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
create temp table _q(uid uuid, rid uuid);
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); select public.request_account_deletion(); reset role;
insert into _q select user_id, request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01';
insert into auth.sessions (id, user_id, created_at, updated_at) values ('a2a2a2a2-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-00000000de01', now(), now());
select test_as('00000000-0000-0000-0000-00000000de01', 'a2a2a2a2-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); select public.activate_session_status(); select public.request_account_deletion(); reset role;
select test_as('00000000-0000-0000-0000-00000000de02', 'b1b1b1b1-bbbb-bbbb-bbbb-bbbbbbbbbbbb'); select public.request_account_deletion(); reset role;
select is((select count(*)::int from app_private.account_deletion_log), 3, 'log has 3 rows');
select is((select count(distinct email_hmac)::int from app_private.account_deletion_log), 2, 'distinct email_hmac count 2');
select is((select count(*)::int from app_private.account_deletion_log where email_hmac ilike '%ann%' or email_hmac ilike '%bob%'), 0, 'no email_hmac like ann or bob');
select is((select bool_and(char_length(email_hmac) >= 32) from app_private.account_deletion_log), true, 'all email_hmac >= 32');
select is((select count(*)::int from app_private.account_deletion_log where email_hmac in ('de-ann@mail.test','de-bob@mail.test')), 0, 'email_hmac not in list');
select is((select count(*)::int from information_schema.columns where table_schema = 'app_private' and table_name = 'account_deletion_log' and column_name in ('user_id','email','name','uid')), 0, 'no columns in list');
select is((select outcome from app_private.account_deletion_log where request_id = (select rid from _q where uid = '00000000-0000-0000-0000-00000000de01')), 'cancelled', 'outcome cancelled');
select test_as('00000000-0000-0000-0000-00000000de04', 'd1d1d1d1-dddd-dddd-dddd-dddddddddddd');
select throws_ok($$select * from app_private.account_deletions$$, '42501', null, 'throws_ok 42501 for: select * from app_private.account_deletions');
select throws_ok($$select * from app_private.account_deletion_log$$, '42501', null, 'throws_ok 42501 for: select * from app_private.account_deletion_log');
select throws_ok($$select * from app_private.apple_revocations$$, '42501', null, 'throws_ok 42501 for: select * from app_private.apple_revocations');
select throws_ok($$select * from vault.decrypted_secrets$$, '42501', null, 'throws_ok 42501 for: select * from vault.decrypted_secrets');
select throws_ok($$select * from vault.secrets$$, '42501', null, 'throws_ok 42501 for: select * from vault.secrets');
select throws_ok($$select app_private.purge_account_deletion_log()$$, '42501', null, 'throws_ok 42501 for: select app_private.purge_account_deletion_log()');
select throws_ok($$select app_private.run_account_deletion()$$, '42501', null, 'throws_ok 42501 for: select app_private.run_account_deletion()');
select throws_ok($$select app_private.cancel_account_deletion('00000000-0000-0000-0000-00000000de01')$$, '42501', null, 'throws_ok 42501 for: select app_private.cancel_account_deletion(''00000000-0000-0000-0000-00000000de01'')');
reset role;
set local role anon;
select throws_ok($$select * from app_private.account_deletions$$, '42501', null, 'anon throws_ok 42501 for: select * from app_private.account_deletions');
select throws_ok($$select * from app_private.account_deletion_log$$, '42501', null, 'anon throws_ok 42501 for: select * from app_private.account_deletion_log');
select throws_ok($$select * from app_private.apple_revocations$$, '42501', null, 'anon throws_ok 42501 for: select * from app_private.apple_revocations');
reset role;
select is((select schedule from cron.job where jobname = 'account-deletion'), '7 * * * *', 'schedule 7 * * * *');
select is((select command from cron.job where jobname = 'account-deletion'), 'select app_private.run_account_deletion()', 'command run_account_deletion');
select ok((select active from cron.job where jobname = 'account-deletion'), 'active true');
select is((select schedule from cron.job where jobname = 'account-deletion-log-purge'), '23 3 * * *', 'schedule 23 3 * * *');
select is((select command from cron.job where jobname = 'account-deletion-log-purge'), 'select app_private.purge_account_deletion_log()', 'command purge_account_deletion_log');
select ok((select active from cron.job where jobname = 'account-deletion-log-purge'), 'active true');
select is((select count(*)::int from vault.decrypted_secrets where name in ('deletion_log_key')), 1, 'deletion_log_key count 1');
select ok((select char_length(decrypted_secret) >= 16 from vault.decrypted_secrets where name in ('deletion_log_key')), 'decrypted_secret length >= 16');
insert into app_private.account_deletion_log(request_id, email_hmac, requested_at, due_at, done_at, channel, outcome) select gen_random_uuid(), 'purge-old', now() - interval '3 years 1 month 1 day', now() - interval '3 years 1 month 1 day', now() - interval '3 years 1 month 1 day', channel, 'done' from app_private.account_deletion_log limit 1;
insert into app_private.account_deletion_log(request_id, email_hmac, requested_at, due_at, done_at, channel, outcome) select gen_random_uuid(), 'purge-edge', now() - interval '3 years 1 month' + interval '1 day', now() - interval '3 years 1 month' + interval '1 day', now() - interval '3 years 1 month' + interval '1 day', channel, 'done' from app_private.account_deletion_log limit 1;
insert into app_private.account_deletion_log(request_id, email_hmac, requested_at, due_at, done_at, channel, outcome) select gen_random_uuid(), 'purge-new', now(), now(), now(), channel, 'done' from app_private.account_deletion_log limit 1;
select app_private.purge_account_deletion_log();
select is((select count(*)::int from app_private.account_deletion_log where email_hmac = 'purge-old'), 0, 'purge-old count 0');
select is((select count(*)::int from app_private.account_deletion_log where email_hmac = 'purge-edge'), 1, 'purge-edge count 1');
select is((select count(*)::int from app_private.account_deletion_log where email_hmac = 'purge-new'), 1, 'purge-new count 1');
select is((select count(*)::int from app_private.account_deletion_log where request_id in (select rid from _q)), 1, 'request_id in _q count 1');
insert into public.stickers(id, owner_id) values ('5e5e5e5e-5e5e-5e5e-5e5e-5e5e5e5e5e01', '00000000-0000-0000-0000-00000000de01');
insert into public.group_events(id, conversation_id, kind, actor_id, subject_id) select 'ae000000-0000-0000-0000-000000000001', conv, 'left', null, '00000000-0000-0000-0000-00000000de01' from _fx;
insert into public.group_events(id, conversation_id, kind, actor_id, subject_id) select 'ae000000-0000-0000-0000-000000000002', conv, 'added', '00000000-0000-0000-0000-00000000de01', '00000000-0000-0000-0000-00000000de02' from _fx;
insert into public.group_events(id, conversation_id, kind, actor_id, subject_id) select 'ae000000-0000-0000-0000-000000000003', conv, 'added', '00000000-0000-0000-0000-00000000de02', '00000000-0000-0000-0000-00000000de01' from _fx;
delete from auth.users where id = '00000000-0000-0000-0000-00000000de01';
select is((select count(*)::int from public.group_events where id = 'ae000000-0000-0000-0000-000000000001'), 0, 'group_event id 1 gone');
select is((select count(*)::int from public.group_events where id = 'ae000000-0000-0000-0000-000000000003'), 0, 'group_event id 3 gone');
select is((select count(*)::int from public.group_events where id = 'ae000000-0000-0000-0000-000000000002'), 1, 'group_event id 2 exists');
select ok((select actor_id from public.group_events where id = 'ae000000-0000-0000-0000-000000000002') is null, 'actor_id null');
select is((select count(*)::int from public.stickers where id = '5e5e5e5e-5e5e-5e5e-5e5e-5e5e5e5e5e01'), 1, 'sticker id exists');
select ok((select owner_id from public.stickers where id = '5e5e5e5e-5e5e-5e5e-5e5e-5e5e5e5e5e01') is null, 'owner_id null');
select is((select count(*)::int from public.messages where sender_id = '00000000-0000-0000-0000-00000000de01'), 0, 'messages from ann count 0');
select is((select count(*)::int from public.messages where sender_id = '00000000-0000-0000-0000-00000000de02'), 1, 'messages from bob count 1');
select is((select count(*)::int from public.profiles where user_id = '00000000-0000-0000-0000-00000000de01'), 0, 'profile ann count 0');
select is((select count(*)::int from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01'), 0, 'account_deletion ann count 0');
select * from finish();
rollback;
