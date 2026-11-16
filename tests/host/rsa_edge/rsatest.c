/*
 * libsec's RSA on the host, built by tests/host/rsa_edge_test.sh with
 * the libmp and libsec sources under AddressSanitizer:
 *
 *	rsatest vectors.txt
 *	rsatest ct crt|general|rsa vectors.txt
 *		under valgrind, built -DCTGRIND and without the sanitizer:
 *		the private key's numbers marked undefined (ctgrind), then
 *		libmp's mpexpcrt, the arithmetic rsadecrypt had before it,
 *		or all of rsadecrypt; a branch or an address that depends on
 *		the key is reported
 *
 * libmp's sysfatal is a raise in the kernels; here it comes back to the
 * check that made the call, which counts it as the wrong way to refuse.
 */
#include "lib9.h"
#include <mp.h>
#include <libsec.h>
#include <stdio.h>
#include <setjmp.h>
#include <fcntl.h>
#include <unistd.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

static int fails, checks, allocs, randoms;
static jmp_buf raised;
static char msg[256];

#ifdef CTGRIND
#define xmalloc malloc
#define xfree free
#else
void*
xmalloc(size_t n)
{
	allocs++;
	return malloc(n);
}

void
xfree(void *p)
{
	if(p != nil)
		allocs--;
	free(p);
}
#endif

void*
mallocz(ulong n, int clr)
{
	void *p;

	p = xmalloc(n);
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
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);
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

#define RAISES(call)	(setjmp(raised) != 0? 1: ((call), 0))

static mpint *N, *E, *D, *P, *Q, *M, *S;

static mpint*
hx(char *s)
{
	return strtomp(s, nil, 16, nil);
}

static mpint*
num(int i)
{
	return itomp(i, nil);
}

static void
ranges(RSApriv *k)
{
	RSApub pub;
	mpint *t, *x;

	pub.n = N;
	pub.ek = E;
	t = rsadecrypt(k, M, nil);
	check(t != nil && mpcmp(t, S) == 0, "rsadecrypt(m) is not OpenSSL's m^d mod n");
	mpfree(t);
	t = rsaencrypt(&pub, S, nil);
	check(t != nil && mpcmp(t, M) == 0, "rsaencrypt(s) is not m");
	mpfree(t);

	/* RFC 8017 5.2.2, 5.1.2: a representative is in 0..n-1 */
	x = mpnew(0);
	mpadd(S, N, x);
	check(rsaencrypt(&pub, x, nil) == nil, "rsaencrypt(s+n) gave a result");
	mpsub(S, N, x);
	check(rsaencrypt(&pub, x, nil) == nil, "rsaencrypt(s-n) gave a result");
	check(rsaencrypt(&pub, N, nil) == nil, "rsaencrypt(n) gave a result");
	mpadd(M, N, x);
	check(rsadecrypt(k, x, nil) == nil, "rsadecrypt(m+n) gave a result");
	mpsub(M, N, x);
	check(rsadecrypt(k, x, nil) == nil, "rsadecrypt(m-n) gave a result");
	check(rsadecrypt(k, N, nil) == nil, "rsadecrypt(n) gave a result");
	mpsub(N, mpone, x);
	t = rsaencrypt(&pub, x, nil);
	check(t != nil && mpcmp(t, x) == 0, "rsaencrypt(n-1) is not n-1");	/* e is odd */
	mpfree(t);
	t = rsaencrypt(&pub, mpzero, nil);
	check(t != nil && t->top == 0, "rsaencrypt(0) is not 0");
	mpfree(t);
	mpfree(x);
}

/* a key whose CRT parts are not the key's gives no result, not the primes */
static void
faults(RSApriv *k)
{
	mpint *t, *save, *g, *x;
	mpint **part[3];
	char *name[3] = { "kq", "kp", "c2" };
	int i;

	part[0] = &k->kq;
	part[1] = &k->kp;
	part[2] = &k->c2;
	for(i = 0; i < 3; i++){
		save = *part[i];
		*part[i] = mpcopy(save);
		mpadd(*part[i], mptwo, *part[i]);
		t = rsadecrypt(k, M, nil);
		if(t != nil){
			/* what the result gives away: gcd(t^e - m, n) */
			x = mpnew(0);
			g = mpnew(0);
			mpexp(t, E, N, x);
			mpsub(x, M, x);
			mpmod(x, N, x);
			mpextendedgcd(x, N, g, mpnew(0), mpnew(0));
			check(0, "rsadecrypt with %s+2 gave a result; gcd(s^e - m, n) is p or q: %d", name[i],
				mpcmp(g, P) == 0 || mpcmp(g, Q) == 0);
		}else
			check(1, "");
		mpfree(*part[i]);
		*part[i] = save;
	}
	t = rsadecrypt(k, M, nil);
	check(t != nil && mpcmp(t, S) == 0, "rsadecrypt with the key's own parts again");
	mpfree(t);
}

static void
fill(void)
{
	RSApriv *k;
	mpint *n, *p, *one, *three;
	int i, before;

	k = nil;
	one = num(1);
	three = num(3);
	/* p == q: nil, with no raise and nothing kept */
	p = num(3);
	n = num(9);
	before = allocs;
	check(!RAISES(k = rsafill(n, three, three, p, p)) && k == nil, "rsafill with p == q = 3: %s", msg);
	check(allocs == before, "rsafill with p == q kept %d allocations", allocs - before);
	p = num(11);
	n = num(121);
	before = allocs;
	for(i = 0; i < 100; i++)
		check(!RAISES(k = rsafill(n, three, num(67), p, p)) && k == nil, "rsafill with p == q = 11: %s", msg);
	check(allocs - before <= 200, "100 rsafills with p == q kept %d allocations", allocs - before);

	/* negative parts: nil, not a raise and not a key */
	check(!RAISES(k = rsafill(num(-15), three, three, num(-3), num(5))) && k == nil, "rsafill with p = -3: %s", msg);
	check(!RAISES(k = rsafill(num(-15), three, three, num(3), num(-5))) && k == nil, "rsafill with q = -5: %s", msg);
	check(!RAISES(k = rsafill(num(35), num(-5), num(-5), num(5), num(7))) && k == nil, "rsafill with e = d = -5 made a key");
	check(!RAISES(k = rsafill(num(35), num(5), num(-19), num(5), num(7))) && k == nil, "rsafill with d = -19 made a key");
	check(!RAISES(k = rsafill(num(-35), num(5), num(5), num(5), num(7))) && k == nil, "rsafill with n = -35 made a key");

	/* and a key that is one */
	k = nil;
	check(!RAISES(k = rsafill(num(35), num(5), num(5), num(5), num(7))) && k != nil, "rsafill(35, 5, 5, 5, 7): %s", msg);
	check(k != nil && mptoi(k->c2) == 3 && mptoi(k->kp) == 1 && mptoi(k->kq) == 5, "its CRT parts");
	USED(one);
}

/* rsagen's keys: d the least positive inverse, and rsafill takes them */
static void
gen(void)
{
	RSApriv *k, *k2;
	mpint *t, *m, *s;
	int i, neg, refused, wrong;

	neg = refused = wrong = 0;
	m = num(0x12345);
	for(i = 0; i < 150; i++){
		k = rsagen(128, 6, 0);
		if(k->dk->sign < 0 || k->dk->top == 0)
			neg++;
		k2 = nil;
		if(RAISES(k2 = rsafill(k->pub.n, k->pub.ek, k->dk, k->p, k->q)) || k2 == nil)
			refused++;
		else{
			/* d itself is the exponent: m^(e*d) is m */
			t = mpnew(0);
			mpexp(m, k->pub.ek, k->pub.n, t);
			mpexp(t, k->dk, k->pub.n, t);
			s = rsadecrypt(k2, m, nil);
			if(mpcmp(t, m) != 0 || s == nil)
				wrong++;
			mpfree(t);
			mpfree(s);
			rsaprivfree(k2);
		}
		rsaprivfree(k);
	}
	check(neg == 0, "%d of 150 keys from rsagen have a d that is not positive", neg);
	check(refused == 0, "rsafill refused %d of 150 keys from rsagen", refused);
	check(wrong == 0, "%d of 150 keys from rsagen do not undo their own exponent", wrong);
}

/* the private operation as rsadecrypt had it: libmp's general arithmetic */
static void
oldcrt(RSApriv *rsa, mpint *in, mpint *out)
{
	mpint *v1, *v2;

	v1 = mpnew(0);
	mpmod(in, rsa->p, v1);
	v2 = mpnew(0);
	mpmod(in, rsa->q, v2);
	mpexp(v1, rsa->kp, rsa->p, v1);
	mpexp(v2, rsa->kq, rsa->q, v2);
	mpsub(v2, v1, v2);
	mpmul(v2, rsa->c2, v2);
	mpmod(v2, rsa->q, v2);
	mpmul(v2, rsa->p, out);
	mpadd(v1, out, out);
	mpfree(v1);
	mpfree(v2);
}

/*
 * mpexpcrt against the general arithmetic: keys of every size from two
 * limbs of 32 bits up, inputs at the edges and at random, primes of
 * unlike lengths; what it is not for refused.
 */
static void
crt(RSApriv *k0)
{
	static int sizes[] = { 64, 96, 128, 130, 190, 192, 256, 384, 512, 1024 };
	RSApriv *k;
	mpint *x, *a, *b, *big, *small, *n2;
	int i, j, bad, refused, r;

	x = mpnew(0);
	a = mpnew(0);
	b = mpnew(0);
	bad = refused = 0;
	for(i = 0; i < nelem(sizes); i++){
		k = rsagen(sizes[i], 17, 0);
		for(j = 0; j < 40; j++){
			switch(j){
			case 0:	mpassign(mpzero, x); break;
			case 1:	mpassign(mpone, x); break;
			case 2:	mpsub(k->pub.n, mpone, x); break;
			case 3:	mpassign(k->p, x); break;
			case 4:	mpassign(k->q, x); break;
			case 5:	mpsub(k->p, mpone, x); break;
			case 6:	mpadd(k->q, mpone, x); break;
			default:
				mprand(sizes[i] + 64, genrandom, x);
				mpmod(x, k->pub.n, x);
				if(j & 1)
					mpright(x, sizes[i]/2 + j, x);	/* short ones */
				break;
			}
			oldcrt(k, x, a);
			r = mpexpcrt(x, k->p, k->q, k->kp, k->kq, k->c2, b);
			if(r < 0)
				refused++;
			else if(mpcmp(a, b) != 0)
				bad++;
			/* and with the result in place of the input */
			if(r == 0){
				mpassign(x, b);
				if(mpexpcrt(b, k->p, k->q, k->kp, k->kq, k->c2, b) < 0 || mpcmp(a, b) != 0)
					bad++;
			}
		}
		rsaprivfree(k);
	}
	check(bad == 0, "mpexpcrt differs from the general arithmetic in %d of 800 cases", bad);
	check(refused == 0, "mpexpcrt refused %d of 400 inputs to rsagen's keys", refused);

	/* numbers it is not for: refused, nothing done */
	mpassign(mpzero, b);
	mpsub(mpzero, mpone, x);
	check(mpexpcrt(x, k0->p, k0->q, k0->kp, k0->kq, k0->c2, b) < 0, "mpexpcrt took a negative input");
	mpmul(k0->pub.n, k0->pub.n, x);
	mpmul(x, k0->pub.n, x);
	check(mpexpcrt(x, k0->p, k0->q, k0->kp, k0->kq, k0->c2, b) < 0, "mpexpcrt took an input three times the modulus's length");
	check(mpexpcrt(M, k0->p, k0->q, k0->pub.n, k0->kq, k0->c2, b) < 0, "mpexpcrt took an exponent longer than its prime");
	check(mpexpcrt(M, k0->p, mpzero, k0->kp, k0->kq, k0->c2, b) < 0, "mpexpcrt took a q of zero");

	/* primes of unlike lengths */
	big = mpnew(0);
	small = mpnew(0);
	n2 = mpnew(0);
	genprime(big, 320, 10);
	genprime(small, 96, 10);
	mpmul(big, small, n2);
	mpsub(big, mpone, a);
	mpsub(small, mpone, b);
	mpmul(a, b, a);
	mpextendedgcd(itomp(65537, x), a, b, x, mpnew(0));	/* x = d */
	mpmod(x, a, x);
	k = nil;
	if(mptoi(b) == 1 && !RAISES(k = rsafill(n2, itomp(65537, nil), x, big, small)) && k != nil){
		mprand(300, genrandom, x);
		oldcrt(k, x, a);
		check(mpexpcrt(x, k->p, k->q, k->kp, k->kq, k->c2, b) == 0 && mpcmp(a, b) == 0, "mpexpcrt with primes of 320 and 96 bits");
		check(mpexpcrt(x, k->q, k->p, k->kq, k->kp, k->c2, b) == 0, "mpexpcrt with primes of 96 and 320 bits refused");
		a = rsadecrypt(k, x, nil);
		b = mpnew(0);
		if(a != nil)
			mpexp(a, k->pub.ek, k->pub.n, b);
		check(a != nil && mpcmp(b, x) == 0, "rsadecrypt with primes of 320 and 96 bits");
	}
}

/* blinding: a number from the generator for every call, and the same answer */
static void
blind(RSApriv *k)
{
	mpint *t;
	int i, before, drew;

	drew = 0;
	for(i = 0; i < 20; i++){
		before = randoms;
		t = rsadecrypt(k, M, nil);
		if(randoms > before)
			drew++;
		check(t != nil && mpcmp(t, S) == 0, "rsadecrypt(m), call %d, is not OpenSSL's m^d mod n", i);
		mpfree(t);
	}
	check(drew == 20, "rsadecrypt drew a blinding number in %d of 20 calls", drew);
}

static void
secret(mpint *b)
{
	VALGRIND_MAKE_MEM_UNDEFINED(b->p, b->top*sizeof(mpdigit));
}

static void
public(mpint *b)
{
	VALGRIND_MAKE_MEM_DEFINED(b->p, b->size*sizeof(mpdigit));
	VALGRIND_MAKE_MEM_DEFINED(&b->top, sizeof b->top);
	VALGRIND_MAKE_MEM_DEFINED(&b->sign, sizeof b->sign);
}

static int
ct(char *what, RSApriv *k)
{
	mpint *out, *x;

	out = mpnew(0);
	x = mpcopy(M);
	secret(k->p);
	secret(k->q);
	secret(k->kp);
	secret(k->kq);
	secret(k->c2);
	if(strcmp(what, "crt") == 0){
		secret(x);
		if(mpexpcrt(x, k->p, k->q, k->kp, k->kq, k->c2, out) < 0)
			return 1;
	}else if(strcmp(what, "general") == 0){
		secret(x);
		oldcrt(k, x, out);
	}else{
		out = rsadecrypt(k, M, nil);
		if(out == nil)
			return 1;
	}
	public(out);
	if(mpcmp(out, S) != 0){
		printf("FAIL: ct %s: not m^d mod n\n", what);
		return 1;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	FILE *f;
	char *ctwhat;
	char nm[8];
	static char v[2000];
	RSApriv *k;
	mpint *b;

	ctwhat = nil;
	if(argc == 4 && strcmp(argv[1], "ct") == 0){
		ctwhat = argv[2];
		argv += 2;
		argc -= 2;
	}
	if(argc != 2 || (f = fopen(argv[1], "r")) == nil){
		fprintf(stderr, "usage: rsatest [ct crt|general|rsa] vectors.txt\n");
		return 2;
	}
	while(fscanf(f, "%7s %1999s", nm, v) == 2){
		b = hx(v);
		switch(nm[0]){
		case 'n': N = b; break;
		case 'e': E = b; break;
		case 'd': D = b; break;
		case 'p': P = b; break;
		case 'q': Q = b; break;
		case 'm': M = b; break;
		case 's': S = b; break;
		}
	}
	fclose(f);
	k = nil;
	if(RAISES(k = rsafill(N, E, D, P, Q)) || k == nil){
		printf("FAIL: rsafill refused OpenSSL's key: %s\n", msg);
		return 1;
	}
	if(ctwhat != nil)
		return ct(ctwhat, k);
	ranges(k);
	faults(k);
	crt(k);
	blind(k);
	fill();
	gen();
	if(fails){
		printf("rsatest: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("rsatest: %d checks passed\n", checks);
	return 0;
}
