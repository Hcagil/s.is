-- The tiny preview that travels with a photo message: messages_attachment_preview_check
-- and its read path.
--
-- Each shape fixture below is built to fail exactly ONE clause of the check
-- constraint, keeping every other clause satisfied, so deleting any one
-- clause from the migration turns exactly its own fixture green -- proving
-- the clause is load-bearing rather than redundant with a neighbour.
--
-- Read-side fixtures each fail exactly one gate: cat is allowlisted and
-- active but not a member (membership gate only); dee is a member whose
-- session was revoked (has_app_access() only); eve is a member removed from
-- the allowlist (has_app_access() only, the allowlist half); anon holds no
-- grant on the table at all.
begin;
select plan(25);

-- fixtures -------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000009001', 'ap-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-000000009002', 'ap-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-000000009003', 'ap-dee@example.com', now(), '{"full_name":"Dee"}'),
  ('00000000-0000-0000-0000-000000009004', 'ap-eve@example.com', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-000000009005', 'ap-cat@example.com', now(), '{"full_name":"Cat"}');
insert into app_private.allowlist(email) values
  ('ap-ann@example.com'), ('ap-bob@example.com'), ('ap-dee@example.com'),
  ('ap-eve@example.com'), ('ap-cat@example.com');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a7000000-0000-0000-0000-000000009001', '00000000-0000-0000-0000-000000009001', now(), now()),
  ('a7000000-0000-0000-0000-000000009002', '00000000-0000-0000-0000-000000009002', now(), now()),
  ('a7000000-0000-0000-0000-000000009003', '00000000-0000-0000-0000-000000009003', now(), now()),
  ('a7000000-0000-0000-0000-000000009004', '00000000-0000-0000-0000-000000009004', now(), now()),
  ('a7000000-0000-0000-0000-000000009005', '00000000-0000-0000-0000-000000009005', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-000000009001', 'a7000000-0000-0000-0000-000000009001');
select public.activate_session();
select public.start_group_conversation('Preview Group',
  array['00000000-0000-0000-0000-000000009002'::uuid,
        '00000000-0000-0000-0000-000000009003'::uuid,
        '00000000-0000-0000-0000-000000009004'::uuid]);
reset role;
select test_as('00000000-0000-0000-0000-000000009002', 'a7000000-0000-0000-0000-000000009002');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-000000009003', 'a7000000-0000-0000-0000-000000009003');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-000000009004', 'a7000000-0000-0000-0000-000000009004');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-000000009005', 'a7000000-0000-0000-0000-000000009005');
select public.activate_session();
reset role;

-- Captured with RLS bypassed, the way attachments_test.sql does it.
create temp table _fx as
  select c.id as conv from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id
                    and m.user_id = '00000000-0000-0000-0000-000000009001')
     and (select count(*) from public.conversation_members m2
           where m2.conversation_id = c.id) = 4;
grant select on _fx to authenticated, anon;

-- messages_send now also requires the sender to own the storage object at
-- attachment_path (20260924140000_delete_for_everyone.sql), so every photo
-- path exercised below needs a real, ann-owned row in storage.objects first.
insert into storage.objects(bucket_id, name, owner_id, metadata)
  select 'attachments', (select conv from _fx) || '/' || suffix, '00000000-0000-0000-0000-000000009001', '{"size":3}'::jsonb
    from unnest(array['p-ok.png', 'p-null.png', 'p-toolong.png', 'p-mod4.png', 'p-charset.png',
                       'p-pad2.png', 'p-pad3.png', 'p-padmid.png', 'p-sig.png', 'p-name.png']) as suffix;

-- 1 the shape of a valid preview ---------------------------------------------
select test_as('00000000-0000-0000-0000-000000009001', 'a7000000-0000-0000-0000-000000009001');

select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || repeat('A', 4000 - 11))$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-ok.png'),
  'a well-formed preview at exactly the 4000-char cap is accepted');

select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, '', %L)$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-null.png'),
  'a null preview is allowed on a photo message');

select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body)
           values (%L, %L, 'no photo here')$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001'),
  'a null preview is allowed on a text-only message');

-- 2 only with attachment_path -------------------------------------------------
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_preview)
           values (%L, %L, 'no photo', 'iVBORw0KGgo' || repeat('A', 20 - 11))$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001'),
  '23514', null, 'a preview with no attachment_path is refused');

-- 3 length: at most 4000 characters ------------------------------------------
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || repeat('A', 4004 - 11))$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-toolong.png'),
  '23514', null, 'a preview of 4004 characters (still a multiple of 4) is refused');

-- 4 length: a multiple of 4 ---------------------------------------------------
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || repeat('A', 4))$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-mod4.png'),
  '23514', null, 'a preview whose length is not a multiple of 4 is refused');

-- 5 charset: only base64 characters ------------------------------------------
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || 'AA_AA')$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-charset.png'),
  '23514', null, 'a character outside [A-Za-z0-9+/=] is refused');

-- 6 padding: up to two '=', trailing only ------------------------------------
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || repeat('A', 7) || '==')$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-pad2.png'),
  'exactly two trailing "=" is accepted');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || repeat('A', 6) || '===')$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-pad3.png'),
  '23514', null, 'three trailing "=" is refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || 'A=AAAAAAA')$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-padmid.png'),
  '23514', null, '"=" that is not trailing is refused');

-- 7 must be the base64 PNG signature ------------------------------------------
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgp' || repeat('A', 9))$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-sig.png'),
  '23514', null, 'text that is not the PNG signature is refused even if otherwise well-formed');

-- 8 the constraint has the name the migration gives it -----------------------
select throws_like(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'not-base64-at-all!!')$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-name.png'),
  '%messages_attachment_preview_check%',
  'the violation is reported against messages_attachment_preview_check');

-- 9 grants: authenticated may insert it, may update no message, anon nothing -
select is(
  (select attachment_preview from public.messages
    where attachment_path = (select conv from _fx) || '/p-ok.png'),
  'iVBORw0KGgo' || repeat('A', 4000 - 11),
  'the member who sent it reads her own preview back');

select throws_ok(
  format($$update public.messages set attachment_preview = 'iVBORw0KGgo' || repeat('A', 9)
           where attachment_path = %L$$,
         (select conv from _fx) || '/p-ok.png'),
  '42501', null, 'a member cannot update attachment_preview: messages are never edited');
reset role;

set local role anon;
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview)
           values (%L, %L, '', %L, 'iVBORw0KGgo' || repeat('A', 9))$$,
         (select conv from _fx), '00000000-0000-0000-0000-000000009001',
         (select conv from _fx) || '/p-anon.png'),
  '42501', null, 'anon cannot insert a message, preview included');
select throws_ok(
  $$select attachment_preview from public.messages$$,
  '42501', null, 'anon cannot read any preview');
reset role;

select set_eq(
  $$select column_name::text from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'messages'
       and grantee = 'anon'$$,
  $$select null::text where false$$,
  'anon holds no column privilege on messages at all');

-- 10 readable only where the message itself is readable -----------------------
-- ann and bob: full members with an active session -- both read the preview.
select test_as('00000000-0000-0000-0000-000000009001', 'a7000000-0000-0000-0000-000000009001');
select is((select count(*) from public.messages
            where attachment_path = (select conv from _fx) || '/p-ok.png'
              and attachment_preview is not null),
          1::bigint, 'the sender reads the preview');
reset role;
select test_as('00000000-0000-0000-0000-000000009002', 'a7000000-0000-0000-0000-000000009002');
select is((select count(*) from public.messages
            where attachment_path = (select conv from _fx) || '/p-ok.png'
              and attachment_preview is not null),
          1::bigint, 'a fellow member reads the same preview');
reset role;

-- cat: allowlisted and active, but never a member -- membership gate only.
select test_as('00000000-0000-0000-0000-000000009005', 'a7000000-0000-0000-0000-000000009005');
select is((select count(*) from public.messages
            where attachment_path = (select conv from _fx) || '/p-ok.png'),
          0::bigint, 'a non-member reads no row, and so no preview');
reset role;

-- dee: a real member, then her session is revoked -- has_app_access() only.
delete from auth.sessions where id = 'a7000000-0000-0000-0000-000000009003';
select test_as('00000000-0000-0000-0000-000000009003', 'a7000000-0000-0000-0000-000000009003');
select is((select count(*) from public.messages
            where attachment_path = (select conv from _fx) || '/p-ok.png'),
          0::bigint, 'a member whose session was revoked reads no preview');
reset role;

-- eve: a real member, then removed from the allowlist -- has_app_access() only.
delete from app_private.allowlist where email = 'ap-eve@example.com';
select test_as('00000000-0000-0000-0000-000000009004', 'a7000000-0000-0000-0000-000000009004');
select is((select count(*) from public.messages
            where attachment_path = (select conv from _fx) || '/p-ok.png'),
          0::bigint, 'a member removed from the allowlist reads no preview');
reset role;

-- 11 conversation_previews does not expose it ---------------------------------
select hasnt_column('public', 'conversation_previews', 'attachment_preview',
                    'conversation_previews does not carry attachment_preview');

-- 12 push_targets_for_message never carries the preview text ------------------
-- Structural: the function's own body never mentions the column at all, which
-- holds regardless of what the preview or caption happen to contain.
select is(
  position('attachment_preview' in
    pg_get_functiondef('app_private.push_targets_for_message(uuid)'::regprocedure)),
  0, 'push_targets_for_message never references attachment_preview');

-- Behavioural: the notification text for the very message that carries a
-- preview is exactly the caption/photo label, never the preview's own bytes.
select test_as('00000000-0000-0000-0000-000000009002', 'a7000000-0000-0000-0000-000000009002');
select public.register_device_token('ap-bob-device', 'android');
reset role;
select is(
  (select string_agg(body, ',') from app_private.push_targets_for_message(
     (select id from public.messages
       where attachment_path = (select conv from _fx) || '/p-ok.png'))),
  '📷 Photo',
  'the pushed body is the photo label, never the preview payload');

select * from finish();
rollback;
