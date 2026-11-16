/*
 * libsec's ElGamal signatures on the host, built by
 * tests/host/elgamal_test.sh with the libmp and libsec sources under
 * AddressSanitizer:
 *
 *	egtest
 *
 * Bleichenbacher's forgery (r = (p-1)/2, an even s chosen from the
 * message) against keys of each kind; what a key must be; the ranges
 * of r and s; and the keys eggen makes at every size.
 */
#include "lib9.h"
#include <mp.h>
#include <libsec.h>
#include <stdio.h>
#include <setjmp.h>
#include <fcntl.h>
#include <unistd.h>

static int fails, checks;
static jmp_buf raised;
static char msg[256];

void*
mallocz(ulong n, int clr)
{
	void *p;

	p = malloc(n);
	if(p != nil && clr)
		memset(p, 0, n);
	return p;
}

void
sysfatal(char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);
	longjmp(raised, 1);
}

void
werrstr(char *fmt, ...)
{
	USED(fmt);
}

void
genrandom(uchar *p, int n)
{
	static int fd = -1;

	if(fd < 0)
		fd = open("/dev/urandom", O_RDONLY);
	if(read(fd, p, n) != n)
		abort();
}

void
prng(uchar *p, int n)
{
	genrandom(p, n);
}

int
fmtstrcpy(Fmt *f, char *s)
{
	USED(f);
	USED(s);
	return 0;
}

static void
check(int ok, char *fmt, ...)
{
	va_list ap;

	checks++;
	if(ok)
		return;
	fails++;
	printf("FAIL: ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

/* the forged signature on m for a generator 2^pow: r = (p-1)/2, s even with 2^-s = alpha^m */
static void
forge(mpint *p, mpint *m, int pow, EGsig *sig)
{
	mpint *q, *t;

	q = mpnew(0);
	t = mpnew(0);
	mpright(p, 1, q);
	uitomp(pow, t);
	mpmul(m, t, t);
	mpmod(t, q, t);
	mpsub(q, t, sig->s);
	if((sig->s->p[0] & 1) != 0 || sig->s->top == 0)
		mpadd(sig->s, q, sig->s);
	mpassign(q, sig->r);
	mpfree(q);
	mpfree(t);
}

/* how many of n random messages the forgery signs under pub, as a generator 2^pow would have it */
static int
forged(EGpub *pub, int pow, int n)
{
	EGsig sig;
	mpint *m;
	int i, took;

	sig.r = mpnew(0);
	sig.s = mpnew(0);
	m = mpnew(0);
	took = 0;
	for(i = 0; i < n; i++){
		mprand(250, genrandom, m);
		forge(pub->p, m, pow, &sig);
		if(setjmp(raised) == 0 && egverify(pub, &sig, m) == 0)
			took++;
	}
	mpfree(sig.r);
	mpfree(sig.s);
	mpfree(m);
	return took;
}

/* a key signs and verifies; its signature's other forms do not */
static void
roundtrip(EGpriv *k, char *what)
{
	EGsig *sig, alt;
	mpint *m, *pm1, *t;

	m = mpnew(0);
	pm1 = mpnew(0);
	t = mpnew(0);
	mprand(mpsignif(k->pub.p) > 250? 250: mpsignif(k->pub.p), genrandom, m);
	mpsub(k->pub.p, mpone, pm1);
	sig = egsign(k, m);
	check(egverify(&k->pub, sig, m) == 0, "%s: its signature does not verify", what);
	check(sig->s->top != 0 && mpcmp(sig->s, pm1) < 0, "%s: s is not from 1 to p-2", what);
	alt = *sig;
	mpadd(sig->s, pm1, t);
	alt.s = t;
	check(egverify(&k->pub, &alt, m) != 0, "%s: the signature with p-1 added to s verifies", what);
	alt.s = mpzero;
	check(egverify(&k->pub, &alt, m) != 0, "%s: the signature with an s of 0 verifies", what);
	alt = *sig;
	mpadd(sig->r, k->pub.p, t);
	alt.r = t;
	check(egverify(&k->pub, &alt, m) != 0, "%s: the signature with p added to r verifies", what);
	alt.r = mpzero;
	check(egverify(&k->pub, &alt, m) != 0, "%s: the signature with an r of 0 verifies", what);
	mpadd(m, mpone, t);
	check(egverify(&k->pub, sig, t) != 0, "%s: the signature verifies on another message", what);
	egsigfree(sig);
	mpfree(m);
	mpfree(pm1);
	mpfree(t);
}

int
main(void)
{
	EGpriv *k, old;
	EGsig sig;
	mpint *p, *g, *q, *t, *x;
	int n, i, took, bits;

	p = mpnew(0);
	g = mpnew(0);
	q = mpnew(0);
	t = mpnew(0);
	x = mpnew(0);
	if(!getdhparams(2048, p, g)){
		printf("FAIL: no 2048-bit group\n");
		return 1;
	}
	mpright(p, 1, q);

	/* a key as eggen(2048) made them: RFC 3526's group with its generator 2 */
	mprand(2040, genrandom, x);
	old.pub.p = p;
	old.pub.alpha = uitomp(2, nil);
	old.pub.key = mpnew(0);
	old.secret = x;
	mpexp(old.pub.alpha, x, p, old.pub.key);
	took = forged(&old.pub, 1, 20);
	check(took == 0, "%d of 20 messages forged under a key with generator 2", took);
	check(egpubvalid(&old.pub) != 0, "a key whose generator is 2 is valid");
	sig.r = mpnew(0);
	sig.s = mpnew(0);

	/* a generator of 4: a key that is one, forged all the same before */
	old.pub.alpha = uitomp(4, nil);
	mpmod(x, q, x);
	mpexp(old.pub.alpha, x, p, old.pub.key);
	check(egpubvalid(&old.pub) == 0, "a key whose generator is 4 is not valid");
	took = forged(&old.pub, 2, 20);
	check(took == 0, "%d of 20 messages forged under a key with generator 4", took);
	roundtrip(&old, "generator 4");
	/* r = p-1, the other multiple of (p-1)/2 */
	mpsub(p, mpone, sig.r);
	uitomp(2, sig.s);
	check(egverify(&old.pub, &sig, mpzero) != 0, "r = p-1, s = 2 verifies on a message of 0");

	/* a generator of the whole group (order p-1), as the other sizes had */
	uitomp(4, t);
	for(i = 5; ; i++){
		uitomp(i, old.pub.alpha);
		mpexp(old.pub.alpha, q, p, t);
		if(mpcmp(t, mpone) != 0)
			break;
	}
	mpexp(old.pub.alpha, x, p, old.pub.key);
	check(egpubvalid(&old.pub) != 0, "a key whose generator has order p-1 is valid");

	/* keys as they are made now */
	k = eggen(2048, 0);
	check(mpsignif(k->pub.alpha) > 1000, "eggen(2048)'s generator has %d bits", mpsignif(k->pub.alpha));
	check(egpubvalid(&k->pub) == 0 && egsafeprime(k->pub.p) == 0, "eggen(2048)'s key is not valid");
	check(mpcmp(k->secret, mpone) > 0 && mpcmp(k->secret, q) < 0, "eggen(2048)'s secret is not from 2 to q-1");
	took = forged(&k->pub, 1, 20) + forged(&k->pub, 2, 20);
	check(took == 0, "%d of 40 messages forged under eggen(2048)'s key", took);
	roundtrip(k, "eggen(2048)");
	egprivfree(k);
	for(bits = 3; bits <= 12; bits++){
		n = 0;
		for(i = 0; i < 40; i++){
			k = eggen(bits, 0);
			if(egpubvalid(&k->pub) != 0 || egsafeprime(k->pub.p) != 0)
				n++;
			else if(i < 6)
				roundtrip(k, "a small key");
			egprivfree(k);
		}
		check(n == 0, "%d of 40 keys of about %d bits are not valid", n, bits);
	}
	for(i = 0; i < 3; i++){
		k = eggen(256, 0);
		check(egpubvalid(&k->pub) == 0 && egsafeprime(k->pub.p) == 0, "eggen(256)'s key is not valid");
		took = forged(&k->pub, 1, 20);
		check(took == 0, "%d of 20 messages forged under eggen(256)'s key", took);
		roundtrip(k, "eggen(256)");
		egprivfree(k);
	}

	if(fails){
		printf("egtest: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("egtest: %d checks passed\n", checks);
	return 0;
}
