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
  - `messages.attachment_path` points into the private `attachments` storage
    bucket, keyed `<conversation_id>/<file>`. The storage policies ask the same
    membership question the table policies ask, so there is one access rule and
    not two that can drift.
  - `profiles` is readable only for accounts that are **themselves on the
    allowlist** — anyone who completes Google sign-in gets a row, and without
    that clause a member could enumerate every account that ever signed in.

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

Message search, `public.search_messages(query, conversation)`, is a
`security definer` RPC like the other public RPCs. The alternative,
running it with the caller's rights under row-level security, can't be fast:
`LIKE` and the trigram operators aren't leakproof, so RLS forces a scan of
every message. So the function repeats `messages_read` explicitly:
`has_app_access()` and `is_member(conversation_id)`, the same functions the
policy calls. It also bounds the rows to the caller's memberships first, and
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

### Secrets

No secrets in the app or repository. Service-role keys and signing material
exist only in GitHub Actions secrets and in the maintainer's offline backup.

Nothing the app stores on the phone (session, waiting notification previews)
leaves it through Android backup or device-to-device transfer: both are
excluded in `android/app/src/main/res/xml/` (see DECISIONS 2026-09-24, one
SIS notification). A previous member's notifications are cleared on every
session end the app itself observes, including a cold start onto sign-in or
"not allowed". The server only stops pushes to a session it knows has ended;
it cannot know about one that ended only locally, so the phone is the last
line: it draws nothing without a stored owner, and drops a push addressed to
someone other than the stored owner, even one the server computed correctly
before a handover (see DECISIONS 2026-09-25).

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
