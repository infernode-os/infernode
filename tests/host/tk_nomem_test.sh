#!/bin/sh
# tk->toplevel with the emulator's main pool full, in an emulator of its
# own with a small main pool (tests/tk_nomem.b fills it with Tk
# variables).
#
# A toplevel that cannot be finished is freed by the builtin that began
# it, before it has a context, and freeing it took the context's lock
# through nil.  The fault came out as the caller's exception, from
# inside destroy(), which stops the collector for the call: it was left
# stopped for good, in every program the emulator ran.
#
# Eight toplevels with the pool full: each is refused (nil) and none
# raises; the collector then frees a cycle made after them; and with
# room again a toplevel is made.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "tk_nomem_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/tk_nomem.dis ] || { echo "tk_nomem_test: SKIP (dis/tests/tk_nomem.dis not built)"; exit 77; }

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

for mode in -c1 -c0; do
	out=$(with_timeout 120 "$EMU" $mode -pmain=24m -pheap=16m -r"$ROOT" /dis/tests/tk_nomem.dis 2>&1 < /dev/null | grep -v '^pool \|^  \|^fs:')
	if echo "$out" | grep -q '^SKIP'; then
		echo "tk_nomem_test: SKIP ($mode: $(echo "$out" | grep '^SKIP'))"
		continue
	fi
	ok=1
	echo "$out" | grep -q '^DONE$' || { fail "$mode: the program did not finish: $(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)"; ok=0; }
	tops=$(echo "$out" | grep '^TOPLEVELS')
	echo "$tops" | grep -q ' raised 0$' || { fail "$mode: a toplevel that could not be made raised: $tops"; ok=0; }
	echo "$tops" | grep -q ' refused [1-9]' || { fail "$mode: no toplevel was refused with the main pool full: $tops"; ok=0; }
	echo "$out" | grep -q '^SWEPT$' || { fail "$mode: the collector no longer runs"; ok=0; }
	echo "$out" | grep -q '^ROOM ok$' || { fail "$mode: no toplevel with room again: $(echo "$out" | grep '^ROOM')"; ok=0; }
	[ $ok = 1 ] && pass "$mode: $(echo "$tops" | sed 's/^TOPLEVELS //') with the main pool full; the collector still runs, and a toplevel is made with room again"
done
exit $rc
