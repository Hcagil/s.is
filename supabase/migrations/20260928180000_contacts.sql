-- Contacts, exact-tag search, and tighter profile visibility (v0.22.0).
--
-- New chat stops listing every allowlisted member. From here a member's
-- "your people" is their contacts plus whoever they already share a
-- conversation with, plus anyone they have just found by exact tag; anyone
-- else is unreachable. `profiles` is narrowed to match: readable only for
-- yourself, someone you share a conversation with, or a contact. The
-- exact-tag lookup below is the one deliberate hole in that rule -- it
-- returns its one row itself (security definer), so it needs no broad read.
--
-- Additive for older builds: `contacts` is new and they never call
-- `find_by_tag`. They still call `members()`-shaped queries against
-- `profiles` directly, which the read policy below just narrows -- they see
-- fewer people, never an error (see the migration's tail comment).

-- Contacts --------------------------------------------------------------
create table public.contacts (
  owner_id   uuid not null references auth.users(id) on delete cascade,
  contact_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, contact_id),
  check (owner_id <> contact_id)
);
alter table public.contacts enable row level security;
revoke all on public.contacts from anon, authenticated;

-- Reach -----------------------------------------------------------------
-- "Can the caller reach [other] at all" -- the gate every RPC that would
-- otherwise let a caller name an arbitrary allowlisted id must pass first
-- (security-lead finding F1, 2026-09-28: presence and the `avatars` bucket's
-- folder listing turn every allowlisted id into a discoverable name, so
-- allowlisted-ness alone can never be enough to start a chat, add a contact,
-- or see someone's "everyone" picture). Defined here, right after the
-- `contacts` table it reads and ahead of the policies and RPCs that call it,
-- so every later policy and function in this file (and its
-- avatar_visibility.sql follow-on) can use it.

-- Whether the caller shares any conversation (1:1 or group) with [other].
-- Security definer, like is_member: read here without re-applying
-- conversation_members' own RLS, the same reason is_member bypasses it.
create or replace function app_private.shares_conversation(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.conversation_members mine
      join public.conversation_members theirs
        on theirs.conversation_id = mine.conversation_id
     where mine.user_id = (select auth.uid()) and theirs.user_id = other)
$$;
revoke all on function app_private.shares_conversation(uuid) from public, anon;
grant execute on function app_private.shares_conversation(uuid) to authenticated;

-- Whether the caller has [other] in THEIR OWN contacts -- the direction
-- "have I saved them", used by profiles_read and can_reach below.
-- avatar_visibility's "my contacts" (added next migration) asks the
-- opposite direction: whether the PICTURE'S OWNER saved the reader.
create or replace function app_private.is_contact(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.contacts c
     where c.owner_id = (select auth.uid()) and c.contact_id = other)
$$;
revoke all on function app_private.is_contact(uuid) from public, anon;
grant execute on function app_private.is_contact(uuid) to authenticated;

-- Recorded when find_by_tag returns a match (below): the finder may then
-- reach that person -- start a chat with them, add them as a contact --
-- even before either of those becomes true on its own; otherwise a result
-- find_by_tag just showed would be unreachable the moment it is shown.
-- Permanent, not pruned like tag_lookups: forgetting it would silently
-- break "message the person I just found" a few minutes later for no
-- reason the member could see. No client grants; belt-and-braces RLS like
-- every other app_private table.
create table app_private.tag_finds (
  finder   uuid not null references auth.users(id) on delete cascade,
  found_id uuid not null references auth.users(id) on delete cascade,
  found_at timestamptz not null default now(),
  primary key (finder, found_id)
);
revoke all on app_private.tag_finds from public, anon, authenticated;
alter table app_private.tag_finds enable row level security;

create or replace function app_private.found_by_tag(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from app_private.tag_finds t
     where t.finder = (select auth.uid()) and t.found_id = other)
$$;
revoke all on function app_private.found_by_tag(uuid) from public, anon;
grant execute on function app_private.found_by_tag(uuid) to authenticated;

-- The gate itself: yourself, a shared conversation, a saved contact, or a
-- tag search that has already turned up this person. Never "allowlisted",
-- which every account is.
create or replace function app_private.can_reach(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select other = (select auth.uid())
     or app_private.shares_conversation(other)
     or app_private.is_contact(other)
     or app_private.found_by_tag(other)
$$;
revoke all on function app_private.can_reach(uuid) from public, anon;
grant execute on function app_private.can_reach(uuid) to authenticated;

-- Contacts policies -------------------------------------------------------
-- (the `contacts` table itself is created above, ahead of can_reach, which
-- its own policies below need.)
create policy contacts_read on public.contacts for select to authenticated
  using ((select app_private.has_app_access()) and owner_id = (select auth.uid()));

-- Both sides must be allowlisted, like starting a conversation, AND the
-- caller must already be able to reach the other side (F1) -- so a contact
-- can only ever be added from a shared conversation or a tag search result,
-- never named blind.
create policy contacts_insert on public.contacts for insert to authenticated
  with check ((select app_private.has_app_access())
              and owner_id = (select auth.uid())
              and contact_id <> owner_id
              and app_private.is_allowed(contact_id)
              and app_private.can_reach(contact_id));

create policy contacts_delete on public.contacts for delete to authenticated
  using ((select app_private.has_app_access()) and owner_id = (select auth.uid()));

grant select, insert, delete on public.contacts to authenticated;

-- Profiles, narrowed -------------------------------------------------------
-- Was: any allowlisted account (scope_profiles_to_allowlist.sql). Now: only
-- yourself, someone you share a conversation with, or a contact. Everyone
-- else is hidden by the server, not only by the app -- an older build that
-- still selects every profile now simply sees fewer rows (see the tail
-- comment); it never gets an error, because it is still allowed to read the
-- rows it gets, just fewer of them.
drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using ((select app_private.has_app_access())
         and app_private.is_allowed(user_id)
         and (user_id = (select auth.uid())
              or app_private.shares_conversation(user_id)
              or app_private.is_contact(user_id)));

-- Exact-tag search ----------------------------------------------------------
-- Same fold tag_base uses when generating a tag from a name (lower-case,
-- Turkish and Latin diacritics collapsed) but without tag_base's underscore
-- collapsing or truncation: a lookup must match a STORED tag exactly, never
-- guess at one. A leading '@' is optional and stripped either way.
create or replace function app_private.normalise_tag_query(input text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(
    translate(replace(lower(btrim(coalesce(input, ''))), chr(775), ''),
              'çğıöşüâîûéèêëáàäíìïóòúùñ',
              'cgiosuaiueeeeaaaiiioouun'),
    '^@', '')
$$;
revoke all on function app_private.normalise_tag_query(text) from public, anon, authenticated;

-- Per-caller lookup history, for the rate limits below. `kind` separates
-- find_by_tag's budget from is_tag_available's own (F6): an unlimited typing
-- check would otherwise be a free existence oracle even with find_by_tag
-- itself limited. Self-pruned in each caller rather than by a scheduled job:
-- nothing else ever reads this table.
create table app_private.tag_lookups (
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null default 'find' check (kind in ('find', 'availability')),
  called_at  timestamptz not null default now()
);
create index tag_lookups_user_idx on app_private.tag_lookups(user_id, kind, called_at);
revoke all on app_private.tag_lookups from public, anon, authenticated;
alter table app_private.tag_lookups enable row level security;

-- At most one allowlisted profile, exact match only -- never a partial or
-- prefix match, so this can never be used to browse the member list letter by
-- letter. Rate-limited per caller (20 calls / 10 minutes; propose changing
-- this pair together, not one alone) to stop even exact guesses from
-- enumerating tags quickly. A limit hit raises SQLSTATE 'RLMT1', a code
-- reserved for exactly this, so the app can show "Too many searches, try
-- again later" instead of a generic failure.
--
-- Locked per caller (F5) before the prune/insert/count: without it, two
-- calls racing in the same window can each see the same under-the-limit
-- count and both proceed, letting a caller running requests in parallel
-- slip past 20 in a window. pg_advisory_xact_lock blocks the second call
-- until the first's transaction ends, and releases automatically then --
-- never held past this call.
--
-- Records a find in tag_finds (F1) so the result this call is about to
-- return becomes reachable -- start_direct_conversation and contacts_insert
-- would otherwise refuse the very person this call just found.
create or replace function public.find_by_tag(search_tag text)
returns table (user_id uuid, display_name text, tag text, avatar_path text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me        uuid := auth.uid();
  candidate text;
  recent    int;
  hit       uuid;
begin
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

  insert into app_private.tag_finds(finder, found_id) values (me, hit)
    on conflict (finder, found_id) do update set found_at = now();

  return query
    select p.user_id, p.display_name, p.tag, p.avatar_path
      from public.profiles p
     where p.user_id = hit;
end $$;
revoke all on function public.find_by_tag(text) from public, anon;
grant execute on function public.find_by_tag(text) to authenticated;

-- The tag field's live-typing availability check (tags_and_onboarding.sql)
-- had no rate limit at all: an unlimited exact-existence oracle over every
-- tag (F6). Its own budget, generous enough that the settings/onboarding
-- field's existing 400ms debounce (profile_form.dart) never trips it during
-- normal typing of a ~20-character tag, but bounded all the same. Same lock
-- pattern as find_by_tag, a separate key so the two budgets never interact.
create or replace function public.is_tag_available(candidate text) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare
  me     uuid := auth.uid();
  recent int;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('is_tag_available:' || me::text, 0));

  delete from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'availability' and t.called_at < now() - interval '10 minutes';
  insert into app_private.tag_lookups(user_id, kind) values (me, 'availability');
  select count(*) into recent from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'availability';
  if recent > 60 then
    raise exception 'too many searches' using errcode = 'RLMT1';
  end if;

  if candidate is null or candidate !~ '^[a-z][a-z0-9_]{2,19}$' then
    return false;
  end if;
  -- The caller's own current tag counts as available to them.
  return not exists (
    select 1 from public.profiles p
     where p.tag = candidate and p.user_id <> me);
end $$;
revoke all on function public.is_tag_available(text) from public, anon;
grant execute on function public.is_tag_available(text) to authenticated;

-- Reach applied to the RPCs F1 named ----------------------------------------
-- start_direct_conversation and start_group_conversation (v0.2/v0.3) and
-- last_seen_of (v0.6) all accepted any allowlisted id -- exactly the hole
-- can_reach above closes. Redefined here rather than in their original
-- migrations, which are already shipped.

-- Was: any allowlisted, confirmed account. Now: also can_reach -- a shared
-- conversation, a saved contact, or a tag search that already found them.
-- Same failure either way (42501, shown as "Not allowed"), so this is not a
-- visible behaviour change for the cases that already worked.
create or replace function public.start_direct_conversation(other_user uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me  uuid := auth.uid();
  key text;
  cid uuid;
begin
  if not app_private.has_app_access() or other_user is null or other_user = me then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.is_allowed(other_user) or not app_private.can_reach(other_user) then
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
end $$;
revoke all on function public.start_direct_conversation(uuid) from public, anon;
grant execute on function public.start_direct_conversation(uuid) to authenticated;

-- Every invitee must be allowlisted AND reachable. One such invitee fails
-- the whole call (42501, "Not allowed") rather than silently creating a
-- smaller group than asked for -- the same all-or-nothing shape the
-- allowlist-only check already had.
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

  -- Deduplicate and drop the caller if they listed themselves.
  select array_agg(distinct m) into invited
    from unnest(coalesce(members, '{}'::uuid[])) as m
   where m is distinct from me;

  if invited is null or array_length(invited, 1) < 1 then
    raise exception 'a group needs at least one other member'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from unnest(invited) as m
     where not app_private.is_allowed(m) or not app_private.can_reach(m)
  ) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  insert into public.conversations(title) values (clean) returning id into cid;
  insert into public.conversation_members(conversation_id, user_id)
    select cid, m from unnest(invited || me) as m;
  return cid;
end $$;
revoke all on function public.start_group_conversation(text, uuid[])
  from public, anon;
grant execute on function public.start_group_conversation(text, uuid[])
  to authenticated;

-- F3: last_seen_of answered for any allowlisted person; now also requires
-- can_reach, on top of the existing mutual sharing rule.
create or replace function public.last_seen_of(person uuid)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select s.seen_at
    from app_private.last_seen s
    join public.profiles them on them.user_id = s.user_id
    join public.profiles me   on me.user_id = auth.uid()
   where s.user_id = person
     and them.share_last_seen
     and me.share_last_seen
     and app_private.has_app_access()
     and app_private.is_allowed(person)
     and app_private.can_reach(person)
$$;
revoke all on function public.last_seen_of(uuid) from public, anon;
grant execute on function public.last_seen_of(uuid) to authenticated;

-- Older builds and profiles_read ---------------------------------------
-- SupabaseChatRepository.members(), conversationMembers() and the
-- conversation list's "other member" lookup all `select ... from profiles`
-- with no extra filter beyond RLS -- so after this migration they simply
-- receive fewer rows: people the caller neither shares a conversation with
-- nor has as a contact drop out silently. None of the three selects a
-- missing profile by id and dereferences it (conversation list already
-- falls back to 'Member' when a profile row is absent), so this is a
-- narrower result, never a crash. min_supported_build does not need to move.
