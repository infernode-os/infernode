/*
 * secp256k1 (SEC 2, 2.4.1; Ethereum, Bitcoin): ECDSA signing with
 * RFC 6979 nonces, low S and a recovery id; public key recovery
 * (ecrecover); verification.
 *
 * The structure is libsec/ecc.c's (P-256, P-384), and so is the claim:
 * constant time with respect to secret scalars and field elements.
 *
 *  - Field and scalar arithmetic is Montgomery multiplication (CIOS) on
 *    four 64-bit limbs through uint128.h, one routine for both moduli
 *    (the field prime p and the group order n).  Every loop runs a fixed
 *    number of times; the final subtraction, modular addition and
 *    subtraction select their result by mask, not by branch.
 *  - Points are projective (X:Y:Z) and added and doubled by the complete
 *    formulas for a = 0 of Renes, Costello and Batina, "Complete addition
 *    formulas for prime order elliptic curves" (EUROCRYPT 2016),
 *    Algorithms 7 and 9.  They have no exceptional cases (the identity,
 *    P + P and P + -P all go through the same instructions), so no branch
 *    depends on a point.
 *  - Scalar multiplication is a fixed 4-bit window over every bit of the
 *    scalar, its table entry chosen by scanning all 16 entries under masks.
 *  - Inversion is Fermat's: a^(p-2) by a fixed addition chain in the
 *    field, a^(n-2) by a fixed window over the (public) exponent for the
 *    nonce.  The square root, (p+1)/4, is a fixed chain too.
 *  - Every mask made from a bit goes through bitmask(), whose barrier hides
 *    from the compiler that it is 0 or all ones: clang otherwise turns a
 *    masked select back into a branch.
 *
 * What may branch is public: a signature or a public key given to us
 * (recovery, verification), a candidate scalar rejected as out of range
 * (the one kept tells nothing), whether a result is the identity, r or s
 * being zero (both are published).
 *
 * libmp is not used: its reduction and inversion take time that depends on
 * the operands.  tests/host/secp256k1_test.sh checks all of this on the
 * host, under valgrind.
 *
 * References:
 *   SEC 2: Recommended Elliptic Curve Domain Parameters, v2.0
 *   RFC 6979: Deterministic Usage of DSA and ECDSA
 *   go-ethereum: github.com/ethereum/go-ethereum/crypto
 *   bitcoin-core/libsecp256k1 (the square root's addition chain)
 */
#include "os.h"
#include <mp.h>
#include <libsec.h>
#include "uint128.h"

enum {
	NLIMB = 4,	/* 256 bits */
	WBITS = 4,	/* window width */
};

typedef u64int limb;
typedef limb felem[NLIMB];

/* an odd modulus and its Montgomery constants (R = 2^256) */
typedef struct Mont Mont;
struct Mont {
	limb	m[NLIMB];	/* modulus, little-endian limbs */
	limb	minv;		/* -m^-1 mod 2^64 */
	limb	rr[NLIMB];	/* R^2 mod m */
};

/* p = 2^256 - 2^32 - 977 */
static const Mont K1P = {
	{0xFFFFFFFEFFFFFC2FULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL},
	0xD838091DD2253531ULL,
	{0x000007A2000E90A1ULL, 0x0000000000000001ULL, 0x0000000000000000ULL, 0x0000000000000000ULL},
};

/* n, the order of G */
static const Mont K1N = {
	{0xBFD25E8CD0364141ULL, 0xBAAEDCE6AF48A03BULL, 0xFFFFFFFFFFFFFFFEULL, 0xFFFFFFFFFFFFFFFFULL},
	0x4B0DFF665588B13FULL,
	{0x896CF21467D7D140ULL, 0x741496C20E7CF878ULL, 0xE697F5E45BCD07C6ULL, 0x9D671CD581C69BC5ULL},
};

/* y^2 = x^3 + 7: 3b, for the complete formulas */
static const felem K1B = {7, 0, 0, 0};
static const felem K1B3 = {21, 0, 0, 0};

static const felem K1Gx = {
	0x59F2815B16F81798ULL, 0x029BFCDB2DCE28D9ULL, 0x55A06295CE870B07ULL, 0x79BE667EF9DCBBACULL
};
static const felem K1Gy = {
	0x9C47D08FFB10D4B8ULL, 0xFD17B448A6855419ULL, 0x5DA4FBFC0E1108A8ULL, 0x483ADA7726A3C465ULL
};

/* n/2 (rounded down): s above it is high (BIP-62, EIP-2) */
static const felem K1HALFN = {
	0xDFE92F46681B20A0ULL, 0x5D576E7357A4501DULL, 0xFFFFFFFFFFFFFFFFULL, 0x7FFFFFFFFFFFFFFFULL
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
fcopy(limb *r, const limb *a)
{
	int i;

	for(i = 0; i < NLIMB; i++)
		r[i] = a[i];
}

static void
fzero(limb *r)
{
	int i;

	for(i = 0; i < NLIMB; i++)
		r[i] = 0;
}

/* all ones if a == 0, else 0 */
static limb
fiszero(const limb *a)
{
	limb d;
	int i;

	d = 0;
	for(i = 0; i < NLIMB; i++)
		d |= a[i];
	return bitmask(((d | ((limb)0 - d)) >> 63) ^ 1);
}

/* all ones if a == b, else 0 */
static limb
fequal(const limb *a, const limb *b)
{
	felem t;
	int i;

	for(i = 0; i < NLIMB; i++)
		t[i] = a[i] ^ b[i];
	return fiszero(t);
}

/* r = a - b, returning the borrow (0 or 1) */
static limb
fsubb(limb *r, const limb *a, const limb *b)
{
	limb borrow;
	u128 v;
	int i;

	borrow = 0;
	for(i = 0; i < NLIMB; i++){
		v = SUB128_64(SUB128_64(U128_FROM64(a[i]), b[i]), borrow);
		r[i] = LO128(v);
		borrow = HI128(v) & 1;
	}
	return borrow;
}

/* all ones if a < b, else 0 */
static limb
fless(const limb *a, const limb *b)
{
	felem t;

	return bitmask(fsubb(t, a, b));
}

/* r = mask ? a : b */
static void
fselect(limb *r, limb mask, const limb *a, const limb *b)
{
	int i;

	mask = barrier(mask);
	for(i = 0; i < NLIMB; i++)
		r[i] = (a[i] & mask) | (b[i] & ~mask);
}

/* r = a mod m, for a < 2m */
static void
freduce(const Mont *M, limb *r, const limb *a)
{
	felem t;
	limb borrow;

	borrow = fsubb(t, a, M->m);
	fselect(r, bitmask(borrow), a, t);
}

/* 32-byte big-endian <-> little-endian limbs */
static void
bytestof(limb *r, const uchar *b)
{
	int i, j, k;

	for(i = 0; i < NLIMB; i++){
		k = (NLIMB - 1 - i) * 8;
		r[i] = 0;
		for(j = 0; j < 8; j++)
			r[i] = r[i] << 8 | b[k + j];
	}
}

static void
ftobytes(uchar *b, const limb *a)
{
	int i, j, k;

	for(i = 0; i < NLIMB; i++){
		k = (NLIMB - 1 - i) * 8;
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
	felem t, s;
	limb carry, borrow;
	u128 c;
	int i;

	c = U128_FROM64(0);
	for(i = 0; i < NLIMB; i++){
		c = ADD128_64(ADD128_64(c, a[i]), b[i]);
		t[i] = LO128(c);
		c = U128_FROM64(SHR128_64(c));
	}
	carry = LO128(c);
	borrow = fsubb(s, t, M->m);
	/* (carry:t) < m exactly when the subtraction borrows past the carry */
	fselect(r, bitmask(borrow & (carry ^ 1)), t, s);
}

/* r = a - b */
static void
msub(const Mont *M, limb *r, const limb *a, const limb *b)
{
	felem t;
	limb mask;
	u128 c;
	int i;

	mask = bitmask(fsubb(t, a, b));
	c = U128_FROM64(0);
	for(i = 0; i < NLIMB; i++){
		c = ADD128_64(ADD128_64(c, t[i]), M->m[i] & mask);
		r[i] = LO128(c);
		c = U128_FROM64(SHR128_64(c));
	}
}

/* r = -a */
static void
mneg(const Mont *M, limb *r, const limb *a)
{
	felem z;

	fzero(z);
	msub(M, r, z, a);
}

/* r = a * b * R^-1 (CIOS) */
static void
mmul(const Mont *M, limb *r, const limb *a, const limb *b)
{
	limb t[NLIMB + 2], s[NLIMB], m, c, borrow;
	u128 x;
	int i, j;

	for(i = 0; i < NLIMB + 2; i++)
		t[i] = 0;
	for(i = 0; i < NLIMB; i++){
		c = 0;
		for(j = 0; j < NLIMB; j++){
			x = ADD128_64(ADD128_64(MUL128(a[j], b[i]), t[j]), c);
			t[j] = LO128(x);
			c = HI128(x);
		}
		x = ADD128_64(U128_FROM64(t[NLIMB]), c);
		t[NLIMB] = LO128(x);
		t[NLIMB+1] = HI128(x);

		m = t[0] * M->minv;
		x = ADD128_64(MUL128(m, M->m[0]), t[0]);
		c = HI128(x);
		for(j = 1; j < NLIMB; j++){
			x = ADD128_64(ADD128_64(MUL128(m, M->m[j]), t[j]), c);
			t[j-1] = LO128(x);
			c = HI128(x);
		}
		x = ADD128_64(U128_FROM64(t[NLIMB]), c);
		t[NLIMB-1] = LO128(x);
		t[NLIMB] = t[NLIMB+1] + HI128(x);
	}
	/* t < 2m: take t - m unless that borrows past t[NLIMB] */
	borrow = fsubb(s, t, M->m);
	borrow = (borrow & (t[NLIMB] ^ 1)) & 1;
	fselect(r, bitmask(borrow), t, s);
}

static void
msqr(const Mont *M, limb *r, const limb *a)
{
	mmul(M, r, a, a);
}

/* r = a^(2^k) */
static void
msqrn(const Mont *M, limb *r, const limb *a, int k)
{
	fcopy(r, a);
	while(k-- > 0)
		msqr(M, r, r);
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

	fzero(one);
	one[0] = 1;
	mmul(M, r, a, one);
}

/* R mod m: one, in the Montgomery domain */
static void
mone(const Mont *M, limb *r)
{
	felem one;

	fzero(one);
	one[0] = 1;
	mto(M, r, one);
}

/*
 * r = a^e for a public exponent e: a fixed 4-bit window, the table
 * indexed by the exponent's digits.  a and r in the Montgomery domain.
 */
static void
mpow(const Mont *M, limb *r, const limb *a, const limb *e)
{
	felem tab[1<<WBITS], x;
	int i, j, w;

	mone(M, tab[0]);
	fcopy(tab[1], a);
	for(i = 2; i < (1<<WBITS); i++)
		mmul(M, tab[i], tab[i-1], a);
	mone(M, x);
	for(i = 256/WBITS - 1; i >= 0; i--){
		for(j = 0; j < WBITS; j++)
			msqr(M, x, x);
		w = (e[i*WBITS/64] >> ((i*WBITS) % 64)) & ((1<<WBITS) - 1);
		mmul(M, x, x, tab[w]);
	}
	fcopy(r, x);
	memset(tab, 0, sizeof tab);
}

/*
 * x2 = a^(2^2-1), x3 = a^(2^3-1), x22 = a^(2^22-1), x223 = a^(2^223-1):
 * the common head of the field's inversion and square root chains.
 */
static void
pchain(limb *x2, limb *x3, limb *x22, limb *x223, const limb *a)
{
	const Mont *F;
	felem x6, x9, x11, x44, x88, x176, x220, t;

	F = &K1P;
	msqr(F, x2, a);
	mmul(F, x2, x2, a);
	msqr(F, x3, x2);
	mmul(F, x3, x3, a);
	msqrn(F, t, x3, 3);
	mmul(F, x6, t, x3);
	msqrn(F, t, x6, 3);
	mmul(F, x9, t, x3);
	msqrn(F, t, x9, 2);
	mmul(F, x11, t, x2);
	msqrn(F, t, x11, 11);
	mmul(F, x22, t, x11);
	msqrn(F, t, x22, 22);
	mmul(F, x44, t, x22);
	msqrn(F, t, x44, 44);
	mmul(F, x88, t, x44);
	msqrn(F, t, x88, 88);
	mmul(F, x176, t, x88);
	msqrn(F, t, x176, 44);
	mmul(F, x220, t, x44);
	msqrn(F, t, x220, 3);
	mmul(F, x223, t, x3);
}

/*
 * r = a^(p-2) = a^-1 (0 if a is 0), in the Montgomery domain.
 * p-2 = ((((2^223-1) << 23 | 2^22-1) << 5 | 1) << 3 | 3) << 2 | 1.
 */
static void
pinv(limb *r, const limb *a)
{
	const Mont *F;
	felem x2, x3, x22, x223, t;

	F = &K1P;
	pchain(x2, x3, x22, x223, a);
	msqrn(F, t, x223, 23);
	mmul(F, t, t, x22);
	msqrn(F, t, t, 5);
	mmul(F, t, t, a);
	msqrn(F, t, t, 3);
	mmul(F, t, t, x2);
	msqrn(F, t, t, 2);
	mmul(F, r, t, a);
}

/*
 * r = a^((p+1)/4), a square root of a if it has one (p = 3 mod 4), in the
 * Montgomery domain.  (p+1)/4 = (((2^223-1) << 23 | 2^22-1) << 6 | 3) << 2.
 */
static void
psqrt(limb *r, const limb *a)
{
	const Mont *F;
	felem x2, x3, x22, x223, t;

	F = &K1P;
	pchain(x2, x3, x22, x223, a);
	msqrn(F, t, x223, 23);
	mmul(F, t, t, x22);
	msqrn(F, t, t, 6);
	mmul(F, t, t, x2);
	msqrn(F, r, t, 2);
}

/* r = a^(n-2) = a^-1 mod n (0 if a is 0), in the Montgomery domain */
static void
ninv(limb *r, const limb *a)
{
	felem e, two;

	fzero(two);
	two[0] = 2;
	fsubb(e, K1N.m, two);
	mpow(&K1N, r, a, e);
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
ptidentity(Pt *r)
{
	fzero(r->x);
	mone(&K1P, r->y);
	fzero(r->z);
}

/* 3b in the Montgomery domain */
static void
b3mont(limb *r)
{
	mto(&K1P, r, K1B3);
}

/*
 * r = a + b, complete (RCB16 Algorithm 7, a = 0); b3 is 3b in the
 * Montgomery domain.  r may be a or b.
 */
static void
ptadd(Pt *r, const Pt *a, const Pt *b, const limb *b3)
{
	const Mont *F;
	felem t0, t1, t2, t3, t4, X3, Y3, Z3;

	F = &K1P;
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
	madd(F, X3, t0, t0);
	madd(F, t0, X3, t0);
	mmul(F, t2, b3, t2);
	madd(F, Z3, t1, t2);
	msub(F, t1, t1, t2);
	mmul(F, Y3, b3, Y3);
	mmul(F, X3, t4, Y3);
	mmul(F, t2, t3, t1);
	msub(F, X3, t2, X3);
	mmul(F, Y3, Y3, t0);
	mmul(F, t1, t1, Z3);
	madd(F, Y3, t1, Y3);
	mmul(F, t0, t0, t3);
	mmul(F, Z3, Z3, t4);
	madd(F, Z3, Z3, t0);
	fcopy(r->x, X3);
	fcopy(r->y, Y3);
	fcopy(r->z, Z3);
}

/* r = 2a, complete (RCB16 Algorithm 9, a = 0).  r may be a. */
static void
ptdouble(Pt *r, const Pt *a, const limb *b3)
{
	const Mont *F;
	felem t0, t1, t2, X3, Y3, Z3;

	F = &K1P;
	msqr(F, t0, a->y);
	madd(F, Z3, t0, t0);
	madd(F, Z3, Z3, Z3);
	madd(F, Z3, Z3, Z3);
	mmul(F, t1, a->y, a->z);
	msqr(F, t2, a->z);
	mmul(F, t2, b3, t2);
	mmul(F, X3, t2, Z3);
	madd(F, Y3, t0, t2);
	mmul(F, Z3, t1, Z3);
	madd(F, t1, t2, t2);
	madd(F, t2, t1, t2);
	msub(F, t0, t0, t2);
	mmul(F, Y3, t0, Y3);
	madd(F, Y3, X3, Y3);
	mmul(F, t1, a->x, a->y);
	mmul(F, X3, t0, t1);
	madd(F, X3, X3, X3);
	fcopy(r->x, X3);
	fcopy(r->y, Y3);
	fcopy(r->z, Z3);
}

/* r = tab[w], reading every entry */
static void
ptselect(Pt *r, const Pt tab[1<<WBITS], int w)
{
	limb mask, d;
	int i, j;

	fzero(r->x);
	fzero(r->y);
	fzero(r->z);
	for(i = 0; i < (1<<WBITS); i++){
		d = (limb)(i ^ w);
		mask = bitmask((d - 1) >> 63);	/* all ones iff d == 0 */
		for(j = 0; j < NLIMB; j++){
			r->x[j] |= tab[i].x[j] & mask;
			r->y[j] |= tab[i].y[j] & mask;
			r->z[j] |= tab[i].z[j] & mask;
		}
	}
}

/*
 * r = k * a, k 32 bytes big-endian: a fixed 4-bit window, all 64 digits
 * of k, each one's multiple of a added (the identity's for a 0 digit)
 * after four doublings.
 */
static void
ptmul(Pt *r, const uchar *k, const Pt *a)
{
	Pt tab[1<<WBITS], acc, t;
	felem b3;
	int i, j, w;

	b3mont(b3);
	ptidentity(&tab[0]);
	tab[1] = *a;
	for(i = 2; i < (1<<WBITS); i++){
		if(i & 1)
			ptadd(&tab[i], &tab[i-1], a, b3);
		else
			ptdouble(&tab[i], &tab[i/2], b3);
	}
	ptidentity(&acc);
	for(i = 0; i < 64; i++){
		if(i != 0)
			for(j = 0; j < WBITS; j++)
				ptdouble(&acc, &acc, b3);
		w = (k[i/2] >> (i & 1 ? 0 : 4)) & 0xF;
		ptselect(&t, tab, w);
		ptadd(&acc, &acc, &t, b3);
	}
	*r = acc;
	memset(tab, 0, sizeof tab);
	memset(&t, 0, sizeof t);
}

/* the base point */
static void
ptbase(Pt *r)
{
	mto(&K1P, r->x, K1Gx);
	mto(&K1P, r->y, K1Gy);
	mone(&K1P, r->z);
}

/*
 * affine (x, y), out of the Montgomery domain; -1 for the identity
 * (whether the result is the identity is public)
 */
static int
ptaffine(limb *x, limb *y, const Pt *a)
{
	const Mont *F;
	felem zi, t;

	F = &K1P;
	if(fiszero(a->z))
		return -1;
	pinv(zi, a->z);
	mmul(F, t, a->x, zi);
	mfrom(F, x, t);
	if(y != nil){
		mmul(F, t, a->y, zi);
		mfrom(F, y, t);
	}
	return 0;
}

/* x^3 + 7, all in the Montgomery domain */
static void
curverhs(limb *r, const limb *x)
{
	felem b;

	msqr(&K1P, r, x);
	mmul(&K1P, r, r, x);
	mto(&K1P, b, K1B);
	madd(&K1P, r, r, b);
}

/*
 * A public affine point (big-endian x, y): each coordinate < p and the
 * point on the curve (which also excludes the identity, having no affine
 * form), else -1.
 */
static int
ptload(Pt *r, const uchar *bx, const uchar *by)
{
	const Mont *F;
	felem x, y, lhs, rhs;

	F = &K1P;
	bytestof(x, bx);
	bytestof(y, by);
	if(!fless(x, F->m) || !fless(y, F->m))
		return -1;
	mto(F, r->x, x);
	mto(F, r->y, y);
	mone(F, r->z);
	msqr(F, lhs, r->y);
	curverhs(rhs, r->x);
	if(!fequal(lhs, rhs))
		return -1;
	return 0;
}

/* all ones if 0 < a < n (a, 32 bytes big-endian), else 0 */
static limb
scalarok(const uchar *a)
{
	felem s;
	limb ok;

	bytestof(s, a);
	ok = ~fiszero(s) & fless(s, K1N.m);
	memset(s, 0, sizeof s);
	return ok;
}

/* the leftmost 32 bytes of hash (left-padded if shorter), and that mod n */
static void
hashtoscalar(uchar h[32], limb *e, const uchar *hash, int hashlen)
{
	memset(h, 0, 32);
	if(hashlen >= 32)
		memmove(h, hash, 32);
	else if(hashlen > 0)
		memmove(h + 32 - hashlen, hash, hashlen);
	bytestof(e, h);
	freduce(&K1N, e, e);	/* e < 2^256 < 2n */
}

/* (x, y) as 0x04 || x || y */
static void
pubbytes(uchar pub[65], const limb *x, const limb *y)
{
	pub[0] = 0x04;
	ftobytes(pub + 1, x);
	ftobytes(pub + 33, y);
}

/* pub = priv * G; -1 if priv is out of range */
static int
pubfrompriv(uchar pub[65], const uchar priv[32])
{
	Pt g, r;
	felem x, y;

	if(!scalarok(priv))
		return -1;
	ptbase(&g);
	ptmul(&r, priv, &g);
	if(ptaffine(x, y, &r) < 0)
		return -1;
	pubbytes(pub, x, y);
	memset(&r, 0, sizeof r);
	/* a fault check: the public key must be on the curve */
	if(ptload(&g, pub + 1, pub + 33) < 0)
		return -1;
	return 0;
}

/*
 * RFC 6979 (3.2) with HMAC-SHA256: k from the private key and
 * h1 = int2octets(bits2int(hash) mod n).  A candidate out of [1, n-1] is
 * dropped, and says nothing about the one kept.
 */
static int
rfc6979(uchar kout[32], const uchar priv[32], const uchar h1[32])
{
	uchar V[32], K[32], buf[32+1+32+32];
	int i, rv;

	memset(V, 0x01, 32);
	memset(K, 0x00, 32);
	memmove(buf, V, 32);
	buf[32] = 0x00;
	memmove(buf+33, priv, 32);
	memmove(buf+65, h1, 32);
	hmac_sha256(buf, 97, K, 32, K, nil);
	hmac_sha256(V, 32, K, 32, V, nil);
	memmove(buf, V, 32);
	buf[32] = 0x01;
	hmac_sha256(buf, 97, K, 32, K, nil);
	hmac_sha256(V, 32, K, 32, V, nil);

	rv = -1;
	for(i = 0; i < 100; i++){
		hmac_sha256(V, 32, K, 32, V, nil);
		if(scalarok(V)){
			memmove(kout, V, 32);
			rv = 0;
			break;
		}
		memmove(buf, V, 32);
		buf[32] = 0x00;
		hmac_sha256(buf, 33, K, 32, K, nil);
		hmac_sha256(V, 32, K, 32, V, nil);
	}
	secureZero(V, sizeof V);
	secureZero(K, sizeof K);
	secureZero(buf, sizeof buf);
	return rv;
}

/*
 * Public API
 */

/* 1 if 0 < priv < n, else 0 */
int
secp256k1_privkey_valid(uchar priv[32])
{
	return scalarok(priv) != 0;
}

int
secp256k1_keygen(uchar priv[32], uchar pub[65])
{
	uchar k[32];
	int i;

	/*
	 * Rejection sampling: draw until 0 < k < n.  The rejection
	 * probability is ~2^-128, so one draw is virtually always enough;
	 * the loop bound only guards against a broken CSPRNG.
	 */
	for(i = 0; i < 64; i++){
		prng(k, 32);
		if(scalarok(k))
			break;
	}
	if(i == 64 || pubfrompriv(pub, k) < 0){
		secureZero(k, sizeof k);
		return -1;
	}
	memmove(priv, k, 32);
	secureZero(k, sizeof k);
	return 0;
}

int
secp256k1_pubkey(uchar pub[65], uchar priv[32])
{
	return pubfrompriv(pub, priv);
}

/*
 * ECDSA sign with recovery ID.
 * sig[65] = r[32] || s[32] || v[1], v the recovery id (0 or 1: R's y
 * parity), as Ethereum's ecrecover takes it.  Deterministic (RFC 6979),
 * and S is low (BIP-62, EIP-2): s > n/2 is replaced by n - s, and v
 * flipped with it.
 */
int
secp256k1_sign(uchar sig[65], uchar priv[32], uchar *hash, int hashlen)
{
	const Mont *Q;
	uchar k[32], h1[32];
	felem e, d, r, s, km, t, x, y;
	limb high, recid;
	Pt g, R;
	int rv;

	if(!scalarok(priv))
		return -1;
	Q = &K1N;
	rv = -1;
	hashtoscalar(h1, e, hash, hashlen);
	ftobytes(h1, e);
	if(rfc6979(k, priv, h1) < 0)
		goto out;

	/* R = kG; r = x(R) mod n (x < p < 2n), v = y(R) mod 2 */
	ptbase(&g);
	ptmul(&R, k, &g);
	if(ptaffine(x, y, &R) < 0)
		goto out;
	recid = y[0] & 1;
	freduce(Q, r, x);
	if(fiszero(r))
		goto out;

	/* s = k^-1 (e + r d) mod n */
	bytestof(d, priv);
	mto(Q, d, d);
	mto(Q, t, r);
	mmul(Q, t, t, d);
	mto(Q, e, e);
	madd(Q, t, t, e);
	bytestof(km, k);
	mto(Q, km, km);
	ninv(km, km);
	mmul(Q, s, km, t);
	mfrom(Q, s, s);
	if(fiszero(s))
		goto out;

	/* low S */
	high = fless(K1HALFN, s);
	mneg(Q, t, s);
	fselect(s, high, t, s);
	recid ^= high & 1;

	ftobytes(sig, r);
	ftobytes(sig + 32, s);
	sig[64] = recid;
	rv = 0;
out:
	secureZero(k, sizeof k);
	secureZero(d, sizeof d);
	secureZero(km, sizeof km);
	secureZero(t, sizeof t);
	secureZero(&R, sizeof R);
	return rv;
}

/* (r, s) from sig, each in [1, n-1], else -1; all public */
static int
sigload(limb *r, limb *s, const uchar *sig)
{
	bytestof(r, sig);
	bytestof(s, sig + 32);
	if(fiszero(r) || fiszero(s) || !fless(r, K1N.m) || !fless(s, K1N.m))
		return -1;
	return 0;
}

/* u1*G + u2*P, its affine x and y; -1 if it is the identity.  All public. */
static int
dualmul(limb *x, limb *y, const limb *u1, const limb *u2, const Pt *P)
{
	uchar b1[32], b2[32];
	Pt g, p1, p2;
	felem b3;

	ftobytes(b1, u1);
	ftobytes(b2, u2);
	ptbase(&g);
	ptmul(&p1, b1, &g);
	ptmul(&p2, b2, P);
	b3mont(b3);
	ptadd(&p1, &p1, &p2, b3);
	return ptaffine(x, y, &p1);
}

/*
 * Recover the public key from a signature and hash (ecrecover).
 * sig[65] = r[32] || s[32] || v[1] (v's low bit is R's y parity)
 * pub[65] = 0x04 || x[32] || y[32]
 * Returns 0 on success, -1 on failure.  Everything here is public.
 */
int
secp256k1_recover(uchar pub[65], uchar *hash, int hashlen, uchar sig[65])
{
	const Mont *F, *Q;
	uchar h[32];
	felem r, s, e, rm, y2, y, t, u1, u2, qx, qy;
	Pt R;

	F = &K1P;
	Q = &K1N;
	if(sigload(r, s, sig) < 0)
		return -1;

	/* R = (r, y), y^2 = r^3 + 7, y's parity v; r < n < p */
	mto(F, R.x, r);
	curverhs(y2, R.x);
	psqrt(y, y2);
	msqr(F, t, y);
	if(!fequal(t, y2))
		return -1;	/* r is no point's x */
	mfrom(F, t, y);
	if((t[0] & 1) != (sig[64] & 1))
		mneg(F, y, y);
	fcopy(R.y, y);
	mone(F, R.z);

	/* Q = r^-1 (s R - e G): u1 = -e r^-1, u2 = s r^-1 (mod n) */
	hashtoscalar(h, e, hash, hashlen);
	mto(Q, rm, r);
	ninv(rm, rm);
	mto(Q, u1, e);
	mmul(Q, u1, u1, rm);
	mfrom(Q, u1, u1);
	mneg(Q, u1, u1);
	mto(Q, u2, s);
	mmul(Q, u2, u2, rm);
	mfrom(Q, u2, u2);
	if(dualmul(qx, qy, u1, u2, &R) < 0)
		return -1;
	pubbytes(pub, qx, qy);
	return 0;
}

/* 1 if sig[64] = r || s is pub's signature of hash, else 0 */
int
secp256k1_verify(uchar sig[64], uchar pub[65], uchar *hash, int hashlen)
{
	const Mont *Q;
	uchar h[32];
	felem r, s, e, w, u1, u2, x, y;
	Pt P;

	Q = &K1N;
	if(pub[0] != 0x04)
		return 0;
	if(sigload(r, s, sig) < 0)
		return 0;
	if(ptload(&P, pub + 1, pub + 33) < 0)
		return 0;
	hashtoscalar(h, e, hash, hashlen);

	/* w = s^-1, u1 = e w, u2 = r w (mod n) */
	mto(Q, w, s);
	ninv(w, w);
	mto(Q, u1, e);
	mmul(Q, u1, u1, w);
	mfrom(Q, u1, u1);
	mto(Q, u2, r);
	mmul(Q, u2, u2, w);
	mfrom(Q, u2, u2);
	if(dualmul(x, y, u1, u2, &P) < 0)
		return 0;
	freduce(Q, x, x);	/* x < p < 2n */
	return fequal(x, r) != 0;
}
