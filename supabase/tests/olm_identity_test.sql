begin;
select plan(31);

-- public.olm_identity(target) (Private Chats step 4a): a member's published
-- identity, so a phone can verify who it talks to, WITHOUT claiming a key.
--
-- Contract (written from the contract, not the function body):
--   Returns (identity_key, signing_key, device_signature) of X's published
--   device when X has a live session and a device bound to it: exactly the
--   published row, and no one-time key is consumed (claimed_at, olm_claims
--   and fallback_used unchanged). A bot caller, no app access, X = self, X not
--   on the allowlist, X not reachable -> 42501. X a bot, or X's device stale
--   behind a newer live session -> no rows. anon cannot execute. Not rate
--   limited: 100 calls in a row raise no RLMT1.
--   X published, allowed and reachable but with no live session (its
--   active session gone, or its auth session signed out) -> no rows, no error.
--
-- Fixtures: every refused target published while allowed, active and
-- reachable by ann; then exactly one condition is taken away.
--   ann  caller (published)   bob  target, 3 keys + fallback
--   far  published, ann cannot reach    nal  published, then delisted
--   stl  published, then a new phone session, not re-published
--   bot  enabled bot with a device row (target) and the bot caller
--   nac  never activated (no access), reaches bob
--   gon  published, then its active session row is removed
--   out  published, then its auth session is signed out

-- fixtures -----------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000013d00' || case n
    when 'ann' then '01' when 'bob' then '02' when 'far' then '03' when 'nal' then '04'
    when 'stl' then '05' when 'bot' then '06' when 'nac' then '07' when 'gon' then '08'
    when 'out' then '09' end)::uuid
$$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'oi-' || n || '@mail.test', now(), json_build_object('full_name', n)::jsonb
    from unnest(array['ann','bob','far','nal','stl','bot','nac','gon','out']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'oi-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('013d0000-0000-0000-0000-' || right(id::text, 12))::uuid, id, now(), now()
    from auth.users where email like 'oi-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  values ('013d0000-0000-0000-0000-0000013df005', u('stl'), now() + interval '1 minute', now());

create function test_as(uid uuid, sid text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', coalesce(sid, '013d0000-0000-0000-0000-' || right(uid::text, 12)))::text, true);
  execute 'set local role authenticated';
end $$;
-- olm_identity as JSON rows, or {"err": "<sqlstate>"}.
create function oi(t uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into r from public.olm_identity(t) c;
  return r;
exception when others then
  return jsonb_build_object('err', sqlstate);
end $$;
grant execute on function u(text), k(text), sig(text), test_as(uuid, text), oi(uuid) to authenticated, anon;
-- What a call could consume, for bob.
create function spent() returns text language sql stable as $$
  select concat_ws('|',
    (select count(*) from app_private.olm_one_time_keys where user_id = u('bob') and claimed_at is not null),
    (select count(*) from app_private.olm_one_time_keys where user_id = u('bob')),
    (select count(*) from app_private.olm_claims),
    (select fallback_used::text from app_private.olm_devices where user_id = u('bob')))
$$;

do $$
declare n text;
begin
  foreach n in array array['ann','bob','far','nal','stl','bot','gon','out'] loop
    perform test_as(u(n));
    perform public.activate_session();
    if n <> 'bot' then
      perform public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n),
        case when n = 'bob' then array[k('bob1'), k('bob2'), k('bob3')] else array[k(n || '1')] end,
        k(n || '-F'));
    end if;
    execute 'reset role';
  end loop;
end $$;
insert into public.conversations(id, title) values ('013dc000-0000-0000-0000-000000000001', 'oi debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled)
  values (u('bot'), '013dc000-0000-0000-0000-000000000001', true);
insert into app_private.olm_devices(user_id, identity_key, signing_key, device_signature, fallback_key, session_id)
  values (u('bot'), k('bot-I'), k('bot-S'), sig('bot'), k('bot-F'), '013d0000-0000-0000-0000-0000013d0006');
insert into public.contacts(owner_id, contact_id) values
  (u('ann'), u('bob')), (u('ann'), u('nal')), (u('ann'), u('stl')), (u('ann'), u('bot')),
  (u('bot'), u('bob')), (u('nac'), u('bob')), (u('ann'), u('gon')), (u('ann'), u('out'));
-- take one condition away from each refused target
delete from app_private.allowlist where email = 'oi-nal@mail.test';
select test_as(u('stl'), '013d0000-0000-0000-0000-0000013df005');
select is(public.activate_session(), true, 'fixture: stl activates its new phone');
reset role;

select is((select count(*) from app_private.olm_devices where user_id in (u('ann'), u('bob'), u('far'), u('nal'), u('stl'))),
  5::bigint, 'fixture: every human target published a device');
select ok(exists(select 1 from app_private.active_sessions where user_id = u('nal')),
  'fixture: nal keeps its live session; only the allowlist row is gone');
select is((select session_id::text from app_private.active_sessions where user_id = u('stl')),
  '013d0000-0000-0000-0000-0000013df005', 'fixture: stl''s new phone holds the active session');
create temp table before as select spent() as s;

-- 1 privileges --------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.olm_identity(uuid)', 'execute'), 'anon cannot execute olm_identity');
select ok(has_function_privilege('authenticated', 'public.olm_identity(uuid)', 'execute'), 'authenticated can');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc
            where oid = 'public.olm_identity(uuid)'::regprocedure),
  'olm_identity is security definer with an empty search_path');
set local role anon;
select throws_ok($$select * from public.olm_identity('00000000-0000-0000-0000-0000013d0002')$$,
  '42501', 'permission denied for function olm_identity', 'anon: permission denied');
reset role;

-- 2 the published row, and nothing consumed ---------------------------------------
select test_as(u('ann'));
select is(oi(u('bob')),
  jsonb_build_array(jsonb_build_object('identity_key', k('bob-I'), 'signing_key', k('bob-S'), 'device_signature', sig('bob'))),
  'ann reads bob''s identity: one row with his published keys');
reset role;
select is((select jsonb_build_array(jsonb_build_object('identity_key', identity_key, 'signing_key', signing_key,
                                                       'device_signature', device_signature))
             from app_private.olm_devices where user_id = u('bob')),
  jsonb_build_array(jsonb_build_object('identity_key', k('bob-I'), 'signing_key', k('bob-S'), 'device_signature', sig('bob'))),
  'and they equal bob''s device row');
select is(spent(), (select s from before), 'no one-time key claimed, no claim logged, fallback unused');
select is(spent(), '0|3|0|false', 'bob still has three free keys and an unused fallback');

-- 3 refusals: 42501 ---------------------------------------------------------------
select test_as(u('bot'));
select is(oi(u('bob')), '{"err":"42501"}', 'a bot caller -> 42501');
reset role;
select test_as(u('nac'));
select is(oi(u('bob')), '{"err":"42501"}', 'a caller without app access -> 42501');
reset role;
select test_as(u('ann'));
select is(oi(u('ann')), '{"err":"42501"}', 'X = self -> 42501');
select is(oi(u('nal')), '{"err":"42501"}', 'X not on the allowlist -> 42501');
select is(oi(u('far')), '{"err":"42501"}', 'X not reachable -> 42501');
select is(oi(null), '{"err":"42501"}', 'a null target -> 42501');
-- 4 no rows -------------------------------------------------------------------------
select is(oi(u('bot')), '[]', 'X is a bot -> no rows');
select is(oi(u('stl')), '[]', 'X''s device is stale behind a newer live session -> no rows');
reset role;
-- 4b no live session: no rows, no error (test_writer draft, checked)
select test_as(u('ann'));
select is((oi(u('gon'))->0->>'identity_key'), k('gon-I'), 'control: gon answers while live');
select is((oi(u('out'))->0->>'identity_key'), k('out-I'), 'control: out answers while live');
reset role;

delete from app_private.active_sessions where user_id = u('gon');
delete from auth.sessions where user_id = u('out');

select ok(not exists(select 1 from app_private.active_sessions where user_id = u('gon')), 'fixture: gon has no active session');
select ok(not exists(select 1 from auth.sessions where user_id = u('out')), 'fixture: out has no auth session');

select test_as(u('ann'));
select is(oi(u('gon')), '[]', 'gon has no active session -> 0 rows, no error');
select is(oi(u('out')), '[]', 'out''s session was signed out -> 0 rows, no error');
reset role;

select test_as(u('ann'));
-- 5 not rate limited ------------------------------------------------------------------
select is((select count(*) from generate_series(1, 100) i where oi(u('bob')) ? 'err'), 0::bigint,
  '100 calls in a row: no error, no RLMT1');
select is(oi(u('bob')) -> 0 ->> 'identity_key', k('bob-I'), 'and the 101st still answers');
reset role;
select is(spent(), (select s from before), 'after 102 calls bob''s keys are still untouched');

-- the twins: give far reach and nal its allowlist row back -- each then answers
insert into public.contacts(owner_id, contact_id) values (u('ann'), u('far'));
insert into app_private.allowlist(email) values ('oi-nal@mail.test');
select test_as(u('ann'));
select is(oi(u('far')) -> 0 ->> 'identity_key', k('far-I'), 'control: once ann reaches far, far answers');
select is(oi(u('nal')) -> 0 ->> 'identity_key', k('nal-I'), 'control: once nal is allowed again, nal answers');
reset role;

select * from finish();
rollback;
