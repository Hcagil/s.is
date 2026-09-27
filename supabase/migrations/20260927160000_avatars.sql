-- v0.17: a changeable picture for a member's own profile and for a group.
--
-- Additive: no avatar (both columns null) is exactly today's behaviour, so
-- builds that predate this keep showing initials unchanged.

alter table public.profiles
  add column avatar_path text
  check (avatar_path is null or char_length(avatar_path) between 3 and 400);

-- A conversation is a group when it has a title (see groups_and_display_
-- names.sql); a 1:1 must never carry an avatar_path -- set_group_avatar below
-- refuses to write one to anything but a group.
alter table public.conversations
  add column avatar_path text
  check (avatar_path is null or char_length(avatar_path) between 3 and 400);

-- A private bucket. Nothing is public: every read goes through the same
-- membership question the row it belongs to already answers.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 1048576, array['image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The object key is `profile/<user id>/<file>` or `group/<conversation id>/
-- <file>`. A fresh upload always mints a new file name rather than
-- overwriting the old one, so a cached copy of a previous picture is never
-- served as the new one; the app deletes the old object once the new one is
-- written. avatar_path_owner returns null (never a wrong owner) for anything
-- that does not fit that shape, so a malformed or foreign key never resolves
-- to someone else's uuid.
create or replace function app_private.avatar_path_owner(object_name text)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare
  segments text[] := storage.foldername(object_name);
begin
  if array_length(segments, 1) is distinct from 2
     or segments[2] !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  then
    return null;
  end if;
  return segments[2]::uuid;
end $$;
revoke all on function app_private.avatar_path_owner(text) from public, anon;
grant execute on function app_private.avatar_path_owner(text) to authenticated;

-- Read: whoever could already read the picture's owner -- profiles_read's
-- rule for a profile picture, membership for a group's.
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
    when 'profile' then app_private.is_allowed(owner)
    when 'group' then app_private.is_member(owner)
    else false
  end;
end $$;
revoke all on function app_private.avatar_path_readable(text) from public, anon;
grant execute on function app_private.avatar_path_readable(text) to authenticated;

-- Write/replace/delete: the caller's own path, or a group path for any of
-- its members -- the same "any member may change it" rule the group's
-- display name would follow if it were editable (start_group_conversation is
-- still the only writer of the name itself). The 'group' branch also checks
-- the conversation actually has a title: without it, any two members sharing
-- a 1:1 could write and read a "group" picture under that 1:1's id, which
-- set_group_avatar's own "not a group" check does not stop from ever
-- reaching storage in the first place.
create or replace function app_private.avatar_path_writable(object_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  kind  text := (storage.foldername(object_name))[1];
  owner uuid := app_private.avatar_path_owner(object_name);
begin
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
end $$;
revoke all on function app_private.avatar_path_writable(text) from public, anon;
grant execute on function app_private.avatar_path_writable(text) to authenticated;

-- Shared by profiles_update_own and set_group_avatar below: [path] sits
-- directly under [owner_prefix] (e.g. `profile/<uid>` or `group/<id>`) with
-- exactly one more segment -- no extra `/`, and that segment is not empty or
-- made only of dots (`.`, `..`), a path-traversal token nothing here ever
-- resolves, but which has no business in a stored value regardless.
create or replace function app_private.avatar_path_pinned(
  path text,
  owner_prefix text
) returns boolean language sql immutable set search_path = '' as $$
  select path like owner_prefix || '/%'
     and array_length(regexp_split_to_array(path, '/'), 1) = 3
     and split_part(path, '/', 3) !~ '^\.*$'
$$;
revoke all on function app_private.avatar_path_pinned(text, text) from public, anon;
grant execute on function app_private.avatar_path_pinned(text, text) to authenticated;

create policy avatars_read on storage.objects for select to authenticated
  using (bucket_id = 'avatars'
         and (select app_private.has_app_access())
         and app_private.avatar_path_readable(name));

create policy avatars_write on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars'
              and (select app_private.has_app_access())
              and app_private.avatar_path_writable(name)
              and owner_id = (select auth.uid())::text);

create policy avatars_remove on storage.objects for delete to authenticated
  using (bucket_id = 'avatars'
         and (select app_private.has_app_access())
         and app_private.avatar_path_writable(name));

-- No update policy: a changed picture is a new object (a new insert), never
-- an overwrite of an existing one -- the client removes the old object once
-- the new one is written, same as a deleted attachment.

-- Column-level write on the member's own row: same row policy profiles_
-- update_own already enforces (has_app_access() and user_id = (select auth.
-- uid())), extended to the new column. The policy is redefined (as
-- rls_access_check_once.sql already redefines it once, and pins the wrapped
-- form) to also pin the value's shape to the caller's own prefix -- exactly
-- what messages_send does for attachment_path (`split_part(attachment_path,
-- '/', 1) = conversation_id::text`), so a member can point their own row
-- only at their own folder, never at a real object under someone else's.
-- avatar_path_readable at download time is the actual authority either way
-- (a foreign path a member sets anyway is only ever as readable as it
-- already was to the same viewer), but the column should not need that
-- second check to hold.
drop policy profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()))
  with check (
    (select app_private.has_app_access())
    and user_id = (select auth.uid())
    and (avatar_path is null
         or app_private.avatar_path_pinned(avatar_path, 'profile/' || user_id::text))
  );
grant update (avatar_path) on public.profiles to authenticated;

-- Conversations have no update policy: nothing about a conversation is
-- client-writable today, including its title (start_group_conversation sets
-- it once, at creation). A group's avatar, like its membership, needs "am I
-- one of its members" rather than "do I own this row", so it goes through an
-- RPC that asks that question itself, the same shape as start_group_
-- conversation. It returns the conversation's previous avatar_path so the
-- caller can remove that file after -- delete_message does the same for a
-- removed attachment.
create or replace function public.set_group_avatar(
  conversation uuid,
  path text
) returns text language plpgsql security definer set search_path = '' as $$
declare
  previous text;
begin
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
  select avatar_path into previous
    from public.conversations
   where id = conversation and title is not null;
  if not found then
    raise exception 'not a group' using errcode = '22023';
  end if;
  update public.conversations set avatar_path = path where id = conversation;
  return previous;
end $$;
revoke all on function public.set_group_avatar(uuid, text) from public, anon;
grant execute on function public.set_group_avatar(uuid, text) to authenticated;
