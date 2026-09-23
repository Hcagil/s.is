begin;
select plan(63);

-- Unread counts (v0.5): conversation_members.last_read_at, public.mark_read()
-- and public.unread_counts().
--
-- Three contracts are under test.
--
-- 1. last_read_at is private. A member may still read the other columns of
--    the membership rows it could read before, but not last_read_at -- not its
--    own, not anyone else's, not even in a WHERE clause. Otherwise "seen at"
--    leaks to the other side of a conversation.
-- 2. mark_read() moves the CALLER's own row, to now(), and only in a
--    conversation the caller belongs to while holding app access.
-- 3. unread_counts() answers for the caller only: per conversation, messages
--    newer than the caller's last_read_at that someone else sent. Zero rows are
--    omitted; nothing comes back for a conversation the caller is not in.
--
-- Negative fixtures each fail exactly ONE gate:
--   xan  allowlisted, active, NOT a member of D or G  -- membership gate only
--        (he has his own conversation X, so his empty answer is not silence)
--   zed  member of G, allowlisted, session REVOKED    -- session gate only
--   kai  member of G, active, removed from allowlist  -- allowlist gate only
-- A stranger would fail app access first and prove nothing about membership.
--
-- Everything is scoped to the fixtures: the database is not empty.

-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000ee01', 'uma@unread.test', now(), '{"full_name":"Uma"}'),
  ('00000000-0000-0000-0000-00000000ee02', 'vic@unread.test', now(), '{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-00000000ee03', 'wes@unread.test', now(), '{"full_name":"Wes"}'),
  ('00000000-0000-0000-0000-00000000ee04', 'xan@unread.test', now(), '{"full_name":"Xan"}'),
  ('00000000-0000-0000-0000-00000000ee05', 'zed@unread.test', now(), '{"full_name":"Zed"}'),
  ('00000000-0000-0000-0000-00000000ee06', 'kai@unread.test', now(), '{"full_name":"Kai"}');
insert into app_private.allowlist(email) values
  ('uma@unread.test'), ('vic@unread.test'), ('wes@unread.test'),
  ('xan@unread.test'), ('zed@unread.test'), ('kai@unread.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('e1000000-0000-0000-0000-00000000ee01', '00000000-0000-0000-0000-00000000ee01', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee02', '00000000-0000-0000-0000-00000000ee02', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee03', '00000000-0000-0000-0000-00000000ee03', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee04', '00000000-0000-0000-0000-00000000ee04', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee05', '00000000-0000-0000-0000-00000000ee05', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee06', '00000000-0000-0000-0000-00000000ee06', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- The caller's unread count for one conversation, or null when the function
-- omits it. security invoker: it runs as whoever the test is acting as.
create or replace function test_unread(conv uuid) returns integer
language sql security invoker as $$
  select unread from public.unread_counts() where conversation_id = conv
$$;
grant execute on function test_unread(uuid) to authenticated;

-- A direct write to somebody's last_read_at, bypassing mark_read. Returns the
-- rows changed, or -1 when the write is refused outright.
create or replace function test_move(conv uuid, target uuid) returns bigint
language plpgsql security invoker as $$
declare n bigint;
begin
  update public.conversation_members set last_read_at = now() + interval '1 day'
   where conversation_id = conv and user_id = target;
  get diagnostics n = row_count;
  return n;
exception when insufficient_privilege then
  return -1;
end $$;
grant execute on function test_move(uuid, uuid) to authenticated;

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is(public.activate_session(), true, 'uma is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
select is(public.activate_session(), true, 'vic is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee03', 'e1000000-0000-0000-0000-00000000ee03');
select is(public.activate_session(), true, 'wes is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee04', 'e1000000-0000-0000-0000-00000000ee04');
select is(public.activate_session(), true, 'xan is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee05', 'e1000000-0000-0000-0000-00000000ee05');
select is(public.activate_session(), true, 'zed is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee06', 'e1000000-0000-0000-0000-00000000ee06');
select is(public.activate_session(), true, 'kai is active');
reset role;

-- D: uma <-> vic.  G: uma, vic, wes, zed, kai.  X: xan <-> vic.
create temp table _d (id uuid);
create temp table _g (id uuid);
create temp table _x (id uuid);
grant select, insert on _d, _g, _x to authenticated;

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
insert into _d select public.start_direct_conversation('00000000-0000-0000-0000-00000000ee02');
insert into _g select public.start_group_conversation('unread group', array[
  '00000000-0000-0000-0000-00000000ee02', '00000000-0000-0000-0000-00000000ee03',
  '00000000-0000-0000-0000-00000000ee05', '00000000-0000-0000-0000-00000000ee06']::uuid[]);
reset role;
select test_as('00000000-0000-0000-0000-00000000ee04', 'e1000000-0000-0000-0000-00000000ee04');
insert into _x select public.start_direct_conversation('00000000-0000-0000-0000-00000000ee02');
reset role;

-- Written as the owner: created_at is withheld from clients, and every row in
-- one transaction would otherwise carry the same now(). Everybody last read an
-- hour ago; the messages sit on either side of that line.
update public.conversation_members set last_read_at = now() - interval '1 hour'
 where conversation_id in (select id from _d union select id from _g union select id from _x);
insert into public.messages(conversation_id, sender_id, body, created_at) values
  -- D, for uma: 2 unread. One before and one exactly AT her last read do not
  -- count (created_at must be strictly newer); her own does not count.
  ((select id from _d), '00000000-0000-0000-0000-00000000ee02', 'd before', now() - interval '2 hours'),
  ((select id from _d), '00000000-0000-0000-0000-00000000ee02', 'd at read', now() - interval '1 hour'),
  ((select id from _d), '00000000-0000-0000-0000-00000000ee02', 'd one', now() - interval '50 minutes'),
  ((select id from _d), '00000000-0000-0000-0000-00000000ee02', 'd two', now() - interval '40 minutes'),
  ((select id from _d), '00000000-0000-0000-0000-00000000ee01', 'd uma', now() - interval '30 minutes'),
  -- G: three newer messages, from wes, vic and uma.
  ((select id from _g), '00000000-0000-0000-0000-00000000ee03', 'g wes', now() - interval '20 minutes'),
  ((select id from _g), '00000000-0000-0000-0000-00000000ee02', 'g vic', now() - interval '10 minutes'),
  ((select id from _g), '00000000-0000-0000-0000-00000000ee01', 'g uma', now() - interval '5 minutes'),
  -- X: one from vic, unread for xan.
  ((select id from _x), '00000000-0000-0000-0000-00000000ee02', 'x vic', now() - interval '15 minutes');

-- 1 the column ---------------------------------------------------------------
select has_column('public', 'conversation_members', 'last_read_at', 'last_read_at exists');
select col_type_is('public', 'conversation_members', 'last_read_at', 'timestamp with time zone',
                   'last_read_at is a timestamptz');
select col_not_null('public', 'conversation_members', 'last_read_at', 'last_read_at is not null');
select col_default_is('public', 'conversation_members', 'last_read_at', 'now()',
                      'a new member has read everything up to joining');

-- 2 anon reaches none of it -------------------------------------------------
set local role anon;
select throws_ok($$select last_read_at from public.conversation_members$$,
                 '42501', null, 'anon cannot read last_read_at');
select throws_ok($$select conversation_id from public.conversation_members$$,
                 '42501', null, 'anon cannot read conversation_members at all');
select throws_ok($$select public.mark_read('00000000-0000-0000-0000-000000000000')$$,
                 '42501', null, 'anon cannot execute mark_read');
select throws_ok($$select * from public.unread_counts()$$,
                 '42501', null, 'anon cannot execute unread_counts');
reset role;

-- 3 last_read_at is private, even to its owner ------------------------------
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is((select count(*) from (select conversation_id, user_id, joined_at
                                   from public.conversation_members
                                  where conversation_id = (select id from _d)) m),
          2::bigint, 'a member still reads conversation_id, user_id, joined_at of both rows');
select throws_ok($$select last_read_at from public.conversation_members
                    where user_id = '00000000-0000-0000-0000-00000000ee01'$$,
                 '42501', null, 'a member cannot read her own last_read_at');
select throws_ok($$select last_read_at from public.conversation_members
                    where user_id = '00000000-0000-0000-0000-00000000ee02'$$,
                 '42501', null, 'a member cannot read the other member''s last_read_at');
select throws_ok($$select count(*) from public.conversation_members
                    where last_read_at < now()$$,
                 '42501', null, 'a member cannot probe last_read_at through a filter');
select throws_ok($$select * from public.conversation_members$$,
                 '42501', null, 'select * is refused, because it includes last_read_at');
reset role;

-- 4 unread_counts: the caller's own count, per conversation -----------------
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is(test_unread((select id from _d)), 2,
          'uma: newer messages from vic only -- not the older one, not the one at her read, not her own');
select is(test_unread((select id from _g)), 2, 'uma: the group counts wes and vic, not uma');
select is(test_unread((select id from _x)), null, 'uma: nothing for a conversation she is not in');
select is((select count(*) from public.unread_counts()
            where conversation_id not in (select id from _d union select id from _g)),
          0::bigint, 'uma: no row outside her own conversations');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
select is(test_unread((select id from _d)), 1, 'vic: his own four do not count, uma''s one does');
select is(test_unread((select id from _g)), 2, 'vic: wes and uma');
select is(test_unread((select id from _x)), null, 'vic: a conversation with 0 unread is omitted, not 0');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee04', 'e1000000-0000-0000-0000-00000000ee04');
select is(test_unread((select id from _x)), 1, 'xan: positive control, his own conversation counts');
select is(test_unread((select id from _d)), null, 'xan: an active non-member gets nothing for D');
select is(test_unread((select id from _g)), null, 'xan: an active non-member gets nothing for G');
reset role;

-- zed and kai have access for now: positive controls for section 7.
select test_as('00000000-0000-0000-0000-00000000ee05', 'e1000000-0000-0000-0000-00000000ee05');
select is(test_unread((select id from _g)), 3, 'zed: while he has access, all three count');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee06', 'e1000000-0000-0000-0000-00000000ee06');
select is(test_unread((select id from _g)), 3, 'kai: while he has access, all three count');
reset role;

-- 5 mark_read moves the caller's own row, to now() --------------------------
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select lives_ok($$select public.mark_read((select id from _d))$$, 'uma marks D read');
select is(test_unread((select id from _d)), null, 'uma: D is gone from her counts');
select is(test_unread((select id from _g)), 2, 'uma: G is untouched by marking D');
reset role;
select is((select last_read_at from public.conversation_members
            where conversation_id = (select id from _d) and user_id = '00000000-0000-0000-0000-00000000ee01'),
          now(), 'uma''s D row now reads now()');
select is((select last_read_at from public.conversation_members
            where conversation_id = (select id from _d) and user_id = '00000000-0000-0000-0000-00000000ee02'),
          now() - interval '1 hour', 'vic''s D row did not move');
select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
select is(test_unread((select id from _d)), 1, 'vic: still 1 unread in D after uma read it');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select lives_ok($$select public.mark_read((select id from _g))$$, 'uma marks G read');
reset role;
select is((select array_agg(user_id order by user_id) from public.conversation_members
            where conversation_id = (select id from _g) and last_read_at = now()),
          array['00000000-0000-0000-0000-00000000ee01']::uuid[],
          'in G only uma''s row moved');
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _g) and last_read_at = now() - interval '1 hour'),
          4::bigint, 'the other four G rows are where they were');

-- 6 no cross-member moves -------------------------------------------------
select test_as('00000000-0000-0000-0000-00000000ee04', 'e1000000-0000-0000-0000-00000000ee04');
select throws_ok($$select public.mark_read((select id from _d))$$,
                 '42501', null, 'an active non-member cannot mark D read');
select throws_ok($$select public.mark_read((select id from _g))$$,
                 '42501', null, 'an active non-member cannot mark G read');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee03', 'e1000000-0000-0000-0000-00000000ee03');
select throws_ok($$select public.mark_read((select id from _d))$$,
                 '42501', null, 'a member of G cannot mark D, which he is not in');
reset role;
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _d) and last_read_at > now()),
          0::bigint, 'no D row moved past now()');
select is((select count(*) from public.conversation_members
            where user_id in ('00000000-0000-0000-0000-00000000ee03', '00000000-0000-0000-0000-00000000ee04')
              and last_read_at <> now() - interval '1 hour'),
          0::bigint, 'the refused callers'' own rows did not move either');

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select ok(test_move((select id from _d), '00000000-0000-0000-0000-00000000ee02') <= 0,
          'uma cannot write vic''s last_read_at directly');
reset role;
select is((select last_read_at from public.conversation_members
            where conversation_id = (select id from _d) and user_id = '00000000-0000-0000-0000-00000000ee02'),
          now() - interval '1 hour', 'vic''s D row is still where it was');

-- 7 without app access: refused, and nothing counted ----------------------
delete from auth.sessions where id = 'e1000000-0000-0000-0000-00000000ee05';
delete from app_private.allowlist where email = 'kai@unread.test';

select test_as('00000000-0000-0000-0000-00000000ee05', 'e1000000-0000-0000-0000-00000000ee05');
select throws_ok($$select public.mark_read((select id from _g))$$,
                 '42501', null, 'a member whose session was revoked cannot mark read');
select is((select count(*) from public.unread_counts()), 0::bigint,
          'a member whose session was revoked gets no counts');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee06', 'e1000000-0000-0000-0000-00000000ee06');
select throws_ok($$select public.mark_read((select id from _g))$$,
                 '42501', null, 'a member removed from the allowlist cannot mark read');
select is((select count(*) from public.unread_counts()), 0::bigint,
          'a member removed from the allowlist gets no counts');
reset role;
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _g)
              and user_id in ('00000000-0000-0000-0000-00000000ee05', '00000000-0000-0000-0000-00000000ee06')
              and last_read_at = now() - interval '1 hour'),
          2::bigint, 'neither refused member''s row moved');

-- 8 a new membership starts with nothing unread -----------------------------
select test_as('00000000-0000-0000-0000-00000000ee03', 'e1000000-0000-0000-0000-00000000ee03');
create temp table _w as select public.start_direct_conversation('00000000-0000-0000-0000-00000000ee02') as id;
reset role;
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _w) and last_read_at = now()),
          2::bigint, 'both rows of a conversation started now read now()');

-- 9 the privileges themselves ---------------------------------------------
-- Pinned directly, so a later blanket `grant select on conversation_members`
-- fails here by name, not only through its consequence in section 3.
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'last_read_at', 'select'),
          'authenticated holds no select on last_read_at');
select ok(has_column_privilege('authenticated', 'public.conversation_members', 'conversation_id', 'select'),
          'authenticated selects conversation_id');
select ok(has_column_privilege('authenticated', 'public.conversation_members', 'user_id', 'select'),
          'authenticated selects user_id');
select ok(has_column_privilege('authenticated', 'public.conversation_members', 'joined_at', 'select'),
          'authenticated selects joined_at');
select ok(not has_column_privilege('anon', 'public.conversation_members', 'last_read_at', 'select'),
          'anon holds no select on last_read_at');
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'last_read_at', 'update'),
          'authenticated holds no update on last_read_at');
select ok(not has_function_privilege('anon', 'public.mark_read(uuid)', 'execute'),
          'anon cannot execute mark_read');
select ok(not has_function_privilege('anon', 'public.unread_counts()', 'execute'),
          'anon cannot execute unread_counts');
select ok(has_function_privilege('authenticated', 'public.mark_read(uuid)', 'execute'),
          'authenticated may execute mark_read');
select ok(has_function_privilege('authenticated', 'public.unread_counts()', 'execute'),
          'authenticated may execute unread_counts');

select * from finish();
rollback;
