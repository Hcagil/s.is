-- Deleting a message for everyone (v0.10): public.delete_message(), the
-- messages check constraints it depends on, the storage removal it unlocks,
-- and its effect on conversation_previews, unread_counts and
-- push_targets_for_message.
--
-- Every negative fixture fails exactly ONE gate: bob is a real member of the
-- conversation but did not send the message under test (the sender gate
-- only); dee sends her own, fresh, well within-window message and then loses
-- her session (the app-access gate only). A stranger who fails every gate at
-- once would prove nothing about any one of them.
begin;
select plan(67);

-- storage.objects carries a statement-level trigger that unconditionally
-- refuses direct DELETE (protect_objects_delete), independent of RLS, unless
-- this is set -- with it set, an unauthorized delete still does nothing: RLS
-- simply leaves the row out of the statement, silently, rather than raising.
set local storage.allow_delete_query = 'true';

-- fixtures --------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000de001', 'de-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000de002', 'de-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000de003', 'de-dee@example.com', now(), '{"full_name":"Dee"}');
insert into app_private.allowlist(email) values
  ('de-ann@example.com'), ('de-bob@example.com'), ('de-dee@example.com');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('de000000-0000-0000-0000-0000000de001', '00000000-0000-0000-0000-0000000de001', now(), now()),
  ('de000000-0000-0000-0000-0000000de002', '00000000-0000-0000-0000-0000000de002', now(), now()),
  ('de000000-0000-0000-0000-0000000de003', '00000000-0000-0000-0000-0000000de003', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select is(public.activate_session(), true, 'ann is active');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000de002'), null,
            'ann starts a conversation with bob');
reset role;
select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select is(public.activate_session(), true, 'bob is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000de003', 'de000000-0000-0000-0000-0000000de003');
select is(public.activate_session(), true, 'dee is active');
reset role;

create temp table _c1 as
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000de001')
     and exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000de002');
grant select on _c1 to authenticated;

-- dee's own conversation with bob, kept apart from _c1 so revoking her
-- session below cannot touch anything ann or bob do.
select test_as('00000000-0000-0000-0000-0000000de003', 'de000000-0000-0000-0000-0000000de003');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000de002'), null,
            'dee starts a conversation with bob');
reset role;
create temp table _c2 as
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000de003')
     and exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id and m.user_id = '00000000-0000-0000-0000-0000000de002');
grant select on _c2 to authenticated;

-- Written as postgres, exactly the way unread_test.sql backdates created_at:
-- a client can never choose it, and every fixture here needs an exact age.
insert into public.messages(conversation_id, sender_id, body, created_at) values
  ((select id from _c1), '00000000-0000-0000-0000-0000000de001', 'recent text', now() - interval '10 minutes'),
  ((select id from _c1), '00000000-0000-0000-0000-0000000de001', 'not so recent', now() - interval '2 hours'),
  ((select id from _c1), '00000000-0000-0000-0000-0000000de001', 'ancient', now() - interval '7 hours');
insert into public.messages(conversation_id, sender_id, body, attachment_path, created_at) values
  ((select id from _c1), '00000000-0000-0000-0000-0000000de001', '',
   (select id from _c1)::text || '/de-photo.jpg', now() - interval '5 minutes'),
  ((select id from _c1), '00000000-0000-0000-0000-0000000de001', '',
   (select id from _c1)::text || '/de-old-photo.jpg', now() - interval '7 hours');

-- Storage rows for the two photos above, owned by ann, as a real upload
-- would leave them -- needed now that messages_send checks ownership too.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _c1)::text || '/de-photo.jpg',
   '00000000-0000-0000-0000-0000000de001', '{"size":3}'::jsonb),
  ('attachments', (select id from _c1)::text || '/de-old-photo.jpg',
   '00000000-0000-0000-0000-0000000de001', '{"size":3}'::jsonb);

create temp table _m as
  select
    (select id from public.messages where conversation_id = (select id from _c1) and body = 'recent text') as recent,
    (select id from public.messages where conversation_id = (select id from _c1) and body = 'not so recent') as mid,
    (select id from public.messages where conversation_id = (select id from _c1) and body = 'ancient') as old,
    (select id from public.messages
      where attachment_path = (select id from _c1)::text || '/de-photo.jpg') as photo,
    (select id from public.messages
      where attachment_path = (select id from _c1)::text || '/de-old-photo.jpg') as old_photo;
grant select on _m to authenticated;

-- 1 anon cannot reach it at all -----------------------------------------
set local role anon;
select throws_ok($$select public.delete_message('00000000-0000-0000-0000-000000000000'::uuid)$$,
                 'permission denied for function delete_message', 'anon cannot execute delete_message');
reset role;
select function_privs_are('public', 'delete_message', array['uuid'], 'anon', '{}'::text[],
                          'anon holds no execute on delete_message');
select function_privs_are('public', 'delete_message', array['uuid'], 'authenticated', array['EXECUTE'],
                          'authenticated may execute delete_message');

-- 2 not the sender ---------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select throws_ok(format($$select public.delete_message(%L)$$, (select recent from _m)),
                 '42501', null, 'a fellow member who did not send it cannot delete it');
reset role;
select is((select deleted from public.messages where id = (select recent from _m)), null,
          'the refused message is untouched');

-- 3 over six hours old -------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select throws_ok(format($$select public.delete_message(%L)$$, (select old from _m)),
                 '42501', null, 'a message over 6 hours old cannot be deleted');
reset role;
select is((select deleted from public.messages where id = (select old from _m)), null,
          'the too-old message is untouched');

-- 4 within the hour: vanishes, and a text message returns no path -----------
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select is(public.delete_message((select recent from _m)), null,
          'a text message returns no path to remove from storage');
reset role;
select is((select deleted from public.messages where id = (select recent from _m)), 'vanished',
          'under an hour old: vanished');
select isnt((select deleted_at from public.messages where id = (select recent from _m)), null,
            'deleted_at is set');
select is((select body from public.messages where id = (select recent from _m)), '',
          'the body is wiped');

-- already deleted -------------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select throws_ok(format($$select public.delete_message(%L)$$, (select recent from _m)),
                 '42501', null, 'a message already deleted cannot be deleted again');
reset role;

-- 5 between one and six hours: a placeholder ---------------------------------
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(format($$select public.delete_message(%L)$$, (select mid from _m)),
                'a message between 1 and 6 hours old may be deleted');
reset role;
select is((select deleted from public.messages where id = (select mid from _m)), 'placeholder',
          'between 1 and 6 hours old: a placeholder');

-- 6 a photo message returns its path, and wipes attachment_path/preview -----
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select is(public.delete_message((select photo from _m)),
          (select id from _c1)::text || '/de-photo.jpg',
          'a photo message returns the path it held, to remove from storage');
reset role;
select is((select attachment_path from public.messages where id = (select photo from _m)), null,
          'attachment_path is wiped');
select is((select deleted from public.messages where id = (select photo from _m)), 'vanished',
          'the photo message, sent 5 minutes ago, vanished too');

-- 7 without app access: the sender gate alone cannot be what stops her ------
select test_as('00000000-0000-0000-0000-0000000de003', 'de000000-0000-0000-0000-0000000de003');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'dee says hi')$$,
         (select id from _c2), '00000000-0000-0000-0000-0000000de003'),
  'dee sends her own message');
reset role;
create temp table _dee as
  select id from public.messages where conversation_id = (select id from _c2) and body = 'dee says hi';
grant select on _dee to authenticated;

delete from auth.sessions where id = 'de000000-0000-0000-0000-0000000de003';
select test_as('00000000-0000-0000-0000-0000000de003', 'de000000-0000-0000-0000-0000000de003');
select throws_ok(format($$select public.delete_message(%L)$$, (select id from _dee)),
                 '42501', null, 'a member whose session was revoked cannot delete her own message');
reset role;
select is((select deleted from public.messages where id = (select id from _dee)), null,
          'the message is untouched: only the app-access gate stopped her');

-- 8 the check constraints delete_message depends on --------------------------
-- Written directly as postgres: authenticated has no column privilege on
-- deleted/deleted_at at all (section 9 pins that), so only a bypass reaches
-- these clauses directly.
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, deleted, deleted_at)
           values (%L, %L, '', 'vanished', now())$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  'a deleted row with nothing in it is accepted');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, deleted, deleted_at)
           values (%L, %L, 'still has text', 'vanished', now())$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  '23514', null, 'a deleted row still carrying text is refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, deleted, deleted_at)
           values (%L, %L, '', %L, 'vanished', now())$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001',
         (select id from _c1)::text || '/ck-photo.jpg'),
  '23514', null, 'a deleted row still carrying a photo is refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, deleted)
           values (%L, %L, '', 'placeholder')$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  '23514', null, 'deleted without deleted_at is refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, deleted_at)
           values (%L, %L, 'live text', now())$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  '23514', null, 'deleted_at without deleted is refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body)
           values (%L, %L, '')$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  '23514', null, 'a live row still needs text or a photo');

-- 9 clients cannot insert deleted/deleted_at, or update any message ----------
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, deleted, deleted_at)
           values (%L, %L, '', 'vanished', now())$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  '42501', null, 'a member cannot insert deleted/deleted_at directly');
select throws_ok($$update public.messages set body = 'edited' where true$$,
                 '42501', null, 'a member cannot update any message, deleted or not');
reset role;
select set_eq(
  $$select column_name::text from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'messages'
       and grantee = 'authenticated' and privilege_type = 'INSERT'$$,
  $$values ('conversation_id'),('sender_id'),('body'),('attachment_path'),('attachment_preview')$$,
  'authenticated may still insert only the original five columns -- never deleted or deleted_at');
select is((select count(*) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'messages'
              and grantee = 'authenticated' and privilege_type = 'UPDATE'), 0::bigint,
          'authenticated holds no UPDATE privilege on messages at all');

-- 10 storage removal: only the sender, only once recorded, only while live --
-- bob is not the object's owner, even though ann's message pointing at it
-- has already been deleted.
select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select lives_ok(
  format($$delete from storage.objects where bucket_id = 'attachments' and name = %L$$,
         (select id from _c1)::text || '/de-photo.jpg'),
  'a fellow member''s delete does nothing: he is not the object''s owner');
reset role;
select is((select count(*) from storage.objects
            where name = (select id from _c1)::text || '/de-photo.jpg'), 1::bigint,
          'the object survives: bob is not its owner');

-- ann cannot remove the OLD photo: delete_message was never called on it, and
-- its message is still live and shows it.
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$delete from storage.objects where bucket_id = 'attachments' and name = %L$$,
         (select id from _c1)::text || '/de-old-photo.jpg'),
  'ann''s delete does nothing: the photo was never recorded as deleted');
reset role;
select is((select count(*) from storage.objects
            where name = (select id from _c1)::text || '/de-old-photo.jpg'), 1::bigint,
          'the never-deleted photo survives');

-- ann, the sender, removes her own deleted photo -----------------------------
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$delete from storage.objects where bucket_id = 'attachments' and name = %L$$,
         (select id from _c1)::text || '/de-photo.jpg'),
  'ann removes the photo of the message she deleted');
reset role;
select is((select count(*) from storage.objects
            where name = (select id from _c1)::text || '/de-photo.jpg'), 0::bigint,
          'the object is gone');

-- 11 the unique photo path: two messages never share one --------------------
-- ann cannot dodge the 6-hour window on her OLD, still-live photo by
-- reusing its path in a brand-new message -- she owns the file and the
-- folder matches, so only the unique index can be what blocks her.
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001',
         (select id from _c1)::text || '/de-old-photo.jpg'),
  '23505', null, 'ann cannot reuse her own still-live old photo''s path to dodge its 6-hour window');
reset role;

-- a fellow member cannot squat on it either, live or not: null sqlstate
-- because ownership and uniqueness both refuse it, and either error proves
-- the path is not his to claim.
select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de002',
         (select id from _c1)::text || '/de-old-photo.jpg'),
  null, null, 'a fellow member cannot squat on another sender''s live photo path');
reset role;
select is((select count(*) from public.messages
            where attachment_path = (select id from _c1)::text || '/de-old-photo.jpg'), 1::bigint,
          'still exactly one message holds that path');

-- 12 the send policy: an attachment must live in its own conversation folder -
-- ann owns this object too (ownership alone must not be enough to pass):
-- its folder is some other conversation entirely, not _c1's.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', '11111111-2222-3333-4444-555555555555/spoof.jpg',
   '00000000-0000-0000-0000-0000000de001', '{"size":3}'::jsonb);
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', '11111111-2222-3333-4444-555555555555/spoof.jpg')$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  '42501', null, 'an attachment path outside the message''s own conversation folder is refused, even one ann owns');
reset role;
select is((select count(*) from public.messages where attachment_path like '%/spoof.jpg'), 0::bigint,
          'no message was created for the mismatched path');

-- 13 ownership: reused after a delete, but only the true owner may reuse it -
-- ann uploads and sends a photo, then deletes that message, freeing its path
-- from the unique index. Bob cannot then claim it as his own -- he never
-- uploaded it -- even though the path is free and the folder matches.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _c1)::text || '/de-reuse.jpg',
   '00000000-0000-0000-0000-0000000de001', '{"size":3}'::jsonb);
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001',
         (select id from _c1)::text || '/de-reuse.jpg'),
  'ann sends a photo she owns');
reset role;
create temp table _reuse_a as
  select id from public.messages where attachment_path = (select id from _c1)::text || '/de-reuse.jpg';
grant select on _reuse_a to authenticated;

select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select is(public.delete_message((select id from _reuse_a)),
          (select id from _c1)::text || '/de-reuse.jpg',
          'ann deletes it, recording the path and freeing it from the unique index');
reset role;

select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de002',
         (select id from _c1)::text || '/de-reuse.jpg'),
  '42501', null,
  'a member cannot claim a photo someone else uploaded, even once its message is gone');
reset role;

-- ann may re-send the very same photo she still owns.
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001',
         (select id from _c1)::text || '/de-reuse.jpg'),
  'ann re-sends the same photo she still owns');
reset role;
create temp table _reuse_b as
  select id from public.messages
   where attachment_path = (select id from _c1)::text || '/de-reuse.jpg'
     and id <> (select id from _reuse_a);
grant select on _reuse_b to authenticated;

-- Even though the path was already recorded as deleted for ann, a live
-- message (the resend) still shows it: removal must be refused.
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$delete from storage.objects where bucket_id = 'attachments' and name = %L$$,
         (select id from _c1)::text || '/de-reuse.jpg'),
  'ann''s delete does nothing while a live message still shows the photo, even though it was already recorded');
reset role;
select is((select count(*) from storage.objects
            where name = (select id from _c1)::text || '/de-reuse.jpg'), 1::bigint,
          'the object survives while the resend is still live');

-- Once the resend is deleted too, nothing live references it, and removal
-- succeeds.
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select is(public.delete_message((select id from _reuse_b)),
          (select id from _c1)::text || '/de-reuse.jpg', 'ann deletes the resend too');
select lives_ok(
  format($$delete from storage.objects where bucket_id = 'attachments' and name = %L$$,
         (select id from _c1)::text || '/de-reuse.jpg'),
  'now removal succeeds: nothing live shows the photo any more');
reset role;

-- 14 conversation_previews / unread_counts ignore what is gone --------------
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'push me')$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001'),
  'ann sends one more message, the newest in the conversation');
reset role;
create temp table _new as
  select id from public.messages where conversation_id = (select id from _c1) and body = 'push me';
grant select on _new to authenticated;

update public.conversation_members set last_read_at = now() - interval '1 hour'
 where conversation_id = (select id from _c1) and user_id = '00000000-0000-0000-0000-0000000de002';

select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select lives_ok($$select public.register_device_token('de-bob-device', 'android')$$,
                'bob registers a phone, so he is reachable by push');
select is((select unread from public.unread_counts() where conversation_id = (select id from _c1)), 1,
          'bob: exactly the one live, unread message counts');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select id from _new))), 1::bigint,
          'before deletion, bob is a push target for the new message');

select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(format($$select public.delete_message(%L)$$, (select id from _new)),
                'ann deletes the newest message too');
reset role;

select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select is((select count(*) from public.unread_counts() where conversation_id = (select id from _c1)), 0::bigint,
          'unread_counts ignores a deleted message: bob has nothing unread left');
reset role;
select is((select count(*) from app_private.push_targets_for_message((select id from _new))), 0::bigint,
          'a message deleted within the push window reaches nobody');

-- The newest message and the two before it (photo, recent) are all vanished:
-- the preview falls back past all of them to the placeholder underneath.
select test_as('00000000-0000-0000-0000-0000000de002', 'de000000-0000-0000-0000-0000000de002');
select is((select body from public.conversation_previews where conversation_id = (select id from _c1)), '',
          'vanished messages are skipped: the preview falls back to the placeholder before them');
select is((select deleted from public.conversation_previews where conversation_id = (select id from _c1)),
          'placeholder', 'conversation_previews exposes deleted for a placeholder');
reset role;

-- 15 without app access: ownership and the record are not enough on their own
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select id from _c1)::text || '/de-final.jpg',
   '00000000-0000-0000-0000-0000000de001', '{"size":3}'::jsonb);
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select id from _c1), '00000000-0000-0000-0000-0000000de001',
         (select id from _c1)::text || '/de-final.jpg'),
  'ann sends one last photo');
reset role;
create temp table _final as
  select id from public.messages where attachment_path = (select id from _c1)::text || '/de-final.jpg';
grant select on _final to authenticated;

select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select is(public.delete_message((select id from _final)),
          (select id from _c1)::text || '/de-final.jpg', 'ann deletes it while she still has access');
reset role;

delete from auth.sessions where id = 'de000000-0000-0000-0000-0000000de001';
select test_as('00000000-0000-0000-0000-0000000de001', 'de000000-0000-0000-0000-0000000de001');
select lives_ok(
  format($$delete from storage.objects where bucket_id = 'attachments' and name = %L$$,
         (select id from _c1)::text || '/de-final.jpg'),
  'ann''s delete does nothing once her session is revoked, even for her own recorded, unreferenced photo');
reset role;
select is((select count(*) from storage.objects
            where name = (select id from _c1)::text || '/de-final.jpg'), 1::bigint,
          'the object survives: app access, not just ownership and the record, is required');

select * from finish();
rollback;
