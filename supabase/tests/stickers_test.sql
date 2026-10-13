begin;
select plan(144);

-- Stickers (20261017120000_stickers.sql), written from the contract:
--   create_sticker_album(p_name) -> uuid, rename_sticker_album(p_album, p_name),
--   delete_sticker_album(p_album), add_sticker_to_album(p_album, p_sticker),
--   remove_sticker_from_album(p_album, p_sticker), add_sticker_favourite(p_sticker),
--   remove_sticker_favourite(p_sticker), album_stickers(p_album) -> setof uuid,
--   add_shared_album(p_album) -> uuid, add_shared_album_to_favourites(p_album) -> int,
--   send_sticker(p_conversation, p_id, p_sticker, p_reply_to, p_forwarded),
--   send_sticker_album(p_conversation, p_id, p_album).
--   Limits in BEFORE INSERT triggers: STKA1 11th album, STKA2 51st sticker in
--   an album, STKF1 201st favourite. Only the owner edits albums/favourites.
--   A sticker is readable (storage too) by its owner, members of a chat it was
--   sent in, members of a chat its album was shared to. Starters
--   5151c000-0000-4000-8000-0000000000NN (01..16) exist and need no object.
--   Push text: '😀 Sticker' / '📂 Sticker album'.
--
-- Each negative fixture fails ONE gate; a valid call next to it is the control.
--   ann  owner of albums, member of G (with bob, dan) and of H (with eve)
--   bob  member of G          cat  member of nothing ann is in (K with bob)
--   dan  member of G, session revoked later (no app access)
--   eve  member of H only, where ann shares an album

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000005c1c' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@stickers.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve')) v(n, name);
insert into app_private.allowlist(email)
select name || '@stickers.test' from unnest(array['ann','bob','cat','dan','eve']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('5c100000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('01'), u('02')), (u('01'), u('04')), (u('01'), u('05')), (u('02'), u('03'));

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', '5c100000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
-- the first column of the first row, or the sqlstate
create function val(q text) returns text language plpgsql as $$
declare r text;
begin execute q into r; perform commit_check(); return coalesce(r, '<null>');
exception when others then return sqlstate; end $$;
grant execute on function u(text), as_(text), commit_check(), try(text), val(text) to authenticated, anon;

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('02');
select public.register_device_token('bob-stickers-token', 'android');
reset role;

select as_('01');
insert into ids values ('G', public.start_group_conversation('Stickers', array[u('02'), u('04')]));
select commit_check();
insert into ids values ('H', public.start_group_conversation('Shared', array[u('05')]));
select commit_check();
reset role;
select as_('02');
insert into ids values ('K', public.start_group_conversation('Bob and cat', array[u('03')]));
select commit_check();
reset role;

-- system chat (ann is its member; only the system rule refuses)
select as_('01'); do $$ begin perform public.deliver_release_notes(179); end $$; reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;

-- text messages to reply to
select as_('01');
with m as (insert into public.messages(conversation_id, sender_id, body) values (g('G'), u('01'), 'hello G') returning id)
insert into ids select 'TXT_G', id from m;
with m as (insert into public.messages(conversation_id, sender_id, body) values (g('H'), u('01'), 'hello H') returning id)
insert into ids select 'TXT_H', id from m;
reset role;

-- the stickers: 10a has no upload, so the owner's rows and objects are fixtures
insert into ids values
  ('SA', '5c1a0000-0000-0000-0000-000000000001'),  -- ann's, sent in G
  ('SB', '5c1a0000-0000-0000-0000-000000000002'),  -- bob's, never sent
  ('SP', '5c1a0000-0000-0000-0000-000000000003'),  -- ann's, never sent, never shared
  ('SQ', '5c1a0000-0000-0000-0000-000000000004'),  -- ann's, only in an album shared to H
  ('ST', '5151c000-0000-4000-8000-000000000001'),  -- starter 01
  ('ST16', '5151c000-0000-4000-8000-000000000016'); -- starter 16
insert into public.stickers(id, owner_id) values
  (g('SA'), u('01')), (g('SB'), u('02')), (g('SP'), u('01')), (g('SQ'), u('01'));
-- 60 more of ann's for the album limit, 205 for the favourite limit
insert into public.stickers(id, owner_id)
select ('5c1b0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, u('01') from generate_series(1, 60) n;
insert into public.stickers(id, owner_id)
select ('5c1f0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, u('01') from generate_series(1, 205) n;
create function sb(n int) returns uuid language sql immutable as $$
  select ('5c1b0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function sf(n int) returns uuid language sql immutable as $$
  select ('5c1f0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function sb(int), sf(int) to authenticated;

insert into storage.objects(bucket_id, name, owner_id, metadata)
select 'stickers', s || '.webp', o, '{"size":3}'::jsonb
  from (values (g('SA'), u('01')), (g('SB'), u('02')), (g('SP'), u('01')), (g('SQ'), u('01'))) v(s, o);

-- the reader's view of the bucket
create function sees(s uuid) returns bigint language sql stable as $$
  select count(*) from storage.objects where bucket_id = 'stickers' and name = s || '.webp'
$$;
grant execute on function sees(uuid) to authenticated, anon;
create function msg_col(id uuid, col text) returns text language plpgsql stable security definer as $$
declare r text;
begin execute format('select %I::text from public.messages where id = %L', col, id) into r;
      return coalesce(r, '<null>'); end $$;
grant execute on function msg_col(uuid, text) to authenticated, anon;

select ok(g('SYS') is not null, 'fixture: ann has a system chat');
select is((select count(*) from public.stickers where id::text like '5151c000-0000-4000-8000-0000000000%' and owner_id is null),
          16::bigint, 'the sixteen starter rows exist, with no owner');
select is((select count(*) from storage.objects where bucket_id = 'stickers' and name like '5151c000%'),
          0::bigint, 'starters have no bucket objects');
select is((select public from storage.buckets where id = 'stickers'), false, 'the stickers bucket is private');

-- 1 grants: no client writes a sticker table ------------------------------------
select ok(not has_table_privilege('authenticated', 'public.stickers', 'INSERT'), 'no client inserts stickers');
select ok(not has_table_privilege('authenticated', 'public.sticker_albums', 'INSERT'), 'no client inserts albums');
select ok(not has_table_privilege('authenticated', 'public.sticker_albums', 'UPDATE'), 'no client updates albums');
select ok(not has_table_privilege('authenticated', 'public.sticker_albums', 'DELETE'), 'no client deletes albums');
select ok(not has_table_privilege('authenticated', 'public.sticker_album_items', 'INSERT'), 'no client inserts album items');
select ok(not has_table_privilege('authenticated', 'public.sticker_favourites', 'INSERT'), 'no client inserts favourites');
select ok(not has_table_privilege('authenticated', 'public.sticker_favourites', 'DELETE'), 'no client deletes favourites');
select ok(not has_column_privilege('authenticated', 'public.messages', 'sticker_id', 'INSERT'), 'no client inserts messages.sticker_id');
select ok(not has_column_privilege('authenticated', 'public.messages', 'sticker_album', 'INSERT'), 'no client inserts messages.sticker_album');
select ok(not has_column_privilege('authenticated', 'public.messages', 'sticker_album_id', 'INSERT'), 'no client inserts messages.sticker_album_id');
select ok(not has_function_privilege('anon', 'public.create_sticker_album(text)', 'EXECUTE'), 'anon cannot create albums');
select ok(not has_function_privilege('anon', 'public.send_sticker(uuid, uuid, uuid, uuid, boolean)', 'EXECUTE'), 'anon cannot send stickers');

-- 2 albums: only the owner edits ---------------------------------------------------
select as_('01');
insert into ids values ('A', public.create_sticker_album('Mine'));
select commit_check();
reset role;
select is((select owner_id from public.sticker_albums where id = g('A')), u('01'), 'ann creates an album she owns');
select is((select name from public.sticker_albums where id = g('A')), 'Mine', 'with its name');
select as_('01');
select is((select count(*) from public.sticker_albums where id = g('A')), 1::bigint, 'ann reads her album');
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A'), g('SA'))), 'ok', 'ann adds her own sticker');
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A'), g('ST'))), 'ok', 'and a starter');
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A'), g('SB'))), '42501',
          'but not bob''s sticker she cannot read (her own album: only the read gate refuses)');
select is((select count(*) from public.sticker_album_items where album_id = g('A')), 2::bigint, 'ann reads her two album items');
select is(val(format('select count(*) from public.album_stickers(%L)', g('A'))), '2', 'album_stickers lists both for ann');
select is(try(format('select public.rename_sticker_album(%L, %L)', g('A'), 'Renamed')), 'ok', 'ann renames her album');
reset role;
select is((select name from public.sticker_albums where id = g('A')), 'Renamed', 'the rename is stored');

select as_('02');
select is((select count(*) from public.sticker_albums where id = g('A')), 0::bigint, 'bob does not read ann''s album');
select is((select count(*) from public.sticker_album_items where album_id = g('A')), 0::bigint, 'nor its items');
select is(try(format('select public.rename_sticker_album(%L, %L)', g('A'), 'Bobs')), '42501', 'bob cannot rename it');
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A'), g('SB'))), '42501',
          'bob cannot add his own sticker to ann''s album (only the owner gate refuses)');
select is(try(format('select public.remove_sticker_from_album(%L, %L)', g('A'), g('SA'))), '42501', 'bob cannot remove from it');
select is(try(format('select public.delete_sticker_album(%L)', g('A'))), '42501', 'bob cannot delete it');
select isnt(val(format('select count(*) from public.album_stickers(%L)', g('A'))), '2', 'album_stickers does not list a private album to bob');
select is(try('update public.sticker_albums set name = ''x'''), '42501', 'a direct update is refused');
select is(try(format('insert into public.sticker_albums(owner_id, name) values (%L, ''x'')', u('02'))), '42501', 'a direct insert is refused');
reset role;
select is((select name from public.sticker_albums where id = g('A')), 'Renamed', 'ann''s album is unchanged');
select is((select count(*) from public.sticker_album_items where album_id = g('A')), 2::bigint, 'with both items');

-- bad names (whatever code, never a row)
select as_('01');
select isnt(try('select public.create_sticker_album('''')'), 'ok', 'an empty name is refused');
select isnt(try(format('select public.create_sticker_album(%L)', repeat('a', 41))), 'ok', 'a 41-character name is refused');
select isnt(try(format('select public.rename_sticker_album(%L, %L)', g('A'), '')), 'ok', 'renaming to empty is refused');
reset role;

-- 3 favourites -----------------------------------------------------------------------
select as_('01');
select is(try(format('select public.add_sticker_favourite(%L)', g('SP'))), 'ok', 'ann favourites her own sticker');
select is(try(format('select public.add_sticker_favourite(%L)', g('ST'))), 'ok', 'and a starter');
select is((select count(*) from public.sticker_favourites where user_id = u('01')), 2::bigint, 'ann reads her two favourites');
reset role;
select as_('02');
select is(try(format('select public.add_sticker_favourite(%L)', g('SP'))), '42501', 'bob cannot favourite a sticker he cannot read');
select is((select count(*) from public.sticker_favourites where user_id = u('01')), 0::bigint, 'bob does not read ann''s favourites');
select is(try(format('select public.remove_sticker_favourite(%L)', g('SP'))), 'ok', 'bob removing a favourite only touches his own');
select is(try(format('delete from public.sticker_favourites where user_id = %L', u('01'))), '42501', 'a direct delete is refused');
reset role;
select is((select count(*) from public.sticker_favourites where user_id = u('01')), 2::bigint, 'ann still has both favourites');
select as_('01');
select is(try(format('select public.remove_sticker_favourite(%L)', g('ST'))), 'ok', 'ann removes one');
reset role;
select is((select count(*) from public.sticker_favourites where user_id = u('01')), 1::bigint, 'and it is gone');

-- 4 reading a sticker: owner, chat member, shared-album member ----------------------
select as_('01');
select is(sees(g('SA')), 1::bigint, 'the owner reads her sticker''s file');
select is(sees(g('SP')), 1::bigint, 'the owner reads her unsent sticker''s file');
reset role;
select as_('02');
select is(sees(g('SA')), 0::bigint, 'bob does not read ann''s sticker before it is sent');
select is(sees(g('SB')), 1::bigint, 'bob reads his own');
reset role;

-- 5 sending ------------------------------------------------------------------------------
insert into ids values
  ('M1', '5c1e0000-0000-0000-0000-000000000001'),  -- ann's SA in G
  ('M2', '5c1e0000-0000-0000-0000-000000000002'),  -- a reply, starter
  ('M3', '5c1e0000-0000-0000-0000-000000000003'),  -- a forward
  ('MX', '5c1e0000-0000-0000-0000-000000000009'),  -- spare id for refusals
  ('MD', '5c1e0000-0000-0000-0000-00000000000d'),  -- deleted
  ('C1', '5c1c0000-0000-0000-0000-000000000001'),  -- album card in H
  ('CX', '5c1c0000-0000-0000-0000-000000000009');  -- spare card id
create function ss(c uuid, id uuid, s uuid, r uuid default null, f boolean default false) returns text language sql as $$
  select try(format('select public.send_sticker(%L, %L, %L, %L, %L)', c, id, s, r, f))
$$;
create function sa(c uuid, id uuid, a uuid) returns text language sql as $$
  select try(format('select public.send_sticker_album(%L, %L, %L)', c, id, a))
$$;
grant execute on function ss(uuid, uuid, uuid, uuid, boolean), sa(uuid, uuid, uuid) to authenticated, anon;

select as_('01');
select is(ss(g('G'), g('M1'), g('SA')), 'ok', 'ann sends her sticker to G');
reset role;
select is(msg_col(g('M1'), 'body'), '', 'a sticker message has an empty body');
select is(msg_col(g('M1'), 'sticker_id'), g('SA')::text, 'and carries the sticker id');
select is(msg_col(g('M1'), 'sender_id'), u('01')::text, 'sent as the caller');
select as_('01');
select is(ss(g('G'), g('M1'), g('SA')), 'ok', 'the same id again is a harmless retry');
reset role;
select is((select count(*) from public.messages where id = g('M1')), 1::bigint, 'and leaves one row');
select as_('02');
select isnt(ss(g('G'), g('M1'), g('ST')), 'ok', 'another member reusing the id is refused');
select is(sees(g('SA')), 1::bigint, 'bob, a member of G, now reads the sent sticker''s file');
select is(try(format('select public.add_sticker_favourite(%L)', g('SA'))), 'ok', 'and may favourite it');
reset role;
select as_('03');
select is(sees(g('SA')), 0::bigint, 'cat, not in G, does not read it');
select is(try(format('select public.add_sticker_favourite(%L)', g('SA'))), '42501', 'nor favourite it');
reset role;
set local role anon;
select is(sees(g('SA')), 0::bigint, 'anon does not read it');
reset role;

-- who may send (a starter, so only the gate under test differs)
select as_('03');
select is(ss(g('G'), g('MX'), g('ST')), '42501', 'a non-member is refused');
reset role;
select as_('01');
select is(ss(g('SYS'), g('MX'), g('ST')), '42501', 'nobody sends into the system chat');
select is(ss(g('G'), g('MX'), g('SB')), '42501', 'a sticker the sender cannot read is refused');
select is(ss(g('G'), g('MX'), g('ST'), g('TXT_H')), '42501', 'a reply target outside the chat is refused');
reset role;
select is((select count(*) from public.messages where id = g('MX')), 0::bigint, 'no refused call stored a row');

select as_('02');
select is(ss(g('G'), g('M2'), g('ST16'), g('TXT_G')), 'ok', 'bob replies with a starter');
select is(ss(g('K'), g('M3'), g('SA'), null, true), 'ok', 'bob forwards ann''s sticker into K');
reset role;
select is(msg_col(g('M2'), 'reply_to'), g('TXT_G')::text, 'the reply is stored');
select is(msg_col(g('M3'), 'forwarded'), 'true', 'the forward is marked');
select is(msg_col(g('M2'), 'forwarded'), 'false', 'a plain send is not');
select as_('03');
select is(sees(g('SA')), 1::bigint, 'cat now reads it, through the chat it was forwarded to');
reset role;

-- frozen body, edit, delete
select as_('01');
select isnt(try(format('select public.edit_message(%L, ''x'')', g('M1'))), 'ok', 'edit_message refuses a sticker');
select isnt(try(format('insert into public.messages(conversation_id, sender_id, body, sticker_id) values (%L, %L, '''', %L)',
                g('G'), u('01'), g('ST'))), 'ok', 'a direct insert with a sticker id is refused');
reset role;
do $$ begin perform try(format('update public.messages set body = ''changed'' where id = %L', g('M1'))); end $$;
select is(msg_col(g('M1'), 'body'), '', 'the body stays empty, even for the owner role');
select as_('01');
select is(ss(g('G'), g('MD'), g('ST')), 'ok', 'fixture: a sticker to delete');
select is(try(format('select public.delete_message(%L)', g('MD'))), 'ok', 'the sender deletes it for everyone');
reset role;
select is(msg_col(g('MD'), 'sticker_id'), '<null>', 'deleting clears the sticker id');

-- revoked session: dan is a member of G
delete from auth.sessions where id = '5c100000-0000-0000-0000-000000000004';
select as_('04');
select is(ss(g('G'), g('MX'), g('ST')), '42501', 'a member whose session was revoked cannot send');
select is(sees(g('SA')), 0::bigint, 'nor read the sticker file');
select isnt(try('select public.create_sticker_album(''Dan'')'), 'ok', 'nor create an album');
reset role;

-- 6 shared albums ---------------------------------------------------------------------
select as_('01');
insert into ids values ('A2', public.create_sticker_album('Shared one'));
select commit_check();
insert into ids values ('AE', public.create_sticker_album('Empty'));
select commit_check();
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A2'), g('SQ'))), 'ok', 'fixture: SQ in the album to share');
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A2'), g('ST'))), 'ok', 'fixture: and a starter');
reset role;
select as_('05');
select is(sees(g('SQ')), 0::bigint, 'eve does not read SQ before the album is shared');
select is(try(format('select public.add_shared_album(%L)', g('A2'))), '42501', 'nor add the album');
reset role;

select as_('01');
select isnt(sa(g('H'), g('CX'), g('AE')), 'ok', 'an empty album cannot be shared');
reset role;
select as_('02');
select is(sa(g('G'), g('CX'), g('A2')), '42501', 'bob cannot share ann''s album, though in G');
reset role;
select as_('01');
select is(sa(g('H'), g('C1'), g('A2')), 'ok', 'ann shares her album into H');
select is(sa(g('H'), g('C1'), g('A2')), 'ok', 'the retry is harmless');
reset role;
select is((select count(*) from public.messages where id = g('C1')), 1::bigint, 'one card row');
select is(msg_col(g('C1'), 'body'), 'Shared one', 'the card''s body is the album''s name');
select is(msg_col(g('C1'), 'sticker_album'), 'true', 'it is marked as an album card');
select is(msg_col(g('C1'), 'sticker_album_id'), g('A2')::text, 'and points at the album');

select as_('05');
select is(sees(g('SQ')), 1::bigint, 'eve, a member of H, now reads SQ');
select is(val(format('select count(*) from public.album_stickers(%L)', g('A2'))), '2', 'album_stickers lists the shared album to eve');
insert into ids values ('EA', public.add_shared_album(g('A2')));
select commit_check();
reset role;
select is((select owner_id from public.sticker_albums where id = g('EA')), u('05'), 'add_shared_album makes eve her own album');
select is((select name from public.sticker_albums where id = g('EA')), 'Shared one', 'with the same name');
select is((select count(*) from public.sticker_album_items where album_id = g('EA')), 2::bigint, 'and the same stickers');
select as_('05');
select is(val(format('select public.add_shared_album_to_favourites(%L)', g('A2'))), '2', 'add to favourites returns how many were added');
select is((select count(*) from public.sticker_favourites where user_id = u('05')), 2::bigint, 'and eve has them');
reset role;
select as_('03');
select is(sees(g('SQ')), 0::bigint, 'cat, not in H, does not read SQ');
select is(try(format('select public.add_shared_album(%L)', g('A2'))), '42501', 'nor add the album');
select is(try(format('select public.add_shared_album_to_favourites(%L)', g('A2'))), '42501', 'nor its stickers to favourites');
select isnt(val(format('select count(*) from public.album_stickers(%L)', g('A2'))), '2', 'nor list it');
reset role;

select as_('01');
select is(try(format('select public.delete_sticker_album(%L)', g('A2'))), 'ok', 'ann deletes the shared album');
reset role;
select is((select count(*) from public.sticker_albums where id = g('A2')), 0::bigint, 'it is gone');
select is(msg_col(g('C1'), 'sticker_album_id'), '<null>', 'the card no longer points at it');
select is(msg_col(g('C1'), 'body'), 'Shared one', 'but keeps its name');
select is((select count(*) from public.sticker_album_items where album_id = g('EA')), 2::bigint, 'eve''s copy keeps its stickers');

-- 7 the limits -----------------------------------------------------------------------
-- ann has A, AE (A2 deleted): eight more make ten
select as_('01');
do $$ begin for i in 1..8 loop perform public.create_sticker_album('L' || i); end loop; end $$;
reset role;
select is((select count(*) from public.sticker_albums where owner_id = u('01')), 10::bigint, 'ann has ten albums');
select as_('01');
select is(try('select public.create_sticker_album(''Eleventh'')'), 'STKA1', 'the eleventh album is STKA1');
reset role;
select is(try(format('insert into public.sticker_albums(owner_id, name) values (%L, ''Bypass'')', u('01'))), 'STKA1',
          'the table refuses the eleventh even without the function');
select as_('02');
select is(try('select public.create_sticker_album(''Bob first'')'), 'ok', 'bob''s albums are counted apart');
reset role;
select as_('05');
do $$ begin for i in 1..9 loop perform public.create_sticker_album('E' || i); end loop; end $$;
reset role;
select is((select count(*) from public.sticker_albums where owner_id = u('05')), 10::bigint, 'eve has ten albums');
select as_('01');
select is(sa(g('H'), gen_random_uuid(), g('A')), 'ok', 'fixture: ann shares A into H');
reset role;
select as_('05');
select is(try(format('select public.add_shared_album(%L)', g('A'))), 'STKA1', 'adding a shared album as the eleventh is STKA1');
reset role;
select as_('01');
select is(try(format('select public.delete_sticker_album(%L)', g('AE'))), 'ok', 'ann deletes one album');
select is(try('select public.create_sticker_album(''Again'')'), 'ok', 'and may create one again');
reset role;

-- STKA2: album A holds SA and ST; 48 more make fifty
select as_('01');
do $$ begin for i in 1..48 loop perform public.add_sticker_to_album(g('A'), sb(i)); end loop; end $$;
reset role;
select is((select count(*) from public.sticker_album_items where album_id = g('A')), 50::bigint, 'album A holds fifty');
select as_('01');
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A'), sb(49))), 'STKA2', 'the fifty-first is STKA2');
reset role;
select is(try(format('insert into public.sticker_album_items(album_id, sticker_id) values (%L, %L)', g('A'), sb(50))), 'STKA2',
          'the table refuses the fifty-first even without the function');
select as_('01');
select is(try(format('select public.add_sticker_to_album((select id from public.sticker_albums where owner_id = %L and name = ''L1''), %L)',
                u('01'), sb(49))), 'ok', 'another album is counted apart');
select is(try(format('select public.remove_sticker_from_album(%L, %L)', g('A'), sb(1))), 'ok', 'ann removes one from A');
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('A'), sb(49))), 'ok', 'and may add again');
reset role;

-- STKF1: ann has SP; 199 more make two hundred
select as_('01');
do $$ begin for i in 1..199 loop perform public.add_sticker_favourite(sf(i)); end loop; end $$;
reset role;
select is((select count(*) from public.sticker_favourites where user_id = u('01')), 200::bigint, 'ann has two hundred favourites');
select as_('01');
select is(try(format('select public.add_sticker_favourite(%L)', sf(200))), 'STKF1', 'the two hundred and first is STKF1');
reset role;
select is(try(format('insert into public.sticker_favourites(user_id, sticker_id) values (%L, %L)', u('01'), sf(201))), 'STKF1',
          'the table refuses it even without the function');
select as_('02');
select is(try(format('select public.add_sticker_favourite(%L)', g('ST16'))), 'ok', 'bob''s favourites are counted apart');
reset role;
select as_('01');
select is(try(format('select public.remove_sticker_favourite(%L)', sf(1))), 'ok', 'ann removes one favourite');
select is(try(format('select public.add_sticker_favourite(%L)', sf(200))), 'ok', 'and may add again');
reset role;

-- 8 previews and the push ------------------------------------------------------------
update public.messages set created_at = now() - interval '1 minute' where conversation_id in (g('G'), g('H'));
insert into ids values ('MP', '5c1e0000-0000-0000-0000-0000000000a1'), ('CP', '5c1c0000-0000-0000-0000-0000000000a1');
select as_('01');
select is(ss(g('G'), g('MP'), g('ST')), 'ok', 'fixture: a sticker as G''s newest message');
select is((select sticker_id from public.conversation_previews where conversation_id = g('G')), g('ST'),
          'the chat list preview carries the sticker id');
select is((select sticker_album from public.conversation_previews where conversation_id = g('G')), false,
          'and is not an album card');
reset role;
select is((select string_agg(body, ',') from app_private.push_targets_for_message(g('MP')) where user_id = u('02')),
          E'\U0001F600 Sticker', 'the push of a sticker reads 😀 Sticker');
-- one transaction, one now(): age the sticker so the card is the newest
update public.messages set created_at = now() - interval '30 seconds' where id = g('MP');
select as_('01');
select is(sa(g('G'), g('CP'), g('A')), 'ok', 'fixture: an album card as G''s newest message');
select is((select sticker_album from public.conversation_previews where conversation_id = g('G')), true,
          'the preview marks the album card');
select is((select sticker_id from public.conversation_previews where conversation_id = g('G')), null::uuid,
          'with no sticker id');
reset role;
select is((select string_agg(body, ',') from app_private.push_targets_for_message(g('CP')) where user_id = u('02')),
          E'\U0001F4C2 Sticker album', 'the push of an album card reads 📂 Sticker album');
select is((select count(*) from app_private.push_targets_for_message(g('CP')) where user_id = u('01')), 0::bigint,
          'the sender gets no push');

select * from finish();
rollback;
