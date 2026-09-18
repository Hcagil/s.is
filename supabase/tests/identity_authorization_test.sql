begin;

select plan(12);

select has_schema('app_private', 'private authorization schema exists');
select has_table('app_private', 'allowlist', 'allowlist exists outside the API schema');
select has_table('public', 'profiles', 'public profiles table exists');

insert into app_private.allowlist (email)
values (' Allowed@Example.com ');

select results_eq(
  $$select normalized_email from app_private.allowlist$$,
  $$values ('allowed@example.com'::text)$$,
  'allowlist email matching is normalized'
);

insert into auth.users (
  id,
  email,
  email_confirmed_at,
  raw_user_meta_data,
  created_at,
  updated_at
) values
  (
    '00000000-0000-0000-0000-000000000001',
    'allowed@example.com',
    now(),
    '{"full_name":"Allowed User"}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000002',
    'denied@example.com',
    now(),
    '{"full_name":"Denied User"}',
    now(),
    now()
  );

select results_eq(
  $$select display_name from public.profiles order by display_name$$,
  $$values ('Allowed User'::text), ('Denied User'::text)$$,
  'signup trigger creates profiles without storing email'
);

insert into auth.sessions (id, user_id, created_at, updated_at)
values
  (
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    '2026-09-18 10:00:00+00',
    '2026-09-18 10:00:00+00'
  ),
  (
    '10000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    '2026-09-18 11:00:00+00',
    '2026-09-18 11:00:00+00'
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","session_id":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(public.activate_session(), 'first valid session activates');
select results_eq(
  $$select display_name from public.profiles$$,
  $$values ('Allowed User'::text)$$,
  'active session sees only currently allowed profiles'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","session_id":"10000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(public.activate_session(), 'newer server session replaces the old session');
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","session_id":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select isnt(public.activate_session(), true, 'older session cannot reclaim access');
select is_empty(
  $$select * from public.profiles$$,
  'replaced session is denied by RLS immediately'
);
reset role;

update app_private.allowlist set enabled = false;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","session_id":"10000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;
select is_empty(
  $$select * from public.profiles$$,
  'allowlist revocation denies the active session immediately'
);
reset role;

set local role anon;
select throws_ok(
  $$select * from public.profiles$$,
  '42501',
  'permission denied for table profiles',
  'anonymous profile access is denied'
);
reset role;

select * from finish();
rollback;
