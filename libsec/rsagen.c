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
	d = mpnew(0);
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
	mpsub(p, mpone, e);
	mpsub(q, mpone, d);
	mpmul(e, d, phi);

	// find an e relatively prime to phi
	t1 = mpnew(0);
	t2 = mpnew(0);
	mprand(elen, genrandom, e);
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
		mpadd(mpone, e, e);
	}
	mpfree(t1);
	mpfree(t2);

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
