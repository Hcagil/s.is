-- delete_message() on the server clock (migration 20261110120000):
--   sender: own message within 6 h, 1:1 and group; group admin: any message
--   at any age (always a placeholder, deleted_by_admin = true), own message
--   after 6 h too (deleted_by_admin = true), own within 6 h as a sender
--   (false). Sender delete under 15 min vanishes, from 15 min a placeholder.
--   Every delete erases all content, reactions, poll options/votes, the pin,
--   and queues the Storage files. Written from the contract, not the body.
--
-- Each refusal fails ONE gate: cat is a member who does not own the message;
-- bob is the sender but past 6 h (sender gate alone, not an admin).
--   ann admin of G   bob member, sender   cat member   dan only in the 1:1 D
begin;
select plan(73);

set local storage.allow_delete_query = 'true';

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000d8001', 'dm-ann@sis.test', now(), '{"full_name":"Ann"}'),
  ('00000000-0000-0000-0000-0000000d8002', 'dm-bob@sis.test', now(), '{"full_name":"Bob"}'),
  ('00000000-0000-0000-0000-0000000d8003', 'dm-cat@sis.test', now(), '{"full_name":"Cat"}');
insert into app_private.allowlist(email) values ('dm-ann@sis.test'), ('dm-bob@sis.test'), ('dm-cat@sis.test');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000d8001', '00000000-0000-0000-0000-0000000d8002'),
  ('00000000-0000-0000-0000-0000000d8001', '00000000-0000-0000-0000-0000000d8003'),
  ('00000000-0000-0000-0000-0000000d8002', '00000000-0000-0000-0000-0000000d8003');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('d8000000-0000-0000-0000-0000000d8001', '00000000-0000-0000-0000-0000000d8001', now(), now()),
  ('d8000000-0000-0000-0000-0000000d8002', '00000000-0000-0000-0000-0000000d8002', now(), now()),
  ('d8000000-0000-0000-0000-0000000d8003', '00000000-0000-0000-0000-0000000d8003', now(), now());

create or replace function test_as(who text) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-0000000d80' || who)::uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', 'd8000000-0000-0000-0000-0000000d80' || who)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('01'); select is(public.activate_session(), true, 'ann is active'); reset role;
select test_as('02'); select is(public.activate_session(), true, 'bob is active'); reset role;
select test_as('03'); select is(public.activate_session(), true, 'cat is active'); reset role;

create temp table _c (k text, id uuid);
grant select, insert on _c to authenticated;
select test_as('01');
insert into _c select 'G', public.start_group_conversation('dm group', array[
  '00000000-0000-0000-0000-0000000d8002', '00000000-0000-0000-0000-0000000d8003']::uuid[]);
reset role;
select test_as('02');
insert into _c select 'D', public.start_direct_conversation('00000000-0000-0000-0000-0000000d8003');
reset role;
create function c(k text) returns uuid language sql as $$ select id from _c where _c.k = $1 $$;
grant execute on function c(text) to authenticated;

-- m(name, conversation, sender, age): a text message of an exact age, as postgres
create temp table _m (k text, id uuid);
grant select on _m to authenticated;
create function mk(k text, conv uuid, sender text, age interval, extra text default '') returns void language plpgsql as $$
begin
  insert into public.messages(conversation_id, sender_id, body, created_at)
  values (conv, ('00000000-0000-0000-0000-0000000d80' || sender)::uuid, 'dm ' || k, now() - age);
  insert into _m select k, id from public.messages where body = 'dm ' || k and conversation_id = conv;
end $$;
create function m(k text) returns uuid language sql as $$ select id from _m where _m.k = $1 $$;
grant execute on function m(text) to authenticated;
create function st(k text) returns text language sql as $$
  select coalesce(deleted, 'live') || '/' || deleted_by_admin from public.messages where id = m(k) $$;

select mk('b_in',     c('G'), '02', interval '6 hours' - interval '1 second');
select mk('b_out',    c('G'), '02', interval '6 hours' + interval '1 second');
select mk('b_old',    c('G'), '02', interval '30 days');
select mk('b_new',    c('G'), '02', interval '1 minute');
select mk('b_v',      c('G'), '02', interval '15 minutes' - interval '1 second');
select mk('b_p',      c('G'), '02', interval '15 minutes');
select mk('b_cat',    c('G'), '02', interval '2 hours');
select mk('a_old',    c('G'), '01', interval '7 hours');
select mk('a_mid',    c('G'), '01', interval '1 hour');
select mk('a_new',    c('G'), '01', interval '1 minute');
select mk('d_in',     c('D'), '02', interval '6 hours' - interval '1 second');
select mk('d_out',    c('D'), '02', interval '6 hours' + interval '1 second');
select mk('d_other',  c('D'), '02', interval '2 hours');
select mk('d_new',    c('D'), '02', interval '1 minute');
select mk('d_old',    c('D'), '02', interval '1 hour');

-- A sender window, group and 1:1 ------------------------------------------------
select test_as('02');
select lives_ok(format($$select public.delete_message(%L)$$, m('b_in')), 'A group: sender at 6 h - 1 s may delete');
select throws_ok(format($$select public.delete_message(%L)$$, m('b_out')), '42501', 'not permitted',
                 'A group: sender at 6 h + 1 s is refused');
select lives_ok(format($$select public.delete_message(%L)$$, m('d_in')), 'A 1:1: sender at 6 h - 1 s may delete');
select throws_ok(format($$select public.delete_message(%L)$$, m('d_out')), '42501', 'not permitted',
                 'A 1:1: sender at 6 h + 1 s is refused');
reset role;
select is(st('b_in'), 'placeholder/false', 'A in-window sender delete: placeholder, not by admin');
select is(st('b_out'), 'live/false', 'A refused late delete leaves the row live');
select is((select body from public.messages where id = m('b_out')), 'dm b_out', 'A refused delete leaves the body');
select is(st('d_out'), 'live/false', 'A 1:1 refused late delete leaves the row live');

-- B admin deletes another's message ------------------------------------------------
select test_as('01');
select lives_ok(format($$select public.delete_message(%L)$$, m('b_old')), 'B admin deletes a 30-day-old member message');
select lives_ok(format($$select public.delete_message(%L)$$, m('b_new')), 'B admin deletes a 1-minute-old member message');
reset role;
select is(st('b_old'), 'placeholder/true', 'B old message: placeholder deleted by admin');
select is(st('b_new'), 'placeholder/true', 'B fresh message: still a placeholder (never vanished), by admin');
select is((select deleted_by from public.messages where id = m('b_new')),
          '00000000-0000-0000-0000-0000000d8001'::uuid, 'B deleted_by is the admin');

-- C / D admin deleting own ----------------------------------------------------------
select test_as('01');
select lives_ok(format($$select public.delete_message(%L)$$, m('a_old')), 'C admin deletes own message after 6 h');
select lives_ok(format($$select public.delete_message(%L)$$, m('a_mid')), 'D admin deletes own message at 1 h');
select lives_ok(format($$select public.delete_message(%L)$$, m('a_new')), 'F admin deletes own message at 1 min');
reset role;
select is(st('a_old'), 'placeholder/true', 'C own after 6 h: placeholder, by admin');
select is(st('a_mid'), 'placeholder/false', 'D own within 6 h: placeholder, NOT by admin');
select is(st('a_new'), 'vanished/false', 'F admin own under 15 min: vanished, not by admin');

-- E refusals ---------------------------------------------------------------------------
select test_as('03');
select throws_ok(format($$select public.delete_message(%L)$$, m('b_cat')), '42501', 'not permitted',
                 'E a member cannot delete another member''s message');
select throws_ok(format($$select public.delete_message(%L)$$, m('d_other')), '42501', 'not permitted',
                 'E in 1:1 nobody deletes the other person''s message');
reset role;
select is(st('b_cat'), 'live/false', 'E refused group delete: row unchanged');
select is(st('d_other'), 'live/false', 'E refused 1:1 delete: row unchanged');
select is((select deleted_at from public.messages where id = m('b_cat')), null, 'E refused: deleted_at still null');

-- F sender 15-minute rule ---------------------------------------------------------------
select test_as('02');
select lives_ok(format($$select public.delete_message(%L)$$, m('b_v')), 'F sender at 15 min - 1 s');
select lives_ok(format($$select public.delete_message(%L)$$, m('b_p')), 'F sender at 15 min');
select lives_ok(format($$select public.delete_message(%L)$$, m('d_new')), 'F 1:1 sender at 1 min');
select lives_ok(format($$select public.delete_message(%L)$$, m('d_old')), 'F 1:1 sender at 1 h');
reset role;
select is(st('b_v'), 'vanished/false', 'F 14m59s: vanished');
select is(st('b_p'), 'placeholder/false', 'F exactly 15 min: placeholder');
select is(st('d_new'), 'vanished/false', 'F 1:1 under 15 min: vanished');
select is(st('d_old'), 'placeholder/false', 'F 1:1 over 15 min: placeholder');

-- G L1 erase: a voice message with every attachment column, and a repeat path ---------------
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('attachments', c('G')::text || '/dm-voice.m4a', '00000000-0000-0000-0000-0000000d8002', '{"size":3}'::jsonb),
  ('attachments', c('G')::text || '/dm-voice.m4a.t', '00000000-0000-0000-0000-0000000d8002', '{"size":3}'::jsonb);
insert into public.messages(conversation_id, sender_id, body, attachment_path, attachment_preview, attachment_name,
    attachment_mime, attachment_size, attachment_duration_ms, attachment_waveform, voice_transcript,
    edited_at, created_at) values
  (c('G'), '00000000-0000-0000-0000-0000000d8002', 'dm voice', c('G')::text || '/dm-voice.m4a', 'iVBORw0KGgo=', 'v.m4a',
   'audio/mp4', 100, 5000, 'ab12', 'secret words', now() - interval '1 hour', now() - interval '2 hours');
-- a link card message: the picture lives in link-previews at <conversation>/<message>.jpg
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('link-previews', c('G')::text || '/d8c00000-0000-0000-0000-000000000001.jpg', '00000000-0000-0000-0000-0000000d8002', '{"size":3}'::jsonb);
insert into public.messages(id, conversation_id, sender_id, body, link_preview, created_at) values
  ('d8c00000-0000-0000-0000-000000000001', c('G'), '00000000-0000-0000-0000-0000000d8002', 'dm card mail.test/x',
   jsonb_build_object('url', 'https://mail.test/x', 'title', 'T', 'image', c('G')::text || '/d8c00000-0000-0000-0000-000000000001.jpg'),
   now() - interval '2 hours');
insert into _m values ('card', 'd8c00000-0000-0000-0000-000000000001');
insert into public.messages(conversation_id, sender_id, body, location_lat, location_lng, created_at) values
  (c('G'), '00000000-0000-0000-0000-0000000d8002', 'dm place', 12.5, 45.5, now() - interval '2 hours');
insert into public.messages(conversation_id, sender_id, body, attachment_path, photo_group, created_at) values
  (c('G'), '00000000-0000-0000-0000-0000000d8002', 'dm album', c('G')::text || '/dm-album.jpg',
   '00000000-0000-0000-0000-0000000d8999', now() - interval '2 hours');
insert into _m select 'album', id from public.messages where body = 'dm album';
insert into _m select 'voice', id from public.messages where body = 'dm voice';
insert into _m select 'place', id from public.messages where body = 'dm place';
-- a reaction on the voice message, from cat
select test_as('03');
select lives_ok(format($$select public.set_reaction(%L, %L)$$, m('voice'), '👍'), 'cat reacts to the voice message');
reset role;
select is((select count(*) from public.message_reactions where message_id = m('voice')), 1::bigint, 'the reaction row exists');
select test_as('02');
select is(public.delete_message(m('voice')), c('G')::text || '/dm-voice.m4a', 'G delete returns the old attachment path');
select lives_ok(format($$select public.delete_message(%L)$$, m('place')), 'G bob deletes the location message');
select lives_ok(format($$select public.delete_message(%L)$$, m('card')), 'G bob deletes the link card message');
select lives_ok(format($$select public.delete_message(%L)$$, m('album')), 'G bob deletes the album photo');
reset role;
select is((select count(*) from public.messages where id = m('voice') and body = '' and ciphertext is null
   and olm_type is null and attachment_path is null and attachment_preview is null and attachment_name is null
   and attachment_mime is null and attachment_size is null and attachment_duration_ms is null
   and attachment_waveform is null and voice_transcript is null and location_lat is null and location_lng is null
   and photo_group is null and sticker_id is null and sticker_album_id is null and link_preview is null
   and edited_at is null and sticker_album = false), 1::bigint, 'G voice message: every content column erased');
select is((select count(*) from public.messages where id = m('place') and body = '' and location_lat is null
   and location_lng is null), 1::bigint, 'G location message: body and location erased');
select is((select count(*) from public.messages where id = m('album') and photo_group is null and attachment_path is null),
          1::bigint, 'G album photo: photo_group and path erased');
select is((select count(*) from public.message_reactions where message_id = m('voice')), 0::bigint, 'G reactions removed');
select is((select link_preview from public.messages where id = m('card')), null, 'G link card erased');
select is((select array_agg(bucket || ':' || path order by bucket || ':' || path) from app_private.storage_removal_queue
            where path like c('G')::text || '/dm-voice%' or path like '%d8c00000%'),
          array['attachments:' || c('G')::text || '/dm-voice.m4a', 'attachments:' || c('G')::text || '/dm-voice.m4a.s', 'attachments:' || c('G')::text || '/dm-voice.m4a.t',
                'link-previews:' || c('G')::text || '/d8c00000-0000-0000-0000-000000000001.jpg'], 'G queue: attachment, its .s and .t copies and the link-card picture');
-- repeat: a second message reusing the (now free) path and card is deleted without error
insert into public.messages(conversation_id, sender_id, body, attachment_path, created_at)
  values (c('G'), '00000000-0000-0000-0000-0000000d8002', 'dm again', c('G')::text || '/dm-voice.m4a', now() - interval '1 hour');
insert into _m select 'again', id from public.messages where body = 'dm again';
select test_as('02');
select lives_ok(format($$select public.delete_message(%L)$$, m('again')), 'G repeat of the same paths does not fail');
reset role;
select is((select count(*) from app_private.storage_removal_queue
            where path like c('G')::text || '/dm-voice%' or path like '%d8c00000%'), 4::bigint,
          'G repeat adds no duplicate queue rows');

-- G poll: options, votes, reactions and the pin go away ----------------------------------
select test_as('02');
select lives_ok(format($$select public.create_poll(%L, %L, 'Lunch?', array['Pizza','Soup'], false, false)$$,
  c('G'), 'd8a00000-0000-0000-0000-000000000001'), 'bob creates a poll');
reset role;
insert into _m values ('poll', 'd8a00000-0000-0000-0000-000000000001');
update public.messages set created_at = now() - interval '1 hour' where id = m('poll');
select test_as('03');
select lives_ok(format($$select public.vote_poll(%L, array[(select id from public.poll_options where message_id = %L limit 1)])$$,
  m('poll'), m('poll')), 'cat votes');
select lives_ok(format($$select public.set_reaction(%L, %L)$$, m('poll'), '🔥'), 'cat reacts to the poll');
reset role;
select test_as('01');
select lives_ok(format($$select public.set_pinned_message(%L, %L)$$, c('G'), m('poll')), 'ann pins the poll');
reset role;
select is((select count(*) from public.poll_votes where message_id = m('poll')), 1::bigint, 'the vote exists');
select test_as('01');
select lives_ok(format($$select public.delete_message(%L)$$, m('poll')), 'ann (admin) deletes the poll message');
reset role;
select is((select count(*) from public.poll_options where message_id = m('poll')), 0::bigint, 'G poll options removed');
select is((select count(*) from public.poll_votes where message_id = m('poll')), 0::bigint, 'G poll votes removed');
select is((select count(*) from public.message_reactions where message_id = m('poll')), 0::bigint, 'G poll reactions removed');
select is((select pinned_message_id from public.conversations where id = c('G')), null, 'G pin cleared');

-- H reacting / voting on deleted or vanished is refused ---------------------------------------
select test_as('03');
select throws_ok(format($$select public.set_reaction(%L, %L)$$, m('b_in'), '👍'), '42501', null, 'H reaction on a placeholder refused');
select throws_ok(format($$select public.set_reaction(%L, %L)$$, m('b_v'), '👍'), '42501', null, 'H reaction on a vanished message refused');
select throws_ok(format($$select public.vote_poll(%L, '{}'::uuid[])$$, m('poll')), '42501', null, 'H vote on a deleted poll refused');
reset role;
select is((select count(*) from public.message_reactions where message_id in (m('b_in'), m('b_v'))), 0::bigint,
          'H no reaction row was written');

-- K (security gate) a deleted poll leaves no polls, poll_options or poll_votes row -----------
-- EXPECTED RED until the code fix: the polls row (with its question) is kept today.
select is((select count(*) from public.polls where message_id = m('poll')), 0::bigint,
          'K deleted poll: no polls row (the question) remains');

-- L (security gate) a link card cleared by an earlier edit is still queued on delete -----------
-- EXPECTED RED until the code fix: link_preview is already null when delete runs.
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('link-previews', c('G')::text || '/d8c00000-0000-0000-0000-000000000002.jpg', '00000000-0000-0000-0000-0000000d8002', '{"size":3}'::jsonb);
insert into public.messages(id, conversation_id, sender_id, body, link_preview, created_at) values
  ('d8c00000-0000-0000-0000-000000000002', c('G'), '00000000-0000-0000-0000-0000000d8002', 'dm card2 mail.test/y',
   jsonb_build_object('url', 'https://mail.test/y', 'title', 'T', 'image', c('G')::text || '/d8c00000-0000-0000-0000-000000000002.jpg'),
   now() - interval '1 hour');
insert into _m values ('card2', 'd8c00000-0000-0000-0000-000000000002');
select test_as('02');
select lives_ok(format($$select public.edit_message(%L, 'dm card2 no link now')$$, m('card2')), 'L bob edits the card away');
reset role;
select is((select link_preview from public.messages where id = m('card2')), null, 'L the edit cleared link_preview');
select test_as('02');
select lives_ok(format($$select public.delete_message(%L)$$, m('card2')), 'L bob deletes the edited message');
reset role;
select is((select count(*) from app_private.storage_removal_queue
            where bucket = 'link-previews' and path = c('G')::text || '/d8c00000-0000-0000-0000-000000000002.jpg'),
          1::bigint, 'L the old link-card picture is queued even though the edit cleared link_preview');

-- M (rule 12, security gate) a 1:1 chat with a bot account: delete for everyone refused ------
-- EXPECTED RED until the code fix. A bot chat = a direct conversation whose other member is in
-- app_private.bot_accounts. bob's own 1-minute-old message there: only the bot rule can stop him
-- (control: d_new in the ordinary 1:1 D, same age and sender, was deleted above).
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000d80b0', 'dm-bot@sis.test', now(), '{"full_name":"Bot"}');
insert into public.conversations(id, direct_key) values ('d8b00000-0000-0000-0000-000000000001', 'dm-bot-chat');
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at) values
  ('d8b00000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000d8002', 'member', now() - interval '3 days', now() - interval '3 days'),
  ('d8b00000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000d80b0', 'member', now() - interval '3 days', now() - interval '3 days');
insert into app_private.bot_accounts(user_id, debug_conversation) values
  ('00000000-0000-0000-0000-0000000d80b0', c('G'));
select mk('bot_own', 'd8b00000-0000-0000-0000-000000000001', '02', interval '1 minute');
select test_as('02');
select throws_ok(format($$select public.delete_message(%L)$$, m('bot_own')), '42501', 'not permitted',
                 'M delete for everyone is refused in a bot chat');
reset role;
select is(st('bot_own'), 'live/false', 'M refused: the bot-chat message is unchanged');

-- I unread ----------------------------------------------------------------------------------------
-- D holds, from bob: d_in, d_out(live, 7h), d_other(live), d_new(vanished), d_old(placeholder).
-- cat has read nothing: only the two live ones count.
update public.conversation_members set last_read_at = now() - interval '30 days'
 where conversation_id = c('D') and user_id = '00000000-0000-0000-0000-0000000d8003';
select test_as('03');
select is((select unread from public.unread_counts() where conversation_id = c('D')), 2,
          'I unread counts only the 2 live messages, not deleted or vanished');
reset role;

-- J the queue is closed to clients -----------------------------------------------------------------
select test_as('02');
select throws_ok($$select * from app_private.storage_removal_queue$$, '42501', null, 'J authenticated cannot select the queue');
select throws_ok($$insert into app_private.storage_removal_queue(bucket, path) values ('attachments', 'x/y')$$,
                 '42501', null, 'J authenticated cannot insert into the queue');
reset role;

select * from finish();
rollback;
