/*
 * AES with the ARMv8 Cryptography Extension's instructions (AESE, AESD,
 * AESMC, AESIMC): several times the speed of aes.c's table code, and no
 * table indexed by key-dependent bytes for a cache to leak.
 *
 * Used where aes.c asks (aesarm64ok) and the processor has them: Apple's
 * (always), Linux's and Android's where getauxval says so.  Built to
 * nothing where NEON is not on, as in the native kernel, whose C is
 * -mgeneral-regs-only so that no interrupt path can touch the FP/SIMD
 * registers; it keeps aes.c's code.
 *
 * The key schedules are aes.c's (ekey, and dkey with InvMixColumns
 * applied to its inner round keys: the "equivalent inverse cipher" that
 * AESD and AESIMC expect), as big-endian words; each is loaded with its
 * bytes reversed per word.
 */
#include "os.h"
#include <libsec.h>

#if defined(__aarch64__) && defined(__ARM_NEON)

#include <arm_neon.h>
#ifdef __linux__
#include <sys/auxv.h>
#endif

/* AES's instructions by name, so no compiler flag is needed for them */
#define AESE(s, k)	__asm__(".arch_extension aes\n\taese %0.16b, %1.16b" : "+w"(s) : "w"(k))
#define AESD(s, k)	__asm__(".arch_extension aes\n\taesd %0.16b, %1.16b" : "+w"(s) : "w"(k))
#define AESMC(s)	__asm__(".arch_extension aes\n\taesmc %0.16b, %0.16b" : "+w"(s))
#define AESIMC(s)	__asm__(".arch_extension aes\n\taesimc %0.16b, %0.16b" : "+w"(s))

static int hasaes = -1;

int
aesarm64ok(void)
{
	if(hasaes < 0){
#if defined(__APPLE__)
		hasaes = 1;	/* every Apple arm64 has it */
#elif defined(__linux__) && defined(AT_HWCAP)
		hasaes = (getauxval(AT_HWCAP) & (1<<3)) != 0;	/* HWCAP_AES */
#else
		hasaes = 0;
#endif
	}
	return hasaes;
}

/* the test's switch: 0 forces aes.c's own code */
void
aesarm64use(int on)
{
	hasaes = on ? -1 : 0;
	if(on)
		aesarm64ok();
}

/* round keys, rounds+1 of them, from aes.c's big-endian words */
static void
loadkeys(uint8x16_t *k, const u32int *rk, int rounds)
{
	int i;

	for(i = 0; i <= rounds; i++)
		k[i] = vrev32q_u8(vld1q_u8((const uint8_t*)(rk + 4*i)));
}

static inline uint8x16_t
enc1(uint8x16_t s, const uint8x16_t *k, int rounds)
{
	int i;

	for(i = 0; i < rounds-1; i++){
		AESE(s, k[i]);
		AESMC(s);
	}
	AESE(s, k[rounds-1]);
	return veorq_u8(s, k[rounds]);
}

static inline uint8x16_t
dec1(uint8x16_t s, const uint8x16_t *k, int rounds)
{
	int i;

	for(i = 0; i < rounds-1; i++){
		AESD(s, k[i]);
		AESIMC(s);
	}
	AESD(s, k[rounds-1]);
	return veorq_u8(s, k[rounds]);
}

void
aesarm64encryptblock(const u32int *ekey, int rounds, const uchar pt[16], uchar ct[16])
{
	uint8x16_t k[AESmaxrounds+1];

	loadkeys(k, ekey, rounds);
	vst1q_u8(ct, enc1(vld1q_u8(pt), k, rounds));
}

/* nblocks of CBC in place, the chaining value in and out of iv */
void
aesarm64cbcencrypt(uchar *p, int nblocks, const u32int *ekey, int rounds, uchar *iv)
{
	uint8x16_t k[AESmaxrounds+1], c;

	loadkeys(k, ekey, rounds);
	c = vld1q_u8(iv);
	for(; nblocks > 0; nblocks--, p += 16){
		c = enc1(veorq_u8(vld1q_u8(p), c), k, rounds);
		vst1q_u8(p, c);
	}
	vst1q_u8(iv, c);
}

/* CBC decryption's blocks are independent: four at a time */
void
aesarm64cbcdecrypt(uchar *p, int nblocks, const u32int *dkey, int rounds, uchar *iv)
{
	uint8x16_t k[AESmaxrounds+1], prev, c0, c1, c2, c3, s0, s1, s2, s3;
	int i;

	loadkeys(k, dkey, rounds);
	prev = vld1q_u8(iv);
	for(; nblocks >= 4; nblocks -= 4, p += 64){
		s0 = c0 = vld1q_u8(p);
		s1 = c1 = vld1q_u8(p+16);
		s2 = c2 = vld1q_u8(p+32);
		s3 = c3 = vld1q_u8(p+48);
		for(i = 0; i < rounds-1; i++){
			AESD(s0, k[i]); AESIMC(s0);
			AESD(s1, k[i]); AESIMC(s1);
			AESD(s2, k[i]); AESIMC(s2);
			AESD(s3, k[i]); AESIMC(s3);
		}
		AESD(s0, k[rounds-1]);
		AESD(s1, k[rounds-1]);
		AESD(s2, k[rounds-1]);
		AESD(s3, k[rounds-1]);
		vst1q_u8(p, veorq_u8(veorq_u8(s0, k[rounds]), prev));
		vst1q_u8(p+16, veorq_u8(veorq_u8(s1, k[rounds]), c0));
		vst1q_u8(p+32, veorq_u8(veorq_u8(s2, k[rounds]), c1));
		vst1q_u8(p+48, veorq_u8(veorq_u8(s3, k[rounds]), c2));
		prev = c3;
	}
	for(; nblocks > 0; nblocks--, p += 16){
		c0 = vld1q_u8(p);
		vst1q_u8(p, veorq_u8(dec1(c0, k, rounds), prev));
		prev = c0;
	}
	vst1q_u8(iv, prev);
}

/*
 * GCM's counter mode: n bytes of p exclusive-ored in place with the
 * encryptions of ctr, ctr+1, ..., the count its last 32 bits, big-endian
 * (SP 800-38D's inc32), as aesgcm.c's loop does.  The round keys are
 * loaded once, and four counters are in flight at a time.
 */
void
aesarm64ctr32(const u32int *ekey, int rounds, const uchar ctr[16], uchar *p, ulong n)
{
	uint8x16_t k[AESmaxrounds+1], c[4], s[4];
	uchar blk[16];
	u32int base, i;
	ulong j, m;
	int l;

	loadkeys(k, ekey, rounds);
	memmove(blk, ctr, 16);
	base = (u32int)blk[12]<<24 | (u32int)blk[13]<<16 | (u32int)blk[14]<<8 | blk[15];
	for(i = 0; n > 0; ){
		for(l = 0; l < 4; l++){
			u32int v = base + i + l;
			blk[12] = v>>24; blk[13] = v>>16; blk[14] = v>>8; blk[15] = v;
			c[l] = vld1q_u8(blk);
		}
		for(l = 0; l < 4; l++)
			s[l] = enc1(c[l], k, rounds);
		for(l = 0; l < 4 && n > 0; l++){
			if(n >= 16){
				vst1q_u8(p, veorq_u8(vld1q_u8(p), s[l]));
				p += 16;
				n -= 16;
			}else{
				vst1q_u8(blk, s[l]);
				m = n;
				for(j = 0; j < m; j++)
					p[j] ^= blk[j];
				n = 0;
			}
		}
		i += 4;
	}
	memset(blk, 0, sizeof blk);
}

#else

int
aesarm64ok(void)
{
	return 0;
}

void
aesarm64use(int on)
{
	USED(on);
}

void
aesarm64encryptblock(const u32int *ekey, int rounds, const uchar *pt, uchar *ct)
{
	USED(ekey); USED(rounds); USED(pt); USED(ct);
}

void
aesarm64cbcencrypt(uchar *p, int nblocks, const u32int *ekey, int rounds, uchar *iv)
{
	USED(p); USED(nblocks); USED(ekey); USED(rounds); USED(iv);
}

void
aesarm64cbcdecrypt(uchar *p, int nblocks, const u32int *dkey, int rounds, uchar *iv)
{
	USED(p); USED(nblocks); USED(dkey); USED(rounds); USED(iv);
}

void
aesarm64ctr32(const u32int *ekey, int rounds, const uchar ctr[16], uchar *p, ulong n)
{
	USED(ekey); USED(rounds); USED(ctr); USED(p); USED(n);
}

#endif
