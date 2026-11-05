/*
 * P-256 (secp256r1) and P-384 (secp384r1): ECDH, ECDSA.
 *
 * Constant time with respect to secret scalars and field elements:
 *
 *  - Field and scalar arithmetic is Montgomery multiplication (CIOS) on
 *    64-bit limbs, one routine for both curves and for both moduli (the
 *    field prime p and the group order n).  Every loop runs a fixed number
 *    of times; the final subtraction, modular addition and subtraction
 *    select their result by mask, not by branch.
 *  - Points are projective (X:Y:Z) and added and doubled by the complete
 *    formulas for a = -3 of Renes, Costello and Batina, "Complete addition
 *    formulas for prime order elliptic curves" (EUROCRYPT 2016),
 *    Algorithms 4 and 6.  They have no exceptional cases (the identity,
 *    P + P and P + -P all go through the same instructions), so no branch
 *    depends on a point.
 *  - Scalar multiplication is a fixed 4-bit window over every bit of the
 *    scalar, its table entry chosen by scanning all 16 entries under masks.
 *  - Inversion is Fermat's (a^(m-2)), its exponent public.
 *  - Every mask made from a bit goes through bitmask(), whose barrier hides
 *    from the compiler that it is 0 or all ones: clang otherwise turns a
 *    masked select back into a branch (tests/host/ecc_test.sh caught it).
 *
 * What may branch is public: the curve, a peer's point (validated on the
 * way in), a signature being verified, the rejection of a random scalar
 * that is out of range (the one kept tells nothing), and whether a result
 * is the identity.
 *
 * libmp is not used: its reduction and inversion take time that depends on
 * the operands.
 */
#include "os.h"
#include <mp.h>
#include <libsec.h>
#include "uint128.h"

enum {
	MAXLIMB = 6,	/* 384 bits */
	WBITS = 4,	/* window width */
};

typedef u64int limb;
typedef limb felem[MAXLIMB];

/* an odd modulus and its Montgomery constants (R = 2^(64n)) */
typedef struct Mont Mont;
struct Mont {
	int	n;		/* limbs */
	limb	m[MAXLIMB];	/* modulus, little-endian limbs */
	limb	minv;		/* -m^-1 mod 2^64 */
	limb	rr[MAXLIMB];	/* R^2 mod m */
};

typedef struct Curve Curve;
struct Curve {
	int	nbytes;		/* 32 or 48 */
	Mont	p;		/* the field */
	Mont	q;		/* the group order */
	limb	b[MAXLIMB];	/* y^2 = x^3 - 3x + b */
	limb	gx[MAXLIMB];
	limb	gy[MAXLIMB];
};

static const Curve P256 = {
	32,
	{
		4,
		{0xFFFFFFFFFFFFFFFFULL, 0x00000000FFFFFFFFULL, 0x0000000000000000ULL, 0xFFFFFFFF00000001ULL},
		0x0000000000000001ULL,
		{0x0000000000000003ULL, 0xFFFFFFFBFFFFFFFFULL, 0xFFFFFFFFFFFFFFFEULL, 0x00000004FFFFFFFDULL},
	},
	{
		4,
		{0xF3B9CAC2FC632551ULL, 0xBCE6FAADA7179E84ULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFF00000000ULL},
		0xCCD1C8AAEE00BC4FULL,
		{0x83244C95BE79EEA2ULL, 0x4699799C49BD6FA6ULL, 0x2845B2392B6BEC59ULL, 0x66E12D94F3D95620ULL},
	},
	{0x3BCE3C3E27D2604BULL, 0x651D06B0CC53B0F6ULL, 0xB3EBBD55769886BCULL, 0x5AC635D8AA3A93E7ULL},
	{0xF4A13945D898C296ULL, 0x77037D812DEB33A0ULL, 0xF8BCE6E563A440F2ULL, 0x6B17D1F2E12C4247ULL},
	{0xCBB6406837BF51F5ULL, 0x2BCE33576B315ECEULL, 0x8EE7EB4A7C0F9E16ULL, 0x4FE342E2FE1A7F9BULL},
};

static const Curve P384 = {
	48,
	{
		6,
		{0x00000000FFFFFFFFULL, 0xFFFFFFFF00000000ULL, 0xFFFFFFFFFFFFFFFEULL,
		 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL},
		0x0000000100000001ULL,
		{0xFFFFFFFE00000001ULL, 0x0000000200000000ULL, 0xFFFFFFFE00000000ULL,
		 0x0000000200000000ULL, 0x0000000000000001ULL, 0x0000000000000000ULL},
	},
	{
		6,
		{0xECEC196ACCC52973ULL, 0x581A0DB248B0A77AULL, 0xC7634D81F4372DDFULL,
		 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL},
		0x6ED46089E88FDC45ULL,
		{0x2D319B2419B409A9ULL, 0xFF3D81E5DF1AA419ULL, 0xBC3E483AFCB82947ULL,
		 0xD40D49174AAB1CC5ULL, 0x3FB05B7A28266895ULL, 0x0C84EE012B39BF21ULL},
	},
	{0x2A85C8EDD3EC2AEFULL, 0xC656398D8A2ED19DULL, 0x0314088F5013875AULL,
	 0x181D9C6EFE814112ULL, 0x988E056BE3F82D19ULL, 0xB3312FA7E23EE7E4ULL},
	{0x3A545E3872760AB7ULL, 0x5502F25DBF55296CULL, 0x59F741E082542A38ULL,
	 0x6E1D3B628BA79B98ULL, 0x8EB1C71EF320AD74ULL, 0xAA87CA22BE8B0537ULL},
	{0x7A431D7C90EA0E5FULL, 0x0A60B1CE1D7E819DULL, 0xE9DA3113B5F0B8C0ULL,
	 0xF8F41DBD289A147CULL, 0x5D9E98BF9292DC29ULL, 0x3617DE4A96262C6FULL},
};

/*
 * Limb vectors
 */

/* x, as far as the optimizer can tell, any value */
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

/* all ones if bit (0 or 1) is 1, else 0 */
static limb
bitmask(limb bit)
{
	return barrier((limb)0 - bit);
}

static void
fcopy(limb *r, const limb *a, int n)
{
	int i;

	for(i = 0; i < n; i++)
		r[i] = a[i];
}

static void
fzero(limb *r, int n)
{
	int i;

	for(i = 0; i < n; i++)
		r[i] = 0;
}

/* all ones if a == 0, else 0 */
static limb
fiszero(const limb *a, int n)
{
	limb d;
	int i;

	d = 0;
	for(i = 0; i < n; i++)
		d |= a[i];
	return bitmask(((d | ((limb)0 - d)) >> 63) ^ 1);
}

/* all ones if a == b, else 0 */
static limb
fequal(const limb *a, const limb *b, int n)
{
	limb t[MAXLIMB];
	int i;

	for(i = 0; i < n; i++)
		t[i] = a[i] ^ b[i];
	return fiszero(t, n);
}

/* r = a - b, returning the borrow (0 or 1) */
static limb
fsubb(limb *r, const limb *a, const limb *b, int n)
{
	limb borrow;
	u128 v;
	int i;

	borrow = 0;
	for(i = 0; i < n; i++){
		v = SUB128_64(SUB128_64(U128_FROM64(a[i]), b[i]), borrow);
		r[i] = LO128(v);
		borrow = HI128(v) & 1;
	}
	return borrow;
}

/* all ones if a < b, else 0 */
static limb
fless(const limb *a, const limb *b, int n)
{
	limb t[MAXLIMB];

	return bitmask(fsubb(t, a, b, n));
}

/* r = mask ? a : b */
static void
fselect(limb *r, limb mask, const limb *a, const limb *b, int n)
{
	int i;

	mask = barrier(mask);
	for(i = 0; i < n; i++)
		r[i] = (a[i] & mask) | (b[i] & ~mask);
}

/* r = a mod m, for a < 2m */
static void
freduce(const Mont *M, limb *r, const limb *a)
{
	limb t[MAXLIMB], borrow;

	borrow = fsubb(t, a, M->m, M->n);
	fselect(r, bitmask(borrow), a, t, M->n);
}

/* 48- or 32-byte big-endian <-> little-endian limbs */
static void
bytestof(limb *r, const uchar *b, int n)
{
	int i, j, k;

	for(i = 0; i < n; i++){
		k = (n - 1 - i) * 8;
		r[i] = 0;
		for(j = 0; j < 8; j++)
			r[i] = r[i] << 8 | b[k + j];
	}
}

static void
ftobytes(uchar *b, const limb *a, int n)
{
	int i, j, k;

	for(i = 0; i < n; i++){
		k = (n - 1 - i) * 8;
		for(j = 0; j < 8; j++)
			b[k + j] = a[i] >> (56 - 8*j);
	}
}

/*
 * Arithmetic mod M->m.  Inputs are < m; so are outputs.
 */

/* r = a + b */
static void
madd(const Mont *M, limb *r, const limb *a, const limb *b)
{
	limb t[MAXLIMB], s[MAXLIMB], carry, borrow;
	u128 c;
	int i, n;

	n = M->n;
	c = U128_FROM64(0);
	for(i = 0; i < n; i++){
		c = ADD128_64(ADD128_64(c, a[i]), b[i]);
		t[i] = LO128(c);
		c = U128_FROM64(SHR128_64(c));
	}
	carry = LO128(c);
	borrow = fsubb(s, t, M->m, n);
	/* (carry:t) < m exactly when the subtraction borrows past the carry */
	fselect(r, bitmask(borrow & (carry ^ 1)), t, s, n);
}

/* r = a - b */
static void
msub(const Mont *M, limb *r, const limb *a, const limb *b)
{
	limb t[MAXLIMB], mask;
	u128 c;
	int i, n;

	n = M->n;
	mask = bitmask(fsubb(t, a, b, n));
	c = U128_FROM64(0);
	for(i = 0; i < n; i++){
		c = ADD128_64(ADD128_64(c, t[i]), M->m[i] & mask);
		r[i] = LO128(c);
		c = U128_FROM64(SHR128_64(c));
	}
}

/* r = a * b * R^-1 (CIOS) */
static void
mmul(const Mont *M, limb *r, const limb *a, const limb *b)
{
	limb t[MAXLIMB + 2], s[MAXLIMB], m, c, borrow;
	u128 x;
	int i, j, n;

	n = M->n;
	for(i = 0; i < n + 2; i++)
		t[i] = 0;
	for(i = 0; i < n; i++){
		c = 0;
		for(j = 0; j < n; j++){
			x = ADD128_64(ADD128_64(MUL128(a[j], b[i]), t[j]), c);
			t[j] = LO128(x);
			c = HI128(x);
		}
		x = ADD128_64(U128_FROM64(t[n]), c);
		t[n] = LO128(x);
		t[n+1] = HI128(x);

		m = t[0] * M->minv;
		x = ADD128_64(MUL128(m, M->m[0]), t[0]);
		c = HI128(x);
		for(j = 1; j < n; j++){
			x = ADD128_64(ADD128_64(MUL128(m, M->m[j]), t[j]), c);
			t[j-1] = LO128(x);
			c = HI128(x);
		}
		x = ADD128_64(U128_FROM64(t[n]), c);
		t[n-1] = LO128(x);
		t[n] = t[n+1] + HI128(x);
	}
	/* t < 2m: take t - m unless that borrows past t[n] */
	borrow = fsubb(s, t, M->m, n);
	borrow = (borrow & (t[n] ^ 1)) & 1;
	fselect(r, bitmask(borrow), t, s, n);
}

static void
msqr(const Mont *M, limb *r, const limb *a)
{
	mmul(M, r, a, a);
}

/* into and out of the Montgomery domain */
static void
mto(const Mont *M, limb *r, const limb *a)
{
	mmul(M, r, a, M->rr);
}

static void
mfrom(const Mont *M, limb *r, const limb *a)
{
	felem one;

	fzero(one, M->n);
	one[0] = 1;
	mmul(M, r, a, one);
}

/* R mod m: one, in the Montgomery domain */
static void
mone(const Mont *M, limb *r)
{
	felem one;

	fzero(one, M->n);
	one[0] = 1;
	mto(M, r, one);
}

/* r = a^(m-2) = a^-1 (0 if a is 0); a and r in the Montgomery domain */
static void
minv(const Mont *M, limb *r, const limb *a)
{
	felem e, x, two;
	int i;

	fzero(two, M->n);
	two[0] = 2;
	fsubb(e, M->m, two, M->n);
	mone(M, x);
	/* the exponent is public: square and multiply, MSB first */
	for(i = 64*M->n - 1; i >= 0; i--){
		msqr(M, x, x);
		if((e[i/64] >> (i%64)) & 1)
			mmul(M, x, x, a);
	}
	fcopy(r, x, M->n);
}

/*
 * Points: projective (X:Y:Z), coordinates in the Montgomery domain;
 * the identity is (0:1:0).
 */
typedef struct Pt Pt;
struct Pt {
	felem	x;
	felem	y;
	felem	z;
};

static void
ptidentity(const Curve *C, Pt *r)
{
	fzero(r->x, C->p.n);
	mone(&C->p, r->y);
	fzero(r->z, C->p.n);
}

/*
 * r = a + b, complete (RCB16 Algorithm 4, a = -3); bm is b in the
 * Montgomery domain.  r may be a or b.
 */
static void
ptadd(const Curve *C, Pt *r, const Pt *a, const Pt *b, const limb *bm)
{
	const Mont *F;
	felem t0, t1, t2, t3, t4, X3, Y3, Z3;

	F = &C->p;
	mmul(F, t0, a->x, b->x);
	mmul(F, t1, a->y, b->y);
	mmul(F, t2, a->z, b->z);
	madd(F, t3, a->x, a->y);
	madd(F, t4, b->x, b->y);
	mmul(F, t3, t3, t4);
	madd(F, t4, t0, t1);
	msub(F, t3, t3, t4);
	madd(F, t4, a->y, a->z);
	madd(F, X3, b->y, b->z);
	mmul(F, t4, t4, X3);
	madd(F, X3, t1, t2);
	msub(F, t4, t4, X3);
	madd(F, X3, a->x, a->z);
	madd(F, Y3, b->x, b->z);
	mmul(F, X3, X3, Y3);
	madd(F, Y3, t0, t2);
	msub(F, Y3, X3, Y3);
	mmul(F, Z3, bm, t2);
	msub(F, X3, Y3, Z3);
	madd(F, Z3, X3, X3);
	madd(F, X3, X3, Z3);
	msub(F, Z3, t1, X3);
	madd(F, X3, t1, X3);
	mmul(F, Y3, bm, Y3);
	madd(F, t1, t2, t2);
	madd(F, t2, t1, t2);
	msub(F, Y3, Y3, t2);
	msub(F, Y3, Y3, t0);
	madd(F, t1, Y3, Y3);
	madd(F, Y3, t1, Y3);
	madd(F, t1, t0, t0);
	madd(F, t0, t1, t0);
	msub(F, t0, t0, t2);
	mmul(F, t1, t4, Y3);
	mmul(F, t2, t0, Y3);
	mmul(F, Y3, X3, Z3);
	madd(F, Y3, Y3, t2);
	mmul(F, X3, t3, X3);
	msub(F, X3, X3, t1);
	mmul(F, Z3, t4, Z3);
	mmul(F, t1, t3, t0);
	madd(F, Z3, Z3, t1);
	fcopy(r->x, X3, F->n);
	fcopy(r->y, Y3, F->n);
	fcopy(r->z, Z3, F->n);
}

/* r = 2a, complete (RCB16 Algorithm 6, a = -3).  r may be a. */
static void
ptdouble(const Curve *C, Pt *r, const Pt *a, const limb *bm)
{
	const Mont *F;
	felem t0, t1, t2, t3, X3, Y3, Z3;

	F = &C->p;
	msqr(F, t0, a->x);
	msqr(F, t1, a->y);
	msqr(F, t2, a->z);
	mmul(F, t3, a->x, a->y);
	madd(F, t3, t3, t3);
	mmul(F, Z3, a->x, a->z);
	madd(F, Z3, Z3, Z3);
	mmul(F, Y3, bm, t2);
	msub(F, Y3, Y3, Z3);
	madd(F, X3, Y3, Y3);
	madd(F, Y3, X3, Y3);
	msub(F, X3, t1, Y3);
	madd(F, Y3, t1, Y3);
	mmul(F, Y3, X3, Y3);
	mmul(F, X3, X3, t3);
	madd(F, t3, t2, t2);
	madd(F, t2, t2, t3);
	mmul(F, Z3, bm, Z3);
	msub(F, Z3, Z3, t2);
	msub(F, Z3, Z3, t0);
	madd(F, t3, Z3, Z3);
	madd(F, Z3, Z3, t3);
	madd(F, t3, t0, t0);
	madd(F, t0, t3, t0);
	msub(F, t0, t0, t2);
	mmul(F, t0, t0, Z3);
	madd(F, Y3, Y3, t0);
	mmul(F, t0, a->y, a->z);
	madd(F, t0, t0, t0);
	mmul(F, Z3, t0, Z3);
	msub(F, X3, X3, Z3);
	mmul(F, Z3, t0, t1);
	madd(F, Z3, Z3, Z3);
	madd(F, Z3, Z3, Z3);
	fcopy(r->x, X3, F->n);
	fcopy(r->y, Y3, F->n);
	fcopy(r->z, Z3, F->n);
}

/* r = tab[w], reading every entry */
static void
ptselect(const Curve *C, Pt *r, const Pt tab[1<<WBITS], int w)
{
	limb mask, d;
	int i, j, n;

	n = C->p.n;
	fzero(r->x, n);
	fzero(r->y, n);
	fzero(r->z, n);
	for(i = 0; i < (1<<WBITS); i++){
		d = (limb)(i ^ w);
		mask = bitmask((d - 1) >> 63);	/* all ones iff d == 0 */
		for(j = 0; j < n; j++){
			r->x[j] |= tab[i].x[j] & mask;
			r->y[j] |= tab[i].y[j] & mask;
			r->z[j] |= tab[i].z[j] & mask;
		}
	}
}

/*
 * r = k * a, k nbytes big-endian: a fixed 4-bit window, all
 * 2*nbytes digits of k, each one's multiple of a added (the identity's for
 * a 0 digit) after four doublings.
 */
static void
ptmul(const Curve *C, Pt *r, const uchar *k, const Pt *a)
{
	Pt tab[1<<WBITS], acc, t;
	felem bm;
	int i, j, w;

	mto(&C->p, bm, C->b);
	ptidentity(C, &tab[0]);
	tab[1] = *a;
	for(i = 2; i < (1<<WBITS); i++){
		if(i & 1)
			ptadd(C, &tab[i], &tab[i-1], a, bm);
		else
			ptdouble(C, &tab[i], &tab[i/2], bm);
	}
	ptidentity(C, &acc);
	for(i = 0; i < 2*C->nbytes; i++){
		if(i != 0)
			for(j = 0; j < WBITS; j++)
				ptdouble(C, &acc, &acc, bm);
		w = (k[i/2] >> (i & 1 ? 0 : 4)) & 0xF;
		ptselect(C, &t, tab, w);
		ptadd(C, &acc, &acc, &t, bm);
	}
	*r = acc;
	memset(tab, 0, sizeof tab);
	memset(&t, 0, sizeof t);
}

/* the base point */
static void
ptbase(const Curve *C, Pt *r)
{
	mto(&C->p, r->x, C->gx);
	mto(&C->p, r->y, C->gy);
	mone(&C->p, r->z);
}

/*
 * affine (x, y), out of the Montgomery domain; -1 for the identity
 * (whether the result is the identity is public)
 */
static int
ptaffine(const Curve *C, limb *x, limb *y, const Pt *a)
{
	const Mont *F;
	felem zi, t;

	F = &C->p;
	if(fiszero(a->z, F->n))
		return -1;
	minv(F, zi, a->z);
	mmul(F, t, a->x, zi);
	mfrom(F, x, t);
	if(y != nil){
		mmul(F, t, a->y, zi);
		mfrom(F, y, t);
	}
	return 0;
}

/*
 * A peer's affine point (big-endian x, y): each coordinate < p and the
 * point on the curve (which also excludes the identity, having no affine
 * form), else -1.  Its coordinates are public.
 */
static int
ptload(const Curve *C, Pt *r, const uchar *bx, const uchar *by)
{
	const Mont *F;
	felem x, y, lhs, rhs, t, bm;

	F = &C->p;
	bytestof(x, bx, F->n);
	bytestof(y, by, F->n);
	if(!fless(x, F->m, F->n) || !fless(y, F->m, F->n))
		return -1;
	mto(F, r->x, x);
	mto(F, r->y, y);
	mone(F, r->z);

	/* y^2 == x^3 - 3x + b */
	msqr(F, lhs, r->y);
	msqr(F, rhs, r->x);
	mmul(F, rhs, rhs, r->x);
	madd(F, t, r->x, r->x);
	madd(F, t, t, r->x);
	msub(F, rhs, rhs, t);
	mto(F, bm, C->b);
	madd(F, rhs, rhs, bm);
	if(!fequal(lhs, rhs, F->n))
		return -1;
	return 0;
}

/*
 * A uniform scalar in [1, n-1], by rejection: a candidate out of range is
 * dropped, and says nothing about the one kept.
 */
static int
randscalar(const Curve *C, uchar *k)
{
	felem s;
	int i;

	for(i = 0; i < 64; i++){
		genrandom(k, C->nbytes);
		bytestof(s, k, C->q.n);
		if(!fiszero(s, C->q.n) && fless(s, C->q.m, C->q.n)){
			memset(s, 0, sizeof s);
			return 0;
		}
	}
	return -1;
}

static int
keygen(const Curve *C, uchar *priv, uchar *pubx, uchar *puby)
{
	Pt g, r;
	felem x, y;

	if(randscalar(C, priv) < 0)
		return -1;
	ptbase(C, &g);
	ptmul(C, &r, priv, &g);
	if(ptaffine(C, x, y, &r) < 0)
		return -1;
	ftobytes(pubx, x, C->p.n);
	ftobytes(puby, y, C->p.n);
	/* a fault check: the public key must be on the curve */
	if(ptload(C, &g, pubx, puby) < 0)
		return -1;
	return 0;
}

static int
ecdh(const Curve *C, uchar *shared, const uchar *priv, const uchar *peerx, const uchar *peery)
{
	Pt p, r;
	felem x;

	if(ptload(C, &p, peerx, peery) < 0)
		return -1;
	ptmul(C, &r, priv, &p);
	if(ptaffine(C, x, nil, &r) < 0)
		return -1;
	ftobytes(shared, x, C->p.n);
	memset(&r, 0, sizeof r);
	return 0;
}

/* e: the leftmost nbytes of hash (FIPS 186 bits2int; both curves' orders are whole bytes), reduced mod n */
static void
hashtoscalar(const Curve *C, limb *e, const uchar *hash, int hashlen)
{
	uchar h[48];

	memset(h, 0, sizeof h);
	if(hashlen >= C->nbytes)
		memmove(h, hash, C->nbytes);
	else
		memmove(h + C->nbytes - hashlen, hash, hashlen);
	bytestof(e, h, C->q.n);
	freduce(&C->q, e, e);	/* e < 2^(8 nbytes) < 2n */
}

static int
ecdsasign(const Curve *C, uchar *sig, const uchar *priv, const uchar *hash, int hashlen)
{
	const Mont *Q;
	uchar k[48];
	felem e, d, r, s, km, t;
	Pt g, R;
	int i;

	Q = &C->q;
	hashtoscalar(C, e, hash, hashlen);
	bytestof(d, priv, Q->n);
	freduce(Q, d, d);
	mto(Q, d, d);
	mto(Q, e, e);
	ptbase(C, &g);
	for(i = 0; i < 100; i++){
		if(randscalar(C, k) < 0)
			break;
		/* r = x(kG) mod n; x < p < 2n */
		ptmul(C, &R, k, &g);
		if(ptaffine(C, r, nil, &R) < 0)
			continue;
		freduce(Q, r, r);
		if(fiszero(r, Q->n))
			continue;
		ftobytes(sig, r, Q->n);

		/* s = k^-1 (e + r d) mod n */
		bytestof(km, k, Q->n);
		mto(Q, km, km);
		minv(Q, km, km);
		mto(Q, t, r);
		mmul(Q, t, t, d);
		madd(Q, t, t, e);
		mmul(Q, s, km, t);
		mfrom(Q, s, s);
		if(fiszero(s, Q->n))
			continue;
		ftobytes(sig + C->nbytes, s, Q->n);
		memset(k, 0, sizeof k);
		memset(km, 0, sizeof km);
		memset(d, 0, sizeof d);
		return 0;
	}
	memset(k, 0, sizeof k);
	memset(d, 0, sizeof d);
	return -1;
}

/* signature, key and hash are public */
static int
ecdsaverify(const Curve *C, const uchar *sig, const uchar *pubx, const uchar *puby, const uchar *hash, int hashlen)
{
	const Mont *Q;
	felem r, s, e, w, u1, u2, x;
	uchar b1[48], b2[48];
	Pt g, pub, p1, p2;
	felem bm;

	Q = &C->q;
	bytestof(r, sig, Q->n);
	bytestof(s, sig + C->nbytes, Q->n);
	if(fiszero(r, Q->n) || fiszero(s, Q->n) || !fless(r, Q->m, Q->n) || !fless(s, Q->m, Q->n))
		return 0;
	if(ptload(C, &pub, pubx, puby) < 0)
		return 0;
	hashtoscalar(C, e, hash, hashlen);

	/* w = s^-1, u1 = e w, u2 = r w (mod n) */
	mto(Q, w, s);
	minv(Q, w, w);
	mto(Q, u1, e);
	mmul(Q, u1, u1, w);
	mfrom(Q, u1, u1);
	mto(Q, u2, r);
	mmul(Q, u2, u2, w);
	mfrom(Q, u2, u2);
	ftobytes(b1, u1, Q->n);
	ftobytes(b2, u2, Q->n);

	ptbase(C, &g);
	ptmul(C, &p1, b1, &g);
	ptmul(C, &p2, b2, &pub);
	mto(&C->p, bm, C->b);
	ptadd(C, &p1, &p1, &p2, bm);
	if(ptaffine(C, x, nil, &p1) < 0)
		return 0;
	freduce(Q, x, x);	/* x < p < 2n */
	return fequal(x, r, Q->n) != 0;
}

/*
 * Public API
 */

int
p256_keygen(uchar priv[32], ECpoint *pub)
{
	return keygen(&P256, priv, pub->x, pub->y);
}

int
p256_ecdh(uchar shared[32], uchar priv[32], ECpoint *peerpub)
{
	return ecdh(&P256, shared, priv, peerpub->x, peerpub->y);
}

int
p256_ecdsa_sign(uchar sig[64], uchar priv[32], uchar *hash, int hashlen)
{
	return ecdsasign(&P256, sig, priv, hash, hashlen);
}

int
p256_ecdsa_verify(uchar sig[64], ECpoint *pub, uchar *hash, int hashlen)
{
	return ecdsaverify(&P256, sig, pub->x, pub->y, hash, hashlen);
}

int
p384_keygen(uchar priv[48], ECpoint384 *pub)
{
	return keygen(&P384, priv, pub->x, pub->y);
}

int
p384_ecdh(uchar shared[48], uchar priv[48], ECpoint384 *peerpub)
{
	return ecdh(&P384, shared, priv, peerpub->x, peerpub->y);
}

int
p384_ecdsa_verify(uchar sig[96], ECpoint384 *pub, uchar *hash, int hashlen)
{
	return ecdsaverify(&P384, sig, pub->x, pub->y, hash, hashlen);
}
