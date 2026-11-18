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

-- avatar
insert into storage.objects(bucket_id,name,owner_id,metadata) values
  ('avatars','profile/00000000-0000-0000-0000-00000000de01/1.jpg',
   '00000000-0000-0000-0000-00000000de01','{"size":3}'::jsonb);
update public.profiles set avatar_path='profile/00000000-0000-0000-0000-00000000de01/1.jpg'
  where user_id='00000000-0000-0000-0000-00000000de01';

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

-- TEST A: no storage queue yet
select is((select count(*)::int from app_private.storage_removal_queue
           where bucket='avatars' and path like 'profile/00000000-0000-0000-0000-00000000de01/%'),
          0, 'prepare queues no file before the delete is final');

-- Ann signs in again (cancel race)
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a2a2a2a2-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-00000000de01', now(), now());
select test_as('00000000-0000-0000-0000-00000000de01', 'a2a2a2a2-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.activate_session_status(); reset role;

-- service_role runs done, swallowing errors
set local role service_role;
do $$
begin
  perform public.account_deletion_done((select rid from _q));
exception when others then null;
end $$;
reset role;

-- TEST B: done does not mark cancelled request done
select is((select outcome from app_private.account_deletion_log
           where request_id = (select rid from _q)),
          'cancelled', 'done does not mark a cancelled request done');

-- TEST C: Ann still exists
select is((select count(*)::int from auth.users where id = '00000000-0000-0000-0000-00000000de01'), 1,
          'Ann still exists');

-- TEST D: cancel removed the pending row
select is((select count(*)::int from app_private.account_deletions
           where user_id = '00000000-0000-0000-0000-00000000de01'), 0,
          'cancel removed the pending row');

-- TEST E: no avatar queued after cancel
select is((select count(*)::int from app_private.storage_removal_queue
           where bucket='avatars' and path like 'profile/00000000-0000-0000-0000-00000000de01/%'),
          0, 'no file of Ann is queued for the sweeper after the cancel');

select * from finish();
rollback;
