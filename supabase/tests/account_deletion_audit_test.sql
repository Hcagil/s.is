begin;
select * from no_plan();

-- fixtures ---------------------------------------------------------------
-- create Ann user
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000de01', 'de-ann@mail.test', now(), '{"full_name":"Ann"}');

-- allowlist Ann
insert into app_private.allowlist(email) values ('de-ann@mail.test');

-- create Ann session
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-00000000de01', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- activate Ann
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.activate_session(); reset role;

-- temp tables for request id
create temp table _q(rid uuid);
create temp table _c(user_id uuid, request_id uuid);
grant all on _c to service_role;
grant select on _q to service_role;

-- Ann requests deletion
select test_as('00000000-0000-0000-0000-00000000de01', 'a1a1a1a1-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.request_account_deletion(); reset role;
insert into _q select request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000de01';

-- make it due
update app_private.account_deletions set due_at = now() - interval '1 minute'
  where user_id = '00000000-0000-0000-0000-00000000de01';

-- service_role claims and prepares
set local role service_role;
insert into _c select * from public.account_deletion_claim(10);
reset role;

-- prepare
set local role service_role;
select public.account_deletion_prepare('00000000-0000-0000-0000-00000000de01');
reset role;

-- insert audit log entries ------------------------------------------------
-- marker key "qa":"audit" in every payload
insert into auth.audit_log_entries(instance_id, id, payload, created_at) values
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"audit","actor_id":"00000000-0000-0000-0000-00000000de01","action":"login"}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"audit","action":"user_signedup","traits":{"user_id":"00000000-0000-0000-0000-00000000de01"}}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"audit","actor_username":"DE-ANN@mail.test","action":"login"}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"audit","action":"user_deleted","traits":{"user_email":"De-Ann@Mail.test"}}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"audit","actor_id":"00000000-0000-0000-0000-00000000de09","actor_username":"de-other@mail.test","action":"login"}'::jsonb, now()),
  ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
   '{"qa":"audit","action":"token_refreshed","traits":{"user_id":"00000000-0000-0000-0000-00000000de09","user_email":"de-other@mail.test"}}'::jsonb, now());

-- count audit rows before deletion
select is((select count(*)::int from auth.audit_log_entries
           where payload->>'qa'='audit'), 6,
          '6 audit rows present before deletion');

-- service_role marks deletion done
set local role service_role;
select public.account_deletion_done((select rid from _q), 'de-ann@mail.test');
reset role;

-- assertions -------------------------------------------------------------
-- only two audit rows should remain (e) and (f)
select is((select count(*)::int from auth.audit_log_entries
           where payload->>'qa'='audit'), 2,
          '2 audit rows remain after deletion');

-- check remaining rows are the unrelated ones
select is((select count(*)::int from auth.audit_log_entries
           where (payload->>'actor_id'='00000000-0000-0000-0000-00000000de09'
                  OR payload->'traits'->>'user_id'='00000000-0000-0000-0000-00000000de09')
                 AND payload->>'qa'='audit'), 2,
          'remaining audit rows belong to de09');

-- outcome of the log row for rid
select is((select outcome from app_private.account_deletion_log
           where request_id = (select rid from _q)), 'done',
          'deletion log outcome is done');

-- second call ordering not needed (idempotent)
set local role service_role;
select public.account_deletion_done((select rid from _q), 'de-ann@mail.test');
reset role;

select * from finish();
rollback;
