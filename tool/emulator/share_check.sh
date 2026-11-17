#!/usr/bin/env bash
# An Android share intent (text + one image, the image owned by the media store, i.e. another app) reaches SIS through MainActivity and the native share channel;
# integration_test/share_intake_check_test.dart asserts what SIS received.
# Usage: tool/emulator/share_check.sh [APK]. Mutation knob: SHARE_MODE=both (default) | text | none. Logcat is saved to $SHARE_LOGCAT (default /tmp/share_check_logcat.txt).

set -euo pipefail
source "$(dirname "$0")/common.sh"

APK="${1:-$REPO/build/app/outputs/flutter-apk/app-debug.apk}"
SHARE_MODE="${SHARE_MODE:-both}"

emu_lock
cleanup() {
  adbe logcat -d > "${SHARE_LOGCAT:-/tmp/share_check_logcat.txt}" 2>/dev/null || true
  docker rm -f "$EMU_NAME-flutter" >/dev/null 2>&1 || true
  emu_stop
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Start emulator with required mounts
emu_start \
  -v "$REPO/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png:/srv/pic.png:ro"

# Put the image into the media store (proven)
adbe push /srv/pic.png /sdcard/Pictures/sis-share.png >/dev/null
adbe shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/sis-share.png" >/dev/null
for i in {1..10}; do
  MID=$(adbe shell "content query --uri content://media/external/images/media --projection _id --where \"_display_name='sis-share.png'\"" | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1)
  [[ -n "$MID" ]] && break
  sleep 1
done
if [[ -z "$MID" ]]; then
  echo 'FAIL share: picture not in the media store' >&2
  exit 1
fi

# Start the Flutter side detached, in the emulator's network namespace
docker run -d --name "$EMU_NAME-flutter" --network "container:$EMU_NAME" \
  -e TZ=JST-9 -e SIS_TEST_APP=1 \
  -v "$REPO":/workspace -w /workspace \
  -v sis-android-home:/home/ubuntu/.android \
  -v sis-android-sdk:/opt/android-sdk \
  -v sis-pub-cache:/home/ubuntu/.pub-cache \
  -v sis-gradle-cache:/home/ubuntu/.gradle \
  -v sis-m2-cache:/home/ubuntu/.m2 \
  "${FLUTTER_IMAGE:-$(basename "$REPO")-flutter}" \
  flutter test integration_test/share_intake_check_test.dart -d emulator-5554 >/dev/null

# Wait for readiness
for i in {1..600}; do
  if docker logs "$EMU_NAME-flutter" 2>&1 | grep SHARE_CHECK_READY >/dev/null; then
    break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$EMU_NAME-flutter")" != "true" ]; then
    echo "FAIL share: Flutter container stopped unexpectedly" >&2
    docker logs "$EMU_NAME-flutter" 2>&1 | tail -30 >&2
    exit 1
  fi
  sleep 1
done
if [ "$i" -eq 600 ]; then
  echo "FAIL share: timeout waiting for Flutter readiness" >&2
  docker logs "$EMU_NAME-flutter" 2>&1 | tail -30 >&2
  exit 1
fi

# Send the intent by SHARE_MODE
case "$SHARE_MODE" in
  both)
      # am start skips the ClipData copy a real share sheet makes, so the read grant rides on the intent data (-d); it runs as the shell user (su 2000) because Android refuses URI grants from root (UriGrantsManagerService: "the system cannot issue a Uri permission grant").
    adbe shell "su 2000 am start -n $APP_ID/com.esd.sis.MainActivity -a android.intent.action.SEND -t image/png -d content://media/external/images/media/$MID --es android.intent.extra.TEXT 'sis lane share' --eu android.intent.extra.STREAM content://media/external/images/media/$MID --grant-read-uri-permission" >/dev/null
    ;;
  text)
    adbe shell "am start -n $APP_ID/com.esd.sis.MainActivity -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT 'sis lane share'" >/dev/null
    ;;
  none)
    # send nothing
    ;;
  *)
    echo "FAIL share: unknown SHARE_MODE=$SHARE_MODE" >&2
    exit 1
    ;;
esac

# Wait for test completion
rc=$(timeout 300 docker wait "$EMU_NAME-flutter" || echo 124)
docker logs "$EMU_NAME-flutter" 2>&1 | grep -E 'SHARE_CHECK|All tests passed|Some tests failed|reason|Expected|Actual' | tail -20
if [ "$rc" -eq 0 ]; then
  echo 'PASS share: SIS received the shared text and image'
  exit 0
else
  echo "FAIL share: integration test exit $rc" >&2
  exit 1
fi
