begin;
select plan(55);

-- A device token is a push target only for the session that registered it.
--
-- device_tokens.session_id records the registering session. A token is on the
-- delivery list only while that session is BOTH the member's active_sessions
-- row AND still present in auth.sessions. A null session_id is never a target.
-- The two gates fail differently, so each has a fixture that passes the other:
--
-- * displaced (dan, dio): the session still exists in auth.sessions; only the
--   active_sessions row moved to a newer session. Fails the active-session gate.
-- * signed out (sol): active_sessions still names the session; only the
--   auth.sessions row is gone. Fails the auth.sessions gate.
-- * unbound (una): a live active session, a token row with session_id null.
--   Fails only the "bound at all" gate -- proved by binding it afterwards.
--
-- Every fixture is a member of one group with a sender (sid), so the only
-- thing that can keep a token off the list is its session binding.
--
-- fixtures -------------------------------------------------------------------
-- sid  sender
-- dan  android token in session A, displaced by session B
-- dio  ios token in session A, displaced by session B
-- sol  token in session A, A signed out of auth.sessions
-- fox  token, then forget_device_token
-- una  raw row with session_id null, live active session
-- reb  same token re-registered from a new session: rebinds
-- hx   hands a token over to hy (another member, same token)
-- mis  registers with no session claim; mal with a malformed one
-- bf1  legacy row, live active session           -> backfill binds
-- bf2  legacy row, never claimed a device        -> stays unbound
-- bf3  legacy row, active_sessions names a signed-out session -> stays unbound
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000e5001', 'sid@pts.test', now(), '{"full_name":"Sid"}'),
  ('00000000-0000-0000-0000-0000000e5002', 'dan@pts.test', now(), '{"full_name":"Dan"}'),
  ('00000000-0000-0000-0000-0000000e5003', 'dio@pts.test', now(), '{"full_name":"Dio"}'),
  ('00000000-0000-0000-0000-0000000e5004', 'sol@pts.test', now(), '{"full_name":"Sol"}'),
  ('00000000-0000-0000-0000-0000000e5005', 'fox@pts.test', now(), '{"full_name":"Fox"}'),
  ('00000000-0000-0000-0000-0000000e5006', 'una@pts.test', now(), '{"full_name":"Una"}'),
  ('00000000-0000-0000-0000-0000000e5007', 'reb@pts.test', now(), '{"full_name":"Reb"}'),
  ('00000000-0000-0000-0000-0000000e5008', 'hx@pts.test',  now(), '{"full_name":"Hx"}'),
  ('00000000-0000-0000-0000-0000000e5009', 'hy@pts.test',  now(), '{"full_name":"Hy"}'),
  ('00000000-0000-0000-0000-0000000e5010', 'mis@pts.test', now(), '{"full_name":"Mis"}'),
  ('00000000-0000-0000-0000-0000000e5011', 'mal@pts.test', now(), '{"full_name":"Mal"}'),
  ('00000000-0000-0000-0000-0000000e5012', 'bf1@pts.test', now(), '{"full_name":"Bf1"}'),
  ('00000000-0000-0000-0000-0000000e5013', 'bf2@pts.test', now(), '{"full_name":"Bf2"}'),
  ('00000000-0000-0000-0000-0000000e5014', 'bf3@pts.test', now(), '{"full_name":"Bf3"}');
insert into app_private.allowlist(email)
  select email from auth.users where email like '%@pts.test';
insert into app_private.tag_finds(finder, found_id)
  select '00000000-0000-0000-0000-0000000e5001', id from auth.users
   where email like '%@pts.test' and id <> '00000000-0000-0000-0000-0000000e5001';

-- Session ids: e5<user>a is the first phone, e5<user>b the second. The first
-- is two hours older so "newer session" is well defined within one transaction.
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('e5000000-0000-0000-0000-00000000' || right(u.id::text, 3) || 'a')::uuid, u.id,
         now() - interval '2 hours', now()
    from auth.users u where u.email like '%@pts.test'
  union all
  select ('e5000000-0000-0000-0000-00000000' || right(u.id::text, 3) || 'b')::uuid, u.id, now(), now()
    from auth.users u where u.email like '%@pts.test';

create or replace function pts_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;
-- A claim set with no session_id at all.
create or replace function pts_as_sessionless(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid))::text, true);
  execute 'set local role authenticated';
end $$;
-- Registers and reports the SQLSTATE instead of aborting; the contract for a
-- bad claim is about what is stored, not how the call is refused.
create or replace function pts_try_register(tok text, plat text) returns text language plpgsql as $$
begin
  perform public.register_device_token(tok, plat);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
grant execute on function pts_try_register(text, text) to authenticated;

create or replace function pts_sess(n int, phone text) returns text language sql as $$
  select 'e5000000-0000-0000-0000-00000000' || lpad(n::text, 3, '0') || phone
$$;
create or replace function pts_uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000e5' || lpad(n::text, 3, '0'))::uuid
$$;
grant execute on function pts_sess(int, text), pts_uid(int) to authenticated;

-- Everyone but bf2 (never claims) claims the device on phone a.
do $$
declare n int;
begin
  foreach n in array array[1,2,3,4,5,6,7,8,9,10,11,12,14] loop
    perform pts_as(pts_uid(n), pts_sess(n, 'a'));
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    reset role;
  end loop;
end $$;

-- the conversation -------------------------------------------------------------
select pts_as(pts_uid(1), pts_sess(1, 'a'));
select isnt(public.start_group_conversation('pgtap-pts',
              array(select pts_uid(n) from generate_series(2, 14) n)),
            null, 'sid starts the group with everyone');
reset role;
create temp table _c as
  select id from public.conversations where btrim(coalesce(title, '')) = 'pgtap-pts';
grant select on _c to authenticated;
select pts_as(pts_uid(1), pts_sess(1, 'a'));
insert into public.messages(conversation_id, sender_id, body)
  select id, pts_uid(1), 'pgtap pts message' from _c;
reset role;
create temp table _m as
  select m.id from public.messages m join _c on m.conversation_id = _c.id;

create or replace function pts_targets() returns setof text language sql as $$
  select token from app_private.push_targets_for_message((select id from _m))
$$;

-- 1 register stores the caller's session ---------------------------------------
select pts_as(pts_uid(2), pts_sess(2, 'a'));
select lives_ok($$select public.register_device_token('pts-dan-token-a', 'android')$$,
                'dan registers on phone a');
reset role;
select pts_as(pts_uid(3), pts_sess(3, 'a'));
select lives_ok($$select public.register_device_token('pts-dio-token-a', 'ios')$$,
                'dio registers an iPhone on phone a');
reset role;
select is((select session_id::text from app_private.device_tokens where token = 'pts-dan-token-a'),
          pts_sess(2, 'a'), 'the row records the session the claim named (jwt_session_id)');
select is((select session_id::text from app_private.device_tokens where token = 'pts-dio-token-a'),
          pts_sess(3, 'a'), 'on ios too');
-- the signature has no session parameter: the client cannot name one
select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'register_device_token'
              and (p.proargnames @> array['session_id'] or pg_get_function_arguments(p.oid) ~* 'uuid')),
          0::bigint, 'register_device_token takes no session argument from the client');

-- positive control: both are targets before anything is displaced
select is((select count(*) from pts_targets() t where t in ('pts-dan-token-a', 'pts-dio-token-a')),
          2::bigint, 'control: a token bound to the live active session is a target');

-- 2 displaced -----------------------------------------------------------------
select pts_as(pts_uid(2), pts_sess(2, 'b'));
select is(public.activate_session(), true, 'dan''s phone b takes the device over');
reset role;
select pts_as(pts_uid(3), pts_sess(3, 'b'));
select is(public.activate_session(), true, 'dio''s phone b takes the device over');
reset role;
select is((select count(*) from auth.sessions where id::text in (pts_sess(2, 'a'), pts_sess(3, 'a'))),
          2::bigint, 'fixture: the displaced sessions still exist in auth.sessions');
select is((select count(*) from app_private.device_tokens
            where token in ('pts-dan-token-a', 'pts-dio-token-a')),
          2::bigint, 'fixture: the displaced tokens are still stored');
select is((select count(*) from pts_targets() t where t = 'pts-dan-token-a'),
          0::bigint, 'a displaced android token is not a target');
select is((select count(*) from pts_targets() t where t = 'pts-dio-token-a'),
          0::bigint, 'a displaced ios token is not a target');
select is((select count(*) from app_private.push_targets_for_message((select id from _m))
            where user_id in (pts_uid(2), pts_uid(3))),
          0::bigint, 'neither displaced member is on the list until phone b registers');

select pts_as(pts_uid(2), pts_sess(2, 'b'));
select lives_ok($$select public.register_device_token('pts-dan-token-b', 'android')$$,
                'dan registers phone b');
reset role;
select is((select string_agg(token, ',') from app_private.push_targets_for_message((select id from _m))
            where user_id = pts_uid(2)),
          'pts-dan-token-b', 'after phone b registers, only phone b is a target');

-- 3 signed out ----------------------------------------------------------------
select pts_as(pts_uid(4), pts_sess(4, 'a'));
select lives_ok($$select public.register_device_token('pts-sol-token-a', 'ios')$$,
                'sol registers');
reset role;
select is((select count(*) from pts_targets() t where t = 'pts-sol-token-a'),
          1::bigint, 'control: sol is a target while signed in');
delete from auth.sessions where id::text = pts_sess(4, 'a');
select is((select a.session_id::text from app_private.active_sessions a where a.user_id = pts_uid(4)),
          pts_sess(4, 'a'), 'fixture: active_sessions still names the signed-out session');
select is((select session_id::text from app_private.device_tokens where token = 'pts-sol-token-a'),
          pts_sess(4, 'a'), 'fixture: the token is still bound to it');
select is((select count(*) from pts_targets() t where t = 'pts-sol-token-a'),
          0::bigint, 'a token whose session was signed out is not a target');

-- 4 forget ----------------------------------------------------------------------
select pts_as(pts_uid(5), pts_sess(5, 'a'));
select lives_ok($$select public.register_device_token('pts-fox-token-a', 'android')$$,
                'fox registers');
reset role;
select is((select count(*) from pts_targets() t where t = 'pts-fox-token-a'),
          1::bigint, 'control: fox is a target');
select pts_as(pts_uid(5), pts_sess(5, 'a'));
select lives_ok($$select public.forget_device_token('pts-fox-token-a')$$, 'fox forgets his token');
reset role;
select is((select count(*) from pts_targets() t where t = 'pts-fox-token-a'),
          0::bigint, 'a forgotten token is not a target');

-- 5 unbound ---------------------------------------------------------------------
insert into app_private.device_tokens(user_id, token, platform)
  values (pts_uid(6), 'pts-una-token-raw', 'android');
select is((select session_id from app_private.device_tokens where token = 'pts-una-token-raw'),
          null, 'fixture: a raw row has no session');
select is((select a.session_id::text from app_private.active_sessions a
             join auth.sessions s on s.id = a.session_id where a.user_id = pts_uid(6)),
          pts_sess(6, 'a'), 'fixture: una holds a live active session');
select is((select count(*) from pts_targets() t where t = 'pts-una-token-raw'),
          0::bigint, 'an unbound token is never a target, even with a live active session');
-- Proves null is the only thing keeping it off: bound, it is a target.
update app_private.device_tokens set session_id = pts_sess(6, 'a')::uuid where token = 'pts-una-token-raw';
select is((select count(*) from pts_targets() t where t = 'pts-una-token-raw'),
          1::bigint, 'control: the same row, bound to the live session, is a target');
update app_private.device_tokens set session_id = null where token = 'pts-una-token-raw';

-- 6 re-register from a new session rebinds ---------------------------------------
select pts_as(pts_uid(7), pts_sess(7, 'a'));
select lives_ok($$select public.register_device_token('pts-reb-token', 'android')$$,
                'reb registers on phone a');
reset role;
select pts_as(pts_uid(7), pts_sess(7, 'b'));
select is(public.activate_session(), true, 'reb''s session b takes over (same handset, new sign-in)');
select lives_ok($$select public.register_device_token('pts-reb-token', 'android')$$,
                'the same token is registered from session b');
reset role;
select is((select session_id::text from app_private.device_tokens where token = 'pts-reb-token'),
          pts_sess(7, 'b'), 're-registering the same token rebinds it to the new session');
select is((select count(*) from pts_targets() t where t = 'pts-reb-token'),
          1::bigint, 'and the rebound token is a target again');

-- 7 no app access: 42501, nothing written ---------------------------------------
-- Session a still exists in auth.sessions but no longer holds the device.
select pts_as(pts_uid(7), pts_sess(7, 'a'));
select throws_ok($$select public.register_device_token('pts-reb-token', 'android')$$,
                 '42501', null, 'the displaced session cannot register');
select throws_ok($$select public.register_device_token('pts-reb-other', 'android')$$,
                 '42501', null, 'nor register a new token');
reset role;
select is((select session_id::text from app_private.device_tokens where token = 'pts-reb-token'),
          pts_sess(7, 'b'), 'a refused registration does not rebind the token');
select is((select count(*) from app_private.device_tokens where token = 'pts-reb-other'),
          0::bigint, 'a refused registration writes no row');

-- 8 handover: the same token moves to another member ------------------------------
select pts_as(pts_uid(8), pts_sess(8, 'a'));
select lives_ok($$select public.register_device_token('pts-shared-handset', 'android')$$,
                'hx registers a handset');
reset role;
select pts_as(pts_uid(9), pts_sess(9, 'a'));
select lives_ok($$select public.register_device_token('pts-shared-handset', 'android')$$,
                'hy signs in on the same handset and registers it');
reset role;
select is((select count(*) from app_private.device_tokens
            where token = 'pts-shared-handset' and user_id = pts_uid(8)),
          0::bigint, 'handover deletes the previous member''s row for the token');
select is((select user_id::text || '@' || session_id::text from app_private.device_tokens
            where token = 'pts-shared-handset'),
          pts_uid(9)::text || '@' || pts_sess(9, 'a'), 'the token now belongs to hy, bound to hy''s session');
select is((select string_agg(user_id::text, ',') from app_private.push_targets_for_message((select id from _m))
            where token = 'pts-shared-handset'),
          pts_uid(9)::text, 'only hy is reached on the handed-over handset');

-- 9 a missing or malformed session claim ------------------------------------------
select pts_as_sessionless(pts_uid(10));
create temp table _mis as select pts_try_register('pts-mis-token', 'android') as st;
reset role;
select pts_as(pts_uid(11), 'not-a-uuid');
create temp table _mal as select pts_try_register('pts-mal-token', 'android') as st;
reset role;
select is((select count(*) from app_private.device_tokens
            where token in ('pts-mis-token', 'pts-mal-token') and session_id is not null),
          0::bigint, 'a missing or malformed session claim binds no token');
select lives_ok($$select * from app_private.push_targets_for_message((select id from _m))$$,
                'push_targets does not error after a bad claim');
select is((select count(*) from pts_targets() t where t in ('pts-mis-token', 'pts-mal-token')),
          0::bigint, 'and neither token is a target');

-- 10 backfill, replayed from the applied migration --------------------------------
-- The legacy state: rows written before session_id existed. The UPDATE is taken
-- from the migration as the database recorded it, so a change to the migration
-- is a change to what runs here.
insert into app_private.device_tokens(user_id, token, platform) values
  (pts_uid(12), 'pts-bf1-legacy', 'android'),
  (pts_uid(13), 'pts-bf2-legacy', 'ios'),
  (pts_uid(14), 'pts-bf3-legacy', 'ios');
delete from auth.sessions where id::text = pts_sess(14, 'a');
select is((select count(*) from app_private.active_sessions where user_id = pts_uid(13)),
          0::bigint, 'fixture: bf2 has no active session');
select is((select count(*) from app_private.active_sessions a where a.user_id = pts_uid(14)
             and not exists (select 1 from auth.sessions s where s.id = a.session_id)),
          1::bigint, 'fixture: bf3''s active session is signed out');
select is((select count(*) from auth.sessions where user_id = pts_uid(13)),
          2::bigint, 'fixture: bf2 has live auth sessions, just never an active one');

create temp table _bf as
  select st from supabase_migrations.schema_migrations m, unnest(m.statements) st
   where m.version = '20260930160000'
     and st ~* 'update\s+app_private\.device_tokens'
     and st !~* 'create\s+(or\s+replace\s+)?function';
select is((select count(*) from _bf), 1::bigint, 'the migration carries one backfill update');
do $$ begin execute (select st from _bf); end $$;

select is((select session_id::text from app_private.device_tokens where token = 'pts-bf1-legacy'),
          pts_sess(12, 'a'), 'backfill binds a legacy row to the member''s live active session');
select is((select count(*) from pts_targets() t where t = 'pts-bf1-legacy'),
          1::bigint, 'and it becomes a target');
select is((select session_id from app_private.device_tokens where token = 'pts-bf2-legacy'),
          null, 'backfill leaves a member with no active session unbound');
select is((select session_id from app_private.device_tokens where token = 'pts-bf3-legacy'),
          null, 'backfill leaves a member whose active session is signed out unbound');
select is((select count(*) from pts_targets() t where t in ('pts-bf2-legacy', 'pts-bf3-legacy')),
          0::bigint, 'neither is a target');

select * from finish();
rollback;
