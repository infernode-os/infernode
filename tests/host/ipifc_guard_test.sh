#!/bin/sh
# The interface code (os/ip/ipifc.c): its tables read under their
# locks, and what a caller can make it hold.
#
# The self table's hash is taken from the source and run: every value
# in range, and addresses chosen to end alike (which all hashed to one
# chain) spread over the table. The rest is checked by the order of the
# source: iptentative holds the table's lock and follows no nil link;
# the local-address searches hold an interface while they read its
# addresses and let it go on every way out; ipifcadd looks at the
# medium with the interface locked and refuses the placeholder an
# unbind leaves; a rebind reopens the write queue an unbind closed; a
# conversation joins no more than Maxmulti groups.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/ipifc.c
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

grep '^#define hashipa(a)' "$SRCFILE" > "$BUILD/hash.inc"
NHASH=$(sed -n 's/^[ \t]*NHASH[ \t]*=[ \t]*\(([^)]*)\),.*/\1/p' "$SRCFILE" | head -1)
if [ ! -s "$BUILD/hash.inc" ] || [ -z "$NHASH" ]; then
	fail "ipifc.c has no hashipa or NHASH to run"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<EOT
#include <stdio.h>
#include <string.h>
typedef unsigned char uchar;
enum { IPaddrlen = 16, NHASH = $NHASH };
#include "hash.inc"
int
main(void)
{
	uchar a[IPaddrlen];
	static int seen[NHASH];
	int i, j, h, n, bad = 0;

	/* in range, whatever the bytes */
	memset(a, 0xff, sizeof a);
	for(i = 0; i < 256; i++)
		for(j = 0; j < 256; j++){
			a[14] = i; a[15] = j;
			h = hashipa(a);
			if(h < 0 || h >= NHASH){
				if(bad++ < 5) printf("  hash %d out of range\n", h);
			}
		}
	/* ff02::1:ffXX:YY01 for every XX, YY a multiple of 64 apart: one chain before */
	memset(a, 0, sizeof a);
	a[0] = 0xff; a[1] = 2; a[11] = 1; a[12] = 0xff;
	memset(seen, 0, sizeof seen);
	n = 0;
	for(i = 0; i < 256; i++)
		for(j = 1; j < 256; j += 64){
			a[13] = 0; a[14] = i; a[15] = j;
			h = hashipa(a);
			if(h >= 0 && h < NHASH && !seen[h]++)
				n++;
		}
	if(n < NHASH/2){
		printf("  1024 addresses ending alike fall on %d of %d chains\n", n, NHASH);
		bad++;
	}
	return bad != 0;
}
EOT
if "$CC" -std=c99 -Wall -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err" && "$BUILD/test" > "$BUILD/run.out" 2>&1; then
	pass "the self table's hash is in range and spreads addresses that end alike"
else
	fail "hashipa: $(cat "$BUILD/cc.err" "$BUILD/run.out" 2>/dev/null | head -4 | tr '\n' ' ')"
fi

# iptentative: lock, then look, and no link followed that is not there.
awk '/^iptentative\(/,/^}/' "$SRCFILE" > "$BUILD/tent.c"
lk=$(grep -n 'qlock(&f->self->ql)' "$BUILD/tent.c" | head -1 | cut -d: -f1)
rd=$(grep -n 'f->self->hash\[hashipa(addr)\]' "$BUILD/tent.c" | head -1 | cut -d: -f1)
ul=$(grep -n 'qunlock(&f->self->ql)' "$BUILD/tent.c" | head -1 | cut -d: -f1)
if [ -n "$lk" ] && [ -n "$rd" ] && [ -n "$ul" ] && [ "$lk" -lt "$rd" ] && [ "$rd" -lt "$ul" ] &&
   grep -q 'link != nil && link->lifc != nil' "$BUILD/tent.c" && ! grep -q 'p->link->lifc->tentative' "$BUILD/tent.c"; then
	pass "iptentative reads the self table under its lock and follows no nil link"
else
	fail "iptentative walks the self table unlocked, or through a link that may not be there"
fi

# The searches for a local address hold each interface they read, and let it go.
ok=1
for fn in findlocalip findprimaryipv4 findprimaryipv6; do
	awk "/^$fn\\(/,/^}/" "$SRCFILE" > "$BUILD/$fn.c"
	can=$(grep -c 'canrlock(&ifc->rwl)' "$BUILD/$fn.c")
	lk=$(grep -n 'canrlock(&ifc->rwl)' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	wk=$(grep -n 'ifc->lifc' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	# every way out between the lock and the end of its block is after a runlock
	leaks=$(awk '
		/canrlock\(&ifc->rwl\)/ { held = 1; next }
		/runlock\(&ifc->rwl\)/ { rel = NR }
		held && /(return;|goto out;)/ { if(rel != NR - 1) print NR }
	' "$BUILD/$fn.c" | tr '\n' ' ')
	if [ "$can" -ne 1 ] || [ -z "$wk" ] || [ "$lk" -ge "$wk" ] || [ -n "$leaks" ] ||
	   [ "$(grep -c 'runlock(&ifc->rwl)' "$BUILD/$fn.c")" -lt 2 ]; then
		fail "$fn reads an interface's addresses without holding it, or leaves holding it (lines $leaks)"
		ok=0
	fi
done
[ "$ok" -eq 1 ] && pass "the local-address searches hold each interface while they read its addresses"

# ipifcadd: bound, as seen with the lock held.
awk '/^ipifcadd\(/,/^}/' "$SRCFILE" > "$BUILD/add.c"
lk=$(grep -n 'wlock(&ifc->rwl)' "$BUILD/add.c" | head -1 | cut -d: -f1)
ck=$(grep -n 'if(ifc->m == nil || ifc->m == &unboundmedium){' "$BUILD/add.c" | head -1 | cut -d: -f1)
mt=$(grep -n 'ifc->maxtu = mtu' "$BUILD/add.c" | head -1 | cut -d: -f1)
if [ -n "$lk" ] && [ -n "$ck" ] && [ -n "$mt" ] && [ "$lk" -lt "$ck" ] && [ "$ck" -lt "$mt" ] &&
   [ "$(grep -c 'ifc->m->mintu' "$BUILD/add.c")" -eq 1 ]; then
	pass "ipifcadd looks at the medium with the interface locked, and refuses an interface being unbound"
else
	fail "ipifcadd uses the medium before it has the interface's lock (lock ${lk:-none}, check ${ck:-none}, mtu ${mt:-none})"
fi

# A rebind reopens what an unbind closed.
closed=$(awk '/^ipifcunbind\(/,/^}/' "$SRCFILE" | sed -n 's/.*qclose(ifc->conv->\([a-z]*\)).*/\1/p' | sort | tr '\n' ' ')
ok=1
for q in $closed; do
	awk '/^ipifcbind\(/,/^}/' "$SRCFILE" | grep -q "qreopen(c->$q)" || ok=0
done
if [ -n "$closed" ] && [ "$ok" -eq 1 ]; then
	pass "a rebind reopens every queue an unbind closes ($closed)"
else
	fail "a rebind leaves closed a queue the unbind closed ($closed)"
fi

# Multicast joins are counted before one more is made.
awk '/^ipifcaddmulti\(/,/^}/' "$SRCFILE" > "$BUILD/multi.c"
ck=$(grep -n 'if(n >= Maxmulti)' "$BUILD/multi.c" | head -1 | cut -d: -f1)
al=$(grep -n 'smalloc(sizeof(\*multi))' "$BUILD/multi.c" | head -1 | cut -d: -f1)
if [ -n "$ck" ] && [ -n "$al" ] && [ "$ck" -lt "$al" ] && grep -q 'Maxmulti = ' "$SRCFILE"; then
	pass "a conversation joins no more multicast groups than the limit"
else
	fail "ipifcaddmulti makes an entry for every group asked for"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
