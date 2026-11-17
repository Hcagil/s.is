#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Replay an old app build's integration tests against the local server.
replay_tag() {
  local dir="$1" tag="$2" compose="${OLD_APP_COMPOSE:-}" db="${OLD_APP_DB_CONTAINER:-}"
  local key log_file rc pg
  [ -z "$compose" ] && compose="docker compose -f compose.yaml -f .github/compose.ci.yaml"
  [ -z "$db" ] && db="supabase_db_s.is"

  # 1. Check for integration tests
  if ! find "$dir/test/integration" -name '*.dart' 2>/dev/null | grep -q .; then
    return 3
  fi

  # 1b. Fresh database: the old suite expects a clean stack (rate limits, one-time identities).
  # New migrations, but the build's own seed.sql (test fixture data, never on production): a later seed may rename accounts the old suite signs in with.
  if [ -n "${OLD_APP_RESET_CMD:-}" ]; then
    pg=$(mktemp)
    if ! $OLD_APP_RESET_CMD --no-seed >"$pg" 2>&1; then
      tail -n 20 "$pg" >&2
      rm -f "$pg"
      return 2
    fi
    if [ -f "$dir/supabase/seed.sql" ] && ! docker exec -i "$db" psql -U postgres -v ON_ERROR_STOP=1 -qAt <"$dir/supabase/seed.sql" >"$pg" 2>&1; then
      tail -n 20 "$pg" >&2
      rm -f "$pg"
      return 2
    fi
    rm -f "$pg"
    reset_done=true
  fi

  # 2. Flutter pub get and optional rust build
  pg=$(mktemp)
  if ! $compose run --rm -T -v "$dir":/workspace flutter flutter pub get >"$pg" 2>&1; then
    tail -n 20 "$pg" >&2
    rm -f "$pg"
    return 2
  fi
  rm -f "$pg"
  if [ -f "$dir/rust/Cargo.toml" ]; then
    pg=$(mktemp)
    if ! $compose run --rm -T -v "$dir":/workspace flutter cargo build --release --manifest-path rust/Cargo.toml >"$pg" 2>&1; then
      tail -n 20 "$pg" >&2
      rm -f "$pg"
      return 2
    fi
    rm -f "$pg"
  fi

  # 3. Service key
  key=$($compose run --rm -T supabase status -o env | sed -n 's/^SECRET_KEY="\(.*\)"/\1/p')
  if [ -z "$key" ]; then
    echo "old app check: no service key from the local stack" >&2
    return 2
  fi
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$key"

  # 4. Load fixtures
  for f in staff_registry admin_view; do
    if [ -f "$dir/test/integration/fixtures/$f.sql" ]; then
      if ! docker exec -i "$db" psql -U postgres -v ON_ERROR_STOP=1 -qAt < "$dir/test/integration/fixtures/$f.sql" >/dev/null; then
        return 2
      fi
    fi
  done

  # 5. Run tests
  log_file=$(mktemp)
  $compose run --rm -T -v "$dir":/workspace \
    -e TZ=JST-9 \
    -e SUPABASE_TEST_SERVICE_KEY="$key" \
    flutter flutter test --run-skipped --tags integration --concurrency=1 \
    ${SUPABASE_TEST_URL:+--dart-define=SUPABASE_TEST_URL=$SUPABASE_TEST_URL} \
    test/integration >"$log_file" 2>&1 && rc=0 || rc=$?

  # 6. Cleanup fixture (ALWAYS)
  if [ -f "$dir/test/integration/fixtures/admin_view_cleanup.sql" ]; then
    docker exec -i "$db" psql -U postgres -v ON_ERROR_STOP=1 -qAt < "$dir/test/integration/fixtures/admin_view_cleanup.sql" >/dev/null 2>&1 || true
  fi

  # 7. Analyze results
  if [ "$rc" -eq 0 ]; then
    rm -f "$log_file"
    return 0
  fi

  # Check for loading errors
  if grep -q ': loading .* \[E\]$' "$log_file"; then
    tail -n 20 "$log_file" >&2
    rm -f "$log_file"
    return 2
  fi

  # Print test errors; a failure with no [E] line (e.g. the runner died) shows the end of the log instead.
  if grep -qE ' \[E\]$' "$log_file"; then
    grep -E ' \[E\]$' "$log_file" | head -40
  else
    tail -n 20 "$log_file"
  fi
  rm -f "$log_file"
  return 1
}

say() { echo "$1"; [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1" >> "$GITHUB_STEP_SUMMARY"; }

# OLD_APP_BASE check
if [ -n "${OLD_APP_BASE:-}" ]; then
  if git diff --quiet "$OLD_APP_BASE" -- supabase 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard supabase)" ]; then
    say "old app check: SKIPPED (supabase/ unchanged against $OLD_APP_BASE)"
    exit 0
  fi
fi

# OLD_APP_MIN check
if [ -z "${OLD_APP_MIN:-}" ]; then
  OLD_APP_MIN=$(docker exec -i "${OLD_APP_DB_CONTAINER:-supabase_db_s.is}" psql -U postgres -v ON_ERROR_STOP=1 -qAt -c 'select min_supported_build from public.app_config where id = 1' 2>/dev/null || true)
fi

if ! [[ "$OLD_APP_MIN" =~ ^[0-9]+$ ]]; then
  echo "old app check: cannot read the minimum supported build" >&2
  exit 1
fi

# OLD_APP_HEAD check
OLD_APP_HEAD="${OLD_APP_HEAD:-$(git rev-parse HEAD)}"

# Tag selection
tags=$(git tag -l 'v*+*' | grep -E '^v.+\+[0-9]+$' || true)

if [ -z "$tags" ]; then
  say "old app check: no build tags found"
  exit 0
fi

# Find newest and oldest
newest_tag=""
newest_n=0
oldest_tag=""
oldest_n=999999999

while IFS= read -r tag; do
  n="${tag##*+}"
  if [ "$n" -gt "$newest_n" ]; then
    newest_n=$n
    newest_tag=$tag
  fi
  if [ "$n" -ge "$OLD_APP_MIN" ] && [ "$n" -lt "$oldest_n" ]; then
    oldest_n=$n
    oldest_tag=$tag
  fi
done <<< "$tags"

selected=()
selected+=("$newest_tag")
if [ -n "$oldest_tag" ] && [ "$oldest_tag" != "$newest_tag" ]; then
  selected+=("$oldest_tag")
fi

if [ "$oldest_tag" = "$newest_tag" ]; then
  say "old app check: newest and oldest are the same build $newest_tag"
fi

if [ -z "$oldest_tag" ]; then
  say "WARN: no build at or above the oldest allowed build $OLD_APP_MIN; only the newest is checked"
fi

# Check if newest is the tested commit
if [ -n "$newest_tag" ]; then
  newest_commit=$(git rev-list -n1 "$newest_tag")
  head_commit=$(git rev-parse "${OLD_APP_HEAD}^{commit}")
  if [ "$newest_commit" = "$head_commit" ]; then
    say "old app check: SKIPPED newest build $newest_tag: it is the tested commit"
    # Remove newest from selected
    if [ ${#selected[@]} -eq 2 ]; then
      selected=("${selected[1]}")
    else
      selected=()
    fi
  fi
fi

say "old app check: minimum supported build $OLD_APP_MIN; checking: ${selected[*]:-none}"

# Run tests
dirs=()
reset_done=false
trap 'rm -rf "${dirs[@]}"' EXIT
any_fail=false

for tag in "${selected[@]}"; do
  dir=$(mktemp -d)
  dirs+=("$dir")
  git archive "$tag" | tar -x -C "$dir"
  
  start=$(date +%s)
  if [ -n "${OLD_APP_REPLAY:-}" ]; then
    if "$OLD_APP_REPLAY" "$dir" "$tag"; then
      rc=0
    else
      rc=$?
    fi
  else
    if replay_tag "$dir" "$tag"; then
      rc=0
    else
      rc=$?
    fi
  fi
  end=$(date +%s)
  seconds=$((end - start))
  
  case $rc in
    0)
      say "PASS $tag (${seconds}s)"
      ;;
    3)
      say "UNCHECKED: no server-call tests in build $tag"
      ;;
    1)
      say "FAIL $tag (${seconds}s)"
      any_fail=true
      ;;
    *)
      say "ERROR $tag (${seconds}s)"
      any_fail=true
      ;;
  esac
done

# Put the current seed back, so later steps (pgTAP, the next suite) see this branch's fixtures.
if $reset_done && ! $OLD_APP_RESET_CMD >/dev/null 2>&1; then
  say "ERROR: could not restore the current seed after the replays"
  any_fail=true
fi

if $any_fail; then
  exit 1
fi

exit 0
