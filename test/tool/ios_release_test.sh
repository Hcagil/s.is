#!/usr/bin/env bash
# The iPhone release path, checked on Linux: the shape of release.yml, ci.yml
# and the reusable .github/workflows/ios-ipa.yml, and the shell steps of
# ios-ipa.yml run as written (lifted out of the file, not copied) against
# stand-ins for codesign, plutil, xcodebuild, xcrun and flutter.
#
#   release.yml
#   - `scope` computes the version once: code = run_number + 100, name = the
#     pubspec version without any +build; outputs code and name;
#   - `publish` needs scope only, reads the version from scope and computes
#     none of its own; nothing ever needs `ios` (Play never waits on Apple);
#   - `ios` needs scope only, runs when shipping and when IOS_RELEASE is not
#     'off' (unset = on), calls ios-ipa.yml with the scope version and
#     upload: true;
#   ci.yml
#   - `ios-signed` calls the same workflow with upload: false, only for
#     same-repository, non-Dependabot pull requests with app changes;
#   ios-ipa.yml
#   - GoogleService-Info.plist is written from its secret; an empty secret
#     fails the step and writes nothing;
#   - the App Store Connect key goes to $RUNNER_TEMP/asc (dir 700, file 600
#     whatever the umask), is never printed, is found there by xcodebuild and
#     altool, and a last `if: always()` step removes it;
#   - Flutter only writes the Xcode config (build number and name passed);
#     xcodebuild archives and exports with automatic signing;
#   - the exported Runner.app must carry aps-environment = production:
#     development, a missing key, an unsigned app or no .ipa all fail;
#   - the upload runs only when inputs.upload, and only after that check;
#   ios/Runner/Info.plist declares ITSAppUsesNonExemptEncryption = false.
#
# What only a macOS runner shows: that Xcode really signs, that the export
# really rewrites aps-environment to production, that altool really uploads.
#
# A `run:` block with no `shell:` runs as `bash -e {0}`, so steps run that way.
set -euo pipefail
command -v python3 >/dev/null || { echo "FAIL: python3 is required (plutil stand-in)"; exit 1; }
command -v unzip >/dev/null || { echo "FAIL: unzip is required"; exit 1; }
cd "$(dirname "$0")/../.."
release=.github/workflows/release.yml
ci=.github/workflows/ci.yml
ipa_wf=.github/workflows/ios-ipa.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; [ ! -s "$tmp/out" ] || { echo "--- step output"; cat "$tmp/out"; }; exit 1; }

# ---- YAML helpers (indentation-based; the workflows use 2-space steps) ----
# job <file> <job>: the job's block, from `  <job>:` to the next job.
job() {
  awk -v j="  $2:" '
    $0 == j { f = 1; next }
    f && /^  [A-Za-z0-9_-]+:/ { exit }
    f && /^[^ #]/ { exit }
    f' "$1"
}
# key <block file> <key>: a 4-space job key; a folded `>-` value is joined.
key() {
  awk -v k="$2" '
    f && /^     / { sub(/^ +/, ""); v = v " " $0; next }
    f { exit }
    $0 ~ "^    " k ":" {
      v = $0; sub("^    " k ": *", "", v)
      if (v == ">-" || v == ">") { v = ""; f = 1; next }
      print v; done = 1; exit
    }
    END { if (f && !done) { sub(/^ /, "", v); print v } }' "$1"
}
# with <block file> <input>: a value under the job's `with:`.
with() {
  awk -v k="$2" '
    /^    with:/ { f = 1; next }
    f && !/^      / { exit }
    f && $0 ~ "^      " k ":" { v = $0; sub("^      " k ": *", "", v); print v; exit }' "$1"
}
# step_keys <file> <step name>: the step's lines before its run: block.
step_keys() {
  awk -v n="- name: $2" '
    index($0, n) && substr($0, index($0, n) + length(n)) == "" { f = 1; next }
    f && (/^ *run:/ || /^ *- /) { exit }
    f' "$1"
}
# step_run <file> <step name> <out>: the step's run block, de-indented;
# a one-line `run: cmd` too.
step_run() {
  awk -v n="- name: $2" '
    index($0, n) && substr($0, index($0, n) + length(n)) == "" { found = 1; next }
    found && !inrun && /^ *- / { exit }
    found && !inrun && /^ *run: \|/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
    found && !inrun && /^ *run: / { sub(/^ *run: /, ""); print; exit }
    inrun {
      if ($0 ~ /^ *$/) { print ""; next }
      match($0, /^ */)
      if (RLENGTH <= ind) exit
      if (!body) { body = RLENGTH }
      print substr($0, body + 1)
    }' "$1" > "$3"
  [ -s "$3" ] || fail "step '$2' not found in $1"
}
norm() { tr -s ' ' <<<"$1" | sed 's/^ //; s/ $//'; }

job "$release" scope > "$tmp/scope"
job "$release" publish > "$tmp/publish"
job "$release" ios > "$tmp/ios"
job "$ci" ios-signed > "$tmp/ios-signed"
for j in scope publish ios ios-signed; do [ -s "$tmp/$j" ] || fail "job $j not found"; done

# ---- release.yml -----------------------------------------------------------
# 1 scope owns the version: its outputs, and the numbers its step computes.
grep -qE '^      code: \$\{\{ steps\.v\.outputs\.code \}\}$' "$tmp/scope" || fail "scope does not output code from steps.v"
grep -qE '^      name: \$\{\{ steps\.v\.outputs\.name \}\}$' "$tmp/scope" || fail "scope does not output name from steps.v"
step_keys "$release" "Compute version" | grep -qE '^ *id: v$' || fail "Compute version is not step id v"
step_run "$release" "Compute version" "$tmp/version.sh"
sed -i 's/\${{ github\.run_number }}/77/g' "$tmp/version.sh"
grep -q '\${{' "$tmp/version.sh" && fail "Compute version reads an unexpected expression: $(cat "$tmp/version.sh")"
mkdir -p "$tmp/v"
for case in "0.30.0|0.30.0" "1.2.3+45|1.2.3"; do
  printf 'name: sis\nversion: %s\n' "${case%%|*}" > "$tmp/v/pubspec.yaml"
  : > "$tmp/v/out"
  (cd "$tmp/v" && GITHUB_OUTPUT="$tmp/v/out" bash -e "$tmp/version.sh") > "$tmp/out" 2>&1 || fail "Compute version failed"
  [ "$(sort "$tmp/v/out")" = "$(printf 'code=177\nname=%s' "${case#*|}")" ] \
    || fail "version ${case%%|*} at run 77 gave [$(tr '\n' ' ' < "$tmp/v/out")], want code=177 name=${case#*|}"
done

# 2 publish: needs scope only, uses scope's version, computes none itself.
[ "$(key "$tmp/publish" needs)" = scope ] || fail "publish must need exactly scope, got [$(key "$tmp/publish" needs)]"
grep -q 'run_number' "$tmp/publish" && fail "publish computes its own version (run_number)"
grep -qE 'pubspec\.yaml|steps\.v\.' "$tmp/publish" && fail "publish reads the version itself instead of from scope"
grep -q -- '--build-number=${{ needs.scope.outputs.code }} --build-name=${{ needs.scope.outputs.name }}' "$tmp/publish" \
  || fail "the AAB is not built with scope's code and name"
grep -q 'BUILD: ${{ needs.scope.outputs.code }}' "$tmp/publish" || fail "the note step does not use scope's code"
grep -q 'v${{ needs.scope.outputs.name }}+${{ needs.scope.outputs.code }}' "$tmp/publish" || fail "the release tag does not use scope's version"
# Nothing in the release waits on the iOS job.
if grep -nE '^    needs:.*\bios\b' "$release"; then fail "a release job needs ios: Play must never wait on Apple"; fi

# 3 ios: needs scope only; ships; IOS_RELEASE=off skips, unset runs.
[ "$(key "$tmp/ios" needs)" = scope ] || fail "ios must need exactly scope, got [$(key "$tmp/ios" needs)]"
[ "$(norm "$(key "$tmp/ios" if)")" = "needs.scope.outputs.ship == 'true' && vars.IOS_RELEASE != 'off'" ] \
  || fail "ios if is [$(key "$tmp/ios" if)]"
[ "$(key "$tmp/ios" uses)" = ./.github/workflows/ios-ipa.yml ] || fail "ios does not call ios-ipa.yml"
[ "$(with "$tmp/ios" upload)" = true ] || fail "the release ios job must upload"
[ "$(with "$tmp/ios" build-number)" = '${{ needs.scope.outputs.code }}' ] || fail "ios build number is not scope's code"
[ "$(with "$tmp/ios" build-name)" = '${{ needs.scope.outputs.name }}' ] || fail "ios build name is not scope's name"
[ "$(with "$tmp/ios" ref)" = '${{ github.event.workflow_run.head_sha }}' ] || fail "ios does not build the commit CI passed"
[ "$(key "$tmp/ios" secrets)" = inherit ] || fail "ios does not pass secrets: inherit"

# ---- ci.yml ----------------------------------------------------------------
# 4 ios-signed: pull requests from this repository, not Dependabot, app changes; no upload.
[ "$(key "$tmp/ios-signed" needs)" = changes ] || fail "ios-signed must need changes"
signed_if=$(norm "$(key "$tmp/ios-signed" if)")
for clause in "needs.changes.outputs.app == 'true'" "github.event_name == 'pull_request'" \
  "github.event.pull_request.head.repo.full_name == github.repository" "github.actor != 'dependabot[bot]'"; do
  [[ " $signed_if " == *" $clause "* ]] || fail "ios-signed if lacks [$clause]: [$signed_if]"
done
[[ "$signed_if" != *"||"* ]] || fail "ios-signed if must be a pure conjunction: [$signed_if]"
[ "$(key "$tmp/ios-signed" uses)" = ./.github/workflows/ios-ipa.yml ] || fail "ios-signed does not call ios-ipa.yml"
[ "$(with "$tmp/ios-signed" upload)" = false ] || fail "a pull request must never upload to TestFlight"
[ "$(key "$tmp/ios-signed" secrets)" = inherit ] || fail "ios-signed does not pass secrets: inherit"

# ---- ios-ipa.yml: shape ------------------------------------------------------
# 5 the call interface.
grep -q '^  workflow_call:$' "$ipa_wf" || fail "ios-ipa.yml is not a reusable workflow"
for input in ref build-number build-name upload; do
  awk -v i="      $input:" '$0 == i { f = 1; next } f && /^      [a-z]/ { exit } f' "$ipa_wf" > "$tmp/input"
  grep -q '^ *required: true$' "$tmp/input" || fail "input $input is not required"
done
awk '$0 == "      upload:" { f = 1; next } f && /^      [a-z]/ { exit } f' "$ipa_wf" | grep -q '^ *type: boolean$' \
  || fail "input upload is not a boolean (a string 'false' is truthy in if:)"
grep -qE '^    runs-on: macos-' "$ipa_wf" || fail "ios-ipa does not run on macOS"
step_keys "$ipa_wf" "Check out source" | grep -q 'ref: ${{ inputs.ref }}' || fail "checkout ignores inputs.ref"
# Secrets reach steps through env only: an inline ${{ secrets.* }} in a run
# block is pasted into the script text.
awk '/^ *run:/ { r = 1; match($0, /^ */); ind = RLENGTH; print; next }
     r { match($0, /^ */); if (RLENGTH > ind || $0 ~ /^ *$/) { print; next } r = 0 }' "$ipa_wf" \
  | grep -q 'secrets\.' && fail "a run block interpolates a secret"
grep -nE 'set -x|set -o xtrace|bash -x' "$ipa_wf" && fail "tracing would print the key"
# The key's value is read by its own step only.
[ "$(grep -c 'secrets.APP_STORE_CONNECT_API_KEY' "$ipa_wf")" -eq 1 ] || fail "the API key secret is read in more than one place"
step_keys "$ipa_wf" "Write the App Store Connect key" | grep -q 'KEY: ${{ secrets.APP_STORE_CONNECT_API_KEY }}' \
  || fail "the key step does not take the key from its secret"
# Step order, and the gates on upload and cleanup.
mapfile -t steps < <(sed -n 's/^      - name: //p' "$ipa_wf")
pos() { local i; for i in "${!steps[@]}"; do [ "${steps[$i]}" = "$1" ] && { echo "$i"; return; }; done; fail "no step '$1'"; }
[ "$(pos "Write the App Store Connect key")" -lt "$(pos "Archive (signed)")" ] || fail "the key is written after the archive"
[ "$(pos "Export for App Store Connect")" -lt "$(pos "Check the push entitlement")" ] || fail "entitlement checked before export"
[ "$(pos "Check the push entitlement")" -lt "$(pos "Upload to TestFlight")" ] || fail "the upload runs before the push entitlement check"
[ "${steps[-1]}" = "Remove the App Store Connect key" ] || fail "key removal is not the last step (last: ${steps[-1]})"
[ "$(step_keys "$ipa_wf" "Upload to TestFlight" | sed -n 's/^ *if: *//p')" = inputs.upload ] || fail "upload is not gated on inputs.upload"
[ "$(step_keys "$ipa_wf" "Remove the App Store Connect key" | sed -n 's/^ *if: *//p')" = 'always()' ] \
  || fail "key removal must run even after a failure (if: always())"
for s in "Check the push entitlement" "Write the App Store Connect key" "Restore Firebase config"; do
  step_keys "$ipa_wf" "$s" | grep -q 'continue-on-error' && fail "'$s' must not be continue-on-error"
done

# ---- ios-ipa.yml: the steps, run ---------------------------------------------
# Stand-ins, strict to the real CLI surface; a refused call is logged.
mkdir -p "$tmp/bin"
export STUB_REJECTS="$tmp/rejects" STUB_CALLS="$tmp/calls"
# codesign -d --entitlements :- PATH  -> entitlements as an XML plist on
#   stdout, "Executable=..." on stderr (real codesign). `--entitlements -`
#   without the ':' and without --xml prints the human "[Dict]" form, which
#   no plist parser reads. Unsigned app -> "code object is not signed at all",
#   exit 1. The stand-in reads the signed entitlements from
#   PATH/_CodeSignature/entitlements.plist (absent = unsigned).
cat > "$tmp/bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
die() { echo "codesign stub: $* (call: codesign $args)" >&2; echo "codesign $args" >> "$STUB_REJECTS"; exit 2; }
[ "${1:-}" = -d ] || die "only -d is expected"
shift; ent=; xml=; path=
while [ $# -gt 0 ]; do
  case "$1" in
    --entitlements) ent=${2:?}; shift 2 ;;
    --xml) xml=1; shift ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$path" ] || die "more than one path"; path=$1; shift ;;
  esac
done
[ "$ent" = :- ] || [ "$ent" = - ] || die "entitlements to a file, not stdout"
[ -e "$path" ] || { echo "$path: No such file or directory" >&2; exit 1; }
[ -d "$path" ] && [ -f "$path/Info.plist" ] || die "not an app bundle: $path"
sig="$path/_CodeSignature/entitlements.plist"
[ -f "$sig" ] || { echo "$path: code object is not signed at all" >&2; exit 1; }
echo "Executable=$path/Runner" >&2
if [ "$ent" = :- ]; then
  echo "Warning: Specifying ':' in the path is deprecated and will not work in a future release" >&2
  cat "$sig"
elif [ -n "$xml" ]; then cat "$sig"
else
  python3 -c 'import plistlib,sys
d=plistlib.load(open(sys.argv[1],"rb")); print("[Dict]")
for k,v in d.items(): print("\t[Key] %s\n\t[Value]\n\t\t[String] %s" % (k,v))' "$sig"
fi
EOF
# plutil -extract KEYPATH FORMAT [-expect TYPE] [-o PATH] FILE ('-' = stdin).
#   Without -o, real plutil rewrites FILE in place; the stand-in refuses that.
#   Missing key -> "Could not extract value", exit 1; unparseable -> exit 1.
#   raw prints a scalar's value.
cat > "$tmp/bin/plutil" <<'EOF'
#!/usr/bin/env python3
import plistlib, sys
args = sys.argv[1:]
def die(msg):
    print("plutil stub: %s (call: plutil %s)" % (msg, " ".join(args)), file=sys.stderr)
    open(__import__("os").environ["STUB_REJECTS"], "a").write("plutil %s\n" % " ".join(args))
    sys.exit(2)
if len(args) < 3 or args[0] != "-extract": die("only -extract is expected")
keypath, fmt, rest = args[1], args[2], args[3:]
if fmt not in ("xml1", "binary1", "json", "swift", "objc", "raw"): die("bad format " + fmt)
out = None; files = []
while rest:
    a = rest.pop(0)
    if a == "-o": out = rest.pop(0)
    elif a == "-expect": rest.pop(0)
    elif a.startswith("-") and a != "-": die("unknown flag " + a)
    else: files.append(a)
if len(files) != 1: die("one input file expected")
if out != "-": die("extract without -o - would rewrite the input")
name = "<stdin>" if files[0] == "-" else files[0]
data = sys.stdin.buffer.read() if files[0] == "-" else open(files[0], "rb").read()
try:
    v = plistlib.loads(data)
except Exception:
    print("%s: Property List error: Cannot parse a NULL or zero-length data / JSON error" % name, file=sys.stderr); sys.exit(1)
for part in keypath.split("."):
    if not isinstance(v, dict) or part not in v:
        print("%s: Could not extract value, error: No value at that key path or invalid key path: %s" % (name, keypath), file=sys.stderr); sys.exit(1)
    v = v[part]
if fmt != "raw": die("only raw is modelled")
if isinstance(v, (dict, list)): print("%s: Could not extract value: not a scalar" % name, file=sys.stderr); sys.exit(1)
print(str(v).lower() if isinstance(v, bool) else v)
EOF
# xcodebuild archive ... / -exportArchive ...: the flags these steps may use.
#   A missing -authenticationKeyPath file fails as real xcodebuild does; the
#   export reads ExportOptions.plist (an invalid plist fails) and writes
#   EXPORT/Runner.ipa, an app whose signed entitlements are $STUB_APS
#   (unset = key absent, "unsigned" = no signature).
cat > "$tmp/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
die() { echo "xcodebuild stub: $* (call: xcodebuild $args)" >&2; echo "xcodebuild $args" >> "$STUB_REJECTS"; exit 2; }
mode=; declare -A o=()
while [ $# -gt 0 ]; do
  case "$1" in
    archive) mode=archive; shift ;;
    -exportArchive) mode=export; shift ;;
    -quiet|-allowProvisioningUpdates) o[$1]=1; shift ;;
    -workspace|-scheme|-configuration|-destination|-archivePath|-exportPath|-exportOptionsPlist|-authenticationKeyPath|-authenticationKeyID|-authenticationKeyIssuerID)
      o[$1]=${2:?}; shift 2 ;;
    *) die "unexpected argument $1" ;;
  esac
done
for k in -allowProvisioningUpdates -authenticationKeyPath -authenticationKeyID -authenticationKeyIssuerID -archivePath; do
  [ -n "${o[$k]:-}" ] || die "missing $k"
done
[ -f "${o[-authenticationKeyPath]}" ] || { echo "error: authentication key file not found: ${o[-authenticationKeyPath]}" >&2; exit 70; }
echo "xcodebuild $mode" >> "$STUB_CALLS"
if [ "$mode" = archive ]; then
  [ "${o[-workspace]:-}" = ios/Runner.xcworkspace ] && [ "${o[-scheme]:-}" = Runner ] && [ "${o[-configuration]:-}" = Release ] \
    || die "archive of the wrong target"
  mkdir -p "${o[-archivePath]}"
else
  [ -d "${o[-archivePath]}" ] || { echo "error: archive not found at path '${o[-archivePath]}'" >&2; exit 70; }
  cp "${o[-exportOptionsPlist]:?}" "$STUB_EXPORT_OPTIONS"
  python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "${o[-exportOptionsPlist]}" 2>/dev/null \
    || { echo "error: exportOptionsPlist error" >&2; exit 70; }
  app=$(mktemp -d)/Payload/Runner.app; mkdir -p "$app"; : > "$app/Info.plist"
  if [ "${STUB_APS-}" != unsigned ]; then
    mkdir -p "$app/_CodeSignature"
    python3 -c 'import plistlib,sys
d={"application-identifier":"T.com.esd.sis"}
if sys.argv[2]: d["aps-environment"]=sys.argv[2]
plistlib.dump(d, open(sys.argv[1],"wb"))' "$app/_CodeSignature/entitlements.plist" "${STUB_APS-}"
  fi
  mkdir -p "${o[-exportPath]:?}"
  (cd "$app/../.." && python3 -c 'import os,zipfile,sys
z=zipfile.ZipFile(sys.argv[1],"w")
for r,_,fs in os.walk("Payload"):
  for f in fs: z.write(os.path.join(r,f))' "${o[-exportPath]}/Runner.ipa")
fi
EOF
# xcrun altool --upload-app --type ios --file IPA --apiKey ID --apiIssuer ISSUER
#   Real altool finds AuthKey_ID.p8 in ./private_keys, ~/private_keys,
#   ~/.private_keys, ~/.appstoreconnect/private_keys or $API_PRIVATE_KEYS_DIR.
cat > "$tmp/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
die() { echo "xcrun stub: $* (call: xcrun $args)" >&2; echo "xcrun $args" >> "$STUB_REJECTS"; exit 2; }
[ "${1:-}" = altool ] || die "only altool is expected"; shift
declare -A o=(); up=
while [ $# -gt 0 ]; do
  case "$1" in
    --upload-app) up=1; shift ;;
    --type|--file|--apiKey|--apiIssuer) o[$1]=${2:?}; shift 2 ;;
    *) die "unexpected argument $1" ;;
  esac
done
[ -n "$up" ] && [ "${o[--type]:-}" = ios ] || die "not an iOS upload"
[ -f "${o[--file]:-}" ] || { echo "*** Error: file not found: ${o[--file]:-}" >&2; exit 1; }
found=
for d in ./private_keys ~/private_keys ~/.private_keys ~/.appstoreconnect/private_keys ${API_PRIVATE_KEYS_DIR:-}; do
  [ -f "$d/AuthKey_${o[--apiKey]:?}.p8" ] && found=1
done
[ -n "$found" ] || { echo "*** Error: Could not find private key AuthKey_${o[--apiKey]}.p8" >&2; exit 1; }
[ -n "${o[--apiIssuer]:-}" ] || die "no issuer"
echo "altool upload ${o[--file]}" >> "$STUB_CALLS"
EOF
# flutter: records its arguments.
cat > "$tmp/bin/flutter" <<'EOF'
#!/usr/bin/env bash
echo "flutter $*" >> "$STUB_CALLS"
EOF
chmod +x "$tmp/bin"/*

key_text=$'-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgSECRETSECRET\nTAILLINEtailline\n-----END PRIVATE KEY-----'
# run <step name> [VAR=value ...]: the step's run block in a fresh-ish job
# env: $tmp/job is the checkout, $RUNNER_TEMP persists across steps, and
# GITHUB_ENV lines written by earlier steps are applied, as on a runner.
# Inline ${{ inputs.* }} / ${{ vars.* }} get fixed test values.
run() {
  local name=$1; shift
  step_run "$ipa_wf" "$name" "$tmp/step.sh"
  sed -i -e 's/\${{ inputs\.build-number }}/4242/g' -e 's/\${{ inputs\.build-name }}/9.8.7/g' \
    -e 's/\${{ vars\.\([A-Z_]*\) }}/var-\1/g' "$tmp/step.sh"
  ! grep -q '\${{' "$tmp/step.sh" || fail "step '$name' uses an expression this test does not model: $(grep '\${{' "$tmp/step.sh")"
  : > "$tmp/rejects"
  local rc=0
  (cd "$tmp/job" && umask 022 && set -a && . "$tmp/github_env" && set +a \
    && env PATH="$tmp/bin:$PATH" HOME="$tmp/home" RUNNER_TEMP="$tmp/rt" GITHUB_ENV="$tmp/github_env" \
      KEY_ID=K3YID ISSUER_ID=issuer-uuid TEAM_ID=TEAM123 STUB_EXPORT_OPTIONS="$tmp/export-options.plist" "$@" \
      bash -e "$tmp/step.sh") > "$tmp/out" 2>&1 || rc=$?
  [ ! -s "$tmp/rejects" ] || fail "step '$name' called a tool in a way the real CLI refuses: $(cat "$tmp/rejects")"
  return $rc
}
fresh() { rm -rf "$tmp/job" "$tmp/rt" "$tmp/home"; mkdir -p "$tmp/job/ios/Runner" "$tmp/rt" "$tmp/home"; : > "$tmp/github_env"; : > "$tmp/calls"; }
leaked() { grep -qE 'SECRETSECRET|TAILLINE|BEGIN PRIVATE KEY' "$tmp/out"; }

# 6 Firebase config: written verbatim; an empty secret fails and writes nothing.
fresh
plist=$'<?xml version="1.0"?>\n<plist><dict><key>GOOGLE_APP_ID</key><string>1:2:ios:3</string></dict></plist>'
run "Restore Firebase config" GOOGLE_SERVICE_INFO_PLIST="$plist" || fail "Firebase config step failed"
[ "$(cat "$tmp/job/ios/Runner/GoogleService-Info.plist")" = "$plist" ] || fail "GoogleService-Info.plist is not the secret"
fresh
if run "Restore Firebase config" GOOGLE_SERVICE_INFO_PLIST=; then fail "an empty GOOGLE_SERVICE_INFO_PLIST did not fail"; fi
[ ! -e "$tmp/job/ios/Runner/GoogleService-Info.plist" ] || fail "an empty plist was written"

# 7 the key: 700/600 under umask 022, exact content, never printed, path in GITHUB_ENV.
fresh
run "Write the App Store Connect key" KEY="$key_text" || fail "key step failed"
kf="$tmp/rt/asc/AuthKey_K3YID.p8"
[ -f "$kf" ] || fail "no key at \$RUNNER_TEMP/asc/AuthKey_\$KEY_ID.p8"
[ "$(stat -c %a "$kf")" = 600 ] || fail "key file mode $(stat -c %a "$kf"), want 600"
[ "$(stat -c %a "$tmp/rt/asc")" = 700 ] || fail "key dir mode $(stat -c %a "$tmp/rt/asc"), want 700"
[ "$(cat "$kf")" = "$key_text" ] || fail "key file content differs from the secret"
leaked && fail "the key step printed the key"
grep -qx "API_PRIVATE_KEYS_DIR=$tmp/rt/asc" "$tmp/github_env" || fail "API_PRIVATE_KEYS_DIR not exported: [$(cat "$tmp/github_env")]"
for empty in KEY KEY_ID ISSUER_ID TEAM_ID; do
  fresh
  if run "Write the App Store Connect key" KEY="$key_text" "$empty="; then fail "an empty $empty did not fail the key step"; fi
  [ -z "$(ls -A "$tmp/rt")" ] || fail "a key was written with $empty empty"
done

# 8 the build, run in order: config, archive with the key, export with automatic signing.
fresh
run "Write the App Store Connect key" KEY="$key_text" || fail "key step failed"
run "Configure the Xcode build" || fail "configure step failed"
grep -q '^flutter build ios ' "$tmp/calls" || fail "flutter does not build ios"
for f in --config-only --release --no-codesign --build-number=4242 --build-name=9.8.7; do
  grep -q -- " $f\( \|$\)" "$tmp/calls" || fail "flutter build lacks $f: $(cat "$tmp/calls")"
done
grep -q 'build ipa' "$tmp/calls" && fail "flutter build ipa cannot pass the API key"
run "Archive (signed)" || fail "archive failed with the key the key step wrote"
run "Export for App Store Connect" STUB_APS=production || fail "export failed"
python3 - "$tmp/export-options.plist" <<'EOF' || fail "ExportOptions.plist is wrong"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
want = {"method": "app-store-connect", "signingStyle": "automatic", "teamID": "TEAM123"}
bad = {k: d.get(k) for k in want if d.get(k) != want[k]}
if bad: print("ExportOptions:", bad, file=sys.stderr); sys.exit(1)
EOF
[ "$(cat "$tmp/calls" | grep -c '^xcodebuild')" -eq 2 ] || fail "want one archive and one export"
# Without the key the archive fails (the key path is the one the key step writes).
rm -rf "$tmp/rt/asc"
if run "Archive (signed)"; then fail "archive ran without the API key"; fi

# 9 the push entitlement: production passes; everything else fails.
ent() { # <STUB_APS value or 'unset'> -> step exit status
  fresh
  run "Write the App Store Connect key" KEY="$key_text" >/dev/null || fail "key step failed"
  run "Archive (signed)" || fail "archive failed"
  if [ "$1" = unset ]; then run "Export for App Store Connect" || fail "export failed"
  else run "Export for App Store Connect" STUB_APS="$1" || fail "export failed"; fi
  run "Check the push entitlement"
}
ent production || fail "a production-signed app failed the push check"
grep -qx 'aps-environment: production' "$tmp/out" || fail "the check does not report the value"
for bad in development unset unsigned; do
  if ent "$bad"; then fail "aps-environment '$bad' passed the push check"; fi
done
fresh
if run "Check the push entitlement"; then fail "the push check passed with no exported .ipa"; fi

# 10 upload: finds the key through GITHUB_ENV, uploads the exported .ipa; the key is then removed.
ent production || fail "push check failed"
run "Upload to TestFlight" || fail "upload failed"
grep -qx "altool upload $tmp/rt/export/Runner.ipa" "$tmp/calls" || fail "the exported .ipa was not uploaded: $(cat "$tmp/calls")"
leaked && fail "the upload printed the key"
run "Remove the App Store Connect key" || fail "key removal failed"
[ ! -e "$tmp/rt/asc" ] || fail "the key directory survived removal"
# Removal is safe when the key step never ran (always() runs it after an early failure).
fresh
run "Remove the App Store Connect key" || fail "key removal failed when there was no key"

# ---- Info.plist --------------------------------------------------------------
# 11 export compliance answered in the app: no manual question per TestFlight build.
python3 -c 'import plistlib,sys; sys.exit(0 if plistlib.load(open("ios/Runner/Info.plist","rb")).get("ITSAppUsesNonExemptEncryption") is False else 1)' \
  || fail "Info.plist must declare ITSAppUsesNonExemptEncryption = false"

echo "ios_release_test: OK"
