begin;
select plan(57);

-- Group conversations and self-service display names (v0.3).
--
-- Two contracts are under test here.
--
-- 1. public.start_group_conversation(title, members) refuses more than it
--    accepts, and every refusal is whole: an invitee the caller may not add
--    must fail the CALL, not be quietly dropped from the group. The negative
--    fixtures are therefore split so each one fails exactly ONE gate --
--    kurt is confirmed but not allowlisted, lena is allowlisted but not
--    confirmed, ghost does not exist at all. A single "stranger" fixture
--    would leave either half of that rule deletable with the suite green.
--
-- 2. A member may rename ITSELF and nothing else. The row is pinned by
--    profiles_update_own, the column by a grant on display_name alone. Those
--    are different mechanisms and they fail differently: a forbidden ROW is
--    invisible and updates nothing, a forbidden COLUMN raises 42501.
--
-- Everything is scoped to the fixtures below: this database is not empty
-- (the integration suites leave rows behind), so unscoped counts lie.

-- fixtures -----------------------------------------------------------------
-- gina, hugo, iris  allowlisted, confirmed, active  -- the group of three
-- jade              allowlisted, confirmed, active  -- never invited
-- kurt              confirmed, NOT allowlisted
-- lena              allowlisted, NOT confirmed
-- mack              allowlisted, confirmed, signed in, never activated
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000aa01', 'gina@group.test', now(), '{"full_name":"Gina"}'),
  ('00000000-0000-0000-0000-00000000aa02', 'hugo@group.test', now(), '{"full_name":"Hugo"}'),
  ('00000000-0000-0000-0000-00000000aa03', 'iris@group.test', now(), '{"full_name":"Iris"}'),
  ('00000000-0000-0000-0000-00000000aa04', 'jade@group.test', now(), '{"full_name":"Jade"}'),
  ('00000000-0000-0000-0000-00000000aa05', 'kurt@group.test', now(), '{"full_name":"Kurt"}'),
  ('00000000-0000-0000-0000-00000000aa06', 'lena@group.test', null,  '{"full_name":"Lena"}'),
  ('00000000-0000-0000-0000-00000000aa07', 'mack@group.test', now(), '{"full_name":"Mack"}');
insert into app_private.allowlist(email) values
  ('gina@group.test'), ('hugo@group.test'), ('iris@group.test'),
  ('jade@group.test'), ('lena@group.test'), ('mack@group.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ea000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000aa01', now(), now()),
  ('ea000000-0000-0000-0000-00000000aa02', '00000000-0000-0000-0000-00000000aa02', now(), now()),
  ('ea000000-0000-0000-0000-00000000aa03', '00000000-0000-0000-0000-00000000aa03', now(), now()),
  ('ea000000-0000-0000-0000-00000000aa04', '00000000-0000-0000-0000-00000000aa04', now(), now()),
  ('ea000000-0000-0000-0000-00000000aa05', '00000000-0000-0000-0000-00000000aa05', now(), now()),
  ('ea000000-0000-0000-0000-00000000aa07', '00000000-0000-0000-0000-00000000aa07', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Renaming is checked by ROW COUNT, not by an error: a row the UPDATE policy
-- hides is simply not there to update, and `update ... where somebody else`
-- succeeds while changing nothing. security invoker, so RLS applies to the
-- caller and not to the owner of this function.
create or replace function test_rename(target uuid, newname text)
returns bigint language plpgsql security invoker as $$
declare n bigint;
begin
  update public.profiles set display_name = newname
   where target is null or user_id = target;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function test_rename(uuid, text) to authenticated;

select test_as('00000000-0000-0000-0000-00000000aa01', 'ea000000-0000-0000-0000-00000000aa01');
select is(public.activate_session(), true, 'gina is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000aa02', 'ea000000-0000-0000-0000-00000000aa02');
select is(public.activate_session(), true, 'hugo is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000aa03', 'ea000000-0000-0000-0000-00000000aa03');
select is(public.activate_session(), true, 'iris is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000aa04', 'ea000000-0000-0000-0000-00000000aa04');
select is(public.activate_session(), true, 'jade is active');
reset role;

-- 1 who may call it at all ---------------------------------------------------
set local role anon;
select throws_ok(
  $$select public.start_group_conversation('anon group', array['00000000-0000-0000-0000-00000000aa02']::uuid[])$$,
  'permission denied for function start_group_conversation', 'anon cannot start a group');
reset role;

-- mack is allowlisted and signed in, but has never claimed a device.
select test_as('00000000-0000-0000-0000-00000000aa07', 'ea000000-0000-0000-0000-00000000aa07');
select throws_ok(
  $$select public.start_group_conversation('pgtap-no-device', array['00000000-0000-0000-0000-00000000aa02']::uuid[])$$,
  '42501', null, 'a caller without an active device cannot start a group');
reset role;

-- 2 the arguments -----------------------------------------------------------
select test_as('00000000-0000-0000-0000-00000000aa01', 'ea000000-0000-0000-0000-00000000aa01');
select throws_ok(
  $$select public.start_group_conversation('', array['00000000-0000-0000-0000-00000000aa02']::uuid[])$$,
  '22023', null, 'an empty title is refused');
select throws_ok(
  $$select public.start_group_conversation('   ', array['00000000-0000-0000-0000-00000000aa02']::uuid[])$$,
  '22023', null, 'a whitespace-only title is refused');
select throws_ok(
  $$select public.start_group_conversation(null, array['00000000-0000-0000-0000-00000000aa02']::uuid[])$$,
  '22023', null, 'a null title is refused');
select throws_ok(
  format($$select public.start_group_conversation(%L, array['00000000-0000-0000-0000-00000000aa02']::uuid[])$$,
         repeat('x', 81)),
  '22023', null, 'a title over 80 characters is refused');
select throws_ok(
  $$select public.start_group_conversation('pgtap-nobody', array[]::uuid[])$$,
  '22023', null, 'a group with no other member is refused');
select throws_ok(
  $$select public.start_group_conversation('pgtap-null-members', null)$$,
  '22023', null, 'a null member list is refused');
select throws_ok(
  $$select public.start_group_conversation('pgtap-alone', array['00000000-0000-0000-0000-00000000aa01']::uuid[])$$,
  '22023', null, 'a group of yourself alone is refused');

-- 3 one bad invitee fails the WHOLE call ------------------------------------
-- Each of these adds one invitee gina may not add to one she may. A partial
-- implementation creates the group with hugo in it and leaves the other out;
-- that is the defect these three assertions exist for, and the leftover check
-- below is what catches it when the call does not raise.
select throws_ok(
  $$select public.start_group_conversation('pgtap-not-allowlisted',
     array['00000000-0000-0000-0000-00000000aa02','00000000-0000-0000-0000-00000000aa05']::uuid[])$$,
  '42501', null, 'an invitee who is not allowlisted fails the call');
select throws_ok(
  $$select public.start_group_conversation('pgtap-unconfirmed',
     array['00000000-0000-0000-0000-00000000aa02','00000000-0000-0000-0000-00000000aa06']::uuid[])$$,
  '42501', null, 'an invitee who never confirmed an email fails the call');
select throws_ok(
  $$select public.start_group_conversation('pgtap-ghost',
     array['00000000-0000-0000-0000-00000000aa02','00000000-0000-0000-0000-0000000000ff']::uuid[])$$,
  '42501', null, 'an invitee who does not exist fails the call');
reset role;

-- Bypassing RLS: the question is whether the row exists at all, not whether
-- gina can see it.
select is((select count(*) from public.conversations
            where title in ('pgtap-not-allowlisted', 'pgtap-unconfirmed', 'pgtap-ghost',
                            'pgtap-nobody', 'pgtap-alone', 'pgtap-no-device')),
          0::bigint,
          'a refused call leaves no conversation behind -- never a smaller group than was asked for');

-- 4 the successful call -----------------------------------------------------
select test_as('00000000-0000-0000-0000-00000000aa01', 'ea000000-0000-0000-0000-00000000aa01');
select lives_ok(
  $$select public.start_group_conversation('  pgtap-trip  ',
     array['00000000-0000-0000-0000-00000000aa02','00000000-0000-0000-0000-00000000aa03',
           '00000000-0000-0000-0000-00000000aa02','00000000-0000-0000-0000-00000000aa01']::uuid[])$$,
  'gina starts a group with hugo and iris, listing herself and a duplicate');
select is((select count(*) from public.conversations where btrim(title) = 'pgtap-trip'),
          1::bigint, 'the group was created once');
select is((select count(*) from public.conversation_members m
            join public.conversations c on c.id = m.conversation_id
           where btrim(c.title) = 'pgtap-trip'),
          3::bigint, 'the caller is added once and duplicates are ignored');
select is((select count(*) from public.conversation_members m
            join public.conversations c on c.id = m.conversation_id
           where btrim(c.title) = 'pgtap-trip'
             and m.user_id = '00000000-0000-0000-0000-00000000aa01'),
          1::bigint, 'the caller is a member without listing herself');
select is((select direct_key from public.conversations where btrim(title) = 'pgtap-trip'),
          null, 'a group carries no direct_key');
select lives_ok(
  format($$select public.start_group_conversation(%L, array['00000000-0000-0000-0000-00000000aa02']::uuid[])$$,
         repeat('y', 80)),
  'a title of exactly 80 characters is accepted');

-- The same title and the same people again: a group is never reused.
select lives_ok(
  $$select public.start_group_conversation('pgtap-trip',
     array['00000000-0000-0000-0000-00000000aa02','00000000-0000-0000-0000-00000000aa03']::uuid[])$$,
  'the same people may start a second group with the same name');
select is((select count(*) from public.conversations where btrim(title) = 'pgtap-trip'),
          2::bigint, 'a group is always new -- the null direct_key does not collide');
select is((select count(*) from public.conversation_members m
            join public.conversations c on c.id = m.conversation_id
           where btrim(c.title) = 'pgtap-trip'),
          6::bigint, 'the second group got its own three members');

-- titles are server-authored: no client may write one
select throws_ok($$update public.conversations set title = 'renamed by a client'$$,
                 '42501', null, 'a client cannot rename a conversation');
select throws_ok($$insert into public.conversations(title) values ('forged group')$$,
                 '42501', null, 'a client cannot create a group directly');

-- gina writes into her group
insert into public.messages(conversation_id, sender_id, body)
  select c.id, '00000000-0000-0000-0000-00000000aa01', 'pgtap group hello'
    from public.conversations c where btrim(c.title) = 'pgtap-trip'
   order by c.created_at limit 1;
reset role;

create temp table _group as
  select id from public.conversations where btrim(title) = 'pgtap-trip' order by created_at limit 1;
grant select on _group to authenticated;

-- 5 every member of the group reads it --------------------------------------
select test_as('00000000-0000-0000-0000-00000000aa02', 'ea000000-0000-0000-0000-00000000aa02');
select is((select count(*) from public.conversations where id = (select id from _group)),
          1::bigint, 'hugo reads the group he was added to');
select is((select count(*) from public.conversation_members where conversation_id = (select id from _group)),
          3::bigint, 'hugo sees all three members');
select is((select count(*) from public.messages where conversation_id = (select id from _group)),
          1::bigint, 'hugo reads the message sent to the group');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'hugo replies')$$,
         (select id from _group), '00000000-0000-0000-0000-00000000aa02'),
  'hugo may write into the group');
reset role;

select test_as('00000000-0000-0000-0000-00000000aa03', 'ea000000-0000-0000-0000-00000000aa03');
select is((select count(*) from public.conversations where id = (select id from _group)),
          1::bigint, 'iris reads the group she was added to');
select is((select count(*) from public.messages where conversation_id = (select id from _group)),
          2::bigint, 'iris reads both messages');
reset role;

-- 6 an active, allowlisted non-member reads nothing of it --------------------
-- jade satisfies has_app_access() on her own, so this tests the membership
-- half of every policy and nothing else.
select test_as('00000000-0000-0000-0000-00000000aa04', 'ea000000-0000-0000-0000-00000000aa04');
select is((select count(*) from public.conversations where id = (select id from _group)),
          0::bigint, 'an active non-member does not see the group');
select is((select count(*) from public.conversation_members where conversation_id = (select id from _group)),
          0::bigint, 'an active non-member sees no membership rows for the group');
select is((select count(*) from public.messages where conversation_id = (select id from _group)),
          0::bigint, 'an active non-member reads no group messages');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'gatecrashing')$$,
         (select id from _group), '00000000-0000-0000-0000-00000000aa04'),
  '42501', null, 'an active non-member cannot post into the group');
reset role;

-- 7 display names: a member renames itself, and only itself ------------------
select test_as('00000000-0000-0000-0000-00000000aa01', 'ea000000-0000-0000-0000-00000000aa01');
select lives_ok($$update public.profiles set display_name = 'Gina G' where user_id = auth.uid()$$,
                'gina renames herself');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000aa01'),
          'Gina G', 'the new display name is stored');
-- An unqualified update is the same statement without a where clause: RLS,
-- not the client, is what keeps it to one row.
select is(test_rename(null, 'Owned'),
          1::bigint, 'an unqualified rename reaches only the caller''s own row');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000aa02'),
          'Hugo', 'hugo keeps his name');
-- Targeting somebody else by id updates nothing at all.
select is(test_rename('00000000-0000-0000-0000-00000000aa02', 'Owned'),
          0::bigint, 'renaming another member updates no row');
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000aa03'),
          'Iris', 'iris keeps her name too');
-- Only display_name is grantable; every other column is refused outright.
select throws_ok($$update public.profiles set created_at = now() where user_id = auth.uid()$$,
                 '42501', null, 'a member cannot write created_at');
select throws_ok($$update public.profiles set user_id = '00000000-0000-0000-0000-00000000aa02'
                    where user_id = auth.uid()$$,
                 '42501', null, 'a member cannot move its profile to another account');
select throws_ok($$delete from public.profiles where user_id = auth.uid()$$,
                 '42501', null, 'a member cannot delete its profile');
-- The length rule still belongs to the database.
select throws_ok($$update public.profiles set display_name = '' where user_id = auth.uid()$$,
                 '23514', null, 'an empty display name is refused');
select throws_ok(
  format($$update public.profiles set display_name = %L where user_id = auth.uid()$$, repeat('z', 81)),
  '23514', null, 'a display name over 80 characters is refused');
select lives_ok(
  format($$update public.profiles set display_name = %L where user_id = auth.uid()$$, repeat('z', 80)),
  'a display name of exactly 80 characters is accepted');
reset role;

-- jade is in no conversation with gina at all: renaming is not group-scoped.
select test_as('00000000-0000-0000-0000-00000000aa04', 'ea000000-0000-0000-0000-00000000aa04');
select is(test_rename('00000000-0000-0000-0000-00000000aa04', 'Jade J'),
          1::bigint, 'any member may rename itself, group or not');
reset role;

-- mack is allowlisted but has no active device: the app-access half holds.
select test_as('00000000-0000-0000-0000-00000000aa07', 'ea000000-0000-0000-0000-00000000aa07');
select is(test_rename('00000000-0000-0000-0000-00000000aa07', 'Mack M'),
          0::bigint, 'a member without an active device renames nothing');
reset role;
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000aa07'),
          'Mack', 'mack''s name is unchanged');

set local role anon;
select throws_ok($$update public.profiles set display_name = 'anon'$$,
                 '42501', null, 'anon cannot write a display name');
reset role;

-- 8 the grant itself is column-scoped ---------------------------------------
select column_privs_are('public', 'profiles', 'display_name', 'authenticated',
                        array['SELECT', 'UPDATE'],
                        'display_name is the one column a member may write');
select column_privs_are('public', 'profiles', 'created_at', 'authenticated',
                        array['SELECT'],
                        'created_at is readable and nothing more');
select column_privs_are('public', 'profiles', 'user_id', 'authenticated',
                        array['SELECT'],
                        'user_id is readable and nothing more');

select * from finish();
rollback;
