#!/usr/bin/env bash
# tool/sis_bot.sh message length limits, with no network: send, start and an
# image caption take 1 to 3916 characters (the server adds an AI line of up to
# 84 to a first bot message; 4000 - 84), edit takes 1 to 4000. Characters, not
# bytes: the tool counts with bash ${#t} under a UTF-8 locale. The tool runs
# from a sandbox copy; a `curl` stand-in first on PATH records every call and
# fails, so nothing reaches a server. "Passes the check" = no length refusal
# (the run goes on and dies at the stand-in with exit 1); "refused" = exit 2
# with the message, and curl never called.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
box=$(mktemp -d); trap 'rm -rf "$box"' EXIT
mkdir -p "$box/tool" "$box/bin" "$box/.private" "$box/tmp"
cp "$repo/tool/sis_bot.sh" "$box/tool/"
printf '{"url":"http://127.0.0.1:9","anon_key":"anon","user_id":"00000000-0000-0000-0000-000000000001","refresh_token":"r"}\n' >"$box/.private/sis_bot.json"
chmod 600 "$box/.private/sis_bot.json"
printf '#!/bin/sh\necho call >>"%s/calls"\nexit 7\n' "$box" >"$box/bin/curl"; chmod +x "$box/bin/curl"
export PATH="$box/bin:$PATH" TMPDIR="$box/tmp" LC_ALL=C.UTF-8
printf '\x89PNG\r\n\x1a\n' >"$box/pic.png"
BOT="$box/tool/sis_bot.sh"; C=00000000-0000-0000-0000-0000000000c1
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
rep() { local o=""; o=$(printf "%$2s" '' | sed "s/ /$1/g"); printf '%s' "$o"; }  # rep CHAR N

# case NAME refused|passes MSG cmd...  (text goes in as the last argument)
case_() {
  local name=$1 want=$2 msg=$3; shift 3
  : >"$box/calls"; local code=0 out
  out=$("$@" 2>&1) || code=$?
  if [ "$want" = refused ]; then
    [ "$code" = 2 ] || fail "$name: want exit 2, got $code ($out)"
    [[ "$out" == *"$msg"* ]] || fail "$name: want '$msg', got '$out'"
    [ ! -s "$box/calls" ] || fail "$name: curl was called"
  else
    [ "$code" != 2 ] || fail "$name: refused locally ($out)"
    [[ "$out" != *"characters"* ]] || fail "$name: length message ($out)"
    [ -s "$box/calls" ] || fail "$name: never reached the network stand-in"
  fi
  echo "done: $name"
}
M="the message must be 1 to 3916 characters"; CAP="the caption must be at most 3916 characters"
for n in 3916 3917; do
  w=passes; [ $n = 3917 ] && w=refused
  case_ "send $n" $w "$M" "$BOT" send $C "$(rep a $n)"
  case_ "start $n" $w "$M" "$BOT" start $C "$(rep a $n)"
  case_ "send stdin $n" $w "$M" bash -c "printf %s '$(rep a $n)' | '$BOT' send $C -"
  case_ "caption $n" $w "$CAP" "$BOT" send --image "$box/pic.png" $C "$(rep a $n)"
done
# Characters, not bytes: 3916 two-byte letters (7832 bytes) pass, 3917 do not.
case_ "send 3916 multi-byte" passes "$M" "$BOT" send $C "$(rep ğ 3916)"
case_ "send 3917 multi-byte" refused "$M" "$BOT" send $C "$(rep ğ 3917)"
case_ "caption 3917 multi-byte" refused "$CAP" "$BOT" send --image "$box/pic.png" $C "$(rep ğ 3917)"
E="00000000-0000-0000-0000-0000000000e1"
case_ "edit 4000" passes "" "$BOT" edit $E "$(rep a 4000)"
case_ "edit 4001" refused "the message must be 1 to 4000 characters" "$BOT" edit $E "$(rep a 4001)"
case_ "edit 4000 multi-byte" passes "" "$BOT" edit $E "$(rep ğ 4000)"
case_ "edit 4001 multi-byte" refused "the message must be 1 to 4000 characters" "$BOT" edit $E "$(rep ğ 4001)"
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all sis_bot length cases ok"
