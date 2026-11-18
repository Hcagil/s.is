#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$repo/.github/workflows/release.yml"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

job_block() { awk -v n="  $1:" '$0==n{f=1;print;next} f&&/^  [a-z_]+:/{exit} f{print}' "$wf"; }
step_block() { job_block "$1" | awk -v t="      - name: $2" '$0==t{f=1;print;next} f&&/^      - name:/{exit} f{print}'; }
lineno() { grep -n -F -x -- "$1" "$wf" | head -1 | cut -d: -f1 || true; }

# w20: old_app job raise steps
old=$(job_block old_app)
grep -qF 'raise_to: ${{ steps.force.outputs.raise_to || steps.replay.outputs.raise_to }}' <<<"$old" || fail "w20: old_app missing raise_to expression"
grep -qF 'raise_reason: ${{ steps.force.outputs.raise_reason || steps.replay.outputs.raise_reason }}' <<<"$old" || fail "w20: old_app missing raise_reason expression"
force=$(step_block old_app 'Raise on request of a new migration')
[[ -n "$force" ]] || fail "w20: no step 'Raise on request of a new migration' in old_app"
for s in 'id: force' \
          'git diff --diff-filter=A --name-only "$range" -- supabase/migrations' \
          '-- raise-minimum:' \
          'echo "raise_to=$RELEASE_CODE" >> "$GITHUB_OUTPUT"' \
          'RELEASE_CODE: ${{ needs.scope.outputs.code }}'; do
  grep -qF -- "$s" <<<"$force" || fail "w20: missing string '$s' in force step"
done

[ "$fails" -eq 0 ] || { echo "old_app_release_gates_test: $fails failed"; exit 1; }
echo "old_app_release_gates_test: OK"
