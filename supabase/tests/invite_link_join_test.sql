begin;
select plan(57);

-- invite_link_join (Invite link join, server slice): skeleton test
--   tests function and table privileges for invite link joining.

create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b08'::uuid
              else ('00000000-0000-0000-0000-0000000c93' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@il.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve'),('06','fay'),('07','gus'),('08','hal')) v(n, name);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
values (u('bot'), 'il-bot@mail.test', now(), '{"full_name":"IL Bot"}');
insert into app_private.allowlist(email)
select email from auth.users where id in (u('01'), u('02'), u('03'), u('04'), u('05'), u('06'), u('08'), u('bot'));
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('cf000000-0000-0000-0000-0000000000' || case when n = 'bot' then '09' else n end)::uuid,
       u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','07','08','bot']) n;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'cf000000-0000-0000-0000-0000000000' || case when n = 'bot' then '09' else n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create temp table ids(name text primary key, id uuid);
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant select on ids to authenticated;
grant execute on function as_(text), u(text), commit_check(), g(text) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07','08','bot'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;
-- delete fay's session
delete from auth.sessions where id = 'cf000000-0000-0000-0000-000000000006';

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
  insert into public.messages(conversation_id, sender_id, body) values (g(nm), u(who), 'il hello')
$$;

-- Fixtures ------------------------------------------------------------

-- J1 grp('J1','ij-1'): ann admin 9, cat member 9, dan member 9 left 4, eve member 9 left 5. Then: update public.conversation_members set left_reason = 'removed' where conversation_id = g('J1') and user_id = u('04'); and select msg('J1','01'); (new_members_see_history stays false).
select grp('J1','ij-1');
select mem('J1','01','admin',9);
select mem('J1','03','member',9);
select mem('J1','04','member',9,4);
select mem('J1','05','member',9,5);
update public.conversation_members set left_reason = 'removed' where conversation_id = g('J1') and user_id = u('04');
select msg('J1','01');

-- J2 grp('J2','ij-2'): ann admin 9; msg('J2','01'); update public.conversations set new_members_see_history = true, avatar_path = 'group/' || g('J2') || '/pic.jpg' where id = g('J2').
select grp('J2','ij-2');
select mem('J2','01','admin',9);
select msg('J2','01');
update public.conversations set new_members_see_history = true, avatar_path = 'group/' || g('J2') || '/pic.jpg' where id = g('J2');

-- J3 grp('J3','ij-3'): ann admin 9 (test will close it later).
select grp('J3','ij-3');
select mem('J3','01','admin',9);

-- J6 grp('J6','ij-6'): ann admin 9 (test will expire its link later).
select grp('JB','ij-b'); select mem('JB','01','admin',9); select mem('JB','bot','member',9);
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), g('JB'), true);
select grp('J6','ij-6');
select mem('J6','01','admin',9);

-- JD 1:1: insert into public.conversations(title) values (null); register in ids as 'JD'; ann and cat both role 'admin' (copy RI from close_group_test style: insert into ids select 'JD', id from public.conversations where title is null and id not in (select id from ids);).
insert into public.conversations(title) values (null);
insert into ids select 'JD', id from public.conversations where title is null and id not in (select id from ids);
select mem('JD','01','admin',9);
select mem('JD','03','admin',9);

-- JA grp('JA','ij-a'): ann admin 9; update public.conversations set admin_chat = true where id = g('JA').
select grp('JA','ij-a');
select mem('JA','01','admin',9);
update public.conversations set admin_chat = true where id = g('JA');

-- bob and gus, hal are in no group. Hide row: insert into public.chat_hides(user_id, conversation_id) values (u('02'), g('J1'));
insert into public.chat_hides(user_id, conversation_id) values (u('02'), g('J1'));

insert into app_private.tag_finds(finder, found_id) values (u('01'), u('04'));
select commit_check();

-- create token table and fill it
create temp table tok(name text primary key, token text);
grant select on tok to authenticated;
create function mk(nm text) returns void language plpgsql as $$ begin perform as_('01'); insert into tok select nm, token from public.reset_invite_link(g(nm), null); execute 'reset role'; end $$;
grant execute on function mk(text) to authenticated;   -- NOTE: also needs tok insert privilege: grant insert on tok to authenticated before mk is called
grant insert on tok to authenticated;
select mk('J1'); select mk('J2'); select mk('J3'); select mk('J6');

-- Direct links for the two refused chats (superuser): insert into app_private.group_invite_links(conversation_id, token, created_by) values (g('JD'), 'aaaaaaaaaaaaaaaaaaaaaaaa', u('01')), (g('JA'), 'bbbbbbbbbbbbbbbbbbbbbbbb', u('01')); insert into tok values ('JD','aaaaaaaaaaaaaaaaaaaaaaaa'), ('JA','bbbbbbbbbbbbbbbbbbbbbbbb');
insert into app_private.group_invite_links(conversation_id, token, created_by) values (g('JD'), 'aaaaaaaaaaaaaaaaaaaaaaaa', u('01')), (g('JA'), 'bbbbbbbbbbbbbbbbbbbbbbbb', u('01'));
insert into tok values ('JD','aaaaaaaaaaaaaaaaaaaaaaaa'), ('JA','bbbbbbbbbbbbbbbbbbbbbbbb');

-- Add a function tk(nm text) returns text language sql stable as $$ select token from tok where name = nm $$; grant execute on it to authenticated.
create function tk(nm text) returns text language sql stable as $$ select token from tok where name = nm $$;
grant execute on function tk(text) to authenticated;

-- 4 assertions only
select ok(not has_function_privilege('anon','public.preview_invite_link(text)','execute'), 'anon cannot execute preview_invite_link');
select ok(has_function_privilege('authenticated','public.preview_invite_link(text)','execute'), 'authenticated can execute preview_invite_link');
select ok(not has_function_privilege('anon','public.join_by_link(text)','execute'), 'anon cannot execute join_by_link');
select ok(has_function_privilege('authenticated','public.join_by_link(text)','execute'), 'authenticated can execute join_by_link');

reset role;
create temp table jr(cid uuid);
grant all on jr to authenticated;
select as_('02');
select is((select title from public.preview_invite_link(tk('J2'))), 'ij-2', 'preview shows the group name');
select is((select member_count::int from public.preview_invite_link(tk('J2'))), 1, 'preview counts the members');
select is((select avatar_path from public.preview_invite_link(tk('J2'))), 'group/' || g('J2') || '/pic.jpg', 'preview shows the picture path');
select is((select conversation_id from public.preview_invite_link(tk('J2'))), g('J2'), 'preview shows the group id');
select ok(pg_get_function_result('public.preview_invite_link(text)'::regprocedure) !~* 'user_id|email|members\M', 'preview returns no member list');
reset role;
select is((select count(*)::int from public.conversation_members where conversation_id = g('J2') and user_id = u('02')), 0, 'preview does not join');
select as_('02');
insert into jr select public.join_by_link(tk('J1'));
select is((select cid from jr), g('J1'), 'join returns the group id');
reset role;
select is((select role from public.conversation_members where conversation_id = g('J1') and user_id = u('02') and left_at is null), 'member', 'the joiner is a member');
select ok((select history_from > now() - interval '1 minute' from public.conversation_members where conversation_id = g('J1') and user_id = u('02')), 'J1 hides earlier messages: history_from is now');
select is((select count(*)::int from public.chat_hides where user_id = u('02') and conversation_id = g('J1')), 0, 'the hide row is cleared');
select is((select count(*)::int from public.group_events where conversation_id = g('J1') and kind = 'joined' and actor_id = u('02') and subject_id = u('02')), 1, 'a joined event is written, actor = subject');
select as_('02');
select public.join_by_link(tk('J2'));
reset role;
select ok((select history_from = '-infinity' from public.conversation_members where conversation_id = g('J2') and user_id = u('02')), 'J2 shows earlier messages: history_from is -infinity');
select as_('02');
select is(public.join_by_link(tk('J1')), g('J1'), 'a second join returns the id');
reset role;
select is((select count(*)::int from public.conversation_members where conversation_id = g('J1') and user_id = u('02')), 1, 'no second member row');
select is((select count(*)::int from public.group_events where conversation_id = g('J1') and kind = 'joined'), 1, 'no second event');
select as_('01');
select is((select count(*)::int from public.group_events where kind = 'joined'), 0, 'the old read policy hides joined events');
select is((select count(*)::int from public.group_join_events(g('J1'))), 1, 'group_join_events shows the event to a member');
reset role;
select as_('08');
select is((select count(*)::int from public.group_join_events(g('J1'))), 0, 'a non-member sees no joined events');
reset role;
select as_('05');
select is(public.join_by_link(tk('J1')), g('J1'), 'a person who left on their own can come back');
reset role;
select is((select count(*)::int from public.conversation_members where conversation_id = g('J1') and user_id = u('05') and left_at is null), 1, 'she is a current member again');
reset role;
select as_('03');
select throws_ok(format('select public.join_by_link(%L)', 'short'), 'LINK1', null, 'join: a bad token shape is invalid');
select throws_ok(format('select public.join_by_link(%L)', ''), 'LINK1', null, 'join: an empty token is invalid');
select throws_ok(format('select public.join_by_link(%L)', repeat('z', 24)), 'LINK1', null, 'join: an unknown token is invalid');
select throws_ok(format('select * from public.preview_invite_link(%L)', repeat('z', 24)), 'LINK1', null, 'preview: an unknown token is invalid');
reset role;
update app_private.group_invite_links set expires_at = now() - interval '1 hour' where conversation_id = g('J6');
select as_('03');
select throws_ok(format('select public.join_by_link(%L)', tk('J6')), 'LINK2', null, 'join: an expired link');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J6')), 'LINK2', null, 'preview: an expired link');
reset role;
select as_('01');
insert into tok select 'J6new', token from public.reset_invite_link(g('J6'), 7);
reset role;
select as_('03');
select throws_ok(format('select public.join_by_link(%L)', tk('J6')), 'LINK1', null, 'join: the old token stops working after a reset');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J6')), 'LINK1', null, 'preview: the old token stops working after a reset');
select is((select count(*)::int from public.preview_invite_link(tk('J6new'))), 1, 'preview: the new token works');
reset role;
select as_('01');
select public.turn_off_invite_link(g('J6'));
reset role;
select as_('03');
select throws_ok(format('select public.join_by_link(%L)', tk('J6new')), 'LINK1', null, 'join: a turned-off link is invalid');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J6new')), 'LINK1', null, 'preview: a turned-off link is invalid');
reset role;
update public.conversations set closed_at = now(), closed_by = u('01') where id = g('J3');
select as_('03');
select throws_ok(format('select public.join_by_link(%L)', tk('J3')), 'LINK3', null, 'join: a closed group');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J3')), 'LINK3', null, 'preview: a closed group');
select throws_ok(format('select public.join_by_link(%L)', tk('JD')), 'LINK1', null, 'join: a direct chat link is invalid');
select throws_ok(format('select public.join_by_link(%L)', tk('JA')), 'LINK1', null, 'join: an admin chat link is invalid');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('JA')), 'LINK1', null, 'preview: an admin chat link is invalid');
reset role;
select as_('04');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J1')), 'LINK4', null, 'preview: a person an admin removed');
select throws_ok(format('select public.join_by_link(%L)', tk('J1')), 'LINK4', null, 'join: a person an admin removed');
reset role;
select as_('01');
select lives_ok(format('select public.add_members(%L, array[%L]::uuid[], true)', g('J1'), u('04')), 'an admin adds the removed person back');
reset role;
select commit_check();
select as_('04');
select is(public.join_by_link(tk('J1')), g('J1'), 'after an admin adds her back the link works');
reset role;
reset role;
select as_('06');
select throws_ok(format('select public.join_by_link(%L)', tk('J2')), '42501', null, 'join: no active session is refused');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J2')), '42501', null, 'preview: no active session is refused');
reset role;
select as_('07');
select throws_ok(format('select public.join_by_link(%L)', tk('J2')), '42501', null, 'join: not on the allowlist is refused');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J2')), '42501', null, 'preview: not on the allowlist is refused');
reset role;
select as_('bot');
select throws_ok(format('select public.join_by_link(%L)', tk('J2')), '42501', null, 'join: a bot is refused');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J2')), '42501', null, 'preview: a bot is refused');
reset role;
set local role anon;
select throws_ok(format('select public.join_by_link(%L)', repeat('y', 24)), '42501', null, 'join: anon is refused');
reset role;
select as_('08');
select is((select count(*)::int from generate_series(1, 20) i, lateral public.preview_invite_link(tk('J2') || repeat('', i))), 20, 'the 20th call in ten minutes is allowed');
select throws_ok(format('select * from public.preview_invite_link(%L)', tk('J2')), 'RLMT1', null, 'preview: the 21st call is refused');
select throws_ok(format('select public.join_by_link(%L)', tk('J2')), 'RLMT1', null, 'join: shares the same limit, the 21st call is refused');
reset role;
select as_('02');
select lives_ok(format('select * from public.preview_invite_link(%L)', tk('J2')), 'another person is not limited');
reset role;
select is((select count(*)::int from app_private.invite_link_attempts where user_id = u('08')), 20, 'a refused call leaves no extra attempt row');
update app_private.invite_link_attempts set called_at = called_at - interval '11 minutes' where user_id = u('08');
select as_('08');
select lives_ok(format('select * from public.preview_invite_link(%L)', tk('J2')), 'attempts older than ten minutes no longer count');
reset role;
select * from finish();
rollback;
