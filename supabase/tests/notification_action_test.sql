begin;
select plan(67);

-- public.notification_action(): the Mark as read / Reply notification buttons,
-- run by the notification-action edge function (service role) AS the member
-- the push's action token names.
--
-- Every refusal fixture passes every gate but the one under test, and each
-- refused subject is first shown to succeed (or a twin of it is):
--
-- * cat  has access, a live bound device, a conversation of her own -- only
--        not a member of the group. Fails membership.
-- * lia  a member who acts once, then leaves. Fails "current member".
-- * dee  acts once from phone a, then signs in on phone b. Fails the device
--        binding only (phone a's session still exists in auth.sessions).
-- * eve  acts once, then loses her allowlist entry. Fails has_app_access.
-- * ann  is a member of a system chat with a live device. Fails "not system".
-- * val  carries the validation (22023) cases, so they cannot eat ann's quota.
-- * rat  carries the rate limit, so the 21 calls are his alone.
--
-- fixtures -------------------------------------------------------------------
-- n  who  role
-- 1  ann  member, the main subject
-- 2  bob  member, started the group, sends the message being acted on
-- 3  cat  not a member of the group
-- 4  dee  member, replaced by a newer sign-in
-- 5  eve  member, delisted
-- 6  rat  member, rate limit
-- 7  lia  member, leaves
-- 8  val  member, validation
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select ('00000000-0000-0000-0000-0000000a700' || n)::uuid, w || '@na.test', now(),
         json_build_object('full_name', initcap(w))::jsonb
    from unnest(array['ann','bob','cat','dee','eve','rat','lia','val']) with ordinality as t(w, n);
insert into app_private.allowlist(email)
  select email from auth.users where email like '%@na.test';
insert into app_private.tag_finds(finder, found_id)
  select '00000000-0000-0000-0000-0000000a7002', id from auth.users
   where email like '%@na.test' and id <> '00000000-0000-0000-0000-0000000a7002';

create or replace function na_uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000a700' || n)::uuid
$$;
create or replace function na_sess(n int, phone text) returns uuid language sql as $$
  select ('a7000000-0000-0000-0000-0000000000' || n || phone)::uuid
$$;
-- The FCM token of member n's phone, and what the action token carries for it.
create or replace function na_tok(n int) returns text language sql as $$
  select 'na-fcm-token-of-member-' || n
$$;
create or replace function na_dev(n int) returns text language sql as $$
  select encode(extensions.digest(na_tok(n), 'sha256'), 'hex')
$$;
grant execute on function na_uid(int), na_sess(int, text), na_tok(int), na_dev(int)
  to anon, authenticated, service_role;

insert into auth.sessions (id, user_id, created_at, updated_at)
  select na_sess(n, 'a'), na_uid(n), now() - interval '2 hours', now() from generate_series(1, 8) n
  union all
  select na_sess(4, 'b'), na_uid(4), now(), now();

create or replace function na_as(n int, phone text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', na_uid(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = na_uid(n)),
      'session_id', na_sess(n, phone))::text, true);
  execute 'set local role authenticated';
end $$;

-- Everyone signs in on phone a and registers its push token there.
do $$
declare n int;
begin
  for n in 1..8 loop
    perform na_as(n, 'a');
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    perform public.register_device_token(na_tok(n), 'android', true);
    reset role;
  end loop;
end $$;

-- The conversations --------------------------------------------------------
select na_as(2, 'a');
select isnt(public.start_group_conversation('pgtap-na',
              array[na_uid(1), na_uid(4), na_uid(5), na_uid(6), na_uid(7), na_uid(8)]),
            null, 'bob starts the group without cat');
select isnt(public.start_group_conversation('pgtap-na-cat', array[na_uid(3)]),
            null, 'bob starts a side group with cat');
reset role;
create temp table _c as
  select id from public.conversations where btrim(coalesce(title, '')) = 'pgtap-na';
create temp table _cat as
  select id from public.conversations where btrim(coalesce(title, '')) = 'pgtap-na-cat';
insert into public.conversations(id, system) values ('a7000000-0000-0000-0000-00000000c5c5', true);
insert into public.conversation_members(conversation_id, user_id)
  values ('a7000000-0000-0000-0000-00000000c5c5', na_uid(1));
grant select on _c, _cat to anon, authenticated, service_role;

select na_as(2, 'a');
insert into public.messages(conversation_id, sender_id, body)
  select id, na_uid(2), 'pgtap na message' from _c;
reset role;

create or replace function na_conv() returns uuid language sql as $$ select id from _c $$;
grant execute on function na_conv() to anon, authenticated, service_role;

-- Calls the RPC as the edge function does (service role) and reports the
-- result, or the SQLSTATE it raised.
create or replace function na_call(n int, dev text, conv uuid, act text, mid uuid, body text)
returns text language plpgsql as $$
begin
  return public.notification_action(na_uid(n), dev, conv, act, mid, body);
exception when others then
  return sqlstate;
end $$;
grant execute on function na_call(int, text, uuid, text, uuid, text) to anon, authenticated, service_role;

-- 1 grants -------------------------------------------------------------------
select ok(not has_function_privilege('anon',
            'public.notification_action(uuid,text,uuid,text,uuid,text)', 'execute'),
          'anon may not execute notification_action');
select ok(not has_function_privilege('authenticated',
            'public.notification_action(uuid,text,uuid,text,uuid,text)', 'execute'),
          'authenticated may not execute notification_action');
select ok(not has_function_privilege('public',
            'public.notification_action(uuid,text,uuid,text,uuid,text)', 'execute'),
          'PUBLIC may not execute notification_action');
select ok(has_function_privilege('service_role',
            'public.notification_action(uuid,text,uuid,text,uuid,text)', 'execute'),
          'service_role may execute notification_action');
select ok(not has_function_privilege('anon', 'app_private.act_as(uuid,text)', 'execute'),
          'anon may not execute act_as');
select ok(not has_function_privilege('authenticated', 'app_private.act_as(uuid,text)', 'execute'),
          'authenticated may not execute act_as');
select ok(not has_function_privilege('public', 'app_private.act_as(uuid,text)', 'execute'),
          'PUBLIC may not execute act_as');
select ok((select relrowsecurity from pg_class where oid = 'app_private.notification_action_log'::regclass),
          'notification_action_log has RLS on');
select is((select count(*) from pg_policies where schemaname = 'app_private'
            and tablename = 'notification_action_log'), 0::bigint,
          'notification_action_log has no policies');
select ok(not has_table_privilege('anon', 'app_private.notification_action_log',
            'select,insert,update,delete,truncate,references,trigger'),
          'anon holds no privilege on notification_action_log');
select ok(not has_table_privilege('authenticated', 'app_private.notification_action_log',
            'select,insert,update,delete,truncate,references,trigger'),
          'authenticated holds no privilege on notification_action_log');

-- The member's own app cannot call it either, even for itself.
select na_as(1, 'a');
select is(na_call(1, na_dev(1), na_conv(), 'mark_read', null, null), '42501',
          'authenticated (ann herself) is refused');
reset role;
set local role anon;
select is(na_call(1, na_dev(1), na_conv(), 'mark_read', null, null), '42501',
          'anon is refused');
reset role;

-- 2 mark_read: as the member, through mark_read --------------------------------
update public.conversation_members set last_read_at = now() - interval '1 hour'
 where conversation_id = na_conv() and user_id in (na_uid(1), na_uid(2));
set local role service_role;
select is(na_call(1, na_dev(1), na_conv(), 'mark_read', null, null), 'done',
          'ann marks the group read from the notification');
select is(current_setting('request.jwt.claims', true)::json->>'sub', na_uid(1)::text,
          'act_as claims the member the token names');
select is(current_setting('request.jwt.claims', true)::json->>'session_id', na_sess(1, 'a')::text,
          'act_as claims the member''s ACTIVE session');
select is(current_setting('request.jwt.claims', true)::json->>'role', 'authenticated',
          'act_as claims role authenticated');
reset role;
select is((select last_read_at from public.conversation_members
            where conversation_id = na_conv() and user_id = na_uid(1)), now(),
          'ann''s last_read_at moved to now');
select is((select last_read_at from public.conversation_members
            where conversation_id = na_conv() and user_id = na_uid(2)), now() - interval '1 hour',
          'bob''s last_read_at is untouched (marked as ann, nobody else)');
select is((select count(*) from public.messages where conversation_id = na_conv()), 1::bigint,
          'mark_read sends nothing');

-- 3 device: the token's device must still be the member's active one -----------
set local role service_role;
select is(na_call(1, encode(extensions.digest('some-other-phone', 'sha256'), 'hex'),
                  na_conv(), 'mark_read', null, null), '42501',
          'a device hash ann never registered is refused');
select is(na_call(1, na_dev(2), na_conv(), 'mark_read', null, null), '42501',
          'bob''s device hash cannot act as ann');
select is(na_call(1, na_tok(1), na_conv(), 'mark_read', null, null), '42501',
          'the raw FCM token is not the device hash');
select is(na_call(4, na_dev(4), na_conv(), 'mark_read', null, null), 'done',
          'dee acts from phone a while it is her active device');
reset role;
select na_as(4, 'b');
select ok(public.activate_session(), 'dee signs in on phone b');
reset role;
select is((select count(*) from auth.sessions where id = na_sess(4, 'a')), 1::bigint,
          'fixture: phone a''s session still exists');
set local role service_role;
select is(na_call(4, na_dev(4), na_conv(), 'mark_read', null, null), '42501',
          'the replaced phone a can no longer mark read');
select is(na_call(4, na_dev(4), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000d0001', 'hi'), '42501',
          'the replaced phone a can no longer reply');
reset role;
select is((select count(*) from public.messages where id = 'a7000000-0000-0000-0000-0000000d0001'), 0::bigint,
          'nothing was stored for the replaced phone');

-- 4 membership and access ------------------------------------------------------
set local role service_role;
select is(na_call(3, na_dev(3), (select id from _cat), 'mark_read', null, null), 'done',
          'cat can act in her own chat (her device and access are fine)');
select is(na_call(3, na_dev(3), na_conv(), 'mark_read', null, null), '42501',
          'cat, not a member, cannot mark the group read');
select is(na_call(3, na_dev(3), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000c0001', 'hi'), '42501',
          'cat, not a member, cannot reply in the group');
select is(na_call(7, na_dev(7), na_conv(), 'mark_read', null, null), 'done',
          'lia acts while a member');
reset role;
update public.conversation_members set left_at = now(), left_reason = 'left'
 where conversation_id = na_conv() and user_id = na_uid(7);
set local role service_role;
select is(na_call(7, na_dev(7), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000f0001', 'hi'), '42501',
          'lia, departed, cannot reply');
select is(na_call(5, na_dev(5), na_conv(), 'mark_read', null, null), 'done',
          'eve acts while allowlisted');
reset role;
delete from app_private.allowlist where email = 'eve@na.test';
set local role service_role;
select is(na_call(5, na_dev(5), na_conv(), 'mark_read', null, null), '42501',
          'eve, delisted (no app access), cannot mark read');
select is(na_call(5, na_dev(5), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000e0001', 'hi'), '42501',
          'eve, delisted, cannot reply');
select is(na_call(1, na_dev(1), 'a7000000-0000-0000-0000-00000000c5c5', 'reply',
                  'a7000000-0000-0000-0000-0000000a0009', 'hi'), '42501',
          'ann cannot reply in the system chat she is a member of');
reset role;
select is((select count(*) from public.messages where id in (
             'a7000000-0000-0000-0000-0000000c0001', 'a7000000-0000-0000-0000-0000000f0001',
             'a7000000-0000-0000-0000-0000000e0001', 'a7000000-0000-0000-0000-0000000a0009')),
          0::bigint, 'no refused reply was stored');

-- 5 validation (22023) ----------------------------------------------------------
set local role service_role;
select is(na_call(8, na_dev(8), na_conv(), 'delete', null, null), '22023', 'an unknown action is 22023');
select is(na_call(8, na_dev(8), na_conv(), null, null, null), '22023', 'a null action is 22023');
select is(na_call(8, na_dev(8), na_conv(), 'reply', null, 'hi'), '22023', 'a reply without an id is 22023');
select is(na_call(8, na_dev(8), na_conv(), 'reply', 'a7000000-0000-0000-0000-000000080001', null), '22023',
          'a reply without a body is 22023');
select is(na_call(8, na_dev(8), na_conv(), 'reply', 'a7000000-0000-0000-0000-000000080002', ''), '22023',
          'an empty reply is 22023');
select is(na_call(8, na_dev(8), na_conv(), 'reply', 'a7000000-0000-0000-0000-000000080003', repeat('x', 4001)),
          '22023', 'a 4001-character reply is 22023');
select is(na_call(8, na_dev(8), na_conv(), 'reply', 'a7000000-0000-0000-0000-000000080004', repeat('x', 4000)),
          'done', 'a 4000-character reply is accepted');
select is(na_call(8, na_dev(8), na_conv(), 'reply', 'a7000000-0000-0000-0000-000000080005', 'x'),
          'done', 'a 1-character reply is accepted');
reset role;
select is((select count(*) from public.messages where sender_id = na_uid(8)), 2::bigint,
          'only the two valid replies were stored');

-- 6 reply: stored as the member, idempotent, and marks the chat read -----------
update public.conversation_members set last_read_at = now() - interval '1 hour'
 where conversation_id = na_conv() and user_id = na_uid(1);
set local role service_role;
select is(na_call(1, na_dev(1), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000a0001', 'on my way'),
          'done', 'ann replies from the notification');
reset role;
select is((select row(sender_id, conversation_id, body)::text from public.messages
            where id = 'a7000000-0000-0000-0000-0000000a0001'),
          row(na_uid(1), na_conv(), 'on my way')::text,
          'the reply is stored with the given id, from ann, in the group');
select is((select last_read_at from public.conversation_members
            where conversation_id = na_conv() and user_id = na_uid(1)), now(),
          'replying also marks the chat read for ann');
set local role service_role;
select is(na_call(1, na_dev(1), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000a0001', 'on my way'),
          'duplicate', 'the same reply retried is a duplicate');
select is(na_call(1, na_dev(1), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000a0001', 'something else'),
          '23505', 'the same id with a different body is 23505');
select is(na_call(2, na_dev(2), na_conv(), 'reply', 'a7000000-0000-0000-0000-0000000a0001', 'on my way'),
          '23505', 'the same id and body from another member is 23505, not a duplicate');
reset role;
select is((select count(*) from public.messages where id = 'a7000000-0000-0000-0000-0000000a0001'), 1::bigint,
          'one row for the id');
select is((select body from public.messages where id = 'a7000000-0000-0000-0000-0000000a0001'), 'on my way',
          'the stored body is unchanged by the conflicting attempts');

-- 7 rate limit: 20 per member per rolling minute, both actions counted ----------
set local role service_role;
select is((select count(*) from generate_series(1, 10) i
            where na_call(6, na_dev(6), na_conv(), 'mark_read', null, null) = 'done'),
          10::bigint, 'rat marks read 10 times');
select is((select count(*) from generate_series(1, 10) i
            where na_call(6, na_dev(6), na_conv(), 'reply',
                          ('a7000000-0000-0000-0000-0000006000' || lpad(i::text, 2, '0'))::uuid,
                          'r' || i) = 'done'),
          10::bigint, 'and replies 10 times: 20 actions');
select is(na_call(6, na_dev(6), na_conv(), 'mark_read', null, null), 'P0429',
          'the 21st action in the minute is rate limited (mark_read)');
select is(na_call(6, na_dev(6), na_conv(), 'reply', 'a7000000-0000-0000-0000-000000006021', 'r21'), 'P0429',
          'the 21st action in the minute is rate limited (reply)');
reset role;
select is((select count(*) from public.messages where id = 'a7000000-0000-0000-0000-000000006021'), 0::bigint,
          'the rate-limited reply was not stored');
select is((select count(*) from public.messages where sender_id = na_uid(6)), 10::bigint,
          'rat''s ten replies were stored');
set local role service_role;
select is(na_call(2, na_dev(2), na_conv(), 'mark_read', null, null), 'done',
          'the limit is per member: bob still acts');
reset role;
update app_private.notification_action_log set at = now() - interval '59 seconds'
 where user_id = na_uid(6);
set local role service_role;
select is(na_call(6, na_dev(6), na_conv(), 'mark_read', null, null), 'P0429',
          'actions 59 seconds old still count');
reset role;
update app_private.notification_action_log set at = now() - interval '61 seconds'
 where user_id = na_uid(6);
set local role service_role;
select is(na_call(6, na_dev(6), na_conv(), 'mark_read', null, null), 'done',
          'a minute later rat may act again (rolling window)');
reset role;

select * from finish();
rollback;
