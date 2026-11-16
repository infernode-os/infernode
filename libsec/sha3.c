/*
 * SHA-3 / SHAKE (FIPS 202)
 *
 * Keccak-f[1600] permutation with SHA3-256, SHA3-512,
 * SHAKE-128, and SHAKE-256 extendable output functions.
 *
 * Required by ML-KEM (FIPS 203) and ML-DSA (FIPS 204).
 *
 * Reference: NIST FIPS 202 "SHA-3 Standard: Permutation-Based
 * Hash and Extendable-Output Functions" (August 2015).
 */
#include "os.h"
#include <libsec.h>

/*
 * Keccak-f[1600] round constants
 */
static const u64int RC[24] = {
	0x0000000000000001ULL, 0x0000000000008082ULL,
	0x800000000000808aULL, 0x8000000080008000ULL,
	0x000000000000808bULL, 0x0000000080000001ULL,
	0x8000000080008081ULL, 0x8000000000008009ULL,
	0x000000000000008aULL, 0x0000000000000088ULL,
	0x0000000080008009ULL, 0x000000008000000aULL,
	0x000000008000808bULL, 0x800000000000008bULL,
	0x8000000000008089ULL, 0x8000000000008003ULL,
	0x8000000000008002ULL, 0x8000000000000080ULL,
	0x000000000000800aULL, 0x800000008000000aULL,
	0x8000000080008081ULL, 0x8000000000008080ULL,
	0x0000000080000001ULL, 0x8000000080008008ULL,
};

/*
 * The lanes are read and written as bytes where they lie: a
 * little-endian host, as every one this is built for is.
 */
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#error "sha3.c: the Keccak state is read as bytes in little-endian order"
#endif

#define ROTL64(x, n) (((x) << (n)) | ((x) >> (64-(n))))

/*
 * theta for column x: each of its lanes takes the parity of the column
 * before and, turned one bit, of the column after
 */
#define THETA(x, before, after) \
	t = before ^ ROTL64(after, 1); \
	st[x] ^= t; st[x+5] ^= t; st[x+10] ^= t; st[x+15] ^= t; st[x+20] ^= t

/*
 * rho and pi move every lane but the first to another place, turned by
 * its own amount; the places make one cycle of 24, taken a step at a
 * time: lane j takes what the lane before it in the cycle held
 */
#define RHOPI(j, n) \
	u = st[j]; st[j] = ROTL64(t, n); t = u

/* chi for the row of five lanes at j */
#define CHI(j) \
	t = st[j]; u = st[j+1]; \
	st[j] ^= ~u & st[j+2]; \
	st[j+1] ^= ~st[j+2] & st[j+3]; \
	st[j+2] ^= ~st[j+3] & st[j+4]; \
	st[j+3] ^= ~st[j+4] & t; \
	st[j+4] ^= ~t & u

/*
 * Keccak-f[1600] permutation: 24 rounds of theta/rho/pi/chi/iota.
 * Operates on 5x5 array of 64-bit lanes (200 bytes = 1600 bits).
 * Constant-time by construction: exclusive-ors, ands, complements and
 * rotations by fixed amounts, with no branch or index made from the
 * state.
 *
 * Each round is written out lane by lane.  It was loops over the
 * columns and rows with the lane's index taken mod 5 and the rotation
 * and the place read from tables, which a compiler asked for little
 * (the emulator's -O) left as written: two microseconds a permutation,
 * and an SLH-DSA signature, three million of them, 9 s.  Written out it
 * is four times as fast at the same flags.  The state is worked on
 * where it is, with seven lanes of temporaries, so that no second copy
 * of it is left on the stack.
 */
static void
keccakf(u64int st[25])
{
	u64int t, u, c0, c1, c2, c3, c4;
	int r;

	for(r = 0; r < 24; r++){
		/* theta */
		c0 = st[0] ^ st[5] ^ st[10] ^ st[15] ^ st[20];
		c1 = st[1] ^ st[6] ^ st[11] ^ st[16] ^ st[21];
		c2 = st[2] ^ st[7] ^ st[12] ^ st[17] ^ st[22];
		c3 = st[3] ^ st[8] ^ st[13] ^ st[18] ^ st[23];
		c4 = st[4] ^ st[9] ^ st[14] ^ st[19] ^ st[24];
		THETA(0, c4, c1);
		THETA(1, c0, c2);
		THETA(2, c1, c3);
		THETA(3, c2, c4);
		THETA(4, c3, c0);

		/* rho and pi */
		t = st[1];
		RHOPI(10, 1);
		RHOPI(7, 3);
		RHOPI(11, 6);
		RHOPI(17, 10);
		RHOPI(18, 15);
		RHOPI(3, 21);
		RHOPI(5, 28);
		RHOPI(16, 36);
		RHOPI(8, 45);
		RHOPI(21, 55);
		RHOPI(24, 2);
		RHOPI(4, 14);
		RHOPI(15, 27);
		RHOPI(23, 41);
		RHOPI(19, 56);
		RHOPI(13, 8);
		RHOPI(12, 25);
		RHOPI(2, 43);
		RHOPI(20, 62);
		RHOPI(14, 18);
		RHOPI(22, 39);
		RHOPI(9, 61);
		RHOPI(6, 20);
		RHOPI(1, 44);

		/* chi */
		CHI(0);
		CHI(5);
		CHI(10);
		CHI(15);
		CHI(20);

		/* iota */
		st[0] ^= RC[r];
	}
}

/*
 * A sponge absorbs, is finalized (padded) once, and is then squeezed.
 * The phase is kept so that a call out of turn does something that can
 * be stated: a squeeze before the padding pads first, and bytes given
 * to absorb after the padding are not taken (they were exclusive-ored
 * into the state at whatever place squeezing had reached, and a squeeze
 * with no padding gave the state of the unpadded input).
 */
enum
{
	Absorbing,
	Squeezing,
};

/*
 * Initialize SHA3/SHAKE state with given rate (in bytes).
 * rate = 200 - 2*security_bytes
 *   SHA3-256: rate = 136 (200 - 2*32)
 *   SHA3-512: rate = 72  (200 - 2*64)
 *   SHAKE128: rate = 168 (200 - 2*16)
 *   SHAKE256: rate = 136 (200 - 2*32)
 */
static void
sha3_init(SHA3state *s, int rate, int mdlen)
{
	memset(s, 0, sizeof(*s));
	s->rate = rate;
	s->mdlen = mdlen;
	s->phase = Absorbing;
}

/*
 * Absorb data into sponge state: what fits in the block at a time.
 */
static void
sha3_update(SHA3state *s, const uchar *in, ulong inlen)
{
	uchar *sb;
	ulong j, n, i;

	if(s->phase != Absorbing)
		return;
	sb = (uchar*)s->a;
	j = s->pt;
	while(inlen > 0){
		n = (ulong)s->rate - j;
		if(n > inlen)
			n = inlen;
		for(i = 0; i < n; i++)
			sb[j+i] ^= in[i];
		in += n;
		inlen -= n;
		j += n;
		if(j >= (ulong)s->rate){
			keccakf(s->a);
			j = 0;
		}
	}
	s->pt = j;
}

/*
 * Pad (FIPS 202 section 5.1, with the function's suffix: 0x06 for
 * SHA-3, 0x1F for SHAKE) and permute: the first block of output.
 */
static void
sha3_pad(SHA3state *s, int suffix)
{
	uchar *sb;

	if(s->phase != Absorbing)
		return;
	sb = (uchar*)s->a;
	sb[s->pt] ^= suffix;
	sb[s->rate - 1] ^= 0x80;
	keccakf(s->a);
	s->pt = 0;
	s->phase = Squeezing;
}

/*
 * Finalize SHA3 hash (domain separator 0x06 for SHA3).
 */
static void
sha3_final(uchar *out, SHA3state *s)
{
	uchar *sb;
	int i;

	sha3_pad(s, 0x06);
	sb = (uchar*)s->a;
	for(i = 0; i < s->mdlen; i++)
		out[i] = sb[i];
}

/*
 * Finalize SHAKE XOF (domain separator 0x1F for SHAKE).
 * After this, call sha3_squeeze() to extract output.
 */
static void
shake_finalize(SHA3state *s)
{
	sha3_pad(s, 0x1F);
}

/*
 * Squeeze output from SHAKE XOF.
 * May be called multiple times after shake_finalize().
 */
static void
sha3_squeeze_internal(SHA3state *s, uchar *out, ulong outlen)
{
	uchar *sb;
	ulong j, n;

	if(s->phase != Squeezing)
		shake_finalize(s);
	sb = (uchar*)s->a;
	j = s->pt;
	while(outlen > 0){
		if(j >= (ulong)s->rate){
			keccakf(s->a);
			j = 0;
		}
		n = (ulong)s->rate - j;
		if(n > outlen)
			n = outlen;
		memmove(out, sb+j, n);
		out += n;
		outlen -= n;
		j += n;
	}
	s->pt = j;
}

/*
 * Public API: SHA3-256
 */
void
sha3_256(const uchar *in, ulong inlen, uchar out[32])
{
	SHA3state s;

	sha3_init(&s, 136, 32);
	sha3_update(&s, in, inlen);
	sha3_final(out, &s);
	/* Keccak-f can be run backwards: the state of a short input is the input */
	secureZero(&s, sizeof s);
}

/*
 * Public API: SHA3-512
 */
void
sha3_512(const uchar *in, ulong inlen, uchar out[64])
{
	SHA3state s;

	sha3_init(&s, 72, 64);
	sha3_update(&s, in, inlen);
	sha3_final(out, &s);
	secureZero(&s, sizeof s);
}

/*
 * Public API: SHAKE-128
 */
void
shake128_init(SHA3state *s)
{
	sha3_init(s, 168, 0);
}

void
shake128_absorb(SHA3state *s, const uchar *in, ulong inlen)
{
	sha3_update(s, in, inlen);
}

void
shake128_finalize(SHA3state *s)
{
	shake_finalize(s);
}

void
shake128_squeeze(SHA3state *s, uchar *out, ulong outlen)
{
	sha3_squeeze_internal(s, out, outlen);
}

/*
 * Public API: SHAKE-256
 */
void
shake256_init(SHA3state *s)
{
	sha3_init(s, 136, 0);
}

void
shake256_absorb(SHA3state *s, const uchar *in, ulong inlen)
{
	sha3_update(s, in, inlen);
}

void
shake256_finalize(SHA3state *s)
{
	shake_finalize(s);
}

void
shake256_squeeze(SHA3state *s, uchar *out, ulong outlen)
{
	sha3_squeeze_internal(s, out, outlen);
}

/*
 * Convenience: one-shot SHAKE-128
 */
void
shake128(const uchar *in, ulong inlen, uchar *out, ulong outlen)
{
	SHA3state s;

	shake128_init(&s);
	shake128_absorb(&s, in, inlen);
	shake128_finalize(&s);
	shake128_squeeze(&s, out, outlen);
	secureZero(&s, sizeof s);	/* see sha3_256 */
}

/*
 * Convenience: one-shot SHAKE-256
 */
void
shake256(const uchar *in, ulong inlen, uchar *out, ulong outlen)
{
	SHA3state s;

	shake256_init(&s);
	shake256_absorb(&s, in, inlen);
	shake256_finalize(&s);
	shake256_squeeze(&s, out, outlen);
	secureZero(&s, sizeof s);	/* see sha3_256 */
}
