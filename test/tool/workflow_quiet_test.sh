#!/usr/bin/env bash
# Quiet release wiring in .github/workflows/release.yml, lifted out of the file and run as written
# under `bash -e` and `bash -eo pipefail`, with stand-ins for gh and tool/release_kind.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
wf=.github/workflows/release.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
SHELLS=("bash -e" "bash -eo pipefail")
# step_run <step name> <out>: the step's `run: |` block, de-indented.
step_run() {
  awk -v n="- name: $1" '
    index($0, n) && substr($0, index($0, n) + length(n)) == "" { found = 1; next }
    found && !inrun && /^ *- / { exit }
    found && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
    inrun {
      if ($0 ~ /^ *$/) { print ""; next }
      match($0, /^ */); if (RLENGTH <= ind) exit
      if (!body) body = RLENGTH
      print substr($0, body + 1)
    }' "$wf" > "$2"
  [ -s "$2" ] || fail "step '$1' not found in $wf"
}
mkdir -p "$tmp/bin" "$tmp/work/tool"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }
# ---- static: the wiring around the steps ----
# CASES A (fill in): grep -qF / grep -qxF checks on $wf, each with a fail message:
#  1 a line containing: inAppUpdatePriority: ${{ needs.scope.outputs.quiet == 'true' && '0' || '2' }}
#  2 a line containing: QUIET: ${{ needs.scope.outputs.quiet }}
#  3 a line containing: QUIET_SUFFIX: ${{ needs.scope.outputs.quiet == 'true' && ' (quiet)' || '' }}
#  4 a line containing: quiet: ${{ steps.kind.outputs.quiet }}
grep -qF 'inAppUpdatePriority: ${{ needs.scope.outputs.quiet == '\''true'\'' && '\''0'\'' || '\''2'\'' }}' "$wf" || fail "missing inAppUpdatePriority line"
grep -qF 'QUIET: ${{ needs.scope.outputs.quiet }}' "$wf" || fail "missing QUIET line"
grep -qF "QUIET_SUFFIX: \${{ needs.scope.outputs.quiet == 'true' && ' (quiet)' || '' }}" "$wf" || fail "missing QUIET_SUFFIX line"
grep -qF 'quiet: ${{ steps.kind.outputs.quiet }}' "$wf" || fail "missing quiet line"
# ---- step "Mark a quiet release" ----
step_run "Mark a quiet release" "$tmp/kind.sh"
# release_kind.sh stand-in: logs that it was called, prints quiet=$KIND_OUT.
printf '#!/usr/bin/env bash\necho "called $*" >> "$KIND_LOG"\necho "quiet=$KIND_OUT"\n' > "$tmp/work/tool/release_kind.sh"; chmod +x "$tmp/work/tool/release_kind.sh"
stub gh 'if [ "$*" = "release list --limit 1 --json tagName --jq .[0].tagName // empty" ]; then echo v1; exit 0; fi
echo "gh stub: unexpected: $*" >&2; exit 2'
kind() { # <shell> <SHIP> <EVENT> <REASON> <KIND_OUT> -> sets rc; output in $tmp/gh_out, calls in $tmp/kind_log
  : > "$tmp/gh_out"; : > "$tmp/kind_log"; set +e
  (cd "$tmp/work" && PATH="$tmp/bin:$PATH" GH_TOKEN=x SHA=abc123 SHIP=$2 EVENT=$3 REASON=$4 KIND_OUT=$5 KIND_LOG="$tmp/kind_log" \
    GITHUB_OUTPUT="$tmp/gh_out" $1 "$tmp/kind.sh") > "$tmp/out" 2>&1; rc=$?; set -e
}
# ---- CASES B (fill in), inside: for sh in "${SHELLS[@]}"; do ... done ----
#  each case: kind ...; check rc=0, `cat "$tmp/gh_out"` equals exactly the wanted single line, and whether kind_log is empty (not called) or equals "called v1 abc123":
#  schedule, SHIP=true, KIND_OUT=true -> quiet=true, called v1 abc123
#  schedule, SHIP=true, KIND_OUT=false -> quiet=false, called
#  workflow_run, SHIP=true, KIND_OUT=true -> quiet=true, called
#  schedule, SHIP=false, KIND_OUT=true -> quiet=false, NOT called
#  workflow_dispatch, REASON=urgent, SHIP=true, KIND_OUT=true -> quiet=false, NOT called
#  workflow_dispatch, REASON=daily, SHIP=true, KIND_OUT=true -> quiet=true, called
for sh in "${SHELLS[@]}"; do
  # 1 schedule, SHIP=true, KIND_OUT=true
  kind "$sh" true schedule "" true
  [ $rc -eq 0 ] || fail "rc not 0 for schedule true true"
  [ "$(cat "$tmp/gh_out")" = "quiet=true" ] || fail "unexpected output for schedule true true"
  [ "$(cat "$tmp/kind_log")" = "called v1 abc123" ] || fail "release_kind.sh not called for schedule true true"

  # 2 schedule, SHIP=true, KIND_OUT=false
  kind "$sh" true schedule "" false
  [ $rc -eq 0 ] || fail "rc not 0 for schedule true false"
  [ "$(cat "$tmp/gh_out")" = "quiet=false" ] || fail "unexpected output for schedule true false"
  [ "$(cat "$tmp/kind_log")" = "called v1 abc123" ] || fail "release_kind.sh not called for schedule true false"

  # 3 workflow_run, SHIP=true, KIND_OUT=true
  kind "$sh" true workflow_run "" true
  [ $rc -eq 0 ] || fail "rc not 0 for workflow_run true true"
  [ "$(cat "$tmp/gh_out")" = "quiet=true" ] || fail "unexpected output for workflow_run true true"
  [ "$(cat "$tmp/kind_log")" = "called v1 abc123" ] || fail "release_kind.sh not called for workflow_run true true"

  # 4 schedule, SHIP=false, KIND_OUT=true
  kind "$sh" false schedule "" true
  [ $rc -eq 0 ] || fail "rc not 0 for schedule false true"
  [ "$(cat "$tmp/gh_out")" = "quiet=false" ] || fail "unexpected output for schedule false true"
  [ -s "$tmp/kind_log" ] && fail "release_kind.sh should not be called for schedule false true"

  # 5 workflow_dispatch, REASON=urgent, SHIP=true, KIND_OUT=true
  kind "$sh" true workflow_dispatch urgent true
  [ $rc -eq 0 ] || fail "rc not 0 for workflow_dispatch urgent true"
  [ "$(cat "$tmp/gh_out")" = "quiet=false" ] || fail "unexpected output for workflow_dispatch urgent true"
  [ -s "$tmp/kind_log" ] && fail "release_kind.sh should not be called for workflow_dispatch urgent true"

  # 6 workflow_dispatch, REASON=daily, SHIP=true, KIND_OUT=true
  kind "$sh" true workflow_dispatch daily true
  [ $rc -eq 0 ] || fail "rc not 0 for workflow_dispatch daily true"
  [ "$(cat "$tmp/gh_out")" = "quiet=true" ] || fail "unexpected output for workflow_dispatch daily true"
  [ "$(cat "$tmp/kind_log")" = "called v1 abc123" ] || fail "release_kind.sh not called for workflow_dispatch daily true"
done
# ---- step "Store the What's new note for this build" ----
step_run "Store the What's new note for this build" "$tmp/note.sh"
# make a real git repo
mkdir -p "$tmp/repo" && (
  cd "$tmp/repo" &&
  git init -q -b main . &&
  git config user.email qa@sis.test &&
  git config user.name QA &&
  git config commit.gpgsign false &&
  echo 1 > a && git add a && git commit -q -m first &&
  echo 2 > a && git add a && git commit -q -m second
)
sha=$(git -C "$tmp/repo" rev-parse HEAD)
# stubs
stub gh 'if [ "$1 $2" = "release list" ]; then exit 0; fi
echo "gh stub: unexpected: $*" >&2; exit 2'
stub supabase 'echo "supabase $*" >> "$SB_LOG"'
# function note
note() { # <shell> <QUIET>
  : > "$tmp/gh_out"; : > "$tmp/sb_log"
  set +e
  (cd "$tmp/repo" && PATH="$tmp/bin:$PATH" GH_TOKEN=x BUILD=177 VERSION=26.10.5 SHA=$sha GITHUB_REPOSITORY=o/r SUPABASE_ACCESS_TOKEN=x QUIET=$2 SB_LOG="$tmp/sb_log" GITHUB_OUTPUT="$tmp/gh_out" $1 "$tmp/note.sh") > "$tmp/out" 2>&1
  rc=$?
  set -e
}
for sh in "${SHELLS[@]}"; do
  # a) quiet=true
  note "$sh" true
  [ $rc -eq 0 ] || fail "rc not 0 for quiet=true $sh"
  [ ! -s "$tmp/gh_out" ] || fail "gh_out not empty for quiet=true $sh"
  [ ! -s "$tmp/sb_log" ] || fail "sb_log not empty for quiet=true $sh"
  # b) quiet=false
  note "$sh" false
  [ $rc -eq 0 ] || fail "rc not 0 for quiet=false $sh"
  out=$(cat "$tmp/gh_out")
  [ -n "$out" ] || fail "gh_out empty for quiet=false $sh"
  case "$out" in
    b64=*) ;; *) fail "gh_out does not start with b64= for quiet=false $sh";;
  esac
  b64part=${out#b64=}
  decoded=$(echo "$b64part" | base64 -d)
  case "$decoded" in
    "Version 26.10.5 (177)"*) ;; *) fail "decoded note does not start with Version 26.10.5 (177) for quiet=false $sh";;
  esac
  sb=$(cat "$tmp/sb_log")
  case "$sb" in
    *insert\ into\ public.release_notes*) ;; *) fail "sb_log does not contain insert into public.release_notes for quiet=false $sh";;
  esac
  # c) quiet=""
  note "$sh" ""
  [ $rc -eq 0 ] || fail "rc not 0 for quiet=\"\" $sh"
  out=$(cat "$tmp/gh_out")
  case "$out" in
    b64=*) ;; *) fail "gh_out does not start with b64= for quiet=\"\" $sh";;
  esac
  b64part=${out#b64=}
  decoded=$(echo "$b64part" | base64 -d)
  case "$decoded" in
    "Version 26.10.5 (177)"*) ;; *) fail "decoded note does not start with Version 26.10.5 (177) for quiet=\"\" $sh";;
  esac
  sb=$(cat "$tmp/sb_log")
  case "$sb" in
    *insert\ into\ public.release_notes*) ;; *) fail "sb_log does not contain insert into public.release_notes for quiet=\"\" $sh";;
  esac
done

# ---- step "Tag and publish release notes" ----
step_run "Tag and publish release notes" "$tmp/tag_raw.sh"
sed 's/\${{ needs\.scope\.outputs\.name }}/26.10.5/g; s/\${{ needs\.scope\.outputs\.code }}/177/g' "$tmp/tag_raw.sh" > "$tmp/tag.sh"
! grep -q '\${{' "$tmp/tag.sh" || fail "the tag step reads an unexpected expression"
stub gh 'for a in "$@"; do echo "arg:$a" >> "$CALLS"; done; exit 0'
# function tag
tag() { # <shell> <suffix or "unset">
  : > "$tmp/calls"
  set +e
  if [ "$2" = unset ]; then
    (PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" GH_TOKEN=x SHA=abc $1 "$tmp/tag.sh") > "$tmp/out" 2>&1
  else
    (PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" GH_TOKEN=x SHA=abc QUIET_SUFFIX="$2" $1 "$tmp/tag.sh") > "$tmp/out" 2>&1
  fi
  rc=$?
  set -e
}
for sh in "${SHELLS[@]}"; do
  tag "$sh" " (quiet)"
  [ $rc -eq 0 ] || fail "rc not 0 for tag quiet $sh"
  grep -qxF 'arg:SIS 26.10.5 (quiet)' "$tmp/calls" || fail "expected arg:SIS 26.10.5 (quiet) in calls for $sh"
  tag "$sh" ""
  [ $rc -eq 0 ] || fail "rc not 0 for tag normal $sh"
  grep -qxF 'arg:SIS 26.10.5' "$tmp/calls" || fail "expected arg:SIS 26.10.5 in calls for $sh"
  grep -q '(quiet)' "$tmp/calls" && fail "unexpected (quiet) in calls for $sh"
  tag "$sh" unset
  [ $rc -eq 0 ] || fail "rc not 0 for tag unset $sh"
  grep -qxF 'arg:SIS 26.10.5' "$tmp/calls" || fail "expected arg:SIS 26.10.5 in calls for unset $sh"
  grep -q '(quiet)' "$tmp/calls" && fail "unexpected (quiet) in calls for unset $sh"
done

echo "workflow quiet: OK"

