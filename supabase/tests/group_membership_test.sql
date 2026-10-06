begin;
select plan(145);

-- Leaving a group, removing members, admins, and membership windows (v0.23.0).
--
-- Written from the contract (docs/SECURITY.md "Membership windows",
-- "Admins", "group_events"; docs/DECISIONS.md 2026-09-29), not from the
-- migration. Three kinds of fixture:
--
--  * RPC groups (G1, G2, G3, G4, D1) are built through the RPCs themselves,
--    so what they leave behind is what production leaves behind;
--  * the window group W is built directly, as postgres, with explicit
--    timestamps: inside one transaction now() never moves, so every window
--    edge would otherwise be the same instant and no bound could be told
--    from its absence;
--  * every negative fixture fails exactly one gate: ren is allowlisted,
--    active and reachable by nobody (only reach can refuse him); nora is
--    reachable but not allowlisted (only the allowlist can refuse her); kim
--    is a current member whose session is revoked (only app access can).
--
-- The deferred admin guard fires only at COMMIT, which a test never
-- reaches. So every RPC below is called through a wrapper that ends the way
-- a committed request does: SET CONSTRAINTS ALL IMMEDIATE fires everything
-- still pending, then the file goes back to deferred. An RPC whose result
-- would be refused at commit is refused here too, inside the same
-- lives_ok/throws_ok, and rolled back with it.

-- fixtures -------------------------------------------------------------------
-- 01 ada  02 bea  03 cai  04 dov  05 eve  06 fay  07 gus  08 hal  09 ivy
-- 10 ren (allowlisted, active, unreachable)  11 nora (confirmed, NOT allowlisted)
-- 12 zed (allowlisted, active, in nothing)   13 kim
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000e30' || n)::uuid, name || '@gm.test', now(),
       json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ada'),('02','bea'),('03','cai'),('04','dov'),('05','eve'),
               ('06','fay'),('07','gus'),('08','hal'),('09','ivy'),('10','ren'),
               ('11','nora'),('12','zed'),('13','kim'),
               ('21','wan'),('22','wbe'),('23','wca'),('24','wdo'),('26','wfa'),('27','wgu')) v(n, name);
insert into app_private.allowlist(email)
select name || '@gm.test'
  from unnest(array['ada','bea','cai','dov','eve','fay','gus','hal','ivy','ren','zed','kim',
                     'wan','wbe','wca','wdo','wfa','wgu']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('e3000000-0000-0000-0000-0000000000' || n)::uuid, ('00000000-0000-0000-0000-0000000e30' || n)::uuid, now(), now()
  from unnest(array['01','02','03','04','05','06','07','08','09','10','11','12','13',
                     '21','22','23','24','26','27']) n;
-- Reach, as tag finds: ada reaches everyone she creates groups with or adds,
-- nora included (so only the allowlist can refuse nora); ren is reached by
-- nobody. hal reaches the members of his own group.
insert into app_private.tag_finds(finder, found_id)
select '00000000-0000-0000-0000-0000000e3001'::uuid, ('00000000-0000-0000-0000-0000000e30' || n)::uuid
  from unnest(array['02','03','04','05','06','07','11','13']) n;
-- bea and cai reach eve too, so their refused add_members below can only be
-- refused for not being an admin.
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000e3002', '00000000-0000-0000-0000-0000000e3005'),
  ('00000000-0000-0000-0000-0000000e3003', '00000000-0000-0000-0000-0000000e3005'),
  ('00000000-0000-0000-0000-0000000e3008', '00000000-0000-0000-0000-0000000e3009'),
  ('00000000-0000-0000-0000-0000000e3008', '00000000-0000-0000-0000-0000000e3013');

create function gm_as(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-0000000e30' || n, 'role', 'authenticated',
      'email', (select email from auth.users where id = ('00000000-0000-0000-0000-0000000e30' || n)::uuid),
      'session_id', 'e3000000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000e30' || n)::uuid
$$;
-- The truth about a member's rows, whatever RLS says (called as postgres).
create function rows_of(conv uuid, n text)
returns table (role text, left_at timestamptz, left_reason text, history_from timestamptz, joined_at timestamptz)
language sql as $$
  select role, left_at, left_reason, history_from, joined_at
    from public.conversation_members where conversation_id = conv and user_id = u(n)
   order by joined_at, left_at nulls last
$$;
create function current_role_of(conv uuid, n text) returns text language sql as $$
  select role from public.conversation_members
   where conversation_id = conv and user_id = u(n) and left_at is null
$$;
create function admins_of(conv uuid) returns text language sql as $$
  select string_agg(p.n, ',' order by p.n)
    from public.conversation_members cm
    join (select lpad(g::text, 2, '0') n from generate_series(1, 27) g) p on cm.user_id = u(p.n)
   where cm.conversation_id = conv and cm.left_at is null and cm.role = 'admin'
$$;
grant execute on function gm_as(text), u(text) to authenticated, anon;

create function commit_check() returns void language plpgsql as $$
begin
  set constraints all immediate;
  set constraints all deferred;
end $$;
create function checked(q text) returns void language plpgsql as $$
begin
  execute q;
  perform commit_check();
end $$;
create function leave_c(c uuid) returns void language plpgsql as $$
begin perform public.leave_group(c); perform commit_check(); end $$;
create function remove_c(c uuid, m uuid) returns void language plpgsql as $$
begin perform public.remove_member(c, m); perform commit_check(); end $$;
create function add_c(c uuid, ms uuid[], h boolean) returns void language plpgsql as $$
begin perform public.add_members(c, ms, h); perform commit_check(); end $$;
create function admin_c(c uuid, m uuid, b boolean) returns void language plpgsql as $$
begin perform public.set_admin(c, m, b); perform commit_check(); end $$;
grant execute on function commit_check(), checked(text), leave_c(uuid), remove_c(uuid, uuid),
  add_c(uuid, uuid[], boolean), admin_c(uuid, uuid, boolean) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07','08','09','10','12','13',
                           '21','22','23','24','26','27'] loop
    perform gm_as(n);
    perform public.activate_session();
    execute 'reset role';
  end loop;
end $$;

-- A captured id, readable by the fixtures.
create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

-- 1 the creator is the group's admin ------------------------------------------
select gm_as('01');
insert into ids values
  ('G1', public.start_group_conversation('gm-rpc', array[u('02'), u('03'), u('04'), u('13')])),
  ('G2', public.start_group_conversation('gm-promote', array[u('02'), u('03')])),
  ('G3', public.start_group_conversation('gm-adminless', array[u('02'), u('03')])),
  ('G5', public.start_group_conversation('gm-guard', array[u('02')])),
  ('D1', public.start_direct_conversation(u('02')));
reset role;
select gm_as('08');
insert into ids values ('G4', public.start_group_conversation('gm-delete', array[u('09'), u('13')]));
reset role;
-- These groups stand for groups that existed before the group settings
-- (20261007120000): the values the migration gave them, so every case below
-- still checks the behaviour such a group keeps. group_settings_test.sql
-- covers the switches themselves.
update public.conversations
   set members_can_add = false, new_members_see_history = false, members_can_set_avatar = true
 where id in (select id from ids);

select is(current_role_of(g('G1'), '01'), 'admin', 'the creator of a group is its admin');
select is(admins_of(g('G1')), '01', 'and the only admin: every invitee is an ordinary member');
select is(current_role_of(g('G4'), '08'), 'admin', 'whoever creates a group is its admin (hal)');
select is((select count(*)::int from public.conversation_members
            where conversation_id = g('D1') and role = 'admin'), 0,
          'a 1:1 has no admin');
select is((select history_from from rows_of(g('G1'), '03')), '-infinity'::timestamptz,
          'an invitee at creation reads the whole (empty) history');

-- 2 who may call the RPCs ------------------------------------------------------
set local role anon;
select throws_ok(format('select public.leave_group(%L)', g('G1')), '42501', null, 'anon cannot leave_group');
select throws_ok(format('select public.remove_member(%L, %L)', g('G1'), u('02')), '42501', null, 'anon cannot remove_member');
select throws_ok(format('select public.add_members(%L, array[%L]::uuid[], true)', g('G1'), u('05')), '42501', null, 'anon cannot add_members');
select throws_ok(format('select public.set_admin(%L, %L, true)', g('G1'), u('02')), '42501', null, 'anon cannot set_admin');
select throws_ok('select count(*) from public.group_events', '42501', null, 'anon cannot read group_events');
reset role;

-- kim is a current member of G1 whose session is revoked: only app access
-- can refuse her.
delete from auth.sessions where user_id = u('13');
select gm_as('13');
select throws_ok(format('select leave_c(%L)', g('G1')), null, null,
                 'a member without an active session cannot leave');
reset role;
select is(current_role_of(g('G1'), '13'), 'member', 'kim is still a current member');

-- 3 1:1s refuse all four ---------------------------------------------------------
-- ada's side of the 1:1 is marked admin (as no RPC ever would), so the admin
-- gate lets her through and only the 1:1 gate can refuse.
update public.conversation_members set role = 'admin' where conversation_id = g('D1') and user_id = u('01');
select gm_as('01');
select throws_ok(format('select leave_c(%L)', g('D1')), null, null, 'a 1:1 cannot be left');
select throws_ok(format('select remove_c(%L, %L)', g('D1'), u('02')), null, null, 'nobody is removed from a 1:1');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('D1'), u('03')), null, null, 'nobody is added to a 1:1');
select throws_ok(format('select admin_c(%L, %L, true)', g('D1'), u('02')), null, null, 'a 1:1 has no admins to make');
select throws_ok(format('select admin_c(%L, %L, true)', g('D1'), u('01')), null, null, 'not even yourself');
reset role;
update public.conversation_members set role = 'member' where conversation_id = g('D1') and user_id = u('01');
select is((select count(*)::int from public.conversation_members
            where conversation_id = g('D1') and left_at is null and role = 'member'), 2,
          'the 1:1 still has its two ordinary current members');

-- 4 remove_member --------------------------------------------------------------
select gm_as('03');
select throws_ok(format('select remove_c(%L, %L)', g('G1'), u('04')), null, null,
                 'an ordinary member cannot remove anyone');
reset role;
select is(current_role_of(g('G1'), '04'), 'member', 'dov is still in');
select gm_as('01');
select throws_ok(format('select remove_c(%L, %L)', g('G1'), u('01')), null, null,
                 'an admin cannot remove herself (she leaves instead)');
select lives_ok(format('select remove_c(%L, %L)', g('G1'), u('02')),
                'the admin removes bea');
reset role;
select is((select string_agg(coalesce(left_reason, '-') || ':' || (left_at is not null)::text, ',') from rows_of(g('G1'), '02')),
          'removed:true', 'bea''s row stays, marked removed');
select is(current_role_of(g('G1'), '02'), null, 'bea is no longer current');
select is((select count(*)::int from public.group_events
            where conversation_id = g('G1') and kind = 'removed' and subject_id = u('02') and actor_id = u('01')), 1,
          'a removed event names bea and the admin who did it');

-- 5 add_members ---------------------------------------------------------------
select gm_as('03');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('G1'), u('05')), null, null,
                 'an ordinary member cannot add anyone');
reset role;
select gm_as('02');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('G1'), u('05')), null, null,
                 'a removed member cannot add anyone');
reset role;
select gm_as('01');
select throws_ok(format('select add_c(%L, array[%L, %L]::uuid[], true)', g('G1'), u('05'), u('10')), null, null,
                 'one unreachable invitee (ren) fails the whole call');
select throws_ok(format('select add_c(%L, array[%L, %L]::uuid[], true)', g('G1'), u('05'), u('11')), null, null,
                 'one invitee who is not allowlisted (nora) fails the whole call');
select throws_ok(format('select add_c(%L, array[%L, null]::uuid[], true)', g('G1'), u('05')), '42501', null,
                 'a null element fails the whole call with 42501');
reset role;
select is((select count(*)::int from public.conversation_members where conversation_id = g('G1') and user_id = u('05')), 0,
          'after three refused calls eve was never added: all or nothing');

select gm_as('01');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G1'), u('05')),
                'the admin adds eve without the old messages');
select lives_ok(format('select add_c(%L, array[%L, %L]::uuid[], true)', g('G1'), u('06'), u('03')),
                'the admin adds fay with the old messages; cai, already current, is skipped');
reset role;
select is((select history_from from rows_of(g('G1'), '05')), now(), 'eve (no history) reads from the moment she was added');
select is((select history_from from rows_of(g('G1'), '06')), '-infinity'::timestamptz, 'fay (with history) reads everything');
select is((select role from rows_of(g('G1'), '05')), 'member', 'an added member is an ordinary member');
select is((select count(*)::int from rows_of(g('G1'), '03')), 1, 'an already-current member gets no second row');
select is((select string_agg(subject_id::text, ',' order by subject_id) from public.group_events
            where conversation_id = g('G1') and kind = 'added' and actor_id = u('01')),
          u('05')::text || ',' || u('06')::text, 'one added event for each member actually added, none for cai');

-- 6 the windows the RPCs made are the windows read through -------------------
-- Messages placed as postgres around now(): one an hour ago, one now.
insert into public.messages(id, conversation_id, sender_id, body, created_at) values
  ('e3e30000-0000-0000-0000-000000000101', g('G1'), u('01'), 'gmrpc before', now() - interval '1 hour'),
  ('e3e30000-0000-0000-0000-000000000102', g('G1'), u('01'), 'gmrpc now', now());
select is((select created_at from public.messages where id = 'e3e30000-0000-0000-0000-000000000101'),
          now() - interval '1 hour', 'fixture: the earlier message keeps its time');
select gm_as('05');
select is((select string_agg(body, ',' order by created_at) from public.messages where conversation_id = g('G1')),
          'gmrpc now', 'eve, added without history, reads only from her joining on');
reset role;
select gm_as('06');
select is((select string_agg(body, ',' order by created_at) from public.messages where conversation_id = g('G1')),
          'gmrpc before,gmrpc now', 'fay, added with history, reads the earlier message too');
reset role;

-- 7 rejoining: a fresh window, the old one still readable, the gap not ------
-- bea's removal (section 4) is moved back in time: in the group 10h..5h ago.
update public.conversation_members set joined_at = now() - interval '10 hours', left_at = now() - interval '5 hours'
 where conversation_id = g('G1') and user_id = u('02');
select commit_check();
insert into public.messages(id, conversation_id, sender_id, body, created_at) values
  ('e3e30000-0000-0000-0000-000000000103', g('G1'), u('01'), 'gmrpc oldwindow', now() - interval '7 hours'),
  ('e3e30000-0000-0000-0000-000000000104', g('G1'), u('01'), 'gmrpc gap', now() - interval '3 hours');
select gm_as('01');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G1'), u('02')),
                'the admin adds bea back, without history');
reset role;
select is((select count(*)::int from rows_of(g('G1'), '02')), 2, 'bea now has two rows: the old window and the new one');
select is((select left_at from rows_of(g('G1'), '02') where left_at is not null), now() - interval '5 hours',
          'the old row keeps its own end');
select is((select history_from from rows_of(g('G1'), '02') where left_at is null), now(),
          'the new row starts now');
select gm_as('02');
select is((select string_agg(body, ',' order by created_at) from public.messages where conversation_id = g('G1')),
          'gmrpc oldwindow,gmrpc now', 'bea reads her old window and her new one, not the gap nor before-history');
reset role;

-- 8 set_admin -----------------------------------------------------------------
select gm_as('03');
select throws_ok(format('select admin_c(%L, %L, true)', g('G1'), u('03')), null, null,
                 'an ordinary member cannot make herself admin');
select throws_ok(format('select admin_c(%L, %L, false)', g('G1'), u('01')), null, null,
                 'an ordinary member cannot demote the admin');
reset role;
select is(admins_of(g('G1')), '01', 'still ada alone');
select gm_as('01');
select throws_ok(format('select admin_c(%L, %L, false)', g('G1'), u('01')), null, null,
                 'the sole admin cannot demote herself');
select lives_ok(format('select admin_c(%L, %L, true)', g('G1'), u('03')), 'ada makes cai an admin');
reset role;
select is(admins_of(g('G1')), '01,03', 'two admins');
-- with another admin present nothing else could refuse this: only the
-- self-removal rule can.
select gm_as('01');
select throws_ok(format('select remove_c(%L, %L)', g('G1'), u('01')), null, null,
                 'an admin cannot remove herself even while another admin remains');
reset role;
select is(current_role_of(g('G1'), '01'), 'admin', 'ada is still in, still admin');
select gm_as('03');
select lives_ok(format('select admin_c(%L, %L, false)', g('G1'), u('01')), 'the new admin demotes ada');
select throws_ok(format('select admin_c(%L, %L, false)', g('G1'), u('03')), null, null,
                 'and, now the sole admin, cannot demote herself');
select lives_ok(format('select admin_c(%L, %L, true)', g('G1'), u('01')), 'cai makes ada admin again');
reset role;
select is(admins_of(g('G1')), '01,03', 'ada and cai are admins');

-- 9 group_events: current admins only, from their own history_from --------
-- An event from an hour ago, before eve's window.
insert into public.group_events(conversation_id, kind, actor_id, subject_id, created_at)
values (g('G1'), 'left', null, u('04'), now() - interval '1 hour');
select gm_as('01');
select is((select count(*)::int from public.group_events where conversation_id = g('G1')), 5,
          'ada (admin, whole history) reads every event: removed bea, added eve, fay, bea, and the hour-old one');
select throws_ok(format($$insert into public.group_events(conversation_id, kind, subject_id) values (%L, 'left', %L)$$, g('G1'), u('04')),
                 '42501', null, 'an admin cannot write an event herself');
select throws_ok(format($$delete from public.group_events where conversation_id = %L$$, g('G1')),
                 '42501', null, 'nor delete one');
reset role;
select gm_as('04');
select is((select count(*)::int from public.group_events where conversation_id = g('G1')), 0,
          'dov, an ordinary current member, reads no events');
reset role;
select gm_as('12');
select is((select count(*)::int from public.group_events where conversation_id = g('G1')), 0,
          'zed, never a member, reads no events');
reset role;
select gm_as('01');
select lives_ok(format('select admin_c(%L, %L, true)', g('G1'), u('05')), 'eve (no history) is made admin');
reset role;
select gm_as('05');
select is((select count(*)::int from public.group_events where conversation_id = g('G1')), 4,
          'eve, admin since now, reads the events from her history_from on, not the hour-old one');
reset role;
select gm_as('01');
select lives_ok(format('select admin_c(%L, %L, false)', g('G1'), u('05')), 'eve is demoted again');
reset role;
select gm_as('05');
select is((select count(*)::int from public.group_events where conversation_id = g('G1')), 0,
          'a demoted admin reads no events');
reset role;
select gm_as('03');
select lives_ok(format('select leave_c(%L)', g('G1')), 'cai, an admin, leaves (ada remains admin)');
select is((select count(*)::int from public.group_events where conversation_id = g('G1')), 0,
          'a departed admin reads no events');
reset role;
select is(admins_of(g('G1')), '01', 'cai leaving with ada still admin promotes nobody');
select is((select count(*)::int from public.group_events
            where conversation_id = g('G1') and kind = 'left' and subject_id = u('03') and actor_id is null), 1,
          'a left event names cai and no actor');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'group_events'), 0,
          'group_events is not in the Realtime publication');
select gm_as('03');
select throws_ok(format('select leave_c(%L)', g('G1')), null, null,
                 'a member who has already left cannot leave again');
reset role;

-- events never reach previews, unread or search: G1's newest message is
-- still its preview after every event above, and a search finds messages only.
select gm_as('01');
select is((select body from public.conversation_previews where conversation_id = g('G1')), 'gmrpc now',
          'the preview is the newest message, not an event');
select is((select count(*)::int from public.search_messages('removed', g('G1'))), 0,
          'search finds no event text');
reset role;

-- 10 leave_group promotes the longest-standing current member -------------
-- G2: ada (admin), bea, cai. cai has been in longest, bea joined later.
update public.conversation_members set joined_at = now() - interval '3 hours'
 where conversation_id = g('G2') and user_id = u('03');
update public.conversation_members set joined_at = now() - interval '2 hours'
 where conversation_id = g('G2') and user_id = u('02');
update public.conversation_members set joined_at = now() - interval '4 hours'
 where conversation_id = g('G2') and user_id = u('01');
select gm_as('01');
select lives_ok(format('select leave_c(%L)', g('G2')), 'the sole admin leaves');
reset role;
select is(admins_of(g('G2')), '03', 'the longest-standing current member (cai) is promoted, and only she');
select is((select left_reason from rows_of(g('G2'), '01')), 'left', 'ada''s row stays, marked left');

-- G3 made admin-less behind the guard's back (a state only data older than
-- the guard could be in); then an ORDINARY member leaves.
alter table public.conversation_members disable trigger conversation_members_admin_guard;
update public.conversation_members set role = 'member' where conversation_id = g('G3');
alter table public.conversation_members enable trigger conversation_members_admin_guard;
update public.conversation_members set joined_at = now() - interval '1 hour'
 where conversation_id = g('G3') and user_id = u('01');
update public.conversation_members set joined_at = now() - interval '3 hours'
 where conversation_id = g('G3') and user_id = u('03');
update public.conversation_members set joined_at = now() - interval '2 hours'
 where conversation_id = g('G3') and user_id = u('02');
select is(admins_of(g('G3')), null, 'fixture: G3 has no admin');
select gm_as('02');
select lives_ok(format('select leave_c(%L)', g('G3')), 'bea, an ordinary member, leaves the admin-less group');
reset role;
select is(admins_of(g('G3')), '03', 'the longest-standing current member (cai) is promoted');

-- the last member leaving empties the group; nobody is left to promote
select gm_as('01');
select lives_ok(format('select leave_c(%L)', g('G5')), 'ada leaves G5, bea is promoted');
reset role;
select is(admins_of(g('G5')), '02', 'bea runs G5');
select gm_as('02');
select lives_ok(format('select leave_c(%L)', g('G5')), 'the last current member can leave');
reset role;
select is((select count(*)::int from public.conversation_members where conversation_id = g('G5') and left_at is null), 0,
          'G5 has no current members');

-- 11 the deferred guard -----------------------------------------------------------
-- G4: hal (admin), ivy, kim. Any change that leaves members and no admin is refused.
select throws_ok(format('select checked(%L)', format($$update public.conversation_members set role = 'member' where conversation_id = %L$$, g('G4'))),
                 null, null, 'demoting the only admin while members remain is refused');
select throws_ok(format('select checked(%L)', format($$update public.conversation_members set left_at = now(), left_reason = 'left'
                           where conversation_id = %L and user_id = %L$$, g('G4'), u('08'))),
                 null, null, 'the only admin leaving behind the RPCs'' back is refused');
select lives_ok(format('select checked(%L)', format($$update public.conversation_members set role = 'admin' where conversation_id = %L and user_id = %L$$, g('G4'), u('09'))),
                'a second admin is fine');
select lives_ok(format('select checked(%L)', format($$update public.conversation_members set role = 'member' where conversation_id = %L and user_id = %L$$, g('G4'), u('09'))),
                'and so is taking it away again while hal remains');
select is(admins_of(g('G4')), '08', 'G4 is back to hal alone');

-- mark_read does not trip the guard: G6 is admin-less (built behind it), and
-- a member marking it read must not be refused for a state she did not make.
insert into ids values ('G6', 'e3e30000-0000-0000-0000-0000000000c6');
insert into public.conversations(id, title) values (g('G6'), 'gm-legacy');
alter table public.conversation_members disable trigger conversation_members_admin_guard;
insert into public.conversation_members(conversation_id, user_id, role) values
  (g('G6'), u('01'), 'member'), (g('G6'), u('02'), 'member');
alter table public.conversation_members enable trigger conversation_members_admin_guard;
select gm_as('02');
select lives_ok(format('select checked(%L)', format('select public.mark_read(%L)', g('G6'))), 'mark_read on an admin-less group is not refused by the guard');
reset role;

-- 12 an account deletion promotes ---------------------------------------------
update public.conversation_members set joined_at = now() - interval '2 hours'
 where conversation_id = g('G4') and user_id = u('09');
update public.conversation_members set joined_at = now() - interval '3 hours'
 where conversation_id = g('G4') and user_id = u('13');
delete from auth.users where id = u('08');
select lives_ok('select commit_check()', 'the deletion commits: the guard is satisfied');
select is(admins_of(g('G4')), '13', 'the admin''s account deleted: the longest-standing current member (kim) is promoted');
select is(current_role_of(g('G4'), '09'), 'member', 'and only she');

-- 13 membership windows on every surface (W) -----------------------------------
-- Built directly with explicit times (T = now()), from its own people
-- (21..27, called ada..gus below by role) so no other group here can lend
-- them a shared conversation:
--   ada  admin   joined T-10h  history -inf   current
--   bea  member  joined T-10h  history -inf   left T-5h
--   cai  member  joined T-3h   history T-3h   current (added without history)
--   dov  member  joined T-8h   history -inf   current
--   fay  member  joined T-2h   history -inf   current (added with history)
--   gus  member  joined T-9h   history -inf   removed T-7h
--   gus  member  joined T-4h   history T-4h   current (back without history)
-- Messages: w1 T-9.5h, w2 T-6h, wedge T-5h (bea's exact end), w3 T-4.5h,
-- w3b T-3h (cai's exact start), w4 T-2.5h, w5 T-1h.
insert into ids values ('W', 'e3e30000-0000-0000-0000-0000000000f1');
insert into public.conversations(id, title) values (g('W'), 'gm-window');
insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from, left_at, left_reason) values
  (g('W'), u('21'), 'admin',  now() - interval '10 hours', '-infinity', null, null),
  (g('W'), u('22'), 'member', now() - interval '10 hours', '-infinity', now() - interval '5 hours', 'left'),
  (g('W'), u('23'), 'member', now() - interval '3 hours',  now() - interval '3 hours', null, null),
  (g('W'), u('24'), 'member', now() - interval '8 hours',  '-infinity', null, null),
  (g('W'), u('26'), 'member', now() - interval '2 hours',  '-infinity', null, null),
  (g('W'), u('27'), 'member', now() - interval '9 hours',  '-infinity', now() - interval '7 hours', 'removed'),
  (g('W'), u('27'), 'member', now() - interval '4 hours',  now() - interval '4 hours', null, null);
select commit_check();
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', g('W') || '/w1.jpg', u('21')::text, '{"size":3}'),
  ('attachments', g('W') || '/w5.jpg', u('21')::text, '{"size":3}'),
  ('attachments', g('W') || '/bea-draft.jpg', u('22')::text, '{"size":3}'),
  -- zed was never in W: owning an object there gives her nothing
  ('attachments', g('W') || '/zed.jpg', u('12')::text, '{"size":3}');
insert into public.messages(id, conversation_id, sender_id, body, attachment_path, created_at) values
  ('e3e30000-0000-0000-0000-0000000000a1', g('W'), u('21'), 'gmwin w1', g('W') || '/w1.jpg', now() - interval '570 minutes'),
  ('e3e30000-0000-0000-0000-0000000000a2', g('W'), u('22'), 'gmwin w2', null, now() - interval '6 hours'),
  ('e3e30000-0000-0000-0000-0000000000ae', g('W'), u('21'), 'gmwin wedge', null, now() - interval '5 hours'),
  ('e3e30000-0000-0000-0000-0000000000a3', g('W'), u('21'), 'gmwin w3', null, now() - interval '270 minutes'),
  ('e3e30000-0000-0000-0000-0000000000ab', g('W'), u('21'), 'gmwin w3b', null, now() - interval '3 hours'),
  ('e3e30000-0000-0000-0000-0000000000a4', g('W'), u('24'), 'gmwin w4', null, now() - interval '150 minutes'),
  ('e3e30000-0000-0000-0000-0000000000a5', g('W'), u('21'), 'gmwin w5', g('W') || '/w5.jpg', now() - interval '1 hour');
update public.conversations set avatar_path = 'group/' || g('W') || '/1.jpg' where id = g('W');
insert into storage.objects(bucket_id, name, owner_id, metadata)
values ('avatars', 'group/' || g('W') || '/1.jpg', u('21')::text, '{"size":3,"mimetype":"image/jpeg"}');

create function w_read() returns text language sql as $$
  select coalesce(string_agg(substr(body, 7), ',' order by created_at), '')
    from public.messages where conversation_id = g('W')
$$;
create function w_search() returns text language sql as $$
  select coalesce(string_agg(substr(body, 7), ',' order by created_at), '')
    from public.search_messages('gmwin', g('W'))
$$;
create function w_search_all() returns text language sql as $$
  select coalesce(string_agg(substr(body, 7), ',' order by created_at), '')
    from public.search_messages('gmwin', null)
$$;
create function w_files() returns text language sql as $$
  select coalesce(string_agg(split_part(name, '/', 2), ',' order by name), '')
    from storage.objects where bucket_id = 'attachments' and name like g('W') || '/%'
$$;
create function w_people() returns text language sql as $$
  select coalesce(string_agg(right(user_id::text, 2) || case when left_at is null then '' else '-' end, ',' order by right(user_id::text, 2), joined_at), '')
    from public.conversation_members where conversation_id = g('W')
$$;
create function w_profiles() returns text language sql as $$
  select coalesce(string_agg(right(user_id::text, 2), ',' order by user_id), '')
    from public.profiles where user_id = any (array[u('21'), u('22'), u('23'), u('24'), u('26'), u('27')])
$$;
grant execute on function w_read(), w_search(), w_search_all(), w_files(), w_people(), w_profiles() to authenticated;

-- messages
select gm_as('21'); select is(w_read(), 'w1,w2,wedge,w3,w3b,w4,w5', 'ada (whole time, whole history) reads every message'); reset role;
select gm_as('22'); select is(w_read(), 'w1,w2,wedge', 'bea (left T-5h) reads up to and including the instant she left, nothing after'); reset role;
select gm_as('23'); select is(w_read(), 'w3b,w4,w5', 'cai (no history, from T-3h) reads from the instant she joined, nothing before'); reset role;
select gm_as('26'); select is(w_read(), 'w1,w2,wedge,w3,w3b,w4,w5', 'fay (joined late, with history) reads everything'); reset role;
select gm_as('27'); select is(w_read(), 'w1,w3b,w4,w5', 'gus reads his first window and his second, never the gap between'); reset role;
select gm_as('12'); select is(w_read(), '', 'zed, never a member, reads nothing'); reset role;

-- the conversation row: any window at all
select gm_as('22');
select is((select count(*)::int from public.conversations where id = g('W')), 1, 'bea, departed, still reads the conversation row');
reset role;
select gm_as('12');
select is((select count(*)::int from public.conversations where id = g('W')), 0, 'zed does not');
reset role;

-- search: the same windows, scoped and unscoped
select gm_as('22'); select is(w_search(), 'w1,w2,wedge', 'search: bea finds only her window'); select is(w_search_all(), 'w1,w2,wedge', 'unscoped search: the same'); reset role;
select gm_as('23'); select is(w_search(), 'w3b,w4,w5', 'search: cai finds only from her start'); select is(w_search_all(), 'w3b,w4,w5', 'unscoped search: the same'); reset role;
select gm_as('27'); select is(w_search(), 'w1,w3b,w4,w5', 'search: gus never finds the gap'); reset role;

-- attachments, by storage listing
select gm_as('22'); select is(w_files(), 'bea-draft.jpg,w1.jpg', 'bea lists w1''s photo and her own unsent upload, not w5''s'); reset role;
select gm_as('23'); select is(w_files(), 'w5.jpg', 'cai lists only the photo of a message in her window'); reset role;
select gm_as('26'); select is(w_files(), 'w1.jpg,w5.jpg', 'fay lists every referenced photo, not bea''s unreferenced upload'); reset role;
select gm_as('27'); select is(w_files(), 'w1.jpg,w5.jpg', 'gus: w1 from his first window, w5 from his second'); reset role;
select gm_as('12'); select is(w_files(), '', 'zed lists nothing'); reset role;

-- previews: one row per conversation, the newest readable message
select gm_as('22');
select is((select string_agg(body, ',') from public.conversation_previews where conversation_id = g('W')), 'gmwin wedge',
          'bea''s preview is the last message she can read');
reset role;
select gm_as('23');
select is((select string_agg(body, ',') from public.conversation_previews where conversation_id = g('W')), 'gmwin w5',
          'cai''s preview is the newest message');
reset role;
select gm_as('27');
select is((select count(*)::int from public.conversation_previews where conversation_id = g('W')), 1,
          'gus, with two membership rows, gets one preview row');
reset role;

-- unread counts: current members only (both have read nothing for 9-10h)
update public.conversation_members set last_read_at = now() - interval '9 hours'
 where conversation_id = g('W') and user_id = u('22');
update public.conversation_members set last_read_at = now() - interval '10 hours'
 where conversation_id = g('W') and user_id = u('23');
select gm_as('22');
select is((select count(*)::int from public.unread_counts() where conversation_id = g('W')), 0,
          'bea, departed, has no unread count for W');
reset role;
select gm_as('23');
select is((select count(*)::int from public.unread_counts() where conversation_id = g('W')), 1,
          'control: cai, current, has an unread row for W');
reset role;

-- mark_read never marks past left_at
update public.conversation_members set last_read_at = now() - interval '9 hours'
 where conversation_id = g('W') and user_id = u('22');
select gm_as('22');
select lives_ok(format('select public.mark_read(%L)', g('W')), 'bea, departed, may mark W read');
reset role;
select cmp_ok((select last_read_at from public.conversation_members where conversation_id = g('W') and user_id = u('22')),
              '<=', now() - interval '5 hours', 'but her read mark stops at the moment she left');
select cmp_ok((select last_read_at from public.conversation_members where conversation_id = g('W') and user_id = u('22')),
              '>', now() - interval '9 hours', 'control: it did move, up to that moment');

-- read_marks: current members only
select gm_as('23');
select is((select count(*)::int from public.read_marks(g('W')) where user_id = u('22')), 0,
          'a current member sees no read mark of a departed one');
select is((select count(*)::int from public.read_marks(g('W')) where user_id = u('24')), 1,
          'control: she sees dov''s');
reset role;
select gm_as('22');
select is((select count(*)::int from public.read_marks(g('W'))), 0, 'a departed member sees no read marks at all');
reset role;

-- replies: a current member can quote only what she can read
select gm_as('23');
select throws_ok(format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'gmwin re', %L)$$,
                        g('W'), u('23'), 'e3e30000-0000-0000-0000-0000000000a1'),
                 '42501', null, 'cai cannot reply to a message from before her history');
select lives_ok(format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'gmwin re', %L)$$,
                       g('W'), u('23'), 'e3e30000-0000-0000-0000-0000000000a4'),
                'control: she can reply to one in her window');
reset role;
select gm_as('27');
select throws_ok(format($$insert into public.messages(conversation_id, sender_id, body, reply_to) values (%L, %L, 'gmwin re', %L)$$,
                        g('W'), u('27'), 'e3e30000-0000-0000-0000-0000000000a2'),
                 '42501', null, 'gus cannot reply to a message from his gap');
reset role;
select gm_as('22');
select throws_ok(format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'gmwin after')$$, g('W'), u('22')),
                 '42501', null, 'bea, departed, cannot send');
reset role;

-- the group picture: current members only
create function w_avatar() returns bigint language sql as $$
  select count(*) from storage.objects where bucket_id = 'avatars' and name = 'group/' || g('W') || '/1.jpg'
$$;
grant execute on function w_avatar() to authenticated;
select gm_as('23'); select is(w_avatar(), 1::bigint, 'control: cai sees the group picture'); reset role;
select gm_as('22'); select is(w_avatar(), 0::bigint, 'bea, departed, does not');
select throws_ok(format($$select public.set_group_avatar(%L, 'group/' || %L || '/2.jpg')$$, g('W'), g('W')), null, null,
                 'nor can she change it');
reset role;

-- who sees whom: the caller's readable window must overlap the other's presence
select gm_as('22'); select is(w_people(), '21,22-,24,27-', 'bea (departed) sees who overlapped her time, never cai, fay or gus''s return'); reset role;
select gm_as('23'); select is(w_people(), '21,23,24,26,27', 'cai (no history) sees who is there from her start, not bea nor gus''s old row'); reset role;
select gm_as('26'); select is(w_people(), '21,22-,23,24,26,27-,27', 'fay (with history) sees everyone who was ever in W'); reset role;
select gm_as('22'); select is(w_profiles(), '21,22,24,27', 'bea reads profiles of overlapping members only'); reset role;
select gm_as('23'); select is(w_profiles(), '21,23,24,26,27', 'cai never reads bea''s profile'); reset role;
select gm_as('26'); select is(w_profiles(), '21,22,23,24,26,27', 'fay reads everyone''s'); reset role;

-- reach counts current sharing only: bea and dov share only W, where bea left.
select gm_as('22');
select throws_ok(format('select public.start_direct_conversation(%L)', u('24')), null, null,
                 'bea no longer reaches dov through W');
reset role;
select gm_as('23');
select throws_ok(format('select public.start_direct_conversation(%L)', u('22')), null, null,
                 'nor does cai, current, reach bea, who left W');
select lives_ok(format('select public.start_direct_conversation(%L)', u('24')), 'control: cai, current, reaches dov through W');
reset role;

-- typing: and reads: channels: current members only (Realtime authorises a
-- join through these policies; probes as in read_status_test.sql)
create function can_send(topic text, ext text) returns boolean
language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', coalesce(topic, ''), true);
  insert into realtime.messages (topic, extension, payload, event, private)
  values (coalesce(topic, ''), ext, '{}'::jsonb, 'probe', true);
  return true;
exception when insufficient_privilege then
  return false;
end $$;
create function can_receive(topic text, ext text) returns boolean
language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', coalesce(topic, ''), true);
  return exists (select 1 from realtime.messages m
                  where m.extension = ext and m.event = 'fixture');
end $$;
grant execute on function can_send(text, text), can_receive(text, text) to authenticated;
insert into realtime.messages (topic, extension, payload, event, private) values
  ('fixture', 'broadcast', '{}'::jsonb, 'fixture', true);
select gm_as('23');
select ok(can_receive('typing:' || g('W'), 'broadcast'), 'control: cai joins W''s typing: channel');
select ok(can_receive('reads:' || g('W'), 'broadcast'), 'control: cai joins W''s reads: channel');
reset role;
select gm_as('22');
select ok(not can_receive('typing:' || g('W'), 'broadcast'), 'bea, departed, cannot join W''s typing: channel');
select ok(not can_send('typing:' || g('W'), 'broadcast'), 'nor type into it');
select ok(not can_receive('reads:' || g('W'), 'broadcast'), 'nor join W''s reads: channel');
reset role;

-- push: a new message reaches current members only
do $$
declare n text;
begin
  foreach n in array array['22','23'] loop
    perform gm_as(n);
    perform public.register_device_token('gm-token-' || n, 'android');
    execute 'reset role';
  end loop;
end $$;
insert into public.messages(id, conversation_id, sender_id, body)
values ('e3e30000-0000-0000-0000-0000000000a9', g('W'), u('21'), 'gmwin push');
select is((select string_agg(right(user_id::text, 2), ',' order by user_id)
             from app_private.push_targets_for_message('e3e30000-0000-0000-0000-0000000000a9')
            where user_id in (u('22'), u('23'))),
          '23', 'push goes to cai, never to bea who left');

select * from finish();
rollback;
