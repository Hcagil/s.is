# Architecture

Status: foundation and partial identity/authorization implemented; messaging remains pending. See [PLAN.md](PLAN.md) for verified progress and the next delivery milestone.

- **Client:** Flutter/Dart; separate screens from data operations.
- **Backend:** Managed Supabase Auth, PostgreSQL, Realtime, and server-side policies/functions.
- **Tables:** profiles, conversations, conversation_members, messages.
- **Identity:** Enforce the email allowlist server-side. Enforce one active phone and revoke the previous phone's server access on replacement.
- **Message flow:** authenticate → verify app access and membership → persist → update authorized connected clients. Push notifications are deferred.
- **Reliability:** stable IDs, deduplicated retries, paginated history, indexed queries, reconnect recovery. Persistence does not imply a read receipt.
- **Authorization:** RLS enforces membership, sender identity, and roles; group operations are atomic. No service secrets in the client or sensitive logs.
- **Initial history:** Store server-readable messages with transport/storage protection and RLS. Authorized login restores retained history; no separate recovery key or passkey is required.
- **E2EE readiness:** Version message payloads independently of app releases. Keep storage and sending outside screen code; do not build unused encryption abstractions in the first pilot.
- **E2EE transition:** Encrypt only new messages after cutover; retain readable legacy history with a clear distinction. Validate secure recovery without the old phone before releasing E2EE. Login-only recovery is not promised for that phase.
- **Groups:** Multiple administrators; new members receive earlier history. Membership removal revokes future server access but cannot erase previously downloaded content. When no administrator remains, promote the oldest active member by membership join time, then user ID to break ties; delete groups with no active members.
- **Account deletion:** Remove the Auth account, profile, session/access records and membership; retain messages with a null sender and the label `Deleted user`. Do not retain a hidden sender mapping or claim message bodies are anonymous. Validate retention before closed-test pilot distribution.

## Development

Use the Docker environment for Android builds and tests. Pin tool versions and persist caches in volumes. Validate on physical devices. Use macOS/Xcode for iOS; Android success does not establish iOS correctness. See [setup](docs/SETUP.md).

Track schema and policy changes with Supabase CLI migrations. Use local/ephemeral Supabase for development and CI, and a managed project for the friend pilot. Add a separate hosted test environment when needed. Test upgrades and preserve compatibility with every build in the centrally managed [supported-version range](PLAN.md#supported-android-versions). Latest release and minimum supported build are independent; supported users may stay on older versions. No automatic destructive rollback.

## References

- [Flutter Android](https://docs.flutter.dev/platform-integration/android/setup), [Flutter iOS](https://docs.flutter.dev/platform-integration/ios/setup)
- [Supabase Flutter](https://supabase.com/docs/guides/getting-started/quickstarts/flutter), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [Realtime](https://supabase.com/docs/guides/realtime/postgres-changes)
