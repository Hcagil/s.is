-- Fixture for test/integration/admin_view_repository_test.dart, run by the
-- runner (docker exec psql) before the integration tests: creates two users
-- (owner and bridge) and populates the admin view tables.
--
-- Idempotent; the password exists only on the local stack.
begin;

-- 1. Insert both emails into app_private.allowlist(email) on conflict do nothing.
insert into app_private.allowlist(email)
values ('avowner@sis.test'), ('avbridge@sis.test')
on conflict do nothing;

-- 2. Insert both users into auth.users and auth.identities exactly like the template
--    (password 'integration-password' via extensions.crypt).
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000',
       u.id,
       'authenticated',
       'authenticated',
       u.email,
       extensions.crypt('integration-password', extensions.gen_salt('bf')),
       now(),
       '{"provider":"email","providers":["email"]}',
       jsonb_build_object('full_name', u.name),
       now(),
       now(),
       '',
       '',
       '',
       ''
  from (values
          ('a0e10000-0000-0000-0000-0000000a0e01'::uuid, 'avowner@sis.test', 'Av Owner'),
          ('a0e10000-0000-0000-0000-0000000a0e02'::uuid, 'avbridge@sis.test', 'Av Bridge')
        ) u(id, email, name)
on conflict (id) do nothing;

insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at)
select gen_random_uuid(),
       u.id,
       u.id::text,
       'email',
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       now(),
       now()
  from auth.users u
 where u.id in ('a0e10000-0000-0000-0000-0000000a0e01', 'a0e10000-0000-0000-0000-0000000a0e02')
on conflict do nothing;

-- 3. Insert into app_private.owners(user_id) values (owner id) on conflict do nothing
insert into app_private.owners(user_id)
values ('a0e10000-0000-0000-0000-0000000a0e01')
on conflict do nothing;

-- 4. Insert into app_private.admin_view_bridge(user_id) values (bridge id) on conflict do nothing
insert into app_private.admin_view_bridge(user_id)
values ('a0e10000-0000-0000-0000-0000000a0e02')
on conflict do nothing;

-- 5. Reset: delete from app_private.admin_view_items; delete from app_private.admin_view_calls; delete from app_private.admin_view_keys;
delete from app_private.admin_view_items;
delete from app_private.admin_view_calls;
delete from app_private.admin_view_keys;

commit;
