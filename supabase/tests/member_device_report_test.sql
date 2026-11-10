begin;
select plan(25);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000e5','erin@mail.test',now(),'{"full_name":"Erin"}'),
 ('00000000-0000-0000-0000-0000000000f6','frank@mail.test',now(),'{"full_name":"Frank"}'),
 ('00000000-0000-0000-0000-0000000000a7','grace@mail.test',now(),'{"full_name":"Grace"}');
insert into app_private.allowlist(email) values ('erin@mail.test'),('frank@mail.test');
insert into auth.sessions (id,user_id,created_at,updated_at) values
 ('e5e5e5e5-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000e5',now(),now()),
 ('f6f6f6f6-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000f6',now(),now()),
 ('a7a7a7a7-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a7',now(),now());
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$ begin perform set_config('request.jwt.claims', json_build_object('sub', uid,'role','authenticated','email',(select email from auth.users where id=uid),'session_id',sid)::text, true); execute 'set local role authenticated'; end $$;
select test_as('00000000-0000-0000-0000-0000000000e5','e5e5e5e5-0000-0000-0000-000000000001');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000000f6','f6f6f6f6-0000-0000-0000-000000000001');
select public.activate_session();
reset role;

-- A grace (not allowlisted) is refused (1 assertion)
select test_as('00000000-0000-0000-0000-0000000000a7','a7a7a7a7-0000-0000-0000-000000000001');
select throws_ok($$select public.report_device_info('x','y','z',1,'w')$$, '42501', 'not permitted', 'a user without app access is refused');
reset role;
select is((select count(*) from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000a7'), 0::bigint, 'and nothing was stored for her');

-- B erin reports (7 assertions)
select test_as('00000000-0000-0000-0000-0000000000e5','e5e5e5e5-0000-0000-0000-000000000001');
select public.report_device_info('Pixel 8','14','1.2.3',45,'com.android.vending');
reset role;
select is((select count(*) from app_private.member_device), 1::bigint, 'one row after the first report');
select is((select model from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 'Pixel 8', 'model stored');
select is((select os_version from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), '14', 'os_version stored');
select is((select app_version from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), '1.2.3', 'app_version stored');
select is((select build from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 45::int, 'build stored');
select is((select installer from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 'com.android.vending', 'installer stored');
select is((select count(*) from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000f6'), 0::bigint, 'frank has no row');

-- C frank reports; erin untouched; and the function takes no user id (4 assertions)
select test_as('00000000-0000-0000-0000-0000000000f6','f6f6f6f6-0000-0000-0000-000000000001');
select public.report_device_info('Moto','13','2.0.0',9,null);
reset role;
select is((select model from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000f6'), 'Moto', 'frank model');
select is((select model from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 'Pixel 8', 'erin unchanged');
select is((select count(*) from app_private.member_device), 2::bigint, 'two rows');
select is((select count(*) from pg_proc p where p.proname='report_device_info' and exists (select 1 from unnest(p.proargnames) a where a like '%user%')), 0::bigint, 'the function takes no user id');

-- D erin again overwrites (4 assertions)
update app_private.member_device set updated_at = now() - interval '1 hour' where user_id='00000000-0000-0000-0000-0000000000e5';
select test_as('00000000-0000-0000-0000-0000000000e5','e5e5e5e5-0000-0000-0000-000000000001');
select public.report_device_info('Pixel 9','15','1.2.4',46,null);
reset role;
select is((select count(*) from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 1::bigint, 'erin row count 1');
select is((select model from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 'Pixel 9', 'erin model updated');
select is((select installer from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), null, 'installer null');
select ok((select updated_at from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5') > now() - interval '1 minute', 'updated_at moved forward');

-- E long and blank values (6 assertions)
select test_as('00000000-0000-0000-0000-0000000000e5','e5e5e5e5-0000-0000-0000-000000000001');
select public.report_device_info(repeat('m',200),repeat('o',100),repeat('v',100),7,repeat('i',100));
reset role;
select is(char_length((select model from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5')), 64::int, 'model length 64');
select is(char_length((select os_version from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5')), 32::int, 'os_version length 32');
select is(char_length((select app_version from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5')), 32::int, 'app_version length 32');
select is(char_length((select installer from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5')), 64::int, 'installer length 64');
select test_as('00000000-0000-0000-0000-0000000000e5','e5e5e5e5-0000-0000-0000-000000000001');
select public.report_device_info('   ','','  ',null::integer,'');
reset role;
select is((select model from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 'unknown', 'model unknown');
select is((select build from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000e5'), 0::int, 'build 0');

-- F an allowlisted, activated user is refused without a live session (2 assertions)
-- erin: allowlisted and active, but her JWT carries no session_id
select test_as('00000000-0000-0000-0000-0000000000e5', null);
select throws_ok($$select public.report_device_info('x','y','z',1,'w')$$, '42501', 'not permitted', 'an allowlisted user whose JWT has no session_id is refused');
reset role;
-- frank: allowlisted and active, then his session is revoked (gone from auth.sessions)
delete from auth.sessions where id = 'f6f6f6f6-0000-0000-0000-000000000001';
select test_as('00000000-0000-0000-0000-0000000000f6','f6f6f6f6-0000-0000-0000-000000000001');
select throws_ok($$select public.report_device_info('x','y','z',1,'w')$$, '42501', 'not permitted', 'an allowlisted user whose session was revoked is refused');
reset role;

select * from finish();
rollback;
