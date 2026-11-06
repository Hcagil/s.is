-- Fixture for test/integration/staff_registry_repository_test.dart, run by the
-- runner (docker exec psql) before the integration tests: a member's staff
-- chat needs app_private rows and a staff_key no client can write.
--
-- Only staff_b is loaded (staff_load replaces the commands of the keys it
-- names); the pgTAP files clear staff_commands before their own loads.
-- Idempotent; the password exists only on the local stack.
begin;
insert into app_private.allowlist(email) values ('staffreg-member@sis.test'), ('staffreg-outsider@sis.test')
on conflict do nothing;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
       extensions.crypt('integration-password', extensions.gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', u.name), now(), now(),
       '', '', '', ''
  from (values ('5a0f0000-0000-0000-0000-0000000005a1'::uuid, 'staffreg-member@sis.test', 'Staffreg Member'),
               ('5a0f0000-0000-0000-0000-0000000005a2'::uuid, 'staffreg-outsider@sis.test', 'Staffreg Outsider')) u(id, email, name)
on conflict (id) do nothing;
insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'email',
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), now(), now()
  from auth.users u where u.id in ('5a0f0000-0000-0000-0000-0000000005a1', '5a0f0000-0000-0000-0000-0000000005a2')
on conflict do nothing;

select app_private.staff_load('{
  "chats": [{"key":"staff_b","title_en":"Staff B","title_tr":"Ekip B","sort":2}],
  "commands": [
    {"chat_key":"staff_b","word":"/sales","handler":"sales_total","help_en":"total","help_tr":"toplam","sort":1}]
}'::jsonb);

-- The member becomes a command admin the way production does it; the trigger
-- gives them their own staff_b chat. The outsider gets nothing.
insert into app_private.command_admins(user_id) values ('5a0f0000-0000-0000-0000-0000000005a1')
on conflict do nothing;
commit;
