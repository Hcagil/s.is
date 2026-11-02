-- delete_message rules on the server clock
-- L1: a delete erases all content

-- deleted_by_admin: set by delete_message when an admin removes a message as admin
alter table public.messages add column deleted_by_admin boolean not null default false;

-- queue: files a service-role job removes from Storage later; no client access
create table app_private.storage_removal_queue (
  id bigint generated always as identity primary key,
  bucket text not null,
  path text not null,
  queued_at timestamptz not null default now(),
  unique (bucket, path)
);
alter table app_private.storage_removal_queue enable row level security;
revoke all on table app_private.storage_removal_queue from public, anon, authenticated;

create or replace function public.delete_message(message uuid) returns text language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
  age interval;
  is_group boolean;
  by_admin boolean;
begin
  if not app_private.has_app_access() then raise exception 'not permitted' using errcode = '42501'; end if;
  select * into m from public.messages where id = message for update;
  if not found or m.deleted is not null or not app_private.is_member(m.conversation_id)
     then raise exception 'not permitted' using errcode = '42501';
  end if;
  age := now() - m.created_at;
  is_group := exists(select 1 from public.conversations c where c.id = m.conversation_id and c.direct_key is null);
  -- rule 12: a 1:1 chat with a bot account allows delete for me only
  if not is_group and exists(select 1 from public.conversation_members cm join app_private.bot_accounts b on b.user_id = cm.user_id
                              where cm.conversation_id = m.conversation_id and cm.user_id <> auth.uid())
     then raise exception 'not permitted' using errcode = '42501';
  end if;
  if m.sender_id = auth.uid() and age <= interval '6 hours' then by_admin := false;
  elsif is_group and app_private.is_admin(m.conversation_id) and app_private.message_readable(m) then by_admin := true;
  else raise exception 'not permitted' using errcode = '42501'; end if;
  if m.attachment_path is not null then
    insert into app_private.deleted_attachments(path, user_id) values (m.attachment_path, auth.uid())
    on conflict (path) do update set user_id = excluded.user_id, recorded_at = now();
  end if;
  if m.attachment_path is not null then
    insert into app_private.storage_removal_queue(bucket, path) values ('attachments', m.attachment_path), ('attachments', m.attachment_path || '.t') on conflict (bucket, path) do nothing;
  end if;
  -- always: an earlier edit may have cleared link_preview while the picture stayed in Storage
  insert into app_private.storage_removal_queue(bucket, path) values ('link-previews', m.conversation_id::text || '/' || m.id::text || '.jpg') on conflict (bucket, path) do nothing;
  delete from public.polls where message_id = message; -- poll_options and poll_votes cascade
  delete from public.message_reactions where message_id = message;
  update public.messages set body = '', sticker_album = false, ciphertext = null, olm_type = null, attachment_path = null, attachment_preview = null, attachment_name = null, attachment_mime = null, attachment_size = null, attachment_duration_ms = null, attachment_waveform = null, voice_transcript = null, location_lat = null, location_lng = null, photo_group = null, sticker_id = null, sticker_album_id = null, link_preview = null, edited_at = null, deleted = case when not by_admin and age < interval '15 minutes' then 'vanished' else 'placeholder' end, deleted_at = now(), deleted_by = auth.uid(), deleted_by_admin = by_admin where id = message;
  return m.attachment_path;
end
$$;
revoke all on function public.delete_message(uuid) from public, anon;
grant execute on function public.delete_message(uuid) to authenticated;
