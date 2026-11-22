#!/bin/sh
# Exercise the real xHCI completion-residual clamp.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/port/usbxhci.c
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

if [ ! -f "$SRCFILE" ]; then
	echo "ERROR: $SRCFILE not found" >&2
	exit 1
fi
CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

{ echo 'static void'; awk '/^setresidue\(/,/^}/' "$SRCFILE"; } > "$BUILD/setresidue.inc"

cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>

typedef unsigned int u32int;
typedef struct Ring Ring;
struct Ring {
	int *residue;
	u32int mask;
};

#include "setresidue.inc"

static int
check(char *name, int queued, u32int reported, int want)
{
	int slots[4] = { 0, 0, 0, 0 };
	Ring r = { slots, 3 };

	slots[2] = queued;
	setresidue(&r, 6, reported);
	if(slots[2] != want) {
		fprintf(stderr, "%s: got %d, want %d\n", name, slots[2], want);
		return 0;
	}
	return 1;
}

int
main(void)
{
	int ok = 1;

	ok &= check("ordinary residual", 192, 64, 64);
	ok &= check("residual equals TD", 192, 192, 192);
	ok &= check("oversized residual", 192, 0xFFFFFF, 192);
	ok &= check("invalid queued length", -1, 1, 0);
	return !ok;
}
EOF

if grep -q '^setresidue(' "$BUILD/setresidue.inc" &&
   "$CC" -std=c99 -Wall -Wextra -Werror -I"$BUILD" "$BUILD/test.c" -o "$BUILD/test" &&
   "$BUILD/test"; then
	pass "controller residual cannot exceed the queued transfer length"
else
	fail "controller residual cannot exceed the queued transfer length"
fi

if grep -q 'm = (long)io->tdsz' "$SRCFILE" &&
   grep -q -- '- io->nleft;' "$SRCFILE"; then
	pass "iso read length uses signed arithmetic and accounts for carried data"
else
	fail "iso read length uses signed arithmetic and accounts for carried data"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
