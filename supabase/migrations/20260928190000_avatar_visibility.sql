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
-- (profiles_public view, below) and the storage read policy
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

alter table public.profiles
  add column avatar_visibility text not null default 'everyone'
    check (avatar_visibility in ('everyone', 'contacts', 'nobody'));
grant update (avatar_visibility) on public.profiles to authenticated;

-- Whether the caller may see [owner]'s picture right now (not their row --
-- profiles_read decides that separately, and avatar visibility is scoped to
-- readers of the row already except for one deliberate widening below).
--
-- 'everyone': ANY active allowlisted member, not only someone who can
-- already read the profile ROW. Today's default behaviour for everyone who
-- has not changed it, and the same rule that lets a fresh find_by_tag result
-- show a picture at the moment it is found -- before the finder has added
-- the person or started a chat, so before shares_conversation/is_contact
-- would otherwise pass. The object's key is a random path under the owner's
-- own folder (see avatars.sql), never discoverable except through a read
-- this function, profiles_public or find_by_tag already gated -- so this is
-- exactly as wide as "any active member who can name the file", not wider.
-- 'contacts': only readers the OWNER has saved.
-- 'nobody': only the owner.
create or replace function app_private.avatar_visible_to(owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select owner = (select auth.uid())
     or exists (
       select 1 from public.profiles p
        where p.user_id = owner
          and (
            (p.avatar_visibility = 'everyone' and app_private.is_allowed(owner))
            or (p.avatar_visibility = 'contacts'
                and exists (select 1 from public.contacts c
                             where c.owner_id = owner
                               and c.contact_id = (select auth.uid())))
          ))
$$;
revoke all on function app_private.avatar_visible_to(uuid) from public, anon;
grant execute on function app_private.avatar_visible_to(uuid) to authenticated;

-- Storage: the same test the app now uses to decide whether to even show the
-- path (profiles_public, find_by_tag). Was app_private.is_allowed(owner)
-- alone -- exactly what avatar_visible_to's 'everyone' branch still is, so
-- this only narrows the 'contacts' and 'nobody' cases.
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

-- A view PostgREST can select from directly, in place of the bare `profiles`
-- table, wherever the app shows someone ELSE's picture: `avatar_path` is
-- null for a reader avatar_visible_to refuses, same as no picture at all --
-- the app already renders a null avatar_path as the initials circle, so
-- nothing new is needed there, and a cached copy of a picture that just
-- became hidden is simply never looked up again once its path stops being
-- returned. security_invoker (the default, stated for clarity) means row
-- visibility still comes from profiles_read on the underlying table; this
-- only narrows one column further.
create or replace view public.profiles_public
  with (security_invoker = true) as
select
  p.user_id,
  p.display_name,
  p.tag,
  case when app_private.avatar_visible_to(p.user_id) then p.avatar_path else null end
    as avatar_path
from public.profiles p;
grant select on public.profiles_public to authenticated;

-- find_by_tag's own picture, masked the same way (its row bypasses
-- profiles_read entirely -- security definer -- so it must apply the same
-- rule itself rather than inherit it).
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
    select p.user_id, p.display_name, p.tag,
           case when app_private.avatar_visible_to(p.user_id) then p.avatar_path else null end
      from public.profiles p
     where p.tag = candidate
       and p.user_id <> me
       and app_private.is_allowed(p.user_id)
     limit 1;
end $$;
revoke all on function public.find_by_tag(text) from public, anon;
grant execute on function public.find_by_tag(text) to authenticated;
