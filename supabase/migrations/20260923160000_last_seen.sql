-- Last seen (v0.6), mutual and enforced here (owner, 2026-09-23): a member
-- who hides their own last seen cannot see anyone else's.
--
-- The time itself lives outside every client-readable table. Two functions
-- are the only way in: touch_last_seen() for the caller's own time, and
-- last_seen_of() for someone else's, which answers only when both share.

alter table public.profiles
  add column share_last_seen boolean not null default true;
grant update (share_last_seen) on public.profiles to authenticated;

create table app_private.last_seen (
  user_id uuid primary key references auth.users(id) on delete cascade,
  seen_at timestamptz not null
);
revoke all on app_private.last_seen from public, anon, authenticated;
-- Belt and braces, like every other app_private table: no policies, so even
-- a stray grant would read nothing.
alter table app_private.last_seen enable row level security;

-- Records "now" for the caller -- only while they share. The app calls it
-- when it opens and when it goes to the background.
-- ponytail: an app killed without going to the background keeps the time it
-- was last opened; a periodic heartbeat would fix that at a write per minute.
create or replace function public.touch_last_seen()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  -- Lock the profile row: a concurrent opt-out then either waits for this
  -- write (and its trigger deletes it) or is seen here (nothing is written).
  -- Without the lock a touch racing an opt-out could store a time the member
  -- had just chosen to hide.
  perform 1 from public.profiles p
   where p.user_id = auth.uid() and p.share_last_seen
     for share;
  if not found then
    return;
  end if;
  insert into app_private.last_seen(user_id, seen_at)
  values (auth.uid(), now())
  on conflict (user_id) do update set seen_at = excluded.seen_at;
end $$;
revoke all on function public.touch_last_seen() from public, anon;
grant execute on function public.touch_last_seen() to authenticated;

-- [person]'s last seen, or null: unknown, not shared by them, or not shared
-- by the caller (the mutual rule), or the caller has no app access. The same
-- null for every refusal: the call itself reveals nothing beyond what
-- profiles.share_last_seen, readable like the other sharing switches, says.
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
$$;
revoke all on function public.last_seen_of(uuid) from public, anon;
grant execute on function public.last_seen_of(uuid) to authenticated;

-- Hiding it also forgets it: nothing stored that the member chose not to
-- share. Turning it back on starts fresh from the next touch.
create or replace function app_private.forget_last_seen() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from app_private.last_seen where user_id = new.user_id;
  return new;
end $$;
revoke all on function app_private.forget_last_seen() from public, anon, authenticated;

create trigger profiles_forget_last_seen
  after update of share_last_seen on public.profiles
  for each row when (old.share_last_seen and not new.share_last_seen)
  execute function app_private.forget_last_seen();
