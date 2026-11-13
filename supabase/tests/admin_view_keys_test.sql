begin;
select plan(21);
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

-- Assertions
select as_own();
select is((select count(*) from public.admin_view_state()), 1::bigint, 'state has one row');
select is((select epoch from public.admin_view_state()), 0, 'fresh epoch 0');
select is((select phone_pub is null from public.admin_view_state()), true, 'fresh phone_pub null');
select is((select computer_pub is null from public.admin_view_state()), true, 'fresh computer_pub null');
reset role;
select as_brg();
select is((select count(*) from public.admin_view_bridge_state()), 1::bigint, 'bridge state has one row');
select is((select epoch from public.admin_view_bridge_state()), 0, 'bridge fresh epoch 0');
reset role;

select as_brg();
select is(public.admin_view_bridge_set_key(k('cc')), 0, 'bridge_set_key creates the keys row, epoch 0');
reset role;
select is((select count(*) from app_private.admin_view_keys), 1::bigint, 'one keys row');
select as_own();
select is((select computer_pub from public.admin_view_state()), k('cc'), 'computer_pub stored');
select is((select phone_pub is null from public.admin_view_state()), true, 'phone_pub still null');
select is((select epoch from public.admin_view_state()), 0, 'epoch still 0');
reset role;

select as_brg();
select is(try_exec($$select public.admin_view_bridge_set_key(bytes(31))$$), 'err:22023', 'bridge key 31 bytes refused');
select is(try_exec($$select public.admin_view_bridge_set_key(bytes(33))$$), 'err:22023', 'bridge key 33 bytes refused');
select is(try_exec($$select public.admin_view_bridge_set_key(null::bytea)$$), 'err:22023', 'bridge key null refused');
reset role;

select as_own();
select is(try_exec($$select public.admin_view_set_phone_key(null::bytea)$$), 'err:22023', 'set_phone_key null refused');
select is(try_exec($$select public.admin_view_set_phone_key(bytes(31))$$), 'err:22023', 'set_phone_key 31 bytes refused');
select is(try_exec($$select public.admin_view_set_phone_key(bytes(33))$$), 'err:22023', 'set_phone_key 33 bytes refused');
select is(public.admin_view_set_phone_key(k('11')), 1, 'first phone key gives epoch 1');
select is((select computer_pub from public.admin_view_state()), k('cc'), 'computer_pub untouched');
select is((select phone_pub from public.admin_view_state()), k('11'), 'phone_pub stored');
select is((select epoch from public.admin_view_state()), 1, 'state epoch 1');
reset role;

select * from finish(); rollback;
