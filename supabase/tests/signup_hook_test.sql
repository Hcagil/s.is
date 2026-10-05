-- The sign-up gate: app_private.before_user_created(event jsonb), Supabase
-- Auth's "before user created" hook, and the deleted_attachments hygiene that
-- shipped with it (findings L1, L2).
--
-- Contract: allow returns {}; refusal is exactly
-- {"error":{"http_code":403,"message":"not invited"}}. Admitted: an
-- allowlisted address after lower(btrim()), provider google or email.
-- Refused: not allowlisted, plus-addressing, null/empty email, an empty event,
-- and any reserved example.com/.net/.org address even when allowlisted.
--
-- The hook runs as supabase_auth_admin, which postgres cannot become here
-- (its memberships are superuser-only), so its privileges are checked with
-- has_*_privilege and its behaviour under that role, RLS included, is proven
-- end to end through real Auth in test/integration/signup_gate_test.dart.
begin;
select plan(47);

-- fixtures --------------------------------------------------------------
-- Every refused address below that is NOT about the allowlist is allowlisted,
-- so only the gate under test can refuse it.
insert into app_private.allowlist(email) values
  ('hook-ann@integration.test'),
  ('sis-destek-bot@example.com'),
  ('hook-net@example.net'),
  ('hook-org@example.org')
on conflict do nothing;  -- the seed allowlists the bot for the integration suite

create function pg_temp.ev(email text, provider text default 'google') returns jsonb
language sql as $$
  select jsonb_build_object('user',
           jsonb_build_object('email', email, 'app_metadata', jsonb_build_object('provider', provider)),
         'metadata', jsonb_build_object('name', 'before-user-created'))
$$;
create function pg_temp.hook(event jsonb) returns jsonb
language sql as $$ select app_private.before_user_created(event) $$;

create temp table _refused as
  select '{"error":{"http_code":403,"message":"not invited"}}'::jsonb as v;

-- 1 admitted -------------------------------------------------------------
select is(pg_temp.hook(pg_temp.ev('hook-ann@integration.test', 'google')), '{}'::jsonb,
          'an allowlisted address signing up with Google is admitted');
select is(pg_temp.hook(pg_temp.ev('hook-ann@integration.test', 'email')), '{}'::jsonb,
          'an allowlisted address signing up by email is admitted (google_only is off)');
select is(pg_temp.hook(pg_temp.ev('  Hook-Ann@Integration.TEST  ', 'google')), '{}'::jsonb,
          'padding and mixed case are normalised before the allowlist match');
select is(pg_temp.hook(pg_temp.ev(' HOOK-ANN@integration.test ', 'email')), '{}'::jsonb,
          'upper case with surrounding blanks is still the invited address');

-- 2 refused: not on the allowlist ---------------------------------------
select is(pg_temp.hook(pg_temp.ev('hook-stranger@integration.test')), (select v from _refused),
          'a non-allowlisted address is refused with exactly the 403 body');
select is(pg_temp.hook(pg_temp.ev('hook-stranger@integration.test', 'email')), (select v from _refused),
          'a non-allowlisted address is refused by email too');
select is(pg_temp.hook(pg_temp.ev('hook-ann+x@integration.test')), (select v from _refused),
          'plus-addressing of an invited address is refused');
select is(pg_temp.hook(pg_temp.ev('hook-ann+@integration.test')), (select v from _refused),
          'an empty plus tag on an invited address is refused');
select is(pg_temp.hook(pg_temp.ev('hook-ann@integration.test.evil')), (select v from _refused),
          'a longer domain around the invited address is refused');

-- 3 refused: no usable email ---------------------------------------------
select is(pg_temp.hook(pg_temp.ev(null)), (select v from _refused), 'a null email is refused');
select is(pg_temp.hook(pg_temp.ev('')), (select v from _refused), 'an empty email is refused');
select is(pg_temp.hook(pg_temp.ev('   ')), (select v from _refused), 'a blank email is refused');
select is(pg_temp.hook('{}'::jsonb), (select v from _refused), 'an empty event is refused');
-- The allowlist's own check admits '' as a row. With it present, only the
-- empty-email gate itself can refuse an empty or blank address.
savepoint empty_row;
insert into app_private.allowlist(email) values ('');
select is(pg_temp.hook(pg_temp.ev('')), (select v from _refused),
          'an empty email is refused even if the allowlist holds an empty row');
select is(pg_temp.hook(pg_temp.ev('   ')), (select v from _refused),
          'a blank email is refused even if the allowlist holds an empty row');
rollback to savepoint empty_row;
select is(pg_temp.hook('{"user":{"app_metadata":{"provider":"google"}},"metadata":{}}'::jsonb),
          (select v from _refused), 'a user without an email key is refused');

-- 4 refused: reserved domains, allowlisted or not (H-1) -------------------
select is(pg_temp.hook(pg_temp.ev('sis-destek-bot@example.com')), (select v from _refused),
          'the SIS Bot address is refused even though it is allowlisted');
select is(pg_temp.hook(pg_temp.ev('sis-destek-bot@example.com', 'email')), (select v from _refused),
          'the SIS Bot address is refused by email too');
select is(pg_temp.hook(pg_temp.ev('  SIS-Destek-Bot@Example.COM ')), (select v from _refused),
          'mixed case and padding do not slip the bot address past the reserved-domain refusal');
select is(pg_temp.hook(pg_temp.ev('hook-net@example.net')), (select v from _refused),
          'an allowlisted example.net address is refused');
select is(pg_temp.hook(pg_temp.ev(' Hook-Net@EXAMPLE.NET')), (select v from _refused),
          'an allowlisted example.net address in mixed case is refused');
select is(pg_temp.hook(pg_temp.ev('hook-org@example.org')), (select v from _refused),
          'an allowlisted example.org address is refused');
select is(pg_temp.hook(pg_temp.ev('Hook-Org@Example.Org  ')), (select v from _refused),
          'an allowlisted example.org address in mixed case is refused');

-- 5 privileges -------------------------------------------------------------
select ok(not exists (
            select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
             where p.oid = 'app_private.before_user_created(jsonb)'::regprocedure
               and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
          'PUBLIC holds no execute on the hook');
select ok(not has_function_privilege('anon', 'app_private.before_user_created(jsonb)', 'execute'),
          'anon cannot execute the hook');
select ok(not has_function_privilege('authenticated', 'app_private.before_user_created(jsonb)', 'execute'),
          'authenticated cannot execute the hook');
select ok(has_function_privilege('supabase_auth_admin', 'app_private.before_user_created(jsonb)', 'execute'),
          'supabase_auth_admin may execute the hook');
select ok(has_schema_privilege('supabase_auth_admin', 'app_private', 'usage'),
          'supabase_auth_admin has USAGE on app_private');
select ok(has_table_privilege('supabase_auth_admin', 'app_private.allowlist', 'select'),
          'supabase_auth_admin may read the allowlist');
select ok(not has_table_privilege('supabase_auth_admin', 'app_private.allowlist',
                                  'insert, update, delete, truncate'),
          'supabase_auth_admin cannot write the allowlist');
select ok(not has_table_privilege('supabase_auth_admin', 'app_private.active_sessions', 'select'),
          'supabase_auth_admin cannot read active_sessions');
select is(
  (select array_agg(c.relname || ':' || p order by c.relname, p)
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'app_private'
     cross join unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
    where c.relkind in ('r', 'v', 'm', 'p', 'f')
      and has_table_privilege('supabase_auth_admin', c.oid, p)),
  array['allowlist:SELECT'],
  'in app_private, supabase_auth_admin holds SELECT on the allowlist and nothing else');

-- 6 fail-closed: an error inside the hook surfaces, it is never swallowed --
-- (Auth then refuses the sign-up.) The allowlist vanishing mid-flight must
-- raise, not admit and not quietly refuse.
savepoint fail_closed;
alter table app_private.allowlist rename to allowlist_gone;
select throws_ok($$select pg_temp.hook(pg_temp.ev('hook-ann@integration.test'))$$,
                 '42P01', null,
                 'an error reading the allowlist propagates out of the hook');
rollback to savepoint fail_closed;
select is(pg_temp.hook(pg_temp.ev('hook-ann@integration.test')), '{}'::jsonb,
          'with the allowlist back, the same address is admitted (the error was the only cause)');

-- 7 deleted_attachments L2: a record only covers objects that already existed
-- ann sends a photo and deletes the message; the only thing that changes
-- between the two checks below is the object's created_at.
set local storage.allow_delete_query = 'true';
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000da001', 'da-ann@integration.test', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000da002', 'da-bob@integration.test', now(), '{"full_name":"Bob"}');
insert into app_private.allowlist(email) values ('da-ann@integration.test'), ('da-bob@integration.test')
on conflict do nothing;
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000da001', '00000000-0000-0000-0000-0000000da002');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('da000000-0000-0000-0000-0000000da001', '00000000-0000-0000-0000-0000000da001', now(), now()),
  ('da000000-0000-0000-0000-0000000da002', '00000000-0000-0000-0000-0000000da002', now(), now());

create function pg_temp.as_user(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000da001', 'da000000-0000-0000-0000-0000000da001');
select public.activate_session();
create temp table _dc as
  select public.start_direct_conversation('00000000-0000-0000-0000-0000000da002') as id;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000da002', 'da000000-0000-0000-0000-0000000da002');
select public.activate_session();
reset role;
grant select on _dc to authenticated;

-- L2 photo, owned and sent by ann.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _dc)::text || '/da-l2.jpg', '00000000-0000-0000-0000-0000000da001', '{"size":3}');
insert into public.messages(conversation_id, sender_id, body, attachment_path) values
  ((select id from _dc), '00000000-0000-0000-0000-0000000da001', '', (select id from _dc)::text || '/da-l2.jpg');
create temp table _l2 as
  select id from public.messages where attachment_path = (select id from _dc)::text || '/da-l2.jpg';
grant select on _l2 to authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000da001', 'da000000-0000-0000-0000-0000000da001');
select is(public.delete_message((select id from _l2)), (select id from _dc)::text || '/da-l2.jpg',
          'ann deletes her photo message, recording the path');
reset role;

update storage.objects set created_at = now() - interval '1 hour'
 where bucket_id = 'attachments' and name = (select id from _dc)::text || '/da-l2.jpg';
select pg_temp.as_user('00000000-0000-0000-0000-0000000da001', 'da000000-0000-0000-0000-0000000da001');
reset role;  -- app_private is not the client's schema; the storage policy calls this as ann
select is(app_private.may_remove_attachment((select id from _dc)::text || '/da-l2.jpg'), true,
          'L2: an object created before the deletion was recorded is removable by the deleter');

update storage.objects set created_at = now() + interval '1 hour'
 where bucket_id = 'attachments' and name = (select id from _dc)::text || '/da-l2.jpg';
select pg_temp.as_user('00000000-0000-0000-0000-0000000da001', 'da000000-0000-0000-0000-0000000da001');
reset role;  -- app_private is not the client's schema; the storage policy calls this as ann
select is(app_private.may_remove_attachment((select id from _dc)::text || '/da-l2.jpg'), false,
          'L2: an object created after the deletion was recorded is NOT removable through that record');

-- 8 deleted_attachments L1: a re-used path, deleted by someone else ---------
-- ann sends and deletes a photo; her object is removed; bob later uploads his
-- own object at the same path, sends and deletes it. The record must now be
-- bob's, and fresh.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _dc)::text || '/da-l1.jpg', '00000000-0000-0000-0000-0000000da001', '{"size":3}');
insert into public.messages(conversation_id, sender_id, body, attachment_path) values
  ((select id from _dc), '00000000-0000-0000-0000-0000000da001', 'l1-ann', (select id from _dc)::text || '/da-l1.jpg');
create temp table _l1a as select id from public.messages where body = 'l1-ann';
grant select on _l1a to authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000da001', 'da000000-0000-0000-0000-0000000da001');
select is(public.delete_message((select id from _l1a)), (select id from _dc)::text || '/da-l1.jpg',
          'L1: ann deletes her photo message');
reset role;
-- Age ann's record so a reset is observable inside this one transaction.
update app_private.deleted_attachments set recorded_at = now() - interval '1 day'
 where path = (select id from _dc)::text || '/da-l1.jpg';
select is((select user_id from app_private.deleted_attachments
            where path = (select id from _dc)::text || '/da-l1.jpg'),
          '00000000-0000-0000-0000-0000000da001'::uuid, 'L1: the record is ann''s first');

delete from storage.objects where bucket_id = 'attachments' and name = (select id from _dc)::text || '/da-l1.jpg';
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _dc)::text || '/da-l1.jpg', '00000000-0000-0000-0000-0000000da002', '{"size":3}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000da002', 'da000000-0000-0000-0000-0000000da002');
insert into public.messages(conversation_id, sender_id, body, attachment_path)
  values ((select id from _dc), '00000000-0000-0000-0000-0000000da002', 'l1-bob', (select id from _dc)::text || '/da-l1.jpg');
reset role;
create temp table _l1b as select id from public.messages where body = 'l1-bob';
grant select on _l1b to authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000da002', 'da000000-0000-0000-0000-0000000da002');
select is(public.delete_message((select id from _l1b)), (select id from _dc)::text || '/da-l1.jpg',
          'L1: bob deletes his message on the re-used path');
reset role;
select is((select user_id from app_private.deleted_attachments
            where path = (select id from _dc)::text || '/da-l1.jpg'),
          '00000000-0000-0000-0000-0000000da002'::uuid,
          'L1: the second delete replaces the deleter with bob');
select ok((select recorded_at from app_private.deleted_attachments
            where path = (select id from _dc)::text || '/da-l1.jpg') > now() - interval '1 minute',
          'L1: the second delete resets recorded_at');
select is((select count(*) from app_private.deleted_attachments
            where path = (select id from _dc)::text || '/da-l1.jpg'), 1::bigint,
          'L1: still one record per path');

-- 9 nothing can outlive a refused user ------------------------------------
-- A refusal creates no auth.users row; test/integration/signup_gate_test.dart
-- reads users and profiles through the API and relies on these keys for the
-- rest: no session, identity, profile or active session without a user.
select fk_ok('auth', 'identities', 'user_id', 'auth', 'users', 'id');
select fk_ok('auth', 'sessions', 'user_id', 'auth', 'users', 'id');
select fk_ok('public', 'profiles', 'user_id', 'auth', 'users', 'id');
select fk_ok('app_private', 'active_sessions', 'user_id', 'auth', 'users', 'id');

select * from finish();
rollback;
