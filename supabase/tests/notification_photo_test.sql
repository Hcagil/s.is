begin;
select plan(42);

-- The picture in a notification (20261020120000_notification_photo.sql),
-- written from the contract, not the migration:
--   push_targets_for_message / public.push_targets carry thumb_path and
--   thumb_video. thumb_path = '<attachment_path>.t', only when the recipient's
--   preview is 'full', the message has an attachment, no sticker, and it is a
--   photo or a video with a duration; thumb_video says which. Muted and
--   archived recipients still get no row at all.
--   attachment_readable now lets a photo's readers read its '.t' too (the
--   forwarder copies it), and nobody else.
--
-- Each "no picture" fixture fails exactly ONE of those clauses:
--   sen, non   preview sender / none        (the preview clause only)
--   video0     a video without a duration   (the duration clause only)
--   voice      audio with a duration        (the photo-or-video clause only)
--   pdf        a file, not a photo          (the photo-or-video clause only)
--   text       no attachment                (the attachment clause only)
--   sticker    impossible with an attachment (messages_sticker_check), shown below
-- Storage readers: bob member (yes), cat allowlisted+active non-member (the
-- membership gate only), anon (no grant), bob once revoked (has_app_access only).
--   ann 01 sends   bob 02 full   cat 03 never a member   sen 04 preview sender
--   non 05 preview none   mut 06 mutes G   arc 07 archives G

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000f33' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@notifphoto.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','sen'),('05','non'),('06','mut'),('07','arc')) v(n, name);
insert into app_private.allowlist(email)
select name || '@notifphoto.test' from unnest(array['ann','bob','cat','sen','non','mut','arc']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('f3300000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','07']) n;
insert into app_private.tag_finds(finder, found_id)
select u('01'), u(n) from unnest(array['02','03','04','05','06','07']) n;

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
grant select, insert on ids to authenticated, anon, service_role;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon, service_role;

-- message [k]'s original, and its small picture
create function opath(k text) returns text language sql stable as $$
  select g('G') || '/' || g(k) || '/' ||
    case k when 'video' then 'clip.mp4' when 'video0' then 'clip.mp4'
           when 'voice' then 'voice.m4a' when 'pdf' then 'doc.pdf' else 'pic.jpg' end
$$;
create function tpath(k text) returns text language sql stable as $$ select opath(k) || '.t' $$;
grant execute on function opath(text), tpath(text) to authenticated, anon, service_role;

-- as the current member: upload the original and its .t, then store message [k]
create function send(k text) returns text language plpgsql as $$
declare r text;
begin
  if k <> 'text' then
    r := try(format($q$insert into storage.objects(bucket_id, name, owner_id, metadata)
                      values ('attachments', %L, %L, '{"size":3}'::jsonb),
                             ('attachments', %L, %L, '{"size":3}'::jsonb)$q$,
                    opath(k), auth.uid(), tpath(k), auth.uid()));
    if r <> 'ok' then return 'upload ' || r; end if;
  end if;
  return try(case k
    when 'text' then format($q$insert into public.messages(id, conversation_id, sender_id, body)
                               values (%L, %L, %L, 'just words')$q$, g(k), g('G'), auth.uid())
    when 'photo' then format($q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path)
                                values (%L, %L, %L, '', %L)$q$, g(k), g('G'), auth.uid(), opath(k))
    else format($q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                               attachment_name, attachment_mime, attachment_size,
                                               attachment_duration_ms)
                   values (%L, %L, %L, '', %L, %L, %L, 1000, %s)$q$,
                g(k), g('G'), auth.uid(), opath(k),
                case k when 'voice' then 'voice.m4a' when 'pdf' then 'doc.pdf' else 'clip.mp4' end,
                case k when 'voice' then 'audio/mp4' when 'pdf' then 'application/pdf' else 'video/mp4' end,
                case k when 'video' then '41000' when 'voice' then '5000' else 'null' end) end);
end $$;
grant execute on function send(text) to authenticated;

create function sees(path text) returns bigint language sql stable as $$
  select count(*) from storage.objects where bucket_id = 'attachments' and name = path
$$;
grant execute on function sees(text) to authenticated, anon;

-- what recipient [n] is told about message [k]: '<path>|<video>', '<null>'
-- (a row, no picture; thumb_video then carries no meaning), or '<no row>'
create function thumb(k text, n text) returns text language sql stable as $$
  select coalesce(string_agg(coalesce(thumb_path || '|' || thumb_video, '<null>'), ','), '<no row>')
    from app_private.push_targets_for_message(g(k)) where user_id = u(n)
$$;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07'] loop
    perform as_(n); perform public.activate_session();
    if n <> '01' and n <> '03' then
      perform public.register_device_token('notifphoto-token-' || n, 'android', true);
    end if;
    execute 'reset role';
  end loop;
end $$;

insert into ids values
  ('photo',  'f3300000-0000-0000-0000-00000000a001'),
  ('video',  'f3300000-0000-0000-0000-00000000a002'),
  ('video0', 'f3300000-0000-0000-0000-00000000a003'),
  ('voice',  'f3300000-0000-0000-0000-00000000a004'),
  ('pdf',    'f3300000-0000-0000-0000-00000000a005'),
  ('text',   'f3300000-0000-0000-0000-00000000a006');

select as_('01');
insert into ids values ('G', public.start_group_conversation('Pictures',
  array[u('02'), u('04'), u('05'), u('06'), u('07')]));
select commit_check();
reset role;

select as_('04');
insert into public.notification_settings(preview) values ('sender');
reset role;
select as_('05');
insert into public.notification_settings(preview) values ('none');
reset role;
select as_('06');
select is(try(format($q$insert into public.notification_mutes(kind, target) values ('conversation', %L)$q$, g('G'))),
          'ok', 'fixture: mut mutes G');
reset role;
select as_('07');
select is(try(format($q$insert into public.chat_archives(conversation_id) values (%L)$q$, g('G'))),
          'ok', 'fixture: arc archives G');
reset role;

select as_('01');
select is(send('photo'), 'ok', 'fixture: ann sends a photo and its .t');
select is(send('video'), 'ok', 'fixture: a video with a duration and its .t');
select is(send('video0'), 'ok', 'fixture: a video without a duration');
select is(send('voice'), 'ok', 'fixture: a voice message (audio with a duration)');
select is(send('pdf'), 'ok', 'fixture: a pdf');
select is(send('text'), 'ok', 'fixture: a text message');
reset role;

-- 1 the columns ----------------------------------------------------------------
select is((select pg_get_function_result('public.push_targets(uuid)'::regprocedure) ~ 'thumb_path text, thumb_video boolean'),
          true, 'public.push_targets returns thumb_path text and thumb_video boolean');
select is((select pg_get_function_result('app_private.push_targets_for_message(uuid)'::regprocedure)
             ~ 'thumb_path text, thumb_video boolean'),
          true, 'and so does push_targets_for_message');
select function_privs_are('public', 'push_targets', array['uuid'], 'authenticated', '{}'::text[],
                          'a member still cannot call public.push_targets');
select function_privs_are('public', 'push_targets', array['uuid'], 'anon', '{}'::text[],
                          'nor anon');
select function_privs_are('public', 'push_targets', array['uuid'], 'service_role', '{EXECUTE}'::text[],
                          'service_role still can');

-- 2 who is told about which picture -------------------------------------------------
select is(thumb('photo', '02'), tpath('photo') || '|false',
          'full preview, a photo: the picture is <path>.t and it is not a video');
select is(thumb('video', '02'), tpath('video') || '|true',
          'full preview, a video with a duration: <path>.t, marked video');
select is(thumb('photo', '04'), '<null>', 'preview sender: a row, but no picture');
select is(thumb('video', '04'), '<null>', 'preview sender: no video picture either');
select is(thumb('photo', '05'), '<null>', 'preview none: a row, but no picture');
select is(thumb('video', '05'), '<null>', 'preview none: no video picture either');
select is(thumb('video0', '02'), '<null>', 'a video without a duration has no picture');
select is(thumb('voice', '02'), '<null>', 'a voice message (audio with a duration) has no picture');
select is(thumb('pdf', '02'), '<null>', 'a file has no picture');
select is(thumb('text', '02'), '<null>', 'a text message has no picture');
select is(thumb('photo', '06'), '<no row>', 'a muted chat: no row at all for a photo');
select is(thumb('video', '06'), '<no row>', 'nor for a video');
select is(thumb('photo', '07'), '<no row>', 'an archived chat: no row at all for a photo');
select is(thumb('video', '07'), '<no row>', 'nor for a video');
select is(thumb('photo', '01'), '<no row>', 'the sender is never told about his own picture');
-- A sticker cannot carry an attachment, so it can never carry a picture.
select is(try(format('update public.messages set sticker_id = gen_random_uuid() where id = %L', g('photo'))),
          '23514', 'a sticker with an attachment is impossible (messages_sticker_check)');

-- public.push_targets carries the same, for the service role
set local role service_role;
create temp table _claimed as
  select user_id, thumb_path, thumb_video from public.push_targets(g('video'));
reset role;
select is((select thumb_path || '|' || thumb_video from _claimed where user_id = u('02')),
          tpath('video') || '|true', 'public.push_targets returns the video''s picture for bob');
select is((select count(*) from _claimed where user_id = u('04') and thumb_path is null),
          1::bigint, 'and none for sen (preview sender)');
select is((select count(*) from _claimed where user_id in (u('06'), u('07'))), 0::bigint,
          'and no row for the muted or the archived member');

-- 3 who reads the picture in storage ----------------------------------------------
select as_('02');
select is(sees(tpath('photo')), 1::bigint, 'a member reads a photo''s .t');
select is(sees(opath('photo')), 1::bigint, 'control: and the photo');
select is(sees(tpath('video')), 1::bigint, 'and a video''s .t, as before');
select is(sees(tpath('pdf')), 0::bigint, 'but not a .t beside a pdf');
reset role;
select as_('03');
select is(sees(opath('photo')), 0::bigint, 'control: a non-member cannot read the photo');
select is(sees(tpath('photo')), 0::bigint, 'nor its .t: photo pictures widen nothing to non-members');
select is(sees(tpath('video')), 0::bigint, 'nor a video''s .t');
reset role;
set local role anon;
select is(sees(tpath('photo')), 0::bigint, 'anon cannot read a photo''s .t');
reset role;
delete from app_private.allowlist where email = 'bob@notifphoto.test';
select as_('02');
select is(sees(tpath('photo')), 0::bigint, 'once revoked, bob cannot read a photo''s .t');
reset role;
select as_('04');
select is(sees(tpath('photo')), 1::bigint,
          'a member whose preview is sender still reads it in the app: the setting is about pushes only');
reset role;

select * from finish();
rollback;
