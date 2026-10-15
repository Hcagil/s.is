-- Photo albums (20261027120000_photo_albums.sql): messages.photo_group, the
-- uuid shared by photos picked together.
--
-- 1. the column: uuid, nullable; authenticated may insert it, never update it.
-- 2. messages_photo_group_check: a group only on a photo (a stored image, not
--    a file) -- each refusal names that constraint, and each refused row is
--    the same as an accepted control apart from the one thing under test.
-- 3. a group opens no door: anon, a non-member, a member whose session was
--    revoked and a member removed from a group are refused exactly as for a
--    plain photo, each after a control showing the same subject could post.
-- 4. delete_message and edit_message leave the group as it was.
-- 5. no posting with a group into a system chat the member may only read.
-- 6. a non-member reads no grouped row.
begin;
select plan(36);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000fa001', 'pa-ann@sis.test', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000fa002', 'pa-bob@sis.test', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000fa003', 'pa-cat@sis.test', now(), '{"full_name":"Cat"}'),
  ('00000000-0000-0000-0000-0000000fa004', 'pa-dee@sis.test', now(), '{"full_name":"Dee"}'),
  ('00000000-0000-0000-0000-0000000fa005', 'pa-eve@sis.test', now(), '{"full_name":"Eve"}');
insert into app_private.allowlist(email) values
  ('pa-ann@sis.test'), ('pa-bob@sis.test'), ('pa-cat@sis.test'), ('pa-dee@sis.test'), ('pa-eve@sis.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000fa001', '00000000-0000-0000-0000-0000000fa002'),
  ('00000000-0000-0000-0000-0000000fa004', '00000000-0000-0000-0000-0000000fa002');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('fa000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000fa001', now(), now()),
  ('fa000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000fa002', now(), now()),
  ('fa000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000fa003', now(), now()),
  ('fa000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000fa004', now(), now()),
  ('fa000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000fa005', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- 'ok:<rows touched>' or 'err:<sqlstate>:<constraint or message>', without
-- aborting the test transaction; the constraint name shows WHICH check refused.
create or replace function try_exec(stmt text) returns text
language plpgsql security invoker as $$
declare n bigint; c text;
begin
  execute stmt;
  get diagnostics n = row_count;
  return 'ok:' || n;
exception when others then
  get stacked diagnostics c = constraint_name;
  return 'err:' || sqlstate || coalesce(':' || nullif(c, ''), '');
end $$;
grant execute on function try_exec(text) to authenticated, anon;

create function as_ann() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000fa001', 'fa000000-0000-0000-0000-000000000001') $$;
create function as_bob() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000fa002', 'fa000000-0000-0000-0000-000000000002') $$;
create function as_cat() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000fa003', 'fa000000-0000-0000-0000-000000000003') $$;
create function as_dee() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000fa004', 'fa000000-0000-0000-0000-000000000004') $$;
create function as_eve() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000fa005', 'fa000000-0000-0000-0000-000000000005') $$;

select as_ann(); select is(public.activate_session(), true, 'ann is active'); reset role;
select as_bob(); select is(public.activate_session(), true, 'bob is active'); reset role;
select as_cat(); select is(public.activate_session(), true, 'cat is active'); reset role;
select as_dee(); select is(public.activate_session(), true, 'dee is active'); reset role;
select as_eve(); select is(public.activate_session(), true, 'eve is active'); reset role;

select as_ann(); select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000fa002'), null, 'ann starts a chat with bob'); reset role;
select as_dee(); select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000fa002'), null, 'dee starts a chat with bob'); reset role;
-- conv(a, b): the direct conversation between two fixtures.
create function conv(a text, b text) returns uuid language sql stable as $$
  select c.id from public.conversations c
   where exists (select 1 from public.conversation_members m where m.conversation_id = c.id
                    and m.user_id = ('00000000-0000-0000-0000-0000000fa00' || a)::uuid)
     and exists (select 1 from public.conversation_members m where m.conversation_id = c.id
                    and m.user_id = ('00000000-0000-0000-0000-0000000fa00' || b)::uuid)
   limit 1 $$;
alter function conv(text, text) security definer;
grant execute on function conv(text, text) to authenticated, anon;

-- put(path): the stored object the app uploads before it inserts the row, owned
-- by the caller. Made here with full rights, so a refusal below is the
-- message insert's own and never the storage policy's.
create function put(path text) returns text language sql security definer as $$
  insert into storage.objects(bucket_id, name, owner_id, metadata)
  values ('attachments', path, auth.uid(), '{"size":3}'::jsonb);
  select path $$;
grant execute on function put(text) to authenticated, anon;

-- a group ann runs with eve in it (eve is removed in section 3)
insert into public.conversations(id, title) values ('fa0c0000-0000-0000-0000-000000000001', 'Album group');
insert into public.conversation_members(conversation_id, user_id, role) values
  ('fa0c0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000fa001', 'admin'),
  ('fa0c0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000fa005', 'member');

-- photo(id, conv, group, body): the caller's photo insert, as the app makes it
-- (its object stored first).
create function photo(id text, c uuid, g text, body text default '') returns text language sql as $$
  select put(c || '/' || id || '.jpg');
  select format($q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path, photo_group)
                   values (%L, %L, auth.uid(), %L, %L, %L)$q$,
                id, c, body, c || '/' || id || '.jpg', g) $$;
grant execute on function photo(text, uuid, text, text) to authenticated, anon;

-- 1 the column -----------------------------------------------------------------
select col_type_is('public', 'messages', 'photo_group', 'uuid', 'photo_group is a uuid');
select col_is_null('public', 'messages', 'photo_group', 'photo_group is nullable (a single photo has none)');
select ok(has_column_privilege('authenticated', 'public.messages', 'photo_group', 'INSERT'),
          'authenticated may insert photo_group');
select ok(not has_column_privilege('authenticated', 'public.messages', 'photo_group', 'UPDATE'),
          'authenticated may not update photo_group');

-- 2 the check: a group only on a photo -------------------------------------------
select as_ann();
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000001', conv('1', '2'),
                         'a1b00000-0000-0000-0000-000000000001', 'beach')),
          'ok:1', 'ann sends photo 1 of an album, with the caption');
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000002', conv('1', '2'),
                         'a1b00000-0000-0000-0000-000000000001')),
          'ok:1', 'and photo 2 with the same group');
-- a file: the control row passes without a group, the same row with one does not
select is(try_exec(format($$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                                         attachment_name, attachment_mime, attachment_size)
                            values ('fa0e0000-0000-0000-0000-000000000003', %L, auth.uid(), '', %L,
                                    'notes.pdf', 'application/pdf', 3)$$,
                          conv('1', '2'), put(conv('1', '2') || '/fa0e0000-0000-0000-0000-000000000003/notes.pdf'))),
          'ok:1', 'control: a file message without a group is accepted');
select is(try_exec(format($$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                                         attachment_name, attachment_mime, attachment_size, photo_group)
                            values ('fa0e0000-0000-0000-0000-000000000004', %L, auth.uid(), '', %L,
                                    'notes.pdf', 'application/pdf', 3, 'a1b00000-0000-0000-0000-000000000001')$$,
                          conv('1', '2'), put(conv('1', '2') || '/fa0e0000-0000-0000-0000-000000000004/notes.pdf'))),
          'err:23514:messages_photo_group_check', 'the same file message with a group is refused by the group check');
select is(try_exec(format($$insert into public.messages(conversation_id, sender_id, body, photo_group)
                            values (%L, auth.uid(), 'just words', 'a1b00000-0000-0000-0000-000000000001')$$,
                          conv('1', '2'))),
          'err:23514:messages_photo_group_check', 'a text message with a group is refused by the group check');
reset role;

-- write-once: the sender cannot move a photo to another group, or out of one
select as_ann();
select is(try_exec($$update public.messages set photo_group = 'a1b00000-0000-0000-0000-000000000009'
                      where id = 'fa0e0000-0000-0000-0000-000000000001'$$),
          'err:42501', 'the sender cannot change photo_group');
select is(try_exec($$update public.messages set photo_group = null
                      where id = 'fa0e0000-0000-0000-0000-000000000002'$$),
          'err:42501', 'nor clear it');
reset role;
select is((select count(*) from public.messages
            where photo_group = 'a1b00000-0000-0000-0000-000000000001'), 2::bigint,
          'both album photos still carry the group');

-- 3 a group opens no door ----------------------------------------------------------
set local role anon;
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000010', conv('1', '2'),
                         'a1b00000-0000-0000-0000-000000000002')),
          'err:42501', 'anon cannot send a grouped photo');
reset role;

-- cat is active and allowed, she is only not a member
select as_cat();
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000011', conv('1', '2'),
                         'a1b00000-0000-0000-0000-000000000002')),
          'err:42501', 'an active non-member cannot send a grouped photo');
reset role;

-- dee: a member, her session then revoked (fails only the app-access gate)
select as_dee();
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000012', conv('4', '2'),
                         'a1b00000-0000-0000-0000-000000000003')),
          'ok:1', 'control: dee sends a grouped photo into her chat with bob');
reset role;
delete from auth.sessions where id = 'fa000000-0000-0000-0000-000000000004';
select as_dee();
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000013', conv('4', '2'),
                         'a1b00000-0000-0000-0000-000000000003')),
          'err:42501', 'after her session is revoked dee cannot add to the album');
reset role;

-- eve: a group member, then removed by ann (fails only membership)
select as_eve();
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000014', 'fa0c0000-0000-0000-0000-000000000001',
                         'a1b00000-0000-0000-0000-000000000004')),
          'ok:1', 'control: eve sends a grouped photo into the group');
reset role;
select as_ann();
select lives_ok($$select public.remove_member('fa0c0000-0000-0000-0000-000000000001',
                                              '00000000-0000-0000-0000-0000000fa005')$$,
                'ann removes eve');
reset role;
select as_eve();
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000015', 'fa0c0000-0000-0000-0000-000000000001',
                         'a1b00000-0000-0000-0000-000000000004')),
          'err:42501', 'removed, eve cannot add to the album');
reset role;

-- 4 delete_message and edit_message keep the group -----------------------------------
select as_ann();
select lives_ok($$select public.edit_message('fa0e0000-0000-0000-0000-000000000001', 'beach, fixed')$$,
                'ann edits the album caption');
reset role;
select is((select row(body, photo_group)::text from public.messages
            where id = 'fa0e0000-0000-0000-0000-000000000001'),
          '("beach, fixed",a1b00000-0000-0000-0000-000000000001)', 'the edit changed the caption, not the group');
select as_ann();
select lives_ok($$select public.delete_message('fa0e0000-0000-0000-0000-000000000002')$$,
                'ann deletes album photo 2 for everyone');
reset role;
select is((select photo_group from public.messages where id = 'fa0e0000-0000-0000-0000-000000000002'),
          'a1b00000-0000-0000-0000-000000000001'::uuid, 'the deleted photo keeps its group');
select ok((select attachment_path is null from public.messages where id = 'fa0e0000-0000-0000-0000-000000000002'),
          'control: the delete did take the image away (the check''s deleted branch is what lets it stay)');
select is((select photo_group from public.messages where id = 'fa0e0000-0000-0000-0000-000000000001'),
          'a1b00000-0000-0000-0000-000000000001'::uuid, 'the other album photo is untouched');

-- 5 the system chat, read-only to its member ---------------------------------------------
insert into public.conversations(id, system, direct_key)
  values ('fa0c0000-0000-0000-0000-000000000005', true, 'system:00000000-0000-0000-0000-0000000fa001');
insert into public.conversation_members(conversation_id, user_id) values
  ('fa0c0000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000fa001');
select as_ann();
select is((select count(*) from public.conversations where id = 'fa0c0000-0000-0000-0000-000000000005'),
          1::bigint, 'control: ann is a member of her system chat and sees it');
select is(try_exec(photo('fa0e0000-0000-0000-0000-000000000016', 'fa0c0000-0000-0000-0000-000000000005',
                         'a1b00000-0000-0000-0000-000000000005')),
          'err:42501', 'a grouped photo into the read-only system chat is refused');
reset role;

-- 6 reading ----------------------------------------------------------------------------
select as_bob();
select is((select count(*) from public.messages where photo_group = 'a1b00000-0000-0000-0000-000000000001'),
          2::bigint, 'control: bob, a member, reads both album rows');
reset role;
select as_cat();
select is((select count(*) from public.messages where photo_group is not null), 0::bigint,
          'cat, a non-member, reads no grouped row');
reset role;

select * from finish();
rollback;
