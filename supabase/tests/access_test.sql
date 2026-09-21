begin;
select plan(21);

-- fixtures ---------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000001', 'Allowed@Example.com', now(), '{"full_name":"Al Lowed"}'),  -- case differs on purpose
  ('00000000-0000-0000-0000-000000000002', 'stranger@example.com', now(), '{"full_name":"Stran Ger"}');
insert into app_private.allowlist(email) values ('allowed@example.com');  -- stored normalised
-- sessions: s1 older, s2 newer (creation time is what makes a session "newer"); s3 belongs to the stranger
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000001', now() - interval '2 hours', now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000001', now() - interval '1 hour',  now()),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000002', now() - interval '1 hour',  now());

-- helper: act as a user with a given session_id claim
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

-- 3 allowed user activates and reads; cannot write, truncate, or reach app_private
select test_as('00000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111');
select is(public.activate_session(), true, 'allowlisted user activates (case-insensitive email)');
select is(public.activate_session(), true, 'activating the same session again is idempotent');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-000000000001'), 'Al Lowed', 'profile created by trigger and readable');
select is((select min_supported_build from public.app_config), 1, 'app_config readable by active user');
select throws_ok($$insert into public.app_config(id, min_supported_build) values (2, 1)$$, '42501', null, 'active user cannot write app_config');
select throws_ok($$truncate public.profiles$$, '42501', null, 'active user cannot truncate profiles');
select throws_ok($$select * from app_private.allowlist$$, '42501', null, 'app_private is unreachable');
select throws_ok($$select * from app_private.active_sessions$$, '42501', null, 'active_sessions is unreachable');
select throws_ok($$truncate public.app_config$$, '42501', null, 'active user cannot truncate app_config');
reset role;

-- 4 sessions that are not the caller's own never activate
select test_as('00000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333');
select is(public.activate_session(), false, 'another user''s session id cannot activate');
reset role;
select test_as('00000000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999');
select is(public.activate_session(), false, 'unknown session id cannot activate');
reset role;

-- 5 a NEWER session replaces; the OLD session cannot come back
select test_as('00000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');
select is(public.activate_session(), true, 'newer device takes over');
reset role;
select test_as('00000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111');
select is((select count(*) from public.profiles), 0::bigint, 'replaced device loses access');
select is(public.activate_session(), false, 'older session cannot re-claim even with a fresh token');
reset role;

-- 5b sign-out / admin revocation: the active session disappears from auth.sessions
delete from auth.sessions where id = '22222222-2222-2222-2222-222222222222';
select test_as('00000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');
select is((select count(*) from public.profiles), 0::bigint, 'revoked session loses access immediately');
select is(public.activate_session(), false, 'revoked session cannot re-activate');
reset role;

-- 6 the signup trigger never aborts a signup
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000003', null, '{}');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-000000000003'), 'User', 'trigger falls back to a default display name');

select * from finish();
rollback;
