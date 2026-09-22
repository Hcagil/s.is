-- Member tags and first-run onboarding (v0.4).
--
-- A tag is a unique handle (`@hayrullah_cagil`) alongside the display name,
-- which is not unique. Every profile always has one: it is generated from the
-- name at sign-up and can be changed during onboarding or in settings.
--
-- Additive for older builds: they never read these columns.

alter table public.profiles
  add column tag text
    check (tag ~ '^[a-z][a-z0-9_]{2,19}$'),
  add column onboarding_done boolean not null default false;
create unique index profiles_tag_key on public.profiles (tag);

-- Name -> tag candidate: lower-case, common Turkish and Latin diacritics
-- folded, everything else collapsed to underscores, starting with a letter.
-- chr(775) is the combining dot that lower('İ') leaves behind.
create or replace function app_private.tag_base(name text) returns text
language sql immutable set search_path = '' as $$
  -- Cut to 20 AFTER prefixing: prefixing a 20-character base that starts
  -- with a digit would otherwise make 21, which the check constraint refuses.
  select left(case when s ~ '^[a-z]' then s else 'u' || s end, 20)
    from (select left(btrim(regexp_replace(
                   translate(replace(lower(coalesce(name, '')), chr(775), ''),
                             'çğıöşüâîûéèêëáàäíìïóòúùñ',
                             'cgiosuaiueeeeaaaiiioouun'),
                   '[^a-z0-9]+', '_', 'g'), '_'), 20) as s) t
$$;
revoke all on function app_private.tag_base(text) from public, anon, authenticated;

-- A tag for a new member: the name's base when free, else the base with a
-- piece of the user id, which is unique to that member.
create or replace function app_private.fresh_tag(name text, uid uuid) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  b text := app_private.tag_base(name);
begin
  if char_length(b) < 3 then
    b := 'member';
  end if;
  if not exists (select 1 from public.profiles p where p.tag = b) then
    return b;
  end if;
  return left(b, 13) || '_' || left(replace(uid::text, '-', ''), 6);
end $$;
revoke all on function app_private.fresh_tag(text, uuid) from public, anon, authenticated;

-- The sign-up trigger now assigns a tag. It must still never abort a sign-up
-- (access_test.sql holds it to that): two people with the same name signing up
-- at the same instant can both see the base as free, so a unique violation
-- falls back to a tag made from the user id alone -- 'u' plus 19 hex digits,
-- unique because the id is.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  name text := app_private.display_name_for(new);
begin
  begin
    insert into public.profiles(user_id, display_name, tag)
    values (new.id, name, app_private.fresh_tag(name, new.id))
    on conflict (user_id) do nothing;
  -- unique_violation: a same-name race. check_violation: any tag the
  -- generator gets wrong. Either way the member still gets a profile.
  exception when unique_violation or check_violation then
    insert into public.profiles(user_id, display_name, tag)
    values (new.id, name, 'u' || left(replace(new.id::text, '-', ''), 19))
    on conflict (user_id) do nothing;
  end;
  return new;
end $$;
-- create or replace keeps the existing ACL; restated so the intent is explicit.
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- Existing members get a tag, oldest first so the earliest account keeps the
-- plain base when two share a name. Sequential, so each sees the last.
do $$
declare
  r record;
begin
  for r in select user_id, display_name from public.profiles
            where tag is null order by created_at, user_id loop
    update public.profiles
       set tag = app_private.fresh_tag(r.display_name, r.user_id)
     where user_id = r.user_id;
  end loop;
end $$;
alter table public.profiles alter column tag set not null;

-- Availability for the tag field's live check. Security definer because the
-- unique index counts EVERY account -- including ones the allowlist denies,
-- whose profiles RLS hides -- so an RLS-scoped lookup would call a taken tag
-- free and the save would then fail. Advisory only: the unique index is the
-- authority, and a tag taken between the check and the save is refused there.
create or replace function public.is_tag_available(candidate text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if candidate is null or candidate !~ '^[a-z][a-z0-9_]{2,19}$' then
    return false;
  end if;
  -- The caller's own current tag counts as available to them.
  return not exists (
    select 1 from public.profiles p
     where p.tag = candidate and p.user_id <> auth.uid());
end $$;
revoke all on function public.is_tag_available(text) from public, anon;
grant execute on function public.is_tag_available(text) to authenticated;

-- A member edits their own tag and marks onboarding done through the same
-- column-level grant as the display name; profiles_update_own already pins the
-- row to the caller. Grants are additive: display_name stays grantable.
grant update (tag, onboarding_done) on public.profiles to authenticated;
