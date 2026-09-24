-- v0.11: read status, mutual like last seen.
--
-- A sender sees their message a little grey until it is read. Whether
-- someone has read is derived from conversation_members.last_read_at, which
-- clients cannot select (20260923150000_unread_counts.sql): it reaches them
-- only through read_marks() and the reads:<conversation> broadcast below,
-- and only between members who both share their read status. Turning it off
-- hides your reads from others and theirs from you.

alter table public.profiles
  add column share_read_status boolean not null default true;
grant update (share_read_status) on public.profiles to authenticated;

create function app_private.shares_read_status() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select p.share_read_status from public.profiles p
                    where p.user_id = auth.uid()), false)
$$;
revoke all on function app_private.shares_read_status() from public, anon;
grant execute on function app_private.shares_read_status() to authenticated;

-- For every other member of [conversation]: whether read status is shared
-- between the two of you, and if so how far they have read.
create function public.read_marks(conversation uuid)
returns table (user_id uuid, shares boolean, read_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select cm.user_id,
         both_share,
         case when both_share then cm.last_read_at end
    from public.conversation_members cm
    left join public.profiles p on p.user_id = cm.user_id
   cross join lateral (
     select coalesce(p.share_read_status, false)
            and app_private.shares_read_status() as both_share
   ) s
   where cm.conversation_id = conversation
     and cm.user_id <> auth.uid()
     and app_private.has_app_access()
     and app_private.is_member(conversation)
$$;
revoke all on function public.read_marks(uuid) from public, anon;
grant execute on function public.read_marks(uuid) to authenticated;

-- Reading also tells the open screens of the conversation, live -- but only
-- when the reader shares their read status. Sent by the database: clients
-- cannot send on a reads: topic (no send policy matches it).
create or replace function public.mark_read(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversation_members m
     set last_read_at = now()
   where m.conversation_id = conversation
     and m.user_id = auth.uid();
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.shares_read_status() then
    perform realtime.send(
      jsonb_build_object('user_id', auth.uid(), 'read_at', now()),
      'read',
      'reads:' || conversation::text,
      true);
  end if;
end $$;

-- 'reads:<uuid>' -> the conversation, or null for any other topic.
create function app_private.reads_conversation(topic text)
returns uuid language plpgsql immutable set search_path = '' as $$
declare
  rest text;
begin
  if topic is null or left(topic, 6) <> 'reads:' then
    return null;
  end if;
  rest := substr(topic, 7);
  if rest !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return null;
  end if;
  return rest::uuid;
end $$;
revoke all on function app_private.reads_conversation(text) from public, anon;
grant execute on function app_private.reads_conversation(text) to authenticated;

-- Receiving: as before, plus reads of your conversations when you share
-- your own read status (mutual). Sending is unchanged, so no client can send
-- a read.
drop policy realtime_receive on realtime.messages;
create policy realtime_receive on realtime.messages for select to authenticated
  using (
    app_private.has_app_access()
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence')
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic())))
      or (extension = 'broadcast'
          and app_private.is_member(app_private.reads_conversation(realtime.topic()))
          and app_private.shares_read_status())
    )
  );
