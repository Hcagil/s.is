-- Profile picture privacy (v0.22.0, add-on to contacts.sql): who sees my
-- picture -- Everyone / My contacts / Nobody, default Everyone (today's
-- behaviour). One-way, like the tag ADR's other one-way settings and unlike
-- the mutual last-seen/read-status pair: hiding yours never hides anyone
-- else's from you.
--
-- "My contacts" means the picture's OWNER saved the reader -- sharing a
-- group does not count, and it is not required to be mutual: reader B sees
-- owner A's "contacts-only" picture only if A saved B, whether or not B
-- saved A back.
--
-- Enforced in two places that must agree, same as avatar_path_readable
-- already does for the profiles_read/membership rule: the path itself
-- (profiles_public function, below) and the storage read policy
-- (avatar_path_readable, redefined below). A member who cannot see a path in
-- the first place obviously cannot download it either, but a member who CAN
-- see the row must still be refused the object when the picture's owner set
-- their picture to fewer people than their profile.
--
-- Additive for older builds: avatar_visibility defaults to 'everyone', so a
-- build that never shows the new setting keeps exactly today's behaviour for
-- its own picture, and still receives every avatar_path it did before this
-- (now possibly null, which they already render as initials -- avatar_path
-- has been nullable since v0.17).
--
-- Security-lead findings F2 and F4 (2026-09-28) landed on this same
-- migration rather than a follow-on, since it had not shipped yet:
--
-- F2: `profiles.avatar_path` and `avatar_visibility` were plain columns, so
-- RLS's row-level grant (anyone sharing a conversation or holding a contact)
-- leaked BOTH the real path and the setting regardless of what the setting
-- said -- a 'nobody' owner's picture and choice were readable to anyone who
-- could read the row at all. Fixed by splitting the path in two: the real
-- value moves to a new column, `avatar_object`, with no client SELECT grant
-- at all (only a security-definer function may read it for someone other
-- than its owner, and only when avatar_visible_to agrees); `avatar_path`
-- stays, but becomes a trigger-maintained shadow that holds the real value
-- ONLY while the owner's setting is 'everyone' and is null otherwise -- so
-- an old build (v0.21) selecting `avatar_path` straight off `profiles`, with
-- no idea `avatar_visibility` or masking exist, sees exactly what
-- avatar_visible_to's 'everyone' branch would show it anyway, and nothing
-- when the owner chose fewer people. `avatar_visibility` itself has no safe
-- masked value (it is not owner-dependent the way a path can be nulled), so
-- its SELECT grant is revoked outright; the owner reads and writes their own
-- through the new `own_profile()` RPC below, which bypasses the revoke the
-- same way every other security-definer function here bypasses RLS: it runs
-- as the table owner, not as `authenticated`.
--
-- F4: avatar_visible_to's 'contacts' branch checked contacts but not
-- is_allowed(owner); the 'everyone' branch already had it. Hoisted the
-- check out so it applies once, to every branch but the owner's own.
alter table public.profiles
  add column avatar_visibility text not null default 'everyone'
    check (avatar_visibility in ('everyone', 'contacts', 'nobody'));

-- The real, unmasked path. Same shape check avatar_path always had.
-- Backfilled from avatar_path: every existing row's avatar_visibility is
-- 'everyone' (the column default, just added, before any owner has had a
-- chance to change it), so the existing avatar_path value is exactly what
-- avatar_object should hold.
alter table public.profiles
  add column avatar_object text
  check (avatar_object is null or char_length(avatar_object) between 3 and 400);
update public.profiles set avatar_object = avatar_path where avatar_path is not null;

-- avatar_path becomes a maintained shadow of avatar_object, masked by
-- visibility, so ANY select of it -- including one an old build makes with
-- no idea this migration exists -- already reflects the current setting.
-- BEFORE trigger: sets NEW directly, no second statement, no recursion.
--
-- C1 (security re-gate, 2026-09-28): a v0.21 build still writes the OLD way
-- -- `.update({'avatar_path': path})` to set a picture, `.update({
-- 'avatar_path': null})` to remove one -- with no idea avatar_object exists.
-- It must keep working (never force an update): when avatar_path is the
-- column that actually changed and avatar_object did not, treat the write as
-- targeting avatar_object -- same value, same pin check on the way out
-- (profiles_update_own's WITH CHECK runs against this trigger's output, so
-- an old build writing outside its own folder is still refused). The masking
-- assignment below then runs on that adopted value exactly as it would for a
-- current build writing avatar_object directly, so a null clears both
-- columns and a same-folder path shows or hides per the current
-- avatar_visibility.
create or replace function app_private.sync_legacy_avatar_path() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.avatar_path is distinct from old.avatar_path
     and new.avatar_object is not distinct from old.avatar_object then
    new.avatar_object := new.avatar_path;
  end if;
  new.avatar_path := case when new.avatar_visibility = 'everyone'
                           then new.avatar_object else null end;
  return new;
end $$;
revoke all on function app_private.sync_legacy_avatar_path() from public, anon, authenticated;

create trigger profiles_sync_legacy_avatar_path
  before insert or update of avatar_path, avatar_object, avatar_visibility on public.profiles
  for each row execute function app_private.sync_legacy_avatar_path();

-- Client write access: avatar_object is the pinned column current builds
-- write; avatar_path stays grant-update (avatars.sql) so a v0.21 build can
-- still set/remove its own picture the old way (C1, above) -- the trigger
-- adopts that write into avatar_object before the row policy's pin check
-- runs. avatar_visibility stays writable (an owner may always change their
-- own setting); its SELECT grant is handled below, with avatar_object's.
grant update (avatar_object) on public.profiles to authenticated;
grant update (avatar_visibility) on public.profiles to authenticated;

-- profiles_update_own (avatars.sql) pinned avatar_path to the caller's own
-- folder; redefined to pin avatar_object instead, same shape check
-- (avatar_path_pinned), same reasoning.
drop policy profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()))
  with check (
    (select app_private.has_app_access())
    and user_id = (select auth.uid())
    and (avatar_object is null
         or app_private.avatar_path_pinned(avatar_object, 'profile/' || user_id::text))
  );

-- F2: profiles' table-level SELECT grant (identity_and_access.sql) covers
-- every column, present or future, including avatar_visibility and
-- avatar_object -- a column-level REVOKE cannot narrow a table-level GRANT
-- in Postgres, so the only way to withhold a column is to revoke the
-- table-level grant and re-grant explicitly by column. Every column that
-- was previously selectable stays selectable; avatar_visibility and
-- avatar_object simply are not re-granted. RLS (profiles_read) still
-- decides which ROWS come back; this narrows which COLUMNS of those rows
-- do. The owner's own row is unaffected in practice: own_profile() below
-- reads it as the table owner, not as `authenticated`.
revoke select on public.profiles from authenticated;
grant select (
  user_id, display_name, created_at, tag, onboarding_done,
  share_presence, share_typing, share_last_seen, share_read_status,
  avatar_path
) on public.profiles to authenticated;

-- The owner's own settings and picture, unmasked -- the only way the app
-- reads avatar_visibility or its own avatar_object now that both lost their
-- client SELECT grant. Security definer: runs as the table owner, so the
-- revoke above does not apply to it: it filters to the caller's own row
-- itself instead. Same shape as `_columns` in supabase_profile_repository.
-- dart's old `.select(_columns)` -- the app's load()/save()/setAvatar()/
-- removeAvatar() all call this now instead of selecting the columns
-- directly.
create or replace function public.own_profile()
returns table (
  user_id uuid,
  display_name text,
  tag text,
  onboarding_done boolean,
  share_presence boolean,
  share_typing boolean,
  share_last_seen boolean,
  share_read_status boolean,
  avatar_path text,
  avatar_visibility text
) language sql stable security definer set search_path = '' as $$
  select p.user_id, p.display_name, p.tag, p.onboarding_done,
         p.share_presence, p.share_typing, p.share_last_seen, p.share_read_status,
         p.avatar_object, p.avatar_visibility
    from public.profiles p
   where p.user_id = (select auth.uid())
     and app_private.has_app_access()
$$;
revoke all on function public.own_profile() from public, anon;
grant execute on function public.own_profile() to authenticated;

-- Whether the caller may see [owner]'s picture right now (not their row --
-- profiles_read decides that separately, and avatar visibility is scoped to
-- readers of the row already except for one deliberate widening below).
--
-- 'everyone': any member who can REACH the owner (F1/can_reach), not only
-- someone who can already read the profile ROW -- the same rule that lets a
-- fresh find_by_tag result show a picture at the moment it is found, before
-- the finder has added the person or started a chat (found_by_tag, one of
-- can_reach's own branches, is what makes that true). Was "any active
-- allowlisted member" with no reach requirement at all (F1): the object's
-- key is a random path under the owner's own folder, discoverable only
-- through a read this function, profiles_public or find_by_tag already
-- gated, but a member who could never otherwise learn the owner's id had no
-- business being handed the path regardless.
--
-- I1 (security re-gate, 2026-09-28): "everyone" must be a superset of
-- "contacts", so a reader the owner has saved sees an 'everyone' picture
-- even when can_reach is false (e.g. the owner saved a tag-find result but
-- never messaged them, or the contact was saved before any shared
-- conversation) -- also OR the same "owner saved reader" check the
-- 'contacts' branch below uses.
-- 'contacts': only readers the OWNER has saved -- and, as of F4, only when
-- the owner is still allowed (hoisted below, applies to both branches).
-- 'nobody': only the owner.
create or replace function app_private.avatar_visible_to(owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select owner = (select auth.uid())
     or exists (
       select 1 from public.profiles p
        where p.user_id = owner
          and app_private.is_allowed(owner)
          and (
            (p.avatar_visibility = 'everyone' and (
               app_private.can_reach(owner)
               or exists (select 1 from public.contacts c
                           where c.owner_id = owner
                             and c.contact_id = (select auth.uid()))))
            or (p.avatar_visibility = 'contacts'
                and exists (select 1 from public.contacts c
                             where c.owner_id = owner
                               and c.contact_id = (select auth.uid())))
          ))
$$;
revoke all on function app_private.avatar_visible_to(uuid) from public, anon;
grant execute on function app_private.avatar_visible_to(uuid) to authenticated;

-- Storage: the same test the app now uses to decide whether to even show the
-- path (profiles_public, find_by_tag).
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

-- In place of the bare `profiles` table, wherever the app shows someone
-- ELSE's picture: `avatar_path` is null for a reader avatar_visible_to
-- refuses, same as no picture at all -- the app already renders a null
-- avatar_path as the initials circle, so nothing new is needed there, and a
-- cached copy of a picture that just became hidden is simply never looked up
-- again once its path stops being returned.
--
-- A SECURITY DEFINER FUNCTION, not a security_invoker VIEW as first written:
-- the view read `p.avatar_object` inside its masking CASE, and Postgres
-- requires the QUERYING role to hold column SELECT on every column a
-- security_invoker view references to plan the query at all -- regardless
-- of whether the CASE ends up returning it -- so the view broke the moment
-- avatar_object's client grant was revoked (F2): every call failed
-- `permission denied for table profiles`, caught only by testing this
-- migration end-to-end through PostgREST, not by db lint or the pgTAP
-- suite. The fix already used everywhere else a masked or privileged read is
-- needed (find_by_tag, last_seen_of, own_profile): run as the table owner,
-- which needs no column grant, and repeat profiles_read's own row rule
-- explicitly instead of relying on RLS pass-through. `stable` so PostgREST
-- still serves it over GET with the same query parameters (select, eq, neq,
-- in, order) the app already sends -- a stable or immutable function is
-- queryable exactly like a view or table, not only callable as an RPC POST.
-- Table-level grants default to anon/authenticated on a new relation the
-- same way they do on a new table (F7) -- so execute is revoked first, then
-- granted only to authenticated, same shape as every other RPC here.
drop view if exists public.profiles_public;
create or replace function public.profiles_public()
returns table (user_id uuid, display_name text, tag text, avatar_path text)
language sql stable security definer set search_path = '' as $$
  select p.user_id, p.display_name, p.tag,
         case when app_private.avatar_visible_to(p.user_id) then p.avatar_object else null end
    from public.profiles p
   where app_private.has_app_access()
     and app_private.is_allowed(p.user_id)
     and (p.user_id = (select auth.uid())
          or app_private.shares_conversation(p.user_id)
          or app_private.is_contact(p.user_id))
$$;
revoke all on function public.profiles_public() from public, anon;
grant execute on function public.profiles_public() to authenticated;

-- find_by_tag's own picture, masked the same way (its row bypasses
-- profiles_read entirely -- security definer -- so it must apply the same
-- rule itself rather than inherit it). Full redefinition, not just the
-- returned expression: this is the same function contacts.sql defines
-- (lock, per-kind rate limit, tag_finds bookkeeping), reading avatar_object
-- instead of avatar_path now that avatar_object exists.
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
end $$;
revoke all on function public.find_by_tag(text) from public, anon;
grant execute on function public.find_by_tag(text) to authenticated;

-- L1 (security re-gate, 2026-09-28): a tag_finds row keeps a picture
-- reachable via can_reach/found_by_tag forever, including after the found
-- member renames their tag -- the finder never searched the NEW tag, so
-- nothing about this find is still true. AFTER trigger, WHEN clause does the
-- "actually changed" filter so a same-value UPDATE of tag (e.g. a no-op
-- save) does not scan tag_finds for nothing. Chats and contacts the find led
-- to are untouched -- can_reach's other branches (shares_conversation,
-- is_contact) do not depend on tag_finds at all.
create or replace function app_private.clear_tag_finds_on_rename() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from app_private.tag_finds where found_id = new.user_id;
  return new;
end $$;
revoke all on function app_private.clear_tag_finds_on_rename() from public, anon, authenticated;

create trigger profiles_clear_tag_finds_on_rename
  after update of tag on public.profiles
  for each row
  when (new.tag is distinct from old.tag)
  execute function app_private.clear_tag_finds_on_rename();
