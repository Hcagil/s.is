begin;
select plan(62);

-- Make your own sticker (20261018120000_sticker_maker.sql), written from the
-- contract:
--   public.create_sticker() -> uuid: security definer; a new row owned by the
--     caller; STKS1 once the caller owns 700 stickers; needs app access.
--   storage: an authenticated member with app access may insert
--     stickers/<uuid>.webp for a sticker row they own (not a starter).
--   public.discard_sticker(p_id uuid): security definer, search_path ''.
--     Deletes the row only if the caller owns it, it is not a starter, it is
--     in no album and it is not a favourite; a sticker used in a message stays
--     (messages.sticker_id is on delete restrict). Like create_sticker it
--     refuses a caller without app access (revoked session, not on the
--     allowlist, the bot) with 42501.
--
-- Each negative fixture fails ONE gate; a positive control sits next to it.
--   ann  the maker            bob  another member (G with ann)
--   dan  session revoked later  eve  removed from the allowlist later
--   bot  the SIS Bot account (allowlisted, active, switched ON)

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000005c3a' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@maker.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('04','dan'),('05','eve')) v(n, name);
insert into app_private.allowlist(email)
select name || '@maker.test' from unnest(array['ann','bob','dan','eve']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('5c3a0000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','04','05']) n;
insert into app_private.tag_finds(finder, found_id) values (u('01'), u('02'));
-- the bot, as the admin API creates it
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'sis-destek-bot@example.com', now(), '{"full_name":"SIS Destek"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());
insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then 'b07b0000-0000-0000-0000-000000000001'
                         else '5c3a0000-0000-0000-0000-0000000000' || n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
-- a new sticker as the caller: its id as text, or the sqlstate
create function mk() returns text language plpgsql as $$
declare r uuid;
begin r := public.create_sticker(); perform commit_check(); return r::text;
exception when others then return sqlstate; end $$;
create function discard(s uuid) returns text language plpgsql as $$
begin perform public.discard_sticker(s); perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
-- upload as the caller, owned by the caller, the way the Storage API does it
create function put(key text) returns text language plpgsql as $$
begin
  insert into storage.objects(bucket_id, name, owner_id, metadata)
  values ('stickers', key, auth.uid()::text, '{"size":3,"mimetype":"image/webp"}'::jsonb);
  return 'ok';
exception when others then return sqlstate; end $$;
-- has_app_access() as the caller sees it
create function access() returns boolean language sql security definer set search_path = '' as $$
  select app_private.has_app_access()
$$;
grant execute on function u(text), as_(text), as_anon(), commit_check(), try(text), mk(),
  discard(uuid), put(text) to authenticated, anon;
grant execute on function access() to authenticated;

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;
-- the truth, whatever RLS says (postgres only)
create function exists_(s uuid) returns boolean language sql security definer as $$
  select exists (select 1 from public.stickers where id = s)
$$;
create function owned(o uuid) returns bigint language sql security definer as $$
  select count(*) from public.stickers where owner_id = o
$$;

do $$
declare n text;
begin
  foreach n in array array['01','02','04','05','bot'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('01');
insert into ids values ('G', public.start_group_conversation('Makers', array[u('02')]));
select commit_check();
reset role;
-- the bot switched ON (most permissive), its Debug chat is G
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), g('G'), true);

-- 1 shape ----------------------------------------------------------------------
select is((select prosecdef from pg_proc where oid = 'public.create_sticker()'::regprocedure),
          true, 'create_sticker is security definer');
select is((select prosecdef from pg_proc where oid = 'public.discard_sticker(uuid)'::regprocedure),
          true, 'discard_sticker is security definer');
select is((select proconfig from pg_proc where oid = 'public.discard_sticker(uuid)'::regprocedure),
          array['search_path=""'], 'discard_sticker runs with an empty search_path');

-- 2 create_sticker ---------------------------------------------------------------
select as_('01');
insert into ids values ('A1', mk()::uuid), ('A2', mk()::uuid);
reset role;
select ok(g('A1') is not null and g('A2') is not null and g('A1') <> g('A2'),
          'create_sticker gives a new id each call');
select is((select owner_id from public.stickers where id = g('A1')), u('01'),
          'the new row belongs to the caller');
select is((select starter from public.stickers where id = g('A1')), false,
          'the new row is not a starter');
select as_anon();
select isnt(mk(), 'ok', 'anon cannot create a sticker');
select ok(mk() !~ '^[0-9a-f]{8}-', 'anon gets no id');
reset role;

-- the cap: 700 owned; starters and other members' stickers do not count
insert into public.stickers(id, owner_id)
select ('5c3b0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, u('01')
  from generate_series(1, 697) n;
select is(owned(u('01')), 699::bigint, 'fixture: ann owns 699');
insert into public.stickers(id, owner_id) select gen_random_uuid(), u('02') from generate_series(1, 5);
select as_('01');
insert into ids values ('A700', mk()::uuid);
reset role;
select is(owned(u('01')), 700::bigint, 'the 700th sticker is allowed');
select as_('01');
select is(mk(), 'STKS1', 'the 701st is refused with STKS1');
reset role;
select is(owned(u('01')), 700::bigint, 'and no row is left behind');
select as_('02');
select ok(mk() ~ '^[0-9a-f]{8}-', 'another member is not limited by ann''s count');
reset role;
-- discarding one frees a place again
select as_('01');
select is(discard(g('A700')), 'ok', 'ann discards one');
select ok(mk() ~ '^[0-9a-f]{8}-', 'then one more fits');
select is(mk(), 'STKS1', 'and the next is refused again');
reset role;
delete from public.stickers where owner_id = u('01') and id::text like '5c3b0000%';
select is(owned(u('01')), 3::bigint, 'fixture: ann back to 3 owned');

-- 3 discard_sticker: every condition alone -----------------------------------------
select as_('01');
insert into ids values ('CLEAN', mk()::uuid), ('ALB', mk()::uuid), ('FAV', mk()::uuid),
  ('SENT', mk()::uuid), ('OALB', mk()::uuid), ('OFAV', mk()::uuid);
reset role;
select as_('02');
insert into ids values ('BOBS', mk()::uuid);
reset role;
-- a starter row that ann owns: only the starter gate refuses it
insert into ids values ('STR', gen_random_uuid());
insert into public.stickers(id, owner_id, starter) values (g('STR'), u('01'), true);

select as_('01');
select is(discard(g('CLEAN')), 'ok', 'control: the owner discards a clean sticker');
reset role;
select is(exists_(g('CLEAN')), false, 'the clean sticker row is gone');

select as_('01');
do $$ begin perform discard(g('BOBS')); end $$;
reset role;
select is(exists_(g('BOBS')), true, 'someone else''s sticker stays');

select as_('01');
do $$ begin perform discard(g('STR')); end $$;
reset role;
select is(exists_(g('STR')), true, 'a starter stays, even one the caller owns');

select as_('01');
insert into ids values ('AL', public.create_sticker_album('Mine'));
select commit_check();
select is(try(format('select public.add_sticker_to_album(%L, %L)', g('AL'), g('ALB'))), 'ok',
          'fixture: sticker in ann''s album');
do $$ begin perform discard(g('ALB')); end $$;
reset role;
select is(exists_(g('ALB')), true, 'a sticker in an album stays');
select is((select count(*) from public.sticker_album_items where sticker_id = g('ALB')), 1::bigint,
          'and stays in its album');
select as_('01');
select is(try(format('select public.remove_sticker_from_album(%L, %L)', g('AL'), g('ALB'))), 'ok',
          'control: taken out of the album');
select is(discard(g('ALB')), 'ok', 'then it can be discarded');
reset role;
select is(exists_(g('ALB')), false, 'and its row is gone');

select as_('01');
select is(try(format('select public.add_sticker_favourite(%L)', g('FAV'))), 'ok',
          'fixture: ann''s favourite');
do $$ begin perform discard(g('FAV')); end $$;
reset role;
select is(exists_(g('FAV')), true, 'a favourite stays');
select as_('01');
select is(try(format('select public.remove_sticker_favourite(%L)', g('FAV'))), 'ok',
          'control: no longer a favourite');
select is(discard(g('FAV')), 'ok', 'then it can be discarded');
reset role;
select is(exists_(g('FAV')), false, 'and its row is gone');

-- in someone else's album / favourites (placed directly: only the "any album" rule refuses)
insert into ids values ('BAL', gen_random_uuid());
insert into public.sticker_albums(id, owner_id, name) values (g('BAL'), u('02'), 'Bob''s');
insert into public.sticker_album_items(album_id, sticker_id) values (g('BAL'), g('OALB'));
insert into public.sticker_favourites(user_id, sticker_id) values (u('02'), g('OFAV'));
select as_('01');
do $$ begin perform discard(g('OALB')); end $$;
do $$ begin perform discard(g('OFAV')); end $$;
reset role;
select is(exists_(g('OALB')), true, 'a sticker in another member''s album stays');
select is(exists_(g('OFAV')), true, 'a sticker in another member''s favourites stays');

-- used in a message
insert into storage.objects(bucket_id, name, owner_id, metadata)
values ('stickers', g('SENT') || '.webp', u('01')::text, '{"size":3}'::jsonb);
select as_('01');
insert into ids values ('MS', gen_random_uuid());
select is(try(format('select public.send_sticker(%L, %L, %L, null, false)', g('G'), g('MS'), g('SENT'))),
          'ok', 'fixture: the sticker is sent in G');
do $$ begin perform discard(g('SENT')); end $$;
reset role;
select is(exists_(g('SENT')), true, 'a sticker used in a message stays');
select is((select sticker_id from public.messages where id = g('MS')), g('SENT'),
          'and the message still shows it');

select as_anon();
select isnt(discard(g('BOBS')), 'ok', 'anon cannot call discard_sticker');
reset role;
select is(exists_(g('BOBS')), true, 'and nothing is deleted');

-- 4 storage: stickers/<uuid>.webp -------------------------------------------------
select as_('01');
insert into ids values ('UP', mk()::uuid), ('UP2', mk()::uuid);
select is(put(g('UP') || '.webp'), 'ok', 'control: the owner uploads <id>.webp');
select is(put(g('UP2') || '.png'), '42501', 'another extension is refused');
select is(put('x/' || g('UP2') || '.webp'), '42501', 'a folder is refused');
select is(put('sticker.webp'), '42501', 'a name that is not a uuid is refused');
select is(put(g('BOBS') || '.webp'), '42501', 'another member''s sticker id is refused');
select is(put(gen_random_uuid() || '.webp'), '42501', 'an id with no sticker row is refused');
select is(put(g('STR') || '.webp'), '42501', 'a starter id is refused, even one the caller owns');
reset role;
select as_anon();
select isnt(put(g('UP2') || '.webp'), 'ok', 'anon cannot upload');
reset role;

-- 5 no app access: revoked session, off the allowlist, the bot ---------------------
-- controls first: each still has access and can make and discard
select as_('04');
select is(access(), true, 'control: dan has app access');
insert into ids values ('D1', mk()::uuid), ('D2', mk()::uuid);
select is(discard(g('D1')), 'ok', 'control: dan discards his own clean sticker');
reset role;
select as_('05');
select is(access(), true, 'control: eve has app access');
insert into ids values ('E1', mk()::uuid);
reset role;
insert into ids values ('BT1', gen_random_uuid());
insert into public.stickers(id, owner_id) values (g('BT1'), u('bot'));
select as_('bot');
select is(access(), true, 'control: the bot itself has app access');
reset role;

delete from auth.sessions where id = '5c3a0000-0000-0000-0000-000000000004';
delete from app_private.allowlist where email = 'eve@maker.test';

select as_('04');
select is(mk(), '42501', 'a revoked session cannot create a sticker');
select is(put(g('D2') || '.webp'), '42501', 'nor upload one');
select is(discard(g('D2')), '42501', 'discard_sticker refuses a revoked session (42501)');
reset role;
select is(exists_(g('D2')), true, 'and the revoked member''s sticker stays');

select as_('05');
select is(mk(), '42501', 'a member off the allowlist cannot create a sticker');
select is(discard(g('E1')), '42501', 'discard_sticker refuses a member off the allowlist (42501)');
reset role;
select is(exists_(g('E1')), true, 'and that member''s sticker stays');

select as_('bot');
select is(mk(), '42501', 'the bot cannot create a sticker');
select is(put(g('BT1') || '.webp'), '42501', 'nor upload one');
select is(discard(g('BT1')), '42501', 'discard_sticker refuses the bot (42501)');
reset role;
select is(exists_(g('BT1')), true, 'and the bot''s sticker stays');

select * from finish();
rollback;
