#include "os.h"
#include <mp.h>
#include <libsec.h>

DSAsig*
dsasign(DSApriv *priv, mpint *m)
{
	DSApub *pub = &priv->pub;
	DSAsig *sig;
	mpint *qm1, *k, *kinv, *r, *s;
	mpint *q = pub->q, *p = pub->p, *alpha = pub->alpha;
	int qlen = mpsignif(q);

	qm1 = mpnew(0);
	kinv = mpnew(0);
	r = mpnew(0);
	s = mpnew(0);
	k = mpnew(0);
	mpsub(pub->q, mpone, qm1);

	// find a k that has an inverse mod q, and for which neither r nor
	// s is 0 (FIPS 186-4 4.6: another k then).  An s of 0 was given
	// out: no verifier takes it, and it tells the secret (-m/r mod q).
	while(1){
		mprand(qlen, genrandom, k);
		if((mpcmp(mpone, k) > 0) || (mpcmp(k, pub->q) >= 0))
			continue;
		mpextendedgcd(k, q, r, kinv, s);
		if(mpcmp(r, mpone) != 0){
			// (what is held, given back first: the raise lost it,
			// 800 bytes of the kernel's pool a call)
			mpfree(qm1);
			mpfree(k);
			mpfree(kinv);
			mpfree(r);
			mpfree(s);
			sysfatal("dsasign: pub->q not prime");
		}

		// make kinv positive
		mpmod(kinv, pub->q, kinv);

		// r = ((alpha**k) mod p) mod q
		mpexp(alpha, k, p, r);
		mpmod(r, q, r);
		if(r->top == 0)
			continue;

		// s = (kinv*(m + ar)) mod q
		mpmul(r, priv->secret, s);
		mpadd(s, m, s);
		mpmul(s, kinv, s);
		mpmod(s, q, s);
		if(s->top == 0)
			continue;
		break;
	}

	sig = dsasigalloc();
	sig->r = r;
	sig->s = s;
	mpfree(qm1);
	mpfree(k);
	mpfree(kinv);
	return sig;
}
