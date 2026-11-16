begin;
select plan(8);

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
 ('00000000-0000-0000-0000-0000000a2001','own@mail.test',now(),'{"full_name":"Own"}'),
 ('00000000-0000-0000-0000-0000000a2003','brg@mail.test',now(),'{"full_name":"Brg"}');
insert into app_private.allowlist(email) values ('own@mail.test'),('brg@mail.test');
insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000a2001');
insert into app_private.admin_view_bridge(user_id) values ('00000000-0000-0000-0000-0000000a2003');
insert into auth.sessions (id,user_id,created_at,updated_at) values
 ('a2000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000a2001', now(), now()),
 ('a2000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-0000000a2003', now(), now());
select test_as('00000000-0000-0000-0000-0000000a2001','a2000000-0000-0000-0000-000000000002'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-0000000a2003','a2000000-0000-0000-0000-000000000004'); select public.activate_session(); reset role;
create function as_own() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a2001','a2000000-0000-0000-0000-000000000002') $$;
create function as_brg() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a2003','a2000000-0000-0000-0000-000000000004') $$;
grant execute on function as_own(), as_brg() to authenticated;

-- Key setup
select as_own();
select public.admin_view_set_phone_key(k('11'));
reset role;
select as_brg();
select public.admin_view_bridge_set_key(k('cc'));
reset role;

-- 1. No push before any insert
select is((select count(*) from realtime.messages where topic='admin_view'), 0::bigint, 'no push before any insert');

-- 2. Insert down item triggers push
insert into app_private.admin_view_items(dir,epoch,seq,body) values ('down',1,1,bytes(1073));
select is((select count(*) from realtime.messages where topic='admin_view' and event='down'), 1::bigint, 'a down insert pushes once');

-- 3. Payload carries the item id
select is((select payload->>'id' from realtime.messages where topic='admin_view'), (select id::text from app_private.admin_view_items where dir='down' and seq=1), 'payload carries the item id');

-- 4. Payload has only one key (no body)
select is((select count(*) from jsonb_object_keys((select payload from realtime.messages where topic='admin_view'))), 1::bigint, 'payload has only one key (no body)');

-- 5. Broadcast and private
select ok((select extension='broadcast' and private from realtime.messages where topic='admin_view'), 'broadcast and private');

-- 6. Insert up item does not push
insert into app_private.admin_view_items(dir,epoch,seq,body) values ('up',1,1,bytes(1073));
select is((select count(*) from realtime.messages where topic='admin_view'), 1::bigint, 'an up insert pushes nothing');

-- 7. Bridge put succeeds and pushes
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,2,bytes(1073))$$), 'ok:1', 'bridge_put succeeds with the trigger');
reset role;
select is((select count(*) from realtime.messages where topic='admin_view'), 2::bigint, 'bridge_put pushed too');

select * from finish(); rollback;
