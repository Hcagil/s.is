#!/usr/bin/env bash
# tool/sis_test_send.sh without a phone: a bad or missing command prints the
# usage line and fails; `login` without the state file
# (.private/sis_test_sender.json) dies naming it, before any device call.
# The tool runs from a sandbox copy with a `docker` stand-in first on PATH that
# records every call and fails, so nothing here can reach sis-adb or a phone.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
box=$(mktemp -d); trap 'rm -rf "$box"' EXIT
mkdir -p "$box/tool" "$box/bin"
cp "$repo/tool/sis_test_send.sh" "$repo/tool/sis_ui_find.py" "$box/tool/"
printf '#!/bin/sh\necho "$*" >>"%s/calls"\nexit 1\n' "$box" >"$box/bin/docker"
cp "$box/bin/docker" "$box/bin/adb"; chmod +x "$box/bin/docker" "$box/bin/adb"
export PATH="$box/bin:$PATH"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
run() { code=0; out=$("$box/tool/sis_test_send.sh" "$@" 2>&1) || code=$?; }

for args in "" "frobnicate"; do
  # shellcheck disable=SC2086
  run $args
  [ "$code" != 0 ] || fail "'$args': exit 0"
  [[ "$out" == *"usage: tool/sis_test_send.sh build | install | login | status"* ]] || fail "'$args': no usage line ($out)"
done

run login
[ "$code" != 0 ] || fail "login without state: exit 0"
[[ "$out" == *".private/sis_test_sender.json"* ]] || fail "login without state: does not name the file ($out)"
[ ! -s "$box/calls" ] || fail "login without state touched docker/adb: $(cat "$box/calls")"

if [ "$fails" -ne 0 ]; then echo "sis_test_send_test: $fails failed"; exit 1; fi
echo "sis_test_send_test: ok"
