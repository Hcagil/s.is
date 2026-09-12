# Development setup

Status: configuration prepared; image build and Android SDK compatibility not yet verified.

## Prerequisites

Linux x86-64, Docker with Compose, Git, internet access, and sufficient storage for SDK/build caches. Clone this repository and run commands from its root.

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

Missing Chrome, Android Studio, or Linux desktop tooling is acceptable for Android CLI builds. Resolve Android toolchain errors before scaffolding. Additional SDK/NDK packages may be required by the generated app.

Commit generated source files and synchronize before editing from another checkout. Exclude credentials, local configuration, and build artifacts. Use macOS/Xcode for iOS builds.

Versions: Flutter 3.47.2; Android command-line tools 15859902; Java 17. [Flutter archive](https://docs.flutter.dev/install/archive), [Android tools](https://developer.android.com/studio#command-tools).
