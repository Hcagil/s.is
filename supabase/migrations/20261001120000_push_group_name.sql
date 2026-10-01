-- A group's notification names the group, WhatsApp style.
--
-- The delivery list now also says who sent the message and which group it
-- is in, as separate fields, so each platform words its own notification:
-- an iPhone's alert (drawn by the system from the FCM notification block)
-- takes the group name as its title and "Sender: message" as its body, and
-- Android's app takes them as data for its MessagingStyle lines. `title` and
-- `body` are unchanged, so builds that parse them keep working.
--
-- What each field reveals follows the recipient's own preview setting:
-- 'full' and 'sender' carry the sender's name and a group's name (a group's
-- name is "where from", next to "who from"); 'none' carries neither. `chat`
-- is null for a 1:1 and for 'none'; `sender` is null for 'none'.
--
-- The return type changes, so both functions are recreated. Same body as
-- 20260930160000_push_token_session.sql plus the two columns.

drop function public.push_targets(uuid);
drop function app_private.push_targets_for_message(uuid);

create function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, 'Someone')
           else coalesce(p.display_name, 'Someone') || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' then 'New message'
           when btrim(m.body) = '' and m.attachment_path is not null then '📷 Photo'
           else case when m.attachment_path is not null then '📷 ' else '' end
                || case when char_length(btrim(m.body)) <= 120 then btrim(m.body)
                        else left(btrim(m.body), 119) || '…' end
         end,
         d.shows_itself,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else coalesce(p.display_name, 'Someone') end,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else c.title end
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
               sender text, chat text)
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
