-- Update 2: send files. A file is a message with an attachment_path (the
-- same private `attachments` bucket and the same members-only paths as a
-- photo) plus its original name, MIME type and size. An older build reads it
-- as a photo it cannot show; nothing else changes for it.
--
--  * Additive: three nullable columns, one trigger, one more column at the END
--    of conversation_previews, the push text, and the bucket limit widened.
--  * The bucket accepted only 10 MiB images. It now takes 50 MiB (52428800
--    bytes, enforced by storage itself), and the type list is the four image
--    types plus application/octet-stream. The phone uploads every non-photo
--    file as octet-stream (the real type travels in attachment_mime), so a
--    scripted SVG, XHTML or HTML object can never be stored and then served
--    as-is from the API domain. The phone still limits photos to 10 MiB and
--    re-encodes them; a hand-made upload could send a larger image, and it is
--    still members-only (attachments_write) and tied to the sender
--    (owns_attachment). No policy changes.
--  * The three file columns are all set or all null, and only with an
--    attachment_path. The name is display text only (1 to 255 characters, no
--    control character, no direction mark or zero-width character that could
--    disguise the type); it is never used as a storage key or a path.
--  * A file's body is frozen while the message lives, so edit_message cannot
--    add a caption. Delete for everyone clears the file columns with the
--    path in the same update (the trigger below), so nothing about a deleted
--    file survives.

update storage.buckets
   set file_size_limit = 52428800,
       allowed_mime_types = array[
         'image/jpeg','image/png','image/webp','image/gif',
         'application/octet-stream'
       ]
 where id = 'attachments';

alter table public.messages
  add column attachment_name text,
  add column attachment_mime text,
  add column attachment_size bigint,
  add constraint messages_file_columns_check check (
    (attachment_name is null and attachment_mime is null and attachment_size is null)
    or (attachment_path is not null
        and attachment_name is not null and attachment_mime is not null
        and attachment_size is not null
        and char_length(attachment_name) between 1 and 255
        and attachment_name !~ '[[:cntrl:]]'
        -- direction marks and zero-width characters can disguise the type
        and attachment_name !~ '[\u200B-\u200F\u202A-\u202E\u2066-\u2069]'
        and char_length(attachment_mime) between 3 and 127
        and attachment_mime ~ '^[^[:space:]/]+/[^[:space:]/]+$'
        and attachment_size between 1 and 52428800));

grant insert (attachment_name, attachment_mime, attachment_size) on public.messages to authenticated;

create function app_private.messages_file_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted is not null then
    new.attachment_name := null;
    new.attachment_mime := null;
    new.attachment_size := null;
  elsif old.attachment_name is not null and new.body is distinct from old.body then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_file_guard() from public, anon, authenticated;
create trigger messages_file_guard before update of body, deleted on public.messages
  for each row execute function app_private.messages_file_guard();

-- The chat list names a file in its preview: one more column at the end.
-- Same definition as 20261012120000 (contact), plus attachment_name.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact, m.attachment_name
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll,
           mm.contact, mm.attachment_name
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;

-- Push text: "📎 <file name>" for a file with no text. Same body as
-- 20261008120000 with that one branch added.
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
