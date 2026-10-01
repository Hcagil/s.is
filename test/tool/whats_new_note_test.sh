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
#   - a failing `gh api` pull read fails the run block, and the step is
#     continue-on-error so that failure never blocks the release;
#   - each PR is read from the REST endpoint repos/$GITHUB_REPOSITORY/pulls/N
#     and kept by its snake_case author_association;
#   - the step is `id: note` and writes the stored note, base64 on one line, as
#     output `b64` (publish exposes it as note_b64 for TestFlight's What to
#     Test): only when there is a note, before the insert (a failed insert
#     still hands it on), and it decodes to exactly the stored text.
#
# A `run:` block with no `shell:` runs as `bash -e {0}` on GitHub Actions --
# errexit but NOT pipefail -- so the step runs that way here; any pipefail
# comes from the step itself.
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
note_keys=$(awk '/- name: Store the What.s new note for this build/ { f = 1; next } f && /^ *run: \|/ { exit } f' "$workflow")
grep -q '^ *continue-on-error: true *$' <<<"$note_keys" \
  || { echo "FAIL: the note step must be continue-on-error: a gh/db hiccup must not block the release"; exit 1; }
grep -q '^ *id: note *$' <<<"$note_keys" || { echo "FAIL: the note step must be id: note (publish reads steps.note.outputs.b64)"; exit 1; }
# publish's outputs map hands the note on.
grep -q '^      note_b64: \${{ steps\.note\.outputs\.b64 }}$' <<<"$(awk '$0 == "  publish:" { j = 1; next } j && /^  [A-Za-z0-9_-]+:/ { exit } j && /^    outputs:$/ { o = 1; next }
     o && !/^      / { o = 0 } o' "$workflow")" \
  || { echo "FAIL: publish must output note_b64: \${{ steps.note.outputs.b64 }}"; exit 1; }

# Stand-ins. gh answers from files; supabase records its arguments.
# The gh stand-in is strict: it accepts only the calls this step may make, in
# the shape the real CLI and REST API accept, and refuses anything else. A
# lenient stand-in once accepted `gh pr view --json authorAssociation`, which
# real gh rejects ("Unknown JSON field"), and a release lost its note.
#   gh release list --limit N --json tagName --jq F
#       serves [{tagName: $STUB_PREV_TAG}], or [] when it is empty;
#   gh api repos/$STUB_REPO/pulls/N --jq F
#       serves the REST pull object {number, body, author_association}
#       (snake_case, as the REST API returns it; body from prs/N, or null when
#       prs/N.null exists; association from prs/N.assoc, default NONE);
#       prs/N.fail answers like an HTTP error.
# Every --json field and every .field a --jq filter reads must be one served
# here. F is applied with real jq, raw output, as gh does. A refused call is
# logged to $STUB_REJECTS so a swallowed failure still fails the test.
mkdir -p "$tmp/bin" "$tmp/prs"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
die() { echo "gh stub: $* (call: gh $args)" >&2; echo "gh $args" >> "$STUB_REJECTS"; exit 2; }
check_filter() { # $1 jq filter, $2 served field names
  local f
  for f in $(grep -oE '\.[A-Za-z_][A-Za-z0-9_]*' <<<"$1" | cut -c2-); do
    [[ " $2 " == *" $f "* ]] || die "jq filter reads field '$f', which is not served"
  done
}
case "${1:-} ${2:-}" in
  "release list")
    shift 2; filter=
    while [ $# -gt 0 ]; do
      case "$1" in
        --limit) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "bad --limit"; shift 2 ;;
        --json) for f in ${2//,/ }; do [ "$f" = tagName ] || die "Unknown JSON field: \"$f\""; done; shift 2 ;;
        --jq) filter=$2; shift 2 ;;
        *) die "unknown flag $1" ;;
      esac
    done
    [ -n "$filter" ] || die "release list without --jq"
    check_filter "$filter" tagName
    jq -n --arg t "${STUB_PREV_TAG:-}" 'if $t == "" then [] else [{tagName: $t}] end' | jq -r "$filter" ;;
  api\ *)
    path=$2; shift 2; filter=
    while [ $# -gt 0 ]; do
      case "$1" in --jq) filter=$2; shift 2 ;; *) die "unknown flag $1" ;; esac
    done
    [[ "$path" =~ ^repos/${STUB_REPO}/pulls/([0-9]+)$ ]] \
      || die "unexpected endpoint '$path', want repos/$STUB_REPO/pulls/<n>"
    pr=${BASH_REMATCH[1]}
    echo "$path" >> "$STUB_API"
    [ -n "$filter" ] || die "api without --jq"
    check_filter "$filter" "number body author_association"
    [ ! -e "$STUB_PRS/$pr.fail" ] || { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
    assoc=NONE; [ ! -e "$STUB_PRS/$pr.assoc" ] || assoc=$(cat "$STUB_PRS/$pr.assoc")
    if [ -e "$STUB_PRS/$pr.null" ]; then
      jq -n --argjson n "$pr" --arg a "$assoc" '{number: $n, body: null, author_association: $a}'
    else
      jq -n --argjson n "$pr" --rawfile body "$STUB_PRS/$pr" --arg a "$assoc" \
        '{number: $n, body: $body, author_association: $a}'
    fi | jq -r "$filter" ;;
  *) die "unexpected subcommand" ;;
esac
EOF
cat > "$tmp/bin/supabase" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
[ -z "${STUB_DB_FAIL:-}" ] || { echo "supabase: connection refused" >&2; exit 1; }
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
  : > "$tmp/calls"; : > "$tmp/api"; : > "$tmp/rejects"; : > "$tmp/ghout"
  local rc=0
  (cd "$repo" && PATH="$tmp/bin:$PATH" STUB_PREV_TAG="$1" STUB_PRS="$tmp/prs" GITHUB_OUTPUT="$tmp/ghout" \
    STUB_CALLS="$tmp/calls" STUB_API="$tmp/api" STUB_REJECTS="$tmp/rejects" \
    STUB_REPO=owner/repo GITHUB_REPOSITORY=owner/repo \
    SHA="$head_sha" BUILD=179 GH_TOKEN=x \
    bash -e "$tmp/step.sh") > "$tmp/out" 2>&1 || rc=$?
  # A call the real gh would refuse fails the test even where the step's
  # `|| exit 1`, a pipeline or continue-on-error would hide it.
  [ ! -s "$tmp/rejects" ] || fail "gh called in a way the real CLI/API refuses: $(cat "$tmp/rejects")"
  return $rc
}
fail() { echo "FAIL: $1"; echo "--- step output"; cat "$tmp/out"; echo "--- supabase calls"; cat "$tmp/calls"; exit 1; }
note_of() { # the text the insert would store
  sed -n "s/.*decode('\([A-Za-z0-9+/=]*\)', 'base64').*/\1/p" "$tmp/calls" | base64 -d
}
check_out() { # GITHUB_OUTPUT must hold exactly one b64= line (a wrapped value corrupts the file)
  [ "$(grep -c '' "$tmp/ghout")" -eq 1 ] && grep -qxE 'b64=[A-Za-z0-9+/]*={0,2}' "$tmp/ghout" \
    || fail "GITHUB_OUTPUT is not one b64= line: [$(cat "$tmp/ghout")]"
}
out_of() { sed -n 's/^b64=//p' "$tmp/ghout" | base64 -d; } # the note handed to distribute
same_note() { # the b64 output decodes to exactly the stored note (trailing newlines included)
  check_out
  local a b; a=$(out_of; printf .); b=$(note_of; printf .)
  [ "$a" = "$b" ] || fail "b64 output [${a%.}] differs from the stored note [${b%.}]"
}

# 1 lines since the previous release, in merge order
run_step v0.26.0+178 || fail "step exited non-zero"
[ "$(wc -l < "$tmp/calls")" -eq 1 ] || fail "expected exactly one insert"
[ "$(cat "$tmp/api")" = "$(printf "repos/owner/repo/pulls/%s\n" 10 11 12)" ] \
  || fail "PRs not read from repos/owner/repo/pulls/<n> in merge order: [$(cat "$tmp/api")]"
grep -q -- '--linked' "$tmp/calls" || fail "insert not sent to the linked project"
grep -q 'insert into public.release_notes(build, note) values (179, ' "$tmp/calls" \
  || fail "insert does not target build 179"
grep -q 'on conflict (build) do nothing' "$tmp/calls" || fail "a re-run would overwrite a dashboard edit"
expected=$(printf '%s\n%s' 'You can pick a sound.' 'It'"'"'s faster; "quoted" $(rm -rf /) `x` too.')
[ "$(note_of)" = "$expected" ] || fail "note was: [$(note_of)]"
if grep -q 'rm -rf\|quoted\|faster' "$tmp/calls"; then fail "PR text reached SQL unencoded"; fi
if grep -q $'\r' <<<"$(note_of)"; then fail "a carriage return survived"; fi
if grep -q 'Old news' <<<"$(note_of)"; then fail "a PR from the previous release was included"; fi
same_note

# 2 nothing user-facing -> no insert, still success
printf 'For users:   \n' > "$tmp/prs/10"
printf 'Nothing to see.\n' > "$tmp/prs/12"
run_step v0.26.0+178 || fail "step failed when there was nothing to store"
[ ! -s "$tmp/calls" ] || fail "an insert was made with no For users line"
[ ! -s "$tmp/ghout" ] || fail "a b64 output was written with no note: [$(cat "$tmp/ghout")]"

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
if grep -q stranger <<<"$(note_of)"; then fail "a CONTRIBUTOR's For users line was stored"; fi
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
both=$(printf '%s\n%s' "$long" "$long")
[ "$stored" = "${both:0:4000}" ] || fail "long note is not the first 4000 characters"
same_note

# 6 a failing gh api read fails the run block, and stores nothing
printf 'For users: Fine.\n' > "$tmp/prs/10"
printf 'For users: Also fine.\n' > "$tmp/prs/12"
touch "$tmp/prs/12.fail"
if run_step v0.26.0+178; then fail "a failing gh api read (last PR) did not fail the step"; fi
[ ! -s "$tmp/calls" ] || fail "a partial note was stored after gh api read failed"
rm "$tmp/prs/12.fail"; touch "$tmp/prs/10.fail"
if run_step v0.26.0+178; then fail "a failing gh api read (first PR) did not fail the step"; fi
[ ! -s "$tmp/calls" ] || fail "a partial note was stored after gh api read failed"
rm "$tmp/prs/10.fail"

# 7 a PR with no description (REST body null) contributes nothing, breaks nothing
printf "For users: Kept.\n" > "$tmp/prs/12"
touch "$tmp/prs/10.null"
run_step v0.26.0+178 || fail "step exited non-zero on a null PR body"
[ "$(note_of)" = "Kept." ] || fail "null body: note was [$(note_of)]"
rm "$tmp/prs/10.null"

# 8 the b64 output round-trips a multi-line UTF-8 note with quotes exactly,
# and is written before the insert: a failed insert still hands it on.
printf "For users: Şarkı seçebilirsin — \"alıntı\" 'tek' \\ \$HOME 🎵\n" > "$tmp/prs/10"
printf "For users: İkinci satır.\n" > "$tmp/prs/12"
utf=$(printf '%s\n%s' "Şarkı seçebilirsin — \"alıntı\" 'tek' \\ \$HOME 🎵" "İkinci satır.")
run_step v0.26.0+178 || fail "step exited non-zero on a UTF-8 note"
check_out
[ "$(out_of)" = "$utf" ] || fail "b64 output decodes to [$(out_of)], want [$utf]"
same_note
if STUB_DB_FAIL=1 run_step v0.26.0+178; then fail "a failed insert did not fail the run block"; fi
check_out
[ "$(out_of)" = "$utf" ] || fail "the note was not handed on when the insert failed (b64 must come before the insert)"

echo "whats_new_note_test: OK"
