#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$repo/.github/workflows/release.yml"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

job_block() { awk -v n="  $1:" '$0==n{f=1;print;next} f&&/^  [a-z_]+:/{exit} f{print}' "$wf"; }
step_block() { job_block "$1" | awk -v t="      - name: $2" '$0==t{f=1;print;next} f&&/^      - name:/{exit} f{print}'; }
lineno() { grep -n -F -x -- "$1" "$wf" | head -1 | cut -d: -f1 || true; }

# w1: old_app before publish
old_app_line=$(lineno "  old_app:")
publish_line=$(lineno "  publish:")
if [[ "$old_app_line" -ge "$publish_line" ]]; then
  fail "w1: old_app line ($old_app_line) not before publish line ($publish_line)"
fi

# w2: publish needs includes old_app
if ! job_block publish | grep -F "needs:" | grep -qF "old_app"; then
  fail "w2: publish job does not mention old_app in needs"
fi

# w3: publish if contains !failure()
if ! job_block publish | grep -F "if:" | grep -qF '!failure()'; then
  fail "w3: publish if missing !failure()"
fi

# w4: publish if contains !cancelled()
if ! job_block publish | grep -F "if:" | grep -qF '!cancelled()'; then
  fail "w4: publish if missing !cancelled()"
fi

# w5: step order in publish
upload_line=$(job_block publish | grep -n -F -x -- "      - name: Upload to Play internal track" | cut -d: -f1 || true)
raise_line=$(job_block publish | grep -n -F -x -- "      - name: Raise the oldest allowed build" | cut -d: -f1 || true)
tag_line=$(job_block publish | grep -n -F -x -- "      - name: Tag and publish release notes" | cut -d: -f1 || true)
if [[ -z "$upload_line" || -z "$raise_line" || -z "$tag_line" ]] || [[ "$upload_line" -ge "$raise_line" || "$raise_line" -ge "$tag_line" ]]; then
  fail "w5: step order incorrect in publish job"
fi

# w6: raise step content
raise_block=$(step_block publish "Raise the oldest allowed build")
if ! echo "$raise_block" | grep -qF "min_supported_build < \$RAISE_TO"; then
  fail "w6: missing min_supported_build < RAISE_TO guard"
fi
if ! echo "$raise_block" | grep -qF "where id = 1"; then
  fail "w6: missing where id = 1"
fi
if ! echo "$raise_block" | grep -qF '[[ "$RAISE_TO" =~ ^[0-9]+$ ]]'; then
  fail "w6: missing digit check regex"
fi

# w7: raise step if condition
if ! echo "$raise_block" | grep -qF "if: needs.old_app.outputs.raise_to != ''"; then
  fail "w7: raise step if condition missing"
fi

# w8: old_app timeout and environment
if ! job_block old_app | grep -qF "timeout-minutes: 120"; then
  fail "w8: old_app missing timeout-minutes: 120"
fi
if ! job_block old_app | grep -qF "environment: play-internal"; then
  fail "w8: old_app missing environment: play-internal"
fi

# w9: old_app contains OLD_APP_MODE=release and OLD_APP_BASE=
if ! job_block old_app | grep -qF "OLD_APP_MODE=release"; then
  fail "w9: old_app missing OLD_APP_MODE=release"
fi
if ! job_block old_app | grep -qF "OLD_APP_BASE="; then
  fail "w9: old_app missing OLD_APP_BASE="
fi

# w10: old_app if contains needs.scope.outputs.ship
if ! job_block old_app | grep -qF "if: needs.scope.outputs.ship == 'true'"; then
  fail "w10: old_app missing if with needs.scope.outputs.ship"
fi

[ "$fails" -eq 0 ] || { echo "old_app_workflow_test: $fails failed"; exit 1; }
echo "old_app_workflow_test: OK"
