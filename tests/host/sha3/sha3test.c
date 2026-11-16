/*
 * libsec/sha3.c (SHA3-256, SHA3-512, SHAKE128, SHAKE256: FIPS 202) on
 * the host, built by tests/host/sha3_test.sh with the library's source.
 *
 *   sha3test vectors.txt
 *		hashlib's answers (tests/host/sha3/gen.py), in one call and
 *		with the SHAKEs absorbed and squeezed in pieces; random
 *		messages against the sponge written below from the
 *		standard's own description; calls out of turn (a squeeze
 *		with no finalize, an absorb after one) doing what
 *		libsec.h says; the one-call forms leaving no state behind
 *   sha3test time	the library's permutation against the one below, which
 *		is the form the library had: loops over rows and columns
 *		with indices mod 5 and the rotations from a table.  At the
 *		emulator's flags the library's must be at least twice as
 *		fast (it is about four times; it was the same code)
 *   sha3test ct	built -DCTGRIND, under valgrind: a secret message
 *		(undefined to memcheck) through each function; any branch
 *		or address that depends on it is reported
 */
#include "os.h"
#include <libsec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#endif

/*
 * The reference: FIPS 202 as it reads (and as libsec/sha3.c was
 * written before its rounds were written out).
 */
static const u64int rc[24] = {
	0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
	0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
	0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
	0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
	0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
	0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL,
};
static const int rotc[24] = { 1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44 };
static const int piln[24] = { 10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1 };
#define ROTL(x, n) (((x) << (n)) | ((x) >> (64-(n))))

static void
refkeccakf(u64int st[25])
{
	u64int t, bc[5];
	int i, j, r;

	for(r = 0; r < 24; r++){
		for(i = 0; i < 5; i++)
			bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20];
		for(i = 0; i < 5; i++){
			t = bc[(i+4) % 5] ^ ROTL(bc[(i+1) % 5], 1);
			for(j = 0; j < 25; j += 5)
				st[j+i] ^= t;
		}
		t = st[1];
		for(i = 0; i < 24; i++){
			j = piln[i];
			bc[0] = st[j];
			st[j] = ROTL(t, rotc[i]);
			t = bc[0];
		}
		for(j = 0; j < 25; j += 5){
			for(i = 0; i < 5; i++)
				bc[i] = st[j+i];
			for(i = 0; i < 5; i++)
				st[j+i] ^= (~bc[(i+1) % 5]) & bc[(i+2) % 5];
		}
		st[0] ^= rc[r];
	}
}

/* the sponge, a byte at a time: out is outlen bytes of Keccak[rate](msg || suffix) */
static void
refsponge(int rate, int suffix, const uchar *msg, long n, uchar *out, long outlen)
{
	u64int st[25];
	uchar *sb;
	long i;
	int j;

	memset(st, 0, sizeof st);
	sb = (uchar*)st;
	j = 0;
	for(i = 0; i < n; i++){
		sb[j++] ^= msg[i];
		if(j == rate){
			refkeccakf(st);
			j = 0;
		}
	}
	sb[j] ^= suffix;
	sb[rate-1] ^= 0x80;
	refkeccakf(st);
	j = 0;
	for(i = 0; i < outlen; i++){
		if(j == rate){
			refkeccakf(st);
			j = 0;
		}
		out[i] = sb[j++];
	}
}

static int fails;

static void
check(int ok, const char *what, int lineno)
{
	if(!ok){
		fails++;
		if(fails < 20)
			fprintf(stderr, "FAIL: %s (line %d)\n", what, lineno);
	}
}

static uchar*
unhex(const char *s, int *np)
{
	int n, i;
	unsigned v;
	uchar *o;

	if(strcmp(s, "-") == 0)
		s = "";
	n = strlen(s)/2;
	o = malloc(n ? n : 1);
	if(o == nil)
		abort();
	for(i = 0; i < n; i++){
		if(sscanf(s + 2*i, "%2x", &v) != 1)
			abort();
		o[i] = v;
	}
	*np = n;
	return o;
}

/* a SHAKE in pieces of p bytes */
static void
pieces(int alg, const uchar *msg, int n, uchar *out, int outlen, int p)
{
	SHA3state s;
	int i, m;

	if(alg == 128) shake128_init(&s); else shake256_init(&s);
	for(i = 0; i < n; i += p){
		m = n - i < p ? n - i : p;
		if(alg == 128) shake128_absorb(&s, msg + i, m); else shake256_absorb(&s, msg + i, m);
	}
	if(alg == 128) shake128_finalize(&s); else shake256_finalize(&s);
	for(i = 0; i < outlen; i += p){
		m = outlen - i < p ? outlen - i : p;
		if(alg == 128) shake128_squeeze(&s, out + i, m); else shake256_squeeze(&s, out + i, m);
	}
}

static int
vectors(const char *file)
{
	static char line[8192];
	char *f[6], *t;
	FILE *fp;
	int nf, lineno, n, no, outlen, piece, nvec, i, alg, rate;
	uchar *msg, *want, *out, *out2;
	static uchar big[4000], o1[700], o2[700];
	unsigned x;
	SHA3state s;

	fp = fopen(file, "r");
	if(fp == nil){
		fprintf(stderr, "cannot open %s\n", file);
		return 1;
	}
	lineno = nvec = 0;
	while(fgets(line, sizeof line, fp) != nil){
		lineno++;
		if(line[0] == '#')
			continue;
		nf = 0;
		for(t = strtok(line, " \n"); t != nil && nf < 6; t = strtok(nil, " \n"))
			f[nf++] = t;
		if(nf != 5){
			check(0, "malformed line", lineno);
			continue;
		}
		nvec++;
		msg = unhex(f[1], &n);
		outlen = atoi(f[2]);
		piece = atoi(f[3]);
		want = unhex(f[4], &no);
		out = malloc(outlen + 1);
		out2 = malloc(outlen + 1);
		out[outlen] = out2[outlen] = 0xA5;
		check(no == outlen, "malformed line", lineno);
		if(strcmp(f[0], "sha3_256") == 0 && outlen == 32)
			sha3_256(msg, n, out);
		else if(strcmp(f[0], "sha3_512") == 0 && outlen == 64)
			sha3_512(msg, n, out);
		else if(strcmp(f[0], "shake128") == 0 || strcmp(f[0], "shake256") == 0){
			alg = f[0][5] == '1' ? 128 : 256;
			if(alg == 128) shake128(msg, n, out, outlen); else shake256(msg, n, out, outlen);
			pieces(alg, msg, n, out2, outlen, piece);
			check(memcmp(out, out2, outlen) == 0, "absorbed and squeezed in pieces differs from one call", lineno);
			check(out2[outlen] == 0xA5, "squeezing wrote past the bytes asked for", lineno);
		}else
			check(0, "unknown algorithm", lineno);
		check(memcmp(out, want, outlen) == 0, "output differs from hashlib's", lineno);
		check(out[outlen] == 0xA5, "wrote past the output", lineno);
		free(msg); free(want); free(out); free(out2);
	}
	fclose(fp);
	if(nvec < 100){
		fprintf(stderr, "FAIL: %s has %d vectors\n", file, nvec);
		fails++;
	}

	/* random messages and lengths against the reference sponge */
	x = 2026;
	for(i = 0; i < 400; i++){
		x = x*1103515245 + 12345;
		n = (x >> 8) % sizeof big;
		for(no = 0; no < n; no++){
			x = x*1103515245 + 12345;
			big[no] = x >> 16;
		}
		x = x*1103515245 + 12345;
		outlen = 1 + (x >> 8) % (sizeof o1 - 1);
		alg = i & 1 ? 128 : 256;
		rate = alg == 128 ? 168 : 136;
		if(alg == 128) shake128(big, n, o1, outlen); else shake256(big, n, o1, outlen);
		refsponge(rate, 0x1F, big, n, o2, outlen);
		check(memcmp(o1, o2, outlen) == 0, "a SHAKE differs from the reference sponge", i);
		sha3_256(big, n, o1);
		refsponge(136, 0x06, big, n, o2, 32);
		check(memcmp(o1, o2, 32) == 0, "SHA3-256 differs from the reference sponge", i);
		sha3_512(big, n, o1);
		refsponge(72, 0x06, big, n, o2, 64);
		check(memcmp(o1, o2, 64) == 0, "SHA3-512 differs from the reference sponge", i);
	}

	/*
	 * out of turn (libsec.h): a squeeze with no finalize finalizes
	 * first, and an absorb after a finalize takes nothing
	 */
	shake256(big, 100, o1, 300);
	shake256_init(&s);
	shake256_absorb(&s, big, 100);
	shake256_squeeze(&s, o2, 300);
	check(memcmp(o1, o2, 300) == 0, "a squeeze with no finalize is not the SHAKE of what was absorbed", 0);
	shake256_init(&s);
	shake256_absorb(&s, big, 100);
	shake256_finalize(&s);
	shake256_squeeze(&s, o2, 100);
	shake256_absorb(&s, big + 500, 50);
	shake256_finalize(&s);
	shake256_squeeze(&s, o2 + 100, 200);
	check(memcmp(o1, o2, 300) == 0, "an absorb after finalize changed the output", 0);
	shake128(big, 300, o1, 400);
	shake128_init(&s);
	shake128_absorb(&s, big, 300);
	shake128_squeeze(&s, o2, 1);
	shake128_absorb(&s, big, 300);
	shake128_squeeze(&s, o2 + 1, 399);
	check(memcmp(o1, o2, 400) == 0, "SHAKE128 out of turn", 0);

	printf("%d known answers from hashlib, 1200 random messages against the reference sponge, calls out of turn\n", nvec);
	return fails != 0;
}

static double
now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec*1e-9;
}

/*
 * The library's permutation against the reference's, each the least of
 * several turns taken one after the other (other work on the machine
 * slows both): 2000 permutations as a long squeeze.
 */
static int
timing(void)
{
	static uchar out[136*2000], out2[136*2000];
	uchar in[32];
	double t, lib, slow;
	int i;

	memset(in, 3, sizeof in);
	lib = slow = 1e9;
	for(i = 0; i < 15; i++){
		t = now();
		shake256(in, sizeof in, out, sizeof out);
		t = now() - t;
		if(t < lib)
			lib = t;
		t = now();
		refsponge(136, 0x1F, in, sizeof in, out2, sizeof out2);
		t = now() - t;
		if(t < slow)
			slow = t;
	}
	if(memcmp(out, out2, sizeof out) != 0){
		fprintf(stderr, "FAIL: the two differ\n");
		return 1;
	}
	printf("%.0f ns a permutation; the form it had, %.0f ns: %.1f times as fast\n", lib/2000*1e9, slow/2000*1e9, slow/lib);
	if(slow < 2*lib){
		fprintf(stderr, "FAIL: Keccak-f is not twice as fast as the loops it was\n");
		return 1;
	}
	return 0;
}

static int
ct(void)
{
#ifdef CTGRIND
	static uchar msg[500], out[300];
	SHA3state s;
	int i;

	for(i = 0; i < sizeof msg; i++)
		msg[i] = i;
	VALGRIND_MAKE_MEM_UNDEFINED(msg, sizeof msg);
	sha3_256(msg, 33, out);
	sha3_512(msg, 64, out);
	sha3_512(msg, sizeof msg, out);
	shake128(msg, 34, out, sizeof out);
	shake256(msg, sizeof msg, out, sizeof out);
	shake256_init(&s);
	shake256_absorb(&s, msg, 32);
	shake256_absorb(&s, msg + 32, 137);
	shake256_finalize(&s);
	shake256_squeeze(&s, out, 7);
	shake256_squeeze(&s, out + 7, 200);
	VALGRIND_MAKE_MEM_DEFINED(out, sizeof out);
	VALGRIND_MAKE_MEM_DEFINED(msg, sizeof msg);
	printf("%02x\n", out[0]);
	return 0;
#else
	fprintf(stderr, "sha3test: not built with -DCTGRIND\n");
	return 2;
#endif
}

int
main(int argc, char **argv)
{
	if(argc >= 2 && strcmp(argv[1], "time") == 0)
		return timing();
	if(argc >= 2 && strcmp(argv[1], "ct") == 0)
		return ct();
	if(argc >= 2)
		return vectors(argv[1]);
	fprintf(stderr, "usage: sha3test vectors.txt | time | ct\n");
	return 2;
}
