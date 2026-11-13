-- Staff dispatch: the server finds a command's handler in the registry; the sales objects get neutral names.
-- Renames keep every row, trigger and grant; the function bodies are re-created below.

alter table app_private.tally_state rename to sales_state;
alter table app_private.tally_jobs rename to sales_jobs;
alter table app_private.tally_commands rename to sales_commands;
alter function app_private.tally_business_day(timestamptz) rename to sales_business_day;
alter function app_private.tally_handle(uuid, uuid, text) rename to sales_handle;
alter function app_private.tally_jobs_dispatch() rename to sales_jobs_dispatch;
alter function app_private.tally_on_message() rename to sales_on_message;
alter function app_private.tally_body(jsonb) rename to sales_body;
alter function public.tally_job_claim(uuid) rename to sales_job_claim;
alter function public.tally_job_finish(uuid, text, text) rename to sales_job_finish;
alter trigger tally_jobs_dispatch on app_private.sales_jobs rename to sales_jobs_dispatch;
alter trigger tally_on_message on public.messages rename to sales_on_message;

-- One sales ask. The word must be a sales_total command of this chat's registry; the text is never stored or forwarded.
create or replace function app_private.sales_handle(conv uuid, uid uuid, body text) returns void language plpgsql security definer set search_path = '' as $$
  declare
    t text := btrim(body, E' \t\r\n');
    r record;
    cnt integer;
    st app_private.sales_state;
    ist timestamp;
    prev boolean;
    d date;
    inflight boolean;
    sk text;
    w text;
  begin
    -- One ask per user at a time, so a parallel burst cannot pass the limit below.
    perform pg_advisory_xact_lock(hashtextextended('sales:' || uid::text, 0));
    -- Locks the one state row: concurrent asks run one after the other.
    select * into st from app_private.sales_state for update;
    -- No cron: each ask fails jobs that never got an answer.
    for r in select id, conversation_id from app_private.sales_jobs where state in ('pending','running','waiting') and created_at < now() - interval '2 minutes' loop
      update app_private.sales_jobs set state='failed' where id = r.id;
      perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k','podFail'));
    end loop;

    -- Rate limit: 30 commands per 10 minutes
    select count(*) into cnt from app_private.sales_commands where user_id = uid and at > now() - interval '10 minutes';
    if cnt >= 30 then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podRate'));
      insert into app_private.sales_commands(user_id, command, outcome) values (uid,'unknown','rate');
      return;
    end if;

    select c.staff_key into sk from public.conversations c where c.id = conv;
    if not exists (select 1 from app_private.staff_commands s where s.chat_key = sk and s.word = lower(t) and s.handler = 'sales_total') then
      select s.word into w from app_private.staff_commands s where s.chat_key = sk and s.handler = 'sales_total' limit 1;
      perform app_private.admin_reply(conv, jsonb_build_object('k','podUnk','c',w));
      insert into app_private.sales_commands(user_id, command, outcome) values (uid,'unknown','unk');
      return;
    end if;

    if st.off then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podOff'));
      insert into app_private.sales_commands(user_id, command, outcome) values (uid,'sales_total','off');
      return;
    end if;

    -- The business day comes from the server clock in Istanbul, never from the phone.
    ist := now() at time zone 'Europe/Istanbul';
    d := app_private.sales_business_day(now());
    prev := d < ist::date;

    -- Shared 30 s gap between sales-source calls: a fresh answer is reused.
    if st.fetched_at is not null and st.fetched_at > now() - interval '30 seconds' and st.day = d and st.amount is not null then
      perform app_private.admin_reply(conv, jsonb_build_object('k', case when prev then 'podPrev' else 'pod' end, 'amt', st.amount, 'day', d, 'at', st.fetched_at));
      insert into app_private.sales_commands(user_id, command, outcome) values (uid,'sales_total','cache');
      return;
    end if;

    inflight := exists (select 1 from app_private.sales_jobs where state in ('pending','running') and created_at > now() - interval '30 seconds');
    insert into app_private.sales_jobs(conversation_id, state, prev, day) values (conv, case when inflight then 'waiting' else 'pending' end, prev, d);
    insert into app_private.sales_commands(user_id, command, outcome) values (uid,'sales_total', case when inflight then 'wait' else 'ask' end);
  end;
$$;
revoke all on function app_private.sales_handle(uuid, uuid, text) from public, anon, authenticated;

-- The edge function claims a job once, then reports the result. Service role only.
create or replace function public.sales_job_claim(job uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
  declare
    d date;
    p boolean;
  begin
    update app_private.sales_jobs set state='running' where id = job and state='pending' and not (select off from app_private.sales_state) returning day, prev into d, p;
    if not found then return null; end if;
    return jsonb_build_object('day', d, 'prev', p);
  end;
$$;

create or replace function public.sales_job_finish(job uuid, amount text, reason text) returns void language plpgsql security definer set search_path = '' as $$
  declare
    j app_private.sales_jobs;
    r record;
    ok boolean;
  begin
    -- lock order: state row first, then job rows (same as sales_handle)
    perform 1 from app_private.sales_state where only_row for update;
    select * into j from app_private.sales_jobs where id = job and state = 'running' for update;
    if not found then return; end if;

    ok := amount is not null and length(amount) <= 25 and amount ~ '^[0-9]{1,3}([.,'' ][0-9]{3})*([.,][0-9]{1,2})?$|^[0-9]+([.,][0-9]{1,2})?$';

    if ok then
      update app_private.sales_state set amount = sales_job_finish.amount, day = j.day, fetched_at = now(), fail_count = 0 where only_row;
    else
      update app_private.sales_state set fail_count = case when reason is distinct from 'config' then fail_count + 1 else fail_count end, off = off or (reason is distinct from 'config' and fail_count + 1 >= 3) where only_row;
    end if;

    -- waiting asks get the same answer
    for r in select id, conversation_id from app_private.sales_jobs where id = job or state = 'waiting' loop
      if ok then
        perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k', case when j.prev then 'podPrev' else 'pod' end, 'amt', amount, 'day', j.day, 'at', now()));
      else
        perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k','podFail'));
      end if;
      update app_private.sales_jobs set state = case when ok then 'done' else 'failed' end where id = r.id;
    end loop;
  end;
$$;
revoke all on function public.sales_job_finish(uuid, text, text) from public, anon, authenticated;
grant execute on function public.sales_job_finish(uuid, text, text) to service_role;

-- A new ask is handed to the sales edge function: job id plus a shared secret header (both in Vault).
create or replace function app_private.sales_jobs_dispatch() returns trigger language plpgsql security definer set search_path = '' as $$
declare url text; secret text;
begin
  select decrypted_secret into url from vault.decrypted_secrets where name = 'job_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'job_secret';
  if url is not null and secret is not null then
    perform net.http_post(url := url, body := jsonb_build_object('job_id', new.id), headers := jsonb_build_object('content-type','application/json','x-job-secret', secret), timeout_milliseconds := 5000);
  end if;
  return null;
exception when others then
  raise warning 'sales_jobs_dispatch failed';
  return null;
end $$;
revoke all on function app_private.sales_jobs_dispatch() from public, anon, authenticated;

-- The command path of the second staff chat, in the sender's own insert.
create or replace function app_private.sales_on_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not exists (select 1 from public.conversations c where c.id = new.conversation_id and c.staff_key = 'staff_b')
     or new.sender_id is distinct from (select auth.uid())
     or not exists (select 1 from app_private.command_admins a where a.user_id = new.sender_id) then
    return null;
  end if;
  begin
    perform app_private.sales_handle(new.conversation_id, new.sender_id, new.body);
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
revoke all on function app_private.sales_on_message() from public, anon, authenticated;

-- English text of a sales chat reply. The amount is never in the body.
create or replace function app_private.sales_body(msg jsonb)
returns text
language sql immutable set search_path = '' as $$
select case msg->>'k'
when 'pod' then 'Total money'
when 'podPrev' then 'Previous day''s total'
when 'podFail' then 'The sales source did not answer.'
when 'podOff' then 'This command is turned off.'
when 'podUnk' then 'Unknown command. Try ' || coalesce(msg->>'c', 'the sales command') || '.'
when 'podRate' then 'Too many commands. Wait a minute and try again.'
when 'podSwOn' then coalesce(msg->>'c', 'The sales command') || ' is turned on.'
when 'podSwOff' then coalesce(msg->>'c', 'The sales command') || ' is turned off.'
else ''
end;
$$;
revoke all on function app_private.sales_body(jsonb) from public, anon, authenticated;

-- Same as before; the fallback text now comes from sales_body. A sales amount reply also carries the source name from the server-only private pack (function app_private.private_source(), absent = no name).
create or replace function app_private.admin_reply(conv uuid, msg jsonb, push boolean default false)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare result uuid; m jsonb := msg; fn regprocedure; src text;
begin
  fn := to_regprocedure('app_private.private_source()');
  if fn is not null and m->>'k' in ('pod','podPrev') then
    execute 'select app_private.private_source()' into src;
    if src is not null and src <> '' then m := m || jsonb_build_object('src', src); end if;
  end if;
  perform set_config('app_private.admin_write', 'on', true);
  insert into public.messages(conversation_id, sender_id, body, admin_msg, admin_push, created_at)
  values (conv, '00000000-0000-0000-0000-00000000ad41', coalesce(nullif(app_private.admin_body(m), ''), app_private.sales_body(m)), m, push, clock_timestamp())
  returning id into result;
  -- the permission lasts for the insert only
  perform set_config('app_private.admin_write', '', true);
  return result;
end;
$$;
revoke all on function app_private.admin_reply(uuid, jsonb, boolean) from public, anon, authenticated;

-- The owner's admin-chat command path: only the first staff chat.
create or replace function app_private.admin_on_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not app_private.is_admin_chat(new.conversation_id)
     or not exists (select 1 from public.conversations c where c.id = new.conversation_id and c.staff_key = 'staff_a')
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

-- New staff chats get their key from the old flags, whichever trigger creates them.
create or replace function app_private.conversations_set_staff_key() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.admin_chat and new.staff_key is null then
    new.staff_key := case when new.staff_b_chat then 'staff_b' else 'staff_a' end;
  end if;
  return new;
end $$;
revoke all on function app_private.conversations_set_staff_key() from public, anon, authenticated;
create trigger conversations_set_staff_key before insert on public.conversations
  for each row execute function app_private.conversations_set_staff_key();

-- Only the server (service role) calls the job functions.
revoke all on function public.sales_job_claim(uuid) from public, anon, authenticated;
grant execute on function public.sales_job_claim(uuid) to service_role;
revoke all on function public.sales_job_finish(uuid, text, text) from public, anon, authenticated;
grant execute on function public.sales_job_finish(uuid, text, text) to service_role;

-- Command dispatch of the first staff chat: the word is looked up in the registry.
create or replace function app_private.admin_handle(conv uuid, owner uuid, body text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  t text := btrim(body, E' \t\r\n');
  parts text[]; c text; em text; masked text; outcome text; cnt integer;
  sk text; h text;
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
  select c2.staff_key into sk from public.conversations c2 where c2.id = conv;
  select s.handler into h from app_private.staff_commands s where s.chat_key = sk and s.word = c;
  if sk is distinct from 'staff_a' or h is null or h not in ('tester_add_ios','tester_add_android','tester_remove','tester_list','sales_on','sales_off') then h := null; end if;
  if h is null then
    perform app_private.admin_reply(conv, jsonb_build_object('k','unk','help',true));
    outcome := 'unk'; c := 'unknown'; em := null;
  elsif h = 'tester_list' then
    outcome := app_private.admin_cmd_list(conv); em := null;
  elsif h in ('sales_on','sales_off') then
    update app_private.sales_state set off = (h = 'sales_off'), fail_count = 0 where only_row;
    perform app_private.admin_reply(conv, jsonb_build_object('k', case when h = 'sales_on' then 'podSwOn' else 'podSwOff' end, 'c', c));
    outcome := 'ok'; em := null;
  elsif em is null then
    perform app_private.admin_reply(conv, jsonb_build_object('k','noem','help',true));
    outcome := 'noem';
  elsif em !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then
    perform app_private.admin_reply(conv, jsonb_build_object('k','bad','help',true));
    outcome := 'bad'; em := null;
  elsif h = 'tester_add_ios' then
    outcome := app_private.admin_cmd_add(conv, 'ios', em);
  elsif h = 'tester_add_android' then
    outcome := app_private.admin_cmd_add(conv, 'android', em);
  else
    outcome := app_private.admin_cmd_remove(conv, owner, em);
  end if;
  c := coalesce(h, 'unknown');
  masked := app_private.admin_mask(em);
  insert into app_private.admin_commands(owner_id, command, email_masked, outcome)
  values (owner, c, masked, outcome);
end $$;
revoke all on function app_private.admin_handle(uuid, uuid, text) from public, anon, authenticated;
