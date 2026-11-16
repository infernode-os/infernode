/*
 * libsec's RSA on the host, built by tests/host/rsa_edge_test.sh with
 * the libmp and libsec sources under AddressSanitizer:
 *
 *	rsatest vectors.txt
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

static int fails, checks, allocs;
static jmp_buf raised;
static char msg[256];

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

int
main(int argc, char **argv)
{
	FILE *f;
	char nm[8];
	static char v[2000];
	RSApriv *k;
	mpint *b;

	if(argc != 2 || (f = fopen(argv[1], "r")) == nil){
		fprintf(stderr, "usage: rsatest vectors.txt\n");
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
	ranges(k);
	faults(k);
	fill();
	gen();
	if(fails){
		printf("rsatest: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("rsatest: %d checks passed\n", checks);
	return 0;
}
