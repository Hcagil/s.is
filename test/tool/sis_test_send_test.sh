#!/usr/bin/env bash
# tool/sis_test_send.sh without a phone: a bad or missing command prints the
# usage line and fails; `login` without the state file
# (.private/sis_test_sender.json) dies naming it, before any device call;
# `login` with it: when the app has not read files/test_session.json after the
# launch, the tool removes it and prints "already signed in; token file removed";
# when the app read it, no such removal. The token never appears in a device
# command line, and the temp copies are removed on exit.
# The tool runs from a sandbox copy with a `docker` stand-in first on PATH that
# records every call and fails, so nothing here can reach sis-adb or a phone.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
box=$(mktemp -d); trap 'rm -rf "$box"' EXIT
mkdir -p "$box/tool" "$box/bin"
cp "$repo/tool/sis_test_send.sh" "$repo/tool/sis_ui_find.py" "$box/tool/"
# Stand-in for docker (and adb): records each call and fails, unless $box/device
# exists; then it succeeds, and `run-as ... ls files/test_session.json` succeeds
# only while $box/still exists (the app has not read the file).
cat >"$box/bin/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$box/calls"
[ -e "$box/device" ] || exit 1
case "\$*" in *"run-as com.esd.sis.test ls files/test_session.json"*) [ -e "$box/still" ];; *) exit 0;; esac
EOF
cp "$box/bin/docker" "$box/bin/adb"; printf '#!/bin/sh\n' >"$box/bin/sleep"
chmod +x "$box/bin/docker" "$box/bin/adb" "$box/bin/sleep"
export PATH="$box/bin:$PATH"
mkdir "$box/tmp"; export TMPDIR="$box/tmp"

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

mkdir -p "$box/.private"; touch "$box/device"
printf '{"refresh_token":"qa-refresh-1","url":"http://127.0.0.1:54321","anon_key":"qa-anon"}' >"$box/.private/sis_test_sender.json"
rm_tok='run-as com.esd.sis.test rm -f files/test_session.json'
for still in yes no; do
  : >"$box/calls"; if [ $still = yes ]; then touch "$box/still"; else rm -f "$box/still"; fi
  run login
  [ "$code" = 0 ] || fail "login (file left: $still): exit $code ($out)"
  if [ $still = yes ]; then
    [[ "$out" == *"already signed in; token file removed"* ]] || fail "login, file left: no 'already signed in' line ($out)"
    grep -qF "$rm_tok" "$box/calls" || fail "login, file left: the app's token file is not removed"
    # The removal comes after the check that found the file.
    [ "$(grep -nF -e 'ls files/test_session.json' -e "$rm_tok" "$box/calls" | cut -d: -f2- | grep -oE 'ls files|rm -f files' | tr '\n' ' ')" = "ls files rm -f files " ] \
      || fail "login, file left: check then remove, in that order: $(cat "$box/calls")"
  else
    [[ "$out" != *"already signed in"* ]] || fail "login, file read: says already signed in"
    ! grep -qF "$rm_tok" "$box/calls" || fail "login, file read: removed a file the app already consumed"
  fi
  ! grep -qF qa-refresh-1 "$box/calls" || fail "login (file left: $still): the token is in a device command line"
  grep -qF 'rm -f /data/local/tmp/sis_test_session.json' "$box/calls" || fail "login (file left: $still): /data/local/tmp copy not removed"
  grep -qF 'exec sis-adb rm -f /tmp/sis_test_session.json' "$box/calls" || fail "login (file left: $still): container copy not removed"
  [ -z "$(grep -rlF qa-refresh-1 "$box/tmp")" ] || fail "login (file left: $still): a host temp copy of the token is left"
done

if [ "$fails" -ne 0 ]; then echo "sis_test_send_test: $fails failed"; exit 1; fi
echo "sis_test_send_test: ok"
