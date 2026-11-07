#!/bin/sh
#
# tests/host/jit_small_test.sh
#
# A module of fewer than 128 Dis instructions is compiled.
#
# comp-amd64.c's compile() checked for overflow after rounding its
# scratch size up, and the rounded size failed the check for every such
# module, so under -c1 they ran interpreted, silently: one module in
# eight in dis/.  The arm64 and riscv64 JITs never had the check.
#
# Runs tests/jit_small_test.b under -c0 and -c1, each of which must print
# the framework's PASS line and no crash signature.  The Limbo test turns
# the JIT off for one load of a copy of its helper marked MUSTCOMPILE, so
# a module compile() declines is refused; it skips where there is no JIT.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_small_test.dis" ] || { echo "SKIP: dis/tests/jit_small_test.dis not built"; exit 77; }
[ -f "$ROOT/dis/tests/jit_small_helper.dis" ] || { echo "SKIP: dis/tests/jit_small_helper.dis not built"; exit 77; }
mkdir -p "$ROOT/tmp"

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_small_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|--- SKIP\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: a module of fewer than 128 instructions is compiled under -c$c"
	else
		echo "FAIL: a small module was not compiled under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
