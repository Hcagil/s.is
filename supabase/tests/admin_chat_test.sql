begin;
select plan(179);

-- Admin chat, slice 1 (step 15): the owner types tester commands into a
-- private chat; the server parses them and answers from a fixed account.
-- Written from the contract, not from the migration:
--
-- 1. shape and grants: is_owner() takes no argument and is not executable by
--    public/anon; the parser trigger is security definer, search_path='',
--    and executable by nobody; admin_answer is for authenticated only;
--    clients cannot write admin_msg, admin_push or admin_chat.
-- 2. only the owner's own message in the admin conversation, without
--    admin_msg, is parsed -- each negative fixture fails exactly one gate.
-- 3. replies: from ...ad41 with an admin_msg; k per command; help:true on
--    every error; list carries FULL emails, every other reply and the
--    command log are masked.
-- 4. admin_answer: owner (with app access) only, one use per card, expired
--    card -> keep; yes removes allowlist + active_sessions and queues an
--    Apple remove unless android; raw email nulled when the card ends.
-- 5. any exception in the parser -> one generic k=err reply, never raised.
-- 6. the admin conversation is refused by every group/membership/send RPC.
-- 7. push: only admin rows flagged admin_push go through notify_new_message.
-- 8. privacy: nobody else sees the admin chat; previews carry admin_msg.
-- 9. rate limit -> k=rate and no action.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function try_exec(stmt text) returns text
language plpgsql security invoker as $$
declare n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  return 'ok:' || n;
exception when others then
  return 'err:' || sqlstate;
end $$;
grant execute on function try_exec(text) to authenticated, anon;

-- fixtures -------------------------------------------------------------------
-- own  the owner (allowlisted, active)
-- mal  allowlisted, active member who is NOT the owner (fails only is_owner)
-- rob  android tester with a live session (removed later)
-- ivy  iPhone tester (removed later: Apple job)
-- zed  older tester with no platform tag (removed later: Apple job)
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ac001', 'own@mail.test', now(), '{"full_name":"Own"}'),
  ('00000000-0000-0000-0000-0000000ac002', 'mal@mail.test', now(), '{"full_name":"Mal"}'),
  ('00000000-0000-0000-0000-0000000ac003', 'rob@mail.test', now(), '{"full_name":"Rob"}'),
  ('00000000-0000-0000-0000-0000000ac004', 'ivy@mail.test', now(), '{"full_name":"Ivy"}'),
  ('00000000-0000-0000-0000-0000000ac005', 'zed@mail.test', now(), '{"full_name":"Zed"}');
insert into app_private.allowlist(email) values
  ('own@mail.test'), ('mal@mail.test'), ('rob@mail.test'), ('zed@mail.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ac000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ac001', now(), now()),
  ('ac000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000ac002', now(), now()),
  ('ac000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000ac003', now(), now());

create function as_own() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000ac001', 'ac000000-0000-0000-0000-000000000001') $$;
create function as_mal() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000ac002', 'ac000000-0000-0000-0000-000000000002') $$;
create function as_rob() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000ac003', 'ac000000-0000-0000-0000-000000000003') $$;
grant execute on function as_own(), as_mal(), as_rob() to authenticated;

select as_own(); select is(public.activate_session(), true, 'own is active'); reset role;
select as_mal(); select is(public.activate_session(), true, 'mal is active'); reset role;
select as_rob(); select is(public.activate_session(), true, 'rob is active'); reset role;

-- An ordinary group own+mal, own admin: the control for every refusal below.
insert into public.conversations(id, title) values ('ac0c0000-0000-0000-0000-000000000001', 'Ordinary');
insert into public.conversation_members(conversation_id, user_id, role) values
  ('ac0c0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ac001', 'admin'),
  ('ac0c0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ac002', 'member');

-- is_owner() as [uid] sees it (authenticated has no usage on app_private, so
-- this reads auth.uid() from the claims while staying superuser).
create function owner_for(uid uuid) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  r := app_private.is_owner();
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

-- 1 shape and grants -----------------------------------------------------------
select is((select pronargs::int from pg_proc where oid = 'app_private.is_owner()'::regprocedure), 0,
          'is_owner takes no argument');
select ok(not has_function_privilege('anon', 'app_private.is_owner()', 'execute'), 'anon cannot execute is_owner');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid = 'app_private.is_owner()'::regprocedure and a.grantee = 0),
          'is_owner is not granted to public');
select ok((select prosecdef from pg_proc where oid = 'app_private.admin_on_message()'::regprocedure),
          'the parser trigger function is security definer');
select ok((select proconfig::text[] && array['search_path=""', 'search_path='] from pg_proc
            where oid = 'app_private.admin_on_message()'::regprocedure),
          'the parser trigger function pins search_path to empty');
select ok(not has_function_privilege('authenticated', 'app_private.admin_on_message()', 'execute'),
          'authenticated cannot execute the parser trigger function');
select ok(not has_function_privilege('anon', 'app_private.admin_on_message()', 'execute'),
          'anon cannot execute the parser trigger function');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid = 'app_private.admin_on_message()'::regprocedure and a.grantee = 0),
          'the parser trigger function is not granted to public');
select ok(has_function_privilege('authenticated', 'public.admin_answer(uuid, boolean)', 'execute'),
          'authenticated may execute admin_answer');
select ok(not has_function_privilege('anon', 'public.admin_answer(uuid, boolean)', 'execute'),
          'anon may not execute admin_answer');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid = 'public.admin_answer(uuid, boolean)'::regprocedure and a.grantee = 0),
          'admin_answer is not granted to public');
select ok(not has_column_privilege('authenticated', 'public.messages', 'admin_msg', 'INSERT'),
          'authenticated cannot insert admin_msg');
select ok(not has_column_privilege('authenticated', 'public.messages', 'admin_msg', 'UPDATE'),
          'authenticated cannot update admin_msg');
select ok(not has_column_privilege('authenticated', 'public.messages', 'admin_push', 'INSERT'),
          'authenticated cannot insert admin_push');
select ok(not has_column_privilege('authenticated', 'public.messages', 'admin_push', 'UPDATE'),
          'authenticated cannot update admin_push');
select has_column('public', 'conversation_previews', 'admin_msg', 'conversation_previews has an admin_msg column');
select ok(not has_table_privilege('authenticated', 'app_private.owners', 'select,insert,update,delete'),
          'authenticated holds nothing on owners');

-- the owner row makes the admin conversation ----------------------------------
select is(owner_for('00000000-0000-0000-0000-0000000ac001'), false, 'before the owner row, own is not the owner');
insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000ac001');
select throws_ok($$insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000ac002')$$,
                 '23505', null, 'a second owner row is refused (single row)');

create temp table adm as select id from public.conversations where admin_chat and not bacanaks_chat;
grant select on adm to authenticated;
select is((select count(*) from adm), 1::bigint, 'exactly one admin conversation exists');
select is((select array_agg(user_id::text) from public.conversation_members where conversation_id = (select id from adm)),
          array['00000000-0000-0000-0000-0000000ac001'], 'the owner is its only member');

select is(owner_for('00000000-0000-0000-0000-0000000ac001'), true, 'own is the owner');
select as_own();
select is((select count(*) from public.conversations where id = (select id from adm)), 1::bigint,
          'own sees the admin chat');
reset role;
select is(owner_for('00000000-0000-0000-0000-0000000ac002'), false, 'mal is not the owner');
select as_mal();
select is((select count(*) from public.conversations where id = (select id from adm)), 0::bigint,
          'mal cannot see the admin chat');
reset role;

-- helpers: what the owner's command produced ---------------------------------
-- seen = every admin-conversation message already looked at.
create temp table seen(id uuid primary key);
grant all on seen to authenticated;

-- New replies (from ...ad41) since the last call, as a jsonb array of admin_msg.
create function fresh() returns jsonb language plpgsql as $$
declare r jsonb;
begin
  select coalesce(jsonb_agg(m.admin_msg order by m.admin_msg->>'k'), '[]') into r
    from public.messages m
   where m.conversation_id = (select id from adm)
     and m.sender_id = '00000000-0000-0000-0000-00000000ad41'
     and m.id not in (select id from seen);
  insert into seen select m.id from public.messages m
   where m.conversation_id = (select id from adm) on conflict do nothing;
  return r;
end $$;

-- The owner types [t] in the admin chat (as the app does); returns the replies.
create function say(t text) returns jsonb language plpgsql as $$
begin
  perform fresh();
  perform as_own();
  insert into public.messages(conversation_id, sender_id, body)
    values ((select id from adm), '00000000-0000-0000-0000-0000000ac001', t);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return fresh();
end $$;

-- Every reply text and every log row, to search for a raw email.
create function leaks(e text) returns bigint language sql as $$
  select (select count(*) from public.messages
           where conversation_id = (select id from adm)
             and sender_id = '00000000-0000-0000-0000-00000000ad41'
             and coalesce(admin_msg->>'k', '') not in ('list', 'fwd')
             and (position(e in lower(coalesce(body, ''))) > 0
                  or position(e in lower(coalesce(admin_msg::text, ''))) > 0))
       + (select count(*) from app_private.admin_commands c
           where position(e in lower(row_to_json(c)::text)) > 0)
$$;

-- 3 replies --------------------------------------------------------------------
create temp table r(name text primary key, v jsonb);

insert into r select 'list0', say('/listtesters');
select is(jsonb_array_length((select v from r where name = 'list0')), 1, '/listtesters gives one reply');
select is((select v->0->>'k' from r where name = 'list0'), 'list', 'its k is list');
select is((select (v->0->>'n')::int from r where name = 'list0'),
          (select count(*)::int from app_private.allowlist), 'n counts the allowlist');
select ok((select v->0->'oth' @> '["zed@mail.test"]' from r where name = 'list0'),
          'an untagged tester is listed under oth with the FULL email');
select is((select sender_id from public.messages where conversation_id = (select id from adm)
            and admin_msg->>'k' = 'list' limit 1), '00000000-0000-0000-0000-00000000ad41'::uuid,
          'replies come from the system account ...ad41');
select is((select count(*) from app_private.admin_commands where outcome is not null), 1::bigint,
          'the command is logged');

insert into r select 'unk', say('/frobnicate');
select is((select v->0->>'k' from r where name = 'unk'), 'unk', 'unknown command -> unk');
select is((select (v->0->>'help')::boolean from r where name = 'unk'), true, 'unk carries help');

insert into r select 'noem', say('/addiostester');
select is((select v->0->>'k' from r where name = 'noem'), 'noem', 'a command without email -> noem');
select is((select (v->0->>'help')::boolean from r where name = 'noem'), true, 'noem carries help');

insert into r select 'bad', say('/addandroidtester not-an-email');
select is((select v->0->>'k' from r where name = 'bad'), 'bad', 'a malformed email -> bad');
select is((select (v->0->>'help')::boolean from r where name = 'bad'), true, 'bad carries help');
select is((select count(*) from app_private.allowlist where email like 'not-an-email%'), 0::bigint,
          'a bad email adds nothing');

-- Count from here: cards other runs left behind are not ours.
create temp table p0 as select count(*) as n from app_private.admin_pending;
insert into r select 'nolist', say('/removetester nobody@mail.test');
select ok((select v @> '[{"k":"nolist","help":true}]' from r where name = 'nolist'),
          'removing an address not on the list -> nolist with help');
select is((select count(*) from app_private.admin_pending) - (select n from p0), 0::bigint, 'and no confirm card is made');
select is(leaks('nobody@mail.test'), 0::bigint, 'nolist masks the email (reply and log)');

-- Android without the Play link: nolink. Then with it: andOk + fwd.
insert into r select 'nolink', say('/addandroidtester pat@mail.test');
select ok((select v @> '[{"k":"nolink"}]' from r where name = 'nolink'),
          'without the Play opt-in link -> nolink');
insert into app_private.admin_settings(key, value) values ('play_optin_link', 'https://play.test/optin');
insert into r select 'and', say('/addandroidtester  Pat@Mail.TEST ');
select ok((select v @> '[{"k":"andOk"}]' from r where name = 'and'), 'android add -> andOk');
select ok((select v @> '[{"k":"fwd"}]' from r where name = 'and'), 'android add -> the forward card');
select ok((select v @> '[{"k":"fwd","l":"https://play.test/optin","e":"pat@mail.test"}]' from r where name = 'and'),
          'the forward card carries the Play opt-in link and the tester''s real email (design: the invite names it)');
select is((select count(*) from app_private.allowlist where email = 'pat@mail.test'), 1::bigint,
          'the email is allowlisted lower-cased and trimmed');
select is((select platform from app_private.tester_platform where email = 'pat@mail.test'), 'android',
          'tagged android');
select is((select count(*) from app_private.admin_jobs where email_masked like 'p%' and kind = 'add'), 0::bigint,
          'no Apple job for an android tester');
select is((select count(*) from public.messages
            where conversation_id = (select id from adm) and admin_msg->>'k' = 'andOk'
              and position('pat@mail.test' in lower(body || admin_msg::text)) > 0), 0::bigint,
          'andOk masks the email');

insert into r select 'and2', say('/addandroidtester pat@mail.test');
select ok((select v @> '[{"k":"andOk"}]' from r where name = 'and2'), 'adding again still replies');
select is((select count(*) from app_private.allowlist where email = 'pat@mail.test'), 1::bigint,
          'and makes no duplicate row');

insert into r select 'ios', say('/addiostester ivy@mail.test');
select ok((select v @> '[{"k":"iosOk"}]' from r where name = 'ios'), 'iPhone add -> iosOk');
select is((select platform from app_private.tester_platform where email = 'ivy@mail.test'), 'ios', 'tagged ios');
select is((select count(*) from app_private.admin_jobs where kind = 'add' and email = 'ivy@mail.test'
             and state = 'pending'), 1::bigint, 'an Apple add job is queued');
select is((select count(*) from app_private.admin_jobs where kind = 'add' and email = 'ivy@mail.test'
             and position('ivy@mail.test' in email_masked) = 0), 1::bigint, 'the job''s masked email is masked');
select is(leaks('ivy@mail.test'), 0::bigint, 'iPhone add: replies and log are masked');
select is(leaks('pat@mail.test'), 0::bigint, 'android add: replies (but the list/forward card) and log are masked');

-- the list now: full emails, split by platform
insert into app_private.tester_platform(email, platform) values ('rob@mail.test', 'android');
insert into r select 'list1', say('/listtesters');
select ok((select v->0->'ios' @> '["ivy@mail.test"]' from r where name = 'list1'), 'list: ivy under ios, full email');
select ok((select v->0->'and' @> '["pat@mail.test", "rob@mail.test"]' from r where name = 'list1'),
          'list: pat and rob under and, full email');
select ok((select not v->0->'oth' @> '["rob@mail.test"]' and not v->0->'oth' @> '["ivy@mail.test"]' from r where name = 'list1'),
          'list: tagged testers are not under oth');
select is((select (v->0->>'n')::int from r where name = 'list1'),
          (select count(*)::int from app_private.allowlist), 'list: n is the allowlist count');
select is((select count(*) from app_private.admin_commands c where position('@mail.test' in lower(row_to_json(c)::text)) > 0
             and position('***' in lower(row_to_json(c)::text)) = 0), 0::bigint,
          'no log row holds an unmasked email');

-- 2 who gets parsed -------------------------------------------------------------
select fresh();
create temp table cnt as select (select count(*) from app_private.admin_commands) as n;

-- control: the owner, inserting with his claims and no admin_msg, is parsed.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac001","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac001', '/listtesters');
select set_config('request.jwt.claims', '', true);
select ok(fresh() @> '[{"k":"list"}]', 'control: the owner''s message (sender = auth.uid()) is parsed');

-- the same, but carrying admin_msg: fails only "without admin_msg"
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac001","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body, admin_msg)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac001', '/listtesters', '{"k":"list"}');
select set_config('request.jwt.claims', '', true);
select is(fresh(), '[]'::jsonb, 'an owner row that already has admin_msg is not parsed');

-- sender is the owner, but auth.uid() is someone else: fails only sender = auth.uid()
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac002","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac001', '/listtesters');
select set_config('request.jwt.claims', '', true);
select is(fresh(), '[]'::jsonb, 'a row whose sender is not auth.uid() is not parsed');

-- a non-owner, as itself (sender = auth.uid(), admin chat, no admin_msg): fails only "owner"
-- (inserted by the superuser: RLS would already stop mal; this proves the parser's own check)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac002","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac002', '/listtesters');
select set_config('request.jwt.claims', '', true);
select is(fresh(), '[]'::jsonb, 'a non-owner''s row in the admin chat is not parsed');

-- the system sender, as itself (sender = auth.uid(), admin chat, no admin_msg): fails only "owner"
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad41","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-00000000ad41', '/listtesters');
select set_config('request.jwt.claims', '', true);
select is((select count(*) from public.messages where conversation_id = (select id from adm)
            and sender_id = '00000000-0000-0000-0000-00000000ad41' and id not in (select id from seen)), 1::bigint,
          'a system-sender row (only the inserted one) does not re-enter the parser');
select fresh();

-- the owner, in an ordinary chat
select as_own();
select is(try_exec($$insert into public.messages(conversation_id, sender_id, body)
                     values ('ac0c0000-0000-0000-0000-000000000001', auth.uid(), '/listtesters')$$),
          'ok:1', 'control: the owner may post in an ordinary chat');
reset role;
select is((select count(*) from public.messages where conversation_id = 'ac0c0000-0000-0000-0000-000000000001'
            and sender_id = '00000000-0000-0000-0000-00000000ad41'), 0::bigint,
          'a command typed in another chat gets no reply there');
select is(fresh(), '[]'::jsonb, 'nor in the admin chat');

-- a non-owner cannot even write into the admin chat
select as_mal();
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body)
                            values (%L, auth.uid(), '/listtesters')$$, (select id from adm))),
          'err:42501', 'mal cannot post into the admin chat');
reset role;
select is(fresh(), '[]'::jsonb, 'and nothing answers');
select is((select count(*) from app_private.admin_commands), (select n from cnt) + 1,
          'only the control was logged');

-- clients cannot write the admin columns
select as_own();
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body, admin_msg)
                            values (%L, auth.uid(), 'x', '{"k":"list"}')$$, (select id from adm))),
          'err:42501', 'the owner cannot insert admin_msg');
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body, admin_push)
                            values (%L, auth.uid(), 'x', true)$$, (select id from adm))),
          'err:42501', 'the owner cannot insert admin_push');
select is(try_exec($$insert into public.messages(conversation_id, sender_id, body, admin_push)
                     values ('ac0c0000-0000-0000-0000-000000000001', auth.uid(), 'x', true)$$),
          'err:42501', 'nor admin_push in an ordinary chat');
select doesnt_match(try_exec(format($$update public.messages set admin_msg = '{"k":"rmOk"}' where conversation_id = %L$$,
                                    (select id from adm))), '^ok:[1-9]', 'the owner cannot update admin_msg');
select matches(try_exec($$insert into public.conversations(admin_chat) values (true)$$), '^err:',
               'a client cannot create an admin chat');
select doesnt_match(try_exec($$update public.conversations set admin_chat = true
                                where id = 'ac0c0000-0000-0000-0000-000000000001'$$), '^ok:[1-9]',
                    'a client cannot flag a chat admin');
reset role;
select is((select count(*) from public.messages where admin_msg is not null
            and sender_id = '00000000-0000-0000-0000-0000000ac001'), 1::bigint,
          'only the superuser-made row above carries admin_msg from the owner');

-- 6 the admin conversation refuses every group, membership and send RPC --------
select as_own();
-- controls in the ordinary group, so each refusal below is about the admin chat
select is(try_exec($$select public.create_poll('ac0c0000-0000-0000-0000-000000000001', gen_random_uuid(), 'q', array['a','b'], false, false)$$),
          'ok:1', 'control: create_poll works in an ordinary group');
select is(try_exec($$select public.send_contact('ac0c0000-0000-0000-0000-000000000001', gen_random_uuid(), 'Ann', '+905550000000')$$),
          'ok:1', 'control: send_contact works in an ordinary group');
select is(try_exec($$select public.send_location('ac0c0000-0000-0000-0000-000000000001', gen_random_uuid(), 41.0, 29.0, 'x', 'y')$$),
          'ok:1', 'control: send_location works in an ordinary group');
select is(try_exec($$insert into public.messages(conversation_id, sender_id, body, forwarded)
                     values ('ac0c0000-0000-0000-0000-000000000001', auth.uid(), 'fw', true)$$),
          'ok:1', 'control: a forward works in an ordinary group');
select is(try_exec($$select public.set_group_settings('ac0c0000-0000-0000-0000-000000000001', true, null, null)$$),
          'ok:1', 'control: set_group_settings works in an ordinary group');
-- (no client can rename any chat today; the 'rename' row below guards the admin chat if that changes)

create temp table refused(name text, res text);
grant all on refused to authenticated;
insert into refused values
 ('add_members',        try_exec(format($$select public.add_members(%L, array['00000000-0000-0000-0000-0000000ac002']::uuid[], true)$$, (select id from adm)))),
 ('leave_group',        try_exec(format($$select public.leave_group(%L)$$, (select id from adm)))),
 ('remove_member',      try_exec(format($$select public.remove_member(%L, '00000000-0000-0000-0000-00000000ad41')$$, (select id from adm)))),
 ('set_admin',          try_exec(format($$select public.set_admin(%L, '00000000-0000-0000-0000-0000000ac001', true)$$, (select id from adm)))),
 ('set_group_avatar',   try_exec(format($$select public.set_group_avatar(%L, 'x/y.jpg')$$, (select id from adm)))),
 ('set_group_settings', try_exec(format($$select public.set_group_settings(%L, true, true, true)$$, (select id from adm)))),
 ('set_members_can_pin',try_exec(format($$select public.set_members_can_pin(%L, true)$$, (select id from adm)))),
 ('delete_group',       try_exec(format($$select public.delete_group(%L)$$, (select id from adm)))),
 ('delete_direct_chat', try_exec(format($$select public.delete_direct_chat(%L)$$, (select id from adm)))),
 ('create_poll',        try_exec(format($$select public.create_poll(%L, gen_random_uuid(), 'q', array['a','b'], false, false)$$, (select id from adm)))),
 ('send_contact',       try_exec(format($$select public.send_contact(%L, gen_random_uuid(), 'Ann', '+905550000000')$$, (select id from adm)))),
 ('send_location',      try_exec(format($$select public.send_location(%L, gen_random_uuid(), 41.0, 29.0, 'x', 'y')$$, (select id from adm)))),
 ('send_sticker',       try_exec(format($$select public.send_sticker(%L, gen_random_uuid(), gen_random_uuid())$$, (select id from adm)))),
 ('send_sticker_album', try_exec(format($$select public.send_sticker_album(%L, gen_random_uuid(), gen_random_uuid())$$, (select id from adm)))),
 ('forward',            try_exec(format($$insert into public.messages(conversation_id, sender_id, body, forwarded) values (%L, auth.uid(), 'fw', true)$$, (select id from adm)))),
 ('attachment',         try_exec(format($$insert into public.messages(conversation_id, sender_id, body, attachment_path) values (%L, auth.uid(), '', 'a/b.jpg')$$, (select id from adm)))),
 ('rename',             try_exec(format($$update public.conversations set title = 'Hijack' where id = %L$$, (select id from adm))));
reset role;
select is((select string_agg(name || '=' || res, ', ' order by name) from refused where res !~ '^(err:|ok:0$)'),
          null, 'every group, membership and send RPC refuses the admin chat');
select is((select array_agg(user_id::text) from public.conversation_members
            where conversation_id = (select id from adm) and left_at is null),
          array['00000000-0000-0000-0000-0000000ac001'], 'the owner is still the only member');
select is((select concat_ws('|', coalesce(title, '-'), coalesce(avatar_path, '-'), admin_chat::text)
             from public.conversations where id = (select id from adm)), '-|-|true', 'no title, no picture, still admin');
select is((select count(*) from public.messages where conversation_id = (select id from adm)
            and (poll or contact or forwarded or location_lat is not null or sticker_id is not null
                 or attachment_path is not null)), 0::bigint, 'no poll, contact, location, sticker, forward or file landed');

-- 4 removal and admin_answer ---------------------------------------------------
select fresh();
insert into r select 'conf_rob', say('/removetester ROB@mail.test');
select ok((select v @> '[{"k":"conf"}]' from r where name = 'conf_rob'), '/removetester of a listed tester -> conf card');
create temp table card as
  select id, 'rob'::text as who from public.messages
   where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf';
grant select on card to authenticated;
select is((select count(*) from card), 1::bigint, 'one card');
select ok((select coalesce(admin_msg->>'st', 'absent') = 'absent' from public.messages where id = (select id from card where who = 'rob')),
          'a fresh card has st absent');
select is((select state from app_private.admin_pending where card_message_id = (select id from card where who = 'rob')), 'pending',
          'its pending row is pending');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint,
          'nothing is removed before the answer');
select is(leaks('rob@mail.test'), 0::bigint, 'the card and log mask the email');

-- non-owner with app access: fails only is_owner
select as_mal();
select throws_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob')), '42501', null,
                 'mal (allowed, not owner) cannot answer a card');
reset role;
-- a non-owner who IS a member of the admin chat (a state only the server could
-- make; forced here past the membership guard): fails only is_owner
select set_config('app_private.admin_write', 'on', true);
insert into public.conversation_members(conversation_id, user_id)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac002');
select set_config('app_private.admin_write', '', true);
select as_mal();
select throws_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob')), '42501', null,
                 'mal, even as a member of the admin chat, cannot answer a card (owner only)');
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body)
                            values (%L, auth.uid(), 'hello')$$, (select id from adm))),
          'err:42501', 'nor post into it (messages_send_admin is owner only)');
reset role;
delete from public.conversation_members where conversation_id = (select id from adm)
   and user_id = '00000000-0000-0000-0000-0000000ac002';
-- the owner without app access: fails only has_app_access
delete from app_private.allowlist where email = 'own@mail.test';
select as_own();
select throws_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob')), '42501', null,
                 'the owner without app access cannot answer a card');
reset role;
insert into app_private.allowlist(email) values ('own@mail.test');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint,
          'refused answers removed nothing');
select is((select state from app_private.admin_pending where card_message_id = (select id from card where who = 'rob')), 'pending',
          'and left the card pending');

select fresh();
select as_own();
select lives_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob')),
                'the owner removes rob');
reset role;
select ok(fresh() @> '[{"k":"rmOk"}]', 'yes -> rmOk');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 0::bigint, 'rob is off the allowlist');
select is((select count(*) from app_private.active_sessions where user_id = '00000000-0000-0000-0000-0000000ac003'), 0::bigint,
          'rob''s active session is gone');
select is((select count(*) from app_private.admin_jobs where kind = 'remove'), 0::bigint,
          'an android tester gets no Apple remove job');
select is((select admin_msg->>'st' from public.messages where id = (select id from card where who = 'rob')), 'done',
          'the card now says st = done');
select is((select state from app_private.admin_pending where card_message_id = (select id from card where who = 'rob')), 'used',
          'the pending row is used');
select is((select email from app_private.admin_pending where card_message_id = (select id from card where who = 'rob')), null,
          'the used card''s raw email is nulled');
select is(leaks('rob@mail.test'), 0::bigint, 'rmOk and the log mask the email');
select is(owner_for('00000000-0000-0000-0000-0000000ac003'), false, 'sanity: rob is not the owner');
select as_rob();
select is((select count(*) from public.conversations where id = 'ac0c0000-0000-0000-0000-000000000001'), 0::bigint,
          'rob (removed) can read nothing');
reset role;

-- one use: re-list rob, answer the same card again -> nothing happens
insert into app_private.allowlist(email) values ('rob@mail.test');
select fresh();
select as_own();
select is(try_exec(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob'))) ~ '^(ok|err)', true,
          'a second answer returns (or refuses) without crashing the session');
reset role;
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint,
          'a used card cannot remove again');
select ok(not fresh() @> '[{"k":"rmOk"}]', 'and gives no second rmOk');

-- cancel
insert into r select 'conf_rob2', say('/removetester rob@mail.test');
insert into card select id, 'rob2' from public.messages
  where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf' and id not in (select id from card);
select as_own();
select lives_ok(format($$select public.admin_answer(%L, false)$$, (select id from card where who = 'rob2')), 'the owner cancels');
reset role;
select ok(fresh() @> '[{"k":"canOk"}]', 'no -> canOk');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint, 'cancel removes nothing');
select is((select admin_msg->>'st' from public.messages where id = (select id from card where who = 'rob2')), 'cancelled',
          'the card says st = cancelled');
select is((select email from app_private.admin_pending where card_message_id = (select id from card where who = 'rob2')), null,
          'the cancelled card''s raw email is nulled');
select as_own();
select lives_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob2')),
                'yes on a cancelled card does not raise');
reset role;
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint,
          'yes after cancel removes nothing (one use)');

-- expired card -> keep
insert into r select 'conf_rob3', say('/removetester rob@mail.test');
insert into card select id, 'rob3' from public.messages
  where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf' and id not in (select id from card);
update app_private.admin_pending set expires_at = now() - interval '1 second'
 where card_message_id = (select id from card where who = 'rob3');
select as_own();
select lives_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob3')), 'yes on an expired card');
reset role;
select ok(fresh() @> '[{"k":"keep"}]', 'expired -> keep');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint, 'an expired card removes nothing');
select is((select admin_msg->>'st' from public.messages where id = (select id from card where who = 'rob3')), 'expired',
          'the card says st = expired');
select is((select email from app_private.admin_pending where card_message_id = (select id from card where who = 'rob3')), null,
          'the expired card''s raw email is nulled');

-- a card nobody answers: once expired, the raw email must not stay (no cron;
-- the next command is the only thing that runs)
insert into r select 'conf_rob4', say('/removetester rob@mail.test');
insert into card select id, 'rob4' from public.messages
  where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf' and id not in (select id from card);
update app_private.admin_pending set expires_at = now() - interval '1 second'
 where card_message_id = (select id from card where who = 'rob4');
insert into r select 'after_expiry', say('/listtesters');
select is((select email from app_private.admin_pending where card_message_id = (select id from card where who = 'rob4')), null,
          'an unanswered expired card loses its raw email by the next command');
select is((select count(*) from app_private.admin_pending where email is not null and expires_at < now()), 0::bigint,
          'no expired pending row keeps a raw email');

-- the sweep runs first on ANY owner command (here an unknown one): expired
-- pending cards -> state expired, raw email gone; finished jobs (ok, failed)
-- lose their raw email. Controls: a live card, a used card past its time, and
-- unfinished jobs (pending, running) keep what they have.
insert into r select 'conf_rob5', say('/removetester rob@mail.test');
insert into card select id, 'rob5' from public.messages
  where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf' and id not in (select id from card);
insert into r select 'conf_rob6', say('/removetester rob@mail.test');
insert into card select id, 'rob6' from public.messages
  where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf' and id not in (select id from card);
update app_private.admin_pending set expires_at = now() - interval '1 second'
 where card_message_id = (select id from card where who = 'rob5');
-- a card already used, past its time, still holding an email (as a row written before the sweep existed)
update app_private.admin_pending set state = 'used', email = 'old@mail.test', expires_at = now() - interval '1 hour'
 where card_message_id = (select id from card where who = 'rob4');
delete from app_private.admin_jobs where email like 'job-%';
insert into app_private.admin_jobs(kind, email, email_masked, state) values
  ('add', 'job-ok@mail.test', 'j***@m***.test', 'ok'),
  ('remove', 'job-failed@mail.test', 'j***@m***.test', 'failed'),
  ('add', 'job-pending@mail.test', 'j***@m***.test', 'pending'),
  ('remove', 'job-running@mail.test', 'j***@m***.test', 'running');
insert into r select 'sweep_unk', say('/nosuchcommand');
select ok((select v @> '[{"k":"unk"}]' from r where name = 'sweep_unk'), 'fixture: the sweeping command is an unknown one');
select is((select state from app_private.admin_pending where card_message_id = (select id from card where who = 'rob5')), 'expired',
          'sweep: an expired pending card becomes state expired');
select is((select email from app_private.admin_pending where card_message_id = (select id from card where who = 'rob5')), null,
          'sweep: and its raw email is nulled');
select is((select email_masked from app_private.admin_pending where card_message_id = (select id from card where who = 'rob5')),
          'r***@m***.test', 'sweep: the masked email stays');
select is((select state || ':' || coalesce(email, 'null') from app_private.admin_pending
            where card_message_id = (select id from card where who = 'rob6')), 'pending:rob@mail.test',
          'sweep control: a card still in time keeps state pending and its email');
select is((select state from app_private.admin_pending where card_message_id = (select id from card where who = 'rob4')), 'used',
          'sweep control: a used card is not relabelled expired');
select is((select email from app_private.admin_pending where card_message_id = (select id from card where who = 'rob4')), null,
          'sweep: an ended card past its time holding a raw email loses it too');
select is((select count(*) from app_private.admin_pending where email is not null and expires_at < now()), 0::bigint,
          'sweep: after a command no card past its time keeps a raw email');
select is((select email from app_private.admin_jobs where email_masked = 'j***@m***.test' and state = 'ok'), null,
          'sweep: an ok job loses its raw email');
select is((select email from app_private.admin_jobs where email_masked = 'j***@m***.test' and state = 'failed'), null,
          'sweep: a failed job loses its raw email');
select is((select email from app_private.admin_jobs where email_masked = 'j***@m***.test' and state = 'pending'),
          'job-pending@mail.test', 'sweep control: a pending job keeps its email (the Apple step needs it)');
select is((select email from app_private.admin_jobs where email_masked = 'j***@m***.test' and state = 'running'),
          'job-running@mail.test', 'sweep control: a running job keeps its email');
select as_own();
select lives_ok(format($$select public.admin_answer(%L, false)$$, (select id from card where who = 'rob6')),
          'the live card can still be answered after a sweep');
reset role;
delete from app_private.admin_jobs where email_masked = 'j***@m***.test';

-- the owner removing his own address: refused as k = err, with help
insert into r select 'rm_self', say('/removetester Own@Mail.test');
select is((select jsonb_array_length(v) from r where name = 'rm_self'), 1, 'removing his own address -> one reply');
select ok((select v @> '[{"k":"err","help":true}]' from r where name = 'rm_self'), 'and it is k = err with help');
select is((select count(*) from app_private.allowlist where email = 'own@mail.test'), 1::bigint, 'the owner stays on the allowlist');
select is((select count(*) from app_private.admin_pending where email = 'own@mail.test'), 0::bigint, 'and no card is made');

-- iPhone and untagged testers: an Apple remove job is queued
insert into r select 'conf_ivy', say('/removetester ivy@mail.test');
insert into card select id, 'ivy' from public.messages
  where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf' and id not in (select id from card);
insert into r select 'conf_zed', say('/removetester zed@mail.test');
insert into card select id, 'zed' from public.messages
  where conversation_id = (select id from adm) and admin_msg->>'k' = 'conf' and id not in (select id from card);
select as_own();
select lives_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'ivy')), 'remove ivy');
select lives_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'zed')), 'remove zed');
reset role;
select is((select count(*) from app_private.allowlist where email in ('ivy@mail.test', 'zed@mail.test')), 0::bigint,
          'both are off the allowlist');
select is((select count(*) from app_private.admin_jobs where kind = 'remove' and email = 'ivy@mail.test'), 1::bigint,
          'an iPhone tester gets an Apple remove job');
select is((select count(*) from app_private.admin_jobs where kind = 'remove' and email = 'zed@mail.test'), 1::bigint,
          'an untagged tester gets an Apple remove job');
select is(leaks('ivy@mail.test') + leaks('zed@mail.test'), 0::bigint, 'replies and log stay masked');

-- 5 an exception becomes one generic reply ---------------------------------------
alter table app_private.allowlist add constraint qa_boom check (email <> 'boom@mail.test');
select fresh();
select as_own();
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body)
                            values (%L, auth.uid(), '/addandroidtester boom@mail.test')$$, (select id from adm))),
          'ok:1', 'a command that fails inside does not fail the owner''s send');
reset role;
insert into r select 'boom', fresh();
select is((select jsonb_array_length(v) from r where name = 'boom'), 1, 'one reply');
select is((select v->0->>'k' from r where name = 'boom'), 'err', 'and it is k = err');
select is((select (v->0->>'help')::boolean from r where name = 'boom'), true, 'the generic err carries help');
select is((select count(*) from app_private.tester_platform where email = 'boom@mail.test'), 0::bigint,
          'nothing of the failed command is kept');
select is(leaks('boom@mail.test'), 0::bigint, 'the email is not in the reply or the log');
alter table app_private.allowlist drop constraint qa_boom;

-- 7 push -----------------------------------------------------------------------------
select isnt(vault.create_secret('https://ac-test.local/hook', 'notify_on_message_url'), null, 'a notify URL is configured');
create temp table q0 as select count(*) as n from net.http_request_queue;
insert into r select 'push_list', say('/listtesters');
select is((select count(*) from net.http_request_queue), (select n from q0),
          'an owner command and its ordinary replies queue no push');
insert into public.messages(conversation_id, sender_id, body, admin_msg, admin_push)
  values ((select id from adm), '00000000-0000-0000-0000-00000000ad41', 'Apple step failed', '{"k":"fail","r":"x"}', true);
select is((select count(*) from net.http_request_queue), (select n from q0) + 1,
          'an admin reply flagged admin_push queues exactly one push');
insert into public.messages(conversation_id, sender_id, body, admin_msg, admin_push)
  values ((select id from adm), '00000000-0000-0000-0000-00000000ad41', 'Apple step failed', '{"k":"fail","r":"x"}', false);
select is((select count(*) from net.http_request_queue), (select n from q0) + 1,
          'the same reply without the flag queues none');
select as_mal();
select is(try_exec($$insert into public.messages(conversation_id, sender_id, body)
                     values ('ac0c0000-0000-0000-0000-000000000001', auth.uid(), 'ping')$$), 'ok:1', 'control: mal posts');
reset role;
select is((select count(*) from net.http_request_queue), (select n from q0) + 2,
          'control: an ordinary message still queues a push');

-- 8 previews ------------------------------------------------------------------------
select fresh();
insert into r select 'prev', say('/listtesters');
select as_own();
select is((select admin_msg->>'k' from public.conversation_previews where conversation_id = (select id from adm)), 'list',
          'the owner''s preview of the admin chat carries the last reply''s admin_msg');
select is((select admin_msg from public.conversation_previews where conversation_id = 'ac0c0000-0000-0000-0000-000000000001'), null,
          'an ordinary chat''s preview has admin_msg null');
reset role;
select as_mal();
select is((select count(*) from public.conversation_previews where conversation_id = (select id from adm)), 0::bigint,
          'mal sees no preview of the admin chat');
select is((select count(*) from public.messages where conversation_id = (select id from adm)), 0::bigint,
          'nor its messages');
reset role;

-- 9 rate limit ------------------------------------------------------------------------
create temp table rate(i int, v jsonb);
do $$ begin for i in 1..60 loop insert into rate select i, say('/listtesters'); end loop; end $$;
select ok(exists (select 1 from rate where v @> '[{"k":"rate"}]'), 'many commands in a row hit the rate limit (k = rate)');
select ok(not exists (select 1 from rate a join rate b on b.i > a.i
                       where a.v @> '[{"k":"rate"}]' and b.v @> '[{"k":"list"}]'), 'once limited, commands are not run');
insert into app_private.admin_jobs(kind, email, email_masked, state) values ('add', 'job-late@mail.test', 'l***@m***.test', 'ok');
insert into r select 'rated_add', say('/addandroidtester late@mail.test');
select ok((select v @> '[{"k":"rate"}]' from r where name = 'rated_add'), 'fixture: this command is rate limited');
select is((select email from app_private.admin_jobs where email_masked = 'l***@m***.test'), null,
          'the sweep runs even for a rate-limited command (it comes first)');
select ok((select not v @> '[{"k":"andOk"}]' from r where name = 'rated_add'), 'a limited add does not reply andOk');
select is((select count(*) from app_private.allowlist where email = 'late@mail.test'), 0::bigint,
          'and adds nothing');
select is((select count(*) from app_private.admin_commands where outcome = 'rate'), (select count(*) from rate where v @> '[{"k":"rate"}]') + 1,
          'every limited command is logged as rate');

select is((select count(*) from public.messages
             where admin_msg->>'k' = 'err' and (admin_msg->>'help') is distinct from 'true'), 0::bigint,
          'every k = err reply in this run carries help');
select * from finish();
rollback;
