#!/usr/bin/env bash
# release.yml "Set the admin chat owner once", run as written (lifted out of the
# workflow, not copied) against the LOCAL Supabase database, with a stand-in
# `supabase` CLI that sends the query to that database. Under GitHub's default
# `bash -e` and under `bash -eo pipefail`:
#
# - owners empty + OWNER_EMAIL of an existing account (any letter case) -> that
#   account becomes the owner;
# - an owner already set is never replaced, whatever OWNER_EMAIL says;
# - OWNER_EMAIL empty -> exits 0 without calling the CLI;
# - an address with no account, or one carrying SQL, inserts nothing;
# - the step prints nothing, and never the address -- even when the CLI fails
#   and echoes the query back (this repository's logs are public);
# - the script never pastes a ${{ }} expression (the address arrives by env).
#
# Needs the local stack (`supabase start`); the owners table must be empty.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${SIS_DB_CONTAINER:-supabase_db_s.is}"
tmp=$(mktemp -d)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "not ok - $1"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
sql() { docker exec -i "$DB" psql -U postgres -At -v ON_ERROR_STOP=1 -q; }

OWN=00000000-0000-0000-0000-0000000a5e01
OTH=00000000-0000-0000-0000-0000000a5e02
cleanup() {
  # owners was empty when the test began (checked below): whatever is in it now, this test put there
  [ "${EMPTY_AT_START:-0}" = 1 ] && sql <<<"delete from app_private.owners;" >/dev/null 2>&1
  sql <<<"delete from app_private.owners where user_id in ('$OWN','$OTH');
          delete from auth.users where id in ('$OWN','$OTH');
          delete from public.conversations c where c.admin_chat and not exists
            (select 1 from public.conversation_members m where m.conversation_id = c.id);" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

[ "$(sql <<<'select count(*) from app_private.owners')" = 0 ] \
  || { echo "FAIL: app_private.owners is not empty on this stack; this test needs it empty"; exit 1; }
EMPTY_AT_START=1
sql <<<"insert into auth.users (id, email, email_confirmed_at) values
          ('$OWN', 'own-step@mail.test', now()), ('$OTH', 'other-step@mail.test', now());" >/dev/null

# the step's `run: |` block, de-indented (as test/tool/workflow_pipes_test.sh lifts it)
name="Set the admin chat owner once"
awk -v n="- name: $name" '
  index($0, n) && substr($0, index($0, n) + length(n)) == "" { found = 1; next }
  found && !inrun && /^ *- / { exit }
  found && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
  inrun {
    if ($0 ~ /^ *$/) { print ""; next }
    match($0, /^ */); if (RLENGTH <= ind) exit
    if (!body) body = RLENGTH
    print substr($0, body + 1)
  }' .github/workflows/release.yml > "$tmp/step.sh"
[ -s "$tmp/step.sh" ] || { echo "FAIL: step '$name' not found in release.yml"; exit 1; }
check "the step pastes no \${{ }} expression into its script" bash -c "! grep -q '\\\${{' '$tmp/step.sh'"
check "OWNER_EMAIL comes from the secret, by env" \
  grep -qE '^ *OWNER_EMAIL: \$\{\{ secrets\.OWNER_EMAIL \}\}$' .github/workflows/release.yml

# Stand-in CLI: `supabase db query --linked <sql>` runs <sql> on the local DB and
# prints the result like the real one; CLI_FAIL=1 fails and echoes the query.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/supabase" <<EOF
#!/usr/bin/env bash
echo called >> "$tmp/calls"
[ "\$1 \$2 \$3" = "db query --linked" ] || { echo "stub: unexpected args" >&2; exit 2; }
if [ "\${CLI_FAIL:-0}" = 1 ]; then echo "ERROR: failed to run query: \$4" >&2; echo "query: \$4"; exit 1; fi
printf '%s\n' "\$4" | docker exec -i "$DB" psql -U postgres -v ON_ERROR_STOP=1
EOF
chmod +x "$tmp/bin/supabase"

owner() { sql <<<"select coalesce((select user_id::text from app_private.owners), 'none')"; }
reset_owner() { sql <<<"delete from app_private.owners" >/dev/null; }
# step <shell> <OWNER_EMAIL> [CLI_FAIL] -> exit code in $rc, output in $tmp/out, calls in $tmp/calls
step() {
  : > "$tmp/calls"; rc=0
  PATH="$tmp/bin:$PATH" OWNER_EMAIL=$2 CLI_FAIL=${3:-0} \
    SUPABASE_ACCESS_TOKEN=x SUPABASE_PROJECT_REF=x $1 "$tmp/step.sh" > "$tmp/out" 2>&1 || rc=$?
}
silent() { [ ! -s "$tmp/out" ]; }
no_email() { ! grep -qiE 'own-step|other-step|mail\.test|nobody' "$tmp/out"; }

for sh in "bash -e" "bash -eo pipefail"; do
  reset_owner
  step "$sh" ""
  check "[$sh] no secret: exits 0" test "$rc" = 0
  check "[$sh] no secret: the CLI is not called" test ! -s "$tmp/calls"
  check "[$sh] no secret: prints nothing" silent
  check "[$sh] no secret: no owner" test "$(owner)" = none

  step "$sh" "Own-Step@Mail.TEST"
  check "[$sh] empty owners: exits 0" test "$rc" = 0
  check "[$sh] empty owners: the account becomes the owner (letter case ignored)" test "$(owner)" = "$OWN"
  check "[$sh] empty owners: prints nothing" silent

  step "$sh" "other-step@mail.test"
  check "[$sh] owner set: exits 0" test "$rc" = 0
  check "[$sh] owner set: never replaced" test "$(owner)" = "$OWN"
  check "[$sh] owner set: prints nothing" silent

  reset_owner
  step "$sh" "nobody@mail.test"
  check "[$sh] no such account: exits 0" test "$rc" = 0
  check "[$sh] no such account: no owner" test "$(owner)" = none
  check "[$sh] no such account: the address is not printed" no_email

  step "$sh" "nobody@mail.test' or ''='"
  check "[$sh] an address carrying SQL inserts nothing" test "$(owner)" = none
  check "[$sh] an address carrying SQL: the address is not printed" no_email

  step "$sh" "other-step@mail.test" 1
  check "[$sh] failing CLI: the step still exits 0" test "$rc" = 0
  check "[$sh] failing CLI: the address is not printed" no_email
  check "[$sh] failing CLI: no owner" test "$(owner)" = none
done

echo "# $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
