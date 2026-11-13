begin;
select plan(14);
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ab0f1', 'jown@mail.test', now(), '{"full_name":"Jown"}');
insert into app_private.allowlist(email) values ('jown@mail.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ab0f0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ab0f1', now(), now());
select test_as('00000000-0000-0000-0000-0000000ab0f1', 'ab0f0000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'fixture: the owner is active');
reset role;
insert into app_private.owners(user_id) values ('00000000-0000-0000-0000-0000000ab0f1');
create temp table adm as select id from public.conversations where admin_chat and staff_key = 'staff_a';
-- one reply, returns the stored admin_msg
create function reply(k text) returns jsonb language plpgsql as $$
declare rid uuid;
begin
  rid := app_private.admin_reply((select id from adm), jsonb_build_object('k', k, 'amt', '7', 'day', '2026-01-05', 'at', now(), 't', 'x'));
  return (select admin_msg from public.messages where id = rid);
end $$;
select has_column('public','conversations','staff_b_chat','conversations has staff_b_chat');
select is(array(select column_name::text from information_schema.columns where table_schema='public' and table_name='conversations' and column_name like '%\_chat' order by 1), array['admin_chat','debug_chat','staff_b_chat'], 'only the expected _chat columns');
select is(array(select proname::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and proname like 'is\_%\_chat' order by 1), array['is_admin_chat','is_staff_b_chat'], '...');
select has_function('app_private','is_staff_b_chat',array['uuid']);
select is(array(select policyname::text from pg_policies where schemaname='public' and tablename='messages' and policyname like 'messages\_send%' order by 1), array['messages_send','messages_send_admin','messages_send_staff_b'], '...');
select ok(position('your tester group' in app_private.admin_body('{"k":"andOk","e":"x"}'::jsonb)) > 0, 'admin text names your tester group');
select ok(to_regprocedure('app_private.private_source()') is null, 'fixture: no private_source locally');
select is(reply('salesTotal') ? 'src', false, 'salesTotal: no src without private_source');
select is(reply('salesTotalPrev') ? 'src', false, 'salesTotalPrev: no src without private_source');
create function app_private.private_source() returns text language sql as $f$ select 'QaSource'::text $f$;
select is(reply('salesTotal')->>'src', 'QaSource', 'salesTotal gets src');
select is(reply('salesTotalPrev')->>'src', 'QaSource', 'salesTotalPrev gets src');
select is(reply('note') ? 'src', false, 'note gets no src');
create or replace function app_private.private_source() returns text language sql as $f$ select ''::text $f$;
select is(reply('salesTotal') ? 'src', false, 'empty source name gives no src');
select * from finish(); rollback;
