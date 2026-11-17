#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * A DSA signature (FIPS 186-4 4.6): r = (alpha^k mod p) mod q,
 * s = (m + x*r)/k mod q.
 *
 * What is secret is the key x and, as much, the nonce k: a few bits of
 * k over some signatures give x.
 *
 * - k is RFC 6979's (nonce.c), from x, m and 32 random bytes: it was
 *   the generator's alone, so a generator whose state repeats signed
 *   two messages with one k.  dsasignrnd is given the bytes (none: the
 *   RFC's k exactly, for known answers).
 * - 1/k is k^(q-2) mod q, by the constant-time mpexp (q is prime:
 *   Fermat).  It was the extended binary GCD, every step of which
 *   follows k's bits.
 * - s is made with mpmuladdmod, in constant time for x, k and their
 *   products; it was mpmul and a division.
 * - alpha^k mod p is mpexp, constant time in k.
 *
 * k*(1/k) is checked to be 1, which it is not when q is not a prime
 * (a key filled in by hand): there is then no signature.  nil is also
 * the answer when no k gives one in Tries, which no real key reaches
 * (the loop was without end), and when there is no memory.
 */
enum
{
	Tries=	100,
	Rndlen=	32,
};

DSAsig*
dsasignrnd(DSApriv *priv, mpint *m, uchar *rnd, int nrnd)
{
	DSApub *pub = &priv->pub;
	DSAsig *sig;
	Noncestate ns;
	mpint *qm2, *k, *kinv, *r, *s, *mq, *t;
	mpint *q = pub->q, *p = pub->p, *alpha = pub->alpha;
	int i, ok;

	if(q->sign < 0 || mpcmp(q, mptwo) <= 0 || p->sign < 0 || p->top == 0){
		werrstr("dsasign: no group");
		return nil;
	}
	if(mpnoncestart(&ns, priv->secret, m, q, rnd, nrnd) < 0)
		return nil;

	qm2 = mpnew(0);
	kinv = mpnew(0);
	r = mpnew(0);
	s = mpnew(0);
	k = mpnew(0);
	mq = mpnew(0);
	t = mpnew(0);
	mpsub(q, mptwo, qm2);
	mpmod(m, q, mq);

	// find a k for which neither r nor s is 0 (FIPS 186-4 4.6:
	// another k then).  An s of 0 was given out: no verifier takes
	// it, and it tells the secret (-m/r mod q).
	sig = nil;
	for(i = 0; i < Tries; i++){
		ok = mpnoncenext(&ns, q, k);
		if(ok < 0)
			break;
		if(ok == 0)
			continue;

		mpexp(k, qm2, q, kinv);
		mpmuladdmod(k, kinv, nil, q, t);
		if(mpcmp(t, mpone) != 0){
			werrstr("dsasign: pub->q not prime");
			break;
		}

		// r = ((alpha**k) mod p) mod q
		mpexp(alpha, k, p, r);
		mpmod(r, q, r);
		if(r->top == 0)
			continue;

		// s = (kinv*(m + xr)) mod q
		mpmuladdmod(r, priv->secret, mq, q, s);
		mpmuladdmod(s, kinv, nil, q, s);
		if(s->top == 0)
			continue;

		sig = dsasigalloc();
		sig->r = r;
		sig->s = s;
		break;
	}
	if(sig == nil){
		if(i == Tries)
			werrstr("dsasign: no signature");
		mpfree(r);
		mpfree(s);
	}
	nonceclear(&ns);
	mpfree(qm2);
	mpfree(k);
	mpfree(kinv);
	mpfree(mq);
	mpfree(t);
	return sig;
}

DSAsig*
dsasign(DSApriv *priv, mpint *m)
{
	uchar rnd[Rndlen];
	DSAsig *sig;

	genrandom(rnd, sizeof rnd);
	sig = dsasignrnd(priv, m, rnd, sizeof rnd);
	secureZero(rnd, sizeof rnd);
	return sig;
}
