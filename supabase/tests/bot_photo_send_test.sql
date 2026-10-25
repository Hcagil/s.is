begin;
select plan(102);

-- The SIS Bot may send a plain single photo into a chat it belongs to.
--
-- Written from the contract (design t_ac9e616e6a, sections 1, 2 and 4), not
-- from the migration:
--   storage attachments_write: the bot inserts into bucket attachments only
--   if app_private.bot_upload_ok(name, mimetype): name is
--   <conversation uuid>/<digits>-<first 8 hex of the bot's uid>.<jpg|jpeg|
--   png|webp|gif>, mimetype is image/jpeg|png|webp|gif, the bot is a current
--   member, and it has made fewer than 10 uploads in 10 min and fewer than 50
--   in 24 h; the membership, app access and owner terms stay. Humans unchanged.
--   messages_bot_rate: a bot message with attachment_path passes only as a
--   plain single photo (every other content column null; poll, contact,
--   sticker_album, forwarded false) whose object the bot owns, with an image
--   mimetype and size <= 10485760; it is charged as one send in the text
--   budget (RLMT2 past 20 in 10 min). Refusal is 42501.
--
-- Each negative fixture fails ONE gate: names differ from a passing name in
-- one part only; objects behind refused messages are valid but for one field.
-- The bot's uid starts with b07ab07a, which no human uid shares, so "wrong
-- uid8" means a real human's prefix.

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then 'b07ab07a-0000-4000-8000-000000000b07'::uuid
              else ('00000000-0000-0000-0000-0000000f07' || n)::uuid end
$$;
create function bot8() returns text language sql immutable as $$ select left(u('bot')::text, 8) $$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@mail.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('04','dan'),('05','eve')) v(n, name);
insert into app_private.allowlist(email)
select name || '@mail.test' from unnest(array['ann','bob','dan','eve']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('f0700000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','04','05']) n;
insert into app_private.tag_finds(finder, found_id) values (u('01'), u('02')), (u('01'), u('05'));
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'bot-photo@sis.test', now(), '{"full_name":"SIS Destek"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('f07b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then 'f07b0000-0000-0000-0000-000000000001'
                         else 'f0700000-0000-0000-0000-0000000000' || n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function runbook() returns void language sql as $$
  select set_config('request.jwt.claims', '', true); select null::void
$$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function group_c(t text, ms uuid[]) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_group_conversation(t, ms); perform commit_check(); return r; end $$;
create function try(q text) returns text language plpgsql as $$
begin execute q; return 'ok';
exception when others then return sqlstate; end $$;
create function rows_changed(q text) returns bigint language plpgsql as $$
declare n bigint;
begin execute q; get diagnostics n = row_count; return n; end $$;

create temp table ids(name text primary key, id uuid);
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
create sequence seq start 1000;
grant usage on sequence seq to authenticated, anon;
-- a name the bot may use: <conv>/<digits>-<bot uid8>.<ext>
create function nm(c uuid, ext text default 'jpg') returns text language sql as $$
  select c || '/' || nextval('seq') || '-' || bot8() || '.' || ext
$$;
-- upload as the current role (auth.uid() as owner), outcome 'ok' or SQLSTATE
create function up(name text, mime text default 'image/jpeg', bucket text default 'attachments',
                   owner text default null) returns text language sql as $$
  select try(format($q$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values (%L, %L, %L, %L::jsonb)$q$,
                    bucket, name, coalesce(owner, auth.uid()::text),
                    case when mime is null then '{"size":3}'
                         else json_build_object('mimetype', mime, 'size', 3)::text end))
$$;
-- an object made by Storage for the bot (postgres), old enough to stay out of
-- the upload-rate windows
create function obj(c uuid, mime text default 'image/jpeg', size bigint default 3,
                    owner uuid default u('bot')) returns text language plpgsql as $$
declare n text := nm(c);
begin
  insert into storage.objects(bucket_id, name, owner_id, metadata, created_at)
  values ('attachments', n, owner::text, json_build_object('mimetype', mime, 'size', size)::jsonb,
          now() - interval '3 days');
  return n;
end $$;
-- a photo message as the current role, with one extra column set
create function psend(path text, col text default null, val text default null) returns text
language sql as $$
  select try(format('insert into public.messages(conversation_id, sender_id, body, attachment_path%s)
                     values (%L, %L, %L, %L%s)',
                    coalesce(', ' || col, ''), split_part(path, '/', 1)::uuid, auth.uid(), '', path,
                    coalesce(', ' || val, '')))
$$;
-- the truth whatever RLS says (definer: the bot cannot read app_private)
create function sends() returns bigint language sql security definer set search_path = '' as $$
  select count(*) from app_private.bot_actions where bot_id = public.u('bot') and kind = 'send'
$$;
-- push every bot upload out of both rate windows
create function age_uploads() returns void language sql as $$
  update storage.objects set created_at = now() - interval '25 hours'
   where bucket_id = 'attachments' and owner_id = u('bot')::text
$$;
grant execute on function u(text), bot8(), as_(text), try(text), rows_changed(text), g(text),
  nm(uuid, text), up(text, text, text, text), sends(), psend(text, text, text), commit_check(),
  group_c(text, uuid[]) to authenticated, anon;
grant select, insert on ids to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['01','02','04','05'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('01');
insert into ids values
  ('DEBUG', group_c('Debug', array[u('02')])),
  ('G2', group_c('no bot here', array[u('05')]));
select public.deliver_release_notes(179);
reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;

-- the bot, bootstrapped as the runbook does it (sis_bot_test.sql)
select runbook();
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('DEBUG'));
insert into app_private.allowlist(email) values ('bot-photo@sis.test');
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
values (g('DEBUG'), u('bot'), 'member', now() - interval '3 days', now() - interval '3 days');
update app_private.bot_accounts set enabled = true where user_id = u('bot');
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('04'));
select as_('bot');
select public.activate_session();
insert into ids values ('LEFT', public.start_direct_conversation(u('04')));
reset role;
-- delisting dan drops the bot out of that 1:1: a chat the bot has left
delete from app_private.bot_contacts where bot_id = u('bot') and contact_id = u('04');
select is((select count(*) from public.conversation_members
            where conversation_id = g('LEFT') and user_id = u('bot') and left_at is null),
          0::bigint, 'fixture: the bot is no longer a current member of LEFT');

-- 1 schema --------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'app_private.bot_upload_ok(text, text)', 'execute'),
          'authenticated may execute bot_upload_ok (the policy runs as the caller)');
select ok(not has_function_privilege('anon', 'app_private.bot_upload_ok(text, text)', 'execute'),
          'anon may not execute bot_upload_ok');
select is((select p.prosecdef and p.proconfig @> array['search_path=""']
             from pg_proc p where p.oid = 'app_private.bot_upload_ok(text, text)'::regprocedure),
          true, 'bot_upload_ok is security definer with an empty search_path');

-- 2 the bot uploads a photo into its chat ---------------------------------------
select as_('bot');
select is(up(nm(g('DEBUG'), 'jpg'), 'image/jpeg'), 'ok', 'bot uploads <conv>/<n>-<uid8>.jpg as image/jpeg');
select is(up(nm(g('DEBUG'), 'jpeg'), 'image/jpeg'), 'ok', '.jpeg as image/jpeg');
select is(up(nm(g('DEBUG'), 'png'), 'image/png'), 'ok', '.png as image/png');
select is(up(nm(g('DEBUG'), 'webp'), 'image/webp'), 'ok', '.webp as image/webp');
select is(up(nm(g('DEBUG'), 'gif'), 'image/gif'), 'ok', '.gif as image/gif');

-- 3 names, types and places it may not use ---------------------------------------
select is(up(nm(g('G2'))), '42501', 'refused: a chat the bot is not a member of');
select is(up(nm(g('LEFT'))), '42501', 'refused: a chat the bot has left');
select is(up(nm(g('SYS'))), '42501', 'refused: a system chat');
select is(up(nm(g('DEBUG'), 'pdf')), '42501', 'refused: extension .pdf');
select is(up(nm(g('DEBUG'), 'jpg.t')), '42501', 'refused: a .t thumbnail');
select is(up(g('DEBUG') || '/' || nextval('seq') || '-' || bot8()), '42501', 'refused: no extension');
select is(up(nm(g('DEBUG'), 'jpg.exe')), '42501', 'refused: .jpg.exe (the extension must end the name)');
select is(up(g('DEBUG') || '/' || nextval('seq') || '-' || left(u('01')::text, 8) || '.jpg'), '42501',
          'refused: a human''s uid8 instead of the bot''s');
select is(up(g('DEBUG') || '/' || nextval('seq') || '-' || left(u('bot')::text, 7) || 'f.jpg'), '42501',
          'refused: a uid8 that differs in the last character');
select is(up(g('DEBUG') || '/sub/' || nextval('seq') || '-' || bot8() || '.jpg'), '42501',
          'refused: an extra folder level');
select is(up(g('DEBUG') || '/x' || nextval('seq') || '-' || bot8() || '.jpg'), '42501',
          'refused: a stamp that is not only digits');
select is(up(g('DEBUG') || '/' || nextval('seq') || bot8() || '.jpg'), '42501',
          'refused: no dash between stamp and uid8');
select is(up('profile/' || nextval('seq') || '-' || bot8() || '.jpg'), '42501',
          'refused: a first folder that is not a conversation');
select is(up(nm(g('DEBUG')), 'image/jpeg', 'avatars'), '42501', 'refused: the avatars bucket');
select is(up(nm(g('DEBUG'), 'png'), 'application/pdf'), '42501', 'refused: a .png name declared application/pdf');
select is(up(nm(g('DEBUG'), 'png'), 'application/octet-stream'), '42501',
          'refused: a .png name declared application/octet-stream');
select is(up(nm(g('DEBUG'), 'png'), 'image/svg+xml'), '42501', 'refused: image/svg+xml');
select is(up(nm(g('DEBUG'), 'png'), null), '42501', 'refused: no declared type');
select is(up(nm(g('DEBUG')), 'image/jpeg', 'attachments', u('01')::text), '42501',
          'refused: an object owned by someone else (owner term kept)');
select is(up(nm(g('DEBUG'), 'jpg')), 'ok', 'control: after all the refusals a valid upload still passes');
reset role;

-- 4 overwrite and delete ----------------------------------------------------------
select as_('01');
select is(up(g('DEBUG') || '/9-' || bot8() || '.jpg'), 'ok', 'fixture: ann uploads under a bot-shaped name');
reset role;
select as_('bot');
select isnt(up(g('DEBUG') || '/9-' || bot8() || '.jpg'), 'ok', 'refused: the bot overwrites ann''s object');
select is(rows_changed(format($$update storage.objects set metadata = '{"mimetype":"image/png","size":4}'
                               where bucket_id = 'attachments' and name = %L$$,
                              g('DEBUG') || '/9-' || bot8() || '.jpg')),
          0::bigint, 'the bot cannot update ann''s object');
select is(rows_changed(format($$update storage.objects set metadata = '{"mimetype":"image/png","size":4}'
                               where bucket_id = 'attachments' and owner_id = %L$$, u('bot'))),
          0::bigint, 'nor its own objects (no update policy: no upsert)');
set local storage.allow_delete_query = 'true';
select is(rows_changed(format($$delete from storage.objects where bucket_id = 'attachments' and name = %L$$,
                              g('DEBUG') || '/9-' || bot8() || '.jpg')),
          0::bigint, 'the bot cannot delete ann''s object');
reset storage.allow_delete_query;
reset role;
select is((select owner_id || ' ' || (metadata->>'mimetype') from storage.objects
            where bucket_id = 'attachments' and name = g('DEBUG') || '/9-' || bot8() || '.jpg'),
          u('01')::text || ' image/jpeg', 'ann''s object is unchanged and still hers');

-- 5 upload rate: 10 in 10 min, 50 in 24 h ------------------------------------------
select age_uploads();
select as_('bot');
select is((select count(*) from generate_series(1, 10) i where up(nm(g('DEBUG'))) = 'ok'), 10::bigint,
          'ten uploads in ten minutes pass');
select is(up(nm(g('DEBUG'))), '42501', 'the 11th upload in ten minutes is refused');
reset role;
select age_uploads();
update storage.objects set created_at = now() - interval '11 minutes'
 where bucket_id = 'attachments' and owner_id = u('bot')::text
   and name in (select name from storage.objects where owner_id = u('bot')::text order by name limit 10);
select as_('bot');
select is(up(nm(g('DEBUG'))), 'ok', 'ten uploads 11 minutes ago leave room in the ten-minute window');
reset role;
select age_uploads();
insert into storage.objects(bucket_id, name, owner_id, metadata, created_at)
select 'attachments', nm(g('DEBUG')), u('bot')::text, '{"mimetype":"image/jpeg","size":3}', now() - interval '23 hours'
  from generate_series(1, 49);
select as_('bot');
select is(up(nm(g('DEBUG'))), 'ok', 'the 50th upload in 24 hours passes');
select is(up(nm(g('DEBUG'))), '42501', 'the 51st upload in 24 hours is refused');
reset role;
select age_uploads();
select as_('bot');
select is(up(nm(g('DEBUG'))), 'ok', 'uploads older than 24 hours do not count');
reset role;
-- humans have no upload rate
select as_('02');
select is((select count(*) from generate_series(1, 12) i where up(nm(g('DEBUG'))) = 'ok'), 12::bigint,
          'a human uploads 12 in a row');
reset role;
select age_uploads();

-- 6 humans unchanged -----------------------------------------------------------------
select as_('01');
select is(up(g('DEBUG') || '/doc.bin', 'application/octet-stream'), 'ok',
          'a human uploads any name with a non-image type');
select is(up(g('DEBUG') || '/nometa.jpg', null), 'ok', 'a human upload without a declared type passes');
select is(up(nm(g('G2'))), 'ok', 'a human uploads into her own chat the bot is not in');
reset role;
select as_('02');
select is(up(nm(g('G2'))), '42501', 'a human still cannot upload into a chat she is not in');
reset role;
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', g('DEBUG') || '/big.jpg', u('01')::text, '{"mimetype":"application/octet-stream","size":20000000}');
select as_('01');
select is(psend(g('DEBUG') || '/big.jpg'), 'ok', 'a human sends a photo row whatever its object''s type and size');
reset role;

-- 7 the bot sends a photo --------------------------------------------------------------
create temp table p(name text primary key, path text);
insert into p values
  ('P1', obj(g('DEBUG'))), ('P2', obj(g('DEBUG'))), ('PMAX', obj(g('DEBUG'), 'image/jpeg', 10485760)),
  ('PPNG', obj(g('DEBUG'), 'image/png')), ('V', obj(g('DEBUG'))),
  ('OCT', obj(g('DEBUG'), 'application/octet-stream')), ('BIG', obj(g('DEBUG'), 'image/jpeg', 10485761)),
  ('ANNS', obj(g('DEBUG'), 'image/jpeg', 3, u('01'))), ('G2O', obj(g('G2'))), ('LEFTO', obj(g('LEFT'))),
  ('SVG', obj(g('DEBUG'), 'image/svg+xml')), ('P3', obj(g('DEBUG')));
insert into storage.objects(bucket_id, name, owner_id, metadata, created_at) values
  ('attachments', g('DEBUG') || '/1-' || bot8() || '.jpg', u('bot')::text, '{"size":3}', now() - interval '3 days');
insert into p values ('NOMIME', g('DEBUG') || '/1-' || bot8() || '.jpg');
create function pp(n text) returns text language sql stable as $$ select path from p where name = n $$;
grant select on p to authenticated;
grant execute on function pp(text) to authenticated;
delete from app_private.bot_actions where bot_id = u('bot');

select as_('bot');
select is(psend(pp('P1')), 'ok', 'the bot sends a plain photo it uploaded');
select is(sends(), 1::bigint, 'and that photo is logged as one send');
select is(psend(pp('PMAX')), 'ok', 'a photo of exactly 10485760 bytes passes');
select is(psend(pp('PPNG')), 'ok', 'an image/png photo passes');
select is(sends(), 3::bigint, 'each photo is one send');

-- 8 only a plain single photo ---------------------------------------------------------------
select is(psend(pp('V'), 'attachment_name', '''a.pdf'''), '42501', 'refused: photo + attachment_name (file)');
select is(psend(pp('V'), 'attachment_mime', '''application/pdf'''), '42501', 'refused: photo + attachment_mime');
select is(psend(pp('V'), 'attachment_size', '3'), '42501', 'refused: photo + attachment_size');
select is(psend(pp('V'), 'attachment_duration_ms', '1000'), '42501', 'refused: photo + attachment_duration_ms (video)');
select is(psend(pp('V'), 'attachment_waveform', '''AAAA'''), '42501', 'refused: photo + attachment_waveform (voice)');
select is(psend(pp('V'), 'voice_transcript', '''words'''), '42501', 'refused: photo + voice_transcript');
select is(psend(pp('V'), 'attachment_preview', '''abc'''), '42501', 'refused: photo + attachment_preview');
select is(psend(pp('V'), 'photo_group', quote_literal(gen_random_uuid())), '42501', 'refused: photo + photo_group (album)');
select is(psend(pp('V'), 'sticker_id', quote_literal(gen_random_uuid())), '42501', 'refused: photo + sticker_id');
select is(psend(pp('V'), 'sticker_album_id', quote_literal(gen_random_uuid())), '42501', 'refused: photo + sticker_album_id');
select is(psend(pp('V'), 'location_lat', '1'), '42501', 'refused: photo + location_lat');
select is(psend(pp('V'), 'location_lng', '1'), '42501', 'refused: photo + location_lng');
select is(psend(pp('V'), 'link_preview', '''{}''::jsonb'), '42501', 'refused: photo + link_preview');
select is(psend(pp('V'), 'ciphertext', '''x'''), '42501', 'refused: photo + ciphertext');
select is(psend(pp('V'), 'olm_type', '1'), '42501', 'refused: photo + olm_type');
select is(psend(pp('V'), 'poll', 'true'), '42501', 'refused: photo + poll');
select is(psend(pp('V'), 'contact', 'true'), '42501', 'refused: photo + contact');
select is(psend(pp('V'), 'sticker_album', 'true'), '42501', 'refused: photo + sticker_album');
select is(psend(pp('V'), 'forwarded', 'true'), '42501', 'refused: photo + forwarded');
select is(sends(), 3::bigint, 'refused photo rows are not logged as sends');

-- 9 the stored object -------------------------------------------------------------------
select is(psend(pp('OCT')), '42501', 'refused: object type application/octet-stream');
select is(psend(pp('SVG')), '42501', 'refused: object type image/svg+xml');
select is(psend(pp('NOMIME')), '42501', 'refused: object with no type');
select is(psend(pp('BIG')), '42501', 'refused: object of 10485761 bytes');
select is(psend(pp('ANNS')), '42501', 'refused: an object owned by a human');
select is(psend(g('DEBUG') || '/' || nextval('seq') || '-' || bot8() || '.jpg'), '42501',
          'refused: a path with no stored object');
select is(psend(pp('G2O')), '42501', 'refused: a chat the bot is not a member of');
select is(psend(pp('LEFTO')), '42501', 'refused: a chat the bot has left');
select is(psend(pp('V')), 'ok', 'control: the same plain row on a valid object passes');
select is(sends(), 4::bigint, 'only the passing photo was logged');
reset role;

-- 9b the trigger alone: a privileged writer (no RLS, no column grants) still
-- cannot store a non-plain bot photo row. Clients cannot set the RPC-only
-- columns at all, so this is the only way to reach those clauses.
create function raw(path text, col text default null, val text default null) returns text
language sql as $$
  select try(format('insert into public.messages(conversation_id, sender_id, body, attachment_path%s)
                     values (%L, %L, %L, %L%s)',
                    coalesce(', ' || col, ''), split_part(path, '/', 1)::uuid, u('bot'), '', path,
                    coalesce(', ' || val, '')))
$$;
insert into p values ('R1', obj(g('DEBUG')));
select is(raw(pp('V'), 'sticker_id', quote_literal(gen_random_uuid())), '42501', 'trigger refuses: photo + sticker_id');
select is(raw(pp('V'), 'sticker_album_id', quote_literal(gen_random_uuid())), '42501', 'trigger refuses: photo + sticker_album_id');
select is(raw(pp('V'), 'location_lat', '1'), '42501', 'trigger refuses: photo + location_lat');
select is(raw(pp('V'), 'location_lng', '1'), '42501', 'trigger refuses: photo + location_lng');
select is(raw(pp('V'), 'poll', 'true'), '42501', 'trigger refuses: photo + poll');
select is(raw(pp('V'), 'contact', 'true'), '42501', 'trigger refuses: photo + contact');
select is(raw(pp('V'), 'sticker_album', 'true'), '42501', 'trigger refuses: photo + sticker_album');
alter table public.messages disable trigger messages_ciphertext_guard;
select is(raw(pp('V'), 'ciphertext', '''x'''), '42501', 'trigger refuses: photo + ciphertext (ciphertext guard off)');
alter table public.messages enable trigger messages_ciphertext_guard;
select is(raw(pp('ANNS')), '42501', 'trigger refuses: an object owned by a human');
select is(raw(pp('R1')), 'ok', 'control: the trigger passes a plain photo row from the same writer');

-- 10 one budget for text and photos ---------------------------------------------------
delete from app_private.bot_actions where bot_id = u('bot');
insert into app_private.bot_actions(bot_id, kind, at)
select u('bot'), 'send', now() - interval '1 minute' from generate_series(1, 18);
select as_('bot');
select lives_ok($$insert into public.messages(conversation_id, sender_id, body) values (g('DEBUG'), u('bot'), 'text 19')$$,
                'the 19th send (text) passes');
select is(psend(pp('P2')), 'ok', 'the 20th send (photo) passes');
select throws_ok(format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
                          values (%L, %L, '', %L)$$, g('DEBUG'), u('bot'), pp('P3')),
                 'RLMT2', null, 'the 21st send, a photo, is refused (RLMT2)');
select throws_ok($$insert into public.messages(conversation_id, sender_id, body) values (g('DEBUG'), u('bot'), 'text 21')$$,
                 'RLMT2', null, 'and so is a text');
select is(sends(), 20::bigint, 'the refused sends left no log row');
reset role;
delete from app_private.bot_actions where bot_id = u('bot');

-- 11 switched off, no access, anon -----------------------------------------------------
delete from app_private.allowlist where email = 'bot-photo@sis.test';
select as_('bot');
select is(up(nm(g('DEBUG'))), '42501', 'refused: upload by the bot without app access (allowlist removed)');
reset role;
insert into app_private.allowlist(email) values ('bot-photo@sis.test');
select as_('bot');
select is(up(nm(g('DEBUG'))), 'ok', 'control: back on the allowlist it uploads');
reset role;
update app_private.bot_accounts set enabled = false where user_id = u('bot');
select as_('bot');
select is(up(nm(g('DEBUG'))), '42501', 'refused: upload by the bot while switched OFF');
select is(psend(pp('P3')), '42501', 'refused: photo send by the bot while switched OFF');
reset role;
update app_private.bot_accounts set enabled = true where user_id = u('bot');
select runbook();
set local role anon;
select is(up(nm(g('DEBUG')), 'image/jpeg', 'attachments', u('bot')::text), '42501', 'refused: anon upload');
reset role;

select * from finish();
rollback;
