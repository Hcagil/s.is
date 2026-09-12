# Development plan

Status: planning; Docker configuration prepared but unverified. No application release exists yet.

## Delivery stages

| Stage | Deliverable | Validation |
| --- | --- | --- |
| 1. Pre-alpha foundation | Validate Docker, Flutter scaffold, mock chat, basic CI | Analysis, tests, APK build, Android launch |
| 2. Identity | Google login, email allowlist, member directory, migrations/RLS | Unauthorized access, phone replacement, prior-session revocation |
| 3. Direct chat | Send, conversation list, history, reconnect | Multiple accounts, retry deduplication, history recovery |
| 4. Android text pilot | Groups, multiple admins, earlier history, manual Play closed-test upload | Membership/revocation, fresh installs, core flows, network interruption, store readiness |
| 5. E2EE | New encrypted messages alongside legacy history | Recovery without old phone, group key access, mixed history and client compatibility |
| 6. Media | E2EE photo/video sharing | Upload/download, playback, interruption and quota handling |
| Conditional: iOS | Email-code login, native build, platform compatibility | Begin when resources are available; iPhone and cross-platform checks |

Follow [implementation instructions](docs/IMPLEMENTATION.md) for stages 1–4. Include blocking/reporting, account deletion and verified retention/privacy disclosures before store distribution. Add notifications and richer CI/CD after the small text pilot as needed; public store release is separate.

## Versioning

- Target labels: foundation `0.1.0-dev.N`, text pilot `0.1.0-alpha.N`, E2EE `0.2.0-alpha.N`, media `0.3.0-alpha.N`.
- These are development milestones, not major releases. Beta requires the agreed release scope to be complete; RC requires release checks to pass; `1.0.0` requires agreed stability and compatibility criteria.
- Use immutable release tags, matching source versions and increasing platform build numbers. Define platform-specific version mapping before distribution. See [SemVer](https://semver.org/spec/v2.0.0.html).

## Initial pipeline

- Private GitHub repository; short-lived `x/*` branches → PR checks → squash merge into `main`.
- GitHub-hosted Ubuntu runner with the existing Docker build environment; pin tools and cache dependencies.
- On PRs and `main`: format check, analysis, relevant unit/widget tests and Android debug build. Documentation-only changes receive lightweight checks.
- When database/schema policies change: Supabase CLI migration and RLS tests against an isolated local instance. Never use pilot data in CI.
- Manually build/sign the release AAB and upload to Google Play closed testing; the initial CI needs no deployment or signing credentials.
- Defer fastlane, automated publishing, hosted staging and macOS CI. Future publishing remains manually initiated; never deploy from a PR.

## Remaining planning

Before store distribution, confirm retention/privacy policy, backups, supported-device checks and release identifiers. E2EE recovery is a release gate for the E2EE milestone, not a blocker for the server-readable text pilot.
