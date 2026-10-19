begin;
select plan(19);

-- edit_message_encrypted checks live keys (20261101120000_encrypted_edit_live_keys.sql).
-- Contract: the edit is refused (42501) when ANY member of the chat whose
-- left_at is null has no live device (olm_devices bound to an active session
-- that still exists in auth.sessions); a refused edit leaves ciphertext and
-- edited_at as they were. A member who left (left_at set) does not block.
--
-- Every refused edit has a twin that succeeds and differs only in the gate
-- under test: the same caller, the same row, the same chat, before or after
-- one member's keys stop being live (or after that member leaves).
--   amy / ben  AB: ben's session ends
--   cid / dot  CD: dot's keys stop being live, then dot leaves
--   eli / fin  EF: eli (the caller) moves to a new phone without publishing

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000e5d000' || case n
    when 'amy' then '01' when 'ben' then '02' when 'cid' then '03'
    when 'dot' then '04' when 'eli' then '05' when 'fin' then '06' end)::uuid
$$;
create function sid(n text) returns text language sql immutable as $$
  select 'e5d00000-0000-0000-0000-' || right(u(n)::text, 12)
$$;
create function mid(n text) returns uuid language sql immutable as $$
  select md5('e5d-msg-' || n)::uuid
$$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function ph() returns text language sql immutable as $$ select '🔒 Encrypted message' $$;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'e5d-' || n || '@mail.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['amy','ben','cid','dot','eli','fin']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'e5d-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select sid(n)::uuid, u(n), now(), now() from unnest(array['amy','ben','cid','dot','eli','fin']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('amy'), u('ben')), (u('cid'), u('dot')), (u('eli'), u('fin'));

create function as_s(n text, s text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', s)::text, true);
  execute 'set local role authenticated';
end $$;
create function as_(n text) returns void language sql as $$ select as_s(n, sid(n)) $$;
create function pub(n text) returns void language sql as $$
  select public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n),
                                 array[k(n || '1'), k(n || '2')], k(n || '-F'))
$$;
create function col(id uuid) returns text language sql stable security definer as $$
  select concat_ws('|', ciphertext, olm_type, coalesce(edited_at::text, '<null>'))
    from public.messages where id = col.id
$$;
-- The edit as the caller: 'ok|<ciphertext>' or the sqlstate.
create function enc(id uuid, x text) returns text language plpgsql as $$
declare m public.messages;
begin
  m := public.edit_message_encrypted(id, x, 1::smallint);
  return 'ok|' || m.ciphertext;
exception when others then return sqlstate;
end $$;
create function send(c uuid, id uuid, x text) returns void language sql as $$
  insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type)
  values (id, c, auth.uid(), ph(), x, 0::smallint)
$$;
create table public.e5d_ids(name text primary key, id uuid);
grant select, insert on public.e5d_ids to authenticated;
create function g(n text) returns uuid language sql stable as $$
  select id from public.e5d_ids where name = n
$$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), ph(), as_s(text, text),
  as_(text), pub(text), col(uuid), enc(uuid, text), send(uuid, uuid, text), g(text) to authenticated;

do $$
declare n text;
begin
  foreach n in array array['amy','ben','cid','dot','eli','fin'] loop
    perform as_(n);
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    perform pub(n);
    execute 'reset role';
  end loop;
end $$;
select as_('amy'); insert into public.e5d_ids values ('AB', public.start_direct_conversation(u('ben'))); reset role;
select as_('cid'); insert into public.e5d_ids values ('CD', public.start_direct_conversation(u('dot'))); reset role;
select as_('eli'); insert into public.e5d_ids values ('EF', public.start_direct_conversation(u('fin'))); reset role;
select as_('amy'); select send(g('AB'), mid('A1'), 'QUFB'); reset role;
select as_('cid'); select send(g('CD'), mid('C1'), 'Q0ND'); reset role;
select as_('eli'); select send(g('EF'), mid('E1'), 'RUVF'); reset role;
select is((select count(*) from public.messages where id in (mid('A1'), mid('C1'), mid('E1'))), 3::bigint,
  'fixture: three locked rows, one per chat');

-- 1 both members live: the edit works -------------------------------------------
select as_('amy');
select is(enc(mid('A1'), 'QUFBMg'), 'ok|QUFBMg', 'amy edits A1 while ben''s keys are live');
reset role;
select ok(col(mid('A1')) like 'QUFBMg|1|%' and col(mid('A1')) not like '%<null>', 'A1 holds the new ciphertext, edited_at set');

-- 2 the peer's session ended: 42501, nothing changed (twin: section 1) -----------
create table e5d_before as select col(mid('A1')) v;
delete from auth.sessions where id = sid('ben')::uuid;
select as_('amy');
select is(enc(mid('A1'), 'QUFBMw'), '42501', 'ben''s session ended: amy''s edit -> 42501');
reset role;
select is(col(mid('A1')), (select v from e5d_before), 'A1: ciphertext, olm_type and edited_at unchanged');

-- 3 a member who LEFT without keys does not block ----------------------------------
select as_('cid');
select is(enc(mid('C1'), 'Q0NDMg'), 'ok|Q0NDMg', 'control: cid edits C1 while dot is live');
reset role;
delete from auth.sessions where id = sid('dot')::uuid;
select as_('cid');
select is(enc(mid('C1'), 'Q0NDMw'), '42501', 'dot (still a member) has no live keys: cid''s edit -> 42501');
reset role;
select is(col(mid('C1')) like 'Q0NDMg|%', true, 'C1 unchanged by the refused edit');
update public.conversation_members set left_at = now(), left_reason = 'left'
 where conversation_id = g('CD') and user_id = u('dot');
select as_('cid');
select is(enc(mid('C1'), 'Q0NDNA'), 'ok|Q0NDNA', 'once dot has left (left_at set), the edit works');
reset role;
select is(col(mid('C1')) like 'Q0NDNA|1|%', true, 'C1 holds the edit');

-- 4 the caller without live keys blocks --------------------------------------------
select as_('eli');
select is(enc(mid('E1'), 'RUVFMg'), 'ok|RUVFMg', 'control: eli edits E1 from the phone his keys are bound to');
reset role;
-- eli moves to a new phone and has not published there: his keys are not live
insert into auth.sessions (id, user_id, created_at, updated_at)
  values ('e5d00000-0000-0000-0000-00000000f00d', u('eli'), now() + interval '1 minute', now());
select as_s('eli', 'e5d00000-0000-0000-0000-00000000f00d');
select is(public.activate_session(), true, 'fixture: eli activates his new phone');
select is(enc(mid('E1'), 'RUVFMw'), '42501', 'eli (the caller) has no live keys: his edit -> 42501');
reset role;
select is(col(mid('E1')) like 'RUVFMg|%', true, 'E1 unchanged by the refused edit');
select as_s('eli', 'e5d00000-0000-0000-0000-00000000f00d');
select lives_ok($q$select pub('eli')$q$, 'eli publishes on the new phone');
select is(enc(mid('E1'), 'RUVFNA'), 'ok|RUVFNA', 'then the same edit works');
reset role;

-- 5 the old checks still hold ---------------------------------------------------------
select as_('fin');
select is(enc(mid('E1'), 'RkZG'), '42501', 'fin cannot edit eli''s row (not the sender)');
reset role;
select is(col(mid('E1')) like 'RUVFNA|%', true, 'E1 unchanged by fin');
select as_s('eli', 'e5d00000-0000-0000-0000-00000000f00d');
select is(enc(mid('E1'), ''), '42501', 'an empty ciphertext -> 42501');
reset role;

select * from finish();
rollback;
