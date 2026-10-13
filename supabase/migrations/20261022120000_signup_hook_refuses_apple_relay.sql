-- Sign-up gate: refuse Apple's hidden-email relay addresses.
--
-- Sign in with Apple arrives on the iPhone (v0.31). A person who hides their
-- email in Apple's sign-in gets a random @privaterelay.appleid.com address that
-- is on no allowlist and cannot be matched to a Google account. It is refused
-- here, before any user exists, so nothing is stored. The app also refuses it
-- earlier, on the phone, with its own message; this is the server backstop.
--
-- An existing user's sign-in never reaches this hook (it runs only when Auth
-- would create a user), so a real Apple email that matches an existing Google
-- account links to it. create or replace keeps the privileges granted in
-- 20261005120000_allowlist_signup_hook.sql.
create or replace function app_private.before_user_created(event jsonb) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  google_only constant boolean := false;
  addr        text := nullif(lower(btrim(event -> 'user' ->> 'email')), '');
  refuse      constant jsonb := jsonb_build_object('error',
                jsonb_build_object('http_code', 403, 'message', 'not invited'));
begin
  if google_only
     and event -> 'user' -> 'app_metadata' ->> 'provider' is distinct from 'google' then
    return refuse;
  end if;
  if addr is null
     or split_part(addr, '@', 2) in ('example.com', 'example.net', 'example.org',
                                     'privaterelay.appleid.com') then
    return refuse;
  end if;
  if exists (select 1 from app_private.allowlist where email = addr) then
    return '{}'::jsonb;
  end if;
  return refuse;
end $$;
