-- Profiles were visible to any active member regardless of whether the profile
-- itself belonged to an allowlisted account. Anyone who completes Google
-- sign-in gets an auth.users row and a profile trigger fires, even though the
-- allowlist then denies them access -- so a production database accumulates
-- profiles for strangers. Google Play's pre-launch robo tests produced seven
-- of them on 2026-09-21.
--
-- The v0.2 member picker reads profiles to offer someone to chat with, which
-- surfaced those names. Scope the read to allowlisted accounts, which also
-- stops any active member enumerating every account that ever signed in.

-- The allowlist check for an ARBITRARY user, not just the caller.
-- is_allowed_user() answers only for auth.uid(); this answers for a row.
create or replace function app_private.is_allowed(uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from auth.users u
      join app_private.allowlist a on a.email = lower(btrim(u.email))
     where u.id = uid and u.email_confirmed_at is not null)
$$;
revoke all on function app_private.is_allowed(uuid) from public, anon;
grant execute on function app_private.is_allowed(uuid) to authenticated;

-- Keep is_allowed_user() as the caller-scoped wrapper so nothing else changes.
create or replace function app_private.is_allowed_user() returns boolean
language sql stable security definer set search_path = '' as $$
  select app_private.is_allowed(auth.uid())
$$;

drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (app_private.has_app_access() and app_private.is_allowed(user_id));
