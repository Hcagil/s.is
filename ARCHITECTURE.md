# Architecture

Status: design approved; implementation pending.

- **Client:** Flutter/Dart; separate screens from data operations.
- **Backend:** Supabase Auth, PostgreSQL, Realtime, and server-side policies/functions.
- **Tables:** profiles, conversations, conversation_members, messages.
- **Message flow:** authenticate → verify membership → persist → notify authorized clients.
- **Reliability:** stable IDs, deduplicated retries, paginated history, indexed queries, reconnect recovery. Persistence does not imply a read receipt.
- **Authorization:** RLS enforces membership, sender identity, and roles; group operations are atomic. No service secrets in the client or sensitive logs.
- **Encryption:** unresolved; transport encryption and RLS do not provide end-to-end encryption.
- **Groups:** membership roles, history visibility, and administrator succession must be finalized before implementation.

## Development

Use the Docker environment for Android builds and tests. Pin tool versions and persist caches in volumes. Validate on physical devices. Use macOS/Xcode for iOS; Android success does not establish iOS correctness. See [setup](docs/SETUP.md).

## References

- [Flutter Android](https://docs.flutter.dev/platform-integration/android/setup), [Flutter iOS](https://docs.flutter.dev/platform-integration/ios/setup)
- [Supabase Flutter](https://supabase.com/docs/guides/getting-started/quickstarts/flutter), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [Realtime](https://supabase.com/docs/guides/realtime/postgres-changes)
