-- Notification buttons (Mark as read, Reply) that work without a session on
-- the phone.
--
-- The background push handler has no Supabase session, so the buttons call
-- the notification-action edge function with a short-lived token the server
-- signed into the push (notify-on-message). The function holds the service
-- role and calls public.notification_action(), which does the work AS the
-- member the token names, by running the existing mark_read() under that
-- member's identity and inserting the reply with the same checks as the
-- messages_send policy. Nothing here is callable by a client role.
--
-- Additive only: one new table, three new functions. Old builds ignore the
-- new push keys and never call any of this.

-- Rate-limit bookkeeping: one row per action taken, pruned per member on use.
create table app_private.notification_action_log (
  user_id uuid not null references auth.users(id) on delete cascade,
  at      timestamptz not null default now()
);
create index notification_action_log_user_idx
  on app_private.notification_action_log (user_id, at desc);
alter table app_private.notification_action_log enable row level security;  -- no policies: no access
revoke all on table app_private.notification_action_log from anon, authenticated;

-- Runs the rest of the CURRENT TRANSACTION as [p_user]: sets the request
-- claims (sub, role and the member's active session) that auth.uid() and
-- app_private.has_app_access() read, so every existing check applies as if
-- the member's own app made the call. It refuses unless the push the token was
-- minted for went to a device that is STILL the member's active one:
-- p_device is the sha256 (hex) of that device's push token, and the member's
-- device_tokens row must still carry it AND be bound to the active session.
-- A phone replaced by a newer sign-in therefore cannot act any more, even
-- with an unexpired token (the one-device rule). set_config(..., true) is
-- transaction-local: each PostgREST call is its own transaction, so the
-- identity never outlives this one call.
create function app_private.act_as(p_user uuid, p_device text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  sid uuid;
begin
  select s.session_id into sid
    from app_private.active_sessions s
    join app_private.device_tokens d
      on d.user_id = s.user_id and d.session_id = s.session_id
   where s.user_id = p_user
     and encode(sha256(convert_to(d.token, 'UTF8')), 'hex') = p_device;
  if sid is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'session_id', sid)::text,
    true);
end $$;
revoke all on function app_private.act_as(uuid, text) from public, anon, authenticated;

-- p_action is 'mark_read' or 'reply'. Returns 'done', or 'duplicate' for a
-- reply whose id is already stored by an earlier identical attempt (a retry
-- after a lost answer: same id, sender, conversation and text is success, any
-- difference is an id conflict).
--
-- Errors (SQLSTATE): 42501 not permitted (no access, device replaced, not a
-- current member, system conversation); 22023 invalid request; 23505 the id
-- belongs to a different message; P0429 rate limited (20 actions per member
-- per rolling minute, both actions counted).
--
-- The insert repeats messages_send (has_app_access, sender = caller,
-- is_member, not a system conversation); text only, so its attachment and
-- reply_to clauses do not apply. If messages_send changes, change this.
create function public.notification_action(
  p_user         uuid,
  p_device       text,
  p_conversation uuid,
  p_action       text,
  p_id           uuid,
  p_body         text
) returns text language plpgsql security definer set search_path = '' as $$
declare
  b       text := btrim(p_body);
  n       int;
  result  text := 'done';
begin
  if p_action not in ('mark_read', 'reply') then
    raise exception 'invalid action' using errcode = '22023';
  end if;
  if p_action = 'reply'
     and (p_id is null or b is null or char_length(b) not between 1 and 4000) then
    raise exception 'invalid reply' using errcode = '22023';
  end if;

  perform app_private.act_as(p_user, p_device);
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  delete from app_private.notification_action_log l
   where l.user_id = p_user and l.at < now() - interval '1 minute';
  select count(*) into n from app_private.notification_action_log l
   where l.user_id = p_user;
  if n >= 20 then
    raise exception 'rate limited' using errcode = 'P0429';
  end if;
  insert into app_private.notification_action_log(user_id) values (p_user);

  if p_action = 'reply' then
    if not app_private.is_member(p_conversation)
       or app_private.is_system_conversation(p_conversation) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
    insert into public.messages(id, conversation_id, sender_id, body)
    values (p_id, p_conversation, p_user, b)
    on conflict (id) do nothing;
    if not found then
      if not exists (select 1 from public.messages m
                      where m.id = p_id and m.sender_id = p_user
                        and m.conversation_id = p_conversation and m.body = b) then
        raise exception 'id in use' using errcode = '23505';
      end if;
      result := 'duplicate';
    end if;
  end if;

  -- Replying reads the chat, as it does in the app. Also the whole of
  -- 'mark_read'; it raises 42501 itself for a non-member.
  perform public.mark_read(p_conversation);
  return result;
end $$;
revoke all on function public.notification_action(uuid, text, uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.notification_action(uuid, text, uuid, text, uuid, text)
  to service_role;
