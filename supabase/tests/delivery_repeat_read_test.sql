-- A repeated mark_read with no new message, in a LATER transaction, leaves
-- delivered_at where it was and sends no delivered: broadcast (Update 1
-- slice 5a, F2).
--
-- Inside one transaction now() never moves, so a repeat there cannot tell a
-- delivery pinned to the newest message from one pinned to the clock. This
-- file therefore commits its fixtures and runs each mark_read in its own
-- transaction, then deletes everything it made. It cleans up first as well,
-- in case an earlier run stopped half-way.

create temp table f2_ids(k text primary key, id uuid);
insert into f2_ids values
  ('ada', '00000000-0000-0000-0000-0000000de201'),
  ('ben', '00000000-0000-0000-0000-0000000de202'),
  ('g',   'c0000000-0000-0000-0000-0000000de201');
create function pg_temp.f2(k text) returns uuid language sql stable as $$
  select id from f2_ids where f2_ids.k = f2.k
$$;
create function pg_temp.f2_clean() returns void language sql as $$
  delete from realtime.messages where topic = 'delivered:' || pg_temp.f2('g') or topic = 'reads:' || pg_temp.f2('g');
  delete from public.messages where conversation_id = pg_temp.f2('g');
  delete from public.conversation_members where conversation_id = pg_temp.f2('g');
  delete from public.conversations where id = pg_temp.f2('g');
  delete from app_private.allowlist where email like '%@f2.test';
  delete from auth.users where id in (pg_temp.f2('ada'), pg_temp.f2('ben'));
$$;
select pg_temp.f2_clean();

begin;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (pg_temp.f2('ada'), 'ada@f2.test', now(), '{"full_name":"Ada"}'),
  (pg_temp.f2('ben'), 'ben@f2.test', now(), '{"full_name":"Ben"}');
insert into app_private.allowlist(email) values ('ada@f2.test'), ('ben@f2.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('f2000000-0000-0000-0000-0000000de201', pg_temp.f2('ada'), now(), now());
insert into public.conversations(id, title) values (pg_temp.f2('g'), null);
insert into public.conversation_members(conversation_id, user_id) values
  (pg_temp.f2('g'), pg_temp.f2('ada')), (pg_temp.f2('g'), pg_temp.f2('ben'));
insert into public.messages(conversation_id, sender_id, body, created_at)
values (pg_temp.f2('g'), pg_temp.f2('ben'), 'f2 m1', now() - interval '1 hour');
update public.conversation_members set delivered_at = now() - interval '2 days',
                                       last_read_at = now() - interval '2 days'
 where conversation_id = pg_temp.f2('g');
commit;

create function pg_temp.f2_as() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-0000000de201', 'role', 'authenticated',
      'email', 'ada@f2.test', 'session_id', 'f2000000-0000-0000-0000-0000000de201')::text, true);
  execute 'set local role authenticated';
end $$;
create temp table f2_snap(k text primary key, lr timestamptz, dlv timestamptz, sent bigint);
create function pg_temp.f2_take(k text) returns void language sql as $$
  insert into f2_snap
  select k, cm.last_read_at, cm.delivered_at,
         (select count(*) from realtime.messages where topic = 'delivered:' || pg_temp.f2('g'))
    from public.conversation_members cm
   where cm.conversation_id = pg_temp.f2('g') and cm.user_id = pg_temp.f2('ada')
$$;

begin;
select pg_temp.f2_as();
select public.activate_session();
commit;

-- first read: delivery advances to the message, once
begin;
select pg_temp.f2_as();
select public.mark_read('c0000000-0000-0000-0000-0000000de201');
commit;
select pg_temp.f2_take('first');
select pg_sleep(0.01);

-- the same read again, later: nothing new to deliver
begin;
select pg_temp.f2_as();
select public.mark_read('c0000000-0000-0000-0000-0000000de201');
commit;
select pg_temp.f2_take('second');

select plan(5);
select is((select dlv from f2_snap where k = 'first'),
          (select created_at from public.messages where conversation_id = pg_temp.f2('g')),
          'the first mark_read advanced delivery to the message');
select is((select sent from f2_snap where k = 'first'), 1::bigint, 'and broadcast it once');
select is((select dlv from f2_snap where k = 'second'), (select dlv from f2_snap where k = 'first'),
          'a later repeat leaves delivery where it was (F2)');
select is((select sent from f2_snap where k = 'second'), 1::bigint,
          'a later repeat sends no delivered: broadcast (F2)');
-- Control: the repeat really ran later. mark_read still stamps last_read_at
-- with its own now() (unread_test.sql), so the row itself is rewritten; only
-- delivery and its broadcast must stand still.
select cmp_ok((select lr from f2_snap where k = 'second'), '>', (select lr from f2_snap where k = 'first'),
              'control: the repeat ran in a later transaction (its read time is later)');
select * from finish();

select pg_temp.f2_clean();
