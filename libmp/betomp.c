#include "os.h"
#include <mp.h>
#include "dat.h"

// convert a big-endian byte array (most significant byte first) to an mpint
mpint*
betomp(uchar *p, uint n, mpint *b)
{
	int m, s, bits;
	mpdigit x;

	// dump leading zeros
	while(n > 1 && *p == 0){
		p++;
		n--;
	}

	// get the space.  eight times the count was an int: for 256MB of
	// bytes it was 2^31, room was made for none of them, and they were
	// stored all the same (see dat.h); asked for before b is made, as
	// a b made here would be lost with the raise
	bits = mpsizebits(0, (vlong)n*8, "betomp");
	if(b == nil)
		b = mpnew(bits);
	mpbits(b, bits);
	b->top = DIGITS(bits);
	m = b->top-1;

	// first digit might not be Dbytes long
	s = ((n-1)*8)%Dbits;
	x = 0;
	for(; n > 0; n--){
		x |= ((mpdigit)(*p++)) << s;
		s -= 8;
		if(s < 0){
			b->p[m--] = x;
			s = Dbits-8;
			x = 0;
		}
	}

	// a zero is no digits: bytes that were all zero left one digit of
	// zero, which is not the divisor mpdiv looked for, and it shifted
	// that digit left for ever looking for its top bit
	mpnorm(b);
	return b;
}
