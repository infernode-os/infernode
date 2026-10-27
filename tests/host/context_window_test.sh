#!/bin/sh
#
# context_window_test.sh — a session is compacted before it outgrows its
# model's window, whatever the window.
#
# The scripted model reports a window of 40000 tokens (as SGLang's and
# vLLM's /v1/models do) and refuses a request longer than 30000 (as vLLM
# refuses one, "maximum context length is 30000 tokens").
#
#   - llmsrv, given no mark, takes it from the window the backend reports.
#   - One agent turn of many long reads passes the mark before it ends: it
#     is compacted in the middle, the step under way kept, and finishes.
#   - Told a window too large (-C 200000), llmsrv is refused, learns the
#     window from the refusal, compacts, and is answered.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

HERE="$ROOT/tests/host/agentloop"
WORK="$(mktemp -d)"
SERVER_PID=
EMU_PID=
SCRIPT=
cleanup() {
	[ -z "${KEEP:-}" ] || { mkdir -p "$KEEP"; cp "$WORK"/*.log "$KEEP"/ 2>/dev/null || true; }
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$ROOT/usr/agentloop" "$WORK"
}
trap cleanup EXIT HUP INT TERM

MOCK_WINDOW=40000 MOCK_HARDWINDOW=30000 python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/usr/agentloop"
mkdir -p "$ROOT/usr/agentloop"
python3 -c 'import sys
for i in range(1, 41):
    print("line %d of a page long enough that two dozen of them outgrow a window: %s" % (i, "0123456789abcdef" * 12))' > "$ROOT/usr/agentloop/big.txt"
python3 -c 'print(" ".join("word%d" % i for i in range(3500)))' > "$ROOT/usr/agentloop/long.txt"

SCRIPT="$ROOT/tests/inferno/.context-window-test.$$.sh"
cat > "$SCRIPT" <<EOS
#!/dis/sh.dis
load std
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 1
/dis/veltro/tools9p.dis read list &
sleep 1
/dis/veltro/veltrosrv.dis -p /usr/agentloop
id=\`{cat /mnt/veltro/new}
echo SCENARIO:long_turn go > /mnt/veltro/\$id/input
cat /mnt/veltro/\$id/text > /dev/null
echo '@@ long turn'
cat /mnt/veltro/\$id/text | tail -4
grep 'turn done' /mnt/veltro/\$id/log
for w in \`{cat /mnt/veltro/\$id/ctl} {
	if {~ \$w 'llm='*} { llm=\`{echo \$w | sed 's/^llm=//'} }
}
echo window \`{cat /mnt/llm/\$llm/window}
# Told the window is larger than it is.
llmsrv -m /mnt/llm2 -b openai -u http://127.0.0.1:$PORT/v1 -M mock -C 200000 &
sleep 1
lid=\`{cat /mnt/llm2/new}
echo '@@ overflow'
for q in 1 2 3 4 5 6 7 8 9 10 {
	cat /usr/agentloop/long.txt > /mnt/llm2/\$lid/ask
	echo answer \$q \`{cat /mnt/llm2/\$lid/ask}
}
echo window \`{cat /mnt/llm2/\$lid/window}
echo '@@ end'
echo DRIVER_DONE
EOS

OPENAI_API_KEY=test "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" </dev/null > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 240 ]; do
	grep -q '^DRIVER_DONE$' "$WORK/emu.log" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=
LOG="$WORK/emu.log"
grep -q '^DRIVER_DONE$' "$LOG" || { echo "FAIL: driver did not finish"; tail -30 "$LOG"; exit 1; }

section() { awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$LOG"; }
FAILED=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

section "long turn" | grep -q '^window 40000$' && ok "the window is the one the backend reports" ||
	bad "the window is the one the backend reports"
section "long turn" | grep -q '^Read them all.$' && ok "a turn that outgrows the mark finishes" ||
	bad "a turn that outgrows the mark finishes"
section "long turn" | grep -q 'stop=end_turn' && ok "it ends as the model ends it" || bad "it ends as the model ends it"
# compacted in the middle of the turn: a summary asked for while the turn's
# tool calls were still coming
python3 -I -c 'import json,sys
reqs=[json.loads(l) for l in open(sys.argv[1])]
s=[i for i,r in enumerate(reqs) if str(r["body"]["messages"][-1].get("content","")).startswith("Summarise the conversation")]
after=[r for r in reqs[s[0]+1:] if r.get("scenario")=="long_turn"] if s else []
sys.exit(0 if s and after else 1)' "$WORK/req.log" && ok "it is compacted in the middle, and goes on" ||
	bad "it is compacted in the middle, and goes on"
grep -q '"scenario": "overflow"' "$WORK/req.log" && first_overflow=1 || first_overflow=0
python3 -I -c 'import json,sys
reqs=[json.loads(l) for l in open(sys.argv[1])]
lt=[r for r in reqs if r.get("scenario")=="long_turn"]
sys.exit(0 if not any(r.get("scenario")=="overflow" and "SCENARIO:long_turn" in json.dumps(r["body"]) for r in reqs) else 1)' "$WORK/req.log" &&
	ok "the long turn never outgrew the window" || bad "the long turn never outgrew the window"

section overflow | grep -q '^answer 10 no scenario$' && ok "a session told too large a window is answered all along" ||
	{ bad "a session told too large a window is answered all along"; section overflow; }
section overflow | grep -q 'Error' && bad "no question was lost to the refusal" || ok "no question was lost to the refusal"
[ "$first_overflow" = 1 ] && ok "the backend refused one request" || bad "the backend refused one request"
section overflow | grep -q '^window 30000$' && ok "the window is learned from the refusal" ||
	bad "the window is learned from the refusal"

[ "$FAILED" -eq 0 ] || { tail -40 "$LOG"; echo "context_window_test: $FAILED failed"; exit 1; }
echo "context_window_test: PASS"
