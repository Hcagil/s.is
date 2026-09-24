-- v0.10: replies and forwards (20260924150000_reply_and_forward.sql).
--
-- A forward is an ordinary insert the server does not distinguish from any
-- other -- forwarded is just a plain insertable column, nothing here checks
-- who set it or why. What IS under test is the reply_to gate entirely:
-- same-conversation only, a tombstoned message still quotable, a vanished
-- sender's account clearing it, the column grants, and a brief re-check that
-- this migration's full policy rewrite kept every v0.10A gate (membership,
-- own folder, own photo).
--
-- Every negative reply_to fixture fails exactly ONE gate, and all three raise
-- the identical row-level-security message: nothing here lets a caller tell
-- "no such message" apart from "not in this conversation".
--   * ann is a member of BOTH _c1 and _c2 -- a _c2 message referenced while
--     sending into _c1 fails only the same-conversation gate, never a
--     membership gate she would also fail.
--   * carl's message lives in _c3, which ann never joined at all -- the
--     same-conversation gate fails again, for a message she could never
--     have reached to begin with.
--   * a random uuid names no message anywhere.
-- Section 4 confirms app_private.in_conversation is as unreachable to a
-- client as every other app_private function (chat_test.sql section 4b):
-- USAGE on the schema is revoked outright, so its own membership clause can
-- never be isolated by calling it directly -- only through the insert path
-- above, where is_member(conversation_id) is already a sibling AND-ed
-- condition of the same policy.
begin;
select plan(42);

set local storage.allow_delete_query = 'true';

-- fixtures --------------------------------------------------------------
-- ann, bob   -- _c1
-- ann, carl  -- _c2 (ann is in both _c1 and _c2)
-- bob, carl  -- _c3 (ann is in neither)
-- ann, vic   -- _c4, kept apart so deleting vic's account cannot touch
--               anything else here
-- dee        -- allowlisted and active, in no conversation at all
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000af001', 'rf-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000af002', 'rf-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000af003', 'rf-carl@example.com', now(), '{"full_name":"Carl"}'),
  ('00000000-0000-0000-0000-0000000af004', 'rf-vic@example.com', now(), '{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-0000000af005', 'rf-dee@example.com', now(), '{"full_name":"Dee"}');
insert into app_private.allowlist(email) values
  ('rf-ann@example.com'), ('rf-bob@example.com'), ('rf-carl@example.com'),
  ('rf-vic@example.com'), ('rf-dee@example.com');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('af000000-0000-0000-0000-0000000af001', '00000000-0000-0000-0000-0000000af001', now(), now()),
  ('af000000-0000-0000-0000-0000000af002', '00000000-0000-0000-0000-0000000af002', now(), now()),
  ('af000000-0000-0000-0000-0000000af003', '00000000-0000-0000-0000-0000000af003', now(), now()),
  ('af000000-0000-0000-0000-0000000af004', '00000000-0000-0000-0000-0000000af004', now(), now()),
  ('af000000-0000-0000-0000-0000000af005', '00000000-0000-0000-0000-0000000af005', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select is(public.activate_session(), true, 'ann is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000af002', 'af000000-0000-0000-0000-0000000af002');
select is(public.activate_session(), true, 'bob is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000af003', 'af000000-0000-0000-0000-0000000af003');
select is(public.activate_session(), true, 'carl is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000af004', 'af000000-0000-0000-0000-0000000af004');
select is(public.activate_session(), true, 'vic is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000af005', 'af000000-0000-0000-0000-0000000af005');
select is(public.activate_session(), true, 'dee is active');
reset role;

select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000af002'), null, 'ann starts _c1 with bob');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000af003'), null, 'ann starts _c2 with carl');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000af004'), null, 'ann starts _c4 with vic');
reset role;
select test_as('00000000-0000-0000-0000-0000000af002', 'af000000-0000-0000-0000-0000000af002');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000af003'), null, 'bob starts _c3 with carl');
reset role;

create temp table _c1 as
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af001')
     and exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af002');
grant select on _c1 to authenticated;

create temp table _c2 as
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af001')
     and exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af003');
grant select on _c2 to authenticated;

create temp table _c3 as
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af002')
     and exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af003');
grant select on _c3 to authenticated;

create temp table _c4 as
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af001')
     and exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000af004');
grant select on _c4 to authenticated;

-- 1 grants: reply_to and forwarded join the insertable columns, nothing else
-- changes ----------------------------------------------------------------
select function_privs_are('app_private', 'in_conversation', array['uuid', 'uuid'], 'anon', '{}'::text[],
                          'anon holds no execute on in_conversation');
select function_privs_are('app_private', 'in_conversation', array['uuid', 'uuid'], 'authenticated',
                          array['EXECUTE'], 'authenticated may execute in_conversation');
select set_eq(
  $$select column_name::text from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'messages'
       and grantee = 'authenticated' and privilege_type = 'INSERT'$$,
  $$values ('conversation_id'),('sender_id'),('body'),('attachment_path'),('attachment_preview'),
           ('reply_to'),('forwarded')$$,
  'authenticated may insert exactly the original five columns plus reply_to and forwarded');
select is((select count(*) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'messages'
              and grantee = 'authenticated' and privilege_type = 'UPDATE'), 0::bigint,
          'still no UPDATE privilege on messages at all: a reply is fixed at send time');

-- 2 the happy path: a reply in the same conversation, and a plain forward --
select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'm1')$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af001'),
  'ann sends m1 in _c1');
reset role;
create temp table _m1 as select id from public.messages where conversation_id = (select id from _c1) and body = 'm1';
grant select on _m1 to authenticated;

select test_as('00000000-0000-0000-0000-0000000af002', 'af000000-0000-0000-0000-0000000af002');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'replying', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af002', (select id from _m1)),
  'bob replies to m1, in the same conversation');
reset role;
select is((select reply_to from public.messages where conversation_id = (select id from _c1) and body = 'replying'),
          (select id from _m1), 'the reply carries m1''s id');
select is((select forwarded from public.messages where body = 'm1'), false,
          'forwarded defaults to false');

select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, forwarded) values (%L, %L, 'fwd', true)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af001'),
  'forwarded is a plain insertable column');
reset role;
select is((select forwarded from public.messages where conversation_id = (select id from _c1) and body = 'fwd'),
          true, 'the row reads back marked forwarded');

-- 3 a reply may reference only a message of the SAME conversation ----------
select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'm-c2')$$,
         (select id from _c2), '00000000-0000-0000-0000-0000000af001'),
  'ann sends a message in _c2, a conversation she is also in');
reset role;
create temp table _mc2 as select id from public.messages where conversation_id = (select id from _c2) and body = 'm-c2';
grant select on _mc2 to authenticated;

select test_as('00000000-0000-0000-0000-0000000af003', 'af000000-0000-0000-0000-0000000af003');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'm-c3')$$,
         (select id from _c3), '00000000-0000-0000-0000-0000000af003'),
  'carl sends a message in _c3, a conversation ann never joined');
reset role;
create temp table _mc3 as select id from public.messages where conversation_id = (select id from _c3) and body = 'm-c3';
grant select on _mc3 to authenticated;

-- negative 1: a message from another conversation ann is ALSO a member of
select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'x', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af001', (select id from _mc2)),
  '42501', 'new row violates row-level security policy for table "messages"',
  'a message from another conversation ann is also in cannot be quoted');
reset role;
select is((select count(*) from public.messages where conversation_id = (select id from _c1) and body = 'x'),
          0::bigint, 'the refused reply was not inserted');

-- negative 2: a message from a conversation the sender is not in at all
select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'x', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af001', (select id from _mc3)),
  '42501', 'new row violates row-level security policy for table "messages"',
  'a message from a conversation the sender is not in cannot be quoted -- the identical error');
reset role;
select is((select count(*) from public.messages where conversation_id = (select id from _c1) and body = 'x'),
          0::bigint, 'the refused reply was not inserted');

-- negative 3: a random, non-existent message id
select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'x', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af001',
         '99999999-9999-9999-9999-999999999999'),
  '42501', 'new row violates row-level security policy for table "messages"',
  'a random uuid gives the identical error: no existence oracle');
reset role;
select is((select count(*) from public.messages where conversation_id = (select id from _c1) and body = 'x'),
          0::bigint, 'the refused reply was not inserted');

-- 4 app_private.in_conversation is unreachable directly, like every other
-- app_private function -- bob really is a member of _c1 and m1 really is
-- his to quote, so only the schema-usage revoke can be what stops this.
select test_as('00000000-0000-0000-0000-0000000af002', 'af000000-0000-0000-0000-0000000af002');
select throws_ok(
  format($$select app_private.in_conversation(%L, %L)$$, (select id from _m1), (select id from _c1)),
  '42501', null, 'app_private.in_conversation is unreachable from the client, membership notwithstanding');
reset role;

-- 5 replying to a deleted (tombstone) message is allowed --------------------
select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'to be deleted')$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af001'),
  'ann sends a message that will be deleted');
reset role;
create temp table _mdel as
  select id from public.messages where conversation_id = (select id from _c1) and body = 'to be deleted';
grant select on _mdel to authenticated;

select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select lives_ok(format($$select public.delete_message(%L)$$, (select id from _mdel)),
                'ann deletes it for everyone');
reset role;

select test_as('00000000-0000-0000-0000-0000000af002', 'af000000-0000-0000-0000-0000000af002');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'quoting a ghost', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af002', (select id from _mdel)),
  'bob may still reply to the now-deleted message: the row is a tombstone, not gone');
reset role;
select is((select reply_to from public.messages where body = 'quoting a ghost'), (select id from _mdel),
          'the reply carries the tombstoned message''s id');

-- 6 deleting the quoted message's sender sets reply_to null -----------------
select test_as('00000000-0000-0000-0000-0000000af004', 'af000000-0000-0000-0000-0000000af004');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'vic says hi')$$,
         (select id from _c4), '00000000-0000-0000-0000-0000000af004'),
  'vic sends a message in _c4');
reset role;
create temp table _mvic as
  select id from public.messages where conversation_id = (select id from _c4) and body = 'vic says hi';
grant select on _mvic to authenticated;

select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'ann replies to vic', %L)$$,
         (select id from _c4), '00000000-0000-0000-0000-0000000af001', (select id from _mvic)),
  'ann replies to vic, in the same conversation');
reset role;
create temp table _mreply as
  select id from public.messages where conversation_id = (select id from _c4) and body = 'ann replies to vic';
grant select on _mreply to authenticated;

select lives_ok(
  $$delete from auth.users where id = '00000000-0000-0000-0000-0000000af004'$$,
  'vic''s account is deleted');

select is((select count(*) from public.messages where id = (select id from _mvic)), 0::bigint,
          'the quoted message itself is gone: sender_id cascades');
select is((select count(*) from public.messages where id = (select id from _mreply)), 1::bigint,
          'ann''s reply message survives -- only its target vanished, not the reply itself');
select is((select reply_to from public.messages where id = (select id from _mreply)), null,
          'reply_to is cleared to null once the message it named no longer exists');

-- 7 the v0.10A send-policy gates this migration replaces still hold ---------
-- membership: dee is allowlisted and active but belongs to no conversation.
select test_as('00000000-0000-0000-0000-0000000af005', 'af000000-0000-0000-0000-0000000af005');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'intruder')$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af005'),
  '42501', null, 'a non-member still cannot send into a conversation she never joined');
reset role;
select is((select count(*) from public.messages where body = 'intruder'), 0::bigint,
          'the refused message was not inserted');

-- own folder: ann owns the object, but its folder is _c2's, not _c1's.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _c2)::text || '/spoof.jpg',
   '00000000-0000-0000-0000-0000000af001', '{"size":3}'::jsonb);
select test_as('00000000-0000-0000-0000-0000000af001', 'af000000-0000-0000-0000-0000000af001');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path) values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af001', (select id from _c2)::text || '/spoof.jpg'),
  '42501', null, 'an attachment outside the message''s own conversation folder is still refused');
reset role;

-- own photo: the object in _c1's own folder belongs to ann, not bob.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _c1)::text || '/not-bobs.jpg',
   '00000000-0000-0000-0000-0000000af001', '{"size":3}'::jsonb);
select test_as('00000000-0000-0000-0000-0000000af002', 'af000000-0000-0000-0000-0000000af002');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path) values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000af002', (select id from _c1)::text || '/not-bobs.jpg'),
  '42501', null, 'a photo someone else uploaded still cannot be claimed, even in the right folder');
reset role;

select * from finish();
rollback;
