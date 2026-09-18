# Development plan

Status: Stage 1 remains open for remote CI and device evidence. Step 2 is in progress: containerized Supabase checks and 12 identity/authorization database tests pass; Flutter runtime configuration, secure session storage, Google OAuth initiation, session activation/access states and the authorized navigation shell pass analysis, five tests and a debug APK build on 2026-09-18. Real OAuth/server integration, GitHub-hosted CI paths and physical Android launch remain unverified.

## Next implementation actions

- Finish stage 1 by running the existing CI remotely to verify application-change checks and the documentation-only skip path, then launch it on an authorized Android device. The equivalent application checks pass locally from a fresh image without the SDK volume, but only an actual GitHub-hosted run proves the workflow. Record remote-run and device evidence or the specific access blockers; preserve the existing scaffold.
- Continue [implementation step 2](docs/IMPLEMENTATION.md#2-identity-and-server-authorization) by connecting the implemented client flow to a configured Supabase project, then complete server-backed conversation/member navigation and access-loss integration checks. Request the permanent Android application ID, Supabase runtime configuration, Google OAuth setup and an authorized test device together; keep credentials and device details outside tracked files. Continue independent work while external inputs are missing, keeping unverified checks open.
- Complete implementation steps 3–4, then the step 5 validation/handoff checklist before pilot acceptance. These implementation steps cover roadmap stages 1–4 below; implementation step 5 is validation, not the E2EE roadmap stage.

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

## First live release and iteration

- Establish CI during the foundation and extend its checks as features arrive. The first live target is a small, complete Android text pilot; E2EE, media and iOS are not prerequisites for it.
- First real-user use means the allowlisted friend group using managed Supabase through Google Play closed testing, after roadmap stage 4 and implementation step 5 checks. Before distribution, resolve permanent identifiers, signing, privacy/retention and account-deletion disclosures, and the backup/restore procedure. A mock chat or successful APK build alone does not meet this gate.
- The initial pipeline automates validation and debug builds. Pilot release AAB builds/signing run in Docker; store upload is manual and requires an explicit release request. Completing a development milestone does not authorize a tag, publication or paid service.
- After the pilot, prioritize user feedback, fixes and stability, then separately scoped E2EE and media releases; iOS depends on macOS resources. Expand delivery automation when needed. Public Google Play production is a separate scope/readiness decision with no scheduled roadmap stage; do not equate closed testing with public production or require every later feature before considering it.

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
