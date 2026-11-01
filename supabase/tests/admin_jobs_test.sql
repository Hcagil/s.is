begin;
select plan(86);

-- Admin chat, slice 2 (step 15): the Apple/TestFlight job lifecycle.
-- Written from the contract, not from the migration:
--
-- 1. grants: the five job RPCs are for service_role only; the internal
--    admin_job_end, admin_jobs_dispatch and admin_jobs_sweep for nobody.
-- 2. the insert trigger posts {job_id} to the vault URL admin_apple_url; with
--    no URL, or pg_net failing, the insert still succeeds.
-- 3. dispatch: true for the first caller only.
-- 4. dispatch_failed: only while run_id is null; ends the job failed + reply.
-- 5. claim: sweeps first; pending + run_id null only; binds run_id, running,
--    attempts = 1; one claim only.
-- 6. progress (attempt 2 -> p2 / r2) and finish (p3 / r3, or fail / failRm
--    with r = reason, admin_push) need the run_id; finishing nulls the email
--    in the same update that ends the job. Unknown reasons become timeout.
-- 7. sweep: pending/running jobs older than 15 minutes fail with timeout, on
--    claim and on every owner command.
-- 8. app_private.admin_write is '' after a reply is written.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Runs [stmt] as service_role (how the edge functions call the RPCs).
create or replace function svc(stmt text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
  begin
    execute stmt into r;
  exception when others then
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return 'err:' || sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return coalesce(r, 'null');
end $$;
grant execute on function svc(text) to service_role;

-- fixtures ------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ab001', 'jown@mail.test', now(), '{"full_name":"Jown"}');
insert into app_private.allowlist(email) values ('jown@mail.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ab000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ab001', now(), now());
select test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'fixture: the owner is active');
reset role;
insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000ab001');
create temp table adm as select id from public.conversations where admin_chat and not bacanaks_chat;
grant select on adm to authenticated;
select is((select count(*) from adm), 1::bigint, 'fixture: one admin conversation');

-- New replies from the system account since the last call: [{id, k, r, e, push, txt}].
create temp table seen(id uuid primary key);
create function fresh() returns jsonb language plpgsql as $$
declare r jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'k', m.admin_msg->>'k', 'r', m.admin_msg->>'r', 'e', m.admin_msg->>'e',
           'push', m.admin_push, 'txt', lower(coalesce(m.body, '') || ' ' || coalesce(m.admin_msg::text, '')))
           order by m.created_at), '[]') into r
    from public.messages m
   where m.conversation_id = (select id from adm)
     and m.sender_id = '00000000-0000-0000-0000-00000000ad41'
     and m.id not in (select id from seen);
  insert into seen select m.id from public.messages m
   where m.conversation_id = (select id from adm) on conflict do nothing;
  return r;
end $$;

create temp table j(name text primary key, id uuid);

-- The owner types [t] in the admin chat, as the app does. The command log is
-- then aged an hour so this file's many commands stay under the rate limit.
create function cmd(t text) returns void language plpgsql as $$
begin
  perform test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
  insert into public.messages(conversation_id, sender_id, body)
    values ((select id from adm), '00000000-0000-0000-0000-0000000ab001', t);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  update app_private.admin_commands set at = at - interval '1 hour';
end $$;

-- A job queued the production way: /addiostester for add; for remove the
-- tester is on the list, the owner sends /removetester and answers yes.
create function job(k text, e text) returns uuid language plpgsql as $$
declare r uuid; card uuid;
begin
  if k = 'add' then
    perform cmd('/addiostester ' || e);
  else
    insert into app_private.allowlist(email) values (e) on conflict do nothing;
    perform cmd('/removetester ' || e);
    select card_message_id into card from app_private.admin_pending where email = e and state = 'pending';
    perform test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
    perform public.admin_answer(card, true);
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
  end if;
  select id into r from app_private.admin_jobs where email = e and kind = k and state = 'pending';
  if r is null then raise exception 'fixture: no pending % job for %', k, e; end if;
  return r;
end $$;
create function aged(n text, a interval) returns void language sql as $$
  update app_private.admin_jobs set created_at = now() - a where id = (select id from j where name = n)
$$;
create function st(j uuid) returns text language sql as $$
  select state || ':' || coalesce(fail_reason, '-') || ':' || coalesce(email, 'null') || ':' ||
         case when finished_at is null then 'open' else 'closed' end
    from app_private.admin_jobs where id = j
$$;

-- 1 grants ---------------------------------------------------------------------
create temp table rpc(sig text);
insert into rpc values ('public.admin_job_dispatch(uuid)'), ('public.admin_job_dispatch_failed(uuid, text)'),
  ('public.admin_job_claim(uuid, bigint)'), ('public.admin_job_progress(uuid, bigint, integer)'),
  ('public.admin_job_finish(uuid, bigint, boolean, text)');
select ok(bool_and(has_function_privilege('service_role', sig, 'execute')), 'service_role may execute every job RPC') from rpc;
select ok(not bool_or(has_function_privilege('anon', sig, 'execute')), 'anon may execute no job RPC') from rpc;
select ok(not bool_or(has_function_privilege('authenticated', sig, 'execute')), 'authenticated may execute no job RPC') from rpc;
select ok(not exists (select 1 from rpc, pg_proc p, aclexplode(p.proacl) a
                       where p.oid = sig::regprocedure and a.grantee = 0), 'no job RPC is granted to public');
create temp table internal(sig text);
insert into internal values ('app_private.admin_job_end(uuid, boolean, text)'),
  ('app_private.admin_jobs_dispatch()'), ('app_private.admin_jobs_sweep()');
select ok(not bool_or(has_function_privilege(r, sig, 'execute')),
          r || ' may execute none of admin_job_end, admin_jobs_dispatch, admin_jobs_sweep')
  from internal, unnest(array['anon', 'authenticated', 'service_role']) r group by r order by r;
select ok(not exists (select 1 from internal, pg_proc p, aclexplode(p.proacl) a
                       where p.oid = sig::regprocedure and a.grantee = 0), 'the internal job functions are not granted to public');
select test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
select throws_ok($$select public.admin_job_claim(gen_random_uuid(), 1)$$, '42501', null,
                 'even the owner, as authenticated, is refused admin_job_claim');
select throws_ok($$select public.admin_job_dispatch(gen_random_uuid())$$, '42501', null,
                 'and admin_job_dispatch');
reset role;
set local role anon;
select throws_ok($$select public.admin_job_finish(gen_random_uuid(), 1, true, null)$$, '42501', null,
                 'anon is refused admin_job_finish');
reset role;

-- 2 the insert trigger ------------------------------------------------------------
create temp table q0 as select coalesce(max(id), 0) as n from net.http_request_queue;
select lives_ok($$insert into j values ('nourl', job('add', 'nourl@mail.test'))$$,
                'with no admin_apple_url secret, queueing a job still succeeds');
select is((select count(*) from net.http_request_queue where id > (select n from q0)), 0::bigint,
          'and nothing is posted');
select isnt(vault.create_secret('https://aj-test.local/admin-apple', 'admin_apple_url'), null, 'fixture: the URL is configured');
insert into j values ('posted', job('add', 'posted@mail.test'));
select is((select count(*) from net.http_request_queue where id > (select n from q0)), 1::bigint,
          'a new job posts exactly one request');
select is((select url from net.http_request_queue where id > (select n from q0)), 'https://aj-test.local/admin-apple',
          'to the admin_apple_url secret');
select is((select convert_from(body, 'utf8')::jsonb from net.http_request_queue where id > (select n from q0)),
          jsonb_build_object('job_id', (select id from j where name = 'posted')), 'with body {job_id} only');

-- pg_net refusing the URL (it raises on a malformed one) must not cost the job
select vault.update_secret((select id from vault.secrets where name = 'admin_apple_url'), 'not a url');
select lives_ok($$insert into j values ('neterr', job('add', 'neterr@mail.test'))$$,
                'pg_net raising does not fail the job insert (warns, never raises)');
select is((select state from app_private.admin_jobs where id = (select id from j where name = 'neterr')), 'pending',
          'and the job is kept pending');
select vault.update_secret((select id from vault.secrets where name = 'admin_apple_url'), 'https://aj-test.local/admin-apple');

-- 3 dispatch --------------------------------------------------------------------
select is(svc(format('select public.admin_job_dispatch(%L)::text', (select id from j where name = 'posted'))), 'true',
          'dispatch: the first caller gets true');
select is(svc(format('select public.admin_job_dispatch(%L)::text', (select id from j where name = 'posted'))), 'false',
          'dispatch: the second caller gets false');
select is(svc(format('select public.admin_job_dispatch(%L)::text', gen_random_uuid())), 'false',
          'dispatch: an unknown job gets false');

-- 4 dispatch_failed ----------------------------------------------------------------
select fresh();
select is(svc(format('select public.admin_job_dispatch_failed(%L, %L)::text', (select id from j where name = 'posted'), 'dispatch')),
          '', 'dispatch_failed runs as service_role');
select is(st((select id from j where name = 'posted')), 'failed:dispatch:null:closed',
          'dispatch_failed before a claim: failed, reason dispatch, email nulled, finished');
create temp table rep(name text primary key, v jsonb);
insert into rep select 'df', fresh();
select is(jsonb_array_length((select v from rep where name = 'df')), 1, 'it posts one reply');
select ok((select v @> '[{"k":"fail","r":"dispatch","push":true}]' from rep where name = 'df'),
          'k = fail, r = dispatch, flagged admin_push');
select is((select position('posted@mail.test' in v::text) from rep where name = 'df'), 0, 'the reply holds no raw email');
select ok((select v @> '[{"e":"p***@m***.test"}]' from rep where name = 'df'), 'it carries the masked email as e');
select ok((select v->0->>'txt' like '%apple step failed for p***@m***.test:%' from rep where name = 'df'),
          'and its text names the masked email');
select is(svc(format('select public.admin_job_claim(%L, 101)::text', (select id from j where name = 'posted'))), 'null',
          'a failed job cannot be claimed');

insert into j values ('dfodd', job('remove', 'dfodd@mail.test'));
select fresh();
select svc(format('select public.admin_job_dispatch_failed(%L, %L)::text', (select id from j where name = 'dfodd'), 'no-such-reason'));
select is(st((select id from j where name = 'dfodd')), 'failed:timeout:null:closed', 'an unknown reason becomes timeout');
select ok(fresh() @> '[{"k":"failRm","r":"timeout","push":true}]', 'a remove job fails with failRm, r = timeout');

insert into j values ('dfclaimed', job('add', 'dfclaimed@mail.test'));
select svc(format('select public.admin_job_claim(%L, 102)::text', (select id from j where name = 'dfclaimed')));
select fresh();
select svc(format('select public.admin_job_dispatch_failed(%L, %L)::text', (select id from j where name = 'dfclaimed'), 'dispatch'));
select is(st((select id from j where name = 'dfclaimed')), 'running:-:dfclaimed@mail.test:open',
          'dispatch_failed after a claim (run_id set) changes nothing');
select is(fresh(), '[]'::jsonb, 'and posts nothing');

-- 5 claim ---------------------------------------------------------------------------
insert into j values ('add1', job('add', 'add1@mail.test'));
select is(svc(format('select public.admin_job_claim(%L, 201)::text', (select id from j where name = 'add1')))::jsonb,
          '{"kind":"add","email":"add1@mail.test"}'::jsonb, 'claim returns {kind, email}');
select is((select state || ':' || run_id || ':' || attempts from app_private.admin_jobs where id = (select id from j where name = 'add1')),
          'running:201:1', 'claim binds run_id, state running, attempts 1');
select is(svc(format('select public.admin_job_claim(%L, 201)::text', (select id from j where name = 'add1'))), 'null',
          'a second claim by the same run gets null');
select is(svc(format('select public.admin_job_claim(%L, 999)::text', (select id from j where name = 'add1'))), 'null',
          'a claim by another run gets null');
select is((select run_id from app_private.admin_jobs where id = (select id from j where name = 'add1')), 201::bigint,
          'and the job stays bound to the first run');
select is(svc(format('select public.admin_job_claim(%L, 202)::text', gen_random_uuid())), 'null', 'an unknown job: null');
insert into j values ('rm1', job('remove', 'rm1@mail.test'));
select is(svc(format('select public.admin_job_claim(%L, 301)::text', (select id from j where name = 'rm1')))::jsonb,
          '{"kind":"remove","email":"rm1@mail.test"}'::jsonb, 'a remove job claims as kind remove');
-- a job somebody already bound to a run, but still labelled pending: run_id gate alone
insert into j values ('bound', job('add', 'bound@mail.test'));
update app_private.admin_jobs set run_id = 77 where id = (select id from j where name = 'bound');
select is(svc(format('select public.admin_job_claim(%L, 78)::text', (select id from j where name = 'bound'))), 'null',
          'a pending job that already has a run_id cannot be claimed');
-- running without a run_id: state gate alone
insert into j values ('runonly', job('add', 'runonly@mail.test'));
update app_private.admin_jobs set state = 'running' where id = (select id from j where name = 'runonly');
select is(svc(format('select public.admin_job_claim(%L, 79)::text', (select id from j where name = 'runonly'))), 'null',
          'a running job without a run_id cannot be claimed');

-- 6 progress and finish ----------------------------------------------------------------
select fresh();
select svc(format('select public.admin_job_progress(%L, 999, 2)::text', (select id from j where name = 'add1')));
select is(fresh(), '[]'::jsonb, 'progress with the wrong run posts nothing');
select is(svc(format('select public.admin_job_progress(%L, 201, 2)::text', (select id from j where name = 'add1'))), '',
          'progress with its own run runs');
select ok(fresh() @> '[{"k":"p2"}]', 'attempt 2 of an add posts p2');
select svc(format('select public.admin_job_progress(%L, 301, 2)::text', (select id from j where name = 'rm1')));
select ok(fresh() @> '[{"k":"r2"}]', 'attempt 2 of a remove posts r2');

select svc(format('select public.admin_job_finish(%L, 999, true, null)::text', (select id from j where name = 'add1')));
select is(st((select id from j where name = 'add1')), 'running:-:add1@mail.test:open',
          'finish with the wrong run changes nothing');
select is(fresh(), '[]'::jsonb, 'and posts nothing');
select is(svc(format('select public.admin_job_finish(%L, 201, true, null)::text', (select id from j where name = 'add1'))), '',
          'finish with its own run runs');
select is(st((select id from j where name = 'add1')), 'ok:-:null:closed', 'a success ends ok, email nulled, finished, no reason');
insert into rep select 'p3', fresh();
select ok((select v @> '[{"k":"p3"}]' from rep where name = 'p3'), 'an add success posts p3');
select ok((select not v @> '[{"push":true}]' from rep where name = 'p3'), 'a success is not pushed');
select is(current_setting('app_private.admin_write', true), '', 'admin_write is empty after finish wrote its reply');

select svc(format('select public.admin_job_finish(%L, 301, true, null)::text', (select id from j where name = 'rm1')));
select ok(fresh() @> '[{"k":"r3"}]', 'a remove success posts r3');
select is(st((select id from j where name = 'rm1')), 'ok:-:null:closed', 'and ends ok with the email nulled');

-- The escalation push: notify_new_message posts the message id to the push
-- function, which reads that message; so the pushed content is the reply above.
select vault.create_secret(v.url, v.n)
  from (values ('https://aj-test.local/notify', 'notify_on_message_url')) v(url, n)
 where v.n not in (select name from vault.secrets);
create temp table q1 as select coalesce(max(id), 0) as n from net.http_request_queue;
insert into j values ('add2', job('add', 'add2@mail.test'));
select svc(format('select public.admin_job_claim(%L, 401)::text', (select id from j where name = 'add2')));
select fresh();
select svc(format('select public.admin_job_finish(%L, 401, false, %L)::text', (select id from j where name = 'add2'), 'rejected'));
select is(st((select id from j where name = 'add2')), 'failed:rejected:null:closed', 'a failure ends failed with its reason, email nulled');
insert into rep select 'fail', fresh();
select is(jsonb_array_length((select v from rep where name = 'fail')), 1, 'a failure posts one NEW message');
select ok((select v @> '[{"k":"fail","r":"rejected","push":true}]' from rep where name = 'fail'),
          'k = fail, r = rejected, flagged admin_push');
select is((select position('add2@mail.test' in v::text) from rep where name = 'fail'), 0, 'it holds no raw email');
select ok((select v @> '[{"e":"a***@m***.test"}]' from rep where name = 'fail'), 'it carries the masked email as e');
select ok((select v->0->>'txt' like '%apple step failed for a***@m***.test: %' from rep where name = 'fail'),
          'and its text (what the push shows) names the masked email');
select is((select count(*) from net.http_request_queue
            where id > (select n from q1)
              and convert_from(body, 'utf8')::jsonb = jsonb_build_object('record', jsonb_build_object('id', (select v->0->>'id' from rep where name = 'fail')))),
          1::bigint, 'the failure is pushed: one post carrying only its message id');
select is((select count(*) from net.http_request_queue
            where id > (select n from q1) and position('add2@mail.test' in convert_from(body, 'utf8')) > 0),
          0::bigint, 'no push request carries the raw email');

insert into j values ('rm2', job('remove', 'rm2@mail.test'));
select svc(format('select public.admin_job_claim(%L, 402)::text', (select id from j where name = 'rm2')));
select fresh();
select svc(format('select public.admin_job_finish(%L, 402, false, %L)::text', (select id from j where name = 'rm2'), 'dispatch'));
select is(st((select id from j where name = 'rm2')), 'failed:dispatch:null:closed', 'reason dispatch is kept');
insert into rep select 'failrm', fresh();
select ok((select v @> '[{"k":"failRm","r":"dispatch","push":true,"e":"r***@m***.test"}]' from rep where name = 'failrm'),
          'a remove failure posts failRm with the masked email, pushed');
select is((select position('rm2@mail.test' in v::text) from rep where name = 'failrm'), 0, 'and no raw email');

insert into j values ('add3', job('add', 'add3@mail.test'));
select svc(format('select public.admin_job_claim(%L, 403)::text', (select id from j where name = 'add3')));
select fresh();
select svc(format('select public.admin_job_finish(%L, 403, false, %L)::text', (select id from j where name = 'add3'), 'Apple said: x@mail.test'));
select is(st((select id from j where name = 'add3')), 'failed:timeout:null:closed', 'any other reason text becomes timeout');
insert into rep select 'odd', fresh();
select ok((select v @> '[{"k":"fail","r":"timeout"}]' from rep where name = 'odd'), 'and the reply says r = timeout');
select is((select position('x@mail.test' in v::text) from rep where name = 'odd'), 0, 'the free text never reaches the chat');

insert into j values ('add4', job('add', 'add4@mail.test'));
select svc(format('select public.admin_job_claim(%L, 404)::text', (select id from j where name = 'add4')));
select svc(format('select public.admin_job_finish(%L, 404, false, null)::text', (select id from j where name = 'add4')));
select is(st((select id from j where name = 'add4')), 'failed:timeout:null:closed', 'a null reason becomes timeout');

-- 7 sweep -------------------------------------------------------------------------------
-- (every owner command sweeps too, so the jobs are made first and aged after)
insert into j values ('stale', job('add', 'stale@mail.test'));
insert into j values ('oldpend', job('add', 'oldpend@mail.test'));
insert into j values ('oldrun', job('remove', 'oldrun@mail.test'));
insert into j values ('young', job('add', 'young@mail.test'));
insert into j values ('oldok', job('add', 'oldok@mail.test'));
insert into j values ('trigger', job('add', 'trigger@mail.test'));
insert into j values ('cmdold', job('remove', 'cmdold@mail.test'));
update app_private.admin_jobs set state = 'running', run_id = 501, attempts = 1 where id = (select id from j where name = 'oldrun');
update app_private.admin_jobs set state = 'ok', email = null, finished_at = now() where id = (select id from j where name = 'oldok');

-- claim sweeps FIRST: the stale job it is asked for is failed, not handed out
select aged('stale', '20 minutes');
select is(svc(format('select public.admin_job_claim(%L, 504)::text', (select id from j where name = 'stale'))), 'null',
          'claiming a job past 15 minutes gets null (swept first)');
select is(st((select id from j where name = 'stale')), 'failed:timeout:null:closed', 'and that job is failed with timeout');

select aged('oldpend', '16 minutes'); select aged('oldrun', '16 minutes');
select aged('young', '14 minutes'); select aged('oldok', '2 hours');
select is(svc(format('select public.admin_job_claim(%L, 502)::text', (select id from j where name = 'trigger')))::jsonb ->> 'kind',
          'add', 'fixture: a young job is claimed');
select is(st((select id from j where name = 'oldpend')), 'failed:timeout:null:closed', 'claim sweeps: a pending job past 15 minutes fails with timeout');
select is(st((select id from j where name = 'oldrun')), 'failed:timeout:null:closed', 'claim sweeps: a running job past 15 minutes fails with timeout');
select is(st((select id from j where name = 'young')), 'pending:-:young@mail.test:open', 'sweep control: a 14-minute-old job is untouched');
select is(st((select id from j where name = 'oldok')), 'ok:-:null:closed', 'sweep control: an old finished job stays ok');
select is(svc(format('select public.admin_job_claim(%L, 503)::text', (select id from j where name = 'oldpend'))), 'null',
          'a timed-out job cannot be claimed');

-- any owner command sweeps too
select aged('cmdold', '30 minutes');
select cmd('/nosuchcommand');
select is(st((select id from j where name = 'cmdold')), 'failed:timeout:null:closed', 'an owner command sweeps a job past 15 minutes');
select is(st((select id from j where name = 'young')), 'pending:-:young@mail.test:open', 'and leaves a young one');

-- 8 admin_write ------------------------------------------------------------------------
select isnt(app_private.admin_reply((select id from adm), '{"k":"unk"}'::jsonb, false), null, 'admin_reply posts a reply');
select is(current_setting('app_private.admin_write', true), '', 'app_private.admin_write is empty after admin_reply');
select test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
select throws_ok(format($$insert into public.messages(conversation_id, sender_id, body, admin_msg)
                          values (%L, auth.uid(), 'x', '{"k":"p3"}')$$, (select id from adm)), '42501', null,
                 'right after a reply, the owner still cannot write admin_msg');
reset role;

select * from finish();
rollback;
