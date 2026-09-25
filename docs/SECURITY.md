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

Presence and typing use **private** Realtime channels. RLS on
`realtime.messages` opens exactly two topics — `presence:members` and
`typing:<conversation id>` — to active members (and conversation members for
typing), and the send side also requires the member's own sharing switch to be
on. Any other private topic is refused.

Realtime publishes **inserts only**: `realtime.apply_rls` evaluates row-level
security for INSERT and UPDATE but delivers DELETE to every subscriber of the
table without consulting it.

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
session end, including a cold start onto sign-in or "not allowed".

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
