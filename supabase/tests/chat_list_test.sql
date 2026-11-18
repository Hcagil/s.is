begin;
select plan(34);

-- public.chat_list(): the whole chat list in one call, for the caller only
-- (security invoker, so RLS decides every row).
--
-- Fixtures: uma, vic, wes are friends. xan is allowlisted and active but in
-- no chat (the outsider). ada belongs only to an admin chat and a staff_b
-- chat, which uma is NOT in.
--   D  uma <-> vic     (vic deletes one message)
--   G  uma, vic, wes   (wes leaves)
--   H  uma <-> wes     (uma hides it)
--   W  wes <-> vic     (uma is not in it)
--   A  admin chat, B staff_b chat: ada only

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000cc01', 'uma@chatlist.test', now(), '{"full_name":"Uma"}'),
  ('00000000-0000-0000-0000-00000000cc02', 'vic@chatlist.test', now(), '{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-00000000cc03', 'wes@chatlist.test', now(), '{"full_name":"Wes"}'),
  ('00000000-0000-0000-0000-00000000cc04', 'xan@chatlist.test', now(), '{"full_name":"Xan"}'),
  ('00000000-0000-0000-0000-00000000cc05', 'ada@chatlist.test', now(), '{"full_name":"Ada"}');
insert into app_private.allowlist(email) values
  ('uma@chatlist.test'), ('vic@chatlist.test'), ('wes@chatlist.test'),
  ('xan@chatlist.test'), ('ada@chatlist.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-00000000cc01', '00000000-0000-0000-0000-00000000cc02'),
  ('00000000-0000-0000-0000-00000000cc01', '00000000-0000-0000-0000-00000000cc03'),
  ('00000000-0000-0000-0000-00000000cc03', '00000000-0000-0000-0000-00000000cc02');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('c1000000-0000-0000-0000-00000000cc01', '00000000-0000-0000-0000-00000000cc01', now(), now()),
  ('c1000000-0000-0000-0000-00000000cc02', '00000000-0000-0000-0000-00000000cc02', now(), now()),
  ('c1000000-0000-0000-0000-00000000cc03', '00000000-0000-0000-0000-00000000cc03', now(), now()),
  ('c1000000-0000-0000-0000-00000000cc04', '00000000-0000-0000-0000-00000000cc04', now(), now()),
  ('c1000000-0000-0000-0000-00000000cc05', '00000000-0000-0000-0000-00000000cc05', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-00000000cc01', 'c1000000-0000-0000-0000-00000000cc01');
select is(public.activate_session(), true, 'uma is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000cc02', 'c1000000-0000-0000-0000-00000000cc02');
select is(public.activate_session(), true, 'vic is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000cc03', 'c1000000-0000-0000-0000-00000000cc03');
select is(public.activate_session(), true, 'wes is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000cc04', 'c1000000-0000-0000-0000-00000000cc04');
select is(public.activate_session(), true, 'xan is active');
reset role;

create temp table _c (k text primary key, id uuid);
create temp table _r (who text primary key, j jsonb);
grant select, insert on _c, _r to authenticated;

select test_as('00000000-0000-0000-0000-00000000cc01', 'c1000000-0000-0000-0000-00000000cc01');
insert into _c select 'D', public.start_direct_conversation('00000000-0000-0000-0000-00000000cc02');
insert into _c select 'G', public.start_group_conversation('chat list group', array[
  '00000000-0000-0000-0000-00000000cc02', '00000000-0000-0000-0000-00000000cc03']::uuid[]);
insert into _c select 'H', public.start_direct_conversation('00000000-0000-0000-0000-00000000cc03');
reset role;
select test_as('00000000-0000-0000-0000-00000000cc03', 'c1000000-0000-0000-0000-00000000cc03');
insert into _c select 'W', public.start_direct_conversation('00000000-0000-0000-0000-00000000cc02');
reset role;

-- admin and staff_b chats with ada alone, written as the owner
insert into public.conversations(id) values
  ('c2000000-0000-0000-0000-00000000cc0a'), ('c2000000-0000-0000-0000-00000000cc0b');
insert into public.conversation_members(conversation_id, user_id) values
  ('c2000000-0000-0000-0000-00000000cc0a', '00000000-0000-0000-0000-00000000cc05'),
  ('c2000000-0000-0000-0000-00000000cc0b', '00000000-0000-0000-0000-00000000cc05');
update public.conversations set admin_chat = true where id = 'c2000000-0000-0000-0000-00000000cc0a';
-- B is a staff_b chat as production makes it: admin_chat, staff_key and the old flag column,
-- which keeps a private name on the table, so it is found here, never written.
update public.conversations set admin_chat = true, staff_key = 'staff_b' where id = 'c2000000-0000-0000-0000-00000000cc0b';
do $o$ begin execute format('update public.conversations set %I = true where id = %L',
  (select column_name from information_schema.columns where table_schema = 'public' and table_name = 'conversations'
     and column_name like '%\_chat' and column_name not in ('admin_chat', 'debug_chat')),
  'c2000000-0000-0000-0000-00000000cc0b'); end $o$;

update public.conversation_members set last_read_at = now() - interval '1 hour'
 where conversation_id in (select id from _c);
insert into public.messages(conversation_id, sender_id, body, created_at) values
  ((select id from _c where k='D'), '00000000-0000-0000-0000-00000000cc02', 'd keep', now() - interval '30 minutes'),
  ((select id from _c where k='D'), '00000000-0000-0000-0000-00000000cc02', 'd gone', now() - interval '20 minutes'),
  ((select id from _c where k='D'), '00000000-0000-0000-0000-00000000cc01', 'd uma own', now() - interval '10 minutes'),
  ((select id from _c where k='G'), '00000000-0000-0000-0000-00000000cc03', 'g wes', now() - interval '15 minutes'),
  ((select id from _c where k='H'), '00000000-0000-0000-0000-00000000cc03', 'h wes', now() - interval '12 minutes'),
  ((select id from _c where k='W'), '00000000-0000-0000-0000-00000000cc02', 'w secret', now() - interval '5 minutes'),
  ('c2000000-0000-0000-0000-00000000cc0a', '00000000-0000-0000-0000-00000000cc05', 'admin secret', now()),
  ('c2000000-0000-0000-0000-00000000cc0b', '00000000-0000-0000-0000-00000000cc05', 'staff_b secret', now());

-- vic deletes one message in D; wes leaves G; uma hides H
select test_as('00000000-0000-0000-0000-00000000cc02', 'c1000000-0000-0000-0000-00000000cc02');
select public.delete_message((select id from public.messages where body = 'd gone'));
reset role;
select test_as('00000000-0000-0000-0000-00000000cc03', 'c1000000-0000-0000-0000-00000000cc03');
select public.leave_group((select id from _c where k='G'));
reset role;
select test_as('00000000-0000-0000-0000-00000000cc01', 'c1000000-0000-0000-0000-00000000cc01');
select public.hide_chat((select id from _c where k='H'));
insert into _r select 'uma', public.chat_list();
reset role;
select test_as('00000000-0000-0000-0000-00000000cc04', 'c1000000-0000-0000-0000-00000000cc04');
insert into _r select 'xan', public.chat_list();
reset role;
select test_as('00000000-0000-0000-0000-00000000cc03', 'c1000000-0000-0000-0000-00000000cc03');
insert into _r select 'wes', public.chat_list();
reset role;

-- shape ------------------------------------------------------------------
select is((select array(select jsonb_object_keys(j) order by 1) from _r where who='uma'),
  array['archives','conversations','hides','members','pins','previews','profiles','unread'],
  'eight keys');

-- member sees only own rows ------------------------------------------------
select is((select array(select (e->>'id')::text from _r, jsonb_array_elements(j->'conversations') e
            where who='uma' order by 1)),
  (select array(select id::text from _c where k in ('D','G','H') order by 1)),
  'uma sees her three chats, not W, A or B');
select is((select count(*)::int from _r, jsonb_array_elements(j->'members') e
            where who='uma' and (e->>'conversation_id')::uuid not in (select id from _c where k in ('D','G','H'))),
  0, 'no member rows from chats uma is not in');
select is((select count(*)::int from _r, jsonb_array_elements(j->'previews') e
            where who='uma' and (e->>'conversation_id')::uuid not in (select id from _c where k in ('D','G','H'))),
  0, 'no previews from other chats');
select is((select count(*)::int from _r, jsonb_array_elements(j->'previews') e
            where who='uma' and e->>'body' in ('w secret','admin secret','staff_b secret')), 0,
  'no foreign message text');
select is((select count(*)::int from _r, jsonb_array_elements(j->'members') e
            where who='uma' and (e->>'conversation_id')::uuid = (select id from _c where k='D')), 2,
  'D has both members');

-- admin_chat / staff_b chat invisible to non-members ----------------------
select is((select count(*)::int from _r, jsonb_array_elements(j->'conversations') e
            where who='uma' and (e->>'admin_chat')::boolean), 0, 'admin chat not in uma list');
select is((select count(*)::int from _r, jsonb_array_elements(j->'conversations') e
            where who='uma' and (e->>'id' = 'c2000000-0000-0000-0000-00000000cc0b' or e->>'staff_key' = 'staff_b')), 0,
  'staff_b chat not in uma list');
select is((select count(*)::int from _r, jsonb_array_elements(j->'members') e
            where who='uma' and e->>'user_id' = '00000000-0000-0000-0000-00000000cc05'), 0,
  'ada is not visible as a member');

-- outsider gets [] everywhere ---------------------------------------------
select is((select count(*)::int from _r, jsonb_each(j) kv where who='xan' and kv.value <> '[]'::jsonb), 0,
  'xan: every key is []');
select is((select count(*)::int from _r, jsonb_each(j) kv where who='xan'), 8, 'xan: all eight keys still there');

-- anon cannot execute ------------------------------------------------------
select is(has_function_privilege('anon', 'public.chat_list()', 'execute'), false, 'anon has no execute');
select is(has_function_privilege('authenticated', 'public.chat_list()', 'execute'), true, 'authenticated may execute');
select is((select prosecdef from pg_proc where oid = 'public.chat_list()'::regprocedure), false,
  'security invoker');
set local role anon;
select throws_ok('select public.chat_list()', '42501', null, 'anon call is refused');
reset role;

-- left member data present with left_at -----------------------------------
select isnt((select e->>'left_at' from _r, jsonb_array_elements(j->'members') e
              where who='uma' and (e->>'conversation_id')::uuid = (select id from _c where k='G')
                and e->>'user_id' = '00000000-0000-0000-0000-00000000cc03'), null,
  'wes shows with left_at in G for uma');
select is((select e->>'left_at' from _r, jsonb_array_elements(j->'members') e
              where who='uma' and (e->>'conversation_id')::uuid = (select id from _c where k='G')
                and e->>'user_id' = '00000000-0000-0000-0000-00000000cc01'), null,
  'uma has no left_at');

-- hidden chats in hides ----------------------------------------------------
select is((select array(select e->>'conversation_id' from _r, jsonb_array_elements(j->'hides') e where who='uma')),
  (select array(select id::text from _c where k='H')), 'hides holds exactly H');
select is((select count(*)::int from _r, jsonb_array_elements(j->'hides') e where who='wes'), 0,
  'wes did not hide anything: hides is private');

-- unread skips deleted / hidden / own -------------------------------------
select is((select (e->>'unread')::int from _r, jsonb_array_elements(j->'unread') e
            where who='uma' and (e->>'conversation_id')::uuid = (select id from _c where k='D')), 1,
  'D unread: the deleted and the own message do not count');
select is((select count(*)::int from _r, jsonb_array_elements(j->'unread') e
            where who='uma' and (e->>'conversation_id')::uuid = (select id from _c where k='H')), 0,
  'hidden H has no unread');
select is((select (e->>'unread')::int from _r, jsonb_array_elements(j->'unread') e
            where who='uma' and (e->>'conversation_id')::uuid = (select id from _c where k='G')), 1,
  'G unread counts wes message');

-- profiles only from shared chats -----------------------------------------
select is((select array(select e->>'user_id' from _r, jsonb_array_elements(j->'profiles') e where who='uma' order by 1)),
  array['00000000-0000-0000-0000-00000000cc02','00000000-0000-0000-0000-00000000cc03'],
  'uma gets vic and wes only: not herself, xan or ada');

-- closed_at: null while open, set once the admin closes the group -------------
-- K: uma (admin) with vic and wes; a message so the empty-group cleanup keeps it.
select test_as('00000000-0000-0000-0000-00000000cc01', 'c1000000-0000-0000-0000-00000000cc01');
insert into _c select 'K', public.start_group_conversation('closing group', array[
  '00000000-0000-0000-0000-00000000cc02', '00000000-0000-0000-0000-00000000cc03']::uuid[]);
reset role;
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from _c where k='K'), '00000000-0000-0000-0000-00000000cc02', 'k hello');
select test_as('00000000-0000-0000-0000-00000000cc01', 'c1000000-0000-0000-0000-00000000cc01');
insert into _r select 'uma-open', public.chat_list();
select public.close_group((select id from _c where k='K'));
set constraints all immediate; set constraints all deferred;
insert into _r select 'uma-closed', public.chat_list();
reset role;
select test_as('00000000-0000-0000-0000-00000000cc04', 'c1000000-0000-0000-0000-00000000cc04');
insert into _r select 'xan-closed', public.chat_list();
reset role;

select is((select count(*)::int from _r, jsonb_array_elements(j->'conversations') e
            where who='uma' and not (e ? 'closed_at')), 0,
  'every conversations row carries a closed_at key');
select is((select count(*)::int from _r, jsonb_array_elements(j->'conversations') e
            where who='uma-open' and e->'closed_at' <> 'null'::jsonb), 0,
  'open groups and chats: closed_at is null');
select is((select count(*)::int from _r, jsonb_array_elements(j->'conversations') e
            where who='uma-open' and (e->>'id')::uuid = (select id from _c where k='K')), 1,
  'K is listed before the close');
select is((select jsonb_typeof(e->'closed_at') from _r, jsonb_array_elements(j->'conversations') e
            where who='uma-closed' and (e->>'id')::uuid = (select id from _c where k='K')), 'string',
  'K carries a closed_at timestamp once closed');
select is((select e->>'closed_at' from _r, jsonb_array_elements(j->'conversations') e
            where who='uma-closed' and (e->>'id')::uuid = (select id from _c where k='K'))::timestamptz,
  (select closed_at from public.conversations where id = (select id from _c where k='K')),
  'the value is the conversations.closed_at of K');
select is((select count(*)::int from _r, jsonb_array_elements(j->'conversations') e
            where who='uma-closed' and (e->>'id')::uuid <> (select id from _c where k='K')
              and e->'closed_at' <> 'null'::jsonb), 0,
  'closing K leaves the other chats open in the list');
select is((select count(*)::int from _r, jsonb_array_elements(j->'conversations') e
            where who='xan-closed'), 0, 'a non-member sees no conversations row, closed or not');

select * from finish();
rollback;
