#!/usr/bin/env bash
# SIS test sender admin: OWNER-RUN ONLY, in the owner's OWN terminal. Never through
# Claude Code (`!` runs in its shell, so the key would reach the AI session),
# and never export the key in the shell that starts Claude Code.
# Uses the service key. Every run is an authentication in the owner's account:
# report it. An AI session never runs this.
#
#   bootstrap   create push-sender@sis.test (a normal user, NOT a bot), allowlist row, mint its session
#   mint        new session for the existing account (the old one ends)
#   revoke      delete every session + the local token file
#   delete      allowlist row, sessions, then the user (cascades keys and push tokens)
#
# The token goes to .private/sis_test_sender.json (mode 600, git-ignored); only
# tool/sis_test_send.sh reads it.
#
# Environment (nothing is read from the repo; no key is ever printed or written):
#   SIS_URL                     https://<ref>.supabase.co  (or http://127.0.0.1:54321 locally)
#   SIS_SERVICE_KEY_FILE        file holding the service key. It must be mode 600 and owned
#                               by you, else exit 2. The key is NEVER read from an
#                               environment variable (SIS_SERVICE_KEY is ignored).
#   SIS_ANON_KEY                public key, written into the token file
#   SUPABASE_ACCESS_TOKEN_FILE  optional, with SIS_PROJECT_REF: file holding the Management
#                               API token (same mode/owner rule); SQL then goes through the
#                               Management API. Otherwise `docker exec` psql in
#                               SIS_DB_CONTAINER (default supabase_db_s.is): the local stack.
set -euo pipefail
set +x

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE="$ROOT/.private/sis_test_sender.json"
ACCT_EMAIL='push-sender@sis.test'
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
HALF=""   # set once the bot user exists but the bootstrap is not finished
trap 'rc=$?; unset SERVICE_KEY MGMT_TOKEN
      [ -z "$HALF" ] || [ "$rc" = 0 ] || echo "bootstrap stopped half-way: run tool/sis_test_account_admin.sh delete, then try again" >&2' EXIT

die() { echo "$*" >&2; exit 1; }
need() { [ -n "${!1:-}" ] || die "set $1 in your environment first"; }
# A secret comes only from a private file the owner names, never from the environment.
read_secret() { # <name of the variable holding the file path>
  local f=${!1:-}
  [ -n "$f" ] && [ -f "$f" ] || { echo "set $1 to a file holding the secret" >&2; exit 2; }
  [ "$(stat -c '%a %U' "$f")" = "600 $(id -un)" ] \
    || { echo "$f must be mode 600 and owned by you" >&2; exit 2; }
  tr -d '\n' <"$f"
}
unset SIS_SERVICE_KEY SUPABASE_ACCESS_TOKEN   # never accepted from the environment
need SIS_URL
SERVICE_KEY=$(read_secret SIS_SERVICE_KEY_FILE)
MGMT_TOKEN=""
[ -z "${SUPABASE_ACCESS_TOKEN_FILE:-}" ] || MGMT_TOKEN=$(read_secret SUPABASE_ACCESS_TOKEN_FILE)

# sql "<statements>": prints the result rows, aborts on error.
sql() {
  if [ -n "${SIS_PROJECT_REF:-}" ] && [ -n "$MGMT_TOKEN" ]; then
    local out
    out=$(SQL="$1" MGMT_TOKEN="$MGMT_TOKEN" python3 - <<'PY'
import json, os, urllib.request, sys
req = urllib.request.Request(
    "https://api.supabase.com/v1/projects/%s/database/query" % os.environ["SIS_PROJECT_REF"],
    data=json.dumps({"query": os.environ["SQL"]}).encode(),
    headers={"Authorization": "Bearer " + os.environ["MGMT_TOKEN"],
             "Content-Type": "application/json", "User-Agent": "sis-bot-admin"})
try:
    rows = json.load(urllib.request.urlopen(req, timeout=60))
except urllib.error.HTTPError as e:
    sys.exit("sql failed: %s %s" % (e.code, e.read().decode()[:300]))
for r in rows if isinstance(rows, list) else []:
    print("|".join("" if v is None else str(v) for v in r.values()))
PY
    ) || exit 1
    printf '%s' "$out"
  else
    printf '%s' "$1" | docker exec -i "${SIS_DB_CONTAINER:-supabase_db_s.is}" \
      psql -U postgres -v ON_ERROR_STOP=1 -At
  fi
}

# auth METHOD PATH JSON KEY: one Auth API call, body on stdout. The key and
# body go to curl as a config on stdin, never in argv.
AUTH_CFG='
import os
e = lambda s: s.replace("\\", "\\\\").replace("\"", "\\\"")
k = e(os.environ["CFG_KEY"])
print("header = \"apikey: %s\"" % k)
print("header = \"Authorization: Bearer %s\"" % k)
print("header = \"Content-Type: application/json\"")
print("data = \"%s\"" % e(os.environ["CFG_BODY"]))
'
auth() {
  CFG_KEY="$4" CFG_BODY="$3" python3 -c "$AUTH_CFG" \
    | curl -sS --max-time 30 --fail-with-body -K - -X "$1" "$SIS_URL$2"
}
jget() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

acct_id() {
  local id; id=$(sql "select id from auth.users where lower(email) = '$ACCT_EMAIL'")
  [[ $id =~ $UUID_RE ]] || die "no test account yet: run bootstrap"
  printf '%s' "$id"
}

# Magic link for the test account, verified at once: a session with no mail involved.
mint_session() { # <user id>
  need SIS_ANON_KEY
  local link hash tok
  link=$(auth POST /auth/v1/admin/generate_link "{\"type\":\"magiclink\",\"email\":\"$ACCT_EMAIL\"}" "$SERVICE_KEY")
  hash=$(printf '%s' "$link" | jget 'd["hashed_token"]')
  tok=$(auth POST /auth/v1/verify "{\"type\":\"magiclink\",\"token_hash\":\"$hash\"}" "$SIS_ANON_KEY")
  # The tokens reach python through the environment (not argv); nothing is printed.
  TOK="$tok" ANON="$SIS_ANON_KEY" URL="$SIS_URL" UID_="$1" STATE="$STATE" python3 - <<'PY'
import json, os, time, urllib.request
t = json.loads(os.environ["TOK"])
req = urllib.request.Request(os.environ["URL"] + "/rest/v1/rpc/activate_session", data=b"{}",
    headers={"apikey": os.environ["ANON"], "Authorization": "Bearer " + t["access_token"],
             "Content-Type": "application/json"})
if urllib.request.urlopen(req, timeout=30).read().strip() != b"true":
    raise SystemExit("activate_session refused the new session")
state = {"url": os.environ["URL"], "anon_key": os.environ["ANON"], "user_id": os.environ["UID_"],
         "refresh_token": t["refresh_token"],
         "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
path = os.environ["STATE"]
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
tmp = path + ".tmp"
with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    json.dump(state, f)
os.replace(tmp, path)
PY
}

cmd=${1:-}; [ $# -gt 0 ] && shift

case "$cmd" in
  bootstrap)
    [ "$(sql "select count(*) from auth.users where lower(email) = '$ACCT_EMAIL'")" = 0 ] || die "abort: the test account already exists"
    created=$(auth POST /auth/v1/admin/users "{\"email\":\"$ACCT_EMAIL\",\"email_confirm\":true,\"user_metadata\":{\"full_name\":\"SIS Test Sender\"}}" "$SERVICE_KEY")
    uid=$(printf '%s' "$created" | jget 'd["id"]')
    [[ $uid =~ $UUID_RE ]] || die "admin create returned no user id"
    HALF=1
    sql "insert into app_private.allowlist(email) values ('$ACCT_EMAIL') on conflict do nothing" >/dev/null
    [ "$(sql "select count(*) from app_private.bot_accounts where user_id = '$uid'")" = 0 ] || die "the test account must not be a bot"
    mint_session "$uid"
    HALF=""
    echo "user $uid, $ACCT_EMAIL, session minted"
    ;;
  mint)
    id=$(acct_id)
    mint_session "$id"; echo "session minted"
    ;;
  revoke)
    id=$(acct_id)
    sql "delete from auth.sessions where user_id = '$id'" >/dev/null
    shred -u "$STATE" 2>/dev/null || rm -f "$STATE"; echo revoked
    ;;
  delete)
    # Order matters: the allowlist row goes BEFORE the user, never after.
    id=$(acct_id)
    sql "delete from app_private.allowlist where email = '$ACCT_EMAIL';
         delete from auth.sessions where user_id = '$id';
         delete from auth.users where id = '$id'" >/dev/null
    shred -u "$STATE" 2>/dev/null || rm -f "$STATE"; echo deleted
    ;;
  *)
    die "usage: tool/sis_test_account_admin.sh bootstrap | mint | revoke | delete"
    ;;
esac
