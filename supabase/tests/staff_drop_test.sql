-- why: a migration dropped the old staff registry tables and loaders; nothing may bring them back
begin;
select plan(6);
select is(to_regclass('app_private.staff_commands')::text, null, 'staff_commands is gone');
select is(to_regclass('app_private.staff_chats')::text, null, 'staff_chats is gone');
select is(to_regprocedure('app_private.staff_load(jsonb)')::text, null, 'staff_load is gone');
select is(to_regprocedure('app_private.admin_handle(uuid,uuid,text)')::text, null, 'admin_handle is gone');
select is(to_regprocedure('app_private.sales_handle(uuid,uuid,text)')::text, null, 'sales_handle is gone');
select is((select count(*) from public.staff_registry()), 0::bigint, 'without a private panel the staff registry returns no rows');
select * from finish();
rollback;
