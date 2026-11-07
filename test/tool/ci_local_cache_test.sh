#!/usr/bin/env bash
# tool/ci_local.sh `prepare_ci_cache`, run alone (function text cut out of the script) in temp dirs
# with SIS_CI_CACHE in the temp dir and a fake `docker` first on PATH that records its arguments:
#  1. fresh dir: .ci-cache/pub (user's) and shared gradle,m2 exist; .ci-cache/gradle,m2 link to them
#  2. a correct symlink stays untouched
#  3. an empty real dir becomes the symlink
#  4. an empty real dir the user cannot write: docker chown call, then symlink
#  5. a non-empty writable real dir is left alone, one warning on stderr naming it
#  6. an unwritable pub: docker chown call, never replaced
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
export SIS_CI_CACHE=$tmp/shared

# run_in <dir>: runs the function there; stderr to $tmp/err.
run_in() { : > "$tmp/docker.log"; (cd "$1" && PATH=$tmp/bin:$PATH && source "$tmp/fn.sh" && prepare_ci_cache) 2> "$tmp/err"; }
fresh() { rm -rf "$tmp/w" "$SIS_CI_CACHE"; mkdir -p "$tmp/w"; }
is_link() { [ -L "$1" ] && [ "$(readlink "$1")" = "$SIS_CI_CACHE/$2" ]; }

# 1
fresh; run_in "$tmp/w" || fail "1: prepare_ci_cache failed"
[ -d "$tmp/w/.ci-cache/pub" ] && [ -O "$tmp/w/.ci-cache/pub" ] || fail "1: pub missing or not the user's"
for d in gradle m2; do
  [ -d "$SIS_CI_CACHE/$d" ] || fail "1: shared $d not created"
  is_link "$tmp/w/.ci-cache/$d" $d || fail "1: .ci-cache/$d is not a link to the shared dir"
done
[ ! -s "$tmp/docker.log" ] || fail "1: docker was called"

# 2
run_in "$tmp/w" || fail "2: second run failed"
for d in gradle m2; do is_link "$tmp/w/.ci-cache/$d" $d || fail "2: link changed"; done
[ ! -s "$tmp/docker.log" ] && [ ! -s "$tmp/err" ] || fail "2: docker call or warning for a correct link"

# 3
fresh; mkdir -p "$tmp/w/.ci-cache/gradle" "$tmp/w/.ci-cache/m2"
run_in "$tmp/w" || fail "3: prepare_ci_cache failed"
for d in gradle m2; do is_link "$tmp/w/.ci-cache/$d" $d || fail "3: empty real $d not replaced by the link"; done
[ ! -s "$tmp/docker.log" ] || fail "3: docker called for writable dirs"

# 4 (chmod cannot make a dir unwritable for root)
if [ "$(id -u)" != 0 ]; then
  fresh; mkdir -p "$tmp/w/.ci-cache/gradle"; chmod 555 "$tmp/w/.ci-cache/gradle"
  run_in "$tmp/w" || fail "4: prepare_ci_cache failed"
  want="run --rm -v $tmp/w/.ci-cache/gradle:/c alpine chown -R $(id -u):$(id -g) /c"
  [ "$(cat "$tmp/docker.log")" = "$want" ] || fail "4: docker calls were: $(cat "$tmp/docker.log"); want: $want"
  is_link "$tmp/w/.ci-cache/gradle" gradle || fail "4: unwritable empty dir not replaced by the link"
fi

# 5
fresh; mkdir -p "$tmp/w/.ci-cache/m2"; echo x > "$tmp/w/.ci-cache/m2/own.jar"
run_in "$tmp/w" || fail "5: prepare_ci_cache failed"
[ ! -L "$tmp/w/.ci-cache/m2" ] && [ -e "$tmp/w/.ci-cache/m2/own.jar" ] || fail "5: non-empty dir was replaced or emptied"
[ "$(wc -l < "$tmp/err")" = 1 ] && grep -q "\.ci-cache/m2" "$tmp/err" || fail "5: want one warning naming .ci-cache/m2, got: $(cat "$tmp/err")"

# 6
if [ "$(id -u)" != 0 ]; then
  fresh; mkdir -p "$tmp/w/.ci-cache/pub"; chmod 555 "$tmp/w/.ci-cache/pub"
  run_in "$tmp/w" || fail "6: prepare_ci_cache failed"
  want="run --rm -v $tmp/w/.ci-cache/pub:/c alpine chown -R $(id -u):$(id -g) /c"
  [ "$(cat "$tmp/docker.log")" = "$want" ] || fail "6: docker calls were: $(cat "$tmp/docker.log"); want: $want"
  [ -d "$tmp/w/.ci-cache/pub" ] && [ ! -L "$tmp/w/.ci-cache/pub" ] || fail "6: pub was replaced"
fi
echo "ci_local_cache_test: ok"
