begin;
select plan(9);

-- Helper functions from template
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated', 'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function try_exec(stmt text) returns text language plpgsql security invoker as $$
declare n bigint;
begin execute stmt; get diagnostics n = row_count; return 'ok:' || n;
exception when others then return 'err:' || sqlstate; end $$;
create or replace function bytes(n int) returns bytea language sql immutable as $$ select decode(repeat('ab', n), 'hex') $$;
create or replace function k(c text) returns bytea language sql immutable as $$ select decode(repeat(c, 32), 'hex') $$;
grant execute on function try_exec(text), bytes(int), k(text) to authenticated, anon;

-- Users and roles
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000a3001','own3@mail.test',now(),'{"full_name":"Own"}'),
 ('00000000-0000-0000-0000-0000000a3002','plain3@mail.test',now(),'{"full_name":"Plain"}');
insert into app_private.allowlist(email) values ('own3@mail.test'),('plain3@mail.test');
insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000a3001');
insert into auth.sessions (id,user_id,created_at,updated_at) values
 ('a3000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000a3001', now(), now()),
 ('a3000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000a3002', now(), now());
select test_as('00000000-0000-0000-0000-0000000a3001','a3000000-0000-0000-0000-000000000001'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-0000000a3002','a3000000-0000-0000-0000-000000000002'); select public.activate_session(); reset role;

-- Helper for anon
create or replace function test_anon() returns void language plpgsql as $$ begin perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true); execute 'set local role anon'; end $$;
grant execute on function test_anon() to authenticated, anon;

-- Helper to check realtime messages
create or replace function can_receive(topic text, ext text) returns boolean language plpgsql security invoker as $$ begin perform set_config('realtime.topic', coalesce(topic,''), true); return exists (select 1 from realtime.messages m where m.extension = ext and m.event = 'fixture'); end $$;
grant execute on function can_receive(text,text) to authenticated, anon;

-- Insert test messages
insert into realtime.messages (topic, extension, payload, event, private) values
 ('admin_view','broadcast','{}'::jsonb,'fixture',true),
 ('other','broadcast','{}'::jsonb,'fixture',true),
 ('admin_view','presence','{}'::jsonb,'fixture',true);

-- 1. own can receive
select test_as('00000000-0000-0000-0000-0000000a3001','a3000000-0000-0000-0000-000000000001');
select is(can_receive('admin_view','broadcast'), true, 'own can receive admin_view broadcast');
reset role;

-- 2. plain cannot (not owner)
select test_as('00000000-0000-0000-0000-0000000a3002','a3000000-0000-0000-0000-000000000002');
select is(can_receive('admin_view','broadcast'), false, 'plain cannot receive admin_view broadcast');
reset role;

-- 3. owner removed from the allowlist cannot (proves has_app_access gate)
delete from app_private.allowlist where email = 'own3@mail.test';
select test_as('00000000-0000-0000-0000-0000000a3001','a3000000-0000-0000-0000-000000000001');
select is(can_receive('admin_view','broadcast'), false, 'owner without app access cannot receive admin_view broadcast');
reset role;
insert into app_private.allowlist(email) values ('own3@mail.test');

-- 4. anon cannot
select test_anon();
select is(can_receive('admin_view','broadcast'), false, 'anon cannot receive admin_view broadcast');
reset role;

-- 5. own cannot receive other topic
select test_as('00000000-0000-0000-0000-0000000a3001','a3000000-0000-0000-0000-000000000001');
select is(can_receive('other','broadcast'), false, 'own cannot receive other broadcast');
reset role;

-- 6. own cannot receive presence extension
select test_as('00000000-0000-0000-0000-0000000a3001','a3000000-0000-0000-0000-000000000001');
select is(can_receive('admin_view','presence'), false, 'own cannot receive admin_view presence');
reset role;

-- 7. policy existence
select ok(exists(select 1 from pg_policies where schemaname='realtime' and tablename='messages' and policyname='admin_view_receive' and cmd='SELECT' and roles = '{authenticated}'), 'admin_view_receive is a select policy for authenticated');

-- 8. realtime_receive policy still exists
select ok(exists(select 1 from pg_policies where schemaname='realtime' and tablename='messages' and policyname='realtime_receive' and cmd='SELECT'), 'realtime_receive policy exists');

-- 9. realtime_send policy still exists
select ok(exists(select 1 from pg_policies where schemaname='realtime' and tablename='messages' and policyname='realtime_send' and cmd='INSERT'), 'realtime_send policy exists');

select * from finish(); rollback;
