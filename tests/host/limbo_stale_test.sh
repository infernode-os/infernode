#!/bin/sh
#
# tests/host/limbo_stale_test.sh
#
# Code the Limbo compiler generated kept an address inside a heap
# object across something that can free the object: a receive, a send,
# an alt or a load while they wait (g.n = <-c; another thread drops g),
# or, in one thread, an element's address found before a call that
# frees the array and used after it.  tests/limbo_stale_test.b has a
# case for each form; this runs it
#
#   as the tree builds it, with the compiler in C, under -c0 and -c1
#   (the suite runs it under one);
#
#   compiled by the compiler in Limbo (/dis/limbo.dis) inside the
#   emulator, into a scratch directory, under both again: the two
#   compilers are twins and both were changed.  limbo_asgcall_test and
#   limbo_inline_test, which are of the same kind (a[i] = f(); an
#   inlined call's argument let go before its element is used, which
#   the compiler in Limbo still did), go through it too;
#
# checks that the two compilers give the same module for each, byte
# for byte, so that one does not quietly lose a change the other has;
#
# and, the test being a case for each form found, looks at what the
# compiler generates for programs at large: the compiler's own source,
# the libraries and the tests compiled to assembly, and
# tools/limbo-stale-screen.py finding in it no receive, send, load or
# address taken with an operand inside an object that can be freed
# meanwhile, and no element's address used after code that can free
# its array (144 and 68 of them in the tree before).
#
# Skips (exit 77) when there is no emulator, the test is not built, or
# there is no /dis/limbo.dis.
#
. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f dis/tests/limbo_stale_test.dis ] || { echo "SKIP: dis/tests/limbo_stale_test.dis not built"; exit 77; }
[ -f dis/limbo.dis ] || { echo "SKIP: dis/limbo.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

# run a compiled test; $1 what, $2 its path in the emulator, $3 -c0 or -c1
runit() {
	out=$(with_timeout "$TIMEOUT" "$EMU" $3 -r"$ROOT" /dis/sh.dis -c "$2 -m $2; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|faults'; then
		pass "$1, $3: $(echo "$out" | grep ' passed' | tail -1)"
	else
		fail "$1, $3:"
		echo "$out" | grep -v 'sdl3\|^fs: ' | grep -- '--- FAIL\|^    \|SEGV\|BUS\|panic\|faults\|passed' | head -30
	fi
}

for mode in -c0 -c1; do
	runit "limbo_stale_test compiled by limbo in C" /dis/tests/limbo_stale_test.dis $mode
done

W=tmp/limbo_stale_test.$$
mkdir -p "$W" || { echo "SKIP: cannot make $ROOT/$W"; exit 77; }
trap 'rm -rf "$ROOT/$W"' EXIT INT TERM

for t in limbo_stale_test limbo_asgcall_test limbo_inline_test; do
	cp tests/$t.b "$W/"
	out=$(with_timeout "$TIMEOUT" "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd /$W; limbo -I/module -gw -o $t.hosted.dis $t.b; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if [ ! -s "$W/$t.hosted.dis" ]; then
		fail "/dis/limbo.dis did not compile $t.b: $(echo "$out" | grep -v '^fs: ' | head -5 | tr '\n' ' ' | cut -c1-300)"
		continue
	fi
	for mode in -c0 -c1; do
		runit "$t compiled by limbo in Limbo" /$W/$t.hosted.dis $mode
	done
	if [ -x "$LIMBO" ]; then
		if (cd "$W" && "$LIMBO" -I"$ROOT/module" -gw -o $t.native.dis $t.b >/dev/null 2>&1) && [ -s "$W/$t.native.dis" ]; then
			if cmp -s "$W/$t.native.dis" "$W/$t.hosted.dis"; then
				pass "the two compilers give the same module for $t"
			else
				fail "the compiler in C and the one in Limbo give different modules for $t ($(wc -c < "$W/$t.native.dis") and $(wc -c < "$W/$t.hosted.dis") bytes)"
			fi
		else
			fail "$LIMBO did not compile $t.b"
		fi
	else
		echo "note: no $LIMBO: the two compilers' modules for $t not compared"
	fi
done

if [ -x "$LIMBO" ] && command -v python3 >/dev/null 2>&1; then
	mkdir -p "$W/s"
	n=0
	for f in appl/cmd/limbo/limbo.b appl/lib/*.b appl/cmd/*.b tests/*.b; do
		d=$(dirname "$f")
		b=$(basename "$f" .b)
		o="$ROOT/$W/s/$(echo "$f" | tr / _).s"
		if (cd "$d" && "$LIMBO" -I"$ROOT/module" -w -S -o "$o" "$b.b" >/dev/null 2>&1) && [ -s "$o" ]; then
			n=$((n+1))
		else
			rm -f "$o"
		fi
	done
	if [ "$n" -lt 100 ]; then
		fail "only $n programs compiled to assembly"
	elif out=$(python3 tools/limbo-stale-screen.py -v "$W"/s/*.s); then
		pass "no address kept across code that can free what it is in: $(echo "$out" | tail -1)"
	else
		fail "generated code keeps an address across code that can free what it is in:"
		echo "$out" | sed "s|$W/s/||" | head -20 | cut -c1-300
		echo "$out" | tail -1
	fi
else
	echo "note: no $LIMBO or no python3: the generated code not screened"
fi
exit $rc
