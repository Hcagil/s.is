-- v0.23: leaving a group, removing members, and admins.
--
-- Membership keeps history instead of deleting rows. conversation_members
-- gains: role ('admin'|'member'), left_at (null = current), left_reason
-- ('left'|'removed'), history_from (messages before it are unreadable to
-- that membership row).
--
-- A member who leaves and is later re-added gets a NEW row rather than the
-- old one rewritten: the primary key moves from (conversation_id, user_id)
-- to a surrogate id, with a partial unique index keeping "at most one
-- CURRENT row per (conversation, user)". Decision (brief asked "a returning
-- member gets a fresh window -- their old window stays readable?"): YES,
-- the old row is left exactly as it was (its own history_from..left_at
-- window keeps reading), and the new row gets its own fresh window from the
-- admin's with_history choice. The alternative -- overwriting the single
-- old row -- would claw back messages the member had already been entitled
-- to read during their first stint whenever they are re-added without
-- history, which contradicts "keeps history instead of deleting rows" and
-- is a worse surprise than one extra row.
--
-- history_from's column default is '-infinity', not "now" or "joined_at":
-- every row this migration backfills, and every row start_direct_
-- conversation/start_group_conversation ever insert, is created at a moment
-- with no message the row should be excluded from anyway (a brand new
-- conversation has no history yet), so '-infinity' and "now" are the same
-- timestamp in effect there -- but '-infinity' also preserves today's actual
-- behaviour (every member reads the whole history, unbounded) for existing
-- rows and for every pgTAP fixture that inserts conversation_members
-- directly without knowing this column exists. Only add_members sets
-- history_from to something else on purpose (the admin's with_history
-- choice), and it always sets it explicitly rather than relying on the
-- default.

alter table public.conversation_members
  add column role text not null default 'member' check (role in ('admin', 'member')),
  add column left_at timestamptz,
  add column left_reason text check (left_reason in ('left', 'removed')),
  add column history_from timestamptz not null default '-infinity'::timestamptz,
  add constraint conversation_members_left_consistency_check
    check ((left_at is null) = (left_reason is null));

-- Backfill admins: the creator is unknown (never stored), so per the brief's
-- own fallback, every existing group's earliest member becomes its admin --
-- ties (start_group_conversation gives every founding member the same
-- joined_at, since the RPC's single INSERT evaluates now() once) broken by
-- user_id for a deterministic, reproducible pick. 1:1 conversations are
-- untouched: role stays 'member' on both rows and is simply never read for
-- them (start_direct_conversation and every RPC below refuse a 1:1 outright).
with earliest as (
  select distinct on (cm.conversation_id) cm.conversation_id, cm.user_id
    from public.conversation_members cm
    join public.conversations c on c.id = cm.conversation_id
   where c.title is not null
   order by cm.conversation_id, cm.joined_at asc, cm.user_id asc
)
update public.conversation_members cm
   set role = 'admin'
  from earliest e
 where cm.conversation_id = e.conversation_id and cm.user_id = e.user_id;

-- The primary key moves to a surrogate id; uniqueness of "current membership"
-- becomes a partial index instead of the table's only key, which is what
-- lets a past row and a fresh row coexist for the same (conversation, user).
alter table public.conversation_members drop constraint conversation_members_pkey;
alter table public.conversation_members add column id uuid not null default gen_random_uuid();
alter table public.conversation_members add primary key (id);
create unique index conversation_members_current_uidx
  on public.conversation_members(conversation_id, user_id) where left_at is null;
-- Replaces the composite lookup the old (conversation_id, user_id) primary
-- key provided for free; conversation_members_user_idx (on user_id alone)
-- is unaffected and stays.
create index conversation_members_conv_user_idx
  on public.conversation_members(conversation_id, user_id);

-- Column-level read grant, extended: role, left_at and left_reason are
-- needed to show admins, grey a departed name and list a "left" section.
-- history_from stays unlisted -- it is bookkeeping for the server's own read
-- gate, not something the app renders.
revoke select on public.conversation_members from authenticated;
grant select (conversation_id, user_id, joined_at, role, left_at, left_reason)
  on public.conversation_members to authenticated;

-- Membership helpers ---------------------------------------------------------
-- is_member: CURRENT membership only -- unchanged meaning from before this
-- migration, now spelled with left_at is null. Used everywhere an ACTION
-- (send, edit, delete, change the avatar, type, go online in a conversation
-- topic, admin actions) requires being in the group right now.
create or replace function app_private.is_member(conversation uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversation_members m
                  where m.conversation_id = conversation and m.user_id = auth.uid()
                    and m.left_at is null)
$$;

-- was_member: current OR past -- any row at all, current or departed. Used
-- everywhere a departed member's READ-ONLY history view must keep working:
-- seeing the conversation exists, seeing the member list (including the
-- "left" section), the group's own picture.
create or replace function app_private.was_member(conversation uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversation_members m
                  where m.conversation_id = conversation and m.user_id = auth.uid())
$$;

-- is_admin: a CURRENT member whose row is marked 'admin'. Gates every admin
-- action (remove_member, add_members, set_admin) and reading group_events.
create or replace function app_private.is_admin(conversation uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversation_members m
                  where m.conversation_id = conversation and m.user_id = auth.uid()
                    and m.left_at is null and m.role = 'admin')
$$;
revoke all on function app_private.was_member(uuid), app_private.is_admin(uuid)
  from public, anon;
grant execute on function app_private.was_member(uuid), app_private.is_admin(uuid)
  to authenticated;

-- security-lead F2: this migration added admins, but never redefined
-- start_group_conversation (still the definition from contacts.sql) -- so a
-- brand new group's own creator was inserted with the plain column default,
-- role = 'member', and every new group had NO admin at all. Redefined here,
-- identical to the contacts.sql version except the membership insert: the
-- caller goes in as 'admin', everyone else as 'member', still one INSERT
-- statement (now() is still evaluated once, so joined_at is still identical
-- across the founding members -- see this migration's backfill comment).
create or replace function public.start_group_conversation(
  title   text,
  members uuid[]
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me      uuid := auth.uid();
  clean   text := btrim(coalesce(title, ''));
  invited uuid[];
  cid     uuid;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if char_length(clean) < 1 or char_length(clean) > 80 then
    raise exception 'a group needs a title' using errcode = '22023';
  end if;

  select array_agg(distinct m) into invited
    from unnest(coalesce(members, '{}'::uuid[])) as m
   where m is distinct from me;

  if invited is null or array_length(invited, 1) < 1 then
    raise exception 'a group needs at least one other member'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from unnest(invited) as m
     where m is null or not app_private.is_allowed(m) or not app_private.can_reach(m)
  ) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  insert into public.conversations(title) values (clean) returning id into cid;
  insert into public.conversation_members(conversation_id, user_id, role)
    select cid, me, 'admin'
    union all
    select cid, m, 'member' from unnest(invited) as m;
  return cid;
end $$;
revoke all on function public.start_group_conversation(text, uuid[])
  from public, anon;
grant execute on function public.start_group_conversation(text, uuid[])
  to authenticated;

-- message_readable: the one place that decides whether [m] falls inside the
-- caller's own membership window for its conversation -- current member:
-- created_at >= history_from, no upper bound; departed member: history_from
-- <= created_at <= left_at. Shared by messages_read, search_messages and
-- attachment_readable below so the three can never drift apart, the same
-- guarantee docs/SECURITY.md already asked for between messages_read and
-- search_messages (previously kept in step by hand, now by construction).
create or replace function app_private.message_readable(m public.messages) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.conversation_members cm
     where cm.conversation_id = m.conversation_id
       and cm.user_id = auth.uid()
       and m.created_at >= cm.history_from
       and (cm.left_at is null or m.created_at <= cm.left_at)
  )
$$;
revoke all on function app_private.message_readable(public.messages) from public, anon;
grant execute on function app_private.message_readable(public.messages) to authenticated;

-- security-lead F8: in_conversation (reply_and_forward.sql) gates a reply's
-- quote target -- messages_send's WITH CHECK calls it as
-- `reply_to is null or in_conversation(reply_to, conversation_id)`. It never
-- changed with this migration, so a CURRENT member (already required
-- separately by messages_send) could still reply to any message that merely
-- EXISTS in the conversation, including one outside their own readable
-- window (added without history, replying to something sent before they
-- joined; or a rejoined member's old, unrelated window). Redefined to also
-- require message_readable(m.*) on the target -- a reply can now only quote
-- a message the replier could actually read.
create or replace function app_private.in_conversation(message uuid, conversation uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.is_member(conversation)
     and exists (select 1 from public.messages m
                  where m.id = message and m.conversation_id = conversation
                    and app_private.message_readable(m.*))
$$;

-- Reads: conversations ----------------------------------------------------
-- A departed member keeps seeing the conversation row (title, avatar) --
-- was_member, not is_member.
drop policy conversations_read on public.conversations;
create policy conversations_read on public.conversations for select to authenticated
  using ((select app_private.has_app_access()) and app_private.was_member(id));

-- conversation_members_read is defined further down (search "F4"), once
-- overlaps_my_membership exists: was_member alone let anyone who was EVER
-- in a conversation see every row of it, of everyone, with no window --
-- security-lead F4.

-- Reads: messages -----------------------------------------------------------
-- Keeps the 20260927150000 leakproof pre-filter (the caller's own
-- conversation ids, current or past, read once) as a NECESSARY condition --
-- still sargable against messages_conversation_idx -- and adds message_
-- readable() as the authoritative, per-row, per-window check on top. This
-- necessarily gives up part of that migration's full hoist (the window is
-- data-dependent per row now, a fixed set of conversation ids alone can no
-- longer decide it), but keeps the same big-O bound on an unscoped read: a
-- foreign conversation is still excluded before any row is fetched.
drop policy messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
  using (
    (select app_private.has_app_access())
    and conversation_id = any (
          array(select cm.conversation_id from public.conversation_members cm
                 where cm.user_id = (select auth.uid()))
        )
    and app_private.message_readable(messages.*)
  );

-- Reads: attachments ---------------------------------------------------------
-- Write stays current-member-only (is_member_of_path, unchanged, chat.sql).
--
-- Read: security-lead F1 (HIGH, real probe on the stack) -- the first
-- attempt here (this migration, before review) was plain was_member: current
-- or past membership of the conversation, no window at all. Storage select
-- covers download, sign AND list, and an object's own name is guessable
-- (`<conversation>/<micros>-<uid8>.<ext>`), so that let a departed/removed
-- member, a member added without history, or a rejoined member with a fresh
-- (narrower) window read a photo from OUTSIDE what messages_read would ever
-- show them.
--
-- Fixed to exactly two cases, an OR, so BOTH keep working:
--  1. The UPLOADER reads back HER OWN object while it exists in storage but
--     before any message references it yet (upload happens before the
--     message insert, docs/DECISIONS.md, "the pair cannot be atomic") --
--     gated on owner_id (the object's own uploader, passed in from the
--     policy) AND was_member (still needs to have been in the conversation
--     at all; not time-windowed, since there is no message yet to window
--     against). This is also what keeps a sender reading back an object she
--     just told delete_message to forget (delete_message_test.sql "the
--     object is gone", read AFTER the message's attachment_path is nulled):
--     she is still the object's owner_id.
--  2. ANYONE ELSE (or the uploader, after upload, once a message exists) may
--     read it only through a message.attachment_path that actually names
--     this object AND falls inside THEIR OWN message_readable() window --
--     the exact same window messages_read itself applies, so a departed/
--     removed/no-history/rejoined member is refused exactly the photos
--     messages_read would already refuse them the message for.
-- messages_attachment_path_key (delete_for_everyone.sql) is already the
-- unique partial index this join needs (attachment_path, where not null).
create or replace function app_private.attachment_readable(
  object_name text,
  object_owner_id text
) returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  head text := (storage.foldername(object_name))[1];
begin
  if head is null or head !~
     '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  then
    return false;
  end if;
  return (object_owner_id = auth.uid()::text and app_private.was_member(head::uuid))
      or exists (
           select 1 from public.messages m
            where m.attachment_path = object_name
              and app_private.message_readable(m.*)
         );
end $$;
revoke all on function app_private.attachment_readable(text, text) from public, anon;
grant execute on function app_private.attachment_readable(text, text) to authenticated;

drop policy attachments_read on storage.objects;
create policy attachments_read on storage.objects for select to authenticated
  using (bucket_id = 'attachments'
         and (select app_private.has_app_access())
         and app_private.attachment_readable(name, owner_id));

-- A group's picture, read: security-lead F7 -- the first version here
-- (before review) moved the group branch to was_member, but the app already
-- falls back to initials whenever a picture is simply absent (avatar_path
-- null), and a departed member has no need to keep seeing a group's
-- current picture (it can change after they leave). Reverted to is_member
-- (current only): a departed member sees initials, like a group with no
-- picture at all. The 'profile' branch (avatar_visible_to) is untouched.
create or replace function app_private.avatar_path_readable(object_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  kind  text := (storage.foldername(object_name))[1];
  owner uuid := app_private.avatar_path_owner(object_name);
begin
  if owner is null then
    return false;
  end if;
  return case kind
    when 'profile' then app_private.avatar_visible_to(owner)
    when 'group' then app_private.is_member(owner)
                       and exists (
                         select 1 from public.conversations c
                          where c.id = owner and c.title is not null)
    else false
  end;
end $$;

-- Reach: only CURRENT membership counts --------------------------------------
-- "Someone who left no longer counts as sharing that chat" (brief). This one
-- function change ripples correctly into everything built on can_reach:
-- profiles_read, contacts_insert, avatar_visible_to's 'everyone' branch,
-- start_direct_conversation, start_group_conversation, last_seen_of.
create or replace function app_private.shares_conversation(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.conversation_members mine
      join public.conversation_members theirs
        on theirs.conversation_id = mine.conversation_id
     where mine.user_id = (select auth.uid()) and mine.left_at is null
       and theirs.user_id = other and theirs.left_at is null)
$$;

-- shared_conversation_ever: current OR past on BOTH sides -- deliberately
-- NOT the function above. profiles_read/profiles_public need this one: a
-- current member of a group must still be able to read a DEPARTED member's
-- name to grey it (criterion 8: "departed members' names greyed wherever
-- shown"), and a departed member must still be able to read the CURRENT
-- members' names for their own read-only view. shares_conversation itself
-- stays current-only, because can_reach -- which must only widen what a
-- member can START doing (a contact, a chat, an "everyone" picture) -- is
-- built on it, and reach and "can I still see a name already in a chat I'm
-- in" are different questions that happened to share one function before
-- this migration.
-- security-lead F4: the first version above (before review) matched on
-- ANY of my rows against ANY of their rows for the conversation, with no
-- window at all -- so a departed member could see the name of someone who
-- only joined after they left (never actually together), and a member
-- added without history could see someone who left before they even
-- joined. Fixed to an interval-overlap test between MY readable window
-- ([my history_from, my left_at or infinity]) and THEIR presence window
-- ([their joined_at, their left_at or infinity]): standard "do these two
-- ranges overlap" (a1<=b2 and b1<=a2). With history (history_from =
-- -infinity), my window covers everything back to the start, so it still
-- overlaps a departed sender's whole presence -- "added-with-history still
-- sees departed senders' names" holds by construction, not as a special
-- case.
create or replace function app_private.shared_conversation_ever(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.conversation_members mine
      join public.conversation_members theirs
        on theirs.conversation_id = mine.conversation_id
     where mine.user_id = (select auth.uid())
       and theirs.user_id = other
       and mine.history_from <= coalesce(theirs.left_at, 'infinity'::timestamptz)
       and theirs.joined_at <= coalesce(mine.left_at, 'infinity'::timestamptz))
$$;
revoke all on function app_private.shared_conversation_ever(uuid) from public, anon;
grant execute on function app_private.shared_conversation_ever(uuid) to authenticated;

-- security-lead F4, second half: conversation_members_read itself had the
-- same gap -- was_member(conversation_id) let anyone who was EVER in a
-- conversation see EVERY row of it, current and past, of everyone,
-- regardless of whether their own window ever overlapped that row's
-- presence. Redefined below (search for "F4" again) once was_member's
-- caller is available; the overlap test itself is the same shape as
-- shared_conversation_ever, against the TARGET ROW's own joined_at/left_at
-- rather than a second table alias -- kept as its own security definer
-- function rather than an inline self-join on conversation_members, for
-- the same reason is_member always has been one (chat.sql): a policy on
-- conversation_members reading conversation_members to decide conversation_
-- members' own visibility is exactly the shape that function exists to
-- avoid inlining.
create or replace function app_private.overlaps_my_membership(
  conversation uuid,
  other_joined timestamptz,
  other_left timestamptz
) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.conversation_members mine
     where mine.conversation_id = conversation
       and mine.user_id = (select auth.uid())
       and mine.history_from <= coalesce(other_left, 'infinity'::timestamptz)
       and other_joined <= coalesce(mine.left_at, 'infinity'::timestamptz)
  )
$$;
revoke all on function app_private.overlaps_my_membership(uuid, timestamptz, timestamptz)
  from public, anon;
grant execute on function app_private.overlaps_my_membership(uuid, timestamptz, timestamptz)
  to authenticated;

drop policy conversation_members_read on public.conversation_members;
create policy conversation_members_read on public.conversation_members for select to authenticated
  using (
    (select app_private.has_app_access())
    and (
      user_id = (select auth.uid())
      or app_private.overlaps_my_membership(conversation_id, joined_at, left_at)
    )
  );

-- profiles_read / profiles_public, redefined to use shared_conversation_ever
-- instead of shares_conversation -- same reasoning as immediately above.
-- is_contact is untouched (a contact stays a contact regardless of shared
-- membership).
drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using ((select app_private.has_app_access())
         and app_private.is_allowed(user_id)
         and (user_id = (select auth.uid())
              or app_private.shared_conversation_ever(user_id)
              or app_private.is_contact(user_id)));

create or replace function public.profiles_public()
returns table (user_id uuid, display_name text, tag text, avatar_path text)
language sql stable security definer set search_path = '' as $$
  select p.user_id, p.display_name, p.tag,
         case when app_private.avatar_visible_to(p.user_id) then p.avatar_object else null end
    from public.profiles p
   where app_private.has_app_access()
     and app_private.is_allowed(p.user_id)
     and (p.user_id = (select auth.uid())
          or app_private.shared_conversation_ever(p.user_id)
          or app_private.is_contact(p.user_id))
$$;
revoke all on function public.profiles_public() from public, anon;
grant execute on function public.profiles_public() to authenticated;

-- Push: a left member gets no push ------------------------------------------
create or replace function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, 'Someone')
           else coalesce(p.display_name, 'Someone') || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' then 'New message'
           when btrim(m.body) = '' and m.attachment_path is not null then '📷 Photo'
           else case when m.attachment_path is not null then '📷 ' else '' end
                || case when char_length(btrim(m.body)) <= 120 then btrim(m.body)
                        else left(btrim(m.body), 119) || '…' end
         end,
         d.shows_itself
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id <> m.sender_id
     and cm.left_at is null
    join app_private.device_tokens d on d.user_id = cm.user_id
    join app_private.active_sessions s on s.user_id = cm.user_id
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
    left join public.profiles p on p.user_id = m.sender_id
    left join public.notification_settings ns on ns.user_id = cm.user_id
   where m.id = message_id
     and m.deleted is null
     and app_private.is_allowed(cm.user_id)
     and coalesce(ns.enabled, true)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = cm.user_id
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;

-- delete_message: was missing an explicit membership check entirely (there
-- was no way to lose membership before this feature). A member removed or
-- who left must not still be able to delete a message of theirs within its
-- 6-hour window.
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
     or m.sender_id <> auth.uid()
     or not app_private.is_member(m.conversation_id)
     or m.deleted is not null
     or m.created_at < now() - interval '6 hours' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if m.attachment_path is not null then
    insert into app_private.deleted_attachments(path, user_id)
    values (m.attachment_path, m.sender_id)
    on conflict do nothing;
  end if;
  update public.messages
     set body = '',
         attachment_path = null,
         attachment_preview = null,
         edited_at = null,
         deleted = case when m.created_at >= now() - interval '1 hour'
                        then 'vanished' else 'placeholder' end,
         deleted_at = now()
   where id = message;
  return m.attachment_path;
end $$;

-- mark_read / read_marks / unread_counts -------------------------------------
-- mark_read targets the caller's most relevant row for [conversation]: the
-- current one if they still have one, else their most recent past row (so a
-- departed member can still catch up on the last few messages inside their
-- own window). Either way last_read_at/shared_read_at are capped at left_at:
-- "cannot mark read beyond left_at" (brief), made literal rather than merely
-- moot. The live reads: broadcast only fires for a CURRENT row -- a departed
-- member's realtime_send attempt would be refused by realtime_send's own
-- is_member() gate anyway; capping it here avoids even trying.
create or replace function public.mark_read(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  sharing boolean := app_private.shares_read_status();
  target  public.conversation_members;
  cap     timestamptz;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into target from public.conversation_members m
   where m.conversation_id = conversation and m.user_id = auth.uid()
   order by (m.left_at is null) desc, m.left_at desc
   limit 1
   for update;
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  cap := least(now(), coalesce(target.left_at, 'infinity'::timestamptz));
  update public.conversation_members m
     set last_read_at = cap,
         shared_read_at = case when sharing then cap else m.shared_read_at end
   where m.id = target.id;
  if sharing and target.left_at is null then
    perform realtime.send(
      jsonb_build_object('user_id', auth.uid(), 'read_at', cap),
      'read',
      'reads:' || conversation::text,
      true);
  end if;
end $$;

-- read_marks: security-lead F6 -- the first version here (before review)
-- gated on was_member, so a departed caller still got back every current
-- member's read mark. Reverted to is_member (current only): a departed
-- caller now gets no rows at all, same shape as unread_counts below (they
-- accrue nothing new to read either).
create or replace function public.read_marks(conversation uuid)
returns table (user_id uuid, shares boolean, read_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select cm.user_id,
         both_share,
         case when both_share then cm.shared_read_at end
    from public.conversation_members cm
    left join public.profiles p on p.user_id = cm.user_id
   cross join lateral (
     select coalesce(p.share_read_status, false)
            and app_private.is_allowed(cm.user_id)
            and app_private.shares_read_status() as both_share
   ) s
   where cm.conversation_id = conversation
     and cm.user_id <> auth.uid()
     and cm.left_at is null
     and app_private.has_app_access()
     and app_private.is_member(conversation)
$$;

-- unread_counts: scoped to the caller's CURRENT row only (a departed member
-- accrues nothing new to count), and bounded below by history_from so a
-- member added without history is never shown old messages as unread.
create or replace function public.unread_counts()
returns table (conversation_id uuid, unread integer)
language sql stable security definer set search_path = '' as $$
  select cm.conversation_id, count(*)::integer
    from public.conversation_members cm
    join public.messages m
      on m.conversation_id = cm.conversation_id
     and m.created_at > cm.last_read_at
     and m.created_at >= cm.history_from
     and m.sender_id <> cm.user_id
     and m.deleted is null
   where cm.user_id = auth.uid()
     and cm.left_at is null
     and app_private.has_app_access()
   group by cm.conversation_id
$$;

-- search_messages: the same window, through the same message_readable()
-- function messages_read uses -- see that policy's comment for why this is
-- now a shared function instead of hand-kept-in-step text (SECURITY.md:
-- "whenever messages_read changes, this function must change with it").
-- Keeps the leakproof array pre-filter (now built from current-or-past
-- memberships, was_member's own set) and the alnum >= 3 guard unchanged.
create or replace function public.search_messages(query text, conversation uuid default null)
returns table (
  id uuid, conversation_id uuid, sender_id uuid, body text, created_at timestamptz,
  attachment_path text, attachment_preview text, deleted text, reply_to uuid,
  forwarded boolean, edited_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select m.id, m.conversation_id, m.sender_id, m.body, m.created_at,
         m.attachment_path, m.attachment_preview, m.deleted, m.reply_to,
         m.forwarded, m.edited_at
    from public.messages m
   where (select app_private.has_app_access())
     and (conversation is null or (select app_private.was_member(conversation)))
     and m.conversation_id = any (
           array(select cm.conversation_id from public.conversation_members cm
                  where cm.user_id = auth.uid())
         )
     and app_private.message_readable(m.*)
     and char_length(regexp_replace(query, '[^[:alnum:]]', '', 'g')) >= 3
     and m.deleted is null
     and (conversation is null or m.conversation_id = conversation)
     and m.search_text like (select '%' || public.escape_like(public.fold_search(btrim(query))) || '%') escape '\'
   order by m.created_at desc
   limit 50
$$;

-- Group events: "X left" / "X was removed" / "X was added" ------------------
-- Least invasive design: a small table, readable only by CURRENT admins of
-- that group, that the app merges into the message timeline on the client
-- side by created_at. Never in previews, unread counts, search or push,
-- because none of those read this table at all. No client insert policy --
-- only the RPCs below write it, as the table owner (security definer),
-- bypassing RLS the same way every other server-authored table here does.
create table public.group_events (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  kind            text not null check (kind in ('left', 'removed', 'added')),
  actor_id        uuid references auth.users(id) on delete set null,
  subject_id      uuid not null references auth.users(id) on delete cascade,
  created_at      timestamptz not null default now()
);
create index group_events_conversation_idx on public.group_events(conversation_id, created_at);
alter table public.group_events enable row level security;
revoke all on public.group_events from anon, authenticated;
-- security-lead F9: is_admin(conversation_id) alone had no lower time bound
-- -- an admin added without history could read "X left" events from before
-- they ever joined, which messages_read would never show them the
-- corresponding history for. Bounded to the admin's own CURRENT row's
-- history_from (is_admin already implies a current admin row exists);
-- coalesced to 'infinity' if somehow none is found, so the policy denies
-- rather than defaults open.
create policy group_events_read on public.group_events for select to authenticated
  using (
    (select app_private.has_app_access())
    and app_private.is_admin(conversation_id)
    and created_at >= coalesce(
      (select cm.history_from from public.conversation_members cm
        where cm.conversation_id = group_events.conversation_id
          and cm.user_id = (select auth.uid())
          and cm.left_at is null),
      'infinity'::timestamptz)
  );
grant select on public.group_events to authenticated;

-- leave_group -----------------------------------------------------------
-- Any CURRENT member of a GROUP (never a 1:1 -- refused) may leave. If they
-- were the group's last current admin, the longest-standing remaining
-- current member (min joined_at, tied by user_id) becomes admin, so a group
-- is never left unmanaged. Locked per conversation (advisory) so two admins
-- leaving at once cannot both see "an admin remains" and leave nobody in
-- charge.
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

  update public.conversation_members set left_at = now(), left_reason = 'left'
   where id = mine.id;
  insert into public.group_events(conversation_id, kind, actor_id, subject_id)
    values (conversation, 'left', null, me);

  if mine.role = 'admin' and not exists (
       select 1 from public.conversation_members
        where conversation_id = conversation and left_at is null and role = 'admin')
  then
    update public.conversation_members
       set role = 'admin'
     where id = (
       select id from public.conversation_members
        where conversation_id = conversation and left_at is null
        order by joined_at asc, user_id asc
        limit 1
        for update
     );
  end if;
end $$;
revoke all on function public.leave_group(uuid) from public, anon;
grant execute on function public.leave_group(uuid) to authenticated;

-- remove_member ---------------------------------------------------------
-- An admin removes anyone but themselves (they leave instead -- self-removal
-- is refused so the caller learns to use leave_group, which also carries the
-- last-admin rule). Never on a 1:1.
--
-- security-lead F3 (MEDIUM, probed concurrently: remove/remove,
-- demote/demote, leave/self-demote): locked per conversation, as the very
-- first statement, same advisory key leave_group already uses -- two admin
-- actions on the same group can no longer race past each other's is_admin()
-- check.
create or replace function public.remove_member(conversation uuid, member uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me     uuid := auth.uid();
  grp    text;
  target public.conversation_members;
begin
  perform pg_advisory_xact_lock(hashtextextended('group_admin:' || conversation::text, 0));
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if member = me then
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

  update public.conversation_members set left_at = now(), left_reason = 'removed'
   where id = target.id;
  insert into public.group_events(conversation_id, kind, actor_id, subject_id)
    values (conversation, 'removed', me, member);
end $$;
revoke all on function public.remove_member(uuid, uuid) from public, anon;
grant execute on function public.remove_member(uuid, uuid) to authenticated;

-- add_members -------------------------------------------------------------
-- An admin adds one or more people, each of whom must be allowlisted and
-- reachable by the admin (contacts rule, 2026-09-28) -- the same all-or-
-- nothing shape start_group_conversation already uses: one bad id fails the
-- whole call. Already-current members are skipped (idempotent, not an
-- error). A returning member (a past row exists, no current one) gets a NEW
-- row with a fresh window; their old row and its window are untouched --
-- see this migration's header comment for why. with_history chooses that
-- fresh window's floor: true = '-infinity' (the group's whole history from
-- their point of view), false = now() (only from here on).
--
-- security-lead F3: locked first, same key leave_group/remove_member use.
-- security-lead F11: a null element used to reach the plain insert below
-- and fail as a raw not-null constraint violation (23502) instead of a
-- clean refusal -- checked explicitly now, before the reachability check
-- (`x <> me` is never true for a null x, so the reachability exists() alone
-- silently let a null slip through unexamined).
create or replace function public.add_members(
  conversation uuid,
  members      uuid[],
  with_history boolean
) returns void language plpgsql security definer set search_path = '' as $$
declare
  me      uuid := auth.uid();
  grp     text;
  from_ts timestamptz := case when with_history then '-infinity'::timestamptz else now() end;
  m       uuid;
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
end $$;
revoke all on function public.add_members(uuid, uuid[], boolean) from public, anon;
grant execute on function public.add_members(uuid, uuid[], boolean) to authenticated;

-- set_admin -----------------------------------------------------------------
-- An admin makes another CURRENT member an admin, or unmakes one. Refuses to
-- demote the sole remaining admin (not asked for explicitly, but follows
-- directly from "a group is never left unmanaged" -- leave_group's own
-- promotion exists for exactly this invariant, and a demotion should not be
-- a back door around it).
--
-- security-lead F3: locked first, same key leave_group/remove_member/
-- add_members use, so a demote racing another demote (or a leave) cannot
-- both see an admin remaining and leave none.
create or replace function public.set_admin(conversation uuid, member uuid, is_admin boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  grp    text;
  target public.conversation_members;
  admins int;
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
      raise exception 'a group needs at least one admin' using errcode = '42501';
    end if;
  end if;

  update public.conversation_members
     set role = case when is_admin then 'admin' else 'member' end
   where id = target.id;
end $$;
revoke all on function public.set_admin(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_admin(uuid, uuid, boolean) to authenticated;

-- Belt-and-suspenders: security-lead F3, second half -- the advisory locks
-- above stop the three RPCs racing EACH OTHER, but say nothing about a
-- future write to conversation_members that does not go through one of
-- them (a bug, a manual fix, a later migration). A deferred constraint
-- trigger checks, once at commit (not per intermediate row state within one
-- transaction -- a demote immediately followed by a promote in the same
-- transaction never trips it), that no GROUP with any current member is
-- left with zero current admins. Never fires for a 1:1 (no title) or an
-- empty/fully-departed group (nobody left to need an admin).
create or replace function app_private.group_needs_admin_check() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  conv uuid := coalesce(new.conversation_id, old.conversation_id);
begin
  if exists (select 1 from public.conversations c where c.id = conv and c.title is not null)
     and exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null
     )
     and not exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null and role = 'admin'
     )
  then
    raise exception 'a group must always have an admin' using errcode = '23514';
  end if;
  return null;
end $$;
revoke all on function app_private.group_needs_admin_check() from public, anon, authenticated;

create constraint trigger conversation_members_admin_guard
  after insert or update on public.conversation_members
  deferrable initially deferred
  for each row
  execute function app_private.group_needs_admin_check();
