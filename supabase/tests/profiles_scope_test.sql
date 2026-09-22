begin;
select plan(13);

-- Profiles are scoped to the allowlist.
--
-- A Google sign-in creates an auth.users row and the trigger creates a
-- profile for it, whether or not the account is on the allowlist. Play
-- pre-launch robo tests produced seven such accounts in production. The v0.2
-- member picker reads public.profiles, so those rows must not be readable.
--
-- The gate under test is the ROW OWNER half of the read policy. The negative
-- fixture below is therefore an active, allowlisted member -- a subject that
-- already satisfies the app-access half -- looking at a non-allowlisted row.
-- A non-allowlisted READER proves nothing here: it fails app access first.

-- fixtures -----------------------------------------------------------------
-- m1 active member (the reader), m2 allowlisted with no session at all,
-- m3 allowlisted and active, m4 allowlisted but never activated a session,
-- robo signed in through Google and is not on the allowlist.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'scope-m1@example.test', now(), '{"full_name":"Mem One"}'),
  ('00000000-0000-0000-0000-0000000000f2', 'scope-m2@example.test', now(), '{"full_name":"Mem Two"}'),
  ('00000000-0000-0000-0000-0000000000f3', 'scope-m3@example.test', now(), '{"full_name":"Mem Three"}'),
  ('00000000-0000-0000-0000-0000000000f4', 'scope-m4@example.test', now(), '{"full_name":"Mem Four"}'),
  ('00000000-0000-0000-0000-0000000000fe', 'scope-robo@example.test', now(), '{"full_name":"Robo Tester"}');
insert into app_private.allowlist(email) values
  ('scope-m1@example.test'), ('scope-m2@example.test'),
  ('scope-m3@example.test'), ('scope-m4@example.test');
-- m2 deliberately has no session: an offline member must still be listable.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ffffffff-ffff-ffff-ffff-fffffffff001', '00000000-0000-0000-0000-0000000000f1', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff003', '00000000-0000-0000-0000-0000000000f3', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff004', '00000000-0000-0000-0000-0000000000f4', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff0fe', '00000000-0000-0000-0000-0000000000fe', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- 0 the negative fixture is real: the row exists, RLS is what hides it -------
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000000000fe'),
          1::bigint, 'the trigger created a profile for the non-allowlisted account');

select test_as('00000000-0000-0000-0000-0000000000f3', 'ffffffff-ffff-ffff-ffff-fffffffff003');
select is(public.activate_session(), true, 'm3 is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffff001');
select is(public.activate_session(), true, 'm1 is active');

-- 1 an active member reads allowlisted profiles, its own and other people's --
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f1'),
          'Mem One', 'a member reads its own profile');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f3'),
          'Mem Three', 'a member reads another active member''s profile');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f2'),
          'Mem Two', 'a member reads an allowlisted member who has never signed in on a device');

-- 2 the non-allowlisted account is invisible to that same member ------------
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000000000fe'),
          0::bigint, 'an active member does not see a non-allowlisted profile');
select is((select count(*) from public.profiles
            where user_id in ('00000000-0000-0000-0000-0000000000f1',
                              '00000000-0000-0000-0000-0000000000f2',
                              '00000000-0000-0000-0000-0000000000f3',
                              '00000000-0000-0000-0000-0000000000f4',
                              '00000000-0000-0000-0000-0000000000fe')),
          4::bigint, 'the member picker lists the allowlist and nothing else');

-- 3 the app-access half of the policy still holds ---------------------------
select throws_ok($$select app_private.is_allowed('00000000-0000-0000-0000-0000000000fe')$$,
                 '42501', null, 'app_private.is_allowed is unreachable from the client');
reset role;

-- allowlisted, but no session was ever activated: reads nothing at all.
select test_as('00000000-0000-0000-0000-0000000000f4', 'ffffffff-ffff-ffff-ffff-fffffffff004');
select is((select count(*) from public.profiles), 0::bigint,
          'an allowlisted member without an active session reads no profiles');
reset role;

-- the non-allowlisted account cannot read its own profile either.
select test_as('00000000-0000-0000-0000-0000000000fe', 'ffffffff-ffff-ffff-ffff-fffffffff0fe');
select is((select count(*) from public.profiles), 0::bigint,
          'a non-allowlisted account reads no profiles, not even its own');
reset role;

-- 4 profiles stay read-only, for everyone -----------------------------------
select table_privs_are('public', 'profiles', 'authenticated', array['SELECT'],
                       'a signed-in client may only read profiles');
select table_privs_are('public', 'profiles', 'anon', array[]::text[],
                       'anon has no privilege on profiles at all');

select * from finish();
rollback;
