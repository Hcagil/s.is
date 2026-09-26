-- Perf: conversation_previews and messages_read stopped scaling with the
-- caller's own conversations and started scaling with the whole message
-- history (qa-lead, 2026-09-26): the unread/group_chat integration suites
-- got measurably slower as the local database grew across runs.
--
-- Measured at 3 members, 5 conversations, 50k messages (EXPLAIN ANALYZE,
-- BUFFERS, as `authenticated` with a member's JWT claims so RLS applies):
--
--   conversation_previews  Seq Scan on messages, 650k buffer hits, 6.9s.
--     DISTINCT ON (m.conversation_id) ... ORDER BY m.conversation_id,
--     m.created_at DESC has no equality condition to seek on, so it is a
--     full scan of every message ever sent, re-evaluating is_member() and
--     has_app_access() per row, however few conversations the caller is
--     actually in.
--
--   messages_read (the conversation screen's own history read: one
--     conversation, newest 500) 6546 buffer hits, ~60ms. Already index-scans
--     messages_conversation_idx; the remaining cost is has_app_access()
--     evaluated once per candidate row even though it takes no row-dependent
--     argument and returns the same answer for the whole query.
--
--   unread_counts(), mark_read(), read_marks(), push_targets_for_message()
--     were already fast (12ms, n/a -- single UPDATE by PK, <1ms, 11ms): each
--     is keyed by an index (conversation_id+created_at, a membership PK, or a
--     message id) and none scales with total history. Left unchanged.

-- conversation_previews: rewritten as one indexed lookup per conversation the
-- caller belongs to (LATERAL "top 1 by created_at desc", using
-- messages_conversation_idx), instead of a DISTINCT ON scan of every message.
-- Same columns, same filters (deleted <> 'vanished'), same result: exactly
-- one row per conversation the caller is a member of, or none if it has no
-- messages. conversation_members is never more than the sum of everyone's
-- memberships, so this scan no longer grows with message history at all.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted
  from public.conversation_members cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m
 where cm.user_id = auth.uid();

revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;

-- messages_read: has_app_access() takes no row-dependent argument, so wrap it
-- in `(select ...)` -- the Supabase-documented RLS pattern that lets the
-- planner hoist it into a one-time InitPlan instead of re-running its several
-- joins (auth.users, auth.sessions, active_sessions, allowlist) for every
-- candidate row. is_member(conversation_id) stays unwrapped: it depends on
-- the row's own conversation_id, so it cannot be hoisted the same way and
-- must still run per row -- it already does so cheaply, as a single indexed
-- lookup against conversation_members. Measured: the 500-row history read
-- above drops from ~60ms/6546 buffers to ~10ms/558 buffers. Identical
-- predicate, so identical rows are visible -- purely a planner hint.
drop policy messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
  using ((select app_private.has_app_access()) and app_private.is_member(conversation_id));
