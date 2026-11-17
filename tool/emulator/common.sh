# shellcheck shell=bash
# Common emulator helper functions for lane scripts

EMU_IMAGE="${EMU_IMAGE:-sis-emulator:google-apis}"
EMU_NAME="${EMU_NAME:-sis-emu-lane}"
APP_ID="${APP_ID:-com.esd.sis.test}"
KVM_GID="${KVM_GID:-$(getent group kvm | cut -d: -f3)}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

emu_lock() {
  if [[ -n "${EMULATOR_LOCK:-}" ]]; then
    exec 9>"$EMULATOR_LOCK"
    flock 9
  fi
}

emu_start() {
  docker rm -f "$EMU_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$EMU_NAME" --device /dev/kvm --group-add "$KVM_GID" "$@" "$EMU_IMAGE" emulator -avd sis -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot -memory 4096 -cores 4 >/dev/null
  if ! timeout 300 docker exec "$EMU_NAME" sh -c 'adb wait-for-device; until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ]; do sleep 2; done'; then
    echo "emulator did not boot in 300 s" >&2
    return 1
  fi
  docker exec "$EMU_NAME" adb root >/dev/null
  docker exec "$EMU_NAME" adb wait-for-device
  docker exec "$EMU_NAME" sh -c 'sleep 2'
}

emu_stop() {
  docker rm -f "$EMU_NAME" >/dev/null 2>&1 || true
}

adbe() {
  docker exec "$EMU_NAME" adb "$@"
}

emu_install() {
  adbe install -r "$1" >/dev/null
}
