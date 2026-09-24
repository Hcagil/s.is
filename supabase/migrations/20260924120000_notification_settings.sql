-- v0.8: notification settings, mutes, and the trigger that sends.
--
-- Settings and mutes are private to their member: unlike the sharing
-- switches on profiles, nobody else needs to read them, so they live in their
-- own tables with own-row policies. A missing settings row means the
-- defaults: notifications on, full preview.

create table public.notification_settings (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  enabled    boolean not null default true,
  -- What the lock screen shows: 'full' = sender and text, 'sender' = only
  -- who wrote, 'none' = only that there is a new message.
  preview    text not null default 'full' check (preview in ('full', 'sender', 'none')),
  updated_at timestamptz not null default now()
);
alter table public.notification_settings enable row level security;
revoke all on table public.notification_settings from anon, authenticated;
grant select, insert, update on table public.notification_settings to authenticated;

create policy notification_settings_own on public.notification_settings
  for all to authenticated
  using (app_private.has_app_access() and user_id = (select auth.uid()))
  with check (app_private.has_app_access() and user_id = (select auth.uid()));

-- A mute silences one conversation, or one person in every conversation.
-- until null = always; a passed until is simply no longer a mute.
create table public.notification_mutes (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind    text not null check (kind in ('conversation', 'person')),
  target  uuid not null,
  until   timestamptz,
  primary key (user_id, kind, target)
);
alter table public.notification_mutes enable row level security;
revoke all on table public.notification_mutes from anon, authenticated;
grant select, insert, update, delete on table public.notification_mutes to authenticated;

create policy notification_mutes_read on public.notification_mutes
  for select to authenticated
  using (app_private.has_app_access() and user_id = (select auth.uid()));
create policy notification_mutes_delete on public.notification_mutes
  for delete to authenticated
  using (app_private.has_app_access() and user_id = (select auth.uid()));
-- A mute may name only a conversation the member is in, or another member
-- they could see anyway: a mute row must not become a way to probe ids.
create policy notification_mutes_write on public.notification_mutes
  for insert to authenticated
  with check (app_private.has_app_access()
              and user_id = (select auth.uid())
              and case kind
                    when 'conversation' then app_private.is_member(target)
                    when 'person' then target <> (select auth.uid())
                                       and app_private.is_allowed(target)
                  end);
create policy notification_mutes_change on public.notification_mutes
  for update to authenticated
  using (app_private.has_app_access() and user_id = (select auth.uid()))
  with check (app_private.has_app_access()
              and user_id = (select auth.uid())
              and case kind
                    when 'conversation' then app_private.is_member(target)
                    when 'person' then target <> (select auth.uid())
                                       and app_private.is_allowed(target)
                  end);

-- Who should hear about a message, now also honouring each recipient's
-- settings and mutes, and carrying what the notification may show. The
-- return type changes, so both functions are recreated.
drop function public.push_targets(uuid);
drop function app_private.push_targets_for_message(uuid);

create function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text)
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
         end
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
revoke all on function app_private.push_targets_for_message(uuid)
  from public, anon, authenticated;

-- Each message is sent at most once, and only while it is news. The sender
-- is reachable without a JWT (a database trigger calls it), so a replayed or
-- forged call must not be able to notify anyone twice or dig up old messages.
create table app_private.push_sent (
  message_id uuid primary key references public.messages(id) on delete cascade,
  sent_at    timestamptz not null default now()
);
alter table app_private.push_sent enable row level security;  -- no policies: no access
revoke all on table app_private.push_sent from anon, authenticated;

-- The sender's one entry point, on the service-role key. It claims the
-- message first: a second call for the same message, or a call for one older
-- than two minutes, gets nobody to notify.
create function public.push_targets(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text)
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

-- The trigger that sends. It hands the sender only the message id: the
-- sender reads everything else itself, so the request carries nothing worth
-- forging. The URL lives in Vault per environment; where it is not set
-- (local, CI) nothing is sent. pg_net queues the request, so the insert
-- never waits on the network.
create extension if not exists pg_net with schema extensions;

create function app_private.notify_new_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  url text;
begin
  select decrypted_secret into url
    from vault.decrypted_secrets where name = 'notify_on_message_url';
  if url is not null then
    perform net.http_post(
      url := url,
      body := jsonb_build_object('record', jsonb_build_object('id', new.id)),
      headers := '{"content-type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000);
  end if;
  return null;
exception when others then
  -- A bad URL or a missing Vault must cost a notification, never the
  -- message: net.http_post validates the URL synchronously and would
  -- otherwise abort the insert.
  raise warning 'notify_new_message: %', sqlerrm;
  return null;
end $$;
revoke all on function app_private.notify_new_message() from public, anon, authenticated;

create trigger messages_notify after insert on public.messages
  for each row execute function app_private.notify_new_message();
