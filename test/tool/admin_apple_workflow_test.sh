#!/usr/bin/env bash
# Static checks on the admin Apple path's workflows (the repo is PUBLIC, so
# what a workflow may print, take as input or be granted is checked as text):
#   admin-apple.yml  workflow_dispatch only; one input job_id, uuid-checked and
#                    passed through env; permissions exactly id-token: write
#                    and contents: read;
#                    ::add-mask:: of the email before any other output; the
#                    email never in argv; no step summary, artifacts or set -x.
#   release.yml      a first attempt always proceeds; a re-run (run_attempt
#                    >= 2) is refused unless head_sha is the live main tip
#                    (an empty tip refuses); the step's script is RUN here
#                    against a stubbed git;
#                    deploys admin-apple and admin-apple-report; creates the
#                    vault secret admin_apple_url in `where not exists` form.
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

r1() {
  grep -q 'workflow_run.head_sha' "$R" && grep -qE 'ls-remote|origin/main' "$R" || return 1
  awk '
    /^[[:space:]]*- name:/ { if (hit && ex) found = 1; hit = 0; ex = 0 }
    /workflow_run\.head_sha/ { hit = 1 }
    /ls-remote|origin\/main/ { if (hit) live = 1 }
    /exit 1/ { ex = 1 }
    END { if (hit && ex) found = 1; exit !(found && live) }' "$R"
}
# The tip-check step's script, run with a stubbed `git ls-remote` printing $TIP.
tip_script() {
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*- name:/ { instep = ($0 ~ /tip of main/) }
    instep && /^[[:space:]]*run:[[:space:]]*\|/ { inr = 1; base = ind($0); next }
    inr { if ($0 !~ /^[[:space:]]*$/ && ind($0) <= base) { inr = 0; instep = 0 } else print }' "$R"
}
tip_run() {  # tip_run ATTEMPT TIP HEAD -> the step's exit status
  local d rc
  d=$(mktemp -d)
  printf '#!/bin/sh\n[ -n "$TIP" ] && printf "%%s\\trefs/heads/main\\n" "$TIP"\nexit 0\n' > "$d/git"
  chmod +x "$d/git"
  tip_script > "$d/step.sh"
  [ -s "$d/step.sh" ] || { echo "no tip-check script found" >&2; return 99; }
  PATH="$d:$PATH" TIP=$2 RUN_ATTEMPT=$1 HEAD_SHA=$3 GITHUB_REPOSITORY=o/r bash -e "$d/step.sh" >/dev/null 2>&1
  rc=$?
  rm -f "$d/git" "$d/step.sh"; rmdir "$d"
  return $rc
}
r1b() {
  grep -qE 'RUN_ATTEMPT:[[:space:]]*\$\{\{[[:space:]]*github\.run_attempt[[:space:]]*\}\}' "$R" || return 1
  local a=aaaaaaa b=bbbbbbb
  tip_run 1 "$b" "$a" || return 1          # a first attempt always proceeds
  tip_run 1 "" "$a" || return 1            # ... even when the tip cannot be read
  tip_run 2 "$a" "$a" || return 1          # a re-run of the live tip proceeds
  ! tip_run 2 "$b" "$a" || return 1        # a re-run of an older commit is refused
  ! tip_run 3 "$b" "$a" || return 1
  ! tip_run 2 "" "$a" || return 1          # a re-run with no readable tip is refused
  ! tip_run 2 "" ""                        # ... even if head_sha came through empty
}
r2() { grep -qE 'functions deploy admin-apple( |$)' "$R" && grep -qE 'functions deploy admin-apple-report( |$)' "$R"; }
r3() {
  # the create and its not-exists guard on the same name, in one statement
  local n
  n=$(grep -n 'admin_apple_url' "$R" | grep create_secret | head -1 | cut -d: -f1)
  [ -n "$n" ] && sed -n "$n,$((n + 2))p" "$R" | tr '\n' ' ' |
    grep -qiE "where not exists.*name *= *'admin_apple_url'"
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
check "R1 release: refuses a head_sha that is not the live main tip" r1
check "R1b release: first attempt proceeds; a re-run only for the live tip" r1b
check "R2 release: deploys admin-apple and admin-apple-report" r2
check "R3 release: vault admin_apple_url created where not exists" r3
check "B1 bootstrap: job behind environment apple-signing" b1

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
