#include "lib9.h"
#include "fcall.h"

#include <sys/mman.h>

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

static int
validstatbuf(uchar *buf, uint nbuf)
{
	uint p;

	memset(buf, 0, nbuf);
	PBIT16(buf, nbuf - BIT16SZ);
	p = STATFIXLEN - 4 * BIT16SZ;
	PBIT16(buf + p, 0);
	PBIT16(buf + p + 2, 0);
	PBIT16(buf + p + 4, 0);
	PBIT16(buf + p + 6, 0);
	return statcheckbuf(buf, nbuf) == nbuf && statcheck(buf, nbuf) == 0;
}

int
main(void)
{
	uchar good[STATFIXLEN + 1], *map, *edge;
	long pagesz;
	uint i, p;
	u16int oversized;

	if(!validstatbuf(good, STATFIXLEN))
		return 1;
	for(i = 0; i < STATFIXLEN; i++)
		if(statcheckbuf(good, i) >= 0)
			return 2;

	good[STATFIXLEN] = 0;
	if(statcheckbuf(good, sizeof good) != STATFIXLEN)
		return 3;

	p = STATFIXLEN - 4 * BIT16SZ;
	PBIT16(good + p, 9);
	if(statcheckbuf(good, STATFIXLEN) >= 0)
		return 4;

	pagesz = sysconf(_SC_PAGESIZE);
	if(pagesz <= 0)
		return 5;
	map = mmap(nil, 2 * pagesz, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if(map == MAP_FAILED)
		return 6;
	if(mprotect(map + pagesz, pagesz, PROT_NONE) < 0)
		return 7;
	edge = map + pagesz - BIT16SZ;
	oversized = ~0;
	PBIT16(edge, oversized);
	if(statcheckbuf(edge, BIT16SZ) >= 0)
		return 8;
	if(munmap(map, 2 * pagesz) < 0)
		return 9;

	return 0;
}
