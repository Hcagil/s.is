# SIS — System design

SIS (S.IS) is a small private chat application by ESD. This document is the
design of record: what the system is, how it is built, how it ships, and the
rules the code is held to. Decisions and their dates are in
[DECISIONS.md](DECISIONS.md); the version plan is in [ROADMAP.md](ROADMAP.md).

## 1. Purpose and scope

- A private, allowlisted group of people exchange text messages, 1:1 and later
  in groups.
- Android first, then iOS. The Flutter code is cross-platform from the first
  version; only the delivery pipeline is Android-only until iOS is added.
- Every version is delivered through Google Play (internal testing track), by
  an automated pipeline, with **no manual steps**: no cable, no manual upload.
- Users are never forced to update unless a build is below the server-side
  minimum supported build, which is raised only by an explicit, recorded
  decision.

Out of scope until explicitly scheduled: iOS, end-to-end encryption, web,
analytics, monetisation, public sign-up.

## 2. System shape

```
Phone (Flutter)  ──HTTPS/WSS──▶  Supabase project (Postgres + Auth + Realtime)
      ▲ install / update                     ▲ forward-only migrations
Google Play internal track  ◀── GitHub Actions (release) ◀── merge to main
```

Four components, nothing else: the app, the Supabase project, the GitHub
repository with its workflows, and the Play Console app `com.esd.sis`.

### Kept from the previous iteration

Play app `com.esd.sis` with Play App Signing and the upload key; Supabase
project `S.IS` (eu-west-1) including its Google auth provider; the GitHub
repository; the Docker images for the Flutter/Android toolchain and the
Supabase CLI. All application code, tests, documentation and the database
schema are replaced by the restart (see DECISIONS 2026-09-21).

## 3. Application architecture

Pattern: **layered feature modules with Riverpod** for state and dependency
injection. Chosen over BLoC (double the boilerplate for this size) and over
hand-wired `ChangeNotifier`s (no enforceable boundaries).

```
lib/
  main.dart               bootstrap only: config → ProviderScope → App
  app/                    MaterialApp, theme, top-level routing
  core/                   RuntimeConfig, Failure types, Result — no widgets, no SDKs
  features/<feature>/
    domain/               immutable models + repository interfaces (pure Dart)
    data/                 repository implementations — the ONLY layer importing
                          an SDK; tool/check_pattern.sh holds the list
    application/          Riverpod Notifiers: state machines; import domain only
    presentation/         widgets: watch state, call notifiers, render
```

Features in v0.1: `auth`, `update`, `home`. v0.2 adds `chat`; v0.3 adds groups
inside `chat`.

### Layer rules (mechanically checked)

1. `presentation/` never imports `supabase_flutter`, `google_sign_in`,
   `in_app_update`, or any `data/` file.
2. `application/` imports only `domain/` and `core/` (plus `riverpod`); no
   Flutter widgets, no SDKs.
3. Only `data/` imports SDKs. Every repository implements a `domain/`
   interface so controllers are tested with fakes.
4. Every Notifier has a unit test. Every RLS policy has a pgTAP test.

`tool/check_pattern.sh` enforces rules 1–3 by import analysis; it runs in CI
and blocks the merge on any violation. Violations are fixed by rewriting the
offending code to the pattern, not by exempting it.

### Errors

Repositories return `Result<T>` with typed `Failure`s
(`network`, `denied`, `provider(reason)`), never raw exceptions. An
incomplete runtime configuration is not one of them: it is a screen state
(`SetupRequired`), reached before any repository exists. Notifiers map failures to explicit screen states. Every failure
state shows its reason on screen; there are no silent returns to a previous
screen.

### Runtime configuration

`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_WEB_CLIENT_ID` are
compile-time `--dart-define`s. They are public by design. An incomplete
configuration renders a "setup required" screen; it never falls back to
mock data.

## 4. Data and security model

Postgres Row Level Security is the only authority. The client is untrusted.

### Schemas

- `app_private` — not exposed through the API and revoked from `anon` and
  `authenticated`; RLS enabled as well.
  - `allowlist(email text primary key, added_at)` — stored lower-case/trimmed;
    compared against the normalised, confirmed `auth.users` email
  - `active_sessions(user_id primary key, session_id uuid, session_created_at)`
- `public` — RLS enabled on every table; policies use the helpers below.
  - `profiles(user_id pk → auth.users, display_name, created_at)` — created by
    a trigger on `auth.users` insert.
  - `app_config(id = 1, min_supported_build int)` — single row, readable by
    active members, never writable from the client. The latest
    available build is not stored: Google Play reports it to the app.
  - v0.2: `conversations`, `conversation_members`, `messages`.
  - v0.3: `conversations.title` — a conversation is a group when it has one;
    a 1:1 keeps its unique `direct_key` and a null title.
  - later: `messages.attachment_path` and a private `attachments` storage
    bucket keyed `<conversation_id>/<file>`, so the storage policy asks the
    same membership question the table policies ask.
- `app_private` also holds `device_tokens` for push — private, one row per
  member, replaced rather than accumulated so a device stops being notified
  when it stops being able to read.

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

## 5. Update policy

- On launch the app reads `app_config`.
- `installed < min_supported_build` → blocking "update required" screen with a
  Play link. Raising `min_supported_build` is a manual, recorded decision,
  used only when an older build would break against the current backend.
- Otherwise, if Play reports a newer version → **flexible** in-app update:
  dismissible banner, background download, install on tap. No repeated
  prompts.
- Publishing a build never changes `min_supported_build`.
- Migrations must remain compatible with every build ≥ `min_supported_build`.

## 6. Delivery pipeline

### Branching and commits

Trunk-based development: `main` is the only long-lived branch and is always
releasable. Every change is a short-lived topic branch named
`<type>/<short-kebab-description>`, opened as a pull request and
**squash-merged**, so `main` receives exactly one commit per change.

Types: `feat` (user-visible feature), `fix` (bug), `chore` (maintenance,
dependencies, tooling), `docs`, `ci` (workflows), `refactor`, `test`, `db`
(migrations). Examples: `feat/google-sign-in`, `ci/play-release-workflow`,
`db/conversations-schema`, `fix/sign-in-reason-hidden`.

The squash commit title follows Conventional Commits —
`type(scope): summary` (e.g. `feat(auth): google native sign-in with
allowlist gate`) — so history reads as a changelog and release notes can be
generated from it. Branches are deleted after merge.

| Trigger | Workflow | Holds secrets | Does |
|---|---|---|---|
| pull request | `ci.yml` | no | pattern check, format, analyze, tests, debug APK; pgTAP on migration changes |
| push to `main` | `release.yml` | yes | see below |

`release.yml`, in order:

1. `versionCode` = GitHub Actions run number **+ 100** (monotonic, never
   reused; the offset keeps codes above builds published before the pipeline
   existed). `versionName` from `pubspec.yaml`.
2. Build a signed release AAB with the upload key from secrets.
3. Apply pending migrations to the Supabase project (schema goes forward
   before the app does).
4. Upload the AAB to the Play **internal** track via the Play Developer API
   using a service account with release permission only.
5. Tag the commit `v<versionName>+<versionCode>` and publish release notes.

Validation jobs never hold publishing or signing secrets and never mutate
cloud state. Failed checks and pull requests cannot publish.

### Secrets inventory (names only)

`ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_KEY_ALIAS`,
`ANDROID_UPLOAD_STORE_PASSWORD`, `ANDROID_UPLOAD_KEY_PASSWORD`,
`PLAY_SERVICE_ACCOUNT_JSON`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`,
`SUPABASE_PROJECT_REF`. Variables (public): `SUPABASE_URL`,
`SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_WEB_CLIENT_ID`.

### Play track policy

Internal testing during development. Closed testing for the wider group once
functionally complete. Production is a separate, later decision.

### iOS (later)

A `release-ios.yml` on a hosted macOS runner builds, signs and uploads to
TestFlight with the same structure and secret discipline. Nothing in the
Android pipeline blocks it.

## 7. Testing

- Dart: unit tests for every Notifier with fake repositories; widget tests for
  each screen state.
- Database: pgTAP suites for anonymous access, unallowlisted users, forged
  sender, session replacement, and the update-policy row.
- Pattern: `tool/check_pattern.sh`.
- Definition of done: all of the above green in CI, merged, published to the
  internal track, and docs updated in the same pull request when a decision
  changed.

## 8. Repository layout

```
README.md          docs/DESIGN.md (this)   docs/DECISIONS.md   docs/DELIVERY.md
docs/SECURITY.md   docs/ROADMAP.md         tool/check_pattern.sh
lib/  test/  supabase/{migrations,tests,functions}/  android/  docker/  .github/workflows/
```

Development tooling runs in Docker (`docker/`, `compose.yaml`); no SDKs are
installed on the workstation. `.private/` and `.orchestra/` are local-only.

## 9. Versions

| Version | Delivers | Done when |
|---|---|---|
| v0.1 | Google sign-in, allowlist gate, home screen, update policy, **full pipeline** | A merged change reaches a phone through Play with no cable |
| v0.2 | 1:1 text chat with Realtime | Two devices exchange messages; one remote update has landed — first stable version |
| v0.3 | Groups; display names | Group of three chats |
| v0.4 | Live chat list; tags and first-run name screen; settings; online and typing status | A new member picks a name and tag, and two members see each other online and typing |
| v0.5 | Design foundation: shared Realtime join/teardown; the name (SIS = Stay In Sync); the Nocturne theme, Sync S logo, launcher icon, branded header | Every existing screen wears the design and the new icon is on the phone |
| v0.6 | Unread counts; sender names in groups; last seen (switchable, server-enforced); settings sub-pages | A member sees what is unread and who said what in a group |
| v0.7 | User and group profile pages | Tapping a chat title or a sender opens their profile |
| v0.8 | Push notifications; global, per-user and per-chat notification settings | A message arrives as a notification on a closed app |
| v0.9 | Own media sheet and fast media | A photo appears at once for the sender and as a blurred preview first for receivers |
| after v0.9 | iOS | scheduled after v0.9 |
| later | E2EE | scheduled individually |

## 10. Visual design

Chosen 2026-09-23 (DECISIONS). **SIS means "Stay In Sync"**, written "SIS".
The design direction is **Nocturne**: sleek, ink violet, precise.

| Token | Light | Dark |
|---|---|---|
| background | `#F5F4FA` | `#0D0B22` |
| surface | `#FFFFFF` | `#151334` |
| surface, raised | `#ECEBF5` | `#1D1A42` |
| text | `#13112B` | `#ECEAFB` |
| muted text | `#65627F` | `#9A96C0` |
| line | `#DEDCEB` | `#25224B` |
| brand (live signals: online, typing) | `#5B4CF0` | `#7B6BFF` |
| brand, deep (gradient start) | `#2F3FD1` | `#3D4BE8` |
| danger | `#D23F57` | `#FF7B8E` |
| prism (logo, wordmark only) | `#2E36D9` → `#6D35E8` → `#B23FD0` | `#4450FF` → `#8B5CFF` → `#C45BE6` |

- **Type:** Manrope (400–800) for the interface; Sora 800 for the "SIS"
  wordmark. Both are bundled (OFL), never fetched at runtime.
- **Shapes:** bubbles and inputs 8px, with a 3px corner on the sender's side;
  buttons and cards 12px; floating buttons and sheets 16px; badges, switches
  and avatars fully round.
- **Colour use:** your own bubbles and filled buttons carry the brand
  gradient; the other side's bubbles are plain surface. The three-stop prism
  gradient is reserved for the logo and wordmark. Conversations and sign-in
  sit on a faint glow of the brand colour.
- **Logo:** the Sync S, an S made of two arrows chasing each other, gradient
  over white on an ink ground. One painter (`lib/app/brand.dart`) draws it in
  the app and renders the launcher icon (`tool/render_icons_test.dart` →
  `tool/icon/` → `flutter_launcher_icons`), so the two cannot drift.
- **Header:** logo and wordmark side by side above the chat list.
- **Avatars:** initials in circles, tinted per person within the palette's
  blue–violet range.

The code holds these values in `lib/app/theme.dart`; change them here first.

## 11. Risks

- **Play processing delay** — an uploaded build can take minutes to hours to
  appear; the pipeline reports the upload, the phone confirms delivery.
- **Google Cloud misconfiguration** (OAuth clients, SHA-1s) is the most likely
  auth failure; the app surfaces the provider's reason to make it diagnosable.
- **Backwards compatibility** — every migration is reviewed against the
  minimum supported build before merge.
- **Single maintainer account** — all cloud assets live under one Google
  account; the offline backup of the upload key is the recovery path.
