#!/usr/bin/env bash
# tool/check_release_clean.sh [aab] on fixture copies of the real repo files:
#
#   - this tree as it is: exit 0, "release guard: ok";
#   - release.yml mentioning SIS_TEST_LOGIN, SIS_TEST_APP or com.esd.sis.test -> exit 1;
#   - the exact line `        applicationId = "com.esd.sis"` missing (also when
#     only its indent changes) -> exit 1;
#   - applicationIdSuffix not exactly once, or once but outside `debug {` -> exit 1;
#   - with an AAB: not a file, manifest without com.esd.sis, or manifest with
#     com.esd.sis.test -> exit 1; a clean bundle -> exit 0.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# fresh : a fixture tree holding copies of the guard and the two files it reads.
fresh() {
  rm -rf "$tmp/t"; mkdir -p "$tmp/t/tool" "$tmp/t/.github/workflows" "$tmp/t/android/app"
  cp "$repo/tool/check_release_clean.sh" "$tmp/t/tool/"
  cp "$repo/.github/workflows/release.yml" "$tmp/t/.github/workflows/"
  cp "$repo/android/app/build.gradle.kts" "$tmp/t/android/app/"
  rel="$tmp/t/.github/workflows/release.yml"; gradle="$tmp/t/android/app/build.gradle.kts"
}

# expect <code> <name> [aab] : runs the guard in the fixture tree.
expect() {
  local want=$1 name=$2 out code=0; shift 2
  out=$(bash "$tmp/t/tool/check_release_clean.sh" "$@" 2>&1) || code=$?
  [ "$code" = "$want" ] || fail "$name: exit $code, want $want ($out)"
  if [ "$want" = 0 ] && [[ "$out" != *"release guard: ok"* ]]; then fail "$name: no ok line ($out)"; fi
  if [ "$want" != 0 ] && [[ "$out" == *"release guard: ok"* ]]; then fail "$name: printed ok on failure"; fi
}

# aab <path> <manifest text> : a minimal bundle with the given manifest.
aab() {
  python3 -I - "$1" "$2" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("base/manifest/AndroidManifest.xml", sys.argv[2])
    z.writestr("base/lib/arm64-v8a/libapp.so", "flutter app code")
PY
}

# Precondition: the real files hold what the rules key on, so the fixtures below mean something.
grep -qxF '        applicationId = "com.esd.sis"' "$repo/android/app/build.gradle.kts" || fail "precondition: applicationId line"
[ "$(grep -c applicationIdSuffix "$repo/android/app/build.gradle.kts")" = 1 ] || fail "precondition: one suffix"

fresh; expect 0 "this tree"

for word in SIS_TEST_LOGIN SIS_TEST_APP com.esd.sis.test; do
  fresh; echo "        # $word" >>"$rel"; expect 1 "release.yml mentions $word"
done

fresh; sed -i 's/^        applicationId = "com.esd.sis"$/        applicationId = "com.esd.other"/' "$gradle"
expect 1 "applicationId changed"
fresh; sed -i 's/^        applicationId = "com.esd.sis"$/    applicationId = "com.esd.sis"/' "$gradle"
expect 1 "applicationId line re-indented"

fresh; sed -i '/applicationIdSuffix/d' "$gradle"; expect 1 "no applicationIdSuffix"
fresh; sed -i '/applicationIdSuffix/p' "$gradle"; expect 1 "applicationIdSuffix twice"
# Move the suffix line just inside `release {` (one occurrence, wrong block).
fresh; line=$(grep applicationIdSuffix "$gradle")
sed -i '/applicationIdSuffix/d' "$gradle"
grep -qE '^[[:space:]]*release[[:space:]]*\{' "$gradle" || fail "precondition: release block"
awk -v l="$line" '{print} /^[[:space:]]*release[[:space:]]*\{/ && !done {print l; done=1}' "$gradle" >"$gradle.n" && mv "$gradle.n" "$gradle"
expect 1 "applicationIdSuffix in release block"

fresh; mkdir "$tmp/dir.aab"; expect 1 "AAB is a directory" "$tmp/dir.aab"
fresh; expect 1 "AAB missing" "$tmp/nope.aab"
aab "$tmp/good.aab" 'package="com.esd.sis" versionCode="1"'
fresh; expect 0 "clean AAB" "$tmp/good.aab"
aab "$tmp/other.aab" 'package="com.example.app"'
fresh; expect 1 "AAB of another app" "$tmp/other.aab"
aab "$tmp/test.aab" 'package="com.esd.sis.test"'
fresh; expect 1 "AAB of the test app" "$tmp/test.aab"

if [ "$fails" -ne 0 ]; then echo "check_release_clean_test: $fails failed"; exit 1; fi
echo "check_release_clean_test: ok"
