#!/usr/bin/env bash
# Static checks on the admin Apple path's workflows (the repo is PUBLIC, so
# what a workflow may print, take as input or be granted is checked as text):
#   admin-apple.yml  workflow_dispatch only; one input job_id, uuid-checked and
#                    passed through env; permissions exactly id-token: write
#                    and contents: read;
#                    ::add-mask:: of the email before any other output; the
#                    email never in argv; no step summary, artifacts or set -x.
#   release.yml      runs on a schedule and by hand: no workflow_run trigger
#                    and no tip-of-main check anywhere;
#                    deploys admin-apple and admin-apple-report; creates the
#                    vault secret admin_apple_url in `where not exists` form.
#   admin-apple.yml  RUN (A8-A12): the "Run the job" script runs in bash with
#                    fake curl / python3 / sleep: a fresh OIDC token, masked
#                    before use, for each report call (claim, progress,
#                    finish); the claim's JSON parses (no mask line captured
#                    in it); the email mask comes right after the claim;
#                    nothing else prints either value; the email reaches the
#                    tool only as TESTER_EMAIL; the exit code maps to finish.
#                    A failed token fetch stops the job on the claim, is
#                    ignored on progress and swallowed on finish.
#   release.yml, ios-ipa.yml  RUN (R1c, R1d): "Refuse a commit older than the
#                    last release" is the first step of publish, distribute and
#                    ipa, with its env and `if:` resolved as GitHub would, against
#                    a stubbed gh: attempt 1 always proceeds; attempt 2+ proceeds
#                    only when no release exists or the compare of the last tag
#                    with scope's sha is identical/ahead (behind, diverged or an
#                    unreadable compare refuses); ipa skips it for CI's call
#                    (upload false).
#   ios-signing-bootstrap.yml  its job runs behind environment apple-signing.
set -euo pipefail
cd "$(dirname "$0")/../.."

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }

F=${ADMIN_APPLE_YML:-.github/workflows/admin-apple.yml}
R=${RELEASE_YML:-.github/workflows/release.yml}
B=${BOOTSTRAP_YML:-.github/workflows/ios-signing-bootstrap.yml}
I=${IOS_IPA_YML:-.github/workflows/ios-ipa.yml}
C=${CI_YML:-.github/workflows/ci.yml}

# Keys one level under the line matching $2 (first occurrence) in file $1.
child_keys() {
  awk -v pat="$2" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    !inb && $0 ~ pat { inb = 1; base = ind($0); want = -1; next }
    inb {
      if ($0 ~ /^[ \t]*(#.*)?$/) next
      i = ind($0)
      if (i <= base) exit
      if (want < 0) want = i
      if (i == want) { k = $0; sub(/^ */, "", k); sub(/:.*/, "", k); print k }
    }' "$1"
}

a1() { grep -qE '^\s+workflow_dispatch:' "$F" &&
  [ "$(child_keys "$F" '^on:')" = "workflow_dispatch" ]; }
a2() { [ "$(child_keys "$F" '^[[:space:]]+inputs:')" = "job_id" ]; }
a3() {
  grep -qE '\[0-9a-f\]\{8\}-' "$F" || return 1
  grep -qE 'inputs\.job_id' "$F" || return 1
  ! grep -E 'inputs\.job_id' "$F" | grep -vqE '^\s*[A-Z_][A-Z0-9_]*:\s*\$\{\{\s*(github\.event\.)?inputs\.job_id\s*\}\}\s*$'
}
a4() {
  # every permissions block holds exactly id-token: write and contents: read
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function close_block() { if (inb && keys != "contents: read|id-token: write|") bad = 1; inb = 0 }
    /^[[:space:]]*permissions:/ {
      close_block()
      blocks++; inb = 1; base = ind($0); keys = ""; n = 0
      rest = $0; sub(/^[[:space:]]*permissions:[[:space:]]*/, "", rest)
      if (rest != "" && rest !~ /^#/) bad = 1   # inline form (write-all, {...})
      next
    }
    inb {
      if ($0 ~ /^[ \t]*(#.*)?$/) next
      if (ind($0) <= base) { close_block() }
      else {
        l = $0; sub(/^[[:space:]]+/, "", l); sub(/[[:space:]]*(#.*)?$/, "", l)
        line[n++] = l
        # keys in sorted order: insertion sort of the few lines
        keys = ""; for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (line[j] < line[i]) { t = line[i]; line[i] = line[j]; line[j] = t }
        for (i = 0; i < n; i++) keys = keys line[i] "|"
        next
      }
    }
    END { close_block(); exit !(blocks >= 1 && !bad) }' "$F"
}
a5() {
  local e m
  e=$(grep -nE '(^|[^_A-Z])EMAIL=' "$F" | head -1 | cut -d: -f1)
  m=$(grep -n '::add-mask::.*EMAIL' "$F" | head -1 | cut -d: -f1)
  [ -n "$e" ] && [ -n "$m" ] && [ "$m" -gt "$e" ] && [ $((m - e)) -le 5 ] || return 1
  # (sed prints line N for an empty range N,N-1, so only look when lines lie between)
  [ $((m - e)) -eq 1 ] || ! sed -n "$((e + 1)),$((m - 1))p" "$F" | grep -qE 'echo|printf|cat |tee '
}
a6() {
  grep -q 'asc_signing.py tester' "$F" || return 1
  ! grep -qE 'asc_signing\.py.*\$\{?EMAIL' "$F" &&
    ! grep 'asc_signing.py tester' "$F" | grep -vq 'TESTER_EMAIL="$EMAIL"'
}
a7() { ! grep -qE 'GITHUB_STEP_SUMMARY|upload-artifact|set -x|set -o xtrace|bash -x|set -[a-wyz]*x' "$F"; }

# --- R1: no workflow_run trigger, no tip-of-main check left in any workflow --
r1() {
  ! grep -qE 'tip of main|ls-remote' "$R" "$I" || return 1
  grep -qE '^  workflow_run:' "$R" && grep -qE '^  schedule:' "$R" && grep -qE '^  workflow_dispatch:' "$R"
}
# --- R1c: the release guard in every deploying job, run as GitHub would ---
# job_step FILE JOB SEL -> the lines of step SEL (a number, or a name regex)
# of job JOB.
job_step() {
  awk -v job="$2" -v sel="$3" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { k = $0; gsub(/[ :]/, "", k); inj = (k == job); ins = 0; take = 0; next }
    inj && /^    steps:/ { ins = 1; n = 0; next }
    inj && ins && $0 !~ /^[[:space:]]*(#.*)?$/ && ind($0) <= 4 { ins = 0; take = 0 }
    inj && ins && /^      - / { n++; take = (sel ~ /^[0-9]+$/) ? (n == sel + 0) : ($0 ~ sel) }
    take && $0 !~ /^[[:space:]]*#/ { print }' "$1"
}
# with_of FILE JOB KEY -> the value the job passes in its `with:` block
with_of() {
  awk -v job="$2" -v key="$3" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { k = $0; gsub(/[ :]/, "", k); inj = (k == job); inw = 0; next }
    inj && /^    with:/ { inw = 1; next }
    inj && inw && /^    [^ ]/ { inw = 0 }
    inj && inw && $0 ~ "^      " key ":" { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); print v; exit }' "$1"
}
# An expression as GitHub resolves it for a Release run: own attempt $RA, the
# release commit scope picked $HEAD; inside ios-ipa.yml the inputs are what
# release.yml's `ios` job (or ci.yml's call) passes.
resolve() {
  local e=$1
  e=$(printf %s "$e" | sed -E 's/^[[:space:]]*(\$\{\{)?[[:space:]]*//; s/[[:space:]]*(\}\})?[[:space:]]*$//')
  case $e in
    github.run_attempt) printf %s "$RA";;
    needs.scope.outputs.sha) printf %s "$HEAD";;
    github.token) printf %s qa-token;;
    github.repository) printf %s o/r;;
    inputs.*) resolve "$(with_of "$CALLER" "$CALLER_JOB" "${e#inputs.}")";;
    true|false) printf %s "$e";;
    *) echo "unresolved: $e" >&2; return 1;;
  esac
}
# guardj FILE JOB SEL RA PREV STATUS HEAD -> the step's status as GitHub would
# run it (an `if:` that is false skips it: status 0). gh answers `release list`
# with $PREV and `api repos/o/r/compare/$PREV...$HEAD` with $STATUS ("!" = the
# call fails); any other gh call fails. Sets GUARD_RAN and GUARD_ERR.
guardj() {
  local f=$1 job=$2 sel=$3 d blk cond v rc envs=() line k
  RA=$4 HEAD=$7
  d=$(mktemp -d); blk=$d/step
  job_step "$f" "$job" "$sel" > "$blk"
  grep -qE '^      - name: Refuse a commit older than the last release$' "$blk" || { echo "$f/$job step $sel is not the release guard" >&2; rm -rf "$d"; return 99; }
  GUARD_RAN=0; GUARD_ERR=
  cond=$(sed -nE 's/^        if:[[:space:]]*//p' "$blk")
  if [ -n "$cond" ]; then
    v=$(resolve "$cond") || { rm -rf "$d"; return 98; }
    [ "$v" = true ] || { rm -rf "$d"; return 0; }
  fi
  while IFS= read -r line; do
    k=${line%%:*}; k=$(echo $k)
    v=$(resolve "${line#*:}") || { rm -rf "$d"; return 98; }
    envs+=("$k=$v")
  done < <(awk '/^        env:/ { e = 1; next } e && /^          [A-Z_]+:/ { print; next } e { exit }' "$blk")
  awk 'function ind(s) { match(s, /^ */); return RLENGTH }
    /^        run:[[:space:]]*\|/ { r = 1; next }
    r { if ($0 !~ /^[[:space:]]*$/ && ind($0) <= 8) exit; print substr($0, 11) }' "$blk" > "$d/step.sh"
  cat > "$d/gh" <<'GH'
#!/bin/sh
[ "$GH_TOKEN" = qa-token ] && [ "$GH_REPO" = o/r ] || exit 3
if [ "$*" = "release list --limit 1 --json tagName --jq .[0].tagName // empty" ]; then printf '%s' "${PREV:+$PREV
}"; exit 0; fi
if [ "$*" = "api repos/o/r/compare/$PREV...$HEAD_SHA --jq .status" ] && [ "$HEAD_SHA" = "$WANT_HEAD" ]; then
  [ "$STATUS" = "!" ] && exit 1
  echo "$STATUS"; exit 0
fi
echo "gh stub: unexpected: $*" >&2; exit 2
GH
  chmod +x "$d/gh"
  GUARD_RAN=1
  env -i PATH="$d:/usr/bin:/bin" PREV=$5 STATUS=$6 WANT_HEAD=$HEAD GITHUB_REPOSITORY=o/r "${envs[@]}" bash -e "$d/step.sh" >/dev/null 2>"$d/err"
  rc=$?; GUARD_ERR=$(cat "$d/err"); rm -rf "$d"
  return $rc
}
# The full table for one deploying job: a first attempt always proceeds; a
# re-run proceeds for the last release's commit or a newer one, or when no
# release exists yet; anything else (older, diverged, unreadable) is refused.
guard_table() {
  local f=$1 job=$2 sel=$3 a=aaaaaaa msg='This commit is older than the last release: nothing is deployed.' c
  for c in "1 v1 behind" "1 v1 diverged" "1 v1 identical" "2 v1 identical" "3 v1 ahead" "2 - behind"; do
    set -- $c; [ "$2" = - ] && set -- "$1" "" "$3"
    guardj "$f" "$job" "$sel" "$1" "$2" "$3" "$a" && [ "$GUARD_RAN" = 1 ] || { echo "$job: [$c] refused: $GUARD_ERR" >&2; return 1; }
  done
  for c in "2 v1 behind" "3 v1 behind" "2 v1 diverged"; do
    set -- $c
    ! guardj "$f" "$job" "$sel" "$1" "$2" "$3" "$a" || { echo "$job: [$c] proceeded" >&2; return 1; }
    [ "$GUARD_ERR" = "$msg" ] || { echo "$job: [$c] refusal said: $GUARD_ERR" >&2; return 1; }
  done
  ! guardj "$f" "$job" "$sel" 2 v1 '!' "$a" || { echo "$job: unreadable compare proceeded" >&2; return 1; }
}
r1c() {
  CALLER=$R CALLER_JOB=ios
  guard_table "$R" publish 1 || { echo "R1c publish" >&2; return 1; }
  guard_table "$R" distribute 1 || { echo "R1c distribute" >&2; return 1; }
  [ "$(with_of "$R" ios upload)" = true ] || { echo "R1c ios upload" >&2; return 1; }
  [ "$(with_of "$R" ios ref)" = '${{ needs.scope.outputs.sha }}' ] || { echo "R1c ios ref" >&2; return 1; }
  guard_table "$I" ipa 1 || { echo "R1c ipa" >&2; return 1; }
}
r1d() {
  # CI's call uploads nothing: the guard is skipped even for an older re-run
  CALLER=$C CALLER_JOB=ios-signed
  [ "$(with_of "$C" ios-signed upload)" = false ] || return 1
  guardj "$I" ipa 1 2 v1 behind aaaaaaa && [ "$GUARD_RAN" = 0 ]
}
r2() { grep -qE 'functions deploy admin-apple( |$)' "$R" && grep -qE 'functions deploy admin-apple-report( |$)' "$R"; }
r3() {
  # the create and its not-exists guard on the same name, in one statement
  local n
  n=$(grep -n 'admin_apple_url' "$R" | grep create_secret | head -1 | cut -d: -f1)
  [ -n "$n" ] && sed -n "$n,$((n + 2))p" "$R" | tr '\n' ' ' |
    grep -qiE "where not exists.*name *= *'admin_apple_url'"
}
# --- A8: run admin-apple.yml's job script ------------------------------------
job_script() {
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*- name:/ { instep = ($0 ~ /Run the job/) }
    instep && /^[[:space:]]*run:[[:space:]]*\|/ { inr = 1; base = ind($0); cut = -1; next }
    inr {
      if ($0 !~ /^[[:space:]]*$/ && ind($0) <= base) { inr = 0; instep = 0; next }
      if (cut < 0 && $0 !~ /^[[:space:]]*$/) cut = ind($0)
      print substr($0, cut + 1)
    }' "$F"
}
A8_TOKEN=qa-oidc-token-value-77
A8_EMAIL=qa.tester@mail.test
# job_run DIR TOOL_RCS -> runs the script; DIR gets out, err, calls, tool, rc
job_run() {
  local d=$1 bin=$1/bin
  mkdir -p "$bin" "$d/tmp"
  job_script > "$d/job.sh"
  [ -s "$d/job.sh" ] || { echo "no job script found" >&2; return 99; }
  printf '%s\n' $2 > "$d/tool_rcs"
  cat > "$bin/curl" <<'EOS'
#!/usr/bin/env bash
# The token service and admin-apple-report, as curl -sS --fail sees them.
auth='' body='' url=''
while [ $# -gt 0 ]; do
  case $1 in
    -H) case $2 in Authorization:*) auth=$2;; esac; shift 2;;
    -d) body=$2; shift 2;;
    -X) shift 2;;
    -*) shift;;
    *) url=$1; shift;;
  esac
done
case $url in
  "$ACTIONS_ID_TOKEN_REQUEST_URL"*)
    # every fetch issues a new token; fetch numbers listed in A8_TOKFAIL fail
    n=$(( $(cat "$A8_DIR/ntok" 2>/dev/null || echo 0) + 1 )); echo $n > "$A8_DIR/ntok"
    printf 'token %s\n' "$n" >> "$A8_DIR/calls"
    [ "$auth" = "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" ] || exit 22
    case " $A8_TOKFAIL " in *" $n "*) exit 22;; esac
    echo "$A8_TOKEN-$n" > "$A8_DIR/latest"
    printf '{"count":1,"value":"%s"}' "$A8_TOKEN-$n";;
  "$SUPABASE_URL/functions/v1/admin-apple-report")
    # A body that is not JSON is what the old bug sent: refuse it like the function does.
    action=$(printf '%s' "$body" | jq -er .action) || { echo bad >> "$A8_DIR/calls"; exit 22; }
    tok=${auth#Authorization: Bearer }
    printf 'report %s %s\n' "$tok" "$body" >> "$A8_DIR/calls"
    # fresh: the token issued last, never used before, already masked on stdout
    [ "$tok" = "$(cat "$A8_DIR/latest" 2>/dev/null)" ] || { echo "stale $tok" >> "$A8_DIR/calls"; exit 22; }
    grep -qxF "$tok" "$A8_DIR/used" && { echo "reused $tok" >> "$A8_DIR/calls"; exit 22; }
    echo "$tok" >> "$A8_DIR/used"
    grep -qxF "::add-mask::$tok" "$A8_DIR/out" || { echo "unmasked $tok" >> "$A8_DIR/calls"; exit 22; }
    case $action in
      claim) printf '{"kind":"%s","email":"%s"}' "$A8_KIND" "$A8_EMAIL";;
      *) printf '{"ok":true}';;
    esac;;
  *) echo "unexpected url" >> "$A8_DIR/calls"; exit 6;;
esac
EOS
  cat > "$bin/python3" <<'EOS'
#!/usr/bin/env bash
printf 'tool TESTER_EMAIL=%s argv=%s\n' "${TESTER_EMAIL-<unset>}" "$*" >> "$A8_DIR/tool"
rc=$(head -1 "$A8_DIR/tool_rcs"); sed -i 1d "$A8_DIR/tool_rcs"; exit "${rc:-0}"
EOS
  printf '#!/bin/sh\necho "sleep $1" >> "$A8_DIR/calls"\n' > "$bin/sleep"
  chmod +x "$bin/curl" "$bin/python3" "$bin/sleep"
  : > "$d/calls"; : > "$d/tool"; : > "$d/used"; : > "$d/out"
  (cd "$d" && env -i PATH="$bin:/usr/bin:/bin" HOME="$d" A8_DIR="$d" A8_TOKEN=$A8_TOKEN A8_EMAIL=$A8_EMAIL \
    A8_KIND=${A8_KIND:-add} A8_TOKFAIL="${A8_TOKFAIL-}" JOB_ID=0b1e2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d SUPABASE_URL=https://sb.example.test \
    KEY=pemdata KEY_ID=K1 ISSUER_ID=I1 TF_GROUPS=bacanaks RUNNER_TEMP="$d/tmp" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-tok ACTIONS_ID_TOKEN_REQUEST_URL='https://tok.example.test/x?api=1' \
    bash "$d/job.sh" >> "$d/out" 2> "$d/err"); echo $? > "$d/rc"
}
finish_of() { grep -o '"action":"finish"[^}]*' "$1/calls"; }
# every report call used a fresh, masked token; no body failed to parse
fresh() {
  ! grep -qE '^(bad|stale|reused|unmasked|unexpected)' "$1/calls" &&
    [ "$(grep -c '^report ' "$1/calls")" = "$2" ] &&
    [ "$(grep -c '^token ' "$1/calls")" = "${3:-$2}" ]
}
a8() {
  local d o t=$A8_TOKEN
  command -v jq >/dev/null || { echo "jq missing" >&2; return 1; }
  d=$(mktemp -d); job_run "$d" "0"
  [ "$(cat "$d/rc")" = 0 ] || { echo "A8: rc $(cat "$d/rc"): $(cat "$d/err")" >&2; return 1; }
  # claim and finish, each with its own fresh token
  fresh "$d" 2 || { echo "A8 calls: $(cat "$d/calls")" >&2; return 1; }
  grep -q "^report $t-1 .*\"action\":\"claim\"" "$d/calls" && grep -q "^report $t-2 .*\"action\":\"finish\"" "$d/calls" || return 1
  # stdout: exactly the masks: claim token, the email straight after the claim, finish token
  o=$(cat "$d/out")
  [ "$o" = "::add-mask::$t-1"$'\n'"::add-mask::$A8_EMAIL"$'\n'"::add-mask::$t-2" ] || { echo "A8 stdout: $o" >&2; return 1; }
  ! grep -qF "$A8_EMAIL" "$d/err" && ! grep -qF "$t" "$d/err" || return 1
  # the claim parsed: the tool got the email, from env only
  [ "$(cat "$d/tool")" = "tool TESTER_EMAIL=$A8_EMAIL argv=tool/asc_signing.py tester add bacanaks" ] ||
    { echo "A8 tool: $(cat "$d/tool")" >&2; return 1; }
  [ "$(finish_of "$d")" = '"action":"finish","job_id":"0b1e2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ok":true,"reason":"ok"' ] || return 1
  rm -rf "$d"
}
a10() {
  local d
  # claim token fails: the job stops, nothing reported, the tool never runs
  d=$(mktemp -d); A8_TOKFAIL=1 job_run "$d" "0"
  [ "$(cat "$d/rc")" != 0 ] && fresh "$d" 0 1 && [ ! -s "$d/tool" ] || { echo "A10 claim: $(cat "$d/rc") $(cat "$d/calls")" >&2; return 1; }
  rm -rf "$d"
}
a11() {
  local d
  # the first progress token fails: ignored, the retries and finish go on
  d=$(mktemp -d); A8_TOKFAIL=2 job_run "$d" "75 75 75"
  [ "$(cat "$d/rc")" = 75 ] && [ "$(wc -l < "$d/tool")" = 3 ] || { echo "A10 progress: $(cat "$d/rc")" >&2; return 1; }
  finish_of "$d" | grep -q '"ok":false,"reason":"timeout"' || return 1
  # a progress sent without a token is harmless; one with an old token is not
  ! grep -qE '^(bad|reused|unmasked|stale .)' "$d/calls" || return 1
  [ "$(grep -c '"action":"progress"' "$d/calls")" -ge 1 ] || return 1
  rm -rf "$d"
}
a12() {
  local d
  # the finish token fails: swallowed; the job keeps the tool's exit code and
  # nothing reports a reason other than the true one
  local rc why
  for rc in 0 1; do
    [ "$rc" = 0 ] && why='"ok":true,"reason":"ok"' || why='"ok":false,"reason":"rejected"'
    d=$(mktemp -d); A8_TOKFAIL=2 job_run "$d" "$rc"
    [ "$(cat "$d/rc")" = "$rc" ] && ! grep -qE '^(bad|reused|unmasked|stale .)' "$d/calls" &&
      ! finish_of "$d" | grep -vqF "$why" ||
      { echo "A12 finish, tool rc $rc: job rc $(cat "$d/rc"); $(grep -E '^(token|report)' "$d/calls" | tr '\n' ' ')" >&2; return 1; }
    rm -rf "$d"
  done
}
a9() {
  # exit codes: 1 -> finish false rejected; 75 x3 -> progress 2, finish false timeout
  local d
  d=$(mktemp -d); job_run "$d" "1"
  [ "$(cat "$d/rc")" = 1 ] && finish_of "$d" | grep -q '"ok":false,"reason":"rejected"' || return 1
  [ "$(wc -l < "$d/tool")" = 1 ] || return 1
  rm -rf "$d"; d=$(mktemp -d); job_run "$d" "75 75 75"
  [ "$(cat "$d/rc")" = 75 ] && finish_of "$d" | grep -q '"ok":false,"reason":"timeout"' || return 1
  [ "$(wc -l < "$d/tool")" = 3 ] && grep -q '"action":"progress".*"attempt":2' "$d/calls" || return 1
  [ "$(grep -c '"action":"finish"' "$d/calls")" = 1 ] || return 1
  fresh "$d" "$(grep -c '^report ' "$d/calls")" || return 1   # progress too: a fresh token each
  rm -rf "$d"; d=$(mktemp -d); A8_KIND=remove job_run "$d" "0"
  [ "$(cat "$d/rc")" = 0 ] && grep -q 'argv=tool/asc_signing.py tester remove bacanaks' "$d/tool" || return 1
  rm -rf "$d"
}
b1() { grep -qE '^\s+environment:\s*apple-signing\s*$' "$B" ||
  { grep -qE '^\s+environment:\s*$' "$B" && grep -qE '^\s+name:\s*apple-signing\s*$' "$B"; }; }

check "A1 admin-apple: workflow_dispatch is the only trigger" a1
check "A2 admin-apple: job_id is the only input" a2
check "A3 admin-apple: job_id regex-checked, read only through env" a3
check "A4 admin-apple: permissions exactly id-token: write, contents: read" a4
check "A5 admin-apple: ::add-mask:: of the email before any other output" a5
check "A6 admin-apple: email only via TESTER_EMAIL env, never argv" a6
check "A7 admin-apple: no step summary, artifacts or xtrace" a7
check "A8 admin-apple: the job script runs: a fresh masked token per report, claim parses, email mask next, env-only" a8
check "A9 admin-apple: tool exit 1 -> rejected, 75 x3 -> timeout, remove passes through" a9
check "A10 admin-apple: claim token fetch fails: the job stops, nothing reported, tool never runs" a10
check "A11 admin-apple: progress token fetch fails: ignored, retries and finish go on" a11
check "A12 admin-apple: finish token fetch fails: swallowed, tool's exit code kept, no false reason" a12
check "R1 release: workflow_run on CI, daily schedule and dispatch, no tip-of-main check left" r1
check "R1c release publish/distribute + ios-ipa ipa (upload true): first step is the release guard; a re-run never deploys a commit older than the last release" r1c
check "R1d ios-ipa: CI's call (upload false) skips the release guard" r1d
check "R2 release: deploys admin-apple and admin-apple-report" r2
check "R3 release: vault admin_apple_url created where not exists" r3
check "B1 bootstrap: job behind environment apple-signing" b1

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
