-- Image attachments on messages — a demo slice of the "media" row.
--
-- Additive. A message with no attachment behaves exactly as in v0.2, so
-- builds that predate this simply never set the column.

-- A private bucket. Nothing is public: every read goes through a signed URL
-- issued only to a member of the conversation.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'attachments', 'attachments', false, 10485760,
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The object key is `<conversation_id>/<uuid>`, so the first path segment is
-- the authorisation subject: storage access asks exactly the same question the
-- table policies ask, rather than inventing a second rule.
create or replace function app_private.is_member_of_path(object_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  head text := (storage.foldername(object_name))[1];
begin
  if head is null or head !~
     '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  then
    return false;
  end if;
  return app_private.is_member(head::uuid);
end $$;
revoke all on function app_private.is_member_of_path(text) from public, anon;
grant execute on function app_private.is_member_of_path(text) to authenticated;

-- Storage policies: same gate as everything else, plus membership of the
-- conversation named by the path.
drop policy if exists attachments_read on storage.objects;
create policy attachments_read on storage.objects for select to authenticated
  using (bucket_id = 'attachments'
         and app_private.has_app_access()
         and app_private.is_member_of_path(name));

drop policy if exists attachments_write on storage.objects;
create policy attachments_write on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
              and app_private.has_app_access()
              and app_private.is_member_of_path(name)
              and owner_id = auth.uid()::text);

-- No update or delete policy: attachments, like messages, are immutable in
-- this slice.

-- The message half --------------------------------------------------------
alter table public.messages
  add column attachment_path text
  check (attachment_path is null or char_length(attachment_path) between 3 and 400);

-- A message must carry something: text, an image, or both. The existing body
-- check still forbids a blank body, so relax it to allow an empty body ONLY
-- when there is an attachment.
alter table public.messages drop constraint messages_body_check;
alter table public.messages
  add constraint messages_body_check
  check (
    (attachment_path is not null and char_length(btrim(body)) between 0 and 4000)
    or char_length(btrim(body)) between 1 and 4000
  );

-- attachment_path joins the column-level insert grant; id and created_at stay
-- server-assigned.
revoke insert on public.messages from authenticated;
grant insert (conversation_id, sender_id, body, attachment_path)
  on public.messages to authenticated;
