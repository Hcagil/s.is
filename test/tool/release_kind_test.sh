#!/usr/bin/env bash
# tool/release_kind.sh <prev> <sha> over a real git history: prints exactly one line
# quiet=true|false (exit 0); quiet=true only if the range ships AND every shipping
# file is under lib/features/admin_panels/ (docs/ .github/ test/ integration_test/
# supabase/tests/ tool/ *.md never count). Wrong arg count -> exit 2; unknown sha or prev -> exit 1.
set -euo pipefail
real="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); errf=$(mktemp); trap 'rm -rf "$tmp" "$errf"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email qa@sis.test; git config user.name QA
git config commit.gpgsign false; git config tag.gpgsign false
mkdir tool; cp "$real/tool/release_kind.sh" "$real/tool/release_scope.sh" tool/
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
# mk <path>...: from tag v1 on a fresh branch, change each path, commit; sets $sha.
mk() {
  git checkout -q -B case v1
  local p; for p in "$@"; do mkdir -p "$(dirname "$p")"; echo "$RANDOM" >>"$p"; git add -- "$p"; done
  git commit -q -m case; sha=$(git rev-parse HEAD)
}
# check <name> <true|false> <prev> <sha>: stdout exactly quiet=<want>, exit 0, one stderr line.
check() {
  local name=$1 want=$2; shift 2
  set +e; out=$(tool/release_kind.sh "$@" 2>"$errf"); code=$?; set -e
  if [[ $code -ne 0 ]]; then fail "$name: exit $code"; return; fi
  if [[ $out != "quiet=$want" ]]; then fail "$name: stdout '$out', want quiet=$want"; return; fi
  if [[ $(grep -c . "$errf") -ne 1 ]]; then fail "$name: stderr not one line: $(cat "$errf")"; return; fi
  echo "ok: $name"
}
# code_is <name> <want exit code> <args...>
code_is() {
  local name=$1 want=$2; shift 2
  set +e; tool/release_kind.sh "$@" >/dev/null 2>&1; code=$?; set -e
  [[ $code -eq $want ]] && echo "ok: $name" || fail "$name: exit $code, want $want"
}
mkdir -p lib/features/admin_panels; echo a >lib/main.dart; echo a >README.md; echo a >lib/features/admin_panels/panel.dart
git add -A; git commit -q -m base; git tag -a v1 -m v1
# ---- CASES (fill in) ----
mk lib/features/admin_panels/panel.dart
check "admin panel only" true v1 "$sha"

mk lib/features/admin_panels/panel.dart docs/x.md README.md
check "admin panel + docs + readme" true v1 "$sha"

mk lib/main.dart
check "app only" false v1 "$sha"

mk lib/features/admin_panels/panel.dart lib/main.dart
check "admin panel + app" false v1 "$sha"

mk docs/x.md
check "docs only" false v1 "$sha"

# prev empty
mk lib/features/admin_panels/panel.dart
check "empty prev admin" true "" "$sha"
mk lib/main.dart
check "empty prev app" false "" "$sha"

check "same commit" false v1 v1

# exit code checks
code_is "no args" 2
code_is "one arg" 2 v1
code_is "three args" 2 v1 v1 v1
code_is "unknown sha" 1 v1 dddddddddddddddddddddddddddddddddddddddd
code_is "unknown prev" 1 nosuchtag HEAD
# ---- end ----
[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo PASS
