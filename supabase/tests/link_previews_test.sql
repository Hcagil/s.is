-- Link preview cards (20261019120000_link_previews.sql): the private
-- link-previews bucket and its two policies, and the guard on
-- messages.link_preview.
--
-- Tests marked TARGET encode the security gate's fix list
-- (link_cards_fixes_after_qa: H1 read only through a readable live message
-- naming the picture, M1 exact `<conv>/<message id>.jpg` owned by the sender,
-- L1 control/invisible characters, L2 the card url appears in the body).
--
-- Negative fixtures fail ONE clause each: `dan` is allowlisted and ACTIVE, so
-- only membership can stop him at the bucket; every rejected card below is a
-- valid card with exactly one field broken, sent by a member on a plain text
-- message, so only the rule under test can refuse it.
begin;
select plan(88);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000a1f01', 'lp-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000a1f02', 'lp-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000a1f03', 'lp-dan@example.com', now(), '{"full_name":"Dan"}');
insert into app_private.allowlist(email) values
  ('lp-ann@example.com'), ('lp-bob@example.com'), ('lp-dan@example.com');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000a1f01', '00000000-0000-0000-0000-0000000a1f02');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a1f00000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000a1f01', now(), now()),
  ('a1f00000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000a1f02', now(), now()),
  ('a1f00000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000a1f03', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-0000000a1f02', 'a1f00000-0000-0000-0000-000000000002');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000a1f03', 'a1f00000-0000-0000-0000-000000000003');
select public.activate_session();
reset role;
select test_as('00000000-0000-0000-0000-0000000a1f01', 'a1f00000-0000-0000-0000-000000000001');
select public.activate_session();
select public.start_direct_conversation('00000000-0000-0000-0000-0000000a1f02');
reset role;

create temp table _fx as
  select c.id as conv from public.conversations c
   where exists (select 1 from public.conversation_members m
                  where m.conversation_id = c.id
                    and m.user_id = '00000000-0000-0000-0000-0000000a1f01');
grant select on _fx to authenticated;

-- Who says what: ann sends; bob is a member whose history starts a day ago
-- (so a message from two days ago is not his to read: the no-history /
-- rejoined case); dan is active but not a member.
update public.conversation_members set history_from = now() - interval '1 day'
 where conversation_id = (select conv from _fx) and user_id = '00000000-0000-0000-0000-0000000a1f02';

-- ann sends a plain text message carrying [card]; the body names the card url
-- unless the test says otherwise.
create or replace function lp_send(card jsonb, body text default null, mid uuid default null)
returns uuid language plpgsql as $$
declare id uuid := coalesce(mid, gen_random_uuid());
begin
  insert into public.messages(id, conversation_id, sender_id, body, link_preview)
    values (id, (select conv from _fx), '00000000-0000-0000-0000-0000000a1f01',
            coalesce(body, 'see ' || coalesce(card->>'url', 'https://example.com/a')), card);
  return id;
end $$;
grant execute on function lp_send(jsonb, text, uuid) to authenticated;

-- As the phone does: upload the picture to <conv>/<message id>.jpg, then send
-- the card naming it.
create or replace function lp_upload(mid uuid) returns text language plpgsql as $$
declare path text := (select conv from _fx)::text || '/' || mid::text || '.jpg';
begin
  insert into storage.objects(bucket_id, name, owner_id, metadata)
    values ('link-previews', path, auth.uid()::text, '{"size":3}'::jsonb);
  return path;
end $$;
grant execute on function lp_upload(uuid) to authenticated;

-- A card valid in every field; each rejection below breaks exactly one.
create or replace function lp_card(patch jsonb default '{}'::jsonb) returns jsonb
language sql as $$
  select jsonb_build_object(
    'url', 'https://example.com/a',
    'title', 'Example page',
    'description', 'What the page says about itself',
    'site', 'Example',
    'video', false) || patch
$$;
grant execute on function lp_card(jsonb) to authenticated;

create temp table _id (k text primary key, id uuid);
insert into _id select k, gen_random_uuid() from unnest(array[
  'full','orphan','other','bobs','none','del','edit','kept']) k;
grant select on _id to authenticated;
create or replace function i(k text) returns uuid language sql as $$ select id from _id where _id.k = $1 $$;
create or replace function pic(k text) returns text language sql as
  $$ select (select conv from _fx)::text || '/' || i(k)::text || '.jpg' $$;
grant execute on function i(text) to authenticated;
grant execute on function pic(text) to authenticated;

-- 1 the bucket --------------------------------------------------------------
select is((select public from storage.buckets where id = 'link-previews'), false,
          'the link-previews bucket is private');
select is((select file_size_limit from storage.buckets where id = 'link-previews'), 262144::bigint,
          'the link-previews bucket caps a picture at 256 KiB');
select set_eq(
  $$select unnest(allowed_mime_types) from storage.buckets where id = 'link-previews'$$,
  $$values ('image/jpeg'),('image/png'),('image/webp')$$,
  'the link-previews bucket accepts jpeg, png and webp only');
select is((select cmd from pg_policies where schemaname = 'storage' and policyname = 'link_previews_write'),
          'INSERT', 'link_previews_write is an insert policy');
select is((select cmd from pg_policies where schemaname = 'storage' and policyname = 'link_previews_read'),
          'SELECT', 'link_previews_read is a select policy');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
             and (coalesce(qual, '') || coalesce(with_check, '')) like '%link-previews%'), 2::bigint,
          'no other policy (no update, no delete) names the link-previews bucket');

-- 2 upload: members only ------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000a1f01', 'a1f00000-0000-0000-0000-000000000001');
select lives_ok($$select lp_upload(i('orphan'))$$,
                'a member uploads a card picture into the conversation folder');
select is((select count(*) from storage.objects where bucket_id = 'link-previews' and name = pic('orphan')),
          1::bigint, 'the uploader reads her own picture before any message names it');
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('link-previews', %L, %L, '{"size":3}'::jsonb)$$,
         '11111111-2222-3333-4444-555555555555/card.jpg', '00000000-0000-0000-0000-0000000a1f01'),
  '42501', null, 'a member cannot upload into a folder of no conversation of hers');
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('link-previews', 'loose.jpg', %L, '{"size":3}'::jsonb)$$,
         '00000000-0000-0000-0000-0000000a1f01'),
  '42501', null, 'a key with no conversation folder is refused by policy');
select lives_ok(
  $$update storage.objects set metadata = '{"hacked":true}'::jsonb where bucket_id = 'link-previews'$$,
  'an update over the bucket matches nothing rather than erroring');
select is((select count(*) from storage.objects where bucket_id = 'link-previews' and metadata ? 'hacked'),
          0::bigint, 'no update policy: a card picture cannot be rewritten');
select throws_ok($$delete from storage.objects where bucket_id = 'link-previews'$$,
                 null, null, 'no delete policy: deleting a card picture is refused');
reset role;
select is((select count(*) from storage.objects where bucket_id = 'link-previews'), 1::bigint,
          'the card picture survives the delete attempt');

select test_as('00000000-0000-0000-0000-0000000a1f03', 'a1f00000-0000-0000-0000-000000000003');
select throws_ok(
  format($$insert into storage.objects(bucket_id, name, owner_id, metadata)
           values ('link-previews', %L, %L, '{"size":3}'::jsonb)$$,
         (select conv from _fx) || '/dan.jpg', '00000000-0000-0000-0000-0000000a1f03'),
  '42501', null, 'an active non-member cannot upload into the conversation folder');
reset role;

-- 3 read: only through a readable, live message naming the picture -----------
select test_as('00000000-0000-0000-0000-0000000a1f02', 'a1f00000-0000-0000-0000-000000000002');
select is((select count(*) from storage.objects where bucket_id = 'link-previews' and name = pic('orphan')),
          0::bigint, 'TARGET H1: a member does not read a picture no message names');
select lives_ok($$select lp_upload(i('bobs'))$$, 'the other member uploads too');
reset role;

select test_as('00000000-0000-0000-0000-0000000a1f01', 'a1f00000-0000-0000-0000-000000000001');
select lives_ok($$select lp_upload(i('full')), lp_upload(i('del')), lp_upload(i('edit')), lp_upload(i('kept'))$$,
                'ann uploads the pictures of her next messages');
select lives_ok($$select lp_send(lp_card(jsonb_build_object('image', pic('full'))), null, i('full'))$$,
                'a full card naming its own <conv>/<message id>.jpg is accepted');
select lives_ok($$select lp_send(lp_card(jsonb_build_object('image', pic('del'))), null, i('del'))$$,
                'a second card with a picture is accepted');
select lives_ok($$select lp_send(lp_card(jsonb_build_object('image', pic('edit'))), null, i('edit'))$$,
                'a third card with a picture is accepted');
select lives_ok($$select lp_send(lp_card(jsonb_build_object('image', pic('kept'))), null, i('kept'))$$,
                'a fourth card with a picture is accepted');
reset role;
-- A card from two days ago, before bob's history: written as the owner.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('link-previews', (select conv from _fx)::text || '/' || '00000000-0000-0000-0000-00000000a1d0' || '.jpg',
   '00000000-0000-0000-0000-0000000a1f01', '{"size":3}'::jsonb);
insert into public.messages(id, conversation_id, sender_id, body, link_preview, created_at) values
  ('00000000-0000-0000-0000-00000000a1d0', (select conv from _fx), '00000000-0000-0000-0000-0000000a1f01',
   'old https://example.com/a',
   lp_card(jsonb_build_object('image', (select conv from _fx)::text || '/00000000-0000-0000-0000-00000000a1d0.jpg')),
   now() - interval '2 days');

select test_as('00000000-0000-0000-0000-0000000a1f02', 'a1f00000-0000-0000-0000-000000000002');
select is((select count(*) from storage.objects where bucket_id = 'link-previews' and name = pic('full')),
          1::bigint, 'the other member reads a picture his message names');
select is((select count(*) from storage.objects where bucket_id = 'link-previews'
            and name = (select conv from _fx)::text || '/00000000-0000-0000-0000-00000000a1d0.jpg'),
          0::bigint, 'TARGET H1: a member does not read the picture of a message before his history');
reset role;
select test_as('00000000-0000-0000-0000-0000000a1f03', 'a1f00000-0000-0000-0000-000000000003');
select is((select count(*) from storage.objects where bucket_id = 'link-previews'), 0::bigint,
          'an active non-member reads no card picture');
reset role;

-- 4 the column grant ----------------------------------------------------------
select ok(has_column_privilege('authenticated', 'public.messages', 'link_preview', 'INSERT'),
          'authenticated may insert link_preview');
select ok(not has_column_privilege('authenticated', 'public.messages', 'link_preview', 'UPDATE'),
          'authenticated may not update link_preview');

-- 5 valid cards ----------------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000a1f01', 'a1f00000-0000-0000-0000-000000000001');
select lives_ok($$select lp_send('{"url":"http://example.com","title":"T"}'::jsonb)$$,
                'url and a one-character title alone are accepted (http too)');
select lives_ok($$select lp_send(lp_card('{"video":true}'))$$, 'a video card is accepted');
select lives_ok(format($$select lp_send(lp_card(%L))$$,
                  jsonb_build_object('url', 'https://example.com/' || repeat('a', 2000 - 20))),
                'a 2000-character url is accepted');
select lives_ok(format($$select lp_send(lp_card(%L))$$,
                  jsonb_build_object('title', repeat('t', 200), 'description', repeat('d', 400),
                                     'site', repeat('s', 100))),
                'title 200, description 400 and site 100 characters are accepted');
select lives_ok(format($$select lp_send(lp_card(%L))$$,
                  jsonb_build_object('title', 'Çok güzel — “quoted” & ünïcode')),
                'non-ASCII text and an ampersand are accepted');
select lives_ok($$select lp_send(null, 'no card https://example.com')$$,
                'a text message without a card is accepted');
select is((select link_preview from public.messages where id = i('full')),
          lp_card(jsonb_build_object('image', pic('full'))), 'the card is stored as sent');

-- 6 every rejection rule: errcode LNKP1, 'invalid link preview' ---------------
select throws_ok($$select lp_send(lp_card('{"extra":"x"}'))$$, 'LNKP1', 'invalid link preview',
                 'an unknown key is refused');
select throws_ok($$select lp_send(lp_card('{"html":"<b>x</b>"}'))$$, 'LNKP1', 'invalid link preview',
                 'an html key is refused');
select throws_ok($$select lp_send(lp_card() - 'url')$$, 'LNKP1', 'invalid link preview',
                 'a card without url is refused');
select throws_ok($$select lp_send(lp_card() - 'title')$$, 'LNKP1', 'invalid link preview',
                 'a card without title is refused');
select throws_ok($$select lp_send(lp_card('{"url":"javascript:alert(1)"}'))$$, 'LNKP1', 'invalid link preview',
                 'a javascript: url is refused');
select throws_ok($$select lp_send(lp_card('{"url":"ftp://example.com/a"}'))$$, 'LNKP1', 'invalid link preview',
                 'an ftp url is refused');
select throws_ok($$select lp_send(lp_card('{"url":"example.com"}'))$$, 'LNKP1', 'invalid link preview',
                 'a url without a scheme is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$,
                   jsonb_build_object('url', 'https://example.com/' || repeat('a', 2001 - 20))),
                 'LNKP1', 'invalid link preview', 'a 2001-character url is refused');
select throws_ok($$select lp_send(lp_card('{"url":42}'))$$, 'LNKP1', 'invalid link preview',
                 'a url that is not a string is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$,
                   jsonb_build_object('url', 'https://example.com/a' || chr(9) || 'b')),
                 'LNKP1', 'invalid link preview', 'TARGET L1: a control character in the url is refused');
select throws_ok($$select lp_send(lp_card(), 'no link in this text')$$, 'LNKP1', 'invalid link preview',
                 'TARGET L2: a card whose url is not in the body is refused');
select throws_ok($$select lp_send(lp_card('{"title":""}'))$$, 'LNKP1', 'invalid link preview',
                 'an empty title is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('title', repeat('t', 201))),
                 'LNKP1', 'invalid link preview', 'a 201-character title is refused');
select throws_ok($$select lp_send(lp_card('{"title":["a"]}'))$$, 'LNKP1', 'invalid link preview',
                 'a title that is not a string is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('description', repeat('d', 401))),
                 'LNKP1', 'invalid link preview', 'a 401-character description is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('site', repeat('s', 101))),
                 'LNKP1', 'invalid link preview', 'a 101-character site is refused');
select throws_ok($$select lp_send(lp_card('{"title":"a<script>"}'))$$, 'LNKP1', 'invalid link preview',
                 'a < in the title is refused');
select throws_ok($$select lp_send(lp_card('{"description":"x > y"}'))$$, 'LNKP1', 'invalid link preview',
                 'a > in the description is refused');
select throws_ok($$select lp_send(lp_card('{"site":"<b>"}'))$$, 'LNKP1', 'invalid link preview',
                 'a < in the site is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('title', 'a' || chr(10) || 'b')),
                 'LNKP1', 'invalid link preview', 'a newline in the title is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('description', 'a' || chr(27) || 'b')),
                 'LNKP1', 'invalid link preview', 'an escape character in the description is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('site', 'a' || chr(127))),
                 'LNKP1', 'invalid link preview', 'a DEL character in the site is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('title', 'pay' || chr(8203) || 'pal')),
                 'LNKP1', 'invalid link preview', 'TARGET L1: a zero-width space (U+200B) in the title is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('description', 'abc' || chr(8238) || 'gpj.exe')),
                 'LNKP1', 'invalid link preview', 'TARGET L1: a right-to-left override (U+202E) in the description is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('site', 'a' || chr(8294) || 'b')),
                 'LNKP1', 'invalid link preview', 'TARGET L1: an isolate (U+2066) in the site is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$, jsonb_build_object('title', chr(65279) || 'Title')),
                 'LNKP1', 'invalid link preview', 'TARGET L1: a byte-order mark (U+FEFF) in the title is refused');
select throws_ok($$select lp_send(lp_card('{"image":"11111111-2222-3333-4444-555555555555/card.jpg"}'))$$,
                 'LNKP1', 'invalid link preview', 'a picture in another conversation''s folder is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$,
                   jsonb_build_object('image', (select conv from _fx)::text || 'card.jpg')),
                 'LNKP1', 'invalid link preview', 'a picture path not inside the folder (no slash) is refused');
select throws_ok(format($$select lp_send(lp_card(%L))$$,
                   jsonb_build_object('image', (select conv from _fx)::text || '/' || repeat('p', 400))),
                 'LNKP1', 'invalid link preview', 'a picture path over 400 characters is refused');
select throws_ok($$select lp_send(lp_card('{"image":"ab"}'))$$, 'LNKP1', 'invalid link preview',
                 'a 2-character picture path is refused');
-- ann owns the orphan picture: only the message-id rule can refuse this.
select throws_ok($$select lp_send(lp_card(jsonb_build_object('image', pic('orphan'))), null, i('other'))$$,
                 'LNKP1', 'invalid link preview',
                 'TARGET M1: a card naming her own picture of ANOTHER message id is refused');
select throws_ok($$select lp_send(lp_card(jsonb_build_object('image', pic('none'))), null, i('none'))$$,
                 'LNKP1', 'invalid link preview',
                 'TARGET M1: a card naming <conv>/<its id>.jpg that was never uploaded is refused');
select throws_ok($$select lp_send(lp_card(jsonb_build_object('image', pic('bobs'))), null, i('bobs'))$$,
                 'LNKP1', 'invalid link preview',
                 'TARGET M1: a card naming a picture uploaded by somebody else is refused');
select throws_ok($$select lp_send(lp_card('{"video":"true"}'))$$, 'LNKP1', 'invalid link preview',
                 'a video flag that is not a boolean is refused');
select throws_ok($$select lp_send('"https://example.com"'::jsonb)$$, 'LNKP1', 'invalid link preview',
                 'a card that is not an object is refused');
select throws_ok($$select lp_send('[{"url":"https://example.com","title":"T"}]'::jsonb)$$,
                 'LNKP1', 'invalid link preview', 'an array card is refused');

-- with an attachment: ann owns a real object, so only the card can refuse it.
reset role;
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', (select conv from _fx) || '/lp-photo.jpg', '00000000-0000-0000-0000-0000000a1f01', '{"size":3}'::jsonb);
select test_as('00000000-0000-0000-0000-0000000a1f01', 'a1f00000-0000-0000-0000-000000000001');
select lives_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path)
           values (%L, %L, 'photo https://example.com/a', %L)$$, (select conv from _fx),
         '00000000-0000-0000-0000-0000000a1f01', (select conv from _fx) || '/lp-photo.jpg'),
  'control: the same photo message without a card is accepted');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, attachment_path, link_preview)
           values (%L, %L, 'photo https://example.com/a', %L, %L)$$, (select conv from _fx),
         '00000000-0000-0000-0000-0000000a1f01', (select conv from _fx) || '/lp-photo.jpg', lp_card()),
  'LNKP1', 'invalid link preview', 'a card on a photo message is refused');
reset role;

-- The special kinds are written only by definer RPCs; as the table owner the
-- grants are out of the way and only the guard can refuse.
create or replace function lp_kind(kind text) returns void language plpgsql as $$
begin
  execute format(
    'insert into public.messages(conversation_id, sender_id, body, link_preview, %s) values ($1, $2::uuid, $3, $4, %s)',
    case kind when 'sticker' then 'sticker_album' when 'location' then 'location_lat, location_lng'
              when 'deleted' then 'deleted, deleted_at' else kind end,
    case kind when 'location' then '1, 2' when 'deleted' then '''placeholder'', now()' else 'true' end)
  using (select conv from _fx), '00000000-0000-0000-0000-0000000a1f01', 'x https://example.com/a', lp_card();
end $$;
select throws_ok($$select lp_kind('sticker')$$, 'LNKP1', 'invalid link preview', 'a card on a sticker album is refused');
select throws_ok($$select lp_kind('poll')$$, 'LNKP1', 'invalid link preview', 'a card on a poll is refused');
select throws_ok($$select lp_kind('contact')$$, 'LNKP1', 'invalid link preview', 'a card on a contact is refused');
select throws_ok($$select lp_kind('location')$$, 'LNKP1', 'invalid link preview', 'a card on a location is refused');
select throws_ok($$select lp_kind('deleted')$$, 'LNKP1', 'invalid link preview', 'a card on a deleted message is refused');
select throws_ok(
  format($$insert into public.messages(conversation_id, sender_id, body, sticker_id, link_preview)
           values (%L, %L, '', %L, %L)$$, (select conv from _fx), '00000000-0000-0000-0000-0000000a1f01',
         '11111111-2222-3333-4444-555555555555', lp_card()),
  'LNKP1', 'invalid link preview', 'a card on a sticker is refused (before the sticker foreign key)');

-- 7 edit and delete drop the card, and with it the picture ------------------
select test_as('00000000-0000-0000-0000-0000000a1f01', 'a1f00000-0000-0000-0000-000000000001');
select lives_ok($$select public.edit_message(i('edit'), 'edited, still https://example.com/a')$$,
                'the sender edits a message with a card');
select lives_ok($$select public.delete_message(i('del'))$$,
                'the sender deletes a message with a card');
reset role;
select is((select link_preview from public.messages where id = i('edit')), null,
          'an edit drops the card');
select is((select link_preview from public.messages where id = i('del')), null,
          'a delete for everyone drops the card');
select test_as('00000000-0000-0000-0000-0000000a1f02', 'a1f00000-0000-0000-0000-000000000002');
select is((select count(*) from storage.objects where bucket_id = 'link-previews' and name = pic('kept')),
          1::bigint, 'control: the other member reads the picture of a live card');
select is((select count(*) from storage.objects where bucket_id = 'link-previews' and name = pic('del')),
          0::bigint, 'TARGET H1: the picture of a card deleted for everyone is unreadable');
select is((select count(*) from storage.objects where bucket_id = 'link-previews' and name = pic('edit')),
          0::bigint, 'TARGET H1: the picture of an edited (card dropped) message is unreadable');
reset role;

-- An update that does not change the body keeps the card; one that does, drops it.
update public.messages set body = body where id = i('kept');
select isnt((select link_preview from public.messages where id = i('kept')), null,
            'rewriting the same body keeps the card');
select throws_ok($$update public.messages set link_preview = '{"url":"https://x.com"}'::jsonb where id = i('kept')$$,
                 'LNKP1', 'invalid link preview', 'an update of the card itself is validated too');
update public.messages set body = 'changed https://example.com/a', link_preview = link_preview where id = i('kept');
select is((select link_preview from public.messages where id = i('kept')), null,
          'a changed body drops the card even when the update names it');

select * from finish();
rollback;
