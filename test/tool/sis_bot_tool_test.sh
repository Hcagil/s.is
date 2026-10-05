#!/usr/bin/env bash
# Integration test of tool/sis_bot.sh and tool/sis_bot_admin.sh against the
# LOCAL Supabase stack (run by CI's database job and tool/ci_local.sh after
# `supabase start`). It never touches the repository's own .private/: both
# tools are copied into a sandbox, so their state file lives there.
#
# Covers: the admin tool's key file (SIS_SERVICE_KEY_FILE: unset, env-only,
# missing, mode 644, foreign owner -> exit 2); bootstrap and list-add; read, send, start (by id and @tag); the
# token rotating on every run and the old one refused after the reuse
# interval; two parallel runs; exit 2 (usage, mode 644, foreign owner), 3 (missing file,
# busy lock, superseded by a second sign-in, revoked), 4 (unlisted chat,
# unlisted user, OFF), 5 (rate limited); revoke; the sign-up hook refusing a
# public sign-up of the bot address; and probes with the bot's REAL JWT of
# storage, avatars, profile update, add_members, set_admin and Realtime.
# While the tools run, a poller checks that no token or key is in any argv and
# that sis_bot.sh keeps its temp files in one mode-700 directory it removes.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
export LOCAL_UID="${LOCAL_UID:-$(id -u)}" LOCAL_GID="${LOCAL_GID:-$(id -g)}"
DB="${SIS_DB_CONTAINER:-supabase_db_s.is}"
# CI passes its compose files here (the flutter image is built with them).
read -r -a COMPOSE <<<"${SIS_BOT_TEST_COMPOSE:-docker compose}"

env_out=$("${COMPOSE[@]}" run --rm supabase status -o env 2>/dev/null)
val() { sed -n "s/^$1=\"\(.*\)\"/\1/p" <<<"$env_out"; }
export SIS_URL=http://127.0.0.1:54321
SKEY=$(val SERVICE_ROLE_KEY)   # the test's own; the admin tool gets it only from a file
export SIS_ANON_KEY; SIS_ANON_KEY=$(val ANON_KEY)
PUBLISHABLE=$(val PUBLISHABLE_KEY)
[ -n "$SKEY" ] && [ -n "$SIS_ANON_KEY" ] || { echo "local stack not running"; exit 1; }
# Never the Management API from here, and no key in the environment.
unset SIS_PROJECT_REF SUPABASE_ACCESS_TOKEN SUPABASE_ACCESS_TOKEN_FILE SIS_SERVICE_KEY

BOX=$(mktemp -d); mkdir -p "$BOX/tool"; chmod 700 "$BOX"
KEYFILE="$BOX/service_key"; (umask 077; printf '%s\n' "$SKEY" >"$KEYFILE")
export SIS_SERVICE_KEY_FILE="$KEYFILE"
cp tool/sis_bot.sh tool/sis_bot_admin.sh "$BOX/tool/"
BOT="$BOX/tool/sis_bot.sh"; ADMIN="$BOX/tool/sis_bot_admin.sh"; STATE="$BOX/.private/sis_bot.json"
DOM=sisbot-tool.test
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "not ok - $1"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
# expect_exit CODE NAME cmd...
expect_exit() {
  local want=$1 name=$2; shift 2
  local got=0; "$@" >"$BOX/out" 2>"$BOX/err" || got=$?
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"
  else bad "$name: want exit $want, got $got: $(tr '\n' ' ' <"$BOX/err" | head -c 300)"; fi
}
# watch WANT NAME SECRET cmd...: runs cmd (with TMPDIR=$TMPD) while a poller
# samples what it puts in TMPDIR and every process's argv. Then checks the exit
# code, that SECRET never appeared in any argv (S-3), and, for tool/sis_bot.sh,
# that no temp file outlives the run and every temp file sat inside a single
# mode-700 directory (S-2). /tmp is diffed too, in case TMPDIR is not honoured.
TMPD="$BOX/tmp"; mkdir -m 700 "$TMPD"
tmp_top() { find /tmp -mindepth 1 -maxdepth 1 -user "$(id -u)" 2>/dev/null | LC_ALL=C sort; }
watch() {
  local want=$1 name=$2 secret=$3; shift 3
  printf '%s\n' "$secret" >"$BOX/pats"
  tmp_top >"$BOX/tmp_before"; : >"$BOX/seen"; : >"$BOX/argv_hits"
  ( while :; do
      find "$TMPD" -mindepth 1 -printf '%d %m %y %P\n' >>"$BOX/seen" 2>/dev/null || true
      grep -lsF -f "$BOX/pats" /proc/[0-9]*/cmdline >>"$BOX/argv_hits" 2>/dev/null || true
    done ) & local poller=$!
  local got=0; TMPDIR="$TMPD" "$@" >"$BOX/out" 2>"$BOX/err" || got=$?
  kill "$poller" 2>/dev/null || true; wait "$poller" 2>/dev/null || true
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"
  else bad "$name: want exit $want, got $got: $(tr '\n' ' ' <"$BOX/err" | head -c 300)"; fi
  check "$name: the secret was never in a process argv" test ! -s "$BOX/argv_hits"
  [ "$1" = "$BOT" ] || return 0
  local left; left=$( (ls -A "$TMPD"; tmp_top | LC_ALL=C comm -13 "$BOX/tmp_before" -) | tr '\n' ' ')
  check "$name: no temp file left behind${left:+ ($left)}" test -z "$left"
  local tops; tops=$(awk '$1 == 1' "$BOX/seen" | sort -u)
  check "$name: temp files only inside one mode-700 directory ($(wc -l <<<"$tops") seen: $(tr '\n' ' ' <<<"$tops"))" \
    awk -v n="$(awk '$1 == 1 {print $4}' "$BOX/seen" | sort -u | wc -l)" \
      'n > 1 {exit 1} $1 == 1 && !($2 == 700 && $3 == "d") {exit 1}' "$BOX/seen"
}
sql() { docker exec -i "$DB" psql -U postgres -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
hdr=(-H "apikey: $SKEY" -H "Authorization: Bearer $SKEY" -H 'content-type: application/json')
create_user() {  # email name -> id
  curl -fsS -X POST "$SIS_URL/auth/v1/admin/users" "${hdr[@]}" \
    -d "{\"email\":\"$1\",\"email_confirm\":true,\"user_metadata\":{\"full_name\":\"$2\"}}" | jq -r .id
}
token_for() {  # email -> access token (magic link, then activate_session)
  local th tok
  th=$(curl -fsS -X POST "$SIS_URL/auth/v1/admin/generate_link" "${hdr[@]}" \
         -d "{\"type\":\"magiclink\",\"email\":\"$1\"}" | jq -r '.hashed_token // .properties.hashed_token')
  tok=$(curl -fsS -X POST "$SIS_URL/auth/v1/verify" -H "apikey: $SIS_ANON_KEY" -H 'content-type: application/json' \
         -d "{\"type\":\"magiclink\",\"token_hash\":\"$th\"}" | jq -r .access_token)
  rpc "$tok" activate_session '{}' >/dev/null
  echo "$tok"
}
rpc() {  # token fn json -> body; HTTP status in $BOX/code
  curl -sS -o "$BOX/body" -w '%{http_code}' -X POST "$SIS_URL/rest/v1/rpc/$2" -H "apikey: $SIS_ANON_KEY" \
    -H "Authorization: Bearer $1" -H 'content-type: application/json' -d "$3" >"$BOX/code"
  cat "$BOX/body"
}
upload() {  # token bucket key -> http code
  printf 'x' | curl -sS -o /dev/null -w '%{http_code}' -X POST "$SIS_URL/storage/v1/object/$2/$3" \
    -H "apikey: $SIS_ANON_KEY" -H "Authorization: Bearer $1" -H 'content-type: image/jpeg' --data-binary @-
}
cleanup() {
  [ -f "$STATE" ] && "$ADMIN" delete >/dev/null 2>&1 || true
  sql "delete from auth.users where email = 'sis-destek-bot@example.com';
       delete from public.conversations where id in (select conversation_id from public.conversation_members cm
         join auth.users u on u.id = cm.user_id where u.email like '%@$DOM');
       delete from app_private.allowlist where email like '%@$DOM';
       delete from auth.users where email like '%@$DOM';
       insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing;" \
    >/dev/null 2>&1 || true  # the seed allowlists the bot address; leave it as found
  rm -rf "$BOX"
}
trap cleanup EXIT

# 0 clean slate ------------------------------------------------------------------
sql "delete from auth.users where email = 'sis-destek-bot@example.com';
     delete from app_private.allowlist where email like '%@$DOM';
     delete from auth.users where email like '%@$DOM';" >/dev/null

# 1 the static guard: the bot tool holds no admin credential ---------------------
check "tool/sis_bot.sh names no service key or access token" \
  bash -c "! grep -nE 'service_role|SERVICE_ROLE|SERVICE_KEY|supabase-access-token' '$BOT'"

# 2 the sign-up hook refuses a public sign-up of the bot address ------------------
sql "insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing" >/dev/null
code=$(curl -sS -o "$BOX/body" -w '%{http_code}' -X POST "$SIS_URL/auth/v1/signup" -H "apikey: $SIS_ANON_KEY" \
         -H 'content-type: application/json' -d '{"email":"sis-destek-bot@example.com","password":"sisbot-probe-pw-1"}')
check "a public sign-up of the bot address is refused (HTTP $code)" test "$code" -ge 400
check "and no account was created" test "$(sql "select count(*) from auth.users where email = 'sis-destek-bot@example.com'")" = 0

# 3 fixtures: ann (Debug admin), bob (listed, in Debug), cat (NOT listed, in
#   Debug), dan (listed, shares nothing) ----------------------------------------
sql "insert into app_private.allowlist(email) values ('ann@$DOM'),('bob@$DOM'),('cat@$DOM'),('dan@$DOM')" >/dev/null
ANN=$(create_user "ann@$DOM" Ann); BOB=$(create_user "bob@$DOM" Bob)
CAT=$(create_user "cat@$DOM" Cat); DAN=$(create_user "dan@$DOM" Dan)
sql "insert into app_private.tag_finds(finder, found_id) values ('$ANN','$BOB'),('$ANN','$CAT')" >/dev/null
ANN_JWT=$(token_for "ann@$DOM")
DEBUG=$(rpc "$ANN_JWT" start_group_conversation "{\"title\":\"Debug\",\"members\":[\"$BOB\",\"$CAT\"]}" | jq -r .)
G2=$(rpc "$ANN_JWT" start_group_conversation "{\"title\":\"Not Debug\",\"members\":[\"$BOB\"]}" | jq -r .)
[[ $DEBUG =~ ^[0-9a-f-]{36}$ && $G2 =~ ^[0-9a-f-]{36}$ ]] || { echo "fixture groups failed: $DEBUG $G2"; exit 1; }

# 4 the admin tool takes the service key only from a private file (exit 2) -------
# Each refusal must name the variable or the file it is about.
refused() {  # NAME VAR FILE env-args...: exit 2, naming VAR or FILE (admin `list`)
  local name=$1 var=$2 file=$3; shift 3
  expect_exit 2 "admin refuses: $name" env "$@" "$ADMIN" list
  check "admin refuses: $name: the message names $var or the file" \
    grep -qF -e "$var" -e "$file" "$BOX/err" "$BOX/out"
}
refused "SIS_SERVICE_KEY_FILE unset" SIS_SERVICE_KEY_FILE SIS_SERVICE_KEY_FILE -u SIS_SERVICE_KEY_FILE
refused "the key only in SIS_SERVICE_KEY" "set SIS_SERVICE_KEY_FILE" "set SIS_SERVICE_KEY_FILE" \
  -u SIS_SERVICE_KEY_FILE SIS_SERVICE_KEY="$SKEY"
refused "a missing key file" SIS_SERVICE_KEY_FILE "$BOX/no_such_key" SIS_SERVICE_KEY_FILE="$BOX/no_such_key"
cp "$KEYFILE" "$BOX/key_644"; chmod 644 "$BOX/key_644"
refused "a key file at mode 644" SIS_SERVICE_KEY_FILE "$BOX/key_644" SIS_SERVICE_KEY_FILE="$BOX/key_644"
# A file owned by someone else needs root to make: a throwaway container does it.
docker run --rm -v "$BOX:/b" --entrypoint sh "$(docker inspect "$DB" --format '{{.Config.Image}}')" \
  -c 'cp /b/service_key /b/key_other && chown 4242:4242 /b/key_other && chmod 600 /b/key_other'
refused "a key file owned by another user" SIS_SERVICE_KEY_FILE "$BOX/key_other" SIS_SERVICE_KEY_FILE="$BOX/key_other"
refused "a Management API token file at mode 644" SUPABASE_ACCESS_TOKEN_FILE "$BOX/key_644" \
  SIS_PROJECT_REF=sisbottest SUPABASE_ACCESS_TOKEN_FILE="$BOX/key_644"

# 4b bootstrap, list --------------------------------------------------------------
expect_exit 0 "admin bootstrap" "$ADMIN" bootstrap --debug "$DEBUG"
BOT_ID=$(sql "select id from auth.users where email = 'sis-destek-bot@example.com'")
check "the bot's profile is SIS Destek / sis_destek" \
  test "$(sql "select display_name || '|' || tag from public.profiles where user_id = '$BOT_ID'")" = "SIS Destek|sis_destek"
check "the bot is ON after bootstrap" test "$(sql "select enabled from app_private.bot_accounts where user_id = '$BOT_ID'")" = t
check "the state file is mode 600" test "$(stat -c %a "$STATE")" = 600
check "the state file holds no admin credential" \
  bash -c "! grep -qE 'service_role|SERVICE_ROLE|supabase-access-token' '$STATE' && ! grep -qF -f '$KEYFILE' '$STATE'"
check "the state file carries the anon key and the bot's id" \
  test "$(jq -r '.anon_key + "|" + .user_id' "$STATE")" = "$SIS_ANON_KEY|$BOT_ID"
expect_exit 0 "admin list-add by email" "$ADMIN" list-add "bob@$DOM"
expect_exit 0 "admin list-add by id" "$ADMIN" list-add "$DAN"
"$ADMIN" list >"$BOX/list" 2>&1 || true
expect_exit 0 "SIS_SERVICE_KEY is ignored when the key file is set" env SIS_SERVICE_KEY=not-the-key "$ADMIN" list
check "admin list shows both contacts" bash -c "grep -q '$BOB' '$BOX/list' && grep -q '$DAN' '$BOX/list'"

# 5 read, send, start ---------------------------------------------------------------
# The bot joins Debug from now on (history_from = now()), so ann writes after.
curl -fsS -o /dev/null -X POST "$SIS_URL/rest/v1/messages" -H "apikey: $SIS_ANON_KEY" -H "Authorization: Bearer $ANN_JWT" \
  -H 'content-type: application/json' -d "{\"conversation_id\":\"$DEBUG\",\"sender_id\":\"$ANN\",\"body\":\"hello from ann\"}"
t0=$(jq -r .refresh_token "$STATE")
expect_exit 0 "status" "$BOT" status
watch 0 "read" "$t0" "$BOT" read
check "read prints Debug's message as JSON lines" \
  bash -c "grep -q 'hello from ann' '$BOX/out' && grep -v '^\$' '$BOX/out' | jq -e . >/dev/null"
t1=$(jq -r .refresh_token "$STATE")
check "each run rotates the refresh token" test "$t0" != "$t1"
expect_exit 0 "send to Debug" "$BOT" send "$DEBUG" "hello from the bot"
check "the message is in Debug, from the bot" \
  test "$(sql "select count(*) from public.messages where conversation_id = '$DEBUG' and sender_id = '$BOT_ID' and body = 'hello from the bot'")" = 1
expect_exit 0 "send from stdin" bash -c "printf 'piped body' | '$BOT' send '$DEBUG' -"
check "the stdin body arrived" \
  test "$(sql "select count(*) from public.messages where sender_id = '$BOT_ID' and body = 'piped body'")" = 1
expect_exit 0 "start a 1:1 with a listed contact by id" "$BOT" start "$DAN" "hi dan"
check "the 1:1 with dan exists with the greeting" \
  test "$(sql "select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
              where m.sender_id = '$BOT_ID' and m.body = 'hi dan' and c.direct_key like '%$DAN%'")" = 1
BOB_TAG=$(sql "select tag from public.profiles where user_id = '$BOB'")
expect_exit 0 "start a 1:1 with a listed contact by @tag" "$BOT" start "@$BOB_TAG" "hi bob"

# 6 not permitted (4) ------------------------------------------------------------------
expect_exit 4 "send to a chat that is not Debug or a listed 1:1" "$BOT" send "$G2" "x"
check "the refusal says not permitted" grep -qi 'not permitted' "$BOX/err" "$BOX/out"
expect_exit 4 "start with an unlisted user (who shares Debug)" "$BOT" start "$CAT" "x"
expect_exit 0 "admin off" "$ADMIN" off
expect_exit 4 "OFF: send to Debug" "$BOT" send "$DEBUG" "x"
watch 4 "OFF: read" "$(jq -r .refresh_token "$STATE")" "$BOT" read
expect_exit 0 "admin on" "$ADMIN" on
expect_exit 0 "ON again: send works" "$BOT" send "$DEBUG" "back on"

# 7 rate limited (5) -------------------------------------------------------------------
sql "delete from app_private.bot_actions where bot_id = '$BOT_ID';
     insert into app_private.bot_actions(bot_id, kind) select '$BOT_ID', 'send' from generate_series(1, 20)" >/dev/null
watch 5 "the 21st send in 10 minutes" "$(jq -r .refresh_token "$STATE")" "$BOT" send "$DEBUG" "one too many"
check "the refused send left no log row" \
  test "$(sql "select count(*) from app_private.bot_actions where bot_id = '$BOT_ID' and kind = 'send'")" = 20
sql "delete from app_private.bot_actions where bot_id = '$BOT_ID'" >/dev/null

# 8 usage and unsafe file (2) ------------------------------------------------------------
expect_exit 2 "no command" "$BOT"
expect_exit 2 "send without a conversation" "$BOT" send
expect_exit 2 "an unknown command" "$BOT" frobnicate
chmod 644 "$STATE"
expect_exit 2 "a state file at mode 644 is refused" "$BOT" status
chmod 600 "$STATE"
mv "$STATE" "$BOX/saved.json"
docker run --rm -v "$BOX:/b" --entrypoint sh "$(docker inspect "$DB" --format '{{.Config.Image}}')" \
  -c 'cp /b/saved.json /b/.private/sis_bot.json && chown 4242:4242 /b/.private/sis_bot.json && chmod 600 /b/.private/sis_bot.json'
expect_exit 2 "a state file owned by another user is refused" "$BOT" status
rm -f "$STATE"; mv "$BOX/saved.json" "$STATE"

# 9 parallel runs share the token safely ----------------------------------------------------
"$BOT" send "$DEBUG" "parallel one" >/dev/null 2>&1 & p1=$!
"$BOT" send "$DEBUG" "parallel two" >/dev/null 2>&1 & p2=$!
r1=0; r2=0; wait $p1 || r1=$?; wait $p2 || r2=$?
check "two parallel sends both succeed ($r1, $r2)" test "$r1$r2" = 00
check "the state file is still valid JSON at mode 600" \
  bash -c "jq -e .refresh_token '$STATE' >/dev/null && test \$(stat -c %a '$STATE') = 600"
expect_exit 0 "and the tool still works" "$BOT" status

# 10 the old refresh token is refused once the reuse interval has passed ------------------
sleep 11
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$SIS_URL/auth/v1/token?grant_type=refresh_token" \
         -H "apikey: $SIS_ANON_KEY" -H 'content-type: application/json' -d "{\"refresh_token\":\"$t0\"}")
check "a rotated-out refresh token is refused (HTTP $code)" test "$code" -ge 400

# 11 session lost (3) ---------------------------------------------------------------------
LOCK="$BOX/.private/sis_bot.lock"
flock "$LOCK" sleep 45 & holder=$!
sleep 1
expect_exit 3 "busy: another run holds the lock" "$BOT" status
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
mv "$STATE" "$BOX/saved.json"
expect_exit 3 "missing state file" "$BOT" status
mv "$BOX/saved.json" "$STATE"

# A second sign-in of the bot (the probe session below) supersedes the tool's.
BOT_JWT=$(token_for sis-destek-bot@example.com)
watch 3 "superseded by a second bot sign-in" "$(jq -r .refresh_token "$STATE")" "$BOT" status
check "the advice names the admin mint" grep -q 'mint' "$BOX/err" "$BOX/out"

# 12 probes with the bot's REAL JWT ---------------------------------------------------------
check "probe: the bot's JWT has app access" test "$(rpc "$BOT_JWT" bot_ids '{}' | jq -r '.[0]')" = "$BOT_ID"
c=$(upload "$BOT_JWT" attachments "$DEBUG/bot.jpg");          check "probe: the bot cannot upload an attachment (HTTP $c)" test "$c" -ge 400
c=$(upload "$ANN_JWT" attachments "$DEBUG/ann.jpg");          check "control: a human uploads an attachment (HTTP $c)" test "$c" = 200
c=$(upload "$BOT_JWT" avatars "profile/$BOT_ID/1.jpg");       check "probe: the bot cannot upload its profile picture (HTTP $c)" test "$c" -ge 400
c=$(upload "$BOT_JWT" avatars "group/$DEBUG/1.jpg");          check "probe: the bot cannot upload a Debug picture (HTTP $c)" test "$c" -ge 400
c=$(upload "$ANN_JWT" avatars "group/$DEBUG/2.jpg");          check "control: a human uploads a Debug picture (HTTP $c)" test "$c" = 200
c=$(curl -sS -o "$BOX/body" -w '%{http_code}' -X PATCH "$SIS_URL/rest/v1/profiles?user_id=eq.$BOT_ID" \
      -H "apikey: $SIS_ANON_KEY" -H "Authorization: Bearer $BOT_JWT" -H 'content-type: application/json' \
      -H 'Prefer: return=representation' -d '{"display_name":"Evil"}')
check "probe: the bot cannot rename itself" \
  test "$(sql "select display_name from public.profiles where user_id = '$BOT_ID'")" = "SIS Destek"
rpc "$ANN_JWT" add_members "{\"conversation\":\"$G2\",\"members\":[\"$BOT_ID\"],\"with_history\":true}" >/dev/null
check "probe: add_members of the bot over the API is refused ($(cat "$BOX/code"), $(jq -r .code "$BOX/body"))" \
  test "$(jq -r .code "$BOX/body")" = 42501
rpc "$ANN_JWT" add_members "{\"conversation\":\"$G2\",\"members\":[\"$CAT\"],\"with_history\":true}" >/dev/null
check "control: add_members of a human over the API ($(cat "$BOX/code"))" test "$(cat "$BOX/code")" -lt 300
rpc "$ANN_JWT" set_admin "{\"conversation\":\"$DEBUG\",\"member\":\"$BOT_ID\",\"is_admin\":true}" >/dev/null
check "probe: set_admin(bot) over the API is refused ($(cat "$BOX/code"), $(jq -r .code "$BOX/body"))" \
  test "$(jq -r .code "$BOX/body")" = 42501
rpc "$BOT_JWT" find_by_tag "{\"search_tag\":\"$BOB_TAG\"}" >/dev/null
check "probe: find_by_tag is refused for the bot ($(cat "$BOX/code"))" test "$(jq -r .code "$BOX/body")" = 42501
check "probe: the bot is in no chat but Debug and its listed 1:1s" \
  test "$(sql "select count(*) from public.conversation_members m where m.user_id = '$BOT_ID' and m.left_at is null
              and not app_private.bot_conversation_allowed('$BOT_ID', m.conversation_id)")" = 0
# Realtime over a real websocket, in the Flutter image.
if "${COMPOSE[@]}" run --rm flutter flutter test --run-skipped --tags integration \
     --dart-define=SIS_BOT_PROBE_JWT="$BOT_JWT" --dart-define=SIS_BOT_PROBE_HUMAN_JWT="$ANN_JWT" \
     --dart-define=SIS_BOT_PROBE_DEBUG="$DEBUG" --dart-define=SUPABASE_TEST_KEY="$PUBLISHABLE" \
     test/integration/sis_bot_realtime_probe_test.dart >"$BOX/rt" 2>&1; then
  ok "probe: Realtime refuses the bot, admits the human"
else
  bad "probe: Realtime: $(grep -E 'Expected|Actual|reason|Failed|Error' "$BOX/rt" | head -8 | tr '\n' ' ')"
fi

# 13 admin mint gives the tool a session again; revoke ends it ------------------------------
watch 0 "admin mint" "$SKEY" "$ADMIN" mint
expect_exit 0 "the tool works on the new session" "$BOT" status
cp "$STATE" "$BOX/before_revoke.json"
expect_exit 0 "revoke" "$BOT" revoke
check "revoke deleted the state file" test ! -e "$STATE"
expect_exit 3 "after revoke: read" "$BOT" read
cp "$BOX/before_revoke.json" "$STATE"; chmod 600 "$STATE"
expect_exit 3 "after revoke: a copy of the old file is dead too" "$BOT" status
expect_exit 0 "admin mint again" "$ADMIN" mint
expect_exit 0 "admin revoke (break-glass)" "$ADMIN" revoke
check "admin revoke switched the bot OFF" test "$(sql "select enabled from app_private.bot_accounts where user_id = '$BOT_ID'")" = f
check "and removed every bot session" test "$(sql "select count(*) from auth.sessions where user_id = '$BOT_ID'")" = 0

# 14 delete --------------------------------------------------------------------------------
expect_exit 0 "admin delete" "$ADMIN" delete
check "the bot user is gone" test "$(sql "select count(*) from auth.users where email = 'sis-destek-bot@example.com'")" = 0
check "and its bot rows with it" test "$(sql "select count(*) from app_private.bot_accounts")" = 0

echo "# passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
