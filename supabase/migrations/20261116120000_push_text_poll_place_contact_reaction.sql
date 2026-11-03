-- Push texts in the receiver's app language, part 2 (profiles.app_language: 'en' English,
-- 'tr' or null Turkish; same switch as 20261108120000_push_text_by_language.sql).
--  * Message push: a poll, a place and a contact get their own text instead of the stored body
--    (poll body = the question; place body = name + address; contact body = name + phone, so
--    only the first line, the name, is used and the phone number never leaves in a push).
--  * Reaction push: body, title and sender follow the language of the person who gets the push.
-- Both functions keep their return types, so create or replace works. Only text expressions
-- change, plus a left join on the receiver's profile (rp). The grants are repeated unchanged:
-- still unreachable for clients.
create or replace function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer, thumb_path text, thumb_video boolean,
               ciphertext text, olm_type smallint, sender_key text, sender_id uuid,
               encrypted boolean)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else (case when rp.app_language = 'en' then 'Someone' else 'Biri' end) end)
           else coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else (case when rp.app_language = 'en' then 'Someone' else 'Biri' end) end) || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' or m.ciphertext is not null then (case when rp.app_language = 'en' then 'New message' else 'Yeni mesaj' end)
           when m.sticker_id is not null then (case when rp.app_language = 'en' then 'Sticker' else 'Çıkartma' end)
           when m.sticker_album then (case when rp.app_language = 'en' then 'Sticker album' else 'Çıkartma albümü' end)
           when m.poll then (case when rp.app_language = 'en' then 'Poll: ' else 'Anket: ' end) || case when char_length(btrim(m.body)) <= 120 then btrim(m.body) else left(btrim(m.body), 119) || '…' end
           when m.location_lat is not null then (case when rp.app_language = 'en' then 'Location' else 'Konum' end)
           when m.contact then (case when rp.app_language = 'en' then 'Contact: ' else 'Kişi: ' end) || split_part(btrim(m.body), E'\n', 1)
           when m.attachment_mime = 'audio/mp4'
                and m.attachment_duration_ms is not null
                and btrim(m.body) = ''
             then (case when rp.app_language = 'en' then 'Voice message' else 'Sesli mesaj' end)
           when m.attachment_duration_ms is not null and btrim(m.body) = ''
             then 'Video'
           when m.attachment_name is not null and btrim(m.body) = ''
             then (case when rp.app_language = 'en' then 'File: ' else 'Dosya: ' end) || case when char_length(m.attachment_name) <= 100 then m.attachment_name
                                else left(m.attachment_name, 99) || '…' end
           when btrim(m.body) = '' and m.attachment_path is not null then (case when rp.app_language = 'en' then 'Photo' else 'Fotoğraf' end)
           else case when char_length(btrim(m.body)) <= 120 then btrim(m.body)
                        else left(btrim(m.body), 119) || '…' end
         end,
         d.shows_itself,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else (case when rp.app_language = 'en' then 'Someone' else 'Biri' end) end) end,
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
         case when coalesce(ns.preview, 'full') = 'full' then m.ciphertext end,
         case when coalesce(ns.preview, 'full') = 'full' then m.olm_type end,
         case when coalesce(ns.preview, 'full') = 'full'
                and m.ciphertext is not null and m.olm_type = 0
              then k.identity_key end,
         case when coalesce(ns.preview, 'full') = 'full'
                and m.ciphertext is not null and m.olm_type = 0
                and k.identity_key is not null
              then m.sender_id end,
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
    left join public.profiles rp on rp.user_id = cm.user_id
    left join lateral (
      select od.identity_key
        from app_private.olm_devices od
        join app_private.active_sessions s2
          on s2.user_id = od.user_id and s2.session_id = od.session_id
        join auth.sessions x2 on x2.id = s2.session_id and x2.user_id = s2.user_id
       where od.user_id = m.sender_id
         and not app_private.is_bot(m.sender_id)
         and app_private.is_allowed(m.sender_id)
    ) k on true
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

create or replace function app_private.reaction_push_targets_for(message_id uuid, reactor uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid, title text, body text, sender text, chat text, emoji text, quote text, quote_kind text, ciphertext text, olm_type smallint, encrypted boolean)
language sql stable security definer set search_path = '' as $$
    select
      m.sender_id as user_id,
      d.token,
      d.platform,
      m.conversation_id,
      case
        when coalesce(ns.preview,'full') = 'none' then 'SIS'
        when coalesce(ns.preview,'full') = 'sender' then coalesce(p.display_name, case when rp.app_language = 'en' then 'Someone' else 'Biri' end)
        else coalesce(p.display_name, case when rp.app_language = 'en' then 'Someone' else 'Biri' end) || coalesce(' @ ' || c.title, '')
      end as title,
      case when rp.app_language = 'en' then 'New reaction to your message' else 'Mesajınıza yeni tepki' end as body,
      case when coalesce(ns.preview,'full') = 'none' then null else coalesce(p.display_name, case when rp.app_language = 'en' then 'Someone' else 'Biri' end) end as sender,
      case when coalesce(ns.preview,'full') = 'none' then null else c.title end as chat,
      case
        when coalesce(ns.preview,'full') = 'full'
          and r.ciphertext is null
          and m.ciphertext is null
          and c.encrypted_at is null
        then r.emoji
        else null
      end as emoji,
      case
        when coalesce(ns.preview,'full') = 'full'
          and r.ciphertext is null
          and m.ciphertext is null
          and c.encrypted_at is null
          and btrim(m.body) <> ''
        then
          case
            when char_length(btrim(m.body)) > 60 then left(btrim(m.body), 60) || '…'
            else btrim(m.body)
          end
        else null
      end as quote,
      case
        when coalesce(ns.preview,'full') = 'full'
          and r.ciphertext is null
          and m.ciphertext is null
          and c.encrypted_at is null
        then
          case
            when m.sticker_id is not null then 'sticker'
            when m.attachment_mime = 'audio/mp4' and m.attachment_duration_ms is not null and btrim(m.body) = '' then 'voice'
            when m.attachment_duration_ms is not null and btrim(m.body) = '' then 'video'
            when m.attachment_name is not null and btrim(m.body) = '' then 'file'
            when btrim(m.body) = '' and m.attachment_path is not null then 'photo'
          end
        else null
      end as quote_kind,
      case
        when coalesce(ns.preview,'full') = 'full'
          and r.ciphertext is not null
        then r.ciphertext
        else null
      end as ciphertext,
      case
        when coalesce(ns.preview,'full') = 'full'
          and r.ciphertext is not null
        then r.olm_type
        else null
      end as olm_type,
      (r.ciphertext is not null or c.encrypted_at is not null) as encrypted
    from public.message_reactions r
    join public.messages m on m.id = reaction_push_targets_for.message_id and m.deleted is null
    join public.conversations c on c.id = m.conversation_id
    join public.conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = m.sender_id and cm.left_at is null
    join app_private.device_tokens d on d.user_id = m.sender_id and d.reaction_push
    join app_private.active_sessions s on s.user_id = d.user_id and s.session_id = d.session_id
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
    left join public.notification_settings ns on ns.user_id = m.sender_id
    left join public.profiles p on p.user_id = reaction_push_targets_for.reactor
    left join public.profiles rp on rp.user_id = m.sender_id
    where r.message_id = reaction_push_targets_for.message_id
      and r.user_id = reaction_push_targets_for.reactor
      and (r.emoji is not null or r.ciphertext is not null)
      and m.sender_id <> reaction_push_targets_for.reactor
      and app_private.is_allowed(m.sender_id)
      and app_private.is_allowed(reaction_push_targets_for.reactor)
      and not app_private.is_bot(reaction_push_targets_for.reactor)
      and coalesce(ns.enabled, true)
      and not exists (select 1 from public.chat_archives a where a.user_id = m.sender_id and a.conversation_id = m.conversation_id)
      and not exists (
        select 1 from public.notification_mutes mu
        where mu.user_id = m.sender_id
          and (mu.until is null or mu.until > now())
          and ((mu.kind='conversation' and mu.target = m.conversation_id) or (mu.kind='person' and mu.target = reaction_push_targets_for.reactor))
      )
      and not app_private.is_system_conversation(m.conversation_id)
      and exists (select 1 from public.conversation_members rm where rm.conversation_id = m.conversation_id and rm.user_id = reaction_push_targets_for.reactor and rm.left_at is null)
$$;
revoke all on function app_private.reaction_push_targets_for(uuid, uuid) from public, anon, authenticated;
