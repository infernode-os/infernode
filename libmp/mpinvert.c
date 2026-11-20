#include "os.h"
#include <mp.h>
#include "dat.h"

// use extended gcd to find the multiplicative inverse
// res = b**-1 mod m
//
// Not in constant time (see mpextendedgcd).  The result may be b or m:
// the reduction is by a copy of m, made before anything else, when the
// result is m (it was reduced by itself, the inverse just written
// there, and was 0).
void
mpinvert(mpint *b, mpint *m, mpint *res)
{
	mpint *dc1, *dc2, *mm;	// don't care
	int r;
	vlong bits;

	bits = ((vlong)(b->top > m->top? b->top: m->top) + 3)*Dbits;
	if(bits > MAXBITS)
		sysfatal("mpinvert: number too large");
	// what is held is made first, with all the room it will use, and
	// freed before any raise
	dc1 = mptrynew(bits);
	dc2 = mptrynew(bits);
	mm = m;
	if(res == m)
		mm = mptrycopy(m);
	if(dc1 == nil || dc2 == nil || mm == nil || mpextendedgcdtry(b, mm, dc1, res, dc2) < 0){
		mpfree(dc1);
		mpfree(dc2);
		if(mm != m)
			mpfree(mm);
		sysfatal("mpinvert: no memory");
	}
	r = mpcmp(dc1, mpone);
	mpfree(dc1);
	mpfree(dc2);
	if(r != 0){
		if(mm != m)
			mpfree(mm);
		sysfatal("mpinvert: no inverse");
	}
	r = mpmodtry(res, mm, res);
	if(mm != m)
		mpfree(mm);
	if(r < 0)
		sysfatal("mpinvert: no memory");
}
