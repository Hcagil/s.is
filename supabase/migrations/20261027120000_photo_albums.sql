-- Photo albums: photos picked together share one group id (photo_group); each
-- photo stays its own message. The app draws a run of 2 or more messages with
-- the same photo_group from the same sender as one bubble.
--
-- The column is write-once: the insert grant covers it, and authenticated has
-- no update grant on public.messages, so it cannot be changed afterwards.
-- It is only allowed on a photo message (a stored image, not a file or video);
-- a message deleted for everyone has lost its image and may keep the value.
-- No index: no query filters on it, the app groups the rows it has already read.

alter table public.messages
  add column photo_group uuid,
  add constraint messages_photo_group_check check (
    photo_group is null
    or deleted is not null
    or (attachment_path is not null and attachment_name is null));

grant insert (photo_group) on public.messages to authenticated;
