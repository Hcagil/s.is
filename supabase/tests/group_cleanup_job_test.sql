begin;
select plan(84);

-- Group cleanup job + storage sweeper (20261114120000_group_cleanup_job.sql), written from the contract:
--   app_private.cleanup_empty_groups(batch) wipes groups (title set, not system) with no current non-bot
--   member whose last leave (no members: created_at) is 90+ days old and that still hold an avatar or a
--   message; queues every storage path, logs counts only, keeps the conversation row.
--   public.sweeper_claim / sweeper_done: service_role only; claim drops paths still in use.
--   app_private.run_storage_sweeper(): one pg_net call only with both Vault secrets and a queue row.
-- One gate per negative fixture: every "untouched" group is eligible except for the one rule under test.

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000ec0' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), 'gc' || n || '@mail.test', now(), json_build_object('full_name', 'GC ' || n)::jsonb
  from unnest(array['01','02','03','04','99']) n;

create temp table ids(name text primary key, id uuid);
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
-- a conversation; title null = 1:1 style
create function conv(nm text, t text, sys boolean default false, dk text default null, age_d int default 200)
returns void language sql as $$
  with c as (insert into public.conversations(title, system, direct_key, created_at)
             values (t, sys, dk, now() - age_d * interval '1 day') returning id)
  insert into ids select nm, id from c
$$;
-- a member who joined 200 days ago; left_d null = current member
create function mem(nm text, who text, left_d numeric default null) returns void language sql as $$
  insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from, left_at, left_reason)
  values (g(nm), u(who), 'member', now() - interval '200 days', '-infinity',
          case when left_d is null then null else now() - left_d * interval '1 day' end,
          case when left_d is null then null else 'left' end)
$$;
create function msg(nm text, who text, b text) returns uuid language sql as $$
  insert into public.messages(conversation_id, sender_id, body, created_at)
  values (g(nm), u(who), b, now() - interval '150 days') returning id
$$;
create temp table mids(name text primary key, id uuid);
create function m(name text) returns uuid language sql stable as $$
  select id from mids where mids.name = m.name
$$;
create function q(nm text) returns text[] language sql stable as $$
  select coalesce(array_agg(bucket || ':' || path order by bucket || ':' || path), '{}')
    from app_private.storage_removal_queue where path like '%' || g(nm)::text || '%'
$$;
create function nlog(nm text) returns int language sql stable as $$
  select count(*)::int from app_private.group_cleanup_log where conversation_id = g(nm)
$$;
create function nmsg(nm text) returns int language sql stable as $$
  select count(*)::int from public.messages where conversation_id = g(nm)
$$;

-- G1: the full case. Left 91 days ago; avatar; attachment, link card, edited, plain (+reaction), poll (+vote).
select conv('G1', 'gc-g1');
select mem('G1', '01', 91); select mem('G1', '02', 95);
update public.conversations set avatar_path = g('G1')::text || '/avatar.jpg' where id = g('G1');
insert into mids values ('att', (select msg('G1', '01', 'gc att')));
update public.messages set attachment_path = g('G1')::text || '/a.jpg' where id = m('att');
insert into mids values ('card', gen_random_uuid());
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('link-previews', g('G1')::text || '/' || m('card')::text || '.jpg', u('01'), '{"size":3}'::jsonb);
insert into public.messages(id, conversation_id, sender_id, body, link_preview, created_at) values
  (m('card'), g('G1'), u('01'), 'gc card mail.test/x',
   jsonb_build_object('url', 'https://mail.test/x', 'title', 'T', 'image', g('G1')::text || '/' || m('card')::text || '.jpg'),
   now() - interval '150 days');
insert into mids values ('edit', (select msg('G1', '01', 'gc edited')));
update public.messages set edited_at = now() - interval '140 days' where id = m('edit');
insert into mids values ('plain', (select msg('G1', '02', 'gc plain')));
insert into public.message_reactions(message_id, user_id, conversation_id, emoji) values (m('plain'), u('01'), g('G1'), '👍');
insert into mids values ('poll', gen_random_uuid());
insert into public.messages(id, conversation_id, sender_id, body, poll, created_at)
  values (m('poll'), g('G1'), u('01'), 'gc question', true, now() - interval '150 days');
insert into public.polls(message_id, conversation_id, question, multiple, anonymous)
  values (m('poll'), g('G1'), 'gc question', false, false);
insert into public.poll_options(message_id, conversation_id, position, text)
  values (m('poll'), g('G1'), 0, 'yes'), (m('poll'), g('G1'), 1, 'no');
insert into public.poll_votes(option_id, user_id, message_id, conversation_id)
  select id, u('02'), m('poll'), g('G1') from public.poll_options where message_id = m('poll') and position = 0;

-- negative fixtures: each would be cleaned but for one gate
select conv('N89', 'gc-n89'); select mem('N89', '01', 89); select msg('N89', '01', 'gc n89');
update public.conversations set avatar_path = g('N89')::text || '/avatar.jpg' where id = g('N89');
-- one member left 200 days ago, another only 10 days ago: the LAST leave counts
select conv('NMAX', 'gc-nmax'); select mem('NMAX', '01', 200); select mem('NMAX', '02', 10); select msg('NMAX', '01', 'gc nmax');
-- one current human member among former members
select conv('NCUR', 'gc-ncur'); select mem('NCUR', '01', 120); select mem('NCUR', '03'); select msg('NCUR', '01', 'gc ncur');
-- 1:1 (no title), bot 1:1, system chat: everyone left long ago, messages present
select conv('N11', null, false, 'gc-dk-1'); select mem('N11', '01', 120); select mem('N11', '02', 120); select msg('N11', '01', 'gc n11');
select conv('NBOT', null, false, 'gc-dk-2'); select mem('NBOT', '01', 120); select mem('NBOT', '99', 120); select msg('NBOT', '99', 'gc nbot');
select conv('NSYS', 'gc-nsys', true); select mem('NSYS', '01', 120); select msg('NSYS', '01', 'gc nsys');
-- nothing to clean: no avatar, no message
select conv('NEMPTY', 'gc-nempty'); select mem('NEMPTY', '01', 120);
-- Debug group: only the bot is still a member; follows the rule
select conv('DBG', 'gc-debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('99'), g('DBG'), true);
select mem('DBG', '99'); select mem('DBG', '01', 100); select msg('DBG', '01', 'gc dbg');
-- no members at all: created_at is the clock (old: cleaned; young: kept)
select conv('NOMEMOLD', 'gc-nomem-old', false, null, 91); select msg('NOMEMOLD', '01', 'gc nomem old');
select conv('NOMEMNEW', 'gc-nomem-new', false, null, 89); select msg('NOMEMNEW', '01', 'gc nomem new');

-- grants and table protection
select ok((select relrowsecurity from pg_class where oid = 'app_private.group_cleanup_log'::regclass), 'log has RLS on');
select ok((select relrowsecurity from pg_class where oid = 'app_private.storage_removal_queue'::regclass), 'queue has RLS on');
select ok(not has_table_privilege(r, 'app_private.group_cleanup_log', 'select'), r || ' cannot select the log')
  from unnest(array['anon', 'authenticated']) r;
select ok(not has_table_privilege(r, 'app_private.storage_removal_queue', 'select'), r || ' cannot select the queue')
  from unnest(array['anon', 'authenticated']) r;
select ok(not has_function_privilege(r, f, 'execute'), r || ' cannot run ' || f)
  from unnest(array['anon', 'authenticated']) r,
       unnest(array['app_private.cleanup_empty_groups(integer)', 'app_private.run_storage_sweeper()',
                    'public.sweeper_claim(integer)', 'public.sweeper_done(bigint[])']) f;
select ok(has_function_privilege('service_role', f, 'execute'), 'service_role runs ' || f)
  from unnest(array['public.sweeper_claim(integer)', 'public.sweeper_done(bigint[])']) f;
select is((select array_agg(column_name::text order by column_name) from information_schema.columns
            where table_schema = 'app_private' and table_name = 'group_cleanup_log'),
          array['avatar_queued', 'cleaned_at', 'conversation_id', 'files_queued', 'id', 'messages_removed'],
          'log holds counts only, no content column');

-- the run: G1, DBG and NOMEMOLD are due
select is(app_private.cleanup_empty_groups(50), 3, 'three groups cleaned');

select is(nmsg('G1'), 0, 'G1 messages gone');
select is((select count(*)::int from public.polls where conversation_id = g('G1')), 0, 'G1 polls gone');
select is((select count(*)::int from public.poll_options where conversation_id = g('G1')), 0, 'G1 poll options gone');
select is((select count(*)::int from public.poll_votes where conversation_id = g('G1')), 0, 'G1 poll votes gone');
select is((select count(*)::int from public.message_reactions where conversation_id = g('G1')), 0, 'G1 reactions gone');
select is((select count(*)::int from public.conversations where id = g('G1')), 1, 'G1 conversation row stays');
select is((select avatar_path from public.conversations where id = g('G1')), null, 'G1 avatar_path cleared');
select is((select count(*)::int from public.conversation_members where conversation_id = g('G1')), 2, 'G1 former members kept');
select is(q('G1'), (select array_agg(x order by x) from unnest(array[
    'attachments:' || g('G1')::text || '/a.jpg',
    'attachments:' || g('G1')::text || '/a.jpg.s',
    'attachments:' || g('G1')::text || '/a.jpg.t',
    'avatars:' || g('G1')::text || '/avatar.jpg',
    'link-previews:' || g('G1')::text || '/' || m('card')::text || '.jpg',
    'link-previews:' || g('G1')::text || '/' || m('edit')::text || '.jpg'
  ]) x), 'G1 queue: attachment, .s, .t, avatar, card picture, edited message picture (nothing for plain/poll)');
select is(nlog('G1'), 1, 'G1 one log row');
select is((select row(messages_removed, files_queued, avatar_queued)::text from app_private.group_cleanup_log
            where conversation_id = g('G1')), row(5, 5, true)::text, 'G1 log counts: 5 messages, 5 files, avatar');

select is(nmsg('DBG'), 0, 'Debug group (only the bot current) is cleaned by the rule');
select is(nlog('DBG'), 1, 'Debug group logged');
select is(nmsg('NOMEMOLD'), 0, 'no members, created 91 days ago: cleaned');
select is((select row(messages_removed, files_queued, avatar_queued)::text from app_private.group_cleanup_log
            where conversation_id = g('NOMEMOLD')), row(1, 0, false)::text, 'NOMEMOLD log counts');

select is(nmsg(n), 1, n || ' messages untouched')
  from unnest(array['N89', 'NMAX', 'NCUR', 'N11', 'NBOT', 'NSYS', 'NOMEMNEW']) n;
select is(nlog(n), 0, n || ' not logged')
  from unnest(array['N89', 'NMAX', 'NCUR', 'N11', 'NBOT', 'NSYS', 'NOMEMNEW', 'NEMPTY']) n;
select is((select avatar_path from public.conversations where id = g('N89')), g('N89')::text || '/avatar.jpg', 'N89 avatar kept');
select is(q('N89'), '{}'::text[], 'N89 nothing queued');

-- idempotent
select is(app_private.cleanup_empty_groups(50), 0, 'second run cleans nothing');
select is((select count(*)::int from app_private.group_cleanup_log
            where conversation_id in (select id from ids)), 3, 'second run adds no log row');

-- batch limit: two more groups become due
update public.conversation_members set left_at = now() - interval '91 days' where conversation_id in (g('N89'), g('NMAX'));
select is(app_private.cleanup_empty_groups(1), 1, 'batch 1: one group');
select is((select count(*)::int from app_private.group_cleanup_log where conversation_id in (g('N89'), g('NMAX'))), 1, 'batch 1: one logged');
select is(app_private.cleanup_empty_groups(1), 1, 'batch 1 again: the other');
select is(app_private.cleanup_empty_groups(1), 0, 'then none');

-- ===== sweeper_claim / sweeper_done =====
delete from app_private.storage_removal_queue;
-- live content: NCUR keeps an attachment message and a card; NCUR has an avatar; profile 03 has an avatar
insert into mids values ('live', (select msg('NCUR', '03', 'gc live')));
update public.messages set attachment_path = 'live/x.jpg' where id = m('live');
insert into mids values ('livecard', gen_random_uuid());
insert into storage.objects(bucket_id, name, owner_id, metadata) values
  ('link-previews', g('NCUR')::text || '/' || m('livecard')::text || '.jpg', u('03'), '{"size":3}'::jsonb);
insert into public.messages(id, conversation_id, sender_id, body, link_preview) values
  (m('livecard'), g('NCUR'), u('03'), 'gc live mail.test/y',
   jsonb_build_object('url', 'https://mail.test/y', 'title', 'T', 'image', g('NCUR')::text || '/' || m('livecard')::text || '.jpg'));
insert into mids values ('nocard', (select msg('NCUR', '03', 'gc nocard')));
update public.conversations set avatar_path = 'conv/live.jpg' where id = g('NCUR');
update public.profiles set avatar_path = 'prof/live.jpg' where user_id = u('03');

create temp table qid(name text primary key, id bigint);
create function qi(name text) returns bigint language sql stable as $$ select id from qid where qid.name = qi.name $$;
create function qadd(nm text, b text, p text, att int default 0) returns void language sql as $$
  with r as (insert into app_private.storage_removal_queue(bucket, path, attempts) values (b, p, att) returning id)
  insert into qid select nm, id from r
$$;
select qadd('liveatt', 'attachments', 'live/x.jpg');
select qadd('livethumb', 'attachments', 'live/x.jpg.t');
select qadd('livecard', 'link-previews', g('NCUR')::text || '/' || m('livecard')::text || '.jpg');
select qadd('liveconvav', 'avatars', 'conv/live.jpg');
select qadd('liveprofav', 'avatars', 'prof/live.jpg');
select qadd('freeatt', 'attachments', 'free/x.jpg', 2);
select qadd('freecard', 'link-previews', g('NCUR')::text || '/' || m('nocard')::text || '.jpg');
select qadd('freeav', 'avatars', 'free/av.jpg');
select qadd('otherbucket', 'avatars', 'live/x.jpg', 5);  -- an attachment path, but in avatars: not in use there

-- refused for app users
create function as_auth() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u('01'), 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on function as_auth(), u(text) to authenticated;
select as_auth();
select throws_ok('select * from public.sweeper_claim(10)', '42501', null, 'authenticated cannot claim');
select throws_ok('select public.sweeper_done(array[1::bigint])', '42501', null, 'authenticated cannot mark done');
reset role;
set local role anon;
select throws_ok('select * from public.sweeper_claim(10)', '42501', null, 'anon cannot claim');
reset role;

-- claimed rows land in cl (run number, row) so postgres can check them
create temp table cl(run int, id bigint, bucket text, path text);
grant insert on cl to service_role;
set local role service_role;
insert into cl select 1, * from public.sweeper_claim(20);
reset role;
select is((select array_agg(id order by id) from cl where run = 1),
          array[qi('freeatt'), qi('freecard'), qi('freeav'), qi('otherbucket')],
          'claim returns every free row (the avatars row holding an attachment path included), no in-use row');
select is((select count(*)::int from app_private.storage_removal_queue
            where id in (qi('liveatt'), qi('livethumb'), qi('livecard'), qi('liveconvav'), qi('liveprofav'))), 0,
          'claim deleted every in-use row (attachment, its .t, live card, conversation and profile avatar)');
select is((select bucket || ':' || path from cl where run = 1 and id = qi('freecard')),
          'link-previews:' || g('NCUR')::text || '/' || m('nocard')::text || '.jpg', 'claim returns bucket and path');
select is((select array_agg(attempts order by id) from app_private.storage_removal_queue
            where id in (qi('freeatt'), qi('freecard'), qi('freeav'), qi('otherbucket'))), array[3, 1, 1, 6],
          'each claim adds one attempt');
set local role service_role;
insert into cl select 2, * from public.sweeper_claim(1);
insert into cl select 3, * from public.sweeper_claim(2);
reset role;
select is((select array_agg(id) from cl where run = 2), array[qi('freecard')], 'claim 1: fewest attempts, then lowest id');
select is((select array_agg(id order by id) from cl where run = 3), array[qi('freecard'), qi('freeav')],
          'claim 2: attempts 1 and 2 beat the older row with attempts 3');
select lives_ok(format('set local role service_role; select public.sweeper_done(array[%s, %s]::bigint[])', qi('freeatt'), qi('freeav')),
                'service_role marks done');
reset role;
select is((select array_agg(id order by id) from app_private.storage_removal_queue), array[qi('freecard'), qi('otherbucket')],
          'done removes exactly those ids');

-- claim cap 200
insert into app_private.storage_removal_queue(bucket, path) select 'attachments', 'cap/' || i from generate_series(1, 250) i;
set local role service_role;
select is((select count(*)::int from public.sweeper_claim(500)), 200, 'claim returns at most 200');
reset role;

-- claim only knows attachments, link-previews, avatars; other buckets stay untouched
delete from app_private.storage_removal_queue;
select qadd('unk1', 'photos', 'free/u1.jpg', 0);
select qadd('unk2', 'Attachments', 'free/u2.jpg', 0);  -- bucket names are exact
select qadd('known', 'attachments', 'free/k.jpg', 3);
set local role service_role;
insert into cl select 4, * from public.sweeper_claim(1);
insert into cl select 5, * from public.sweeper_claim(10);
reset role;
select is((select array_agg(id) from cl where run = 4), array[qi('known')],
          'claim 1 skips unknown-bucket rows even with fewer attempts');
select is((select array_agg(id) from cl where run = 5), array[qi('known')], 'claim never returns an unknown-bucket row');
select is((select array_agg(attempts order by id) from app_private.storage_removal_queue where id in (qi('unk1'), qi('unk2'))),
          array[0, 0], 'unknown-bucket rows stay queued with attempts unchanged');

-- in-use rows are dropped from the whole queue, not only the first n
select lives_ok(format('set local role service_role; select public.sweeper_done(array[%s]::bigint[])', qi('known')), 'done known');
reset role;
select qadd('w1', 'attachments', 'live/x.jpg');
select qadd('w2', 'attachments', 'live/x.jpg.t');
select qadd('w3', 'avatars', 'conv/live.jpg');
select qadd('wf1', 'attachments', 'free/w1.jpg', 1);
select qadd('wf2', 'link-previews', 'free/w2.jpg', 1);
set local role service_role;
insert into cl select 6, * from public.sweeper_claim(2);
reset role;
select is((select array_agg(id order by id) from cl where run = 6), array[qi('wf1'), qi('wf2')],
          'claim 2 returns the free rows behind 3 in-use rows');
select is((select count(*)::int from app_private.storage_removal_queue where id in (qi('w1'), qi('w2'), qi('w3'))), 0,
          'claim 2 dropped all 3 in-use rows');
select lives_ok(format('set local role service_role; select public.sweeper_done(array[%s, %s]::bigint[])', qi('wf1'), qi('wf2')), 'done wf');
reset role;
select qadd('w4', 'avatars', 'prof/live.jpg');
set local role service_role;
insert into cl select 7, * from public.sweeper_claim(5);
reset role;
select is((select count(*)::int from cl where run = 7), 0, 'only in-use and unknown rows left: claim returns 0 rows');
select is((select count(*)::int from app_private.storage_removal_queue where id = qi('w4')), 0, 'that claim still dropped the in-use row');
select is((select array_agg(id order by id) from app_private.storage_removal_queue), array[qi('unk1'), qi('unk2')],
          'afterwards only the unknown-bucket rows remain');

-- ===== run_storage_sweeper =====
create function nreq() returns int language sql as $$ select count(*)::int from net.http_request_queue $$;
delete from vault.secrets where name in ('sweeper_url', 'sweeper_secret');
create temp table n0 as select nreq() n;
select app_private.run_storage_sweeper();
select is(nreq(), (select n from n0), 'no Vault secrets: no http call');
select vault.create_secret('http://sweeper.qa.test/functions/v1/storage-sweeper', 'sweeper_url');
select app_private.run_storage_sweeper();
select is(nreq(), (select n from n0), 'only the url: no http call');
select vault.create_secret('qa-sweeper-value', 'sweeper_secret');
delete from app_private.storage_removal_queue;
select app_private.run_storage_sweeper();
select is(nreq(), (select n from n0), 'both secrets, empty queue: no http call');
insert into app_private.storage_removal_queue(bucket, path) values ('attachments', 'run/x.jpg');
select app_private.run_storage_sweeper();
select is(nreq(), (select n from n0) + 1, 'both secrets and a queued row: one http call');
select is((select headers->>'x-sweeper-secret' from net.http_request_queue
            where url = 'http://sweeper.qa.test/functions/v1/storage-sweeper'), 'qa-sweeper-value',
          'the call goes to the Vault url with header x-sweeper-secret');

-- ===== cron =====
select is((select array_agg(jobname || ' ' || schedule order by jobname) from cron.job
            where jobname in ('group-cleanup', 'storage-sweeper')),
          array['group-cleanup 17 3 * * *', 'storage-sweeper */10 * * * *'], 'both cron jobs, once each');

select * from finish();
rollback;
