begin;
select plan(19);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000e5','erin@mail.test',now(),'{"full_name":"Erin"}');
insert into app_private.allowlist(email) values ('erin@mail.test');
create or replace function test_as(uid uuid) returns void language plpgsql as $$ begin perform set_config('request.jwt.claims', json_build_object('sub', uid,'role','authenticated','email','erin@mail.test')::text, true); execute 'set local role authenticated'; end $$;
-- 1
select is((select relrowsecurity from pg_class where oid = 'app_private.member_device'::regclass), true, 'row level security is on');
-- 2
select is((select count(*) from pg_policies where schemaname='app_private' and tablename='member_device'), 0::bigint, 'no client policy exists');
-- 3 (8 lines, one per role x privilege, same shape):
select is(has_table_privilege('anon','app_private.member_device','select'), false, 'anon has no select');
select is(has_table_privilege('anon','app_private.member_device','insert'), false, 'anon has no insert');
select is(has_table_privilege('anon','app_private.member_device','update'), false, 'anon has no update');
select is(has_table_privilege('anon','app_private.member_device','delete'), false, 'anon has no delete');
select is(has_table_privilege('authenticated','app_private.member_device','select'), false, 'authenticated has no select');
select is(has_table_privilege('authenticated','app_private.member_device','insert'), false, 'authenticated has no insert');
select is(has_table_privilege('authenticated','app_private.member_device','update'), false, 'authenticated has no update');
select is(has_table_privilege('authenticated','app_private.member_device','delete'), false, 'authenticated has no delete');
-- 4
select test_as('00000000-0000-0000-0000-0000000000e5');
select throws_ok($$select * from app_private.member_device$$, '42501', null, 'authenticated cannot read the table');
select throws_ok($$insert into app_private.member_device(user_id,model,os_version,app_version,build) values (gen_random_uuid(),'m','o','v',1)$$, '42501', null, 'authenticated cannot insert into the table');
select throws_ok($$update app_private.member_device set model='x'$$, '42501', null, 'authenticated cannot update the table');
select throws_ok($$delete from app_private.member_device$$, '42501', null, 'authenticated cannot delete from the table');
select throws_ok($$select app_private.cleanup_member_device()$$, '42501', null, 'authenticated cannot call cleanup_member_device');
reset role;
-- 5 anon cannot call the RPC
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
select throws_ok($$select public.report_device_info('a','b','c',1,'d')$$, '42501', null, 'anon cannot call report_device_info');
reset role;
select is(has_function_privilege('anon','public.report_device_info(text,text,text,integer,text)','execute'), false, 'anon has no execute on report_device_info');
select is(has_function_privilege('authenticated','app_private.cleanup_member_device()','execute'), false, 'authenticated has no execute on the cleanup');
-- 6 cron
select is((select count(*) from cron.job where jobname='member-device-cleanup' and schedule='23 3 * * *'), 1::bigint, 'the cleanup job exists once, daily 03:23');
select * from finish();
rollback;
