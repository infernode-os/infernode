#!/bin/sh
#
# tools9p_result_test.sh — each caller of a tool reads its own result.
#
# Runs tests/tools9p_test.dis against a tools9p serving read.  Its
# ResultPerFid case writes different arguments on two fids of one tool's
# ctl and reads both back: with the result kept per tool rather than per
# fid, the first fid read the second's, and the agent harness's
# concurrent calls got each other's output.
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
	"path=(/dis/veltro /dis/cmd /dis .); tools9p -m /tool read & sleep 2; /dis/tests/tools9p_test.dis -v" \
	</dev/null >"$OUT" 2>&1 || true

if grep -q -- '^--- PASS: ResultPerFid' "$OUT"; then
	echo "PASS: two fids on one tool each read their own result"
	echo "tools9p_result_test: PASS"
else
	grep -A12 -- 'RUN   ResultPerFid' "$OUT" || tail -20 "$OUT"
	echo "FAIL: two fids on one tool did not each read their own result"
	exit 1
fi
