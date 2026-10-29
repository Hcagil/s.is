-- Reaction notifications, server side (owner 2026-10-29): a push to the author of a
-- message when someone sets or changes a reaction on it. Sent only from the two
-- 'user tapped an emoji' RPCs (never from relock_reaction, a clear, or a bulk update).
-- A private chat never gets emoji, quote or quote_kind from the server: its push
-- carries the reaction's ciphertext and the phone opens it in memory.
-- Harmless alone: no device has reaction_push until a build that draws reactions sets it.

-- 1a. Capability: an old build must never draw a reaction as a message.
alter table app_private.device_tokens add column reaction_push boolean not null default false;

-- Dropped first: a new signature next to the old one would make a 2- or 3-argument call ambiguous.
drop function public.register_device_token(text, text, boolean);
create function public.register_device_token(
  device_token    text,
  device_platform text,
  shows_itself    boolean default false,
  reaction_push   boolean default false
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if device_token is null
     or char_length(device_token) < 10 or char_length(device_token) > 4096
     or device_platform is null
     or device_platform not in ('android', 'ios') then
    raise exception 'invalid device token' using errcode = '22023';
  end if;
  delete from app_private.device_tokens d
   where d.user_id = auth.uid() and d.token <> device_token;
  delete from app_private.device_tokens d
   where d.token = device_token and d.user_id <> auth.uid();
  insert into app_private.device_tokens(user_id, token, platform, shows_itself, session_id, reaction_push)
  values (auth.uid(), device_token, device_platform,
          coalesce(register_device_token.shows_itself, false),
          app_private.jwt_session_id(),
          coalesce(register_device_token.reaction_push, false))
  on conflict (user_id, token) do update
    set platform = excluded.platform, shows_itself = excluded.shows_itself,
        session_id = excluded.session_id, reaction_push = excluded.reaction_push,
        updated_at = now();
end $$;
revoke all on function public.register_device_token(text, text, boolean, boolean) from public, anon;
grant execute on function public.register_device_token(text, text, boolean, boolean) to authenticated;

-- 1b. Log and limit table: no policies, no client grants.
create table app_private.reaction_push_log (
  message_id   uuid not null references public.messages(id) on delete cascade,
  reactor_id   uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  reacted_at   timestamptz not null,
  sent_at      timestamptz not null default now(),
  primary key (message_id, reactor_id, reacted_at));
create index reaction_push_log_pair_idx on app_private.reaction_push_log (reactor_id, recipient_id, sent_at);
create index reaction_push_log_recipient_idx on app_private.reaction_push_log (recipient_id);
alter table app_private.reaction_push_log enable row level security;
revoke all on table app_private.reaction_push_log from public, anon, authenticated;

-- 1c. Sending: ids only, same transport as notify_new_message; never fails the caller.
create function app_private.notify_reaction(message uuid, reactor uuid) returns void language plpgsql security definer set search_path = '' as $$
declare url text;
begin
  select decrypted_secret into url
    from vault.decrypted_secrets
   where name = 'notify_on_message_url';
  if url is not null then
    perform net.http_post(url := url,
      body := jsonb_build_object('reaction', jsonb_build_object('message_id', message, 'user_id', reactor)),
      headers := '{"content-type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000);
  end if;
  return;
exception when others then
  raise warning 'notify_reaction: %', sqlerrm;
  return;
end $$;
revoke all on function app_private.notify_reaction(uuid, uuid) from public, anon, authenticated;

-- 1d. Who and what.
create function app_private.reaction_push_targets_for(message_id uuid, reactor uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid, title text, body text, sender text, chat text, emoji text, quote text, quote_kind text, ciphertext text, olm_type smallint, encrypted boolean)
language sql stable security definer set search_path = '' as $$
    select
      m.sender_id as user_id,
      d.token,
      d.platform,
      m.conversation_id,
      case
        when coalesce(ns.preview,'full') = 'none' then 'SIS'
        when coalesce(ns.preview,'full') = 'sender' then coalesce(p.display_name,'Someone')
        else coalesce(p.display_name,'Someone') || coalesce(' @ ' || c.title, '')
      end as title,
      'New reaction to your message' as body,
      case when coalesce(ns.preview,'full') = 'none' then null else coalesce(p.display_name,'Someone') end as sender,
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

-- 1e. Claim.
create function public.reaction_push_targets(message_id uuid, reactor uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid, title text, body text, sender text, chat text, emoji text, quote text, quote_kind text, ciphertext text, olm_type smallint, encrypted boolean)
language plpgsql volatile security definer set search_path = '' as $$
declare
  r public.message_reactions;
  recipient uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('reaction_push:' || reaction_push_targets.reactor::text, 0));
  delete from app_private.reaction_push_log l where l.sent_at < now() - interval '24 hours';
  select * into r from public.message_reactions mr where mr.message_id = reaction_push_targets.message_id and mr.user_id = reaction_push_targets.reactor;
  if not found or r.updated_at <= now() - interval '2 minutes' then return; end if;
  recipient := (select m.sender_id from public.messages m where m.id = reaction_push_targets.message_id);
  if recipient is null then return; end if;
  if (select count(*) from app_private.reaction_push_log l where l.message_id = reaction_push_targets.message_id and l.reactor_id = reaction_push_targets.reactor and l.sent_at > now() - interval '10 minutes') >= 3 then return; end if;
  if (select count(*) from app_private.reaction_push_log l where l.reactor_id = reaction_push_targets.reactor and l.recipient_id = recipient and l.sent_at > now() - interval '10 minutes') >= 10 then return; end if;
  if (select count(*) from app_private.reaction_push_log l where l.reactor_id = reaction_push_targets.reactor and l.recipient_id = recipient and l.sent_at > now() - interval '60 minutes') >= 30 then return; end if;
  insert into app_private.reaction_push_log(message_id, reactor_id, recipient_id, reacted_at) values (reaction_push_targets.message_id, reaction_push_targets.reactor, recipient, r.updated_at) on conflict do nothing;
  if not found then return; end if;
  return query select * from app_private.reaction_push_targets_for(reaction_push_targets.message_id, reaction_push_targets.reactor);
end $$;
revoke all on function public.reaction_push_targets(uuid, uuid) from public, anon, authenticated;
grant execute on function public.reaction_push_targets(uuid, uuid) to service_role;

-- 1c (cont). The two RPCs.
create or replace function public.set_reaction(message uuid, emoji text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
  locked_at timestamptz;
  old_emoji text;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.deleted is not null
     or not app_private.is_member(m.conversation_id)
     or not app_private.message_readable(m)
     or app_private.is_system_conversation(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if emoji is null then
    update public.message_reactions r set emoji = null, ciphertext = null, olm_type = null, updated_at = now() where r.message_id = message and r.user_id = auth.uid() and (r.emoji is not null or r.ciphertext is not null);
    return;
  end if;
  -- No plain set once the chat is encrypted. The conversation row is share-locked unconditionally (a condition in the WHERE would lock nothing while encrypted_at is null), so a first locked message or reaction that is still running is waited for.
  select c.encrypted_at into locked_at from public.conversations c where c.id = m.conversation_id for share;
  if locked_at is not null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if octet_length(emoji) not between 1 and 64 or emoji ~ '[[:space:][:cntrl:]]' then
    raise exception 'invalid emoji' using errcode = '22023';
  end if;
  if app_private.is_bot(auth.uid()) then
    perform app_private.bot_send_charge(auth.uid());
  end if;
  select r.emoji into old_emoji from public.message_reactions r where r.message_id = message and r.user_id = auth.uid() for update;
  insert into public.message_reactions(message_id, user_id, conversation_id, emoji)
  values (message, auth.uid(), m.conversation_id, emoji)
  on conflict (message_id, user_id)
  do update set emoji = excluded.emoji, ciphertext = null, olm_type = null, updated_at = now();
  -- A retry with the same emoji sends nothing.
  if old_emoji is distinct from emoji then
    perform app_private.notify_reaction(message, auth.uid());
  end if;
end $$;
revoke all on function public.set_reaction(uuid, text) from public, anon;
grant execute on function public.set_reaction(uuid, text) to authenticated;

create or replace function public.set_reaction_encrypted(message uuid, ciphertext text, olm_type smallint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
  old_ct text;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found or m.deleted is not null or not app_private.is_member(m.conversation_id) or not app_private.message_readable(m) or app_private.is_system_conversation(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.is_bot(auth.uid()) or not app_private.chat_lockable(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if ciphertext is null or char_length(ciphertext) not between 1 and 1024 or olm_type is null or olm_type not in (0, 1) then
    raise exception 'invalid ciphertext' using errcode = '22023';
  end if;
  update public.conversations set encrypted_at = coalesce(encrypted_at, now()) where id = m.conversation_id;
  select r.ciphertext into old_ct from public.message_reactions r where r.message_id = message and r.user_id = auth.uid() for update;
  insert into public.message_reactions(message_id, user_id, conversation_id, ciphertext, olm_type)
  values (message, auth.uid(), m.conversation_id, ciphertext, olm_type)
  on conflict (message_id, user_id)
  do update set emoji = null, ciphertext = excluded.ciphertext, olm_type = excluded.olm_type, updated_at = now();
  -- A network retry inside one tap reuses the same bytes and sends nothing.
  if old_ct is distinct from ciphertext then
    perform app_private.notify_reaction(message, auth.uid());
  end if;
end $$;
revoke all on function public.set_reaction_encrypted(uuid, text, smallint) from public, anon;
grant execute on function public.set_reaction_encrypted(uuid, text, smallint) to authenticated;
