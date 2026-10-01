#!/usr/bin/env bash
# One-time creation (and yearly rotation) of the long-lived iOS distribution
# certificate that every build is signed with (docs/DELIVERY.md, Certificate
# lifecycle). The private key never leaves this machine except as the GitHub
# secret IOS_DISTRIBUTION_KEY; nothing secret is printed.
#
# Usage: tool/ios_signing_bootstrap.sh [GIT_REF] [PROFILE_NAME]
#   GIT_REF defaults to the current branch, PROFILE_NAME to 'sis ci distribution'.
#
# Steps:
#   1. Generates a 2048-bit RSA key and a CSR in a container (the host has no
#      toolchain), in a private temporary directory removed on exit.
#   2. Dispatches .github/workflows/ios-signing-bootstrap.yml, which holds the
#      App Store Connect key and receives only the CSR (public). It creates the
#      certificate and the App Store profile and logs their ids.
#   3. Waits for that run to succeed.
#   4. Only then stores the key: `gh secret set IOS_DISTRIBUTION_KEY` from stdin
#      (never an argument, never echoed). After the run, so that a rotation never
#      leaves releases with a key that matches no certificate.
#   5. Prints the ids and the expiry the run logged.
#
# Needs gh (signed in) and docker. The workflow_dispatch event is accepted only
# for a workflow file that exists on the repository's default branch, so the
# pull request that adds the workflow must be merged first.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null && command -v docker >/dev/null || { echo 'needs gh and docker' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'gh is not signed in' >&2; exit 1; }

ref=${1:-$(git branch --show-current)}
profile=${2:-'sis ci distribution'}

LOCAL_UID=$(id -u) LOCAL_GID=$(id -g)
export LOCAL_UID LOCAL_GID
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

docker compose run --rm -T --no-deps -v "$tmp:/keys" --entrypoint sh flutter -c \
  'umask 077; openssl req -new -newkey rsa:2048 -nodes -keyout /keys/key.pem -out /keys/csr.pem -subj "/CN=sis distribution" 2>/dev/null'
[ -s "$tmp/key.pem" ] && [ -s "$tmp/csr.pem" ] || { echo 'could not generate the key and CSR' >&2; exit 1; }
chmod 600 "$tmp/key.pem"

start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run ios-signing-bootstrap.yml --ref "$ref" \
  -f csr_b64="$(base64 -w0 "$tmp/csr.pem")" -f profile_name="$profile"

id=
for _ in $(seq 20); do
  id=$(gh run list --workflow ios-signing-bootstrap.yml --event workflow_dispatch --limit 5 \
    --json databaseId,createdAt --jq "[.[] | select(.createdAt >= \"$start\")][0].databaseId // empty")
  [ -z "$id" ] || break
  sleep 3
done
[ -n "$id" ] || { echo 'the bootstrap run did not appear' >&2; exit 1; }

gh run watch "$id" --exit-status >/dev/null || { echo "bootstrap run failed: gh run view $id --log" >&2; exit 1; }

gh secret set IOS_DISTRIBUTION_KEY < "$tmp/key.pem"

gh run view "$id" --log | grep -E 'SIGNING_(CERTIFICATE|PROFILE)_ID=|notAfter=' | sed 's/^.*Z //' || true
echo 'Done. Open a pull request: the iOS signed build job proves the identity. For a rotation, revoke the previous certificate in App Store Connect only after the last build it signed has left beta review.'
