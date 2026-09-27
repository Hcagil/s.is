-- v0.16 follow-up: search_messages runs only for a query with at least three
-- letters or digits. Owner rule "search starts at 3 characters", refined
-- 2026-09-27 after two security-lead dynamic probes (F-DYN-1, F-DYN-1b):
-- the length that matters to pg_trgm is not characters but WORD characters.
--
-- Why: pg_trgm builds the Index Cond for `search_text like '%q%'` by
-- splitting the pattern into runs of word characters (letters and digits,
-- get_wildcard_part in trgm_op.c), padding each run with two spaces on the
-- left unless it directly follows a wildcard and one space on the right
-- unless it directly precedes one, and taking trigrams of the padded runs.
-- If that yields no trigram at all, gin_extract_query falls back to
-- GIN_SEARCH_MODE_ALL: it walks the whole of messages_search_trgm_idx and
-- rechecks EVERY message in the table against the LIKE -- every
-- conversation's rows, not just the caller's -- before the leakproof
-- membership bound discards them. So a symbol-only query (`%%%`, `...`,
-- `!!!`, three emoji) has no run at all, and `a..` has one run, `a`,
-- preceded by the leading `%` (no left pad) and followed by `.` (one right
-- pad): "a " -- two characters, no trigram, full scan. Both pass a
-- `char_length(btrim(query)) >= 3` guard. The previous version of this
-- migration raised the character count from 2 to 3 and closed only the
-- 1-2 character case; F-DYN-1b showed the same full scan from 3+ symbols,
-- whether `conversation` is given or not. The costs are the ones F-DYN-1
-- named: a DoS surface growing with total message volume, and a timing side
-- channel leaking that volume to any member.
--
-- The guard now counts letters and digits: strip everything that is not
-- [[:alnum:]] and require three left. Three word characters always give at
-- least one trigram: either they sit in one run of length three, or there
-- is a second run, and a second run is never preceded by a wildcard, so it
-- gets the two-space left pad ("  b" is a trigram). Verified in this
-- database's locale (ICU en-US for regexes, libc en_US.UTF-8 for pg_trgm --
-- they are different classifiers): a sweep of every code point below
-- U+30000 found NO character that [[:alnum:]] accepts and pg_trgm does not
-- treat as a word character (the only unsafe direction; 1,661 combining
-- marks go the harmless other way). Turkish İ ı ş ğ ç ö ü are word
-- characters for both. On a libc-collated database both sides are the same
-- iswalnum(), so the subset property holds there trivially. btrim and
-- fold_search are not needed in the guard: whitespace is not alnum and
-- folding does not change whether a character is a letter.
--
-- The guard stays a bare qual referencing no column of `messages`, so the
-- planner keeps hoisting it into the One-Time Filter ahead of the scan (the
-- EXPLAIN below shows the Bitmap Index Scan as "never executed" when it
-- rejects). regexp_replace is immutable, so nothing else changes about how
-- the query is planned.
--
-- Measured 2026-09-27, `explain (analyze, buffers)` of the function body as
-- the definer with a member's JWT claims, generic plan (as the SQL function
-- itself plans), a foreign conversation the caller is not a member of
-- filled with 0 / 20,000 / 100,000 messages; shared blocks, and ms:
--
--                                   0 foreign     20,000 foreign  100,000 foreign
--   `%%%` `...` `!!!` emoji `a..`
--     char_length(btrim) >= 3       730b/0.9ms    1204b/5.4ms     3037b/24ms
--       (Bitmap Index Scan actual rows=102,647, "Rows Removed by Index
--        Recheck: 102,625": the whole index and heap, climbing with volume;
--        own-conversation scope identical: 731 / 1205 / 3038b)
--     alnum count >= 3              9b/0.3ms      9b/0.3ms        9b/0.3ms
--       (One-Time Filter false, scan never executed; own scope 10b)
--   `abc`                           34b/0.5ms     34b/0.5ms       34b/0.5ms  (both guards)
--   `a b c` `a.b.c` `1 2 3`         18-20b/0.3ms  same            same       (both guards)
--   `şğü` `İıi`                     12b/0.3ms     same            same       (both guards)
--   `pro` `probe`                   37-45b        424-438b        1975-2017b (both guards)
--       (the previous migration's documented residual: matching foreign
--        rows are heap-fetched before the leakproof bound discards them;
--        unchanged here)
--   `pr` `..a` `a b`                9b/0.3ms      same            same
--       (rejected: under three letters or digits)
--
-- End to end through search_messages() as `authenticated` at 100,000
-- foreign rows: `%%%` / `a..` / emoji 3038-3073b, 24ms before; 10-27b,
-- 0.4-0.5ms after. `abc` 35b before and after.
--
-- Nothing else about search_messages changes: security definer,
-- search_path, the one-time is_member(conversation) check, the
-- any(array(memberships)) leakproof bound, the per-row
-- is_member(m.conversation_id) check and the InitPlan for the LIKE value
-- are all identical to the previous migration. The app applies the same
-- rule client-side (isSearchable in the chat domain) so a symbol-only query
-- never makes the round trip; this guard is the one that is enforced.
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
     -- At least three letters or digits (this migration's header): fewer,
     -- or symbols only, can leave pg_trgm with no trigram to look up, and
     -- the LIKE below then degrades to a full scan of the shared trigram
     -- index across every conversation's messages -- a DoS surface and a
     -- timing leak of total message volume. This clause references no
     -- column of `messages`, so the planner hoists it into a one-time
     -- gating check ahead of the scan, same as a rejected `conversation`.
     and char_length(regexp_replace(query, '[^[:alnum:]]', '', 'g')) >= 3
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
