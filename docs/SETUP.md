# Development setup

Status: A fresh Docker image build, Android toolchain, format, analysis, tests and debug APK build were verified locally on 2026-09-18 with the current pins. Remote CI and device connection remain unverified. The image includes the SDK packages and license receipts produced by the interactive review so a fresh CI runner does not depend on a pre-populated SDK volume. See [PLAN.md](../PLAN.md) for remaining work.

## Prerequisites

Linux x86-64, existing Docker with Compose, internet access, and sufficient storage for images/volumes. Work from this checkout; existing host Git may be used but no new host development tools are to be installed. Report missing Docker access instead of installing it automatically.

## Host installation policy

Run all development commands inside Docker, including Flutter/Dart, Android SDK/ADB, Java/Gradle, Supabase CLI, dependency installation, tests, migrations and signing. Add missing tools to the relevant image/service, not the workstation. Keep source/output in the checkout and SDK/dependency caches in Docker images or volumes. Local Supabase means containerized CLI and services.

Device testing requires an authorized test phone and an explicit container connection; do not install host ADB or silently alter USB/daemon settings. Report unavailable device checks. iOS remains a later macOS/Xcode task on a separate Mac or hosted macOS runner.

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

The reviewed license receipts in `docker/android-licenses` let CI install the pinned SDK packages without automating license acceptance. Re-run the interactive review and update those receipts whenever the Android license terms or SDK pins change.

Missing Chrome, Android Studio, or Linux desktop tooling is acceptable for Android CLI builds. Resolve Android toolchain errors before scaffolding. Additional SDK/NDK packages may be required by the generated app.

Commit generated source files and synchronize before editing from another checkout. Exclude credentials, local configuration, and build artifacts. Use macOS/Xcode for iOS builds.

Versions: Flutter 3.47.2; Android command-line tools 15859902; Java 17. [Flutter archive](https://docs.flutter.dev/install/archive), [Android tools](https://developer.android.com/studio#command-tools).
