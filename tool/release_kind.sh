#!/bin/bash
# Decides whether the commits between the last release and <sha> are a "quiet" change:
# shipping files touch only Admin Panels, plus l10n strings used only by Admin Panels.
# Usage: tool/release_kind.sh <prev tag-or-commit, may be empty> <sha>
# Prints quiet=true or quiet=false on stdout; the reason goes to stderr.
set -euo pipefail

if [ $# -ne 2 ]; then echo "Usage: $0 <prev> <sha>" >&2; exit 2; fi
prev=$1
sha=$2

git rev-parse --verify --quiet "$sha^{commit}" >/dev/null || { echo "unknown commit: $sha" >&2; exit 1; }
if [ -n "$prev" ]; then git rev-parse --verify --quiet "$prev^{commit}" >/dev/null || { echo "unknown release: $prev" >&2; exit 1; }; fi
if [ -z "$prev" ]; then base=$(git rev-parse "$sha^"); else base=$(git rev-list -n1 "$prev"); fi

if [ "$base" = "$(git rev-parse "$sha")" ]; then
  echo "quiet=false"; echo "no new commits since the last release" >&2; exit 0
fi
if ! git merge-base --is-ancestor "$base" "$sha"; then
  echo "quiet=false"; echo "release commit is not newer than the last release" >&2; exit 0
fi

# Only a build that ships can be quiet; release_scope.sh decides that.
scope=$("$(dirname "$0")/release_scope.sh" "$prev" "$sha" 2>/dev/null) || true
if [ "$scope" != "ship=true" ]; then
  echo "quiet=false"; echo "nothing ships" >&2; exit 0
fi

# Same non-shipping filter as release_scope.sh.
files=$(git diff --no-renames --name-only "$base" "$sha" \
  | grep -vE '^(docs/|\.github/|test/|integration_test/|supabase/tests/|tool/)|\.md$|^\.git(ignore|attributes)$' || true)

has_l10n=0
while IFS= read -r f; do
  case "$f" in
    "") ;;
    lib/features/admin_panels/*) ;;
    lib/l10n/*) has_l10n=1 ;;
    *) echo "quiet=false"; echo "changes outside Admin Panels: $f" >&2; exit 0 ;;
  esac
done <<< "$files"

# An l10n string is quiet only if no code outside Admin Panels uses its key.
if [ "$has_l10n" -eq 1 ]; then
  keys=$(git diff -U0 --no-renames "$base" "$sha" -- lib/l10n/app_en.arb lib/l10n/app_tr.arb \
    | grep -E '^[+-]  "@?[A-Za-z0-9_]+":' \
    | sed -E 's/^[+-]  "@?([A-Za-z0-9_]+)":.*/\1/' | sort -u || true)
  if [ -z "$keys" ]; then
    echo "quiet=false"; echo "no l10n keys found in the diff" >&2; exit 0
  fi
  while IFS= read -r key; do
    if git grep -qE "\.${key}\b" "$sha" -- lib ':!lib/features/admin_panels' ':!lib/l10n'; then
      echo "quiet=false"; echo "l10n key used outside Admin Panels: $key" >&2; exit 0
    fi
  done <<< "$keys"
fi

echo "quiet=true"; echo "only Admin Panels changes" >&2
