#!/usr/bin/env bash
# SIS Test Send: drives the second app com.esd.sis.test on the test phone
# through the running container sis-adb. It never reads a service key.
# Commands: build | install | login | status (the UI commands come next).
# It reads .private/sis_test_sender.json (written by tool/sis_test_account_admin.sh).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE="$ROOT/.private/sis_test_sender.json"
PKG=com.esd.sis.test
APK="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"

die() { echo "$*" >&2; exit 1; }
need_state() { [ -f "$STATE" ] || die "no $STATE: the owner runs tool/sis_test_account_admin.sh bootstrap"; }
adb() { docker exec sis-adb adb "$@"; }
state() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$STATE" "$1"; }
ui_dump() { adb shell uiautomator dump /sdcard/sis_ui.xml >/dev/null 2>&1 && adb exec-out cat /sdcard/sis_ui.xml; }
find_node() { python3 "$ROOT/tool/sis_ui_find.py" "$1" "$2"; }
# wait_tap <mode> <label>: poll the screen up to 20 s, tap the node found (flutter semantics labels, never fixed coordinates)
wait_tap() {
  local i xy
  for i in $(seq 20); do
    if xy=$(ui_dump | find_node "$1" "$2"); then adb shell input tap $xy; return 0; fi
    sleep 1
  done
  die "not found on screen: $2"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  build)
    need_state
    url=$(state url); anon=$(state anon_key); cd "$ROOT"
    # The test app never uses Google sign-in, so the web client id only has to be non-empty.
    LOCAL_UID=$(id -u) LOCAL_GID=$(id -g) docker compose run --rm -T -e SIS_TEST_APP=1 flutter \
      flutter build apk --debug --dart-define=SIS_TEST_LOGIN=true \
      "--dart-define=SUPABASE_URL=$url" "--dart-define=SUPABASE_PUBLISHABLE_KEY=$anon" \
      "--dart-define=GOOGLE_WEB_CLIENT_ID=${SIS_GOOGLE_WEB_CLIENT_ID:-unused-no-google-sign-in}"
    ;;
  install)
    [ -f "$APK" ] || die "build first"
    docker cp "$APK" sis-adb:/tmp/sis_test.apk
    rc=0; adb install -r -t /tmp/sis_test.apk || rc=$?
    docker exec sis-adb rm -f /tmp/sis_test.apk
    exit $rc
    ;;
  login)
    # Hands the refresh token to the app once; the app deletes the file after reading it.
    need_state
    tmp=$(mktemp); chmod 600 "$tmp"
    trap 'rm -f "$tmp"; docker exec sis-adb rm -f /tmp/sis_test_session.json >/dev/null 2>&1 || true; adb shell rm -f /data/local/tmp/sis_test_session.json >/dev/null 2>&1 || true' EXIT
    python3 -c "import json,sys;print(json.dumps({'refresh_token': json.load(open(sys.argv[1]))['refresh_token']}))" "$STATE" >"$tmp"
    docker cp "$tmp" sis-adb:/tmp/sis_test_session.json
    adb push /tmp/sis_test_session.json /data/local/tmp/sis_test_session.json >/dev/null
    adb shell run-as "$PKG" cp /data/local/tmp/sis_test_session.json files/test_session.json \
      || die "hand-over failed (is the debug test app installed?)"
    adb shell am force-stop "$PKG"
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
    # The app deletes the file when it reads it. If it is still there the app did not read it (already signed in, or slow): remove it.
    sleep 5
    if adb shell run-as "$PKG" ls files/test_session.json >/dev/null 2>&1; then
      adb shell run-as "$PKG" rm -f files/test_session.json
      echo "token file not read within 5 s (app already signed in, or slow): removed; run login again if needed"
    else
      echo "token handed over; the app signs in on start"
    fi
    ;;
  status)
    adb devices
    adb shell pm list packages "$PKG"
    ;;
  open)
    [ -n "${1:-}" ] || die "give the chat name"
    wait_tap label "$1"
    ;;
  send)
    text=${1:-}
    [[ $text =~ ^[A-Za-z0-9\ .,!?-]+$ ]] || die "send: letters, digits, space and . , ! ? - only"
    wait_tap label "Message|Mesaj"    # the composer hint, EN or TR
    adb shell input text "${text// /%s}"
    wait_tap label "Send|Gönder"    # the send button tooltip, EN or TR
    # the typed text now sits in a message row, not in the box
    for _ in $(seq 20); do
      if ui_dump | find_node msg "$text" >/dev/null; then echo sent; exit 0; fi
      sleep 1
    done
    die "the message did not appear"
    ;;
  lock)
    # SLEEP, not POWER: POWER toggles and can wake the phone.
    adb shell input keyevent KEYCODE_SLEEP
    ;;
  *)
    die "usage: tool/sis_test_send.sh build | install | login | status | open <chat name> | send <text> | lock"
    ;;
esac
