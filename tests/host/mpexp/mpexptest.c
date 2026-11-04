/*
 * libmp's mpexp on the host, built by tests/host/mpexp_test.sh.
 *
 *   mpexptest diff N		N random cases, each modulus odd, even, of
 *				one digit to 4096 bits, base 0, 1, m-1, larger
 *				than m or negative, exponent 1 to 4096 bits:
 *				Montgomery's path against the square and
 *				multiply it replaced (mpexpplain, kept for an
 *				even modulus); a power that is a negative
 *				multiple of m is 0 (the plain path gave m)
 *   mpexptest vec FILE		lines "b e m r" in hex from Python's pow
 *   mpexptest time		2048- and 4096-bit times, both algorithms
 *   mpexptest ct		one 2048-bit exponentiation with the exponent
 *				marked undefined for valgrind's memcheck
 *				(ctgrind): a branch or address depending on
 *				it is reported.  Its top digit stays defined:
 *				the exponent's length chooses the work.
 *				"ct plain" runs the square and multiply it
 *				replaced, which must be reported (the check
 *				sees a leak when there is one)
 *
 * mpexp.c is included, so its static functions are reachable.
 */
#include "../../../libmp/mpexp.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

void *mallocz(ulong n, int clr){ void *p = malloc(n); if(p != nil && clr) memset(p, 0, n); return p; }
void sysfatal(char *fmt, ...){ fprintf(stderr, "sysfatal: %s\n", fmt); abort(); }
void genrandom(uchar *p, int n){ while(n-- > 0) *p++ = rand(); }

static uvlong rstate = 0x9e3779b97f4a7c15ULL;

static ulong
rnd(void)
{
	rstate ^= rstate << 13;
	rstate ^= rstate >> 7;
	rstate ^= rstate << 17;
	return (ulong)(rstate >> 11);
}

/* a random number of nbits bits (the top one set), patterned at times */
static mpint*
rmp(int nbits)
{
	mpint *b;
	int i, n, kind;

	n = (nbits + Dbits - 1)/Dbits;
	b = mpnew(n*Dbits);
	kind = rnd()%8;
	for(i = 0; i < n; i++){
		switch(kind){
		case 0: b->p[i] = ~(mpdigit)0; break;		/* all ones */
		case 1: b->p[i] = i == 0 ? 1 : 0; break;	/* sparse */
		default: b->p[i] = rnd() ^ ((mpdigit)rnd() << 16); break;
		}
	}
	b->top = n;
	if(nbits % Dbits)
		b->p[n-1] &= ((mpdigit)1 << (nbits % Dbits)) - 1;
	b->p[n-1] |= (mpdigit)1 << ((nbits - 1) % Dbits);
	b->sign = 1;
	mpnorm(b);
	return b;
}

static int
sizepick(void)
{
	static int sizes[] = {1, 2, 17, 31, 32, 33, 63, 64, 65, 127, 256, 512, 1024, 1536, 2048, 3072, 4096};

	if(rnd()%3 == 0)
		return 1 + rnd()%300;
	return sizes[rnd()%nelem(sizes)];
}

static int
diff(int count)
{
	int i, fails, mb, eb;
	mpint *b, *e, *m, *r1, *r2;
	char *s;

	fails = 0;
	for(i = 0; i < count; i++){
		mb = sizepick();
		eb = sizepick();
		if(i%10 == 0 && mb > 1024)
			mb = 1024;		/* keep the plain path's time down */
		m = rmp(mb);
		if(rnd()%4 == 0)
			m->p[0] &= ~1;	/* even: the plain path */
		else
			m->p[0] |= 1;
		mpnorm(m);
		if(m->top == 0)
			itomp(1, m);
		switch(rnd()%8){
		case 0: b = itomp(0, nil); break;
		case 1: b = itomp(1, nil); break;
		case 2: b = mpcopy(m); mpsub(b, mpone, b); break;		/* m-1 */
		case 3: b = rmp(mb + 1 + rnd()%100); break;		/* larger */
		case 4: b = rmp(1 + rnd()%mb); b->sign = -1; break;	/* negative */
		default: b = rmp(1 + rnd()%mb); break;
		}
		e = rmp(eb);
		r1 = mpnew(0);
		r2 = mpnew(0);
		mpexp(b, e, m, r1);
		mpexpplain(b, e, m, r2);
		/*
		 * the plain path gives m, not 0, for a power that is a
		 * negative multiple of m (mpmod's -0 + m): (-3)^e mod 3 was 3
		 */
		if(mpcmp(r2, m) == 0)
			itomp(0, r2);
		if(mpcmp(r1, r2) != 0){
			fails++;
			if(fails < 10){
				s = smprint("m=%B b=%B new=%B old=%B e %d bits", m, b, r1, r2, mpsignif(e));
				fprintf(stderr, "FAIL: %.300s\n", s);
				free(s);
			}
		}
		/* in place: res the base, the exponent, the modulus */
		if(i%5 == 0){
			mpint *x = mpcopy(b);
			mpexp(x, e, m, x);
			if(mpcmp(x, r2) != 0 && fails++ < 10)
				fprintf(stderr, "FAIL: res == b\n");
			mpassign(e, x);
			mpexp(b, x, m, x);
			if(mpcmp(x, r2) != 0 && fails++ < 10)
				fprintf(stderr, "FAIL: res == e\n");
			mpassign(m, x);
			mpexp(b, e, x, x);
			if(mpcmp(x, r2) != 0 && fails++ < 10)
				fprintf(stderr, "FAIL: res == m\n");
			mpfree(x);
		}
		mpfree(b); mpfree(e); mpfree(m); mpfree(r1); mpfree(r2);
	}
	printf("diff: %d cases, %d failures\n", count, fails);
	return fails;
}

static int
vec(char *file)
{
	FILE *f;
	char line[8*4096];
	char *fld[4];
	int n, fails;
	mpint *b, *e, *m, *want, *got;

	f = fopen(file, "r");
	if(f == nil){
		perror(file);
		return 1;
	}
	n = fails = 0;
	while(fgets(line, sizeof line, f) != nil){
		if(getfields(line, fld, 4, 1, " \n") != 4)
			continue;
		b = strtomp(fld[0], nil, 16, nil);
		e = strtomp(fld[1], nil, 16, nil);
		m = strtomp(fld[2], nil, 16, nil);
		want = strtomp(fld[3], nil, 16, nil);
		got = mpnew(0);
		mpexp(b, e, m, got);
		if(mpcmp(got, want) != 0 && fails++ < 10)
			fprintf(stderr, "FAIL: vector %d: m %d bits, e %d bits\n", n, mpsignif(m), mpsignif(e));
		n++;
		mpfree(b); mpfree(e); mpfree(m); mpfree(want); mpfree(got);
	}
	fclose(f);
	printf("vectors: %d, %d failures\n", n, fails);
	return fails;
}

static double
now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec/1e9;
}

static void
time1(char *what, int mb, int eb, int n)
{
	mpint *b, *e, *m, *r;
	double t0, t1, t2;
	int i;

	m = rmp(mb);
	m->p[0] |= 1;
	b = rmp(mb - 1);
	e = rmp(eb);
	r = mpnew(0);
	t0 = now();
	for(i = 0; i < n; i++)
		mpexpplain(b, e, m, r);
	t1 = now();
	for(i = 0; i < n; i++)
		mpexp(b, e, m, r);
	t2 = now();
	printf("%-32s square and multiply %8.2f ms   Montgomery %7.2f ms   %.0fx\n",
		what, (t1-t0)*1000/n, (t2-t1)*1000/n, (t1-t0)/(t2-t1));
}

static int
ct(int plain)
{
	mpint *b, *e, *m, *r;

	m = rmp(2048);
	m->p[0] |= 1;
	b = rmp(2047);
	e = rmp(2048);
	r = mpnew(0);
	/* every digit but the top one, which fixes the length */
	VALGRIND_MAKE_MEM_UNDEFINED(e->p, (e->top - 1)*Dbytes);
	if(plain)
		mpexpplain(b, e, m, r);
	else
		mpexp(b, e, m, r);
	VALGRIND_MAKE_MEM_DEFINED(r->p, r->size*Dbytes);
	VALGRIND_MAKE_MEM_DEFINED(&r->top, sizeof r->top);
	return 0;
}

int
main(int argc, char **argv)
{
	fmtinstall('B', mpfmt);
	if(argc >= 3 && strcmp(argv[1], "diff") == 0)
		return diff(atoi(argv[2])) != 0;
	if(argc >= 3 && strcmp(argv[1], "vec") == 0)
		return vec(argv[2]) != 0;
	if(argc >= 2 && strcmp(argv[1], "time") == 0){
		time1("2048 mod, 2048 exp", 2048, 2048, 10);
		time1("2048 mod, 256 exp", 2048, 256, 40);
		time1("2048 mod, e=65537", 2048, 17, 400);
		time1("1024 mod, 1024 exp (CRT half)", 1024, 1024, 40);
		time1("4096 mod, 4096 exp", 4096, 4096, 2);
		return 0;
	}
	if(argc >= 2 && strcmp(argv[1], "ct") == 0)
		return ct(argc >= 3 && strcmp(argv[2], "plain") == 0);
	fprintf(stderr, "usage: mpexptest diff N | vec FILE | time | ct [plain]\n");
	return 2;
}
