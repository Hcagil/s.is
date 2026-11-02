-- chat and group rules (S2)
-- Rule 9: a 1:1 chat is deleted on the user's own phone only; old apps get a plain error.
create or replace function public.delete_direct_chat(conversation uuid)
returns text[] language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'not permitted' using errcode = '42501';
end $$;

-- Rule 17: delete-group-for-everyone is gone (closing a group replaces it).
create or replace function public.delete_group(conversation uuid)
returns text[] language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'not permitted' using errcode = '42501';
end $$;

-- Rule 16: "show earlier messages" is OFF by default; every existing group goes OFF once.
alter table public.conversations alter column new_members_see_history set default false;
update public.conversations set new_members_see_history = false
 where new_members_see_history is distinct from false;

-- Rule 15: always >= 1 admin. The last admin removing their own admin right promotes the
-- longest-standing other member first; an admin who is the only member is still refused.
create or replace function public.set_admin(conversation uuid, member uuid, is_admin boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  grp    text;
  target public.conversation_members;
  admins int;
  next_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select title into grp from public.conversations where id = conversation;
  if grp is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.is_admin(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  select * into target from public.conversation_members
   where conversation_id = conversation and user_id = member and left_at is null
   for update;
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  if not is_admin and target.role = 'admin' then
    select count(*) into admins from public.conversation_members
     where conversation_id = conversation and left_at is null and role = 'admin';
    if admins <= 1 then
      select id into next_id from public.conversation_members
       where conversation_id = conversation and left_at is null and id <> target.id
         and not app_private.is_bot(user_id)
       order by joined_at asc, user_id asc
       limit 1
       for update;
      if next_id is null then
        raise exception 'a group needs at least one admin' using errcode = '42501';
      end if;
      update public.conversation_members set role = 'admin' where id = next_id;
    end if;
  end if;

  update public.conversation_members
     set role = case when is_admin then 'admin' else 'member' end
   where id = target.id;
end $$;
revoke all on function public.set_admin(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_admin(uuid, uuid, boolean) to authenticated;

-- Rule 19 / Q7: a group with no current member and no message anyone wrote is deleted at once.
-- A group that has messages is kept (a later job wipes it); the Debug group is never dropped here.
create or replace function app_private.drop_group_if_unused(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  avatar text;
begin
  if exists (select 1 from public.conversation_members cm
              where cm.conversation_id = conversation and cm.left_at is null)
     or exists (select 1 from public.messages m where m.conversation_id = conversation)
     or exists (select 1 from app_private.bot_accounts b where b.debug_conversation = conversation)
     or not exists (select 1 from public.conversations c
                     where c.id = conversation and c.title is not null and not c.system) then
    return;
  end if;
  select c.avatar_path into avatar from public.conversations c where c.id = conversation;
  if avatar is not null then
    insert into app_private.storage_removal_queue(bucket, path) values ('avatars', avatar)
      on conflict (bucket, path) do nothing;
  end if;
  perform app_private.notify_group_changed(conversation, 'deleted');
  delete from public.conversations where id = conversation;
end $$;
revoke all on function app_private.drop_group_if_unused(uuid) from public, anon, authenticated;

-- leave_group: unchanged except the last line (the empty-group check).
create or replace function public.leave_group(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me   uuid := auth.uid();
  mine public.conversation_members;
  grp  text;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));

  select title into grp from public.conversations where id = conversation;
  if grp is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  select * into mine from public.conversation_members
   where conversation_id = conversation and user_id = me and left_at is null
   for update;
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  -- Debug group: the last human admin cannot leave while only the bot remains.
  if mine.role = 'admin'
     and not exists (select 1 from public.conversation_members
                      where conversation_id = conversation and left_at is null and id <> mine.id
                        and (role = 'admin' or not app_private.is_bot(user_id)))
     and exists (select 1 from public.conversation_members
                  where conversation_id = conversation and left_at is null and id <> mine.id) then
    raise exception 'a group needs at least one admin' using errcode = '42501';
  end if;

  update public.conversation_members set left_at = now(), left_reason = 'left'
   where id = mine.id;
  insert into public.group_events(conversation_id, kind, actor_id, subject_id)
    values (conversation, 'left', null, me);

  if not exists (
       select 1 from public.conversation_members
        where conversation_id = conversation and left_at is null and role = 'admin')
  then
    update public.conversation_members
       set role = 'admin'
     where id = (
       select id from public.conversation_members
        where conversation_id = conversation and left_at is null
          and not app_private.is_bot(user_id)
        order by joined_at asc, user_id asc
        limit 1
        for update
     );
  end if;
  perform app_private.drop_group_if_unused(conversation);
end $$;
revoke all on function public.leave_group(uuid) from public, anon;
grant execute on function public.leave_group(uuid) to authenticated;

-- Rule 16: a re-added member brings the chat back even if they had deleted it.
-- add_members is unchanged except the one chat_hides delete in the loop.
create or replace function public.add_members(
  conversation uuid,
  members      uuid[],
  with_history boolean
) returns void language plpgsql security definer set search_path = '' as $$
declare
  me      uuid := auth.uid();
  adm     boolean;
  grp     text;
  see     boolean;
  from_ts timestamptz;
  m       uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select c.title, c.new_members_see_history into grp, see
    from public.conversations c where c.id = conversation;
  if grp is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  adm := app_private.is_admin(conversation);
  if not adm
     and not (app_private.is_member(conversation)
              and (select c.members_can_add from public.conversations c
                    where c.id = conversation)) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  from_ts := case when (case when adm then coalesce(with_history, false) else see end)
                  then '-infinity'::timestamptz else now() end;

  if exists (select 1 from unnest(coalesce(members, '{}'::uuid[])) as x where x is null) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if exists (
    select 1 from unnest(coalesce(members, '{}'::uuid[])) as x
     where x <> me and (not app_private.is_allowed(x)
                        or not case when adm then app_private.can_reach(x)
                                    else app_private.shares_conversation(x)
                                         or app_private.is_contact(x) end)
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
    delete from public.chat_hides where user_id = m and conversation_id = conversation;
    insert into public.group_events(conversation_id, kind, actor_id, subject_id)
      values (conversation, 'added', me, m);
  end loop;
  perform app_private.notify_group_changed(conversation, 'members');
end $$;

-- Rule 13: every member sees "NAME left" / "NAME was removed by NAME" (the table itself stays
-- admin-only for old apps), inside the window the caller may read, left members included.
create function public.group_member_events(conversation uuid)
returns table (id uuid, conversation_id uuid, kind text, actor_id uuid,
               subject_id uuid, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select e.id, e.conversation_id, e.kind, e.actor_id, e.subject_id, e.created_at
    from public.group_events e
   where e.conversation_id = conversation
     and e.kind in ('left', 'removed')
     and app_private.has_app_access()
     and exists (select 1 from public.conversation_members cm
                  where cm.conversation_id = e.conversation_id
                    and cm.user_id = auth.uid()
                    and e.created_at >= cm.history_from
                    and (cm.left_at is null or e.created_at <= cm.left_at))
   order by e.created_at
$$;
revoke all on function public.group_member_events(uuid) from public, anon;
grant execute on function public.group_member_events(uuid) to authenticated;
