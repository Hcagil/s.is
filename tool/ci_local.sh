#!/usr/bin/env bash
# Replays .github/workflows/ci.yml locally, in Docker: the `android` and
# `database` jobs, same steps, same order, same commands.
# mirrors ci.yml jobs android + database; update both together.
#
# Not replayed: the iOS jobs (build, signed build; need macOS and Apple secrets,
# GitHub CI only), the classify/documentation jobs, and the "Restore Firebase
# config" secret step (android/app/google-services.json is copied from the main
# checkout's .private/firebase/ when missing), and the runner-only "Install Pillow"
# step (a venv for the SIS Bot tool test; this machine has its own Python).
# Local only: "Wipe leftover Supabase stack" and "Private functions and tests".
# SIS_PRIVATE_OPS_DIR=<dir with private-sql/ and private-tests/>: read the private pack from there instead of the main checkout's .private/ops (for a branch whose public code needs a newer pack).
#
# The database job starts from zero like CI: any leftover stack and its data
# are wiped first, and the stack is stopped at the end (never `down -v`).
#
# Usage: tool/ci_local.sh [--android] [--database]   (default: both)
# Each job stops at its first failing step; both jobs always run.
set -euo pipefail
cd "$(dirname "$0")/.."
# Gradle keys cached artifacts by repository, so a fresh per-worktree cache re-downloads from Maven Central (HTTP 429). Share gradle and m2 across worktrees through one host dir; pub stays per worktree. Created as the user before any docker call so Docker never makes them root-owned.
prepare_ci_cache() {
  local shared="${SIS_CI_CACHE:-$HOME/.cache/sis-ci}" d t
  mkdir -p .ci-cache/pub "$shared/gradle" "$shared/m2"
  [ -w .ci-cache/pub ] || docker run --rm -v "$PWD/.ci-cache/pub:/c" alpine chown -R "$(id -u):$(id -g)" /c
  for d in gradle m2; do
    t=.ci-cache/$d
    [ -L "$t" ] && continue
    if [ -e "$t" ]; then
      [ -w "$t" ] || docker run --rm -v "$PWD/$t:/c" alpine chown -R "$(id -u):$(id -g)" /c
      if [ -n "$(ls -A "$t")" ]; then echo "ci_local: $t has files and is not the shared cache link; left as is" >&2; continue; fi
      rmdir "$t"
    fi
    ln -s "$shared/$d" "$t"
  done
}
prepare_ci_cache

# Fresh worktrees lack the git-ignored Firebase config: take the owner's copy from the main checkout.
if [ ! -f android/app/google-services.json ]; then
  main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  src="$main/.private/firebase/google-services.json"
  if [ -f "$src" ]; then
    cp "$src" android/app/google-services.json
    echo 'copied android/app/google-services.json from the main checkout (.private/firebase)'
  fi
fi

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

layer_rules() { tool/check_pattern.sh && tool/check_release_clean.sh && test/tool/check_pattern_test.sh && test/tool/whats_new_note_test.sh && test/tool/ios_release_test.sh && test/tool/workflow_pipes_test.sh && test/tool/asc_signing_test.py && test/tool/ios_signing_bootstrap_test.py && test/tool/asc_tester_test.py && test/tool/vault_names_test.py && test/tool/admin_apple_workflow_test.sh && test/tool/sis_bot_watch_test.sh && test/tool/sis_bot_length_test.sh && test/tool/check_pr_body_test.py && test/tool/release_scope_test.sh && test/tool/check_release_clean_test.sh && test/tool/sis_test_send_test.sh && test/tool/private_install_db_test.sh && test/tool/ci_local_cache_test.sh && test/tool/ci_test_lists_test.sh; }

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
    ghcr.io/denoland/deno:2.9.7@sha256:fa335acdf6b72106eda2cb6a8cb5f4187e7630e357467489db4b2e7352d5e432 \
    test --no-check --no-lock --allow-all test/edge/
}

integration() {
  local rc=0 key; key=$(service_key)
  test -n "$key"
  # Rows no client can write (app_private), for staff_registry_repository_test.dart.
  docker exec -i supabase_db_s.is psql -U postgres -v ON_ERROR_STOP=1 -qAt < test/integration/fixtures/staff_registry.sql >/dev/null
  # Owner, bridge and their rows, for admin_view_repository_test.dart.
  docker exec -i supabase_db_s.is psql -U postgres -v ON_ERROR_STOP=1 -qAt < test/integration/fixtures/admin_view.sql >/dev/null
  "${CI[@]}" run --rm -e TZ=JST-9 -e SUPABASE_TEST_SERVICE_KEY="$key" \
    flutter flutter test --run-skipped --tags integration --concurrency=1 test/integration || rc=$?
  # The owners table holds one row: leave none for the pgTAP tests that follow, pass or fail.
  docker exec -i supabase_db_s.is psql -U postgres -v ON_ERROR_STOP=1 -qAt < test/integration/fixtures/admin_view_cleanup.sql >/dev/null || rc=$?
  return "$rc"
}

# The private functions and their tests live outside git, in the main checkout's .private/ops (found through the git common dir, so a worktree sees them).
# No private-sql folder: skipped, unless the marker file EXPECT_PRIVATE says this machine must have them; then it FAILS.
private_scripts() {
  local main priv f n=0 sup='docker compose run --rm supabase' sqlb64 ver harm big
  main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  priv="${SIS_PRIVATE_OPS_DIR:-$main/.private/ops}"
  shopt -s nullglob
  if [ ! -d "$priv/private-sql" ] || [ -z "$(echo "$priv"/private-sql/*.sql)" ]; then
    if [ -e "$priv/EXPECT_PRIVATE" ]; then echo 'private scripts are expected here but .private/ops/private-sql has no .sql file' >&2; return 1; fi
    echo 'no private scripts on this machine: skipped'
    return 0
  fi
  ver_of() { printf 'v%s' "$(printf '%s\n' "$1" | head -n -2 | sha256sum | cut -c1-16)"; }
  b64_of() { printf '%s\n' "$1" | gzip -9n | base64 -w0; }
  # Deliberate failures: each wrong pack must make the install script exit non-zero.
  harm=$(printf 'select 1;\nselect 2;\nselect 3;')
  if env PRIVATE_EXPECTED=1 PRIVATE_SUPABASE="$sup" PRIVATE_SQL_B64="" PRIVATE_PACK_VERSION="$(ver_of "$harm")" tool/private_install.sh local >/dev/null 2>&1; then echo 'private install must fail: empty' >&2; return 1; fi
  if env PRIVATE_EXPECTED=1 PRIVATE_SUPABASE="$sup" PRIVATE_SQL_B64="$(printf "not gzip" | base64 -w0)" PRIVATE_PACK_VERSION="$(ver_of "$harm")" tool/private_install.sh local >/dev/null 2>&1; then echo 'private install must fail: corrupt gzip' >&2; return 1; fi
  big=$(head -c 82500 /dev/urandom | base64 -w0; printf '\nx\ny')
  if env PRIVATE_EXPECTED=1 PRIVATE_SUPABASE="$sup" PRIVATE_SQL_B64="$(b64_of "$big")" PRIVATE_PACK_VERSION="$(ver_of "$big")" tool/private_install.sh local >/dev/null 2>&1; then echo 'private install must fail: oversize' >&2; return 1; fi
  if env PRIVATE_EXPECTED=1 PRIVATE_SUPABASE="$sup" PRIVATE_SQL_B64="$(b64_of "$harm")" PRIVATE_PACK_VERSION="$(ver_of "$harm")" tool/private_install.sh local >/dev/null 2>&1; then echo 'private install must fail: no pack in the database' >&2; return 1; fi
  sqlb64=$(cat "$priv"/private-sql/0*.sql | gzip -9n | base64 -w0)
  ver=$(sed -n "s/.*return '\(v[0-9a-f]\{16\}\)'.*/\1/p" "$priv"/private-sql/09_version.sql)
  env PRIVATE_EXPECTED=1 PRIVATE_SUPABASE="$sup" PRIVATE_SQL_B64="$sqlb64" PRIVATE_PACK_VERSION="$ver" tool/private_install.sh local || return 1
  harm=$(printf 'select 4;\nselect 5;\nselect 6;')
  if env PRIVATE_EXPECTED=1 PRIVATE_SUPABASE="$sup" PRIVATE_SQL_B64="$(b64_of "$harm")" PRIVATE_PACK_VERSION="$(ver_of "$harm")" tool/private_install.sh local >/dev/null 2>&1; then echo 'private install must fail: stale pack' >&2; return 1; fi
  for f in "$priv"/private-tests/*.sql; do n=$((n + 1)); done
  [ "$n" -gt 0 ] || { echo 'no private tests found' >&2; return 1; }
  rm -rf supabase/tests/private && mkdir -p supabase/tests/private && cp "$priv"/private-tests/*.sql supabase/tests/private/
  docker compose run --rm supabase test db supabase/tests/private || { rm -rf supabase/tests/private; return 1; }
  rm -rf supabase/tests/private
}

# The public side of the private function hashes: a changed function body with a forgotten hash fails here, not at release.
private_hashes() {
  local f; f=$(mktemp)
  { printf 'do $pk$ begin perform set_config(%s, %s, false); execute $pkw_$' "'private.expected'" "''"; cat tool/private_check.sql; printf '$pkw_$; end $pk$;\n'; } > "$f"
  docker compose run --rm -v "$f:/tmp/private_check.sql:ro" supabase db query --local -f /tmp/private_check.sql || { rm -f "$f"; return 1; }
  rm -f "$f"
}

job_android() {
  step "Build development image" "${CI[@]}" build || return 1
  step "Resolve dependencies" "${CI[@]}" run --rm flutter flutter pub get || return 1
  step "Layer rules" layer_rules || return 1
  step "Check formatting" "${CI[@]}" run --rm flutter dart format --output=none --set-exit-if-changed lib test || return 1
  step "Analyze" "${CI[@]}" run --rm flutter flutter analyze || return 1
  step "Build the Rust library for the Dart tests" "${CI[@]}" run --rm flutter cargo build --release --manifest-path rust/Cargo.toml || return 1
  step "Rust tests" "${CI[@]}" run --rm flutter cargo test --manifest-path rust/Cargo.toml || return 1
  step "Rust advisories" "${CI[@]}" run --rm flutter cargo deny --manifest-path rust/Cargo.toml check -W unmaintained advisories || return 1
  step "Rust licences" "${CI[@]}" run --rm flutter cargo deny --manifest-path rust/Cargo.toml check licenses || return 1
  step "Cargokit build tool tests" "${CI[@]}" run --rm flutter sh -c 'cd rust_builder/cargokit/build_tool && dart pub get && for t in test/*_test.dart; do dart run "$t" || exit 1; done' || return 1
  step "Test" "${CI[@]}" run --rm -e TZ=JST-9 flutter flutter test || return 1
  step "Firebase config present" test -f android/app/google-services.json || return 1
  step "Android unit tests" "${CI[@]}" run --rm flutter sh -c 'flutter build apk --config-only && cd android && ./gradlew --no-daemon :app:testDebugUnitTest' || return 1
  step "Build release bundle" bundle
}

job_database() {
  # One database run per machine: the Supabase stack is shared, and a second run's wipe step would kill the first.
  exec 9>"${XDG_RUNTIME_DIR:-/tmp}/sis-ci-db.lock"
  flock -n 9 || { echo 'waiting for another database run'; flock 9; }
  step "Build Supabase tooling image" docker compose build supabase || return 1
  # Zero state: --no-backup drops the stack's data volumes (not the SDK ones).
  step "Wipe leftover Supabase stack" docker compose run --rm supabase stop --no-backup || return 1
  step "Start Supabase and replay migrations" docker compose run --rm supabase start -x "$SKIP" || return 1
  step "Lint database" docker compose run --rm supabase db lint --level error || return 1
  step "Check the private function hashes" private_hashes || return 1
  step "Test database" docker compose run --rm supabase test db || return 1
  step "Edge function tests" edge_tests || return 1
  step "Build development image" "${CI[@]}" build flutter || return 1
  step "Build the Rust library for the Dart tests" "${CI[@]}" run --rm flutter cargo build --release --manifest-path rust/Cargo.toml || return 1
  step "Wait until Realtime delivers" "${CI[@]}" run --rm flutter flutter test --run-skipped --tags warmup test/integration/realtime_warmup_test.dart || return 1
  step "Repository integration tests" integration || return 1
  # The integration tests run before the private pack: the registry fixture adds a stand-in panel only when none exists.
  step "Private functions and tests" private_scripts || return 1
  step "SIS Bot tool test" env SIS_BOT_TEST_COMPOSE="${CI[*]}" test/tool/sis_bot_tool_test.sh || return 1
  step "Test sender admin tool test" env SIS_BOT_TEST_COMPOSE="${CI[*]}" test/tool/sis_test_account_admin_test.sh
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
