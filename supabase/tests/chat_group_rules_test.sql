begin;
select plan(47);

-- Chat and group rules (rules 9, 15-17, 19): written from the contract.
--   old delete_group / delete_direct_chat are refused (42501 'not permitted'), nothing deleted;
--   set_admin: the last admin may demote herself and the oldest other non-bot member is promoted;
--   new_members_see_history defaults to false; leave_group drops a group left with no member and
--   no people-sent message (and queues its avatar); add_members clears a re-added member's hide;
--   group_member_events shows left/removed events inside the caller's membership window.
-- Every group is built directly with explicit times; one gate per negative fixture.

create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000000c90' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@cg.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve')) v(n, name);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
values (u('bot'), 'cg-bot@mail.test', now(), '{"full_name":"CG Bot"}');
insert into app_private.allowlist(email)
select email from auth.users where id in (u('01'), u('02'), u('03'), u('04'), u('05'), u('bot'));
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('cc000000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05']) n;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'cc000000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function leave_c(c uuid) returns void language plpgsql as $$
begin perform public.leave_group(c); perform commit_check(); end $$;
create function admin_c(c uuid, m uuid, b boolean) returns void language plpgsql as $$
begin perform public.set_admin(c, m, b); perform commit_check(); end $$;
create temp table ids(name text primary key, id uuid);
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
create function admins_of(c uuid) returns text language sql as $$
  select string_agg(right(user_id::text, 2), ',' order by right(user_id::text, 2))
    from public.conversation_members where conversation_id = c and left_at is null and role = 'admin'
$$;
grant select on ids to authenticated;
grant execute on function as_(text), u(text), commit_check(), leave_c(uuid), admin_c(uuid, uuid, boolean),
  g(text), admins_of(uuid) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

-- grp(name, title) makes a titled group; mem(group, who, role, joined hours ago, left hours ago)
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

-- GB: ann alone (admin), a message she wrote
select grp('GB', 'cg-b'); select mem('GB', '01', 'admin', 5);
insert into public.messages(conversation_id, sender_id, body) values (g('GB'), u('01'), 'cg hello');
-- GC: ann, bob admins, cat member
select grp('GC', 'cg-c'); select mem('GC', '01', 'admin', 5); select mem('GC', '02', 'admin', 4); select mem('GC', '03', 'member', 6);
-- GL: ann admin, bob member, no message: bob leaving leaves a member behind
select grp('GL', 'cg-l'); select mem('GL', '01', 'admin', 5); select mem('GL', '02', 'member', 4);
-- GE: ann alone, no messages, with a group picture
select grp('GE', 'cg-e'); select mem('GE', '01', 'admin', 5);
update public.conversations set avatar_path = 'group/' || g('GE') || '/pic.jpg' where id = g('GE');
-- GF: ann alone, only an event line (no people-sent message), bob left earlier
select grp('GF', 'cg-f'); select mem('GF', '01', 'admin', 5); select mem('GF', '02', 'member', 6, 3);
-- GD: the bot's Debug group: bot (oldest, current), cat (oldest non-bot), bob, dan, ann = sole admin
select grp('GD', 'cg-debug');
select mem('GD', 'bot', 'member', 50); select mem('GD', '03', 'member', 9); select mem('GD', '02', 'member', 8);
select mem('GD', '04', 'member', 2); select mem('GD', '01', 'admin', 1);
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), g('GD'), true);
-- GS: system chat, GI: a 1:1, both with nobody current
select grp('GS', 'cg-s'); select mem('GS', '01', 'member', 5, 1);
update public.conversations set system = true where id = g('GS');
insert into public.conversations(title) values (null);
insert into ids select 'GI', id from public.conversations where title is null;
insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from, left_at, left_reason)
values (g('GI'), u('01'), 'member', now(), '-infinity', now(), 'left'), (g('GI'), u('02'), 'member', now(), '-infinity', now(), 'left');
select commit_check();

-- 1 old apps: delete_group / delete_direct_chat -----------------------------------------
select as_('01');
select throws_ok(format('select public.delete_group(%L)', g('GC')), '42501', 'not permitted',
                 'delete_group is refused for an admin');
select throws_ok(format('select public.delete_group(%L)', g('GD')), '42501', 'not permitted',
                 'and for the Debug group');
select throws_ok(format('select public.delete_direct_chat(%L)', g('GC')), '42501', 'not permitted',
                 'delete_direct_chat is refused');
reset role;
select is((select count(*)::int from public.conversations where id in (g('GC'), g('GD'))), 2,
          'nothing was deleted');
select is((select count(*)::int from public.conversation_members where conversation_id = g('GC')), 3,
          'and no member removed');
select function_returns('public', 'delete_group', array['uuid'], 'text[]', 'delete_group keeps its signature');
select function_returns('public', 'delete_direct_chat', array['uuid'], 'text[]', 'delete_direct_chat keeps its signature');
select has_function('public', 'set_admin', array['uuid', 'uuid', 'boolean'], 'set_admin signature unchanged');
select has_function('public', 'leave_group', array['uuid'], 'leave_group signature unchanged');
select has_function('public', 'add_members', array['uuid', 'uuid[]', 'boolean'], 'add_members signature unchanged');

-- 2 set_admin ---------------------------------------------------------------------------
select as_('02');
select throws_ok(format('select admin_c(%L, %L, true)', g('GD'), u('02')), null, null,
                 'a non-admin cannot make herself admin');
reset role;
select is(admins_of(g('GD')), '01', 'GD still has ann alone');
select as_('01');
select lives_ok(format('select admin_c(%L, %L, false)', g('GD'), u('01')), 'the sole admin of the Debug group demotes herself');
reset role;
select is(admins_of(g('GD')), '03', 'cat, the oldest non-bot other member, is promoted');
select ok(not exists (select 1 from public.conversation_members where conversation_id = g('GD')
                       and user_id = u('bot') and role = 'admin'), 'the bot is never promoted');
select is((select role from public.conversation_members where conversation_id = g('GD') and user_id = u('01')),
          'member', 'ann is an ordinary member now');
-- two admins: demoting one promotes nobody
select as_('01');
select lives_ok(format('select admin_c(%L, %L, false)', g('GC'), u('01')), 'one of two admins demotes herself');
reset role;
select is(admins_of(g('GC')), '02', 'only bob is admin: cat is not promoted');
select as_('02');
select lives_ok(format('select admin_c(%L, %L, true)', g('GC'), u('01')), 'bob makes ann admin again');
select lives_ok(format('select admin_c(%L, %L, false)', g('GC'), u('02')), 'and demotes bob; ann stays admin');
reset role;
select is(admins_of(g('GC')), '01', 'ann is the admin and bob was not re-promoted');
-- the only member cannot leave admin-less: an admin who is the only member cannot demote
select as_('01');
select throws_ok(format('select admin_c(%L, %L, false)', g('GB'), u('01')), null, null,
                 'the only member cannot demote herself');
reset role;
select is(admins_of(g('GB')), '01', 'and stays admin');

-- 3 default of the history switch ---------------------------------------------------------
select is((select column_default from information_schema.columns
            where table_schema = 'public' and table_name = 'conversations'
              and column_name = 'new_members_see_history'), 'false', 'the column default is false');
select ok(not (select new_members_see_history from public.conversations where id = g('GC')),
          'a new group does not show earlier messages to new members');
select ok(not exists (select 1 from public.conversations where new_members_see_history),
          'and no existing group has it on');

-- 4 leave_group: member-zero cleanup ------------------------------------------------------
select as_('01');
select lives_ok(format('select leave_c(%L)', g('GE')), 'ann leaves GE (no members left, no messages)');
select lives_ok(format('select leave_c(%L)', g('GB')), 'ann leaves GB (a message exists)');
select lives_ok(format('select leave_c(%L)', g('GF')), 'ann leaves GF (bob left earlier, no messages)');
reset role;
select as_('02');
select lives_ok(format('select leave_c(%L)', g('GL')), 'bob leaves GL, ann remains');
reset role;
select as_('01');
reset role;
select is((select count(*)::int from public.conversations where id = g('GE')), 0, 'GE is gone at once');
select is((select count(*)::int from app_private.storage_removal_queue
            where bucket = 'avatars' and path = 'group/' || g('GE') || '/pic.jpg'), 1, 'its picture is queued for removal');
select is((select count(*)::int from public.conversations where id = g('GB')), 1, 'GB stays: it has a message');
select is((select count(*)::int from public.conversations where id = g('GL')), 1, 'GL stays: a member remains');
select is((select count(*)::int from public.conversations where id = g('GF')), 0, 'GF is gone: nothing anyone wrote');
-- paths a leave cannot reach: call the cleanup itself. GD still has the bot as a current member.
update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = g('GD') and user_id <> u('bot');
select app_private.drop_group_if_unused(g('GD'));
select is((select count(*)::int from public.conversations where id = g('GD')), 1, 'a group the bot remains in is kept');
update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = g('GD');
select app_private.drop_group_if_unused(g('GD'));
select is((select count(*)::int from public.conversations where id = g('GD')), 1, 'the Debug group is never dropped');
select app_private.drop_group_if_unused(g('GS'));
select app_private.drop_group_if_unused(g('GI'));
select is((select count(*)::int from public.conversations where id in (g('GS'), g('GI'))), 2,
          'the system chat and a 1:1 are never dropped');

-- 5 add_members clears the hide of a re-added member --------------------------------------
select grp('GJ', 'cg-j'); select mem('GJ', '01', 'admin', 9); select mem('GJ', '02', 'member', 8, 4);
select mem('GJ', '03', 'member', 8);
select commit_check();
insert into public.chat_hides(user_id, conversation_id) values (u('02'), g('GJ')), (u('03'), g('GJ'));
select as_('01');
select lives_ok(format('select public.add_members(%L, array[%L]::uuid[], false)', g('GJ'), u('02')), 'ann re-adds bob');
reset role;
select is((select count(*)::int from public.chat_hides where conversation_id = g('GJ') and user_id = u('02')), 0,
          'bob''s hide is gone: the chat comes back');
select is((select count(*)::int from public.chat_hides where conversation_id = g('GJ') and user_id = u('03')), 1,
          'cat, a current member never added, keeps her hide');

-- 6 group_member_events -----------------------------------------------------------------
-- ann admin (whole history, current); bob left T-5h; cat in from T-3h; dan never a member
select grp('GK', 'cg-k'); select mem('GK', '01', 'admin', 10); select mem('GK', '02', 'member', 10, 5);
insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from)
values (g('GK'), u('03'), 'member', now() - interval '3 hours', now() - interval '3 hours');
select commit_check();
insert into public.group_events(conversation_id, kind, actor_id, subject_id, created_at) values
  (g('GK'), 'removed', u('01'), u('04'), now() - interval '8 hours'),
  (g('GK'), 'added',   u('01'), u('03'), now() - interval '4 hours'),
  (g('GK'), 'left',    null,    u('02'), now() - interval '5 hours'),
  (g('GK'), 'left',    null,    u('05'), now() - interval '2 hours');
select as_('01');
select is((select string_agg(kind, ',' order by created_at) from public.group_member_events(g('GK'))),
          'removed,left,left', 'ann reads left and removed events, never added');
reset role;
select as_('02');
select is((select string_agg(kind, ',' order by created_at) from public.group_member_events(g('GK'))),
          'removed,left', 'bob, who left at T-5h, reads up to and including his leaving');
reset role;
select as_('03');
select is((select count(*)::int from public.group_member_events(g('GK'))), 1,
          'cat reads only events inside her window (from T-3h)');
reset role;
select as_('04');
select is((select count(*)::int from public.group_member_events(g('GK'))), 0, 'a stranger reads nothing');
reset role;
select ok(not has_function_privilege('anon', 'public.group_member_events(uuid)', 'execute'),
          'anon cannot execute group_member_events');
select ok(has_function_privilege('authenticated', 'public.group_member_events(uuid)', 'execute'),
          'authenticated can');

select * from finish();
rollback;
