begin;
select plan(52);

-- Who shows a push itself (v0.12), and why older builds must not go quiet.
--
-- From 0.12 the app draws its own grouped notification and wants DATA-ONLY
-- pushes. A build of 0.11 or older has no code to draw a data-only push: sent
-- one, it shows nothing. Updates are never forced, so the database has to
-- know, per device, which of the two it is talking to:
--
-- 1. device_tokens.shows_itself -- false for every device that did not say
--    otherwise, including every row written before this column existed.
-- 2. register_device_token(device_token, device_platform, shows_itself
--    default false) is
--    the ONLY register_device_token. An older build keeps calling it with two
--    arguments (by name, through PostgREST) and must land on false; a second
--    two-argument overload left beside it would make that call ambiguous or,
--    worse, silently keep writing a row without the flag.
-- 3. Re-registering is a statement of what the device is NOW: the same phone
--    registering with two arguments after three (a downgrade, or the old app
--    restored from a backup) goes back to false.
-- 4. The delivery list (push_targets_for_message, and public.push_targets
--    over it) carries the flag, so the sender can split the two kinds.
-- 5. None of this loosens the table: still private, still one device per
--    member, still taken from whoever held the token before.

-- fixtures -------------------------------------------------------------------
-- ava   allowlisted, active   sender
-- ben   allowlisted, active   the new build (shows_itself = true)
-- cyd   allowlisted, active   the old build (two-argument call)
-- dot   allowlisted, active   receives a handset ava's token was on
-- eli   allowlisted, active   mutes the chat on a new-build phone
-- ben also has a second, newer session: the phone he moves to.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000c1001', 'ava@display.test', now(), '{"full_name":"Ava"}'),
  ('00000000-0000-0000-0000-0000000c1002', 'ben@display.test', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-0000000c1003', 'cyd@display.test', now(), '{"full_name":"Cyd"}'),
  ('00000000-0000-0000-0000-0000000c1004', 'dot@display.test', now(), '{"full_name":"Dot"}'),
  ('00000000-0000-0000-0000-0000000c1005', 'eli@display.test', now(), '{"full_name":"Eli"}');
insert into app_private.allowlist(email) values
  ('ava@display.test'), ('ben@display.test'), ('cyd@display.test'),
  ('dot@display.test'), ('eli@display.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('c1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000c1001', now(), now()),
  ('c1000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000c1002', now() - interval '2 hours', now()),
  ('c1000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000c1003', now(), now()),
  ('c1000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000c1004', now(), now()),
  ('c1000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000c1005', now(), now()),
  ('c1000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-0000000c1002', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-0000000c1001', 'c1000000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'ava is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'ben is active on his first phone');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1003', 'c1000000-0000-0000-0000-000000000003');
select is(public.activate_session(), true, 'cyd is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1004', 'c1000000-0000-0000-0000-000000000004');
select is(public.activate_session(), true, 'dot is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000c1005', 'c1000000-0000-0000-0000-000000000005');
select is(public.activate_session(), true, 'eli is active');
reset role;

-- 1 the column ---------------------------------------------------------------
select has_column('app_private', 'device_tokens', 'shows_itself',
                  'device_tokens says whether the device shows pushes itself');
select col_type_is('app_private', 'device_tokens', 'shows_itself', 'boolean',
                   'and it is a boolean');
-- A row written the way every row before this migration was written -- no
-- shows_itself at all -- is an older build and must read false, not null.
insert into app_private.device_tokens(user_id, token, platform)
  values ('00000000-0000-0000-0000-0000000c1004', 'dot-legacy-row', 'android');
select is((select shows_itself from app_private.device_tokens where token = 'dot-legacy-row'),
          false, 'a row that never mentions the flag is an older build: false');
delete from app_private.device_tokens where token = 'dot-legacy-row';

-- 2 one function, three arguments, and who may call it -------------------------
select has_function('public', 'register_device_token', array['text', 'text', 'boolean'],
                    'register_device_token takes token, platform and shows_itself');
select hasnt_function('public', 'register_device_token', array['text', 'text'],
                      'the two-argument register_device_token is gone');
select is((select count(*) from pg_proc
            where proname = 'register_device_token'
              and pronamespace = 'public'::regnamespace),
          1::bigint, 'exactly one register_device_token: an old two-argument call has one place to land');
-- PostgREST calls by NAME, so the names are part of the contract an older
-- build depends on.
select is((select proargnames::text from pg_proc
            where proname = 'register_device_token'
              and pronamespace = 'public'::regnamespace),
          '{device_token,device_platform,shows_itself}',
          'its parameters keep the names older builds send: device_token, device_platform (+ shows_itself)');
select function_privs_are('public', 'register_device_token', array['text', 'text', 'boolean'],
                          'anon', '{}'::text[], 'anon holds no execute on register_device_token');
select function_privs_are('public', 'register_device_token', array['text', 'text', 'boolean'],
                          'authenticated', '{EXECUTE}'::text[],
                          'authenticated may execute register_device_token');
select is((select has_function_privilege('public',
             'public.register_device_token(text, text, boolean)', 'execute')),
          false, 'PUBLIC holds no execute: anon cannot reach it through the default grant');
set local role anon;
select throws_ok($$select public.register_device_token('anon-display-token', 'android', true)$$,
                 '42501', null, 'anon cannot register, with or without the flag');
reset role;

-- 3 what gets stored -----------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000002');
select lives_ok($$select public.register_device_token('ben-token-one', 'android', true)$$,
                'ben''s new build registers and says it shows pushes itself');
reset role;
select is((select shows_itself from app_private.device_tokens where token = 'ben-token-one'),
          true, 'true is stored');

select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000002');
select lives_ok($$select public.register_device_token('ben-token-one', 'android')$$,
                'the same phone registers again with two arguments (an older build back on it)');
reset role;
select is((select shows_itself from app_private.device_tokens where token = 'ben-token-one'),
          false, 'a two-argument re-register resets the flag to false');
select is((select count(*) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000c1002'),
          1::bigint, 'and it is still one row');

select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000002');
select lives_ok($$select public.register_device_token(device_token => 'ben-token-one',
                                                      device_platform => 'android',
                                                      shows_itself => true)$$,
                'called by name, the way PostgREST calls it for this build');
reset role;
select is((select shows_itself from app_private.device_tokens where token = 'ben-token-one'),
          true, 'updating the app switches the phone over');

select test_as('00000000-0000-0000-0000-0000000c1003', 'c1000000-0000-0000-0000-000000000003');
select lives_ok($$select public.register_device_token(device_token => 'cyd-token-one', device_platform => 'ios')$$,
                'cyd''s 0.11 build calls by name with only token and platform');
reset role;
select is((select shows_itself from app_private.device_tokens where token = 'cyd-token-one'),
          false, 'an older build''s call lands on false');

select test_as('00000000-0000-0000-0000-0000000c1005', 'c1000000-0000-0000-0000-000000000005');
select lives_ok($$select public.register_device_token('eli-token-one', 'android', true)$$,
                'eli registers a new-build phone');
reset role;

-- the gates are the same gates with the flag set
select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000002');
select throws_ok($$select public.register_device_token('123456789', 'android', true)$$,
                 '22023', null, 'the flag does not bypass the token check');
reset role;

-- 4 the delivery list carries it ------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000c1001', 'c1000000-0000-0000-0000-000000000001');
select isnt(public.start_group_conversation('pgtap-display',
              array['00000000-0000-0000-0000-0000000c1002',
                    '00000000-0000-0000-0000-0000000c1003',
                    '00000000-0000-0000-0000-0000000c1005']::uuid[]),
            null, 'ava starts a group with ben, cyd and eli');
reset role;
create temp table _grp as
  select c.id from public.conversations c where btrim(coalesce(c.title, '')) = 'pgtap-display';
grant select on _grp to authenticated, service_role;

select test_as('00000000-0000-0000-0000-0000000c1005', 'c1000000-0000-0000-0000-000000000005');
select lives_ok(format($$insert into public.notification_mutes(kind, target) values ('conversation', %L)$$,
                       (select id from _grp)),
                'eli mutes the group');
reset role;

select test_as('00000000-0000-0000-0000-0000000c1001', 'c1000000-0000-0000-0000-000000000001');
insert into public.messages(conversation_id, sender_id, body)
  select id, auth.uid(), 'display one' from _grp;
insert into public.messages(conversation_id, sender_id, body)
  select id, auth.uid(), 'display two' from _grp;
reset role;
create temp table _msg as
  select (select id from public.messages where body = 'display one') as one,
         (select id from public.messages where body = 'display two') as two;
grant select on _msg to service_role;

select is((select string_agg(shows_itself::text, ',') from app_private.push_targets_for_message((select one from _msg))
            where user_id = '00000000-0000-0000-0000-0000000c1002'),
          'true', 'push_targets_for_message: ben''s phone shows pushes itself');
select is((select string_agg(shows_itself::text, ',') from app_private.push_targets_for_message((select one from _msg))
            where user_id = '00000000-0000-0000-0000-0000000c1003'),
          'false', 'push_targets_for_message: cyd''s older build does not');
select is((select count(*) from app_private.push_targets_for_message((select one from _msg))),
          2::bigint, 'the list is still ben and cyd: not the sender, not eli');
select is((select count(*) from app_private.push_targets_for_message((select one from _msg))
            where user_id = '00000000-0000-0000-0000-0000000c1005'),
          0::bigint, 'a muted chat is not delivered, even to a phone that would group it');
select is((select string_agg(conversation_id::text, ',') from app_private.push_targets_for_message((select one from _msg))
            where user_id = '00000000-0000-0000-0000-0000000c1002'),
          (select id::text from _grp), 'the target names its conversation: the app groups by it');

set local role service_role;
create temp table _claimed as
  select user_id, token, shows_itself from public.push_targets((select two from _msg));
reset role;
select is((select string_agg(shows_itself::text, ',') from _claimed
            where user_id = '00000000-0000-0000-0000-0000000c1002'),
          'true', 'public.push_targets returns the flag: true for ben');
select is((select string_agg(shows_itself::text, ',') from _claimed
            where user_id = '00000000-0000-0000-0000-0000000c1003'),
          'false', 'and false for cyd');
select is((select count(*) from _claimed), 2::bigint,
          'public.push_targets returns the same two targets');

-- 5 the table is exactly as private as before ------------------------------------
select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000002');
select throws_ok($$select shows_itself from app_private.device_tokens$$,
                 '42501', null, 'a member cannot read the flag, his own or anyone''s');
select throws_ok($$update app_private.device_tokens set shows_itself = false
                    where user_id = '00000000-0000-0000-0000-0000000c1003'$$,
                 '42501', null, 'a member cannot flip another member''s flag directly');
select throws_ok($$delete from app_private.device_tokens
                    where user_id = '00000000-0000-0000-0000-0000000c1003'$$,
                 '42501', null, 'a member cannot delete another member''s token');
reset role;
select table_privs_are('app_private', 'device_tokens', 'authenticated', '{}'::text[],
                       'authenticated still holds no privilege on device_tokens');
select table_privs_are('app_private', 'device_tokens', 'anon', '{}'::text[],
                       'anon still holds no privilege on device_tokens');
select is((select relrowsecurity from pg_class where oid = 'app_private.device_tokens'::regclass),
          true, 'row level security is still on');
select is((select count(*) from pg_policies
            where schemaname = 'app_private' and tablename = 'device_tokens'),
          0::bigint, 'and there is still no policy');
select is((select shows_itself from app_private.device_tokens where token = 'cyd-token-one'),
          false, 'cyd''s flag is what cyd registered, whatever ben tried');

-- 6 one device per member, and a token belongs to one member ----------------------
select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000012');
select is(public.activate_session(), true, 'ben''s new phone takes the device over');
select lives_ok($$select public.register_device_token('ben-token-two', 'android')$$,
                'and registers with an older build on it');
reset role;
select is((select string_agg(token || ':' || shows_itself, ',') from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000c1002'),
          'ben-token-two:false', 'one row: the new phone, with the new phone''s flag');

select test_as('00000000-0000-0000-0000-0000000c1002', 'c1000000-0000-0000-0000-000000000002');
select throws_ok($$select public.register_device_token('ben-token-one', 'android', true)$$,
                 '42501', null, 'the replaced phone cannot register again, flag or not');
reset role;

-- ben's first phone goes to dot (an older build), holding the token ben's
-- new build registered with true.
update app_private.device_tokens set token = 'handed-over-token', shows_itself = true
 where user_id = '00000000-0000-0000-0000-0000000c1002';
select test_as('00000000-0000-0000-0000-0000000c1004', 'c1000000-0000-0000-0000-000000000004');
select lives_ok($$select public.register_device_token('handed-over-token', 'android')$$,
                'dot signs in on the handset and registers it with two arguments');
reset role;
select is((select count(*) from app_private.device_tokens
            where user_id = '00000000-0000-0000-0000-0000000c1002'),
          0::bigint, 'ben no longer holds the token');
select is((select string_agg(user_id::text || ':' || shows_itself, ',') from app_private.device_tokens
            where token = 'handed-over-token'),
          '00000000-0000-0000-0000-0000000c1004:false',
          'the token is dot''s, with what dot''s build said -- not what ben''s did');

select * from finish();
rollback;
