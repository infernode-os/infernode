/*
 * AES with x86-64's AES instructions (AES-NI: AESENC, AESDEC, AESIMC,
 * AESKEYGENASSIST): many times the speed of aes.c's C, which is
 * constant time by bit planes; these are constant time by construction
 * (no table, no branch on the state).  This is aesarm64.c's twin.
 *
 * Used where aes.c asks (aesamd64ok) and cpuid says the processor has
 * AES and SSSE3 (PSHUFB, for the byte orders): every x86-64 since about
 * 2010-2013, but not all, so it is asked at run time and the C stays
 * for the rest.  Only the functions here are compiled for those
 * instructions (the target attribute); the rest of the library is built
 * with the flags it always had, so nothing else can come to use them.
 *
 * Built to nothing but stubs where it does not apply: other processors,
 * a native kernel (which would have to save the XMM registers first),
 * and Microsoft's compiler, which has the intrinsics but neither the
 * attribute nor cpuid.h: Windows keeps aes.c's C.
 *
 * The key schedules are aes.c's (ekey, and dkey with InvMixColumns
 * applied to its inner round keys: the "equivalent inverse cipher" that
 * AESDEC expects), as big-endian words; each is loaded with its bytes
 * reversed per word.  aesamd64expand makes the same two schedules from
 * a key with the instructions (FIPS 197 5.2 and 5.3.5), since SubWord
 * in bit planes is most of what a short message costs.
 */
#include "os.h"
#include <libsec.h>

#if defined(__x86_64__) && defined(__GNUC__) && !defined(_MSC_VER) && !defined(INFERNO_NATIVE)

#include <immintrin.h>
#include <cpuid.h>

#define NI	__attribute__((target("aes,ssse3")))

static int hasaes = -1;

int
aesamd64ok(void)
{
	unsigned int a, b, c, d;
	int has;

	if(hasaes < 0){
		has = 0;
		/* CPUID.1:ECX bit 25 is AES, bit 9 SSSE3 */
		if(__get_cpuid(1, &a, &b, &c, &d))
			has = (c & (1u<<25)) != 0 && (c & (1u<<9)) != 0;
		hasaes = has;
	}
	return hasaes;
}

/* the test's switch: 0 forces aes.c's own code */
void
aesamd64use(int on)
{
	hasaes = on ? -1 : 0;
	if(on)
		aesamd64ok();
}

/* aes.c gives these 10, 12 or 14 rounds, the only schedules there are (see aesarm64.c) */
static int
roundsok(int rounds)
{
	return rounds == 10 || rounds == 12 || rounds == 14;
}

/* PSHUFB's mask that reverses the bytes of each 32-bit word */
NI static inline __m128i
swapmask(void)
{
	return _mm_set_epi8(12, 13, 14, 15, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3);
}

/* round keys, rounds+1 of them, from aes.c's big-endian words */
NI static void
loadkeys(__m128i *k, const u32int *rk, int rounds)
{
	__m128i m;
	int i;

	m = swapmask();
	for(i = 0; i <= rounds; i++)
		k[i] = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(rk + 4*i)), m);
}

NI static inline __m128i
enc1(__m128i s, const __m128i *k, int rounds)
{
	int i;

	s = _mm_xor_si128(s, k[0]);
	for(i = 1; i < rounds; i++)
		s = _mm_aesenc_si128(s, k[i]);
	return _mm_aesenclast_si128(s, k[rounds]);
}

NI static inline __m128i
dec1(__m128i s, const __m128i *k, int rounds)
{
	int i;

	s = _mm_xor_si128(s, k[0]);
	for(i = 1; i < rounds; i++)
		s = _mm_aesdec_si128(s, k[i]);
	return _mm_aesdeclast_si128(s, k[rounds]);
}

/*
 * SubWord (FIPS 197 5.2).  AESKEYGENASSIST's low word is SubWord of
 * its operand's second word (and the round constant goes into words
 * this does not read).
 */
NI static inline u32int
subword(u32int w)
{
	return (u32int)_mm_cvtsi128_si32(_mm_aeskeygenassist_si128(_mm_set_epi32(0, 0, (int)w, 0), 0));
}

/*
 * The key expansion, as aes.c's keysetup has it: ekey the encryption
 * round keys as big-endian words, dkey those of the equivalent inverse
 * cipher (in reverse order, the inner ones through InvMixColumns).
 * What it branches on is the key's length.
 */
NI void
aesamd64expand(u32int *ekey, u32int *dkey, const uchar *key, int keybytes)
{
	static const uchar rcon[] = {
		0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36
	};
	__m128i k, m;
	u32int t;
	int nk, nr, i;

	if(keybytes != 16 && keybytes != 24 && keybytes != 32)
		return;
	nk = keybytes/4;
	nr = nk + 6;
	for(i = 0; i < nk; i++)
		ekey[i] = (u32int)key[4*i]<<24 | (u32int)key[4*i+1]<<16 | (u32int)key[4*i+2]<<8 | (u32int)key[4*i+3];
	for(i = nk; i < 4*(nr+1); i++){
		t = ekey[i-1];
		if(i % nk == 0)
			t = subword(t<<8 | t>>24) ^ (u32int)rcon[i/nk - 1]<<24;
		else if(nk > 6 && i % nk == 4)
			t = subword(t);
		ekey[i] = ekey[i-nk] ^ t;
	}
	m = swapmask();
	for(i = 0; i <= nr; i++){
		k = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(ekey + 4*i)), m);
		if(i != 0 && i != nr)
			k = _mm_aesimc_si128(k);
		_mm_storeu_si128((__m128i*)(dkey + 4*(nr-i)), _mm_shuffle_epi8(k, m));
	}
	secureZero(&t, sizeof t);
}

NI void
aesamd64encryptblock(const u32int *ekey, int rounds, const uchar pt[16], uchar ct[16])
{
	__m128i k[AESmaxrounds+1];

	if(!roundsok(rounds)){
		memset(ct, 0, 16);
		return;
	}
	loadkeys(k, ekey, rounds);
	_mm_storeu_si128((__m128i*)ct, enc1(_mm_loadu_si128((const __m128i*)pt), k, rounds));
	secureZero(k, sizeof k);
}

/* nblocks of CBC in place, the chaining value in and out of iv */
NI void
aesamd64cbcencrypt(uchar *p, int nblocks, const u32int *ekey, int rounds, uchar *iv)
{
	__m128i k[AESmaxrounds+1], c;

	if(!roundsok(rounds)){
		if(nblocks > 0)
			memset(p, 0, (ulong)nblocks*16);
		return;
	}
	loadkeys(k, ekey, rounds);
	c = _mm_loadu_si128((const __m128i*)iv);
	for(; nblocks > 0; nblocks--, p += 16){
		c = enc1(_mm_xor_si128(_mm_loadu_si128((const __m128i*)p), c), k, rounds);
		_mm_storeu_si128((__m128i*)p, c);
	}
	_mm_storeu_si128((__m128i*)iv, c);
	secureZero(k, sizeof k);
}

/* one round of eight blocks: the instructions overlap, so eight cost little more than one */
#define ROUND8(op, kk)	do{ \
	s0 = op(s0, kk); s1 = op(s1, kk); s2 = op(s2, kk); s3 = op(s3, kk); \
	s4 = op(s4, kk); s5 = op(s5, kk); s6 = op(s6, kk); s7 = op(s7, kk); \
	}while(0)

/* CBC decryption's blocks are independent: eight at a time */
NI void
aesamd64cbcdecrypt(uchar *p, int nblocks, const u32int *dkey, int rounds, uchar *iv)
{
	__m128i k[AESmaxrounds+1], prev, c[8], s0, s1, s2, s3, s4, s5, s6, s7;
	int i;

	if(!roundsok(rounds)){
		if(nblocks > 0)
			memset(p, 0, (ulong)nblocks*16);
		return;
	}
	loadkeys(k, dkey, rounds);
	prev = _mm_loadu_si128((const __m128i*)iv);
	for(; nblocks >= 8; nblocks -= 8, p += 128){
		for(i = 0; i < 8; i++)
			c[i] = _mm_loadu_si128((const __m128i*)(p + 16*i));
		s0 = c[0]; s1 = c[1]; s2 = c[2]; s3 = c[3];
		s4 = c[4]; s5 = c[5]; s6 = c[6]; s7 = c[7];
		ROUND8(_mm_xor_si128, k[0]);
		for(i = 1; i < rounds; i++)
			ROUND8(_mm_aesdec_si128, k[i]);
		ROUND8(_mm_aesdeclast_si128, k[rounds]);
		_mm_storeu_si128((__m128i*)p, _mm_xor_si128(s0, prev));
		_mm_storeu_si128((__m128i*)(p+16), _mm_xor_si128(s1, c[0]));
		_mm_storeu_si128((__m128i*)(p+32), _mm_xor_si128(s2, c[1]));
		_mm_storeu_si128((__m128i*)(p+48), _mm_xor_si128(s3, c[2]));
		_mm_storeu_si128((__m128i*)(p+64), _mm_xor_si128(s4, c[3]));
		_mm_storeu_si128((__m128i*)(p+80), _mm_xor_si128(s5, c[4]));
		_mm_storeu_si128((__m128i*)(p+96), _mm_xor_si128(s6, c[5]));
		_mm_storeu_si128((__m128i*)(p+112), _mm_xor_si128(s7, c[6]));
		prev = c[7];
	}
	for(; nblocks > 0; nblocks--, p += 16){
		c[0] = _mm_loadu_si128((const __m128i*)p);
		_mm_storeu_si128((__m128i*)p, _mm_xor_si128(dec1(c[0], k, rounds), prev));
		prev = c[0];
	}
	_mm_storeu_si128((__m128i*)iv, prev);
	secureZero(k, sizeof k);
}

/*
 * GCM's counter mode: n bytes of p exclusive-ored in place with the
 * encryptions of ctr, ctr+1, ..., the count its last 32 bits, big-endian
 * (SP 800-38D's inc32), as aes.c's loop does.  The block is kept with
 * each word's bytes reversed, so the count is its last word and an
 * addition there wraps as inc32 does; eight counters are in flight at
 * a time, then one.
 */
NI void
aesamd64ctr32(const u32int *ekey, int rounds, const uchar ctr[16], uchar *p, ulong n)
{
	__m128i k[AESmaxrounds+1], m, c, s0, s1, s2, s3, s4, s5, s6, s7;
	uchar blk[16];
	int i;

	if(!roundsok(rounds)){
		memset(p, 0, n);
		return;
	}
	loadkeys(k, ekey, rounds);
	m = swapmask();
	c = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)ctr), m);
#define CTR(j)	_mm_shuffle_epi8(_mm_add_epi32(c, _mm_set_epi32(j, 0, 0, 0)), m)
	for(; n >= 128; n -= 128, p += 128){
		s0 = CTR(0); s1 = CTR(1); s2 = CTR(2); s3 = CTR(3);
		s4 = CTR(4); s5 = CTR(5); s6 = CTR(6); s7 = CTR(7);
		c = _mm_add_epi32(c, _mm_set_epi32(8, 0, 0, 0));
		ROUND8(_mm_xor_si128, k[0]);
		for(i = 1; i < rounds; i++)
			ROUND8(_mm_aesenc_si128, k[i]);
		ROUND8(_mm_aesenclast_si128, k[rounds]);
#define OUT(j, s)	_mm_storeu_si128((__m128i*)(p + 16*j), \
		_mm_xor_si128(_mm_loadu_si128((const __m128i*)(p + 16*j)), s))
		OUT(0, s0); OUT(1, s1); OUT(2, s2); OUT(3, s3);
		OUT(4, s4); OUT(5, s5); OUT(6, s6); OUT(7, s7);
	}
	for(; n >= 16; n -= 16, p += 16){
		s0 = enc1(CTR(0), k, rounds);
		c = _mm_add_epi32(c, _mm_set_epi32(1, 0, 0, 0));
		OUT(0, s0);
	}
	if(n > 0){
		/* the last part-block, through a whole one: n bytes
		 * of p in, a 16-byte exclusive-or, n bytes out */
		s0 = enc1(CTR(0), k, rounds);
		memset(blk, 0, sizeof blk);
		memmove(blk, p, n);
		_mm_storeu_si128((__m128i*)blk, _mm_xor_si128(_mm_loadu_si128((const __m128i*)blk), s0));
		memmove(p, blk, n);
	}
#undef CTR
#undef OUT
	/* the round keys and the last part-block, by stores a compiler keeps */
	secureZero(k, sizeof k);
	secureZero(blk, sizeof blk);
}

#else

int
aesamd64ok(void)
{
	return 0;
}

void
aesamd64use(int on)
{
	USED(on);
}

void
aesamd64expand(u32int *ekey, u32int *dkey, const uchar *key, int keybytes)
{
	USED(ekey); USED(dkey); USED(key); USED(keybytes);
}

void
aesamd64encryptblock(const u32int *ekey, int rounds, const uchar *pt, uchar *ct)
{
	USED(ekey); USED(rounds); USED(pt); USED(ct);
}

void
aesamd64cbcencrypt(uchar *p, int nblocks, const u32int *ekey, int rounds, uchar *iv)
{
	USED(p); USED(nblocks); USED(ekey); USED(rounds); USED(iv);
}

void
aesamd64cbcdecrypt(uchar *p, int nblocks, const u32int *dkey, int rounds, uchar *iv)
{
	USED(p); USED(nblocks); USED(dkey); USED(rounds); USED(iv);
}

void
aesamd64ctr32(const u32int *ekey, int rounds, const uchar ctr[16], uchar *p, ulong n)
{
	USED(ekey); USED(rounds); USED(ctr); USED(p); USED(n);
}

#endif
