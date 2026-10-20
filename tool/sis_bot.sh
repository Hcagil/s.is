#!/usr/bin/env bash
# SIS Bot: lets an AI session act as the bot chat user, with ONLY the bot's own
# session (its refresh token in .private/sis_bot.json). It reads no other file.
#
#   tool/sis_bot.sh read [--since ISO8601]       new messages as JSON lines, then marks them read
#   tool/sis_bot.sh send <conversation_id> [text|-]
#   tool/sis_bot.sh start <user_id|@tag> [text|-]  open a 1:1 with a listed tester (and say hello)
#   tool/sis_bot.sh status
#   tool/sis_bot.sh revoke                         sign this session out everywhere, delete the file
#   tool/sis_bot.sh edit <message_id> <text|->    change one of the bot's own messages (within 6 hours)
#   tool/sis_bot.sh delete <message_id>           delete one of the bot's own messages for everyone
#   tool/sis_bot.sh attachments <message_id>      save that message's image into .private/bot-attachments/<id>/ (prints the paths)
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
case "$cmd" in read|send|start|status|revoke|edit|delete|attachments) ;;
  *) die 2 "usage: tool/sis_bot.sh read [--since ISO] | send <conversation_id> [text|-] | start <user_id|@tag> [text|-] | status | revoke | edit <message_id> <text|-> | delete <message_id> | attachments <message_id>" ;;
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
  edit) [ $# -ge 2 ] && [ -n "$2" ] || die 2 "edit needs a message id and the new text (or - for stdin)"; TEXT=$(body_arg "$2") ;;
  delete) [ $# -ge 1 ] || die 2 "delete needs a message id" ;;
  attachments) [ $# -ge 1 ] || die 2 "attachments needs a message id" ;;
esac

# 2. One run at a time.
exec 9>"$LOCK"
flock -w 30 9 || die 3 "busy: another sis_bot.sh run holds the lock"

WORK=$(mktemp -d); TMP="$WORK/body"; trap 'rm -rf "$WORK"' EXIT
URL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$FILE")
ANON=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["anon_key"])' "$FILE")
ME=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["user_id"])' "$FILE")
ACCESS=""
STATUS=0

# api METHOD PATH [JSON]: body in $TMP, HTTP status in $STATUS. Headers and
# body go to curl as a config on stdin, so no token ever shows in ps/argv.
CURL_CFG='
import os
e = lambda s: s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
print("header = \"apikey: %s\"" % e(os.environ["CFG_ANON"]))
print("header = \"Content-Type: application/json\"")
if os.environ["CFG_TOKEN"]:
    print("header = \"Authorization: Bearer %s\"" % e(os.environ["CFG_TOKEN"]))
if os.environ["CFG_BODY"]:
    print("data = \"%s\"" % e(os.environ["CFG_BODY"]))
'
api() {
  STATUS=$(CFG_ANON="$ANON" CFG_TOKEN="$ACCESS" CFG_BODY="${3:-}" python3 -c "$CURL_CFG" \
    | curl -sS --max-time 30 -K - -o "$TMP" -w '%{http_code}' -X "$1" "$URL$2") || die 1 "network error"
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
api POST "/auth/v1/token?grant_type=refresh_token" "$(RT="$RT" python3 -c 'import json,os;print(json.dumps({"refresh_token":os.environ["RT"]}))')"
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
    q="/rest/v1/messages?select=id,conversation_id,sender_id,body,created_at,reply_to,deleted,attachment_path,attachment_mime,attachment_duration_ms&order=created_at.asc&limit=500"
    [ -z "$since" ] || q="$q&created_at=gt.$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$since")"
    call GET "$q"
    NAMES="$names" python3 - "$TMP" "$WORK/convs" >"$WORK/out" <<'PY'
import json, os, sys
names = {p["user_id"]: p["display_name"] for p in json.loads(os.environ["NAMES"])}
convs = []
for m in json.load(open(sys.argv[1])):
    if m.get("deleted"):
        continue
    img = bool(m.get("attachment_path")) and m.get("attachment_duration_ms") is None and (m.get("attachment_mime") is None or m["attachment_mime"].startswith("image/"))
    body = (m["body"] + "\n" if m["body"] else "") + "[image " + m["id"] + "]" if img else m["body"]
    if m["conversation_id"] not in convs:
        convs.append(m["conversation_id"])
    print(json.dumps({"id": m["id"], "conversation_id": m["conversation_id"],
                      "sender_id": m["sender_id"], "sender_name": names.get(m["sender_id"]),
                      "body": body, "created_at": m["created_at"], "reply_to": m["reply_to"]},
                     ensure_ascii=False))
open(sys.argv[2], "w").write("\n".join(convs))
PY
    cat "$WORK/out"
    while read -r c || [ -n "$c" ]; do   # mark every chat shown as read (the list has no trailing newline)
      [ -z "$c" ] || call POST /rest/v1/rpc/mark_read "{\"conversation\":\"$c\"}"
    done <"$WORK/convs"
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

  edit)
    [[ $1 =~ $UUID_RE ]] || die 2 "not a message id"
    call POST /rest/v1/rpc/edit_message "$(python3 -c 'import json,sys;print(json.dumps({"message":sys.argv[1],"body":sys.argv[2]}))' "$1" "$TEXT")"
    echo "edited $1"
    ;;

  delete)
    [[ $1 =~ $UUID_RE ]] || die 2 "not a message id"
    call POST /rest/v1/rpc/delete_message "{\"message\":\"$1\"}"
    echo "deleted $1"
    ;;

  attachments)
    [[ $1 =~ $UUID_RE ]] || die 2 "not a message id"
    # RLS decides: the storage policy gives the bot only what it may read as a member.
    call POST /rest/v1/rpc/bot_ids '{}'   # access probe: refused while the bot is OFF
    call GET "/rest/v1/messages?select=attachment_path,attachment_name,attachment_mime,attachment_duration_ms&id=eq.$1&deleted=is.null"
    ACCESS="$ACCESS" URL="$URL" ANON="$ANON" python3 - "$TMP" "$1" "$ROOT/.private/bot-attachments" <<'PY'
import json, os, re, sys, urllib.error, urllib.parse, urllib.request
ACCESS, URL, ANON = os.environ["ACCESS"], os.environ["URL"], os.environ["ANON"]
def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)
rows = json.load(open(sys.argv[1]))
if not rows:
    fail("no such message (or not readable)")
row = rows[0]
path, name, mime = row.get("attachment_path"), row.get("attachment_name"), row.get("attachment_mime")
if not path or row.get("attachment_duration_ms") is not None or (mime and not mime.startswith("image/")):
    fail("that message has no image")
req = urllib.request.Request(URL + "/storage/v1/object/authenticated/attachments/" + urllib.parse.quote(path))
req.add_header("apikey", ANON)
req.add_header("Authorization", "Bearer " + ACCESS)
try:
    data = urllib.request.urlopen(req, timeout=60).read()
except urllib.error.HTTPError as e:
    fail("download failed (http %d)" % e.code)
except (urllib.error.URLError, OSError):
    fail("network error")
ext = ""
for cand in (os.path.splitext(name or "")[1], os.path.splitext(path)[1],
             {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}.get(mime or ""),
             ".jpg" if data[:3] == b"\xff\xd8\xff" else ".png" if data[:4] == b"\x89PNG" else
             ".webp" if data[:4] == b"RIFF" and data[8:12] == b"WEBP" else ".gif" if data[:4] == b"GIF8" else ""):
    if cand and re.fullmatch(r"\.[A-Za-z0-9]{1,5}", cand):
        ext = cand.lower()
        break
out = os.path.join(sys.argv[3], sys.argv[2])
os.makedirs(sys.argv[3], mode=0o700, exist_ok=True)
os.chmod(sys.argv[3], 0o700)
os.makedirs(out, mode=0o700, exist_ok=True)
os.chmod(out, 0o700)
dest = os.path.join(out, "1" + ext)
fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, "wb") as f:
    f.write(data)
print(os.path.abspath(dest))
PY
    ;;
esac
