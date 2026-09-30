-- Push goes only to a token its own session still stands behind.
--
-- device_tokens was tied to a member, not to a session: push_targets checked
-- that the RECIPIENT had an active session, never that the TOKEN belonged to
-- it. Ben registers an iPhone, signs in on another device, and the old token
-- stayed a target. Android's own owner check dropped such a push on the
-- phone; on iOS the system draws the alert, so a displaced iPhone would show
-- the message on its lock screen.
--
-- Invariant, for every platform: a push goes to a token whose registering
-- session (device_tokens.session_id, from the JWT) is still the member's
-- active session AND still exists in auth.sessions. An unbound token
-- (session_id null) is never a target.
--
-- Every path that ends or switches a session keeps it without touching this
-- table: activate_session() swaps active_sessions.session_id (the old token's
-- session no longer matches), sign-out / revocation delete the auth.sessions
-- row (the join fails), register_device_token() rebinds the row it writes.

alter table app_private.device_tokens add column session_id uuid;

-- Existing rows take the member's current active session, so nobody's
-- notifications stop at the release. A member with no live active session
-- keeps unbound tokens, which are never targets.
update app_private.device_tokens d
   set session_id = s.session_id
  from app_private.active_sessions s
  join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
 where s.user_id = d.user_id;

-- Same body as 20260925100000_push_display.sql plus the session binding.
create or replace function public.register_device_token(
  device_token    text,
  device_platform text,
  shows_itself    boolean default false
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if device_token is null
     or char_length(device_token) < 10 or char_length(device_token) > 4096
     or device_platform is null
     or device_platform not in ('android', 'ios') then
    raise exception 'invalid device token' using errcode = '22023';
  end if;

  -- One row per member: the single-active-device rule, extended to push.
  delete from app_private.device_tokens d
   where d.user_id = auth.uid() and d.token <> device_token;
  -- A token identifies a handset, not a person: another member signing in on
  -- this handset takes the token over.
  delete from app_private.device_tokens d
   where d.token = device_token and d.user_id <> auth.uid();

  -- has_app_access() above proved the JWT's session is the member's active
  -- one, so jwt_session_id() is never null here. The client sends no session.
  insert into app_private.device_tokens(user_id, token, platform, shows_itself, session_id)
  values (auth.uid(), device_token, device_platform,
          coalesce(register_device_token.shows_itself, false),
          app_private.jwt_session_id())
  on conflict (user_id, token) do update
    set platform = excluded.platform, shows_itself = excluded.shows_itself,
        session_id = excluded.session_id, updated_at = now();
end $$;

create or replace function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, 'Someone')
           else coalesce(p.display_name, 'Someone') || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' then 'New message'
           when btrim(m.body) = '' and m.attachment_path is not null then '📷 Photo'
           else case when m.attachment_path is not null then '📷 ' else '' end
                || case when char_length(btrim(m.body)) <= 120 then btrim(m.body)
                        else left(btrim(m.body), 119) || '…' end
         end,
         d.shows_itself
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id <> m.sender_id
     and cm.left_at is null
    join app_private.device_tokens d on d.user_id = cm.user_id
    join app_private.active_sessions s
      on s.user_id = cm.user_id and s.session_id = d.session_id
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
    left join public.profiles p on p.user_id = m.sender_id
    left join public.notification_settings ns on ns.user_id = cm.user_id
   where m.id = message_id
     and m.deleted is null
     and app_private.is_allowed(cm.user_id)
     and coalesce(ns.enabled, true)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = cm.user_id
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;
