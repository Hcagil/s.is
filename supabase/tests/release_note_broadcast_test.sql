begin;
select plan(68);

-- Release note broadcast (step 14). Written from the contract, not from the
-- migration:
--
-- 1. inserting a non-empty release_notes row puts ONE message from the SIS
--    system sender into the system chat of every allowed member (creating chat
--    and membership if needed, reusing an existing one), and records
--    app_private.release_note_sent(user_id, build). Not to a non-allowed
--    user, not to the system sender itself (even when it would pass the
--    allowlist gate).
-- 2. no duplicates: a second broadcast for the same build adds nothing;
--    deliver_release_notes after a broadcast adds nothing for that build but
--    still delivers other builds, silently; an empty/whitespace note delivers
--    nothing.
-- 3. one failing member does not stop the others or the insert.
-- 4. push: one net.http_post to notify_on_message_url per member per note;
--    the backstop stays silent; push_targets_for_message names the SIS
--    sender "SIS", never "Someone".
-- 5. clients cannot touch release_note_sent nor run the broadcast; the chat
--    stays read-only.

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function try_exec(stmt text) returns text
language plpgsql security invoker as $$
declare n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  return 'ok:' || n;
exception when others then
  return 'err:' || sqlstate;
end $$;
grant execute on function try_exec(text) to authenticated, anon;

-- 5 shape and grants -----------------------------------------------------------
select has_table('app_private', 'release_note_sent', 'release_note_sent exists');
select ok((select relrowsecurity from pg_class where oid = 'app_private.release_note_sent'::regclass),
          'release_note_sent has RLS on');
select is((select count(*) from pg_policies
            where schemaname = 'app_private' and tablename = 'release_note_sent'),
          0::bigint, 'release_note_sent has no policy');
select ok(not has_table_privilege('authenticated', 'app_private.release_note_sent',
                                  'select,insert,update,delete'),
          'authenticated holds no privilege on release_note_sent');
select ok(not has_table_privilege('anon', 'app_private.release_note_sent',
                                  'select,insert,update,delete'),
          'anon holds no privilege on release_note_sent');
select ok(not has_function_privilege('authenticated', 'app_private.broadcast_release_note()', 'execute'),
          'authenticated may not execute broadcast_release_note');
select ok(not has_function_privilege('anon', 'app_private.broadcast_release_note()', 'execute'),
          'anon may not execute broadcast_release_note');
select ok(has_function_privilege('authenticated', 'public.deliver_release_notes(integer)', 'execute'),
          'authenticated still may execute deliver_release_notes');
select ok(not has_function_privilege('anon', 'public.deliver_release_notes(integer)', 'execute'),
          'anon still may not execute deliver_release_notes');

-- fixtures -----------------------------------------------------------------------
-- ann   allowed, active, has a phone      gets every broadcast; push title subject
-- bo    allowed                           gets every broadcast
-- cara  allowed, already has a SIS chat   chat is reused, not duplicated
-- dan   allowed only AFTER 497/498         backstop delivers 498 silently
-- fay   allowed, her insert is made to fail (section 3)
-- zed   not on the allowlist              gets nothing
-- una   allowlisted, email NOT confirmed  fails only is_allowed's confirmation
-- SIS   the system sender, made to pass the allowlist gate: still no self-chat
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000b1401', 'ann.rnb@sis.test',  now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000b1402', 'bo.rnb@sis.test',   now(), '{"full_name":"Bo"}'),
  ('00000000-0000-0000-0000-0000000b1403', 'cara.rnb@sis.test', now(), '{"full_name":"Cara"}'),
  ('00000000-0000-0000-0000-0000000b1404', 'dan.rnb@sis.test',  now(), '{"full_name":"Dan"}'),
  ('00000000-0000-0000-0000-0000000b1405', 'fay.rnb@sis.test',  now(), '{"full_name":"Fay"}'),
  ('00000000-0000-0000-0000-0000000b1406', 'zed.rnb@sis.test',  now(), '{"full_name":"Zed"}'),
  ('00000000-0000-0000-0000-0000000b1407', 'una.rnb@sis.test',  null,  '{"full_name":"Una"}');
insert into app_private.allowlist(email) values
  ('ann.rnb@sis.test'), ('bo.rnb@sis.test'), ('cara.rnb@sis.test'),
  ('fay.rnb@sis.test'), ('una.rnb@sis.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b1400000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000b1401', now(), now()),
  ('b1400000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000b1403', now(), now()),
  ('b1400000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000b1404', now(), now()),
  ('b1400000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000b1405', now(), now());
create function as_ann()  returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000b1401', 'b1400000-0000-0000-0000-000000000001') $$;
create function as_cara() returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000b1403', 'b1400000-0000-0000-0000-000000000003') $$;
create function as_dan()  returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000b1404', 'b1400000-0000-0000-0000-000000000004') $$;
create function as_fay()  returns void language sql as $$ select test_as('00000000-0000-0000-0000-0000000b1405', 'b1400000-0000-0000-0000-000000000005') $$;
grant execute on function as_ann(), as_cara(), as_dan(), as_fay() to authenticated;
select as_ann();  select is(public.activate_session(), true, 'ann is active');  reset role;
select as_cara(); select is(public.activate_session(), true, 'cara is active'); reset role;
select as_fay();  select is(public.activate_session(), true, 'fay is active');  reset role;
insert into app_private.device_tokens(user_id, token, platform, session_id) values
  ('00000000-0000-0000-0000-0000000b1401', 'rnb-ann-phone', 'android', 'b1400000-0000-0000-0000-000000000001');

-- bot   allowed, registered as a bot     the bot gets no release notes (sis_bot)
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000b1408', 'bot.rnb@sis.test', now());
insert into app_private.allowlist(email) values ('bot.rnb@sis.test');
insert into public.conversations(id) values ('c1400000-0000-0000-0000-0000000000db');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
  values ('00000000-0000-0000-0000-0000000b1408', 'c1400000-0000-0000-0000-0000000000db', true);
select ok(app_private.is_allowed('00000000-0000-0000-0000-0000000b1408'),
          'fixture: the bot passes is_allowed, so only a bot rule can keep notes away');

-- The system sender passes every is_allowed clause here, so a self-chat could
-- only be stopped by the "not the sender" rule.
update auth.users set email = 'sis.rnb@sis.test', email_confirmed_at = now()
 where id = '00000000-0000-0000-0000-00000000515e';
insert into app_private.allowlist(email) values ('sis.rnb@sis.test');
select ok(app_private.is_allowed('00000000-0000-0000-0000-00000000515e'),
          'fixture: the system sender passes is_allowed in this test');
select ok(not app_private.is_allowed('00000000-0000-0000-0000-0000000b1407'),
          'fixture: una fails is_allowed (email unconfirmed) though allowlisted');
select ok(not app_private.is_allowed('00000000-0000-0000-0000-0000000b1406'),
          'fixture: zed fails is_allowed');

-- Messages in system chats, per member.
create view sis_inbox as
  select cm.user_id, m.id as message_id, m.conversation_id, m.sender_id, m.body, m.created_at
    from public.conversation_members cm
    join public.conversations c on c.id = cm.conversation_id and c.system
    join public.messages m on m.conversation_id = cm.conversation_id;
create function inbox(uid uuid, b text) returns bigint language sql as $$
  select count(*) from sis_inbox where user_id = uid and body = b $$;
create function sis_chats(uid uuid) returns bigint language sql as $$
  select count(*) from public.conversation_members cm
    join public.conversations c on c.id = cm.conversation_id and c.system
   where cm.user_id = uid $$;

delete from public.release_notes;
select isnt(vault.create_secret('https://rnb-test.local/hook', 'notify_on_message_url'), null,
            'a notify URL is configured');

-- dan is not allowed yet: 497 and 498 never reach him by broadcast.
insert into public.release_notes(build, note) values (497, 'n497'), (498, 'n498');
select is(inbox('00000000-0000-0000-0000-0000000b1404', 'n498'), 0::bigint,
          'control: dan (not yet allowed) got no broadcast of 498');
insert into app_private.allowlist(email) values ('dan.rnb@sis.test');
select as_dan(); select is(public.activate_session(), true, 'dan is active');
select is(public.deliver_release_notes(497), 1, 'dan first backstop call at 497 delivers one note');
reset role;

-- cara already has her SIS chat before the broadcast.
select is(sis_chats('00000000-0000-0000-0000-0000000b1403'), 1::bigint, 'cara has one SIS chat (497/498 broadcast)');
select is(sis_chats('00000000-0000-0000-0000-0000000b1401'), 1::bigint, 'ann has one SIS chat');

-- 1 the broadcast --------------------------------------------------------------
create temp table q0 as select count(*) as n from net.http_request_queue;
insert into public.release_notes(build, note) values (500, 'Version 0.50
- Faster chats');

select is(inbox('00000000-0000-0000-0000-0000000b1401', 'Version 0.50
- Faster chats'), 1::bigint, 'ann has exactly one 500 note');
select is(inbox('00000000-0000-0000-0000-0000000b1402', 'Version 0.50
- Faster chats'), 1::bigint, 'bo (no session, no chat before) has exactly one 500 note');
select is(inbox('00000000-0000-0000-0000-0000000b1403', 'Version 0.50
- Faster chats'), 1::bigint, 'cara has exactly one 500 note');
select is(inbox('00000000-0000-0000-0000-0000000b1404', 'Version 0.50
- Faster chats'), 1::bigint, 'dan has exactly one 500 note');
select is((select count(distinct sender_id) || ':' || min(sender_id::text) from sis_inbox
            where body like 'Version 0.50%'),
          '1:00000000-0000-0000-0000-00000000515e', 'every 500 note is from the SIS system sender');
select is(sis_chats('00000000-0000-0000-0000-0000000b1403'), 1::bigint,
          'cara''s existing SIS chat is reused, not duplicated');
select is(sis_chats('00000000-0000-0000-0000-0000000b1402'), 1::bigint,
          'bo got a SIS chat created for him');
select is((select count(*) from public.messages m
            join public.conversations c on c.id = m.conversation_id and c.system
            join public.conversation_members cm on cm.conversation_id = m.conversation_id
                 and cm.user_id = '00000000-0000-0000-0000-0000000b1402'
           where m.body like 'Version 0.50%'), 1::bigint,
          'bo''s note sits in a system conversation he is a member of');
select is(inbox('00000000-0000-0000-0000-0000000b1406', 'Version 0.50
- Faster chats'), 0::bigint, 'zed (not allowed) gets nothing');
select is(sis_chats('00000000-0000-0000-0000-0000000b1406'), 0::bigint, 'and no SIS chat');
select is(sis_chats('00000000-0000-0000-0000-0000000b1407'), 0::bigint, 'una (unconfirmed) gets no SIS chat');
select is((select count(*) from public.conversations
            where system and direct_key = 'system:00000000-0000-0000-0000-00000000515e'),
          0::bigint, 'the system sender gets no SIS chat of its own');
select is((select count(*) from public.messages m
            join public.conversations c on c.id = m.conversation_id
           where m.body like 'Version 0.50%'
             and not exists (select 1 from public.conversation_members cm
                              where cm.conversation_id = c.id
                                and cm.user_id <> '00000000-0000-0000-0000-00000000515e')),
          0::bigint, 'no 500 note lands in a chat with nobody but the sender');
select is(sis_chats('00000000-0000-0000-0000-0000000b1408'), 0::bigint,
          'the bot gets no release note broadcast');
select is((select string_agg(right(user_id::text, 4), ',' order by user_id)
             from app_private.release_note_sent
            where build = 500 and user_id::text like '00000000-0000-0000-0000-0000000b14%'),
          '1401,1402,1403,1404,1405', 'release_note_sent records 500 for every allowed fixture member');
select is((select count(*) from app_private.release_note_sent
            where build = 500 and user_id in ('00000000-0000-0000-0000-0000000b1406',
              '00000000-0000-0000-0000-0000000b1407', '00000000-0000-0000-0000-00000000515e')),
          0::bigint, 'and nothing for zed, una or the system sender');
select is((select count(*) from app_private.release_note_sent where build = 500),
          (select count(*) from public.messages where body like 'Version 0.50%'),
          'one message per recorded member, no more');

-- 4 push ---------------------------------------------------------------------
select is((select count(*) from net.http_request_queue) - (select n from q0),
          (select count(*) from app_private.release_note_sent where build = 500),
          'exactly one push request per member for the note');
select is((select count(*) from net.http_request_queue where url <> 'https://rnb-test.local/hook'),
          0::bigint, 'every push goes to notify_on_message_url');
select ok((select bool_and(exists (select 1 from net.http_request_queue q
                                    where convert_from(q.body, 'utf8') like '%' || i.message_id || '%'))
             from sis_inbox i
            where i.body like 'Version 0.50%'
              and i.user_id::text like '00000000-0000-0000-0000-0000000b14%'),
          'each fixture member''s note has its own push request');
select is((select title from app_private.push_targets_for_message(
             (select message_id from sis_inbox where user_id = '00000000-0000-0000-0000-0000000b1401'
                and body like 'Version 0.50%'))
            where user_id = '00000000-0000-0000-0000-0000000b1401'),
          'SIS', 'the push for ann is titled SIS');
select is((select count(*) from app_private.push_targets_for_message(
             (select message_id from sis_inbox where user_id = '00000000-0000-0000-0000-0000000b1401'
                and body like 'Version 0.50%')) t
            where t.title like '%Someone%' or t.sender like '%Someone%' or t.body like '%Someone%'),
          0::bigint, 'never "Someone"');
insert into public.notification_settings(user_id, preview) values ('00000000-0000-0000-0000-0000000b1401', 'sender')
  on conflict (user_id) do update set preview = 'sender';
select is((select title || '|' || coalesce(sender, '<null>') from app_private.push_targets_for_message(
             (select message_id from sis_inbox where user_id = '00000000-0000-0000-0000-0000000b1401'
                and body like 'Version 0.50%'))
            where user_id = '00000000-0000-0000-0000-0000000b1401'),
          'SIS|SIS', 'with sender-only previews the title and sender are SIS too');
delete from public.notification_settings where user_id = '00000000-0000-0000-0000-0000000b1401';

-- 2 no duplicates ------------------------------------------------------------
create temp table q1 as select count(*) as n from net.http_request_queue;
delete from public.release_notes where build = 500;
insert into public.release_notes(build, note) values (500, 'Version 0.50
- Faster chats');
select is(inbox('00000000-0000-0000-0000-0000000b1401', 'Version 0.50
- Faster chats'), 1::bigint, 'a second broadcast of 500 adds nothing for ann');
select is((select count(*) from public.messages where body like 'Version 0.50%'),
          (select count(*) from app_private.release_note_sent where build = 500),
          'nor for anyone');
select is((select count(*) from net.http_request_queue), (select n from q1),
          'and queues no push');

select as_ann();
select is(public.deliver_release_notes(500), 0, 'ann''s backstop call at 500 delivers nothing');
reset role;
select is(inbox('00000000-0000-0000-0000-0000000b1401', 'Version 0.50
- Faster chats'), 1::bigint, 'ann still has exactly one 500 note');

select as_dan();
select is(public.deliver_release_notes(500), 1, 'dan''s backstop at 500 delivers one note: 498, not 500');
reset role;
select is(inbox('00000000-0000-0000-0000-0000000b1404', 'n498'), 1::bigint, 'dan now has 498');
select is(inbox('00000000-0000-0000-0000-0000000b1404', 'Version 0.50
- Faster chats'), 1::bigint, 'and still one 500');
select is((select count(*) from net.http_request_queue), (select n from q1),
          'the backstop delivery queued no push');

-- empty and whitespace notes
create temp table m0 as select count(*) as n from public.messages;
insert into public.release_notes(build, note) values (501, ''), (502, E'  \n\t ');
select is((select count(*) from public.messages), (select n from m0), 'empty / whitespace notes post nothing');
select is((select count(*) from app_private.release_note_sent where build in (501, 502)), 0::bigint,
          'and record nothing');
select is((select count(*) from net.http_request_queue), (select n from q1), 'and queue no push');

-- 3 one failing member ---------------------------------------------------------
create function fail_for_fay() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.conversation_members
              where conversation_id = new.conversation_id
                and user_id = '00000000-0000-0000-0000-0000000b1405') then
    raise exception 'fay is broken';
  end if;
  return new;
end $$;
create trigger zz_fail_for_fay before insert on public.messages
  for each row execute function fail_for_fay();

select lives_ok($$insert into public.release_notes(build, note) values (503, 'n503')$$,
                'a member whose message fails does not fail the release_notes insert');
select is((select count(*) from public.release_notes where build = 503), 1::bigint, 'the 503 row is stored');
select is(inbox('00000000-0000-0000-0000-0000000b1401', 'n503'), 1::bigint, 'ann still gets 503');
select is(inbox('00000000-0000-0000-0000-0000000b1402', 'n503'), 1::bigint, 'bo still gets 503');
select is(inbox('00000000-0000-0000-0000-0000000b1403', 'n503'), 1::bigint, 'cara still gets 503');
select is(inbox('00000000-0000-0000-0000-0000000b1404', 'n503'), 1::bigint, 'dan still gets 503');
select is(inbox('00000000-0000-0000-0000-0000000b1405', 'n503'), 0::bigint, 'fay does not');
select is((select count(*) from app_private.release_note_sent
            where build = 503 and user_id = '00000000-0000-0000-0000-0000000b1405'), 0::bigint,
          'fay is not recorded as sent, so the backstop can still reach her');
drop trigger zz_fail_for_fay on public.messages;

-- 5 read-only -------------------------------------------------------------------
select as_ann();
select isnt(try_exec($$insert into public.messages(conversation_id, sender_id, body)
                      select conversation_id, auth.uid(), 'hi'
                        from public.conversation_members cm join public.conversations c
                          on c.id = cm.conversation_id and c.system
                       where cm.user_id = auth.uid()$$),
            'ok:1', 'ann cannot write into her SIS chat');
select matches(try_exec($$select * from app_private.release_note_sent$$), '^err:',
            'ann cannot read release_note_sent');
select matches(try_exec($$insert into app_private.release_note_sent(user_id, build) values (auth.uid(), 900)$$),
            '^err:', 'ann cannot write release_note_sent');
reset role;

select * from finish();
rollback;
