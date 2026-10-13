-- Update 2: send videos. A video is a file message (same private `attachments`
-- bucket, same members-only path, original name, MIME type and size) that also
-- carries its length, plus a small jpeg thumbnail stored next to it.
--
--  * attachment_duration_ms marks a video: null for every other message. It is
--    set only on a file message whose MIME type is video/*, 1 ms to 5 minutes
--    (300000 ms, the app's limit; the phone also refuses longer clips before
--    compressing). A video picked as a plain file keeps a null length and stays
--    a file bubble.
--  * The bucket is unchanged: the phone uploads the video and its thumbnail as
--    application/octet-stream (the real type travels in attachment_mime), so
--    the server never stores or serves a scripted type, and the 50 MiB limit of
--    20261013120000 still applies to the compressed video. No video type is
--    added to the allowlist.
--  * The thumbnail object is `<video path>.t`. Whoever may read the video
--    message may read it (attachment_readable); whoever deleted the message may
--    read and remove it (may_remove_attachment follows the video's own record in
--    deleted_attachments). No new policy: the existing attachments_write already
--    gates the whole `<conversation>/...` folder to members.
--  * Delete for everyone clears the length with the other file columns.
--  * The chat list preview carries the length column (the app shows
--    "🎥 Video"), and the push text for a caption-less video is "🎥 Video".

alter table public.messages
  add column attachment_duration_ms integer,
  add constraint messages_video_check check (
    attachment_duration_ms is null
    or (attachment_name is not null
        and attachment_mime ~ '^video/'
        and attachment_duration_ms between 1 and 300000));

grant insert (attachment_duration_ms) on public.messages to authenticated;

-- messages_file_guard as in 20261013120000, plus: a deleted message loses its
-- length with the other file columns.
create or replace function app_private.messages_file_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted is not null then
    new.attachment_name := null;
    new.attachment_mime := null;
    new.attachment_size := null;
    new.attachment_duration_ms := null;
  elsif old.attachment_name is not null and new.body is distinct from old.body then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;

-- attachment_readable as in 20260929120000, plus: the thumbnail of a video
-- message is readable exactly when that message is (same window).
create or replace function app_private.attachment_readable(
  object_name text,
  object_owner_id text
) returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  head text := (storage.foldername(object_name))[1];
begin
  if head is null or head !~
     '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  then
    return false;
  end if;
  return (object_owner_id = auth.uid()::text and app_private.was_member(head::uuid))
      or exists (
           select 1 from public.messages m
            where m.attachment_path = object_name
              and app_private.message_readable(m.*)
         )
      or (object_name ~ '\.t$' and exists (
           select 1 from public.messages m
            where m.attachment_path = left(object_name, -2)
              and m.attachment_duration_ms is not null
              and app_private.message_readable(m.*)
         ));
end $$;
revoke all on function app_private.attachment_readable(text, text) from public, anon;
grant execute on function app_private.attachment_readable(text, text) to authenticated;

-- may_remove_attachment as in 20261005120000, plus: a thumbnail `<path>.t` is
-- removable through the record of `<path>` (delete_message, delete_group and
-- delete_direct_chat record the video's path, never the thumbnail's), under
-- the same rules: the caller's own record, the object older than the record,
-- no live message on the path.
create or replace function app_private.may_remove_attachment(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1
                   from app_private.deleted_attachments d
                   join storage.objects o
                     on o.bucket_id = 'attachments' and o.name = object_name
                  where d.path = case when object_name ~ '\.t$'
                                      then left(object_name, -2) else object_name end
                    and d.user_id = auth.uid()
                    and o.created_at <= d.recorded_at)
     and not exists (select 1 from public.messages m
                      where m.attachment_path = case when object_name ~ '\.t$'
                                                     then left(object_name, -2) else object_name end)
$$;

-- The chat list names a video by its length column: one more column at the
-- end. Same definition as 20261013120000, plus attachment_duration_ms.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact, m.attachment_name,
       m.attachment_duration_ms
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll,
           mm.contact, mm.attachment_name, mm.attachment_duration_ms
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;

-- Push text: "🎥 Video" for a video with no text. Same body as 20261013120000
-- with that one branch added before the file branch.
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
