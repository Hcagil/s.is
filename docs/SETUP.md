# Development setup

Status: A fresh Docker image build, Android toolchain, format, analysis, tests and debug APK build were verified locally on 2026-09-18 with the current pins. Remote CI and device connection remain unverified. The image includes the SDK packages and license receipts produced by the interactive review so a fresh CI runner does not depend on a pre-populated SDK volume. See [PLAN.md](../PLAN.md) for remaining work.

## Prerequisites

Linux x86-64, existing Docker with Compose, internet access, and sufficient storage for images/volumes. Work from this checkout; existing host Git may be used but no new host development tools are to be installed. Report missing Docker access instead of installing it automatically.

## Host installation policy

Run all development commands inside Docker, including Flutter/Dart, Android SDK/ADB, Java/Gradle, Supabase CLI, dependency installation, tests, migrations and signing. Add missing tools to the relevant image/service, not the workstation. Keep source/output in the checkout and SDK/dependency caches in Docker images or volumes. Local Supabase means containerized CLI and services.

Initial device setup requires an authorized test phone and an explicit container connection; do not install host ADB or silently alter USB/daemon settings. Finish this cable-based verification once, then use Google Play for routine installation/updates according to [PLAN D1–D4](../PLAN.md#delivery-transition-decision--2026-09-19). ADB remains available for targeted debugging. Report unavailable device checks. iOS remains a later macOS/Xcode task on a separate Mac or hosted macOS runner.

## Device setup completion

- Obtain the authorized phone, enable USB debugging and approve the connection on the phone. Configure only the required container/device access explicitly; `compose.yaml` currently has no device mapping. Do not add privileged mode or blanket device access as a workaround.
- Verify containerized ADB detects an authorized device, install/launch the configured current build, and test native Google account sign-in once OAuth is configured. Record success or the precise blocker in PLAN D1, without serial numbers, account emails or other personal device details.
- After Play bootstrap, install the Play version and validate the next update with the cable disconnected. Do not assume a debug-signed local installation can be upgraded by Play: package/signing compatibility must be checked first. If replacement requires uninstalling local test data, explain the impact and obtain permission before removal. Android updates require compatible signing identity; see [app signing](https://developer.android.com/studio/publish/app-signing).

## Google Play delivery bootstrap

These are pending setup tasks, not completed configuration. Gather missing owner inputs together and continue independent pipeline work while access is unavailable.

1. Confirm Play Console account/app access for `com.esd.sis`, the developer's internal tester account/opt-in access and applicable account/app requirements. Because this package was installed once outside Play with a transient debug key that is no longer available, first check whether Android developer verification requests proof of that private key. Stop and resolve package ownership explicitly if it does; do not silently change the package name. Keep tester lists and private access links outside tracked files. Internal developer testing may begin before the full text pilot; closed testing remains gated by pilot acceptance.
2. Configure Play App Signing and a protected upload key. Release builds require the four signing environment variables below and fail when any are absent; never upload a debug-signed release. Arrange secure key backup and restore access. Confirm build-time Supabase configuration and test native Google account sign-in in the Play-installed app.
3. Complete initial Console setup, required declarations and the first signed AAB upload/install. The publishing API updates an existing app and does not replace initial Console bootstrap or legal consents; see [publishing API prerequisites](https://developers.google.com/android-publisher/edits). This one-time manual step does not make recurring releases manual.
4. Enable the Google Play Developer API and configure a publishing service account with only required app/testing permissions. Store publishing credentials and upload-key material/passwords in protected GitHub configuration, available only to trusted release jobs. Never put them in the client, logs, source or retained artifacts. See [API access setup](https://developers.google.com/android-publisher/getting_started).
5. Configure the central [supported-version range](../PLAN.md#supported-android-versions), then implement and enable the [automated pipeline contract](../PLAN.md#automated-pipeline-contract). Verify a second, higher-version build reaches the internal track while the previous supported build remains usable; then voluntarily update the Play-installed app without USB. Record the allowed range, workflow/build/track results and physical checks in PLAN D2–D4; an upload alone is not delivery completion.

For closed-test promotion, finish text-pilot validation, blocking/reporting, account deletion, truthful privacy/retention and applicable store disclosures, owner-provided contact/deletion URL and backup/restore procedure. Internal distribution does not waive applicable Play requirements. Verify current Console requirements at execution time; public production is a separate decision.

## Container setup

```bash
export LOCAL_UID=$(id -u)
export LOCAL_GID=$(id -g)
docker compose build
docker compose run --rm flutter sdkmanager --licenses
docker compose run --rm flutter sdkmanager 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
docker compose run --rm flutter flutter doctor -v
```

Review Android licenses interactively. Tools run in Docker; generated source files remain in the checkout. Dependency caches persist in volumes. Avoid `down -v` during routine shutdown.

The reviewed license receipts in `docker/android-licenses` let CI install the pinned SDK packages without automating license acceptance. Android platforms 35/36, build-tools 36.0.0, NDK 28.2.13676358 and CMake 3.22.1 are included because the current Flutter/plugin build requires them. Re-run the interactive review and update those receipts whenever the Android license terms or SDK pins change.

## Local Supabase

The pinned Supabase CLI and Docker CLI run in the `supabase` tooling container. It uses the existing host Docker daemon only to manage the local development services; do not expose their ports beyond the development machine.

```bash
docker compose build supabase
docker compose run --rm supabase db start
docker compose run --rm supabase db reset
docker compose run --rm supabase db lint --level error
docker compose run --rm supabase test db
docker compose run --rm supabase stop
```

The current pins are Supabase CLI 2.117.0, Node 22.20.0 and Docker CLI 29.8.0. Update them deliberately and replay the migrations/tests before committing a pin change.

## App runtime configuration

Supply client configuration at build/run time; do not commit a values file. `GOOGLE_WEB_CLIENT_ID` is the Web OAuth client ID also configured for the Supabase Google provider. Register an Android OAuth client for package `com.esd.sis` and each signing certificate SHA-1 used to test or distribute the app.

```bash
docker compose run --rm flutter flutter run \
  --dart-define=SUPABASE_URL=https://PROJECT_REF.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=VALUE \
  --dart-define=GOOGLE_WEB_CLIENT_ID=VALUE
```

The publishable client key may be embedded in the app; never provide a service-role key. Auth sessions are persisted with platform secure storage.

Release AAB builds additionally require `ANDROID_UPLOAD_KEYSTORE`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_STORE_PASSWORD`, and `ANDROID_UPLOAD_KEY_PASSWORD`. Mount the protected upload keystore into the container and set `ANDROID_UPLOAD_KEYSTORE` to that container path. Never place the keystore or passwords in source control or command output.

Missing Chrome, Android Studio, or Linux desktop tooling is acceptable for Android CLI builds. Resolve Android toolchain errors before scaffolding. Additional SDK/NDK packages may be required by the generated app.

Commit generated source files and synchronize before editing from another checkout. Exclude credentials, local configuration, and build artifacts. Use macOS/Xcode for iOS builds.

Versions: Flutter 3.47.2; Android command-line tools 15859902; Java 17. [Flutter archive](https://docs.flutter.dev/install/archive), [Android tools](https://developer.android.com/studio#command-tools).
