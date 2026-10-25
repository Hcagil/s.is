# Security model

Source of truth: [DESIGN.md §4](DESIGN.md).

Postgres Row Level Security is the only authority. The client is untrusted.

### Schemas

- `app_private` — not exposed through the API and revoked from `anon` and
  `authenticated`; RLS enabled as well.
  - `allowlist(email text primary key, added_at)` — stored normalised, with a
    `check (email = lower(btrim(email)))`; compared against the normalised,
    confirmed `auth.users` email
  - `active_sessions(user_id primary key, session_id uuid, session_created_at)`
    — note this cascades from `auth.users`, **not** from `auth.sessions`, so a
    row here can outlive the session it names. Anything deciding access must
    re-check `auth.sessions` as `has_app_access()` does; a push path that
    trusted this table alone would have notified a revoked device.
  - `device_tokens(user_id, token, platform, shows_itself, session_id, updated_at)`
    — push delivery addresses. One row per member: registering replaces, so a
    replaced phone stops being notified when it stops being able to read.
    `session_id` is the JWT session that registered the token, recorded by
    `register_device_token` (the client sends none). The server gate: a token
    is a push target only while `session_id` is still the member's row in
    `active_sessions` **and** still exists in `auth.sessions`, on every
    platform; a null (unbound) token is never a target. Sign-in on another
    device, sign-out and revocation each break that match on their own.
  - `push_receipts(user_id, message_id, stage, error, build, ...)` — what
    became of each push on a phone. RLS on, no policy, no grant. Written only
    by `public.report_push_receipts(jsonb)` (security definer, app access
    required, `authenticated` only): rows are always `auth.uid()`'s, invalid
    stages are skipped, errors cut to 300 characters, 100 per call, newest 500
    kept per member. Never holds message text.
- `public` — RLS enabled on every table; policies use the helpers below.
  - `profiles(user_id pk → auth.users, display_name, created_at)` — created by
    a trigger on `auth.users` insert.
    Stored preference `profiles.app_language` (`en` or `tr`, null = unknown, treated as Turkish): the language the app shows, written by the member's own app (column update grant, `profiles_update_own` pins the row; the bot cannot). It is not in the column-level select grant, so no client reads it; only `app_private.messages_bot_intro()` (security definer) reads it, to pick the language of SIS Destek's automatic first line.
  - `app_config(id = 1, min_supported_build int)` — single row, readable by an
    **active allowlisted member** (`has_app_access()`), never writable from the
    client. The latest available build is not stored: Google Play reports it to
    the app.
  - `conversations`, `conversation_members`, `messages` — every policy is
    `has_app_access()` **and** membership. A conversation is a group when it
    has a `title`; a 1:1 has a unique `direct_key`.
  - **Membership windows (v0.23).** `conversation_members` keeps history:
    `role` (`admin`|`member`), `left_at`/`left_reason` (null = current),
    `history_from`. Leaving or removal keeps the row; a returning member gets
    a new row, so one person can have several windows. `is_member` = a
    current row (every action: send, edit, delete, reply, group picture,
    typing, read marks, admin actions); `was_member` = any row (the
    conversation row itself). Messages are readable only inside a window —
    `app_private.message_readable(m)`: `history_from ≤ created_at` and, for a
    past row, `created_at ≤ left_at`. `messages_read`, `search_messages`,
    attachment reads (plus the uploader's own object at any time if she was
    ever a member — before her message exists and after `delete_message`)
    and the reply check all use it. `unread_counts`, push and the `typing:`/`reads:`
    topics use current membership only; `mark_read` never marks past
    `left_at`. Seeing another member's row and name requires the caller's
    readable window (`history_from` to `left_at`) to overlap that row's
    presence (`joined_at` to `left_at`), so a departed member never learns
    who joined later and a member added without history never sees who left
    before; a member added with history sees everyone who has ever been in
    the group. `add_members(with_history=false)` sets `history_from = now()`.
  - **Admins.** `leave_group`, `remove_member`, `add_members`, `set_admin`
    are security-definer RPCs: allowlist + active session, groups only (a 1:1
    is refused), admin actions need a current admin, invitees must be
    allowlisted and reachable (all or nothing). Each takes a per-group
    advisory lock first; a deferred constraint trigger on role and
    membership changes refuses any transaction that leaves a group with
    members but no admin; and when an account is deleted, or anyone leaves
    while no other admin would remain, the longest-standing current member
    is promoted. The group's
    creator is its admin; the last admin leaving promotes the
    longest-standing current member; the sole admin cannot be demoted; an
    admin cannot remove themselves.
  - **`group_events`** (left/removed/added): RLS, SELECT only for current
    admins and only from their own `history_from`, written only by those
    RPCs, not in the Realtime publication, never read by previews, unread
    counts, search or push.
  - Accepted leftovers (v0.23): a private Realtime channel joined before
    leaving keeps receiving typing and read broadcasts until it is rejoined
    (authorisation is checked at join; the same holds for a revoked session;
    the app leaves those channels as soon as it sees it has left); a message
    edited within its 6-hour window after someone left shows the edit to
    them; a departed member still sees later leaves, removals and role
    changes of members whose time in the group overlapped hers.
  - `messages` inserts: `authenticated` may insert exactly `id,
    conversation_id, sender_id, body, attachment_path, attachment_preview,
    attachment_name, attachment_mime, attachment_size, attachment_duration_ms,
    attachment_waveform, voice_transcript, reply_to, forwarded, link_preview,
    photo_group`; `created_at`, `deleted`, `deleted_at` and
    `edited_at` stay server-assigned, and there is no UPDATE or DELETE
    privilege (edits and deletes go through `edit_message` /
    `delete_message`). The `id` is proposed by the phone (a random v4 UUID),
    so a send queued offline can be retried safely: the primary key refuses
    an id that already exists. Any UUID is accepted, so **nothing may trust a
    message id to be server-generated or unpredictable** — never key an
    authorisation decision, storage path or topic on it. The app treats a
    duplicate-key answer as "already sent" only when the stored row is the
    caller's own, in the same conversation, with the same body (a locked text:
    the same ciphertext, which the queue keeps so a retry sends the same bytes
    and an encrypted text is never locked twice) (and, when the retried message
    is a reply, the same reply target); otherwise the send fails. Accepted leftover risk: a member who already
    knows a message id learns whether that message exists.
  - `messages.photo_group` (a uuid, null for every message but the photos of
    an album) is only a grouping label: each photo is its own message with
    its own access rule, so knowing or guessing a group id reveals nothing.
    It is insert-only like the other columns (no UPDATE privilege), and the
    `messages_photo_group_check` constraint allows it only on a stored photo
    (an image, not a file or video; a message deleted for everyone may keep
    the value). The app folds photos into one bubble only when they share the
    group AND the sender, so a member cannot pull another member's photos
    into their own album. Nothing filters on it, so it has no index.
  - Drafts live in the app's memory only. Queued unsent messages (text, files,
    videos, places, stickers) are stored in the encrypted on-phone store (table
    `send_queue`, see "On-phone message store"), never in shared_preferences,
    so an unsent text is not readable from a copy of the app's files; a locked
    text waits there as its ciphertext, plus the plain text it was typed as
    (needed to show it and to retry a refusal). The old preferences key is
    moved into the store at the first start and removed. The queue is erased
    with the store at sign-out; files the queue copied into the app's own
    folders are deleted then too. They are personal data under the on-phone
    storage posture.
  - `messages.attachment_path` points into the private `attachments` storage
    bucket, keyed `<conversation_id>/<file>`. The storage policies ask the same
    membership question the table policies ask, so there is one access rule and
    not two that can drift.
  - `messages.link_preview` (a link card) is validated by the
    `messages_link_preview_guard` trigger (security invoker, errcode LNKP1):
    fixed keys, text without control, invisible or markup characters, an
    http(s) url that appears in the body, plain text messages only; an edit
    or a delete for everyone drops the card. Its picture sits in the private
    `link-previews` bucket as `<conversation_id>/<message_id>.jpg`, and the
    card may name only that path, only if the sender uploaded it (unique per
    message). The read policy copies `attachments`: the uploader before the
    message exists, then only through a readable message whose card names the
    picture. The sender's phone reads the page: redirects are followed by hand
    (at most 5, never https to http), and the page, every hop and the picture
    must resolve to public addresses only (loopback, private, link-local,
    CGNAT, ULA, multicast, documentation and special ranges, and the IPv4
    inside NAT64 and 6to4 addresses, are refused). A failed, empty or slow
    (3 s) lookup refuses. The connection goes to the exact address that was
    checked (a custom connection factory), and for https the certificate is
    checked against the original host name, so a DNS answer that changes
    afterwards cannot redirect it. The whole fetch is capped at 9 s, the
    page at 300000 bytes, the picture at 3000000 bytes and 16 megapixels
    (checked before decoding). Readers see the site only if they tap the card.
    The card's url must appear in the body as a whole link (after the start,
    whitespace, a bracket or a quote; before whitespace, the end or closing
    punctuation), not inside a longer word or address. Addresses of the form
    `::a.b.c.d` are refused like `::` and `::1`; an international host name is
    looked up and checked in its ASCII (punycode) form; each resolved address
    is tried in turn (3 s each) and the TLS handshake has its own 5 s limit.
    The video player loads only the official embed of YouTube, Instagram,
    TikTok or X in a sandboxed web view, and only after the tap (see
    `docs/DECISIONS.md`, 2026-10-11).
  - `profiles` rows are readable only for an allowlisted account that is the
    caller, shares a conversation with the caller, or is a contact the
    caller saved; a tag find alone does not open the row (`find_by_tag`
    returns its own single row). **Reach** (`app_private.can_reach`) is those
    three plus someone the caller found by exact tag (`app_private.tag_finds`,
    written by `find_by_tag` and `find_by_contacts`, cleared when the found member changes their
    tag); it gates contacts insert, `start_*`, `last_seen_of` and the
    `everyone` picture. Clients may select
    every column except `avatar_object` (the real picture path) and
    `avatar_visibility`; the owner reads those through `own_profile()`.
    `profiles.avatar_path` is a server-maintained copy for older builds: the
    real path only while the owner's picture setting is `everyone`, null
    otherwise. The app reads other people through `profiles_public()`
    (security definer, repeats the row rule, masks the path).
  - `contacts(owner_id, contact_id)`: one-way, owner-only read/insert/delete;
    inserting requires the contact be allowlisted and reachable.
  - `find_by_contacts(hashes)` is the second deliberate way to reach a stranger: the phone sends SHA-256 hex hashes of its contacts' lower-cased, trimmed emails (at most 2000 per call, each exactly 64 lower-case hex characters, else 22023); the server hashes the allowlisted emails of confirmed, not deleted, not banned, non-bot accounts per call and returns only those that match (the 4 `find_by_tag` columns plus the matched hash, never an email), and records each in `tag_finds` so Message works. Refused for the bot (42501). At most 3 calls per hour and 10 per 24 hours per member (`app_private.tag_lookups` kind `contacts`, serialised by an advisory lock, row written before any lookup work), `RLMT1` beyond. Nothing else is stored: no hashes, no contact data. Known limit: an email hash can be guessed, so a member could test email lists; bounded by the app gate, the caps above and allowlisted targets only.
  - `find_by_tag(tag)` is the one deliberate way to reach a stranger by name: exact
    match on the stored tag after folding (case, Turkish/Latin letters, a
    leading @), never prefix or wildcard; at most 20 calls per 10 minutes per
    member (`app_private.tag_lookups`, serialised by an advisory lock),
    `RLMT1` beyond. `is_tag_available` has its own budget (60 per 10 minutes).
  - Profile pictures: `app_private.avatar_visible_to(owner)` — the owner
    always; otherwise the owner must be allowlisted and either `everyone` and
    (reachable or saved by the owner), or `contacts` and the owner saved the
    reader; `nobody` is the owner only. Older builds that write
    `avatar_path` directly have the write mapped onto `avatar_object` by the
    same trigger, under the same folder pin. Enforced twice with the same function: `profiles_public()` /
    `find_by_tag` mask the path, and the `avatars` storage read policy
    refuses the object (download, sign, list).
  - `start_direct_conversation`, `start_group_conversation` (every invitee)
    and `last_seen_of` also require `can_reach`, so an account id learned
    elsewhere unlocks nothing.
  - Accepted leftovers: presence (`presence:members`) keys are account ids
    and stay visible to every member; a signed picture link created while the
    picture was visible works until it expires (the app never creates one).
  - Every new view or function exposed to clients revokes `anon` and
    defaults, and grants only what `authenticated` needs.

### Privileged surfaces

- `public.push_targets(uuid)` — granted to `service_role` only, revoked from
  every client role. It returns other members' delivery addresses and message
  bodies, so it exists solely for the notifier and must never be granted
  wider. It wraps `app_private.push_targets_for_message`, which keeps
  `app_private` unreachable from the API.
- The owner row (`app_private.owners`) is set once by the owner with the SQL Editor; never by the app, CI or a migration.

### Helpers and the access gate

All are `security definer` with `set search_path = ''`.

- `app_private.is_allowed_user()` — the caller's **confirmed** `auth.users`
  email (normalised) is on the allowlist. JWT claims are never trusted for
  authorisation.
- `app_private.has_app_access()` — allowed **and** the JWT's `session_id`
  equals the user's active session.
- `public.activate_session()` — RPC called by the app after sign-in.
  Atomically records the JWT's `session_id` as the active one **only if that
  session was created later** (per `auth.sessions.created_at`) than the stored
  one and the user is allowed. Token refreshes keep the session, so a replaced
  device can never re-claim access by refreshing. Returns `true` when
  this device now holds the active session.

Consequence: one active device per user; tokens from a replaced device can
never regain access. Every read, write, RPC and Realtime delivery of
application data requires `has_app_access()`, and Realtime never substitutes
for RLS.

One deliberate exception: `public.forget_device_token()` requires only a
signed-in caller. A member whose device was just replaced has already lost
access and must still be able to stop that device receiving notifications;
gating it on `has_app_access()` would strand notifications on a phone that can
no longer open them.

`messages_read` bounds rows by the caller's own memberships:
`conversation_id = any(array(select … from conversation_members where user_id =
(select auth.uid())))`. That subquery runs under `conversation_members_read`,
which requires `has_app_access()` and membership. So **changing
`conversation_members_read` changes which messages are readable**. An
equivalence test (`messages_read_equivalence_test.sql`) compares the rows with
the explicit rule "has app access and is a member" for every kind of caller
(2026-09-27).

Profile and group pictures live in the private `avatars` bucket (JPEG only,
1 MB max). Object keys have exactly two forms, `profile/<user id>/<file>` and
`group/<conversation id>/<file>`, and any other shape resolves to no owner and
is refused. Reading a picture requires allowlist access, an active session,
and the same right as the thing it belongs to: a profile picture follows
`profiles_read`; a group picture requires membership, and only a group (never
a 1:1) can have one. Uploading or deleting is limited to the caller's own
`profile/<own id>/` folder, or to a group the caller belongs to. Objects are
never overwritten: there is no update policy, and each change uploads a new
file and removes the old one. The stored `avatar_path` values are pinned by
`app_private.avatar_path_pinned` to exactly one file directly under the
owner's own folder. `profiles_update_own` applies the pin to the member's own
row. The security-definer RPC `set_group_avatar` applies it to a group after
checking allowlist access, the active session and membership; it locks the
row and returns the path it replaced, so the client can delete that file.
The app deletes a just-uploaded file only after a definite server refusal,
never after a network failure, because the change may have committed. The
phone's photo and picture cache is emptied whenever the session ends,
including when the phone was replaced elsewhere. Accepted: files left behind
by deleted or delisted accounts are unreadable but not yet removed (roadmap).

Message search, `public.search_messages(query, conversation)`, is a
`security definer` RPC like the other public RPCs. The alternative,
running it with the caller's rights under row-level security, can't be fast:
`LIKE` and the trigram operators aren't leakproof, so RLS forces a scan of
every message. So the function repeats `messages_read` explicitly:
`has_app_access()` and `app_private.message_readable(m)`, the same functions
the policy calls. It also bounds the rows to the caller's memberships first, and
refuses a named conversation the caller is not in before any scan. **Whenever
`messages_read` changes, this function must change with it.** A pgTAP
equivalence test (`message_search_test.sql`) fails if the two drift apart.

A search needs at least three letters or digits: the function strips
everything that is not `[[:alnum:]]` and refuses the query if fewer than
three remain, in a check that runs before any scan. With fewer, or with
symbols, punctuation or emoji only, pg_trgm can find no trigram in the
pattern and falls back to reading the whole shared index, every
conversation's messages, on every call. That rule is safe only while every
character `[[:alnum:]]` accepts is also a word character to pg_trgm. The two
use different classifiers (ICU for regular expressions, libc for pg_trgm), so
the property depends on the Postgres image. It was verified over every Unicode
code point on 17.6.1.167 with ICU 15.1, and must be re-verified when that
image changes.

Accepted residual: the search runs over one shared trigram index, so its
duration still grows by about 0.2 µs for every message, in conversations the
caller can't read, that contains all of the query's trigrams. That set
includes every real match and can be much larger: `o o o` matches nothing but
touches every message that contains the word "o". It reaches about 24 ms at
100,000 such messages, whether the caller searches everywhere or one of their
own conversations. A named conversation the caller is not in costs nothing.
The residual is a bounded frequency oracle for trigrams the caller chooses.
It reveals roughly how many unreadable messages share them, never which
conversation, sender or text. It is also a load cost that grows with total
message volume, available only to allowlisted users with an active session.
Closing it would need a trigram index per conversation, which changing
membership rules out. The fix ladder reached rung 3 on this twice
(2026-09-27).

Presence and typing use **private** Realtime channels. RLS on
`realtime.messages` opens exactly two topics — `presence:members` and
`typing:<conversation id>` — to active members (and conversation members for
typing), and the send side also requires the member's own sharing switch to be
on. Any other private topic is refused.

Realtime publishes **inserts and updates** (updates carry edits and "deleted
for everyone"), never deletes: `realtime.apply_rls` evaluates row-level
security for INSERT and UPDATE but delivers DELETE to every subscriber of the
table without consulting it. Generated columns such as `messages.search_text`
are not published.

### Sign-in flow

Google native sign-in (Credential Manager) → ID token →
`auth.signInWithIdToken` → profile trigger → `activate_session()` →
`allowed` | `denied` | `error(reason)`.

Android requirement: an Android OAuth client registered in the same Google
Cloud project as the Web client ID, for package `com.esd.sis`, with the SHA-1
of **the Play App Signing certificate** and of the upload certificate. A
missing registration surfaces as a Credential Manager cancellation after
account selection; the app shows that reason rather than returning silently.

**Sign-up gate (before user created hook).** Google and Apple (iPhone) are the only providers. The
hosted email provider is off (since 2026-10-05; Anonymous sign-ins off,
"Allow new users to sign up" on, so Google sign-up still works); the local stack keeps email on, with confirmations off, for the
integration fixtures only. Supabase Auth runs `app_private.before_user_created`
before it creates a user and refuses (HTTP 403, message `not invited`) unless
the trimmed, lower-case address is on the allowlist and is not on a reserved
test domain (`example.com`, `example.net`, `example.org`; this covers
`sis-destek-bot@example.com`, refused even with an allowlist row). The function
has a switch, `google_only`, that also refuses any non-Google sign-up; it is
off, because the email provider is off and Apple sign-in arrives
in v0.31. A refused person leaves no `auth.users`, identity, profile or
session row. It fails closed: an error in the function is an Auth error (500)
and creates nobody; nothing catches an error and allows. Break-glass: the owner
switches the hook off in Dashboard > Authentication > Hooks. The function runs
as `supabase_auth_admin`, which holds execute on it, usage on `app_private` and
SELECT on `allowlist` (one RLS policy) and nothing else; it is not a broad
security definer. Turning `google_only` on needs Apple added to it first.

The hook is data minimisation, not the gate. It does not run for existing
users, for linking a Google sign-in to an existing user, or for the admin API,
so `has_app_access()` and the allowlist table stay authoritative. The SIS Bot
(`sis-destek-bot@example.com`) is created through the admin API and holds a
refresh token only; the hook refuses its address unconditionally, even with an
allowlist row, so public sign-up and generated links can never create it. The
local `supabase/config.toml` runs the hook too, so local matches hosted:
invited integration fixtures are on the seed allowlist and the non-invited
"stranger" fixtures are created through the admin API; pgTAP also calls the
function with crafted payloads.
A non-invited Google account now gets a 403 at sign-in, which the app shows as
the Access denied screen.

iOS: the iOS OAuth client `306417977220-vqg0ne5360a921i23quf294g8e0fjshq` is
set as `GIDClientID` in `ios/Runner/Info.plist`. The Web client is still passed as
`serverClientId`, but the iOS SDK issues the ID token with the **iOS client as
audience** (found on the first TestFlight build). The Supabase Google provider's
client list therefore holds both, Web first, comma separated; it is set in the
dashboard, not in the repository. A token for any other client is still rejected.
Restore checklist: a new or restored Supabase project needs this list (Web, iOS)
set again, or iPhone sign-in fails with "unacceptable audience".

**Sign-in errors are not shown or logged in full.** SDK and backend error text
can contain a token or an ID, so the sign-in screen shows a fixed sentence and
the device log (`sis.auth`) keeps only the error code or type. The start-up failure
screen is the same: a fixed sentence, and `sis.startup` logs only the error type.
One exception remains: an offline sign-in goes through `readableFailure`, which
logs the full error under `sis.data` (network text, never the request body; the
log exists only in debug and profile builds). Narrowing it to the type is planned
for 0.33.1.

Nonce: on iOS the Google SDK puts a `nonce` claim in the ID token, and
Supabase requires the request nonce and the token nonce to be both present or
both absent (it compares the SHA-256 hex of the request nonce with the
token's). On iOS the app makes a random 32-byte nonce (`Random.secure`), gives
Google its SHA-256 hex and gives Supabase the raw value, so a token obtained
elsewhere cannot be injected, and "Skip nonce checks" stays off. It is not
single-use: Supabase keeps no record of used nonces, so a captured token and
nonce pair is limited only by the token's expiry. The nonce is fixed for the app
process because `google_sign_in` takes it once, at initialize. Android sends
no nonce: nothing shows that Play services embeds it, and a mismatch would
break the production sign-in. Revisit with a device test.

**Sign in with Apple (iPhone only).** Native flow: the `sign_in_with_apple` package (8.2.0, `data/` only) gives an Apple identity token, which goes to `auth.signInWithIdToken(provider: apple)`. Android has no Apple button. Each attempt makes a fresh random 32-byte nonce (`Random.secure`); Apple gets its SHA-256 hex, Supabase the raw value, and "Skip nonce checks" stays off for the Apple provider. In Supabase the Apple provider needs the bundle ID `com.esd.sis` in Client IDs (the native flow accepts any listed client ID as the token audience). The Apple secret key (which Apple makes the owner rotate every 6 months) is only for the web OAuth flow, which SIS does not use. The App ID `com.esd.sis` carries the Sign in with Apple capability and `Runner.entitlements` the `com.apple.developer.applesignin` entitlement; `tool/asc_signing.py ensure --signin` turns the capability on through the App Store Connect API and replaces a profile that lacks it, and CI fails the build if the signed app has no such entitlement.

One person, one account: Supabase automatically links identities with the same verified email, so the same address through Google and Apple is one user. The allowlist applies exactly as for Google, through the same hook: an uninvited address gets the same not-invited screen and nothing is stored. A hidden email (`@privaterelay.appleid.com`, what Apple's "Hide My Email" gives) is refused twice: on the phone before any request is sent (the member stays on the sign-in screen and reads "SIS needs your real email address. In Apple's sign-in choose Share My Email and try again."), and by the hook as a server backstop, because a relay address is on no allowlist and cannot be matched to a Google account. A real Apple email that matches an existing member links to that member without the hook running. Both sign-in ways end in `activate_session()`, so one-phone-at-a-time applies to Apple unchanged, including the sign-in buttons on the "You signed in on another phone" screen.

### System account

`00000000-0000-0000-0000-00000000515e` authors the "What's new" messages: it has no email, is on no allowlist and is banned, so it cannot sign in. Never delete it: `messages.sender_id` cascades and every system message would go with it.

### SIS Bot

`sis-destek-bot@example.com` (display name SIS Destek) is an ordinary auth user created through the admin API by the owner-run `tool/sis_bot_admin.sh`; no migration or repo file holds a bot row. Migration `20261005130000_sis_bot.sql` adds `app_private.bot_accounts` (one row; `enabled` is the OFF switch, born OFF), `bot_contacts` (the owner-listed testers) and `bot_actions` (rate log), none granted to API roles.

- Confinement: a trigger on `conversation_members` admits the bot only to its Debug chat and to the 1:1 with a listed tester, always as `member`. It is never an admin and never auto-promoted (`leave_group`, `promote_on_member_deleted` and the admin guard skip it). Removing a contact deletes the bot's membership at once, so its history there is unreadable. Listing the tester again re-adds the bot, with history from that moment only.
- OFF: `has_app_access()` is false while `enabled` is false, which stops every policy and RPC at the next statement, even with a live token.
- Refused for the bot outright (even when ON): `find_by_tag`, `find_by_contacts`, `set_group_avatar`, `deliver_release_notes`, `register_device_token` (so it never gets push), profile edits, contacts, attachment upload other than one photo (below), avatar paths, and the Realtime receive and send policies (`presence:members` is project-wide).
- Rate limits, error code `RLMT2`: 20 messages per 10 minutes, 200 per 24 hours, 10 chats started per 24 hours by the bot itself (a listed tester starting a 1:1 with the bot does not count against it).
- Photos (migration `20261105120000_bot_photo_send.sql`): the bot may upload a plain photo only into a chat it is a current member of. `app_private.bot_upload_ok(name, mime)` in the `attachments_write` policy checks the name shape `<conversation>/<digits>-<first 8 hex of the bot id>.<jpg|jpeg|png|webp|gif>`, an image mime type, and at most 10 uploads per 10 minutes and 50 per 24 hours, counted under an advisory lock. The message trigger then accepts only a plain single photo (every other content column empty) whose stored object belongs to the bot, has an image mime type and is at most 10 MB, and charges it as one send under `RLMT2`. Every other attachment kind stays refused.
- Accepted leftover risks: the object size is not known when the upload policy runs, so an upload that is never sent is capped only by the bucket's 50 MB limit (with a leaked token, at most 50 × 50 MB of unused files per day). The image check trusts the client's claims (name extension and Content-Type); nothing reads the file's bytes, and a broken file shows as "image unavailable".
- It acts through `tool/sis_bot.sh` with its own refresh token in `.private/sis_bot.json` (mode 600, rotated on every run, locked) and never holds the service key. Revoke with `tool/sis_bot.sh revoke` (global sign-out) or, owner-run, `tool/sis_bot_admin.sh revoke` (OFF plus every session deleted).
- The admin tool takes the service key only from a file named by `SIS_SERVICE_KEY_FILE` (mode 600, owned by you, else exit 2), never from an environment variable and never from the repo; the Management API token likewise from `SUPABASE_ACCESS_TOKEN_FILE`. Run it in your own terminal, never through Claude Code `!`, and never export the key in the shell that starts Claude Code. Every run is an authentication in the owner's account and is reported.

### Push processors and the iOS residual risk

Message text in a push (title and body, worded by the recipient's preview
setting) passes through two processors: Google Firebase Cloud Messaging (FCM)
for every device, and Apple Push Notification service (APNs) as well for an
iPhone, because FCM hands iOS pushes to APNs. On Android the app draws the
notification itself and drops a push not addressed to the stored owner. On iOS
the **system** draws the alert, so the app cannot check the owner.

Residual risk, accepted (DECISIONS 2026-09-30): an iPhone signed out while
offline keeps its server session alive (the sign-out call never reached the
server), so its token stays bound to a live active session and the system
still draws its pushes until that session ends (another device signs in, or
the member is revoked). The window has no time limit: sessions have no
timebox or inactivity timeout (`[auth.sessions]` in `supabase/config.toml` is
unset). The full fix is an iOS Notification Service Extension
that checks the owner before the alert is shown; it is a follow-up.

A group's name and the sender's name also travel in the push (as separate
fields, and as an iPhone's alert title and body) under the "Name and message"
and "Only who it is from" settings; "No details" carries neither (DECISIONS
2026-10-01).

A private (encrypted) chat's push is different. Its `body` is only the
placeholder. Only when the recipient's preview is "Name and message" does it also
carry the ciphertext (`ct`, base64) and `ot` (0 or 1), and only if the whole FCM
message fits the byte budget (else it is resent once without `ct`). FCM and APNs
see ciphertext, never the text; the text is opened on the phone (Android: a
read-only peek in a short-lived engine; iPhone: the notification service
extension), which never saves a ratchet step. `ct` and FCM response bodies are
never logged, and no session id rides in the push. For a first (pre-key, `ot` 0) message the sender's id (`si`) and public identity key (`sk`) also ride beside `ct`, from the same SQL gate (preview full, live allowed non-bot sender device) and dropped together with `ct` when the message is over the byte budget. The phone uses them only when it has no stored session with that sender, only after a shape check, and refuses a key already stored for another person or an id other than the chat's peer; with a stored session it ignores them. The peek still builds the session on an in-memory copy and never saves. The key is public and FCM already sees the sender's name. An evil server could substitute its own key (the same trust as the first contact in the app); this is an accepted residual, fixed by the Step 7 security codes. The iPhone ignores `sk` and `si` (it reads only named keys, PushPeekCore.swift). What the phone shows when it
cannot open the text is one locked text, identical on both platforms: "🔒 New
message" (Turkish "🔒 Yeni mesaj"); Android takes it from `notification_locked`,
the iPhone extension sets it for every encrypted push (mutable-content is set for
them all).

### Notification buttons (Mark as read, Reply)

A notification's buttons run where no Supabase session exists (the Android
background isolate, the iOS notification handler), so `notify-on-message`
signs a short-lived action token into the push and `notification-action`
(deployed `--no-verify-jwt`) is the only thing that accepts it.

- Token: `v1.<payload>.<signature>`, HMAC-SHA256 with the service-role key.
  Claims: user, conversation, sha256 of that device's push token, allowed
  actions, expiry (one hour). Rotating the service-role key voids every
  outstanding token, which is the intended revocation.
- The function checks signature, expiry, that the token's conversation is the
  request's, and that the action is in the token. It then calls
  `notification_action(...)` (service role only), which acts as the member:
  it requires the device row bound to the member's active session (a replaced
  device is refused), repeats the `messages_send` checks (app access,
  membership, not the system chat) and marks the chat read through the
  existing `mark_read`.
- A reply carries a client-generated message id: the same id again is a
  success without a second message; a different body under a used id is 409.
- Rate limit: 20 actions per member per rolling minute (`P0429`, HTTP 429),
  kept in `app_private.notification_action_log` (RLS on, no policies).
- Who can read the push data: the token travels in the push, so FCM and APNs
  can read it, and so can any notification-listener app on the phone, which
  can then fire the buttons for up to an hour (the token names one member, one
  chat and one device, and dies when the device is replaced). The recipient's
  user id (UUID) is also in the push data now.
- A request over 20000 bytes or a reply over 4000 characters is refused (400)
  before the database; every refused ticket is 403, a missing token 400.
- Lock-screen Reply: decided 2026-10-06 (owner). Reply requires an unlocked phone on Android 12+ (the system enforces it, `setAuthenticationRequired`) and iOS. On Android 11 and older (API below 31) the system cannot enforce it, so a notification drawn natively (`InstantPush`) omits Reply whenever the phone has a secure lock (`KeyguardManager.isDeviceSecure`), locked or not; the check is made when the notification is drawn, so a lock set afterwards applies from the next one. Mark as read stays on every version. Limit: on those versions a phone with a PIN, pattern or password loses Reply in the shade too, because the app cannot tell when the phone locks; a phone with no secure lock (no PIN, pattern or password) keeps Reply below API 31. As a second guard, `NotificationActionReceiver` refuses a Reply on API below 31 while `KeyguardManager.isDeviceLocked` is true (nothing is sent, the "not sent" line shows; the same holds for `EncryptedReplyActivity` of a private chat, which shows the "not sent" line without the typed text and keeps nothing), which covers a notification drawn by an older build or before a lock was set (finding L1) (the screen-off and user-present broadcasts cannot be declared in the manifest, and a lock-screen-only version of the notification does not hold when the user shows all content on the lock screen). Native `InstantPush` is the only drawer of chat notifications on Android; the Dart handler only keeps the delivery receipt. Therefore, on Android 12+, Reply is behind the unlock for every push, high-priority ones included; there is no Dart-drawn Reply and no `sis.reply_offered` preference. The Android receiver draws on one background thread under `goAsync`, so pacing never blocks the main thread. iOS buttons are drawn by `AppDelegate.swift` (Reply carries `.authenticationRequired`); the Dart side adds no iOS buttons.

  Private (encrypted) chats (I2): the action token of a push into a private chat signs `mark_read` only (decided per chat from `conversations.encrypted_at`, not per message; a failed lookup counts as encrypted), because the notification Reply of a private chat never calls `notification-action`, and `notification_action` still refuses a plain reply into an encrypted chat (42501; a direct plain insert gets ENCR1 from the trigger). It is a different button: on Android `InstantPush.addEncryptedReply` offers Reply only (no Mark as read), with `setAuthenticationRequired(true)` and the same API-below-31 rule as above. Its `PendingIntent.getActivity` targets `EncryptedReplyActivity` by explicit component (`exported=false`, no UI, not in recents); only that intent is `FLAG_MUTABLE` (the system fills in the typed text). The activity reads the text, drops the intent (`setIntent(Intent())`, finish, noHistory), makes the message id at tap time, keeps `{id, chat, member, text}` in memory only (`EncryptedReplyInbox`, never disk, prefs or log, lost if the process dies) and opens SIS. On iPhone the `SIS_MESSAGE_LOCKED` category has a `UNTextInputNotificationAction` with `.authenticationRequired` and `.foreground`; `AppDelegate.swift` keeps the text in memory the same way. Dart then takes it (channel `sis/encrypted_reply`) and calls the normal send queue, which locks the text on the phone and never sends it plain when locking fails. A reply whose member is not the signed-in member is dropped. Nothing is ever encrypted in a receiver, an extension or a background isolate: an unsaved ratchet step would reuse a message key.

### Notification picture link

A photo or video push carries a signed link (600 s) to the small `.t` picture. It is a bearer link: whoever holds it can read that one picture until it expires, without an active session. This is an accepted exception to the active-session rule: the link goes only to recipients `push_targets` chose, is never logged, and deleting the message removes the `.t` object, which ends the link. Both phones fetch it only over https, only from the host of the push's own action link (our Supabase host), without following redirects, and only while a member is signed in (Android).

### Group name colour slot (finding L1)

Former members keep their colour slot, so the number of slots in use leaks how many members a group has had (up to ten). Low risk, accepted.

### Delivery marks

Delivery marks (`conversation_members.delivered_at`, `read_marks().delivered_at`,
Realtime `delivered:<conversation>`) are shown to the other current members
whatever the member's read-receipt or last-seen settings, by product decision
(as WhatsApp does). So that they cannot reveal read or online times, the stored
and broadcast position is always the `created_at` of a real message, never a
clock reading or the moment of a read, and it only moves forward when a newer
message is reached; a departed member's position never moves. Accepted
residual: the moment an advance happens is visible live, so other members can
roughly tell when a member's device received a message. This must not be
widened: no path may write a clock time into `delivered_at` or broadcast one on
`delivered:`.

### Secrets

No secrets in the app or repository. Service-role keys and signing material
exist only in GitHub Actions secrets and in the maintainer's offline backup.

Nothing the app stores on the phone (session, waiting notification previews, the message store)
leaves it through Android backup or device-to-device transfer: both are
excluded in `android/app/src/main/res/xml/` (see DECISIONS 2026-09-24, one
SIS notification). A previous member's notifications are cleared on every
session end the app itself observes, including a cold start onto sign-in or
"not allowed". The server only stops pushes to a session it knows has ended;
it cannot know about one that ended only locally, so the phone is the last
line: it draws nothing without a stored owner, and drops a push addressed to
someone other than the stored owner, even one the server computed correctly
before a handover (see DECISIONS 2026-09-25).

**Stored chat list and last confirmed session (v0.24.0, revised 0.30.15, store moved 2026-10-17).**
The last conversation list the member saw is kept in the `conversations` table
of the encrypted message store (see "On-phone message store" below). It holds
each conversation's id, title, the other person's id, name, tag and picture
path (never an email), the one-line last-message preview and its time, sender
id, unread count and left-group flag. This is personal data. The store is
stamped with the owner's user id; a store that does not match the reading
account is deleted rather than used, and the list is only read for the account
that owns the store. Until 2026-10-17 the list was a plain file,
`chat_list.json`, with the previews in it. The name lives on as the push feed
described below, without any message text. At every launch the app keeps that
file only if it is a valid new feed (version 1, every message field empty) and
deletes anything else, so an old file with previews is gone after the first
start. Drafts are not stored; queued unsent messages are, in the same encrypted
store (table send_queue).

Since 0.30.15 the list is no longer held back until the server has confirmed
the session. A second file, `last_session.json` (the marker), sits in the app support directory:
the user id, the `session_id` claim of the access token, the member (id, name,
tag, picture path; never the email), whether the first-run screen was
finished, and `confirmedAt`. It never holds a token. A cold start shows Home
and the stored list from the marker and the store at once, with no network call before
the first list frame, only when all of these hold: a saved session exists, the
marker's user id is the signed-in user, its session id is the current
token's `session_id`, the member had finished first run, and `confirmedAt` is
at most 14 days old. Otherwise -- a fresh sign-in, another account (which also
deletes the marker), a new session id, an older marker (kept until the next
confirmation overwrites it) -- the gated path runs as before and nothing is
shown until the server answers.

Behind the stored list the app asks `activate_session()`. `true`: confirmed,
and `confirmedAt` moves (only a server `true` ever moves it). `false` (revoked,
or replaced on another device): the Denied screen is assigned in the same
frame, every open page is closed (a chat opened from a notification in the
unconfirmed window never stays on top of it), then the marker, the message store
with its key, the push feed file and the photo cache are wiped. A refresh token the server rejects: signed out
and wiped. A network error, a timeout or a non-retryable server error: the
list stays, a small notice shows, the app retries after 2 s, 4 s ... capped at
60 s and again when the app returns to the foreground; it never confirms and
never clears on a failure. A session end the app observes (sign-out, "not
allowed", a cold start onto sign-in) erases the marker, the store with its key and the feed file.

RLS stays the authority. While unconfirmed nothing the server would refuse is
granted: reads of a revoked member return no rows, `messages_send` and
`register_device_token` refuse them. Sends made meanwhile are queued like any
optimistic send; a refusal (42501) is not retried, and Denied drops the queue
and the drafts. Accepted residual risk: a member revoked while this phone is
offline sees the stored list (and nothing newer) until the phone reaches the
server or the 14 days end. The marker and the feed file are in the app's private directory,
encrypted with the phone, and excluded from backup (the store is covered below): on Android by
`allowBackup="false"` plus the data-extraction rules, on iOS by
`NSURLIsExcludedFromBackupKey` set on Application Support at launch (new in
0.30.15; before it these files could be in iCloud and iTunes backups on iOS).
Low note: the iOS Keychain session survives an uninstall.

### On-phone message store (Private Chats step 1)

Since 2026-10-17 each phone keeps a copy of the member's chats: text and
metadata only, never media, never a message still being sent. The server stays
the truth (DECISIONS 2026-10-17).

- **Encrypted file.** One file, `sis_store.sqlite` (with `-wal`, `-shm` and
  `-journal` beside it), made by drift on SQLite3 Multiple Ciphers. The key is
  set with `PRAGMA key` on every connection. A plain SQLite would ignore that
  and store everything unencrypted, so the app refuses to run if the cipher
  build is not loaded.
- **Where the key lives.** 32 random bytes (64 hex characters) from
  `Random.secure`, made once and kept in the platform secure storage
  (`flutter_secure_storage`: Android Keystore, iOS Keychain) as `sis.store.key`.
  On iOS it is `first_unlock_this_device`: a backup carries it locked to this
  phone's hardware, so it is restored only onto the same phone. Every erase
  deletes it.
- **Where the file lives.** Android: the app support directory (never the cache,
  which the OS may clear). iOS: the App Group container `group.com.esd.sis`, so
  a notification extension can reach it later; the app support directory if the
  container is unavailable. One function in `data/store/store_location.dart`
  decides.
- **Backup is off.** Android: `allowBackup="false"` plus the extraction rules.
  iOS: the exclude-from-backup flag is set on Application Support only, not on
  the App Group container. There the protection is the key: it is this-device-only,
  so the file is readable again only when restored onto the same phone (same
  owner; `activate_session` still decides). On any other phone a restored file
  cannot be opened; the app deletes it and starts empty.
- **Owner check on open.** The file holds the owner's user id (`meta.owner_id`).
  It is written when missing. A different owner, a wrong key or a corrupt file
  makes the app delete the files and start again from nothing. An open that began
  before an erase deletes the files and the key it just made, and fails.
- **Erasure on SignedOut, Denied and Replaced.** One routine, in this order:
  clear the chat-list snapshot (the push feed file first, then the list
  tables), then `store.clear()`, then clear the snapshot a second time, then
  invalidate `messageStoreProvider`. The second clear catches a list save that
  finished before `store.clear()` and rewrote the feed. It must run before the
  invalidate: after it, a fresh store would re-create the database.
- **Process-wide erase counter.** Every `clear()` on any store instance raises
  one static counter. An instance whose work began before a raise closes itself
  and refuses to serve or write. `clear()` waits for the work already running,
  closes the database, then deletes the files and the key. A closed store
  refuses every write.
- **Push feed.** `chat_list.json` in the app support directory exists only for
  the Android push code, which reads picture paths from it. `lastMessage`,
  `lastMessageAt` and `lastSenderId` are always null: it never holds message
  text. It is written to a `.part` file and renamed. A static epoch in the
  writer is raised by every clear. A list save captures the epoch at the start
  of `save()` and writes the feed only if the database took the list and the
  epoch has not changed; the writer checks the epoch again around its rename.
- **The SQLite finding (case A and case B).** Case A: a save queued behind other
  work starts writing after the file was unlinked; SQLite refuses the write and
  no feed is written. Case B: the save's first write landed before the unlink and
  its commit succeeds into the unlinked file after the whole erase. Only the
  epoch captured at the start of `save()` stops the feed write there. Rows
  committed into the unlinked file are harmless: no file remains.
- **Sync stops on a change of account.** `StoreSyncController` (catch-up and
  history fill) checks a halt before every write to the store: after each server
  read and before the write, and before it saves the cursor. It halts when the
  account changed, the store instance is no longer the current one, or a new run
  was asked. It keeps the instance it started with, and a closed instance
  refuses writes, so a late write cannot reach another account's store.
- **Server side.** Migration `20261028120000_messages_updated_at.sql` adds
  `messages.updated_at`, set by a `BEFORE INSERT OR UPDATE` trigger to
  `clock_timestamp()` on every write. A client value is ignored, and the column
  has no insert or update grant. The trigger function is in `app_private` with
  `search_path ''` and no execute right for `public`, `anon` or `authenticated`.
  There are no new grants and RLS is unchanged. `changesSince`, `newestChange`
  and `messagesBefore` use the member's own client through PostgREST (no service
  key, no RPC), so they read only the rows `messages_read` allows. A non-member
  gets nothing.
- **Accepted residuals.**
  - The change feed is blind to hide-for-me (a separate table), hard-deleted
    rows and chats removed from the list. Those leave the phone at the next
    list purge or reconcile of that chat's page.
  - A halt in the middle of one page write (between removing the stale rows and
    writing the new ones) is not covered; the closed old store refuses the write.
  - There is no reconnect signal in the app. App start, resume and sign-in start
    a catch-up; a Realtime reconnect does not.
  - A live row written between a page read and its commit can be deleted by the
    reconcile; the next catch-up pass adds it again.
  - Members can see when a message last changed (an edit or a deletion). They
    already see that moment over Realtime.
  - A rare X to Y to sign-out to Z race can wipe the local cache; the network
    refills it.
  - If two deletes of the feed's `.part` file both fail, the file can stay. It
    holds no message text and is never read.

**Accepted risk: CI secrets and pushed branches.** Any branch pushed to
this repository runs its own workflow files and can reach every repository
secret, including the Admin App Store Connect key. Accepted while the owner
is the only collaborator. If collaborators are added, move
`APP_STORE_CONNECT_API_KEY` into a protected-branch environment used only by
the two release jobs that need it (`ios` and `distribute`), and give the
pull-request signing proof a separate key or drop it. The Admin key is
kept for `distribute` (TestFlight groups and beta review) and for the
one-off `ios-signing-bootstrap.yml` (creates the distribution certificate); the
`ios` job only reads the certificate and profile.

**Accepted risk: a long-lived iOS signing key in repository secrets** (decided
2026-10-01, `docs/DECISIONS.md`). Every build is signed with one Apple
Distribution certificate whose private key is the secret `IOS_DISTRIBUTION_KEY`,
valid for a year. Same trust model as `ANDROID_UPLOAD_KEYSTORE_BASE64`: any
pushed branch can read it, so a branch author can sign a build as this team
until the certificate is revoked. Unlike the Android keystore, which only the
release after a merge receives, this key is also handed to every same-repository
pull request's `iOS signed build`, which runs that branch's own workflow file. The key was previously minted per run, but
the same branch author could always mint a fresh certificate with the App Store
Connect key, so the added exposure is that a stolen key stays usable for the
rest of the certificate's year instead of one job. A signed build still has to
get past App Store Connect (bundle ID, team, TestFlight review) to reach a
tester. Mitigations:
the key is written to the runner with mode 600 only in the `ios` job and
removed at the end, never printed, and the bootstrap workflow never sees it
(it receives only a CSR). When collaborators are added, move
`IOS_DISTRIBUTION_KEY` into a protected-branch environment together with the
App Store Connect key. Compromise or a lost key: revoke the certificate in App
Store Connect and run the bootstrap again (DELIVERY.md, Certificate lifecycle);
builds it signed that are still in review fail. Leftover certificates
no longer accumulate: runs create none; the three-slot limit is used by the
one certificate (plus one during a rotation). Rotate the key in App Store Connect (Users and Access, Integrations)
when a collaborator leaves or a dependency is suspected compromised.

### Key directory (Private Chats step 3)

- Tables `app_private.olm_devices`, `olm_one_time_keys`, `olm_claims`: all rights revoked from public, anon and authenticated; RLS enabled with no policy; not in the `supabase_realtime` publication. Only three security-definer RPCs (search_path '') touch them: `publish_olm_keys`, `claim_olm_keys`, `olm_key_status`; anon cannot execute them.
- `publish_olm_keys`: the owner is auth.uid() (no user parameter); needs has_app_access (the active session still exists in auth.sessions); bots are refused (42501); 30 calls an hour (RLMT1, tag_lookups kind olm_publish). Inputs are checked and a bad one gives 22023 'invalid request' without echoing input: 43-character base64 keys, 86-character signature, identity key differs from signing key, no duplicate or null keys, fallback differs from every one-time key, at most 100 per call and 100 free in total. A phone is the same device only when identity key AND signing key both match; otherwise all old one-time keys are deleted and the device row replaced (this is how the one-active-phone rule drops old keys). For the same device a re-publish is idempotent and rebinds session_id.
- `claim_olm_keys`: the caller needs access and is no bot; the target must be allowlisted (is_allowed), reachable (can_reach) and not the caller; every refusal is the same 42501. An advisory lock per caller; every call that passed the gates is counted: 60 an hour per caller and 5 an hour per caller and target (RLMT1). A claimed key gets claimed_at set and stays as a tombstone (never deleted), so a re-publish cannot hand it out twice; claiming uses FOR UPDATE SKIP LOCKED. An empty pool returns the fallback key (reusable; fallback_used is set). Nothing is returned unless the device row's session_id is the target's active session and that session still exists in auth.sessions.
- Self-signature: each phone signs `sis-olm-v1|<user_id>|<identity_key>|<signing_key>` with its Ed25519 key; the server stores it, claim returns it, and the claiming phone verifies it before opening any session (claimVerified; a failure is DeviceKeysFailure). Step 7 security codes must cover the Ed25519 key; with the signature it also binds the Curve25519 key.
- Known limits: the server could swap one-time or fallback keys (messages then fail; nothing becomes readable); a member can drain another's pool (5 an hour per target), so first messages use the fallback key and lose some forward secrecy, and top-up at app start and resume repairs it; a signed-out target (no live session) gives 42501 and a signed-in target with no keys gives an empty result; refusals roll back so they are not rate-counted (accepted: a reachable member can learn whether the target is signed in); tombstones are pruned after a year.
- On the phone: the account is an encrypted vodozemac pickle in the encrypted on-phone store (meta row `olm_account`); its 32-byte key is in secure storage as `sis.olm.pickle.key` (this device only) and is deleted with the store key at sign-out. The pickle is saved before publishing and again after marking published; a failed publish is retried (idempotent). No pickle but a server row bound to this same session (olm_key_status same_session) means identity lost (KeysIdentityLost): never a silent new account; a row bound to another session (sign-out and sign-in, new phone) gets a new account and a publish. Pickles, keys and engine errors are never logged or shown.
- The engine keeps the previous fallback key on rotation (late first messages still decrypt); this step never forgets it.

### Encrypted one-to-one text (Private Chats step 4a)

- A one-to-one text between two human members is locked (Olm) on the sender's phone and opened only on the receiver's phone. The server, Supabase, Google and Apple see ciphertext, never the text. Metadata (who, when, size, type) stays visible.
- A locked message is a messages row with `ciphertext` and `olm_type` set and `body` fixed to the placeholder `🔒 Encrypted message`. A CHECK forces link_preview, attachments, poll, contact, photo group, sticker and location to be empty on such a row.
- Only a direct human chat can hold ciphertext; bots never send it. Server search never matches ciphertext rows (search runs on the phone).
- No downgrade after the first locked message: once a conversation has held one (`conversations.encrypted_at`, kept after deletes), the server refuses a plain insert into it, and `notification_action` refuses a reply into it.
- First-message gap: the first message of a chat is sent in plain text when the peer has published no keys (the key lookup returns nothing). A malicious server that withholds the peer's keys can cause this. Any lookup error blocks the send instead of sending plain. A verified security code does not cover that message. There is no "not encrypted" label yet (step 9).
- Security codes (step 7): each one-to-one chat has a 60-digit code and a QR code, built on the phone from both members' identity keys (Curve25519 from the live session row, Ed25519 only when its signature checks and it matches that session; no session, no code). "Matches" marks the person verified on this phone only (meta `verified:<peer>`, stored with both keys); any key change clears it and adds a "security code changed" line in the chat. One device per user in v1: a new phone means a new code.
- Phone-side checks against a malicious server: an opened text is never shown under a different sender than the one it was stored with; an identity key already bound to another user is refused; the notification name comes from the phone's own chat copy when it has one; once a chat has held a locked text (meta `held:<conv>`), a later plain text from the peer is shown locked. Kinds that stay plain by design (polls, contacts, places, stickers) and media with a caption are not flagged. Known gaps until step 6: a forged plain caption, poll, contact or place still shows as the peer's; the check trusts the server's dates.
- Plain until step 6: places, polls, contacts, photos and other media with captions, stickers, voice and the emoji of reactions in chats that are not locked (groups, bot chats, a person with no published keys). The link-card picture is not uploaded in a locked chat.
- Reactions in a locked chat: the emoji is locked the same way (Olm, a versioned envelope bound to the message id and the reactor's user id, padded to one fixed length of 192 bytes; an emoji over 64 bytes is refused on the phone) and stored as message_reactions.ciphertext / olm_type through set_reaction_encrypted (same gate as a locked message: direct human chat, no bot, every member with live keys; the first locked reaction also sets encrypted_at). set_reaction refuses a plain emoji once the chat is locked; a clear still works. A reaction is never sent plain when locking fails. The server sees who reacted to which message, when, and set versus cleared, never the emoji. Opened reactions are kept once in the encrypted on-phone store (reaction_plains); an unreadable one is hidden. Reactions are not queued: a failed one is rolled back and locked afresh on the next tap (a network retry inside one tap reuses the same bytes). Reactions never reach a push (a reaction push, when built, must send only a fixed locked text in a locked chat).
- Old plain reactions: the migration clears plain emoji made at or after encrypted_at in locked chats; reactions from before encrypted_at stay (sent before encryption). The member's own old plain reactions are re-locked on the phone, up to 100 each time the chat is opened (relock_reaction: only a reaction that is still plain is replaced, so a newer change or a removal is never undone); other people's old plain reactions stay until their own phone re-locks them. A peer's locked reaction is opened only after a complete message catch-up that began after it was read, so it normally cannot use up the Olm chain before that person's older messages. Rare gap: a peer who queues more than 40 messages while offline and reacts before that queue is sent can still make a reaction open first. Supabase backups and point-in-time recovery keep the old plain values until they expire.
- The send queue lives in the encrypted on-phone store, with the ciphertext of a locked text, so a retry sends the same bytes.
- Notifications: the push carries `encrypted: true`; the locked text is "🔒 New message" (Turkish "🔒 Yeni mesaj") on both platforms, with the sender's name. No Mark as read button. Reply is offered (see "Notification buttons", I2).
- Notification residue (M5): once the real text is shown it is in the system's hands. Android: a notification listener app, a watch or other wearable, and the notification history (Android 11+) can read or keep it; the lock screen shows only the locked public version (`setPublicVersion`) unless the member chose to show all content, and the app itself writes the text only to memory (never `PushInbox` or SharedPreferences). iPhone: delivered notifications keep the text in the system's notification store until dismissed or cleared by reading the chat, and an Apple Watch or a connected device mirrors it. The member's "Name and message" setting is the switch: any other setting keeps the text out of the push, so none of this applies.
- iPhone: the push carries category `SIS_MESSAGE_LOCKED` (a foreground Reply only).
- On the phone, an opened text is stored once. The store's upsert is one atomic statement, so a live row never replaces a deleted one. A hidden or vanished message is dropped from the opener's waiting list, so it cannot come back.

## Runbook

- **Allow a member:** insert the row directly against the project, through the
  Supabase SQL editor or `psql`:
  `insert into app_private.allowlist(email) values (lower(btrim('...'))) on conflict do nothing;`
  **Not through a migration.** Migrations are tracked, and a tracked file must
  never contain a personal email address (see the repository hygiene rule). The
  allowlist is membership data, not schema.
- **Revoke a member:** delete the row the same way. Their next request fails
  `has_app_access()`; the app shows *Access denied*. Existing tokens do not
  need revoking — the gate is checked per request, not at sign-in.
- **Lost or stolen phone:** the member signs in on another device; `activate_session()` makes it the only active device. No admin action needed.
- Allowlist emails are stored lower-case and trimmed (a check constraint enforces it) and compared against the confirmed `auth.users` email, normalised the same way. JWT claims are never used for authorisation.
- **Every new `public` table** must `enable row level security` and `revoke all ... from anon, authenticated`, then grant only what policies allow — Supabase's default privileges grant both roles full access to new tables, and RLS does not cover `TRUNCATE`.
- Profiles are readable by an active member **only for accounts that are
  themselves allowlisted**. Anyone who completes Google sign-in gets a
  `profiles` row — Google Play's automated pre-launch testing created eleven
  such accounts on 2026-09-21 — so a contact list scoped only by
  `has_app_access()` would list strangers by name and let any member enumerate
  everyone who ever signed in. Do not widen it back. The sign-up hook (see Sign-in flow) now also stops a
  stranger's Google sign-in from creating the row at all.
- **Never** grant `anon` or `authenticated` anything on `app_private`; never disable RLS on a `public` table.
