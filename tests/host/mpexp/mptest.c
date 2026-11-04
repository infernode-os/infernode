/*
 * libmp's mpexp on the host, built by tests/host/mpexp_test.sh with the
 * libmp sources it needs.
 *
 *   mptest vectors.txt	known answers from Python's pow (gen.py), each
 *			also through the general path (mpexpslow), with the
 *			result aliasing each operand; random operands, the
 *			Montgomery path against the general path; timing
 *   mptest ct BITS	one exponentiation with the exponent's digits
 *			marked undefined for valgrind's memcheck (ctgrind):
 *			a branch or an address that depends on them is
 *			reported
 *   mptest ctslow BITS	the same through the general path, which the
 *			check must catch (it branches on each bit)
 *
 * mpexp.c is included, so its static functions are reachable.
 */
#include "../../../libmp/mpexp.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

void *mallocz(ulong n, int clr){ void *p = malloc(n); if(p != nil && clr) memset(p, 0, n); return p; }

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

static int fails;

static mpint*
unhex(char *s)
{
	uchar buf[2048];
	mpint *b;
	int n, i, l;
	unsigned v;
	char tmp[3];

	l = strlen(s);
	n = (l+1)/2;
	if(n > sizeof buf)
		abort();
	i = 0;
	if(l & 1){
		tmp[0] = s[0];
		tmp[1] = 0;
		sscanf(tmp, "%x", &v);
		buf[i++] = v;
		s++;
	}
	for(; i < n; i++, s += 2){
		tmp[0] = s[0];
		tmp[1] = s[1];
		tmp[2] = 0;
		sscanf(tmp, "%x", &v);
		buf[i] = v;
	}
	b = betomp(buf, n, nil);
	mpnorm(b);	/* betomp leaves a zero one digit long */
	return b;
}

static int
same(mpint *a, mpint *b)
{
	return a->sign == b->sign && mpcmp(a, b) == 0 && a->top == b->top;
}

static double
now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec/1e9;
}

static ulong rstate = 88172645;

static void
gen(uchar *p, int n)
{
	while(n-- > 0){
		rstate ^= rstate << 13;
		rstate ^= rstate >> 7;
		rstate ^= rstate << 17;
		*p++ = rstate;
	}
}

static void
fail(char *what, int line)
{
	fails++;
	if(fails < 20)
		fprintf(stderr, "FAIL: %s, line %d\n", what, line);
}

static int
vectors(char *file)
{
	FILE *f;
	static char lb[16384];
	char *fs[4], *p;
	mpint *b, *e, *m, *r, *got, *x, *y;
	int line, i, n;

	f = fopen(file, "r");
	if(f == nil){
		perror(file);
		return -1;
	}
	n = 0;
	for(line = 1; fgets(lb, sizeof lb, f) != nil; line++){
		p = lb;
		for(i = 0; i < 4; i++){
			fs[i] = strtok(p, " \n");
			p = nil;
		}
		if(fs[3] == nil)
			continue;
		b = unhex(fs[0]);
		e = unhex(fs[1]);
		m = unhex(fs[2]);
		r = unhex(fs[3]);
		got = mpnew(0);

		mpexp(b, e, m, got);
		if(!same(got, r))
			fail("mpexp", line);
		mpexpslow(b, e, m, got);
		if(!same(got, r))
			fail("mpexpslow", line);

		// the result in place of each operand
		x = mpcopy(b);
		mpexp(x, e, m, x);
		if(!same(x, r))
			fail("res == b", line);
		mpfree(x);
		x = mpcopy(e);
		mpexp(b, x, m, x);
		if(!same(x, r))
			fail("res == e", line);
		mpfree(x);
		x = mpcopy(m);
		mpexp(b, e, x, x);
		if(!same(x, r))
			fail("res == m", line);
		mpfree(x);

		// a negative base takes the general path: (-b)^e = (m-b)^e or -(m-b)^e
		if(b->top > 0){
			x = mpcopy(b);
			x->sign = -1;
			mpexp(x, e, m, got);
			y = mpnew(0);
			mpexpslow(x, e, m, y);
			if(!same(got, y))
				fail("negative base", line);
			mpfree(x);
			mpfree(y);
		}

		mpfree(b);
		mpfree(e);
		mpfree(m);
		mpfree(r);
		mpfree(got);
		n++;
	}
	fclose(f);
	return n;
}

static void
randoms(int count)
{
	mpint *b, *e, *m, *r1, *r2;
	int i, mb, eb, bb;
	uchar x[2];

	b = mpnew(0);
	e = mpnew(0);
	m = mpnew(0);
	r1 = mpnew(0);
	r2 = mpnew(0);
	for(i = 0; i < count; i++){
		gen(x, 2);
		mb = 1 + (x[0] | x[1]<<8) % 1100;
		gen(x, 2);
		eb = 1 + (x[0] | x[1]<<8) % 1200;
		gen(x, 1);
		bb = 1 + mb + x[0] % 80;
		mprand(mb, gen, m);
		if(m->top == 0)
			itomp(1, m);
		m->p[0] |= 1;
		mprand(eb, gen, e);
		mprand(bb, gen, b);
		if(e->top == 0)
			continue;
		mpexp(b, e, m, r1);
		mpexpslow(b, e, m, r2);
		if(!same(r1, r2))
			fail("random", i);
	}
	mpfree(b);
	mpfree(e);
	mpfree(m);
	mpfree(r1);
	mpfree(r2);
}

static void
timing(int bits)
{
	mpint *b, *e, *m, *r;
	double t0, fast, slow;
	int i, nf, ns;

	b = mprand(bits, gen, nil);
	e = mprand(bits, gen, nil);
	m = mprand(bits, gen, nil);
	m->p[0] |= 1;
	m->p[m->top-1] |= mpdighi;
	r = mpnew(0);
	nf = bits > 3000? 20: 100;
	ns = bits > 3000? 2: 5;
	t0 = now();
	for(i = 0; i < nf; i++)
		mpexp(b, e, m, r);
	fast = (now() - t0)/nf;
	t0 = now();
	for(i = 0; i < ns; i++)
		mpexpslow(b, e, m, r);
	slow = (now() - t0)/ns;
	printf("%d-bit modulus, %d-bit exponent: %.2f ms (was %.1f ms, %.0fx)\n",
		bits, bits, fast*1e3, slow*1e3, slow/fast);
	mpfree(b);
	mpfree(e);
	mpfree(m);
	mpfree(r);
}

static int
ct(int bits, int slow)
{
	mpint *b, *e, *m, *r;

	b = mprand(bits, gen, nil);
	e = mprand(bits, gen, nil);
	m = mprand(bits, gen, nil);
	m->p[0] |= 1;
	m->p[m->top-1] |= mpdighi;
	e->p[e->top-1] |= mpdighi;	/* its length is public */
	r = mpnew(0);
	VALGRIND_MAKE_MEM_UNDEFINED(e->p, e->top*sizeof(mpdigit));
	if(slow)
		mpexpslow(b, e, m, r);
	else
		mpexp(b, e, m, r);
	VALGRIND_MAKE_MEM_DEFINED(r->p, r->size*sizeof(mpdigit));
	VALGRIND_MAKE_MEM_DEFINED(&r->top, sizeof r->top);
	VALGRIND_MAKE_MEM_DEFINED(&r->sign, sizeof r->sign);
	return r->top > 0? 0: 1;
}

int
main(int argc, char **argv)
{
	int n;

	if(argc == 3 && strcmp(argv[1], "ct") == 0)
		return ct(atoi(argv[2]), 0);
	if(argc == 3 && strcmp(argv[1], "ctslow") == 0)
		return ct(atoi(argv[2]), 1);
	if(argc != 2){
		fprintf(stderr, "usage: mptest vectors.txt | mptest ct|ctslow bits\n");
		return 2;
	}
	n = vectors(argv[1]);
	if(n < 0)
		return 1;
	printf("%d known answers\n", n);
	fflush(stdout);
	randoms(2000);
	printf("2000 random operands against the general path\n");
	if(fails == 0){
		timing(1024);
		timing(2048);
		timing(3072);
		timing(4096);
	}
	if(fails){
		printf("%d failures\n", fails);
		return 1;
	}
	return 0;
}
