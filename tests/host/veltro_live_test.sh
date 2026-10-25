#!/bin/sh
#
# veltro_live_test.sh — the agent harness against a real model.
#
# The characterization test pins what the loop does against a scripted
# model; this one asks a real model to do real work through veltrosrv,
# and checks the work was done: the files on disk, not what the model
# says about them (the staged copies: an agent's writes to a granted
# path wait in its cowfs overlay for the user to promote them).  It
# costs model calls, so it runs only when asked:
#
#	VELTRO_LIVE_URL=http://127.0.0.1:11435/v1 tests/host/veltro_live_test.sh
#	VELTRO_LIVE_MODEL=sonnet VELTRO_LIVE_URL=... tests/host/veltro_live_test.sh edit
#
# The URL is an OpenAI-shape endpoint (claude-gate, Ollama, vLLM, SGLang);
# VELTRO_LIVE_MODEL names its model (default haiku).  KEEP=1 keeps the
# emulator's output.
#
#	edit	read a file, change every line that needs it, say how many
#	spawn	a child agent reads a file with its own tool call
#	write	a file longer than one short reply, written whole
#	fanout	two children at once, one of them several steps deep
#	docs	a tool's full documentation, read from its file when needed

set -e
. "$(dirname "$0")/common.sh"
set -u

[ -n "${VELTRO_LIVE_URL:-}" ] || { echo "SKIP: VELTRO_LIVE_URL not set (this test calls a real model)"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
MODEL=${VELTRO_LIVE_MODEL:-haiku}
SCENARIOS="edit spawn write fanout docs"
[ $# -gt 0 ] && SCENARIOS="$*"

WORK="$(mktemp -d)"
EMU_PID=
SCRIPT=
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	# and the overlays its writes were staged in, which a later test
	# would find as changes an earlier session kept
	rm -rf "$ROOT/usr/live" "$ROOT/tmp/veltro/cow"
	[ "${KEEP:-0}" = 1 ] && echo "work kept in $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

FAILED=0
fail() { echo "FAIL: $*"; FAILED=$((FAILED + 1)); }

task() {
	case "$1" in
	edit)	echo 'The file /usr/live/notes.txt uses British spelling. Change colour to color everywhere in it, leaving everything else as it is, then tell me how many lines you changed.' ;;
	spawn)	echo 'Use the spawn tool to start one child agent, with the read tool and the path /usr/live, whose task is to read /usr/live/secret.txt and report the word in it. Then tell me the word the child reported.' ;;
	write)	echo 'Write a file /usr/live/numbers.txt containing the numbers 1 to 1500, one per line, nothing else. Then check its last line.' ;;
	docs)	echo 'At most how many matches does the grep tool report in one call? Look it up in the tool documentation rather than guessing, and give the number.' ;;
	fanout)	echo 'In one spawn call start two child agents, each with the read and list tools and the path /usr/live. The first child: list /usr/live/maze, where every file names the next file to read, starting at start.txt; follow the chain to its end and report the word in the last file. The second child: read /usr/live/secret.txt and report its word. Then tell me both words.' ;;
	esac
}

for sc in $SCENARIOS; do
	SCRIPT="$ROOT/tests/inferno/.veltro_live_$sc.sh"
	cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
rm -r /usr/live /tmp/veltro/cow >[2] /dev/null
mkdir -p /usr/live
echo 'The colour of the sky.' > /usr/live/notes.txt
echo 'Nothing here.' >> /usr/live/notes.txt
echo 'A colour chart, and colours.' >> /usr/live/notes.txt
echo 'Last line, no colour words? colour.' >> /usr/live/notes.txt
echo 'tangerine' > /usr/live/secret.txt
mkdir -p /usr/live/maze
echo 'next: b.txt' > /usr/live/maze/start.txt
echo 'next: c.txt' > /usr/live/maze/b.txt
echo 'next: d.txt' > /usr/live/maze/c.txt
echo 'the word is: periwinkle' > /usr/live/maze/d.txt
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u $VELTRO_LIVE_URL -M $MODEL &
sleep 1
/dis/veltro/tools9p.dis -b read,list read list write edit grep find spawn &
sleep 1
/dis/veltro/veltrosrv.dis -p /usr/live
id=\`{cat /mnt/veltro/new}
echo '$(task "$sc")' > /mnt/veltro/\$id/input
cat /mnt/veltro/\$id/text > /dev/null
echo '--- BEGIN'
cat /mnt/veltro/\$id/text
echo '== log'
cat /mnt/veltro/\$id/log
echo '--- END'
# The agent's writes are staged (cowfs) until the user promotes them:
# the staged copy is the work.
echo '--- FILES'
cat /tmp/veltro/cow/*/notes.txt
echo '--- NUMBERS'
wc -l /tmp/veltro/cow/*/numbers.txt >[2] /dev/null
tail -1 /tmp/veltro/cow/*/numbers.txt >[2] /dev/null
echo DRIVER_DONE
EOF
	LOG="$WORK/$sc.log"
	rm -f "$LOG"
	"$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" >"$LOG" 2>&1 &
	EMU_PID=$!
	i=0
	while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 600 ]; do
		grep -q '^DRIVER_DONE$' "$LOG" 2>/dev/null && break
		sleep 1
		i=$((i + 1))
	done
	kill -9 "$EMU_PID" 2>/dev/null || true
	wait "$EMU_PID" 2>/dev/null || true
	EMU_PID=
	rm -f "$SCRIPT"
	SCRIPT=
	if ! grep -q '^DRIVER_DONE$' "$LOG"; then
		fail "$sc: did not finish in 600 s"
		tail -30 "$LOG"
		continue
	fi
	reply=$(sed -n '/^--- BEGIN$/,/^== log$/p' "$LOG")
	case "$sc" in
	edit)
		files=$(sed -n '/^--- FILES$/,/^--- NUMBERS$/p' "$LOG")
		if echo "$files" | grep -q colour; then fail "edit: colour left in the file"; echo "$files"; fi
		[ "$(echo "$files" | grep -c color)" -eq 3 ] || { fail "edit: three lines should say color"; echo "$files"; }
		echo "$files" | grep -q '^Nothing here.$' || fail "edit: an untouched line changed"
		echo "$reply" | grep -q '3\|three' || { fail "edit: the reply does not say three lines"; echo "$reply"; }
		;;
	spawn)
		echo "$reply" | grep -qi tangerine || { fail "spawn: the word is not in the reply"; echo "$reply"; }
		sed -n '/^== log$/,/^--- END$/p' "$LOG" | grep -q 'tool spawn' || fail "spawn: spawn was not called"
		;;
	docs)
		echo "$reply" | grep -q '200' || { fail "docs: the reply does not give grep's limit, 200"; echo "$reply"; }
		sed -n '/^== log$/,/^--- END$/p' "$LOG" | grep -q 'lib/veltro/tools/grep.txt' || fail "docs: grep.txt was not read"
		;;
	fanout)
		echo "$reply" | grep -qi tangerine || { fail "fanout: the second child's word is not in the reply"; echo "$reply"; }
		echo "$reply" | grep -qi periwinkle || { fail "fanout: the end of the chain is not in the reply"; echo "$reply"; }
		;;
	write)
		nums=$(sed -n '/^--- NUMBERS$/,/^DRIVER_DONE$/p' "$LOG")
		# 1500 lines; the last may want its newline
		echo "$nums" | grep -q '^ *150[0]\? \|^ *1499 ' || { fail "write: numbers.txt is not 1500 lines"; echo "$nums"; }
		echo "$nums" | grep -q '^1500' || fail "write: the last line is not 1500"
		;;
	esac
	echo "done: $sc ($i s)"
	[ "${VERBOSE:-0}" = 1 ] && cat "$LOG"
done

[ "$FAILED" -eq 0 ] || { echo "veltro_live_test: $FAILED failed"; exit 1; }
echo "veltro_live_test: PASS"
