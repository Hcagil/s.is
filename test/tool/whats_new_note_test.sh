#!/usr/bin/env bash
# The release step "Store the What's new note for this build", run as written
# in .github/workflows/release.yml (the script is lifted out of the file, not
# copied), over a real git history and stand-ins for gh and supabase:
#
#   - PR numbers come from the (#N) at the end of commit subjects between the
#     previous release tag and $SHA; commits before the tag never count;
#   - only non-empty `For users:` lines are kept (CRLF bodies included), in
#     merge order, joined by newlines;
#   - the text reaches SQL base64-encoded (PR bodies are untrusted), as one
#     insert for $BUILD with `on conflict (build) do nothing`;
#   - no such line -> no insert at all, and the step still succeeds;
#   - no previous release -> only the released commit itself;
#   - only PRs whose author is OWNER, MEMBER or COLLABORATOR count (anyone else
#     could edit a merged PR's body and have it sent to every member as SIS);
#   - the joined note is cut to 4000 characters, the release_notes check;
#   - a failing `gh pr view` fails the run block, and the step is
#     continue-on-error so that failure never blocks the release.
#
# A `run:` block with no `shell:` runs as `bash -e {0}` on GitHub Actions --
# errexit but NOT pipefail -- so the step runs that way here; any pipefail
# comes from the step itself. The gh stand-in honours --json and --jq with
# real jq, as gh does.
set -euo pipefail
command -v jq >/dev/null || { echo "FAIL: jq is required (gh --jq stand-in)"; exit 1; }
cd "$(dirname "$0")/../.."
workflow=.github/workflows/release.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The step's run block, de-indented.
awk '
  /- name: Store the What.s new note for this build/ { found = 1; next }
  found && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
  inrun {
    if ($0 ~ /^ *$/) { print ""; next }
    match($0, /^ */)
    if (RLENGTH <= ind) exit
    if (!body) { body = RLENGTH }
    print substr($0, body + 1)
  }
' "$workflow" > "$tmp/step.sh"
grep -q 'supabase db query' "$tmp/step.sh" || { echo "FAIL: step not found in $workflow"; exit 1; }
# The step's own keys, between its name and its run: line.
awk '/- name: Store the What.s new note for this build/ { f = 1; next } f && /^ *run: \|/ { exit } f' \
  "$workflow" | grep -q '^ *continue-on-error: true *$' \
  || { echo "FAIL: the note step must be continue-on-error: a gh/db hiccup must not block the release"; exit 1; }

# Stand-ins. gh answers from files; supabase records its arguments.
# `gh pr view N --json f1,f2 --jq F` builds an object with only the requested
# fields (body from prs/N, authorAssociation from prs/N.assoc, default NONE),
# then applies F with jq -r, as gh does. prs/N.fail makes the call fail.
mkdir -p "$tmp/bin" "$tmp/prs"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "release list") printf '%s\n' "${STUB_PREV_TAG:-}" ;;
  "pr view")
    pr=$3; shift 3; fields=; filter=.
    while [ $# -gt 0 ]; do
      case "$1" in --json) fields=$2; shift 2 ;; --jq) filter=$2; shift 2 ;; *) shift ;; esac
    done
    [ ! -e "$STUB_PRS/$pr.fail" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    [ -n "$fields" ] || { echo "gh stub: pr view without --json" >&2; exit 1; }
    assoc=NONE; [ ! -e "$STUB_PRS/$pr.assoc" ] || assoc=$(cat "$STUB_PRS/$pr.assoc")
    jq -n --rawfile body "$STUB_PRS/$pr" --arg a "$assoc" --arg f "$fields" \
      '{body: $body, authorAssociation: $a} | with_entries(select(.key | IN($f | split(",")[])))' \
      | jq -r "$filter" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$tmp/bin/supabase" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/supabase"

# A history: #9 ships in the previous release; #10-#12 and a direct commit after.
repo=$tmp/repo
git init -q "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
g commit -q --allow-empty -m 'feat: old change (#9)'
g tag v0.26.0+178
g commit -q --allow-empty -m 'feat: sound settings (#10)'
g commit -q --allow-empty -m 'chore: tidy (#11)'
g commit -q --allow-empty -m 'docs: no pull request here'
g commit -q --allow-empty -m 'fix: faster start (#12)'
head_sha=$(g rev-parse HEAD)

printf 'For users: Old news.\n' > "$tmp/prs/9"
printf '## Summary\r\nSound.\r\n\r\nFor users: You can pick a sound.\r\n' > "$tmp/prs/10"
printf 'Refactor.\n\nFor users:\n' > "$tmp/prs/11"
printf 'Speed.\nFor users: It'"'"'s faster; "quoted" $(rm -rf /) `x` too.\n' > "$tmp/prs/12"
for pr in 9 10 11 12; do echo OWNER > "$tmp/prs/$pr.assoc"; done

# run_step <prev tag> -> sets $out, $calls; step exit status is returned
run_step() {
  : > "$tmp/calls"
  (cd "$repo" && PATH="$tmp/bin:$PATH" STUB_PREV_TAG="$1" STUB_PRS="$tmp/prs" \
    STUB_CALLS="$tmp/calls" SHA="$head_sha" BUILD=179 GH_TOKEN=x \
    bash -e "$tmp/step.sh") > "$tmp/out" 2>&1
}
fail() { echo "FAIL: $1"; echo "--- step output"; cat "$tmp/out"; echo "--- supabase calls"; cat "$tmp/calls"; exit 1; }
note_of() { # the text the insert would store
  sed -n "s/.*decode('\([A-Za-z0-9+/=]*\)', 'base64').*/\1/p" "$tmp/calls" | base64 -d
}

# 1 lines since the previous release, in merge order
run_step v0.26.0+178 || fail "step exited non-zero"
[ "$(wc -l < "$tmp/calls")" -eq 1 ] || fail "expected exactly one insert"
grep -q -- '--linked' "$tmp/calls" || fail "insert not sent to the linked project"
grep -q 'insert into public.release_notes(build, note) values (179, ' "$tmp/calls" \
  || fail "insert does not target build 179"
grep -q 'on conflict (build) do nothing' "$tmp/calls" || fail "a re-run would overwrite a dashboard edit"
expected=$(printf '%s\n%s' 'You can pick a sound.' 'It'"'"'s faster; "quoted" $(rm -rf /) `x` too.')
[ "$(note_of)" = "$expected" ] || fail "note was: [$(note_of)]"
if grep -q 'rm -rf\|quoted\|faster' "$tmp/calls"; then fail "PR text reached SQL unencoded"; fi
if note_of | grep -q $'\r'; then fail "a carriage return survived"; fi
if note_of | grep -q 'Old news'; then fail "a PR from the previous release was included"; fi

# 2 nothing user-facing -> no insert, still success
printf 'For users:   \n' > "$tmp/prs/10"
printf 'Nothing to see.\n' > "$tmp/prs/12"
run_step v0.26.0+178 || fail "step failed when there was nothing to store"
[ ! -s "$tmp/calls" ] || fail "an insert was made with no For users line"

# 3 no previous release -> only the released commit
printf 'For users: Only this one.\n' > "$tmp/prs/12"
printf 'For users: Not this one.\n' > "$tmp/prs/10"
run_step '' || fail "step exited non-zero without a previous release"
[ "$(note_of)" = 'Only this one.' ] || fail "first release note was: [$(note_of)]"

# 4 author association: only OWNER / MEMBER / COLLABORATOR PRs count
printf 'For users: From the owner.\n' > "$tmp/prs/10"
printf 'For users: From a collaborator.\n' > "$tmp/prs/11"
printf 'For users: From a stranger.\n' > "$tmp/prs/12"
echo COLLABORATOR > "$tmp/prs/11.assoc"
echo NONE > "$tmp/prs/12.assoc"
run_step v0.26.0+178 || fail "step exited non-zero"
[ "$(note_of)" = $'From the owner.\nFrom a collaborator.' ] || fail "association filter: note was [$(note_of)]"
echo CONTRIBUTOR > "$tmp/prs/12.assoc"
run_step v0.26.0+178 || fail "step exited non-zero"
if note_of | grep -q stranger; then fail "a CONTRIBUTOR's For users line was stored"; fi
echo MEMBER > "$tmp/prs/12.assoc"
run_step v0.26.0+178 || fail "step exited non-zero"
[ "$(note_of)" = $'From the owner.\nFrom a collaborator.\nFrom a stranger.' ] || fail "MEMBER dropped: [$(note_of)]"
for pr in 10 11 12; do echo NONE > "$tmp/prs/$pr.assoc"; done
run_step v0.26.0+178 || fail "step exited non-zero"
[ ! -s "$tmp/calls" ] || fail "an insert was made from non-collaborator PRs only"
for pr in 10 11 12; do echo OWNER > "$tmp/prs/$pr.assoc"; done

# 5 a joined note over 4000 characters is stored cut to exactly 4000
long=$(printf 'x%.0s' $(seq 3000))
printf 'For users: %s\n' "$long" > "$tmp/prs/10"
printf 'For users: %s\n' "$long" > "$tmp/prs/12"
printf 'Nothing.\n' > "$tmp/prs/11"
run_step v0.26.0+178 || fail "step exited non-zero on a long note"
stored=$(note_of; printf .); stored=${stored%.}
[ "${#stored}" -eq 4000 ] || fail "long note stored as ${#stored} characters, want 4000"
[ "$stored" = "$(printf '%s\n%s' "$long" "$long" | head -c 4000)" ] || fail "long note is not the first 4000 characters"

# 6 a failing gh pr view fails the run block, and stores nothing
printf 'For users: Fine.\n' > "$tmp/prs/10"
printf 'For users: Also fine.\n' > "$tmp/prs/12"
touch "$tmp/prs/12.fail"
if run_step v0.26.0+178; then fail "a failing gh pr view (last PR) did not fail the step"; fi
[ ! -s "$tmp/calls" ] || fail "a partial note was stored after gh pr view failed"
rm "$tmp/prs/12.fail"; touch "$tmp/prs/10.fail"
if run_step v0.26.0+178; then fail "a failing gh pr view (first PR) did not fail the step"; fi
[ ! -s "$tmp/calls" ] || fail "a partial note was stored after gh pr view failed"
rm "$tmp/prs/10.fail"

echo "whats_new_note_test: OK"
