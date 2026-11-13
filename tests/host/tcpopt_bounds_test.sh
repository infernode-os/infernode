#!/bin/sh
# Put a one-byte TCP option tail immediately before an inaccessible page.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/tcp.c
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
{ echo 'static int'; awk '/^tcpoptlen\(/,/^}/' "$SRCFILE"; } > "$BUILD/tcpoptlen.inc"

cat > "$BUILD/test.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

typedef unsigned char uchar;
#include "tcpoptlen.inc"

int
main(void)
{
	long pagesz;
	uchar *map, *opt;

	pagesz = sysconf(_SC_PAGESIZE);
	map = mmap(0, 2*pagesz, PROT_READ|PROT_WRITE,
		MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if(map == MAP_FAILED || mprotect(map+pagesz, pagesz, PROT_NONE) < 0)
		return 2;
	opt = map+pagesz-1;
	opt[0] = 99;
	if(tcpoptlen(opt, 1) != 0)
		return 1;
	opt = map+pagesz-2;
	opt[1] = 2;
	if(tcpoptlen(opt, 2) != 2)
		return 1;
	opt[1] = 3;
	if(tcpoptlen(opt, 2) != 0)
		return 1;
	munmap(map, 2*pagesz);
	return 0;
}
EOF

if grep -q '^tcpoptlen(' "$BUILD/tcpoptlen.inc" &&
   "$CC" -std=c99 -Wall -Wextra -Werror -I"$BUILD" "$BUILD/test.c" -o "$BUILD/test" &&
   "$BUILD/test"; then
	pass "one-byte TCP option tail is rejected before reading its length"
else
	fail "one-byte TCP option tail is rejected before reading its length"
fi

if [ "$(grep -c 'optlen = tcpoptlen(optr, n)' "$SRCFILE")" -eq 2 ]; then
	pass "IPv4 and IPv6 parsers share the bounded option-length helper"
else
	fail "IPv4 and IPv6 parsers share the bounded option-length helper"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
