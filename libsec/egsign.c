#include "os.h"
#include <mp.h>
#include <libsec.h>

EGsig*
egsign(EGpriv *priv, mpint *m)
{
	EGpub *pub = &priv->pub;
	EGsig *sig;
	mpint *pm1, *k, *kinv, *r, *s;
	mpint *p = pub->p, *alpha = pub->alpha;
	int plen = mpsignif(p);

	pm1 = mpnew(0);
	kinv = mpnew(0);
	r = mpnew(0);
	s = mpnew(0);
	k = mpnew(0);
	mpsub(p, mpone, pm1);
	while(1){
		mprand(plen, genrandom, k);
		if((mpcmp(mpone, k) > 0) || (mpcmp(k, pm1) >= 0))
			continue;
		mpextendedgcd(k, pm1, r, kinv, s);
		if(mpcmp(r, mpone) != 0)
			continue;
		mpmod(kinv, pm1, kinv);  // make kinv positive
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
		break;
	}
	sig = egsigalloc();
	sig->r = r;
	sig->s = s;
	mpfree(pm1);
	mpfree(k);
	mpfree(kinv);
	return sig;
}
