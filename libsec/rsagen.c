#include "os.h"
#include <mp.h>
#include <libsec.h>

RSApriv*
rsagen(int nlen, int elen, int rounds)
{
	mpint *p, *q, *e, *d, *phi, *n, *t1, *t2, *kp, *kq, *c2;
	RSApriv *rsa;

	p = mpnew(nlen/2);
	q = mpnew(nlen/2);
	n = mpnew(nlen);
	e = mpnew(elen);
	d = mpnew(nlen+Dbits);	// all it will hold: no buffer of it is left behind as it grows
	phi = mpnew(nlen);

	// create the prime factors and euclid's function
	genprime(p, nlen/2, rounds);
	// p == q has no CRT coefficient (mpinvert below raises "no inverse").
	// genprime counts up past its width: for a 16-bit key p of 8 bits
	// begun at 253 is 257, q is then drawn at 8 bits, and one begun at
	// 253 or 255 is 257 too (keyring_args_test's 16-bit genSK, now and then)
	do
		genprime(q, nlen - mpsignif(p) + 1, rounds);
	while(mpcmp(p, q) == 0);
	mpmul(p, q, n);
	// p-1 and q-1 in numbers of their own, which are cleared when
	// they are freed.  They were made in e and d: the public exponent
	// then had p-1's digits above its own in its buffer, and d's first
	// buffer, with q-1 in it, was given back to the pool as it was
	// when d grew.
	t1 = mpnew(nlen);
	t2 = mpnew(nlen);
	mpsub(p, mpone, t1);
	mpsub(q, mpone, t2);
	mpmul(t1, t2, phi);

	// find an e relatively prime to phi: of elen bits exactly, and
	// odd (an even one has no inverse; FIPS 186-5 A.1.1 wants it odd
	// and above 2^16, which a caller that asks for 17 bits or more
	// now gets: the top bit asked for was set one time in two)
	mprand(elen, genrandom, e);
	if(elen >= 2 && elen <= mpsignif(phi) - 2){
		mpleft(mpone, elen-1, t1);
		if(mpcmp(e, t1) < 0)
			mpadd(e, t1, e);
	}
	if(e->top > 0)
		e->p[0] |= 1;
	if(mpcmp(e,mptwo) <= 0)
		itomp(3, e);
	// See Menezes et al. p.291 "8.8 Note (selecting primes)" for discussion
	// of the merits of various choices of primes and exponents.  e=3 is a
	// common and recommended exponent, but doesn't necessarily work here
	// because we chose strong rather than safe primes.
	for(;;){
		mpextendedgcd(e, phi, t1, d, t2);
		if(mpcmp(t1, mpone) == 0)
			break;
		mpadd(mptwo, e, e);	// the next odd one
	}
	mpfree(t1);
	mpfree(t2);
	// the gcd's coefficient is negative as often as not: d is the
	// least positive one (RFC 8017 3.2), the number a key's text holds
	// (a negative d was written as its magnitude, which is not e's
	// inverse, and rsafill refused the key rsagen had made)
	mpmod(d, phi, d);

	// compute chinese remainder coefficient
	c2 = mpnew(0);
	mpinvert(p, q, c2);

	// for crt a**k mod p == (a**(k mod p-1)) mod p
	kq = mpnew(0);
	kp = mpnew(0);
	mpsub(p, mpone, phi);
	mpmod(d, phi, kp);
	mpsub(q, mpone, phi);
	mpmod(d, phi, kq);

	rsa = rsaprivalloc();
	rsa->pub.ek = e;
	rsa->pub.n = n;
	rsa->dk = d;
	rsa->kp = kp;
	rsa->kq = kq;
	rsa->p = p;
	rsa->q = q;
	rsa->c2 = c2;

	mpfree(phi);

	return rsa;
}
