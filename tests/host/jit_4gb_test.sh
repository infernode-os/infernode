#!/bin/sh
# Calls into a compiled module whose code is at a multiple of 4GB
# (tests/jit_4gb.b, tests/jit_4gb_mod.b), in an emulator of its own.
#
# The amd64 JIT's call into another module compared the low 32 bits of
# the callee's Modlink.prog with 0 to tell a built-in module from a
# compiled one.  Its executable memory is mapped near the emulator's
# text, 64K apart, so for about one launch in a thousand one of those
# places is a multiple of 4GB, and the module whose code landed there
# was taken for a built-in: its code was called from C as a function,
# never came back, and a few thousand calls later the emulator faulted
# holding its locks and exited.
#
# tests/host/jit_4gb/shim.c, preloaded, puts the called module's code
# at such a place (which place depends on where this launch's text is:
# up to eight launches are tried), and 100000 calls of it must each
# return.  Linux on amd64 only; skips where there is no C compiler.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ "$(uname -s)" = Linux ] && [ "$OBJTYPE" = amd64 ] || { echo "jit_4gb_test: SKIP (Linux amd64 only)"; exit 77; }
[ -x "$EMU" ] || { echo "jit_4gb_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/jit_4gb.dis ] && [ -f dis/tests/jit_4gb_mod.dis ] || { echo "jit_4gb_test: SKIP (dis/tests/jit_4gb.dis not built)"; exit 77; }
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || { echo "jit_4gb_test: SKIP (no C compiler)"; exit 77; }

D="$ROOT/tmp/jit_4gb.$$"
rm -rf "$D"
mkdir -p "$D" || exit 1
trap 'rm -rf "$D"' EXIT
"$CC" -shared -fPIC -O1 -o "$D/shim.so" tests/host/jit_4gb/shim.c 2>"$D/cc.err" ||
	{ echo "jit_4gb_test: SKIP (cannot build the shim: $(head -1 "$D/cc.err"))"; exit 77; }

try=0
while [ $try -lt 8 ]; do
	try=$((try+1))
	rm -f "$D/arm"
	out=$(JIT4GB_ARM="$D/arm" LD_PRELOAD="$D/shim.so" with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/tests/jit_4gb.dis "/tmp/jit_4gb.$$/arm" 2>&1 < /dev/null)
	st=$?
	if echo "$out" | grep -q '^SKIP'; then
		echo "jit_4gb_test: SKIP ($(echo "$out" | grep '^SKIP' | head -1))"
		exit 77
	fi
	echo "$out" | grep -q '^jit_4gb: text moved to ' && break
	out=
done
if [ -z "$out" ]; then
	echo "jit_4gb_test: SKIP (no launch in $try had a 4GB boundary its JIT memory could be put at)"
	exit 77
fi
where=$(echo "$out" | sed -n 's/^jit_4gb: text moved to //p' | head -1)
if echo "$out" | grep -q '^SUM 100000$' && ! echo "$out" | grep -q 'SEGV: addr=\|BUS: addr=\|panic:\|Broken'; then
	echo "PASS: 100000 calls into a module compiled at $where each returned"
	exit 0
fi
echo "FAIL: calls into a module compiled at $where (emu's status $st): $(echo "$out" | grep -v '^fs:\|^jit_4gb:' | tail -4 | tr '\n' ' ' | cut -c1-400)"
exit 1
