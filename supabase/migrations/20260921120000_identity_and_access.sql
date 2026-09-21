-- Identity, access gate and update policy for SIS v0.1.
-- Replaces the previous schema in one forward migration. Enabled allowlist
-- rows and existing profiles are preserved.

-- Preserve enabled allowlist emails from the previous schema, if it exists.
create temp table _keep_allowlist (email text);
do $$
begin
  if to_regclass('app_private.allowlist') is null then
    return;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'app_private' and table_name = 'allowlist'
               and column_name = 'enabled') then
    execute 'insert into _keep_allowlist select lower(btrim(email::text)) from app_private.allowlist where enabled';
  else
    execute 'insert into _keep_allowlist select lower(btrim(email::text)) from app_private.allowlist';
  end if;
end $$;

drop trigger if exists create_profile_after_signup on auth.users;
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists app_private.create_profile_for_user() cascade;
drop function if exists public.handle_new_user() cascade;
drop function if exists public.activate_session() cascade;
drop schema if exists app_private cascade;
drop table if exists public.profiles cascade;
drop table if exists public.app_config cascade;

-- Private authority ---------------------------------------------------------
create schema app_private;
revoke all on schema app_private from public, anon, authenticated;

-- Emails are stored normalised (lower-case, trimmed) and compared against the
-- normalised, CONFIRMED email in auth.users — never against a JWT claim.
create table app_private.allowlist (
  email    text primary key check (email = lower(btrim(email))),
  added_at timestamptz not null default now()
);
create table app_private.active_sessions (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  session_id         uuid not null,
  session_created_at timestamptz not null
);
alter table app_private.allowlist       enable row level security;   -- belt and braces: no policies = no access
alter table app_private.active_sessions enable row level security;
insert into app_private.allowlist(email) select email from _keep_allowlist on conflict do nothing;
drop table _keep_allowlist;

-- The JWT's session id as uuid, or null when absent/malformed (never raises).
create or replace function app_private.jwt_session_id() returns uuid
language sql stable set search_path = '' as $$
  select case
    when c ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    then c::uuid end
  from (select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'session_id' as c) t
$$;
create or replace function app_private.is_allowed_user() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from auth.users u
      join app_private.allowlist a on a.email = lower(btrim(u.email))
     where u.id = auth.uid() and u.email_confirmed_at is not null)
$$;
create or replace function app_private.has_app_access() returns boolean
language sql stable security definer set search_path = '' as $$
  -- The session must still exist in auth.sessions: sign-out or admin
  -- revocation takes effect immediately, not at access-token expiry.
  select app_private.is_allowed_user()
     and exists (select 1
                   from app_private.active_sessions s
                   join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
                  where s.user_id = auth.uid() and s.session_id = app_private.jwt_session_id())
$$;
revoke all on function app_private.jwt_session_id() from public, anon, authenticated;
revoke all on function app_private.is_allowed_user() from public, anon;
revoke all on function app_private.has_app_access() from public, anon;
grant execute on function app_private.is_allowed_user(), app_private.has_app_access() to authenticated;

-- Public surface ------------------------------------------------------------
create table public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 80),
  created_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;
-- Supabase default privileges grant anon/authenticated on new tables; RLS does
-- not cover TRUNCATE, so revoke everything and grant only what is needed.
revoke all on public.profiles from anon, authenticated;
create policy profiles_read on public.profiles for select to authenticated
  using (app_private.has_app_access());

create table public.app_config (
  id                  int primary key check (id = 1),
  min_supported_build int not null check (min_supported_build >= 1)
);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
create policy app_config_read on public.app_config for select to authenticated
  using (app_private.has_app_access());
insert into public.app_config(id, min_supported_build) values (1, 1);

create or replace function app_private.display_name_for(u auth.users) returns text
language sql immutable set search_path = '' as $$
  select left(coalesce(
    nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(u.raw_user_meta_data ->> 'name'), ''),
    nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
    'User'), 80)
$$;
revoke all on function app_private.display_name_for(auth.users) from public, anon, authenticated;
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(user_id, display_name)
  values (new.id, app_private.display_name_for(new))
  on conflict (user_id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
-- Existing users keep a profile across the schema replacement.
insert into public.profiles(user_id, display_name)
  select u.id, app_private.display_name_for(u) from auth.users u
  on conflict (user_id) do nothing;

-- The access gate: claim this JWT's session as the single active one. A
-- different session may replace it only if it was CREATED later (auth.sessions
-- is authoritative; token refreshes keep the same session and never re-claim).
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

grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.app_config to authenticated;
