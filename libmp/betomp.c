#include "os.h"
#include <mp.h>
#include "dat.h"

// convert a big-endian byte array (most significant byte first) to an mpint
mpint*
betomp(uchar *p, uint n, mpint *b)
{
	int m, s;
	mpdigit x;

	if(b == nil)
		b = mpnew(0);

	// dump leading zeros
	while(n > 1 && *p == 0){
		p++;
		n--;
	}

	// get the space
	mpbits(b, n*8);
	b->top = DIGITS(n*8);
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
