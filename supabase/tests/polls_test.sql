begin;
select plan(100);

-- Polls: public.create_poll / vote_poll / close_poll and the polls,
-- poll_options and poll_votes tables (20261011120000_polls.sql).
--
-- Written from the contract, not from the migration:
--   create_poll(p_conversation, p_id, p_question, p_options text[],
--   p_multiple, p_anonymous) is atomic; the same id again by the same sender
--   is OK; another message's id is 23505; a non-member or the bot 42501;
--   invalid input (question 1..255, options 2..12, each 1..100) 22023.
--   vote_poll(p_message, p_options uuid[]) sets the caller's exact set; an
--   empty array retracts; single choice allows at most one; closed 55000; a
--   non-member, a past member or the bot 42501. close_poll(p_message): the
--   creator only, idempotent. Read: members (and past members inside their
--   history window); on an anonymous poll the raw poll_votes read shows only
--   your own rows. vote_count / voter_count follow the votes. A poll's body is
--   frozen; deleting the message cascades. poll_votes is never published to
--   Realtime; polls and poll_options are. conversation_previews has a last
--   column `poll`.
--
-- Each negative fixture fails ONE gate; a control passes the same call.
--   ann  creator, group admin          bob  member; positive control
--   cat  never a member of G           dan  member of G who left 1 h ago
--   bot  the SIS bot, a member of G

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000000fa1' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@poll.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan')) v(n, name);
insert into app_private.allowlist(email)
select name || '@poll.test' from unnest(array['ann','bob','cat','dan']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('fa100000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('01'), u('02')), (u('01'), u('03')), (u('01'), u('04'));

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'sis-destek-bot@example.com', now(), '{"full_name":"SIS Destek"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then 'b07b0000-0000-0000-0000-000000000001'
                         else 'fa100000-0000-0000-0000-0000000000' || n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function runbook() returns void language sql as $$
  select set_config('request.jwt.claims', '', true); select null::void
$$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function group_c(t text, ms uuid[]) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_group_conversation(t, ms); perform commit_check(); return r; end $$;
create function msg(c uuid, body text) returns uuid language sql as $$
  insert into public.messages(conversation_id, sender_id, body) values (c, auth.uid(), body) returning id
$$;
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
grant execute on function u(text), as_(text), commit_check(), group_c(text, uuid[]),
  msg(uuid, text), try(text) to authenticated, anon;

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

-- the truth, whatever RLS says (security definer, owned by postgres)
create function opt(m uuid, pos int) returns uuid language sql stable security definer as $$
  select id from public.poll_options where message_id = m and position = pos
$$;
create function votes_of(m uuid, pos int) returns int language sql stable security definer as $$
  select vote_count from public.poll_options where message_id = m and position = pos
$$;
create function voters_of(m uuid) returns int language sql stable security definer as $$
  select voter_count from public.polls where message_id = m
$$;
create function my_set(m uuid, who text) returns text language sql stable security definer as $$
  select coalesce(string_agg(o.position::text, ',' order by o.position), '')
    from public.poll_votes v join public.poll_options o on o.id = v.option_id
   where v.message_id = m and v.user_id = u(who)
$$;
create function option_rows(m uuid) returns bigint language sql stable security definer as $$
  select count(*) from public.poll_options where message_id = m
$$;
grant execute on function opt(uuid, int), votes_of(uuid, int), voters_of(uuid),
  my_set(uuid, text), option_rows(uuid) to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('01');
insert into ids values ('G', group_c('Polls', array[u('02'), u('04')]));
insert into ids values ('TXT', msg(g('G'), 'plain text'));
reset role;

-- the bot: a member of G (its Debug chat), so only the bot gate refuses it
select runbook();
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('G'));
insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing;
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
values (g('G'), u('bot'), 'member', now() - interval '3 days', now() - interval '3 days');
update app_private.bot_accounts set enabled = true where user_id = u('bot');
select as_('bot');
select public.activate_session();
reset role;

-- fixed poll ids
insert into ids values
  ('P1',  'fa1a0000-0000-0000-0000-000000000001'),  -- single, public
  ('PM',  'fa1a0000-0000-0000-0000-000000000002'),  -- multiple, public
  ('PA',  'fa1a0000-0000-0000-0000-000000000003'),  -- single, anonymous
  ('PIN', 'fa1a0000-0000-0000-0000-000000000004'),  -- inside dan's window
  ('POUT','fa1a0000-0000-0000-0000-000000000005'),  -- after dan left
  ('PX',  'fa1a0000-0000-0000-0000-000000000006');  -- spare id for refusals

-- 1 create_poll -----------------------------------------------------------------
create function mk(c uuid, id uuid, q text, o text[], m boolean, a boolean) returns text language sql as $$
  select try(format($q$select public.create_poll(%L, %L, %L, %L, %L, %L)$q$, c, id, q, o, m, a))
$$;
create function vote(m uuid, o uuid[]) returns text language sql as $$
  select try(format($q$select public.vote_poll(%L, %L)$q$, m, o))
$$;
create function close_(m uuid) returns text language sql as $$
  select try(format($q$select public.close_poll(%L)$q$, m))
$$;
grant execute on function mk(uuid, uuid, text, text[], boolean, boolean), vote(uuid, uuid[]), close_(uuid)
  to authenticated, anon;

-- one transaction = one now(): make the text message older so "newest" is a poll
update public.messages set created_at = now() - interval '1 minute' where id = g('TXT');
select as_('01');
select is(mk(g('G'), g('P1'), 'Lunch?', array['Pizza','Soup','Salad'], false, false), 'ok', 'ann creates P1');
select is(mk(g('G'), g('PM'), 'Pick any', array['A','B','C'], true, false), 'ok', 'ann creates PM (multiple)');
select is(mk(g('G'), g('PA'), 'Secret?', array['Yes','No'], false, true), 'ok', 'ann creates PA (anonymous)');
select is((select poll from public.conversation_previews where conversation_id = g('G')), true,
          'the chat list marks a poll as the newest message');
reset role;
select is(option_rows(g('P1')), 3::bigint, 'P1 has its 3 options');
select is((select string_agg(text, ',' order by position) from public.poll_options where message_id = g('P1')),
          'Pizza,Soup,Salad', 'in the order given');
select is(voters_of(g('P1')), 0, 'nobody voted yet');
select is((select poll from public.messages where id = g('P1')), true, 'P1 is a poll message');
select is((select body from public.messages where id = g('P1')), 'Lunch?', 'its body is the question');
select is((select sender_id from public.messages where id = g('P1')), u('01'), 'ann sent it');
select is((select multiple::text || anonymous::text from public.polls where message_id = g('PA')), 'falsetrue',
          'PA is single choice and anonymous');

select as_('01');
select is(mk(g('G'), g('P1'), 'Lunch?', array['Pizza','Soup','Salad'], false, false), 'ok',
          'a retry with the same id by the same sender is harmless');
select is(mk(g('G'), g('TXT'), 'Hijack?', array['a','b'], false, false), '23505',
          'the id of another message is 23505');
select is(mk(g('G'), g('PX'), '', array['a','b'], false, false), '22023', 'an empty question is 22023');
select is(mk(g('G'), g('PX'), repeat('q', 256), array['a','b'], false, false), '22023', 'a 256-char question is 22023');
select is(mk(g('G'), g('PX'), 'Q', array['only'], false, false), '22023', 'one option is 22023');
select is(mk(g('G'), g('PX'), 'Q', (select array_agg('o' || i) from generate_series(1, 13) i), false, false), '22023',
          '13 options is 22023');
select is(mk(g('G'), g('PX'), 'Q', array[repeat('o', 101), 'b'], false, false), '22023', 'a 101-char option is 22023');
select is(mk(g('G'), 'fa1a0000-0000-0000-0000-0000000000a1', repeat('q', 255),
             array_cat(array[repeat('o', 100)], (select array_agg('o' || i) from generate_series(1, 11) i)), false, false),
          'ok', 'the limits themselves pass: 255-char question, 12 options, a 100-char option');
reset role;
select is(option_rows(g('P1')), 3::bigint, 'the retry added no options');
select is((select count(*) from public.messages where id = g('P1')), 1::bigint, 'nor a message');
select is((select body from public.messages where id = g('TXT')), 'plain text', 'the other message is untouched');
select is((select count(*) from public.polls where message_id = g('TXT')), 0::bigint, 'and is no poll');
select is((select count(*) from public.messages where id = g('PX')), 0::bigint, 'refused input left no message');
select is(option_rows(g('PX')), 0::bigint, 'and no options');

select as_('03');
select is(mk(g('G'), g('PX'), 'Q', array['a','b'], false, false), '42501', 'a non-member cannot create a poll');
reset role;
select as_('bot');
select is(mk(g('G'), g('PX'), 'Q', array['a','b'], false, false), '42501', 'the bot cannot create a poll in its own chat');
reset role;
select is((select count(*) from public.messages where id = g('PX')), 0::bigint, 'the refusals left nothing');

-- 2 vote_poll -------------------------------------------------------------------
select as_('02');
select is(vote(g('P1'), array[opt(g('P1'), 0)]), 'ok', 'bob votes Pizza');
reset role;
select is(my_set(g('P1'), '02'), '0', 'bob''s set is Pizza');
select is(votes_of(g('P1'), 0), 1, 'Pizza has 1 vote');
select is(voters_of(g('P1')), 1, 'one voter');
select as_('02');
select is(vote(g('P1'), array[opt(g('P1'), 1)]), 'ok', 'bob changes to Soup');
reset role;
select is(my_set(g('P1'), '02'), '1', 'his set is exactly Soup');
select is(votes_of(g('P1'), 0) || '/' || votes_of(g('P1'), 1), '0/1', 'Pizza 0, Soup 1');
select is(voters_of(g('P1')), 1, 'still one voter');
select as_('02');
select isnt(vote(g('P1'), array[opt(g('P1'), 0), opt(g('P1'), 2)]), 'ok', 'single choice refuses two options');
select isnt(vote(g('P1'), array[opt(g('PM'), 0)]), 'ok', 'an option of another poll is refused');
reset role;
select is(my_set(g('P1'), '02'), '1', 'the refused votes changed nothing');
select as_('01');
select is(vote(g('P1'), array[opt(g('P1'), 1)]), 'ok', 'ann votes Soup');
reset role;
select is(votes_of(g('P1'), 1) || '/' || voters_of(g('P1')), '2/2', 'Soup 2 votes, 2 voters');
select as_('02');
select is(vote(g('P1'), '{}'::uuid[]), 'ok', 'an empty array retracts');
reset role;
select is(my_set(g('P1'), '02'), '', 'bob has no vote');
select is(votes_of(g('P1'), 1) || '/' || voters_of(g('P1')), '1/1', 'Soup 1 vote, 1 voter');
select as_('02');
select is(vote(g('P1'), array[opt(g('P1'), 0)]), 'ok', 'bob votes Pizza again');
select is(vote(g('PM'), array[opt(g('PM'), 0), opt(g('PM'), 2)]), 'ok', 'multiple choice takes two');
reset role;
select is(my_set(g('PM'), '02'), '0,2', 'bob''s set is A and C');
select is(votes_of(g('PM'), 0) || '/' || votes_of(g('PM'), 1) || '/' || votes_of(g('PM'), 2) || '/' || voters_of(g('PM')),
          '1/0/1/1', 'A 1, B 0, C 1, one voter');
select as_('02');
select is(vote(g('PM'), array[opt(g('PM'), 2)]), 'ok', 'bob keeps only C');
reset role;
select is(my_set(g('PM'), '02'), '2', 'exactly C');
select is(votes_of(g('PM'), 0) || '/' || votes_of(g('PM'), 2) || '/' || voters_of(g('PM')), '0/1/1', 'A 0, C 1, one voter');
select as_('03');
select is(vote(g('P1'), array[opt(g('P1'), 0)]), '42501', 'a non-member cannot vote');
reset role;
select as_('bot');
select is(vote(g('P1'), array[opt(g('P1'), 0)]), '42501', 'the bot cannot vote in its own chat');
reset role;
select is(votes_of(g('P1'), 0) || '/' || voters_of(g('P1')), '1/2', 'the refused votes counted nothing');

-- 3 close_poll ------------------------------------------------------------------
select as_('02');
select is(close_(g('P1')), '42501', 'only the creator closes');
reset role;
select is((select closed_at from public.polls where message_id = g('P1')), null, 'P1 is still open');
select as_('01');
select is(close_(g('P1')), 'ok', 'ann closes her poll');
reset role;
select isnt((select closed_at from public.polls where message_id = g('P1')), null, 'P1 is closed');
update public.polls set closed_at = closed_at - interval '1 minute' where message_id = g('P1');
create temp table closed_at_before as select closed_at from public.polls where message_id = g('P1');
select as_('01');
select is(close_(g('P1')), 'ok', 'closing again is harmless');
reset role;
select is((select closed_at from public.polls where message_id = g('P1')), (select closed_at from closed_at_before),
          'and keeps the first closing time');
select as_('02');
select is(vote(g('P1'), array[opt(g('P1'), 1)]), '55000', 'a vote on a closed poll is 55000');
select is(vote(g('P1'), '{}'::uuid[]), '55000', 'so is a retract');
reset role;
select is(my_set(g('P1'), '02') || '/' || votes_of(g('P1'), 0) || '/' || voters_of(g('P1')), '0/1/2',
          'the closed poll keeps its votes');

-- 4 reading: members, anonymous votes, past members ------------------------------
select as_('01');
select is(vote(g('PA'), array[opt(g('PA'), 0)]), 'ok', 'ann votes Yes on the anonymous poll');
reset role;
select as_('02');
select is(vote(g('PA'), array[opt(g('PA'), 1)]), 'ok', 'bob votes No on it');
select is((select count(*) from public.polls where message_id = g('P1')), 1::bigint, 'a member reads the poll');
select is((select count(*) from public.poll_options where message_id = g('P1')), 3::bigint, 'and its options');
select is((select count(*) from public.poll_votes where message_id = g('P1')), 2::bigint,
          'and every vote of a public poll');
select is((select string_agg(user_id::text, ',') from public.poll_votes where message_id = g('PA')), u('02')::text,
          'on an anonymous poll only his own vote');
select is((select voter_count from public.polls where message_id = g('PA')), 2, 'but the voter count is all of them');
select is((select string_agg(vote_count::text, ',' order by position) from public.poll_options where message_id = g('PA')),
          '1,1', 'and so are the option counts');
reset role;
select as_('03');
select is((select count(*) from public.polls where message_id = g('P1')), 0::bigint, 'a non-member reads no poll');
select is((select count(*) from public.poll_options where message_id = g('P1')), 0::bigint, 'no options');
select is((select count(*) from public.poll_votes where message_id = g('P1')), 0::bigint, 'and no votes');
reset role;

-- dan makes an anonymous poll while a member, votes on it, then leaves 1 h ago;
-- his history began 3 h ago, the poll is 2 h old (inside), POUT is newer (outside)
update public.conversation_members set history_from = now() - interval '3 hours'
 where conversation_id = g('G') and user_id = u('04');
select as_('04');
select is(mk(g('G'), g('PIN'), 'Before I go?', array['Stay','Go'], false, true), 'ok', 'dan creates PIN');
select is(vote(g('PIN'), array[opt(g('PIN'), 1)]), 'ok', 'and votes Go');
reset role;
select as_('02');
select is(vote(g('PIN'), array[opt(g('PIN'), 0)]), 'ok', 'bob votes Stay on PIN');
reset role;
update public.messages set created_at = now() - interval '2 hours' where id = g('PIN');
update public.conversation_members set left_at = now() - interval '1 hour', left_reason = 'left'
 where conversation_id = g('G') and user_id = u('04');
select as_('01');
select is(mk(g('G'), g('POUT'), 'After dan?', array['a','b'], false, false), 'ok', 'ann creates POUT after dan left');
reset role;
select as_('04');
select is((select count(*) from public.polls where message_id = g('PIN')), 1::bigint,
          'a past member reads a poll inside his window');
select is((select count(*) from public.poll_options where message_id = g('PIN')), 2::bigint, 'and its options');
select is((select string_agg(user_id::text, ',') from public.poll_votes where message_id = g('PIN')), u('04')::text,
          'on an anonymous poll still only his own vote');
select is((select count(*) from public.polls where message_id = g('POUT')), 0::bigint,
          'he reads no poll after he left');
select is((select count(*) from public.poll_options where message_id = g('POUT')), 0::bigint, 'nor its options');
select is(vote(g('PIN'), array[opt(g('PIN'), 0)]), '42501', 'a past member cannot vote');
select is(vote(g('PIN'), '{}'::uuid[]), '42501', 'nor retract');
select is(close_(g('PIN')), '42501', 'nor close his own poll');
reset role;
select is(my_set(g('PIN'), '04') || '/' || voters_of(g('PIN')), '1/2', 'his vote stands');
select is((select closed_at from public.polls where message_id = g('PIN')), null, 'and PIN is open');

-- 5 frozen body, delete, cascade, Realtime --------------------------------------
select isnt(try(format($q$update public.messages set body = 'changed' where id = %L$q$, g('PM'))), 'ok',
            'a poll''s body cannot change, even for the owner role');
select is(try(format($q$update public.messages set body = 'edited text' where id = %L$q$, g('TXT'))), 'ok',
          'a text message''s body can (control)');
select as_('01');
select isnt(try(format($q$select public.edit_message(%L, 'new question')$q$, g('PM'))), 'ok',
            'edit_message refuses a poll');
reset role;
select is((select body from public.messages where id = g('PM')), 'Pick any', 'the question is unchanged');
select as_('01');
select is(try(format($q$select public.delete_message(%L)$q$, g('PA'))), 'ok',
          'the creator can still delete a poll for everyone');
reset role;
delete from public.messages where id = g('PM');
select is((select count(*) from public.polls where message_id = g('PM')), 0::bigint, 'deleting the message drops the poll');
select is(option_rows(g('PM')), 0::bigint, 'its options');
select is((select count(*) from public.poll_votes where message_id = g('PM')), 0::bigint, 'and its votes');
select ok(not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'poll_votes'),
          'poll_votes is not published to Realtime');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'polls'), 'polls is published');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'poll_options'), 'poll_options is published');
insert into public.messages(conversation_id, sender_id, body, created_at)
values (g('G'), u('01'), 'after the polls', now() + interval '1 second');
select as_('01');
select is((select poll from public.conversation_previews where conversation_id = g('G')), false,
          'a text message as the newest is not marked as a poll');
reset role;


select * from finish();
rollback;
