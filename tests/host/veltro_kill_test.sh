#!/bin/sh
#
# veltro_kill_test.sh — the veltro command stopped, and what it asks.
#
# Against a scripted model (coordinator/mock.py) whose turn never ends by
# itself:
#   - the command killed (its process, as an interrupt kills it): the
#     harness it started is stopped with it; no agent process is left and
#     the model is asked nothing more.  It used to run on to the step
#     limit, with the gate off under -y.
#   - every process of the command killed by name, the one that watches
#     for that among them: the session it held is closed by veltrosrv, and
#     the model is asked nothing more.
#   - a request for approval is printed on one line, a carriage return in
#     the command written out (it drew another command over the one
#     asked about).
#   - -r takes a session's name, not a path.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltro.dis dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

HERE="$ROOT/tests/host/coordinator"
WORK="$(mktemp -d)"
SCRATCH="$ROOT/tmp/cokill.$$"
SERVER_PID=
EMU_PID=
SCRIPT=
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	[ -z "${KEEP:-}" ] || cp "$WORK"/*.log "$KEEP"/ 2>/dev/null || true
	rm -rf "$ROOT/usr/agentloop" "$ROOT/usr/inferno/veltro/sessions/scenarioslow-loop-go" \
		"$ROOT/usr/inferno/veltro/sessions/scenarioslow-loop-go-"* \
		"$ROOT/usr/inferno/veltro/sessions/scenariocr-exec-go" \
		"$ROOT/usr/inferno/veltro/sessions/scenariocr-exec-go-"* "$SCRATCH" "$WORK"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch" "$SCRATCH"
mkdir -p "$ROOT/usr/agentloop" "$SCRATCH/evil"
echo alpha > "$ROOT/usr/agentloop/a.txt"
echo 'SCENARIO:text_only go' > "$SCRATCH/evil/task"
T=/tmp/cokill.$$

SCRIPT="$ROOT/tests/inferno/.veltro-kill-test.$$.sh"
cat > "$SCRIPT" <<EOF2
#!/dis/sh.dis
load std
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 1
/dis/veltro/tools9p.dis read list write exec &
sleep 2

echo '@@ prompt'
/dis/veltro/veltro.dis -p /usr/agentloop 'SCENARIO:cr_exec go'
echo
echo '@@ resume'
/dis/veltro/veltro.dis -y -r ../../../..$T/evil
ls $T/evil

echo '@@ killed'
/dis/veltro/veltro.dis -y -p /usr/agentloop 'SCENARIO:slow_loop go' > /dev/null >[2=1] &
pid=\$apid
sleep 5
echo procs-before \`{ps | grep VeltroSrv | wc -l}
echo kill > /prog/\$pid/ctl
sleep 5
echo MARK1
sleep 5
echo MARK2
sleep 2
echo procs-after \`{ps | grep 'Veltro' | wc -l}

echo '@@ killed by name'
/dis/veltro/veltro.dis -y -p /usr/agentloop 'SCENARIO:slow_loop go' > /dev/null >[2=1] &
sleep 5
kill Veltro | sh
sleep 5
echo MARK3
sleep 5
echo MARK4
sleep 2
echo sessions:
ls /mnt/veltro
echo DRIVER_DONE
EOF2
chmod +x "$SCRIPT"

OPENAI_API_KEY=test "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" < /dev/null > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
# The model's requests, counted at each mark the driver prints.
i=0
for m in 1 2 3 4; do eval "N$m="; done
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 900 ]; do
	for m in 1 2 3 4; do
		if eval "[ -z \"\$N$m\" ]" && grep -q "^MARK$m\$" "$WORK/emu.log" 2>/dev/null; then
			eval "N$m=$(wc -l < "$WORK/req.log")"
		fi
	done
	grep -q '^DRIVER_DONE$' "$WORK/emu.log" 2>/dev/null && break
	sleep 0.2
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

LOG="$WORK/emu.log"
FAILED=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }
section() { awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$LOG"; }
grep -q '^DRIVER_DONE$' "$LOG" || { echo "FAIL: driver did not finish"; tail -40 "$LOG"; exit 1; }

if section prompt | grep -q '^veltro: allow exec rm -r /usr/agentloop/important\\rveltro: allow exec ls /tmp/veltro/scratch? \[y/N\]' &&
   ! section prompt | LC_ALL=C grep -q "$(printf '\r')"; then
	ok "the request for approval is one line, its carriage return written out"
else
	bad "the request for approval is one line, its carriage return written out"; section prompt | od -c | head -8
fi
if section resume | grep -q "is not a session's name" && ! section resume | grep -q 'resuming session' &&
   ! section resume | grep -q -E '/(context|transcript)$'; then
	ok "-r refuses a path"
else
	bad "-r refuses a path"
fi
if section killed | grep -q '^procs-before [1-9]'; then ok "the agent was running"; else bad "the agent was running"; fi
if [ -n "$N1" ] && [ "$N1" = "$N2" ]; then
	ok "the command killed, the model is asked nothing more ($N1 requests)"
else
	bad "the command killed, the model is asked nothing more ($N1 requests, then $N2)"
fi
if section killed | grep -q '^procs-after 0$'; then
	ok "and no agent process is left"
else
	bad "and no agent process is left ($(section killed | grep procs-after))"
fi
if [ -n "$N3" ] && [ "$N3" = "$N4" ]; then
	ok "every process of the command killed, the model is asked nothing more ($N3 requests)"
else
	bad "every process of the command killed, the model is asked nothing more ($N3 requests, then $N4)"
fi
if section "killed by name" | sed -n '/^sessions:$/,$p' | grep -q '/[0-9][0-9]*$'; then
	bad "and its session is closed"
else
	ok "and its session is closed"
fi

[ "$FAILED" -eq 0 ] || { tail -40 "$LOG"; echo "veltro_kill_test: $FAILED failed"; exit 1; }
echo "veltro_kill_test: PASS"
