begin;
select plan(133);

-- Encrypted messages (Private Chats step 4a, 20261031120000_encrypted_messages.sql):
-- messages.ciphertext / olm_type, the conversation gates, the plain-text lock
-- of an encrypted 1:1, delete_message, edit_message_encrypted, edit_message,
-- the link guard, push_targets' encrypted column and search_messages.
--
-- Contract (written from the contract, not the function bodies):
--   ciphertext and olm_type are set together or not at all; olm_type 0 or 1;
--   ciphertext 1..65536 chars; body exactly the placeholder; none of the
--   content columns (link_preview, attachment_*, voice_transcript, poll,
--   contact, photo_group, sticker_*, location_lat, admin_msg) -> 23514.
--   forwarded is allowed. A ciphertext row is refused (42501) in a group, the
--   system chat, the admin chat, a 1:1 with a bot, and from a bot sender.
--   Once a 1:1 holds a ciphertext row a plain text insert is ENCR1 and a
--   notification reply 42501; photo, sticker, poll, contact and location
--   still go; other chats are untouched.
--
-- Fixtures. Every refused subject is shown next to a twin that succeeds and
-- differs only in the gate under test. Rows the client cannot shape (age,
-- columns without an insert grant, the system / admin chat, a bot sender in
-- a chat it is not in) are written as the superuser, so the refusal is the
-- table's own (CHECK or trigger), never RLS.
--   ann  main sender         bob  ann's 1:1 partner (AB, encrypted)
--   cat  ann's plain 1:1 (AC), and bob's 1:1 (BC, the bot-sender target)
--   dee  deletes her own ciphertext (DE, with eve)
--   fay  edits once, then leaves FB (with bob)
--   gus  preview sender       hal  preview none      own  the owner (admin chat)
--   bot  enabled bot, ann's 1:1 AT
-- Every human publishes keys first, so a later "members need live keys"
-- rule cannot be what refuses a row here.

-- fixtures -----------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000e5c000' || case n
    when 'ann' then '01' when 'bob' then '02' when 'cat' then '03' when 'dee' then '04'
    when 'eve' then '05' when 'bot' then '06' when 'own' then '07' when 'fay' then '08'
    when 'gus' then '09' when 'hal' then '0a' end)::uuid
$$;
create function sid(n text) returns text language sql immutable as $$
  select 'e5c00000-0000-0000-0000-' || right(u(n)::text, 12)
$$;
create function mid(n text) returns uuid language sql immutable as $$
  select md5('e5c-msg-' || n)::uuid
$$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function ph() returns text language sql immutable as $$ select '🔒 Encrypted message' $$;
create function ct(n int, c text default 'A') returns text language sql immutable as $$ select repeat(c, n) $$;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'e5c-' || n || '@mail.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['ann','bob','cat','dee','eve','bot','own','fay','gus','hal']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'e5c-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select sid(n)::uuid, u(n), now(), now()
    from unnest(array['ann','bob','cat','dee','eve','bot','own','fay','gus','hal']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('ann'), u('bob')), (u('ann'), u('cat')), (u('ann'), u('bot')), (u('ann'), u('gus')),
  (u('ann'), u('hal')), (u('dee'), u('eve')), (u('fay'), u('bob')), (u('bob'), u('cat'));

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', sid(n))::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
-- 'ok' or the sqlstate, in its own subtransaction.
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;

create table public.e5c_ids(name text primary key, id uuid);
grant select, insert on public.e5c_ids to authenticated, anon, service_role;
create function g(n text) returns uuid language sql stable as $$
  select id from public.e5c_ids where name = n
$$;
-- ins(conv, id, body, ciphertext, olm_type [, forwarded]): the client's insert, as SQL.
create function ins(c uuid, id uuid, b text, x text, t int, f boolean default false) returns text
language sql stable as $$
  select format($q$insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type, forwarded)
                   values (%L, %L, auth.uid(), %L, %L, %L::smallint, %L)$q$, id, c, b, x, t, f)
$$;
-- A stored object owned by the caller (the photo the app uploads first).
create function put(path text) returns text language sql security definer as $$
  insert into storage.objects(bucket_id, name, owner_id, metadata)
  values ('attachments', path, auth.uid(), '{"size":3}'::jsonb);
  select path $$;
create function col(id uuid, c text) returns text language plpgsql stable security definer as $$
declare r text;
begin execute format('select %I::text from public.messages where id = %L', c, id) into r;
return coalesce(r, '<null>'); end $$;
create function enc(id uuid, x text, t int) returns text language plpgsql as $$
declare m public.messages;
begin
  m := public.edit_message_encrypted(id, x, t::smallint);
  return concat_ws('|', m.ciphertext, m.olm_type, (m.edited_at is not null)::text, m.body);
exception when others then return sqlstate;
end $$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), ph(), ct(int, text),
  as_(text), commit_check(), try(text), g(text), ins(uuid, uuid, text, text, int, boolean),
  put(text), col(uuid, text), enc(uuid, text, int) to authenticated, anon, service_role;

-- activate, publish keys, register a push token
do $$
declare n text;
begin
  foreach n in array array['ann','bob','cat','dee','eve','bot','own','fay','gus','hal'] loop
    perform as_(n);
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    if n <> 'bot' then
      perform public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n),
                                      array[k(n || '1'), k(n || '2')], k(n || '-F'));
    end if;
    perform public.register_device_token('e5c-tok-' || n, 'android', true);
    if n = 'gus' then insert into public.notification_settings(preview) values ('sender'); end if;
    if n = 'hal' then insert into public.notification_settings(preview) values ('none'); end if;
    execute 'reset role';
  end loop;
end $$;
insert into public.conversations(id, title) values ('e5c0c000-0000-0000-0000-00000000dbdb', 'e5c debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
  values (u('bot'), 'e5c0c000-0000-0000-0000-00000000dbdb', true);
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('ann'));

select as_('ann');
insert into public.e5c_ids values
  ('AB', public.start_direct_conversation(u('bob'))),
  ('AC', public.start_direct_conversation(u('cat'))),
  ('AT', public.start_direct_conversation(u('bot'))),
  ('AG', public.start_direct_conversation(u('gus'))),
  ('AH', public.start_direct_conversation(u('hal'))),
  ('G',  public.start_group_conversation('e5c group', array[u('bob'), u('cat')]));
reset role;
select as_('dee'); insert into public.e5c_ids values ('DE', public.start_direct_conversation(u('eve'))); reset role;
select as_('fay'); insert into public.e5c_ids values ('FB', public.start_direct_conversation(u('bob'))); reset role;
select as_('bob'); insert into public.e5c_ids values ('BC', public.start_direct_conversation(u('cat'))); reset role;
insert into public.conversations(id, system) values ('e5c0c000-0000-0000-0000-00000000555a', true);
insert into public.conversation_members(conversation_id, user_id) values ('e5c0c000-0000-0000-0000-00000000555a', u('ann'));
insert into public.e5c_ids values ('SYS', 'e5c0c000-0000-0000-0000-00000000555a');
insert into app_private.owners(user_id) values (u('own'));
insert into public.e5c_ids select 'ADM', id from public.conversations where admin_chat;
-- ann's sticker (and its file), sent while AB is encrypted
insert into public.stickers(id, owner_id) values ('e5c05000-0000-0000-0000-000000000001', u('ann'));
insert into storage.objects(bucket_id, name, owner_id, metadata)
  values ('stickers', 'e5c05000-0000-0000-0000-000000000001.webp', u('ann'), '{"size":3}'::jsonb);

select is((select count(*) from public.e5c_ids where id is not null), 11::bigint, 'fixture: all eleven conversations exist');
select ok(exists(select 1 from public.conversation_members where conversation_id = g('AT') and user_id = u('bot')),
  'fixture: the bot is a member of AT');
select is((select count(*) from app_private.olm_devices where user_id in (u('ann'), u('bob'))), 2::bigint,
  'fixture: ann and bob have published devices');

-- 1 the columns ------------------------------------------------------------
select has_column('public', 'messages', 'ciphertext', 'messages.ciphertext exists');
select col_type_is('public', 'messages', 'ciphertext', 'text', 'ciphertext is text');
select has_column('public', 'messages', 'olm_type', 'messages.olm_type exists');
select col_type_is('public', 'messages', 'olm_type', 'smallint', 'olm_type is smallint');
select ok(not has_column_privilege('authenticated', 'public.messages', 'ciphertext', 'UPDATE'),
  'authenticated cannot update ciphertext directly');

-- 2 the CHECK, as the client, before AB holds any ciphertext ---------------------
-- A plain row in AB first: edit_message_encrypted must refuse it, and push says false.
select as_('ann');
select is(try(format($q$insert into public.messages(id, conversation_id, sender_id, body)
                        values (%L, %L, auth.uid(), 'ab plain words')$q$, mid('abplain'), g('AB'))),
  'ok', 'ann sends a plain row in AB before it is encrypted');
select is(try(ins(g('AB'), mid('c1'), ph(), ct(10), null)), '23514', 'ciphertext without olm_type -> 23514');
select is(try(ins(g('AB'), mid('c2'), ph(), null, 0)), '23514', 'olm_type without ciphertext -> 23514');
select is(try(ins(g('AB'), mid('c3'), ph(), ct(10), 2)), '23514', 'olm_type 2 -> 23514');
select is(try(ins(g('AB'), mid('c4'), ph(), ct(10), -1)), '23514', 'olm_type -1 -> 23514');
select is(try(ins(g('AB'), mid('c5'), ph(), '', 0)), '23514', 'empty ciphertext -> 23514');
select is(try(ins(g('AB'), mid('c6'), ph(), ct(65537), 0)), '23514', '65537 chars -> 23514');
select is(try(ins(g('AB'), mid('c7'), 'hello', ct(10), 0)), '23514', 'a body other than the placeholder -> 23514');
select is(try(ins(g('AB'), mid('c8'), '', ct(10), 0)), '23514', 'an empty body with ciphertext -> 23514');
select is(try(ins(g('AB'), mid('c9'), ph() || ' ', ct(10), 0)), '23514', 'the placeholder plus a space -> 23514');
reset role;
select is((select count(*) from public.messages where conversation_id = g('AB') and ciphertext is not null), 0::bigint,
  'fixture: AB still holds no ciphertext row');

-- 3 the happy path --------------------------------------------------------------
select as_('ann');
select is(try(ins(g('AB'), mid('E1'), ph(), ct(10), 0)), 'ok', 'ann: ciphertext, olm_type 0, placeholder in a human 1:1 -> ok');
select is(try(ins(g('AB'), mid('E2'), ph(), ct(10, 'B'), 1)), 'ok', 'ann: olm_type 1 -> ok');
select is(try(ins(g('AB'), mid('E3'), ph(), ct(10, 'C'), 1)), 'ok', 'ann: a third row');
select is(try(ins(g('AB'), mid('E64'), ph(), ct(65536), 1)), 'ok', 'ann: 65536 chars -> ok');
select is(try(ins(g('AB'), mid('EF'), ph(), ct(10, 'F'), 1, true)), 'ok', 'ann: forwarded true is allowed');
reset role;
select as_('bob');
select is(try(ins(g('AB'), mid('EB'), ph(), ct(10, 'D'), 1)), 'ok', 'bob answers with ciphertext');
reset role;
select is(col(mid('E1'), 'ciphertext'), ct(10), 'the ciphertext is stored as sent');
select is(col(mid('E1'), 'olm_type'), '0', 'and its olm_type');
select is(col(mid('E1'), 'body'), ph(), 'and the placeholder body');

-- 4 the content columns, as the superuser (no client grant needed) ---------------
-- 'ok', or the sqlstate and the constraint that refused the row.
create function try_c(q text) returns text language plpgsql as $$
declare n text;
begin execute q; perform commit_check(); return 'ok';
exception when others then get stacked diagnostics n = constraint_name; return concat_ws(':', sqlstate, nullif(n, ''));
end $$;
create function su_ct(c text, v text) returns text language sql as $$
  select try_c(format($q$insert into public.messages(conversation_id, sender_id, body, ciphertext, olm_type, %I)
                       values (%L, %L, %L, 'QUFB', 1, %s)$q$, c, g('AB'), u('ann'), ph(), v))
$$;
select is(su_ct('forwarded', 'false'), 'ok', 'superuser control: a ciphertext row with no content column -> ok');
select is(su_ct(c, v), '23514:messages_ciphertext_check', 'a ciphertext row with ' || c || ' set -> 23514')
  from (values ('link_preview', $$'{"url":"https://e5c.test/a"}'::jsonb$$),
               ('attachment_path', format('%L', g('AB')::text || '/e5c.jpg')),
               ('attachment_name', $$'e5c.jpg'$$),
               ('attachment_mime', $$'image/jpeg'$$),
               ('attachment_size', '3'),
               ('attachment_duration_ms', '1000'),
               ('attachment_waveform', $$'AAAA'$$),
               ('voice_transcript', $$'words'$$),
               ('poll', 'true'),
               ('contact', 'true'),
               ('photo_group', $$'e5c06000-0000-0000-0000-000000000001'::uuid$$),
               ('sticker_id', $$'e5c05000-0000-0000-0000-000000000001'::uuid$$),
               ('sticker_album_id', $$'e5c07000-0000-0000-0000-000000000001'::uuid$$),
               ('sticker_album', 'true'),
               ('location_lat', '41.0'),
               ('admin_msg', $$'{}'::jsonb$$)) v(c, v);
-- A preview alone is already refused by messages_attachment_preview_check (it
-- needs a path), so the ciphertext rule can only be seen through the path.
select is(su_ct('attachment_preview', $$'e5cpreview'$$), '23514:messages_attachment_preview_check',
  'a ciphertext row with attachment_preview set -> 23514 (the preview check)');

-- 5 where ciphertext may not go -------------------------------------------------
select as_('ann');
select is(try(format($q$insert into public.messages(conversation_id, sender_id, body) values (%L, auth.uid(), 'g plain')$q$, g('G'))),
  'ok', 'control: ann sends plain text in the group');
select is(try(ins(g('G'), mid('xg'), ph(), ct(10), 1)), '42501', 'ciphertext in a group -> 42501');
select is(try(format($q$insert into public.messages(conversation_id, sender_id, body) values (%L, auth.uid(), 'at plain')$q$, g('AT'))),
  'ok', 'control: ann sends plain text in her 1:1 with the bot');
select is(try(ins(g('AT'), mid('xt'), ph(), ct(10), 1)), '42501', 'ciphertext in a 1:1 with a bot member -> 42501');
reset role;
create function su_ins(c uuid, s uuid, x text) returns text language sql as $$
  select try(format($q$insert into public.messages(conversation_id, sender_id, body, ciphertext, olm_type)
                       values (%L, %L, %L, %L, %s)$q$, c, s, case when x is null then 'su plain' else ph() end,
                    x, case when x is null then 'null' else '1' end))
$$;
select is(su_ins(g('SYS'), u('ann'), null), 'ok', 'control: the superuser writes plain text in the system chat');
select is(su_ins(g('SYS'), u('ann'), 'QUFB'), '42501', 'ciphertext in the system chat -> 42501 (even as superuser)');
select is(su_ins(g('ADM'), u('own'), null), 'ok', 'control: plain text in the admin chat');
select is(su_ins(g('ADM'), u('own'), 'QUFB'), '42501', 'ciphertext in the admin chat -> 42501 (even as superuser)');
select as_('own');
select is(try(ins(g('ADM'), mid('xa'), ph(), ct(10), 1)), '42501', 'the owner''s client: ciphertext in the admin chat -> 42501');
reset role;
-- The system and admin chats have no direct_key, so the "direct only" rule
-- already refuses them. Give each a direct_key, so only its own flag can.
insert into public.conversations(id, system, direct_key) values ('e5c0c000-0000-0000-0000-00000000555d', true, 'e5c-sys-direct');
insert into public.conversation_members(conversation_id, user_id) values ('e5c0c000-0000-0000-0000-00000000555d', u('ann'));
select is(su_ins('e5c0c000-0000-0000-0000-00000000555d', u('ann'), 'QUFB'), '42501',
  'ciphertext in a system chat that carries a direct_key -> 42501');
-- The admin chat is also flagged system; clear that too, so admin_chat alone decides.
select is((select system from public.conversations where id = g('ADM')), true, 'fixture: the admin chat is also a system chat');
update public.conversations set direct_key = 'e5c-adm-direct', system = false where id = g('ADM');
select is(su_ins(g('ADM'), u('own'), 'QUFB'), '42501', 'ciphertext in an admin chat with a direct_key, not system -> 42501');
update public.conversations set direct_key = null, system = true where id = g('ADM');
select is(su_ins(g('BC'), u('cat'), 'QUFB'), 'ok', 'control: a human sender''s ciphertext in BC (bob-cat) -> ok');
select is(su_ins(g('BC'), u('bot'), 'QUFB'), '42501', 'a bot sender''s ciphertext in the same human 1:1 -> 42501');
select as_('bot');
select is(try(format($q$insert into public.messages(conversation_id, sender_id, body) values (%L, auth.uid(), 'bot plain')$q$, g('AT'))),
  'ok', 'control: the bot''s client sends plain text in its 1:1 with ann');
select is(try(ins(g('AT'), mid('xbot'), ph(), ct(10), 1)), '42501', 'the bot''s client: ciphertext -> 42501');
reset role;

-- 6 an encrypted 1:1 refuses plain text, keeps the other kinds -------------------
select as_('ann');
select is(try(format($q$insert into public.messages(conversation_id, sender_id, body) values (%L, auth.uid(), 'leak')$q$, g('AB'))),
  'ENCR1', 'ann: plain text into encrypted AB -> ENCR1');
reset role;
select as_('bob');
select is(try(format($q$insert into public.messages(conversation_id, sender_id, body) values (%L, auth.uid(), 'leak')$q$, g('AB'))),
  'ENCR1', 'bob: plain text into encrypted AB -> ENCR1');
reset role;
select as_('ann');
select is(try(format($q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path)
                        values (%L, %L, auth.uid(), '', %L)$q$,
                     mid('photo'), g('AB'), put(g('AB')::text || '/e5c-photo.jpg'))),
  'ok', 'a plain photo still goes');
select is(try(format('select public.send_sticker(%L, %L, %L, null, false)', g('AB'), mid('sticker'),
                     'e5c05000-0000-0000-0000-000000000001')), 'ok', 'a sticker still goes');
select is(try(format('select public.create_poll(%L, %L, %L, %L, false, false)', g('AB'), mid('poll'),
                     'Lunch?', array['Pizza','Soup'])), 'ok', 'a poll still goes');
select is(try(format('select public.send_contact(%L, %L, %L, %L)', g('AB'), mid('contact'), 'Ann Lee', '+90 555')),
  'ok', 'a contact still goes');
select is(try(format('select public.send_location(%L, %L, 41.0::float8, 29.0::float8, %L, %L)', g('AB'), mid('loc'),
                     'Pier', 'Iskele Sk. 1')), 'ok', 'a location still goes (plain in 4a)');
select is(try(format($q$insert into public.messages(id, conversation_id, sender_id, body)
                        values (%L, %L, auth.uid(), 'we talk about encrypted things')$q$, mid('acplain'), g('AC'))),
  'ok', 'another conversation (AC) still takes plain text');
reset role;
-- 7 delete_message on a ciphertext row -------------------------------------------
select as_('dee');
select is(try(ins(g('DE'), mid('D1'), ph(), ct(12), 1)), 'ok', 'dee sends ciphertext in DE');
select lives_ok(format('select public.delete_message(%L)', mid('D1')), 'dee deletes it');
reset role;
select is(col(mid('D1'), 'ciphertext'), '<null>', 'deleted: ciphertext is null');
select is(col(mid('D1'), 'olm_type'), '<null>', 'deleted: olm_type is null');
select is(col(mid('D1'), 'body'), '', 'deleted: body is empty');
select isnt(col(mid('D1'), 'deleted'), '<null>', 'deleted: deleted is set');

-- 8 edit_message_encrypted -------------------------------------------------------
-- fixtures only the superuser can shape: exact ages
insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type, created_at) values
  (mid('EOLD'), g('AB'), u('ann'), ph(), ct(10), 1, now() - interval '6 hours 1 second'),
  (mid('EIN'),  g('AB'), u('ann'), ph(), ct(10), 1, now() - interval '5 hours 59 minutes 59 seconds');
-- (A deleted row that still holds ciphertext cannot exist: messages_body_check
-- wants an empty body on a deleted row, the ciphertext check the placeholder.)
select function_privs_are('public', 'edit_message_encrypted', array['uuid', 'text', 'smallint'], 'anon',
  '{}'::text[], 'anon cannot execute edit_message_encrypted');
select as_('ann');
select is(enc(mid('E1'), ct(20, 'Z'), 1), ct(20, 'Z') || '|1|true|' || ph(),
  'ann edits her row: new ciphertext, olm_type 1, edited_at set, body unchanged');
select is(enc(mid('E2'), ct(20, 'Y'), 0), ct(20, 'Y') || '|0|true|' || ph(), 'and to olm_type 0');
select is(enc(mid('EIN'), ct(20, 'X'), 1), ct(20, 'X') || '|1|true|' || ph(), 'a row just inside 6 hours may be edited');
select is(enc(mid('EOLD'), ct(20, 'X'), 1), '42501', 'a row older than 6 hours -> 42501');
select is(enc(mid('abplain'), ct(20, 'X'), 1), '42501', 'a plain row -> 42501');
select is(enc(mid('EB'), ct(20, 'X'), 1), '42501', 'another member''s row -> 42501');
select is(enc(mid('EF'), ct(20, 'X'), 1), '42501', 'a forwarded row -> 42501');
select is(enc(mid('E3'), null, 1), '42501', 'null ciphertext -> 42501');
select is(enc(mid('E3'), '', 1), '42501', 'empty ciphertext -> 42501');
select is(enc(mid('E3'), ct(65537), 1), '42501', '65537 chars -> 42501');
select is(enc(mid('E3'), ct(10), null), '42501', 'olm_type null -> 42501');
select is(enc(mid('E3'), ct(10), 2), '42501', 'olm_type 2 -> 42501');
reset role;
select is(col(mid('E1'), 'ciphertext'), ct(20, 'Z'), 'the edit is stored');
select isnt(col(mid('E1'), 'edited_at'), '<null>', 'with edited_at');
select is(col(mid('E1'), 'link_preview'), '<null>', 'link guard: the edited row has no link preview');
select is(col(mid('E3'), 'ciphertext') || '|' || col(mid('E3'), 'olm_type') || '|' || col(mid('E3'), 'edited_at'),
  ct(10, 'C') || '|1|<null>', 'every refused edit left E3 untouched');
select is(col(mid('EB'), 'ciphertext'), ct(10, 'D'), 'bob''s row untouched');
select is(col(mid('abplain'), 'body') || '|' || col(mid('abplain'), 'ciphertext'), 'ab plain words|<null>',
  'the plain row untouched');
select as_('dee');
select is(enc(mid('D1'), ct(20, 'X'), 1), '42501', 'a deleted row -> 42501 (dee owns it)');
reset role;
-- a member who edits once, then leaves
select as_('fay');
select is(try(ins(g('FB'), mid('F1'), ph(), ct(10), 1)), 'ok', 'fay sends ciphertext in FB');
select is(enc(mid('F1'), ct(11), 1), ct(11) || '|1|true|' || ph(), 'fay edits it while a member');
reset role;
delete from public.conversation_members where conversation_id = g('FB') and user_id = u('fay');
select as_('fay');
select is(enc(mid('F1'), ct(12), 1), '42501', 'after leaving, fay''s edit -> 42501');
reset role;

-- 9 edit_message (plain) refuses ciphertext rows ------------------------------------
select as_('ann');
select throws_ok(format($q$select public.edit_message(%L, 'plain now')$q$, mid('E3')), '42501', null,
  'edit_message on a ciphertext row -> 42501');
select throws_ok(format('select public.edit_message(%L, %L)', mid('E3'), ph()), '42501', null,
  'edit_message with exactly the placeholder -> 42501');
select lives_ok(format($q$select public.edit_message(%L, 'we edited encrypted things')$q$, mid('acplain')),
  'edit_message on a plain row still works');
reset role;
select is(col(mid('E3'), 'ciphertext') || '|' || col(mid('E3'), 'body'), ct(10, 'C') || '|' || ph(),
  'E3 unchanged by edit_message');
select is(col(mid('acplain'), 'body'), 'we edited encrypted things', 'the plain edit is stored');

-- 10 link guard: an update on a ciphertext row ---------------------------------------
select lives_ok(format($q$update public.messages set ciphertext = 'QkJC', olm_type = 0 where id = %L$q$, mid('E3')),
  'an update on a ciphertext row works');
select is(col(mid('E3'), 'link_preview'), '<null>', 'and link_preview stays null');

-- 11 search never returns a ciphertext row -------------------------------------------
select as_('ann');
select ok((select count(*) from public.search_messages('encrypted', null) s where s.id = mid('acplain')) = 1,
  'control: a plain row matching "encrypted" is found');
select is((select count(*) from public.search_messages(q, c) s
            join public.messages m on m.id = s.id where m.ciphertext is not null), 0::bigint,
          format('search %L in %s returns no ciphertext row', q, coalesce(c::text, 'all chats')))
  from unnest(array['encrypted', 'Encrypted message', 'message', '🔒 Encrypted message']) q,
       unnest(array[null, g('AB')]) c;
reset role;

-- 12 push_targets: the encrypted column and the locked wording -------------------------
select is(right(pg_get_function_result('public.push_targets(uuid)'::regprocedure), 18), 'encrypted boolean)',
  'push_targets ends with encrypted boolean');
select is(right(pg_get_function_result('app_private.push_targets_for_message(uuid)'::regprocedure), 18),
  'encrypted boolean)', 'push_targets_for_message ends with encrypted boolean');
select as_('ann');
select is(try(ins(g('AB'), mid('P1'), ph(), ct(10), 1)), 'ok', 'ann: fresh ciphertext to bob (preview full)');
select is(try(ins(g('AG'), mid('P3'), ph(), ct(10), 1)), 'ok', 'ann: ciphertext to gus (preview sender)');
select is(try(ins(g('AH'), mid('P4'), ph(), ct(10), 1)), 'ok', 'ann: ciphertext to hal (preview none)');
select is(try(format($q$insert into public.messages(id, conversation_id, sender_id, body) values (%L, %L, auth.uid(), 'p2 words')$q$,
                     mid('P2'), g('AC'))), 'ok', 'ann: plain to cat');
reset role;
select is((select encrypted::text || '|' || body from app_private.push_targets_for_message(mid('P1')) where user_id = u('bob')),
  'true|' || ph(), 'ciphertext, preview full: encrypted true, the placeholder body');
select is((select encrypted::text || '|' || body from app_private.push_targets_for_message(mid('P3')) where user_id = u('gus')),
  'true|New message', 'ciphertext, preview sender: encrypted true, New message');
select is((select encrypted::text || '|' || coalesce(body, '<null>') from app_private.push_targets_for_message(mid('P4')) where user_id = u('hal')),
  'true|New message', 'ciphertext, preview none: encrypted true, New message');
select is((select encrypted from app_private.push_targets_for_message(mid('P2')) where user_id = u('cat')),
  false, 'a plain row: encrypted false');
select is((select encrypted from app_private.push_targets_for_message(mid('abplain')) where user_id = u('bob')),
  false, 'a plain row in an encrypted chat: encrypted false');
select ok((select body <> ph() from app_private.push_targets_for_message(mid('P2')) where user_id = u('cat')),
  'a plain row never gets the placeholder wording');
set local role service_role;
select is((select encrypted::text || '|' || body from public.push_targets(mid('P1')) where user_id = u('bob')),
  'true|' || ph(), 'public.push_targets: encrypted true for the ciphertext row');
select is((select encrypted from public.push_targets(mid('P2')) where user_id = u('cat')),
  false, 'public.push_targets: encrypted false for the plain row');
reset role;

-- 13 the notification reply (last: act_as leaves the acting member's claims set)
-- as the edge function calls it (service role)
create function na(n text, c uuid, id uuid) returns text language plpgsql as $$
begin
  return 'ok:' || public.notification_action(u(n), encode(extensions.digest('e5c-tok-' || n, 'sha256'), 'hex'),
                                              c, 'reply', id, 'a reply');
exception when others then return sqlstate;
end $$;
grant execute on function na(text, uuid, uuid) to service_role;
set local role service_role;
select is(na('bob', g('AB'), mid('nab')), '42501', 'a notification reply into encrypted AB -> 42501');
select alike(na('ann', g('AC'), mid('nac')), 'ok:%', 'control: the same reply into plain AC goes');
reset role;
select is((select count(*) from public.messages where id = mid('nab')), 0::bigint, 'and no reply row exists in AB');
select is((select count(*) from public.messages where id = mid('nac')), 1::bigint, 'while the AC reply was stored');

select * from finish();
rollback;
