-- close group (S2b): rules 18, 19, Q7, Q10 of the delete rules.

-- 1. Add closed_at / closed_by columns.
alter table public.conversations
  add column closed_at timestamptz,
  add column closed_by uuid references auth.users(id) on delete set null;
alter table public.conversation_members
  add column closed_by uuid references auth.users(id) on delete set null;

-- 2. Allow 'closed' in group_events kind.
alter table public.group_events
  drop constraint group_events_kind_check;
alter table public.group_events
  add constraint group_events_kind_check
    check (kind in ('left','removed','added','picture','pinned','closed'));

-- 3. Replace policy group_events_read (old apps must not see the new kind).
drop policy group_events_read on public.group_events;
create policy group_events_read on public.group_events
  for select to authenticated
  using ((select app_private.has_app_access())
         and kind not in ('picture','pinned','closed')
         and app_private.admin_event_visible(conversation_id, created_at));

-- 4. Update group_member_events to include 'closed'.
create or replace function public.group_member_events(conversation uuid)
returns table (id uuid, conversation_id uuid, kind text, actor_id uuid,
               subject_id uuid, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select e.id, e.conversation_id, e.kind, e.actor_id, e.subject_id, e.created_at
    from public.group_events e
   where e.conversation_id = conversation
     and e.kind in ('left', 'removed', 'closed')
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

-- 5. close_group: a current admin (never a bot) removes everyone, for good.
create function public.close_group(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me  uuid := auth.uid();
  grp text;
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select c.title into grp
    from public.conversations c
   where c.id = conversation
     and c.title is not null
     and not c.system
     and c.closed_at is null
   for update;
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.is_admin(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  -- before the update, so the current members are the ones told
  perform app_private.notify_group_changed(conversation, 'members');
  update public.conversations
     set closed_at = now(), closed_by = me
   where id = conversation;
  insert into public.group_events(conversation_id, kind, actor_id, subject_id)
    values (conversation, 'closed', me, me);
  update public.conversation_members
     set left_at = now(), left_reason = 'removed', closed_by = me
   where conversation_id = conversation and left_at is null;
  perform app_private.drop_group_if_unused(conversation);
end $$;
revoke all on function public.close_group(uuid) from public, anon;
grant execute on function public.close_group(uuid) to authenticated;

-- 6. add_members: unchanged except `closed_at is null` (a closed group takes nobody new).
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
    from public.conversations c where c.id = conversation and c.closed_at is null;
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
revoke all on function public.add_members(uuid, uuid[], boolean) from public, anon;
grant execute on function public.add_members(uuid, uuid[], boolean) to authenticated;
