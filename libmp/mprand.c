#include "os.h"
#include <mp.h>
#include <libsec.h>
#include "dat.h"

mpint*
mprand(int bits, void (*gen)(uchar*, int), mpint *b)
{
	int n, m, made;
	mpdigit mask;
	uchar *p;
	volatile uchar *v;

	// a count of bits is the caller's: see dat.h
	bits = mpsizebits(0, bits, "mprand");
	n = DIGITS(bits);
	made = 0;
	if(b == nil){
		b = mpnew(bits);
		made = 1;
	}else
		mpbits(b, bits);

	// with no memory for the bytes, a raise, as mpnew's: nil was
	// returned with b left a zero, and the callers that draw a nonce or
	// an exponent into a b of their own did not look
	p = malloc(n*Dbytes);
	if(p == nil){
		if(made)
			mpfree(b);	// it was lost
		sysfatal("mprand: %r");
	}
	(*gen)(p, n*Dbytes);
	betomp(p, n*Dbytes, b);
	// bytes of zero at the top are not stored: a b that had held a
	// longer number kept its old digits there, and they were counted below
	for(m = b->top; m < n; m++)
		b->p[m] = 0;
	// they are the number, which may be a key or a nonce: cleared, by
	// stores a compiler keeps before a free
	v = p;
	for(m = n*Dbytes; m > 0; m--)
		*v++ = 0;
	free(p);

	// make sure we don't give too many bits
	m = bits%Dbits;
	n--;
	if(m > 0){
		mask = 1;
		mask <<= m;
		mask--;
		b->p[n] &= mask;
	}

	for(; n >= 0; n--)
		if(b->p[n] != 0)
			break;
	b->top = n+1;
	b->sign = 1;
	return b;
}
