#!/usr/bin/env bash
# SIS Bot: lets an AI session act as the bot chat user, with ONLY the bot's own
# session (its refresh token in .private/sis_bot.json). It reads no other file.
#
#   tool/sis_bot.sh read [--since ISO8601]       new messages as JSON lines, then marks them read
#   tool/sis_bot.sh send <conversation_id> [text|-]
#   tool/sis_bot.sh start <user_id|@tag> [text|-]  open a 1:1 with a listed tester (and say hello)
#   tool/sis_bot.sh status
#   tool/sis_bot.sh revoke                         sign this session out everywhere, delete the file
#
# Exit codes: 1 other error, 2 usage or unsafe state file, 3 session lost or
# superseded (the owner runs the admin tool's `mint`), 4 not permitted (not
# allowed, or the bot is switched off), 5 rate limited.
#
# Every run takes a lock, rotates the refresh token and writes the new one
# back atomically BEFORE any other call, so two runs never fight over a token.
# The access token lives in memory only; nothing secret is ever printed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FILE="$ROOT/.private/sis_bot.json"
LOCK="$ROOT/.private/sis_bot.lock"
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

die() { echo "$2" >&2; exit "$1"; }
cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in read|send|start|status|revoke) ;;
  *) die 2 "usage: tool/sis_bot.sh read [--since ISO] | send <conversation_id> [text|-] | start <user_id|@tag> [text|-] | status | revoke" ;;
esac

# Body text from the first remaining argument or stdin ('-' or missing).
body_arg() {
  local t=${1:--}
  [ "$t" = "-" ] && t=$(cat)
  [ -n "$t" ] && [ "${#t}" -le 4000 ] || die 2 "the message must be 1 to 4000 characters"
  printf '%s' "$t"
}

# 1. The state file must be ours and private.
[ -f "$FILE" ] || die 3 "no session file: the owner runs tool/sis_bot_admin.sh mint"
[ "$(stat -c '%a %U' "$FILE")" = "600 $(id -un)" ] || die 2 "$FILE must be mode 600 and owned by you"

# Read the body text BEFORE the lock so a slow stdin never holds it.
TEXT=""
case "$cmd" in
  send) [ $# -ge 1 ] || die 2 "send needs a conversation id"; TEXT=$(body_arg "${2:--}") ;;
  start) [ $# -ge 1 ] || die 2 "start needs a user id or @tag"
         if [ $# -ge 2 ]; then TEXT=$(body_arg "$2"); fi ;;
esac

# 2. One run at a time.
exec 9>"$LOCK"
flock -w 30 9 || die 3 "busy: another sis_bot.sh run holds the lock"

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
URL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$FILE")
ANON=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["anon_key"])' "$FILE")
ME=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["user_id"])' "$FILE")
ACCESS=""
STATUS=0

# api METHOD PATH [JSON]: body in $TMP, HTTP status in $STATUS.
api() {
  local args=(-sS --max-time 30 -o "$TMP" -w '%{http_code}' -X "$1" -H "apikey: $ANON" -H 'Content-Type: application/json')
  [ -z "$ACCESS" ] || args+=(-H "Authorization: Bearer $ACCESS")
  [ -z "${3:-}" ] || args+=(-d "$3")
  STATUS=$(curl "${args[@]}" "$URL$2") || die 1 "network error"
}
json() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));$1" "$TMP"; }
# api, then map any HTTP error to a plain sentence and an exit code.
call() {
  api "$@"
  [ "$STATUS" -lt 400 ] && return 0
  local code msg
  code=$(json 'print(d.get("code",""))' 2>/dev/null || true)
  msg=$(json 'print(d.get("message",""))' 2>/dev/null || true)
  case "$code" in
    42501) die 4 "not permitted (not allowed, or the bot is switched off)" ;;
    RLMT2) die 5 "rate limited, try again later" ;;
    *) die 1 "error ${code:-http $STATUS}: $msg" ;;
  esac
}

# 3. Refresh, and 4. persist the rotated token before anything else.
RT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["refresh_token"])' "$FILE")
api POST "/auth/v1/token?grant_type=refresh_token" "$(python3 -c 'import json,sys;print(json.dumps({"refresh_token":sys.argv[1]}))' "$RT")"
unset RT
[ "$STATUS" = 200 ] || die 3 "session lost: the owner runs tool/sis_bot_admin.sh mint"
ACCESS=$(json 'print(d["access_token"])')
json 'print(d["refresh_token"])' | python3 -c '
import json, os, sys, time
path = sys.argv[1]
d = json.load(open(path))
d["refresh_token"] = sys.stdin.read().strip()
d["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(d, f)
os.replace(tmp, path)' "$FILE"

# 5. This session must be the active one.
call POST /rest/v1/rpc/activate_session '{}'
[ "$(tr -d ' \n' <"$TMP")" = "true" ] || die 3 "session superseded: the owner runs tool/sis_bot_admin.sh mint"

send_message() { # conversation text
  local id payload
  id=$(python3 -c 'import uuid;print(uuid.uuid4())')
  payload=$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"conversation_id":sys.argv[2],"sender_id":sys.argv[3],"body":sys.argv[4]}))' "$id" "$1" "$ME" "$2")
  call POST /rest/v1/messages "$payload"
  echo "sent $id"
}

case "$cmd" in
  status) echo "ok user=$ME session active" ;;

  read)
    since=""
    if [ "${1:-}" = "--since" ]; then [ -n "${2:-}" ] || die 2 "--since needs a time"; since=$2; fi
    call POST /rest/v1/rpc/bot_ids '{}'   # access probe: refused while the bot is OFF
    call GET "/rest/v1/profiles?select=user_id,display_name"
    names=$(cat "$TMP")
    q="/rest/v1/messages?select=id,conversation_id,sender_id,body,created_at,reply_to,deleted&order=created_at.asc&limit=500"
    [ -z "$since" ] || q="$q&created_at=gt.$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$since")"
    call GET "$q"
    NAMES="$names" python3 - "$TMP" "$TMP.convs" >"$TMP.out" <<'PY'
import json, os, sys
names = {p["user_id"]: p["display_name"] for p in json.loads(os.environ["NAMES"])}
convs = []
for m in json.load(open(sys.argv[1])):
    if m.get("deleted"):
        continue
    if m["conversation_id"] not in convs:
        convs.append(m["conversation_id"])
    print(json.dumps({"id": m["id"], "conversation_id": m["conversation_id"],
                      "sender_id": m["sender_id"], "sender_name": names.get(m["sender_id"]),
                      "body": m["body"], "created_at": m["created_at"], "reply_to": m["reply_to"]},
                     ensure_ascii=False))
open(sys.argv[2], "w").write("\n".join(convs))
PY
    cat "$TMP.out"
    while read -r c; do   # mark every chat shown as read
      [ -z "$c" ] || call POST /rest/v1/rpc/mark_read "{\"conversation\":\"$c\"}"
    done <"$TMP.convs"
    rm -f "$TMP.out" "$TMP.convs"
    ;;

  send)
    [[ $1 =~ $UUID_RE ]] || die 2 "not a conversation id"
    send_message "$1" "$TEXT"
    ;;

  start)
    target=$1
    if [[ $target == @* ]]; then
      [[ $target =~ ^@[A-Za-z0-9_]{1,40}$ ]] || die 2 "not a tag"
      call POST /rest/v1/rpc/profiles_public '{}'
      target=$(json "t='${target#@}'.lower();print(next((p['user_id'] for p in d if (p.get('tag') or '').lower()==t),''))")
      [ -n "$target" ] || die 1 "no such tag"
    fi
    [[ $target =~ $UUID_RE ]] || die 2 "not a user id"
    call POST /rest/v1/rpc/start_direct_conversation "{\"other_user\":\"$target\"}"
    conv=$(json 'print(d)')
    echo "conversation $conv"
    [ -z "$TEXT" ] || send_message "$conv" "$TEXT"
    ;;

  revoke)
    api POST "/auth/v1/logout?scope=global"
    [ "$STATUS" = 204 ] || die 1 "revoke failed (http $STATUS); the owner runs tool/sis_bot_admin.sh revoke"
    shred -u "$FILE" 2>/dev/null || rm -f "$FILE"
    echo revoked
    ;;
esac
