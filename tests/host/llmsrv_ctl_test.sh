#!/bin/sh
#
# llmsrv_ctl_test.sh — what llmsrv's control files answer is what happened.
#
# llmsrv against the scripted model (tests/host/agentloop/mock_openai.py),
# driven through /mnt/llm as a harness drives it.
#
#   new          every read made a session, and cat reads until a read
#                returns nothing: each cat left one nobody had the name
#                of, and after 64 the next was "cannot allocate session".
#                One session for one open.
#   temperature  "abc" was read as 0 and taken.
#   ctl          "autocompact5" was taken as autocompact 5.
#   model        any text was taken as a model's name.
#   tools        a document that is no list of tools was "written": the
#                session went on with the tools before it.  It answers no
#                prompt until tools are written that parse, and a read of
#                the file says why.
#   compact      was begun over a prompt already written.
#   stream       a second read after a generation's end never returned;
#   ask          nor did a second reader of one turn.
#   close        left the generation running: a reader that had begun
#                before the close was given its reply.  It is stopped, and
#                the reader told the session has closed.
#   cancel       answered that it had stopped a generation it could not
#                stop (here: a llmsrv with no /prog to stop it through),
#                and close then delivers nothing of it either.
#
set -e

. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
[ -f "$ROOT/dis/llmsrv.dis" ] || { echo "SKIP: dis/llmsrv.dis not built"; exit 77; }

HERE="$ROOT/tests/host/agentloop"
WORK="$(mktemp -d)"
SERVER_PID=
SCRIPT=
SCRATCH="$ROOT/tmp/llmsrv-ctl.$$"
cleanup() {
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$WORK" "$SCRATCH"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

mkdir -p "$SCRATCH"
T=/tmp/llmsrv-ctl.$$
SCRIPT="$ROOT/tests/inferno/.llmsrv-ctl.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
bind -a '#I' /net
ndb/cs
# session names come from /dev/random, which the emulator fills slowly:
# a hundred sessions are wanted here, not a hundred good names
bind /dev/notquiterandom /dev/random
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 2

id=\`{cat /mnt/llm/new}

# settings that are not settings
if {echo abc > /mnt/llm/\$id/temperature} {echo R temp-abc taken} {echo R temp-abc refused}
if {echo 0.5 > /mnt/llm/\$id/temperature} {echo R temp-half taken} {echo R temp-half refused}
echo R temp \`{cat /mnt/llm/\$id/temperature}
if {echo autocompact5 > /mnt/llm/\$id/ctl} {echo R autocompact5 taken} {echo R autocompact5 refused}
if {echo autocompact 5 > /mnt/llm/\$id/ctl} {echo R autocompact-5 taken} {echo R autocompact-5 refused}
if {echo autocompact auto > /mnt/llm/\$id/ctl} {echo R autocompact-auto taken} {echo R autocompact-auto refused}
if {echo 'two words' > /mnt/llm/\$id/model} {echo R model-words taken} {echo R model-words refused}
if {echo 'gpt-oss:20b' > /mnt/llm/\$id/model} {echo R model-name taken} {echo R model-name refused}
echo mock > /mnt/llm/\$id/model
echo R model \`{cat /mnt/llm/\$id/model}

# tools that are no tools
echo '[{"name":' > /mnt/llm/\$id/tools
echo R badtools-read \`{cat /mnt/llm/\$id/tools}
echo 'SCENARIO:text_only go' > /mnt/llm/\$id/ask
echo R badtools-ask \`{cat /mnt/llm/\$id/ask}
echo '[{"name":"t","description":"d","parameters":{"type":"object"}}]' > /mnt/llm/\$id/tools
echo R goodtools-read \`{cat /mnt/llm/\$id/tools}
echo 'SCENARIO:text_only go' > /mnt/llm/\$id/ask
echo R goodtools-ask \`{cat /mnt/llm/\$id/ask}

# a compaction over a prompt already written
echo 'SCENARIO:text_only go' > /mnt/llm/\$id/ask
if {echo x > /mnt/llm/\$id/compact} {echo R compact-pending taken} {echo R compact-pending refused}
echo R compact-ask \`{cat /mnt/llm/\$id/ask}
if {echo x > /mnt/llm/\$id/compact} {echo R compact-idle taken} {echo R compact-idle refused}

# stream: a second read after the end
id=\`{cat /mnt/llm/new}
echo 'SCENARIO:text_only go' > /mnt/llm/\$id/ask
cat /mnt/llm/\$id/ask > /dev/null
cat /mnt/llm/\$id/stream > /dev/null
echo R stream1 ended
{cat /mnt/llm/\$id/stream > /dev/null; echo R stream2 ended} &

# ask: two readers of one turn (the model takes 3 s)
id=\`{cat /mnt/llm/new}
echo 'SCENARIO:steer go' > /mnt/llm/\$id/ask
{cat /mnt/llm/\$id/ask > /dev/null; echo R askreader1 ended} &
{cat /mnt/llm/\$id/ask > /dev/null; echo R askreader2 ended} &

# cancel with nothing running, and of a generation (the model takes 20 s)
id=\`{cat /mnt/llm/new}
if {echo cancel > /mnt/llm/\$id/ctl} {echo R cancel-idle ok} {echo R cancel-idle error}
echo 'SCENARIO:slow go' > /mnt/llm/\$id/ask
{cat /mnt/llm/\$id/ask > $T/cancel.out >[2=1]; echo R cancelreader ended} &
sleep 2
if {echo cancel > /mnt/llm/\$id/ctl} {echo R cancel-running ok} {echo R cancel-running error}

# close during a generation
idc=\`{cat /mnt/llm/new}
echo 'SCENARIO:slow go' > /mnt/llm/\$idc/ask
{cat /mnt/llm/\$idc/ask > $T/close.out >[2=1]; echo R closereader ended} &
sleep 2
if {echo close > /mnt/llm/\$idc/ctl} {echo R close ok} {echo R close error}
sleep 6
echo R cancel-out \`{cat $T/cancel.out}
echo R close-out \`{cat $T/close.out}
echo 'SCENARIO:text_only go' > /mnt/llm/\$id/ask
echo R after-cancel \`{cat /mnt/llm/\$id/ask}

# new: seventy cats, then a session is still to be had
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 {
	cat /mnt/llm/new > /dev/null >[2=1]
}
idn=\`{cat /mnt/llm/new >[2] /dev/null}
echo R new71 \$#idn

# a llmsrv that cannot stop a generation: it has no /prog
unmount /prog
llmsrv -m $T/llm2 -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 2
id=\`{cat $T/llm2/new}
# (with the tool it calls, the scripted model's slow step is a reply to see)
echo '[{"name":"read","description":"d","parameters":{"type":"object"}}]' > $T/llm2/\$id/tools
echo 'SCENARIO:steer go' > $T/llm2/\$id/ask
{cat $T/llm2/\$id/ask > $T/noprog.out >[2=1]; echo R noprogreader ended} &
sleep 1
if {echo cancel > $T/llm2/\$id/ctl >[2] /dev/null} {echo R noprog-cancel ok} {echo R noprog-cancel error}
echo close > $T/llm2/\$id/ctl
sleep 6
echo R noprog-out \`{cat $T/noprog.out}
echo R done
echo halt > '#c/sysctl'
EOF

LOG="$WORK/log"
cd "$ROOT"
OPENAI_API_KEY=test with_timeout 100 "$EMU" -c1 -r"$ROOT" /dis/sh.dis \
	"/tests/inferno/$(basename "$SCRIPT")" </dev/null > "$LOG" 2>&1 || true

failed=0
# want LINE-PREFIX WHAT : the log has a line beginning so
want() {
	if grep -q "^$1" "$LOG"; then echo "PASS: $2"; else echo "FAIL: $2 (no line: $1)"; failed=1; fi
}
# wantnot PATTERN WHAT
wantnot() {
	if grep -q "$1" "$LOG"; then echo "FAIL: $2"; failed=1; else echo "PASS: $2"; fi
}

want 'R done' "the driver finished"
want 'R new71 1$' "a session is to be had after seventy cats of new"
want 'R temp-abc refused' "temperature abc is refused"
want 'R temp-half taken' "temperature 0.5 is taken"
want 'R temp 0.50' "and reads back"
want 'R autocompact5 refused' "ctl autocompact5 is refused"
want 'R autocompact-5 taken' "ctl autocompact 5 is taken"
want 'R autocompact-auto taken' "ctl autocompact auto is taken"
want 'R model-words refused' "a model's name with a blank is refused"
want 'R model-name taken' "a model's name is taken"
want 'R model mock' "and reads back"
want 'R badtools-read error: ' "a read of tools says why the last were refused"
want 'R badtools-ask Error: tools: ' "the session answers no prompt with tools that did not parse"
want 'R goodtools-read$' "tools that parse clear it"
want 'R goodtools-ask .*Hello from the mock' "and the model is asked again"
want 'R compact-pending refused' "a compaction is not begun over a prompt already written"
want 'R compact-ask .*Hello from the mock' "the prompt is answered"
want 'R compact-idle taken' "a compaction between turns is taken"
want 'R stream1 ended' "the stream ends with its generation"
want 'R stream2 ended' "a second read of the stream after the end returns"
want 'R askreader1 ended' "a reader of ask is answered"
want 'R askreader2 ended' "and a second reader of the same turn"
want 'R cancel-idle ok' "cancel with nothing running is not an error"
want 'R cancel-running ok' "cancel stops a generation"
want 'R cancelreader ended' "its reader is answered"
want 'R cancel-out STOP:end_turn' "with the turn's end"
want 'R after-cancel .*Hello from the mock' "the session answers after a cancel"
want 'R close ok' "close is taken during a generation"
want 'R closereader ended' "its reader is answered at once"
want 'R close-out .*session closed' "and told the session has closed"
want 'R noprog-cancel error' "cancel says so when it cannot stop the generation"
want 'R noprogreader ended' "a closed session's reader is answered when the generation ends"
want 'R noprog-out .*session closed' "with the close, not the reply"
wantnot 'Too late' "nothing of a closed session's generation is delivered"
wantnot 'R noprog-out .*STOP' "nor of one that could not be stopped"

if [ "$failed" = 0 ]; then echo "ALL PASS"; exit 0; fi
echo "--- log"
tail -60 "$LOG"
exit 1
