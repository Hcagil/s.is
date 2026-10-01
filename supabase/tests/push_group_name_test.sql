begin;
select plan(38);

-- 0.30.6: a group's notification names the group.
--
-- The delivery list (app_private.push_targets_for_message, and
-- public.push_targets over it) carries two more columns beside the wording
-- it always had:
--
--   sender  the sender's display name ('Someone' with no profile);
--           null when the RECIPIENT's preview is 'none'
--   chat    conversations.title; null for a 1:1, and null when the
--           recipient's preview is 'none'
--
-- title/body keep their old wording per preview ('full' -> "Name @ Group" +
-- text, 'sender' -> name + "New message", 'none' -> "SIS" + "New message"),
-- so an older build that only reads title/body sees nothing new. The
-- preview 'none' rows are the privacy gate: they must not leak the name or
-- the group through the new columns either.
--
-- fixtures -------------------------------------------------------------------
-- ann   sender                  display name "Ann Sender"
-- bob   group, preview full
-- cat   group, preview sender
-- dan   group, preview none
-- eve   1:1 with ann, preview full
-- fay   1:1 with ann, preview none
-- gus   group member who sends after his profile row is gone
-- hal   1:1 with ann, preview sender
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000006a001', 'ann@groupname.test', now(), '{"full_name":"Ann Sender"}'),
  ('00000000-0000-0000-0000-00000006a002', 'bob@groupname.test', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-00000006a003', 'cat@groupname.test', now(), '{"full_name":"Cat"}'),
  ('00000000-0000-0000-0000-00000006a004', 'dan@groupname.test', now(), '{"full_name":"Dan"}'),
  ('00000000-0000-0000-0000-00000006a005', 'eve@groupname.test', now(), '{"full_name":"Eve"}'),
  ('00000000-0000-0000-0000-00000006a006', 'fay@groupname.test', now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-00000006a007', 'gus@groupname.test', now(), '{"full_name":"Gus"}'),
  ('00000000-0000-0000-0000-00000006a008', 'hal@groupname.test', now(), '{"full_name":"Hal"}');
insert into app_private.allowlist(email)
  select email from auth.users where email like '%@groupname.test';
insert into app_private.tag_finds(finder, found_id)
  select '00000000-0000-0000-0000-00000006a001', id from auth.users
   where email like '%@groupname.test' and email <> 'ann@groupname.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('6a000000-0000-0000-0000-' || right(id::text, 12))::uuid, id, now(), now()
    from auth.users where email like '%@groupname.test';

create or replace function test_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', '6a000000-0000-0000-0000-' || right(uid::text, 12))::text, true);
  execute 'set local role authenticated';
end $$;

-- Every member active, on a registered phone; preview as in the fixtures.
create or replace function test_join(uid uuid, preview text) returns void language plpgsql as $$
begin
  perform test_as(uid);
  perform public.activate_session();
  perform public.register_device_token('gn-token-' || right(uid::text, 4), 'android', true);
  if preview is not null then
    insert into public.notification_settings(preview) values (preview);
  end if;
  execute 'reset role';
end $$;
select test_join('00000000-0000-0000-0000-00000006a001', null);
select test_join('00000000-0000-0000-0000-00000006a002', 'full');
select test_join('00000000-0000-0000-0000-00000006a003', 'sender');
select test_join('00000000-0000-0000-0000-00000006a004', 'none');
select test_join('00000000-0000-0000-0000-00000006a005', null);   -- default: full
select test_join('00000000-0000-0000-0000-00000006a006', 'none');
select test_join('00000000-0000-0000-0000-00000006a007', null);
select test_join('00000000-0000-0000-0000-00000006a008', 'sender');

create temp table _c (grp uuid, to_eve uuid, to_fay uuid, to_hal uuid) on commit drop;
grant select, insert on _c to authenticated;
select test_as('00000000-0000-0000-0000-00000006a001');
insert into _c select
  public.start_group_conversation('Night Shift', array[
    '00000000-0000-0000-0000-00000006a002', '00000000-0000-0000-0000-00000006a003',
    '00000000-0000-0000-0000-00000006a004', '00000000-0000-0000-0000-00000006a007']::uuid[]) as grp,
  public.start_direct_conversation('00000000-0000-0000-0000-00000006a005') as to_eve,
  public.start_direct_conversation('00000000-0000-0000-0000-00000006a006') as to_fay,
  public.start_direct_conversation('00000000-0000-0000-0000-00000006a008') as to_hal;
insert into public.messages(conversation_id, sender_id, body)
  select grp, auth.uid(), 'group hello' from _c;
insert into public.messages(conversation_id, sender_id, body)
  select to_eve, auth.uid(), 'eve hello' from _c;
insert into public.messages(conversation_id, sender_id, body)
  select to_fay, auth.uid(), 'fay hello' from _c;
insert into public.messages(conversation_id, sender_id, body)
  select to_hal, auth.uid(), 'hal hello' from _c;
reset role;

create temp table _t on commit drop as
  select m.body as msg, t.*
    from public.messages m, app_private.push_targets_for_message(m.id) t
   where m.body in ('group hello', 'eve hello', 'fay hello', 'hal hello');

create or replace function test_row(msg text, who text)
returns table (title text, body text, sender text, chat text) language sql as $$
  select t.title, t.body, t.sender, t.chat from _t t
    join auth.users u on u.id = t.user_id
   where t.msg = test_row.msg and u.email = who || '@groupname.test'
$$;

-- 1 group, preview full: both new columns, old wording unchanged ----------
select is((select count(*) from _t where msg = 'group hello'), 4::bigint,
          'fixture: bob, cat, dan and gus are on the group message''s list');
select is((select sender from test_row('group hello', 'bob')), 'Ann Sender',
          'full: sender is the sender''s display name');
select is((select chat from test_row('group hello', 'bob')), 'Night Shift',
          'full: chat is the group''s title');
select is((select title from test_row('group hello', 'bob')), 'Ann Sender @ Night Shift',
          'full: title keeps its old "Name @ Group" wording');
select is((select body from test_row('group hello', 'bob')), 'group hello',
          'full: body is still the text');

-- 2 group, preview sender: name and group, never the text ---------------
select is((select sender from test_row('group hello', 'cat')), 'Ann Sender',
          'sender preview: sender is the name');
select is((select chat from test_row('group hello', 'cat')), 'Night Shift',
          'sender preview: chat is the group''s title');
select is((select title from test_row('group hello', 'cat')), 'Ann Sender',
          'sender preview: title unchanged (name only)');
select is((select body from test_row('group hello', 'cat')), 'New message',
          'sender preview: body unchanged');

-- 3 group, preview none: neither new column leaks who or where ------------
select is((select sender from test_row('group hello', 'dan')), null,
          'none: sender is null');
select is((select chat from test_row('group hello', 'dan')), null,
          'none: chat is null, the group name stays off the lock screen');
select is((select title from test_row('group hello', 'dan')), 'SIS',
          'none: title unchanged');
select is((select body from test_row('group hello', 'dan')), 'New message',
          'none: body unchanged');
select is((select count(*) from _t, jsonb_each_text(to_jsonb(_t))
            where _t.msg = 'group hello'
              and _t.user_id = '00000000-0000-0000-0000-00000006a004'
              and key <> 'msg'
              and (value like '%Ann%' or value like '%Night Shift%' or value like '%group hello%')),
          0::bigint, 'none: no column of dan''s row names the sender, the group or the text');

-- 4 1:1: sender present, chat null ------------------------------------------
select is((select count(*) from test_row('eve hello', 'eve')), 1::bigint,
          'fixture: eve is on the 1:1 list');
select is((select sender from test_row('eve hello', 'eve')), 'Ann Sender',
          '1:1 full: sender is the name');
select is((select chat from test_row('eve hello', 'eve')), null,
          '1:1: chat is null, a 1:1 is not a group');
select is((select title from test_row('eve hello', 'eve')), 'Ann Sender',
          '1:1 full: title unchanged (the name)');
select is((select body from test_row('eve hello', 'eve')), 'eve hello',
          '1:1 full: body unchanged');
select is((select sender from test_row('fay hello', 'fay')), null,
          '1:1 none: sender is null');
select is((select chat from test_row('fay hello', 'fay')), null,
          '1:1 none: chat is null');
select is((select title from test_row('fay hello', 'fay')), 'SIS',
          '1:1 none: title unchanged');
select is((select sender from test_row('hal hello', 'hal')), 'Ann Sender',
          '1:1 sender preview: sender is the name');
select is((select chat from test_row('hal hello', 'hal')), null,
          '1:1 sender preview: chat is null');
select is((select title from test_row('hal hello', 'hal')), 'Ann Sender',
          '1:1 sender preview: title unchanged');

-- 5 a sender with no profile row is 'Someone' in both places ---------------
delete from public.profiles where user_id = '00000000-0000-0000-0000-00000006a007';
select test_as('00000000-0000-0000-0000-00000006a007');
insert into public.messages(conversation_id, sender_id, body)
  select grp, auth.uid(), 'gus hello' from _c;
reset role;
create temp table _g on commit drop as
  select t.* from public.messages m, app_private.push_targets_for_message(m.id) t
   where m.body = 'gus hello';
select is((select sender from _g where user_id = '00000000-0000-0000-0000-00000006a002'),
          'Someone', 'no profile: sender is Someone');
select is((select title from _g where user_id = '00000000-0000-0000-0000-00000006a002'),
          'Someone @ Night Shift', 'no profile: title agrees with sender');
select is((select chat from _g where user_id = '00000000-0000-0000-0000-00000006a002'),
          'Night Shift', 'no profile: chat is still the group');
select is((select sender from _g where user_id = '00000000-0000-0000-0000-00000006a004'),
          null, 'no profile, preview none: still null, not Someone');

-- 6 public.push_targets returns the same new columns, as it claims ---------
select test_as('00000000-0000-0000-0000-00000006a001');
insert into public.messages(conversation_id, sender_id, body)
  select grp, auth.uid(), 'claimed hello' from _c;
reset role;
set local role service_role;
create temp table _p on commit drop as
  select t.* from public.messages m, public.push_targets(m.id) t
   where m.body = 'claimed hello';
reset role;
select is((select count(*) from _p), 4::bigint,
          'fixture: push_targets claims the four group recipients');
select is((select sender || '|' || chat from _p
            where user_id = '00000000-0000-0000-0000-00000006a002'),
          'Ann Sender|Night Shift', 'push_targets: full row carries sender and chat');
select is((select sender || '|' || chat from _p
            where user_id = '00000000-0000-0000-0000-00000006a003'),
          'Ann Sender|Night Shift', 'push_targets: sender-preview row carries sender and chat');
select ok((select sender is null and chat is null from _p
            where user_id = '00000000-0000-0000-0000-00000006a004'),
          'push_targets: none row carries neither');

-- 7 privileges unchanged ---------------------------------------------------
select function_privs_are('app_private', 'push_targets_for_message', array['uuid'], 'anon',
                          '{}'::text[], 'anon holds no execute on push_targets_for_message');
select function_privs_are('app_private', 'push_targets_for_message', array['uuid'], 'authenticated',
                          '{}'::text[], 'authenticated holds no execute on push_targets_for_message');
select function_privs_are('public', 'push_targets', array['uuid'], 'anon',
                          '{}'::text[], 'anon holds no execute on push_targets');
select function_privs_are('public', 'push_targets', array['uuid'], 'authenticated',
                          '{}'::text[], 'authenticated holds no execute on push_targets');
select function_privs_are('public', 'push_targets', array['uuid'], 'service_role',
                          array['EXECUTE'], 'the sender (service_role) still executes push_targets');

select * from finish();
rollback;
