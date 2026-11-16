/*
 * libmp's sizes, signs and text on the host, built by
 * tests/host/libmp_edge_test.sh with the libmp sources under
 * AddressSanitizer and UndefinedBehaviorSanitizer (malloc and free in
 * them renamed to this file's, which can refuse).
 *
 *	mpedge vectors.txt [section]
 *
 * libmp's sysfatal is a raise in the kernels: here it comes back to the
 * check that made the call.
 */
#include "lib9.h"
#include <mp.h>
#include <libsec.h>
#include "dat.h"
#include <stdio.h>
#include <setjmp.h>
#include <limits.h>

#undef malloc
#undef free

static int fails, checks;
static jmp_buf raised;
static char raisemsg[256];
static int refuse;	/* allocations to refuse: all at or past this many bytes */
static int refused;

void*
xmalloc(size_t n)
{
	if(refuse && n >= refuse){
		refused++;
		return nil;
	}
	return malloc(n);
}

void
xfree(void *p)
{
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
	vsnprintf(raisemsg, sizeof raisemsg, fmt, ap);
	va_end(ap);
	longjmp(raised, 1);
}

/* dec32 and dec64 are lib9's (u32.c, u64.c), linked in; %B is not used */
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

/* does the call raise? */
#define RAISES(call)	(setjmp(raised) != 0? 1: ((call), 0))

static mpint*
num(char *s)
{
	mpint *b;
	int neg;

	neg = 0;
	if(*s == '-'){
		neg = 1;
		s++;
	}
	b = strtomp(s, nil, 16, nil);
	if(b == nil)
		abort();
	if(neg && b->top != 0)
		b->sign = -1;
	return b;
}

static int
same(mpint *a, mpint *b)
{
	return a->sign == b->sign && mpcmp(a, b) == 0 && (a->top == 0 || a->p[a->top-1] != 0);
}

static char*
hex(mpint *b)
{
	static char buf[4][4096];
	static int i;
	char *p;

	p = buf[i++ & 3];
	if(mptoa(b, 16, p, 4096) == nil)
		return "(long)";
	return p;
}

/*
 * A number that says it has top digits and has room for few: what is
 * refused for its size must be refused before a digit of it is touched.
 */
static mpint*
fake(int top)
{
	mpint *b;

	b = mpnew(0);
	b->p[0] = 3;
	b->top = top;
	return b;
}

static void
sizes(void)
{
	mpint *b, *x, *y, *r;
	uchar byte[8];
	mpint *v;

	b = mpnew(0);
	check(RAISES(mpbits(b, -1)), "mpbits(b, -1) did not raise");
	check(RAISES(mpbits(b, INT_MIN)), "mpbits(b, INT_MIN) did not raise");
	check(RAISES(mpbits(b, INT_MAX)), "mpbits(b, INT_MAX) did not raise");
	check(RAISES(mpbits(b, INT_MAX-31)), "mpbits(b, INT_MAX-31) did not raise");
	check(b->size == 33 && b->top == 0, "a refused mpbits changed the number: size %d top %d", b->size, b->top);
	check(RAISES(mpnew(-1)), "mpnew(-1) did not raise");
	check(RAISES(mpnew(INT_MAX)), "mpnew(INT_MAX) did not raise");
	check(!RAISES(mpbits(b, 4096)) && b->size >= 128, "mpbits(b, 4096)");
	mpfree(b);

	/* the product of the longest number by one digit: 2^31 bits */
	x = fake((1<<26)-2);
	y = fake(1);
	r = mpnew(0);
	check(RAISES(mpmul(x, y, r)), "mpmul of 2^26-2 digits by one did not raise");
	check(RAISES(mpmul(y, x, r)), "mpmul of one digit by 2^26-2 did not raise");
	x->top = (1<<25)+1;
	check(RAISES(mpmul(x, y, r)), "mpmul past the longest number did not raise");
	/* the longest number and one more */
	x->top = (1<<26)-1;
	check(RAISES(mpadd(x, y, r)), "mpadd of 2^26-1 digits and 1 did not raise");
	y->sign = -1;
	check(RAISES(mpsub(x, y, r)), "mpsub of 2^26-1 digits and -1 did not raise");
	y->sign = 1;
	x->top = 1;

	/* shifts whose result's bits pass an int, or reach it */
	check(RAISES(mpleft(y, INT_MAX-32, r)), "mpleft by INT_MAX-32 did not raise");
	check(RAISES(mpleft(y, INT_MAX-62, r)), "mpleft by INT_MAX-62 did not raise");
	check(RAISES(mpleft(y, INT_MAX, r)), "mpleft by INT_MAX did not raise");
	check(RAISES(mpright(y, -(INT_MAX-32), r)), "mpright by -(INT_MAX-32) did not raise");
	check(RAISES(mpright(y, INT_MIN, r)), "mpright by INT_MIN did not raise");
	check(!RAISES(mpright(y, 1000, r)) && r->top == 0 && r->sign == 1, "1 >> 1000 is not 0");
	check(!RAISES(mpright(y, INT_MAX, r)) && r->top == 0, "1 >> INT_MAX is not 0");

	/* bytes whose bits pass an int: refused before one is read */
	byte[0] = 1;
	check(RAISES(betomp(byte, (1<<28)-3, nil)), "betomp of 2^28-3 bytes did not raise");
	check(RAISES(betomp(byte, (1<<29)+1, nil)), "betomp of 2^29+1 bytes did not raise");
	check(RAISES(betomp(byte, 0xffffffff, nil)), "betomp of 2^32-1 bytes did not raise");
	check(RAISES(letomp(byte, 0x0fffffff, nil)), "letomp of 2^28-1 bytes did not raise");
	check(RAISES(letomp(byte, 0x20000000, nil)), "letomp of 2^29 bytes did not raise");
	v = nil;
	check(!RAISES(v = betomp(byte, 1, nil)) && v != nil && v->top == 1 && v->p[0] == 1, "betomp of one byte");
	mpfree(v);
	v = nil;
	check(!RAISES(v = betomp(byte, 0, nil)) && v != nil && v->top == 0, "betomp of no bytes");
	mpfree(v);

	check(RAISES(mprand(-5, genrandom, nil)), "mprand of -5 bits did not raise");
	check(RAISES(mprand(INT_MAX, genrandom, nil)), "mprand of INT_MAX bits did not raise");

	x->top = 0;	/* they hold 33 digits, whatever they said */
	y->top = 0;
	mpfree(x);
	mpfree(y);
	mpfree(r);
}

static uchar rbytes[64];
static void
gen(uchar *p, int n)
{
	memmove(p, rbytes, n < sizeof rbytes? n: sizeof rbytes);
}

void
genrandom(uchar *p, int n)
{
	memset(p, 0x5a, n);
}

static void
rands(void)
{
	mpint *b, *v;
	int i;

	/* a b that held a longer number, and a draw whose top bytes are zero */
	b = num("cccccccccccccccccccccccccccccccccccccccccccccccc");
	memset(rbytes, 0, 4);
	for(i = 4; i < 12; i++)
		rbytes[i] = 0x11*i;
	mprand(96, gen, b);
	check(b->top == 2 && mpsignif(b) <= 64, "mprand into a longer number kept its old top digit: %s", hex(b));
	mpfree(b);

	/* no memory for the bytes: a raise, and b not a number to use */
	b = mpnew(0);
	refuse = 200;
	v = b;
	check(RAISES(v = mprand(2048, gen, b)), "mprand with no memory did not raise (returned %p)", v);
	refuse = 0;
	mpfree(b);
}

static void
text(void)
{
	static char *bad32[] = { "2", "222", "222222", "A", "0l1o+/AB", "22222222222", "2222222222222a" };
	mpint *b, *r;
	char buf[64], *e;
	int i;

	/* lengths base 32 does not have, and what is not base 32 */
	for(i = 0; i < nelem(bad32); i++){
		b = nil;
		check(!RAISES(b = strtomp(bad32[i], &e, 32, nil)) && b == nil,
			"strtomp(\"%s\", 32) is a number: %s", bad32[i], b != nil? hex(b): raisemsg);
	}
	b = strtomp("a2", nil, 32, nil);	/* two digits: one byte */
	check(b != nil && b->top == 1 && b->p[0] == 0x40, "strtomp(\"a2\", 32)");
	mpfree(b);
	/* base 64's digits after base 32's are not the number's */
	b = strtomp("22222223ZZ", &e, 32, nil);
	check(b != nil && b->top == 1 && b->p[0] == 1 && strcmp(e, "ZZ") == 0, "strtomp(\"22222223ZZ\", 32) stops at the Z");
	mpfree(b);

	/* a zero with a sign */
	b = strtomp("-0", nil, 10, nil);
	check(b != nil && b->top == 0 && b->sign == 1, "strtomp(\"-0\", 10) has a sign");
	mpfree(b);
	b = strtomp("-0000", nil, 16, nil);
	check(b != nil && b->top == 0 && b->sign == 1, "strtomp(\"-0000\", 16) has a sign");
	mpfree(b);
	b = strtomp("-AAAA", nil, 64, nil);
	check(b != nil && b->top == 0 && b->sign == 1, "strtomp(\"-AAAA\", 64) has a sign");
	mpfree(b);

	/* base 64 into a buffer too short: none of it, not some */
	b = num("123456789abcdef0123456789abcdef");
	for(i = 2; i < 40; i++){
		memset(buf, 'x', sizeof buf);
		e = mptoa(b, 64, buf, i);
		check(e == nil || strcmp(buf, "ASNFZ4mrze8BI0VniavN7w==") == 0, "mptoa base 64 in %d bytes: \"%.40s\"", i, buf);
	}
	mpfree(b);

	/* no memory for the decoded bytes is no number, not zero */
	r = mpnew(0);
	refuse = 8;
	b = r;
	check(!RAISES(b = strtomp("ASNFZ4mrze8BI0VniavN7w==", nil, 64, r)) && b == nil, "strtomp base 64 with no memory is a number");
	refuse = 0;
	mpfree(r);
}

static void
arith(void)
{
	mpint *a, *b, *q, *r, *m, *e;

	/* the quotient's sign */
	a = num("6"); b = num("3"); q = num("-5");
	mpdiv(a, b, q, nil);
	check(q->sign == 1 && mptoi(q) == 2, "6/3 into a number that held -5: %s", hex(q));
	mpfree(a); mpfree(b); mpfree(q);
	a = num("-6"); b = num("-3");
	mpdiv(a, b, a, nil);
	check(a->sign == 1 && mptoi(a) == 2, "-6/-3 into the dividend: %s", hex(a));
	mpfree(a); mpfree(b);
	/* the remainder's sign when the quotient is written over the dividend */
	a = num("7"); b = num("-2"); r = mpnew(0);
	mpdiv(a, b, a, r);
	check(mptoi(a) == -3 && mptoi(r) == 1, "7/-2 into the dividend: %s r %s", hex(a), hex(r));
	mpfree(a); mpfree(b); mpfree(r);
	/* one number for both results */
	a = num("7"); b = num("2"); q = mpnew(0);
	check(RAISES(mpdiv(a, b, q, q)), "mpdiv with one number for quotient and remainder did not raise");
	mpfree(a); mpfree(b); mpfree(q);

	/* a negative modulus; the remainder written over the modulus */
	a = num("-7"); m = num("-5"); r = mpnew(0);
	mpmod(a, m, r);
	check(same(r, num("3")), "-7 mod -5: %s", hex(r));
	mpfree(a); mpfree(r);
	a = num("-3"); m = num("5");
	mpmod(a, m, m);
	check(same(m, num("2")), "-3 mod 5 into the 5: %s", hex(m));
	mpfree(a); mpfree(m);

	/* b^0 mod 1 */
	a = num("5"); e = num("0"); r = mpnew(0);
	mpexp(a, e, mpone, r);
	check(r->top == 0, "5^0 mod 1: %s", hex(r));
	mpexp(a, e, num("7"), r);
	check(same(r, mpone), "5^0 mod 7: %s", hex(r));
	mpexp(a, e, nil, r);
	check(same(r, mpone), "5^0: %s", hex(r));
	/* zero digits above an exponent, on the general path (an even modulus) */
	e = num("1");
	mpbits(e, 1024);
	a = num("3");
	mpexp(a, e, num("4"), r);
	check(same(r, num("3")), "3^1 mod 4, the exponent written with 32 digits: %s", hex(r));
	/* and an exponent of zero written with digits */
	e->p[0] = 0;
	mpexp(a, e, num("4"), r);
	check(same(r, mpone), "3^0 mod 4, the zero written with 32 digits: %s", hex(r));
	/* zero digits above a modulus (the limbs are counted by its bits) */
	m = num("5");
	mpbits(m, 4096*Dbits);
	e = num("3");
	mpexp(a, e, m, r);
	check(same(r, num("2")), "3^3 mod 5, the modulus written with 4096 digits: %s", hex(r));

	/* a zero written with digits, to the gcd */
	a = mpnew(0);
	mpbits(a, 64);
	b = num("6");
	q = mpnew(0); r = mpnew(0); m = mpnew(0);
	mpextendedgcd(a, b, q, r, m);
	check(same(q, num("6")), "gcd(0 written with digits, 6): %s", hex(q));
	mpextendedgcd(b, a, q, r, m);
	check(same(q, num("6")), "gcd(6, 0 written with digits): %s", hex(q));
}

/* a product when there is no memory for Karatsuba's scratch */
static void
nomem(void)
{
	mpint *a, *b, *p1, *p2;
	int i, did;

	a = mpnew(0);
	b = mpnew(0);
	mpbits(a, 80*Dbits);
	mpbits(b, 70*Dbits);
	for(i = 0; i < a->top; i++)
		a->p[i] = 0x9e3779b9*(i+1);
	for(i = 0; i < b->top; i++)
		b->p[i] = 0x85ebca6b*(i+7);
	p1 = mpnew(0);
	p2 = mpnew(200*Dbits);
	mpmul(a, b, p1);
	refuse = 600;	/* the scratch, not the digits of anything */
	refused = 0;
	did = !RAISES(mpmul(a, b, p2));
	refuse = 0;
	check(did, "mpmul raised when Karatsuba had no scratch: %s", raisemsg);
	check(refused > 0, "the scratch was not asked for");
	check(did && same(p1, p2), "the product made without Karatsuba's scratch is another number");
}

static void
vectors(char *file)
{
	FILE *f;
	static char line[32768], w[5][8192], buf[8192];
	mpint *a, *b, *q, *r, *wq, *wr, *n;
	char *e;
	int nf, base, nv;

	f = fopen(file, "r");
	if(f == nil){
		printf("FAIL: cannot open %s\n", file);
		fails++;
		return;
	}
	nv = 0;
	q = mpnew(0);
	r = mpnew(0);
	while(fgets(line, sizeof line, f) != nil){
		nf = sscanf(line, "%8191s %8191s %8191s %8191s %8191s", w[0], w[1], w[2], w[3], w[4]);
		if(nf < 4)
			continue;
		nv++;
		if(strcmp(w[0], "div") == 0 && nf == 5){
			a = num(w[1]); b = num(w[2]); wq = num(w[3]); wr = num(w[4]);
			mpdiv(a, b, q, r);
			check(same(q, wq) && same(r, wr), "%s / %s: %s r %s, want %s r %s", w[1], w[2], hex(q), hex(r), w[3], w[4]);
			/* the quotient over the dividend, the remainder over the divisor */
			mpdiv(a, b, a, b);
			check(same(a, wq) && same(b, wr), "%s / %s in place: %s r %s", w[1], w[2], hex(a), hex(b));
			mpfree(a); mpfree(b); mpfree(wq); mpfree(wr);
		}else if(strcmp(w[0], "mod") == 0){
			a = num(w[1]); b = num(w[2]); wr = num(w[3]);
			mpmod(a, b, r);
			check(same(r, wr), "%s mod %s: %s, want %s", w[1], w[2], hex(r), w[3]);
			mpmod(a, b, b);
			check(same(b, wr), "%s mod %s into the modulus: %s", w[1], w[2], hex(b));
			mpfree(a); mpfree(b); mpfree(wr);
		}else if(strcmp(w[0], "txt") == 0){
			base = atoi(w[1]);
			n = num(w[2]);
			e = mptoa(n, base, buf, sizeof buf);
			check(e != nil && strcmp(buf, w[3]) == 0, "%s in base %d: \"%s\", want \"%s\"", w[2], base, e != nil? buf: "(nil)", w[3]);
			a = strtomp(w[3], &e, base, nil);
			check(a != nil && same(a, n) && (*e == 0 || *e == '='), "\"%s\" read in base %d: %s", w[3], base, a != nil? hex(a): "(nil)");
			mpfree(a); mpfree(n);
		}
	}
	fclose(f);
	check(nv > 6000, "only %d vectors in %s", nv, file);
}

int
main(int argc, char **argv)
{
	char *only;

	if(argc != 2 && argc != 3){
		fprintf(stderr, "usage: mpedge vectors.txt [sizes|rands|text|arith|nomem|vectors]\n");
		return 2;
	}
	only = argc == 3? argv[2]: nil;
#define WANT(s)	(only == nil || strcmp(only, s) == 0)
	if(WANT("sizes"))
		sizes();
	if(WANT("rands"))
		rands();
	if(WANT("text"))
		text();
	if(WANT("arith"))
		arith();
	if(WANT("nomem"))
		nomem();
	if(WANT("vectors"))
		vectors(argv[1]);
	if(fails){
		printf("mpedge: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("mpedge: %d checks passed\n", checks);
	return 0;
}
