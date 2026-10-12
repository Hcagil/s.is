-- The sign-up gate and Sign in with Apple (20261022120000): an Apple private
-- relay address (@privaterelay.appleid.com) is refused, allowlisted or not and
-- whatever the provider; a real allowlisted address arriving through Apple is
-- admitted; everything signup_hook_test.sql refuses stays refused, Apple
-- included.
--
-- Every relay address below is allowlisted, so only the relay gate can refuse
-- it. Not covered here: a second identity (Apple) with the same verified email
-- linking to the existing account. That is GoTrue's automatic linking, which
-- needs an Apple-signed ID token; the local stack cannot mint one.
begin;
select plan(13);

insert into app_private.allowlist(email) values
  ('apple-ann@integration.test'),
  ('x7f2k9@privaterelay.appleid.com'),
  ('apple-bot@example.com')
on conflict do nothing;

create function pg_temp.ev(email text, provider text default 'apple') returns jsonb
language sql as $$
  select jsonb_build_object('user',
           jsonb_build_object('email', email, 'app_metadata', jsonb_build_object('provider', provider)),
         'metadata', jsonb_build_object('name', 'before-user-created'))
$$;
create function pg_temp.hook(event jsonb) returns jsonb
language sql as $$ select app_private.before_user_created(event) $$;
create temp table _refused as
  select '{"error":{"http_code":403,"message":"not invited"}}'::jsonb as v;

-- relay refused --------------------------------------------------------------
select is(pg_temp.hook(pg_temp.ev('x7f2k9@privaterelay.appleid.com')), (select v from _refused),
          'an allowlisted relay address through Apple is refused');
select is(pg_temp.hook(pg_temp.ev('x7f2k9@privaterelay.appleid.com', 'google')), (select v from _refused),
          'an allowlisted relay address is refused whatever the provider (google)');
select is(pg_temp.hook(pg_temp.ev('x7f2k9@privaterelay.appleid.com', 'email')), (select v from _refused),
          'an allowlisted relay address is refused whatever the provider (email)');
select is(pg_temp.hook(pg_temp.ev('X7F2K9@PrivateRelay.AppleID.COM')), (select v from _refused),
          'a mixed-case relay domain is refused');
select is(pg_temp.hook(pg_temp.ev('  x7f2k9@PRIVATERELAY.APPLEID.COM  ')), (select v from _refused),
          'a padded upper-case relay address is refused');

-- real address through Apple admitted -----------------------------------------
select is(pg_temp.hook(pg_temp.ev('apple-ann@integration.test')), '{}'::jsonb,
          'an allowlisted real address signing up with Apple is admitted');
select is(pg_temp.hook(pg_temp.ev(' Apple-Ann@Integration.TEST ')), '{}'::jsonb,
          'mixed case and padding of an allowlisted address through Apple are normalised');
select is(pg_temp.hook(pg_temp.ev('apple-ann@integration.test', 'google')), '{}'::jsonb,
          'the same address through Google is still admitted');

-- earlier refusals hold through Apple ----------------------------------------
select is(pg_temp.hook(pg_temp.ev(null)), (select v from _refused),
          'an Apple event with a null email is refused');
select is(pg_temp.hook('{"user":{"app_metadata":{"provider":"apple"}},"metadata":{}}'::jsonb),
          (select v from _refused), 'an Apple event without an email key is refused');
select is(pg_temp.hook(pg_temp.ev('apple-stranger@integration.test')), (select v from _refused),
          'an uninvited real address through Apple is refused');
select is(pg_temp.hook(pg_temp.ev('apple-ann+x@integration.test')), (select v from _refused),
          'plus-addressing of an invited address through Apple is refused');
select is(pg_temp.hook(pg_temp.ev('apple-bot@example.com')), (select v from _refused),
          'an allowlisted example.com address through Apple is refused');

select * from finish();
rollback;
