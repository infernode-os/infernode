/*
 * GCM's GHASH (NIST SP 800-38D) with x86-64's carry-less multiply,
 * PCLMULQDQ: no table indexed by the data or the key for a cache to
 * leak, and many times aesgcm.c's C.  This is ghasharm64.c's twin.
 *
 * GHASH's bits are reflected: byte 0's most significant bit is x^0.
 * With the 16 bytes reversed (PSHUFB) a block is the polynomial with
 * its bits in reverse order, x^127 at bit 0; the product of two such
 * is the reversed product one place down, so it is shifted left one
 * bit and then reduced by x^128 + x^7 + x^2 + x + 1 with shifts (Gueron
 * and Kounavis, "Intel carry-less multiplication instruction and its
 * usage for computing the GCM mode", 2010, algorithms 1 and 5).  Y is
 * kept so reversed between blocks and turned back at the end.
 *
 * The shift and the reduction are linear, so four products can be
 * added before them: Y' = (Y^X1)H^4 + X2 H^3 + X3 H^2 + X4 H, the four
 * multiplications not waiting on each other.  The powers of H are made
 * at each call that has blocks enough to repay them.
 *
 * Used where aesgcm.c asks (ghashamd64ok) and cpuid says the processor
 * has PCLMULQDQ and SSSE3.  Only the functions here are compiled for
 * those instructions.  Built to nothing but stubs where it does not
 * apply (see aesamd64.c): other processors, a native kernel, Microsoft's
 * compiler.
 */
#include "os.h"
#include <libsec.h>

#if defined(__x86_64__) && defined(__GNUC__) && !defined(_MSC_VER) && !defined(INFERNO_NATIVE)

#include <immintrin.h>
#include <cpuid.h>

#define CL	__attribute__((target("pclmul,ssse3")))

static int hasclmul = -1;

int
ghashamd64ok(void)
{
	unsigned int a, b, c, d;
	int has;

	if(hasclmul < 0){
		has = 0;
		/* CPUID.1:ECX bit 1 is PCLMULQDQ, bit 9 SSSE3 */
		if(__get_cpuid(1, &a, &b, &c, &d))
			has = (c & (1u<<1)) != 0 && (c & (1u<<9)) != 0;
		hasclmul = has;
	}
	return hasclmul;
}

/* the test's switch: 0 forces aesgcm.c's own code */
void
ghashamd64use(int on)
{
	hasclmul = on ? -1 : 0;
	if(on)
		ghashamd64ok();
}

/* a block with its 16 bytes reversed */
CL static inline __m128i
rev(__m128i b)
{
	return _mm_shuffle_epi8(b, _mm_set_epi8(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
}

/* the 256-bit carry-less product of a and b, added to hi:lo */
CL static inline void
clmuladd(__m128i a, __m128i b, __m128i *lo, __m128i *hi)
{
	__m128i t0, t1, t2, t3;

	t0 = _mm_clmulepi64_si128(a, b, 0x00);
	t1 = _mm_clmulepi64_si128(a, b, 0x10);
	t2 = _mm_clmulepi64_si128(a, b, 0x01);
	t3 = _mm_clmulepi64_si128(a, b, 0x11);
	t1 = _mm_xor_si128(t1, t2);
	*lo = _mm_xor_si128(*lo, _mm_xor_si128(t0, _mm_slli_si128(t1, 8)));
	*hi = _mm_xor_si128(*hi, _mm_xor_si128(t3, _mm_srli_si128(t1, 8)));
}

/* hi:lo shifted left one bit (the reflection), then reduced to 128 bits */
CL static inline __m128i
reduce(__m128i lo, __m128i hi)
{
	__m128i t7, t8, t9, t2, t4, t5;

	t7 = _mm_srli_epi32(lo, 31);
	t8 = _mm_srli_epi32(hi, 31);
	lo = _mm_slli_epi32(lo, 1);
	hi = _mm_slli_epi32(hi, 1);
	t9 = _mm_srli_si128(t7, 12);
	t8 = _mm_slli_si128(t8, 4);
	t7 = _mm_slli_si128(t7, 4);
	lo = _mm_or_si128(lo, t7);
	hi = _mm_or_si128(hi, t8);
	hi = _mm_or_si128(hi, t9);

	t7 = _mm_slli_epi32(lo, 31);
	t8 = _mm_slli_epi32(lo, 30);
	t9 = _mm_slli_epi32(lo, 25);
	t7 = _mm_xor_si128(t7, t8);
	t7 = _mm_xor_si128(t7, t9);
	t8 = _mm_srli_si128(t7, 4);
	t7 = _mm_slli_si128(t7, 12);
	lo = _mm_xor_si128(lo, t7);

	t2 = _mm_srli_epi32(lo, 1);
	t4 = _mm_srli_epi32(lo, 2);
	t5 = _mm_srli_epi32(lo, 7);
	t2 = _mm_xor_si128(t2, t4);
	t2 = _mm_xor_si128(t2, t5);
	t2 = _mm_xor_si128(t2, t8);
	lo = _mm_xor_si128(lo, t2);
	return _mm_xor_si128(hi, lo);
}

/* a*b in GHASH's field, both byte-reversed */
CL static inline __m128i
gfmul(__m128i a, __m128i b)
{
	__m128i lo, hi;

	lo = _mm_setzero_si128();
	hi = _mm_setzero_si128();
	clmuladd(a, b, &lo, &hi);
	return reduce(lo, hi);
}

#define LOAD(p)	rev(_mm_loadu_si128((const __m128i*)(p)))

/* Y = (Y ^ X) * H for each 16-byte X of p; n a multiple of 16 */
CL void
ghashamd64(uchar y[16], const uchar h[16], const uchar *p, ulong n)
{
	__m128i Y, H, Hp[3], lo, hi;

	Y = LOAD(y);
	H = LOAD(h);
	if(n >= 8*16){
		Hp[0] = gfmul(H, H);
		Hp[1] = gfmul(Hp[0], H);
		Hp[2] = gfmul(Hp[1], H);
		for(; n >= 64; n -= 64, p += 64){
			lo = _mm_setzero_si128();
			hi = _mm_setzero_si128();
			clmuladd(_mm_xor_si128(Y, LOAD(p)), Hp[2], &lo, &hi);
			clmuladd(LOAD(p+16), Hp[1], &lo, &hi);
			clmuladd(LOAD(p+32), Hp[0], &lo, &hi);
			clmuladd(LOAD(p+48), H, &lo, &hi);
			Y = reduce(lo, hi);
		}
		/* H's powers are the key's: cleared by stores a compiler keeps */
		secureZero(Hp, sizeof Hp);
	}
	for(; n >= 16; n -= 16, p += 16)
		Y = gfmul(_mm_xor_si128(Y, LOAD(p)), H);
	_mm_storeu_si128((__m128i*)y, rev(Y));
}

#else

int
ghashamd64ok(void)
{
	return 0;
}

void
ghashamd64use(int on)
{
	USED(on);
}

void
ghashamd64(uchar y[16], const uchar h[16], const uchar *p, ulong n)
{
	USED(y); USED(h); USED(p); USED(n);
}

#endif
