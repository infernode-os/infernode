#include "os.h"
#include <mp.h>
#include <libsec.h>

// find a prime p of length n and a generator alpha of Z^*_p
// Alg 4.86 Menezes et al () Handbook, p.164
//
// The search is for a prime q with 2q+1 prime too, about one prime in
// n/2 at n bits.  It went on until it found one, however long, and
// could not be stopped (see genprime.c).  It gives up after Tries
// candidates, sixty times and more what a search is expected to take,
// and when stop says so: -1 then, with p and alpha zero, else 0.
enum
{
	Gentries=	1000,	// for a generator: one number in two is one
};

int
gensafeprimestop(mpint *p, mpint *alpha, int n, int accuracy, int (*stop)(void))
{
	mpint *q, *b;
	int i, tries, rv;

	if(n < 3 || n > (1<<24))
		sysfatal("gensafeprime: bad bit count");
	tries = 64*n + 1000;
	rv = -1;
	q = mpnew(n-1);
	b = mpnew(0);
	for(i = 0; ; i++){
		if(i == tries || (stop != nil && (*stop)()))
			goto Out;
		if(genprimestop(q, n-1, accuracy, stop) < 0)
			goto Out;
		mpleft(q, 1, p);
		mpadd(p, mpone, p); // p = 2*q+1
		if(probably_prime(p, accuracy))
			break;
	}
	// now find a generator alpha of the multiplicative
	// group Z*_p of order p-1=2q
	for(i = 0; ; i++){
		if(i == Gentries || (stop != nil && (*stop)()))
			goto Out;
		mprand(n, genrandom, alpha);
		mpmod(alpha, p, alpha);
		if(alpha->top == 0)
			continue;	// 0 passes the tests below and generates nothing
		mpmul(alpha, alpha, b);
		mpmod(b, p, b);
		if(mpcmp(b, mpone) == 0)
			continue;
		mpexp(alpha, q, p, b);
		if(mpcmp(b, mpone) != 0)
			break;
	}
	rv = 0;
Out:
	if(rv < 0){
		mpassign(mpzero, p);
		mpassign(mpzero, alpha);
	}
	mpfree(b);
	mpfree(q);
	return rv;
}

int
gensafeprime(mpint *p, mpint *alpha, int n, int accuracy)
{
	return gensafeprimestop(p, alpha, n, accuracy, secstop);
}
