begin;
select plan(56);

-- Reads made while "Show when I have read messages" is OFF stay hidden
-- forever (20260925090000_shared_read_at): conversation_members.shared_read_at
-- only moves while the reader shares, and read_marks() answers from it.
-- last_read_at still moves on every read, so unread counts are unchanged.
--
-- One group G: ada (the observer, always sharing), ben (the reader whose
-- switch is flipped), cal (a member with no shared read at all -- what the
-- backfill leaves a member who was not sharing at migration time).
--
-- Everything runs in one transaction, so now() is one instant T throughout,
-- and every mark_read below stamps T. To tell a later read from an earlier
-- one, a read is "aged" (both of its columns moved back by the same amount,
-- with RLS bypassed) -- the fixture equivalent of time passing after it.

-- fixtures -----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000fa001', 'ada@shared.test', now(), '{"full_name":"Ada"}'),
  ('00000000-0000-0000-0000-0000000fa002', 'ben@shared.test', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-0000000fa003', 'cal@shared.test', now(), '{"full_name":"Cal"}');
insert into app_private.allowlist(email) values
  ('ada@shared.test'), ('ben@shared.test'), ('cal@shared.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('5e000000-0000-0000-0000-0000000fa001', '00000000-0000-0000-0000-0000000fa001', now(), now()),
  ('5e000000-0000-0000-0000-0000000fa002', '00000000-0000-0000-0000-0000000fa002', now(), now()),
  ('5e000000-0000-0000-0000-0000000fa003', '00000000-0000-0000-0000-0000000fa003', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function as_ada() returns void language sql as $$
  select test_as('00000000-0000-0000-0000-0000000fa001', '5e000000-0000-0000-0000-0000000fa001')
$$;
create or replace function as_ben() returns void language sql as $$
  select test_as('00000000-0000-0000-0000-0000000fa002', '5e000000-0000-0000-0000-0000000fa002')
$$;
create or replace function as_cal() returns void language sql as $$
  select test_as('00000000-0000-0000-0000-0000000fa003', '5e000000-0000-0000-0000-0000000fa003')
$$;

-- One member's row out of read_marks(), as whoever the test is acting as.
create or replace function read_at_of(conv uuid, target uuid) returns timestamptz
language sql security invoker as $$
  select read_at from public.read_marks(conv) where user_id = target
$$;
create or replace function shares_with(conv uuid, target uuid) returns boolean
language sql security invoker as $$
  select shares from public.read_marks(conv) where user_id = target
$$;
create or replace function unread_in(conv uuid) returns integer
language sql security invoker as $$
  select unread from public.unread_counts() where conversation_id = conv
$$;
-- The caller switching her OWN sharing, the way the client does.
create or replace function share_mine(on_ boolean) returns void
language sql security invoker as $$
  update public.profiles set share_read_status = on_
   where user_id = (auth.jwt() ->> 'sub')::uuid
$$;
grant execute on function read_at_of(uuid, uuid), shares_with(uuid, uuid),
  unread_in(uuid), share_mine(boolean) to authenticated;

-- The private columns, read / aged with RLS bypassed (run as the owner).
create or replace function stored_last(conv uuid, target uuid) returns timestamptz
language sql as $$
  select last_read_at from public.conversation_members
   where conversation_id = conv and user_id = target
$$;
create or replace function stored_shared(conv uuid, target uuid) returns timestamptz
language sql as $$
  select shared_read_at from public.conversation_members
   where conversation_id = conv and user_id = target
$$;
create or replace function age_reads(conv uuid, target uuid, by_ interval) returns void
language sql as $$
  update public.conversation_members
     set last_read_at = last_read_at - by_, shared_read_at = shared_read_at - by_
   where conversation_id = conv and user_id = target
$$;

-- Broadcasts on G's reads: topic so far (RLS bypassed).
create or replace function reads_sent() returns bigint language plpgsql as $$
begin
  return (select count(*) from realtime.messages where topic = 'reads:' || (select id from _g)::text);
end $$;

select as_ada(); select public.activate_session(); reset role;
select as_ben(); select public.activate_session(); reset role;
select as_cal(); select public.activate_session(); reset role;

select as_ada();
create temp table _g as
  select public.start_group_conversation('shared', array[
    '00000000-0000-0000-0000-0000000fa002', '00000000-0000-0000-0000-0000000fa003'
  ]::uuid[]) as id;
reset role;
grant select on _g to authenticated;

-- 1 the column and its privileges --------------------------------------------
select has_column('public', 'conversation_members', 'shared_read_at', 'shared_read_at exists');
select col_type_is('public', 'conversation_members', 'shared_read_at', 'timestamp with time zone',
                   'shared_read_at is a timestamptz');
select col_is_null('public', 'conversation_members', 'shared_read_at',
                   'shared_read_at is nullable: a member may have no shared read at all');
select col_default_is('public', 'conversation_members', 'shared_read_at', 'now()',
                      'shared_read_at defaults to now() for a new membership');
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'shared_read_at', 'SELECT'),
          'authenticated cannot select shared_read_at');
select ok(not has_column_privilege('anon', 'public.conversation_members', 'shared_read_at', 'SELECT'),
          'anon cannot select shared_read_at');
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'shared_read_at', 'UPDATE'),
          'authenticated cannot update shared_read_at');
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'shared_read_at', 'INSERT'),
          'authenticated cannot insert shared_read_at');
select ok(not has_column_privilege('anon', 'public.conversation_members', 'shared_read_at', 'UPDATE'),
          'anon cannot update shared_read_at');
-- No new grants at all: clients still hold exactly the three public columns.
select is(
  (select string_agg(grantee || ':' || privilege_type || ':' || column_name, ', '
                     order by grantee, privilege_type, column_name)
     from information_schema.column_privileges
    where table_schema = 'public' and table_name = 'conversation_members'
      and grantee in ('authenticated', 'anon'))::text,
  'authenticated:SELECT:conversation_id, authenticated:SELECT:joined_at, authenticated:SELECT:user_id',
  'clients hold exactly SELECT on conversation_id, joined_at, user_id -- nothing new');
select is((select count(*) from information_schema.table_privileges
            where table_schema = 'public' and table_name = 'conversation_members'
              and grantee in ('authenticated', 'anon')),
          0::bigint, 'and no table-wide privilege on conversation_members');
select as_ada();
select throws_ok($$select shared_read_at from public.conversation_members$$,
                 '42501', null, 'a member cannot read shared_read_at directly');
select throws_ok($$update public.conversation_members set shared_read_at = now() + interval '1 day'
                    where user_id = '00000000-0000-0000-0000-0000000fa001'$$,
                 '42501', null, 'a member cannot write her own shared_read_at directly');
reset role;

-- 2 a new membership starts at its join time ---------------------------------
select is((select count(*) from public.conversation_members where conversation_id = (select id from _g)),
          3::bigint, 'G has its three members');
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _g)
              and shared_read_at is not distinct from joined_at),
          3::bigint, 'every new membership''s shared_read_at is its joined_at');
select is(stored_shared((select id from _g), '00000000-0000-0000-0000-0000000fa002'), now(),
          'which is now(), the moment G was created');

-- 3 read while OFF, then back ON: the earlier shared read, never the off one --
-- ben's last shared read is two hours old; ada has two unread-for-ben
-- messages from an hour ago.
select age_reads((select id from _g), '00000000-0000-0000-0000-0000000fa002', interval '2 hours');
insert into public.messages(conversation_id, sender_id, body, created_at) values
  ((select id from _g), '00000000-0000-0000-0000-0000000fa001', 'one', now() - interval '1 hour'),
  ((select id from _g), '00000000-0000-0000-0000-0000000fa001', 'two', now() - interval '1 hour');
select as_ada();
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'),
          now() - interval '2 hours', 'control: ada sees ben''s two-hour-old shared read');
reset role;
select as_ben();
select is(unread_in((select id from _g)), 2, 'control: ben has two unread');
select share_mine(false);
select lives_ok($$select public.mark_read((select id from _g))$$, 'ben, sharing OFF, reads G');
-- unread_counts() omits a conversation with nothing unread.
select is(coalesce(unread_in((select id from _g)), 0), 0,
          'a read made while off still clears ben''s unread count');
reset role;
select is(reads_sent(), 0::bigint, 'a read made while off is not broadcast');
select is(stored_last((select id from _g), '00000000-0000-0000-0000-0000000fa002'), now(),
          'last_read_at moved to the off-period read');
select is(stored_shared((select id from _g), '00000000-0000-0000-0000-0000000fa002'),
          now() - interval '2 hours', 'shared_read_at did not move');
select as_ada();
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'), null,
          'while ben is off, ada sees no read time for him');
reset role;
select as_ben(); select share_mine(true); reset role;
select as_ada();
select is(shares_with((select id from _g), '00000000-0000-0000-0000-0000000fa002'), true,
          'ben is back on: ada sees him sharing');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'),
          now() - interval '2 hours',
          'and sees his last SHARED read, not the one he made while off');
select isnt(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'), now(),
            'the off-period read never surfaces');
reset role;

-- 3b a member with no shared read at all: null, even once sharing --------------
update public.conversation_members set shared_read_at = null, last_read_at = now() - interval '3 hours'
 where conversation_id = (select id from _g) and user_id = '00000000-0000-0000-0000-0000000fa003';
select as_cal();
select share_mine(false);
select lives_ok($$select public.mark_read((select id from _g))$$, 'cal, sharing OFF, reads G');
select share_mine(true);
reset role;
select is(stored_shared((select id from _g), '00000000-0000-0000-0000-0000000fa003'), null,
          'cal''s off-period read left shared_read_at null');
select as_ada();
select is(shares_with((select id from _g), '00000000-0000-0000-0000-0000000fa003'), true,
          'cal is sharing now: the gate is open');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa003'), null,
          'yet ada sees no read time: cal has never read while sharing');
reset role;

-- 4 turn on, then read: visible at once, and broadcast ------------------------
select as_ben();
select lives_ok($$select public.mark_read((select id from _g))$$, 'ben, sharing ON, reads G');
reset role;
select is(reads_sent(), 1::bigint, 'a read made while sharing is broadcast once');
select is(stored_shared((select id from _g), '00000000-0000-0000-0000-0000000fa002'), now(),
          'shared_read_at moved to it');
select as_ada();
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'), now(),
          'ada sees it at once');
reset role;

-- The broadcast payload: exactly {id, user_id, read_at}, nothing more.
select is((select array_agg(k order by k) from jsonb_object_keys(
             (select payload from realtime.messages
               where topic = 'reads:' || (select id from _g)::text)) k),
          array['id', 'read_at', 'user_id'], 'the read broadcast carries exactly id, read_at, user_id');
select is((select payload ->> 'user_id' from realtime.messages
            where topic = 'reads:' || (select id from _g)::text),
          '00000000-0000-0000-0000-0000000fa002', 'user_id is the reader');
select is((select (payload ->> 'read_at')::timestamptz from realtime.messages
            where topic = 'reads:' || (select id from _g)::text),
          now(), 'read_at is the shared read time');

-- 5 read while sharing, turn off, turn on: the SAME shared read again ---------
-- The read just made is aged an hour, so any later read is distinguishable.
select age_reads((select id from _g), '00000000-0000-0000-0000-0000000fa002', interval '1 hour');
select as_ada();
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'),
          now() - interval '1 hour', 'control: ada sees ben''s hour-old shared read');
reset role;
select as_ben(); select share_mine(false); reset role;
select as_ada();
select is(shares_with((select id from _g), '00000000-0000-0000-0000-0000000fa002'), false,
          'ben turns off: ada sees him not sharing');
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'), null,
          'and his shared read is hidden');
reset role;
select as_ben();
select lives_ok($$select public.mark_read((select id from _g))$$, 'ben, OFF again, reads G again');
select share_mine(true);
reset role;
select is(reads_sent(), 1::bigint, 'the off-period read sent nothing');
select as_ada();
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'),
          now() - interval '1 hour',
          'ben back on: ada sees the same shared read again, not the off-period one');
reset role;

-- 6 the reverse direction is gated the same way ------------------------------
-- ada reads while off; ben must never see it either.
select age_reads((select id from _g), '00000000-0000-0000-0000-0000000fa001', interval '30 minutes');
select as_ada();
select share_mine(false);
select lives_ok($$select public.mark_read((select id from _g))$$, 'ada, OFF, reads G');
select share_mine(true);
reset role;
select as_ben();
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa001'),
          now() - interval '30 minutes', 'ben sees ada''s last shared read, not her off-period one');
reset role;
select is(stored_last((select id from _g), '00000000-0000-0000-0000-0000000fa001'), now(),
          'ada''s own place still moved');

-- 7 mark_read's refusals are unchanged and move nothing ------------------------
-- A non-member (dee, active and allowlisted) is refused and writes nothing.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000fa004', 'dee@shared.test', now(), '{"full_name":"Dee"}');
insert into app_private.allowlist(email) values ('dee@shared.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('5e000000-0000-0000-0000-0000000fa004', '00000000-0000-0000-0000-0000000fa004', now(), now());
select test_as('00000000-0000-0000-0000-0000000fa004', '5e000000-0000-0000-0000-0000000fa004');
select is(public.activate_session(), true, 'dee is active');
select throws_ok($$select public.mark_read((select id from _g))$$, '42501', null,
                 'dee, not a member of G, is refused with 42501');
reset role;
select is(reads_sent(), 1::bigint, 'and nothing is broadcast');
select is((select count(*) from public.conversation_members
            where conversation_id = (select id from _g)
              and user_id = '00000000-0000-0000-0000-0000000fa004'), 0::bigint,
          'and no membership (and so no shared_read_at) appears for her');

-- 8 a sharer's read, when the OBSERVER is off, is still recorded as shared -----
-- The condition is the reader's sharing only: ada off does not stop ben's
-- read from counting as shared once ada turns back on.
select as_ada(); select share_mine(false); reset role;
select as_ben();
select lives_ok($$select public.mark_read((select id from _g))$$, 'ben (on) reads while ada is off');
reset role;
select is(reads_sent(), 2::bigint, 'ben''s read is broadcast: he shares');
select is(stored_shared((select id from _g), '00000000-0000-0000-0000-0000000fa002'), now(),
          'and recorded as shared');
select as_ada();
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'), null,
          'ada, off, sees nothing (mutual gate unchanged)');
select share_mine(true);
select is(read_at_of((select id from _g), '00000000-0000-0000-0000-0000000fa002'), now(),
          'ada back on sees ben''s read, which he made while sharing');
reset role;

select * from finish();
rollback;
