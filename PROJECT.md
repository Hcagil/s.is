# Project specification

## Scope

SIS — Stay In Sync is an Android/iOS messaging application.

- Account registration and login.
- Username discovery.
- Direct and group text messaging.
- Conversation list and message history.

## Technical decisions

- Flutter/Dart mobile client; Supabase Auth, PostgreSQL, and Realtime.
- Containerized Android build environment; native macOS/Xcode for iOS.
- Validate Android first, then iOS and cross-platform behavior.
- Keep dependencies minimal and optimize measured bottlenecks.
- Use concise English documentation and application-owned text.

## Pending decisions

Encryption model, group-history visibility, administrator succession, email delivery, distribution, and license. Push notifications, media, calls, and persistent offline sending are outside the initial baseline.

## Repository policy

Publish only project documentation, source code, and necessary configuration. Exclude personal details, device inventories, hostnames, network addresses, credentials, private working notes, and personal commit email addresses.
