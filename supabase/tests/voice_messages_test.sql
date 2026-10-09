begin;
select plan(43);

-- Voice messages (20261016120000_voice_messages.sql), written from the contract:
--   messages.attachment_waveform (^[0-9a-f]{1,64}$) and voice_transcript
--   (1..10000 chars) may be inserted, never updated, and only on an audio/mp4
--   message with a duration (messages_voice_check). audio/mp4 lasts
--   1..600000 ms, video 1..300000 ms (messages_duration_check). Deleting for
--   everyone clears both. conversation_previews ends with attachment_mime. The
--   push of a voice message reads the mic and 'Voice message', never the
--   transcript; a non-member never reads the transcript.
-- Each refused insert differs from a valid control by ONE column.
--   ann  member of G, sends      bob  member of G, has a phone
--   cat  never a member of G

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000f33' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@voices.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat')) v(n, name);
insert into app_private.allowlist(email)
select name || '@voices.test' from unnest(array['ann','bob','cat']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('f3300000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03']) n;
insert into app_private.tag_finds(finder, found_id) values (u('01'), u('02')), (u('01'), u('03'));

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'f3300000-0000-0000-0000-0000000000' || n)::text, true);
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

create function vpath(id uuid) returns text language sql stable as $$
  select g('G') || '/' || id || '/Note.m4a'
$$;
grant execute on function vpath(uuid) to authenticated, anon;

-- as the current member: upload the file, then store the message; duration,
-- waveform and transcript are SQL expressions ('null' for none)
create function voice_insert(id uuid, mime text, duration text, waveform text, transcript text)
returns text language sql as $$
  select try(format($q$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('attachments', %L, %L, '{"size":3}'::jsonb)$q$, vpath(id), auth.uid()));
  select try(format(
    $q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                   attachment_name, attachment_mime, attachment_size,
                                   attachment_duration_ms, attachment_waveform, voice_transcript)
       values (%L, %L, %L, '', %L, 'Note.m4a', %L, 9000, %s, %s, %s)$q$,
    id, g('G'), auth.uid(), vpath(id), mime, duration, waveform, transcript))
$$;
grant execute on function voice_insert(uuid, text, text, text, text) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['01','02','03'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('02');
select public.register_device_token('bob-voices-token', 'android');
reset role;

select as_('01');
insert into ids values ('G', public.start_group_conversation('Voices', array[u('02')]));
select commit_check();
reset role;

-- 1 column grants ---------------------------------------------------------------
select ok(has_column_privilege('authenticated', 'public.messages', 'attachment_waveform', 'INSERT'),
          'authenticated may insert the waveform');
select ok(has_column_privilege('authenticated', 'public.messages', 'voice_transcript', 'INSERT'),
          'authenticated may insert the transcript');
select ok(not has_column_privilege('authenticated', 'public.messages', 'attachment_waveform', 'UPDATE'),
          'nobody may update the waveform');
select ok(not has_column_privilege('authenticated', 'public.messages', 'voice_transcript', 'UPDATE'),
          'nobody may update the transcript');
select ok(not has_column_privilege('anon', 'public.messages', 'attachment_waveform', 'INSERT'),
          'anon may not insert the waveform');
select ok(not has_column_privilege('anon', 'public.messages', 'voice_transcript', 'INSERT'),
          'anon may not insert the transcript');

-- 2 the checks --------------------------------------------------------------------
select as_('01');
select is(voice_insert('f3300000-0000-0000-0000-00000000a001', 'audio/mp4', '41000',
          '''0123456789abcdef0123456789abcdef01234567''', '''hello there'''),
          'ok', 'control: a voice message with a waveform and a transcript');
select is(voice_insert('f3300000-0000-0000-0000-00000000a002', 'audio/mp4', '41000', 'null', 'null'),
          'ok', 'control: without waveform and transcript');
select is(voice_insert('f3300000-0000-0000-0000-00000000a003', 'audio/mp4', '600000', 'null', 'null'),
          'ok', 'exactly ten minutes is allowed');
select is(voice_insert('f3300000-0000-0000-0000-00000000b001', 'audio/mp4', '600001', 'null', 'null'),
          '23514', 'one millisecond over ten minutes is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000b002', 'audio/mp4', '0', 'null', 'null'),
          '23514', 'a zero-length voice message is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000a004', 'video/mp4', '300000', 'null', 'null'),
          'ok', 'control: a five-minute video');
select is(voice_insert('f3300000-0000-0000-0000-00000000b003', 'video/mp4', '300001', 'null', 'null'),
          '23514', 'a video keeps its five-minute cap');
select is(voice_insert('f3300000-0000-0000-0000-00000000b004', 'audio/mp4', '41000', '''ABC''', 'null'),
          '23514', 'an uppercase waveform is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000b005', 'audio/mp4', '41000', '''''', 'null'),
          '23514', 'an empty waveform is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000b006', 'audio/mp4', '41000', 'repeat(''a'', 65)', 'null'),
          '23514', 'a 65-digit waveform is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000a005', 'audio/mp4', '41000', 'repeat(''a'', 64)', 'null'),
          'ok', 'a 64-digit waveform is allowed');
select is(voice_insert('f3300000-0000-0000-0000-00000000b007', 'audio/mp4', '41000', '''zz''', 'null'),
          '23514', 'a waveform that is not hex is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000b008', 'audio/mp4', '41000', 'null', ''''''),
          '23514', 'an empty transcript is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000b009', 'audio/mp4', '41000', 'null', 'repeat(''a'', 10001)'),
          '23514', 'a transcript over 10000 characters is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000a006', 'audio/mp4', '41000', 'null', 'repeat(''a'', 10000)'),
          'ok', 'a 10000-character transcript is allowed');
select is(voice_insert('f3300000-0000-0000-0000-00000000b010', 'video/mp4', '41000', '''0f''', 'null'),
          '23514', 'a waveform on a video is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000b011', 'video/mp4', '41000', 'null', '''hi'''),
          '23514', 'a transcript on a video is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000a007', 'audio/mp4', 'null', 'null', 'null'),
          'ok', 'control: an audio/mp4 file without a duration is a plain file');
select is(voice_insert('f3300000-0000-0000-0000-00000000b012', 'audio/mp4', 'null', '''0f''', 'null'),
          '23514', 'a waveform without a duration is refused');
select is(voice_insert('f3300000-0000-0000-0000-00000000b013', 'audio/mp4', 'null', 'null', '''hi'''),
          '23514', 'a transcript without a duration is refused');

-- 3 no updates ------------------------------------------------------------------------
select is(try($$update public.messages set voice_transcript = 'x'
                 where id = 'f3300000-0000-0000-0000-00000000a001'$$),
          '42501', 'the sender cannot rewrite the transcript');
select is(try($$update public.messages set attachment_waveform = 'ff'
                 where id = 'f3300000-0000-0000-0000-00000000a001'$$),
          '42501', 'the sender cannot rewrite the waveform');
reset role;

-- 4 who reads the transcript ------------------------------------------------------------
select as_('02');
select is((select voice_transcript from public.messages where id = 'f3300000-0000-0000-0000-00000000a001'),
          'hello there', 'a member reads the transcript');
select is((select attachment_waveform from public.messages where id = 'f3300000-0000-0000-0000-00000000a001'),
          '0123456789abcdef0123456789abcdef01234567', 'and the waveform');
reset role;
select as_('03');
select is((select count(*) from public.messages where id = 'f3300000-0000-0000-0000-00000000a001'),
          0::bigint, 'a non-member reads no row of it');
reset role;
set local role anon;
select is(try($$select voice_transcript from public.messages
                 where id = 'f3300000-0000-0000-0000-00000000a001'$$),
          '42501', 'anon may not read messages at all');
reset role;

-- 5 previews and the push -----------------------------------------------------------------
update public.messages set created_at = now() - interval '1 minute' where conversation_id = g('G');
select as_('01');
select is(voice_insert('f3300000-0000-0000-0000-00000000a010', 'audio/mp4', '41000',
          '''0123456789abcdef0123456789abcdef01234567''', '''secret words'''),
          'ok', 'fixture: a voice message with a transcript as the newest message');
select is((select attachment_mime from public.conversation_previews where conversation_id = g('G')),
          'audio/mp4', 'the preview carries the newest message''s mime');
reset role;
select is((select attname::text from pg_attribute
            where attrelid = 'public.conversation_previews'::regclass and attnum > 0 and not attisdropped
            order by attnum desc limit 1),
          'attachment_mime', 'conversation_previews ends with attachment_mime');
select is((select string_agg(body, ',') from app_private.push_targets_for_message(
             'f3300000-0000-0000-0000-00000000a010') where user_id = u('02')),
          E'\U0001F3A4 Voice message', 'the push of a voice message reads the mic and Voice message');
select is((select strpos(string_agg(body, ','), 'secret') from app_private.push_targets_for_message(
             'f3300000-0000-0000-0000-00000000a010') where user_id = u('02')),
          0, 'the push never carries the transcript');
select as_('01');
select is(voice_insert('f3300000-0000-0000-0000-00000000a011', 'audio/mp4', 'null', 'null', 'null'),
          'ok', 'fixture: an audio/mp4 file with no length is a plain file');
reset role;
select isnt((select string_agg(body, ',') from app_private.push_targets_for_message(
             'f3300000-0000-0000-0000-00000000a011') where user_id = u('02')),
          E'\U0001F3A4 Voice message', 'an audio/mp4 file without a length is not pushed as a voice message');
select isnt((select string_agg(body, ',') from app_private.push_targets_for_message(
             'f3300000-0000-0000-0000-00000000a011') where user_id = u('02')),
          null, 'the length-less audio file still pushes to the other member');

-- 6 deleting for everyone ---------------------------------------------------------------------
select as_('01');
select lives_ok($$select public.delete_message('f3300000-0000-0000-0000-00000000a010')$$,
                'the sender deletes the voice message for everyone');
reset role;
select is((select attachment_waveform from public.messages where id = 'f3300000-0000-0000-0000-00000000a010'),
          null, 'deleting for everyone clears the waveform');
select is((select voice_transcript from public.messages where id = 'f3300000-0000-0000-0000-00000000a010'),
          null, 'and the transcript');

select * from finish();
rollback;
