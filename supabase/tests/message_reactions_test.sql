begin;
select plan(154);

-- Message reactions: public.set_reaction(message, emoji) and the read-only
-- public.message_reactions table.
--
-- Written from the contract, not from the migration:
--   set_reaction is security definer, EXECUTE for authenticated only. A null
--   emoji clears; a set is idempotent and never toggles. 42501 'not permitted'
--   for every refusal alike (no app access, message missing or deleted, not a
--   current member, message not readable: history window or hidden for me,
--   the system chat); then 22023 'invalid emoji' (empty, > 64 bytes,
--   whitespace or control characters); RLMT2 for the bot only, each set a
--   'send' in app_private.bot_actions sharing the message budget (20 / 10 min,
--   200 / 24 h), a clear not counted, a refusal not logged.
--   message_reactions(message_id, user_id, conversation_id, emoji, created_at,
--   updated_at), PK (message_id, user_id); NULL emoji = no reaction, a clear
--   is an UPDATE. Clients: SELECT on every column but created_at, nothing
--   else. Read: app access, member, message undeleted and readable.
--   Published to Realtime.
--
-- Each negative fixture fails ONE gate; a control passes the same call.
--   ann  admin of Debug and G2           bob  Debug and G2; positive control
--   cat  Debug, history starts 1 h ago, never in G2
--   dan  listed bot contact (bot 1:1)    eve  Debug, session revoked later
--   fay  G2, then leaves

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000000ec7' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@react.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve'),('06','fay')) v(n, name);
insert into app_private.allowlist(email)
select name || '@react.test' from unnest(array['ann','bob','cat','dan','eve','fay']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('ec700000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('01'), u('02')), (u('01'), u('03')), (u('01'), u('05')), (u('01'), u('06'));

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'sis-destek-bot@example.com', now(), '{"full_name":"SIS Destek"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then 'b07b0000-0000-0000-0000-000000000001'
                         else 'ec700000-0000-0000-0000-0000000000' || n end)::text, true);
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
create function leave_c(c uuid) returns void language plpgsql as $$
begin perform public.leave_group(c); perform commit_check(); end $$;
create function msg(c uuid, body text) returns uuid language sql as $$
  insert into public.messages(conversation_id, sender_id, body) values (c, auth.uid(), body) returning id
$$;
create function react(m uuid, e text) returns void language sql as $$
  select public.set_reaction(m, e)
$$;
-- reactions on a message as the current role sees them
create function seen(m uuid) returns text language sql as $$
  select coalesce(string_agg(user_id::text || '=' || coalesce(emoji, '-'), ',' order by user_id::text), '')
    from public.message_reactions where message_id = m
$$;
create function try(q text) returns text language plpgsql as $$
begin execute q; return 'ok';
exception when others then return sqlstate; end $$;
grant execute on function u(text), as_(text), commit_check(), group_c(text, uuid[]), leave_c(uuid),
  msg(uuid, text), react(uuid, text), seen(uuid), try(text) to authenticated, anon;

-- the truth, whatever RLS says (postgres only)
create function stored(m uuid, who text) returns text language sql as $$
  select coalesce(emoji, '-') from public.message_reactions where message_id = m and user_id = u(who)
$$;
create function rows_of(m uuid) returns bigint language sql as $$
  select count(*) from public.message_reactions where message_id = m
$$;
create function sends() returns bigint language sql as $$
  select count(*) from app_private.bot_actions where bot_id = u('bot') and kind = 'send'
$$;
create function backdate(n int, age interval) returns void language sql as $$
  delete from app_private.bot_actions where bot_id = u('bot') and kind = 'send';
  insert into app_private.bot_actions(bot_id, kind, at)
  select u('bot'), 'send', now() - age from generate_series(1, n);
$$;
-- the physical row version: a new ctid/xmin means an UPDATE wrote (and was published).
-- Every call runs in its own lives_ok subtransaction, so a write there gets a new xmin.
create function ver(m uuid, who text) returns text language sql as $$
  select ctid::text || '/' || xmin::text || '/' || updated_at::text
    from public.message_reactions where message_id = m and user_id = u(who)
$$;
create function age_row(m uuid, who text) returns void language sql as $$
  update public.message_reactions set updated_at = now() - interval '1 day' where message_id = m and user_id = u(who)
$$;
create function upd_at(m uuid, who text) returns timestamptz language sql as $$
  select updated_at from public.message_reactions where message_id = m and user_id = u(who)
$$;
create temp table snaps(name text primary key, v text);

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06'] loop
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
  ('DEBUG', group_c('Debug', array[u('02'), u('03'), u('05')])),
  ('G2', group_c('other group', array[u('02'), u('06')]));
insert into ids values
  ('M', msg(g('DEBUG'), 'react to me')),
  ('DEL', msg(g('DEBUG'), 'to be deleted')),
  ('HIDE', msg(g('DEBUG'), 'bob hides this')),
  ('G2M', msg(g('G2'), 'group two'));
select public.deliver_release_notes(179);
reset role;
insert into public.messages(conversation_id, sender_id, body, created_at)
values (g('DEBUG'), u('01'), 'old note', now() - interval '2 hours');
insert into ids select 'OLD', id from public.messages where body = 'old note' and conversation_id = g('DEBUG');
update public.conversation_members set history_from = now() - interval '1 hour'
 where conversation_id = g('DEBUG') and user_id = u('03');
insert into ids
select 'SYSM', m.id from public.messages m join public.conversations c on c.id = m.conversation_id
 where c.system and m.conversation_id in (select conversation_id from public.conversation_members where user_id = u('01'))
 limit 1;

-- 1 schema and grants -----------------------------------------------------------
select has_table('public', 'message_reactions', 'public.message_reactions exists');
select columns_are('public', 'message_reactions',
                   array['message_id', 'user_id', 'conversation_id', 'emoji', 'created_at', 'updated_at'],
                   'message_reactions has exactly the contract columns');
select col_is_pk('public', 'message_reactions', array['message_id', 'user_id'],
                 'the primary key is (message_id, user_id)');
select ok((select prosecdef from pg_proc where oid = 'public.set_reaction(uuid, text)'::regprocedure),
          'set_reaction is security definer');
select is((select prorettype::regtype::text from pg_proc where oid = 'public.set_reaction(uuid, text)'::regprocedure),
          'void', 'set_reaction returns void');
select function_privs_are('public', 'set_reaction', array['uuid', 'text'], 'authenticated', array['EXECUTE'],
                          'authenticated may execute set_reaction');
select function_privs_are('public', 'set_reaction', array['uuid', 'text'], 'anon', '{}'::text[],
                          'anon holds no execute on set_reaction');
select ok(not has_function_privilege('public', 'public.set_reaction(uuid, text)', 'execute'),
          'PUBLIC holds no execute on set_reaction');
select has_function('app_private', 'bot_send_charge', array['uuid'], 'app_private.bot_send_charge(uuid) exists');
select is((select prorettype::regtype::text from pg_proc where oid = 'app_private.bot_send_charge(uuid)'::regprocedure),
          'void', 'bot_send_charge returns void');
select ok((select prosecdef from pg_proc where oid = 'app_private.bot_send_charge(uuid)'::regprocedure),
          'bot_send_charge is security definer');
select ok(not has_function_privilege('public', 'app_private.bot_send_charge(uuid)', 'execute'),
          'PUBLIC holds no execute on bot_send_charge');
select ok(not has_function_privilege('anon', 'app_private.bot_send_charge(uuid)', 'execute'),
          'anon holds no execute on bot_send_charge');
select ok(not has_function_privilege('authenticated', 'app_private.bot_send_charge(uuid)', 'execute'),
          'authenticated holds no execute on bot_send_charge');
select is((select array_agg(c order by c) from unnest(array['message_id','user_id','conversation_id','emoji',
                                                             'created_at','updated_at']) c
            where has_column_privilege('authenticated', 'public.message_reactions', c, 'select')),
          array['conversation_id','emoji','message_id','updated_at','user_id'],
          'authenticated selects every column but created_at');
select is_empty(
  $$select r || ' ' || p from unnest(array['anon','authenticated']) r,
                              unnest(array['insert','update','delete','truncate','references','trigger']) p
     where case when p in ('insert','update','references')
                then has_any_column_privilege(r, 'public.message_reactions', p)
                else has_table_privilege(r, 'public.message_reactions', p) end$$,
  'no client role may insert, update, delete or truncate message_reactions');
select ok(not has_any_column_privilege('anon', 'public.message_reactions', 'select'),
          'anon reads no column of message_reactions');
select ok((select relrowsecurity from pg_class where oid = 'public.message_reactions'::regclass),
          'row level security is on');
select ok(exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'message_reactions'),
          'message_reactions is published to Realtime');

set local role anon;
select throws_ok(format('select public.set_reaction(%L, %L)', g('M'), '👍'), '42501', null,
                 'anon cannot call set_reaction');
reset role;

-- 2 a human sets, changes and clears ------------------------------------------------
select as_('01');
select lives_ok(format('select react(%L, %L)', g('M'), '👍'), 'ann reacts 👍');
select lives_ok(format('select react(%L, %L)', g('M'), '👍'), 'and again: no error');
reset role;
select is(stored(g('M'), '01'), '👍', 'setting the same emoji twice leaves it set (no toggle)');
select is(rows_of(g('M')), 1::bigint, 'one row per (message, user)');
select is((select conversation_id from public.message_reactions where message_id = g('M') and user_id = u('01')),
          g('DEBUG'), 'conversation_id is the message''s conversation');
select as_('01');
select lives_ok(format('select react(%L, %L)', g('M'), '❤️'), 'ann changes to ❤️');
reset role;
select is(stored(g('M'), '01'), '❤️', 'the change replaces the emoji');
select is(rows_of(g('M')), 1::bigint, 'still one row');
select as_('01');
select lives_ok(format('select react(%L, null)', g('M')), 'ann clears');
reset role;
select is(stored(g('M'), '01'), '-', 'a clear stores a NULL emoji');
select is(rows_of(g('M')), 1::bigint, 'a clear is an UPDATE: the row stays');
select as_('01');
select lives_ok(format('select react(%L, null)', g('M')), 'clearing again is fine');
reset role;
select is(stored(g('M'), '01'), '-', 'and stays cleared (no toggle)');
select as_('01');
select lives_ok(format('select react(%L, %L)', g('M'), '👍'), 'ann reacts again after a clear');
reset role;
select is(stored(g('M'), '01'), '👍', 'the cleared row is set again');
select as_('02');
select lives_ok(format('select react(%L, %L)', g('M'), '😂'), 'bob reacts too');
select is(seen(g('M')), u('01') || '=👍,' || u('02') || '=😂', 'bob sees both reactions');
select is(try($$insert into public.message_reactions(message_id, user_id, conversation_id, emoji)
                values (g('HIDE'), u('02'), g('DEBUG'), '👍')$$), '42501', 'a client cannot insert a reaction');
select is(try($$update public.message_reactions set emoji = '🔥' where user_id = u('02')$$), '42501',
          'nor update one');
select is(try($$delete from public.message_reactions where user_id = u('02')$$), '42501', 'nor delete one');
reset role;
select is(stored(g('M'), '02'), '😂', 'bob''s reaction is unchanged');

-- 3 emojis: only after access, then validated ------------------------------------------
select as_('01');
select lives_ok(format('select react(%L, %L)', g('M'), repeat('😀', 16)), 'exactly 64 bytes is accepted');
select lives_ok(format('select react(%L, %L)', g('M'), '👨‍👩‍👧'), 'a ZWJ family emoji is accepted');
select lives_ok(format('select react(%L, %L)', g('M'), '👍🏽'), 'a skin-tone emoji is accepted');
select throws_ok(format('select react(%L, %L)', g('M'), ''), '22023', 'invalid emoji', 'empty is refused');
select throws_ok(format('select react(%L, %L)', g('M'), repeat('😀', 17)), '22023', 'invalid emoji',
                 '68 bytes in 17 characters is refused (bytes, not characters)');
select throws_ok(format('select react(%L, %L)', g('M'), repeat('a', 65)), '22023', 'invalid emoji',
                 '65 bytes is refused');
select throws_ok(format('select react(%L, %L)', g('M'), ' '), '22023', 'invalid emoji', 'a space is refused');
select throws_ok(format('select react(%L, %L)', g('M'), '👍 '), '22023', 'invalid emoji',
                 'a trailing space is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'👍\t'), '22023', 'invalid emoji', 'a tab is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'a\nb'), '22023', 'invalid emoji', 'a newline is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'\u0001'), '22023', 'invalid emoji',
                 'a control character is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'\u007f'), '22023', 'invalid emoji',
                 'DEL is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'\u00a0'), '22023', 'invalid emoji',
                 'a no-break space is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'\u3000'), '22023', 'invalid emoji',
                 'an ideographic space is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'👍\u2028'), '22023', 'invalid emoji',
                 'a line separator is refused');
select throws_ok(format('select react(%L, %L)', g('M'), E'\u0085'), '22023', 'invalid emoji',
                 'a C1 control character is refused');
reset role;
select is(stored(g('M'), '01'), '👍🏽', 'refused emojis left the last valid one');
select as_('03');
select throws_ok(format('select react(%L, %L)', g('G2M'), ''), '42501', 'not permitted',
                 'access is checked before the emoji: a non-member with an empty emoji gets 42501');
reset role;

-- 4 every refusal is 42501 'not permitted' -----------------------------------------------
select as_('01');
select throws_ok(format('select react(%L, %L)', gen_random_uuid(), '👍'), '42501', 'not permitted',
                 'a missing message');
select isnt((select count(*) from public.messages where id = g('SYSM')), 0::bigint,
            'ann reads her system chat message (only the system rule can refuse her)');
select throws_ok(format('select react(%L, %L)', g('SYSM'), '👍'), '42501', 'not permitted',
                 'the read-only system chat');
reset role;

-- deleted for everyone: bob reacts first, then ann deletes
select as_('02');
select lives_ok(format('select react(%L, %L)', g('DEL'), '👍'), 'control: bob reacts to a live message');
reset role;
select as_('01');
select lives_ok(format('select public.delete_message(%L)', g('DEL')), 'ann deletes it for everyone');
reset role;
select as_('02');
select throws_ok(format('select react(%L, %L)', g('DEL'), '😂'), '42501', 'not permitted', 'a deleted message');
select throws_ok(format('select react(%L, null)', g('DEL')), '42501', 'not permitted',
                 'nor can a reaction on a deleted message be cleared');
select is(seen(g('DEL')), '', 'reactions on a deleted message are not readable');
reset role;
select is(rows_of(g('DEL')), 1::bigint, 'fixture: the reaction row is still there underneath');

-- hidden for me: bob hides, ann still may
select as_('02');
select lives_ok(format('select react(%L, %L)', g('HIDE'), '👍'), 'control: bob reacts before hiding');
reset role;
select as_('01');
select lives_ok(format('select react(%L, %L)', g('HIDE'), '🔥'), 'ann reacts too');
reset role;
select as_('02');
select lives_ok(format('select public.hide_message(%L)', g('HIDE')), 'bob deletes it for himself');
select throws_ok(format('select react(%L, %L)', g('HIDE'), '😂'), '42501', 'not permitted',
                 'a message deleted for me');
select is(seen(g('HIDE')), '', 'bob no longer reads its reactions');
reset role;
select as_('01');
select is(seen(g('HIDE')), u('01') || '=🔥,' || u('02') || '=👍', 'ann still reads them');
select lives_ok(format('select react(%L, null)', g('HIDE')), 'and still reacts');
reset role;

-- history window: cat joined Debug's history 1 h ago, the note is 2 h old
select as_('02');
select lives_ok(format('select react(%L, %L)', g('OLD'), '👍'), 'control: bob reacts to the old note');
reset role;
select as_('03');
select is(seen(g('M')), u('01') || '=👍🏽,' || u('02') || '=😂', 'cat reads reactions inside her window');
select throws_ok(format('select react(%L, %L)', g('OLD'), '👍'), '42501', 'not permitted',
                 'a message before the caller''s history window');
select is(seen(g('OLD')), '', 'nor reads reactions on it');
reset role;

-- membership
select as_('02');
select lives_ok(format('select react(%L, %L)', g('G2M'), '👍'), 'control: bob reacts in G2');
reset role;
select as_('03');
select throws_ok(format('select react(%L, %L)', g('G2M'), '👍'), '42501', 'not permitted',
                 'a caller who was never a member');
select is(seen(g('G2M')), '', 'a non-member reads no reactions');
reset role;
select as_('06');
select is(seen(g('G2M')), u('02') || '=👍', 'fay reads G2 reactions while a member');
select lives_ok($$select leave_c(g('G2'))$$, 'fay leaves G2');
select throws_ok(format('select react(%L, %L)', g('G2M'), '👍'), '42501', 'not permitted',
                 'a former member');
select is(seen(g('G2M')), '', 'a former member reads no reactions');
reset role;

-- app access: eve is a Debug member, then her session is revoked
select as_('05');
select is(seen(g('M')), u('01') || '=👍🏽,' || u('02') || '=😂', 'eve reads Debug reactions');
select lives_ok(format('select react(%L, %L)', g('M'), '👍'), 'eve reacts while she has access');
reset role;
delete from auth.sessions where user_id = u('05');
select as_('05');
select throws_ok(format('select react(%L, %L)', g('M'), '😂'), '42501', 'not permitted', 'a revoked user');
select throws_ok(format('select react(%L, %L)', g('M'), ''), '42501', 'not permitted',
                 'a revoked user with a bad emoji still gets 42501');
select is(seen(g('M')), '', 'a revoked user reads no reactions');
reset role;
select is(stored(g('M'), '05'), '👍', 'her refused call changed nothing');
select is((select count(*) from app_private.bot_actions), 0::bigint, 'humans leave no bot_actions rows');

-- 4b S-1: a clear on an already-cleared row writes nothing (human) ------------------------
select age_row(g('M'), '02');
insert into snaps values ('bob set', ver(g('M'), '02'));
select as_('02');
select lives_ok(format('select react(%L, null)', g('M')), 'bob clears his 😂');
reset role;
select is(stored(g('M'), '02'), '-', 'the first clear writes NULL');
select ok(upd_at(g('M'), '02') > now() - interval '1 hour', 'and a new updated_at');
select isnt(ver(g('M'), '02'), (select v from snaps where name = 'bob set'), 'as a new row version');
insert into snaps values ('bob cleared', ver(g('M'), '02'));
select as_('02');
select lives_ok(format('select react(%L, null)', g('M')), 'bob clears again (1)');
select lives_ok(format('select react(%L, null)', g('M')), 'bob clears again (2)');
select lives_ok(format('select react(%L, null)', g('M')), 'bob clears again (3)');
reset role;
select is(ver(g('M'), '02'), (select v from snaps where name = 'bob cleared'),
          'repeated clears leave the row untouched: same ctid, xmin and updated_at');
select is(stored(g('M'), '02'), '-', 'still cleared');
-- cat has no reaction row on M
select is(rows_of(g('M')), 3::bigint, 'fixture: M has ann, bob and eve rows, none for cat');
select as_('03');
select is((select pg_typeof(public.set_reaction(g('M'), null))::text), 'void',
          'a clear with no reaction row returns void');
reset role;
select is(rows_of(g('M')), 3::bigint, 'and inserts nothing');
select is(stored(g('M'), '03'), null, 'cat still has no row');

-- 5 the bot ---------------------------------------------------------------------------
select runbook();
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('DEBUG'));
insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing;
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
values (g('DEBUG'), u('bot'), 'member', now() - interval '3 days', now() - interval '3 days');
update app_private.bot_accounts set enabled = true where user_id = u('bot');
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('04'));
select as_('bot');
select public.activate_session();
insert into ids values ('BD', public.start_direct_conversation(u('04')));
reset role;
select as_('04');
insert into ids values ('BDM', msg(g('BD'), 'hi bot'));
reset role;
select backdate(0, '0'::interval);

select as_('bot');
select lives_ok(format('select react(%L, %L)', g('M'), '👍'), 'the bot reacts in Debug');
reset role;
select is(stored(g('M'), 'bot'), '👍', 'its reaction is stored');
select is(sends(), 1::bigint, 'a set is logged as one send');
select as_('02');
select ok(seen(g('M')) like '%' || u('bot') || '=👍%', 'a human member sees the bot''s reaction');
reset role;
select as_('bot');
select lives_ok(format('select react(%L, null)', g('M')), 'the bot clears it');
reset role;
select is(stored(g('M'), 'bot'), '-', 'cleared');
select is(sends(), 1::bigint, 'a clear is not counted');
select as_('bot');
select lives_ok(format('select react(%L, %L)', g('BDM'), '❤️'), 'the bot reacts in its listed 1:1');
select is(seen(g('BDM')), u('bot') || '=❤️', 'and reads it');
reset role;
select as_('04');
select is(seen(g('BDM')), u('bot') || '=❤️', 'dan sees the bot''s reaction');
reset role;
select is(sends(), 2::bigint, 'that set was counted too');

select as_('bot');
select throws_ok(format('select react(%L, %L)', g('G2M'), '👍'), '42501', 'not permitted',
                 'the bot is refused in a chat it is not in');
select is(seen(g('G2M')), '', 'and reads no reactions there');
select throws_ok(format('select react(%L, %L)', g('M'), ''), '22023', 'invalid emoji',
                 'a bad emoji from the bot is 22023');
reset role;
select is(sends(), 2::bigint, 'refused calls left no log row');

-- S-1 for the bot: a counted set, then clears that write once and log nothing
select as_('bot');
select lives_ok(format('select react(%L, %L)', g('M'), '🎉'), 'the bot sets 🎉');
reset role;
select is(sends(), 3::bigint, 'the set is counted');
select age_row(g('M'), 'bot');
insert into snaps values ('bot set', ver(g('M'), 'bot'));
select as_('bot');
select lives_ok(format('select react(%L, null)', g('M')), 'the bot clears it');
reset role;
select is(stored(g('M'), 'bot'), '-', 'the first clear writes NULL');
select ok(upd_at(g('M'), 'bot') > now() - interval '1 hour', 'and a new updated_at');
select isnt(ver(g('M'), 'bot'), (select v from snaps where name = 'bot set'), 'as a new row version');
insert into snaps values ('bot cleared', ver(g('M'), 'bot'));
select as_('bot');
select lives_ok(format('select react(%L, null)', g('M')), 'the bot clears again (1)');
select lives_ok(format('select react(%L, null)', g('M')), 'the bot clears again (2)');
select lives_ok(format('select react(%L, null)', g('M')), 'the bot clears again (3)');
reset role;
select is(ver(g('M'), 'bot'), (select v from snaps where name = 'bot cleared'),
          'repeated bot clears leave the row untouched: same ctid, xmin and updated_at');
select is(sends(), 3::bigint, 'none of the clears added a bot_actions row');
select is(stored(g('OLD'), 'bot'), null, 'fixture: the bot has no row on the old note');
select as_('bot');
select is((select pg_typeof(public.set_reaction(g('OLD'), null))::text), 'void',
          'a bot clear with no reaction row returns void');
reset role;
select is(stored(g('OLD'), 'bot'), null, 'and inserts nothing');
select is(sends(), 3::bigint, 'and logs nothing');

-- the shared budget
select backdate(19, '1 minute');
select as_('bot');
select lives_ok(format('select react(%L, %L)', g('M'), '🔥'), 'the 20th action in 10 minutes is a reaction');
select throws_ok(format('insert into public.messages(conversation_id, sender_id, body) values (%L, %L, %L)',
                        g('DEBUG'), u('bot'), 'over'),
                 'RLMT2', null, 'it used up the message budget: the next message is refused');
select throws_ok(format('select react(%L, %L)', g('BDM'), '👍'), 'RLMT2', null,
                 'and so is the next reaction');
select lives_ok(format('select react(%L, null)', g('M')), 'a clear is still allowed... and');
reset role;
select is(sends(), 20::bigint, '...the clear and the refused calls left no log rows');
select is(stored(g('BDM'), 'bot'), '❤️', 'the refused reaction changed nothing');
select backdate(20, '1 minute');
select as_('bot');
select throws_ok(format('select react(%L, %L)', g('M'), '👍'), 'RLMT2', null,
                 '20 messages in 10 minutes block a reaction');
reset role;
select backdate(20, '11 minutes');
select as_('bot');
select lives_ok(format('select react(%L, %L)', g('M'), '👍'), 'sends older than 10 minutes do not count');
reset role;
select backdate(200, '1 hour');
select as_('bot');
select throws_ok(format('select react(%L, %L)', g('M'), '😂'), 'RLMT2', null,
                 '200 in 24 hours block a reaction');
reset role;
select is(sends(), 200::bigint, 'and left no log row');
select backdate(0, '0'::interval);

-- delisted
select runbook();
delete from app_private.bot_contacts where bot_id = u('bot') and contact_id = u('04');
select as_('bot');
select throws_ok(format('select react(%L, %L)', g('BDM'), '👍'), '42501', 'not permitted',
                 'after delisting the bot is refused in that 1:1');
select is(seen(g('BDM')), '', 'and reads none of its reactions');
select lives_ok(format('select react(%L, %L)', g('M'), '😂'), 'control: Debug still works');
reset role;

-- OFF
update app_private.bot_accounts set enabled = false where user_id = u('bot');
select backdate(0, '0'::interval);
select as_('bot');
select throws_ok(format('select react(%L, %L)', g('M'), '👍'), '42501', 'not permitted', 'OFF: a set is refused');
select throws_ok(format('select react(%L, null)', g('M')), '42501', 'not permitted', 'OFF: a clear is refused');
select is(seen(g('M')), '', 'OFF: it reads no reactions');
reset role;
select is(stored(g('M'), 'bot'), '😂', 'OFF: nothing changed');
select is(sends(), 0::bigint, 'OFF: nothing logged');

select * from finish();
rollback;
