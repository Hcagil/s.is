-- promote_on_member_deleted() (migration 20261115120000): when the last human
-- admin's account is deleted from a titled group, the oldest current HUMAN
-- member (joined_at, then user_id) becomes admin. A bot is never promoted;
-- only bots left => nobody is. Another admin left, or an untitled chat => no
-- change. Written from the contract, not the body.
--   a, c humans (admins)  h, i humans (members)  b bot (oldest member)
begin;
select plan(14);

create function u(n text) returns uuid language sql immutable as $$
  select ('ab0000' || n || '-0000-0000-0000-000000000000')::uuid $$;
create function g(n text) returns uuid language sql immutable as $$
  select ('ab000000-0000-0000-0000-0000000000' || n)::uuid $$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), 'ap-' || n || '@sis.test', now(), '{"full_name":"Ap"}'::jsonb
  from unnest(array['01','02','03','04','05']) n;  -- 01 a, 02 c, 03 h, 04 i, 05 b
insert into public.conversations(id, title) values (g('06'), 'ap debug');

-- members built directly (the admin guard is deferred and off for setup)
alter table public.conversation_members disable trigger conversation_members_admin_guard;
create function mem(c text, who text, r text, age interval) returns void language sql as $$
  insert into public.conversation_members(conversation_id, user_id, role, joined_at)
  values (g(c), u(who), r, now() - age) $$;
-- G1 bot is oldest, humans later
insert into public.conversations(id, title) values (g('01'), 'ap one');
select mem('01','01','admin','10 hours'), mem('01','05','member','9 hours'),
       mem('01','03','member','8 hours'), mem('01','04','member','7 hours');
-- G2 only a bot besides the admin
insert into public.conversations(id, title) values (g('02'), 'ap two');
select mem('02','01','admin','10 hours'), mem('02','05','member','9 hours');
-- G3 another admin remains
insert into public.conversations(id, title) values (g('03'), 'ap three');
select mem('03','01','admin','10 hours'), mem('03','02','admin','9 hours'), mem('03','03','member','8 hours');
-- G4 untitled chat
insert into public.conversations(id, title) values (g('04'), null);
select mem('04','01','admin','10 hours'), mem('04','03','member','9 hours');
-- G5 humans joined at the same instant: lower user_id wins
insert into public.conversations(id, title) values (g('05'), 'ap five');
select mem('05','01','admin','10 hours'), mem('05','04','member','5 hours'), mem('05','03','member','5 hours');
update public.conversation_members set joined_at = (select joined_at from public.conversation_members where conversation_id = g('05') and user_id = u('03'))
 where conversation_id = g('05') and user_id = u('04');
alter table public.conversation_members enable trigger conversation_members_admin_guard;
-- registered last: a bot guard refuses bot members inserted afterwards
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('05'), g('06'));

create function role_of(c text, who text) returns text language sql as $$
  select role from public.conversation_members where conversation_id = g(c) and user_id = u(who) and left_at is null $$;
create function admins(c text) returns int language sql as $$
  select count(*)::int from public.conversation_members where conversation_id = g(c) and left_at is null and role = 'admin' $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;

delete from auth.users where id = u('01');

select is(role_of('01','03'), 'admin', 'G1: oldest human (h) is promoted past the older bot');
select is(role_of('01','05'), 'member', 'G1: the bot stays a member');
select is(role_of('01','04'), 'member', 'G1: the younger human is not promoted');
select is(admins('01'), 1, 'G1: exactly one admin');
select lives_ok('select commit_check()', 'G1: the deferred admin guard is satisfied at commit');

select is(role_of('02','05'), 'member', 'G2: only a bot left, the bot is not promoted');
select is(admins('02'), 0, 'G2: nobody is promoted, the group has no admin');
-- Reported, not decided: what the deferred guard does for a bot-only group.
select lives_ok('select commit_check()', 'G2: guard result at commit with only a bot left (see report)');

select is(role_of('03','02'), 'admin', 'G3: the other admin stays');
select is(role_of('03','03'), 'member', 'G3: no one else is promoted');
select is(admins('03'), 1, 'G3: still one admin');

select is(role_of('04','03'), 'member', 'G4: untitled chat, no promotion');
select is(admins('04'), 0, 'G4: untitled chat has no admin added');

select is(role_of('05','03'), 'admin', 'G5: tie on joined_at, the lower user_id is promoted');

select * from finish();
rollback;
