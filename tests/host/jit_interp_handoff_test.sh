#!/bin/sh
#
# tests/host/jit_interp_handoff_test.sh
#
# A compiled module calling an interpreted one, and the other way round.
#
# With the JIT on, every module loaded is compiled; switch it off at run
# time (echo 0 > /dev/jit) and the next module loads interpreted while
# the shell that runs it is still compiled. The arm64 JIT punted IMCALL
# to the interpreter's op and then branched to whatever R.PC that left,
# which for an interpreted callee is a Dis Inst array: bytecode executed
# as instructions, a SEGV in JIT code here and a kernel panic on the Pi
# 3B+ (#687). amd64 inlines the call and checks Modlink.compiled first.
#
# Both orders are run, and each must print the interpreted (or compiled)
# module's output AND the shell's line after it -- a crash takes both.
#
# Skips (exit 77) when there is no emulator.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/echo.dis" ] || { echo "SKIP: dis/echo.dis not built"; exit 77; }

rc=0
for order in "1 0" "0 1"; do
	set -- $order
	out=$(timeout 60 "$EMU" -c$1 -r"$ROOT" /dis/sh.dis -c "echo $2 > /dev/jit; /dis/echo.dis HANDOFF-$1-TO-$2; echo AFTER-$1-TO-$2" 2>&1)
	if echo "$out" | grep -q "^HANDOFF-$1-TO-$2" && echo "$out" | grep -q "^AFTER-$1-TO-$2"; then
		echo "PASS: started with cflag=$1, switched to $2, the next module ran and the shell went on"
	else
		echo "FAIL: started with cflag=$1, switched to $2:"
		echo "$out" | grep -v sdl3 | head -8
		rc=1
	fi
done
exit $rc
