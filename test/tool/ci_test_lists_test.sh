#!/usr/bin/env bash
# Verify that the test names referenced in ci.yml and ci_local.sh match.

root="$(cd "$(dirname "$0")/../.." && pwd)"
set -euo pipefail

names() {
  grep -E "$2" "$1" | grep -oE 'test/tool/[A-Za-z0-9_]+_test\.[a-z]+' | sort -u
}

list_a=$(names "$root/.github/workflows/ci.yml" 'tool/check_pattern.sh &&')
list_b=$(names "$root/tool/ci_local.sh" '^layer_rules()')

if [[ -z $list_a ]]; then
  echo "no names found in $root/.github/workflows/ci.yml"
  exit 1
fi
if [[ -z $list_b ]]; then
  echo "no names found in $root/tool/ci_local.sh"
  exit 1
fi

diff_a_b=$(comm -23 <(echo "$list_a") <(echo "$list_b"))
diff_b_a=$(comm -13 <(echo "$list_a") <(echo "$list_b"))

if [[ -n $diff_a_b ]]; then
  echo "FAIL: only in ci.yml: $diff_a_b"
fi
if [[ -n $diff_b_a ]]; then
  echo "FAIL: only in ci_local.sh: $diff_b_a"
fi

if [[ -n $diff_a_b || -n $diff_b_a ]]; then
  exit 1
fi

echo "ok: $(echo "$list_a" | wc -l) test names match"
exit 0
