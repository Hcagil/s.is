begin;
select plan(9);

-- conversations.debug_chat: true only for the group a bot account points at (insert trigger),
-- readable by its members only, never writable by a signed-in user.

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000dc0' || n)::uuid $$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@dc.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','bot')) v(n, name);
insert into app_private.allowlist(email) select email from auth.users where id in (u('01'), u('02'), u('03'));
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('dc000000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03']) n;
create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'dc000000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on function as_(text), u(text) to authenticated;
do $$ declare n text; begin
  foreach n in array array['01','02'] loop perform as_(n); perform public.activate_session(); execute 'reset role'; end loop;
end $$;

insert into public.conversations(id, title) values
  ('dc000000-0000-0000-0000-00000000000a', 'dc-debug'), ('dc000000-0000-0000-0000-00000000000b', 'dc-plain');
insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from)
values ('dc000000-0000-0000-0000-00000000000a', u('01'), 'admin', now() - interval '1 hour', '-infinity'),
       ('dc000000-0000-0000-0000-00000000000b', u('01'), 'admin', now() - interval '1 hour', '-infinity');

select is((select debug_chat from public.conversations where id = 'dc000000-0000-0000-0000-00000000000a'), false, 'false before a bot points at it');
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('03'), 'dc000000-0000-0000-0000-00000000000a');
select is((select debug_chat from public.conversations where id = 'dc000000-0000-0000-0000-00000000000a'), true, 'the bot insert trigger marks its group');
select is((select debug_chat from public.conversations where id = 'dc000000-0000-0000-0000-00000000000b'), false, 'another group stays false');

select as_('01');
select is((select debug_chat from public.conversations where id = 'dc000000-0000-0000-0000-00000000000a'), true, 'a member reads true');
select is((select debug_chat from public.conversations where id = 'dc000000-0000-0000-0000-00000000000b'), false, 'a member reads false for a normal group');
select throws_ok($$update public.conversations set debug_chat = false where id = 'dc000000-0000-0000-0000-00000000000a'$$,
  '42501', null, 'authenticated cannot update debug_chat');
reset role;
select as_('02');
select is((select count(*)::int from public.conversations where id = 'dc000000-0000-0000-0000-00000000000a'), 0, 'a non-member sees 0 rows');
reset role;
select is((select debug_chat from public.conversations where id = 'dc000000-0000-0000-0000-00000000000a'), true, 'still true after the refused update');
set local role anon;
select throws_ok($$select debug_chat from public.conversations$$, '42501', null, 'anon cannot read');
reset role;

select * from finish();
rollback;
