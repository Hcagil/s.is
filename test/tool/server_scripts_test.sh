#!/usr/bin/env bash
# server-scripts.yml and its link to release.yml, read as written:
#
#   - triggers: workflow_dispatch only, with a required `reason` input;
#   - the first job refuses any ref but main and every later job needs it;
#   - concurrency group `release` (release.yml's own), cancel-in-progress false;
#   - every job that reads a secret runs in environment play-internal;
#   - no build, store upload, tag, release notes or migration apply step;
#   - release.yml calls the private-server action with mode local (private
#     gate) and mode linked (publish);
#   - the "Refuse when production is behind main" run block, run as written
#     against a fake `supabase` and a fake migrations folder: applied older
#     than main's newest file -> exit 1 "production is behind main: run the
#     normal release"; equal or newer -> exit 0; an unreadable applied
#     version (CLI fails or prints no 14-digit version) -> exit 1; files that
#     are not <14 digits>_*.sql are ignored; the newest file is the highest
#     number, not the last one listed.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
w=.github/workflows/server-scripts.yml
r=.github/workflows/release.yml

job() { # <file> <job id>: the job's lines
  awk -v j="$2" '/^jobs:/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_-]+:/ { cur = $1; sub(":", "", cur) }
    in_jobs && cur == j' "$1"
}
has() { grep -Eq -- "$2" <<< "$1"; }

# --- triggers
on=$(awk '/^on:/ { f = 1; next } f && /^[^ ]/ { exit } f' "$w")
has "$on" '^  workflow_dispatch:' || fail "no workflow_dispatch trigger"
[ "$(grep -Ec '^  [a-z_]+:' <<< "$on")" = 1 ] || fail "triggers other than workflow_dispatch: $on"
reason=$(awk '/^      reason:/ { f = 1; next } f && /^      [a-z]/ { exit } f' <<< "$on")
has "$reason" '^        required: true$' || fail "reason input not required"
has "$on" '^      reason:' || fail "no reason input"

# --- ref guard
guard=$(job "$w" guard)
has "$guard" 'refs/heads/main' || fail "guard does not name refs/heads/main"
has "$guard" 'exit 1' || fail "guard does not exit 1"
jobs=$(awk '/^jobs:/ { f = 1; next } f && /^  [A-Za-z_-]+:/ { sub(":", "", $1); print $1 }' "$w")
for j in $jobs; do
  [ "$j" = guard ] && continue
  has "$(job "$w" "$j")" '^    needs: .*guard' || fail "job $j does not need guard"
done

# --- concurrency
grep -Eq '^concurrency: \{ group: release, cancel-in-progress: false \}' "$w" || fail "concurrency is not group release / cancel-in-progress false"
grep -Eq 'group: release' "$r" || fail "release.yml no longer uses group release"

# --- environment on every secret-reading job
for j in $jobs; do
  body=$(job "$w" "$j")
  if has "$body" '(secrets|vars)\.'; then
    has "$body" '^    environment: play-internal$' || fail "job $j reads secrets outside environment play-internal"
  fi
done
has "$(job "$w" install)" 'secrets\.SUPABASE_ACCESS_TOKEN' || fail "install job no longer reads the access token (test is blind)"

# --- nothing that ships an app
bad='flutter|gradle|bundleRelease|upload|r0adkll|git tag|gh release|release-notes|whats_new|db push|migration up|db reset|--include-all'
if grep -Eiv '^ *#' "$w" | grep -Ein "$bad"; then fail "server-scripts.yml has a build, upload, tag, notes or migration-apply step"; fi

# --- release.yml uses the action in both modes
uses_mode() { # <file> <job> <mode>
  job "$1" "$2" | awk -v m="$3" '/uses: \.\/\.github\/actions\/private-server/ { f = 1; next } f && /^      - / { f = 0 } f && $1 == "mode:" && $2 == m { ok = 1 } END { exit !ok }'
}
uses_mode "$r" private-gate local || fail "release.yml private-gate lacks the action with mode local"
uses_mode "$r" publish linked || fail "release.yml publish lacks the action with mode linked"
uses_mode "$w" private-gate local || fail "server-scripts.yml private-gate lacks mode local"
uses_mode "$w" install linked || fail "server-scripts.yml install lacks mode linked"
# the private steps live in the action only
for s in 'Check the private secrets' 'Install the private functions' 'Check the private handlers' 'Run the private tests'; do
  ! grep -q "name: $s" "$r" "$w" || fail "step '$s' is back in a workflow"
done

# --- migration-behind check, run as written
awk '/^ *- name: Refuse when production is behind main$/ { f = 1; next }
  f && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
  inrun { if ($0 ~ /^ *$/) { print ""; next } match($0, /^ */); if (RLENGTH <= ind) exit
    if (!body) body = RLENGTH; print substr($0, body + 1) }' "$w" > "$tmp/behind.sh"
[ -s "$tmp/behind.sh" ] || fail "no 'Refuse when production is behind main' run block"
mkdir "$tmp/bin"
cat > "$tmp/bin/supabase" <<'STUB'
#!/usr/bin/env bash
case "$*" in "db query --linked "*) ;; *) echo "unexpected args: $*" >&2; exit 64 ;; esac
printf '%s\n' "${STUB_OUT:-}"; exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/bin/supabase"

run_behind() { # <label> <want rc> <want text|-> <STUB_OUT> <STUB_RC> <files...>
  local label=$1 want=$2 text=$3 out=$4 src=$5; shift 5
  local d="$tmp/case"; rm -rf "$d"; mkdir -p "$d/supabase/migrations"
  for f in "$@"; do : > "$d/supabase/migrations/$f"; done
  local rc=0
  (cd "$d" && PATH="$tmp/bin:$PATH" STUB_OUT=$out STUB_RC=$src GITHUB_STEP_SUMMARY="$d/summary" bash -e "$tmp/behind.sh") > "$tmp/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || fail "$label: exit $rc, want $want ($(cat "$tmp/out"))"
  [ "$text" = - ] || grep -qF -- "$text" "$tmp/out" || fail "$label: output [$(cat "$tmp/out")] lacks [$text]"
}
table=$'version\n20260101000002\n'
behind='production is behind main: run the normal release'
run_behind "applied older" 1 "$behind" "$table" 0 20260101000001_a.sql 20260101000003_b.sql
run_behind "applied equal" 0 - "$table" 0 20260101000001_a.sql 20260101000002_b.sql
run_behind "applied newer" 0 - "$table" 0 20260101000001_a.sql
run_behind "newest is highest, not last listed" 1 "$behind" "$table" 0 20260101000009_z.sql 20260101000001_a.sql
run_behind "highest applied version counts" 0 - $'version\n20260101000001\n20260101000005' 0 20260101000003_a.sql
run_behind "junk file names ignored" 0 - "$table" 0 20260101000001_a.sql seed.sql 99999999_x.sql 202601010000099_x.sql README.md 20260101000099_x.txt
run_behind "unreadable: CLI fails" 1 "could not read the latest applied migration" "" 1 20260101000001_a.sql
run_behind "unreadable: no version printed" 1 "could not read the latest applied migration" $'version\n(null)' 0 20260101000001_a.sql
echo "server_scripts_test: ok"
