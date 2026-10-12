-- Photo push pictures. The thumbnail object is `<attachment path>.t` (photos get
-- one from the sender, videos already have one). The path is returned only for
-- recipients whose preview setting is 'full', so a chat set to show no content
-- never leaks a picture. Muted and archived chats are already excluded by the
-- where clause. The return type changes, so both functions are recreated.

drop function public.push_targets(uuid);
drop function app_private.push_targets_for_message(uuid);

create function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer, thumb_path text, thumb_video boolean)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, 'Someone')
           else coalesce(p.display_name, 'Someone') || coalesce(' @ ' || c.title, '')
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
              else coalesce(p.display_name, 'Someone') end,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else c.title end,
         app_private.unread_total(cm.user_id),
         case when coalesce(ns.preview, 'full') = 'full'
                and m.sticker_id is null
                and m.attachment_path is not null
                and (m.attachment_name is null
                     or (m.attachment_mime ~ '^video/' and m.attachment_duration_ms is not null))
              then m.attachment_path || '.t' end,
         coalesce(m.attachment_mime ~ '^video/' and m.attachment_duration_ms is not null, false)
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
               sender text, chat text, badge integer, thumb_path text, thumb_video boolean)
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

-- attachment_readable as in 20261014120000, plus: the small picture of a PHOTO
-- (a message with no file name) is readable exactly when that message is, so a
-- member who forwards a photo can copy its picture along. A video's was already
-- covered (attachment_duration_ms is not null).
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
              and (m.attachment_duration_ms is not null or m.attachment_name is null)
              and app_private.message_readable(m.*)
         ));
end $$;
revoke all on function app_private.attachment_readable(text, text) from public, anon;
grant execute on function app_private.attachment_readable(text, text) to authenticated;
