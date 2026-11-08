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
#   - guard: reads no secret; "Refuse any ref but main" and "Refuse unless CI
#     is green on this commit" run as written against a fake gh: a green
#     ci.yml push run for $SHA passes; none, only another commit, or a failing
#     gh -> exit 1 "main's newest commit has no green CI yet...";
#   - "Refuse when production is behind main", run as written against a fake
#     `supabase` and a fake migrations folder: every main version applied
#     (extra applied ones fine) -> 0; any main version missing (also when a
#     newer one is applied) -> exit 1 naming each; files not <14 digits>_*.sql
#     are ignored; empty main list or empty applied list (CLI fails or prints
#     no version) -> exit 1.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
command -v jq >/dev/null || fail "jq is needed (fake gh filters with it)"
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

# --- guard: no secret, CI-green refusal and migration check, run as written
has "$guard" '(secrets|vars)\.' && fail "guard job reads a secret or variable"
has "$guard" '^      actions: read$' || fail "guard lacks actions: read"
step() { # <file> <step name> <out>: the step's run block, de-indented
  awk -v n="$2" '$0 ~ "^ *- name: " n "$" { f = 1; next }
  f && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
  inrun { if ($0 ~ /^ *$/) { print ""; next } match($0, /^ */); if (RLENGTH <= ind) exit
    if (!body) body = RLENGTH; print substr($0, body + 1) }' "$1" > "$3"
  [ -s "$3" ] || fail "no '$2' run block"
}
mkdir "$tmp/bin"
cat > "$tmp/bin/supabase" <<'STUB'
#!/usr/bin/env bash
case "$*" in "db query --linked select version from supabase_migrations.schema_migrations") ;; *) echo "unexpected args: $*" >&2; exit 64 ;; esac
printf '%s\n' "${STUB_OUT:-}"; exit "${STUB_RC:-0}"
STUB
# gh stand-in: insists on the exact question, answers from STUB_RUNS (a json
# list of runs) through the caller's own --jq filter, like the real gh.
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_RC:-0}" = 0 ] || exit "$STUB_RC"
a=" $* "
for want in "run list" "--workflow ci.yml" "--branch main" "--event push" "--status success" "--json headSha"; do
  case "$a" in *" $want "*|*" $want"*) ;; *) echo "unexpected gh args: $*" >&2; exit 64 ;; esac
done
while [ $# -gt 0 ]; do [ "$1" = --jq ] && { printf '%s' "$STUB_RUNS" | jq -r "$2"; exit; }; shift; done
exit 64
STUB
chmod +x "$tmp/bin/supabase" "$tmp/bin/gh"

run_gate() { # <label> <want rc> <want text|-> <script> <env...>
  local label=$1 want=$2 text=$3 script=$4; shift 4
  local d="$tmp/case"; rm -rf "$d"; mkdir -p "$d/supabase/migrations"
  local rc=0
  (cd "$d" && env PATH="$tmp/bin:$PATH" GITHUB_STEP_SUMMARY="$d/summary" "$@" bash -e "$script") > "$tmp/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || fail "$label: exit $rc, want $want ($(cat "$tmp/out"))"
  [ "$text" = - ] || grep -qF -- "$text" "$tmp/out" || fail "$label: output [$(cat "$tmp/out")] lacks [$text]"
}
step "$w" "Refuse any ref but main" "$tmp/ref.sh"
run_gate "main ref" 0 - "$tmp/ref.sh" REF=refs/heads/main REASON=why
run_gate "other branch" 1 "from main only" "$tmp/ref.sh" REF=refs/heads/feat/x REASON=why
run_gate "tag ref" 1 "from main only" "$tmp/ref.sh" REF=refs/tags/v1 REASON=why

step "$w" "Refuse unless CI is green on this commit" "$tmp/ci.sh"
nogreen="main's newest commit has no green CI yet: wait for CI or run the normal release"
sha=aaaa1111
run_gate "green run for the sha" 0 - "$tmp/ci.sh" SHA=$sha 'STUB_RUNS=[{"headSha":"bbbb2222"},{"headSha":"aaaa1111"}]'
run_gate "only an older commit is green" 1 "$nogreen" "$tmp/ci.sh" SHA=$sha 'STUB_RUNS=[{"headSha":"bbbb2222"}]'
run_gate "no green run" 1 "$nogreen" "$tmp/ci.sh" SHA=$sha 'STUB_RUNS=[]'
run_gate "gh fails" 1 "$nogreen" "$tmp/ci.sh" SHA=$sha 'STUB_RUNS=[{"headSha":"aaaa1111"}]' STUB_RC=1

step "$w" "Refuse when production is behind main" "$tmp/behind.sh"
run_behind() {
  local label=$1 want=$2 text=$3 out=$4 src=$5; shift 5
  local d="$tmp/case" rc=0; rm -rf "$d"; mkdir -p "$d/supabase/migrations"
  for f in "$@"; do : > "$d/supabase/migrations/$f"; done
  (cd "$d" && PATH="$tmp/bin:$PATH" STUB_OUT=$out STUB_RC=$src GITHUB_STEP_SUMMARY="$d/summary" bash -e "$tmp/behind.sh") > "$tmp/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || fail "$label: exit $rc, want $want ($(cat "$tmp/out"))"
  [ "$text" = - ] || grep -qF -- "$text" "$tmp/out" || fail "$label: output [$(cat "$tmp/out")] lacks [$text]"
}
t() { printf 'version\n'; printf '%s\n' "$@"; }
behind='production is behind main: run the normal release'
A=20260101000001 B=20260101000002 C=20260101000003
run_behind "same set" 0 - "$(t $A $B)" 0 ${A}_a.sql ${B}_b.sql
run_behind "production has more than main" 0 - "$(t $A $B $C)" 0 ${A}_a.sql ${B}_b.sql
run_behind "one main version missing, named" 1 "missing: $B" "$(t $A $C)" 0 ${A}_a.sql ${B}_b.sql ${C}_c.sql
run_behind "newest applied but an older one missing" 1 "missing: $A" "$(t $B $C)" 0 ${A}_a.sql ${B}_b.sql ${C}_c.sql
run_behind "missing message" 1 "$behind" "$(t $A)" 0 ${A}_a.sql ${B}_b.sql
run_behind "two missing both named" 1 "$B $C" "$(t $A)" 0 ${A}_a.sql ${B}_b.sql ${C}_c.sql
run_behind "junk file names ignored" 0 - "$(t $A)" 0 ${A}_a.sql seed.sql 99999999_x.sql 202601010000099_x.sql README.md 20260101000099_x.txt
run_behind "empty main list" 1 "could not read the migrations of main" "$(t $A)" 0 seed.sql
run_behind "empty applied list: no version" 1 "could not read the applied migrations" $'version\n(null)' 0 ${A}_a.sql
run_behind "empty applied list: CLI fails" 1 "could not read the applied migrations" "" 1 ${A}_a.sql
echo "server_scripts_test: ok"
