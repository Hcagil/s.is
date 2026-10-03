-- Delete rules of 0.30.8: public.delete_message() for a group admin, the
-- storage removal it opens to whoever deleted, and public.hide_message()
-- ("delete for me").
--
-- Fixtures, each failing exactly ONE gate:
--   ann  admin of G (creator), reads every message there except m_hist
--        (her history_from is moved past it): the readability gate alone
--   bob  member of G, sends every message under test, owns their photos:
--        the sender who did NOT delete -- ownership alone must open nothing
--   cat  member of G, not admin, reads everything: the admin gate alone
--   dan  active, admin of his OWN group H, not in G: the membership gate
--        alone -- an admin elsewhere is nobody here
--   ann  again, at the very end, with her session revoked: app access alone
begin;
select plan(55);

set local storage.allow_delete_query = 'true';

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000d7001', 'dr-ann@example.com', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000d7002', 'dr-bob@example.com', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000d7003', 'dr-cat@example.com', now(), '{"full_name":"Cat"}'),
  ('00000000-0000-0000-0000-0000000d7004', 'dr-dan@example.com', now(), '{"full_name":"Dan"}');
insert into app_private.allowlist(email) values
  ('dr-ann@example.com'), ('dr-bob@example.com'), ('dr-cat@example.com'), ('dr-dan@example.com');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000d7001', '00000000-0000-0000-0000-0000000d7002'),
  ('00000000-0000-0000-0000-0000000d7001', '00000000-0000-0000-0000-0000000d7003'),
  ('00000000-0000-0000-0000-0000000d7004', '00000000-0000-0000-0000-0000000d7003');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('d7000000-0000-0000-0000-0000000d7001', '00000000-0000-0000-0000-0000000d7001', now(), now()),
  ('d7000000-0000-0000-0000-0000000d7002', '00000000-0000-0000-0000-0000000d7002', now(), now()),
  ('d7000000-0000-0000-0000-0000000d7003', '00000000-0000-0000-0000-0000000d7003', now(), now()),
  ('d7000000-0000-0000-0000-0000000d7004', '00000000-0000-0000-0000-0000000d7004', now(), now());

create or replace function test_as(who text) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-0000000d70' || who)::uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', 'd7000000-0000-0000-0000-0000000d70' || who)::text, true);
  execute 'set local role authenticated';
end $$;

-- How many attachment objects at [path] the caller can see / what remains.
create or replace function seen(path text) returns bigint language sql security invoker as $$
  select count(*) from storage.objects where bucket_id = 'attachments' and name = path
$$;
create or replace function stored(path text) returns bigint language sql security definer as $$
  select count(*) from storage.objects where bucket_id = 'attachments' and name = path
$$;
create or replace function remove(path text) returns void language sql security invoker as $$
  delete from storage.objects where bucket_id = 'attachments' and name = path
$$;
grant execute on function seen(text), stored(text), remove(text) to authenticated;

select test_as('01'); select is(public.activate_session(), true, 'ann is active'); reset role;
select test_as('02'); select is(public.activate_session(), true, 'bob is active'); reset role;
select test_as('03'); select is(public.activate_session(), true, 'cat is active'); reset role;
select test_as('04'); select is(public.activate_session(), true, 'dan is active'); reset role;

create temp table _g (k text, id uuid);
grant select, insert on _g to authenticated;
select test_as('01');
insert into _g select 'G', public.start_group_conversation('dr group', array[
  '00000000-0000-0000-0000-0000000d7002', '00000000-0000-0000-0000-0000000d7003']::uuid[]);
reset role;
select test_as('04');
insert into _g select 'H', public.start_group_conversation('dan group', array[
  '00000000-0000-0000-0000-0000000d7003']::uuid[]);
reset role;
create function g(k text) returns uuid language sql as $$ select id from _g where _g.k = $1 $$;
grant execute on function g(text) to authenticated;

select is((select role from public.conversation_members
            where conversation_id = g('G') and user_id = '00000000-0000-0000-0000-0000000d7001'),
          'admin', 'ann is G''s admin');
select is((select role from public.conversation_members
            where conversation_id = g('H') and user_id = '00000000-0000-0000-0000-0000000d7004'),
          'admin', 'dan is an admin -- of H, not of G');

-- Written as postgres to fix exact ages. bob's photos get storage rows owned
-- by bob, as his upload would leave them.
insert into public.messages(conversation_id, sender_id, body, created_at, edited_at) values
  (g('G'), '00000000-0000-0000-0000-0000000d7002', 'dr text',   now() - interval '3 days', now() - interval '2 days'),
  (g('G'), '00000000-0000-0000-0000-0000000d7002', 'dr second', now() - interval '3 days', null),
  (g('G'), '00000000-0000-0000-0000-0000000d7002', 'dr hist',   now() - interval '30 days', null),
  (g('G'), '00000000-0000-0000-0000-0000000d7002', 'dr last',   now() - interval '1 day', null);
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', g('G')::text || '/dr-photo.jpg', '00000000-0000-0000-0000-0000000d7002', '{"size":3}'::jsonb),
  ('attachments', g('G')::text || '/dr-live.jpg',  '00000000-0000-0000-0000-0000000d7002', '{"size":3}'::jsonb),
  ('attachments', g('G')::text || '/dr-hide.jpg',  '00000000-0000-0000-0000-0000000d7002', '{"size":3}'::jsonb);
insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview, created_at) values
  (g('G'), '00000000-0000-0000-0000-0000000d7002', 'caption', g('G')::text || '/dr-photo.jpg', 'iVBORw0KGgoA', now() - interval '2 days'),
  (g('G'), '00000000-0000-0000-0000-0000000d7002', '',        g('G')::text || '/dr-live.jpg',  null,   now() - interval '2 days'),
  (g('G'), '00000000-0000-0000-0000-0000000d7002', '',        g('G')::text || '/dr-hide.jpg',  null,   now() - interval '40 minutes'),
  (g('G'), '00000000-0000-0000-0000-0000000d7002', 'needle zebra', null, null, now() - interval '30 minutes');
-- ann joined G's history only 20 days back: 'dr hist' is not hers to read.
update public.conversation_members set history_from = now() - interval '20 days'
 where conversation_id = g('G') and user_id = '00000000-0000-0000-0000-0000000d7001';

create temp table _m as select
  (select id from public.messages where body = 'dr text' and conversation_id = g('G')) as text,
  (select id from public.messages where body = 'dr second' and conversation_id = g('G')) as second,
  (select id from public.messages where body = 'dr hist' and conversation_id = g('G')) as hist,
  (select id from public.messages where body = 'dr last' and conversation_id = g('G')) as last,
  (select id from public.messages where attachment_path = g('G')::text || '/dr-photo.jpg') as photo,
  (select id from public.messages where attachment_path = g('G')::text || '/dr-hide.jpg') as hphoto,
  (select id from public.messages where body = 'needle zebra' and conversation_id = g('G')) as hide;
grant select on _m to authenticated;

-- 1 privileges ---------------------------------------------------------------
select function_privs_are('public', 'hide_message', array['uuid'], 'anon', '{}'::text[],
                          'anon holds no execute on hide_message');
select function_privs_are('public', 'hide_message', array['uuid'], 'authenticated', array['EXECUTE'],
                          'authenticated may execute hide_message');

-- 2 delete_message: who may not -----------------------------------------------
select test_as('03');
select is((select count(*) from public.messages where id = (select second from _m)), 1::bigint,
          'cat reads bob''s message');
select throws_ok(format($$select public.delete_message(%L)$$, (select second from _m)),
                 '42501', null, 'cat, a member who reads it but is no admin, cannot delete it');
reset role;
select test_as('04');
select throws_ok(format($$select public.delete_message(%L)$$, (select second from _m)),
                 '42501', null, 'dan, an admin of a DIFFERENT group, cannot delete a G message');
reset role;
select test_as('01');
select is((select count(*) from public.messages where id = (select hist from _m)), 0::bigint,
          'ann cannot read the message from before her history');
select throws_ok(format($$select public.delete_message(%L)$$, (select hist from _m)),
                 '42501', null, 'an admin cannot delete a message she cannot read');
reset role;
select is((select count(*) from public.messages
            where id in ((select second from _m), (select hist from _m)) and deleted is not null),
          0::bigint, 'every refused message is untouched');

-- 3 delete_message: the admin deletes a member's message, at any age --------
select test_as('01');
select is(public.delete_message((select text from _m)), null,
          'ann, G''s admin, deletes bob''s 3-day-old edited text message (no path)');
reset role;
select is((select (deleted, deleted_by, body, attachment_path, attachment_preview, edited_at)::text
             from public.messages where id = (select text from _m)),
          row('placeholder', '00000000-0000-0000-0000-0000000d7001'::uuid, '', null::text, null::text,
              null::timestamptz)::text,
          'a placeholder deleted by ann, with body and edited_at wiped');
select is((select deleted_by from public.messages where id = (select text from _m)),
          '00000000-0000-0000-0000-0000000d7001'::uuid, 'deleted_by is the admin, not the sender');

select test_as('01');
select is(public.delete_message((select photo from _m)), g('G')::text || '/dr-photo.jpg',
          'deleting bob''s photo message returns the path to remove');
select throws_ok(format($$select public.delete_message(%L)$$, (select text from _m)),
                 '42501', null, 'an already-deleted message cannot be deleted again, not even by an admin');
reset role;
select is((select (deleted, deleted_by, body, attachment_path, attachment_preview)::text
             from public.messages where id = (select photo from _m)),
          row('placeholder', '00000000-0000-0000-0000-0000000d7001'::uuid, '', null::text, null::text)::text,
          'the photo message: placeholder, caption, path and preview wiped');

-- 4 storage: only the recorded deleter opens the deleted photo --------------
select is(stored(g('G')::text || '/dr-photo.jpg'), 1::bigint, 'the deleted photo''s object still exists');
select test_as('04');
select is(seen(g('G')::text || '/dr-photo.jpg'), 0::bigint, 'dan, an outsider, cannot see it');
select lives_ok(format('select remove(%L)', g('G')::text || '/dr-photo.jpg'), 'dan tries to remove it');
reset role;
select is(stored(g('G')::text || '/dr-photo.jpg'), 1::bigint, '... and removes nothing');
select test_as('03');
select is(seen(g('G')::text || '/dr-photo.jpg'), 0::bigint, 'cat, a member who did not delete it, cannot see it');
select lives_ok(format('select remove(%L)', g('G')::text || '/dr-photo.jpg'), 'cat tries to remove it');
reset role;
select is(stored(g('G')::text || '/dr-photo.jpg'), 1::bigint, '... and removes nothing');
select test_as('02');
-- (bob may still see his own upload: that read predates 0.30.8.)
select lives_ok(format('select remove(%L)', g('G')::text || '/dr-photo.jpg'), 'bob, its sender and owner, did not delete it: he tries to remove it');
reset role;
select is(stored(g('G')::text || '/dr-photo.jpg'), 1::bigint, '... and removes nothing: owning it is not enough');

-- a live photo opens nothing extra to anyone
select test_as('04');
select is(seen(g('G')::text || '/dr-live.jpg'), 0::bigint, 'dan cannot see a live G photo');
reset role;
select test_as('01');
select lives_ok(format('select remove(%L)', g('G')::text || '/dr-live.jpg'),
                'ann tries to remove a live photo she never deleted');
reset role;
select is(stored(g('G')::text || '/dr-live.jpg'), 1::bigint, '... and removes nothing');

select test_as('01');
select is(seen(g('G')::text || '/dr-photo.jpg'), 1::bigint, 'ann, the recorded deleter, sees the deleted photo');
select lives_ok(format('select remove(%L)', g('G')::text || '/dr-photo.jpg'), 'ann removes it');
reset role;
select is(stored(g('G')::text || '/dr-photo.jpg'), 0::bigint,
          'the admin who deleted a member''s photo removed its object: nothing is orphaned');

-- 5 hide_message ------------------------------------------------------------
select test_as('03');
select is((select count(*) from public.messages where id = (select hide from _m)), 1::bigint,
          'before: cat reads the message');
select is((select count(*) from public.search_messages('zebra', g('G'))), 1::bigint,
          'before: cat finds it in search');
select is((select body from public.conversation_previews where conversation_id = g('G')), 'needle zebra',
          'before: it is cat''s preview of G');
select is(seen(g('G')::text || '/dr-hide.jpg'), 1::bigint, 'before: cat sees the photo');
reset role;

select test_as('04');
select throws_ok(format($$select public.hide_message(%L)$$, (select hide from _m)),
                 '42501', null, 'dan cannot hide a message he cannot read');
reset role;
select test_as('01');
select throws_ok(format($$select public.hide_message(%L)$$, (select hist from _m)),
                 '42501', null, 'ann cannot hide a G message from before her history');
reset role;

select test_as('03');
select lives_ok(format($$select public.hide_message(%L)$$, (select hide from _m)), 'cat hides the text');
select lives_ok(format($$select public.hide_message(%L)$$, (select hphoto from _m)), 'cat hides the photo');
select is((select count(*) from public.messages where id in ((select hide from _m), (select hphoto from _m))),
          0::bigint, 'after: cat reads neither message');
select is((select count(*) from public.search_messages('zebra', g('G'))), 0::bigint,
          'after: cat''s search no longer finds it');
select isnt((select body from public.conversation_previews where conversation_id = g('G')), 'needle zebra',
            'after: it is no longer cat''s preview');
select is(seen(g('G')::text || '/dr-hide.jpg'), 0::bigint, 'after: cat cannot read the photo''s object');
reset role;

select test_as('02');
select is((select count(*) from public.messages where id in ((select hide from _m), (select hphoto from _m))),
          2::bigint, 'bob still reads both');
select is((select body from public.conversation_previews where conversation_id = g('G')), 'needle zebra',
          'bob''s preview is unchanged');
select is(seen(g('G')::text || '/dr-hide.jpg'), 1::bigint, 'bob still sees the photo');
reset role;
select test_as('01');
select is((select count(*) from public.search_messages('zebra', g('G'))), 1::bigint, 'ann still finds it');
reset role;
select is((select deleted from public.messages where id = (select hide from _m)), null,
          'hiding deletes nothing');

-- 6 without app access -------------------------------------------------------
delete from auth.sessions where id = 'd7000000-0000-0000-0000-0000000d7001';
select test_as('01');
select throws_ok(format($$select public.delete_message(%L)$$, (select last from _m)),
                 '42501', null, 'ann, admin but with her session revoked, cannot delete');
select throws_ok(format($$select public.hide_message(%L)$$, (select last from _m)),
                 '42501', null, 'nor hide');
reset role;
select is((select deleted from public.messages where id = (select last from _m)), null,
          'the message is untouched: only the app-access gate stopped her');

select * from finish();
rollback;
