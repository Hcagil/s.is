#!/usr/bin/env bash
# tool/private_install.sh local, against the running local Supabase stack
# (start it first: docker compose run --rm supabase start).
#
#   - PRIVATE_EXPECTED unset or empty: exit 0, nothing installed;
#     any value other than ''/1 (2, yes, 0): non-zero, nothing installed;
#   - EXPECTED=1 with the real pack and its version: exit 0, the pack is in,
#     private_pack_version() returns PRIVATE_PACK_VERSION;
#   - EXPECTED=1 must fail, with nothing installed and no SQL or secret in the
#     output, on: empty or unset secret; bad base64; corrupt gzip (mid-stream
#     byte; CRC trailer only, content intact); truncated gzip (half; trailer cut
#     only, content intact); valid gzip cut between statements (version function
#     missing); empty SQL; oversize value (> 100000 base64 chars, otherwise a
#     valid pack); empty PRIVATE_PACK_VERSION; stale pack (secret built from an
#     older body); version function not matching the content hash; content not
#     matching its version (extra statement; `select 1;` with the current
#     version); a failing statement mid-pack (all or nothing); bad mode argument;
#   - after every run no temp file is left (repo tree, /tmp), and every file
#     handed to the CLI with -f was mode 600 while it existed.
# Fixtures are built at run time: neutral SQL made here, or the private pack read
# from the main checkout's .private/ops/private-sql (never copied into git).
# No private pack on this machine: skipped (exit 0) unless .private/ops/EXPECT_PRIVATE exists.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
priv="$main/.private/ops/private-sql"
shopt -s nullglob
body_files=("$priv"/0[0-8]*.sql)
shopt -u nullglob
if [ ${#body_files[@]} -eq 0 ]; then
  [ -e "$main/.private/ops/EXPECT_PRIVATE" ] && { echo 'FAIL: private pack expected but missing'; exit 1; }
  echo 'private_install_test: no private pack on this machine: skipped'; exit 0
fi
box=$(mktemp -d); trap 'rm -rf "$box"' EXIT
db() { docker exec -i supabase_db_s.is psql -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }

# Stand-in CLI: records the mode of every -f file, then runs the real CLI.
cat >"$box/sb" <<EOF
#!/usr/bin/env bash
prev=
for a in "\$@"; do
  if [ "\$prev" = -f ]; then stat -c '%a %n' "\$a" >>"$box/modes.run" 2>&1 || echo "missing \$a" >>"$box/modes.run"; fi
  prev=\$a
done
exec docker compose run --rm supabase "\$@"
EOF
chmod +x "$box/sb"
SB="$box/sb"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

ver_of() { printf 'v%s' "$(sha256sum <"$1" | cut -c1-16)"; }
# verlines <ver> : the last two lines of a pack (same shape as pack-secrets.sh).
verlines() {
  printf '%s\n' "create or replace function app_private.private_pack_version() returns text language plpgsql security definer set search_path = '' as \$\$ begin return '$1'; end \$\$;"
  echo "revoke all on function app_private.private_pack_version() from public, anon, authenticated, service_role;"
}
b64() { gzip -9n <"$1" | base64 -w0; }

# real body with a marker table first (proves install happened / did not)
{ echo 'create table if not exists public.qa_f_marker (id int);'; cat "${body_files[@]}"; } >"$box/body"
V=$(ver_of "$box/body")
{ cat "$box/body"; verlines "$V"; } >"$box/pack"
GOOD=$(b64 "$box/pack")

baseline() {
  db -c "drop table if exists public.qa_f_marker; drop table if exists public.qa_f_other;
create or replace function app_private.private_pack_version() returns text language sql as \$\$ select 'vbaseline'::text \$\$;" >/dev/null
}
installed_version() { db -c 'select app_private.private_pack_version()' 2>/dev/null || echo none; }
marker() { db -c "select coalesce(to_regclass('public.qa_f_marker')::text, '-')"; }

# run <name> <mode> <EXPECTED|-unset-> <B64|-unset-> <VERSION|-unset-> [cli]
run() {
  local name=$1 mode=$2 e=$3 s=$4 v=$5 cli=${6:-$SB}
  baseline; : >"$box/modes.run"; rm -rf "$box/tmp"; mkdir "$box/tmp"
  touch "$box/mark"; sleep 1
  local envs=(env -u PRIVATE_EXPECTED -u PRIVATE_SQL_B64 -u PRIVATE_PACK_VERSION "PRIVATE_SUPABASE=$cli" "TMPDIR=$box/tmp")
  [ "$e" = -unset- ] || envs+=("PRIVATE_EXPECTED=$e")
  [ "$s" = -unset- ] || envs+=("PRIVATE_SQL_B64=$s")
  [ "$v" = -unset- ] || envs+=("PRIVATE_PACK_VERSION=$v")
  code=0; out=$("${envs[@]}" tool/private_install.sh $mode 2>&1) || code=$?
  local left
  left=$( { find "$repo" -path "$repo/.git" -prune -o -path "$repo/supabase/.temp" -prune -o -path "$repo/.dart_tool" -prune -o -path "$repo/build" -prune -o -type f -newer "$box/mark" -print; find "$box/tmp" -mindepth 1; } | grep -v '^$' || true)
  [ -z "$left" ] || fail "$name: left behind: $left"
  local f
  while read -r _ f; do [ ! -e "$f" ] || fail "$name: -f file left behind: $f"; done < <(grep -v '^missing ' "$box/modes.run" || true)
  cat "$box/modes.run" >>"$box/modes"
  echo "$name: exit $code"
}
# refused <name> : the last run failed and said nothing secret.
refused() {
  [ "$code" != 0 ] || fail "$1: exit 0"
  local lc=${out,,}
  case "$lc" in *create*|*select*|*app_private*|*"${GOOD:0:24}"*|*"${2:-${GOOD:0:24}}"*) fail "$1: output leaks SQL or secret: $out";; esac
}
# bad <name> : refused, and nothing was installed (the failure comes before or inside the one install statement).
bad() {
  refused "$@"
  [ "$(marker)" = - ] || fail "$1: pack was installed"
  [ "$(installed_version)" = vbaseline ] || fail "$1: version changed to $(installed_version)"
}

baseline

# --- EXPECTED switch
for e in -unset- ''; do
  run "expected '$e'" local "$e" "$GOOD" "$V"
  [ "$code" = 0 ] || fail "expected '$e': exit $code ($out)"
  [ "$(marker)" = - ] || fail "expected '$e': installed"
  [ "$(installed_version)" = vbaseline ] || fail "expected '$e': version changed"
done
for e in 2 yes 0 ' 1' true; do run "expected '$e'" local "$e" "$GOOD" "$V"; bad "expected '$e'"; done

# --- mode argument
for m in '' foo LOCAL '--local' 'local extra'; do run "mode '$m'" "$m" 1 "$GOOD" "$V"; bad "mode '$m'"; done

# --- secret decoding
run 'empty secret' local 1 '' "$V"; bad 'empty secret'
run 'unset secret' local 1 -unset- "$V"; bad 'unset secret'
run 'bad base64' local 1 '!!!not*base64!!!' "$V"; bad 'bad base64'
gzip -9n <"$box/pack" >"$box/gz"; n=$(stat -c %s "$box/gz")
cp "$box/gz" "$box/c1"; printf '\xff\x00\xff\x00' | dd of="$box/c1" bs=1 seek=$((n / 2)) conv=notrunc status=none
run 'corrupt gzip (mid-stream)' local 1 "$(base64 -w0 <"$box/c1")" "$V"; bad 'corrupt gzip (mid-stream)'
cp "$box/gz" "$box/c2"; printf '\x00\x00\x00\x00' | dd of="$box/c2" bs=1 seek=$((n - 8)) conv=notrunc status=none
run 'corrupt gzip (CRC only, content intact)' local 1 "$(base64 -w0 <"$box/c2")" "$V"; bad 'corrupt gzip (CRC only, content intact)'
run 'truncated gzip (half)' local 1 "$(head -c $((n / 2)) "$box/gz" | base64 -w0)" "$V"; bad 'truncated gzip (half)'
run 'truncated gzip (trailer cut, content intact)' local 1 "$(head -c $((n - 8)) "$box/gz" | base64 -w0)" "$V"; bad 'truncated gzip (trailer cut, content intact)'
run 'valid gzip cut between statements' local 1 "$(b64 "$box/body")" "$V"; bad 'valid gzip cut between statements'
run 'empty SQL' local 1 "$(: | gzip -9n | base64 -w0)" "$V"; bad 'empty SQL'

# --- oversize: a valid pack padded with an incompressible comment
{ echo 'create table if not exists public.qa_f_marker (id int);'; head -c 78000 /dev/urandom | base64 -w0 | sed 's/^/-- /'; echo; cat "${body_files[@]}"; } >"$box/bigbody"
BV=$(ver_of "$box/bigbody"); { cat "$box/bigbody"; verlines "$BV"; } >"$box/big"; BIG=$(b64 "$box/big")
[ ${#BIG} -gt 100000 ] && [ ${#BIG} -lt 131000 ] || fail "fixture: oversize value ${#BIG} chars, want 100001..130999 (env limit 131072)"
run 'oversize value' local 1 "$BIG" "$BV"; bad 'oversize value' "${BIG:0:24}"

# --- version
run 'empty PRIVATE_PACK_VERSION' local 1 "$GOOD" ''; refused 'empty PRIVATE_PACK_VERSION'
run 'unset PRIVATE_PACK_VERSION' local 1 "$GOOD" -unset-; refused 'unset PRIVATE_PACK_VERSION'
{ cat "$box/body"; echo '-- older build'; } >"$box/oldbody"; OV=$(ver_of "$box/oldbody")
{ cat "$box/oldbody"; verlines "$OV"; } >"$box/old"
run 'stale pack' local 1 "$(b64 "$box/old")" "$V"; refused 'stale pack'
# content hash = V, but the version function says something else
{ cat "$box/body"; verlines v0000000000000000; } >"$box/wrongfn"
run 'version function not V' local 1 "$(b64 "$box/wrongfn")" "$V"; refused 'version function not V'
# version function = V, but the content has an extra statement
{ cat "$box/body"; echo 'create table if not exists public.qa_f_other (id int);'; verlines "$V"; } >"$box/extra"
run 'content not matching its version' local 1 "$(b64 "$box/extra")" "$V"; refused 'content not matching its version'
[ "$(db -c "select coalesce(to_regclass('public.qa_f_other')::text, '-')")" = - ] || fail 'content not matching: extra statement ran'
run 'select 1 with the current version' local 1 "$(printf 'select 1;\n' | gzip -9n | base64 -w0)" "$V"; refused 'select 1 with the current version'

# --- all or nothing: a failing statement after the marker, version consistent
{ cat "$box/body"; echo 'select 1/0;'; } >"$box/failbody"; FV=$(ver_of "$box/failbody")
{ cat "$box/failbody"; verlines "$FV"; } >"$box/fail"
run 'failing statement mid-pack' local 1 "$(b64 "$box/fail")" "$FV"; bad 'failing statement mid-pack'

# --- the good path, with the production CLI form
run 'real pack' local 1 "$GOOD" "$V" 'docker compose run --rm supabase'
[ "$code" = 0 ] || fail "real pack: exit $code ($out)"
[ "$(marker)" != - ] || fail 'real pack: not installed'
[ "$(installed_version)" = "$V" ] || fail "real pack: version $(installed_version), want $V"
baseline
run 'real pack (stand-in CLI)' local 1 "$GOOD" "$V"
[ "$code" = 0 ] || fail "real pack (stand-in): exit $code ($out)"
[ "$(installed_version)" = "$V" ] || fail "real pack (stand-in): version $(installed_version)"

# --- temp files handed to the CLI
if [ -s "$box/modes" ]; then
  grep -v '^600 ' "$box/modes" && fail 'a -f file was not mode 600 (or missing)'
else
  fail 'the CLI never got a -f file (mode not checkable)'
fi

db -c 'drop table if exists public.qa_f_marker; drop table if exists public.qa_f_other;' >/dev/null
[ "$fails" = 0 ] && echo 'private_install_test: all passed' || { echo "private_install_test: $fails failed"; exit 1; }
