#!/usr/bin/env bash
# tool/ci_local.sh `prepare_ci_cache`, run alone (function text cut out of the script) in temp git repos
# with a fake `docker` first on PATH:
#  1. creates .ci-cache/{pub,gradle,m2} as the user, no docker call
#  2. a dir the user cannot write -> `docker run --rm -v <dir>:/c alpine chown -R <uid>:<gid> /c`
#  3. linked worktree, empty cache + non-empty main cache -> full copy (nested dirs), no *.lock
#  4. non-empty cache dir is never touched
#  5. main checkout itself: nothing copied
set -euo pipefail
cd "$(dirname "$0")/../.."
script=$PWD/tool/ci_local.sh
tmp=$(mktemp -d); trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

awk '/^prepare_ci_cache\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$script" > "$tmp/fn.sh"
[ -s "$tmp/fn.sh" ] || fail "prepare_ci_cache is not defined in tool/ci_local.sh"

mkdir "$tmp/bin"
printf '#!/bin/sh\necho "$@" >> "%s/docker.log"\n' "$tmp" > "$tmp/bin/docker"
chmod +x "$tmp/bin/docker"

# new_repo <name>: main repo + linked worktree <name>-wt; main cache is full.
new_repo() {
  local m=$tmp/$1
  git init -q "$m" && git -C "$m" -c user.email=a@mail.test -c user.name=t commit -q --allow-empty -m i
  git -C "$m" worktree add -q "$tmp/$1-wt"
  mkdir -p "$m/.ci-cache/pub" "$m/.ci-cache/gradle/metadata-2.107" "$m/.ci-cache/m2"
  echo p > "$m/.ci-cache/pub/p.txt"
  echo g > "$m/.ci-cache/gradle/metadata-2.107/x"
  echo l > "$m/.ci-cache/gradle/x.lock"
  echo m > "$m/.ci-cache/m2/a.jar"
}
run_in() { : > "$tmp/docker.log"; (cd "$1" && PATH=$tmp/bin:$PATH && source "$tmp/fn.sh" && prepare_ci_cache); }

# 1. fresh dir, no cache
mkdir "$tmp/plain" && git init -q "$tmp/plain"
run_in "$tmp/plain" || fail "1: prepare_ci_cache failed"
for d in pub gradle m2; do [ -d "$tmp/plain/.ci-cache/$d" ] || fail "1: .ci-cache/$d not created"; [ -O "$tmp/plain/.ci-cache/$d" ] || fail "1: .ci-cache/$d not owned by the user"; done
[ ! -s "$tmp/docker.log" ] || fail "1: docker was called for writable dirs"

# 2. unwritable dir
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$tmp/ro/.ci-cache/pub" "$tmp/ro/.ci-cache/m2" "$tmp/ro/.ci-cache/gradle" && git init -q "$tmp/ro"
  chmod 555 "$tmp/ro/.ci-cache/gradle"
  run_in "$tmp/ro" || fail "2: prepare_ci_cache failed"
  want="run --rm -v $tmp/ro/.ci-cache/gradle:/c alpine chown -R $(id -u):$(id -g) /c"
  [ "$(cat "$tmp/docker.log")" = "$want" ] || fail "2: docker calls were: $(cat "$tmp/docker.log"); want: $want"
fi

# 3. worktree with empty caches gets the main ones
new_repo a
run_in "$tmp/a-wt" || fail "3: prepare_ci_cache failed"
w=$tmp/a-wt/.ci-cache
[ "$(cat "$w/pub/p.txt")" = p ] || fail "3: pub not copied"
[ "$(cat "$w/gradle/metadata-2.107/x")" = g ] || fail "3: nested gradle metadata not copied"
[ "$(cat "$w/m2/a.jar")" = m ] || fail "3: m2 not copied"
[ -z "$(find "$w" -name '*.lock')" ] || fail "3: a .lock file was copied"

# 4. non-empty dir untouched, empty sibling still filled
new_repo b
mkdir -p "$tmp/b-wt/.ci-cache/m2" "$tmp/b-wt/.ci-cache/pub" "$tmp/b-wt/.ci-cache/gradle"
echo mine > "$tmp/b-wt/.ci-cache/m2/own.jar"
run_in "$tmp/b-wt" || fail "4: prepare_ci_cache failed"
[ "$(ls "$tmp/b-wt/.ci-cache/m2")" = own.jar ] || fail "4: non-empty m2 was touched: $(ls "$tmp/b-wt/.ci-cache/m2")"
[ -e "$tmp/b-wt/.ci-cache/pub/p.txt" ] || fail "4: empty pub was not filled"

# 5. main checkout: empty caches stay empty
mkdir "$tmp/m5" && git init -q "$tmp/m5"
run_in "$tmp/m5" || fail "5: prepare_ci_cache failed"
[ -z "$(ls -A "$tmp/m5/.ci-cache/pub")" ] || fail "5: main checkout cache was filled"
echo "ci_local_cache_test: ok"
