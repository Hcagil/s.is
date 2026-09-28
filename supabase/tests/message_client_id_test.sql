-- v0.21.3: a member may propose a message's id
-- (20260928170000_message_client_id.sql), so a retried send is the same row,
-- never a second one.
--
-- What the grant must NOT open up:
--   * a chosen id that is already taken is a primary-key conflict (23505)
--     that changes nothing, whoever's row it is;
--   * it never lets anyone write where they could not write before -- a
--     non-member, anon, a caller who lost the allowlist, a stale or revoked
--     session all get the same 42501 as before, and never 23505 (which would
--     tell them the id exists);
--   * it is an INSERT grant only: no upsert, no rewriting an id;
--   * created_at is still the server's.
--
-- Every refusal below uses an id that IS taken (_x1, ann's row in _ab), so
-- a check that ran after the primary-key index would answer 23505 instead.
-- Each negative subject fails exactly one gate:
--   * carl is allowlisted and active, only not a member of _ab;
--   * eve is a member of _eb, allowlisted, on a session made stale by her
--     own newer one -- the same insert on the newer session passes;
--   * fay is a member of _fb and active, only removed from the allowlist --
--     the same insert passed while she was on it;
--   * ann is a member of _ab, allowlisted, only her session revoked.
begin;
select plan(35);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000c1d01', 'cid-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000c1d02', 'cid-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000c1d03', 'cid-carl@example.com', now(), '{"full_name":"Carl"}'),
  ('00000000-0000-0000-0000-0000000c1d04', 'cid-eve@example.com', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-0000000c1d05', 'cid-fay@example.com', now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-0000000c1d06', 'cid-cat@example.com', now(), '{"full_name":"Cat"}');
insert into app_private.allowlist(email) values
  ('cid-ann@example.com'), ('cid-bob@example.com'), ('cid-carl@example.com'),
  ('cid-eve@example.com'), ('cid-fay@example.com');
-- v0.22.0: starting a conversation needs reach. Seed exactly the pairs the
-- fixtures start, as tag finds (not contacts, which would also open rows and
-- pictures and hide regressions elsewhere).
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000c1d01', '00000000-0000-0000-0000-0000000c1d02'),
  ('00000000-0000-0000-0000-0000000c1d02', '00000000-0000-0000-0000-0000000c1d03'),
  ('00000000-0000-0000-0000-0000000c1d04', '00000000-0000-0000-0000-0000000c1d02'),
  ('00000000-0000-0000-0000-0000000c1d05', '00000000-0000-0000-0000-0000000c1d02');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('c1d00000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000c1d01', now(), now()),
  ('c1d00000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000c1d02', now(), now()),
  ('c1d00000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000c1d03', now(), now()),
  ('c1d00000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000c1d04', now() - interval '2 hours', now()),
  ('c1d00000-0000-0000-0000-000000000044', '00000000-0000-0000-0000-0000000c1d04', now() - interval '1 hour', now()),
  ('c1d00000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000c1d05', now(), now()),
  ('c1d00000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000c1d06', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- everyone but cat (not allowlisted) claims a device; eve's first session
-- is the active one for now
select test_as('00000000-0000-0000-0000-0000000c1d01', 'c1d00000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'claims a device');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000c1d02'), null, 'starts a conversation');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1d02', 'c1d00000-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'claims a device');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000c1d03'), null, 'starts a conversation');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1d03', 'c1d00000-0000-0000-0000-000000000003');
select is(public.activate_session(), true, 'claims a device');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1d04', 'c1d00000-0000-0000-0000-000000000004');
select is(public.activate_session(), true, 'claims a device');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000c1d02'), null, 'starts a conversation');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1d05', 'c1d00000-0000-0000-0000-000000000005');
select is(public.activate_session(), true, 'claims a device');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000c1d02'), null, 'starts a conversation');
reset role;

create temp table _pair(name text, a uuid, b uuid);
insert into _pair values
  ('ab', '00000000-0000-0000-0000-0000000c1d01', '00000000-0000-0000-0000-0000000c1d02'),
  ('bc', '00000000-0000-0000-0000-0000000c1d02', '00000000-0000-0000-0000-0000000c1d03'),
  ('eb', '00000000-0000-0000-0000-0000000c1d04', '00000000-0000-0000-0000-0000000c1d02'),
  ('fb', '00000000-0000-0000-0000-0000000c1d05', '00000000-0000-0000-0000-0000000c1d02');
create temp table _conv as
  select p.name, c.id from _pair p, public.conversations c
   where exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = p.a)
     and exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = p.b)
     and (select count(*) from public.conversation_members m where m.conversation_id = c.id) = 2;
grant select on _conv to authenticated, anon;
select is((select count(*)::int from _conv), 4, 'fixtures: four conversations');

-- the ids under test
create temp table _id(name text primary key, id uuid);
insert into _id values
  ('x1', 'c1d0aaaa-0000-4000-8000-000000000001'),  -- ann's, in _ab
  ('y1', 'c1d0bbbb-0000-4000-8000-000000000001'),  -- bob's, in _bc (ann is not in it)
  ('fresh', 'c1d0cccc-0000-4000-8000-000000000001'),
  ('eve2', 'c1d0eeee-0000-4000-8000-000000000002'),
  ('fay1', 'c1d0ffff-0000-4000-8000-000000000001');
grant select on _id to authenticated, anon;

-- 1 a member may choose a fresh id; the server keeps created_at -------------
select test_as('00000000-0000-0000-0000-0000000c1d01', 'c1d00000-0000-0000-0000-000000000001');
select lives_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'x1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'first')$$,
  'a member may insert a message with an id she chose');
select is((select created_at from public.messages where id = (select id from _id where name = 'x1')),
          now(), 'created_at is still set by the server');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1d02', 'c1d00000-0000-0000-0000-000000000002');
select lives_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'y1'), (select id from _conv where name = 'bc'),
            '00000000-0000-0000-0000-0000000c1d02', 'bob in bc')$$,
  'bob writes y1 into _bc');
reset role;

-- 2 a taken id is a conflict that changes nothing -----------------------------
select test_as('00000000-0000-0000-0000-0000000c1d01', 'c1d00000-0000-0000-0000-000000000001');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'x1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'second')$$,
  '23505', null, 'her own id again, in her own conversation: a conflict');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'y1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'stealing')$$,
  '23505', null, 'another conversation''s id, into her own conversation: a conflict');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'y1'), (select id from _conv where name = 'bc'),
            '00000000-0000-0000-0000-0000000c1d01', 'intruding')$$,
  '42501', null, 'that id into the conversation she is not in: refused, not a conflict');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'fresh'), (select id from _conv where name = 'bc'),
            '00000000-0000-0000-0000-0000000c1d01', 'intruding')$$,
  '42501', null, 'a fresh id into a conversation she is not in: refused');
-- 3 insert only: no upsert, no rewriting an id -------------------------------
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'x1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'upserted')
    on conflict (id) do update set body = excluded.body$$,
  '42501', null, 'an upsert onto her own message is refused');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'y1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'upserted')
    on conflict (id) do update set body = excluded.body$$,
  '42501', null, 'an upsert onto someone else''s message is refused');
select throws_ok(
  $$update public.messages set id = (select id from _id where name = 'fresh')
     where id = (select id from _id where name = 'x1')$$,
  '42501', null, 'an id cannot be rewritten');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ('not-a-uuid', (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'bad id')$$,
  '22P02', null, 'an id that is not a UUID is refused');
reset role;
select is((select body from public.messages where id = (select id from _id where name = 'x1')),
          'first', 'x1 is unchanged');
select is((select conversation_id from public.messages where id = (select id from _id where name = 'y1')),
          (select id from _conv where name = 'bc'), 'y1 is still in _bc');
select is((select body from public.messages where id = (select id from _id where name = 'y1')),
          'bob in bc', 'y1 is unchanged');
select is((select count(*)::int from public.messages where id = (select id from _id where name = 'fresh')),
          0, 'no row was stored under the fresh id');

-- 4 a member who is only not in the conversation ------------------------------
select test_as('00000000-0000-0000-0000-0000000c1d03', 'c1d00000-0000-0000-0000-000000000003');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'x1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d03', 'probe')$$,
  '42501', null, 'an active non-member probing a taken id gets 42501, never 23505');
reset role;

-- 5 anon, and a stranger who was never allowlisted ------------------------------
set local role anon;
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'x1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'probe')$$,
  '42501', null, 'anon probing a taken id gets 42501, never 23505');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1d06', 'c1d00000-0000-0000-0000-000000000006');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'x1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d06', 'probe')$$,
  '42501', null, 'a never-allowlisted user probing a taken id gets 42501, never 23505');
reset role;

-- 6 a stale session: eve moves to a second device -------------------------------
select test_as('00000000-0000-0000-0000-0000000c1d04', 'c1d00000-0000-0000-0000-000000000044');
select is(public.activate_session(), true, 'eve claims her second device');
select lives_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'eve2'), (select id from _conv where name = 'eb'),
            '00000000-0000-0000-0000-0000000c1d04', 'from the new phone')$$,
  'control: eve, on her active session, may insert with a chosen id');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1d04', 'c1d00000-0000-0000-0000-000000000004');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'eve2'), (select id from _conv where name = 'eb'),
            '00000000-0000-0000-0000-0000000c1d04', 'from the old phone')$$,
  '42501', null, 'a stale session retrying a taken id gets 42501, never 23505');
reset role;

-- 7 removed from the allowlist ---------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000c1d05', 'c1d00000-0000-0000-0000-000000000005');
select lives_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'fay1'), (select id from _conv where name = 'fb'),
            '00000000-0000-0000-0000-0000000c1d05', 'while allowed')$$,
  'control: fay, allowlisted, may insert with a chosen id');
reset role;
delete from app_private.allowlist where email = 'cid-fay@example.com';
select test_as('00000000-0000-0000-0000-0000000c1d05', 'c1d00000-0000-0000-0000-000000000005');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'fay1'), (select id from _conv where name = 'fb'),
            '00000000-0000-0000-0000-0000000c1d05', 'after removal')$$,
  '42501', null, 'a member removed from the allowlist gets 42501, never 23505');
reset role;

-- 8 a revoked session ----------------------------------------------------------
delete from auth.sessions where id = 'c1d00000-0000-0000-0000-000000000001';
select test_as('00000000-0000-0000-0000-0000000c1d01', 'c1d00000-0000-0000-0000-000000000001');
select throws_ok(
  $$insert into public.messages(id, conversation_id, sender_id, body)
    values ((select id from _id where name = 'x1'), (select id from _conv where name = 'ab'),
            '00000000-0000-0000-0000-0000000c1d01', 'after revocation')$$,
  '42501', null, 'a revoked session retrying its own taken id gets 42501, never 23505');
reset role;

select is((select count(*)::int from public.messages
            where id in (select id from _id)), 4,
          'exactly x1, y1, eve2 and fay1 were ever stored');

select * from finish();
rollback;
