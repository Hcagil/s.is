# Development plan

Status reviewed 2026-09-19: Stage 1 remains open for remote CI and native Google sign-in evidence. Containerized ADB detected the authorized phone and installed/launched the configured debug build; do not record its identifier. Step 2 is in progress: containerized Supabase checks and 12 identity/authorization database tests passed; Flutter runtime configuration, secure session storage, native Google authentication token exchange, session activation/access states and the authorized navigation shell pass analysis, six tests and a debug APK build. The permanent Android application ID is `com.esd.sis`, version `0.1.0-dev.1+1`. Native Google/server integration and GitHub-hosted CI paths remain unverified. Direct/group messaging is not implemented. Release signing rejects missing upload-key configuration; a real upload key is backed up and the signed build-1 AAB is active on Play internal testing. Physical Play installation is blocked because the available GBox environment reports that the device is not Play Protect certified. Publishing API setup and delivery automation remain pending.

## Next implementation actions

1. Finish the foundation evidence and one-time cable/device work in D1 below; preserve the existing scaffold. Run the existing CI remotely for application, documentation-only and database changes. Local checks cannot establish GitHub-hosted workflow success.
2. Make the delivery transition D2–D4 the next infrastructure milestone, before adding direct/group messaging. Continue [implementation step 2](docs/IMPLEMENTATION.md#2-identity-and-server-authorization) alongside it: apply migrations to the configured Supabase project, complete Google OAuth, and verify server-backed member/access-loss behavior. The application ID, Supabase URL and publishable key are resolved; OAuth, device and Play access still need verification. Continue independent work when external inputs are missing.
3. After the delivery transition, resume the first incomplete application step: finish identity, then implementation steps 3–4 and the step 5 validation/handoff checklist. These cover roadmap stages 1–4; implementation step 5 is validation, not the E2EE roadmap stage. Use Play for subsequent routine phone updates.

## Delivery transition decision — 2026-09-19

Accepted direction: finish the outstanding cable-based phone setup/validation, then use Google Play Store for installation and updates, backed by an automated GitHub Actions pipeline. This supersedes the previous manual-only pilot upload and deferred publishing-automation decisions. The initial internal-test upload has occurred; D1–D4 remain incomplete and no automated publishing workflow is active.

Execution defaults: use **internal testing** for developer/device verification while the app is incomplete; use **closed testing** for the friend pilot after its functional/readiness gates. Public production remains a separate decision. Internal testing does not count as pilot acceptance. Google supports internal tests during development; see [Play testing tracks](https://support.google.com/googleplay/android-developer/answer/9845334?hl=en).

| Order / status | Work | Completion evidence |
| --- | --- | --- |
| D1 — in progress | Verify remote CI and finish one-time authorized USB/containerized ADB setup. Install/launch the current build; verify native Google account sign-in once OAuth is configured. | ADB install/launch passed. Remote CI paths and native Google/server integration remain unverified. Do not record device identifiers or credentials. |
| D2 — in progress | Complete Play Console bootstrap for `com.esd.sis`, internal tester access, Play App Signing/upload key, release signing, runtime configuration and publishing API access. Follow [setup prerequisites](docs/SETUP.md#google-play-delivery-bootstrap). | Package ownership, real upload key, Play App Signing, build-1 AAB acceptance, active internal release and tester opt-in link are confirmed. The available GBox environment is not Play Protect certified, so Play installation/login need a certified Android device. Android OAuth registration and publishing API access remain to be confirmed. |
| D3 — pending | Extend the existing Docker/GitHub Actions setup with the automated delivery contract and supported-version policy below. | A successful remote run tied to a commit and increasing build number uploads a signed AAB to the internal track; failed checks and PRs cannot publish. Supported older builds remain allowed. |
| D4 — pending | Disconnect the cable and deliver a second version through the pipeline. Verify the previous supported build still works, then choose to update it through Google Play. | Both build numbers, allowed range, workflow result, Play availability and physical install/update/login checks recorded here. Verify retained server data remains accessible; do not invent messaging checks before messaging exists. |

After D4, close the routine cable-installation phase. Keep ADB only for targeted debugging when needed; do not repeat USB setup for every feature or substitute wireless ADB/manual APK sharing for the agreed Play update channel. Physical-device checks remain required. An uploaded AAB alone does not prove that Play made it available or that the phone updated; Play processing and device update settings may delay delivery.

AI handoff rule: start at the first incomplete D item and application step above. Record concise evidence/blockers in this file, distinguish decisions from implemented/verified work, and never reset completed work. Do not reopen the Play/automation direction unless the owner changes it or a concrete blocker requires a new decision.

## Delivery stages

| Stage | Deliverable | Validation |
| --- | --- | --- |
| 1. Pre-alpha foundation | Validate Docker, Flutter scaffold, mock chat, basic CI | Analysis, tests, APK build, Android launch |
| 2. Identity | Google login, email allowlist, member directory, migrations/RLS | Unauthorized access, phone replacement, prior-session revocation |
| 3. Direct chat | Send, conversation list, history, reconnect | Multiple accounts, retry deduplication, history recovery |
| 4. Android text pilot | Groups, multiple admins, earlier history, pipeline promotion to Play closed testing | Membership/revocation, fresh installs, core flows, network interruption, store readiness |
| 5. E2EE | New encrypted messages alongside legacy history | Recovery without old phone, group key access, mixed history and client compatibility |
| 6. Media | E2EE photo/video sharing | Upload/download, playback, interruption and quota handling |
| Conditional: iOS | Email-code login, native build, platform compatibility | Begin when resources are available; iPhone and cross-platform checks |

Follow [implementation instructions](docs/IMPLEMENTATION.md) for stages 1–4. Include blocking/reporting, account deletion and verified retention/privacy disclosures before closed-test pilot distribution. Developer-only internal testing may precede those features, subject to applicable Play requirements and truthful disclosures. Delivery automation starts in D2–D4; notifications remain deferred. Public store release is separate.

## First live release and iteration

- Establish CI during the foundation, then finish D1–D4 to distribute development updates through Play internal testing. The first friend-pilot target remains a small, complete Android text pilot; E2EE, media and iOS are not prerequisites for it.
- First friend-group use means allowlisted users on managed Supabase through Google Play closed testing, after roadmap stage 4 and implementation step 5 checks. Before that distribution, resolve signing, privacy/retention and account-deletion disclosures, and the backup/restore procedure. A mock chat or successful APK build alone does not meet this gate.
- Build/sign release AABs in Docker and automate recurring Play uploads. Initial Console setup/upload is a one-time bootstrap. Once publishing is configured and enabled for internal testing, eligible updates follow the pipeline without a separate manual upload or per-build approval. Closed-test promotion is explicitly initiated after pilot gates pass; it reuses the tested artifact. Paid services and public production remain separate decisions.
- After the pilot, prioritize user feedback, fixes and stability, then separately scoped E2EE and media releases; iOS depends on macOS resources. Public Google Play production has no scheduled roadmap stage; do not equate closed testing with production or require every later feature before considering it.

## Versioning

- Target labels: foundation `0.1.0-dev.N`, text pilot `0.1.0-alpha.N`, E2EE `0.2.0-alpha.N`, media `0.3.0-alpha.N`.
- These are development milestones, not major releases. Beta requires the agreed release scope to be complete; RC requires release checks to pass; `1.0.0` requires agreed stability and compatibility criteria.
- Use immutable release tags, matching source versions and increasing platform build numbers. Define platform-specific version mapping before distribution. See [SemVer](https://semver.org/spec/v2.0.0.html).

## Supported Android versions

Decision added 2026-09-19: users may keep any version in the allowed range. Publishing a new version must not force supported users onto the newest version. Pipeline automation distributes updates; installation remains subject to the user's choice and Play update settings.

- Maintain a centrally managed policy, independent of the latest release: inclusive integer bounds `min_supported_build` and `max_supported_build`, compared with Android `versionCode`. Use `versionName` for display, never lexical version comparisons. `latest_build` is informational and must not become the minimum automatically.
- Any installed build within the range retains normal login and implemented application flows. An optional update notice must be dismissible; no blocking latest-version prompt for a supported build.
- Below the minimum, require a supported build, not an exact latest-version match. Above the maximum, show an unsupported-version state with retry/support guidance; do not automatically downgrade, uninstall or erase data. Policy-fetch errors are configuration/network failures, not proof that the installed version is unsupported.
- Before publishing a new build, validate `1 <= min_supported_build <= max_supported_build` and extend the maximum to include it after compatibility checks. Preserve the minimum and previously supported builds. Raising the minimum or narrowing the range requires a separate explicit compatibility decision with a recorded reason; it is never a side effect of a release.
- Example: allowed builds `10–14`, latest `14`: builds `10`, `12` and `14` work without a forced update. Publishing `15` normally extends the range to `10–15`; it does not change the minimum to `15`. These numbers are illustrative, not current project configuration.
- Release checks cover both inclusive boundaries, a supported older build, builds outside the range and policy-fetch failure. Confirm publishing a newer build leaves the older supported build usable. Backend/API/schema changes must remain compatible with every supported build; complete any deliberate support-window change separately before deploying an incompatible change.

## Automated pipeline contract

Current implementation: `.github/workflows/ci.yml` runs validation/debug builds only. The following delivery behavior is agreed next work, not an existing capability.

- Private GitHub repository; short-lived `x/*` branches → PR checks → squash merge into `main`.
- GitHub-hosted Ubuntu runner with the existing Docker build environment; pin tools and cache dependencies.
- On PRs and `main`: format check, analysis, relevant unit/widget tests and Android debug build. Documentation-only changes receive lightweight checks.
- When database/schema policies change: Supabase CLI migration and RLS tests against an isolated local instance. Never use pilot data in CI.
- After D2 bootstrap, an eligible application/release-configuration push to protected `main` must pass checks for that exact commit, then automatically build/sign a release AAB and upload it to Play **internal testing**. Documentation-only changes never build/sign/publish; database-only changes run their checks without triggering an app release unless client/release files also changed.
- PR jobs have no signing/publishing secrets and never deploy. Keep publication in a separate trusted job/workflow with access restricted to the selected app/testing tracks. Serialize publishing to avoid concurrent uploads/Play edits. Failed checks, absent configuration or signing errors stop publication; never fall back to debug signing.
- Keep `com.esd.sis`, configure the upload key and Play App Signing, and supply runtime configuration securely. Define an increasing Android `versionCode` above previously uploaded builds across tracks; retries must not reuse a code for a different artifact. Record commit, version/build, artifact checksum, workflow result and Play track/status without secrets. Store credentials in protected GitHub configuration, never source or artifacts.
- Validate the [supported-version policy](#supported-android-versions) before upload: the candidate must be inside the allowed range and earlier supported builds must still work. Record the range with release evidence. Do not automatically raise the minimum or equate latest release with minimum supported version. Any policy update uses the trusted delivery path, not PR validation.
- After the pilot gates pass, explicitly initiated closed-test promotion uses the already tested build; uploading/promoting is automated. Public production is excluded. Manual recovery may rerun delivery for a verified commit; never publish arbitrary PR code or silently roll back live data.
- A successful upload is distinct from Play availability and phone verification. Validate fresh Play install and an upgrade from a previous Play build without USB. Resolve applicable Console requirements rather than treating review delays as pipeline success.
- Never run managed-Supabase migrations or alter pilot user data from validation/app publishing. A supported-version policy update is permitted as scoped release configuration in the trusted delivery path only. Coordinate required backward-compatible migrations separately before shipping dependent clients. Hosted staging, macOS CI and fastlane remain deferred unless the active delivery work demonstrates a need.

## Remaining planning

Before closed-test pilot distribution, confirm retention/privacy policy, backups, supported-device checks and release identifiers. E2EE recovery is a release gate for the E2EE milestone, not a blocker for the server-readable text pilot.
