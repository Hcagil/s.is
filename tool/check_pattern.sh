#!/usr/bin/env bash
# Layer rules from docs/ARCHITECTURE.md. Exit 1 on any violation.
set -euo pipefail
LIB_DIR="${LIB_DIR:-lib}"
SDKS='package:(supabase_flutter|supabase|google_sign_in|in_app_update|package_info_plus|flutter_secure_storage)/'
FAILFLAG=$(mktemp); trap 'rm -f "$FAILFLAG"' EXIT
report() { echo "PATTERN VIOLATION: $1"; echo 1 > "$FAILFLAG"; }
# Rule 1: presentation never imports SDKs or data/
while IFS= read -r f; do
  grep -nE "import [\"']($SDKS|[^']*/data/)" "$f" | sed "s|^|$f:|" | while read -r l; do report "$l"; done || true
done < <(find "$LIB_DIR" -path '*/presentation/*.dart' 2>/dev/null)
# Rule 2: application imports only domain/, core/, riverpod, dart:
while IFS= read -r f; do
  grep -nE "import [\"'](package:flutter/|$SDKS|[^']*/(data|presentation)/)" "$f" | sed "s|^|$f:|" | while read -r l; do report "$l"; done || true
done < <(find "$LIB_DIR" -path '*/application/*.dart' 2>/dev/null)
# Rule 3: SDKs only in data/ (and lib/main.dart bootstrap)
while IFS= read -r f; do
  case "$f" in */data/*|*/main.dart) continue;; esac
  grep -nE "import [\"']$SDKS" "$f" | sed "s|^|$f:|" | while read -r l; do report "$l"; done || true
done < <(find "$LIB_DIR" -name '*.dart' 2>/dev/null)
if [ -s "$FAILFLAG" ]; then exit 1; fi; echo "pattern: OK"
