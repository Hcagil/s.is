begin;
select plan(14);

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
select grp('L1','il-1'); select mem('L1','01','admin',9); select mem('L1','02','member',9);
select grp('L2','il-2'); select mem('L2','01','admin',9);
update public.conversations set new_members_see_history = true where id = g('L1');
update public.conversations set new_members_see_history = false where id = g('L2');
select commit_check();
create temp table t1(token text, created_at timestamptz, expires_at timestamptz, limit_days int);
grant all on t1 to authenticated;

-- 1. Switch to admin 01 and create first invite link for L1
reset role;
select as_('01');
insert into t1 select * from public.reset_invite_link(g('L1'), 7);

-- 2. Verify limit_days is 7
select is((select limit_days from t1), 7, 'limit_days of t1 = 7');

-- 3. Test reset_invite_link with various valid_days
select is((select limit_days from public.reset_invite_link(g('L1'), 1)), 1, 'reset_invite_link with 1 day');
select is((select limit_days from public.reset_invite_link(g('L1'), 30)), 30, 'reset_invite_link with 30 days');
select is((select limit_days from public.reset_invite_link(g('L1'), null)), null, 'reset_invite_link with null days');

-- 4. Delete previous link, create new one, then extend expiry
delete from t1;
insert into t1 select * from public.reset_invite_link(g('L1'), 7);

-- Create temp table for set_invite_link_expiry result
create temp table t3(token text, created_at timestamptz, expires_at timestamptz, limit_days int);
grant all on t3 to authenticated;
insert into t3 select * from public.set_invite_link_expiry(g('L1'), 30);

-- Assertions: token and created_at unchanged, limit_days updated to 30
select is((select token from t3), (select token from t1), 'token unchanged after expiry update');
select is((select created_at from t3), (select created_at from t1), 'created_at unchanged after expiry update');
select is((select limit_days from t3), 30, 'limit_days updated to 30');

-- 5. Verify get_invite_link returns updated limit_days
select is((select limit_days from public.get_invite_link(g('L1'))), 30, 'get_invite_link returns 30 days');

-- Set to null and verify
select public.set_invite_link_expiry(g('L1'), null);
select is((select limit_days from public.get_invite_link(g('L1'))), null, 'get_invite_link returns null days');

-- 6. Prepare token for preview by plain member
reset role;
select as_('01');
create temp table tk(token text);
grant all on tk to authenticated;
insert into tk select token from public.get_invite_link(g('L1'));

reset role;
select as_('02');
select is((select new_members_see_history from public.preview_invite_link((select token from tk))), true, 'preview_invite_link for L1 returns true');

-- 7. Group L2 preview by plain member
reset role;
select as_('01');
create temp table tk2(token text);
grant all on tk2 to authenticated;
insert into tk2 select token from public.reset_invite_link(g('L2'), null);

reset role;
select as_('02');
select is((select new_members_see_history from public.preview_invite_link((select token from tk2))), false, 'preview_invite_link for L2 returns false');
select is((select error from public.preview_invite_link((select token from tk2))), null, 'preview success row has no error');

-- 8. Refusal case with unknown token
select is((select new_members_see_history from public.preview_invite_link(repeat('z',24))), null, 'unknown token returns null new_members_see_history');
select is((select error from public.preview_invite_link(repeat('z',24))), 'LINK1', 'unknown token returns LINK1 error');
select * from finish();
