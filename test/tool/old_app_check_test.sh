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
      git add -A; git commit -qm "c$n"; git tag "v1.0.$n+$n"
    done
    echo last > g; git add -A; git commit -qm last )
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

# test_old_app_check_cases.sh
# This file contains the bash test cases described in the task.
# It uses the provided harness functions: mkrepo, setrc, run, runreal, eqv, has, fail.

# Case c1
mkrepo 101 110 120
run OLD_APP_MIN=105
eqv c1-code "$code" 0
eqv c1-calls "$calls" "v1.0.110+110 v1.0.120+120"
has c1-pass "PASS v1.0.110+110"
has c1-min "minimum supported build 105"

# Case c2
mkrepo 101 110 120
run OLD_APP_MIN=1
eqv c2-code "$code" 0
eqv c2-calls "$calls" "v1.0.101+101 v1.0.120+120"

# Case c3a
mkrepo 101 110 120
run OLD_APP_MIN=110
eqv c3a-code "$code" 0
eqv c3a-calls "$calls" "v1.0.110+110 v1.0.120+120"

# Case c3b
mkrepo 101 110 120
run OLD_APP_MIN=111
eqv c3b-code "$code" 0
eqv c3b-calls "$calls" "v1.0.120+120"
has c3b-same "newest and oldest are the same build v1.0.120+120"

# Case c4
mkrepo 101 110 120
run OLD_APP_MIN=500
eqv c4-code "$code" 0
eqv c4-calls "$calls" "v1.0.120+120"

# Case c5
mkrepo 101
run OLD_APP_MIN=1
eqv c5-code "$code" 0
eqv c5-calls "$calls" "v1.0.101+101"
has c5-same "same build v1.0.101+101"

# Case c6
mkrepo 101 110 120
run OLD_APP_MIN=1 OLD_APP_HEAD=v1.0.120+120
eqv c6-code "$code" 0
eqv c6-calls "$calls" "v1.0.101+101"
has c6-skipped "SKIPPED newest build v1.0.120+120: it is the tested commit"

# Case c7
mkrepo 9 100
run OLD_APP_MIN=1
eqv c7-code "$code" 0
eqv c7-calls "$calls" "v1.0.100+100 v1.0.9+9"

# Case c8
mkrepo 101 120
git -C "$tmp/r" tag v1.0.999
git -C "$tmp/r" tag foo+500
git -C "$tmp/r" tag v1.0.130+x
run OLD_APP_MIN=1
eqv c8-code "$code" 0
eqv c8-calls "$calls" "v1.0.101+101 v1.0.120+120"

# Test cases for old_app_check.sh

# c9: loop over five rc values
for rc in 0 1 2 7 3; do
  mkrepo 101 120
  setrc v1.0.101+101 "$rc"
  run OLD_APP_MIN=1
  case "$rc" in
    0) want=0; needle="PASS v1.0.101+101" ;;
    1) want=1; needle="FAIL v1.0.101+101" ;;
    2|7) want=1; needle="ERROR v1.0.101+101" ;;
    3) want=0; needle="UNCHECKED: no server-call tests in build v1.0.101+101" ;;
  esac
  eqv "c9-code-$rc" "$code" "$want"
  has "c9-out-$rc" "$needle"
done

# c10: check two tags with rc 1
mkrepo 101 120
setrc v1.0.120+120 1
run OLD_APP_MIN=1
eqv c10-code "$code" 1
eqv c10-calls "$calls" "v1.0.101+101 v1.0.120+120"
has c10-fail "FAIL v1.0.120+120"
has c10-pass "PASS v1.0.101+101"

# c11: check UNCHECKED handling and summary
mkrepo 101 120
setrc v1.0.101+101 3
run OLD_APP_MIN=1 GITHUB_STEP_SUMMARY="$tmp/sum"
grep -qF "UNCHECKED: no server-call tests in build v1.0.101+101" "$tmp/sum" || fail c11-unchecked
grep -qF "PASS v1.0.120+120" "$tmp/sum" || fail c11-pass

# c12: non-numeric OLD_APP_MIN
mkrepo 101 120
run OLD_APP_MIN=abc
eqv c12-code "$code" 1
has c12-out "cannot read the minimum supported build"
eqv c12-calls "$calls" ""

# c13: no build tags
mkrepo
run OLD_APP_MIN=1
eqv c13-code "$code" 0
has c13-out "no build tags found"

# test_old_app_check.sh
# This file contains the bash test cases for the old_app_check script.
# It uses the provided harness functions: mkrepo, run, runreal, eqv, has, fail.

# c14 base skip
mkrepo 101 120
mkdir -p "$tmp/r/supabase"
echo a > "$tmp/r/supabase/a.sql"
git -C "$tmp/r" add -A
git -C "$tmp/r" commit -qm sql

# (a) unchanged against HEAD
run OLD_APP_MIN=1 OLD_APP_BASE=HEAD
eqv c14a-code "$code" 0
has c14a-pass "SKIPPED (supabase/ unchanged against HEAD)"
eqv c14a-calls "$calls" ""

# (b) untracked file in supabase
echo b > "$tmp/r/supabase/new.sql"
run OLD_APP_MIN=1 OLD_APP_BASE=HEAD
eqv c14b-code "$code" 0
eqv c14b-calls "$calls" "v1.0.101+101 v1.0.120+120"

# (c) commit adding supabase change
git -C "$tmp/r" add -A
git -C "$tmp/r" commit -qm new
run OLD_APP_MIN=1 OLD_APP_BASE=HEAD~1
eqv c14c-code "$code" 0
eqv c14c-calls "$calls" "v1.0.101+101 v1.0.120+120"

# (d) commit outside supabase
echo z > "$tmp/r/outside.txt"
git -C "$tmp/r" add -A
git -C "$tmp/r" commit -qm outside
run OLD_APP_MIN=1 OLD_APP_BASE=HEAD~1
eqv c14d-code "$code" 0
has c14d-pass "SKIPPED (supabase/ unchanged against HEAD~1)"
eqv c14d-calls "$calls" ""

# c15 no server-call tests
mkrepo 101 120
runreal OLD_APP_MIN=1 OLD_APP_HEAD=v1.0.120+120
eqv c15-code "$code" 0
has c15-pass "UNCHECKED: no server-call tests in build v1.0.101+101"

# c16 reset and compose failures
# (a) reset fails, compose should not run
WITH_INTEG=1 mkrepo 101 120
runreal OLD_APP_MIN=1 OLD_APP_HEAD=v1.0.120+120 OLD_APP_RESET_CMD=false OLD_APP_COMPOSE="$tmp/compose.sh"
eqv c16a-code "$code" 1
has c16a-pass "ERROR v1.0.101+101"
[ ! -e "$tmp/compose.log" ] || fail c16a-compose-ran

# (b) compose fails
WITH_INTEG=1 mkrepo 101 120
runreal OLD_APP_MIN=1 OLD_APP_HEAD=v1.0.120+120 OLD_APP_COMPOSE=false
eqv c16b-code "$code" 1
has c16b-pass "ERROR v1.0.101+101"

# c17 static checks
grep -qF "OLD_APP_BASE=origin/main" "$repo/tool/ci_local.sh" || fail c17-base
grep -qF "tool/old_app_check.sh" "$repo/tool/ci_local.sh" || fail c17-script

[ "$fails" -eq 0 ] || { echo "old_app_check_test: $fails failed"; exit 1; }
echo "old_app_check_test: OK"
