-- Delete my account: tables, Vault key, HMAC helper (part 1).

-- one row per pending deletion; the row cascades away when the auth user is deleted
create table app_private.account_deletions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  request_id uuid not null unique default gen_random_uuid(),
  requested_at timestamptz not null default now(),
  due_at timestamptz not null,
  channel text not null default 'app',
  attempts int not null default 0,
  claimed_at timestamptz
);
create index account_deletions_due_idx on app_private.account_deletions(due_at);

-- the deletion record the law asks us to keep; no user id on purpose
create table app_private.account_deletion_log (
  request_id uuid primary key,
  email_hmac text not null,
  requested_at timestamptz not null,
  due_at timestamptz not null,
  done_at timestamptz,
  channel text not null,
  outcome text not null check (outcome in ('pending','done','cancelled'))
);
create index account_deletion_log_requested_at_idx on app_private.account_deletion_log(requested_at);

-- set by the apple-revoke edge function after Apple accepted the token revoke
create table app_private.apple_revocations (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revoked_at timestamptz not null default now()
);

alter table app_private.account_deletions enable row level security;
revoke all on table app_private.account_deletions from public, anon, authenticated;
alter table app_private.account_deletion_log enable row level security;
revoke all on table app_private.account_deletion_log from public, anon, authenticated;
alter table app_private.apple_revocations enable row level security;
revoke all on table app_private.apple_revocations from public, anon, authenticated;

-- the HMAC key lives only in Vault; created here once, so nobody has to set it by hand
do $$
begin
  if not exists (select 1 from vault.secrets where name in ('deletion_log_key')) then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'deletion_log_key');
  end if;
end $$;

create function app_private.deletion_email_hmac(addr text) returns text
language plpgsql security definer set search_path = ''
as $$
declare k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name in ('deletion_log_key');
  if k is null then raise exception 'deletion log key missing'; end if;
  return encode(extensions.hmac(lower(btrim(coalesce(addr, ''))), k, 'sha256'), 'hex');
end $$;
revoke all on function app_private.deletion_email_hmac(text) from public, anon, authenticated;

-- Signing in again cancels a pending deletion (called by both activate functions below).
create function app_private.cancel_account_deletion(uid uuid) returns void language plpgsql security definer set search_path = ''
as $$
declare rid uuid;
begin
  delete from app_private.account_deletions where user_id = uid returning request_id into rid;
  if rid is not null then
    update app_private.account_deletion_log set outcome = 'cancelled', done_at = now() where request_id = rid;
  end if;
end;
$$;
revoke all on function app_private.cancel_account_deletion(uuid) from public, anon, authenticated;

-- Errors: 42501 not permitted (also owner, bot, bridge and staff accounts), P0001 'REAUTH' (sign-in older than 10 minutes), P0001 'APPLE_REVOKE_REQUIRED'.
-- Returns when the account will be removed (29 days). Idempotent while pending.
create function public.request_account_deletion() returns timestamptz language plpgsql volatile security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  due timestamptz;
  rid uuid;
  addr text;
  sess_at timestamptz;
begin
  if uid is null or not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select due_at into due from app_private.account_deletions where user_id = uid;
  if found then
    return due;
  end if;
  if exists (select 1 from app_private.owners o where o.user_id = uid)
     or exists (select 1 from app_private.bot_accounts b where b.user_id = uid)
     or exists (select 1 from app_private.admin_view_bridge a where a.user_id = uid)
     or exists (select 1 from app_private.admin_commands c where c.owner_id = uid) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select created_at into sess_at from auth.sessions where id = app_private.jwt_session_id() and user_id = uid;
  if not found or sess_at < now() - interval '10 minutes' then
    raise exception 'REAUTH' using errcode = 'P0001';
  end if;
  if exists (select 1 from auth.identities i where i.user_id = uid and i.provider = 'apple')
     and not exists (select 1 from app_private.apple_revocations r where r.user_id = uid and r.revoked_at > now() - interval '10 minutes') then
    raise exception 'APPLE_REVOKE_REQUIRED' using errcode = 'P0001';
  end if;
  due := now() + interval '29 days';
  select email into addr from auth.users where id = uid;
  insert into app_private.account_deletions(user_id, due_at) values (uid, due) returning request_id into rid;
  insert into app_private.account_deletion_log(request_id, email_hmac, requested_at, due_at, channel, outcome)
    values (rid, app_private.deletion_email_hmac(addr), now(), due, 'app', 'pending');
  -- signed out everywhere at once
  delete from auth.sessions where user_id = uid;
  delete from app_private.active_sessions where user_id = uid;
  delete from app_private.device_tokens where user_id = uid;
  delete from app_private.olm_one_time_keys where user_id = uid;
  return due;
end;
$$;
revoke all on function public.request_account_deletion() from public, anon;
grant execute on function public.request_account_deletion() to authenticated;

-- a pending account deletion is cancelled when the person signs in again
create or replace function public.activate_session_status() returns text
language plpgsql security definer set search_path = '' as $$
declare
  sid     uuid := app_private.jwt_session_id();
  created timestamptz;
begin
  if auth.uid() is not null and not app_private.is_allowed_user() then
    return 'not_allowed';
  end if;
  if auth.uid() is null or sid is null then
    return 'replaced';
  end if;
  select s.created_at into created
    from auth.sessions s
   where s.id = sid and s.user_id = auth.uid();
  if not found then
    return 'replaced';
  end if;
  perform app_private.cancel_account_deletion(auth.uid());
  insert into app_private.active_sessions(user_id, session_id, session_created_at)
  values (auth.uid(), sid, created)
  on conflict (user_id) do update
    set session_id = excluded.session_id, session_created_at = excluded.session_created_at
    where app_private.active_sessions.session_id <> excluded.session_id
      and excluded.session_created_at > app_private.active_sessions.session_created_at;
  return case when exists (select 1 from app_private.active_sessions
                 where user_id = auth.uid() and session_id = sid) then 'active' else 'replaced' end;
end $$;
revoke all on function public.activate_session_status() from public, anon;
grant execute on function public.activate_session_status() to authenticated;

-- same for the old boolean function that old app builds still call
create or replace function public.activate_session() returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  sid     uuid := app_private.jwt_session_id();
  created timestamptz;
begin
  if auth.uid() is null or sid is null or not app_private.is_allowed_user() then
    return false;
  end if;
  select s.created_at into created
    from auth.sessions s
   where s.id = sid and s.user_id = auth.uid();
  if not found then
    return false;
  end if;
  perform app_private.cancel_account_deletion(auth.uid());
  insert into app_private.active_sessions(user_id, session_id, session_created_at)
  values (auth.uid(), sid, created)
  on conflict (user_id) do update
    set session_id = excluded.session_id, session_created_at = excluded.session_created_at
    where app_private.active_sessions.session_id <> excluded.session_id
      and excluded.session_created_at > app_private.active_sessions.session_created_at;
  return exists (select 1 from app_private.active_sessions
                 where user_id = auth.uid() and session_id = sid);
end $$;
revoke all on function public.activate_session() from public, anon;
grant execute on function public.activate_session() to authenticated;

-- Called by the account-deletion and apple-revoke edge functions with the service role.
create function public.account_deletion_claim(batch int)
  returns table(user_id uuid, request_id uuid)
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
begin
  return query
    update app_private.account_deletions d
    set attempts = d.attempts + 1, claimed_at = now()
    where d.user_id in (
      select a.user_id
      from app_private.account_deletions a
      where a.due_at <= now()
        and (a.claimed_at is null or a.claimed_at < now() - interval '15 minutes')
      order by a.due_at
      limit greatest(least(batch, 20), 1)
      for update skip locked
    )
    returning d.user_id, d.request_id;
end;
$$;
revoke all on function public.account_deletion_claim(int) from public, anon, authenticated;
grant execute on function public.account_deletion_claim(int) to service_role;

-- false = cancelled or not due: the caller must not delete the account
create function public.account_deletion_prepare(uid uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
begin
  if not exists (
    select 1 from app_private.account_deletions d
    where d.user_id = uid and d.due_at <= now()
  ) then
    return false;
  end if;

  -- the person's messages go with the account: queue their files for the storage sweeper
  insert into app_private.storage_removal_queue(bucket, path)
    select 'attachments', m.attachment_path
    from public.messages m
    where m.sender_id = uid and m.attachment_path is not null
  union all
    select 'attachments', m.attachment_path || '.t'
    from public.messages m
    where m.sender_id = uid and m.attachment_path is not null
  union all
    select 'attachments', m.attachment_path || '.s'
    from public.messages m
    where m.sender_id = uid and m.attachment_path is not null
  on conflict (bucket, path) do nothing;

  insert into app_private.storage_removal_queue(bucket, path)
    select 'link-previews', m.conversation_id::text || '/' || m.id::text || '.jpg'
    from public.messages m
    where m.sender_id = uid and (m.link_preview is not null or m.edited_at is not null)
  on conflict (bucket, path) do nothing;

  insert into app_private.storage_removal_queue(bucket, path)
    select 'avatars', p.avatar_path
    from public.profiles p
    where p.user_id = uid and p.avatar_path is not null
  on conflict (bucket, path) do nothing;

  return true;
end;
$$;
revoke all on function public.account_deletion_prepare(uuid) from public, anon, authenticated;
grant execute on function public.account_deletion_prepare(uuid) to service_role;

create function public.account_deletion_done(rid uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
begin
  update app_private.account_deletion_log
  set outcome = 'done', done_at = now()
  where request_id = rid and outcome = 'pending';
end;
$$;
revoke all on function public.account_deletion_done(uuid) from public, anon, authenticated;
grant execute on function public.account_deletion_done(uuid) to service_role;

create function public.mark_apple_revoked(uid uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
begin
  insert into app_private.apple_revocations(user_id, revoked_at)
    values (uid, now())
  on conflict (user_id) do update set revoked_at = now();
end;
$$;
revoke all on function public.mark_apple_revoked(uuid) from public, anon, authenticated;
grant execute on function public.mark_apple_revoked(uuid) to service_role;

-- Of the given ids (at most 200), the ones that no longer exist: the app shows 'Deleted account' for them. Errors: 42501, 22023 (too many).
create function public.missing_users(ids uuid[])
  returns uuid[]
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
begin
  if auth.uid() is null or not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if coalesce(array_length(ids, 1), 0) > 200 then
    raise exception 'too many' using errcode = '22023';
  end if;
  return coalesce(
    (select array_agg(i) from unnest(ids) i where not exists (
      select 1 from auth.users u where u.id = i
    )),
    '{}'::uuid[]
  );
end;
$$;
revoke all on function public.missing_users(uuid[]) from public, anon;
grant execute on function public.missing_users(uuid[]) to authenticated;

-- Posts to the account-deletion function; does nothing where the Vault secrets are not set (local, CI) or nothing is due.
create function app_private.run_account_deletion() returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  url text;
  secret text;
begin
  -- a deletion whose row is gone and which was not cancelled finished, even if the edge function died before reporting
  update app_private.account_deletion_log l set outcome = 'done', done_at = now()
   where l.outcome = 'pending' and l.due_at < now() - interval '1 day'
     and not exists (select 1 from app_private.account_deletions d where d.request_id = l.request_id);
  select decrypted_secret into url from vault.decrypted_secrets where name in ('account_deletion_url');
  select decrypted_secret into secret from vault.decrypted_secrets where name in ('account_deletion_secret');
  if url is null or secret is null then
    return;
  end if;
  if not exists (select 1 from app_private.account_deletions where due_at <= now()) then
    return;
  end if;
  perform net.http_post(
    url := url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json', 'x-deletion-secret', secret),
    timeout_milliseconds := 5000
  );
exception when others then
  -- a bad URL must not stop the cron job; the secret is never logged
  raise warning 'run_account_deletion: %', sqlerrm;
end $$;
revoke all on function app_private.run_account_deletion() from public, anon, authenticated;

-- the law asks for a 3 year record of deletions; older rows go
create function app_private.purge_account_deletion_log() returns void
language sql
security definer
set search_path = ''
as $$
  delete from app_private.account_deletion_log where coalesce(done_at, requested_at) < now() - interval '3 years 1 month';
$$;
revoke all on function app_private.purge_account_deletion_log() from public, anon, authenticated;

-- hourly: ask the edge function to remove accounts whose 29 days are over
select cron.schedule('account-deletion', '7 * * * *', 'select app_private.run_account_deletion()');
-- 03:23 every day: drop deletion records older than 3 years
select cron.schedule('account-deletion-log-purge', '23 3 * * *', 'select app_private.purge_account_deletion_log()');
