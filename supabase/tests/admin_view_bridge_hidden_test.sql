begin;
select plan(8);
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated', 'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function h(e text) returns text language sql immutable as $$ select encode(sha256(convert_to(lower(btrim(e)), 'UTF8')), 'hex') $$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000a1001','ann@mail.test',now(),'{"full_name":"Ann"}'),
 ('00000000-0000-0000-0000-0000000a1002','bob@mail.test',now(),'{"full_name":"Bob"}'),
 ('00000000-0000-0000-0000-0000000a1003','brg@mail.test',now(),'{"full_name":"Brg"}');
insert into app_private.allowlist(email) values ('ann@mail.test'),('bob@mail.test'),('brg@mail.test');
insert into app_private.admin_view_bridge(user_id) values ('00000000-0000-0000-0000-0000000a1003');
insert into auth.sessions (id,user_id,created_at,updated_at) values
 ('a1000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000a1001', now(), now());
select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000001'); select public.activate_session(); reset role;
create function as_ann() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000a1001','a1000000-0000-0000-0000-000000000001') $$;
grant execute on function as_ann() to authenticated;

select as_ann();
select is((select count(*) from public.find_by_contacts(array[h('bob@mail.test')])), 1::bigint, 'control: a normal member is found');
select is((select count(*) from public.find_by_contacts(array[h('brg@mail.test')])), 0::bigint, 'the bridge account is not found by contacts');
reset role;
insert into public.release_notes(build, note) values (900, 'n900');
select is((select count(*) from app_private.release_note_sent where user_id = '00000000-0000-0000-0000-0000000a1002'), 1::bigint, 'control: bob got the release note');
select is((select count(*) from app_private.release_note_sent where user_id = '00000000-0000-0000-0000-0000000a1003'), 0::bigint, 'the bridge got no release note row');
select is((select count(*) from public.conversation_members where user_id = '00000000-0000-0000-0000-0000000a1003'), 0::bigint, 'the bridge was put in no conversation');
insert into public.conversations(id) values ('c0000000-0000-0000-0000-0000000a1001');
select is(app_private.admin_cmd_list('c0000000-0000-0000-0000-0000000a1001'), 'ok', 'the list command ran');
select is((select (admin_msg->>'n')::int from public.messages where conversation_id = 'c0000000-0000-0000-0000-0000000a1001' order by created_at desc limit 1), (select count(*)::int from app_private.allowlist where email <> 'brg@mail.test'), 'the tester list does not count the bridge');
select is((select admin_msg::text like '%brg@mail.test%' from public.messages where conversation_id = 'c0000000-0000-0000-0000-0000000a1001' order by created_at desc limit 1), false, 'the tester list does not show the bridge email');

select * from finish(); rollback;
