begin;
select plan(134);

-- Generic private hook. Written from the contract, not the migrations. The
-- private functions are NOT part of the public code; here each one is a tiny
-- fake made inside this transaction (or dropped, to stand for a missing pack),
-- so the public side is driven the same with or without the real pack:
--   app_private.private_dispatch(conv uuid, sender uuid, body text)
--   app_private.private_answer(card uuid, yes boolean, conv uuid)
-- 1. staff_commands.handler accepts ^(private:)?[a-z_]{3,40}$ and nothing else.
-- 2. both chat gates call private_dispatch exactly once per accepted message,
--    with the chat, the sender and the body unchanged; the public side runs no
--    command of its own (no sales job, no tester change). Hook missing ->
--    silence (no reply, no error to the sender). Hook raising -> exactly one
--    'err' reply with no help and no cause.
-- 3. the first chat (staff_a) takes only the owner; the second chat (staff_b)
--    takes the owner or a command admin.
-- 4. admin_answer: answers only private cards (key 'card', kind 'private:%');
--    a mismatch, a missing private_answer or an old open 'conf' card expires
--    with 'keep' and removes nothing (allowlist, sessions, command admins, bot
--    contacts, no job); a raising private_answer expires with 'err'; cancel
--    stays public and logs the kind.
-- 5. admin_body: 'card' and 'note' show msg->>'t'; other keys unchanged.
-- 6. only the owner who is a member of the card's chat can answer; a client
--    cannot forge a card.

-- helpers ----------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000006f00' || case n
    when 'own' then '01' when 'adm' then '02' when 'mal' then '03' end)::uuid $$;
create function s(n text) returns uuid language sql immutable as $$
  select ('6f000000-0000-0000-0000-0000000000' || right(u(n)::text, 2))::uuid $$;
grant execute on function u(text), s(text) to authenticated, anon;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', s(n))::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on function as_(text) to authenticated;

create function act(n text) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform as_(n);
  r := public.activate_session();
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

-- A message [n] types into [conv], as the server sees a client insert, past RLS.
create function typed(n text, conv uuid, t text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u(n), 'role', 'authenticated')::text, true);
  insert into public.messages(conversation_id, sender_id, body) values (conv, u(n), t);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Server replies in [conv] since the last call: their k, sorted (one
-- transaction gives every message the same created_at, so order is not kept).
create table seen(id uuid primary key);
create function ks(conv uuid) returns text language plpgsql as $$
declare r text;
begin
  select coalesce(string_agg(m.admin_msg->>'k', ',' order by m.admin_msg->>'k'), '') into r
    from public.messages m
   where m.conversation_id = conv and m.sender_id = '00000000-0000-0000-0000-00000000ad41'
     and m.id not in (select id from seen);
  insert into seen select m.id from public.messages m
   where m.conversation_id = conv and m.id not in (select id from seen);
  return r;
end $$;
-- The unseen reply in [conv] (call before ks, when exactly one is expected).
create function last_reply(conv uuid) returns public.messages language sql as $$
  select m.* from public.messages m
   where m.conversation_id = conv and m.sender_id = '00000000-0000-0000-0000-00000000ad41'
     and m.id not in (select id from seen) limit 1 $$;

-- admin_answer as [n]; 'ok' or 'err:<sqlstate>'.
create function ans(n text, card uuid, yes boolean) returns text language plpgsql as $$
begin
  perform as_(n);
  perform public.admin_answer(card, yes);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return 'ok';
exception when others then
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return 'err:' || sqlstate;
end $$;

create function try_sql(q text) returns text language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then
  return 'err:' || sqlstate;
end $$;

-- A server card in [conv] with key [k], a pending row for [em] and [kind]
-- (dynamic, so a missing kind column fails the tests, not the file).
create function mkcard(conv uuid, k text, em text, kind text, ttl interval default '1 hour') returns uuid
language plpgsql as $$
declare id uuid;
begin
  id := app_private.admin_reply(conv, jsonb_build_object('k', k, 't', 'Fake card ' || em, 'e', 'x***@m***.test'));
  execute 'insert into app_private.admin_pending(card_message_id, email, email_masked, expires_at, kind)
           values ($1, $2, ''x***@m***.test'', now() + $3, $4)' using id, em, ttl, kind;
  return id;
exception when others then
  return null;
end $$;

create function listed(e text) returns bigint language sql as $$ select count(*) from app_private.allowlist where email = e $$;
create function acmd() returns bigint language sql as $$ select count(*) from app_private.admin_commands $$;
create function scmd() returns bigint language sql as $$ select count(*) from app_private.sales_commands $$;
create function card_state(id uuid) returns text language sql as $$
  select state || ':' || coalesce(email, 'null') from app_private.admin_pending where card_message_id = id $$;
create function card_st(id uuid) returns text language sql as $$
  select coalesce(admin_msg->>'st', 'absent') from public.messages where id = $1 $$;

-- what the fakes were given
create table calls(n serial, fn text, a1 text, a2 uuid, a3 uuid, a4 text, a5 text, yes boolean);
create table fail_answer(on_ boolean);
insert into fail_answer values (false);
create function ncalls() returns bigint language sql as $$ select count(*) from calls $$;

-- fixtures -------------------------------------------------------------------
-- own  owner (allowlisted, active): staff_a chat, and command admin -> staff_b chat
-- adm  command admin (allowlisted, active): own staff_b chat
-- mal  allowlisted, active, not owner
insert into auth.users (id, email, email_confirmed_at)
  select u(n), n || '@sis.test', now() from unnest(array['own','adm','mal']) n;
insert into app_private.allowlist(email) select n || '@sis.test' from unnest(array['own','adm','mal']) n;
insert into app_private.allowlist(email)
  select 'tst' || i || '@mail.test' from generate_series(1, 20) i;
-- android testers: a removal queues no Apple job, so its only reply is rmOk
insert into app_private.tester_platform(email, platform)
  select 'tst' || i || '@mail.test', 'android' from generate_series(1, 20) i;
insert into auth.sessions (id, user_id, created_at, updated_at)
  select s(n), u(n), now(), now() from unnest(array['own','adm','mal']) n;
select is((select count(*) from unnest(array['own','adm','mal']) n where act(n)), 3::bigint, 'fixture: sessions active');

insert into app_private.owners(user_id) values (u('own'));
insert into app_private.command_admins(user_id) values (u('adm'));
create table chat as
  select m.user_id as who, c.staff_key as k, c.id from public.conversations c
    join public.conversation_members m on m.conversation_id = c.id and m.left_at is null
   where c.staff_key is not null;
create function ca() returns uuid language sql stable as $$ select id from chat where who = u('own') and k = 'staff_a' $$;
create function cb(n text) returns uuid language sql stable as $$ select id from chat where who = u(n) and k = 'staff_b' $$;
select isnt(ca(), null, 'fixture: the owner has a staff_a chat');
select isnt(cb('own'), null, 'fixture: the owner has a staff_b chat');
select isnt(cb('adm'), null, 'fixture: the command admin has a staff_b chat');

select lives_ok($$select app_private.staff_load(jsonb_build_object(
  'chats', jsonb_build_array(
    jsonb_build_object('key','staff_a','title_en','Staff A','title_tr','Ekip A','sort',1),
    jsonb_build_object('key','staff_b','title_en','Staff B','title_tr','Ekip B','sort',2)),
  'commands', jsonb_build_array(
    jsonb_build_object('chat_key','staff_a','word','/remove','handler','tester_remove'),
    jsonb_build_object('chat_key','staff_a','word','/addandroid','handler','tester_add_android'),
    jsonb_build_object('chat_key','staff_a','word','/list','handler','tester_list'),
    jsonb_build_object('chat_key','staff_b','word','/sales','handler','sales_total'))))$$,
  'fixture: public rows loaded');
update app_private.sales_state set off = false, amount = null, day = null, fetched_at = null, fail_count = 0;

-- 1 handler CHECK ------------------------------------------------------------------
select is(try_sql(format($$insert into app_private.staff_commands(chat_key, word, handler) values (%L, %L, %L)$$, c, w, h)), 'ok',
          'a private row is accepted: ' || h)
  from (values ('staff_a','/fa','private:fake_cmd'), ('staff_b','/fb','private:fake_cmd'),
               ('staff_a','/fboom','private:fake_boom'), ('staff_b','/fbboom','private:fake_boom'),
               ('staff_a','/fpx','privatex_abc'), ('staff_a','/fpu','private_fake_cmd'),
               ('staff_a','/fmax','private:' || repeat('a', 40))) v(c, w, h);
select is(try_sql(format($$insert into app_private.staff_commands(chat_key, word, handler) values ('staff_a', '/zz', %L)$$, h)), 'err:23514',
          'the handler CHECK refuses: ' || h)
  from unnest(array['private:x''; drop table app_private.allowlist; --', 'private:a;b', 'private:ab',
                    'private:' || repeat('a', 41), 'xprivate:abc', 'private:private:abc', 'Private:abc',
                    'private: abc', 'private:abc ', 'private:abc$1', 'drop_all; --', 'ab', '']) h;
select is(try_sql($$update app_private.staff_commands set handler = 'private:x''y' where word = '/fa'$$), 'err:23514',
          'an update cannot write a crafted name either');


-- consume what the chats were born with
select ks(ca()), ks(cb('own')), ks(cb('adm'));

-- 2 hook missing (stands for "no private pack") ---------------------------------------
drop function if exists app_private.private_dispatch(uuid, uuid, text);
drop function if exists app_private.private_answer(uuid, boolean, uuid);
create table j0 as select (select count(*) from app_private.sales_jobs) j, (select count(*) from app_private.admin_jobs) aj;
select lives_ok($$select typed('own', ca(), '/fa tst1@mail.test')$$, 'missing hook: the owner''s send in the first chat does not fail');
select is(ks(ca()), '', 'missing hook: the first chat stays silent');
select lives_ok($$select typed('own', cb('own'), '/sales')$$, 'missing hook: the owner''s send in the second chat does not fail');
select is(ks(cb('own')), '', 'missing hook: the second chat stays silent');
select typed('adm', cb('adm'), 'plain words');
select is(ks(cb('adm')), '', 'missing hook: a command admin''s chat stays silent');
select is((select count(*) from app_private.sales_jobs), (select j from j0), 'missing hook: no sales job is made by the public side');
select is(listed('tst1@mail.test'), 1::bigint, 'missing hook: nothing about the tester changes');

-- the fakes ------------------------------------------------------------------------
create function app_private.private_dispatch(conv uuid, sender uuid, body text) returns void
language plpgsql as $$
begin
  insert into public.calls(fn, a2, a3, a4) values ('dispatch', conv, sender, body);
  if body like '%boom%' then raise exception 'fake cause qzx'; end if;
  perform app_private.admin_reply(conv, jsonb_build_object('k', 'note', 't', 'fake reply'));
end $$;
create function app_private.private_answer(card uuid, yes boolean, conv uuid) returns void
language plpgsql as $$
begin
  insert into public.calls(fn, a2, a3, yes) values ('answer', card, conv, yes);
  if (select on_ from public.fail_answer) then raise exception 'fake failure'; end if;
  perform app_private.admin_reply(conv, jsonb_build_object('k', 'note', 't', 'fake done'));
end $$;
-- calls since [c], as 'chat|sender|body' with chat/sender named
create function got(c bigint) returns text language sql as $$
  select coalesce(string_agg(
           case a2 when ca() then 'A' when cb('own') then 'Bown' when cb('adm') then 'Badm' else 'other' end || '|' ||
           case a3 when u('own') then 'own' when u('adm') then 'adm' when u('mal') then 'mal' else a3::text end || '|' || a4,
           '#' order by n), '')
    from calls where fn = 'dispatch' and n > c $$;

-- 3 dispatch -------------------------------------------------------------------------
create table c0 as select coalesce(max(n), 0) c from calls;
select typed('own', ca(), '/fa tst2@mail.test');
select is(got((select c from c0)), 'A|own|/fa tst2@mail.test', 'first chat: the owner''s message calls the hook once with chat, sender, body');
select is((select admin_msg->>'t' || '|' || body from last_reply(ca())), 'fake reply|fake reply', 'the hook''s reply is a note whose body is its t text');
select is(ks(ca()), 'note', 'first chat: exactly the hook''s reply, nothing public');
delete from c0; insert into c0 select max(n) from calls;
select typed('own', ca(), t) from unnest(array[E'x''; drop table app_private.allowlist; --', E'\t/fa', E'\n/fa tst3@mail.test', 'plain words', '/list', '/' || repeat('a', 300)]) t;
select is(got((select c from c0)),
          E'A|own|x''; drop table app_private.allowlist; --#A|own|\t/fa#A|own|\n/fa tst3@mail.test#A|own|plain words#A|own|/list#A|own|/' || repeat('a', 300),
          'first chat: any text reaches the hook unchanged, once each');
select is(ks(ca()), 'note,note,note,note,note,note', 'and each gets only the hook''s reply');
select is((select count(*) from app_private.allowlist where email like '%@sis.test'), 3::bigint, 'crafted text runs nothing');

delete from c0; insert into c0 select max(n) from calls;
select typed('own', cb('own'), '/sales');
select typed('adm', cb('adm'), '/sales tst4@mail.test');
select is(got((select c from c0)), 'Bown|own|/sales#Badm|adm|/sales tst4@mail.test',
          'second chat: the owner and a command admin each call the hook once');
select is(ks(cb('own')) || '/' || ks(cb('adm')), 'note/note', 'second chat: exactly the hook''s reply');
select is((select count(*) from app_private.sales_jobs), (select j from j0), 'the public side makes no sales job');

-- the first chat: only the owner (a command admin and a plain user, made members past the guard)
select set_config('app_private.admin_write', 'on', true);
insert into public.conversation_members(conversation_id, user_id, role) values (ca(), u('adm'), 'member'), (ca(), u('mal'), 'member'),
  (cb('own'), u('mal'), 'member');
select set_config('app_private.admin_write', '', true);
delete from c0; insert into c0 select max(n) from calls;
select typed('adm', ca(), '/fa tst5@mail.test');
select typed('mal', ca(), '/fa tst5@mail.test');
select is(got((select c from c0)), '', 'first chat: a command admin or a plain member never reaches the hook');
select is(ks(ca()), '', 'and gets no reply');
-- the second chat: a plain member is not a command admin
select typed('mal', cb('own'), '/sales');
select is(got((select c from c0)), '', 'second chat: a member who is neither owner nor command admin never reaches the hook');
select is(ks(cb('own')), '', 'and gets no reply');
-- a server row, a row with admin_msg, a row not sent as auth.uid(), an ordinary chat
insert into public.conversations(id, title) values ('6f0c0000-0000-0000-0000-000000000001', 'Ordinary');
insert into public.conversation_members(conversation_id, user_id, role) values ('6f0c0000-0000-0000-0000-000000000001', u('own'), 'admin');
select typed('own', '6f0c0000-0000-0000-0000-000000000001', '/fa');
select app_private.admin_reply(ca(), '{"k":"note","t":"server"}'::jsonb);
select set_config('request.jwt.claims', json_build_object('sub', u('own'), 'role', 'authenticated')::text, true);
insert into public.messages(conversation_id, sender_id, body, admin_msg) values (ca(), u('own'), '/fa', '{"k":"note"}');
select set_config('request.jwt.claims', json_build_object('sub', u('mal'), 'role', 'authenticated')::text, true);
insert into public.messages(conversation_id, sender_id, body) values (ca(), u('own'), '/fa');
select set_config('request.jwt.claims', '', true);
select is(got((select c from c0)), '', 'an ordinary chat, a server reply, a row with admin_msg and a row not sent as auth.uid() never reach the hook');
select ks(ca());
-- owner OR command admin: the owner without a command_admins row still reaches the second chat
delete from app_private.command_admins where user_id = u('own');
select is((select count(*) from app_private.command_admins where user_id = u('own')), 0::bigint, 'fixture: the owner holds no command_admins row');
select typed('own', cb('own'), '/sales');
select is(got((select c from c0)), 'Bown|own|/sales', 'second chat: the owner alone (not a command admin) reaches the hook');
select ks(cb('own'));
-- a command admin whose flag is removed no longer reaches it
delete from app_private.command_admins where user_id = u('adm');
delete from c0; insert into c0 select max(n) from calls;
select typed('adm', cb('adm'), '/sales');
select is(got((select c from c0)), '', 'second chat: a removed command admin never reaches the hook');
insert into app_private.command_admins(user_id) values (u('adm'));
select typed('adm', cb('adm'), '/sales');
select is(got((select c from c0)), 'Badm|adm|/sales', 'control: the same user as a command admin reaches it');
select ks(cb('adm'));
select set_config('app_private.admin_write', 'on', true);
delete from public.conversation_members where conversation_id in (ca(), cb('own')) and user_id in (u('adm'), u('mal'));
select set_config('app_private.admin_write', '', true);
insert into app_private.command_admins(user_id) values (u('own')) on conflict do nothing;

-- errors: one plain err, no help, no cause, the send itself succeeds
create table e1 as select r.id, r.admin_msg, r.body from last_reply(ca()) r where false;
select lives_ok($$select typed('own', ca(), '/boom')$$, 'first chat: a raising hook does not fail the owner''s send');
insert into e1 select r.id, r.admin_msg, r.body from last_reply(ca()) r;
select is(ks(ca()), 'err', 'first chat: a raising hook gives exactly one err');
select lives_ok($$select typed('own', cb('own'), '/boom')$$, 'second chat: a raising hook does not fail the owner''s send');
insert into e1 select r.id, r.admin_msg, r.body from last_reply(cb('own')) r;
select is(ks(cb('own')), 'err', 'second chat: a raising hook gives exactly one err');
select is((select count(*) from e1 where coalesce((admin_msg->>'help')::boolean, false) = false), 2::bigint, 'neither err carries help');
select is((select count(*) from e1 where body = app_private.admin_body('{"k":"err"}'::jsonb)), 2::bigint, 'both bodies are the plain err text');
select is((select count(*) from e1 where (admin_msg::text || body) like '%qzx%'), 0::bigint, 'neither names the cause');

-- 4 admin_answer -----------------------------------------------------------------------
-- 4a private_answer missing: the private card expires, nothing is removed
alter function app_private.private_answer(uuid, boolean, uuid) rename to private_answer_off;
create table k1 as select mkcard(ca(), 'card', 'tst5@mail.test', 'private:fake_cmd') id;
select isnt((select id from k1), null, 'fixture: a private card');
select is(card_state((select id from k1)), 'pending:tst5@mail.test', 'fixture: it is pending');
select ks(ca());
select is(ans('own', (select id from k1), true), 'ok', 'yes on a private card without private_answer does not raise');
select is(card_state((select id from k1)), 'expired:null', 'the card expires and its email is nulled');
select is(listed('tst5@mail.test'), 1::bigint, 'nothing is removed');
select is(ks(ca()), 'keep', 'the reply is keep');
alter function app_private.private_answer_off(uuid, boolean, uuid) rename to private_answer;

-- 4b key and kind mismatch, both ways, and an unprefixed kind
create table k2 as select mkcard(ca(), 'card', 'tst6@mail.test', null) id;
create table k3 as select mkcard(ca(), 'conf', 'tst7@mail.test', null) id;
select is(try_sql(format($$update app_private.admin_pending set kind = 'private:fake_cmd' where card_message_id = %L$$, (select id from k3))), 'ok',
          'fixture: a conf card with a private kind');
create table k4 as select mkcard(ca(), 'card', 'tst8@mail.test', 'fake_cmd') id;
select ks(ca());
create table c3 as select ncalls() c;
select is(ans('own', id, true), 'ok', 'yes on a mismatched card does not raise: ' || w)
  from (values ((select id from k2), 'card/null'), ((select id from k3), 'conf/private'), ((select id from k4), 'card/unprefixed')) v(id, w);
select is(card_state((select id from k2)), 'expired:null', 'card with kind null: expired, email nulled');
select is(card_state((select id from k3)), 'expired:null', 'conf with a private kind: expired, email nulled');
select is(card_state((select id from k4)), 'expired:null', 'card with an unprefixed kind: expired, email nulled');
select is(card_st(id), 'expired', 'its message says st = expired') from (values ((select id from k2)), ((select id from k3))) v(id);
select is(listed(e), 1::bigint, 'nothing is removed: ' || e) from unnest(array['tst6@mail.test', 'tst7@mail.test', 'tst8@mail.test']) e;
select is(ks(ca()), 'keep,keep,keep', 'each answer gets keep');
select is(ncalls(), (select c from c3), 'private_answer is not called for a mismatch');
-- 4c an old open 'conf' card (kind null) answers keep and removes nothing:
-- no allowlist, session, command admin or bot contact row goes, no job is queued
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000006f0b01', 'tst11@mail.test', now()),
  ('00000000-0000-0000-0000-0000006f0b03', 'fakebot@sis.test', now());
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('6f0b0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000006f0b01', now(), now());
insert into app_private.active_sessions(user_id, session_id, session_created_at)
  values ('00000000-0000-0000-0000-0000006f0b01', '6f0b0000-0000-0000-0000-000000000001', now());
insert into app_private.bot_accounts(user_id, debug_conversation) values ('00000000-0000-0000-0000-0000006f0b03', ca());
insert into app_private.command_admins(user_id) values ('00000000-0000-0000-0000-0000006f0b01');
insert into app_private.bot_contacts(bot_id, contact_id) values ('00000000-0000-0000-0000-0000006f0b03', '00000000-0000-0000-0000-0000006f0b01');
create function rows11() returns text language sql as $$
  select (select count(*) from app_private.allowlist where email = 'tst11@mail.test')
   || '/' || (select count(*) from app_private.active_sessions where user_id = '00000000-0000-0000-0000-0000006f0b01')
   || '/' || (select count(*) from app_private.command_admins where user_id = '00000000-0000-0000-0000-0000006f0b01')
   || '/' || (select count(*) from app_private.bot_contacts where contact_id = '00000000-0000-0000-0000-0000006f0b01')
   || '/' || (select count(*) from app_private.admin_jobs) $$;
create table r0 as select rows11() v;
select matches((select v from r0), '^1/1/1/1/', 'fixture: the user has allowlist, session, command admin and bot contact rows');
create table k5 as select mkcard(ca(), 'conf', 'tst11@mail.test', null) id;
select ks(ca());
create table c35 as select ncalls() c;
select is(ans('own', (select id from k5), true), 'ok', 'yes on an old conf card does not raise');
select is(ks(ca()), 'keep', 'yes on an old conf card -> keep');
select is(card_state((select id from k5)), 'expired:null', 'the conf card expires, email nulled');
select is(card_st((select id from k5)), 'expired', 'its message says st = expired');
select is(rows11(), (select v from r0), 'yes on an old conf card removes nothing and queues no job');
select is(ncalls(), (select c from c35), 'an old conf card never reaches private_answer');
create table k6 as select mkcard(ca(), 'conf', 'tst11@mail.test', null) id;
select ks(ca());
select is(ans('own', (select id from k6), false), 'ok', 'cancel on an old conf card does not raise');
select is(rows11(), (select v from r0), 'cancel on an old conf card removes nothing');
select ks(ca());

-- 4d a private card: private_answer gets the card, the answer and the chat
create table k7 as select mkcard(ca(), 'card', 'tst11@mail.test', 'private:fake_cmd') id;
select ks(ca());
create table c4 as select ncalls() c;
select is(ans('own', (select id from k7), true), 'ok', 'yes on a private card');
select is((select a2 || '|' || a3 || '|' || yes from calls where n > (select c from c4) and fn = 'answer'),
          (select id from k7) || '|' || ca() || '|true', 'private_answer gets (card, true, chat), once');
select is(listed('tst11@mail.test'), 1::bigint, 'the public removal never runs for a private card');
select is(ks(ca()), 'note', 'the reply is the private one only');
-- second chat card
create table k8 as select mkcard(cb('own'), 'card', 'tst12@mail.test', 'private:fake_cmd') id;
select ks(cb('own'));
select is(ans('own', (select id from k8), true), 'ok', 'yes on a private card in the second chat');
select is((select a3 from calls order by n desc limit 1), cb('own'), 'private_answer gets the second chat');
select is(listed('tst12@mail.test'), 1::bigint, 'nothing is removed there either');
select ks(cb('own'));

-- 4e private cancel stays public and logs the kind
create table k9 as select mkcard(ca(), 'card', 'tst13@mail.test', 'private:fake_cmd') id;
select ks(ca());
create table c5 as select ncalls() c, (select count(*) from app_private.admin_commands where command = 'private:fake_cmd') l;
select is(ans('own', (select id from k9), false), 'ok', 'cancel on a private card');
select is(ncalls(), (select c from c5), 'cancel does not call private_answer');
select is(card_state((select id from k9)), 'cancelled:null', 'the private card is cancelled, email nulled');
select is(card_st((select id from k9)), 'cancelled', 'its message says st = cancelled');
select is(ks(ca()), 'canOk', 'cancel -> canOk');
select is((select count(*) from app_private.admin_commands where command = 'private:fake_cmd'), (select l from c5) + 1,
          'the private cancel is logged with its kind');

-- 4f stale private cards never reach private_answer
create table k10 as select mkcard(ca(), 'card', 'tst14@mail.test', 'private:fake_cmd', '-1 second') id;
select ks(ca());
create table c6 as select ncalls() c;
select is(ans('own', (select id from k10), true), 'ok', 'yes on an expired private card');
select is(ans('own', (select id from k9), true), 'ok', 'yes on the cancelled private card');
select is(ans('own', (select id from k7), true), 'ok', 'yes again on the answered private card');
select is(ncalls(), (select c from c6), 'stale, cancelled and answered cards do not call private_answer');
select is(card_state((select id from k10)), 'expired:null', 'the expired private card is expired, email nulled');
select ks(ca());

-- 4g private_answer raising: the card expires, err
update fail_answer set on_ = true;
create table k11 as select mkcard(ca(), 'card', 'tst15@mail.test', 'private:fake_cmd') id;
select ks(ca());
select is(ans('own', (select id from k11), true), 'ok', 'a failing private_answer does not raise to the client');
select is(card_state((select id from k11)), 'expired:null', 'the card expires, email nulled');
select is(listed('tst15@mail.test'), 1::bigint, 'nothing is removed');
select is(ks(ca()), 'err', 'the reply is err');
update fail_answer set on_ = false;
-- 5 admin_body ---------------------------------------------------------------------
select is(app_private.admin_body(jsonb_build_object('k', k, 't', 'Masked t***@m***.test')), 'Masked t***@m***.test',
          k || ' shows its t text') from unnest(array['card', 'note']) k;
select is(app_private.admin_body(jsonb_build_object('k', k)), '', k || ' without t is empty') from unnest(array['card', 'note']) k;
select is(app_private.admin_body('{"k":"zz_unknown","t":"x"}'::jsonb), '', 'an unknown key stays empty, t is not shown');
select is((select body from public.messages where id = (select id from k7)), 'Fake card tst11@mail.test',
          'a card made through admin_reply has its t text as body');
-- every other key gives the same text as before this change (md5 of the bodies taken on main b6557ec)
select is(md5(string_agg(k || '=' || app_private.admin_body(m), '|' order by k)), 'fa119617bc6689644cc0d9a04e133c6a',
          'existing reply bodies are unchanged')
  from (values
    ('andOk', '{"k":"andOk","e":"a***@m***.test"}'::jsonb), ('bad', '{"k":"bad"}'), ('canOk', '{"k":"canOk"}'),
    ('conf', '{"k":"conf","e":"r***@m***.test"}'), ('err', '{"k":"err"}'), ('iosOk', '{"k":"iosOk","e":"i***@m***.test"}'),
    ('keep', '{"k":"keep"}'), ('noem', '{"k":"noem"}'), ('nolink', '{"k":"nolink"}'),
    ('nolist', '{"k":"nolist","e":"z***@m***.test"}'), ('p3', '{"k":"p3"}'), ('r3', '{"k":"r3"}'), ('rate', '{"k":"rate"}'),
    ('rmOk', '{"k":"rmOk","e":"r***@m***.test"}'), ('unk', '{"k":"unk"}')) v(k, m);

-- 6 who may answer ------------------------------------------------------------------
create table k12 as select mkcard(ca(), 'card', 'tst17@mail.test', 'private:fake_cmd') id;
create table k13 as select mkcard(cb('adm'), 'card', 'tst18@mail.test', 'private:fake_cmd') id;
select ks(ca()); select ks(cb('adm'));
create table c7 as select ncalls() c;
select is(ans('mal', (select id from k12), true), 'err:42501', 'a non-owner cannot answer a private card');
select is(ans('adm', (select id from k13), true), 'err:42501', 'a command admin cannot answer a card in their own chat');
select isnt(ans('own', (select id from k13), true), 'ok', 'the owner cannot answer a card in a chat they are not a member of');
select is(card_state(id), 'pending:' || e, 'refused answers leave the card pending: ' || e)
  from (values ((select id from k12), 'tst17@mail.test'), ((select id from k13), 'tst18@mail.test')) v(id, e);
select is(ncalls(), (select c from c7), 'refused answers never call private_answer');
-- a note with a pending row is not a card
create table k14 as select mkcard(ca(), 'note', 'tst19@mail.test', 'private:fake_cmd') id;
select ks(ca());
select ans('own', (select id from k14), true);
select is(ncalls(), (select c from c7), 'a note is not a card: private_answer is not called');
select is(listed('tst19@mail.test'), 1::bigint, 'and nothing is removed');
-- a client cannot forge a card
select as_('own');
select is(try_sql(format($$insert into public.messages(conversation_id, sender_id, body, admin_msg) values (%L, %L, 'x', '{"k":"card","t":"x"}')$$, ca(), u('own'))) ~ '^err:', true,
          'the owner cannot post a card message');
select is(try_sql(format($$insert into public.messages(conversation_id, sender_id, body, admin_msg) values (%L, %L, 'x', '{"k":"card","t":"x"}')$$, ca(), '00000000-0000-0000-0000-00000000ad41')) ~ '^err:', true,
          'nor one as the server sender');
select is(try_sql($$update app_private.admin_pending set kind = 'private:fake_cmd'$$), 'err:42501', 'nor write a card kind');
reset role;
select is((select count(*) from public.messages where admin_msg->>'k' = 'card' and admin_msg->>'t' = 'x'), 0::bigint, 'no forged card exists');
select ok(exists (select 1 from information_schema.columns where table_schema = 'app_private' and table_name = 'admin_pending' and column_name = 'kind')
          and not has_column_privilege(r, 'app_private.admin_pending', 'kind', p), r || ' has no ' || p || ' on admin_pending.kind')
  from unnest(array['anon', 'authenticated']) r, unnest(array['SELECT', 'INSERT', 'UPDATE']) p;

select * from finish();
rollback;
