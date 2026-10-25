#!/usr/bin/env bash
# tool/release_scope.sh <prev> <sha> over a real git history (no git stand-ins):
#
#   - stdout is exactly one line, ship=true or ship=false; one reason on stderr;
#     exit 0 in every valid case;
#   - prev may be a commit, a lightweight tag or an annotated tag; "" means the
#     base is sha^;
#   - base == sha -> false ("no new commits since the last release");
#   - base not an ancestor of sha (older commit, or a side branch) -> false
#     ("not newer than the last release");
#   - a range touching only docs/ .github/ test/ integration_test/
#     supabase/tests/ tool/, *.md, .gitignore, .gitattributes -> false;
#   - any other path in the range (also a deleted or renamed-away one) -> true,
#     stderr "<n> files ship";
#   - merge commits in the range are judged by what they bring in;
#   - not exactly two arguments -> exit 2 with usage on stderr; an unknown
#     prev or sha -> non-zero exit.
set -euo pipefail
script="$(cd "$(dirname "$0")/../.." && pwd)/tool/release_scope.sh"
tmp=$(mktemp -d); errf=$(mktemp); trap 'rm -rf "$tmp" "$errf"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email qa@sis.test
git config user.name QA
git config commit.gpgsign false
git config tag.gpgsign false

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# commit <message> <path>... : writes a fresh line into each path, commits.
commit() {
  local msg=$1; shift
  local p
  for p in "$@"; do mkdir -p "$(dirname "$p")"; echo "$msg $RANDOM" >>"$p"; git add -- "$p"; done
  git commit -q -m "$msg"
}

# run <prev> <sha> : sets out, err, code.
run() {
  set +e
  out=$("$script" "$@" 2>"$errf"); code=$?
  set -e
  err=$(cat "$errf")
}

# expect <name> <true|false> <stderr regex> <prev> <sha>
expect() {
  local name=$1 want=$2 why=$3; shift 3
  run "$@"
  if [[ $code -ne 0 ]]; then fail "$name: exit $code, want 0 (stderr: $err)"; return; fi
  if [[ $out != "ship=$want" ]]; then fail "$name: stdout '$out', want exactly 'ship=$want'"; return; fi
  if [[ $(printf '%s\n' "$err" | grep -c .) -ne 1 ]]; then fail "$name: stderr must be one reason line, got '$err'"; return; fi
  if ! grep -Eq -- "$why" <<<"$err"; then fail "$name: stderr '$err' does not match /$why/"; return; fi
  echo "ok: $name"
}

commit base lib/main.dart README.md
git tag -a v1 -m "release 1"
v1=$(git rev-parse HEAD)

# --- base == sha
expect 'same commit as the annotated tag' false 'no new commits' v1 "$v1"
expect 'same commit given as a commit id' false 'no new commits' "$v1" "$v1"

# --- non-shipping paths, each alone, then all together
for p in docs/guide.txt .github/workflows/x.yml test/a_test.dart integration_test/b.dart \
         supabase/tests/c.sql tool/d.sh notes.md lib/deep/CHANGES.md .gitignore .gitattributes \
         CHANGELOG.md docs/a.png .github/dependabot.yml; do
  git checkout -q --detach "$v1"
  commit "only $p" "$p"
  expect "only $p" false '.' v1 HEAD
done
git checkout -q --detach "$v1"
commit 'every non-shipping kind' docs/a.txt .github/b.yml test/c.dart integration_test/d.dart \
  supabase/tests/e.sql tool/f.sh g.md .gitignore .gitattributes
expect 'every non-shipping kind in one range' false '.' v1 HEAD

# --- shipping paths, each alone (anchored prefixes: lib/docs/ and tooling/ ship)
for p in lib/a.dart android/app/build.gradle ios/Runner/Info.plist supabase/migrations/1_x.sql \
         supabase/functions/f/index.ts pubspec.yaml rust/src/lib.rs docker/Dockerfile \
         lib/docs/x.dart tooling/x.sh supabase/config.toml lib/a.mdx \
         lib/tool/x.dart lib/test/x.dart assets/icon.png sub/.gitignore .gitignore.bak README.mdx \
         .githubx/y Docs/x README.MD x.md.orig; do
  git checkout -q --detach "$v1"
  commit "ship $p" "$p"
  expect "ship $p" true '^[0-9]+ files? ships?' v1 HEAD
done

# --- mixed: many docs commits and one shipping file, the shipping one in the middle
git checkout -q --detach "$v1"
commit d1 docs/one.txt
commit d2 a.md
commit code lib/x.dart
commit d3 .github/c.yml
commit d4 tool/t.sh
mixed=$(git rev-parse HEAD)
expect 'docs + one lib file over five commits' true '^[0-9]+ files? ships?' v1 "$mixed"

# --- many files: one shipping path among thousands that do not (no early exit loses it)
git checkout -q --detach "$v1"
mkdir -p docs/many; for ((i = 0; i < 3000; i++)); do echo "$i" > "docs/many/p$i.md"; done
echo big > lib/big.dart; git add docs/many lib/big.dart; git commit -q -m 'many docs and one app file'
expect 'one app file among 3000 docs' true '^[0-9]+ files? ships?' v1 HEAD
git checkout -q --detach "$v1"
mkdir -p docs/many; for ((i = 0; i < 3000; i++)); do echo "$i" > "docs/many/p$i.md"; done
git add docs/many; git commit -q -m 'many docs only'
expect '3000 docs files only' false '.' v1 HEAD

# --- a shipping file removed or moved out of the app ships too
git checkout -q --detach "$v1"
git rm -q lib/main.dart; git commit -q -m 'delete lib file'
expect 'deleted lib file' true '^[0-9]+ files? ships?' v1 HEAD
git checkout -q --detach "$v1"
mkdir -p docs; git mv lib/main.dart docs/main.dart; git commit -q -m 'move lib file to docs'
expect 'lib file renamed into docs/' true '^[0-9]+ files? ships?' v1 HEAD

# --- lightweight tag as prev; the range starts at the tag, not before it
git checkout -q --detach "$v1"
commit 'app change before release 2' lib/before.dart
git tag v2
commit 'docs after release 2' docs/after.txt
after2=$(git rev-parse HEAD)
expect 'lightweight tag: only docs after it' false '.' v2 "$after2"
expect 'same commit as the lightweight tag' false 'no new commits' v2 v2

# --- sha older than the last release / not on its line
before2=$(git rev-parse v2^)
expect 'sha older than the last release' false 'not newer than the last release' v2 "$before2"
git checkout -q --detach "$v1"
commit 'side branch app change' lib/side.dart
side=$(git rev-parse HEAD)
expect 'sha on a side branch, not after the last release' false 'not newer than the last release' v2 "$side"

# --- prev "" falls back to sha^ (only the released commit itself counts)
git checkout -q --detach "$v1"
commit 'app' lib/p.dart
commit 'docs on top' docs/p.txt
expect 'empty prev, docs-only commit on an app commit' false '.' '' HEAD
expect 'empty prev, app commit itself' true '^[0-9]+ files? ships?' '' HEAD^

# --- merge commits in the range
git checkout -q -B trunk "$v1"
git checkout -q -b feature
commit 'feature app' lib/feature.dart
git checkout -q trunk
commit 'trunk docs' docs/t.txt
git tag v3
git merge -q --no-ff -m 'merge feature' feature
expect 'merge brings in a lib change from before the tag' true '^[0-9]+ files? ships?' v3 HEAD
git checkout -q -B trunk2 v3
git checkout -q -b docsbranch
commit 'docs only branch' docs/b.txt
git checkout -q trunk2
commit 'trunk md' x.md
git merge -q --no-ff -m 'merge docs' docsbranch
expect 'merge of docs-only branches' false '.' v3 HEAD

# --- argument and git errors
for args in 0 1 3; do
  set --; for ((i = 0; i < args; i++)); do set -- "$@" v1; done
  run "$@"
  if [[ $code -ne 2 || -n $out ]] || ! grep -qi usage <<<"$err"; then
    fail "$args arguments: exit $code stdout '$out' stderr '$err', want exit 2, usage on stderr"
  else echo "ok: $args arguments -> usage, exit 2"; fi
done
run no-such-tag HEAD
[[ $code -ne 0 && $out != ship=* ]] && echo 'ok: unknown prev fails' || fail "unknown prev: exit $code stdout '$out'"
run v1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[[ $code -ne 0 && $out != ship=* ]] && echo 'ok: unknown sha fails' || fail "unknown sha: exit $code stdout '$out'"

[[ $fails -eq 0 ]] || { echo "$fails case(s) failed"; exit 1; }
echo PASS
