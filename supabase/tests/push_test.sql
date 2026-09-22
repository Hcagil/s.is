begin;
select plan(84);

-- Push notification delivery addresses.
--
-- A device token is a delivery address for a person. Three things have to hold
-- and each fails differently:
--
-- 1. The table is private in the same sense as the allowlist -- RLS on, no
--    policy, no grant. Any ONE of those three being enough on its own is the
--    trap: a grant with RLS on and no policy still denies, and a policy with
--    no grant still denies, so a test that only checks the client gets 42501
--    stays green after either one is deleted. All three are asserted.
-- 2. register_device_token() needs app access; forget_device_token()
--    deliberately does NOT. A member whose phone was replaced has already lost
--    app access, and is exactly the member who most needs to stop the old
--    handset receiving messages it can no longer open. That asymmetry is the
--    non-obvious half of the contract and it gets its own fixture below.
-- 3. push_targets_for_message() is a delivery list. Every name on it is
--    somebody who may read the message: not the sender, not a member without a
--    device, and not a member whose session is gone.
--
-- Every negative fixture fails ONE gate. tess is allowlisted and signed in and
-- fails only the active-device check; rhea holds the active device and fails
-- only the allowlist; quin holds a token AND a live active_sessions row and
-- fails only the auth.sessions lookup. A single all-purpose "stranger" would
-- satisfy every clause at once and leave any of them deletable.
--
-- This database is not necessarily empty -- the integration tests leave rows
-- behind -- so every count below is scoped to these fixtures.

-- fixtures -------------------------------------------------------------------
-- nina  allowlisted, confirmed, active            sender
-- omar  allowlisted, confirmed, active, token     the target; replaces his phone
-- pia   allowlisted, confirmed, active, NO token  member who cannot be reached
-- quin  allowlisted, confirmed, token, REVOKED    member who may no longer read
-- rhea  confirmed, holds the active device, NOT allowlisted
-- sam   allowlisted, confirmed, active, token, NOT a member
-- tess  allowlisted, confirmed, signed in, never claimed a device
-- uma   allowlisted, confirmed, two phones -- the old one is the replaced one
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000fd001', 'nina@push.test', now(), '{"full_name":"Nina"}'),
  ('00000000-0000-0000-0000-0000000fd002', 'omar@push.test', now(), '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-0000000fd003', 'pia@push.test',  now(), '{"full_name":"Pia"}'),
  ('00000000-0000-0000-0000-0000000fd004', 'quin@push.test', now(), '{"full_name":"Quin"}'),
  ('00000000-0000-0000-0000-0000000fd005', 'rhea@push.test', now(), '{"full_name":"Rhea"}'),
  ('00000000-0000-0000-0000-0000000fd006', 'sam@push.test',  now(), '{"full_name":"Sam"}'),
  ('00000000-0000-0000-0000-0000000fd007', 'tess@push.test', now(), '{"full_name":"Tess"}'),
  ('00000000-0000-0000-0000-0000000fd008', 'uma@push.test',  now(), '{"full_name":"Uma"}');
insert into app_private.allowlist(email) values
  ('nina@push.test'), ('omar@push.test'), ('pia@push.test'), ('quin@push.test'),
  ('sam@push.test'), ('tess@push.test'), ('uma@push.test');   -- rhea on purpose absent

-- omar's and uma's second phones are newer than their first; now() is the
-- transaction timestamp, so "two hours ago" is the only way to order them.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('fd000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000fd001', now(), now()),
  ('fd000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000fd002', now() - interval '2 hours', now()),
  ('fd000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000fd003', now(), now()),
  ('fd000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000fd004', now(), now()),
  ('fd000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000fd005', now(), now()),
  ('fd000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000fd006', now(), now()),
  ('fd000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000fd007', now(), now()),
  ('fd000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000fd008', now() - interval '2 hours', now()),
  ('fd000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-0000000fd002', now(), now()),
  ('fd000000-0000-0000-0000-000000000018', '00000000-0000-0000-0000-0000000fd008', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- rhea cannot reach the active device through the front door -- activate_session
-- checks the allowlist first. Written here so that she fails the allowlist gate
-- and nothing else.
insert into app_private.active_sessions(user_id, session_id, session_created_at)
  values ('00000000-0000-0000-0000-0000000fd005', 'fd000000-0000-0000-0000-000000000005', now());

select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'nina is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd002', 'fd000000-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'omar is active on his first phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd003', 'fd000000-0000-0000-0000-000000000003');
select is(public.activate_session(), true, 'pia is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd004', 'fd000000-0000-0000-0000-000000000004');
select is(public.activate_session(), true, 'quin is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd006', 'fd000000-0000-0000-0000-000000000006');
select is(public.activate_session(), true, 'sam is active');
reset role;

-- 1 the table is private, by three independent mechanisms --------------------
select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select throws_ok($$select * from app_private.device_tokens$$,
                 '42501', null, 'a member cannot read device tokens');
select throws_ok($$insert into app_private.device_tokens(user_id, token, platform)
                   values (auth.uid(), 'forged-token-value', 'android')$$,
                 '42501', null, 'a member cannot write a device token directly');
select throws_ok($$select * from app_private.device_tokens where user_id <> auth.uid()$$,
                 '42501', null, 'a member cannot read another member''s delivery address');
reset role;
set local role anon;
select throws_ok($$select * from app_private.device_tokens$$,
                 '42501', null, 'anon cannot read device tokens');
reset role;
select table_privs_are('app_private', 'device_tokens', 'authenticated', '{}'::text[],
                       'authenticated holds no privilege on device_tokens');
select table_privs_are('app_private', 'device_tokens', 'anon', '{}'::text[],
                       'anon holds no privilege on device_tokens');
select is((select relrowsecurity from pg_class where oid = 'app_private.device_tokens'::regclass),
          true, 'row level security is enabled on device_tokens');
select is((select count(*) from pg_policies
            where schemaname = 'app_private' and tablename = 'device_tokens'),
          0::bigint, 'device_tokens carries no policy: a stray grant still reaches nothing');

-- 2 who may register a token -------------------------------------------------
set local role anon;
select throws_ok($$select public.register_device_token('anon-token-value', 'android')$$,
                 'permission denied for function register_device_token',
                 'anon cannot register a device token');
select throws_ok($$select public.forget_device_token('anon-token-value')$$,
                 'permission denied for function forget_device_token',
                 'anon cannot forget a device token');
reset role;

-- tess: allowlisted, confirmed, signed in -- fails only the active-device gate.
select is((select exists (select 1 from app_private.allowlist where email = 'tess@push.test')
              and exists (select 1 from auth.sessions where id = 'fd000000-0000-0000-0000-000000000007')
              and not exists (select 1 from app_private.active_sessions
                               where user_id = '00000000-0000-0000-0000-0000000fd007')),
          true, 'tess is allowlisted and signed in and has never claimed a device');
select test_as('00000000-0000-0000-0000-0000000fd007', 'fd000000-0000-0000-0000-000000000007');
select throws_ok($$select public.register_device_token('tess-token-value', 'android')$$,
                 '42501', null, 'a member who has never claimed a device cannot register a token');
reset role;

-- rhea: holds the active device -- fails only the allowlist gate.
select is((select exists (select 1 from app_private.active_sessions
                           where user_id = '00000000-0000-0000-0000-0000000fd005'
                             and session_id = 'fd000000-0000-0000-0000-000000000005')
              and not exists (select 1 from app_private.allowlist where email = 'rhea@push.test')),
          true, 'rhea holds the active device and is not allowlisted');
select test_as('00000000-0000-0000-0000-0000000fd005', 'fd000000-0000-0000-0000-000000000005');
select throws_ok($$select public.register_device_token('rhea-token-value', 'android')$$,
                 '42501', null, 'a user off the allowlist cannot register a token');
reset role;

-- 3 what a token may look like -----------------------------------------------
select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select lives_ok($$select public.register_device_token('nina-token-1', 'android')$$,
                'nina registers her phone');
select throws_ok($$select public.register_device_token('123456789', 'android')$$,
                 '22023', null, 'a token of nine characters is refused');
select throws_ok($$select public.register_device_token(null, 'android')$$,
                 '22023', null, 'a null token is refused');
select throws_ok(
  format($$select public.register_device_token(%L, 'android')$$, repeat('x', 4097)),
  '22023', null, 'a token of 4097 characters is refused');
select throws_ok($$select public.register_device_token('nina-token-1', 'windows')$$,
                 '22023', null, 'a platform outside android and ios is refused');
select throws_ok($$select public.register_device_token('nina-token-1', 'Android')$$,
                 '22023', null, 'the platform set is exact: Android is not android');
-- Refused, but NOT by the function: a null token raises 22023 while a null
-- platform falls through to the not-null constraint on the table and raises
-- 23502. The row is never written either way, so this asserts the guarantee
-- that holds -- the SQLSTATE gap is reported, not blessed with an expectation.
select throws_ok($$select public.register_device_token('nina-token-1', null)$$,
                 null::text, null::text, 'a null platform is refused');
reset role;
-- A refused registration must not have deleted anything first. Checked with RLS
-- bypassed: nina cannot read this table at all, which is the point of part 1.
select is((select string_agg(token, ',' order by token) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          'nina-token-1', 'a refused registration leaves the phone she has registered alone');

select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select lives_ok(format($$select public.register_device_token(%L, 'ios')$$, repeat('a', 10)),
                'a token of exactly ten characters is accepted');
select lives_ok(format($$select public.register_device_token(%L, 'android')$$, repeat('b', 4096)),
                'a token of exactly 4096 characters is accepted');
reset role;

-- 4 registering REPLACES: one member, one device ------------------------------
select is((select count(*) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          1::bigint, 'three registrations leave one row: a member has one device');
select is((select string_agg(token, ',' order by token) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          repeat('b', 4096), 'the surviving row is the phone that registered last');

select test_as('00000000-0000-0000-0000-0000000fd002', 'fd000000-0000-0000-0000-000000000002');
select lives_ok($$select public.register_device_token('omar-token-old', 'android')$$,
                'omar registers his first phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select lives_ok($$select public.register_device_token('nina-token-2', 'android')$$,
                'nina moves to another phone');
reset role;
select is((select string_agg(token, ',' order by token) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          'omar-token-old', 'replacing your own phone never deletes another member''s');
select is((select count(*) from app_private.device_tokens
            where user_id in ('00000000-0000-0000-0000-0000000fd001',
                              '00000000-0000-0000-0000-0000000fd002')),
          2::bigint, 'two members, two delivery addresses');

-- Idempotence. now() is frozen for the whole transaction, so the only way to
-- see updated_at move is to push the stored value into the past first.
update app_private.device_tokens set updated_at = now() - interval '1 day'
 where user_id = '00000000-0000-0000-0000-0000000fd001';
select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select lives_ok($$select public.register_device_token('nina-token-2', 'android')$$,
                'the same phone registers again on the next launch');
reset role;
select is((select count(*) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          1::bigint, 'registering the same token twice is one row, not two');
select is((select bool_and(updated_at > now() - interval '1 hour') from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          true, 'registering the same token refreshes updated_at');

-- 5 forgetting: the half that must NOT need app access ------------------------
-- uma's old phone is allowlisted, confirmed, its auth.sessions row is alive and
-- it is still signed in. The only thing it fails is holding the active device --
-- which is exactly the state a member is in the moment they change phone, and
-- exactly when the handset they left must stop being notified.
select test_as('00000000-0000-0000-0000-0000000fd008', 'fd000000-0000-0000-0000-000000000008');
select is(public.activate_session(), true, 'uma claims the device on her old phone');
select lives_ok($$select public.register_device_token('uma-token-old', 'android')$$,
                'uma registers her old phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd008', 'fd000000-0000-0000-0000-000000000018');
select is(public.activate_session(), true, 'uma''s new phone takes the device over');
reset role;

select is((select count(*) from auth.sessions where id = 'fd000000-0000-0000-0000-000000000008'),
          1::bigint, 'the old phone''s session was never revoked -- only the device moved');
select test_as('00000000-0000-0000-0000-0000000fd008', 'fd000000-0000-0000-0000-000000000008');
select throws_ok($$select public.register_device_token('uma-token-old', 'android')$$,
                 '42501', null, 'the replaced phone has lost app access');
select lives_ok($$select public.forget_device_token('uma-token-old')$$,
                'the replaced phone may still stop its own notifications');
reset role;
select is((select count(*) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd008'),
          0::bigint, 'the replaced phone''s delivery address is gone');

select test_as('00000000-0000-0000-0000-0000000fd008', 'fd000000-0000-0000-0000-000000000008');
select lives_ok($$select public.forget_device_token('uma-token-old')$$,
                'forgetting a token that is already gone is not an error');
reset role;

-- rhea is signed in and nothing else: forgetting is not gated on the allowlist.
select test_as('00000000-0000-0000-0000-0000000fd005', 'fd000000-0000-0000-0000-000000000005');
select lives_ok($$select public.forget_device_token('rhea-token-value')$$,
                'a signed-in user off the allowlist may still forget a token');
reset role;

-- forgetting reaches your own row and no other
select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select lives_ok($$select public.forget_device_token('omar-token-old')$$,
                'nina may name another member''s token without an error');
reset role;
select is((select string_agg(token, ',' order by token) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          'omar-token-old', 'omar keeps the phone nina tried to forget');
select is((select count(*) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          1::bigint, 'and nina still has her own');

-- 6 who gets told about a message ---------------------------------------------
-- The conversation: nina, omar, pia and quin in a group; nina and omar also
-- have a one-to-one. sam is a member of neither.
select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select isnt(public.start_group_conversation('pgtap-push',
              array['00000000-0000-0000-0000-0000000fd002',
                    '00000000-0000-0000-0000-0000000fd003',
                    '00000000-0000-0000-0000-0000000fd004']::uuid[]),
            null, 'nina starts the group');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000fd002'),
            null, 'nina also starts a one-to-one with omar');
-- The notification carries the name the member chose, not the one Google gave.
select lives_ok($$update public.profiles set display_name = 'Nina N' where user_id = auth.uid()$$,
                'nina renames herself before she writes');
reset role;

select test_as('00000000-0000-0000-0000-0000000fd004', 'fd000000-0000-0000-0000-000000000004');
select lives_ok($$select public.register_device_token('quin-token-1', 'ios')$$,
                'quin registers his phone while he still has access');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd006', 'fd000000-0000-0000-0000-000000000006');
select lives_ok($$select public.register_device_token('sam-token-1', 'android')$$,
                'sam registers a phone he will never be notified on');
reset role;

-- Captured with RLS bypassed, and granted on so the inserts below can be made
-- as the sender rather than as the owner of the table.
create temp table _push as
  select c.id from public.conversations c where btrim(coalesce(c.title, '')) = 'pgtap-push';
create temp table _direct as
  select c.id
    from public.conversations c
    join public.conversation_members a on a.conversation_id = c.id
     and a.user_id = '00000000-0000-0000-0000-0000000fd001'
    join public.conversation_members b on b.conversation_id = c.id
     and b.user_id = '00000000-0000-0000-0000-0000000fd002'
   where c.direct_key is not null;
grant select on _push, _direct to authenticated;

select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000fd001', 'pgtap push to the group' from _push;
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000fd001', 'pgtap push to omar alone' from _direct;
reset role;
select test_as('00000000-0000-0000-0000-0000000fd002', 'fd000000-0000-0000-0000-000000000002');
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000fd002', 'pgtap push from omar' from _push;
reset role;

-- quin loses his session AFTER the group exists and his token is registered:
-- allowlisted, confirmed, still a member, still holding the active-device row,
-- and now unable to read a word of the conversation.
delete from auth.sessions where id = 'fd000000-0000-0000-0000-000000000004';
select is((select exists (select 1 from app_private.device_tokens
                           where user_id = '00000000-0000-0000-0000-0000000fd004')
              and exists (select 1 from app_private.active_sessions
                           where user_id = '00000000-0000-0000-0000-0000000fd004')
              and exists (select 1 from public.conversation_members
                           where user_id = '00000000-0000-0000-0000-0000000fd004')
              and not exists (select 1 from auth.sessions
                               where user_id = '00000000-0000-0000-0000-0000000fd004')),
          true, 'quin still has a phone, a device row and a membership -- only his session is gone');

create temp table _ids as
  select (select id from public.messages
           where conversation_id = (select id from _push) and body = 'pgtap push to the group') as grp,
         (select id from public.messages
           where conversation_id = (select id from _push) and body = 'pgtap push from omar') as omar,
         (select id from public.messages
           where conversation_id = (select id from _direct) and body = 'pgtap push to omar alone') as direct;

-- it is unreachable from a client
set local role anon;
select throws_ok($$select * from app_private.push_targets_for_message(null)$$,
                 '42501', null, 'anon cannot build a delivery list');
reset role;
select test_as('00000000-0000-0000-0000-0000000fd001', 'fd000000-0000-0000-0000-000000000001');
select throws_ok($$select * from app_private.push_targets_for_message(null)$$,
                 '42501', null, 'a member cannot build a delivery list');
reset role;
select function_privs_are('app_private', 'push_targets_for_message', array['uuid'], 'anon',
                          '{}'::text[], 'anon holds no execute on push_targets_for_message');
select function_privs_are('app_private', 'push_targets_for_message', array['uuid'], 'authenticated',
                          '{}'::text[], 'authenticated holds no execute on push_targets_for_message');

-- the delivery list itself
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))),
          1::bigint, 'one target: the only other member with a phone and a live session');
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          0::bigint, 'the sender is never told about their own message');
-- Pinned to omar on purpose: a list with a row too many must fail one
-- assertion, not abort the file on a scalar subquery.
select is((select string_agg(token, ',' order by token) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          'omar-token-old', 'the target carries the phone omar registered');
select is((select string_agg(platform, ',' order by platform) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          'android', 'and the platform it runs');
select is((select string_agg(body, ',') from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          'pgtap push to the group', 'the notification carries the message');
select is((select string_agg(sender_name, ',') from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          'Nina N', 'and the name the sender chose, not the one her account was created with');
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd003'),
          0::bigint, 'a member with no phone is not a target');
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd004'),
          0::bigint, 'a member whose session is gone is not told about a message he cannot read');
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd006'),
          0::bigint, 'an active member of another conversation is not a target');

-- pia turns her phone on: every other member of a group is a target
select test_as('00000000-0000-0000-0000-0000000fd003', 'fd000000-0000-0000-0000-000000000003');
select lives_ok($$select public.register_device_token('pia-token-1', 'ios')$$,
                'pia registers a phone');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))),
          2::bigint, 'both other members with a phone are targets');
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd003' and token = 'pia-token-1'),
          1::bigint, 'pia is reached on the phone she just registered');

-- the same group, a message somebody else sent
select is((select count(*) from app_private.push_targets_for_message((select omar from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          0::bigint, 'whoever sends is the one member left off the list');
select is((select count(*) from app_private.push_targets_for_message((select omar from _ids))),
          2::bigint, 'nina and pia are told about omar''s message');
select is((select string_agg(sender_name, ',') from app_private.push_targets_for_message((select omar from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd001'),
          'Omar', 'the name on it is the sender of THAT message');

-- the one-to-one
select is((select count(*) from app_private.push_targets_for_message((select direct from _ids))),
          1::bigint, 'a one-to-one message reaches exactly one phone');
select is((select count(*) from app_private.push_targets_for_message((select direct from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          1::bigint, 'and it is the other person''s');

-- omar changes phone: the handset he left is never on the list again
select test_as('00000000-0000-0000-0000-0000000fd002', 'fd000000-0000-0000-0000-000000000012');
select is(public.activate_session(), true, 'omar''s new phone takes the device over');
select lives_ok($$select public.register_device_token('omar-token-new', 'android')$$,
                'omar registers the new phone');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          1::bigint, 'omar is on the list once, not once per handset he has owned');
select is((select string_agg(token, ',' order by token) from app_private.push_targets_for_message((select grp from _ids))
            where user_id = '00000000-0000-0000-0000-0000000fd002'),
          'omar-token-new', 'and it is the phone he is holding');
select is((select count(*) from app_private.push_targets_for_message((select grp from _ids))
            where token = 'omar-token-old'),
          0::bigint, 'the replaced handset is never a delivery address again');

-- an id that names no message names nobody
select is((select count(*) from app_private.push_targets_for_message(
             '00000000-0000-0000-0000-0000000fdfff'::uuid)),
          0::bigint, 'an unknown message has no targets');
select is((select count(*) from app_private.push_targets_for_message(null)),
          0::bigint, 'a null message id has no targets');

select * from finish();
rollback;
