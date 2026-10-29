-- Bacanaks Ozel: an admin-only command chat (/podium).
-- Users in app_private.command_admins (the owner, added automatically) get their
-- own system chat; only the server writes its members and its replies.
-- Podium data, audit log and job rows live in app_private: no policies, no grants.

alter table public.conversations add column bacanaks_chat boolean not null default false;

create table if not exists app_private.command_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table app_private.command_admins enable row level security;
revoke all on table app_private.command_admins from public, anon, authenticated;

create table if not exists app_private.podium_state (
  only_row boolean primary key default true check (only_row),
  amount text,
  day date,
  fetched_at timestamptz,
  fail_count integer not null default 0,
  off boolean not null default false
);

insert into app_private.podium_state (only_row) values (true);

alter table app_private.podium_state enable row level security;
revoke all on table app_private.podium_state from public, anon, authenticated;

create table if not exists app_private.podium_commands (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  at timestamptz not null default now(),
  command text not null,
  outcome text not null
);

create index on app_private.podium_commands (user_id, at desc);

alter table app_private.podium_commands enable row level security;
revoke all on table app_private.podium_commands from public, anon, authenticated;

create table if not exists app_private.podium_jobs (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  state text not null default 'pending' check (state in ('pending','running','waiting','done','failed')),
  prev boolean not null,
  day date not null,
  created_at timestamptz not null default now()
);

create index on app_private.podium_jobs (state, created_at);

alter table app_private.podium_jobs enable row level security;
revoke all on table app_private.podium_jobs from public, anon, authenticated;

create or replace function app_private.is_command_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.command_admins a where a.user_id = (select auth.uid()))
$$;

revoke all on function app_private.is_command_admin() from public, anon;
grant execute on function app_private.is_command_admin() to authenticated;

create or replace function app_private.is_bacanaks_chat(conversation uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversations c where c.id = conversation and c.bacanaks_chat)
$$;

revoke all on function app_private.is_bacanaks_chat(uuid) from public, anon;
grant execute on function app_private.is_bacanaks_chat(uuid) to authenticated;

create or replace function app_private.command_admins_after_insert() returns trigger language plpgsql security definer set search_path = '' as $$
  declare cid uuid;
begin
  perform set_config('app_private.admin_write','on',true);
  insert into public.conversations(direct_key, system, admin_chat, bacanaks_chat)
    values ('bacanaks:' || new.user_id::text, true, true, true)
    on conflict (direct_key) do nothing
    returning id into cid;
  if cid is null then
    select c.id into cid from public.conversations c where c.direct_key = 'bacanaks:' || new.user_id::text;
  end if;
  insert into public.conversation_members(conversation_id,user_id)
    values (cid,new.user_id)
    on conflict do nothing;
  perform set_config('app_private.admin_write','',true);
  return null;
end;
$$;

revoke all on function app_private.command_admins_after_insert() from public, anon, authenticated;

create trigger command_admins_after_insert
  after insert on app_private.command_admins
  for each row execute function app_private.command_admins_after_insert();

create or replace function app_private.command_admins_after_delete() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.conversation_members m
  using public.conversations c
  where m.conversation_id = c.id
    and c.direct_key = 'bacanaks:' || old.user_id::text;
  return null;
end;
$$;

revoke all on function app_private.command_admins_after_delete() from public, anon, authenticated;

create trigger command_admins_after_delete
  after delete on app_private.command_admins
  for each row execute function app_private.command_admins_after_delete();

create or replace function app_private.owners_make_command_admin() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into app_private.command_admins(user_id) values (new.user_id) on conflict do nothing;
  return null;
end;
$$;

revoke all on function app_private.owners_make_command_admin() from public, anon, authenticated;

create trigger owners_make_command_admin
  after insert on app_private.owners
  for each row execute function app_private.owners_make_command_admin();

insert into app_private.command_admins(user_id)
select user_id from app_private.owners on conflict do nothing;

create policy messages_send_bacanaks on public.messages for insert to authenticated with check (
  (select app_private.has_app_access()) and
  sender_id = (select auth.uid()) and
  app_private.is_member(conversation_id) and
  app_private.is_bacanaks_chat(conversation_id) and
  (select app_private.is_command_admin()) and
  attachment_path is null and
  reply_to is null and
  not forwarded
);

-- The business day in Istanbul: before 07:30 it is still the previous day.
create or replace function app_private.podium_business_day(at timestamptz) returns date language sql immutable set search_path = '' as $$
  select ((at at time zone 'Europe/Istanbul') - interval '7 hours 30 minutes')::date
$$;
revoke all on function app_private.podium_business_day(timestamptz) from public, anon, authenticated;

-- One /podium ask. Only the exact word /podium is read; the text is never stored or forwarded.
create or replace function app_private.podium_handle(conv uuid, uid uuid, body text) returns void language plpgsql security definer set search_path = '' as $$
  declare
    t text := btrim(body, E' \t\r\n');
    r record;
    cnt integer;
    st app_private.podium_state;
    ist timestamp;
    prev boolean;
    d date;
    inflight boolean;
  begin
    -- No cron: each ask fails jobs that never got an answer.
    for r in select id, conversation_id from app_private.podium_jobs where state in ('pending','running','waiting') and created_at < now() - interval '2 minutes' loop
      update app_private.podium_jobs set state='failed' where id = r.id;
      perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k','podFail'));
    end loop;

    -- Rate limit: 30 commands per 10 minutes
    select count(*) into cnt from app_private.podium_commands where user_id = uid and at > now() - interval '10 minutes';
    if cnt >= 30 then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podRate'));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'unknown','rate');
      return;
    end if;

    if lower(t) <> '/podium' then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podUnk'));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'unknown','unk');
      return;
    end if;

    -- Locks the one state row: concurrent asks run one after the other.
    select * into st from app_private.podium_state for update;

    if st.off then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podOff'));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'/podium','off');
      return;
    end if;

    -- The business day comes from the server clock in Istanbul, never from the phone.
    ist := now() at time zone 'Europe/Istanbul';
    d := app_private.podium_business_day(now());
    prev := d < ist::date;

    -- Shared 30 s gap between Vega calls: a fresh answer is reused.
    if st.fetched_at is not null and st.fetched_at > now() - interval '30 seconds' and st.day = d and st.amount is not null then
      perform app_private.admin_reply(conv, jsonb_build_object('k', case when prev then 'podPrev' else 'pod' end, 'amt', st.amount, 'day', d, 'at', st.fetched_at));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'/podium','cache');
      return;
    end if;

    inflight := exists (select 1 from app_private.podium_jobs where state in ('pending','running') and created_at > now() - interval '30 seconds');
    insert into app_private.podium_jobs(conversation_id, state, prev, day) values (conv, case when inflight then 'waiting' else 'pending' end, prev, d);
    insert into app_private.podium_commands(user_id, command, outcome) values (uid,'/podium', case when inflight then 'wait' else 'ask' end);
  end;
$$;
revoke all on function app_private.podium_handle(uuid, uuid, text) from public, anon, authenticated;

-- The edge function claims a job once, then reports the result. Service role only.
create or replace function public.podium_job_claim(job uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
  declare
    d date;
    p boolean;
  begin
    update app_private.podium_jobs set state='running' where id = job and state='pending' and not (select off from app_private.podium_state) returning day, prev into d, p;
    if not found then return null; end if;
    return jsonb_build_object('day', d, 'prev', p);
  end;
$$;
revoke all on function public.podium_job_claim(uuid) from public, anon, authenticated;
grant execute on function public.podium_job_claim(uuid) to service_role;

-- amount null or malformed = failure. Three failures in a row (any reason but 'config') turn the command off.
create or replace function public.podium_job_finish(job uuid, amount text, reason text) returns void language plpgsql security definer set search_path = '' as $$
  declare
    j app_private.podium_jobs;
    r record;
    ok boolean;
  begin
    select * into j from app_private.podium_jobs where id = job and state = 'running' for update;
    if not found then return; end if;

    ok := amount is not null and length(amount) <= 25 and amount ~ '^[0-9]{1,3}([.,'' ][0-9]{3})*([.,][0-9]{1,2})?$|^[0-9]+([.,][0-9]{1,2})?$';

    if ok then
      update app_private.podium_state set amount = podium_job_finish.amount, day = j.day, fetched_at = now(), fail_count = 0 where only_row;
    else
      update app_private.podium_state set fail_count = case when reason is distinct from 'config' then fail_count + 1 else fail_count end, off = off or (reason is distinct from 'config' and fail_count + 1 >= 3) where only_row;
    end if;

    -- waiting asks get the same answer
    for r in select id, conversation_id from app_private.podium_jobs where id = job or state = 'waiting' loop
      if ok then
        perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k', case when j.prev then 'podPrev' else 'pod' end, 'amt', amount, 'day', j.day, 'at', now()));
      else
        perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k','podFail'));
      end if;
      update app_private.podium_jobs set state = case when ok then 'done' else 'failed' end where id = r.id;
    end loop;
  end;
$$;
revoke all on function public.podium_job_finish(uuid, text, text) from public, anon, authenticated;
grant execute on function public.podium_job_finish(uuid, text, text) to service_role;

-- A new ask is handed to the podium edge function: job id plus a shared secret header (both in Vault).
create or replace function app_private.podium_jobs_dispatch() returns trigger language plpgsql security definer set search_path = '' as $$
declare url text; secret text;
begin
  select decrypted_secret into url from vault.decrypted_secrets where name = 'podium_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'podium_secret';
  if url is not null and secret is not null then
    perform net.http_post(url := url, body := jsonb_build_object('job_id', new.id), headers := jsonb_build_object('content-type','application/json','x-podium-secret', secret), timeout_milliseconds := 5000);
  end if;
  return null;
exception when others then
  raise warning 'podium_jobs_dispatch failed';
  return null;
end $$;
revoke all on function app_private.podium_jobs_dispatch() from public, anon, authenticated;
create trigger podium_jobs_dispatch after insert on app_private.podium_jobs for each row when (new.state = 'pending') execute function app_private.podium_jobs_dispatch();

-- The command path of the Bacanaks chat, in the sender's own insert.
create or replace function app_private.podium_on_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not app_private.is_bacanaks_chat(new.conversation_id)
     or new.sender_id is distinct from (select auth.uid())
     or not exists (select 1 from app_private.command_admins a where a.user_id = new.sender_id) then
    return null;
  end if;
  begin
    perform app_private.podium_handle(new.conversation_id, new.sender_id, new.body);
  exception when others then
    -- One generic line, never the cause.
    begin
      perform app_private.admin_reply(new.conversation_id, jsonb_build_object('k','err'));
    exception when others then
      null;
    end;
  end;
  return null;
end $$;
revoke all on function app_private.podium_on_message() from public, anon, authenticated;
create trigger podium_on_message after insert on public.messages for each row when (new.admin_msg is null) execute function app_private.podium_on_message();

-- The owner's admin-chat command trigger must ignore Bacanaks chats (also admin chats).
create or replace function app_private.admin_on_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not app_private.is_admin_chat(new.conversation_id)
     or app_private.is_bacanaks_chat(new.conversation_id)
     or new.sender_id is distinct from auth.uid()
     or not exists (select 1 from app_private.owners o where o.user_id = new.sender_id) then
    return null;
  end if;
  begin
    perform app_private.admin_handle(new.conversation_id, new.sender_id, new.body);
  exception when others then
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

-- English text of a Bacanaks chat reply. The amount is never in the body.
create or replace function app_private.podium_body(msg jsonb)
returns text
language sql immutable set search_path = '' as $$
select case msg->>'k'
when 'pod' then 'Total money'
when 'podPrev' then 'Previous day''s total'
when 'podFail' then 'Vega did not answer.'
when 'podOff' then 'This command is turned off.'
when 'podUnk' then 'Unknown command. Try /podium.'
when 'podRate' then 'Too many commands. Wait a minute and try again.'
when 'podSwOn' then '/podium is turned on.'
when 'podSwOff' then '/podium is turned off.'
else ''
end;
$$;
revoke all on function app_private.podium_body(jsonb) from public, anon, authenticated;

-- Same as before, but a key the admin chat does not know gets the podium text.
create or replace function app_private.admin_reply(conv uuid, msg jsonb, push boolean default false)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  perform set_config('app_private.admin_write', 'on', true);
  insert into public.messages(conversation_id, sender_id, body, admin_msg, admin_push, created_at)
  values (conv, '00000000-0000-0000-0000-00000000ad41', coalesce(nullif(app_private.admin_body(msg), ''), app_private.podium_body(msg)), msg, push, clock_timestamp())
  returning id into result;
  -- the permission lasts for the insert only
  perform set_config('app_private.admin_write', '', true);
  return result;
end;
$$;
revoke all on function app_private.admin_reply(uuid, jsonb, boolean) from public, anon, authenticated;

-- /podiumon and /podiumoff: the owner's switch for /podium, typed in the admin chat.
create or replace function app_private.admin_handle(conv uuid, owner uuid, body text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  t text := btrim(body, E' \t\r\n');
  parts text[]; c text; em text; masked text; outcome text; cnt integer;
begin
  -- No cron: each command first drops the raw email of expired cards and ended jobs.
  update app_private.admin_pending set state = 'expired', email = null
   where state = 'pending' and expires_at < now();
  update app_private.admin_pending set email = null where email is not null and expires_at < now();
  perform app_private.admin_jobs_sweep();
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
  if c not in ('/addiostester','/addandroidtester','/removetester','/listtesters','/podiumon','/podiumoff') then
    perform app_private.admin_reply(conv, jsonb_build_object('k','unk','help',true));
    outcome := 'unk'; c := 'unknown'; em := null;
  elsif c = '/listtesters' then
    outcome := app_private.admin_cmd_list(conv); em := null;
  elsif c in ('/podiumon','/podiumoff') then
    update app_private.podium_state set off = (c = '/podiumoff'), fail_count = 0 where only_row;
    perform app_private.admin_reply(conv, jsonb_build_object('k', case when c = '/podiumon' then 'podSwOn' else 'podSwOff' end));
    outcome := 'ok'; em := null;
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
