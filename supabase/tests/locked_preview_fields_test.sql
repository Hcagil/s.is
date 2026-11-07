begin;
select plan(10);

-- Locked-message guard, database half. (1) chat_list()'s `previews` entries
-- carry `olm_type` (as stored) and `has_ciphertext` (boolean) so the app can
-- tell a half-set row from a plain one; the ciphertext itself never leaves.
-- (2) search_messages() never returns a row with olm_type set. The table check
-- messages_ciphertext_check forbids a half-set row, so the check is dropped
-- inside this rolled-back transaction to build one.
--
-- Fixtures: uma talks to vic (D, newest message locked) and to wes (H, newest
-- message plain).
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000dd01', 'uma@lockprev.test', now(), '{"full_name":"Uma"}'),
  ('00000000-0000-0000-0000-00000000dd02', 'vic@lockprev.test', now(), '{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-00000000dd03', 'wes@lockprev.test', now(), '{"full_name":"Wes"}');
insert into app_private.allowlist(email) values
  ('uma@lockprev.test'), ('vic@lockprev.test'), ('wes@lockprev.test');
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

create temp table _c (k text primary key, id uuid);
grant select, insert on _c to authenticated;
select test_as('00000000-0000-0000-0000-00000000dd01', 'd1000000-0000-0000-0000-00000000dd01');
insert into _c select 'D', public.start_direct_conversation('00000000-0000-0000-0000-00000000dd02');
insert into _c select 'H', public.start_direct_conversation('00000000-0000-0000-0000-00000000dd03');
reset role;

-- Written as the owner (created_at is withheld from clients). The insert guard
-- trigger (needs live device keys) is off for this rolled-back transaction.
alter table public.messages disable trigger messages_ciphertext_guard;
insert into public.messages(conversation_id, sender_id, body, created_at, ciphertext, olm_type) values
  ((select id from _c where k = 'D'), '00000000-0000-0000-0000-00000000dd02', '🔒 Encrypted message', now() - interval '1 hour', 'Y3RsZWFr', 1),
  ((select id from _c where k = 'H'), '00000000-0000-0000-0000-00000000dd03', 'plain preview', now() - interval '1 hour', null, null);

select test_as('00000000-0000-0000-0000-00000000dd01', 'd1000000-0000-0000-0000-00000000dd01');
create temp table _p as
  select p, public.chat_list()::text as whole
    from jsonb_array_elements(public.chat_list() -> 'previews') p;
reset role;

select is((select p ->> 'has_ciphertext' from _p where p ->> 'conversation_id' = (select id::text from _c where k = 'D')),
          'true', 'locked preview: has_ciphertext is true');
select is((select p -> 'olm_type' from _p where p ->> 'conversation_id' = (select id::text from _c where k = 'D')),
          '1'::jsonb, 'locked preview: olm_type is as stored');
select is((select p ->> 'has_ciphertext' from _p where p ->> 'conversation_id' = (select id::text from _c where k = 'H')),
          'false', 'plain preview: has_ciphertext is false');
select ok((select p ? 'olm_type' and p -> 'olm_type' = 'null'::jsonb from _p where p ->> 'conversation_id' = (select id::text from _c where k = 'H')),
          'plain preview: olm_type is present and null');
select ok((select bool_and(not (p ? 'ciphertext')) from _p), 'no preview carries a ciphertext key');
select ok((select bool_and(position('Y3RsZWFr' in whole) = 0) from _p), 'the ciphertext value is nowhere in chat_list');

-- search_messages: plain, fully locked and half-set (olm_type only) rows with
-- the same needle.
alter table public.messages drop constraint messages_ciphertext_check;
insert into public.messages(conversation_id, sender_id, body, created_at, ciphertext, olm_type) values
  ((select id from _c where k = 'H'), '00000000-0000-0000-0000-00000000dd03', 'zebraneedle plain', now() - interval '3 hours', null, null),
  ((select id from _c where k = 'H'), '00000000-0000-0000-0000-00000000dd03', 'zebraneedle locked', now() - interval '4 hours', 'Y3Q=', 1),
  ((select id from _c where k = 'H'), '00000000-0000-0000-0000-00000000dd03', 'zebraneedle half', now() - interval '5 hours', null, 1);

select test_as('00000000-0000-0000-0000-00000000dd01', 'd1000000-0000-0000-0000-00000000dd01');
select is((select array_agg(body order by body) from public.search_messages('zebraneedle')),
          array['zebraneedle plain'], 'search returns only the plain row');
select is((select count(*)::int from public.search_messages('zebraneedle half')), 0,
          'search never returns a row with olm_type set and no ciphertext');
select is((select count(*)::int from public.search_messages('zebraneedle locked')), 0,
          'control: a fully locked row is not returned');
reset role;

select * from finish();
rollback;
