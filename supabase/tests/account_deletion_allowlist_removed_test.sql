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

-- Bob (steps 1-3 only) ----------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000db02', 'bob@mail.test', now(), '{"full_name":"Bobby Tester"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b2000000-0000-0000-0000-00000000db02', '00000000-0000-0000-0000-00000000db02', now(), now());
insert into app_private.allowlist(email) values ('bob@mail.test');
select test_as('00000000-0000-0000-0000-00000000db02', 'b2000000-0000-0000-0000-00000000db02'); select public.activate_session(); reset role;

-- Alice (steps 1-10) ------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000db01', 'Alice@Mail.Test', now(), '{"full_name":"Alice Tester"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a1000000-0000-0000-0000-00000000db01', '00000000-0000-0000-0000-00000000db01', now(), now());
insert into app_private.allowlist(email) values ('alice@mail.test');
select test_as('00000000-0000-0000-0000-00000000db01', 'a1000000-0000-0000-0000-00000000db01'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000db01', 'a1000000-0000-0000-0000-00000000db01'); select public.request_account_deletion(); reset role;
insert into _q select user_id, request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000db01';
update app_private.account_deletions set due_at = now() - interval '1 minute' where user_id = '00000000-0000-0000-0000-00000000db01';
set local role service_role; insert into _c select * from public.account_deletion_claim(10); reset role;
set local role service_role; select public.account_deletion_prepare('00000000-0000-0000-0000-00000000db01'); reset role;
delete from auth.users where id = '00000000-0000-0000-0000-00000000db01';
set local role service_role; select public.account_deletion_done((select rid from _q where uid = '00000000-0000-0000-0000-00000000db01')); reset role;

select is((select count(*)::int from app_private.allowlist where email = 'alice@mail.test'), 0, 'alice e-mail leaves the invite list at day 30');
select is((select count(*)::int from app_private.allowlist where email = 'bob@mail.test'), 1, 'bob e-mail stays on the invite list');

-- done a second time ------------------------------------------------------
set local role service_role;
select lives_ok(format('select public.account_deletion_done(%L)', (select rid from _q where uid = '00000000-0000-0000-0000-00000000db01')), 'done twice does not fail');
reset role;
select is((select count(*)::int from app_private.allowlist where email = 'bob@mail.test'), 1, 'bob row still there after second done');
select is((select count(*)::int from app_private.allowlist where email = 'alice@mail.test'), 0, 'alice row still gone after second done');

-- returning person is invited again --------------------------------------
select lives_ok($$insert into app_private.allowlist(email) values ('alice@mail.test')$$, 'returning person is invited again');
select is((select count(*)::int from app_private.allowlist where email = 'alice@mail.test'), 1, 'alice row is back on the invite list');

-- Eve (steps 1-10, done with addr) ---------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000db04', 'eve@mail.test', now(), '{"full_name":"Evelyn Tester"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('e4000000-0000-0000-0000-00000000db04', '00000000-0000-0000-0000-00000000db04', now(), now());
insert into app_private.allowlist(email) values ('eve@mail.test');
select test_as('00000000-0000-0000-0000-00000000db04', 'e4000000-0000-0000-0000-00000000db04'); select public.activate_session(); reset role;
select test_as('00000000-0000-0000-0000-00000000db04', 'e4000000-0000-0000-0000-00000000db04'); select public.request_account_deletion(); reset role;
insert into _q select user_id, request_id from app_private.account_deletions where user_id = '00000000-0000-0000-0000-00000000db04';
update app_private.account_deletions set due_at = now() - interval '1 minute' where user_id = '00000000-0000-0000-0000-00000000db04';
set local role service_role; insert into _c select * from public.account_deletion_claim(10); reset role;
set local role service_role; select public.account_deletion_prepare('00000000-0000-0000-0000-00000000db04'); reset role;
delete from auth.users where id = '00000000-0000-0000-0000-00000000db04';
set local role service_role; select public.account_deletion_done((select rid from _q where uid = '00000000-0000-0000-0000-00000000db04'), ' EVE@Mail.Test '); reset role;

select is((select count(*)::int from app_private.allowlist where email = 'eve@mail.test'), 0, 'addr in any case and spaces still removes the row');
select is((select count(*)::int from app_private.allowlist where email = 'bob@mail.test'), 1, 'bob row still there after eve is removed');

-- returning person signs up again ----------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000db03', 'alice@mail.test', now(), '{"full_name":"Alice Back"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a3000000-0000-0000-0000-00000000db03', '00000000-0000-0000-0000-00000000db03', now(), now());
select test_as('00000000-0000-0000-0000-00000000db03', 'a3000000-0000-0000-0000-00000000db03');
reset role;
select is(app_private.is_allowed_user(), true, 'returning person is allowed again');

select * from finish();
rollback;
