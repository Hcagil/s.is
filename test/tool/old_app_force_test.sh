#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$repo/.github/workflows/release.yml"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

job_block() { local o; o=$(awk -v n="  $1:" '$0==n{f=1;print;next} f&&/^  [a-z_]+:/{exit} f{print}' "$wf"); printf '%s\n' "$o"; }
step_block() { local o; o=$(job_block "$1" | awk -v t="      - name: $2" '!d&&$0==t{f=1;print;next} f&&/^      - name:/{f=0;d=1} f&&!d{print}'); printf '%s\n' "$o"; }
lineno() { grep -n -F -x -- "$1" "$wf" | head -1 | cut -d: -f1 || true; }

body() { local o; o=$(step_block "$1" "$2" | awk '!d&&/^        run: \|$/{f=1;next} f&&/^          /{sub(/^          /,"");print;next} f{f=0;d=1}'); printf '%s\n' "$o"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mk() {
  rm -rf "$tmp/r" "$tmp/bin"
  mkdir -p "$tmp/bin" "$tmp/r/supabase/migrations"
  cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo v1.0.5+5
EOF
  chmod +x "$tmp/bin/gh"
  (cd "$tmp/r" && git init -q && git config user.email a@mail.test && git config user.name a && git config commit.gpgsign false)
  echo "select 0;" >"$tmp/r/supabase/migrations/001_old.sql"
}

tagit() {
  (cd "$tmp/r" && git add -A && git commit -qm base && git tag 'v1.0.5+5')
}

addm() {
  (cd "$tmp/r" && printf '%s\n' "$2" > "supabase/migrations/$1" && git add -A && git commit -qm "m $1")
}

fbody=$(body old_app 'Raise on request of a new migration')
if [[ -z "$fbody" ]]; then fail "f0: no force step body"; fi

runforce() {
  : >"$tmp/go"
  (cd "$tmp/r" && PATH="$tmp/bin:$PATH" RELEASE_CODE=250 GITHUB_OUTPUT="$tmp/go" bash -c "$fbody")
  go=$(cat "$tmp/go")
}

# f1
mk; tagit; addm 002_new.sql $'-- raise-minimum: old chat keys break\nselect 1;'; runforce
[[ "$go" == *"raise_to=250"* ]] || fail "f1: raise_to missing"
[[ "$go" == *"raise_reason=old chat keys break"* ]] || fail "f1: raise_reason missing"

# f2
mk; echo '-- raise-minimum: already shipped' >>"$tmp/r/supabase/migrations/001_old.sql"; tagit; addm 002_new.sql 'select 1;'; runforce
[[ -z "$go" ]] || fail "f2: output should be empty"

# f3
mk; tagit; addm 002_new.sql 'select 1;'; runforce
[[ -z "$go" ]] || fail "f3: output should be empty"

# f4
mk; tagit; echo '-- raise-minimum: edited later' >>"$tmp/r/supabase/migrations/001_old.sql"; (cd "$tmp/r" && git commit -am "edit old" -q); runforce
[[ -z "$go" ]] || fail "f4: output should be empty"

# f5
mk; tagit; addm 002_a.sql 'select 1;'; addm 003_b.sql $'-- raise-minimum: second one\nselect 2;'; runforce
[[ "$go" == *"raise_to=250"* ]] || fail "f5: raise_to missing"
[[ "$go" == *"raise_reason=second one"* ]] || fail "f5: raise_reason missing"

# Part 2
abody=$(body publish 'Check the Apple secrets for account deletion')
[[ -n "$abody" ]] || fail "a0: no Apple secrets step body"

runapple() {
  code=0
  out=$(env -i PATH="$PATH" "$@" bash -c "$abody" 2>&1) || code=$?
  echo "$code:$out"
}

# a1
out=$(runapple APPLE_TEAM_ID=x APPLE_SIWA_KEY_ID=x APPLE_SIWA_PRIVATE_KEY=x)
code=${out%%:*}
[[ "$code" -eq 0 ]] || fail "a1: code non-zero"

# a2
out=$(runapple APPLE_TEAM_ID= APPLE_SIWA_KEY_ID=x APPLE_SIWA_PRIVATE_KEY=x)
code=${out%%:*}
[[ "$code" -ne 0 ]] || fail "a2: code zero"
[[ "${out#*:}" == *"Missing GitHub secret(s): APPLE_TEAM_ID"* ]] || fail "a2: missing APPLE_TEAM_ID"

# a3
out=$(runapple APPLE_TEAM_ID=x APPLE_SIWA_KEY_ID= APPLE_SIWA_PRIVATE_KEY=x)
code=${out%%:*}
[[ "$code" -ne 0 ]] || fail "a3: code zero"
[[ "${out#*:}" == *"Missing GitHub secret(s): APPLE_SIWA_KEY_ID"* ]] || fail "a3: missing APPLE_SIWA_KEY_ID"

# a4
out=$(runapple APPLE_TEAM_ID=x APPLE_SIWA_KEY_ID=x APPLE_SIWA_PRIVATE_KEY=)
code=${out%%:*}
[[ "$code" -ne 0 ]] || fail "a4: code zero"
[[ "${out#*:}" == *"Missing GitHub secret(s): APPLE_SIWA_PRIVATE_KEY"* ]] || fail "a4: missing APPLE_SIWA_PRIVATE_KEY"

# a5
out=$(runapple APPLE_TEAM_ID=x APPLE_SIWA_PRIVATE_KEY=x)
code=${out%%:*}
[[ "$code" -ne 0 ]] || fail "a5: code zero"
[[ "${out#*:}" == *"Missing GitHub secret(s): APPLE_SIWA_KEY_ID"* ]] || fail "a5: missing APPLE_SIWA_KEY_ID"

[ "$fails" -eq 0 ] || { echo "old_app_force_test: $fails failed"; exit 1; }
echo "old_app_force_test: OK"
