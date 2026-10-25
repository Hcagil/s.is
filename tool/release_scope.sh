#!/bin/bash
# Decides whether the commits between the last release and <sha> change something that ships.
# Usage: tool/release_scope.sh <prev tag-or-commit, may be empty> <sha>
# Prints ship=true or ship=false on stdout; the reason goes to stderr.
set -euo pipefail

if [ $# -ne 2 ]; then echo "Usage: $0 <prev> <sha>" >&2; exit 2; fi
prev=$1
sha=$2

git rev-parse --verify --quiet "$sha^{commit}" >/dev/null || { echo "unknown commit: $sha" >&2; exit 1; }
if [ -n "$prev" ]; then git rev-parse --verify --quiet "$prev^{commit}" >/dev/null || { echo "unknown release: $prev" >&2; exit 1; }; fi
if [ -z "$prev" ]; then base=$(git rev-parse "$sha^"); else base=$(git rev-list -n1 "$prev"); fi

if [ "$base" = "$(git rev-parse "$sha")" ]; then
  echo "ship=false"; echo "no new commits since the last release" >&2; exit 0
fi
if ! git merge-base --is-ancestor "$base" "$sha"; then
  echo "ship=false"; echo "release commit is not newer than the last release" >&2; exit 0
fi

# Docs, CI, tests and tool scripts cannot affect the artefact or the database, so they do not publish a build.
n=$(git diff --no-renames --name-only "$base" "$sha" \
  | grep -vE '^(docs/|\.github/|test/|integration_test/|supabase/tests/|tool/)|\.md$|^\.git(ignore|attributes)$' \
  | wc -l) || true
if [ "$n" -gt 0 ]; then
  echo "ship=true"; echo "$n files ship" >&2
else
  echo "ship=false"; echo "only docs, tests, tool or CI files changed" >&2
fi
