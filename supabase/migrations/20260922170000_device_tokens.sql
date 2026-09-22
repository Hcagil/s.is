-- Push delivery addresses, for the "push" row of the roadmap.
--
-- This is the half that does not need a vendor credential: storing the token
-- and deciding who should be notified. Actually sending needs a Firebase
-- project and an FCM service account, which only the owner can create, so the
-- sender lives in supabase/functions/notify-on-message and is not deployed.

-- Private, like the allowlist and the active sessions. A push token is a
-- delivery address for a person: it is never readable by another member, and
-- the client never writes it directly.
create table app_private.device_tokens (
  user_id    uuid not null references auth.users(id) on delete cascade,
  token      text not null check (char_length(token) between 10 and 4096),
  platform   text not null check (platform in ('android', 'ios')),
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);
alter table app_private.device_tokens enable row level security;  -- no policies: no access
revoke all on table app_private.device_tokens from anon, authenticated;

-- Claims this token for the caller and drops every other token they had.
--
-- One row per member, on purpose: the same single-active-device rule the
-- session gate enforces. A replaced phone must stop receiving notifications at
-- the moment it stops being able to read the messages they are about.
-- Parameters are prefixed: a parameter named `token` shadows the column of
-- the same name, which Postgres reports as an ambiguous reference.
create or replace function public.register_device_token(
  device_token    text,
  device_platform text
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if device_token is null
     or char_length(device_token) < 10 or char_length(device_token) > 4096
     or device_platform is null
     or device_platform not in ('android', 'ios') then
    raise exception 'invalid device token' using errcode = '22023';
  end if;

  -- One row per member: the single-active-device rule, extended to push.
  delete from app_private.device_tokens d
   where d.user_id = auth.uid() and d.token <> device_token;
  -- A token identifies a handset, not a person. If someone else signs in on
  -- this handset, the previous member must stop receiving message bodies on
  -- it -- otherwise signing out and handing the phone over leaks them.
  delete from app_private.device_tokens d
   where d.token = device_token and d.user_id <> auth.uid();

  insert into app_private.device_tokens(user_id, token, platform)
  values (auth.uid(), device_token, device_platform)
  on conflict (user_id, token) do update
    set platform = excluded.platform, updated_at = now();
end $$;
revoke all on function public.register_device_token(text, text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;

-- Called on sign-out. Deliberately does NOT require has_app_access(): a member
-- whose device was just replaced has already lost access, and must still be
-- able to stop that device receiving notifications.
create or replace function public.forget_device_token(device_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  delete from app_private.device_tokens d
   where d.user_id = auth.uid() and d.token = device_token;
end $$;
revoke all on function public.forget_device_token(text) from public, anon;
grant execute on function public.forget_device_token(text) to authenticated;

-- Who should hear about a message: every OTHER member of its conversation who
-- still holds an active session. Returns the token and the sender's name so
-- the notifier needs no further queries.
--
-- Stays in app_private: it reads across members by design and is never
-- client-callable. Nothing in app_private is exposed through the API.
create or replace function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, sender_name text, body text)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform,
         coalesce(p.display_name, 'Someone'),
         m.body
    from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id <> m.sender_id
    join app_private.device_tokens d on d.user_id = cm.user_id
    join app_private.active_sessions s on s.user_id = cm.user_id
    -- The session must still EXIST, exactly as has_app_access() requires.
    -- active_sessions cascades from auth.users, not from auth.sessions, so it
    -- outlives the session it names. Without this join a revoked phone is
    -- handed the message body for a conversation it can no longer read --
    -- the precise thing the session gate exists to prevent.
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
    left join public.profiles p on p.user_id = m.sender_id
   where m.id = message_id
$$;
revoke all on function app_private.push_targets_for_message(uuid)
  from public, anon, authenticated;

-- The notifier reaches the list through this, on the service-role key.
-- A wrapper rather than a grant on app_private: the edge function gets the one
-- thing it needs instead of the run of the private schema, and app_private
-- stays unreachable from the API for every role.
create or replace function public.push_targets(message_id uuid)
returns table (user_id uuid, token text, platform text, sender_name text, body text)
language sql stable security definer set search_path = '' as $$
  select * from app_private.push_targets_for_message(message_id)
$$;
revoke all on function public.push_targets(uuid) from public, anon, authenticated;
grant execute on function public.push_targets(uuid) to service_role;
