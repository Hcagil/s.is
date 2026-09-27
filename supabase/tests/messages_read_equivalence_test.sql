begin;
select plan(27);

-- messages_read was rewritten at 20260927150000 from
--   (select has_app_access()) and is_member(conversation_id)
-- to
--   (select has_app_access()) and conversation_id = any(array(<the caller's
--   memberships>))
-- so the planner reads the memberships once and bounds the messages index
-- with them. It must be a planner-only change: for every kind of caller, the
-- rows a client sees through the policy are exactly the rows the old
-- predicate admits. The old predicate is computed here as the owner, outside
-- RLS, with the caller's claims set: app_private.has_app_access() (unchanged)
-- and an explicit exists-membership on the caller's id.
--
-- Callers: ada (member of A and B), ben (member of A and C), dan (active,
-- removed from A), eve (member of A, session revoked), fay (member of B,
-- delisted, session still active), gus (active, in no conversation).
-- Conversation D has messages and no members.

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select ('00000000-0000-0000-0000-00000000e00' || n)::uuid, name || '@mre.test', now(),
         json_build_object('full_name', name)::jsonb
    from (values (1, 'ada'), (2, 'ben'), (4, 'dan'), (5, 'eve'), (6, 'fay'), (7, 'gus')) u(n, name);
insert into app_private.allowlist(email)
  values ('ada@mre.test'), ('ben@mre.test'), ('dan@mre.test'), ('eve@mre.test'), ('fay@mre.test'), ('gus@mre.test');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('e0000000-0000-0000-0000-00000000e00' || n)::uuid,
         ('00000000-0000-0000-0000-00000000e00' || n)::uuid, now(), now()
    from unnest(array[1, 2, 4, 5, 6, 7]) n;

-- mre_claims(n): caller n's claims; mre_as(n): those claims as the client.
create function mre_claims(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000e00' || n, 'role', 'authenticated',
      'email', (select email from auth.users where id = ('00000000-0000-0000-0000-00000000e00' || n)::uuid),
      'session_id', 'e0000000-0000-0000-0000-00000000e00' || n)::text, true);
end $$;
create function mre_as(n int) returns void language plpgsql as $$
begin
  perform mre_claims(n);
  execute 'set local role authenticated';
end $$;
grant execute on function mre_claims(int), mre_as(int) to authenticated;

select mre_as(1); select public.activate_session(); reset role;
select mre_as(2); select public.activate_session(); reset role;
select mre_as(4); select public.activate_session(); reset role;
select mre_as(5); select public.activate_session(); reset role;
select mre_as(6); select public.activate_session(); reset role;
select mre_as(7); select public.activate_session(); reset role;
select is((select count(*)::int from app_private.active_sessions
            where user_id::text like '00000000-0000-0000-0000-00000000e00_'), 6, 'all six callers are active');

insert into public.conversations(id, title) values
  ('c0000000-0000-0000-0000-0000000e000a', 'A'), ('c0000000-0000-0000-0000-0000000e000b', 'B'),
  ('c0000000-0000-0000-0000-0000000e000c', 'C'), ('c0000000-0000-0000-0000-0000000e000d', 'D');
insert into public.conversation_members(conversation_id, user_id)
  select ('c0000000-0000-0000-0000-0000000e000' || c)::uuid, ('00000000-0000-0000-0000-00000000e00' || u)::uuid
    from (values ('a', 1), ('b', 1), ('a', 2), ('c', 2), ('a', 4), ('a', 5), ('b', 6)) m(c, u);
-- A: 3 messages (one a placeholder), B: 2, C: 2 (one vanished), D: 1.
insert into public.messages(conversation_id, sender_id, body, deleted, deleted_at) values
  ('c0000000-0000-0000-0000-0000000e000a', '00000000-0000-0000-0000-00000000e001', 'a1', null, null),
  ('c0000000-0000-0000-0000-0000000e000a', '00000000-0000-0000-0000-00000000e002', 'a2', null, null),
  ('c0000000-0000-0000-0000-0000000e000a', '00000000-0000-0000-0000-00000000e004', '', 'placeholder', now()),
  ('c0000000-0000-0000-0000-0000000e000b', '00000000-0000-0000-0000-00000000e001', 'b1', null, null),
  ('c0000000-0000-0000-0000-0000000e000b', '00000000-0000-0000-0000-00000000e006', 'b2', null, null),
  ('c0000000-0000-0000-0000-0000000e000c', '00000000-0000-0000-0000-00000000e002', 'c1', null, null),
  ('c0000000-0000-0000-0000-0000000e000c', '00000000-0000-0000-0000-00000000e002', '', 'vanished', now()),
  ('c0000000-0000-0000-0000-0000000e000d', '00000000-0000-0000-0000-00000000e001', 'd1', null, null);

-- The three ways out, each leaving the other half of the old predicate open:
delete from public.conversation_members                       -- dan: removed, access intact
 where user_id = '00000000-0000-0000-0000-00000000e004';
delete from auth.sessions where id = 'e0000000-0000-0000-0000-00000000e005';  -- eve: revoked, still a member
delete from app_private.allowlist where email = 'fay@mre.test';               -- fay: delisted, still a member

-- The old predicate, per caller, as the owner (RLS does not apply to it).
create temp table ref(n int, id uuid, conversation_id uuid);
create temp table gate(n int, access boolean, memberships int);
create function pg_temp.old_rows(n int) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-00000000e00' || n)::uuid;
begin
  perform mre_claims(n);
  insert into gate select n, app_private.has_app_access(),
    (select count(*)::int from public.conversation_members where user_id = uid);
  insert into ref
    select n, m.id, m.conversation_id from public.messages m
     where app_private.has_app_access()
       and exists (select 1 from public.conversation_members cm
                    where cm.conversation_id = m.conversation_id and cm.user_id = uid);
end $$;
select pg_temp.old_rows(n) from unnest(array[1, 2, 4, 5, 6, 7]) n;
grant select on ref to authenticated;

-- Each negative caller fails exactly one half of the old predicate.
select is((select format('%s/%s', access, memberships) from gate where n = 4), 't/0',  'dan: app access, no membership');
select is((select format('%s/%s', access, memberships) from gate where n = 5), 'f/1', 'eve: a membership, no app access (session revoked)');
select is((select format('%s/%s', access, memberships) from gate where n = 6), 'f/1', 'fay: a membership, no app access (delisted)');
select is((select format('%s/%s', access, memberships) from gate where n = 7), 't/0',  'gus: app access, no membership');
-- The reference is not vacuous: its sizes, derived by hand from the fixture.
select is((select string_agg(format('%s:%s', u.n, (select count(*) from ref r where r.n = u.n)), ' ' order by u.n)
             from unnest(array[1, 2, 4, 5, 6, 7]) u(n)),
          '1:5 2:5 4:0 5:0 6:0 7:0', 'old predicate: ada 5 (A+B), ben 5 (A+C), everyone else none');

-- 1 unscoped reads: the same rows as the old predicate -----------------------
select mre_as(1);
select set_eq('select id from public.messages', 'select id from ref where n = 1', 'ada (member of A, B): same rows as before');
reset role;
select mre_as(2);
select set_eq('select id from public.messages', 'select id from ref where n = 2', 'ben (member of A, C): same rows as before');
reset role;
select mre_as(4);
select is_empty('select id from public.messages', 'dan (removed member): no rows, as before');
reset role;
select mre_as(5);
select is_empty('select id from public.messages', 'eve (revoked session): no rows, as before');
reset role;
select mre_as(6);
select is_empty('select id from public.messages', 'fay (delisted): no rows, as before');
reset role;
select mre_as(7);
select is_empty('select id from public.messages', 'gus (no memberships): no rows, as before');
reset role;

-- 2 a history read of one conversation: the same rows, per conversation ------
-- Member and non-member of each conversation, including the memberless D.
create function pg_temp.history_matches(n int, c text) returns boolean language plpgsql as $$
declare seen uuid[]; expected uuid[];
begin
  select coalesce(array_agg(id order by id), '{}') into expected from ref
   where ref.n = history_matches.n and conversation_id = ('c0000000-0000-0000-0000-0000000e000' || c)::uuid;
  perform mre_as(n);
  select coalesce(array_agg(id order by id), '{}') into seen from public.messages
   where conversation_id = ('c0000000-0000-0000-0000-0000000e000' || c)::uuid;
  reset role;
  return seen = expected;
end $$;
select ok(pg_temp.history_matches(1, 'a'), 'ada, history of A (member): same rows');
select ok(pg_temp.history_matches(1, 'b'), 'ada, history of B (member): same rows');
select ok(pg_temp.history_matches(1, 'c'), 'ada, history of C (not a member): same rows (none)');
select ok(pg_temp.history_matches(1, 'd'), 'ada, history of D (nobody''s): same rows (none)');
select ok(pg_temp.history_matches(2, 'a'), 'ben, history of A (member): same rows');
select ok(pg_temp.history_matches(2, 'b'), 'ben, history of B (not a member): same rows (none)');
select ok(pg_temp.history_matches(2, 'c'), 'ben, history of C (member, one vanished): same rows');
select ok(pg_temp.history_matches(4, 'a'), 'dan, history of A (removed): same rows (none)');
select ok(pg_temp.history_matches(5, 'a'), 'eve, history of A (revoked): same rows (none)');
select ok(pg_temp.history_matches(6, 'b'), 'fay, history of B (delisted): same rows (none)');
select ok(pg_temp.history_matches(7, 'a'), 'gus, history of A (no memberships): same rows (none)');
-- Not vacuous: the member histories above compare non-empty sets.
select is((select count(*)::int from ref where n = 1 and conversation_id = 'c0000000-0000-0000-0000-0000000e000a'), 3,
          'ada''s history of A has 3 rows to compare');

-- 3 the rows are whole: a member reads the same content the owner stored ----
select mre_as(2);
create temp table ben_c as select id, body, deleted from public.messages
  where conversation_id = 'c0000000-0000-0000-0000-0000000e000c';
reset role;
select set_eq('select id, body, deleted from ben_c',
              $$select id, body, deleted from public.messages where conversation_id = 'c0000000-0000-0000-0000-0000000e000c'$$,
              'ben reads C''s rows as stored, vanished one included');

-- 4 the new text reads conversation_members as the caller -------------------
-- The membership subquery runs under conversation_members_read. A caller who
-- is a member of B but whose membership row has vanished between two reads
-- in one transaction loses B at once (no stale cached array across queries).
select mre_as(1);
select is((select count(*)::int from public.messages), 5, 'ada before leaving B: 5 rows');
reset role;
delete from public.conversation_members
 where conversation_id = 'c0000000-0000-0000-0000-0000000e000b' and user_id = '00000000-0000-0000-0000-00000000e001';
select mre_as(1);
select is((select count(*)::int from public.messages), 3, 'ada after leaving B: only A''s 3 rows, in the same transaction');
reset role;

select * from finish();
rollback;
