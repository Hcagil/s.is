-- Online status and typing indicators (v0.4).
--
-- Both travel over PRIVATE Realtime channels, which Realtime authorises with
-- row-level security on realtime.messages: `select` decides who may receive
-- on a topic, `insert` who may send (and, for presence, who may be seen).
-- realtime.topic() names the channel being authorised.
--
-- Topics:
--   presence:members           who is online; any active member
--   typing:<conversation id>   who is typing; members of that conversation
--
-- Before this migration realtime.messages had RLS on and no policies, so
-- private channels were deny-all. These policies open exactly the two topics
-- above and nothing else.

-- A member may stop sharing either. Stored on the profile, so the choice
-- follows the account to a new phone like everything else does.
alter table public.profiles
  add column share_presence boolean not null default true,
  add column share_typing boolean not null default true;
grant update (share_presence, share_typing) on public.profiles to authenticated;

-- The conversation a `typing:<uuid>` topic names, or null for anything else.
-- Never raises on a malformed topic: a junk channel name is a refusal, not an
-- error.
create or replace function app_private.typing_conversation(topic text)
returns uuid language plpgsql immutable set search_path = '' as $$
declare
  rest text;
begin
  if topic is null or left(topic, 7) <> 'typing:' then
    return null;
  end if;
  rest := substr(topic, 8);
  if rest !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return null;
  end if;
  return rest::uuid;
end $$;
revoke all on function app_private.typing_conversation(text) from public, anon;
grant execute on function app_private.typing_conversation(text) to authenticated;

-- The caller's own sharing choices, read with definer rights so the policy
-- does not depend on the profiles read policy.
create or replace function app_private.shares_presence() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select p.share_presence from public.profiles p
                    where p.user_id = auth.uid()), false)
$$;
create or replace function app_private.shares_typing() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select p.share_typing from public.profiles p
                    where p.user_id = auth.uid()), false)
$$;
revoke all on function app_private.shares_presence() from public, anon;
revoke all on function app_private.shares_typing() from public, anon;
grant execute on function app_private.shares_presence(),
                          app_private.shares_typing() to authenticated;

-- Receive: the same gate as every other read, plus membership for typing.
create policy realtime_receive on realtime.messages for select to authenticated
  using (
    app_private.has_app_access()
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence')
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic())))
    )
  );

-- Send: as receive, AND the sender has not turned sharing off. Enforced here
-- rather than only in the app, so a modified client cannot announce someone
-- who chose to stay hidden. Realtime evaluates this when a channel is joined;
-- the app also stops sending the moment the setting changes.
create policy realtime_send on realtime.messages for insert to authenticated
  with check (
    app_private.has_app_access()
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence'
       and app_private.shares_presence())
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic()))
          and app_private.shares_typing())
    )
  );
