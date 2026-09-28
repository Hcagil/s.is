begin;
select plan(86);

-- Profile picture privacy (v0.22.0).
--
-- Contract (docs/SECURITY.md, docs/DECISIONS.md 2026-09-28):
--   avatar_visible_to(owner): the owner always; otherwise the owner must be
--     allowlisted and either 'everyone' and (the reader can reach the owner OR
--     the owner saved the reader), or 'contacts' and the owner saved the
--     reader; 'nobody' is the owner only. The reader needs app access.
--   It is enforced on every channel that can hand out the picture:
--     profiles_public()  -- the row rule of profiles, path masked;
--     find_by_tag()      -- its single row, path masked;
--     profiles.avatar_path -- the legacy copy: the real path only while the
--                           owner's setting is 'everyone', else null;
--     storage avatars read -- the object itself.
--   Clients cannot select avatar_object or avatar_visibility; the owner reads
--   them through own_profile(). An old build's write to avatar_path is mapped
--   onto avatar_object under the same folder pin.
--
-- Fixtures, relative to own (the owner, picture P = profile/<own>/1.jpg):
--   one  shares a 1:1 with own             grp  shares a group with own
--   osr  own saved osr (owner-saved reader; no row, no reach)
--   rso  saved own (reader-saved-owner only; row and reach, not saved by own)
--   tfd  found own by exact tag (reach, no row)
--   str  allowlisted, active stranger
--   rev  in the group, session revoked     stl  in the group, on a replaced phone
--   bot  in the group, signed in, never allowlisted
--   dls  in the group with a picture, 'everyone', saved by grp -- then delisted
--
-- Each observation reads, as the reader: pub = profiles_public()'s path for
-- own ('-' no row), leg = profiles.avatar_path ('-' no row), st = storage
-- objects visible for the picture, find = find_by_tag(own's tag)'s path ('-'
-- no row). 'P' is the real path, 'null' a masked one. find runs in a rolled
-- back subtransaction, so it neither spends budget nor leaves a find behind.


-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000a7a00001', 'own@picpriv.test', now(), '{"full_name":"Own"}'),
  ('00000000-0000-0000-0000-0000a7a00002', 'one@picpriv.test', now(), '{"full_name":"One"}'),
  ('00000000-0000-0000-0000-0000a7a00003', 'grp@picpriv.test', now(), '{"full_name":"Grp"}'),
  ('00000000-0000-0000-0000-0000a7a00004', 'osr@picpriv.test', now(), '{"full_name":"Osr"}'),
  ('00000000-0000-0000-0000-0000a7a00005', 'rso@picpriv.test', now(), '{"full_name":"Rso"}'),
  ('00000000-0000-0000-0000-0000a7a00006', 'tfd@picpriv.test', now(), '{"full_name":"Tfd"}'),
  ('00000000-0000-0000-0000-0000a7a00007', 'str@picpriv.test', now(), '{"full_name":"Str"}'),
  ('00000000-0000-0000-0000-0000a7a00008', 'rev@picpriv.test', now(), '{"full_name":"Rev"}'),
  ('00000000-0000-0000-0000-0000a7a00009', 'stl@picpriv.test', now(), '{"full_name":"Stl"}'),
  ('00000000-0000-0000-0000-0000a7a0000a', 'bot@picpriv.test', now(), '{"full_name":"Bot"}'),
  ('00000000-0000-0000-0000-0000a7a0000b', 'dls@picpriv.test', now(), '{"full_name":"Dls"}');
insert into app_private.allowlist(email) values
  ('own@picpriv.test'), ('one@picpriv.test'), ('grp@picpriv.test'), ('osr@picpriv.test'), ('rso@picpriv.test'), ('tfd@picpriv.test'), ('str@picpriv.test'), ('rev@picpriv.test'), ('stl@picpriv.test'), ('dls@picpriv.test');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('5a5a0000-0000-0000-0000-' || right(id::text, 12))::uuid, id, now(), now()
    from auth.users where email like '%@picpriv.test';
-- stl's OLD phone, activated first and then replaced by the one above.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('5a5a0000-0000-0000-0000-00000000dead', '00000000-0000-0000-0000-0000a7a00009', now() - interval '1 hour', now());
update public.profiles set tag = 'ap_' || split_part(
    (select email from auth.users u where u.id = user_id), '@', 1)
 where user_id in (select id from auth.users where email like '%@picpriv.test');

create or replace function test_as(uid uuid, sid text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', coalesce(sid, '5a5a0000-0000-0000-0000-' || right(uid::text, 12)))::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function uid_of(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000a7a000' || case n
    when 'own' then '01' when 'one' then '02' when 'grp' then '03' when 'osr' then '04'
    when 'rso' then '05' when 'tfd' then '06' when 'str' then '07' when 'rev' then '08'
    when 'stl' then '09' when 'bot' then '0a' when 'dls' then '0b' end)::uuid
$$;
-- the session a reader acts with: stl acts on her replaced (old) phone
create or replace function sid_of(n text) returns text language sql as $$
  select case n when 'stl' then '5a5a0000-0000-0000-0000-00000000dead'
                else '5a5a0000-0000-0000-0000-' || right(uid_of(n)::text, 12) end
$$;
grant execute on function test_as(uuid, text), uid_of(text), sid_of(text) to authenticated;

select test_as(uid_of('stl'), '5a5a0000-0000-0000-0000-00000000dead');
select public.activate_session();
reset role;
do $$
declare n text;
begin
  foreach n in array array['own','one','grp','osr','rso','tfd','str','rev','stl','bot','dls'] loop
    perform test_as(uid_of(n));
    perform public.activate_session();
    execute 'reset role';
  end loop;
end $$;
delete from auth.sessions where user_id = uid_of('rev');

insert into public.conversations(id, title) values
  ('a7a0c000-0000-0000-0000-000000000001', null), ('a7a0c000-0000-0000-0000-000000000002', 'g');
insert into public.conversation_members(conversation_id, user_id)
  select 'a7a0c000-0000-0000-0000-000000000001'::uuid, uid_of(n) from unnest(array['own','one']) n
  union all
  select 'a7a0c000-0000-0000-0000-000000000002'::uuid, uid_of(n)
    from unnest(array['own','grp','rev','stl','bot','dls']) n;
insert into public.contacts(owner_id, contact_id) values
  (uid_of('own'), uid_of('osr')), (uid_of('rso'), uid_of('own')), (uid_of('grp'), uid_of('dls'));
insert into app_private.tag_finds(finder, found_id) values (uid_of('tfd'), uid_of('own'));

-- The stored pictures, as the Storage API would have written them.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('avatars', 'profile/00000000-0000-0000-0000-0000a7a00001/1.jpg', '00000000-0000-0000-0000-0000a7a00001', '{"size":3,"mimetype":"image/jpeg"}'),
  ('avatars', 'profile/00000000-0000-0000-0000-0000a7a0000b/1.jpg', '00000000-0000-0000-0000-0000a7a0000b', '{"size":3,"mimetype":"image/jpeg"}');

-- The owners set their pictures the way the app does (the new column).
select test_as(uid_of('own'));
select is((select count(*) from public.own_profile()), 1::bigint, 'own reads her own profile');
update public.profiles set avatar_object = 'profile/00000000-0000-0000-0000-0000a7a00001/1.jpg' where user_id = auth.uid();
reset role;
select test_as(uid_of('dls'));
update public.profiles set avatar_object = 'profile/00000000-0000-0000-0000-0000a7a0000b/1.jpg' where user_id = auth.uid();
reset role;
delete from app_private.allowlist where email = 'dls@picpriv.test';

-- What [reader] (the current role) gets for [owner]'s picture, on every channel.
create or replace function pv_look(owner uuid, otag text, pic text, do_find boolean) returns text
language plpgsql as $$
declare
  n bigint; v text; pub text; leg text; st bigint; fnd text := '-';
begin
  begin
    select count(*), max(coalesce(avatar_path, 'null')) into n, v
      from public.profiles_public() where user_id = owner;
    pub := case when n = 0 then '-' else v end;
  exception when insufficient_privilege then pub := '-';
  end;
  select count(*), max(coalesce(avatar_path, 'null')) into n, v
    from public.profiles where user_id = owner;
  leg := case when n = 0 then '-' else v end;
  select count(*) into st from storage.objects where bucket_id = 'avatars' and name = pic;
  if do_find then
    begin
      select count(*), max(coalesce(avatar_path, 'null')) into n, v from public.find_by_tag(otag);
      fnd := case when n = 0 then '-' else v end;
      raise sqlstate 'PVRB0';  -- undo the find, its budget and its tag_finds row
    exception
      when sqlstate 'PVRB0' then null;
      when insufficient_privilege then fnd := '-';
    end;
  end if;
  return replace(format('pub=%s leg=%s st=%s find=%s', pub, leg, st, fnd), pic, 'P');
end $$;
grant execute on function pv_look(uuid, text, text, boolean) to authenticated;

create temp table _obs (setting text, reader text, obs text);
create temp table _exp (setting text, reader text, obs text);
grant select, insert on _obs to authenticated;

create or replace function observe(setting text) returns void language plpgsql as $$
declare n text;
begin
  foreach n in array array['own','one','grp','osr','rso','tfd','str','rev','stl','bot'] loop
    perform test_as(uid_of(n), sid_of(n));
    insert into _obs values (setting, n,
      pv_look(uid_of('own'), 'ap_own', 'profile/' || uid_of('own') || '/1.jpg', n <> 'own'));
    execute 'reset role';
  end loop;
  -- the delisted owner, 'everyone', seen by her group partner who saved her
  perform test_as(uid_of('grp'));
  insert into _obs values (setting, 'grp->dls',
    pv_look(uid_of('dls'), 'ap_dls', 'profile/' || uid_of('dls') || '/1.jpg', true));
  execute 'reset role';
end $$;

insert into _exp(setting, reader, obs) values
  ('everyone', 'own', 'pub=P leg=P st=1 find=-'),
  ('everyone', 'one', 'pub=P leg=P st=1 find=P'),
  ('everyone', 'grp', 'pub=P leg=P st=1 find=P'),
  ('everyone', 'osr', 'pub=- leg=- st=1 find=P'),
  ('everyone', 'rso', 'pub=P leg=P st=1 find=P'),
  ('everyone', 'tfd', 'pub=- leg=- st=1 find=P'),
  ('everyone', 'str', 'pub=- leg=- st=0 find=P'),
  ('everyone', 'rev', 'pub=- leg=- st=0 find=-'),
  ('everyone', 'stl', 'pub=- leg=- st=0 find=-'),
  ('everyone', 'bot', 'pub=- leg=- st=0 find=-'),
  ('everyone', 'grp->dls', 'pub=- leg=- st=0 find=-'),
  ('contacts', 'own', 'pub=P leg=null st=1 find=-'),
  ('contacts', 'one', 'pub=null leg=null st=0 find=null'),
  ('contacts', 'grp', 'pub=null leg=null st=0 find=null'),
  ('contacts', 'osr', 'pub=- leg=- st=1 find=P'),
  ('contacts', 'rso', 'pub=null leg=null st=0 find=null'),
  ('contacts', 'tfd', 'pub=- leg=- st=0 find=null'),
  ('contacts', 'str', 'pub=- leg=- st=0 find=null'),
  ('contacts', 'rev', 'pub=- leg=- st=0 find=-'),
  ('contacts', 'stl', 'pub=- leg=- st=0 find=-'),
  ('contacts', 'bot', 'pub=- leg=- st=0 find=-'),
  ('contacts', 'grp->dls', 'pub=- leg=- st=0 find=-'),
  ('nobody', 'own', 'pub=P leg=null st=1 find=-'),
  ('nobody', 'one', 'pub=null leg=null st=0 find=null'),
  ('nobody', 'grp', 'pub=null leg=null st=0 find=null'),
  ('nobody', 'osr', 'pub=- leg=- st=0 find=null'),
  ('nobody', 'rso', 'pub=null leg=null st=0 find=null'),
  ('nobody', 'tfd', 'pub=- leg=- st=0 find=null'),
  ('nobody', 'str', 'pub=- leg=- st=0 find=null'),
  ('nobody', 'rev', 'pub=- leg=- st=0 find=-'),
  ('nobody', 'stl', 'pub=- leg=- st=0 find=-'),
  ('nobody', 'bot', 'pub=- leg=- st=0 find=-'),
  ('nobody', 'grp->dls', 'pub=- leg=- st=0 find=-');

-- The owner's setting, changed by the owner through the client path.
create or replace function set_vis(v text) returns void language plpgsql as $$
begin
  perform test_as(uid_of('own'));
  update public.profiles set avatar_visibility = v where user_id = auth.uid();
  execute 'reset role';
end $$;

-- 1 the matrix --------------------------------------------------------------
select is((select avatar_visibility from public.profiles where user_id = uid_of('own')), 'everyone',
          'the default setting is everyone');
select observe('everyone');
select set_vis('contacts');
select observe('contacts');
select set_vis('nobody');
select observe('nobody');
select is(o.obs, e.obs, format('%s: %s', e.setting, e.reader))
  from _exp e left join _obs o using (setting, reader)
 order by array_position(array['everyone','contacts','nobody'], e.setting), e.reader;

-- 2 one-way: hiding yours hides nobody else's from you ------------------------
-- own is on 'nobody' now; one's picture, 'everyone', is still own's to see.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('avatars', 'profile/00000000-0000-0000-0000-0000a7a00002/1.jpg', '00000000-0000-0000-0000-0000a7a00002', '{"size":3,"mimetype":"image/jpeg"}');
select test_as(uid_of('one'));
update public.profiles set avatar_object = 'profile/00000000-0000-0000-0000-0000a7a00002/1.jpg' where user_id = auth.uid();
reset role;
select test_as(uid_of('own'));
select is(pv_look(uid_of('one'), 'ap_one', 'profile/00000000-0000-0000-0000-0000a7a00002/1.jpg', false), 'pub=P leg=P st=1 find=-',
          'own, hiding hers from everyone, still sees one''s picture');
reset role;

-- 3 the legacy copy, after every write path -----------------------------------
-- snap: the stored row as the setup role sees it.
create or replace function snap(n text) returns text language sql as $$
  select format('obj=%s leg=%s vis=%s',
                coalesce(replace(avatar_object, 'profile/' || user_id || '/', ''), 'null'),
                coalesce(replace(avatar_path, 'profile/' || user_id || '/', ''), 'null'),
                avatar_visibility)
    from public.profiles where user_id = uid_of(n)
$$;
-- as the owner: 'ok', or the SQLSTATE the statement raised
create or replace function own_write(stmt text) returns text language plpgsql as $$
begin
  perform test_as(uid_of('own'));
  execute stmt;
  execute 'reset role';
  return 'ok';
exception when others then
  execute 'reset role';
  return sqlstate;
end $$;

select is(snap('own'), 'obj=1.jpg leg=null vis=nobody', 'nobody: the legacy copy is null');
select is(own_write($$update public.profiles set avatar_visibility = 'everyone' where user_id = auth.uid()$$), 'ok',
          'own switches to everyone');
select is(snap('own'), 'obj=1.jpg leg=1.jpg vis=everyone', 'everyone: the legacy copy is the real path');
select is(own_write($$update public.profiles set display_name = 'Own O' where user_id = auth.uid()$$), 'ok',
          'own renames');
select is(snap('own'), 'obj=1.jpg leg=1.jpg vis=everyone', 'an unrelated update keeps the copy');
select is(own_write($$update public.profiles set avatar_visibility = 'contacts' where user_id = auth.uid()$$), 'ok',
          'own switches to contacts');
select is(snap('own'), 'obj=1.jpg leg=null vis=contacts', 'contacts: the legacy copy is null');
select is(own_write(format($$update public.profiles set avatar_object = %L where user_id = auth.uid()$$,
                          'profile/' || uid_of('own') || '/2.jpg')), 'ok', 'new build: own sets picture 2');
select is(snap('own'), 'obj=2.jpg leg=null vis=contacts', 'a new picture under contacts: copy stays null');
select is(own_write($$update public.profiles set avatar_visibility = 'everyone' where user_id = auth.uid()$$), 'ok',
          'own switches back to everyone');
select is(snap('own'), 'obj=2.jpg leg=2.jpg vis=everyone', 'the copy follows the new picture');
select is(own_write($$update public.profiles set avatar_object = null where user_id = auth.uid()$$), 'ok',
          'new build: own removes her picture');
select is(snap('own'), 'obj=null leg=null vis=everyone', 'removed: both are null');
select is(own_write(format($$update public.profiles set avatar_object = %L where user_id = auth.uid()$$,
                          'profile/' || uid_of('one') || '/1.jpg')), '42501',
          'new build: a path in someone else''s folder is refused');
-- an older build writes avatar_path only
select is(own_write(format($$update public.profiles set avatar_path = %L where user_id = auth.uid()$$,
                          'profile/' || uid_of('own') || '/3.jpg')), 'ok', 'old build: own sets picture 3');
select is(snap('own'), 'obj=3.jpg leg=3.jpg vis=everyone', 'old build set: mapped onto the real path');
select is(own_write(format($$update public.profiles set avatar_path = %L where user_id = auth.uid()$$,
                          'profile/' || uid_of('one') || '/1.jpg')), '42501',
          'old build: a path in someone else''s folder is refused');
select is(own_write(format($$update public.profiles set avatar_path = %L where user_id = auth.uid()$$,
                          'profile/' || uid_of('own') || '/a/b.jpg')), '42501',
          'old build: a nested path is refused');
select is(snap('own'), 'obj=3.jpg leg=3.jpg vis=everyone', 'refused old-build writes changed nothing');
select is(own_write($$update public.profiles set avatar_visibility = 'nobody' where user_id = auth.uid()$$), 'ok',
          'own switches to nobody');
select is(own_write(format($$update public.profiles set avatar_path = %L where user_id = auth.uid()$$,
                          'profile/' || uid_of('own') || '/4.jpg')), 'ok', 'old build under nobody: picture 4');
select is(snap('own'), 'obj=4.jpg leg=null vis=nobody', 'old build under nobody: real path moves, copy stays null');
select is(own_write($$update public.profiles set avatar_visibility = 'everyone' where user_id = auth.uid()$$), 'ok',
          'own switches back to everyone (an old build sees her picture again)');
select is(snap('own'), 'obj=4.jpg leg=4.jpg vis=everyone', 'the copy is back');
select is(own_write($$update public.profiles set avatar_path = null where user_id = auth.uid()$$), 'ok',
          'old build: own removes her picture');
select is(snap('own'), 'obj=null leg=null vis=everyone', 'old build remove: the real path is cleared');
select is(own_write($$update public.profiles set avatar_visibility = 'friends' where user_id = auth.uid()$$) <> 'ok',
          true, 'an unknown setting is refused');
select is(own_write(format($$update public.profiles set avatar_visibility = 'nobody' where user_id = %L$$,
                          uid_of('one'))), 'ok', 'own''s update aimed at one''s row runs');
select is(snap('one'), 'obj=1.jpg leg=1.jpg vis=everyone', 'and changes nothing of one''s');
select is((select count(*) from public.profiles
            where user_id in (select id from auth.users where email like '%@picpriv.test')
              and avatar_path is distinct from
                  case when avatar_visibility = 'everyone' then avatar_object end), 0::bigint,
          'every fixture row keeps avatar_path = avatar_object exactly when everyone');

-- 4 own_profile: only the caller's row, and only with app access ---------------
select test_as(uid_of('one'));
select results_eq($$select user_id, avatar_path, avatar_visibility from public.own_profile()$$,
                  format($$values (%L::uuid, %L::text, 'everyone'::text)$$,
                         uid_of('one'), 'profile/' || uid_of('one') || '/1.jpg'),
                  'own_profile returns the caller''s row, real path and setting');
select throws_ok($$select avatar_object from public.profiles$$, '42501', null,
                 'avatar_object is not selectable by a client');
select throws_ok($$select avatar_visibility from public.profiles$$, '42501', null,
                 'avatar_visibility is not selectable by a client');
reset role;
select is(own_write(format($$update public.profiles set avatar_object = %L, avatar_visibility = 'contacts'
                               where user_id = auth.uid()$$, 'profile/' || uid_of('own') || '/5.jpg')), 'ok',
          'own sets picture 5 under contacts');
select test_as(uid_of('own'));
select results_eq($$select user_id, avatar_path, avatar_visibility from public.own_profile()$$,
                  format($$values (%L::uuid, %L::text, 'contacts'::text)$$,
                         uid_of('own'), 'profile/' || uid_of('own') || '/5.jpg'),
                  'own_profile hands the owner her real path even while the copy is null');
reset role;
create or replace function own_rows() returns bigint language plpgsql as $$
begin
  return (select count(*) from public.own_profile());
exception when insufficient_privilege then
  return 0;
end $$;
grant execute on function own_rows() to authenticated;
select test_as(uid_of('rev'));
select is(own_rows(), 0::bigint, 'own_profile: nothing for a revoked session');
reset role;
select test_as(uid_of('stl'), sid_of('stl'));
select is(own_rows(), 0::bigint, 'own_profile: nothing for a replaced phone');
reset role;
select test_as(uid_of('bot'));
select is(own_rows(), 0::bigint, 'own_profile: nothing for a non-allowlisted account');
reset role;

-- 5 profiles_public() shows exactly the rows profiles shows, for every caller ----
create or replace function pp_diff() returns bigint language plpgsql as $$
declare a bigint; b bigint;
begin
  begin
    select count(*) into a from (select user_id from public.profiles_public()
                                 except select user_id from public.profiles) x;
    select count(*) into b from (select user_id from public.profiles
                                 except select user_id from public.profiles_public()) y;
  exception when insufficient_privilege then
    select count(*) into b from public.profiles;
    return b;  -- refused outright: equal only if profiles shows nothing either
  end;
  return a + b;
end $$;
grant execute on function pp_diff() to authenticated;
create temp table _eq (reader text, diff bigint, seen bigint);
grant insert on _eq to authenticated;
do $$
declare n text;
begin
  foreach n in array array['own','one','grp','osr','rso','tfd','str','rev','stl','bot','dls'] loop
    perform test_as(uid_of(n), sid_of(n));
    insert into _eq values (n, pp_diff(), (select count(*) from public.profiles));
    execute 'reset role';
  end loop;
end $$;
select is(diff, 0::bigint, 'profiles_public() and profiles show the same people to ' || reader)
  from _eq order by reader;
select ok((select min(seen) from _eq where reader in ('own','one','grp','rso')) > 1,
          'not vacuous: the active readers see more than themselves');

select * from finish();
rollback;
