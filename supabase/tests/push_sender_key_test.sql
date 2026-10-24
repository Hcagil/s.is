begin;
select plan(31);

-- The sender key of a pre-key push (20261103120000_push_prekey_sender_key.sql).
--
-- Contract (written from the contract, not the function body):
--   public.push_targets(message_id) adds `sender_key text, sender_id uuid`
--   before `encrypted`. Both are non-null ONLY for a recipient whose preview
--   is full (or unset), on a ciphertext row with olm_type 0, when the sender
--   has a live olm_devices row (its session is the sender's active session and
--   that auth session exists), is allowlisted and is not a bot. sender_key is
--   then that olm_devices.identity_key and sender_id the message's sender.
--   Otherwise both null. The recipient rows are the same as before: one row
--   per recipient device, never multiplied, never dropped by these columns.
--
-- Each negative sender differs from the positive sender ann in ONE gate only,
-- and that gate is broken after the message was sent (sending needs a live
-- sender), so the message itself is identical in shape to ann's:
--   bea  second live sender (her key, never ann's)
--   dan  active_sessions row gone          eve  auth.sessions row gone
--   jon  olm_devices bound to an older session (still signed in)
--   fay  removed from the allowlist        gil  marked as a bot
--   ivy  olm_devices row deleted
-- Recipients: bob preview unset, cat preview 'sender', hal preview 'none'.

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000a5c000' || case n
    when 'ann' then '01' when 'bob' then '02' when 'cat' then '03' when 'hal' then '04'
    when 'bea' then '05' when 'dan' then '06' when 'eve' then '07' when 'fay' then '08'
    when 'gil' then '09' when 'ivy' then '10' when 'jon' then '11' end)::uuid
$$;
create function sid(n text) returns text language sql immutable as $$
  select 'a5c00000-0000-0000-0000-' || right(u(n)::text, 12)
$$;
create function mid(n text) returns uuid language sql immutable as $$
  select md5('a5c-msg-' || n)::uuid
$$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', sid(n))::text, true);
  execute 'set local role authenticated';
end $$;
create table public.a5c_ids(name text primary key, id uuid);
grant select, insert on public.a5c_ids to authenticated, anon, service_role;
create function g(n text) returns uuid language sql stable as $$ select id from public.a5c_ids where name = n $$;
create function send(c text, m text, x text, t int) returns void language sql as $$
  insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type)
  values (mid(m), g(c), auth.uid(), case when x is null then 'plain ' || m else '🔒 Encrypted message' end, x, t::smallint)
$$;
-- push_targets claims a message: each message is read ONCE, into snap.
create table public.a5c_snap(m text, user_id uuid, ciphertext text, sender_key text, sender_id uuid);
grant select, insert on public.a5c_snap to service_role;
-- the row of [n] for message [m]: "ciphertext|sender_key|sender_id", nulls as <null>.
create function pt(m text, n text) returns text language sql stable as $$
  select coalesce(ciphertext, '<null>') || '|' || coalesce(sender_key, '<null>') || '|' || coalesce(sender_id::text, '<null>')
    from public.a5c_snap s where s.m = pt.m and user_id = u(n)
$$;
create function rows_of(m text) returns bigint language sql stable as $$
  select count(*) from public.a5c_snap s where s.m = rows_of.m
$$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), as_(text), g(text),
  send(text, text, text, int), pt(text, text), rows_of(text) to authenticated, anon, service_role;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'a5c-' || n || '@mail.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['ann','bob','cat','hal','bea','dan','eve','fay','gil','ivy','jon']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'a5c-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select sid(n)::uuid, u(n), now(), now()
    from unnest(array['ann','bob','cat','hal','bea','dan','eve','fay','gil','ivy','jon']) n;
insert into app_private.tag_finds(finder, found_id)
  select u('ann'), u(n) from unnest(array['bob','cat','hal']) n
  union all
  select u(n), u('bob') from unnest(array['bea','dan','eve','fay','gil','ivy','jon']) n;

do $$
declare n text;
begin
  foreach n in array array['ann','bob','cat','hal','bea','dan','eve','fay','gil','ivy','jon'] loop
    perform as_(n);
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    perform public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n), array[k(n || '1'), k(n || '2')], k(n || '-F'));
    perform public.register_device_token('a5c-tok-' || n, 'android', true);
    if n = 'cat' then insert into public.notification_settings(preview) values ('sender'); end if;
    if n = 'hal' then insert into public.notification_settings(preview) values ('none'); end if;
    execute 'reset role';
  end loop;
end $$;

select as_('ann');
insert into public.a5c_ids values
  ('AB', public.start_direct_conversation(u('bob'))),
  ('AC', public.start_direct_conversation(u('cat'))),
  ('AH', public.start_direct_conversation(u('hal')));
select send('AB', 'ap', null, null);
select send('AB', 'a0', 'QUFBMA==', 0), send('AB', 'a1', 'QUFBMQ==', 1),
       send('AC', 'c0', 'Q0NDMA==', 0), send('AH', 'h0', 'SEhIMA==', 0);
reset role;

do $$
declare n text;
begin
  foreach n in array array['bea','dan','eve','fay','gil','ivy','jon'] loop
    perform as_(n);
    insert into public.a5c_ids values (n, public.start_direct_conversation(u('bob')));
    perform send(n, n || '0', 'WFhYMA==', 0);
    execute 'reset role';
  end loop;
end $$;

-- Break one gate per negative sender, after the send.
delete from app_private.active_sessions where user_id = u('dan');
delete from auth.sessions where user_id = u('eve');
update app_private.olm_devices set session_id = 'a5c00000-0000-0000-0000-00000000dead' where user_id = u('jon');
delete from app_private.allowlist where email = 'a5c-fay@mail.test';
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('gil'), g('gil'));
delete from app_private.olm_devices where user_id = u('ivy');

-- Fixtures: the states are what the scenario says.
select is((select identity_key from app_private.olm_devices where user_id = u('ann')), k('ann-I'),
  'fixture: ann''s olm_devices identity key is the one she published');
select ok(exists (select 1 from app_private.active_sessions a join app_private.olm_devices d using (user_id)
                   where user_id = u('fay') and a.session_id = d.session_id)
          and exists (select 1 from app_private.active_sessions a join app_private.olm_devices d using (user_id)
                   where user_id = u('gil') and a.session_id = d.session_id),
  'fixture: fay and gil still have a live device (only the allowlist / bot gate is broken)');
select ok(exists (select 1 from app_private.active_sessions where user_id = u('jon'))
          and exists (select 1 from auth.sessions where user_id = u('jon')),
  'fixture: jon is still signed in (only his device''s session is stale)');

set local role service_role;
insert into public.a5c_snap
  select m, t.user_id, t.ciphertext, t.sender_key, t.sender_id
    from unnest(array['ap','a0','a1','c0','h0','bea0','dan0','eve0','fay0','gil0','ivy0','jon0']) m,
         lateral public.push_targets(mid(m)) t;
reset role;

-- 1 the positive case -------------------------------------------------------
select is(pt('a0', 'bob'), 'QUFBMA==|' || k('ann-I') || '|' || u('ann'),
  'ot 0, preview unset, live sender: ct, sender_key = her olm_devices identity key, sender_id = sender');
select is(pt('bea0', 'bob'), 'WFhYMA==|' || k('bea-I') || '|' || u('bea'),
  'a second live sender: her own key and id');
select isnt((select sender_key from public.a5c_snap where m = 'bea0'), k('ann-I'),
  'a message from bea never carries ann''s key');

-- 2 olm_type 1, preview sender/none, plain ----------------------------------
select is(pt('a1', 'bob'), 'QUFBMQ==|<null>|<null>', 'ot 1: ct only, sender_key and sender_id null');
select is(pt('c0', 'cat'), '<null>|<null>|<null>', 'preview sender: ct, sender_key, sender_id all null');
select is(pt('h0', 'hal'), '<null>|<null>|<null>', 'preview none: ct, sender_key, sender_id all null');
select is(pt('ap', 'bob'), '<null>|<null>|<null>', 'plain message: all null');

-- 3 one sender gate broken: ct still rides, the key does not ----------------
select is(pt('dan0', 'bob'), 'WFhYMA==|<null>|<null>', 'sender''s active session ended: no key');
select is(pt('eve0', 'bob'), 'WFhYMA==|<null>|<null>', 'sender''s auth session deleted: no key');
select is(pt('jon0', 'bob'), 'WFhYMA==|<null>|<null>', 'sender''s device bound to an older session: no key');
select is(pt('fay0', 'bob'), 'WFhYMA==|<null>|<null>', 'sender off the allowlist: no key');
select is(pt('gil0', 'bob'), 'WFhYMA==|<null>|<null>', 'sender is a bot: no key');
select is(pt('ivy0', 'bob'), 'WFhYMA==|<null>|<null>', 'sender has no olm_devices row: no key');

-- 4 the recipient rows are unchanged: exactly one per message, the recipient --
select is(rows_of('a0'), 1::bigint, 'a0: one row');
select is(rows_of('a1'), 1::bigint, 'a1: one row');
select is(rows_of('ap'), 1::bigint, 'ap: one row');
select is(rows_of('c0'), 1::bigint, 'c0: one row (preview sender still notified)');
select is(rows_of('h0'), 1::bigint, 'h0: one row (preview none still notified)');
select is(rows_of('bea0'), 1::bigint, 'bea0: one row');
select is(rows_of('dan0'), 1::bigint, 'dan0: one row (a signed-out sender does not drop the recipient)');
select is(rows_of('eve0'), 1::bigint, 'eve0: one row');
select is(rows_of('jon0'), 1::bigint, 'jon0: one row');
select is(rows_of('fay0'), 1::bigint, 'fay0: one row');
select is(rows_of('gil0'), 1::bigint, 'gil0: one row');
select is(rows_of('ivy0'), 1::bigint, 'ivy0: one row (no device row does not drop the recipient)');
select is((select count(*) from public.a5c_snap where user_id <> u('bob') and m not in ('c0', 'h0')), 0::bigint,
  'every 1:1 row goes to bob only (the sender is never on her own list)');

-- 5 the shape, and the inner function returns the same columns ---------------
select ok(pg_get_function_result('public.push_targets(uuid)'::regprocedure)
            like '%, olm_type smallint, sender_key text, sender_id uuid, encrypted boolean)',
  'push_targets: sender_key text, sender_id uuid right before encrypted');
select is(pg_get_function_result('app_private.push_targets_for_message(uuid)'::regprocedure),
          pg_get_function_result('public.push_targets(uuid)'::regprocedure),
  'push_targets_for_message returns the same columns');

select * from finish();
rollback;
