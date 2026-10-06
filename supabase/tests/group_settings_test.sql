begin;
select plan(106);

-- Group settings (Update 2): the three switches on conversations,
-- set_group_settings, add_members and set_group_avatar under the switches,
-- the "picture changed" events, delete_group, read_marks inside the history
-- window, and the per-user chats:<uid> nudge.
--
-- Written from the contract, not from the migration:
--  * only a current admin changes a switch or deletes a group;
--  * a non-admin adds only while members_can_add is on, and only people they
--    share a chat with or saved as a contact (a tag find is not enough);
--    an admin keeps the full reach; nobody adds the bot;
--  * an admin's per-add with_history always wins; the switch
--    new_members_see_history decides only when a non-admin adds;
--  * the history limit holds through every read: messages, search, storage,
--    read_marks, picture events; a leave and rejoin gets the rule of the new add;
--  * delete_group returns the photo paths, refuses the bot's Debug group with
--    "not permitted", and nudges every member on chats:<their id>.
--
-- Every negative fixture fails ONE gate:
--   bea  a member of G: refused only by the admin gate or by a switch;
--   fay  found by bea by tag only (allowlisted, active, reachable): only the
--        "shares a chat or is a contact" rule can refuse bea adding her;
--   bot  reachable by ada, a contact of bea: only the bot rule can refuse;
--   hal  allowlisted, active, in no group: only membership can refuse him;
--   rem  a removed member of G, still allowlisted and active;
--   kim  a current member of G whose session is revoked: only app access.

-- fixtures -------------------------------------------------------------------
-- 01 ada  02 bea  03 cai  04 dov  05 eve  06 fay  07 gus  08 hal  09 rem
-- 10 bot  11 kim
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000e40' || n)::uuid, name || '@gs.test', now(),
       json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ada'),('02','bea'),('03','cai'),('04','dov'),('05','eve'),('06','fay'),
               ('07','gus'),('08','hal'),('09','rem'),('10','bot'),('11','kim')) v(n, name);
insert into app_private.allowlist(email)
select name || '@gs.test'
  from unnest(array['ada','bea','cai','dov','eve','fay','gus','hal','rem','bot','kim']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('e4000000-0000-0000-0000-0000000000' || n)::uuid, ('00000000-0000-0000-0000-0000000e40' || n)::uuid, now(), now()
  from unnest(array['01','02','03','04','05','06','07','08','09','10','11']) n;

create function gs_as(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-0000000e40' || n, 'role', 'authenticated',
      'email', (select email from auth.users where id = ('00000000-0000-0000-0000-0000000e40' || n)::uuid),
      'session_id', 'e4000000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000e40' || n)::uuid
$$;
-- The deferred admin guard fires at COMMIT; end each call the way a request does.
create function commit_check() returns void language plpgsql as $$
begin
  set constraints all immediate;
  set constraints all deferred;
end $$;
create function add_c(c uuid, ms uuid[], h boolean) returns void language plpgsql as $$
begin perform public.add_members(c, ms, h); perform commit_check(); end $$;
create function leave_c(c uuid) returns void language plpgsql as $$
begin perform public.leave_group(c); perform commit_check(); end $$;
create function remove_c(c uuid, m uuid) returns void language plpgsql as $$
begin perform public.remove_member(c, m); perform commit_check(); end $$;
create function settings_c(c uuid, a boolean, d boolean, h boolean) returns void language plpgsql as $$
begin perform public.set_group_settings(c, a, d, h); perform commit_check(); end $$;
-- The newest window of a member, RLS bypassed (call as postgres).
create function hist(conv uuid, n text) returns timestamptz language sql as $$
  select history_from from public.conversation_members
   where conversation_id = conv and user_id = u(n) order by joined_at desc, left_at nulls first limit 1
$$;
create function settings_of(conv uuid) returns text language sql as $$
  select members_can_set_avatar || '|' || members_can_add || '|' || new_members_see_history
    from public.conversations where id = conv
$$;
-- realtime.messages as the Realtime server asks it, with realtime.topic() set.
create function can_receive(topic text) returns boolean language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', topic, true);
  return exists (select 1 from realtime.messages m where m.extension = 'broadcast' and m.event = 'gs-fixture');
end $$;
create function can_send(topic text) returns boolean language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', topic, true);
  insert into realtime.messages (topic, extension, payload, event, private)
  values (topic, 'broadcast', '{}'::jsonb, 'probe', true);
  return true;
exception when insufficient_privilege then
  return false;
end $$;
-- The members nudged on chats:<id> with group_changed since the last clear.
create function nudged() returns text language sql as $$
  select coalesce(string_agg(distinct right(topic, 2), ',' order by right(topic, 2)), '')
    from realtime.messages
   where topic like 'chats:00000000-0000-0000-0000-0000000e40%' and event = 'group_changed'
$$;
-- How many picture events the caller gets; -1 when refused.
create function picture_events(conv uuid) returns int language plpgsql security invoker as $$
begin
  return (select count(*) from public.group_picture_events(conv));
exception when others then
  return -1;
end $$;
create function avatar_c(conv uuid, path text) returns text language plpgsql security invoker as $$
begin return public.set_group_avatar(conv, path); end $$;
grant execute on function gs_as(text), u(text), commit_check(), add_c(uuid, uuid[], boolean),
  leave_c(uuid), remove_c(uuid, uuid), settings_c(uuid, boolean, boolean, boolean),
  can_receive(text), can_send(text), picture_events(uuid), avatar_c(uuid, text) to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07','08','09','10','11'] loop
    perform gs_as(n);
    perform public.activate_session();
    execute 'reset role';
  end loop;
end $$;

-- Reach: ada (the admin) finds everyone by tag. bea finds dov (then shares a
-- 1:1 with him) and fay by tag only; eve and the bot are bea's contacts.
insert into app_private.tag_finds(finder, found_id)
select u('01'), u(n) from unnest(array['02','03','04','05','06','07','09','10','11']) n;
insert into app_private.tag_finds(finder, found_id) values (u('02'), u('04')), (u('02'), u('06')), (u('11'), u('02'));
insert into public.contacts(owner_id, contact_id) values (u('02'), u('05')), (u('02'), u('10'));
update public.profiles set share_read_status = true where user_id in (select u(n) from unnest(array['01','02','04','06']) n);

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

select gs_as('01');
insert into ids values
  ('G', public.start_group_conversation('gs-group', array[u('02'), u('03'), u('09'), u('11')])),
  ('DEBUG', public.start_group_conversation('Debug', array[u('02')]));
reset role;
select gs_as('02');
insert into ids values ('D', public.start_direct_conversation(u('04')));
reset role;
select gs_as('11');
insert into ids values ('K', public.start_group_conversation('gs-kim', array[u('02')]));
reset role;
select gs_as('01'); do $$ begin perform public.deliver_release_notes(179); end $$; reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('10'), g('DEBUG'), true);
select gs_as('01'); select remove_c(g('G'), u('09')); reset role;
-- rem's window is moved back: he was removed 90 minutes ago.
update public.conversation_members set left_at = now() - interval '90 minutes', joined_at = now() - interval '3 hours'
 where conversation_id = g('G') and user_id = u('09');
delete from auth.sessions where user_id = u('11');

-- An hour-old message with a photo, an hour-old read mark by bea, and an
-- hour-old picture event: all before anyone added "from now" may read.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', g('G') || '/gs-old.jpg', u('01')::text, '{"size":3,"mimetype":"image/jpeg"}'::jsonb),
  ('avatars', 'group/' || g('G') || '/1.jpg', u('01')::text, '{"size":3,"mimetype":"image/jpeg"}'::jsonb),
  ('avatars', 'group/' || g('G') || '/2.jpg', u('02')::text, '{"size":3,"mimetype":"image/jpeg"}'::jsonb);
insert into public.messages(id, conversation_id, sender_id, body, attachment_path, created_at) values
  ('e4e40000-0000-0000-0000-000000000001', g('G'), u('01'), 'gsold secret', g('G') || '/gs-old.jpg', now() - interval '1 hour'),
  ('e4e40000-0000-0000-0000-000000000002', g('G'), u('01'), 'gsnew hello', null, now());
insert into public.group_events(id, conversation_id, kind, actor_id, subject_id, created_at)
values ('e4e40000-0000-0000-0000-0000000000e1', g('G'), 'picture', u('01'), u('01'), now() - interval '2 hours');
insert into realtime.messages (topic, extension, payload, event, private)
values ('fixture', 'broadcast', '{}'::jsonb, 'gs-fixture', true);

select ok(app_private.is_bot(u('10')), 'fixture: the bot is a bot');

-- 1 the switches and their defaults ------------------------------------------
select col_not_null('public', 'conversations', 'members_can_set_avatar', 'members_can_set_avatar is not null');
select col_not_null('public', 'conversations', 'members_can_add', 'members_can_add is not null');
select col_not_null('public', 'conversations', 'new_members_see_history', 'new_members_see_history is not null');
select is(settings_of(g('G')), 'false|true|true',
          'a new group: picture admins-only, members add, new members see history');

-- 2 who may call the new RPCs ---------------------------------------------------
do $$ begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); end $$;
select ok(not has_function_privilege('anon', 'public.set_group_settings(uuid, boolean, boolean, boolean)', 'execute'),
          'anon may not execute set_group_settings');
select ok(not has_function_privilege('anon', 'public.delete_group(uuid)', 'execute'),
          'anon may not execute delete_group');
select ok(not has_function_privilege('anon', 'public.group_picture_events(uuid)', 'execute'),
          'anon may not execute group_picture_events');
set local role anon;
select throws_ok(format('select public.set_group_settings(%L, true, true, true)', g('G')), '42501', null,
                 'anon cannot set_group_settings');
select throws_ok(format('select public.delete_group(%L)', g('G')), '42501', null, 'anon cannot delete_group');
select throws_ok(format('select count(*) from public.group_picture_events(%L)', g('G')), '42501', null,
                 'anon cannot read group_picture_events');
select throws_ok(format('select public.add_members(%L, array[%L]::uuid[], true)', g('G'), u('04')), '42501', null,
                 'anon cannot add_members');
select throws_ok(format('select public.set_group_avatar(%L, %L)', g('G'), 'group/' || g('G') || '/1.jpg'), '42501', null,
                 'anon cannot set_group_avatar');
select ok(not can_receive('chats:' || u('01')), 'anon does not receive anyone''s chats: nudge');
reset role;

-- 3 set_group_settings: current admins only ------------------------------------
select gs_as('02');
select throws_ok(format('select settings_c(%L, true, false, false)', g('G')), '42501', null,
                 'bea, an ordinary member, cannot change a switch');
reset role;
select gs_as('08');
select throws_ok(format('select settings_c(%L, true, false, false)', g('G')), '42501', null,
                 'hal, not in the group, cannot change a switch');
reset role;
select gs_as('09');
select throws_ok(format('select settings_c(%L, true, false, false)', g('G')), '42501', null,
                 'rem, removed from the group, cannot change a switch');
reset role;
select gs_as('11');
select throws_ok(format('select settings_c(%L, true, false, false)', g('G')), '42501', null,
                 'kim, a member whose session is revoked, cannot change a switch');
reset role;
select gs_as('11');
select throws_ok(format('select settings_c(%L, true, false, false)', g('K')), '42501', null,
                 'kim, admin of K but with her session revoked, cannot change K''s switches');
reset role;
select is(settings_of(g('G')), 'false|true|true', 'every refused call left the switches as they were');

delete from realtime.messages where topic like 'chats:%';
select gs_as('01');
select lives_ok(format('select settings_c(%L, null, false, null)', g('G')), 'ada, the admin, turns members adding off');
reset role;
select is(settings_of(g('G')), 'false|false|true', 'one switch changed; null left the other two');
select is(nudged(), '01,02,03,11',
          'each current member got group_changed on chats:<own id>; not rem (removed) nor hal');
select gs_as('01');
select lives_ok(format('select settings_c(%L, null, null, false)', g('G')), 'ada turns new members seeing history off');
select lives_ok(format('select settings_c(%L, null, null, null)', g('G')), 'all null changes nothing and is not refused');
reset role;
select is(settings_of(g('G')), 'false|false|false', 'the switches are as ada left them');

-- 4 the chats:<uid> topic ------------------------------------------------------
select gs_as('02');
select ok(can_receive('chats:' || u('02')), 'bea receives on chats:<her own id>');
select ok(not can_receive('chats:' || u('01')), 'bea does not receive on ada''s chats: topic');
select ok(not can_send('chats:' || u('01')), 'bea cannot send a nudge on ada''s chats: topic');
reset role;
select gs_as('08');
select ok(not can_receive('chats:' || u('02')), 'hal, a signed-in non-member, does not receive bea''s nudges');
reset role;
select gs_as('11');
select ok(not can_receive('chats:' || u('11')), 'kim, session revoked, receives nothing even on her own topic');
reset role;
select gs_as('10');
select ok(not can_receive('chats:' || u('10')), 'the bot receives nothing on a chats: topic');
reset role;

-- 5 add_members under the switches --------------------------------------------
-- members_can_add is off.
select gs_as('02');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G'), u('04')), '42501', null,
                 'with members adding off, bea cannot add dov even though they share a chat');
reset role;
select gs_as('01');
select lives_ok(format('select settings_c(%L, null, true, null)', g('G')), 'ada turns members adding back on');
reset role;
select gs_as('02');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G'), u('06')), '42501', null,
                 'bea cannot add fay, whom she only found by tag');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G'), u('10')), '42501', null,
                 'bea cannot add the bot, though it is her contact');
select throws_ok(format('select add_c(%L, array[%L, %L]::uuid[], false)', g('G'), u('04'), u('06')), '42501', null,
                 'one refused invitee fails bea''s whole call');
reset role;
select is((select count(*)::int from public.conversation_members
            where conversation_id = g('G') and user_id in (u('04'), u('06'), u('10'))), 0,
          'after the refused calls nobody was added');

-- history switch is off: bea's own with_history=true does not count.
select gs_as('02');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('G'), u('04')),
                'bea adds dov, with whom she shares a 1:1');
reset role;
select is(hist(g('G'), '04'), now(), 'switch off, a member adds: dov reads from now, whatever bea asked');

-- an admin chooses per add, against the switch.
select gs_as('01');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('G'), u('06')),
                'ada, the admin, adds fay (tag find only: an admin keeps the full reach)');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('G'), u('10')), '42501', null,
                 'ada cannot add the bot either');
reset role;
select is(hist(g('G'), '06'), '-infinity'::timestamptz, 'an admin''s with_history wins over the switch being off');

select gs_as('01');
select lives_ok(format('select settings_c(%L, null, null, true)', g('G')), 'ada turns new members seeing history on');
reset role;
select gs_as('02');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G'), u('05')),
                'bea adds eve, her contact');
reset role;
select is(hist(g('G'), '05'), '-infinity'::timestamptz, 'switch on, a member adds: eve reads everything, whatever bea asked');
select gs_as('01');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G'), u('07')),
                'ada adds gus without the old messages');
reset role;
select is(hist(g('G'), '07'), now(), 'an admin''s with_history=false wins over the switch being on');

select is((select string_agg(actor_id::text || '>' || subject_id::text, ',' order by subject_id)
             from public.group_events where conversation_id = g('G') and kind = 'added'),
          u('02') || '>' || u('04') || ',' || u('02') || '>' || u('05') || ',' ||
          u('01') || '>' || u('06') || ',' || u('01') || '>' || u('07'),
          'every add wrote one "X added Y" event with the right actor; refused calls wrote none');

-- the bot as the caller: a member of its own Debug group (members may add
-- there), adding cai, its contact; only the bot rule can refuse it.
insert into public.conversation_members(conversation_id, user_id) values (g('DEBUG'), u('10'));
insert into public.contacts(owner_id, contact_id) values (u('10'), u('03'));
select gs_as('10');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('DEBUG'), u('03')), '42501', null,
                 'the bot, a member of Debug where members add, cannot add its contact');
reset role;
select gs_as('08');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G'), u('04')), '42501', null,
                 'hal, not in the group, cannot add');
reset role;
select gs_as('09');
select throws_ok(format('select add_c(%L, array[%L]::uuid[], false)', g('G'), u('04')), '42501', null,
                 'rem, removed, cannot add');
reset role;

-- 6 the history window holds through every read -------------------------------
-- bea's read and delivered marks, an hour old: before dov's window.
update public.conversation_members set last_read_at = now() - interval '1 hour', shared_read_at = now() - interval '1 hour', delivered_at = now() - interval '1 hour'
 where conversation_id = g('G') and user_id = u('02');
select gs_as('04');
select is((select string_agg(body, ',' order by created_at) from public.messages where conversation_id = g('G')),
          'gsnew hello', 'dov reads only from his joining on');
select is((select count(*)::int from public.search_messages('gsold', g('G'))), 0,
          'dov''s search does not find the older message');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments' and name = g('G') || '/gs-old.jpg'), 0,
          'dov cannot read the older message''s photo in storage');
select is((select count(*)::int from public.read_marks(g('G')) where read_at < now() or delivered_at < now()), 0,
          'read_marks gives dov no position from before his window');
select is(picture_events(g('G')), 0, 'dov does not get the picture event from before his window');
reset role;
select gs_as('06');
select is((select string_agg(body, ',' order by created_at) from public.messages where conversation_id = g('G')),
          'gsold secret,gsnew hello', 'control: fay (with history) reads the older message');
select is((select count(*)::int from public.search_messages('gsold', g('G'))), 1, 'control: fay''s search finds it');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments' and name = g('G') || '/gs-old.jpg'), 1,
          'control: fay reads its photo');
select is((select read_at from public.read_marks(g('G')) where user_id = u('02')), now() - interval '1 hour',
          'control: fay gets bea''s hour-old read position');
select is(picture_events(g('G')), 1, 'control: fay gets the older picture event');
reset role;

-- leaving and rejoining: the new add's rule, never the old window's.
select gs_as('01');
select lives_ok(format('select settings_c(%L, null, null, false)', g('G')), 'ada turns history off again');
reset role;
select gs_as('04'); select leave_c(g('G')); reset role;
select gs_as('02');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('G'), u('04')), 'bea adds dov back');
reset role;
select is(hist(g('G'), '04'), now(), 'dov''s new window starts now: rejoining gave him no history');
select gs_as('04');
select is((select count(*)::int from public.messages where id = 'e4e40000-0000-0000-0000-000000000001'), 0,
          'after rejoining dov still cannot read the older message');
reset role;
select is((select count(*)::int from public.group_events
            where conversation_id = g('G') and kind = 'added' and subject_id = u('04')), 2,
          'the rejoin wrote its own "added" event');

-- 7 set_group_avatar under members_can_set_avatar ------------------------------
delete from realtime.messages where topic like 'chats:%';
select gs_as('02');
select throws_ok(format('select avatar_c(%L, %L)', g('G'), 'group/' || g('G') || '/2.jpg'), '42501', null,
                 'with the picture switch off, bea cannot change the picture');
reset role;
select is((select avatar_path from public.conversations where id = g('G')), null, 'the refused call set nothing');
select gs_as('01');
select is(avatar_c(g('G'), 'group/' || g('G') || '/1.jpg'), null, 'ada, the admin, sets the picture with the switch off');
select lives_ok(format('select settings_c(%L, true, null, null)', g('G')), 'ada lets members change the picture');
reset role;
select gs_as('02');
select is(avatar_c(g('G'), 'group/' || g('G') || '/2.jpg'), 'group/' || g('G') || '/1.jpg',
          'with the switch on, bea changes it and gets the previous path back');
reset role;
select gs_as('08');
select throws_ok(format('select avatar_c(%L, %L)', g('G'), 'group/' || g('G') || '/1.jpg'), '42501', null,
                 'hal, not in the group, cannot change the picture');
reset role;
select gs_as('09');
select throws_ok(format('select avatar_c(%L, %L)', g('G'), 'group/' || g('G') || '/1.jpg'), '42501', null,
                 'rem, removed, cannot change the picture');
reset role;
select is((select string_agg(actor_id::text, ',' order by actor_id) from public.group_events
            where conversation_id = g('G') and kind = 'picture' and created_at = now()),
          u('01') || ',' || u('02'), 'each change wrote one "X changed the group picture" event');
select ok(nudged() like '%02%', 'a picture change nudges the members');

-- 8 group_picture_events --------------------------------------------------------
select gs_as('03');
select is(picture_events(g('G')), 3, 'cai, an ordinary member, reads all three picture events');
select is((select string_agg(actor_id::text, ',' order by created_at, actor_id) from public.group_picture_events(g('G'))),
          u('01') || ',' || u('01') || ',' || u('02'), 'oldest first, with their actors');
select is((select count(*)::int from public.group_events where conversation_id = g('G') and kind = 'picture'), 0,
          'the picture rows stay out of the group_events table for old builds');
reset role;
select gs_as('08');
select ok(picture_events(g('G')) <= 0, 'hal, not in the group, gets no picture events');
reset role;
select gs_as('09');
select is(picture_events(g('G')), 1, 'rem, removed, gets only the event inside his old window');
reset role;
select gs_as('11');
select ok(picture_events(g('G')) <= 0, 'kim, session revoked, gets no picture events');
reset role;
-- eve (whole history) leaves, her old window is moved back, she is added back
-- with the whole history: both windows cover the two-hour-old event.
select gs_as('05'); select leave_c(g('G')); reset role;
update public.conversation_members set joined_at = now() - interval '3 hours', left_at = now() - interval '1 minute'
 where conversation_id = g('G') and user_id = u('05') and left_at is not null;
select gs_as('01');
select lives_ok(format('select add_c(%L, array[%L]::uuid[], true)', g('G'), u('05')), 'ada adds eve back, with history');
reset role;
select gs_as('05');
select is(picture_events(g('G')), 3, 'eve, rejoined, gets each picture event once');
select is((select count(*) - count(distinct id) from public.group_picture_events(g('G')))::int, 0,
          'no duplicate rows for a rejoined member');
reset role;

-- 9 delete_group ----------------------------------------------------------------
select gs_as('02');
select throws_ok(format('select public.delete_group(%L)', g('G')), '42501', null, 'bea, an ordinary member, cannot delete the group');
reset role;
select gs_as('08');
select throws_ok(format('select public.delete_group(%L)', g('G')), '42501', null, 'hal, not in the group, cannot delete it');
reset role;
select gs_as('09');
select throws_ok(format('select public.delete_group(%L)', g('G')), '42501', null, 'rem, removed, cannot delete it');
reset role;
select gs_as('11');
select throws_ok(format('select public.delete_group(%L)', g('G')), '42501', null, 'kim, session revoked, cannot delete it');
reset role;
select gs_as('11');
select throws_ok(format('select public.delete_group(%L)', g('K')), '42501', null,
                 'kim, admin of K but with her session revoked, cannot delete K');
reset role;
select is((select count(*)::int from public.conversations where id = g('G')), 1, 'the refused calls deleted nothing');
select gs_as('01');
select throws_ok(format('select public.delete_group(%L)', g('D')), '42501', null, 'a 1:1 is not deleted through delete_group');
select ok(g('SYS') is not null, 'fixture: ada has the system chat');
-- ada's side of it marked admin (as no RPC ever would): only the system gate can refuse.
reset role;
update public.conversation_members set role = 'admin' where conversation_id = g('SYS') and user_id = u('01');
select gs_as('01');
select throws_ok(format('select public.delete_group(%L)', g('SYS')), '42501', null, 'the system chat is not deleted through delete_group');
select throws_ok(format('select public.delete_group(%L)', g('DEBUG')), '42501', 'not permitted',
                   'the bot''s Debug group is refused as not permitted, even for its admin');
reset role;
select is((select count(*)::int from public.conversations where id = g('DEBUG')), 1, 'the Debug group is still there');

delete from realtime.messages where topic like 'chats:%';
select gs_as('01');
create temp table deleted_paths as select public.delete_group(g('G')) as paths;
reset role;
select ok((select (g('G') || '/gs-old.jpg') = any(paths) from deleted_paths),
          'delete_group returns the photo paths of the group''s messages');
select ok((select ('group/' || g('G') || '/2.jpg') = any(paths) from deleted_paths),
          'delete_group returns the current group picture path too');
select is((select count(*)::int from app_private.deleted_attachments
            where user_id = u('01') and path in (g('G') || '/gs-old.jpg', 'group/' || g('G') || '/2.jpg')), 2,
          'the deleter is recorded for each returned path');
select is((select count(*)::int from public.conversations where id = g('G')), 0, 'the group is gone');
select is((select count(*)::int from public.messages where conversation_id = g('G')), 0, 'its messages are gone');
select is((select count(*)::int from public.conversation_members where conversation_id = g('G')), 0, 'its members are gone');
select is(nudged(), '01,02,03,04,05,06,07,09,11',
          'everyone who had it in their list (rem, removed, too) got group_changed on chats:<own id>');
select gs_as('02');
select is((select count(*)::int from public.conversations where id = g('G')), 0, 'bea''s list no longer has it');
reset role;

-- a group with photo messages and NO group picture.
select gs_as('01');
insert into ids values ('P', public.start_group_conversation('gs-photos', array[u('02')]));
reset role;
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', g('P') || '/gs-p.jpg', u('01')::text, '{"size":3,"mimetype":"image/jpeg"}'::jsonb);
insert into public.messages(conversation_id, sender_id, body, attachment_path)
values (g('P'), u('01'), 'gs photo', g('P') || '/gs-p.jpg');
select gs_as('01');
create temp table deleted_p as select public.delete_group(g('P')) as paths;
reset role;
select is((select paths from deleted_p), array[g('P') || '/gs-p.jpg'],
          'no group picture: delete_group still returns the photo paths, never null');
select is((select count(*)::int from app_private.deleted_attachments where path = g('P') || '/gs-p.jpg' and user_id = u('01')), 1,
          'and records them for the deleter');

select * from finish();
rollback;
