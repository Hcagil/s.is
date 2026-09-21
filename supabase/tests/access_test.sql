begin;
select plan(10);

-- fixtures ---------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000001', 'Allowed@Example.com',  '{"full_name":"Al Lowed"}'),  -- JWT email case differs on purpose
  ('00000000-0000-0000-0000-000000000002', 'stranger@example.com', '{"full_name":"Stran Ger"}');
insert into app_private.allowlist(email) values ('allowed@example.com');  -- stored normalised
-- sessions: s1 older, s2 newer (creation time is what makes a session "newer")
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000001', now() - interval '2 hours', now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000001', now() - interval '1 hour',  now()),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000002', now() - interval '1 hour',  now());

-- helper: act as a user with a given session_id
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- 1 anonymous sees nothing
set local role anon;
select throws_ok($$select count(*) from public.profiles$$, '42501', 'permission denied for table profiles', 'anon cannot read profiles');
select throws_ok($$select public.activate_session()$$, 'permission denied for function activate_session', 'anon cannot call activate_session');
reset role;

-- 2 stranger (not allowlisted) is denied
select test_as('00000000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333');
select is(public.activate_session(), false, 'unallowlisted user cannot activate');
select is((select count(*) from public.profiles), 0::bigint, 'unallowlisted user reads no profiles');
reset role;

-- 3 allowed user activates and reads
select test_as('00000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111');
select is(public.activate_session(), true, 'allowlisted user activates (case-insensitive email)');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-000000000001'), 'Al Lowed', 'profile created by trigger and readable');
select is((select min_supported_build from public.app_config), 1, 'app_config readable by active user');
reset role;

-- 4 a NEWER session replaces; the OLD session cannot come back
select test_as('00000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');
select is(public.activate_session(), true, 'newer device takes over');
reset role;
select test_as('00000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111');
select is((select count(*) from public.profiles), 0::bigint, 'replaced device loses access');
select is(public.activate_session(), false, 'older session cannot re-claim even with a fresh token');
reset role;

select * from finish();
rollback;
