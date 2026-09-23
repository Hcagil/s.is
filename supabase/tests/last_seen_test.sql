begin;
select plan(91);

-- Last seen (v0.4): public.touch_last_seen() records the caller, and
-- public.last_seen_of(person) answers only when EVERY gate holds:
--   the caller has app access      (allowlisted + the active session)
--   the caller shares last seen    (mutual: hide yours, see nobody's)
--   the person shares last seen
--   the person is allowlisted
-- A refusal is a plain null, never an error, so it cannot be told apart from
-- "never seen".
--
-- Each negative subject fails ONE gate, and is shown passing first with that
-- gate still open, so the null is caused by the gate and nothing else:
--   ada   everything on: the caller in every positive control
--   ben   everything on: the person in every positive control
--   cal   caller sharing off          -- only the caller-share gate stops her
--   dot   person sharing off, a time still stored (planted with RLS bypassed:
--         the trigger would otherwise have deleted it) -- only person-share
--   eve   person delisted, sharing, a time stored -- only person-allowlisted
--   fay   caller on a replaced phone  -- only the session half of app access
--   ivy   caller delisted while active -- only the allowlist half
--   gus   caller never activated      -- app access again
--   hal   signed in, never allowlisted: app access, from the outside
-- Everything runs in one transaction, so now() is one instant throughout.

-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000cc001', 'ada@lastseen.test', now(), '{"full_name":"Ada"}'),
  ('00000000-0000-0000-0000-0000000cc002', 'ben@lastseen.test', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-0000000cc003', 'cal@lastseen.test', now(), '{"full_name":"Cal"}'),
  ('00000000-0000-0000-0000-0000000cc004', 'dot@lastseen.test', now(), '{"full_name":"Dot"}'),
  ('00000000-0000-0000-0000-0000000cc005', 'eve@lastseen.test', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-0000000cc006', 'fay@lastseen.test', now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-0000000cc007', 'ivy@lastseen.test', now(), '{"full_name":"Ivy"}'),
  ('00000000-0000-0000-0000-0000000cc008', 'gus@lastseen.test', now(), '{"full_name":"Gus"}'),
  ('00000000-0000-0000-0000-0000000cc009', 'hal@lastseen.test', now(), '{"full_name":"Hal"}');
insert into app_private.allowlist(email) values
  ('ada@lastseen.test'), ('ben@lastseen.test'), ('cal@lastseen.test'),
  ('dot@lastseen.test'), ('eve@lastseen.test'), ('fay@lastseen.test'),
  ('ivy@lastseen.test'), ('gus@lastseen.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ec000000-0000-0000-0000-0000000cc001', '00000000-0000-0000-0000-0000000cc001', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc002', '00000000-0000-0000-0000-0000000cc002', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc003', '00000000-0000-0000-0000-0000000cc003', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc004', '00000000-0000-0000-0000-0000000cc004', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc005', '00000000-0000-0000-0000-0000000cc005', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc006', '00000000-0000-0000-0000-0000000cc006', now() - interval '1 hour', now()),
  ('ec000000-0000-0000-0000-00000000c006', '00000000-0000-0000-0000-0000000cc006', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc007', '00000000-0000-0000-0000-0000000cc007', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc008', '00000000-0000-0000-0000-0000000cc008', now(), now()),
  ('ec000000-0000-0000-0000-0000000cc009', '00000000-0000-0000-0000-0000000cc009', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function test_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end $$;

-- Rows the caller's own-row update changed (RLS decides which).
create or replace function test_share_last_seen(target uuid, on_ boolean)
returns bigint language plpgsql security invoker as $$
declare n bigint;
begin
  update public.profiles set share_last_seen = on_ where user_id = target;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function test_share_last_seen(uuid, boolean) to authenticated, anon;

-- The stored time, read with RLS bypassed (call after reset role).
create or replace function stored(uid uuid) returns timestamptz language sql as $$
  select seen_at from app_private.last_seen where user_id = uid
$$;

-- Everyone who has a session activates; fay's OLD phone first, so her new
-- one replaces it. gus signs in and never activates; hal is not allowlisted.
select test_as('00000000-0000-0000-0000-0000000cc006', 'ec000000-0000-0000-0000-0000000cc006');
select is(public.activate_session(), true, 'fay activates her old phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc006', 'ec000000-0000-0000-0000-00000000c006');
select is(public.activate_session(), true, 'fay moves to her new phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select is(public.activate_session(), true, 'ada is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc002', 'ec000000-0000-0000-0000-0000000cc002');
select is(public.activate_session(), true, 'ben is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc003', 'ec000000-0000-0000-0000-0000000cc003');
select is(public.activate_session(), true, 'cal is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc004', 'ec000000-0000-0000-0000-0000000cc004');
select is(public.activate_session(), true, 'dot is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc005', 'ec000000-0000-0000-0000-0000000cc005');
select is(public.activate_session(), true, 'eve is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc007', 'ec000000-0000-0000-0000-0000000cc007');
select is(public.activate_session(), true, 'ivy is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc009', 'ec000000-0000-0000-0000-0000000cc009');
select is(public.activate_session(), false, 'hal is not allowlisted');
reset role;

-- 1 schema and privileges ----------------------------------------------------
select col_not_null('public', 'profiles', 'share_last_seen', 'share_last_seen is not null');
select col_default_is('public', 'profiles', 'share_last_seen', 'true', 'share_last_seen defaults on');
select is((select share_last_seen from public.profiles
            where user_id = '00000000-0000-0000-0000-0000000cc001'),
          true, 'a new member shares last seen');
select ok(has_column_privilege('authenticated', 'public.profiles', 'share_last_seen', 'UPDATE'),
          'members may update share_last_seen');
select ok(not has_column_privilege('anon', 'public.profiles', 'share_last_seen', 'UPDATE'),
          'anon may not update share_last_seen');
select ok((select relrowsecurity from pg_class where oid = 'app_private.last_seen'::regclass),
          'last_seen has row security enabled');
select is((select count(*) from pg_policies where schemaname = 'app_private' and tablename = 'last_seen'),
          0::bigint, 'last_seen has no policies: nothing is let through');
select ok(not has_table_privilege('authenticated', 'app_private.last_seen', 'SELECT'), 'authenticated: no select on last_seen');
select ok(not has_table_privilege('authenticated', 'app_private.last_seen', 'INSERT'), 'authenticated: no insert on last_seen');
select ok(not has_table_privilege('authenticated', 'app_private.last_seen', 'UPDATE'), 'authenticated: no update on last_seen');
select ok(not has_table_privilege('authenticated', 'app_private.last_seen', 'DELETE'), 'authenticated: no delete on last_seen');
select ok(not has_table_privilege('anon', 'app_private.last_seen', 'SELECT'), 'anon: no select on last_seen');
select ok(not has_table_privilege('anon', 'app_private.last_seen', 'INSERT'), 'anon: no insert on last_seen');
select ok(not has_table_privilege('anon', 'app_private.last_seen', 'UPDATE'), 'anon: no update on last_seen');
select ok(not has_table_privilege('anon', 'app_private.last_seen', 'DELETE'), 'anon: no delete on last_seen');
select ok(has_function_privilege('authenticated', 'public.touch_last_seen()', 'EXECUTE'),
          'members may call touch_last_seen');
select ok(has_function_privilege('authenticated', 'public.last_seen_of(uuid)', 'EXECUTE'),
          'members may call last_seen_of');
select ok(not has_function_privilege('anon', 'public.touch_last_seen()', 'EXECUTE'),
          'anon may not call touch_last_seen');
select ok(not has_function_privilege('anon', 'public.last_seen_of(uuid)', 'EXECUTE'),
          'anon may not call last_seen_of');

-- 2 touch_last_seen: the caller, now, insert then update ----------------------
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select lives_ok($$select public.touch_last_seen()$$, 'ada touches');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc001'), now(), 'ada''s first touch is stored as now');
update app_private.last_seen set seen_at = '2026-01-01 00:00+00'
 where user_id = '00000000-0000-0000-0000-0000000cc001';
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select lives_ok($$select public.touch_last_seen()$$, 'ada touches again');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc001'), now(), 'the second touch moves her time to now');
select is((select count(*) from app_private.last_seen
            where user_id = '00000000-0000-0000-0000-0000000cc001'), 1::bigint,
          'one row per member');
select is(stored('00000000-0000-0000-0000-0000000cc002'), null, 'ada''s touch recorded nobody else');

-- ben, dot and eve touch; their times are then moved to known, distinct
-- instants so an answer can only be THEIR time, never the caller's.
select test_as('00000000-0000-0000-0000-0000000cc002', 'ec000000-0000-0000-0000-0000000cc002');
select public.touch_last_seen();
reset role;
select test_as('00000000-0000-0000-0000-0000000cc004', 'ec000000-0000-0000-0000-0000000cc004');
select public.touch_last_seen();
reset role;
select test_as('00000000-0000-0000-0000-0000000cc005', 'ec000000-0000-0000-0000-0000000cc005');
select public.touch_last_seen();
reset role;
select is((select count(*) from app_private.last_seen where user_id in (
  '00000000-0000-0000-0000-0000000cc002', '00000000-0000-0000-0000-0000000cc004',
  '00000000-0000-0000-0000-0000000cc005')), 3::bigint, 'ben, dot and eve each have a time');
update app_private.last_seen set seen_at = '2026-09-01 10:00+00' where user_id = '00000000-0000-0000-0000-0000000cc002';
update app_private.last_seen set seen_at = '2026-09-02 10:00+00' where user_id = '00000000-0000-0000-0000-0000000cc004';
update app_private.last_seen set seen_at = '2026-09-03 10:00+00' where user_id = '00000000-0000-0000-0000-0000000cc005';

-- 3 the positive control: ada sees ben, dot and eve ---------------------------
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'ada sees ben''s time');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc004'), '2026-09-02 10:00+00'::timestamptz,
          'ada sees dot''s time (control)');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc005'), '2026-09-03 10:00+00'::timestamptz,
          'ada sees eve''s time (control)');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc003'), null,
          'a member who never touched has no time');
select lives_ok($$select public.last_seen_of('00000000-0000-0000-0000-00000000dead')$$,
                'an unknown id does not raise');
select is(public.last_seen_of('00000000-0000-0000-0000-00000000dead'), null, 'an unknown id is null');
-- no way round the functions
select throws_ok($$select * from app_private.last_seen$$, '42501', null, 'a member cannot read the table');
select throws_ok($$insert into app_private.last_seen values ('00000000-0000-0000-0000-0000000cc002', now())$$,
                 '42501', null, 'a member cannot plant a time for someone else');
select throws_ok($$update app_private.last_seen set seen_at = now()$$, '42501', null,
                 'a member cannot move anyone''s time');
select throws_ok($$delete from app_private.last_seen$$, '42501', null, 'a member cannot erase anyone''s time');
-- nor erase ben's time by turning HIS sharing off
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc002', false), 0::bigint,
          'ada cannot turn ben''s sharing off');
reset role;
select is((select share_last_seen from public.profiles
            where user_id = '00000000-0000-0000-0000-0000000cc002'), true, 'ben''s choice is untouched');
select is(stored('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'ben''s time is untouched');

-- 4 cal: only the caller-share gate -------------------------------------------
select test_as('00000000-0000-0000-0000-0000000cc003', 'ec000000-0000-0000-0000-0000000cc003');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'cal, sharing, sees ben (control)');
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc003', false), 1::bigint,
          'cal turns her own sharing off');
select lives_ok($$select public.last_seen_of('00000000-0000-0000-0000-0000000cc002')$$,
                'not sharing: asking does not raise');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), null,
          'not sharing: cal sees nobody''s time');
select lives_ok($$select public.touch_last_seen()$$, 'not sharing: a touch does not raise');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc003'), null, 'not sharing: the touch stored nothing');
select test_as('00000000-0000-0000-0000-0000000cc003', 'ec000000-0000-0000-0000-0000000cc003');
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc003', true), 1::bigint,
          'cal turns sharing back on');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'sharing again: cal sees ben again');
reset role;

-- 5 dot: only the person-share gate ---------------------------------------------
-- Her sharing goes off (the trigger forgets her), then her old time is planted
-- back with RLS bypassed: a row exists, so only her choice can hide it.
update public.profiles set share_last_seen = false where user_id = '00000000-0000-0000-0000-0000000cc004';
select is(stored('00000000-0000-0000-0000-0000000cc004'), null, 'dot turning sharing off forgot her time');
insert into app_private.last_seen values ('00000000-0000-0000-0000-0000000cc004', '2026-09-02 10:00+00')
  on conflict (user_id) do update set seen_at = excluded.seen_at;
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc004'), null,
          'dot does not share: her stored time is withheld');
reset role;

-- 6 eve: only the person-allowlisted gate ---------------------------------------
delete from app_private.allowlist where email = 'eve@lastseen.test';
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc005'), null,
          'eve left the allowlist: her time is withheld');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc005'), '2026-09-03 10:00+00'::timestamptz,
          'eve''s time is still stored, so only the allowlist gate hid it');

-- 7 fay: only the session half of app access ------------------------------------
select test_as('00000000-0000-0000-0000-0000000cc006', 'ec000000-0000-0000-0000-00000000c006');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'fay''s new phone sees ben (control)');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc006', 'ec000000-0000-0000-0000-0000000cc006');
select lives_ok($$select public.last_seen_of('00000000-0000-0000-0000-0000000cc002')$$,
                'old phone: asking does not raise');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), null, 'old phone: sees nobody');
select throws_ok($$select public.touch_last_seen()$$, '42501', null, 'old phone: a touch is refused');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc006'), null, 'old phone: nothing stored');

-- 8 ivy: only the allowlist half of app access ----------------------------------
select test_as('00000000-0000-0000-0000-0000000cc007', 'ec000000-0000-0000-0000-0000000cc007');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'ivy, active, sees ben (control)');
reset role;
delete from app_private.allowlist where email = 'ivy@lastseen.test';
select test_as('00000000-0000-0000-0000-0000000cc007', 'ec000000-0000-0000-0000-0000000cc007');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), null, 'delisted: sees nobody');
select throws_ok($$select public.touch_last_seen()$$, '42501', null, 'delisted: a touch is refused');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc007'), null, 'delisted: nothing stored');

-- 9 gus: never activated ------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000cc008', 'ec000000-0000-0000-0000-0000000cc008');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), null, 'never activated: sees nobody');
select throws_ok($$select public.touch_last_seen()$$, '42501', null, 'never activated: a touch is refused');
select is(public.activate_session(), true, 'gus activates');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'activated: gus sees ben (control)');
reset role;

-- 10 hal: signed in, not allowlisted ---------------------------------------------
select test_as('00000000-0000-0000-0000-0000000cc009', 'ec000000-0000-0000-0000-0000000cc009');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), null, 'a stranger sees nobody');
select throws_ok($$select public.touch_last_seen()$$, '42501', null, 'a stranger cannot touch');
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc009', false), 0::bigint,
          'a stranger cannot change even his own sharing');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc009'), null, 'a stranger stored nothing');

-- 11 anon ---------------------------------------------------------------------
select test_anon();
select throws_ok($$select public.touch_last_seen()$$, '42501', null, 'anon cannot touch');
select throws_ok($$select public.last_seen_of('00000000-0000-0000-0000-0000000cc002')$$, '42501', null,
                 'anon cannot ask');
select throws_ok($$select * from app_private.last_seen$$, '42501', null, 'anon cannot read the table');
select throws_ok($$update public.profiles set share_last_seen = false$$, '42501', null,
                 'anon cannot turn anyone''s sharing off');
reset role;

-- 12 turning sharing off forgets; turning it on does not bring it back ----------
-- An unrelated update, and an update that leaves it on, keep the time.
select test_as('00000000-0000-0000-0000-0000000cc002', 'ec000000-0000-0000-0000-0000000cc002');
update public.profiles set display_name = 'Ben B' where user_id = '00000000-0000-0000-0000-0000000cc002';
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc002', true), 1::bigint,
          'ben re-saves sharing on');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc002'), '2026-09-01 10:00+00'::timestamptz,
          'a rename or an on-to-on save keeps the time');
select test_as('00000000-0000-0000-0000-0000000cc002', 'ec000000-0000-0000-0000-0000000cc002');
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc002', false), 1::bigint,
          'ben turns sharing off');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc002'), null, 'off: ben''s time is deleted');
select is(stored('00000000-0000-0000-0000-0000000cc001'), now(), 'off: only ben''s time is deleted');
select test_as('00000000-0000-0000-0000-0000000cc002', 'ec000000-0000-0000-0000-0000000cc002');
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc002', false), 1::bigint,
          'ben saves off again');
select is(test_share_last_seen('00000000-0000-0000-0000-0000000cc002', true), 1::bigint,
          'ben turns sharing back on');
reset role;
select is(stored('00000000-0000-0000-0000-0000000cc002'), null, 'back on: nothing restored');
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), null,
          'back on: ada sees null until ben is next seen');
reset role;
select test_as('00000000-0000-0000-0000-0000000cc002', 'ec000000-0000-0000-0000-0000000cc002');
select public.touch_last_seen();
reset role;
select test_as('00000000-0000-0000-0000-0000000cc001', 'ec000000-0000-0000-0000-0000000cc001');
select is(public.last_seen_of('00000000-0000-0000-0000-0000000cc002'), now(),
          'after his next touch ada sees ben again');
reset role;

select * from finish();
rollback;
