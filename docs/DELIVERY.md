# Delivery

Source of truth: [DESIGN.md §5–6](DESIGN.md).

- On launch the app reads `app_config`.
- `installed < min_supported_build` → blocking "update required" screen with a
  Play link. Raising `min_supported_build` is a manual, recorded decision,
  used only when an older build would break against the current backend.
- Otherwise, if Play reports a newer version → **flexible** in-app update:
  dismissible banner, background download, install on tap. No repeated
  prompts.
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
| pull request | `ci.yml` | no | pattern check, format, analyze, tests, debug APK; pgTAP on migration changes |
| push to `main` | `release.yml` | yes | see below |

`release.yml`, in order:

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
cloud state. Failed checks and pull requests cannot publish.

### Secrets inventory (names only)

`ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_KEY_ALIAS`,
`ANDROID_UPLOAD_STORE_PASSWORD`, `ANDROID_UPLOAD_KEY_PASSWORD`,
`PLAY_SERVICE_ACCOUNT_JSON`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`,
`SUPABASE_PROJECT_REF`. Variables (public): `SUPABASE_URL`,
`SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_WEB_CLIENT_ID`.

### Play track policy

Internal testing during development. Closed testing for the wider group once
functionally complete. Production is a separate, later decision.

### iOS (later)

A `release-ios.yml` on a hosted macOS runner builds, signs and uploads to
TestFlight with the same structure and secret discipline. Nothing in the
Android pipeline blocks it.

## Runbook

- **Ship:** merge a pull request into `main`. Nothing else. Watch *Actions → Release*; the Play Console *Internal testing* track shows the new build within minutes. Phones receive it as a flexible in-app update.
- **versionCode** is `run_number + 100` of the Release workflow — never edit it by hand, never reuse one. `versionName` is edited in `pubspec.yaml` when a milestone changes (0.1.0 → 0.2.0).
- **Raise the minimum supported build** only when an older build would break against the current backend: a migration `update public.app_config set min_supported_build = <code> where id = 1;` with the reason in a SQL comment, plus a DECISIONS entry. Every migration must remain compatible with all builds ≥ the current minimum.
- **Register a signing fingerprint with Google:** download the certificate
  archive from Play Console → Test and release → Setup → App signing, then hash
  it locally (`deployment_cert.der` is the app's signing identity). Do not copy
  fingerprints from the page: SHA-256 and SHA-1 are shown together and are easy
  to confuse.
- **Rotate a secret:** update it in GitHub → Settings → Secrets; re-run the last Release workflow. Signing material also exists in the maintainer's offline backup.
- **Roll back:** Play Console → Internal testing → promote the previous release; then fix forward on `main`. Never rewrite `main` history.

## Push notifications (not yet live)

The database half is in place and tested: `app_private.device_tokens`,
`register_device_token`, `forget_device_token`, and
`app_private.push_targets_for_message` with the `public.push_targets` wrapper
the notifier calls on the service-role key.

`supabase/functions/notify-on-message/` is written but **not deployed**, and
the app has no push client, because both need a Firebase project that does not
exist yet. Adding `firebase_messaging` before `android/app/google-services.json`
exists would break the Android build and therefore the release workflow.

To finish it:

1. Create a Firebase project and add an Android app for `com.esd.sis`.
   Download `google-services.json` into `android/app/` — it is not a secret,
   but it is not committed either; add it to the release workflow as a secret
   file, alongside the signing key.
2. In that project, create a service account with the **Firebase Cloud
   Messaging API** role and download its JSON key.
3. `supabase secrets set FCM_SERVICE_ACCOUNT="$(cat key.json)"`, then
   `supabase functions deploy notify-on-message`.
4. Add a database webhook on `insert` into `public.messages` pointing at the
   function.
5. Add `firebase_messaging` to the app, register the token on sign-in with
   `register_device_token`, and clear it on sign-out with
   `forget_device_token`.

Step 5 is deliberately last: until steps 1-4 exist, a push client can only
fail, and the Android build cannot even compile without step 1.
