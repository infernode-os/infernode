#include "os.h"
#include <mp.h>
#include <libsec.h>

RSApriv*
rsafill(mpint *n, mpint *e, mpint *d, mpint *p, mpint *q)
{
	mpint *c2, *kq, *kp, *x;
	RSApriv *rsa;

	// The parts are the caller's, a Limbo program's through
	// RSAsk.fill.  A negative p or q raised in probably_prime where nil
	// is the refusal, and negative e or d made a key every use of
	// which raised; p equal to q has no CRT coefficient, and mpinvert
	// raised for it with x and c2 made and nothing to free them: 768
	// bytes of the kernel's pool a call, for good.  (RFC 8017 3.2: the
	// primes are distinct.)
	if(n->sign < 0 || e->sign < 0 || d->sign < 0 || p->sign < 0 || q->sign < 0){
		werrstr("rsafill: negative number");
		return nil;
	}
	if(mpcmp(p, q) == 0){
		werrstr("rsafill: p == q");
		return nil;
	}

	// The cheap check before the dear one: the primes are the
	// modulus's.
	x = mpnew(0);
	mpmul(p, q, x);
	if(mpcmp(n, x) != 0){
		werrstr("rsafill: n != p*q");
		mpfree(x);
		return nil;
	}
	mpfree(x);

	// make sure we're not being hoodwinked
	if(!probably_prime(p, 10) || !probably_prime(q, 10)){
		werrstr("rsafill: p or q not prime");
		return nil;
	}

	// e*d is 1 mod lambda = lcm(p-1, q-1): that, and no more, is
	// what makes d undo e (RFC 8017 3.2; FIPS 186-5 A.1.1 defines d
	// so).  The test was mod (p-1)*(q-1), which the d of a key made
	// elsewhere need not satisfy (OpenSSL writes the least d, mod
	// lambda): such keys were refused.  A d that passed the old test
	// passes this one.  And e is more than 1: with e = d = 1, which
	// passed, the key changes nothing it is applied to; so is any e
	// that is 1 mod lambda.
	x = mpnew(0);
	c2 = mpnew(0);
	kq = mpnew(0);
	kp = mpnew(0);
	mpsub(p, mpone, c2);
	mpsub(q, mpone, x);
	mpextendedgcd(c2, x, kq, kp, kp);	// kq = gcd(p-1, q-1)
	mpmul(c2, x, x);
	mpdiv(x, kq, x, nil);			// lambda
	mpmod(e, x, c2);
	if(mpcmp(e, mpone) <= 0 || mpcmp(d, mpone) <= 0 || mpcmp(c2, mpone) == 0){
		werrstr("rsafill: e or d is 1");
		mpfree(x);
		mpfree(c2);
		mpfree(kq);
		mpfree(kp);
		return nil;
	}
	mpmul(e, d, c2);
	mpmod(c2, x, c2);
	if(mpcmp(c2, mpone) != 0){
		werrstr("rsafill: e*d != 1 mod lcm(p-1, q-1)");
		mpfree(x);
		mpfree(c2);
		mpfree(kq);
		mpfree(kp);
		return nil;
	}

	// compute chinese remainder coefficient.  p and q are only
	// probably prime: if p has no inverse mod q this is no key (not
	// mpinvert's raise, with these numbers held)
	mpextendedgcd(p, q, kq, c2, kp);
	if(mpcmp(kq, mpone) != 0){
		werrstr("rsafill: p has no inverse mod q");
		mpfree(x);
		mpfree(c2);
		mpfree(kq);
		mpfree(kp);
		return nil;
	}
	mpmod(c2, q, c2);

	// for crt a**k mod p == (a**(k mod p-1)) mod p
	mpsub(p, mpone, x);
	mpmod(d, x, kp);
	mpsub(q, mpone, x);
	mpmod(d, x, kq);

	rsa = rsaprivalloc();
	rsa->pub.ek = mpcopy(e);
	rsa->pub.n = mpcopy(n);
	rsa->dk = mpcopy(d);
	rsa->kp = kp;
	rsa->kq = kq;
	rsa->p = mpcopy(p);
	rsa->q = mpcopy(q);
	rsa->c2 = c2;

	mpfree(x);

	return rsa;
}

