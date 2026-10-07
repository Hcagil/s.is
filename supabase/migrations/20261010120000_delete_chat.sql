-- Update 2: delete a chat from the chat list.
--
-- Three server paths, one table:
--
--  * Delete for me (any chat, a group or a 1:1): hide_chat(). The chat leaves
--    the caller's list and its old messages stay hidden from the caller for
--    good; nobody else sees any change. The cut-off is the caller's own
--    history_from -- the same gate every read already honours (messages_read,
--    previews, search, unread counts, read marks) -- so nothing else had to
--    change. If the other person (or the group) writes again, the chat comes
--    back with only the new messages. public.chat_hides remembers "this user
--    hid this chat" so the app can drop a chat that has no readable message
--    left (a chat nobody has written in yet is otherwise a listed, empty row).
--  * Delete for both sides (a 1:1 only): delete_direct_chat(). Either of the
--    two people may do it. The conversation, its messages and photos go for
--    both, like delete_group() does for a group; the photo paths come back so
--    the app can remove the files (each is recorded for the caller first,
--    which is what lets the storage delete policies accept them).
--  * Delete a group for all members: unchanged -- delete_group() (a current
--    admin; SIS stores no separate "creator", the admin is who may do it).
--    Leaving a group: unchanged -- leave_group().
--
-- Additive only: one new table and two new functions. Builds that do not know
-- this migration never call them.

-- 1. Who hid which chat. Own rows are readable; there are NO insert / update /
--    delete grants: only hide_chat() writes (security definer).
create table public.chat_hides (
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  hidden_at       timestamptz not null default now(),
  primary key (user_id, conversation_id)
);
create index chat_hides_conversation_idx on public.chat_hides (conversation_id);

alter table public.chat_hides enable row level security;
revoke all on table public.chat_hides from anon, authenticated;
grant select on table public.chat_hides to authenticated;

create policy chat_hides_read on public.chat_hides
  for select to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));

-- 2. Delete for me. The caller must be, or have been, a member (a group they
--    left stays in their list read-only and can be removed from it). The
--    bot never hides chats. Only the caller's own membership rows change, and
--    only history_from: it moves up to the clock's current instant (never
--    back; clock_timestamp, not now(), so a message written earlier in the same
--    transaction is cut off too), so everything sent
--    before this moment is unreadable to the caller from here on. The chat's
--    pin and archive marks go with it, so it does not come back pinned.
create function public.hide_chat(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if not (select app_private.has_app_access())
     or app_private.is_bot(me)
     or not app_private.was_member(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversation_members cm
     set history_from = greatest(cm.history_from, clock_timestamp())
   where cm.conversation_id = conversation and cm.user_id = me;
  insert into public.chat_hides(user_id, conversation_id, hidden_at)
  values (me, conversation, now())
  on conflict (user_id, conversation_id) do update set hidden_at = excluded.hidden_at;
  delete from public.chat_pins
   where user_id = me and conversation_id = conversation;
  delete from public.chat_archives
   where user_id = me and conversation_id = conversation;
end $$;
revoke all on function public.hide_chat(uuid) from public, anon;
grant execute on function public.hide_chat(uuid) to authenticated;

-- 3. Delete a 1:1 for both sides. A current member of a real 1:1 (a direct_key
--    and no title, never the system chat, never one the SIS Bot is in --
--    those exist by the bot's own rules). Returns the photo paths so the app
--    can remove the files; recorded for the caller first, exactly as
--    delete_group does, because the messages are gone by the time the files
--    are removed. The other person's list is nudged to re-read (the same
--    private Realtime topic delete_group uses).
create function public.delete_direct_chat(conversation uuid)
returns text[] language plpgsql security definer set search_path = '' as $$
declare
  me    uuid := auth.uid();
  paths text[];
begin
  perform pg_advisory_xact_lock(hashtextextended('direct_chat:' || conversation::text, 0));
  if not (select app_private.has_app_access())
     or app_private.is_bot(me)
     or not app_private.is_member(conversation)
     or not exists (select 1 from public.conversations c
                     where c.id = conversation
                       and c.direct_key is not null
                       and c.title is null
                       and not c.system)
     or exists (select 1
                  from public.conversation_members cm
                  join app_private.bot_accounts b on b.user_id = cm.user_id
                 where cm.conversation_id = conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select coalesce(array_agg(m.attachment_path), '{}') into paths
    from public.messages m
   where m.conversation_id = conversation and m.attachment_path is not null;
  insert into app_private.deleted_attachments(path, user_id)
    select p, me from unnest(paths) as p
    on conflict (path) do update
      set user_id = excluded.user_id, recorded_at = now();
  perform app_private.notify_group_changed(conversation, 'deleted');
  delete from public.conversations where id = conversation;
  return paths;
end $$;
revoke all on function public.delete_direct_chat(uuid) from public, anon;
grant execute on function public.delete_direct_chat(uuid) to authenticated;
