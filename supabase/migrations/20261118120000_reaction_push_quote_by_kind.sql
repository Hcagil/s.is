-- Reaction push quote follows the same kind rules as the message push (security finding LOW-2):
-- a place quotes only "Location"/"Konum" (never the address), a contact only its name (never the
-- phone number), a poll its question. Text, photo and other kinds are unchanged. Same return type,
-- so create or replace works; grants repeated unchanged (unreachable for clients).
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
          and (btrim(m.body) <> '' or m.location_lat is not null)
        then
          case
            when m.location_lat is not null then (case when rp.app_language = 'en' then 'Location' else 'Konum' end)
            when m.contact then (case when rp.app_language = 'en' then 'Contact: ' else 'Kişi: ' end) || left(split_part(btrim(m.body), E'\n', 1), 60)
            when m.poll then (case when rp.app_language = 'en' then 'Poll: ' else 'Anket: ' end) || case when char_length(btrim(m.body)) > 60 then left(btrim(m.body), 60) || '…' else btrim(m.body) end
            else case when char_length(btrim(m.body)) > 60 then left(btrim(m.body), 60) || '…' else btrim(m.body) end
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
