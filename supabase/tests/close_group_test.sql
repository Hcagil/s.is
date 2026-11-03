begin;
select plan(47);

-- close_group (Close group, server slice): written from the contract.
--   refused with 'not permitted' / 42501 unless a current admin of an open ordinary group;
--   success: closed_at/closed_by, one 'closed' event, every current member removed;
--   afterwards add_members is refused, only group_member_events shows the closed event;
--   a group with no message is dropped at once (avatar queued), the Debug group never is.
-- One gate per negative fixture.

create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b08'::uuid
              else ('00000000-0000-0000-0000-0000000c91' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@cl.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve'),('06','fay')) v(n, name);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
values (u('bot'), 'cl-bot@mail.test', now(), '{"full_name":"CL Bot"}');
insert into app_private.allowlist(email)
select email from auth.users where id in (u('01'), u('02'), u('03'), u('04'), u('05'), u('06'), u('bot'));
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('cd000000-0000-0000-0000-0000000000' || case when n = 'bot' then '07' else n end)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','bot']) n;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'cd000000-0000-0000-0000-0000000000' || case when n = 'bot' then '07' else n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function close_c(c uuid) returns void language plpgsql as $$
begin perform public.close_group(c); perform commit_check(); end $$;
create temp table ids(name text primary key, id uuid);
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant select on ids to authenticated;
grant execute on function as_(text), u(text), commit_check(), close_c(uuid), g(text) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','bot'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;
-- fay loses her session: no app access
delete from auth.sessions where id = 'cd000000-0000-0000-0000-000000000006';

create function grp(nm text, t text) returns void language plpgsql as $$
begin
  insert into public.conversations(title) values (t);
  insert into ids select nm, id from public.conversations where title = t and id not in (select id from ids);
end $$;
create function mem(nm text, who text, r text, joined_h numeric, left_h numeric default null)
returns void language sql as $$
  insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from, left_at, left_reason)
  values (g(nm), u(who), r, now() - joined_h * interval '1 hour', '-infinity',
          case when left_h is null then null else now() - left_h * interval '1 hour' end,
          case when left_h is null then null else 'left' end)
$$;
create function msg(nm text, who text) returns void language sql as $$
  insert into public.messages(conversation_id, sender_id, body) values (g(nm), u(who), 'cl hello')
$$;

-- RA: refusal fixture. ann/bob members; cat FORMER admin; fay admin w/o access; eve stranger.
select grp('RA', 'cl-ra'); select mem('RA', '01', 'admin', 9); select mem('RA', '02', 'member', 9);
select mem('RA', '03', 'admin', 9, 3); select mem('RA', '06', 'admin', 9);
select msg('RA', '01');
-- RC: already closed, ann current admin
select grp('RC', 'cl-rc'); select mem('RC', '01', 'admin', 9); select msg('RC', '01');
update public.conversations set closed_at = now() - interval '1 hour', closed_by = u('01') where id = g('RC');
-- RS: system chat, ann admin; RI: 1:1 with ann admin
select grp('RS', 'cl-rs'); select mem('RS', '01', 'admin', 9); select msg('RS', '01');
update public.conversations set system = true where id = g('RS');
insert into public.conversations(title) values (null);
insert into ids select 'RI', id from public.conversations where title is null;
insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from)
values (g('RI'), u('01'), 'admin', now(), '-infinity'), (g('RI'), u('02'), 'member', now(), '-infinity');
-- C1: ann, bob admins; cat member; dan former member; has a message
select grp('C1', 'cl-c1'); select mem('C1', '01', 'admin', 9); select mem('C1', '02', 'admin', 9);
select mem('C1', '03', 'member', 9); select mem('C1', '04', 'member', 9, 4); select msg('C1', '01');
-- E0: ann alone, no message, group picture; F0: ann admin + bob, no message (an old event line only)
select grp('E0', 'cl-e0'); select mem('E0', '01', 'admin', 9);
update public.conversations set avatar_path = 'group/' || g('E0') || '/pic.jpg' where id = g('E0');
select grp('F0', 'cl-f0'); select mem('F0', '01', 'admin', 9); select mem('F0', '02', 'member', 9);
insert into public.group_events(conversation_id, kind, actor_id, subject_id) values (g('F0'), 'added', u('01'), u('02'));
-- D0: Debug group: ann admin, bot member, no message
select grp('D0', 'cl-debug'); select mem('D0', '01', 'admin', 9); select mem('D0', 'bot', 'member', 9);
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), g('D0'), true);
select commit_check();

-- 1 grants ------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.close_group(uuid)', 'execute'), 'anon cannot execute close_group');
select ok(has_function_privilege('authenticated', 'public.close_group(uuid)', 'execute'), 'authenticated can');

-- 2 refusals ----------------------------------------------------------------------------
select as_('02');
select throws_ok(format('select public.close_group(%L)', g('RA')), '42501', 'not permitted', 'a plain member is refused');
reset role;
select as_('03');
select throws_ok(format('select public.close_group(%L)', g('RA')), '42501', 'not permitted', 'a former admin is refused');
reset role;
select as_('05');
select throws_ok(format('select public.close_group(%L)', g('RA')), '42501', 'not permitted', 'a stranger is refused');
reset role;
select as_('06');
select throws_ok(format('select public.close_group(%L)', g('RA')), '42501', 'not permitted', 'an admin without app access is refused');
reset role;
select as_('bot');
-- a bot cannot hold the admin role (bot guard), so it is refused in the Debug group it belongs to
select throws_ok(format('select public.close_group(%L)', g('D0')), '42501', 'not permitted', 'a bot is refused');
reset role;
select as_('01');
select throws_ok(format('select public.close_group(%L)', gen_random_uuid()), '42501', 'not permitted', 'a missing conversation is refused');
select throws_ok(format('select public.close_group(%L)', g('RI')), '42501', 'not permitted', 'a 1:1 chat is refused');
select throws_ok(format('select public.close_group(%L)', g('RS')), '42501', 'not permitted', 'a system chat is refused');
select throws_ok(format('select public.close_group(%L)', g('RC')), '42501', 'not permitted', 'an already closed group is refused');
reset role;
select is((select count(*)::int from public.conversations where id in (g('RA'), g('RI'), g('RS'), g('D0')) and closed_at is not null), 0,
          'nothing was closed by a refused call');
select is((select count(*)::int from public.conversation_members where conversation_id = g('RA') and left_at is null), 3,
          'and no member of RA was removed');
select is((select count(*)::int from public.group_events where conversation_id in (g('RA'), g('RC'))), 0, 'and no event written');

-- 3 success -------------------------------------------------------------------------------
select as_('01');
select lives_ok(format('select close_c(%L)', g('C1')), 'ann closes C1');
reset role;
select is((select closed_by from public.conversations where id = g('C1')), u('01'), 'closed_by is ann');
select ok((select closed_at is not null from public.conversations where id = g('C1')), 'closed_at is set');
select is((select count(*)::int from public.group_events where conversation_id = g('C1')), 1, 'exactly one event');
select is((select kind || ':' || (actor_id = u('01'))::text || ':' || (subject_id = u('01'))::text
             from public.group_events where conversation_id = g('C1')), 'closed:true:true', 'a closed event, actor = subject = ann');
select is((select count(*)::int from public.conversation_members
            where conversation_id = g('C1') and user_id in (u('01'), u('02'), u('03'))
              and left_at is not null and left_reason = 'removed' and closed_by = u('01')), 3,
          'ann, bob and cat are removed and marked closed_by ann');
select is((select count(*)::int from public.conversation_members where conversation_id = g('C1') and left_at is null), 0,
          'nobody is left in C1');
select is((select left_reason || ':' || coalesce(closed_by::text, '-') from public.conversation_members
            where conversation_id = g('C1') and user_id = u('04')), 'left:-', 'the former member dan is untouched');
select is((select count(*)::int from public.group_events where conversation_id = g('C1') and kind = 'removed'), 0,
          'no per-member removed events');
select is((select closed_at from public.conversations where id = g('C1')), now(), 'closed_at is the transaction time');

-- 4 after the close -----------------------------------------------------------------------
select as_('01');
select throws_ok(format('select public.add_members(%L, array[%L]::uuid[], false)', g('C1'), u('05')), '42501', 'not permitted',
                 'the former admin cannot add members');
reset role;
select as_('02');
select throws_ok(format('select public.add_members(%L, array[%L]::uuid[], false)', g('C1'), u('05')), '42501', 'not permitted',
                 'nor the other former admin');
reset role;
select as_('01');
select throws_ok(format('select public.close_group(%L)', g('C1')), '42501', 'not permitted', 'closing twice is refused');
reset role;
-- a closed group that still has a current admin (RC) and a reachable newcomer (bob shares RA with ann)
select as_('01');
select throws_ok(format('select public.add_members(%L, array[%L]::uuid[], false)', g('RC'), u('02')), '42501', 'not permitted',
                 'a closed group takes nobody, even with a current admin');
reset role;
select ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.proname ~* 'reopen'), 'there is no reopen function');

-- 5 visibility ----------------------------------------------------------------------------
select as_('01');
select is((select count(*)::int from public.group_member_events(g('C1')) where kind = 'closed'), 1, 'ann (admin) reads the closed event');
select is((select count(*)::int from public.group_events where conversation_id = g('C1')), 0, 'ann gets no row by plain select');
reset role;
select as_('03');
select is((select count(*)::int from public.group_member_events(g('C1')) where kind = 'closed'), 1, 'cat (member) reads the closed event');
select is((select count(*)::int from public.group_events where conversation_id = g('C1')), 0, 'cat gets no row by plain select');
reset role;
select as_('02');
select is((select count(*)::int from public.group_member_events(g('C1')) where kind = 'closed'), 1, 'bob reads the closed event');
select throws_ok('select closed_by from public.conversation_members', '42501', null, 'conversation_members.closed_by is not readable');
select lives_ok('select closed_by from public.conversations', 'conversations.closed_by is readable');
reset role;
select as_('05');
select is((select count(*)::int from public.group_member_events(g('C1'))), 0, 'a stranger reads nothing');
reset role;

-- a closed event never shows by plain select, even to a current admin (RA is open: ann is admin there)
insert into public.group_events(conversation_id, kind, actor_id, subject_id) values
  (g('RA'), 'closed', u('01'), u('01')), (g('RA'), 'removed', u('01'), u('03'));
select as_('01');
select is((select count(*)::int from public.group_events where conversation_id = g('RA') and kind = 'removed'), 1,
          'control: the current admin does see a removed event by plain select');
select is((select count(*)::int from public.group_events where conversation_id = g('RA') and kind = 'closed'), 0,
          'but never the closed event');
reset role;

-- 6 drop at once --------------------------------------------------------------------------
select as_('01');
select lives_ok(format('select close_c(%L)', g('E0')), 'ann closes E0 (no message)');
select lives_ok(format('select close_c(%L)', g('F0')), 'ann closes F0 (only an event line)');
reset role;
select is((select count(*)::int from public.conversations where id in (g('E0'), g('F0'))), 0, 'both are gone at once');
select is((select count(*)::int from app_private.storage_removal_queue
            where bucket = 'avatars' and path = 'group/' || g('E0') || '/pic.jpg'), 1, 'the picture is queued for removal');
select is((select count(*)::int from public.conversations where id = g('C1')), 1, 'C1 stays: it has a message');

-- 7 Debug group ---------------------------------------------------------------------------
select as_('01');
select lives_ok(format('select close_c(%L)', g('D0')), 'an admin closes the Debug group');
reset role;
select is((select (closed_by = u('01'))::text from public.conversations where id = g('D0')), 'true', 'it is closed');
select is((select count(*)::int from public.conversation_members where conversation_id = g('D0') and left_at is null), 0,
          'everyone, the bot too, is removed');

select * from finish();
rollback;
