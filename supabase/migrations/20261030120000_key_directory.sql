-- Private Chats step 3 key directory
-- tables are private (no grants, RLS on, no policy, not in supabase_realtime)
-- only the RPCs below touch them.

alter table app_private.tag_lookups drop constraint tag_lookups_kind_check;
alter table app_private.tag_lookups add constraint tag_lookups_kind_check check (kind in ('find','availability','contacts','olm_publish'));

create table app_private.olm_devices (
  user_id uuid primary key references auth.users(id) on delete cascade,
  identity_key text not null check (identity_key ~ '^[A-Za-z0-9+/]{43}$'),
  signing_key text not null check (signing_key ~ '^[A-Za-z0-9+/]{43}$' and signing_key <> identity_key),
  device_signature text not null check (device_signature ~ '^[A-Za-z0-9+/]{86}$'),
  fallback_key text check (fallback_key is null or fallback_key ~ '^[A-Za-z0-9+/]{43}$'),
  fallback_used boolean not null default false,
  session_id uuid not null,
  published_at timestamptz not null default now()
);

-- A claimed row stays as a tombstone so a re-publish of the same key is a no-op.
create table app_private.olm_one_time_keys (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  key text not null check (key ~ '^[A-Za-z0-9+/]{43}$'),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique (user_id, key)
);
create index olm_otk_free_idx on app_private.olm_one_time_keys(user_id, id) where claimed_at is null;

create table app_private.olm_claims (
  claimer uuid not null references auth.users(id) on delete cascade,
  target uuid not null references auth.users(id) on delete cascade,
  called_at timestamptz not null default now()
);
create index olm_claims_claimer_idx on app_private.olm_claims(claimer, called_at);
create index olm_claims_pair_idx on app_private.olm_claims(claimer, target, called_at);

revoke all on app_private.olm_devices from public, anon, authenticated;
alter table app_private.olm_devices enable row level security;

revoke all on app_private.olm_one_time_keys from public, anon, authenticated;
alter table app_private.olm_one_time_keys enable row level security;

revoke all on app_private.olm_claims from public, anon, authenticated;
alter table app_private.olm_claims enable row level security;

-- Publish (or re-publish) this phone's keys. The same call with an empty key
-- list just rebinds the live session and reports how many keys are free.
-- Errors: 42501 not permitted, RLMT1 over 30 calls an hour, 22023 bad input.
create or replace function public.publish_olm_keys(
  p_identity_key text, p_signing_key text, p_device_signature text,
  p_one_time_keys text[], p_fallback_key text default null
) returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  me  uuid := auth.uid();
  dev app_private.olm_devices%rowtype;
  n   int;
begin
  if app_private.is_bot(me) or not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('publish_olm_keys:' || me::text, 0));

  delete from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'olm_publish' and t.called_at < now() - interval '1 hour';
  insert into app_private.tag_lookups(user_id, kind) values (me, 'olm_publish');
  select count(*) into n from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'olm_publish' and t.called_at >= now() - interval '1 hour';
  if n > 30 then
    raise exception 'too many requests' using errcode = 'RLMT1';
  end if;

  if p_identity_key is null or p_signing_key is null or p_device_signature is null
     or p_one_time_keys is null
     or p_identity_key !~ '^[A-Za-z0-9+/]{43}$' or p_signing_key !~ '^[A-Za-z0-9+/]{43}$'
     or p_identity_key = p_signing_key
     or p_device_signature !~ '^[A-Za-z0-9+/]{86}$'
     or cardinality(p_one_time_keys) > 100
     or exists (select 1 from unnest(p_one_time_keys) k where k is null or k !~ '^[A-Za-z0-9+/]{43}$')
     or (select count(distinct k) from unnest(p_one_time_keys) k) <> cardinality(p_one_time_keys)
     or (p_fallback_key is not null
         and (p_fallback_key !~ '^[A-Za-z0-9+/]{43}$' or p_fallback_key = p_identity_key
              or p_fallback_key = any(p_one_time_keys))) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  select * into dev from app_private.olm_devices where user_id = me for update;
  -- The same device means BOTH keys match; one differing key is a new device.
  if not found or dev.identity_key <> p_identity_key or dev.signing_key <> p_signing_key then
    delete from app_private.olm_one_time_keys where user_id = me;
    insert into app_private.olm_devices(user_id, identity_key, signing_key, device_signature,
                                        fallback_key, fallback_used, session_id)
    values (me, p_identity_key, p_signing_key, p_device_signature, p_fallback_key, false,
            app_private.jwt_session_id())
    on conflict (user_id) do update set
      identity_key = excluded.identity_key, signing_key = excluded.signing_key,
      device_signature = excluded.device_signature, fallback_key = excluded.fallback_key,
      fallback_used = false, session_id = excluded.session_id, published_at = now();
  else
    update app_private.olm_devices set
      device_signature = p_device_signature,
      session_id = app_private.jwt_session_id(),
      published_at = now(),
      fallback_key = coalesce(p_fallback_key, fallback_key),
      fallback_used = case when p_fallback_key is not null then false else fallback_used end
     where user_id = me;
  end if;

  -- shortcut: tombstones kept a year; a phone offline longer re-publishes at worst
  delete from app_private.olm_one_time_keys where user_id = me and claimed_at < now() - interval '1 year';

  insert into app_private.olm_one_time_keys(user_id, key)
    select me, k from unnest(p_one_time_keys) k
    on conflict (user_id, key) do nothing;

  select count(*) into n from app_private.olm_one_time_keys where user_id = me and claimed_at is null;
  if n > 100 then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  return n;
end $$;
revoke all on function public.publish_olm_keys(text, text, text, text[], text) from public, anon;
grant execute on function public.publish_olm_keys(text, text, text, text[], text) to authenticated;

-- Claim one of target's one-time keys to open a chat. Returns the device keys
-- and signature (the caller's phone verifies the signature) plus one key:
-- a free one-time key, else the fallback key. No rows when the target has no
-- live device. The target must pass the same reach test as starting a chat and
-- be on the allowlist; every refusal is the same 42501 so ids cannot be probed.
-- Errors: 42501 not permitted, RLMT1 over 60 claims an hour or 5 per target.
create or replace function public.claim_olm_keys(target uuid)
returns table (identity_key text, signing_key text, device_signature text,
               one_time_key text, is_fallback boolean)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me     uuid := auth.uid();
  dev    app_private.olm_devices%rowtype;
  otk    text;
  n      int;
  n_pair int;
begin
  if app_private.is_bot(me) or not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if target is null or target = me or not app_private.is_allowed(target)
     or not app_private.can_reach(target) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('claim_olm_keys:' || me::text, 0));

  -- Every call that passed the gates counts, even one that returns nothing.
  delete from app_private.olm_claims c where c.claimer = me and c.called_at < now() - interval '1 hour';
  insert into app_private.olm_claims(claimer, target) values (me, target);
  select count(*) into n from app_private.olm_claims c where c.claimer = me;
  select count(*) into n_pair from app_private.olm_claims c
   where c.claimer = me and c.target = claim_olm_keys.target;
  if n > 60 or n_pair > 5 then
    raise exception 'too many requests' using errcode = 'RLMT1';
  end if;

  if app_private.is_bot(target) then
    return;
  end if;

  -- Only a device bound to the target's live session. No live session at all is
  -- refused (42501); a stale device behind a live session hands out nothing.
  select d.* into dev
    from app_private.olm_devices d
    join app_private.active_sessions s on s.user_id = d.user_id and s.session_id = d.session_id
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
   where d.user_id = target;
  if not found then
    if not exists (select 1 from app_private.active_sessions s
                    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
                   where s.user_id = target) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
    return;
  end if;

  -- shortcut: if a parallel claim holds the first row, skip locked may fall
  -- through to the fallback key; the pool is topped up on the next app start.
  update app_private.olm_one_time_keys k set claimed_at = now()
   where k.id = (select f.id from app_private.olm_one_time_keys f
                  where f.user_id = target and f.claimed_at is null
                  order by f.id limit 1 for update skip locked)
  returning k.key into otk;
  if otk is not null then
    return query select dev.identity_key, dev.signing_key, dev.device_signature, otk, false;
    return;
  end if;

  if dev.fallback_key is not null then
    update app_private.olm_devices d set fallback_used = true where d.user_id = target;
    return query select dev.identity_key, dev.signing_key, dev.device_signature, dev.fallback_key, true;
  end if;
end $$;
revoke all on function public.claim_olm_keys(uuid) from public, anon;
grant execute on function public.claim_olm_keys(uuid) to authenticated;

-- The caller's own device row: lets the phone top up, and tell a first run
-- from an identity reset (a server row but no key on the phone).
-- No row = nothing published. Errors: 42501 not permitted.
create or replace function public.olm_key_status()
returns table (has_device boolean, identity_key text, signing_key text,
               one_time_keys integer, has_fallback boolean, fallback_used boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if app_private.is_bot(auth.uid()) or not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query
    select true, d.identity_key, d.signing_key,
           (select count(*)::int from app_private.olm_one_time_keys k
             where k.user_id = d.user_id and k.claimed_at is null),
           d.fallback_key is not null, d.fallback_used
      from app_private.olm_devices d where d.user_id = auth.uid();
end $$;
revoke all on function public.olm_key_status() from public, anon;
grant execute on function public.olm_key_status() to authenticated;
