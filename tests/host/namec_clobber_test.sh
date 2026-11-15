#!/bin/sh
# namec (chan.c, both kernels) and the channel its error handler closes.
#
# namec holds one channel, c, which walk() and domount() replace through
# a pointer after waserror(), closing the one they were given; the
# handler, reached by a longjmp, closes c.  C leaves a local changed
# between setjmp and longjmp, and not volatile, indeterminate in the
# handler.  The native kernel met it on a board: the handler closed the
# channel c held at waserror(), which walk had already released, so the
# name space's root lost a reference for every name that failed after
# its walk, and the kernel panicked in cclose some time later.  It was
# made volatile there.  The hosted kernel's was not: the compilers the
# hosted builds use read it from memory at the -O they are built with,
# and clang at -O2 does not (it closes the old channel).
#
# By the source, in both kernels: c is volatile, and nothing in namec
# hands its address to walk or domount directly.  Where clang is
# installed and the tree has this host's headers, the hosted chan.c is
# compiled at -O2 and the handler's cclose must be of a value read from
# memory after the longjmp.  No emulator needed.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

for k in emu os; do
	SRCFILE=$ROOT/$k/port/chan.c
	if [ ! -f "$SRCFILE" ]; then
		fail "$SRCFILE not found"
		continue
	fi
	# the function, less its comments' lines (one speaks of walk(&c, ...))
	awk '/^namec\(char \*aname/,/^}/' "$SRCFILE" | grep -v '^[[:space:]]*/\{0,1\}\*' > "$BUILD/namec.$k"
	if [ ! -s "$BUILD/namec.$k" ]; then
		fail "$k/port/chan.c: namec not found"
		continue
	fi
	if grep -Eq '^[[:space:]]*Chan[[:space:]]*\*[[:space:]]*volatile[[:space:]]+c;' "$BUILD/namec.$k"; then
		pass "$k/port/chan.c: the channel namec's error handler closes is volatile"
	else
		fail "$k/port/chan.c: namec's c is not volatile: its handler may close the channel c held at waserror()"
	fi
	if grep -Eq '[^a-z](walk|domount)\(&c,' "$BUILD/namec.$k"; then
		fail "$k/port/chan.c: namec gives walk or domount the address of its volatile c: $(grep -En '[^a-z](walk|domount)\(&c,' "$BUILD/namec.$k" | head -2 | tr '\n' ' ')"
	else
		pass "$k/port/chan.c: walk and domount are reached through walkc and domountc"
	fi
done

# What a compiler that takes the invitation makes of the hosted one.
CLANG=$(command -v clang 2>/dev/null)
INC=""
for d in "$ROOT"/Linux/*/include "$ROOT"/MacOSX/*/include; do
	if [ -f "$d/lib9.h" ]; then
		case "$d" in
		*/Linux/*)	[ "$(uname -s)" = Linux ] || continue;;
		*/MacOSX/*)	[ "$(uname -s)" = Darwin ] || continue;;
		esac
		case "$(uname -m)" in
		x86_64|amd64)	case "$d" in */amd64/*) INC=$d;; esac;;
		aarch64|arm64)	case "$d" in */arm64/*) INC=$d;; esac;;
		esac
	fi
done
EMUDIR=$ROOT/emu/Linux
[ "$(uname -s)" = Darwin ] && EMUDIR=$ROOT/emu/MacOSX
if [ -z "$CLANG" ] || [ -z "$INC" ]; then
	echo "SKIP: the compile at -O2 (no clang, or no headers for this host)"
elif ! (cd "$EMUDIR" && "$CLANG" -O2 -S -emit-llvm -w -DROOT='"/"' -DEMU -I. -I../port -I"$INC" \
	-I"$ROOT/include" -I"$ROOT/libinterp" -fno-strict-aliasing -fcommon \
	-o "$BUILD/chan.ll" ../port/chan.c) 2> "$BUILD/cc.err"; then
	echo "SKIP: the compile at -O2 (chan.c does not compile to IR here: $(head -1 "$BUILD/cc.err" | cut -c1-120))"
else
	# namec's first setjmp is its waserror(); the block taken when it
	# returns non-zero is the handler, and its first call is cclose(c)
	awk '
	/^define .*@namec\(/ { infn = 1 }
	infn && /setjmp/ && !seen { seen = 1; next }
	infn && seen && /call void @cclose\(/ { print prev; print; exit }
	infn { prev = $0 }
	infn && /^}/ { exit }
	' "$BUILD/chan.ll" > "$BUILD/handler"
	if ! grep -q 'call void @cclose' "$BUILD/handler"; then
		echo "SKIP: the compile at -O2 (namec's handler not recognised in the IR)"
	else
		arg=$(sed -n 's/.*call void @cclose(ptr[^%]*\(%[0-9A-Za-z_.]*\)).*/\1/p' "$BUILD/handler")
		if [ -n "$arg" ] && grep -q "^ *$arg = load volatile ptr" "$BUILD/handler"; then
			pass "clang -O2: namec's handler closes the channel it reads after the longjmp"
		else
			fail "clang -O2: namec's handler closes a value from before waserror(): $(tr '\n' ' ' < "$BUILD/handler" | cut -c1-200)"
		fi
	fi
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
