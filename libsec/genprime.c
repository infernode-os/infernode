#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * The searches for a prime run with the Dis VM let go, as long as they
 * take: minutes for a safe prime of 2048 bits, hours for a prime at
 * the longest size a program may ask for.  A Prog killed in one was
 * gone only when the search ended, and until then it had one of the
 * machine's processors; gensafeprime's search had no end at all but
 * its luck.  Each search now asks, between candidates, whether to
 * stop: the function it is given, or for the callers that give none
 * (eggen, Keyring's dhparams) secstop, which the kernels set to
 * "is this process's Prog being killed" (libinterp/ipint.c).  A search
 * that stops returns -1, and what it was to make is not a prime.
 */
int	(*secstop)(void);

//  generate a probable prime.  accuracy is the miller-rabin interations
int
genprimestop(mpint *p, int n, int accuracy, int (*stop)(void))
{
	mpdigit x;

	// a prime has two bits at least.  with none, the top digit set
	// below is the word before the number; with a count near the
	// largest int the digit count wraps
	if(n < 2 || n > (1<<30))
		sysfatal("genprime: bad bit count");

	// until the prime found has n bits: counting up from a number
	// near the top of them passed 2^n (at four bits, one time in
	// three), and the prime had one bit more than was asked for
	do{
		// generate n random bits with high and low bits set
		p->top = 0;
		mpbits(p, n);
		genrandom((uchar*)p->p, (n+7)/8);
		p->top = (n+Dbits-1)/Dbits;
		p->sign = 1;
		x = 1;
		x <<= ((n-1)%Dbits);
		p->p[p->top-1] &= (x-1);
		p->p[p->top-1] |= x;
		p->p[0] |= 1;

		// keep icrementing till it looks prime
		for(;;){
			if(probably_prime(p, accuracy))
				break;
			if(stop != nil && (*stop)())
				return -1;
			mpadd(p, mptwo, p);
		}
	}while(mpsignif(p) != n);
	return 0;
}

void
genprime(mpint *p, int n, int accuracy)
{
	genprimestop(p, n, accuracy, nil);
}
