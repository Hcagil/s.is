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

-- SETUP
select as_own();
select public.admin_view_set_phone_key(k('11'));
reset role;
select as_brg();
select public.admin_view_bridge_set_key(k('cc'));
reset role;  -- epoch is then 1

-- A. FETCH
reset role;
insert into app_private.admin_view_items(dir,epoch,seq,body)
  select 'down',1,g,bytes(1073) from generate_series(1,250) g;
insert into app_private.admin_view_items(dir,epoch,seq,body)
  values ('down',0,1,bytes(1073)),('up',1,1,bytes(1073));
create temp table t(m bigint);
grant select on t to authenticated;
insert into t select max(id)-10 from app_private.admin_view_items where dir='down' and epoch=1;
select as_own();
select is((select count(*) from public.admin_view_fetch(0)), 200::bigint, 'fetch returns at most 200');
select is((select min(seq) from public.admin_view_fetch(0)), 1::bigint, 'fetch starts at the oldest');
select is((select max(seq) from public.admin_view_fetch(0)), 200::bigint, 'fetch is ordered by id');
select is((select count(*) from public.admin_view_fetch(0) where epoch <> 1), 0::bigint, 'fetch hides other epochs');
select is((select count(*) from public.admin_view_fetch(0) where seq = 1), 1::bigint, 'fetch skips up rows and other epochs');
select is((select count(*) from public.admin_view_fetch((select m from t))), 10::bigint, 'fetch honours after_id');
reset role;

-- B. TAKE
reset role;
delete from app_private.admin_view_items;
insert into app_private.admin_view_items(dir,epoch,seq,body)
  select 'up',1,g,bytes(1073) from generate_series(1,250) g;
insert into app_private.admin_view_items(dir,epoch,seq,body)
  values ('up',0,1,bytes(1073)),('down',1,1,bytes(1073));
select as_brg();
select is((select count(*) from public.admin_view_bridge_take(0)), 200::bigint, 'take returns at most 200');
select is((select count(*) from public.admin_view_bridge_take(0) where epoch <> 1), 0::bigint, 'take hides other epochs');
select is((select count(*) from public.admin_view_bridge_take(0) where seq = 1), 1::bigint, 'take skips down rows');
select is((select min(seq) from public.admin_view_bridge_take(0)), 1::bigint, 'take starts at the oldest');
reset role;

-- C. ACK
reset role;
delete from app_private.admin_view_items;
insert into app_private.admin_view_items(dir,epoch,seq,body)
  values ('up',1,1,bytes(1073)),('up',1,2,bytes(1073)),('up',1,3,bytes(1073)),
         ('down',1,1,bytes(1073)),('down',1,2,bytes(1073));
create temp table ids as select id, dir, seq from app_private.admin_view_items;
grant select on ids to authenticated;
select as_brg();
select is(public.admin_view_bridge_ack(array(select id from ids where dir='up' and seq<=2)), 2, 'ack deletes the named up rows');
reset role;
select is((select count(*) from app_private.admin_view_items where dir='up'), 1::bigint, 'one up row left');
select as_brg();
select is(public.admin_view_bridge_ack(array(select id from ids where dir='down')), 0, 'ack never deletes down rows');
reset role;
select is((select count(*) from app_private.admin_view_items where dir='down'), 2::bigint, 'down rows survive ack');
select as_brg();
select is(try_exec($$select public.admin_view_bridge_ack(null::bigint[])$$), 'err:22023', 'ack null refused');
select is(try_exec($$select public.admin_view_bridge_ack(array(select g::bigint from generate_series(1,201) g))$$), 'err:22023', 'ack of 201 ids refused');
select is(try_exec($$select public.admin_view_bridge_ack(array(select g::bigint from generate_series(1,200) g))$$), 'ok:1', 'ack of 200 ids accepted');
reset role;

-- D. CLEANUP
reset role;
delete from app_private.admin_view_items;
delete from app_private.admin_view_calls;
insert into app_private.admin_view_items(dir,epoch,seq,body,created_at)
  values ('up',1,1,bytes(1073),now()-interval '8 days'),
         ('down',1,1,bytes(1073),now()-interval '8 days'),
         ('up',1,2,bytes(1073),now()-interval '6 days'),
         ('down',1,2,bytes(1073),now()-interval '6 days');
insert into app_private.admin_view_calls(user_id,kind,called_at)
  values ('00000000-0000-0000-0000-0000000a1001','owner_send',now()-interval '2 hours'),
         ('00000000-0000-0000-0000-0000000a1001','owner_send',now()-interval '30 minutes');
select app_private.cleanup_admin_view();
select is((select count(*) from app_private.admin_view_items), 2::bigint, 'items older than 7 days are deleted');
select is((select count(*) from app_private.admin_view_items where seq = 2), 2::bigint, 'the 6 day old items stay');
select is((select count(*) from app_private.admin_view_calls), 1::bigint, 'rate rows older than 1 hour are deleted');
select is((select count(*) from cron.job where jobname = 'admin-view-cleanup' and schedule = '31 * * * *' and command like '%cleanup_admin_view%'), 1::bigint, 'the hourly cleanup job exists');

select * from finish(); rollback;
