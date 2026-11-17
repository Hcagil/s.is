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

break_markers() {
  local f
  while IFS= read -r f; do
    local commit
    commit=$(git log --no-renames --diff-filter=A --format=%H -- "$f" | tail -n 1)
    [ -z "$commit" ] && commit="$OLD_APP_HEAD"
    while IFS= read -r name; do
      echo "$name $commit"
    done < <(grep -hE '^-- old-app-break: [^ ]+ -- .+' "$f" | sed -E 's/^-- old-app-break: ([^ ]+) -- .*/\1/')
  done < <(grep -rlE '^-- old-app-break: [^ ]+ -- .+' supabase/migrations 2>/dev/null || true)
}

excused() {
  local tag="$1" logfile="$2"
  local markers count line testfile commit ok
  markers=$(break_markers)
  count=0
  while IFS= read -r line; do
    count=$((count+1))
    ok=false
    while read -r testfile commit; do
      [ -n "$testfile" ] || continue
      case "$line" in
        *"/test/integration/$testfile: "*)
          # strictly older: a build made on the migration's own commit already has the removal
          if [ "$(git rev-parse "$tag^{commit}")" != "$commit" ] && git merge-base --is-ancestor "$tag" "$commit"; then
            ok=true
          fi
          ;;
      esac
    done <<< "$markers"
    $ok || return 1
  done < <(grep -E ' \[E\]$' "$logfile" || true)
  [ "$count" -gt 0 ]
}

check_tag() {
  local tag="$1"
  local dir
  dir=$(mktemp -d)
  dirs+=("$dir")
  git archive "$tag" | tar -x -C "$dir"

  local start end seconds rc out
  out=$(mktemp)
  start=$(date +%s)
  if [ -n "${OLD_APP_REPLAY:-}" ]; then
    if "$OLD_APP_REPLAY" "$dir" "$tag" >"$out"; then
      rc=0
    else
      rc=$?
    fi
  else
    if replay_tag "$dir" "$tag" >"$out"; then
      rc=0
    else
      rc=$?
    fi
  fi
  end=$(date +%s)
  seconds=$((end - start))
  cat "$out"

  case $rc in
    0)
      say "PASS $tag (${seconds}s)"
      ;;
    3)
      say "UNCHECKED: no server-call tests in build $tag"
      ;;
    1)
      if [ "${OLD_APP_EXCUSE:-1}" = 1 ] && excused "$tag" "$out"; then say "EXPECTED BREAK $tag (${seconds}s): every failing test is named by an old-app-break marker in a newer migration"; rc=0; else say "FAIL $tag (${seconds}s)"; fi
      ;;
    *)
      say "ERROR $tag (${seconds}s)"
      ;;
  esac

  rm -f "$out"

  # 0 pass or unchecked, 1 a real failing test, 2 error (the release stops on 2)
  case $rc in 0|3) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

release_raise() {
  local build="${OLD_APP_RELEASE_BUILD:-}"
  if ! [[ "$build" =~ ^[0-9]+$ ]]; then
    echo "old app raise: OLD_APP_RELEASE_BUILD is missing" >&2
    return 1
  fi

  OLD_APP_EXCUSE=0

  local arr
  mapfile -t arr < <(printf '%s\n' "$tags" | awk -F+ -v m="$OLD_APP_MIN" '$NF+0 >= m+0' | sort -t+ -k2 -n)
  if [ ${#arr[@]} -eq 0 ]; then
    say "old app raise: no build at or above the oldest allowed build $OLD_APP_MIN; nothing to replay"
    return 0
  fi

  local hi=$(( ${#arr[@]} - 1 ))
  local raise=""
  local reason=""

  local rc
  rc=0; check_tag "${arr[$hi]}" || rc=$?
  if [ "$rc" -eq 2 ]; then return 1; fi
  if [ "$rc" -eq 1 ]; then
    raise="$build"
    reason="newest build ${arr[$hi]} fails against the new server"
  fi

  if [ -z "$raise" ] && [ "$hi" -gt 0 ]; then
    rc=0; check_tag "${arr[0]}" || rc=$?
    if [ "$rc" -eq 2 ]; then return 1; fi
    if [ "$rc" -eq 1 ]; then
      local lo=0
      while [ $((hi - lo)) -gt 1 ]; do
        local mid=$(( (lo + hi) / 2 ))
        rc=0; check_tag "${arr[$mid]}" || rc=$?
        if [ "$rc" -eq 2 ]; then return 1; fi
        if [ "$rc" -eq 0 ]; then
          hi=$mid
        else
          lo=$mid
        fi
      done
      raise="${arr[$hi]##*+}"
      reason="build ${arr[$lo]} fails and ${arr[$hi]} passes against the new server"
    fi
  fi

  if [ -n "$raise" ] && [ "$raise" -gt "$OLD_APP_MIN" ]; then
    say "old app raise: raise the oldest allowed build from $OLD_APP_MIN to $raise ($reason)"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "raise_to=$raise" >> "$GITHUB_OUTPUT"
      echo "raise_reason=$reason" >> "$GITHUB_OUTPUT"
    fi
    echo "raise_to=$raise"
  else
    say "old app raise: no raise needed"
  fi
  return 0
}

dirs=()
reset_done=false
trap 'rm -rf "${dirs[@]}"' EXIT
any_fail=false

if [ "${OLD_APP_MODE:-}" = release ]; then
  release_raise || any_fail=true
else
  for tag in "${selected[@]}"; do
    check_tag "$tag" || any_fail=true
  done
fi

# Put the current seed back, so later steps (pgTAP, the next suite) see this branch's fixtures.
if $reset_done && ! $OLD_APP_RESET_CMD >/dev/null 2>&1; then
  say "ERROR: could not restore the current seed after the replays"
  any_fail=true
fi

if $any_fail; then
  exit 1
fi

exit 0
