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
set -uo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOT="${SIS_BOT_CMD:-$ROOT/tool/sis_bot.sh}"
INBOX="$ROOT/.private/tester-inbox.md"
SEEN="$ROOT/.private/tester-inbox.seen"
BAD="$ROOT/.private/tester-inbox.bad"
INTERVAL=${1:-3600}
BACKOFF=0
mkdir -p "$ROOT/.private"
[ -f "$SEEN" ] || date -u +%Y-%m-%dT%H:%M:%S.%6NZ >"$SEEN"

process() { # $1 = stdout of sis_bot.sh read, $2 = bot id
  printf '%s\n' "$1" | INBOX="$INBOX" SEEN="$SEEN" BOTID="$2" BAD="$BAD" python3 -u -I -c '
import hashlib, json, os, re, sys
def clean(s, keep_nl):
    return re.sub(r"[\x00-\x09\x0b-\x1f\x7f-\x9f]" if keep_nl else r"[\x00-\x1f\x7f-\x9f]", "", s)
newest = ""
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
    newest = max(newest, ts)
    if sender_id == os.environ["BOTID"]:
        continue
    who = clean(name if isinstance(name, str) and name else sender_id, False)
    body = clean(body, True)
    fence = "`" * max(3, max([len(x) for x in re.findall(r"`+", body)] + [0]) + 1)
    with open(os.environ["INBOX"], "a", encoding="utf-8") as f:
        f.write("## %s — %s\nconversation: %s\n\n%s\n%s\n%s\n\n" % (ts, who, conv, fence, body, fence))
    print("%s: %s" % (who, body[:80].replace("\n", " ")))
if newest:
    open(os.environ["SEEN"], "w").write(newest)
'
}

check() {
  local out rc botid
  botid=$("$BOT" status 2>/dev/null | sed -n 's/.*user=\([^ ]*\).*/\1/p' | head -1)
  if [ -z "$botid" ]; then echo "watch: bot id unknown"; return; fi
  out=$("$BOT" read --since "$(cat "$SEEN")" 2>/dev/null)
  rc=$?
  case $rc in
    0) process "$out" "$botid" ;;
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
