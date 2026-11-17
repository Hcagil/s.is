-- Invite by link, part 1 of 3: tables, helper functions and the join-event line.
-- Invite tokens live in app_private, locked to all client roles.
-- Parts 2 and 3 follow in later migrations.

create extension if not exists pgcrypto with schema extensions;

create table app_private.group_invite_links (
  conversation_id uuid primary key references public.conversations(id) on delete cascade,
  token text not null unique check (token ~ '^[A-Za-z0-9_-]{24}$'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz  -- null = no time limit
);

revoke all on app_private.group_invite_links from public, anon, authenticated;
alter table app_private.group_invite_links enable row level security;

create table app_private.invite_link_attempts (
  user_id uuid not null references auth.users(id) on delete cascade,
  called_at timestamptz not null default now()
);

create index invite_link_attempts_user_called_idx on app_private.invite_link_attempts (user_id, called_at);

revoke all on app_private.invite_link_attempts from public, anon, authenticated;
alter table app_private.invite_link_attempts enable row level security;

create function app_private.invite_rate_check()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  recent int;
begin
  perform pg_advisory_xact_lock(hashtextextended('invite_link:' || me::text, 0));
  delete from app_private.invite_link_attempts a
   where a.user_id = me and a.called_at < now() - interval '10 minutes';
  insert into app_private.invite_link_attempts(user_id) values (me);
  select count(*) into recent from app_private.invite_link_attempts a where a.user_id = me;
  if recent > 20 then
    raise exception 'too many tries' using errcode = 'RLMT1';
  end if;
end;
$$;

revoke all on function app_private.invite_rate_check() from public, anon, authenticated;

create function app_private.invite_group_state(conversation uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select case
              when c.closed_at is not null then 'closed'
              else 'ok'
            end
       from public.conversations c
      where c.id = conversation
        and c.title is not null
        and not c.admin_chat
        and not c.staff_b_chat
        and not c.debug_chat
        and not c.system
        and c.staff_key is null),
    'none')
$$;

revoke all on function app_private.invite_group_state(uuid) from public, anon, authenticated;

alter table public.group_events drop constraint group_events_kind_check;
alter table public.group_events add constraint group_events_kind_check check (kind in ('left','removed','added','picture','pinned','closed','joined'));

drop policy group_events_read on public.group_events;
create policy group_events_read on public.group_events for select to authenticated using ((select app_private.has_app_access()) and kind not in ('picture','pinned','closed','joined') and app_private.admin_event_visible(conversation_id, created_at));

create function public.group_join_events(conversation uuid)
returns table (id uuid, conversation_id uuid, actor_id uuid, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select e.id, e.conversation_id, e.actor_id, e.created_at
    from public.group_events e
   where e.conversation_id = conversation
     and e.kind = 'joined'
     and app_private.has_app_access()
     and exists (select 1 from public.conversation_members cm
                  where cm.conversation_id = e.conversation_id
                    and cm.user_id = auth.uid()
                    and e.created_at >= cm.history_from
                    and (cm.left_at is null or e.created_at <= cm.left_at))
   order by e.created_at
$$;
revoke all on function public.group_join_events(uuid) from public, anon;
grant execute on function public.group_join_events(uuid) to authenticated;

-- create and reset are one action: a new token replaces the old one, so the old link stops working.
create function public.reset_invite_link(conversation uuid, valid_days int)
returns table (token text, created_at timestamptz, expires_at timestamptz)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.invite_group_state(conversation) <> 'ok'
     or not app_private.is_admin(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if valid_days is not null and valid_days not in (1,7,30) then
    raise exception 'invalid days' using errcode = '22023';
  end if;
  insert into app_private.group_invite_links(conversation_id, token, created_by, created_at, expires_at)
  values (conversation, translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/', '-_'), me, now(),
          case when valid_days is null then null else now() + make_interval(days => valid_days) end)
  on conflict (conversation_id) do update set token = excluded.token, created_by = excluded.created_by,
    created_at = excluded.created_at, expires_at = excluded.expires_at;
  return query select l.token, l.created_at, l.expires_at from app_private.group_invite_links l where l.conversation_id = reset_invite_link.conversation;
end $$;
revoke all on function public.reset_invite_link(uuid, int) from public, anon;
grant execute on function public.reset_invite_link(uuid, int) to authenticated;

create function public.turn_off_invite_link(conversation uuid)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.invite_group_state(conversation) <> 'ok'
     or not app_private.is_admin(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  delete from app_private.group_invite_links where conversation_id = turn_off_invite_link.conversation;
end $$;
revoke all on function public.turn_off_invite_link(uuid) from public, anon;
grant execute on function public.turn_off_invite_link(uuid) to authenticated;

-- A new time limit keeps the same link and restarts its timer; only reset_invite_link makes a new token.
create function public.set_invite_link_expiry(conversation uuid, valid_days int)
returns table (token text, created_at timestamptz, expires_at timestamptz)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.invite_group_state(conversation) <> 'ok'
     or not app_private.is_admin(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if valid_days is not null and valid_days not in (1,7,30) then
    raise exception 'invalid days' using errcode = '22023';
  end if;
  update app_private.group_invite_links l
     set expires_at = case when valid_days is null then null else now() + make_interval(days => valid_days) end
   where l.conversation_id = set_invite_link_expiry.conversation;
  if not found then
    raise exception 'invalid link' using errcode = 'LINK1';
  end if;
  return query select l.token, l.created_at, l.expires_at
    from app_private.group_invite_links l
   where l.conversation_id = set_invite_link_expiry.conversation;
end $$;
revoke all on function public.set_invite_link_expiry(uuid, int) from public, anon;
grant execute on function public.set_invite_link_expiry(uuid, int) to authenticated;

create function public.get_invite_link(conversation uuid)
returns table (token text, created_at timestamptz, expires_at timestamptz)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.invite_group_state(conversation) <> 'ok'
     or not app_private.is_admin(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query select l.token, l.created_at, l.expires_at
    from app_private.group_invite_links l
   where l.conversation_id = get_invite_link.conversation;
end $$;
revoke all on function public.get_invite_link(uuid) from public, anon;
grant execute on function public.get_invite_link(uuid) to authenticated;

create function app_private.invite_removed(conversation uuid, uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select m.left_reason = 'removed'
                     from public.conversation_members m
                    where m.conversation_id = conversation and m.user_id = uid
                    order by m.joined_at desc, m.left_at desc nulls first
                    limit 1), false)
$$;
revoke all on function app_private.invite_removed(uuid, uuid) from public, anon, authenticated;

create function public.preview_invite_link(token text)
returns table (conversation_id uuid, title text, avatar_path text, member_count int)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  link record;
begin
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform app_private.invite_rate_check();
  if token is null or token !~ '^[A-Za-z0-9_-]{24}$' then
    raise exception 'invalid link' using errcode = 'LINK1';
  end if;
  select l.conversation_id, l.expires_at into link
    from app_private.group_invite_links l where l.token = preview_invite_link.token;
  if not found then
    raise exception 'invalid link' using errcode = 'LINK1';
  end if;
  case app_private.invite_group_state(link.conversation_id)
    when 'none' then raise exception 'invalid link' using errcode = 'LINK1';
    when 'closed' then raise exception 'group closed' using errcode = 'LINK3';
    else null;
  end case;
  if link.expires_at is not null and link.expires_at <= now() then
    raise exception 'link expired' using errcode = 'LINK2';
  end if;
  -- a member an admin removed comes back only when an admin adds them
  if app_private.invite_removed(link.conversation_id, me) then
    raise exception 'removed member' using errcode = 'LINK4';
  end if;
  return query
    select c.id, c.title, c.avatar_path,
           (select count(*)::int from public.conversation_members m
             where m.conversation_id = c.id and m.left_at is null)
      from public.conversations c where c.id = link.conversation_id;
end $$;
revoke all on function public.preview_invite_link(text) from public, anon;
grant execute on function public.preview_invite_link(text) to authenticated;

create function public.join_by_link(token text)
returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  conv uuid;
  link record;
  see boolean;
begin
  if not app_private.has_app_access() or app_private.is_bot(me) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform app_private.invite_rate_check();
  if token is null or token !~ '^[A-Za-z0-9_-]{24}$' then
    raise exception 'invalid link' using errcode = 'LINK1';
  end if;
  select l.conversation_id into conv
    from app_private.group_invite_links l where l.token = join_by_link.token;
  if conv is null then
    raise exception 'invalid link' using errcode = 'LINK1';
  end if;
  -- same lock add_members and close_group take; re-read the link after it (a reset may have raced)
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conv::text, 0));
  select l.conversation_id, l.expires_at into link
    from app_private.group_invite_links l where l.token = join_by_link.token;
  if not found then
    raise exception 'invalid link' using errcode = 'LINK1';
  end if;
  case app_private.invite_group_state(conv)
    when 'none' then raise exception 'invalid link' using errcode = 'LINK1';
    when 'closed' then raise exception 'group closed' using errcode = 'LINK3';
    else null;
  end case;
  if link.expires_at is not null and link.expires_at <= now() then
    raise exception 'link expired' using errcode = 'LINK2';
  end if;
  if exists (select 1 from public.conversation_members m
              where m.conversation_id = conv and m.user_id = me and m.left_at is null) then
    return conv;
  end if;
  if app_private.invite_removed(conv, me) then
    raise exception 'removed member' using errcode = 'LINK4';
  end if;
  select c.new_members_see_history into see from public.conversations c where c.id = conv;
  insert into public.conversation_members(conversation_id, user_id, role, history_from)
    values (conv, me, 'member',
            case when see then '-infinity'::timestamptz else now() end);
  delete from public.chat_hides where user_id = me and conversation_id = conv;
  insert into public.group_events(conversation_id, kind, actor_id, subject_id)
    values (conv, 'joined', me, me);
  perform app_private.notify_group_changed(conv, 'members');
  return conv;
end $$;
revoke all on function public.join_by_link(text) from public, anon;
grant execute on function public.join_by_link(text) to authenticated;

