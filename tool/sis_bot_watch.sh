#!/usr/bin/env bash
# Hourly tester inbox: checks for new tester messages with ONLY `tool/sis_bot.sh read`
# (the bot's own session; no key file, no other secret, no token printed), appends each
# to .private/tester-inbox.md and prints one short line per message. Silent otherwise.
# The bot's own messages are skipped by sender id (`status` prints user=<bot id>).
#
#   tool/sis_bot_watch.sh [interval_seconds]     default 3600; the first check runs at start
#
# State: .private/tester-inbox.seen holds the created_at of the newest message handled.
# .private/tester-inbox.bad holds hashes of malformed lines already reported (reported once).
# First run: it starts at "now", so old history is not dumped.
# sis_bot.sh takes .private/sis_bot.lock itself, so this script does not lock: a manual
# run waits for it (and it for the manual run). Exit 3 from sis_bot.sh means session lost
# OR lock busy for 30 s; the watcher prints one line and tries again next round.
# Exit 4/5/other: one line, keep looping; 5 (rate limited) doubles the next wait.
# SIS_BOT_CMD overrides the sis_bot.sh path (tests only).
#
#   tool/sis_bot_watch.sh --supervise [seconds]  restart the poll loop after a crash (backoff 5 s .. 5 min)
#   tool/sis_bot_watch.sh --once                 one check, then exit
#   tool/sis_bot_watch.sh --self-test            offline self-check (lock, cursor, PICTURE line, heartbeat)
# Interval: argument, else SIS_WATCH_INTERVAL, else 60 seconds. No AI call anywhere.
# One instance only: flock on .private/bot-watch.lock (the kernel frees it when the process
# dies, so a stale lock never blocks). A second start exits 1 at once.
# Heartbeat: .orchestra/bot-watch.heartbeat holds the ISO time of the last successful poll.
# A picture prints "PICTURE from <sender>, id <id>" and is saved by `sis_bot.sh attachments`
# into .private/bot-attachments/<id>/. The cursor moves only after a message is handled; a
# failed picture download keeps it, so the next poll retries.
set -uo pipefail
umask 077

ROOT=${SIS_WATCH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BOT="${SIS_BOT_CMD:-$ROOT/tool/sis_bot.sh}"
INBOX="$ROOT/.private/tester-inbox.md"
SEEN="$ROOT/.private/tester-inbox.seen"
BAD="$ROOT/.private/tester-inbox.bad"
MODE=loop
case "${1:-}" in --supervise|--once|--self-test) MODE=${1#--}; shift ;; esac
INTERVAL=${1:-${SIS_WATCH_INTERVAL:-60}}
HEART="$ROOT/.orchestra/bot-watch.heartbeat"
LOCK="$ROOT/.private/bot-watch.lock"
BACKOFF=0
mkdir -p "$ROOT/.private" "$ROOT/.orchestra"
[ -f "$SEEN" ] || date -u +%Y-%m-%dT%H:%M:%S.%6NZ >"$SEEN"

process() { # $1 = stdout of sis_bot.sh read, $2 = bot id
  printf '%s\n' "$1" | INBOX="$INBOX" SEEN="$SEEN" BOTID="$2" BAD="$BAD" BOT="$BOT" python3 -u -I -c '
import hashlib, json, os, re, subprocess, sys
def clean(s, keep_nl):
    return re.sub(r"[\x00-\x09\x0b-\x1f\x7f-\x9f]" if keep_nl else r"[\x00-\x1f\x7f-\x9f]", "", s)
def save(ts):  # cursor moves only after a message is handled; atomic
    tmp = os.environ["SEEN"] + ".tmp"
    with open(tmp, "w") as f:
        f.write(ts)
    os.replace(tmp, os.environ["SEEN"])
# A bad line has no usable time, so it is remembered by hash: reported once, never again.
badf = os.environ["BAD"]
known = set(open(badf).read().split()) if os.path.exists(badf) else set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        m = json.loads(line)
        ts = m["created_at"]
        sender_id = m["sender_id"]
        conv = m["conversation_id"]
        name = m.get("sender_name")
        body = m["body"] or ""
        if not all(isinstance(x, str) for x in (ts, sender_id, conv, body)):
            raise ValueError
    except (ValueError, KeyError, TypeError, AttributeError):
        h = hashlib.sha256(line.encode("utf-8", "replace")).hexdigest()
        if h not in known:
            known.add(h)
            open(badf, "a").write(h + "\n")
            print("watch: skipped a bad line")
        continue
    if sender_id == os.environ["BOTID"]:
        save(ts)
        continue
    who = clean(name if isinstance(name, str) and name else sender_id, False)
    body = clean(body, True)
    mid = m.get("id")
    pic = re.search(r"\[image ([0-9a-fA-F-]{36})\]\s*$", body)
    pic = bool(pic) and pic.group(1) == mid
    if pic:  # download first (sis_bot.sh attachments); on failure keep the cursor so the next poll retries
        print("PICTURE from %s, id %s" % (who, mid))
        if subprocess.run([os.environ["BOT"], "attachments", mid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            print("watch: picture download failed for %s, will retry" % mid)
            sys.exit(0)
    fence = "`" * max(3, max([len(x) for x in re.findall(r"`+", body)] + [0]) + 1)
    with open(os.environ["INBOX"], "a", encoding="utf-8") as f:
        f.write("## %s — %s\nconversation: %s\n\n%s\n%s\n%s\n\n" % (ts, who, conv, fence, body, fence))
    if not pic:
        print("%s: %s" % (who, body[:80].replace("\n", " ")))
    save(ts)
'
}

heartbeat() { # atomic: tmp + mv
  date -u +%Y-%m-%dT%H:%M:%SZ >"$HEART.tmp" && mv -f "$HEART.tmp" "$HEART"
}

check() {
  local out rc botid
  botid=$("$BOT" status 2>/dev/null | sed -n 's/.*user=\([^ ]*\).*/\1/p' | head -1)
  if [ -z "$botid" ]; then echo "watch: bot id unknown"; return; fi
  out=$("$BOT" read --since "$(cat "$SEEN")" 2>/dev/null)
  rc=$?
  case $rc in
    0) process "$out" "$botid" && heartbeat ;;
    3) echo "watch: bot session lost or busy (exit 3)" ;;
    4) echo "watch: bot not permitted or switched off (exit 4)" ;;
    5) echo "watch: rate limited (exit 5), backing off"; BACKOFF=1 ;;
    *) echo "watch: sis_bot.sh failed (exit $rc)" ;;
  esac
}

lock_or_exit() {
  [ -n "${SIS_WATCH_LOCKED:-}" ] && return 0  # the supervisor already holds it
  exec 8>"$LOCK"
  flock -n 8 || { echo "watch: already running (lock $LOCK); this copy exits" >&2; exit 1; }
  export SIS_WATCH_LOCKED=1
}

self_test() {
  local T fail=0 out h
  local PID=11111111-1111-4111-8111-111111111111 TS=2030-01-01T00:00:00.000000+00:00
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/.private"
  cat >"$T/bot.sh" <<'FAKE'
#!/usr/bin/env bash
d=$(dirname "$0")
echo "$*" >>"$d/calls"
case "$1" in
  status) echo "ok user=00000000-0000-4000-8000-000000b07b07 session active" ;;
  attachments) [ ! -f "$d/failpic" ] ;;
  read) cat "$d/mailbox" ;;
esac
FAKE
  chmod +x "$T/bot.sh"
  printf '{"id":"%s","conversation_id":"c","sender_id":"u","sender_name":"Bob","body":"hi\\n[image %s]","created_at":"%s","reply_to":null}\n' \
    "$PID" "$PID" "$TS" >"$T/mailbox"
  echo 2000-01-01T00:00:00Z >"$T/.private/tester-inbox.seen"
  run() { SIS_WATCH_ROOT=$T SIS_BOT_CMD=$T/bot.sh "$0" --once 2>&1; }
  t() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: want [$2] got [$3]"; fail=1; fi; }
  # lock: a live holder blocks a second start; once it is dead the lock is free again
  ( exec 7>"$T/.private/bot-watch.lock"; flock 7; exec sleep 30 ) & h=$!
  sleep 0.3
  out=$(run); t "second start exits at once with a message" yes "$([[ $out == *"already running"* ]] && echo yes || echo "$out")"
  kill $h; wait $h 2>/dev/null; sleep 0.2
  # failed download: PICTURE line printed, cursor kept, no heartbeat claim of the picture
  : >"$T/failpic"; out=$(run)
  t "picture line" "PICTURE from Bob, id $PID" "$(printf '%s\n' "$out" | head -1)"
  t "cursor kept on failed download" 2000-01-01T00:00:00Z "$(cat "$T/.private/tester-inbox.seen")"
  # good download: cursor moves, heartbeat is an ISO time
  rm "$T/failpic"; run >/dev/null
  t "cursor moved after handling" "$TS" "$(cat "$T/.private/tester-inbox.seen")"
  t "attachments called with the message id" yes "$(grep -qx "attachments $PID" "$T/calls" && echo yes || echo no)"
  t "heartbeat is ISO time" yes "$([[ $(cat "$T/.orchestra/bot-watch.heartbeat" 2>/dev/null) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && echo yes || echo no)"
  exit $fail
}

[ "$MODE" = self-test ] && self_test

lock_or_exit

if [ "$MODE" = once ]; then check; exit 0; fi

if [ "$MODE" = supervise ]; then
  wait_s=5
  while true; do
    start=$(date +%s)
    "$0" "$INTERVAL"
    echo "watch: poll loop ended (exit $?), restarting in ${wait_s}s" >&2
    sleep "$wait_s" 8>&-
    if [ $(( $(date +%s) - start )) -gt 300 ]; then wait_s=5; else wait_s=$((wait_s * 2 > 300 ? 300 : wait_s * 2)); fi
  done
fi

while true; do
  BACKOFF=0
  check
  if [ "$BACKOFF" = 1 ]; then sleep $((INTERVAL * 2)) 8>&-; else sleep "$INTERVAL" 8>&-; fi
done
