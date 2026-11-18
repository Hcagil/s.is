begin;
select plan(65);

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

-- Fixtures ------------------------------------------------------------

-- G1: grp('G1','il-g1'); ann admin 9; bob member 9; cat admin 9 left 3; fay admin 9.
select grp('G1','il-g1');
select mem('G1','01','admin',9);
select mem('G1','02','member',9);
select mem('G1','03','admin',9,3);
select mem('G1','05','admin',9);

-- GM: ann admin, bob member, then update public.conversations set members_can_add = true where id = g('GM').
select grp('GM','il-gm');
select mem('GM','01','admin',9);
select mem('GM','02','member',9);
update public.conversations set members_can_add = true where id = g('GM');

-- GC: ann admin; update public.conversations set closed_at = now(), closed_by = u('01') where id = g('GC').
select grp('GC','il-gc');
select mem('GC','01','admin',9);
update public.conversations set closed_at = now(), closed_by = u('01') where id = g('GC');

-- GD (1:1): insert into public.conversations(title) values (null) and register in ids as 'GD', ann and bob both role 'admin'.
insert into public.conversations(title) values (null);
insert into ids select 'GD', id from public.conversations where title is null and id not in (select id from ids);
select mem('GD','01','admin',9);
select mem('GD','02','admin',9);

-- GS: ann admin; update public.conversations set admin_chat = true where id = g('GS').
select grp('GS','il-gs');
select mem('GS','01','admin',9);
update public.conversations set admin_chat = true where id = g('GS');
select grp('GT','il-gt'); select mem('GT','01','admin',9); update public.conversations set staff_b_chat = true where id = g('GT');
update public.conversations set debug_chat = true where id = g('GB');

-- GB: ann admin, bot member; insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), g('GB'), true).
select grp('GB','il-gb');
select mem('GB','01','admin',9);
select mem('GB','bot','member',9);
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), g('GB'), true);

select commit_check();

-- Grants ------------------------------------------------------------


-- Function privilege checks
select ok(not has_function_privilege('anon','public.get_invite_link(uuid)','execute'), 'anon cannot execute get_invite_link');
select ok(has_function_privilege('authenticated','public.get_invite_link(uuid)','execute'), 'authenticated can execute get_invite_link');
select ok(not has_function_privilege('anon','public.reset_invite_link(uuid,int)','execute'), 'anon cannot execute reset_invite_link');
select ok(has_function_privilege('authenticated','public.reset_invite_link(uuid,int)','execute'), 'authenticated can execute reset_invite_link');
select ok(not has_function_privilege('anon','public.turn_off_invite_link(uuid)','execute'), 'anon cannot execute turn_off_invite_link');
select ok(has_function_privilege('authenticated','public.turn_off_invite_link(uuid)','execute'), 'authenticated can execute turn_off_invite_link');

-- Table privilege checks
select ok((select relrowsecurity from pg_class where oid = 'app_private.group_invite_links'::regclass), 'group_invite_links has row security');
select ok(not has_table_privilege('anon','app_private.group_invite_links','select,insert,update,delete'), 'anon cannot access group_invite_links');
select ok(not has_table_privilege('authenticated','app_private.group_invite_links','select,insert,update,delete'), 'authenticated cannot access group_invite_links');
select ok((select relrowsecurity from pg_class where oid = 'app_private.invite_link_attempts'::regclass), 'invite_link_attempts has row security');
select ok(not has_table_privilege('anon','app_private.invite_link_attempts','select,insert,update,delete'), 'anon cannot access invite_link_attempts');
select ok(not has_table_privilege('authenticated','app_private.invite_link_attempts','select,insert,update,delete'), 'authenticated cannot access invite_link_attempts');


-- refusals
-- invite_link_refusals.sql
-- Test cases for invite link refusal scenarios

-- 1. G1 member (role 02) – all three actions
select as_('02');
select throws_ok(format('select * from public.get_invite_link(%L)', g('G1')), '42501', null, 'get: a plain member is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('G1')), '42501', null, 'reset: a plain member is refused');
select throws_ok(format('select public.turn_off_invite_link(%L)', g('G1')), '42501', null, 'turn off: a plain member is refused');
reset role;

-- 2. GM member (role 02) – get and reset only
select as_('02');
select throws_ok(format('select * from public.get_invite_link(%L)', g('GM')), '42501', null, 'get: member with members_can_add is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('GM')), '42501', null, 'reset: member with members_can_add is refused');
reset role;

-- 3. Ex-admin (role 03) – all three actions
select as_('03');
select throws_ok(format('select * from public.get_invite_link(%L)', g('G1')), '42501', null, 'get: ex-admin is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('G1')), '42501', null, 'reset: ex-admin is refused');
select throws_ok(format('select public.turn_off_invite_link(%L)', g('G1')), '42501', null, 'turn off: ex-admin is refused');
reset role;

-- 4. Stranger (role 04) – all three actions
select as_('04');
select throws_ok(format('select * from public.get_invite_link(%L)', g('G1')), '42501', null, 'get: stranger is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('G1')), '42501', null, 'reset: stranger is refused');
select throws_ok(format('select public.turn_off_invite_link(%L)', g('G1')), '42501', null, 'turn off: stranger is refused');
reset role;

-- 5. Admin without app access (role 05) – get and reset only
select as_('05');
select throws_ok(format('select * from public.get_invite_link(%L)', g('G1')), '42501', null, 'get: admin without app access is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('G1')), '42501', null, 'reset: admin without app access is refused');
select throws_ok(format('select public.turn_off_invite_link(%L)', g('G1')), '42501', null, 'turn off: admin without app access is refused');
reset role;

-- 6. Bot (role bot) – get and reset only
select as_('bot');
select throws_ok(format('select * from public.get_invite_link(%L)', g('GB')), '42501', null, 'get: bot is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('GB')), '42501', null, 'reset: bot is refused');
reset role;

-- 7. Missing conversation (role 01) – get and reset only
select as_('01');
select throws_ok(format('select * from public.get_invite_link(%L)', gen_random_uuid()), '42501', null, 'get: missing conversation is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', gen_random_uuid()), '42501', null, 'reset: missing conversation is refused');
reset role;

-- 8. Closed group (role 01) – get and reset only
select as_('01');
select throws_ok(format('select * from public.get_invite_link(%L)', g('GC')), '42501', null, 'get: closed group is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('GC')), '42501', null, 'reset: closed group is refused');
reset role;

-- 9. 1:1 chat (role 01) – get and reset only
select as_('01');
select throws_ok(format('select * from public.get_invite_link(%L)', g('GD')), '42501', null, 'get: 1:1 chat is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('GD')), '42501', null, 'reset: 1:1 chat is refused');
reset role;

-- 10. System chat (role 01) – get and reset only
select as_('01');
select throws_ok(format('select * from public.get_invite_link(%L)', g('GS')), '42501', null, 'get: admin chat is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('GS')), '42501', null, 'reset: admin chat is refused');
reset role;
select as_('01');
select throws_ok(format('select * from public.get_invite_link(%L)', g('GT')), '42501', null, 'get: staff chat is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('GT')), '42501', null, 'reset: staff chat is refused');
reset role;
select as_('01');
select throws_ok(format('select * from public.get_invite_link(%L)', g('GB')), '42501', null, 'get: debug chat is refused');
select throws_ok(format('select * from public.reset_invite_link(%L, null)', g('GB')), '42501', null, 'reset: debug chat is refused');
reset role;
-- reset
reset role;
create temp table t1(token text, created_at timestamptz, expires_at timestamptz, limit_days int);
grant all on t1 to authenticated;
select as_('01');
select is((select count(*)::int from public.get_invite_link(g('G1'))), 0, 'no link before the first reset');                       -- test 1
insert into t1 select * from public.reset_invite_link(g('G1'), 7);
select is((select count(*)::int from t1), 1, 'reset returns exactly one row');                                                  -- 2
select ok((select token ~ '^[A-Za-z0-9_-]{24}$' from t1), 'token has 24 url-safe chars');                                       -- 3
select ok((select abs(extract(epoch from expires_at - (now() + interval '7 days'))) < 60 from t1), 'valid 7 days expires in 7 days'); -- 4
select is((select token from public.get_invite_link(g('G1'))), (select token from t1), 'get returns the token reset made');      -- 5
select ok((select abs(extract(epoch from expires_at - (now() + interval '7 days'))) < 60 from public.get_invite_link(g('G1'))), 'get shows the same expiry'); -- 6
select ok((select abs(extract(epoch from expires_at - (now() + interval '1 day'))) < 60 from public.reset_invite_link(g('G1'), 1)), 'valid 1 day');   -- 7
select ok((select abs(extract(epoch from expires_at - (now() + interval '30 days'))) < 60 from public.reset_invite_link(g('G1'), 30)), 'valid 30 days'); -- 8
select ok((select expires_at is null from public.reset_invite_link(g('G1'), null)), 'null validity never expires');                -- 9
select throws_ok(format('select * from public.reset_invite_link(%L, %s)', g('G1'), 0), '22023', null, 'validity 0 is refused');   -- 10
select throws_ok(format('select * from public.reset_invite_link(%L, %s)', g('G1'), 2), '22023', null, 'validity 2 is refused');   -- 11
select throws_ok(format('select * from public.reset_invite_link(%L, %s)', g('G1'), -1), '22023', null, 'validity -1 is refused'); -- 12
select throws_ok(format('select * from public.reset_invite_link(%L, %s)', g('G1'), 365), '22023', null, 'validity 365 is refused'); -- 13
select ok((select token ~ '^[A-Za-z0-9_-]{24}$' from public.get_invite_link(g('G1'))), 'a stored token keeps the 24 char shape'); -- 14
reset role;
-- lifecycle
reset role;
create temp table t2(token text);
grant all on t2 to authenticated;
select as_('01');
insert into t2 select token from public.reset_invite_link(g('G1'), 7);
select isnt((select token from t2), (select token from t1), 'a new reset gives a different token');            -- 1
select is((select count(*)::int from public.get_invite_link(g('G1'))), 1, 'get returns one row after a reset');  -- 2
select is((select token from public.get_invite_link(g('G1'))), (select token from t2), 'get returns only the newest token'); -- 3
reset role;
select is((select count(*)::int from app_private.group_invite_links where conversation_id = g('G1')), 1, 'one link row per group'); -- 4
select as_('01');
select lives_ok(format('select public.turn_off_invite_link(%L)', g('G1')), 'admin turns the link off');         -- 5
select is((select count(*)::int from public.get_invite_link(g('G1'))), 0, 'no link after turn off');           -- 6
select lives_ok(format('select public.turn_off_invite_link(%L)', g('G1')), 'turning off twice does not raise');   -- 7
reset role;
select is((select count(*)::int from app_private.group_invite_links where conversation_id = g('G1')), 0, 'link row deleted'); -- 8
select as_('01');
select * from public.reset_invite_link(g('G1'), null);
reset role;
create temp table t3 as select token from app_private.group_invite_links where conversation_id = g('G1');
grant all on t3 to authenticated;
update public.conversation_members set role = 'member' where conversation_id = g('G1') and user_id = u('01');
update public.conversation_members set role = 'admin' where conversation_id = g('G1') and user_id = u('02');
select as_('02');
select is((select token from public.get_invite_link(g('G1'))), (select token from t3), 'the link survives an admin change');  -- 9
reset role;
select as_('01');
select throws_ok(format('select * from public.get_invite_link(%L)', g('G1')), '42501', null, 'the old admin, now a member, is refused'); -- 10
reset role;
select as_('01');
select * from public.reset_invite_link(g('GM'), null);
reset role;
delete from public.conversation_members where conversation_id = g('GM');
delete from public.conversations where id = g('GM');
select ok(not exists (select 1 from app_private.group_invite_links where conversation_id = g('GM')), 'the link goes with the group'); -- 11

select * from finish();
rollback;
