begin;
select plan(62);
-- The plan checks below read planner statistics this transaction writes
-- with ANALYZE. A concurrent (auto)vacuum of messages would overwrite
-- pg_class.reltuples in place, mid-test; holding this lock keeps it out.
lock table public.messages in share update exclusive mode;

-- public.search_messages(query, conversation) (v0.16): message search across
-- all history, written from its contract:
--
--  * case-insensitive and Turkish-safe: I, İ and ı all fold to i;
--  * substring match; %, _ and \ are literal, never wildcards;
--  * a trimmed query under two characters returns no rows and no error;
--  * scoped to [conversation] when given, else every conversation the caller
--    is a member of; a conversation the caller is not in -- or that does not
--    exist -- never contributes a row, omitted or passed explicitly;
--  * a caller without app access (not allowlisted, or a replaced session)
--    gets nothing;
--  * deleted (vanished or placeholder) and textless messages never match; an
--    edited message matches its current text only;
--  * newest first, at most 50;
--  * a member's search reaches public.messages through the trigram index,
--    never a sequential scan of the table.
--
-- Each refusal fixture fails exactly one gate:
--   eli is allowlisted and active -- only membership can hide ada's rows;
--   dee is a member of 'main' whose session was replaced by a newer one --
--     only app access can stop her, and the newer session proves it;
--   fay is a member of 'main' with a session but not allowlisted;
--   gus is a member of 'main', was active, and was then delisted.
--
-- Fixtures:
--   main  (ada ben dee fay)  the text cases
--   pair  (ada cid)          one istanbul, for scoping
--   eli   (eli ben)          eli's own istanbul: his search does work
--   other (ben cid)          an istanbul ada is not in
--   big   (ada ben)          6000 fillers: the limit, the order and the plan
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000a5001', 'ada@search.test', now(), '{"full_name":"Ada"}'),
  ('00000000-0000-0000-0000-0000000a5002', 'ben@search.test', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-0000000a5003', 'cid@search.test', now(), '{"full_name":"Cid"}'),
  ('00000000-0000-0000-0000-0000000a5004', 'dee@search.test', now(), '{"full_name":"Dee"}'),
  ('00000000-0000-0000-0000-0000000a5005', 'eli@search.test', now(), '{"full_name":"Eli"}'),
  ('00000000-0000-0000-0000-0000000a5006', 'fay@search.test', now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-0000000a5008', 'gus@search.test', now(), '{"full_name":"Gus"}');
insert into app_private.allowlist(email) values
  ('ada@search.test'), ('ben@search.test'), ('cid@search.test'),
  ('dee@search.test'), ('eli@search.test'), ('gus@search.test');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('a5000000-0000-0000-0000-0000000a500' || n)::uuid,
         ('00000000-0000-0000-0000-0000000a500' || n)::uuid, now(), now()
    from (values (1), (2), (3), (4), (5), (6), (8)) v(n);
-- dee's newer device.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a5000000-0000-0000-0000-0000000a5007', '00000000-0000-0000-0000-0000000a5004', now() + interval '1 minute', now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- as_s(n): user a500n with session a500n.
create or replace function as_s(n int) returns void language sql as $$
  select test_as(('00000000-0000-0000-0000-0000000a500' || n)::uuid,
                 'a5000000-0000-0000-0000-0000000a500' || n)
$$;

-- The bodies search_messages returns, in the order it returns them. A refusal
-- (42501) is "nothing" too, reported as '<denied>' so it can be told apart.
create or replace function hits(q text, conv uuid default null) returns text
language plpgsql as $$
declare t text;
begin
  select coalesce(string_agg(s.body, ' | ' order by s.n), '') into t
    from public.search_messages(q, conv) with ordinality as s(id, conversation_id, sender_id, body,
      created_at, attachment_path, attachment_preview, deleted, reply_to, forwarded, edited_at, n);
  return t;
exception when insufficient_privilege then
  return '<denied>';
end $$;

create or replace function hit_count(q text, conv uuid default null) returns bigint
language sql as $$ select count(*) from public.search_messages(q, conv) $$;

grant execute on function test_as(uuid, text), as_s(int), hits(text, uuid), hit_count(text, uuid)
  to authenticated;

select as_s(1); select is(public.activate_session(), true, 'ada is active'); reset role;
select as_s(2); select is(public.activate_session(), true, 'ben is active'); reset role;
select as_s(3); select is(public.activate_session(), true, 'cid is active'); reset role;
select as_s(4); select is(public.activate_session(), true, 'dee is active on her first device'); reset role;
select as_s(5); select is(public.activate_session(), true, 'eli is active'); reset role;
select as_s(8); select is(public.activate_session(), true, 'gus is active'); reset role;
delete from app_private.allowlist where email = 'gus@search.test';
select test_as('00000000-0000-0000-0000-0000000a5004', 'a5000000-0000-0000-0000-0000000a5007');
select is(public.activate_session(), true, 'dee''s newer device takes over');
reset role;

insert into public.conversations(id, title) values
  ('a5c00000-0000-0000-0000-000000000001', 'main'),
  ('a5c00000-0000-0000-0000-000000000002', 'pair'),
  ('a5c00000-0000-0000-0000-000000000003', 'eli'),
  ('a5c00000-0000-0000-0000-000000000004', 'other'),
  ('a5c00000-0000-0000-0000-000000000005', 'big');
insert into public.conversation_members(conversation_id, user_id)
  select ('a5c00000-0000-0000-0000-00000000000' || c)::uuid,
         ('00000000-0000-0000-0000-0000000a500' || u)::uuid
    from (values (1,1),(1,2),(1,4),(1,6),(1,8),(2,1),(2,3),(3,5),(3,2),(4,2),(4,3),(5,1),(5,2)) m(c, u);

-- As the owner: created_at is withheld from clients, and distinct times make
-- "newest first" decidable. Minutes before now; bigger is older.
create temp table _m (tag text primary key, id uuid) on commit drop;
grant all on _m to authenticated;
with rows(tag, conv, sender, body, mins) as (values
  ('ist_cap',   1, 2, 'İstanbul trip',            100),
  ('ist_upper', 1, 1, 'ISTANBUL again',            90),
  ('ist_dotless',1,2, 'ıstanbul typo',             80),
  ('ist_lower', 1, 1, 'going to istanbul',         70),
  ('dinner',    1, 2, 'dinner at eight',           60),
  ('pct',       1, 1, 'code 1%e ok',               59),
  ('pct_decoy', 1, 1, '100 percent',               58),
  ('pct2',      1, 2, '100% sure',                 58.5),
  ('und',       1, 2, 'file_a.txt',                57),
  ('und_decoy', 1, 2, 'fileXa.txt',                56),
  ('und2',      1, 1, 'a_b',                       57.5),
  ('und2_decoy',1, 1, 'axb',                       56.5),
  ('bsl',       1, 1, 'path\to',                   55),
  ('bsl_decoy', 1, 1, 'pathto',                    54),
  ('bsl2',      1, 2, 'C:\sys',                    55.5),
  ('bsl2_decoy',1, 2, 'plain sys',                 54.5),
  ('edited',    1, 1, 'old wording here',          53),
  ('del_place', 1, 1, 'placeholder quokka',        52),
  ('del_van',   1, 2, 'vanished quokka',           51),
  ('pair_ist',  2, 3, 'İstanbul in pair',          40),
  ('eli_ist',   3, 2, 'istanbul for eli',          30),
  ('other_ist', 4, 3, 'istanbul secret',           20)
), ins as (
  insert into public.messages(conversation_id, sender_id, body, created_at)
  select ('a5c00000-0000-0000-0000-00000000000' || conv)::uuid,
         ('00000000-0000-0000-0000-0000000a500' || sender)::uuid,
         body, now() - make_interval(secs => mins * 60)
    from rows
  returning id, body
)
insert into _m select r.tag, i.id from rows r join ins i on i.body = r.body;

-- A photo with no caption, and one whose caption is its text.
insert into public.messages(conversation_id, sender_id, body, attachment_path, created_at) values
  ('a5c00000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000a5001', '',
   'a5c00000-0000-0000-0000-000000000001/bare.jpg', now() - interval '50 minutes'),
  ('a5c00000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000a5001', 'wombat caption',
   'a5c00000-0000-0000-0000-000000000001/cap.jpg', now() - interval '49 minutes');

-- Deleted for everyone: the server empties the row and marks it.
update public.messages set body = '', deleted = 'placeholder', deleted_at = now()
 where id = (select id from _m where tag = 'del_place');
update public.messages set body = '', deleted = 'vanished', deleted_at = now()
 where id = (select id from _m where tag = 'del_van');
-- Edited: only the latest body survives.
update public.messages set body = 'new phrasing here', edited_at = now()
 where id = (select id from _m where tag = 'edited');

-- A long history for ada and ben.
insert into public.messages(conversation_id, sender_id, body, created_at)
  select 'a5c00000-0000-0000-0000-000000000005',
         ('00000000-0000-0000-0000-0000000a500' || (1 + g % 2))::uuid,
         'filler ' || g || ' lorem ipsum dolor', now() - make_interval(days => 1, secs => g)
    from generate_series(1, 6000) g;
analyze public.messages;
analyze public.conversation_members;
analyze public.conversations;

-- 1 the Turkish fold and case -----------------------------------------------
select as_s(1);
select is(hits('istanbul', 'a5c00000-0000-0000-0000-000000000001'),
  'going to istanbul | ıstanbul typo | ISTANBUL again | İstanbul trip',
  '"istanbul" finds İstanbul, ISTANBUL and ıstanbul, newest first');
select is(hits('İSTANBUL', 'a5c00000-0000-0000-0000-000000000001'),
  'going to istanbul | ıstanbul typo | ISTANBUL again | İstanbul trip',
  '"İSTANBUL" finds every spelling too');
select is(hits('ıstanbul', 'a5c00000-0000-0000-0000-000000000001'),
  'going to istanbul | ıstanbul typo | ISTANBUL again | İstanbul trip',
  '"ıstanbul" finds every spelling too');
select is(hits('DINNER', 'a5c00000-0000-0000-0000-000000000001'), 'dinner at eight',
  'case-insensitive outside the Turkish letters');
select is(hits('din'), 'dinner at eight', 'a substring matches: "din" finds "dinner"');
select is(hits('  din  '), 'dinner at eight', 'the query is trimmed before it is matched');

-- 2 wildcards are literal ---------------------------------------------------
select is(hits('1%e'), 'code 1%e ok', '% matches a percent sign only, not "anything"');
select is(hits('e_a'), 'file_a.txt', '_ matches an underscore only, not "one character"');
select is(hits('h\t'), 'path\to', '\ matches a backslash only, it escapes nothing');
select is(hits('0%'), '100% sure', '"0%" finds only "100% sure", not "100 percent"');
select is(hits('a_'), 'a_b', '"a_" finds "a_b", not "axb"');
select is(hits('\s'), 'C:\sys', '"\s" matches a literal backslash, not "s" alone');
select is(hits('%%'), '', 'a query of wildcards alone matches nothing');
select is(hits('__'), '', 'nor does a query of underscores alone');

-- 3 short queries -------------------------------------------------------------
select lives_ok($$select public.search_messages('i')$$, 'a one-character query is not an error');
select is(hit_count('i'), 0::bigint, 'one character: no rows');
select is(hit_count(' i '), 0::bigint, 'one character once trimmed: no rows');
select is(hit_count(''), 0::bigint, 'empty: no rows');
select is(hit_count('     '), 0::bigint, 'blank: no rows');
select is(hit_count('in', 'a5c00000-0000-0000-0000-000000000001') > 0, true,
  'two characters do search (control for the above)');

-- 4 deleted, textless and edited messages -------------------------------------
select is(hits('quokka'), '', 'a message deleted for everyone never matches, vanished or placeholder');
select is(hits('old wording'), '', 'an edited message does not match its old text');
select is(hits('new phrasing'), 'new phrasing here', 'an edited message matches its current text');
select is(hits('wombat'), 'wombat caption', 'a photo''s caption is its text');
select is((select count(*) from public.search_messages('jpg')), 0::bigint,
  'a photo is not found by its storage key: only text is searched');

-- 5 scope ---------------------------------------------------------------------
select is(hits('istanbul', 'a5c00000-0000-0000-0000-000000000002'), 'İstanbul in pair',
  'a conversation given: only its messages');
select is(hits('istanbul'),
  'İstanbul in pair | going to istanbul | ıstanbul typo | ISTANBUL again | İstanbul trip',
  'none given: every conversation ada is in, newest first, and none she is not');
select is(hits('istanbul', 'a5c00000-0000-0000-0000-000000000004'), '',
  'ada passing a conversation she is not in gets nothing from it');
select is(hits('istanbul', 'a5c00000-0000-0000-0000-00000000ffff'), '',
  'a conversation that does not exist gives nothing');
reset role;

-- 6 membership: eli has app access, only membership stands in his way --------
select as_s(5);
select is(hits('istanbul'), 'istanbul for eli', 'eli''s search works: his own conversation');
select is(hits('istanbul', 'a5c00000-0000-0000-0000-000000000001'), '',
  'eli naming a conversation he is not in gets none of it');
select is(hits('dinner'), '', 'eli, omitting it, gets nothing of ada''s either');
reset role;
select as_s(2);
select is(hits('istanbul', 'a5c00000-0000-0000-0000-000000000004'), 'istanbul secret',
  'ben, a member of "other", does find its message (control for ada)');
reset role;

-- 7 app access ------------------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000a5004', 'a5000000-0000-0000-0000-0000000a5007');
select is(hits('dinner', 'a5c00000-0000-0000-0000-000000000001'), 'dinner at eight',
  'dee on her active device finds it (control: she is a member)');
reset role;
select as_s(4);
select is(hits('dinner', 'a5c00000-0000-0000-0000-000000000001') in ('', '<denied>'), true,
  'dee on her replaced device gets nothing, scoped');
select is(hits('dinner') in ('', '<denied>'), true, 'nor unscoped');
reset role;
select as_s(6);
select is(hits('dinner', 'a5c00000-0000-0000-0000-000000000001') in ('', '<denied>'), true,
  'fay, a member but not allowlisted, gets nothing, scoped');
select is(hits('dinner') in ('', '<denied>'), true, 'nor unscoped');
reset role;
select as_s(8);
select is(hits('dinner', 'a5c00000-0000-0000-0000-000000000001') in ('', '<denied>'), true,
  'gus, a member delisted after he was active, gets nothing, scoped');
select is(hits('dinner') in ('', '<denied>'), true, 'nor unscoped');
reset role;
set local role anon;
select throws_ok($$select public.search_messages('dinner')$$, '42501', null,
  'anon cannot run search_messages');
reset role;

-- 8 limit and order ---------------------------------------------------------------
select as_s(1);
select is(hit_count('filler'), 50::bigint, 'at most 50 hits');
select is(hit_count('lorem', 'a5c00000-0000-0000-0000-000000000005'), 50::bigint, 'at most 50, scoped too');
select is(
  (select bool_and(prev is null or prev > created_at)
     from (select created_at, lag(created_at) over (order by n) prev
             from public.search_messages('filler') with ordinality as s(id, conversation_id, sender_id,
               body, created_at, attachment_path, attachment_preview, deleted, reply_to, forwarded,
               edited_at, n)) x),
  true, 'strictly newest first');
select is((select body from public.search_messages('filler') limit 1), 'filler 1 lorem ipsum dolor',
  'the first hit is the newest of all');
select is((select min(created_at) from public.search_messages('filler')),
  (select created_at from public.messages where body = 'filler 50 lorem ipsum dolor'),
  'the 50 are the newest 50, not any 50');
reset role;

-- 9 equivalence with row-level security ------------------------------------------
-- search_messages is SECURITY DEFINER: it reads past messages_read and must
-- re-apply both of its gates itself. For every kind of caller, its rows are
-- exactly the rows a plain select under messages_read returns for the same
-- term (folded as the contract folds). Drift in either gate turns this red.
create or replace function rls_ids(q text) returns text language sql as $$
  select coalesce(string_agg(id::text, ',' order by id), '')
    from public.messages
   where deleted is null
     and strpos(lower(translate(body, 'İIı', 'iii')), lower(translate(btrim(q), 'İIı', 'iii'))) > 0
$$;
create or replace function search_ids(q text) returns text language plpgsql as $$
declare t text;
begin
  select coalesce(string_agg(id::text, ',' order by id), '') into t from public.search_messages(q);
  return t;
exception when insufficient_privilege then
  return '';
end $$;
grant execute on function rls_ids(text), search_ids(text) to authenticated;

create temp table _eq (who text, term text, rls text, search text) on commit drop;
grant all on _eq to authenticated;
create or replace function eq_as(who text, uid uuid, sid text) returns void language plpgsql as $$
begin
  perform test_as(uid, sid);
  insert into _eq select who, t, rls_ids(t), search_ids(t)
    from unnest(array['istanbul', 'dinner', 'secret', 'phrasing', '0%', 'a_']) t;
  execute 'reset role';
end $$;
select eq_as('ada (member)',       '00000000-0000-0000-0000-0000000a5001', 'a5000000-0000-0000-0000-0000000a5001');
select eq_as('ben (member)',       '00000000-0000-0000-0000-0000000a5002', 'a5000000-0000-0000-0000-0000000a5002');
select eq_as('eli (non-member)',   '00000000-0000-0000-0000-0000000a5005', 'a5000000-0000-0000-0000-0000000a5005');
select eq_as('dee (replaced)',     '00000000-0000-0000-0000-0000000a5004', 'a5000000-0000-0000-0000-0000000a5004');
select eq_as('fay (never listed)', '00000000-0000-0000-0000-0000000a5006', 'a5000000-0000-0000-0000-0000000a5006');
select eq_as('gus (delisted)',     '00000000-0000-0000-0000-0000000a5008', 'a5000000-0000-0000-0000-0000000a5008');
select is((select string_agg(who || ' ' || term, '; ') from _eq where rls is distinct from search), null,
  'for every caller and term, search_messages returns exactly what messages_read lets them select');
select is((select count(distinct term) from _eq where (who like 'ada%' or who like 'ben%') and rls <> ''), 6::bigint,
  'the equivalence is not vacuous: the members have rows for every term');
select is((select count(*) from _eq where who like 'dee%' and rls <> '') + (select count(*) from _eq where who like 'eli%' and rls <> ''),
  1::bigint, 'and the refused callers have none (eli''s one: "istanbul" in his own chat)');
reset role;

-- 10 the plan: a member's search reaches messages through the trigram index -------
-- Counted from this transaction's own statistics, which cover the statements
-- inside the function too -- an EXPLAIN of the call would show only a
-- Function Scan.
create temp table _scans (what text primary key, seq bigint, trgm bigint) on commit drop;
insert into _scans values ('before',
  pg_stat_get_xact_numscans('public.messages'::regclass),
  pg_stat_get_xact_numscans('public.messages_search_trgm_idx'::regclass));
select as_s(1); select hit_count('istanbul'); reset role;
insert into _scans values ('unscoped',
  pg_stat_get_xact_numscans('public.messages'::regclass),
  pg_stat_get_xact_numscans('public.messages_search_trgm_idx'::regclass));
select as_s(1); select hit_count('istanbul', 'a5c00000-0000-0000-0000-000000000005'); reset role;
insert into _scans values ('scoped',
  pg_stat_get_xact_numscans('public.messages'::regclass),
  pg_stat_get_xact_numscans('public.messages_search_trgm_idx'::regclass));
select is((select a.trgm > b.trgm from _scans a, _scans b where a.what = 'unscoped' and b.what = 'before'),
  true, 'an unscoped search uses messages_search_trgm_idx');
select is((select a.seq - b.seq from _scans a, _scans b where a.what = 'unscoped' and b.what = 'before'),
  0::bigint, 'an unscoped search never scans messages sequentially');
select is((select a.seq - b.seq from _scans a, _scans b where a.what = 'scoped' and b.what = 'unscoped'),
  0::bigint, 'a scoped search never scans messages sequentially');

-- 11 the plan's shape: the pattern is computed once, not per row -----------------
-- search_messages' own query, planned the way a SQL function body is planned
-- (parameters as parameters: a generic plan), run as its owner with ada's
-- claims. The LIKE pattern must be an InitPlan -- computed once -- so the
-- Recheck Cond and Filter never call escape_like/fold_search for every
-- candidate row, and the unscoped search still starts from the trigram index.
create or replace function plan_of(q text) returns text language plpgsql as $$
declare r record; t text := '';
begin
  for r in execute 'explain (costs off) ' || q loop
    t := t || r."QUERY PLAN" || E'\n';
  end loop;
  return t;
end $$;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000a5001', 'role', 'authenticated',
    'email', 'ada@search.test', 'session_id', 'a5000000-0000-0000-0000-0000000a5001')::text, true);
select set_config('plan_cache_mode', 'force_generic_plan', true);
do $$
begin
  execute 'prepare search_body(text, uuid) as ' || (
    select regexp_replace(regexp_replace(prosrc, '\mquery\M', '$1', 'g'), '\mconversation\M', '$2', 'g')
      from pg_proc where oid = 'public.search_messages'::regproc);
end $$;
create temp table _plans (what text primary key, plan text) on commit drop;
insert into _plans values
  ('unscoped', plan_of($$execute search_body('istanbul', null)$$)),
  ('scoped', plan_of($$execute search_body('istanbul', 'a5c00000-0000-0000-0000-000000000001')$$));
deallocate search_body;
select ok((select bool_and(plan ~ '\n\s*Recheck Cond: \(\(search_text ~~ (like_escape\()?\(InitPlan \d+\)\.col1') from _plans),
  'the Recheck Cond compares search_text to an InitPlan: the pattern is computed once per search');
select ok((select plan ~ 'Bitmap Index Scan on messages_search_trgm_idx' from _plans where what = 'unscoped'),
  'an unscoped search starts from messages_search_trgm_idx');
select is((select string_agg(what || ': ' || line, E'\n')
             from _plans, regexp_split_to_table(plan, E'\n') line
            where line ~ '^\s*(Recheck Cond|Filter|Index Cond):'
              and line ~ '(escape_like|fold_search|btrim)'),
  null,
  'no Recheck Cond, Filter or Index Cond evaluates escape_like/fold_search per row');

select * from finish();
rollback;
