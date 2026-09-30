# Delivery

Source of truth: [DESIGN.md §5–6](DESIGN.md).

- On launch the app reads `app_config`.
- `installed < min_supported_build` → blocking "update required" screen with a
  Play link. Raising `min_supported_build` is a manual, recorded decision,
  used only when an older build would break against the current backend.
- Otherwise, if Play reports a newer version → **flexible** in-app update:
  dismissible banner, background download, install on tap. The check runs at
  launch and every time the app returns to the foreground; a dismissed banner
  stays away until then, never while the member is using the app. An update
  that finished downloading earlier is offered for install at once.
- Publishing a build never changes `min_supported_build`.
- Migrations must remain compatible with every build ≥ `min_supported_build`.

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
| pull request, push to `main` | `ci.yml` | no | pattern check, format, analyze, tests, release bundle signed with a throwaway key; pgTAP and integration tests on database changes |
| `ci.yml` passed on a push to `main` | `release.yml` | yes | see below |

`release.yml` starts only when CI has passed on the exact commit it
publishes, and skips commits that touch nothing but docs, Markdown or
`.github/`. In order:

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
cloud state. Failed checks and pull requests cannot publish — including a
merge an administrator forced past a red check, because the release waits for
CI on `main`. The `play-internal` environment, which holds the secrets, only
deploys from protected branches.

### Secrets inventory (names only)

`ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_KEY_ALIAS`,
`ANDROID_UPLOAD_STORE_PASSWORD`, `ANDROID_UPLOAD_KEY_PASSWORD`,
`PLAY_SERVICE_ACCOUNT_JSON`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`,
`SUPABASE_PROJECT_REF`, `FCM_SERVICE_ACCOUNT`, `GOOGLE_SERVICES_JSON`, `GOOGLE_SERVICE_INFO_PLIST`, `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY`, `APPLE_TEAM_ID`.
Variables (public): `SUPABASE_URL`,
`SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_WEB_CLIENT_ID`, and optionally `IOS_RELEASE`.

### Play track policy

Internal testing during development. Closed testing for the wider group once
functionally complete. Production is a separate, later decision.

### iOS

What exists: the iOS project (bundle ID `com.esd.sis`, minimum iOS 15.0) and
an `iOS build` job in `ci.yml` on a hosted macOS runner. It runs
`flutter build ios --release --no-codesign` with the same Flutter version as
the Android job (read from `docker/Dockerfile`), so iOS breakage shows up on
the pull request. It restores `ios/Runner/GoogleService-Info.plist` from the
`GOOGLE_SERVICE_INFO_PLIST` secret (the file text, stored as is, like
`GOOGLE_SERVICES_JSON`) and fails if the secret is empty.

Release: `release.yml` has a second job, `ios`, beside `publish` in the same
run, so it carries the same `versionCode` (computed once, in the `scope` job).
It calls `.github/workflows/ios-ipa.yml`, which writes
`GoogleService-Info.plist`, archives unsigned with `xcodebuild` (a signed
archive would need a development profile, which needs a registered device),
ad-hoc signs the archived app with `Runner.entitlements` so the entitlements
survive, lets the export sign it for App Store distribution, fails unless the exported app carries `aps-environment` =
`production`, and uploads the `.ipa` to TestFlight (`xcrun altool`). TestFlight
is the internal-track equivalent: the internal group `Team` receives each
build automatically. Signing is cloud-managed: the App Store Connect API key
(`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_API_KEY` = the `.p8` text, plus `APPLE_TEAM_ID`) lets Xcode
create the certificate and profiles itself; no certificate, `.p12` or match
repository exists. The `.p8` is written to the runner's temporary directory
with mode 600, never printed, and removed at the end.

`publish` (Play, migrations, function deploy, tag) does not wait on `ios`, and
an `ios` failure leaves the Play release intact: the run shows one red job,
nothing else changes. Off switch: the repository variable `IOS_RELEASE`; the
job is skipped only when it equals `off`, unset means on.

Pull requests: `ci.yml` calls the same `ios-ipa.yml` with the upload disabled
(job `iOS signed build`), so a signing problem shows on the pull request and
not after the merge. It runs only for pull requests from this repository,
never for forks or Dependabot.

### Before pushing

`tool/ci_local.sh` replays `ci.yml`'s Android checks and Database checks jobs
in Docker: same compose files, `TZ=JST-9`, the release bundle (throwaway key),
db lint, pgTAP, the Edge function tests, the Realtime warmup and the
integration tests with `--concurrency=1`. The Database job starts from zero:
it wipes any leftover local Supabase stack and its data, starts a fresh one,
replays the migrations, and stops it at the end (never `down -v`). Each job
stops at its first failing step, both always run, and the script ends with
`RESULT <job> PASS|FAIL (step: ...)` lines and a non-zero exit on failure.
The iOS build needs macOS and runs only in GitHub CI. The script and `ci.yml`
are updated together.

```bash
tool/ci_local.sh             # both jobs
tool/ci_local.sh --android   # one job
tool/ci_local.sh --database
```

## Runbook

- **Ship:** merge a pull request into `main`. Nothing else. CI runs again on `main` first (about ten minutes), then *Actions → Release* starts; the Play Console *Internal testing* track shows the new build within minutes of that. Phones receive it as a flexible in-app update.
- **A release failed:** read the failed step first. A failure before *Apply database migrations* changed nothing anywhere — re-run the failed job (*Re-run failed jobs*; it keeps the same `versionCode`). A failure at the migration or upload step is also safe to re-run: `db push` skips migrations that are already applied. A failure only at *Tag and publish release notes* means the build is already on Play — do not re-run (Play rejects the same `versionCode` twice); create the tag by hand.
- **The iOS job failed but Play succeeded:** the Play build is fine. Do not re-run the whole workflow (Play rejects the same `versionCode` twice); use *Re-run failed jobs*, which runs only `ios` again with the same build number. A build number App Store Connect has already accepted is never reused: if the upload itself got that far, ship the next merge instead.
- **Turn iOS releases off or on:** set the repository variable `IOS_RELEASE` to `off` (Settings, Secrets and variables, Actions, Variables); delete it to turn them back on. Build numbers only rise, so a gap in the TestFlight builds is normal.
- **A phone does not see a new build:** the app asks Play on launch and on
  every return to the foreground, but Play answers from the Play Store's own
  cache, which can lag a fresh internal-track release by hours. Open the Play
  Store → profile → *Manage apps & device* → *Updates available* to refresh
  it; the next time SIS comes to the foreground it offers the update. Never
  uninstall to update: that signs the phone out and drops its local cache.
- **versionCode** is `run_number + 100` of the Release workflow — never edit it by hand, never reuse one. `versionName` is edited in `pubspec.yaml` when a milestone changes (0.1.0 → 0.2.0).
- **Raise the minimum supported build** only when an older build would break against the current backend: a migration `update public.app_config set min_supported_build = <code> where id = 1;` with the reason in a SQL comment, plus a DECISIONS entry. Every migration must remain compatible with all builds ≥ the current minimum.
- **Register a signing fingerprint with Google:** download the certificate
  archive from Play Console → Test and release → Setup → App signing, then hash
  it locally (`deployment_cert.der` is the app's signing identity). Do not copy
  fingerprints from the page: SHA-256 and SHA-1 are shown together and are easy
  to confuse.
- **Rotate a secret:** update it in GitHub → Settings → Secrets; re-run the last Release workflow. Signing material also exists in the maintainer's offline backup.
- **Roll back:** Play Console → Internal testing → promote the previous release; then fix forward on `main`. Never rewrite `main` history.

## What's new notes

Every pull request body carries a line `For users: <plain sentence>`, left
empty when the change is invisible. On release, the *Store the What's new note
for this build* step joins the non-empty lines of the pull requests merged
since the previous release and stores them as the note for that build's
`versionCode` in `public.release_notes`. Nothing is stored when no line is
non-empty. The owner may edit or add rows in the Supabase dashboard table
editor: an edit made before a member's app has fetched the note is what that
member gets, and empty text delivers nothing. Members receive notes as
messages from SIS on the first start of a newer build; no push is sent
(docs/DECISIONS.md, 2026-09-30).

## Push notifications

Firebase project: `sis-app-509303` (the same Cloud project as sign-in),
Android app `com.esd.sis`, Google Analytics off. The sender signs in as the
service account `sis-push-sender`, which holds only the *Firebase Cloud
Messaging API Admin* role.

How a message becomes a notification:

1. Insert into `public.messages` fires `messages_notify`, which queues an
   HTTP call through `pg_net` carrying only the message id, to the URL in
   the Vault secret `notify_on_message_url`. No secret, no call: local and CI
   databases never send.
2. `notify-on-message` (deployed with `--no-verify-jwt`) calls
   `public.push_targets(id)` on the service-role key. That claims the message
   (once, and only while it is under two minutes old) and returns, per
   recipient, the title and body their own preview setting allows.
3. The function sends each through FCM HTTP v1.

All of it is deployed by `release.yml` after the migrations: it sets the
`FCM_SERVICE_ACCOUNT` function secret from the GitHub secret of the same
name, deploys the function, and creates the Vault URL if it is missing.
Nothing is done by hand.

`google-services.json` and `ios/Runner/GoogleService-Info.plist` are not
committed; CI and the release restore them from the `GOOGLE_SERVICES_JSON`
and `GOOGLE_SERVICE_INFO_PLIST` secrets. Local copies live in
`.private/firebase/`.
