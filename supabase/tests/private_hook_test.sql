begin;
select plan(152);

-- Generic private hook. Written from the contract, not the migrations. The
-- private functions are NOT part of the public code; here each one is a tiny
-- fake made inside this transaction, so the public side can be driven:
--   app_private.private_handler(name text, conv uuid, owner uuid, c text, rest text)
--   app_private.private_answer(card uuid, yes boolean, conv uuid)
-- 1. staff_commands.handler accepts ^(private:)?[a-z_]{3,40}$ and nothing else.
-- 2. a 'private:<name>' row: the owner's word calls private_handler(<name>, ...)
--    with the arguments passed as values; the function missing -> 'unk' in the
--    first chat, silence in the second; a public-looking name -> 'unk'.
-- 3. second chat: owner plain text / sales word -> exactly one sales reply and
--    no admin_commands row; a private word -> exactly the private reply, no
--    sales reply, no sales_commands row; an error -> 'err' without help.
-- 4. admin_answer: card key and kind must match ('card' <-> 'private:%',
--    'conf' <-> null) or the card expires with 'keep' and nothing is removed;
--    a private card calls private_answer (missing -> expire + keep, raising ->
--    expire + err); cancel stays public and logs the kind; 'conf' unchanged.
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

-- 2 private function missing (no fake yet) -----------------------------------------
drop function if exists app_private.private_handler(text, uuid, uuid, text, text);
drop function if exists app_private.private_answer(uuid, boolean, uuid);
create table a0 as select acmd() a, scmd() s;
select typed('own', ca(), '/fa');
select is(ks(ca()), 'unk', 'missing private function: the first chat gets only unk');
select typed('own', cb('own'), '/fb');
select is(ks(cb('own')), '', 'missing private function: the second chat stays silent');
select typed('own', cb('own'), '/fb some arg');
select is(ks(cb('own')), '', 'missing private function: the second chat stays silent with an argument');
select is(scmd(), (select s from a0), 'missing private function: no sales_commands row for a private word');
select is(acmd(), (select a from a0) + 1, 'missing private function: only the first-chat unk is logged');
select typed('own', cb('own'), '/fa');
select is(ks(cb('own')), 'podUnk', 'a first-chat word typed in the second chat is a plain unknown there');

-- the fakes ------------------------------------------------------------------------
create function app_private.private_handler(name text, conv uuid, owner uuid, c text, rest text) returns void
language plpgsql as $$
begin
  insert into public.calls(fn, a1, a2, a3, a4, a5) values ('handler', name, conv, owner, c, rest);
  if name = 'fake_boom' then raise exception 'fake failure'; end if;
  perform app_private.admin_reply(conv, jsonb_build_object('k', 'note', 't', 'fake reply'));
end $$;
create function app_private.private_answer(card uuid, yes boolean, conv uuid) returns void
language plpgsql as $$
begin
  insert into public.calls(fn, a2, a3, yes) values ('answer', card, conv, yes);
  if (select on_ from public.fail_answer) then raise exception 'fake failure'; end if;
  perform app_private.admin_reply(conv, jsonb_build_object('k', 'note', 't', 'fake done'));
end $$;

-- 3 dispatch -------------------------------------------------------------------------
create table a1 as select acmd() a, scmd() s;
select typed('own', ca(), '/fa');
select is((select admin_msg->>'t' || '|' || body from last_reply(ca())), 'fake reply|fake reply',
          'the private reply is a note whose body is its t text');
select is(ks(ca()), 'note', 'first chat: a private word gives exactly the private reply');
select is((select a1 || '|' || a2 || '|' || a3 || '|' || coalesce(a5, '') from calls where fn = 'handler' order by n desc limit 1),
          'fake_cmd|' || ca() || '|' || u('own') || '|', 'private_handler gets the name without the prefix, the chat and the owner');
select typed('own', ca(), '/fa tst1@mail.test');
select is((select a5 from calls order by n desc limit 1), 'tst1@mail.test', 'the argument reaches private_handler');
select is(ks(ca()), 'note', 'and still exactly one reply');
select typed('own', ca(), '/fmax');
select is((select a1 from calls order by n desc limit 1), repeat('a', 40), 'a 40-letter name is passed whole');
select ks(ca());

-- crafted arguments arrive as values and run nothing
create table c0 as select (select count(*) from app_private.allowlist) n, ncalls() c;
select typed('own', ca(), '/fa x''); delete from app_private.allowlist; --');
select typed('own', ca(), '/fa $1 %s %L '' ; select 1');
select is((select string_agg(a5, '#' order by n) from calls where n > (select c from c0)),
          'x''); delete from app_private.allowlist; --#$1 %s %L '' ; select 1', 'crafted arguments reach private_handler unchanged');
select is((select count(*) from app_private.allowlist), (select n from c0), 'and nothing else changes');
select is(ks(ca()), 'note,note', 'each gets one private reply');

-- names that only look private are not private
create table c1 as select ncalls() c;
select typed('own', ca(), '/fpx');
select typed('own', ca(), '/fpu');
select typed('own', ca(), '/fax');
select is(ks(ca()), 'unk,unk,unk', 'privatex_ / private_ names and a glued word -> unk');
select is(ncalls(), (select c from c1), 'and private_handler is not called');

-- second chat
create table a2 as select acmd() a, scmd() s, ncalls() c;
select typed('own', cb('own'), '/fb');
select is(ks(cb('own')), 'note', 'second chat: a private word gives exactly the private reply');
select typed('own', cb('own'), '/fb tst2@mail.test');
select is(ks(cb('own')), 'note', 'second chat: with an argument too');
select is((select string_agg(a2::text || '|' || coalesce(a5, ''), ',' order by n) from calls where n > (select c from a2)),
          cb('own') || '|,' || cb('own') || '|tst2@mail.test', 'private_handler gets the second chat and the argument');
select is(scmd(), (select s from a2), 'second chat: a private word makes no sales_commands row');

create table a3 as select acmd() a, scmd() s, ncalls() c;
select typed('own', cb('own'), 'hello there');
select is(ks(cb('own')), 'podUnk', 'second chat: owner plain text gets exactly one reply, the sales unknown');
-- sales switched off: the sales word answers at once (no job)
update app_private.sales_state set off = true;
select typed('own', cb('own'), '/sales');
select matches(ks(cb('own')), '^[A-Za-z0-9_]+$', 'second chat: the sales word gets exactly one reply');
select is(acmd(), (select a from a3), 'second chat: plain text and the sales word make no admin_commands row');
select is(scmd(), (select s from a3) + 2, 'they are sales commands');
-- many plain texts do not use up (they do fill the sales rate limit: the
-- private word below must still reach the private path, before that limit)
-- and do not use up the owner's command budget in the first chat
select typed('own', cb('own'), 'chat ' || i) from generate_series(1, 30) i;
select ks(cb('own'));
select is(acmd(), (select a from a3), 'thirty plain texts in the second chat: still no admin_commands row');
select typed('own', ca(), '/fa');
select is(ks(ca()), 'note', 'and the first chat still answers (no rate-limit count)');

-- a command admin's private word in the second chat: not the owner -> nothing
create table c2 as select ncalls() c;
select typed('adm', cb('adm'), '/fb');
select is(ks(cb('adm')), '', 'a command admin''s private word gets no reply');
select is(ncalls(), (select c from c2), 'and private_handler is not called for a non-owner');

-- errors
select typed('own', cb('own'), '/fbboom');
select is((select coalesce((admin_msg->>'help')::boolean, false) from last_reply(cb('own'))), false,
          'second chat: the err reply carries no help');
select is((select body from last_reply(cb('own'))), app_private.admin_body('{"k":"err"}'::jsonb),
          'second chat: the err body is the plain err text (no tester list)');
select is(ks(cb('own')), 'err', 'second chat: a failing private function gives exactly err');
select typed('own', ca(), '/fboom');
select is((select coalesce((admin_msg->>'help')::boolean, false) from last_reply(ca())), true,
          'first chat: err keeps its help, unchanged');
select is(ks(ca()), 'err', 'first chat: a failing private function gives exactly err');

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
select typed('own', ca(), '/remove tst7@mail.test');
create table k3 as select id from public.messages
  where conversation_id = ca() and admin_msg->>'k' = 'conf' and id not in (select id from seen);
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

-- 4c a normal conf card is unchanged (kind null: the coalesce)
select typed('own', ca(), '/remove tst9@mail.test');
create table k5 as select id from public.messages
  where conversation_id = ca() and admin_msg->>'k' = 'conf' and id not in (select id from seen);
select ks(ca());
select is(ans('own', (select id from k5), true), 'ok', 'yes on a normal conf card');
select is(listed('tst9@mail.test'), 0::bigint, 'the tester IS removed');
select is(card_state((select id from k5)), 'used:null', 'the card is used');
select is(ks(ca()), 'rmOk', 'the reply is rmOk');
select typed('own', ca(), '/remove tst10@mail.test');
create table k6 as select id from public.messages
  where conversation_id = ca() and admin_msg->>'k' = 'conf' and id not in (select id from seen);
select ks(ca());
create table l1 as select count(*) n from app_private.admin_commands where md5(command) = 'dc6e9609a26f1c6b9cea40c6e280f669';  -- the log word of the public removal card, as before
select is(ans('own', (select id from k6), false), 'ok', 'cancel on a normal conf card');
select is(ks(ca()), 'canOk', 'cancel -> canOk');
select is(listed('tst10@mail.test'), 1::bigint, 'cancel removes nothing');
select is(card_state((select id from k6)), 'cancelled:null', 'the conf card is cancelled');
select is((select count(*) from app_private.admin_commands where md5(command) = 'dc6e9609a26f1c6b9cea40c6e280f669'), (select n from l1) + 1,
          'the conf cancel is logged with the same word as before');

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
-- first-chat public commands keep their outcome
select typed('own', ca(), '/addandroid tst16@mail.test');
select typed('own', ca(), '/nope');
select typed('own', ca(), 'plain words');
select is(ks(ca()), 'andOk,nolink,unk,unk', 'first chat: public word, unknown word and plain text answer as before');
select is(listed('tst16@mail.test'), 1::bigint, 'the public add still adds');

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

-- R6: a removed tester also loses command-chat access and bot contact (yes on a
-- normal conf card only); other users' rows stay; cancel changes nothing.
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000006f0b01', 'tst11@mail.test', now()),
  ('00000000-0000-0000-0000-0000006f0b02', 'tst12@mail.test', now()),
  ('00000000-0000-0000-0000-0000006f0b03', 'fakebot@sis.test', now());
insert into app_private.bot_accounts(user_id, debug_conversation) values ('00000000-0000-0000-0000-0000006f0b03', ca());
insert into app_private.command_admins(user_id) values ('00000000-0000-0000-0000-0000006f0b01'), ('00000000-0000-0000-0000-0000006f0b02');
insert into app_private.bot_contacts(bot_id, contact_id) values
  ('00000000-0000-0000-0000-0000006f0b03', '00000000-0000-0000-0000-0000006f0b01'),
  ('00000000-0000-0000-0000-0000006f0b03', '00000000-0000-0000-0000-0000006f0b02');
create function r6(who text) returns text language sql as $$
  select (select count(*) from app_private.command_admins where user_id = ('00000000-0000-0000-0000-0000006f0b' || who)::uuid)
   || '/' || (select count(*) from app_private.bot_contacts where contact_id = ('00000000-0000-0000-0000-0000006f0b' || who)::uuid) $$;
select is(r6('01') || ' ' || r6('02'), '1/1 1/1', 'R6 fixture: both testers have access and a contact');
select typed('own', ca(), '/remove tst11@mail.test');
create table r6a as select id from public.messages
  where conversation_id = ca() and admin_msg->>'k' = 'conf' and id not in (select id from seen);
select ks(ca());
select typed('own', ca(), '/remove tst12@mail.test');
create table r6b as select id from public.messages
  where conversation_id = ca() and admin_msg->>'k' = 'conf' and id not in (select id from seen) and id not in (select id from r6a);
select ks(ca());
select is(ans('own', (select id from r6b), false), 'ok', 'R6 cancel');
select is(r6('02'), '1/1', 'R6 cancel keeps the access and the contact');
select is(ans('own', (select id from r6a), true), 'ok', 'R6 yes on a normal conf card');
select is(listed('tst11@mail.test'), 0::bigint, 'R6 the tester is removed');
select is(r6('01'), '0/0', 'R6 the removed tester has no access row and no contact row');
select is((select count(*) from app_private.command_admins where user_id = '00000000-0000-0000-0000-0000006f0b01'), 0::bigint, 'R6 access row gone');
select is((select count(*) from app_private.bot_contacts where contact_id = '00000000-0000-0000-0000-0000006f0b01'), 0::bigint, 'R6 contact row gone');
select is(r6('02'), '1/1', 'R6 another user keeps both rows');
select is((select count(*) from app_private.command_admins where user_id = u('own')), 1::bigint, 'R6 the owner keeps the access row');

-- A private word after leading whitespace (tab, newline): still only the private reply in the second chat.
create table ws as select scmd() s, ncalls() c;
select typed('own', cb('own'), E'\t/fb');
select is(ks(cb('own')), 'note', 'second chat: a private word after a tab gets exactly the private reply');
select typed('own', cb('own'), E'\n/fb tst2@mail.test');
select is(ks(cb('own')), 'note', 'second chat: a private word after a newline, with an argument, gets exactly one reply');
select is(scmd(), (select s from ws), 'second chat: leading whitespace makes no sales_commands row');
select is(ncalls(), (select c from ws) + 2, 'second chat: private_handler ran for both');

select * from finish();
rollback;
