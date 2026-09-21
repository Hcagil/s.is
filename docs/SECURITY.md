# Security model

Source of truth: [DESIGN.md §4](DESIGN.md).

Postgres Row Level Security is the only authority. The client is untrusted.

### Schemas

- `app_private` — not exposed through the API and revoked from `anon` and
  `authenticated`; RLS enabled as well.
  - `allowlist(email citext primary key, added_at)`
  - `active_sessions(user_id primary key, session_id uuid, session_created_at)`
- `public` — RLS enabled on every table; policies use the helpers below.
  - `profiles(user_id pk → auth.users, display_name, created_at)` — created by
    a trigger on `auth.users` insert.
  - `app_config(id = 1, min_supported_build int)` — single row, readable by
    any authenticated user, never writable from the client. The latest
    available build is not stored: Google Play reports it to the app.
  - v0.2: `conversations`, `conversation_members`, `messages`.
  - v0.3: group fields on `conversations`.

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
never regain access. Every read, write, RPC and Realtime delivery requires
`has_app_access()`. Realtime never substitutes for RLS.

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

## Runbook

- **Allow a member:** add a migration `supabase/migrations/<ts>_allow_<name>.sql` containing `insert into app_private.allowlist(email) values ('person@example.com') on conflict do nothing;`. Merge to `main`; the release workflow applies it.
- **Revoke a member:** a migration deleting the row. Their next request fails `has_app_access()`; the app shows *Access denied*.
- **Lost or stolen phone:** the member signs in on another device; `activate_session()` makes it the only active device. No admin action needed.
- Allowlist emails are stored lower-case and trimmed (a check constraint enforces it) and compared against the confirmed `auth.users` email, normalised the same way. JWT claims are never used for authorisation.
- **Every new `public` table** must `enable row level security` and `revoke all ... from anon, authenticated`, then grant only what policies allow — Supabase's default privileges grant both roles full access to new tables, and RLS does not cover `TRUNCATE`.
- Profiles are readable by every active member (a contact list); this is intentional.
- **Never** grant `anon` or `authenticated` anything on `app_private`; never disable RLS on a `public` table.
