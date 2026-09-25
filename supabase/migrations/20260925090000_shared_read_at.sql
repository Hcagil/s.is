-- v0.11 follow-up: reads made while "Show when I have read messages" was off
-- must stay hidden forever, not just until the switch is on again.
--
-- read_marks() used to return last_read_at whenever both members currently
-- share, so turning sharing off, reading, then turning it back on revealed
-- the read that was made while it was off. shared_read_at is the same idea
-- as last_read_at but only ever moves while the reader shares -- it is the
-- record of reads that were actually shared, not of reads at all.
--
-- last_read_at itself is untouched: unread_counts and mark_read's own-place
-- bookkeeping still need every read, shared or not.

alter table public.conversation_members
  add column shared_read_at timestamptz;

-- Backfill: a currently-sharing member keeps their last read as shared. One
-- read made during an off period in v0.11 cannot be told apart and stays
-- visible; v0.11 already showed it, so nothing new is exposed.
-- A member not currently sharing gets nothing backfilled -- whether their
-- last_read_at was earned while sharing or not is exactly what could not be
-- told apart before this migration, so the conservative read (hidden) wins.
update public.conversation_members cm
   set shared_read_at = cm.last_read_at
  from public.profiles p
 where p.user_id = cm.user_id
   and p.share_read_status;

-- New memberships start caught up, same as last_read_at: joined_at is
-- already public (granted below), so a shared_read_at equal to it discloses
-- nothing that joining itself did not already.
alter table public.conversation_members
  alter column shared_read_at set default now();

-- Column-level grant unchanged on purpose: shared_read_at is not listed, so
-- it stays as unreadable to clients as last_read_at (20260923150000).

create or replace function public.mark_read(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  sharing boolean := app_private.shares_read_status();
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversation_members m
     set last_read_at = now(),
         shared_read_at = case when sharing then now() else m.shared_read_at end
   where m.conversation_id = conversation
     and m.user_id = auth.uid();
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if sharing then
    perform realtime.send(
      jsonb_build_object('user_id', auth.uid(), 'read_at', now()),
      'read',
      'reads:' || conversation::text,
      true);
  end if;
end $$;

create or replace function public.read_marks(conversation uuid)
returns table (user_id uuid, shares boolean, read_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select cm.user_id,
         both_share,
         case when both_share then cm.shared_read_at end
    from public.conversation_members cm
    left join public.profiles p on p.user_id = cm.user_id
   cross join lateral (
     -- Someone taken off the allowlist shows nothing, as for last seen.
     select coalesce(p.share_read_status, false)
            and app_private.is_allowed(cm.user_id)
            and app_private.shares_read_status() as both_share
   ) s
   where cm.conversation_id = conversation
     and cm.user_id <> auth.uid()
     and app_private.has_app_access()
     and app_private.is_member(conversation)
$$;
