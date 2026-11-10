/*
 * SHA-256's compression function with the ARMv8 Cryptography Extension's
 * instructions (SHA256H, SHA256H2, SHA256SU0, SHA256SU1): several times
 * sha256block.c's speed, which bounds a devssl session once AES is in
 * hardware (aesarm64.c).
 *
 * Used where sha2.c and sha256block.c ask (sha256arm64ok) and the
 * processor has them: Apple's (always), Linux's and Android's where
 * getauxval says so.  Built to nothing where NEON is not on, as in the
 * native kernel, whose C is -mgeneral-regs-only; it keeps
 * sha256block.c's code.
 */
#include "os.h"
#include <libsec.h>

#if defined(__aarch64__) && defined(__ARM_NEON)

#include <arm_neon.h>
#ifdef __linux__
#include <sys/auxv.h>
#endif

/* the instructions by name, so no compiler flag is needed for them */
#define SHA256H(a, e, t)	__asm__(".arch_extension sha2\n\tsha256h %q0, %q1, %2.4s" : "+w"(a) : "w"(e), "w"(t))
#define SHA256H2(e, a, t)	__asm__(".arch_extension sha2\n\tsha256h2 %q0, %q1, %2.4s" : "+w"(e) : "w"(a), "w"(t))
#define SHA256SU0(w0, w1)	__asm__(".arch_extension sha2\n\tsha256su0 %0.4s, %1.4s" : "+w"(w0) : "w"(w1))
#define SHA256SU1(w0, w2, w3)	__asm__(".arch_extension sha2\n\tsha256su1 %0.4s, %1.4s, %2.4s" : "+w"(w0) : "w"(w2), "w"(w3))

extern u32int sha256const[64];	/* sha256block.c */

static int hassha = -1;

int
sha256arm64ok(void)
{
	if(hassha < 0){
#if defined(__APPLE__)
		hassha = 1;	/* every Apple arm64 has it */
#elif defined(__linux__) && defined(AT_HWCAP)
		hassha = (getauxval(AT_HWCAP) & (1<<6)) != 0;	/* HWCAP_SHA2 */
#else
		hassha = 0;
#endif
	}
	return hassha;
}

/* the test's switch: 0 forces sha256block.c's own code */
void
sha256arm64use(int on)
{
	hassha = on ? -1 : 0;
	if(on)
		sha256arm64ok();
}

/* nblocks of 64 bytes into h, the state's eight words */
void
sha256arm64blocks(u32int h[8], const uchar *p, ulong nblocks)
{
	uint32x4_t abcd, efgh, abcd0, efgh0, w[4], t, a;
	int i;

	abcd = vld1q_u32(h);
	efgh = vld1q_u32(h+4);
	for(; nblocks > 0; nblocks--, p += 64){
		abcd0 = abcd;
		efgh0 = efgh;
		for(i = 0; i < 4; i++)
			w[i] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(p + 16*i)));
		for(i = 0; i < 16; i++){
			t = vaddq_u32(w[i&3], vld1q_u32(sha256const + 4*i));
			a = abcd;
			SHA256H(abcd, efgh, t);
			SHA256H2(efgh, a, t);
			if(i < 12){
				/* the message words four rounds of four on */
				SHA256SU0(w[i&3], w[(i+1)&3]);
				SHA256SU1(w[i&3], w[(i+2)&3], w[(i+3)&3]);
			}
		}
		abcd = vaddq_u32(abcd, abcd0);
		efgh = vaddq_u32(efgh, efgh0);
	}
	vst1q_u32(h, abcd);
	vst1q_u32(h+4, efgh);
}

#else

int
sha256arm64ok(void)
{
	return 0;
}

void
sha256arm64use(int on)
{
	USED(on);
}

void
sha256arm64blocks(u32int *h, const uchar *p, ulong nblocks)
{
	USED(h); USED(p); USED(nblocks);
}

#endif
