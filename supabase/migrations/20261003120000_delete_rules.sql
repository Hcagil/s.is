-- v0.30.8: message deletion, WhatsApp style.
--
--  * Delete for me: hide_message() hides one message from the caller's own
--    reads, on every device, for good. Nobody else notices.
--  * Delete for everyone: its sender may do it with no time limit (the 6-hour
--    window of 20260924140000 is gone; editing keeps its window), and a group
--    admin may do it to any member's message. The row is wiped as before --
--    body, photo path, preview -- and always becomes the "This message was
--    deleted" placeholder (new deletes are never 'vanished' any more; old
--    vanished rows stay as they are). deleted_by says who deleted it, so a
--    group can show "deleted by an admin".
--  * The deleted photo file is removed by whoever deleted the message: the
--    delete policy on storage no longer asks the remover to be the uploader,
--    only that delete_message recorded the path for them. A storage DELETE only
--    reaches rows the SELECT policy shows, and a wiped message no longer points
--    at its photo, so attachments_read also lets that same recorded deleter see
--    the object (and only that object) until it is gone.
--
-- Realtime still delivers the wipe as an UPDATE to everyone who may read the
-- row (a real DELETE would fan out to the whole table).

alter table public.messages add column deleted_by uuid;

-- Messages a member hid from themselves. No policies and no grants: only the
-- security definer functions below read or write it.
create table app_private.message_hides (
  user_id    uuid not null references auth.users(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  primary key (user_id, message_id)
);
alter table app_private.message_hides enable row level security;
revoke all on table app_private.message_hides from anon, authenticated;

-- message_readable is the one gate shared by messages_read, search_messages,
-- attachment_readable and in_conversation (20260929120000): hiding a message
-- there hides it from the list, the chat-list preview, search and its photo
-- at once, and a Realtime update for it never reaches the hider. Unchanged
-- apart from the hide check.
create or replace function app_private.message_readable(m public.messages) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.conversation_members cm
     where cm.conversation_id = m.conversation_id
       and cm.user_id = auth.uid()
       and m.created_at >= cm.history_from
       and (cm.left_at is null or m.created_at <= cm.left_at)
  ) and not exists (
    select 1 from app_private.message_hides h
     where h.user_id = auth.uid() and h.message_id = m.id
  )
$$;

-- Hides [message] from the caller: they must be able to read it now.
create function public.hide_message(message uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message;
  if not found or not app_private.message_readable(m) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into app_private.message_hides(user_id, message_id)
  values (auth.uid(), message)
  on conflict do nothing;
end $$;
revoke all on function public.hide_message(uuid) from public, anon;
grant execute on function public.hide_message(uuid) to authenticated;

-- delete_message, redefined (20260929120000 is released; never edit it):
-- the sender, or a current admin of the conversation who can read the
-- message, may delete it for everyone, at any age. Returns the photo path to
-- remove from storage (or null), recorded for the DELETER.
create or replace function public.delete_message(message uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.deleted is not null
     or not app_private.is_member(m.conversation_id)
     or not (m.sender_id = auth.uid()
             or (app_private.is_admin(m.conversation_id)
                 and app_private.message_readable(m))) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if m.attachment_path is not null then
    insert into app_private.deleted_attachments(path, user_id)
    values (m.attachment_path, auth.uid())
    on conflict do nothing;
  end if;
  update public.messages
     set body = '',
         attachment_path = null,
         attachment_preview = null,
         edited_at = null,
         deleted = 'placeholder',
         deleted_at = now(),
         deleted_by = auth.uid()
   where id = message;
  return m.attachment_path;
end $$;

-- The photo file of a deleted message may be removed by whoever deleted the
-- message (delete_message recorded the path for them, and no live message
-- shows it), not only by its uploader.
drop policy attachments_remove_deleted on storage.objects;
create policy attachments_remove_deleted on storage.objects for delete to authenticated
  using (bucket_id = 'attachments'
         and (select app_private.has_app_access())
         and app_private.may_remove_attachment(name));

-- attachments_read as in 20260929120000, plus: the deleter delete_message
-- recorded may see the (now unreferenced) object, so the delete above can
-- reach it. may_remove_attachment needs a deleted_attachments row for the
-- caller and no live message on the path: nobody else gains any read.
drop policy attachments_read on storage.objects;
create policy attachments_read on storage.objects for select to authenticated
  using (bucket_id = 'attachments'
         and (select app_private.has_app_access())
         and (app_private.attachment_readable(name, owner_id)
              or app_private.may_remove_attachment(name)));
