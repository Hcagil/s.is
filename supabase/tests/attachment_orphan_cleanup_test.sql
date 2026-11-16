begin;
select plan(29);
create function u(n text) returns uuid language sql immutable as $$ select ('00000000-0000-0000-0000-0000000ec1' || n)::uuid $$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values (u('01'), 'oc01@sis.test', now(), '{"full_name":"OC 01"}'::jsonb);
insert into public.conversations(id, title) values ('00000000-0000-0000-0000-0000000ec1ff', 'oc-g');
insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from) values ('00000000-0000-0000-0000-0000000ec1ff', u('01'), 'member', now() - interval '200 days', '-infinity');
create function obj(n text, age interval, b text default 'attachments') returns void language sql as $$ insert into storage.objects(bucket_id, name, owner_id, metadata, created_at) values (b, n, u('01'), '{"size":3}'::jsonb, now() - age) $$;
create function msgp(p text) returns void language sql as $$ insert into public.messages(conversation_id, sender_id, body, attachment_path) values ('00000000-0000-0000-0000-0000000ec1ff', u('01'), '', p) $$;
create function qp(prefix text) returns text[] language sql stable as $$ select coalesce(array_agg(path order by path), '{}') from app_private.storage_removal_queue where bucket = 'attachments' and path like prefix || '%' $$;
delete from app_private.storage_removal_queue;
create temp table res(n int);

-- Fixtures
-- A
select obj('oc/a/p.jpg', '40 days');
select obj('oc/a/p.jpg.t', '40 days');
select obj('oc/a/p.jpg.s', '40 days');
-- B
select obj('oc/b/p.jpg', '40 days');
select obj('oc/b/p.jpg.t', '40 days');
select obj('oc/b/p.jpg.s', '40 days');
select msgp('oc/b/p.jpg');
-- C
select obj('oc/c/p.jpg.s', '40 days');
select msgp('oc/c/p.jpg');
-- D
select obj('oc/d/p.jpg.t', '40 days');
-- E
select obj('oc/e/p.jpg.t', '40 days');
select msgp('oc/e/p.jpg.t');
-- F
select obj('oc/f/fresh.jpg', '1 day');
select obj('oc/f/in.jpg', '29 days 23 hours');
select obj('oc/f/out.jpg', '30 days 1 hour');
-- G
select obj('oc/g/x.jpg', '40 days', 'avatars');
select obj('oc/g/y.jpg', '40 days', 'link-previews');
-- H
select obj('oc/h/p.jpg', '40 days');
insert into app_private.storage_removal_queue(bucket,path) values ('attachments','oc/h/p.jpg');

-- Run the function once
insert into res select app_private.queue_orphan_attachments(1000);

-- Assertions
select is(qp('oc/a/'), array['oc/a/p.jpg','oc/a/p.jpg.s','oc/a/p.jpg.t'], 'orphan with its .t and .s queued');
select is(qp('oc/b/'), '{}'::text[], 'referenced file and its copies kept');
select is(qp('oc/c/'), '{}'::text[], 'old .s kept while the message still references the base');
select is(qp('oc/d/'), array['oc/d/p.jpg.t'], 'lone old .t queued');
select is(qp('oc/e/'), '{}'::text[], 'message path ending .t keeps that object');
select is(qp('oc/f/'), array['oc/f/out.jpg'], 'fresh and 29d23h kept, 30d1h queued');
select is((select count(*)::int from app_private.storage_removal_queue where path in ('oc/g/x.jpg','oc/g/y.jpg')), 0, 'other buckets untouched');
select is(qp('oc/h/'), array['oc/h/p.jpg'], 'already queued: one row, no duplicate');
select is((select n from res), 5, 'returns rows actually inserted (3 A + 1 D + 1 F; H already queued)');
select is(app_private.queue_orphan_attachments(1000), 0, 'second run inserts nothing');
select ok((select prosecdef from pg_proc where oid = 'app_private.queue_orphan_attachments(integer)'::regprocedure), 'security definer');
select ok((select 'search_path=""' = any(proconfig) from pg_proc where oid = 'app_private.queue_orphan_attachments(integer)'::regprocedure), 'search_path empty');
select is((select prorettype::regtype::text from pg_proc where oid = 'app_private.queue_orphan_attachments(integer)'::regprocedure), 'integer', 'returns int');
select is((select pronargdefaults::int from pg_proc where oid = 'app_private.queue_orphan_attachments(integer)'::regprocedure), 1, 'batch has a default');
select ok(not has_function_privilege(r, 'app_private.queue_orphan_attachments(integer)', 'execute'), r || ' cannot run it') from unnest(array['anon','authenticated']) r;
select is((select array_agg(jobname || ' ' || schedule) from cron.job where jobname = 'attachment-orphan-cleanup'), array['attachment-orphan-cleanup 41 3 * * *'], 'cron job once');

-- Late message claim
select msgp('oc/a/p.jpg');
create temp table cl(id bigint, bucket text, path text);
grant insert on cl to service_role;
set local role service_role;
insert into cl select * from public.sweeper_claim(50);
reset role;
select is((select count(*)::int from cl where path like 'oc/a/%'), 0, 'claim drops the file a message now uses and its copies');
select is(qp('oc/a/'), '{}'::text[], 'and removes them from the queue');
select is((select count(*)::int from cl where path = 'oc/d/p.jpg.t'), 1, 'claim still returns real orphans');

-- batch
delete from app_private.storage_removal_queue;
set local storage.allow_delete_query = 'true';
delete from storage.objects where name like 'oc/%';
select obj('oc/b1', '100 days');
select obj('oc/b2', '90 days');
select obj('oc/b3', '80 days');
select obj('oc/b4', '70 days');

-- 1
select is(app_private.queue_orphan_attachments(2), 2, 'batch 2 queues 2');
select is(qp('oc/b'), array['oc/b1','oc/b2'], 'oldest first');

delete from app_private.storage_removal_queue;

-- 2
select is(app_private.queue_orphan_attachments(0), 1, 'batch 0 clamps to 1');
select is(qp('oc/b'), array['oc/b1'], 'batch 0 queues the oldest');

delete from app_private.storage_removal_queue;

-- 3
select is(app_private.queue_orphan_attachments(-5), 1, 'batch -5 clamps to 1');
select is(qp('oc/b'), array['oc/b1'], 'batch -5 queues the oldest');

delete from app_private.storage_removal_queue;
delete from storage.objects where name like 'oc/%';

select obj('oc/m/' || i, '40 days' + i * interval '1 minute')
from generate_series(1,1005) i;

-- 4
select is(app_private.queue_orphan_attachments(5000), 1000, 'batch 5000 clamps to 1000');
select is((select count(*)::int from app_private.storage_removal_queue where path like 'oc/m/%'), 1000, '1000 rows queued');

delete from app_private.storage_removal_queue;
delete from storage.objects where name like 'oc/%';

select obj('oc/d/' || i, '40 days' + i * interval '1 minute')
from generate_series(1,600) i;

-- 5
select is(app_private.queue_orphan_attachments(), 500, 'default batch is 500');

select * from finish();
rollback;
