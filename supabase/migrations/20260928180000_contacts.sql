-- Contacts, exact-tag search, and tighter profile visibility (v0.22.0).
--
-- New chat stops listing every allowlisted member. From here a member's
-- "your people" is their contacts plus whoever they already share a
-- conversation with; anyone else is found only by typing their exact tag.
-- `profiles` is narrowed to match: readable only for yourself, someone you
-- share a conversation with, or a contact. The exact-tag lookup below is the
-- one deliberate hole in that rule -- it returns its one row itself
-- (security definer), so it needs no broad read.
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

create policy contacts_read on public.contacts for select to authenticated
  using ((select app_private.has_app_access()) and owner_id = (select auth.uid()));

-- Both sides must be allowlisted, like starting a conversation
-- (start_direct_conversation checks the same thing for the other party).
create policy contacts_insert on public.contacts for insert to authenticated
  with check ((select app_private.has_app_access())
              and owner_id = (select auth.uid())
              and contact_id <> owner_id
              and app_private.is_allowed(contact_id));

create policy contacts_delete on public.contacts for delete to authenticated
  using ((select app_private.has_app_access()) and owner_id = (select auth.uid()));

grant select, insert, delete on public.contacts to authenticated;

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
-- "have I saved them", used by profiles_read below. avatar_visibility's
-- "my contacts" (added next migration) asks the opposite direction.
create or replace function app_private.is_contact(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.contacts c
     where c.owner_id = (select auth.uid()) and c.contact_id = other)
$$;
revoke all on function app_private.is_contact(uuid) from public, anon;
grant execute on function app_private.is_contact(uuid) to authenticated;

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

-- Per-caller lookup history, for the rate limit below. Self-pruned in
-- find_by_tag rather than by a scheduled job: nothing else ever reads it.
create table app_private.tag_lookups (
  user_id    uuid not null references auth.users(id) on delete cascade,
  called_at  timestamptz not null default now()
);
create index tag_lookups_user_idx on app_private.tag_lookups(user_id, called_at);
revoke all on app_private.tag_lookups from public, anon, authenticated;
alter table app_private.tag_lookups enable row level security;

-- At most one allowlisted profile, exact match only -- never a partial or
-- prefix match, so this can never be used to browse the member list letter by
-- letter. Rate-limited per caller (20 calls / 10 minutes; propose changing
-- this pair together, not one alone) to stop even exact guesses from
-- enumerating tags quickly. A limit hit raises SQLSTATE 'RLMT1', a code
-- reserved for exactly this, so the app can show "Too many searches, try
-- again later" instead of a generic failure.
create or replace function public.find_by_tag(search_tag text)
returns table (user_id uuid, display_name text, tag text, avatar_path text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me        uuid := auth.uid();
  candidate text;
  recent    int;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  delete from app_private.tag_lookups t
   where t.user_id = me and t.called_at < now() - interval '10 minutes';
  insert into app_private.tag_lookups(user_id) values (me);
  select count(*) into recent from app_private.tag_lookups t where t.user_id = me;
  if recent > 20 then
    raise exception 'too many searches' using errcode = 'RLMT1';
  end if;

  candidate := app_private.normalise_tag_query(search_tag);
  if candidate !~ '^[a-z][a-z0-9_]{2,19}$' then
    return;
  end if;

  return query
    select p.user_id, p.display_name, p.tag, p.avatar_path
      from public.profiles p
     where p.tag = candidate
       and p.user_id <> me
       and app_private.is_allowed(p.user_id)
     limit 1;
end $$;
revoke all on function public.find_by_tag(text) from public, anon;
grant execute on function public.find_by_tag(text) to authenticated;

-- Older builds and profiles_read ---------------------------------------
-- SupabaseChatRepository.members(), conversationMembers() and the
-- conversation list's "other member" lookup all `select ... from profiles`
-- with no extra filter beyond RLS -- so after this migration they simply
-- receive fewer rows: people the caller neither shares a conversation with
-- nor has as a contact drop out silently. None of the three selects a
-- missing profile by id and dereferences it (conversation list already
-- falls back to 'Member' when a profile row is absent), so this is a
-- narrower result, never a crash. min_supported_build does not need to move.
