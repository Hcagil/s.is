-- Fixture to clean up admin view tables after integration tests.
-- Run after the tests; idempotent.
begin;

delete from app_private.admin_view_items;
delete from app_private.admin_view_calls;
delete from app_private.admin_view_keys;
delete from app_private.admin_view_bridge where user_id = 'a0e10000-0000-0000-0000-0000000a0e02';
delete from app_private.owners where user_id = 'a0e10000-0000-0000-0000-0000000a0e01';

commit;
