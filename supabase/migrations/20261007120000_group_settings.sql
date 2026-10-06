-- Update 2: the group settings the Group info page shows.
--
-- Three switches on the conversation row, changed only by a current admin:
--   members_can_set_avatar  may any member change the group picture
--   members_can_add         may any member add people (else admins only)
--   new_members_see_history do people added from now on read what came before
-- Plus: a "picture changed" line for the chat, delete-for-everyone, and a
-- live "something about this group changed" nudge to every member.
--
-- Additive: no existing function changes meaning for a group that keeps its
-- migrated values. Groups that exist today are backfilled with TODAY's
-- behaviour (any member changes the picture, only admins add, new people are
-- offered history by the admin per add); groups created from now on get the
-- owner's defaults (picture admins-only, anyone adds, history shown).

-- 1. Settings columns. Added with TODAY's value so every existing row keeps
-- its behaviour, then the default flips for groups created from now on.
alter table public.conversations
  add column members_can_set_avatar  boolean not null default true,
  add column members_can_add         boolean not null default false,
  add column new_members_see_history boolean not null default true;
alter table public.conversations
  alter column members_can_set_avatar set default false,
  alter column members_can_add        set default true;

-- 2. Live nudge. A private per-user broadcast topic 'chats:<user id>': the
-- server sends one event per member whenever a group's settings, picture or
-- existence change, so the member's chat list re-reads at once. Content-free
-- (the conversation id and a word), never a message. Sent to every row of the
-- group, current or departed, because a departed member still lists it.
create or replace function app_private.notify_group_changed(conversation uuid, what text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  u uuid;
begin
  for u in select distinct cm.user_id from public.conversation_members cm
            where cm.conversation_id = conversation loop
    perform realtime.send(
      jsonb_build_object('conversation_id', conversation, 'what', what),
      'group_changed',
      'chats:' || u::text,
      true);
  end loop;
end $$;
revoke all on function app_private.notify_group_changed(uuid, text)
  from public, anon, authenticated;

-- Receiving 'chats:<own id>': 20261005150000's policy plus one branch. Only
-- the owner of the topic may join it. The bot still gets no Realtime at all.
drop policy realtime_receive on realtime.messages;
create policy realtime_receive on realtime.messages for select to authenticated
  using (
    (select app_private.has_app_access())
    and not app_private.is_bot((select auth.uid()))
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence')
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic())))
      or (extension = 'broadcast'
          and app_private.is_member(app_private.reads_conversation(realtime.topic()))
          and app_private.shares_read_status())
      or (extension = 'broadcast'
          and app_private.is_member(app_private.delivered_conversation(realtime.topic())))
      or (extension = 'broadcast'
          and realtime.topic() = 'chats:' || (select auth.uid())::text)
    )
  );

-- 3. Changing the settings: a current admin of a group, any subset (null =
-- leave as it is), so one switch flip is one call.
create function public.set_group_settings(
  conversation            uuid,
  members_can_set_avatar  boolean default null,
  members_can_add         boolean default null,
  new_members_see_history boolean default null
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select app_private.has_app_access())
     or app_private.is_bot(auth.uid())
     or not app_private.is_admin(conversation)
     or not exists (select 1 from public.conversations c
                     where c.id = conversation and c.title is not null) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversations c
     set members_can_set_avatar  = coalesce($2, c.members_can_set_avatar),
         members_can_add         = coalesce($3, c.members_can_add),
         new_members_see_history = coalesce($4, c.new_members_see_history)
   where c.id = conversation;
  perform app_private.notify_group_changed(conversation, 'settings');
end $$;
revoke all on function public.set_group_settings(uuid, boolean, boolean, boolean)
  from public, anon;
grant execute on function public.set_group_settings(uuid, boolean, boolean, boolean)
  to authenticated;

-- 4. add_members: an admin always; any current member while the group allows
-- it. History: the admin's per-call with_history (old builds still send it)
-- can only NARROW what the group setting allows -- with the setting off, a
-- person added now never reads what came before, whatever the caller sends.
-- A leave-and-rejoin is a new row through here, so it gets the same window.
create or replace function public.add_members(
  conversation uuid,
  members      uuid[],
  with_history boolean
) returns void language plpgsql security definer set search_path = '' as $$
declare
  me      uuid := auth.uid();
  grp     text;
  see     boolean;
  from_ts timestamptz;
  m       uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select c.title, c.new_members_see_history into grp, see
    from public.conversations c where c.id = conversation;
  if grp is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.is_admin(conversation)
     and not (app_private.is_member(conversation)
              and (select c.members_can_add from public.conversations c
                    where c.id = conversation)) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  from_ts := case when with_history and see then '-infinity'::timestamptz else now() end;

  if exists (select 1 from unnest(coalesce(members, '{}'::uuid[])) as x where x is null) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if exists (
    select 1 from unnest(coalesce(members, '{}'::uuid[])) as x
     where x <> me and (not app_private.is_allowed(x) or not app_private.can_reach(x))
  ) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  foreach m in array coalesce(members, '{}'::uuid[]) loop
    if m = me then
      continue;
    end if;
    if exists (select 1 from public.conversation_members
                where conversation_id = conversation and user_id = m and left_at is null) then
      continue;
    end if;
    insert into public.conversation_members(conversation_id, user_id, role, history_from)
      values (conversation, m, 'member', from_ts);
    insert into public.group_events(conversation_id, kind, actor_id, subject_id)
      values (conversation, 'added', me, m);
  end loop;
  perform app_private.notify_group_changed(conversation, 'members');
end $$;

-- 5. "X changed the group picture". Stored in group_events (kind 'picture'),
-- but that table stays admin-only and, for the three old kinds, exactly as
-- before: old builds in the field read it directly and would show a kind they
-- do not know as "X left". The picture rows are therefore hidden from the
-- table policy and served to every member through group_picture_events below,
-- inside the window the member may read (the same window messages use).
alter table public.group_events drop constraint group_events_kind_check;
alter table public.group_events add constraint group_events_kind_check
  check (kind in ('left', 'removed', 'added', 'picture'));

drop policy group_events_read on public.group_events;
create policy group_events_read on public.group_events for select to authenticated
  using (
    (select app_private.has_app_access())
    and kind <> 'picture'
    and app_private.admin_event_visible(conversation_id, created_at)
  );

create function public.group_picture_events(conversation uuid)
returns table (id uuid, conversation_id uuid, actor_id uuid, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select e.id, e.conversation_id, e.actor_id, e.created_at
    from public.group_events e
    join public.conversation_members cm
      on cm.conversation_id = e.conversation_id
     and cm.user_id = auth.uid()
     and e.created_at >= cm.history_from
     and (cm.left_at is null or e.created_at <= cm.left_at)
   where e.conversation_id = conversation
     and e.kind = 'picture'
     and app_private.has_app_access()
   order by e.created_at
$$;
revoke all on function public.group_picture_events(uuid) from public, anon;
grant execute on function public.group_picture_events(uuid) to authenticated;

-- 6. set_group_avatar (20261005130000): unchanged except that a non-admin
-- needs the group's switch on, and a real change leaves a 'picture' event and
-- a nudge. Returns the previous path, as before.
create or replace function public.set_group_avatar(conversation uuid, path text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  previous text;
begin
  if app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not (select app_private.has_app_access()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.is_member(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if path is not null and char_length(path) not between 3 and 400 then
    raise exception 'invalid path' using errcode = '22023';
  end if;
  if path is not null
     and not app_private.avatar_path_pinned(path, 'group/' || conversation::text)
  then
    raise exception 'invalid path' using errcode = '22023';
  end if;
  -- Locked so two replacements cannot read the same "previous" value.
  select avatar_path into previous
    from public.conversations c
   where c.id = conversation and c.title is not null
     for update;
  if not found then
    raise exception 'not a group' using errcode = '22023';
  end if;
  if not app_private.is_admin(conversation)
     and not (select c.members_can_set_avatar from public.conversations c
               where c.id = conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversations set avatar_path = path where id = conversation;
  if path is distinct from previous then
    insert into public.group_events(conversation_id, kind, actor_id, subject_id)
      values (conversation, 'picture', auth.uid(), auth.uid());
    perform app_private.notify_group_changed(conversation, 'picture');
  end if;
  return previous;
end $$;

-- 7. Delete a group for everyone: a current admin of a real group (never a
-- 1:1 or the system chat). Messages, members, reactions and events go with
-- it (on delete cascade). Returns the photo paths so the app can remove the
-- files; each is recorded for the caller first, which is what lets the
-- storage delete policy accept them (the messages are gone by then).
create function public.delete_group(conversation uuid)
returns text[] language plpgsql security definer set search_path = '' as $$
declare
  paths text[];
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not (select app_private.has_app_access())
     or app_private.is_bot(auth.uid())
     or not app_private.is_admin(conversation)
     or not exists (select 1 from public.conversations c
                     where c.id = conversation and c.title is not null and not c.system) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select coalesce(array_agg(m.attachment_path), '{}') into paths
    from public.messages m
   where m.conversation_id = conversation and m.attachment_path is not null;
  insert into app_private.deleted_attachments(path, user_id)
    select p, auth.uid() from unnest(paths) as p
    on conflict do nothing;
  perform app_private.notify_group_changed(conversation, 'deleted');
  delete from public.conversations where id = conversation;
  return paths;
end $$;
revoke all on function public.delete_group(uuid) from public, anon;
grant execute on function public.delete_group(uuid) to authenticated;

-- 8. Read marks: a person added without history must not learn from another
-- member's read/delivered position when messages from before they joined
-- were sent. A position earlier than the caller's own history_from says
-- nothing about any message they can see (all later), so it is returned as
-- "not yet", which is exactly what it means for them. history_from is
-- -infinity for everyone with full history, so nothing changes there.
create or replace function public.read_marks(conversation uuid)
returns table (user_id uuid, shares boolean, read_at timestamptz, delivered_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select cm.user_id,
         both_share,
         case when both_share and cm.shared_read_at >= me.history_from
              then cm.shared_read_at end,
         case when cm.delivered_at >= me.history_from then cm.delivered_at end
    from public.conversation_members me
    join public.conversation_members cm on cm.conversation_id = me.conversation_id
    left join public.profiles p on p.user_id = cm.user_id
   cross join lateral (
     select coalesce(p.share_read_status, false)
            and app_private.is_allowed(cm.user_id)
            and app_private.shares_read_status() as both_share
   ) s
   where me.conversation_id = conversation
     and me.user_id = auth.uid()
     and me.left_at is null
     and cm.user_id <> auth.uid()
     and cm.left_at is null
     and app_private.has_app_access()
$$;
