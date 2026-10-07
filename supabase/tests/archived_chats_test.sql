-- Archived chats: public.chat_archives, its policies, and the two places
-- archiving is felt on the server: the badge count (unread_total) and the
-- push delivery list (push_targets_for_message). unread_counts() is NOT
-- changed: the Archived screen still shows per-chat counts.
--
-- ana (1) is the subject; ben (2) writes to her; cem (3) is the control.
--   D1 ana<->ben   2 unread from ben
--   D2 ben<->cem   ana never a member
--   G  ben, ana, cem
-- Each refused insert fails exactly one clause of the policy: an insert for
-- another user_id targets a chat that user IS in; a non-member insert uses
-- ana's own user_id.
begin;
select plan(35);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ac001', 'ac-ana@example.com', now(), '{"full_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000ac002', 'ac-ben@example.com', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-0000000ac003', 'ac-cem@example.com', now(), '{"full_name":"Cem"}');
insert into app_private.allowlist(email) values
  ('ac-ana@example.com'), ('ac-ben@example.com'), ('ac-cem@example.com');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000ac001', '00000000-0000-0000-0000-0000000ac002'),
  ('00000000-0000-0000-0000-0000000ac002', '00000000-0000-0000-0000-0000000ac001'),
  ('00000000-0000-0000-0000-0000000ac002', '00000000-0000-0000-0000-0000000ac003');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('ac000000-0000-0000-0000-0000000ac00' || n)::uuid,
         ('00000000-0000-0000-0000-0000000ac00' || n)::uuid, now(), now()
    from generate_series(1, 3) n;

create or replace function test_as(n int) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-0000000ac00' || n)::uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', 'ac000000-0000-0000-0000-0000000ac00' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000ac00' || n)::uuid $$;
grant execute on function u(int) to authenticated;

select test_as(1); select ok(public.activate_session(), 'ana is active'); reset role;
select test_as(2); select ok(public.activate_session(), 'ben is active'); reset role;
select test_as(3); select ok(public.activate_session(), 'cem is active'); reset role;

create temp table _c (k text, id uuid);
grant select, insert on _c to authenticated;
select test_as(1);
insert into _c select 'D1', public.start_direct_conversation(u(2));
reset role;
select test_as(2);
insert into _c select 'D2', public.start_direct_conversation(u(3));
insert into _c select 'G', public.start_group_conversation('ac group', array[u(1), u(3)]);
reset role;
create function c(k text) returns uuid language sql as $$ select id from _c where _c.k = $1 $$;
grant execute on function c(text) to authenticated;

update public.conversation_members set last_read_at = now() - interval '1 day'
 where conversation_id in (select id from _c);
insert into public.messages(conversation_id, sender_id, body, created_at) values
  (c('D1'), u(2), 'ac one', now() - interval '50 minutes'),
  (c('D1'), u(2), 'ac two', now() - interval '49 minutes');

select test_as(1);
select lives_ok($$select public.register_device_token('ac-ana-device', 'android')$$, 'ana registers a phone');
reset role;
select test_as(3);
select lives_ok($$select public.register_device_token('ac-cem-device', 'android')$$, 'cem registers a phone');
reset role;

-- The delivery list for a fresh message from ben in conversation k.
create function targets(k text, body text) returns setof uuid language plpgsql as $$
declare mid uuid;
begin
  insert into public.messages(conversation_id, sender_id, body)
    values (c(k), u(2), body) returning id into mid;
  return query select t.user_id from app_private.push_targets_for_message(mid) t;
end $$;

-- 1 shape and privileges ------------------------------------------------------
select has_table('public', 'chat_archives', 'chat_archives exists');
select col_is_pk('public', 'chat_archives', array['user_id', 'conversation_id'],
                 'one row per member per chat');
select ok((select relrowsecurity from pg_class where oid = 'public.chat_archives'::regclass),
          'RLS is on');
select table_privs_are('public', 'chat_archives', 'authenticated', array['DELETE', 'INSERT', 'SELECT'],
                       'authenticated: select, insert, delete only');
select table_privs_are('public', 'chat_archives', 'anon', '{}'::text[], 'anon: nothing');

-- 2 before archiving -----------------------------------------------------------
select test_as(1);
select is(public.unread_total(), 2, 'ana: 2 unread before archiving');
reset role;
select ok(u(1) in (select targets('D1', 'ac before')), 'ana is a push target before archiving');
select test_as(1);
select is(public.unread_total(), 3, 'ana: 3 unread with the new one');
reset role;

-- 3 insert policy --------------------------------------------------------------
select test_as(1);
select lives_ok(format('insert into public.chat_archives(conversation_id) values (%L)', c('D1')),
                'ana archives D1 without naming herself');
select throws_ok(format('insert into public.chat_archives(user_id, conversation_id) values (%L, %L)',
                        u(2), c('D1')),
                 '42501', null, 'ana cannot archive D1 for ben, though ben is in D1');
select throws_ok(format('insert into public.chat_archives(user_id, conversation_id) values (%L, %L)',
                        u(1), c('D2')),
                 '42501', null, 'ana cannot archive D2, a chat she never belonged to');
reset role;
select is((select user_id from public.chat_archives where conversation_id = c('D1')), u(1),
          'user_id defaults to the caller');

-- a former member may archive (was_member, not is_member)
update public.conversation_members set left_at = now(), left_reason = 'left'
 where conversation_id = c('G') and user_id = u(3);
select test_as(3);
select lives_ok(format('insert into public.chat_archives(conversation_id) values (%L)', c('G')),
                'cem, who left G, may still archive it');
delete from public.chat_archives where conversation_id = c('G');
reset role;
update public.conversation_members set left_at = null, left_reason = null
 where conversation_id = c('G') and user_id = u(3);

-- 4 select, update, delete -----------------------------------------------------
select test_as(1);
select is((select count(*)::int from public.chat_archives), 1, 'ana sees her row');
reset role;
select test_as(2);
select is((select count(*)::int from public.chat_archives), 0, 'ben does not see ana''s row');
delete from public.chat_archives;  -- no WHERE: only the delete policy decides
reset role;
select is((select count(*)::int from public.chat_archives where user_id = u(1)), 1,
          'ben''s delete removed nothing of ana''s');
select test_as(1);
select throws_ok('update public.chat_archives set archived_at = now()', '42501', null,
                 'no update privilege');
reset role;
set local role anon;
select throws_ok('select * from public.chat_archives', '42501', null, 'anon reads nothing');
reset role;

-- 5 archived: no badge count, no push; unread_counts unchanged --------------
select test_as(1);
select is(public.unread_total(), 0, 'ana: archived D1 leaves the badge');
select is((select unread from public.unread_counts() where conversation_id = c('D1')), 3,
          'unread_counts still counts archived D1');
reset role;
select is(app_private.unread_total(u(1)), 0, 'app_private.unread_total agrees');
select ok(u(1) not in (select targets('D1', 'ac archived')), 'no push to ana for archived D1');

select test_as(1);
select lives_ok(format('insert into public.chat_archives(conversation_id) values (%L)', c('G')),
                'ana archives G');
reset role;
create temp table _g as select targets('G', 'ac group msg') as user_id;
select ok(u(1) not in (select user_id from _g), 'no push to ana in archived G');
select ok(u(3) in (select user_id from _g), 'cem, who did not archive G, still gets it');

-- search covers archived chats: D1 and G are both archived for ana here.
select test_as(1);
select ok(exists(select 1 from public.search_messages('ac two') s where s.conversation_id = c('D1')),
          'search finds a message in archived D1');
select ok(exists(select 1 from public.search_messages('ac group msg') s where s.conversation_id = c('G')),
          'search finds a message in archived G');
reset role;

-- 6 unarchive restores both ---------------------------------------------------
select test_as(1);
select lives_ok(format('delete from public.chat_archives where conversation_id = %L', c('D1')),
                'ana unarchives D1');
select is(public.unread_total(), 4, 'ana: D1''s 4 unread are back on the badge, G still archived');
reset role;
select ok(u(1) in (select targets('D1', 'ac after')), 'ana is a push target again');

select * from finish();
rollback;
