-- Identity, access gate and update policy for SIS v0.1.
-- Replaces the previous schema: everything is dropped and recreated; allowlist rows are preserved.
create temp table _keep_allowlist as select email::text as email from app_private.allowlist;

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user() cascade;
drop function if exists public.activate_session() cascade;
drop schema if exists app_private cascade;
drop table if exists public.profiles cascade;
drop table if exists public.app_config cascade;

-- Private authority ---------------------------------------------------------
create schema app_private;
revoke all on schema app_private from public, anon, authenticated;

-- Emails are stored normalised (lower-case, trimmed); the JWT email is
-- normalised the same way before comparison. No citext: its operators are
-- not resolvable under search_path = ''.
create table app_private.allowlist (
  email    text primary key check (email = lower(btrim(email))),
  added_at timestamptz not null default now()
);
create table app_private.active_sessions (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  session_id   text not null,
  activated_at timestamptz not null default now()
);
alter table app_private.allowlist       enable row level security;   -- belt and braces: no policies = no access
alter table app_private.active_sessions enable row level security;
insert into app_private.allowlist(email) select lower(btrim(email)) from _keep_allowlist on conflict do nothing;

create or replace function app_private.jwt_email() returns text
language sql stable set search_path = '' as $$
  select lower(btrim(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'))
$$;
create or replace function app_private.jwt_session_id() returns text
language sql stable set search_path = '' as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'session_id'
$$;
create or replace function app_private.is_allowed_user() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.allowlist a where a.email = app_private.jwt_email())
$$;
create or replace function app_private.has_app_access() returns boolean
language sql stable security definer set search_path = '' as $$
  select app_private.is_allowed_user()
     and exists (select 1 from app_private.active_sessions s
                 where s.user_id = auth.uid() and s.session_id = app_private.jwt_session_id())
$$;
revoke all on function app_private.is_allowed_user() from public, anon;
revoke all on function app_private.has_app_access() from public, anon;
grant execute on function app_private.is_allowed_user(), app_private.has_app_access() to authenticated;

-- Public surface ------------------------------------------------------------
create table public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  created_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;
revoke all on public.profiles from anon;   -- Supabase default privileges grant anon; we do not
create policy profiles_read on public.profiles for select to authenticated
  using (app_private.has_app_access());

create table public.app_config (
  id                  int primary key check (id = 1),
  min_supported_build int not null check (min_supported_build >= 1)
);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon;
create policy app_config_read on public.app_config for select to authenticated
  using (app_private.has_app_access());
insert into public.app_config(id, min_supported_build) values (1, 1);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(user_id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- The access gate: claim this JWT's session as the single active one. A
-- different session may replace it only if it was CREATED later (auth.sessions
-- is authoritative; token refreshes keep the same session and never re-claim).
create or replace function public.activate_session() returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  sid     uuid;
  created timestamptz;
begin
  sid := nullif(app_private.jwt_session_id(), '')::uuid;
  if auth.uid() is null or sid is null or not app_private.is_allowed_user() then
    return false;
  end if;
  select s.created_at into created
    from auth.sessions s
   where s.id = sid and s.user_id = auth.uid();
  if not found then
    return false;
  end if;
  insert into app_private.active_sessions(user_id, session_id, activated_at)
  values (auth.uid(), sid::text, created)
  on conflict (user_id) do update
    set session_id = excluded.session_id, activated_at = excluded.activated_at
    where app_private.active_sessions.session_id <> excluded.session_id
      and excluded.activated_at > app_private.active_sessions.activated_at;
  return exists (select 1 from app_private.active_sessions
                 where user_id = auth.uid() and session_id = sid::text);
end $$;
revoke all on function public.activate_session() from public, anon;
grant execute on function public.activate_session() to authenticated;

grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.app_config to authenticated;
