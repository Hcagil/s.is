begin;
select plan(6);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000b8','heidi@mail.test',now(),'{"full_name":"Heidi"}'),
 ('00000000-0000-0000-0000-0000000000c9','ivan@mail.test',now(),'{"full_name":"Ivan"}'),
 ('00000000-0000-0000-0000-0000000000d1','judy@mail.test',now(),'{"full_name":"Judy"}');
insert into app_private.member_device (user_id, model, os_version, app_version, build, updated_at) values
 ('00000000-0000-0000-0000-0000000000b8','m','o','v',1, now() - interval '91 days'),
 ('00000000-0000-0000-0000-0000000000c9','m','o','v',1, now() - interval '89 days'),
 ('00000000-0000-0000-0000-0000000000d1','m','o','v',1, now());
select is(app_private.cleanup_member_device()::bigint, 1::bigint, 'cleanup deleted exactly the one old row');
select is((select count(*) from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000b8'), 0::bigint, 'the 91 day old row is gone');
select is((select count(*) from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000c9'), 1::bigint, 'the 89 day old row stays');
select is((select count(*) from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000d1'), 1::bigint, 'the fresh row stays');
delete from auth.users where id='00000000-0000-0000-0000-0000000000c9';
select is((select count(*) from app_private.member_device where user_id='00000000-0000-0000-0000-0000000000c9'), 0::bigint, 'deleting the account deletes its row');
select is((select count(*) from app_private.member_device), 1::bigint, 'only the fresh row is left');
select * from finish();
rollback;
