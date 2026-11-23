/*
 * libsec's AES, aes.c's constant-time C (bit planes) and the
 * processor's AES instructions (aesarm64.c's ARMv8, aesamd64.c's
 * AES-NI), against FIPS-197 and NIST SP 800-38A, against a plain
 * reference written from FIPS 197 here, and against each other.
 * Built by tests/host/armcrypto_test.sh.
 *
 *	aestest		known answers, the S-box circuit on every byte,
 *			random cases against the reference, by the C and
 *			by the instructions; the two against each other
 *			(key schedules, CBC, a block, counter mode); speeds
 *	aestest ct	the C on a key, IV and data valgrind is told are
 *			secret (-DCTGRIND): any branch or address that
 *			depends on them is reported
 *	aestest ct hw	the same through the instructions
 */
#include "../../../libsec/aes.c"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

void aesarm64use(int);	/* aesarm64.c, built beside this */
void aesamd64use(int);	/* and aesamd64.c */

/* the instructions, whichever the processor has: on, or off for aes.c's C */
static void
hwuse(int on)
{
	aesarm64use(on);
	aesamd64use(on);
}

static int
hwok(void)
{
	return aesarm64ok() || aesamd64ok();
}

static char*
hwname(void)
{
	return aesamd64ok() ? "AES-NI" : "ARMv8";
}

static int failed;

static void
hex(const char *s, uchar *b, int n)
{
	int i;
	unsigned v;

	for(i = 0; i < n; i++){
		sscanf(s + 2*i, "%2x", &v);
		b[i] = v;
	}
}

static void
check(const char *what, uchar *got, uchar *want, int n)
{
	if(memcmp(got, want, n) != 0){
		printf("FAIL: %s\n", what);
		failed = 1;
	}
}

static void
fips197(const char *path)
{
	static struct { int kb; const char *ct; } v[] = {
		{16, "69c4e0d86a7b0430d8cdb78070b4c55a"},
		{24, "dda97ca4864cdfe06eaf70a0ec0d7191"},
		{32, "8ea2b7ca516745bfeafc49904b496089"},
	};
	uchar key[32], pt[16], ct[16], out[16], want[16], iv[16];
	char what[64];
	AESstate s;
	int i, j;

	for(i = 0; i < 32; i++)
		key[i] = i;
	hex("00112233445566778899aabbccddeeff", pt, 16);
	for(j = 0; j < 3; j++){
		hex(v[j].ct, want, 16);
		memset(iv, 0, 16);
		setupAESstate(&s, key, v[j].kb, iv);
		aesEncryptBlock(&s, pt, out);
		snprintf(what, sizeof what, "%s: FIPS-197 AES-%d block", path, 8*v[j].kb);
		check(what, out, want, 16);
		/* CBC with a zero IV is the block cipher on its first block */
		memcpy(ct, pt, 16);
		aesCBCencrypt(ct, 16, &s);
		snprintf(what, sizeof what, "%s: FIPS-197 AES-%d through CBC", path, 8*v[j].kb);
		check(what, ct, want, 16);
		memset(iv, 0, 16);
		setupAESstate(&s, key, v[j].kb, iv);
		aesCBCdecrypt(ct, 16, &s);
		snprintf(what, sizeof what, "%s: FIPS-197 AES-%d decrypted", path, 8*v[j].kb);
		check(what, ct, pt, 16);
	}
}

static void
sp80038a(const char *path)
{
	uchar key[32], iv[16], pt[64], ct[64], buf[64];
	char what[64];
	AESstate s;

	hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4", key, 32);
	hex("000102030405060708090a0b0c0d0e0f", iv, 16);
	hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
	    "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710", pt, 64);
	hex("f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d"
	    "39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b", ct, 64);
	setupAESstate(&s, key, 32, iv);
	memcpy(buf, pt, 64);
	aesCBCencrypt(buf, 64, &s);
	snprintf(what, sizeof what, "%s: SP 800-38A F.2.5 CBC-AES256 encrypt", path);
	check(what, buf, ct, 64);
	setupAESstate(&s, key, 32, iv);
	aesCBCdecrypt(buf, 64, &s);
	snprintf(what, sizeof what, "%s: SP 800-38A F.2.6 CBC-AES256 decrypt", path);
	check(what, buf, pt, 64);
}

static void
cross(void)
{
	uchar key[32], iv[16], buf[1000], a[1000], b[1000];
	AESstate s, s2;
	int t, i, n, kb, bad;

	srand(1);
	bad = 0;
	for(t = 0; t < 6000; t++){
		kb = 16 + 8*(t%3);
		for(i = 0; i < 32; i++)
			key[i] = rand();
		for(i = 0; i < 16; i++)
			iv[i] = rand();
		n = rand() % 1000;
		for(i = 0; i < n; i++)
			buf[i] = rand();
		memcpy(a, buf, n);
		memcpy(b, buf, n);
		hwuse(0);
		setupAESstate(&s, key, kb, iv);
		aesCBCencrypt(a, n, &s);
		hwuse(1);
		setupAESstate(&s2, key, kb, iv);
		/* the same state from either: round keys as words, for decryption, as bit planes */
		if(memcmp(&s, &s2, offsetof(AESstate, ivec)) != 0)
			bad++;
		aesCBCencrypt(b, n, &s2);
		if(memcmp(a, b, n) != 0)
			bad++;
		/* and back, each with the other's */
		hwuse(t & 1);
		setupAESstate(&s, key, kb, iv);
		aesCBCdecrypt(b, n, &s);
		if(memcmp(b, buf, n) != 0)
			bad++;
		/* a block, and the counter mode, the count near its wrap one time in four */
		hwuse(0);
		aesEncryptBlock(&s, buf, a);
		hwuse(1);
		aesEncryptBlock(&s, buf, b);
		if(memcmp(a, b, 16) != 0)
			bad++;
		if(t % 4 == 0){
			iv[12] = iv[13] = iv[14] = 0xff;
			iv[15] = 0xf0 + t%16;
		}
		memcpy(a, buf, n);
		memcpy(b, buf, n);
		hwuse(0);
		aesCTR32(&s, iv, a, n);
		hwuse(1);
		aesCTR32(&s, iv, b, n);
		if(memcmp(a, b, n) != 0)
			bad++;
	}
	if(bad){
		printf("FAIL: the two paths disagree %d times on 6000 random keys, IVs and lengths\n", bad);
		failed = 1;
	}else
		printf("PASS: the two paths agree on 6000 random keys, IVs and lengths: the schedules, CBC both ways, a block, counter mode\n");
}

/*
 * The reference: FIPS 197 a byte at a time, its S-box from the
 * definition (the inverse in GF(2^8), then the affine map).  Slow,
 * and nothing of aes.c's in it.
 */
static uchar rsbox[256], risbox[256];

static uchar
gmul(uchar a, uchar b)
{
	uchar p;
	int i;

	p = 0;
	for(i = 0; i < 8; i++){
		if(b & 1)
			p ^= a;
		a = (a << 1) ^ ((a & 0x80) ? 0x1b : 0);
		b >>= 1;
	}
	return p;
}

static void
refinit(void)
{
	int x, y, i;
	uchar inv, v;

	for(x = 0; x < 256; x++){
		inv = 0;
		for(y = 1; y < 256; y++)
			if(gmul(x, y) == 1)
				inv = y;
		v = 0;
		for(i = 0; i < 8; i++)
			v |= (((inv >> i) ^ (inv >> ((i+4)%8)) ^ (inv >> ((i+5)%8))
				^ (inv >> ((i+6)%8)) ^ (inv >> ((i+7)%8)) ^ (0x63 >> i)) & 1) << i;
		rsbox[x] = v;
		risbox[v] = x;
	}
}

static void
refkeys(uchar rk[15][16], uchar *key, int kb)
{
	uchar w[60][4], t[4], x, rc;
	int nk, nr, i, j;

	nk = kb/4;
	nr = nk + 6;
	memcpy(w, key, kb);
	rc = 1;
	for(i = nk; i < 4*(nr+1); i++){
		memcpy(t, w[i-1], 4);
		if(i % nk == 0){
			x = t[0];
			t[0] = rsbox[t[1]] ^ rc;
			t[1] = rsbox[t[2]];
			t[2] = rsbox[t[3]];
			t[3] = rsbox[x];
			rc = gmul(rc, 2);
		}else if(nk > 6 && i % nk == 4)
			for(j = 0; j < 4; j++)
				t[j] = rsbox[t[j]];
		for(j = 0; j < 4; j++)
			w[i][j] = w[i-nk][j] ^ t[j];
	}
	for(i = 0; i <= nr; i++)
		memcpy(rk[i], w[4*i], 16);
}

static void
refenc(uchar *key, int kb, uchar *in, uchar *out)
{
	uchar rk[15][16], s[16], t[16];
	int nr, r, i, c;

	nr = kb/4 + 6;
	refkeys(rk, key, kb);
	for(i = 0; i < 16; i++)
		s[i] = in[i] ^ rk[0][i];
	for(r = 1; r <= nr; r++){
		for(i = 0; i < 16; i++)
			t[i] = rsbox[s[i]];
		for(c = 0; c < 4; c++)
			for(i = 0; i < 4; i++)
				s[4*c+i] = t[4*((c+i)%4)+i];
		if(r != nr)
			for(c = 0; c < 4; c++){
				memcpy(t, s+4*c, 4);
				for(i = 0; i < 4; i++)
					s[4*c+i] = gmul(t[i], 2) ^ gmul(t[(i+1)%4], 3) ^ t[(i+2)%4] ^ t[(i+3)%4];
			}
		for(i = 0; i < 16; i++)
			s[i] ^= rk[r][i];
	}
	memcpy(out, s, 16);
}

static void
refdec(uchar *key, int kb, uchar *in, uchar *out)
{
	uchar rk[15][16], s[16], t[16];
	int nr, r, i, c;

	nr = kb/4 + 6;
	refkeys(rk, key, kb);
	for(i = 0; i < 16; i++)
		s[i] = in[i] ^ rk[nr][i];
	for(r = nr-1; r >= 0; r--){
		for(c = 0; c < 4; c++)
			for(i = 0; i < 4; i++)
				t[4*((c+i)%4)+i] = s[4*c+i];
		for(i = 0; i < 16; i++)
			s[i] = risbox[t[i]] ^ rk[r][i];
		if(r != 0)
			for(c = 0; c < 4; c++){
				memcpy(t, s+4*c, 4);
				for(i = 0; i < 4; i++)
					s[4*c+i] = gmul(t[i], 14) ^ gmul(t[(i+1)%4], 11)
						^ gmul(t[(i+2)%4], 13) ^ gmul(t[(i+3)%4], 9);
			}
	}
	memcpy(out, s, 16);
}

/* the S-box circuit and its inverse on every byte, in every one of the 64 places */
static void
sboxes(void)
{
	u64 q[8];
	int x, pos, b, bad;
	uchar got;

	bad = 0;
	for(x = 0; x < 256; x++){
		for(b = 0; b < 8; b++)
			q[b] = ((x >> b) & 1) ? ~0ULL : 0;
		subbytes(q);
		for(pos = 0; pos < 64; pos++){
			got = 0;
			for(b = 0; b < 8; b++)
				got |= ((q[b] >> pos) & 1) << b;
			if(got != rsbox[x])
				bad++;
		}
		for(b = 0; b < 8; b++)
			q[b] = ((x >> b) & 1) ? ~0ULL : 0;
		invsubbytes(q);
		for(pos = 0; pos < 64; pos++){
			got = 0;
			for(b = 0; b < 8; b++)
				got |= ((q[b] >> pos) & 1) << b;
			if(got != risbox[x])
				bad++;
		}
	}
	if(rsbox[0] != 0x63 || rsbox[0x53] != 0xed || risbox[0x63] != 0){
		printf("FAIL: the test's own S-box is not FIPS 197's\n");
		failed = 1;
	}
	if(bad){
		printf("FAIL: the S-box circuit is wrong for %d of 32768 bytes and places\n", bad);
		failed = 1;
	}
}

/*
 * aes.c's C against the reference: the round keys, CBC both ways at
 * every length (so one, two, three and four blocks in the planes, and
 * the short tail), and the counter mode across its 32-bit wrap.
 */
static void
reference(const char *path)
{
	uchar key[32], iv[16], buf[300], a[300], want[300], prev[16], ks[16], ctr[16];
	uchar rk[15][16], blk[16];
	AESstate s;
	int t, i, j, n, kb, bad;
	u32 c0, v;

	srand(7);
	bad = 0;
	for(t = 0; t < 3000; t++){
		kb = 16 + 8*(t%3);
		for(i = 0; i < 32; i++)
			key[i] = rand();
		for(i = 0; i < 16; i++)
			iv[i] = rand();
		n = t < 300 ? t : rand() % 300;
		for(i = 0; i < n; i++)
			buf[i] = rand();

		setupAESstate(&s, key, kb, iv);
		refkeys(rk, key, kb);
		for(i = 0; i <= s.rounds; i++){
			wordstobytes(blk, s.ekey + 4*i);
			if(memcmp(blk, rk[i], 16) != 0)
				bad++;
		}

		/* CBC as libsec has it: whole blocks chained, a tail exclusive-ored with E(chain) */
		memcpy(prev, iv, 16);
		for(i = 0; i + 16 <= n; i += 16){
			for(j = 0; j < 16; j++)
				want[i+j] = buf[i+j] ^ prev[j];
			refenc(key, kb, want+i, want+i);
			memcpy(prev, want+i, 16);
		}
		if(i < n){
			refenc(key, kb, prev, ks);
			for(j = 0; i+j < n; j++)
				want[i+j] = buf[i+j] ^ ks[j];
		}
		memcpy(a, buf, n);
		aesCBCencrypt(a, n, &s);
		if(memcmp(a, want, n) != 0)
			bad++;
		setupAESstate(&s, key, kb, iv);
		aesCBCdecrypt(a, n, &s);
		if(memcmp(a, buf, n) != 0)
			bad++;
		/* and the reference's own inverse, on a block */
		if(n >= 16){
			refdec(key, kb, want, blk);
			for(j = 0; j < 16; j++)
				blk[j] ^= iv[j];
			if(memcmp(blk, buf, 16) != 0)
				bad++;
		}

		/* counter mode, the count starting near its wrap one time in four */
		memcpy(ctr, iv, 16);
		if(t % 4 == 0){
			ctr[12] = ctr[13] = ctr[14] = 0xff;
			ctr[15] = 0xf0 + t%16;
		}
		c0 = (u32)ctr[12]<<24 | (u32)ctr[13]<<16 | (u32)ctr[14]<<8 | ctr[15];
		for(i = 0; i < n; i += 16){
			memcpy(blk, ctr, 12);
			v = c0 + i/16;
			blk[12] = v>>24; blk[13] = v>>16; blk[14] = v>>8; blk[15] = v;
			refenc(key, kb, blk, ks);
			for(j = 0; j < 16 && i+j < n; j++)
				want[i+j] = buf[i+j] ^ ks[j];
		}
		memcpy(a, buf, n);
		aesCTR32(&s, ctr, a, n);
		if(memcmp(a, want, n) != 0)
			bad++;
	}
	if(bad){
		printf("FAIL: %s and the reference disagree %d times in 3000 random keys, IVs and lengths\n", path, bad);
		failed = 1;
	}else
		printf("PASS: %s is the reference's cipher on 3000 random keys, IVs and lengths: round keys, CBC both ways, counter mode\n", path);
}

/*
 * Constant time: the key, the IV and the data are marked as valgrind's
 * "undefined", which it follows through every operation; a branch or
 * an address made from them is reported.
 */
static void
ct(void)
{
	uchar key[32], iv[16], buf[200], ctr[16];
	AESstate s;
	int kb, i;

	for(kb = 16; kb <= 32; kb += 8){
		for(i = 0; i < 32; i++)
			key[i] = 3*i + kb;
		for(i = 0; i < 16; i++)
			iv[i] = ctr[i] = 5*i;
		for(i = 0; i < sizeof buf; i++)
			buf[i] = i;
		VALGRIND_MAKE_MEM_UNDEFINED(key, sizeof key);
		VALGRIND_MAKE_MEM_UNDEFINED(iv, sizeof iv);
		VALGRIND_MAKE_MEM_UNDEFINED(buf, sizeof buf);
		setupAESstate(&s, key, kb, iv);
		VALGRIND_MAKE_MEM_DEFINED(&s.setup, sizeof s.setup);
		VALGRIND_MAKE_MEM_DEFINED(&s.rounds, sizeof s.rounds);
		aesCBCencrypt(buf, sizeof buf, &s);
		aesCBCdecrypt(buf, sizeof buf, &s);
		aesEncryptBlock(&s, buf, buf+16);
		aesCTR32(&s, ctr, buf, sizeof buf);
		clearAESstate(&s);
		VALGRIND_MAKE_MEM_DEFINED(key, sizeof key);
		VALGRIND_MAKE_MEM_DEFINED(iv, sizeof iv);
		VALGRIND_MAKE_MEM_DEFINED(buf, sizeof buf);
	}
}

static double
speed(int dec)
{
	static uchar buf[32768];
	uchar key[32] = {1}, iv[16] = {0};
	AESstate s;
	clock_t t0;
	int n;

	setupAESstate(&s, key, 32, iv);
	t0 = clock();
	n = 0;
	while(clock() - t0 < CLOCKS_PER_SEC/2){
		if(dec)
			aesCBCdecrypt(buf, sizeof buf, &s);
		else
			aesCBCencrypt(buf, sizeof buf, &s);
		n++;
	}
	return n * (double)sizeof buf / 1e6 / ((double)(clock() - t0) / CLOCKS_PER_SEC);
}

/* key setups a second, in thousands: what a short message mostly costs */
static double
setups(void)
{
	uchar key[32] = {1}, iv[16] = {0};
	AESstate s;
	clock_t t0;
	int n;

	t0 = clock();
	n = 0;
	while(clock() - t0 < CLOCKS_PER_SEC/4){
		key[0] = n;
		setupAESstate(&s, key, 32, iv);
		n++;
	}
	return n / 1e3 / ((double)(clock() - t0) / CLOCKS_PER_SEC);
}

/*
 * A key is 16, 24 or 32 bytes.  Any other length made a state with no
 * rounds, which gave the block exclusive-ored with the key's first 16
 * bytes (a cipher to look at; with a key of no bytes, the block), and
 * through the instructions read the round key before its array.  Such a
 * state gives zeros now, by either path.
 */
static void
keylengths(const char *path)
{
	static int bad[] = { 0, 1, 8, 15, 17, 20, 31, 33, 48, 100, -1 };
	AESstate s;
	uchar key[128], pt[64], buf[64], ct[16], zero[64];
	int i, j;

	memset(zero, 0, sizeof zero);
	for(j = 0; j < sizeof key; j++)
		key[j] = 0xa0 + j;
	for(j = 0; j < sizeof pt; j++)
		pt[j] = j;
	for(i = 0; i < nelem(bad); i++){
		char what[64];

		setupAESstate(&s, key, bad[i], nil);
		snprintf(what, sizeof what, "%s: a key of %d bytes", path, bad[i]);
		if(s.setup != 0 || s.rounds != 0){
			printf("FAIL: %s made a state (rounds %d)\n", what, s.rounds);
			failed = 1;
		}
		memset(ct, 0xee, sizeof ct);
		aesEncryptBlock(&s, pt, ct);
		check(what, ct, zero, 16);
		memmove(buf, pt, sizeof buf);
		aesCBCencrypt(buf, 53, &s);
		check(what, buf, zero, 53);
		memmove(buf, pt, sizeof buf);
		aesCBCdecrypt(buf, 53, &s);
		check(what, buf, zero, 53);
	}
	/* and the functions under them, given a count that is none */
	if(aesarm64ok()){
		memset(ct, 0xee, sizeof ct);
		aesarm64encryptblock(s.ekey, 0, pt, ct);
		check("aesarm64encryptblock with no rounds", ct, zero, 16);
		memmove(buf, pt, sizeof buf);
		aesarm64cbcencrypt(buf, 3, s.ekey, 0, ct);
		check("aesarm64cbcencrypt with no rounds", buf, zero, 48);
		memmove(buf, pt, sizeof buf);
		aesarm64cbcdecrypt(buf, 3, s.dkey, 15, ct);
		check("aesarm64cbcdecrypt with 15 rounds", buf, zero, 48);
	}
	if(aesamd64ok()){
		memset(ct, 0xee, sizeof ct);
		aesamd64encryptblock(s.ekey, 0, pt, ct);
		check("aesamd64encryptblock with no rounds", ct, zero, 16);
		memmove(buf, pt, sizeof buf);
		aesamd64cbcencrypt(buf, 3, s.ekey, 0, ct);
		check("aesamd64cbcencrypt with no rounds", buf, zero, 48);
		memmove(buf, pt, sizeof buf);
		aesamd64cbcdecrypt(buf, 3, s.dkey, 15, ct);
		check("aesamd64cbcdecrypt with 15 rounds", buf, zero, 48);
		memmove(buf, pt, sizeof buf);
		aesamd64ctr32(s.ekey, 11, pt, buf, 53);
		check("aesamd64ctr32 with 11 rounds", buf, zero, 53);
	}
}

int
main(int argc, char **argv)
{
	double te, td, ts, ae, ad, as;
	char *hw;

	hwuse(0);
	if(argc > 1 && strcmp(argv[1], "ct") == 0){
		if(argc > 2 && strcmp(argv[2], "hw") == 0){
			hwuse(1);
			if(!hwok())
				return 2;	/* no instructions here: nothing was checked */
		}
		ct();
		return 0;
	}
	refinit();
	sboxes();
	fips197("C");
	sp80038a("C");
	keylengths("C");
	reference("aes.c");
	te = speed(0);
	td = speed(1);
	ts = setups();
	hwuse(1);
	if(hwok()){
		hw = hwname();
		fips197(hw);
		sp80038a(hw);
		keylengths(hw);
		reference(hw);
		cross();
		hwuse(1);
		ae = speed(0);
		ad = speed(1);
		as = setups();
		printf("AES-256-CBC MB/s: C %.0f encrypt %.0f decrypt; %s %.0f encrypt %.0f decrypt\n", te, td, hw, ae, ad);
		printf("AES-256 key setups, thousands a second: C %.0f; %s %.0f\n", ts, hw, as);
	}else
		printf("SKIP: no AES instructions here; AES-256-CBC in C %.0f encrypt %.0f decrypt MB/s, %.0f thousand key setups a second\n", te, td, ts);
	if(!failed)
		printf("PASS: FIPS-197 and SP 800-38A vectors on every path; a key that is none gives zeros\n");
	return failed;
}
