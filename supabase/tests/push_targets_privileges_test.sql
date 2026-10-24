begin;
select plan(13);

-- Private Chats 4b Group J (L-c): app_private.push_targets_for_message returns
-- every recipient's device token and the push wording of a message. Only the
-- service role may reach it, and only through public.push_targets (what the
-- notify-on-message function calls). anon, authenticated and PUBLIC hold no
-- EXECUTE on either, and a call from those roles is refused with 42501 --
-- checked as a real call, not only through the catalog, so a grant that slips
-- in via PUBLIC or a default privilege still shows up here.

select ok(not has_function_privilege('anon', 'app_private.push_targets_for_message(uuid)', 'EXECUTE'),
          'anon cannot execute push_targets_for_message');
select ok(not has_function_privilege('authenticated', 'app_private.push_targets_for_message(uuid)', 'EXECUTE'),
          'authenticated cannot execute push_targets_for_message');
select ok(not has_function_privilege('public', 'app_private.push_targets_for_message(uuid)', 'EXECUTE'),
          'PUBLIC holds no execute on push_targets_for_message');
select ok(has_function_privilege('service_role', 'public.push_targets(uuid)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.push_targets(uuid)', 'EXECUTE')
          and not has_function_privilege('public', 'public.push_targets(uuid)', 'EXECUTE'),
          'public.push_targets: service_role only');

-- A real call per role. An unknown id: a caller that gets in sees zero rows.
set local role anon;
select throws_ok($$ select * from app_private.push_targets_for_message('00000000-0000-0000-0000-0000000fa001') $$,
                 '42501', null, 'anon: a call is refused (42501)');
reset role;

set local role authenticated;
select set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-0000-0000-0000000fa002","role":"authenticated"}', true);
select throws_ok($$ select * from app_private.push_targets_for_message('00000000-0000-0000-0000-0000000fa001') $$,
                 '42501', null, 'authenticated: a call is refused (42501)');
reset role;

set local role service_role;
select lives_ok($$ select * from public.push_targets('00000000-0000-0000-0000-0000000fa001') $$,
                'service_role: public.push_targets runs');
select is((select count(*) from public.push_targets('00000000-0000-0000-0000-0000000fa001'))::int,
          0, 'service_role: an unknown message has no targets');
reset role;

-- The public wrapper keeps the same gate.
set local role authenticated;
select throws_ok($$ select * from public.push_targets('00000000-0000-0000-0000-0000000fa001') $$,
                 '42501', null, 'authenticated: public.push_targets is refused (42501)');
reset role;

-- Both functions run as their owner with an empty search_path (every name
-- qualified), and the key directory they read stays closed to clients.
select ok((select prosecdef from pg_proc where oid = 'public.push_targets(uuid)'::regprocedure)
          and (select prosecdef from pg_proc where oid = 'app_private.push_targets_for_message(uuid)'::regprocedure),
          'push_targets and push_targets_for_message are security definer');
select ok((select proconfig from pg_proc where oid = 'public.push_targets(uuid)'::regprocedure) @> array['search_path=""']
          and (select proconfig from pg_proc where oid = 'app_private.push_targets_for_message(uuid)'::regprocedure) @> array['search_path=""'],
          'both pin search_path to empty');
select ok(not exists (select 1 from information_schema.role_table_grants
                       where table_schema = 'app_private' and table_name = 'olm_devices'
                         and grantee in ('anon', 'authenticated', 'PUBLIC')),
          'olm_devices: no grant to anon, authenticated or PUBLIC');
select is((select count(*) from pg_policies where schemaname = 'app_private' and tablename = 'olm_devices'),
          0::bigint, 'olm_devices: no policy');

select * from finish();
rollback;
