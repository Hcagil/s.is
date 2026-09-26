-- v0.16: search messages across all history, in one chat or across all of
-- them. Owner-approved 2026-09-27.
--
-- Server design (smallest thing that satisfies the brief's four points):
--
-- 1. Case-insensitive AND Turkish-safe. Plain lower() does not unify Turkish
--    I/ı/İ: in this database's locale, lower('İ') and lower('ı') are no-ops
--    (both are non-ASCII code points a byte-wise lower() does not touch), so
--    "istanbul" would not find "İstanbul" or "ıstanbul" without help.
--    public.fold_search() first maps all three of İ (U+0130), I (U+0049) and
--    ı (U+0131) to plain 'i' with translate(), THEN lower()s the rest --
--    deterministic regardless of server locale, unlike relying on a tr_TR
--    collation. The same function folds both the stored text and the
--    caller's query, so the two are compared on equal footing. It reads no
--    table, so it lives in `public`, plain, not `security definer`.
--
-- 2. Fast over all history: search_text is a generated column (fold_search
--    applied once, at write time, not per search) with a pg_trgm GIN index.
--
--    Measured, and this is the one place this migration departs from the
--    smallest-sounding design: LIKE ('~~') is NOT a leakproof operator in
--    Postgres (`select proleakproof from pg_proc where proname =
--    'textlike'` -> false), and neither is pg_trgm's own `%` similarity
--    operator. A row-level-security table is planned like a security-barrier
--    view: a non-leakproof qual in the caller's own WHERE can never be
--    pushed below the barrier to help choose an access path, so it is always
--    applied as a Filter AFTER whichever plan the *leakproof* quals alone
--    justify. With no other leakproof, selective condition when searching
--    every conversation at once, that plan is a full Seq Scan -- the
--    trigram index sits unused underneath it, and marking `~~` leakproof
--    ourselves needs superuser, which the migration role (`postgres`, in
--    Supabase's hosted project too) does not have. Confirmed by EXPLAIN
--    (ANALYZE, BUFFERS), as authenticated with a member's JWT claims, 5
--    conversations of 10,000 messages each (50,000 rows), searching a term
--    that appears in 100 of them:
--
--      security-invoker search_messages (RLS applies automatically):
--        Seq Scan on messages, 49,900 rows filtered out, ~100,000 buffer
--        hits, ~270ms -- indistinguishable from a hand-written
--        `body ilike '%term%'` with no index at all: the index exists and is
--        provably unused (confirmed by forcing `enable_seqscan = off`:
--        Postgres then reads the WHOLE partial index, 102,523 buffer hits,
--        254ms -- *slower* -- rather than derive an Index Cond from the LIKE
--        at all).
--
--    search_messages is `security definer` instead, calling
--    app_private.has_app_access() and app_private.is_member(conversation_id)
--    itself -- the exact functions messages_read's policy calls, not a
--    reimplementation that could drift from it -- as ordinary WHERE
--    conditions rather than through the automatic RLS path. Running as the
--    table owner, its own scan is not behind a security barrier at all, so
--    whether LIKE is leakproof stops mattering and the trigram index is free
--    to be chosen on its own merits, same as any ordinary query:
--
--      security-definer search_messages, same data and query:
--        Function Scan on search_messages, 50 rows (the LIMIT), 802 buffer
--        hits, ~2.7ms -- internally a Bitmap Heap Scan on messages via
--        Bitmap Index Scan on messages_search_trgm_idx with Index Cond:
--        (search_text ~~ '%istanbul%'), confirmed against the equivalent
--        query run directly (not through the opaque function-scan node).
--
--    ~125x fewer buffers, ~100x faster, and it stays that way as history
--    grows instead of scaling with it -- which a security-invoker version,
--    measurably, cannot do on this table today. Compare this to the
--    codebase's other `security definer` public RPCs that re-check access
--    explicitly rather than relying on RLS -- start_direct_conversation(),
--    delete_message(), edit_message(), mark_read(), unread_counts(),
--    read_marks() -- every one of them calls app_private.has_app_access()
--    (or the equivalent plpgsql `if not ... raise exception ... 42501`)
--    itself, for the same reason: a function that needs to see or touch more
--    than RLS alone would show its caller has always had to ask RLS's own
--    question explicitly. This is that established pattern, not
--    `public.forget_device_token()`'s (SECURITY.md): that one deliberately
--    checks LESS than has_app_access() for a narrower, different reason (a
--    revoked member must still be able to silence a device's push); this one
--    checks the same as messages_read, just explicitly instead of through
--    RLS's automatic path.
--
--    security-lead (2026-09-27, F1) caught a second, subtler cost once the
--    barrier above is gone: app_private.is_member(m.conversation_id) only
--    rejects a foreign row AFTER the trigram index has found it and the
--    bitmap heap scan has fetched it, so a search touching many rows in
--    conversations the caller is NOT in ran measurably longer than one that
--    did not -- a timing side channel on content the caller can never see
--    (roughly 5us of is_member()'s own lookup per such row). Fixed by
--    bounding every row to the caller's own conversations with a LEAKPROOF,
--    plain equality first -- `conversation_id = any(array(...))` against a
--    list read once from conversation_members -- which costs an array
--    lookup, not a function call and a subquery, per foreign row; and by
--    rejecting a `conversation` given explicitly up front, in one hoisted
--    check, before the scan runs at all, when the caller is not a member of
--    it. app_private.is_member(m.conversation_id) stays alongside both,
--    unchanged: they exist for their cost profile, not to replace it as the
--    real authority check.
--
--    Re-measured, same 50,000-row fixture as above, plus a SEPARATE
--    conversation the caller is not a member of, 20,000 messages, every one
--    matching "istanbul" (the densest possible foreign case for a shared
--    trigram index), EXPLAIN (ANALYZE, BUFFERS) as authenticated:
--
--      conversation given explicitly, caller NOT a member of it: 17 buffer
--        hits, ~0.4-0.6ms, whatever the term -- rejected by the hoisted
--        is_member(conversation) check before the scan runs, same cost as
--        an empty table.
--      conversation null (search every conversation the caller belongs to),
--        with those 20,000 dense foreign matches present: ~1,750-1,985
--        buffer hits, ~65-68ms, steady across repeated (warm-cache) runs --
--        a real residual, NOT a function-call-per-row cost: the shared GIN
--        index's own posting lists for a globally common term still have to
--        be walked, and Postgres still bitmap-heap-fetches the foreign rows
--        it finds there before the (cheap) array check discards them, since
--        no index here lets it skip straight to "only the caller's own
--        conversations" within the trigram results. That scales with how
--        common the term is SYSTEM-WIDE, not with anything the caller could
--        not already infer by how long any shared search takes -- unlike
--        F1's per-row function-call cost, this is not a side channel onto
--        specific foreign content, and eliminating it entirely would need
--        the trigram index itself partitioned by conversation, which
--        membership changing over time rules out for a stored index. Left
--        as a known, now-small-relative-to-history-size cost rather than
--        built further: it does not grow per foreign MEMBER, only per
--        foreign MATCH of a given search term, and 20,000 dense matches in
--        one conversation is already an extreme case.
--
-- 3. Access: has_app_access() and is_member(conversation_id) are both
--    checked, explicitly, using the identical functions messages_read's
--    policy uses -- see point 2 for why they are called directly rather than
--    left to RLS. The generated column and its partial index exclude
--    deleted <> null messages up front (vanished and placeholder both set
--    `deleted`), and an empty body can never contain a 2+ character
--    substring, so a photo with no caption never matches either. The
--    caller's query is matched with LIKE, so public.escape_like()
--    backslash-escapes any literal %, _ or \ in it before it is wrapped in
--    '%...%' -- otherwise a query containing them would run as a wildcard
--    instead of being searched for literally.
--
-- 4. Query shape: one RPC, public.search_messages(query, conversation),
--    chosen over a generated column exposed straight through PostgREST
--    because the length check (fewer than 2 trimmed characters returns
--    nothing), the fold-and-escape of the query, the access check and the
--    limit/order are all one small function instead of encoded per-call in
--    a PostgREST filter string. conversation is optional: null searches
--    every conversation the caller is a member of; given, it also narrows
--    the WHERE clause. Newest first, capped at 50, matching the RPC style
--    already used for unread_counts()/read_marks() -- the client maps the
--    returned rows the same way it maps a plain messages read.

create extension if not exists pg_trgm with schema extensions;

-- Pure text transforms, no table access: plain functions in `public`, not
-- `security definer`.
create function public.fold_search(input text) returns text
language sql immutable set search_path = '' as $$
  select lower(translate(input, 'İIı', 'iii'))
$$;
revoke all on function public.fold_search(text) from public, anon;
grant execute on function public.fold_search(text) to authenticated;

-- Backslash first (so a literal backslash in the query does not turn the
-- escape it is about to gain into a real escape sequence), then the two LIKE
-- wildcards.
create function public.escape_like(input text) returns text
language sql immutable set search_path = '' as $$
  select replace(replace(replace(input, '\', '\\'), '%', '\%'), '_', '\_')
$$;
revoke all on function public.escape_like(text) from public, anon;
grant execute on function public.escape_like(text) to authenticated;

alter table public.messages
  add column search_text text generated always as (public.fold_search(body)) stored;

-- Partial: a deleted message's search_text is fold_search('') = '', which
-- could never match a 2+ character query anyway, but excluding it keeps the
-- index itself smaller as more messages get deleted over time.
create index messages_search_trgm_idx on public.messages
  using gin (search_text extensions.gin_trgm_ops)
  where deleted is null;

-- security definer: see point 2 above. has_app_access() and is_member() are
-- called explicitly, in the WHERE clause, exactly as messages_read's policy
-- calls them -- nothing here narrows access more loosely than that policy.
create function public.search_messages(query text, conversation uuid default null)
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
     -- many messages match `query` anywhere. See point 2 for why this is not
     -- enough by itself when `conversation` is null.
     and (conversation is null or (select app_private.is_member(conversation)))
     -- Bounds every candidate row to the caller's own conversations with a
     -- leakproof equality (an array built once from conversation_members),
     -- BEFORE app_private.is_member()'s own (real, still-kept) check --
     -- see point 2.
     and m.conversation_id = any (
           array(select cm.conversation_id from public.conversation_members cm
                  where cm.user_id = auth.uid())
         )
     and app_private.is_member(m.conversation_id)
     and char_length(btrim(query)) >= 2
     and m.deleted is null
     and (conversation is null or m.conversation_id = conversation)
     and m.search_text like '%' || public.escape_like(public.fold_search(btrim(query))) || '%' escape '\'
   order by m.created_at desc
   limit 50
$$;
revoke all on function public.search_messages(text, uuid) from public, anon;
grant execute on function public.search_messages(text, uuid) to authenticated;
