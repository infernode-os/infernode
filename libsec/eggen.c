#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * alpha: a generator of the subgroup of order q = (p-1)/2, p a prime
 * 2q+1 with q prime, that does not divide p-1: the square of a random
 * number.  Its logarithm to any base is nobody's to know, which
 * matters: see egverify.c.  There is none for p = 5 (the subgroup is 1
 * and 4, and 4 is p-1), and the caller does not ask.
 */
static void
eggenerator(mpint *p, mpint *alpha)
{
	mpint *pm1, *t;

	pm1 = mpnew(0);
	t = mpnew(0);
	mpsub(p, mpone, pm1);
	for(;;){
		mprand(mpsignif(p), genrandom, alpha);
		mpmod(alpha, p, alpha);
		mpmul(alpha, alpha, t);
		mpmod(t, p, alpha);
		if(mpcmp(alpha, mpone) <= 0 || mpcmp(alpha, pm1) >= 0)
			continue;
		mpmod(pm1, alpha, t);
		if(t->top != 0)
			break;
	}
	mpfree(pm1);
	mpfree(t);
}

/*
 * The secret and the public value for priv's p and alpha: the secret
 * from 1 to q-1, the exponents alpha has (it was drawn below p, and
 * could be 0), and not 1 where there is another to have.
 */
void
egsecret(EGpriv *priv)
{
	EGpub *pub;
	mpint *q;
	int qlen;

	pub = &priv->pub;
	q = mpnew(0);
	mpright(pub->p, 1, q);
	qlen = mpsignif(q);
	for(;;){
		mprand(qlen, genrandom, priv->secret);
		if(mpcmp(priv->secret, mpone) < 0 || mpcmp(priv->secret, q) >= 0)
			continue;
		if(mpcmp(priv->secret, mpone) == 0 && mpcmp(q, mptwo) > 0 && qlen > 2)
			continue;
		break;
	}
	mpexp(pub->alpha, priv->secret, pub->p, pub->key);
	mpfree(q);
}

EGpriv*
eggen(int nlen, int rounds)
{
	EGpub *pub;
	EGpriv *priv;
	mpint *g;

	priv = egprivalloc();
	pub = &priv->pub;
	pub->p = mpnew(0);
	pub->alpha = mpnew(0);
	pub->key = mpnew(0);
	priv->secret = mpnew(0);

	/*
	 * RFC 3526's prime if there is one for this size, but not its
	 * generator: that is 2, which divides p-1, and with such a
	 * generator a signature on any message is made from the public
	 * key alone (see egverify.c).  2 is right for Diffie-Hellman,
	 * which is what getdhparams is for.
	 */
	g = mpnew(0);
	for(;;){
		if(!getdhparams(nlen, pub->p, g))
			gensafeprime(pub->p, g, nlen, rounds);
		if(mpsignif(pub->p) > 3 || mptoi(pub->p) != 5)
			break;
	}
	mpfree(g);
	eggenerator(pub->p, pub->alpha);
	egsecret(priv);
	return priv;
}
