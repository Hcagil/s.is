begin;
select plan(32);

-- conversation_previews and the messages_read policy, after they were made
-- to scale with the caller's own conversations instead of the whole message
-- history. Three things are pinned here:
--
--  1. the view returns exactly what it always did: one row per conversation
--     the caller is a member of, carrying its newest message that has not
--     vanished (a placeholder still counts); never a row per fellow member,
--     never another member's conversations, nothing without app access;
--  2. messages_read refuses exactly who it refused before;
--  3. with a few thousand messages of history, the view and the history read
--     reach public.messages through its (conversation_id, created_at) index,
--     bounded to the conversation, never by scanning the table. Plan text,
--     not timings.
--
-- Fixtures: ada, ben, cid, dee share a group; ada+ben, cid+dee, ada+dee have
-- direct chats; ada+cid have a chat whose only message vanished; ada+ben a
-- group with no messages at all. eli is allowlisted and active but in no
-- conversation. fay has a session but is not allowlisted (no app access).
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000b001', 'ada@qi.test', now(), '{"full_name":"Ada"}'),
  ('00000000-0000-0000-0000-00000000b002', 'ben@qi.test', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-00000000b003', 'cid@qi.test', now(), '{"full_name":"Cid"}'),
  ('00000000-0000-0000-0000-00000000b004', 'dee@qi.test', now(), '{"full_name":"Dee"}'),
  ('00000000-0000-0000-0000-00000000b005', 'eli@qi.test', now(), '{"full_name":"Eli"}'),
  ('00000000-0000-0000-0000-00000000b006', 'fay@qi.test', now(), '{"full_name":"Fay"}');
insert into app_private.allowlist(email) values
  ('ada@qi.test'), ('ben@qi.test'), ('cid@qi.test'), ('dee@qi.test'), ('eli@qi.test');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('b0000000-0000-0000-0000-00000000b00' || n)::uuid,
         ('00000000-0000-0000-0000-00000000b00' || n)::uuid, now(), now()
    from generate_series(1, 6) n;

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- as(n): user b00n with session b00n.
create or replace function as_qi(n int) returns void language sql as $$
  select test_as(('00000000-0000-0000-0000-00000000b00' || n)::uuid,
                 'b0000000-0000-0000-0000-00000000b00' || n)
$$;

-- The caller's preview rows, compact and ordered: "title:body:sender:deleted".
create or replace function previews() returns text language sql as $$
  select coalesce(string_agg(format('%s:%s:%s:%s', c.title, p.body,
                                    right(p.sender_id::text, 1), coalesce(p.deleted, '-')),
                             ' | ' order by c.title), '')
    from public.conversation_previews p join public.conversations c on c.id = p.conversation_id
$$;

-- EXPLAIN of [q], as text.
create or replace function plan_of(q text) returns text language plpgsql as $$
declare r record; t text := '';
begin
  for r in execute 'explain (costs off) ' || q loop
    t := t || r."QUERY PLAN" || E'\n';
  end loop;
  return t;
end $$;
grant execute on function test_as(uuid, text), as_qi(int), previews(), plan_of(text) to authenticated;

select as_qi(1); select is(public.activate_session(), true, 'ada is active'); reset role;
select as_qi(2); select is(public.activate_session(), true, 'ben is active'); reset role;
select as_qi(3); select is(public.activate_session(), true, 'cid is active'); reset role;
select as_qi(4); select is(public.activate_session(), true, 'dee is active'); reset role;
select as_qi(5); select is(public.activate_session(), true, 'eli is active'); reset role;

-- Conversations and members, written as the owner. The title names each one
-- (a direct chat has no title in the app; here it only labels the fixture).
insert into public.conversations(id, title) values
  ('c0000000-0000-0000-0000-00000000c001', 'club'),     -- ada ben cid dee
  ('c0000000-0000-0000-0000-00000000c002', 'ada-ben'),  -- newest vanished
  ('c0000000-0000-0000-0000-00000000c003', 'cid-dee'),
  ('c0000000-0000-0000-0000-00000000c004', 'ada-dee'),  -- newest is a placeholder
  ('c0000000-0000-0000-0000-00000000c005', 'ada-cid'),  -- only message vanished
  ('c0000000-0000-0000-0000-00000000c006', 'quiet');    -- ada ben, no messages
insert into public.conversation_members(conversation_id, user_id)
  select ('c0000000-0000-0000-0000-00000000c00' || c)::uuid,
         ('00000000-0000-0000-0000-00000000b00' || u)::uuid
    from (values (1,1),(1,2),(1,3),(1,4),(2,1),(2,2),(3,3),(3,4),(4,1),(4,4),(5,1),(5,3),(6,1),(6,2)) m(c, u);

-- Messages as the owner: created_at is withheld from clients, and distinct
-- times make "the newest" decidable.
insert into public.messages(conversation_id, sender_id, body, created_at, deleted, deleted_at) values
  ('c0000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-00000000b002', 'club old',    now() - interval '5 hours', null, null),
  ('c0000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-00000000b003', 'club newest', now() - interval '1 hour', null, null),
  ('c0000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-00000000b001', 'ab kept',     now() - interval '4 hours', null, null),
  ('c0000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-00000000b002', '',            now() - interval '2 hours', 'vanished', now()),
  ('c0000000-0000-0000-0000-00000000c003', '00000000-0000-0000-0000-00000000b004', 'cd newest',   now() - interval '3 hours', null, null),
  ('c0000000-0000-0000-0000-00000000c004', '00000000-0000-0000-0000-00000000b004', 'ad older',    now() - interval '6 hours', null, null),
  ('c0000000-0000-0000-0000-00000000c004', '00000000-0000-0000-0000-00000000b001', '',            now() - interval '30 minutes', 'placeholder', now()),
  ('c0000000-0000-0000-0000-00000000c005', '00000000-0000-0000-0000-00000000b003', '',            now() - interval '10 minutes', 'vanished', now());

-- 1 the view's rows, per caller ---------------------------------------------
select as_qi(1);
select is(previews(), 'ada-ben:ab kept:1:- | ada-dee::1:placeholder | club:club newest:3:-',
  'ada: one row per conversation she is in, its newest non-vanished message; '
  'a vanished-only and an empty conversation give none');
reset role;
select as_qi(2);
select is(previews(), 'ada-ben:ab kept:1:- | club:club newest:3:-', 'ben: club and ada-ben, nothing of ada''s other chats');
reset role;
select as_qi(3);
select is(previews(), 'cid-dee:cd newest:4:- | club:club newest:3:-', 'cid: club and cid-dee');
reset role;
select as_qi(4);
select is(previews(), 'ada-dee::1:placeholder | cid-dee:cd newest:4:- | club:club newest:3:-', 'dee: club, cid-dee and ada-dee');
reset role;

-- 2 a group of four: exactly one row for each of its members ---------------
-- Security-lead's ask: never one row per fellow member.
select as_qi(1); select is((select count(*) from public.conversation_previews where conversation_id = 'c0000000-0000-0000-0000-00000000c001'), 1::bigint, 'ada: one club row, not one per member'); reset role;
select as_qi(2); select is((select count(*) from public.conversation_previews where conversation_id = 'c0000000-0000-0000-0000-00000000c001'), 1::bigint, 'ben: one club row'); reset role;
select as_qi(3); select is((select count(*) from public.conversation_previews where conversation_id = 'c0000000-0000-0000-0000-00000000c001'), 1::bigint, 'cid: one club row'); reset role;
select as_qi(4); select is((select count(*) from public.conversation_previews where conversation_id = 'c0000000-0000-0000-0000-00000000c001'), 1::bigint, 'dee: one club row'); reset role;

-- 3 callers who get nothing -------------------------------------------------
select as_qi(5);
select is((select count(*) from public.conversation_previews), 0::bigint, 'eli (active, in no conversation) gets no rows');
reset role;
select as_qi(6);
select is((select count(*) from public.conversation_previews), 0::bigint, 'fay (session, not allowlisted) gets no rows');
reset role;
set local role anon;
select throws_ok($$select count(*) from public.conversation_previews$$, '42501', null, 'anon cannot read the view');
reset role;

-- 4 messages_read refuses exactly who it did --------------------------------
select as_qi(1);
select is((select count(*) from public.messages where conversation_id = 'c0000000-0000-0000-0000-00000000c001'), 2::bigint, 'a member reads her group''s messages');
select is((select count(*) from public.messages where conversation_id = 'c0000000-0000-0000-0000-00000000c003'), 0::bigint, 'an active non-member reads nothing of cid-dee');
reset role;
select as_qi(6);
select is((select count(*) from public.messages), 0::bigint, 'no app access (not allowlisted): no messages at all');
reset role;
-- A member whose app access is gone: the membership half would pass, so only
-- the has_app_access() half can refuse her.
insert into public.conversation_members(conversation_id, user_id) values ('c0000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-00000000b006');
select as_qi(6);
select is((select count(*) from public.messages where conversation_id = 'c0000000-0000-0000-0000-00000000c001'), 0::bigint, 'a member without app access reads none of her group''s messages');
select is((select count(*) from public.conversation_previews), 0::bigint, 'nor its preview');
reset role;
select ok((select qual from pg_policies where schemaname = 'public' and tablename = 'messages' and policyname = 'messages_read')
            ~* '\(\s*select\s+app_private\.has_app_access\(\)',
          'messages_read wraps has_app_access() in a scalar subquery: evaluated once per query');

-- 5 with a few thousand messages, the index does the work --------------------
-- A plain or bitmap index scan both count; what must not appear is a scan of
-- the table, or an index scan with no condition (the whole index, in order).
-- 80 more conversations of 40 messages each (3200 rows); ada is in 8 of them.
-- Triggers off for the bulk insert only (push fan-out is not under test).
set local session_replication_role = replica;
insert into public.conversations(id, title)
  select ('d0000000-0000-0000-0000-0000000' || lpad(g::text, 5, '0'))::uuid, 'bulk ' || g
    from generate_series(1, 80) g;
insert into public.conversation_members(conversation_id, user_id)
  select ('d0000000-0000-0000-0000-0000000' || lpad(g::text, 5, '0'))::uuid, u
    from generate_series(1, 80) g,
         lateral (values ('00000000-0000-0000-0000-00000000b002'::uuid),
                         ('00000000-0000-0000-0000-00000000b003'::uuid),
                         (case when g % 10 = 0 then '00000000-0000-0000-0000-00000000b001'::uuid
                               else '00000000-0000-0000-0000-00000000b004'::uuid end)) v(u);
insert into public.messages(conversation_id, sender_id, body, created_at)
  select ('d0000000-0000-0000-0000-0000000' || lpad(g::text, 5, '0'))::uuid,
         '00000000-0000-0000-0000-00000000b002', 'bulk ' || g || '/' || i,
         now() - make_interval(mins => g * 100 + i)
    from generate_series(1, 80) g, generate_series(1, 40) i;
set local session_replication_role = origin;
analyze public.messages;
analyze public.conversation_members;
analyze public.conversations;

-- The view still says the same thing at scale, for a member of many
-- conversations: compared to the plain "newest non-vanished message per
-- conversation I am in", written independently of the view.
create temp table ref_ada as
  select distinct on (m.conversation_id) m.conversation_id, m.body, m.sender_id, m.created_at, m.deleted
    from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = '00000000-0000-0000-0000-00000000b001'
   where m.deleted is distinct from 'vanished'
   order by m.conversation_id, m.created_at desc;
grant select on ref_ada to authenticated;
select as_qi(1);
select set_eq($$select conversation_id, body, sender_id, created_at, deleted from public.conversation_previews$$,
              $$select conversation_id, body, sender_id, created_at, deleted from ref_ada$$,
              'at scale ada gets exactly the newest non-vanished message of each of her 11 conversations');
select is((select count(*) from public.conversation_previews), 11::bigint, '3 fixture + 8 bulk conversations with messages');
reset role;

create temp table idx as
  select indexrelid::regclass::text as name
    from pg_index
   where indrelid = 'public.messages'::regclass
     and pg_get_indexdef(indexrelid) ~ '\(conversation_id, created_at';
grant select on idx to authenticated;
select is((select count(*) from idx), 1::bigint, 'public.messages has its (conversation_id, created_at) index');

select as_qi(1);
create temp table plans as select
  plan_of('select * from public.conversation_previews') as view_plan,
  plan_of($$select * from public.messages where conversation_id = 'd0000000-0000-0000-0000-000000000010'
            order by created_at desc limit 50$$) as history_plan;
reset role;

select unalike((select view_plan from plans), '%Seq Scan on messages%', 'the view does not scan public.messages');
select ok((select view_plan ~ ('(Index (Only )?Scan( Backward)? using|Bitmap Index Scan on) ' || (select name from idx) || '\M')
             from plans),
          'the view reaches public.messages through its (conversation_id, created_at) index');
select ok((select view_plan ~ 'Index Cond: \(conversation_id = ' from plans),
          'the view''s index scan is bounded to one conversation at a time, not the whole index');
select unalike((select history_plan from plans), '%Seq Scan on messages%', 'the history read does not scan public.messages');
select ok((select history_plan ~ ('(Index (Only )?Scan( Backward)? using|Bitmap Index Scan on) ' || (select name from idx) || '\M')
                  and history_plan ~ 'Index Cond: \(conversation_id = '
             from plans),
          'the history read uses the index, bounded to its conversation');

select ok((select history_plan !~ 'Filter: [^\n]*has_app_access\(\)' from plans),
          'the history read checks has_app_access() once (an InitPlan), not in its per-row filter');

-- 6 a delisted member loses the view at once (security-lead's ask) ----------
-- Her session is still active; only the allowlist changed.
delete from app_private.allowlist where email = 'ada@qi.test';
select as_qi(1);
select is((select count(*) from public.conversation_previews), 0::bigint, 'ada, delisted with an active session, gets no rows');
reset role;

select * from finish();
rollback;
