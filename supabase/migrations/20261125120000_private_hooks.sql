-- Generic private command hook: a registry row whose handler starts with private: calls a server function that is not part of this repository.

-- A private card remembers which private command made it; no grant, so no client can read or write it.
alter table app_private.admin_pending add column if not exists kind text;
-- A handler is a public name or private:<name>; the name is only letters and underscores.
alter table app_private.staff_commands drop constraint if exists staff_commands_handler_check;
alter table app_private.staff_commands add constraint staff_commands_handler_check check (handler ~ '^(private:)?[a-z_]{3,40}$');
create or replace function app_private.admin_on_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not app_private.is_admin_chat(new.conversation_id)
     or not exists (select 1 from public.conversations c where c.id = new.conversation_id and c.staff_key is not null)
     or new.sender_id is distinct from auth.uid()
     or not exists (select 1 from app_private.owners o where o.user_id = new.sender_id) then
    return null;
  end if;
  begin
    perform app_private.admin_handle(new.conversation_id, new.sender_id, new.body);
  exception when others then
    begin
      perform app_private.admin_reply(new.conversation_id, jsonb_build_object('k','err') || case when exists (select 1 from public.conversations c where c.id = new.conversation_id and c.staff_key = 'staff_a') then jsonb_build_object('help',true) else '{}'::jsonb end);
      insert into app_private.admin_commands(owner_id, command, outcome) values (new.sender_id, 'unknown', 'err');
    exception when others then
      null;
    end;
  end;
  return null;
end $$;
revoke all on function app_private.admin_on_message() from public, anon, authenticated;

create or replace function app_private.admin_handle(conv uuid, owner uuid, body text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  t text := btrim(body, E' \t\r\n');
  parts text[]; c text; em text; masked text; outcome text; cnt integer;
  sk text; h text; rest text;
begin
  parts := regexp_split_to_array(t, '\s+');
  c := lower(parts[1]);
  em := lower(parts[2]);
  select c2.staff_key into sk from public.conversations c2 where c2.id = conv;
  select s.handler into h from app_private.staff_commands s where s.chat_key = sk and s.word = c;
  -- A private word whose server function is missing is an unknown word.
  if h like 'private:%' and to_regprocedure('app_private.private_handler(text,uuid,uuid,text,text)') is null then h := null; end if;
  -- Outside the first chat only private words are ours: stay silent before any sweep, limit or log.
  if sk is distinct from 'staff_a' and (h is null or h not like 'private:%') then return; end if;
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
  rest := btrim(substr(t, length(parts[1]) + 1), E' \t\r\n');
  if h is not null and h not like 'private:%' and (sk is distinct from 'staff_a' or h not in ('tester_add_ios','tester_add_android','tester_remove','tester_list','sales_on','sales_off')) then h := null; end if;
  if h is null then
    perform app_private.admin_reply(conv, jsonb_build_object('k','unk','help',true));
    outcome := 'unk'; c := 'unknown'; em := null;
  elsif h like 'private:%' then
    -- Values only (USING): the name and the text never become SQL.
    execute format('select %s($1,$2,$3,$4,$5)', to_regprocedure('app_private.private_handler(text,uuid,uuid,text,text)')::regproc) using substr(h, 9), conv, owner, c, rest;
    outcome := 'ok'; em := null;
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
    first_word text;
  begin
    -- A private word is answered by the private path only: no reply, no row, no rate-limit count here.
    select c.staff_key into sk from public.conversations c where c.id = conv;
    first_word := lower((regexp_split_to_array(btrim(body), '\s+'))[1]);
    if exists (select 1 from app_private.staff_commands s where s.chat_key = sk and s.word = first_word and s.handler like 'private:%') then
      return;
    end if;
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

    -- Shared 30 s gap between Vega calls: a fresh answer is reused.
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

create or replace function public.admin_answer(card uuid, yes boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p app_private.admin_pending;
  conv uuid;
  em text;
  plat text;
  jid uuid;
  mid uuid;
  card_k text;
begin
  if not (select app_private.has_app_access()) or not (select app_private.is_owner()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  -- lets this function update the card and write replies
  perform set_config('app_private.admin_write', 'on', true);

  select m.conversation_id, m.admin_msg->>'k' into conv, card_k from public.messages m where m.id = card and m.admin_msg->>'k' in ('conf','card');
  if conv is null or not app_private.is_member(conv) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  select * into p from app_private.admin_pending where card_message_id = card for update;

  -- A card of one kind never runs the other kind's answer: key and kind must match (a null kind means a normal removal card).
  if not found or p.state <> 'pending' or p.expires_at < now()
     or (card_k = 'card') is distinct from coalesce(p.kind like 'private:%', false) then
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
    values (auth.uid(), coalesce(p.kind, '/removetester'), p.email_masked, 'cancelled');
    perform app_private.admin_reply(conv, jsonb_build_object('k','canOk'));
    return;
  end if;

  if p.kind like 'private:%' then
    -- The private code does the work; this function only keeps the card's life: used after a clean return, else expired.
    if to_regprocedure('app_private.private_answer(uuid,boolean,uuid)') is null then
      update app_private.admin_pending set state = 'expired', email = null where card_message_id = card;
      update public.messages set admin_msg = admin_msg || jsonb_build_object('st','expired')
       where id = card and not (admin_msg ? 'st');
      perform app_private.admin_reply(conv, jsonb_build_object('k','keep'));
      return;
    end if;
    begin
      execute format('select %s($1,$2,$3)', to_regprocedure('app_private.private_answer(uuid,boolean,uuid)')::regproc) using card, yes, conv;
    exception when others then
      perform set_config('app_private.admin_write', 'on', true);
      update app_private.admin_pending set state = 'expired', email = null where card_message_id = card;
      update public.messages set admin_msg = admin_msg || jsonb_build_object('st','expired')
       where id = card and not (admin_msg ? 'st');
      perform app_private.admin_reply(conv, jsonb_build_object('k','err'));
      return;
    end;
    -- the private code's own replies switch the write permission off again
    perform set_config('app_private.admin_write', 'on', true);
    update app_private.admin_pending set state = 'used', email = null where card_message_id = card;
    update public.messages set admin_msg = admin_msg || jsonb_build_object('st','done') where id = card;
    return;
  end if;

  em := p.email;
  select t.platform into plat from app_private.tester_platform t where t.email = em;
  -- tester_platform goes with it (on delete cascade)
  delete from app_private.allowlist where email = em;
  delete from app_private.active_sessions where user_id in (select u.id from auth.users u where lower(u.email) = em);
  -- A removed tester also loses any command-chat access and bot contact.
  delete from app_private.command_admins where user_id in (select u.id from auth.users u where lower(u.email) = em);
  delete from app_private.bot_contacts where contact_id in (select u.id from auth.users u where lower(u.email) = em);
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

-- Card and note replies carry their whole text in t; every other key keeps the old function, renamed.
alter function app_private.admin_body(jsonb) rename to admin_body_core;
create function app_private.admin_body(msg jsonb) returns text
language sql immutable set search_path = '' as $$
  select case when msg->>'k' in ('card','note')
    then btrim(coalesce(msg->>'t',''), E' \n')
    else app_private.admin_body_core(msg) end
$$;
revoke all on function app_private.admin_body(jsonb) from public, anon, authenticated;
revoke all on function app_private.admin_body_core(jsonb) from public, anon, authenticated;
