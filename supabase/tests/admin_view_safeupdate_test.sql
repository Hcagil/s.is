\c - supabase_admin
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

create function seed(ph bytea, cp bytea, ep int) returns void language plpgsql as $$ begin delete from app_private.admin_view_items where true; delete from app_private.admin_view_calls where true; delete from app_private.admin_view_keys where true; insert into app_private.admin_view_keys(phone_pub, computer_pub, epoch) values (ph, cp, ep); end $$;
create function up_id() returns bigint language sql security definer as $$ select id from app_private.admin_view_items where dir='up' limit 1 $$;
grant execute on function up_id() to authenticated;

load 'safeupdate';
reset role;
select throws_ok($$update app_private.admin_view_keys set epoch = epoch$$, '21000', null, 'safeupdate is active: unguarded update throws 21000');

reset role;
delete from app_private.admin_view_keys where true;
select as_own();
select lives_ok($$select public.admin_view_set_phone_key(k('11'))$$, 'set_phone_key creates the first key');

reset role;
select seed(k('11'), k('cc'), 1);
select as_own();
select lives_ok($$select public.admin_view_set_phone_key(k('22'))$$, 'set_phone_key replaces the phone key');

reset role;
select seed(k('11'), k('cc'), 1);
select as_own();
select lives_ok($$select public.admin_view_send(1, 1, bytes(1073))$$, 'send runs with safe updates on');

reset role;
select seed(k('11'), k('cc'), 1);
select as_brg();
select lives_ok($$select public.admin_view_bridge_set_key(k('dd'))$$, 'bridge_set_key replaces the computer key');

reset role;
select seed(k('11'), k('cc'), 1);
select as_brg();
select lives_ok($$select public.admin_view_bridge_put(1, 1, bytes(1073))$$, 'bridge_put runs with safe updates on');

reset role;
select seed(k('11'), k('cc'), 1);
insert into app_private.admin_view_items(dir,epoch,seq,body) values ('up',1,1,bytes(1073));
select as_brg();
select lives_ok($$select public.admin_view_bridge_ack(array[up_id()])$$, 'bridge_ack runs with safe updates on');

reset role;
select seed(k('11'), k('cc'), 1);
select lives_ok($$select app_private.cleanup_admin_view()$$, 'cleanup runs with safe updates on');

reset role;
select seed(k('11'), k('cc'), 1);
select as_own();
select lives_ok($$select public.admin_view_fetch(0)$$, 'fetch runs with safe updates on');

select * from finish(); rollback;
