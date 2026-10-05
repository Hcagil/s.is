-- SIS Bot (t_2f501471c7): schema, helpers and a guard on every path the bot
-- can reach. Design: security-lead brief sis-bot-redesign; ADR 2026-10-05.
--
-- The bot is an ordinary auth user created through the admin API (never
-- here: this file holds no rows). It acts only with its own JWT, so everything
-- below is enforced on the server, for that one user id:
--   * confinement: its Debug chat plus 1:1 chats with owner-listed testers,
--     proved by a trigger on conversation_members (every way in, superuser
--     included);
--   * never an admin, never auto-promoted;
--   * OFF switch inside has_app_access(), so one flag stops every path;
--   * no push, no release notes, no tag search, no profile or avatar edit, no
--     contacts, no attachments, no Realtime;
--   * rate limits: 20 sends / 10 min, 200 / 24 h, 10 chat starts / 24 h
--     (error code RLMT2).
--
-- 1. Schema. app_private has no grants to API roles; RLS on, no policies.
create table app_private.bot_accounts (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  debug_conversation uuid not null references public.conversations(id),
  enabled            boolean not null default false,   -- the OFF switch; born OFF
  created_at         timestamptz not null default now()
);
create table app_private.bot_contacts (
  bot_id     uuid not null references app_private.bot_accounts(user_id) on delete cascade,
  contact_id uuid not null references auth.users(id) on delete cascade,
  added_at   timestamptz not null default now(),
  primary key (bot_id, contact_id),
  check (bot_id <> contact_id)
);
create table app_private.bot_actions (               -- rate log, as tag_lookups
  bot_id uuid not null references auth.users(id) on delete cascade,
  kind   text not null check (kind in ('send', 'start')),
  at     timestamptz not null default now()
);
create index bot_actions_bot_kind_at on app_private.bot_actions(bot_id, kind, at);
alter table app_private.bot_accounts enable row level security;
alter table app_private.bot_contacts enable row level security;
alter table app_private.bot_actions  enable row level security;
revoke all on app_private.bot_accounts, app_private.bot_contacts, app_private.bot_actions
  from public, anon, authenticated;

-- 2. Helpers.
create function app_private.is_bot(uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.bot_accounts where user_id = uid)
$$;
revoke all on function app_private.is_bot(uuid) from public, anon;
grant execute on function app_private.is_bot(uuid) to authenticated;

-- Debug chat, or the non-system 1:1 between the bot and one of its contacts.
create function app_private.bot_conversation_allowed(bot uuid, conv uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.bot_accounts b
                  where b.user_id = bot and b.debug_conversation = conv)
      or exists (select 1
                   from app_private.bot_contacts k
                   join public.conversations c on c.id = conv and not c.system
                    and c.direct_key = least(bot::text, k.contact_id::text)
                                       || ':' || greatest(bot::text, k.contact_id::text)
                  where k.bot_id = bot)
$$;
revoke all on function app_private.bot_conversation_allowed(uuid, uuid)
  from public, anon, authenticated;

-- 2a. Membership guard: the one place that proves confinement. Fires for every
-- insert or role/left_at change on a bot's row, whatever function or runbook
-- caused it (start_direct_conversation, add_members, set_admin, auto-promotion).
-- Rules: the conversation must be allowed and the role 'member'. On a new 1:1
-- membership: a caller (JWT present) needs the bot ON, and the bot starting a
-- chat itself is limited to 10 per 24 h (RLMT2). The Debug membership is the
-- owner's bootstrap, so it is exempt from ON and the rate; runbook inserts
-- (no JWT) are exempt from ON, so listing a tester works while OFF.
create function app_private.conversation_members_bot_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  recent int;
begin
  if not app_private.is_bot(new.user_id) then
    return new;
  end if;
  if new.role <> 'member'
     or not app_private.bot_conversation_allowed(new.user_id, new.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if tg_op = 'INSERT'
     and not exists (select 1 from app_private.bot_accounts b
                      where b.user_id = new.user_id
                        and b.debug_conversation = new.conversation_id) then
    if caller is not null
       and not exists (select 1 from app_private.bot_accounts b
                        where b.user_id = new.user_id and b.enabled) then
      raise exception 'not permitted' using errcode = '42501';
    end if;
    if caller = new.user_id then
      perform pg_advisory_xact_lock(hashtextextended('bot_start:' || caller::text, 0));
      delete from app_private.bot_actions a
       where a.bot_id = caller and a.at < now() - interval '24 hours';
      insert into app_private.bot_actions(bot_id, kind) values (caller, 'start');
      select count(*) into recent from app_private.bot_actions a
       where a.bot_id = caller and a.kind = 'start';
      if recent > 10 then
        raise exception 'too many chats started' using errcode = 'RLMT2';
      end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function app_private.conversation_members_bot_guard()
  from public, anon, authenticated;
create trigger conversation_members_bot_guard
  before insert or update of user_id, conversation_id, role, left_at
  on public.conversation_members
  for each row execute function app_private.conversation_members_bot_guard();

-- 2b. Delisting a contact cuts the bot off that chat at once: its membership
-- row goes, and with it every read of the history. Listing again (a runbook
-- statement) re-adds the bot from now on, so older messages stay unreadable.
create function app_private.bot_contacts_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  bot   uuid := coalesce(new.bot_id, old.bot_id);
  other uuid := coalesce(new.contact_id, old.contact_id);
  key   text := least(bot::text, other::text) || ':' || greatest(bot::text, other::text);
begin
  if tg_op = 'DELETE' then
    delete from public.conversation_members m
     using public.conversations c
     where m.user_id = bot and m.conversation_id = c.id
       and not c.system and c.direct_key = key;
  else
    insert into public.conversation_members(conversation_id, user_id, history_from)
    select c.id, bot, now() from public.conversations c
     where not c.system and c.direct_key = key
    on conflict do nothing;
  end if;
  return null;
end $$;
revoke all on function app_private.bot_contacts_sync() from public, anon, authenticated;
create trigger bot_contacts_sync after insert or delete on app_private.bot_contacts
  for each row execute function app_private.bot_contacts_sync();

-- 2c. Send limits and text-only. Refused sends roll back with their log row,
-- so only accepted sends count. Humans return at once.
create function app_private.messages_bot_rate() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  last10 int;
  last24 int;
begin
  if not app_private.is_bot(new.sender_id) then
    return new;
  end if;
  if new.attachment_path is not null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('bot_send:' || new.sender_id::text, 0));
  delete from app_private.bot_actions a
   where a.bot_id = new.sender_id and a.at < now() - interval '24 hours';
  insert into app_private.bot_actions(bot_id, kind) values (new.sender_id, 'send');
  select count(*) filter (where a.at >= now() - interval '10 minutes'), count(*)
    into last10, last24
    from app_private.bot_actions a
   where a.bot_id = new.sender_id and a.kind = 'send';
  if last10 > 20 or last24 > 200 then
    raise exception 'too many messages' using errcode = 'RLMT2';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_bot_rate() from public, anon, authenticated;
create trigger messages_bot_rate before insert on public.messages
  for each row execute function app_private.messages_bot_rate();


-- 3. The OFF switch: has_app_access() is the one gate every policy and RPC calls.
CREATE OR REPLACE FUNCTION app_private.has_app_access()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- The session must still exist in auth.sessions: sign-out or admin
  -- revocation takes effect immediately, not at access-token expiry.
  select app_private.is_allowed_user()
     and exists (select 1
                   from app_private.active_sessions s
                   join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
                  where s.user_id = auth.uid() and s.session_id = app_private.jwt_session_id())
     -- The SIS Bot's OFF switch (20261005130000): off stops it on every path.
     and not exists (select 1 from app_private.bot_accounts b
                      where b.user_id = auth.uid() and not b.enabled)
$function$;

-- 4. Starting a 1:1.
CREATE OR REPLACE FUNCTION public.start_direct_conversation(other_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  me  uuid := auth.uid();
  key text;
  cid uuid;
begin
  if not app_private.has_app_access() or other_user is null or other_user = me then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  -- The SIS Bot reaches only its listed testers (and they reach it); the
  -- members trigger then re-proves the conversation, OFF and the start rate.
  if not app_private.is_allowed(other_user)
     or not (app_private.can_reach(other_user)
             or (app_private.is_bot(me)
                 and exists (select 1 from app_private.bot_contacts k
                              where k.bot_id = me and k.contact_id = other_user))
             or (app_private.is_bot(other_user)
                 and exists (select 1 from app_private.bot_contacts k
                              where k.bot_id = other_user and k.contact_id = me))) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  key := least(me::text, other_user::text) || ':' || greatest(me::text, other_user::text);

  insert into public.conversations(direct_key) values (key)
    on conflict (direct_key) do nothing
    returning id into cid;
  if cid is null then
    select c.id into cid from public.conversations c where c.direct_key = key;
  else
    insert into public.conversation_members(conversation_id, user_id)
    values (cid, me), (cid, other_user);
  end if;
  return cid;
end $function$;

-- 5. Paths a bot never needs: refused outright (even when ON).

CREATE OR REPLACE FUNCTION public.find_by_tag(search_tag text)
 RETURNS TABLE(user_id uuid, display_name text, tag text, avatar_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  me        uuid := auth.uid();
  candidate text;
  recent    int;
  hit       uuid;
begin
  if app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('find_by_tag:' || me::text, 0));

  delete from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'find' and t.called_at < now() - interval '10 minutes';
  insert into app_private.tag_lookups(user_id, kind) values (me, 'find');
  select count(*) into recent from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'find';
  if recent > 20 then
    raise exception 'too many searches' using errcode = 'RLMT1';
  end if;

  candidate := app_private.normalise_tag_query(search_tag);
  if candidate !~ '^[a-z][a-z0-9_]{2,19}$' then
    return;
  end if;

  select p.user_id into hit
    from public.profiles p
   where p.tag = candidate
     and p.user_id <> me
     and app_private.is_allowed(p.user_id)
   limit 1;
  if hit is null then
    return;
  end if;

  -- Recorded BEFORE the masked select below, so this same call's
  -- avatar_visible_to (via can_reach -> found_by_tag) already sees it and a
  -- fresh 'everyone' result shows its picture immediately.
  insert into app_private.tag_finds(finder, found_id) values (me, hit)
    on conflict (finder, found_id) do update set found_at = now();

  return query
    select p.user_id, p.display_name, p.tag,
           case when app_private.avatar_visible_to(p.user_id) then p.avatar_object else null end
      from public.profiles p
     where p.user_id = hit;
end $function$;

CREATE OR REPLACE FUNCTION public.set_group_avatar(conversation uuid, path text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- Same shape pin as profiles_update_own, for the same reason: the value
  -- can only name the caller's own group, never one it copies from another.
  if path is not null
     and not app_private.avatar_path_pinned(path, 'group/' || conversation::text)
  then
    raise exception 'invalid path' using errcode = '22023';
  end if;
  -- Locked: two members replacing the picture at once must not both read the
  -- same "previous" value and each delete only what the OTHER just wrote,
  -- leaving neither's upload ever removed. The second caller's select waits
  -- for the first's update to commit, so it reads what the first actually
  -- left behind.
  select avatar_path into previous
    from public.conversations
   where id = conversation and title is not null
     for update;
  if not found then
    raise exception 'not a group' using errcode = '22023';
  end if;
  update public.conversations set avatar_path = path where id = conversation;
  return previous;
end $function$;

CREATE OR REPLACE FUNCTION public.deliver_release_notes(installed_build integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  me     uuid := auth.uid();
  sender constant uuid := '00000000-0000-0000-0000-00000000515e';
  served integer;
  cid    uuid;
  n      record;
  sent   integer := 0;
begin
  if app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if installed_build is null or installed_build < 1 then
    raise exception 'invalid build' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('release_notes:' || me::text, 0));

  select d.last_build into served from app_private.release_note_delivery d
   where d.user_id = me;
  if served is not null and installed_build <= served then
    return 0;
  end if;

  for n in
    select r.note from public.release_notes r
     where btrim(r.note, E' \t\r\n') <> ''
       and r.build <= installed_build
       and case when served is null
                then r.build = (select max(x.build) from public.release_notes x
                                 where btrim(x.note, E' \t\r\n') <> '' and x.build <= installed_build)
                else r.build > served end
     order by r.build
  loop
    if cid is null then
      insert into public.conversations(direct_key, system)
      values ('system:' || me::text, true)
      on conflict (direct_key) do nothing
      returning id into cid;
      if cid is null then
        select c.id into cid from public.conversations c
         where c.direct_key = 'system:' || me::text;
      else
        insert into public.conversation_members(conversation_id, user_id)
        values (cid, me);
      end if;
    end if;
    -- clock_timestamp, not now(): distinct times keep the notes in order.
    insert into public.messages(conversation_id, sender_id, body, created_at)
    values (cid, sender, btrim(n.note, E' \t\r\n'), clock_timestamp());
    sent := sent + 1;
  end loop;

  insert into app_private.release_note_delivery(user_id, last_build)
  values (me, installed_build)
  on conflict (user_id) do update
    set last_build = greatest(app_private.release_note_delivery.last_build, excluded.last_build);
  return sent;
end $function$;

CREATE OR REPLACE FUNCTION public.register_device_token(device_token text, device_platform text, shows_itself boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
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
  -- A token identifies a handset, not a person: another member signing in on
  -- this handset takes the token over.
  delete from app_private.device_tokens d
   where d.token = device_token and d.user_id <> auth.uid();

  -- has_app_access() above proved the JWT's session is the member's active
  -- one, so jwt_session_id() is never null here. The client sends no session.
  insert into app_private.device_tokens(user_id, token, platform, shows_itself, session_id)
  values (auth.uid(), device_token, device_platform,
          coalesce(register_device_token.shows_itself, false),
          app_private.jwt_session_id())
  on conflict (user_id, token) do update
    set platform = excluded.platform, shows_itself = excluded.shows_itself,
        session_id = excluded.session_id, updated_at = now();
end $function$;

CREATE OR REPLACE FUNCTION app_private.avatar_path_writable(object_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  kind  text := (storage.foldername(object_name))[1];
  owner uuid := app_private.avatar_path_owner(object_name);
begin
  if app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if owner is null then
    return false;
  end if;
  return case kind
    when 'profile' then owner = (select auth.uid())
    when 'group' then app_private.is_member(owner)
                       and exists (
                         select 1 from public.conversations c
                          where c.id = owner and c.title is not null)
    else false
  end;
end $function$;

-- 6. The bot is never an admin and never auto-promoted.
CREATE OR REPLACE FUNCTION public.leave_group(conversation uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION app_private.promote_on_member_deleted()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conv uuid := old.conversation_id;
begin
  if old.left_at is null and old.role = 'admin'
     and exists (select 1 from public.conversations c where c.id = conv and c.title is not null)
     and exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null
          and not app_private.is_bot(user_id)
     )
     and not exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null and role = 'admin'
     )
  then
    update public.conversation_members
       set role = 'admin'
     where id = (
       select id from public.conversation_members
        where conversation_id = conv and left_at is null
          and not app_private.is_bot(user_id)
        order by joined_at asc, user_id asc
        limit 1
        for update
     );
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION app_private.group_needs_admin_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conv uuid := coalesce(new.conversation_id, old.conversation_id);
begin
  if exists (select 1 from public.conversations c where c.id = conv and c.title is not null)
     and exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null
          and not app_private.is_bot(user_id)
     )
     and not exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null and role = 'admin'
     )
  then
    raise exception 'a group must always have an admin' using errcode = '23514';
  end if;
  return null;
end $function$;

-- 7. Policies. Each gains `not is_bot` except where noted.
-- Profile edits (name, tag, avatar, sharing switches).
drop policy profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using ((select app_private.has_app_access())
         and user_id = (select auth.uid())
         and not app_private.is_bot((select auth.uid())))
  with check (
    (select app_private.has_app_access())
    and user_id = (select auth.uid())
    and (avatar_object is null
         or app_private.avatar_path_pinned(avatar_object, 'profile/' || user_id::text))
  );

-- Contacts would widen what the bot may read (profiles_read), so it gets none.
drop policy contacts_insert on public.contacts;
create policy contacts_insert on public.contacts for insert to authenticated
  with check ((select app_private.has_app_access())
              and owner_id = (select auth.uid())
              and contact_id <> owner_id
              and not app_private.is_bot(owner_id)
              and app_private.is_allowed(contact_id)
              and app_private.can_reach(contact_id));

-- Text-only bot: no uploads (members' attachments stay readable by membership).
drop policy attachments_write on storage.objects;
create policy attachments_write on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
              and (select app_private.has_app_access())
              and not app_private.is_bot((select auth.uid()))
              and app_private.is_member_of_path(name)
              and owner_id = (select auth.uid())::text);

-- No Realtime: presence:members is project-wide, so receiving it would show
-- every member's online state outside the bot's confinement.
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
    )
  );

drop policy realtime_send on realtime.messages;
create policy realtime_send on realtime.messages for insert to authenticated
  with check (
    (select app_private.has_app_access())
    and not app_private.is_bot((select auth.uid()))
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence'
       and app_private.shares_presence())
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic()))
          and app_private.shares_typing())
    )
  );

-- 8. Which user ids are bots, for the client's BOT label (Update 1).
create function public.bot_ids() returns setof uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query select user_id from app_private.bot_accounts;
end $$;
revoke all on function public.bot_ids() from public, anon;
grant execute on function public.bot_ids() to authenticated;
