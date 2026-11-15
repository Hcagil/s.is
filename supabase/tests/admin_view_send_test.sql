begin;
select plan(45);

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


-- 1. No keys row as own: send(1,1,bytes(1073)) -> 'err:22023'
select as_own();
select is(try_exec($$select public.admin_view_send(1,1,bytes(1073))$$), 'err:22023', 'no keys row refused');
reset role;

-- 2. Set phone key, send still refused because computer_pub not set
select as_own();
select public.admin_view_set_phone_key(k('11'));
-- M2 corrected behaviour, red until the server is fixed
select is(try_exec($$select public.admin_view_send(1,1,bytes(1073))$$), 'err:22023', 'send refused while computer_pub is not set');
reset role;
-- cleanup
delete from app_private.admin_view_items;
delete from app_private.admin_view_calls;

-- 3. Set bridge key
select as_brg();
select public.admin_view_bridge_set_key(k('cc'));
reset role;

-- 4. Sizes as own (epoch 1)
select as_own();
-- 1073 accepted
select is(try_exec($$select public.admin_view_send(1,1,bytes(1073))$$), 'ok:1', '1073 accepted');
-- 1072 too small
select is(try_exec($$select public.admin_view_send(1,90,bytes(1072))$$), 'err:22023', '1072 too small');
-- 1074 too large
select is(try_exec($$select public.admin_view_send(1,90,bytes(1074))$$), 'err:22023', '1074 too large');
-- 2096 not multiple
select is(try_exec($$select public.admin_view_send(1,90,bytes(2096))$$), 'err:22023', '2096 not multiple');
-- 0 bytes
select is(try_exec($$select public.admin_view_send(1,90,bytes(0))$$), 'err:22023', '0 bytes');
-- null bytea
select is(try_exec($$select public.admin_view_send(1,90,null::bytea)$$), 'err:22023', 'null bytea');
-- 2097 accepted
select is(try_exec($$select public.admin_view_send(1,2,bytes(2097))$$), 'ok:1', '2097 accepted');
-- 8241 accepted
select is(try_exec($$select public.admin_view_send(1,3,bytes(8241))$$), 'ok:1', '8241 accepted, the up maximum');
-- 8240 too small
select is(try_exec($$select public.admin_view_send(1,90,bytes(8240))$$), 'err:22023', '8240 too small');
-- 9265 too large
select is(try_exec($$select public.admin_view_send(1,90,bytes(9265))$$), 'err:22023', 'max + 1024 refused');
reset role;

-- 5. Seq/Epoch checks
select as_own();
-- equal seq
select is(try_exec($$select public.admin_view_send(1,3,bytes(1073))$$), 'err:22023', 'equal seq refused');
-- lower seq
select is(try_exec($$select public.admin_view_send(1,2,bytes(1073))$$), 'err:22023', 'lower seq refused');
-- lower epoch
select is(try_exec($$select public.admin_view_send(1,0,bytes(1073))$$), 'err:22023', 'lower epoch refused');
-- negative epoch
select is(try_exec($$select public.admin_view_send(1,-1,bytes(1073))$$), 'err:22023', 'negative epoch refused');
-- null epoch
select is(try_exec($$select public.admin_view_send(1,null::bigint,bytes(1073))$$), 'err:22023', 'null epoch refused');
-- null uid
select is(try_exec($$select public.admin_view_send(null::int,50,bytes(1073))$$), 'err:22023', 'null uid refused');
-- wrong epoch
select is(try_exec($$select public.admin_view_send(2,50,bytes(1073))$$), 'err:22023', 'wrong epoch refused');
-- zero uid
select is(try_exec($$select public.admin_view_send(0,50,bytes(1073))$$), 'err:22023', 'zero uid refused');
-- gap
select is(try_exec($$select public.admin_view_send(1,10,bytes(1073))$$), 'ok:1', 'gap accepted');
reset role;

-- 6. Rate 240/h (other)
-- fill 239 calls
delete from app_private.admin_view_calls;
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1001','owner_send',now() from generate_series(1,239);
select as_own();
-- 60th allowed
select is(try_exec($$select public.admin_view_send(1,11,bytes(1073))$$), 'ok:1', '240th send in the hour is allowed');
-- 61st refused
select is(try_exec($$select public.admin_view_send(1,12,bytes(1073))$$), 'err:RLMT1', '241st send refused');
reset role;
-- old calls older than 2 hours
delete from app_private.admin_view_calls;
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1001','owner_send',now() - interval '2 hours' from generate_series(1,100);
select as_own();
select is(try_exec($$select public.admin_view_send(1,12,bytes(1073))$$), 'ok:1', 'old calls do not count');
reset role;
-- bridge_put calls do not count
delete from app_private.admin_view_calls;
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1001','bridge_put',now() from generate_series(1,100);
select as_own();
select is(try_exec($$select public.admin_view_send(1,13,bytes(1073))$$), 'ok:1', 'bridge_put calls do not count against owner send');
reset role;

-- 7. Capacity 200
delete from app_private.admin_view_calls;
delete from app_private.admin_view_items;
update app_private.admin_view_keys set last_up_seq = 1999;
insert into app_private.admin_view_items(dir,epoch,seq,body)
select 'up',1,g,bytes(1073) from generate_series(1000,1199) g;
select as_own();
select is(try_exec($$select public.admin_view_send(1,2000,bytes(1073))$$), 'err:RLMT1', '200 up rows: refused');
reset role;
delete from app_private.admin_view_items where seq = 1000;
select as_own();
select is(try_exec($$select public.admin_view_send(1,2000,bytes(1073))$$), 'ok:1', '199 up rows: accepted');
reset role;

-- 8. Kinds, bounds, compat, grants
delete from app_private.admin_view_calls;
delete from app_private.admin_view_items;
update app_private.admin_view_keys set last_up_seq = 5000;
-- 'other' at 240: reads still pass, counters independent
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1001','owner_send',now() from generate_series(1,240);
select as_own();
select is(try_exec($$select public.admin_view_send(1,5001,bytes(1073),'other')$$), 'err:RLMT1', 'other: 241st refused');
select is(try_exec($$select public.admin_view_send(1,5001,bytes(1073),'read')$$), 'ok:1', 'read not blocked when other is at 240');
reset role;
select is((select count(*)::int from app_private.admin_view_calls where kind='owner_send'), 240, 'refused other left no row');
select is((select count(*)::int from app_private.admin_view_calls where kind='owner_read'), 1, 'read counted as owner_read');
-- reads: 720 ok, 721st refused
delete from app_private.admin_view_calls;
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1001','owner_read',now() from generate_series(1,719);
select as_own();
select is(try_exec($$select public.admin_view_send(1,5002,bytes(1073),'read')$$), 'ok:1', '720th read allowed');
select is(try_exec($$select public.admin_view_send(1,5003,bytes(1073),'read')$$), 'err:RLMT1', '721st read refused');
reset role;
select is((select count(*)::int from app_private.admin_view_calls where kind='owner_read'), 720, 'refused read left no row');
-- bad kind
delete from app_private.admin_view_calls;
select as_own();
select is(try_exec($$select public.admin_view_send(1,5003,bytes(1073),'bogus')$$), 'err:22023', 'bogus kind refused');
select is(try_exec($$select public.admin_view_send(1,5003,bytes(1073),null)$$), 'err:22023', 'null kind refused');
-- seq bound: +1001 refused, +1000 ok
select is(try_exec($$select public.admin_view_send(1,6003,bytes(1073))$$), 'err:22023', '+1001 refused');
reset role;
select is((select last_up_seq from app_private.admin_view_keys), 5002::bigint, 'refused call changed nothing');
select is((select count(*)::int from app_private.admin_view_calls), 0, 'refused bound left no call row');
select as_own();
select is(try_exec($$select public.admin_view_send(1,6002,bytes(1073))$$), 'ok:1', '+1000 accepted');
-- backward compat: 3 named args counted as owner_send
select is(try_exec($$select public.admin_view_send(p_epoch => 1, p_seq => 6003, p_body => bytes(1073))$$), 'ok:1', 'named 3-arg call works');
reset role;
select is((select count(*)::int from app_private.admin_view_calls where kind='owner_send'), 2, 'default kind and named 3-arg both counted as owner_send');
select is((select count(*)::int from app_private.admin_view_calls where kind='owner_read'), 0, 'no read rows from 3-arg calls');
-- anon cannot execute
select is(has_function_privilege('anon','public.admin_view_send(integer,bigint,bytea,text)','execute'), false, 'anon cannot execute');
select is(has_function_privilege('authenticated','public.admin_view_send(integer,bigint,bytea,text)','execute'), true, 'authenticated can execute');

select * from finish(); rollback;
