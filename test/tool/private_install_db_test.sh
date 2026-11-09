#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
box=$(mktemp -d)
fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

# S1: prerequisites
if ! command -v openssl >/dev/null 2>&1 || ! docker image inspect public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null 2>&1; then
  echo 'private_install_db_test: skipped (needs openssl and the local postgres image)'
  exit 0
fi

# S2: port, name, cleanup
PORT=$((20000 + RANDOM % 20000))
CTR=qa-pk-$$
trap 'docker rm -f "$CTR" >/dev/null 2>&1 || true; rm -rf "$box"' EXIT

# S3: TLS files
(
  cd "$box"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -subj "/CN=qa-ca" -days 2 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=qa-db" 2>/dev/null
  printf 'subjectAltName=IP:172.17.0.1\n' > ext
  openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out srv.crt -days 2 -extfile ext 2>/dev/null
  chmod 644 srv.crt ca.crt
)

# S4: start DB
P6543=(); ss -ltn 2>/dev/null | grep -q ':6543 ' || P6543=(-p 172.17.0.1:6543:5432)

docker run -d --name "$CTR" --user root \
  -e POSTGRES_PASSWORD=pw1x \
  -p 172.17.0.1:"$PORT":5432 \
  "${P6543[@]}" \
  -v "$box/srv.crt:/ssl/srv.crt:ro" \
  -v "$box/srv.key:/ssl/srv.key:ro" \
  --entrypoint bash public.ecr.aws/supabase/postgres:17.6.1.167 \
  -c 'install -m 600 -o postgres /ssl/srv.key /tmp/k.key; \
      install -m 644 /ssl/srv.crt /tmp/k.crt; \
      printf "local all all trust\nhostssl all qa_trust all trust\nhostssl all all all scram-sha-256\n" > /tmp/hba.conf; chmod 644 /tmp/hba.conf; \
      exec docker-entrypoint.sh postgres -D /etc/postgresql -c hba_file=/tmp/hba.conf -c listen_addresses=* -c ssl=on -c ssl_cert_file=/tmp/k.crt -c ssl_key_file=/tmp/k.key' >/dev/null

# S5: helper to run psql
db() { docker exec -i "$CTR" psql -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }

# readiness loop
ok=0
for i in $(seq 1 60); do
  sleep 1
  if db -c 'select 1' >/dev/null 2>&1; then
    sleep 2
    if db -c 'select 1' >/dev/null 2>&1; then
      ok=1
      break
    fi
  fi
done
if [ "$ok" -ne 1 ]; then
  echo 'FAIL: database did not start'
  exit 1
fi

# S6: pgpass and CA
mkdir "$box/pg"
chmod 700 "$box/pg"
printf '172.17.0.1:%s:postgres:postgres:pw1x\n' "$PORT" > "$box/pg/pgpass"
chmod 600 "$box/pg/pgpass"
CA="$box/ca.crt"

docker exec -i "$CTR" psql -U supabase_admin -d postgres -qAt -c 'create role qa_trust superuser login' >/dev/null
mkdir "$box/pgt"; chmod 700 "$box/pgt"
printf '172.17.0.1:%s:postgres:qa_trust:x\n' "$PORT" > "$box/pgt/pgpass"; chmod 600 "$box/pgt/pgpass"
PT="$box/pgt/pgpass"

# S7: source dir and helper functions
mkdir -p "$box/src/tool" "$box/src/.github/workflows"

green_check() {
  cat >"$box/src/tool/private_check.sql" <<'EOF'
do $$ begin
  if current_setting('private.expected', true) is distinct from '1' then
    raise exception 'not expected';
  end if;
  if to_regclass('public.qa_marker') is null then
    raise exception 'marker missing';
  end if;
end $$;
EOF
}

red_check() {
  cat >"$box/src/tool/private_check.sql" <<'EOF'
do $$ begin
  raise exception 'red check';
end $$;
EOF
}

wf_with() {
  cat >"$box/src/.github/workflows/release.yml" <<'EOF'
      - name: private-server
EOF
}

wf_without() {
  cat >"$box/src/.github/workflows/release.yml" <<'EOF'
      - name: build
EOF
}

wf_none() {
  rm -f "$box/src/.github/workflows/release.yml"
}

# S8: pack creation helpers
make_pack() {
  body="$box/body"
  printf 'create schema if not exists app_private;\n' > "$body"
  printf 'create table if not exists public.qa_marker (id int);\n' >> "$body"
  V="v$(sha256sum "$body" | cut -c1-16)"
  cp "$body" "$box/pack"
  printf "create or replace function app_private.private_pack_version() returns text language plpgsql security definer set search_path = '' as \$\$ begin return '%s'; end \$\$;\n" "$V" >> "$box/pack"
  printf 'revoke all on function app_private.private_pack_version() from public;\n' >> "$box/pack"
  B64=$(gzip -9n <"$box/pack" | base64 -w0)
  OLDV=v00000000000000aa
}

# S9: baseline helpers
baseline() {
  local L="$1"
  db -c "drop table if exists public.qa_marker; create schema if not exists app_private; create or replace function app_private.private_pack_version() returns text language sql as \$\$ select '$L'::text \$\$;" >/dev/null
}

installed() {
  db -c "select to_regclass('public.qa_marker') is not null"
}

livever() {
  db -c 'select app_private.private_pack_version()'
}

# S10: docker shim
mkdir -p "$box/bin" "$box/seen"
REAL=$(command -v docker)
cat >"$box/bin/docker" <<EOF
#!/usr/bin/env bash
REAL="$REAL"
printf '%s\n' "\$@" >>"$box/docker.args"
args=("\$@")
for ((i=0; i<\${#args[@]}-1; i++)); do
  if [ "\${args[i]}" = -f ] && [ -f "\$PWD/\${args[i+1]#/w/}" ]; then
    f="\$PWD/\${args[i+1]#/w/}"
    n="$box/seen/\$(date +%s%N).sql"
    cp "\$f" "\$n"; stat -c %a "\$f" >>"$box/seen.modes"
  fi
done
exec \$REAL "\$@"
EOF
chmod +x "$box/bin/docker"
touch "$box/docker.args" "$box/seen.modes"

# S11: run helper
run() {
  local name="$1" pgp="$2" ca="$3" b64="$4" ver="$5"
  code=0
  (cd "$box/src" && env -u PRIVATE_EXPECTED PRIVATE_EXPECTED=1 PRIVATE_SQL_B64="$b64" PRIVATE_PACK_VERSION="$ver" PRIVATE_DB_PGPASS="$pgp" PRIVATE_DB_CA="$ca" PATH="$box/bin:$PATH" "$repo/tool/private_install.sh" db) >"$box/out" 2>&1 || code=$?
  out=$(cat "$box/out")
  echo "$name: exit $code"
  left=$(find "$box/src" -name '.private_pack.*')
  [ -z "$left" ] || fail "$name: temp file left"
  case "$out" in
    *pw1x*) fail "$name: output holds the password";;
  esac
}

finish() {
  [ "$fails" = 0 ] && echo 'private_install_db_test: all passed' || { echo "private_install_db_test: $fails failed"; exit 1; }
}

P="$box/pg/pgpass"
# helper to check results
expect() {
  local NAME="$1" CODE="$2" INSTALLED="$3" LIVE="$4"
  if [ "$code" -ne "$CODE" ]; then
    fail "$NAME: exit $code expected $CODE"
  fi
  if [ "$(installed)" != "$INSTALLED" ]; then
    fail "$NAME: installed expected $INSTALLED"
  fi
  if [ "$(livever)" != "$LIVE" ]; then
    fail "$NAME: livever expected $LIVE"
  fi
}

make_pack; green_check

# a. same version
wf_with
baseline "$V"
run 'same version' "$P" "$CA" "$B64" "$V"
expect 'same version' 0 t "$V"

# b. differs, release installs
wf_with
baseline "$OLDV"
run 'differs, release installs' "$P" "$CA" "$B64" "$V"
expect 'differs, release installs' 3 f "$OLDV"

# c. wf_none
wf_none
baseline "$OLDV"
run 'wf_none' "$P" "$CA" "$B64" "$V"
expect 'wf_none' 3 f "$OLDV"

# d. wf_without
wf_without
baseline "$OLDV"
rm -f "$box"/seen/*
: >"$box/seen.modes"
: >"$box/docker.args"
run 'differs, no release step' "$P" "$CA" "$B64" "$V"
expect 'differs, no release step' 0 t "$V"

# shape checks on case d's files
inst=$(grep -l qa_marker "$box"/seen/*.sql | head -1)
[ -n "$inst" ] || fail 'no install file seen'
[ "$(grep -c '^do \$pk\$' "$inst")" -eq 1 ] || fail 'wrong do count'
[ "$(grep -c '^end \$pk\$;' "$inst")" -eq 1 ] || fail 'wrong end count'
grep -q "set_config('private.expected', '1', true)" "$inst" || fail 'expected config missing'
n_create=$(grep -n 'create table' "$inst" | cut -d: -f1)
n_set=$(grep -n "set_config('private.expected'" "$inst" | cut -d: -f1)
n_ver=$(grep -n "private pack is stale" "$inst" | cut -d: -f1)
[ -n "$n_create" ] || fail 'create line missing'
[ -n "$n_set" ] || fail 'set_config line missing'
[ -n "$n_ver" ] || fail 'stale line missing'
[ "$n_create" -lt "$n_set" ] || fail 'create before set_config'
[ "$n_set" -lt "$n_ver" ] || fail 'set_config before stale'
[ "$(cat "$box/seen.modes")" = "$(printf '600\n600\n')" ] || fail 'modes not 600'
grep -q pw1x "$box/docker.args" && fail 'password in docker args'

# e. red check rolls back
wf_without
red_check
baseline "$OLDV"
run 'red check rolls back' "$P" "$CA" "$B64" "$V"
expect 'red check rolls back' 1 f "$OLDV"

green_check
baseline "$OLDV"
run 'wrong pack version' "$P" "$CA" "$B64" v1111111111111111
expect 'wrong pack version' 1 f "$OLDV"

# f. refusals
wf_without
green_check
baseline "$OLDV"

# pgpass 644
chmod 644 "$PT"
run 'pgpass 644' "$PT" "$CA" "$B64" "$V"
chmod 600 "$PT"
expect 'pgpass 644' 1 f "$OLDV"

# folder 755
chmod 755 "$box/pgt"
run 'folder 755' "$PT" "$CA" "$B64" "$V"
chmod 700 "$box/pgt"
expect 'folder 755' 1 f "$OLDV"

# port 6543
mkdir "$box/pg6543"
chmod 700 "$box/pg6543"
printf '172.17.0.1:6543:postgres:qa_trust:x\n' >"$box/pg6543/pgpass"
chmod 600 "$box/pg6543/pgpass"
run 'port 6543' "$box/pg6543/pgpass" "$CA" "$B64" "$V"
expect 'port 6543' 1 f "$OLDV"

# pgpass missing
run 'pgpass missing' "$box/pg/nope" "$CA" "$B64" "$V"
expect 'pgpass missing' 1 f "$OLDV"

# CA missing
run 'CA missing' "$P" "$box/nope.crt" "$B64" "$V"
expect 'CA missing' 1 f "$OLDV"

# malformed pgpass
mkdir "$box/pgbad"
chmod 700 "$box/pgbad"
printf 'onlyone\n' >"$box/pgbad/pgpass"
chmod 600 "$box/pgbad/pgpass"
run 'malformed pgpass' "$box/pgbad/pgpass" "$CA" "$B64" "$V"
expect 'malformed pgpass' 1 f "$OLDV"

# pack not matching version
run 'pack not matching version' "$P" "$CA" "$B64" v2222222222222222
case "$out" in *'does not match'*) ;; *) fail "pack not matching version: wrong message: $out";; esac
expect 'pack not matching version' 1 f "$OLDV"

# wrong CA: a different, self-made CA must be refused by verify-full
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$box/ca2.key" -out "$box/ca2.crt" -subj "/CN=qa-other-ca" -days 2 2>/dev/null
run 'wrong CA' "$PT" "$box/ca2.crt" "$B64" "$V"
expect 'wrong CA' 1 f "$OLDV"

# wrong host: the database answers on its own container address, which is not in the certificate names
CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CTR")
[ -n "$CIP" ] || fail 'wrong host: container address not found'
mkdir "$box/pgcip"; chmod 700 "$box/pgcip"
printf '%s:5432:postgres:qa_trust:x\n' "$CIP" >"$box/pgcip/pgpass"; chmod 600 "$box/pgcip/pgpass"
run 'wrong host' "$box/pgcip/pgpass" "$CA" "$B64" "$V"
expect 'wrong host' 1 f "$OLDV"

# new test block for symlink and permission checks
# 1. REFUSE folder: open755
mkdir "$box/open755"
chmod 755 "$box/open755"
cp "$PT" "$box/open755/pgpass"
chmod 600 "$box/open755/pgpass"
mkdir "$box/lnk755"
chmod 700 "$box/lnk755"
ln -s "$box/open755/pgpass" "$box/lnk755/pgpass"
run 'symlink to file in 755 folder' "$box/lnk755/pgpass" "$CA" "$B64" "$V"
case "$out" in
  *'the database password folder is too open'*) ;;
  *) fail "symlink to file in 755 folder: wrong message: $out" ;;
esac
expect 'symlink to file in 755 folder' 1 f "$OLDV"

# 2. REFUSE file: 644
mkdir "$box/pg644"
chmod 700 "$box/pg644"
printf '172.17.0.1:%s:postgres:qa_trust:x\n' "$PORT" > "$box/pg644/pgpass"
chmod 644 "$box/pg644/pgpass"
mkdir "$box/lnk644"
chmod 700 "$box/lnk644"
ln -s "$box/pg644/pgpass" "$box/lnk644/pgpass"
run 'symlink to 644 file' "$box/lnk644/pgpass" "$CA" "$B64" "$V"
case "$out" in
  *'the database password file is too open'*) ;;
  *) fail "symlink to 644 file: wrong message: $out" ;;
esac
expect 'symlink to 644 file' 1 f "$OLDV"

# 3. DANGLING
mkdir "$box/lnkdead"
chmod 700 "$box/lnkdead"
ln -s "$box/nowhere" "$box/lnkdead/pgpass"
run 'dangling symlink' "$box/lnkdead/pgpass" "$CA" "$B64" "$V"
case "$out" in
  *'the database password file is missing'*) ;;
  *) fail "dangling symlink: wrong message: $out" ;;
esac
expect 'dangling symlink' 1 f "$OLDV"

# 4. ACCEPT pgpass link
mkdir "$box/lnkok"
chmod 700 "$box/lnkok"
ln -s "$PT" "$box/lnkok/pgpass"
run 'symlink to 600 file in 700 folder' "$box/lnkok/pgpass" "$CA" "$B64" "$V"
expect 'symlink to 600 file in 700 folder' 0 t "$V"

# 5. ACCEPT CA link
baseline "$OLDV"
ln -s "$CA" "$box/ca-link.crt"
run 'symlinked CA' "$PT" "$box/ca-link.crt" "$B64" "$V"
expect 'symlinked CA' 0 t "$V"

[ ${#P6543[@]} -gt 0 ] || echo 'note: host port 6543 was busy, the 6543 case only checks the refusal message'
finish
