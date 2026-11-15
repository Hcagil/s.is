begin;
select plan(9);
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
select is(try_exec($$select public.admin_view_bridge_put(1,1000001,bytes(1073))$$), 'ok:1', 'down +1000000 accepted');
select is(try_exec($$select public.admin_view_bridge_put(1,2000002,bytes(1073))$$), 'err:22023', 'down +1000001 refused');
reset role;
select is((select last_down_seq from app_private.admin_view_keys where only_row), 1000001::bigint, 'seq unchanged after refusal');
select is((select count(*) from app_private.admin_view_items where dir='down'), 2::bigint, 'no new row after refusal');
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,9223372036854775807,bytes(1073))$$), 'err:22023', 'down max bigint refused');
select is(try_exec($$select public.admin_view_bridge_put(1,1000002,bytes(1073))$$), 'ok:1', 'down +1 accepted after refusal');
select is(try_exec($$select public.admin_view_bridge_put(1,0,bytes(1073))$$), 'err:22023', 'down seq 0 refused');
reset role;
select is((select last_down_seq from app_private.admin_view_keys where only_row), 1000002::bigint, 'seq is 1000002 at end');
reset role;
select * from finish(); rollback;
