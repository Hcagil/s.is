#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$repo/.github/workflows/release.yml"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

job_block() { local o; o=$(awk -v n="  $1:" '$0==n{f=1;print;next} f&&/^  [a-z_]+:/{exit} f{print}' "$wf"); printf '%s\n' "$o"; }
step_block() { local o; o=$(job_block "$1" | awk -v t="      - name: $2" '!d&&$0==t{f=1;print;next} f&&/^      - name:/{f=0;d=1} f&&!d{print}'); printf '%s\n' "$o"; }
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

# w11: a separate step reads the production minimum; fails with the ::error:: line unless digits; hands it on as `min`
prod=$(step_block old_app "Read the production minimum")
[[ -n "$prod" ]] || fail "w11: no step 'Read the production minimum' in old_app"
grep -qF '::error::could not read the production minimum supported build' <<<"$prod" || fail "w11: missing the ::error:: line"
grep -qF '=~ ^[0-9]+$' <<<"$prod" || fail "w11: missing the digit check"
grep -qF 'min_supported_build from public.app_config' <<<"$prod" || fail "w11: step does not read app_config"
grep -qF 'min=$min' <<<"$prod" || fail "w11: step does not write min to GITHUB_OUTPUT"
grep -qF 'SUPABASE_ACCESS_TOKEN' <<<"$prod" || fail "w11: read step has no access token"

# w12: the long replay step has NO SUPABASE_* env and gets the min from the read step
replay=$(step_block old_app "Find the lowest safe build")
[[ -n "$replay" ]] || fail "w12: no step 'Find the lowest safe build'"
if grep -q 'SUPABASE_' <<<"$replay"; then fail "w12: replay step mentions SUPABASE_*"; fi
grep -qF 'OLD_APP_MIN: ${{ steps.prod.outputs.min }}' <<<"$replay" || fail "w12: replay step lacks OLD_APP_MIN from steps.prod"
grep -qF 'OLD_APP_RELEASE_BUILD: ${{ needs.scope.outputs.code }}' <<<"$replay" || fail "w12: replay step lacks OLD_APP_RELEASE_BUILD"
r_line=$(job_block old_app | grep -n -F -x -- "      - name: Read the production minimum" | cut -d: -f1 || true)
f_line=$(job_block old_app | grep -n -F -x -- "      - name: Find the lowest safe build" | cut -d: -f1 || true)
{ [[ -n "$r_line" && -n "$f_line" ]] && [ "$r_line" -lt "$f_line" ]; } || fail "w12: read step is not before the replay step"

# w13: ios waits for old_app and survives a skipped or failed-neighbour state
ios_hdr=$(job_block ios | grep -E '^    (needs|if):' || true)
grep -E '^    needs:' <<<"$ios_hdr" | grep -qF 'old_app' || fail "w13: ios needs lacks old_app"
grep -E '^    if:' <<<"$ios_hdr" | grep -qF '!failure()' || fail "w13: ios if lacks !failure()"
grep -E '^    if:' <<<"$ios_hdr" | grep -qF '!cancelled()' || fail "w13: ios if lacks !cancelled()"

# w14: publish's raise step and the release-notes line skip a raise to this release's own build
raise_block=$(step_block publish "Raise the oldest allowed build")
grep -F 'if:' <<<"$raise_block" | grep -qF "needs.old_app.outputs.raise_to != needs.scope.outputs.code" || fail "w14: publish raise step does not skip raise_to == code"
tag_block=$(step_block publish "Tag and publish release notes")
grep -F 'RAISE_NOTE:' <<<"$tag_block" | grep -qF "needs.old_app.outputs.raise_to != needs.scope.outputs.code" || fail "w14: RAISE_NOTE does not skip raise_to == code"

# w15: raise_own runs after ios, distribute and publish, only for a raise to this release's own build
ro_hdr=$(job_block raise_own | grep -E '^    (needs|if):' || true)
for j in old_app publish ios distribute; do grep -E '^    needs:' <<<"$ro_hdr" | grep -qF "$j" || fail "w15: raise_own needs lacks $j"; done
grep -E '^    if:' <<<"$ro_hdr" | grep -qF "needs.old_app.outputs.raise_to == needs.scope.outputs.code" || fail "w15: raise_own if lacks raise_to == code"
grep -E '^    if:' <<<"$ro_hdr" | grep -qF "needs.publish.result == 'success'" || fail "w15: raise_own if lacks publish success"
grep -E '^    if:' <<<"$ro_hdr" | grep -qF '!cancelled()' || fail "w15: raise_own if lacks !cancelled()"
job_block raise_own | grep -qF "environment: play-internal" || fail "w15: raise_own lacks environment play-internal"

# w16: raise_own decides: SQL only after ios AND distribute succeeded, else the warning and the job summary
dec=$(step_block raise_own "Decide")
grep -qF '[ "$IOS" = success ] && [ "$DISTRIBUTE" = success ]' <<<"$dec" || fail "w16: decide does not require ios and distribute success"
grep -qF '::warning::raise to $RAISE_TO skipped: no iOS build in this release; raise by hand after the next iOS build' <<<"$dec" || fail "w16: decide lacks the ::warning:: line"
grep -qF 'skipped: no iOS build in this release; raise by hand after the next iOS build" >> "$GITHUB_STEP_SUMMARY"' <<<"$dec" || fail "w16: decide lacks the job summary line"
grep -qF 'IOS: ${{ needs.ios.result }}' <<<"$dec" || fail "w16: IOS not taken from needs.ios.result"
grep -qF 'DISTRIBUTE: ${{ needs.distribute.result }}' <<<"$dec" || fail "w16: DISTRIBUTE not taken from needs.distribute.result"
own=$(step_block raise_own "Raise the oldest allowed build to this release")
grep -qF "if: steps.decide.outputs.go == 'true'" <<<"$own" || fail "w16: raise step not gated on decide go"
for st in "Check out source" "Install Supabase CLI"; do
  step_block raise_own "$st" | grep -qF "if: steps.decide.outputs.go == 'true'" || fail "w16: step '$st' not gated on decide go"
done

# w17: both raise paths check RAISE_TO <= RELEASE_CODE, the digit check and keep the guarded update
for blk in "$raise_block" "$own"; do
  grep -qF '[ "$RAISE_TO" -le "$RELEASE_CODE" ]' <<<"$blk" || fail "w17: a raise path lacks the RAISE_TO <= RELEASE_CODE cap"
  grep -qF 'RELEASE_CODE: ${{ needs.scope.outputs.code }}' <<<"$blk" || fail "w17: a raise path lacks RELEASE_CODE env"
  grep -qF '=~ ^[0-9]+$' <<<"$blk" || fail "w17: a raise path lacks the digit check"
  grep -qF 'where id = 1 and min_supported_build < $RAISE_TO' <<<"$blk" || fail "w17: a raise path lacks the guarded update"
done

[ "$fails" -eq 0 ] || { echo "old_app_workflow_test: $fails failed"; exit 1; }
echo "old_app_workflow_test: OK"
