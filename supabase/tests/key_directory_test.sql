begin;
select plan(148);

-- Key directory (Private Chats step 3): publish_olm_keys, claim_olm_keys,
-- olm_key_status and their three private tables.
--
-- Contract (docs/SECURITY.md "Key directory"; written from the contract, not
-- the function bodies):
--   Tables olm_devices, olm_one_time_keys, olm_claims: no privilege for anon
--   or authenticated, RLS on, not in supabase_realtime. The RPCs are security
--   definer with search_path '', anon cannot execute.
--   publish(identity, signing, signature, one_time[], fallback): bot or no
--   app access 42501; bad input 22023 'invalid request' (no input echo):
--   keys 43-char unpadded base64, signature 86, identity <> signing, no null,
--   duplicate or malformed element, <= 100 per call and <= 100 free in total,
--   fallback differs from identity and from every one-time key; the 31st call
--   in an hour RLMT1. Same identity AND signing = same device (idempotent
--   insert, rebind session, new fallback resets fallback_used); either key
--   different = new device (old keys deleted). Returns free keys.
--   claim(target): bot caller, no access, null target, self, target not on
--   the allowlist, not reachable, revoked (no active session), signed out
--   (auth session gone) -> 42501 'not permitted', the same for every one.
--   A bot target, a stale device (session replaced, not re-published) or no
--   keys -> no rows. A one-time key is handed out once; the claimed row stays
--   (claimed_at) so a re-publish cannot make it free again. Empty pool -> the
--   fallback, is_fallback, repeatedly, fallback_used. 60 calls per hour per
--   caller and 5 per (caller, target), every passed call counting, RLMT1.
--   status(): own row only, free count, fallback flags, same_session (the
--   row is bound to the caller's JWT session); no row when
--   unpublished; bot / no access 42501.
--   Two claims at the same moment (two connections) run in
--   test/integration/key_directory_seam_test.dart: pgTAP has one connection.
--
-- Fixtures. Every refused target fails exactly ONE claim gate: it published
-- keys while allowed and active, the caller ann can reach it, and then one
-- condition is taken away.
--   ann  claimer, published     bob  target with 3 keys + fallback
--   cat  second claimer of bob  far  published, not reachable by ann
--   nal  published, then removed from the allowlist (session kept)
--   rvk  published, then active_sessions row deleted (admin revoke)
--   out  published, then its auth.sessions row deleted (signed out)
--   stl  published, then a new phone session activated, not re-published
--   emp  device, no keys, no fallback     fbk  fallback only
--   bot  enabled bot with a device row    nac  never activated (no access)
--   pub  input checks   cap  caps   prl  publish rate   sem  publish semantics
--   rlm  hourly claim budget   par  per-target budget   cnt  empty claims count
--   btc  claims the bot target   non  never published

-- fixtures -----------------------------------------------------------------
create or replace function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000cde000' || case n
    when 'ann' then '01' when 'bob' then '02' when 'cat' then '03' when 'far' then '04'
    when 'nal' then '05' when 'rvk' then '06' when 'out' then '07' when 'stl' then '08'
    when 'emp' then '09' when 'fbk' then '0a' when 'bot' then '0b' when 'nac' then '0c'
    when 'pub' then '0d' when 'cap' then '0e' when 'prl' then '0f' when 'sem' then '10'
    when 'rlm' then '11' when 'par' then '12' when 'cnt' then '13' when 'btc' then '14'
    when 'non' then '15' end)::uuid
$$;
-- A valid 32-byte public key / 64-byte signature (unpadded base64), named.
create or replace function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create or replace function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create or replace function ks(n text, cnt int) returns text[] language sql immutable as $$
  select coalesce(array_agg(k(n || i) order by i), '{}') from generate_series(1, cnt) i
$$;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'kd-' || n || '@mail.test', now(), json_build_object('full_name', n)::jsonb
    from unnest(array['ann','bob','cat','far','nal','rvk','out','stl','emp','fbk','bot','nac',
                      'pub','cap','prl','sem','rlm','par','cnt','btc','non']) n;
insert into app_private.allowlist(email)
  select email from auth.users where id::text like '00000000-0000-0000-0000-0000cde000%';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('5e5e0000-0000-0000-0000-' || right(id::text, 12))::uuid, id, now(), now()
    from auth.users where id::text like '00000000-0000-0000-0000-0000cde000%';
-- Second phones: stl's new phone, sem's new phone.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('5e5e0000-0000-0000-0000-0000cde0f008', u('stl'), now() + interval '1 minute', now()),
  ('5e5e0000-0000-0000-0000-0000cde0f010', u('sem'), now() + interval '1 minute', now());

create or replace function test_as(uid uuid, sid text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', coalesce(sid, '5e5e0000-0000-0000-0000-' || right(uid::text, 12)))::text, true);
  execute 'set local role authenticated';
end $$;
-- One call as the current role, in its own subtransaction: 'ok:<n>' or
-- '<sqlstate>:<message>'.
create or replace function try_pub(i text, s text, g text, otk text[], fb text default null)
returns text language plpgsql as $$
begin
  return 'ok:' || public.publish_olm_keys(i, s, g, otk, fb);
exception when others then
  return sqlstate || ':' || sqlerrm;
end $$;
-- Everything a publish error tells the client: message, detail, hint.
create or replace function err_pub(i text, s text, g text, otk text[], fb text default null)
returns text language plpgsql as $$
declare m text; d text; t text;
begin
  perform public.publish_olm_keys(i, s, g, otk, fb);
  return 'no error';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail, t = pg_exception_hint;
  return concat_ws('|', sqlstate, m, nullif(d, ''), nullif(t, ''));
end $$;
-- A claim as JSON rows, or {"err": "<sqlstate>|<message>|<detail>|<hint>"}.
create or replace function claim_json(t uuid) returns jsonb language plpgsql as $$
declare r jsonb; m text; d text; h text;
begin
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into r from public.claim_olm_keys(t) c;
  return r;
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail, h = pg_exception_hint;
  return jsonb_build_object('err', concat_ws('|', sqlstate, m, nullif(d, ''), nullif(h, '')));
end $$;
create or replace function try_status() returns text language plpgsql as $$
declare n bigint;
begin
  select count(*) into n from public.olm_key_status();
  return 'ok:' || n;
exception when others then
  return sqlstate || ':' || sqlerrm;
end $$;
grant execute on function u(text), k(text), sig(text), ks(text, int), test_as(uuid, text),
  try_pub(text, text, text, text[], text), err_pub(text, text, text, text[], text),
  claim_json(uuid), try_status() to authenticated, anon;
-- Claims made by the tests, kept to compare across calls.
create table public.kd_got(label text primary key, j jsonb);
grant select, insert on public.kd_got to authenticated;
create or replace function got(l text) returns jsonb language sql as $$
  select j from public.kd_got where label = l
$$;
grant execute on function got(text) to authenticated;
-- A member publishes I/S keys named after them (setup helper; asserts ok).
create or replace function publish_as(n text, otk text[], fb text default null, sid text default null)
returns text language plpgsql as $$
declare r text;
begin
  perform test_as(u(n), sid);
  r := try_pub(k(n || '-I'), k(n || '-S'), sig(n), otk, fb);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

do $$
declare n text;
begin
  foreach n in array array['ann','bob','cat','far','nal','rvk','out','stl','emp','fbk','bot',
                           'pub','cap','prl','sem','rlm','par','cnt','btc','non'] loop
    perform test_as(u(n));
    perform public.activate_session();
    execute 'reset role';
  end loop;
end $$;
insert into public.conversations(id, title) values ('cde0c000-0000-0000-0000-000000000001', 'debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
  values (u('bot'), 'cde0c000-0000-0000-0000-000000000001', true);
-- Reach: one-way saved contacts (can_reach is true for the owner).
insert into public.contacts(owner_id, contact_id) values
  (u('ann'), u('bob')), (u('cat'), u('bob')), (u('ann'), u('nal')), (u('ann'), u('rvk')),
  (u('ann'), u('out')), (u('ann'), u('stl')), (u('ann'), u('emp')), (u('ann'), u('fbk')),
  (u('ann'), u('bot')), (u('bot'), u('bob')), (u('nac'), u('bob')), (u('rlm'), u('fbk')),
  (u('par'), u('fbk')), (u('par'), u('emp')), (u('cnt'), u('emp')), (u('btc'), u('bot'));

-- Publishing every target while it is allowed and active.
select is(publish_as('ann', ks('ann', 2), k('ann-F')), 'ok:2', 'setup: ann publishes');
select is(publish_as('bob', ks('bob', 3), k('bob-F')), 'ok:3', 'setup: bob publishes 3 keys and a fallback');
select is(publish_as('far', ks('far', 2), k('far-F')), 'ok:2', 'setup: far publishes');
select is(publish_as('nal', ks('nal', 2), k('nal-F')), 'ok:2', 'setup: nal publishes');
select is(publish_as('rvk', ks('rvk', 2), k('rvk-F')), 'ok:2', 'setup: rvk publishes');
select is(publish_as('out', ks('out', 2), k('out-F')), 'ok:2', 'setup: out publishes');
select is(publish_as('stl', ks('stl', 2), k('stl-F')), 'ok:2', 'setup: stl publishes on the old phone');
select is(publish_as('emp', '{}'), 'ok:0', 'setup: emp publishes a device with no keys');
select is(publish_as('fbk', '{}', k('fbk-F')), 'ok:0', 'setup: fbk publishes only a fallback');
-- Bots cannot publish; the bot target's device is written by the setup role.
insert into app_private.olm_devices(user_id, identity_key, signing_key, device_signature, fallback_key, session_id)
  values (u('bot'), k('bot-I'), k('bot-S'), sig('bot'), k('bot-F'),
          '5e5e0000-0000-0000-0000-0000cde0000b');
insert into app_private.olm_one_time_keys(user_id, key) values (u('bot'), k('bot1'));

-- Take away exactly one condition from each refused target.
delete from app_private.allowlist where email = 'kd-nal@mail.test';
delete from app_private.active_sessions where user_id = u('rvk');
delete from auth.sessions where user_id = u('out');
select test_as(u('stl'), '5e5e0000-0000-0000-0000-0000cde0f008');
select public.activate_session();
reset role;

select ok(exists(select 1 from app_private.active_sessions where user_id = u('nal'))
          and exists(select 1 from auth.sessions where user_id = u('nal')),
  'fixture: nal keeps its live session; only the allowlist row is gone');
select ok(exists(select 1 from app_private.allowlist where email = 'kd-rvk@mail.test')
          and exists(select 1 from auth.sessions where user_id = u('rvk'))
          and not exists(select 1 from app_private.active_sessions where user_id = u('rvk')),
  'fixture: rvk is allowlisted with an auth session but no active session');
select ok(exists(select 1 from app_private.active_sessions where user_id = u('out'))
          and exists(select 1 from app_private.allowlist where email = 'kd-out@mail.test')
          and not exists(select 1 from auth.sessions where user_id = u('out')),
  'fixture: out keeps allowlist and active_sessions; its auth session is gone');
select is((select session_id::text from app_private.active_sessions where user_id = u('stl')),
  '5e5e0000-0000-0000-0000-0000cde0f008', 'fixture: stl''s new phone holds the active session');

-- 1 tables and functions ----------------------------------------------------
select ok(not has_table_privilege(r, 'app_private.' || t, p),
          format('%s has no %s on %s', r, p, t))
  from unnest(array['anon','authenticated']) r,
       unnest(array['olm_devices','olm_one_time_keys','olm_claims']) t,
       unnest(array['select','insert','update','delete']) p;
select ok((select relrowsecurity from pg_class where oid = ('app_private.' || t)::regclass),
          t || ': row level security is on')
  from unnest(array['olm_devices','olm_one_time_keys','olm_claims']) t;
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and tablename like 'olm%'), 0,
  'no olm table is in the supabase_realtime publication');
select ok(not has_function_privilege('anon', f, 'execute'), 'anon cannot execute ' || f)
  from unnest(array['public.publish_olm_keys(text,text,text,text[],text)',
                    'public.claim_olm_keys(uuid)', 'public.olm_key_status()']) f;
select ok(has_function_privilege('authenticated', f, 'execute'), 'authenticated can execute ' || f)
  from unnest(array['public.publish_olm_keys(text,text,text,text[],text)',
                    'public.claim_olm_keys(uuid)', 'public.olm_key_status()']) f;
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = f::regprocedure),
          f || ' is security definer with an empty search_path')
  from unnest(array['public.publish_olm_keys(text,text,text,text[],text)',
                    'public.claim_olm_keys(uuid)', 'public.olm_key_status()']) f;

-- 2 publish: refusals and input checks --------------------------------------
select test_as(u('bot'));
select alike(try_pub(k('b-I'), k('b-S'), sig('b'), '{}'), '42501:%', 'publish: a bot caller is refused');
reset role;
select test_as(u('nac'));
select alike(try_pub(k('n-I'), k('n-S'), sig('n'), '{}'), '42501:%', 'publish: no app access is refused');
reset role;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
set local role authenticated;
select alike(try_pub(k('x-I'), k('x-S'), sig('x'), '{}'), '42501:%', 'publish: no signed-in user is refused');
reset role;

select test_as(u('pub'));
select is(try_pub(null, k('p-S'), sig('p'), '{}'), '22023:invalid request', 'publish: null identity');
select is(try_pub(left(k('p-I'), 42), k('p-S'), sig('p'), '{}'), '22023:invalid request', 'publish: short identity');
select is(try_pub(k('p-I') || 'A', k('p-S'), sig('p'), '{}'), '22023:invalid request', 'publish: long identity');
select is(try_pub('-' || right(k('p-I'), 42), k('p-S'), sig('p'), '{}'), '22023:invalid request', 'publish: non-base64 identity');
select is(try_pub(k('p-I'), null, sig('p'), '{}'), '22023:invalid request', 'publish: null signing');
select is(try_pub(k('p-I'), left(k('p-S'), 42), sig('p'), '{}'), '22023:invalid request', 'publish: short signing');
select is(try_pub(k('p-I'), k('p-S') || 'A', sig('p'), '{}'), '22023:invalid request', 'publish: long signing');
select is(try_pub(k('p-I'), '_' || right(k('p-S'), 42), sig('p'), '{}'), '22023:invalid request', 'publish: non-base64 signing');
select is(try_pub(k('p-I'), k('p-S'), null, '{}'), '22023:invalid request', 'publish: null signature');
select is(try_pub(k('p-I'), k('p-S'), left(sig('p'), 85), '{}'), '22023:invalid request', 'publish: short signature');
select is(try_pub(k('p-I'), k('p-S'), sig('p') || 'A', '{}'), '22023:invalid request', 'publish: long signature');
select is(try_pub(k('p-I'), k('p-S'), '-' || right(sig('p'), 85), '{}'), '22023:invalid request', 'publish: non-base64 signature');
select is(try_pub(k('p-I'), k('p-I'), sig('p'), '{}'), '22023:invalid request', 'publish: identity equal to signing');
select is(try_pub(k('p-I'), k('p-S'), sig('p'), array[k('p1'), null]), '22023:invalid request', 'publish: a null one-time element');
select is(try_pub(k('p-I'), k('p-S'), sig('p'), array[k('p1'), k('p1')]), '22023:invalid request', 'publish: a duplicate one-time element');
select is(try_pub(k('p-I'), k('p-S'), sig('p'), array[k('p1'), 'not a key']), '22023:invalid request', 'publish: a malformed one-time element');
select is(try_pub(k('p-I'), k('p-S'), sig('p'), ks('p', 2), k('p-I')), '22023:invalid request', 'publish: fallback equal to identity');
select is(try_pub(k('p-I'), k('p-S'), sig('p'), ks('p', 2), k('p1')), '22023:invalid request', 'publish: fallback equal to a one-time key');
select is(try_pub(k('p-I'), k('p-S'), sig('p'), '{}', 'short'), '22023:invalid request', 'publish: malformed fallback');
select is(err_pub(k('p-I'), k('p-S'), sig('p'), array['secret-looking-input-0123']), '22023|invalid request',
  'publish: the error carries no detail, hint or echo of the input');
reset role;
select is((select count(*)::int from app_private.olm_devices where user_id = u('pub')), 0,
  'publish: refused calls store no device');

select test_as(u('cap'));
select is(try_pub(k('c-I'), k('c-S'), sig('c'), ks('c', 101)), '22023:invalid request', 'publish: 101 keys in one call');
select is(try_pub(k('c-I'), k('c-S'), sig('c'), ks('c', 100)), 'ok:100', 'publish: 100 keys in one call is the cap');
select is(try_pub(k('c-I'), k('c-S'), sig('c'), array[k('c-extra')]), '22023:invalid request', 'publish: 101 free in total');
reset role;
select is((select count(*)::int from app_private.olm_one_time_keys where user_id = u('cap')), 100,
  'publish: the refused top-up stored nothing');

-- publish rate: 30 per hour, the 31st is RLMT1.
insert into app_private.tag_lookups(user_id, kind) select u('prl'), 'olm_publish' from generate_series(1, 29);
select test_as(u('prl'));
select is(try_pub(k('r-I'), k('r-S'), sig('r'), '{}'), 'ok:0', 'publish: call 30 in an hour is accepted');
select alike(try_pub(k('r-I'), k('r-S'), sig('r'), '{}'), 'RLMT1:%', 'publish: call 31 in an hour is RLMT1');
reset role;
update app_private.tag_lookups set called_at = now() - interval '61 minutes' where user_id = u('prl');
select test_as(u('prl'));
select is(try_pub(k('r-I'), k('r-S'), sig('r'), '{}'), 'ok:0', 'publish: calls older than an hour no longer count');
reset role;

-- 3 publish semantics -------------------------------------------------------
select test_as(u('sem'));
select is(try_pub(k('s-I'), k('s-S'), sig('s'), ks('s', 3), k('s-F')), 'ok:3', 'publish: first publish returns the free count');
select is(try_pub(k('s-I'), k('s-S'), sig('s'), ks('s', 3), k('s-F')), 'ok:3', 'publish: the same keys again are idempotent');
reset role;
select is((select count(*)::int from app_private.olm_one_time_keys where user_id = u('sem')), 3,
  'publish: the repeat stored no duplicates');
select is((select device_signature from app_private.olm_devices where user_id = u('sem')), sig('s'),
  'publish: device_signature is stored');
select test_as(u('sem'));
select is((select same_session from public.olm_key_status()), true,
  'status: same_session is true for the session that published');
reset role;
-- sem moves to a new phone session; the old one is refused, the new rebinds.
select test_as(u('sem'), '5e5e0000-0000-0000-0000-0000cde0f010');
select public.activate_session();
select is((select same_session::text || ':' || identity_key from public.olm_key_status()), 'false:' || k('s-I'),
  'status: after the session changed the row is still there, with same_session false');
select is(try_pub(k('s-I'), k('s-S'), sig('s'), '{}'), 'ok:3', 'publish: an empty list returns the count');
select is((select same_session from public.olm_key_status()), true,
  'status: the rebind makes same_session true again');
reset role;
select is((select session_id::text from app_private.olm_devices where user_id = u('sem')),
  '5e5e0000-0000-0000-0000-0000cde0f010', 'publish: an empty list rebinds the device to the live session');
select test_as(u('sem'));
select alike(try_pub(k('s-I'), k('s-S'), sig('s'), '{}'), '42501:%', 'publish: a replaced phone session is refused');
reset role;
update app_private.olm_devices set fallback_used = true where user_id = u('sem');
select test_as(u('sem'), '5e5e0000-0000-0000-0000-0000cde0f010');
select is(try_pub(k('s-I'), k('s-S'), sig('s'), '{}', k('s-F2')), 'ok:3', 'publish: same device with a new fallback');
reset role;
select is((select fallback_key || ':' || fallback_used from app_private.olm_devices where user_id = u('sem')),
  k('s-F2') || ':false', 'publish: the new fallback replaces the old and resets fallback_used');
select test_as(u('sem'), '5e5e0000-0000-0000-0000-0000cde0f010');
select is(try_pub(k('s-I2'), k('s-S'), sig('s2'), array[k('s4')]), 'ok:1', 'publish: only the identity changed is a new device');
reset role;
select is((select array_agg(key) from app_private.olm_one_time_keys where user_id = u('sem')), array[k('s4')],
  'publish: a new identity deletes the old device''s keys');
select is((select identity_key || device_signature from app_private.olm_devices where user_id = u('sem')),
  k('s-I2') || sig('s2'), 'publish: the new identity and signature replace the old');
select test_as(u('sem'), '5e5e0000-0000-0000-0000-0000cde0f010');
select is(try_pub(k('s-I2'), k('s-S2'), sig('s3'), array[k('s5')]), 'ok:1', 'publish: only the signing key changed is a new device');
reset role;
select is((select array_agg(key) from app_private.olm_one_time_keys where user_id = u('sem')), array[k('s5')],
  'publish: a new signing key deletes the old device''s keys');

-- 7 status (before any claim) -----------------------------------------------
select test_as(u('bob'));
select is((select one_time_keys || ':' || has_fallback || ':' || fallback_used || ':' || identity_key
             from public.olm_key_status()),
  '3:true:false:' || k('bob-I'), 'status: bob sees his own row: 3 free, fallback unused');
select is((select count(*)::int from public.olm_key_status()), 1, 'status: one row, the caller''s own');
reset role;
select test_as(u('non'));
select is(try_status(), 'ok:0', 'status: no row when nothing is published');
reset role;
select test_as(u('bot'));
select alike(try_status(), '42501:%', 'status: a bot caller is refused');
reset role;
select test_as(u('nac'));
select alike(try_status(), '42501:%', 'status: no app access is refused');
reset role;

-- 4 claim gates: all the same 42501 'not permitted' -------------------------
select test_as(u('bot'));
select is(claim_json(u('bob')), '{"err":"42501|not permitted"}', 'claim: a bot caller is refused');
reset role;
select test_as(u('nac'));
select is(claim_json(u('bob')), '{"err":"42501|not permitted"}', 'claim: a caller without app access is refused');
reset role;
select test_as(u('ann'));
select is(claim_json(null), '{"err":"42501|not permitted"}', 'claim: a null target is refused');
select is(claim_json(u('ann')), '{"err":"42501|not permitted"}', 'claim: the caller''s own keys are refused');
select is(claim_json(u('far')), '{"err":"42501|not permitted"}', 'claim: a target the caller cannot reach is refused');
select is(claim_json(u('nal')), '{"err":"42501|not permitted"}', 'claim: a target off the allowlist is refused');
select is(claim_json(u('rvk')), '{"err":"42501|not permitted"}', 'claim: a target revoked by an admin is refused');
select is(claim_json(u('out')), '{"err":"42501|not permitted"}', 'claim: a signed-out target is refused');
select is(claim_json('00000000-0000-0000-0000-0000cde000ff'), '{"err":"42501|not permitted"}',
  'claim: an unknown user id is refused the same way');
reset role;
select is((select count(*)::int from app_private.olm_one_time_keys
            where user_id in (u('far'), u('nal'), u('rvk'), u('out')) and claimed_at is not null), 0,
  'claim: refused claims hand out no key');

-- 5 claim semantics ---------------------------------------------------------
select test_as(u('ann'));
insert into public.kd_got values ('a1', claim_json(u('bob')));
reset role;
select is(jsonb_array_length(got('a1')), 1, 'claim: one row');
select is(got('a1')->0->>'identity_key', k('bob-I'), 'claim: the target''s identity key');
select is(got('a1')->0->>'signing_key', k('bob-S'), 'claim: the target''s signing key');
select is(got('a1')->0->>'device_signature', sig('bob'), 'claim: the stored device signature');
select ok(got('a1')->0->>'one_time_key' = any(ks('bob', 3)), 'claim: one of the target''s one-time keys');
select is(got('a1')->0->>'is_fallback', 'false', 'claim: not the fallback');
select test_as(u('cat'));
insert into public.kd_got values ('c1', claim_json(u('bob')));
reset role;
select test_as(u('ann'));
insert into public.kd_got values ('a2', claim_json(u('bob')));
reset role;
select is((select count(distinct j->0->>'one_time_key')::int from public.kd_got where label in ('a1','c1','a2')), 3,
  'claim: three claims by two callers get three different keys');
select ok((select bool_and(j->0->>'one_time_key' = any(ks('bob', 3)) and j->0->>'is_fallback' = 'false')
             from public.kd_got where label in ('c1','a2')), 'claim: both later claims are one-time keys');
select is((select count(*)::int from app_private.olm_one_time_keys where user_id = u('bob') and claimed_at is not null), 3,
  'claim: claimed rows stay, with claimed_at set');
select test_as(u('bob'));
select is((select one_time_keys from public.olm_key_status()), 0, 'status: claimed keys are not counted as free');
select is(try_pub(k('bob-I'), k('bob-S'), sig('bob'), ks('bob', 3)), 'ok:0',
  'claim: re-publishing claimed keys leaves none free (tombstones)');
reset role;
select test_as(u('cat'));
insert into public.kd_got values ('c2', claim_json(u('bob')));
reset role;
select is(got('c2')->0->>'one_time_key' || ':' || (got('c2')->0->>'is_fallback'), k('bob-F') || ':true',
  'claim: a re-published claimed key is never handed out again; the fallback comes instead');
select test_as(u('ann'));
insert into public.kd_got values ('a3', claim_json(u('bob')));
reset role;
select is(got('a3')->0->>'one_time_key' || ':' || (got('a3')->0->>'is_fallback'), k('bob-F') || ':true',
  'claim: the fallback is returned again (not consumed)');
select is((select fallback_used from app_private.olm_devices where user_id = u('bob')), true,
  'claim: handing out the fallback sets fallback_used');
select test_as(u('bob'));
select is((select has_fallback || ':' || fallback_used from public.olm_key_status()), 'true:true',
  'status: bob sees his fallback was used');
reset role;
select test_as(u('ann'));
select is(claim_json(u('emp')), '[]', 'claim: a device with no keys and no fallback gives no rows');
select is(claim_json(u('fbk'))->0->>'is_fallback', 'true', 'claim: fallback-only device gives the fallback');
select is(claim_json(u('bot')), '[]', 'claim: a bot target gives no rows');
select is(claim_json(u('stl')), '[]', 'claim: a stale device (phone replaced, not re-published) gives no rows');
reset role;
select is((select count(*)::int from app_private.olm_one_time_keys where user_id = u('bot') and claimed_at is not null), 0,
  'claim: the bot target''s key is not handed out');
select test_as(u('stl'), '5e5e0000-0000-0000-0000-0000cde0f008');
select is(try_pub(k('stl-I2'), k('stl-S2'), sig('stl2'), ks('stl-2nd', 2), k('stl-F2')), 'ok:2',
  'claim: stl''s new phone publishes a new identity');
reset role;
select test_as(u('ann'));
insert into public.kd_got values ('s1', claim_json(u('stl')));
reset role;
select is(got('s1')->0->>'identity_key', k('stl-I2'), 'claim: after the new phone publishes, its identity comes back');
select ok(got('s1')->0->>'one_time_key' = any(ks('stl-2nd', 2)), 'claim: and one of the new phone''s keys');

-- 6 claim rate limits -------------------------------------------------------
-- 60 per hour per caller.
insert into app_private.olm_claims(claimer, target) select u('rlm'), u('far') from generate_series(1, 59);
insert into app_private.olm_claims(claimer, target, called_at) values (u('rlm'), u('far'), now() - interval '2 hours');
select test_as(u('rlm'));
select is(claim_json(u('fbk'))->0->>'is_fallback', 'true', 'claim: call 60 in an hour is served');
select alike(claim_json(u('fbk'))->>'err', 'RLMT1|%', 'claim: call 61 in an hour is RLMT1');
reset role;
select is((select count(*)::int from app_private.olm_claims where claimer = u('rlm') and called_at < now() - interval '1 hour'), 0,
  'claim: claim rows older than an hour are pruned');
update app_private.olm_claims set called_at = now() - interval '61 minutes' where claimer = u('rlm');
select test_as(u('rlm'));
select is(claim_json(u('fbk'))->0->>'is_fallback', 'true', 'claim: calls older than an hour no longer count');
reset role;
-- 5 per hour per (caller, target); another target is still allowed.
select test_as(u('par'));
select is((select count(*)::int from generate_series(1, 5) g where claim_json(u('fbk'))->0->>'is_fallback' = 'true'), 5,
  'claim: five claims of one target in an hour are served');
select alike(claim_json(u('fbk'))->>'err', 'RLMT1|%', 'claim: the sixth claim of the same target is RLMT1');
select is(claim_json(u('emp')), '[]', 'claim: a different target is still allowed (the cap is per pair)');
reset role;
-- A claim that returns no rows still counts (empty device and bot target).
select test_as(u('cnt'));
select is((select count(*)::int from generate_series(1, 5) g where claim_json(u('emp')) = '[]'), 5,
  'claim: five empty claims are answered');
select alike(claim_json(u('emp'))->>'err', 'RLMT1|%', 'claim: empty claims count toward the per-target cap');
reset role;
select test_as(u('btc'));
select is((select count(*)::int from generate_series(1, 5) g where claim_json(u('bot')) = '[]'), 5,
  'claim: five claims of a bot target give no rows');
select alike(claim_json(u('bot'))->>'err', 'RLMT1|%', 'claim: claims of a bot target count too');
reset role;
-- Refused claims do not reach the counter (only passed gates count).
select is((select count(*)::int from app_private.olm_claims where claimer in (u('bot'), u('nac'))), 0,
  'claim: refused callers leave no claim rows');

select * from finish();
rollback;
