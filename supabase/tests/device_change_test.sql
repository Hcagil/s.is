begin;
select plan(16);

-- Changing the phone, at the SQL level.
--
-- The product rule: a member who moves to a new phone sees their whole
-- history, and the phone they left loses access at the same moment.
--
-- What only this level can set up is TIME. A real second sign-in is always
-- newer than the first, so the integration suite cannot produce a session that
-- is older than, or exactly as old as, the active one -- and `activate_session`
-- turns on precisely that comparison. It also cannot write history that
-- predates a session; here the messages are a hundred minutes older than the
-- phone that reads them.
--
-- The replaced phone here is allowlisted, confirmed, still a member of both
-- conversations, and its row in auth.sessions is still alive. The only thing
-- it fails is the active-session match inside has_app_access() -- so every
-- refusal below belongs to that clause and to nothing else.

-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000e5', 'erin@example.com',  now(), '{"full_name":"Erin"}'),
  ('00000000-0000-0000-0000-0000000000f6', 'frank@example.com', now(), '{"full_name":"Frank"}'),
  ('00000000-0000-0000-0000-0000000000a7', 'grace@example.com', now(), '{"full_name":"Grace"}');
insert into app_private.allowlist(email) values
  ('erin@example.com'), ('frank@example.com'), ('grace@example.com');

-- now() is the transaction timestamp, so the new phone and the tie-break phone
-- are created at exactly the same instant, and the old phone two hours earlier.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('e5e5e5e5-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-0000000000e5', now() - interval '2 hours', now()),
  ('e5e5e5e5-0000-0000-0000-000000000002'::uuid, '00000000-0000-0000-0000-0000000000e5', now(), now()),
  ('e5e5e5e5-0000-0000-0000-000000000003'::uuid, '00000000-0000-0000-0000-0000000000e5', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- 1 the old phone is the active device and chats with two people ------------
select test_as('00000000-0000-0000-0000-0000000000e5', 'e5e5e5e5-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'the first phone claims the device');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000000f6'), null, 'erin chats with frank');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000000a7'), null, 'erin chats with grace');
reset role;

-- History, back-dated to before the new phone's session exists. Written here
-- with RLS bypassed only so created_at can be chosen; a client cannot.
create temp table _mine as
  select c.id from public.conversations c
   join public.conversation_members m
     on m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000000e5';
grant select on _mine to authenticated;

insert into public.messages (conversation_id, sender_id, body, created_at)
select m.conversation_id, s.sender, s.body, now() - interval '100 minutes'
  from (values
    ('00000000-0000-0000-0000-0000000000f6'::uuid, '00000000-0000-0000-0000-0000000000e5'::uuid, 'erin to frank, first'),
    ('00000000-0000-0000-0000-0000000000f6'::uuid, '00000000-0000-0000-0000-0000000000e5'::uuid, 'erin to frank, second'),
    ('00000000-0000-0000-0000-0000000000f6'::uuid, '00000000-0000-0000-0000-0000000000f6'::uuid, 'frank to erin'),
    ('00000000-0000-0000-0000-0000000000a7'::uuid, '00000000-0000-0000-0000-0000000000e5'::uuid, 'erin to grace')
  ) as s(other, sender, body)
  join public.conversation_members m
    on m.user_id = s.other and m.conversation_id in (select id from _mine);

-- 2 the new phone takes over and reads everything ---------------------------
select test_as('00000000-0000-0000-0000-0000000000e5', 'e5e5e5e5-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'the new phone takes the device over');
select is((select count(*) from public.messages where conversation_id in (select id from _mine)),
          4::bigint, 'the new phone reads history written before its session existed');
select is((select count(*) from public.messages
            where conversation_id in (select id from _mine)
              and sender_id = '00000000-0000-0000-0000-0000000000f6'),
          1::bigint, 'including the messages it did not send');
select is((select count(*) from public.conversations where id in (select id from _mine)),
          2::bigint, 'every conversation the member belongs to, not just the latest');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'from the new phone')$$,
         (select id from _mine limit 1), '00000000-0000-0000-0000-0000000000e5'),
  'the new phone can send');
reset role;

-- 3 the old phone is still a live, allowlisted member -- and still refused ---
-- These two assertions are what make the refusals below mean something: the
-- fixture fails the active-session clause of has_app_access() and no other.
select is((select count(*) from auth.sessions where id = 'e5e5e5e5-0000-0000-0000-000000000001'),
          1::bigint, 'the old session was never revoked');
select is((select count(*) from public.conversation_members
            where user_id = '00000000-0000-0000-0000-0000000000e5'),
          2::bigint, 'the old phone''s user is still a member of both conversations');

select test_as('00000000-0000-0000-0000-0000000000e5', 'e5e5e5e5-0000-0000-0000-000000000001');
select is((select count(*) from public.messages where conversation_id in (select id from _mine)),
          0::bigint, 'the replaced phone reads no messages');
select is((select count(*) from public.conversations where id in (select id from _mine)),
          0::bigint, 'the replaced phone sees no conversations');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'from the old phone')$$,
         (select id from _mine limit 1), '00000000-0000-0000-0000-0000000000e5'),
  '42501', null, 'the replaced phone cannot send');
-- A token refresh keeps the session id, so this is exactly what a refreshed
-- old phone can attempt.
select is(public.activate_session(), false, 'the older session cannot take the device back');
reset role;
select is((select session_id from app_private.active_sessions
            where user_id = '00000000-0000-0000-0000-0000000000e5'),
          'e5e5e5e5-0000-0000-0000-000000000002'::uuid,
          'the failed attempt left the new phone active');

-- 4 the boundary: same instant is not later ---------------------------------
-- Two devices signing in within the same timestamp tick: the first claim wins,
-- rather than the two of them trading the device back and forth.
select test_as('00000000-0000-0000-0000-0000000000e5', 'e5e5e5e5-0000-0000-0000-000000000003');
select is(public.activate_session(), false, 'a session created at the same instant does not take over');
reset role;

select * from finish();
rollback;
