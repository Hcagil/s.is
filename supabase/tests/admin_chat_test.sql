begin;
select plan(95);

-- Neutral staff registry rows, loaded the way release loads the private file.
do $fx$ begin perform app_private.staff_load($j${
  "chats": [{"key":"staff_a","title_en":"Staff A","title_tr":"Ekip A","sort":1},
            {"key":"staff_b","title_en":"Staff B","title_tr":"Ekip B","sort":2}],
  "commands": [
    {"chat_key":"staff_a","word":"/addios","handler":"tester_add_ios","help_en":"add ios","help_tr":"ios ekle","sort":1},
    {"chat_key":"staff_a","word":"/addandroid","handler":"tester_add_android","help_en":"add android","help_tr":"android ekle","sort":2},
    {"chat_key":"staff_a","word":"/remove","handler":"tester_remove","help_en":"remove","help_tr":"cikar","sort":3},
    {"chat_key":"staff_a","word":"/list","handler":"tester_list","help_en":"list","help_tr":"liste","sort":4},
    {"chat_key":"staff_a","word":"/saleson","handler":"sales_on","help_en":"on","help_tr":"ac","sort":5},
    {"chat_key":"staff_a","word":"/salesoff","handler":"sales_off","help_en":"off","help_tr":"kapat","sort":6},
    {"chat_key":"staff_b","word":"/sales","handler":"sales_total","help_en":"total","help_tr":"toplam","sort":1}]
}$j$::jsonb); end $fx$;

-- Admin chat (the first staff chat, staff_a). The owner types into a private
-- chat; the gate hands each accepted message to the one generic hook,
-- app_private.private_dispatch(conv, sender, body), which lives in the private
-- pack (faked here, inside this transaction). Written from the contract, not
-- from the migration:
--
-- 1. shape and grants: is_owner() takes no argument and is not executable by
--    public/anon; the gate trigger is security definer, search_path='',
--    and executable by nobody; admin_answer is for authenticated only;
--    clients cannot write admin_msg, admin_push or admin_chat.
-- 2. only the owner's own message in the admin conversation, without
--    admin_msg, reaches the hook, once -- each negative fixture fails exactly
--    one gate.
-- 4. admin_answer: owner (with app access) only; an old open 'conf' card
--    answers keep and removes nothing; an expired card -> keep.
-- 5. a raising hook -> one plain k=err reply (no help), never raised.
-- 6. the admin conversation is refused by every group/membership/send RPC.
-- 7. push: only admin rows flagged admin_push go through notify_new_message.
-- 8. privacy: nobody else sees the admin chat; previews carry admin_msg.

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

create temp table adm as select id from public.conversations where admin_chat and staff_key = 'staff_a';
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

-- the fake hook: records what it got, answers one note; '/boom' raises
create table calls(n serial, conv uuid, sender uuid, body text);
create or replace function app_private.private_dispatch(conv uuid, sender uuid, body text) returns void
language plpgsql as $$
begin
  insert into public.calls(conv, sender, body) values (conv, sender, body);
  if body like '%boom%' then raise exception 'fake cause qzx'; end if;
  perform app_private.admin_reply(conv, jsonb_build_object('k', 'note', 't', 'fake reply'));
end $$;
create function ncalls() returns bigint language sql as $$ select count(*) from calls $$;
-- An old 'conf' card for [em] in the admin chat, as build 1 left them open.
create function conf_card(em text, ttl interval default '1 hour') returns uuid language plpgsql as $$
declare cid uuid;
begin
  cid := app_private.admin_reply((select a.id from adm a), jsonb_build_object('k', 'conf', 'e', app_private.admin_mask(em)));
  insert into app_private.admin_pending(card_message_id, email, email_masked, expires_at)
    values (cid, em, app_private.admin_mask(em), now() + ttl);
  return cid;
end $$;
create temp table r(name text primary key, v jsonb);

-- 3 replies come from the system account ---------------------------------------
insert into r select 'note', say('/anything');
select is((select v from r where name = 'note'), '[{"k":"note","t":"fake reply"}]'::jsonb, 'the owner''s message gets exactly the hook''s reply');
select is((select sender_id from public.messages where conversation_id = (select id from adm)
            and admin_msg->>'k' = 'note' limit 1), '00000000-0000-0000-0000-00000000ad41'::uuid,
          'replies come from the system account ...ad41');

-- 2 who gets parsed -------------------------------------------------------------
select fresh();
create temp table cnt as select ncalls() as n;

-- control: the owner, inserting with his claims and no admin_msg, is parsed.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac001","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac001', '/list');
select set_config('request.jwt.claims', '', true);
select ok(fresh() @> '[{"k":"note"}]', 'control: the owner''s message (sender = auth.uid()) reaches the hook');

-- the same, but carrying admin_msg: fails only "without admin_msg"
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac001","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body, admin_msg)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac001', '/list', '{"k":"list"}');
select set_config('request.jwt.claims', '', true);
select is(fresh(), '[]'::jsonb, 'an owner row that already has admin_msg does not reach the hook');

-- sender is the owner, but auth.uid() is someone else: fails only sender = auth.uid()
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac002","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac001', '/list');
select set_config('request.jwt.claims', '', true);
select is(fresh(), '[]'::jsonb, 'a row whose sender is not auth.uid() does not reach the hook');

-- a non-owner, as itself (sender = auth.uid(), admin chat, no admin_msg): fails only "owner"
-- (inserted by the superuser: RLS would already stop mal; this proves the parser's own check)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000ac002","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-0000000ac002', '/list');
select set_config('request.jwt.claims', '', true);
select is(fresh(), '[]'::jsonb, 'a non-owner''s row in the admin chat does not reach the hook');

-- the system sender, as itself (sender = auth.uid(), admin chat, no admin_msg): fails only "owner"
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad41","role":"authenticated"}', true);
insert into public.messages(conversation_id, sender_id, body)
  values ((select id from adm), '00000000-0000-0000-0000-00000000ad41', '/list');
select set_config('request.jwt.claims', '', true);
select is((select count(*) from public.messages where conversation_id = (select id from adm)
            and sender_id = '00000000-0000-0000-0000-00000000ad41' and id not in (select id from seen)), 1::bigint,
          'a system-sender row (only the inserted one) does not reach the hook');
select fresh();

-- the owner, in an ordinary chat
select as_own();
select is(try_exec($$insert into public.messages(conversation_id, sender_id, body)
                     values ('ac0c0000-0000-0000-0000-000000000001', auth.uid(), '/list')$$),
          'ok:1', 'control: the owner may post in an ordinary chat');
reset role;
select is((select count(*) from public.messages where conversation_id = 'ac0c0000-0000-0000-0000-000000000001'
            and sender_id = '00000000-0000-0000-0000-00000000ad41'), 0::bigint,
          'a command typed in another chat gets no reply there');
select is(fresh(), '[]'::jsonb, 'nor in the admin chat');

-- a non-owner cannot even write into the admin chat
select as_mal();
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body)
                            values (%L, auth.uid(), '/list')$$, (select id from adm))),
          'err:42501', 'mal cannot post into the admin chat');
reset role;
select is(fresh(), '[]'::jsonb, 'and nothing answers');
select is(ncalls(), (select n from cnt) + 1, 'only the control reached the hook, once');

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

-- 4 old conf cards and admin_answer ---------------------------------------------------
select fresh();
create temp table card as select conf_card('rob@mail.test') as id, 'rob'::text as who;
grant select on card to authenticated;
select fresh();
select ok((select coalesce(admin_msg->>'st', 'absent') = 'absent' from public.messages where id = (select id from card where who = 'rob')),
          'a fresh card has st absent');
select is((select state from app_private.admin_pending where card_message_id = (select id from card where who = 'rob')), 'pending',
          'its pending row is pending');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint,
          'nothing is removed before the answer');

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

create temp table before_rob as select
  (select count(*) from app_private.allowlist where email = 'rob@mail.test') a,
  (select count(*) from app_private.active_sessions where user_id = '00000000-0000-0000-0000-0000000ac003') s,
  (select count(*) from app_private.admin_jobs) j;
select is((select a || '/' || s from before_rob), '1/1', 'fixture: rob is listed with an active session');
select fresh();
select as_own();
select lives_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob')),
                'the owner answers yes on an old conf card');
reset role;
select is(fresh(), '[{"k":"keep"}]'::jsonb, 'yes on an old conf card -> exactly keep');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint, 'rob stays on the allowlist');
select is((select count(*) from app_private.active_sessions where user_id = '00000000-0000-0000-0000-0000000ac003'), 1::bigint,
          'rob''s active session stays');
select is((select count(*) from app_private.admin_jobs), (select j from before_rob), 'no job is queued');
select is((select admin_msg->>'st' from public.messages where id = (select id from card where who = 'rob')), 'expired',
          'the card now says st = expired');
select is((select state || ':' || coalesce(email, 'null') from app_private.admin_pending where card_message_id = (select id from card where who = 'rob')),
          'expired:null', 'the pending row is expired and its raw email nulled');
select as_rob();
select is((select count(*) from public.conversations where id = 'ac0c0000-0000-0000-0000-000000000001'), 0::bigint,
          'sanity: rob never was in the ordinary chat');
reset role;

-- expired card -> keep
insert into card select conf_card('rob@mail.test', '-1 second'), 'rob3';
select fresh();
select as_own();
select lives_ok(format($$select public.admin_answer(%L, true)$$, (select id from card where who = 'rob3')), 'yes on an expired card');
reset role;
select ok(fresh() @> '[{"k":"keep"}]', 'expired -> keep');
select is((select count(*) from app_private.allowlist where email = 'rob@mail.test'), 1::bigint, 'an expired card removes nothing');
select is((select admin_msg->>'st' from public.messages where id = (select id from card where who = 'rob3')), 'expired',
          'the card says st = expired');
select is((select email from app_private.admin_pending where card_message_id = (select id from card where who = 'rob3')), null,
          'the expired card''s raw email is nulled');

-- 5 a raising hook becomes one plain reply ---------------------------------------
select fresh();
select as_own();
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body)
                            values (%L, auth.uid(), '/boom zed@mail.test')$$, (select id from adm))),
          'ok:1', 'a raising hook does not fail the owner''s send');
reset role;
insert into r select 'boom', fresh();
select is((select v from r where name = 'boom'), '[{"k":"err"}]'::jsonb, 'one reply, k = err, no help and no cause');
select is((select count(*) from public.messages where conversation_id = (select id from adm) and body like '%qzx%'), 0::bigint,
          'the cause is not in any body');
select is(leaks('zed@mail.test'), 0::bigint, 'the typed email is not echoed in a reply or the log');

-- 7 push -----------------------------------------------------------------------------
select isnt(vault.create_secret('https://ac-test.local/hook', 'notify_on_message_url'), null, 'a notify URL is configured');
create temp table q0 as select count(*) as n from net.http_request_queue;
insert into r select 'push_cmd', say('/anything');
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
insert into r select 'prev', say('/anything');
select as_own();
select is((select admin_msg->>'k' from public.conversation_previews where conversation_id = (select id from adm)), 'note',
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


select is((select count(*) from public.messages
             where admin_msg->>'k' = 'err' and (admin_msg->>'help') is not null), 0::bigint,
          'no k = err reply in this run carries help');
select * from finish();
rollback;
