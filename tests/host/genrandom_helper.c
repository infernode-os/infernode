#include "os.h"
#include <libsec.h>

static u32int seed = 0x6a09e667;

ulong
truerand(void)
{
	seed = seed * 1664525U + 1013904223U;
	return seed;
}

void
_genrandomqlock(void)
{
}

void
_genrandomqunlock(void)
{
}

int
main(void)
{
	uchar a[96], b[96], z[96];

	memset(z, 0, sizeof(z));
	genrandom(a, sizeof(a));
	genrandom(b, sizeof(b));
	if(memcmp(a, z, sizeof(a)) == 0 || memcmp(b, z, sizeof(b)) == 0)
		return 1;
	if(memcmp(a, b, sizeof(a)) == 0)
		return 2;
	return 0;
}
