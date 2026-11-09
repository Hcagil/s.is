-- The staff rows and their loader are dead: the private pack serves the staff chats now. Drop them (forward-only).
drop function if exists app_private.admin_handle(uuid, uuid, text);
drop function if exists app_private.sales_handle(uuid, uuid, text);
drop function if exists app_private.staff_load(jsonb);
drop table if exists app_private.staff_commands;
drop table if exists app_private.staff_chats;
