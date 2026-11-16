/*
 * libsec/mlkem*.c (ML-KEM-768 and -1024, FIPS 203) on the host, built by
 * tests/host/mlkem_test.sh with the library's sources.
 *
 *   kemtest vectors.txt
 *		OpenSSL's answers (tests/host/mlkem/gen.py): key generation
 *		from the seeds d and z gives OpenSSL's encapsulation key
 *		(K-PKE.KeyGen hashes G(d || k); it hashed G(d)), the
 *		decapsulation key is s || ek || H(ek) || z, OpenSSL's
 *		ciphertext decapsulates to its secret, a changed ciphertext
 *		to J(z || c); an encapsulation of this code's decapsulates
 *		to K = G(m || H(ek))[0:32]; an encapsulation key with a
 *		coefficient not below q, and a decapsulation key with a bit
 *		of its ek or H(ek) changed, are refused with nothing
 *		written.  Every key and ciphertext is in a heap buffer
 *		exactly its length.
 *   kemtest ct SET keygen|enc|good|bad
 *		one operation with its secret marked undefined for
 *		valgrind's memcheck (ctgrind): the seeds of a key, the
 *		message of an encapsulation, s-hat and z of a decapsulation
 *		key (of a good ciphertext and of a changed one).  A branch
 *		or an address that depends on it is reported.
 *   kemtest cli	keygen, encaps and decaps on standard input, for cross.py
 */
#include "os.h"
#include <libsec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

/* genrandom: the bytes a test queued (d and z, or m), else the host's */
static uchar rngq[128];
static int rngqn, rngqp;

void
genrandom(uchar *p, int n)
{
	static int fd = -1;

	if(rngqp + n <= rngqn){
		memmove(p, rngq + rngqp, n);
		rngqp += n;
		return;
	}
	if(fd < 0)
		fd = open("/dev/urandom", O_RDONLY);
	if(fd < 0 || read(fd, p, n) != n)
		abort();
}

static void
queue(const uchar *p, int n)
{
	memmove(rngq, p, n);
	rngqn = n;
	rngqp = 0;
}

static int fails;

static void
check(int ok, const char *what, int set, int lineno)
{
	if(!ok){
		fails++;
		if(fails < 20)
			fprintf(stderr, "FAIL: ML-KEM-%d: %s (vectors line %d)\n", set, what, lineno);
	}
}

static uchar*
unhex(const char *s, int *np)
{
	int n, i;
	unsigned v;
	uchar *o;

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

static void
phex(const char *t, const uchar *p, int n)
{
	int i;

	printf("%s ", t);
	for(i = 0; i < n; i++)
		printf("%02x", p[i]);
	printf("\n");
}

static int pklen(int set) { return set == 768 ? MLKEM768_PKLEN : MLKEM1024_PKLEN; }
static int sklen(int set) { return set == 768 ? MLKEM768_SKLEN : MLKEM1024_SKLEN; }
static int ctlen(int set) { return set == 768 ? MLKEM768_CTLEN : MLKEM1024_CTLEN; }

static int
keygen(int set, uchar *pk, uchar *sk)
{
	return set == 768 ? mlkem768_keygen(pk, sk) : mlkem1024_keygen(pk, sk);
}

static int
encaps(int set, uchar *ct, uchar *ss, const uchar *pk)
{
	return set == 768 ? mlkem768_encaps(ct, ss, pk) : mlkem1024_encaps(ct, ss, pk);
}

static int
decaps(int set, uchar *ss, const uchar *ct, const uchar *sk)
{
	return set == 768 ? mlkem768_decaps(ss, ct, sk) : mlkem1024_decaps(ss, ct, sk);
}

static int
checkek(int set, const uchar *pk)
{
	return set == 768 ? mlkem768_checkek(pk) : mlkem1024_checkek(pk);
}

static int
checkdk(int set, const uchar *sk)
{
	return set == 768 ? mlkem768_checkdk(sk) : mlkem1024_checkdk(sk);
}

static int
allare(const uchar *p, int n, uchar v)
{
	int i;

	for(i = 0; i < n; i++)
		if(p[i] != v)
			return 0;
	return 1;
}

/* set the 12-bit coefficient i of an encoded key to c */
static void
setcoef(uchar *b, int i, int c)
{
	int byte;

	byte = 12*i/8;
	if(i % 2 == 0){
		b[byte] = c & 0xff;
		b[byte+1] = (b[byte+1] & 0xf0) | (c >> 8);
	}else{
		b[byte] = (b[byte] & 0x0f) | ((c & 0xf) << 4);
		b[byte+1] = c >> 4;
	}
}

static int
vectors(const char *file)
{
	static char line[40000];
	static const int badcoef[] = { 3329, 3330, 4095 };
	char *f[10], *t;
	FILE *fp;
	int nf, set, k, lineno, n[8], i, j, nkat[2], pkl, skl, ctl, at[4];
	uchar *d, *z, *ek, *ct, *K, *badct, *badK;
	uchar *pk, *sk, *c, *b, ss[32], ss2[32], m[32], seed[64], g[64], g2[64], h[32];

	fp = fopen(file, "r");
	if(fp == nil){
		fprintf(stderr, "cannot open %s\n", file);
		return 1;
	}
	lineno = 0;
	nkat[0] = nkat[1] = 0;
	while(fgets(line, sizeof line, fp) != nil){
		lineno++;
		if(line[0] == '#')
			continue;
		nf = 0;
		for(t = strtok(line, " \n"); t != nil && nf < 10; t = strtok(nil, " \n"))
			f[nf++] = t;
		if(nf < 2)
			continue;
		set = atoi(f[1]);
		if(strcmp(f[0], "kat") != 0 || nf != 9 || (set != 768 && set != 1024)){
			check(0, "unknown line", set, lineno);
			continue;
		}
		nkat[set == 1024]++;
		k = set == 768 ? 3 : 4;
		pkl = pklen(set);
		skl = sklen(set);
		ctl = ctlen(set);
		d = unhex(f[2], &n[0]);
		z = unhex(f[3], &n[1]);
		ek = unhex(f[4], &n[2]);
		ct = unhex(f[5], &n[3]);
		K = unhex(f[6], &n[4]);
		badct = unhex(f[7], &n[5]);
		badK = unhex(f[8], &n[6]);
		if(n[0] != 32 || n[1] != 32 || n[2] != pkl || n[3] != ctl || n[4] != 32 || n[5] != ctl || n[6] != 32){
			check(0, "malformed kat line", set, lineno);
			continue;
		}
		pk = malloc(pkl);
		sk = malloc(skl);
		c = malloc(ctl);

		/* key generation */
		memmove(seed, d, 32);
		memmove(seed + 32, z, 32);
		queue(seed, 64);
		check(keygen(set, pk, sk) == 0, "keygen fails", set, lineno);
		check(rngqp == 64, "keygen does not take d then z", set, lineno);
		rngqn = 0;
		check(memcmp(pk, ek, pkl) == 0, "encapsulation key differs from ML-KEM.KeyGen_internal(d, z)'s", set, lineno);
		sha3_256(ek, pkl, h);
		check(memcmp(sk + 384*k, ek, pkl) == 0 && memcmp(sk + 384*k + pkl, h, 32) == 0
			&& memcmp(sk + skl - 32, z, 32) == 0, "decapsulation key is not s || ek || H(ek) || z", set, lineno);
		check(checkek(set, pk) == 0 && checkdk(set, sk) == 0, "own keys fail their checks", set, lineno);

		/* decapsulation of another implementation's ciphertext, good and changed */
		memset(ss, 0, 32);
		check(decaps(set, ss, ct, sk) == 0 && memcmp(ss, K, 32) == 0, "OpenSSL's ciphertext does not decapsulate to its secret", set, lineno);
		memset(ss, 0, 32);
		check(decaps(set, ss, badct, sk) == 0 && memcmp(ss, badK, 32) == 0, "a changed ciphertext does not give J(z || c)", set, lineno);

		/* encapsulation: K = G(m || H(ek))[0:32], and it decapsulates */
		for(i = 0; i < 32; i++)
			m[i] = d[i] ^ z[31-i];
		queue(m, 32);
		check(encaps(set, c, ss, ek) == 0, "encaps fails", set, lineno);
		check(rngqp == 32, "encaps does not take 32 bytes for m", set, lineno);
		rngqn = 0;
		memmove(g, m, 32);
		memmove(g + 32, h, 32);
		sha3_512(g, 64, g2);
		check(memcmp(ss, g2, 32) == 0, "encaps's secret is not G(m || H(ek))[0:32]", set, lineno);
		check(decaps(set, ss2, c, sk) == 0 && memcmp(ss, ss2, 32) == 0, "own ciphertext does not decapsulate", set, lineno);

		/* FIPS 203 7.2: an encapsulation key with a coefficient >= q */
		at[0] = 0; at[1] = 1; at[2] = 255; at[3] = 256*k - 1;
		for(i = 0; i < nelem(badcoef); i++)
			for(j = 0; j < 4; j++){
				b = malloc(pkl);
				memmove(b, ek, pkl);
				setcoef(b, at[j], badcoef[i]);
				memset(c, 0xA5, ctl);
				memset(ss, 0xA5, 32);
				check(encaps(set, c, ss, b) == -1 && checkek(set, b) == -1,
					"an encapsulation key with a coefficient not below q is accepted", set, lineno);
				check(allare(c, ctl, 0xA5) && allare(ss, 32, 0xA5), "a refused encapsulation wrote something", set, lineno);
				free(b);
			}

		/* FIPS 203 7.3: a decapsulation key whose H(ek) is not its ek's */
		for(i = 0; i < 2; i++){
			b = malloc(skl);
			memmove(b, sk, skl);
			b[384*k + (i ? pkl + 5 : 7)] ^= 0x10;
			memset(ss, 0xA5, 32);
			check(decaps(set, ss, ct, b) == -1 && checkdk(set, b) == -1,
				"a decapsulation key with ek or H(ek) changed is accepted", set, lineno);
			check(allare(ss, 32, 0xA5), "a refused decapsulation wrote something", set, lineno);
			free(b);
		}
		free(d); free(z); free(ek); free(ct); free(K); free(badct); free(badK);
		free(pk); free(sk); free(c);
	}
	fclose(fp);
	if(nkat[0] == 0 || nkat[1] == 0){
		fprintf(stderr, "FAIL: %s has no vectors for a set\n", file);
		fails++;
	}
	printf("%d and %d known answers (ML-KEM-768, -1024)\n", nkat[0], nkat[1]);
	return fails != 0;
}

/* ctgrind */
static int
ct(int set, const char *what)
{
	int k, rc, i, pkl, skl, ctl;
	uchar *pk, *sk, *c, ss[32], ss2[32], seed[64];

	k = set == 768 ? 3 : 4;
	pkl = pklen(set);
	skl = sklen(set);
	ctl = ctlen(set);
	pk = malloc(pkl);
	sk = malloc(skl);
	c = malloc(ctl);
	if(strcmp(what, "keygen") == 0){
		for(i = 0; i < 64; i++)
			seed[i] = i*7 + 1;
		queue(seed, 64);
		VALGRIND_MAKE_MEM_UNDEFINED(rngq, 64);
		rc = keygen(set, pk, sk);
		VALGRIND_MAKE_MEM_DEFINED(pk, pkl);
		VALGRIND_MAKE_MEM_DEFINED(sk, skl);
		printf("keygen rc %d %02x\n", rc, pk[0]);
		return rc != 0;
	}
	rc = keygen(set, pk, sk);
	if(strcmp(what, "enc") == 0){
		for(i = 0; i < 32; i++)
			seed[i] = i*5 + 3;
		queue(seed, 32);
		VALGRIND_MAKE_MEM_UNDEFINED(rngq, 32);
		rc |= encaps(set, c, ss, pk);
		VALGRIND_MAKE_MEM_DEFINED(c, ctl);
		VALGRIND_MAKE_MEM_DEFINED(ss, 32);
		printf("encaps rc %d %02x\n", rc, c[0]);
		return rc != 0;
	}
	rc |= encaps(set, c, ss, pk);
	if(strcmp(what, "bad") == 0)
		c[17] ^= 4;
	VALGRIND_MAKE_MEM_UNDEFINED(sk, k*384);		/* s-hat */
	VALGRIND_MAKE_MEM_UNDEFINED(sk + skl - 32, 32);	/* z */
	rc |= decaps(set, ss2, c, sk);
	VALGRIND_MAKE_MEM_DEFINED(ss2, 32);
	i = memcmp(ss, ss2, 32) == 0;
	printf("decaps rc %d same %d\n", rc, i);
	return rc != 0 || i != (strcmp(what, "good") == 0);
}

static int
cli(void)
{
	static char line[40000];
	char *f[8], *t;
	int nf, set, n1, n2, rc;
	uchar *a, *b, *pk, *sk, *c, ss[32];

	while(fgets(line, sizeof line, stdin) != nil){
		nf = 0;
		for(t = strtok(line, " \n"); t != nil && nf < 8; t = strtok(nil, " \n"))
			f[nf++] = t;
		if(nf < 3)
			continue;
		set = atoi(f[1]);
		if(set != 768 && set != 1024)
			continue;
		if(strcmp(f[0], "keygen") == 0){
			a = unhex(f[2], &n1);
			queue(a, n1 > 64 ? 64 : n1);
			pk = malloc(pklen(set));
			sk = malloc(sklen(set));
			rc = keygen(set, pk, sk);
			rngqn = 0;
			printf("rc %d\n", rc);
			phex("ek", pk, pklen(set));
			phex("dk", sk, sklen(set));
			free(a); free(pk); free(sk);
		}else if(strcmp(f[0], "encaps") == 0 && nf >= 4){
			a = unhex(f[2], &n1);
			b = unhex(f[3], &n2);
			queue(b, n2 > 32 ? 32 : n2);
			c = malloc(ctlen(set));
			memset(c, 0, ctlen(set));
			memset(ss, 0, 32);
			rc = n1 == pklen(set) ? encaps(set, c, ss, a) : -2;
			rngqn = 0;
			printf("rc %d\n", rc);
			phex("ct", c, ctlen(set));
			phex("ss", ss, 32);
			free(a); free(b); free(c);
		}else if(strcmp(f[0], "decaps") == 0 && nf >= 4){
			a = unhex(f[2], &n1);
			b = unhex(f[3], &n2);
			memset(ss, 0, 32);
			rc = n1 == sklen(set) && n2 == ctlen(set) ? decaps(set, ss, b, a) : -2;
			printf("rc %d\n", rc);
			phex("ss", ss, 32);
			free(a); free(b);
		}
		fflush(stdout);
	}
	return 0;
}

int
main(int argc, char **argv)
{
	if(argc >= 4 && strcmp(argv[1], "ct") == 0)
		return ct(atoi(argv[2]), argv[3]);
	if(argc >= 2 && strcmp(argv[1], "cli") == 0)
		return cli();
	if(argc >= 2)
		return vectors(argv[1]);
	fprintf(stderr, "usage: kemtest vectors.txt | ct SET keygen|enc|good|bad | cli\n");
	return 2;
}
