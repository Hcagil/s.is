-- Grouped notifications (v0.12) without leaving older app builds silent.
--
-- From 0.12 the app shows pushes itself, grouped into one SIS notification,
-- so it wants data-only pushes. A build from before that has no code to show
-- a data-only push and would go quiet until updated -- and updates are never
-- forced. So each device says, when it registers, whether it shows pushes
-- itself; the sender sends data only to those, and a regular notification to
-- every other device, exactly as before.

alter table app_private.device_tokens
  add column shows_itself boolean not null default false;

-- Older builds keep calling it with two arguments: the default keeps them
-- on regular notifications. Dropped first because a new signature would
-- otherwise sit next to the old one and make a two-argument call ambiguous.
drop function public.register_device_token(text, text);

create function public.register_device_token(
  device_token    text,
  device_platform text,
  shows_itself    boolean default false
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if device_token is null
     or char_length(device_token) < 10 or char_length(device_token) > 4096
     or device_platform is null
     or device_platform not in ('android', 'ios') then
    raise exception 'invalid device token' using errcode = '22023';
  end if;

  -- One row per member: the single-active-device rule, extended to push.
  delete from app_private.device_tokens d
   where d.user_id = auth.uid() and d.token <> device_token;
  -- A token identifies a handset, not a person. If someone else signs in on
  -- this handset, the previous member must stop receiving message bodies on
  -- it -- otherwise signing out and handing the phone over leaks them.
  delete from app_private.device_tokens d
   where d.token = device_token and d.user_id <> auth.uid();

  insert into app_private.device_tokens(user_id, token, platform, shows_itself)
  values (auth.uid(), device_token, device_platform,
          coalesce(register_device_token.shows_itself, false))
  on conflict (user_id, token) do update
    set platform = excluded.platform, shows_itself = excluded.shows_itself,
        updated_at = now();
end $$;
revoke all on function public.register_device_token(text, text, boolean) from public, anon;
grant execute on function public.register_device_token(text, text, boolean) to authenticated;

drop function public.push_targets(uuid);
drop function app_private.push_targets_for_message(uuid);

create function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean)
language sql stable security definer set search_path = '' as $$
  -- What the lock screen shows, by the recipient's own preview setting:
  -- 'full' = who and what (a group adds its name), 'sender' = only the
  -- person, 'none' = only that there is something.
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
         d.shows_itself
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id <> m.sender_id
    join app_private.device_tokens d on d.user_id = cm.user_id
    join app_private.active_sessions s on s.user_id = cm.user_id
    -- The session must still EXIST, exactly as has_app_access() requires:
    -- active_sessions outlives the session it names.
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
    left join public.profiles p on p.user_id = m.sender_id
    left join public.notification_settings ns on ns.user_id = cm.user_id
   where m.id = message_id
     -- Deleted before the sender got to it: nothing to announce.
     and m.deleted is null
     -- Taken off the allowlist = no more message text on their lock screen,
     -- even while their session and token still exist (has_app_access()
     -- checks both, and so must this).
     and app_private.is_allowed(cm.user_id)
     and coalesce(ns.enabled, true)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = cm.user_id
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;
revoke all on function app_private.push_targets_for_message(uuid) from public, anon, authenticated;

create function public.push_targets(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean)
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
