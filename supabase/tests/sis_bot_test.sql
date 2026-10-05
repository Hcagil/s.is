begin;
select plan(131);

-- SIS Bot: one auth user (sis-destek-bot@example.com, "SIS Destek",
-- sis_destek) that an AI session drives with its own JWT only.
--
-- Written from the contract (docs/DECISIONS.md, docs/SECURITY.md "SIS Bot"),
-- not from the migration:
--   app_private.bot_accounts(user_id, debug_conversation, enabled default
--   false = the OFF switch), bot_contacts(bot_id, contact_id), bot_actions(
--   bot_id, kind in ('send','start'), at); none granted to clients.
--   is_bot(uid) for authenticated; bot_conversation_allowed(bot, conv) for
--   nobody; public.bot_ids() for authenticated, 42501 without app access.
--   The bot reads and writes ONLY Debug and 1:1s with listed contacts; a
--   membership anywhere else, or as admin, is refused by trigger even for a
--   superuser; never auto-promoted; starts a 1:1 only with a listed contact
--   (and a listed contact may start one with it); RLMT2 above 20 sends in
--   10 min, 200 in 24 h, or 10 starts in 24 h; text only; refused on
--   find_by_tag, set_group_avatar, deliver_release_notes,
--   register_device_token, own profile update, contacts, attachment upload,
--   avatar writes and Realtime; OFF refuses every path; delisting drops the
--   1:1 membership and its history, relisting starts history at now().
--
-- Each negative fixture fails ONE gate. The humans:
--   ann  Debug's admin; the positive control for every bot refusal
--   bob  listed, in Debug                  cat  NOT listed, in Debug (so
--   dan  listed, shares nothing                 reach alone would admit him)
--   eve  NOT listed, shares nothing        fay  listed, starts a 1:1 herself
--   gus, hal  a second group (promotion on delete)
--   ivy, jon, kai, lee  listed, fresh partners for the start budget and OFF
--   max  allowlisted, session revoked (bot_ids without app access)
-- The deferred admin guard fires only at COMMIT, which a test never reaches,
-- so group RPCs run through wrappers that SET CONSTRAINTS ALL IMMEDIATE.

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000000b07' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@bot.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve'),('06','fay'),
               ('07','gus'),('08','hal'),('09','ivy'),('10','jon'),('11','kai'),('12','lee'),
               ('13','max')) v(n, name);
insert into app_private.allowlist(email)
select name || '@bot.test'
  from unnest(array['ann','bob','cat','dan','eve','fay','gus','hal','ivy','jon','kai','lee','max']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('b0700000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','07','08','09','10','11','12','13']) n;
-- reach for the human-made fixtures only
insert into app_private.tag_finds(finder, found_id) values
  (u('01'), u('02')), (u('01'), u('03')), (u('07'), u('08'));

-- The bot, as the admin API creates it (the hook is Auth-side; see
-- signup_hook_test.sql and the tool test).
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'sis-destek-bot@example.com', now(), '{"full_name":"SIS Destek"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());

create function as_(n text, sess text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', coalesce(sess, case when n = 'bot' then 'b07b0000-0000-0000-0000-000000000001'
                                        else 'b0700000-0000-0000-0000-0000000000' || n end))::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on function as_(text, text), u(text) to authenticated, anon;

create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function leave_c(c uuid) returns void language plpgsql as $$
begin perform public.leave_group(c); perform commit_check(); end $$;
create function group_c(t text, ms uuid[]) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_group_conversation(t, ms); perform commit_check(); return r; end $$;
create function add_c(c uuid, ms uuid[]) returns void language plpgsql as $$
begin perform public.add_members(c, ms, true); perform commit_check(); end $$;
create function admin_c(c uuid, m uuid, b boolean) returns void language plpgsql as $$
begin perform public.set_admin(c, m, b); perform commit_check(); end $$;
grant execute on function commit_check(), leave_c(uuid), group_c(text, uuid[]),
  add_c(uuid, uuid[]), admin_c(uuid, uuid, boolean) to authenticated;

-- A runbook statement: postgres with no JWT at all. as_() claims are
-- transaction-local and outlive `reset role`, so they are cleared explicitly.
create function runbook() returns void language sql as $$
  select set_config('request.jwt.claims', '', true); select null::void
$$;

-- Statement outcome as the current role: 'ok' or the SQLSTATE.
create function try(q text) returns text language plpgsql as $$
begin execute q; return 'ok';
exception when others then return sqlstate; end $$;
create function rows_changed(q text) returns bigint language plpgsql as $$
declare n bigint;
begin execute q; get diagnostics n = row_count; return n; end $$;
create function send(c uuid, body text default 'hi') returns void language plpgsql as $$
begin
  insert into public.messages(conversation_id, sender_id, body) values (c, auth.uid(), body);
end $$;
create function sees(c uuid) returns bigint language sql as $$
  select count(*) from public.messages where conversation_id = c
$$;
create function can_send(topic text, ext text) returns boolean language plpgsql as $$
begin
  perform set_config('realtime.topic', topic, true);
  insert into realtime.messages (topic, extension, payload, event, private)
  values (topic, ext, '{}'::jsonb, 'probe', true);
  return true;
exception when insufficient_privilege then return false;
end $$;
create function can_receive(topic text, ext text) returns boolean language plpgsql as $$
begin
  perform set_config('realtime.topic', topic, true);
  return exists (select 1 from realtime.messages m where m.extension = ext and m.event = 'fixture');
end $$;
grant execute on function try(text), rows_changed(text), send(uuid, text), sees(uuid),
  can_send(text, text), can_receive(text, text) to authenticated, anon;

-- has_app_access() as the caller sees it (the function itself is not granted;
-- auth.uid() still reads the caller's claims under security definer).
create function access() returns boolean language sql security definer set search_path = '' as $$
  select app_private.has_app_access()
$$;
grant execute on function access() to authenticated;

-- The truth, whatever RLS says (postgres only).
create function bot_member(c uuid) returns boolean language sql as $$
  select exists (select 1 from public.conversation_members
                  where conversation_id = c and user_id = u('bot') and left_at is null)
$$;
create function bot_actions_of(k text) returns bigint language sql as $$
  select count(*) from app_private.bot_actions where bot_id = u('bot') and kind = k
$$;
create function backdate(k text, n int, age interval) returns void language sql as $$
  delete from app_private.bot_actions where bot_id = u('bot') and kind = k;
  insert into app_private.bot_actions(bot_id, kind, at)
  select u('bot'), k, now() - age from generate_series(1, n);
$$;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07','08','09','10','11','12','13'] loop
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
  ('DEBUG', group_c('Debug', array[u('02'), u('03')])),
  ('G2', group_c('other group', array[u('02')])),
  ('AC', public.start_direct_conversation(u('03')));
select send(g('G2'), 'not for the bot');
reset role;
select as_('07');
insert into ids values ('D2', group_c('second debug', array[u('08')]));
reset role;
-- an old Debug message, two hours ago
insert into public.messages(conversation_id, sender_id, body, created_at)
values (g('DEBUG'), u('01'), 'old debug note', now() - interval '2 hours');
select as_('01'); select public.deliver_release_notes(179); reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;
insert into realtime.messages (topic, extension, payload, event, private) values
  ('fixture', 'presence', '{}'::jsonb, 'fixture', true),
  ('fixture', 'broadcast', '{}'::jsonb, 'fixture', true);

-- 1 schema and grants ----------------------------------------------------------
select has_table('app_private', 'bot_accounts', 'app_private.bot_accounts exists');
select has_table('app_private', 'bot_contacts', 'app_private.bot_contacts exists');
select has_table('app_private', 'bot_actions', 'app_private.bot_actions exists');
select col_default_is('app_private', 'bot_accounts', 'enabled', 'false', 'a bot is born OFF');
select is_empty(
  $$select r || ' ' || t from unnest(array['anon','authenticated']) r,
                              unnest(array['app_private.bot_accounts','app_private.bot_contacts',
                                           'app_private.bot_actions']) t
     where has_table_privilege(r, t, 'select,insert,update,delete,truncate,references,trigger')$$,
  'no client role holds any privilege on the bot tables');
select ok(has_function_privilege('authenticated', 'app_private.is_bot(uuid)', 'execute'),
          'authenticated may execute is_bot (policies call it)');
select ok(not has_function_privilege('authenticated', 'app_private.bot_conversation_allowed(uuid, uuid)', 'execute')
          and not has_function_privilege('anon', 'app_private.bot_conversation_allowed(uuid, uuid)', 'execute'),
          'nobody on the client side may execute bot_conversation_allowed');
select ok(has_function_privilege('authenticated', 'public.bot_ids()', 'execute'),
          'authenticated may execute bot_ids');
select ok(not has_function_privilege('anon', 'public.bot_ids()', 'execute'), 'anon may not execute bot_ids');
select throws_ok($$insert into app_private.bot_actions(bot_id, kind) values (u('bot'), 'react')$$,
                 '23514', null, 'bot_actions.kind is only send or start');

-- 2 the profile the admin API gives it ------------------------------------------
select is((select display_name || '|' || tag from public.profiles where user_id = u('bot')),
          'SIS Destek|sis_destek', 'the bot''s profile is "SIS Destek", tag sis_destek');

-- 3 bootstrap while OFF ---------------------------------------------------------
select runbook();
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('DEBUG'));
insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing;
select is((select enabled from app_private.bot_accounts where user_id = u('bot')), false,
          'a new bot_accounts row is OFF');
-- the bot joined Debug three days ago, before everyone: oldest member, so only
-- the bot filter keeps auto-promotion off it.
select runbook();
select lives_ok(
  format($$insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
           values (%L, u('bot'), 'member', now() - interval '3 days', now() - interval '3 days')$$, g('DEBUG')),
  'bootstrap: the runbook (no JWT) adds the bot to Debug while it is OFF');
select ok(app_private.is_bot(u('bot')), 'is_bot(bot) is true');
select ok(not app_private.is_bot(u('01')), 'is_bot(a human) is false');
update app_private.bot_accounts set enabled = true where user_id = u('bot');
select as_('bot');
select ok(public.activate_session(), 'the bot activates its session');
reset role;

-- 4 confinement: what it may read and write --------------------------------------
select as_('bot');
select is(sees(g('DEBUG')), 1::bigint, 'the bot reads Debug history');
select lives_ok($$select send(g('DEBUG'), 'hello from the bot')$$, 'the bot sends in Debug');
select is(sees(g('G2')), 0::bigint, 'it reads nothing of a third chat');
select is((select count(*) from public.conversations where id in (g('G2'), g('AC'))), 0::bigint,
          'nor sees the third chats at all');
select throws_ok($$select send(g('G2'))$$, '42501', null, 'it cannot send to a third chat');
select throws_ok($$select send(g('SYS'))$$, '42501', null, 'nor to a system chat');
select throws_ok($$insert into public.messages(conversation_id, sender_id, body)
                   values (g('DEBUG'), u('01'), 'forged')$$,
                 '42501', null, 'it cannot send as anyone else (sender_id)');
select is((select array_agg(b) from public.bot_ids() b), array[u('bot')], 'the bot sees bot_ids too');
reset role;
select as_('01');
select is((select array_agg(b) from public.bot_ids() b), array[u('bot')], 'a member reads bot_ids: the bot');
reset role;
delete from auth.sessions where user_id = u('13');
select as_('13');
select throws_ok($$select * from public.bot_ids()$$, '42501', null, 'bot_ids without app access: 42501');
reset role;
set local role anon;
select throws_ok($$select * from public.bot_ids()$$, '42501', null, 'anon cannot call bot_ids');
reset role;

select runbook();
insert into app_private.bot_contacts(bot_id, contact_id)
select u('bot'), u(n) from unnest(array['02','04','06','09','10','11','12']) n;
select ok(app_private.bot_conversation_allowed(u('bot'), g('DEBUG')), 'Debug is allowed');
select ok(not app_private.bot_conversation_allowed(u('bot'), g('G2')), 'another group is not');
select ok(not app_private.bot_conversation_allowed(u('bot'), g('AC')), 'a 1:1 of two humans is not');

-- starting a 1:1
select as_('bot');
select lives_ok($$insert into ids values ('BD', public.start_direct_conversation(u('04')))$$,
                'the bot starts a 1:1 with a listed contact it shares nothing with');
select throws_ok($$select public.start_direct_conversation(u('05'))$$, '42501', null,
                 'the bot cannot start a 1:1 with an unlisted user');
select throws_ok($$select public.start_direct_conversation(u('03'))$$, '42501', null,
                 'nor with an unlisted user it reaches through Debug');
select throws_ok($$select group_c('bot group', array[u('02')])$$, '42501', null,
                 'the bot cannot start a group');
reset role;
select ok(bot_member(g('BD')), 'the bot is a current member of its 1:1 with dan');
select ok(app_private.bot_conversation_allowed(u('bot'), g('BD')), 'and that 1:1 is allowed');
select is(bot_actions_of('start'), 1::bigint, 'the bot''s start was logged once');
select as_('06');
select lives_ok($$insert into ids values ('FB', public.start_direct_conversation(u('bot')))$$,
                'a listed contact starts a 1:1 with the bot, sharing nothing with it');
reset role;
select is(bot_actions_of('start'), 1::bigint, 'a human starting with the bot is not logged as a bot start');
select as_('03');
select throws_ok($$select public.start_direct_conversation(u('bot'))$$, '42501', null,
                 'an unlisted human who reaches the bot through Debug cannot start a 1:1 with it');
reset role;
select as_('bot');
select lives_ok($$select send(g('BD'), 'hi dan')$$, 'the bot sends in its 1:1 with dan');
select lives_ok($$select send(g('FB'), 'hi fay')$$, 'and in the 1:1 fay started');
reset role;

-- membership: every other way in is refused
select as_('01');
select throws_ok($$select group_c('with bot', array[u('02'), u('bot')])$$, '42501', null,
                 'a human cannot start a group that includes the bot');
select throws_ok($$select add_c(g('G2'), array[u('bot')])$$, '42501', null,
                 'add_members of the bot is refused');
select throws_ok($$select admin_c(g('DEBUG'), u('bot'), true)$$, '42501', null,
                 'set_admin(bot, true) is refused');
reset role;
select runbook();
select throws_ok($$insert into public.conversation_members(conversation_id, user_id) values (g('G2'), u('bot'))$$,
                 '42501', 'not permitted', 'a superuser insert of the bot into another group is refused by trigger');
select throws_ok($$insert into public.conversation_members(conversation_id, user_id) values (g('AC'), u('bot'))$$,
                 '42501', 'not permitted', 'a superuser insert into a 1:1 of two humans is refused');
select throws_ok($$insert into public.conversation_members(conversation_id, user_id) values (g('SYS'), u('bot'))$$,
                 '42501', 'not permitted', 'a superuser insert into a system chat is refused');
select throws_ok($$update public.conversation_members set role = 'admin'
                    where conversation_id = g('DEBUG') and user_id = u('bot')$$,
                 '42501', 'not permitted', 'a superuser cannot make the bot admin of Debug');
select ok(not bot_member(g('G2')) and not bot_member(g('AC')), 'the bot is in neither chat');
select is((select role from public.conversation_members where conversation_id = g('DEBUG') and user_id = u('bot')),
          'member', 'the bot is still an ordinary Debug member');

-- 5 text only, its own name only ---------------------------------------------------
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', g('DEBUG') || '/bot.jpg', u('bot')::text, '{"size":3}'::jsonb),
  ('attachments', g('DEBUG') || '/ann.jpg', u('01')::text, '{"size":3}'::jsonb);
select as_('01');
select lives_ok($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
                  values (g('DEBUG'), u('01'), '', g('DEBUG') || '/ann.jpg')$$,
                'control: a human sends a photo she owns');
reset role;
select as_('bot');
select throws_ok($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
                   values (g('DEBUG'), u('bot'), '', g('DEBUG') || '/bot.jpg')$$,
                 '42501', null, 'the bot cannot send an attachment, even one it owns');
reset role;

-- 6 refused paths ---------------------------------------------------------------
-- profile: USING excludes the bot, so its update matches nothing
select as_('01');
select is(rows_changed($$update public.profiles set display_name = 'Ann B' where user_id = u('01')$$),
          1::bigint, 'control: a human updates her own profile');
reset role;
select as_('bot');
select is(rows_changed($$update public.profiles set display_name = 'Evil' where user_id = u('bot')$$),
          0::bigint, 'the bot cannot rename itself');
select is(rows_changed($$update public.profiles set tag = 'sis_evil' where user_id = u('bot')$$),
          0::bigint, 'nor change its tag');
select is(rows_changed($$update public.profiles set share_presence = true where user_id = u('bot')$$),
          0::bigint, 'nor its sharing settings');
reset role;
select is((select display_name || '|' || tag from public.profiles where user_id = u('bot')),
          'SIS Destek|sis_destek', 'its profile is unchanged');

-- contacts: the bot reaches bob through Debug, so only the bot clause refuses
select as_('01');
select is(try($$insert into public.contacts(owner_id, contact_id) values (u('01'), u('02'))$$), 'ok',
          'control: a human saves a contact she shares Debug with');
reset role;
select as_('bot');
select is(try($$insert into public.contacts(owner_id, contact_id) values (u('bot'), u('02'))$$), '42501',
          'the bot cannot save a contact');
select throws_ok($$select * from public.find_by_tag((select tag from public.profiles where user_id = u('02')))$$,
                 '42501', null, 'the bot cannot use find_by_tag');
reset role;

-- group avatar: a real object, so only the bot refusal can fail it
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('avatars', 'group/' || g('DEBUG') || '/9.jpg', u('bot')::text, '{"size":3,"mimetype":"image/jpeg"}'::jsonb),
  ('avatars', 'group/' || g('DEBUG') || '/8.jpg', u('01')::text, '{"size":3,"mimetype":"image/jpeg"}'::jsonb);
select as_('bot');
select throws_ok($$select public.set_group_avatar(g('DEBUG'), 'group/' || g('DEBUG') || '/9.jpg')$$,
                 '42501', null, 'the bot cannot change Debug''s picture');
reset role;
select as_('01');
select lives_ok($$select public.set_group_avatar(g('DEBUG'), 'group/' || g('DEBUG') || '/8.jpg')$$,
                'control: a member changes Debug''s picture');
reset role;

-- release notes and push
select as_('bot');
select throws_ok($$select public.deliver_release_notes(179)$$, '42501', null, 'the bot gets no release notes');
-- build 1 predates every note, so no system chat would be made: only the
-- function's own bot refusal can fail this one.
select throws_ok($$select public.deliver_release_notes(1)$$, '42501', null,
                 'not even a call that would deliver nothing');
select throws_ok($$select public.register_device_token('sisbot-test-token-bot', 'android')$$, '42501', null,
                 'the bot cannot register a push token');
reset role;
select as_('02');
select lives_ok($$select public.register_device_token('sisbot-test-token-bob', 'android')$$,
                'control: a human registers a push token');
reset role;
select is((select count(*) from app_private.device_tokens where user_id = u('bot')), 0::bigint,
          'the bot has no push token');

-- storage
select as_('02');
select is(try(format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('attachments', %L, %L, '{"size":3}'::jsonb)$$, g('DEBUG') || '/b.jpg', u('02'))),
          'ok', 'control: a Debug member uploads an attachment');
select is(try(format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('avatars', %L, %L, '{"size":3,"mimetype":"image/jpeg"}'::jsonb)$$,
                     'profile/' || u('02') || '/1.jpg', u('02'))),
          'ok', 'control: a human uploads her own profile picture');
select is(try(format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('avatars', %L, %L, '{"size":3,"mimetype":"image/jpeg"}'::jsonb)$$,
                     'group/' || g('DEBUG') || '/b.jpg', u('02'))),
          'ok', 'control: a Debug member uploads a group picture');
reset role;
select as_('bot');
select is(try(format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('attachments', %L, %L, '{"size":3}'::jsonb)$$, g('DEBUG') || '/x.jpg', u('bot'))),
          '42501', 'the bot cannot upload an attachment');
select is(try(format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('avatars', %L, %L, '{"size":3,"mimetype":"image/jpeg"}'::jsonb)$$,
                     'profile/' || u('bot') || '/1.jpg', u('bot'))),
          '42501', 'nor its own profile picture');
select is(try(format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('avatars', %L, %L, '{"size":3,"mimetype":"image/jpeg"}'::jsonb)$$,
                     'group/' || g('DEBUG') || '/x.jpg', u('bot'))),
          '42501', 'nor a Debug group picture');
reset role;

-- Realtime: sharing switched on for both, so only the bot clause refuses
update public.profiles set share_presence = true, share_typing = true, share_read_status = true
 where user_id in (u('bot'), u('01'));
select as_('01');
select ok(can_receive('presence:members', 'presence') and can_send('presence:members', 'presence')
          and can_receive('typing:' || g('DEBUG'), 'broadcast') and can_send('typing:' || g('DEBUG'), 'broadcast')
          and can_receive('reads:' || g('DEBUG'), 'broadcast'),
          'control: a human joins presence, Debug typing and Debug reads');
reset role;
select as_('bot');
select ok(not can_receive('presence:members', 'presence'), 'the bot cannot receive presence');
select ok(not can_send('presence:members', 'presence'), 'nor send presence');
select ok(not can_receive('typing:' || g('DEBUG'), 'broadcast'), 'nor receive Debug typing');
select ok(not can_send('typing:' || g('DEBUG'), 'broadcast'), 'nor send Debug typing');
select ok(not can_receive('reads:' || g('DEBUG'), 'broadcast'), 'nor receive Debug read marks');
reset role;
update public.profiles set share_presence = false, share_typing = false, share_read_status = false
 where user_id = u('bot');

-- 7 rate limits ---------------------------------------------------------------------
select backdate('send', 0, '0'::interval);
select as_('bot');
select lives_ok($$select send(g('DEBUG'), 'n' || i) from generate_series(1, 20) i$$,
                '20 sends in 10 minutes are fine');
select throws_ok($$select send(g('DEBUG'), 'n21')$$, 'RLMT2', null, 'the 21st in 10 minutes is refused (RLMT2)');
reset role;
select is(bot_actions_of('send'), 20::bigint, 'the refused send left no log row');
select backdate('send', 20, '11 minutes');
select as_('bot');
select lives_ok($$select send(g('DEBUG'), 'later')$$, 'sends older than 10 minutes do not count');
reset role;
select backdate('send', 199, '1 hour');
select as_('bot');
select lives_ok($$select send(g('DEBUG'), '200th')$$, 'the 200th send in 24 h is fine');
select throws_ok($$select send(g('DEBUG'), '201st')$$, 'RLMT2', null, 'the 201st in 24 h is refused (RLMT2)');
reset role;
select is(bot_actions_of('send'), 200::bigint, 'and left no log row');
select backdate('send', 200, '25 hours');
select as_('bot');
select lives_ok($$select send(g('DEBUG'), 'next day')$$, 'sends older than 24 h do not count');
reset role;
select as_('01');
select lives_ok($$select send(g('DEBUG'), 'h' || i) from generate_series(1, 25) i$$,
                'a human is not rate limited by the bot limits');
reset role;
select is((select count(*) from app_private.bot_actions where bot_id <> u('bot')), 0::bigint,
          'humans leave no bot_actions rows');

select backdate('start', 10, '1 hour');
select as_('bot');
select throws_ok($$select public.start_direct_conversation(u('09'))$$, 'RLMT2', null,
                 'the 11th start in 24 h is refused (RLMT2)');
reset role;
select is(bot_actions_of('start'), 10::bigint, 'the refused start left no log row');
select ok(not exists (select 1 from public.conversations where direct_key like '%' || u('09') || '%'),
          'and no empty conversation');
select backdate('start', 9, '1 hour');
select as_('bot');
select lives_ok($$select public.start_direct_conversation(u('10'))$$, 'the 10th start in 24 h is fine');
select throws_ok($$select public.start_direct_conversation(u('05'))$$, '42501', null,
                 'an unlisted start is refused');
reset role;
select is(bot_actions_of('start'), 10::bigint, 'the start was logged and the refused one was not');
select backdate('start', 10, '25 hours');
select as_('bot');
select lives_ok($$select public.start_direct_conversation(u('11'))$$, 'starts older than 24 h do not count');
reset role;
select backdate('start', 0, '0'::interval);
select backdate('send', 0, '0'::interval);

-- 8 delisting and relisting -----------------------------------------------------------
insert into public.messages(conversation_id, sender_id, body, created_at)
values (g('BD'), u('04'), 'old from dan', now() - interval '1 hour');
select as_('bot');
select is(sees(g('BD')), 2::bigint, 'before delisting the bot reads its 1:1 with dan');
reset role;
select runbook();
delete from app_private.bot_contacts where bot_id = u('bot') and contact_id = u('04');
select ok(not bot_member(g('BD')), 'delisting removes the bot''s membership at once');
select as_('bot');
select is(sees(g('BD')), 0::bigint, 'and its history becomes unreadable');
select throws_ok($$select send(g('BD'))$$, '42501', null, 'and it cannot send there');
select throws_ok($$select public.start_direct_conversation(u('04'))$$, '42501', null,
                 'nor start it again');
reset role;
select runbook();
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('04'));
select ok(bot_member(g('BD')), 'relisting re-adds the membership');
select is((select history_from from public.conversation_members
            where conversation_id = g('BD') and user_id = u('bot') and left_at is null),
          now(), 'with history_from = now()');
select as_('bot');
select is((select count(*) from public.messages where conversation_id = g('BD') and created_at < now()),
          0::bigint, 'older history stays unreadable');
select lives_ok($$select send(g('BD'), 'back')$$, 'it can send again');
reset role;

-- 9 OFF -----------------------------------------------------------------------------
update app_private.bot_accounts set enabled = false where user_id = u('bot');
select as_('bot');
select ok(not access(), 'OFF: the bot has no app access');
select is(sees(g('DEBUG')), 0::bigint, 'OFF: it reads nothing');
select throws_ok($$select send(g('DEBUG'))$$, '42501', null, 'OFF: it cannot send');
select throws_ok($$select public.start_direct_conversation(u('12'))$$, '42501', null,
                 'OFF: it cannot start a 1:1 with a listed contact');
select throws_ok(format('select public.mark_read(%L)', g('DEBUG')), '42501', null, 'OFF: it cannot mark read');
select throws_ok($$select * from public.bot_ids()$$, '42501', null, 'OFF: bot_ids refuses it');
reset role;
select as_('12');
select throws_ok($$select public.start_direct_conversation(u('bot'))$$, '42501', null,
                 'OFF: a listed contact cannot start a 1:1 with it');
reset role;
select runbook();
delete from app_private.bot_contacts where bot_id = u('bot') and contact_id = u('06');
select lives_ok($$insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('06'))$$,
                'OFF: a runbook list-add (no JWT) is allowed');
select ok(bot_member(g('FB')), 'OFF: the runbook (no JWT) still lists a tester back into the 1:1');
select as_('01');
select ok(access(), 'OFF does not touch humans');
select lives_ok($$select send(g('DEBUG'), 'still here')$$, 'a human still sends in Debug');
reset role;
update app_private.bot_accounts set enabled = true where user_id = u('bot');
select as_('bot');
select ok(access(), 'ON again: access is back');
reset role;

-- 10 sessions ----------------------------------------------------------------------------
create temp table _human_active as select user_id, session_id from app_private.active_sessions where user_id = u('01');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000002', u('bot'), now(), now());
select as_('bot', 'b07b0000-0000-0000-0000-000000000002');
select ok(public.activate_session(), 'a second bot sign-in activates');
reset role;
select as_('bot');
select ok(not access(), 'and the first bot session loses access');
reset role;
select is((select session_id from app_private.active_sessions where user_id = u('01')),
          (select session_id from _human_active), 'a human''s active session is untouched');
delete from auth.sessions where user_id = u('bot');
select as_('bot', 'b07b0000-0000-0000-0000-000000000002');
select ok(not access(), 'revoked: deleting the bot''s sessions ends access at once');
reset role;
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000003', u('bot'), now() + interval '1 second', now());
select as_('bot', 'b07b0000-0000-0000-0000-000000000003');
select ok(public.activate_session(), 'a fresh mint activates again');
reset role;

-- 11 never admin, never promoted ------------------------------------------------------------
-- promote_on_member_deleted: D2 becomes the Debug chat (the runbook path) and
-- the bot is its oldest member.
select runbook();
update app_private.bot_accounts set debug_conversation = g('D2') where user_id = u('bot');
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
values (g('D2'), u('bot'), 'member', now() - interval '3 days', now() - interval '3 days');
select lives_ok($$delete from public.conversation_members where conversation_id = g('D2') and user_id = u('07');
                  select commit_check()$$,
                'deleting the admin''s membership is accepted');
select is((select string_agg(cm.user_id::text, ',') from public.conversation_members cm
            where conversation_id = g('D2') and left_at is null and role = 'admin'),
          u('08')::text, 'the human is promoted, not the older bot');
update app_private.bot_accounts set debug_conversation = g('DEBUG') where user_id = u('bot');

-- leave_group in Debug: the bot is its oldest member
select as_('01');
select lives_ok($$select leave_c(g('DEBUG'))$$, 'the last admin leaves Debug');
reset role;
select is((select role from public.conversation_members
            where conversation_id = g('DEBUG') and user_id = u('bot') and left_at is null),
          'member', 'the bot is not promoted on leave');
select is((select count(*) from public.conversation_members
            where conversation_id = g('DEBUG') and left_at is null and role = 'admin'),
          1::bigint, 'a human is');
select as_('02'); select lives_ok($$select leave_c(g('DEBUG'))$$, 'bob leaves'); reset role;
select as_('03');
select lives_ok($$select leave_c(g('DEBUG'))$$, 'the last human leaves a group of himself and the bot');
reset role;
select is((select count(*) from public.conversation_members
            where conversation_id = g('DEBUG') and left_at is null and role = 'admin'),
          0::bigint, 'and the bot was not made admin to let him');

select * from finish();
rollback;
