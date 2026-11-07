begin;
select plan(11);

-- has_ciphertext(messages): the computed field the pinned bar selects instead
-- of the ciphertext (up to 64 KB). SECURITY INVOKER, so messages RLS still
-- decides who sees the row. uma and vic share chat D (one locked and one plain
-- message); wes is in no chat with them.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000dd01', 'uma@sis.test', now(), '{"full_name":"Uma"}'),
  ('00000000-0000-0000-0000-00000000dd02', 'vic@sis.test', now(), '{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-00000000dd03', 'wes@sis.test', now(), '{"full_name":"Wes"}');
insert into app_private.allowlist(email) values
  ('uma@sis.test'), ('vic@sis.test'), ('wes@sis.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-00000000dd01', '00000000-0000-0000-0000-00000000dd02'),
  ('00000000-0000-0000-0000-00000000dd01', '00000000-0000-0000-0000-00000000dd03');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('d1000000-0000-0000-0000-00000000dd01', '00000000-0000-0000-0000-00000000dd01', now(), now()),
  ('d1000000-0000-0000-0000-00000000dd02', '00000000-0000-0000-0000-00000000dd02', now(), now()),
  ('d1000000-0000-0000-0000-00000000dd03', '00000000-0000-0000-0000-00000000dd03', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-00000000dd01', 'd1000000-0000-0000-0000-00000000dd01');
select is(public.activate_session(), true, 'uma is active');
reset role;

select test_as('00000000-0000-0000-0000-00000000dd02', 'd1000000-0000-0000-0000-00000000dd02');
select is(public.activate_session(), true, 'vic is active');
reset role;
select test_as('00000000-0000-0000-0000-00000000dd03', 'd1000000-0000-0000-0000-00000000dd03');
select is(public.activate_session(), true, 'wes is active');
reset role;

create temp table _c (k text primary key, id uuid);
grant select, insert on _c to authenticated;
select test_as('00000000-0000-0000-0000-00000000dd01', 'd1000000-0000-0000-0000-00000000dd01');
insert into _c select 'D', public.start_direct_conversation('00000000-0000-0000-0000-00000000dd02');
reset role;

-- Written as the owner; the insert guard (needs live device keys) is off
-- inside this rolled-back transaction.
alter table public.messages disable trigger messages_ciphertext_guard;
insert into public.messages(id, conversation_id, sender_id, body, created_at, ciphertext, olm_type) values
  ('a0000000-0000-4000-8000-0000000000a1', (select id from _c where k = 'D'), '00000000-0000-0000-0000-00000000dd02', '🔒 Encrypted message', now() - interval '2 hours', 'Y3RsZWFr', 1),
  ('a0000000-0000-4000-8000-0000000000a2', (select id from _c where k = 'D'), '00000000-0000-0000-0000-00000000dd02', 'plain text', now() - interval '1 hour', null, null);

select has_function('public', 'has_ciphertext', array['messages'], 'has_ciphertext(messages) exists');
select is((select prosecdef from pg_proc where oid = to_regprocedure('public.has_ciphertext(public.messages)')),
          false, 'it is SECURITY INVOKER');
select is((select provolatile from pg_proc where oid = to_regprocedure('public.has_ciphertext(public.messages)')),
          's', 'it is STABLE');
select ok((select coalesce(proconfig, '{}') @> array['search_path=""'] from pg_proc where oid = to_regprocedure('public.has_ciphertext(public.messages)')),
          'its search_path is empty');
select is((select has_function_privilege('anon', 'public.has_ciphertext(public.messages)', 'execute')),
          false, 'anon cannot execute it');
select is((select has_function_privilege('authenticated', 'public.has_ciphertext(public.messages)', 'execute')),
          true, 'authenticated can execute it');

select test_as('00000000-0000-0000-0000-00000000dd01', 'd1000000-0000-0000-0000-00000000dd01');
select is((select array_agg(id::text order by id::text) from public.messages m where public.has_ciphertext(m)),
          array['a0000000-0000-4000-8000-0000000000a1'], 'member: true only for the locked row (false for the plain one)');
reset role;

-- wes is not a member: RLS hides the row, the function adds no way round it.
select test_as('00000000-0000-0000-0000-00000000dd03', 'd1000000-0000-0000-0000-00000000dd03');
select is((select count(*)::int from public.messages m where m.id = 'a0000000-0000-4000-8000-0000000000a1' or public.has_ciphertext(m)),
          0, 'non-member sees no row through it');
reset role;

select * from finish();
rollback;
