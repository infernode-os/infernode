#!/bin/sh
# The native Ethernet device's RNDIS records (os/port/devether.c): the
# kernel's own copy of the record walk, which the frames of a USB
# Ethernet adapter go through. The Limbo driver's copy has a self-test
# (usbclass_selftest_test.sh); this one had none, and is the one on the
# data path.
#
# A record's length, the offset of its frame and the frame's length are
# the device's, 32 bits each. They were assembled in an int: one with
# its top bit set was negative, passed "offset + length <= n", and the
# frame was taken from before the buffer (fffff000: 4088 bytes before
# it). rndisunwrap is extracted and run on heap buffers exactly as long
# as the bytes received, under ASan and UBSan where the compiler has
# them: whatever the three numbers say, a frame it gives lies inside
# the record, after the header, and is no longer than a frame.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/port/devether.c
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

{
	echo 'static ulong rnisget4(uchar*);'
	echo 'static long'; awk '/^rndisunwrap\(/,/^}/' "$SRCFILE"
	echo 'static ulong'; awk '/^rnisget4\(/,/^}/' "$SRCFILE"
} > "$BUILD/fn.inc"
if ! grep -q '^rndisunwrap(uchar \*p, long n, long max' "$BUILD/fn.inc" || ! grep -q '^rnisget4(' "$BUILD/fn.inc"; then
	fail "devether.c's rndisunwrap is not the one that is told how much the buffer holds"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned char uchar;
typedef unsigned long ulong;
#define nil ((void*)0)
enum { Maxframe = 1514, Rnishdr = 44, Rnisdata = 1 };
#include "fn.inc"

static void
put4(uchar *p, ulong v)
{
	p[0] = v; p[1] = v>>8; p[2] = v>>16; p[3] = v>>24;
}

static const ulong edge[] = {
	0, 1, 8, 13, 14, 35, 36, 37, 43, 44, 45, 60, 100, 1514, 1515, 1550, 1558, 1559, 2000, 4096,
	0x7fffffffUL, 0x80000000UL, 0x80000001UL, 0xfffff000UL, 0xffffffd4UL, 0xfffffff8UL, 0xffffffffUL,
};
#define N (int)(sizeof edge/sizeof edge[0])

int
main(void)
{
	static const long have[] = {44, 45, 60, 100, 1558, 1600, 4096};
	int a, b, c, h, bad = 0, frames = 0;
	long n, used, flen;
	uchar *buf, *fp;

	for(h = 0; h < (int)(sizeof have/sizeof have[0]); h++)
	for(a = 0; a < N; a++)
	for(b = 0; b < N; b++)
	for(c = 0; c < N; c++){
		n = have[h];
		buf = malloc(n);	/* exactly what was received: a read outside it is the sanitizer's */
		memset(buf, 0x5a, n);
		put4(buf, Rnisdata);
		put4(buf+4, edge[a]);	/* MessageLength */
		put4(buf+8, edge[b]);	/* DataOffset */
		put4(buf+12, edge[c]);	/* DataLength */
		fp = nil; flen = -1;
		used = rndisunwrap(buf, n, 4096, &fp, &flen);
		if(used > n || used < -1){
			if(bad++ < 10) printf("  used %ld of %ld (msglen %#lx)\n", used, n, edge[a]);
		}
		if(fp != nil){
			frames++;
			if(used <= 0 || fp < buf+Rnishdr || flen < 14 || flen > Maxframe
			|| fp+flen > buf+used || fp+flen > buf+n){
				if(bad++ < 10)
					printf("  frame at %ld, %ld bytes, record of %ld in %ld (msglen %#lx off %#lx len %#lx)\n",
						(long)(fp-buf), flen, used, n, edge[a], edge[b], edge[c]);
			}else{
				/* touch every byte of it, as the stack above will */
				volatile uchar s = 0;
				long i;
				for(i = 0; i < flen; i++)
					s += fp[i];
				(void)s;
			}
		}
		free(buf);
	}
	/* an ordinary record: header, then a frame of 60 bytes */
	n = 44 + 60;
	buf = malloc(n);
	memset(buf, 0, n);
	put4(buf, Rnisdata); put4(buf+4, n); put4(buf+8, 36); put4(buf+12, 60);
	used = rndisunwrap(buf, n, 4096, &fp, &flen);
	if(used != n || fp != buf+44 || flen != 60){
		printf("  an ordinary record is not read: used %ld, frame %ld bytes\n", used, flen);
		bad++;
	}
	/* a record longer than the buffer can ever hold is not waited for */
	put4(buf+4, 8192);
	if(rndisunwrap(buf, n, 4096, &fp, &flen) != -1){
		printf("  a record of 8192 bytes is waited for in a buffer of 4096\n");
		bad++;
	}
	/* one not yet all here is */
	put4(buf+4, 2000);
	if(rndisunwrap(buf, n, 4096, &fp, &flen) != 0){
		printf("  a record of 2000 bytes with 104 here is not waited for\n");
		bad++;
	}
	free(buf);
	printf("%d frames given\n", frames);
	return bad != 0;
}
EOT

SAN=""
echo 'int main(void){return 0;}' > "$BUILD/san.c"
if "$CC" -fsanitize=address,undefined -o "$BUILD/san" "$BUILD/san.c" 2>/dev/null && "$BUILD/san" 2>/dev/null; then
	SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi

if "$CC" -std=c99 -Wall -Wno-unused-function -g $SAN -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "whatever a record's three numbers say, a frame lies inside it, after the header, and is no longer than a frame ($(tail -1 "$BUILD/run.out")${SAN:+, under ASan and UBSan})"
	else
		fail "rndisunwrap: $(grep -v '^$' "$BUILD/run.out" | head -6 | tr '\n' ' ' | cut -c1-600)"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

# The receive loop tells it how much the buffer holds.
if grep -q 'rndisunwrap(e->rxbuf+off, e->nacc-off, e->nrxbuf, &fp, &flen)' "$SRCFILE"; then
	pass "the receive loop gives the walk the size of its buffer"
else
	fail "the receive loop calls rndisunwrap without the buffer's size"
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
