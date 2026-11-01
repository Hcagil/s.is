begin;
select plan(187);

-- Bacanaks Ozel: a command chat for command admins only, one command /podium
-- (the Vega money total). Written from the contract, not from the migration:
--
-- 1. shape and grants: podium_job_claim / podium_job_finish for service_role
--    only; podium tables in app_private hold no grant for clients.
-- 2. a command admin (the owner is one automatically) gets one system chat
--    (admin_chat + bacanaks_chat) whose only member is that admin; removing
--    the flag removes the membership.
-- 3. reads: anon, a user without the flag, a user whose flag was removed and
--    a revoked session see nothing (not the chat, its messages, members or
--    preview). Each negative subject fails exactly one gate.
-- 4. sends: only the flagged member with app access, plain text only.
-- 5. only the exact /podium is a command; anything else -> podUnk, no job.
-- 6. rate limit 30 commands per 10 minutes -> podRate, no job.
-- 7. one audit row per command; the amount is never in it.
-- 8. the business day is Istanbul time; 00:00-07:30 = previous day (prev).
-- 9. 30 s shared cache; asks during a fetch wait and get the same answer.
-- 10. /podiumoff and /podiumon: the owner, in the admin chat only.
-- 11. three failures in a row (any reason but 'config') turn the command off.
-- 12. claim once; finish answers with pod/podPrev or podFail.
-- 13. no push for any reply; the body and the chat-list preview never hold
--     the amount; a malformed amount is never stored or shown.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- fixtures -------------------------------------------------------------------
-- own  the owner (allowlisted, active): command admin automatically
-- mal  allowlisted, active, NOT a command admin (fails only the flag)
-- adm  allowlisted, active, made command admin, later removed
-- rev  allowlisted, command admin, session revoked later (fails only the session)
create function u(n text) returns uuid language sql immutable as $$
  select case n when 'own' then '00000000-0000-0000-0000-0000000bd001'::uuid
                when 'mal' then '00000000-0000-0000-0000-0000000bd002'::uuid
                when 'adm' then '00000000-0000-0000-0000-0000000bd003'::uuid
                when 'rev' then '00000000-0000-0000-0000-0000000bd004'::uuid end $$;
create function s(n text) returns text language sql immutable as $$
  select case n when 'own' then 'bd000000-0000-0000-0000-000000000001'
                when 'mal' then 'bd000000-0000-0000-0000-000000000002'
                when 'adm' then 'bd000000-0000-0000-0000-000000000003'
                when 'rev' then 'bd000000-0000-0000-0000-000000000004' end $$;
create function as_(n text) returns void language sql as $$ select test_as(u(n), s(n)) $$;
grant execute on function u(text), s(text), as_(text), test_as(uuid, text) to authenticated, anon;

insert into auth.users (id, email, email_confirmed_at) values
  (u('own'), 'bown@mail.test', now()), (u('mal'), 'bmal@mail.test', now()),
  (u('adm'), 'badm@mail.test', now()), (u('rev'), 'brev@mail.test', now());
insert into app_private.allowlist(email) values
  ('bown@mail.test'), ('bmal@mail.test'), ('badm@mail.test'), ('brev@mail.test');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select s(n)::uuid, u(n), now(), now() from unnest(array['own', 'mal', 'adm', 'rev']) n;
select as_('own'); select is(public.activate_session(), true, 'fixture: own is active'); reset role;
select as_('mal'); select is(public.activate_session(), true, 'fixture: mal is active'); reset role;
select as_('adm'); select is(public.activate_session(), true, 'fixture: adm is active'); reset role;
select as_('rev'); select is(public.activate_session(), true, 'fixture: rev is active'); reset role;

-- one known state for the shared row
update app_private.podium_state set amount = null, day = null, fetched_at = null, fail_count = 0, off = false;

-- A message as [n]; 'ok' or 'err:<sqlstate>'.
create function say(n text, conv uuid, t text) returns text language plpgsql as $$
begin
  if n = 'anon' then
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    execute 'set local role anon';
  else
    perform as_(n);
  end if;
  insert into public.messages(conversation_id, sender_id, body) values (conv, coalesce(u(n), u('own')), t);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return 'ok';
exception when others then
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return 'err:' || sqlstate;
end $$;

-- Server replies (from ...ad41) in [conv] not returned before, as a jsonb array of admin_msg.
create table seen(id uuid primary key);
-- every audit row ever written (sections below clear the live table)
create table audit_log(r text);
create function fresh(conv uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  select coalesce(jsonb_agg(m.admin_msg order by m.id), '[]') into r from public.messages m
   where m.conversation_id = conv and m.sender_id = '00000000-0000-0000-0000-00000000ad41'
     and m.id not in (select id from seen);
  insert into seen select m.id from public.messages m
   where m.conversation_id = conv and m.id not in (select id from seen);
  return r;
end $$;
create function jobs() returns bigint language sql as $$ select count(*) from app_private.podium_jobs $$;
create function cmds() returns bigint language sql as $$ select count(*) from app_private.podium_commands $$;
-- Run the edge function's part for every pending job: claim, then finish.
create function vega(amount text, reason text) returns int language plpgsql as $$
declare j uuid; n int := 0;
begin
  for j in select id from app_private.podium_jobs where state = 'pending' loop
    if public.podium_job_claim(j) is not null then
      perform public.podium_job_finish(j, amount, reason);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
-- The business day the contract asks for, from the server clock.
create function want_prev() returns boolean language sql as $$
  select (now() at time zone 'Europe/Istanbul')::time < time '07:30' $$;
create function want_day() returns date language sql as $$
  select (now() at time zone 'Europe/Istanbul')::date - case when want_prev() then 1 else 0 end $$;
create function want_k() returns text language sql as $$ select case when want_prev() then 'podPrev' else 'pod' end $$;

-- 1 shape and grants -------------------------------------------------------------
select ok(has_function_privilege('service_role', 'public.podium_job_claim(uuid)', 'execute'), 'service_role may claim a job');
select ok(not has_function_privilege('authenticated', 'public.podium_job_claim(uuid)', 'execute'), 'authenticated may not claim a job');
select ok(not has_function_privilege('anon', 'public.podium_job_claim(uuid)', 'execute'), 'anon may not claim a job');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid = 'public.podium_job_claim(uuid)'::regprocedure and a.grantee = 0),
          'podium_job_claim is not granted to public');
select ok(has_function_privilege('service_role', 'public.podium_job_finish(uuid, text, text)', 'execute'), 'service_role may finish a job');
select ok(not has_function_privilege('authenticated', 'public.podium_job_finish(uuid, text, text)', 'execute'), 'authenticated may not finish a job');
select ok(not has_function_privilege('anon', 'public.podium_job_finish(uuid, text, text)', 'execute'), 'anon may not finish a job');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid = 'public.podium_job_finish(uuid, text, text)'::regprocedure and a.grantee = 0),
          'podium_job_finish is not granted to public');
select ok(not has_table_privilege(r, 'app_private.' || t, 'select,insert,update,delete'), r || ' holds nothing on ' || t)
  from unnest(array['command_admins', 'podium_state', 'podium_commands', 'podium_jobs']) t,
       unnest(array['authenticated', 'anon']) r;
select is((select pronargs::int from pg_proc where oid = 'app_private.is_command_admin()'::regprocedure), 0,
          'is_command_admin takes no argument (answers for the caller only)');
select ok(not has_function_privilege('anon', 'app_private.is_command_admin()', 'execute'), 'anon cannot execute is_command_admin');
select ok(not has_column_privilege('authenticated', 'public.conversations', 'bacanaks_chat', 'INSERT')
          and not has_column_privilege('authenticated', 'public.conversations', 'bacanaks_chat', 'UPDATE'),
          'clients cannot write bacanaks_chat');

-- 2 the chats ------------------------------------------------------------------------
insert into app_private.owners(user_id) values (u('own'));
insert into app_private.command_admins(user_id) values (u('adm')), (u('rev'));
create table chat as
  select m.user_id as who, c.id from public.conversations c join public.conversation_members m on m.conversation_id = c.id
   where c.bacanaks_chat;
grant select on chat, seen to authenticated, anon;
create function bc(n text) returns uuid language sql stable as $$ select id from chat where who = u(n) $$;
grant execute on function bc(text) to authenticated, anon;
create table adm as select id from public.conversations where admin_chat and not bacanaks_chat;
select is((select count(*) from chat where who = u('own')), 1::bigint, 'the owner row gives the owner one Bacanaks chat');
select is((select count(*) from chat where who = u('adm')), 1::bigint, 'a command admin row gives that user one Bacanaks chat');
select is((select count(distinct id) from chat), 3::bigint, 'each command admin has a chat of their own');
select is((select count(*) from chat where who = u('mal')), 0::bigint, 'a user without the flag gets no chat');
select ok((select system and admin_chat and bacanaks_chat from public.conversations where id = bc('own')),
          'the chat is a system chat flagged admin_chat and bacanaks_chat');
select is((select array_agg(user_id) from public.conversation_members where conversation_id = bc('own')),
          array[u('own')], 'the owner is the only member of the owner''s chat');
select is((select array_agg(user_id) from public.conversation_members where conversation_id = bc('adm')),
          array[u('adm')], 'adm is the only member of adm''s chat');
select fresh(id) from chat;

-- 3 reads -------------------------------------------------------------------------------
select from (select say('own', bc('own'), 'seed text')) x;
-- controls: the flagged member with a live session sees all of it
select as_('own');
select is((select count(*) from public.conversations where id = bc('own')), 1::bigint, 'control: own sees the chat');
select ok((select count(*) from public.messages where conversation_id = bc('own')) >= 1, 'control: own sees its messages');
select is((select count(*) from public.conversation_previews where conversation_id = bc('own')), 1::bigint, 'control: own sees its preview');
reset role;
select as_('adm');
select is((select count(*) from public.conversations where id = bc('adm')), 1::bigint, 'control: adm sees adm''s chat while flagged');
reset role;
select as_('rev');
select is((select count(*) from public.conversations where id = bc('rev')), 1::bigint, 'control: rev sees rev''s chat while the session lives');
reset role;

create function sees(n text, conv uuid) returns bigint language plpgsql as $$
declare c bigint;
begin
  if n = 'anon' then
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    execute 'set local role anon';
  else
    perform as_(n);
  end if;
  c := (select count(*) from public.conversations where id = conv)
     + (select count(*) from public.messages where conversation_id = conv)
     + (select count(*) from public.conversation_members where conversation_id = conv)
     + (select count(*) from public.conversation_previews where conversation_id = conv);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return c;
exception when insufficient_privilege then
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return 0;
end $$;

select is(sees('anon', bc('own')), 0::bigint, 'anon sees nothing of the chat');
select is(sees('mal', bc('own')), 0::bigint, 'a user without the flag sees nothing of the owner''s chat');
-- mal made a member by hand: now only the flag is missing
select set_config('app_private.admin_write', 'on', true);
insert into public.conversation_members(conversation_id, user_id) values (bc('own'), u('mal'));
select set_config('app_private.admin_write', '', true);
select is(say('mal', bc('own'), '/podium'), 'err:42501', 'a member without the flag cannot send (fails only the flag)');
select set_config('app_private.admin_write', 'on', true);
delete from public.conversation_members where conversation_id = bc('own') and user_id = u('mal');
select set_config('app_private.admin_write', '', true);
select is(sees('adm', bc('own')), 0::bigint, 'one command admin sees nothing of another admin''s chat');
select is(say('adm', bc('own'), '/podium'), 'err:42501', 'one command admin cannot send in another admin''s chat');

delete from app_private.command_admins where user_id = u('adm');
select is((select count(*) from public.conversation_members where conversation_id = bc('adm')), 0::bigint,
          'removing the flag removes the membership');
select is(sees('adm', bc('adm')), 0::bigint, 'a user whose flag was removed sees nothing (chat, history, preview)');
select is(say('adm', bc('adm'), '/podium'), 'err:42501', 'a user whose flag was removed cannot send');

delete from auth.sessions where id = s('rev')::uuid;
select is(sees('rev', bc('rev')), 0::bigint, 'a revoked session sees nothing, though still flagged and a member');
select is(say('rev', bc('rev'), '/podium'), 'err:42501', 'a revoked session cannot send');
select is(say('anon', bc('own'), '/podium'), 'err:42501', 'anon cannot send');
-- the flag opens only the Bacanaks chat: not another system chat the admin is in
insert into public.conversations(id, system) values ('bd0c0000-0000-0000-0000-000000000005', true);
insert into public.conversation_members(conversation_id, user_id) values ('bd0c0000-0000-0000-0000-000000000005', u('own'));
select is(say('own', 'bd0c0000-0000-0000-0000-000000000005', 'hi'), 'err:42501', 'a command admin cannot send in another system chat');

-- 4 sends: plain text only, as yourself ---------------------------------------------------
create function try_own(stmt text) returns text language plpgsql as $$
begin
  perform as_('own');
  execute stmt;
  execute 'reset role';
  return 'ok';
exception when others then
  execute 'reset role';
  return 'err:' || sqlstate;
end $$;
create table keep as select id from public.messages where conversation_id = bc('own') limit 1;
grant select on keep to authenticated;
select is(try_own(format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'x')$$, bc('own'), u('own'))),
          'ok', 'control: own sends plain text');
select is(try_own(format($$insert into public.messages(conversation_id, sender_id, body) values (%L, '00000000-0000-0000-0000-00000000ad41', 'x')$$, bc('own'))),
          'err:42501', 'own cannot send as the server account');
select is(try_own(format($$insert into public.messages(conversation_id, sender_id, body, attachment_path) values (%L, %L, 'x', 'a/b.jpg')$$, bc('own'), u('own'))),
          'err:42501', 'no attachment');
select is(try_own(format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'x', (select id from keep))$$, bc('own'), u('own'))),
          'err:42501', 'no reply');
select is(try_own(format($$insert into public.messages(conversation_id, sender_id, body, forwarded) values (%L, %L, 'x', true)$$, bc('own'), u('own'))),
          'err:42501', 'no forward');
select matches(try_own(format($$insert into public.messages(conversation_id, sender_id, body, link_preview) values (%L, %L, 'x', '{}')$$, bc('own'), u('own'))),
          '^err:', 'no link preview');
select is(try_own(format($$insert into public.messages(conversation_id, sender_id, ciphertext) values (%L, %L, 'QUFB')$$, bc('own'), u('own'))),
          'err:42501', 'no ciphertext');
select fresh(bc('own'));

-- 5 exact /podium only -------------------------------------------------------------------
create table j0 as select jobs() as n;
select is(say('own', bc('own'), t), 'ok', 'fixture: own sends ' || t) from unnest(array['/podium x', 'podium', '/podiumx', '/podium set 5', '/podiumoff']) t;
select is(jobs(), (select n from j0), 'no text but /podium makes a job');
select is((select jsonb_agg(e->>'k') from jsonb_array_elements(fresh(bc('own'))) e), '["podUnk","podUnk","podUnk","podUnk","podUnk"]'::jsonb,
          'each non-command gets podUnk');
select is((select off from app_private.podium_state), false, '/podiumoff in the Bacanaks chat does not switch anything');
select is((select count(*) from public.messages where conversation_id = bc('own') and sender_id = '00000000-0000-0000-0000-00000000ad41'
             and body like '%set 5%'), 0::bigint, 'the typed text is never echoed back');

-- 8, 12 one ask: a job for the Istanbul business day -----------------------------------------
create table c0 as select cmds() as n;
select is(say('own', bc('own'), '/podium'), 'ok', 'own asks /podium');
select is(jobs(), (select n from j0) + 1, 'one ask makes one job');
select is((select prev from app_private.podium_jobs where state = 'pending'), want_prev(), 'prev = Istanbul time before 07:30');
select is((select day from app_private.podium_jobs where state = 'pending'), want_day(), 'day = the Istanbul business day');
select is(fresh(bc('own')), '[]'::jsonb, 'no reply before Vega answers');
select is(cmds(), (select n from c0) + 1, 'one audit row for the ask');

-- 9 a second ask while the fetch runs waits ------------------------------------------------
select is(say('own', bc('own'), '/podium'), 'ok', 'own asks again while the job is pending');
select is((select count(*) from app_private.podium_jobs where state = 'pending'), 1::bigint, 'still only one job goes to Vega');
create table claimed as select public.podium_job_claim((select id from app_private.podium_jobs where state = 'pending')) as c;
select is((select c from claimed), jsonb_build_object('day', want_day(), 'prev', want_prev()), 'claim returns the day and prev');
select is(public.podium_job_claim((select id from app_private.podium_jobs where state = 'running')), null, 'a second claim of the same job gets nothing');
select is(public.podium_job_claim(gen_random_uuid()), null, 'claiming an unknown job gets nothing');
select is(say('own', bc('own'), '/podium'), 'ok', 'own asks a third time while the job runs');
select is((select count(*) from app_private.podium_jobs where state in ('pending', 'running')), 1::bigint, 'still one job at Vega');
select public.podium_job_finish((select id from app_private.podium_jobs where state = 'running'), '4815162342', null);
create table r1 as select fresh(bc('own')) as v;
select is(jsonb_array_length((select v from r1)), 3, 'every waiting ask gets an answer');
select is((select count(distinct e) from jsonb_array_elements((select v from r1)) e), 1::bigint, 'all three get the same answer');
select is((select v->0->>'k' from r1), want_k(), 'k = pod, or podPrev before 07:30');
select is((select v->0->>'amt' from r1), '4815162342', 'the answer carries the amount');
select is((select (v->0->>'day')::date from r1), want_day(), 'the answer names the business day');
select is((select (v->0->>'at')::timestamptz from r1), now(), 'the answer carries the fetch time');
select is((select count(*) from app_private.podium_jobs where state in ('pending', 'running', 'waiting')), 0::bigint, 'no job is left open');

-- 13 the amount is never in a body, a preview, an audit row or a push ----------------------------
select is((select count(*) from public.messages where body like '%4815162342%'), 0::bigint, 'no message body holds the amount');
select as_('own');
select is((select count(*) from public.conversation_previews where conversation_id = bc('own') and body like '%4815162342%'), 0::bigint,
          'the chat-list preview text never holds the amount');
reset role;
select is((select count(*) from app_private.podium_commands c where c::text like '%4815162342%'), 0::bigint, 'no audit row holds the amount');
select is((select count(*) from public.messages where conversation_id in (select id from chat) and admin_push), 0::bigint,
          'no reply in a Bacanaks chat is flagged for push');
select isnt(vault.create_secret('https://bd-test.local/notify', 'notify_on_message_url'), null, 'fixture: a notify URL is configured');
create table q0 as select coalesce(max(id), 0) as n from net.http_request_queue;
update app_private.podium_state set fetched_at = now() - interval '31 seconds';
select from (select say('own', bc('own'), '/podium')) x;
select vega('7770001', null);
select is(jsonb_array_length(fresh(bc('own'))), 1, 'fixture: a reply was written');
select is((select count(*) from net.http_request_queue where id > (select n from q0) and url = 'https://bd-test.local/notify'), 0::bigint,
          'an ask and its reply queue no push');

-- both answer kinds, whatever the clock says now: the job's own prev decides
create function answer_for(p boolean, amount text) returns jsonb language plpgsql as $$
declare j uuid;
begin
  insert into app_private.podium_jobs(conversation_id, prev, day) values (bc('own'), p, date '2026-01-05') returning id into j;
  perform public.podium_job_claim(j);
  perform public.podium_job_finish(j, amount, null);
  return (select jsonb_build_object('m', admin_msg, 'b', body) from public.messages
           where conversation_id = bc('own') and admin_msg->>'amt' = amount);
end $$;
select fresh(bc('own'));
select is((select answer_for(false, '7770008')), jsonb_build_object('b', 'Total money',
            'm', jsonb_build_object('k', 'pod', 'at', now(), 'amt', '7770008', 'day', '2026-01-05')),
          'a current-day answer: k pod, body "Total money" only');
select is((select answer_for(true, '7770009')), jsonb_build_object('b', 'Previous day''s total',
            'm', jsonb_build_object('k', 'podPrev', 'at', now(), 'amt', '7770009', 'day', '2026-01-05')),
          'a previous-day answer: k podPrev, body "Previous day''s total" only');
select fresh(bc('own'));
update app_private.podium_state set amount = '7770001', day = want_day(), fetched_at = now() - interval '31 seconds';

-- 9 the 30 s shared cache ---------------------------------------------------------------------
create table j1 as select jobs() as n;
update app_private.podium_state set fetched_at = now() - interval '29 seconds';
insert into app_private.command_admins(user_id) values (u('adm'));
create table chat2 as select c.id from public.conversations c join public.conversation_members m on m.conversation_id = c.id
   where c.bacanaks_chat and m.user_id = u('adm');
select fresh((select id from chat2));
select is(say('adm', (select id from chat2), '/podium'), 'ok', 'adm (flag given back) asks 29 s after the fetch');
select is(jobs(), (select n from j1), 'within 30 s nobody calls Vega again, even another admin');
create table r2 as select fresh((select id from chat2)) as v;
select is((select v->0->>'amt' from r2), '7770001', 'the other admin gets the cached amount at once');
select is((select (v->0->>'at')::timestamptz from r2), now() - interval '29 seconds', 'with the ORIGINAL fetch time');
update app_private.podium_state set fetched_at = now() - interval '31 seconds';
select is(say('own', bc('own'), '/podium'), 'ok', 'own asks 31 s after the fetch');
select is(jobs(), (select n from j1) + 1, 'after 30 s a new job goes to Vega');
select is(fresh(bc('own')), '[]'::jsonb, 'and no stale answer is given');
select vega('7770002', null);
select fresh(bc('own'));
update app_private.podium_state set day = want_day() - 3, fetched_at = now();
select is(say('own', bc('own'), '/podium'), 'ok', 'own asks while the cache holds another day');
select is(fresh(bc('own')), '[]'::jsonb, 'a cached total of another day is never served');
select vega('7770003', null);
select fresh(bc('own'));

-- 12, 13 amount validation: a bad amount is a failure, never stored or shown -------------------------
insert into audit_log select c::text from app_private.podium_commands c; delete from app_private.podium_commands;
create table bad(a text);
insert into bad values ('12.345 TL'), ('₺100'), ('-5'), ('1e5'), (' 12 '), (''), (E'12\n34'), ('<b>1</b>'), (repeat('9', 200)), ('١٢٣'), (null);
create table badr(a text, v jsonb, stored text);
do $$ declare r record; begin
  for r in select a from bad loop
    update app_private.podium_state set fetched_at = now() - interval '31 seconds', fail_count = 0, off = false where only_row;
    perform say('own', bc('own'), '/podium');
    perform vega(r.a, null);
    insert into badr values (r.a, fresh(bc('own')), (select amount from app_private.podium_state));
  end loop;
end $$;
select is((select count(*) from badr where v = '[{"k":"podFail"}]'::jsonb), 11::bigint, 'each malformed or missing amount -> exactly one podFail');
select is((select count(*) from badr where stored is distinct from '7770003'), 0::bigint, 'a malformed amount never replaces the stored one');
select is((select count(*) from public.messages m, bad b where b.a <> '' and m.body like '%' || b.a || '%'), 0::bigint,
          'a malformed amount is never shown');
select is((select count(*) from badr where v::text like '%"amt"%'), 0::bigint, 'a failure reply carries no amount');
select is((select body from public.messages where admin_msg->>'k' = 'podFail' limit 1), 'Vega did not answer.', 'the failure text is fixed');

-- 11 three login failures in a row turn the command off -------------------------------------------
-- (each section below starts with an empty audit for its askers: the rate limit is tested on its own)
insert into audit_log select c::text from app_private.podium_commands c; delete from app_private.podium_commands;
create function fail_once(reason text) returns void language plpgsql as $$
begin
  update app_private.podium_state set fetched_at = now() - interval '31 seconds';
  perform say('own', bc('own'), '/podium');
  perform vega(null, reason);
  perform fresh(bc('own'));
end $$;
update app_private.podium_state set fail_count = 0, off = false where only_row;
select fail_once('config'); select fail_once('config'); select fail_once('config'); select fail_once('config');
select is((select off from app_private.podium_state), false, 'four config failures (reader not set up) do not turn it off');
select is((select fail_count from app_private.podium_state), 0, 'a config failure is not counted');
select fail_once('timeout'); select fail_once('shape');
select is((select off from app_private.podium_state), false, 'two failures: still on');
update app_private.podium_state set fetched_at = now() - interval '31 seconds' where only_row;
select from (select say('own', bc('own'), '/podium')) x; select vega('7770004', null); select fresh(bc('own'));
select fail_once('login');
select is((select off from app_private.podium_state), false, 'timeout, shape, success, login: not three in a row, still on');
select fail_once('shape'); select fail_once('other');
select is((select off from app_private.podium_state), true, 'three non-config failures in a row (login, shape, other) turn the command off');
create table j2 as select jobs() as n;
select is(say('own', bc('own'), '/podium'), 'ok', 'own asks while it is off');
select is(fresh(bc('own')), '[{"k":"podOff"}]'::jsonb, 'an ask while off -> podOff');
select is(jobs(), (select n from j2), 'and Vega is not called');

-- 10 the switch lives in the owner's admin chat --------------------------------------------------
select is(say('own', (select id from adm), '/podiumon'), 'ok', 'the owner types /podiumon in the admin chat');
select is((select admin_msg->>'k' from public.messages where conversation_id = (select id from adm)
             and sender_id = '00000000-0000-0000-0000-00000000ad41' order by created_at desc, (admin_msg->>'k' = 'podSwOn') desc limit 1),
          'podSwOn', 'and gets podSwOn');
select is((select off from app_private.podium_state), false, '/podiumon turns it on');
select fail_once('login');
select is((select off from app_private.podium_state), false, 'after /podiumon one login failure does not turn it off again');
select is(say('own', (select id from adm), '/podiumoff'), 'ok', 'the owner types /podiumoff in the admin chat');
select is((select off from app_private.podium_state), true, '/podiumoff turns it off');
select is(say('adm', (select id from chat2), '/podiumon'), 'ok', 'fixture: adm types /podiumon in adm''s chat');
select is((select off from app_private.podium_state), true, 'a command admin cannot switch it from the Bacanaks chat');
select is(fresh((select id from chat2)) -> 0 ->> 'k', 'podUnk', 'and gets podUnk');
select from (select say('own', (select id from adm), '/podiumon')) x;

-- 7 audit, 6 rate limit -----------------------------------------------------------------------------
insert into audit_log select c::text from app_private.podium_commands c; delete from app_private.podium_commands;
create table c1 as select cmds() as n;
select from (select say('adm', (select id from chat2), t) from unnest(array['/podium', 'hello', '/podium']) t) x;
select is(cmds(), (select n from c1) + 3, 'one audit row per command, known or not');
select ok((select bool_and(user_id = u('adm') and at = now()) from app_private.podium_commands
            where at = now() and user_id = u('adm')), 'each audit row names the user and the time');
select is((select count(*) from app_private.podium_commands where command not in ('/podium', 'unknown')), 0::bigint,
          'the audit never stores free text the user typed');
select fresh((select id from chat2));
select vega('7770005', null);
select fresh((select id from chat2));

insert into audit_log select c::text from app_private.podium_commands c; delete from app_private.podium_commands where user_id = u('adm');
insert into app_private.podium_commands(user_id, at, command, outcome)
  select u('adm'), now() - interval '11 minutes', '/podium', 'cache' from generate_series(1, 50);
insert into app_private.podium_commands(user_id, at, command, outcome)
  select u('adm'), now() - interval '9 minutes', '/podium', 'cache' from generate_series(1, 29);
update app_private.podium_state set fetched_at = now();
select is(say('adm', (select id from chat2), '/podium'), 'ok', 'the 30th command in 10 minutes');
select is(fresh((select id from chat2)) -> 0 ->> 'k', want_k(), 'is answered (older commands do not count)');
create table j3 as select jobs() as n;
update app_private.podium_state set fetched_at = now() - interval '31 seconds';
select is(say('adm', (select id from chat2), '/podium'), 'ok', 'the 31st command in 10 minutes');
select is(fresh((select id from chat2)), '[{"k":"podRate"}]'::jsonb, 'is refused with podRate');
select is(jobs(), (select n from j3), 'and calls nobody');
select is(say('own', bc('own'), '/podium'), 'ok', 'the limit is per user: own still asks');
select is(jobs(), (select n from j3) + 1, 'own''s ask makes a job');
select vega('7770006', null);

insert into audit_log select c::text from app_private.podium_commands c; delete from app_private.podium_commands;
-- dispatch: a job sends only its id and the shared secret header, to the Vault URL ---------------------
select isnt(vault.create_secret('https://bd-test.local/podium', 'podium_url'), null, 'fixture: the podium URL is configured');
select isnt(vault.create_secret('bd-shared-value', 'podium_secret'), null, 'fixture: the shared secret is configured');
create table q1 as select coalesce(max(id), 0) as n from net.http_request_queue;
update app_private.podium_state set fetched_at = now() - interval '31 seconds';
select from (select say('own', bc('own'), '/podium')) x;
select is((select count(*) from net.http_request_queue where id > (select n from q1) and url = 'https://bd-test.local/podium'), 1::bigint,
          'one job -> one call to the podium function');
select is((select convert_from(body, 'utf8')::jsonb from net.http_request_queue where id > (select n from q1) and url = 'https://bd-test.local/podium'),
          jsonb_build_object('job_id', (select id from app_private.podium_jobs where state = 'pending')),
          'the call carries only the job id');
select is((select headers->>'x-podium-secret' from net.http_request_queue where id > (select n from q1) and url = 'https://bd-test.local/podium'),
          'bd-shared-value', 'with the shared secret header');

-- round 2 ------------------------------------------------------------------------------------------
select vega('7770007', null); select fresh(bc('own'));
insert into audit_log select c::text from app_private.podium_commands c; delete from app_private.podium_commands;

-- amount rule (same in edge and SQL): <= 25 chars and
-- ^[0-9]{1,3}([.,' ][0-9]{3})*([.,][0-9]{1,2})?$ | ^[0-9]+([.,][0-9]{1,2})?$; else a 'shape' failure (counted)
create table amt_case(a text, good boolean);
insert into amt_case values
  ('12.345,67', true), ('1234', true), ('0', true), ('1,5', true), ('1.23', true), ('1''234', true),
  ('1 234,5', true), ('999.999.999,99', true), (repeat('1', 25), true), ('12.345.678.901.234.567,89', true),
  ('1234567,89', true),
  ('1.2.3,4,5', false), ('1,', false), ('1.', false), ('.5', false), ('1234.567', false), ('12,34,567', false),
  ('1..2', false), ('1,234,5678', false), (repeat('1', 26), false), ('123.456.789.012.345.678,90', false),
  ('1,234', true);
create table amt_res(a text, good boolean, v jsonb, stored text, fc int);
do $$ declare r record; begin
  for r in select a, good from amt_case loop
    delete from app_private.podium_commands;
    update app_private.podium_state set amount = 'before', fetched_at = now() - interval '31 seconds',
      fail_count = case when r.good then 2 else 0 end, off = false where only_row;
    perform say('own', bc('own'), '/podium');
    perform vega(r.a, null);
    insert into amt_res select r.a, r.good, fresh(bc('own')), amount, fail_count from app_private.podium_state;
  end loop;
end $$;
select is(jsonb_build_object('amt', v->0->>'amt', 'k_ok', v->0->>'k' in ('pod', 'podPrev'), 'n', jsonb_array_length(v), 'stored', stored, 'fc', fc),
          jsonb_build_object('amt', a, 'k_ok', true, 'n', 1, 'stored', a, 'fc', 0),
          'amount ' || quote_literal(a) || ' is accepted: answered, stored as is, fail count reset')
  from amt_res where good order by a;
select is(jsonb_build_object('v', v, 'stored', stored, 'fc', fc),
          jsonb_build_object('v', '[{"k":"podFail"}]'::jsonb, 'stored', 'before', 'fc', 1),
          'amount ' || quote_literal(a) || ' is refused: podFail, not stored, counted as a failure')
  from amt_res where not good order by a;
delete from app_private.podium_commands;

-- auto-off: a failure with no reason (null) counts; 'config' never turns it off
update app_private.podium_state set fail_count = 0, off = false where only_row;
select fail_once(null);
select is((select fail_count from app_private.podium_state), 1, 'a failure with a null reason adds 1');
select fail_once(null);
select is((select (fail_count, off)::text from app_private.podium_state), '(2,f)', 'two null-reason failures: still on');
select fail_once(null);
select is((select off from app_private.podium_state), true, 'three null-reason failures in a row turn it off');
update app_private.podium_state set fail_count = 2, off = false where only_row;
select fail_once('config'); select fail_once('config');
select is((select off from app_private.podium_state), false, 'config failures on top of two counted ones never turn it off');
select ok((select fail_count < 3 from app_private.podium_state), 'and never push the count to 3');
update app_private.podium_state set fail_count = 0, off = false where only_row;
delete from app_private.podium_commands;

-- business day: app_private.podium_business_day(timestamptz), Istanbul, before 07:30 = previous day
create function ist(t timestamp) returns timestamptz language sql immutable as $$ select timezone('Europe/Istanbul', t) $$;
select is(app_private.podium_business_day(ist('2026-10-29 07:29:59')), date '2026-10-28', 'Istanbul 07:29:59 -> previous day');
select is(app_private.podium_business_day(ist('2026-10-29 07:30:00')), date '2026-10-29', 'Istanbul 07:30:00 -> same day');
select is(app_private.podium_business_day(ist('2026-10-29 00:00:00')), date '2026-10-28', 'Istanbul 00:00 -> previous day');
select is(app_private.podium_business_day(ist('2026-10-29 23:59:59')), date '2026-10-29', 'Istanbul 23:59:59 -> same day');
select is(app_private.podium_business_day('2026-10-29 00:00:00+00'), date '2026-10-28', 'UTC midnight (03:00 Istanbul) -> previous day');
select is(app_private.podium_business_day('2026-10-29 05:00:00+00'), date '2026-10-29', 'UTC 05:00 (08:00 Istanbul) -> same day, not the UTC answer');
select is(app_private.podium_business_day('2026-10-28 21:30:00+00'), date '2026-10-28', 'UTC 21:30 (00:30 next day in Istanbul) -> the UTC date');
select is(app_private.podium_business_day(ist('2027-01-01 07:00:00')), date '2026-12-31', 'New Year 07:00 Istanbul -> 31 December');
set local timezone = 'Pacific/Kiritimati';
select is(app_private.podium_business_day(ist('2026-10-29 07:30:00')), date '2026-10-29', 'session time zone +14: 07:30 Istanbul still the same day');
select is(app_private.podium_business_day(ist('2026-10-29 07:29:59')), date '2026-10-28', 'session time zone +14: 07:29:59 Istanbul still the previous day');
set local timezone = 'America/Los_Angeles';
select is(app_private.podium_business_day(ist('2026-10-29 07:30:00')), date '2026-10-29', 'session time zone -07: 07:30 Istanbul still the same day');
reset timezone;
select function_returns('app_private', 'podium_business_day', array['timestamp with time zone'], 'date', 'it returns a date');
select volatility_is('app_private', 'podium_business_day', array['timestamp with time zone'], 'immutable', 'it is immutable');
select ok(not has_function_privilege('anon', 'app_private.podium_business_day(timestamptz)', 'execute'), 'anon may not call it');
select ok(not has_function_privilege('authenticated', 'app_private.podium_business_day(timestamptz)', 'execute'), 'authenticated may not call it');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid = 'app_private.podium_business_day(timestamptz)'::regprocedure and a.grantee = 0),
          'it is not granted to public');

-- the ask path uses it: with the function stubbed, the job and the cache follow the stub
create or replace function app_private.podium_business_day(at timestamptz) returns date language sql immutable as $$ select date '2001-02-03' $$;
update app_private.podium_state set fetched_at = now() - interval '31 seconds' where only_row;
create table j9 as select id from app_private.podium_jobs;
select is(say('own', bc('own'), '/podium'), 'ok', 'fixture: own asks with the business day stubbed');
select is((select day from app_private.podium_jobs where id not in (select id from j9)), date '2001-02-03',
          'the job is for the day podium_business_day returns');
select vega('5', null); select fresh(bc('own'));
update app_private.podium_state set fetched_at = now() - interval '5 seconds' where only_row;
create table j10 as select jobs() as n;
select from (select say('own', bc('own'), '/podium')) x;
select is(fresh(bc('own'))->0->>'amt', '5', 'a fresh cache of the stubbed day is served');
select is(jobs(), (select n from j10), 'without a new job: the cache day check uses podium_business_day too');

-- last: nothing anywhere ever held an amount outside the answer's admin_msg
select is((select count(*) from app_private.podium_commands c where c::text ~ '(777000[0-9]|4815162342)')
            + (select count(*) from audit_log where r ~ '(777000[0-9]|4815162342)'), 0::bigint,
          'after every path (ask, wait, cache, fail, rate), no audit row holds an amount');
select is((select count(*) from public.messages where body ~ '(777000[0-9]|4815162342)'), 0::bigint,
          'after every path, no message body holds an amount');

select * from finish();
rollback;
