begin;
select plan(77);

-- Online status and typing (v0.4): who Realtime lets receive and send on a
-- private channel, decided by the policies on realtime.messages.
--
-- Realtime authorises a join by inserting (send) and selecting (receive) a
-- row on realtime.messages as the caller, with the channel name in the
-- `realtime.topic` setting that realtime.topic() reads. can_send/can_receive
-- below do exactly that, so each assertion is the question Realtime asks.
--
-- Both policies are conjunctions, so every negative fixture fails ONE gate:
--   pia   presence off, typing on, member     -- only shares_presence() stops her
--   ravi  typing off, presence on, member     -- only shares_typing() stops him
--   sol   active, sharing on, NOT a member    -- only is_member() stops him
--   tove  member, sharing on, old session     -- only has_app_access() stops her
--         (the same account on its new session passes everything)
--   uwe   member, sharing on, never activated -- has_app_access() again
-- and ola (member, everything on) is the positive control for each of them.
--
-- The select policy reads realtime.topic(), not the row's topic column, so
-- the probe rows below are what a receive check can see; they are inserted
-- with RLS bypassed only because a refused sender could not insert them.

-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000bb001', 'ola@presence.test',  now(), '{"full_name":"Ola"}'),
  ('00000000-0000-0000-0000-0000000bb002', 'pia@presence.test',  now(), '{"full_name":"Pia"}'),
  ('00000000-0000-0000-0000-0000000bb003', 'ravi@presence.test', now(), '{"full_name":"Ravi"}'),
  ('00000000-0000-0000-0000-0000000bb004', 'sol@presence.test',  now(), '{"full_name":"Sol"}'),
  ('00000000-0000-0000-0000-0000000bb005', 'tove@presence.test', now(), '{"full_name":"Tove"}'),
  ('00000000-0000-0000-0000-0000000bb006', 'uwe@presence.test',  now(), '{"full_name":"Uwe"}');
insert into app_private.allowlist(email) values
  ('ola@presence.test'), ('pia@presence.test'), ('ravi@presence.test'),
  ('sol@presence.test'), ('tove@presence.test'), ('uwe@presence.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('eb000000-0000-0000-0000-0000000bb001', '00000000-0000-0000-0000-0000000bb001', now(), now()),
  ('eb000000-0000-0000-0000-0000000bb002', '00000000-0000-0000-0000-0000000bb002', now(), now()),
  ('eb000000-0000-0000-0000-0000000bb003', '00000000-0000-0000-0000-0000000bb003', now(), now()),
  ('eb000000-0000-0000-0000-0000000bb004', '00000000-0000-0000-0000-0000000bb004', now(), now()),
  ('eb000000-0000-0000-0000-0000000bb005', '00000000-0000-0000-0000-0000000bb005', now() - interval '1 hour', now()),
  ('eb000000-0000-0000-0000-00000000b005', '00000000-0000-0000-0000-0000000bb005', now(), now()),
  ('eb000000-0000-0000-0000-0000000bb006', '00000000-0000-0000-0000-0000000bb006', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function test_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end $$;

-- May the caller send on `topic` with `ext`? The insert Realtime makes.
create or replace function can_send(topic text, ext text) returns boolean
language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', coalesce(topic, ''), true);
  insert into realtime.messages (topic, extension, payload, event, private)
  values (coalesce(topic, ''), ext, '{}'::jsonb, 'probe', true);
  return true;
exception when insufficient_privilege then
  return false;
end $$;

-- May the caller receive on `topic` with `ext`? The select Realtime makes.
create or replace function can_receive(topic text, ext text) returns boolean
language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', coalesce(topic, ''), true);
  return exists (select 1 from realtime.messages m
                  where m.extension = ext and m.event = 'fixture');
end $$;

-- Rows a caller changed, for the verbs no policy grants.
create or replace function test_update_realtime() returns bigint
language plpgsql security invoker as $$
declare n bigint;
begin
  update realtime.messages set payload = '{"x":1}'::jsonb where event = 'fixture';
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function test_share(target uuid, presence boolean, typing boolean)
returns bigint language plpgsql security invoker as $$
declare n bigint;
begin
  update public.profiles set share_presence = presence, share_typing = typing
   where user_id = target;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function can_send(text, text), can_receive(text, text),
  test_update_realtime(), test_share(uuid, boolean, boolean)
  to authenticated, anon;

-- Everyone activates; tove's OLD session first, so her new one replaces it.
select test_as('00000000-0000-0000-0000-0000000bb005', 'eb000000-0000-0000-0000-0000000bb005');
select is(public.activate_session(), true, 'tove activates her old phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000bb001', 'eb000000-0000-0000-0000-0000000bb001');
select is(public.activate_session(), true, 'ola is active');
-- The conversation: ola, pia, ravi, tove, uwe. Not sol.
create temp table _c as
  select public.start_group_conversation('presence', array[
    '00000000-0000-0000-0000-0000000bb002', '00000000-0000-0000-0000-0000000bb003',
    '00000000-0000-0000-0000-0000000bb005', '00000000-0000-0000-0000-0000000bb006'
  ]::uuid[]) as id;
reset role;
grant select on _c to authenticated, anon;
select test_as('00000000-0000-0000-0000-0000000bb002', 'eb000000-0000-0000-0000-0000000bb002');
select is(public.activate_session(), true, 'pia is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000bb003', 'eb000000-0000-0000-0000-0000000bb003');
select is(public.activate_session(), true, 'ravi is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000bb004', 'eb000000-0000-0000-0000-0000000bb004');
select is(public.activate_session(), true, 'sol is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000bb005', 'eb000000-0000-0000-0000-00000000b005');
select is(public.activate_session(), true, 'tove moves to her new phone');
reset role;
-- uwe signs in but never activates.

update public.profiles set share_presence = false
 where user_id = '00000000-0000-0000-0000-0000000bb002';
update public.profiles set share_typing = false
 where user_id = '00000000-0000-0000-0000-0000000bb003';

create temp table _t as select 'typing:' || id::text as topic from _c;
grant select on _t to authenticated, anon;

-- Probe rows for the receive checks: one per extension.
insert into realtime.messages (topic, extension, payload, event, private) values
  ('fixture', 'presence',  '{}'::jsonb, 'fixture', true),
  ('fixture', 'broadcast', '{}'::jsonb, 'fixture', true);

-- 1 schema: the two columns and who may change them --------------------------
select col_not_null('public', 'profiles', 'share_presence', 'share_presence is not null');
select col_default_is('public', 'profiles', 'share_presence', 'true', 'share_presence defaults on');
select col_not_null('public', 'profiles', 'share_typing', 'share_typing is not null');
select col_default_is('public', 'profiles', 'share_typing', 'true', 'share_typing defaults on');
select is((select share_presence and share_typing from public.profiles
            where user_id = '00000000-0000-0000-0000-0000000bb001'),
          true, 'a new member shares both');
select ok(has_column_privilege('authenticated', 'public.profiles', 'share_presence', 'UPDATE'),
          'members may update share_presence');
select ok(has_column_privilege('authenticated', 'public.profiles', 'share_typing', 'UPDATE'),
          'members may update share_typing');
select ok(not has_column_privilege('anon', 'public.profiles', 'share_presence', 'UPDATE'),
          'anon may not update share_presence');
select ok(not has_column_privilege('anon', 'public.profiles', 'share_typing', 'UPDATE'),
          'anon may not update share_typing');

-- 2 nothing else was opened on realtime.messages -------------------------------
select policies_are('realtime', 'messages', array['realtime_receive', 'realtime_send'],
                    'realtime.messages has exactly the receive and send policies');
select policy_cmd_is('realtime', 'messages', 'realtime_receive', 'select', 'receive is select');
select policy_cmd_is('realtime', 'messages', 'realtime_send', 'insert', 'send is insert');
select policy_roles_are('realtime', 'messages', 'realtime_receive', array['authenticated'],
                        'receive is for authenticated only');
select policy_roles_are('realtime', 'messages', 'realtime_send', array['authenticated'],
                        'send is for authenticated only');

-- 3 ola: everything on, a member ---------------------------------------------
select test_as('00000000-0000-0000-0000-0000000bb001', 'eb000000-0000-0000-0000-0000000bb001');
select ok(can_receive('presence:members', 'presence'), 'ola receives presence');
select ok(can_send('presence:members', 'presence'), 'ola is seen online');
select ok(can_receive((select topic from _t), 'broadcast'), 'ola receives typing in her conversation');
select ok(can_send((select topic from _t), 'broadcast'), 'ola sends typing in her conversation');
select ok(can_send(upper((select topic from _t)), 'broadcast') = false,
          'the typing prefix is exact: TYPING: is another topic');
-- other topics and other extensions stay closed
select ok(not can_receive('presence:members', 'broadcast'), 'no broadcast on the presence topic');
select ok(not can_send('presence:members', 'broadcast'), 'no broadcast sent on the presence topic');
select ok(not can_receive((select topic from _t), 'presence'), 'no presence on a typing topic');
select ok(not can_send((select topic from _t), 'presence'), 'no presence sent on a typing topic');
select ok(not can_receive('presence:others', 'presence'), 'another presence topic is closed');
select ok(not can_send('presence:others', 'presence'), 'another presence topic cannot be sent on');
select ok(not can_receive((select id::text from _c), 'broadcast'), 'a bare conversation id is closed');
select ok(not can_receive('chat:' || (select id::text from _c), 'broadcast'), 'another prefix is closed');
select ok(not can_send('chat:' || (select id::text from _c), 'broadcast'), 'another prefix cannot be sent on');
select ok(not can_receive(null, 'presence'), 'no topic at all is closed (presence)');
select ok(not can_receive(null, 'broadcast'), 'no topic at all is closed (broadcast)');
select is(test_update_realtime(), 0::bigint, 'no member may update realtime messages');
select throws_ok($$delete from realtime.messages$$, '42501', null, 'no member may delete realtime messages');
-- malformed typing topics: refused, never an error
select lives_ok($$select can_receive('typing:not-a-uuid', 'broadcast')$$, 'a junk typing topic does not raise (receive)');
select lives_ok($$select can_send('typing:not-a-uuid', 'broadcast')$$, 'a junk typing topic does not raise (send)');
select ok(not can_receive('typing:not-a-uuid', 'broadcast'), 'typing:<junk> is closed');
select ok(not can_send('typing:', 'broadcast'), 'typing: with nothing after it is closed');
select ok(not can_send((select topic from _t) || 'x', 'broadcast'), 'a uuid with a tail is closed');
select ok(not can_send((select topic from _t) || '/x', 'broadcast'), 'a uuid with a path is closed');
select ok(not can_send('typing: ' || (select id::text from _c), 'broadcast'), 'a padded uuid is closed');
select ok(not can_send('typing:00000000-0000-0000-0000-000000000000', 'broadcast'),
          'a well-formed id of no conversation is closed');
-- a member may flip her own sharing, and the server follows at once
select is(test_share('00000000-0000-0000-0000-0000000bb001', false, false), 1::bigint,
          'ola turns both off');
select ok(not can_send('presence:members', 'presence'), 'ola off: not seen online');
select ok(not can_send((select topic from _t), 'broadcast'), 'ola off: typing refused');
select ok(can_receive('presence:members', 'presence'), 'ola off: still receives presence');
select is(test_share('00000000-0000-0000-0000-0000000bb001', true, true), 1::bigint,
          'ola turns both back on');
select ok(can_send('presence:members', 'presence'), 'ola on again: seen online');
select is(test_share('00000000-0000-0000-0000-0000000bb002', true, true), 0::bigint,
          'ola cannot turn pia''s sharing back on');
reset role;
select is((select share_presence from public.profiles
            where user_id = '00000000-0000-0000-0000-0000000bb002'),
          false, 'pia''s choice is untouched');

-- 4 pia: presence off -- only shares_presence() refuses her --------------------
select test_as('00000000-0000-0000-0000-0000000bb002', 'eb000000-0000-0000-0000-0000000bb002');
select ok(not can_send('presence:members', 'presence'), 'pia is not seen online');
select ok(can_receive('presence:members', 'presence'), 'pia still sees who is online');
select ok(can_send((select topic from _t), 'broadcast'), 'pia still sends typing');
reset role;

-- 5 ravi: typing off -- only shares_typing() refuses him -----------------------
select test_as('00000000-0000-0000-0000-0000000bb003', 'eb000000-0000-0000-0000-0000000bb003');
select ok(not can_send((select topic from _t), 'broadcast'), 'ravi''s typing is refused');
select ok(can_receive((select topic from _t), 'broadcast'), 'ravi still sees who types');
select ok(can_send('presence:members', 'presence'), 'ravi is still seen online');
reset role;

-- 6 sol: active, sharing, not a member -- only is_member() refuses him ---------
select test_as('00000000-0000-0000-0000-0000000bb004', 'eb000000-0000-0000-0000-0000000bb004');
select ok(can_send('presence:members', 'presence'), 'sol has app access (control)');
select ok(not can_receive((select topic from _t), 'broadcast'), 'sol cannot listen to their typing');
select ok(not can_send((select topic from _t), 'broadcast'), 'sol cannot inject typing');
reset role;

-- 7 tove: a member on a replaced phone -- only has_app_access() refuses her ----
select test_as('00000000-0000-0000-0000-0000000bb005', 'eb000000-0000-0000-0000-0000000bb005');
select ok(not can_receive('presence:members', 'presence'), 'old phone: no presence');
select ok(not can_send('presence:members', 'presence'), 'old phone: not seen online');
select ok(not can_receive((select topic from _t), 'broadcast'), 'old phone: no typing');
select ok(not can_send((select topic from _t), 'broadcast'), 'old phone: cannot type');
reset role;
select test_as('00000000-0000-0000-0000-0000000bb005', 'eb000000-0000-0000-0000-00000000b005');
select ok(can_receive((select topic from _t), 'broadcast'), 'new phone: typing (control)');
select ok(can_send('presence:members', 'presence'), 'new phone: seen online (control)');
reset role;

-- 8 uwe: a member who never activated -----------------------------------------
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _c)
              and user_id = '00000000-0000-0000-0000-0000000bb006'),
          1::bigint, 'uwe is a member, so only the missing session can refuse him');
select test_as('00000000-0000-0000-0000-0000000bb006', 'eb000000-0000-0000-0000-0000000bb006');
select ok(not can_receive('presence:members', 'presence'), 'never activated: no presence');
select ok(not can_send((select topic from _t), 'broadcast'), 'never activated: cannot type');
reset role;

-- 9 anon: no policy is for anon ------------------------------------------------
select test_anon();
select ok(not can_receive('presence:members', 'presence'), 'anon receives no presence');
select ok(not can_send('presence:members', 'presence'), 'anon cannot be seen online');
select ok(not can_receive((select topic from _t), 'broadcast'), 'anon receives no typing');
select ok(not can_send((select topic from _t), 'broadcast'), 'anon cannot inject typing');
select is(test_update_realtime(), 0::bigint, 'anon updates nothing');
reset role;

select * from finish();
rollback;
