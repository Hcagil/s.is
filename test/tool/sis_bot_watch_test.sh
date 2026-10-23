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
# Also: a picture (body ending "[image <its own id>]") prints only
# "PICTURE from <sender>, id <id>" and calls `attachments <id>`; a foreign uuid is
# plain text; a failed download prints "will retry" twice (batch stopped, cursor
# kept, count in .private/bot-watch.retries, no inbox entry) and "gave up" on
# try 3 (retry file deleted, entry written once, cursor moves); the count resets
# on success and for another id; the heartbeat (ISO UTC, written only after a
# successful poll, never on exit 3/4/5/other or an unknown bot id);
# SIS_WATCH_INTERVAL, the argument beating it, SIS_WATCH_ROOT, --self-test; the
# lock (a second copy exits 1 with the line and never reads, a kill -9'd holder
# frees it, the supervisor holds it while its child polls); the supervisor
# restarting a crashed loop after 5 s then 10 s with the "poll loop ended" line.
# Replies: one "reply to: <original>" line per reply entry and " (reply to: ...)" on
# its printed line (newlines as spaces, control characters stripped, 80-character cut,
# multi-byte too, "(message not found)" for null); a non-reply entry byte-for-byte unchanged.
# Not covered (needs 5+ minutes): the 300 s cap and the reset after a long run.
set -euo pipefail
cd "$(dirname "$0")/../.."

BOX=$(mktemp -d); BG=
TRAP() { [ -z "$BG" ] || kill -9 -- "-$BG" 2>/dev/null || :; rm -rf "$BOX"; }; trap TRAP EXIT
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
# prints "ok user=<bot id> session active", exactly as the real one. `read`
# exit codes come one per read call from
# $FAKE/exits (missing line: 0). Mailbox lines are "<epoch> <raw line>"; a read
# prints the raw lines whose epoch is after --since.
cat >"$FAKE/sis_bot.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
d=$(dirname "$0")
printf '%s %s\n' "$(date +%s.%N)" "$*" >>"$d/calls"
sleep 0.2
if [ "$*" = status ]; then
  [ -n "${FAKE_NO_ID:-}" ] && { echo "ok session active"; exit 0; }  # no user=: bot id unknown
  echo "ok user=$FAKE_BOT_ID session active"; exit 0  # as tool/sis_bot.sh prints it
fi
if [ "${1:-}" = attachments ]; then  # exit codes one per attachments call from $d/att_exits
  n=$(grep -c ' attachments ' "$d/calls")
  code=$(sed -n "${n}p" "$d/att_exits" 2>/dev/null); code=${code:-0}
  [ "$code" = 0 ] && mkdir -p ".private/bot-attachments/$2" && : >".private/bot-attachments/$2/photo.jpg"
  exit "$code"
fi
if [ -n "${FAKE_CRASH:-}" ]; then  # kill -9 the poll loop: the topmost watcher below the supervisor
  p=$PPID; victim=
  while [ "$p" -gt 1 ]; do
    a=$(ps -o args= -p "$p") || break
    case $a in *--supervise*) break ;; *sis_bot_watch.sh*) victim=$p ;; esac
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  [ -n "$victim" ] && kill -9 "$victim"
  exit 0
fi
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
  rm -f "$FAKE/calls"; printf '%s' "$exits" >"$FAKE/exits"; printf '%s' "${ATT:-}" >"$FAKE/att_exits"
  RC=0
  (cd "$BOX" && umask 022 && SIS_BOT_CMD="$FAKE/sis_bot.sh" timeout "$secs" "$W" "$@") >"$BOX/out" 2>&1 || RC=$?
  touch "$FAKE/calls"
}
calls_ok() { ! grep -vE '^[0-9.]+ (status|read --since [^ ]+|attachments [0-9a-f-]{36})$' "$FAKE/calls"; }
att_calls() { grep ' attachments ' "$FAKE/calls" | cut -d' ' -f2-; }
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
hex() { printf '%s' "$1" | od -v -An -tx1 | tr -d ' \n'; }
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
# the newest line malformed: reported once, not again every round
printf '%s500000000 %s\n' $((base+13)) '{"id":"broken-last", "body": "cut off' >>"$FAKE/mailbox"
run 3 "" 100
same "a malformed newest line is reported" "watch: skipped a bad line" "$(cat "$BOX/out")"
run 3 "" 100
same "and not again on the next round" "" "$(cat "$BOX/out")"
same "nothing was appended for it" "$WANT" "$(inbox_view)"
sed -i '/broken-last/d' "$FAKE/mailbox"  # keep later sections independent of this one

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

# 9b pictures: a body ending "[image <its own id>]" -----------------------------------
I15=33333333-0000-4000-8000-000000000015; I16=33333333-0000-4000-8000-000000000016
I17=33333333-0000-4000-8000-000000000017; OTHER=44444444-0000-4000-8000-0000000000ff
msg "$I15" "$CONV" "$TESTER" Kim "[image $I15]" $((base+15))
msg "$I16" "$CONV" "$TESTER" Kim $'look at this\n'"[image $I16]" $((base+16))
msg "$I17" "$CONV" "$TESTER" Kim "[image $OTHER]" $((base+17))  # not its own id: plain text
run 3 "" 100
same "each picture prints exactly one PICTURE line, a foreign uuid none" \
  "$(printf 'PICTURE from Kim, id %s\nPICTURE from Kim, id %s' "$I15" "$I16")" "$(grep PICTURE "$BOX/out")"
same "each picture is downloaded with attachments <id>, once" \
  "$(printf 'attachments %s\nattachments %s' "$I15" "$I16")" "$(att_calls)"
same "a picture prints only its PICTURE line; the foreign uuid prints as text" \
  "$(printf 'PICTURE from Kim, id %s\nPICTURE from Kim, id %s\nKim: [image %s]' "$I15" "$I16" "$OTHER")" \
  "$(cat "$BOX/out")"
WANT+=$'\n'$(entry "$(ts $((base+14)))" Jon "$CONV" "after the outage")  # section 9's
WANT+=$'\n'$(entry "$(ts $((base+15)))" Kim "$CONV" "[image $I15]")
WANT+=$'\n'$(entry "$(ts $((base+16)))" Kim "$CONV" $'look at this\n'"[image $I16]")
WANT+=$'\n'$(entry "$(ts $((base+17)))" Kim "$CONV" "[image $OTHER]")
same "and appended unchanged, once each" "$WANT" "$(inbox_view)"
same "the marker is the newest" "$(ts $((base+17)))" "$(cat "$SEEN")"
check "it only calls status, read --since <marker> and attachments <id>" calls_ok

# 9c a failing download: retried twice, given up on the third try ----------------------
RETRY="$BOX/.private/bot-watch.retries"
I18=33333333-0000-4000-8000-000000000018; I19=33333333-0000-4000-8000-000000000019
I20=33333333-0000-4000-8000-000000000020
msg "$I18" "$CONV" "$TESTER" Lea "before the picture" $((base+18))
msg "$I19" "$CONV" "$TESTER" Lea "[image $I19]" $((base+19))
msg "$I20" "$CONV" "$TESTER" Lea "after the picture" $((base+20))
WANT18=$WANT$'\n'$(entry "$(ts $((base+18)))" Lea "$CONV" "before the picture")
for n in 1 2; do
  ATT=1 run 5 "" --once
  same "try $n: PICTURE, then 'will retry'; the batch stops" \
    "$(printf 'Lea: before the picture\nPICTURE from Lea, id %s\nwatch: picture download failed for %s, will retry' "$I19" "$I19" | tail -n $((n == 1 ? 3 : 2)))" \
    "$(cat "$BOX/out")"
  same "try $n: the retry file counts it" "$I19 $n" "$(cat "$RETRY" 2>/dev/null)"
  same "try $n: the cursor stays on the last handled message" "$(ts $((base+18)))" "$(cat "$SEEN")"
  same "try $n: no inbox entry for the picture yet" "$WANT18" "$(inbox_view)"
done
same "the retry reads from the kept cursor" "read --since $(ts $((base+18)))" "$(first_read)"
ATT=1 run 5 "" --once
same "try 3: PICTURE, then 'gave up', then the rest of the batch" \
  "$(printf 'PICTURE from Lea, id %s\nwatch: picture download gave up for %s\nLea: after the picture' "$I19" "$I19" | sort)" \
  "$(sort "$BOX/out")"
check "try 3: the retry file is deleted" test ! -e "$RETRY"
WANT=$WANT18$'\n'$(entry "$(ts $((base+19)))" Lea "$CONV" "[image $I19]")$'\n'$(entry "$(ts $((base+20)))" Lea "$CONV" "after the picture")
same "try 3: the picture is in the inbox once, then the rest" "$WANT" "$(inbox_view)"
same "try 3: the cursor moves past it" "$(ts $((base+20)))" "$(cat "$SEEN")"
run 5 "" --once
same "the next poll prints nothing" "" "$(cat "$BOX/out")"
same "and appends nothing twice" "$WANT" "$(inbox_view)"

# 9d the retry count resets on success and for another id -------------------------------
I21=33333333-0000-4000-8000-000000000021; I22=33333333-0000-4000-8000-000000000022
msg "$I21" "$CONV" "$TESTER" Max "[image $I21]" $((base+21))
ATT=1 run 5 "" --once
same "a failed try counts 1" "$I21 1" "$(cat "$RETRY" 2>/dev/null)"
ATT=0 run 5 "" --once
same "the next try prints PICTURE again and succeeds" \
  "PICTURE from Max, id $I21" "$(cat "$BOX/out")"
check "success clears the count" bash -c "! grep -qF '$I21' '$RETRY' 2>/dev/null"
WANT+=$'\n'$(entry "$(ts $((base+21)))" Max "$CONV" "[image $I21]")
same "it is appended once" "$WANT" "$(inbox_view)"
printf '%s 2\n' "$OTHER" >"$RETRY"  # a stale count for another id
msg "$I22" "$CONV" "$TESTER" Max "[image $I22]" $((base+22))
ATT=1 run 5 "" --once
same "another id's count is not inherited (first try, not give up)" \
  "$(printf 'PICTURE from Max, id %s\nwatch: picture download failed for %s, will retry' "$I22" "$I22")" "$(cat "$BOX/out")"
same "the count restarts at 1 for it" "$I22 1" "$(cat "$RETRY" 2>/dev/null)"
ATT=0 run 5 "" --once
WANT+=$'\n'$(entry "$(ts $((base+22)))" Max "$CONV" "[image $I22]")
same "then it is delivered once" "$WANT" "$(inbox_view)"
same "and the cursor moves to it" "$(ts $((base+22)))" "$(cat "$SEEN")"

# 9e heartbeat: ISO UTC time, only after a successful poll --------------------------------
HB="$BOX/.orchestra/bot-watch.heartbeat"
hb_fresh() {
  local h e; h=$(cat "$HB" 2>/dev/null) || return 1
  [[ $h =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  e=$(date -u -d "$h" +%s) && [ $(( $(date +%s) - e )) -le 10 ] && [ $(( e - $(date +%s) )) -le 1 ]
}
rm -f "$HB"; run 5 "" --once
check "a successful poll writes the heartbeat as YYYY-MM-DDTHH:MM:SSZ, now ($(cat "$HB" 2>/dev/null))" hb_fresh
same "the heartbeat is one line, no temp file left beside it" "bot-watch.heartbeat 1" \
  "$(ls -A "$BOX/.orchestra" | tr '\n' ' ')$(grep -c '' "$HB")"
rm -f "$HB"; FAKE_NO_ID=1 run 5 "" --once
check "no heartbeat when the bot id is unknown" test ! -e "$HB"
for c in 3 4 5 7; do
  rm -f "$HB"; run 5 "$c" --once
  check "no heartbeat after a read exit $c" test ! -e "$HB"
done
I23=33333333-0000-4000-8000-000000000023
msg "$I23" "$CONV" "$TESTER" Ned "late" $((base+23))
rm -f "$HB"; run 5 "" --once
WANT+=$'\n'$(entry "$(ts $((base+23)))" Ned "$CONV" "late")
same "a poll with a message delivers it" "$WANT" "$(inbox_view)"
check "and writes the heartbeat" hb_fresh

# 9f interval from SIS_WATCH_INTERVAL, the argument wins; SIS_WATCH_ROOT ---------------------
SIS_WATCH_INTERVAL=1 run 3 ""
check "SIS_WATCH_INTERVAL=1 with no argument polls again ($(grep -c ' read ' "$FAKE/calls") reads in 3 s)" \
  test "$(grep -c ' read ' "$FAKE/calls")" -ge 2
SIS_WATCH_INTERVAL=1 run 3 "" 100
check "an argument beats SIS_WATCH_INTERVAL ($(grep -c ' read ' "$FAKE/calls") reads)" \
  test "$(grep -c ' read ' "$FAKE/calls")" = 1
ROOT2=$(mktemp -d)
SIS_WATCH_ROOT=$ROOT2 run 5 "" --once
check "SIS_WATCH_ROOT moves the cursor file" test -s "$ROOT2/.private/tester-inbox.seen"
rm -rf "$ROOT2"
(cd "$BOX" && SIS_BOT_CMD="$FAKE/sis_bot.sh" timeout 60 "$W" --self-test) >"$BOX/out" 2>&1 && st=0 || st=$?
same "--self-test passes offline" 0 "$st"

# 9g the lock: one copy only; a dead holder frees it -------------------------------------------
LOCKRE='^watch: already running \(lock .*\); this copy exits$'
start_bg() {  # ARGS...: a watcher in its own process group; pid in BG
  rm -f "$FAKE/calls"; : >"$FAKE/exits"; : >"$FAKE/att_exits"
  (cd "$BOX" && SIS_BOT_CMD="$FAKE/sis_bot.sh" exec setsid "$W" "$@") >"$BOX/bg.out" 2>&1 &
  BG=$!
}
second() {  # a second --once copy: stderr in $BOX/err, exit code in RC2, its calls in $BOX/calls2
  local before; before=$(grep -c '' "$FAKE/calls" 2>/dev/null || echo 0)
  RC2=0; (cd "$BOX" && SIS_BOT_CMD="$FAKE/sis_bot.sh" timeout 10 "$W" --once) >/dev/null 2>"$BOX/err" || RC2=$?
  tail -n +$((before + 1)) "$FAKE/calls" >"$BOX/calls2" 2>/dev/null || :
}
start_bg 100; sleep 1.5
second
same "a second start exits 1" 1 "$RC2"
check "and says so on stderr ($(cat "$BOX/err"))" grep -qE "$LOCKRE" "$BOX/err"
check "and never reads" bash -c "! grep -q ' read ' '$BOX/calls2'"
kill -9 "$BG" 2>/dev/null || :; wait "$BG" 2>/dev/null || :
second
same "after the holder is killed (kill -9) a new copy runs" 0 "$RC2"
check "and is not told it is running" bash -c "! grep -q 'already running' '$BOX/err'"
kill -9 -- "-$BG" 2>/dev/null || :

start_bg --supervise 100; sleep 1.5
check "under --supervise the child polls (the supervisor's lock does not stop it)" grep -q ' read ' "$FAKE/calls"
second
same "a second start beside the supervisor exits 1" 1 "$RC2"
check "with the lock line" grep -qE "$LOCKRE" "$BOX/err"
kill -9 -- "-$BG" 2>/dev/null || :; wait "$BG" 2>/dev/null || :

# 9h the supervisor restarts a crashed loop with a doubling wait ------------------------------
rm -f "$FAKE/calls"
(cd "$BOX" && FAKE_CRASH=1 SIS_BOT_CMD="$FAKE/sis_bot.sh" timeout 8.5 "$W" --supervise 100) >"$BOX/out" 2>&1 || :
touch "$FAKE/calls"
same "each crash is reported with the exit code and the wait, 5 s then 10 s" \
  "$(printf 'watch: poll loop ended (exit 137), restarting in 5s\nwatch: poll loop ended (exit 137), restarting in 10s')" \
  "$(grep 'poll loop ended' "$BOX/out" || :)"
g=$({ grep ' read ' "$FAKE/calls" || :; } | awk 'NR==1 {x=$1} NR==2 {y=$1} END {printf "%.1f", (NR < 2 ? -1 : y-x)}')
check "the loop is restarted after 5 s ($g s between the two reads)" awk -v g="$g" 'BEGIN {exit !(g >= 4.8 && g < 6.5)}'

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

# 12 replies: "reply to: <text>" in the entry and on the printed line -------------------
rmsg() {  # ID SENDER_NAME BODY EPOCH REPLY_TO REPLY_BODY_JSON -> one mailbox line, as `read` prints a reply
  printf '%s000000000 %s\n' "$4" "$(jq -nc --arg id "$1" --arg c "$CONV" --arg u "$TESTER" --arg s "$2" --arg b "$3" \
    --arg t "$(ts "$4")" --arg r "$5" --argjson rb "$6" '{id:$id, conversation_id:$c, sender_id:$u, sender_name:$s,
                           body:$b, created_at:$t, reply_to:$r, reply_body:$rb}')" >>"$FAKE/mailbox"
}
rb=$(( $(date -d "$(cat "$SEEN")" +%s) + 2 ))
ORIG=44444444-0000-4000-8000-000000000001
R80=$(printf 'r%.0s' $(seq 100)); RTR=$(printf 'ş%.0s' $(seq 100))
rmsg 44444444-0000-4000-8000-000000000011 Bob "short answer" $((rb+1)) "$ORIG" '"the original"'
rmsg 44444444-0000-4000-8000-000000000012 Bob "long answer" $((rb+2)) "$ORIG" "$(jq -n --arg v "$R80" '$v')"
rmsg 44444444-0000-4000-8000-000000000013 Bob "multi answer" $((rb+3)) "$ORIG" "$(jq -n --arg v $'first line\nsecond line\n## 2030-01-01 — Mallory' '$v')"
rmsg 44444444-0000-4000-8000-000000000014 Bob "lost answer" $((rb+4)) 44444444-0000-4000-8000-0000000000ff null
rmsg 44444444-0000-4000-8000-000000000015 Bob "ctrl answer" $((rb+5)) "$ORIG" "$(jq -n --arg v $'red\e[31m bell\a' '$v')"
rmsg 44444444-0000-4000-8000-000000000016 Bob "tr answer" $((rb+6)) "$ORIG" "$(jq -n --arg v "$RTR" '$v')"
msg 44444444-0000-4000-8000-000000000017 "$CONV" "$TESTER" Bob $'plain\nafter replies' $((rb+7))
before=$(stat -c %s "$INBOX")
run 3 "" 100
same "a reply prints '<sender>: <text> (reply to: <original, one line, 80 chars>)'; a non-reply line is unchanged" \
  "$(printf 'Bob: short answer (reply to: the original)\nBob: long answer (reply to: %s)\nBob: multi answer (reply to: first line second line ## 2030-01-01 — Mallory)\nBob: lost answer (reply to: (message not found))\nBob: ctrl answer (reply to: red[31m bell)\nBob: tr answer (reply to: %s)\nBob: plain after replies' \
     "$(printf 'r%.0s' $(seq 80))" "$(printf 'ş%.0s' $(seq 80))")" \
  "$(cat "$BOX/out")"
NEW=$(tail -c +$((before + 1)) "$INBOX")
same "each reply entry has exactly one 'reply to:' line, in its own entry; none in the non-reply entry" \
  "$(printf '%s\n' "## $(ts $((rb+1))) — Bob" "reply to: the original" \
     "## $(ts $((rb+2))) — Bob" "reply to: $(printf 'r%.0s' $(seq 80))" \
     "## $(ts $((rb+3))) — Bob" "reply to: first line second line ## 2030-01-01 — Mallory" \
     "## $(ts $((rb+4))) — Bob" "reply to: (message not found)" \
     "## $(ts $((rb+5))) — Bob" "reply to: red[31m bell" \
     "## $(ts $((rb+6))) — Bob" "reply to: $(printf 'ş%.0s' $(seq 80))" \
     "## $(ts $((rb+7))) — Bob")" \
  "$(printf '%s\n' "$NEW" | grep -E '^(## |reply to)')"
same "a reply entry: header, conversation, the reply line, then the body block" \
  "$(printf '## %s — Bob\nconversation: %s\nreply to: the original\n\n```\nshort answer\n```\n' "$(ts $((rb+1)))" "$CONV")" \
  "$(printf '%s\n' "$NEW" | sed -n 1,7p)"
same "a non-reply entry is byte-for-byte the old format" \
  "$(printf '## %s — Bob\nconversation: %s\n\n```\nplain\nafter replies\n```\n\nEND' "$(ts $((rb+7)))" "$CONV")" \
  "$(tail -c +$((before + 1)) "$INBOX" | sed -n '/^## '"$(ts $((rb+7)))"'/,$p'; printf END)"
same "the reply text never opens a header line of its own" 7 "$(printf '%s\n' "$NEW" | grep -c '^## ')"

echo "# passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
