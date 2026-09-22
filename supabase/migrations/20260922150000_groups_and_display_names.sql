-- Group conversations and member-editable display names for SIS v0.3.
--
-- Additive: a 1:1 conversation is one with a direct_key and no title, exactly
-- as v0.2 created it, so builds from v0.2 keep working unchanged.

-- Groups --------------------------------------------------------------------
-- A conversation is a group when it has a title. 1:1 conversations keep their
-- unique direct_key and a null title; groups have a null direct_key, which the
-- unique index ignores, so any number of groups may share the same people.
alter table public.conversations
  add column title text
  check (title is null or char_length(btrim(title)) between 1 and 80);

-- Membership is server-authored for groups too: neither conversations nor
-- conversation_members has a client write policy, so this RPC is the only way
-- a group comes into existence.
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

  -- Every invitee must be a confirmed, allowlisted account. One stranger in
  -- the list fails the whole call rather than silently creating a smaller
  -- group than the caller asked for.
  if exists (
    select 1 from unnest(invited) as m
     where not app_private.is_allowed(m)
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

-- Display names -------------------------------------------------------------
-- The signup trigger seeds a display name from the Google profile; from v0.3 a
-- member may change their own. Column-level, so nothing else on the row can be
-- rewritten, and the policy pins the row to the caller.
create policy profiles_update_own on public.profiles for update to authenticated
  using (app_private.has_app_access() and user_id = auth.uid())
  with check (app_private.has_app_access() and user_id = auth.uid());
grant update (display_name) on public.profiles to authenticated;
