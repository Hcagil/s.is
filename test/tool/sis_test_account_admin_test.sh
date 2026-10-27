#!/usr/bin/env bash
# Integration test of tool/sis_test_account_admin.sh against the LOCAL Supabase
# stack (CI's database job and tool/ci_local.sh, after `supabase start`). It
# uses only the stack's own local keys and never the repository's .private/:
# the tool is copied into a sandbox, so its token file lives there.
#
# Covers: usage on a bad command; the key file (unset, only in SIS_SERVICE_KEY,
# mode 644, another owner -> exit 2, nothing created); bootstrap (user
# push-sender@sis.test, allowlist row, NOT a bot, token file mode 600 whose
# refresh token really signs that user in); mint (a new session; the old one
# is superseded: active_sessions moves, its JWT reads nothing); revoke (no session, no file); delete (allowlist row gone before the
# user, then the user).
set -euo pipefail
cd "$(dirname "$0")/../.."
export LOCAL_UID="${LOCAL_UID:-$(id -u)}" LOCAL_GID="${LOCAL_GID:-$(id -g)}"
DB="${SIS_DB_CONTAINER:-supabase_db_s.is}"
read -r -a COMPOSE <<<"${SIS_BOT_TEST_COMPOSE:-docker compose}"

env_out=$("${COMPOSE[@]}" run --rm supabase status -o env 2>/dev/null)
val() { sed -n "s/^$1=\"\(.*\)\"/\1/p" <<<"$env_out"; }
export SIS_URL=http://127.0.0.1:54321
SKEY=$(val SERVICE_ROLE_KEY)
export SIS_ANON_KEY; SIS_ANON_KEY=$(val ANON_KEY)
[ -n "$SKEY" ] && [ -n "$SIS_ANON_KEY" ] || { echo "local stack not running"; exit 1; }
unset SIS_PROJECT_REF SUPABASE_ACCESS_TOKEN SUPABASE_ACCESS_TOKEN_FILE SIS_SERVICE_KEY

EMAIL=push-sender@sis.test
BOX=$(mktemp -d); mkdir -p "$BOX/tool"; chmod 700 "$BOX"
KEYFILE="$BOX/service_key"; (umask 077; printf '%s\n' "$SKEY" >"$KEYFILE")
export SIS_SERVICE_KEY_FILE="$KEYFILE"
cp tool/sis_test_account_admin.sh "$BOX/tool/"
ADMIN="$BOX/tool/sis_test_account_admin.sh"; STATE="$BOX/.private/sis_test_sender.json"

sql() { docker exec -i "$DB" psql -U postgres -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
su_sql() { docker exec -i "$DB" psql -U supabase_admin -d postgres -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
clean() {
  su_sql "drop trigger if exists qa_delete_order on auth.users; drop schema if exists qa_t cascade;" >/dev/null 2>&1 || true
  sql "delete from app_private.allowlist where email = '$EMAIL'; delete from auth.users where email = '$EMAIL';" >/dev/null 2>&1 || true
}
trap 'clean; rm -rf "$BOX"' EXIT
clean

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "not ok - $1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$2], got [$3]"; fi; }
expect_exit() {  # CODE NAME cmd...
  local want=$1 name=$2; shift 2
  local got=0; "$@" >"$BOX/out" 2>"$BOX/err" || got=$?
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"; else bad "$name: exit $got, want $want: $(head -c 300 "$BOX/err")"; fi
}
users() { sql "select count(*) from auth.users where email = '$EMAIL'"; }
uid() { sql "select id from auth.users where email = '$EMAIL'"; }
sessions() { sql "select count(*) from auth.sessions s join auth.users u on u.id = s.user_id where u.email = '$EMAIL'"; }
token() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["refresh_token"])' "$STATE"; }
# refresh <token>: prints the HTTP code of a refresh-token sign-in, and the email to $BOX/who.
refresh() {
  curl -s -o "$BOX/resp" -w '%{http_code}' -X POST "$SIS_URL/auth/v1/token?grant_type=refresh_token" \
    -H "apikey: $SIS_ANON_KEY" -H 'Content-Type: application/json' --data-binary @- <<<"{\"refresh_token\":\"$1\"}"
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("user",{}).get("email",""))' "$BOX/resp" >"$BOX/who" 2>/dev/null || true
}

# usage ----------------------------------------------------------------------
got=0; "$ADMIN" frobnicate >"$BOX/out" 2>"$BOX/err" || got=$?
if [ "$got" != 0 ]; then ok "a bad command fails (exit $got)"; else bad "a bad command exits 0"; fi
if grep -qE 'bootstrap.*mint.*revoke.*delete' "$BOX/err" "$BOX/out"; then ok "the usage line names the commands"; else bad "no usage line: $(cat "$BOX/err")"; fi

# key file refusals: exit 2, and nothing is created ---------------------------
expect_exit 2 "key file unset" env -u SIS_SERVICE_KEY_FILE "$ADMIN" bootstrap
expect_exit 2 "key only in SIS_SERVICE_KEY" env -u SIS_SERVICE_KEY_FILE SIS_SERVICE_KEY="$SKEY" "$ADMIN" bootstrap
cp "$KEYFILE" "$BOX/key_644"; chmod 644 "$BOX/key_644"
expect_exit 2 "key file at mode 644" env SIS_SERVICE_KEY_FILE="$BOX/key_644" "$ADMIN" bootstrap
cp "$KEYFILE" "$BOX/key_640"; chmod 640 "$BOX/key_640"
expect_exit 2 "key file at mode 640" env SIS_SERVICE_KEY_FILE="$BOX/key_640" "$ADMIN" bootstrap
docker run --rm -v "$BOX:/b" --entrypoint sh "$(docker inspect "$DB" --format '{{.Config.Image}}')" \
  -c 'cp /b/service_key /b/key_other && chown 4242:4242 /b/key_other && chmod 600 /b/key_other'
expect_exit 2 "key file owned by another user" env SIS_SERVICE_KEY_FILE="$BOX/key_other" "$ADMIN" bootstrap
same "no user after the refusals" 0 "$(users)"
if [ -e "$STATE" ]; then bad "a token file after the refusals"; else ok "no token file after the refusals"; fi

# bootstrap --------------------------------------------------------------------
expect_exit 0 "bootstrap" "$ADMIN" bootstrap
same "the user exists" 1 "$(users)"
same "the allowlist row exists" 1 "$(sql "select count(*) from app_private.allowlist where email = '$EMAIL'")"
same "it is NOT a bot account" 0 "$(sql "select count(*) from app_private.bot_accounts b join auth.users u on u.id = b.user_id where u.email = '$EMAIL'")"
if [ -f "$STATE" ]; then
  same "the token file is mode 600" 600 "$(stat -c %a "$STATE")"
  T1=$(token)
  same "its refresh token signs in" 200 "$(refresh "$T1")"
  same "as $EMAIL" "$EMAIL" "$(cat "$BOX/who")"
  OLD=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["refresh_token"])' "$BOX/resp") || OLD=none
else bad "no token file after bootstrap"; T1=none; fi
if grep -qF "$SKEY" "$BOX/out" "$BOX/err" "$STATE" 2>/dev/null; then bad "the service key appears in output or the file"; else ok "the service key is not printed or stored"; fi

# mint -------------------------------------------------------------------------
S_OLD=$(sql "select session_id from app_private.active_sessions a join auth.users u on u.id = a.user_id where u.email = '$EMAIL'")
expect_exit 0 "mint" "$ADMIN" mint
T2=$(token 2>/dev/null || echo none)
if [ "$T2" != "$T1" ] && [ "$T2" != none ]; then ok "mint wrote a new token"; else bad "mint kept the token"; fi
S_NEW=$(sql "select session_id from app_private.active_sessions a join auth.users u on u.id = a.user_id where u.email = '$EMAIL'")
same "the active session is the newest one" "$(sql "select s.id from auth.sessions s join auth.users u on u.id = s.user_id where u.email = '$EMAIL' order by s.created_at desc limit 1")" "$S_NEW"
if [ -n "$S_OLD" ] && [ "$S_OLD" != "$S_NEW" ]; then ok "mint superseded the old session"; else bad "the old session is still the active one ($S_OLD)"; fi
same "the new token signs in" 200 "$(refresh "$T2")"
NEW_AT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$BOX/resp") || NEW_AT=none
refresh "${OLD:-none}" >/dev/null
OLD_AT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("access_token",""))' "$BOX/resp")
own_profile() { curl -s "$SIS_URL/rest/v1/profiles?select=user_id&user_id=eq.$(uid)" -H "apikey: $SIS_ANON_KEY" -H "Authorization: Bearer $1" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else "err")'; }
same "the new session reads its own profile" 1 "$(own_profile "$NEW_AT")"
same "the superseded session reads nothing" 0 "$(own_profile "${OLD_AT:-none}")"

# revoke -----------------------------------------------------------------------
expect_exit 0 "revoke" "$ADMIN" revoke
same "no session after revoke" 0 "$(sessions)"
if [ -e "$STATE" ]; then bad "the token file survives revoke"; else ok "revoke removed the token file"; fi
same "the user is still there after revoke" 1 "$(users)"

# delete: a trigger records whether the allowlist row was still there when the user went.
su_sql "create schema qa_t; create table qa_t.log(allowlisted boolean);
  create function qa_t.f() returns trigger language plpgsql security definer as \$\$ begin
    insert into qa_t.log select exists(select 1 from app_private.allowlist where email = old.email); return old; end \$\$;
  create trigger qa_delete_order before delete on auth.users for each row when (old.email = '$EMAIL') execute function qa_t.f();" >/dev/null
expect_exit 0 "delete" "$ADMIN" delete
same "the user is gone" 0 "$(users)"
same "the allowlist row is gone" 0 "$(sql "select count(*) from app_private.allowlist where email = '$EMAIL'")"
same "the allowlist row went before the user" false "$(su_sql "select string_agg(allowlisted::text, ',') from qa_t.log")"

echo "sis_test_account_admin_test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
