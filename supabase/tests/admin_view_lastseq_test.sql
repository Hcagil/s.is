begin;
select plan(20);
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
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000a1001','own@mail.test',now(),'{"full_name":"Own"}'),
 ('00000000-0000-0000-0000-0000000a1003','brg@mail.test',now(),'{"full_name":"Brg"}');
insert into app_private.allowlist(email) values ('own@mail.test'),('brg@mail.test');
insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000a1001');
insert into app_private.admin_view_bridge(user_id) values ('00000000-0000-0000-0000-0000000a1003');
insert into auth.sessions (id,user_id,created_at,updated_at) values
 ('a1000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000a1001', now(), now()),
 ('a1000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-0000000a1003', now(), now());
select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000002'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-0000000a1003','a1000000-0000-0000-0000-000000000004'); select public.activate_session(); reset role;
create function as_own() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000002') $$;
create function as_brg() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1003','a1000000-0000-0000-0000-000000000004') $$;
grant execute on function as_own(), as_brg() to authenticated;
select as_own();
select public.admin_view_set_phone_key(k('11'));
reset role;
select as_brg();
select public.admin_view_bridge_set_key(k('cc'));
reset role;
-- DOWN: last seq survives deleting the rows
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,1,bytes(1073))$$), 'ok:1', 'down seq 1 accepted');
select is(try_exec($$select public.admin_view_bridge_put(1,2,bytes(1073))$$), 'ok:1', 'down seq 2 accepted');
select is(try_exec($$select public.admin_view_bridge_put(1,3,bytes(1073))$$), 'ok:1', 'down seq 3 accepted');
reset role;
delete from app_private.admin_view_items where dir = 'down';
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,3,bytes(1073))$$), 'err:22023', 'down: the last seq is refused after its rows are gone');
select is(try_exec($$select public.admin_view_bridge_put(1,2,bytes(1073))$$), 'err:22023', 'down: a lower seq is refused after its rows are gone');
select is(try_exec($$select public.admin_view_bridge_put(1,4,bytes(1073))$$), 'ok:1', 'down: the next seq is accepted');
reset role;
-- UP
select as_own();
select is(try_exec($$select public.admin_view_send(1,1,bytes(1073))$$), 'ok:1', 'up seq 1 accepted');
select is(try_exec($$select public.admin_view_send(1,2,bytes(1073))$$), 'ok:1', 'up seq 2 accepted');
reset role;
delete from app_private.admin_view_items where dir = 'up';
select as_own();
select is(try_exec($$select public.admin_view_send(1,2,bytes(1073))$$), 'err:22023', 'up: the last seq is refused after its rows are gone');
select is(try_exec($$select public.admin_view_send(1,3,bytes(1073))$$), 'ok:1', 'up: the next seq is accepted');
-- NULLS
select is(try_exec($$select public.admin_view_send(1,null::bigint,bytes(1073))$$), 'err:22023', 'send: null seq refused');
select is(try_exec($$select public.admin_view_send(null::int,50,bytes(1073))$$), 'err:22023', 'send: null epoch refused');
reset role;
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,null::bigint,bytes(1073))$$), 'err:22023', 'put: null seq refused');
select is(try_exec($$select public.admin_view_bridge_put(null::int,50,bytes(1073))$$), 'err:22023', 'put: null epoch refused');
reset role;
-- RESET ON PHONE KEY BUMP
select as_own();
select is(public.admin_view_set_phone_key(k('22')), 2, 'new phone key: epoch 2');
select is(try_exec($$select public.admin_view_send(2,1,bytes(1073))$$), 'ok:1', 'after a phone key bump the up seq restarts at 1');
reset role;
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(2,1,bytes(1073))$$), 'ok:1', 'after a phone key bump the down seq restarts at 1');
-- RESET ON COMPUTER KEY BUMP
select is(public.admin_view_bridge_set_key(k('dd')), 3, 'new computer key: epoch 3');
select is(try_exec($$select public.admin_view_bridge_put(3,1,bytes(1073))$$), 'ok:1', 'after a computer key bump the down seq restarts at 1');
reset role;
select as_own();
select is(try_exec($$select public.admin_view_send(3,1,bytes(1073))$$), 'ok:1', 'after a computer key bump the up seq restarts at 1');
reset role;
select * from finish(); rollback;
