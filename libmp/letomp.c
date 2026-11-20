#include "os.h"
#include <mp.h>
#include "dat.h"

// convert a little endian byte array (least significant byte first) to an mpint
mpint*
letomp(uchar *s, uint n, mpint *b)
{
	int i=0, m = 0, bits;
	mpdigit x=0;

	// see betomp
	bits = mpsizebits(0, (vlong)n*8, "letomp");
	if(b == nil)
		b = mpnew(bits);
	mpbits(b, bits);
	for(; n > 0; n--){
		x |= ((mpdigit)(*s++)) << i;
		i += 8;
		if(i == Dbits){
			b->p[m++] = x;
			i = 0;
			x = 0;
		}
	}
	if(i > 0)
		b->p[m++] = x;
	b->top = m;
	// zero bytes at the top are not digits: see betomp
	mpnorm(b);
	return b;
}
