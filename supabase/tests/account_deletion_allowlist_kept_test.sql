begin;
select * from no_plan();

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

create temp table _q(uid uuid, rid uuid);
create temp table _c(user_id uuid, request_id uuid);
grant all on _c to service_role;
grant select on _q to service_role;

-- Cara: pending account (auth user stays) ---------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000db11', 'cara@mail.test', now(), '{"full_name":"Cara"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('c0c0c0c0-1111-1111-1111-111111111111', '00000000-0000-0000-0000-00000000db11', now(), now());
insert into app_private.allowlist(email) values ('cara@mail.test');
select test_as('00000000-0000-0000-0000-00000000db11', 'c0c0c0c0-1111-1111-1111-111111111111'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000db11', 'c0c0c0c0-1111-1111-1111-111111111111'); select public.request_account_deletion(); reset role;
insert into _q select user_id, request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000db11';
update app_private.account_deletions set due_at = now() - interval '1 minute' where user_id = '00000000-0000-0000-0000-00000000db11';
set local role service_role; insert into _c select * from public.account_deletion_claim(10); reset role;
set local role service_role; select public.account_deletion_prepare('00000000-0000-0000-0000-00000000db11'); reset role;
set local role service_role; select public.account_deletion_done((select rid from _q where uid = '00000000-0000-0000-0000-00000000db11')); reset role;
select is((select count(*)::int from app_private.allowlist where email = 'cara@mail.test'), 1, 'pending account keeps its invite');
select is((select count(*)::int from auth.users where id = '00000000-0000-0000-0000-00000000db11'), 1, 'cara auth user still exists');

-- Dana: cancelled request --------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000db12', 'dana@mail.test', now(), '{"full_name":"Dana"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('d0d0d0d0-2222-2222-2222-222222222222', '00000000-0000-0000-0000-00000000db12', now(), now());
insert into app_private.allowlist(email) values ('dana@mail.test');
select test_as('00000000-0000-0000-0000-00000000db12', 'd0d0d0d0-2222-2222-2222-222222222222'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000db12', 'd0d0d0d0-2222-2222-2222-222222222222'); select public.request_account_deletion(); reset role;
insert into _q select user_id, request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000db12';
update app_private.account_deletions set due_at = now() - interval '1 minute' where user_id = '00000000-0000-0000-0000-00000000db12';
set local role service_role; insert into _c select * from public.account_deletion_claim(10); reset role;
set local role service_role; select public.account_deletion_prepare('00000000-0000-0000-0000-00000000db12'); reset role;
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('d1d1d1d1-2222-2222-2222-222222222222', '00000000-0000-0000-0000-00000000db12', now(), now());
select test_as('00000000-0000-0000-0000-00000000db12', 'd1d1d1d1-2222-2222-2222-222222222222'); select public.activate_session_status(); reset role;
set local role service_role; select public.account_deletion_done((select rid from _q where uid = '00000000-0000-0000-0000-00000000db12')); reset role;
select is((select count(*)::int from app_private.allowlist where email = 'dana@mail.test'), 1, 'cancelled request keeps its invite');

select * from finish();
rollback;
