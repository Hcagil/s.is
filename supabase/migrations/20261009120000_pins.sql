-- Update 2: pinned chats and pinned messages.
--
--  * Pinned chats: per member, server-side (survives a reinstall, shows on
--    every device), at most 5. public.chat_pins holds one row per "this user
--    pinned this conversation". Own rows only (read, insert, delete); a row may
--    name only a conversation the user is, or was, a member of. The limit of 5
--    is enforced by a trigger (under a per-user lock, so two devices cannot
--    both squeeze in a sixth), not by the app.
--  * Pinned message: ONE per conversation, shared by everyone in it. It is a
--    column on the conversation (pinned_message_id); it can be changed only
--    through set_pinned_message, which checks who may pin. Pinning leaves a
--    "X pinned a message" line (group_events kind 'pinned', served to every
--    member by pin_events, like 'picture'); unpinning leaves none. A pinned
--    message that is deleted for everyone is unpinned by a trigger.
--  * Who may pin messages: conversations.members_can_pin, default TRUE (all
--    members). Changed only by a current admin of a group (set_members_can_pin).
--    A 1:1 has no such switch: both people may pin. The SIS system chat and the
--    SIS Bot never pin.
--
-- Additive only: one new table, two new columns, new functions, and the
-- group_events kind check plus read policy widened for the new kind.
-- group_events stays admin-only for the four older kinds and exactly as
-- before for old builds, which would show a kind they do not know as "X left":
-- the new rows are hidden from the table policy and served through pin_events.

-- 1. Pinned chats.
create table public.chat_pins (
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  pinned_at       timestamptz not null default now(),
  primary key (user_id, conversation_id)
);
create index chat_pins_conversation_idx on public.chat_pins (conversation_id);

alter table public.chat_pins enable row level security;
revoke all on table public.chat_pins from anon, authenticated;
grant select, insert, delete on table public.chat_pins to authenticated;

create policy chat_pins_read on public.chat_pins
  for select to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));
create policy chat_pins_insert on public.chat_pins
  for insert to authenticated
  with check ((select app_private.has_app_access())
              and user_id = (select auth.uid())
              and app_private.was_member(conversation_id));
create policy chat_pins_delete on public.chat_pins
  for delete to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));

-- The limit: 5 pinned chats per member. Pinning a chat that is already pinned
-- is not a new pin, so it never trips the limit. SQLSTATE 54000
-- (program_limit_exceeded) is what the app reads as "You can pin up to 5 chats."
create function app_private.enforce_pin_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('chat_pins:' || new.user_id::text, 0));
  if exists (select 1 from public.chat_pins p
              where p.user_id = new.user_id
                and p.conversation_id = new.conversation_id) then
    return new;
  end if;
  -- An archived chat is never pinned (archiving unpins), so no pin is ever
  -- hidden in the Archived screen while it counts toward the 5.
  if exists (select 1 from public.chat_archives a
              where a.user_id = new.user_id
                and a.conversation_id = new.conversation_id) then
    raise exception 'archived chat' using errcode = '42501';
  end if;
  if (select count(*) from public.chat_pins p where p.user_id = new.user_id) >= 5 then
    raise exception 'pin limit' using errcode = '54000';
  end if;
  return new;
end $$;
revoke all on function app_private.enforce_pin_limit() from public, anon, authenticated;
create trigger chat_pins_limit before insert on public.chat_pins
  for each row execute function app_private.enforce_pin_limit();

-- Archiving a chat unpins it (like Telegram). Unarchiving does not pin again.
create function app_private.unpin_on_archive() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.chat_pins p
   where p.user_id = new.user_id and p.conversation_id = new.conversation_id;
  return new;
end $$;
revoke all on function app_private.unpin_on_archive() from public, anon, authenticated;
create trigger chat_archives_unpin after insert on public.chat_archives
  for each row execute function app_private.unpin_on_archive();

-- 2. Pinned message and who may pin. Existing groups and every new group
-- start with "all members" (the owner's default).
alter table public.conversations
  add column pinned_message_id uuid references public.messages(id) on delete set null,
  add column members_can_pin   boolean not null default true;

-- 3. The "X pinned a message" line.
alter table public.group_events drop constraint group_events_kind_check;
alter table public.group_events add constraint group_events_kind_check
  check (kind in ('left', 'removed', 'added', 'picture', 'pinned'));

drop policy group_events_read on public.group_events;
create policy group_events_read on public.group_events for select to authenticated
  using (
    (select app_private.has_app_access())
    and kind not in ('picture', 'pinned')
    and app_private.admin_event_visible(conversation_id, created_at)
  );

-- Every member (of a group or a 1:1), inside the window they may read, same
-- rule as group_picture_events.
create function public.pin_events(conversation uuid)
returns table (id uuid, conversation_id uuid, actor_id uuid, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select e.id, e.conversation_id, e.actor_id, e.created_at
    from public.group_events e
   where e.conversation_id = conversation
     and e.kind = 'pinned'
     and app_private.has_app_access()
     and exists (select 1 from public.conversation_members cm
                  where cm.conversation_id = e.conversation_id
                    and cm.user_id = auth.uid()
                    and e.created_at >= cm.history_from
                    and (cm.left_at is null or e.created_at <= cm.left_at))
   order by e.created_at
$$;
revoke all on function public.pin_events(uuid) from public, anon;
grant execute on function public.pin_events(uuid) to authenticated;

-- 4. Pin or unpin (message null) the conversation's message. A current member;
-- in a group also "all members may pin" or a current admin. The message must
-- be in this conversation, not deleted, and readable by the caller.
create function public.set_pinned_message(conversation uuid, message uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  conv public.conversations;
  m    public.messages;
begin
  if not (select app_private.has_app_access())
     or app_private.is_bot(auth.uid())
     or not app_private.is_member(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into conv from public.conversations c where c.id = conversation for update;
  if not found or conv.system
     or (conv.title is not null
         and not conv.members_can_pin
         and not app_private.is_admin(conversation)) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if message is not null then
    select * into m from public.messages x where x.id = message;
    if not found
       or m.conversation_id <> conversation
       or m.deleted is not null
       or not app_private.message_readable(m) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
  end if;
  if conv.pinned_message_id is not distinct from message then
    return;
  end if;
  update public.conversations c set pinned_message_id = message where c.id = conversation;
  if message is not null then
    insert into public.group_events(conversation_id, kind, actor_id, subject_id)
      values (conversation, 'pinned', auth.uid(), auth.uid());
  end if;
  perform app_private.notify_group_changed(conversation, 'pinned');
end $$;
revoke all on function public.set_pinned_message(uuid, uuid) from public, anon;
grant execute on function public.set_pinned_message(uuid, uuid) to authenticated;

-- 5. Who may pin messages: a current admin of a group.
create function public.set_members_can_pin(conversation uuid, allowed boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select app_private.has_app_access())
     or app_private.is_bot(auth.uid())
     or allowed is null
     or not app_private.is_admin(conversation)
     or not exists (select 1 from public.conversations c
                     where c.id = conversation and c.title is not null) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversations c set members_can_pin = allowed where c.id = conversation;
  perform app_private.notify_group_changed(conversation, 'settings');
end $$;
revoke all on function public.set_members_can_pin(uuid, boolean) from public, anon;
grant execute on function public.set_members_can_pin(uuid, boolean) to authenticated;

-- 6. A message deleted for everyone stops being the pinned one.
create function app_private.unpin_deleted_message() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted is not null and old.deleted is null then
    update public.conversations c set pinned_message_id = null
     where c.id = new.conversation_id and c.pinned_message_id = new.id;
    if found then
      perform app_private.notify_group_changed(new.conversation_id, 'pinned');
    end if;
  end if;
  return new;
end $$;
revoke all on function app_private.unpin_deleted_message() from public, anon, authenticated;
create trigger messages_unpin_deleted after update of deleted on public.messages
  for each row execute function app_private.unpin_deleted_message();
