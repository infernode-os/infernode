#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * RSA's private operation (RFC 8017 5.1.2, RSADP, and 5.2.1, RSASP1),
 * by the Chinese remainder theorem.
 *
 * What is secret here is the key: p, q, kp, kq and c2.  It was done
 * with libmp's general arithmetic: the input divided by p and by q,
 * each power's base put into Montgomery form by another division by
 * the prime, and Garner's recombination a subtraction, a product and a
 * third division by q.  libmp's division takes a time that follows its
 * divisor's digits and the dividend's, and whoever could have a number
 * of his choosing signed or decrypted and time it (Kocher 1996;
 * Brumley and Boneh 2003, over a network) was measuring the primes.
 *
 * Two things now stand between the key and the clock:
 *
 * - The operation itself is libmp's mpexpcrt, which does both powers
 *   and the recombination in Montgomery arithmetic at the primes'
 *   length, with no division and no branch or address that depends on
 *   p, q, kp, kq, c2 or the input.  tests/host/rsa_edge_test.sh runs it
 *   under valgrind with all of them marked secret.
 *
 * - The input is blinded: it is multiplied by r^e for an r drawn for
 *   this call alone, and the result divided by r.  So the numbers the
 *   private operation works on are not ones anybody chose or knows,
 *   whatever is still variable in it or under it (a multiplier whose
 *   time depends on its operands; a fault).  The generator is
 *   genrandom, which gives nothing rather than something guessable.
 *
 * The products that blind and unblind are mpmuladdmod's, constant time
 * too.  What is not constant time, and why it does not matter: r's
 * inverse mod n is the extended Euclidean algorithm's, whose time
 * follows r, a number used once that has nothing of the key in it; the
 * check compares two numbers that are equal unless the key is broken;
 * every number's leading zero digits are trimmed (mpnorm); and a key
 * whose numbers mpexpcrt does not take (a negative one, a CRT part
 * longer than its prime: no key rsagen, rsafill or a key file makes)
 * goes through the old arithmetic, blinded.
 */

/* the operation as it was, for primes of unlike lengths: x is blinded */
static void
crtgeneral(RSApriv *rsa, mpint *x, mpint *y)
{
	mpint *v1, *v2;

	v1 = mpnew(0);
	mpmod(x, rsa->p, v1);
	v2 = mpnew(0);
	mpmod(x, rsa->q, v2);
	mpexp(v1, rsa->kp, rsa->p, v1);
	mpexp(v2, rsa->kq, rsa->q, v2);
	// y = v1 + p*((v2-v1)*c2 mod q)
	mpsub(v2, v1, v2);
	mpmul(v2, rsa->c2, v2);
	mpmod(v2, rsa->q, v2);
	mpmul(v2, rsa->p, y);
	mpadd(v1, y, y);
	mpfree(v1);
	mpfree(v2);
}

mpint*
rsadecrypt(RSApriv *rsa, mpint *in, mpint *out)
{
	mpint *r, *ri, *g, *x, *y, *t, *n;
	int i, nbits, ok;

	n = rsa->pub.n;
	// RFC 8017 5.1.2 and 5.2.1, step 1: a representative is between 0
	// and n-1, or there is no result (nil)
	if(in->sign < 0 || mpcmp(in, n) >= 0){
		werrstr("rsadecrypt: representative out of range");
		return nil;
	}
	nbits = mpsignif(n);
	if(nbits < 2){
		werrstr("rsadecrypt: no modulus");
		return nil;
	}

	r = mpnew(0);
	ri = mpnew(0);
	g = mpnew(0);
	x = mpnew(0);
	y = mpnew(0);
	t = mpnew(0);

	// r, with an inverse mod n (all but a few numbers have one, and
	// one that has none would be the modulus's factor: but a key that
	// is no key is not a reason to loop)
	ok = 0;
	for(i = 0; i < 8 && !ok; i++){
		mprand(nbits-1, genrandom, r);
		if(r->top == 0)
			continue;
		mpextendedgcd(r, n, g, ri, t);
		if(mpcmp(g, mpone) == 0){
			mpmod(ri, n, ri);
			ok = 1;
		}
	}
	if(!ok){
		werrstr("rsadecrypt: no blinding number");
		goto Bad;
	}

	// x = in * r^e mod n
	mpexp(r, rsa->pub.ek, n, t);
	mpmuladdmod(in, t, nil, n, x);

	// y = x^d mod n
	if(mpexpcrt(x, rsa->p, rsa->q, rsa->kp, rsa->kq, rsa->c2, y) < 0)
		crtgeneral(rsa, x, y);

	// The result is checked before it is given out: y^e mod n is
	// x, or there is no result.  With one of kp, kq and c2 not
	// the key's (a damaged key file, a fault in the computation) the
	// result is right mod one prime and wrong mod the other, and a
	// signature made so gives the modulus's factors to whoever sees it
	// (Boneh, DeMillo and Lipton, 1997).  One public operation, on the
	// blinded numbers.
	mpexp(y, rsa->pub.ek, n, t);
	if(mpcmp(t, x) != 0){
		werrstr("rsadecrypt: the key's parts do not agree");
		goto Bad;
	}

	// out = y/r mod n
	if(out == nil)
		out = mpnew(0);
	mpmuladdmod(y, ri, nil, n, out);

	mpfree(r);
	mpfree(ri);
	mpfree(g);
	mpfree(x);
	mpfree(y);
	mpfree(t);
	return out;

Bad:
	mpfree(r);
	mpfree(ri);
	mpfree(g);
	mpfree(x);
	mpfree(y);
	mpfree(t);
	if(out != nil)
		mpassign(mpzero, out);
	return nil;
}
