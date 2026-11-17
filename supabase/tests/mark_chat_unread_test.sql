begin;
select plan(53);

-- Fixtures: emails @markunread.test; users uma(…ee01), vic(…ee02), wes(…ee03), gus(…ee04),
-- ids 00000000-0000-0000-0000-00000000ee0N; sessions ids e1000000-0000-0000-0000-00000000ee0N (N = 1..4).
-- All four allowlisted and activated.

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000ee01', 'uma@markunread.test', now(), '{"full_name":"Uma"}'),
  ('00000000-0000-0000-0000-00000000ee02', 'vic@markunread.test', now(), '{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-00000000ee03', 'wes@markunread.test', now(), '{"full_name":"Wes"}'),
  ('00000000-0000-0000-0000-00000000ee04', 'gus@markunread.test', now(), '{"full_name":"Gus"}');
insert into app_private.allowlist(email) values
  ('uma@markunread.test'), ('vic@markunread.test'), ('wes@markunread.test'), ('gus@markunread.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-00000000ee01', '00000000-0000-0000-0000-00000000ee02'),
  ('00000000-0000-0000-0000-00000000ee01', '00000000-0000-0000-0000-00000000ee04');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('e1000000-0000-0000-0000-00000000ee01', '00000000-0000-0000-0000-00000000ee01', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee02', '00000000-0000-0000-0000-00000000ee02', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee03', '00000000-0000-0000-0000-00000000ee03', now(), now()),
  ('e1000000-0000-0000-0000-00000000ee04', '00000000-0000-0000-0000-00000000ee04', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is(public.activate_session(), true, 'uma is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
select is(public.activate_session(), true, 'vic is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee03', 'e1000000-0000-0000-0000-00000000ee03');
select is(public.activate_session(), true, 'wes is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000ee04', 'e1000000-0000-0000-0000-00000000ee04');
select is(public.activate_session(), true, 'gus is active');
reset role;

create temp table _c (k text primary key, id uuid);
create temp table _r (who text primary key, j jsonb);
grant select, insert, delete on _c, _r to authenticated, anon;

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
insert into _c select 'D', public.start_direct_conversation('00000000-0000-0000-0000-00000000ee02');
insert into _c select 'G', public.start_group_conversation('mu group', array[
  '00000000-0000-0000-0000-00000000ee02', '00000000-0000-0000-0000-00000000ee04']::uuid[]);
reset role;

-- gus loses app access
delete from app_private.allowlist where email = 'gus@markunread.test';
reset role;

-- helper functions
create or replace function test_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
end $$;
grant execute on function test_anon() to authenticated, anon;

create or replace function try_mark(conv uuid) returns text language plpgsql security invoker as $$
begin
  perform public.mark_chat_unread(conv);
  return 'ok';
exception when others then return sqlstate;
end $$;
grant execute on function try_mark(uuid) to authenticated, anon;

create or replace function try_sql(q text) returns text language plpgsql security invoker as $$
begin
  execute q;
  return 'ok';
exception when others then return sqlstate;
end $$;
grant execute on function try_sql(text) to authenticated, anon;

reset role;
-- MUTATION-POINT
select has_table('public','chat_marked_unread', 'marked table exists');
select ok((select relrowsecurity from pg_class where oid='public.chat_marked_unread'::regclass), 'rls is on');
select ok(has_table_privilege('authenticated','public.chat_marked_unread','SELECT'), 'authenticated may select');
select ok(not has_table_privilege('authenticated','public.chat_marked_unread','INSERT'), 'authenticated has no insert grant');
select ok(not has_table_privilege('authenticated','public.chat_marked_unread','UPDATE'), 'authenticated has no update grant');
select ok(not has_table_privilege('authenticated','public.chat_marked_unread','DELETE'), 'authenticated has no delete grant');
select ok(not (has_table_privilege('anon','public.chat_marked_unread','SELECT') or has_table_privilege('anon','public.chat_marked_unread','INSERT') or has_table_privilege('anon','public.chat_marked_unread','UPDATE') or has_table_privilege('anon','public.chat_marked_unread','DELETE')), 'anon has no table privilege at all');
select ok((select prosecdef from pg_proc where oid='public.mark_chat_unread(uuid)'::regprocedure), 'mark_chat_unread is security definer');
select ok((select 'search_path=""' = any(proconfig) from pg_proc where oid='public.mark_chat_unread(uuid)'::regprocedure), 'mark_chat_unread pins an empty search_path');
select ok(has_function_privilege('authenticated','public.mark_chat_unread(uuid)','EXECUTE'), 'authenticated may execute mark_chat_unread');
select ok(not has_function_privilege('anon','public.mark_chat_unread(uuid)','EXECUTE'), 'anon may not execute mark_chat_unread');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid='public.mark_chat_unread(uuid)'::regprocedure and a.grantee = 0 and a.privilege_type='EXECUTE'), 'PUBLIC has no execute on mark_chat_unread');

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is(try_sql(format('insert into public.chat_marked_unread(user_id, conversation_id) values (%L, %L)', '00000000-0000-0000-0000-00000000ee01', (select id from _c where k='D'))), '42501', 'uma cannot insert a mark directly');
select is(try_sql('update public.chat_marked_unread set marked_at = now()'), '42501', 'uma cannot update a mark directly');
select is(try_sql('delete from public.chat_marked_unread'), '42501', 'uma cannot delete a mark directly');
reset role;

select test_anon();
select is(try_mark((select id from _c where k='D')), '42501', 'anon is refused');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee03', 'e1000000-0000-0000-0000-00000000ee03');
select is(try_mark((select id from _c where k='D')), '42501', 'a non-member is refused');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee04', 'e1000000-0000-0000-0000-00000000ee04');
select is(try_mark((select id from _c where k='G')), '42501', 'a member without app access is refused');
reset role;

select is((select count(*)::int from public.chat_marked_unread), 0, 'refusals wrote nothing');

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is(try_mark((select id from _c where k='D')), 'ok', 'uma marks D');
select is(try_mark((select id from _c where k='D')), 'ok', 'uma marks D twice');
reset role;

select is((select count(*)::int from public.chat_marked_unread where user_id='00000000-0000-0000-0000-00000000ee01' and conversation_id=(select id from _c where k='D')), 1, 'two calls leave one row');

select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
select is(try_mark((select id from _c where k='D')), 'ok', 'vic marks D');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is((select count(*)::int from public.chat_marked_unread), 1, 'uma sees one row');
select is((select user_id from public.chat_marked_unread), '00000000-0000-0000-0000-00000000ee01'::uuid, 'uma sees her own row');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
select is((select count(*)::int from public.chat_marked_unread), 1, 'vic sees one row');
select is((select user_id from public.chat_marked_unread), '00000000-0000-0000-0000-00000000ee02'::uuid, 'vic sees his own row');
reset role;

select test_as('00000000-0000-0000-0000-00000000ee03', 'e1000000-0000-0000-0000-00000000ee03');
select is((select count(*)::int from public.chat_marked_unread), 0, 'wes sees none');
reset role;

select is((select count(*)::int from public.chat_marked_unread), 2, 'two rows in total');

-- GROUP C: receipts and mark_read

-- S1: setup
update public.conversation_members set last_read_at = now() - interval '1 hour'
where conversation_id = (select id from _c where k='D');
create temp table _lr as
  select user_id, last_read_at
  from public.conversation_members
  where conversation_id = (select id from _c where k='D');

-- S2: uma marks again
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is(try_mark((select id from _c where k='D')), 'ok', 'uma marks D a third time');
reset role;

-- 1
select is(
  (select count(*)::int
   from _lr l
   join public.conversation_members m
     on m.user_id=l.user_id
    and m.conversation_id=(select id from _c where k='D')
   where m.last_read_at is distinct from l.last_read_at),
  0,
  'marking unread changes nobody''s read receipt'
);

-- 2
select is(
  (select count(*)::int
   from public.chat_marked_unread
   where user_id='00000000-0000-0000-0000-00000000ee02'),
  1,
  'vic''s mark survives uma marking'
);

-- S3: uma mark_read
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select public.mark_read((select id from _c where k='D'));
reset role;

-- 3
select is(
  (select count(*)::int
   from public.chat_marked_unread
   where user_id='00000000-0000-0000-0000-00000000ee01'),
  0,
  'mark_read clears the caller''s mark'
);

-- 4
select is(
  (select count(*)::int
   from public.chat_marked_unread
   where user_id='00000000-0000-0000-0000-00000000ee02'),
  1,
  'mark_read leaves another member''s mark'
);

-- 5
select ok(
  (select last_read_at
   from public.conversation_members
   where user_id='00000000-0000-0000-0000-00000000ee01'
     and conversation_id=(select id from _c where k='D')) > now() - interval '30 minutes',
  'mark_read still moves the caller''s read time forward'
);

-- 6
select is(
  (select last_read_at
   from public.conversation_members
   where user_id='00000000-0000-0000-0000-00000000ee02'
     and conversation_id=(select id from _c where k='D')),
  (select last_read_at
   from _lr
   where user_id='00000000-0000-0000-0000-00000000ee02'),
  'mark_read leaves another member''s read time alone'
);

-- S4: second mark_read with no mark
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select public.mark_read((select id from _c where k='D'));
reset role;

-- 7
select is(
  (select count(*)::int
   from public.chat_marked_unread
   where user_id='00000000-0000-0000-0000-00000000ee01'),
  0,
  'mark_read with no mark is harmless'
);

-- S5: uma marks again after reading
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
select is(try_mark((select id from _c where k='D')), 'ok', 'uma marks D after reading');
reset role;

-- 8
select is(
  (select count(*)::int
   from public.chat_marked_unread
   where user_id='00000000-0000-0000-0000-00000000ee01'),
  1,
  'uma can mark again after reading'
);

-- GROUP D: chat_list

-- S1: insert chat_list for each user
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
delete from _r;
insert into _r select 'uma', public.chat_list();
reset role;

select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
insert into _r select 'vic', public.chat_list();
reset role;

select test_as('00000000-0000-0000-0000-00000000ee03', 'e1000000-0000-0000-0000-00000000ee03');
insert into _r select 'wes', public.chat_list();
reset role;

-- Assertions (as postgres)
select ok((select j ? 'marked_unread' from _r where who='uma'), 'chat_list has the marked_unread key');
select ok((select j ?& array['archives','conversations','hides','members','pins','previews','profiles','unread'] from _r where who='uma'), 'chat_list keeps every old key');
select is((select jsonb_array_length(j->'marked_unread') from _r where who='uma'), 1, 'uma has one marked chat');
select is((select (j->'marked_unread'->0->>'conversation_id')::uuid from _r where who='uma'), (select id from _c where k='D'), 'uma''s marked chat is D');
select is((select jsonb_array_length(j->'marked_unread') from _r where who='vic'), 1, 'vic has one marked chat');
select is((select (j->'marked_unread'->0->>'conversation_id')::uuid from _r where who='vic'), (select id from _c where k='D'), 'vic''s marked chat is D');
select ok((select j ? 'marked_unread' and jsonb_array_length(j->'marked_unread') = 0 from _r where who='wes'), 'wes has the key and no marks');
select ok((select j ?& array['archives','conversations','hides','members','pins','previews','profiles','unread'] from _r where who='wes'), 'wes still gets every old key');

-- S2: vic reads D
select test_as('00000000-0000-0000-0000-00000000ee02', 'e1000000-0000-0000-0000-00000000ee02');
select public.mark_read((select id from _c where k='D'));
delete from _r where who='vic';
insert into _r select 'vic', public.chat_list();
reset role;

select is((select jsonb_array_length(j->'marked_unread') from _r where who='vic'), 0, 'vic reading D empties his marked list');

-- S3: uma still has her D mark
select test_as('00000000-0000-0000-0000-00000000ee01', 'e1000000-0000-0000-0000-00000000ee01');
delete from _r where who='uma';
insert into _r select 'uma', public.chat_list();
reset role;

select is((select jsonb_array_length(j->'marked_unread') from _r where who='uma'), 1, 'vic reading D did not clear uma''s mark');

select * from finish();
rollback;
