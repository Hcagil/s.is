begin;
select plan(58);


create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated', 'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function try_exec(stmt text) returns text language plpgsql security invoker as $$
declare n bigint;
begin execute stmt; get diagnostics n = row_count; return 'ok:' || n;
exception when others then return 'err:' || sqlstate; end $$;
grant execute on function try_exec(text) to authenticated, anon;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000a1001','own@mail.test',now(),'{"full_name":"Own"}'),
 ('00000000-0000-0000-0000-0000000a1002','mal@mail.test',now(),'{"full_name":"Mal"}'),
 ('00000000-0000-0000-0000-0000000a1003','brg@mail.test',now(),'{"full_name":"Brg"}');

insert into app_private.allowlist(email) values ('own@mail.test'),('mal@mail.test'),('brg@mail.test');
insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000a1001');
insert into app_private.admin_view_bridge(user_id) values ('00000000-0000-0000-0000-0000000a1003');
insert into auth.sessions (id,user_id,created_at,updated_at) values
 ('a1000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000a1001', now()-interval '2 hours', now()),
 ('a1000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000a1001', now()-interval '1 hour', now()),
 ('a1000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-0000000a1002', now(), now()),
 ('a1000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-0000000a1003', now(), now());
select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000001'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000002'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-0000000a1002','a1000000-0000-0000-0000-000000000003'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-0000000a1003','a1000000-0000-0000-0000-000000000004'); select public.activate_session(); reset role;
create function as_own() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000002') $$;
create function as_own_old() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000001') $$;
create function as_own_gone() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000005') $$;
create function as_mal() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1002','a1000000-0000-0000-0000-000000000003') $$;
create function as_brg() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1003','a1000000-0000-0000-0000-000000000004') $$;
grant execute on function as_own(), as_own_old(), as_own_gone(), as_mal(), as_brg() to authenticated;

-- A. anon role
set local role anon;
select is(try_exec(format('select public.%s', c)), 'err:42501', 'anon: ' || c)
from unnest(array[
  'admin_view_state()',
  'admin_view_set_phone_key(decode(repeat(''11'',32),''hex''))',
  'admin_view_fetch(0)',
  'admin_view_send(1,1,decode(repeat(''ab'',1073),''hex''))',
  'admin_view_bridge_state()',
  'admin_view_bridge_set_key(decode(repeat(''22'',32),''hex''))',
  'admin_view_bridge_put(1,1,decode(repeat(''ab'',1073),''hex''))',
  'admin_view_bridge_take(0)',
  'admin_view_bridge_ack(array[1]::bigint[])'
]) as c;
reset role;

-- B. as_mal
select as_mal();
select is((select count(*) from public.admin_view_state()), 0::bigint, 'as_mal: state returns no rows');
select is(try_exec($$select public.admin_view_set_phone_key(decode(repeat('11',32),'hex'))$$), 'err:42501', 'as_mal: admin_view_set_phone_key refused');
select is(try_exec($$select public.admin_view_fetch(0)$$), 'err:42501', 'as_mal: fetch refused');
select is(try_exec($$select public.admin_view_send(1,1,decode(repeat('ab',1073),'hex'))$$), 'err:42501', 'as_mal: send refused');
reset role;

-- B. as_own_old
select as_own_old();
select is((select count(*) from public.admin_view_state()), 0::bigint, 'as_own_old: state returns no rows');
select is(try_exec($$select public.admin_view_set_phone_key(decode(repeat('11',32),'hex'))$$), 'err:42501', 'as_own_old: admin_view_set_phone_key refused');
select is(try_exec($$select public.admin_view_fetch(0)$$), 'err:42501', 'as_own_old: fetch refused');
select is(try_exec($$select public.admin_view_send(1,1,decode(repeat('ab',1073),'hex'))$$), 'err:42501', 'as_own_old: send refused');
reset role;

-- B. as_own_gone
select as_own_gone();
select is((select count(*) from public.admin_view_state()), 0::bigint, 'as_own_gone: state returns no rows');
select is(try_exec($$select public.admin_view_set_phone_key(decode(repeat('11',32),'hex'))$$), 'err:42501', 'as_own_gone: admin_view_set_phone_key refused');
select is(try_exec($$select public.admin_view_fetch(0)$$), 'err:42501', 'as_own_gone: fetch refused');
select is(try_exec($$select public.admin_view_send(1,1,decode(repeat('ab',1073),'hex'))$$), 'err:42501', 'as_own_gone: send refused');
reset role;

-- B. as_brg
select as_brg();
select is((select count(*) from public.admin_view_state()), 0::bigint, 'as_brg: state returns no rows');
select is(try_exec($$select public.admin_view_set_phone_key(decode(repeat('11',32),'hex'))$$), 'err:42501', 'as_brg: admin_view_set_phone_key refused');
select is(try_exec($$select public.admin_view_fetch(0)$$), 'err:42501', 'as_brg: fetch refused');
select is(try_exec($$select public.admin_view_send(1,1,decode(repeat('ab',1073),'hex'))$$), 'err:42501', 'as_brg: send refused');
reset role;

-- C. as_own
select as_own();
select is(try_exec(format('select public.%s', c)), 'err:42501', 'as_own: ' || c)
from unnest(array[
  'admin_view_bridge_state()',
  'admin_view_bridge_set_key(decode(repeat(''22'',32),''hex''))',
  'admin_view_bridge_put(1,1,decode(repeat(''ab'',1073),''hex''))',
  'admin_view_bridge_take(0)',
  'admin_view_bridge_ack(array[1]::bigint[])'
]) as c;
reset role;

-- D. app access
select as_brg();
reset role;
select is(app_private.has_app_access(), false, 'bridge has no app access');
select as_own();
reset role;
select is(app_private.has_app_access(), true, 'owner has app access');
select set_config('request.jwt.claims','',true);

-- E. Grants for functions
select ok(not has_function_privilege('anon','public.'||s,'execute'), 'anon has no exec on '||s)
from unnest(array[
  'admin_view_state()',
  'admin_view_set_phone_key(bytea)',
  'admin_view_fetch(bigint)',
  'admin_view_send(integer,bigint,bytea)',
  'admin_view_bridge_state()',
  'admin_view_bridge_set_key(bytea)',
  'admin_view_bridge_put(integer,bigint,bytea)',
  'admin_view_bridge_take(bigint)',
  'admin_view_bridge_ack(bigint[])'
]) as s;
select ok(has_function_privilege('authenticated','public.'||s,'execute'), 'authenticated has exec on '||s)
from unnest(array[
  'admin_view_state()',
  'admin_view_set_phone_key(bytea)',
  'admin_view_fetch(bigint)',
  'admin_view_send(integer,bigint,bytea)',
  'admin_view_bridge_state()',
  'admin_view_bridge_set_key(bytea)',
  'admin_view_bridge_put(integer,bigint,bytea)',
  'admin_view_bridge_take(bigint)',
  'admin_view_bridge_ack(bigint[])'
]) as s;

-- F. Table privileges and row security
select ok(not has_table_privilege('authenticated', t, 'select,insert,update,delete'), 'authenticated no dml on '||t)
from unnest(array[
  'app_private.admin_view_keys',
  'app_private.admin_view_items',
  'app_private.admin_view_calls',
  'app_private.admin_view_bridge'
]) as t;
select ok((select relrowsecurity from pg_class where oid = t::regclass), 'row security enabled on '||t)
from unnest(array[
  'app_private.admin_view_keys',
  'app_private.admin_view_items',
  'app_private.admin_view_calls',
  'app_private.admin_view_bridge'
]) as t;

select finish();
rollback;
