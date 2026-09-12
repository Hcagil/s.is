# Android text pilot: AI execution contract

## Assignment and reading order

Deliver the working Android text pilot, following steps 1–5 below consecutively. A mock screen or scaffold alone is not completion. Do not implement E2EE, media, iOS, push notifications, offline queues, read receipts, typing indicators, message editing/deletion, fastlane or hosted staging.

Read `AGENTS.md` once, then this file. Consult [PROJECT.md](../PROJECT.md) for scope, [ARCHITECTURE.md](../ARCHITECTURE.md) for design, [PLAN.md](../PLAN.md) for releases, and [SETUP.md](SETUP.md) for Docker commands. Read only the relevant section and directly related implementation files. Do not scan the repository, dump lockfiles or repeatedly summarize these documents.

Preserve unrelated edits and existing documentation/configuration. Do not regenerate an existing app. For an empty app, scaffold in a temporary directory and copy only required Android/Flutter files into the repository root. Use project name `sis`, display name `SIS` and English text. Start a new scaffold at `0.1.0-dev.1+1`; never reset an existing version/build number.

## Fixed implementation defaults

- The workstation must not receive new development-tool installations. Run scaffolding, dependency resolution, formatting, analysis, tests, migrations, APK/AAB builds and signing inside Docker. This includes Flutter/Dart, Java/Gradle, Android SDK/ADB, Supabase CLI and any required Node/Ruby tools; do not install them on the host or alter host PATH/package configuration.
- Use the existing Docker/Compose installation. If unavailable or container/device access fails, report the exact prerequisite and continue independent work; do not install host tools, change daemon/USB rules or use privileged containers as an automatic workaround. Document any required Docker-socket/device mapping explicitly.
- Source and deliverable files may remain in the checkout; SDKs and dependency/build caches belong in images or Docker volumes. Run Supabase CLI in a tooling container and its local services in containers. Do not reinterpret "local Supabase" or "manual signing" as host-tool installation.
- Use Flutter Material 3, system theme, built-in navigation/state primitives and a concrete data layer outside widgets. No additional routing/state-management framework, generic repository framework or future-feature stubs.
- Use `supabase_flutter` and its Google OAuth external-browser flow. Add packages only for required capabilities absent from the current stack; use OS-backed secure session storage. Keep mocks limited to tests and the initial scaffold.
- Use managed Supabase for the pilot and Supabase CLI/local Docker for development and CI. All schema, grants, RLS and database functions must be reproducible migrations; no dashboard-only schema changes.
- Runtime configuration: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `AUTH_REDIRECT_URI`, supplied outside source control. No client service-role key, OAuth secret, signing key or credential logging.
- Missing runtime configuration shows a setup-required state; the pilot must never fall back to mock login or fabricated messages.
- Missing external inputs: request the permanent Android application ID, project configuration, Google OAuth setup and a test device in one concise list. Use `com.example.sis` only for local scaffold/debug builds; do not publish it. Never invent credentials or disable access checks to unblock testing.
- Continue independent local work while inputs are missing. State precisely which integration/device checks remain blocked; do not mark them passed. Publishing, paid services and destructive live-data changes are outside this implementation assignment.

## 1. Environment and initial CI

Validate the existing Docker/Compose configuration using [SETUP.md](SETUP.md). Fix only demonstrated incompatibilities; record changed tool pins and their reason. Complete Android license review interactively; do not automate acceptance. Missing desktop/web tooling does not block Android CLI work.

Scaffold an Android-only Flutter app and a temporary in-memory chat screen. Add `.github/workflows/ci.yml`: PRs and pushes to `main`, GitHub-hosted Ubuntu, the existing Docker environment, pinned tool/action versions and dependency caches. Run format check, analysis, tests and debug APK build. Documentation-only changes must skip the Android build while returning a successful lightweight check. Cancel superseded PR runs; no signing/deployment secrets or cloud mutations in CI.

## 2. Identity and server authorization

- Screens: Google login, access-denied state, conversations, member directory, chat, group details and settings. Use names/initials; do not expose member emails or import the phone address book. Provide loading, empty, error and retry states.
- Directory contains registered, currently allowed users except self. No username registration, friend requests or email/password login. Display names are not authorization identifiers.
- Check the allowlist against the server-verified Auth email, normalized by trimming and lowercasing; do not use editable user metadata. Only dashboard administrators may change the allowlist.
- Every application read, write, RPC and Realtime delivery must require allowed account access and the current active session. A hidden button, JWT refresh revocation or client-side logout alone is insufficient.
- Implement single-active-session enforcement on the free plan. Verify JWT `session_id` belongs to the caller in `auth.sessions`; atomically replace the active session only with a newer server-created session. Preserve the newest-session watermark so old tokens/refreshes cannot reactivate themselves. Deny the replaced session even before its JWT expires; clear its UI when rejection is observed.
- Keep allowlist/session authority in private tables/functions, inaccessible for client mutation. Restrict privileged functions, validate caller/target permissions and set a fixed safe search path. Realtime subscriptions never replace RLS.

The built-in Supabase single-session setting requires a paid plan and is not this implementation. See [session semantics](https://supabase.com/docs/guides/auth/sessions).

## 3. Conversations and text messages

Use these minimum data contracts; add only indexes, constraints and private support records needed to enforce them:

| Record | Required behavior |
| --- | --- |
| `profiles` | Auth user UUID and display name; no publicly readable email. |
| `conversations` | UUID, direct/group type, group name and server timestamps. At most one direct conversation per unordered pair, including concurrent creation. |
| `conversation_members` | Unique conversation/user pair, member/admin role and server join time. Direct membership is fixed; group operations are atomic. |
| `messages` | Stable client-generated UUID, conversation UUID, nullable sender UUID, server timestamp, `format_version=1`, `kind=text`, and body. Null sender is reserved for account deletion. |

- Direct creation opens the existing conversation if the pair already exists. Only the authenticated sender may send; derive sender identity server-side. Users cannot mutate roles or membership through unrestricted table writes.
- Trim submitted text; accept 1–4,000 Unicode code points and enforce the limit server-side. Group names are trimmed and limited to 1–80 code points. No HTML interpretation.
- Send states: sending, sent after confirmed persistence, failed with manual retry. Retrying an ambiguous network result reuses the original message UUID/body; return the existing message only when sender, conversation and body match, otherwise reject the conflict. Never duplicate or overwrite a message.
- History pages contain 50 messages, ordered by server timestamp then UUID, using a cursor. Merge fetched/Realtime messages by UUID. Unsupported message formats render `Unsupported message`; do not interpret them as plaintext.
- Initial load, app resume and reconnection reconcile history from the server. Realtime INSERT/UPDATE events are hints; do not rely on receiving every event or expose unfiltered DELETE payloads. Clear protected views after access loss.
- No persistent message cache/outbox. Keep unsent text in memory during the current screen/session; block offline sending with an explicit status. Replacement-phone login reloads retained, authorized history without a recovery code.
- Conversation list sorts by latest retained message, then conversation ID; empty conversations use creation time. Use server queries/functions for summaries instead of downloading every message.

## 4. Groups and account lifecycle

- Any allowed user may create a group and becomes its first admin. Admins add/remove members and promote/demote admins; ordinary members may only leave. Adding a member requires an allowed registered account and grants all retained group history.
- An active member has an existing account and enabled allowlist entry; being online is not required. Direct conversations with a deleted or disallowed recipient are read-only; account deletion is the sole exception to fixed direct membership.
- If an operation leaves active members but no admin, promote the oldest remaining active member by `joined_at`, then user UUID. Apply this atomically to departure, demotion, account deletion and allowlist revocation. Delete the group and its messages when no active members remain.
- Revocation denies server access immediately and removes group membership. Reallowlisting does not silently restore membership. Already downloaded information cannot be remotely erased.
- Blocking is per user: either direction blocks new direct messages and direct-conversation creation; existing history remains visible. Blocking does not hide shared-group messages; users may leave or report the group participant. Provide unblock in settings.
- Reporting accepts a user or accessible message plus a reason; validate access server-side. Reports are visible only to the reporter and dashboard operator. No separate admin application.
- Account deletion requires an explicit confirmation. Deny access first; remove Auth identity, profile, allowlist entry, sessions, membership and personally identifying support records. Preserve authored message bodies with `sender_id=NULL` and `Deleted user`; retain no hidden sender-ID mapping. Use an idempotent server operation; retry must finish partial cleanup without restoring access.
- Message bodies may still contain personal data. Prepare truthful privacy/retention text and an external account-deletion request path; owner-supplied contact/URL and policy verification are required before Play distribution. Do not claim complete anonymization or finalized compliance.

## 5. Validation and handoff

Run each affected test first; after the final changes run the full narrow pilot checks once:

- Flutter: `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`, `flutter build apk --debug`, all in Docker. Include widget coverage for empty input, send failure/retry and access-loss UI.
- Database: clean local migration replay, `supabase db lint`, `supabase test db`, all through the containerized CLI. Cover anonymous/unallowlisted access, forged sender/admin operations, concurrent direct creation, membership changes, last-admin succession and account deletion with retained unlinked messages.
- Two accounts/two sessions: duplicate retry after a lost response, paginated history/reconnect, new-member history, revoked membership, old-session REST/RPC/Realtime denial and replacement-phone history restoration. Retrying an old session must not reclaim access.
- Physical Android: Google login/callback, direct/group exchange, background/resume and network interruption. Use containerized ADB with an explicitly configured connection, not host ADB installation. Installing the APK requires an authorized test phone; otherwise report device checks as unverified. An APK build or mocked login is not device/integration verification.
- CI: verify app-change checks, the documentation-only path, database-change checks and absence of deployment actions. Report a remote CI run only if one actually ran.

At functional pilot acceptance set `0.1.0-alpha.1` and an unused increasing build number. Document manual signing/AAB upload steps and required inputs; never create a release/tag, upload to Play or buy a service solely because this checklist finished. AAB production readiness also requires the permanent ID, policy/retention review and backup/restore procedure; list missing prerequisites separately from code completion.

iOS is deferred and requires a macOS/Xcode build environment; Linux Docker does not replace it. Plan a separate Mac/hosted macOS runner at that stage rather than installing iOS tooling on this workstation.

Keep progress in [PLAN.md](../PLAN.md) as one short status per completed step, including evidence or blockers. Do not add a second diary or copy this contract into other files. Review the diff; finish in fewer than 10 lines with changed files, checks actually run and remaining blockers. If this task is resumed, start at the first incomplete step rather than repeating completed work.
