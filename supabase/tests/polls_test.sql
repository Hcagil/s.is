begin;
select plan(1);

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

select pass('fixtures ready');

select * from finish();
rollback;
