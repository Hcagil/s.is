-- Image attachments: the storage policies, the relaxed body check, and the
-- insert grant on public.messages.
--
-- The object key is `<conversation_id>/<something>`, so the FIRST path segment
-- is the authorisation subject. Every negative fixture here is chosen to fail
-- the ONE clause under test: `dan` is allowlisted and holds an active session,
-- so he passes `has_app_access()` and can only be stopped by membership;
-- `ann` with a revoked session is still a member, so she can only be stopped
-- by `has_app_access()`. A stranger would fail the first gate and prove
-- nothing about the rest.
begin;
select plan(36);

-- fixtures ------------------------------------------------------------------
-- ann, bob: members of the conversation. dan: allowlisted and ACTIVE but not
-- a member. cat: signed in, never allowlisted.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000aa01', 'att-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-00000000bb01', 'att-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-00000000dd01', 'att-dan@example.com', now(), '{"full_name":"Dan"}'),
  ('00000000-0000-0000-0000-00000000cc01', 'att-cat@example.com', now(), '{"full_name":"Cat"}');
insert into app_private.allowlist(email) values
  ('att-ann@example.com'), ('att-bob@example.com'), ('att-dan@example.com');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a7a7a7a7-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-00000000aa01', now(), now()),
  ('b7b7b7b7-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '00000000-0000-0000-0000-00000000bb01', now(), now()),
  ('d7d7d7d7-dddd-dddd-dddd-dddddddddddd', '00000000-0000-0000-0000-00000000dd01', now(), now()),
  ('c7c7c7c7-cccc-cccc-cccc-cccccccccccc', '00000000-0000-0000-0000-00000000cc01', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-00000000bb01', 'b7b7b7b7-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-00000000dd01', 'd7d7d7d7-dddd-dddd-dddd-dddddddddddd');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-00000000aa01', 'a7a7a7a7-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select public.activate_session();
select public.start_direct_conversation('00000000-0000-0000-0000-00000000bb01');
reset role;

-- Captured with RLS bypassed so the negative fixtures below attack the real
-- conversation id rather than a guess.
create temp table _fx as
  select c.id as conv from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id
                    and m.user_id = '00000000-0000-0000-0000-00000000aa01');
grant select on _fx to authenticated;

-- 1 the bucket itself -------------------------------------------------------
-- A public bucket, or a missing size/type limit, hands every policy below a
-- door it does not guard.
select is((select public from storage.buckets where id = 'attachments'), false,
          'the attachments bucket is private');
select is((select file_size_limit from storage.buckets where id = 'attachments'), 10485760::bigint,
          'the attachments bucket caps an object at 10 MB');
select set_eq(
  $$select unnest(allowed_mime_types) from storage.buckets where id = 'attachments'$$,
  $$values ('image/jpeg'),('image/png'),('image/webp'),('image/gif')$$,
  'the attachments bucket accepts only the four image types');

-- 2 is_member_of_path is total ---------------------------------------------
-- A storage key is attacker-supplied text. If this raises on nonsense, the
-- refusal arrives as a 500 and, worse, any scan over a bucket holding one bad
-- key fails for everyone. Called as postgres: authenticated may not reach
-- app_private at all.
select is(app_private.is_member_of_path('photo.jpg'), false,
          'a key with no folder is not a member path');
select is(app_private.is_member_of_path('not-a-uuid/photo.jpg'), false,
          'a non-uuid first segment is not a member path');
select is(app_private.is_member_of_path(''), false,
          'an empty key is not a member path');
select is(app_private.is_member_of_path('/photo.jpg'), false,
          'an empty first segment is not a member path');
select is(app_private.is_member_of_path('00000000-0000-0000-0000-00000000aa01/x.jpg'), false,
          'a well-formed uuid that is no conversation is not a member path');
select is(app_private.is_member_of_path(null), false,
          'a null key answers false, not an error');

-- 3 a member uploads --------------------------------------------------------
select test_as('00000000-0000-0000-0000-00000000aa01', 'a7a7a7a7-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select lives_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('attachments', %L, %L, '{"size":3}'::jsonb)$$,
         (select conv from _fx) || '/photo.jpg', '00000000-0000-0000-0000-00000000aa01'),
  'a member uploads into the conversation folder');
select is((select count(*) from storage.objects where bucket_id = 'attachments'), 1::bigint,
          'the uploader reads back her own object');

-- owner_id is the clause under test: everything else about this insert is
-- valid, so deleting `owner_id = auth.uid()` turns this green.
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('attachments', %L, %L, '{"size":3}'::jsonb)$$,
         (select conv from _fx) || '/forged.jpg', '00000000-0000-0000-0000-00000000bb01'),
  '42501', null, 'a member cannot upload an object owned by somebody else');

-- A malformed key must be REFUSED, not raise: 42501 is the policy saying no,
-- while 22P02 would be a uuid cast blowing up inside it.
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('attachments', 'not-a-uuid/photo.jpg', %L, '{"size":3}'::jsonb)$$,
         '00000000-0000-0000-0000-00000000aa01'),
  '42501', null, 'a malformed key is refused by policy, not by a cast error');
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('attachments', 'loose.jpg', %L, '{"size":3}'::jsonb)$$,
         '00000000-0000-0000-0000-00000000aa01'),
  '42501', null, 'a key with no conversation folder is refused');
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('attachments', %L, %L, '{"size":3}'::jsonb)$$,
         '11111111-2222-3333-4444-555555555555/photo.jpg', '00000000-0000-0000-0000-00000000aa01'),
  '42501', null, 'a member cannot upload into a conversation that does not exist');

-- 4 attachments are immutable ----------------------------------------------
-- No update and no delete policy: an update matches nothing, and a delete is
-- refused outright.
select lives_ok(
  $$update storage.objects set metadata = '{"hacked":true}'::jsonb where bucket_id = 'attachments'$$,
  'an update over the bucket matches nothing rather than erroring');
select is((select count(*) from storage.objects
            where bucket_id = 'attachments' and metadata ? 'hacked'), 0::bigint,
          'no update policy: the uploader cannot rewrite her own object');
select throws_ok(
  $$delete from storage.objects where bucket_id = 'attachments'$$,
  null, null, 'no delete policy: the uploader cannot delete her own object');
select is((select count(*) from storage.objects where bucket_id = 'attachments'), 1::bigint,
          'the object survives the delete attempt');
reset role;

-- A malformed object planted by a service role must not break a member's
-- listing: is_member_of_path is evaluated for every row scanned.
insert into storage.objects(bucket_id, name, owner_id, metadata)
  values ('attachments', 'garbage-key.jpg', '00000000-0000-0000-0000-00000000aa01', '{"size":1}'::jsonb);

-- 5 the other member reads, a non-member does not --------------------------
select test_as('00000000-0000-0000-0000-00000000bb01', 'b7b7b7b7-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
select is((select count(*) from storage.objects where bucket_id = 'attachments'), 1::bigint,
          'the other member reads the attachment');
select lives_ok(
  $$select count(*) from storage.objects where bucket_id = 'attachments'$$,
  'a malformed key already in the bucket does not break a listing');
reset role;

-- dan is allowlisted and ACTIVE, so has_app_access() is true for him: only
-- membership can stop him. This is the fixture that proves that clause.
select test_as('00000000-0000-0000-0000-00000000dd01', 'd7d7d7d7-dddd-dddd-dddd-dddddddddddd');
select is((select count(*) from storage.objects where bucket_id = 'attachments'), 0::bigint,
          'an active non-member reads no attachment');
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('attachments', %L, %L, '{"size":3}'::jsonb)$$,
         (select conv from _fx) || '/intruding.jpg', '00000000-0000-0000-0000-00000000dd01'),
  '42501', null, 'an active non-member cannot upload into the conversation folder');
reset role;

-- cat never reached the allowlist: the app-access gate, independent of any
-- membership he could not have anyway.
select test_as('00000000-0000-0000-0000-00000000cc01', 'c7c7c7c7-cccc-cccc-cccc-cccccccccccc');
select is((select count(*) from storage.objects where bucket_id = 'attachments'), 0::bigint,
          'an unallowlisted user reads no attachment');
reset role;

-- 6 the relaxed body check --------------------------------------------------
select test_as('00000000-0000-0000-0000-00000000aa01', 'a7a7a7a7-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01',
         (select conv from _fx) || '/photo.jpg'),
  'an image with no caption is accepted');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '   ', %L)$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01',
         (select conv from _fx) || '/photo2.jpg'),
  'an image with a whitespace-only caption is accepted');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, 'look at this', %L)$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01',
         (select conv from _fx) || '/photo3.jpg'),
  'an image with a caption is accepted');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body)
           values (%L, %L, 'still just text')$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01'),
  'a text-only message is still accepted');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body)
           values (%L, %L, '')$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01'),
  '23514', null, 'a message with neither text nor attachment is refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '  ', null)$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01'),
  '23514', null, 'whitespace with an explicitly null attachment is still refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, %L, %L)$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01',
         repeat('x', 4001), (select conv from _fx) || '/photo4.jpg'),
  '23514', null, 'an attachment does not lift the caption length limit');

-- 7 the insert grant still excludes the server-assigned columns -------------
-- Adding attachment_path to the column grant is the moment id and created_at
-- get handed back by accident.
select throws_ok(
  format($$insert into public.messages(id, conversation_id, sender_id, body, attachment_path)
           values (gen_random_uuid(), %L, %L, '', %L)$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01',
         (select conv from _fx) || '/photo5.jpg'),
  '42501', null, 'a member still cannot choose the message id');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, created_at)
           values (%L, %L, '', %L, '2000-01-01')$$,
         (select conv from _fx), '00000000-0000-0000-0000-00000000aa01',
         (select conv from _fx) || '/photo6.jpg'),
  '42501', null, 'a member still cannot choose created_at');
reset role;
select set_eq(
  $$select column_name::text from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'messages'
       and grantee = 'authenticated' and privilege_type = 'INSERT'$$,
  $$values ('conversation_id'),('sender_id'),('body'),('attachment_path')$$,
  'authenticated may insert exactly conversation_id, sender_id, body, attachment_path');

-- 8 losing the active session closes the attachment too ---------------------
-- ann is still a member, so membership cannot be what stops her here.
delete from auth.sessions where id = 'a7a7a7a7-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select test_as('00000000-0000-0000-0000-00000000aa01', 'a7a7a7a7-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
select is((select count(*) from storage.objects where bucket_id = 'attachments'), 0::bigint,
          'a revoked session loses the attachment it uploaded');
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('attachments', %L, %L, '{"size":3}'::jsonb)$$,
         (select conv from _fx) || '/after-revoke.jpg', '00000000-0000-0000-0000-00000000aa01'),
  '42501', null, 'a revoked session cannot upload');
reset role;

select * from finish();
rollback;
