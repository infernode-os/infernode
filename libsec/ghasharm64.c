/*
 * GCM's GHASH (NIST SP 800-38D) with the ARMv8 Cryptography Extension's
 * 64-bit carry-less multiply, PMULL: no table indexed by the data or the
 * key for a cache to leak, and several times aesgcm.c's C.
 *
 * GHASH's bits are reflected: byte 0's most significant bit is x^0.  With
 * each byte's bits reversed (RBIT), the 16 bytes read little-endian are the
 * polynomial plainly, x^i at bit i, so the product is the ordinary one:
 * Karatsuba's three PMULLs make 256 bits, which x^128 = x^7 + x^2 + x + 1
 * folds twice to 128.  Y is kept so reversed between blocks and turned
 * back at the end.
 *
 * Used where aesgcm.c asks (ghasharm64ok) and the processor has PMULL:
 * Apple's (always), Linux's and Android's where getauxval says so.  Built
 * to nothing where NEON is not on, as in the native kernel, whose C is
 * -mgeneral-regs-only; it keeps aesgcm.c's C.
 */
#include "os.h"
#include <libsec.h>

#if defined(__aarch64__) && defined(__ARM_NEON)

#include <arm_neon.h>
#ifdef __linux__
#include <sys/auxv.h>
#endif

static int haspmull = -1;

int
ghasharm64ok(void)
{
	if(haspmull < 0){
#if defined(__APPLE__)
		haspmull = 1;	/* every Apple arm64 has it */
#elif defined(__linux__) && defined(AT_HWCAP)
		haspmull = (getauxval(AT_HWCAP) & (1<<4)) != 0;	/* HWCAP_PMULL */
#else
		haspmull = 0;
#endif
	}
	return haspmull;
}

/* the test's switch: 0 forces aesgcm.c's own code */
void
ghasharm64use(int on)
{
	haspmull = on ? -1 : 0;
	if(on)
		ghasharm64ok();
}

/* PMULL of the low (or high) 64-bit lanes, by name, so no compiler flag is needed */
static inline uint64x2_t
pmull_lo(uint64x2_t a, uint64x2_t b)
{
	uint64x2_t r;

	__asm__(".arch_extension aes\n\tpmull %0.1q, %1.1d, %2.1d" : "=w"(r) : "w"(a), "w"(b));
	return r;
}

static inline uint64x2_t
pmull_hi(uint64x2_t a, uint64x2_t b)
{
	uint64x2_t r;

	__asm__(".arch_extension aes\n\tpmull2 %0.1q, %1.2d, %2.2d" : "=w"(r) : "w"(a), "w"(b));
	return r;
}

static inline uint64x2_t
rev(uint8x16_t b)
{
	return vreinterpretq_u64_u8(vrbitq_u8(b));
}

/* a*b mod x^128 + x^7 + x^2 + x + 1, both plain (bit-reversed GHASH) */
static inline uint64x2_t
gfmul(uint64x2_t a, uint64x2_t b)
{
	uint64x2_t lo, hi, mid, t, r, w;
	uint64_t lo0, lo1, hi0, hi1;

	lo = pmull_lo(a, b);
	hi = pmull_hi(a, b);
	/* (a0^a1)(b0^b1) in the low lanes */
	t = veorq_u64(a, vextq_u64(a, a, 1));
	w = veorq_u64(b, vextq_u64(b, b, 1));
	mid = veorq_u64(pmull_lo(t, w), veorq_u64(lo, hi));

	/* the 256-bit product: hi:lo with mid at 64 */
	lo0 = vgetq_lane_u64(lo, 0);
	lo1 = vgetq_lane_u64(lo, 1) ^ vgetq_lane_u64(mid, 0);
	hi0 = vgetq_lane_u64(hi, 0) ^ vgetq_lane_u64(mid, 1);
	hi1 = vgetq_lane_u64(hi, 1);

	r = vdupq_n_u64(0x87);
	/* hi1 sits at x^192: x^128 * x^64, so 0x87*hi1 goes in at x^64 */
	w = pmull_lo(vdupq_n_u64(hi1), r);
	lo1 ^= vgetq_lane_u64(w, 0);
	hi0 ^= vgetq_lane_u64(w, 1);
	/* hi0 at x^128 */
	w = pmull_lo(vdupq_n_u64(hi0), r);
	lo0 ^= vgetq_lane_u64(w, 0);
	lo1 ^= vgetq_lane_u64(w, 1);
	return vcombine_u64(vcreate_u64(lo0), vcreate_u64(lo1));
}

/* Y = (Y ^ X) * H for each 16-byte X of p; n a multiple of 16 */
void
ghasharm64(uchar y[16], const uchar h[16], const uchar *p, ulong n)
{
	uint64x2_t Y, H;

	Y = rev(vld1q_u8(y));
	H = rev(vld1q_u8(h));
	for(; n >= 16; n -= 16, p += 16)
		Y = gfmul(veorq_u64(Y, rev(vld1q_u8(p))), H);
	vst1q_u8(y, vrbitq_u8(vreinterpretq_u8_u64(Y)));
}

#else

int
ghasharm64ok(void)
{
	return 0;
}

void
ghasharm64use(int on)
{
	USED(on);
}

void
ghasharm64(uchar y[16], const uchar h[16], const uchar *p, ulong n)
{
	USED(y); USED(h); USED(p); USED(n);
}

#endif
