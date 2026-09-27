-- Profile and group pictures: the avatars bucket, its storage policies,
-- profiles.avatar_path and set_group_avatar().
--
-- Keys: `profile/<user id>/<file>` for a person, `group/<conversation id>/<file>`
-- for a group. Every negative fixture fails ONE gate:
--   dan  -- allowlisted, active, in no group with ann: stopped only by
--           membership (group rules) or by the path owner (profile rules);
--   bob  -- a member of BOTH groups: a cross-group path can only be refused by
--           the path pin, never by membership;
--   cy   -- a member of g1 until removed, still allowlisted and active;
--   eve  -- a member of g1 whose session is revoked;
--   fay  -- allowlisted and active with a picture, then delisted;
--   robo -- signed in, never allowlisted.
begin;
select plan(101);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000a9001', 'av-ann@example.test', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000a9002', 'av-bob@example.test', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000a9003', 'av-cy@example.test', now(), '{"full_name":"Cy"}'),
  ('00000000-0000-0000-0000-0000000a9004', 'av-dan@example.test', now(), '{"full_name":"Dan"}'),
  ('00000000-0000-0000-0000-0000000a9005', 'av-eve@example.test', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-0000000a9006', 'av-fay@example.test', now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-0000000a90fe', 'av-robo@example.test', now(), '{"full_name":"Robo"}');
insert into app_private.allowlist(email) values
  ('av-ann@example.test'), ('av-bob@example.test'), ('av-cy@example.test'),
  ('av-dan@example.test'), ('av-eve@example.test'), ('av-fay@example.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a9a9a9a9-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000a9001', now(), now()),
  ('a9a9a9a9-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000a9002', now(), now()),
  ('a9a9a9a9-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000a9003', now(), now()),
  ('a9a9a9a9-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000a9004', now(), now()),
  ('a9a9a9a9-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000a9005', now(), now()),
  ('a9a9a9a9-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000a9006', now(), now()),
  ('a9a9a9a9-0000-0000-0000-0000000000fe', '00000000-0000-0000-0000-0000000a90fe', now(), now());

create function av_as(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-0000000a90' || n, 'role', 'authenticated',
      'email', (select email from auth.users where id = ('00000000-0000-0000-0000-0000000a90' || n)::uuid),
      'session_id', 'a9a9a9a9-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
-- Upload as the caller, owned by the caller, the way the Storage API does it.
create function av_put(key text) returns void language plpgsql as $$
begin
  insert into storage.objects(bucket_id, name, owner_id, metadata)
  values ('avatars', key, auth.uid()::text, '{"size":3,"mimetype":"image/jpeg"}'::jsonb);
end $$;
-- How many avatars objects named [key] the caller can see.
create function av_sees(key text) returns bigint language sql as $$
  select count(*) from storage.objects where bucket_id = 'avatars' and name = key
$$;
-- The truth, whatever RLS says: called as postgres only.
create function av_exists(key text) returns boolean language sql security definer as $$
  select exists (select 1 from storage.objects where bucket_id = 'avatars' and name = key)
$$;
grant execute on function av_as(text), av_put(text), av_sees(text) to authenticated, anon;

select av_as('01'); select public.activate_session(); reset role;
select av_as('02'); select public.activate_session(); reset role;
select av_as('03'); select public.activate_session(); reset role;
select av_as('04'); select public.activate_session(); reset role;
select av_as('05'); select public.activate_session(); reset role;
select av_as('06'); select public.activate_session(); reset role;
select av_as('fe'); select public.activate_session(); reset role;

-- g1: ann bob cy eve. g2: bob dan. d1: ann and dan, one-to-one.
insert into public.conversations(id, title) values
  ('c9000000-0000-0000-0000-0000000000a1', 'g1'),
  ('c9000000-0000-0000-0000-0000000000b2', 'g2');
insert into public.conversation_members(conversation_id, user_id) values
  ('c9000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000a9001'),
  ('c9000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000a9002'),
  ('c9000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000a9003'),
  ('c9000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000a9005'),
  ('c9000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000a9002'),
  ('c9000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000a9004');
select av_as('01');
create temp table _d1 as
  select public.start_direct_conversation('00000000-0000-0000-0000-0000000a9004') as id;
reset role;
grant select on _d1 to authenticated;

-- 1 the bucket -----------------------------------------------------------------
select is((select public from storage.buckets where id = 'avatars'), false,
          'the avatars bucket is private');
select is((select file_size_limit from storage.buckets where id = 'avatars'), 1048576::bigint,
          'the avatars bucket caps a picture at 1 MB');
select is((select allowed_mime_types from storage.buckets where id = 'avatars'), array['image/jpeg'],
          'the avatars bucket accepts only JPEG');

-- 2 own picture: storage writes ------------------------------------------------
select av_as('01');
select lives_ok($$select av_put('profile/00000000-0000-0000-0000-0000000a9001/1.jpg')$$,
                'ann uploads under her own profile/ folder');
select lives_ok($$select av_put('profile/00000000-0000-0000-0000-0000000a9001/old.jpg')$$,
                'ann uploads a second picture under her own folder');
select throws_ok($$select av_put('profile/00000000-0000-0000-0000-0000000a9002/x.jpg')$$,
                 '42501', null, 'ann cannot upload into bob''s profile/ folder');
select throws_ok($$select av_put('profile/not-a-uuid/x.jpg')$$,
                 '42501', null, 'a malformed profile key is refused by policy, not a cast error');
select throws_ok($$select av_put('loose.jpg')$$,
                 '42501', null, 'a key outside profile/ and group/ is refused');
select throws_ok($$select av_put('00000000-0000-0000-0000-0000000a9001/1.jpg')$$,
                 '42501', null, 'a bare <uid>/ key (no profile/ prefix) is refused');
select throws_ok(
  $$insert into storage.objects(bucket_id, name, owner_id, metadata)
    values ('attachments', 'profile/00000000-0000-0000-0000-0000000a9001/2.jpg',
            '00000000-0000-0000-0000-0000000a9001', '{"size":3}'::jsonb)$$,
  '42501', null, 'a profile key in the attachments bucket gets no avatar rights');
-- No update policy: a picture is never rewritten in place, so a phone's cache
-- keyed by path can never hold a stale copy.
select lives_ok(
  $$update storage.objects set metadata = '{"size":9}'::jsonb
     where bucket_id = 'avatars' and name = 'profile/00000000-0000-0000-0000-0000000a9001/1.jpg'$$,
  'an update of her own picture matches nothing rather than erroring');
reset role;
select is((select metadata->>'size' from storage.objects
            where bucket_id = 'avatars' and name = 'profile/00000000-0000-0000-0000-0000000a9001/1.jpg'),
          '3', 'the picture was not rewritten in place');

-- dan writes his own: the control proving he passes app access below.
select av_as('04');
select lives_ok($$select av_put('profile/00000000-0000-0000-0000-0000000a9004/1.jpg')$$,
                'control: dan, active, uploads his own picture');
reset role;

-- seeded as postgres: fay's, robo's, eve's and bob's pictures.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('avatars', 'profile/00000000-0000-0000-0000-0000000a9006/1.jpg', '00000000-0000-0000-0000-0000000a9006', '{"size":3}'),
  ('avatars', 'profile/00000000-0000-0000-0000-0000000a90fe/1.jpg', '00000000-0000-0000-0000-0000000a90fe', '{"size":3}'),
  ('avatars', 'profile/00000000-0000-0000-0000-0000000a9005/1.jpg', '00000000-0000-0000-0000-0000000a9005', '{"size":3}'),
  ('avatars', 'profile/00000000-0000-0000-0000-0000000a9002/1.jpg', '00000000-0000-0000-0000-0000000a9002', '{"size":3}'),
  ('avatars', 'group/c9000000-0000-0000-0000-0000000000b2/1.jpg', '00000000-0000-0000-0000-0000000a9004', '{"size":3}');

-- 3 profiles.avatar_path -----------------------------------------------------------
select av_as('01');
select lives_ok(
  $$update public.profiles set avatar_path = 'profile/00000000-0000-0000-0000-0000000a9001/1.jpg'
     where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  'ann points her profile at her own picture');
select is((select avatar_path from public.profiles where user_id = '00000000-0000-0000-0000-0000000a9001'),
          'profile/00000000-0000-0000-0000-0000000a9001/1.jpg', 'ann''s avatar_path is set');
select throws_ok(
  $$update public.profiles set avatar_path = 'profile/00000000-0000-0000-0000-0000000a9002/1.jpg'
     where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  '42501', null, 'ann cannot point her own profile at bob''s picture');
select throws_ok(
  $$update public.profiles set avatar_path = 'group/c9000000-0000-0000-0000-0000000000a1/1.jpg'
     where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  '42501', null, 'ann cannot point her profile at a group picture');
select throws_ok(
  $$update public.profiles set avatar_path = 'xprofile/00000000-0000-0000-0000-0000000a9001/1.jpg'
     where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  '42501', null, 'the profile/ prefix is anchored at the start');
select throws_ok(
  $$update public.profiles set avatar_path = 'profile/00000000-0000-0000-0000-0000000a9001'
     where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  '42501', null, 'a path that is only her folder name, with no file, is refused');
-- Exactly profile/<own id>/<one file>: no climbing out, no sub-folders, no
-- empty or all-dots file name.
select throws_ok(
  format($$update public.profiles set avatar_path = %L
            where user_id = '00000000-0000-0000-0000-0000000a9001'$$, v.path),
  '42501', null, 'the profile path pin refuses ' || v.what)
  from (values
    ('profile/00000000-0000-0000-0000-0000000a9001/../00000000-0000-0000-0000-0000000a9002/1.jpg', 'a .. climb into bob''s folder'),
    ('profile/00000000-0000-0000-0000-0000000a9001/sub/1.jpg', 'a sub-folder'),
    ('profile/00000000-0000-0000-0000-0000000a9001//1.jpg', 'a doubled slash'),
    ('profile/00000000-0000-0000-0000-0000000a9001/', 'an empty file name'),
    ('profile/00000000-0000-0000-0000-0000000a9001/..', 'a .. file name'),
    ('profile/00000000-0000-0000-0000-0000000a9001/.', 'a . file name'),
    ('profile/00000000-0000-0000-0000-0000000a9001/...', 'an all-dots file name')
  ) v(path, what);
select lives_ok(
  $$update public.profiles set avatar_path = 'profile/00000000-0000-0000-0000-0000000a9001/.hidden.v2.jpg'
     where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  'control: a file name with dots in it (not all dots) is accepted');
select lives_ok(
  $$update public.profiles set avatar_path = 'profile/00000000-0000-0000-0000-0000000a9001/1.jpg'
     where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  'ann points back at her real picture');
select lives_ok(
  $$update public.profiles set avatar_path = 'profile/00000000-0000-0000-0000-0000000a9001/evil.jpg'
     where user_id = '00000000-0000-0000-0000-0000000a9002'$$,
  'ann''s update of bob''s row matches nothing');
reset role;
select is((select avatar_path from public.profiles where user_id = '00000000-0000-0000-0000-0000000a9002'),
          null, 'bob''s avatar_path is untouched by ann');
select av_as('01');
select is((select avatar_path from public.profiles where user_id = '00000000-0000-0000-0000-0000000a9001'),
          'profile/00000000-0000-0000-0000-0000000a9001/1.jpg', 'refused updates left ann''s own path as it was');
reset role;

-- 4 a person's picture is read like their profile -------------------------------
select av_as('04');
select is(av_sees('profile/00000000-0000-0000-0000-0000000a9001/1.jpg'), 1::bigint,
          'dan, sharing no conversation with ann, sees her picture (same rule as her profile)');
select is(av_sees('profile/00000000-0000-0000-0000-0000000a9006/1.jpg'), 1::bigint,
          'control: dan sees fay''s picture while she is allowlisted');
select is(av_sees('profile/00000000-0000-0000-0000-0000000a90fe/1.jpg'), 0::bigint,
          'dan does not see the picture of an account that is not allowlisted');
reset role;
select av_as('01');
select is(av_sees('profile/00000000-0000-0000-0000-0000000a9001/1.jpg'), 1::bigint,
          'ann sees her own picture');
reset role;
select av_as('fe');
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 0::bigint,
          'a signed-in account off the allowlist sees no picture at all');
select throws_ok($$select av_put('profile/00000000-0000-0000-0000-0000000a90fe/2.jpg')$$,
                 '42501', null, 'an account off the allowlist cannot upload even into its own folder');
reset role;

-- 5 group picture: storage writes -------------------------------------------------
select av_as('01');
select lives_ok($$select av_put('group/c9000000-0000-0000-0000-0000000000a1/1.jpg')$$,
                'ann, a member of g1, uploads a g1 picture');
select throws_ok($$select av_put('group/c9000000-0000-0000-0000-0000000000b2/x.jpg')$$,
                 '42501', null, 'ann cannot upload into g2, which she is not in');
select throws_ok($$select av_put('group/11111111-2222-3333-4444-555555555555/x.jpg')$$,
                 '42501', null, 'nobody uploads into a conversation that does not exist');
select throws_ok($$select av_put('group/not-a-uuid/x.jpg')$$,
                 '42501', null, 'a malformed group key is refused by policy, not a cast error');
-- A group/ object under a 1:1 id, planted by the service role: its members
-- still may not read it -- a 1:1 has no picture of its own.
reset role;
insert into storage.objects(bucket_id, name, owner_id, metadata)
  select 'avatars', 'group/' || id || '/planted.jpg', '00000000-0000-0000-0000-0000000a9004', '{"size":3}'
    from _d1;
select av_as('01');
select is(av_sees('group/' || (select id from _d1) || '/planted.jpg'), 0::bigint,
          'a member of a 1:1 cannot read a group/<that 1:1>/ object');
-- ann IS a member of d1; only "group paths need a group" can refuse this.
select throws_ok(format($$select av_put('group/' || %L || '/1.jpg')$$, (select id from _d1)),
                 '42501', null, 'a member of a 1:1 cannot upload under group/<that 1:1>/');
reset role;
select av_as('02');
select lives_ok($$select av_put('group/c9000000-0000-0000-0000-0000000000a1/2.jpg')$$,
                'bob, another member of g1, uploads a g1 picture too');
reset role;
select av_as('04');
select throws_ok($$select av_put('group/c9000000-0000-0000-0000-0000000000a1/x.jpg')$$,
                 '42501', null, 'dan, active but not in g1, cannot upload a g1 picture');
reset role;
select av_as('03');
select lives_ok($$select av_put('group/c9000000-0000-0000-0000-0000000000a1/cy.jpg')$$,
                'control: cy uploads while still a member');
reset role;

-- 6 group picture: read ------------------------------------------------------------
select av_as('02');
select is(av_sees('group/c9000000-0000-0000-0000-0000000000a1/1.jpg'), 1::bigint,
          'bob, a member of g1, sees the g1 picture ann uploaded');
reset role;
select av_as('04');
select is(av_sees('group/c9000000-0000-0000-0000-0000000000a1/1.jpg'), 0::bigint,
          'dan, active but not in g1, does not see its picture');
select is(av_sees('group/c9000000-0000-0000-0000-0000000000b2/1.jpg'), 1::bigint,
          'control: dan sees his own group''s picture');
reset role;
select av_as('01');
select is(av_sees('group/c9000000-0000-0000-0000-0000000000b2/1.jpg'), 0::bigint,
          'ann does not see the picture of g2, which she is not in');
reset role;
select av_as('03');
select is(av_sees('group/c9000000-0000-0000-0000-0000000000a1/1.jpg'), 1::bigint,
          'control: cy sees the g1 picture while a member');
reset role;

-- 7 set_group_avatar ----------------------------------------------------------------
select av_as('01');
select is(public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                  'group/c9000000-0000-0000-0000-0000000000a1/1.jpg'),
          null, 'ann sets g1''s first picture; there was no previous one');
select is((select avatar_path from public.conversations where id = 'c9000000-0000-0000-0000-0000000000a1'),
          'group/c9000000-0000-0000-0000-0000000000a1/1.jpg', 'members read g1''s new avatar_path');
reset role;
select av_as('02');
select is(public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                  'group/c9000000-0000-0000-0000-0000000000a1/2.jpg'),
          'group/c9000000-0000-0000-0000-0000000000a1/1.jpg',
          'any member (bob) replaces it, and gets the previous path back');
-- bob is in g1 AND g2: only the path pin can refuse this.
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'group/c9000000-0000-0000-0000-0000000000b2/1.jpg')$$,
                 null, null, 'a member of both groups cannot give g1 a path under g2');
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'profile/00000000-0000-0000-0000-0000000a9002/1.jpg')$$,
                 null, null, 'a group cannot point at a profile picture');
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'xgroup/c9000000-0000-0000-0000-0000000000a1/1.jpg')$$,
                 null, null, 'the group/ prefix is anchored at the start');
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'group/c9000000-0000-0000-0000-0000000000a1')$$,
                 null, null, 'a path that is only the group''s folder name, with no file, is refused');
select throws_ok(
  format($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1', %L)$$, v.path),
  null, null, 'the group path pin refuses ' || v.what)
  from (values
    ('group/c9000000-0000-0000-0000-0000000000a1/../c9000000-0000-0000-0000-0000000000b2/1.jpg', 'a .. climb into g2''s folder'),
    ('group/c9000000-0000-0000-0000-0000000000a1/sub/1.jpg', 'a sub-folder'),
    ('group/c9000000-0000-0000-0000-0000000000a1//1.jpg', 'a doubled slash'),
    ('group/c9000000-0000-0000-0000-0000000000a1/', 'an empty file name'),
    ('group/c9000000-0000-0000-0000-0000000000a1/..', 'a .. file name'),
    ('group/c9000000-0000-0000-0000-0000000000a1/.', 'a . file name'),
    ('group/c9000000-0000-0000-0000-0000000000a1/...', 'an all-dots file name')
  ) v(path, what);
reset role;
select av_as('04');
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'group/c9000000-0000-0000-0000-0000000000a1/9.jpg')$$,
                 null, null, 'dan, active but not in g1, cannot set its picture');
select throws_ok(format($$select public.set_group_avatar(%L, 'group/' || %L || '/1.jpg')$$,
                        (select id from _d1), (select id from _d1)),
                 null, null, 'a one-to-one conversation never gets a picture of its own (dan)');
reset role;
select av_as('01');
select throws_ok(format($$select public.set_group_avatar(%L, 'group/' || %L || '/1.jpg')$$,
                        (select id from _d1), (select id from _d1)),
                 null, null, 'a one-to-one conversation never gets a picture of its own (ann)');
select throws_ok($$update public.conversations set avatar_path = 'group/c9000000-0000-0000-0000-0000000000a1/3.jpg'
                    where id = 'c9000000-0000-0000-0000-0000000000a1'$$,
                 '42501', null, 'conversations.avatar_path cannot be written directly');
reset role;
select is((select avatar_path from public.conversations where id = (select id from _d1)),
          null, 'the one-to-one conversation still has no picture');
select is((select avatar_path from public.conversations where id = 'c9000000-0000-0000-0000-0000000000a1'),
          'group/c9000000-0000-0000-0000-0000000000a1/2.jpg', 'every refused call left g1''s picture as bob set it');

-- 8 removed member ----------------------------------------------------------------
delete from public.conversation_members
 where conversation_id = 'c9000000-0000-0000-0000-0000000000a1'
   and user_id = '00000000-0000-0000-0000-0000000a9003';
select av_as('03');
select is(av_sees('group/c9000000-0000-0000-0000-0000000000a1/1.jpg'), 0::bigint,
          'cy, removed from g1, no longer sees its picture');
select throws_ok($$select av_put('group/c9000000-0000-0000-0000-0000000000a1/cy2.jpg')$$,
                 '42501', null, 'cy, removed, cannot upload a g1 picture');
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'group/c9000000-0000-0000-0000-0000000000a1/cy.jpg')$$,
                 null, null, 'cy, removed, cannot set g1''s picture');
select is(av_sees('profile/00000000-0000-0000-0000-0000000a9001/1.jpg'), 1::bigint,
          'control: cy is still active -- she still sees ann''s profile picture');
reset role;

-- 9 anon -----------------------------------------------------------------------------
set local role anon;
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 0::bigint,
          'anon sees no picture');
select throws_ok($$insert into storage.objects(bucket_id, name, metadata)
                   values ('avatars', 'profile/00000000-0000-0000-0000-0000000a9001/anon.jpg', '{"size":3}')$$,
                 '42501', null, 'anon cannot upload');
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'group/c9000000-0000-0000-0000-0000000000a1/anon.jpg')$$,
                 '42501', null, 'anon cannot call set_group_avatar');
reset role;

-- 10 delete ----------------------------------------------------------------------------
-- Storage refuses direct DELETE unless this is set, independent of RLS; set it
-- so the policies are what decides.
set local storage.allow_delete_query = 'true';
select av_as('04');
select lives_ok($$delete from storage.objects where bucket_id = 'avatars'
                   and name = 'profile/00000000-0000-0000-0000-0000000a9001/1.jpg'$$,
                'dan''s delete of ann''s picture runs');
select lives_ok($$delete from storage.objects where bucket_id = 'avatars'
                   and name = 'group/c9000000-0000-0000-0000-0000000000a1/2.jpg'$$,
                'dan''s delete of a g1 picture runs');
reset role;
select ok(av_exists('profile/00000000-0000-0000-0000-0000000a9001/1.jpg'),
          'dan could not delete ann''s picture');
select ok(av_exists('group/c9000000-0000-0000-0000-0000000000a1/2.jpg'),
          'dan, not in g1, could not delete a g1 picture');
select av_as('03');
select lives_ok($$delete from storage.objects where bucket_id = 'avatars'
                   and name = 'group/c9000000-0000-0000-0000-0000000000a1/cy.jpg'$$,
                'removed cy''s delete of her old g1 upload runs');
reset role;
select ok(av_exists('group/c9000000-0000-0000-0000-0000000000a1/cy.jpg'),
          'cy, removed, could not delete a g1 picture -- even one she uploaded');
select av_as('01');
select lives_ok($$delete from storage.objects where bucket_id = 'avatars'
                   and name = 'profile/00000000-0000-0000-0000-0000000a9001/old.jpg'$$,
                'ann deletes her own old picture');
select lives_ok($$delete from storage.objects where bucket_id = 'avatars'
                   and name = 'group/c9000000-0000-0000-0000-0000000000a1/2.jpg'$$,
                'ann deletes a g1 picture bob uploaded');
reset role;
select ok(not av_exists('profile/00000000-0000-0000-0000-0000000a9001/old.jpg'),
          'ann''s old picture is gone');
select ok(not av_exists('group/c9000000-0000-0000-0000-0000000000a1/2.jpg'),
          'any member removes a group''s picture');

-- 11 clearing the group picture --------------------------------------------------------
select av_as('01');
select is(public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1', null),
          'group/c9000000-0000-0000-0000-0000000000a1/2.jpg', 'clearing returns the previous path');
select is((select avatar_path from public.conversations where id = 'c9000000-0000-0000-0000-0000000000a1'),
          null, 'g1 has no picture now');
select lives_ok(
  $$update public.profiles set avatar_path = null where user_id = '00000000-0000-0000-0000-0000000a9001'$$,
  'ann clears her own picture');
reset role;
select is((select avatar_path from public.profiles where user_id = '00000000-0000-0000-0000-0000000a9001'),
          null, 'ann has no picture now');

-- 12 revoked session: eve is still a g1 member and allowlisted -------------------------
select av_as('05');
select is(av_sees('group/c9000000-0000-0000-0000-0000000000a1/1.jpg'), 1::bigint,
          'control: eve sees the g1 picture while her session is live');
reset role;
delete from auth.sessions where id = 'a9a9a9a9-0000-0000-0000-000000000005';
select av_as('05');
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 0::bigint,
          'eve, session revoked, sees no picture');
select throws_ok($$select av_put('profile/00000000-0000-0000-0000-0000000a9005/2.jpg')$$,
                 '42501', null, 'eve, session revoked, cannot upload her own picture');
select throws_ok($$select public.set_group_avatar('c9000000-0000-0000-0000-0000000000a1',
                                                  'group/c9000000-0000-0000-0000-0000000000a1/eve.jpg')$$,
                 null, null, 'eve, session revoked, cannot set g1''s picture');
select lives_ok($$delete from storage.objects where bucket_id = 'avatars'
                   and name = 'profile/00000000-0000-0000-0000-0000000a9005/1.jpg'$$,
                'eve''s delete of her own picture runs');
reset role;
select ok(av_exists('profile/00000000-0000-0000-0000-0000000a9005/1.jpg'),
          'eve, session revoked, could not delete even her own picture');

-- 13 delisted: fay leaves the allowlist with her session live ----------------------------
delete from app_private.allowlist where email = 'av-fay@example.test';
select av_as('04');
select is(av_sees('profile/00000000-0000-0000-0000-0000000a9006/1.jpg'), 0::bigint,
          'once fay is delisted, dan no longer sees her picture');
reset role;
select av_as('06');
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 0::bigint,
          'delisted fay sees no picture');
select throws_ok($$select av_put('profile/00000000-0000-0000-0000-0000000a9006/2.jpg')$$,
                 '42501', null, 'delisted fay cannot upload into her own folder');
reset role;

select * from finish();
rollback;
