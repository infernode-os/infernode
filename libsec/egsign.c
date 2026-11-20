#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * An ElGamal signature: r = alpha^k mod p, s = (m - x*r)/k mod p-1,
 * for a k with an inverse mod p-1.
 *
 * As with DSA, the nonce k is as secret as the key x.
 *
 * - k is RFC 6979's (nonce.c), from x, m and 32 random bytes, where it
 *   was the generator's alone.  egsignrnd is given the bytes.
 * - 1/k mod p-1 cannot be a power as DSA's is (p-1 is not prime), and
 *   the extended binary GCD follows every bit of what it inverts.  So
 *   it is blinded: k*b mod p-1 is inverted for a random b that has an
 *   inverse, and the result multiplied by b.  What the GCD then works
 *   on is a number that says nothing of k.
 * - alpha^k mod p is mpexp, constant time in k.
 *
 * What is not constant time: the arithmetic mod p-1, which is even, so
 * that Montgomery's does not serve.  The products and divisions that
 * make k*b, 1/k and s are libmp's general ones, whose time follows
 * their operands' digits in the rare steps Knuth's division corrects a
 * digit, on numbers the blinding or the random r have made unlike the
 * secrets.  (DSA and Ed25519 have no such part; ElGamal is here for
 * the keys there are.)
 *
 * nil when no k gives a signature in Tries, which no real key reaches,
 * and when there is no memory.
 */
enum
{
	Tries=	200,
	Rndlen=	32,
};

EGsig*
egsignrnd(EGpriv *priv, mpint *m, uchar *rnd, int nrnd)
{
	EGpub *pub = &priv->pub;
	EGsig *sig;
	Noncestate ns;
	mpint *pm1, *k, *kinv, *r, *s, *b, *g, *t;
	mpint *p = pub->p, *alpha = pub->alpha;
	int i, j, ok, plen;

	if(p->sign < 0 || mpcmp(p, mptwo) <= 0){
		werrstr("egsign: no group");
		return nil;
	}
	pm1 = mpnew(0);
	mpsub(p, mpone, pm1);
	if(mpnoncestart(&ns, priv->secret, m, pm1, rnd, nrnd) < 0){
		mpfree(pm1);
		return nil;
	}
	plen = mpsignif(pm1);
	kinv = mpnew(0);
	r = mpnew(0);
	s = mpnew(0);
	k = mpnew(0);
	b = mpnew(0);
	g = mpnew(0);
	t = mpnew(0);
	sig = nil;
	for(i = 0; i < Tries; i++){
		ok = mpnoncenext(&ns, pm1, k);
		if(ok < 0)
			break;
		if(ok == 0)
			continue;

		// b with an inverse mod p-1: an odd number often has
		for(j = 0; j < Tries; j++){
			mprand(plen-1, genrandom, b);
			if(b->top == 0)
				continue;
			b->p[0] |= 1;
			mpextendedgcd(b, pm1, g, t, s);
			if(mpcmp(g, mpone) == 0)
				break;
		}
		if(j == Tries)
			break;
		// 1/k = b/(k*b); with no inverse (k shares a factor with p-1), another k
		mpmul(k, b, t);
		mpmod(t, pm1, t);
		mpextendedgcd(t, pm1, g, kinv, s);
		if(mpcmp(g, mpone) != 0)
			continue;
		mpmod(kinv, pm1, kinv);
		mpmul(kinv, b, kinv);
		mpmod(kinv, pm1, kinv);

		mpexp(alpha, k, p, r);
		mpmul(priv->secret, r, s);
		mpmod(s, pm1, s);
		mpsub(m, s, s);
		mpmul(kinv, s, s);
		mpmod(s, pm1, s);
		// an s of 0 is m = secret*r mod p-1 told to whoever sees it,
		// and no signature (egverify): another k
		if(s->top == 0)
			continue;

		sig = egsigalloc();
		sig->r = r;
		sig->s = s;
		break;
	}
	if(sig == nil){
		werrstr("egsign: no signature");
		mpfree(r);
		mpfree(s);
	}
	nonceclear(&ns);
	mpfree(pm1);
	mpfree(k);
	mpfree(kinv);
	mpfree(b);
	mpfree(g);
	mpfree(t);
	return sig;
}

EGsig*
egsign(EGpriv *priv, mpint *m)
{
	uchar rnd[Rndlen];
	EGsig *sig;

	genrandom(rnd, sizeof rnd);
	sig = egsignrnd(priv, m, rnd, sizeof rnd);
	secureZero(rnd, sizeof rnd);
	return sig;
}
