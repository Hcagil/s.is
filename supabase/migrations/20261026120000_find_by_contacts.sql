-- Find people from contacts. The caller sends SHA-256 hex hashes of
-- lower(btrim(email)); the function returns the allowlisted members they match.
-- Limits: 3 calls per hour and 10 per 24 hours per member, 2000 hashes per call.
-- Errors: 42501 not permitted, RLMT1 limit hit, 22023 bad input.
-- Nothing is stored except the rate-limit row and the tag_finds reach row.

alter table app_private.tag_lookups drop constraint tag_lookups_kind_check;
alter table app_private.tag_lookups add constraint tag_lookups_kind_check
  check (kind in ('find', 'availability', 'contacts'));

create or replace function public.find_by_contacts(hashes text[])
returns table (user_id uuid, display_name text, tag text, avatar_path text, matched_hash text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  me         uuid := auth.uid();
  recent     int;
  recent_day int;
  wanted     text[];
begin
  if app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('find_by_contacts:' || me::text, 0));

  -- This kind is pruned at 24 hours because the daily cap needs that history.
  delete from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'contacts' and t.called_at < now() - interval '24 hours';
  insert into app_private.tag_lookups(user_id, kind) values (me, 'contacts');
  select count(*) into recent from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'contacts' and t.called_at >= now() - interval '1 hour';
  select count(*) into recent_day from app_private.tag_lookups t
   where t.user_id = me and t.kind = 'contacts';
  if recent > 3 or recent_day > 10 then
    raise exception 'too many searches' using errcode = 'RLMT1';
  end if;

  if hashes is null or cardinality(hashes) = 0 then
    return;
  end if;
  if cardinality(hashes) > 2000
     or exists (select 1 from unnest(hashes) h where h is null or h !~ '^[0-9a-f]{64}$') then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  select array_agg(distinct h) into wanted from unnest(hashes) h;

  -- shortcut: hashes allowlist emails per call, add a stored hash column with index if the allowlist reaches tens of thousands
  insert into app_private.tag_finds(finder, found_id)
    select me, m.uid
      from (
        select u.id as uid, encode(sha256(convert_to(a.email, 'UTF8')), 'hex') as h
          from app_private.allowlist a
          join auth.users u on lower(btrim(u.email)) = a.email
         where u.email_confirmed_at is not null
           and u.deleted_at is null
           and (u.banned_until is null or u.banned_until <= now())
           and u.id <> me
           and not app_private.is_bot(u.id)
           and encode(sha256(convert_to(a.email, 'UTF8')), 'hex') = any(wanted)
      ) m
    on conflict (finder, found_id) do update set found_at = now();

  return query
    select p.user_id, p.display_name, p.tag,
           case when app_private.avatar_visible_to(p.user_id) then p.avatar_object else null end,
           m.h
      from (
        select u.id as uid, encode(sha256(convert_to(a.email, 'UTF8')), 'hex') as h
          from app_private.allowlist a
          join auth.users u on lower(btrim(u.email)) = a.email
         where u.email_confirmed_at is not null
           and u.deleted_at is null
           and (u.banned_until is null or u.banned_until <= now())
           and u.id <> me
           and not app_private.is_bot(u.id)
           and encode(sha256(convert_to(a.email, 'UTF8')), 'hex') = any(wanted)
      ) m
      join public.profiles p on p.user_id = m.uid;
end $$;
revoke all on function public.find_by_contacts(text[]) from public, anon;
grant execute on function public.find_by_contacts(text[]) to authenticated;
