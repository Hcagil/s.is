begin;
select plan(21);

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

-- v0.22.0: the row rule is has_app_access AND is_allowed(row) AND (the row is
-- the caller's own, OR shares a conversation with the caller, OR is a contact
-- the caller saved). A tag find alone does NOT open the row.
--
-- fixtures -----------------------------------------------------------------
-- m1 active member (the reader), m2 allowlisted with no session at all (m1
-- saved m2 as a contact), m3 allowlisted and active (shares a conversation
-- with m1), m4 allowlisted but never activated a session (a stranger to m1),
-- m5 allowlisted and active, a stranger to m1, m6 allowlisted and active,
-- found by m1 by exact tag and nothing else, m7 allowlisted and active, who
-- saved m1 (contacts are one-way: that does not open m7 to m1), robo signed
-- in through Google and is not on the allowlist -- but m1 saved robo and
-- shares a conversation with robo, so ONLY the allowlist half hides robo.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'scope-m1@example.test', now(), '{"full_name":"Mem One"}'),
  ('00000000-0000-0000-0000-0000000000f2', 'scope-m2@example.test', now(), '{"full_name":"Mem Two"}'),
  ('00000000-0000-0000-0000-0000000000f3', 'scope-m3@example.test', now(), '{"full_name":"Mem Three"}'),
  ('00000000-0000-0000-0000-0000000000f4', 'scope-m4@example.test', now(), '{"full_name":"Mem Four"}'),
  ('00000000-0000-0000-0000-0000000000f5', 'scope-m5@example.test', now(), '{"full_name":"Mem Five"}'),
  ('00000000-0000-0000-0000-0000000000f6', 'scope-m6@example.test', now(), '{"full_name":"Mem Six"}'),
  ('00000000-0000-0000-0000-0000000000f7', 'scope-m7@example.test', now(), '{"full_name":"Mem Seven"}'),
  ('00000000-0000-0000-0000-0000000000fe', 'scope-robo@example.test', now(), '{"full_name":"Robo Tester"}');
insert into app_private.allowlist(email) values
  ('scope-m1@example.test'), ('scope-m2@example.test'),
  ('scope-m3@example.test'), ('scope-m4@example.test'),
  ('scope-m5@example.test'), ('scope-m6@example.test'), ('scope-m7@example.test');
-- The relations, planted as the setup role (the client paths to them have
-- their own tests): m1-m3 and m1-robo share a conversation; m1 saved m2 and
-- robo; m7 saved m1; m1 found m6 by tag.
insert into public.conversations(id) values
  ('5c000000-0000-0000-0000-0000000000a3'), ('5c000000-0000-0000-0000-0000000000fe');
insert into public.conversation_members(conversation_id, user_id) values
  ('5c000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000f1'),
  ('5c000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000f3'),
  ('5c000000-0000-0000-0000-0000000000fe', '00000000-0000-0000-0000-0000000000f1'),
  ('5c000000-0000-0000-0000-0000000000fe', '00000000-0000-0000-0000-0000000000fe');
insert into public.contacts(owner_id, contact_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000fe'),
  ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-0000000000f1');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f6');
-- m2 deliberately has no session: an offline member must still be listable.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ffffffff-ffff-ffff-ffff-fffffffff001', '00000000-0000-0000-0000-0000000000f1', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff003', '00000000-0000-0000-0000-0000000000f3', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff004', '00000000-0000-0000-0000-0000000000f4', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff005', '00000000-0000-0000-0000-0000000000f5', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff006', '00000000-0000-0000-0000-0000000000f6', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffff007', '00000000-0000-0000-0000-0000000000f7', now(), now()),
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
select test_as('00000000-0000-0000-0000-0000000000f5', 'ffffffff-ffff-ffff-ffff-fffffffff005');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000000f6', 'ffffffff-ffff-ffff-ffff-fffffffff006');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000000f7', 'ffffffff-ffff-ffff-ffff-fffffffff007');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffff001');
select is(public.activate_session(), true, 'm1 is active');

-- 1 an active member reads its own row and the rows its relations open -------
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f1'),
          'Mem One', 'a member reads its own profile');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f3'),
          'Mem Three', 'a member reads the profile of someone it shares a conversation with');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f2'),
          'Mem Two', 'a member reads a saved contact who has never signed in on a device');

-- 1b nobody else: strangers, a tag find alone, a contact in the other direction
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f5'),
          0::bigint, 'an allowlisted, active stranger''s row is hidden');
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f4'),
          0::bigint, 'an allowlisted stranger who never activated is hidden');
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f6'),
          0::bigint, 'a member found only by exact tag is hidden (a tag find alone does not open the row)');
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f7'),
          0::bigint, 'someone who saved the reader is hidden: contacts are one-way');

reset role;
-- self, alone: m5 has no conversation, contact or find, and still reads itself
select test_as('00000000-0000-0000-0000-0000000000f5', 'ffffffff-ffff-ffff-ffff-fffffffff005');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-0000000000f5'),
          'Mem Five', 'a member with no relations at all reads its own profile');
reset role;
select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffff001');

-- 2 the non-allowlisted account is invisible to that same member ------------
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000000000fe'),
          0::bigint, 'a non-allowlisted contact sharing a conversation is still hidden (allowlist half)');
select is((select count(*) from public.profiles
            where user_id in ('00000000-0000-0000-0000-0000000000f1',
                              '00000000-0000-0000-0000-0000000000f2',
                              '00000000-0000-0000-0000-0000000000f3',
                              '00000000-0000-0000-0000-0000000000f4',
                              '00000000-0000-0000-0000-0000000000f5',
                              '00000000-0000-0000-0000-0000000000f6',
                              '00000000-0000-0000-0000-0000000000f7',
                              '00000000-0000-0000-0000-0000000000fe')),
          3::bigint, 'of all the fixtures the reader sees exactly itself, its chat partner and its contact');

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
-- Table-level: nothing. Column-level: SELECT every column but the real picture
-- path and its setting; UPDATE only the member-editable columns.
select table_privs_are('public', 'profiles', 'authenticated', array[]::text[],
                       'a signed-in client holds no table-wide privilege on profiles');
select is(
  (select array_agg(attname::text order by attname) from pg_attribute
    where attrelid = 'public.profiles'::regclass and attnum > 0 and not attisdropped
      and has_column_privilege('authenticated', 'public.profiles', attname, 'SELECT')),
  array['avatar_path', 'created_at', 'display_name', 'onboarding_done', 'share_last_seen',
        'share_presence', 'share_read_status', 'share_typing', 'tag', 'user_id'],
  'a client selects every profiles column except avatar_object and avatar_visibility');
select is(
  (select array_agg(attname::text order by attname) from pg_attribute
    where attrelid = 'public.profiles'::regclass and attnum > 0 and not attisdropped
      and has_column_privilege('authenticated', 'public.profiles', attname, 'UPDATE')),
  array['avatar_object', 'avatar_path', 'avatar_visibility', 'display_name', 'onboarding_done',
        'share_last_seen', 'share_presence', 'share_read_status', 'share_typing', 'tag'],
  'a client updates only the member-editable profiles columns');
select ok(not has_table_privilege('authenticated', 'public.profiles', 'INSERT')
          and not has_table_privilege('authenticated', 'public.profiles', 'DELETE'),
          'a client can neither insert nor delete a profile');
select table_privs_are('public', 'profiles', 'anon', array[]::text[],
                       'anon has no privilege on profiles at all');

select * from finish();
rollback;
