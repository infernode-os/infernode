#!/bin/sh
# Run the real arpread with an exact-size destination and a guard byte.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/arp.c
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

{ echo 'static void'; awk '/^convmac\(/,/^}/' "$SRCFILE"; } > "$BUILD/arpread.inc"
{ echo 'int'; awk '/^arpread\(/,/^}/' "$SRCFILE"; } >> "$BUILD/arpread.inc"

cat > "$BUILD/test.c" <<'EOF'
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned long ulong;
enum { Alinelen = 90, MAClen = 16, NCACHE = 2 };

typedef struct Medium Medium;
typedef struct Arpent Arpent;
typedef struct Arp Arp;
struct Medium { int maclen; char *name; };
struct Arpent {
	int state;
	uchar mac[MAClen];
	Medium *type;
	uchar ip[16];
};
struct Arp { int ql; Arpent cache[NCACHE]; };

char *aformat = "%-6.6s %-8.8s %-40.40I %-32.32s\n";
char *arpstate[] = { "unused", "wait", "ok" };

void qlock(int *q) { *q = 1; }
void qunlock(int *q) { *q = 0; }

int
sprint(char *p, char *fmt, ...)
{
	va_list ap;
	int v;

	va_start(ap, fmt);
	if(strcmp(fmt, "%2.2ux") == 0) {
		v = va_arg(ap, int);
		va_end(ap);
		return sprintf(p, "%02x", v);
	}
	va_end(ap);
	memset(p, 'X', Alinelen);
	p[Alinelen] = 0;
	return Alinelen;
}

int
snprint(char *p, int n, char *fmt, ...)
{
	int m = Alinelen;

	(void)fmt;
	if(m >= n)
		m = n-1;
	memset(p, 'X', m);
	p[m] = 0;
	return m;
}

#include "arpread.inc"

int
main(void)
{
	Arp arp;
	Medium ether = { 6, "ether" };
	uchar out[Alinelen+1];
	int n;

	memset(&arp, 0, sizeof arp);
	arp.cache[0].state = 1;
	arp.cache[0].type = &ether;
	memset(out, 0xA5, sizeof out);
	n = arpread(&arp, (char*)out, 0, Alinelen);
	if(n != Alinelen || out[Alinelen] != 0xA5) {
		fprintf(stderr, "n=%d guard=%#x\n", n, out[Alinelen]);
		return 1;
	}
	return 0;
}
EOF

if "$CC" -std=c99 -Wall -Wextra -Werror -I"$BUILD" "$BUILD/test.c" -o "$BUILD/test" &&
   "$BUILD/test"; then
	pass "exact-size ARP read leaves the guard byte untouched"
else
	fail "exact-size ARP read leaves the guard byte untouched"
fi

LOCKLINE=$(awk '/^arpread\(/,/^}/ { if($0 ~ /qlock\(&arp->ql\)/) { print NR; exit } }' "$SRCFILE")
LOOPLINE=$(awk '/^arpread\(/,/^}/ { if($0 ~ /for\(a = arp->cache/) { print NR; exit } }' "$SRCFILE")
if [ -n "$LOCKLINE" ] && [ -n "$LOOPLINE" ] && [ "$LOCKLINE" -lt "$LOOPLINE" ]; then
	pass "ARP entry state and medium are read under the cache lock"
else
	fail "ARP entry state and medium are read under the cache lock"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
