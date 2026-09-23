-- Unread counts (v0.6).
--
-- A member's place in a conversation is one timestamp: everything newer than
-- last_read_at that someone else sent is unread. Opening a conversation moves
-- it to now(). There are no read receipts (owner, 2026-09-23), so another
-- member's last_read_at must stay unreadable: it would be a receipt by the
-- back door.

-- Existing memberships start fully read: now() is fixed for the migration's
-- transaction, so history does not arrive as hundreds of unread messages.
alter table public.conversation_members
  add column last_read_at timestamptz not null default now();

-- Column-level read access, so the new column stays private. The table grant
-- covered every column; members still see who is in a conversation.
revoke select on public.conversation_members from authenticated;
grant select (conversation_id, user_id, joined_at)
  on public.conversation_members to authenticated;

-- The only write to last_read_at, and only to the caller's own membership.
-- ponytail: now() is the transaction's start time, so a message whose insert
-- began before and committed after a mark_read counts as read. The app marks
-- read on open, on every incoming message and on leaving, which shrinks that
-- window to milliseconds; if it ever matters, take the newest created_at the
-- client displayed and store greatest(last_read_at, that).
-- security definer because conversation_members has no client update policy,
-- and must not get one: a policy would expose the other columns to updates.
create or replace function public.mark_read(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.conversation_members m
     set last_read_at = now()
   where m.conversation_id = conversation
     and m.user_id = auth.uid();
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
end $$;
revoke all on function public.mark_read(uuid) from public, anon;
grant execute on function public.mark_read(uuid) to authenticated;

-- The caller's unread count per conversation; conversations with nothing
-- unread are omitted. security definer to read last_read_at, which the caller
-- cannot select; it therefore scopes itself: only the caller's own
-- memberships, and nothing at all without app access.
create or replace function public.unread_counts()
returns table (conversation_id uuid, unread integer)
language sql stable security definer set search_path = '' as $$
  select cm.conversation_id, count(*)::integer
    from public.conversation_members cm
    join public.messages m
      on m.conversation_id = cm.conversation_id
     and m.created_at > cm.last_read_at
     and m.sender_id <> cm.user_id
   where cm.user_id = auth.uid()
     and app_private.has_app_access()
   group by cm.conversation_id
$$;
revoke all on function public.unread_counts() from public, anon;
grant execute on function public.unread_counts() to authenticated;
