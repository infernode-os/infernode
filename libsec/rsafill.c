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

	// make sure we're not being hoodwinked
	if(!probably_prime(p, 10) || !probably_prime(q, 10)){
		werrstr("rsafill: p or q not prime");
		return nil;
	}
	x = mpnew(0);
	mpmul(p, q, x);
	if(mpcmp(n, x) != 0){
		werrstr("rsafill: n != p*q");
		mpfree(x);
		return nil;
	}
	c2 = mpnew(0);
	mpsub(p, mpone, c2);
	mpsub(q, mpone, x);
	mpmul(c2, x, x);
	mpmul(e, d, c2);
	mpmod(c2, x, x);
	if(mpcmp(x, mpone) != 0){
		werrstr("rsafill: e*d != 1 mod (p-1)*(q-1)");
		mpfree(x);
		mpfree(c2);
		return nil;
	}

	// compute chinese remainder coefficient.  p and q are only
	// probably prime: if p has no inverse mod q this is no key (not
	// mpinvert's raise, with these numbers held)
	kq = mpnew(0);
	kp = mpnew(0);
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

