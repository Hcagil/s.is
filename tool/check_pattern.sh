#!/usr/bin/env bash
# Layer rules from docs/ARCHITECTURE.md. Exit 1 on any violation.
set -euo pipefail
LIB_DIR="${LIB_DIR:-lib}"
SDKS='package:(supabase_flutter|supabase|google_sign_in|in_app_update|package_info_plus|flutter_secure_storage|url_launcher|image_picker)/'
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
# Rule 4: data/ never awaits a teardown inside a catch block. On a failed
# Realtime join, removeChannel waits on a dead socket and close() on a stream
# nobody listened to never completes -- the failure path hangs. Use
# leaveChannel() from lib/data/realtime_channels.dart.
while IFS= read -r f; do
  awk '
    { code = $0; sub(/\/\/.*/, "", code) }
    !in_catch && match(code, /(^|[^A-Za-z_.])catch[[:space:]]*\(/) {
      pre = substr(code, 1, RSTART); closes = gsub(/}/, "}", pre)
      in_catch = 1; catch_depth = depth - closes
    }
    in_catch && code ~ /(^|[^A-Za-z_])await[[:space:]][^;]*(\.close\(\)|removeChannel\()/ { print FILENAME ":" FNR ":" $0 }
    { opens = gsub(/{/, "{", code); shuts = gsub(/}/, "}", code); depth += opens - shuts }
    in_catch && depth <= catch_depth && !/catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*$/ { in_catch = 0 }
  ' "$f" | while read -r l; do report "awaited teardown in catch: $l"; done || true
done < <(find "$LIB_DIR" -path '*/data/*.dart' 2>/dev/null)
if [ -s "$FAILFLAG" ]; then exit 1; fi; echo "pattern: OK"
