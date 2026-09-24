begin;
select plan(96);

-- Notification settings, mutes, and the two functions that decide who is
-- told about a message and what they may see (v0.8).
--
-- 1. notification_settings and notification_mutes are private in the same
--    sense as everything else gated on app access: own row only, and losing
--    the active session revokes read/write at the same instant it revokes
--    everything else. No row in notification_settings means the defaults
--    (on, full) -- proved through push_targets_for_message, since there is
--    nothing to select.
-- 2. A mute must name something the caller could plausibly want to silence:
--    a conversation they are actually in, or another allowlisted member, not
--    themselves. That guard is asserted on INSERT and, separately, that an
--    UPDATE cannot launder a row into a forbidden target or hand it to
--    another user -- a negative fixture proves exactly one clause the same
--    way the push fixtures do: a target that fails only membership, a target
--    that is only the caller themself, a target that is only unlisted.
-- 3. app_private.push_targets_for_message honours the recipient's OWN
--    settings and mutes, never the sender's: enabled=false removes them from
--    every delivery list regardless of who muted whom; an unexpired mute on
--    the conversation or on the sender removes them from that message only;
--    an expired mute removes nobody. What is shown is keyed off preview:
--    full names the sender (plus the group, if any) and the trimmed/photo
--    body; sender names the sender and hides the body; none hides both.
-- 4. public.push_targets is the sender's only entry point: it claims a
--    message before returning its targets, so a second call (replay) or a
--    call for a message more than two minutes old returns nobody -- and, on
--    a fresh message, still returns the same list app_private would.
-- 5. The messages_notify trigger only reaches the network when Vault holds
--    the URL; otherwise an insert queues nothing. When it does reach out, the
--    request carries the message id and nothing else -- no body text.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Rows touched by an UPDATE or DELETE, as the caller: a row RLS hides is not
-- an error, it is simply not touched.
create or replace function test_row_count(stmt text)
returns bigint language plpgsql security invoker as $$
declare n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function test_row_count(text) to authenticated;

-- fixtures ---------------------------------------------------------------
-- ann   allowlisted, active           the subject: her settings and mutes
-- bo    allowlisted, active           sends to ann; a valid person-mute target
-- cleo  allowlisted, active           third member of the group; another sender
-- dee   allowlisted, active -> revoked   proves the session gate on both tables
-- eve   confirmed, NOT allowlisted    an invalid person-mute target
-- fay   allowlisted, active           shares a conversation with bo only -- ann
--                                     is not a member, so it is an invalid
--                                     conversation-mute target for her
-- gus   allowlisted, active, token, THEN REMOVED FROM THE ALLOWLIST -- still a
--       member with a live session and a device, to prove that alone is not
--       enough once app_private.is_allowed() says no
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ee001', 'ann@ns.test',  now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000ee002', 'bo@ns.test',   now(), '{"full_name":"Bo"}'),
  ('00000000-0000-0000-0000-0000000ee003', 'cleo@ns.test', now(), '{"full_name":"Cleo"}'),
  ('00000000-0000-0000-0000-0000000ee004', 'dee@ns.test',  now(), '{"full_name":"Dee"}'),
  ('00000000-0000-0000-0000-0000000ee005', 'eve@ns.test',  now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-0000000ee006', 'fay@ns.test',  now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-0000000ee007', 'gus@ns.test',  now(), '{"full_name":"Gus"}');
insert into app_private.allowlist(email) values
  ('ann@ns.test'), ('bo@ns.test'), ('cleo@ns.test'), ('dee@ns.test'), ('fay@ns.test'),
  ('gus@ns.test');
  -- eve on purpose absent

-- eve never signs in for this file -- she exists only as an off-allowlist
-- mute target -- so she gets no session row at all.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ee000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ee001', now(), now()),
  ('ee000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000ee002', now(), now()),
  ('ee000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000ee003', now(), now()),
  ('ee000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000ee004', now(), now()),
  ('ee000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000ee006', now(), now()),
  ('ee000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000ee007', now(), now());

select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'ann is active');
select lives_ok($$select public.register_device_token('ann-token-1', 'android')$$,
                'ann registers a phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'bo is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee003', 'ee000000-0000-0000-0000-000000000003');
select is(public.activate_session(), true, 'cleo is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee004', 'ee000000-0000-0000-0000-000000000004');
select is(public.activate_session(), true, 'dee is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee006', 'ee000000-0000-0000-0000-000000000006');
select is(public.activate_session(), true, 'fay is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee007', 'ee000000-0000-0000-0000-000000000007');
select is(public.activate_session(), true, 'gus is active');
select lives_ok($$select public.register_device_token('gus-token-1', 'android')$$,
                'gus registers a phone while still allowlisted');
reset role;

-- groupC: ann, bo, cleo. directBoAnn: bo and ann. directFayBo: fay and bo --
-- ann is a member of neither directFayBo nor anything with fay.
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select isnt(public.start_group_conversation('ee-group',
              array['00000000-0000-0000-0000-0000000ee002',
                    '00000000-0000-0000-0000-0000000ee003']::uuid[]),
            null, 'ann starts the group');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000ee001'),
            null, 'bo starts a one-to-one with ann');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee006', 'ee000000-0000-0000-0000-000000000006');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000ee002'),
            null, 'fay starts a one-to-one with bo -- ann is not in it');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000ee007'),
            null, 'bo starts a one-to-one with gus, while gus is still allowlisted');
reset role;

create temp table _grp as
  select c.id from public.conversations c where btrim(coalesce(c.title, '')) = 'ee-group';
create temp table _direct_bo_ann as
  select c.id
    from public.conversations c
    join public.conversation_members a on a.conversation_id = c.id
     and a.user_id = '00000000-0000-0000-0000-0000000ee001'
    join public.conversation_members b on b.conversation_id = c.id
     and b.user_id = '00000000-0000-0000-0000-0000000ee002'
   where c.direct_key is not null;
create temp table _direct_fay_bo as
  select c.id
    from public.conversations c
    join public.conversation_members a on a.conversation_id = c.id
     and a.user_id = '00000000-0000-0000-0000-0000000ee006'
    join public.conversation_members b on b.conversation_id = c.id
     and b.user_id = '00000000-0000-0000-0000-0000000ee002'
   where c.direct_key is not null;
create temp table _direct_bo_gus as
  select c.id
    from public.conversations c
    join public.conversation_members a on a.conversation_id = c.id
     and a.user_id = '00000000-0000-0000-0000-0000000ee002'
    join public.conversation_members b on b.conversation_id = c.id
     and b.user_id = '00000000-0000-0000-0000-0000000ee007'
   where c.direct_key is not null;
grant select on _grp, _direct_bo_ann, _direct_fay_bo, _direct_bo_gus to authenticated;

-- 1 notification_settings is private, structurally -----------------------
select is((select relrowsecurity from pg_class where oid = 'public.notification_settings'::regclass),
          true, 'row level security is enabled on notification_settings');
select table_privs_are('public', 'notification_settings', 'anon', '{}'::text[],
                       'anon holds no privilege on notification_settings');
select table_privs_are('public', 'notification_settings', 'authenticated',
                       '{SELECT,INSERT,UPDATE}'::text[],
                       'authenticated holds select, insert and update but not delete');
set local role anon;
select throws_ok($$select * from public.notification_settings$$,
                 '42501', null, 'anon cannot read notification_settings');
reset role;

-- 2 own row only, and only while app access holds -------------------------
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok($$insert into public.notification_settings(enabled, preview)
                   values (true, 'full')$$,
                'ann creates her own settings row');
select is((select preview from public.notification_settings where user_id = auth.uid()),
          'full', 'ann reads her own row');
reset role;

-- cleo cannot read or write ann's row: the row exists and is visible with
-- RLS bypassed, so a zero count below is the policy, not an empty table.
select is((select count(*) from public.notification_settings
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          1::bigint, 'ann''s row exists (checked with RLS bypassed)');
select test_as('00000000-0000-0000-0000-0000000ee003', 'ee000000-0000-0000-0000-000000000003');
select is((select count(*) from public.notification_settings
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'another member cannot read ann''s settings');
select is(test_row_count(
            $$update public.notification_settings set enabled = false
               where user_id = '00000000-0000-0000-0000-0000000ee001'$$),
          0::bigint, 'another member''s update touches none of ann''s row');
select throws_ok(
  $$insert into public.notification_settings(user_id, enabled)
     values ('00000000-0000-0000-0000-0000000ee001', false)$$,
  '42501', null, 'a member cannot spoof another member''s settings row');
reset role;
select is((select enabled from public.notification_settings
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          true, 'ann''s row is unchanged by every attempt above');

-- no delete grant at all, even on your own row
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select throws_ok($$delete from public.notification_settings where user_id = auth.uid()$$,
                 '42501', null, 'nobody may delete a settings row, not even its owner');
reset role;

-- dee: active when she writes, revoked before she reads or writes again
select test_as('00000000-0000-0000-0000-0000000ee004', 'ee000000-0000-0000-0000-000000000004');
select lives_ok($$insert into public.notification_settings(enabled) values (false)$$,
                'dee creates her settings row while active');
reset role;
delete from auth.sessions where id = 'ee000000-0000-0000-0000-000000000004';
select test_as('00000000-0000-0000-0000-0000000ee004', 'ee000000-0000-0000-0000-000000000004');
select is((select count(*) from public.notification_settings where user_id = auth.uid()),
          0::bigint, 'a member whose session was revoked cannot read her own settings row');
select is(test_row_count(
            $$update public.notification_settings set enabled = true where user_id = auth.uid()$$),
          0::bigint, 'and cannot write it either');
reset role;

-- 3 notification_mutes is private, structurally ---------------------------
select is((select relrowsecurity from pg_class where oid = 'public.notification_mutes'::regclass),
          true, 'row level security is enabled on notification_mutes');
select table_privs_are('public', 'notification_mutes', 'anon', '{}'::text[],
                       'anon holds no privilege on notification_mutes');
select table_privs_are('public', 'notification_mutes', 'authenticated',
                       '{SELECT,INSERT,UPDATE,DELETE}'::text[],
                       'authenticated holds full CRUD on its own mutes');
set local role anon;
select throws_ok($$select * from public.notification_mutes$$,
                 '42501', null, 'anon cannot read notification_mutes');
reset role;

-- 4 what a mute may name, on insert -- each fixture fails ONE clause -------
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok(
  format($$insert into public.notification_mutes(kind, target) values ('conversation', %L)$$,
         (select id from _grp)),
  'ann mutes a conversation she is actually in');
select throws_ok(
  format($$insert into public.notification_mutes(kind, target) values ('conversation', %L)$$,
         (select id from _direct_fay_bo)),
  '42501', null, 'a conversation ann is not a member of is refused');
select throws_ok(
  $$insert into public.notification_mutes(kind, target)
     values ('person', '00000000-0000-0000-0000-0000000ee001')$$,
  '42501', null, 'muting yourself is refused');
select throws_ok(
  $$insert into public.notification_mutes(kind, target)
     values ('person', '00000000-0000-0000-0000-0000000ee005')$$,
  '42501', null, 'a person off the allowlist is refused as a mute target');
select lives_ok(
  $$insert into public.notification_mutes(kind, target)
     values ('person', '00000000-0000-0000-0000-0000000ee002')$$,
  'ann mutes bo, an allowlisted member she can otherwise see');
reset role;
select is((select count(*) from public.notification_mutes
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          2::bigint, 'only the two valid inserts landed');

-- own rows only, for read, write and delete
select test_as('00000000-0000-0000-0000-0000000ee003', 'ee000000-0000-0000-0000-000000000003');
select is((select count(*) from public.notification_mutes
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'another member cannot read ann''s mutes');
select is(test_row_count(
            $$update public.notification_mutes set until = now()
               where user_id = '00000000-0000-0000-0000-0000000ee001'$$),
          0::bigint, 'another member cannot update ann''s mutes');
select is(test_row_count(
            $$delete from public.notification_mutes
               where user_id = '00000000-0000-0000-0000-0000000ee001'$$),
          0::bigint, 'another member cannot delete ann''s mutes');
reset role;
select is((select count(*) from public.notification_mutes
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          2::bigint, 'ann''s two mutes survived every attempt above');

-- an update cannot move a row to another user, or launder it into a target
-- the write policy would have refused on insert
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select throws_ok(
  format($$update public.notification_mutes set user_id = '00000000-0000-0000-0000-0000000ee003'
            where user_id = auth.uid() and kind = 'conversation' and target = %L$$,
         (select id from _grp)),
  '42501', null, 'an update cannot hand a mute row to another member');
select throws_ok(
  format($$update public.notification_mutes set target = %L
            where user_id = auth.uid() and kind = 'conversation' and target = %L$$,
         (select id from _direct_fay_bo), (select id from _grp)),
  '42501', null, 'an update cannot move a conversation mute to one ann is not in');
select throws_ok(
  $$update public.notification_mutes set target = auth.uid()
     where user_id = auth.uid() and kind = 'person' and target = '00000000-0000-0000-0000-0000000ee002'$$,
  '42501', null, 'an update cannot turn a person mute into muting yourself');
select throws_ok(
  $$update public.notification_mutes set target = '00000000-0000-0000-0000-0000000ee005'
     where user_id = auth.uid() and kind = 'person' and target = '00000000-0000-0000-0000-0000000ee002'$$,
  '42501', null, 'an update cannot move a person mute to someone off the allowlist');
select lives_ok(
  format($$update public.notification_mutes set until = now() + interval '1 hour'
            where user_id = auth.uid() and kind = 'conversation' and target = %L$$,
         (select id from _grp)),
  'an update within the allowed shape -- setting an expiry -- still works');
reset role;

-- clean slate: remove both scratch mutes before the delivery-list tests, so
-- ann starts them unmuted.
delete from public.notification_mutes where user_id = '00000000-0000-0000-0000-0000000ee001';
select is((select count(*) from public.notification_mutes
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'ann enters the delivery-list tests with no mutes');
delete from public.notification_settings where user_id = '00000000-0000-0000-0000-0000000ee001';
select is((select count(*) from public.notification_settings
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'and no settings row -- the defaults are what get exercised first');

-- 5 messages, sent while ann has no settings row and no mutes --------------
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee002', 'short group message under limit' from _grp;
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee002', repeat('x', 130) from _grp;
insert into public.messages(conversation_id, sender_id, body, attachment_path)
  select id, '00000000-0000-0000-0000-0000000ee002', 'look', 'ee-group/photo1.jpg' from _grp;
insert into public.messages(conversation_id, sender_id, body, attachment_path)
  select id, '00000000-0000-0000-0000-0000000ee002', '', 'ee-group/photo2.jpg' from _grp;
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee002', 'direct hello' from _direct_bo_ann;
reset role;

create temp table _msg as
  select
    (select id from public.messages where conversation_id = (select id from _grp)
      and body = 'short group message under limit') as short,
    (select id from public.messages where conversation_id = (select id from _grp)
      and body = repeat('x', 130)) as long,
    (select id from public.messages where conversation_id = (select id from _grp)
      and attachment_path = 'ee-group/photo1.jpg') as photo_cap,
    (select id from public.messages where conversation_id = (select id from _grp)
      and attachment_path = 'ee-group/photo2.jpg') as photo_nocap,
    (select id from public.messages where conversation_id = (select id from _direct_bo_ann)
      and body = 'direct hello') as direct;

-- 6 no row = defaults, and the full-preview format -------------------------
select is((select count(*) from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          1::bigint, 'with no settings row, ann is still a target -- enabled defaults to true');
select is((select title from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'Bo @ ee-group', 'the default preview is full: the sender''s name plus the group');
select is((select body from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'short group message under limit', 'and the body is the trimmed text');
select is((select title from app_private.push_targets_for_message((select direct from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'Bo', 'a one-to-one has no group to append');
select is((select body from app_private.push_targets_for_message((select long from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          left(repeat('x', 130), 119) || '…', 'text over 120 characters is cut to 119 plus an ellipsis');
select is((select body from app_private.push_targets_for_message((select photo_cap from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          '📷 look', 'a photo with a caption is prefixed with a camera');
select is((select body from app_private.push_targets_for_message((select photo_nocap from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          '📷 Photo', 'a photo with no caption just says so');

-- the sender-name fallback, for the one message sent after bo's profile
-- is gone -- kept last among the naming assertions so it cannot affect
-- any of the ones above.
create temp table _bo_profile as
  select * from public.profiles where user_id = '00000000-0000-0000-0000-0000000ee002';
delete from public.profiles where user_id = '00000000-0000-0000-0000-0000000ee002';
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee002', 'sent with no profile row' from _grp;
reset role;
select is((select title from app_private.push_targets_for_message(
             (select id from public.messages where body = 'sent with no profile row')))
             , 'Someone @ ee-group', 'a sender with no profile row is shown as Someone');
-- restored: every assertion below this line that names bo again needs his name back.
insert into public.profiles select * from _bo_profile;

-- 6b removal from the allowlist removes the recipient, even with a live
-- session, a device token and a membership all still in place -----------
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee002', 'to gus before he is delisted' from _direct_bo_gus;
reset role;
select is((select count(*) from app_private.push_targets_for_message(
             (select id from public.messages where body = 'to gus before he is delisted'))
            where user_id = '00000000-0000-0000-0000-0000000ee007'),
          1::bigint, 'gus is a target while still on the allowlist');
delete from app_private.allowlist where email = 'gus@ns.test';
select is((select exists (select 1 from public.conversation_members
                           where user_id = '00000000-0000-0000-0000-0000000ee007')
              and exists (select 1 from app_private.device_tokens
                           where user_id = '00000000-0000-0000-0000-0000000ee007')
              and exists (select 1 from app_private.active_sessions
                           where user_id = '00000000-0000-0000-0000-0000000ee007')
              and exists (select 1 from auth.sessions
                           where user_id = '00000000-0000-0000-0000-0000000ee007')
              and not exists (select 1 from app_private.allowlist where email = 'gus@ns.test')),
          true, 'gus still has membership, a token and a live session -- only the allowlist changed');
select is((select count(*) from app_private.push_targets_for_message(
             (select id from public.messages where body = 'to gus before he is delisted'))
            where user_id = '00000000-0000-0000-0000-0000000ee007'),
          0::bigint, 'removed from the allowlist: no longer a target for the very same message');

-- 7 preview: sender and none, keyed off the RECIPIENT's own setting --------
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok($$insert into public.notification_settings(preview) values ('sender')$$,
                'ann sets her preview to sender-only');
reset role;
select is((select title from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'Bo', 'sender preview names only the sender -- no group suffix, unlike full');
select is((select body from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'New message', 'sender preview never shows the text');
select is((select body from app_private.push_targets_for_message((select photo_cap from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'New message', 'not even a caption, when the recipient asked for sender-only');

select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok($$update public.notification_settings set preview = 'none' where user_id = auth.uid()$$,
                'ann sets her preview to none');
reset role;
select is((select title from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'SIS', 'none preview hides even the sender''s name');
select is((select body from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          'New message', 'and still says only that a message exists');

-- 8 enabled=false removes the recipient from every list --------------------
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok($$update public.notification_settings
                   set preview = 'full', enabled = false where user_id = auth.uid()$$,
                'ann turns notifications off entirely');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'disabled: not a target for the group message');
select is((select count(*) from app_private.push_targets_for_message((select direct from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'disabled: not a target for the one-to-one either');
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok($$update public.notification_settings set enabled = true where user_id = auth.uid()$$,
                'ann turns notifications back on');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          1::bigint, 're-enabled: a target again');

-- 9 mutes: scoped exclusion, and an expired mute excludes nobody -----------
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok(
  format($$insert into public.notification_mutes(kind, target) values ('conversation', %L)$$,
         (select id from _grp)),
  'ann mutes the group conversation');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select short from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'a muted conversation: not a target for a message in it');
select is((select count(*) from app_private.push_targets_for_message((select direct from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          1::bigint, 'the mute does not reach a different conversation with the same sender');
delete from public.notification_mutes
 where user_id = '00000000-0000-0000-0000-0000000ee001' and kind = 'conversation';

select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select lives_ok(
  $$insert into public.notification_mutes(kind, target, until)
     values ('person', '00000000-0000-0000-0000-0000000ee002', now() + interval '1 hour')$$,
  'ann mutes bo as a person, for the next hour');
select lives_ok(
  $$insert into public.notification_mutes(kind, target, until)
     values ('person', '00000000-0000-0000-0000-0000000ee003', now() - interval '1 hour')$$,
  'ann also has an already-expired mute on cleo');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select direct from _msg))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          0::bigint, 'an unexpired person mute removes bo''s message, in any conversation');
select test_as('00000000-0000-0000-0000-0000000ee003', 'ee000000-0000-0000-0000-000000000003');
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee003', 'from cleo, past her expired mute' from _grp;
reset role;
select is((select count(*) from app_private.push_targets_for_message(
             (select id from public.messages where body = 'from cleo, past her expired mute'))
            where user_id = '00000000-0000-0000-0000-0000000ee001'),
          1::bigint, 'an expired mute on cleo excludes nobody -- her message still reaches ann');
delete from public.notification_mutes where user_id = '00000000-0000-0000-0000-0000000ee001';

-- 10 public.push_targets: service_role only, claims once, and only fresh --
select function_privs_are('public', 'push_targets', array['uuid'], 'anon',
                          '{}'::text[], 'anon holds no execute on push_targets');
select function_privs_are('public', 'push_targets', array['uuid'], 'authenticated',
                          '{}'::text[], 'authenticated holds no execute on push_targets');
select function_privs_are('public', 'push_targets', array['uuid'], 'service_role',
                          '{EXECUTE}'::text[], 'only service_role may call push_targets');
set local role anon;
select throws_ok($$select * from public.push_targets(null)$$,
                 '42501', null, 'anon cannot call push_targets');
reset role;
select test_as('00000000-0000-0000-0000-0000000ee001', 'ee000000-0000-0000-0000-000000000001');
select throws_ok($$select * from public.push_targets(null)$$,
                 '42501', null, 'a member cannot call push_targets either');
reset role;

select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee002', 'claim test message' from _grp;
insert into public.messages(conversation_id, sender_id, body)
  select id, '00000000-0000-0000-0000-0000000ee002', 'old claim test message' from _grp;
reset role;
create temp table _claim as
  select
    (select id from public.messages where body = 'claim test message') as fresh,
    (select id from public.messages where body = 'old claim test message') as old;
grant select on _claim to service_role;
update public.messages set created_at = now() - interval '3 minutes'
 where id = (select old from _claim);

set local role service_role;
select is((select count(*) from public.push_targets((select fresh from _claim))),
          1::bigint, 'the first call returns the same delivery list app_private would');
select is((select string_agg(token, ',') from public.push_targets((select fresh from _claim))),
          null, 'a second call for the same message returns nobody -- it is already claimed');
select is((select count(*) from public.push_targets((select old from _claim))),
          0::bigint, 'a message more than two minutes old returns nobody, claimed or not');
reset role;
select is((select count(*) from app_private.push_sent where message_id = (select fresh from _claim)),
          1::bigint, 'the fresh message was claimed exactly once');
select is((select count(*) from app_private.push_sent where message_id = (select old from _claim)),
          0::bigint, 'the stale message was never claimed at all');

-- 11 the trigger: nothing queued without a URL, exactly one request with it
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
select lives_ok($$insert into public.messages(conversation_id, sender_id, body)
                   select id, auth.uid(), 'no secret set yet' from _grp$$,
                'an insert succeeds with no notify URL configured');
reset role;
select is((select count(*) from net.http_request_queue), 0::bigint,
          'and queues nothing at all');

select vault.create_secret('https://ns-test.local/hook', 'notify_on_message_url');
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
select lives_ok($$insert into public.messages(conversation_id, sender_id, body)
                   select id, auth.uid(), 'this text must never leave the database' from _grp$$,
                'an insert succeeds once a notify URL is configured');
reset role;
select is((select count(*) from net.http_request_queue), 1::bigint,
          'exactly one request is queued');
select is((select url from net.http_request_queue), 'https://ns-test.local/hook',
          'queued for the URL held in Vault');
select is((select convert_from(body, 'utf8')::jsonb from net.http_request_queue),
          jsonb_build_object('record', jsonb_build_object('id',
            (select id from public.messages where body = 'this text must never leave the database'))),
          'the request body carries only the message id -- no text, no other field');

-- a URL Vault holds but pg_net cannot use must never cost the message: the
-- insert is the whole point, the notification is a courtesy.
select vault.update_secret(
  (select id from vault.secrets where name = 'notify_on_message_url'),
  'not a url at all');
select test_as('00000000-0000-0000-0000-0000000ee002', 'ee000000-0000-0000-0000-000000000002');
select lives_ok($$insert into public.messages(conversation_id, sender_id, body)
                   select id, auth.uid(), 'sent despite a malformed notify url' from _grp$$,
                'an insert still succeeds when the configured notify URL is malformed');
reset role;
select is((select count(*) from public.messages where body = 'sent despite a malformed notify url'),
          1::bigint, 'and the message row exists');

select * from finish();
rollback;
