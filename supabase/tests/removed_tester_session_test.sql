-- REPRO for the removed-tester bug; the last assertion fails until the server tells removed apart from replaced.

begin;
select plan(17);

-- Fixtures
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000d1', 'rita@mail.test', now(), '{"full_name":"Rita"}'),
  ('00000000-0000-0000-0000-0000000000d2', 'nick@mail.test', now(), '{"full_name":"Nick"}'),
  ('00000000-0000-0000-0000-0000000000d3', 'ghost@mail.test', now(), '{"full_name":"Ghost"}'),
  ('00000000-0000-0000-0000-0000000000d4', 'gone@mail.test', now(), '{"full_name":"Gone"}');

insert into app_private.allowlist(email) values
  ('rita@mail.test'),
  ('nick@mail.test');

insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('d1d1d1d1-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d1', now() - interval '2 hours', now()),
  ('d2d2d2d2-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d2', now() - interval '2 hours', now()),
  ('d2d2d2d2-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000d2', now() - interval '1 hour', now()),
  ('e3e3e3e3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d3', now() - interval '3 hours', now());

-- Helper to act as a user/session
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Helper to capture activate_session_status() result as text, catching errors
create or replace function answer_of() returns text language plpgsql as $$
begin
  return coalesce(public.activate_session_status(), 'null');
exception when others then
  return 'error:' || sqlstate;
end $$;
grant execute on function answer_of() to authenticated;

-- Helper to capture activate_session() result as text
create or replace function old_answer_of() returns text language plpgsql as $$
begin
  return coalesce(public.activate_session()::text, 'null');
exception when others then
  return 'error:' || sqlstate;
end $$;
grant execute on function old_answer_of() to authenticated;

-- Temporary table to store answers
create temp table answers(kind text primary key, val text);
grant select, insert on answers to authenticated;

-- Rita holds the active phone
select test_as('00000000-0000-0000-0000-0000000000d1', 'd1d1d1d1-0000-0000-0000-000000000001');
select is(answer_of(), 'active', 'rita holds the active phone');
reset role;

-- Nick first phone active
select test_as('00000000-0000-0000-0000-0000000000d2', 'd2d2d2d2-0000-0000-0000-000000000001');
select is(answer_of(), 'active', 'nick first phone active');
reset role;

-- Nick newer phone takes over
select test_as('00000000-0000-0000-0000-0000000000d2', 'd2d2d2d2-0000-0000-0000-000000000002');
select is(answer_of(), 'active', 'nick newer phone takes over');
reset role;

-- Record replaced answer
select test_as('00000000-0000-0000-0000-0000000000d2', 'd2d2d2d2-0000-0000-0000-000000000001');
insert into answers values ('replaced', answer_of());
insert into answers values ('old_replaced', old_answer_of());
reset role;
select test_as('00000000-0000-0000-0000-0000000000d2', 'd2d2d2d2-0000-0000-0000-000000000002');
insert into answers values ('old_active', old_answer_of());
reset role;
select is((select val from answers where kind='replaced'), 'replaced', 'a phone replaced by a newer phone gets replaced');
select is((select val from answers where kind='old_replaced'), 'false', 'old activate_session still false for the replaced phone');
select is((select val from answers where kind='old_active'), 'true', 'old activate_session still true for the active phone');

-- Remove Rita from allowlist and active_sessions
delete from app_private.allowlist where email = 'rita@mail.test';
delete from app_private.active_sessions where user_id = '00000000-0000-0000-0000-0000000000d1';
select ok(exists(select 1 from auth.sessions where id = 'd1d1d1d1-0000-0000-0000-000000000001'),
  'rita still holds her session after removal');

-- Record removed answer
select test_as('00000000-0000-0000-0000-0000000000d1', 'd1d1d1d1-0000-0000-0000-000000000001');
insert into answers values ('removed', answer_of());
reset role;

-- Assertions for removed case
select isnt((select val from answers where kind='removed'), 'true',
  'a removed account is not let in');
select isnt((select val from answers where kind='removed'),
  (select val from answers where kind='replaced'),
  'REPRO removed tester: activate_session_status must not give a removed account the replaced-by-a-newer-phone answer');
select is((select val from answers where kind='removed'), 'not_allowed',
  'removed account returns not_allowed');
select is((select count(*) from app_private.active_sessions where user_id='00000000-0000-0000-0000-0000000000d1')::int, 0,
  'a removed caller who still has a session row writes nothing to active_sessions');

-- Ghost user never allowlisted
select test_as('00000000-0000-0000-0000-0000000000d3', 'e3e3e3e3-0000-0000-0000-000000000001');
select is(answer_of(), 'not_allowed', 'ghost user not allowlisted returns not_allowed');
reset role;

-- Signed-out removed caller
select test_as('00000000-0000-0000-0000-0000000000d4', 'e4e4e4e4-0000-0000-0000-000000000001');
select is(answer_of(), 'not_allowed', 'signed-out removed caller returns not_allowed');
reset role;
select is((select count(*) from app_private.active_sessions where user_id='00000000-0000-0000-0000-0000000000d4')::int, 0,
  'nothing written to active_sessions for signed-out removed caller');

-- Function privilege checks
select is(has_function_privilege('authenticated','public.activate_session_status()','execute'), true,
  'authenticated can execute activate_session_status');
select is(has_function_privilege('anon','public.activate_session_status()','execute'), false,
  'anon cannot execute activate_session_status');

-- Anon role should be denied
reset role;
set local role anon;
select throws_ok($$select public.activate_session_status()$$, '42501', null, 'anon cannot call activate_session_status');
reset role;

select * from finish();
rollback;
