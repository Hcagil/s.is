#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

# usage: tool/private_install.sh local|linked|db
#      db mode exit code 3 = refused because the pack version differs from the live one
# env: PRIVATE_EXPECTED (empty or 1), PRIVATE_SQL_B64 (gzip, then base64), PRIVATE_PACK_VERSION (v + 16 hex),
#      PRIVATE_SUPABASE (command that runs the Supabase CLI, default: supabase)
#      db mode: PRIVATE_DB_PGPASS (path of a pgpass file, host:port:db:user:password), PRIVATE_DB_CA (path of the server CA cert), PRIVATE_PSQL_IMAGE (default public.ecr.aws/supabase/postgres:17.6.1.167)

fail() {
  echo "::error::$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail 'usage: exactly one argument, local, linked or db'
mode=${1:-}
case "$mode" in
  local|linked|db) ;;
  *) fail 'usage: local, linked or db' ;;
esac

case "${PRIVATE_EXPECTED:-}" in
  ''|1) ;;
  *) fail 'PRIVATE_EXPECTED must be empty or 1' ;;
esac

if [ "${PRIVATE_EXPECTED:-}" != '1' ]; then
  echo 'The private part is not expected.'
  exit 0
fi

[ -n "${PRIVATE_SQL_B64:-}" ] || fail 'the private install secret is empty'
[ -n "${PRIVATE_PACK_VERSION:-}" ] || fail 'the private pack version is empty'
printf %s "$PRIVATE_PACK_VERSION" | grep -Eq '^v[0-9a-f]{16}$' || fail 'the private pack version is malformed'
[ -f tool/private_check.sql ] || fail 'private_check.sql is missing'

sup=${PRIVATE_SUPABASE:-supabase}

if [ "$mode" = db ]; then
  pgp=${PRIVATE_DB_PGPASS:-}
  ca=${PRIVATE_DB_CA:-}
  [ -f "$pgp" ] || fail 'the database password file is missing'
  [ -f "$ca" ] || fail 'the database CA file is missing'
  # Resolve links first: the checks below must see the real file and the real folder, not the link.
  pgp=$(readlink -f "$pgp"); ca=$(readlink -f "$ca")
  # Refuse a password file wider than 600 or its real folder wider than 700 (no group or other bits).
  [ $((8#$(stat -c %a "$pgp") & 8#077)) -eq 0 ] || fail 'the database password file is too open'
  [ $((8#$(stat -c %a "$(dirname "$pgp")") & 8#077)) -eq 0 ] || fail 'the database password folder is too open'
  # Only host, port, db and user are read (cut keeps the password field out of the shell).
  IFS=: read -r dbhost dbport dbname dbuser < <(cut -d: -f1-4 "$pgp" | head -n1) || true
  [ -n "$dbhost" ] && [ -n "$dbport" ] && [ -n "$dbname" ] && [ -n "$dbuser" ] || fail 'the database password file is malformed'
  [ "$dbport" != 6543 ] || fail 'the transaction pooler port 6543 is refused: use the direct host or the session pooler on 5432'
fi

# db mode only: psql reads the password from the mounted pgpass file, so it is never in an argument or in ps.
run_sql_out() {
  docker run --rm --user "$(id -u):$(id -g)" -e PGPASSFILE=/pg/pgpass \
    -v "$pgp:/pg/pgpass:ro" -v "$ca:/pg/ca.crt:ro" -v "$PWD:/w:ro" -w /w \
    --entrypoint psql "${PRIVATE_PSQL_IMAGE:-public.ecr.aws/supabase/postgres:17.6.1.167}" \
    -X -q -A -t -v ON_ERROR_STOP=1 -f "$1" \
    "host=$dbhost port=$dbport dbname=$dbname user=$dbuser sslmode=verify-full sslrootcert=/pg/ca.crt" 2>/dev/null
}

run_sql() {
  if [ "$mode" = db ]; then
    run_sql_out "$1" >/dev/null
  else
    $sup db query "--$mode" -f "$1" >/dev/null 2>&1
  fi
}

# Temp files stay in the working directory so a container sees them; mode 600, removed on exit.
gz=$(mktemp .private_pack.XXXXXX)
sql=$(mktemp .private_pack.XXXXXX)
chk=$(mktemp .private_pack.XXXXXX)
trap 'rm -f "$gz" "$sql" "$chk"' EXIT
chmod 600 "$gz" "$sql" "$chk"

printf %s "$PRIVATE_SQL_B64" | base64 -d > "$gz" || fail 'the private secret is not base64'
gzip -t "$gz" 2>/dev/null || fail 'the private secret is not a valid gzip'
gzip -dc "$gz" > "$sql" || fail 'the private secret cannot be unpacked'
[ -s "$sql" ] || fail 'the private install is empty'
# The version is the hash of the pack without its last two lines (the version function), as pack-secrets.sh computes it.
[ "v$(head -n -2 "$sql" | sha256sum | cut -c1-16)" = "$PRIVATE_PACK_VERSION" ] || fail 'the private pack does not match its version'
re=$(base64 -w0 < "$gz")
[ "${#re}" -le 100000 ] || fail 'the private install secret is longer than 100000 characters'

if [ "$mode" = db ]; then
  live=$(mktemp .private_pack.XXXXXX)
  chmod 600 "$live"
  trap 'rm -f "$gz" "$sql" "$chk" "$live"' EXIT
  cat > "$live" <<'SQL'
select case when to_regprocedure('app_private.private_pack_version()') is not null then 'select app_private.private_pack_version()' else 'select ''''' end \gexec
SQL
  liveversion=$(run_sql_out "$live" | tr -d '[:space:]') || fail 'could not read the live pack version'
  if [ "$liveversion" != "$PRIVATE_PACK_VERSION" ]; then
    # While any GitHub workflow or action still installs a pack, this script may only re-install the live version.
    # grep: 0 = match, 1 = none, 2 = error (unreadable file); only 1 is safe. -R follows symlinked files.
    wf_hit=0; grep -RqE 'private-server|private_install\.sh|PRIVATE_SQL_B64' .github/workflows || wf_hit=$?
    if [ ! -f .github/workflows/release.yml ] || [ -d .github/actions/private-server ] || [ "$wf_hit" -ne 1 ]; then
      echo '::error::the pack version differs from the live one and a GitHub workflow or action still installs a pack' >&2
      exit 3
    fi
  fi
fi

# $sup is left unquoted on purpose (it may be several words).
# db query -f runs ONE statement, so each file is wrapped into a single DO that executes the text.
if grep -q 'pkq_' "$sql"; then fail 'the private install holds a reserved tag'; fi
if grep -q 'pkw_' tool/private_check.sql; then fail 'the private check holds a reserved tag'; fi

# One statement = one transaction: a red check rolls the install back.
printf 'do $pk$ begin execute $pkq_$' > "$chk"
cat "$sql" >> "$chk"
printf '$pkq_$;\n' >> "$chk"
printf 'perform set_config(%s, %s, true);\n' "'private.expected'" "'1'" >> "$chk"
printf 'execute $pkw_$' >> "$chk"
cat tool/private_check.sql >> "$chk"
printf '$pkw_$;\n' >> "$chk"
printf 'if app_private.private_pack_version() is distinct from %s then raise exception %s; end if;\n' "'$PRIVATE_PACK_VERSION'" "'private pack is stale'" >> "$chk"
printf 'end $pk$;\n' >> "$chk"
run_sql "$chk" || fail 'install or check failed, nothing was changed'

echo 'The private part is installed and checked.'
