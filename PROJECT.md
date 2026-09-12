# Project specification

## Scope

SIS — Stay In Sync is an Android/iOS messaging application for a closed friend group of up to 20 people. Prioritize a small, usable Android pre-alpha.

- Google login on Android; email access allowlist managed through the Supabase dashboard.
- In-app member directory and direct conversation initiation.
- Direct and group text messaging.
- Anyone may create groups; multiple administrators manage membership. New members see earlier history.
- If the last administrator leaves, deletes their account or loses app access, promote the oldest remaining active member; delete empty groups.
- Conversation list, history, send status, and retry while the app remains open.
- One active phone per account; login on a replacement phone restores server-held history without a recovery code.
- No automatic history expiration. Account deletion removes the sender's identity link but retains their messages as `Deleted user`; message text is not guaranteed anonymous. Validate the retention policy before store distribution.

## Technical decisions

- Flutter/Dart mobile client; managed Supabase Auth, PostgreSQL, and Realtime.
- Docker for all development/tooling, including Android builds, tests, migrations and signing; no new workstation tool installations. iOS later requires a separate Mac/hosted macOS environment with Xcode.
- Validate Android first; iOS follows when build/test resources are available, using email-code login only.
- Start within free service limits; paid services require a separate decision. Store account costs are separate.
- Private GitHub repository and GitHub Actions; manually build/upload pilot releases to Google Play closed testing.
- Initial messages are not end-to-end encrypted; authorized server operators can access content. Require transport and storage protection.
- Keep dependencies minimal and optimize measured bottlenecks.
- Use concise English documentation and application-owned text.

## Later releases

E2EE precedes photo/video sharing. E2EE applies only to messages sent after the transition; earlier history stays accessible and distinguishable. Recovery must not require access to or approval from the old phone; the secure recovery method remains unresolved.

Push notifications and publishing automation are deferred. Calls, persistent offline sending, read receipts, typing indicators, message editing/deletion, and general file sharing remain outside the first pilot.

## Pending decisions

Before the relevant release: retained-message policy, backup/restore operations, E2EE recovery, iOS email delivery, and media limits. No open-source license is selected; source remains for private use. The initial pilot execution contract is in [implementation instructions](docs/IMPLEMENTATION.md).

## Repository policy

Publish only project documentation, source code, and necessary configuration. Exclude personal details, device inventories, hostnames, network addresses, credentials, private working notes, and personal commit email addresses.
