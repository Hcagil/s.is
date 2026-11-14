#!/usr/bin/env bash
# tool/release_kind.sh <prev> <sha>, l10n rules, over a real git history: output is exactly one line
# quiet=true|false (exit 0). A change under lib/l10n/ stays quiet only if every changed ARB key
# (a diff line of app_en.arb / app_tr.arb, added or removed, of the form two spaces + "key": or
# two spaces + "@key":) is used by no code outside lib/features/admin_panels and lib/l10n
# (usage = `.key` followed by a word boundary, e.g. l.key). No key found in an l10n diff -> false.
set -euo pipefail
real="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); errf=$(mktemp); trap 'rm -rf "$tmp" "$errf"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email qa@sis.test; git config user.name QA
git config commit.gpgsign false; git config tag.gpgsign false
mkdir tool; cp "$real/tool/release_kind.sh" "$real/tool/release_scope.sh" tool/
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
# arb <file> <line>: append a line to lib/l10n/<file>.arb (stays in the working tree).
arb() { printf '%s\n' "$2" >>"lib/l10n/$1.arb"; git add -- "lib/l10n/$1.arb"; }
# start: fresh branch from tag v1.
start() { git checkout -q -B case v1; }
# finish: commit what is staged; sets $sha.
finish() { git commit -q -m case; sha=$(git rev-parse HEAD); }
# put <path> <text>: write the file text, stage it.
put() { mkdir -p "$(dirname "$1")"; printf '%b\n' "$2" >"$1"; git add -- "$1"; }
check() {
  local name=$1 want=$2; shift 2
  set +e; out=$(tool/release_kind.sh "$@" 2>"$errf"); code=$?; set -e
  if [[ $code -ne 0 ]]; then fail "$name: exit $code"; return; fi
  if [[ $out != "quiet=$want" ]]; then fail "$name: stdout '$out', want quiet=$want"; return; fi
  if [[ $(grep -c . "$errf") -ne 1 ]]; then fail "$name: stderr not one line: $(cat "$errf")"; return; fi
  echo "ok: $name"
}
mkdir -p lib/l10n lib/features/admin_panels lib/chat
echo a >lib/main.dart
printf '{\n  "hello": "Hello"\n}\n' >lib/l10n/app_en.arb
printf '{\n  "hello": "Merhaba"\n}\n' >lib/l10n/app_tr.arb
echo 'final a = l.sharedKey; final b = l.foobar;' >lib/chat/chat.dart
echo 'final a = 1;' >lib/features/admin_panels/panel.dart
git add -A; git commit -q -m base; git tag -a v1 -m v1
# ---- CASES (fill in) ----
# 1 "admin-only key"
start
arb app_en '  "adminOnlyKey": "x",'
put lib/features/admin_panels/panel.dart 'final a = l.adminOnlyKey;'
finish
check "admin-only key" true v1 "$sha"

# 2 "admin-only key in both languages"
start
arb app_en '  "adminOnlyKey": "x",'
arb app_tr '  "adminOnlyKey": "x",'
put lib/features/admin_panels/panel.dart 'final a = l.adminOnlyKey;'
finish
check "admin-only key in both languages" true v1 "$sha"

# 3 "key used elsewhere (en)"
start
arb app_en '  "sharedKey": "x",'
finish
check "key used elsewhere (en)" false v1 "$sha"

# 4 "key used elsewhere (tr)"
start
arb app_tr '  "sharedKey": "x",'
finish
check "key used elsewhere (tr)" false v1 "$sha"

# 5 "metadata line of a used key"
start
arb app_en '  "@sharedKey": {'
finish
check "metadata line of a used key" false v1 "$sha"

# 6 "no key found"
start
arb app_en '    "nested": 1,'
finish
check "no key found" false v1 "$sha"

# 7 "word boundary"
start
arb app_en '  "foo": "x",'
finish
check "word boundary" true v1 "$sha"

# 8 "mixed: admin key plus app change"
start
arb app_en '  "adminOnlyKey": "x",'
put lib/main.dart 'changed'
finish
check "mixed: admin key plus app change" false v1 "$sha"

# 9 "one admin-only key and one shared key in one change"
start
arb app_en '  "adminOnlyKey": "x",'
arb app_en '  "sharedKey": "x",'
finish
check "one admin-only key and one shared key in one change" false v1 "$sha"

# 10 "removed shared key"
# First commit base for v2
start
put lib/l10n/app_en.arb '{\n  "sharedKey": "x",\n}'
git add -- lib/l10n/app_en.arb
git commit -q -m base
git tag -f -a v2 -m v2
# Second commit removing the key
put lib/l10n/app_en.arb '{\n}'
git add -- lib/l10n/app_en.arb
git commit -q -m remove
sha=$(git rev-parse HEAD)
check "removed used key" false v2 "$sha"

# 11 "tr-only admin key"
start
arb app_tr '  "adminOnlyKey": "x",'
put lib/features/admin_panels/panel.dart 'final a = l.adminOnlyKey;'
finish
check "tr-only admin key" true v1 "$sha"

# 12 "admin key in en, shared key in tr"
start
arb app_en '  "adminOnlyKey": "x",'
arb app_tr '  "sharedKey": "x",'
put lib/features/admin_panels/panel.dart 'final a = l.adminOnlyKey;'
finish
check "admin key in en, shared key in tr" false v1 "$sha"

# 13 "removed admin-only key"
start
put lib/l10n/app_en.arb '{\n  "adminOnlyKey": "x",\n}'
git add -- lib/l10n/app_en.arb
git commit -q -m base
git tag -f -a v3 -m v3
put lib/l10n/app_en.arb '{\n}'
git add -- lib/l10n/app_en.arb
git commit -q -m remove
sha=$(git rev-parse HEAD)
check "removed admin-only key" true v3 "$sha"

# 14 "metadata line of an admin-only key"
start
arb app_en '  "@adminOnlyKey": {'
put lib/features/admin_panels/panel.dart 'final a = l.adminOnlyKey;'
finish
check "metadata line of an admin-only key" true v1 "$sha"
# ---- end ----
[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo PASS
