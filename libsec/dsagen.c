#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * Whether p and q can be a DSA key's (FIPS 186-4 4.1): q divides p-1
 * and both are prime.  0 if so, else -1.  dsagen asks, before it makes
 * anything, of parameters taken from another key, which are a
 * program's (DSAsk.gen) or a file's (genSKfromPK).  It did not: a q
 * that does not divide p-1 was its "dsagen foul up", raised with nine
 * numbers made and nothing to free them (3200 bytes of the kernel's
 * pool a call), and for a p that is no prime the search below for a
 * generator of order q need never end.  A Carmichael number p (the
 * product of three primes of a kind) with q a factor of p-1 made it
 * so: g^((p-1)/q) was 1 for every g prime to p, the search went on
 * for ever, and could not be killed.
 */
int
dsaparamsok(mpint *p, mpint *q)
{
	mpint *t, *r;
	int ok;

	if(p->sign < 0 || q->sign < 0 || mpcmp(q, mpone) <= 0 || mpcmp(p, q) <= 0)
		return -1;
	t = mpnew(0);
	r = mpnew(0);
	mpsub(p, mpone, t);
	mpmod(t, q, r);
	ok = r->top == 0;
	mpfree(t);
	mpfree(r);
	if(!ok)
		return -1;
	if(!probably_prime(q, 0) || !probably_prime(p, 0))
		return -1;
	return 0;
}

DSApriv*
dsagen(DSApub *opub)
{
	DSApub *pub;
	DSApriv *priv;
	mpint *exp;
	mpint *g;
	mpint *r;
	int bits, qbits, tries;

	if(opub != nil && dsaparamsok(opub->p, opub->q) < 0)
		sysfatal("dsagen: p and q are not a DSA key's");

	priv = dsaprivalloc();
	pub = &priv->pub;

	if(opub != nil){
		pub->p = mpcopy(opub->p);
		pub->q = mpcopy(opub->q);
	} else {
		pub->p = mpnew(0);
		pub->q = mpnew(0);
		DSAprimes(pub->q, pub->p, nil);
	}
	bits = Dbits*pub->p->top;

	pub->alpha = mpnew(0);
	pub->key = mpnew(0);
	priv->secret = mpnew(0);

	// find a generator alpha of the subgroup of order q of the
	// multiplicative group Z*p: g to the power (p-1)/q, for any g
	// for which that is not 1 (or 0, which a g of 0 makes it).  For a
	// prime p one g in q fails; the search is bounded all the same,
	// as nothing can end it from outside.
	exp = mpnew(0);
	g = mpnew(0);
	r = mpnew(0);
	mpsub(pub->p, mpone, exp);
	mpdiv(exp, pub->q, exp, r);
	for(tries = 0; ; tries++){
		if(tries >= 256 || mpcmp(r, mpzero) != 0){
			mpfree(g);
			mpfree(exp);
			mpfree(r);
			dsaprivfree(priv);
			sysfatal("dsagen: no generator of order q");
		}
		mprand(bits, genrandom, g);
		mpmod(g, pub->p, g);
		mpexp(g, exp, pub->p, pub->alpha);
		if(pub->alpha->top != 0 && mpcmp(pub->alpha, mpone) != 0)
			break;
	}
	mpfree(g);
	mpfree(exp);
	mpfree(r);	// (it never was: 384 bytes a key)

	// create the secret key: from 1 to q-1 (FIPS 186-4 B.1.2).  It was
	// drawn below p, a number libkeyring's own reader of keys refuses
	// (it wants one below q), so a DSA key written to a file could not
	// be read back.
	qbits = mpsignif(pub->q);
	do
		mprand(qbits, genrandom, priv->secret);
	while(mpcmp(priv->secret, mpone) < 0 || mpcmp(priv->secret, pub->q) >= 0);
	mpexp(pub->alpha, priv->secret, pub->p, pub->key);

	return priv;
}
