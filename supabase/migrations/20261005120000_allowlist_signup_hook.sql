-- 1. Sign-up gate: Supabase Auth's "before user created" hook.
--
-- Anyone who completed Google sign-in used to get an auth.users row and a
-- profile (Play's pre-launch robots made eleven on 2026-09-21), even though
-- the allowlist then denied them. Auth now asks this function before it
-- creates a user. A refused address leaves no auth.users, identity, profile
-- or session row: the user is never inserted.
--
-- Allowed only when ALL hold: the address is not on a reserved test domain
-- (example.com, .net, .org: IANA-reserved, they receive no mail, and the SIS
-- Bot lives there; refused even when allowlisted), and the normalised address
-- (trimmed, lower case, as app_private.is_allowed()) is on the allowlist.
-- Provider: google_only below refuses any non-Google sign-up. It is off
-- (decided 2026-10-05): the hosted email provider is being turned off, and
-- Apple sign-in arrives in v0.31; switching it on is a one-line change.
--
-- Fail closed: an error in this function is an error in Auth (HTTP 500) and
-- creates nobody; there is no catch-all that allows. Break-glass: switch the
-- hook off in the dashboard (Authentication > Hooks); has_app_access() still
-- denies every stranger, so the table stays the real gate.
--
-- Scope, verified on gotrue v2.196.0: it runs only when Auth would CREATE a
-- user. An existing user's sign-in and refresh never reach it, a Google
-- sign-in that links to an existing user creates nobody, and the admin API
-- (POST /auth/v1/admin/users) does not run it. The SIS Bot is created through
-- that admin API, and its reserved-domain address is refused here for every
-- public path, allowlist row or not: no sign-up or generated link creates it.
--
-- Wiring: supabase/config.toml [auth.hook.before_user_created] (left off
-- locally, where the integration fixtures sign up through email) and, in
-- production, the dashboard or Management API; neither is in this file.
-- Runs as supabase_auth_admin (security invoker), which may read the
-- allowlist and nothing else in app_private.
create function app_private.before_user_created(event jsonb) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  google_only constant boolean := false;
  addr        text := lower(btrim(event -> 'user' ->> 'email'));
  refuse      constant jsonb := jsonb_build_object('error',
                jsonb_build_object('http_code', 403, 'message', 'not invited'));
begin
  if google_only
     and event -> 'user' -> 'app_metadata' ->> 'provider' is distinct from 'google' then
    return refuse;
  end if;
  if addr is null
     or split_part(addr, '@', 2) in ('example.com', 'example.net', 'example.org') then
    return refuse;
  end if;
  if exists (select 1 from app_private.allowlist where email = addr) then
    return '{}'::jsonb;
  end if;
  return refuse;
end $$;

revoke all on function app_private.before_user_created(jsonb)
  from public, anon, authenticated;
grant usage on schema app_private to supabase_auth_admin;
grant execute on function app_private.before_user_created(jsonb) to supabase_auth_admin;
grant select on table app_private.allowlist to supabase_auth_admin;
create policy allowlist_signup_hook on app_private.allowlist
  for select to supabase_auth_admin using (true);

-- 2. deleted_attachments hygiene (security re-gate of 0.30.8, findings L1, L2).
--
-- L2: a deleter's record never expired, so it could read or delete a LATER
-- object uploaded at the same path while no message showed it. The record now
-- carries the time it was written, and only an object that already existed
-- then (created_at <= recorded_at) is removable through it. Existing rows get
-- the migration time, later than every object they name.
alter table app_private.deleted_attachments
  add column recorded_at timestamptz not null default now();

create or replace function app_private.may_remove_attachment(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1
                   from app_private.deleted_attachments d
                   join storage.objects o
                     on o.bucket_id = 'attachments' and o.name = d.path
                  where d.path = object_name
                    and d.user_id = auth.uid()
                    and o.created_at <= d.recorded_at)
     and not exists (select 1 from public.messages m
                      where m.attachment_path = object_name)
$$;

-- L1: deleting a message whose path had been recorded before (the path was
-- re-used by a hand-crafted send) kept the FIRST deleter's record, orphaning
-- the new one. The latest deletion now owns the record and restarts its clock.
-- delete_message as in 20261003120000 (released, never edited), plus that.
create or replace function public.delete_message(message uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.deleted is not null
     or not app_private.is_member(m.conversation_id)
     or not (m.sender_id = auth.uid()
             or (app_private.is_admin(m.conversation_id)
                 and app_private.message_readable(m))) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if m.attachment_path is not null then
    insert into app_private.deleted_attachments(path, user_id)
    values (m.attachment_path, auth.uid())
    on conflict (path) do update
      set user_id = excluded.user_id, recorded_at = now();
  end if;
  update public.messages
     set body = '',
         attachment_path = null,
         attachment_preview = null,
         edited_at = null,
         deleted = 'placeholder',
         deleted_at = now(),
         deleted_by = auth.uid()
   where id = message;
  return m.attachment_path;
end $$;
