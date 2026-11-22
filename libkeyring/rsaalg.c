#include <lib9.h>
#include <kernel.h>
#include <isa.h>
#include "interp.h"
#include "../libinterp/keyringif.h"
#include "mp.h"
#include "libsec.h"
#include "keys.h"

static char*	pkattr[] = { "n", "ek", nil };
static char*	skattr[] = { "n", "ek", "!dk", "!p", "!q", "!kp", "!kq", "!c2", nil };
static char*	sigattr[] = { "val", nil };

enum
{
	/* the least rsagen can make primes for; not a size to use */
	MinRSAgen	= 16,
	/* and the most: past it nothing returns, and near the largest int the digit counts wrap */
	MaxRSAgen	= 1<<16,
	/* the public exponent: FIPS 186-5 A.1.1 has it odd, above 2^16 and below 2^256 */
	RSAebits	= 17,
	MaxRSAebits	= 256,
};

/*
 * A key that is one, as far as what uses it goes on to divide by: read
 * from a string, which a peer or a file supplies, a modulus or a prime
 * of 0 reached mpdiv, whose answer to a zero divisor is sysfatal, and
 * the emulator ended.  Not a judgment of the key's strength.
 *
 * And as far as what it costs to use: the key is a peer's, and its
 * signature is checked by raising to its exponent.  An exponent as long
 * as the modulus made each check hundreds of times the work of one with
 * the usual exponent, and with an even modulus (which is no product of
 * two odd primes) mpexp leaves its fast path: seconds for one check at
 * 8192 bits.  FIPS 186-5 A.1.1 has the exponent below 2^256.
 */
static int
rsapubok(RSApub *pub)
{
	return mpcmp(pub->n, mpone) > 0
		&& (pub->n->p[0] & 1) != 0
		&& mpcmp(pub->ek, mpone) > 0
		&& mpsignif(pub->ek) <= MaxRSAebits
		&& mpcmp(pub->ek, pub->n) < 0;
}

static int
rsaprivok(RSApriv *rsa)
{
	return rsapubok(&rsa->pub)
		&& mpcmp(rsa->p, mpone) > 0
		&& mpcmp(rsa->q, mpone) > 0
		&& mpcmp(rsa->dk, mpzero) > 0;
}

static void*
rsa_str2sk(char *str, char **strp)
{
	RSApriv *rsa;
	char *p;

	rsa = rsaprivalloc();
	rsa->pub.n = base64tobig(str, &p);
	rsa->pub.ek = base64tobig(p, &p);
	rsa->dk = base64tobig(p, &p);
	rsa->p = base64tobig(p, &p);
	rsa->q = base64tobig(p, &p);
	rsa->kp = base64tobig(p, &p);
	rsa->kq = base64tobig(p, &p);
	rsa->c2 = base64tobig(p, &p);
	if(strp)
		*strp = p;
	if(rsa->pub.n == nil || rsa->pub.ek == nil ||
	   rsa->dk == nil || rsa->p == nil || rsa->q == nil ||
	   rsa->kp == nil || rsa->kq == nil || rsa->c2 == nil || !rsaprivok(rsa)){
		rsaprivfree(rsa);
		return nil;
	}

	return rsa;
}

static void*
rsa_str2pk(char *str, char **strp)
{
	RSApub *rsa;
	char *p;

	rsa = rsapuballoc();
	rsa->n = base64tobig(str, &p);
	rsa->ek = base64tobig(p, &p);
	if(strp)
		*strp = p;
	if(rsa->n == nil || rsa->ek == nil || !rsapubok(rsa)){
		rsapubfree(rsa);
		return nil;
	}

	return rsa;
}

static void*
rsa_str2sig(char *str, char **strp)
{
	mpint *rsa;
	char *p;

	rsa = base64tobig(str, &p);
	if(rsa == nil)
		return nil;
	if(strp)
		*strp = p;
	return rsa;
}

static int
rsa_sk2str(void *vrsa, char *buf, int len)
{
	RSApriv *rsa;
	char *cp, *ep;

	rsa = vrsa;
	ep = buf + len - 1;
	cp = buf;

	cp += snprint(cp, ep - cp, "%U\n", rsa->pub.n);
	cp += snprint(cp, ep - cp, "%U\n", rsa->pub.ek);
	cp += snprint(cp, ep - cp, "%U\n", rsa->dk);
	cp += snprint(cp, ep - cp, "%U\n", rsa->p);
	cp += snprint(cp, ep - cp, "%U\n", rsa->q);
	cp += snprint(cp, ep - cp, "%U\n", rsa->kp);
	cp += snprint(cp, ep - cp, "%U\n", rsa->kq);
	cp += snprint(cp, ep - cp, "%U\n", rsa->c2);
	*cp = 0;

	return cp - buf;
}

static int
rsa_pk2str(void *vrsa, char *buf, int len)
{
	RSApub *rsa;
	char *cp, *ep;

	rsa = vrsa;
	ep = buf + len - 1;
	cp = buf;
	cp += snprint(cp, ep - cp, "%U\n", rsa->n);
	cp += snprint(cp, ep - cp, "%U\n", rsa->ek);
	*cp = 0;

	return cp - buf;
}

static int
rsa_sig2str(void *vrsa, char *buf, int len)
{
	mpint *rsa;
	char *cp, *ep;

	rsa = vrsa;
	ep = buf + len - 1;
	cp = buf;

	cp += snprint(cp, ep - cp, "%U\n", rsa);
	*cp = 0;

	return cp - buf;
}

static void*
rsa_sk2pk(void *vs)
{
	return rsaprivtopub((RSApriv*)vs);
}

/* generate an rsa secret key */
static void*
rsa_gen(int len)
{
	RSApriv *key;
	int elen;

	/*
	 * rsagen() halves len for genprime(); a non-positive / tiny size
	 * drives genprime() to p->top==0 and an out-of-bounds p->p[-1]
	 * write.  Reject it so genSK() returns nil instead of corrupting
	 * memory.
	 */
	if(len < MinRSAgen || len > MaxRSAgen)
		return nil;
	/*
	 * An exponent of 17 bits (FIPS 186-5 A.1.1: above 2^16); it was
	 * 6 bits.  A modulus too short to have one below it (no size to
	 * use: the least there are primes for) keeps the 6.
	 */
	elen = RSAebits;
	if(len < 4*RSAebits)
		elen = 6;
	for(;;){
		key = rsagen(len, elen, 0);
		if(mpsignif(key->pub.n) == len)
			return key;
		rsaprivfree(key);
	}
}

/* generate an rsa secret key with same params as a public key */
static void*
rsa_genfrompk(void *vpub)
{
	RSApub *pub;
	int nlen, elen;

	/*
	 * the same sizes as rsa_gen is held to, and for the same reason:
	 * this is the path given a key from elsewhere (a signer's, at
	 * enrolment), and a modulus of a bit or two had genprime write
	 * before its number
	 */
	pub = vpub;
	nlen = mpsignif(pub->n);
	elen = mpsignif(pub->ek);
	if(nlen < MinRSAgen || elen < 2 || elen > nlen || elen > MaxRSAebits)
		return nil;
	return rsagen(nlen, elen, 0);
}

static void*
rsa_sign(mpint* m, void *key)
{
	return rsadecrypt((RSApriv*)key, m, nil);
}

static int
rsa_verify(mpint* m, void *sig, void *key)
{
	mpint *t;
	int r;

	/* nil for a signature outside 0..n-1 (RFC 8017 5.2.2): none */
	t = rsaencrypt((RSApub*)key, (mpint*)sig, nil);
	if(t == nil)
		return 0;
	r = mpcmp(t, m) == 0;
	mpfree(t);
	return r;
}

static void
rsa_freepriv(void *a)
{
	rsaprivfree((RSApriv*)a);
}

static void
rsa_freepub(void *a)
{
	rsapubfree((RSApub*)a);
}

static void
rsa_freesig(void *a)
{
	mpfree(a);
}

SigAlgVec*
rsainit(void)
{
	SigAlgVec *vec;

	vec = malloc(sizeof(SigAlgVec));
	if(vec == nil)
		return nil;

	vec->name = "rsa";

	vec->pkattr = pkattr;
	vec->skattr = skattr;
	vec->sigattr = sigattr;

	vec->str2sk = rsa_str2sk;
	vec->str2pk = rsa_str2pk;
	vec->str2sig = rsa_str2sig;

	vec->sk2str = rsa_sk2str;
	vec->pk2str = rsa_pk2str;
	vec->sig2str = rsa_sig2str;

	vec->sk2pk = rsa_sk2pk;

	vec->gensk = rsa_gen;
	vec->genskfrompk = rsa_genfrompk;
	vec->sign = rsa_sign;
	vec->verify = rsa_verify;
	/* signs a number: a digest's leading zero bytes are not part of it */
	vec->signb = nil;
	vec->verifyb = nil;

	vec->skfree = rsa_freepriv;
	vec->pkfree = rsa_freepub;
	vec->sigfree = rsa_freesig;

	return vec;
}
