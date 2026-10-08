begin;
select plan(31);

-- Video messages (20261014120000_video_messages.sql), written from the contract:
--   messages.attachment_duration_ms: authenticated may insert it, nobody may
--   update it; messages_video_check takes 1..300000 ms, only on a file message
--   whose type is video/*. The thumbnail is the object '<attachment_path>.t'
--   next to the video: attachment_readable lets exactly the video's readers
--   see it, may_remove_attachment lets only its owner remove it, and only once
--   the video message is deleted. Deleting for everyone clears the duration.
--   conversation_previews carries the duration; the push of a video reads
--   '🎥 Video'.
--
-- Each refused insert differs from ann's valid one (the control) by ONE
-- column. Each refused thumbnail delete fails one gate only: the owner's own
-- delete is refused while the video is live; the others are tried after
-- delete_message, so only "not the owner" stands in their way.
--   ann  member of G, sends      bob  member of G, has a phone
--   cat  never a member of G

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000f22' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@videos.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat')) v(n, name);
insert into app_private.allowlist(email)
select name || '@videos.test' from unnest(array['ann','bob','cat']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('f2200000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03']) n;
insert into app_private.tag_finds(finder, found_id) values (u('01'), u('02')), (u('01'), u('03'));

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'f2200000-0000-0000-0000-0000000000' || n)::text, true);
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

-- the path of message [id]'s video in G, and its thumbnail
create function vpath(id uuid) returns text language sql stable as $$
  select g('G') || '/' || id || '/Beach day.mp4'
$$;
create function tpath(id uuid) returns text language sql stable as $$ select vpath(id) || '.t' $$;
grant execute on function vpath(uuid), tpath(uuid) to authenticated, anon;

-- as the current member: upload the video and its thumbnail, then store the
-- message; [with_file] false stores a text message carrying only a duration
create function video_insert(id uuid, mime text, duration text, with_file boolean default true)
returns text language sql as $$
  select try(format($q$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('attachments', %L, %L, '{"size":3}'::jsonb),
                              ('attachments', %L, %L, '{"size":3}'::jsonb)$q$,
                    vpath(id), auth.uid(), tpath(id), auth.uid()))
   where with_file;
  select case when with_file then try(format(
    $q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                   attachment_name, attachment_mime, attachment_size,
                                   attachment_duration_ms)
       values (%L, %L, %L, '', %L, 'Beach day.mp4', %L, 8388608, %s)$q$,
    id, g('G'), auth.uid(), vpath(id), mime, duration))
  else try(format(
    $q$insert into public.messages(id, conversation_id, sender_id, body, attachment_duration_ms)
       values (%L, %L, %L, 'hi', %s)$q$, id, g('G'), auth.uid(), duration)) end
$$;
grant execute on function video_insert(uuid, text, text, boolean) to authenticated;

create function sees(path text) returns bigint language sql stable as $$
  select count(*) from storage.objects where bucket_id = 'attachments' and name = path
$$;
grant execute on function sees(text) to authenticated, anon;
create function removes(path text) returns bigint language plpgsql as $$
declare n bigint;
begin
  with d as (delete from storage.objects where bucket_id = 'attachments' and name = path returning 1)
  select count(*) into n from d;
  return n;
end $$;
grant execute on function removes(text) to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['01','02','03'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('02');
select public.register_device_token('bob-videos-token', 'android');
reset role;

select as_('01');
insert into ids values ('G', public.start_group_conversation('Videos', array[u('02')]));
select commit_check();
reset role;

-- 1 column grants --------------------------------------------------------------
select ok(has_column_privilege('authenticated', 'public.messages', 'attachment_duration_ms', 'INSERT'),
          'authenticated may insert the duration');
select ok(not has_column_privilege('authenticated', 'public.messages', 'attachment_duration_ms', 'UPDATE'),
          'nobody may update it directly');
select ok(not has_column_privilege('anon', 'public.messages', 'attachment_duration_ms', 'INSERT'),
          'anon may not insert it');

-- 2 messages_video_check ---------------------------------------------------------
select as_('01');
select is(video_insert('f2200000-0000-0000-0000-00000000a001', 'video/mp4', '41000'),
          'ok', 'control: a member stores a video message');
select is(video_insert('f2200000-0000-0000-0000-00000000a002', 'video/mp4', '1'),
          'ok', 'control: one millisecond is allowed');
select is(video_insert('f2200000-0000-0000-0000-00000000a003', 'video/mp4', '300000'),
          'ok', 'control: exactly five minutes is allowed');
select is(video_insert('f2200000-0000-0000-0000-00000000b001', 'video/mp4', '0'),
          '23514', 'a zero duration is refused');
select is(video_insert('f2200000-0000-0000-0000-00000000b002', 'video/mp4', '-5'),
          '23514', 'a negative duration is refused');
select is(video_insert('f2200000-0000-0000-0000-00000000b003', 'video/mp4', '300001'),
          '23514', 'one millisecond over five minutes is refused');
select is(video_insert('f2200000-0000-0000-0000-00000000b004', 'application/pdf', '41000'),
          '23514', 'a duration on a pdf is refused');
select is(video_insert('f2200000-0000-0000-0000-00000000b005', 'video/mp4', '41000', false),
          '23514', 'a duration without the file columns is refused');
select is(video_insert('f2200000-0000-0000-0000-00000000a004', 'application/pdf', 'null'),
          'ok', 'control: the same pdf without a duration is stored');
reset role;

-- 3 conversation_previews and the push ---------------------------------------------
-- one transaction shares one now(): age the earlier rows so the next is newest
update public.messages set created_at = now() - interval '1 minute' where conversation_id = g('G');
select as_('01');
select is(video_insert('f2200000-0000-0000-0000-00000000a010', 'video/mp4', '41000'),
          'ok', 'fixture: a video as the newest message');
select is((select attachment_duration_ms from public.conversation_previews where conversation_id = g('G')),
          41000, 'the preview carries the newest video''s duration');
reset role;
select is((select string_agg(body, ',') from app_private.push_targets_for_message(
             'f2200000-0000-0000-0000-00000000a010') where user_id = u('02')),
          E'\U0001F3A5 Video', 'the push of a video message reads the camera and Video');
select is((select string_agg(body, ',') from app_private.push_targets_for_message(
             'f2200000-0000-0000-0000-00000000a004') where user_id = u('02')),
          E'\U0001F4CE Beach day.mp4', 'control: a pdf still pushes the paperclip and its name');

-- 4 who sees the thumbnail ------------------------------------------------------------
select as_('02');
select is(sees(tpath('f2200000-0000-0000-0000-00000000a010')), 1::bigint,
          'a member sees the thumbnail of a video');
select is(sees(vpath('f2200000-0000-0000-0000-00000000a010')), 1::bigint,
          'and the video itself');
select is(sees(tpath('f2200000-0000-0000-0000-00000000a004')), 0::bigint,
          'but not a .t object beside a pdf: only a video has a thumbnail');
reset role;
select as_('03');
select is(sees(tpath('f2200000-0000-0000-0000-00000000a010')), 0::bigint,
          'a non-member does not see the thumbnail');
select is(sees(vpath('f2200000-0000-0000-0000-00000000a010')), 0::bigint,
          'nor the video');
reset role;
set local role anon;
select is(sees(tpath('f2200000-0000-0000-0000-00000000a010')), 0::bigint,
          'anon does not see the thumbnail');
reset role;

-- 5 who removes the thumbnail -----------------------------------------------------------
-- storage refuses a direct delete unless this is set; the policies still apply
select set_config('storage.allow_delete_query', 'true', true);
select as_('01');
select is(removes(tpath('f2200000-0000-0000-0000-00000000a010')), 0::bigint,
          'the owner cannot remove the thumbnail while the video message is live');
select lives_ok($$select public.delete_message('f2200000-0000-0000-0000-00000000a010')$$,
                'the sender deletes the video for everyone');
reset role;
select is((select attachment_duration_ms from public.messages where id = 'f2200000-0000-0000-0000-00000000a010'),
          null::integer, 'deleting for everyone clears the duration');
select as_('03');
select is(removes(tpath('f2200000-0000-0000-0000-00000000a010')), 0::bigint,
          'a non-member cannot remove the thumbnail, even after the delete');
reset role;
select as_('02');
select is(removes(tpath('f2200000-0000-0000-0000-00000000a010')), 0::bigint,
          'a member who does not own it cannot remove it, even after the delete');
reset role;
select is(sees(tpath('f2200000-0000-0000-0000-00000000a010')), 1::bigint,
          'so the thumbnail is still there');
select as_('01');
select is(removes(tpath('f2200000-0000-0000-0000-00000000a010')), 1::bigint,
          'the owner removes the thumbnail once the video message is deleted');
reset role;

-- 6 a revoked member loses the thumbnail ----------------------------------------------------
select as_('02');
select is(sees(tpath('f2200000-0000-0000-0000-00000000a001')), 1::bigint,
          'control: bob sees another video''s thumbnail while allowed');
reset role;
delete from app_private.allowlist where email = 'bob@videos.test';
select as_('02');
select is(sees(tpath('f2200000-0000-0000-0000-00000000a001')), 0::bigint,
          'once revoked, bob sees no thumbnail');
reset role;

select * from finish();
rollback;
