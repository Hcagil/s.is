begin;
select plan(97);

-- Read status (v0.11): profiles.share_read_status, public.read_marks(),
-- public.mark_read()'s added broadcast, app_private.reads_conversation(),
-- and the realtime.messages policies that open the reads:<conversation>
-- topic. Mutual, like last seen: read_marks() answers `shares = true` for
-- another member only when BOTH the caller and that member share; read_at
-- is null whenever shares is false. conversation_members.last_read_at stays
-- unreadable directly -- read_marks() is the only way to it.
--
-- One group G: ada, ben, cal, dan, eve, fay, gus. xan has her own
-- conversation X but is NOT in G (the membership gate). hal is a stranger,
-- never allowlisted.
--
-- Each negative fixture fails exactly ONE gate, proved by a positive control
-- (ada querying ben) that holds every other gate open:
--   cal   her own sharing off, otherwise a full member  -- caller-share gate
--   dan   his own sharing off, queried by a sharer      -- person-share gate
--   eve   delisted after joining, still sharing         -- person-allowlist gate
--   fay   on a replaced (old) session                   -- caller session gate
--   gus   never activated                                -- caller app-access gate
--   xan   active, allowlisted, NOT a member of G         -- membership gate
--   hal   never allowlisted at all                        -- caller allowlist gate
-- Everything runs in one transaction, so now() is one instant throughout.

-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000dd01', 'ada@reads.test', now(), '{"full_name":"Ada"}'),
  ('00000000-0000-0000-0000-00000000dd02', 'ben@reads.test', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-00000000dd03', 'cal@reads.test', now(), '{"full_name":"Cal"}'),
  ('00000000-0000-0000-0000-00000000dd04', 'dan@reads.test', now(), '{"full_name":"Dan"}'),
  ('00000000-0000-0000-0000-00000000dd05', 'eve@reads.test', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-00000000dd06', 'fay@reads.test', now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-00000000dd07', 'gus@reads.test', now(), '{"full_name":"Gus"}'),
  ('00000000-0000-0000-0000-00000000dd08', 'xan@reads.test', now(), '{"full_name":"Xan"}'),
  ('00000000-0000-0000-0000-00000000dd09', 'hal@reads.test', now(), '{"full_name":"Hal"}');
insert into app_private.allowlist(email) values
  ('ada@reads.test'), ('ben@reads.test'), ('cal@reads.test'), ('dan@reads.test'),
  ('eve@reads.test'), ('fay@reads.test'), ('gus@reads.test'), ('xan@reads.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ed000000-0000-0000-0000-00000000dd01', '00000000-0000-0000-0000-00000000dd01', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd02', '00000000-0000-0000-0000-00000000dd02', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd03', '00000000-0000-0000-0000-00000000dd03', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd04', '00000000-0000-0000-0000-00000000dd04', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd05', '00000000-0000-0000-0000-00000000dd05', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd06', '00000000-0000-0000-0000-00000000dd06', now() - interval '1 hour', now()),
  ('ed000000-0000-0000-0000-00000000d006', '00000000-0000-0000-0000-00000000dd06', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd07', '00000000-0000-0000-0000-00000000dd07', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd08', '00000000-0000-0000-0000-00000000dd08', now(), now()),
  ('ed000000-0000-0000-0000-00000000dd09', '00000000-0000-0000-0000-00000000dd09', now(), now());

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

-- One target's own row out of read_marks(), read as whoever the test is
-- acting as -- the same shape as last_seen_test.sql's stored() and
-- unread_test.sql's test_unread().
create or replace function shares_with(conv uuid, target uuid) returns boolean
language sql security invoker as $$
  select shares from public.read_marks(conv) where user_id = target
$$;
create or replace function read_at_of(conv uuid, target uuid) returns timestamptz
language sql security invoker as $$
  select read_at from public.read_marks(conv) where user_id = target
$$;
grant execute on function shares_with(uuid, uuid), read_at_of(uuid, uuid)
  to authenticated, anon;

-- May the caller send/receive on a topic+extension -- the same probes
-- presence_test.sql uses, since Realtime authorises a join the same way.
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
create or replace function can_receive(topic text, ext text) returns boolean
language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', coalesce(topic, ''), true);
  return exists (select 1 from realtime.messages m
                  where m.extension = ext and m.event = 'fixture');
end $$;
grant execute on function can_send(text, text), can_receive(text, text) to authenticated, anon;

-- mark_read as the current caller: 'ok', or the SQLSTATE it refused with.
create or replace function try_mark_read(conv uuid) returns text
language plpgsql security invoker as $$
begin
  perform public.mark_read(conv);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
grant execute on function try_mark_read(uuid) to authenticated, anon;

-- Broadcasts on G's reads: topic so far (read with RLS bypassed).
create or replace function reads_sent() returns bigint language plpgsql as $$
begin
  return (select count(*) from realtime.messages
           where topic = 'reads:' || (select id from _g)::text);
end $$;

-- Everyone with a session activates; fay's OLD phone first, so her new one
-- replaces it. gus never activates (tested standing, then activates as a
-- late control). hal is never allowlisted.
select test_as('00000000-0000-0000-0000-00000000dd06', 'ed000000-0000-0000-0000-00000000dd06');
select is(public.activate_session(), true, 'fay activates her old phone');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd06', 'ed000000-0000-0000-0000-00000000d006');
select is(public.activate_session(), true, 'fay moves to her new phone');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select is(public.activate_session(), true, 'ada is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd02', 'ed000000-0000-0000-0000-00000000dd02');
select is(public.activate_session(), true, 'ben is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd03', 'ed000000-0000-0000-0000-00000000dd03');
select is(public.activate_session(), true, 'cal is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd04', 'ed000000-0000-0000-0000-00000000dd04');
select is(public.activate_session(), true, 'dan is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd05', 'ed000000-0000-0000-0000-00000000dd05');
select is(public.activate_session(), true, 'eve is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd08', 'ed000000-0000-0000-0000-00000000dd08');
select is(public.activate_session(), true, 'xan is active');
reset role;

-- G: ada, ben, cal, dan, eve, fay. gus and xan and hal are not in it. xan
-- gets her own conversation X so her empty G answer is not universal silence.
-- Created AS ada / AS xan: the caller's identity (from the still-set JWT
-- claims) is what start_group_conversation/start_direct_conversation add as
-- a member, not the current role, so this must run through test_as like
-- every other write -- running it as postgres would add whoever's claims
-- were left over from the last test_as call instead of the intended caller.
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
create temp table _g as
  select public.start_group_conversation('reads', array[
    '00000000-0000-0000-0000-00000000dd02', '00000000-0000-0000-0000-00000000dd03',
    '00000000-0000-0000-0000-00000000dd04', '00000000-0000-0000-0000-00000000dd05',
    '00000000-0000-0000-0000-00000000dd06'
  ]::uuid[]) as id;
reset role;
select test_as('00000000-0000-0000-0000-00000000dd08', 'ed000000-0000-0000-0000-00000000dd08');
create temp table _x as
  select public.start_direct_conversation('00000000-0000-0000-0000-00000000dd01') as id;
reset role;
grant select on _g, _x to authenticated, anon;

-- cal never shares; dan never shares -- planted directly so the only
-- difference from a full positive control is that one switch.
update public.profiles set share_read_status = false
 where user_id in ('00000000-0000-0000-0000-00000000dd03', '00000000-0000-0000-0000-00000000dd04');
-- eve keeps sharing ON but is later delisted (person-allowlist gate only).

-- 1 schema and privileges ----------------------------------------------------
select col_not_null('public', 'profiles', 'share_read_status', 'share_read_status is not null');
select col_default_is('public', 'profiles', 'share_read_status', 'true', 'share_read_status defaults on');
select is((select share_read_status from public.profiles
            where user_id = '00000000-0000-0000-0000-00000000dd01'),
          true, 'a new member shares read status');
select ok(has_column_privilege('authenticated', 'public.profiles', 'share_read_status', 'UPDATE'),
          'members may update share_read_status');
select ok(not has_column_privilege('anon', 'public.profiles', 'share_read_status', 'UPDATE'),
          'anon may not update share_read_status');
select ok(has_function_privilege('authenticated', 'public.read_marks(uuid)', 'EXECUTE'),
          'members may execute read_marks');
select ok(not has_function_privilege('anon', 'public.read_marks(uuid)', 'EXECUTE'),
          'anon may not execute read_marks');
select ok(not has_function_privilege('anon', 'public.mark_read(uuid)', 'EXECUTE'),
          'anon may not execute mark_read');
select ok(not has_function_privilege('anon', 'app_private.shares_read_status()', 'EXECUTE'),
          'anon may not execute shares_read_status');
select ok(not has_function_privilege('anon', 'app_private.reads_conversation(text)', 'EXECUTE'),
          'anon may not execute reads_conversation');
select ok(not has_table_privilege('anon', 'public.conversation_members', 'SELECT'),
          'anon may not select conversation_members at all');
select ok(not has_column_privilege('anon', 'public.profiles', 'share_read_status', 'SELECT'),
          'anon may not read anyone''s share_read_status');
-- last_read_at stays unreadable: read_marks() is the only way to it.
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'last_read_at', 'select'),
          'last_read_at is still not directly selectable');
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select throws_ok($$select last_read_at from public.conversation_members$$,
                 '42501', null, 'a member cannot read last_read_at directly');
reset role;

-- 2 nothing else was opened on realtime.messages -----------------------------
select policies_are('realtime', 'messages', array['realtime_receive', 'realtime_send'],
                    'realtime.messages still has exactly the receive and send policies');
select policy_cmd_is('realtime', 'messages', 'realtime_receive', 'select', 'receive is select');
select policy_cmd_is('realtime', 'messages', 'realtime_send', 'insert', 'send is insert');
select policy_roles_are('realtime', 'messages', 'realtime_receive', array['authenticated'],
                        'receive is for authenticated only');
select policy_roles_are('realtime', 'messages', 'realtime_send', array['authenticated'],
                        'send is for authenticated only');

-- 3 reads_conversation(): the topic->uuid mapping -----------------------------
select is(app_private.reads_conversation('reads:' || (select id from _g)::text),
          (select id from _g), 'reads:<uuid> maps to that conversation');
select is(app_private.reads_conversation('reads:not-a-uuid'), null, 'a junk suffix maps to null');
select is(app_private.reads_conversation('typing:' || (select id from _g)::text), null,
          'the wrong prefix maps to null');
select is(app_private.reads_conversation(null), null, 'no topic at all maps to null');
select is(app_private.reads_conversation('reads:'), null, 'nothing after the prefix maps to null');
select is(app_private.reads_conversation('reads:' || (select id from _g)::text || 'x'), null,
          'a uuid with a trailing tail maps to null');
select lives_ok($$select app_private.reads_conversation('reads:not-a-uuid')$$,
                'a junk topic never raises');

-- 4 ada: the positive control, everything on ---------------------------------
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select is(shares_with((select id from _g), '00000000-0000-0000-0000-00000000dd02'),
          true, 'ada sees ben sharing (control)');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-00000000dd02'), now(),
          'ben''s read time is now (a new membership starts caught up)');
-- app_private is not reachable to clients; ask as the owner, ada's claims still set.
reset role;
select is(app_private.shares_read_status(), true, 'shares_read_status(): ada shares');
select test_as('00000000-0000-0000-0000-00000000dd02', 'ed000000-0000-0000-0000-00000000dd02');
select is(shares_with((select id from _g), '00000000-0000-0000-0000-00000000dd01'),
          true, 'and ben sees ada sharing: the other direction (control)');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
-- ada never appears in her own answer.
select is((select count(*) from public.read_marks((select id from _g))
            where user_id = '00000000-0000-0000-0000-00000000dd01'),
          0::bigint, 'read_marks never lists the caller herself');
-- exactly the other five members of G, nobody extra.
select is((select count(*) from public.read_marks((select id from _g))), 5::bigint,
          'ada sees exactly the other five members of G');
reset role;

-- 5 xan: active, allowlisted, NOT a member of G -- the membership gate only --
select test_as('00000000-0000-0000-0000-00000000dd08', 'ed000000-0000-0000-0000-00000000dd08');
select is((select count(*) from public.read_marks((select id from _g))), 0::bigint,
          'xan, not a member of G, gets nothing for it');
select is((select count(*) from public.read_marks((select id from _x))), 1::bigint,
          'xan: positive control, her own conversation X still answers');
reset role;

-- 6 cal: her own sharing off -- only the caller-share gate ----------------------
select test_as('00000000-0000-0000-0000-00000000dd03', 'ed000000-0000-0000-0000-00000000dd03');
select is(shares_with((select id from _g), '00000000-0000-0000-0000-00000000dd02'),
          false, 'cal, not sharing, sees ben as not-shared');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-00000000dd02'), null,
          'cal, not sharing, gets a null read time for ben');
select is((select count(*) from public.read_marks((select id from _g))), 5::bigint,
          'cal still gets a row per other member -- not sharing hides times, not rows');
select is((select count(*) from public.read_marks((select id from _g)) where shares or read_at is not null),
          0::bigint, 'cal, not sharing, sees nobody''s read status at all');
reset role;
select is(app_private.shares_read_status(), false, 'shares_read_status(): cal does not');
reset role;

-- 7 dan: his own sharing off, queried by a sharer -- the person-share gate only -
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select is(shares_with((select id from _g), '00000000-0000-0000-0000-00000000dd04'),
          false, 'ada, sharing, sees dan (not sharing) as not-shared');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-00000000dd04'), null,
          'ada sees a null read time for dan');
reset role;
-- the same pair, the other way: dan (not sharing) asking about ada (sharing).
select test_as('00000000-0000-0000-0000-00000000dd04', 'ed000000-0000-0000-0000-00000000dd04');
select is(shares_with((select id from _g), '00000000-0000-0000-0000-00000000dd01'),
          false, 'dan, not sharing, sees ada as not-shared: mutual both ways');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-00000000dd01'), null,
          'and gets no read time for her');
reset role;

-- 8 eve: delisted after joining, still sharing -- the person-allowlist gate ----
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select is(shares_with((select id from _g), '00000000-0000-0000-0000-00000000dd05'),
          true, 'ada sees eve sharing, still allowlisted (control)');
reset role;
delete from app_private.allowlist where email = 'eve@reads.test';
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select is(shares_with((select id from _g), '00000000-0000-0000-0000-00000000dd05'), false,
          'once eve is delisted, ada sees her as not-shared, although eve never turned sharing off');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-00000000dd05'), null,
          'and her read time is withheld too');
reset role;

-- 9 fay: an old, replaced session -- only the caller's own app-access gate -----
select test_as('00000000-0000-0000-0000-00000000dd06', 'ed000000-0000-0000-0000-00000000d006');
select is((select count(*) from public.read_marks((select id from _g))), 5::bigint,
          'fay''s new phone gets the full answer (control)');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd06', 'ed000000-0000-0000-0000-00000000dd06');
select lives_ok($$select count(*) from public.read_marks(
                    (select id from _g))$$, 'fay''s old phone: asking never raises');
select is((select count(*) from public.read_marks((select id from _g))), 0::bigint,
          'fay''s old phone gets nothing');
select is(try_mark_read((select id from _g)), '42501', 'fay''s old phone cannot mark_read');
reset role;

-- 10 gus: never activated -- the caller app-access gate again -------------------
select test_as('00000000-0000-0000-0000-00000000dd07', 'ed000000-0000-0000-0000-00000000dd07');
select is((select count(*) from public.read_marks((select id from _g))), 0::bigint,
          'gus, never activated, gets nothing, although he was never added to G either');
select is(try_mark_read((select id from _g)), '42501', 'gus, never activated, cannot mark_read');
select is(public.activate_session(), true, 'gus activates');
reset role;

-- 11 hal: never allowlisted at all -----------------------------------------------
select test_as('00000000-0000-0000-0000-00000000dd09', 'ed000000-0000-0000-0000-00000000dd09');
select is(public.activate_session(), false, 'hal cannot activate: never allowlisted');
select is((select count(*) from public.read_marks((select id from _g))), 0::bigint,
          'hal gets nothing from any conversation');
select is(try_mark_read((select id from _g)), '42501', 'hal, never allowlisted, cannot mark_read');
reset role;

-- 12 anon -------------------------------------------------------------------
select test_anon();
select throws_ok($$select * from public.read_marks('00000000-0000-0000-0000-000000000000')$$,
                 '42501', null, 'anon cannot execute read_marks');
select throws_ok($$update public.profiles set share_read_status = false$$,
                 '42501', null, 'anon cannot turn anyone''s read-status sharing off');
reset role;

-- 13 the realtime channel: receive/send on reads:<conversation> -----------------
-- Probe rows for the receive checks.
insert into realtime.messages (topic, extension, payload, event, private) values
  ('fixture', 'broadcast', '{}'::jsonb, 'fixture', true),
  ('fixture', 'presence',  '{}'::jsonb, 'fixture', true);

select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select ok(can_receive('reads:' || (select id from _g)::text, 'broadcast'),
          'ada, sharing, member of G, receives on its reads: topic');
select ok(not can_send('reads:' || (select id from _g)::text, 'broadcast'),
          'no client -- sharing or not -- may ever SEND on a reads: topic');
select ok(not can_receive('reads:' || (select id from _g)::text, 'presence'),
          'no presence extension on a reads: topic');
select ok(not can_receive((select id from _g)::text, 'broadcast'), 'a bare conversation id is closed');
select ok(not can_receive('chat:' || (select id from _g)::text, 'broadcast'), 'another prefix is closed');
select lives_ok($$select can_receive('reads:not-a-uuid', 'broadcast')$$, 'a junk reads: topic never raises');
select ok(not can_receive('reads:not-a-uuid', 'broadcast'), 'reads:<junk> is closed');
select ok(not can_receive('reads:', 'broadcast'), 'reads: with nothing after it is closed');
select ok(not can_receive('reads:' || (select id from _g)::text || 'x', 'broadcast'),
          'a uuid with a trailing tail is closed');
-- her own sharing off closes her OWN receive too.
update public.profiles set share_read_status = false
 where user_id = '00000000-0000-0000-0000-00000000dd01';
select ok(not can_receive('reads:' || (select id from _g)::text, 'broadcast'),
          'ada, sharing OFF, no longer receives on reads: -- even in her own conversation');
update public.profiles set share_read_status = true
 where user_id = '00000000-0000-0000-0000-00000000dd01';
reset role;

select test_as('00000000-0000-0000-0000-00000000dd06', 'ed000000-0000-0000-0000-00000000d006');
select ok(can_receive('reads:' || (select id from _g)::text, 'broadcast'),
          'fay''s new phone receives on G''s reads: topic (control)');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd06', 'ed000000-0000-0000-0000-00000000dd06');
select ok(not can_receive('reads:' || (select id from _g)::text, 'broadcast'),
          'fay''s replaced phone does not');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd03', 'ed000000-0000-0000-0000-00000000dd03');
select ok(not can_receive('reads:' || (select id from _g)::text, 'broadcast'),
          'cal, a member who does not share, does not receive reads');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd08', 'ed000000-0000-0000-0000-00000000dd08');
select ok(can_receive('reads:' || (select id from _x)::text, 'broadcast'),
          'xan receives on her own conversation''s reads: topic (control)');
select ok(not can_receive('reads:' || (select id from _g)::text, 'broadcast'),
          'xan, sharing, but not a member of G, cannot receive on its reads: topic');
reset role;

-- regression: the typing/presence topics this migration did not touch are
-- still open, unaffected by the reads: clause being added to the same OR.
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select ok(can_receive('presence:members', 'presence'), 'presence:members is still open (regression)');
select ok(can_receive('typing:' || (select id from _g)::text, 'broadcast'),
          'typing:<conversation> is still open (regression)');
reset role;

-- 14 mark_read's broadcast: only while the reader shares -------------------------
-- Nothing has been broadcast on G's reads: topic yet: only 'fixture'-topic
-- probe rows exist above.
select is(reads_sent(), 0::bigint,
          'nothing broadcast on G''s reads: topic yet -- the refused mark_reads sent nothing');

select test_as('00000000-0000-0000-0000-00000000dd02', 'ed000000-0000-0000-0000-00000000dd02');
select lives_ok($$select public.mark_read((select id from _g))$$, 'ben (sharing) marks G read');
reset role;
select is(reads_sent(), 1::bigint,
          'a sharing member''s mark_read broadcasts exactly one message');
select is((select bool_and(private) from realtime.messages
            where topic = 'reads:' || (select id from _g)::text), true,
          'the read broadcast is private: only the receive policy opens it');
select ok((select bool_and(payload::text like '%00000000-0000-0000-0000-00000000dd02%')
             from realtime.messages
            where topic = 'reads:' || (select id from _g)::text),
          'the broadcast says who read');
create temp table _ben_read as
  select last_read_at from public.conversation_members
   where conversation_id = (select id from _g)
     and user_id = '00000000-0000-0000-0000-00000000dd02';
grant select on _ben_read to authenticated;
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-00000000dd02'),
          (select last_read_at from _ben_read),
          'read_marks gives ada ben''s stored read time');
reset role;

select test_as('00000000-0000-0000-0000-00000000dd03', 'ed000000-0000-0000-0000-00000000dd03');
select lives_ok($$select public.mark_read((select id from _g))$$,
                'cal (not sharing) marks G read -- still moves her own place');
reset role;
select is(reads_sent(), 1::bigint,
          'a non-sharing member''s mark_read broadcasts nothing more');

-- xan, not a member of G, marking it read: refused or ignored, never a
-- broadcast and never a membership.
select test_as('00000000-0000-0000-0000-00000000dd08', 'ed000000-0000-0000-0000-00000000dd08');
select ok(try_mark_read((select id from _x)) = 'ok', 'xan marks her own conversation read (control)');
select ok(try_mark_read((select id from _g)) is not null, 'xan tries to mark G read');
reset role;
select is(reads_sent(), 1::bigint, 'a non-member''s mark_read broadcasts nothing on G');
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _g)
              and user_id = '00000000-0000-0000-0000-00000000dd08'),
          0::bigint, 'and does not make her a member');

-- one member cannot switch another's sharing.
select test_as('00000000-0000-0000-0000-00000000dd01', 'ed000000-0000-0000-0000-00000000dd01');
update public.profiles set share_read_status = true
 where user_id = '00000000-0000-0000-0000-00000000dd03';
reset role;
select is((select share_read_status from public.profiles
            where user_id = '00000000-0000-0000-0000-00000000dd03'),
          false, 'ada cannot turn cal''s sharing on');

-- cal's own place still moved, proving mark_read itself was not refused --
-- only the broadcast was withheld. Read back with RLS bypassed, the way
-- last_seen_test.sql and unread_test.sql read a private column.
select is((select last_read_at from public.conversation_members
            where conversation_id = (select id from _g)
              and user_id = '00000000-0000-0000-0000-00000000dd03'),
          now(), 'cal''s own last_read_at moved even though she shares nothing');

select * from finish();
rollback;
