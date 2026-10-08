#!/bin/sh
#
# agentloop_characterization_test.sh — pin what the Veltro agent loops do.
#
# The agent loop is written out in veltro.b (agentloop) and lucibridge.b
# (agentturn).  Before either is moved, this test records what each does
# against a scripted model, and fails if that changes.  It runs the real
# loops, the real llmsrv and llmclient, and the real tools: only the model
# is scripted (agentloop/mock_openai.py), so the test sees exactly what each
# loop sends back to the model after every tool call, and what it shows the
# user.
#
# Each scenario runs in a fresh emulator, through each front end.  The
# results are compared with tests/host/agentloop/golden/<frontend>-<scenario>.txt.
#
#	tests/host/agentloop_characterization_test.sh          compare
#	UPDATE=1 tests/host/agentloop_characterization_test.sh rewrite the golden files
#	tests/host/agentloop_characterization_test.sh two_reads  one scenario
#
# A difference is not necessarily a bug: it is a change in what the model
# sees, which is what this test exists to make visible.  Update the golden
# files only for a change that is meant.

set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltro.dis dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/lucibridge.dis dis/luciuisrv.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

HERE="$ROOT/tests/host/agentloop"
GOLDEN="$HERE/golden"
UPDATE=${UPDATE:-0}

SCENARIOS="text_only single_read text_and_tool two_reads dup_read dup_in_batch
big_output unknown_tool error_streak say write_then_read approval_deny step_cap"
[ $# -gt 0 ] && SCENARIOS="$*"

TOOLS="read list write say"

WORK="$(mktemp -d)"
SERVER_PID=
EMU_PID=
SCRIPT=
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$ROOT/usr/agentloop"
	[ "${KEEP:-0}" = 1 ] && echo "work kept in $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

# Run one emulator script until it prints DRIVER_DONE (the emulator does not
# exit on its own), or until the deadline.
runemu() {	# script log seconds
	rm -f "$2"
	OPENAI_API_KEY=test "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$1")" >"$2" 2>&1 &
	EMU_PID=$!
	i=0
	while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt "$3" ]; do
		grep -q '^DRIVER_DONE$' "$2" 2>/dev/null && break
		sleep 1
		i=$((i + 1))
	done
	kill -9 "$EMU_PID" 2>/dev/null || true
	wait "$EMU_PID" 2>/dev/null || true
	EMU_PID=
	grep -q '^DRIVER_DONE$' "$2" 2>/dev/null
}

# The common prelude: fixtures (under /usr: a bindpath grant under /tmp does
# not reach the per-call tool workers), the network for llmsrv, the scripted model,
# and the tool server.
prelude() {	# port
	cat <<EOF
#!/dis/sh.dis
load std
rm -r /usr/agentloop >[2] /dev/null
mkdir -p /usr/agentloop
echo alpha > /usr/agentloop/a.txt
echo beta > /usr/agentloop/b.txt
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 {
	echo 'line '^\$i^' of a file large enough to spill to scratch: 0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789' >> /usr/agentloop/big.txt
}
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$1/v1 -M mock &
sleep 1
/dis/veltro/tools9p.dis $TOOLS &
sleep 1
EOF
}

veltro_driver() {	# port scenario
	prelude "$1"
	cat <<EOF
echo '--- BEGIN $2'
/dis/veltro/veltro.dis -p /usr/agentloop 'SCENARIO:$2 go'
echo '--- END $2'
echo DRIVER_DONE
EOF
}

# The harness itself, through its files.  An approver in the background
# denies whatever the gate asks about, as the lucibridge driver does.
veltrosrv_driver() {	# port scenario
	prelude "$1"
	cat <<EOF
/dis/veltro/veltrosrv.dis -p /usr/agentloop
id=\`{cat /mnt/veltro/new}
echo 'SCENARIO:$2 go' > /mnt/veltro/\$id/input
{
	for i in 1 2 3 4 5 {
		a=\`{cat /mnt/veltro/\$id/approve}
		if {! ~ \$#a 0} {
			echo deny \$a(1) > /mnt/veltro/\$id/approve
		}
	}
} &
cat /mnt/veltro/\$id/text > /dev/null
echo '--- BEGIN $2'
cat /mnt/veltro/\$id/text
echo '== log'
cat /mnt/veltro/\$id/log
echo '--- END $2'
echo DRIVER_DONE
EOF
}

lucibridge_driver() {	# port scenario
	prelude "$1"
	cat <<EOF
# lucibridge's configuration gate reads /lib/ndb/llm; stage one naming the
# scripted backend, as the grind driver does, so it starts instead of
# showing the setup wizard.
mkdir -p /tmp/charndb
echo 'mode=local' > /tmp/charndb/llm
echo 'backend=openai' >> /tmp/charndb/llm
echo 'url=http://127.0.0.1:$1/v1' >> /tmp/charndb/llm
echo 'model=mock' >> /tmp/charndb/llm
bind -bc /tmp/charndb /lib/ndb
# Past the first launch: the welcome document shown and the tour offered,
# so neither comes before the scenario (both markers are per install,
# untracked, and absent from a fresh checkout).
mkdir -p /tmp/charveltro
echo > /tmp/charveltro/welcome_shown
echo > /tmp/charveltro/tour_offered
bind -bc /tmp/charveltro /lib/veltro
luciuisrv
sleep 1
echo 'activity create Characterize' > /mnt/ui/ctl
lucibridge -a 0 -p /usr/agentloop &
sleep 2
echo 'SCENARIO:$2 go' > /mnt/ui/activity/0/conversation/input
sleep 2
done=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 {
	if {! ~ \$done 1} {
		s=\`{cat /mnt/ui/activity/0/status}
		if {~ \$s blocked} {
			echo Deny > /mnt/ui/activity/0/conversation/input
		}
		if {~ \$s idle complete} {
			done=1
		} {
			sleep 1
		}
	}
}
echo '--- BEGIN $2'
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 {
	if {ftest -e /mnt/ui/activity/0/conversation/\$i} {
		echo msg \$i
		cat /mnt/ui/activity/0/conversation/\$i
		echo
	}
}
echo '--- END $2'
echo DRIVER_DONE
EOF
}

FAILED=0
FRONTENDS=${FRONTENDS:-lucibridge}
for fe in $FRONTENDS; do
	for sc in $SCENARIOS; do
		: > "$WORK/req.log"
		rm -f "$WORK/port"
		python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
		SERVER_PID=$!
		i=0
		while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
		[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
		PORT=$(cat "$WORK/port")

		# The fixture, and the agent's staged writes (cowfs overlays and
		# scratch live under /tmp/veltro, which is on the host and would
		# otherwise carry one scenario's writes into the next).
		rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch"
		SCRIPT="$ROOT/tests/inferno/.agentloop-char.$$.sh"
		${fe}_driver "$PORT" "$sc" > "$SCRIPT"
		if ! runemu "$SCRIPT" "$WORK/emu.log" 120; then
			echo "FAIL: $fe $sc: driver did not finish"
			tail -20 "$WORK/emu.log"
			FAILED=$((FAILED + 1))
		fi
		rm -f "$SCRIPT"; SCRIPT=
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
		SERVER_PID=

		rm -rf "$WORK/out"
		python3 -I "$HERE/normalize.py" "$fe" "$WORK/req.log" "$WORK/emu.log" "$WORK/out"
		got="$WORK/out/$fe-$sc.txt"
		want="$GOLDEN/$fe-$sc.txt"
		if [ "$UPDATE" = 1 ]; then
			mkdir -p "$GOLDEN"
			cp "$got" "$want"
			echo "updated $fe $sc"
		elif [ ! -f "$want" ]; then
			echo "FAIL: $fe $sc: no golden file $want (run with UPDATE=1)"
			FAILED=$((FAILED + 1))
		elif ! diff -u "$want" "$got"; then
			echo "FAIL: $fe $sc: differs from golden"
			FAILED=$((FAILED + 1))
		else
			echo "PASS: $fe $sc"
		fi
	done
done

[ "$FAILED" -eq 0 ] || { echo "agentloop_characterization_test: $FAILED failed"; exit 1; }
echo "agentloop_characterization_test: PASS"
