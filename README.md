# SIS

Private chat by ESD. Android now, iOS next.

- Design: [docs/DESIGN.md](docs/DESIGN.md) · Decisions: [docs/DECISIONS.md](docs/DECISIONS.md)
- Architecture rules: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · Security: [docs/SECURITY.md](docs/SECURITY.md)
- Delivery: [docs/DELIVERY.md](docs/DELIVERY.md) · Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md)

## Develop

**Every development command runs in a container. Nothing is installed on
the workstation** — not Flutter, Dart, Java, Gradle, the Android SDK, ADB or
the Supabase CLI. The images in `docker/` are the whole toolchain, and CI
builds from the same images, so a check that passes here passes there.

If something appears to need a tool that is not in an image, add it to the
image and rebuild — never install it on the host. A host installation drifts
from CI, is invisible to every other machine, and turns a reproducible build
into "works on mine".

```bash
export LOCAL_UID=$(id -u) LOCAL_GID=$(id -g)
docker compose build
docker compose run --rm flutter flutter pub get
docker compose run --rm flutter dart format --output=none --set-exit-if-changed lib test
docker compose run --rm flutter flutter analyze
docker compose run --rm flutter flutter test
tool/check_pattern.sh
docker compose run --rm supabase supabase db start
docker compose run --rm supabase supabase test db
```

Run on a device with the three public compile-time defines:

```bash
docker compose run --rm flutter flutter run \
  --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_PUBLISHABLE_KEY=… --dart-define=GOOGLE_WEB_CLIENT_ID=…
```

## Ship

Merge to `main`. The Release workflow signs the bundle, applies migrations and publishes to the Play internal track. See [docs/DELIVERY.md](docs/DELIVERY.md).
