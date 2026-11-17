-- gone_peers seam: when the other person of a 1:1 chat is deleted, only the remaining member's chat_list() names the deleted id; never for groups, nobody else, not while the partner exists.
begin;
select plan(12);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000fd001','gp-uma@mail.test',now(),'{"full_name":"Uma"}'),
  ('00000000-0000-0000-0000-0000000fd002','gp-vic@mail.test',now(),'{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-0000000fd003','gp-wes@mail.test',now(),'{"full_name":"Wes"}'),
  ('00000000-0000-0000-0000-0000000fd004','gp-xan@mail.test',now(),'{"full_name":"Xan"}'),
  ('00000000-0000-0000-0000-0000000fd005','gp-yan@mail.test',now(),'{"full_name":"Yan"}');
insert into app_private.allowlist(email) values ('gp-uma@mail.test'),('gp-vic@mail.test'),('gp-wes@mail.test'),('gp-xan@mail.test'),('gp-yan@mail.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000fd001','00000000-0000-0000-0000-0000000fd002'),
  ('00000000-0000-0000-0000-0000000fd001','00000000-0000-0000-0000-0000000fd003'),
  ('00000000-0000-0000-0000-0000000fd003','00000000-0000-0000-0000-0000000fd004');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('fd000000-0000-0000-0000-0000000fd00' || n)::uuid, ('00000000-0000-0000-0000-0000000fd00' || n)::uuid, now(), now() from generate_series(1, 5) n;
create or replace function test_as(n int) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-0000000fd00' || n)::uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', 'fd000000-0000-0000-0000-0000000fd00' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n int) returns uuid language sql as $$ select ('00000000-0000-0000-0000-0000000fd00' || n)::uuid $$;
grant execute on function u(int) to authenticated;
select test_as(1); select public.activate_session(); reset role;
select test_as(2); select public.activate_session(); reset role;
select test_as(3); select public.activate_session(); reset role;
select test_as(4); select public.activate_session(); reset role;
select test_as(5); select public.activate_session(); reset role;
create temp table _c (k text, id uuid);
grant select, insert on _c to authenticated;
select test_as(1);
insert into _c select 'D1', public.start_direct_conversation(u(2));
insert into _c select 'D3', public.start_direct_conversation(u(3));
insert into _c select 'G', public.start_group_conversation('gp group', array[u(2), u(3)]);
reset role;
select test_as(3);
insert into _c select 'D2', public.start_direct_conversation(u(4));
reset role;
create function c(k text) returns uuid language sql as $$ select id from _c where _c.k = $1 $$;
create temp table _r (who text primary key, j jsonb);
grant select, insert on _r to authenticated;
create function r(w text) returns jsonb language sql as $$ select j from _r where who = w $$;
select test_as(1); insert into _r select 'uma_before', public.chat_list()->'gone_peers'; reset role;
select test_as(3); insert into _r select 'wes_before', public.chat_list()->'gone_peers'; reset role;
delete from auth.users where id in (u(2), u(4));
select test_as(1); insert into _r select 'uma_after', public.chat_list()->'gone_peers'; reset role;
select test_as(3); insert into _r select 'wes_after', public.chat_list()->'gone_peers'; reset role;
select test_as(5); insert into _r select 'yan_after', public.chat_list()->'gone_peers'; reset role;

-- Assertions
select is(r('uma_before')::text, '[]', 'uma before: partner alive, nothing');
select is(r('wes_before')::text, '[]', 'wes before: partner alive, nothing');
select is(jsonb_array_length(r('uma_after'))::text, '1', 'uma after: one gone peer');
select is((r('uma_after')->0->>'conversation_id')::text, c('D1')::text, 'uma after: conversation id matches D1');
select is((r('uma_after')->0->>'user_id')::text, u(2)::text, 'uma after: user id matches Vic');
select is(jsonb_array_length(r('wes_after'))::text, '1', 'wes after: one gone peer');
select is((r('wes_after')->0->>'conversation_id')::text, c('D2')::text, 'wes after: conversation id matches D2');
select is((r('wes_after')->0->>'user_id')::text, u(4)::text, 'wes after: user id matches Xan');
select is(r('yan_after')::text, '[]', 'yan has no chats: nothing');

-- Yan: chat_gone_peers has no rows
select test_as(5);
select is((select count(*)::int from public.chat_gone_peers())::text, '0', 'yan: chat_gone_peers has no rows');
reset role;

-- Uma: chat_gone_peers names Vic
select test_as(1);
select is((select user_id::text from public.chat_gone_peers()), u(2)::text, 'uma: chat_gone_peers names vic');
reset role;

-- anon cannot call chat_gone_peers
set local role anon;
select throws_ok($$select * from public.chat_gone_peers()$$, '42501', null, 'anon cannot call chat_gone_peers');
reset role;

select * from finish();
rollback;
