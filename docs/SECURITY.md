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
  - `device_tokens(user_id, token, platform, updated_at)` — push delivery
    addresses. One row per member: registering replaces, so a replaced phone
    stops being notified when it stops being able to read.
  - `push_receipts(user_id, message_id, stage, error, build, ...)` — what
    became of each push on a phone. RLS on, no policy, no grant. Written only
    by `public.report_push_receipts(jsonb)` (security definer, app access
    required, `authenticated` only): rows are always `auth.uid()`'s, invalid
    stages are skipped, errors cut to 300 characters, 100 per call, newest 500
    kept per member. Never holds message text.
- `public` — RLS enabled on every table; policies use the helpers below.
  - `profiles(user_id pk → auth.users, display_name, created_at)` — created by
    a trigger on `auth.users` insert.
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
    reply_to, forwarded`; `created_at`, `deleted`, `deleted_at` and
    `edited_at` stay server-assigned, and there is no UPDATE or DELETE
    privilege (edits and deletes go through `edit_message` /
    `delete_message`). The `id` is proposed by the phone (a random v4 UUID),
    so a send queued offline can be retried safely: the primary key refuses
    an id that already exists. Any UUID is accepted, so **nothing may trust a
    message id to be server-generated or unpredictable** — never key an
    authorisation decision, storage path or topic on it. The app treats a
    duplicate-key answer as "already sent" only when the stored row is the
    caller's own, in the same conversation, with the same body (and, when
    the retried message is a reply, the same reply target);
    otherwise the send fails. Accepted leftover risk: a member who already
    knows a message id learns whether that message exists.
  - Drafts and queued unsent messages live in the app's memory only; if they
    are ever stored on the phone (not stored as of v0.24.0; the chat list is — see Secrets), they are
    personal data under the on-phone storage posture.
  - `messages.attachment_path` points into the private `attachments` storage
    bucket, keyed `<conversation_id>/<file>`. The storage policies ask the same
    membership question the table policies ask, so there is one access rule and
    not two that can drift.
  - `profiles` rows are readable only for an allowlisted account that is the
    caller, shares a conversation with the caller, or is a contact the
    caller saved; a tag find alone does not open the row (`find_by_tag`
    returns its own single row). **Reach** (`app_private.can_reach`) is those
    three plus someone the caller found by exact tag (`app_private.tag_finds`,
    written by `find_by_tag`, cleared when the found member changes their
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
  - `find_by_tag(tag)` is the one deliberate way to reach a stranger: exact
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

iOS: the iOS OAuth client `306417977220-vqg0ne5360a921i23quf294g8e0fjshq` is
set as `GIDClientID` in `ios/Runner/Info.plist`. The Web client stays
`serverClientId`, so the ID token's audience is still the Web client and
Supabase keeps one client list.

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

### System account

`00000000-0000-0000-0000-00000000515e` authors the "What's new" messages: it has no email, is on no allowlist and is banned, so it cannot sign in. Never delete it: `messages.sender_id` cascades and every system message would go with it.

### Secrets

No secrets in the app or repository. Service-role keys and signing material
exist only in GitHub Actions secrets and in the maintainer's offline backup.

Nothing the app stores on the phone (session, waiting notification previews, the stored chat list)
leaves it through Android backup or device-to-device transfer: both are
excluded in `android/app/src/main/res/xml/` (see DECISIONS 2026-09-24, one
SIS notification). A previous member's notifications are cleared on every
session end the app itself observes, including a cold start onto sign-in or
"not allowed". The server only stops pushes to a session it knows has ended;
it cannot know about one that ended only locally, so the phone is the last
line: it draws nothing without a stored owner, and drops a push addressed to
someone other than the stored owner, even one the server computed correctly
before a handover (see DECISIONS 2026-09-25).

**Stored chat list (v0.24.0).** The last conversation list the member saw is
kept in one file, `chat_list.json`, in the app's private support directory
(`files/`, never the cache). It holds each conversation's id, title, the
other person's id, name, tag and picture path (never an email), the one-line
last-message preview and its time, sender id, unread count and left-group
flag. This is personal data. It is written to a temporary file and renamed,
stamped with the owner's user id and a schema version, and any file that does
not match the reading account, is on an old schema, or is unreadable is
deleted rather than used. It is shown only after the server has confirmed the
session (`activate_session()` returned true and the member profile loaded); a
phone offline at start-up, or a session that is refused, never displays it.
It is erased on every session end the app observes (sign-out, a cold start
onto sign-in, or "not allowed"). Once an erase and any save it overtook have
finished, neither the list file nor its temporary file remains, wherever that
save had reached, including its final rename (since v0.24.1). A process killed
mid-save can leave the temporary file, which the app never reads, until the
next erase or save. A different account's first list load deletes the list
file. Once the owner
changes, the previous owner's list is unreachable from the app's list state,
even while the new owner's list is loading or has failed. Accepted leftover: a
phone whose access was removed or replaced and that never reaches the server
again keeps the file; it is unreadable through the app, encrypted with the
phone, and excluded from backup. Drafts and queued unsent messages
are still not stored.

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
  everyone who ever signed in. Do not widen it back.
- **Never** grant `anon` or `authenticated` anything on `app_private`; never disable RLS on a `public` table.
