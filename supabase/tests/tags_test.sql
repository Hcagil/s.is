begin;
select plan(87);

-- Member tags and first-run onboarding (v0.4).
--
-- 1. Sign-up generates a tag from the display name: folded, lower-case,
--    3..20, starting with a letter; a taken base gets a piece of the user id,
--    and a collision on THAT (a race) falls back to the id alone. Whatever
--    happens, the sign-up itself never aborts -- that invariant is v0.1's.
-- 2. The backfill that tagged existing members ran oldest first: the older
--    account keeps the plain base. It is tested by executing the migration's
--    own backfill statement, as recorded when it was applied, against
--    fixtures whose insertion order and ids disagree with their age.
-- 3. is_tag_available answers for tags RLS hides from the caller: a tag held
--    by an account the allowlist denies is still not available. The negative
--    fixture is a member who CANNOT see that row -- a visible row would prove
--    nothing about the security-definer half.
-- 4. A member writes display_name, tag and onboarding_done on its own row and
--    nothing else. The other row in the negative case is VISIBLE to the
--    member, so zero rows updated is the update policy, not the read policy.
-- 5. The tag helpers in app_private are unreachable from clients.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Rows touched by an UPDATE, as the caller: a row RLS hides from the update is
-- not an error, it is simply not updated.
create or replace function test_update_count(stmt text)
returns bigint language plpgsql security invoker as $$
declare n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function test_update_count(text) to authenticated;

create or replace function tag_of(uid uuid) returns text language sql as $$
  select tag from public.profiles where user_id = uid
$$;

-- 1 generation ---------------------------------------------------------------
-- Every insert is its own lives_ok: a trigger that raises aborts the sign-up.
select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000001-0000-4000-8000-000000000001', 'tag-cagil@tags.test', now(), '{"full_name":"Çağıl Öztürk"}')$$,
  'sign-up with a Turkish name');
select is(tag_of('a1000001-0000-4000-8000-000000000001'), 'cagil_ozturk',
  'ç ğ ı ö ü fold to ASCII, the space becomes _');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000002-0000-4000-8000-000000000002', 'tag-ismail@tags.test', now(), '{"full_name":"İsmail Şükrü Işık"}')$$,
  'sign-up with a dotted capital İ');
select is(tag_of('a1000002-0000-4000-8000-000000000002'), 'ismail_sukru_isik',
  'İ, ş, ü and ı fold to i, s, u and i');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000003-0000-4000-8000-000000000003', 'tag-cagri@tags.test', now(), '{"full_name":"ÇAĞRI ÖZ"}')$$,
  'sign-up with an upper-case Turkish name');
select is(tag_of('a1000003-0000-4000-8000-000000000003'), 'cagri_oz',
  'upper-case Ç Ğ I Ö fold and lower-case');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000004-0000-4000-8000-000000000004', 'tag-jose@tags.test', now(), '{"full_name":"José Müller"}')$$,
  'sign-up with Latin diacritics');
select is(tag_of('a1000004-0000-4000-8000-000000000004'), 'jose_muller',
  'é and ü fold to e and u');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000005-0000-4000-8000-000000000005', 'tag-anna@tags.test', now(), '{"full_name":"  --Anna!!  "}')$$,
  'sign-up with punctuation around the name');
select is(tag_of('a1000005-0000-4000-8000-000000000005'), 'anna',
  'runs of other characters collapse, and leading/trailing _ are trimmed');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000006-0000-4000-8000-000000000006', 'tag-42@tags.test', now(), '{"full_name":"42 Club"}')$$,
  'sign-up with a name starting with a digit');
select is(tag_of('a1000006-0000-4000-8000-000000000006'), 'u42_club',
  'a tag must start with a letter: u is prefixed');

-- The two rules meet: a long name that starts with a digit. Prefixing u must
-- not push the tag past 20, or the check constraint aborts the sign-up.
select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a100000d-0000-4000-8000-00000000000d', 'tag-2024@tags.test', now(), '{"full_name":"2024 Graduates of Istanbul"}')$$,
  'sign-up with a long name starting with a digit');
select ok(tag_of('a100000d-0000-4000-8000-00000000000d') ~ '^u2024_[a-z0-9_]{2,14}$',
  'u is prefixed and the tag still fits in 20 characters');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000007-0000-4000-8000-000000000007', 'tag-long@tags.test', now(), '{"full_name":"Abcdefghijklmnopqrstuvwxyz"}')$$,
  'sign-up with a long name');
select is(tag_of('a1000007-0000-4000-8000-000000000007'), 'abcdefghijklmnopqrst',
  'a tag is cut at 20 characters');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('a1000008-0000-4000-8000-000000000008', 'tag-al@tags.test', now(), '{"full_name":"Al"}')$$,
  'sign-up with a two-letter name');
select is(tag_of('a1000008-0000-4000-8000-000000000008'), 'member',
  'under three characters the base is member');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('b2000009-0000-4000-8000-000000000009', 'tag-emoji@tags.test', now(), '{"full_name":"😀😀"}')$$,
  'sign-up with a name that has no letters at all');
select is(tag_of('b2000009-0000-4000-8000-000000000009'), 'member_b20000',
  'nothing usable -> member, which is taken -> member_ plus 6 hex of the id');

-- collisions: same name twice. The second gets left(base, 13) || _ || 6 hex.
select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('c3abcdef-0000-4000-8000-00000000000a', 'tag-cagil2@tags.test', now(), '{"full_name":"Çağıl Öztürk"}')$$,
  'a second member with the same name still signs up');
select is(tag_of('c3abcdef-0000-4000-8000-00000000000a'), 'cagil_ozturk_c3abcd',
  'the base is taken: base || _ || first 6 hex of the user id');
select is(tag_of('a1000001-0000-4000-8000-000000000001'), 'cagil_ozturk',
  'the first member keeps the plain base');

select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('d4a5b6c7-0000-4000-8000-00000000000b', 'tag-long2@tags.test', now(), '{"full_name":"Abcdefghijklmnopqrstuvwxyz"}')$$,
  'a second long name still signs up');
select is(tag_of('d4a5b6c7-0000-4000-8000-00000000000b'), 'abcdefghijklm_d4a5b6',
  'a long base is cut to 13 before the suffix, so the tag stays at 20');

-- The race: the base AND the suffixed form are both held already.
select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('e5000001-0000-4000-8000-00000000000c', 'tag-race1@tags.test', now(), '{"full_name":"Race Case"}'),
  ('e5000002-0000-4000-8000-00000000000d', 'tag-race2@tags.test', now(), '{"full_name":"race_case_c0ffee"}')$$,
  'two members occupy race_case and race_case_c0ffee');
select is(tag_of('e5000002-0000-4000-8000-00000000000d'), 'race_case_c0ffee',
  'fixture: the suffixed form really is held');
select lives_ok($$insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('c0ffee12-3456-4789-8abc-def012345678', 'tag-race3@tags.test', now(), '{"full_name":"Race Case"}')$$,
  'a sign-up whose base and suffixed tag are both taken still succeeds');
select is(tag_of('c0ffee12-3456-4789-8abc-def012345678'), 'uc0ffee12345647898ab',
  'the race falls back to u || the user id''s hex');

-- Never abort: no name at all, and the same nameless sign-up twice.
select lives_ok($$insert into auth.users (id, email, raw_user_meta_data) values
  ('f6000001-0000-4000-8000-00000000000e', null, '{}'),
  ('f6000002-0000-4000-8000-00000000000f', null, '{}')$$,
  'two sign-ups without any name both succeed');
select is((select count(*) from public.profiles
            where user_id in ('f6000001-0000-4000-8000-00000000000e', 'f6000002-0000-4000-8000-00000000000f')
              and tag ~ '^[a-z][a-z0-9_]{2,19}$'),
          2::bigint, 'both nameless members got a well-formed tag');

select is((select count(*) from public.profiles where tag !~ '^[a-z][a-z0-9_]{2,19}$'),
          0::bigint, 'every generated tag has the enforced shape');
select is((select bool_or(onboarding_done) from public.profiles
            where user_id::text like 'a1%' or user_id::text like 'c3%'),
          false, 'a new member has not onboarded yet');

-- 2 the schema ---------------------------------------------------------------
select col_not_null('public', 'profiles', 'tag', 'tag is NOT NULL');
select col_not_null('public', 'profiles', 'onboarding_done', 'onboarding_done is NOT NULL');
select col_default_is('public', 'profiles', 'onboarding_done', 'false', 'onboarding_done defaults to false');
select throws_ok($$update public.profiles set tag = 'Bad-Tag' where user_id = 'a1000001-0000-4000-8000-000000000001'$$,
  '23514', null, 'the check constraint refuses a malformed tag, even for the owner role');
select throws_ok($$update public.profiles set tag = 'anna' where user_id = 'a1000001-0000-4000-8000-000000000001'$$,
  '23505', null, 'the unique index refuses a held tag');

-- 3 the backfill, oldest first -----------------------------------------------
-- The backfill statement is run exactly as the migration recorded it. Its
-- fixtures: two members with the same name, the NEWER inserted first and
-- given the smaller id, so neither insertion order nor id order can pass for
-- age. Every tag is cleared first: before the migration nobody had one.
select is((select count(*) from supabase_migrations.schema_migrations, unnest(statements) s
            where version = '20260923130000' and s ilike '%oldest first%' and s ilike '%update%'),
          1::bigint, 'fixture: exactly one recorded backfill statement');

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data, created_at) values
  ('0bf00002-0000-4000-8000-000000000002', 'bf-newer@tags.test', now(), '{"full_name":"Twin Backfill"}', now()),
  ('ffbf0001-0000-4000-8000-000000000001', 'bf-older@tags.test', now(), '{"full_name":"Twin Backfill"}', now() - interval '1 year');
update public.profiles set created_at = now() - interval '1 year'
 where user_id = 'ffbf0001-0000-4000-8000-000000000001';
select is(tag_of('0bf00002-0000-4000-8000-000000000002'), 'twin_backfill',
  'fixture: at sign-up the newer account took the base (it came first)');

alter table public.profiles alter column tag drop not null;
update public.profiles set tag = null;
do $$
begin
  execute (select s from supabase_migrations.schema_migrations, unnest(statements) s
            where version = '20260923130000' and s ilike '%oldest first%' and s ilike '%update%');
end $$;

select is(tag_of('ffbf0001-0000-4000-8000-000000000001'), 'twin_backfill',
  'the backfill gives the plain base to the older account');
select is(tag_of('0bf00002-0000-4000-8000-000000000002'), 'twin_backfill_0bf000',
  'the newer account gets the suffixed tag');
select is((select count(*) from public.profiles where tag is null), 0::bigint,
  'the backfill leaves no member without a tag');
select is((select count(*) from public.profiles where tag !~ '^[a-z][a-z0-9_]{2,19}$'),
  0::bigint, 'every backfilled tag has the enforced shape');
alter table public.profiles alter column tag set not null;

-- 4 is_tag_available -----------------------------------------------------------
-- m1 active member (the caller), m2 allowlisted, m4 allowlisted but never
-- activated, robo signed in and NOT allowlisted: RLS hides robo's profile.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('7a000001-0000-4000-8000-000000000001', 'avail-m1@tags.test', now(), '{"full_name":"Avail One"}'),
  ('7a000002-0000-4000-8000-000000000002', 'avail-m2@tags.test', now(), '{"full_name":"Avail Two"}'),
  ('7a000004-0000-4000-8000-000000000004', 'avail-m4@tags.test', now(), '{"full_name":"Avail Four"}'),
  ('7a0000fe-0000-4000-8000-0000000000fe', 'avail-robo@tags.test', now(), '{"full_name":"Hidden Robo"}');
insert into app_private.allowlist(email) values
  ('avail-m1@tags.test'), ('avail-m2@tags.test'), ('avail-m4@tags.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('7b000000-0000-4000-8000-000000000001', '7a000001-0000-4000-8000-000000000001', now(), now()),
  ('7b000000-0000-4000-8000-000000000004', '7a000004-0000-4000-8000-000000000004', now(), now()),
  ('7b000000-0000-4000-8000-0000000000fe', '7a0000fe-0000-4000-8000-0000000000fe', now(), now());
select is(tag_of('7a0000fe-0000-4000-8000-0000000000fe'), 'hidden_robo',
  'fixture: the non-allowlisted account holds hidden_robo');

select test_as('7a000001-0000-4000-8000-000000000001', '7b000000-0000-4000-8000-000000000001');
select is(public.activate_session(), true, 'm1 is active');
select is((select count(*) from public.profiles where tag = 'hidden_robo'), 0::bigint,
  'fixture: m1 cannot see the row holding hidden_robo');
select is((select count(*) from public.profiles where tag = 'avail_two'), 1::bigint,
  'fixture: m1 can see the row holding avail_two');

select is(public.is_tag_available('hidden_robo'), false,
  'a tag held by an account RLS hides is still not available');
select is(public.is_tag_available('avail_two'), false,
  'a tag another member holds is not available');
select is(public.is_tag_available('avail_one'), true,
  'the caller''s own current tag counts as available');
select is(public.is_tag_available('nobody_has_this'), true,
  'a free, well-formed tag is available');
select is(public.is_tag_available('ab'), false, 'too short is not available');
select is(public.is_tag_available(repeat('a', 21)), false, 'too long is not available');
select is(public.is_tag_available('1abc'), false, 'a leading digit is not available');
select is(public.is_tag_available('Nobody_Upper'), false, 'upper case is not available');
select is(public.is_tag_available('no-dash'), false, 'a dash is not available');
select is(public.is_tag_available(''), false, 'empty is not available');
reset role;

select test_as('7a0000fe-0000-4000-8000-0000000000fe', '7b000000-0000-4000-8000-0000000000fe');
select throws_ok($$select public.is_tag_available('nobody_has_this')$$, '42501', null,
  'a non-allowlisted account cannot probe tags');
reset role;
select test_as('7a000004-0000-4000-8000-000000000004', '7b000000-0000-4000-8000-000000000004');
select throws_ok($$select public.is_tag_available('nobody_has_this')$$, '42501', null,
  'an allowlisted account without an active device cannot probe tags');
reset role;
select function_privs_are('public', 'is_tag_available', array['text'], 'anon', '{}'::text[],
  'anon holds no execute on is_tag_available');
select function_privs_are('public', 'is_tag_available', array['text'], 'authenticated', array['EXECUTE'],
  'authenticated may call is_tag_available');

-- 5 grants and writes ----------------------------------------------------------
select column_privs_are('public', 'profiles', 'user_id', 'authenticated', array['SELECT'],
  'user_id is read-only');
select column_privs_are('public', 'profiles', 'created_at', 'authenticated', array['SELECT'],
  'created_at is read-only');
select column_privs_are('public', 'profiles', 'display_name', 'authenticated', array['SELECT', 'UPDATE'],
  'display_name is writable');
select column_privs_are('public', 'profiles', 'tag', 'authenticated', array['SELECT', 'UPDATE'],
  'tag is writable');
select column_privs_are('public', 'profiles', 'onboarding_done', 'authenticated', array['SELECT', 'UPDATE'],
  'onboarding_done is writable');
select column_privs_are('public', 'profiles', 'tag', 'anon', '{}'::text[], 'anon cannot touch tag');
select column_privs_are('public', 'profiles', 'onboarding_done', 'anon', '{}'::text[],
  'anon cannot touch onboarding_done');

select test_as('7a000001-0000-4000-8000-000000000001', '7b000000-0000-4000-8000-000000000001');
select is(test_update_count($$update public.profiles set tag = 'avail_new', onboarding_done = true, display_name = 'New One'
                               where user_id = auth.uid()$$),
  1::bigint, 'a member updates its own name, tag and flag in one statement');
select is((select (display_name, tag, onboarding_done)::text from public.profiles
            where user_id = '7a000001-0000-4000-8000-000000000001'),
  '("New One",avail_new,t)', 'all three are stored');
select is(test_update_count($$update public.profiles set tag = 'stolen_tag'
                               where user_id = '7a000002-0000-4000-8000-000000000002'$$),
  0::bigint, 'a member cannot change another member''s tag');
select is(test_update_count($$update public.profiles set onboarding_done = true
                               where user_id = '7a000002-0000-4000-8000-000000000002'$$),
  0::bigint, 'a member cannot mark another member onboarded');
select is(test_update_count($$update public.profiles set onboarding_done = false$$),
  1::bigint, 'an unqualified update reaches only the caller''s row');
select throws_ok($$update public.profiles set tag = 'avail_two' where user_id = auth.uid()$$,
  '23505', null, 'taking a held tag fails with 23505');
select throws_ok($$update public.profiles set tag = 'hidden_robo' where user_id = auth.uid()$$,
  '23505', null, 'a tag held by a hidden account fails with 23505 too');
select throws_ok($$update public.profiles set tag = 'Bad' where user_id = auth.uid()$$,
  '23514', null, 'a malformed tag fails the check constraint');
select throws_ok($$update public.profiles set created_at = now() where user_id = auth.uid()$$,
  '42501', null, 'no other column became writable');
reset role;
select is(tag_of('7a000002-0000-4000-8000-000000000002'), 'avail_two', 'm2 keeps its tag');
select is((select onboarding_done from public.profiles where user_id = '7a000002-0000-4000-8000-000000000002'),
  false, 'm2 keeps its flag');

-- 6 the helpers are private ----------------------------------------------------
select function_privs_are('app_private', 'tag_base', array['text'], 'authenticated', '{}'::text[],
  'authenticated holds no execute on tag_base');
select function_privs_are('app_private', 'tag_base', array['text'], 'anon', '{}'::text[],
  'anon holds no execute on tag_base');
select function_privs_are('app_private', 'fresh_tag', array['text', 'uuid'], 'authenticated', '{}'::text[],
  'authenticated holds no execute on fresh_tag');
select function_privs_are('app_private', 'fresh_tag', array['text', 'uuid'], 'anon', '{}'::text[],
  'anon holds no execute on fresh_tag');
select function_privs_are('public', 'handle_new_user', array[]::text[], 'authenticated', '{}'::text[],
  'authenticated cannot call the sign-up trigger function');
select test_as('7a000001-0000-4000-8000-000000000001', '7b000000-0000-4000-8000-000000000001');
select throws_ok($$select app_private.tag_base('x')$$, '42501', null, 'a member cannot call tag_base');
select throws_ok($$select app_private.fresh_tag('x', auth.uid())$$, '42501', null,
  'a member cannot call fresh_tag');
reset role;

select * from finish();
rollback;
