-- v0.30.8: the app-icon unread badge.
--
-- One number for the whole app: the messages the member has not read, across
-- every conversation they are still in, leaving out what they would not be
-- told about -- their own messages, deleted ones, ones they deleted for
-- themselves, and chats or people they muted (the same mute rules as
-- push_targets_for_message).
--
--  * app_private.unread_total(member): the count itself. Not callable by any
--    client role; it takes any user id.
--  * public.unread_total(): the caller's own count, for the app to set the
--    badge when it opens, resumes or reads a chat (so a stale number is
--    corrected, including after a read on another device).
--  * push_targets*() carry the recipient's count (`badge`) so the push that
--    announces a message also sets the badge while the app is closed.
--  * unread_counts() now skips messages the member deleted for themselves, so
--    the chat list and the badge agree.

create function app_private.unread_total(member uuid)
returns integer
language sql stable security definer set search_path = '' as $$
  select coalesce(count(*), 0)::integer
    from public.conversation_members cm
    join public.messages m
      on m.conversation_id = cm.conversation_id
     and m.created_at > cm.last_read_at
     and m.created_at >= cm.history_from
     and m.sender_id <> cm.user_id
     and m.deleted is null
   where cm.user_id = member
     and cm.left_at is null
     and not exists (
       select 1 from app_private.message_hides h
        where h.user_id = member and h.message_id = m.id)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = member
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;
revoke all on function app_private.unread_total(uuid) from public, anon, authenticated;

create function public.unread_total()
returns integer
language sql stable security definer set search_path = '' as $$
  select case when app_private.has_app_access()
              then app_private.unread_total(auth.uid()) else 0 end
$$;
revoke all on function public.unread_total() from public, anon;
grant execute on function public.unread_total() to authenticated;

create or replace function public.unread_counts()
returns table (conversation_id uuid, unread integer)
language sql stable security definer set search_path = '' as $$
  select cm.conversation_id, count(*)::integer
    from public.conversation_members cm
    join public.messages m
      on m.conversation_id = cm.conversation_id
     and m.created_at > cm.last_read_at
     and m.created_at >= cm.history_from
     and m.sender_id <> cm.user_id
     and m.deleted is null
   where cm.user_id = auth.uid()
     and cm.left_at is null
     and app_private.has_app_access()
     and not exists (
       select 1 from app_private.message_hides h
        where h.user_id = cm.user_id and h.message_id = m.id)
   group by cm.conversation_id
$$;

-- The delivery list gains `badge`; the return type changes, so both functions
-- are recreated. Same bodies as 20261001120000_push_group_name.sql plus the
-- badge column.
drop function public.push_targets(uuid);
drop function app_private.push_targets_for_message(uuid);

create function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer)
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
         d.shows_itself,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else coalesce(p.display_name, 'Someone') end,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else c.title end,
         app_private.unread_total(cm.user_id)
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
revoke all on function app_private.push_targets_for_message(uuid)
  from public, anon, authenticated;

create function public.push_targets(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer)
language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into app_private.push_sent(message_id)
  select m.id from public.messages m
   where m.id = push_targets.message_id
     and m.created_at > now() - interval '2 minutes'
  on conflict do nothing;
  if not found then
    return;
  end if;
  return query select * from app_private.push_targets_for_message(push_targets.message_id);
end $$;
revoke all on function public.push_targets(uuid) from public, anon, authenticated;
grant execute on function public.push_targets(uuid) to service_role;
