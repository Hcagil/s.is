begin;
select plan(53);

-- Push receipts (0.30): what a phone reports about each push it handled.
--
-- 1. app_private.push_receipts is private like every app_private table: RLS
--    on, no policy, nothing granted to anon or authenticated. Each is
--    asserted on its own -- any one of them alone already denies a client,
--    so a "client gets 42501" test stays green after the other two go.
-- 2. report_push_receipts(jsonb) is the only way in. It needs app access,
--    refuses anything but an array, always files rows under the caller,
--    keeps only well-formed stages, never trusts a client's values (bad
--    uuid / build -> null, bad time -> now, error cut to 300, time clamped to the
--    last 7 days), reads at most 100 elements per call and leaves the
--    caller at most 500 rows -- never touching anyone else's.
--
-- The database is not empty (the integration tests leave rows behind), so
-- every lookup is scoped to these fixtures.
--
-- Fixtures fail one gate each: max is allowlisted and signed in but never
-- claimed the active device, so he fails only has_app_access().

-- fixtures -------------------------------------------------------------------
-- kai  allowlisted, active     the subject
-- lea  allowlisted, active     someone else's rows, which must never move
-- max  allowlisted, signed in, NOT active
-- nia  allowlisted, active     retention (starts with no rows)
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ab001', 'kai@receipts.test', now(), '{"full_name":"Kai"}'),
  ('00000000-0000-0000-0000-0000000ab002', 'lea@receipts.test', now(), '{"full_name":"Lea"}'),
  ('00000000-0000-0000-0000-0000000ab003', 'max@receipts.test', now(), '{"full_name":"Max"}'),
  ('00000000-0000-0000-0000-0000000ab004', 'nia@receipts.test', now(), '{"full_name":"Nia"}');
insert into app_private.allowlist(email) values
  ('kai@receipts.test'), ('lea@receipts.test'), ('max@receipts.test'), ('nia@receipts.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ab000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ab001', now(), now()),
  ('ab000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000ab002', now(), now()),
  ('ab000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000ab003', now(), now()),
  ('ab000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000ab004', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000ab002', 'ab000000-0000-0000-0000-000000000002');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000ab004', 'ab000000-0000-0000-0000-000000000004');
select public.activate_session();
reset role;

-- 1 the table is private (6) --------------------------------------------------
select has_table('app_private', 'push_receipts', 'push_receipts exists');
select is((select relrowsecurity from pg_class where oid = 'app_private.push_receipts'::regclass),
          true, 'RLS is on');
select is((select count(*)::int from pg_policies
            where schemaname = 'app_private' and tablename = 'push_receipts'),
          0, 'no policy');
select is((select count(*)::int from information_schema.role_table_grants
            where table_schema = 'app_private' and table_name = 'push_receipts'
              and grantee in ('anon', 'authenticated', 'PUBLIC')),
          0, 'nothing granted to anon, authenticated or PUBLIC');
select ok(not has_table_privilege('anon', 'app_private.push_receipts',
            'select,insert,update,delete'), 'anon has no table privilege');
select ok(not has_table_privilege('authenticated', 'app_private.push_receipts',
            'select,insert,update,delete'), 'authenticated has no table privilege');

-- 2 the function's own shape and grants (5) -----------------------------------
select is((select prosecdef from pg_proc
            where oid = 'public.report_push_receipts(jsonb)'::regprocedure),
          true, 'security definer');
select ok((select proconfig from pg_proc
            where oid = 'public.report_push_receipts(jsonb)'::regprocedure)
          && array['search_path=""', 'search_path='],
          'search_path is pinned empty');
select function_returns('public', 'report_push_receipts', array['jsonb'], 'integer',
          'returns integer');
select ok(not has_function_privilege('anon', 'public.report_push_receipts(jsonb)', 'execute'),
          'anon cannot execute');
select ok(has_function_privilege('authenticated', 'public.report_push_receipts(jsonb)', 'execute'),
          'authenticated can execute');

-- 3 the gates (6) --------------------------------------------------------------
set local role anon;
select throws_ok($$select public.report_push_receipts('[{"stage":"received"}]')$$,
          '42501', null, 'anon is refused');
reset role;

select test_as('00000000-0000-0000-0000-0000000ab003', 'ab000000-0000-0000-0000-000000000003');
select throws_ok($$select public.report_push_receipts('[{"stage":"received"}]')$$,
          '42501', null, 'no app access (signed in, not active): 42501');
reset role;
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab003'),
          0, 'and nothing was stored for max');

select test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
select throws_ok($$select public.report_push_receipts(null)$$, '22023', null, 'null: 22023');
select throws_ok($$select public.report_push_receipts('{"stage":"received"}')$$,
          '22023', null, 'an object, not an array: 22023');
select throws_ok($$select public.report_push_receipts('"received"')$$,
          '22023', null, 'a string: 22023');

-- 4 what is kept, and for whom (still kai) (11) -------------------------------
select is(public.report_push_receipts(jsonb_build_array(
            jsonb_build_object('stage', 'received', 'build', 1),
            jsonb_build_object('stage', 'shown', 'build', 1),
            jsonb_build_object('stage', 'error', 'build', 1),
            jsonb_build_object('stage', 'dropped:no_owner', 'build', 1),
            jsonb_build_object('stage', 'dropped:' || repeat('a', 40), 'build', 1),
            -- forged owner: must still be filed under kai
            jsonb_build_object('stage', 'shown', 'build', 2,
                               'user_id', '00000000-0000-0000-0000-0000000ab002'))),
          6, 'six valid receipts: six counted');
select is(public.report_push_receipts(jsonb_build_array(
            jsonb_build_object('stage', 'bogus', 'build', 3),
            jsonb_build_object('stage', 'dropped:BAD', 'build', 3),
            jsonb_build_object('stage', 'dropped:', 'build', 3),
            jsonb_build_object('stage', 'dropped:' || repeat('a', 41), 'build', 3),
            jsonb_build_object('stage', 'RECEIVED', 'build', 3),
            jsonb_build_object('stage', ' shown', 'build', 3),
            jsonb_build_object('stage', 'dropped:no-owner', 'build', 3),
            jsonb_build_object('build', 3),
            jsonb_build_object('stage', 5, 'build', 3),
            '5'::jsonb, '"shown"'::jsonb, 'null'::jsonb, '[]'::jsonb,
            jsonb_build_object('stage', 'shown', 'build', 4))),
          1, 'invalid stages and non-objects are skipped and not counted');
select is(public.report_push_receipts('[]'), 0, 'an empty array: 0');
reset role;

select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab001'),
          7, 'kai has exactly the seven counted rows');
select is((select count(*)::int from app_private.push_receipts
            where build = 3 and user_id::text like '00000000-0000-0000-0000-0000000ab%'),
          0, 'no invalid stage stored, for any fixture member');
select is((select array_agg(stage order by stage) from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 1),
          array['dropped:' || repeat('a', 40), 'dropped:no_owner', 'error', 'received', 'shown'],
          'the valid stages are stored as sent');
select is((select user_id from app_private.push_receipts
            where user_id::text like '00000000-0000-0000-0000-0000000ab%' and build = 2),
          '00000000-0000-0000-0000-0000000ab001'::uuid,
          'a forged user_id is ignored: filed under the caller');
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab002'),
          0, 'nothing reached lea');

-- 5 values the client cannot be trusted with (13) -----------------------------
select test_as('00000000-0000-0000-0000-0000000ab001', 'ab000000-0000-0000-0000-000000000001');
select is(public.report_push_receipts(jsonb_build_array(
            jsonb_build_object('stage', 'error', 'build', 10, 'error', repeat('e', 1000)),
            jsonb_build_object('stage', 'shown', 'build', 11,
                               'message_id', '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d'),
            jsonb_build_object('stage', 'shown', 'build', 12, 'message_id', 'not-a-uuid'),
            jsonb_build_object('stage', 'shown', 'build', 'abc', 'error', 'bad-build'),
            jsonb_build_object('stage', 'shown', 'build', 13, 'occurred_at', 'yesterday-ish'),
            jsonb_build_object('stage', 'shown', 'build', 14, 'occurred_at', '2100-01-01T00:00:00Z'),
            jsonb_build_object('stage', 'shown', 'build', 15, 'occurred_at', '2000-01-01T00:00:00Z'),
            jsonb_build_object('stage', 'shown', 'build', 16,
                               'occurred_at', to_jsonb(now() - interval '1 hour')),
            jsonb_build_object('stage', 'shown', 'build', 17, 'message_id', 42))),
          9, 'malformed values do not drop the receipt');
reset role;
select is((select length(error) from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 10),
          300, 'error cut to 300');
select is((select message_id::text from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 11),
          '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d', 'a uuid message_id is kept');
select ok((select message_id is null from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 12),
          'a malformed message_id becomes null');
select ok((select message_id is null from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 17),
          'a numeric message_id becomes null');
select ok((select build is null from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and error = 'bad-build'),
          'a non-numeric build becomes null');
select is((select build from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 11), 11,
          'a numeric build is kept');
-- occurred_at is NOT NULL: an unreadable time is not a reason to lose the
-- receipt, and the server's own time is the only one left.
select is((select occurred_at from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 13), now(),
          'a malformed occurred_at falls back to the server''s now');
select is((select occurred_at from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 14), now(),
          'a future occurred_at is clamped to now');
select is((select occurred_at from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 15),
          now() - interval '7 days', 'an ancient occurred_at is clamped to 7 days ago');
select is((select occurred_at from app_private.push_receipts where user_id = '00000000-0000-0000-0000-0000000ab001' and build = 16),
          now() - interval '1 hour', 'an occurred_at inside the window is kept');
select ok((select bool_and(created_at is not null) from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab001'),
          'created_at is set by the server');
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab001'),
          16, 'kai now has 16 rows');

-- 6 at most 100 per call, the first 100 (3) -----------------------------------
select test_as('00000000-0000-0000-0000-0000000ab002', 'ab000000-0000-0000-0000-000000000002');
select is(public.report_push_receipts(
            (select jsonb_agg(jsonb_build_object('stage', 'received', 'build', 1000 + g) order by g)
               from generate_series(1, 101) g)),
          100, '101 elements: 100 counted');
reset role;
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab002'),
          100, '100 stored');
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab002' and build = 1101),
          0, 'the 101st is the one ignored');

-- 7 at most 500 rows per member, newest kept, nobody else touched (6) ---------
-- nia sends six batches of 100, each newer than the one before, with valid
-- times inside the window. The oldest batch (builds 2001..2100) must go.
select test_as('00000000-0000-0000-0000-0000000ab004', 'ab000000-0000-0000-0000-000000000004');
select is(public.report_push_receipts(
            (select jsonb_agg(jsonb_build_object('stage', 'shown', 'build', 1000 * b + g,
                      'occurred_at', to_jsonb(now() - make_interval(days => 7 - b, mins => 100 - g))))
               from generate_series(1, 100) g)),
          100, format('batch %s: 100', b))
  from generate_series(2, 6) b;
select is(public.report_push_receipts(
            (select jsonb_agg(jsonb_build_object('stage', 'shown', 'build', 7000 + g,
                      'occurred_at', to_jsonb(now() - make_interval(mins => 100 - g))))
               from generate_series(1, 100) g)),
          100, 'the sixth batch is still counted in full');
reset role;
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab004'),
          500, 'nia keeps 500');
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab004' and build between 2001 and 2100),
          0, 'the oldest 100 are the ones gone');
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab004' and build between 7001 and 7100),
          100, 'the newest batch is all there');
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab002'), 100,
          'lea''s rows untouched by nia''s trim');

-- 8 deleting the member deletes their receipts (2) ----------------------------
delete from auth.users where id = '00000000-0000-0000-0000-0000000ab001';
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab001'),
          0, 'kai''s receipts went with him');
select is((select count(*)::int from app_private.push_receipts
            where user_id = '00000000-0000-0000-0000-0000000ab002'),
          100, 'lea''s did not');

select * from finish();
rollback;
