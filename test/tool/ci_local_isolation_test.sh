#!/usr/bin/env bash
# tool/ci_local.sh `sb_isolate` and `sb_cleanup` tests
# 1 free slot: id, project_id, 7 ports in 55100..55109, api/db ports, exported vars, original config unchanged, .temp not copied
# 2 a long dir name is cut to 30 chars
# 3 a slot whose lock is held is skipped
# 4 a slot with a busy port is skipped
# 5 every port busy: non-zero, no hang
# 6 cleanup stops only this project, removes only its volumes, network and copy; a second call does nothing
# 7 cleanup without SB_ID does nothing
set -euo pipefail
cd "$(dirname "$0")/../.."
script=$PWD/tool/ci_local.sh
tmp=$(mktemp -d); trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# extract functions
awk '/^sb_isolate\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$script" > "$tmp/fn.sh"
awk '/^sb_cleanup\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$script" >> "$tmp/fn.sh"
grep -q '^sb_isolate()' "$tmp/fn.sh" && grep -q '^sb_cleanup()' "$tmp/fn.sh" || fail "functions not found"

# fake bin
mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "$TMPD/docker.log"
if [ "$1 $2" = "volume ls" ]; then
  f=$(printf '%s\n' "$@" | sed -n 's/^name=//p')
  grep -F -- "$f" "$TMPD/volumes" || true
fi
EOF
chmod +x "$tmp/bin/docker"
cat > "$tmp/bin/ss" <<'EOF'
#!/bin/bash
cat "$TMPD/ss.out"
EOF
chmod +x "$tmp/bin/ss"

export TMPD=$tmp
export XDG_RUNTIME_DIR=$tmp/run
mkdir -p "$tmp/run"; printf '%s\n' supabase_db_s.is supabase_storage_s.is > "$tmp/volumes"

# helpers
fixture() {
  rm -rf "$tmp/$1"
  mkdir -p "$tmp/$1/supabase/.temp" "$tmp/$1/supabase/tests"
  cp supabase/config.toml "$tmp/$1/supabase/"
  touch "$tmp/$1/supabase/.temp/x" "$tmp/$1/supabase/tests/a.sql"
  : > "$tmp/docker.log"
  : > "$tmp/ss.out"
}
iso() {
  (cd "$1" && PATH=$tmp/bin:$PATH && source "$tmp/fn.sh" && sb_isolate && printf 'SB_ID=%s\nCOMPOSE_FILE=%s\nSUPABASE_TEST_URL=%s\nSUPABASE_TEST_DB_URL=%s\nSIS_DB_CONTAINER=%s\nSIS_URL=%s\n' "$SB_ID" "$COMPOSE_FILE" "$SUPABASE_TEST_URL" "$SUPABASE_TEST_DB_URL" "$SIS_DB_CONTAINER" "$SIS_URL" > "$tmp/vars" )
}
var() { sed -n "s/^$1=//p" "$tmp/vars"; }
ports() { grep -E '^ *(port|shadow_port) *= *[0-9]+' "$1" | grep -oE '[0-9]+$'; }
secport() { awk -v s="[$2]" '$0==s{i=1;next} /^\[/{i=0} i&&$1=="port"{print $3; exit}' "$1"; }
inrange() { local lo=$1 n=0 p; while read -r p; do [ "$p" -ge "$lo" ] && [ "$p" -le $((lo+9)) ] || return 1; n=$((n+1)); done; [ "$n" = 7 ]; }

# 1
fixture "My Work.Tree_X"
iso "$tmp/My Work.Tree_X"
id="ci-my-work-tree-x-$$"
var SB_ID | grep -qxF "$id" || fail "1: SB_ID"
c="$tmp/My Work.Tree_X/.ci-cache/sb-$id/supabase/config.toml"
grep -q "^project_id = \"$id\"" "$c" || fail "1: project_id"
ports "$c" | sort -u | wc -l | grep -qxF 7 || fail "1: ports count"
ports "$c" | inrange 55100 || fail "1: ports not 7 in 55100..55109"
secport "$c" api | grep -qxF 55100 || fail "1: api port"
secport "$c" db | grep -qxF 55101 || fail "1: db port"
var COMPOSE_FILE | grep -qxF "compose.yaml:$tmp/My Work.Tree_X/.ci-cache/sb-$id/compose.sb.yaml" || fail "1: compose file"
[ -f "$tmp/My Work.Tree_X/.ci-cache/sb-$id/compose.sb.yaml" ] || fail "1: compose.sb.yaml missing"
grep -q -- --workdir "$tmp/My Work.Tree_X/.ci-cache/sb-$id/compose.sb.yaml" || fail "1: --workdir missing"
var SUPABASE_TEST_URL | grep -qxF "http://host.docker.internal:55100" || fail "1: test url"
var SUPABASE_TEST_DB_URL | grep -qxF "postgresql://postgres:postgres@host.docker.internal:55101/postgres" || fail "1: db url"
var SIS_DB_CONTAINER | grep -qxF "supabase_db_$id" || fail "1: db container"
var SIS_URL | grep -qxF "http://127.0.0.1:55100" || fail "1: sis url"
cmp "$tmp/My Work.Tree_X/supabase/config.toml" supabase/config.toml || fail "1: config mismatch"
[ ! -e "$tmp/My Work.Tree_X/.ci-cache/sb-$id/supabase/.temp" ] || fail "1: .temp was copied"
[ -d "$tmp/My Work.Tree_X/.ci-cache/sb-$id/supabase/tests" ] && [ -f "$tmp/My Work.Tree_X/.ci-cache/sb-$id/supabase/tests/a.sql" ] || fail "1: tests missing"
! grep -q stop "$tmp/docker.log" || fail "1: docker stop called"

# 2
fixture "abcdefghijklmnopqrstuvwxyz0123456789XYZ"
iso "$tmp/abcdefghijklmnopqrstuvwxyz0123456789XYZ"
id="ci-abcdefghijklmnopqrstuvwxyz0123-$$"
var SB_ID | grep -qxF "$id" || fail "2: SB_ID"

# 3
fixture "w3"
exec 8>"$tmp/run/sis-ci-slot-0.lock"
flock -n 8
iso "$tmp/w3"
exec 8>&-
id=$(var SB_ID); c="$tmp/w3/.ci-cache/sb-$id/supabase/config.toml"
secport "$c" api | grep -qxF 55110 || fail "3: api port"
ports "$c" | inrange 55110 || fail "3: ports not 7 in 55110..55119"

# 4
fixture "w4"
echo "LISTEN 0 4096 0.0.0.0:55103 0.0.0.0:*" > "$tmp/ss.out"
iso "$tmp/w4"
id=$(var SB_ID); secport "$tmp/w4/.ci-cache/sb-$id/supabase/config.toml" api | grep -qxF 55110 || fail "4: api port"

# 5
fixture "w5"
for p in $(seq 55100 56099); do echo "LISTEN 0 4096 0.0.0.0:$p 0.0.0.0:*"; done > "$tmp/ss.out"
rc=0; timeout 60 bash -c 'cd "$1" && PATH=$2/bin:$PATH && source "$2/fn.sh" && sb_isolate' _ "$tmp/w5" "$tmp" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "5: sb_isolate succeeded with every port busy"
[ "$rc" != 124 ] || fail "5: sb_isolate hung"

# 6
fixture "w6"
(
  cd "$tmp/w6" && PATH=$tmp/bin:$PATH && source "$tmp/fn.sh" && sb_isolate
  printf '%s\n' "supabase_db_$SB_ID" "supabase_storage_$SB_ID" >> "$tmp/volumes"
  echo "$SB_ID" > "$tmp/id"
  : > "$tmp/docker.log"
  sb_cleanup
  cp "$tmp/docker.log" "$tmp/log1"
  : > "$tmp/docker.log"
  sb_cleanup
  cp "$tmp/docker.log" "$tmp/log2"
)
id=$(cat "$tmp/id")
grep -qxF "compose run --rm supabase stop --project-id $id --no-backup" "$tmp/log1" || fail "6: stop called"
! grep -q -- --all "$tmp/log1" || fail "6: --all present"
! grep 'volume rm' "$tmp/log1" | grep -q 's\.is' || fail "6: an s.is volume was removed"
grep 'volume rm' "$tmp/log1" | grep -q "supabase_db_$id" || fail "6: db volume missing"
grep 'volume rm' "$tmp/log1" | grep -q "supabase_storage_$id" || fail "6: storage volume missing"
grep -qxF "network rm supabase_network_$id" "$tmp/log1" || fail "6: network rm missing"
grep 'alpine' "$tmp/log1" | grep -q "sb-$id" || fail "6: no alpine rm of sb-$id"
[ ! -s "$tmp/log2" ] || fail "6: log2 not empty"

# 7
: > "$tmp/docker.log"
(
  cd "$tmp" && PATH=$tmp/bin:$PATH && source "$tmp/fn.sh" && unset SB_ID && sb_cleanup
)
[ ! -s "$tmp/docker.log" ] || fail "7: docker.log not empty"

echo "ci_local_isolation_test: ok"
