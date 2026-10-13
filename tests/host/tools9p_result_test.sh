#!/bin/sh
#
# tools9p_result_test.sh — each caller of a tool reads its own result,
# the result of one call on all its arguments.
#
# Runs tests/tools9p_test.dis against a tools9p serving read and json.
# Its ResultPerFid case writes different arguments on two fids of one
# tool's ctl and reads both back: with the result kept per tool rather
# than per fid, the first fid read the second's, and the agent harness's
# concurrent calls got each other's output.  LongArgsOneCall and
# ArgsOnBoundary write arguments longer than one 9P message: the tool
# ran once a fragment, each time on part of them (INFR-521).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/tests/tools9p_test.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT HUP INT TERM
timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	"path=(/dis/veltro /dis/cmd /dis .); tools9p -m /tool read json & sleep 2; /dis/tests/tools9p_test.dis -v" \
	</dev/null >"$OUT" 2>&1 || true

status=0
for c in "ResultPerFid:two fids on one tool each read their own result" \
	"LongArgsOneCall:a call longer than one message runs once, on all of it" \
	"ArgsOnBoundary:a call ending on a message boundary runs at the next read"; do
	name=${c%%:*}
	what=${c#*:}
	if grep -q -- "^--- PASS: $name" "$OUT"; then
		echo "PASS: $what"
	else
		grep -A12 -- "RUN   $name" "$OUT" || tail -20 "$OUT"
		echo "FAIL: $what"
		status=1
	fi
done
[ $status -eq 0 ] && echo "tools9p_result_test: PASS"
exit $status
