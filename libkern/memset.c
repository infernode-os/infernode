#include	<lib9.h>

void*
memset(void *ap, int c, ulong n)
{
	char *p;
	int m = (int)n;

	p = ap;
#ifdef WORDMEM
	/*
	 * By words where it can: a kernel clears and copies megabytes, and
	 * byte by byte the speed of that hangs on how this loop happens to
	 * fall in the text, 47% between two builds. Aligned stores only:
	 * this runs before the MMU, where memory is Device.
	 */
	if(m >= 64){
		u64int v, *w;

		while(((uintptr)p & 7) != 0){
			*p++ = c;
			m--;
		}
		v = (uchar)c;
		v |= v<<8;
		v |= v<<16;
		v |= v<<32;
		w = (u64int*)p;
		for(; m >= 32; m -= 32){
			w[0] = v;
			w[1] = v;
			w[2] = v;
			w[3] = v;
			w += 4;
		}
		p = (char*)w;
	}
#endif
	while(m > 0) {
		*p++ = c;
		m--;
	}
	return ap;
}
