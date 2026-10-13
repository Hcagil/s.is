begin;
select plan(82);

-- SIS Destek says it is an AI in its first message to each user.
--
-- Written from the contract, not the migration:
--   The first non-blank text message a bot sends in a non-system 1:1 to a
--   given other member is stored as INTRO || E'\n\n' || body, once per
--   (bot, user) pair, ever, recorded in app_private.bot_intro_sent(bot_id,
--   user_id) (primary key on both) by the same statement as the send. Later
--   bot messages, human senders, and null or blank bodies are unchanged.
--   Groups (Debug or any other non-system group): the bot's first non-blank
--   message there gets the same line, once per (bot, group), recorded in
--   app_private.bot_group_intro_sent(bot_id, conversation_id), removed with
--   the conversation; a member joining does not bring it back, and a group
--   records nothing per member. A 1:1 whose other member has left is still a
--   1:1 (no line there, as before). A failed first send (rate limit, body over 4000 after the
--   prefix) leaves no row and the next send gets the line. No client role
--   touches bot_intro_sent or executes app_private.messages_bot_intro(). The
--   parallel case runs in test/tool/sis_bot_tool_test.sh (pgTAP has one
--   session).
--
-- Humans: ann  Debug admin; bob in Debug, listed; cat a human 1:1 partner
--   dan listed (bot starts; delist/relist)   eve listed (blank and null)
--   fay listed, starts the 1:1 herself       gus listed (rate limit)
--   hal listed (4000 boundary)               ivy listed, record pre-seeded
--   jon listed, leaves his 1:1 with the bot   kim joins Debug after the line

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-0000001a7b07'::uuid
              else ('00000000-0000-0000-0000-0000001a70' || n)::uuid end
$$;
create function intro(b text) returns text language sql immutable as $$
  select 'Merhaba, ben SIS Destek, bir yapay zekâ asistanıyım. Mesajlarımı yapay zekâ yazar.'
         || E'\n\n' || b
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@sis.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve'),('06','fay'),
               ('07','gus'),('08','hal'),('09','ivy'),('10','jon'),('11','kim')) v(n, name);
insert into app_private.allowlist(email)
select name || '@sis.test' from unnest(array['ann','bob','cat','dan','eve','fay','gus','hal','ivy','jon','kim']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('1a700000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','07','08','09','10','11']) n;
insert into app_private.tag_finds(finder, found_id) values (u('01'), u('02')), (u('01'), u('03')), (u('01'), u('11'));

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'intro-bot@sis.test', now(), '{"full_name":"SIS Destek"}');
insert into app_private.allowlist(email) values ('intro-bot@sis.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('1a7b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then '1a7b0000-0000-0000-0000-000000000001'
                         else '1a700000-0000-0000-0000-0000000000' || n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function runbook() returns void language sql as $$
  select set_config('request.jwt.claims', '', true); select null::void
$$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function group_c(t text, ms uuid[]) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_group_conversation(t, ms); perform commit_check(); return r; end $$;
create function add_c(c uuid, ms uuid[]) returns void language plpgsql as $$
begin perform public.add_members(c, ms, true); perform commit_check(); end $$;
-- Sends as the caller; returns the stored body as postgres sees it.
create function send(c uuid, b text) returns text language plpgsql as $$
declare i uuid;
begin
  insert into public.messages(conversation_id, sender_id, body) values (c, auth.uid(), b) returning id into i;
  return (select body from public.messages where id = i);
end $$;
create function try(q text) returns text language plpgsql as $$
begin execute q; return 'ok';
exception when others then return sqlstate; end $$;
grant execute on function as_(text), u(text), intro(text), commit_check(), group_c(text, uuid[]),
  send(uuid, text), try(text), add_c(uuid, uuid[]) to authenticated, anon;

-- postgres-only truth
create function intro_rows(n text) returns bigint language sql as $$
  select count(*) from app_private.bot_intro_sent where bot_id = u('bot') and user_id = u(n)
$$;
-- per-user records only (a later per-group record is not counted here)
create function intro_total() returns bigint language sql as $$
  select count(*) from app_private.bot_intro_sent
   where user_id in (select id from auth.users where email like '%@sis.test' and id <> u('bot'))
$$;
create function last_body(c uuid) returns text language sql as $$
  select body from public.messages where conversation_id = c order by created_at desc, id desc limit 1
$$;
create function bodies(c uuid, s text) returns text[] language sql as $$
  select array_agg(body order by body) from public.messages
   where conversation_id = c and sender_id = u(s)
$$;
create function group_rows(c uuid) returns bigint language sql as $$
  select count(*) from app_private.bot_group_intro_sent where bot_id = u('bot') and conversation_id = c
$$;
-- the bot's send budget is not what this file tests
create function fresh_budget() returns void language sql as $$
  delete from app_private.bot_actions where bot_id = u('bot')
$$;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07','08','09','10','11'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

select as_('01');
insert into ids values
  ('DEBUG', group_c('Debug', array[u('02')])),
  ('AC', public.start_direct_conversation(u('03')));
reset role;

select runbook();
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('DEBUG'));
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
values (g('DEBUG'), u('bot'), 'member', now() - interval '1 day', now() - interval '1 day');
update app_private.bot_accounts set enabled = true where user_id = u('bot');
insert into app_private.bot_contacts(bot_id, contact_id)
select u('bot'), u(n) from unnest(array['02','04','05','06','07','08','09','10']) n;
select as_('bot'); select public.activate_session(); reset role;

-- 1 schema and grants --------------------------------------------------------------
select has_table('app_private', 'bot_intro_sent', 'app_private.bot_intro_sent exists');
select col_is_pk('app_private', 'bot_intro_sent', array['bot_id', 'user_id'],
                 'its primary key is (bot_id, user_id)');
select has_function('app_private', 'messages_bot_intro', '{}'::name[], 'app_private.messages_bot_intro() exists');
select is_empty(
  $$select r || ' ' || p from unnest(array['anon','authenticated']) r,
                              unnest(array['select','insert','update','delete']) p
     where has_table_privilege(r, 'app_private.bot_intro_sent', p)$$,
  'anon and authenticated hold no select/insert/update/delete on bot_intro_sent');
select has_table('app_private', 'bot_group_intro_sent', 'app_private.bot_group_intro_sent exists');
select col_is_pk('app_private', 'bot_group_intro_sent', array['bot_id', 'conversation_id'],
                 'its primary key is (bot_id, conversation_id)');
select is_empty(
  $$select r || ' ' || p from unnest(array['anon','authenticated','public']) r,
                              unnest(array['select','insert','update','delete']) p
     where has_table_privilege(r, 'app_private.bot_group_intro_sent', p)$$,
  'anon, authenticated and public hold no select/insert/update/delete on bot_group_intro_sent');
select ok(not has_function_privilege('anon', 'app_private.messages_bot_intro()', 'execute')
          and not has_function_privilege('authenticated', 'app_private.messages_bot_intro()', 'execute'),
          'neither anon nor authenticated may execute messages_bot_intro()');
select as_('bot');
select is(try('select count(*) from app_private.bot_intro_sent'), '42501', 'the bot cannot read the record');
select is(try($q$insert into app_private.bot_group_intro_sent(bot_id, conversation_id) values (u('bot'), g('DEBUG'))$q$),
          '42501', 'the bot cannot pre-write a group record (to skip its line)');
select is(try($q$insert into app_private.bot_intro_sent(bot_id, user_id) values (u('bot'), u('04'))$q$), '42501',
          'the bot cannot pre-write a record (to skip its line)');
reset role;
select as_('04');
select is(try('select count(*) from app_private.bot_intro_sent'), '42501', 'a user cannot read the record');
select is(try($q$delete from app_private.bot_intro_sent$q$), '42501',
          'a user cannot delete the record (to get the line again)');
select is(try('select count(*) from app_private.bot_group_intro_sent'), '42501', 'a user cannot read the group record');
reset role;
set local role anon;
select is(try('select count(*) from app_private.bot_intro_sent'), '42501', 'anon cannot read the record');
reset role;

-- 2 groups: the line once per (bot, group), Debug included ---------------------------
select as_('01');
select is(send(g('DEBUG'), 'before the bot'), 'before the bot',
          'a human''s message in Debug before the bot''s first is unchanged');
reset role;
select is(group_rows(g('DEBUG')), 0::bigint, 'and records nothing');
select as_('bot');
select is(try($q$select send(g('DEBUG'), '   ')$q$), '23514', 'a blank first body in Debug is not prefixed (refused as blank)');
select isnt(try($q$select send(g('DEBUG'), null)$q$), 'ok', 'a null first body in Debug is not prefixed (refused)');
reset role;
select is(group_rows(g('DEBUG')), 0::bigint, 'null and blank bodies in Debug leave no group record');
select as_('bot');
select is(send(g('DEBUG'), 'hello debug'), intro('hello debug'),
          'the bot''s first message in Debug carries the line, a blank line, then the body');
select is(send(g('DEBUG'), 'second in debug'), 'second in debug', 'its second message in Debug is unchanged');
reset role;
select is(group_rows(g('DEBUG')), 1::bigint, 'one record for (bot, Debug)');
select is(intro_total(), 0::bigint, 'and no per-member record (once per group, not per member)');
select as_('02');
select is((select count(*) from public.messages where conversation_id = g('DEBUG') and sender_id = u('bot')
             and body = intro('hello debug')),
          1::bigint, 'bob reads the line in Debug through RLS as stored');
select is(send(g('DEBUG'), 'hi bot'), 'hi bot', 'bob''s reply in Debug is unchanged');
reset role;
-- a new member joins Debug
select as_('01');
select add_c(g('DEBUG'), array[u('11')]);
reset role;
select as_('bot');
select is(send(g('DEBUG'), 'welcome kim'), 'welcome kim', 'a new member joining Debug does not bring the line back');
reset role;
select as_('11');
select is(send(g('DEBUG'), 'hi from kim'), 'hi from kim', 'the new member''s first message in Debug is unchanged');
reset role;
select is(group_rows(g('DEBUG')), 1::bigint, 'still one record for (bot, Debug)');

-- a second group (the bot's Debug moved there) gets its own line
select as_('01');
insert into ids values ('G2', group_c('Second', array[u('02')]));
select is(send(g('G2'), 'first in G2'), 'first in G2', 'a human''s first message in another group is unchanged');
reset role;
select runbook();
update app_private.bot_accounts set debug_conversation = g('G2') where user_id = u('bot');
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
values (g('G2'), u('bot'), 'member', now(), now());
select as_('bot');
select is(send(g('G2'), 'hello second'), intro('hello second'), 'the bot''s first message in a second group gets its own line');
select is(send(g('G2'), 'again second'), 'again second', 'and its next one there does not');
reset role;
select is(group_rows(g('G2')), 1::bigint, 'one record for (bot, second group)');
select is(group_rows(g('DEBUG')), 1::bigint, 'and Debug''s record is untouched');
select is(intro_total(), 0::bigint, 'still no per-member record');

-- a deleted conversation takes its record with it
select runbook();
update app_private.bot_accounts set debug_conversation = g('DEBUG') where user_id = u('bot');
delete from public.conversations where id = g('G2');
select is((select count(*) from app_private.bot_group_intro_sent where conversation_id = g('G2')), 0::bigint,
          'deleting a conversation removes its group record');
select is(group_rows(g('DEBUG')), 1::bigint, 'and only that one');
select as_('bot');
select is(send(g('DEBUG'), 'still debug'), 'still debug', 'back in Debug: no second line');
reset role;

-- a system conversation: no line (only a superuser can put a bot message there)
select as_('01'); select public.deliver_release_notes(179); reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;
select runbook();
insert into public.messages(conversation_id, sender_id, body) values (g('SYS'), u('bot'), 'system hello');
select is((select array_agg(body) from public.messages where conversation_id = g('SYS') and sender_id = u('bot')),
          array['system hello'], 'a bot message in a system conversation gets no line');
select is(group_rows(g('SYS')) + intro_rows('01'), 0::bigint, 'and leaves no group or per-user record');
select fresh_budget();


-- 3 the first 1:1 message gets the line, once ---------------------------------------
select as_('bot');
insert into ids values ('BD', public.start_direct_conversation(u('04')));
select is(send(g('BD'), 'hello dan'), intro('hello dan'),
          'the bot''s first message to dan carries the line, a blank line, then the body');
reset role;
select is(intro_rows('04'), 1::bigint, 'one record for (bot, dan)');
select as_('bot');
select is(send(g('BD'), 'again'), 'again', 'its second message to dan is unchanged');
select is(send(g('BD'), 'and again'), 'and again', 'and its third');
reset role;
select is(intro_rows('04'), 1::bigint, 'still one record for (bot, dan)');
select as_('04');
select is(send(g('BD'), 'hi bot'), 'hi bot', 'dan''s reply to the bot is unchanged');
select is((select count(*) from public.messages where conversation_id = g('BD') and sender_id = u('bot')
             and body = intro('hello dan')),
          1::bigint, 'dan reads the line through RLS as stored');
reset role;
select is(intro_total(), 1::bigint, 'a human sender records nothing');

-- 4 non-bot senders -----------------------------------------------------------------
select as_('01');
select is(send(g('AC'), 'hi cat'), 'hi cat', 'a human''s first message in a human 1:1 is unchanged');
select is(send(g('DEBUG'), 'hi all'), 'hi all', 'a human''s message in Debug is unchanged');
reset role;
select as_('06');
insert into ids values ('FB', public.start_direct_conversation(u('bot')));
select is(send(g('FB'), 'hello bot'), 'hello bot', 'a human''s first message to the bot is unchanged');
reset role;
select is(intro_total(), 1::bigint, 'and records nothing');

-- 5 a different user gets its own line, also in a 1:1 the human started ---------------
select as_('bot');
select is(send(g('FB'), 'hi fay'), intro('hi fay'), 'the bot''s first message to fay gets its own line');
select is(send(g('FB'), 'more'), 'more', 'its next one to fay does not');
reset role;
select is(intro_rows('06'), 1::bigint, 'one record for (bot, fay)');
select is(intro_total(), 2::bigint, 'two records in all');

-- 6 null and blank bodies -----------------------------------------------------------
select as_('bot');
insert into ids values ('BE', public.start_direct_conversation(u('05')));
-- A text-only bot's blank body is refused by the body check; with the line
-- added it would pass, so a refusal proves the blank body was not prefixed.
select is(try($q$select send(g('BE'), '   ')$q$), '23514', 'a blank first body is not prefixed (refused as blank)');
select is(try($q$select send(g('BE'), '')$q$), '23514', 'an empty first body is not prefixed (refused as blank)');
select isnt(try($q$select send(g('BE'), null)$q$), 'ok', 'a null first body is not prefixed (refused)');
reset role;
select is(intro_rows('05'), 0::bigint, 'null and blank bodies leave no record');
select as_('bot');
select is(send(g('BE'), 'hello eve'), intro('hello eve'), 'the first real message to eve still gets the line');
reset role;
select fresh_budget();

-- 7 a rate-limited first send leaves no record -----------------------------------------
select as_('bot');
insert into ids values ('BG', public.start_direct_conversation(u('07')));
reset role;
insert into app_private.bot_actions(bot_id, kind) select u('bot'), 'send' from generate_series(1, 20);
select as_('bot');
select throws_ok($q$select send(g('BG'), 'hello gus')$q$, 'RLMT2', null, 'the 21st send in 10 minutes is refused');
reset role;
select is(intro_rows('07'), 0::bigint, 'the refused first send left no record');
select is(bodies(g('BG'), 'bot'), null::text[], 'and no message');
select fresh_budget();
select as_('bot');
select is(send(g('BG'), 'hello gus'), intro('hello gus'), 'the next send to gus gets the line');
reset role;
select is(intro_rows('07'), 1::bigint, 'and records it');

-- 8 4000 characters, counted after the prefix -----------------------------------------
select as_('bot');
insert into ids values ('BH', public.start_direct_conversation(u('08')));
select throws_ok(format($q$select send(g('BH'), %L)$q$, repeat('x', 4001 - char_length(intro('')))),
                 '23514', null, 'a first body one character too long once prefixed is refused');
reset role;
select is(intro_rows('08'), 0::bigint, 'the too-long first send left no record');
select as_('bot');
select is(send(g('BH'), repeat('y', 4000 - char_length(intro('')))), intro(repeat('y', 4000 - char_length(intro('')))),
          'a first body that fits exactly with the line (4000 characters) is stored prefixed');
select is(send(g('BH'), repeat('z', 4000)), repeat('z', 4000), 'a later 4000-character body is stored unchanged');
reset role;
select is(intro_rows('08'), 1::bigint, 'and the fitting first send recorded (bot, hal)');
select fresh_budget();

-- 9 once ever: a seeded record suppresses the line; delisting and relisting does not reset it
select runbook();
insert into app_private.bot_intro_sent(bot_id, user_id) values (u('bot'), u('09'));
select as_('bot');
insert into ids values ('BI', public.start_direct_conversation(u('09')));
select is(send(g('BI'), 'hello ivy'), 'hello ivy', 'with a record already there, the first message has no line');
reset role;
select runbook();
delete from app_private.bot_contacts where bot_id = u('bot') and contact_id = u('04');
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('04'));
select as_('bot');
select is(send(g('BD'), 'back again'), 'back again', 'after delisting and relisting dan, no second line');
reset role;
select is(intro_rows('04'), 1::bigint, 'and still one record for dan');

-- 10 the bot's name is unchanged --------------------------------------------------------
select is((select display_name from public.profiles where user_id = u('bot')), 'SIS Destek',
          'the bot is still named SIS Destek');

-- 11 1:1s are still per user: after the Debug line, and when the other member left ----
select as_('bot');
insert into ids values ('BB', public.start_direct_conversation(u('02')));
select is(send(g('BB'), 'hello bob'), intro('hello bob'),
          'bob, who already saw the Debug line, still gets the line in his first 1:1');
reset role;
select is(intro_rows('02'), 1::bigint, 'one record for (bot, bob)');
select as_('bot');
insert into ids values ('BJ', public.start_direct_conversation(u('10')));
reset role;
select runbook();
update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = g('BJ') and user_id = u('10');
update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = g('BI') and user_id = u('09');
select as_('bot');
select is(send(g('BI'), 'ivy left'), 'ivy left',
          'a 1:1 whose other member left, with that user''s record there: no line (not taken for a group)');
-- As before the group change (checked against a8b0bc2's migration): a 1:1 with
-- no current other member has nobody to introduce to, so no line and no record.
select is(send(g('BJ'), 'hello jon'), 'hello jon',
          'a 1:1 whose other member left, never introduced: no line, as before (not taken for a group)');
select is(send(g('BJ'), 'jon again'), 'jon again', 'nor on the next one');
reset role;
select is(intro_rows('10'), 0::bigint, 'and no per-user record, as before');
select is((select count(*) from app_private.bot_group_intro_sent where bot_id = u('bot')
            and conversation_id in (g('BI'), g('BJ'), g('BB'))), 0::bigint, 'and no group record for any 1:1');

select * from finish();
rollback;
