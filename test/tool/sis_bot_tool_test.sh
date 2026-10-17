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
# unlisted user, OFF), 5 (rate limited); two parallel first sends to
# one user, and in one group, giving one AI line and one intro record; the
# bot's first Debug message carrying the line and its second not; revoke; the sign-up hook refusing a
# public sign-up of the bot address; and probes with the bot's REAL JWT of
# storage, avatars, profile update, add_members, set_admin and Realtime; admin
# rename (trim, 1-80 characters, exact quotes/backslashes, no bot -> exit 1);
# edit and delete of the bot's own messages (stdin, 4000 characters; exit 2 on a
# bad uuid or empty text; 4 on another user's, a >6 h old (edit) or a deleted
# message and when OFF; 3 when superseded; no token in any output); attachments
# (a photo or image file of Debug saved byte-identical at 700/600 with its
# extension from name, path, mime or bytes, only the path printed; exit 1 for
# another chat, an unknown id, a video, a non-image file, text only and a gone
# object, writing nothing; 2 bad uuid; 4 OFF) and read's [image <id>] marker.
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
# mode-700 directory (S-2). Only the private TMPDIR is watched: other processes
# fill the shared /tmp at any moment. A mktemp shim logs every path the tool
# gets, so a temp file made outside TMPDIR (TMPDIR not honoured) still fails.
TMPD="$BOX/tmp"; mkdir -m 700 "$TMPD"
mkdir "$BOX/bin"; REAL_MKTEMP=$(command -v mktemp)
printf '#!/bin/sh\nout=$("%s" "$@") || exit $?\nprintf "%%s\\n" "$out" >>"%s"\nprintf "%%s\\n" "$out"\n' \
  "$REAL_MKTEMP" "$BOX/mktemps" >"$BOX/bin/mktemp"; chmod 700 "$BOX/bin/mktemp"
watch() {
  local want=$1 name=$2 secret=$3; shift 3
  printf '%s\n' "$secret" >"$BOX/pats"
  : >"$BOX/seen"; : >"$BOX/argv_hits"; : >"$BOX/mktemps"
  ( while :; do
      find "$TMPD" -mindepth 1 -printf '%d %m %y %P\n' >>"$BOX/seen" 2>/dev/null || true
      grep -lsF -f "$BOX/pats" /proc/[0-9]*/cmdline >>"$BOX/argv_hits" 2>/dev/null || true
    done ) & local poller=$!
  local got=0; PATH="$BOX/bin:$PATH" TMPDIR="$TMPD" "$@" >"$BOX/out" 2>"$BOX/err" || got=$?
  kill "$poller" 2>/dev/null || true; wait "$poller" 2>/dev/null || true
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"
  else bad "$name: want exit $want, got $got: $(tr '\n' ' ' <"$BOX/err" | head -c 300)"; fi
  check "$name: the secret was never in a process argv" test ! -s "$BOX/argv_hits"
  [ "$1" = "$BOT" ] || return 0
  local left; left=$(ls -A "$TMPD" | tr '\n' ' ')
  check "$name: no temp file left behind${left:+ ($left)}" test -z "$left"
  local outside; outside=$(grep -v "^$TMPD/" "$BOX/mktemps" | tr '\n' ' ' || true)
  check "$name: every temp file was made inside TMPDIR${outside:+ ($outside)}" test -z "$outside"
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
INTRO='Merhaba, ben SIS Destek, bir yapay zekâ asistanıyım. Mesajlarımı yapay zekâ yazar.'
expect_exit 0 "send to Debug" "$BOT" send "$DEBUG" "hello from the bot"
check "the message is in Debug, from the bot, after the AI line (the bot's first in Debug)" \
  test "$(sql "select count(*) from public.messages where conversation_id = '$DEBUG' and sender_id = '$BOT_ID'
              and body = '$INTRO' || E'\\n\\n' || 'hello from the bot'")" = 1
expect_exit 0 "send from stdin" bash -c "printf 'piped body' | '$BOT' send '$DEBUG' -"
check "the stdin body arrived unchanged (the bot's second in Debug)" \
  test "$(sql "select count(*) from public.messages where sender_id = '$BOT_ID' and body = 'piped body'")" = 1
check "one group intro record for (bot, Debug)" \
  test "$(sql "select count(*) from app_private.bot_group_intro_sent where bot_id = '$BOT_ID' and conversation_id = '$DEBUG'")" = 1
expect_exit 0 "start a 1:1 with a listed contact by id" "$BOT" start "$DAN" "hi dan"
check "the 1:1 with dan exists with the greeting, after the AI line (first message to dan)" \
  test "$(sql "select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
              where m.sender_id = '$BOT_ID' and m.body = '$INTRO' || E'\\n\\n' || 'hi dan' and c.direct_key like '%$DAN%'")" = 1
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

# 7b edit and delete own messages (2, 4, never a token) -------------------------------
mid() { sql "select id from public.messages where sender_id = '$BOT_ID' and body = '$1'"; }
body_of() { sql "select body from public.messages where id = '$1'"; }
gone() { test "$(sql "select deleted_at is not null from public.messages where id = '$1'")" = t; }
# no_token NAME: no refresh token (old or current) and nothing JWT-shaped in the last output
no_token() {
  check "$1: no token in the output" bash -c "! grep -qF -e '$2' -e \"\$(jq -r .refresh_token '$STATE')\" '$BOX/out' '$BOX/err' \
    && ! grep -qE 'eyJ[A-Za-z0-9_-]{8,}\\.' '$BOX/out' '$BOX/err'"
}
expect_exit 0 "send a message to edit" "$BOT" send "$DEBUG" "to be edited"
M1=$(mid 'to be edited')
t=$(jq -r .refresh_token "$STATE")
watch 0 "edit own message" "$t" "$BOT" edit "$M1" "edited body"
same_out() { test "$(cat "$BOX/out")" = "$1"; }
check "edit prints 'edited <id>'" same_out "edited $M1"
no_token "edit" "$t"
check "the body is replaced" test "$(body_of "$M1")" = "edited body"
expect_exit 0 "edit from stdin" bash -c "printf 'piped\nedit' | '$BOT' edit '$M1' -"
check "the stdin body arrived unchanged" test "$(body_of "$M1")" = $'piped\nedit'
n4000=$(printf 'ş%.0s' $(seq 4000))
expect_exit 0 "edit to 4000 characters (multi-byte, stdin)" bash -c "printf '%s' '$n4000' | '$BOT' edit '$M1' -"
check "the 4000-character body is stored" test "$(sql "select char_length(body) from public.messages where id = '$M1'")" = 4000
expect_exit 0 "edit back" "$BOT" edit "$M1" "edited body"
# open_stdin cmd...: cmd with a stdin that stays open and silent, killed after
# 10 s, so a command that waits on stdin when it should not shows as exit 124.
open_stdin() { timeout 10 "$@" < <(sleep 30); }
expect_exit 2 "edit with empty text (stdin left unread)" open_stdin "$BOT" edit "$M1" ""
expect_exit 2 "edit with empty stdin" bash -c "printf '' | '$BOT' edit '$M1' -"
expect_exit 2 "edit with no text (stdin left unread)" open_stdin "$BOT" edit "$M1"
expect_exit 2 "edit with no id" open_stdin "$BOT" edit
expect_exit 2 "edit a bad uuid" "$BOT" edit "not-a-uuid" "x"
expect_exit 2 "delete a bad uuid" "$BOT" delete "1234"
expect_exit 2 "delete with no id" open_stdin "$BOT" delete
check "the refused edits left the body alone" test "$(body_of "$M1")" = "edited body"
ANN_MSG=$(sql "select id from public.messages where sender_id = '$ANN' and body = 'hello from ann'")
t=$(jq -r .refresh_token "$STATE")
watch 4 "edit another user's message" "$t" "$BOT" edit "$ANN_MSG" "hijacked"
no_token "edit refused" "$t"
expect_exit 4 "delete another user's message" "$BOT" delete "$ANN_MSG"
check "ann's message is unchanged and not deleted" \
  test "$(sql "select body || '|' || (deleted_at is null) from public.messages where id = '$ANN_MSG'")" = "hello from ann|true"
# older than 6 h: edit refused, a 5 h old one still editable
expect_exit 0 "send a message to age" "$BOT" send "$DEBUG" "aged seven"
expect_exit 0 "send another to age" "$BOT" send "$DEBUG" "aged five"
M7=$(mid 'aged seven'); M5=$(mid 'aged five')
sql "update public.messages set created_at = now() - interval '7 hours' where id = '$M7';
     update public.messages set created_at = now() - interval '5 hours' where id = '$M5'" >/dev/null
expect_exit 4 "edit a message older than 6 h" "$BOT" edit "$M7" "too late"
check "the old message is unchanged" test "$(body_of "$M7")" = "aged seven"
expect_exit 0 "control: edit a 5 h old message" "$BOT" edit "$M5" "still in time"
check "the 5 h old message is edited" test "$(body_of "$M5")" = "still in time"
t=$(jq -r .refresh_token "$STATE")
watch 0 "delete own message" "$t" "$BOT" delete "$M1"
check "delete prints 'deleted <id>'" same_out "deleted $M1"
no_token "delete" "$t"
check "the message is deleted" gone "$M1"
expect_exit 4 "delete an already deleted message" "$BOT" delete "$M1"
expect_exit 4 "edit a deleted message" "$BOT" edit "$M1" "zombie"
expect_exit 0 "admin off (edit/delete)" "$ADMIN" off
expect_exit 4 "OFF: edit own message" "$BOT" edit "$M5" "while off"
expect_exit 4 "OFF: delete own message" "$BOT" delete "$M5"
expect_exit 0 "admin on (edit/delete)" "$ADMIN" on
check "OFF left the message as it was" \
  test "$(sql "select body || '|' || (deleted_at is null) from public.messages where id = '$M5'")" = "still in time|true"
sql "delete from app_private.bot_actions where bot_id = '$BOT_ID'" >/dev/null

# 7c attachments: the bot downloads an image of a chat it is in -------------------
# ann uploads and posts (as the app does); the bot fetches with its own session.
# Fixture bytes start with the real magic of their type, then random bytes.
# The bucket takes only images and application/octet-stream (files, videos).
sql "delete from app_private.bot_actions where bot_id = '$BOT_ID'" >/dev/null
ATT="$BOX/.private/bot-attachments"
FIX="$BOX/fix"; mkdir -p "$FIX"
mkbytes() { { printf '%b' "$2"; head -c 4000 /dev/urandom; } >"$FIX/$1"; }
mkbytes jpg '\xff\xd8\xff\xe0\x00\x10JFIF\x00'; mkbytes png '\x89PNG\r\n\x1a\n'
mkbytes gif 'GIF89a'; mkbytes pdf '%PDF-1.4\n'; mkbytes mp4 '\x00\x00\x00\x18ftypmp42'
newkey() { printf '%s/%s%s' "$1" "$(cat /proc/sys/kernel/random/uuid)" "${2:-}"; }
# post CONV KEY CTYPE FIXTURE BODY [FILE-COLUMNS-JSON] -> the message id
post() {
  local c; c=$(curl -sS -o "$BOX/body" -w '%{http_code}' -X POST "$SIS_URL/storage/v1/object/attachments/$2" \
    -H "apikey: $SIS_ANON_KEY" -H "Authorization: Bearer $ANN_JWT" -H "content-type: $3" --data-binary @"$FIX/$4")
  [ "$c" = 200 ] || { echo "fixture upload $2 failed: $c $(cat "$BOX/body")" >&2; exit 1; }
  curl -fsS -o /dev/null -X POST "$SIS_URL/rest/v1/messages" -H "apikey: $SIS_ANON_KEY" \
    -H "Authorization: Bearer $ANN_JWT" -H 'content-type: application/json' \
    -d "{\"conversation_id\":\"$1\",\"sender_id\":\"$ANN\",\"body\":\"$5\",\"attachment_path\":\"$2\"${6:+,$6}}" \
    || { echo "fixture message $2 failed" >&2; exit 1; }
  sql "select id from public.messages where attachment_path = '$2'"
}
filecols() { printf '"attachment_name":"%s","attachment_mime":"%s","attachment_size":%s%s' \
  "$1" "$2" "$(stat -c %s "$FIX/$3")" "${4:+,\"attachment_duration_ms\":$4}"; }
P1=$(post "$DEBUG" "$(newkey "$DEBUG" .jpg)" image/jpeg jpg "")                  # a photo, ext from the path
P2=$(post "$DEBUG" "$(newkey "$DEBUG")" image/png png "look at this")            # with text, ext from the bytes
P3=$(post "$DEBUG" "$(newkey "$DEBUG" .jpg)" image/gif gif "" "$(filecols holiday.gif image/gif gif)")   # name beats path
P4=$(post "$DEBUG" "$(newkey "$DEBUG" .jpeg)" image/png png "" "$(filecols screenshot image/png png)")   # no ext in name: path beats mime
P5=$(post "$DEBUG" "$(newkey "$DEBUG")" image/webp png "" "$(filecols screenshot image/webp png)")      # mime beats the bytes
P6=$(post "$DEBUG" "$(newkey "$DEBUG" .jpg)" image/jpeg jpg "")                  # fetched while OFF
P7=$(post "$DEBUG" "$(newkey "$DEBUG" .jpg)" image/jpeg jpg "")                  # its object deleted
V1=$(post "$DEBUG" "$(newkey "$DEBUG" .mp4)" application/octet-stream mp4 "" "$(filecols clip.mp4 video/mp4 mp4 1500)")
F1=$(post "$DEBUG" "$(newkey "$DEBUG" .pdf)" application/octet-stream pdf "" "$(filecols notes.pdf application/pdf pdf)")
X1=$(post "$G2" "$(newkey "$G2" .jpg)" image/jpeg jpg "")                        # a chat the bot is not in
curl -fsS -o /dev/null -X POST "$SIS_URL/rest/v1/messages" -H "apikey: $SIS_ANON_KEY" -H "Authorization: Bearer $ANN_JWT" \
  -H 'content-type: application/json' -d "{\"conversation_id\":\"$DEBUG\",\"sender_id\":\"$ANN\",\"body\":\"text only 7c\"}"
T1=$(sql "select id from public.messages where body = 'text only 7c'")
# the object behind P7 goes away (test setup, service key), the message stays
curl -fsS -o /dev/null -X DELETE "$SIS_URL/storage/v1/object/attachments/$(sql "select attachment_path from public.messages where id = '$P7'")" \
  -H "apikey: $SKEY" -H "Authorization: Bearer $SKEY"
# got ID EXT FIXTURE: the printed path (absolute, or relative as the contract
# writes it) is <ATT>/<id>/1<ext>, byte-identical, dir 700, file 600
got() {
  local f="$ATT/$1/1$2" o; o=$(cat "$BOX/out")
  check "attachments $1: prints only its path ($o)" bash -c "[ '$o' = '$f' ] || [ '$o' = '${f#"$BOX/"}' ]"
  check "attachments $1: 1$2 is byte-identical" cmp -s "$f" "$FIX/$3"
  check "attachments $1: the directory is mode 700" test "$(stat -c %a "$ATT/$1" 2>/dev/null)" = 700
  check "attachments $1: the file is mode 600" test "$(stat -c %a "$f" 2>/dev/null)" = 600
  check "attachments $1: one file in its directory" test "$(ls -A "$ATT/$1" 2>/dev/null | wc -l)" = 1
}
refusal() {  # WANT-EXIT ID TEXT NAME: the exit, the message, nothing written
  expect_exit "$1" "attachments refuses $4" "$BOT" attachments "$2"
  [ -z "$3" ] || check "attachments refuses $4: says '$3'" grep -qiF "$3" "$BOX/err" "$BOX/out"
  check "attachments refuses $4: nothing written" test ! -e "$ATT/$2"
}
old_umask=$(umask); umask 022   # modes must not come from the caller's umask
t=$(jq -r .refresh_token "$STATE")
watch 0 "attachments of a photo in Debug" "$t" "$BOT" attachments "$P1"
got "$P1" .jpg jpg
no_token "attachments" "$t"
check "attachments: no URL in the output" bash -c "! grep -qiE 'https?://|/storage/' '$BOX/out' '$BOX/err'"
expect_exit 0 "attachments of a photo with text" "$BOT" attachments "$P2"; got "$P2" .png png
expect_exit 0 "attachments of an image file (name holiday.gif, path .jpg)" "$BOT" attachments "$P3"; got "$P3" .gif gif
expect_exit 0 "attachments of an image file (no ext in name, path .jpeg, mime image/png)" "$BOT" attachments "$P4"; got "$P4" .jpeg png
expect_exit 0 "attachments of an image file (no ext anywhere, mime image/webp)" "$BOT" attachments "$P5"; got "$P5" .webp png
umask "$old_umask"
refusal 1 "$X1" "no such message" "a photo in a chat the bot is not in"
refusal 1 "$(cat /proc/sys/kernel/random/uuid)" "no such message" "an unknown message id"
refusal 1 "$V1" "no image" "a video message"
refusal 1 "$F1" "no image" "a non-image file"
refusal 1 "$T1" "no image" "a text-only message"
refusal 1 "$P7" "download failed (http " "a photo whose object is gone"
expect_exit 2 "attachments refuses a bad uuid" "$BOT" attachments "not-a-uuid"
check "the bad uuid wrote nothing" test ! -e "$ATT/not-a-uuid"
expect_exit 2 "attachments with no id" open_stdin "$BOT" attachments
expect_exit 0 "admin off (attachments)" "$ADMIN" off
refusal 4 "$P6" "" "while the bot is OFF"
expect_exit 0 "admin on (attachments)" "$ADMIN" on
# read shows an image as [image <id>], after the text when there is text
expect_exit 0 "read after the images" "$BOT" read
has_body() { jq -se --arg b "$1" '[.[] | .. | strings | select(. == $b)] | length > 0' "$BOX/out" >/dev/null 2>&1; }
check "read: a photo without text is '[image <id>]'" has_body "[image $P1]"
check "read: a photo with text is '<text>\\n[image <id>]'" has_body $'look at this\n'"[image $P2]"
check "read: an image file is '[image <id>]' too" has_body "[image $P3]"
check "read: a video gets no image marker" bash -c "! grep -qF '[image $V1]' '$BOX/out'"
check "read: a non-image file gets no image marker" bash -c "! grep -qF '[image $F1]' '$BOX/out'"
check "read: a text-only message is unchanged" has_body "text only 7c"
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
expect_exit 3 "superseded: edit" "$BOT" edit "$ANN" "x"
expect_exit 3 "superseded: delete" "$BOT" delete "$ANN"

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
if "${COMPOSE[@]}" run --rm flutter flutter test --run-skipped --tags sis_bot_probe \
     --dart-define=SIS_BOT_PROBE_JWT="$BOT_JWT" --dart-define=SIS_BOT_PROBE_HUMAN_JWT="$ANN_JWT" \
     --dart-define=SIS_BOT_PROBE_DEBUG="$DEBUG" --dart-define=SUPABASE_TEST_KEY="$PUBLISHABLE" \
     test/tool/sis_bot_realtime_probe_test.dart >"$BOX/rt" 2>&1; then
  ok "probe: Realtime refuses the bot, admits the human"
else
  bad "probe: Realtime: $(grep -E 'Expected|Actual|reason|Failed|Error' "$BOX/rt" | head -8 | tr '\n' ' ')"
fi

# 12a two parallel first sends to one user: exactly one AI line, one record -------------
# eve starts a 1:1 with the bot; the bot then sends twice at once with its REAL JWT.
# A psql session holds the 1:1's row FOR UPDATE, so each insert runs its BEFORE
# triggers and then waits on the foreign-key check: both decide "first message
# or not" before either commits. Both must be seen waiting, or it was no race.
sql "insert into app_private.allowlist(email) values ('eve@$DOM')" >/dev/null
EVE=$(create_user "eve@$DOM" Eve)
sql "insert into app_private.bot_contacts(bot_id, contact_id) values ('$BOT_ID', '$EVE');
     delete from app_private.bot_actions where bot_id = '$BOT_ID'" >/dev/null
EVE_JWT=$(token_for "eve@$DOM")
EB=$(rpc "$EVE_JWT" start_direct_conversation "{\"other_user\":\"$BOT_ID\"}" | jq -r .)
[[ $EB =~ ^[0-9a-f-]{36}$ ]] || { echo "fixture 1:1 with eve failed: $EB"; exit 1; }
bot_post() {  # body -> HTTP code in $BOX/par_<body>
  curl -sS -o /dev/null -w '%{http_code}' -X POST "$SIS_URL/rest/v1/messages" -H "apikey: $SIS_ANON_KEY" \
    -H "Authorization: Bearer $BOT_JWT" -H 'content-type: application/json' \
    -d "{\"conversation_id\":\"$EB\",\"sender_id\":\"$BOT_ID\",\"body\":\"$1\"}" >"$BOX/par_$1"
}
sql "select 1 from public.conversations where id = '$EB' for update; select pg_sleep(4)" >/dev/null & holder=$!
sleep 1
bot_post race1 & pa=$!; bot_post race2 & pb=$!
sleep 2
waiting=$(sql "select count(*) from pg_stat_activity where wait_event_type = 'Lock'
               and query ilike '%insert into%messages%' and query not ilike '%pg_stat_activity%'")
wait "$pa" || true; wait "$pb" || true; wait "$holder" || true
check "both parallel first sends were in flight at once ($waiting waiting)" test "$waiting" = 2
check "both parallel first sends succeed ($(cat "$BOX/par_race1"), $(cat "$BOX/par_race2"))" \
  test "$(cat "$BOX/par_race1")$(cat "$BOX/par_race2")" = 201201
check "exactly one of them carries the AI line" \
  test "$(sql "select count(*) from public.messages where conversation_id = '$EB' and sender_id = '$BOT_ID'
              and body in ('$INTRO' || E'\\n\\n' || 'race1', '$INTRO' || E'\\n\\n' || 'race2')")" = 1
check "and the other is stored unchanged" \
  test "$(sql "select count(*) from public.messages where conversation_id = '$EB' and sender_id = '$BOT_ID'
              and body in ('race1', 'race2')")" = 1
check "one intro record for (bot, eve)" \
  test "$(sql "select count(*) from app_private.bot_intro_sent where bot_id = '$BOT_ID' and user_id = '$EVE'")" = 1

# 12a2 two parallel first sends in one group: exactly one AI line, one record ------------
# A fresh group (ann, bob) becomes the bot's Debug for this case; same lock as 12a.
G3=$(rpc "$ANN_JWT" start_group_conversation "{\"title\":\"Race\",\"members\":[\"$BOB\"]}" | jq -r .)
[[ $G3 =~ ^[0-9a-f-]{36}$ ]] || { echo "fixture race group failed: $G3"; exit 1; }
sql "update app_private.bot_accounts set debug_conversation = '$G3' where user_id = '$BOT_ID';
     insert into public.conversation_members(conversation_id, user_id, role, history_from, joined_at)
     values ('$G3', '$BOT_ID', 'member', now(), now());
     delete from app_private.bot_actions where bot_id = '$BOT_ID'" >/dev/null
EB=$G3
sql "select 1 from public.conversations where id = '$G3' for update; select pg_sleep(4)" >/dev/null & holder=$!
sleep 1
bot_post grace1 & pa=$!; bot_post grace2 & pb=$!
sleep 2
waiting=$(sql "select count(*) from pg_stat_activity where wait_event_type = 'Lock'
               and query ilike '%insert into%messages%' and query not ilike '%pg_stat_activity%'")
wait "$pa" || true; wait "$pb" || true; wait "$holder" || true
check "group: both parallel first sends were in flight at once ($waiting waiting)" test "$waiting" = 2
check "group: both parallel first sends succeed ($(cat "$BOX/par_grace1"), $(cat "$BOX/par_grace2"))" \
  test "$(cat "$BOX/par_grace1")$(cat "$BOX/par_grace2")" = 201201
check "group: exactly one of them carries the AI line" \
  test "$(sql "select count(*) from public.messages where conversation_id = '$G3' and sender_id = '$BOT_ID'
              and body in ('$INTRO' || E'\\n\\n' || 'grace1', '$INTRO' || E'\\n\\n' || 'grace2')")" = 1
check "group: and the other is stored unchanged" \
  test "$(sql "select count(*) from public.messages where conversation_id = '$G3' and sender_id = '$BOT_ID'
              and body in ('grace1', 'grace2')")" = 1
check "group: one intro record for (bot, race group)" \
  test "$(sql "select count(*) from app_private.bot_group_intro_sent where bot_id = '$BOT_ID' and conversation_id = '$G3'")" = 1
sql "update app_private.bot_accounts set debug_conversation = '$DEBUG' where user_id = '$BOT_ID'" >/dev/null

# 12b admin rename: trims, 1-80 characters, stored exactly; the bot still cannot --------
name_is() { test "$(sql "select display_name from public.profiles where user_id = '$BOT_ID'")" = "$1"; }
expect_exit 0 "admin rename" "$ADMIN" rename "  SIS Yardım  "
check "rename prints only 'renamed'" bash -c "test \"\$(cat '$BOX/out')\" = renamed && test ! -s '$BOX/err'"
check "rename trims and stores the name" name_is "SIS Yardım"
q="O'Brien \\ back\\\\slash \"x\""
expect_exit 0 "admin rename with quotes and backslashes" "$ADMIN" rename "$q"
check "quotes and backslashes are stored exactly" \
  test "$(docker exec -i "$DB" psql -U postgres -XAtq -c "select encode(convert_to(display_name, 'UTF8'), 'hex') from public.profiles where user_id = '$BOT_ID'")" \
       = "$(printf '%s' "$q" | od -An -tx1 | tr -d ' \n')"
n80=$(printf 'ş%.0s' $(seq 80))
expect_exit 0 "admin rename to 80 characters (multi-byte)" "$ADMIN" rename "$n80"
check "the 80-character name is stored" name_is "$n80"
expect_exit 0 "admin rename to 1 character" "$ADMIN" rename " Z "
check "the 1-character name is stored" name_is "Z"
too_long() {  # NAME args...: exit 1, the length message, the name unchanged
  local name=$1; shift
  expect_exit 1 "admin rename refuses $name" "$ADMIN" rename "$@"
  check "admin rename refuses $name: says 1 to 80 characters" \
    grep -qF "the name must be 1 to 80 characters" "$BOX/err" "$BOX/out"
  check "admin rename refuses $name: the name is unchanged" name_is "Z"
}
too_long "81 characters" "${n80}x"
too_long "an empty name" ""
too_long "a blank name" "   "
too_long "a missing name"
expect_exit 0 "admin rename back" "$ADMIN" rename "SIS Destek"
# return=minimal: return=representation needs a table-wide SELECT grant and is
# refused for everyone, so it would pass even with the bot guard gone.
self_rename() {  # jwt user name -> http code
  curl -sS -o "$BOX/body" -w '%{http_code}' -X PATCH "$SIS_URL/rest/v1/profiles?user_id=eq.$2" \
    -H "apikey: $SIS_ANON_KEY" -H "Authorization: Bearer $1" -H 'content-type: application/json' \
    -H 'Prefer: return=minimal' -d "{\"display_name\":\"$3\"}"
}
c=$(self_rename "$ANN_JWT" "$ANN" "Ann Renamed")
check "control: a human renames itself with the same request (HTTP $c)" \
  test "$(sql "select display_name from public.profiles where user_id = '$ANN'")" = "Ann Renamed"
self_rename "$ANN_JWT" "$ANN" "Ann" >/dev/null
c=$(self_rename "$BOT_JWT" "$BOT_ID" "Evil after rename")
check "probe: after an admin rename the bot still cannot rename itself (HTTP $c)" name_is "SIS Destek"

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

expect_exit 1 "admin rename with no bot" "$ADMIN" rename "Nobody"
check "it says rename changed 0 rows" grep -qF "rename changed 0 rows" "$BOX/err" "$BOX/out"

echo "# passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
