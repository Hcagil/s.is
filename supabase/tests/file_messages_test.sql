begin;
select plan(33);

-- File messages (20261013120000_file_messages.sql), written from the contract:
--   messages.attachment_name / attachment_mime / attachment_size: authenticated
--   may insert them (column grants); a check constraint takes all three or
--   none, needs attachment_path with them, a name of 1..255 characters with no
--   control, zero-width or direction-changing characters (U+200B-U+200F,
--   U+202A-U+202E, U+2066-U+2069), a type/subtype MIME, and a size of
--   1..52428800 bytes. The messages_file_guard trigger nulls the file columns
--   when a message is deleted for everyone and refuses a caption edit on a
--   file message (42501). conversation_previews carries attachment_name. The
--   push body of a file message is the paperclip and the name. Storage stays
--   members-only by path.
--
-- Each refused insert differs from ann's valid one (the control) by ONE
-- column, so it fails exactly the clause under test.
--   ann  member of G, sends      bob  member of G, has a phone
--   cat  never a member of G

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000f11' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@files.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat')) v(n, name);
insert into app_private.allowlist(email)
select name || '@files.test' from unnest(array['ann','bob','cat']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('f1100000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03']) n;
insert into app_private.tag_finds(finder, found_id) values (u('01'), u('02')), (u('01'), u('03'));

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'f1100000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
grant execute on function u(text), as_(text), commit_check(), try(text) to authenticated, anon;

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

-- insert as the current member: a file message with one column overridable
create function file_insert(id uuid, name text, mime text, size bigint,
                            path_suffix text default null, with_path boolean default true)
returns text language sql as $$
  -- the object first, as the app uploads before it stores the message (the
  -- send policy asks that the sender owns it)
  select try(format($q$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('attachments', %L, %L, '{"size":3}'::jsonb)$q$,
                    g('G') || '/' || id || '/' || coalesce(path_suffix, 'f.bin'), auth.uid()))
   where with_path;
  select try(format(
    $q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                   attachment_name, attachment_mime, attachment_size)
       values (%L, %L, %L, '', %L, %L, %L, %s)$q$,
    id, g('G'), auth.uid(),
    case when with_path then g('G') || '/' || id || '/' || coalesce(path_suffix, 'f.bin') end,
    name, mime, coalesce(size::text, 'null')))
$$;
grant execute on function file_insert(uuid, text, text, bigint, text, boolean) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['01','02','03'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('02');
select public.register_device_token('bob-files-token', 'android');
reset role;

select as_('01');
insert into ids values ('G', public.start_group_conversation('Files', array[u('02')]));
select commit_check();
reset role;

-- 1 column grants --------------------------------------------------------------
select ok((select bool_and(has_column_privilege('authenticated', 'public.messages', c, 'INSERT'))
             from unnest(array['attachment_name', 'attachment_mime', 'attachment_size']) c),
          'authenticated may insert the three file columns');
select ok(not (select bool_or(has_column_privilege('authenticated', 'public.messages', c, 'UPDATE'))
                 from unnest(array['attachment_name', 'attachment_mime', 'attachment_size']) c),
          'nobody may update them directly');

-- 2 the check constraint --------------------------------------------------------
select as_('01');
select is(file_insert('f1100000-0000-0000-0000-00000000a001', 'Cabin booking.pdf', 'application/pdf', 2516582),
          'ok', 'control: a member stores a file message');
select is(file_insert('f1100000-0000-0000-0000-00000000a002', 'Max.bin', 'application/octet-stream', 52428800),
          'ok', 'control: exactly 50 MiB is allowed');
select is(file_insert('f1100000-0000-0000-0000-00000000a003', 'One.bin', 'application/octet-stream', 1),
          'ok', 'control: one byte is allowed');
select is(file_insert('f1100000-0000-0000-0000-00000000a004', repeat('n', 255), 'text/plain', 10),
          'ok', 'control: a 255-character name is allowed');
select is(file_insert('f1100000-0000-0000-0000-00000000b001', 'Big.bin', 'application/octet-stream', 52428801),
          '23514', 'one byte over 50 MiB is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b002', 'Empty.bin', 'application/octet-stream', 0),
          '23514', 'an empty file is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b003', '', 'text/plain', 10),
          '23514', 'an empty name is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b004', repeat('n', 256), 'text/plain', 10),
          '23514', 'a 256-character name is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b005', E'line\nbreak.txt', 'text/plain', 10),
          '23514', 'a control character in the name is refused');
select is((select string_agg(distinct r, ',') from (
             select file_insert(('f1100000-0000-0000-0000-0000000c' || lpad(to_hex(c), 4, '0'))::uuid,
                                'invoice' || chr(c) || 'fdp.exe', 'application/octet-stream', 10) r
               from (select generate_series(8203, 8207) c
                     union all select generate_series(8234, 8238)
                     union all select generate_series(8294, 8297)) cs) x),
          '23514', 'every zero-width and direction-changing character in the name is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b006', 'x.pdf', 'pdf', 10),
          '23514', 'a MIME type without a subtype is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b007', 'x.pdf', 'application/ pdf', 10),
          '23514', 'a MIME type with a space is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b008', 'x.pdf', 'application/pdf/x', 10),
          '23514', 'a MIME type with two slashes is refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b009', 'x.pdf', null, 10),
          '23514', 'a name and size without a type are refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b00a', 'x.pdf', 'application/pdf', null),
          '23514', 'a name and type without a size are refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b00b', null, 'application/pdf', 10),
          '23514', 'a type and size without a name are refused');
select is(file_insert('f1100000-0000-0000-0000-00000000b00c', 'x.pdf', 'application/pdf', 10, null, false),
          '23514', 'file columns without an attachment path are refused');
reset role;

-- 3 conversation_previews ----------------------------------------------------------
select is((select attname::text from pg_attribute
            where attrelid = 'public.conversation_previews'::regclass and attnum > 0 and not attisdropped
            order by attnum desc limit 1 offset 1),
          'attachment_name', 'conversation_previews keeps attachment_name just before the video duration');
-- one transaction shares one now(): age the earlier rows so the next is newest
update public.messages set created_at = now() - interval '1 minute' where conversation_id = g('G');
select as_('01');
select is(file_insert('f1100000-0000-0000-0000-00000000a010', 'Menu.xlsx',
                      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 86016),
          'ok', 'fixture: a file as the newest message');
select is((select attachment_name from public.conversation_previews where conversation_id = g('G')),
          'Menu.xlsx', 'the preview carries the newest file''s name');
reset role;

-- 4 the push body ---------------------------------------------------------------------
select is((select string_agg(body, ',') from app_private.push_targets_for_message(
             'f1100000-0000-0000-0000-00000000a010') where user_id = u('02')),
          E'\U0001F4CE Menu.xlsx', 'the push of a file message reads the paperclip and the name');

-- 5 the guard trigger ------------------------------------------------------------------
select as_('01');
select throws_ok($$select public.edit_message('f1100000-0000-0000-0000-00000000a010', 'a caption')$$,
                 '42501', null, 'a caption edit on a file message is refused');
select is((select body from public.messages where id = 'f1100000-0000-0000-0000-00000000a010'),
          '', 'and the body is unchanged');
select is(try(format($$insert into public.messages(id, conversation_id, sender_id, body)
                      values ('f1100000-0000-0000-0000-00000000a020', %L, %L, 'plain')$$, g('G'), u('01'))),
          'ok', 'fixture: a text message');
select lives_ok($$select public.edit_message('f1100000-0000-0000-0000-00000000a020', 'plain, edited')$$,
                'control: a text message still edits');
select lives_ok($$select public.delete_message('f1100000-0000-0000-0000-00000000a001')$$,
                'the sender deletes a file message for everyone');
reset role;
select is((select row(attachment_name, attachment_mime, attachment_size)::text from public.messages
            where id = 'f1100000-0000-0000-0000-00000000a001'),
          '(,,)', 'deleting for everyone nulls the name, type and size');

-- 6 storage stays members-only by path -------------------------------------------------
select as_('02');
select is((select count(*) from storage.objects
            where bucket_id = 'attachments' and name = g('G') || '/f1100000-0000-0000-0000-00000000a010/f.bin'),
          1::bigint, 'a member sees the file object');
reset role;
select as_('03');
select is((select count(*) from storage.objects
            where bucket_id = 'attachments' and name like g('G') || '/%'),
          0::bigint, 'a non-member sees nothing under the conversation');
select is(try(format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
                      values ('attachments', %L, %L, '{"size":3}'::jsonb)$$,
                     g('G') || '/f1100000-0000-0000-0000-00000000a099/f.bin', u('03'))),
          '42501', 'a non-member cannot upload into the conversation');
select is(file_insert('f1100000-0000-0000-0000-00000000a030', 'x.pdf', 'application/pdf', 10),
          '42501', 'a non-member cannot store a file message there');
reset role;

select * from finish();
rollback;
