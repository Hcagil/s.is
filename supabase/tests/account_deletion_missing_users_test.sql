begin;
select * from no_plan();

-- fixtures (every id ends in de0N) ---------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000de01', 'de-ann@mail.test', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-00000000de02', 'de-bob@mail.test', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-00000000de03', 'de-cat@mail.test', now(), '{"full_name":"Cat"}'),
  ('00000000-0000-0000-0000-00000000de04', 'de-old@mail.test', now(), '{"full_name":"Old"}'),
  ('00000000-0000-0000-0000-00000000de05', 'de-apl@mail.test', now(), '{"full_name":"Apl"}'),
  ('00000000-0000-0000-0000-00000000de06', 'de-aplx@mail.test', now(), '{"full_name":"Aplx"}'),
  ('00000000-0000-0000-0000-00000000de07', 'de-aplo@mail.test', now(), '{"full_name":"Aplo"}');
insert into app_private.allowlist(email) values
  ('de-ann@mail.test'), ('de-bob@mail.test'), ('de-old@mail.test'),
  ('de-apl@mail.test'), ('de-aplx@mail.test'), ('de-aplo@mail.test');
-- ann, bob, apl, aplx, aplo have a fresh session; old signed in 1 hour ago; cat has one but no allowlist row
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-00000000de01', now(), now()),
  ('b1b1b1b1-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '00000000-0000-0000-0000-00000000de02', now(), now()),
  ('c1c1c1c1-cccc-cccc-cccc-cccccccccccc', '00000000-0000-0000-0000-00000000de03', now(), now()),
  ('d1d1d1d1-dddd-dddd-dddd-dddddddddddd', '00000000-0000-0000-0000-00000000de04', now() - interval '1 hour', now() - interval '1 hour'),
  ('e1e1e1e1-eeee-eeee-eeee-eeeeeeeeeeee', '00000000-0000-0000-0000-00000000de05', now(), now()),
  ('f1f1f1f1-ffff-ffff-ffff-ffffffffffff', '00000000-0000-0000-0000-00000000de06', now(), now()),
  ('f2f2f2f2-ffff-ffff-ffff-ffffffffffff', '00000000-0000-0000-0000-00000000de07', now(), now());
-- apple identities for apl, aplx, aplo
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-de05', '00000000-0000-0000-0000-00000000de05', '{"sub":"apple-de05"}', 'apple'),
  ('apple-de06', '00000000-0000-0000-0000-00000000de06', '{"sub":"apple-de06"}', 'apple'),
  ('apple-de07', '00000000-0000-0000-0000-00000000de07', '{"sub":"apple-de07"}', 'apple');
-- apl: Apple revoked 1 minute ago (fresh enough); aplo: revoked 1 hour ago (too old); aplx: never revoked
insert into app_private.apple_revocations(user_id, revoked_at) values
  ('00000000-0000-0000-0000-00000000de05', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-00000000de07', now() - interval '1 hour');
-- reach for the ann/bob chat
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-00000000de01', '00000000-0000-0000-0000-00000000de02');

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- activate the allowlisted users (as the real app does)
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000de02', 'b1b1b1b1-bbbb-bbbb-bbbb-bbbbbbbbbbbb'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000de04', 'd1d1d1d1-dddd-dddd-dddd-dddddddddddd'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000de05', 'e1e1e1e1-eeee-eeee-eeee-eeeeeeeeeeee'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000de06', 'f1f1f1f1-ffff-ffff-ffff-ffffffffffff'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000de07', 'f2f2f2f2-ffff-ffff-ffff-ffffffffffff'); select public.activate_session(); reset role;
-- ann starts a chat with bob; one message from each
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.start_direct_conversation('00000000-0000-0000-0000-00000000de02');
reset role;
create temp table _fx as select conversation_id as conv from public.conversation_members where user_id = '00000000-0000-0000-0000-00000000de01' limit 1;
insert into public.messages(conversation_id, sender_id, body) select conv, '00000000-0000-0000-0000-00000000de01', 'from ann' from _fx;
insert into public.messages(conversation_id, sender_id, body) select conv, '00000000-0000-0000-0000-00000000de02', 'from bob' from _fx;
-- ann has a device token and a one-time key
insert into app_private.device_tokens(user_id, token, platform) values ('00000000-0000-0000-0000-00000000de01', 'tok-de01-aaaaaaaa', 'android');
insert into app_private.olm_one_time_keys(user_id, key) values ('00000000-0000-0000-0000-00000000de01', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
-- bob too (must survive ann's request)
insert into app_private.device_tokens(user_id, token, platform) values ('00000000-0000-0000-0000-00000000de02', 'tok-de02-bbbbbbbb', 'android');
select test_as('00000000-0000-0000-0000-00000000de03', 'c1c1c1c1-cccc-cccc-cccc-cccccccccccc');
select throws_ok($$select public.missing_users(array['00000000-0000-0000-0000-00000000de01']::uuid[])$$, 42501, null, 'B1: throws_ok 42501 (message null) for: select public.missing_users(array[...])');
reset role;
set local role anon;
select throws_ok($$select public.missing_users(array['00000000-0000-0000-0000-00000000de01']::uuid[])$$, 42501, null, 'B2: same as B1 for anon');
reset role;
delete from auth.users where id = '00000000-0000-0000-0000-00000000de03';
select test_as('00000000-0000-0000-0000-00000000de02', 'b1b1b1b1-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select set_eq($$select unnest(public.missing_users(array['00000000-0000-0000-0000-00000000de01','00000000-0000-0000-0000-00000000de02','00000000-0000-0000-0000-00000000de03','ffffffff-ffff-ffff-ffff-ffffffffffff']::uuid[]))$$, $$values ('00000000-0000-0000-0000-00000000de03'::uuid),('ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)$$, 'B3: set_eq of: select unnest(public.missing_users(...)) with values ...');
select is(coalesce(cardinality(public.missing_users(array[]::uuid[])), 0), 0, 'B4: is(coalesce(cardinality(public.missing_users(array[]::uuid[])), 0), 0, ...) empty input');
select is(cardinality(public.missing_users((select array_agg(gen_random_uuid()) from generate_series(1, 200)))), 200, 'B5: is(cardinality(public.missing_users((select array_agg(gen_random_uuid()) from generate_series(1, 200)))), 200, ...) exactly 200 ids accepted');
select throws_ok($$select public.missing_users((select array_agg(gen_random_uuid()) from generate_series(1, 201)))$$, 22023, null, 'B6: throws_ok 22023 (message null) for: select public.missing_users((select array_agg(gen_random_uuid()) from generate_series(1, 201)))');
reset role;
select test_as('00000000-0000-0000-0000-00000000de06', 'f1f1f1f1-ffff-ffff-ffff-ffffffffffff');
select throws_ok($$select public.request_account_deletion()$$, 'P0001', 'APPLE_REVOKE_REQUIRED', 'B7: throws_ok P0001 message ''APPLE_REVOKE_REQUIRED'' for select public.request_account_deletion() (Aplx never revoked)');
reset role;
set local role service_role;
select public.mark_apple_revoked('00000000-0000-0000-0000-00000000de06');
reset role;
select is((select count(*)::int from app_private.apple_revocations where user_id = '00000000-0000-0000-0000-00000000de06' and revoked_at > now() - interval '1 minute'), 1, 'B8: app_private.apple_revocations has exactly 1 row for user ... with revoked_at > now() - interval ''1 minute''');
select test_as('00000000-0000-0000-0000-00000000de06', 'f1f1f1f1-ffff-ffff-ffff-ffffffffffff');
select lives_ok($$select public.request_account_deletion()$$, 'B9: lives_ok on select public.request_account_deletion() (Aplx can request after revoke)');
reset role;
select test_as('00000000-0000-0000-0000-00000000de07', 'f2f2f2f2-ffff-ffff-ffff-ffffffffffff');
select throws_ok($$select public.request_account_deletion()$$, 'P0001', 'APPLE_REVOKE_REQUIRED', 'B10: throws_ok P0001 ''APPLE_REVOKE_REQUIRED'' for request (Aplo, revocation 1 hour old)');
reset role;
set local role service_role;
select public.mark_apple_revoked('00000000-0000-0000-0000-00000000de07');
reset role;
select is((select count(*)::int from app_private.apple_revocations where user_id = '00000000-0000-0000-0000-00000000de07' and revoked_at > now() - interval '1 minute'), 1, 'B11: apple_revocations has exactly 1 row for user ... with revoked_at > now() - interval ''1 minute''');
select test_as('00000000-0000-0000-0000-00000000de07', 'f2f2f2f2-ffff-ffff-ffff-ffffffffffff');
select lives_ok($$select public.request_account_deletion()$$, 'B12: lives_ok request (Aplo can request after revoke)');
reset role;
select test_as('00000000-0000-0000-0000-00000000de05', 'e1e1e1e1-eeee-eeee-eeee-eeeeeeeeeeee'); select public.request_account_deletion(); reset role;
create temp table _q as select request_id as rid from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de05';
select is((select outcome from app_private.account_deletion_log where request_id = (select rid from _q)), 'pending', 'B13: log row (request_id = (select rid from _q)) outcome is ''pending''');
delete from auth.users where id = '00000000-0000-0000-0000-00000000de05';
select is((select count(*)::int from app_private.account_deletions where request_id = (select rid from _q)), 0, 'B14: app_private.account_deletions has 0 rows with request_id = (select rid from _q)');
select is((select outcome from app_private.account_deletion_log where request_id = (select rid from _q)), 'pending', 'B15: log row outcome is still ''pending''');
select lives_ok($$select app_private.run_account_deletion()$$, 'B16: lives_ok on: select app_private.run_account_deletion()');
select is((select outcome from app_private.account_deletion_log where request_id = (select rid from _q)), 'done', 'B17: log row outcome is now ''done''');
select * from finish();
rollback;
