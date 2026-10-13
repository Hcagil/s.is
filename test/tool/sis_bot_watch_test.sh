#!/usr/bin/env bash
# Test of tool/sis_bot_watch.sh, the tester-inbox watcher, against a fake
# sis_bot.sh (SIS_BOT_CMD). No database: the fake answers `status` with the
# bot's id and holds a mailbox; like the real `read --since` it prints, after a
# short delay, only the lines newer than the cursor it is given. It can fail
# with a chosen exit code, printing an error with a secret the watcher must
# never repeat.
#
# Covers: the first run sets the marker to now with no history dump; a new
# message appended (header, conversation line, body in a fenced block) and
# printed as '<sender>: <first 80 chars>'; the 80-character cut (multi-byte
# too) with newlines as spaces; the bot's own messages skipped by sender id
# (a renamed bot too) while the marker moves past them, and a tester NAMED
# "SIS Destek" still delivered; control characters stripped (except newline)
# in the inbox and the printed line; a body cannot fake an entry header, even
# by closing the fence; a malformed line skipped with one line, the rest
# handled once; inbox and marker mode 600 under umask 022; nothing new prints
# nothing; only `status` and `read --since <marker>` calls; the line for exit
# 3, 4, 5 and any other code; continuing after a failure; the sleep doubling
# after exit 5; the default interval (one check at start, none soon after).
set -euo pipefail
cd "$(dirname "$0")/../.."

BOX=$(mktemp -d); trap 'rm -rf "$BOX"' EXIT
mkdir -p "$BOX/tool" "$BOX/fake"
cp tool/sis_bot_watch.sh "$BOX/tool/"
W="$BOX/tool/sis_bot_watch.sh"; FAKE="$BOX/fake"
SEEN="$BOX/.private/tester-inbox.seen"; INBOX="$BOX/.private/tester-inbox.md"
SECRET=fake-secret-must-not-print
BOTID=00000000-0000-4000-8000-000000b07b07
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "not ok - $1"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
same() {  # NAME WANT GOT
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$2], got [$3]"; fi
}

# The fake sis_bot.sh. Every call is logged as "<epoch> <args>". `status`
# prints user=<bot id>. `read` exit codes come one per read call from
# $FAKE/exits (missing line: 0). Mailbox lines are "<epoch> <raw line>"; a read
# prints the raw lines whose epoch is after --since.
cat >"$FAKE/sis_bot.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
d=$(dirname "$0")
printf '%s %s\n' "$(date +%s.%N)" "$*" >>"$d/calls"
sleep 0.2
if [ "$*" = status ]; then echo "user=$FAKE_BOT_ID"; exit 0; fi
n=$(grep -c ' read ' "$d/calls")
code=$(sed -n "${n}p" "$d/exits" 2>/dev/null); code=${code:-0}
if [ "$code" != 0 ]; then
  echo "sis_bot.sh: refresh failed, refresh_token=$SECRET_FOR_FAKE" >&2
  echo "token $SECRET_FOR_FAKE"
  exit "$code"
fi
[ "$#" = 3 ] && [ "$1" = read ] && [ "$2" = --since ] || { echo "usage" >&2; exit 2; }
since=$(date -d "$3" +%s%N) || exit 2
while IFS= read -r line; do
  [ "${line%% *}" -gt "$since" ] && printf '%s\n' "${line#* }"
done <"$d/mailbox"
exit 0
EOF
chmod +x "$FAKE/sis_bot.sh"; : >"$FAKE/mailbox"
export SECRET_FOR_FAKE=$SECRET FAKE_BOT_ID=$BOTID

# ts EPOCH -> a created_at as PostgREST prints it
ts() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123456+00:00; }
TESTER=00000000-0000-4000-8000-0000000000aa
msg() {  # ID CONV SENDER_ID SENDER_NAME BODY EPOCH -> one mailbox line
  printf '%s000000000 %s\n' "$6" "$(jq -nc --arg id "$1" --arg c "$2" --arg u "$3" --arg s "$4" --arg b "$5" \
    --arg t "$(ts "$6")" '{id:$id, conversation_id:$c, sender_id:$u, sender_name:$s, body:$b,
                           created_at:$t, reply_to:null}')" >>"$FAKE/mailbox"
}
# run SECONDS EXITS [ARGS...]: one fresh watcher process for SECONDS under
# umask 022, EXITS (one code per line) scripting the fake's reads; combined
# output in $BOX/out.
run() {
  local secs=$1 exits=$2; shift 2
  rm -f "$FAKE/calls"; printf '%s' "$exits" >"$FAKE/exits"
  (cd "$BOX" && umask 022 && SIS_BOT_CMD="$FAKE/sis_bot.sh" timeout "$secs" "$W" "$@") >"$BOX/out" 2>&1 || true
  touch "$FAKE/calls"
}
calls_ok() { ! grep -vE '^[0-9.]+ (status|read --since [^ ]+)$' "$FAKE/calls"; }
first_read() { grep -m1 ' read ' "$FAKE/calls" | cut -d' ' -f2-; }
# The inbox as a reader of Markdown sees it: entry headers and conversation
# lines outside fences, each fenced block as "B <hex of its content>", any
# other text outside fences as "X <line>".
inbox_view() {
  python3 -I - "$INBOX" <<'EOF'
import re, sys
out, fence, buf = [], None, []
for line in open(sys.argv[1], encoding='utf-8').read().split('\n'):
    if fence:
        if re.fullmatch(r' {0,3}' + re.escape(fence[0]) + '{%d,}[ \t]*' % len(fence), line):
            out.append('B ' + '\n'.join(buf).encode().hex()); fence, buf = None, []
        else:
            buf.append(line)
        continue
    m = re.match(r' {0,3}(`{3,}|~{3,})', line)
    if m: fence = m.group(1)
    elif line.startswith('## ') or line.startswith('conversation: '): out.append(line)
    elif line.strip(): out.append('X ' + line)
if fence: out.append('UNCLOSED')
print('\n'.join(out))
EOF
}
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
entry() {  # CREATED_AT SENDER CONV BODY -> the expected inbox_view lines
  printf '## %s — %s\nconversation: %s\nB %s\n' "$1" "$2" "$3" "$(hex "$4")"
}
CONV=11111111-1111-4111-8111-111111111111

# 1 first run: marker set to now, nothing dumped ---------------------------------
msg 22222222-0000-4000-8000-000000000001 "$CONV" "$TESTER" Bob "old history" $(( $(date +%s) - 86400 ))
start=$(date +%s)
run 3 "" 100
end=$(date +%s)
same "first run prints nothing" "" "$(cat "$BOX/out")"
check "first run appends nothing to the inbox" test ! -s "$INBOX"
check "first run writes the marker, one line" test "$(grep -c '' "$SEEN" 2>/dev/null)" = 1
same "the marker file is mode 600 (umask 022 outside)" 600 "$(stat -c %a "$SEEN" 2>/dev/null)"
M0=$(cat "$SEEN" 2>/dev/null || true)
m=$(date -d "$M0" +%s 2>/dev/null || echo 0)
check "the first marker is now ($m in $((start-5))..$((end+5)))" test "$m" -ge $((start-5)) -a "$m" -le $((end+5))
check "it only calls status and read --since <marker>" calls_ok
base=$((m + 2))

# 2 a new message: appended in the format, printed ---------------------------------
msg 33333333-0000-4000-8000-000000000001 "$CONV" "$TESTER" Bob "hello from bob" $((base+1))
T1=$(ts $((base+1)))
run 3 "" 100
same "a new message prints '<sender>: <body>'" "Bob: hello from bob" "$(cat "$BOX/out")"
WANT=$(entry "$T1" Bob "$CONV" "hello from bob")
same "it is appended: header, conversation line, body in a fenced block" "$WANT" "$(inbox_view)"
same "the inbox file is mode 600 (umask 022 outside)" 600 "$(stat -c %a "$INBOX" 2>/dev/null)"
same "the marker is the message's created_at" "$T1" "$(cat "$SEEN")"
same "the cursor passed is the previous marker" "read --since $M0" "$(first_read)"

# 3 nothing new: no output, inbox unchanged, cursor = last marker -----------------
run 3 "" 100
same "nothing new prints nothing" "" "$(cat "$BOX/out")"
same "and appends nothing" "$WANT" "$(inbox_view)"
same "the cursor passed is the stored marker" "read --since $T1" "$(first_read)"

# 4 the bot's own messages: skipped by sender id, marker moves past them ----------
msg 33333333-0000-4000-8000-000000000002 "$CONV" "$BOTID" "SIS Destek" "the bot's reply" $((base+2))
msg 33333333-0000-4000-8000-000000000003 "$CONV" "$BOTID" "SIS Yardım" "renamed bot's reply" $((base+3))
run 3 "" 100
same "the bot's messages (any name) print nothing" "" "$(cat "$BOX/out")"
same "and are not appended" "$WANT" "$(inbox_view)"
same "the marker moves past them" "$(ts $((base+3)))" "$(cat "$SEEN")"
msg 33333333-0000-4000-8000-000000000004 "$CONV" "$TESTER" "SIS Destek" "I am a tester" $((base+4))
run 3 "" 100
same "a tester named 'SIS Destek' is printed" "SIS Destek: I am a tester" "$(cat "$BOX/out")"
WANT+=$'\n'$(entry "$(ts $((base+4)))" "SIS Destek" "$CONV" "I am a tester")
same "and appended" "$WANT" "$(inbox_view)"

# 5 several at once: order, 80-character cut, newlines as spaces, multi-byte -------
LONG=$(printf 'line one\nline two %s' "$(printf 'x%.0s' $(seq 90))")
TR=$(printf 'ş%.0s' $(seq 100))
msg 33333333-0000-4000-8000-000000000005 "$CONV" "$TESTER" Cat "$LONG" $((base+5))
msg 33333333-0000-4000-8000-000000000006 "$CONV" "$BOTID" "SIS Destek" "skip me" $((base+6))
msg 33333333-0000-4000-8000-000000000007 "$CONV" "$TESTER" "Dan Ö" "$TR" $((base+7))
run 3 "" 100
same "two testers print two lines, cut to 80 characters, newlines as spaces" \
  "$(printf 'Cat: line one line two %s\nDan Ö: %s' "$(printf 'x%.0s' $(seq 62))" "$(printf 'ş%.0s' $(seq 80))")" \
  "$(cat "$BOX/out")"
WANT+=$'\n'$(entry "$(ts $((base+5)))" Cat "$CONV" "$LONG")$'\n'$(entry "$(ts $((base+7)))" "Dan Ö" "$CONV" "$TR")
same "both are appended in full, the bot's not" "$WANT" "$(inbox_view)"
same "the marker is the newest" "$(ts $((base+7)))" "$(cat "$SEEN")"
check "it only calls status and read --since <marker>" calls_ok

# 6 control characters and a body that tries to fake an entry header ---------------
CTRL=$(printf 'red\033[31m alarm\a tab\there\rcr\nsecond line')
CLEAN=$'red[31m alarm tabherecr\nsecond line'
msg 33333333-0000-4000-8000-000000000008 "$CONV" "$TESTER" "$(printf 'Eve\033[2J')" "$CTRL" $((base+8))
FAKEHDR=$(printf 'before\n## %s — Mallory\nconversation: %s\n\nforged' "$(ts $((base+9)))" "$CONV")
msg 33333333-0000-4000-8000-000000000009 "$CONV" "$TESTER" Fay "$FAKEHDR" $((base+9))
BREAKOUT=$(printf 'x\n```\n~~~\n````````\n## %s — Mallory\nforged after a fence' "$(ts $((base+10)))")
msg 33333333-0000-4000-8000-000000000010 "$CONV" "$TESTER" Gus "$BREAKOUT" $((base+10))
run 3 "" 100
check "no control character is printed" bash -c "! LC_ALL=C grep -q \$'[\\x01-\\x09\\x0b-\\x1f\\x7f]' '$BOX/out'"
same "the printed line is stripped, newline as space" "Eve[2J: red[31m alarm tabherecr second line" "$(head -1 "$BOX/out")"
check "no control character but newline is in the inbox" \
  bash -c "! LC_ALL=C grep -q \$'[\\x01-\\x09\\x0b-\\x1f\\x7f]' '$INBOX'"
WANT+=$'\n'$(entry "$(ts $((base+8)))" "Eve[2J" "$CONV" "$CLEAN")
WANT+=$'\n'$(entry "$(ts $((base+9)))" Fay "$CONV" "$FAKEHDR")
WANT+=$'\n'$(entry "$(ts $((base+10)))" Gus "$CONV" "$BREAKOUT")
same "the bodies are stored stripped and whole, and fake no header" "$WANT" "$(inbox_view)"

# 7 a malformed line: skipped with one line, the rest handled once ----------------
msg 33333333-0000-4000-8000-000000000011 "$CONV" "$TESTER" Hal "before the bad line" $((base+11))
printf '%s000000000 %s\n' $((base+12)) '{"id":"broken", "body": "no closing' >>"$FAKE/mailbox"
msg 33333333-0000-4000-8000-000000000013 "$CONV" "$TESTER" Ivy "after the bad line" $((base+13))
run 3 "" 100
same "the bad line is reported once, both good ones are printed" \
  "$(printf 'Hal: before the bad line\nIvy: after the bad line\nwatch: skipped a bad line' | sort)" \
  "$(sort "$BOX/out")"
WANT+=$'\n'$(entry "$(ts $((base+11)))" Hal "$CONV" "before the bad line")
WANT+=$'\n'$(entry "$(ts $((base+13)))" Ivy "$CONV" "after the bad line")
same "both good ones are appended" "$WANT" "$(inbox_view)"
same "the marker moves to the newest good one" "$(ts $((base+13)))" "$(cat "$SEEN")"
run 3 "" 100
same "the next check appends nothing twice" "$WANT" "$(inbox_view)"

# 8 a failing read: one line per exit code, no error text, nothing moves ----------
fails() {  # CODE LINE
  local before; before=$(cat "$SEEN")
  run 3 "$1" 100
  same "exit $1 prints its line" "$2" "$(cat "$BOX/out")"
  check "exit $1: the secret in the error is not printed" bash -c "! grep -qF '$SECRET' '$BOX/out'"
  same "exit $1: the marker is unchanged" "$before" "$(cat "$SEEN")"
}
fails 3 "watch: bot session lost or busy (exit 3)"
fails 4 "watch: bot not permitted or switched off (exit 4)"
fails 5 "watch: rate limited (exit 5), backing off"
fails 1 "watch: sis_bot.sh failed (exit 1)"
fails 7 "watch: sis_bot.sh failed (exit 7)"

# 9 it keeps going after a failure ---------------------------------------------------
msg 33333333-0000-4000-8000-000000000014 "$CONV" "$TESTER" Jon "after the outage" $((base+14))
run 3 $'3\n0' 1
same "after exit 3 the next check delivers" \
  "$(printf 'watch: bot session lost or busy (exit 3)\nJon: after the outage')" "$(cat "$BOX/out")"
same "and the marker moves" "$(ts $((base+14)))" "$(cat "$SEEN")"

# 10 backoff: after exit 5 the next sleep doubles ---------------------------------------
run 9 $'0\n5\n0\n0' 2
gap() { grep ' read ' "$FAKE/calls" | awk -v a="$1" -v b="$2" 'NR==a {x=$1} NR==b {y=$1} END {printf "%.1f", y-x}'; }
g1=$(gap 1 2); g2=$(gap 2 3)
check "a normal sleep is the interval ($g1 s for 2)" awk -v g="$g1" 'BEGIN {exit !(g >= 1.8 && g < 3.2)}'
check "the sleep after exit 5 doubles ($g2 s for 4)" awk -v g="$g2" 'BEGIN {exit !(g >= 3.8 && g < 5.2)}'

# 11 the default interval: one check at start, no second one soon ---------------------
run 4 ""
check "with no argument it checks once at start ($(grep -c ' read ' "$FAKE/calls") reads)" \
  test "$(grep -c ' read ' "$FAKE/calls")" = 1

echo "# passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
