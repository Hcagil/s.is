begin;
select plan(13);
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

-- SETUP
select as_brg();
select public.admin_view_bridge_set_key(k('cc'));
reset role;
select as_own();
select public.admin_view_set_phone_key(k('11'));
reset role;

-- Assertions
reset role;
insert into app_private.admin_view_items(dir,epoch,seq,body) values ('down',1,1,bytes(1073)),('up',1,1,bytes(1073));
select as_own();
select is(public.admin_view_set_phone_key(k('11')), 1, 'same phone key returns same epoch');
reset role;
select is((select count(*) from app_private.admin_view_items), 2::bigint, 'same phone key keeps items');

select as_own();
select is(public.admin_view_set_phone_key(k('22')), 2, 'new phone key gives epoch 2');
reset role;
select is((select count(*) from app_private.admin_view_items), 0::bigint, 'new phone key wipes all items');
select as_own();
select is((select phone_pub from public.admin_view_state()), k('22'), 'phone_pub is the new key');
select is((select epoch from public.admin_view_state()), 2, 'state epoch 2');
reset role;

-- F3 corrected behaviour, red until the server is fixed
reset role;
insert into app_private.admin_view_items(dir,epoch,seq,body) values ('down',2,1,bytes(1073));
select as_brg();
select is(public.admin_view_bridge_set_key(k('cc')), 2, 'same computer key: epoch unchanged');
reset role;
select is((select count(*) from app_private.admin_view_items), 1::bigint, 'same computer key keeps items');
select as_brg();
select is(public.admin_view_bridge_set_key(k('dd')), 3, 'different computer key bumps the epoch');
reset role;
select is((select count(*) from app_private.admin_view_items), 0::bigint, 'different computer key wipes items');
select as_own();
select is((select epoch from public.admin_view_state()), 3, 'state epoch 3');
select is((select computer_pub from public.admin_view_state()), k('dd'), 'computer_pub is the new key');
select is((select phone_pub from public.admin_view_state()), k('22'), 'phone_pub untouched');
reset role;

select * from finish(); rollback;
