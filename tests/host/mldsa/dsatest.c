/*
 * libsec/mldsa*.c (ML-DSA-65 and -87, FIPS 204) on the host, built by
 * tests/host/mldsa_test.sh with the library's sources.
 *
 * mldsa65_sign and mldsa87_sign are the standard's ML-DSA.Sign
 * (Algorithm 2: the pure signature, M' = 0 || |ctx| || ctx || M) with an
 * empty context string and rnd from the generator, the _ctx forms with
 * a context string; mldsa_sign_internal and its fellows are Algorithms
 * 6, 7 and 8 with the randomness given.  (The plain functions used to
 * be Sign_internal on the caller's message.)
 *
 *   dsatest vectors.txt
 *		OpenSSL's answers (tests/host/mldsa/gen.py): key generation
 *		from the seed gives its public and secret key; signing
 *		takes 32 bytes from the generator as rnd and, given
 *		OpenSSL's, makes OpenSSL's pure signature byte for byte,
 *		with and without a context string; so does Sign_internal
 *		on M' whole; the signature verifies, and not for another
 *		message, context or key, with a bit changed, or as the
 *		other interface's; signing twice gives two signatures
 *		(hedged) that both verify.  Everything is in heap buffers
 *		exactly its length.
 *   dsatest rounds	built with -DMLDSA_MAXROUNDS=1: signing gives up after
 *		the round it is allowed, with nothing written, and a
 *		signature it does make verifies.  (The loop had no bound.)
 *   dsatest cli	keygen, sign and verify on standard input, for cross.py
 *   dsatest ct SET	built -DCTGRIND, under valgrind: a signature made
 *		with the secret key and the randomness undefined to
 *		memcheck, which reports each branch and address that
 *		depends on them; mldsa_test.sh holds the reports to the
 *		decisions the source marks as public
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
#endif

/* genrandom: the bytes a test queued (xi, rnd), else the host's */
static uchar rngq[64];
static int rngqn, rngqp;
static long rngbytes;

void
genrandom(uchar *p, int n)
{
	static int fd = -1;

	rngbytes += n;
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

/*
 * the signatures' hedging bytes are asked for here (libsec.h: -1 and
 * nothing when there is no generator); norng makes that the answer
 */
int	norng;

int
genrandomtry(uchar *p, int n)
{
	if(norng)
		return -1;
	genrandom(p, n);
	return 0;
}

static void
queue(const uchar *p, int n)
{
	if(n > sizeof rngq)
		n = sizeof rngq;
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
			fprintf(stderr, "FAIL: ML-DSA-%d: %s (vectors line %d)\n", set, what, lineno);
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

static void
phex(const char *t, const uchar *p, int n)
{
	int i;

	printf("%s ", t);
	for(i = 0; i < n; i++)
		printf("%02x", p[i]);
	printf("\n");
}

static int pklen(int set) { return set == 65 ? MLDSA65_PKLEN : MLDSA87_PKLEN; }
static int sklen(int set) { return set == 65 ? MLDSA65_SKLEN : MLDSA87_SKLEN; }
static int siglen(int set) { return set == 65 ? MLDSA65_SIGLEN : MLDSA87_SIGLEN; }

static int
keygen(int set, uchar *pk, uchar *sk)
{
	return set == 65 ? mldsa65_keygen(pk, sk) : mldsa87_keygen(pk, sk);
}

static int
sign(int set, uchar *sig, const uchar *msg, int n, const uchar *sk)
{
	return set == 65 ? mldsa65_sign(sig, msg, n, sk) : mldsa87_sign(sig, msg, n, sk);
}

static int
signctx(int set, uchar *sig, const uchar *msg, int n, const uchar *ctx, int nctx, const uchar *sk)
{
	return set == 65 ? mldsa65_sign_ctx(sig, msg, n, ctx, nctx, sk) : mldsa87_sign_ctx(sig, msg, n, ctx, nctx, sk);
}

static int
verifyctx(int set, const uchar *sig, const uchar *msg, int n, const uchar *ctx, int nctx, const uchar *pk)
{
	uchar *s, *p, *m, *c;
	int r;

	s = malloc(siglen(set));
	p = malloc(pklen(set));
	m = malloc(n ? n : 1);
	c = malloc(nctx ? nctx : 1);
	memmove(s, sig, siglen(set));
	memmove(p, pk, pklen(set));
	memmove(m, msg, n);
	memmove(c, ctx, nctx);
	r = set == 65 ? mldsa65_verify_ctx(s, m, n, c, nctx, p) : mldsa87_verify_ctx(s, m, n, c, nctx, p);
	free(s); free(p); free(m); free(c);
	return r;
}

/* in buffers exactly as long as the signature and the key */
static int
verify(int set, const uchar *sig, const uchar *msg, int n, const uchar *pk)
{
	uchar *s, *p, *m;
	int r;

	s = malloc(siglen(set));
	p = malloc(pklen(set));
	m = malloc(n ? n : 1);
	memmove(s, sig, siglen(set));
	memmove(p, pk, pklen(set));
	memmove(m, msg, n);
	r = set == 65 ? mldsa65_verify(s, m, n, p) : mldsa87_verify(s, m, n, p);
	free(s); free(p); free(m);
	return r;
}

static int
vectors(const char *file)
{
	static char line[40000];
	char *f[10], *t;
	FILE *fp;
	int nf, set, lineno, n[8], i, l, nkat[2], nexact, nsig, nctx, nint, L, expect;
	static uchar zero[32];
	uchar *xi, *pk, *want, *msg, *rnd, *sig, *mypk, *mysk, *mysig, *b, sum[32];
	long before;
	unsigned x;

	fp = fopen(file, "r");
	if(fp == nil){
		fprintf(stderr, "cannot open %s\n", file);
		return 1;
	}
	lineno = 0;
	nkat[0] = nkat[1] = nexact = nsig = nctx = nint = 0;
	x = 4321;
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
		if(set != 65 && set != 87){
			check(0, "unknown parameter set", set, lineno);
			continue;
		}
		L = siglen(set);
		if(strcmp(f[0], "kat") == 0 && nf == 8){
			nkat[set == 87]++;
			xi = unhex(f[2], &n[0]);
			pk = unhex(f[3], &n[1]);
			want = unhex(f[4], &n[2]);
			msg = unhex(f[5], &n[3]);
			rnd = unhex(f[6], &n[4]);
			sig = unhex(f[7], &n[5]);
			if(n[0] != 32 || n[1] != pklen(set) || (n[2] != 32 && n[2] != 0) || (n[4] != 32 && n[4] != 0) || n[5] != L){
				check(0, "malformed kat line", set, lineno);
				continue;
			}
			mypk = malloc(pklen(set));
			mysk = malloc(sklen(set));
			mysig = malloc(L);

			queue(xi, 32);
			check(keygen(set, mypk, mysk) == 0, "keygen fails", set, lineno);
			check(rngqp == 32, "keygen does not take 32 bytes for xi", set, lineno);
			rngqn = 0;
			check(memcmp(mypk, pk, n[1]) == 0, "public key differs from ML-DSA.KeyGen_internal(xi)'s", set, lineno);
			if(n[2] == 32){
				shake256(mysk, sklen(set), sum, 32);
				check(memcmp(sum, want, 32) == 0, "secret key differs from ML-DSA.KeyGen_internal(xi)'s", set, lineno);
			}

			/* OpenSSL's signature verifies */
			check(verify(set, sig, msg, n[3], pk) == 1, "OpenSSL's signature refused", set, lineno);

			/* given OpenSSL's rnd, signing makes OpenSSL's signature */
			if(n[4] == 32){
				nexact++;
				memset(mysig, 0, L);
				queue(rnd, 32);
				before = rngbytes;
				check(sign(set, mysig, msg, n[3], mysk) == 0, "sign fails", set, lineno);
				check(rngbytes - before == 32 && rngqp == 32, "signing does not take 32 random bytes for rnd", set, lineno);
				rngqn = 0;
				check(memcmp(mysig, sig, L) == 0, "signature differs from ML-DSA.Sign(sk, M, empty context)'s with the same rnd", set, lineno);
			}

			/* hedged: two signatures of one message differ, and both verify */
			b = malloc(L);
			check(sign(set, mysig, msg, n[3], mysk) == 0 && sign(set, b, msg, n[3], mysk) == 0, "sign fails", set, lineno);
			check(memcmp(mysig, b, L) != 0, "two signatures of one message are the same: no randomness went into them", set, lineno);
			check(verify(set, mysig, msg, n[3], pk) == 1 && verify(set, b, msg, n[3], pk) == 1, "own signature refused", set, lineno);

			/* no generator: no signature, said, with nothing written */
			memset(b, 0xA5, L);
			norng = 1;
			check(sign(set, b, msg, n[3], mysk) != 0, "a signature was made with no generator to hedge it", set, lineno);
			norng = 0;
			for(i = 0; i < L && b[i] == 0xA5; i++)
				;
			check(i == L, "signing with no generator wrote to the signature", set, lineno);

			/* another message, another key, a bit changed */
			if(n[3] > 0){
				msg[0] ^= 1;
				check(verify(set, sig, msg, n[3], pk) == 0, "signature accepted for another message", set, lineno);
				msg[0] ^= 1;
			}
			check(verify(set, sig, msg, n[3] + 0, mypk) == 1, "signature refused under the generated key", set, lineno);
			pk[40] ^= 2;
			check(verify(set, sig, msg, n[3], pk) == 0, "signature accepted under a changed key", set, lineno);
			pk[40] ^= 2;
			for(i = 0; i < 60; i++){
				x = x*1103515245 + 12345;
				l = i == 0 ? 0 : i == 1 ? L - 1 : (x >> 8) % L;
				memmove(b, sig, L);
				b[l] ^= 1 << ((x >> 4) & 7);
				check(verify(set, b, msg, n[3], pk) == 0, "signature with one bit changed accepted", set, lineno);
			}
			free(b);
			free(xi); free(pk); free(want); free(msg); free(rnd); free(sig); free(mypk); free(mysk); free(mysig);
		}else if(strcmp(f[0], "ctx") == 0 && nf == 7){
			/* ctx SET XI MSG CTX RND SIG: the pure signature under a context string */
			nctx++;
			xi = unhex(f[2], &n[0]);
			msg = unhex(f[3], &n[1]);
			b = unhex(f[4], &n[2]);
			rnd = unhex(f[5], &n[3]);
			sig = unhex(f[6], &n[4]);
			if(n[0] != 32 || n[3] != 32 || n[4] != L){
				check(0, "malformed ctx line", set, lineno);
				continue;
			}
			mypk = malloc(pklen(set));
			mysk = malloc(sklen(set));
			mysig = malloc(L);
			check(mldsa_keygen_internal(set, mypk, mysk, xi) == 0, "keygen fails", set, lineno);
			memset(mysig, 0, L);
			queue(rnd, 32);
			if(n[2] > 255){
				/* FIPS 204 Algorithm 2 line 1: a context string is at most 255 bytes */
				memset(mysig, 0xA5, L);
				check(signctx(set, mysig, msg, n[1], b, n[2], mysk) != 0, "a context string of more than 255 bytes signed under", set, lineno);
				for(i = 0; i < L; i++)
					if(mysig[i] != 0xA5)
						break;
				check(i == L, "a refused context string wrote to the signature", set, lineno);
				check(verifyctx(set, sig, msg, n[1], b, n[2], mypk) == 0, "a context string of more than 255 bytes verified under", set, lineno);
			}else{
				check(signctx(set, mysig, msg, n[1], b, n[2], mysk) == 0, "sign_ctx fails", set, lineno);
				check(memcmp(mysig, sig, L) == 0, "signature differs from ML-DSA.Sign(sk, M, ctx)'s with the same rnd", set, lineno);
				check(verifyctx(set, sig, msg, n[1], b, n[2], mypk) == 1, "OpenSSL's signature under a context string refused", set, lineno);
				if(n[2] > 0){
					check(verify(set, sig, msg, n[1], mypk) == 0, "a signature under a context string accepted with none", set, lineno);
					b[0] ^= 1;
					check(verifyctx(set, sig, msg, n[1], b, n[2], mypk) == 0, "a signature accepted under another context string", set, lineno);
					check(verifyctx(set, sig, msg, n[1], b, n[2] - 1, mypk) == 0, "a signature accepted under a shorter context string", set, lineno);
				}
			}
			rngqn = 0;
			free(xi); free(msg); free(b); free(rnd); free(sig); free(mypk); free(mysk); free(mysig);
		}else if(strcmp(f[0], "int") == 0 && nf == 6){
			/* int SET XI MP RND SIG: Sign_internal on M' whole */
			nint++;
			xi = unhex(f[2], &n[0]);
			msg = unhex(f[3], &n[1]);
			rnd = unhex(f[4], &n[2]);
			sig = unhex(f[5], &n[3]);
			if(n[0] != 32 || n[2] != 32 || n[3] != L){
				check(0, "malformed int line", set, lineno);
				continue;
			}
			mypk = malloc(pklen(set));
			mysk = malloc(sklen(set));
			mysig = malloc(L);
			check(mldsa_keygen_internal(set, mypk, mysk, xi) == 0, "keygen fails", set, lineno);
			before = rngbytes;
			check(mldsa_sign_internal(set, mysig, msg, n[1], nil, rnd, mysk) == 0, "sign_internal fails", set, lineno);
			check(rngbytes == before, "sign_internal took bytes from the generator", set, lineno);
			check(memcmp(mysig, sig, L) == 0, "signature differs from Sign_internal(sk, M', rnd)'s", set, lineno);
			check(mldsa_verify_internal(set, sig, msg, n[1], nil, mypk) == 1, "verify_internal refuses Sign_internal's signature", set, lineno);
			/* the internal interface's signature of M is not the pure signature of M */
			check(verify(set, sig, msg, n[1], mypk) == 0, "Sign_internal's signature of M accepted as ML-DSA.Sign's", set, lineno);
			/* and the pure signature is the internal one of 0 || 0 || M */
			b = malloc(n[1] + 2);
			b[0] = b[1] = 0;
			memmove(b + 2, msg, n[1]);
			queue(zero, 32);
			check(sign(set, mysig, msg, n[1], mysk) == 0, "sign fails", set, lineno);
			rngqn = 0;
			check(mldsa_verify_internal(set, mysig, b, n[1] + 2, nil, mypk) == 1, "the pure signature is not Sign_internal's on 0 || 0 || M", set, lineno);
			free(b);
			free(xi); free(msg); free(rnd); free(sig); free(mypk); free(mysk); free(mysig);
		}else if(strcmp(f[0], "sig") == 0 && nf == 7){
			nsig++;
			expect = atoi(f[2]);
			pk = unhex(f[4], &n[0]);
			msg = unhex(f[5], &n[1]);
			sig = unhex(f[6], &n[2]);
			if(n[0] != pklen(set) || n[2] != L){
				check(0, "malformed sig line", set, lineno);
				continue;
			}
			if(verify(set, sig, msg, n[1], pk) != expect){
				fails++;
				fprintf(stderr, "FAIL: ML-DSA-%d: a %s signature is %s (vectors line %d)\n",
					set, f[3], expect ? "refused" : "accepted", lineno);
			}
			free(pk); free(msg); free(sig);
		}else
			check(0, "unknown line", set, lineno);
	}
	fclose(fp);
	if(nkat[0] == 0 || nkat[1] == 0){
		fprintf(stderr, "FAIL: %s has no vectors for a set\n", file);
		fails++;
	}
	if(nctx == 0 || nint == 0){
		fprintf(stderr, "FAIL: %s has no context-string or internal-interface vectors\n", file);
		fails++;
	}
	printf("%d and %d known answers (ML-DSA-65, -87), %d pure signatures made byte for byte, %d under context strings, %d by Sign_internal, %d framings\n", nkat[0], nkat[1], nexact, nctx, nint, nsig);
	return fails != 0;
}

/*
 * With one round allowed (-DMLDSA_MAXROUNDS=1) most signings must give
 * up: a round is accepted about once in five.
 */
static int
rounds(void)
{
	static uchar pk[MLDSA87_PKLEN], sk[MLDSA87_SKLEN], sig[MLDSA87_SIGLEN];
	uchar msg[4];
	int set, i, j, rc, ok, gaveup, clean;

	for(set = 65; set <= 87; set += 22){
		if(keygen(set, pk, sk) != 0)
			return 1;
		ok = gaveup = 0;
		clean = 1;
		for(i = 0; i < 60; i++){
			msg[0] = i; msg[1] = set; msg[2] = 0; msg[3] = 1;
			memset(sig, 0xA5, siglen(set));
			rc = sign(set, sig, msg, 4, sk);
			if(rc == 0){
				ok++;
				if(verify(set, sig, msg, 4, pk) != 1){
					fprintf(stderr, "FAIL: ML-DSA-%d: a signature made in one round does not verify\n", set);
					fails++;
				}
			}else{
				gaveup++;
				for(j = 0; j < siglen(set); j++)
					if(sig[j] != 0xA5)
						clean = 0;
			}
		}
		printf("ML-DSA-%d, one round allowed: %d of 60 signings gave up, %d signed\n", set, gaveup, ok);
		if(gaveup == 0){
			fprintf(stderr, "FAIL: ML-DSA-%d: the rejection loop has no bound (60 signings in one round each?)\n", set);
			fails++;
		}
		if(!clean){
			fprintf(stderr, "FAIL: ML-DSA-%d: a signing that gave up wrote to the signature\n", set);
			fails++;
		}
	}
	return fails != 0;
}

static int
cli(void)
{
	static char line[40000];
	char *f[8], *t;
	int nf, set, n1, n2, n3, n4, rc;
	uchar *a, *b, *c, *d, *pk, *sk, *sig;

	while(fgets(line, sizeof line, stdin) != nil){
		nf = 0;
		for(t = strtok(line, " \n"); t != nil && nf < 8; t = strtok(nil, " \n"))
			f[nf++] = t;
		if(nf < 3)
			continue;
		set = atoi(f[1]);
		if(set != 65 && set != 87)
			continue;
		if(strcmp(f[0], "keygen") == 0){
			a = unhex(f[2], &n1);
			queue(a, n1);
			pk = malloc(pklen(set));
			sk = malloc(sklen(set));
			rc = keygen(set, pk, sk);
			rngqn = 0;
			printf("rc %d\n", rc);
			phex("pk", pk, pklen(set));
			phex("sk", sk, sklen(set));
			free(a); free(pk); free(sk);
		}else if(strcmp(f[0], "sign") == 0 && nf >= 5){
			/* sign SET SK MSG RND [CTX] */
			a = unhex(f[2], &n1);
			b = unhex(f[3], &n2);
			c = unhex(f[4], &n3);
			d = unhex(nf >= 6 ? f[5] : "-", &n4);
			queue(c, n3);
			sig = malloc(siglen(set));
			memset(sig, 0, siglen(set));
			if(n1 != sklen(set))
				rc = -2;
			else if(nf >= 6)
				rc = signctx(set, sig, b, n2, d, n4, a);
			else
				rc = sign(set, sig, b, n2, a);
			rngqn = 0;
			printf("rc %d\n", rc);
			phex("sig", sig, siglen(set));
			free(a); free(b); free(c); free(d); free(sig);
		}else if(strcmp(f[0], "verify") == 0 && nf >= 5){
			/* verify SET PK MSG SIG [CTX] */
			a = unhex(f[2], &n1);
			b = unhex(f[3], &n2);
			c = unhex(f[4], &n3);
			d = unhex(nf >= 6 ? f[5] : "-", &n4);
			if(n1 != pklen(set) || n3 != siglen(set))
				rc = -2;
			else if(nf >= 6)
				rc = verifyctx(set, c, b, n2, d, n4, a);
			else
				rc = verify(set, c, b, n2, a);
			printf("ok %d\n", rc);
			free(a); free(b); free(c); free(d);
		}
		fflush(stdout);
	}
	return 0;
}

/*
 * Signing with the secret key undefined to memcheck, which then
 * reports every branch and address that depends on it.  The key is
 * made from a fixed seed and the randomness is fixed, so the reports
 * are the same from run to run.
 */
static int
ct(int set)
{
#ifdef CTGRIND
	static uchar pk[MLDSA87_PKLEN], sk[MLDSA87_SKLEN], sig[MLDSA87_SIGLEN], msg[64], rnd[32];
	uchar xi[32];
	int i, rc;

	for(i = 0; i < 32; i++)
		xi[i] = i + set;
	for(i = 0; i < sizeof msg; i++)
		msg[i] = 3*i;
	if(mldsa_keygen_internal(set, pk, sk, xi) != 0)
		return 2;
	/*
	 * the secret key less its first 32 bytes (rho, which is in the
	 * public key) and tr (the public key's digest): K, s1, s2, t0;
	 * and the signing randomness
	 */
	VALGRIND_MAKE_MEM_UNDEFINED(sk + 32, 32);
	VALGRIND_MAKE_MEM_UNDEFINED(sk + 128, sklen(set) - 128);
	memset(rnd, 0x5C, sizeof rnd);
	VALGRIND_MAKE_MEM_UNDEFINED(rnd, sizeof rnd);
	queue(rnd, 32);
	rc = sign(set, sig, msg, sizeof msg, sk);
	VALGRIND_MAKE_MEM_DEFINED(sig, siglen(set));
	VALGRIND_MAKE_MEM_DEFINED(&rc, sizeof rc);
	if(rc != 0 || verify(set, sig, msg, sizeof msg, pk) != 1){
		fprintf(stderr, "FAIL: ML-DSA-%d: signing with the key marked secret\n", set);
		return 1;
	}
	printf("ML-DSA-%d signed\n", set);
	return 0;
#else
	fprintf(stderr, "dsatest: not built with -DCTGRIND\n");
	return 2;
#endif
}

int
main(int argc, char **argv)
{
	if(argc >= 3 && strcmp(argv[1], "ct") == 0)
		return ct(atoi(argv[2]));
	if(argc >= 2 && strcmp(argv[1], "rounds") == 0)
		return rounds();
	if(argc >= 2 && strcmp(argv[1], "cli") == 0)
		return cli();
	if(argc >= 2)
		return vectors(argv[1]);
	fprintf(stderr, "usage: dsatest vectors.txt | rounds | cli\n");
	return 2;
}
