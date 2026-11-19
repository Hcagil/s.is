begin;
select plan(10);

-- fixtures ---------------------------------------------------------------
-- users
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000cb001', 'ann@cbn.test',  now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000cb002', 'bo@cbn.test',   now(), '{"full_name":"Bo"}'),
  ('00000000-0000-0000-0000-0000000cb003', 'cleo@cbn.test', now(), '{"full_name":"Cleo"}');

-- sessions
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('cb000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000cb001', now(), now()),
  ('cb000001-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000cb002', now(), now()),
  ('cb000002-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000cb003', now(), now());

-- insert allowlist entries
insert into app_private.allowlist(email) values
  ('ann@cbn.test'), ('bo@cbn.test'), ('cleo@cbn.test');

-- insert tag_finds
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000cb002'),
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000cb003');

-- helper to activate session
create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- activate sessions
select test_as('00000000-0000-0000-0000-0000000cb001', 'cb000000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'ann is active');
reset role;

select test_as('00000000-0000-0000-0000-0000000cb002', 'cb000001-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'bo is active');
reset role;

select test_as('00000000-0000-0000-0000-0000000cb003', 'cb000002-0000-0000-0000-000000000003');
select is(public.activate_session(), true, 'cleo is active');
reset role;

-- create group conversation
select test_as('00000000-0000-0000-0000-0000000cb001', 'cb000000-0000-0000-0000-000000000001');
select isnt(public.start_group_conversation('cbn-group', array['00000000-0000-0000-0000-0000000cb002','00000000-0000-0000-0000-0000000cb003']::uuid[]), null, 'ann starts cbn-group');
reset role;

-- temp table for group id
create temp table _grp as
  select c.id from public.conversations c where btrim(coalesce(c.title,'')) = 'cbn-group';
grant select on _grp to service_role;

-- (a) ann's notification_settings row inserted without alert columns
reset role;
insert into public.notification_settings(user_id) values ('00000000-0000-0000-0000-0000000cb001');
select is((select alert_sound is null and alert_vibration is null from public.notification_settings where user_id='00000000-0000-0000-0000-0000000cb001'), true, 'ann''s settings row has null alert columns');

-- (b) service_role push_alerts for ann
set local role service_role;
select results_eq(
  $$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000cb001']::uuid[])$$,
  $$values ('00000000-0000-0000-0000-0000000cb001', true, true)$$,
  'service_role sees ann with default sound/vibration');

-- (c) bo row with alert_sound=false, alert_vibration=false
reset role;
insert into public.notification_settings(user_id, alert_sound, alert_vibration) values ('00000000-0000-0000-0000-0000000cb002', false, false);
select is((select alert_sound from public.notification_settings where user_id='00000000-0000-0000-0000-0000000cb002'), false, 'bo''s alert_sound is false');
select is((select alert_vibration from public.notification_settings where user_id='00000000-0000-0000-0000-0000000cb002'), false, 'bo''s alert_vibration is false');
set local role service_role;
select results_eq(
  $$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000cb002']::uuid[])$$,
  $$values ('00000000-0000-0000-0000-0000000cb002', false, false)$$,
  'service_role sees bo with false sound/vibration');

-- (d) cleo row with alert_sound=false only, alert_vibration null
reset role;
insert into public.notification_settings(user_id, alert_sound) values ('00000000-0000-0000-0000-0000000cb003', false);
set local role service_role;
select results_eq(
  $$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000cb003']::uuid[])$$,
  $$values ('00000000-0000-0000-0000-0000000cb003', false, true)$$,
  'service_role sees cleo with false sound and default vibration');

select * from finish();
rollback;
