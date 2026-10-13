-- Admin chat: the owner types tester commands into a private chat with SIS Admin.
--
-- One conversation per owner, flagged system (so every "no client writes into
-- a system chat" rule already in the database applies to it) and admin_chat
-- (so the few things the owner may do there are named). The owner is the only
-- member; replies are written by a fixed account that cannot sign in. The
-- server learns who the owner is from app_private.owners and auth.uid(),
-- never from the app.
--
-- Replies carry a machine-readable admin_msg (a key plus values) next to an
-- English body; the app words the reply in its own language from the key.

alter table public.conversations
  add column admin_chat boolean not null default false;

-- Machine-readable reply: key k plus values; the app words it. body holds the English text.
alter table public.messages add column admin_msg jsonb;

-- Set at insert time on an escalation reply; notify_new_message lets only these
-- through in an admin chat. Neither column has an insert grant: clients never write them.
alter table public.messages add column admin_push boolean not null default false;

-- The author of every admin reply. messages.sender_id references auth.users,
-- so this is a real row: no email, so it is on no allowlist, can never sign in,
-- and has no profile (the profile the signup trigger makes is removed again).
-- Every column below must hold a value because GoTrue scans them into
-- non-nullable types (see 20260930120000_whats_new.sql). banned_until is finite:
-- GoTrue cannot scan 'infinity'. messages.sender_id cascades: deleting this
-- account deletes every admin reply, so it must never be deleted.
insert into auth.users (id, instance_id, aud, role,
                        confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        email_change_confirm_status,
                        phone_change, phone_change_token, reauthentication_token,
                        raw_app_meta_data, raw_user_meta_data,
                        is_sso_user, is_anonymous,
                        created_at, updated_at, banned_until)
values ('00000000-0000-0000-0000-00000000ad41', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        '', '',
        '', '', '',
        0,
        '', '', '',
        '{}', '{}',
        false, false,
        now(), now(), '2999-12-31 00:00:00+00')
on conflict (id) do nothing;
delete from public.profiles where user_id = '00000000-0000-0000-0000-00000000ad41';

-- At most one row: filled once by the release workflow or by the owner in the
-- SQL editor, never by the app.
create table app_private.owners (
  only_row   boolean primary key default true check (only_row),
  user_id    uuid not null unique references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

-- key play_optin_link holds the Play opt-in link.
create table app_private.admin_settings (
  key   text primary key,
  value text not null
);

-- Testers without a row are older ones, listed as Other.
create table app_private.tester_platform (
  email    text primary key references app_private.allowlist(email) on delete cascade,
  platform text not null check (platform in ('ios','android'))
);

-- Masked log of every command, kept forever. It never holds a full email.
create table app_private.admin_commands (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete restrict,
  at           timestamptz not null default now(),
  command      text not null,
  email_masked text,
  outcome      text not null,
  job_id       uuid
);
create index admin_commands_owner_at_idx on app_private.admin_commands (owner_id, at desc);

-- Apple TestFlight work. email is nulled when the job ends.
create table app_private.admin_jobs (
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null check (kind in ('add','remove')),
  email               text,
  email_masked        text not null,
  state               text not null default 'pending' check (state in ('pending','running','ok','failed')),
  attempts            integer not null default 0,
  progress_message_id uuid references public.messages(id) on delete set null,
  created_at          timestamptz not null default now(),
  finished_at         timestamptz
);

-- A /removetester confirmation. email is nulled when the card is answered or expires.
create table app_private.admin_pending (
  card_message_id uuid primary key references public.messages(id) on delete cascade,
  email           text,
  email_masked    text not null,
  expires_at      timestamptz not null,
  state           text not null default 'pending' check (state in ('pending','used','cancelled','expired'))
);

-- No policies and no grants: none of these is reachable from the API.
alter table app_private.owners          enable row level security;
alter table app_private.admin_settings  enable row level security;
alter table app_private.tester_platform enable row level security;
alter table app_private.admin_commands  enable row level security;
alter table app_private.admin_jobs      enable row level security;
alter table app_private.admin_pending   enable row level security;
revoke all on app_private.owners, app_private.admin_settings, app_private.tester_platform,
  app_private.admin_commands, app_private.admin_jobs, app_private.admin_pending
  from public, anon, authenticated;

-- Helpers -------------------------------------------------------------------
-- True when the caller is the owner. No argument: it can only answer for the
-- caller, so it cannot be used to probe other users.
create or replace function app_private.is_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.owners o where o.user_id = (select auth.uid()))
$$;
revoke all on function app_private.is_owner() from public, anon;
grant execute on function app_private.is_owner() to authenticated;

create or replace function app_private.is_admin_chat(conversation uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversations c where c.id = conversation and c.admin_chat)
$$;
revoke all on function app_private.is_admin_chat(uuid) from public, anon;
grant execute on function app_private.is_admin_chat(uuid) to authenticated;

-- English text of a /listtesters reply.
create or replace function app_private.admin_body_list(msg jsonb) returns text
language sql immutable set search_path = '' as $$
  with g(ord, title, key, force) as (
    values (1,'iPhone','ios',true),(2,'Android','and',true),(3,'Other','oth',false)
  )
  select 'Testers: ' || coalesce(msg->>'n','0') || coalesce(
    E'\n\n' || string_agg(
      title || ' (' || cardinality(arr) || ')' ||
      case when cardinality(arr) = 0 then '' else E'\n' || array_to_string(arr, E'\n') end,
      E'\n\n' order by ord),
    '')
  from (
    select g.*, array(select jsonb_array_elements_text(
      case when jsonb_typeof(msg->g.key) = 'array' then msg->g.key else '[]'::jsonb end)) as arr
    from g
  ) x
  where force or cardinality(arr) > 0
$$;
revoke all on function app_private.admin_body_list(jsonb) from public, anon, authenticated;

-- English text of a reply, from its machine-readable form. The app words the
-- reply in its own language from msg->>'k'; this text is the fallback.
create or replace function app_private.admin_body(msg jsonb) returns text
language sql immutable set search_path = '' as $$
  select btrim(case msg->>'k'
    when 'unk' then 'I don''t know that command.'
    when 'noem' then 'That command needs an email address.'
    when 'bad' then 'That email address doesn''t look right.'
    when 'iosOk' then 'Added ' || coalesce(msg->>'e','') || ' to the allowlist. Apple will email the invite. Tell them to sign in with the same email.'
    when 'p1' then 'Sending the invite to Apple...'
    when 'p2' then 'Apple is slow. Trying again (2 of 3)...'
    when 'p3' then 'Apple accepted. The invite email is on its way.'
    when 'fail' then 'Apple step failed: ' || coalesce(msg->>'r','') || '. The allowlist row is saved; type the command again to retry.'
    when 'andOk' then 'Added ' || coalesce(msg->>'e','') || ' to the allowlist. One step by hand: add this email to Play Console > Internal testing > Testers > Bacanaks.'
    when 'fwd' then 'Hi! You can test SIS on Android now.' || E'\n' || '1. Open this link and accept the invite: ' || coalesce(msg->>'l','') || E'\n' || '2. Install SIS from Google Play.' || E'\n' || '3. Sign in with this email: ' || coalesce(msg->>'e','')
    when 'conf' then 'Remove this tester? ' || coalesce(msg->>'e','') || ' loses access to SIS.'
    when 'rmOk' then 'Removed ' || coalesce(msg->>'e','') || ' from the allowlist. Now remove it by hand in Play: Play Console > Internal testing > Testers > Bacanaks > delete this email.'
    when 'canOk' then 'Cancelled. Nothing was removed.'
    when 'nolist' then coalesce(msg->>'e','') || ' is not on the tester list.'
    when 'r1' then 'Removing ' || coalesce(msg->>'e','') || ' from the TestFlight group...'
    when 'r3' then 'Removed from TestFlight.'
    when 'failRm' then 'Apple step failed: ' || coalesce(msg->>'r','') || '. The allowlist row is already removed; type the command again to retry.'
    when 'list' then app_private.admin_body_list(msg)
    when 'rate' then 'Too many commands. Wait a minute and try again.'
    when 'keep' then 'Cancelled: this card is no longer valid.'
    when 'err' then 'Something went wrong. Nothing was changed.'
    when 'nolink' then 'The Play opt-in link is not set yet. Ask the owner to set it, then type the command again.'
    else ''
  end || case when msg->>'help' = 'true' then E'\n\nCommands:\n'
    || '/addiostester ayla@mail.test - Add an iPhone tester' || E'\n'
    || '/addandroidtester can@mail.test - Add an Android tester' || E'\n'
    || '/removetester deniz@mail.test - Remove a tester' || E'\n'
    || '/listtesters - Count and list testers' else '' end, E' \n')
$$;
revoke all on function app_private.admin_body(jsonb) from public, anon, authenticated;

-- a***@m***.test: the only form of an email that reaches a log or a push.
create or replace function app_private.admin_mask(e text) returns text
language sql immutable set search_path = '' as $$
  select case
    when e is null then null
    when position('@' in e) = 0 then e
    else left(split_part(e,'@',1),1) || '***@' || left(split_part(e,'@',2),1) || '***'
         || coalesce(substring(split_part(e,'@',2) from '\.[^.]*$'), '')
  end
$$;
revoke all on function app_private.admin_mask(text) from public, anon, authenticated;

-- Writes one reply from the admin account. The GUC tells the update guard
-- (below) that this is the server, not a client.
create or replace function app_private.admin_reply(conv uuid, msg jsonb, push boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  perform set_config('app_private.admin_write', 'on', true);
  insert into public.messages(conversation_id, sender_id, body, admin_msg, admin_push, created_at)
  values (conv, '00000000-0000-0000-0000-00000000ad41', app_private.admin_body(msg), msg, push, clock_timestamp())
  returning id into result;
  return result;
end;
$$;
revoke all on function app_private.admin_reply(uuid, jsonb, boolean) from public, anon, authenticated;

-- Guards --------------------------------------------------------------------
-- The owner may send plain text into the admin chat and nothing else: no
-- attachment, reply or forward. messages_send (unchanged) still refuses every
-- system chat; this second permissive policy opens only the admin chat, only
-- to the owner.
-- The admin_msg and admin_push columns have no insert grant, so a client
-- cannot forge a reply or a push flag.
create policy messages_send_admin on public.messages for insert to authenticated
  with check ((select app_private.has_app_access())
              and sender_id = (select auth.uid())
              and app_private.is_member(conversation_id)
              and app_private.is_admin_chat(conversation_id)
              and (select app_private.is_owner())
              and attachment_path is null
              and reply_to is null
              and not forwarded);

-- Nothing edits, deletes or re-flags a message of the admin chat except the
-- server (admin_reply and admin_answer set the GUC for their own transaction).
-- The history is kept forever. Edit, delete-for-everyone and pins all end in
-- an update of public.messages, so one trigger covers them.
create or replace function app_private.messages_admin_chat_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('app_private.admin_write', true), '') = 'on' then
    return new;
  end if;
  if app_private.is_admin_chat(new.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_admin_chat_guard() from public, anon, authenticated;
create trigger messages_admin_chat_guard before update on public.messages
  for each row execute function app_private.messages_admin_chat_guard();

-- Nobody is added to, or moved around in, the admin chat except the server.
create or replace function app_private.conversation_members_admin_chat_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('app_private.admin_write', true), '') = 'on' then
    return new;
  end if;
  if app_private.is_admin_chat(new.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app_private.conversation_members_admin_chat_guard() from public, anon, authenticated;
create trigger conversation_members_admin_chat_guard before insert on public.conversation_members
  for each row execute function app_private.conversation_members_admin_chat_guard();

-- Push: a system chat sends none, except an admin reply flagged at insert
-- (an escalation). Same function as 20260930120000, one changed early exit.
create or replace function app_private.notify_new_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  url text;
begin
  if app_private.is_system_conversation(new.conversation_id)
     and not (new.admin_push and app_private.is_admin_chat(new.conversation_id)) then
    return null;
  end if;
  select decrypted_secret into url
    from vault.decrypted_secrets
   where name = 'notify_on_message_url';
  if url is not null then
    perform net.http_post(
      url := url,
      body := jsonb_build_object('record', jsonb_build_object('id', new.id)),
      headers := '{"content-type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000);
  end if;
  return null;
exception when others then
  raise warning 'notify_new_message: %', sqlerrm;
  return null;
end $$;
revoke all on function app_private.notify_new_message() from public, anon, authenticated;

-- The two chat RPCs that did not already refuse a chat without a title.
create or replace function public.hide_message(message uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message;
  if not found or not app_private.message_readable(m) or app_private.is_admin_chat(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into app_private.message_hides(user_id, message_id)
  values (auth.uid(), message)
  on conflict do nothing;
end $$;
revoke all on function public.hide_message(uuid) from public, anon;
grant execute on function public.hide_message(uuid) to authenticated;

create or replace function public.hide_chat(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if not (select app_private.has_app_access())
     or app_private.is_bot(me)
     or not app_private.was_member(conversation)
     or app_private.is_admin_chat(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversation_members cm
     set history_from = greatest(cm.history_from, clock_timestamp())
   where cm.conversation_id = conversation and cm.user_id = me;
  insert into public.chat_hides(user_id, conversation_id, hidden_at)
  values (me, conversation, now())
  on conflict (user_id, conversation_id) do update set hidden_at = excluded.hidden_at;
  delete from public.chat_pins
   where user_id = me and conversation_id = conversation;
  delete from public.chat_archives
   where user_id = me and conversation_id = conversation;
end $$;
revoke all on function public.hide_chat(uuid) from public, anon;
grant execute on function public.hide_chat(uuid) to authenticated;

-- Owner ---------------------------------------------------------------------
-- A new owner gets the admin chat, with the help list as its first reply.
create or replace function app_private.owners_after_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare cid uuid;
begin
  perform set_config('app_private.admin_write', 'on', true);
  insert into public.conversations(direct_key, system, admin_chat)
  values ('admin:' || new.user_id::text, true, true)
  on conflict (direct_key) do nothing
  returning id into cid;
  if cid is null then
    select c.id into cid from public.conversations c where c.direct_key = 'admin:' || new.user_id::text;
  end if;
  insert into public.conversation_members(conversation_id, user_id)
  values (cid, new.user_id) on conflict do nothing;
  perform app_private.admin_reply(cid, jsonb_build_object('k','help','help',true));
  return null;
end $$;
revoke all on function app_private.owners_after_insert() from public, anon, authenticated;
create trigger owners_after_insert after insert on app_private.owners
  for each row execute function app_private.owners_after_insert();

-- A removed owner loses the chat at once; the history stays.
create or replace function app_private.owners_after_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.conversation_members m using public.conversations c
   where m.conversation_id = c.id and c.direct_key = 'admin:' || old.user_id::text;
  return null;
end $$;
revoke all on function app_private.owners_after_delete() from public, anon, authenticated;
create trigger owners_after_delete after delete on app_private.owners
  for each row execute function app_private.owners_after_delete();

-- Commands ------------------------------------------------------------------
-- Each returns the outcome word that goes into the masked command log.

-- /listtesters: counts and FULL emails (the only reply that shows them).
create or replace function app_private.admin_cmd_list(conv uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  select jsonb_build_object(
    'k','list',
    'n', count(*),
    'ios', coalesce(jsonb_agg(a.email order by a.email) filter (where t.platform = 'ios'), '[]'::jsonb),
    'and', coalesce(jsonb_agg(a.email order by a.email) filter (where t.platform = 'android'), '[]'::jsonb),
    'oth', coalesce(jsonb_agg(a.email order by a.email) filter (where t.platform is null), '[]'::jsonb))
    into r
    from app_private.allowlist a left join app_private.tester_platform t on t.email = a.email;
  perform app_private.admin_reply(conv, r);
  return 'ok';
end $$;
revoke all on function app_private.admin_cmd_list(uuid) from public, anon, authenticated;

-- /addiostester and /addandroidtester: allowlist row, platform tag, then the
-- reply (an iPhone add also queues the Apple job; slice 2 runs it).
create or replace function app_private.admin_cmd_add(conv uuid, platform text, em text) returns text
language plpgsql security definer set search_path = '' as $$
declare masked text := app_private.admin_mask(em); jid uuid; mid uuid; link text;
begin
  insert into app_private.allowlist(email) values (em) on conflict do nothing;
  insert into app_private.tester_platform(email, platform) values (em, platform)
    on conflict (email) do update set platform = excluded.platform;
  if platform = 'ios' then
    insert into app_private.admin_jobs(kind, email, email_masked) values ('add', em, masked) returning id into jid;
    perform app_private.admin_reply(conv, jsonb_build_object('k','iosOk','e',masked));
    mid := app_private.admin_reply(conv, jsonb_build_object('k','p1','e',masked));
    update app_private.admin_jobs set progress_message_id = mid where id = jid;
  else
    perform app_private.admin_reply(conv, jsonb_build_object('k','andOk','e',masked));
    select s.value into link from app_private.admin_settings s where s.key = 'play_optin_link';
    if link is null then
      perform app_private.admin_reply(conv, jsonb_build_object('k','nolink'));
    else
      perform app_private.admin_reply(conv, jsonb_build_object('k','fwd','l',link,'e',em));
    end if;
  end if;
  return 'ok';
end $$;
revoke all on function app_private.admin_cmd_add(uuid, text, text) from public, anon, authenticated;

-- /removetester: a confirmation card first; admin_answer does the removal.
create or replace function app_private.admin_cmd_remove(conv uuid, owner uuid, em text) returns text
language plpgsql security definer set search_path = '' as $$
declare masked text := app_private.admin_mask(em); card uuid;
begin
  -- the owner cannot remove their own address
  if em = (select lower(u.email) from auth.users u where u.id = owner) then
    perform app_private.admin_reply(conv, jsonb_build_object('k','err','help',true));
    return 'err';
  end if;
  if not exists (select 1 from app_private.allowlist a where a.email = em) then
    perform app_private.admin_reply(conv, jsonb_build_object('k','nolist','e',masked,'help',true));
    return 'nolist';
  end if;
  card := app_private.admin_reply(conv, jsonb_build_object('k','conf','e',masked));
  insert into app_private.admin_pending(card_message_id, email, email_masked, expires_at)
  values (card, em, masked, now() + interval '10 minutes');
  return 'ok';
end $$;
revoke all on function app_private.admin_cmd_remove(uuid, uuid, text) from public, anon, authenticated;

-- Parses one owner message. Only the command word and the masked email are logged.
create or replace function app_private.admin_handle(conv uuid, owner uuid, body text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t text := btrim(body, E' \t\r\n');
  parts text[]; c text; em text; masked text; outcome text; cnt integer;
begin
  -- No cron: each command first drops the raw email of expired cards and ended jobs.
  update app_private.admin_pending set state = 'expired', email = null
   where state = 'pending' and expires_at < now();
  update app_private.admin_pending set email = null where email is not null and expires_at < now();
  update app_private.admin_jobs set email = null where email is not null and state in ('ok','failed');
  -- Rate limit: 30 commands in 10 minutes.
  select count(*) into cnt from app_private.admin_commands
   where owner_id = owner and at > now() - interval '10 minutes';
  if cnt >= 30 then
    perform app_private.admin_reply(conv, jsonb_build_object('k','rate'));
    insert into app_private.admin_commands(owner_id, command, outcome) values (owner, 'unknown', 'rate');
    return;
  end if;
  parts := regexp_split_to_array(t, '\s+');
  c := lower(parts[1]);
  em := lower(parts[2]);
  if c not in ('/addiostester','/addandroidtester','/removetester','/listtesters') then
    perform app_private.admin_reply(conv, jsonb_build_object('k','unk','help',true));
    outcome := 'unk'; c := 'unknown'; em := null;
  elsif c = '/listtesters' then
    outcome := app_private.admin_cmd_list(conv); em := null;
  elsif em is null then
    perform app_private.admin_reply(conv, jsonb_build_object('k','noem','help',true));
    outcome := 'noem';
  elsif em !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then
    perform app_private.admin_reply(conv, jsonb_build_object('k','bad','help',true));
    outcome := 'bad'; em := null;
  elsif c = '/addiostester' then
    outcome := app_private.admin_cmd_add(conv, 'ios', em);
  elsif c = '/addandroidtester' then
    outcome := app_private.admin_cmd_add(conv, 'android', em);
  else
    outcome := app_private.admin_cmd_remove(conv, owner, em);
  end if;
  masked := app_private.admin_mask(em);
  insert into app_private.admin_commands(owner_id, command, email_masked, outcome)
  values (owner, c, masked, outcome);
end $$;
revoke all on function app_private.admin_handle(uuid, uuid, text) from public, anon, authenticated;

-- The command path: runs in the sender's own insert, so the reply is there within one round trip.
create or replace function app_private.admin_on_message()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Only the owner's own message in the admin chat is a command; replies (admin_msg set) never come back in.
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not app_private.is_admin_chat(new.conversation_id)
     or new.sender_id is distinct from auth.uid()
     or not exists (select 1 from app_private.owners o where o.user_id = new.sender_id) then
    return null;
  end if;
  begin
    perform app_private.admin_handle(new.conversation_id, new.sender_id, new.body);
  exception when others then
    -- One generic line, never the cause: it could hold an email.
    begin
      perform app_private.admin_reply(new.conversation_id, jsonb_build_object('k','err','help',true));
      insert into app_private.admin_commands(owner_id, command, outcome) values (new.sender_id, 'unknown', 'err');
    exception when others then
      null;
    end;
  end;
  return null;
end $$;
revoke all on function app_private.admin_on_message() from public, anon, authenticated;
create trigger admin_on_message after insert on public.messages
  for each row when (new.admin_msg is null) execute function app_private.admin_on_message();

-- Cancel or Remove on a /removetester card. One use; an expired or used card only gets a plain line.
create or replace function public.admin_answer(card uuid, yes boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p app_private.admin_pending;
  conv uuid;
  em text;
  plat text;
  jid uuid;
  mid uuid;
begin
  if not (select app_private.has_app_access()) or not (select app_private.is_owner()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  -- lets this function update the card and write replies
  perform set_config('app_private.admin_write', 'on', true);

  select m.conversation_id into conv from public.messages m where m.id = card and m.admin_msg->>'k' = 'conf';
  if conv is null or not app_private.is_member(conv) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  select * into p from app_private.admin_pending where card_message_id = card for update;

  if not found or p.state <> 'pending' or p.expires_at < now() then
    -- stale: used before, or expired. Mark an unanswered one expired; the raw email goes.
    update app_private.admin_pending set state = case when state = 'pending' then 'expired' else state end, email = null
     where card_message_id = card;
    update public.messages set admin_msg = admin_msg || jsonb_build_object('st','expired')
     where id = card and not (admin_msg ? 'st');
    perform app_private.admin_reply(conv, jsonb_build_object('k','keep'));
    return;
  end if;

  if not yes then
    update app_private.admin_pending set state = 'cancelled', email = null where card_message_id = card;
    update public.messages set admin_msg = admin_msg || jsonb_build_object('st','cancelled') where id = card;
    insert into app_private.admin_commands(owner_id, command, email_masked, outcome)
    values (auth.uid(), '/removetester', p.email_masked, 'cancelled');
    perform app_private.admin_reply(conv, jsonb_build_object('k','canOk'));
    return;
  end if;

  em := p.email;
  select t.platform into plat from app_private.tester_platform t where t.email = em;
  -- tester_platform goes with it (on delete cascade)
  delete from app_private.allowlist where email = em;
  delete from app_private.active_sessions where user_id in (select u.id from auth.users u where lower(u.email) = em);
  update app_private.admin_pending set state = 'used', email = null where card_message_id = card;
  update public.messages set admin_msg = admin_msg || jsonb_build_object('st','done') where id = card;

  if plat is distinct from 'android' then
    -- an iPhone or an older tester: queue the Apple removal (slice 2 runs it)
    insert into app_private.admin_jobs(kind, email, email_masked) values ('remove', em, p.email_masked)
    returning id into jid;
    mid := app_private.admin_reply(conv, jsonb_build_object('k','r1','e',p.email_masked));
    update app_private.admin_jobs set progress_message_id = mid where id = jid;
  end if;

  perform app_private.admin_reply(conv, jsonb_build_object('k','rmOk','e',p.email_masked));
  insert into app_private.admin_commands(owner_id, command, email_masked, outcome, job_id)
  values (auth.uid(), '/removetester', p.email_masked, 'removed', jid);
end $$;
revoke all on function public.admin_answer(uuid, boolean) from public, anon;
grant execute on function public.admin_answer(uuid, boolean) to authenticated;

-- The chat list words admin chat previews in the reader's language: admin_msg at the end.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact, m.attachment_name,
       m.attachment_duration_ms, m.location_lat, m.attachment_mime,
       m.sticker_id, m.sticker_album, m.admin_msg
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll,
           mm.contact, mm.attachment_name, mm.attachment_duration_ms, mm.location_lat,
           mm.attachment_mime, mm.sticker_id, mm.sticker_album, mm.admin_msg
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;
