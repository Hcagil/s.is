begin;
select plan(69);

-- Location messages: public.send_location and messages.location_lat/lng
-- (20261015120000_location_messages.sql). Written from the contract, not from
-- the migration:
--   send_location(p_conversation, p_id, p_lat, p_lng, p_name, p_address),
--   security definer, stores p_id with body name, or name || E'\n' ||
--   address, and the coordinates in their own columns. 42501 for no app
--   access, the bot, a non-member and the system chat; 22023 for a bad name
--   (1..80), address (..200), coordinates (range, NaN, infinity, null) or id.
--   The same id again by the same sender is OK; any other reuse is 23505.
--   Body and coordinates are frozen; deleting nulls the coordinates; no
--   client writes them directly. conversation_previews ends with location_lat.
--
-- Each negative fixture fails ONE gate; ann's valid call is the control.
--   ann  creator (admin) of G, sends     bob  member of G
--   cat  never a member of G             bot  the SIS bot, a member of G
--   dan  member of G, session revoked (no app access)
--   SYS  ann's system chat (she is its member; only the system rule refuses)

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000000dd1' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@location.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan')) v(n, name);
insert into app_private.allowlist(email)
select name || '@location.test' from unnest(array['ann','bob','cat','dan']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('dd100000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
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
                         else 'dd100000-0000-0000-0000-0000000000' || n end)::text, true);
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
insert into ids values ('G', group_c('Locations', array[u('02'), u('04')]));
insert into ids values ('TXT', msg(g('G'), 'plain text'));
insert into ids values ('G2', group_c('Other', array[u('02')]));
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
create function rows_of(id uuid) returns bigint language sql stable security definer as $$
  select count(*) from public.messages where messages.id = rows_of.id
$$;
grant execute on function rows_of(uuid) to authenticated, anon;

select ok(g('SYS') is not null, 'fixture: ann has a system chat');
select ok(app_private.is_bot(u('bot')), 'fixture: the bot is a bot');

insert into ids values
  ('L1', 'dd1a0000-0000-0000-0000-000000000001'),  -- ann's location in G
  ('L2', 'dd1a0000-0000-0000-0000-000000000002'),  -- ann deletes it
  ('LX', 'dd1a0000-0000-0000-0000-000000000003'),  -- spare id for refusals
  ('LB', 'dd1a0000-0000-0000-0000-000000000004'),  -- bob's, the admin deletes it
  ('LD', 'dd1a0000-0000-0000-0000-000000000005'),  -- in the 1:1 chat
  ('LP', 'dd1a0000-0000-0000-0000-000000000006');  -- no address; deleted by a bypass

create function sl(c uuid, id uuid, la float8, ln float8, n text, a text) returns text language sql as $$
  select try(format($q$select public.send_location(%L, %L, %L::float8, %L::float8, %L, %L)$q$, c, id, la, ln, n, a))
$$;
grant execute on function sl(uuid, uuid, float8, float8, text, text) to authenticated, anon;
create function direct_c(o uuid) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_direct_conversation(o); perform commit_check(); return r; end $$;
grant execute on function direct_c(uuid) to authenticated;
create function ll(id uuid) returns text language sql stable security definer as $$
  select format('%s,%s', location_lat, location_lng) from public.messages where messages.id = ll.id
$$;
grant execute on function ll(uuid) to authenticated, anon;

-- 1 the control -----------------------------------------------------------------
select as_('01');
select is(sl(g('G'), g('L1'), 41.0, 29.0, 'Kadikoy', 'Iskele Sk. 1'), 'ok', 'ann sends a location to her group');
select is(sl(g('G'), g('LP'), 41.5, 29.5, 'Pier', ''), 'ok', 'and one without an address');
reset role;
select is((select body from public.messages where id = g('L1')), E'Kadikoy\nIskele Sk. 1', 'the body is name, line break, address');
select is(ll(g('L1')), '41,29', 'the coordinates are stored in their columns');
select is((select sender_id from public.messages where id = g('L1')), u('01'), 'sent as the caller');
select is((select body from public.messages where id = g('LP')), 'Pier', 'no address: the body is the name alone');

-- 2 who may send (valid input, only the gate under test differs) ---------------
select runbook();
set local role anon;
select is(sl(g('G'), g('LX'), 1, 2, 'X', ''), '42501', 'anon has no access');
reset role;
select as_('03');
select is(sl(g('G'), g('LX'), 1, 2, 'X', ''), '42501', 'a non-member is refused');
reset role;
select as_('bot');
select is(sl(g('G'), g('LX'), 1, 2, 'X', ''), '42501', 'the bot is refused, though a member of G');
reset role;
select as_('01');
select is(sl(g('SYS'), g('LX'), 1, 2, 'X', ''), '42501', 'nobody sends into the system chat');
reset role;
delete from auth.sessions where id = 'dd100000-0000-0000-0000-000000000004';
select as_('04');
select is(sl(g('G'), g('LX'), 1, 2, 'X', ''), '42501', 'a member whose session was revoked is refused');
reset role;
select is(rows_of(g('LX')), 0::bigint, 'no refused call stored a row');

-- 3 bad input, as ann in G --------------------------------------------------------
select as_('01');
select is(sl(g('G'), g('LX'), 1, 2, '', ''), '22023', 'an empty name');
select is(sl(g('G'), g('LX'), 1, 2, '   ', ''), '22023', 'a name of only spaces');
select is(sl(g('G'), g('LX'), 1, 2, repeat('a', 81), ''), '22023', 'an 81-character name');
select is(sl(g('G'), g('LX'), 1, 2, 'X', repeat('b', 201)), '22023', 'a 201-character address');
select is(sl(g('G'), g('LX'), 1, 2, E'A\nB', ''), '22023', 'a line break in the name');
select is(sl(g('G'), g('LX'), 1, 2, 'X', E'x\ty'), '22023', 'a tab in the address');
select is(sl(g('G'), g('LX'), 90.000001, 2, 'X', ''), '22023', 'latitude above 90');
select is(sl(g('G'), g('LX'), -90.000001, 2, 'X', ''), '22023', 'latitude below -90');
select is(sl(g('G'), g('LX'), 1, 180.000001, 'X', ''), '22023', 'longitude above 180');
select is(sl(g('G'), g('LX'), 1, -180.000001, 'X', ''), '22023', 'longitude below -180');
select is(sl(g('G'), g('LX'), 'NaN'::float8, 2, 'X', ''), '22023', 'a NaN latitude');
select is(sl(g('G'), g('LX'), 1, 'NaN'::float8, 'X', ''), '22023', 'a NaN longitude');
select is(sl(g('G'), g('LX'), 1, 'Infinity'::float8, 'X', ''), '22023', 'an infinite longitude');
select is(sl(g('G'), g('LX'), '-Infinity'::float8, 2, 'X', ''), '22023', 'a minus-infinite latitude');
select is(sl(g('G'), g('LX'), null, 2, 'X', ''), '22023', 'no latitude');
select is(sl(g('G'), g('LX'), 1, null, 'X', ''), '22023', 'no longitude');
select is(sl(g('G'), null, 1, 2, 'X', ''), '22023', 'no message id');
reset role;
select is(rows_of(g('LX')), 0::bigint, 'no bad input stored a row');
select as_('01');
select is(sl(g('G'), gen_random_uuid(), 1, 2, repeat('a', 80), repeat('b', 200)), 'ok', 'the limits pass (80, 200)');
select is(sl(g('G'), gen_random_uuid(), 90, 180, 'X', ''), 'ok', 'latitude 90, longitude 180 pass');
select is(sl(g('G'), gen_random_uuid(), -90, -180, 'X', ''), 'ok', 'latitude -90, longitude -180 pass');

-- 4 retry and foreign ids -------------------------------------------------------
select is(sl(g('G'), g('L1'), 41.0, 29.0, 'Kadikoy', 'Iskele Sk. 1'), 'ok', 'the same id again by the same sender is a harmless retry');
reset role;
select is(rows_of(g('L1')), 1::bigint, 'and leaves one row');
select as_('02');
select is(sl(g('G'), g('L1'), 41.0, 29.0, 'Kadikoy', 'Iskele Sk. 1'), '23505', 'another member reusing the id is a conflict');
select is(sl(g('G'), g('TXT'), 41.0, 29.0, 'Kadikoy', ''), '23505', 'an id of an existing text message is a conflict');
reset role;
select is(ll(g('TXT')), ',', 'the text message has no coordinates');
select as_('01');
select is(sl(g('G'), g('TXT'), 41.0, 29.0, 'Kadikoy', ''), '23505', 'the sender reusing her own text message id is a conflict');
select is(sl(g('G2'), g('L1'), 41.0, 29.0, 'Kadikoy', 'Iskele Sk. 1'), '23505', 'the same sender and id in another conversation is a conflict');
reset role;

-- 5 frozen body and coordinates -------------------------------------------------
select as_('01');
select is(try(format($q$select public.edit_message(%L, 'x')$q$, g('L1'))), '42501', 'edit_message refuses a location');
reset role;
select try(format($q$update public.messages set body = 'changed' where id = %L$q$, g('L1')));
select is((select body from public.messages where id = g('L1')), E'Kadikoy\nIskele Sk. 1', 'the body does not change, even for the owner role');
select try(format($q$update public.messages set location_lat = 1, location_lng = 1 where id = %L$q$, g('LP')));
select is(ll(g('LP')), '41.5,29.5', 'the coordinates do not change, even for the owner role');
select is(try(format($q$update public.messages set body = 'edited text' where id = %L$q$, g('TXT'))), 'ok',
          'a text message''s body can (control)');

-- 6 no client writes the coordinates; the range check -----------------------------
select as_('01');
select isnt(try(format($q$insert into public.messages(conversation_id, sender_id, body, location_lat, location_lng) values (%L, %L, 'X', 1, 1)$q$,
                g('G'), u('01'))), 'ok', 'a direct insert with coordinates is refused');
select is(try(format($q$insert into public.messages(conversation_id, sender_id, body) values (%L, %L, 'X')$q$,
                g('G'), u('01'))), 'ok', 'the same insert without them works (control)');
select try(format($q$update public.messages set location_lat = 2 where id = %L$q$, g('L1')));
reset role;
select is(ll(g('L1')), '41,29', 'the sender cannot move her location directly');
select isnt(try(format($q$insert into public.messages(conversation_id, sender_id, body, location_lat, location_lng) values (%L, %L, 'X', 91, 0)$q$,
                g('G'), u('01'))), 'ok', 'a latitude out of range is refused by the table');
select isnt(try(format($q$insert into public.messages(conversation_id, sender_id, body, location_lat, location_lng) values (%L, %L, 'X', 10, null)$q$,
                g('G'), u('01'))), 'ok', 'a latitude without a longitude is refused by the table');

-- 7 the coordinates go on delete -----------------------------------------------
select as_('01');
select is(sl(g('G'), g('L2'), 1, 2, 'Del', ''), 'ok', 'fixture: a location to delete');
select is(try(format($q$select public.delete_message(%L)$q$, g('L2'))), 'ok', 'the sender deletes it for everyone');
reset role;
select is((select deleted from public.messages where id = g('L2')), 'placeholder', 'it is a placeholder now');
select is(ll(g('L2')), ',', 'and its coordinates are gone');
select as_('02');
select is(sl(g('G'), g('LB'), 3, 4, 'Bob place', ''), 'ok', 'fixture: bob''s location');
reset role;
select as_('01');
select is(try(format($q$select public.delete_message(%L)$q$, g('LB'))), 'ok', 'ann, the admin, deletes bob''s location');
reset role;
select is(ll(g('LB')), ',', 'its coordinates are gone too');
update public.messages set deleted = 'placeholder', deleted_at = now(), body = '' where id = g('LP');
select is(ll(g('LP')), ',', 'any path that marks a location deleted drops its coordinates');
select as_('01');
select is(sl(g('G'), g('L2'), 1, 2, 'Del', ''), '23505', 'retrying a deleted location''s id is a conflict, not a resurrection');
reset role;

-- 8 a 1:1 chat ---------------------------------------------------------------------
select as_('01');
insert into ids values ('D', direct_c(u('02')));
select is(sl(g('D'), g('LD'), 10, 20, 'Here', ''), 'ok', 'ann sends a location in a 1:1 chat');
reset role;
select as_('02');
select is((select format('%s|%s,%s', body, location_lat, location_lng) from public.messages where id = g('LD')),
          'Here|10,20', 'bob reads it with its coordinates');
select is((select format('%s|%s,%s', body, location_lat, location_lng) from public.messages where id = g('L1')),
          E'Kadikoy\nIskele Sk. 1|41,29', 'and reads ann''s group location too');
reset role;
select as_('03');
select is((select count(*) from public.messages where id = g('LD')), 0::bigint, 'an outsider does not');
reset role;

-- 9 conversation_previews ---------------------------------------------------------
select is((select attname::text from pg_attribute
            where attrelid = 'public.conversation_previews'::regclass and attnum > 0 and not attisdropped
            order by attnum desc limit 1), 'location_lat', 'conversation_previews ends with location_lat');
update public.messages set created_at = created_at - interval '1 minute' where conversation_id = g('G');
select as_('01');
select is(sl(g('G'), gen_random_uuid(), 41.25, 29.0, 'Newest', ''), 'ok', 'fixture: a location as the newest message');
select is((select location_lat from public.conversation_previews where conversation_id = g('G')), 41.25::float8,
          'the preview carries the newest message''s latitude');
reset role;
insert into public.messages(conversation_id, sender_id, body, created_at)
values (g('G'), u('01'), 'after the location', now() + interval '1 second');
select as_('01');
select is((select location_lat from public.conversation_previews where conversation_id = g('G')), null::float8,
          'a newer text message has none');
reset role;

select * from finish();
rollback;
