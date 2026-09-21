begin;
select plan(20);

-- fixtures: two allowlisted members (ann, bob) and one stranger -------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cat@example.com', now(), '{"full_name":"Cat"}');
insert into app_private.allowlist(email) values ('ann@example.com'), ('bob@example.com');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-0000000000a1', now(), now()),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '00000000-0000-0000-0000-0000000000b1', now(), now()),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', '00000000-0000-0000-0000-0000000000c1', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- ann and bob each claim their device
select test_as('00000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select is(public.activate_session(), true, 'ann is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000000b1', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select is(public.activate_session(), true, 'bob is active');
reset role;

-- 1 anonymous reaches nothing ----------------------------------------------
set local role anon;
select throws_ok($$select count(*) from public.messages$$, '42501', null, 'anon cannot read messages');
select throws_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000000000b1')$$,
                 'permission denied for function start_direct_conversation', 'anon cannot start a conversation');
reset role;

-- 2 ann starts a chat with bob ---------------------------------------------
select test_as('00000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select lives_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000000000b1')$$,
                'ann starts a conversation with bob');
select is((select count(*) from public.conversations), 1::bigint, 'ann sees her conversation');
select is((select count(*) from public.conversation_members), 2::bigint, 'both members are recorded');
-- starting again returns the SAME conversation, never a second one
select is(public.start_direct_conversation('00000000-0000-0000-0000-0000000000b1'),
          (select id from public.conversations), 'starting again reuses the same conversation');
select is((select count(*) from public.conversations), 1::bigint, 'no duplicate 1:1 conversation');
-- a chat with a stranger, or with yourself, is refused
select throws_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000000000c1')$$,
                 '42501', null, 'cannot start a conversation with an unallowlisted user');
select throws_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000000000a1')$$,
                 '42501', null, 'cannot start a conversation with yourself');
-- ann sends, and cannot forge a sender
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from public.conversations), '00000000-0000-0000-0000-0000000000a1', 'hello bob');
select is((select body from public.messages), 'hello bob', 'ann reads back her message');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'forged')$$,
         (select id from public.conversations), '00000000-0000-0000-0000-0000000000b1'),
  '42501', null, 'cannot send a message as somebody else');
select throws_ok($$update public.messages set body = 'edited'$$, '42501', null, 'messages cannot be edited');
select throws_ok($$delete from public.messages$$, '42501', null, 'messages cannot be deleted');
reset role;
-- captured with RLS bypassed, so the non-member below attacks a real id
create temp table _conv as select id from public.conversations;
grant select on _conv to authenticated;

-- 3 bob, the other member, sees the conversation and the message ------------
select test_as('00000000-0000-0000-0000-0000000000b1', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select is((select count(*) from public.messages), 1::bigint, 'bob reads the message sent to him');
reset role;

-- 4 the stranger sees nothing, even by guessing the conversation id ---------
select test_as('00000000-0000-0000-0000-0000000000c1', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
select is((select count(*) from public.messages), 0::bigint, 'a non-member reads no messages');
select is((select count(*) from public.conversations), 0::bigint, 'a non-member sees no conversations');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'intruding')$$,
         (select id from _conv), '00000000-0000-0000-0000-0000000000c1'),
  '42501', null, 'a non-member cannot post into a conversation');
reset role;

-- 5 losing the active session closes chat too -------------------------------
delete from auth.sessions where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select test_as('00000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select is((select count(*) from public.messages), 0::bigint, 'a revoked session loses chat access');
reset role;

select * from finish();
rollback;
