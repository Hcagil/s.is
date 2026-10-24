begin;
select plan(108);

-- Locked reactions in private chats (20261104120000_encrypted_reactions.sql).
--
-- Written from the contract, not from the migration:
--   message_reactions.ciphertext text, olm_type smallint; CHECK
--   message_reactions_lock_check: (ciphertext null) = (olm_type null), never
--   emoji and ciphertext together, ciphertext 1..1024 chars, olm_type 0 or 1.
--   Clients select both new columns, write nothing; the read policy is
--   unchanged; Realtime is postgres_changes only (no broadcast trigger).
--   set_reaction_encrypted(message, ciphertext, olm_type): security definer,
--   search_path '', EXECUTE for authenticated only. 42501 for no app access,
--   a missing, deleted or unreadable message, a non-member, the system chat,
--   a bot caller, a chat that cannot be locked (group, bot chat, a member
--   without live keys); 22023 for a null, empty or > 1024 char ciphertext or
--   an olm_type not 0/1. Success sets conversations.encrypted_at (coalesce,
--   the first locked reaction locks the chat) and upserts the row with emoji
--   NULL. set_reaction: a non-null emoji is 42501 once encrypted_at is set; a
--   clear still works and nulls emoji, ciphertext and olm_type; a plain set
--   nulls ciphertext and olm_type. Migration S5: plain emoji rows in a chat
--   with encrypted_at and updated_at >= encrypted_at are nulled; older kept.
--
-- Each refused subject has a twin that differs only in the gate under test.
--   ann  main caller        bob  ann's 1:1 (AB), locked here by a reaction
--   cat  ann's plain 1:1 (AC), never locked; also in the group G
--   dee  ann's 1:1 (AD), locked by a ciphertext message; the S5 chat
--   eve  keyed, a member of nothing ann has (the non-member)
--   nok  never publishes keys (AN with ann)
--   rev  1:1 with bob (RB), session revoked later
--   out  1:1 with bob (OB), removed from the allowlist later (keys stay live)
--   bot  enabled bot with a device on its live session, ann's 1:1 AT

-- fixtures -----------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000e6c000' || case n
    when 'ann' then '01' when 'bob' then '02' when 'cat' then '03' when 'dee' then '04'
    when 'eve' then '05' when 'nok' then '06' when 'rev' then '07' when 'out' then '08'
    when 'bot' then '09' end)::uuid
$$;
create function sid(n text) returns text language sql immutable as $$
  select 'e6c00000-0000-0000-0000-' || right(u(n)::text, 12)
$$;
create function mid(n text) returns uuid language sql immutable as $$
  select md5('e6c-msg-' || n)::uuid
$$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function ct(n int, c text default 'A') returns text language sql immutable as $$ select repeat(c, n) $$;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'e6c-' || n || '@mail.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['ann','bob','cat','dee','eve','nok','rev','out','bot']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'e6c-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select sid(n)::uuid, u(n), now(), now() from unnest(array['ann','bob','cat','dee','eve','nok','rev','out','bot']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('ann'), u('bob')), (u('ann'), u('cat')), (u('ann'), u('dee')), (u('ann'), u('nok')),
  (u('ann'), u('bot')), (u('rev'), u('bob')), (u('out'), u('bob'));

create function tag_find(a uuid, b uuid) returns void language sql as $$
  insert into app_private.tag_finds(finder, found_id) values (a, b) on conflict do nothing
$$;
create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', sid(n))::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
-- 'ok' or the sqlstate, in its own subtransaction.
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
-- the two RPCs, as the current role
create function lk(m uuid, x text, t int) returns text language sql as $$
  select try(format('select public.set_reaction_encrypted(%L, %L, %L::smallint)', m, x, t))
$$;
create function pl(m uuid, e text) returns text language sql as $$
  select try(format('select public.set_reaction(%L, %L)', m, e))
$$;
-- the stored truth, whatever RLS says
create function row_of(m uuid, who text) returns text language sql stable security definer as $$
  select coalesce((select concat_ws('|', coalesce(emoji, '<null>'), coalesce(ciphertext, '<null>'),
                                    coalesce(olm_type::text, '<null>'))
                     from public.message_reactions where message_id = m and user_id = u(who)), '<no row>')
$$;
create function enc_at(c uuid) returns timestamptz language sql stable security definer as $$
  select encrypted_at from public.conversations where id = c
$$;
-- a row written as the superuser (shapes a client cannot make)
create function put_row(m uuid, who text, e text, x text, t int) returns text language sql as $$
  select try(format($q$insert into public.message_reactions(message_id, user_id, conversation_id, emoji, ciphertext, olm_type)
                       select %L, %L, conversation_id, %L, %L, %L::smallint from public.messages where id = %L$q$,
                    m, u(who), e, x, t, m))
$$;

create table public.e6c_ids(name text primary key, id uuid);
grant select, insert on public.e6c_ids to authenticated, anon;
create function g(n text) returns uuid language sql stable as $$
  select id from public.e6c_ids where name = n
$$;
create function msg(c uuid, id uuid, b text) returns uuid language sql as $$
  insert into public.messages(id, conversation_id, sender_id, body) values (id, c, auth.uid(), b) returning id
$$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), ct(int, text), as_(text),
  commit_check(), try(text), lk(uuid, text, int), pl(uuid, text), row_of(uuid, text), enc_at(uuid), g(text),
  msg(uuid, uuid, text) to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['ann','bob','cat','dee','eve','nok','rev','out','bot'] loop
    perform as_(n);
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    if n not in ('bot', 'nok') then
      perform public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n),
                                      array[k(n || '1'), k(n || '2')], k(n || '-F'));
    end if;
    execute 'reset role';
  end loop;
end $$;
-- The bot has a device on its live session: refused for being a bot, never for keys.
insert into app_private.olm_devices(user_id, identity_key, signing_key, device_signature, fallback_key, session_id)
  values (u('bot'), k('bot-I'), k('bot-S'), sig('bot'), k('bot-F'), sid('bot')::uuid);
insert into public.conversations(id, title) values ('e6c0c000-0000-0000-0000-00000000dbdb', 'e6c debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
  values (u('bot'), 'e6c0c000-0000-0000-0000-00000000dbdb', true);
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('ann'));

select as_('ann');
insert into public.e6c_ids values
  ('AB', public.start_direct_conversation(u('bob'))),
  ('AC', public.start_direct_conversation(u('cat'))),
  ('AD', public.start_direct_conversation(u('dee'))),
  ('AN', public.start_direct_conversation(u('nok'))),
  ('AT', public.start_direct_conversation(u('bot'))),
  ('G',  public.start_group_conversation('e6c group', array[u('bob'), u('cat')]));
reset role;
select commit_check();
select as_('rev'); insert into public.e6c_ids values ('RB', public.start_direct_conversation(u('bob'))); reset role;
select as_('out'); insert into public.e6c_ids values ('OB', public.start_direct_conversation(u('bob'))); reset role;
insert into public.conversations(id, system) values ('e6c0c000-0000-0000-0000-00000000555a', true);
insert into public.conversation_members(conversation_id, user_id) values ('e6c0c000-0000-0000-0000-00000000555a', u('ann'));
insert into public.e6c_ids values ('SYS', 'e6c0c000-0000-0000-0000-00000000555a');
-- a system chat shaped like a lockable 1:1 (two keyed humans), so only the system rule can refuse it
insert into public.conversations(id, system) values ('e6c0c000-0000-0000-0000-00000000555b', true);
insert into public.conversation_members(conversation_id, user_id)
  values ('e6c0c000-0000-0000-0000-00000000555b', u('ann')), ('e6c0c000-0000-0000-0000-00000000555b', u('bob'));
insert into public.e6c_ids values ('SYS2', 'e6c0c000-0000-0000-0000-00000000555b');

-- every message is written while every chat is still plain
select as_('ann');
select msg(g('AB'), mid('ab1'), 'ab one');
select msg(g('AB'), mid('ab2'), 'ab two');
select msg(g('AB'), mid('abdel'), 'ab deleted later');
select msg(g('AB'), mid('abhid'), 'ab hidden by bob');
select msg(g('AC'), mid('ac1'), 'ac one');
select msg(g('AC'), mid('ac2'), 'ac two');
select msg(g('AD'), mid('ad1'), 'ad one');
select msg(g('AD'), mid('ad2'), 'ad two');
select msg(g('AD'), mid('ad3'), 'ad three');
select msg(g('AN'), mid('an1'), 'an one');
select msg(g('AT'), mid('at1'), 'at one');
select msg(g('G'), mid('g1'), 'group one');
reset role;
select as_('rev'); select msg(g('RB'), mid('rb1'), 'rb one'); reset role;
select as_('out'); select msg(g('OB'), mid('ob1'), 'ob one'); reset role;
insert into public.messages(id, conversation_id, sender_id, body) values
  (mid('sys1'), g('SYS'), u('ann'), 'system note'), (mid('sys2'), g('SYS2'), u('ann'), 'system note two');

select is((select count(*) from public.e6c_ids where id is not null), 10::bigint, 'fixture: all ten conversations exist');
select is((select count(*) from public.conversations where id in (select id from public.e6c_ids) and encrypted_at is not null),
          0::bigint, 'fixture: no chat is private yet');

-- 1 S1: columns and the CHECK ------------------------------------------------
select has_column('public', 'message_reactions', 'ciphertext', 'message_reactions.ciphertext exists');
select col_type_is('public', 'message_reactions', 'ciphertext', 'text', 'ciphertext is text');
select has_column('public', 'message_reactions', 'olm_type', 'message_reactions.olm_type exists');
select col_type_is('public', 'message_reactions', 'olm_type', 'smallint', 'olm_type is smallint');
select ok(exists(select 1 from pg_constraint where conrelid = 'public.message_reactions'::regclass
                  and conname = 'message_reactions_lock_check' and contype = 'c'),
          'the CHECK message_reactions_lock_check exists');
-- every shape on a message with no row yet (ac2, as dee's twin user cat)
select is(put_row(mid('ac2'), 'cat', '👍', ct(10), 1), '23514', 'CHECK: emoji and ciphertext together are refused');
select is(put_row(mid('ac2'), 'cat', null, ct(10), null), '23514', 'CHECK: ciphertext without olm_type is refused');
select is(put_row(mid('ac2'), 'cat', null, null, 1), '23514', 'CHECK: olm_type without ciphertext is refused');
select is(put_row(mid('ac2'), 'cat', null, ct(10), 2), '23514', 'CHECK: olm_type 2 is refused');
select is(put_row(mid('ac2'), 'cat', null, ct(10), -1), '23514', 'CHECK: olm_type -1 is refused');
select is(put_row(mid('ac2'), 'cat', null, '', 1), '23514', 'CHECK: an empty ciphertext is refused');
select is(put_row(mid('ac2'), 'cat', null, ct(1025), 1), '23514', 'CHECK: 1025 characters are refused');
select is(put_row(mid('ac2'), 'cat', null, ct(1024, 'é'), 0), 'ok', 'CHECK: 1024 characters (multi-byte) are accepted, olm_type 0');
select is(row_of(mid('ac2'), 'cat'), '<null>|' || ct(1024, 'é') || '|0', 'stored as written');
select is(put_row(mid('ac1'), 'cat', '👍', null, null), 'ok', 'CHECK: a plain emoji row is still accepted');

-- 2 S4: grants, policy, realtime -----------------------------------------------
select ok(has_column_privilege('authenticated', 'public.message_reactions', 'ciphertext', 'select')
          and has_column_privilege('authenticated', 'public.message_reactions', 'olm_type', 'select'),
          'authenticated selects ciphertext and olm_type');
select ok(not has_column_privilege('anon', 'public.message_reactions', 'ciphertext', 'select')
          and not has_column_privilege('anon', 'public.message_reactions', 'olm_type', 'select'),
          'anon selects neither');
select is_empty($$select r || ' ' || c || ' ' || p from unnest(array['anon','authenticated']) r,
                     unnest(array['ciphertext','olm_type']) c, unnest(array['insert','update','references']) p
                  where has_column_privilege(r, 'public.message_reactions', c, p)$$,
                'no client role writes ciphertext or olm_type');
select is_empty($$select t.tgname from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                  where t.tgrelid = 'public.message_reactions'::regclass and not t.tgisinternal
                    and p.prosrc ~* 'realtime\.(send|broadcast)'$$,
                'no broadcast trigger on message_reactions (postgres_changes only)');
select ok(exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'message_reactions'),
          'message_reactions stays published to Realtime');
select ok((select prosecdef from pg_proc where oid = 'public.set_reaction_encrypted(uuid, text, smallint)'::regprocedure),
          'set_reaction_encrypted is security definer');
select ok((select 'search_path=""' = any(proconfig) from pg_proc
            where oid = 'public.set_reaction_encrypted(uuid, text, smallint)'::regprocedure),
          'set_reaction_encrypted pins search_path to empty');
select function_privs_are('public', 'set_reaction_encrypted', array['uuid', 'text', 'smallint'], 'authenticated',
                          array['EXECUTE'], 'authenticated may execute set_reaction_encrypted');
select function_privs_are('public', 'set_reaction_encrypted', array['uuid', 'text', 'smallint'], 'anon', '{}'::text[],
                          'anon holds no execute on set_reaction_encrypted');
select ok(not has_function_privilege('public', 'public.set_reaction_encrypted(uuid, text, smallint)', 'execute'),
          'PUBLIC holds no execute on set_reaction_encrypted');
select is_empty($$select r from unnest(array['public','anon','authenticated']) r, pg_proc p
                  join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'app_private' and p.proname = 'chat_lockable'
                    and has_function_privilege(r, p.oid, 'execute')$$,
                'no client role executes app_private.chat_lockable');

-- 3 S2: the first locked reaction locks a lockable 1:1 ---------------------------
select as_('ann');
select is(pl(mid('ab1'), '👍'), 'ok', 'control: a plain reaction in AB while it is still plain');
reset role;
select is(enc_at(g('AB')), null, 'a plain reaction does not lock the chat');
select as_('bob');
select is(lk(mid('ab1'), ct(40, 'B'), 0), 'ok', 'bob locks a reaction in AB (olm_type 0)');
reset role;
select is(row_of(mid('ab1'), 'bob'), '<null>|' || ct(40, 'B') || '|0', 'stored with emoji NULL');
select is(enc_at(g('AB')), now(), 'the first locked reaction set AB.encrypted_at');
update public.conversations set encrypted_at = now() - interval '3 days' where id = g('AB');
select as_('bob');
select is(lk(mid('ab1'), ct(40, 'C'), 1), 'ok', 'bob changes his locked reaction (olm_type 1)');
reset role;
select is(enc_at(g('AB')), now() - interval '3 days', 'encrypted_at is kept once set (coalesce)');
select is(row_of(mid('ab1'), 'bob'), '<null>|' || ct(40, 'C') || '|1', 'the change replaced the row');
select is((select count(*) from public.message_reactions where message_id = mid('ab1') and user_id = u('bob')), 1::bigint,
          'still one row per (message, user)');

-- a member reads the locked row; a non-member reads nothing
select as_('ann');
select is((select ciphertext from public.message_reactions where message_id = mid('ab1') and user_id = u('bob')), ct(40, 'C'),
          'ann (member) reads bob''s ciphertext');
select is((select emoji from public.message_reactions where message_id = mid('ab1') and user_id = u('bob')), null,
          'and no emoji');
reset role;
select as_('eve');
select is_empty(format('select ciphertext from public.message_reactions where message_id = %L', mid('ab1')),
                'eve (non-member) reads no row of AB');
reset role;

-- 4 S3: no downgrade -----------------------------------------------------------
select is(row_of(mid('ab1'), 'ann'), '👍|<null>|<null>', 'fixture: ann''s plain row from before the lock');
select as_('ann');
select is(pl(mid('ab2'), '😂'), '42501', 'a plain set in a locked chat is refused (42501)');
select is(pl(mid('ab1'), '❤️'), '42501', 'also over her existing plain row');
reset role;
select is(row_of(mid('ab2'), 'ann'), '<no row>', 'the refusal wrote nothing');
select is(row_of(mid('ab1'), 'ann'), '👍|<null>|<null>', 'and left the old row');
select as_('ann');
select is(lk(mid('ab1'), ct(30, 'R'), 1), 'ok', 'ann re-locks her old plain reaction');
reset role;
select is(row_of(mid('ab1'), 'ann'), '<null>|' || ct(30, 'R') || '|1', 'the plain emoji is gone, the ciphertext stored');
select as_('bob');
select is(pl(mid('ab1'), null), 'ok', 'bob clears his locked reaction with set_reaction(NULL)');
reset role;
select is(row_of(mid('ab1'), 'bob'), '<null>|<null>|<null>', 'the clear nulls emoji, ciphertext and olm_type');
select is((select count(*) from public.message_reactions where message_id = mid('ab1') and user_id = u('bob')), 1::bigint,
          'the clear is an UPDATE: the row stays');
-- a plain chat keeps plain reactions, and a plain set nulls a ciphertext
select is(put_row(mid('ac1'), 'ann', null, ct(20), 1), 'ok', 'fixture: a locked row of ann in plain AC');
select as_('ann');
select is(pl(mid('ac1'), '🔥'), 'ok', 'a plain set in a plain chat works');
reset role;
select is(row_of(mid('ac1'), 'ann'), '🔥|<null>|<null>', 'and nulls ciphertext and olm_type');
select is(enc_at(g('AC')), null, 'AC stays plain');
-- a chat locked by a ciphertext message refuses plain sets too
select as_('ann');
select is(try(format($q$insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type)
                        values (%L, %L, auth.uid(), '🔒 Encrypted message', %L, 0::smallint)$q$,
                     mid('adx'), g('AD'), ct(10))), 'ok', 'ann sends a locked message in AD');
reset role;
select isnt(enc_at(g('AD')), null, 'fixture: AD is private');
select as_('dee');
select is(pl(mid('ad1'), '👍'), '42501', 'a plain set in a chat locked by a message is refused');
select is(lk(mid('ad1'), ct(10), 0), 'ok', 'control: a locked set there works');
reset role;

-- 5 S2: 22023 for a bad ciphertext or olm_type (caller and chat pass every gate) --
select as_('ann');
select is(lk(mid('ab2'), null, 0), '22023', 'a null ciphertext');
select is(lk(mid('ab2'), '', 0), '22023', 'an empty ciphertext');
select is(lk(mid('ab2'), ct(1025), 0), '22023', '1025 characters');
select is(lk(mid('ab2'), ct(10), 2), '22023', 'olm_type 2');
select is(lk(mid('ab2'), ct(10), -1), '22023', 'olm_type -1');
select is(lk(mid('ab2'), ct(10), null), '22023', 'a null olm_type');
reset role;
select is(row_of(mid('ab2'), 'ann'), '<no row>', 'none of them wrote a row');
select as_('ann');
select is(lk(mid('ab2'), ct(1024), 0), 'ok', 'control: 1024 characters go');
reset role;

-- 6 S2: every refusal is 42501 and writes nothing ---------------------------------
select as_('ann');
select is(lk(gen_random_uuid(), ct(10), 0), '42501', 'a missing message');
select is(lk(mid('sys1'), ct(10), 0), '42501', 'the system chat');
select is(lk(mid('sys2'), ct(10), 0), '42501', 'a system chat of two keyed humans');
select is(lk(mid('g1'), ct(10), 0), '42501', 'a group (every member keyed)');
select is(lk(mid('an1'), ct(10), 0), '42501', 'a 1:1 whose other member has no keys');
select is(lk(mid('at1'), ct(10), 0), '42501', 'a 1:1 with a bot (the bot has a live device)');
select is(lk(mid('ab2'), ct(11), 0), 'ok', 'control: the same call in AB goes');
reset role;
select is(enc_at(g('G')), null, 'the group stays plain');
select is(enc_at(g('AN')), null, 'AN stays plain');
select is(enc_at(g('AT')), null, 'AT stays plain');
select is((select count(*) from public.message_reactions where message_id in (mid('g1'), mid('an1'), mid('at1'), mid('sys1'), mid('sys2'))),
          0::bigint, 'the refusals wrote no row');
select as_('ann');
select is(pl(mid('an1'), '👍'), 'ok', 'control: AN still takes a plain reaction');
reset role;

select as_('bot');
select is(lk(mid('at1'), ct(10), 0), '42501', 'a bot caller');
reset role;
select as_('eve');
select is(lk(mid('ab2'), ct(10), 0), '42501', 'a non-member');
reset role;

-- deleted and hidden: the twin is the live message / the other member
select as_('ann');
select is(lk(mid('abdel'), ct(10), 0), 'ok', 'control: ann locks on a live message');
select lives_ok(format('select public.delete_message(%L)', mid('abdel')), 'ann deletes it for everyone');
select is(lk(mid('abdel'), ct(12), 0), '42501', 'a deleted message');
reset role;
select as_('bob');
select lives_ok(format('select public.hide_message(%L)', mid('abhid')), 'bob deletes a message for himself');
select is(lk(mid('abhid'), ct(10), 0), '42501', 'a message deleted for the caller');
reset role;
select as_('ann');
select is(lk(mid('abhid'), ct(10), 0), 'ok', 'control: ann still locks on it');
reset role;

-- app access: out keeps live keys, only the allowlist goes; rev's session is revoked
select as_('out');
select is(lk(mid('ob1'), ct(10), 0), 'ok', 'control: out locks while allowed');
reset role;
delete from app_private.allowlist where email = 'e6c-out@mail.test';
select as_('out');
select is(lk(mid('ob1'), ct(13), 0), '42501', 'a caller without app access (live keys kept)');
reset role;
select is(row_of(mid('ob1'), 'out'), '<null>|' || ct(10) || '|0', 'the refused call changed nothing');
select as_('rev');
select is(lk(mid('rb1'), ct(10), 0), 'ok', 'control: rev locks before the revoke');
reset role;
delete from auth.sessions where user_id = u('rev');
select as_('rev');
select is(lk(mid('rb1'), ct(14), 0), '42501', 'a revoked session');
reset role;
select is(row_of(mid('rb1'), 'rev'), '<null>|' || ct(10) || '|0', 'the refused call changed nothing');
set local role anon;
select is(lk(mid('ab2'), ct(10), 0), '42501', 'anon cannot call set_reaction_encrypted');
reset role;

-- 7 S5: the migration's null-out, run from the recorded migration --------------------
-- AD is private since now(); rows: before (kept), equal and after (nulled),
-- a locked row (kept), a plain row in plain AC (kept).
select is(put_row(mid('ad2'), 'ann', '👍', null, null), 'ok', 'fixture: ann plain on ad2');
select is(put_row(mid('ad2'), 'dee', '😂', null, null), 'ok', 'fixture: dee plain on ad2');
select is(put_row(mid('ad3'), 'ann', '🔥', null, null), 'ok', 'fixture: ann plain on ad3');
update public.message_reactions set updated_at = enc_at(g('AD')) - interval '1 hour'
 where message_id = mid('ad2') and user_id = u('ann');
update public.message_reactions set updated_at = enc_at(g('AD'))
 where message_id = mid('ad2') and user_id = u('dee');
update public.message_reactions set updated_at = enc_at(g('AD')) + interval '1 hour'
 where message_id = mid('ad3') and user_id = u('ann');
select is((select array[count(*) filter (where updated_at < enc_at(g('AD'))),
                         count(*) filter (where updated_at = enc_at(g('AD'))),
                         count(*) filter (where updated_at > enc_at(g('AD')))]
             from public.message_reactions where message_id in (mid('ad2'), mid('ad3'))),
          array[1, 1, 1]::bigint[], 'fixture: one row before, at and after encrypted_at');
select is((select count(*) from supabase_migrations.schema_migrations, unnest(statements) s
            where version = '20261104120000' and s ~* '^\s*(--[^\n]*\n\s*)*update\s+public\.message_reactions'),
          1::bigint, 'the migration holds one null-out statement');
do $$
begin
  execute (select s from supabase_migrations.schema_migrations, unnest(statements) s
            where version = '20261104120000' and s ~* '^\s*(--[^\n]*\n\s*)*update\s+public\.message_reactions');
end $$;
select is(row_of(mid('ad2'), 'ann'), '👍|<null>|<null>', 'a row from before encrypted_at is kept');
select is(row_of(mid('ad2'), 'dee'), '<null>|<null>|<null>', 'a row at encrypted_at is nulled');
select is(row_of(mid('ad3'), 'ann'), '<null>|<null>|<null>', 'a row after encrypted_at is nulled');
select is((select count(*) from public.message_reactions where message_id in (mid('ad2'), mid('ad3'))), 3::bigint,
          'nulled rows stay (published as updates)');
select is(row_of(mid('ad1'), 'dee'), '<null>|' || ct(10) || '|0', 'a locked row is untouched');
select is(row_of(mid('ac1'), 'cat'), '👍|<null>|<null>', 'a plain row in a plain chat is kept');
select is(row_of(mid('an1'), 'ann'), '👍|<null>|<null>', 'and in another plain chat');

-- 8 F2: a plain set locks the conversation row whatever encrypted_at holds, so
-- it waits for (and then sees) a first locked message or reaction committing
-- in the same instant. Read from the row's own lock bits (pgrowlocks): a
-- fresh plain 1:1 holds only the KEY SHARE its foreign keys take, until the
-- plain set. RED-EXPECTED until the fix round (F2).
create extension if not exists pgrowlocks;
create function modes(c uuid) returns text language sql as $$
  select coalesce((select array_to_string(array(select unnest(modes) order by 1), ',')
                     from pgrowlocks('public.conversations')
                    where locked_row = (select ctid from public.conversations where id = c)), 'none')
$$;
select tag_find(u('ann'), u('eve'));
select as_('ann');
insert into public.e6c_ids values ('AE', public.start_direct_conversation(u('eve')));
select msg(g('AE'), mid('ae1'), 'ae one');
reset role;
select ok(modes(g('AE')) !~ 'For (Share|No Key Update|Update)', 'fixture: AE''s row is not share-locked yet (' || modes(g('AE')) || ')');
select as_('eve');
select public.set_reaction(mid('ae1'), '😺');
reset role;
select is(enc_at(g('AE')), null, 'fixture: AE is still plain');
select ok(modes(g('AE')) ~ 'For (Share|No Key Update|Update)',
          'F2: the plain set share-locked the conversation row of a plain chat (' || modes(g('AE')) || ')');

select * from finish();
rollback;
