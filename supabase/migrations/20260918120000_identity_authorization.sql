create schema if not exists app_private;

revoke all on schema app_private from public, anon, authenticated;

create table app_private.allowlist (
  email text primary key check (btrim(email) <> ''),
  normalized_email text generated always as (lower(btrim(email))) stored unique,
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table app_private.active_sessions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  session_id uuid not null unique,
  session_created_at timestamptz not null,
  activated_at timestamptz not null default now()
);

revoke all on all tables in schema app_private from public, anon, authenticated;

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 80),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;

create function app_private.has_app_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users as users
    join auth.sessions as sessions
      on sessions.user_id = users.id
    join app_private.active_sessions as active
      on active.user_id = users.id
     and active.session_id = sessions.id
    join app_private.allowlist as allowed
      on allowed.normalized_email = lower(btrim(users.email))
     and allowed.enabled
    where users.id = auth.uid()
      and users.email_confirmed_at is not null
      and sessions.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
  );
$$;

revoke all on function app_private.has_app_access() from public, anon, authenticated;
grant execute on function app_private.has_app_access() to authenticated;

create function app_private.is_allowed_user(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users as users
    join app_private.allowlist as allowed
      on allowed.normalized_email = lower(btrim(users.email))
     and allowed.enabled
    where users.id = target_user_id
      and users.email_confirmed_at is not null
  );
$$;

revoke all on function app_private.is_allowed_user(uuid) from public, anon, authenticated;
grant execute on function app_private.is_allowed_user(uuid) to authenticated;

create function public.activate_session()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  claimed_session_id uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  claimed_session_created_at timestamptz;
begin
  select sessions.created_at
    into claimed_session_created_at
  from auth.sessions as sessions
  join auth.users as users on users.id = sessions.user_id
  join app_private.allowlist as allowed
    on allowed.normalized_email = lower(btrim(users.email))
   and allowed.enabled
  where sessions.id = claimed_session_id
    and sessions.user_id = caller_id
    and users.email_confirmed_at is not null;

  if not found then
    return false;
  end if;

  insert into app_private.active_sessions (
    user_id,
    session_id,
    session_created_at
  ) values (
    caller_id,
    claimed_session_id,
    claimed_session_created_at
  )
  on conflict (user_id) do update
    set session_id = excluded.session_id,
        session_created_at = excluded.session_created_at,
        activated_at = now()
    where excluded.session_created_at > app_private.active_sessions.session_created_at
       or excluded.session_id = app_private.active_sessions.session_id;

  return exists (
    select 1
    from app_private.active_sessions as active
    where active.user_id = caller_id
      and active.session_id = claimed_session_id
  );
end;
$$;

revoke all on function public.activate_session() from public, anon;
grant execute on function public.activate_session() to authenticated;

create policy "allowed active sessions can read profiles"
on public.profiles
for select
to authenticated
using (
  app_private.has_app_access()
  and app_private.is_allowed_user(user_id)
);

create function app_private.create_profile_for_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, display_name)
  values (
    new.id,
    left(
      coalesce(
        nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
        nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
        'User'
      ),
      80
    )
  );
  return new;
end;
$$;

revoke all on function app_private.create_profile_for_user() from public, anon, authenticated;

create trigger create_profile_after_signup
after insert on auth.users
for each row execute function app_private.create_profile_for_user();
