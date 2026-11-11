begin;
select plan(26);
-- fixtures: humans ann, bob, dan; bots bot (one) and bot2
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000000' || n)::uuid $$;
create function s(n text) returns uuid language sql immutable as $$
  select ('5e550000-0000-0000-0000-0000000000' || n)::uuid $$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@mail.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','dan'),('11','botone'),('12','bottwo')) v(n, name);
insert into app_private.allowlist(email)
select name || '@mail.test' from unnest(array['ann','bob','dan','botone','bottwo']) name;
insert into app_private.tag_finds(finder, found_id) values (u('01'), u('02'));
insert into auth.sessions (id, user_id, created_at, updated_at)
select s(n), u(n), now() - interval '1 hour', now() from unnest(array['01','02','03','11','12']) n;
create function as_(n text, sess text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u(n), 'role', 'authenticated',
    'email', (select email from auth.users where id = u(n)), 'session_id', s(coalesce(sess, n)))::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on function as_(text, text), u(text), s(text) to authenticated, anon;
create function access() returns boolean language sql security definer set search_path = '' as $$
  select app_private.has_app_access() $$;
grant execute on function access() to authenticated;
do $$ declare n text; begin
  foreach n in array array['01','02','03','11','12'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop; end $$;
create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated;
select as_('01');
insert into ids values ('DEBUG', public.start_group_conversation('Debug', array[u('02')]));
reset role;
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
select u(n), (select id from ids where name = 'DEBUG'), true from unnest(array['11','12']) n;

-- 1 anon may not execute
select ok(not has_function_privilege('anon', 'public.bot_member_devices()', 'execute'), 'anon has no execute');
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select throws_ok($$select * from public.bot_member_devices()$$, '42501', null, 'anon call is refused');
reset role;

-- positive control: the enabled bot with its live session
select as_('11');
select ok(access(), 'control: the bot has app access');
select lives_ok($$select * from public.bot_member_devices()$$, 'control: the enabled bot may call');
reset role;

-- 2 a human with app access who is not a bot
select as_('01'); select ok(access(), 'ann has app access'); select throws_ok($$select * from public.bot_member_devices()$$, '42501', null, 'a non-bot is refused'); reset role;

-- 3 the bot switched off
update app_private.bot_accounts set enabled = false where user_id = u('11');
select as_('11'); select throws_ok($$select * from public.bot_member_devices()$$, '42501', null, 'a disabled bot is refused'); reset role;
update app_private.bot_accounts set enabled = true where user_id = u('11');

-- 4 a stale session: a newer bot session is activated
insert into auth.sessions (id, user_id, created_at, updated_at) values (s('21'), u('11'), now(), now());
select as_('11', '21'); select public.activate_session(); reset role;
select as_('11'); select throws_ok($$select * from public.bot_member_devices()$$, '42501', null, 'the stale session is refused'); reset role;
select as_('11', '21'); select lives_ok($$select * from public.bot_member_devices()$$, 'the new session may call'); reset role;

-- 5 the bot's allowlist row is gone
delete from app_private.allowlist where email = 'botone@mail.test';
select as_('11', '21'); select throws_ok($$select * from public.bot_member_devices()$$, '42501', null, 'a bot off the allowlist is refused'); reset role;
insert into app_private.allowlist(email) values ('botone@mail.test');

-- rows: bob and dan are the bot's contacts; cat is nobody's; eve is bot2's
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@mail.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('04','cat'),('05','eve')) v(n, name);
insert into app_private.bot_contacts(bot_id, contact_id) values (u('11'), u('02')), (u('11'), u('03')), (u('12'), u('05'));
insert into app_private.member_device(user_id, model, os_version, app_version, build, installer, updated_at) values
  (u('02'), 'Pixel 8<b>"q";{}', '14', '1.2.3+45 (beta)', 45, 'com.android.vending', now() - interval '2 hours'),
  (u('03'), 'Moto', '13', '2.0.0', 9, null, now() - interval '1 hour'),
  (u('04'), 'Cat Phone', '12', '1.0', 1, null, now()),
  (u('05'), 'Eve Phone', '12', '1.0', 1, null, now());
-- 6 only the bot's own contacts, newest first
select as_('11', '21');
select results_eq($$select display_name from public.bot_member_devices()$$, $$values ('Dan'::text), ('Bob'::text)$$, 'the bot sees its two contacts, newest first');
select is((select count(*) from public.bot_member_devices()), 2::bigint, 'exactly two rows');
select ok(not exists (select 1 from public.bot_member_devices() where display_name in ('Cat', 'Eve')), 'no one else''s phone');
reset role;
-- 7 the exact eight columns, no user_id or email
select is(pg_get_function_result('public.bot_member_devices()'::regprocedure), 'TABLE(tag text, display_name text, model text, os_version text, app_version text, build integer, installer text, last_seen timestamp with time zone)', 'exactly the eight columns');
-- 8 security definer with an empty search_path
select ok((select prosecdef from pg_proc where proname = 'bot_member_devices'), 'security definer');
select is((select proconfig from pg_proc where proname = 'bot_member_devices'), array['search_path=""']::text[], 'search_path is empty');
-- 9 member_device stays closed to clients
select is((select count(*) from pg_policies where schemaname = 'app_private' and tablename = 'member_device'), 0::bigint, 'member_device has no policies');
select ok(not has_table_privilege('anon', 'app_private.member_device', 'select,insert,update,delete'), 'anon has no table privilege');
select ok(not has_table_privilege('authenticated', 'app_private.member_device', 'select,insert,update,delete'), 'authenticated has no table privilege');
-- 10 device text is stripped to [[:alnum:] ._()+/-] at read time
select as_('11', '21');
select is((select model from public.bot_member_devices() where display_name = 'Bob'), 'Pixel 8bq', 'model loses <>";{}');
select is((select app_version from public.bot_member_devices() where display_name = 'Bob'), '1.2.3+45 (beta)', 'allowed characters stay');
select is((select installer from public.bot_member_devices() where display_name = 'Bob'), 'com.android.vending', 'installer kept');
select is((select installer from public.bot_member_devices() where display_name = 'Dan'), null::text, 'a null installer stays null');
select is((select build from public.bot_member_devices() where display_name = 'Bob'), 45, 'build kept');
reset role;
select is((select model from app_private.member_device where user_id = u('02')), 'Pixel 8<b>"q";{}', 'the stored row is unchanged');
-- 11 at most 500 rows
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select gen_random_uuid(), 'many' || i || '@mail.test', now(), '{"full_name":"Many"}'::jsonb from generate_series(1, 501) i;
insert into app_private.member_device(user_id, model, os_version, app_version, build)
select id, 'Model', '1', '1', 1 from auth.users where email like 'many%@mail.test';
insert into app_private.bot_contacts(bot_id, contact_id)
select u('11'), id from auth.users where email like 'many%@mail.test';
select as_('11', '21');
select is((select count(*) from public.bot_member_devices()), 500::bigint, 'at most 500 rows');
reset role;
select * from finish();
rollback;
