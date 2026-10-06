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

**Sign-up gate (before user created hook).** Google is the only provider. The
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

### System account

`00000000-0000-0000-0000-00000000515e` authors the "What's new" messages: it has no email, is on no allowlist and is banned, so it cannot sign in. Never delete it: `messages.sender_id` cascades and every system message would go with it.

### SIS Bot

`sis-destek-bot@example.com` (display name SIS Destek) is an ordinary auth user created through the admin API by the owner-run `tool/sis_bot_admin.sh`; no migration or repo file holds a bot row. Migration `20261005130000_sis_bot.sql` adds `app_private.bot_accounts` (one row; `enabled` is the OFF switch, born OFF), `bot_contacts` (the owner-listed testers) and `bot_actions` (rate log), none granted to API roles.

- Confinement: a trigger on `conversation_members` admits the bot only to its Debug chat and to the 1:1 with a listed tester, always as `member`. It is never an admin and never auto-promoted (`leave_group`, `promote_on_member_deleted` and the admin guard skip it). Removing a contact deletes the bot's membership at once, so its history there is unreadable. Listing the tester again re-adds the bot, with history from that moment only.
- OFF: `has_app_access()` is false while `enabled` is false, which stops every policy and RPC at the next statement, even with a live token.
- Refused for the bot outright (even when ON): `find_by_tag`, `set_group_avatar`, `deliver_release_notes`, `register_device_token` (so it never gets push), profile edits, contacts, attachment upload, avatar paths, and the Realtime receive and send policies (`presence:members` is project-wide).
- Rate limits, error code `RLMT2`: 20 messages per 10 minutes, 200 per 24 hours, 10 chats started per 24 hours by the bot itself (a listed tester starting a 1:1 with the bot does not count against it). Text only.
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
- Lock-screen Reply: decision pending (owner).

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

**Stored chat list and last confirmed session (v0.24.0, revised 0.30.15).**
The last conversation list the member saw is kept in one file,
`chat_list.json`, in the app's private support directory (`files/`, never the
cache). It holds each conversation's id, title, the other person's id, name,
tag and picture path (never an email), the one-line last-message preview and
its time, sender id, unread count and left-group flag. This is personal data.
It is written to a temporary file and renamed, stamped with the owner's user
id and a schema version, and any file that does not match the reading
account, is on an old schema, or is unreadable is deleted rather than used.
Once an erase and any save it overtook have finished, neither the list file
nor its temporary file remains, wherever that save had reached, including its
final rename (since v0.24.1). A process killed mid-save can leave the
temporary file, which the app never reads, until the next erase or save.
Once the owner changes, the previous owner's list is unreachable from the app's
list state, even while the new owner's list is loading or has failed. Drafts
and queued unsent messages are not stored.

Since 0.30.15 the list is no longer held back until the server has confirmed
the session. A second file, `last_session.json` (the marker), sits beside it:
the user id, the `session_id` claim of the access token, the member (id, name,
tag, picture path; never the email), whether the first-run screen was
finished, and `confirmedAt`. It never holds a token. A cold start shows Home
and the stored list from the two files at once, with no network call before
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
unconfirmed window never stays on top of it), then the marker, the list file
and the photo cache are wiped. A refresh token the server rejects: signed out
and wiped. A network error, a timeout or a non-retryable server error: the
list stays, a small notice shows, the app retries after 2 s, 4 s ... capped at
60 s and again when the app returns to the foreground; it never confirms and
never clears on a failure. A session end the app observes (sign-out, "not
allowed", a cold start onto sign-in) erases both files.

RLS stays the authority. While unconfirmed nothing the server would refuse is
granted: reads of a revoked member return no rows, `messages_send` and
`register_device_token` refuse them. Sends made meanwhile are queued like any
optimistic send; a refusal (42501) is not retried, and Denied drops the queue
and the drafts. Accepted residual risk: a member revoked while this phone is
offline sees the stored list (and nothing newer) until the phone reaches the
server or the 14 days end. Both files are in the app's private directory,
encrypted with the phone, and excluded from backup: on Android by
`allowBackup="false"` plus the data-extraction rules, on iOS by
`NSURLIsExcludedFromBackupKey` set on Application Support at launch (new in
0.30.15; before it these files could be in iCloud and iTunes backups on iOS).
Low note: the iOS Keychain session survives an uninstall.

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
