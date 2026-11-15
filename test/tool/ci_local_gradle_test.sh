#!/usr/bin/env bash
# tool/ci_local.sh `gradle_isolate` and `gradle_cleanup` tests
set -euo pipefail
cd "$(dirname "$0")/../.."
script=$PWD/tool/ci_local.sh

tmp=$(mktemp -d); trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# extract functions
awk '/^gradle_isolate\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$script" > "$tmp/fn.sh"
awk '/^gradle_cleanup\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$script" >> "$tmp/fn.sh"
grep -q '^gradle_isolate()' "$tmp/fn.sh" && grep -q '^gradle_cleanup()' "$tmp/fn.sh" || fail "functions not found"

# fake bin
mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/sh
echo "$@" >> "$TMPD/docker.log"
EOF
chmod +x "$tmp/bin/docker"

export SIS_CI_CACHE=$tmp/shared
export TMPD=$tmp
mkdir -p "$tmp/w" "$SIS_CI_CACHE/gradle/wrapper/dists" "$SIS_CI_CACHE/gradle/caches"
echo m > "$SIS_CI_CACHE/gradle/wrapper/dists/marker.txt"

# helper iso
iso() {
  local o=$1
  bash -c 'cd "$1" && PATH=$2/bin:$PATH && source "$2/fn.sh" && CI=() && gradle_isolate >/dev/null && printf "%s\n" "$GR_DIR" "$GR_COMPOSE" "${CI[*]}"' _ "$tmp/w" "$tmp" > "$tmp/out$o"
}

iso 1
iso 2

# read outputs
GR_DIR1=$(sed -n 1p "$tmp/out1")
GR_COMPOSE1=$(sed -n 2p "$tmp/out1")
CI1=$(sed -n 3p "$tmp/out1")
GR_DIR2=$(sed -n 1p "$tmp/out2")
GR_COMPOSE2=$(sed -n 2p "$tmp/out2")
CI2=$(sed -n 3p "$tmp/out2")

# 1 checks
[ "$GR_DIR1" != "$GR_DIR2" ] || fail "1: GR_DIRs equal"
[ "$GR_COMPOSE1" != "$GR_COMPOSE2" ] || fail "1: GR_COMPOSEs equal"
[ -d "$GR_DIR1" ] || fail "1: GR_DIR1 not a directory"
[ -d "$GR_DIR2" ] || fail "1: GR_DIR2 not a directory"
[[ "$GR_DIR1" =~ \.ci-cache/gradle-run-[0-9]+$ ]] || fail "1: GR_DIR1 pattern"
[[ "$GR_DIR2" =~ \.ci-cache/gradle-run-[0-9]+$ ]] || fail "1: GR_DIR2 pattern"
[ "$GR_COMPOSE1" = "${GR_DIR1}.yaml" ] || fail "1: GR_COMPOSE1 mismatch"
[ "$GR_COMPOSE2" = "${GR_DIR2}.yaml" ] || fail "1: GR_COMPOSE2 mismatch"
[ "$CI1" = "-f $GR_COMPOSE1" ] || fail "1: CI1 wrong"
[ "$CI2" = "-f $GR_COMPOSE2" ] || fail "1: CI2 wrong"
[ -f "$GR_DIR1/wrapper/dists/marker.txt" ] || fail "1: marker.txt missing in run1"
[ -f "$GR_DIR2/wrapper/dists/marker.txt" ] || fail "1: marker.txt missing in run2"

# 2 checks
# yaml 1
grep -c ':/home/ubuntu/\.gradle$' "$GR_COMPOSE1" | grep -qxF 1 || fail "2: yaml1 gradle mount count"
grep -qxF "      - $GR_DIR1:/home/ubuntu/.gradle" "$GR_COMPOSE1" || fail "2: yaml1 missing gradle mount"
grep -qxF "      - $SIS_CI_CACHE/gradle/caches:/home/ubuntu/.gradle-ro:ro" "$GR_COMPOSE1" || fail "2: yaml1 missing caches mount"
grep -qxF "      GRADLE_RO_DEP_CACHE: /home/ubuntu/.gradle-ro" "$GR_COMPOSE1" || fail "2: yaml1 missing dep cache"
grep -qF "$GR_DIR2" "$GR_COMPOSE1" && fail "2: yaml1 contains run2 dir"

# yaml 2
grep -c ':/home/ubuntu/\.gradle$' "$GR_COMPOSE2" | grep -qxF 1 || fail "2: yaml2 gradle mount count"
grep -qxF "      - $GR_DIR2:/home/ubuntu/.gradle" "$GR_COMPOSE2" || fail "2: yaml2 missing gradle mount"
grep -qxF "      - $SIS_CI_CACHE/gradle/caches:/home/ubuntu/.gradle-ro:ro" "$GR_COMPOSE2" || fail "2: yaml2 missing caches mount"
grep -qxF "      GRADLE_RO_DEP_CACHE: /home/ubuntu/.gradle-ro" "$GR_COMPOSE2" || fail "2: yaml2 missing dep cache"
grep -qxF "      - $GR_DIR2:/home/ubuntu/.gradle" "$GR_COMPOSE2" || fail "2: yaml2 missing gradle mount"
grep -qF "$GR_DIR1" "$GR_COMPOSE2" && fail "2: yaml2 contains run1 dir"

# 3-6 cases
# prepare shared cache
mkdir -p "$SIS_CI_CACHE/gradle/caches/modules-2"
echo shared > "$SIS_CI_CACHE/gradle/caches/modules-2/old.jar"

# create p3.sh
cat > "$tmp/p3.sh" <<'EOF'
#!/usr/bin/env bash
cd "$1/w"; PATH=$1/bin:$PATH; source "$1/fn.sh"; CI=()
gradle_isolate >/dev/null; d=$GR_DIR; c=$GR_COMPOSE; mkdir -p "$GR_DIR/caches/modules-2"; echo new > "$GR_DIR/caches/modules-2/new.jar"; echo fromrun > "$GR_DIR/caches/modules-2/old.jar"; mkdir -p "$GR_DIR/wrapper/dists"; echo newwrap > "$GR_DIR/wrapper/dists/new.txt"; rc=0; gradle_cleanup || rc=$?; : > "$1/docker.log"; gradle_cleanup; printf '%s\n' "$d" "$c" "$GR_DIR" "$rc" > "$1/out3"
EOF
chmod +x "$tmp/p3.sh"

# run p3
bash "$tmp/p3.sh" "$tmp"

# read out3
d=$(sed -n 1p "$tmp/out3")
c=$(sed -n 2p "$tmp/out3")
g=$(sed -n 3p "$tmp/out3")
rc=$(sed -n 4p "$tmp/out3")
# checks
[ "$(cat "$SIS_CI_CACHE/gradle/caches/modules-2/new.jar")" = new ] || fail "3: new file not merged"
[ "$(cat "$SIS_CI_CACHE/gradle/caches/modules-2/old.jar")" = shared ] || fail "3: existing file overwritten"
[ "$(cat "$SIS_CI_CACHE/gradle/wrapper/dists/new.txt")" = newwrap ] || fail "3: wrapper not merged"
[ -e "$d" ] && fail "3: run dir not removed"
[ -e "$c" ] && fail "3: compose file not removed"
[ -n "$g" ] && fail "3: GR_DIR not cleared"
[ "$rc" -eq 0 ] || fail "4: second call failed"
[ -s "$tmp/docker.log" ] && fail "4: second call used docker"

# case5
cat > "$tmp/p5.sh" <<'EOF'
#!/usr/bin/env bash
cd "$1/w"; PATH=$1/bin:$PATH; source "$1/fn.sh"; CI=()
unset GR_DIR; gradle_cleanup; echo $? > "$1/out5"
EOF
chmod +x "$tmp/p5.sh"
: > "$tmp/docker.log"
before=$(find "$SIS_CI_CACHE" "$tmp/w" | wc -l)
bash "$tmp/p5.sh" "$tmp"
[ "$(cat "$tmp/out5")" -eq 0 ] || fail "5: cleanup exit code"
[ -s "$tmp/docker.log" ] && fail "5: docker.log not empty"
after=$(find "$SIS_CI_CACHE" "$tmp/w" | wc -l)
[ "$before" -eq "$after" ] || fail "5: file count changed"

# case6
cat > "$tmp/p6.sh" <<'EOF'
#!/usr/bin/env bash
cd "$1/w"; PATH=$1/bin:$PATH; source "$1/fn.sh"; CI=()
gradle_isolate >/dev/null; mkdir -p "$GR_DIR/locked"; touch "$GR_DIR/locked/f"; chmod 500 "$GR_DIR/locked"; gradle_cleanup; echo $$ > "$1/pid6"
EOF
chmod +x "$tmp/p6.sh"
: > "$tmp/docker.log"
bash "$tmp/p6.sh" "$tmp"
pid=$(cat "$tmp/pid6")
grep -qxF "run --rm -v $tmp/w/.ci-cache:/c alpine rm -rf /c/gradle-run-$pid" "$tmp/docker.log" || fail "6: no alpine rm fallback"
chmod -R u+rwx "$tmp/w"

echo "ci_local_gradle_test: ok"
