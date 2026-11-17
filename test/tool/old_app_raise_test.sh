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

# Helpers (copy exactly)
mkstub() { rm -rf "$tmp/out"; mkdir -p "$tmp/out"; printf '#!/usr/bin/env bash\necho "$2" >> "%s/calls"\n[ -f "%s/out/$2" ] && cat "%s/out/$2"\nrc=$(cat "%s/out/$2.rc" 2>/dev/null || echo 0)\nexit $rc\n' "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/stub.sh"; chmod +x "$tmp/stub.sh"; }
setout() { local tag=$1 rc=$2; shift 2; printf '%s\n' "$@" > "$tmp/out/$tag"; echo "$rc" > "$tmp/out/$tag.rc"; }
# rel <ENV=val...>: release-mode run; sets $out $code $go (the GITHUB_OUTPUT file text) and $ncalls (how many replays ran)
rel() { rm -f "$tmp/go"; run OLD_APP_MODE=release GITHUB_OUTPUT="$tmp/go" "$@"; go=$(cat "$tmp/go" 2>/dev/null || true); ncalls=0; [ -f "$tmp/calls" ] && ncalls=$(wc -l < "$tmp/calls" | tr -d ' '); return 0; }
noraise() { [[ "$out" != *"raise_to="* ]] || fail "$1: stdout has raise_to= (out: $out)"; [[ "$go" != *"raise_to="* ]] || fail "$1: GITHUB_OUTPUT has raise_to (go: $go)"; }
efail() { echo "00:05 +3 -1: /work/test/integration/$1: some test [E]"; }
failtag() { setout "$1" 1 "$(efail x_test.dart)"; }   # replay of that tag fails (exit 1)
addmig() { ( cd "$tmp/r"; mkdir -p supabase/migrations; printf '%s\n' "$2" > "supabase/migrations/$1"; git add -A; git commit -qm "mig $1" ); }

# Test cases for old_app_raise_test.sh
# This file contains the bash test cases described in the task.
# It uses the provided harness functions: mkrepo, setout, rel, noraise, failtag, addmig.

# r1
mkrepo 101 110 120
mkstub
setout v1.0.101+101 0 "ok"
setout v1.0.110+110 0 "ok"
setout v1.0.120+120 0 "ok"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r1-code "$code" 0
has r1 "no raise needed"
noraise r1

# r2
mkrepo 101 110 120
mkstub
failtag v1.0.120+120
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r2-code "$code" 0
has r2 "raise_to=200"
has r2 "from 1 to 200"
[[ "$go" == *"raise_to=200"* && "$go" == *"raise_reason="* ]] || fail "r2-go: $go"

# r3
mkrepo 101 110 120 130 140 150 160
mkstub
failtag v1.0.101+101
failtag v1.0.110+110
failtag v1.0.120+120
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r3-code "$code" 0
has r3 "raise_to=130"
[[ "$go" == *"raise_to=130"* ]] || fail "r3-go: $go"
[ "$ncalls" -le 5 ] || fail r3 "ncalls $ncalls > 5"

# r3b
mkrepo 101 110 120 130 140 150 160 170 180 190
mkstub
failtag v1.0.101+101
failtag v1.0.110+110
failtag v1.0.120+120
failtag v1.0.130+130
failtag v1.0.140+140
failtag v1.0.150+150
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r3b-code "$code" 0
has r3b "raise_to=160"
[ "$ncalls" -le 6 ] || fail r3b "ncalls $ncalls > 6"

# r3c
mkrepo 101 110 120 130 140 150 160
mkstub
failtag v1.0.101+101
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r3c-code "$code" 0
has r3c "raise_to=110"

# r3d
mkrepo 101 110 120 130 140 150 160
mkstub
failtag v1.0.101+101
failtag v1.0.110+110
failtag v1.0.120+120
failtag v1.0.130+130
failtag v1.0.140+140
failtag v1.0.150+150
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r3d-code "$code" 0
has r3d "raise_to=160"

# r4
mkrepo 101
mkstub
setout v1.0.101+101 0 "ok"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r4-code "$code" 0
noraise r4

# r4b
mkrepo 101
mkstub
failtag v1.0.101+101
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r4b-code "$code" 0
has r4b "raise_to=200"

# r4c
mkrepo 101 120
mkstub
failtag v1.0.101+101
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r4c-code "$code" 0
has r4c "raise_to=120"

# r5
mkrepo 101 120
mkstub
setout v1.0.101+101 0 "ok"
setout v1.0.120+120 0 "ok"
rel OLD_APP_MIN=500 OLD_APP_RELEASE_BUILD=600
eqv r5-code "$code" 0
has r5 "nothing to replay"
noraise r5
[ "$ncalls" -eq 0 ] || fail r5 "ncalls $ncalls != 0"

# r6
mkrepo 101 110 120
mkstub
setout v1.0.101+101 0 "ok"
rel OLD_APP_MIN=1
eqv r6-code "$code" 1
noraise r6
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=abc
eqv r6b-code "$code" 1
noraise r6b

# r7
mkrepo 101 110 120
mkstub
setout v1.0.101+101 2 "error"
setout v1.0.110+110 0 "ok"
setout v1.0.120+120 0 "ok"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r7-code "$code" 1
noraise r7
# newest error
mkrepo 101 110 120
mkstub
setout v1.0.101+101 0 "ok"
setout v1.0.110+110 0 "ok"
setout v1.0.120+120 2 "error"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r7b-code "$code" 1
noraise r7b
# middle error with binary search
mkrepo 101 110 120 130 140 150 160
mkstub
failtag v1.0.101+101
setout v1.0.110+110 2 "error"
setout v1.0.120+120 2 "error"
setout v1.0.130+130 2 "error"
setout v1.0.140+140 2 "error"
setout v1.0.150+150 2 "error"
setout v1.0.160+160 0 "ok"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r7c-code "$code" 1
noraise r7c

# r8
mkrepo 101 110 120
mkstub
setout v1.0.101+101 3 "unchecked"
setout v1.0.110+110 0 "ok"
setout v1.0.120+120 0 "ok"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r8-code "$code" 0
noraise r8
has r8 "no raise needed"
# r8b
mkrepo 101 110 120
mkstub
setout v1.0.101+101 3 "unchecked"
setout v1.0.110+110 0 "ok"
failtag v1.0.120+120
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r8b-code "$code" 0
has r8b "raise_to=200"
# r8c
mkrepo 101 110 120 130
mkstub
failtag v1.0.101+101
failtag v1.0.110+110
setout v1.0.120+120 3 "unchecked"
setout v1.0.130+130 0 "ok"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r8c-code "$code" 0
has r8c "raise_to=120"

# r9
mkrepo 101 110 120
mkstub
addmig 20260101000000_a.sql '-- old-app-break: x_test.dart -- why it breaks'
failtag v1.0.101+101
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r9-code "$code" 0
has r9 "raise_to=110"
! [[ "$out" == *"EXPECTED BREAK"* ]] || fail r9 "output contains EXPECTED BREAK"

# r10
mkrepo 101 120
mkstub
setout v1.0.120+120 1 "fail"
rel OLD_APP_MIN=100 OLD_APP_RELEASE_BUILD=100
eqv r10-code "$code" 0
noraise r10
rel OLD_APP_MIN=100 OLD_APP_RELEASE_BUILD=50
eqv r10b-code "$code" 0
noraise r10b
rel OLD_APP_MIN=100 OLD_APP_RELEASE_BUILD=101
eqv r10c-code "$code" 0
has r10c "raise_to=101"

# r11
mkrepo 101 120
mkstub
setout v1.0.120+120 1 "fail"
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200
eqv r11-code "$code" 0
has r11 "raise_to=200"

# r12
mkrepo 101 110 120
mkstub
addmig 20260101000000_a.sql '-- old-app-break: x_test.dart -- why it breaks'
failtag v1.0.101+101
rel OLD_APP_MIN=1 OLD_APP_RELEASE_BUILD=200 OLD_APP_EXCUSE=1
eqv r12-code "$code" 0
has r12 "raise_to=110"

[ "$fails" -eq 0 ] || { echo "old_app_raise_test: $fails failed"; exit 1; }
echo "old_app_raise_test: OK"
