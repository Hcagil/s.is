#!/usr/bin/env bash
# Phone half of a push: an FCM-shaped broadcast reaches SIS's receiver and the chat notification is
# posted with its picture, which SIS fetches over https from a server inside the lane (no public host).
# Usage: tool/emulator/push_check.sh [APK]. Mutation knobs: PIC_PATH (default pic.png), SKIP_CA=1.

set -euo pipefail
source "$(dirname "$0")/common.sh"

APK="${1:-$REPO/build/app/outputs/flutter-apk/app-debug.apk}"
PIC_PATH="${PIC_PATH:-pic.png}"
SKIP_CA="${SKIP_CA:-0}"

emu_lock
trap emu_stop EXIT

# Start emulator with required mounts
emu_start \
  -v "$REPO/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png:/srv/pic.png:ro" \
  -v "$APK:/tmp/app.apk:ro"

# Create self‑signed cert, start HTTPS server, and push cert to device
docker exec "$EMU_NAME" sh -c 'cd /tmp && openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 1 -subj /CN=10.0.2.2 -addext subjectAltName=IP:10.0.2.2 2>/dev/null && h=$(openssl x509 -subject_hash_old -noout -in c.pem) && cp c.pem $h.0 && echo $h > hash'
H=$(docker exec "$EMU_NAME" cat /tmp/hash)
docker exec -d -w /srv "$EMU_NAME" openssl s_server -accept 8443 -cert /tmp/c.pem -key /tmp/k.pem -WWW -quiet
# Install the APK first: the uid and prefs steps below need it.
emu_install /tmp/app.apk
adbe push /tmp/"$H".0 /data/local/tmp/ >/dev/null

# Bind CA into zygote's mount namespace unless skipped
if [[ "$SKIP_CA" -ne 1 ]]; then
  adbe shell "mkdir -p /data/local/tmp/ca && cp /apex/com.android.conscrypt/cacerts/* /data/local/tmp/ca/ && cp /data/local/tmp/$H.0 /data/local/tmp/ca/ && chmod 755 /data/local/tmp/ca && chmod 644 /data/local/tmp/ca/* && chcon -R u:object_r:system_file:s0 /data/local/tmp/ca && for p in \$(pidof zygote64) \$(pidof zygote); do nsenter --mount=/proc/\$p/ns/mnt -- mount --bind /data/local/tmp/ca /apex/com.android.conscrypt/cacerts; done"
fi

# Prepare app: force‑stop, grant permission, set shared prefs
adbe shell "am force-stop $APP_ID; pm grant $APP_ID android.permission.POST_NOTIFICATIONS"
U=$(adbe shell stat -c %u /data/data/$APP_ID | tr -d '\r')
adbe shell "mkdir -p /data/data/$APP_ID/shared_prefs && printf '%s\n' '<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\" ?>' '<map>' '<string name=\"flutter.sis.push_inbox_owner\">member-a</string>' '</map>' > /data/data/$APP_ID/shared_prefs/FlutterSharedPreferences.xml && chown -R $U:$U /data/data/$APP_ID/shared_prefs && chmod 771 /data/data/$APP_ID/shared_prefs && chmod 660 /data/data/$APP_ID/shared_prefs/*.xml && restorecon -R /data/data/$APP_ID/shared_prefs >/dev/null"

# Broadcast push intent
ID=6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d
B=https://10.0.2.2:8443
adbe shell "am broadcast -a com.google.android.c2dm.intent.RECEIVE -n $APP_ID/com.esd.sis.PushArrivalReceiver -f 32 --es message_id $ID --es conversation_id c-lane-chat --es title Lane --es body a_photo --es sender Lane_Sender --es chat Lane --es user_id member-a --es google.original_priority normal --es google.delivered_priority normal --es action_token v1.ticket.sig --es action_url $B/functions/v1/notification-action --es thumb_url $B/$PIC_PATH --es thumb_kind photo" >/dev/null

# Poll for notification
for i in {1..20}; do
  if adbe shell "dumpsys notification --noredact" | grep -E "uri=content://$APP_ID.captures/notif/$ID\.jpg, [^]]*type=image/jpeg" >/dev/null; then
    echo "PASS push: chat notification posted with its picture"
    exit 0
  fi
  sleep 1
done

# Failure path
echo "FAIL push: no chat notification with a picture" >&2
adbe shell "dumpsys notification --noredact" | grep -A30 "pkg=$APP_ID" | head -40
exit 1
