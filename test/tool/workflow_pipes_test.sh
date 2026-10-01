#!/usr/bin/env bash
# Three workflow steps that read a command's output, run as written (lifted out
# of the files, not copied) against stand-ins for git, xcrun and codesign, each
# under GitHub's default `bash -e` AND under `bash -eo pipefail`, including a
# large input whose answer is on the first line -- the shape that kills the
# writer with SIGPIPE (exit 141) when the reader stops early:
#
#   release.yml `scope` / "Decide whether this change ships" (id: diff)
#   - ship=true when some changed path matches none of ^(docs/|\.github/),
#     \.md$, ^\.git(ignore|attributes)$; else ship=false (no paths, or a
#     failing git diff); the same answer with or without pipefail, at any size;
#   ci.yml "Native iOS tests (simulator)"
#   - the destination is the UUID on the first `  iPhone` line of
#     `xcrun simctl list devices available`; never a UUID from another line;
#     no iPhone -> the step fails before xcodebuild;
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

# ---- 1 ship decision ---------------------------------------------------------
grep -A1 -- '- name: Decide whether this change ships' .github/workflows/release.yml | grep -qE '^ *id: diff$' \
  || fail "Decide whether this change ships is not step id diff"
step_run .github/workflows/release.yml "Decide whether this change ships" "$tmp/ship.sh"
# git: `diff --name-only HEAD^ HEAD` prints $PATHS (cat: dies of SIGPIPE like
# the real writer); GIT_RC != 0 -> git fails after printing nothing.
stub git '[ "$*" = "diff --name-only HEAD^ HEAD" ] || { echo "git stub: unexpected: $*" >&2; exit 2; }
[ "${GIT_RC:-0}" = 0 ] || { echo "fatal: bad revision HEAD^" >&2; exit "$GIT_RC"; }
cat "$PATHS"'
ship() { # <shell> <paths file> [GIT_RC] -> prints the ship= output
  : > "$tmp/gh_out"
  PATH="$tmp/bin:$PATH" PATHS=$2 GIT_RC=${3:-0} GITHUB_OUTPUT="$tmp/gh_out" $1 "$tmp/ship.sh" > "$tmp/out" 2>&1 \
    || fail "ship step exited $? under '$1'"
  cat "$tmp/gh_out"
}
while IFS='|' read -r want list; do
  tr ',' '\n' <<<"$list" | sed '/^$/d' > "$tmp/paths"
  for sh in "${SHELLS[@]}"; do
    got=$(ship "$sh" "$tmp/paths")
    [ "$got" = "ship=$want" ] || fail "paths [$list] under '$sh' gave [$got], want ship=$want"
  done
done <<'EOF'
false|
false|docs/DESIGN.md
false|.github/workflows/ci.yml,docs/a.png,README.md,lib/x/notes.md
false|.gitignore,.gitattributes
false|docs/a,.github/b,CHANGELOG.md,.gitignore
true|lib/main.dart
true|docs/x.md,pubspec.yaml
true|.github/dependabot.yml,supabase/migrations/1.sql
true|lib/docs/x.dart
true|sub/.gitignore
true|.gitignore.bak
true|README.mdx
true|.githubx/y
true|Docs/x
true|README.MD
true|x.md.orig
EOF
# A failing git diff ships nothing.
printf 'lib/main.dart\n' > "$tmp/paths"
for sh in "${SHELLS[@]}"; do
  [ "$(ship "$sh" "$tmp/paths" 128)" = ship=false ] || fail "a failing git diff shipped under '$sh'"
done
# Large: the shipping path first, then many that do not ship (or do).
{ echo lib/main.dart; for ((i = 0; i < BIG; i++)); do echo "docs/p$i.md"; done; } > "$tmp/big-first"
{ for ((i = 0; i < BIG; i++)); do echo "docs/p$i.md"; done; } > "$tmp/big-none"
{ for ((i = 0; i < BIG; i++)); do echo "lib/p$i.dart"; done; } > "$tmp/big-all"
for sh in "${SHELLS[@]}"; do
  [ "$(ship "$sh" "$tmp/big-first")" = ship=true ] || fail "$BIG paths, first shipping, under '$sh' gave [$(cat "$tmp/gh_out")] (SIGPIPE?)"
  [ "$(ship "$sh" "$tmp/big-all")" = ship=true ] || fail "$BIG shipping paths under '$sh' gave [$(cat "$tmp/gh_out")] (SIGPIPE?)"
  [ "$(ship "$sh" "$tmp/big-none")" = ship=false ] || fail "$BIG docs paths under '$sh' gave [$(cat "$tmp/gh_out")]"
done

# ---- 2 simulator UDID ----------------------------------------------------------
step_run .github/workflows/ci.yml "Native iOS tests (simulator)" "$tmp/udid.sh"
stub flutter ':'
stub xcrun '[ "$*" = "simctl list devices available" ] || { echo "xcrun stub: unexpected: $*" >&2; exit 2; }
cat "$DEVICES"'
# xcodebuild: records the exact -destination argument (a multi-line one too).
stub xcodebuild 'while [ $# -gt 0 ]; do [ "$1" = -destination ] && printf "%s" "$2" > "$XCB_ARGS"; shift; done'
udid() { # <shell> <devices file> -> prints the -destination given to xcodebuild; rc of the step
  rm -f "$tmp/xcb"
  local rc=0
  PATH="$tmp/bin:$PATH" DEVICES=$2 XCB_ARGS="$tmp/xcb" $1 "$tmp/udid.sh" > "$tmp/out" 2>&1 || rc=$?
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
# A real Runner.app always holds Flutter.framework (the loop has no nullglob).
sig() { # <shell> <app authority file> [<Flutter.framework authority file>, default distribution]; rc of the step
  rm -rf "$tmp/rt" "$tmp/cs"; mkdir -p "$tmp/rt/export" "$tmp/cs" "$tmp/pkg/Payload/Runner.app/Frameworks"
  rm -rf "$tmp/pkg/Payload/Runner.app/Frameworks/"*
  cp "$2" "$tmp/cs/Runner.app.dvv"
  mkdir "$tmp/pkg/Payload/Runner.app/Frameworks/Flutter.framework"; cp "${3:-$tmp/a-dist}" "$tmp/cs/Flutter.framework.dvv"
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
  sig "$sh" "$tmp/a-stderr" || fail "an authority printed on stderr was not read under '$sh'"
  sig "$sh" "$tmp/a-big" || fail "a distribution signature with $BIG more Authority lines failed under '$sh' (SIGPIPE?)"
  [ "$(grep -A1 -xF "Runner.app: $DIST" "$tmp/out" | tail -1)" = "  DR: identifier x" ] \
    || fail "large input: authority is not exactly the first line's under '$sh'"
  for bad in a-dev-first a-adhoc a-root-first a-prefixed a-nospace a-indented; do
    if sig "$sh" "$tmp/$bad"; then fail "app with $bad passed the signature check under '$sh'"; fi
    if sig "$sh" "$tmp/a-dist" "$tmp/$bad"; then fail "framework with $bad passed the signature check under '$sh'"; fi
  done
  sig "$sh" "$tmp/a-adhoc" || true
  grep -qxF "Runner.app: unsigned or ad-hoc" "$tmp/out" || fail "no Authority line is not reported as unsigned under '$sh'"
done

echo "workflow pipes: OK"
