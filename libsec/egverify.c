#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * ElGamal signatures, and which keys they may be checked with.
 *
 * The check is key^r r^s = alpha^m (mod p), and it asked of r only
 * that it lie from 1 to p-1.  Bleichenbacher ("Generating ElGamal
 * signatures without knowing the secret key", Eurocrypt 1996; the
 * Handbook of Applied Cryptography, 11.66) showed what that leaves.
 * Where alpha divides p-1, r = (p-1)/alpha is a known power of alpha
 * and key^r lies in a subgroup small enough to search, and a
 * signature on any message follows from the public key.  The keys made
 * here at 2048 bits were such keys: RFC 3526's prime with its
 * generator 2, which divides p-1.  With r = (p-1)/2, key^r is 1 for
 * every key (2 has order (p-1)/2 there) and r is -1/2, so r^s is
 * 2^-s for an even s: any message, any key, no secret.  The same r
 * serves for any alpha that is a known power of 2 (4, say): what the
 * forger needs is r's logarithm, not that alpha divide p-1.
 *
 * So, in a group whose prime p is 2q+1 with q prime (the only primes
 * made here):
 *
 *  - a key's generator and public value must lie in the subgroup of
 *    order q (alpha^q = key^q = 1, neither of them 1), and alpha must
 *    not divide p-1;
 *  - r must lie in that subgroup as well (r^q = 1), as alpha^k does.
 *    The r's that make key^r trivial are the multiples of q, which are
 *    q and p-1, and neither is in the subgroup: both are refused,
 *    whatever alpha is;
 *  - s is from 1 to p-2 (it was any number: s + (p-1) was a second
 *    form of one signature, and s = 0 is a signature that gives the
 *    secret away, which egsign no longer makes).
 *
 * What cannot be told here is whether p and q are prime: testing them
 * costs dozens of exponentiations of the modulus's size, and a key is
 * read for every authentication.  The tests above hold for any odd p
 * with q = (p-1)/2, and they are what stops the forgeries above; for a
 * p that is not such a prime the subgroup has factors of its own that
 * the key's maker chose.  egsafeprime tests them, and is asked where a
 * key is made from another's parameters or a secret key is read.
 *
 * A generator that divides p-1 is refused although the test of r
 * stops its forgery here: such a key is forgeable for every verifier
 * that has not that test, and must be made again.  All ElGamal keys
 * this code made before are refused: the 2048-bit ones for their
 * generator 2, the others because their generator had order 2q.
 */

/* (p-1)/2, or nil if p is not an odd number past 3 */
static mpint*
halfgroup(mpint *p)
{
	mpint *q;

	if(p->sign < 0 || p->top == 0 || (p->p[0] & 1) == 0 || mpcmp(p, mptwo) <= 0)
		return nil;
	q = mpnew(0);
	mpright(p, 1, q);
	return q;
}

/* 0 if pub is a key signatures may be checked with, else -1 */
int
egpubvalid(EGpub *pub)
{
	mpint *p, *q, *pm1, *t;
	int ok;

	p = pub->p;
	q = halfgroup(p);
	if(q == nil)
		return -1;
	pm1 = mpnew(0);
	t = mpnew(0);
	mpsub(p, mpone, pm1);
	/* 1 < alpha, key < p-1 */
	ok = mpcmp(pub->alpha, mpone) > 0 && mpcmp(pub->alpha, pm1) < 0
		&& mpcmp(pub->key, mpone) > 0 && mpcmp(pub->key, pm1) < 0;
	if(ok){
		mpmod(pm1, pub->alpha, t);
		ok = t->top != 0;	/* alpha does not divide p-1 */
	}
	if(ok){
		mpexp(pub->alpha, q, p, t);
		ok = mpcmp(t, mpone) == 0;
	}
	if(ok){
		mpexp(pub->key, q, p, t);
		ok = mpcmp(t, mpone) == 0;
	}
	mpfree(q);
	mpfree(pm1);
	mpfree(t);
	return ok? 0: -1;
}

/* 0 if p and (p-1)/2 are (probably) prime, else -1 */
int
egsafeprime(mpint *p)
{
	mpint *q;
	int ok;

	q = halfgroup(p);
	if(q == nil)
		return -1;
	ok = probably_prime(q, 0) && probably_prime(p, 0);
	mpfree(q);
	return ok? 0: -1;
}

int
egverify(EGpub *pub, EGsig *sig, mpint *m)
{
	mpint *p = pub->p, *alpha = pub->alpha;
	mpint *r = sig->r, *s = sig->s;
	mpint *v1, *v2, *rs, *q;
	int rv = -1;

	if(egpubvalid(pub) < 0)
		return rv;
	/* 1 <= r <= p-1, 1 <= s <= p-2; m is an exponent */
	if(mpcmp(r, mpone) < 0 || mpcmp(r, p) >= 0)
		return rv;
	if(mpcmp(s, mpone) < 0 || m->sign < 0)
		return rv;
	q = halfgroup(p);
	v1 = mpnew(0);
	rs = mpnew(0);
	v2 = mpnew(0);
	mpsub(p, mpone, v1);
	if(mpcmp(s, v1) >= 0)
		goto out;
	/* r in the subgroup alpha generates */
	mpexp(r, q, p, v1);
	if(mpcmp(v1, mpone) != 0)
		goto out;
	mpexp(pub->key, r, p, v1);
	mpexp(r, s, p, rs);
	mpmul(v1, rs, v1);
	mpmod(v1, p, v1);
	mpexp(alpha, m, p, v2);
	if(mpcmp(v1, v2) == 0)
		rv = 0;
out:
	mpfree(q);
	mpfree(v1);
	mpfree(rs);
	mpfree(v2);
	return rv;
}
