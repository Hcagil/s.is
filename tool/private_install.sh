#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

# usage: tool/private_install.sh local|linked
# env: PRIVATE_EXPECTED (empty or 1), PRIVATE_SQL_B64 (gzip, then base64), PRIVATE_PACK_VERSION (v + 16 hex),
#      PRIVATE_SUPABASE (command that runs the Supabase CLI, default: supabase)

fail() {
  echo "::error::$1" >&2
  exit 1
}

mode=${1:-}
case "$mode" in
  local|linked) ;;
  *) fail 'usage: local or linked' ;;
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
re=$(base64 -w0 < "$gz")
[ "${#re}" -le 100000 ] || fail 'the private install secret is longer than 100000 characters'

# $sup is left unquoted on purpose (it may be several words).
# db query -f runs ONE statement, so each file is wrapped into a single DO that executes the text.
if grep -q 'pkq_' "$sql"; then fail 'the private install holds a reserved tag'; fi
if grep -q 'pkw_' tool/private_check.sql; then fail 'the private check holds a reserved tag'; fi

printf 'do $pk$ begin execute $pkq_$' > "$chk"
cat "$sql" >> "$chk"
printf '$pkq_$; end $pk$;\n' >> "$chk"
$sup db query "--$mode" -f "$chk" >/dev/null 2>&1 || fail 'install failed'

# The check runs with the expected flag set in the same session, then compares the pack version.
printf 'do $pk$ begin perform set_config(%s, %s, false); execute $pkw_$' "'private.expected'" "'1'" > "$chk"
cat tool/private_check.sql >> "$chk"
printf '$pkw_$; if app_private.private_pack_version() is distinct from %s then raise exception %s; end if; end $pk$;\n' "'$PRIVATE_PACK_VERSION'" "'private pack is stale'" >> "$chk"
$sup db query "--$mode" -f "$chk" >/dev/null 2>&1 || fail 'private check failed'

echo 'The private part is installed and checked.'
