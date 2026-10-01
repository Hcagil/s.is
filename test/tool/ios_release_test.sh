#!/usr/bin/env bash
# The iPhone release path, checked on Linux: the shape of release.yml, ci.yml
# and the reusable .github/workflows/ios-ipa.yml, and the shell steps of
# ios-ipa.yml run as written (lifted out of the file, not copied), in the
# file's order with GitHub's if: gates, against stand-ins for codesign,
# security, xcodebuild, xcrun altool, plutil, curl, openssl, flutter and
# tool/asc_signing.py (test/tool/ios_release_stubs.py).
#
#   release.yml
#   - `scope` computes the version once: code = run_number + 100, name = the
#     pubspec version without any +build; outputs code and name;
#   - `publish` needs scope only, reads the version from scope and computes
#     none of its own; only `distribute` needs `ios` (Play never waits on
#     Apple), and nothing needs `distribute`;
#   - `distribute` needs scope, ios and publish, runs whenever ios succeeded
#     and the run is not cancelled (a failed publish does not stop it), on
#     ubuntu-24.04 with contents: read and an unpersisted checkout, sees only
#     the three App Store Connect secrets, writes the key 700/600 under
#     $RUNNER_TEMP/asc and removes it if: always(); it runs
#     `tool/asc_signing.py distribute com.esd.sis BUILD GROUPS NOTE` with the
#     groups from vars.TESTFLIGHT_GROUPS through env (empty = bacanaks) and the
#     note decoded from publish's note_b64, byte for byte;
#   - `ios` needs scope only, runs when shipping and when IOS_RELEASE is not
#     'off' (unset = on), calls ios-ipa.yml with the scope version and
#     upload: true;
#   ci.yml
#   - `ios-signed` calls the same workflow with upload: false, only for
#     same-repository pull requests with app changes not opened by Dependabot
#     (pull_request.user.login, not github.actor: a human re-run of a
#     Dependabot PR must still skip);
#   both callers pass exactly the five declared secrets by name, and no
#   workflow uses `secrets: inherit`;
#   ios-ipa.yml
#   - runs on macos-26 (Xcode 26); declares exactly those five secrets, all
#     required;
#   - checkout does not persist the token; no ${{ inputs|vars|secrets }} is
#     pasted into any run: text (they reach steps through env:);
#   - the steps, exactly in this order: checkout, Flutter, Firebase config,
#     pub get, config-only build, the key, the archive, the ad-hoc signature,
#     the certificate, the export, the explicit requirement, the signature
#     check, the push check, validate, upload, revoke, key removal;
#   - GoogleService-Info.plist is written from its secret; an empty secret
#     fails the step and writes nothing;
#   - the App Store Connect key goes to $RUNNER_TEMP/asc (dir 700, file 600
#     whatever the umask) after the config-only build and before the
#     certificate step, is never printed, and a last `if: always()` step
#     removes it;
#   - the archive is unsigned (no -allowProvisioningUpdates or API key flags),
#     one archive and one export; the app is then signed ad-hoc with
#     Runner.entitlements so the export keeps the push entitlement;
#   - the certificate step makes a key, has tool/asc_signing.py create a
#     distribution certificate and an App Store profile for com.esd.sis under
#     a name unique to the run attempt, fetches the intermediate, builds a
#     temporary keychain codesign can use, installs the profile, and puts
#     SIGNING_IDENTITY (SHA-1), SIGNING_PROFILE_UUID, SIGNING_CERTIFICATE_ID
#     and SIGNING_PROFILE_ID in GITHUB_ENV; the intermediate is fetched from
#     Apple's fixed https URL (not the http-only AIA URL) and must really have
#     issued the certificate (openssl verify, Apple's critical extensions
#     tolerated), or the step fails saying so;
#   - the export is manual: that SHA-1, that profile UUID for com.esd.sis;
#   - every framework, then the app, is re-signed with a designated
#     requirement on identifier and team: the one Xcode writes names the
#     certificate's common name in NFD and never matches this team's
#     certificate; the check then wants Apple Distribution on every code object
#     and a clean `codesign --verify --deep --strict`;
#   - the exported Runner.app must carry aps-environment = production;
#   - validate runs only on a pull request (!inputs.upload), upload only on a
#     release (inputs.upload), both after every check;
#   - `if: always()` revoke deletes the certificate and profile (`-` for one
#     never made, nothing when the key never existed), the keychain and the
#     profiles, after any failure too; a failed revoke still removes the
#     keychain and profiles, then fails the step;
#   ios/Runner/Info.plist declares ITSAppUsesNonExemptEncryption = false.
#
# What only a macOS runner shows: that Xcode and codesign really sign, that
# the export really sets aps-environment to production, that Apple accepts
# the signature (altool --validate-app on every pull request), that the API
# calls work against Apple (tool/asc_signing.py; its request shapes are
# checked in test/tool/asc_signing_test.py against a fake server).
#
# A `run:` block with no `shell:` runs as `bash -e {0}`, so steps run that way.
set -euo pipefail
# pipefail: never pipe into a reader that stops early (grep -q, head, awk exit;
# gawk stops, mawk drains): the writer can die of SIGPIPE (141). grep -q <<<"$(...)".
command -v python3 >/dev/null || { echo "FAIL: python3 is required (the stand-ins)"; exit 1; }
command -v zip >/dev/null || { echo "FAIL: zip is required"; exit 1; }
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
# passed_secrets <block file>: the job's `secrets:` map, sorted.
passed_secrets() {
  awk '/^    secrets:/ { f = 1; next } f && !/^      / { exit } f { sub(/^ +/, ""); print }' "$1" | sort
}
SECRETS=(APP_STORE_CONNECT_API_KEY APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APPLE_TEAM_ID GOOGLE_SERVICE_INFO_PLIST)
want_passed=$(for n in "${SECRETS[@]}"; do echo "$n: \${{ secrets.$n }}"; done | sort)
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
job "$release" distribute > "$tmp/distribute"
job "$ci" ios-signed > "$tmp/ios-signed"
for j in scope publish ios distribute ios-signed; do [ -s "$tmp/$j" ] || fail "job $j not found"; done

# ---- release.yml -----------------------------------------------------------
# 1 scope owns the version: its outputs, and the numbers its step computes.
grep -qE '^      code: \$\{\{ steps\.v\.outputs\.code \}\}$' "$tmp/scope" || fail "scope does not output code from steps.v"
grep -qE '^      name: \$\{\{ steps\.v\.outputs\.name \}\}$' "$tmp/scope" || fail "scope does not output name from steps.v"
grep -qE '^ *id: v$' <<<"$(step_keys "$release" "Compute version")" || fail "Compute version is not step id v"
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
# Only distribute waits on the iOS job; nothing waits on distribute.
for j in $(sed -n 's/^  \([A-Za-z0-9_-]*\):$/\1/p' "$release"); do
  [ "$j" = distribute ] && continue
  needs=$(job "$release" "$j" | awk '/^    needs:/ && !n++')
  if grep -qE '\bios\b' <<<"$needs"; then fail "job $j needs ios: Play must never wait on Apple ($needs)"; fi
  if grep -qE '\bdistribute\b' <<<"$needs"; then fail "job $j needs distribute: nothing may wait on TestFlight groups ($needs)"; fi
done

# 3 ios: needs scope only; ships; IOS_RELEASE=off skips, unset runs.
[ "$(key "$tmp/ios" needs)" = scope ] || fail "ios must need exactly scope, got [$(key "$tmp/ios" needs)]"
[ "$(norm "$(key "$tmp/ios" if)")" = "needs.scope.outputs.ship == 'true' && vars.IOS_RELEASE != 'off'" ] \
  || fail "ios if is [$(key "$tmp/ios" if)]"
[ "$(key "$tmp/ios" uses)" = ./.github/workflows/ios-ipa.yml ] || fail "ios does not call ios-ipa.yml"
[ "$(with "$tmp/ios" upload)" = true ] || fail "the release ios job must upload"
[ "$(with "$tmp/ios" build-number)" = '${{ needs.scope.outputs.code }}' ] || fail "ios build number is not scope's code"
[ "$(with "$tmp/ios" build-name)" = '${{ needs.scope.outputs.name }}' ] || fail "ios build name is not scope's name"
[ "$(with "$tmp/ios" ref)" = '${{ github.event.workflow_run.head_sha }}' ] || fail "ios does not build the commit CI passed"
[ "$(passed_secrets "$tmp/ios")" = "$want_passed" ] || fail "ios must pass exactly the five secrets by name, got [$(passed_secrets "$tmp/ios")]"

# 3b distribute: shape. It waits for publish only for the note.
dneeds=$(key "$tmp/distribute" needs | tr -d '[] ' | tr , '\n' | sort | paste -sd,)
[ "$dneeds" = ios,publish,scope ] || fail "distribute must need exactly scope, ios and publish, got [$(key "$tmp/distribute" needs)]"
[ "$(norm "$(key "$tmp/distribute" if | sed 's/^\${{ *//; s/ *}}$//')")" = "!cancelled() && needs.ios.result == 'success'" ] \
  || fail "distribute if is [$(key "$tmp/distribute" if)]: run after a successful ios, even when publish failed, never after a cancel"
[ "$(key "$tmp/distribute" runs-on)" = ubuntu-24.04 ] || fail "distribute must run on ubuntu-24.04 (polling on macOS bills minutes)"
[ "$(awk '/^    permissions:/ { f = 1; next } f && !/^      / { exit } f { sub(/^ +/, ""); print }' "$tmp/distribute")" = "contents: read" ] \
  || fail "distribute permissions must be exactly contents: read"
grep -qE '^ *persist-credentials: false$' "$tmp/distribute" || fail "distribute checkout must not persist the token"
dsecrets=$(grep -oE 'secrets\.[A-Z_]+' "$tmp/distribute" | sort -u | paste -sd,)
[ "$dsecrets" = secrets.APP_STORE_CONNECT_API_KEY,secrets.APP_STORE_CONNECT_ISSUER_ID,secrets.APP_STORE_CONNECT_KEY_ID ] \
  || fail "distribute must see exactly the three App Store Connect secrets, got [$dsecrets]"
[ "$(grep -c 'secrets.APP_STORE_CONNECT_API_KEY' "$tmp/distribute")" -eq 1 ] || fail "distribute reads the API key secret more than once"
awk '/^ *run:/ { r = 1; match($0, /^ */); ind = RLENGTH; print; next }
     r { match($0, /^ */); if (RLENGTH > ind || $0 ~ /^ *$/) { print; next } r = 0 }' "$tmp/distribute" > "$tmp/druntext"
grep -n '\${{' "$tmp/druntext" && fail "a distribute run block pastes an expression into its script"
grep -qE '^ *TF_GROUPS: \$\{\{ vars\.TESTFLIGHT_GROUPS \}\}$' "$tmp/distribute" || fail "groups must come from vars.TESTFLIGHT_GROUPS via env TF_GROUPS"
grep -qE '^ *NOTE_B64: \$\{\{ needs\.publish\.outputs\.note_b64 \}\}$' "$tmp/distribute" || fail "the note must come from publish's note_b64"
grep -qE '^ *BUILD: \$\{\{ needs\.scope\.outputs\.code \}\}$' "$tmp/distribute" || fail "the build number must be scope's code"
mapfile -t dsteps < <(sed -n 's/^      - name: //p' "$tmp/distribute")
[ "${dsteps[-1]}" = "Remove the App Store Connect key" ] || fail "key removal is not distribute's last step: ${dsteps[*]}"
dgate() { awk -v n="      - name: $1" '$0 == n { f = 1; next } f && (/^ *run:/ || /^ *- /) { exit } f' "$tmp/distribute" | sed -n 's/^ *if: *//p'; }
[ "$(dgate "Remove the App Store Connect key")" = 'always()' ] || fail "distribute key removal must be if: always()"
for s in "${dsteps[@]}"; do
  [ "$s" = "Remove the App Store Connect key" ] || [ -z "$(dgate "$s")" ] || fail "distribute step '$s' is gated [$(dgate "$s")]"
done
if grep -n 'set -x\|xtrace' "$tmp/distribute"; then fail "tracing would print the key"; fi

# ---- ci.yml ----------------------------------------------------------------
# 4 ios-signed: pull requests from this repository, not Dependabot, app changes; no upload.
[ "$(key "$tmp/ios-signed" needs)" = changes ] || fail "ios-signed must need changes"
signed_if=$(norm "$(key "$tmp/ios-signed" if)")
for clause in "needs.changes.outputs.app == 'true'" "github.event_name == 'pull_request'" \
  "github.event.pull_request.head.repo.full_name == github.repository" "github.event.pull_request.user.login != 'dependabot[bot]'"; do
  [[ " $signed_if " == *" $clause "* ]] || fail "ios-signed if lacks [$clause]: [$signed_if]"
done
[[ "$signed_if" != *"github.actor"* ]] || fail "ios-signed if must not use github.actor (a re-run by a human is not Dependabot): [$signed_if]"
[[ "$signed_if" != *"||"* ]] || fail "ios-signed if must be a pure conjunction: [$signed_if]"
[ "$(key "$tmp/ios-signed" uses)" = ./.github/workflows/ios-ipa.yml ] || fail "ios-signed does not call ios-ipa.yml"
[ "$(with "$tmp/ios-signed" upload)" = false ] || fail "a pull request must never upload to TestFlight"
[ "$(passed_secrets "$tmp/ios-signed")" = "$want_passed" ] || fail "ios-signed must pass exactly the five secrets by name, got [$(passed_secrets "$tmp/ios-signed")]"
if grep -nE 'secrets: *inherit' .github/workflows/*.yml; then fail "secrets: inherit hands every repository secret to the callee"; fi

# ---- ios-ipa.yml: shape ------------------------------------------------------
# 5 the call interface.
grep -q '^  workflow_call:$' "$ipa_wf" || fail "ios-ipa.yml is not a reusable workflow"
for input in ref build-number build-name upload; do
  awk -v i="      $input:" '$0 == i { f = 1; next } f && /^      [a-z]/ { exit } f' "$ipa_wf" > "$tmp/input"
  grep -q '^ *required: true$' "$tmp/input" || fail "input $input is not required"
done
grep -q '^ *type: boolean$' <<<"$(awk '$0 == "      upload:" { f = 1; next } f && /^      [a-z]/ { exit } f' "$ipa_wf")" \
  || fail "input upload is not a boolean (a string 'false' is truthy in if:)"
# Exactly the five secrets are declared, each required.
declared=$(awk '/^    secrets:$/ { f = 1; next } f && /^    [^ ]/ { exit } f && /^      [A-Z_]+:$/ { sub(/^ +/, ""); sub(/:$/, ""); print }' "$ipa_wf" | sort)
[ "$declared" = "$(printf '%s\n' "${SECRETS[@]}" | sort)" ] || fail "ios-ipa.yml must declare exactly the five secrets, got [$declared]"
for n in "${SECRETS[@]}"; do
  grep -q '^ *required: true$' <<<"$(awk -v i="      $n:" '$0 == i { f = 1; next } f && /^ {0,6}[A-Za-z]/ { exit } f' "$ipa_wf")" \
    || fail "secret $n is not required"
done
grep -qE "^    runs-on: macos-26$" "$ipa_wf" || fail "ios-ipa must run on macos-26 (Xcode 26: App Store Connect refuses older SDKs)"
grep -q 'ref: ${{ inputs.ref }}' <<<"$(step_keys "$ipa_wf" "Check out source")" || fail "checkout ignores inputs.ref"
grep -qE '^ *persist-credentials: false$' <<<"$(step_keys "$ipa_wf" "Check out source")" \
  || fail "checkout must not persist the token into .git/config (persist-credentials: false)"
# Secrets reach steps through env only: an inline ${{ secrets.* }} in a run
# block is pasted into the script text.
awk '/^ *run:/ { r = 1; match($0, /^ */); ind = RLENGTH; print; next }
     r { match($0, /^ */); if (RLENGTH > ind || $0 ~ /^ *$/) { print; next } r = 0 }' "$ipa_wf" \
  > "$tmp/runtext"
grep -q 'secrets\.' "$tmp/runtext" && fail "a run block interpolates a secret"
# Nor inputs or vars: a value pasted into script text is code, not data.
grep -nE '\$\{\{ *(inputs|vars|secrets)\.' "$tmp/runtext" && fail "a run block interpolates an inputs/vars/secrets expression"
grep -nE 'set -x|set -o xtrace|bash -x' "$ipa_wf" && fail "tracing would print the key"
# The key's value is read by its own step only.
[ "$(grep -c 'secrets.APP_STORE_CONNECT_API_KEY' "$ipa_wf")" -eq 1 ] || fail "the API key secret is read in more than one place"
grep -q 'KEY: ${{ secrets.APP_STORE_CONNECT_API_KEY }}' <<<"$(step_keys "$ipa_wf" "Write the App Store Connect key")" \
  || fail "the key step does not take the key from its secret"
# Step order, exactly the contract's; the gates on validate, upload and cleanup.
mapfile -t steps < <(sed -n 's/^      - name: //p' "$ipa_wf")
want_steps=("Check out source" "Install Flutter" "Restore Firebase config" "Resolve dependencies"
  "Configure the Xcode build" "Write the App Store Connect key" "Archive (signed)"
  "Sign the archive with its entitlements" "Create the signing certificate" "Export for App Store Connect"
  "Sign with an explicit requirement" "Check the signature" "Check the push entitlement"
  "Validate with App Store Connect" "Upload to TestFlight" "Revoke the signing certificate"
  "Remove the App Store Connect key")
[ "$(printf '%s\n' "${steps[@]}")" = "$(printf '%s\n' "${want_steps[@]}")" ] \
  || fail "ios-ipa.yml steps are not in the contract order:$(printf '\n  %s' "${steps[@]}")"
pos() { local i; for i in "${!steps[@]}"; do [ "${steps[$i]}" = "$1" ] && { echo "$i"; return; }; done; fail "no step '$1'"; }
# The key is on disk only from after the config-only build: not during
# checkout, pub get or configure; and before the certificate step needs it.
for s in "Check out source" "Resolve dependencies" "Configure the Xcode build"; do
  [ "$(pos "$s")" -lt "$(pos "Write the App Store Connect key")" ] || fail "the key is on disk during '$s'"
done
[ "$(pos "Write the App Store Connect key")" -lt "$(pos "Create the signing certificate")" ] || fail "the certificate step runs before the key exists"
gate() { step_keys "$ipa_wf" "$1" | sed -n 's/^ *if: *//p' | sed 's/^\${{ *//; s/ *}}$//'; }
[ "$(gate "Upload to TestFlight")" = inputs.upload ] || fail "upload is not gated on inputs.upload: [$(gate "Upload to TestFlight")]"
[ "$(gate "Validate with App Store Connect")" = '!inputs.upload' ] || fail "validate must run only when not uploading: [$(gate "Validate with App Store Connect")]"
[ "$(gate "Revoke the signing certificate")" = 'always()' ] || fail "revoke must run even after a failure (if: always())"
[ "$(gate "Remove the App Store Connect key")" = 'always()' ] || fail "key removal must run even after a failure (if: always())"
[ "${steps[-1]}" = "Remove the App Store Connect key" ] || fail "key removal is not the last step (last: ${steps[-1]})"
for s in "${want_steps[@]}"; do
  case "$s" in "Upload to TestFlight"|"Validate with App Store Connect"|"Revoke the signing certificate"|"Remove the App Store Connect key") continue ;; esac
  [ -z "$(gate "$s")" ] || fail "'$s' is gated [$(gate "$s")]: every other step must run on every call"
done
for s in "${want_steps[@]}"; do
  grep -q 'continue-on-error' <<<"$(step_keys "$ipa_wf" "$s")" && fail "'$s' must not be continue-on-error"
done

# ---- ios-ipa.yml: the steps, run ---------------------------------------------
# Stand-ins, strict to the real CLI surfaces (test/tool/ios_release_stubs.py):
# codesign, security, xcodebuild, xcrun altool, plutil, curl, and openssl
# (the real one, refusing what LibreSSL lacks). tool/asc_signing.py is stood
# in for too (its own test is test/tool/asc_signing_test.py): it checks the
# CSR and the key, and returns a certificate for the CSR's key issued by a test
# intermediate, for a team whose name has non-ASCII letters, and a profile.
REAL_OPENSSL=$(command -v openssl) || fail "openssl is required"
export REAL_OPENSSL STUB_REJECTS="$tmp/rejects" STUB_CALLS="$tmp/calls" STUB_ROOT_CN="Test Apple Root CA" STUB_TEAM=TEAM123
mkdir -p "$tmp/bin" "$tmp/ca"
stubs="$PWD/test/tool/ios_release_stubs.py"
for t in codesign security xcodebuild xcrun plutil curl openssl; do ln -s "$stubs" "$tmp/bin/$t"; done
cat > "$tmp/bin/flutter" <<'EOF'
#!/usr/bin/env bash
echo "flutter $*" >> "$STUB_CALLS"
EOF
chmod +x "$tmp/bin/flutter"
# A root (the system trusts it; never imported) and the intermediate that
# issues the certificate; the intermediate is served at the certificate's AIA URL.
"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/ca/root.key" -out "$tmp/ca/root.pem" \
  -subj "/CN=$STUB_ROOT_CN" -days 2 2>/dev/null
"$REAL_OPENSSL" req -new -newkey rsa:2048 -nodes -keyout "$tmp/ca/inter.key" -out "$tmp/ca/inter.csr" -subj "/CN=Test WWDR G3" 2>/dev/null
"$REAL_OPENSSL" req -x509 -in "$tmp/ca/inter.csr" -CA "$tmp/ca/root.pem" -CAkey "$tmp/ca/root.key" -days 2 \
  -addext basicConstraints=critical,CA:true -outform der -out "$tmp/ca/inter.cer" 2>/dev/null
wwdr_url=https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
export STUB_CA="$tmp/ca" STUB_URLS="{\"$wwdr_url\": \"$tmp/ca/inter.cer\"}"
# Only Apple's fixed https URL is served: the certificate's AIA URL
# (certs.apple.com, http only) is a 404 and curl refuses plain http
# (test/tool/ios_release_stubs.py). An impostor: same name, same root, another
# key; only a real signature check tells it from the intermediate.
"$REAL_OPENSSL" req -new -newkey rsa:2048 -nodes -keyout "$tmp/ca/fake.key" -out "$tmp/ca/fake.csr" -subj "/CN=Test WWDR G3" 2>/dev/null
"$REAL_OPENSSL" req -x509 -in "$tmp/ca/fake.csr" -CA "$tmp/ca/root.pem" -CAkey "$tmp/ca/root.key" -days 2 \
  -addext basicConstraints=critical,CA:true -outform der -out "$tmp/ca/fake.cer" 2>/dev/null

key_text=$'-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgSECRETSECRET\nTAILLINEtailline\n-----END PRIVATE KEY-----'
# run <step name> [VAR=value ...]: the step's run block in a fresh-ish job
# env: $tmp/job is the checkout, $RUNNER_TEMP persists across steps, and
# GITHUB_ENV lines written by earlier steps are applied, as on a runner.
# The step's own env: is applied, as on a runner, with fixed test values for
# ${{ inputs.* }} / ${{ vars.* }}; ${{ secrets.* }} entries are left to the
# caller's VAR=value arguments. Run text must hold no expression at all.
run() {
  local name=$1 wf=${RUN_WF:-$ipa_wf}; shift
  step_run "$wf" "$name" "$tmp/step.sh"
  ! grep -q '\${{' "$tmp/step.sh" || fail "step '$name' pastes an expression into its script: $(grep '\${{' "$tmp/step.sh")"
  local -a senv=()
  mapfile -t senv < <(step_keys "$wf" "$name" | awk '
    /^ *env:$/ { match($0, /^ */); ind = RLENGTH; f = 1; next }
    f { match($0, /^ */); if (RLENGTH <= ind) exit; sub(/^ +/, ""); print }' \
    | grep -v ': \${{ secrets\.' | grep -v ': \${{ needs\.\|: \${{ vars\.TESTFLIGHT_GROUPS }}$' \
    | sed -e 's/: \${{ inputs\.build-number }}$/: 4242/' -e 's/: \${{ inputs\.build-name }}$/: 9.8.7/' \
      -e 's/: \${{ vars\.\([A-Z_]*\) }}$/: var-\1/' -e 's/^\([A-Z_]*\): /\1=/')
  local e; for e in "${senv[@]}"; do [[ "$e" != *'${{'* ]] || fail "step '$name' env uses an expression this test does not model: $e"; done
  : > "$tmp/rejects"
  local rc=0
  (cd "$tmp/job" && umask 022 && set -a && . "$tmp/github_env" && set +a \
    && env PATH="$tmp/bin:$PATH" HOME="$tmp/home" RUNNER_TEMP="$tmp/rt" GITHUB_ENV="$tmp/github_env" \
      GITHUB_RUN_ID=5150 GITHUB_RUN_ATTEMPT=2 \
      KEY_ID=K3YID ISSUER_ID=issuer-uuid TEAM_ID=TEAM123 STUB_EXPORT_OPTIONS="$tmp/export-options.plist" ${senv[@]+"${senv[@]}"} "$@" \
      bash -e "$tmp/step.sh") > "$tmp/out" 2>&1 || rc=$?
  [ ! -s "$tmp/rejects" ] || fail "step '$name' called a tool in a way the real CLI refuses: $(cat "$tmp/rejects")"
  return $rc
}
fresh() {
  rm -rf "$tmp/job" "$tmp/rt" "$tmp/home"
  mkdir -p "$tmp/job/ios/Runner" "$tmp/job/tool" "$tmp/rt" "$tmp/home"
  cp ios/Runner/Runner.entitlements "$tmp/job/ios/Runner/"
  ln -s "$stubs" "$tmp/job/tool/asc_signing.py"
  : > "$tmp/github_env"; : > "$tmp/calls"; : > "$tmp/all-out"
}
leaked() { grep -qE 'SECRETSECRET|TAILLINE|BEGIN [A-Z ]*PRIVATE KEY' "$1"; }
plist_get() { python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get(sys.argv[2], ""))' "$1" "$2"; }

# run_job UPLOAD [VAR=value ...]: every step the stand-ins model (all but
# checkout, Flutter install and pub get), in the workflow's own order, with
# GitHub's gates: after a failure only always() steps run; `!inputs.upload`
# and `inputs.upload` follow UPLOAD. Sets $failed_step (empty = all passed)
# and $ran; every step's output is checked for the key.
run_job() {
  local upload=$1; shift
  local s g ok=1 rc
  failed_step= ran=()
  for s in "${steps[@]}"; do
    case "$s" in "Check out source"|"Install Flutter"|"Resolve dependencies") continue ;; esac
    g=$(gate "$s")
    case "$g" in
      "") [ "$ok" = 1 ] || continue ;;
      'always()') ;;
      inputs.upload) [ "$ok" = 1 ] && [ "$upload" = true ] || continue ;;
      '!inputs.upload') [ "$ok" = 1 ] && [ "$upload" = false ] || continue ;;
      *) fail "step '$s' has a gate this test does not model: $g" ;;
    esac
    ran+=("$s"); rc=0
    run "$s" GOOGLE_SERVICE_INFO_PLIST="<plist/>" KEY="$key_text" "$@" || rc=$?
    { echo "--- $s (exit $rc)"; cat "$tmp/out"; } >> "$tmp/all-out"
    leaked "$tmp/out" && fail "step '$s' printed a private key"
    if [ "$rc" != 0 ] && [ "$ok" = 1 ]; then ok=0; failed_step=$s; fi
  done
  cp "$tmp/all-out" "$tmp/out"
}
cleaned() { # after the always() steps: nothing of the signing material is left
  [ ! -e "$tmp/rt/asc" ] || fail "the key directory survived the job"
  [ ! -e "$tmp/rt/sign" ] || fail "\$RUNNER_TEMP/sign (private key, keychain) survived the job"
  [ ! -e "$tmp/home/Library/MobileDevice/Provisioning Profiles" ] && [ ! -e "$tmp/home/Library/Developer/Xcode/UserData/Provisioning Profiles" ] \
    || fail "the provisioning profile survived the job"
  ! grep -q sign.keychain-db "$tmp/home/.stub-keychain-search" 2>/dev/null || fail "the temporary keychain is still in the search list"
}

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
leaked "$tmp/out" && fail "the key step printed the key"
grep -qx "API_PRIVATE_KEYS_DIR=$tmp/rt/asc" "$tmp/github_env" || fail "API_PRIVATE_KEYS_DIR not exported: [$(cat "$tmp/github_env")]"
for empty in KEY KEY_ID ISSUER_ID TEAM_ID; do
  fresh
  if run "Write the App Store Connect key" KEY="$key_text" "$empty="; then fail "an empty $empty did not fail the key step"; fi
  [ -z "$(ls -A "$tmp/rt")" ] || fail "a key was written with $empty empty"
done

# 8 a pull request run, every step in workflow order: passes, validates, never uploads.
fresh
run_job false
[ -z "$failed_step" ] || fail "the pull request job failed at '$failed_step'"
grep -q '^xcodebuild -version$' "$tmp/calls" || fail "the archive step does not log the Xcode version"
[ "$(grep -c '^xcodebuild archive ' "$tmp/calls")" -eq 1 ] && [ "$(grep -c '^xcodebuild export ' "$tmp/calls")" -eq 1 ] \
  || fail "want one archive and one export: $(grep '^xcodebuild' "$tmp/calls")"
grep -qE -- '-allowProvisioningUpdates|-authenticationKey' <<<"$(grep '^xcodebuild archive ' "$tmp/calls")" \
  && fail "the archive is unsigned: no -allowProvisioningUpdates or -authenticationKey* ($(grep '^xcodebuild archive' "$tmp/calls"))"
grep -q '^flutter build ios ' "$tmp/calls" || fail "flutter does not build ios"
for f in --config-only --release --no-codesign --build-number=4242 --build-name=9.8.7 \
  --dart-define=SUPABASE_URL=var-SUPABASE_URL --dart-define=SUPABASE_PUBLISHABLE_KEY=var-SUPABASE_PUBLISHABLE_KEY \
  --dart-define=GOOGLE_WEB_CLIENT_ID=var-GOOGLE_WEB_CLIENT_ID; do
  grep -q -- " $f\( \|$\)" "$tmp/calls" || fail "flutter build lacks $f: $(cat "$tmp/calls")"
done
grep -q 'build ipa' "$tmp/calls" && fail "flutter build ipa cannot sign this app"
[[ "$(grep '^asc create' "$tmp/calls")" == "asc create com.esd.sis "*5150*2* ]] \
  || fail "the certificate step does not create for com.esd.sis with a profile name unique to the run attempt: $(grep '^asc' "$tmp/calls")"
for v in SIGNING_IDENTITY SIGNING_PROFILE_UUID SIGNING_CERTIFICATE_ID SIGNING_PROFILE_ID; do
  grep -q "^$v=." "$tmp/github_env" || fail "$v is not in GITHUB_ENV: $(cat "$tmp/github_env")"
done
grep -qx 'SIGNING_CERTIFICATE_ID=CERT-1' "$tmp/github_env" && grep -qx 'SIGNING_PROFILE_ID=PROF-1' "$tmp/github_env" \
  || fail "the ids from asc_signing.py did not reach GITHUB_ENV"
[ "$(grep '^curl ' "$tmp/calls")" = "curl $wwdr_url" ] || fail "the intermediate is not fetched once from $wwdr_url: $(grep '^curl' "$tmp/calls")"
sha1=$(sed -n 's/^SIGNING_IDENTITY=//p' "$tmp/github_env")
uuid=$(sed -n 's/^SIGNING_PROFILE_UUID=//p' "$tmp/github_env")
python3 - "$tmp/export-options.plist" "$sha1" "$uuid" <<'EOF' || fail "ExportOptions.plist is wrong"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
want = {"method": "app-store-connect", "signingStyle": "manual", "teamID": "TEAM123",
        "signingCertificate": sys.argv[2], "provisioningProfiles": {"com.esd.sis": sys.argv[3]}}
bad = {k: d.get(k) for k in want if d.get(k) != want[k]}
if bad or len(sys.argv[2]) != 40: print("ExportOptions:", bad, file=sys.stderr); sys.exit(1)
EOF
grep -q "^altool validate $tmp/rt/export/sis.ipa$" "$tmp/calls" || fail "the pull request was not validated with App Store Connect: $(cat "$tmp/calls")"
grep -q '^altool upload' "$tmp/calls" && fail "a pull request uploaded to TestFlight"
grep -qx 'asc delete CERT-1 PROF-1' "$tmp/calls" || fail "the certificate and profile were not revoked: $(grep '^asc' "$tmp/calls")"
grep -qx 'security delete-keychain' "$tmp/calls" || fail "the temporary keychain was not deleted"
cleaned
# What the check printed: every code object with an Apple Distribution authority.
for o in Runner.app Flutter.framework App.framework objective_c.framework; do
  grep -q "^$o: Apple Distribution: " "$tmp/out" || fail "the signature check does not show $o signed for distribution"
done

# 9 the release run: uploads, never validates separately; the same cleanup.
fresh
run_job true
[ -z "$failed_step" ] || fail "the release job failed at '$failed_step'"
grep -q "^altool upload $tmp/rt/export/sis.ipa$" "$tmp/calls" || fail "the release did not upload the exported .ipa: $(cat "$tmp/calls")"
grep -q '^altool validate' "$tmp/calls" && fail "the release validates separately (the upload validates itself)"
grep -qx 'asc delete CERT-1 PROF-1' "$tmp/calls" || fail "the release did not revoke the certificate"
cleaned

# 10 failures: the always() steps still clean up whatever exists, and nothing is uploaded.
# A certificate made, then the profile refused: the certificate is still revoked.
fresh
run_job true STUB_ASC_FAIL=profile
[ "$failed_step" = "Create the signing certificate" ] || fail "a refused profile did not fail the certificate step (failed: '${failed_step:-none}')"
grep -qx 'asc delete CERT-1 -' "$tmp/calls" || fail "a certificate without a profile was not revoked: $(grep '^asc' "$tmp/calls")"
grep -q '^altool' "$tmp/calls" && fail "the job went on to altool after a failure"
cleaned
# The downloaded intermediate did not issue the certificate: the step says so, nothing is imported.
fresh
run_job true STUB_URLS="{\"$wwdr_url\": \"$tmp/ca/fake.cer\"}"
[ "$failed_step" = "Create the signing certificate" ] || fail "a wrong WWDR intermediate did not fail the certificate step (failed: '${failed_step:-none}')"
grep -q 'the downloaded WWDR intermediate did not issue the signing certificate' "$tmp/out" \
  || fail "a wrong WWDR intermediate failed without saying so: $(sed -n '/^--- Create the signing/,/^---/p' "$tmp/out")"
grep -q "^curl $wwdr_url$" "$tmp/calls" || fail "the wrong-issuer case never fetched the intermediate"
grep -qx 'asc delete CERT-1 PROF-1' "$tmp/calls" || fail "after a wrong issuer the certificate was not revoked"
cleaned
# The export fails: both are revoked.
fresh
run_job true STUB_EXPORT_FAIL=1
[ "$failed_step" = "Export for App Store Connect" ] || fail "a failed export did not stop the job (failed: '${failed_step:-none}')"
grep -qx 'asc delete CERT-1 PROF-1' "$tmp/calls" || fail "after a failed export the certificate was not revoked"
cleaned
# An early failure (no key yet): nothing to revoke, and the cleanup steps pass.
fresh
run_job true GOOGLE_SERVICE_INFO_PLIST=
[ "$failed_step" = "Restore Firebase config" ] || fail "an empty Firebase secret did not fail first (failed: '${failed_step:-none}')"
[ "${ran[-2]}" = "Revoke the signing certificate" ] && [ "${ran[-1]}" = "Remove the App Store Connect key" ] \
  || fail "after an early failure the cleanup steps did not run: ${ran[*]}"
grep -q '^asc' "$tmp/calls" && fail "revoke called the API with no key and nothing created"
grep -q "exit [1-9]).*" <(grep -- '^--- \(Revoke\|Remove\)' "$tmp/out") && fail "a cleanup step failed after an early failure"
# A certificate that is not for distribution fails the signature check, before any altool.
fresh
run_job false STUB_CERT_KIND="Apple Development"
[ "$failed_step" = "Check the signature" ] || fail "a development-signed app passed the signature check (failed: '${failed_step:-none}')"
grep -q '^altool' "$tmp/calls" && fail "altool ran after the signature check failed"
cleaned
# A profile without the production push environment fails the push check.
fresh
run_job true STUB_PROFILE_APS=development
[ "$failed_step" = "Check the push entitlement" ] || fail "aps-environment development passed (failed: '${failed_step:-none}')"
grep -q '^altool' "$tmp/calls" && fail "a build without production push was uploaded"
cleaned

# A revoke that fails (Apple down) still removes the keychain and profiles,
# and fails the step so the leftover certificate shows red.
fresh
run_job true STUB_ASC_FAIL=delete
[ "$failed_step" = "Revoke the signing certificate" ] || fail "a failed revoke did not fail its step (failed: '${failed_step:-none}')"
grep -qx 'asc delete CERT-1 PROF-1' "$tmp/calls" || fail "revoke did not try the delete"
grep -qx 'security delete-keychain' "$tmp/calls" || fail "a failed revoke skipped the keychain delete"
[ "${ran[-1]}" = "Remove the App Store Connect key" ] || fail "key removal did not run after a failed revoke: ${ran[*]}"
cleaned

# 11 the signature check on its own: a code object re-signed after the app
# (broken seal), or signed ad-hoc, fails.
sig_case() { # <framework> <adhoc | tamper>: re-sign it ad-hoc, or change it after signing
  fresh
  run_job false >/dev/null
  [ -z "$failed_step" ] || fail "setup job failed at '$failed_step'"
  ( cd "$tmp/rt" && rm -rf resign && mkdir resign && cd resign && unzip -q ../export/sis.ipa )
  local fw="$tmp/rt/resign/Payload/Runner.app/Frameworks/$1"
  if [ "$2" = adhoc ]; then PATH="$tmp/bin:$PATH" HOME="$tmp/home" codesign --force --sign - "$fw" 2>/dev/null
  else echo ' ' >> "$fw/_CodeSignature/stub.json"; fi
  ( cd "$tmp/rt/resign" && rm ../export/sis.ipa && zip -qr ../export/sis.ipa . )
  rm -rf "$tmp/rt/sig"
  run "Check the signature"
}
if sig_case App.framework adhoc; then fail "an ad-hoc framework inside a distribution-signed app passed the signature check"; fi
grep -q "App.framework: unsigned or ad-hoc" "$tmp/out" || fail "the check does not name the ad-hoc framework: $(cat "$tmp/out")"
# Still Apple Distribution everywhere, but the app's seal no longer matches: only --verify sees it.
if sig_case Flutter.framework tamper; then fail "a framework changed after the app was signed passed the signature check"; fi
grep -q "sealed resource is missing or invalid" "$tmp/out" || fail "the check did not fail on the broken seal: $(cat "$tmp/out")"

# 12 the push entitlement on its own: production passes; everything else fails.
mkipa() { # <aps-environment | unset | unsigned>: $RUNNER_TEMP/export/sis.ipa
  rm -rf "$tmp/rt/export" "$tmp/rt/ipa"; mkdir -p "$tmp/rt/export"
  python3 - "$tmp/rt/export/sis.ipa" "$1" <<'EOF'
import io, json, plistlib, sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("Payload/Runner.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "com.esd.sis"}))
if sys.argv[2] != "unsigned":
    ents = {"application-identifier": "TEAM123.com.esd.sis"}
    if sys.argv[2] != "unset": ents["aps-environment"] = sys.argv[2]
    z.writestr("Payload/Runner.app/_CodeSignature/stub.json", json.dumps({"identifier": "com.esd.sis", "adhoc": True,
               "leaf": None, "entitlements": ents, "dr": None, "seal": {}}))
EOF
}
fresh; mkipa production
run "Check the push entitlement" || fail "a production-signed app failed the push check"
grep -qx 'aps-environment: production' "$tmp/out" || fail "the check does not report the value"
for bad in development unset unsigned; do
  fresh; mkipa "$bad"
  if run "Check the push entitlement"; then fail "aps-environment '$bad' passed the push check"; fi
done
fresh
if run "Check the push entitlement"; then fail "the push check passed with no exported .ipa"; fi

# 13 validate and upload find the key through GITHUB_ENV; without it they fail.
fresh
run_job false >/dev/null
rm -rf "$tmp/rt/asc"
if run "Validate with App Store Connect"; then fail "validation ran without the API key"; fi
if run "Upload to TestFlight"; then fail "the upload ran without the API key"; fi
# Revoke and removal are safe when nothing was created (always() after an early failure).
fresh
run "Revoke the signing certificate" || fail "revoke failed when nothing was created"
run "Remove the App Store Connect key" || fail "key removal failed when there was no key"
fresh
run "Write the App Store Connect key" KEY="$key_text" >/dev/null
run "Revoke the signing certificate" || fail "revoke failed with the key but no certificate"
grep -q '^asc delete' "$tmp/calls" && ! grep -qx 'asc delete - -' "$tmp/calls" && fail "revoke without ids must pass '- -': $(grep '^asc' "$tmp/calls")"

# ---- release.yml distribute: the steps, run ---------------------------------------
# The key, then distribute, then removal, with GitHub's gates; job env KEY_ID /
# ISSUER_ID as run() sets them. TF_GROUPS as the runner gives an unset
# variable: empty.
run_dist() { # [VAR=value ...]: sets $failed_step, $ran
  local s rc ok=1
  failed_step= ran=()
  for s in "${dsteps[@]}"; do
    [ "$ok" = 1 ] || [ "$(dgate "$s")" = 'always()' ] || continue
    ran+=("$s"); rc=0
    RUN_WF=$release run "$s" KEY="$key_text" BUILD=4242 "$@" || rc=$?
    leaked "$tmp/out" && fail "distribute step '$s' printed a private key"
    if [ "$rc" != 0 ] && [ "$ok" = 1 ]; then ok=0; failed_step=$s; fi
  done
}
dnote() { cat "$tmp/calls.note"; }
note=$'Şarkı seçebilirsin — "alıntı" \'tek\' $HOME `x`\nİkinci satır 🎵'
# 15 the groups default to bacanaks; the note arrives byte for byte; the key is gone after.
fresh
kmode=$(RUN_WF=$release run "Write the App Store Connect key" KEY="$key_text" >/dev/null; stat -c %a "$tmp/rt/asc" "$tmp/rt/asc/AuthKey_K3YID.p8" | paste -sd' ')
[ "$kmode" = "700 600" ] || fail "distribute key dir/file modes are [$kmode], want 700 600"
grep -qx "API_PRIVATE_KEYS_DIR=$tmp/rt/asc" "$tmp/github_env" || fail "distribute does not export API_PRIVATE_KEYS_DIR"
fresh
run_dist TF_GROUPS= NOTE_B64="$(printf '%s' "$note" | base64 -w0)"
[ -z "$failed_step" ] || fail "distribute failed at '$failed_step'"
grep -qx 'asc distribute com.esd.sis 4242 bacanaks' "$tmp/calls" || fail "empty TESTFLIGHT_GROUPS must mean bacanaks: $(grep '^asc' "$tmp/calls")"
[ "$(dnote)" = "$note" ] || fail "the note reached distribute as [$(dnote)], want [$note]"
[ ! -e "$tmp/rt/asc" ] || fail "distribute left the key behind"
# Groups from the variable, as data: never run as shell.
fresh
run_dist TF_GROUPS=' bacanaks, Friends $(touch pwned)' NOTE_B64=
[ -z "$failed_step" ] || fail "distribute failed at '$failed_step'"
grep -qxF 'asc distribute com.esd.sis 4242  bacanaks, Friends $(touch pwned)' "$tmp/calls" \
  || fail "TESTFLIGHT_GROUPS did not reach distribute verbatim: $(grep '^asc' "$tmp/calls")"
[ ! -e "$tmp/job/pwned" ] || fail "TESTFLIGHT_GROUPS was run as shell"
[ -z "$(dnote)" ] || fail "an empty note_b64 must pass an empty note (the tool supplies the default): [$(dnote)]"
# A failing distribute still removes the key, and the job fails.
fresh
run_dist TF_GROUPS= NOTE_B64= STUB_ASC_FAIL=distribute
[ "$failed_step" = "Distribute the build to the TestFlight groups" ] || fail "a failed distribute did not fail (failed: '${failed_step:-none}')"
[ "${ran[-1]}" = "Remove the App Store Connect key" ] || fail "key removal did not run after a failed distribute: ${ran[*]}"
[ ! -e "$tmp/rt/asc" ] || fail "the key survived a failed distribute"
# An empty secret fails before anything is written or called.
for empty in KEY KEY_ID ISSUER_ID; do
  fresh
  run_dist TF_GROUPS= NOTE_B64= "$empty="
  [ "$failed_step" = "Write the App Store Connect key" ] || fail "an empty $empty did not fail the distribute key step"
  grep -q '^asc' "$tmp/calls" && fail "distribute ran with $empty empty"
done

# ---- Info.plist --------------------------------------------------------------
# 14 export compliance answered in the app: no manual question per TestFlight build.
python3 -c 'import plistlib,sys; sys.exit(0 if plistlib.load(open("ios/Runner/Info.plist","rb")).get("ITSAppUsesNonExemptEncryption") is False else 1)' \
  || fail "Info.plist must declare ITSAppUsesNonExemptEncryption = false"

echo "ios_release_test: OK"
