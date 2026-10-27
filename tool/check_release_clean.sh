#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "release guard: $*" >&2; exit 1; }

# Check 1: release.yml must not mention test app
if grep -qE 'SIS_TEST_LOGIN|SIS_TEST_APP|com\.esd\.sis\.test' .github/workflows/release.yml; then
  fail "release.yml mentions the test app"
fi

# Check 2: build.gradle.kts must contain exactly the line with applicationId = "com.esd.sis"
if ! grep -qxF '        applicationId = "com.esd.sis"' android/app/build.gradle.kts; then
  fail "build.gradle.kts does not contain the expected applicationId line"
fi

# Check 3: applicationIdSuffix occurs exactly once, inside the debug block
[ "$(grep -c applicationIdSuffix android/app/build.gradle.kts)" = 1 ] || fail "applicationIdSuffix must occur exactly once"
out=$(awk '/^[[:space:]]*debug[[:space:]]*\{/{d=1} /^[[:space:]]*release[[:space:]]*\{/{d=0} /applicationIdSuffix/ && !d {print "outside"}' android/app/build.gradle.kts)
[ -z "$out" ] || fail "applicationIdSuffix is outside the debug block"

# Check 4: if AAB provided, validate it
if [[ -n "${1:-}" ]]; then
  if [[ ! -f "$1" ]]; then
    fail "the given AAB is not a file"
  fi
  manifest=$(unzip -p "$1" base/manifest/AndroidManifest.xml | strings)
  if ! echo "$manifest" | grep -q 'com.esd.sis'; then
    fail "the release bundle is not com.esd.sis"
  fi
  if echo "$manifest" | grep -q 'com.esd.sis.test'; then
    fail "the release bundle contains the test app"
  fi

fi

echo "release guard: ok"
