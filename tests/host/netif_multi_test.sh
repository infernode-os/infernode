#!/bin/sh
# The native kernel's network interface files (os/port/netif.c): the
# table of multicast addresses, and three ways a file of the tree could
# stop the machine or use up the interface.
#
# netmulti (with hash) is extracted and run against netif.h's own
# structures, with two conversations joining and leaving addresses: the
# list is no longer than a conversation's set has bits however many
# addresses come and go (it grew by one for each new address for ever,
# and ethergenet.c's filter loop followed it past its table, into the
# MAC's other registers); a conversation's joins of an address are counted
# and each leave gives one back (IP joins a group once for each local
# address through one conversation: taken once, removing one address left
# the group for the others); a conversation leaves only what it joined
# (another's address was given back, and its owner's count left); a close
# gives back each of the conversation's joins and nobody else's; and what
# is joined is what the driver was told.
#
# By the order of the source: stats and ifstats are of the second level
# in netifgen (a stat of either asked devstat's question for ever when
# conversation 0 had never been opened, which is /net/ether2 and
# /net/ether3 from boot); a refused open gives back the conversation it
# counted; a close releases each address by its own place in the list
# and takes the interface's lock before the conversation's; ethergenet
# programs only joined addresses, and no more than its filter holds.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/port/netif.c
HDR=$ROOT/os/port/netif.h
GENET=$ROOT/os/bcm2711/ethergenet.c
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

if [ ! -f "$SRCFILE" ] || [ ! -f "$HDR" ]; then
	echo "ERROR: $SRCFILE or $HDR not found" >&2
	exit 1
fi
CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

{
	echo 'static ulong'; awk '/^hash\(/,/^}/' "$SRCFILE"
	echo 'static char* netmulti(Netif*, Netfile*, uchar*, int);'
	# the close's block that gives back what the conversation joined, as it is in the source
	echo 'static void closeloop(Netif *nif, Netfile *f) { Netaddr *ap; int t;'
	awk '/^\t\tif\(f->nmaddr\)\{/ {on=1} on {print} on && /^\t\t\}/ {exit}' "$SRCFILE"
	echo '}'
	echo 'static char*'; awk '/^netmulti\(/,/^}/' "$SRCFILE"
} > "$BUILD/fn.inc"
cp "$HDR" "$BUILD/netif.h"
if ! grep -q '^netmulti(' "$BUILD/fn.inc" || ! grep -q '^hash(' "$BUILD/fn.inc" || ! grep -q 'if(f->nmaddr){' "$BUILD/fn.inc"; then
	fail "netif.c has no netmulti to run"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned char uchar;
typedef unsigned long ulong;
typedef unsigned int uint;
typedef unsigned short ushort;
#define nelem(x) (sizeof(x)/sizeof((x)[0]))
#define nil ((void*)0)
enum { KNAMELEN = 28 };
typedef struct QLock { int x; } QLock;
typedef struct Queue Queue;
typedef struct Chan Chan;
typedef struct Block Block;
typedef struct Walkqid Walkqid;
#include "netif.h"
#define smalloc(n) calloc(1, (n))
#include "fn.inc"

static int told[4096];	/* what the driver was told is joined, by an address's first two bytes */
static int ntold;

static void
drv(void *a, uchar *addr, int on)
{
	int k = addr[4]<<8 | addr[5];

	(void)a;
	if(on){ if(!told[k]) ntold++; told[k] = 1; }
	else{ if(told[k]) ntold--; told[k] = 0; }
}

static void
mkaddr(uchar *a, int k)
{
	memset(a, 0, Nmaxaddr);
	a[0] = 1; a[4] = k>>8; a[5] = k;
}

static int
listlen(Netif *nif)
{
	Netaddr *p;
	int n = 0;

	for(p = nif->maddr; p != nil; p = p->next)
		n++;
	return n;
}

static int
refs(Netif *nif, int k)
{
	Netaddr *p;
	uchar a[Nmaxaddr];

	mkaddr(a, k);
	for(p = nif->maddr; p != nil; p = p->next)
		if(p->ref > 0 && memcmp(p->addr, a, 6) == 0)
			return p->ref;
	return 0;
}

static int
bits(Netfile *f)
{
	int i, n = 0;

	for(i = 0; i < (int)nelem(f->maddr); i++)
		if(f->maddr[i] != 0)
			n++;
	return n;
}

int
main(void)
{
	static Netif nif;
	static Netfile fa, fb;
	uchar a[Nmaxaddr];
	char *e;
	int k, bad = 0, cap = (int)nelem(fa.maddr);

	nif.alen = 6;
	nif.multicast = drv;

	/* a thousand addresses joined and left in turn: the list does not grow with them */
	for(k = 1; k <= 1000; k++){
		mkaddr(a, k);
		if((e = netmulti(&nif, &fa, a, 1)) != nil){ printf("  join %d: %s\n", k, e); bad++; break; }
		netmulti(&nif, &fa, a, 0);
	}
	if(listlen(&nif) > cap){ printf("  the list is %d entries after 1000 joins and leaves; a conversation's set has %d bits\n", listlen(&nif), cap); bad++; }
	if(nif.nmaddr != 0 || ntold != 0 || bits(&fa) != 0 || fa.nmaddr != 0){
		printf("  after leaving everything: %d joined, driver told %d, %d bits, count %d\n", nif.nmaddr, ntold, bits(&fa), fa.nmaddr); bad++; }

	/*
	 * the same address twice by one conversation is two joins, each given
	 * back by a leave: IP joins a group once for each local address that
	 * needs it, through one conversation, and leaves once for each
	 */
	mkaddr(a, 7);
	netmulti(&nif, &fa, a, 1);
	netmulti(&nif, &fa, a, 1);
	if(refs(&nif, 7) != 2 || fa.nmaddr != 1 || bits(&fa) != 1){ printf("  joined twice by one conversation: ref %d, addresses %d\n", refs(&nif, 7), fa.nmaddr); bad++; }
	netmulti(&nif, &fa, a, 0);
	if(refs(&nif, 7) != 1 || !told[7] || fa.nmaddr != 1){ printf("  two joins, one leave: ref %d, driver told %d (the group was left for the address that remains)\n", refs(&nif, 7), told[7]); bad++; }
	netmulti(&nif, &fa, a, 0);
	if(refs(&nif, 7) != 0 || told[7] || fa.nmaddr != 0){ printf("  two joins, two leaves: ref %d, driver still told %d\n", refs(&nif, 7), told[7]); bad++; }
	netmulti(&nif, &fa, a, 0);
	if(refs(&nif, 7) != 0 || nif.nmaddr != 0){ printf("  a third leave: ref %d, %d joined\n", refs(&nif, 7), nif.nmaddr); bad++; }

	/* a close gives back every join the conversation made, and nobody else's */
	mkaddr(a, 11);
	netmulti(&nif, &fa, a, 1);
	netmulti(&nif, &fa, a, 1);
	netmulti(&nif, &fb, a, 1);
	mkaddr(a, 12);
	netmulti(&nif, &fa, a, 1);
	mkaddr(a, 13);
	netmulti(&nif, &fb, a, 1);
	closeloop(&nif, &fa);
	if(refs(&nif, 11) != 1 || refs(&nif, 12) != 0 || refs(&nif, 13) != 1 || told[12] || !told[11] || !told[13] || bits(&fa) != 0 || fa.nmaddr != 0){
		printf("  A closed: refs %d %d %d (want 1 0 1), A's addresses %d\n", refs(&nif, 11), refs(&nif, 12), refs(&nif, 13), fa.nmaddr); bad++; }
	closeloop(&nif, &fb);
	if(nif.nmaddr != 0 || ntold != 0 || bits(&fb) != 0){ printf("  both closed: %d joined, driver told %d\n", nif.nmaddr, ntold); bad++; }

	/* a conversation leaves only what it joined */
	mkaddr(a, 9);
	netmulti(&nif, &fa, a, 1);
	netmulti(&nif, &fb, a, 0);	/* B never joined 9 */
	if(refs(&nif, 9) != 1 || !told[9] || bits(&fa) != 1){ printf("  B left an address only A joined: ref %d, driver told %d\n", refs(&nif, 9), told[9]); bad++; }
	netmulti(&nif, &fb, a, 1);
	if(refs(&nif, 9) != 2){ printf("  two conversations joined: ref %d\n", refs(&nif, 9)); bad++; }
	netmulti(&nif, &fa, a, 0);
	if(refs(&nif, 9) != 1 || !told[9]){ printf("  one of two left: ref %d, driver told %d\n", refs(&nif, 9), told[9]); bad++; }
	netmulti(&nif, &fb, a, 0);
	if(refs(&nif, 9) != 0 || told[9] || nif.nmaddr != 0){ printf("  both left: ref %d, driver told %d, %d joined\n", refs(&nif, 9), told[9], nif.nmaddr); bad++; }

	/* more at once than a set has bits: refused, and nothing recorded that cannot be given back */
	for(k = 2000; k < 2000 + cap + 20; k++){
		mkaddr(a, k);
		e = netmulti(&nif, &fa, a, 1);
		if(k < 2000 + cap && e != nil){ printf("  join %d of %d at once refused: %s\n", k-2000+1, cap, e); bad++; break; }
		if(k >= 2000 + cap && e == nil){ printf("  join %d at once taken, past the set's %d bits\n", k-2000+1, cap); bad++; break; }
	}
	if(listlen(&nif) > cap || nif.nmaddr != cap || ntold != cap || bits(&fa) != cap || fa.nmaddr != cap){
		printf("  with the set full: list %d, joined %d, driver told %d, bits %d, count %d (want %d each)\n",
			listlen(&nif), nif.nmaddr, ntold, bits(&fa), fa.nmaddr, cap); bad++; }
	for(k = 2000; k < 2000 + cap; k++){
		mkaddr(a, k);
		netmulti(&nif, &fa, a, 0);
	}
	if(nif.nmaddr != 0 || ntold != 0 || bits(&fa) != 0){ printf("  and left again: joined %d, driver told %d, bits %d\n", nif.nmaddr, ntold, bits(&fa)); bad++; }
	printf("list of %d after it all\n", listlen(&nif));
	return bad != 0;
}
EOT

if "$CC" -std=c99 -Wall -Wno-unused-function -g -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "the multicast list is bounded, a conversation's joins are counted and it leaves only its own, a close gives back what it joined, and the driver is told what is joined ($(tail -1 "$BUILD/run.out"))"
	else
		fail "netmulti: $(head -6 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(grep -m3 error "$BUILD/cc.err" | tr '\n' ' ')"
fi

awk '/^netifgen\(/,/^}/' "$SRCFILE" > "$BUILD/gen.c"
if grep -q 't == N2ndqid || t == Ncloneqid || t == Naddrqid || t == Nstatqid || t == Nifstatqid' "$BUILD/gen.c" &&
   awk '/third level/,/^}/' "$BUILD/gen.c" | grep -A1 'if(f == 0)' | grep -q 'return -1'; then
	pass "stats and ifstats are of the second level, and a conversation that is not there ends the question"
else
	fail "netifgen sends a stat of stats or ifstats to the third level, or answers 0 for a conversation that is not there"
fi

awk '/^netifopen\(/,/^}/' "$SRCFILE" > "$BUILD/open.c"
if grep -B1 -A8 'netown(f, up->env->user, omode&7) < 0' "$BUILD/open.c" | grep -q 'closefile(nif, f)'; then
	pass "a refused open gives back the conversation it counted"
else
	fail "netifopen leaves a refused open counted"
fi

awk '/^closefile\(/,/^}/' "$SRCFILE" > "$BUILD/close.c"
n=$(grep -n 'qlock(&nif->ql)' "$BUILD/close.c" | head -1 | cut -d: -f1)
f=$(grep -n 'qlock(&f->ql)' "$BUILD/close.c" | head -1 | cut -d: -f1)
if [ -n "$n" ] && [ -n "$f" ] && [ "$n" -lt "$f" ] && [ "$(grep -c 'qlock(&nif->ql)' "$BUILD/close.c")" -eq 1 ] &&
   grep -q 'ap = ap->next, t++' "$BUILD/close.c"; then
	pass "a close takes the interface's lock before the conversation's, and releases each address by its own place"
else
	fail "closefile's lock order or its walk of the addresses is as it was (nif lock ${n:-none}, file lock ${f:-none})"
fi

if [ -f "$GENET" ]; then
	awk '/^rxmode\(/,/^}/' "$GENET" > "$BUILD/rxmode.c"
	if grep -q 'na->ref <= 0' "$BUILD/rxmode.c" && grep -q 'i >= 17' "$BUILD/rxmode.c" &&
	   ! grep -q 'na = na->next, i++' "$BUILD/rxmode.c"; then
		pass "the Pi 4's MAC programs only joined addresses, and no more than its filter holds"
	else
		fail "ethergenet's rxmode writes a filter entry for every list entry"
	fi
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
