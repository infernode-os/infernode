#!/bin/bash
#
# tests/host/wordmem_test.sh
#
# libkern's memset and memmove, built as the Pi 5 builds them (WORDMEM)
# and as every other board does, against the C library's, over every
# small alignment and length and random large ones, overlapping both
# ways. They copy every buffer in the kernel, and a bug here is a
# corruption somewhere else. Guard bytes either side catch an overrun.
#
# Usage: tests/host/wordmem_test.sh
#

set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wordmem.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
CC="$(command -v cc || command -v clang || command -v gcc)"
[ -n "$CC" ] || { echo "SKIP: no C compiler"; exit 0; }

mkdir "$BUILD/inc"
cat > "$BUILD/inc/lib9.h" <<'C'
typedef unsigned char uchar;
typedef unsigned long ulong;
typedef unsigned long uintptr;
typedef unsigned long long u64int;
void *k_memmove(void*, void*, unsigned long);
void *k_memset(void*, int, unsigned long);
C
sed -e 's/\bmemset\b/k_memset/g' "$ROOT/libkern/memset.c" > "$BUILD/s.c"
sed -e 's/\bmemmove\b/k_memmove/g; s/\bmemcpy\b/k_memcpy/g' "$ROOT/libkern/memmove.c" > "$BUILD/m.c"
cat > "$BUILD/t.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *k_memset(void*, int, unsigned long);
void *k_memmove(void*, void*, unsigned long);

enum { Size = 1<<16, Guard = 64 };
static unsigned char a[Size+2*Guard], b[Size+2*Guard];

static void
fill(void)
{
	int i;

	for(i = 0; i < Size+2*Guard; i++)
		a[i] = b[i] = rand();
}

static int
same(char *what, long d, long s, long n)
{
	if(memcmp(a, b, sizeof a) == 0)
		return 0;
	printf("%s: dst %ld src %ld len %ld differs\n", what, d, s, n);
	return 1;
}

int
main(void)
{
	long i, d, s, n;

	for(d = 0; d < 16; d++)
		for(n = 0; n < 300; n++){
			fill();
			memset(a+Guard+d, 0x5a, n);
			if(k_memset(b+Guard+d, 0x5a, n) != b+Guard+d || same("memset", d, 0, n))
				return 1;
		}
	for(d = 0; d < 16; d++)
		for(s = 0; s < 16; s++)
			for(n = 0; n < 300; n += 3){
				fill();
				memmove(a+Guard+d, a+Guard+64+s, n);
				k_memmove(b+Guard+d, b+Guard+64+s, n);
				if(same("memmove back", d, s, n))
					return 1;
				fill();
				memmove(a+Guard+64+d, a+Guard+s, n);
				k_memmove(b+Guard+64+d, b+Guard+s, n);
				if(same("memmove forward", d, s, n))
					return 1;
			}
	for(i = 0; i < 20000; i++){
		n = rand() % (Size/2);
		d = rand() % (Size-n);
		s = rand() % (Size-n);
		fill();
		memmove(a+Guard+d, a+Guard+s, n);
		k_memmove(b+Guard+d, b+Guard+s, n);
		if(same("memmove", d, s, n))
			return 1;
	}
	return 0;
}
C
fail=0
for f in "" -DWORDMEM; do
	if "$CC" -O2 -fno-builtin -I"$BUILD/inc" $f -o "$BUILD/t" "$BUILD/t.c" "$BUILD/s.c" "$BUILD/m.c" 2>"$BUILD/err" && "$BUILD/t"; then
		echo "PASS: memset and memmove ${f:-as byte loops}"
	else
		cat "$BUILD/err"; echo "FAIL: memset and memmove ${f:-as byte loops}"; fail=1
	fi
done
exit $fail
