#include "os.h"
#include <mp.h>
#include <libsec.h>

// Gordon's algorithm for generating a strong prime
//	Menezes et al () Handbook, p.150
// The prime has n bits, and 64 if fewer are asked for.  (It had n or
// n-1 as its parts fell: the steps are repeated until it has n.)
//
// Its searches stop when stop says (see genprime.c): -1 then, with p
// zero, else 0.  They are otherwise as long as the gaps between
// primes, which end.
static int	gordon(mpint*, int, int, int(*)(void));

int
genstrongprimestop(mpint *p, int n, int accuracy, int (*stop)(void))
{
	if(n < 64)
		n = 64;
	do
		if(gordon(p, n, accuracy, stop) < 0){
			mpassign(mpzero, p);
			return -1;
		}
	while(mpsignif(p) != n);
	return 0;
}

int
genstrongprime(mpint *p, int n, int accuracy)
{
	return genstrongprimestop(p, n, accuracy, secstop);
}

static int
gordon(mpint *p, int n, int accuracy, int (*stop)(void))
{
	mpint *s, *t, *r, *i;
	int rv;

	rv = -1;
	s = mpnew(n/2);
	t = mpnew(n/2);
	i = mpnew(16);
	r = mpnew(0);
	if(genprimestop(s, (n/2)-16, accuracy, stop) < 0)
		goto Out;
	if(genprimestop(t, n-mpsignif(s)-32, accuracy, stop) < 0)
		goto Out;

	// first r = 2it + 1 that's prime
	itomp(0x8000, i);
	mpleft(t, 1, t);	// 2t
	mpmul(i, t, r);		// 2it
	mpadd(r, mpone, r);	// 2it + 1
	for(;;){
		if(probably_prime(r, 18))
			break;
		if(stop != nil && (*stop)())
			goto Out;
		mpadd(r, t, r);	// r += 2t
	}

	// p0 = 2(s**(r-2) mod r)s - 1
	itomp(2, p);
	mpsub(r, p, p);
	mpexp(s, p, r, p);
	mpmul(s, p, p);
	mpleft(p, 1, p);
	mpsub(p, mpone, p);

	// first p = p0 + 2irs that's prime
	itomp(0x8000, i);
	mpleft(r, 1, r);	// 2r
	mpmul(r, s, r);		// 2rs
	mpmul(r, i, i);		// 2irs
	mpadd(p, i, p);		// p0 + 2irs
	for(;;){
		if(probably_prime(p, accuracy))
			break;
		if(stop != nil && (*stop)())
			goto Out;
		mpadd(p, r, p); // p += 2rs
	}
	rv = 0;
Out:
	mpfree(i);
	mpfree(s);
	mpfree(r);
	mpfree(t);
	return rv;
}
