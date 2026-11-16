#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Prevent two PRs from adding the same migration version; release applies duplicates.
shopt -s nullglob
files=(supabase/migrations/*.sql)
shopt -u nullglob

[ ${#files[@]} -eq 0 ] && exit 0

clashes=$(printf '%s\n' "${files[@]}" | xargs -n1 basename | cut -c1-14 | sort | uniq -d)

if [ -n "$clashes" ]; then
  while IFS= read -r v; do
    echo "migration version clash: $v used by:" >&2
    ls supabase/migrations | grep "^${v}.*\\.sql$" | sed 's/^/  /' >&2
  done <<< "$clashes"
  exit 1
fi

exit 0
