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

-- Files of a person, noted by account_deletion_prepare and handed to the storage sweeper only after the account is really deleted (account_deletion_done); a cancel drops them.
create table app_private.account_deletion_files (
  request_id uuid not null,
  bucket text not null,
  path text not null,
  primary key (request_id, bucket, path)
);
-- who the request was for, until the deletion is final (the log itself has no user id)
create table app_private.account_deletion_after (
  request_id uuid primary key,
  user_id uuid not null,
  email text   -- lower-cased address read by prepare, only so the audit clean-up can find e-mail-only rows; dropped by account_deletion_done
);
alter table app_private.account_deletion_files enable row level security;
revoke all on table app_private.account_deletion_files from public, anon, authenticated;
alter table app_private.account_deletion_after enable row level security;
revoke all on table app_private.account_deletion_after from public, anon, authenticated;

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
    -- the notes (files, user id, e-mail) are kept: a delete that was already under way may still finish, and account_deletion_done cleans up whenever the account is really gone. Done / the hourly sweep drop them when the account still exists.
    update app_private.account_deletion_log set outcome = 'cancelled', done_at = now() where request_id = rid;
  end if;
end;
$$;
revoke all on function app_private.cancel_account_deletion(uuid) from public, anon, authenticated;

-- Errors: 42501 not permitted (also owner, bot, bridge and staff accounts), P0001 'REAUTH' (sign-in older than 10 minutes), P0001 'APPLE_REVOKE_REQUIRED'.
-- Returns when the account will be removed (30 days minus 1 hour, so the hourly job ends inside 30 days). Idempotent while pending.
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
  due := now() + interval '30 days' - interval '1 hour';
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

-- false = cancelled or not due: the caller must not delete the account. Called right before deleteUser, so it is also the last check.
create function public.account_deletion_prepare(uid uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  rid uuid;
begin
  select d.request_id into rid from app_private.account_deletions d
   where d.user_id = uid and d.due_at <= now();
  if rid is null then
    return false;
  end if;

  insert into app_private.account_deletion_after(request_id, user_id, email)
  values (rid, uid, (select lower(btrim(u.email)) from auth.users u where u.id = uid))
  on conflict (request_id) do nothing;

  -- the person's messages go with the account. Their files are only NOTED here; the storage sweeper gets them in account_deletion_done, after the account is really gone (a cancel must never lose a file).
  insert into app_private.account_deletion_files(request_id, bucket, path)
    select rid, 'attachments', m.attachment_path
    from public.messages m
    where m.sender_id = uid and m.attachment_path is not null
  union
    select rid, 'attachments', m.attachment_path || '.t'
    from public.messages m
    where m.sender_id = uid and m.attachment_path is not null
  union
    select rid, 'attachments', m.attachment_path || '.s'
    from public.messages m
    where m.sender_id = uid and m.attachment_path is not null
  union
    select rid, 'link-previews', m.conversation_id::text || '/' || m.id::text || '.jpg'
    from public.messages m
    where m.sender_id = uid and (m.link_preview is not null or m.edited_at is not null)
  union
    select rid, 'avatars', p.avatar_path
    from public.profiles p
    where p.user_id = uid and p.avatar_path is not null
  on conflict (request_id, bucket, path) do nothing;

  return true;
end;
$$;
revoke all on function public.account_deletion_prepare(uuid) from public, anon, authenticated;
grant execute on function public.account_deletion_prepare(uuid) to service_role;

-- Called after deleteUser. Cleans up when the account is really gone (no auth.users row), whatever the log says (a cancel that lost the race), or when the request is still pending: removes Auth's audit rows naming the person (by user id and by e-mail, the e-mail from prepare's note or addr), hands the noted files to the storage sweeper, drops the notes and marks the log done. While the account still exists nothing is queued or removed (the person signed in again); a cancelled request's notes are dropped then.
create function public.account_deletion_done(rid uuid, addr text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  uid uuid;
  mail text;
  state text;
begin
  select l.outcome into state from app_private.account_deletion_log l where l.request_id = rid;
  select a.user_id, a.email into uid, mail from app_private.account_deletion_after a where a.request_id = rid;
  if uid is null then
    -- no note: only the log can be settled (old behaviour)
    update app_private.account_deletion_log set outcome = 'done', done_at = now()
     where request_id = rid and outcome = 'pending';
    return;
  end if;
  -- the account still exists and the request is not pending (cancelled: the person signed in again): nothing is cleaned
  if exists (select 1 from auth.users u where u.id = uid) and state is distinct from 'pending' then
    if state = 'cancelled' then
      delete from app_private.account_deletion_files where request_id = rid;
      delete from app_private.account_deletion_after where request_id = rid;
    end if;
    return;
  end if;
  mail := nullif(lower(btrim(coalesce(addr, mail))), '');
  delete from auth.audit_log_entries e
   where e.payload ->> 'actor_id' = uid::text
      or e.payload -> 'traits' ->> 'user_id' = uid::text
      or (mail is not null and (lower(e.payload ->> 'actor_username') = mail or lower(e.payload -> 'traits' ->> 'user_email') = mail));
  insert into app_private.storage_removal_queue(bucket, path)
    select f.bucket, f.path from app_private.account_deletion_files f where f.request_id = rid
  on conflict (bucket, path) do nothing;
  delete from app_private.account_deletion_files where request_id = rid;
  delete from app_private.account_deletion_after where request_id = rid;
  update app_private.account_deletion_log
  set outcome = 'done', done_at = now()
  where request_id = rid and outcome in ('pending', 'cancelled');
end;
$$;
revoke all on function public.account_deletion_done(uuid, text) from public, anon, authenticated;
grant execute on function public.account_deletion_done(uuid, text) to service_role;

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
  rid uuid;
begin
  -- a deletion whose row is gone and which was not cancelled finished, even if the edge function died before reporting
  for rid in
    select l.request_id from app_private.account_deletion_log l
     where l.outcome = 'pending'
       and not exists (select 1 from app_private.account_deletions d where d.request_id = l.request_id)
    union
    -- a noted deletion whose account is gone (finish the clean-up), or a cancelled one older than an hour (drop its notes)
    select a.request_id from app_private.account_deletion_after a
      left join app_private.account_deletion_log l on l.request_id = a.request_id
     where not exists (select 1 from auth.users u where u.id = a.user_id)
        or (l.outcome = 'cancelled' and l.done_at < now() - interval '1 hour')
  loop
    perform public.account_deletion_done(rid);
  end loop;
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

-- hourly: ask the edge function to remove accounts whose wait (30 days minus 1 hour) is over
select cron.schedule('account-deletion', '7 * * * *', 'select app_private.run_account_deletion()');
-- 03:23 every day: drop deletion records older than 3 years
select cron.schedule('account-deletion-log-purge', '23 3 * * *', 'select app_private.purge_account_deletion_log()');

-- public.chat_gone_peers(): the other person of a 1:1 whose account is gone (no member row, no auth user), for the one remaining member only: the app then shows "Deleted account".
-- The id comes from conversations.direct_key ('<smaller uuid>:<larger uuid>'); the caller already knew it.
create function public.chat_gone_peers()
returns table(conversation_id uuid, user_id uuid)
language sql stable security definer set search_path = ''
as $$
  select c.id, p.other
    from public.conversations c
    join public.conversation_members me
      on me.conversation_id = c.id and me.user_id = auth.uid() and me.left_at is null
    cross join lateral (
      select case
        when c.direct_key ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
        then (case when split_part(c.direct_key, ':', 1) = auth.uid()::text
                   then split_part(c.direct_key, ':', 2)
                   else split_part(c.direct_key, ':', 1) end)::uuid
      end as other
    ) p
   where c.direct_key is not null
     and p.other is not null
     and p.other <> auth.uid()
     and (select app_private.has_app_access())
     and auth.uid()::text in (split_part(c.direct_key, ':', 1), split_part(c.direct_key, ':', 2))
     and not exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = p.other)
     and not exists (select 1 from auth.users u where u.id = p.other);
$$;
revoke all on function public.chat_gone_peers() from public, anon;
grant execute on function public.chat_gone_peers() to authenticated;

-- adds gone_peers: the id of a 1:1 partner whose account is deleted (a new key; old apps ignore it).
CREATE OR REPLACE FUNCTION public.chat_list()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
SELECT jsonb_build_object(
  'members', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id, user_id, left_at, color_slot, role
      from public.conversation_members
    ) x
  ), '[]'::jsonb),
  'conversations', coalesce((
    -- Exactly the columns the app reads (a whitelist, same output as before); every other column stays server-side.
    select jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'avatar_path', c.avatar_path, 'system', c.system, 'members_can_set_avatar', c.members_can_set_avatar, 'members_can_add', c.members_can_add, 'new_members_see_history', c.new_members_see_history, 'pinned_message_id', c.pinned_message_id, 'members_can_pin', c.members_can_pin, 'admin_chat', c.admin_chat, 'closed_at', c.closed_at, 'debug_chat', c.debug_chat, 'staff_key', c.staff_key))
    from public.conversations c
  ), '[]'::jsonb),
  'archives', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id
      from public.chat_archives
    ) x
  ), '[]'::jsonb),
  'pins', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id
      from public.chat_pins
    ) x
  ), '[]'::jsonb),
  'hides', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id
      from public.chat_hides
    ) x
  ), '[]'::jsonb),
  'profiles', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select user_id, display_name, avatar_path
      from public.profiles_public()
      where user_id in (
        select cm.user_id
        from public.conversation_members cm
        where cm.user_id <> (select auth.uid())
      )
    ) x
  ), '[]'::jsonb),
  'previews', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id, body, created_at, attachment_path, sender_id, deleted, poll, contact, attachment_name, attachment_duration_ms, location_lat, attachment_mime, sticker_id, sticker_album, admin_msg, olm_type, has_ciphertext
      from public.conversation_previews
    ) x
  ), '[]'::jsonb),
  'unread', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id, unread
      from public.unread_counts()
    ) x
  ), '[]'::jsonb),
  'gone_peers', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id, user_id
      from public.chat_gone_peers()
    ) x
  ), '[]'::jsonb)
);
$$;

REVOKE ALL ON FUNCTION public.chat_list() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.chat_list() TO authenticated;
