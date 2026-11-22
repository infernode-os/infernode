/*
 * AES (FIPS 197) in constant time, for processors with no AES
 * instructions: no table is indexed by, and no branch taken on, a byte
 * of the key or the data.
 *
 * This file was rijndael-alg-fst.c: four 1K tables for each direction,
 * indexed by the state's bytes, which are the key's exclusive-or with
 * the data.  Which cache lines such a lookup touches is visible to
 * other programs on the same processor (Bernstein 2005, Osvik, Shamir
 * and Tromer 2006), and devssl, TLS and the random number generator
 * all ran on it wherever the processor had no AES instructions: amd64
 * as built here, the Raspberry Pi 3 and 4, RISC-V.
 *
 * Here the cipher is bitsliced: the state of up to four blocks is held
 * as eight 64-bit words, word b holding bit b of each of the 64 bytes,
 * and every step of a round is a fixed sequence of ANDs, ORs,
 * exclusive-ors and shifts by constants on those words.  SubBytes is
 * the circuit of Boyar and Peralta ("A small depth-16 circuit for the
 * AES S-box", 2012: 113 gates, 32 of them ANDs), and its inverse is the
 * same circuit between two applications of the inverse affine map;
 * ShiftRows moves bits within a word; MixColumns is word rotations
 * and exclusive-ors.  The key schedule's SubWord is the same circuit.
 * The design is that of Käsper and Schwabe's and of BearSSL's
 * bitsliced AES; the layout and code are this file's own.
 *
 * Where the bits are: the byte in row r and column c (FIPS 197's
 * s[r,c], byte 4c+r of a block) of block k is at bit 16r + 4c + k of
 * each word.  A row is then 16 adjacent bits, so ShiftRows rotates
 * each 16-bit group and "the row below" is a rotation by 16.
 *
 * Four blocks go through at the price of one, so the modes that have
 * blocks to spare take four at a time: CBC decryption and GCM's
 * counter mode.  CBC encryption cannot (each block needs the one
 * before), so it pays for four and uses one: it is the slow case.
 *
 * Where the processor has AES instructions (aesarm64.c, aesamd64.c)
 * they are used instead, from the same key schedule.
 */
#include "os.h"
#include <libsec.h>

typedef u64int	u64;
typedef u32int	u32;

/* aesarm64.c: the ARMv8 instructions, where the processor has them */
int	aesarm64ok(void);
void	aesarm64encryptblock(const u32int*, int, const uchar*, uchar*);
void	aesarm64cbcencrypt(uchar*, int, const u32int*, int, uchar*);
void	aesarm64cbcdecrypt(uchar*, int, const u32int*, int, uchar*);
void	aesarm64ctr32(const u32int*, int, const uchar*, uchar*, ulong);

/* aesamd64.c: x86-64's, where cpuid says the processor has them */
int	aesamd64ok(void);
void	aesamd64expand(u32int*, u32int*, const uchar*, int);
void	aesamd64encryptblock(const u32int*, int, const uchar*, uchar*);
void	aesamd64cbcencrypt(uchar*, int, const u32int*, int, uchar*);
void	aesamd64cbcdecrypt(uchar*, int, const u32int*, int, uchar*);
void	aesamd64ctr32(const u32int*, int, const uchar*, uchar*, ulong);

/*
 * A key is 16, 24 or 32 bytes (FIPS 197).  Any other length was taken:
 * the schedule was not made, rounds was 0, and what came out was the
 * block exclusive-ored with the key's first 16 bytes and no more (a
 * key of no bytes: with nothing), which decrypts again and looks like
 * a cipher; a key longer than 32 bytes was cut to them.  The
 * instructions' code (aesarm64.c) indexed its round keys with rounds-1
 * and read the 16 bytes of the stack below them, which the result gave
 * back.  The state of such a key is left unset, and what is asked of an
 * unset state gives zeros, not the data and not a cipher of it.
 */
enum {
	AESset=	0xcafebabe,
};

static int
aesok(AESstate *s)
{
	return s->setup == AESset && (s->rounds == 10 || s->rounds == 12 || s->rounds == 14);
}

/*
 * SubBytes on all 64 bytes at once.  q[7] is each byte's high bit,
 * which the circuit calls x0.
 */
static void
subbytes(u64 *q)
{
	u64 x0, x1, x2, x3, x4, x5, x6, x7;
	u64 y1, y2, y3, y4, y5, y6, y7, y8, y9, y10, y11;
	u64 y12, y13, y14, y15, y16, y17, y18, y19, y20, y21;
	u64 z0, z1, z2, z3, z4, z5, z6, z7, z8, z9, z10;
	u64 z11, z12, z13, z14, z15, z16, z17;
	u64 t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10;
	u64 t11, t12, t13, t14, t15, t16, t17, t18, t19, t20;
	u64 t21, t22, t23, t24, t25, t26, t27, t28, t29, t30;
	u64 t31, t32, t33, t34, t35, t36, t37, t38, t39, t40;
	u64 t41, t42, t43, t44, t45, t46, t47, t48, t49, t50;
	u64 t51, t52, t53, t54, t55, t56, t57, t58, t59, t60;
	u64 t61, t62, t63, t64, t65, t66, t67;
	u64 s0, s1, s2, s3, s4, s5, s6, s7;

	x0 = q[7]; x1 = q[6]; x2 = q[5]; x3 = q[4];
	x4 = q[3]; x5 = q[2]; x6 = q[1]; x7 = q[0];

	/* the linear map into the inversion's basis */
	y14 = x3 ^ x5;
	y13 = x0 ^ x6;
	y9 = x0 ^ x3;
	y8 = x0 ^ x5;
	t0 = x1 ^ x2;
	y1 = t0 ^ x7;
	y4 = y1 ^ x3;
	y12 = y13 ^ y14;
	y2 = y1 ^ x0;
	y5 = y1 ^ x6;
	y3 = y5 ^ y8;
	t1 = x4 ^ y12;
	y15 = t1 ^ x5;
	y20 = t1 ^ x1;
	y6 = y15 ^ x7;
	y10 = y15 ^ t0;
	y11 = y20 ^ y9;
	y7 = x7 ^ y11;
	y17 = y10 ^ y11;
	y19 = y10 ^ y8;
	y16 = t0 ^ y11;
	y21 = y13 ^ y16;
	y18 = x0 ^ y16;

	/* the inversion in GF(2^8), by its tower of subfields */
	t2 = y12 & y15;
	t3 = y3 & y6;
	t4 = t3 ^ t2;
	t5 = y4 & x7;
	t6 = t5 ^ t2;
	t7 = y13 & y16;
	t8 = y5 & y1;
	t9 = t8 ^ t7;
	t10 = y2 & y7;
	t11 = t10 ^ t7;
	t12 = y9 & y11;
	t13 = y14 & y17;
	t14 = t13 ^ t12;
	t15 = y8 & y10;
	t16 = t15 ^ t12;
	t17 = t4 ^ t14;
	t18 = t6 ^ t16;
	t19 = t9 ^ t14;
	t20 = t11 ^ t16;
	t21 = t17 ^ y20;
	t22 = t18 ^ y19;
	t23 = t19 ^ y21;
	t24 = t20 ^ y18;

	t25 = t21 ^ t22;
	t26 = t21 & t23;
	t27 = t24 ^ t26;
	t28 = t25 & t27;
	t29 = t28 ^ t22;
	t30 = t23 ^ t24;
	t31 = t22 ^ t26;
	t32 = t31 & t30;
	t33 = t32 ^ t24;
	t34 = t23 ^ t33;
	t35 = t27 ^ t33;
	t36 = t24 & t35;
	t37 = t36 ^ t34;
	t38 = t27 ^ t36;
	t39 = t29 & t38;
	t40 = t25 ^ t39;

	t41 = t40 ^ t37;
	t42 = t29 ^ t33;
	t43 = t29 ^ t40;
	t44 = t33 ^ t37;
	t45 = t42 ^ t41;
	z0 = t44 & y15;
	z1 = t37 & y6;
	z2 = t33 & x7;
	z3 = t43 & y16;
	z4 = t40 & y1;
	z5 = t29 & y7;
	z6 = t42 & y11;
	z7 = t45 & y17;
	z8 = t41 & y10;
	z9 = t44 & y12;
	z10 = t37 & y3;
	z11 = t33 & y4;
	z12 = t43 & y13;
	z13 = t40 & y5;
	z14 = t29 & y2;
	z15 = t42 & y9;
	z16 = t45 & y14;
	z17 = t41 & y8;

	/* the linear map back, with the affine map and its constant 63 */
	t46 = z15 ^ z16;
	t47 = z10 ^ z11;
	t48 = z5 ^ z13;
	t49 = z9 ^ z10;
	t50 = z2 ^ z12;
	t51 = z2 ^ z5;
	t52 = z7 ^ z8;
	t53 = z0 ^ z3;
	t54 = z6 ^ z7;
	t55 = z16 ^ z17;
	t56 = z12 ^ t48;
	t57 = t50 ^ t53;
	t58 = z4 ^ t46;
	t59 = z3 ^ t54;
	t60 = t46 ^ t57;
	t61 = z14 ^ t57;
	t62 = t52 ^ t58;
	t63 = t49 ^ t58;
	t64 = z4 ^ t59;
	t65 = t61 ^ t62;
	t66 = z1 ^ t63;
	s0 = t59 ^ t63;
	s6 = t56 ^ ~t62;
	s7 = t48 ^ ~t60;
	t67 = t64 ^ t65;
	s3 = t53 ^ t66;
	s4 = t51 ^ t66;
	s5 = t47 ^ t65;
	s1 = t64 ^ ~s3;
	s2 = t55 ^ ~t67;

	q[7] = s0; q[6] = s1; q[5] = s2; q[4] = s3;
	q[3] = s4; q[2] = s5; q[1] = s6; q[0] = s7;
}

/*
 * The inverse of the affine map, with its constant: bit i of the
 * result is bits i+2, i+5 and i+7 of the byte (mod 8), exclusive-ored
 * with 05 (FIPS 197 5.3.2).
 */
static void
invaffine(u64 *q)
{
	u64 q0, q1, q2, q3, q4, q5, q6, q7;

	q0 = q[0]; q1 = q[1]; q2 = q[2]; q3 = q[3];
	q4 = q[4]; q5 = q[5]; q6 = q[6]; q7 = q[7];
	q[0] = ~(q2 ^ q5 ^ q7);
	q[1] = q3 ^ q6 ^ q0;
	q[2] = ~(q4 ^ q7 ^ q1);
	q[3] = q5 ^ q0 ^ q2;
	q[4] = q6 ^ q1 ^ q3;
	q[5] = q7 ^ q2 ^ q4;
	q[6] = q0 ^ q3 ^ q5;
	q[7] = q1 ^ q4 ^ q6;
}

/*
 * InvSubBytes.  S(x) is A(1/x) + 63 and its inverse 1/(B(y)), where B
 * is the inverse of A with the constant: so 1/z is B(S(z)), and the
 * inverse S-box is B(S(B(y))): one circuit serves both directions.
 */
static void
invsubbytes(u64 *q)
{
	invaffine(q);
	subbytes(q);
	invaffine(q);
}

/* row r's 16 bits rotated by r columns: the byte from column c+r comes to column c */
static void
shiftrows(u64 *q)
{
	u64 x;
	int i;

	for(i = 0; i < 8; i++){
		x = q[i];
		q[i] = (x & 0x000000000000FFFFULL)
			| ((x & 0x00000000FFF00000ULL) >> 4)
			| ((x & 0x00000000000F0000ULL) << 12)
			| ((x & 0x0000FF0000000000ULL) >> 8)
			| ((x & 0x000000FF00000000ULL) << 8)
			| ((x & 0xF000000000000000ULL) >> 12)
			| ((x & 0x0FFF000000000000ULL) << 4);
	}
}

static void
invshiftrows(u64 *q)
{
	u64 x;
	int i;

	for(i = 0; i < 8; i++){
		x = q[i];
		q[i] = (x & 0x000000000000FFFFULL)
			| ((x & 0x000000000FFF0000ULL) << 4)
			| ((x & 0x00000000F0000000ULL) >> 12)
			| ((x & 0x0000FF0000000000ULL) >> 8)
			| ((x & 0x000000FF00000000ULL) << 8)
			| ((x & 0x000F000000000000ULL) << 12)
			| ((x & 0xFFF0000000000000ULL) >> 4);
	}
}

#define ROWUP(x)	(((x) >> 16) | ((x) << 48))	/* each row takes the one below it */
#define ROW2(x)		(((x) >> 32) | ((x) << 32))

/*
 * MixColumns: each byte a becomes 2a + 3b + c + d, with b, c and d the
 * bytes below it in its column: 2(a+b) + b + (c+d).  Doubling in
 * GF(2^8) moves each bit up one and folds the top bit into bits 0, 1,
 * 3 and 4 (the polynomial 11B).
 */
static void
mixcolumns(u64 *q)
{
	u64 a[8], b[8], t[8];
	int i;

	for(i = 0; i < 8; i++){
		a[i] = q[i];
		b[i] = ROWUP(a[i]);
		t[i] = a[i] ^ b[i];
	}
	q[0] = t[7] ^ b[0] ^ ROW2(t[0]);
	q[1] = t[0] ^ t[7] ^ b[1] ^ ROW2(t[1]);
	q[2] = t[1] ^ b[2] ^ ROW2(t[2]);
	q[3] = t[2] ^ t[7] ^ b[3] ^ ROW2(t[3]);
	q[4] = t[3] ^ t[7] ^ b[4] ^ ROW2(t[4]);
	q[5] = t[4] ^ b[5] ^ ROW2(t[5]);
	q[6] = t[5] ^ b[6] ^ ROW2(t[6]);
	q[7] = t[6] ^ b[7] ^ ROW2(t[7]);
}

/*
 * InvMixColumns is MixColumns after each byte a has had 4(a+c) added
 * to it, c the byte two below: the matrix (0E 0B 0D 09) is (02 03 01
 * 01) times (05 00 04 00).
 */
static void
invmixcolumns(u64 *q)
{
	u64 u[8];
	int i;

	for(i = 0; i < 8; i++)
		u[i] = q[i] ^ ROW2(q[i]);
	/* 4u: two doublings */
	q[0] ^= u[6];
	q[1] ^= u[6] ^ u[7];
	q[2] ^= u[0] ^ u[7];
	q[3] ^= u[1] ^ u[6];
	q[4] ^= u[2] ^ u[6] ^ u[7];
	q[5] ^= u[3] ^ u[7];
	q[6] ^= u[4];
	q[7] ^= u[5];
	mixcolumns(q);
}

static void
addroundkey(u64 *q, const u64 *rk)
{
	int i;

	for(i = 0; i < 8; i++)
		q[i] ^= rk[i];
}

/*
 * Words to bit planes and back.  Bit 8m+b of x[j] is bit b of the
 * byte at position 8m+j; exchanging bit b of word j with bit j of
 * word b, in every byte of the words, makes x[b] hold bit b of every
 * byte: the transpose of an 8 by 8 matrix of bits, a level at a time.
 * It is its own inverse.
 */
#define SWAPBITS(a, b, m, s) do{ \
		u64 t_ = (((a) >> (s)) ^ (b)) & (m); \
		(b) ^= t_; \
		(a) ^= t_ << (s); \
	}while(0)

static void
transpose(u64 *x)
{
	SWAPBITS(x[0], x[1], 0x5555555555555555ULL, 1);
	SWAPBITS(x[2], x[3], 0x5555555555555555ULL, 1);
	SWAPBITS(x[4], x[5], 0x5555555555555555ULL, 1);
	SWAPBITS(x[6], x[7], 0x5555555555555555ULL, 1);
	SWAPBITS(x[0], x[2], 0x3333333333333333ULL, 2);
	SWAPBITS(x[1], x[3], 0x3333333333333333ULL, 2);
	SWAPBITS(x[4], x[6], 0x3333333333333333ULL, 2);
	SWAPBITS(x[5], x[7], 0x3333333333333333ULL, 2);
	SWAPBITS(x[0], x[4], 0x0F0F0F0F0F0F0F0FULL, 4);
	SWAPBITS(x[1], x[5], 0x0F0F0F0F0F0F0F0FULL, 4);
	SWAPBITS(x[2], x[6], 0x0F0F0F0F0F0F0F0FULL, 4);
	SWAPBITS(x[3], x[7], 0x0F0F0F0F0F0F0F0FULL, 4);
}

/* n blocks (1 to 4) into the eight words; the blocks not given are zeros */
static void
load(u64 *q, const uchar *in, int n)
{
	int k, c, r;

	memset(q, 0, 8*sizeof(u64));
	for(k = 0; k < n; k++)
		for(c = 0; c < 4; c++)
			for(r = 0; r < 4; r++)
				q[4*(c&1) + k] |= (u64)in[16*k + 4*c + r] << (8*(2*r + (c>>1)));
	transpose(q);
}

/* and back (q is left as bytes, for the caller to clear) */
static void
store(uchar *out, u64 *q, int n)
{
	int k, c, r;

	transpose(q);
	for(k = 0; k < n; k++)
		for(c = 0; c < 4; c++)
			for(r = 0; r < 4; r++)
				out[16*k + 4*c + r] = q[4*(c&1) + k] >> (8*(2*r + (c>>1)));
}

/* the cipher (FIPS 197 5.1) on the blocks in q (not named encrypt: the native kernels' lib.h has one) */
static void
cipher(const u64 *rk, int rounds, u64 *q)
{
	int i;

	addroundkey(q, rk);
	for(i = 1; i < rounds; i++){
		subbytes(q);
		shiftrows(q);
		mixcolumns(q);
		addroundkey(q, rk + 8*i);
	}
	subbytes(q);
	shiftrows(q);
	addroundkey(q, rk + 8*rounds);
}

/* the inverse cipher (FIPS 197 5.3), with the same round keys */
static void
invcipher(const u64 *rk, int rounds, u64 *q)
{
	int i;

	addroundkey(q, rk + 8*rounds);
	for(i = rounds-1; i > 0; i--){
		invshiftrows(q);
		invsubbytes(q);
		addroundkey(q, rk + 8*i);
		invmixcolumns(q);
	}
	invshiftrows(q);
	invsubbytes(q);
	addroundkey(q, rk);
}

/* SubWord (FIPS 197 5.2): the S-box on a word's four bytes */
static u32
subword(u32 w)
{
	u64 q[8];
	int b, j;

	memset(q, 0, sizeof q);
	for(b = 0; b < 8; b++)
		for(j = 0; j < 4; j++)
			q[b] |= (u64)((w >> (8*j + b)) & 1) << j;
	subbytes(q);
	w = 0;
	for(b = 0; b < 8; b++)
		for(j = 0; j < 4; j++)
			w |= (u32)((q[b] >> j) & 1) << (8*j + b);
	secureZero(q, sizeof q);
	return w;
}

/* a round key's four words as a block's 16 bytes: a word is a column, its high byte row 0 */
static void
wordstobytes(uchar *p, const u32 *w)
{
	int c;

	for(c = 0; c < 4; c++){
		p[4*c] = w[c] >> 24;
		p[4*c+1] = w[c] >> 16;
		p[4*c+2] = w[c] >> 8;
		p[4*c+3] = w[c];
	}
}

/*
 * The key expansion (FIPS 197 5.2): the encryption round keys as
 * words (which the instructions' code loads), the same as bit planes
 * with each key under all four blocks, and the decryption keys of the
 * equivalent inverse cipher (5.3.5: the inner ones through
 * InvMixColumns, in reverse order), which only the instructions use.
 * What it branches on is the key's length.  Where x86-64 has the
 * instructions they make the words of both (aesamd64expand: SubWord
 * through the bit planes is slow, and a message of a few blocks is
 * mostly its key's setup); the bit planes are made from them all the
 * same, so a state serves either code.
 */
static int
keysetup(AESstate *s, const uchar *key, int keybytes)
{
	static const uchar rcon[] = {
		0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36
	};
	u32 *w, t;
	u64 q[8];
	uchar blk[16];
	int nk, nr, i, j, c, hw;

	nk = keybytes/4;
	nr = nk + 6;
	w = s->ekey;
	t = 0;
	hw = aesamd64ok();
	if(hw)
		aesamd64expand(w, s->dkey, key, keybytes);
	else{
		for(i = 0; i < nk; i++)
			w[i] = (u32)key[4*i]<<24 | (u32)key[4*i+1]<<16 | (u32)key[4*i+2]<<8 | (u32)key[4*i+3];
		for(i = nk; i < 4*(nr+1); i++){
			t = w[i-1];
			if(i % nk == 0)
				t = subword(t<<8 | t>>24) ^ (u32)rcon[i/nk - 1]<<24;
			else if(nk > 6 && i % nk == 4)
				t = subword(t);
			w[i] = w[i-nk] ^ t;
		}
	}
	for(i = 0; i <= nr; i++){
		wordstobytes(blk, w + 4*i);
		load(q, blk, 1);
		if(hw)
			;	/* aesamd64expand made dkey */
		else if(i == 0 || i == nr)
			memmove(s->dkey + 4*(nr-i), w + 4*i, 4*sizeof(u32));
		else{
			u64 d[8];

			memmove(d, q, sizeof d);
			invmixcolumns(d);
			store(blk, d, 1);
			for(c = 0; c < 4; c++)
				s->dkey[4*(nr-i) + c] = (u32)blk[4*c]<<24 | (u32)blk[4*c+1]<<16
					| (u32)blk[4*c+2]<<8 | (u32)blk[4*c+3];
			secureZero(d, sizeof d);
		}
		for(j = 0; j < 8; j++)
			s->bkey[8*i + j] = q[j] | q[j]<<1 | q[j]<<2 | q[j]<<3;
	}
	secureZero(&t, sizeof t);
	secureZero(q, sizeof q);
	secureZero(blk, sizeof blk);
	return nr;
}

void
setupAESstate(AESstate *s, uchar key[], int keybytes, uchar *ivec)
{
	memset(s, 0, sizeof(*s));
	if(keybytes != 16 && keybytes != 24 && keybytes != 32)
		return;
	s->keybytes = keybytes;
	s->rounds = keysetup(s, key, keybytes);
	if(ivec != nil)
		memmove(s->ivec, ivec, AESbsize);
	s->setup = AESset;
}

/*
 * A state holds the key as round keys, twice over (words and bit
 * planes; the key as given was kept too, which nothing read), and the
 * chain's last block: whoever is done with one calls this, so that a
 * freed or reused block of memory does not keep them.
 */
void
clearAESstate(AESstate *s)
{
	secureZero(s, sizeof(*s));
}

/* one block, when there is only one */
static void
encrypt1(AESstate *s, const uchar *pt, uchar *ct)
{
	u64 q[8];

	load(q, pt, 1);
	cipher(s->bkey, s->rounds, q);
	store(ct, q, 1);
	secureZero(q, sizeof q);
}

// Define by analogy with desCBCencrypt;  AES modes are not standardized yet.
// Because of the way that non-multiple-of-16 buffers are handled,
// the decryptor must be fed buffers of the same size as the encryptor.
void
aesCBCencrypt(uchar *p, int len, AESstate *s)
{
	uchar *p2, *ip, *eip;
	uchar q[AESbsize];

	if(!aesok(s)){
		if(len > 0)
			memset(p, 0, len);
		return;
	}
	if(len >= AESbsize && aesarm64ok()){
		aesarm64cbcencrypt(p, len/AESbsize, s->ekey, s->rounds, s->ivec);
		p += len - len%AESbsize;
		len %= AESbsize;
	}else if(len >= AESbsize && aesamd64ok()){
		aesamd64cbcencrypt(p, len/AESbsize, s->ekey, s->rounds, s->ivec);
		p += len - len%AESbsize;
		len %= AESbsize;
	}
	for(; len >= AESbsize; len -= AESbsize){
		p2 = p;
		ip = s->ivec;
		for(eip = ip+AESbsize; ip < eip; )
			*p2++ ^= *ip++;
		encrypt1(s, p, q);
		memmove(s->ivec, q, AESbsize);
		memmove(p, q, AESbsize);
		p += AESbsize;
	}

	if(len > 0){
		ip = s->ivec;
		aesEncryptBlock(s, ip, q);
		memmove(s->ivec, q, AESbsize);
		for(eip = ip+len; ip < eip; )
			*p++ ^= *ip++;
	}
	secureZero(q, sizeof q);
}

void
aesCBCdecrypt(uchar *p, int len, AESstate *s)
{
	uchar *ip, *eip;
	uchar ct[4*AESbsize], q[AESbsize];
	u64 b[8];
	int n, i;

	if(!aesok(s)){
		if(len > 0)
			memset(p, 0, len);
		return;
	}
	if(len >= AESbsize && aesarm64ok()){
		aesarm64cbcdecrypt(p, len/AESbsize, s->dkey, s->rounds, s->ivec);
		p += len - len%AESbsize;
		len %= AESbsize;
	}else if(len >= AESbsize && aesamd64ok()){
		aesamd64cbcdecrypt(p, len/AESbsize, s->dkey, s->rounds, s->ivec);
		p += len - len%AESbsize;
		len %= AESbsize;
	}
	/* four blocks at a time: each is decrypted and exclusive-ored with the ciphertext before it */
	while(len >= AESbsize){
		n = len/AESbsize;
		if(n > 4)
			n = 4;
		memmove(ct, p, n*AESbsize);
		load(b, p, n);
		invcipher(s->bkey, s->rounds, b);
		store(p, b, n);
		for(i = 0; i < AESbsize; i++)
			p[i] ^= s->ivec[i];
		for(i = AESbsize; i < n*AESbsize; i++)
			p[i] ^= ct[i-AESbsize];
		memmove(s->ivec, ct + (n-1)*AESbsize, AESbsize);
		p += n*AESbsize;
		len -= n*AESbsize;
	}

	if(len > 0){
		ip = s->ivec;
		aesEncryptBlock(s, ip, q);
		memmove(s->ivec, q, AESbsize);
		for(eip = ip+len; ip < eip; )
			*p++ ^= *ip++;
	}
	secureZero(b, sizeof b);
	secureZero(q, sizeof q);
}

/* single-block AES encrypt, for GCM's H and tag and the generator */
void
aesEncryptBlock(AESstate *s, uchar pt[16], uchar ct[16])
{
	if(!aesok(s)){
		memset(ct, 0, AESbsize);
		return;
	}
	if(aesarm64ok()){
		aesarm64encryptblock(s->ekey, s->rounds, pt, ct);
		return;
	}
	if(aesamd64ok()){
		aesamd64encryptblock(s->ekey, s->rounds, pt, ct);
		return;
	}
	encrypt1(s, pt, ct);
}

/*
 * GCM's counter mode (SP 800-38D 6.5, GCTR): n bytes of p
 * exclusive-ored in place with the encryptions of ctr, ctr+1, ..., the
 * count its last 32 bits, big-endian.  Four counters are encrypted at
 * a time, which is where the bit planes earn their keep.
 */
void
aesCTR32(AESstate *s, const uchar ctr[16], uchar *p, ulong n)
{
	uchar blk[4*AESbsize];
	u64 q[8];
	u32 base, v;
	ulong m, j;
	int l;

	if(!aesok(s)){
		memset(p, 0, n);
		return;
	}
	if(aesarm64ok()){
		aesarm64ctr32(s->ekey, s->rounds, ctr, p, n);
		return;
	}
	if(aesamd64ok()){
		aesamd64ctr32(s->ekey, s->rounds, ctr, p, n);
		return;
	}
	base = (u32)ctr[12]<<24 | (u32)ctr[13]<<16 | (u32)ctr[14]<<8 | ctr[15];
	while(n > 0){
		for(l = 0; l < 4; l++){
			memmove(blk + 16*l, ctr, 12);
			v = base + l;
			blk[16*l+12] = v>>24;
			blk[16*l+13] = v>>16;
			blk[16*l+14] = v>>8;
			blk[16*l+15] = v;
		}
		base += 4;
		load(q, blk, 4);
		cipher(s->bkey, s->rounds, q);
		store(blk, q, 4);
		m = n;
		if(m > sizeof blk)
			m = sizeof blk;
		for(j = 0; j < m; j++)
			p[j] ^= blk[j];
		p += m;
		n -= m;
	}
	secureZero(q, sizeof q);
	secureZero(blk, sizeof blk);
}
