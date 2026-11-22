#!/bin/sh
# The route table (os/ip/iproute.c): what guards it.
#
# routemaskok and routeroom are extracted from the source and run: a
# mask is ones and then zeros (every 4-byte prefix taken, every
# 16-bit pattern that is not one refused, at every byte); a route is
# added only while its family has room for its nodes. The rest is
# checked by the order of the source: an add takes its nodes from the
# free list and counts the generation while it holds the lock, in one
# hold, and a delete counts the generation before it lets go; a
# conversation's cached route is used only if it is of the family
# being looked up; an empty write to the route file is refused before
# its first field is read.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/iproute.c
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

: > "$BUILD/fns.inc"
for fn in routeroom routemaskok; do
	{ echo 'static int'; awk "/^$fn\\(/,/^}/" "$SRCFILE"; } >> "$BUILD/fns.inc"
	if ! grep -q "^$fn(" "$BUILD/fns.inc"; then
		fail "iproute.c has no $fn to run"
		echo "Passed: $PASSED  Failed: $FAILED"
		exit 1
	fi
done
MAXN=$(sed -n 's/^[ \t]*Maxroutenodes[ \t]*=[ \t]*\([^,]*\),.*/\1/p' "$SRCFILE" | head -1)
if [ -z "$MAXN" ]; then
	fail "iproute.c has no Maxroutenodes"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<EOT
#include <stdio.h>
#include <string.h>
typedef unsigned char uchar;
enum { Maxroutenodes = $MAXN };
#include "fns.inc"

static int bad;
static void
want(int got, int expect, const char *what, unsigned a)
{
	if(got != expect){
		if(bad++ < 10)
			printf("  %s %#x: got %d, want %d\n", what, a, got, expect);
	}
}

int
main(void)
{
	uchar m[16];
	unsigned v, x;
	int i, ok, bits;

	/* every prefix length of a v4 and a v6 mask */
	for(bits = 0; bits <= 128; bits++){
		memset(m, 0, sizeof m);
		for(i = 0; i < bits; i++)
			m[i/8] |= 0x80 >> (i%8);
		want(routemaskok(m, 16), 1, "prefix", bits);
		if(bits <= 32)
			want(routemaskok(m, 4), 1, "v4 prefix", bits);
	}
	/* every 16-bit pattern, at every pair of bytes of a v4 mask, with ones before and zeros after */
	for(i = 0; i < 3; i++)
		for(v = 0; v < 0x10000; v++){
			memset(m, 0, 4);
			memset(m, 0xff, i);
			m[i] = v >> 8;
			m[i+1] = v;
			x = ~v & 0xffff;		/* a prefix: its complement is 2^k - 1 */
			ok = (x & (x + 1)) == 0;
			want(routemaskok(m, 4), ok, "pattern", v);
		}
	/* ones after a zero byte, anywhere */
	memset(m, 0xff, 16); m[5] = 0;
	want(routemaskok(m, 16), 0, "hole", 5);
	memset(m, 0, 16); m[15] = 1;
	want(routemaskok(m, 16), 0, "low bit alone", 15);

	/* room */
	want(routeroom(0, 1), 1, "room", 0);
	want(routeroom(0, 1024), 1, "room", 1024);
	want(routeroom(Maxroutenodes - 1024, 1024), 1, "room at the limit", 0);
	want(routeroom(Maxroutenodes - 1023, 1024), 0, "room past the limit", 0);
	want(routeroom(Maxroutenodes, 1), 0, "room when full", 0);
	want(routeroom(0, -1), 0, "room for a negative count", 0);
	want(routeroom(0x7fffffff, 1), 0, "room with a count that would wrap", 0);
	want(routeroom(0, 0x7fffffff), 0, "room for a count that would wrap", 0);
	return bad != 0;
}
EOT

SAN=
if echo 'int main(void){return 0;}' > "$BUILD/san.c" &&
   "$CC" -fsanitize=address,undefined -o "$BUILD/san" "$BUILD/san.c" 2>/dev/null &&
   "$BUILD/san" 2>/dev/null; then
	SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi
if "$CC" -std=c99 -Wall -Wno-unused-function -g $SAN -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "masks that are prefixes are taken and no others; a route is added only while there is room${SAN:+ (ASan, UBSan)}"
	else
		fail "route guards: $(head -6 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

# An add: lock, room, nodes, generation, unlock -- in that order, once.
for v in 4 6; do
	awk "/^v${v}addroute\\(/,/^}/" "$SRCFILE" > "$BUILD/add$v.c"
	lk=$(grep -n 'wlock(&routelock)' "$BUILD/add$v.c" | head -1 | cut -d: -f1)
	rm=$(grep -n "routeroom(v${v}nodes" "$BUILD/add$v.c" | head -1 | cut -d: -f1)
	al=$(grep -n 'allocroute(' "$BUILD/add$v.c" | head -1 | cut -d: -f1)
	gn=$(grep -n "v${v}routegeneration++" "$BUILD/add$v.c" | head -1 | cut -d: -f1)
	ul=$(grep -n 'wunlock(&routelock)' "$BUILD/add$v.c" | tail -1 | cut -d: -f1)
	nlk=$(grep -c 'wlock(&routelock)' "$BUILD/add$v.c")
	mk=$(grep -n 'routemaskok(mask' "$BUILD/add$v.c" | head -1 | cut -d: -f1)
	if [ -n "$lk" ] && [ -n "$rm" ] && [ -n "$al" ] && [ -n "$gn" ] && [ -n "$ul" ] && [ -n "$mk" ] &&
	   [ "$nlk" -eq 1 ] && [ "$mk" -lt "$lk" ] && [ "$lk" -lt "$rm" ] && [ "$rm" -lt "$al" ] &&
	   [ "$al" -lt "$gn" ] && [ "$gn" -lt "$ul" ]; then
		pass "v${v}addroute takes its nodes and counts its generation in one hold of the lock, with room checked first"
	else
		fail "v${v}addroute: lock ${lk:-none} room ${rm:-none} alloc ${al:-none} generation ${gn:-none} unlock ${ul:-none} ($nlk holds)"
	fi
	awk "/^v${v}delroute\\(/,/^}/" "$SRCFILE" > "$BUILD/del$v.c"
	gn=$(grep -n "v${v}routegeneration++" "$BUILD/del$v.c" | head -1 | cut -d: -f1)
	ul=$(grep -n 'wunlock(&routelock)' "$BUILD/del$v.c" | tail -1 | cut -d: -f1)
	if [ -n "$gn" ] && [ -n "$ul" ] && [ "$gn" -lt "$ul" ] && [ "$(grep -c 'wunlock(&routelock)' "$BUILD/del$v.c")" -eq 1 ]; then
		pass "v${v}delroute counts its generation before it lets the lock go"
	else
		fail "v${v}delroute counts its generation after unlocking (generation ${gn:-none}, unlock ${ul:-none})"
	fi
done

# The cached route is of the family asked for.
if awk '/^v4lookup\(/,/^}/' "$SRCFILE" | grep -q '(c->r->type & Rv4) != 0 && c->rgen == v4routegeneration' &&
   awk '/^v6lookup\(/,/^}/' "$SRCFILE" | grep -q '(c->r->type & Rv4) == 0 && c->rgen == v6routegeneration'; then
	pass "a conversation's cached route is used only for its own family"
else
	fail "a lookup takes a cached route of the other family when the generations agree"
fi

# An empty write is refused before f[0] is read.
awk '/^routewrite\(/,/^}/' "$SRCFILE" > "$BUILD/write.c"
chk=$(grep -n 'if(cb->nf < 1)' "$BUILD/write.c" | head -1 | cut -d: -f1)
use=$(grep -n 'strcmp(cb->f\[0\]' "$BUILD/write.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$use" ] && [ "$chk" -lt "$use" ] && grep -q 'cb->nf < 2 || c == nil' "$BUILD/write.c"; then
	pass "routewrite refuses a write with no fields, and a tag with no channel"
else
	fail "routewrite reads cb->f[0] of a write that has none"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
