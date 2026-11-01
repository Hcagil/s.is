#!/usr/bin/env bash
# Three workflow steps that read a command's output, run as written (lifted out
# of the files, not copied) against stand-ins for git, xcrun and codesign, each
# under GitHub's default `bash -e` AND under `bash -eo pipefail`, including a
# large input whose answer is on the first line -- the shape that kills the
# writer with SIGPIPE (exit 141) when the reader stops early:
#
#   release.yml `scope` / "Pick the newest commit whose CI passed on main" (id: pick)
#   - asks gh for exactly the newest passed ci.yml push run on main and outputs
#     sha=<its head sha>; no such run, or a failing gh, fails the step red and
#     outputs nothing;
#   release.yml `scope` / "Decide whether the commits since the last release
#     ship" (id: diff), run in a real git repo with the real tool/release_scope.sh
#   - judges $SHA = steps.pick.outputs.sha against the newest release tag gh
#     returns ("" = none: the commit alone); outputs exactly its ship= line;
#     an unknown commit or an unreadable release list fails the step and
#     outputs nothing; the summary names the reason or the event; a release
#     already published today in Europe/Istanbul turns ship=false for a
#     schedule, workflow_run or reason=daily dispatch, never for another reason;
#   ci.yml "Native iOS tests (simulator)"
#   - the destination is the UUID on the first `  iPhone` line of
#     `xcrun simctl list devices available`; never a UUID from another line;
#     no iPhone -> the step fails before xcodebuild; a failing xcodebuild
#     fails the step with its own code after printing the result bundle's
#     summary (the same -resultBundlePath);
#   ci.yml "Video prep integration test (simulator)"
#   - flutter's output reaches the log; its exit code is the step's; no
#     clock before "Xcode build done" (a slow build is not a hang); after it,
#     no result within VIDEO_PREP_AFTER_BUILD_S -> flutter is stopped and the
#     step fails at once with an ::error:: line;
#   release.yml `publish` / "Tag and publish release notes"
#   - creates release v<name>+<code> targeting $SHA (scope's picked commit);
#     up to 3 tries, waiting 10 s after the 1st failure and 30 s after the 2nd;
#     after a failed create, an existing release (`gh release view` succeeds)
#     ends the step with 0; 3 failures and no release -> a message, exit 1;
#   ios-ipa.yml "Check the signature"
#   - authority = the text after the FIRST `Authority=` line of
#     `codesign -dvv` (stderr included); signed only when it begins with
#     `Apple Distribution: `; anything else (another authority first, none,
#     ad-hoc) fails the step.
set -euo pipefail
command -v zip >/dev/null || { echo "FAIL: zip is required"; exit 1; }
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; [ ! -s "$tmp/out" ] || { echo "--- step output"; tail -20 "$tmp/out"; }; exit 1; }
SHELLS=("bash -e" "bash -eo pipefail")
BIG=200000

# step_run <file> <step name> <out>: the step's `run: |` block, de-indented.
step_run() {
  awk -v n="- name: $2" '
    index($0, n) && substr($0, index($0, n) + length(n)) == "" { found = 1; next }
    found && !inrun && /^ *- / { exit }
    found && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
    inrun {
      if ($0 ~ /^ *$/) { print ""; next }
      match($0, /^ */); if (RLENGTH <= ind) exit
      if (!body) body = RLENGTH
      print substr($0, body + 1)
    }' "$1" > "$3"
  [ -s "$3" ] || fail "step '$2' not found in $1"
  ! grep -q '\${{' "$3" || fail "step '$2' pastes an expression into its script"
}
mkdir -p "$tmp/bin"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }

# ---- 1 release commit and ship decision -----------------------------------------
# "Pick": gh answers the one exact query (newest passed ci.yml push run on main)
# with $GREEN ("!" = gh fails); any other call fails.
step_run .github/workflows/release.yml "Pick the newest commit whose CI passed on main" "$tmp/pick.sh"
grep -A1 -- '- name: Pick the newest commit whose CI passed on main' .github/workflows/release.yml | grep -qE '^ *id: pick$' \
  || fail "Pick the newest commit whose CI passed on main is not step id pick"
stub gh 'if [ "$*" = "run list --workflow ci.yml --branch main --event push --status success --limit 1 --json headSha --jq .[0].headSha // empty" ]; then
  [ "$GREEN" = "!" ] && exit 1; [ -n "$GREEN" ] && echo "$GREEN"; exit 0; fi
if [ "$*" = "release list --limit 1 --json tagName --jq .[0].tagName // empty" ]; then
  [ "$PREV" = "!" ] && exit 1; [ -n "$PREV" ] && echo "$PREV"; exit 0; fi
if [ "$*" = "release list --limit 1 --json publishedAt --jq .[0].publishedAt // empty" ]; then
  [ "$LAST" = "!" ] && exit 1; [ -n "$LAST" ] && echo "$LAST"; exit 0; fi
echo "gh stub: unexpected: $*" >&2; exit 2'
pick() { # <shell> <green> -> sets rc; $tmp/gh_out holds the outputs
  : > "$tmp/gh_out"; set +e
  PATH="$tmp/bin:$PATH" GREEN=$2 GITHUB_OUTPUT="$tmp/gh_out" $1 "$tmp/pick.sh" > "$tmp/out" 2>&1; rc=$?; set -e
}
for sh in "${SHELLS[@]}"; do
  pick "$sh" 0123abc
  [ $rc = 0 ] && [ "$(cat "$tmp/gh_out")" = sha=0123abc ] || fail "pick under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")], want sha=0123abc"
  pick "$sh" ""
  [ $rc != 0 ] && [ ! -s "$tmp/gh_out" ] && grep -q 'No commit on main has a passed CI run' "$tmp/out" \
    || fail "pick with no green run under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")] (must fail red, output nothing)"
  pick "$sh" '!'
  [ $rc != 0 ] && [ ! -s "$tmp/gh_out" ] || fail "pick with a failing gh under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")]"
done

# "Decide": the step as written, run in a real git repo with the real
# tool/release_scope.sh (its path rules: test/tool/release_scope_test.sh);
# gh answers the last release tag with $PREV.
grep -A1 -- '- name: Decide whether the commits since the last release ship' .github/workflows/release.yml | grep -qE '^ *id: diff$' \
  || fail "Decide whether the commits since the last release ship is not step id diff"
grep -A6 -- '- name: Decide whether the commits since the last release ship' .github/workflows/release.yml \
  | grep -qE '^ *SHA: \$\{\{ steps\.pick\.outputs\.sha \}\}$' || fail "the ship decision does not judge the picked commit"
step_run .github/workflows/release.yml "Decide whether the commits since the last release ship" "$tmp/ship.sh"
repo=$tmp/repo; mkdir -p "$repo/tool" "$repo/lib" "$repo/docs"
cp tool/release_scope.sh "$repo/tool/"
(
  cd "$repo"; git init -q -b main .; git config user.email qa@sis.test; git config user.name QA
  git config commit.gpgsign false; git config tag.gpgsign false
  echo 1 > lib/a.dart; git add lib; git commit -q -m app; git tag -a v1 -m v1
  echo 2 > docs/a.md; git add docs; git commit -q -m docs; git tag docs-commit
  echo 3 > lib/a.dart; git add lib; git commit -q -m app2; git tag app-commit
)
D=$(git -C "$repo" rev-parse docs-commit); L=$(git -C "$repo" rev-parse app-commit)
# gh answers the last release tag with $PREV and its publishedAt with $LAST
# ("" = no release, "!" = gh fails). The test runs under TZ=UTC so a guard that
# forgets Europe/Istanbul is caught by the late-UTC-evening case below.
decide() { # <shell> <prev> <sha> [reason] [event=schedule] [last] -> sets rc; $tmp/gh_out, $tmp/summary
  : > "$tmp/gh_out"; : > "$tmp/summary"; set +e
  (cd "$repo" && PATH="$tmp/bin:$PATH" TZ=UTC PREV=$2 SHA=$3 REASON=${4:-} EVENT=${5:-schedule} LAST=${6:-} \
    GITHUB_OUTPUT="$tmp/gh_out" GITHUB_STEP_SUMMARY="$tmp/summary" $1 "$tmp/ship.sh") > "$tmp/out" 2>&1; rc=$?; set -e
}
now=$(date -u +%FT%TZ); empty=
today_ist=$(TZ=Europe/Istanbul date +%F)
# 00:30 today in Istanbul = 21:30 on the previous UTC day, in gh's Z form.
early_ist=$(date -u -d "${today_ist}T00:30:00+03:00" +%FT%TZ)
yesterday_ist=$(TZ=Europe/Istanbul date -d yesterday +%F)T12:00:00Z
for sh in "${SHELLS[@]}"; do
  while read -r prev sha want; do
    [ "$prev" = - ] && prev=
    decide "$sh" "$prev" "${!sha}"
    [ $rc = 0 ] && [ "$(cat "$tmp/gh_out")" = "ship=$want" ] \
      || fail "decide prev [$prev] sha $sha under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")], want ship=$want"
  done <<'TABLE'
v1 D false
v1 L true
- D false
- L true
docs-commit L true
app-commit L false
TABLE
  # One release per Istanbul day: a release already published today blocks a
  # scheduled, CI-triggered or "daily" manual run; any other manual reason ships.
  while read -r reason event last want; do
    [ "$reason" = - ] && reason=
    decide "$sh" v1 "$L" "$reason" "$event" "${!last}"
    [ $rc = 0 ] && [ "$(cat "$tmp/gh_out")" = "ship=$want" ] \
      || fail "decide event $event reason [$reason] last \$$last under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")], want ship=$want"
  done <<'TABLE'
- schedule now false
- workflow_run now false
daily workflow_dispatch now false
urgent workflow_dispatch now true
- schedule early_ist false
- schedule yesterday_ist true
- schedule empty true
TABLE
  decide "$sh" v1 "$L" "" schedule '!'
  [ $rc != 0 ] && [ ! -s "$tmp/gh_out" ] || fail "an unreadable publishedAt under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")] (must fail, decide nothing)"
  decide "$sh" v1 "$D"
  grep -q 'schedule' "$tmp/summary" || fail "a scheduled run's summary does not name the event: [$(cat "$tmp/summary")]"
  decide "$sh" v1 "$D" 'crash for everyone' workflow_dispatch
  grep -q 'crash for everyone' "$tmp/summary" || fail "a manual run's summary lacks its reason: [$(cat "$tmp/summary")]"
  decide "$sh" v1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  [ $rc != 0 ] && [ ! -s "$tmp/gh_out" ] || fail "an unknown release commit under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")] (must fail, decide nothing)"
  decide "$sh" '!' "$L"
  [ $rc != 0 ] && [ ! -s "$tmp/gh_out" ] || fail "an unreadable last release under '$sh': rc $rc, outputs [$(cat "$tmp/gh_out")] (must fail, never judge sha^ alone)"
done

# ---- 2 simulator UDID ----------------------------------------------------------
step_run .github/workflows/ci.yml "Native iOS tests (simulator)" "$tmp/udid.sh"
stub flutter ':'
stub xcrun 'case "$*" in
  "simctl list devices available") cat "$DEVICES" ;;
  "simctl bootstatus "*" -b") ;;
  "xcresulttool get test-results summary --path "*) echo "SUMMARY of ${*: -1}" ;;
  *) echo "xcrun stub: unexpected: $*" >&2; exit 2 ;;
esac'
# xcodebuild: records the exact -destination argument (a multi-line one too)
# and the -resultBundlePath; exits $XCB_RC.
stub xcodebuild 'while [ $# -gt 0 ]; do
  [ "$1" = -destination ] && printf "%s" "$2" > "$XCB_ARGS"
  [ "$1" = -resultBundlePath ] && printf "%s" "$2" > "$XCB_ARGS.bundle"
  shift; done; exit "${XCB_RC:-0}"'
udid() { # <shell> <devices file> [XCB_RC] -> prints the -destination given to xcodebuild; rc of the step
  rm -f "$tmp/xcb" "$tmp/xcb.bundle"
  local rc=0
  PATH="$tmp/bin:$PATH" DEVICES=$2 XCB_ARGS="$tmp/xcb" XCB_RC=${3:-0} RUNNER_TEMP="$tmp/rt" \
    $1 "$tmp/udid.sh" > "$tmp/out" 2>&1 || rc=$?
  [ ! -e "$tmp/xcb" ] || cat "$tmp/xcb"
  return $rc
}
A=11111111-AAAA-4BBB-8CCC-111111111111
B=22222222-AAAA-4BBB-8CCC-222222222222
W=33333333-AAAA-4BBB-8CCC-333333333333
cat > "$tmp/dev-normal" <<EOF
== Devices ==
-- iOS 26.0 --
    iPad Air 11-inch (M3) ($W) (Shutdown)
    iPhone 17 Pro ($A) (Shutdown)
    iPhone 17 ($B) (Shutdown)
-- watchOS 26.0 --
    Apple Watch Series 11 (46mm) ($W) (Shutdown)
EOF
printf '== Devices ==\n-- iOS 26.0 --\n    iPad Pro 13-inch (M4) (%s) (Shutdown)\n-- tvOS 26.0 --\n    Apple TV 4K (%s) (Shutdown)\n' "$W" "$B" > "$tmp/dev-none"
# `iPhone` not at line start after spaces: a header and an unindented line never count.
printf '== Devices ==\n-- iPhone runtimes --\niPhone 1 (%s) (Shutdown)\n    iPad mini (%s) (Shutdown)\n    iPhone 16e (%s) (Booted)\n' "$W" "$W" "$A" > "$tmp/dev-tricky"
{ echo "== Devices =="; echo "-- iOS 26.0 --"; echo "    iPhone 17 Pro ($A) (Shutdown)"
  for ((i = 0; i < BIG; i++)); do echo "    iPhone 17 ($B) (Shutdown)"; done; } > "$tmp/dev-big"
for sh in "${SHELLS[@]}"; do
  [ "$(udid "$sh" "$tmp/dev-normal")" = "id=$A" ] || fail "normal list under '$sh': destination [$(udid "$sh" "$tmp/dev-normal" || true)], want id=$A"
  [ "$(udid "$sh" "$tmp/dev-tricky")" = "id=$A" ] || fail "only an indented iPhone line counts under '$sh'"
  got=$(udid "$sh" "$tmp/dev-big") || fail "a $BIG-line device list failed the step under '$sh' (SIGPIPE?)"
  [ "$got" = "id=$A" ] || fail "a $BIG-line device list under '$sh' gave [$got], want id=$A"
  if udid "$sh" "$tmp/dev-none" > /dev/null; then fail "no iPhone, yet the step passed under '$sh'"; fi
  [ ! -e "$tmp/xcb" ] || fail "no iPhone, yet xcodebuild ran under '$sh' with $(tr '\n' ' ' < "$tmp/xcb")"
  # Green: no summary. Red (65, a failing test): the summary of the bundle
  # xcodebuild wrote, then the step fails with xcodebuild's code.
  udid "$sh" "$tmp/dev-normal" > /dev/null || fail "a passing xcodebuild failed the step under '$sh'"
  ! grep -q SUMMARY "$tmp/out" || fail "a passing run printed the result summary under '$sh'"
  rc=0; udid "$sh" "$tmp/dev-normal" 65 > /dev/null || rc=$?
  [ "$rc" = 65 ] || fail "a failing xcodebuild (65) ended the step with $rc under '$sh'"
  bundle=$(cat "$tmp/xcb.bundle" 2>/dev/null) || fail "xcodebuild got no -resultBundlePath under '$sh'"
  [ "$bundle" = "$tmp/rt/RunnerTests.xcresult" ] || fail "result bundle [$bundle] is not in RUNNER_TEMP under '$sh'"
  grep -qxF "SUMMARY of $bundle" "$tmp/out" || fail "a failing run did not print the summary of $bundle under '$sh': $(cat "$tmp/out")"
done

# ---- 2b video prep: flutter's exit code, and a hang after the build ----------
step_run .github/workflows/ci.yml "Video prep integration test (simulator)" "$tmp/video.sh"
# flutter: prints its arguments; FL_BUILT=1 prints flutter's "Xcode build
# done" line; then sleeps FL_SLEEP seconds (exec: the step's kill reaches it)
# or exits FL_RC.
stub flutter 'echo "flutter $*"
[ "${FL_BUILT:-0}" = 1 ] && echo "Xcode build done.                                           248.7s"
[ "${FL_SLEEP:-0}" = 0 ] || exec sleep "$FL_SLEEP"
exit "${FL_RC:-0}"'
video() { # <shell> <FL_BUILT> <FL_SLEEP> <FL_RC> -> rc of the step; output in $tmp/out, seconds in $tmp/secs
  local rc=0 t0=$SECONDS
  PATH="$tmp/bin:$PATH" DEVICES="$tmp/dev-normal" RUNNER_TEMP="$tmp/rt" VIDEO_PREP_AFTER_BUILD_S=2 \
    FL_BUILT=$2 FL_SLEEP=$3 FL_RC=$4 $1 "$tmp/video.sh" > "$tmp/out" 2>&1 || rc=$?
  echo $((SECONDS - t0)) > "$tmp/secs"
  return $rc
}
mkdir -p "$tmp/rt"
for sh in "${SHELLS[@]}"; do
  video "$sh" 1 0 0 || fail "a passing flutter test failed the step under '$sh'"
  grep -qxF "flutter test integration_test/video_source_prep_ios_test.dart -d $A" "$tmp/out" \
    || fail "flutter's output (or the -d $A) is missing from the step log under '$sh': $(cat "$tmp/out")"
  ! grep -q '::error::' "$tmp/out" || fail "a passing run printed an error under '$sh'"
  rc=0; video "$sh" 1 0 3 || rc=$?
  [ "$rc" = 3 ] || fail "flutter test exit 3 ended the step with $rc under '$sh'"
  ! grep -q '::error::' "$tmp/out" || fail "a failing test was reported as a hang under '$sh'"
  # Built, then silent: stopped after the 2 s limit, not after the 30 s sleep.
  rc=0; video "$sh" 1 30 0 || rc=$?
  [ "$rc" != 0 ] || fail "flutter hanging after the build passed the step under '$sh'"
  [ "$(cat "$tmp/secs")" -le 10 ] || fail "a hang after the build took $(cat "$tmp/secs")s to fail under '$sh'"
  grep -q '^::error::video prep test: no result 2s after the Xcode build' "$tmp/out" \
    || fail "a hang after the build has no ::error:: line under '$sh': $(cat "$tmp/out")"
  # Still building after the limit (no "Xcode build done" yet): not a hang.
  video "$sh" 0 4 0 || fail "a build slower than the after-build limit failed the step under '$sh': $(cat "$tmp/out")"
done

# ---- 3 signature authority ---------------------------------------------------
step_run .github/workflows/ios-ipa.yml "Check the signature" "$tmp/sig.sh"
# codesign: -dvv OBJ prints $CS/<basename>.dvv (half to stderr, the step merges
# it); -d -r- prints a requirement; --verify passes.
stub codesign 'obj=${!#}
case "$1" in
  -dvv) f="$CS/$(basename "$obj").dvv"; [ -e "$f" ] || exit 1
        head -2 "$f" >&2; tail -n +3 "$f" ;;
  -d) echo "designated => identifier x" ;;
  --verify) exit 0 ;;
  *) echo "codesign stub: unexpected: $*" >&2; exit 2 ;;
esac'
# A real Runner.app always holds Flutter.framework and PlugIns/ShareExtension.appex (the loops have no nullglob).
sig() { # <shell> <app authority file> [<Flutter.framework authority file>] [<ShareExtension.appex authority file>] (default distribution); rc of the step
  rm -rf "$tmp/rt" "$tmp/cs"; mkdir -p "$tmp/rt/export" "$tmp/cs" "$tmp/pkg/Payload/Runner.app/Frameworks"
  rm -rf "$tmp/pkg/Payload/Runner.app/Frameworks/"*
  cp "$2" "$tmp/cs/Runner.app.dvv"
  mkdir "$tmp/pkg/Payload/Runner.app/Frameworks/Flutter.framework"; cp "${3:-$tmp/a-dist}" "$tmp/cs/Flutter.framework.dvv"
  rm -rf "$tmp/pkg/Payload/Runner.app/PlugIns"; mkdir -p "$tmp/pkg/Payload/Runner.app/PlugIns/ShareExtension.appex"
  cp "${4:-$tmp/a-dist}" "$tmp/cs/ShareExtension.appex.dvv"
  (cd "$tmp/pkg" && rm -f "$tmp/rt/export/sis.ipa" && zip -qr "$tmp/rt/export/sis.ipa" Payload)
  PATH="$tmp/bin:$PATH" CS="$tmp/cs" RUNNER_TEMP="$tmp/rt" $1 "$tmp/sig.sh" > "$tmp/out" 2>&1
}
dvv() { printf 'Executable=/x/Runner\nIdentifier=com.esd.sis\nFormat=app bundle with Mach-O thin (arm64)\nCodeDirectory v=20500 size=1 flags=0x0(none)\n'; printf '%s\n' "$@"; printf 'TeamIdentifier=TEAM123\n'; }
DIST="Apple Distribution: Hayrullah Cagil (TEAM123)"
dvv "Authority=$DIST" "Authority=Apple Worldwide Developer Relations Certification Authority" "Authority=Apple Root CA" > "$tmp/a-dist"
dvv "Authority=Apple Development: Hayrullah Cagil (TEAM123)" "Authority=$DIST" "Authority=Apple Root CA" > "$tmp/a-dev-first"
dvv "Signature=adhoc" > "$tmp/a-adhoc"
dvv "Authority=Apple Root CA" "Authority=$DIST" > "$tmp/a-root-first"
dvv "Authority=xApple Distribution: X" > "$tmp/a-prefixed"
dvv "Authority=Apple Distribution:X" > "$tmp/a-nospace"
dvv " Authority=$DIST" > "$tmp/a-indented"
# Large: the distribution authority first, then many more Authority lines.
{ dvv "Authority=$DIST"; for ((i = 0; i < BIG; i++)); do echo "Authority=Apple Root CA $i"; done; } > "$tmp/a-big"
# Authority on stderr only (the first lines go to stderr): merged, still read.
printf 'Authority=%s\nIdentifier=x\nTeamIdentifier=TEAM123\n' "$DIST" > "$tmp/a-stderr"
for sh in "${SHELLS[@]}"; do
  sig "$sh" "$tmp/a-dist" || fail "a distribution-signed app failed under '$sh'"
  [ "$(grep -A1 -xF "Runner.app: $DIST" "$tmp/out" | tail -1)" = "  DR: identifier x" ] \
    || fail "the app's authority is not reported as exactly [$DIST] under '$sh'"
  sig "$sh" "$tmp/a-dist" "$tmp/a-dist" || fail "a distribution-signed app and framework failed under '$sh'"
  grep -qxF "ShareExtension.appex: $DIST" "$tmp/out" || fail "the share extension's authority is not reported under '$sh': $(cat "$tmp/out")"
  sig "$sh" "$tmp/a-stderr" || fail "an authority printed on stderr was not read under '$sh'"
  sig "$sh" "$tmp/a-big" || fail "a distribution signature with $BIG more Authority lines failed under '$sh' (SIGPIPE?)"
  [ "$(grep -A1 -xF "Runner.app: $DIST" "$tmp/out" | tail -1)" = "  DR: identifier x" ] \
    || fail "large input: authority is not exactly the first line's under '$sh'"
  for bad in a-dev-first a-adhoc a-root-first a-prefixed a-nospace a-indented; do
    if sig "$sh" "$tmp/$bad"; then fail "app with $bad passed the signature check under '$sh'"; fi
    if sig "$sh" "$tmp/a-dist" "$tmp/$bad"; then fail "framework with $bad passed the signature check under '$sh'"; fi
    if sig "$sh" "$tmp/a-dist" "$tmp/a-dist" "$tmp/$bad"; then fail "share extension with $bad passed the signature check under '$sh'"; fi
  done
  sig "$sh" "$tmp/a-adhoc" || true
  grep -qxF "Runner.app: unsigned or ad-hoc" "$tmp/out" || fail "no Authority line is not reported as unsigned under '$sh'"
done

# ---- 4 release tag: retried, and a release that already exists is success ----
# "Tag and publish release notes" as written; gh fails the first $FAILS creates
# ("all" = every one) and `release view` of the tag succeeds from view call
# number $VIEW_FROM on (0 = never); sleep is a stand-in that only logs.
grep -A3 -- '- name: Tag and publish release notes' .github/workflows/release.yml | grep -qE '^ *GH_TOKEN: \$\{\{ github\.token \}\}$' \
  || fail "the tag step does not get GH_TOKEN"
awk '/^  publish:/ { f = 1; next } f && /^  [a-z-]+:/ { exit } f && /^    env:/ { e = 1; next } e && !/^      / { exit } e' .github/workflows/release.yml \
  | grep -qE '^      SHA: \$\{\{ needs\.scope\.outputs\.sha \}\}$' || fail "publish's SHA is not scope's picked commit"
awk -v n="- name: Tag and publish release notes" '
  index($0, n) && substr($0, index($0, n) + length(n)) == "" { found = 1; next }
  found && !inrun && /^ *- / { exit }
  found && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
  inrun { if ($0 ~ /^ *$/) { print ""; next }; match($0, /^ */); if (RLENGTH <= ind) exit; if (!body) body = RLENGTH; print substr($0, body + 1) }' \
  .github/workflows/release.yml | sed 's/\${{ needs\.scope\.outputs\.name }}/26.10.5/g; s/\${{ needs\.scope\.outputs\.code }}/177/g' > "$tmp/tag.sh"
[ -s "$tmp/tag.sh" ] || fail "step 'Tag and publish release notes' not found"
! grep -q '\${{' "$tmp/tag.sh" || fail "the tag step reads an unexpected expression: $(cat "$tmp/tag.sh")"
TAG='v26.10.5+177'; PICK=0123abcd0123abcd0123abcd0123abcd0123abcd
stub gh 'echo "gh $*" >> "$CALLS"
case "$1 $2" in
  "release create")
    [ "$3" = "$TAG" ] || { echo "gh stub: create of [$3]" >&2; exit 2; }
    t=; for a in "$@"; do [ "$t" = 1 ] && { [ "$a" = "$PICK" ] || exit 2; t=2; }; [ "$a" = --target ] && t=1; done
    [ "$t" = 2 ] || { echo "gh stub: create without --target $PICK: $*" >&2; exit 2; }
    n=$(grep -c "^gh release create" "$CALLS")
    [ "$FAILS" = all ] && exit 1; [ "$n" -le "$FAILS" ] && exit 1; exit 0 ;;
  "release view")
    [ "$3" = "$TAG" ] || exit 1
    n=$(grep -c "^gh release view" "$CALLS")
    [ "$VIEW_FROM" != 0 ] && [ "$n" -ge "$VIEW_FROM" ] && exit 0; exit 1 ;;
esac
echo "gh stub: unexpected: $*" >&2; exit 2'
stub sleep 'echo "sleep $*" >> "$CALLS"'
tagrun() { # <shell> <fails> <view_from> -> sets rc; $tmp/calls
  : > "$tmp/calls"; set +e
  PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" TAG=$TAG PICK=$PICK SHA=$PICK FAILS=$2 VIEW_FROM=$3 $1 "$tmp/tag.sh" >> "$tmp/calls" 2>&1; rc=$?; set -e
}
seq_of() { grep -E '^(gh release create|sleep)' "$tmp/calls" | awk '{ print $1 == "sleep" ? "sleep" $2 : "create" }' | tr '\n' ' '; }
for sh in "${SHELLS[@]}"; do
  while read -r fails view_from want_rc want_seq; do
    tagrun "$sh" "$fails" "$view_from"
    got=$(seq_of)
    [ "$rc" = "$want_rc" ] && [ "$got" = "${want_seq//_/ } " ] \
      || fail "tag under '$sh', $fails failed creates, view ok from call $view_from: rc $rc, calls [$got], want rc $want_rc [${want_seq//_/ }]; log: $(tr '\n' ';' < "$tmp/calls")"
  done <<'TABLE'
0 0 0 create
1 0 0 create_sleep10_create
2 0 0 create_sleep10_create_sleep30_create
1 1 0 create
all 3 0 create_sleep10_create_sleep30_create
all 0 1 create_sleep10_create_sleep30_create
TABLE
  # Always failing: a message of the step's own after the last try (the step's
  # output is interleaved with the stand-ins' log, which prints nothing else).
  tagrun "$sh" all 0; ! grep -qE '^(gh|sleep) ' <<<"$(tail -1 "$tmp/calls")" \
    || fail "a tag step that gave up printed no message after its last try under '$sh': $(tr '\n' ';' < "$tmp/calls")"
done

echo "workflow pipes: OK"
