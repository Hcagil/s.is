begin;
select plan(24);

-- Neutral staff registry rows, loaded the way release loads the private file.
do $fx$ begin perform app_private.staff_load($j${
  "chats": [{"key":"staff_a","title_en":"Staff A","title_tr":"Ekip A","sort":1},
            {"key":"staff_b","title_en":"Staff B","title_tr":"Ekip B","sort":2}],
  "commands": [
    {"chat_key":"staff_a","word":"/addios","handler":"tester_add_ios","help_en":"add ios","help_tr":"ios ekle","sort":1},
    {"chat_key":"staff_a","word":"/addandroid","handler":"tester_add_android","help_en":"add android","help_tr":"android ekle","sort":2},
    {"chat_key":"staff_a","word":"/remove","handler":"tester_remove","help_en":"remove","help_tr":"cikar","sort":3},
    {"chat_key":"staff_a","word":"/list","handler":"tester_list","help_en":"list","help_tr":"liste","sort":4},
    {"chat_key":"staff_a","word":"/saleson","handler":"sales_on","help_en":"on","help_tr":"ac","sort":5},
    {"chat_key":"staff_a","word":"/salesoff","handler":"sales_off","help_en":"off","help_tr":"kapat","sort":6},
    {"chat_key":"staff_b","word":"/sales","handler":"sales_total","help_en":"total","help_tr":"toplam","sort":1}]
}$j$::jsonb); end $fx$;

-- Admin command job lock order. Written from the contract, not the migration:
-- sales_handle (after its per-user advisory lock) and sales_job_finish both
-- lock (1) the sales_state row, then (2) sales_jobs rows. Before the fix,
-- handle (stale waiting job, then state) crossed with finish (state, then the
-- job) could deadlock (40P01) and abort a user's message insert.
--
-- Part 1 uses real sessions over dblink, so its fixtures are COMMITTED by a
-- setup session and removed at the end of part 1. Part 2 (sweep, quiet finish)
-- runs in this transaction and is rolled back.
--
-- dblink must authenticate with a password as a non-superuser; loopback is
-- trust-only here, so connect to the address this session came in on (the
-- test runner connects over the docker network).

create extension if not exists dblink with schema extensions;
create function cs() returns text language sql as $$
  select format('host=%s port=%s dbname=%s user=postgres password=postgres',
                host(inet_server_addr()), inet_server_port(), current_database()) $$;
create function rx(c text, q text) returns void language sql as $$ select extensions.dblink_exec(c, q) $$;

select extensions.dblink_connect('f', cs());
select extensions.dblink_connect('a', cs());
select extensions.dblink_connect('b', cs());

-- p1 asks (session B); p2's chat holds the running job J and the stale waiting job W.
create function u(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000d10' || lpad(n::text, 2, '0'))::uuid $$;
create function s(n int) returns text language sql immutable as $$
  select 'd1000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0') $$;
create function claims(n int) returns text language sql as $$
  select json_build_object('sub', u(n), 'role', 'authenticated', 'email', 'jlo' || n || '@mail.test',
                           'session_id', s(n))::text $$;
create function as_sql(n int) returns text language sql as $$
  select format('select set_config(''request.jwt.claims'', %L, true); set local role authenticated;', claims(n)) $$;

-- part 1 setup (committed by session f) -----------------------------------------------------
create table saved_state as select * from app_private.sales_state;
select rx('f', format($q$
  delete from public.conversations c where c.staff_key = 'staff_b' and exists (select 1 from public.conversation_members m
    where m.conversation_id = c.id and m.user_id in (%1$L, %2$L));
  delete from auth.users where id in (%1$L, %2$L);
  delete from app_private.allowlist where email in ('jlo1@mail.test', 'jlo2@mail.test');
  insert into auth.users (id, email, email_confirmed_at) values (%1$L, 'jlo1@mail.test', now()), (%2$L, 'jlo2@mail.test', now());
  insert into app_private.allowlist(email) values ('jlo1@mail.test'), ('jlo2@mail.test');
  insert into auth.sessions (id, user_id, created_at, updated_at) values (%3$L, %1$L, now(), now()), (%4$L, %2$L, now(), now());
$q$, u(1), u(2), s(1), s(2)));
select rx('f', 'begin; ' || as_sql(1) || ' select public.activate_session(); commit;');
select rx('f', 'begin; ' || as_sql(2) || ' select public.activate_session(); commit;');
select rx('f', format($q$
  insert into app_private.command_admins(user_id) values (%1$L), (%2$L);
  update app_private.sales_state set amount = null, day = null, fetched_at = now() - interval '1 hour', fail_count = 0, off = false;
$q$, u(1), u(2)));
create table chat as
  select m.user_id as who, c.id from public.conversations c join public.conversation_members m on m.conversation_id = c.id
   where c.staff_key = 'staff_b' and m.user_id in (u(1), u(2));
create table jw(name text, id uuid default gen_random_uuid());
insert into jw(name) values ('J'), ('W');
select rx('f', format($q$
  insert into app_private.sales_jobs(id, conversation_id, state, prev, day, created_at) values
    (%1$L, %3$L, 'running', false, current_date, now()),
    (%2$L, %3$L, 'waiting', false, current_date, now() - interval '3 minutes');
$q$, (select id from jw where name = 'J'), (select id from jw where name = 'W'), (select id from chat where who = u(2))));
select is((select count(*) from chat), 2::bigint, 'fixture: both committed admins have a chat');
select is((select string_agg(state, ',' order by state) from app_private.sales_jobs where id in (select id from jw)),
          'running,waiting', 'fixture: J running and W waiting are committed');

-- part 1: A finishes J inside an open transaction; B asks -----------------------------------------
select rx('a', 'begin');
select * from extensions.dblink('a', format('select public.sales_job_finish(%L, ''1.000'', null)::text',
  (select id from jw where name = 'J'))) as t(x text);
create table bpid as select * from extensions.dblink('b', 'select pg_backend_pid()') as t(pid int);
select rx('b', 'begin; ' || as_sql(1));
select extensions.dblink_send_query('b', format(
  'insert into public.messages(conversation_id, sender_id, body) values (%L, %L, ''/sales'')',
  (select id from chat where who = u(1)), u(1)));

-- wait (at most 10 s) until B blocks on a lock
create function b_waits() returns boolean language plpgsql as $$
begin
  for i in 1..100 loop
    if exists (select 1 from pg_locks where pid = (select pid from bpid) and not granted) then return true; end if;
    perform pg_sleep(0.1);
  end loop;
  return false;
end $$;
select ok(b_waits(), 'B blocks while A holds its finish open');
-- a row-lock waiter holds the heavyweight tuple lock of the row it waits for
create table bwait as
  select l.relation::regclass::text as rel from pg_locks l where l.pid = (select pid from bpid) and l.locktype = 'tuple';
select is((select string_agg(rel, ',') from bwait), 'app_private.sales_state',
          'B waits on the sales_state row, not on a job row');
select is((select count(*) from pg_locks l where l.pid = (select pid from bpid) and not l.granted and l.locktype = 'advisory'),
          0::bigint, 'B is not stuck on the advisory lock');

select rx('a', 'commit');
create function b_result() returns text language plpgsql as $$
declare r text;
begin
  select t.s into r from extensions.dblink_get_result('b') as t(s text);
  perform * from extensions.dblink_get_result('b') as t(s text);
  return r;
exception when others then
  return 'err:' || sqlstate;
end $$;
select is(b_result(), 'INSERT 0 1', 'after A commits, B''s message insert completes (no 40P01)');
select rx('b', 'commit');
select is((select count(*) from public.messages where conversation_id = (select id from chat where who = u(1)) and body = '/sales'),
          1::bigint, 'B''s message is stored');
select is((select count(*) from app_private.sales_jobs where id in (select id from jw) and state in ('running', 'waiting')),
          0::bigint, 'neither J nor W is left open');

-- part 1b, the other side: B holds the state row (its ask is open); A finishes a running job.
-- A must wait on the state row before it locks any job row.
insert into jw(name) values ('J2'), ('W2');
select rx('f', format($q$
  update app_private.sales_state set amount = null, day = null, fetched_at = now() - interval '1 hour', fail_count = 0, off = false;
  insert into app_private.sales_jobs(id, conversation_id, state, prev, day, created_at) values
    (%1$L, %3$L, 'running', false, current_date, now()),
    (%2$L, %3$L, 'waiting', false, current_date, now() - interval '3 minutes');
$q$, (select id from jw where name = 'J2'), (select id from jw where name = 'W2'), (select id from chat where who = u(2))));
create table apid as select * from extensions.dblink('a', 'select pg_backend_pid()') as t(pid int);
select rx('b', 'begin; ' || as_sql(1));
select rx('b', format('insert into public.messages(conversation_id, sender_id, body) values (%L, %L, ''/sales'')',
  (select id from chat where who = u(1)), u(1)));
select extensions.dblink_send_query('a', format('select public.sales_job_finish(%L, ''1.000'', null)::text',
  (select id from jw where name = 'J2')));
create function a_waits() returns boolean language plpgsql as $$
begin
  for i in 1..100 loop
    if exists (select 1 from pg_locks where pid = (select pid from apid) and not granted) then return true; end if;
    perform pg_sleep(0.1);
  end loop;
  return false;
end $$;
select ok(a_waits(), 'A''s finish blocks while B''s ask holds the state row');
select is((select string_agg(l.relation::regclass::text, ',') from pg_locks l where l.pid = (select pid from apid) and l.locktype = 'tuple'),
          'app_private.sales_state', 'A waits on the sales_state row');
-- a third session probes J2: A must not hold it yet
create function probe(j uuid) returns text language plpgsql as $$
begin
  perform * from extensions.dblink('f', format('select id::text from app_private.sales_jobs where id = %L for update nowait', j)) as t(x text);
  return 'free';
exception when others then
  return 'err:' || sqlstate;
end $$;
select rx('f', 'begin');
select is(probe((select id from jw where name = 'J2')), 'free', 'while A waits on the state row it holds no job row');
select rx('f', 'rollback');
select rx('b', 'commit');
create function a_result() returns text language plpgsql as $$
declare r text;
begin
  select t.x into r from extensions.dblink_get_result('a') as t(x text);
  perform * from extensions.dblink_get_result('a') as t(x text);
  return 'done';
exception when others then
  return 'err:' || sqlstate;
end $$;
select is(a_result(), 'done', 'after B commits, A''s finish completes (no 40P01)');

-- part 1 cleanup (committed by session f) ---------------------------------------------------------
select rx('f', format($q$
  delete from public.conversations where id in (%3$L, %4$L);
  delete from auth.users where id in (%1$L, %2$L);
  delete from app_private.allowlist where email in ('jlo1@mail.test', 'jlo2@mail.test');
  update app_private.sales_state set amount = %5$L, day = %6$L, fetched_at = %7$L, fail_count = %8$L, off = %9$L;
$q$, u(1), u(2), (select id from chat where who = u(1)), (select id from chat where who = u(2)),
     (select amount from saved_state), (select day from saved_state), (select fetched_at from saved_state),
     (select fail_count from saved_state), (select off from saved_state)));
select extensions.dblink_disconnect('f'); select extensions.dblink_disconnect('a'); select extensions.dblink_disconnect('b');
select is((select count(*) from auth.users where id in (u(1), u(2)))
        + (select count(*) from public.conversations where id in (select id from chat)), 0::bigint,
          'committed fixtures are removed');

-- part 2: sweep and quiet finish (this transaction only) ------------------------------------------
create function test_as(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', claims(n), true);
  execute 'set local role authenticated';
end $$;
grant execute on function test_as(int), claims(int), u(int), s(int) to authenticated;
insert into auth.users (id, email, email_confirmed_at) values (u(3), 'jlo3@mail.test', now()), (u(4), 'jlo4@mail.test', now());
insert into app_private.allowlist(email) values ('jlo3@mail.test'), ('jlo4@mail.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values (s(3)::uuid, u(3), now(), now()), (s(4)::uuid, u(4), now(), now());
select test_as(3); select is(public.activate_session(), true, 'fixture: p3 is active'); reset role;
select test_as(4); select is(public.activate_session(), true, 'fixture: p4 is active'); reset role;
insert into app_private.command_admins(user_id) values (u(3)), (u(4));
create table chat2 as
  select m.user_id as who, c.id from public.conversations c join public.conversation_members m on m.conversation_id = c.id
   where c.staff_key = 'staff_b' and m.user_id in (u(3), u(4));
create function c2(n int) returns uuid language sql as $$ select id from chat2 where who = u(n) $$;
update app_private.sales_state set amount = null, day = null, fetched_at = now() - interval '1 hour', fail_count = 0, off = false;
-- in p4's chat: a waiting job past 2 minutes (old) and one inside 2 minutes (young)
create table jw2(name text, id uuid default gen_random_uuid());
insert into jw2(name) values ('old'), ('young');
insert into app_private.sales_jobs(id, conversation_id, state, prev, day, created_at) values
  ((select id from jw2 where name = 'old'), c2(4), 'waiting', false, current_date, now() - interval '2 minutes 10 seconds'),
  ((select id from jw2 where name = 'young'), c2(4), 'waiting', false, current_date, now() - interval '1 minute 50 seconds');
create function st(n text) returns text language sql as $$
  select state from app_private.sales_jobs where id = (select id from jw2 where name = n) $$;
create function replies(conv uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(admin_msg->>'k' order by id), '[]') from public.messages
   where conversation_id = conv and sender_id = '00000000-0000-0000-0000-00000000ad41' $$;

select test_as(3);
insert into public.messages(conversation_id, sender_id, body) values (c2(3), u(3), '/sales');
reset role;
select is(st('old'), 'failed', 'an ask sweeps a waiting job older than 2 minutes to failed');
select is(st('young'), 'waiting', 'a waiting job inside 2 minutes is not swept');
select is(replies(c2(4)), '["podFail"]'::jsonb, 'the swept job''s chat gets exactly one failure reply');

-- finish with an unknown or a non-running job returns quietly
create table before as select (select count(*) from public.messages) as m, (select row(p.*)::text from app_private.sales_state p) as ps;
select lives_ok(format('select public.sales_job_finish(%L, ''1.000'', null)', gen_random_uuid()),
                'finish of an unknown job raises nothing');
select lives_ok(format('select public.sales_job_finish(%L, ''1.000'', null)', (select id from jw2 where name = 'old')),
                'finish of a failed (non-running) job raises nothing');
select lives_ok(format('select public.sales_job_finish(%L, ''1.000'', null)', (select id from jw2 where name = 'young')),
                'finish of a waiting (non-running) job raises nothing');
select is((select count(*) from public.messages), (select m from before), 'and posts no reply');
select is((select row(p.*)::text from app_private.sales_state p), (select ps from before), 'and leaves the state row as it was');
select is(st('old') || ',' || st('young'), 'failed,waiting', 'and leaves the jobs as they were');

select * from finish();
rollback;
