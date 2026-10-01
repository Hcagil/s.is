begin;
select plan(34);

-- Group sender colours (20261002120000_group_color_slots), from the contract:
--
--  * conversation_members.color_slot smallint not null default 0, 0..9;
--  * a BEFORE INSERT trigger assigns it and ignores any supplied value:
--    0, 1, 2, ... while a slot is free; after ten, the least-used slot, the
--    lowest number on a tie; a departed member keeps holding its slot; a
--    re-added user gets their earlier slot back; a per-conversation
--    advisory lock serialises joins;
--  * clients may SELECT color_slot (only where they share the conversation)
--    and never INSERT or UPDATE it; the trigger function is not callable by
--    public, anon or authenticated.
--
-- Membership rows are inserted directly as the owner: the trigger fires on
-- every insert, whatever path made it, and the slot arithmetic needs more
-- members than the reach rules would let one fixture add.

-- fixtures -----------------------------------------------------------------
-- people 1..15 (ids c50000NN-...); 16 zed: allowlisted, active, in nothing
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select ('c50000' || lpad(n::text, 2, '0') || '-0000-0000-0000-000000000000')::uuid,
       'p' || n || '@slots.test', now(), json_build_object('full_name', 'P' || n)::jsonb
  from generate_series(1, 16) n;
insert into app_private.allowlist(email)
select 'p' || n || '@slots.test' from generate_series(1, 16) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('5e000000-0000-0000-0000-0000000c50' || lpad(n::text, 2, '0'))::uuid,
       ('c50000' || lpad(n::text, 2, '0') || '-0000-0000-0000-000000000000')::uuid, now(), now()
  from generate_series(1, 16) n;

create function cs_u(n int) returns uuid language sql immutable as $$
  select ('c50000' || lpad(n::text, 2, '0') || '-0000-0000-0000-000000000000')::uuid
$$;
create function cs_as(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', cs_u(n), 'role', 'authenticated',
      'email', 'p' || n || '@slots.test',
      'session_id', '5e000000-0000-0000-0000-0000000c50' || lpad(n::text, 2, '0'))::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on function cs_u(int), cs_as(int) to authenticated;

create temp table _c (name text primary key, id uuid not null);
grant select on _c to authenticated;
create function cs_group(name_ text) returns uuid language sql as $$
  with x as (insert into public.conversations (title) values (name_) returning id)
  insert into _c select name_, id from x returning id
$$;
create function cs_c(name_ text) returns uuid language sql stable as $$
  select id from _c where name = name_
$$;
grant execute on function cs_c(text) to authenticated;
-- n joins [conv]; [asked] is a slot the inserter tries to impose.
create function cs_join(conv text, n int, asked int default null) returns int
language plpgsql as $$
declare s int;
begin
  if asked is null then
    insert into public.conversation_members (conversation_id, user_id)
    values (cs_c(conv), cs_u(n)) returning color_slot into s;
  else
    insert into public.conversation_members (conversation_id, user_id, color_slot)
    values (cs_c(conv), cs_u(n), asked) returning color_slot into s;
  end if;
  return s;
end $$;
create function cs_leave(conv text, n int) returns void language sql as $$
  update public.conversation_members set left_at = now(), left_reason = 'left'
   where conversation_id = cs_c(conv) and user_id = cs_u(n) and left_at is null
$$;
-- Forces n's slot (as the owner; the trigger guards INSERT only).
create function cs_force(conv text, n int, s int) returns void language sql as $$
  update public.conversation_members set color_slot = s
   where conversation_id = cs_c(conv) and user_id = cs_u(n)
$$;
create function cs_locks() returns bigint language sql as $$
  select count(*) from pg_locks
   where locktype = 'advisory' and pid = pg_backend_pid() and granted
$$;

-- 1 the column ----------------------------------------------------------------
select col_type_is('public', 'conversation_members', 'color_slot', 'smallint', 'color_slot is smallint');
select col_not_null('public', 'conversation_members', 'color_slot', 'color_slot is not null');
select col_default_is('public', 'conversation_members', 'color_slot', '0', 'color_slot defaults to 0');

select cs_group('range');
select cs_join('range', 1);
select throws_ok($$select cs_force('range', 1, 10)$$, '23514', null, 'slot 10 is out of range');
select throws_ok($$select cs_force('range', 1, -1)$$, '23514', null, 'slot -1 is out of range');
select lives_ok($$select cs_force('range', 1, 9)$$, 'control: slot 9 is in range');

-- 2 assignment ---------------------------------------------------------------
select cs_group('ten');
select is(array(select cs_join('ten', n) from generate_series(1, 10) n),
          array[0,1,2,3,4,5,6,7,8,9], 'the first ten get 0..9 in join order');
select is(cs_join('ten', 11), 0, 'eleventh: every slot used once, lowest wins: 0');
select is(cs_join('ten', 12), 1, 'twelfth: 0 is used twice now, so 1');

select cs_group('imposed');
select is(cs_join('imposed', 1, 7), 0, 'a supplied slot is ignored: the first member gets 0');
select is(cs_join('imposed', 2, 0), 1, 'a supplied slot is ignored: the second gets 1, not 0');

-- Least used, lowest on a tie: usage made uneven by hand so that neither
-- "count mod 10" nor "lowest" answers it.
select cs_group('uneven');
select cs_join('uneven', n) from generate_series(1, 15) n;
select cs_force('uneven', n, s)
  from (values (1,0),(2,0),(3,1),(4,1),(5,2),(6,3),(7,3),(8,4),(9,4),
               (10,5),(11,5),(12,6),(13,7),(14,8),(15,9)) v(n, s);
-- 15 members: 2,6,7,8,9 used once; 2 is the lowest of those.
select is(cs_join('uneven', 16), 2, 'no free slot: the least used, lowest on a tie (2)');

select cs_group('free');
select cs_join('free', n) from generate_series(1, 10) n;
select cs_force('free', 4, 0);
-- slot 3 is free again (4 moved to 0): it wins over least-used/round robin.
select is(cs_join('free', 11), 3, 'a free slot is taken before any used one');

-- 3 departed and re-added ------------------------------------------------------
select cs_group('departed');
select cs_join('departed', n) from generate_series(1, 4) n;   -- 0,1,2,3
select cs_leave('departed', 2);                                -- held: 1
select is(cs_join('departed', 5), 4, 'a departed member keeps its slot: the next joiner gets 4, not 1');

select cs_group('readd');
select cs_join('readd', n) from generate_series(1, 3) n;       -- 0,1,2
select cs_leave('readd', 3);
select cs_force('readd', 2, 5);                                -- 1 is free now
select is(cs_join('readd', 3), 2, 'a re-added user gets the earlier slot (2), not the free 1');
select is((select count(distinct color_slot)::int from public.conversation_members
            where conversation_id = cs_c('readd') and user_id = cs_u(3)),
          1, 'both of their rows hold one slot');

-- 4 the per-conversation lock -----------------------------------------------------
-- Inside one transaction an xact advisory lock is held until the end, so the
-- locks this backend holds show what the trigger took: one per conversation.
select cs_group('lock1');
select cs_group('lock2');
create temp table _l as select cs_locks() as n;
select cs_join('lock1', 1);
select is(cs_locks(), (select n from _l) + 1, 'a join takes one advisory lock, held to commit');
select cs_join('lock1', 2);
select is(cs_locks(), (select n from _l) + 1, 'a second join into the same conversation takes the same lock');
select cs_join('lock2', 1);
select is(cs_locks(), (select n from _l) + 2, 'a join into another conversation takes a different lock');

-- 5 grants ----------------------------------------------------------------------
select ok(has_column_privilege('authenticated', 'public.conversation_members', 'color_slot', 'SELECT'),
          'authenticated may read color_slot');
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'color_slot', 'INSERT'),
          'authenticated may not insert color_slot');
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'color_slot', 'UPDATE'),
          'authenticated may not update color_slot');
select ok(not has_column_privilege('anon', 'public.conversation_members', 'color_slot', 'SELECT'),
          'anon may not read color_slot');
select is((select count(*)::int from pg_proc where proname = 'assign_color_slot'), 1,
          'one assign_color_slot function');
select ok(not has_function_privilege('anon', (select oid from pg_proc where proname = 'assign_color_slot'), 'EXECUTE'),
          'anon cannot execute assign_color_slot');
select ok(not has_function_privilege('authenticated', (select oid from pg_proc where proname = 'assign_color_slot'), 'EXECUTE'),
          'authenticated cannot execute assign_color_slot');
select ok(not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                       where p.proname = 'assign_color_slot' and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
          'public cannot execute assign_color_slot');

-- 6 who sees which slots --------------------------------------------------------
-- 'seen': p1 and p2. 'apart': p2 and p3. p16 zed is allowlisted, active and in
-- nothing, so only membership can refuse him.
select cs_group('seen'); select cs_join('seen', 1); select cs_join('seen', 2);
select cs_group('apart'); select cs_join('apart', 2); select cs_join('apart', 3);
select cs_as(1); select public.activate_session(); reset role;
select cs_as(2); select public.activate_session(); reset role;
select cs_as(16); select public.activate_session(); reset role;

select cs_as(1);
select is(array(select color_slot::int from public.conversation_members
                 where conversation_id = cs_c('seen') order by color_slot),
          array[0,1], 'a member reads every slot of a conversation they share');
select is((select count(*)::int from public.conversation_members
            where conversation_id = cs_c('apart')),
          0, 'a member reads no slot of a conversation they are not in');
select throws_ok($$update public.conversation_members set color_slot = 5
                    where conversation_id = cs_c('seen') and user_id = cs_u(1)$$,
                 '42501', null, 'a member cannot update their own slot');
select throws_ok($$insert into public.conversation_members (conversation_id, user_id, color_slot)
                    values (cs_c('seen'), cs_u(16), 3)$$,
                 '42501', null, 'a member cannot insert a slot');
reset role;
select cs_as(2);
select is((select count(*)::int from public.conversation_members
            where conversation_id = cs_c('apart')),
          2, 'control: a member of apart reads its slots');
reset role;
select cs_as(16);
select is((select count(*)::int from public.conversation_members
            where conversation_id in (cs_c('seen'), cs_c('apart'))),
          0, 'an active member in neither reads no slot');
reset role;
select is((select color_slot::int from public.conversation_members
            where conversation_id = cs_c('seen') and user_id = cs_u(1)),
          0, 'the refused update changed nothing');

select * from finish();
rollback;
