#!/usr/bin/env bash
# tool/check_migration_versions.sh on fixture trees:
#
#   - fresh fixture tree for each case
#   - run the script and capture output and exit code
#   - compare against expected behaviour
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# fresh : a fixture tree holding copies of the guard and the migrations folder
fresh() {
  rm -rf "$tmp/t"; mkdir -p "$tmp/t/tool" "$tmp/t/supabase/migrations"
  cp "$repo/tool/check_migration_versions.sh" "$tmp/t/tool/"
}

# expect <code> <name> [needle...] : runs the guard in the fixture tree.
expect() {
  local want=$1 name=$2 out code=0; shift 2
  out=$(bash "$tmp/t/tool/check_migration_versions.sh" 2>&1) || code=$?
  [ "$code" = "$want" ] || fail "$name: exit $code, want $want ($out)"
  if [ "$want" = 0 ] && [[ -n "$out" ]]; then fail "$name: unexpected output ($out)"; fi
  if [ "$want" != 0 ] && [[ -z "$out" ]]; then fail "$name: no output on failure"; fi
  # check needles on failure
  if [ "$want" != 0 ]; then
    for needle in "$@"; do
      if [[ "$out" != *"$needle"* ]]; then
        fail "$name: output lacks '$needle' ($out)"
      fi
    done
  fi
}

# Case 1: clash2
fresh
touch "$tmp/t/supabase/migrations/20260101000000_a.sql"
touch "$tmp/t/supabase/migrations/20260101000000_b.sql"
expect 1 "clash2" 20260101000000 20260101000000_a.sql 20260101000000_b.sql
# Case 2: clash3
fresh
touch "$tmp/t/supabase/migrations/20260101000000_a.sql"
touch "$tmp/t/supabase/migrations/20260101000000_b.sql"
touch "$tmp/t/supabase/migrations/20260101000000_c.sql"
expect 1 "clash3" 20260101000000 20260101000000_a.sql 20260101000000_b.sql 20260101000000_c.sql
# Case 3: unique
fresh
touch "$tmp/t/supabase/migrations/20260101000000_a.sql"
touch "$tmp/t/supabase/migrations/20260102000000_b.sql"
expect 0 "unique"
# Case 4: non_sql
fresh
touch "$tmp/t/supabase/migrations/20260101000000_a.sql"
touch "$tmp/t/supabase/migrations/20260101000000_notes.md"
expect 0 "non_sql"
# Case 5: empty
fresh
expect 0 "empty"
# Case 6: prefix_only_14
fresh
touch "$tmp/t/supabase/migrations/20260101000000_a.sql"
touch "$tmp/t/supabase/migrations/20260101000001_b.sql"
expect 0 "prefix_only_14"
# Case 7: two_clashes
fresh
touch "$tmp/t/supabase/migrations/20260101000000_a.sql"
touch "$tmp/t/supabase/migrations/20260101000000_b.sql"
touch "$tmp/t/supabase/migrations/20260102000000_c.sql"
touch "$tmp/t/supabase/migrations/20260102000000_d.sql"
expect 1 "two_clashes" 20260101000000_a.sql 20260101000000_b.sql 20260102000000_c.sql 20260102000000_d.sql

if [ "$fails" -ne 0 ]; then echo "check_migration_versions_test: $fails failed"; exit 1; fi
echo "check_migration_versions_test: ok"
