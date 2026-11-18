#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$repo/.github/workflows/release.yml"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

job_block() { awk -v n="  $1:" '$0==n{f=1;print;next} f&&/^  [a-z_]+:/{exit} f{print}' "$wf"; }
step_block() { job_block "$1" | awk -v t="      - name: $2" '$0==t{f=1;print;next} f&&/^      - name:/{exit} f{print}'; }
lineno() { grep -n -F -x -- "$1" "$wf" | head -1 | cut -d: -f1 || true; }

# w18: publish job checks
a=$(job_block publish | grep -n -F -x -- '      - name: Check the Apple secrets for account deletion' | cut -d: -f1 || true)
b=$(job_block publish | grep -n -F -x -- '      - name: Apply database migrations (schema goes forward before the app)' | cut -d: -f1 || true)
if [[ -z "$a" || -z "$b" || "$a" -ge "$b" ]]; then
  fail "w18: Apple check step missing or not before migrations step"
fi
apple=$(step_block publish 'Check the Apple secrets for account deletion')
[[ -n "$apple" ]] || fail "w18: no step 'Check the Apple secrets for account deletion' in publish job"
for s in 'for v in APPLE_TEAM_ID APPLE_SIWA_KEY_ID APPLE_SIWA_PRIVATE_KEY; do' \
          '[ -z "${!v}" ]' \
          '::error::Missing GitHub secret(s):' \
          'exit 1' \
          'APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}' \
          'APPLE_SIWA_KEY_ID: ${{ secrets.APPLE_SIWA_KEY_ID }}' \
          'APPLE_SIWA_PRIVATE_KEY: ${{ secrets.APPLE_SIWA_PRIVATE_KEY }}'; do
  grep -qF -- "$s" <<<"$apple" || fail "w18: missing string '$s' in Apple step"
done

# w19: ios job needs and if
hdr=$(job_block ios | grep -E '^    (needs|if):' || true)
grep -E '^    needs:' <<<"$hdr" | grep -qF 'publish' || fail "w19: ios needs does not include publish"
p="needs.publish.result == 'success'"
grep -E '^    if:' <<<"$hdr" | grep -qF -- "$p" || fail "w19: ios if does not contain '$p'"

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
