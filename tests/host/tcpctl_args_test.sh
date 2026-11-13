#!/bin/sh
# Exercise the real tcpctl dispatcher with missing and valid arguments.

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
{ echo 'char*'; awk '/^tcpctl\(/,/^}/' "$SRCFILE"; } > "$BUILD/tcpctl.inc"

cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
#include <string.h>

typedef struct Conv Conv;
struct Conv { int unused; };

static int checksumcalls;
static int porthogcalls;
char *tcphangup(Conv *c) { (void)c; return 0; }
char *tcpstartka(Conv *c, char **f, int n) { (void)c; (void)f; (void)n; return 0; }
char *tcpsetchecksum(Conv *c, char **f, int n)
{
	(void)c; (void)f; (void)n;
	checksumcalls++;
	return 0;
}
static char *tcpporthogdefensectl(char *s)
{
	(void)s;
	porthogcalls++;
	return 0;
}

#include "tcpctl.inc"

static int
check(char *command, int n, char *want)
{
	Conv c;
	char *f[2] = { command, "on" };
	char *got;

	got = tcpctl(&c, f, n);
	if(got == 0 || strcmp(got, want) != 0) {
		fprintf(stderr, "%s: got %s\n", command, got == 0 ? "nil" : got);
		return 0;
	}
	return 1;
}

int
main(void)
{
	Conv c;
	char *checksum[2] = { "checksum", "1" };
	char *porthog[2] = { "tcpporthogdefense", "on" };

	if(!check("checksum", 1, "insufficient arguments"))
		return 1;
	if(!check("tcpporthogdefense", 1, "insufficient arguments"))
		return 1;
	if(tcpctl(&c, checksum, 2) != 0 || checksumcalls != 1)
		return 1;
	if(tcpctl(&c, porthog, 2) != 0 || porthogcalls != 1)
		return 1;
	return 0;
}
EOF

if "$CC" -std=c99 -Wall -Wextra -Werror -I"$BUILD" "$BUILD/test.c" -o "$BUILD/test" &&
   "$BUILD/test"; then
	pass "bare TCP controls return an argument error without dispatching"
else
	fail "bare TCP controls return an argument error without dispatching"
fi

if [ "$(grep -c 'return "insufficient arguments"' "$SRCFILE")" -ge 2 ]; then
	pass "checksum and port-hog controls both carry explicit argument gates"
else
	fail "checksum and port-hog controls both carry explicit argument gates"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
