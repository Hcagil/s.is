begin;
select plan(36);

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

-- 1. No keys row as brg: bridge_put(1,1,bytes(1073)) -> err:22023
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,1,bytes(1073))$$), 'err:22023', 'no keys row refused');
reset role;

-- 2. keys: phone key then computer key
select as_own();
select public.admin_view_set_phone_key(k('11'));
reset role;
select as_brg();
select public.admin_view_bridge_set_key(k('cc'));
reset role;
-- 3. put refused while computer_pub is null
update app_private.admin_view_keys set computer_pub = null;
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,1,bytes(1073))$$), 'err:22023', 'put refused while computer_pub is null');
reset role;
update app_private.admin_view_keys set computer_pub = k('cc');

-- 4. Sizes as brg (epoch 1)
select as_brg();
-- 1073 accepted
select is(try_exec($$select public.admin_view_bridge_put(1,1,bytes(1073))$$), 'ok:1', '1073 accepted');
-- 1072 too small
select is(try_exec($$select public.admin_view_bridge_put(1,90,bytes(1072))$$), 'err:22023', '1072 too small');
-- 1074 too large
select is(try_exec($$select public.admin_view_bridge_put(1,90,bytes(1074))$$), 'err:22023', '1074 too large');
-- 2096 not multiple
select is(try_exec($$select public.admin_view_bridge_put(1,90,bytes(2096))$$), 'err:22023', '2096 not multiple');
-- 0 bytes
select is(try_exec($$select public.admin_view_bridge_put(1,90,bytes(0))$$), 'err:22023', '0 bytes');
-- null bytea
select is(try_exec($$select public.admin_view_bridge_put(1,90,null::bytea)$$), 'err:22023', 'null bytea');
-- 65585 accepted
select is(try_exec($$select public.admin_view_bridge_put(1,2,bytes(65585))$$), 'ok:1', '65585 accepted, the down maximum');
-- 66609 too large
select is(try_exec($$select public.admin_view_bridge_put(1,90,bytes(66609))$$), 'err:22023', 'max + 1024 refused');
-- 65584 too small
select is(try_exec($$select public.admin_view_bridge_put(1,90,bytes(65584))$$), 'err:22023', '65584 too small');
-- null bytea
select is(try_exec($$select public.admin_view_bridge_put(1,90,null::bytea)$$), 'err:22023', 'null bytea');
reset role;

-- 5. Seq/Epoch checks
select as_brg();
-- equal seq
select is(try_exec($$select public.admin_view_bridge_put(1,2,bytes(1073))$$), 'err:22023', 'equal seq refused');
-- lower seq
select is(try_exec($$select public.admin_view_bridge_put(1,1,bytes(1073))$$), 'err:22023', 'lower seq refused');
-- lower epoch
select is(try_exec($$select public.admin_view_bridge_put(1,0,bytes(1073))$$), 'err:22023', 'lower epoch refused');
-- negative epoch
select is(try_exec($$select public.admin_view_bridge_put(1,-1,bytes(1073))$$), 'err:22023', 'negative epoch refused');
-- null epoch
select is(try_exec($$select public.admin_view_bridge_put(1,null::bigint,bytes(1073))$$), 'err:22023', 'null epoch refused');
-- null uid
select is(try_exec($$select public.admin_view_bridge_put(null::int,50,bytes(1073))$$), 'err:22023', 'null uid refused');
-- wrong epoch
select is(try_exec($$select public.admin_view_bridge_put(2,50,bytes(1073))$$), 'err:22023', 'wrong epoch refused');
-- zero uid
select is(try_exec($$select public.admin_view_bridge_put(0,50,bytes(1073))$$), 'err:22023', 'zero uid refused');
-- gap
select is(try_exec($$select public.admin_view_bridge_put(1,10,bytes(1073))$$), 'ok:1', 'gap accepted');
reset role;

-- 6. Rate 120/h
-- fill 119 calls
delete from app_private.admin_view_calls;
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1003','bridge_put',now() from generate_series(1,119);
select as_brg();
-- 120th allowed
select is(try_exec($$select public.admin_view_bridge_put(1,11,bytes(1073))$$), 'ok:1', '120th put in the hour allowed');
-- 121st refused
select is(try_exec($$select public.admin_view_bridge_put(1,12,bytes(1073))$$), 'err:RLMT1', '121st put refused');
reset role;
-- old calls older than 2 hours
delete from app_private.admin_view_calls;
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1003','bridge_put',now() - interval '2 hours' from generate_series(1,200);
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,12,bytes(1073))$$), 'ok:1', 'old calls do not count');
reset role;
-- owner_send calls do not count
delete from app_private.admin_view_calls;
insert into app_private.admin_view_calls(user_id,kind,called_at)
select '00000000-0000-0000-0000-0000000a1003','owner_send',now() from generate_series(1,200);
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,13,bytes(1073))$$), 'ok:1', 'owner_send calls do not count against bridge put');
reset role;

-- 7. Retention 20 and replay after trim
reset role;
delete from app_private.admin_view_calls;
delete from app_private.admin_view_items;
insert into app_private.admin_view_items(dir,epoch,seq,body)
select 'up',1,g,bytes(1073) from generate_series(1,3) g;
select as_brg();
select public.admin_view_bridge_put(1, g, bytes(1073)) from generate_series(100,124) g;
reset role;
select is((select count(*) from app_private.admin_view_items where dir='down'), 20::bigint, 'only the newest 20 down rows are kept');
select is((select min(seq) from app_private.admin_view_items where dir='down'), 105::bigint, 'oldest kept down seq is 105');
select is((select max(seq) from app_private.admin_view_items where dir='down'), 124::bigint, 'newest down seq is 124');
select is((select count(*) from app_private.admin_view_items where dir='up'), 3::bigint, 'trimming does not touch up rows');

-- 8. F5 corrected behaviour
-- F5 corrected behaviour, red until the server is fixed
select as_brg();
select is(try_exec($$select public.admin_view_bridge_put(1,90,bytes(1073))$$), 'err:22023', 'seq of a trimmed down row is still refused');
-- F5 corrected behaviour, red until the server is fixed
select is(try_exec($$select public.admin_view_bridge_put(1,124,bytes(1073))$$), 'err:22023', 'equal to the last seq still refused');
select is(try_exec($$select public.admin_view_bridge_put(1,125,bytes(1073))$$), 'ok:1', 'new seq accepted');

-- 9. Up after ack
reset role;
delete from app_private.admin_view_items;
-- send up seq 5
select as_own();
select is(try_exec($$select public.admin_view_send(1,5,bytes(1073))$$), 'ok:1', 'send seq 5 accepted');
-- ack all up rows
reset role;
delete from app_private.admin_view_items where dir='up';
-- send again seq 5 should be refused
select as_own();
-- F5 corrected behaviour, red until the server is fixed
select is(try_exec($$select public.admin_view_send(1,5,bytes(1073))$$), 'err:22023', 'seq already acknowledged is still refused');
-- F5 corrected behaviour, red until the server is fixed
-- lower seq after ack refused
select is(try_exec($$select public.admin_view_send(1,4,bytes(1073))$$), 'err:22023', 'lower seq after ack refused');
-- higher seq accepted
select is(try_exec($$select public.admin_view_send(1,6,bytes(1073))$$), 'ok:1', 'higher seq accepted');

select * from finish(); rollback;
