#!/usr/bin/env bash
# Proves the checker fails on a violation and passes on clean code.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib/features/demo/presentation" "$tmp/lib/features/demo/application" "$tmp/lib/features/demo/data"
echo "import 'package:supabase_flutter/supabase_flutter.dart';" > "$tmp/lib/features/demo/presentation/bad.dart"
if LIB_DIR="$tmp/lib" tool/check_pattern.sh >/dev/null 2>&1; then echo "FAIL: violation not detected"; exit 1; fi
rm "$tmp/lib/features/demo/presentation/bad.dart"
echo "import 'package:flutter/material.dart';" > "$tmp/lib/features/demo/presentation/good.dart"
LIB_DIR="$tmp/lib" tool/check_pattern.sh >/dev/null && echo "PASS"
