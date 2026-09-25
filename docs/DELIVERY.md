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
`SUPABASE_PROJECT_REF`, `FCM_SERVICE_ACCOUNT`, `GOOGLE_SERVICES_JSON`.
Variables (public): `SUPABASE_URL`,
`SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_WEB_CLIENT_ID`.

### Play track policy

Internal testing during development. Closed testing for the wider group once
functionally complete. Production is a separate, later decision.

### iOS (later)

A `release-ios.yml` on a hosted macOS runner builds, signs and uploads to
TestFlight with the same structure and secret discipline. Nothing in the
Android pipeline blocks it.

### Before pushing

`tool/ci_local.sh` runs the same checks as `ci.yml`'s Android and Database
checks jobs, in the project's Docker images, stopping at the first failure:

```bash
tool/ci_local.sh            # everything: pattern, format, analyze, unit
                             # tests, a debug build, db lint, pgTAP, and the
                             # integration folder
tool/ci_local.sh --no-db    # skip the database part (no local Supabase
                             # stack needed) -- measured 3:43
tool/ci_local.sh --db-only  # only the database part -- measured 10:12,
                             # 9:47 of it the integration tests; not fast,
                             # run it before pushing a data/ or db/ change
tool/ci_local.sh --reset-db # replay migrations onto a clean database first,
                             # instead of reusing whatever is already running
```

It reuses an already-running local Supabase stack (`supabase start` is
idempotent) rather than resetting it, and never runs `docker compose down
-v`. The database part needs `docker compose run --rm supabase start` to
have been run at least once (or pass `--reset-db`).

## Runbook

- **Ship:** merge a pull request into `main`. Nothing else. CI runs again on `main` first (about ten minutes), then *Actions → Release* starts; the Play Console *Internal testing* track shows the new build within minutes of that. Phones receive it as a flexible in-app update.
- **A release failed:** read the failed step first. A failure before *Apply database migrations* changed nothing anywhere — re-run the failed job (*Re-run failed jobs*; it keeps the same `versionCode`). A failure at the migration or upload step is also safe to re-run: `db push` skips migrations that are already applied. A failure only at *Tag and publish release notes* means the build is already on Play — do not re-run (Play rejects the same `versionCode` twice); create the tag by hand.
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

`google-services.json` is not committed; CI and the release restore it from
the `GOOGLE_SERVICES_JSON` secret. Local copies live in `.private/firebase/`.
