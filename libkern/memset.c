#include	<lib9.h>

/*
 * The native kernels' memset: eight bytes at a time in general
 * registers, every word store aligned. See memmove.c, which this
 * follows, for why (interrupt paths, RISC-V, the compiler).
 */

typedef uvlong __attribute__((__may_alias__)) Word;

enum
{
	Wsz	= sizeof(Word),
	Wmask	= Wsz-1,
};

void*
memset(void *ap, int c, ulong n)
{
	uchar *p;
	Word *wp, w;

	p = ap;
	if(n >= 2*Wsz){
		while((uintptr)p & Wmask){
			*p++ = c;
			n--;
		}
		w = (uchar)c;
		w |= w<<8;
		w |= w<<16;
		w |= w<<32;
		wp = (Word*)p;
		for(; n >= 4*Wsz; n -= 4*Wsz){
			wp[0] = w; wp[1] = w; wp[2] = w; wp[3] = w;
			wp += 4;
		}
		for(; n >= Wsz; n -= Wsz)
			*wp++ = w;
		p = (uchar*)wp;
	}
	while(n > 0){
		*p++ = c;
		n--;
	}
	return ap;
}
