#include "os.h"
#include <mp.h>
#include "dat.h"

// res = b**e [mod m]
//
// For an odd positive modulus: Montgomery multiplication (multiply and
// reduce interleaved) with a fixed window, in constant time for the
// values of the exponent, of the base when it is no longer than the
// modulus, and of the modulus:
//
//  - every window, zero or not, costs w squarings and one multiply;
//  - its table entry is found by reading all 2^w entries under masks
//    (bitmask's barrier keeps the compiler from making them branches);
//  - each Montgomery product ends with a masked, not a branching,
//    subtraction of m;
//  - the exponent's length is taken as e->top digits, so its leading
//    zero bits are not counted either;
//  - a base that fits the modulus's limbs goes into Montgomery form by
//    one such product, with no division (it was mpmod, whose time is
//    the base's and the modulus's: DSA's nonce is a base, k^(q-2));
//  - R^2 mod m is made by doubling and squaring under the same masks
//    (it was a division by the modulus).
//
// What may branch is public: the lengths of all three, and a base that
// is negative or longer than the modulus, which is reduced with mpmod.
// The table and the accumulator are wiped before they are freed.
// tests/host/mpexp_test.sh checks known answers against the general
// path and, under valgrind, that nothing branches on the exponent or
// the base.
//
// mpexpcrt is the same arithmetic for RSA's private operation, where
// the moduli are the secret primes: both exponentiations and Garner's
// recombination, with no division and no branch on any of them.
//
// Otherwise (no modulus, an even or non-positive one): left-to-right
// binary, knuth, vol 2, pp 398-400, whose time follows every bit of
// the exponent.  It is for public exponents.
//
// mpcmp, mpveccmp and the other comparisons stop at the first digit
// that differs: they are for public values, and nothing here or in
// libsec gives them a secret one (rsadecrypt's check compares a
// result with its input only after both are what the caller holds).

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
	int	nm;	// of them, the modulus's own: its top limb is m[nm-1]
	limb	*m;	// modulus
	limb	minv;	// -m^-1 mod 2^Lbits
	limb	*t;	// n+1 limbs of scratch
	limb	*u;	// n more
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
	// (no further than the limbs: zero digits above a number, which
	// mpsignif does not count, were stored past them)
	for(i = 0; i < b->top && i < n*(Lbits/Dbits); i++){
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

// r = a+b mod m; a, b < m; r may be a or b
static void
montadd(Mont *M, limb *r, limb *a, limb *b)
{
	int i, n;
	limb *t, *m, c, x, s, d, borrow, mask;

	n = M->n;
	t = M->u;
	m = M->m;
	c = 0;
	for(i = 0; i < n; i++){
		x = a[i] + c;
		c = x < c;
		s = x + b[i];
		c |= s < x;
		t[i] = s;
	}
	borrow = 0;
	for(i = 0; i < n; i++){
		d = t[i] - m[i];
		x = (t[i] < m[i]) | (d < borrow);
		r[i] = d - borrow;
		borrow = x;
	}
	// the sum stands only if it did not carry and is less than m
	mask = bitmask(borrow & (c ^ 1));
	for(i = 0; i < n; i++)
		r[i] = (r[i] & ~mask) | (t[i] & mask);
}

// r = a-b mod m; a, b < m; r may be a or b
static void
montsub(Mont *M, limb *r, limb *a, limb *b)
{
	int i, n;
	limb *t, *m, c, x, s, d, borrow, mask;

	n = M->n;
	t = M->u;
	m = M->m;
	borrow = 0;
	for(i = 0; i < n; i++){
		d = a[i] - b[i];
		x = (a[i] < b[i]) | (d < borrow);
		t[i] = d - borrow;
		borrow = x;
	}
	// below zero: m is added back
	mask = bitmask(borrow);
	c = 0;
	for(i = 0; i < n; i++){
		x = t[i] + c;
		c = x < c;
		s = x + (m[i] & mask);
		c |= s < x;
		r[i] = s;
	}
}

// the modulus (odd, more than 1, normalized) in n limbs, which may be
// more than it needs, and -1/m mod 2^Lbits
static void
montinit(Mont *M, mpint *m, int n, limb *mem)
{
	limb inv;
	int i;

	M->n = n;
	M->nm = ((vlong)m->top*Dbits + Lbits-1)/Lbits;
	if(M->nm > n)
		M->nm = n;
	if(M->nm < 1)
		M->nm = 1;
	M->m = mem;
	M->t = mem + n;
	M->u = M->t + n+1;
	tolimbs(m, M->m, n);
	// by Newton's iteration; m*m = 1 mod 8
	inv = M->m[0];
	for(i = 3; i < Lbits; i *= 2)
		inv *= 2 - M->m[0]*inv;
	M->minv = 0 - inv;
}

enum {
	Montlimbs=	2,	// limbs montinit takes beside 3 for each of the modulus's
};

// rr = R^2 mod m, R = 2^(Lbits*n), with no division by m.
// 2^(Lbits*(nm-1)) is less than m, whose top limb is not zero; doubled
// mod m until it is 2R, it is 2 in Montgomery form; and 2 to the power
// Lbits*n, by squaring and doubling over that (public) count's bits,
// is R, in Montgomery form R^2.
static void
montrr(Mont *M, limb *rr)
{
	int i, n, k, bit;

	n = M->n;
	for(i = 0; i < n; i++)
		rr[i] = 0;
	rr[M->nm-1] = 1;
	for(i = 0; i <= (n - M->nm + 1)*Lbits; i++)
		montadd(M, rr, rr, rr);
	k = n*Lbits;
	for(bit = 1; bit <= k/2; bit <<= 1)
		;
	// bit is k's highest; the 2 already made stands for it
	while((bit >>= 1) != 0){
		montmul(M, rr, rr, rr);
		if(k & bit)
			montadd(M, rr, rr, rr);
	}
}

// the window for an exponent of nbits: as OpenSSL's BN_window_bits_for_ctime_exponent_size
static int
window(int nbits)
{
	if(nbits > 937)
		return 6;
	if(nbits > 306)
		return 5;
	if(nbits > 89)
		return 4;
	if(nbits > 22)
		return 3;
	return 1;
}

// acc = x^e, x and the result in Montgomery form, the exponent taken
// as nbits bits whatever its value.  one is 1 in Montgomery form; tab
// has room for 2^w numbers, tmp for one.
static void
montexp(Mont *M, limb *acc, limb *x, limb *one, mpint *e, int nbits, int w, limb *tab, limb *tmp)
{
	int i, n, nent, pos;

	n = M->n;
	nent = 1<<w;
	// tab[i] = x^i
	for(i = 0; i < n; i++){
		tab[i] = one[i];
		tab[n+i] = x[i];
	}
	for(i = 2; i < nent; i++)
		montmul(M, tab+i*n, tab+(i-1)*n, tab+n);

	// the windows, most significant first
	pos = ((nbits + w-1)/w - 1)*w;
	lookup(acc, tab, nent, n, ebits(e, pos, w));
	while((pos -= w) >= 0){
		for(i = 0; i < w; i++)
			montmul(M, acc, acc, acc);
		lookup(tmp, tab, nent, n, ebits(e, pos, w));
		montmul(M, acc, acc, tmp);
	}
}

// res = b**e mod m: m odd and positive, e > 0
static void
mpexpmont(mpint *b, mpint *e, mpint *m, mpint *res)
{
	Mont M;
	mpint *tb;
	limb *mem, *tab, *acc, *x, *rr, *one;
	int n, w, nent, nbits, i;
	ulong nmem;

	if(m->top == 1 && m->p[0] == 1){
		mpassign(mpzero, res);
		return;
	}
	n = (mpsignif(m) + Lbits-1)/Lbits;
	// the table's size is an int's worth, asked first
	mpsizebits(0, (vlong)2*n*Lbits + Dbits, "mpexp");

	nbits = e->top*Dbits;
	w = window(nbits);
	nent = 1<<w;

	// Everything this needs is made before any of it is used, so that
	// a raise for want of memory leaves nothing of this function's
	// behind (libmp has no handler to free it): room in the result,
	// then the base reduced if it must be, then the limbs.
	mpreserve(res, n*Lbits);
	tb = nil;
	if(b->sign < 0 || (vlong)b->top*Dbits > (vlong)n*Lbits){
		tb = mptrynew(mpsizebits((vlong)b->top+2, 0, "mpexp"));
		if(tb == nil || mpmodtry(b, m, tb) < 0){
			mpfree(tb);
			sysfatal("mpexp: no memory");
		}
		b = tb;
	}
	nmem = (ulong)n*(nent+7) + Montlimbs;
	mem = mallocz(sizeof(limb)*nmem, 1);
	if(mem == nil){
		mpfree(tb);
		sysfatal("mpexp: no memory");
	}
	montinit(&M, m, n, mem);
	rr = mem + 3*n + Montlimbs;
	one = rr + n;
	x = one + n;
	acc = x + n;
	tab = acc + n;

	montrr(&M, rr);
	for(i = 0; i < n; i++)
		acc[i] = 0;
	acc[0] = 1;
	montmul(&M, one, rr, acc);		// R mod m
	tolimbs(b, x, n);
	montmul(&M, x, x, rr);			// bR mod m, whatever b below R
	mpfree(tb);

	montexp(&M, acc, x, one, e, nbits, w, tab, x);

	// out of Montgomery form
	for(i = 0; i < n; i++)
		x[i] = 0;
	x[0] = 1;
	montmul(&M, acc, acc, x);
	fromlimbs(acc, n, res);

	wipe(mem, nmem);
	free(mem);
}

// How many limbs a number of top digits takes
static int
limbsof(int top)
{
	return ((vlong)top*Dbits + Lbits-1)/Lbits;
}

// res = the number below p*q that is x^kp mod p and x^kq mod q, where
// c2 is 1/p mod q: RSA's private operation by the Chinese remainder
// theorem (RFC 8017 5.1.2, 2b), in constant time for the values of p,
// q, kp, kq and c2, and of x.
//
// p and q are odd, more than 1 and normalized (as libmp's numbers
// are); 0 <= x < p*q; kp, kq and c2 are not negative and no longer
// than the longer prime.  Returns -1, with nothing done, when the
// numbers' lengths or signs are not those (rsadecrypt then does it the
// general way), else 0.  What it branches on is those lengths; the
// primes are worked at the length of the longer (rsagen's q is a bit
// longer than its p, and a limb longer at the usual sizes).
//
// x is brought below each prime with Montgomery products, not a
// division: as xh*R + xl, it is xh*R^3 + xl*R^2 over R, in Montgomery
// form.  Each power is mpexp's window, the exponent taken at the
// prime's length.  Garner's h = (v2 - v1)*c2 mod q is a product and a
// masked subtraction mod q, and v1 + p*h a plain product, every digit
// of both multiplied whatever it is.
int
mpexpcrt(mpint *x, mpint *p, mpint *q, mpint *kp, mpint *kq, mpint *c2, mpint *res)
{
	Mont P, Q;
	limb *mem, *rr, *one, *xh, *xl, *v1, *v2, *h, *acc, *tmp, *tab, *prod, c;
	dlimb t;
	int n, w, nent, nbits, i, j;
	ulong nmem;

	if(sizeof(mpdigit) > sizeof(limb))
		return -1;
	if(p->sign < 0 || q->sign < 0 || p->top == 0 || q->top == 0)
		return -1;
	n = limbsof(p->top);
	if(limbsof(q->top) > n)
		n = limbsof(q->top);
	if((vlong)n*Lbits > MAXBITS/4)
		return -1;
	if(x->sign < 0 || limbsof(x->top) > 2*n)
		return -1;
	if(kp->sign < 0 || kq->sign < 0 || c2->sign < 0
	|| limbsof(kp->top) > n || limbsof(kq->top) > n || limbsof(c2->top) > n)
		return -1;

	nbits = n*Lbits;
	w = window(nbits);
	nent = 1<<w;

	// room in the result, then everything else at once: see mpexpmont
	mpreserve(res, 2*n*Lbits);
	nmem = 2*((ulong)3*n + Montlimbs) + (ulong)n*(nent+11) + 1;
	mem = mallocz(sizeof(limb)*nmem, 1);
	if(mem == nil)
		sysfatal("mpexpcrt: no memory");
	montinit(&P, p, n, mem);
	montinit(&Q, q, n, mem + 3*n + Montlimbs);
	rr = mem + 2*(3*n + Montlimbs);
	one = rr + n;
	xh = one + n;
	xl = xh + n;
	v1 = xl + n;
	v2 = v1 + n;
	h = v2 + n;
	acc = h + n;
	tmp = acc + n;
	prod = tmp + n;		// 2n+1
	tab = prod + 2*n+1;

	// x's two halves
	tolimbs(x, prod, 2*n);
	for(i = 0; i < n; i++){
		xl[i] = prod[i];
		xh[i] = prod[n+i];
	}

	// v1 = x^kp mod p
	montrr(&P, rr);
	for(i = 0; i < n; i++)
		tmp[i] = 0;
	tmp[0] = 1;
	montmul(&P, one, rr, tmp);
	montmul(&P, acc, xl, rr);		// xl*R
	montmul(&P, tmp, rr, rr);		// R^3
	montmul(&P, tmp, xh, tmp);		// xh*R^2
	montadd(&P, tmp, tmp, acc);		// x*R mod p
	montexp(&P, acc, tmp, one, kp, nbits, w, tab, h);
	for(i = 0; i < n; i++)
		tmp[i] = 0;
	tmp[0] = 1;
	montmul(&P, v1, acc, tmp);

	// v2 = x^kq mod q, left in Montgomery form
	montrr(&Q, rr);
	montmul(&Q, one, rr, tmp);
	montmul(&Q, acc, xl, rr);
	montmul(&Q, tmp, rr, rr);
	montmul(&Q, tmp, xh, tmp);
	montadd(&Q, tmp, tmp, acc);
	montexp(&Q, v2, tmp, one, kq, nbits, w, tab, h);

	// h = (v2 - v1)*c2 mod q
	montmul(&Q, tmp, v1, rr);		// v1*R mod q: v1 is below R
	montsub(&Q, tmp, v2, tmp);
	tolimbs(c2, acc, n);
	montmul(&Q, h, tmp, acc);

	// v1 + p*h, which is below p*q
	for(i = 0; i < n; i++)
		prod[i] = v1[i];
	for(i = n; i <= 2*n; i++)
		prod[i] = 0;
	for(i = 0; i < n; i++){
		c = 0;
		for(j = 0; j < n; j++){
			t = (dlimb)P.m[j]*h[i] + prod[i+j] + c;
			prod[i+j] = (limb)t;
			c = (limb)(t >> Lbits);
		}
		// the carry goes up as far as it may: no branch on it
		for(j = i+n; j <= 2*n; j++){
			t = (dlimb)prod[j] + c;
			prod[j] = (limb)t;
			c = (limb)(t >> Lbits);
		}
	}
	fromlimbs(prod, 2*n, res);

	wipe(mem, nmem);
	free(mem);
	return 0;
}

// res = (a*b + c) mod m, for the arithmetic of a signature: in
// constant time for the values of a, b and c when m is odd and
// positive and they are not negative and no longer than it (they need
// not be below it).  c may be nil, for a*b mod m.  Otherwise (an even
// modulus, as ElGamal's p-1) it is libmp's general product, sum and
// division, whose time follows the numbers.
void
mpmuladdmod(mpint *a, mpint *b, mpint *c, mpint *m, mpint *res)
{
	Mont M;
	mpint *t;
	limb *mem, *rr, *x, *y;
	int n, i;
	ulong nmem;

	if(c == nil)
		c = mpzero;
	n = 0;
	if(m->sign > 0 && m->top > 0)
		n = limbsof(m->top);
	if(sizeof(mpdigit) > sizeof(limb) || n == 0 || (m->p[0] & 1) == 0
	|| (m->top == 1 && m->p[0] == 1)
	|| a->sign < 0 || b->sign < 0 || c->sign < 0
	|| limbsof(a->top) > n || limbsof(b->top) > n || limbsof(c->top) > n){
		// what is made is made before anything is held: see mpexpmont
		if(m->top == 0)
			sysfatal("mpmuladdmod: divide by zero");
		t = mptrynew(mpsizebits((vlong)a->top + b->top + c->top + 2, 0, "mpmuladdmod"));
		if(t == nil || mpmultry(a, b, t) < 0){
			mpfree(t);
			sysfatal("mpmuladdmod: no memory");
		}
		mpadd(t, c, t);
		if(mpmodtry(t, m, res) < 0){
			mpfree(t);
			sysfatal("mpmuladdmod: no memory");
		}
		mpfree(t);
		return;
	}

	mpreserve(res, n*Lbits);
	nmem = (ulong)6*n + Montlimbs;
	mem = mallocz(sizeof(limb)*nmem, 1);
	if(mem == nil)
		sysfatal("mpmuladdmod: no memory");
	montinit(&M, m, n, mem);
	rr = mem + 3*n + Montlimbs;
	x = rr + n;
	y = x + n;
	montrr(&M, rr);
	// each into Montgomery form (and below m) by a product with R^2
	tolimbs(a, x, n);
	montmul(&M, x, x, rr);
	tolimbs(b, y, n);
	montmul(&M, y, y, rr);
	montmul(&M, x, x, y);
	tolimbs(c, y, n);
	montmul(&M, y, y, rr);
	montadd(&M, x, x, y);
	for(i = 0; i < n; i++)
		y[i] = 0;
	y[0] = 1;
	montmul(&M, x, x, y);
	fromlimbs(x, n, res);
	wipe(mem, nmem);
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
	int i, j, etop, rbits;
	vlong v;

	// zero digits above the exponent are not its digits: the loop
	// below looked in the top one for a bit, for ever
	etop = e->top;
	while(etop > 0 && e->p[etop-1] == 0)
		etop--;
	if(etop == 0){
		// b^0 is 1, which mod 1 (or -1) is 0: it was 1
		if(m != nil && m->top == 1 && m->p[0] == 1)
			mpassign(mpzero, res);
		else
			mpassign(mpone, res);
		return;
	}
	if(e->sign < 0)
		sysfatal("mpexp: negative exponent");

	// with no modulus the result is as long as the base for each of
	// the exponent: room for it in both working numbers now, so that
	// no product raises for want of memory with the other one held
	// (see mpreserve)
	rbits = Dbits*b->size;
	if(m == nil && etop == 1){
		v = (vlong)mpsignif(b)*e->p[0] + 4*Dbits;
		if(v <= MAXBITS && v > rbits)
			rbits = v;
		mpreserve(res, rbits);
	}
	t[0] = mpnew(rbits);
	mpassign(b, t[0]);
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
	i = etop-1;
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
	// a negative base took the general path, whose time is the
	// exponent's: it is reduced and keeps the exponent's protection
	if(m != nil && m->sign > 0 && m->top > 0 && (m->p[0] & 1) != 0
	&& e->sign > 0 && e->top > 0 && sizeof(mpdigit) <= sizeof(limb)){
		mpexpmont(b, e, m, res);
		return;
	}
	mpexpslow(b, e, m, res);
}
