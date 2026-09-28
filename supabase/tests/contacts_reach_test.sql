begin;
select plan(105);

-- Contacts, reach and the exact-tag lookup (v0.22.0).
--
-- Contract (docs/SECURITY.md, docs/DECISIONS.md 2026-09-28):
--   can_reach(other) = self OR shares a conversation (current membership) OR
--     the caller saved other as a contact OR the caller found other by exact
--     tag (app_private.tag_finds, written by find_by_tag, cleared when the
--     FOUND member changes their tag). Every relation is one-way where it is
--     one-way: someone who saved you, or found you, is not reachable by that.
--   contacts(owner_id, contact_id): owner-only read/insert/delete; inserting
--     needs the contact allowlisted AND reachable.
--   start_direct_conversation, start_group_conversation (every invitee, all
--     or nothing) and last_seen_of need can_reach.
--   find_by_tag(tag): exact match after folding (case, Turkish/Latin letters,
--     a leading @); never prefix or wildcard; at most one row; 20 calls per
--     10 minutes per member, then RLMT1. is_tag_available: 60 per 10 minutes,
--     a separate budget.
--
-- Fixtures, all relative to ann (the caller). Each negative fails ONE gate:
--   bob  shares a 1:1 with ann             cat  shares a group with ann
--   dan  ann saved dan                     eve  ann found eve by tag
--   fin  allowlisted, active stranger      gil  saved ann (not the reverse)
--   hux  found ann by tag (not reverse)    ida  was in a group with ann, removed
--   jon  allowlisted, active stranger      kim, mo  fresh callers for budgets
--   nia  ann found nia by tag (used only to start a chat)
--   lou  ann's chat partner, session revoked
--   robo signed in, NOT allowlisted; ann found robo by tag and shares a chat
--        with robo, so only the allowlist gate refuses robo as a contact.

-- 0 catalog, checked before this file creates any helper function ------------
select is_empty(
  $$select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app_private') and p.prosecdef
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
       and (p.proconfig is null or not ('search_path=""' = any (p.proconfig)))$$,
  'every security definer function in public and app_private pins search_path to empty');
select is_empty(
  $$select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')$$,
  'anon may execute no function in public');
select ok(has_function_privilege('authenticated', 'public.find_by_tag(text)', 'EXECUTE'),
          'members may call find_by_tag');
select ok(not has_schema_privilege('authenticated', 'app_private', 'USAGE')
      and not has_schema_privilege('anon', 'app_private', 'USAGE'),
          'clients cannot use app_private, so can_reach is not theirs to call');
select ok(not has_table_privilege('authenticated', 'app_private.tag_finds', 'SELECT')
      and not has_table_privilege('authenticated', 'app_private.tag_finds', 'INSERT')
      and not has_table_privilege('authenticated', 'app_private.tag_finds', 'UPDATE')
      and not has_table_privilege('authenticated', 'app_private.tag_finds', 'DELETE'),
          'authenticated holds no privilege on tag_finds');
select ok(not has_table_privilege('anon', 'app_private.tag_finds', 'SELECT')
      and not has_table_privilege('anon', 'app_private.tag_finds', 'INSERT')
      and not has_table_privilege('anon', 'app_private.tag_finds', 'UPDATE')
      and not has_table_privilege('anon', 'app_private.tag_finds', 'DELETE'),
          'anon holds no privilege on tag_finds');
select ok(not has_table_privilege('authenticated', 'app_private.tag_lookups', 'SELECT')
      and not has_table_privilege('authenticated', 'app_private.tag_lookups', 'INSERT')
      and not has_table_privilege('authenticated', 'app_private.tag_lookups', 'UPDATE')
      and not has_table_privilege('authenticated', 'app_private.tag_lookups', 'DELETE'),
          'authenticated holds no privilege on tag_lookups');
select ok(not has_table_privilege('anon', 'app_private.tag_lookups', 'SELECT')
      and not has_table_privilege('anon', 'app_private.tag_lookups', 'INSERT')
      and not has_table_privilege('anon', 'app_private.tag_lookups', 'UPDATE')
      and not has_table_privilege('anon', 'app_private.tag_lookups', 'DELETE'),
          'anon holds no privilege on tag_lookups');
select table_privs_are('public', 'contacts', 'authenticated', array['DELETE', 'INSERT', 'SELECT'],
                       'members may read, insert and delete contacts, never update');
select table_privs_are('public', 'contacts', 'anon', array[]::text[], 'anon holds nothing on contacts');
select ok((select relrowsecurity from pg_class where oid = 'public.contacts'::regclass),
          'contacts has row security enabled');

-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000c0a00001', 'ann@reach.test', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000c0a00002', 'bob@reach.test', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000c0a00003', 'cat@reach.test', now(), '{"full_name":"Cat"}'),
  ('00000000-0000-0000-0000-0000c0a00004', 'dan@reach.test', now(), '{"full_name":"Dan"}'),
  ('00000000-0000-0000-0000-0000c0a00005', 'eve@reach.test', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-0000c0a00006', 'fin@reach.test', now(), '{"full_name":"Fin"}'),
  ('00000000-0000-0000-0000-0000c0a00007', 'gil@reach.test', now(), '{"full_name":"Gil"}'),
  ('00000000-0000-0000-0000-0000c0a00008', 'hux@reach.test', now(), '{"full_name":"Hux"}'),
  ('00000000-0000-0000-0000-0000c0a00009', 'ida@reach.test', now(), '{"full_name":"Ida"}'),
  ('00000000-0000-0000-0000-0000c0a0000a', 'jon@reach.test', now(), '{"full_name":"Jon"}'),
  ('00000000-0000-0000-0000-0000c0a0000b', 'kim@reach.test', now(), '{"full_name":"Kim"}'),
  ('00000000-0000-0000-0000-0000c0a0000c', 'lou@reach.test', now(), '{"full_name":"Lou"}'),
  ('00000000-0000-0000-0000-0000c0a0000d', 'mo@reach.test', now(), '{"full_name":"Mo"}'),
  ('00000000-0000-0000-0000-0000c0a0000e', 'nia@reach.test', now(), '{"full_name":"Nia"}'),
  ('00000000-0000-0000-0000-0000c0a000fe', 'robo@reach.test', now(), '{"full_name":"Robo"}');
insert into app_private.allowlist(email) values
  ('ann@reach.test'), ('bob@reach.test'), ('cat@reach.test'), ('dan@reach.test'),
  ('eve@reach.test'), ('fin@reach.test'), ('gil@reach.test'), ('hux@reach.test'),
  ('ida@reach.test'), ('jon@reach.test'), ('kim@reach.test'), ('lou@reach.test'),
  ('mo@reach.test'), ('nia@reach.test');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('5e5e0000-0000-0000-0000-' || right(id::text, 12))::uuid, id, now(), now()
    from auth.users where email like '%@reach.test';

-- Known tags. Set before any tag find exists, so no rename clears anything.
update public.profiles p set tag = t.tag
  from (values ('00000000-0000-0000-0000-0000c0a00001'::uuid, 'cr_ann'),
               ('00000000-0000-0000-0000-0000c0a00002'::uuid, 'cr_bob'),
               ('00000000-0000-0000-0000-0000c0a00003'::uuid, 'cr_cat'),
               ('00000000-0000-0000-0000-0000c0a00004'::uuid, 'cr_dan'),
               ('00000000-0000-0000-0000-0000c0a00005'::uuid, 'cr_eve'),
               ('00000000-0000-0000-0000-0000c0a00006'::uuid, 'crsule'),
               ('00000000-0000-0000-0000-0000c0a00007'::uuid, 'cr_gil'),
               ('00000000-0000-0000-0000-0000c0a00008'::uuid, 'cr_hux'),
               ('00000000-0000-0000-0000-0000c0a00009'::uuid, 'crirmak'),
               ('00000000-0000-0000-0000-0000c0a0000a'::uuid, 'cr_jon'),
               ('00000000-0000-0000-0000-0000c0a0000b'::uuid, 'cr_kim'),
               ('00000000-0000-0000-0000-0000c0a0000c'::uuid, 'cr_lou'),
               ('00000000-0000-0000-0000-0000c0a0000d'::uuid, 'cr_mo'),
               ('00000000-0000-0000-0000-0000c0a0000e'::uuid, 'cr_nia'),
               ('00000000-0000-0000-0000-0000c0a000fe'::uuid, 'cr_robo')) t(uid, tag)
 where p.user_id = t.uid;

create or replace function test_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', '5e5e0000-0000-0000-0000-' || right(uid::text, 12))::text, true);
  execute 'set local role authenticated';
end $$;

-- can_reach as [caller] sees it, asked by the setup role (clients cannot call
-- it). Only the claims change; the role stays the setup role.
create or replace function reach(caller uuid, other uuid) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', caller, 'role', 'authenticated',
      'session_id', '5e5e0000-0000-0000-0000-' || right(caller::text, 12))::text, true);
  r := app_private.can_reach(other);
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

-- A contacts insert as the current role: 'ok', or the SQLSTATE it raised.
create or replace function try_add(owner uuid, contact uuid) returns text language plpgsql as $$
begin
  insert into public.contacts(owner_id, contact_id) values (owner, contact);
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Rows deleted from contacts by the current role.
create or replace function try_remove(owner uuid, contact uuid) returns bigint language plpgsql as $$
declare n bigint;
begin
  delete from public.contacts where owner_id = owner and contact_id = contact;
  get diagnostics n = row_count;
  return n;
end $$;

-- find_by_tag as the current role: the found user id, or null for no row.
create or replace function found(t text) returns uuid language sql as $$
  select user_id from public.find_by_tag(t)
$$;
grant execute on function test_as(uuid), try_add(uuid, uuid), try_remove(uuid, uuid), found(text)
  to authenticated;

do $$
declare u record;
begin
  for u in select id from auth.users where email like '%@reach.test' loop
    perform test_as(u.id);
    perform public.activate_session();
    execute 'reset role';
  end loop;
end $$;

-- Relations, planted as the setup role (the client paths are tested below).
insert into public.conversations(id, title) values
  ('c0a0c000-0000-0000-0000-000000000001', null),     -- ann + bob
  ('c0a0c000-0000-0000-0000-000000000002', 'group'),  -- ann + cat (+ ida, removed below)
  ('c0a0c000-0000-0000-0000-000000000003', null),     -- ann + lou
  ('c0a0c000-0000-0000-0000-000000000004', null);     -- ann + robo
insert into public.conversation_members(conversation_id, user_id) values
  ('c0a0c000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000c0a00001'),
  ('c0a0c000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000c0a00002'),
  ('c0a0c000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000c0a00001'),
  ('c0a0c000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000c0a00003'),
  ('c0a0c000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000c0a00009'),
  ('c0a0c000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000c0a00001'),
  ('c0a0c000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000c0a0000c'),
  ('c0a0c000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000c0a00001'),
  ('c0a0c000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000c0a000fe');
delete from public.conversation_members
 where conversation_id = 'c0a0c000-0000-0000-0000-000000000002'
   and user_id = '00000000-0000-0000-0000-0000c0a00009';
insert into public.contacts(owner_id, contact_id) values
  ('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00004'),  -- ann saved dan
  ('00000000-0000-0000-0000-0000c0a00007', '00000000-0000-0000-0000-0000c0a00001'),  -- gil saved ann
  ('00000000-0000-0000-0000-0000c0a0000c', '00000000-0000-0000-0000-0000c0a00001');  -- lou saved ann
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00005'),  -- ann found eve
  ('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a0000e'),  -- ann found nia
  ('00000000-0000-0000-0000-0000c0a00008', '00000000-0000-0000-0000-0000c0a00001'),  -- hux found ann
  ('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a000fe'),  -- ann found robo
  ('00000000-0000-0000-0000-0000c0a0000c', '00000000-0000-0000-0000-0000c0a00002');  -- lou found bob
-- lou's phone is revoked (session gate only; lou stays allowlisted).
delete from auth.sessions where user_id = '00000000-0000-0000-0000-0000c0a0000c';

-- 1 can_reach, one branch at a time ------------------------------------------
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00001'), true,
          'reach: yourself');
select is(reach('00000000-0000-0000-0000-0000c0a00006', '00000000-0000-0000-0000-0000c0a00006'), true,
          'reach: yourself, with no chat, contact or find at all');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00002'), true,
          'reach: someone you share a 1:1 with');
select is(reach('00000000-0000-0000-0000-0000c0a00002', '00000000-0000-0000-0000-0000c0a00001'), true,
          'reach: sharing a conversation works both ways');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00003'), true,
          'reach: someone you share a group with');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00004'), true,
          'reach: a contact you saved');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00005'), true,
          'reach: someone you found by exact tag');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00006'), false,
          'no reach: an allowlisted, active stranger');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00007'), false,
          'no reach: someone who saved you (contacts are one-way)');
select is(reach('00000000-0000-0000-0000-0000c0a00004', '00000000-0000-0000-0000-0000c0a00001'), false,
          'no reach: the contact you saved cannot reach you back by that');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00008'), false,
          'no reach: someone who found you by tag (finds are one-way)');
select is(reach('00000000-0000-0000-0000-0000c0a00005', '00000000-0000-0000-0000-0000c0a00001'), false,
          'no reach: the member you found cannot reach you back by that');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00009'), false,
          'no reach: someone who left the only group you shared');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-00000000dead'), false,
          'no reach: an unknown id');

-- 5 contacts: owner only, allowlisted and reachable ------------------------------
select test_as('00000000-0000-0000-0000-0000c0a00001');
select is(try_add('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00005'), 'ok',
          'ann saves eve, whom she found by tag');
select is(try_add('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00002'), 'ok',
          'ann saves bob, her chat partner');
select is(try_add('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a0000a'), '42501',
          'ann cannot save jon, an allowlisted stranger she cannot reach');
select is(try_add('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00007'), '42501',
          'ann cannot save gil, who only saved her');
select is(try_add('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a000fe'), '42501',
          'ann cannot save robo: reachable, but not allowlisted');
select isnt(try_add('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00001'), 'ok',
          'ann cannot save herself');
select is(try_add('00000000-0000-0000-0000-0000c0a00002', '00000000-0000-0000-0000-0000c0a00001'), '42501',
          'ann cannot write a row owned by bob');
select is((select count(*) from public.contacts), 3::bigint,
          'ann reads exactly her own three rows (dan, eve, bob)');
select is((select count(*) from public.contacts where contact_id = '00000000-0000-0000-0000-0000c0a00001'),
          0::bigint, 'ann cannot read the rows of those who saved her');
select is(try_remove('00000000-0000-0000-0000-0000c0a00007', '00000000-0000-0000-0000-0000c0a00001'), 0::bigint,
          'ann cannot delete gil''s row');
select is(try_remove('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a00002'), 1::bigint,
          'ann removes bob from her contacts');
select throws_ok($$update public.contacts set contact_id = '00000000-0000-0000-0000-0000c0a0000a'$$,
                 '42501', null, 'a contact row cannot be rewritten to point elsewhere');
reset role;
select is((select count(*) from public.contacts where owner_id = '00000000-0000-0000-0000-0000c0a00007'),
          1::bigint, 'gil''s row survived ann''s delete');
select is((select count(*) from public.contacts where owner_id = '00000000-0000-0000-0000-0000c0a00001'
             and contact_id = '00000000-0000-0000-0000-0000c0a00002'), 0::bigint,
          'bob''s row is gone');
select is(reach('00000000-0000-0000-0000-0000c0a00001', '00000000-0000-0000-0000-0000c0a0000a'), false,
          'the refused insert gave ann no reach to jon');
-- lou: allowlisted, a chat partner of ann, with a row saving ann -- but her
-- session is revoked, so only the app-access gate is in the way.
select test_as('00000000-0000-0000-0000-0000c0a0000c');
select is((select count(*) from public.contacts), 0::bigint, 'a revoked member reads no contacts, not even her own');
select is(try_add('00000000-0000-0000-0000-0000c0a0000c', '00000000-0000-0000-0000-0000c0a00002'), '42501',
          'a revoked member cannot save bob, allowlisted and reachable by her find');
reset role;

-- 2 start_direct_conversation needs reach --------------------------------------
create temp table _n (before bigint);
grant select on _n to authenticated;
insert into _n select count(*) from public.conversations;
select test_as('00000000-0000-0000-0000-0000c0a00001');
select throws_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000c0a00006')$$,
                 '42501', null, 'ann cannot start a chat with a stranger');
select throws_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000c0a00007')$$,
                 '42501', null, 'ann cannot start a chat with someone who only saved her');
select throws_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000c0a00008')$$,
                 '42501', null, 'ann cannot start a chat with someone who only found her');
select throws_ok($$select public.start_direct_conversation('00000000-0000-0000-0000-0000c0a00009')$$,
                 '42501', null, 'ann cannot start a chat with someone who left their only group');
-- 3 start_group_conversation: every invitee, all or nothing ----------------------
select throws_ok($$select public.start_group_conversation('cr-all-or-nothing',
                   array['00000000-0000-0000-0000-0000c0a00005', '00000000-0000-0000-0000-0000c0a00006']::uuid[])$$,
                 '42501', null, 'a group with one unreachable invitee (last) is refused');
select throws_ok($$select public.start_group_conversation('cr-all-or-nothing',
                   array['00000000-0000-0000-0000-0000c0a00006', '00000000-0000-0000-0000-0000c0a00005']::uuid[])$$,
                 '42501', null, 'a group with one unreachable invitee (first) is refused');
select throws_ok($$select public.start_group_conversation('cr-all-or-nothing',
                   array['00000000-0000-0000-0000-0000c0a00004', '00000000-0000-0000-0000-0000c0a00007']::uuid[])$$,
                 '42501', null, 'a group inviting someone who only saved the creator is refused');
reset role;
select is((select count(*) from public.conversations), (select before from _n),
          'no refused call left a conversation behind');
select is((select count(*) from public.conversations where title = 'cr-all-or-nothing'), 0::bigint,
          'no partial group exists');
select test_as('00000000-0000-0000-0000-0000c0a00001');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000c0a0000e'), null,
            'control: ann starts a chat with nia, whom she found by tag');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000c0a00004'), null,
            'control: ann starts a chat with dan, her contact');
select is(public.start_direct_conversation('00000000-0000-0000-0000-0000c0a0000e'),
          (select c.id from public.conversations c
             join public.conversation_members m on m.conversation_id = c.id
            where m.user_id = '00000000-0000-0000-0000-0000c0a0000e'),
          'control: starting again reopens the same chat');
select isnt(public.start_group_conversation('cr-reachable',
              array['00000000-0000-0000-0000-0000c0a00003', '00000000-0000-0000-0000-0000c0a00004']::uuid[]),
            null, 'control: a group of reachable invitees is created');
reset role;
select is((select count(*) from public.conversation_members m join public.conversations c on c.id = m.conversation_id
            where c.title = 'cr-reachable'), 3::bigint, 'control: the group holds ann and both invitees');

-- 4 last_seen_of needs reach ----------------------------------------------------
insert into app_private.last_seen(user_id, seen_at) values
  ('00000000-0000-0000-0000-0000c0a00006', '2026-09-01 10:00+00'),
  ('00000000-0000-0000-0000-0000c0a00003', '2026-09-02 10:00+00');
select test_as('00000000-0000-0000-0000-0000c0a00001');
select is(public.last_seen_of('00000000-0000-0000-0000-0000c0a00006'), null,
          'last seen: a stranger''s time is null');
select is(public.last_seen_of('00000000-0000-0000-0000-0000c0a00003'), '2026-09-02 10:00+00'::timestamptz,
          'last seen control: a group partner''s time is shown');
reset role;

-- 6 find_by_tag: exact match after folding ----------------------------------------
reset role;
select test_as('00000000-0000-0000-0000-0000c0a0000a');
select is(found('crsule'), '00000000-0000-0000-0000-0000c0a00006'::uuid, 'the exact tag is found');
select is((select count(*) from public.find_by_tag('crsule')), 1::bigint, 'one row, never more');
select is(found('CRSULE'), '00000000-0000-0000-0000-0000c0a00006'::uuid, 'case is folded');
select is(found('@crsule'), '00000000-0000-0000-0000-0000c0a00006'::uuid, 'a leading @ is ignored');
select is(found('CRŞULE'), '00000000-0000-0000-0000-0000c0a00006'::uuid, 'Turkish Ş folds to s');
select is(found('crırmak'), '00000000-0000-0000-0000-0000c0a00009'::uuid, 'Turkish dotless ı folds to i');
select is(found('CRİRMAK'), '00000000-0000-0000-0000-0000c0a00009'::uuid, 'Turkish dotted İ folds to i');
select is(found('crsul'), null, 'a prefix finds nobody');
select is(found('crsule2'), null, 'a longer tag finds nobody');
select is(found('crs%'), null, 'a % wildcard finds nobody');
select is(found('crsul_'), null, 'a _ wildcard finds nobody');
select is(found('cr_robo'), null, 'a non-allowlisted account is never found');
select is((select count(*) from public.profiles where user_id = '00000000-0000-0000-0000-0000c0a00006'),
          0::bigint, 'a tag find alone does not open the profiles row');
reset role;
select is((select count(*) from app_private.tag_finds
            where finder = '00000000-0000-0000-0000-0000c0a0000a'
              and found_id = '00000000-0000-0000-0000-0000c0a00006'), 1::bigint,
          'the find is remembered once');
select is((select count(*) from app_private.tag_finds
            where finder = '00000000-0000-0000-0000-0000c0a0000a'
              and found_id <> '00000000-0000-0000-0000-0000c0a0000a'), 2::bigint,
          'only real hits are remembered (fin and ida), no miss');
select is(reach('00000000-0000-0000-0000-0000c0a0000a', '00000000-0000-0000-0000-0000c0a00006'), true,
          'the find gives jon reach to fin');
select test_as('00000000-0000-0000-0000-0000c0a0000a');
select is(try_add('00000000-0000-0000-0000-0000c0a0000a', '00000000-0000-0000-0000-0000c0a00006'), 'ok',
          'after the find jon may save fin');
select is(try_remove('00000000-0000-0000-0000-0000c0a0000a', '00000000-0000-0000-0000-0000c0a00006'), 1::bigint,
          'and remove fin again');
reset role;

-- 7 a tag find is forgotten when the FOUND member changes their tag ---------------
-- Not on a same-value save, not on a name change, not when the finder renames,
-- and never touching contacts.
select test_as('00000000-0000-0000-0000-0000c0a00005');
update public.profiles set tag = 'cr_eve' where user_id = auth.uid();
update public.profiles set display_name = 'Eve E' where user_id = auth.uid();
reset role;
select is((select count(*) from app_private.tag_finds
            where found_id = '00000000-0000-0000-0000-0000c0a00005'), 1::bigint,
          'a same-tag save and a name change keep the find of eve');
select test_as('00000000-0000-0000-0000-0000c0a00001');
update public.profiles set tag = 'cr_ann_new' where user_id = auth.uid();
reset role;
select is((select count(*) from app_private.tag_finds where finder = '00000000-0000-0000-0000-0000c0a00001'),
          3::bigint, 'the finder renaming keeps her own finds (eve, nia, robo)');
select is((select count(*) from app_private.tag_finds where found_id = '00000000-0000-0000-0000-0000c0a00001'),
          0::bigint, 'ann renaming forgets that hux found her');
select is(reach('00000000-0000-0000-0000-0000c0a00008', '00000000-0000-0000-0000-0000c0a00001'), false,
          'hux no longer reaches ann by the old find');
select test_as('00000000-0000-0000-0000-0000c0a00006');
update public.profiles set tag = 'crsule_new' where user_id = auth.uid();
reset role;
select is((select count(*) from app_private.tag_finds where found_id = '00000000-0000-0000-0000-0000c0a00006'),
          0::bigint, 'fin renaming forgets every find of fin');
select is(reach('00000000-0000-0000-0000-0000c0a0000a', '00000000-0000-0000-0000-0000c0a00006'), false,
          'jon no longer reaches fin');
select is((select count(*) from app_private.tag_finds where found_id = '00000000-0000-0000-0000-0000c0a00009'),
          1::bigint, 'fin renaming left the find of ida alone');
select test_as('00000000-0000-0000-0000-0000c0a00004');
update public.profiles set tag = 'cr_dan_new' where user_id = auth.uid();
reset role;
select is((select count(*) from public.contacts where owner_id = '00000000-0000-0000-0000-0000c0a00001'
             and contact_id = '00000000-0000-0000-0000-0000c0a00004'), 1::bigint,
          'a contact who renames stays a contact');
select test_as('00000000-0000-0000-0000-0000c0a0000a');
select is(found('crsule'), null, 'the old tag finds nobody now');
select is(found('crsule_new'), '00000000-0000-0000-0000-0000c0a00006'::uuid, 'the new tag finds fin again');
reset role;

-- 8 budgets: 20 finds and 60 availability checks per 10 minutes, separately ----
-- Everything is one transaction, so every call is at the same now().
select test_as('00000000-0000-0000-0000-0000c0a0000b');
select is((select count(*) from generate_series(1, 19) g, lateral public.find_by_tag('cr_nobody_' || g)), 0::bigint,
          'kim: 19 misses are answered');
select is(found('cr_bob'), '00000000-0000-0000-0000-0000c0a00002'::uuid, 'kim: the 20th find is answered');
select throws_ok($$select * from public.find_by_tag('cr_bob')$$, 'RLMT1', null, 'kim: the 21st find is refused');
select throws_ok($$select * from public.find_by_tag('cr_cat')$$, 'RLMT1', null, 'kim: and the 22nd');
select is((select count(*) from generate_series(1, 60) g where public.is_tag_available('cr_free_' || g)), 60::bigint,
          'kim: 60 availability checks still answer while finds are spent');
select throws_ok($$select public.is_tag_available('cr_free_x')$$, 'RLMT1', null,
                 'kim: the 61st availability check is refused');
reset role;
select test_as('00000000-0000-0000-0000-0000c0a0000d');
select is(found('cr_bob'), '00000000-0000-0000-0000-0000c0a00002'::uuid,
          'mo: kim''s spent budget is not mo''s');
select is((select count(*) from generate_series(1, 60) g where public.is_tag_available('cr_free_' || g)), 60::bigint,
          'mo: 60 availability checks answer');
select throws_ok($$select public.is_tag_available('cr_free_x')$$, 'RLMT1', null,
                 'mo: the 61st availability check is refused');
select is(found('cr_cat'), '00000000-0000-0000-0000-0000c0a00003'::uuid,
          'mo: finds still answer while availability is spent');
reset role;
-- The window: calls 9 minutes old still count; calls 11 minutes old do not.
update app_private.tag_lookups set called_at = now() - interval '9 minutes'
 where user_id = '00000000-0000-0000-0000-0000c0a0000b';
select test_as('00000000-0000-0000-0000-0000c0a0000b');
select throws_ok($$select * from public.find_by_tag('cr_bob')$$, 'RLMT1', null,
                 'kim: finds from 9 minutes ago still count');
reset role;
update app_private.tag_lookups set called_at = now() - interval '11 minutes'
 where user_id = '00000000-0000-0000-0000-0000c0a0000b';
select test_as('00000000-0000-0000-0000-0000c0a0000b');
select is(found('cr_bob'), '00000000-0000-0000-0000-0000c0a00002'::uuid,
          'kim: finds older than 10 minutes no longer count');
select is(public.is_tag_available('cr_free_y'), true,
          'kim: nor do availability checks older than 10 minutes');
reset role;

-- 9 no app access, no lookup --------------------------------------------------
-- Refused either by an error or by an empty answer; never a row, never a find.
create or replace function try_found(t text) returns text language plpgsql as $$
declare r uuid;
begin
  select user_id into r from public.find_by_tag(t);
  return coalesce(r::text, 'none');
exception when others then
  return sqlstate;
end $$;
grant execute on function try_found(text) to authenticated;
select test_as('00000000-0000-0000-0000-0000c0a0000c');
select ok(try_found('cr_bob') in ('none', '42501'), 'a revoked member finds nobody by tag');
reset role;
select test_as('00000000-0000-0000-0000-0000c0a000fe');
select ok(try_found('cr_bob') in ('none', '42501'), 'a non-allowlisted account finds nobody by tag');
reset role;
select is((select count(*) from app_private.tag_finds where finder in (
             '00000000-0000-0000-0000-0000c0a0000c', '00000000-0000-0000-0000-0000c0a000fe')
             and found_id <> '00000000-0000-0000-0000-0000c0a00002'),
          0::bigint, 'the refused searches remembered nothing');

-- 10 a bulk delete (no WHERE: only the delete policy applies) touches only
-- the caller's own rows
create or replace function wipe() returns bigint language plpgsql as $$
declare n bigint;
begin
  delete from public.contacts;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function wipe() to authenticated;
select test_as('00000000-0000-0000-0000-0000c0a0000c');
select is(wipe(), 0::bigint, 'lou, revoked, cannot delete even her own row');
reset role;
select test_as('00000000-0000-0000-0000-0000c0a00001');
select is(wipe(), 2::bigint, 'ann''s bulk delete removes her own two rows (dan, eve)');
reset role;
select is((select count(*) from public.contacts where contact_id = '00000000-0000-0000-0000-0000c0a00001'),
          2::bigint, 'the rows of gil and lou, who saved ann, survive it');

select * from finish();
rollback;
