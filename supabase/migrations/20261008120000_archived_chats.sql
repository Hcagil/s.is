-- Update 2: archived chats.
--
-- A member archives a chat for themselves only (a group or a 1:1); nobody else
-- sees or is told. An archived chat STAYS archived when new messages arrive and
-- is silent: no push, and it does not count towards the app-icon badge. The
-- state lives on the server so it survives a reinstall and shows on every
-- device.
--
-- Additive only: one new table; two existing functions are replaced with the
-- same signature and return type (CREATE OR REPLACE, no drop), so existing
-- privileges and callers are untouched.
--
--  * public.chat_archives: one row = "this user archived this conversation".
--    Own rows only (read, insert, delete); there is nothing to update. A row
--    may name only a conversation the user is, or was, a member of (a group
--    they left stays in their list, read-only, and can still be archived), so
--    the table cannot be used to probe conversation ids.
--  * app_private.unread_total(member): the badge count now skips archived
--    chats (also feeds the push `badge`).
--  * app_private.push_targets_for_message(message): skips recipients who
--    archived the conversation, exactly like a conversation mute.
--
-- public.unread_counts() is unchanged on purpose: the chat list still needs
-- each archived chat's own count to show the dot on the "Archived chats" row.

create table public.chat_archives (
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  archived_at     timestamptz not null default now(),
  primary key (user_id, conversation_id)
);
create index chat_archives_conversation_idx on public.chat_archives (conversation_id);

alter table public.chat_archives enable row level security;
revoke all on table public.chat_archives from anon, authenticated;
grant select, insert, delete on table public.chat_archives to authenticated;

create policy chat_archives_read on public.chat_archives
  for select to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));
create policy chat_archives_insert on public.chat_archives
  for insert to authenticated
  with check ((select app_private.has_app_access())
              and user_id = (select auth.uid())
              and app_private.was_member(conversation_id));
create policy chat_archives_delete on public.chat_archives
  for delete to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));

-- The badge count: same body as 20261003130000_unread_badge.sql, plus
-- "not archived".
create or replace function app_private.unread_total(member uuid)
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
       select 1 from public.chat_archives a
        where a.user_id = member and a.conversation_id = m.conversation_id)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = member
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;

-- Who hears about a message: same body as 20261003130000_unread_badge.sql, plus
-- "has not archived the conversation".
create or replace function app_private.push_targets_for_message(message_id uuid)
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
       select 1 from public.chat_archives a
        where a.user_id = cm.user_id and a.conversation_id = m.conversation_id)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = cm.user_id
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;
