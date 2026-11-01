-- messages.updated_at (Update 3): the server-set change time the on-phone
-- store's catch-up feed pages by (updated_at, id). The column must be set by
-- the server on insert, edit and delete-for-everyone whatever a writer sends,
-- no client may write it, the (updated_at, id) index exists, and the feed
-- opens no new rows: messages RLS is unchanged.
--
-- ann and bob share a chat; fay is active and allowlisted but in none of
-- these chats, so the RLS check fails only the membership gate.
begin;
select plan(26);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000cf001', 'cf-ann@sis.test', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000cf002', 'cf-bob@sis.test', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000cf003', 'cf-fay@sis.test', now(), '{"full_name":"Fay"}');
insert into app_private.allowlist(email) values
  ('cf-ann@sis.test'), ('cf-bob@sis.test'), ('cf-fay@sis.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000cf001', '00000000-0000-0000-0000-0000000cf002');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('cf000000-0000-0000-0000-0000000cf001', '00000000-0000-0000-0000-0000000cf001', now(), now()),
  ('cf000000-0000-0000-0000-0000000cf002', '00000000-0000-0000-0000-0000000cf002', now(), now()),
  ('cf000000-0000-0000-0000-0000000cf003', '00000000-0000-0000-0000-0000000cf003', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- schema ------------------------------------------------------------------
select has_column('public', 'messages', 'updated_at', 'messages.updated_at exists');
select col_type_is('public', 'messages', 'updated_at', 'timestamp with time zone',
                   'updated_at is timestamptz');
select col_not_null('public', 'messages', 'updated_at', 'updated_at is not null');
select has_index('public', 'messages', 'messages_updated_at_idx', array['updated_at', 'id'],
                 'index on (updated_at, id) for the keyset feed');
select has_trigger('public', 'messages', 'messages_touch_updated_at',
                   'a trigger keeps updated_at');
select is(has_column_privilege('authenticated', 'public.messages', 'updated_at', 'INSERT'),
          false, 'authenticated cannot insert updated_at');
select is(has_column_privilege('authenticated', 'public.messages', 'updated_at', 'UPDATE'),
          false, 'authenticated cannot update updated_at');
select is(has_column_privilege('anon', 'public.messages', 'updated_at', 'INSERT'),
          false, 'anon cannot insert updated_at');
select is(has_column_privilege('anon', 'public.messages', 'updated_at', 'UPDATE'),
          false, 'anon cannot update updated_at');
select policies_are('public', 'messages',
  array['messages_read', 'messages_send', 'messages_send_admin', 'messages_send_bacanaks'],
  'messages policies unchanged');

-- fixtures ------------------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000cf002', 'cf000000-0000-0000-0000-0000000cf002');
select is(public.activate_session(), true, 'bob is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cf003', 'cf000000-0000-0000-0000-0000000cf003');
select is(public.activate_session(), true, 'fay is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000cf001', 'cf000000-0000-0000-0000-0000000cf001');
select is(public.activate_session(), true, 'ann is active');
create temp table _c as
  select public.start_direct_conversation('00000000-0000-0000-0000-0000000cf002') as ann;
reset role;
grant select on _c to authenticated;

-- insert --------------------------------------------------------------------
-- A writer that names updated_at (postgres here; a client cannot) is ignored.
insert into public.messages(conversation_id, sender_id, body, updated_at) values
  ((select ann from _c), '00000000-0000-0000-0000-0000000cf001', 'cf forged', '2000-01-01');
select cmp_ok((select updated_at from public.messages where body = 'cf forged'), '>=', now(),
              'insert: a written updated_at is replaced by the server time');

select test_as('00000000-0000-0000-0000-0000000cf001', 'cf000000-0000-0000-0000-0000000cf001');
insert into public.messages(conversation_id, sender_id, body) values
  ((select ann from _c), '00000000-0000-0000-0000-0000000cf001', 'cf edit me'),
  ((select ann from _c), '00000000-0000-0000-0000-0000000cf001', 'cf delete me');
select throws_ok(
  $$insert into public.messages(conversation_id, sender_id, body, updated_at)
    values ((select ann from _c), '00000000-0000-0000-0000-0000000cf001', 'cf client', '2000-01-01')$$,
  '42501', null, 'a client insert naming updated_at is refused');
reset role;
select cmp_ok((select updated_at from public.messages where body = 'cf edit me'), '>=', now(),
              'insert by a client: updated_at is set');

create temp table _t as select id, body, updated_at as before
  from public.messages where body in ('cf edit me', 'cf delete me', 'cf forged');
grant select on _t to authenticated;
select pg_sleep(0.01);

-- edit ----------------------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000cf001', 'cf000000-0000-0000-0000-0000000cf001');
select lives_ok(format($$select public.edit_message(%L, 'cf edited')$$,
                       (select id from _t where body = 'cf edit me')),
                'ann edits her message');
select throws_ok(
  format($$update public.messages set updated_at = '2000-01-01' where id = %L$$,
         (select id from _t where body = 'cf edit me')),
  '42501', null, 'a client update of updated_at is refused');
reset role;
select cmp_ok((select m.updated_at from public.messages m join _t using (id) where _t.body = 'cf edit me'),
              '>', (select before from _t where body = 'cf edit me'),
              'edit: updated_at moves forward');

-- A direct update naming updated_at (postgres) is still overwritten.
update public.messages set updated_at = '2000-01-01', body = 'cf forged 2'
 where id = (select id from _t where body = 'cf forged');
select cmp_ok((select m.updated_at from public.messages m join _t using (id) where _t.body = 'cf forged'),
              '>', (select before from _t where body = 'cf forged'),
              'update: a written updated_at is replaced by the server time');

-- delete for everyone -------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000cf001', 'cf000000-0000-0000-0000-0000000cf001');
select lives_ok(format($$select public.delete_message(%L)$$,
                       (select id from _t where body = 'cf delete me')),
                'ann deletes her message for everyone');
reset role;
select cmp_ok((select m.updated_at from public.messages m join _t using (id) where _t.body = 'cf delete me'),
              '>', (select before from _t where body = 'cf delete me'),
              'delete for everyone: updated_at moves forward');

-- tie order -----------------------------------------------------------------
-- Equal updated_at values can only be forged with the trigger off (postgres);
-- the keyset (updated_at, id) still pages them by id.
alter table public.messages disable trigger messages_touch_updated_at;
insert into public.messages(id, conversation_id, sender_id, body, updated_at) values
  ('00000000-0000-0000-0000-00000000c0f3', (select ann from _c), '00000000-0000-0000-0000-0000000cf001', 'cf tie 3', '2001-01-01'),
  ('00000000-0000-0000-0000-00000000c0f1', (select ann from _c), '00000000-0000-0000-0000-0000000cf001', 'cf tie 1', '2001-01-01'),
  ('00000000-0000-0000-0000-00000000c0f2', (select ann from _c), '00000000-0000-0000-0000-0000000cf001', 'cf tie 2', '2001-01-01');
alter table public.messages enable trigger messages_touch_updated_at;

select test_as('00000000-0000-0000-0000-0000000cf002', 'cf000000-0000-0000-0000-0000000cf002');
select results_eq(
  $$select id from public.messages
     where (updated_at, id) > ('2001-01-01'::timestamptz, '00000000-0000-0000-0000-00000000c0f1'::uuid)
       and updated_at = '2001-01-01'
     order by updated_at, id$$,
  $$values ('00000000-0000-0000-0000-00000000c0f2'::uuid), ('00000000-0000-0000-0000-00000000c0f3'::uuid)$$,
  'ties on updated_at page by id after the cursor');

-- RLS -----------------------------------------------------------------------
select cmp_ok((select count(*) from public.messages where conversation_id = (select ann from _c)),
              '>=', 6::bigint, 'bob, a member, reads the chat through the feed order');
reset role;
select test_as('00000000-0000-0000-0000-0000000cf003', 'cf000000-0000-0000-0000-0000000cf003');
select is((select count(*) from public.messages where conversation_id = (select ann from _c)),
          0::bigint, 'fay, not a member, sees none of its rows');
select is((select count(*) from public.messages where updated_at >= '2000-01-01'),
          0::bigint, 'fay reads an empty change feed');
reset role;

select * from finish();
rollback;
