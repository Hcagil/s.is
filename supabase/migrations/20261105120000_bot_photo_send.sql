-- SIS Bot: lets the bot upload a plain photo into chats it belongs to
-- limits are 10 uploads / 10 min and 50 / 24 h, counted under a lock like bot_send_charge.
create function app_private.bot_upload_ok(object_name text) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid := auth.uid(); n10 int; n24 int;
begin
  if uid is null or object_name !~ '^[0-9a-f-]{36}/[0-9]{1,20}-[0-9a-f]{8}\.(jpg|jpeg|png|webp|gif)$' then return false; end if;
  if substring(object_name from '-([0-9a-f]{8})\.[a-z]+$') <> left(uid::text, 8) then return false; end if;
  perform pg_advisory_xact_lock(hashtextextended('bot_upload:' || uid::text, 0));
  select count(*) filter (where o.created_at >= now() - interval '10 minutes'), count(*) into n10, n24 from storage.objects o where o.bucket_id = 'attachments' and o.owner_id = uid::text and o.created_at >= now() - interval '24 hours';
  return n10 < 10 and n24 < 50;
end $$;
revoke all on function app_private.bot_upload_ok(text) from public, anon; grant execute on function app_private.bot_upload_ok(text) to authenticated;

-- only the bot line changed; the bot may upload only a photo-shaped name into a chat it is a member of.
drop policy attachments_write on storage.objects;
create policy attachments_write on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
              and (select app_private.has_app_access())
              and (not app_private.is_bot((select auth.uid())) or app_private.bot_upload_ok(name))
              and app_private.is_member_of_path(name)
              and owner_id = (select auth.uid())::text);

-- A bot row with attachment_path passes only as a plain single photo (every other
-- content column empty, a stored image of at most 10 MB), then counts as one send.
create or replace function app_private.messages_bot_rate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.is_bot(new.sender_id) then return new; end if;
  if new.attachment_path is not null and not (
    new.attachment_name is null and
    new.attachment_mime is null and
    new.attachment_size is null and
    new.attachment_duration_ms is null and
    new.attachment_waveform is null and
    new.voice_transcript is null and
    new.attachment_preview is null and
    new.photo_group is null and
    new.sticker_id is null and
    new.sticker_album_id is null and
    new.location_lat is null and
    new.location_lng is null and
    new.link_preview is null and
    new.ciphertext is null and
    new.olm_type is null and
    not new.poll and
    not new.contact and
    not new.sticker_album and
    not new.forwarded and
    exists (
      select 1 from storage.objects o
      where o.bucket_id = 'attachments'
        and o.name = new.attachment_path
        and o.owner_id = new.sender_id::text
        and o.metadata->>'mimetype' in ('image/jpeg','image/png','image/webp','image/gif')
        and (o.metadata->>'size')::bigint <= 10485760
    )
  ) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform app_private.bot_send_charge(new.sender_id);
  return new;
end $$;
