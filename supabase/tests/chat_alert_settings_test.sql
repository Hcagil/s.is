begin;
select plan(38);

-- chat_alert_settings: a member reads and writes only their own rows, only for
-- chats they are in; no anon access. public.push_alerts is for service_role
-- only and resolves each user's sound and vibration: a chat's on/off wins,
-- default or no row follows notification_settings.alert_*, no settings row = on.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

-- Rows touched by an UPDATE or DELETE, as the caller: a row RLS hides is not
-- an error, it is simply not touched.
create or replace function test_row_count(stmt text)
returns bigint language plpgsql security invoker as $$
declare n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function test_row_count(text) to authenticated;

-- fixtures ---------------------------------------------------------------
-- ann   allowlisted, active           the subject: her settings and mutes
-- bo    allowlisted, active           sends to ann; a valid person-mute target
-- cleo  allowlisted, active           third member of the group; another sender
-- dee   allowlisted, active -> revoked   proves the session gate on both tables
-- fay   allowlisted, active           shares a conversation with bo only
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000ca001', 'ann@cas.test',  now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000ca002', 'bo@cas.test',   now(), '{"full_name":"Bo"}'),
  ('00000000-0000-0000-0000-0000000ca003', 'cleo@cas.test', now(), '{"full_name":"Cleo"}'),
  ('00000000-0000-0000-0000-0000000ca004', 'dee@cas.test',  now(), '{"full_name":"Dee"}'),
  ('00000000-0000-0000-0000-0000000ca005', 'fay@cas.test',  now(), '{"full_name":"Fay"}');
insert into app_private.allowlist(email) values
  ('ann@cas.test'), ('bo@cas.test'), ('cleo@cas.test'), ('dee@cas.test'), ('fay@cas.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000ca002'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000ca003'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000ca004'),
  ('00000000-0000-0000-0000-0000000ca005', '00000000-0000-0000-0000-0000000ca002');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ca000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000ca001', now(), now()),
  ('ca000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000ca002', now(), now()),
  ('ca000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000ca003', now(), now()),
  ('ca000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000ca004', now(), now()),
  ('ca000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000ca005', now(), now());

-- activate sessions -------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000ca001', 'ca000000-0000-0000-0000-000000000001');
select is(public.activate_session(), true, 'ann is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca002', 'ca000000-0000-0000-0000-000000000002');
select is(public.activate_session(), true, 'bo is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca003', 'ca000000-0000-0000-0000-000000000003');
select is(public.activate_session(), true, 'cleo is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca004', 'ca000000-0000-0000-0000-000000000004');
select is(public.activate_session(), true, 'dee is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca005', 'ca000000-0000-0000-0000-000000000005');
select is(public.activate_session(), true, 'fay is active');
reset role;

-- start conversations ------------------------------------------------------
select test_as('00000000-0000-0000-0000-0000000ca001', 'ca000000-0000-0000-0000-000000000001');
select isnt(public.start_group_conversation('ca-group', array['00000000-0000-0000-0000-0000000ca002','00000000-0000-0000-0000-0000000ca003']::uuid[]), null, 'ann starts ca-group');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca001', 'ca000000-0000-0000-0000-000000000001');
select isnt(public.start_group_conversation('ca-group2', array['00000000-0000-0000-0000-0000000ca004']::uuid[]), null, 'ann starts ca-group2');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca005', 'ca000000-0000-0000-0000-000000000005');
select isnt(public.start_direct_conversation('00000000-0000-0000-0000-0000000ca002'), null, 'fay starts a one-to-one with bo');
reset role;

-- temp tables for conversation ids -----------------------------------------
create temp table _grp as
  select c.id from public.conversations c where btrim(coalesce(c.title,'')) = 'ca-group';
create temp table _grp2 as
  select c.id from public.conversations c where btrim(coalesce(c.title,'')) = 'ca-group2';
create temp table _other as
  select c.id
    from public.conversations c
    join public.conversation_members a on a.conversation_id = c.id
     and a.user_id = '00000000-0000-0000-0000-0000000ca005'
    join public.conversation_members b on b.conversation_id = c.id
     and b.user_id = '00000000-0000-0000-0000-0000000ca002'
   where c.direct_key is not null;
grant select on _grp, _grp2, _other to authenticated;

-- structure tests ---------------------------------------------------------
select is((select relrowsecurity from pg_class where oid='public.chat_alert_settings'::regclass), true, 'row level security is enabled on chat_alert_settings');
select table_privs_are('public','chat_alert_settings','anon','{}'::text[],'anon holds no privilege on chat_alert_settings');
select ok(has_function_privilege('service_role','public.push_alerts(uuid,uuid[])','EXECUTE'),'push_alerts: service_role may run it');
select ok(not has_function_privilege('authenticated','public.push_alerts(uuid,uuid[])','EXECUTE'),'push_alerts: authenticated may not');
select ok(not has_function_privilege('anon','public.push_alerts(uuid,uuid[])','EXECUTE'),'push_alerts: anon may not');

-- BLOCK RLS
select test_as('00000000-0000-0000-0000-0000000ca001', 'ca000000-0000-0000-0000-000000000001');
select lives_ok($$insert into public.chat_alert_settings(conversation_id, sound) select id, 'off' from _grp$$, 'ann saves a choice for her group');
select is((select count(*) from public.chat_alert_settings)::int, 1, 'ann sees her one row');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca002', 'ca000000-0000-0000-0000-000000000002');
select is((select count(*) from public.chat_alert_settings where conversation_id = (select id from _grp))::int, 0, 'bo, a member of the same group, sees none of ann''s rows');
select is(test_row_count('update public.chat_alert_settings set sound = ''on'' where user_id = ''00000000-0000-0000-0000-0000000ca001'''), 0::bigint, 'bo cannot update ann''s row');
select is(test_row_count('delete from public.chat_alert_settings where user_id = ''00000000-0000-0000-0000-0000000ca001'''), 0::bigint, 'bo cannot delete ann''s row');
select throws_ok($$insert into public.chat_alert_settings(user_id, conversation_id, sound) select '00000000-0000-0000-0000-0000000ca003', id, 'on' from _grp$$, '42501', null, 'bo cannot write a row for another user, even in a chat he is in');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca001', 'ca000000-0000-0000-0000-000000000001');
select throws_ok($$insert into public.chat_alert_settings(conversation_id, sound) select id, 'on' from _other$$, '42501', null, 'ann cannot save a choice for a chat she is not in');
select throws_ok($$insert into public.chat_alert_settings(conversation_id, sound) select id, 'loud' from _grp2$$, '23514', null, 'a choice other than default, on, off is refused');
select is(test_row_count('update public.chat_alert_settings set vibration = ''on'' where true'), 1::bigint, 'ann updates her own row');
select is((select vibration from public.chat_alert_settings), 'on', 'her update was kept');
select throws_ok($$update public.chat_alert_settings set conversation_id = (select id from _other)$$, '42501', null, 'ann cannot move her row to a chat she is not in');
reset role;
set local role anon;
select throws_ok($$select count(*) from public.chat_alert_settings$$, '42501', null, 'anon cannot read the table');
reset role;
select test_as('00000000-0000-0000-0000-0000000ca004', 'ca000000-0000-0000-0000-000000000004');
select lives_ok($$insert into public.chat_alert_settings(conversation_id, sound) select id, 'on' from _grp2$$, 'dee saves a choice while her session is active');
reset role;
delete from auth.sessions where id = 'ca000000-0000-0000-0000-000000000004';
select test_as('00000000-0000-0000-0000-0000000ca004', 'ca000000-0000-0000-0000-000000000004');
select is((select count(*) from public.chat_alert_settings)::int, 0, 'dee loses access with her session');
reset role;

insert into public.chat_alert_settings(user_id, conversation_id, sound) select '00000000-0000-0000-0000-0000000ca003', id, 'on' from _grp;
delete from app_private.allowlist where email = 'cleo@cas.test';
select test_as('00000000-0000-0000-0000-0000000ca003', 'ca000000-0000-0000-0000-000000000003');
select is((select count(*) from public.chat_alert_settings)::int, 0, 'cleo, removed from the allowlist with an active session, can no longer read her rows');
select throws_ok($$insert into public.chat_alert_settings(conversation_id, sound) select id, 'off' from _grp$$, '42501', null, 'cleo, removed from the allowlist, can no longer insert (she is still a member of the chat)');
select is(test_row_count('update public.chat_alert_settings set sound = ''off'' where user_id = ''00000000-0000-0000-0000-0000000ca003'''), 0::bigint, 'cleo, removed from the allowlist, can no longer update her row');
reset role;

-- BLOCK RESOLUTION
reset role;
delete from public.chat_alert_settings;
grant select on _grp, _grp2 to service_role;
set local role service_role;
select results_eq($$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca001','00000000-0000-0000-0000-0000000ca002','00000000-0000-0000-0000-0000000ca003']::uuid[]) order by user_id$$, $$values ('00000000-0000-0000-0000-0000000ca001', true, true), ('00000000-0000-0000-0000-0000000ca002', true, true), ('00000000-0000-0000-0000-0000000ca003', true, true)$$, 'no settings at all: everybody gets sound and vibration');
reset role;
insert into public.notification_settings(user_id, alert_sound, alert_vibration) values ('00000000-0000-0000-0000-0000000ca001', false, false), ('00000000-0000-0000-0000-0000000ca002', true, true), ('00000000-0000-0000-0000-0000000ca003', true, false);
set local role service_role;
select results_eq($$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca001']::uuid[])$$, $$values ('00000000-0000-0000-0000-0000000ca001', false, false)$$, 'no chat row: the account defaults apply');
reset role;
insert into public.chat_alert_settings(user_id, conversation_id, sound, vibration) select '00000000-0000-0000-0000-0000000ca001', id, 'default', 'default' from _grp;
set local role service_role;
select results_eq($$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca001']::uuid[])$$, $$values ('00000000-0000-0000-0000-0000000ca001', false, false)$$, 'a chat row set to default follows the account defaults');
reset role;
update public.chat_alert_settings set sound = 'on' where user_id = '00000000-0000-0000-0000-0000000ca001';
set local role service_role;
select results_eq($$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca001']::uuid[])$$, $$values ('00000000-0000-0000-0000-0000000ca001', true, false)$$, 'chat sound on wins, vibration still follows the account');
reset role;
insert into public.chat_alert_settings(user_id, conversation_id, sound, vibration) select '00000000-0000-0000-0000-0000000ca002', id, 'off', 'on' from _grp;
insert into public.chat_alert_settings(user_id, conversation_id, sound, vibration) select '00000000-0000-0000-0000-0000000ca003', id, 'off', 'off' from _grp2;
set local role service_role;
select results_eq($$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca002']::uuid[])$$, $$values ('00000000-0000-0000-0000-0000000ca002', false, true)$$, 'chat sound off and vibration on win over the account');
select results_eq($$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca003']::uuid[])$$, $$values ('00000000-0000-0000-0000-0000000ca003', true, false)$$, 'a choice for a different chat does not apply');
select results_eq($$select user_id::text, sound, vibration from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca001','00000000-0000-0000-0000-0000000ca002','00000000-0000-0000-0000-0000000ca003']::uuid[]) order by user_id$$, $$values ('00000000-0000-0000-0000-0000000ca001', true, false), ('00000000-0000-0000-0000-0000000ca002', false, true), ('00000000-0000-0000-0000-0000000ca003', true, false)$$, 'one call resolves every user separately');
select is((select count(*) from public.push_alerts((select id from _grp), array['00000000-0000-0000-0000-0000000ca001']::uuid[]))::int, 1, 'only the asked user comes back');
reset role;

select * from finish();
rollback;
