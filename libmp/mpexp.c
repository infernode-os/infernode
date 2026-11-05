#include "os.h"
#include <mp.h>
#include "dat.h"

// res = b**e [mod m]
//
// For an odd positive modulus and a non-negative base: Montgomery
// multiplication (multiply and reduce interleaved) with a fixed window, in constant time for the
// exponent's value:
//
//  - every window, zero or not, costs w squarings and one multiply;
//  - its table entry is found by reading all 2^w entries under masks
//    (bitmask's barrier keeps the compiler from making them branches);
//  - each Montgomery product ends with a masked, not a branching,
//    subtraction of m;
//  - the exponent's length is taken as e->top digits, so its leading
//    zero bits are not counted either.
//
// What may branch is public: the modulus, the base (reduced mod m and
// put in Montgomery form with mpmod) and the lengths of all three.
// The table and the accumulator are wiped before they are freed.
// tests/host/mpexp_test.sh checks known answers against the general
// path and, under valgrind, that nothing branches on the exponent.
//
// Otherwise (no modulus, an even or non-positive one, a negative base):
// left-to-right binary, knuth, vol 2, pp 398-400.

// 64-bit limbs where the compiler has a 128-bit product; MPEXP32 forces
// the 32-bit limbs used elsewhere (MSVC, 32-bit hosts) for the host test
#if defined(__SIZEOF_INT128__) && !defined(MPEXP32)
typedef uvlong limb;
typedef unsigned __int128 dlimb;
#else
typedef u32int limb;
typedef uvlong dlimb;
#endif

enum {
	Lbits=	8*sizeof(limb),
};

// x, as far as the optimizer can tell, any value
static limb
barrier(limb x)
{
#if defined(__GNUC__) || defined(__clang__)
	__asm__("" : "+r"(x));
	return x;
#else
	volatile limb v;

	v = x;
	return v;
#endif
}

// all ones if bit is 1, else 0
static limb
bitmask(limb bit)
{
	return barrier((limb)0 - bit);
}

typedef struct Mont Mont;
struct Mont {
	int	n;	// limbs
	limb	*m;	// modulus
	limb	minv;	// -m^-1 mod 2^Lbits
	limb	*t;	// n+1 limbs of scratch
};

// r = a*b/R mod m, R = 2^(Lbits*n); a, b < m; r may be a or b
//
// Each pass adds a*b[i] and q*m (q making the low limb zero) and shifts
// down a limb at once; t stays below 2m, so t[n] is 0 or 1.
static void
montmul(Mont *M, limb *r, limb *a, limb *b)
{
	int i, j, n;
	limb *t, *m, c1, c2, bi, q, lo, hi, borrow, mask;
	dlimb p;

	n = M->n;
	t = M->t;
	m = M->m;
	for(j = 0; j <= n; j++)
		t[j] = 0;
	for(i = 0; i < n; i++){
		bi = b[i];
		p = (dlimb)a[0]*bi + t[0];
		c1 = (limb)(p >> Lbits);
		lo = (limb)p;
		q = lo*M->minv;
		p = (dlimb)q*m[0] + lo;
		c2 = (limb)(p >> Lbits);
		for(j = 1; j < n; j++){
			p = (dlimb)a[j]*bi + t[j] + c1;
			c1 = (limb)(p >> Lbits);
			p = (dlimb)q*m[j] + (limb)p + c2;
			c2 = (limb)(p >> Lbits);
			t[j-1] = (limb)p;
		}
		p = (dlimb)t[n] + c1 + c2;
		t[n-1] = (limb)p;
		t[n] = (limb)(p >> Lbits);
	}

	// t < 2m: r = t >= m? t-m: t
	borrow = 0;
	for(j = 0; j < n; j++){
		lo = t[j] - m[j];
		hi = (t[j] < m[j]) | (lo < borrow);
		r[j] = lo - borrow;
		borrow = hi;
	}
	// t-m is negative only if t[n] is 0 and the subtraction borrowed
	mask = bitmask(borrow & ((t[n] | (0 - t[n])) >> (Lbits-1) ^ 1));
	for(j = 0; j < n; j++)
		r[j] = (r[j] & ~mask) | (t[j] & mask);
}

// r = tab[i], reading every entry
static void
lookup(limb *r, limb *tab, int nent, int n, limb i)
{
	int k, j;
	limb d, mask;

	for(j = 0; j < n; j++)
		r[j] = 0;
	for(k = 0; k < nent; k++){
		d = i ^ (limb)k;
		mask = bitmask(((d | (0 - d)) >> (Lbits-1)) ^ 1);
		for(j = 0; j < n; j++)
			r[j] |= tab[k*n+j] & mask;
	}
}

// mpint to n limbs, zero filled; b < 2^(Lbits*n)
static void
tolimbs(mpint *b, limb *r, int n)
{
	int i, k;

	for(i = 0; i < n; i++)
		r[i] = 0;
	for(i = 0; i < b->top; i++){
		k = i*Dbits;
		r[k/Lbits] |= (limb)b->p[i] << (k%Lbits);
	}
}

static void
fromlimbs(limb *a, int n, mpint *r)
{
	int i, k, nd;

	nd = DIGITS(n*Lbits);
	mpbits(r, nd*Dbits);
	for(i = 0; i < nd; i++){
		k = i*Dbits;
		r->p[i] = (mpdigit)(a[k/Lbits] >> (k%Lbits));
	}
	r->top = nd;
	r->sign = 1;
	mpnorm(r);
}

static void
wipe(limb *p, int n)
{
	volatile limb *v;

	v = p;
	while(n-- > 0)
		*v++ = 0;
}

// bits [pos, pos+w) of e; pos+w <= e->top*Dbits rounded up to w
static limb
ebits(mpint *e, int pos, int w)
{
	int i, sh;
	limb x;

	x = 0;
	i = pos/Dbits;
	sh = pos%Dbits;
	if(i < e->top)
		x = e->p[i] >> sh;
	if(sh+w > Dbits && i+1 < e->top)
		x |= (limb)e->p[i+1] << (Dbits-sh);
	return x & (((limb)1<<w)-1);
}

// res = b**e mod m: m odd and positive, b >= 0, e > 0
static void
mpexpmont(mpint *b, mpint *e, mpint *m, mpint *res)
{
	Mont M;
	mpint *t;
	limb *mem, *tab, *acc, *x, *rr, inv;
	int n, w, nent, nbits, pos, i;

	n = (mpsignif(m) + Lbits-1)/Lbits;

	// the window: as OpenSSL's BN_window_bits_for_ctime_exponent_size
	nbits = e->top*Dbits;
	if(nbits > 937)
		w = 6;
	else if(nbits > 306)
		w = 5;
	else if(nbits > 89)
		w = 4;
	else if(nbits > 22)
		w = 3;
	else
		w = 1;
	nent = 1<<w;

	mem = mallocz(sizeof(limb)*(n*(nent+4) + n+2), 1);
	if(mem == nil)
		sysfatal("mpexp: %r");
	tab = mem;
	acc = tab + n*nent;
	x = acc + n;
	rr = x + n;
	M.m = rr + n;
	M.t = M.m + n;
	M.n = n;
	tolimbs(m, M.m, n);

	// -m^-1 mod 2^Lbits by Newton's iteration; m*m = 1 mod 8
	inv = M.m[0];
	for(i = 3; i < Lbits; i *= 2)
		inv *= 2 - M.m[0]*inv;
	M.minv = 0 - inv;

	// R^2 mod m, and b mod m: public
	t = mpnew(0);
	mpleft(mpone, 2*n*Lbits, t);
	mpmod(t, m, t);
	tolimbs(t, rr, n);
	mpmod(b, m, t);
	tolimbs(t, x, n);
	mpfree(t);

	// tab[i] = b^i R mod m
	for(i = 0; i < n; i++)
		acc[i] = 0;
	acc[0] = 1;
	montmul(&M, tab, rr, acc);		// R mod m
	montmul(&M, tab+n, x, rr);		// bR mod m
	for(i = 2; i < nent; i++)
		montmul(&M, tab+i*n, tab+(i-1)*n, tab+n);

	// the windows, most significant first
	pos = ((nbits + w-1)/w - 1)*w;
	lookup(acc, tab, nent, n, ebits(e, pos, w));
	while((pos -= w) >= 0){
		for(i = 0; i < w; i++)
			montmul(&M, acc, acc, acc);
		lookup(x, tab, nent, n, ebits(e, pos, w));
		montmul(&M, acc, acc, x);
	}

	// out of Montgomery form
	for(i = 0; i < n; i++)
		x[i] = 0;
	x[0] = 1;
	montmul(&M, acc, acc, x);
	fromlimbs(acc, n, res);

	wipe(mem, n*(nent+4) + n+2);
	free(mem);
}

enum {
	Freeb=	0x1,
	Freee=	0x2,
	Freem=	0x4,
};

//int expdebug;

// the general path: any modulus (or none), any base
static void
mpexpslow(mpint *b, mpint *e, mpint *m, mpint *res)
{
	mpint *t[2];
	int tofree;
	mpdigit d, bit;
	int i, j;

	i = mpcmp(e,mpzero);
	if(i==0){
		mpassign(mpone, res);
		return;
	}
	if(i<0)
		sysfatal("mpexp: negative exponent");

	t[0] = mpcopy(b);
	t[1] = res;

	tofree = 0;
	if(res == b){
		b = mpcopy(b);
		tofree |= Freeb;
	}
	if(res == e){
		e = mpcopy(e);
		tofree |= Freee;
	}
	if(res == m){
		m = mpcopy(m);
		tofree |= Freem;
	}

	// skip first bit
	i = e->top-1;
	d = e->p[i];
	for(bit = mpdighi; (bit & d) == 0; bit >>= 1)
		;
	bit >>= 1;

	j = 0;
	for(;;){
		for(; bit != 0; bit >>= 1){
			mpmul(t[j], t[j], t[j^1]);
			if(bit & d)
				mpmul(t[j^1], b, t[j]);
			else
				j ^= 1;
			if(m != nil && t[j]->top > m->top){
				mpmod(t[j], m, t[j^1]);
				j ^= 1;
			}
		}
		if(--i < 0)
			break;
		bit = mpdighi;
		d = e->p[i];
	}
	if(m != nil){
		mpmod(t[j], m, t[j^1]);
		j ^= 1;
	}
	if(t[j] == res){
		mpfree(t[j^1]);
	} else {
		mpassign(t[j], res);
		mpfree(t[j]);
	}

	if(tofree){
		if(tofree & Freeb)
			mpfree(b);
		if(tofree & Freee)
			mpfree(e);
		if(tofree & Freem)
			mpfree(m);
	}
}

void
mpexp(mpint *b, mpint *e, mpint *m, mpint *res)
{
	if(m != nil && m->sign > 0 && m->top > 0 && (m->p[0] & 1) != 0
	&& b->sign > 0 && e->sign > 0 && e->top > 0 && sizeof(mpdigit) <= sizeof(limb)){
		mpexpmont(b, e, m, res);
		return;
	}
	mpexpslow(b, e, m, res);
}
