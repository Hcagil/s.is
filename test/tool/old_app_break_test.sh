#!/usr/bin/env bash
# tool/old_app_check.sh on a throwaway git repo with stubbed replay/compose.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# mkrepo <numbers...> : repo $tmp/r with tags v1.0.N+N, then one untagged commit (HEAD is no tag).
mkrepo() {
  rm -rf "$tmp/r" "$tmp/calls" "$tmp/rc" "$tmp/sum" "$tmp/compose.log"
  mkdir -p "$tmp/r/tool" "$tmp/r/supabase"
  cp "$repo/tool/old_app_check.sh" "$tmp/r/tool/"
  ( cd "$tmp/r"
    git init -q; git config user.email a@mail.test; git config user.name a; git config commit.gpgsign false
    for n in "$@"; do
      echo "$n" > f
      if [ "${WITH_INTEG:-}" = 1 ]; then mkdir -p test/integration; echo "void main(){}" > test/integration/a_test.dart; fi
      if [ "${SEEDS:-}" = 1 ]; then echo "-- SEED-$n" > supabase/seed.sql; fi
      git add -A; git commit -qm "c$n"; git tag "v1.0.$n+$n"
    done
    echo last > g; if [ "${SEEDS:-}" = 1 ]; then echo "-- SEED-NEW" > supabase/seed.sql; fi; git add -A; git commit -qm last )
  printf '#!/usr/bin/env bash\necho "$2" >> "%s/calls"\nrc=$(grep "^$2 " "%s/rc" 2>/dev/null | cut -d" " -f2 || true)\nexit ${rc:-0}\n' "$tmp" "$tmp" > "$tmp/stub.sh"
  chmod +x "$tmp/stub.sh"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/compose.log"\nexit 0\n' "$tmp" > "$tmp/compose.sh"
  chmod +x "$tmp/compose.sh"
}
# setrc <tag> <rc> : the stub replay exits <rc> for <tag>.
setrc() { echo "$1 $2" >> "$tmp/rc"; }
# run <ENV=val...> : runs the script in the fixture; sets $out $code $calls (sorted, space-joined). Uses the stub replay.
run() {
  code=0; rm -f "$tmp/calls"
  out=$( cd "$tmp/r" && env OLD_APP_REPLAY="$tmp/stub.sh" "$@" bash tool/old_app_check.sh 2>&1 ) || code=$?
  calls=""; [ -f "$tmp/calls" ] && calls=$(sort "$tmp/calls" | paste -sd' ' -)
  return 0
}
# runreal <ENV=val...> : same but with the script's own replay (no stub).
runreal() {
  code=0
  out=$( cd "$tmp/r" && env "$@" bash tool/old_app_check.sh 2>&1 ) || code=$?
  return 0
}
eqv() { [ "$2" = "$3" ] || fail "$1: got '$2', want '$3' (out: $out)"; }
has() { [[ "$out" == *"$2"* ]] || fail "$1: output lacks '$2' (out: $out)"; }

# Helpers for old_app_break_test
mkstub() { rm -rf "$tmp/out"; mkdir -p "$tmp/out"; printf '#!/usr/bin/env bash\necho "$2" >> "%s/calls"\n[ -f "%s/out/$2" ] && cat "%s/out/$2"\nrc=$(cat "%s/out/$2.rc" 2>/dev/null || echo 0)\nexit $rc\n' "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/stub.sh"; chmod +x "$tmp/stub.sh"; }
setout() { local tag=$1 rc=$2; shift 2; printf '%s\n' "$@" > "$tmp/out/$tag"; echo "$rc" > "$tmp/out/$tag.rc"; }
addmig() { ( cd "$tmp/r"; mkdir -p supabase/migrations; printf '%s\n' "$2" > "supabase/migrations/$1"; git add -A; git commit -qm "mig $1" ); }
efail() { echo "00:05 +3 -1: /work/test/integration/$1: some test [E]"; }
MARK='-- old-app-break: x_test.dart -- why it breaks'

# Test cases for old_app_break_test.sh

# m1
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
setout v1.0.101+101 1 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m1-code "$code" 0
has m1-pass "EXPECTED BREAK v1.0.101+101 ("
has m1-pass "PASS v1.0.120+120"

# m2
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
setout v1.0.101+101 1 "$(efail x_test.dart)" "$(efail y_test.dart)"
run OLD_APP_MIN=1
eqv m2-code "$code" 1
has m2-fail "FAIL v1.0.101+101"
[[ "$out" != *"EXPECTED BREAK"* ]] || fail "m2 excused wrongly"

# m3
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "-- old-app-break: y_test.dart -- why it breaks"
setout v1.0.101+101 1 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m3-code "$code" 1
has m3-fail "FAIL v1.0.101+101"

# m4
for bad in "-- old-app-break: x_test.dart" "-- old-app-break x_test.dart -- why" "-- old-app-brake: x_test.dart -- why"; do
  mkrepo 101 120; mkstub
  addmig 20260101000000_a.sql "$bad"
  setout v1.0.101+101 1 "$(efail x_test.dart)"
  run OLD_APP_MIN=1
  eqv "m4-$bad-code" "$code" 1
  has "m4-$bad-fail" "FAIL v1.0.101+101"
done

# m5
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
setout v1.0.101+101 2 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m5-code "$code" 1
has m5-error "ERROR v1.0.101+101"
[[ "$out" != *"EXPECTED BREAK"* ]] || fail "m5 excused ERROR"

# m6
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
setout v1.0.101+101 1 "boom"
run OLD_APP_MIN=1
eqv m6-code "$code" 1
has m6-fail "FAIL v1.0.101+101"

# m7
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
git -C "$tmp/r" tag v1.0.130+130
git -C "$tmp/r" commit --allow-empty -qm head
setout v1.0.130+130 1 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m7-code "$code" 1
has m7-fail "FAIL v1.0.130+130"

# m7b
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
git -C "$tmp/r" commit --allow-empty -qm later
git -C "$tmp/r" tag v1.0.130+130
git -C "$tmp/r" commit --allow-empty -qm head
setout v1.0.130+130 1 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m7b-code "$code" 1
has m7b-fail "FAIL v1.0.130+130"

# m8
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"$'\n'"-- old-app-break: y_test.dart -- why"
setout v1.0.101+101 1 "$(efail x_test.dart)" "$(efail y_test.dart)"
run OLD_APP_MIN=1
eqv m8-code "$code" 0
has m8-pass "EXPECTED BREAK v1.0.101+101"

# m8b
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
addmig 20260101000001_b.sql "-- old-app-break: y_test.dart -- why"
setout v1.0.101+101 1 "$(efail x_test.dart)" "$(efail y_test.dart)"
run OLD_APP_MIN=1
eqv m8b-code "$code" 0
has m8b-pass "EXPECTED BREAK v1.0.101+101"

# m9
mkrepo 101 120; mkstub
mkdir -p "$tmp/r/supabase/migrations"
printf '%s\n' "$MARK" > "$tmp/r/supabase/migrations/20260101000000_a.sql"
# not added to git
setout v1.0.101+101 1 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m9-code "$code" 0
has m9-pass "EXPECTED BREAK v1.0.101+101"

# m10
mkrepo 101 120; mkstub
mkdir -p "$tmp/r/docs"
printf '%s\n' "$MARK" > "$tmp/r/docs/a.md"
git -C "$tmp/r" add -A
git -C "$tmp/r" commit -qm doc
setout v1.0.101+101 1 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m10-code "$code" 1
has m10-fail "FAIL v1.0.101+101"

# m11
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
setout v1.0.101+101 1 "$(efail x_test.dart)"
setout v1.0.120+120 1 "$(efail x_test.dart)"
run OLD_APP_MIN=1
eqv m11-code "$code" 0
has m11-exp "EXPECTED BREAK v1.0.101+101"
has m11-exp "EXPECTED BREAK v1.0.120+120"

# m12
mkrepo 101 120; mkstub
addmig 20260101000000_a.sql "$MARK"
setout v1.0.101+101 1 "$(efail x_test.dart)"
setout v1.0.120+120 1 "$(efail z_test.dart)"
run OLD_APP_MIN=1
eqv m12-code "$code" 1
has m12-exp "EXPECTED BREAK v1.0.101+101"
has m12-fail "FAIL v1.0.120+120"

[ "$fails" -eq 0 ] || { echo "old_app_break_test: $fails failed"; exit 1; }
echo "old_app_break_test: OK"
