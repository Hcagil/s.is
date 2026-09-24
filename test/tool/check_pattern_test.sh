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
LIB_DIR="$tmp/lib" tool/check_pattern.sh >/dev/null

# Rule 5: no awaited teardown (close(), removeChannel) inside a catch block
# under any data/ directory. Each case gets its own LIB_DIR holding one file
# at <rel>, read from stdin.
n=0
run_case() { # <rel under lib/> ; stdin = file content ; prints output
  local lib="$tmp/r5-$n/lib"
  mkdir -p "$(dirname "$lib/$1")"
  cat > "$lib/$1"
  LIB_DIR="$lib" tool/check_pattern.sh 2>&1
}
violation() { # <name> <rel>
  local out; n=$((n + 1))
  if out=$(run_case "$2"); then echo "FAIL: rule 5 missed: $1"; exit 1; fi
  if ! grep -q '^PATTERN VIOLATION' <<<"$out"; then
    echo "FAIL: rule 5 ($1) exited non-zero without a PATTERN VIOLATION line:"
    echo "$out"; exit 1
  fi
}
clean() { # <name> <rel>
  local out; n=$((n + 1))
  if ! out=$(run_case "$2"); then echo "FAIL: rule 5 false positive: $1"; echo "$out"; exit 1; fi
}

awaited_close='class Repo {
  Future<void> open() async {
    try {
      await join();
    } catch (e) {
  await controller.close();
}
  }
}'
violation 'await close() in catch, feature data/' features/demo/data/repo.dart <<<"$awaited_close"
violation 'await close() in catch, shared data/' data/helper.dart <<<"$awaited_close"

violation 'await removeChannel deep in a multi-line catch' data/channels.dart <<'EOF'
class Repo {
  Future<Result<void>> open() async {
    final ch = _client.channel('presence:members');
    try {
      await joinChannel(ch);
      return const Ok(null);
    } catch (e) {
      final reason = e.toString();
      log(reason);
      await _client.removeChannel(ch);
      return Err(Failure.provider(reason));
    }
  }
}
EOF

violation 'on SocketException catch (e) form' features/demo/data/net.dart <<'EOF'
class Repo {
  Future<void> open() async {
    try {
      await connect();
    } on SocketException catch (e) {
      log(e);
      await sink.close();
    }
  }
}
EOF

clean 'unawaited(close()) inside catch' features/demo/data/ok1.dart <<'EOF'
class Repo {
  Future<void> open() async {
    try {
      await join();
    } catch (e) {
      unawaited(controller.close());
      unawaited(_client.removeChannel(ch));
      rethrow;
    }
  }
}
EOF

clean 'await close() in a try body and a plain method' data/ok2.dart <<'EOF'
class Repo {
  Future<void> open() async {
    try {
      await controller.close();
      await _client.removeChannel(ch);
    } finally {
      log('done');
    }
  }

  Future<void> dispose() async {
    await controller.close();
    await _client.removeChannel(ch);
  }
}
EOF

clean 'one-line catch, then an unrelated await close()' features/demo/data/ok3.dart <<'EOF'
class Repo {
  void ping() {
    try {
      send();
    } catch (_) {}
  }

  Future<void> dispose() async {
    log('closing');
    await controller.close();
  }
}
EOF

clean 'same catch outside data/ (application)' features/demo/application/ctl.dart <<<"$awaited_close"
clean 'same catch outside data/ (presentation)' features/demo/presentation/view.dart <<<"$awaited_close"

# Rule 6: a feature's data/ never builds a NetworkFailure from an error's
# text. Only a plain string literal (no `$` interpolation) may be passed.
violation 'string interpolation of the error' features/demo/data/repo.dart <<'EOF'
Failure f(Object e) => NetworkFailure('$e');
EOF

violation 'error.message passed straight through' features/demo/data/repo2.dart <<'EOF'
Failure f(Object e) => NetworkFailure(e.message);
EOF

violation 'error.toString() passed straight through' features/demo/data/repo3.dart <<'EOF'
Failure f(Object e) => NetworkFailure(e.toString());
EOF

violation 'a bare variable, not a literal' features/demo/data/repo4.dart <<'EOF'
Failure f(String message) => NetworkFailure(message);
EOF

violation 'interpolation mid-sentence' features/demo/data/repo5.dart <<'EOF'
Failure f(Object e) => NetworkFailure('Upload failed: $e');
EOF

clean 'a plain string literal, no interpolation' features/demo/data/ok4.dart <<'EOF'
Failure f(Object e) => NetworkFailure('This photo is not available.');
EOF

clean 'the same raw-text pattern outside features/*/data' data/helper.dart <<'EOF'
Failure f(Object e) => NetworkFailure('$e');
EOF

echo "PASS"
