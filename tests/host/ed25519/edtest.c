/*
 * libkeyring/ed25519alg.c's Ed25519 on the host: known answers and
 * refusals, built with the undefined-behaviour sanitizer by
 * tests/host/ed25519_test.sh.  The file is Keyring's glue and the
 * arithmetic in one, and is included here, so its scalar arithmetic
 * can be reached; what the glue needs of lib9 is stubbed here
 * (nothing below calls it), and libmp is the tree's.
 *
 *	edtest vectors.txt	known answers and refusals; then the
 *				scalar arithmetic (sc_reduce, sc_muladd)
 *				against libmp's, and [a]B against plain
 *				double-and-add, on random and extreme values
 *	edtest ct sign|pubkey	a signature, or a public key, made of a
 *				seed valgrind is told is secret (-DCTGRIND):
 *				any branch or address that depends on it,
 *				and so on the scalar or the nonce made of
 *				it, is reported
 */
#include <stdio.h>
#include "../../../libkeyring/ed25519alg.c"
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

/* the glue's needs of lib9 and libsec that nothing below reaches */
static void	no(char *s) { fprintf(stderr, "edtest: %s called\n", s); exit(3); }
int	enc64(char *o, int n, uchar *i, int m) { USED(o); USED(n); USED(i); USED(m); no("enc64"); return 0; }
int	dec64(uchar *o, int n, char *i, int m) { USED(o); USED(n); USED(i); USED(m); no("dec64"); return 0; }
int	fprint(int fd, char *fmt, ...) { USED(fd); USED(fmt); return 0; }
void	genrandom(uchar *p, int n) { USED(p); USED(n); no("genrandom"); }

/* libmp's (the signature's S is made with it) */
void*
mallocz(ulong n, int clr)
{
	USED(clr);
	return calloc(1, n);
}

void
sysfatal(char *fmt, ...)
{
	fprintf(stderr, "edtest: sysfatal: %s\n", fmt);
	exit(3);
}

static int fails, checks;

static void
check(int ok, char *what, int i)
{
	checks++;
	if(!ok){
		fails++;
		if(fails < 20)
			printf("FAIL: %s (vector %d)\n", what, i);
	}
}

static int
unhex(char *s, uchar *out, int max)
{
	int n, c, v;

	if(strcmp(s, "-") == 0)
		return 0;
	for(n = 0; s[0] != 0 && s[1] != 0; s += 2, n++){
		if(n >= max)
			return -1;
		v = 0;
		for(c = 0; c < 2; c++){
			v <<= 4;
			if(s[c] >= '0' && s[c] <= '9')
				v |= s[c] - '0';
			else if(s[c] >= 'a' && s[c] <= 'f')
				v |= s[c] - 'a' + 10;
			else
				return -1;
		}
		out[n] = v;
	}
	return n;
}

/* the group's order, little-endian: S + L is the same signature to an implementation that does not ask S < L */
static uchar L[32] = {
	0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
};

/* n bytes, little-endian, as a number; and a number mod L as 32 bytes, little-endian */
static mpint*
le2mp(const uchar *le, int n)
{
	uchar be[64];
	int i;

	for(i = 0; i < n; i++)
		be[i] = le[n-1-i];
	return betomp(be, n, nil);
}

static void
modL(uchar out[32], mpint *x)
{
	uchar be[32];
	mpint *l, *r;
	int i, n;

	l = le2mp(L, 32);
	r = mpnew(0);
	mpmod(x, l, r);
	memset(be, 0, sizeof be);
	n = (mpsignif(r) + 7) / 8;
	if(n > 0)
		mptobe(r, be + 32 - n, n, nil);
	for(i = 0; i < 32; i++)
		out[i] = be[31-i];
	mpfree(l);
	mpfree(r);
}

/* [a]B the plain way, a bit at a time: what ge_scalarmult_base was */
static void
refbasemult(uchar out[32], const uchar *a)
{
	ge_p3 B, h;
	ge_p1p1 t;
	ge_cached Bc;
	int i;

	fe_copy(B.X, Bx);
	fe_copy(B.Y, By);
	fe_1(B.Z);
	fe_mul(B.T, Bx, By);
	ge_p3_to_cached(&Bc, &B);
	ge_p3_0(&h);
	for(i = 255; i >= 0; i--){
		ge_p3_dbl(&t, &h);
		ge_p1p1_to_p3(&h, &t);
		if((a[i/8] >> (i&7)) & 1){
			ge_add(&t, &h, &Bc);
			ge_p1p1_to_p3(&h, &t);
		}
	}
	ge_p3_tobytes(out, &h);
}

/* a value to try: random, or one of the ends (0, 1, L-1, L, L+1, all ones, a top bit, ones below it) */
static void
pick(uchar *b, int n, int k)
{
	int i;

	for(i = 0; i < n; i++)
		b[i] = rand() >> 7;
	switch(k % 16){
	case 0:
		memset(b, 0, n);
		break;
	case 1:
		memset(b, 0, n);
		b[0] = 1;
		break;
	case 2: case 3: case 4:
		memset(b, 0, n);
		memmove(b, L, 32);
		b[0] += k % 16 - 3;	/* L-1, L, L+1 */
		break;
	case 5:
		memset(b, 0xff, n);
		break;
	case 6:
		memset(b, 0, n);
		b[n-1] = 0x80;
		break;
	case 7:
		memset(b, 0xff, n);
		b[n-1] = 0x7f;
		break;
	}
}

/*
 * The scalar arithmetic against libmp's, and the base-point
 * multiplication against the plain one.  A signature's values are
 * below L or clamped; these are any at all, the ends among them.
 */
static void
scalars(void)
{
	uchar a[32], b[32], c[32], w[64], got[32], want[32];
	mpint *ma, *mb, *mc, *mw;
	ge_p3 h;
	int i;

	srand(8032);
	for(i = 0; i < 20000; i++){
		pick(a, 32, i);
		pick(b, 32, i / 16);
		pick(c, 32, i / 256);
		ma = le2mp(a, 32);
		mb = le2mp(b, 32);
		mc = le2mp(c, 32);
		mw = mpnew(0);
		mpmul(ma, mb, mw);
		mpadd(mw, mc, mw);
		modL(want, mw);
		sc_muladd(got, a, b, c);
		check(memcmp(got, want, 32) == 0, "sc_muladd is (a*b+c) mod L", i);
		mpfree(ma); mpfree(mb); mpfree(mc); mpfree(mw);

		pick(w, 64, i);
		mw = le2mp(w, 64);
		modL(want, mw);
		sc_reduce(w);
		check(memcmp(w, want, 32) == 0, "sc_reduce is a 512-bit number mod L", i);
		mpfree(mw);
	}
	for(i = 0; i < 400; i++){
		pick(a, 32, i);
		ge_scalarmult_base(&h, a);
		ge_p3_tobytes(got, &h);
		refbasemult(want, a);
		check(memcmp(got, want, 32) == 0, "[a]B is double-and-add's", i);
	}
}

/*
 * Constant time: the seed is marked as valgrind's "undefined", which it
 * follows through every operation: the scalar and the nonce are made
 * of it.  A first call with a known seed gets the file's self-test,
 * which runs once, out of the way.
 */
static int
ct(char *what)
{
	uchar seed[32], pk[32], sig[64], msg[100];
	int i;

	for(i = 0; i < 32; i++)
		seed[i] = 7*i + 1;
	for(i = 0; i < sizeof msg; i++)
		msg[i] = i;
	ed25519_raw_sign(sig, seed, msg, sizeof msg);
	seed[0] ^= 0x55;
	VALGRIND_MAKE_MEM_UNDEFINED(seed, sizeof seed);
	if(strcmp(what, "sign") == 0){
		ed25519_raw_sign(sig, seed, msg, sizeof msg);
		VALGRIND_MAKE_MEM_DEFINED(sig, sizeof sig);
		printf("%02x\n", sig[0] ^ sig[63]);
	}else if(strcmp(what, "pubkey") == 0){
		ed25519_raw_pubkey(pk, seed);
		VALGRIND_MAKE_MEM_DEFINED(pk, sizeof pk);
		printf("%02x\n", pk[0]);
	}else
		return 2;
	return 0;
}

int
main(int argc, char **argv)
{
	FILE *f;
	static char line[4096], sseed[80], spk[80], smsg[2048], ssig[160];
	uchar seed[32], pk[32], msg[1024], sig[64], out[64], bad[64], pk2[32];
	int i, n, j, c;

	if(argc == 3 && strcmp(argv[1], "ct") == 0)
		return ct(argv[2]);
	if(argc != 2){
		fprintf(stderr, "usage: edtest vectors.txt | ct sign|pubkey\n");
		return 2;
	}
	f = fopen(argv[1], "r");
	if(f == NULL){
		perror(argv[1]);
		return 2;
	}
	for(i = 0; fgets(line, sizeof line, f) != NULL; i++){
		if(sscanf(line, "%79s %79s %2047s %159s", sseed, spk, smsg, ssig) != 4
		|| unhex(sseed, seed, 32) != 32 || unhex(spk, pk, 32) != 32
		|| (n = unhex(smsg, msg, sizeof msg)) < 0 || unhex(ssig, sig, 64) != 64){
			printf("FAIL: vector %d is not one\n", i);
			return 2;
		}
		ed25519_raw_pubkey(pk2, seed);
		check(memcmp(pk2, pk, 32) == 0, "the public key of a seed", i);
		ed25519_raw_sign(out, seed, msg, n);
		check(memcmp(out, sig, 64) == 0, "a signature, byte for byte", i);
		check(ed25519_raw_verify(sig, pk, msg, n) == 1, "a signature verifies", i);

		/* each half changed, the message changed, another key's */
		memmove(bad, sig, 64);
		bad[i % 32] ^= 1 << (i % 8);
		check(ed25519_raw_verify(bad, pk, msg, n) != 1, "a signature with R changed is refused", i);
		memmove(bad, sig, 64);
		bad[32 + i % 32] ^= 1 << (i % 8);
		check(ed25519_raw_verify(bad, pk, msg, n) != 1, "a signature with S changed is refused", i);
		if(n > 0){
			msg[i % n] ^= 0x80;
			check(ed25519_raw_verify(sig, pk, msg, n) != 1, "a signature of another message is refused", i);
			msg[i % n] ^= 0x80;
		}
		check(ed25519_raw_verify(sig, pk, msg, n + 1) != 1, "a signature of a longer message is refused", i);
		memmove(pk2, pk, 32);
		pk2[i % 32] ^= 4;
		check(ed25519_raw_verify(sig, pk2, msg, n) != 1, "a signature under another key is refused", i);

		/* S + L (RFC 8032 5.1.7: S must be below L) */
		memmove(bad, sig, 64);
		c = 0;
		for(j = 0; j < 32; j++){
			c += bad[32+j] + L[j];
			bad[32+j] = c;
			c >>= 8;
		}
		if(c == 0)
			check(ed25519_raw_verify(bad, pk, msg, n) != 1, "a signature with the order added to S is refused", i);
	}
	fclose(f);
	if(i < 100){
		printf("FAIL: only %d vectors read\n", i);
		return 1;
	}
	scalars();
	if(fails){
		printf("ed25519: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("ed25519: %d vectors and the scalar arithmetic, %d checks\n", i, checks);
	return 0;
}
