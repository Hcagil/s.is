begin;
select plan(177);

-- Reaction notifications, server side (20261107120000_reaction_notifications.sql).
--
-- Written from the contract, not from the migration:
--   device_tokens.reaction_push (default false); register_device_token(
--   device_token, device_platform, shows_itself default false, reaction_push
--   default false) is the only overload; a bot is refused (42501).
--   app_private.notify_reaction(message, reactor): posts
--   {"reaction":{"message_id","user_id"}} to the vault notify_on_message_url;
--   never raises; no URL = no call. set_reaction / set_reaction_encrypted call
--   it only when the emoji (the ciphertext) changed; clear, relock_reaction
--   and a rolled-back RPC queue nothing.
--   app_private.reaction_push_targets_for(message, reactor): rows for the
--   message's sender only, rules R1-R12 (bot reactors excluded).
--   public.reaction_push_targets(message, reactor): service_role only; claims
--   (message, reactor, updated_at) once; nothing when updated_at is older than
--   2 min; L1 < 3 per (message, reactor) in 10 min; L2 < 10 in 10 min and
--   < 30 in 60 min per (reactor, recipient); log rows older than 24 h deleted.
--   app_private.reaction_push_log: RLS on, no policies, no client grants.
--
-- now() is frozen inside this transaction, so every time is set relative to
-- it by hand (updated_at, sent_at) as the superuser.
--
--   ava  sends the messages: the only recipient
--   ben  reacts (the reactor under test)
--   cyd  third member of the group (must never get a row)
--   dan  ava's keyed 1:1 partner: the private chat P
--   bot  an enabled bot account

-- fixtures -----------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000d10' || case n
    when 'ava' then '01' when 'ben' then '02' when 'cyd' then '03' when 'dan' then '04'
    when 'bot' then '05' end)::uuid
$$;
create function sid(n text) returns uuid language sql immutable as $$
  select ('d1000000-0000-0000-0000-' || right(u(n)::text, 12))::uuid
$$;
create function mid(n text) returns uuid language sql immutable as $$ select md5('rp-msg-' || n)::uuid $$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', sid(n))::text, true);
  execute 'set local role authenticated';
end $$;
-- 'ok' or the sqlstate, in its own subtransaction.
create function try(q text) returns text language plpgsql as $$
begin execute q; return 'ok';
exception when others then return sqlstate; end $$;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'rp-' || n || '@sis.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['ava','ben','cyd','dan','bot']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'rp-%@sis.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select sid(n), u(n), now(), now() from unnest(array['ava','ben','cyd','dan','bot']) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
  values ('d1000000-0000-0000-0000-00000000a5a5', u('ava'), now(), now()); -- ava's other session
insert into app_private.tag_finds(finder, found_id) values
  (u('ava'), u('ben')), (u('ava'), u('cyd')), (u('ava'), u('dan'));
insert into public.conversations(id, title) values ('d10c0000-0000-0000-0000-00000000dbdb', 'rp debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
  values (u('bot'), 'd10c0000-0000-0000-0000-00000000dbdb', true);

create table public.rp_ids(name text primary key, id uuid);
grant select, insert on public.rp_ids to authenticated, anon, service_role;
create function g(n text) returns uuid language sql stable as $$ select id from public.rp_ids where name = n $$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), as_(text), try(text), g(text)
  to authenticated, anon, service_role;

do $$
declare n text;
begin
  foreach n in array array['ava','ben','cyd','dan','bot'] loop
    perform as_(n);
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    if n in ('ava', 'dan') then
      perform public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n),
                                      array[k(n || '1'), k(n || '2')], k(n || '-F'));
    end if;
    execute 'reset role';
  end loop;
end $$;

select as_('ava');
insert into public.rp_ids values
  ('G', public.start_group_conversation('rp-group', array[u('ben'), u('cyd')])),
  ('D', public.start_direct_conversation(u('ben'))),
  ('P', public.start_direct_conversation(u('dan')));
reset role;

-- 1 register_device_token: one function, four arguments ---------------------
select has_column('app_private', 'device_tokens', 'reaction_push', 'device_tokens says whether the device draws reaction pushes');
insert into app_private.device_tokens(user_id, token, platform) values (u('cyd'), 'rp-legacy-row', 'android');
select is((select reaction_push from app_private.device_tokens where token = 'rp-legacy-row'), false,
          'a row that never mentions reaction_push is an older build: false, not null');
delete from app_private.device_tokens where token = 'rp-legacy-row';
select is((select count(*) from pg_proc where proname = 'register_device_token' and pronamespace = 'public'::regnamespace),
          1::bigint, 'exactly one register_device_token: an older call has one place to land');
select has_function('public', 'register_device_token', array['text', 'text', 'boolean', 'boolean'],
                    'register_device_token(text, text, boolean, boolean)');
select hasnt_function('public', 'register_device_token', array['text', 'text', 'boolean'],
                      'the three-argument overload is gone (it would make an old call ambiguous)');
select is((select proargnames::text from pg_proc where proname = 'register_device_token' and pronamespace = 'public'::regnamespace),
          '{device_token,device_platform,shows_itself,reaction_push}', 'parameter names, as PostgREST calls them');
select function_privs_are('public', 'register_device_token', array['text', 'text', 'boolean', 'boolean'],
                          'anon', '{}'::text[], 'anon cannot register');
select function_privs_are('public', 'register_device_token', array['text', 'text', 'boolean', 'boolean'],
                          'authenticated', '{EXECUTE}'::text[], 'authenticated may register');

select as_('ben');
select is(try($$select public.register_device_token('rp-tok-ben', 'android', true, true)$$), 'ok', 'ben registers with reaction_push');
reset role;
select is((select reaction_push::text || shows_itself::text from app_private.device_tokens where token = 'rp-tok-ben'),
          'truetrue', 'reaction_push true is stored');
select as_('ben');
select is(try($$select public.register_device_token('rp-tok-ben', 'android', true)$$), 'ok',
          'an old three-argument positional call still resolves');
reset role;
select is((select reaction_push::text || shows_itself::text from app_private.device_tokens where token = 'rp-tok-ben'),
          'falsetrue', 'and it stores reaction_push false (an older build back on the phone)');
select as_('ben');
select is(try($$select public.register_device_token(device_token => 'rp-tok-ben', device_platform => 'android', shows_itself => true)$$),
          'ok', 'the old by-name call still resolves');
reset role;
select is((select reaction_push from app_private.device_tokens where token = 'rp-tok-ben'), false, 'by name: false');
select as_('ben');
select is(try($$select public.register_device_token(device_token => 'rp-tok-ben', device_platform => 'android',
                                                     shows_itself => true, reaction_push => true)$$),
          'ok', 'the new build calls by name with reaction_push');
reset role;
select is((select reaction_push from app_private.device_tokens where token = 'rp-tok-ben'), true, 'by name: true');
select as_('bot');
select is(try($$select public.register_device_token('rp-tok-bot', 'android', true, true)$$), '42501', 'a bot is refused (four arguments)');
select is(try($$select public.register_device_token('rp-tok-bot', 'android', true)$$), '42501', 'a bot is refused (three arguments)');
reset role;
select is((select count(*) from app_private.device_tokens where user_id = u('bot')), 0::bigint, 'no bot device row');
set local role anon;
select is(try($$select public.register_device_token('rp-tok-anon', 'android', true, true)$$), '42501', 'anon is refused');
reset role;

do $$
declare n text;
begin
  foreach n in array array['ava','cyd','dan'] loop
    perform as_(n);
    perform public.register_device_token('rp-tok-' || n, 'android', true, true);
    execute 'reset role';
  end loop;
end $$;

-- 2 nothing new is reachable by a client (AC-8) ------------------------------
select function_privs_are('app_private', 'notify_reaction', array['uuid', 'uuid'], 'anon', '{}'::text[], 'anon: no notify_reaction');
select function_privs_are('app_private', 'notify_reaction', array['uuid', 'uuid'], 'authenticated', '{}'::text[], 'authenticated: no notify_reaction');
select function_privs_are('app_private', 'reaction_push_targets_for', array['uuid', 'uuid'], 'anon', '{}'::text[], 'anon: no reaction_push_targets_for');
select function_privs_are('app_private', 'reaction_push_targets_for', array['uuid', 'uuid'], 'authenticated', '{}'::text[], 'authenticated: no reaction_push_targets_for');
select function_privs_are('public', 'reaction_push_targets', array['uuid', 'uuid'], 'anon', '{}'::text[], 'anon: no reaction_push_targets');
select function_privs_are('public', 'reaction_push_targets', array['uuid', 'uuid'], 'authenticated', '{}'::text[], 'authenticated: no reaction_push_targets');
select function_privs_are('public', 'reaction_push_targets', array['uuid', 'uuid'], 'service_role', '{EXECUTE}'::text[], 'service_role may claim');
select is((select count(*) from unnest(array['app_private.notify_reaction(uuid,uuid)', 'app_private.reaction_push_targets_for(uuid,uuid)',
                                             'public.reaction_push_targets(uuid,uuid)']) f
            where has_function_privilege('public', f, 'execute')),
          0::bigint, 'PUBLIC holds execute on none of the three');
select table_privs_are('app_private', 'reaction_push_log', 'anon', '{}'::text[], 'anon: no privilege on reaction_push_log');
select table_privs_are('app_private', 'reaction_push_log', 'authenticated', '{}'::text[], 'authenticated: no privilege on reaction_push_log');
select is((select relrowsecurity from pg_class where oid = 'app_private.reaction_push_log'::regclass), true, 'reaction_push_log: RLS on');
select is((select count(*) from pg_policies where schemaname = 'app_private' and tablename = 'reaction_push_log'), 0::bigint, 'and no policy');
select as_('ben');
select is(try($$select 1 from app_private.reaction_push_log$$), '42501', 'a member cannot select the log');
select is(try(format($$select * from public.reaction_push_targets(%L, %L)$$, mid('x'), u('ben'))), '42501', 'a member cannot claim');
select is(try(format($$select * from app_private.reaction_push_targets_for(%L, %L)$$, mid('x'), u('ben'))), '42501', 'a member cannot list targets');
select is(try(format($$select app_private.notify_reaction(%L, %L)$$, mid('x'), u('ben'))), '42501', 'a member cannot post a reaction push');
reset role;
set local role anon;
select is(try(format($$select * from public.reaction_push_targets(%L, %L)$$, mid('x'), u('ben'))), '42501', 'anon cannot claim');
select is(try(format($$select app_private.notify_reaction(%L, %L)$$, mid('x'), u('ben'))), '42501', 'anon cannot post a reaction push');
select is(try($$select 1 from app_private.reaction_push_log$$), '42501', 'anon cannot select the log');
reset role;
-- 3 who gets a row (AC-1, AC-3, AC-4; R1-R10) ---------------------------------
-- Messages and reactions are written as the superuser: these tests are about
-- the list, not the RPCs (section 5 drives the RPCs).
insert into public.messages(id, conversation_id, sender_id, body) values
  (mid('G1'), g('G'), u('ava'), 'hello group'),
  (mid('D1'), g('D'), u('ava'), 'hello ben'),
  (mid('P1'), g('P'), u('ava'), 'hello dan');
create function react(m uuid, who text, e text, x text default null, t int default null) returns void language sql as $$
  insert into public.message_reactions(message_id, user_id, conversation_id, emoji, ciphertext, olm_type)
  select m, u(who), conversation_id, e, x, t::smallint from public.messages where id = m
  on conflict (message_id, user_id) do update
    set emoji = excluded.emoji, ciphertext = excluded.ciphertext, olm_type = excluded.olm_type, updated_at = now()
$$;
create function n(m uuid, who text) returns bigint language sql as $$
  select count(*) from app_private.reaction_push_targets_for(m, u(who))
$$;
-- what ava's row says: title|sender|chat|emoji|quote|quote_kind|ct|ot|encrypted ('-' = null)
create function shown(m uuid, who text) returns text language sql as $$
  select string_agg(concat_ws('|', coalesce(title, '-'), coalesce(sender, '-'), coalesce(chat, '-'), coalesce(emoji, '-'),
                              coalesce(quote, '-'), coalesce(quote_kind, '-'), coalesce(ciphertext, '-'),
                              coalesce(olm_type::text, '-'), encrypted::text), ' / ')
    from app_private.reaction_push_targets_for(m, u(who))
$$;

select is(n(mid('G1'), 'ben'), 0::bigint, 'R1: no reaction row, no target');
select react(mid('G1'), 'ben', null);
select is(n(mid('G1'), 'ben'), 0::bigint, 'R1: a cleared reaction (no emoji, no ciphertext): no target');
select react(mid('G1'), 'ben', '👍');
select is((select string_agg(user_id::text || ':' || token || ':' || platform || ':' || conversation_id::text, ',')
             from app_private.reaction_push_targets_for(mid('G1'), u('ben'))),
          u('ava')::text || ':rp-tok-ava:android:' || g('G')::text,
          'AC-1: ben reacts to ava''s message: exactly one row, ava''s current device, in that chat (not ben, not cyd)');
select is((select string_agg(body, ',') from app_private.reaction_push_targets_for(mid('G1'), u('ben'))),
          'New reaction to your message', 'the body is always the generic English line');
select react(mid('G1'), 'ava', '🎉');
select is(n(mid('G1'), 'ava'), 0::bigint, 'R3: ava reacting to her own message gets no row');
select react(mid('G1'), 'cyd', '🎉');
select is((select string_agg(user_id::text, ',') from app_private.reaction_push_targets_for(mid('G1'), u('cyd'))),
          u('ava')::text, 'a second reactor: again only the sender');
select is(n(mid('G1'), 'dan'), 0::bigint, 'a user who never reacted to it gets nobody a row');

-- Each refusal is undone at once, and the row comes back (the twin).
create function gate(label text, make text, undo text) returns setof text language plpgsql as $$
begin
  execute make;
  return next is(n(mid('G1'), 'ben'), 0::bigint, label || ': no row');
  execute undo;
  return next is(n(mid('G1'), 'ben'), 1::bigint, label || ' undone: the row is back');
end $$;
select gate('R9 ava muted the chat',
  format($$insert into public.notification_mutes(user_id, kind, target) values (%L, 'conversation', %L)$$, u('ava'), g('G')),
  $$delete from public.notification_mutes$$);
select gate('R9 ava muted the chat until later',
  format($$insert into public.notification_mutes(user_id, kind, target, until) values (%L, 'conversation', %L, now() + interval '1 hour')$$, u('ava'), g('G')),
  $$delete from public.notification_mutes$$);
select gate('R9 ava muted ben (person)',
  format($$insert into public.notification_mutes(user_id, kind, target) values (%L, 'person', %L)$$, u('ava'), u('ben')),
  $$delete from public.notification_mutes$$);
insert into public.notification_mutes(user_id, kind, target, until) values (u('ava'), 'conversation', g('G'), now() - interval '1 minute');
insert into public.notification_mutes(user_id, kind, target) values (u('ava'), 'person', u('cyd'));
insert into public.notification_mutes(user_id, kind, target) values (u('ben'), 'conversation', g('G'));
select is(n(mid('G1'), 'ben'), 1::bigint, 'R9: an expired chat mute, a mute of another person, or the reactor''s own mute do not stop it');
delete from public.notification_mutes;
select gate('R8 ava archived the chat',
  format($$insert into public.chat_archives(user_id, conversation_id) values (%L, %L)$$, u('ava'), g('G')),
  $$delete from public.chat_archives$$);
insert into public.chat_archives(user_id, conversation_id) values (u('ben'), g('G'));
select is(n(mid('G1'), 'ben'), 1::bigint, 'R8: the reactor archiving the chat does not stop it');
delete from public.chat_archives;
select gate('R7 ava turned notifications off',
  format($$insert into public.notification_settings(user_id, enabled) values (%L, false)$$, u('ava')),
  $$delete from public.notification_settings$$);
select gate('R4 ava left the group',
  format($$update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = %L and user_id = %L$$, g('G'), u('ava')),
  format($$update public.conversation_members set left_at = null, left_reason = null where conversation_id = %L and user_id = %L$$, g('G'), u('ava')));
select gate('R4 ben left the group',
  format($$update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = %L and user_id = %L$$, g('G'), u('ben')),
  format($$update public.conversation_members set left_at = null, left_reason = null where conversation_id = %L and user_id = %L$$, g('G'), u('ben')));
select gate('R2 the message is deleted',
  format($$update public.messages set deleted = 'placeholder', deleted_at = now(), body = '' where id = %L$$, mid('G1')),
  format($$update public.messages set deleted = null, deleted_at = null, body = 'hello group' where id = %L$$, mid('G1')));
select gate('R6 ben is not allowed',
  $$delete from app_private.allowlist where email = 'rp-ben@sis.test'$$,
  $$insert into app_private.allowlist(email) values ('rp-ben@sis.test')$$);
select gate('R6 ava is not allowed',
  $$delete from app_private.allowlist where email = 'rp-ava@sis.test'$$,
  $$insert into app_private.allowlist(email) values ('rp-ava@sis.test')$$);
select gate('R6 ben is a bot',
  format($$insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (%L, 'd10c0000-0000-0000-0000-00000000dbdb', true)$$, u('ben')),
  format($$delete from app_private.bot_accounts where user_id = %L$$, u('ben')));
select gate('R6 ben is a disabled bot',
  format($$insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (%L, 'd10c0000-0000-0000-0000-00000000dbdb', false)$$, u('ben')),
  format($$delete from app_private.bot_accounts where user_id = %L$$, u('ben')));
select gate('R10 a system chat',
  format($$update public.conversations set system = true where id = %L$$, g('G')),
  format($$update public.conversations set system = false where id = %L$$, g('G')));
select gate('R5 ava''s device does not draw reactions (AC-4)',
  format($$update app_private.device_tokens set reaction_push = false where user_id = %L$$, u('ava')),
  format($$update app_private.device_tokens set reaction_push = true where user_id = %L$$, u('ava')));
select gate('R5 ava''s token belongs to a session that is no longer the active one (AC-4)',
  format($$update app_private.active_sessions set session_id = 'd1000000-0000-0000-0000-00000000a5a5' where user_id = %L$$, u('ava')),
  format($$update app_private.active_sessions set session_id = %L where user_id = %L$$, sid('ava'), u('ava')));
select gate('R5 ava has no device',
  format($$delete from app_private.device_tokens where user_id = %L$$, u('ava')),
  format($$insert into app_private.device_tokens(user_id, token, platform, shows_itself, session_id, reaction_push)
           values (%L, 'rp-tok-ava', 'android', true, %L, true)$$, u('ava'), sid('ava')));
-- The reactor's own device state is irrelevant: ben without reaction_push still notifies ava.
update app_private.device_tokens set reaction_push = false where user_id = u('ben');
select is(n(mid('G1'), 'ben'), 1::bigint, 'R5 is about the recipient''s device, not the reactor''s');
update app_private.device_tokens set reaction_push = true where user_id = u('ben');

-- bot reactor (manager decision): a real bot account reacting gets no row.
insert into app_private.tag_finds(finder, found_id) values (u('ava'), u('bot'));
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('ava'));
select as_('ava');
insert into public.rp_ids values ('T', public.start_direct_conversation(u('bot')));
reset role;
insert into public.messages(id, conversation_id, sender_id, body) values (mid('T1'), g('T'), u('ava'), 'hello bot');
select react(mid('T1'), 'bot', '👍');
select is(n(mid('T1'), 'bot'), 0::bigint, 'R6: a bot''s reaction in its own 1:1 with ava never notifies');
-- 4 what the row says (AC-5, AC-6; R11, R12) ---------------------------------
create function preview(p text) returns void language sql as $$
  insert into public.notification_settings(user_id, preview) values (u('ava'), p)
  on conflict (user_id) do update set preview = excluded.preview
$$;
select is(shown(mid('G1'), 'ben'), 'Ben @ rp-group|Ben|rp-group|👍|hello group|-|-|-|false',
          'AC-5 group, preview unset (= full): reactor @ chat, sender, chat, emoji, quote; nothing locked');
select preview('full');
select is(shown(mid('G1'), 'ben'), 'Ben @ rp-group|Ben|rp-group|👍|hello group|-|-|-|false', 'AC-5 group, full');
select preview('sender');
select is(shown(mid('G1'), 'ben'), 'Ben|Ben|rp-group|-|-|-|-|-|false', 'AC-5 group, sender: who (the name alone, as message pushes), never what');
select preview('none');
select is(shown(mid('G1'), 'ben'), 'SIS|-|-|-|-|-|-|-|false', 'AC-5 group, none: SIS and nothing else');
delete from public.notification_settings;
select react(mid('D1'), 'ben', '❤️');
select is((select title || '|' || coalesce(chat, '-') || '|' || coalesce(emoji, '-') || '|' || coalesce(quote, '-')
             from app_private.reaction_push_targets_for(mid('D1'), u('ben'))),
          'Ben|-|❤️|hello ben', 'AC-5 1:1, full: the reactor''s name alone, no chat name');
select preview('none');
select is((select title || '|' || coalesce(sender, '-') || '|' || coalesce(chat, '-') || '|' || coalesce(emoji, '-')
             from app_private.reaction_push_targets_for(mid('D1'), u('ben'))),
          'SIS|-|-|-', 'AC-5 1:1, none');
delete from public.notification_settings;
create temp table _ben_profile as select * from public.profiles where user_id = u('ben');
delete from public.profiles where user_id = u('ben');
select is((select title from app_private.reaction_push_targets_for(mid('G1'), u('ben'))),
          'Someone @ rp-group', 'a reactor without a display name is ''Someone''');
insert into public.profiles select * from _ben_profile;

-- the quote: btrim, cut at 60 characters + '…', null when the body is empty
insert into public.messages(id, conversation_id, sender_id, body) values
  (mid('Q61'), g('G'), u('ava'), repeat('x', 59) || 'yz'),
  (mid('Q60'), g('G'), u('ava'), repeat('x', 59) || 'y'),
  (mid('Q61u'), g('G'), u('ava'), repeat('ğ', 61)),
  (mid('Q60u'), g('G'), u('ava'), repeat('ğ', 60)),
  (mid('Qpad'), g('G'), u('ava'), '  padded words  ');
insert into public.messages(id, conversation_id, sender_id, body, attachment_path) values
  (mid('Mphoto'), g('G'), u('ava'), '', 'rp/photo.jpg');
insert into public.messages(id, conversation_id, sender_id, body, attachment_path, attachment_name, attachment_mime, attachment_size, attachment_duration_ms) values
  (mid('Mfile'), g('G'), u('ava'), '', 'rp/a.pdf', 'a.pdf', 'application/pdf', 10, null),
  (mid('Mvideo'), g('G'), u('ava'), '', 'rp/v.mp4', 'v.mp4', 'video/mp4', 10, 1000),
  (mid('Mvoice'), g('G'), u('ava'), '', 'rp/v.m4a', 'v.m4a', 'audio/mp4', 10, 1000);
set local session_replication_role = replica; -- a sticker row without building a sticker pack
insert into public.messages(id, conversation_id, sender_id, body, sticker_id) values
  (mid('Msticker'), g('G'), u('ava'), '', gen_random_uuid());
set local session_replication_role = origin;
select react(m, 'ben', '👍') from unnest(array[mid('Q61'), mid('Q60'), mid('Q61u'), mid('Q60u'), mid('Qpad'), mid('Mphoto'), mid('Mfile'),
                                             mid('Mvideo'), mid('Mvoice'), mid('Msticker')]) m;
select is((select quote from app_private.reaction_push_targets_for(mid('Q61'), u('ben'))), repeat('x', 59) || 'y…',
          '61 characters: cut to 60 plus …');
select is((select quote from app_private.reaction_push_targets_for(mid('Q60'), u('ben'))), repeat('x', 59) || 'y',
          '60 characters: whole, no …');
select is((select quote from app_private.reaction_push_targets_for(mid('Q61u'), u('ben'))), repeat('ğ', 60) || '…',
          'the cut counts characters, not bytes');
select is((select quote from app_private.reaction_push_targets_for(mid('Q60u'), u('ben'))), repeat('ğ', 60),
          '60 two-byte characters (120 bytes): whole, no …');
select is((select quote from app_private.reaction_push_targets_for(mid('Qpad'), u('ben'))), 'padded words', 'the quote is trimmed');
select is((select coalesce(quote, '-') || '|' || coalesce(quote_kind, '-') from app_private.reaction_push_targets_for(mid('Mphoto'), u('ben'))),
          '-|photo', 'a photo: no quote, kind photo');
select is((select coalesce(quote, '-') || '|' || coalesce(quote_kind, '-') from app_private.reaction_push_targets_for(mid('Mfile'), u('ben'))),
          '-|file', 'a file: kind file');
select is((select coalesce(quote, '-') || '|' || coalesce(quote_kind, '-') from app_private.reaction_push_targets_for(mid('Mvideo'), u('ben'))),
          '-|video', 'a video: kind video');
select is((select coalesce(quote, '-') || '|' || coalesce(quote_kind, '-') from app_private.reaction_push_targets_for(mid('Mvoice'), u('ben'))),
          '-|voice', 'a voice message: kind voice');
select is((select coalesce(quote, '-') || '|' || coalesce(quote_kind, '-') from app_private.reaction_push_targets_for(mid('Msticker'), u('ben'))),
          '-|sticker', 'a sticker: kind sticker');
select is((select coalesce(quote_kind, '-') from app_private.reaction_push_targets_for(mid('G1'), u('ben'))), '-', 'a text: no kind');
select preview('sender');
select is((select count(*) from unnest(array[mid('Mphoto'), mid('Mvoice'), mid('Msticker'), mid('Q61')]) m,
                  app_private.reaction_push_targets_for(m, u('ben')) t
            where emoji is not null or quote is not null or quote_kind is not null),
          0::bigint, 'preview sender: no emoji, quote or kind for any message type');
delete from public.notification_settings;

-- R12: a private chat never gets emoji, quote or quote_kind, for any preview.
-- Three separate causes in ava's 1:1 with ben; each is checked alone, with a
-- twin that differs only by that cause.
insert into public.messages(id, conversation_id, sender_id, body, attachment_path) values
  (mid('D2'), g('D'), u('ava'), '', 'rp/d2.jpg');
set local session_replication_role = replica; -- an encrypted row in a chat not (yet) marked: a shape the guard refuses
insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type) values
  (mid('D3'), g('D'), u('ava'), '🔒 Encrypted message', 'Q1RtZXNzYWdl', 1);
set local session_replication_role = origin;
-- leaks across previews full, sender, none: rows that carry emoji, quote or kind / all rows
create function leaks(ms uuid[]) returns text language plpgsql as $$
declare p text; bad bigint := 0; total bigint := 0;
begin
  foreach p in array array['full', 'sender', 'none'] loop
    perform preview(p);
    bad := bad + (select count(*) from unnest(ms) m, app_private.reaction_push_targets_for(m, u('ben')) t
                   where t.emoji is not null or t.quote is not null or t.quote_kind is not null);
    total := total + (select count(*) from unnest(ms) m, app_private.reaction_push_targets_for(m, u('ben')));
  end loop;
  delete from public.notification_settings;
  return bad || ' of ' || total;
end $$;

-- twin first: the plain 1:1 shows emoji, quote and kind under full
select react(mid('D1'), 'ben', '👍');
select react(mid('D2'), 'ben', '👍');
select is(shown(mid('D1'), 'ben') || ' / ' || shown(mid('D2'), 'ben'),
          'Ben|Ben|-|👍|hello ben|-|-|-|false / Ben|Ben|-|👍|-|photo|-|-|false',
          'twin: the plain 1:1 with a plain reaction shows emoji, quote and kind');
-- cause 1: the reaction is a ciphertext (chat not marked, message plain)
select react(mid('D1'), 'ben', null, 'Q1RyZWFjdGlvbg', 1);
select react(mid('D2'), 'ben', null, 'Q1RyZWFjdGlvbg', 0);
select is(leaks(array[mid('D1'), mid('D2')]), '0 of 6', 'R12 a locked reaction: no emoji, quote or kind, for every preview');
select is(shown(mid('D1'), 'ben') || ' / ' || shown(mid('D2'), 'ben'),
          'Ben|Ben|-|-|-|-|Q1RyZWFjdGlvbg|1|true / Ben|Ben|-|-|-|-|Q1RyZWFjdGlvbg|0|true',
          'a locked reaction, full: ct and ot travel instead, marked encrypted');
select preview('sender');
select is((select count(*) from app_private.reaction_push_targets_for(mid('D1'), u('ben')) where ciphertext is null and olm_type is null and encrypted),
          1::bigint, 'a locked reaction, sender: no ct/ot, still encrypted');
select preview('none');
select is((select count(*) from app_private.reaction_push_targets_for(mid('D1'), u('ben')) where ciphertext is null and olm_type is null and encrypted),
          1::bigint, 'a locked reaction, none: no ct/ot, still encrypted');
delete from public.notification_settings;
-- cause 2: the message is a ciphertext (plain reaction, chat not marked)
select react(mid('D3'), 'ben', '👍');
select is(leaks(array[mid('D3')]), '0 of 3', 'R12 an encrypted message: no emoji, quote or kind, for every preview');
select is((select coalesce(ciphertext, '-') from app_private.reaction_push_targets_for(mid('D3'), u('ben'))), '-',
          'the message''s ciphertext is never sent as the reaction''s');
-- cause 3: the chat is marked encrypted (plain message, plain reaction)
select react(mid('D1'), 'ben', '👍');
select react(mid('D2'), 'ben', '👍');
update public.conversations set encrypted_at = now() where id = g('D');
select is(leaks(array[mid('D1'), mid('D2')]), '0 of 6', 'R12 a chat with encrypted_at: no emoji, quote or kind, for every preview');
select is((select string_agg(encrypted::text || coalesce(ciphertext, '-'), ',') from app_private.reaction_push_targets_for(mid('D1'), u('ben'))),
          'true-', 'a marked chat: encrypted, but no ct (the reaction has none)');
update public.conversations set encrypted_at = null where id = g('D');
select is(leaks(array[mid('D1'), mid('D2')]), '2 of 6', 'twin: the same rows unmarked leak under full only (2 of 6)');
-- 5 when a push is asked for (AC-2): the RPCs, as members ---------------------
insert into public.messages(id, conversation_id, sender_id, body) values (mid('N1'), g('G'), u('ava'), 'notify me');
create function rq() returns bigint language sql as $$
  select count(*) from net.http_request_queue where convert_from(body, 'UTF8')::jsonb ? 'reaction'
$$;
create function emoji_of(m uuid, who text) returns text language sql security definer as $$
  select coalesce(emoji, ciphertext, '-') from public.message_reactions where message_id = m and user_id = u(who)
$$;
grant execute on function rq(), emoji_of(uuid, text) to authenticated;
select is((select count(*) from vault.secrets where name in ('notify_on_message_url')), 0::bigint, 'fixture: no notify URL yet');
select as_('ben');
select is(try(format($$select public.set_reaction(%L, '😀')$$, mid('N1'))), 'ok', 'no URL configured: set_reaction still succeeds');
reset role;
select is(rq(), 0::bigint, 'and nothing is queued (silent)');
select is(emoji_of(mid('N1'), 'ben'), '😀', 'the reaction is stored');

select isnt(vault.create_secret('https://rp-test.local/hook', 'notify_on_message_url'), null, 'a notify URL is configured');
select as_('ben');
select is(try(format($$select public.set_reaction(%L, '🎉')$$, mid('N1'))), 'ok', 'ben changes his reaction');
reset role;
select is(rq(), 1::bigint, 'a changed emoji queues one call');
select is((select string_agg(method || ' ' || url || ' ' || (convert_from(body, 'UTF8')::jsonb)::text, ',')
             from net.http_request_queue where convert_from(body, 'UTF8')::jsonb ? 'reaction'),
          'POST https://rp-test.local/hook ' || jsonb_build_object('reaction',
            jsonb_build_object('message_id', mid('N1'), 'user_id', u('ben')))::text,
          'POST to the vault URL with ids only: {"reaction":{"message_id","user_id"}}');
select as_('ben');
select is(try(format($$select public.set_reaction(%L, '🎉')$$, mid('N1'))), 'ok', 'the same emoji again (a retry)');
reset role;
select is(rq(), 1::bigint, 'the same emoji twice: still one call');
select as_('ben');
select is(try(format($$select public.set_reaction(%L, '👍')$$, mid('N1'))), 'ok', 'another emoji');
reset role;
select is(rq(), 2::bigint, 'a different emoji: one more call');
select as_('ben');
select is(try(format($$select public.set_reaction(%L, null)$$, mid('N1'))), 'ok', 'ben clears his reaction');
reset role;
select is(rq(), 2::bigint, 'a clear queues nothing');
select as_('ben');
select is(try(format($$select public.set_reaction(%L, null)$$, mid('N1'))), 'ok', 'and clears again');
select is(try(format($$select public.set_reaction(%L, '👍')$$, mid('N1'))), 'ok', 'then sets 👍 again after the clear');
reset role;
select is(rq(), 3::bigint, 'set after a clear is a change: one more call');
select as_('ben');
select is(try(format($q$do $x$ begin perform public.set_reaction(%L, '😎'); raise exception 'rp rollback'; end $x$$q$, mid('N1'))),
          'P0001', 'a set_reaction whose transaction fails');
reset role;
select is(rq(), 3::bigint, 'a rolled-back set_reaction queues nothing');
select is(emoji_of(mid('N1'), 'ben'), '👍', 'and changed nothing');
update public.message_reactions set emoji = '🔥', updated_at = now() where message_id = mid('N1') and user_id = u('ben');
select is(rq(), 3::bigint, 'a bulk update outside the RPCs queues nothing');

-- the private chat: dan reacts to ava's message there
select as_('dan');
select is(try(format($$select public.set_reaction(%L, '👍')$$, mid('P1'))), 'ok', 'dan sets a plain emoji in P (not locked yet)');
reset role;
select is(rq(), 4::bigint, 'one call');
select as_('dan');
select is(try(format($$select public.relock_reaction(%L, 'Q1RhYWE', 1::smallint)$$, mid('P1'))), 'ok', 'dan relocks it');
reset role;
select is(emoji_of(mid('P1'), 'dan'), 'Q1RhYWE', 'fixture: the reaction is now the ciphertext');
select is(rq(), 4::bigint, 'relock_reaction queues nothing');
select as_('dan');
select is(try(format($$select public.set_reaction_encrypted(%L, 'Q1RhYWE', 1::smallint)$$, mid('P1'))), 'ok',
          'set_reaction_encrypted with the same bytes (a network retry)');
reset role;
select is(rq(), 4::bigint, 'the same ciphertext: nothing');
select as_('dan');
select is(try(format($$select public.set_reaction_encrypted(%L, 'Q1RiYmI', 1::smallint)$$, mid('P1'))), 'ok', 'a new locked reaction');
reset role;
select is(rq(), 5::bigint, 'a new ciphertext: one call');
select is((select count(*) from net.http_request_queue where convert_from(body, 'UTF8')::jsonb =
             jsonb_build_object('reaction', jsonb_build_object('message_id', mid('P1'), 'user_id', u('dan')))),
          2::bigint, 'with dan''s and the message''s ids (the plain set and this one)');
select as_('dan');
select is(try(format($$select public.set_reaction_encrypted(%L, 'Q1RiYmI', 1::smallint)$$, mid('P1'))), 'ok', 'the same again');
reset role;
select is(rq(), 5::bigint, 'nothing');
select as_('dan');
select is(try(format($$select public.set_reaction(%L, null)$$, mid('P1'))), 'ok', 'dan clears it');
reset role;
select is(rq(), 5::bigint, 'a clear of a locked reaction: nothing');
select as_('dan');
select is(try(format($$select public.set_reaction_encrypted(%L, 'Q1RiYmI', 1::smallint)$$, mid('P1'))), 'ok', 'and locks the same bytes again after the clear');
select is(try(format($q$do $x$ begin perform public.set_reaction_encrypted(%L, 'Q1RjY2M', 1::smallint); raise exception 'rp rollback'; end $x$$q$, mid('P1'))),
          'P0001', 'a set_reaction_encrypted whose transaction fails');
reset role;
select is(rq(), 6::bigint, 'after a clear it is a change (one call); the rolled-back one queued nothing');
select is(shown(mid('P1'), 'dan'), 'Dan|Dan|-|-|-|-|Q1RiYmI|1|true',
          'AC-6 the real private chat, full: no emoji, quote or kind; ct and ot');

create temp table _q as select rq() as n;
select as_('ava');
select is(try(format($$select public.set_reaction(%L, '🎉')$$, mid('N1'))), 'ok', 'ava reacts to her own message');
reset role;
select is(rq(), (select n from _q), 'AC-2: reacting to your own message queues nothing');

-- a broken URL: the RPC still succeeds (notify never raises)
select vault.update_secret((select id from vault.secrets where name in ('notify_on_message_url')), 'not a url at all');
select as_('ben');
select is(try(format($$select public.set_reaction(%L, '🙂')$$, mid('N1'))), 'ok', 'a failing push call never fails the reaction');
reset role;
select is(emoji_of(mid('N1'), 'ben'), '🙂', 'and the reaction is stored');
select vault.update_secret((select id from vault.secrets where name in ('notify_on_message_url')), 'https://rp-test.local/hook');
-- 6 the claim: once, while it is news, within the limits (AC-7) ---------------
insert into public.messages(id, conversation_id, sender_id, body)
  select mid('C' || i), g('G'), u('ava'), 'claim ' || i from generate_series(1, 9) i;
insert into public.messages(id, conversation_id, sender_id, body) values (mid('F1'), g('G'), u('ava'), 'filler');
create function claim(m uuid, who text) returns bigint language plpgsql as $$
declare c bigint;
begin
  execute 'set local role service_role';
  select count(*) into c from public.reaction_push_targets(m, u(who));
  execute 'reset role';
  return c;
end $$;
grant execute on function claim(uuid, text) to service_role;
-- n log rows (message, reactor, recipient), sent [ago] before now, each with its own (random, past) reacted_at
create function seed(m uuid, reactor text, recipient text, n int, ago interval) returns void language sql as $$
  insert into app_private.reaction_push_log(message_id, reactor_id, recipient_id, reacted_at, sent_at)
  select m, u(reactor), u(recipient), now() - interval '1 day' - random() * interval '300 days', now() - ago
    from generate_series(1, n) i
$$;
create function logged(m uuid) returns bigint language sql as $$
  select count(*) from app_private.reaction_push_log where message_id = m
$$;
delete from app_private.reaction_push_log;

select react(mid('C1'), 'ben', '👍');
select is(claim(mid('C1'), 'ben'), 1::bigint, 'AC-7 the first claim returns ava''s row');
select is((select string_agg(recipient_id::text || ':' || (reacted_at = r.updated_at)::text, ',')
             from app_private.reaction_push_log l
             join public.message_reactions r on r.message_id = l.message_id and r.user_id = l.reactor_id
            where l.message_id = mid('C1') and l.reactor_id = u('ben')),
          u('ava')::text || ':true', 'it is logged once, for ava, at the reaction''s updated_at');
select is(claim(mid('C1'), 'ben'), 0::bigint, 'AC-7 the second claim of the same change returns nothing');
select is(logged(mid('C1')), 1::bigint, 'and logs nothing more');
update public.message_reactions set updated_at = now() - interval '10 seconds' where message_id = mid('C1') and user_id = u('ben');
select is(claim(mid('C1'), 'ben'), 1::bigint, 'a later change of the same reaction is news again');

-- the 2-minute window
select react(mid('C2'), 'ben', '👍');
update public.message_reactions set updated_at = now() - interval '2 minutes 1 second' where message_id = mid('C2') and user_id = u('ben');
select is(claim(mid('C2'), 'ben'), 0::bigint, 'a reaction changed 2 min 1 s ago: nothing');
update public.message_reactions set updated_at = now() - interval '2 minutes' where message_id = mid('C2') and user_id = u('ben');
select is(claim(mid('C2'), 'ben'), 0::bigint, 'exactly 2 min ago: nothing (only while newer)');
select is(logged(mid('C2')), 0::bigint, 'an old reaction is not logged');
update public.message_reactions set updated_at = now() - interval '1 minute 59 seconds' where message_id = mid('C2') and user_id = u('ben');
select is(claim(mid('C2'), 'ben'), 1::bigint, '1 min 59 s ago: claimed');

-- L1: fewer than 3 per (message, reactor) in 10 minutes
delete from app_private.reaction_push_log;
select react(mid('C3'), 'ben', '👍');
select seed(mid('C3'), 'ben', 'ava', 2, interval '5 minutes');
select seed(mid('C3'), 'ben', 'ava', 1, interval '11 minutes');
select seed(mid('C3'), 'cyd', 'ava', 3, interval '1 minute');   -- another reactor, same message
select is(claim(mid('C3'), 'ben'), 1::bigint, 'L1: 2 sends in 10 min (a third 11 min ago, cyd''s do not count): the 3rd is claimed');
update public.message_reactions set updated_at = now() - interval '5 seconds' where message_id = mid('C3') and user_id = u('ben');
select is(claim(mid('C3'), 'ben'), 0::bigint, 'L1: the 4th change within 10 min: nothing');
select is((select count(*) from app_private.reaction_push_log where message_id = mid('C3') and reactor_id = u('ben')), 4::bigint,
          'a limited change is not logged');

-- L2: fewer than 10 per (reactor, recipient) in 10 minutes
delete from app_private.reaction_push_log;
select seed(mid('F1'), 'ben', 'ava', 9, interval '5 minutes');
select seed(mid('F1'), 'ben', 'cyd', 10, interval '5 minutes');  -- ben to someone else
select seed(mid('F1'), 'cyd', 'ava', 10, interval '5 minutes');  -- someone else to ava
select seed(mid('F1'), 'ben', 'ava', 5, interval '11 minutes');  -- outside the 10 minutes
select react(mid('C4'), 'ben', '👍');
select react(mid('C5'), 'ben', '👍');
select is(claim(mid('C4'), 'ben'), 1::bigint, 'L2: the 10th reaction ben->ava in 10 min is claimed (other pairs do not count)');
select is(claim(mid('C5'), 'ben'), 0::bigint, 'L2: the 11th within 10 min: nothing');
select is(logged(mid('C5')), 0::bigint, 'and it is not logged');

-- L2: fewer than 30 per (reactor, recipient) in 60 minutes
delete from app_private.reaction_push_log;
select seed(mid('F1'), 'ben', 'ava', 29, interval '30 minutes');
select seed(mid('F1'), 'ben', 'ava', 3, interval '61 minutes');
select seed(mid('F1'), 'ben', 'cyd', 30, interval '30 minutes');
select seed(mid('F1'), 'cyd', 'ava', 30, interval '30 minutes');
select react(mid('C6'), 'ben', '👍');
select react(mid('C7'), 'ben', '👍');
select is(claim(mid('C6'), 'ben'), 1::bigint, 'L2: the 30th reaction ben->ava within the hour is claimed (other pairs do not count)');
select is(claim(mid('C7'), 'ben'), 0::bigint, 'L2: the 31st within the hour: nothing');

-- housekeeping: rows older than 24 hours go
delete from app_private.reaction_push_log;
select seed(mid('F1'), 'ben', 'ava', 1, interval '25 hours');
select seed(mid('F1'), 'cyd', 'dan', 1, interval '25 hours');
select seed(mid('F1'), 'ben', 'ava', 1, interval '23 hours');
select react(mid('C8'), 'ben', '👍');
select is(claim(mid('C8'), 'ben'), 1::bigint, 'a claim');
select is((select string_agg(extract(epoch from now() - sent_at)::int / 3600 || 'h', ',') from app_private.reaction_push_log
            where message_id = mid('F1')),
          '23h', 'deletes every log row older than 24 h, and keeps the rest');

-- nothing to claim
select is(claim(mid('C9'), 'ben'), 0::bigint, 'no reaction: nothing');
select is(claim(mid('T1'), 'bot'), 0::bigint, 'a bot''s fresh reaction: nothing');
select react(mid('C9'), 'ava', '👍');
select is(claim(mid('C9'), 'ava'), 0::bigint, 'ava''s own reaction: nothing');
select react(mid('C9'), 'ben', null);
select is(claim(mid('C9'), 'ben'), 0::bigint, 'a fresh clear: nothing');
-- @@BODY@@
select * from finish();
rollback;
