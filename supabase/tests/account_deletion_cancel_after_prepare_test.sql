begin;
select * from no_plan();

-- fixtures ---------------------------------------------------------------
-- create Cap user
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000de31', 'de-cap@mail.test', now(), '{"full_name":"Cap"}');

-- allowlist Cap
insert into app_private.allowlist(email) values ('de-cap@mail.test');

-- create Cap session
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a1b1b1b1-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-00000000de31', now(), now());

-- avatar for Cap
insert into storage.objects(bucket_id,name,owner_id,metadata) values ('avatars','profile/00000000-0000-0000-0000-00000000de31/1.jpg','00000000-0000-0000-0000-00000000de31','{"size":3}'::jsonb);
update public.profiles set avatar_path='profile/00000000-0000-0000-0000-00000000de31/1.jpg' where user_id='00000000-0000-0000-0000-00000000de31';

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- activate Cap
select test_as('00000000-0000-0000-0000-00000000de31', 'a1b1b1b1-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.activate_session(); reset role;

-- temp tables for request id
create temp table _q(rid uuid);
create temp table _c(user_id uuid, request_id uuid);
grant all on _c to service_role;
grant select on _q to service_role;

-- Cap requests deletion
select test_as('00000000-0000-0000-0000-00000000de31', 'a1b1b1b1-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.request_account_deletion(); reset role;
insert into _q select request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de31';

-- make it due
update app_private.account_deletions set due_at = now() - interval '1 minute'
  where user_id = '00000000-0000-0000-0000-00000000de31';

-- service_role claims and prepares
set local role service_role;
insert into _c select * from public.account_deletion_claim(10);
reset role;

-- prepare
set local role service_role;
select is((select public.account_deletion_prepare('00000000-0000-0000-0000-00000000de31')), true, 'prepare returns true');
reset role;

-- insert audit log entries ------------------------------------------------
-- marker key "qa":"cap" in every payload
insert into auth.audit_log_entries(instance_id, id, payload, created_at) values
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"cap","actor_id":"00000000-0000-0000-0000-00000000de31","action":"login"}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"cap","action":"user_signedup","traits":{"user_id":"00000000-0000-0000-0000-00000000de31"}}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"cap","actor_username":"DE-CAP@mail.test","action":"login"}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"cap","action":"user_deleted","traits":{"user_email":"De-Cap@Mail.test"}}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"cap","actor_id":"00000000-0000-0000-0000-00000000de09","actor_username":"de-other@mail.test","action":"login"}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"cap","action":"token_refreshed","traits":{"user_id":"00000000-0000-0000-0000-00000000de09","user_email":"de-other@mail.test"}}'::jsonb, now());

-- count audit rows before deletion
select is((select count(*)::int from auth.audit_log_entries
           where payload->>'qa'='cap'), 6,
          '6 audit rows present before deletion');

-- person signs in again to cancel request
insert into auth.sessions (id, user_id, created_at, updated_at) values ('a2b2b2b2-aaaa-aaaa-aaaa-aaaaaaaaaaaa','00000000-0000-0000-0000-00000000de31', now(), now());
select test_as('00000000-0000-0000-0000-00000000de31','a2b2b2b2-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.activate_session_status(); reset role;

-- delete user
delete from auth.users where id = '00000000-0000-0000-0000-00000000de31';

-- service_role marks deletion done
set local role service_role;
select public.account_deletion_done((select rid from _q), 'de-cap@mail.test');
reset role;

-- assertions -------------------------------------------------------------
-- all audit rows for Cap should be gone
select is((select count(*)::int from auth.audit_log_entries
           where payload->>'qa'='cap' and
                 (payload->>'actor_id'='00000000-0000-0000-0000-00000000de31' or
                  payload->'traits'->>'user_id'='00000000-0000-0000-0000-00000000de31')), 0,
          'no audit rows for de31 remain');

-- no audit rows with Cap username/email
select is((select count(*)::int from auth.audit_log_entries
           where payload->>'qa'='cap' and
                 (lower(payload->>'actor_username')='de-cap@mail.test' or
                  lower(payload->'traits'->>'user_email')='de-cap@mail.test')), 0,
          'no audit rows with Cap username/email remain');

-- unrelated de09 row still present
select is((select count(*)::int from auth.audit_log_entries
           where payload->>'qa'='cap' and payload->>'actor_id'='00000000-0000-0000-0000-00000000de09'), 1,
          'unrelated de09 audit row remains');

-- avatar queued for deletion
select ok(exists(select 1 from app_private.storage_removal_queue where bucket='avatars' and path='profile/00000000-0000-0000-0000-00000000de31/1.jpg'), 'avatar queued');

select * from finish();
rollback;
