/*
 * The nonces of libsec's DSA and ElGamal signatures (dsasign.c,
 * egsign.c, nonce.c, mpnonce.c) on the host, built by
 * tests/host/sign_nonce_test.sh:
 *
 *	noncetest vectors.txt
 *		signatures with RFC 6979's nonce, from gen.py's reading of
 *		the RFC; hedged ones; a generator that repeats
 *	noncetest ct dsa|dsaold|eg vectors.txt
 *		under valgrind, built -DCTGRIND: the secret key and the
 *		nonce's random bytes marked undefined (ctgrind)
 */
#include "lib9.h"
#include <mp.h>
#include <libsec.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

static int fails, checks, stuck, randoms;

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
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
	abort();
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

	randoms++;
	if(fd < 0)
		fd = open("/dev/urandom", O_RDONLY);
	if(read(fd, p, n) != n)
		abort();
	if(stuck)
		memset(p, 0x42, n);
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

static mpint*
hx(char *s)
{
	return strtomp(s, nil, 16, nil);
}

static int
unhex(char *s, uchar *b)
{
	int n;
	unsigned v;

	if(strcmp(s, "-") == 0)
		return 0;
	for(n = 0; s[2*n] != 0 && s[2*n+1] != 0; n++){
		sscanf(s + 2*n, "%2x", &v);
		b[n] = v;
	}
	return n;
}

static void
secret(mpint *b)
{
	VALGRIND_MAKE_MEM_UNDEFINED(b->p, b->top*sizeof(mpdigit));
}

/* DSA's s as dsasign made it: the extended GCD on the nonce, then a product and a division */
static void
dsaold(DSApriv *k, mpint *m)
{
	mpint *nonce, *r, *kinv, *s;

	nonce = mpnew(0);
	r = mpnew(0);
	kinv = mpnew(0);
	s = mpnew(0);
	mprand(mpsignif(k->pub.q)-1, genrandom, nonce);
	secret(nonce);
	mpextendedgcd(nonce, k->pub.q, r, kinv, s);
	mpmod(kinv, k->pub.q, kinv);
	mpexp(k->pub.alpha, nonce, k->pub.p, r);
	mpmod(r, k->pub.q, r);
	mpmul(r, k->secret, s);
	mpadd(s, m, s);
	mpmul(s, kinv, s);
	mpmod(s, k->pub.q, s);
}

int
main(int argc, char **argv)
{
	static char f[6][2200];
	char line[9000], *ct;
	FILE *fp;
	DSApriv *dk;
	EGpriv *ek;
	DSAsig *ds, *ds2;
	EGsig *es, *es2;
	mpint *m, *r, *s, *m0;
	uchar rnd[64];
	int n, nrnd, ndsa, neg, before;

	ct = nil;
	if(argc == 4 && strcmp(argv[1], "ct") == 0){
		ct = argv[2];
		argv += 2;
		argc -= 2;
	}
	if(argc != 2 || (fp = fopen(argv[1], "r")) == nil){
		fprintf(stderr, "usage: noncetest [ct dsa|dsaold|eg] vectors.txt\n");
		return 2;
	}
	dk = nil;
	ek = nil;
	m0 = nil;
	ndsa = neg = 0;
	while(fgets(line, sizeof line, fp) != nil){
		n = sscanf(line, "%2199s %2199s %2199s %2199s %2199s %2199s", f[0], f[1], f[2], f[3], f[4], f[5]);
		if(n == 6 && strcmp(f[0], "dsakey") == 0){
			if(ct != nil && dk != nil && strcmp(ct, "eg") != 0)
				break;	/* the first group will do */
			dk = dsaprivalloc();
			dk->pub.p = hx(f[1]);
			dk->pub.q = hx(f[2]);
			dk->pub.alpha = hx(f[3]);
			dk->pub.key = hx(f[4]);
			dk->secret = hx(f[5]);
		}else if(n == 5 && strcmp(f[0], "egkey") == 0){
			ek = egprivalloc();
			ek->pub.p = hx(f[1]);
			ek->pub.alpha = hx(f[2]);
			ek->pub.key = hx(f[3]);
			ek->secret = hx(f[4]);
		}else if(n == 5 && strcmp(f[0], "dsasig") == 0 && ct == nil){
			m = hx(f[1]);
			nrnd = unhex(f[2], rnd);
			r = hx(f[3]);
			s = hx(f[4]);
			ds = dsasignrnd(dk, m, rnd, nrnd);
			check(ds != nil && mpcmp(ds->r, r) == 0 && mpcmp(ds->s, s) == 0,
				"DSA, q of %d bits, %d random bytes: not the signature RFC 6979's nonce gives", mpsignif(dk->pub.q), nrnd);
			check(ds != nil && dsaverify(&dk->pub, ds, m) == 0, "DSA: the signature does not verify");
			/* hedged: drawn from the generator, another signature, which verifies */
			before = randoms;
			ds2 = dsasign(dk, m);
			check(randoms > before, "dsasign drew nothing from the generator");
			check(ds2 != nil && ds != nil && mpcmp(ds2->r, ds->r) != 0, "dsasign's signature is the deterministic one");
			check(ds2 != nil && dsaverify(&dk->pub, ds2, m) == 0, "DSA: a hedged signature does not verify");
			if(m0 != nil && nrnd == 0){
				/* a generator that repeats: two messages, two nonces */
				stuck = 1;
				ds = dsasign(dk, m0);
				ds2 = dsasign(dk, m);
				stuck = 0;
				check(ds != nil && ds2 != nil && mpcmp(ds->r, ds2->r) != 0,
					"DSA: two messages signed with a generator that repeats have one nonce (r)");
			}
			m0 = m;
			ndsa++;
		}else if(n == 5 && strcmp(f[0], "egsig") == 0 && ct == nil){
			m = hx(f[1]);
			nrnd = unhex(f[2], rnd);
			r = hx(f[3]);
			s = hx(f[4]);
			es = egsignrnd(ek, m, rnd, nrnd);
			check(es != nil && mpcmp(es->r, r) == 0 && mpcmp(es->s, s) == 0,
				"ElGamal, %d random bytes: not the signature RFC 6979's nonce gives", nrnd);
			check(es != nil && egverify(&ek->pub, es, m) == 0, "ElGamal: the signature does not verify");
			before = randoms;
			es2 = egsign(ek, m);
			check(randoms > before, "egsign drew nothing from the generator");
			check(es2 != nil && es != nil && mpcmp(es2->r, es->r) != 0, "egsign's signature is the deterministic one");
			check(es2 != nil && egverify(&ek->pub, es2, m) == 0, "ElGamal: a hedged signature does not verify");
			stuck = 1;
			es = egsign(ek, m0);
			es2 = egsign(ek, m);
			stuck = 0;
			check(es != nil && es2 != nil && (mpcmp(m0, m) == 0 || mpcmp(es->r, es2->r) != 0),
				"ElGamal: two messages signed with a generator that repeats have one nonce (r)");
			m0 = m;
			neg++;
		}
	}
	fclose(fp);
	if(ct != nil){
		m = hx("1234567890ABCDEF1234567890ABCDEF12345678");
		genrandom(rnd, 32);
		VALGRIND_MAKE_MEM_UNDEFINED(rnd, 32);
		if(strcmp(ct, "dsa") == 0){
			secret(dk->secret);
			ds = dsasignrnd(dk, m, rnd, 32);
			if(ds == nil)
				return 1;
			VALGRIND_MAKE_MEM_DEFINED(ds->r->p, ds->r->size*sizeof(mpdigit));
			VALGRIND_MAKE_MEM_DEFINED(ds->s->p, ds->s->size*sizeof(mpdigit));
			VALGRIND_MAKE_MEM_DEFINED(&ds->r->top, sizeof(int));
			VALGRIND_MAKE_MEM_DEFINED(&ds->s->top, sizeof(int));
			return dsaverify(&dk->pub, ds, m) != 0;
		}
		if(strcmp(ct, "dsaold") == 0){
			secret(dk->secret);
			dsaold(dk, m);
			return 0;
		}
		secret(ek->secret);
		es = egsignrnd(ek, m, rnd, 32);
		return es == nil;
	}
	/* numbers that are no group: no signature, and an end */
	if(dk != nil){
		mpint *q;

		q = dk->pub.q;
		dk->pub.q = hx("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFD");	/* 3 * 5 * ... : not prime */
		check(dsasign(dk, m0) == nil, "dsasign with a q that is not prime gave a signature");
		dk->pub.q = q;
		q = dk->pub.alpha;
		dk->pub.alpha = mpnew(0);
		check(dsasign(dk, m0) == nil, "dsasign with a generator of 0 gave a signature");
		dk->pub.alpha = q;
	}
	check(ndsa >= 18 && neg >= 6, "vectors read: %d DSA, %d ElGamal", ndsa, neg);
	if(fails){
		printf("noncetest: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("noncetest: %d checks passed\n", checks);
	return 0;
}
