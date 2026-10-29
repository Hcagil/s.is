-- A private (encrypted) message's push body is now the plain words 'New message'
-- instead of the stored placeholder ('🔒 Encrypted message'): no lock words in any
-- notification text (owner 2026-10-29). It covers an iPhone whose notification
-- extension did not run and older Android builds. The function is the one from
-- 20261103120000_push_prekey_sender_key.sql with one CASE arm added first; same
-- return type, so create or replace works. push_targets (the wrapper) is unchanged.
-- Still unreachable for clients: the grants are repeated unchanged.
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
           when 'sender' then coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end)
           else coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end) || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' or m.ciphertext is not null then 'New message'
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
