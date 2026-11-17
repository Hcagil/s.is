begin;
select plan(11);

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

select grp('R1','ig-1'); select mem('R1','01','admin',9);
select commit_check();
create temp table rt(token text);
grant all on rt to authenticated;
select as_('01');
insert into rt select token from public.reset_invite_link(g('R1'), null);
reset role;
select as_('04');
do $$ begin for i in 1..20 loop begin perform public.join_by_link(repeat('z', 24)); exception when others then null; end; end loop; end $$;
reset role;
select is((select count(*)::int from app_private.invite_link_attempts where user_id = u('04')), 20, 'twenty wrong-token joins leave twenty attempt rows');
select as_('04');
select throws_ok(format('select public.join_by_link(%L)', repeat('z', 24)), 'RLMT1', null, 'the 21st wrong-token join is limited');
select throws_ok(format('select * from public.preview_invite_link(%L)', (select token from rt)), 'RLMT1', null, 'a right-token preview is limited after 20 wrong guesses');
select throws_ok(format('select public.join_by_link(%L)', (select token from rt)), 'RLMT1', null, 'a right-token join is limited after 20 wrong guesses');
reset role;
select is((select count(*)::int from public.conversation_members where conversation_id = g('R1') and user_id = u('04')), 0, 'the limited person did not join');
select as_('03');
do $$ begin for i in 1..10 loop begin perform public.join_by_link(repeat('y', 24)); exception when others then null; end; end loop; end $$;
do $$ begin for i in 1..10 loop begin perform * from public.preview_invite_link(repeat('x', 24)); exception when others then null; end; end loop; end $$;
reset role;
select is((select count(*)::int from app_private.invite_link_attempts where user_id = u('03')), 20, 'ten wrong joins and ten wrong previews share one count');
select as_('03');
select throws_ok(format('select * from public.preview_invite_link(%L)', repeat('x', 24)), 'RLMT1', null, 'a wrong preview is limited after the shared 20');
select throws_ok(format('select public.join_by_link(%L)', repeat('y', 24)), 'RLMT1', null, 'a wrong join is limited after the shared 20');
reset role;
select as_('02');
select lives_ok(format('select * from public.preview_invite_link(%L)', (select token from rt)), 'another person is not limited');
select throws_ok(format('select public.join_by_link(%L)', repeat('z', 24)), 'LINK1', null, 'another person still gets LINK1 for a wrong token');
reset role;
update app_private.invite_link_attempts set called_at = called_at - interval '11 minutes' where user_id = u('04');
select as_('04');
select throws_ok(format('select public.join_by_link(%L)', repeat('z', 24)), 'LINK1', null, 'attempts older than ten minutes no longer count');
reset role;
select * from finish();
rollback;
