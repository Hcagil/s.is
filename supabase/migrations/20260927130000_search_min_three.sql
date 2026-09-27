-- v0.16 follow-up: raise search_messages' minimum query length from two
-- characters to three. Owner-approved 2026-09-27, on a security-lead dynamic
-- probe (Low): pg_trgm cannot derive an index condition from a LIKE pattern
-- shorter than three characters (a trigram needs three characters to exist
-- at all), so a 2-character query fell through to a full, unselective scan
-- of messages_search_trgm_idx -- every row in the table, in every
-- conversation, not just the caller's own -- rather than the targeted
-- bitmap scan a 3+ character query gets. Two costs, both independent of
-- `conversation` (scoped or unscoped, both pay it): a DoS surface (~0.23us
-- per row measured by security-lead, so ~22.7ms at 100,000 foreign rows and
-- ~230ms at 1,000,000, from a search term as short as two characters and as
-- cheap to send as any other), and a timing side channel leaking the
-- database's total message volume regardless of the caller's own
-- membership.
--
-- The existing length guard, `char_length(btrim(query)) >= 2`, already sits
-- in the WHERE clause as a bare (unwrapped) condition -- unlike
-- has_app_access() and is_member(conversation) just above it, it is not
-- wrapped in a scalar subquery. That turns out not to matter for THIS qual:
-- it references no column of `messages` and calls only immutable functions
-- on the function's own parameter, so Postgres's planner treats it as a
-- pseudoconstant (a clause with no Vars) and hoists it into a one-time
-- gating check ahead of the scan on its own, the same way a bare `false` in
-- a WHERE clause short-circuits a query -- confirmed below by EXPLAIN
-- (ANALYZE, BUFFERS) showing zero buffer hits on `messages` once the guard
-- rejects the query. The problem was never that the guard failed to gate;
-- it is that two characters PASSED it, and a passing 2-character query still
-- reached the trigram index with a pattern too short for it to help.
-- Raising the threshold to three removes that gap: nothing shorter than
-- three characters reaches the scan at all, and everything that does is
-- long enough for pg_trgm to produce a real Index Cond.
--
-- Measured myself against this branch's own local stack (`explain (analyze,
-- buffers)` via `select * from search_messages(...)`, authenticated as a
-- member with zero of their own messages), a fixture conversation the
-- caller is NOT a member of, filled with 0 / 20,000 / 100,000 messages all
-- containing the probe term "probe" (single runs; timings settle further
-- once buffers are warm, the buffer counts -- the point being made -- do
-- not):
--
--                              0 foreign    20,000 foreign   100,000 foreign
--   2-char "pr", threshold 2   5.85ms/535b     5.36ms/830b     23.57ms/2646b
--     (no usable Index Cond for a 2-char pattern: a full scan of
--      messages_search_trgm_idx, buffers and time both climbing with total
--      row count -- this is the DoS/timing leak security-lead measured;
--      23.57ms at 100,000 matches security-lead's own ~22.7ms independently)
--   2-char "pr", threshold 3   3.89ms/356b     0.66ms/124b      0.65ms/114b
--     (char_length(btrim($1)) >= 3 -> false: a pseudoconstant qual with no
--      Vars, hoisted into a one-time gating check ahead of the scan, same as
--      a rejected `conversation` id already was -- buffers and time do NOT
--      grow with foreign row count; the one elevated first run is
--      parse/catalog-cache warmup, not scan work, and disappears on repeat)
--   3-char "pro", threshold 3  3.30ms/24b      3.19ms/409b      14.85ms/1961b
--     (unaffected by this change either way: the previous migration's own
--      documented residual cost -- the trigram index IS used, matching
--      foreign rows are still heap-fetched before the leakproof array bound
--      discards them, restated here only to show 3-char is untouched)
--
-- 2-char (and, by the same gate, 1-char and empty) is now ~independent of
-- table size, matching a rejected `conversation` id's cost; 3-char is
-- unchanged. Nothing else about
-- search_messages changes: security definer, search_path, the one-time
-- is_member(conversation) check, the any(array(memberships)) leakproof
-- bound, the per-row is_member(m.conversation_id) check, and the InitPlan
-- pattern for the LIKE value are all identical to the previous migration.
create or replace function public.search_messages(query text, conversation uuid default null)
returns table (
  id uuid, conversation_id uuid, sender_id uuid, body text, created_at timestamptz,
  attachment_path text, attachment_preview text, deleted text, reply_to uuid,
  forwarded boolean, edited_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select m.id, m.conversation_id, m.sender_id, m.body, m.created_at,
         m.attachment_path, m.attachment_preview, m.deleted, m.reply_to,
         m.forwarded, m.edited_at
    from public.messages m
   where (select app_private.has_app_access())
     -- A given `conversation` the caller is not a member of is rejected here,
     -- once, before the trigram scan below ever runs (a scalar subquery on
     -- the parameter alone, hoisted the same way has_app_access() is): a
     -- foreign conversation id costs the same ~nothing regardless of how
     -- many messages match `query` anywhere. See the previous migration for
     -- why this is not enough by itself when `conversation` is null.
     and (conversation is null or (select app_private.is_member(conversation)))
     -- Bounds every candidate row to the caller's own conversations with a
     -- leakproof equality (an array built once from conversation_members),
     -- BEFORE app_private.is_member()'s own (real, still-kept) check -- see
     -- the previous migration.
     and m.conversation_id = any (
           array(select cm.conversation_id from public.conversation_members cm
                  where cm.user_id = auth.uid())
         )
     and app_private.is_member(m.conversation_id)
     -- Raised from 2 to 3 (this migration's header): below 3 characters
     -- pg_trgm cannot derive an Index Cond from the LIKE pattern below, so a
     -- passing-but-short query forced a full, unselective scan of the
     -- shared trigram index across every conversation's messages, not just
     -- the caller's own -- a DoS surface and a timing leak of total message
     -- volume. This clause references no column of `messages`, so the
     -- planner hoists it into a one-time gating check ahead of the scan,
     -- same as a rejected `conversation` above.
     and char_length(btrim(query)) >= 3
     and m.deleted is null
     and (conversation is null or m.conversation_id = conversation)
     -- The pattern is a scalar subquery so it is built ONCE, as an InitPlan,
     -- not once per candidate row: fold_search()/escape_like() carry a SET
     -- search_path, which stops them being inlined, and `query` is a
     -- parameter, not a constant, so nothing else folds this expression at
     -- plan time -- see the previous migration.
     and m.search_text like (select '%' || public.escape_like(public.fold_search(btrim(query))) || '%') escape '\'
   order by m.created_at desc
   limit 50
$$;
revoke all on function public.search_messages(text, uuid) from public, anon;
grant execute on function public.search_messages(text, uuid) to authenticated;
