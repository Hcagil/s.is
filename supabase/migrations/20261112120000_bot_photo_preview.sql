-- A bot photo may now carry attachment_preview. The table check
-- messages_attachment_preview_check (base64 PNG, at most 4000 chars) still applies to
-- every row, so no new shape is allowed.
create or replace function app_private.messages_bot_rate() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.is_bot(new.sender_id) then return new; end if;
  if new.attachment_path is not null and not (
    new.attachment_name is null and
    new.attachment_mime is null and
    new.attachment_size is null and
    new.attachment_duration_ms is null and
    new.attachment_waveform is null and
    new.voice_transcript is null and
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
