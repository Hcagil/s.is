-- REPRO for the removed-tester bug; the last assertion fails until the server tells removed apart from replaced.

begin;
select plan(7);

-- Fixtures
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000d1', 'rita@mail.test', now(), '{"full_name":"Rita"}'),
  ('00000000-0000-0000-0000-0000000000d2', 'nick@mail.test', now(), '{"full_name":"Nick"}');

insert into app_private.allowlist(email) values
  ('rita@mail.test'),
  ('nick@mail.test');

insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('d1d1d1d1-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d1', now() - interval '2 hours', now()),
  ('d2d2d2d2-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d2', now() - interval '2 hours', now()),
  ('d2d2d2d2-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000d2', now() - interval '1 hour', now());

-- Helper to act as a user/session
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Helper to capture activate_session result as text, catching errors
create or replace function answer_of() returns text language plpgsql as $$
begin
  return coalesce(public.activate_session()::text, 'null');
exception when others then
  return 'error:' || sqlstate;
end $$;
grant execute on function answer_of() to authenticated;

-- Temporary table to store answers
create temp table answers(kind text primary key, val text);
grant select, insert on answers to authenticated;

-- Rita holds the active phone
select test_as('00000000-0000-0000-0000-0000000000d1', 'd1d1d1d1-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'rita holds the active phone');
reset role;

-- Nick first phone active
select test_as('00000000-0000-0000-0000-0000000000d2', 'd2d2d2d2-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'nick first phone active');
reset role;

-- Nick newer phone takes over
select test_as('00000000-0000-0000-0000-0000000000d2', 'd2d2d2d2-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'nick newer phone takes over');
reset role;

-- Record replaced answer
select test_as('00000000-0000-0000-0000-0000000000d2', 'd2d2d2d2-0000-0000-0000-000000000001');
insert into answers values ('replaced', answer_of());
reset role;
select is((select val from answers where kind='replaced'), 'false',
  'control: a phone replaced by a newer phone gets the replaced answer');

-- Remove Rita from allowlist
delete from app_private.allowlist where email = 'rita@mail.test';
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
  'REPRO removed tester: activate_session must not give a removed account the replaced-by-a-newer-phone answer');

select * from finish();
rollback;
