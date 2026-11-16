#include "os.h"
#include <mp.h>
#include <libsec.h>

// decrypt rsa using garner's algorithm for the chinese remainder theorem
//	seminumerical algorithms, knuth, pp 253-254
//	applied cryptography, menezes et al, pg 612
mpint*
rsadecrypt(RSApriv *rsa, mpint *in, mpint *out)
{
	mpint *v1, *v2, *made;

	// RFC 8017 5.1.2 and 5.2.1, step 1: a representative is between 0
	// and n-1, or there is no result (nil)
	if(in->sign < 0 || mpcmp(in, rsa->pub.n) >= 0){
		werrstr("rsadecrypt: representative out of range");
		return nil;
	}

	made = nil;
	if(out == nil)
		out = made = mpnew(0);

	// convert in to modular representation
	v1 = mpnew(0);
	mpmod(in, rsa->p, v1);
	v2 = mpnew(0);
	mpmod(in, rsa->q, v2);

	// exponentiate the modular rep
	mpexp(v1, rsa->kp, rsa->p, v1);
	mpexp(v2, rsa->kq, rsa->q, v2);
	
	// out = v1 + p*((v2-v1)*c2 mod q)
	mpsub(v2, v1, v2);
	mpmul(v2, rsa->c2, v2);
	mpmod(v2, rsa->q, v2);
	mpmul(v2, rsa->p, out);
	mpadd(v1, out, out);

	// The result is checked before it is given out: out^e mod n is
	// the input, or there is no result.  With one of kp, kq and c2 not
	// the key's (a damaged key file, a fault in the computation) the
	// result is right mod one prime and wrong mod the other, and a
	// signature made so gives the modulus's factors to whoever sees it
	// (Boneh, DeMillo and Lipton, 1997).  One public operation.
	mpexp(out, rsa->pub.ek, rsa->pub.n, v1);
	if(mpcmp(v1, in) != 0){
		mpfree(v1);
		mpfree(v2);
		if(made != nil)
			mpfree(made);
		else
			mpassign(mpzero, out);
		werrstr("rsadecrypt: the key's parts do not agree");
		return nil;
	}

	mpfree(v1);
	mpfree(v2);

	return out;
}
