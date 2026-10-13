-- Pinned chats: public.chat_pins, its policies, the before-insert trigger
-- chat_pins_limit (foreign user_id, archived chat, 5 pins) and the
-- chat_archives_unpin trigger.
--
-- ana (1) is the subject; ben (2) shares G1..G7 with her; cem (3) only with ben.
-- Each refused insert fails exactly ONE gate:
--   foreign user_id: ben IS in the chat, so only the user_id gate refuses;
--   never a member:  ana's own id, a chat not archived, under the limit;
--   archived:        ana is a member, own id, 4 pins;
--   limit:           ana is a member, own id, chat not archived.
begin;
select plan(39);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000cb001', 'cb-ana@example.com', now(), '{"full_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000cb002', 'cb-ben@example.com', now(), '{"full_name":"Ben"}'),
  ('00000000-0000-0000-0000-0000000cb003', 'cb-cem@example.com', now(), '{"full_name":"Cem"}');
insert into app_private.allowlist(email) values
  ('cb-ana@example.com'), ('cb-ben@example.com'), ('cb-cem@example.com');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000cb002'),
  ('00000000-0000-0000-0000-0000000cb002', '00000000-0000-0000-0000-0000000cb001'),
  ('00000000-0000-0000-0000-0000000cb002', '00000000-0000-0000-0000-0000000cb003');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('cb000000-0000-0000-0000-0000000cb00' || n)::uuid,
         ('00000000-0000-0000-0000-0000000cb00' || n)::uuid, now(), now()
    from generate_series(1, 3) n;

create or replace function test_as(n int) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-0000000cb00' || n)::uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', 'cb000000-0000-0000-0000-0000000cb00' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000cb00' || n)::uuid $$;
grant execute on function u(int) to authenticated;

select test_as(1); select ok(public.activate_session(), 'ana is active'); reset role;
select test_as(2); select ok(public.activate_session(), 'ben is active'); reset role;
select test_as(3); select ok(public.activate_session(), 'cem is active'); reset role;

create temp table _c (k text, id uuid);
grant select, insert on _c to authenticated;
select test_as(1);
insert into _c select 'G' || n, public.start_group_conversation('cb g' || n, array[u(2)])
  from generate_series(1, 7) n;
reset role;
select test_as(2);
insert into _c select 'D_BC', public.start_direct_conversation(u(3));
insert into _c select 'GX', public.start_group_conversation('cb gx', array[u(1), u(3)]);
reset role;
create function c(k text) returns uuid language sql as $$ select id from _c where _c.k = $1 $$;
grant execute on function c(text) to authenticated;
-- ana is a FORMER member of GX.
update public.conversation_members set left_at = now(), left_reason = 'left'
 where conversation_id = c('GX') and user_id = u(1);

create function pin(who int, k text) returns text language sql as $$
  select format('insert into public.chat_pins(user_id, conversation_id) values (%L, %L)', u(who), c(k)) $$;
create function pins_of(who int) returns int language sql as $$
  select count(*)::int from public.chat_pins where user_id = u(who) $$;
create function pinned(who int, k text) returns boolean language sql as $$
  select exists(select 1 from public.chat_pins where user_id = u(who) and conversation_id = c(k)) $$;
grant execute on function pin(int, text) to authenticated;

-- 1 shape and privileges ------------------------------------------------------
select has_table('public', 'chat_pins', 'chat_pins exists');
select col_is_pk('public', 'chat_pins', array['user_id', 'conversation_id'], 'one row per member per chat');
select ok((select relrowsecurity from pg_class where oid = 'public.chat_pins'::regclass), 'RLS is on');
select table_privs_are('public', 'chat_pins', 'authenticated', array['DELETE', 'INSERT', 'SELECT'],
                       'authenticated: select, insert, delete only');
select table_privs_are('public', 'chat_pins', 'anon', '{}'::text[], 'anon: nothing');

-- 2 own rows only ---------------------------------------------------------------
select test_as(1);
select lives_ok(format('insert into public.chat_pins(conversation_id) values (%L)', c('G1')),
                'ana pins G1 without naming herself');
reset role;
select is((select user_id from public.chat_pins where conversation_id = c('G1')), u(1), 'user_id defaults to the caller');
select test_as(2);
select lives_ok(pin(2, 'G1'), 'ben pins G1 too');
select is((select count(*)::int from public.chat_pins), 1, 'ben sees only his own pin');
reset role;
select test_as(1);
select is((select count(*)::int from public.chat_pins), 1, 'ana sees only her own pin');
delete from public.chat_pins where user_id = u(2);
reset role;
select ok(pinned(2, 'G1'), 'ana''s delete removed nothing of ben''s');
select test_as(3);
delete from public.chat_pins;  -- no WHERE: only the delete policy decides
reset role;
select is(pins_of(1) + pins_of(2), 2, 'cem''s unqualified delete removed nobody else''s pins');

-- 3 a foreign user_id: the plain refusal, whatever the victim's state -----------
select test_as(1);
select throws_ok(pin(2, 'G2'), '42501', 'not permitted', 'ana cannot pin G2 for ben, though ben is in G2');
reset role;
select test_as(2);
select lives_ok(pin(2, 'G2'), 'ben pins G2');
select lives_ok(pin(2, 'G3'), 'ben pins G3');
select lives_ok(pin(2, 'G4'), 'ben pins G4');
select lives_ok(pin(2, 'G5'), 'ben pins G5 (his 5th)');
reset role;
select test_as(1);
select throws_ok(pin(2, 'G6'), '42501', 'not permitted',
                 'ben at 5 pins: ana still gets the plain refusal, not the pin limit');
reset role;
select test_as(2);
insert into public.chat_archives(conversation_id) values (c('G7'));
reset role;
select test_as(1);
select throws_ok(pin(2, 'G7'), '42501', 'not permitted',
                 'ben archived G7: ana still gets the plain refusal, not "archived chat"');
reset role;

-- 4 was_member ------------------------------------------------------------------
select test_as(1);
select throws_ok(pin(1, 'D_BC'), '42501', null, 'ana cannot pin D_BC, a chat she never belonged to');
select lives_ok(pin(1, 'GX'), 'ana, who left GX, may still pin it');
delete from public.chat_pins where conversation_id = c('GX');
reset role;
select is(pins_of(1), 1, 'ana is back to one pin (G1)');

-- 5 the limit -------------------------------------------------------------------
select test_as(1);
select lives_ok(pin(1, 'G2'), 'ana pins G2');
select lives_ok(pin(1, 'G3'), 'ana pins G3');
select lives_ok(pin(1, 'G4'), 'ana pins G4');
select lives_ok(pin(1, 'G5'), 'ana pins G5: the 5th is allowed');
select throws_ok(pin(1, 'G6'), '54000', 'pin limit', 'the 6th pin is refused');
select lives_ok(pin(1, 'G1') || ' on conflict do nothing', 're-pinning G1 at 5 pins does not trip the limit');
reset role;
select is(pins_of(1), 5, 'ana still has 5 pins');
select test_as(1);
delete from public.chat_pins where conversation_id = c('G5');
select lives_ok(pin(1, 'G6'), 'after unpinning G5 ana may pin G6');
delete from public.chat_pins where conversation_id = c('G6');
reset role;
select is(pins_of(1), 4, 'ana has 4 pins');

-- 6 an archived chat cannot be pinned -------------------------------------------
select test_as(1);
insert into public.chat_archives(conversation_id) values (c('G7'));
select throws_ok(pin(1, 'G7'), '42501', 'archived chat', 'ana cannot pin G7, which she archived');
reset role;

-- 7 archiving unpins, unarchiving does not re-pin --------------------------------
select test_as(1);
insert into public.chat_archives(conversation_id) values (c('G1'));
reset role;
select ok(not pinned(1, 'G1'), 'archiving G1 removed ana''s pin');
select ok(pinned(2, 'G1'), 'ben''s pin of G1 stays');
select ok(pinned(1, 'G2'), 'ana''s other pins stay');
select test_as(1);
delete from public.chat_archives where conversation_id = c('G1');
reset role;
select ok(not pinned(1, 'G1'), 'unarchiving G1 does not re-pin it');

select * from finish();
rollback;
