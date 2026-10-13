begin;
select plan(56);

-- Pinned message (Update 2): conversations.pinned_message_id and
-- members_can_pin, set_pinned_message, set_members_can_pin, pin_events, the
-- messages_unpin_deleted trigger and the group_events read policy hiding
-- 'picture' and 'pinned'.
--
-- Written from the contract, not from the migration. Every refused call fails
-- ONE gate:
--   hal  allowlisted, active, in no chat: only membership refuses;
--   rem  removed from G, pins a message inside his old window: only "current";
--   bot  a current member of Debug, message readable: only the bot rule;
--   ada  pins in her system chat: only the system-chat rule;
--   bea  a D message under G / a deleted message / with the switch off;
--   cai  added without history, pins an older message: only readability.

-- fixtures -------------------------------------------------------------------
-- 01 ada  02 bea  03 cai  08 hal  09 rem  10 bot
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000f50' || n)::uuid, name || '@pm.test', now(),
       json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ada'),('02','bea'),('03','cai'),('08','hal'),('09','rem'),('10','bot')) v(n, name);
insert into app_private.allowlist(email)
select name || '@pm.test' from unnest(array['ada','bea','cai','hal','rem','bot']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('f5000000-0000-0000-0000-0000000000' || n)::uuid, ('00000000-0000-0000-0000-0000000f50' || n)::uuid, now(), now()
  from unnest(array['01','02','03','08','09','10']) n;

create function pm_as(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-0000000f50' || n, 'role', 'authenticated',
      'email', (select email from auth.users where id = ('00000000-0000-0000-0000-0000000f50' || n)::uuid),
      'session_id', 'f5000000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000f50' || n)::uuid
$$;
create function m(n text) returns uuid language sql immutable as $$
  select ('f5f50000-0000-0000-0000-0000000000' || n)::uuid
$$;
create function commit_check() returns void language plpgsql as $$
begin
  set constraints all immediate;
  set constraints all deferred;
end $$;
create function add_c(c uuid, ms uuid[], h boolean) returns void language plpgsql as $$
begin perform public.add_members(c, ms, h); perform commit_check(); end $$;
create function remove_c(c uuid, mem uuid) returns void language plpgsql as $$
begin perform public.remove_member(c, mem); perform commit_check(); end $$;
create function pin_sql(c uuid, msg uuid) returns text language sql as $$
  select format('select public.set_pinned_message(%L, %L)', c, msg) $$;
create function who_sql(c uuid, allowed boolean) returns text language sql as $$
  select format('select public.set_members_can_pin(%L, %L)', c, allowed) $$;
-- How many pin events the caller gets; -1 when refused.
create function pe(conv uuid) returns int language plpgsql security invoker as $$
begin
  return (select count(*) from public.pin_events(conv));
exception when others then
  return -1;
end $$;
create function del(msg uuid) returns void language plpgsql security invoker as $$
begin perform public.delete_message(msg); end $$;
grant execute on function pm_as(text), u(text), m(text), commit_check(), add_c(uuid, uuid[], boolean),
  remove_c(uuid, uuid), pin_sql(uuid, uuid), who_sql(uuid, boolean), pe(uuid), del(uuid) to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','08','09','10'] loop
    perform pm_as(n);
    perform public.activate_session();
    execute 'reset role';
  end loop;
end $$;

insert into app_private.tag_finds(finder, found_id)
select u('01'), u(n) from unnest(array['02','03','09','10']) n;
insert into app_private.tag_finds(finder, found_id) values (u('02'), u('01'));

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

select pm_as('01');
insert into ids values
  ('G', public.start_group_conversation('pm-group', array[u('02'), u('09')])),
  ('DEBUG', public.start_group_conversation('Debug', array[u('02'), u('10')]));
reset role;
select pm_as('02');
insert into ids values ('D', public.start_direct_conversation(u('01')));
reset role;
select pm_as('01'); do $$ begin perform public.deliver_release_notes(179); end $$; reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('10'), g('DEBUG'), true);
select pm_as('01'); select remove_c(g('G'), u('09')); reset role;
update public.conversation_members set left_at = now() - interval '90 minutes', joined_at = now() - interval '3 hours'
 where conversation_id = g('G') and user_id = u('09');

insert into public.messages(id, conversation_id, sender_id, body, created_at) values
  (m('01'), g('G'), u('01'), 'pm old', now() - interval '1 hour'),
  (m('02'), g('G'), u('01'), 'pm new', now()),
  (m('03'), g('G'), u('02'), 'pm bea', now()),
  (m('04'), g('G'), u('02'), 'pm del', now()),
  (m('05'), g('D'), u('02'), 'pm d', now()),
  (m('06'), g('DEBUG'), u('01'), 'pm dbg', now()),
  (m('07'), g('G'), u('01'), 'pm early', now() - interval '2 hours');
select pm_as('01'); select add_c(g('G'), array[u('03')], false); reset role;

create function pinned(conv uuid) returns uuid language sql as $$
  select pinned_message_id from public.conversations where id = conv $$;
create function pin_count(conv uuid) returns int language sql as $$
  select count(*)::int from public.group_events where conversation_id = conv and kind = 'pinned' $$;

select ok(app_private.is_bot(u('10')), 'fixture: the bot is a bot');
select ok(g('SYS') is not null and exists(select 1 from public.messages where conversation_id = g('SYS')),
          'fixture: ada has a system chat with a message');

-- 1 columns and RPC shape ---------------------------------------------------
select has_column('public', 'conversations', 'pinned_message_id', 'conversations.pinned_message_id exists');
select col_not_null('public', 'conversations', 'members_can_pin', 'members_can_pin is not null');
select col_default_is('public', 'conversations', 'members_can_pin', 'true', 'members_can_pin defaults to true');
select function_privs_are('public', 'set_pinned_message', array['uuid', 'uuid'], 'anon', '{}'::text[], 'anon cannot set_pinned_message');
select function_privs_are('public', 'set_pinned_message', array['uuid', 'uuid'], 'authenticated', array['EXECUTE'], 'authenticated may set_pinned_message');
select function_privs_are('public', 'set_members_can_pin', array['uuid', 'boolean'], 'anon', '{}'::text[], 'anon cannot set_members_can_pin');
select function_privs_are('public', 'set_members_can_pin', array['uuid', 'boolean'], 'authenticated', array['EXECUTE'], 'authenticated may set_members_can_pin');
select function_privs_are('public', 'pin_events', array['uuid'], 'anon', '{}'::text[], 'anon cannot pin_events');
select function_privs_are('public', 'pin_events', array['uuid'], 'authenticated', array['EXECUTE'], 'authenticated may pin_events');
select is((select array_agg(prosecdef::text || '|' || array_to_string(proconfig, ',') order by oid::regprocedure::text)
             from pg_proc where oid in ('public.set_pinned_message(uuid,uuid)'::regprocedure,
                                        'public.set_members_can_pin(uuid,boolean)'::regprocedure,
                                        'public.pin_events(uuid)'::regprocedure)),
          array['true|search_path=""', 'true|search_path=""', 'true|search_path=""'],
          'all three RPCs: security definer, search_path ''''');

-- 2 pin, replace, unpin ---------------------------------------------------------
select pm_as('02');
select lives_ok(pin_sql(g('G'), m('03')), 'bea, a member, pins her message in G');
reset role;
select is(pinned(g('G')), m('03'), 'G''s pinned message is bea''s');
select is(pin_count(g('G')), 1, 'pinning adds one pinned event');
select is((select actor_id from public.group_events where conversation_id = g('G') and kind = 'pinned'), u('02'),
          'the pinned event names bea as the actor');
select pm_as('01');
select lives_ok(pin_sql(g('G'), m('02')), 'ada pins another message');
reset role;
select is(pinned(g('G')), m('02'), 'a new pin replaces the old one');
select is(pin_count(g('G')), 2, 'a second pinned event');
select pm_as('01');
select lives_ok(pin_sql(g('G'), null), 'ada unpins');
reset role;
select is(pinned(g('G')), null, 'null unpins');
select is(pin_count(g('G')), 2, 'unpinning adds no event');
select pm_as('01'); select lives_ok(pin_sql(g('G'), m('02')), 'ada pins m_new again'); reset role;

-- 3 1:1: both may pin, the switch does not apply -------------------------------
select pm_as('02'); select lives_ok(pin_sql(g('D'), m('05')), 'bea pins in the 1:1'); reset role;
select is(pin_count(g('D')), 1, 'a 1:1 pin adds a pinned event too');
select pm_as('01'); select lives_ok(pin_sql(g('D'), m('05')), 'ada pins in the 1:1'); reset role;
update public.conversations set members_can_pin = false where id = g('D');
select pm_as('02'); select lives_ok(pin_sql(g('D'), m('05')), 'members_can_pin off does not stop a 1:1 pin'); reset role;

-- 4 refusals, one gate each ------------------------------------------------------
select pm_as('08');
select throws_ok(pin_sql(g('G'), m('02')), '42501', null, 'hal, not a member, cannot pin in G');
reset role;
select pm_as('09');
select throws_ok(pin_sql(g('G'), m('07')), '42501', null, 'rem, removed, cannot pin a message from his old window');
reset role;
select pm_as('10');
select throws_ok(pin_sql(g('DEBUG'), m('06')), '42501', null, 'the bot cannot pin in its Debug group');
reset role;
select pm_as('02');
select lives_ok(pin_sql(g('DEBUG'), m('06')), 'control: bea pins the same message in Debug');
reset role;
select pm_as('01');
select throws_ok(pin_sql(g('SYS'), (select id from public.messages where conversation_id = g('SYS') limit 1)),
                 '42501', null, 'nobody pins in the system chat');
reset role;
select pm_as('02');
select throws_ok(pin_sql(g('G'), m('05')), '42501', null, 'a message from another chat cannot be pinned');
select lives_ok(format('select del(%L)', m('04')), 'bea deletes her message for everyone');
select throws_ok(pin_sql(g('G'), m('04')), '42501', null, 'a deleted message cannot be pinned');
reset role;
select pm_as('03');
select throws_ok(pin_sql(g('G'), m('01')), '42501', null, 'cai, added without history, cannot pin an older message');
select lives_ok(pin_sql(g('G'), m('02')), 'control: cai pins a message she can read');
reset role;
select is(pinned(g('G')), m('02'), 'refusals left G''s pin unchanged');

-- 5 who may pin ------------------------------------------------------------------
select pm_as('02');
select throws_ok(who_sql(g('G'), false), '42501', null, 'bea, not an admin, cannot change who may pin');
reset role;
select pm_as('01');
-- ada made an admin of D by hand, so only the "groups only" rule can refuse.
reset role;
update public.conversation_members set role = 'admin' where conversation_id = g('D') and user_id = u('01');
select pm_as('01');
select throws_ok(who_sql(g('D'), false), '42501', null, 'there is no who-may-pin switch in a 1:1, even for an admin');
reset role;
update public.conversation_members set role = 'member' where conversation_id = g('D') and user_id = u('01');
select pm_as('01');
select lives_ok(who_sql(g('G'), false), 'ada, the admin, sets G to admins only');
reset role;
select is((select members_can_pin from public.conversations where id = g('G')), false, 'members_can_pin is off');
select pm_as('02');
select throws_ok(pin_sql(g('G'), m('03')), '42501', null, 'admins only: bea cannot pin');
reset role;
select pm_as('01');
select lives_ok(pin_sql(g('G'), m('03')), 'admins only: ada still pins');
select lives_ok(who_sql(g('G'), true), 'ada lets every member pin again');
reset role;
select pm_as('02');
select lives_ok(pin_sql(g('G'), m('02')), 'bea pins again');
reset role;

-- 6 deleting the pinned message for everyone clears the pin ---------------------
select pm_as('02'); select del(m('03')); reset role;
select is(pinned(g('G')), m('02'), 'deleting another message keeps the pin');
select pm_as('01'); select del(m('02')); reset role;
select is(pinned(g('G')), null, 'deleting the pinned message clears the pin');

-- 7 the group_events read policy hides picture and pinned -----------------------
insert into public.group_events(id, conversation_id, kind, actor_id, subject_id, created_at)
values (gen_random_uuid(), g('G'), 'picture', u('01'), u('01'), now());
select ok((select count(*) from public.group_events where conversation_id = g('G') and kind in ('pinned', 'picture')) > 1,
          'fixture: G has picture and pinned events');
-- ada: direct reads of group_events are for admins, so only the kind filter can hide these.
select pm_as('01');
select is((select count(*)::int from public.group_events where conversation_id = g('G') and kind in ('pinned', 'picture')), 0,
          'a direct read never returns picture or pinned events, even to the admin');
select ok((select count(*) from public.group_events where conversation_id = g('G') and kind in ('added', 'removed')) > 0,
          'control: the admin still reads added and removed events');
reset role;

-- 8 pin_events: members, inside their window -----------------------------------
insert into public.group_events(id, conversation_id, kind, actor_id, subject_id, created_at)
values (gen_random_uuid(), g('G'), 'pinned', u('01'), u('01'), now() - interval '2 hours');
create temp table _n as select pin_count(g('G')) as total;
grant select on _n to authenticated;
select pm_as('02');
select is(pe(g('G')), (select total from _n), 'bea gets every pinned event of G');
select ok(exists(select 1 from public.pin_events(g('G')) e
                  where e.conversation_id = g('G') and e.actor_id = u('02') and e.id is not null and e.created_at is not null),
          'pin_events rows carry id, conversation_id, actor_id and created_at');
reset role;
select pm_as('03');
select is(pe(g('G')), (select total from _n) - 1, 'cai does not get the event from before she joined');
reset role;
select pm_as('09');
select is(pe(g('G')), 1, 'rem gets only the event inside his old window');
reset role;
select pm_as('08');
select ok(pe(g('G')) <= 0, 'hal, never a member, gets nothing');
reset role;

select * from finish();
rollback;
