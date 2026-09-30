begin;
select plan(106);

-- "What's new" (v0.27.0): release notes arrive as messages from SIS in a
-- read-only system chat, delivered by public.deliver_release_notes when a
-- member's app first starts a newer build. Written from the contract, not
-- from the migration:
--
-- 1. shape and grants: release_notes and release_note_delivery have RLS on,
--    no policy and nothing granted to clients; the RPC is callable by
--    authenticated only; conversations.system defaults to false.
-- 2. the system account: in auth.users with nothing to sign in with, no
--    profile, on no allowlist, and invisible to every member-facing lookup
--    (profiles_public, find_by_tag, profiles) -- even after it shares a
--    conversation with the member.
-- 3. delivery rules: first call -> only the latest NON-EMPTY note at or below
--    the installed build; later calls -> every non-empty note in
--    (last served, installed], oldest first, one message each, strictly
--    increasing timestamps, bodies trimmed; the served build is recorded even
--    when nothing was due and never goes down; the conversation is created
--    lazily and is one per member.
-- 4. argument and access errors: null / < 1 -> 22023, no app access -> 42501.
-- 5. read-only: a member who passes every other clause of messages_send is
--    refused only because the conversation is the system one; the group RPCs
--    refuse it; nothing can be deleted or flipped; mute works.
-- 6. no push: with a notify URL configured, a delivered note queues nothing,
--    while an ordinary message in the same state queues one request.
-- 7. privacy: another member sees neither the SIS chat, its messages, its
--    membership, nor anyone's delivery state, and no client reads the notes.
--
-- Concurrency (two devices, repeated calls at once) cannot be shown inside
-- one transaction; test/integration/release_notes_delivery_test.dart fires
-- parallel RPCs at the real stack for that.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Runs [stmt] as the current role; 'ok:<rows touched>' or 'err:<sqlstate>',
-- without aborting the surrounding test transaction.
create or replace function try_exec(stmt text) returns text
language plpgsql security invoker as $$
declare n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  return 'ok:' || n;
exception when others then
  return 'err:' || sqlstate;
end $$;
grant execute on function try_exec(text) to authenticated, anon;

-- 1 shape and grants ---------------------------------------------------------
select ok((select relrowsecurity from pg_class where oid = 'public.release_notes'::regclass),
          'release_notes has RLS on');
select is((select count(*) from pg_policies where schemaname = 'public' and tablename = 'release_notes'),
          0::bigint, 'release_notes has no policy');
select ok((select relrowsecurity from pg_class where oid = 'app_private.release_note_delivery'::regclass),
          'release_note_delivery has RLS on');
select is((select count(*) from pg_policies
            where schemaname = 'app_private' and tablename = 'release_note_delivery'),
          0::bigint, 'release_note_delivery has no policy');
select ok(not has_table_privilege('authenticated', 'public.release_notes', 'select,insert,update,delete'),
          'authenticated holds no privilege on release_notes');
select ok(not has_table_privilege('anon', 'public.release_notes', 'select,insert,update,delete'),
          'anon holds no privilege on release_notes');
select ok(not has_table_privilege('authenticated', 'app_private.release_note_delivery',
                                  'select,insert,update,delete'),
          'authenticated holds no privilege on release_note_delivery');
select ok(has_function_privilege('authenticated', 'public.deliver_release_notes(integer)', 'execute'),
          'authenticated may execute deliver_release_notes');
select ok(not has_function_privilege('anon', 'public.deliver_release_notes(integer)', 'execute'),
          'anon may not execute deliver_release_notes');
select is((select pg_get_function_result('public.deliver_release_notes(integer)'::regprocedure)),
          'integer', 'deliver_release_notes returns integer');
select col_not_null('public', 'conversations', 'system', 'conversations.system is not null');
select col_default_is('public', 'conversations', 'system', 'false', 'conversations.system defaults to false');
select throws_ok($$insert into public.release_notes(build, note) values (0, 'x')$$, '23514', null,
                 'a build below 1 is refused');
select throws_ok($$insert into public.release_notes(build, note) values (99999, repeat('x', 4001))$$,
                 '23514', null, 'a note over 4000 characters is refused');
select lives_ok($$insert into public.release_notes(build, note) values (99999, repeat('x', 4000))$$,
                'a note of exactly 4000 characters is accepted');
select is((select note from public.release_notes where build = 99998), null,
          'control: nothing at 99998');
insert into public.release_notes(build) values (99998);
select is((select note from public.release_notes where build = 99998), '',
          'a note defaults to empty text');

-- the seeds
select is((select count(*) from public.release_notes
            where build in (177, 178, 179) and btrim(note) <> ''), 3::bigint,
          'builds 177, 178 and 179 are seeded with non-empty notes');

-- 2 the system account -------------------------------------------------------
select is((select count(*) from auth.users where id = '00000000-0000-0000-0000-00000000515e'),
          1::bigint, 'the system account exists in auth.users');
select is((select concat_ws('|', coalesce(email, '<null>'), coalesce(phone, '<null>'),
                            coalesce(nullif(encrypted_password, ''), '<none>'))
             from auth.users where id = '00000000-0000-0000-0000-00000000515e'),
          '<null>|<null>|<none>', 'it has no email, no phone and no password: nothing to sign in with');
select is((select count(*) from auth.identities where user_id = '00000000-0000-0000-0000-00000000515e'),
          0::bigint, 'it has no identity (no Google, no provider sign-in)');
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-00000000515e'),
          0::bigint, 'it has no profile row');
select ok(not app_private.is_allowed('00000000-0000-0000-0000-00000000515e'),
          'it is on no allowlist');

-- fixtures -------------------------------------------------------------------
-- ann   allowlisted, active           the subject
-- bo    allowlisted, active           another member: privacy, ordinary chat
-- cleo  allowlisted, active           first call below every note
-- dee   allowlisted, active, THEN DELISTED  fails only has_app_access
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000a2701', 'ann@wn.test',  now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000a2702', 'bo@wn.test',   now(), '{"full_name":"Bo"}'),
  ('00000000-0000-0000-0000-0000000a2703', 'cleo@wn.test', now(), '{"full_name":"Cleo"}'),
  ('00000000-0000-0000-0000-0000000a2704', 'dee@wn.test',  now(), '{"full_name":"Dee"}');
insert into app_private.allowlist(email) values
  ('ann@wn.test'), ('bo@wn.test'), ('cleo@wn.test'), ('dee@wn.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a2700000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000a2701', now(), now()),
  ('a2700000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000a2702', now(), now()),
  ('a2700000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000a2703', now(), now()),
  ('a2700000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000a2704', now(), now());

create function as_ann()  returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a2701', 'a2700000-0000-0000-0000-000000000001') $$;
create function as_bo()   returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a2702', 'a2700000-0000-0000-0000-000000000002') $$;
create function as_cleo() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a2703', 'a2700000-0000-0000-0000-000000000003') $$;
create function as_dee()  returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a2704', 'a2700000-0000-0000-0000-000000000004') $$;
grant execute on function as_ann(), as_bo(), as_cleo(), as_dee() to authenticated;

select as_ann();  select is(public.activate_session(), true, 'ann is active');  reset role;
select as_bo();   select is(public.activate_session(), true, 'bo is active');   reset role;
select as_cleo(); select is(public.activate_session(), true, 'cleo is active'); reset role;
select as_dee();  select is(public.activate_session(), true, 'dee is active');  reset role;

-- An ordinary ann-bo chat, for the controls.
insert into public.conversations(id) values ('c2700000-0000-0000-0000-000000000001');
insert into public.conversation_members(conversation_id, user_id) values
  ('c2700000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000a2701'),
  ('c2700000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000a2702');

-- Notes under test only: the seeds would make "latest" depend on them.
delete from public.release_notes;
insert into public.release_notes(build, note) values
  (100, 'first'),
  (101, '     '),        -- blank: must never be delivered
  (102, '  second  '),
  (103, ''),
  (104, 'third');

create view sis_msgs as
  select m.conversation_id, m.sender_id, m.body, m.created_at, c.direct_key, c.system
    from public.messages m join public.conversations c on c.id = m.conversation_id
   where c.system;

-- 4 argument and access errors -------------------------------------------------
select as_ann();
select throws_ok($$select public.deliver_release_notes(null)$$, '22023', null,
                 'a null build is refused with 22023');
select throws_ok($$select public.deliver_release_notes(0)$$, '22023', null,
                 'build 0 is refused with 22023');
select throws_ok($$select public.deliver_release_notes(-5)$$, '22023', null,
                 'a negative build is refused with 22023');
reset role;
select is((select count(*) from app_private.release_note_delivery
            where user_id = '00000000-0000-0000-0000-0000000a2701'), 0::bigint,
          'a refused call records nothing');

delete from app_private.allowlist where email = 'dee@wn.test';
select as_dee();
select throws_ok($$select public.deliver_release_notes(104)$$, '42501', null,
                 'a member without app access is refused with 42501');
reset role;
select is((select count(*) from app_private.release_note_delivery
            where user_id = '00000000-0000-0000-0000-0000000a2704'), 0::bigint,
          'and nothing is recorded for her');

set local role anon;
select throws_ok($$select public.deliver_release_notes(104)$$, '42501', null,
                 'anon cannot call it at all');
reset role;

-- 3 first delivery: latest non-empty only ------------------------------------
select as_ann();
select is(public.deliver_release_notes(102), 1, 'ann first call at 102 adds one message');
reset role;
select is((select string_agg(body, '|') from sis_msgs
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'),
          'second', 'only the latest note (102), trimmed -- no backlog of 100');
select is((select sender_id from sis_msgs
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2701' limit 1),
          '00000000-0000-0000-0000-00000000515e'::uuid, 'sent by the system account');
select is((select last_build from app_private.release_note_delivery
            where user_id = '00000000-0000-0000-0000-0000000a2701'), 102,
          'ann is recorded as served 102');

-- bo's first call lands on a blank note: the latest NON-empty one wins.
select as_bo();
select is(public.deliver_release_notes(101), 1, 'bo first call at 101 adds one message');
reset role;
select is((select string_agg(body, '|') from sis_msgs
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2702'),
          'first', 'the blank 101 is skipped; 100 is delivered');

-- cleo's first call is below every note: nothing, no chat, but recorded.
select as_cleo();
select is(public.deliver_release_notes(99), 0, 'cleo first call at 99 adds nothing');
reset role;
select is((select count(*) from public.conversations
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2703'), 0::bigint,
          'no system chat is created when nothing is delivered');
select is((select last_build from app_private.release_note_delivery
            where user_id = '00000000-0000-0000-0000-0000000a2703'), 99,
          'the served build is recorded even though nothing was due');
select as_cleo();
select is(public.deliver_release_notes(100), 1,
          'cleo then at 100: 100 is in (99, 100] -- delivered, not treated as a first call');
reset role;
select is((select count(*) from public.conversations
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2703' and system), 1::bigint,
          'the first delivered message creates her system chat');

-- 1 (A) repeat and lower builds do nothing ---------------------------------------
select as_ann();
select is(public.deliver_release_notes(102), 0, 'ann again at 102: nothing');
select is(public.deliver_release_notes(101), 0, 'ann at an older build 101: nothing');
select is(public.deliver_release_notes(100), 0, 'ann at 100: nothing (100 predates her first call)');
reset role;
select is((select count(*) from sis_msgs
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'), 1::bigint,
          'ann still has exactly one note');
select is((select last_build from app_private.release_note_delivery
            where user_id = '00000000-0000-0000-0000-0000000a2701'), 102,
          'the served build did not go down');

-- later deliveries: every non-empty note in the window, oldest first
insert into public.release_notes(build, note) values (105, 'fifth'), (106, 'sixth');
select as_ann();
select is(public.deliver_release_notes(106), 3, 'ann at 106: 104, 105, 106 (103 is empty)');
reset role;
select is((select string_agg(body, '|' order by created_at) from sis_msgs
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'),
          'second|third|fifth|sixth', 'each note its own message, oldest first');
select is((select count(distinct created_at) from sis_msgs
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'), 4::bigint,
          'every message has its own timestamp');
select is((select count(*) from public.conversations
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'), 1::bigint,
          'still one system chat for ann');
select is((select count(*) from public.conversations c
             join public.conversation_members cm on cm.conversation_id = c.id
            where c.system and cm.user_id = '00000000-0000-0000-0000-0000000a2701'), 1::bigint,
          'ann is a member of exactly one system chat');

-- nothing due, but a newer build: recorded; a later note at or below it is past
select as_ann();
select is(public.deliver_release_notes(110), 0, 'ann at 110 with no note in (106, 110]: nothing');
reset role;
select is((select last_build from app_private.release_note_delivery
            where user_id = '00000000-0000-0000-0000-0000000a2701'), 110,
          'yet 110 is recorded');
insert into public.release_notes(build, note) values (108, 'late edit'), (111, '  eleventh ');
select as_ann();
select is(public.deliver_release_notes(111), 1, 'ann at 111: only 111 -- 108 is at or below 110');
reset role;
select is((select body from sis_msgs where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'
            order by created_at desc limit 1), 'eleventh', 'the newest note, trimmed');
select is((select count(*) from sis_msgs where body = 'late edit'), 0::bigint,
          'the late note at 108 was never delivered to anyone');

select is((select system from public.conversations
            where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'), true,
          'the system chat is flagged system');
select is((select count(*) from public.conversations where system and direct_key is distinct from
             'system:' || (select cm.user_id::text from public.conversation_members cm
                            where cm.conversation_id = conversations.id
                              and cm.user_id <> '00000000-0000-0000-0000-00000000515e' limit 1)),
          0::bigint, 'every system chat is keyed system:<its member>');
select is((select count(*) from public.conversations
            where not system and direct_key like 'system:%'), 0::bigint,
          'no ordinary chat carries a system key');

-- 5 read-only ----------------------------------------------------------------
create temp table sys as
  select id from public.conversations where direct_key = 'system:00000000-0000-0000-0000-0000000a2701';
grant select on sys to authenticated;

select as_ann();
select is(try_exec($$insert into public.messages(conversation_id, sender_id, body)
                     values ('c2700000-0000-0000-0000-000000000001', auth.uid(), 'control')$$),
          'ok:1', 'control: ann may post in her ordinary chat');
select is((select count(*) from public.conversations where id = (select id from sys)), 1::bigint,
          'control: ann sees her system chat (she is its member)');
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body)
                            values (%L, auth.uid(), 'let me in')$$, (select id from sys))),
          'err:42501', 'ann may not post into the system chat (messages_send)');
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body)
                            values (%L, '00000000-0000-0000-0000-00000000515e', 'as SIS')$$,
                          (select id from sys))),
          'err:42501', 'nor post as the system account');
select is(try_exec(format($$select public.leave_group(%L)$$, (select id from sys))),
          'err:42501', 'leave_group refuses the system chat with 42501');
select is(try_exec(format($$select public.add_members(%L, array[%L]::uuid[], false)$$,
                          (select id from sys), '00000000-0000-0000-0000-0000000a2702')),
          'err:42501', 'add_members refuses the system chat with 42501');
select is(try_exec(format($$select public.remove_member(%L, %L)$$,
                          (select id from sys), '00000000-0000-0000-0000-00000000515e')),
          'err:42501', 'remove_member refuses the system chat with 42501');
select is(try_exec(format($$select public.set_admin(%L, %L, true)$$,
                          (select id from sys), '00000000-0000-0000-0000-0000000a2701')),
          'err:42501', 'set_admin refuses the system chat with 42501');
select doesnt_match(try_exec(format($$delete from public.messages where conversation_id = %L$$, (select id from sys))),
            '^ok:[1-9]', 'ann cannot delete the notes');
select doesnt_match(try_exec(format($$delete from public.conversation_members where conversation_id = %L$$,
                            (select id from sys))),
            '^ok:[1-9]', 'ann cannot delete her membership');
select doesnt_match(try_exec(format($$delete from public.conversations where id = %L$$, (select id from sys))),
            '^ok:[1-9]', 'ann cannot delete the system chat');
select doesnt_match(try_exec(format($$update public.conversations set system = false where id = %L$$,
                            (select id from sys))),
            '^ok:[1-9]', 'ann cannot turn the system flag off');
select matches(try_exec($$insert into public.conversations(direct_key, system) values ('system:x', true)$$),
            '^err:', 'ann cannot create a system chat of her own');
select is(try_exec(format($$insert into public.notification_mutes(kind, target) values ('conversation', %L)$$,
                          (select id from sys))),
          'ok:1', 'ann can mute her system chat');
reset role;
select is((select count(*) from sis_msgs where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'),
          5::bigint, 'all five notes are still there');
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from sys)
              and user_id = '00000000-0000-0000-0000-0000000a2701'), 1::bigint,
          'ann is still its member');
select is((select system from public.conversations where id = (select id from sys)), true,
          'and it is still a system chat');
select is((select count(*) from pg_policies
            where schemaname = 'public'
              and tablename in ('conversations', 'conversation_members', 'messages')
              and cmd in ('DELETE', 'ALL')), 0::bigint,
          'no delete policy on conversations, conversation_members or messages');

-- 7 privacy --------------------------------------------------------------------
select as_bo();
select is((select count(*) from public.conversations where id = (select id from sys)), 0::bigint,
          'bo cannot see ann''s system chat');
select is((select count(*) from public.messages where conversation_id = (select id from sys)), 0::bigint,
          'nor its messages');
select is((select count(*) from public.conversation_members where conversation_id = (select id from sys)),
          0::bigint, 'nor its membership');
select is((select count(*) from public.conversation_previews where conversation_id = (select id from sys)),
          0::bigint, 'nor its preview');
select is((select count(*) from public.unread_counts() where conversation_id = (select id from sys)),
          0::bigint, 'nor its unread count');
select is(try_exec(format($$insert into public.notification_mutes(kind, target) values ('conversation', %L)$$,
                          (select id from sys))),
          'err:42501', 'bo cannot mute ann''s system chat');
select is(try_exec($$select * from app_private.release_note_delivery$$), 'err:42501',
          'bo cannot read delivery state');
select is(try_exec($$select * from public.release_notes$$), 'err:42501',
          'a member cannot read release_notes');
select is(try_exec($$insert into public.release_notes(build, note) values (500, 'mine')$$), 'err:42501',
          'a member cannot write release_notes');
select is(try_exec($$update public.release_notes set note = 'x'$$), 'err:42501',
          'a member cannot edit release_notes');
reset role;
set local role anon;
select is(try_exec($$select * from public.release_notes$$), 'err:42501', 'anon cannot read release_notes');
reset role;

-- the system account stays out of every member-facing lookup, even now that
-- it shares a conversation with ann
select as_ann();
select is((select count(*) from public.unread_counts() where conversation_id = (select id from sys)),
          1::bigint, 'ann''s unread counts include her system chat');
select is((select count(*) from public.profiles_public()
            where user_id = '00000000-0000-0000-0000-00000000515e'), 0::bigint,
          'profiles_public never lists the system account');
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-00000000515e'),
          0::bigint, 'profiles never shows the system account');
select is((select count(*) from (select * from public.find_by_tag('sis')
                                  union all select * from public.find_by_tag('system')
                                  union all select * from public.find_by_tag('')) f
            where user_id = '00000000-0000-0000-0000-00000000515e'), 0::bigint,
          'find_by_tag never finds the system account');
select isnt(try_exec($$select public.start_direct_conversation('00000000-0000-0000-0000-00000000515e')$$),
            'ok:1', 'ann cannot open a 1:1 chat with the system account');
reset role;

-- 6 no push for a note -----------------------------------------------------------
select isnt(vault.create_secret('https://wn-test.local/hook', 'notify_on_message_url'), null, 'a notify URL is configured');
select is((select count(*) from net.http_request_queue), 0::bigint, 'queue starts empty');
insert into public.release_notes(build, note) values (112, 'no push please');
select as_ann();
select is(public.deliver_release_notes(112), 1, 'ann receives 112');
reset role;
select is((select count(*) from net.http_request_queue), 0::bigint,
          'a delivered note queues no push');
select as_bo();
select is(try_exec($$insert into public.messages(conversation_id, sender_id, body)
                     values ('c2700000-0000-0000-0000-000000000001', auth.uid(), 'ping')$$),
          'ok:1', 'control: bo posts in the ordinary chat');
reset role;
select is((select count(*) from net.http_request_queue), 1::bigint,
          'control: the ordinary message queues exactly one push, so the trigger is live');

-- 8 whitespace beyond spaces -------------------------------------------------------
-- The owner edits notes in the dashboard, where a stray newline is easy to
-- leave. A note that is only newlines and tabs is empty to a member, and a
-- body must not carry them at its ends: SIS would post a blank bubble.
insert into public.release_notes(build, note) values (113, E'\n\t\n'), (114, E'\nfourteen\n');
select as_ann();
select is(public.deliver_release_notes(113), 0, 'a note of only newlines and tabs delivers nothing');
select is(public.deliver_release_notes(114), 1, 'ann receives 114');
reset role;
select is((select body from sis_msgs where direct_key = 'system:00000000-0000-0000-0000-0000000a2701'
            order by created_at desc limit 1), 'fourteen', 'newlines around a note are trimmed');

select * from finish();
rollback;
