#include "os.h"
#include <libsec.h>

/*
 * AES-GCM (Galois/Counter Mode) per NIST SP 800-38D.
 *
 * GHASH, multiplication by H = AES_K(0^128) in GF(2^128), is by PMULL
 * where the processor has it (ghasharm64.c) and otherwise by the C below,
 * which takes the same time whatever the data and the key: it looks up no
 * table.  The 4-bit table it replaces (Shoup's) was indexed by nibbles of
 * the running hash, which a cache shared with an attacker shows.  The
 * counter mode is aesarm64.c's where AES has its instructions, else
 * aesEncryptBlock a block at a time.
 */

/* ghasharm64.c and aesarm64.c: the ARMv8 instructions, where the processor has them */
int	ghasharm64ok(void);
void	ghasharm64(uchar y[16], const uchar h[16], const uchar *p, ulong n);
int	aesarm64ok(void);
void	aesarm64ctr32(const u32int*, int, const uchar*, uchar*, ulong);

static u64int
be64(const uchar *b)
{
	return (u64int)b[0]<<56 | (u64int)b[1]<<48 | (u64int)b[2]<<40 | (u64int)b[3]<<32
	     | (u64int)b[4]<<24 | (u64int)b[5]<<16 | (u64int)b[6]<<8 | (u64int)b[7];
}

static void
put64(uchar *b, u64int v)
{
	b[0] = v>>56; b[1] = v>>48; b[2] = v>>40; b[3] = v>>32;
	b[4] = v>>24; b[5] = v>>16; b[6] = v>>8;  b[7] = v;
}

/*
 * Constant-time GHASH by integer multiplication, after BearSSL's
 * ghash_ctmul64 (Copyright (c) 2016 Thomas Pornin; MIT licence: "Permission
 * is hereby granted, free of charge, to any person obtaining a copy of this
 * software ... The above copyright notice and this permission notice shall
 * be included in all copies or substantial portions of the Software.").
 *
 * bmul64 is a carry-less 64x64 multiply, low 64 bits: each operand is
 * split into four interleaved bit sets (every fourth bit), so the carries
 * of the ordinary multiplications land in bits that are masked away.  The
 * high halves come from the same multiply of the bit-reversed operands.
 * A 64-bit MUL takes the same time whatever its operands on the Cortex-A53,
 * A72 and A76 these run on.
 */
static u64int
bmul64(u64int x, u64int y)
{
	u64int x0, x1, x2, x3, y0, y1, y2, y3, z0, z1, z2, z3;

	x0 = x & 0x1111111111111111ULL;
	x1 = x & 0x2222222222222222ULL;
	x2 = x & 0x4444444444444444ULL;
	x3 = x & 0x8888888888888888ULL;
	y0 = y & 0x1111111111111111ULL;
	y1 = y & 0x2222222222222222ULL;
	y2 = y & 0x4444444444444444ULL;
	y3 = y & 0x8888888888888888ULL;
	z0 = (x0 * y0) ^ (x1 * y3) ^ (x2 * y2) ^ (x3 * y1);
	z1 = (x0 * y1) ^ (x1 * y0) ^ (x2 * y3) ^ (x3 * y2);
	z2 = (x0 * y2) ^ (x1 * y1) ^ (x2 * y0) ^ (x3 * y3);
	z3 = (x0 * y3) ^ (x1 * y2) ^ (x2 * y1) ^ (x3 * y0);
	z0 &= 0x1111111111111111ULL;
	z1 &= 0x2222222222222222ULL;
	z2 &= 0x4444444444444444ULL;
	z3 &= 0x8888888888888888ULL;
	return z0 | z1 | z2 | z3;
}

static u64int
rev64(u64int x)
{
#define RMS(m, s) x = ((x & (u64int)(m)) << (s)) | ((x >> (s)) & (u64int)(m))
	RMS(0x5555555555555555ULL, 1);
	RMS(0x3333333333333333ULL, 2);
	RMS(0x0F0F0F0F0F0F0F0FULL, 4);
	RMS(0x00FF00FF00FF00FFULL, 8);
	RMS(0x0000FFFF0000FFFFULL, 16);
#undef RMS
	return (x << 32) | (x >> 32);
}

/* Y = (Y ^ X) * H for each 16-byte X of p; n a multiple of 16 */
static void
ghashct(uchar y[16], const uchar h[16], const uchar *p, ulong n)
{
	u64int y0, y1, h0, h1, h2, h0r, h1r, h2r;
	u64int y0r, y1r, y2, y2r, z0, z1, z2, z0h, z1h, z2h, v0, v1, v2, v3;

	y1 = be64(y);
	y0 = be64(y + 8);
	h1 = be64(h);
	h0 = be64(h + 8);
	h0r = rev64(h0);
	h1r = rev64(h1);
	h2 = h0 ^ h1;
	h2r = h0r ^ h1r;
	for(; n >= 16; n -= 16, p += 16){
		y1 ^= be64(p);
		y0 ^= be64(p + 8);
		y0r = rev64(y0);
		y1r = rev64(y1);
		y2 = y0 ^ y1;
		y2r = y0r ^ y1r;

		/* Karatsuba: low halves, and the high halves bit-reversed */
		z0 = bmul64(y0, h0);
		z1 = bmul64(y1, h1);
		z2 = bmul64(y2, h2);
		z0h = bmul64(y0r, h0r);
		z1h = bmul64(y1r, h1r);
		z2h = bmul64(y2r, h2r);
		z2 ^= z0 ^ z1;
		z2h ^= z0h ^ z1h;
		z0h = rev64(z0h) >> 1;
		z1h = rev64(z1h) >> 1;
		z2h = rev64(z2h) >> 1;

		/* the 256-bit product, shifted one place (GHASH's bits are reflected) */
		v0 = z0;
		v1 = z0h ^ z2;
		v2 = z1 ^ z2h;
		v3 = z1h;
		v3 = (v3 << 1) | (v2 >> 63);
		v2 = (v2 << 1) | (v1 >> 63);
		v1 = (v1 << 1) | (v0 >> 63);
		v0 = (v0 << 1);

		/* reduced by x^128 + x^7 + x^2 + x + 1 */
		v2 ^= v0 ^ (v0 >> 1) ^ (v0 >> 2) ^ (v0 >> 7);
		v1 ^= (v0 << 63) ^ (v0 << 62) ^ (v0 << 57);
		v3 ^= v1 ^ (v1 >> 1) ^ (v1 >> 2) ^ (v1 >> 7);
		v2 ^= (v1 << 63) ^ (v1 << 62) ^ (v1 << 57);
		y0 = v2;
		y1 = v3;
	}
	put64(y, y1);
	put64(y + 8, y0);
}

/* the test's switch: 0 forces the C (ghasharm64use is its own) */
static int ghashc;

void
aesgcmuseC(int on)
{
	ghashc = on;
}

/* GHASH over data, with zero-padding to a block's end */
static void
ghash_update(AESGCMstate *s, uchar y[16], uchar *data, ulong len)
{
	uchar block[16];
	ulong whole;

	whole = len & ~(ulong)15;
	if(whole > 0){
		if(!ghashc && ghasharm64ok())
			ghasharm64(y, s->hkey, data, whole);
		else
			ghashct(y, s->hkey, data, whole);
	}
	if(len > whole){
		memset(block, 0, 16);
		memmove(block, data + whole, len - whole);
		if(!ghashc && ghasharm64ok())
			ghasharm64(y, s->hkey, block, 16);
		else
			ghashct(y, s->hkey, block, 16);
		secureZero(block, sizeof(block));
	}
}

/* the length block: [len(AAD) in bits || len(C) in bits] */
static void
ghash_lengths(AESGCMstate *s, uchar y[16], ulong naad, ulong ndat)
{
	uchar lenblock[16];

	put64(lenblock, (u64int)naad*8);
	put64(lenblock+8, (u64int)ndat*8);
	ghash_update(s, y, lenblock, 16);
}

/* increment the rightmost 32 bits of J (counter) */
static void
gcm_inc32(uchar J[16])
{
	int i;
	for(i = 15; i >= 12; i--)
		if(++J[i] != 0)
			break;
}

/* dat ^= AES_K(J0+1), AES_K(J0+2), ...: counter mode from J0's successor */
static void
gcm_ctr(AESGCMstate *s, uchar *dat, ulong ndat)
{
	uchar J[AESbsize], block[AESbsize];
	ulong i, k, n;

	memmove(J, s->J0, AESbsize);
	gcm_inc32(J);
	if(!ghashc && aesarm64ok()){
		aesarm64ctr32(s->a.ekey, s->a.rounds, J, dat, ndat);
		secureZero(J, sizeof(J));
		return;
	}
	for(i = 0; i < ndat; i += AESbsize){
		aesEncryptBlock(&s->a, J, block);
		gcm_inc32(J);
		n = ndat - i;
		if(n > AESbsize)
			n = AESbsize;
		for(k = 0; k < n; k++)
			dat[i+k] ^= block[k];
	}
	secureZero(J, sizeof(J));
	secureZero(block, sizeof(block));
}

void
setupAESGCMstate(AESGCMstate *s, uchar *key, int keylen, uchar *iv, int ivlen)
{
	uchar zero[AESbsize];

	memset(s, 0, sizeof(*s));
	setupAESstate(&s->a, key, keylen, nil);

	/* H = AES_K(0^128) */
	memset(zero, 0, AESbsize);
	aesEncryptBlock(&s->a, zero, s->hkey);

	/* compute J0 (initial counter) */
	if(ivlen == 12){
		/* common case: J0 = IV || 0^31 || 1 */
		memmove(s->J0, iv, 12);
		s->J0[12] = 0;
		s->J0[13] = 0;
		s->J0[14] = 0;
		s->J0[15] = 1;
	} else {
		/* general case: J0 = GHASH_H(IV || pad || len64) */
		memset(s->J0, 0, AESbsize);
		ghash_update(s, s->J0, iv, ivlen);
		ghash_lengths(s, s->J0, 0, ivlen);
	}
}

/*
 * Maximum plaintext/ciphertext length for AES-GCM per NIST SP 800-38D:
 * 2^32 - 2 blocks = (2^36 - 32) bytes.
 * Beyond this the 32-bit counter wraps, causing keystream reuse.
 */
#define AESGCM_MAXLEN	(((u64int)1 << 36) - 32)

/* the tag: GHASH(A, C) ^ AES_K(J0) */
static void
gcm_tag(AESGCMstate *s, uchar *aad, ulong naad, uchar *dat, ulong ndat, uchar tag[16])
{
	uchar y[16], block[AESbsize];
	int i;

	memset(y, 0, 16);
	ghash_update(s, y, aad, naad);
	ghash_update(s, y, dat, ndat);
	ghash_lengths(s, y, naad, ndat);
	aesEncryptBlock(&s->a, s->J0, block);
	for(i = 0; i < 16; i++)
		tag[i] = y[i] ^ block[i];
	secureZero(y, sizeof(y));
	secureZero(block, sizeof(block));
}

/*
 * AES-GCM encrypt.
 * dat is plaintext on input, ciphertext on output.
 * tag receives the 16-byte authentication tag.
 * Returns 0 on success, -1 if input exceeds GCM limits.
 */
int
aesgcm_encrypt(uchar *dat, ulong ndat, uchar *aad, ulong naad,
	uchar tag[16], AESGCMstate *s)
{
	if((u64int)ndat > AESGCM_MAXLEN)
		return -1;
	gcm_ctr(s, dat, ndat);
	gcm_tag(s, aad, naad, dat, ndat, tag);
	return 0;
}

/*
 * AES-GCM decrypt.
 * dat is ciphertext on input, plaintext on output.
 * tag is the 16-byte authentication tag to verify.
 * Returns 0 on success, -1 on authentication failure or input overflow;
 * on failure dat is left as it was.
 */
int
aesgcm_decrypt(uchar *dat, ulong ndat, uchar *aad, ulong naad,
	uchar tag[16], AESGCMstate *s)
{
	uchar computed[16];
	int i, diff;

	if((u64int)ndat > AESGCM_MAXLEN)
		return -1;
	gcm_tag(s, aad, naad, dat, ndat, computed);

	/* constant-time comparison */
	diff = 0;
	for(i = 0; i < 16; i++)
		diff |= computed[i] ^ tag[i];
	secureZero(computed, sizeof(computed));
	if(diff != 0)
		return -1;

	gcm_ctr(s, dat, ndat);
	return 0;
}
