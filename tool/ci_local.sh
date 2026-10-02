#!/usr/bin/env bash
# Replays .github/workflows/ci.yml locally, in Docker: the `android` and
# `database` jobs, same steps, same order, same commands.
# mirrors ci.yml jobs android + database; update both together.
#
# Not replayed: the iOS jobs (build, signed build; need macOS and Apple secrets,
# GitHub CI only), the classify/documentation jobs, and the "Restore Firebase
# config" secret step (android/app/google-services.json must already exist
# locally).
#
# The database job starts from zero like CI: any leftover stack and its data
# are wiped first, and the stack is stopped at the end (never `down -v`).
#
# Usage: tool/ci_local.sh [--android] [--database]   (default: both)
# Each job stops at its first failing step; both jobs always run.
set -euo pipefail
cd "$(dirname "$0")/.."

export LOCAL_UID="${LOCAL_UID:-$(id -u)}" LOCAL_GID="${LOCAL_GID:-$(id -g)}"
CI=(docker compose -f compose.yaml -f .github/compose.ci.yaml)
SKIP='imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor'

want_android=1 want_database=1
if [ $# -gt 0 ]; then
  want_android=0 want_database=0
  for arg in "$@"; do
    case "$arg" in
      --android) want_android=1 ;;
      --database) want_database=1 ;;
      *) echo "unknown flag: $arg (expected --android, --database)" >&2; exit 2 ;;
    esac
  done
fi

FAILED=
# step "name" cmd...: run one ci.yml step; on failure remember it (the job stops).
step() {
  local name=$1; shift
  echo; echo "==> $name"
  "$@" || { FAILED=$name; return 1; }
}

service_key() {
  "${CI[@]}" run --rm supabase status -o env | sed -n 's/^SECRET_KEY="\(.*\)"/\1/p'
}

layer_rules() { tool/check_pattern.sh && test/tool/check_pattern_test.sh && test/tool/whats_new_note_test.sh && test/tool/ios_release_test.sh && test/tool/workflow_pipes_test.sh && test/tool/asc_signing_test.py && test/tool/ios_signing_bootstrap_test.py; }

bundle() {
  test -f android/app/google-services.json \
    || { echo 'android/app/google-services.json missing (CI restores it from a secret)' >&2; return 1; }
  "${CI[@]}" run --rm \
    -e ANDROID_UPLOAD_KEYSTORE=/tmp/ci.jks -e ANDROID_UPLOAD_KEY_ALIAS=ci \
    -e ANDROID_UPLOAD_STORE_PASSWORD=throwaway -e ANDROID_UPLOAD_KEY_PASSWORD=throwaway \
    flutter sh -c 'keytool -genkeypair -noprompt -keystore /tmp/ci.jks -alias ci \
        -storepass throwaway -keypass throwaway -keyalg RSA -keysize 2048 -validity 1 -dname CN=ci \
      && flutter build appbundle --release'
}

edge_tests() {
  local key; key=$(service_key)
  test -n "$key"
  docker run --rm --add-host host.docker.internal:host-gateway \
    -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="$key" \
    denoland/deno:2.9.7@sha256:fa335acdf6b72106eda2cb6a8cb5f4187e7630e357467489db4b2e7352d5e432 \
    test --no-check --no-lock --allow-all test/edge/notify_on_message_test.ts
}

integration() {
  local key; key=$(service_key)
  test -n "$key"
  "${CI[@]}" run --rm -e TZ=JST-9 -e SUPABASE_TEST_SERVICE_KEY="$key" \
    flutter flutter test --run-skipped --tags integration --concurrency=1 test/integration
}

job_android() {
  step "Prepare cache directories" mkdir -p .ci-cache/pub .ci-cache/gradle || return 1
  step "Build development image" "${CI[@]}" build || return 1
  step "Resolve dependencies" "${CI[@]}" run --rm flutter flutter pub get || return 1
  step "Layer rules" layer_rules || return 1
  step "Check formatting" "${CI[@]}" run --rm flutter dart format --output=none --set-exit-if-changed lib test || return 1
  step "Analyze" "${CI[@]}" run --rm flutter flutter analyze || return 1
  step "Test" "${CI[@]}" run --rm -e TZ=JST-9 flutter flutter test || return 1
  step "Android unit tests" "${CI[@]}" run --rm flutter sh -c 'cd android && ./gradlew --no-daemon :app:testDebugUnitTest' || return 1
  step "Build release bundle" bundle
}

job_database() {
  step "Build Supabase tooling image" docker compose build supabase || return 1
  # Zero state: --no-backup drops the stack's data volumes (not the SDK ones).
  step "Wipe leftover Supabase stack" docker compose run --rm supabase stop --no-backup || return 1
  step "Start Supabase and replay migrations" docker compose run --rm supabase start -x "$SKIP" || return 1
  step "Lint database" docker compose run --rm supabase db lint --level error || return 1
  step "Test database" docker compose run --rm supabase test db || return 1
  step "Edge function tests" edge_tests || return 1
  step "Prepare cache directories" mkdir -p .ci-cache/pub .ci-cache/gradle || return 1
  step "Build development image" "${CI[@]}" build flutter || return 1
  step "Wait until Realtime delivers" "${CI[@]}" run --rm flutter flutter test --run-skipped --tags warmup test/integration/realtime_warmup_test.dart || return 1
  step "Repository integration tests" integration
}

status=0
summary=()
run_job() {
  FAILED=
  if "job_$1"; then
    summary+=("RESULT $1 PASS")
  else
    summary+=("RESULT $1 FAIL (step: $FAILED)")
    status=1
  fi
}

[ "$want_android" = 0 ] || run_job android
if [ "$want_database" = 1 ]; then
  run_job database
  docker compose run --rm supabase stop || true
fi
# Drops this worktree's compose network (no -v: volumes are kept).
docker compose down --remove-orphans >/dev/null 2>&1 || true
echo
echo "iOS build and signed build: skipped (macOS only; run in GitHub CI)"
printf '%s\n' "${summary[@]}"
exit "$status"
