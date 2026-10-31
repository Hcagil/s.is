begin;
select plan(37);

-- The app language on the server, and SIS Destek's first line in it.
--
-- Written from the contract, not the migration:
--   profiles.app_language is nullable text, 'en' or 'tr' only (null = Turkish).
--   A client may UPDATE it on its own row only and no client may SELECT it,
--   not even its own. The bot's automatic first line (messages_bot_intro):
--   in a 1:1 it is English when the person's app_language is 'en', else
--   (tr, null) the Turkish line; in a group it is English only when the group
--   has at least one other active (not left) non-bot member and every one of
--   them has 'en', else Turkish. Once per (bot, user) and per (bot, group); a
--   later language change never sends it again.
--
-- Humans: ann, bob  share group GEN (both en) -- ann is also the RLS subject
--   cat en, dan tr    group GMIX               eve null, cat  group GNULL
--   ann en, fay tr    group GLEFT, fay leaves (only en ann is still active)
--   gus en, hal en    group GALONE, both leave (no other active member)
--   ivy, jon          Debug (not under test here)
--   kim en / lee tr / max null / ned null then en   1:1s the bot starts

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-0000002a7b07'::uuid
              else ('00000000-0000-0000-0000-0000002a70' || n)::uuid end
$$;
create function tr_(b text) returns text language sql immutable as $$
  select 'Merhaba, ben SIS Destek, bir yapay zekâ asistanıyım. Mesajlarımı yapay zekâ yazar.'
         || E'\n\n' || b
$$;
create function en_(b text) returns text language sql immutable as $$
  select 'Hi, I''m SIS Support, an AI assistant. My replies are written by AI.' || E'\n\n' || b
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), 'al-' || name || '@sis.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve'),('06','fay'),
               ('07','gus'),('08','hal'),('09','ivy'),('10','jon'),('11','kim'),('12','lee'),
               ('13','max'),('14','ned')) v(n, name);
insert into app_private.allowlist(email)
select 'al-' || name || '@sis.test'
  from unnest(array['ann','bob','cat','dan','eve','fay','gus','hal','ivy','jon','kim','lee','max','ned']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('2a700000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','07','08','09','10','11','12','13','14']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('01'), u('02')), (u('01'), u('06')), (u('03'), u('04')), (u('03'), u('05')),
  (u('07'), u('08')), (u('09'), u('10'));

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'al-bot@sis.test', now(), '{"full_name":"SIS Destek"}');
insert into app_private.allowlist(email) values ('al-bot@sis.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('2a7b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then '2a7b0000-0000-0000-0000-000000000001'
                         else '2a700000-0000-0000-0000-0000000000' || n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function group_c(t text, ms uuid[]) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_group_conversation(t, ms); perform commit_check(); return r; end $$;
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
-- The caller sets [who]'s language as a client does; returns the rows it changed.
create function set_lang(who text, code text) returns int language plpgsql as $$
declare k int;
begin
  update public.profiles set app_language = code where user_id = u(who);
  get diagnostics k = row_count; return k;
end $$;
grant execute on function as_(text), u(text), tr_(text), en_(text), commit_check(),
  group_c(text, uuid[]), send(uuid, text), try(text), set_lang(text, text) to authenticated, anon;

-- postgres-only truth
create function lang_of(n text) returns text language sql as $$
  select app_language from public.profiles where user_id = u(n)
$$;
-- the bot's send budget is not what this file tests
create function fresh_budget() returns void language sql as $$
  delete from app_private.bot_actions where bot_id = u('bot')
$$;
-- The bot is admitted only to its Debug chat, so each group is made its Debug
-- chat in turn (as in bot_intro_test); [join] adds it there once.
create function debug_is(c uuid, join_ boolean default false) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  update app_private.bot_accounts set debug_conversation = c where user_id = u('bot');
  if join_ then
    insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
    values (c, u('bot'), 'member', now() - interval '1 day', now() - interval '1 day');
  end if;
end $$;
create function leave(c uuid, n text) returns void language sql as $$
  update public.conversation_members set left_at = now(), left_reason = 'left'
   where conversation_id = c and user_id = u(n)
$$;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07','08','09','10','11','12','13','14'] loop
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
insert into ids values ('GEN', group_c('Both English', array[u('02')])),
                       ('GLEFT', group_c('One left', array[u('06')]));
reset role;
select as_('03');
insert into ids values ('GMIX', group_c('Mixed', array[u('04')])),
                       ('GNULL', group_c('Unset', array[u('05')]));
reset role;
select as_('07');
insert into ids values ('GALONE', group_c('Nobody left', array[u('08')]));
reset role;
select as_('09');
insert into ids values ('DEBUG', group_c('Debug', array[u('10')]));
reset role;

insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('DEBUG'));
select debug_is(g('DEBUG'), true);
update app_private.bot_accounts set enabled = true where user_id = u('bot');
insert into app_private.bot_contacts(bot_id, contact_id)
select u('bot'), u(n) from unnest(array['11','12','13','14']) n;
select as_('bot'); select public.activate_session(); reset role;

-- 1 the column ---------------------------------------------------------------
select has_column('public', 'profiles', 'app_language', 'profiles.app_language exists');
select col_type_is('public', 'profiles', 'app_language', 'text', 'it is text');
select col_is_null('public', 'profiles', 'app_language', 'it is nullable');
select is(lang_of('13'), null, 'a new profile has no language (null = Turkish)');

-- 2 who may touch it ---------------------------------------------------------
select ok(not has_column_privilege('authenticated', 'public.profiles', 'app_language', 'SELECT'),
          'a signed-in client holds no SELECT on app_language');
select ok(not has_column_privilege('anon', 'public.profiles', 'app_language', 'SELECT')
          and not has_column_privilege('anon', 'public.profiles', 'app_language', 'UPDATE'),
          'anon can neither read nor write app_language');
select ok(has_column_privilege('authenticated', 'public.profiles', 'app_language', 'UPDATE'),
          'a signed-in client may UPDATE app_language');

select as_('01');
-- The negative fixture below must fail only the own-row gate: bob's row is one
-- ann may read (they share GEN), and ann is an active, allowlisted member.
select is((select count(*) from public.profiles where user_id = u('02')), 1::bigint,
          'ann reads bob''s profile row (the read gate is open)');
select is(set_lang('01', 'en'), 1, 'ann sets her own language');
select is(set_lang('02', 'tr'), 0, 'ann''s update of bob''s language changes no row');
select is(try($q$select app_language from public.profiles where user_id = u('01')$q$), '42501',
          'ann cannot read her own language back');
select is(try($q$select app_language from public.profiles where user_id = u('02')$q$), '42501',
          'ann cannot read bob''s language');
select is(try($q$update public.profiles set app_language = 'tr' where user_id = u('01') returning app_language$q$),
          '42501', 'an update cannot return the language either');
select is(try($q$select set_lang('01', 'fr')$q$), '23514', 'a language other than en or tr is refused');
select is(try($q$select set_lang('01', 'EN')$q$), '23514', 'the code is exact: ''EN'' is refused');
select is(try($q$select set_lang('01', '')$q$), '23514', 'an empty code is refused');
reset role;
select is(lang_of('01'), 'en', 'ann''s language is stored as en');
select is(lang_of('02'), null, 'bob''s language is untouched by ann');
select as_('01');
select is(set_lang('01', null), 1, 'ann may clear her language');
reset role;
select is(lang_of('01'), null, 'and it is null again');
set local role anon;
select is(try($q$update public.profiles set app_language = 'en'$q$), '42501', 'anon cannot set a language');
reset role;

-- languages for the bot cases, set as each member's client does
do $$
declare p record;
begin
  for p in select * from (values ('01','en'),('02','en'),('03','en'),('04','tr'),('06','tr'),
                                 ('07','en'),('08','en'),('11','en'),('12','tr')) v(n, c) loop
    perform as_(p.n); perform set_lang(p.n, p.c); execute 'reset role';
  end loop;
end $$;
select leave(g('GLEFT'), '06');
select leave(g('GALONE'), '07'); select leave(g('GALONE'), '08');

-- 3 the 1:1 line follows the person's language ------------------------------
select as_('bot');
insert into ids values ('BK', public.start_direct_conversation(u('11'))),
                       ('BL', public.start_direct_conversation(u('12'))),
                       ('BM', public.start_direct_conversation(u('13'))),
                       ('BN', public.start_direct_conversation(u('14')));
select is(send(g('BK'), 'hi kim'), en_('hi kim'), 'kim (en) gets the English line');
select is(send(g('BL'), 'hi lee'), tr_('hi lee'), 'lee (tr) gets the Turkish line');
select is(send(g('BM'), 'hi max'), tr_('hi max'), 'max (no language) gets the Turkish line');
reset role;
select fresh_budget();
select as_('14'); select set_lang('14', 'en'); reset role;
select as_('bot');
select is(send(g('BN'), 'hi ned'), en_('hi ned'), 'ned, who chose en before the first message, gets English');
reset role;

-- 4 no resend after a language change ----------------------------------------
select as_('11'); select set_lang('11', 'tr'); reset role;
select as_('13'); select set_lang('13', 'en'); reset role;
select as_('bot');
select is(send(g('BK'), 'again kim'), 'again kim', 'kim switching to tr does not bring the line back');
select is(send(g('BM'), 'again max'), 'again max', 'max switching to en does not bring the line back');
reset role;
select is((select count(*) from public.messages where sender_id = u('bot') and conversation_id = g('BK')
             and body like 'Merhaba, ben SIS Destek%'), 0::bigint, 'and no Turkish line is added for kim later');
select fresh_budget();

-- 5 groups ---------------------------------------------------------------------
select debug_is(g('GEN'), true); select as_('bot');
select is(send(g('GEN'), 'hello group'), en_('hello group'),
          'a group where every other active member has en gets English');
reset role; select debug_is(g('GMIX'), true); select as_('bot');
select is(send(g('GMIX'), 'hello mix'), tr_('hello mix'), 'one tr member makes it Turkish');
reset role; select debug_is(g('GNULL'), true); select as_('bot');
select is(send(g('GNULL'), 'hello unset'), tr_('hello unset'), 'one member with no language makes it Turkish');
reset role; select debug_is(g('GLEFT'), true); select as_('bot');
select is(send(g('GLEFT'), 'hello left'), en_('hello left'),
          'a member who left (tr) does not count: the active en member decides');
reset role; select debug_is(g('GALONE'), true); select as_('bot');
select is(send(g('GALONE'), 'hello alone'), tr_('hello alone'),
          'no other active member (the two who left had en): Turkish');
reset role;
select fresh_budget();

-- 6 a group line is not sent again after a language change -------------------
select as_('02'); select set_lang('02', 'tr'); reset role;
select as_('04'); select set_lang('04', 'en'); reset role;
select debug_is(g('GEN')); select as_('bot');
select is(send(g('GEN'), 'second'), 'second', 'bob switching to tr does not resend the group line');
reset role; select debug_is(g('GMIX')); select as_('bot');
select is(send(g('GMIX'), 'second mix'), 'second mix', 'dan switching to en does not resend it either');
reset role;
select is((select count(*) from public.messages where sender_id = u('bot') and conversation_id = g('GEN')
             and (body like 'Merhaba, ben SIS Destek%' or body like 'Hello, I am SIS Destek%')),
          1::bigint, 'GEN holds exactly one first line');

-- 7 humans are never prefixed, whatever their language -----------------------
select as_('01');
select is(send(g('GEN'), 'from ann'), 'from ann', 'a human''s message is unchanged');
reset role;

select * from finish();
rollback;
