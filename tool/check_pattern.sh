#!/usr/bin/env bash
# Layer rules from docs/ARCHITECTURE.md. Exit 1 on any violation.
set -euo pipefail
LIB_DIR="${LIB_DIR:-lib}"
# Every third-party package in pubspec.yaml's dependencies (flutter itself
# and flutter_riverpod excluded: riverpod is explicitly allowed in
# application/ by rule 2). Keep this in sync with pubspec.yaml and with
# docs/ARCHITECTURE.md's data/ layer list, which names this script as the
# authority.
SDKS='package:(drift|sqlite3|flutter_rust_bridge|supabase_flutter|supabase|google_sign_in|sign_in_with_apple|in_app_update|package_info_plus|flutter_secure_storage|flutter_local_notifications|firebase_messaging|firebase_core|shared_preferences|web_socket_channel|path_provider|path_provider_foundation|photo_manager|flutter_contacts|url_launcher|http|connectivity_plus|file_picker|open_filex|light_compressor_v2|video_player|share_plus|google_maps_flutter|flutter_map|latlong2|geolocator|local_auth|record|speech_to_text|imcodec|webview_flutter|webview_flutter_android|webview_flutter_wkwebview)/'
FAILFLAG=$(mktemp); words=$(mktemp); trap 'rm -f "$FAILFLAG" "$words"' EXIT
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
# Rule 6 (ARCHITECTURE rule 6): a feature's data/ never builds a
# NetworkFailure from error text.
# Raw SDK text ("ClientException: SocketException ...") ends up on screen;
# pass the error to readableFailure() from lib/data/failures.dart instead.
# Only a plain string literal is allowed.
while IFS= read -r f; do
  grep -nE "NetworkFailure\\([^'\"]|NetworkFailure\\(['\"][^'\"]*\\$" "$f" | sed "s|^|$f:|" | while read -r l; do report "raw error text in a Failure: $l"; done || true
done < <(find "$LIB_DIR" -path '*/features/*/data/*.dart' 2>/dev/null)
# Rule 7: none of the words in a secret list appears in what this change adds (diff lines, commit messages, PR text). The list lives outside git:
# PRIVATE_WORDS (one word per line) or .private/ops/private-words.txt in the main checkout. Prints counts only, never a match.
# PRIVATE_EXPECTED=1 makes a missing or short list (fewer than 5 words) a failure. PRIVATE_BASE is the commit the change starts from (default origin/main).
if [ -n "${PRIVATE_WORDS:-}" ]; then
  printf '%s\n' "$PRIVATE_WORDS" > "$words"
elif f="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo /nonexistent/.git)")/.private/ops/private-words.txt"; [ -f "$f" ]; then
  cat "$f" > "$words"
fi
tr -d '\r' < "$words" | grep -v '^[[:space:]]*$' > "$words.clean" || true
mv "$words.clean" "$words"
nwords=$(wc -l < "$words")
if [ "${PRIVATE_EXPECTED:-}" = 1 ] && [ "$nwords" -lt 5 ]; then report "private word list missing or shorter than 5 words"; fi
base="${PRIVATE_BASE:-origin/main}"
if [ "$nwords" -gt 0 ]; then
  if git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
    hits=$({
      git diff -U0 "$(git merge-base "$base" HEAD)" | { grep '^+' || true; } | { grep -v '^+++' || true; }
      git log --format=%B "$base"..HEAD
      printf '%s\n' "${PRIVATE_PR_TEXT:-}"
    } | { grep -ciF -f "$words" || true; })
    if [ "$hits" -ne 0 ]; then report "private words: $hits hits in added lines, commit messages or PR text"; fi
  elif [ "${PRIVATE_EXPECTED:-}" = 1 ]; then
    report "private word guard cannot find its base commit"
  fi
fi
if [ -s "$FAILFLAG" ]; then exit 1; fi; echo "pattern: OK"
