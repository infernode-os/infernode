#include "os.h"
#include <mp.h>
#include <libsec.h>

//  generate a probable prime.  accuracy is the miller-rabin interations
void
genprime(mpint *p, int n, int accuracy)
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
			mpadd(p, mptwo, p);
		}
	}while(mpsignif(p) != n);
}
