begin;
select plan(38);

-- Contact messages: public.send_contact and the messages.contact flag
-- (20261012120000_contact_messages.sql).
--
-- Written from the contract, not from the migration:
--   send_contact(p_conversation, p_id, p_name, p_phone) stores message p_id
--   with body name || E'\n' || phone and contact = true. 42501 for no access,
--   the bot, a non-member and the system chat; 22023 for bad input (name
--   1..80, number 3..32, no control characters). The same id again by the
--   same sender is OK; an id that is someone else's message is 23505. The
--   body is frozen (edit_message 42501), but delete-for-everyone works. A
--   direct insert with contact = true is refused. conversation_previews ends
--   with poll, contact.
--
-- Each negative fixture fails ONE gate; ann's valid call is the control.
--   ann  member of G, sends              bob  member of G
--   cat  never a member of G             bot  the SIS bot, a member of G
--   SYS  ann's system chat (she is its member; only the system rule refuses)

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000000cc1' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@contact.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan')) v(n, name);
insert into app_private.allowlist(email)
select name || '@contact.test' from unnest(array['ann','bob','cat','dan']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('cc100000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('01'), u('02')), (u('01'), u('03')), (u('01'), u('04'));

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'sis-destek-bot@example.com', now(), '{"full_name":"SIS Destek"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then 'b07b0000-0000-0000-0000-000000000001'
                         else 'cc100000-0000-0000-0000-0000000000' || n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function runbook() returns void language sql as $$
  select set_config('request.jwt.claims', '', true); select null::void
$$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function group_c(t text, ms uuid[]) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_group_conversation(t, ms); perform commit_check(); return r; end $$;
create function msg(c uuid, body text) returns uuid language sql as $$
  insert into public.messages(conversation_id, sender_id, body) values (c, auth.uid(), body) returning id
$$;
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate; end $$;
grant execute on function u(text), as_(text), commit_check(), group_c(text, uuid[]),
  msg(uuid, text), try(text) to authenticated, anon;

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('01');
insert into ids values ('G', group_c('Contacts', array[u('02'), u('04')]));
insert into ids values ('TXT', msg(g('G'), 'plain text'));
reset role;

-- the bot: a member of G (its Debug chat), so only the bot gate refuses it
select runbook();
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('G'));
insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing;
insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
values (g('G'), u('bot'), 'member', now() - interval '3 days', now() - interval '3 days');
update app_private.bot_accounts set enabled = true where user_id = u('bot');
select as_('bot');
select public.activate_session();
reset role;


select as_('01'); do $$ begin perform public.deliver_release_notes(179); end $$; reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;
insert into ids values
  ('C1', 'cc1a0000-0000-0000-0000-000000000001'),  -- ann's contact
  ('C2', 'cc1a0000-0000-0000-0000-000000000002'),  -- for delete
  ('CX', 'cc1a0000-0000-0000-0000-000000000003');  -- spare id for refusals

create function sc(c uuid, id uuid, n text, p text) returns text language sql as $$
  select try(format($q$select public.send_contact(%L, %L, %L, %L)$q$, c, id, n, p))
$$;
grant execute on function sc(uuid, uuid, text, text) to authenticated, anon;
create function rows_of(id uuid) returns bigint language sql stable security definer as $$
  select count(*) from public.messages where messages.id = rows_of.id
$$;
grant execute on function rows_of(uuid) to authenticated, anon;

select ok(g('SYS') is not null, 'fixture: ann has a system chat');
select ok(app_private.is_bot(u('bot')), 'fixture: the bot is a bot');

-- 1 the control -----------------------------------------------------------------
select as_('01');
select is(sc(g('G'), g('C1'), 'Ann Lee', '+90 555'), 'ok', 'ann sends a contact to her group');
reset role;
select is((select body from public.messages where id = g('C1')), E'Ann Lee\n+90 555', 'the body is name, line break, number');
select is((select contact from public.messages where id = g('C1')), true, 'the row is marked as a contact');
select is((select sender_id from public.messages where id = g('C1')), u('01'), 'sent as the caller');

-- 2 who may send ----------------------------------------------------------------
select runbook();
set local role anon;
select is(sc(g('G'), g('CX'), 'Ann', '123'), '42501', 'anon has no access');
reset role;
select as_('03');
select is(sc(g('G'), g('CX'), 'Ann', '123'), '42501', 'a non-member is refused');
reset role;
select as_('bot');
select is(sc(g('G'), g('CX'), 'Ann', '123'), '42501', 'the bot is refused, though a member of G');
reset role;
select as_('01');
select is(sc(g('SYS'), g('CX'), 'Ann', '123'), '42501', 'nobody sends into the system chat');
reset role;
select is(rows_of(g('CX')), 0::bigint, 'no refused call stored a row');

-- 3 bad input, as ann in G (every other gate passes) -------------------------
select as_('01');
select is(sc(g('G'), g('CX'), '', '123'), '22023', 'an empty name');
select is(sc(g('G'), g('CX'), repeat('a', 81), '123'), '22023', 'an 81-character name');
select is(sc(g('G'), g('CX'), 'Ann', '12'), '22023', 'a 2-character number');
select is(sc(g('G'), g('CX'), 'Ann', repeat('1', 33)), '22023', 'a 33-character number');
select is(sc(g('G'), g('CX'), E'Ann\nLee', '123'), '22023', 'a line break in the name');
select is(sc(g('G'), g('CX'), 'Ann', E'12\t3'), '22023', 'a tab in the number');
select is(rows_of(g('CX')), 0::bigint, 'no bad input stored a row');
select is(sc(g('G'), g('CX'), repeat('a', 80), repeat('1', 32)), 'ok', 'the limits themselves pass (80, 32)');
select is(sc(g('G'), gen_random_uuid(), 'A', '123'), 'ok', 'a 1-character name and 3-character number pass');

-- 4 retry and foreign ids -------------------------------------------------------
select is(sc(g('G'), g('C1'), 'Ann Lee', '+90 555'), 'ok', 'the same id again by the same sender is a harmless retry');
reset role;
select is(rows_of(g('C1')), 1::bigint, 'and leaves one row');
select as_('02');
select is(sc(g('G'), g('C1'), 'Ann Lee', '+90 555'), '23505', 'another member reusing the id is a conflict');
select is(sc(g('G'), g('TXT'), 'Ann Lee', '+90 555'), '23505', 'an id of an existing text message is a conflict');
reset role;
select is((select contact from public.messages where id = g('TXT')), false, 'the text message stays text');

-- 5 frozen body, delete for everyone, direct insert --------------------------
select as_('01');
select is(try(format($q$select public.edit_message(%L, 'x')$q$, g('C1'))), '42501', 'edit_message refuses a contact');
reset role;
select isnt(try(format($q$update public.messages set body = 'changed' where id = %L$q$, g('C1'))), 'ok',
            'a contact''s body cannot change, even for the owner role');
select is(try(format($q$update public.messages set body = 'edited text' where id = %L$q$, g('TXT'))), 'ok',
          'a text message''s body can (control)');
select is((select body from public.messages where id = g('C1')), E'Ann Lee\n+90 555', 'the body is unchanged');
select as_('01');
select is(sc(g('G'), g('C2'), 'Del Me', '123'), 'ok', 'fixture: a second contact');
select is(try(format($q$select public.delete_message(%L)$q$, g('C2'))), 'ok', 'the sender deletes it for everyone');
reset role;
select is((select deleted from public.messages where id = g('C2')), 'placeholder', 'it is a placeholder now');
select as_('01');
select isnt(try(format($q$insert into public.messages(conversation_id, sender_id, body, contact) values (%L, %L, E'Ann\n123', true)$q$,
                g('G'), u('01'))), 'ok', 'a direct insert with contact = true is refused');
select is(try(format($q$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'plain')$q$,
                g('G'), u('01'))), 'ok', 'the same insert without the flag works (control)');
reset role;

-- 6 conversation_previews ---------------------------------------------------------
select is((select array_agg(attname::text order by attnum) from (
             select attname, attnum from pg_attribute
              where attrelid = 'public.conversation_previews'::regclass
                and attnum > 0 and not attisdropped
              order by attnum desc limit 2) last_two),
          array['poll', 'contact'], 'conversation_previews ends with poll, contact');
select as_('01');
select is(sc(g('G'), gen_random_uuid(), 'Newest', '123'), 'ok', 'fixture: a contact as the newest message');
select is((select contact from public.conversation_previews where conversation_id = g('G')), true,
          'the preview marks the newest message as a contact');
reset role;
insert into public.messages(conversation_id, sender_id, body, created_at)
values (g('G'), u('01'), 'after the contact', now() + interval '1 second');
select as_('01');
select is((select contact from public.conversation_previews where conversation_id = g('G')), false,
          'a newer text message is not marked as a contact');
reset role;

select * from finish();
rollback;
