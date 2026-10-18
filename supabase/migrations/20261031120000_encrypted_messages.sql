-- Private Chats step 4a, server side: end-to-end encrypted one-to-one text.
--
-- A ciphertext row is an ordinary messages row whose `ciphertext` (Olm,
-- base64, at most 65536 characters) and `olm_type` (0 pre-key, 1 normal) are
-- set and whose `body` is the fixed placeholder below, so an older build, a
-- push, and every server path that reads `body` stay valid without ever
-- seeing the text. A ciphertext row carries nothing else that could leak
-- content: no link card, attachment, poll, contact, sticker, album or place.
--
--  * A plain text insert into a conversation that already has a ciphertext row
--    is refused (ENCR1): a downgrade cannot survive a reinstall.
--  * Only a direct human chat may hold ciphertext (a member could otherwise
--    lock a group's plain text), and a bot may not send it.
--  * olm_identity(target): the sender's published keys for the receiver to
--    check, with the same gates as claim_olm_keys and no one-time key.
--  * edit_message_encrypted replaces the ciphertext; edit_message refuses
--    ciphertext rows; delete_message clears ciphertext too.
--  * Push: `encrypted` flag out of push_targets; notification replies and
--    server search leave encrypted chats alone.

alter table public.messages
  add column ciphertext text,
  add column olm_type smallint,
  add constraint messages_ciphertext_check check (
    (ciphertext is null) = (olm_type is null)
    and (ciphertext is null or (
      char_length(ciphertext) between 1 and 65536
      and olm_type in (0, 1)
      and body = '🔒 Encrypted message'
      and link_preview is null
      and attachment_path is null and attachment_preview is null
      and attachment_name is null and attachment_mime is null
      and attachment_size is null and attachment_duration_ms is null
      and attachment_waveform is null and voice_transcript is null
      and not poll and not contact and photo_group is null
      and sticker_id is null and sticker_album_id is null and not sticker_album
      and location_lat is null and admin_msg is null)));

create index messages_ciphertext_idx on public.messages (conversation_id)
  where ciphertext is not null;

-- Column-level insert grants are cumulative (20261027120000_photo_albums.sql).
grant insert (ciphertext, olm_type) on public.messages to authenticated;

-- ciphertext: only in a direct human chat, never from a bot. A plain text row
-- (media, stickers, polls, contacts and places stay plain until step 6) into a
-- chat that has ciphertext is refused. System, release-note and admin rows
-- insert plain into system, admin and bot chats, which never hold ciphertext.
create function app_private.messages_ciphertext_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.ciphertext is not null then
    if not exists (select 1 from public.conversations c
                    where c.id = new.conversation_id
                      and c.direct_key is not null and not c.system and not c.admin_chat)
       or exists (select 1 from public.conversation_members cm
                   where cm.conversation_id = new.conversation_id
                     and app_private.is_bot(cm.user_id)) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.attachment_path is null and new.sticker_id is null and not new.sticker_album
     and not new.poll and not new.contact and new.location_lat is null
     and new.admin_msg is null
     and exists (select 1 from public.messages m
                  where m.conversation_id = new.conversation_id and m.ciphertext is not null) then
    raise exception 'conversation is encrypted' using errcode = 'ENCR1';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_ciphertext_guard() from public, anon, authenticated;
create trigger messages_ciphertext_guard before insert on public.messages
  for each row execute function app_private.messages_ciphertext_guard();

-- The sender's published device keys, for the receiver to check the
-- self-signature against the sender's user id. Same gates as claim_olm_keys;
-- uses no one-time key and writes nothing. No rows for a bot or a stale
-- device. Errors: 42501 not permitted (also: target has no live session).
create function public.olm_identity(target uuid)
returns table (identity_key text, signing_key text, device_signature text)
language plpgsql stable security definer set search_path = '' as $$
declare
  me  uuid := auth.uid();
  dev app_private.olm_devices%rowtype;
begin
  if app_private.is_bot(me) or not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if target is null or target = me or not app_private.is_allowed(target)
     or not app_private.can_reach(target) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.is_bot(target) then
    return;
  end if;
  select d.* into dev
    from app_private.olm_devices d
    join app_private.active_sessions s on s.user_id = d.user_id and s.session_id = d.session_id
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
   where d.user_id = target;
  if not found then
    if not exists (select 1 from app_private.active_sessions s
                    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
                   where s.user_id = target) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
    return;
  end if;
  return query select dev.identity_key, dev.signing_key, dev.device_signature;
end $$;
revoke all on function public.olm_identity(uuid) from public, anon;
grant execute on function public.olm_identity(uuid) to authenticated;

-- Replaces the ciphertext of the caller's own encrypted message (same rules as
-- edit_message: member, not deleted, not forwarded, within 6 hours). The body
-- stays the placeholder. Errors: 42501 not permitted (also: not an encrypted
-- row, or an empty/oversized ciphertext, or olm_type not 0 or 1).
create function public.edit_message_encrypted(p_id uuid, p_ciphertext text, p_olm_type smallint)
returns public.messages language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = p_id for update;
  if not found
     or m.sender_id <> auth.uid()
     or not app_private.is_member(m.conversation_id)
     or m.deleted is not null
     or m.forwarded
     or m.created_at < now() - interval '6 hours'
     or m.ciphertext is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_ciphertext is null or char_length(p_ciphertext) not between 1 and 65536
     or p_olm_type is null or p_olm_type not in (0, 1) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.messages
     set ciphertext = p_ciphertext, olm_type = p_olm_type, edited_at = now()
   where id = p_id
  returning * into m;
  return m;
end $$;
revoke all on function public.edit_message_encrypted(uuid, text, smallint) from public, anon;
grant execute on function public.edit_message_encrypted(uuid, text, smallint) to authenticated;

-- delete_message as in 20261005120000 (released, never edited), plus: a deleted
-- message keeps no ciphertext.
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
    on conflict (path) do update
      set user_id = excluded.user_id, recorded_at = now();
  end if;
  update public.messages
     set body = '',
         ciphertext = null,
         olm_type = null,
         attachment_path = null,
         attachment_preview = null,
         edited_at = null,
         deleted = 'placeholder',
         deleted_at = now(),
         deleted_by = auth.uid()
   where id = message;
  return m.attachment_path;
end $$;

-- edit_message as in 20260926120000, plus: refuses an encrypted row (the body is
-- only a placeholder; edit_message_encrypted is the way).
create or replace function public.edit_message(message uuid, body text)
returns public.messages language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
  trimmed text := btrim(coalesce(body, ''));
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.sender_id <> auth.uid()
     or not app_private.is_member(m.conversation_id)
     or m.deleted is not null
     or m.forwarded
     or m.ciphertext is not null
     or m.created_at < now() - interval '6 hours' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not (
    (m.attachment_path is not null and char_length(trimmed) between 0 and 4000)
    or char_length(trimmed) between 1 and 4000
  ) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.messages
     set body = trimmed,
         edited_at = now()
   where id = message
  returning * into m;
  return m;
end $$;

-- Link-card guard as in 20261021120000, plus: a ciphertext row is skipped (the
-- table check already keeps its link_preview null).
create or replace function app_private.messages_link_preview_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare
  lp jsonb := new.link_preview;
  k text;
begin
  if new.ciphertext is not null then
    return new;
  end if;
  if tg_op = 'UPDATE' and (new.deleted is not null or new.body is distinct from old.body) then
    new.link_preview := null;
    return new;
  end if;
  if lp is null then
    return new;
  end if;

  -- jsonb_typeof(null) is null, so every type check uses "is distinct from":
  -- a MISSING key fails too.
  if jsonb_typeof(lp) is distinct from 'object' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  for k in select jsonb_object_keys(lp) loop
    if k not in ('url', 'title', 'description', 'site', 'image', 'video') then
      raise exception 'invalid link preview' using errcode = 'LNKP1';
    end if;
  end loop;

  if jsonb_typeof(lp->'url') is distinct from 'string'
     or lp->>'url' !~* '^https?://[^[:space:][:cntrl:]<>"\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]+$'
     or char_length(lp->>'url') > 2000 then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if jsonb_typeof(lp->'title') is distinct from 'string'
     or char_length(lp->>'title') not between 1 and 200 then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if lp ? 'description'
     and (jsonb_typeof(lp->'description') is distinct from 'string'
          or char_length(lp->>'description') > 400) then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if lp ? 'site'
     and (jsonb_typeof(lp->'site') is distinct from 'string'
          or char_length(lp->>'site') > 100) then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  -- Text only, never markup.
  if lp->>'title' ~ '[[:cntrl:]<>\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'
     or coalesce(lp->>'description', '') ~ '[[:cntrl:]<>\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'
     or coalesce(lp->>'site', '') ~ '[[:cntrl:]<>\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  if lp ? 'image'
     and (jsonb_typeof(lp->'image') is distinct from 'string'
          or lp->>'image' is distinct from new.conversation_id::text || '/' || new.id::text || '.jpg'
          or not exists (select 1 from storage.objects o
                          where o.bucket_id = 'link-previews' and o.name = lp->>'image'
                            and o.owner_id = new.sender_id::text)) then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if lp ? 'video' and jsonb_typeof(lp->'video') is distinct from 'boolean' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  -- The card must describe a link the message really contains, as a WHOLE
  -- link: after the start, whitespace, an opening bracket or a quote (with or
  -- without the scheme), and before whitespace, the end or closing punctuation.
  -- The url is regex-escaped first so its dots and symbols match literally.
  if coalesce(new.body, '') !~* (
       '(^|[[:space:](<"''])(https?://)?'
       || regexp_replace(
            regexp_replace(lp->>'url', '^https?://', '', 'i'),
            '([.^$*+?()|{}\[\]\\])', '\\\1', 'g')
       || '[.,;:!?)>"'']*([[:space:]]|$)') then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  -- A card rides on a plain text message only.
  if new.attachment_path is not null or new.sticker_id is not null
     or new.sticker_album or new.poll or new.contact
     or new.location_lat is not null or new.deleted is not null then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  return new;
end $$;

-- notification_action as in 20261006120000, plus: a reply into a conversation
-- that holds ciphertext is refused (42501); the typed text would go in plain.
create or replace function public.notification_action(
  p_user         uuid,
  p_device       text,
  p_conversation uuid,
  p_action       text,
  p_id           uuid,
  p_body         text
) returns text language plpgsql security definer set search_path = '' as $$
declare
  b       text := btrim(p_body);
  n       int;
  result  text := 'done';
begin
  if p_action is null or p_action not in ('mark_read', 'reply') then
    raise exception 'invalid action' using errcode = '22023';
  end if;
  if p_action = 'reply'
     and (p_id is null or b is null or char_length(b) not between 1 and 4000) then
    raise exception 'invalid reply' using errcode = '22023';
  end if;

  perform app_private.act_as(p_user, p_device);
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  -- One member's actions are counted one at a time (as messages_bot_rate), so
  -- two parallel calls cannot both see 19 and pass.
  perform pg_advisory_xact_lock(hashtextextended('notification_action:' || p_user::text, 0));
  delete from app_private.notification_action_log l
   where l.user_id = p_user and l.at < now() - interval '1 minute';
  select count(*) into n from app_private.notification_action_log l
   where l.user_id = p_user;
  if n >= 20 then
    raise exception 'rate limited' using errcode = 'P0429';
  end if;
  insert into app_private.notification_action_log(user_id) values (p_user);

  if p_action = 'reply' then
    if not app_private.is_member(p_conversation)
       or app_private.is_system_conversation(p_conversation) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
    if exists (select 1 from public.messages m
                where m.conversation_id = p_conversation and m.ciphertext is not null) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
    insert into public.messages(id, conversation_id, sender_id, body)
    values (p_id, p_conversation, p_user, b)
    on conflict (id) do nothing;
    if not found then
      if not exists (select 1 from public.messages m
                      where m.id = p_id and m.sender_id = p_user
                        and m.conversation_id = p_conversation and m.body = b) then
        raise exception 'id in use' using errcode = '23505';
      end if;
      result := 'duplicate';
    end if;
  end if;

  -- Replying reads the chat, as it does in the app. Also the whole of
  -- 'mark_read'; it raises 42501 itself for a non-member.
  perform public.mark_read(p_conversation);
  return result;
end $$;

-- search_messages as in 20260929120000, plus: ciphertext rows are never matched
-- (their body is only the placeholder).
create or replace function public.search_messages(query text, conversation uuid default null)
returns table (
  id uuid, conversation_id uuid, sender_id uuid, body text, created_at timestamptz,
  attachment_path text, attachment_preview text, deleted text, reply_to uuid,
  forwarded boolean, edited_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select m.id, m.conversation_id, m.sender_id, m.body, m.created_at,
         m.attachment_path, m.attachment_preview, m.deleted, m.reply_to,
         m.forwarded, m.edited_at
    from public.messages m
   where (select app_private.has_app_access())
     and (conversation is null or (select app_private.was_member(conversation)))
     and m.conversation_id = any (
           array(select cm.conversation_id from public.conversation_members cm
                  where cm.user_id = auth.uid())
         )
     and app_private.message_readable(m.*)
     and char_length(regexp_replace(query, '[^[:alnum:]]', '', 'g')) >= 3
     and m.deleted is null
     and m.ciphertext is null
     and (conversation is null or m.conversation_id = conversation)
     and m.search_text like (select '%' || public.escape_like(public.fold_search(btrim(query))) || '%') escape '\'
   order by m.created_at desc
   limit 50
$$;

-- Push: the delivery list gains `encrypted` (a ciphertext row). The return type
-- changes, so both functions are recreated (as 20261020120000_notification_photo.sql).
-- Otherwise push_targets_for_message is 20261023120000 unchanged: the body text
-- of a ciphertext row is the placeholder, which is what the push may show.
drop function public.push_targets(uuid);
drop function app_private.push_targets_for_message(uuid);

create function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer, thumb_path text, thumb_video boolean,
               encrypted boolean)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end)
           else coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end) || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' then 'New message'
           when m.sticker_id is not null then '😀 Sticker'
           when m.sticker_album then '📂 Sticker album'
           when m.attachment_mime = 'audio/mp4'
                and m.attachment_duration_ms is not null
                and btrim(m.body) = ''
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
              else coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end) end,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else c.title end,
         app_private.unread_total(cm.user_id),
         case when coalesce(ns.preview, 'full') = 'full'
                and m.sticker_id is null
                and m.attachment_path is not null
                and (m.attachment_name is null
                     or (m.attachment_mime ~ '^video/' and m.attachment_duration_ms is not null))
              then m.attachment_path || '.t' end,
         coalesce(m.attachment_mime ~ '^video/' and m.attachment_duration_ms is not null, false),
         m.ciphertext is not null
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
revoke all on function app_private.push_targets_for_message(uuid)
  from public, anon, authenticated;

create function public.push_targets(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer, thumb_path text, thumb_video boolean,
               encrypted boolean)
language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into app_private.push_sent(message_id)
  select m.id from public.messages m
   where m.id = push_targets.message_id
     and m.created_at > now() - interval '2 minutes'
  on conflict do nothing;
  if not found then
    return;
  end if;
  return query select * from app_private.push_targets_for_message(push_targets.message_id);
end $$;
revoke all on function public.push_targets(uuid) from public, anon, authenticated;
grant execute on function public.push_targets(uuid) to service_role;
