#!/usr/bin/env bash
# Runs, locally in the project's Docker images, the same checks
# .github/workflows/ci.yml runs: pattern, format, analyze, unit tests
# (TZ=JST-9), a debug build (not the signed release bundle), and -- unless
# --no-db -- db lint, pgTAP and the integration folder with the warmup probe.
# Stops at the first failure. Never touches the running local Supabase stack
# destructively: it reuses it if one is already up (`supabase start` is
# idempotent) and never runs `db reset` or `down -v` unless you ask for it.
#
# Usage: tool/ci_local.sh [--no-db] [--db-only] [--reset-db]
#   --no-db    skip database checks (pattern/format/analyze/test/build only)
#   --db-only  skip the app checks, run only the database checks
#   --reset-db replay migrations onto a clean database first (supabase db
#              reset) instead of reusing whatever is already running
set -euo pipefail
cd "$(dirname "$0")/.."

export LOCAL_UID="${LOCAL_UID:-$(id -u)}" LOCAL_GID="${LOCAL_GID:-$(id -g)}"
COMPOSE=(docker compose -f compose.yaml -f .github/compose.ci.yaml)
# Services nothing here talks to (see .github/workflows/ci.yml for why):
# keeps a laptop-run mirroring what CI now excludes.
SUPABASE_EXCLUDE=imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor

run_app=1
run_db=1
reset_db=0
for arg in "$@"; do
  case "$arg" in
    --no-db) run_db=0 ;;
    --db-only) run_app=0 ;;
    --reset-db) reset_db=1 ;;
    *)
      echo "unknown flag: $arg (expected --no-db, --db-only, --reset-db)" >&2
      exit 2
      ;;
  esac
done

step() { echo; echo "==> $*"; }
verdict_fail() {
  echo "FAILED: $1" >&2
  exit 1
}

mkdir -p .ci-cache/pub .ci-cache/gradle

build_dev_image() {
  step "Build development image"
  "${COMPOSE[@]}" build flutter || verdict_fail "Build development image"
}

if [ "$run_app" = 1 ]; then
  build_dev_image

  step "Resolve dependencies"
  "${COMPOSE[@]}" run --rm flutter flutter pub get || verdict_fail "Resolve dependencies"

  step "Layer rules"
  tool/check_pattern.sh || verdict_fail "Layer rules"
  test/tool/check_pattern_test.sh || verdict_fail "Layer rules (self-test)"

  step "Check formatting"
  "${COMPOSE[@]}" run --rm flutter dart format --output=none --set-exit-if-changed lib test \
    || verdict_fail "Check formatting"

  step "Analyze"
  "${COMPOSE[@]}" run --rm flutter flutter analyze || verdict_fail "Analyze"

  # TZ=JST-9 as in CI: a non-UTC zone catches a test that only passes because
  # it never converts to local time.
  step "Test (TZ=JST-9)"
  "${COMPOSE[@]}" run --rm -e TZ=JST-9 flutter flutter test || verdict_fail "Test"

  # Debug, not the signed release bundle: this script never sees the
  # signing/Play secrets that only exist in ci.yml's Android checks job.
  step "Build debug APK"
  "${COMPOSE[@]}" run --rm flutter flutter build apk --debug || verdict_fail "Build debug APK"
fi

if [ "$run_db" = 1 ]; then
  step "Build Supabase tooling image"
  docker compose build supabase || verdict_fail "Build Supabase tooling image"

  if [ "$reset_db" = 1 ]; then
    step "Reset database (--reset-db given)"
    docker compose run --rm supabase db reset || verdict_fail "Reset database"
  fi

  # Idempotent: starts what isn't running yet and replays pending migrations;
  # does nothing destructive to an already-running stack.
  step "Start Supabase and replay migrations"
  docker compose run --rm supabase start -x "$SUPABASE_EXCLUDE" || verdict_fail "Start Supabase"

  step "Lint database"
  docker compose run --rm supabase db lint --level error || verdict_fail "Lint database"

  step "Test database (pgTAP)"
  docker compose run --rm supabase test db || verdict_fail "Test database"

  [ "$run_app" = 1 ] || build_dev_image

  step "Wait until Realtime delivers"
  "${COMPOSE[@]}" run --rm flutter flutter test --run-skipped --tags warmup \
    test/integration/realtime_warmup_test.dart || verdict_fail "Wait until Realtime delivers"

  step "Repository integration tests"
  SUPABASE_TEST_SERVICE_KEY=$(docker compose run --rm supabase status -o env \
    | sed -n 's/^SECRET_KEY="\(.*\)"/\1/p')
  [ -n "$SUPABASE_TEST_SERVICE_KEY" ] \
    || verdict_fail "could not read the local stack's service key"
  "${COMPOSE[@]}" run --rm -e TZ=JST-9 -e SUPABASE_TEST_SERVICE_KEY="$SUPABASE_TEST_SERVICE_KEY" \
    flutter flutter test --run-skipped --tags integration --concurrency=1 test/integration \
    || verdict_fail "Repository integration tests"
fi

echo
echo "PASSED: all requested checks passed."
