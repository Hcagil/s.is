-- Update 2: voice messages. A voice message is a file message (same private
-- `attachments` bucket, same members-only path, original name, MIME type and
-- size) whose MIME type is audio/mp4 (AAC in an .m4a) and which carries its
-- length, a small waveform and, when the sender's phone made one, a transcript.
--
--  * attachment_duration_ms already marks a video; it now also marks a voice
--    message: 1 ms to 10 minutes (600000 ms, the app's limit) on audio/mp4.
--    A video keeps its 5 minute limit. Any other MIME type keeps a null length.
--  * attachment_waveform: the bars drawn in the bubble, one lowercase hex digit
--    (0..f) per bar, 1 to 64 bars. Voice messages only.
--  * voice_transcript: the words of the message as text, made on the SENDER's
--    phone and sent with the message (never on a server). Nullable, 1 to 10000
--    characters, voice messages only. It is a plain column with the same row
--    security as `body` (whoever may read the message may read it) so a
--    ciphertext can replace it later. It is never part of a push or
--    notification text and never part of a chat list preview.
--  * The bucket is unchanged: the phone uploads the recording as
--    application/octet-stream (the real type travels in attachment_mime), so
--    the 50 MiB limit of 20261013120000 still applies and no audio type is
--    added to the allowlist. A voice message has no thumbnail object.
--  * Clients cannot update the new columns (insert grant only); delete for
--    everyone clears them with the other file columns.
--  * The chat list preview carries the MIME type column (the app shows
--    "Voice message"), and the push text for a voice message is
--    "🎤 Voice message" whatever its transcript says.

alter table public.messages
  add column attachment_waveform text,
  add column voice_transcript text;

alter table public.messages drop constraint messages_video_check;
alter table public.messages
  add constraint messages_duration_check check (
    attachment_duration_ms is null
    or (attachment_name is not null
        and ((attachment_mime ~ '^video/'
              and attachment_duration_ms between 1 and 300000)
          or (attachment_mime = 'audio/mp4'
              and attachment_duration_ms between 1 and 600000)))),
  add constraint messages_voice_check check (
    (attachment_waveform is null and voice_transcript is null)
    or (attachment_mime = 'audio/mp4'
        and attachment_duration_ms is not null
        and (attachment_waveform is null
             or attachment_waveform ~ '^[0-9a-f]{1,64}$')
        and (voice_transcript is null
             or char_length(voice_transcript) between 1 and 10000)));

grant insert (attachment_waveform, voice_transcript) on public.messages to authenticated;

-- messages_file_guard as in 20261014120000, plus: a deleted message loses its
-- waveform and transcript with the other file columns.
create or replace function app_private.messages_file_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted is not null then
    new.attachment_name := null;
    new.attachment_mime := null;
    new.attachment_size := null;
    new.attachment_duration_ms := null;
    new.attachment_waveform := null;
    new.voice_transcript := null;
  elsif old.attachment_name is not null and new.body is distinct from old.body then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;

-- The chat list tells a voice message from a video by the MIME type column:
-- one more column at the END. Same definition as 20261015120000, plus
-- attachment_mime. The transcript is deliberately not in the view.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact, m.attachment_name,
       m.attachment_duration_ms, m.location_lat, m.attachment_mime
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll,
           mm.contact, mm.attachment_name, mm.attachment_duration_ms, mm.location_lat,
           mm.attachment_mime
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;

-- Push text: "🎤 Voice message" for a voice message with no text. Same body as
-- 20261014120000 with that one branch added before the video branch (a voice
-- message also has a length). The transcript is never read here.
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
           when m.attachment_mime = 'audio/mp4' and btrim(m.body) = ''
             then '🎤 Voice message'
           when m.attachment_duration_ms is not null and btrim(m.body) = ''
             then '🎥 Video'
           when m.attachment_name is not null and btrim(m.body) = ''
             then '📎 ' || case when char_length(m.attachment_name) <= 100 then m.attachment_name
                                else left(m.attachment_name, 99) || '…' end
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
