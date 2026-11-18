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
insert into storage.objects(bucket_id,name,owner_id,metadata) select 'attachments', conv::text||'/ann-file.jpg', '00000000-0000-0000-0000-00000000de01', '{"size":3}'::jsonb from _fx;
insert into storage.objects(bucket_id,name,owner_id,metadata) select 'attachments', conv::text||'/bob-file.jpg', '00000000-0000-0000-0000-00000000de02', '{"size":3}'::jsonb from _fx;
insert into storage.objects(bucket_id,name,owner_id,metadata) select 'link-previews', conv::text||'/d8c00000-0000-0000-0000-0000000000a1.jpg', '00000000-0000-0000-0000-00000000de01', '{"size":3}'::jsonb from _fx;
insert into storage.objects(bucket_id,name,owner_id,metadata) values ('avatars','profile/00000000-0000-0000-0000-00000000de01/1.jpg','00000000-0000-0000-0000-00000000de01','{"size":3}'::jsonb);
update public.messages set attachment_path = conversation_id::text||'/ann-file.jpg', attachment_name='f.jpg', attachment_mime='image/jpeg', attachment_size=3 where body='from ann';
update public.messages set attachment_path = conversation_id::text||'/bob-file.jpg', attachment_name='g.jpg', attachment_mime='image/jpeg', attachment_size=3 where body='from bob';
insert into public.messages(id,conversation_id,sender_id,body,link_preview) select 'd8c00000-0000-0000-0000-0000000000a1', conv, '00000000-0000-0000-0000-00000000de01', 'card mail.test/x', jsonb_build_object('url','https://mail.test/x','title','T','image', conv::text||'/d8c00000-0000-0000-0000-0000000000a1.jpg') from _fx;
update public.profiles set avatar_path='profile/00000000-0000-0000-0000-00000000de01/1.jpg' where user_id='00000000-0000-0000-0000-00000000de01';
create temp table _q(uid uuid, rid uuid);
create temp table _c(user_id uuid, request_id uuid);
grant all on _c to service_role;
grant select on _q to service_role;
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); select public.request_account_deletion(); reset role;
select test_as('00000000-0000-0000-0000-00000000de05', 'e1e1e1e1-eeee-eeee-eeee-eeeeeeeeeeee'); select public.request_account_deletion(); reset role;
insert into _q select user_id, request_id from app_private.account_deletions;
select is((select count(*)::int from _q), 2, '_q has exactly 2 rows');
select test_as('00000000-0000-0000-0000-00000000de02', 'b1b1b1b1-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select throws_ok($$select public.account_deletion_claim(5)$$, '42501', 'permission denied for function account_deletion_claim', 'anon claim (as A2)');
select throws_ok($$select public.account_deletion_prepare('00000000-0000-0000-0000-00000000de01')$$, '42501', 'permission denied for function account_deletion_prepare', 'anon prepare (as A3)');
select throws_ok($$select public.account_deletion_done('00000000-0000-0000-0000-00000000de01')$$, '42501', 'permission denied for function account_deletion_done', 'anon done (as A4)');
select throws_ok($$select public.mark_apple_revoked('00000000-0000-0000-0000-00000000de01')$$, '42501', 'permission denied for function mark_apple_revoked', 'anon mark_apple_revoked (as A5)');
reset role;
set local role anon;
select throws_ok($$select public.account_deletion_claim(5)$$, '42501', 'permission denied for function account_deletion_claim', 'anon claim (as A6)');
select throws_ok($$select public.account_deletion_prepare('00000000-0000-0000-0000-00000000de01')$$, '42501', 'permission denied for function account_deletion_prepare', 'anon prepare (as A7)');
select throws_ok($$select public.account_deletion_done('00000000-0000-0000-0000-00000000de01')$$, '42501', 'permission denied for function account_deletion_done', 'anon done (as A8)');
select throws_ok($$select public.mark_apple_revoked('00000000-0000-0000-0000-00000000de01')$$, '42501', 'permission denied for function mark_apple_revoked', 'anon mark_apple_revoked (as A9)');
reset role;
set local role service_role;
insert into _c select * from public.account_deletion_claim(10);
reset role;
select is((select count(*)::int from _c), 0, '_c has 0 rows (nothing is due yet)');
set local role service_role;
select is(public.account_deletion_prepare('00000000-0000-0000-0000-00000000de01'), false, 'request not due yet');
select is(public.account_deletion_prepare('ffffffff-ffff-ffff-ffff-ffffffffffff'), false, 'unknown user');
reset role;
select is((select count(*)::int from app_private.storage_removal_queue where path like (select conv from _fx)::text || '%'), 0, 'app_private.storage_removal_queue has 0 rows with path like conv');
update app_private.account_deletions set due_at = now() - interval '1 minute' where user_id = '00000000-0000-0000-0000-00000000de01';
set local role service_role;
insert into _c select * from public.account_deletion_claim(10);
reset role;
select is((select count(*)::int from _c), 1, '_c has exactly 1 row');
select is((select user_id from _c), '00000000-0000-0000-0000-00000000de01'::uuid, 'that row''s user_id is Ann');
select is((select request_id from _c), (select rid from _q where uid = '00000000-0000-0000-0000-00000000de01'), 'request_id equals _q rid');
select is((select attempts from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01'), 1, 'Ann attempts = 1');
select ok((select claimed_at is not null from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01'), 'claimed_at is not null');
truncate _c;
set local role service_role;
insert into _c select * from public.account_deletion_claim(10);
reset role;
select is((select count(*)::int from _c), 0, '_c has 0 rows (lease still active)');
update app_private.account_deletions set claimed_at = now() - interval '14 minutes' where user_id = '00000000-0000-0000-0000-00000000de01';
truncate _c;
set local role service_role;
insert into _c select * from public.account_deletion_claim(10);
reset role;
select is((select count(*)::int from _c), 0, '_c has 0 rows (lease 14 minutes old is still held)');
update app_private.account_deletions set claimed_at = now() - interval '16 minutes' where user_id = '00000000-0000-0000-0000-00000000de01';
truncate _c;
set local role service_role;
insert into _c select * from public.account_deletion_claim(10);
reset role;
select is((select count(*)::int from _c), 1, '_c has 1 row');
select is((select attempts from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01'), 2, 'Ann attempts is now 2');
update app_private.account_deletions set due_at = now() - interval '1 minute', claimed_at = null where user_id in ('00000000-0000-0000-0000-00000000de01', '00000000-0000-0000-0000-00000000de05');
truncate _c;
set local role service_role;
insert into _c select * from public.account_deletion_claim(1);
reset role;
select is((select count(*)::int from _c), 1, '_c has exactly 1 row (batch of 1)');
update app_private.account_deletions set claimed_at = null where user_id in ('00000000-0000-0000-0000-00000000de01', '00000000-0000-0000-0000-00000000de05');
set local role service_role;
select is(public.account_deletion_prepare('00000000-0000-0000-0000-00000000de01'), true, 'due request accepted');
reset role;
select is((select count(*)::int from app_private.storage_removal_queue where path like (select conv from _fx)::text || '/%' or path like 'profile/00000000-0000-0000-0000-00000000de01/%'), 0, 'prepare leaves the sweeper queue empty');
select is((select outcome from app_private.account_deletion_log where request_id = (select rid from _q where uid = '00000000-0000-0000-0000-00000000de01')), 'pending', 'Ann''s log row outcome pending');
set local role service_role;
select public.account_deletion_done((select rid from _q where uid = '00000000-0000-0000-0000-00000000de01'));
reset role;
select is((select outcome from app_private.account_deletion_log where request_id = (select rid from _q where uid = '00000000-0000-0000-0000-00000000de01')), 'done', 'Ann''s log row outcome is now done');
select ok((select done_at is not null from app_private.account_deletion_log where request_id = (select rid from _q where uid = '00000000-0000-0000-0000-00000000de01')), 'Ann''s log row done_at is not null');
select ok((select exists(select 1 from app_private.storage_removal_queue where bucket = 'attachments' and path like (select conv from _fx)::text || '/ann-file.jpg%')), 'queue has >= 1 row with bucket attachments and path like conv/ann-file.jpg% after done');
select ok((select exists(select 1 from app_private.storage_removal_queue where bucket = 'link-previews' and path = (select conv from _fx)::text || '/d8c00000-0000-0000-0000-0000000000a1.jpg')), 'queue has >= 1 row with bucket link-previews and path conv/d8c00000-0000-0000-0000-0000000000a1.jpg after done');
select ok((select exists(select 1 from app_private.storage_removal_queue where bucket = 'avatars' and path = 'profile/00000000-0000-0000-0000-00000000de01/1.jpg')), 'queue has >= 1 row with bucket avatars and path profile/.../1.jpg after done');
select ok((select not exists(select 1 from app_private.storage_removal_queue where path like (select conv from _fx)::text || '/bob-file.jpg%')), 'queue has 0 rows with path like conv/bob-file.jpg% after done');
select is((select outcome from app_private.account_deletion_log where request_id = (select rid from _q where uid = '00000000-0000-0000-0000-00000000de05')), 'pending', 'Apl''s log row outcome is still pending');
-- done on a cancelled request marks nothing and queues nothing (Bob)
select test_as('00000000-0000-0000-0000-00000000de02','b1b1b1b1-bbbb-bbbb-bbbb-bbbbbbbbbbbb'); select public.request_account_deletion(); reset role;
insert into _q select user_id, request_id from app_private.account_deletions where user_id='00000000-0000-0000-0000-00000000de02';
update app_private.account_deletions set due_at = now() - interval '1 minute' where user_id='00000000-0000-0000-0000-00000000de02';
truncate _c;
set local role service_role; insert into _c select * from public.account_deletion_claim(10); select public.account_deletion_prepare('00000000-0000-0000-0000-00000000de02'); reset role;
insert into auth.sessions (id, user_id, created_at, updated_at) values ('b2b2b2b2-bbbb-bbbb-bbbb-bbbbbbbbbbbb','00000000-0000-0000-0000-00000000de02', now(), now());
select test_as('00000000-0000-0000-0000-00000000de02','b2b2b2b2-bbbb-bbbb-bbbb-bbbbbbbbbbbb'); select public.activate_session_status(); reset role;
set local role service_role; select public.account_deletion_done((select rid from _q where uid='00000000-0000-0000-0000-00000000de02')); reset role;
select is((select outcome from app_private.account_deletion_log where request_id=(select rid from _q where uid='00000000-0000-0000-0000-00000000de02')), 'cancelled', 'done on a cancelled request marks nothing');
select is((select count(*)::int from app_private.storage_removal_queue where path like '%bob-file.jpg%'), 0, 'done on a cancelled request queues no file');
select * from finish();
rollback;
