begin;
select plan(31);

-- invite_link_admin (Invite link admin, server slice): skeleton test
--   tests function and table privileges for invite link administration.

create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b08'::uuid
              else ('00000000-0000-0000-0000-0000000c92' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@il.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','eve'),('05','fay')) v(n, name);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
values (u('bot'), 'il-bot@mail.test', now(), '{"full_name":"IL Bot"}');
insert into app_private.allowlist(email)
select email from auth.users where id in (u('01'), u('02'), u('03'), u('04'), u('05'), u('bot'));
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('ce000000-0000-0000-0000-0000000000' || case when n = 'bot' then '07' else n end)::uuid,
       u(n), now(), now()
  from unnest(array['01','02','03','04','05','bot']) n;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'ce000000-0000-0000-0000-0000000000' || case when n = 'bot' then '07' else n end)::text, true);
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
  foreach n in array array['01','02','03','04','05','bot'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;
-- fay loses her session: no app access
delete from auth.sessions where id = 'ce000000-0000-0000-0000-000000000005';

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

-- fixtures
select grp('E1','ie-1'); select mem('E1','01','admin',9); select mem('E1','02','member',9); select mem('E1','03','admin',9,3); select mem('E1','05','admin',9);
select grp('E2','ie-2'); select mem('E2','01','admin',9);
select grp('EC','ie-c'); select mem('EC','01','admin',9);
select grp('EA','ie-a'); select mem('EA','01','admin',9); update public.conversations set admin_chat = true where id = g('EA');
select grp('ES','ie-s'); select mem('ES','01','admin',9); select mem('ES','02','member',9); update public.conversations set system = true where id = g('ES');
select grp('EB','ie-b'); select mem('EB','01','admin',9); select mem('EB','bot','member',9); update public.conversations set debug_chat = true where id = g('EB');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), g('EB'), true);
select commit_check();
create temp table t1(token text, created_at timestamptz, expires_at timestamptz);
create temp table t2(token text, created_at timestamptz, expires_at timestamptz);
grant all on t1, t2 to authenticated;
select as_('01');
insert into t1 select * from public.reset_invite_link(g('E1'), 1);
reset role;
insert into app_private.group_invite_links(conversation_id, token, created_by) values (g('ES'), 'ssssssssssssssssssssssss', u('01'));
update public.conversations set closed_at = now(), closed_by = u('01') where id = g('EC');
-- refusals (set_invite_link_expiry(conversation uuid, valid_days int), SQLSTATE 42501)
select as_('02');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('E1')), '42501', null, 'expiry: a plain member is refused');
reset role;
select as_('03');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('E1')), '42501', null, 'expiry: an ex-admin is refused');
reset role;
select as_('04');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('E1')), '42501', null, 'expiry: a stranger is refused');
reset role;
select as_('05');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('E1')), '42501', null, 'expiry: an admin without app access is refused');
reset role;
select as_('bot');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('EB')), '42501', null, 'expiry: a bot is refused');
reset role;
select as_('01');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', gen_random_uuid()), '42501', null, 'expiry: a missing conversation is refused');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('EC')), '42501', null, 'expiry: a closed group is refused');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('EA')), '42501', null, 'expiry: an admin chat is refused');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('ES')), '42501', null, 'expiry: a system chat is refused');
select throws_ok(format('select * from public.get_invite_link(%L)', g('ES')), '42501', null, 'get: a system chat is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('ES')), '42501', null, 'reset: a system chat is refused');
select throws_ok(format('select public.turn_off_invite_link(%L)', g('ES')), '42501', null, 'turn off: a system chat is refused');
reset role;
select as_('02');
select throws_ok(format('select public.join_by_link(%L)', 'ssssssssssssssssssssssss'), 'LINK1', null, 'join: a system chat link is invalid');
select throws_ok(format('select * from public.preview_invite_link(%L)', 'ssssssssssssssssssssssss'), 'LINK1', null, 'preview: a system chat link is invalid');
reset role;
-- validity and missing link
select as_('01');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, %s)', g('E1'), 0), '22023', null, 'expiry: validity 0 is refused');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, %s)', g('E1'), 2), '22023', null, 'expiry: validity 2 is refused');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, %s)', g('E1'), -1), '22023', null, 'expiry: validity -1 is refused');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, %s)', g('E1'), 365), '22023', null, 'expiry: validity 365 is refused');
select throws_ok(format('select * from public.set_invite_link_expiry(%L, null)', g('E2')), 'LINK1', null, 'expiry: a group with no link answers LINK1');
-- behaviour
insert into t2 select * from public.set_invite_link_expiry(g('E1'), 30);
select is((select token from t2), (select token from t1), 'expiry keeps the same token');
select is((select created_at from t2), (select created_at from t1), 'expiry keeps created_at');
select ok((select abs(extract(epoch from expires_at - (now() + interval '30 days'))) < 60 from t2), 'expiry sets now + 30 days');
select is((select token from public.get_invite_link(g('E1'))), (select token from t1), 'get still shows the same token');
select ok((select abs(extract(epoch from expires_at - (now() + interval '30 days'))) < 60 from public.get_invite_link(g('E1'))), 'get shows the new expiry');
select ok((select expires_at is null from public.set_invite_link_expiry(g('E1'), null)), 'null validity removes the limit');
select ok((select abs(extract(epoch from expires_at - (now() + interval '7 days'))) < 60 from public.set_invite_link_expiry(g('E1'), 7)), 'validity 7 days');
reset role;
select as_('04');
select is(public.join_by_link((select token from t1)), g('E1'), 'the old link still joins after the limit changed');
reset role;
update app_private.group_invite_links set expires_at = now() - interval '1 hour' where conversation_id = g('E1');
select as_('03');
select throws_ok(format('select public.join_by_link(%L)', (select token from t1)), 'LINK2', null, 'an expired link answers LINK2');
reset role;
select as_('01');
select public.set_invite_link_expiry(g('E1'), 7);
reset role;
select as_('03');
select is(public.join_by_link((select token from t1)), g('E1'), 'a new limit brings the same link back to life');
reset role;
select ok(not has_function_privilege('anon','public.set_invite_link_expiry(uuid,int)','execute'), 'anon cannot execute set_invite_link_expiry');
select ok(has_function_privilege('authenticated','public.set_invite_link_expiry(uuid,int)','execute'), 'authenticated can execute set_invite_link_expiry');
select * from finish();
rollback;
