#!/usr/bin/env bash
# Hourly tester inbox: checks for new tester messages with ONLY `tool/sis_bot.sh read`
# (the bot's own session; no key file, no other secret, no token printed), appends each
# to .private/tester-inbox.md and prints one short line per message. Silent otherwise.
# The bot's own messages (sender_name "SIS Destek") are ignored.
#
#   tool/sis_bot_watch.sh [interval_seconds]     default 3600; the first check runs at start
#
# State: .private/tester-inbox.seen holds the created_at of the newest message handled.
# First run: it starts at "now", so old history is not dumped.
# sis_bot.sh takes .private/sis_bot.lock itself, so this script does not lock: a manual
# run waits for it (and it for the manual run). Exit 3 from sis_bot.sh means session lost
# OR lock busy for 30 s; the watcher prints one line and tries again next round.
# Exit 4/5/other: one line, keep looping; 5 (rate limited) doubles the next wait.
# SIS_BOT_CMD overrides the sis_bot.sh path (tests only).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOT="${SIS_BOT_CMD:-$ROOT/tool/sis_bot.sh}"
INBOX="$ROOT/.private/tester-inbox.md"
SEEN="$ROOT/.private/tester-inbox.seen"
INTERVAL=${1:-3600}
BACKOFF=0
mkdir -p "$ROOT/.private"
[ -f "$SEEN" ] || date -u +%Y-%m-%dT%H:%M:%S.%6NZ >"$SEEN"

process() { # $1 = stdout of sis_bot.sh read
  printf '%s\n' "$1" | INBOX="$INBOX" SEEN="$SEEN" python3 -u -I -c '
import json, os, sys
newest = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    m = json.loads(line)
    newest = max(newest, m["created_at"])
    if m.get("sender_name") == "SIS Destek":
        continue
    who = m.get("sender_name") or m["sender_id"]
    body = m["body"] or ""
    with open(os.environ["INBOX"], "a", encoding="utf-8") as f:
        f.write("## %s — %s\nconversation: %s\n\n%s\n\n" % (m["created_at"], who, m["conversation_id"], body))
    print("%s: %s" % (who, body[:80].replace("\n", " ")))
if newest:
    open(os.environ["SEEN"], "w").write(newest)
'
}

check() {
  local out rc
  out=$("$BOT" read --since "$(cat "$SEEN")" 2>/dev/null)
  rc=$?
  case $rc in
    0) process "$out" ;;
    3) echo "watch: bot session lost or busy (exit 3)" ;;
    4) echo "watch: bot not permitted or switched off (exit 4)" ;;
    5) echo "watch: rate limited (exit 5), backing off"; BACKOFF=1 ;;
    *) echo "watch: sis_bot.sh failed (exit $rc)" ;;
  esac
}

while true; do
  BACKOFF=0
  check
  if [ "$BACKOFF" = 1 ]; then sleep $((INTERVAL * 2)); else sleep "$INTERVAL"; fi
done
