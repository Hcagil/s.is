begin;
select plan(73);

-- Find people from your contacts: public.find_by_contacts(hashes text[]).
--
-- Contract (step 16; docs/SECURITY.md):
--   Returns (user_id, display_name, tag, avatar_path, matched_hash), never an
--   email. A match is a confirmed, allowlisted, not deleted, not banned, not
--   bot member other than the caller whose allowlist email hashes to a sent
--   element: sha256 hex of lower(btrim(email)). avatar_path is masked by
--   avatar_visible_to, evaluated after the tag_finds row is written. Every
--   match writes tag_finds(caller, found). Duplicates collapse.
--   Errors, in order: 1 bot caller 42501 'not permitted'; 2 no app access
--   42501; 3 the 4th call in an hour or the 11th in 24 hours RLMT1; 4 null or
--   empty array -> no rows (the call still counts); 5 more than 2000 elements
--   or an element that is null or not ^[0-9a-f]{64}$ -> 22023 'invalid
--   request', never echoing the input. Failed calls leave no tag_lookups row.
--   'contacts' rows are pruned after 24 hours. Anon cannot execute.
--
-- Fixtures. Every negative target fails exactly ONE match gate; every caller
-- used for an error fails exactly the gate under test:
--   ann  the caller for matches          bob  target, picture, 'everyone'
--   cat  target, picture, 'contacts'     eve  target, mixed-case auth email
--   unc  allowlisted, unconfirmed        nal  confirmed, not allowlisted
--   del  allowlisted, deleted            ban  allowlisted, banned
--   bot  allowlisted bot, active session (also the bot caller)
--   kim  hour budget    mo  day budget   pat  null/empty    rob  bad input
--   stl  allowlisted, acts on a replaced phone
--   rev  allowlisted, session revoked

-- fixtures -----------------------------------------------------------------
create or replace function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000fbc000' || case n
    when 'ann' then '01' when 'bob' then '02' when 'cat' then '03' when 'eve' then '04'
    when 'unc' then '05' when 'nal' then '06' when 'del' then '07' when 'ban' then '08'
    when 'bot' then '09' when 'kim' then '0a' when 'mo' then '0b' when 'pat' then '0c'
    when 'rob' then '0d' when 'stl' then '0e' when 'rev' then '0f' end)::uuid
$$;
-- The contract's hash, computed here, not by the code under test.
create or replace function h(email text) returns text language sql immutable as $$
  select encode(sha256(convert_to(lower(btrim(email)), 'UTF8')), 'hex')
$$;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('ann'), 'fbc-ann@mail.test', now(), '{"full_name":"Ann"}'),
  (u('bob'), 'fbc-bob@mail.test', now(), '{"full_name":"Bob"}'),
  (u('cat'), 'fbc-cat@mail.test', now(), '{"full_name":"Cat"}'),
  (u('eve'), 'FBC-Eve@Mail.test', now(), '{"full_name":"Eve"}'),
  (u('unc'), 'fbc-unc@mail.test', null,  '{"full_name":"Unc"}'),
  (u('nal'), 'fbc-nal@mail.test', now(), '{"full_name":"Nal"}'),
  (u('del'), 'fbc-del@mail.test', now(), '{"full_name":"Del"}'),
  (u('ban'), 'fbc-ban@mail.test', now(), '{"full_name":"Ban"}'),
  (u('bot'), 'fbc-bot@mail.test', now(), '{"full_name":"Bot"}'),
  (u('kim'), 'fbc-kim@mail.test', now(), '{"full_name":"Kim"}'),
  (u('mo'),  'fbc-mo@mail.test',  now(), '{"full_name":"Mo"}'),
  (u('pat'), 'fbc-pat@mail.test', now(), '{"full_name":"Pat"}'),
  (u('rob'), 'fbc-rob@mail.test', now(), '{"full_name":"Rob"}'),
  (u('stl'), 'fbc-stl@mail.test', now(), '{"full_name":"Stl"}'),
  (u('rev'), 'fbc-rev@mail.test', now(), '{"full_name":"Rev"}');
insert into app_private.allowlist(email) values
  ('fbc-ann@mail.test'), ('fbc-bob@mail.test'), ('fbc-cat@mail.test'), ('fbc-eve@mail.test'),
  ('fbc-unc@mail.test'), ('fbc-del@mail.test'), ('fbc-ban@mail.test'), ('fbc-bot@mail.test'),
  ('fbc-kim@mail.test'), ('fbc-mo@mail.test'), ('fbc-pat@mail.test'), ('fbc-rob@mail.test'),
  ('fbc-stl@mail.test'), ('fbc-rev@mail.test');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('5e5e0000-0000-0000-0000-' || right(id::text, 12))::uuid, id, now(), now()
    from auth.users where id::text like '00000000-0000-0000-0000-0000fbc0%';
-- stl's OLD phone, activated first and then replaced by the one above.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('5e5e0000-0000-0000-0000-0000fbcdead0', u('stl'), now() - interval '1 hour', now());
update public.profiles set tag = replace(split_part(
    lower((select email from auth.users x where x.id = user_id)), '@', 1), '-', '_')
 where user_id::text like '00000000-0000-0000-0000-0000fbc0%';

create or replace function test_as(uid uuid, sid text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', coalesce(sid, '5e5e0000-0000-0000-0000-' || right(uid::text, 12)))::text, true);
  execute 'set local role authenticated';
end $$;
-- One call as the current role, the way a client sees it: its own
-- subtransaction, rolled back on error. 'ok:<rows>' or '<sqlstate>:<message>'.
create or replace function try_fbc(hs text[]) returns text language plpgsql as $$
declare n bigint;
begin
  select count(*) into n from public.find_by_contacts(hs);
  return 'ok:' || n;
exception when others then
  return sqlstate || ':' || sqlerrm;
end $$;
-- Everything an error tells the client: message, detail and hint.
create or replace function err_text(hs text[]) returns text language plpgsql as $$
declare m text; d text; t text;
begin
  perform count(*) from public.find_by_contacts(hs);
  return 'no error';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail, t = pg_exception_hint;
  return concat_ws('|', sqlstate, m, d, t);
end $$;
grant execute on function u(text), h(text), test_as(uuid, text), try_fbc(text[]), err_text(text[])
  to authenticated, anon;
-- 'contacts' rate rows of a member, read by the setup role.
create or replace function rate_rows(uid uuid) returns bigint language sql as $$
  select count(*) from app_private.tag_lookups where user_id = uid and kind = 'contacts'
$$;
-- avatar_visible_to as [reader] sees it, asked by the setup role.
create or replace function sees_picture(reader uuid, owner uuid) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', reader, 'role', 'authenticated',
      'session_id', '5e5e0000-0000-0000-0000-' || right(reader::text, 12))::text, true);
  r := app_private.avatar_visible_to(owner);
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

select test_as(u('stl'), '5e5e0000-0000-0000-0000-0000fbcdead0');
select public.activate_session();
reset role;
do $$
declare n text;
begin
  foreach n in array array['ann','bob','cat','eve','unc','nal','del','ban','bot','kim','mo','pat','rob','stl','rev'] loop
    perform test_as(u(n));
    perform public.activate_session();
    execute 'reset role';
  end loop;
end $$;
delete from auth.sessions where user_id = u('rev');
update auth.users set deleted_at = now() - interval '1 day' where id = u('del');
update auth.users set banned_until = now() + interval '30 days' where id = u('ban');
insert into public.conversations(id, title) values ('fbc0c000-0000-0000-0000-000000000001', 'debug');
-- Switched ON: an OFF bot has no app access, which would hide the bot gate.
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
  values (u('bot'), 'fbc0c000-0000-0000-0000-000000000001', true);
-- has_app_access() as the caller sees it, for fixture checks.
create or replace function access() returns boolean language sql security definer set search_path = '' as $$
  select app_private.has_app_access()
$$;
grant execute on function access() to authenticated;

-- Pictures, set by their owners the way the app does.
select test_as(u('bob'));
update public.profiles set avatar_object = 'profile/' || auth.uid() || '/1.jpg',
                           avatar_visibility = 'everyone' where user_id = auth.uid();
reset role;
select test_as(u('cat'));
update public.profiles set avatar_object = 'profile/' || auth.uid() || '/1.jpg',
                           avatar_visibility = 'contacts' where user_id = auth.uid();
reset role;

-- 0 catalog and grants -------------------------------------------------------
select is(pg_get_function_result('public.find_by_contacts(text[])'::regprocedure),
          'TABLE(user_id uuid, display_name text, tag text, avatar_path text, matched_hash text)',
          'the result has exactly the five contract columns, no email');
select ok(not has_function_privilege('anon', 'public.find_by_contacts(text[])', 'EXECUTE'),
          'anon may not execute find_by_contacts');
select ok(not has_function_privilege('public', 'public.find_by_contacts(text[])', 'EXECUTE'),
          'PUBLIC may not execute find_by_contacts');
select ok(has_function_privilege('authenticated', 'public.find_by_contacts(text[])', 'EXECUTE'),
          'members may execute find_by_contacts');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc
            where oid = 'public.find_by_contacts(text[])'::regprocedure),
          'security definer with an empty search_path');
set local role anon;
select throws_ok($$select * from public.find_by_contacts(array[h('fbc-bob@mail.test')])$$,
                 '42501', null, 'anon calling it is refused');
reset role;

-- fixture sanity: before any find, ann cannot reach bob or see his picture
select ok(not sees_picture(u('ann'), u('bob')), 'fixture: ann cannot see bob''s picture yet');

-- 1 matches: one call with every target, every negative, self, a stranger hash
-- and a duplicate. Budget: ann's 1st call.
select test_as(u('ann'));
create temp table ann_rows on commit drop as
  select * from public.find_by_contacts(array[
    h('fbc-bob@mail.test'), h('fbc-cat@mail.test'), h('fbc-eve@mail.test'),
    h('fbc-unc@mail.test'), h('fbc-nal@mail.test'), h('fbc-del@mail.test'),
    h('fbc-ban@mail.test'), h('fbc-bot@mail.test'), h('fbc-ann@mail.test'),
    h('nobody@mail.test'), h('fbc-bob@mail.test')]);
reset role;
select results_eq(
  $$select user_id, display_name, tag, matched_hash from ann_rows order by user_id$$,
  $$values (u('bob'), 'Bob'::text, 'fbc_bob'::text, h('fbc-bob@mail.test')),
           (u('cat'), 'Cat'::text, 'fbc_cat'::text, h('fbc-cat@mail.test')),
           (u('eve'), 'Eve'::text, 'fbc_eve'::text, h('fbc-eve@mail.test'))$$,
  'only confirmed, allowlisted, live, unbanned, human members other than ann match, once each');
select is((select count(*) from ann_rows where user_id = u('unc')), 0::bigint, 'an unconfirmed member is not matched');
select is((select count(*) from ann_rows where user_id = u('nal')), 0::bigint, 'a non-allowlisted member is not matched');
select is((select count(*) from ann_rows where user_id = u('del')), 0::bigint, 'a deleted member is not matched');
select is((select count(*) from ann_rows where user_id = u('ban')), 0::bigint, 'a banned member is not matched');
select is((select count(*) from ann_rows where user_id = u('bot')), 0::bigint, 'a bot is not matched');
select is((select count(*) from ann_rows where user_id = u('ann')), 0::bigint, 'the caller is not matched');
select is((select count(*) from ann_rows where user_id = u('bob')), 1::bigint, 'a hash sent twice gives one row');
select is((select avatar_path from ann_rows where user_id = u('bob')), 'profile/' || u('bob') || '/1.jpg',
          'bob''s ''everyone'' picture is shown: visibility is judged after the find gives reach');
select is((select avatar_path from ann_rows where user_id = u('cat')), null,
          'cat''s ''contacts'' picture is masked: cat never saved ann');
select is((select count(*) from ann_rows
            where concat(user_id, display_name, tag, avatar_path, matched_hash) like '%@%'),
          0::bigint, 'no returned value carries an email');
select is((select count(*) from app_private.tag_finds where finder = u('ann')), 3::bigint,
          'ann''s finds: exactly the three matches');
select is((select array_agg(found_id order by found_id) from app_private.tag_finds where finder = u('ann')),
          array[u('bob'), u('cat'), u('eve')], 'the finds are bob, cat and eve');
select ok(sees_picture(u('ann'), u('bob')), 'after the find ann may see bob''s picture');
select is(rate_rows(u('ann')), 1::bigint, 'ann''s call left one rate row');

-- 1b duplicates collapse
select test_as(u('ann'));
select is((select count(*) from public.find_by_contacts(array[h('fbc-bob@mail.test'), h('fbc-bob@mail.test'), h('fbc-bob@mail.test')])),
          1::bigint, 'three copies of one hash: one row (ann''s 2nd call)');
reset role;

-- 2 error order: bot first ---------------------------------------------------
-- bot: allowlisted, active session, fresh budget, valid input that matches
-- nobody (so no later reach rule can refuse it): only the bot gate.
select test_as(u('bot'));
select ok(access(), 'fixture: the bot has app access, so only the bot gate is in the way');
select throws_ok($$select * from public.find_by_contacts(array[h('nobody@mail.test')])$$,
                 '42501', 'not permitted', 'a bot caller is refused');
select throws_ok($$select * from public.find_by_contacts(array[h('fbc-bob@mail.test')])$$,
                 '42501', 'not permitted', 'a bot caller is refused when the hash matches too');
reset role;
select is((select count(*) from app_private.tag_finds where finder = u('bot')), 0::bigint,
          'the refused bot found nobody');
select is(rate_rows(u('bot')), 0::bigint, 'the refused bot call left no rate row');

-- 3 no app access: 42501, ahead of the budget and of input checks ------------
select test_as(u('stl'), '5e5e0000-0000-0000-0000-0000fbcdead0');
select alike(try_fbc(array[h('fbc-bob@mail.test')]), '42501:%', 'a replaced phone is refused');
select alike(try_fbc(array['NOT-A-HASH']), '42501:%', 'a replaced phone with bad input: 42501, not 22023');
reset role;
select test_as(u('rev'));
select alike(try_fbc(array[h('fbc-bob@mail.test')]), '42501:%', 'a revoked session is refused');
reset role;
select test_as(u('nal'));
select alike(try_fbc(array[h('fbc-bob@mail.test')]), '42501:%', 'a non-allowlisted account is refused');
reset role;
select is((select count(*) from app_private.tag_finds where finder in (u('stl'), u('rev'), u('nal'))),
          0::bigint, 'the refused callers found nobody');
select is((select count(*) from app_private.tag_lookups where user_id in (u('stl'), u('rev'), u('nal'))),
          0::bigint, 'the refused callers left no rate row');

-- 4 hour budget: 3 calls, then RLMT1, ahead of input checks -------------------
select test_as(u('kim'));
select is(try_fbc(array[h('nobody1@mail.test')]), 'ok:0', 'kim: call 1 answers');
select is(try_fbc(array[h('nobody2@mail.test')]), 'ok:0', 'kim: call 2 answers');
select is(try_fbc(array[h('fbc-bob@mail.test')]), 'ok:1', 'kim: call 3 answers');
select is(try_fbc(array[h('fbc-cat@mail.test')]), 'RLMT1:too many searches', 'kim: call 4 is refused');
select alike(try_fbc(array['NOT-A-HASH']), 'RLMT1:%', 'kim: bad input over budget is RLMT1, not 22023');
select alike(try_fbc(null), 'RLMT1:%', 'kim: a null array over budget is RLMT1 too');
reset role;
select is(rate_rows(u('kim')), 3::bigint, 'kim: the refused calls left no rate row');
select is((select count(*) from app_private.tag_finds where finder = u('kim') and found_id = u('cat')),
          0::bigint, 'kim: the refused call found nobody');
update app_private.tag_lookups set called_at = now() - interval '59 minutes' where user_id = u('kim');
select test_as(u('kim'));
select alike(try_fbc(array[h('fbc-cat@mail.test')]), 'RLMT1:%', 'kim: calls 59 minutes old still count');
reset role;
update app_private.tag_lookups set called_at = now() - interval '61 minutes' where user_id = u('kim');
select test_as(u('kim'));
select is(try_fbc(array[h('fbc-cat@mail.test')]), 'ok:1', 'kim: calls 61 minutes old no longer count per hour');
reset role;
select test_as(u('mo'));
select is(try_fbc(array[h('fbc-bob@mail.test')]), 'ok:1', 'mo: kim''s budget is not mo''s');
reset role;

-- 5 day budget: 10 calls per 24 hours ------------------------------------------
-- mo has 1 call now; 8 more just inside the day, outside the hour.
insert into app_private.tag_lookups(user_id, kind, called_at)
  select u('mo'), 'contacts', now() - interval '23 hours 50 minutes' from generate_series(1, 8);
-- Other kinds never spend this budget.
insert into app_private.tag_lookups(user_id, kind, called_at)
  select u('mo'), 'find', now() - interval '2 hours' from generate_series(1, 30);
select test_as(u('mo'));
select is(try_fbc(array[h('fbc-cat@mail.test')]), 'ok:1', 'mo: the 10th call in 24 hours answers');
select is(try_fbc(array[h('fbc-cat@mail.test')]), 'RLMT1:too many searches',
          'mo: the 11th call in 24 hours is refused, with only 2 in the hour');
reset role;
select is(rate_rows(u('mo')), 10::bigint, 'mo: the refused call left no rate row');
update app_private.tag_lookups set called_at = now() - interval '24 hours 10 minutes'
 where user_id = u('mo') and kind = 'contacts';
insert into app_private.tag_lookups(user_id, kind, called_at)
  values (u('mo'), 'contacts', now() - interval '23 hours');
update app_private.tag_lookups set called_at = now() - interval '30 hours'
 where user_id = u('mo') and kind = 'find';
select test_as(u('mo'));
select is(try_fbc(array[h('fbc-cat@mail.test')]), 'ok:1', 'mo: calls older than 24 hours no longer count');
reset role;
select is((select count(*) from app_private.tag_lookups
            where user_id = u('mo') and kind = 'contacts' and called_at < now() - interval '24 hours'),
          0::bigint, 'mo: contacts rows older than 24 hours are pruned');
select is(rate_rows(u('mo')), 2::bigint, 'mo: the 23-hour-old row and the new one are kept');
select is((select count(*) from app_private.tag_lookups where user_id = u('mo') and kind = 'find'),
          30::bigint, 'mo: rows of another kind are left alone');

-- 6 null and empty: no rows, but the call counts ------------------------------
select test_as(u('pat'));
select is(try_fbc(null), 'ok:0', 'pat: a null array gives no rows');
select is(try_fbc(array[]::text[]), 'ok:0', 'pat: an empty array gives no rows');
reset role;
select is(rate_rows(u('pat')), 2::bigint, 'pat: both calls counted');
select test_as(u('pat'));
select is(try_fbc(array[h('fbc-bob@mail.test')]), 'ok:1', 'pat: call 3 answers');
select alike(try_fbc(array[h('fbc-bob@mail.test')]), 'RLMT1:%', 'pat: call 4 is refused');
reset role;

-- 7 bad input: 22023, nothing found, nothing counted, nothing echoed -----------
select test_as(u('rob'));
select is(try_fbc(array(select h('n' || g || '@mail.test') from generate_series(1, 2001) g)),
          '22023:invalid request', 'rob: 2001 elements are refused');
select is(try_fbc(array[h('fbc-bob@mail.test'), null]), '22023:invalid request', 'rob: a null element is refused');
select is(try_fbc(array[h('fbc-bob@mail.test'), upper(h('fbc-cat@mail.test'))]), '22023:invalid request',
          'rob: an upper-case hash is refused, and the valid one beside it finds nobody');
select is(try_fbc(array[left(h('fbc-bob@mail.test'), 63)]), '22023:invalid request', 'rob: 63 characters are refused');
select is(try_fbc(array[h('fbc-bob@mail.test') || '0']), '22023:invalid request', 'rob: 65 characters are refused');
select is(try_fbc(array['g' || right(h('fbc-bob@mail.test'), 63)]), '22023:invalid request', 'rob: a non-hex letter is refused');
select is(try_fbc(array[' ' || h('fbc-bob@mail.test')]), '22023:invalid request', 'rob: a padded hash is refused');
select is(try_fbc(array['fbc-bob@mail.test']), '22023:invalid request', 'rob: a raw email is refused');
select is(strpos(err_text(array['fbc-bob@mail.test']), 'fbc-bob'), 0,
          'rob: the error never echoes a raw email (message, detail, hint)');
select is(strpos(err_text(array[upper(h('fbc-cat@mail.test'))]), upper(h('fbc-cat@mail.test'))), 0,
          'rob: the error never echoes a bad hash');
reset role;
select is(rate_rows(u('rob')), 0::bigint, 'rob: the refused calls left no rate row');
select is((select count(*) from app_private.tag_finds where finder = u('rob')), 0::bigint,
          'rob: the refused calls found nobody');
select test_as(u('rob'));
select is(try_fbc(array(select h('n' || g || '@mail.test') from generate_series(1, 1999) g)
                  || h('fbc-bob@mail.test')),
          'ok:1', 'rob: exactly 2000 elements answer');
select is(try_fbc(array[h('fbc-bob@mail.test')]), 'ok:1', 'rob: call 2 answers');
select is(try_fbc(array[h('fbc-bob@mail.test')]), 'ok:1', 'rob: call 3 answers: the bad calls spent nothing');
select alike(try_fbc(array[h('fbc-bob@mail.test')]), 'RLMT1:%', 'rob: call 4 is refused');
reset role;

select * from finish();
rollback;
