-- gone_peers access test: signed‑in users without app access must see no gone peers
begin;
select plan(4);

-- create users
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000fe001','ga-uma@mail.test',now(),'{"full_name":"Uma"}'),
  ('00000000-0000-0000-0000-0000000fe002','ga-vic@mail.test',now(),'{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-0000000fe003','ga-zed@mail.test',now(),'{"full_name":"Zed"}');

-- allowlist all three
insert into app_private.allowlist(email) values
  ('ga-uma@mail.test'),
  ('ga-vic@mail.test'),
  ('ga-zed@mail.test');

-- tag_finds: uma->vic, zed->vic
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000fe001','00000000-0000-0000-0000-0000000fe002'),
  ('00000000-0000-0000-0000-0000000fe003','00000000-0000-0000-0000-0000000fe002');

-- sessions
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('fe000000-0000-0000-0000-0000000fe00' || n)::uuid,
         ('00000000-0000-0000-0000-0000000fe00' || n)::uuid,
         now(), now()
  from generate_series(1,3) n;

-- helper functions
create or replace function test_as(n int) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-0000000fe00' || n)::uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', ('fe000000-0000-0000-0000-0000000fe00' || n)::text)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n int) returns uuid language sql as $$ select ('00000000-0000-0000-0000-0000000fe00' || n)::uuid $$;
grant execute on function u(int) to authenticated;

-- activate sessions
select test_as(1); select public.activate_session(); reset role;
select test_as(2); select public.activate_session(); reset role;
select test_as(3); select public.activate_session(); reset role;

-- start 1:1 chats
create temp table _c (k text, id uuid);
grant select, insert on _c to authenticated;
select test_as(1);
insert into _c select 'D1', public.start_direct_conversation(u(2));
reset role;
select test_as(3);
insert into _c select 'D2', public.start_direct_conversation(u(2));
reset role;

-- revoke zed from allowlist and active_sessions
delete from app_private.allowlist where email='ga-zed@mail.test';
delete from app_private.active_sessions where user_id=u(3);
reset role;

-- delete vic
delete from auth.users where id = u(2);

-- assertions
-- 1. Uma sees one gone peer
select test_as(1);
select is((select count(*)::int from public.chat_gone_peers()), 1, 'uma: chat_gone_peers has one row');
reset role;

-- 2. Zed sees none
select test_as(3);
select is((select count(*)::int from public.chat_gone_peers()), 0, 'zed: chat_gone_peers has no rows');
reset role;

-- 3. Zed chat_list()->gone_peers is empty array
select test_as(3);
select is(coalesce(public.chat_list()->'gone_peers','[]'::jsonb)::text, '[]', 'zed: chat_list gone_peers empty');
reset role;

-- 4. Uma chat_list()->gone_peers array length 1
select test_as(1);
select is(jsonb_array_length(public.chat_list()->'gone_peers')::text, '1', 'uma: chat_list gone_peers length 1');
reset role;

select * from finish();
rollback;
