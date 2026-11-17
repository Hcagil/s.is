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
-- anon
set local role anon;
select throws_ok($$select public.request_account_deletion()$$, '42501', 'permission denied for function request_account_deletion', 'anon cannot call it');
reset role;

-- Cat
select test_as('00000000-0000-0000-0000-00000000de03', 'c1c1c1c1-cccc-cccc-cccc-cccccccccccc');
select throws_ok($$select public.request_account_deletion()$$, '42501', 'not permitted', 'Cat has no app access');
reset role;

-- Old
select test_as('00000000-0000-0000-0000-00000000de04', 'd1d1d1d1-dddd-dddd-dddd-dddddddddddd');
select throws_ok($$select public.request_account_deletion()$$, 'P0001', 'REAUTH');
reset role;
select is((select count(*)::int from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de04'), 0, 'Old has no account_deletions');
select is((select count(*)::int from app_private.account_deletion_log), 0, 'No account_deletion_log rows');

-- Aplx
select test_as('00000000-0000-0000-0000-00000000de06', 'f1f1f1f1-ffff-ffff-ffff-ffffffffffff');
select throws_ok($$select public.request_account_deletion()$$, 'P0001', 'APPLE_REVOKE_REQUIRED');
reset role;
select is((select count(*)::int from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de06'), 0, 'Aplx has no account_deletions');

-- Aplo
select test_as('00000000-0000-0000-0000-00000000de07', 'f2f2f2f2-ffff-ffff-ffff-ffffffffffff');
select throws_ok($$select public.request_account_deletion()$$, 'P0001', 'APPLE_REVOKE_REQUIRED');
reset role;
select is((select count(*)::int from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de07'), 0, 'Aplo has no account_deletions');

-- Apl
select test_as('00000000-0000-0000-0000-00000000de05', 'e1e1e1e1-eeee-eeee-eeee-eeeeeeeeeeee');
create temp table _r(uid uuid, due timestamptz);
grant all on _r to authenticated;
insert into _r select '00000000-0000-0000-0000-00000000de05', public.request_account_deletion();
reset role;
select is((select due from _r where uid = '00000000-0000-0000-0000-00000000de05'), (select due_at from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de05'), 'Apl due matches the stored due_at');

-- Ann
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
insert into _r select '00000000-0000-0000-0000-00000000de01', public.request_account_deletion();
reset role;
select ok((select due from _r where uid = '00000000-0000-0000-0000-00000000de01') between now() + interval '28 days 23 hours' and now() + interval '29 days 1 hour', 'Ann due is about 29 days away');
select is((select count(*)::int from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01'), 1, 'Ann has one account_deletions row');
select is((select count(*)::int from app_private.account_deletion_log where request_id = (select request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01') and outcome = 'pending' and done_at is null and email_hmac is not null and email_hmac not like '%ann%'), 1, 'Ann has one pending log row');

-- After Ann's request (superuser)
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-0000-0000-00000000de01'), 0, 'Ann has no auth.sessions');
select is((select count(*)::int from app_private.active_sessions where user_id = '00000000-0000-0000-0000-00000000de01'), 0, 'Ann has no active_sessions');
select is((select count(*)::int from app_private.device_tokens where user_id = '00000000-0000-0000-0000-00000000de01'), 0, 'Ann has no device_tokens');
select is((select count(*)::int from app_private.olm_one_time_keys where user_id = '00000000-0000-0000-0000-00000000de01'), 0, 'Ann has no olm_one_time_keys');
select is((select count(*)::int from app_private.device_tokens where user_id = '00000000-0000-0000-0000-00000000de02'), 1, 'Bob has one device_token');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-0000-0000-00000000de02'), 1, 'Bob has one auth.session');

-- Ann with old session id
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select is((select count(*)::int from public.profiles where user_id = '00000000-0000-0000-0000-00000000de01'), 0, 'Ann cannot read any profile after her request');
reset role;

-- Bob
grant select on _fx to authenticated;
select test_as('00000000-0000-0000-0000-00000000de02', 'b1b1b1b1-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select is((select count(*)::int from public.profiles where user_id = '00000000-0000-0000-0000-00000000de01'), 1, 'Bob sees Ann profile');
select is((select count(*)::int from public.messages where conversation_id = (select conv from _fx)), 2, 'Bob sees two messages');
reset role;
select is((select count(*)::int from auth.users where id = '00000000-0000-0000-0000-00000000de01'), 1, 'Ann still exists in auth.users');

select * from finish();
rollback;
