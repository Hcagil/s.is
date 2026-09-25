-- Editing a message (v0.13): public.edit_message(message, body), the
-- edited_at column it writes, the privileges that make it the only write
-- path, and what an edit must NOT do -- notify anyone, re-order or re-count
-- a conversation, or survive a deletion.
--
-- Every negative fixture fails exactly ONE gate. ann owns the messages under
-- test; bob is a real, active member of the same conversation who did not
-- send them (the sender gate only); dee sends her own fresh message and then
-- loses her session (the app-access gate only); eve sends her own fresh
-- message and then leaves the conversation (the membership gate only). The
-- deleted, forwarded, too-old and bad-body fixtures are all ann's own, fresh
-- where freshness is not the point, in a conversation she is still in.
begin;
select plan(85);

-- fixtures --------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ed001', 'ed-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000ed002', 'ed-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000ed003', 'ed-dee@example.com', now(), '{"full_name":"Dee"}'),
  ('00000000-0000-0000-0000-0000000ed004', 'ed-eve@example.com', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-0000000ed005', 'ed-fay@example.com', now(), '{"full_name":"Fay"}');
insert into app_private.allowlist(email) values
  ('ed-ann@example.com'), ('ed-bob@example.com'), ('ed-dee@example.com'),
  ('ed-eve@example.com'), ('ed-fay@example.com');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ed000000-0000-0000-0000-0000000ed001', '00000000-0000-0000-0000-0000000ed001', now(), now()),
  ('ed000000-0000-0000-0000-0000000ed002', '00000000-0000-0000-0000-0000000ed002', now(), now()),
  ('ed000000-0000-0000-0000-0000000ed003', '00000000-0000-0000-0000-0000000ed003', now(), now()),
  ('ed000000-0000-0000-0000-0000000ed004', '00000000-0000-0000-0000-0000000ed004', now(), now()),
  ('ed000000-0000-0000-0000-0000000ed005', '00000000-0000-0000-0000-0000000ed005', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-0000000ed002', 'ed000000-0000-0000-0000-0000000ed002');
select is(public.activate_session(), true, 'bob is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ed005', 'ed000000-0000-0000-0000-0000000ed005');
select is(public.activate_session(), true, 'fay is active (allowlisted, signed in, in none of these chats)');
reset role;
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select is(public.activate_session(), true, 'ann is active');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000ed002'), null,
            'ann starts a conversation with bob');
reset role;
select test_as('00000000-0000-0000-0000-0000000ed003', 'ed000000-0000-0000-0000-0000000ed003');
select is(public.activate_session(), true, 'dee is active');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000ed002'), null,
            'dee starts her own conversation with bob');
reset role;
select test_as('00000000-0000-0000-0000-0000000ed004', 'ed000000-0000-0000-0000-0000000ed004');
select is(public.activate_session(), true, 'eve is active');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000ed002'), null,
            'eve starts her own conversation with bob');
reset role;

create or replace function _conv_of(a uuid, b uuid) returns uuid language sql as $$
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = a)
     and exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = b)
$$;
create temp table _c as select
  _conv_of('00000000-0000-0000-0000-0000000ed001', '00000000-0000-0000-0000-0000000ed002') as ann,
  _conv_of('00000000-0000-0000-0000-0000000ed003', '00000000-0000-0000-0000-0000000ed002') as dee,
  _conv_of('00000000-0000-0000-0000-0000000ed004', '00000000-0000-0000-0000-0000000ed002') as eve;
grant select on _c to authenticated, anon;

-- Written as postgres, the way delete_message_test.sql does it: a client can
-- never choose created_at, and these fixtures need exact ages. Times are
-- relative to now(), the transaction timestamp edit_message sees too.
insert into public.messages(conversation_id, sender_id, body, created_at) values
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed text',      now() - interval '10 minutes'),
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed inside',    now() - interval '5 hours 59 minutes 59 seconds'),
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed outside',   now() - interval '6 hours 1 second'),
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed doomed',    now() - interval '9 minutes'),
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed to delete', now() - interval '8 minutes'),
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed to wipe',   now() - interval '3 hours'),
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed newest',    now() - interval '1 minute');
insert into public.messages(conversation_id, sender_id, body, forwarded, created_at) values
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'ed forwarded', true, now() - interval '7 minutes');
insert into public.messages(conversation_id, sender_id, body, attachment_path, created_at) values
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', 'a caption',
   (select ann from _c)::text || '/ed-photo.jpg', now() - interval '6 minutes');
insert into public.messages(conversation_id, sender_id, body, deleted, deleted_at, created_at) values
  ((select ann from _c), '00000000-0000-0000-0000-0000000ed001', '', 'placeholder', now(), now() - interval '2 hours');
insert into public.messages(conversation_id, sender_id, body, created_at) values
  ((select dee from _c), '00000000-0000-0000-0000-0000000ed003', 'dee says hi', now() - interval '5 minutes'),
  ((select eve from _c), '00000000-0000-0000-0000-0000000ed004', 'eve says hi', now() - interval '5 minutes');

create temp table _m as select
  (select id from public.messages where body = 'ed text')      as txt,
  (select id from public.messages where body = 'ed inside')    as inside,
  (select id from public.messages where body = 'ed outside')   as outside,
  (select id from public.messages where body = 'ed doomed')    as doomed,
  (select id from public.messages where body = 'ed to delete') as to_delete,
  (select id from public.messages where body = 'ed to wipe')   as to_wipe,
  (select id from public.messages where body = 'ed newest')    as newest,
  (select id from public.messages where body = 'ed forwarded') as fwd,
  (select id from public.messages where attachment_path = (select ann from _c)::text || '/ed-photo.jpg') as photo,
  (select id from public.messages where conversation_id = (select ann from _c) and deleted = 'placeholder') as gone,
  (select id from public.messages where body = 'dee says hi')  as dee,
  (select id from public.messages where body = 'eve says hi')  as eve;
grant select on _m to authenticated, anon;

-- 1 the column: nullable, no default, so older builds' explicit inserts ---
-- and selects are unaffected, and a row is unedited until edit_message says so
select has_column('public', 'messages', 'edited_at', 'messages.edited_at exists');
select col_type_is('public', 'messages', 'edited_at', 'timestamp with time zone',
                   'edited_at is a timestamptz');
select col_is_null('public', 'messages', 'edited_at', 'edited_at is nullable');
select col_hasnt_default('public', 'messages', 'edited_at', 'edited_at has no default');
select is((select edited_at from public.messages where id = (select txt from _m)), null,
          'a freshly sent message is not edited');

-- 2 the function: shape and who may call it -------------------------------
select function_returns('public', 'edit_message', array['uuid', 'text'], 'messages',
                        'edit_message(uuid, text) returns a messages row');
select is((select prosecdef from pg_proc where oid = 'public.edit_message(uuid, text)'::regprocedure),
          true, 'edit_message is security definer');
select is((select proconfig from pg_proc where oid = 'public.edit_message(uuid, text)'::regprocedure),
          array['search_path=""'], 'edit_message pins an empty search_path');
select function_privs_are('public', 'edit_message', array['uuid', 'text'], 'anon', '{}'::text[],
                          'anon holds no execute on edit_message');
select function_privs_are('public', 'edit_message', array['uuid', 'text'], 'authenticated', array['EXECUTE'],
                          'authenticated may execute edit_message');
set local role anon;
select throws_ok(format($$select public.edit_message(%L, 'anon edit')$$, (select txt from _m)),
                 '42501', null, 'anon cannot execute edit_message');
reset role;

-- 3 the sole write path: no client UPDATE on messages at all ---------------
select is((select count(*) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'messages'
              and grantee in ('authenticated', 'anon', 'PUBLIC') and privilege_type = 'UPDATE'), 0::bigint,
          'nobody but the definer can UPDATE any column of messages');
select table_privs_are('public', 'messages', 'anon', '{}'::text[], 'anon holds nothing on messages');
select set_eq(
  $$select column_name::text from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'messages'
       and grantee = 'authenticated' and privilege_type = 'INSERT'$$,
  $$values ('conversation_id'),('sender_id'),('body'),('attachment_path'),('attachment_preview'),
           ('reply_to'),('forwarded')$$,
  'authenticated still inserts exactly the same seven columns -- never edited_at');
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select throws_ok(format($$update public.messages set body = 'sneaky', edited_at = now() where id = %L$$,
                        (select txt from _m)),
                 '42501', null, 'ann cannot update her own message directly');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, edited_at) values (%L, %L, 'pre-edited', now())$$,
         (select ann from _c), '00000000-0000-0000-0000-0000000ed001'),
  '42501', null, 'ann cannot insert a message already marked edited');
reset role;

-- 4 an accepted edit ------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
create temp table _r as
  select * from public.edit_message((select txt from _m), 'ed text, fixed');
reset role;
select is((select id from _r), (select txt from _m), 'edit_message returns the edited row');
select is((select body from _r), 'ed text, fixed', 'the returned row carries the new body');
select is((select edited_at from _r), now(), 'the returned row carries edited_at = now()');
select is((select body from public.messages where id = (select txt from _m)), 'ed text, fixed',
          'the stored body is replaced');
select is((select edited_at from public.messages where id = (select txt from _m)), now(),
          'edited_at is set to now()');
select is((select created_at from public.messages where id = (select txt from _m)), now() - interval '10 minutes',
          'created_at is untouched: an edit never moves a message');
select is((select sender_id from public.messages where id = (select txt from _m)),
          '00000000-0000-0000-0000-0000000ed001'::uuid, 'sender_id is untouched');
select is((select count(*) from public.messages where body like 'ed text%'), 1::bigint,
          'no second row was written: it is an edit, not a send');

-- a second edit of the same message is allowed and keeps no history
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select lives_ok(format($$select public.edit_message(%L, 'ed text, again')$$, (select txt from _m)),
                'an edited message may be edited again');
reset role;
select is((select body from public.messages where id = (select txt from _m)), 'ed text, again',
          'the latest edit wins');
select is((select count(*) from public.messages where body in ('ed text', 'ed text, fixed')), 0::bigint,
          'no earlier version is kept anywhere in messages');

-- 5 the six-hour window, each side of it ----------------------------------
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select lives_ok(format($$select public.edit_message(%L, 'just in time')$$, (select inside from _m)),
                'a message 5h59m59s old may be edited');
select throws_ok(format($$select public.edit_message(%L, 'too late')$$, (select outside from _m)),
                 '42501', null, 'a message 6h00m01s old cannot be edited');
reset role;
select is((select body from public.messages where id = (select inside from _m)), 'just in time',
          'the in-window edit was stored');
select is((select (body, edited_at) from public.messages where id = (select outside from _m)),
          row('ed outside'::text, null::timestamptz), 'the too-old message is untouched');

-- 6 not the sender: bob is a member, active, and the message is fresh -------
select test_as('00000000-0000-0000-0000-0000000ed002', 'ed000000-0000-0000-0000-0000000ed002');
select throws_ok(format($$select public.edit_message(%L, 'bob was here')$$, (select newest from _m)),
                 '42501', null, 'a fellow member cannot edit a message he did not send');
reset role;
select is((select (body, edited_at) from public.messages where id = (select newest from _m)),
          row('ed newest'::text, null::timestamptz), 'the message bob tried to edit is untouched');

-- 7 deleted and forwarded: ann's own, fresh, in her own conversation --------
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select throws_ok(format($$select public.edit_message(%L, 'back from the dead')$$, (select gone from _m)),
                 '42501', null, 'a deleted (placeholder) message cannot be edited');
select throws_ok(format($$select public.edit_message(%L, 'my words now')$$, (select fwd from _m)),
                 '42501', null, 'a forwarded message cannot be edited, not even by who forwarded it');
select is(public.delete_message((select doomed from _m)), null, 'ann deletes a fresh message (it vanishes)');
select throws_ok(format($$select public.edit_message(%L, 'undo')$$, (select doomed from _m)),
                 '42501', null, 'a vanished message cannot be edited');
reset role;
select is((select (body, deleted::text, edited_at) from public.messages where id = (select gone from _m)),
          row(''::text, 'placeholder'::text, null::timestamptz), 'the placeholder is untouched');
select is((select (body, edited_at) from public.messages where id = (select fwd from _m)),
          row('ed forwarded'::text, null::timestamptz), 'the forwarded message is untouched');
select is((select (body, edited_at) from public.messages where id = (select doomed from _m)),
          row(''::text, null::timestamptz), 'the vanished message is untouched');

-- 8 body rules for a text message: 1..4000 characters once trimmed ---------
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select throws_ok(format($$select public.edit_message(%L, '')$$, (select inside from _m)),
                 '42501', null, 'a text message cannot be edited to nothing');
-- Trimmed as messages_body_check trims: btrim(), i.e. spaces.
select throws_ok(format($$select public.edit_message(%L, '     ')$$, (select inside from _m)),
                 '42501', null, 'a text message cannot be edited to spaces only');
select throws_ok(format($$select public.edit_message(%L, null)$$, (select inside from _m)),
                 '42501', null, 'a null body is refused');
select throws_ok(format($$select public.edit_message(%L, repeat('x', 4001))$$, (select inside from _m)),
                 '42501', null, 'a text message cannot be edited to 4001 characters');
reset role;
select is((select body from public.messages where id = (select inside from _m)), 'just in time',
          'every refused body left the message as it was');
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select lives_ok(format($$select public.edit_message(%L, repeat('x', 4000))$$, (select inside from _m)),
                'exactly 4000 characters is allowed');
select lives_ok(format($$select public.edit_message(%L, '  ' || repeat('y', 4000) || '  ')$$, (select inside from _m)),
                '4000 characters plus surrounding spaces is allowed: the limit counts trimmed text');
reset role;
select is((select btrim(body) from public.messages where id = (select inside from _m)), repeat('y', 4000),
          'the 4000-character edit was stored');

-- 9 body rules for a photo message: 0..4000, an empty caption is fine ------
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select lives_ok(format($$select public.edit_message(%L, 'a better caption')$$, (select photo from _m)),
                'a photo''s caption may be changed');
select lives_ok(format($$select public.edit_message(%L, '')$$, (select photo from _m)),
                'a photo''s caption may be removed entirely');
reset role;
select is((select (btrim(body), attachment_path, edited_at) from public.messages where id = (select photo from _m)),
          row(''::text, (select ann from _c)::text || '/ed-photo.jpg', now()),
          'the photo keeps its attachment and is marked edited with an empty caption');
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select throws_ok(format($$select public.edit_message(%L, repeat('x', 4001))$$, (select photo from _m)),
                 '42501', null, 'a caption cannot be 4001 characters');
reset role;
select is((select btrim(body) from public.messages where id = (select photo from _m)), '',
          'the refused caption left the photo as it was');

-- 10 without app access: dee's own, fresh message, her own conversation -----
delete from auth.sessions where id = 'ed000000-0000-0000-0000-0000000ed003';
select test_as('00000000-0000-0000-0000-0000000ed003', 'ed000000-0000-0000-0000-0000000ed003');
select throws_ok(format($$select public.edit_message(%L, 'dee edits')$$, (select dee from _m)),
                 '42501', null, 'a member whose session was revoked cannot edit her own message');
reset role;
select is((select (body, edited_at) from public.messages where id = (select dee from _m)),
          row('dee says hi'::text, null::timestamptz), 'only the app-access gate stopped dee');

-- 11 no longer a member: eve's own, fresh message, eve still active --------
delete from public.conversation_members
 where conversation_id = (select eve from _c) and user_id = '00000000-0000-0000-0000-0000000ed004';
select test_as('00000000-0000-0000-0000-0000000ed004', 'ed000000-0000-0000-0000-0000000ed004');
select throws_ok(format($$select public.edit_message(%L, 'eve edits')$$, (select eve from _m)),
                 '42501', null, 'a sender who is no longer a member cannot edit her message');
reset role;
select is((select (body, edited_at) from public.messages where id = (select eve from _m)),
          row('eve says hi'::text, null::timestamptz), 'only the membership gate stopped eve');

-- a message id that does not exist is refused the same way, not a null row
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select throws_ok($$select public.edit_message('00000000-0000-0000-0000-000000000000'::uuid, 'ghost')$$,
                 '42501', null, 'a message that does not exist is refused');
reset role;

-- 12 an edit announces nothing and re-counts nothing ------------------------
-- Positive control first: with Vault holding the notify URL, a SEND queues
-- exactly one request, so the queue is observable here. Then an edit must
-- queue nothing more.
select vault.create_secret('https://ed-test.local/hook', 'notify_on_message_url');
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select lives_ok(format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'ed control')$$,
                       (select ann from _c), '00000000-0000-0000-0000-0000000ed001'),
                'ann sends one message with the notify URL configured');
reset role;
select is((select count(*) from net.http_request_queue), 1::bigint,
          'control: a send queues exactly one push request');
-- Move the control message out of the way (older than every fixture), so
-- the preview and unread checks below are about 'ed newest' alone.
update public.messages set created_at = now() - interval '1 day' where body = 'ed control';
-- bob has read everything up to half a minute ago, newest included.
update public.conversation_members set last_read_at = now() - interval '30 seconds'
 where conversation_id = (select ann from _c) and user_id = '00000000-0000-0000-0000-0000000ed002';

select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select lives_ok(format($$select public.edit_message(%L, 'ed newest, edited')$$, (select newest from _m)),
                'ann edits her newest message');
reset role;
select is((select count(*) from net.http_request_queue), 1::bigint,
          'the edit queued no push request: nothing new in the pg_net queue');
select is((select count(*) from app_private.push_sent where message_id = (select newest from _m)), 0::bigint,
          'and claimed no push for the edited message');

select test_as('00000000-0000-0000-0000-0000000ed002', 'ed000000-0000-0000-0000-0000000ed002');
select is((select coalesce(sum(unread), 0)::int from public.unread_counts()
            where conversation_id = (select ann from _c)), 0,
          'an edit does not make a message bob has read unread again');

-- 13 the conversation preview follows the newest message only ---------------
select is((select body from public.conversation_previews where conversation_id = (select ann from _c)),
          'ed newest, edited', 'editing the newest message changes the preview text');
select is((select created_at from public.conversation_previews where conversation_id = (select ann from _c)),
          now() - interval '1 minute', 'but not its time: the conversation does not move');
reset role;
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select lives_ok(format($$select public.edit_message(%L, 'ed older, edited')$$, (select to_delete from _m)),
                'ann edits an older message');
reset role;
select test_as('00000000-0000-0000-0000-0000000ed002', 'ed000000-0000-0000-0000-0000000ed002');
select is((select body from public.conversation_previews where conversation_id = (select ann from _c)),
          'ed newest, edited', 'editing an older message leaves the preview alone');

-- 14 Realtime: an edit is an UPDATE of a published row, readable by members
-- only (postgres_changes applies the select policy per subscriber) --------
select is((select body from public.messages where id = (select to_delete from _m)), 'ed older, edited',
          'bob, a member, reads the edited row');
reset role;
select test_as('00000000-0000-0000-0000-0000000ed005', 'ed000000-0000-0000-0000-0000000ed005');
select is((select count(*) from public.messages where id = (select to_delete from _m)), 0::bigint,
          'fay, active but not a member, cannot read it -- so Realtime cannot deliver it to her');
reset role;
select is((select pubupdate from pg_publication where pubname = 'supabase_realtime'), true,
          'Realtime still publishes updates');
select ok((select 'edited_at' = any(attnames) and 'body' = any(attnames) from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'),
          'the published messages row carries body and edited_at');

-- 15 deleting an edited message clears its edited mark ---------------------
-- A deleted row keeps only who sent it and when; "edited" is not kept.
select test_as('00000000-0000-0000-0000-0000000ed001', 'ed000000-0000-0000-0000-0000000ed001');
select is(public.delete_message((select to_delete from _m)), null,
          'ann deletes the older edited message (under an hour: vanished)');
select lives_ok(format($$select public.edit_message(%L, 'wipe me')$$, (select to_wipe from _m)),
                'ann edits a 3-hour-old message');
select is(public.delete_message((select to_wipe from _m)), null,
          'and deletes it (over an hour: placeholder)');
reset role;
select is((select (deleted::text, edited_at) from public.messages where id = (select to_delete from _m)),
          row('vanished'::text, null::timestamptz), 'a vanished message is no longer marked edited');
select is((select (deleted::text, edited_at) from public.messages where id = (select to_wipe from _m)),
          row('placeholder'::text, null::timestamptz), 'a placeholder is no longer marked edited');

select * from finish();
rollback;
