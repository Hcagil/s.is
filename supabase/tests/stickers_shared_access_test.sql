begin;
select plan(31);

-- Stickers: who keeps access to a shared album (security gate rules, 2026-10-10).
--   a) A member who LEFT (or was removed from) a chat loses access to albums
--      shared there: no storage read of its stickers, album_stickers refused,
--      add_shared_album refused, no favouriting through the shared path.
--      Current members keep access and see stickers the owner adds later (live).
--      A sticker someone already saved to their own album or favourites stays.
--   b) Deleting a sticker row never deletes messages: messages.sticker_id does
--      not cascade.
--   c) A member added later without history reads an album shared before they
--      joined, while they are a current member.
--
--   ann  owner, shares album A into H     fay  member of H, stays
--   eve  member of H, favourites SQ2, then leaves
--   hal  member of H, copies A (add_shared_album), then leaves
--   ivy  member of H, removed by ann      gus  added to H later, without history

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000005c2c' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@stickershare.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','eve'),('03','fay'),('04','hal'),('05','ivy'),('06','gus')) v(n, name);
insert into app_private.allowlist(email)
select name || '@stickershare.test' from unnest(array['ann','eve','fay','hal','ivy','gus']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('5c200000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06']) n;
insert into app_private.tag_finds(finder, found_id)
select u('01'), u(n) from unnest(array['02','03','04','05','06']) n;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', '5c200000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
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
create function sees(s uuid) returns bigint language sql stable as $$
  select count(*) from storage.objects where bucket_id = 'stickers' and name = s || '.webp'
$$;
grant execute on function sees(uuid) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

insert into ids values
  ('SQ1', '5c2a0000-0000-0000-0000-000000000001'),  -- in A from the start
  ('SQ2', '5c2a0000-0000-0000-0000-000000000002'),  -- in A; eve favourites it
  ('SQ3', '5c2a0000-0000-0000-0000-000000000003'),  -- added to A after the share
  ('SM',  '5c2a0000-0000-0000-0000-000000000004'),  -- sent as a message, then its row deleted
  ('C',   '5c2c0000-0000-0000-0000-000000000001'),  -- the album card in H
  ('M',   '5c2e0000-0000-0000-0000-000000000001');  -- the sticker message of SM
insert into public.stickers(id, owner_id) values
  (g('SQ1'), u('01')), (g('SQ2'), u('01')), (g('SQ3'), u('01')), (g('SM'), u('01'));
insert into storage.objects(bucket_id, name, owner_id, metadata)
select 'stickers', s || '.webp', u('01'), '{"size":3}'::jsonb
  from unnest(array[g('SQ1'), g('SQ2'), g('SQ3'), g('SM')]) s;

select as_('01');
insert into ids values ('H', public.start_group_conversation('Share', array[u('02'), u('03'), u('04'), u('05')]));
select commit_check();
insert into ids values ('A', public.create_sticker_album('Live'));
select commit_check();
select public.add_sticker_to_album(g('A'), g('SQ1'));
select public.add_sticker_to_album(g('A'), g('SQ2'));
select public.send_sticker_album(g('H'), g('C'), g('A'));
select public.send_sticker(g('H'), g('M'), g('SM'));
select commit_check();
reset role;

-- before anyone leaves ---------------------------------------------------------
select as_('02');
select is(sees(g('SQ1')), 1::bigint, 'eve, a member, reads a shared sticker');
select is(try(format('select public.add_sticker_favourite(%L)', g('SQ2'))), 'ok', 'eve saves SQ2 to her favourites');
reset role;
select as_('04');
insert into ids values ('HA', public.add_shared_album(g('A')));
select commit_check();
reset role;
select is((select count(*) from public.sticker_album_items where album_id = g('HA')), 2::bigint, 'hal copies the album');

-- they leave / are removed --------------------------------------------------------
select as_('02'); select public.leave_group(g('H')); select commit_check(); reset role;
select as_('04'); select public.leave_group(g('H')); select commit_check(); reset role;
select as_('01'); select public.remove_member(g('H'), u('05')); select commit_check(); reset role;
select is((select count(*) from public.conversation_members where conversation_id = g('H') and left_at is not null),
          3::bigint, 'fixture: eve and hal left, ivy was removed');

-- a) the member who left loses the shared path ------------------------------------
select as_('02');
select is(sees(g('SQ1')), 0::bigint, 'eve, gone, no longer reads the shared album''s sticker file');
select isnt(try(format('select public.album_stickers(%L)', g('A'))), 'ok', 'album_stickers is refused to eve');
select isnt(try(format('select public.add_shared_album(%L)', g('A'))), 'ok', 'add_shared_album is refused to eve');
select isnt(try(format('select public.add_shared_album_to_favourites(%L)', g('A'))), 'ok', 'add_shared_album_to_favourites is refused to eve');
select isnt(try(format('select public.add_sticker_favourite(%L)', g('SQ1'))), 'ok', 'eve cannot favourite SQ1 through the shared path');
select is(sees(g('SQ2')), 1::bigint, 'but SQ2, already in her favourites, stays readable');
select is((select count(*) from public.sticker_favourites where user_id = u('02') and sticker_id = g('SQ2')), 1::bigint,
          'and stays in her favourites');
reset role;
select as_('04');
select is((select count(*) from public.sticker_album_items where album_id = g('HA')), 2::bigint, 'hal''s copied album keeps its stickers');
select is(sees(g('SQ1')), 1::bigint, 'and hal still reads them');
reset role;
select as_('05');
select is(sees(g('SQ1')), 0::bigint, 'ivy, removed, no longer reads the shared sticker file');
select isnt(try(format('select public.album_stickers(%L)', g('A'))), 'ok', 'album_stickers is refused to ivy');
reset role;

-- current members: live, not a snapshot --------------------------------------------
select as_('01');
select public.add_sticker_to_album(g('A'), g('SQ3'));
select commit_check();
reset role;
select as_('03');
select is(sees(g('SQ1')), 1::bigint, 'fay, still a member, reads the shared sticker');
select is(sees(g('SQ3')), 1::bigint, 'and the sticker the owner added after sharing');
select is(val(format('select count(*) from public.album_stickers(%L)', g('A'))), '3', 'album_stickers shows all three to fay');
reset role;
select as_('02');
select is(sees(g('SQ3')), 0::bigint, 'eve, gone, does not read the later sticker');
reset role;

-- c) a member added later without history ---------------------------------------
-- one transaction shares one now(): age the card so it is older than gus's joining
update public.messages set created_at = now() - interval '1 hour' where id in (g('C'), g('M'));
select as_('01');
select public.add_members(g('H'), array[u('06')], false);
select commit_check();
reset role;
select as_('06');
select is(sees(g('SQ1')), 1::bigint, 'gus, added later without history, reads the album shared before he joined');
select is(val(format('select count(*) from public.album_stickers(%L)', g('A'))), '3', 'album_stickers shows him all three');
select isnt(try(format('select public.add_shared_album(%L)', g('A'))), '42501', 'and he may add the album');
reset role;

-- b) deleting a sticker row keeps its messages --------------------------------------
select isnt((select confdeltype::text from pg_constraint
              where conrelid = 'public.messages'::regclass and contype = 'f'
                and conkey = array[(select attnum from pg_attribute
                                     where attrelid = 'public.messages'::regclass and attname = 'sticker_id')]),
            'c', 'messages.sticker_id does not cascade on delete');
do $$ begin perform try(format('delete from public.stickers where id = %L', g('SM'))); end $$;
select is((select count(*) from public.messages where id = g('M')), 1::bigint,
          'deleting a sticker row (or trying to) leaves its message in place');

-- b2) the sticker row itself is protected while a message uses it, and an account
--     deletion keeps the sticker (owner cleared) instead of cascading or failing
select is((select confdeltype::text from pg_constraint
            where conrelid = 'public.messages'::regclass and contype = 'f'
              and conkey = array[(select attnum from pg_attribute
                                   where attrelid = 'public.messages'::regclass and attname = 'sticker_id')]),
          'r', 'messages.sticker_id is ON DELETE RESTRICT');
select is(try(format('delete from public.stickers where id = %L', g('SM'))), '23503',
          'a sticker a message still uses cannot be deleted');
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
values (u('07'), 'zed@stickershare.test', now(), '{"full_name":"Zed"}'::jsonb);
insert into ids values ('SZ', '5c2a0000-0000-0000-0000-000000000007');
insert into public.stickers(id, owner_id) values (g('SZ'), u('07'));
select is(try(format('delete from auth.users where id = %L', u('07'))), 'ok',
          'an account that owns a sticker can be deleted');
select is((select coalesce(owner_id::text, '<null>') from public.stickers where id = g('SZ')), '<null>',
          'its sticker stays, with no owner');

-- security re-gate N1: an owner-less sticker is NOT a starter sticker
insert into storage.objects(bucket_id, name, owner_id, metadata)
values ('stickers', g('SZ') || '.webp', null, '{"size":3}'::jsonb);
select as_('06');
select is(sees(g('SZ')), 0::bigint,
          'N1: a deleted account''s sticker file stays unreadable to an unrelated member');
reset role;  -- the claims stay; call the gate function as its owner would
select is(app_private.can_read_sticker(g('SZ')), false,
          'N1: can_read_sticker is false for a deleted account''s sticker');
select is(app_private.can_read_sticker('5151c000-0000-4000-8000-000000000001'), true,
          'a SIS starter sticker stays readable to every member');

select * from finish();
rollback;
