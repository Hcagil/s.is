#!/usr/bin/env bash
# Every release.yml step named "Mask the private words" (any job), run as
# written under GitHub's default `bash -e`, with PRIVATE_WORDS =
#   empty (secret not set), one word, several words with a blank line between:
# it exits 0 and prints `::add-mask::<w>` exactly once per non-empty line, and
# nothing else (a word never appears in any other form).
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
f=.github/workflows/release.yml

# Writes each such step's `run: |` block, de-indented, to $tmp/step.<n>.sh.
awk -v dir="$tmp" '
  /^ *- name: Mask the private words$/ { found = 1; n++; next }
  found && !inrun && /^ *- / { found = 0 }
  found && !inrun && /^ *run: \|/ { inrun = 1; found = 0; match($0, /^ */); ind = RLENGTH; body = 0; next }
  inrun {
    if ($0 ~ /^ *$/) { print "" > (dir "/step." n ".sh"); next }
    match($0, /^ */); if (RLENGTH <= ind) { inrun = 0; next }
    if (!body) body = RLENGTH
    print substr($0, body + 1) > (dir "/step." n ".sh")
  }' "$f"
steps=("$tmp"/step.*.sh)
[ -e "${steps[0]}" ] || fail "no 'Mask the private words' step with a run block in $f"

check() { # <script> <label> <PRIVATE_WORDS> <expected stdout>
  local rc=0
  PRIVATE_WORDS=$3 bash -e "$1" > "$tmp/out" 2>&1 || rc=$?
  [ $rc = 0 ] || fail "$2: exit $rc, want 0"
  [ "$(cat "$tmp/out")" = "$4" ] || fail "$2: output [$(cat "$tmp/out")], want [$4]"
}
for s in "${steps[@]}"; do
  check "$s" "empty secret" "" ""
  check "$s" "one word" "alpha" "::add-mask::alpha"
  check "$s" "several words, blank line between" $'alpha\n\nbeta gamma\ndelta' \
    $'::add-mask::alpha\n::add-mask::beta gamma\n::add-mask::delta'
done
echo "mask_words_test: ${#steps[@]} step(s) ok"
