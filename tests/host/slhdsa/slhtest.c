/*
 * libsec/slhdsa*.c (SLH-DSA-SHAKE-192s and -256s, FIPS 205) on the host,
 * built by tests/host/slhdsa_test.sh with the library's sources.
 *
 *   slhtest vectors.txt [quick]
 *		the known answers (tests/host/slhdsa/gen.py: the FIPS 205
 *		reference's, equal to OpenSSL's): key generation from the
 *		three seeds gives the public and secret key; the
 *		deterministic signature of a message (slh_sign_internal
 *		on M' with no added randomness) is the standard's byte for
 *		byte; signing is hedged: it takes n bytes from the
 *		generator as opt_rand, makes the standard's signature for
 *		them (hkat lines: with and without a context string),
 *		and two signatures of one message differ (it was the
 *		deterministic variant); a signature made elsewhere
 *		verifies, and what is not a pure signature with an empty
 *		context is refused: the format this code made before it
 *		was held to the standard, the internal interface on the
 *		bare message, a context string; signatures cut short,
 *		lengthened and changed are refused, each in a heap buffer
 *		exactly its length.  quick: one kat a set (the sanitizers'
 *		build).
 *   slhtest forge
 *		a WOTS+ signature chained forward with the public F to a
 *		message whose digits are all at least the signed one's and
 *		sum to 256 more is not that key's signature, alone and
 *		under an XMSS tree's root.  The checksum is what stops it,
 *		and the code before signed only the checksum mod 256.
 *   slhtest cli	keygen, sign and verify on standard input, for cross.py
 */
#include "os.h"
#include <libsec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

/* genrandom: the bytes a test queued (key generation's seeds, opt_rand), else the host's */
static uchar rngq[256];
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

static int fails;

static void
check(int ok, const char *what, int set, int lineno)
{
	if(!ok){
		fails++;
		if(fails < 20)
			fprintf(stderr, "FAIL: SLH-DSA-SHAKE-%ds: %s (vectors line %d)\n", set, what, lineno);
	}
}

/* hex to a heap buffer of exactly its length ("-" is no bytes) */
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

static int pklen(int set) { return set == 192 ? SLHDSA192S_PKLEN : SLHDSA256S_PKLEN; }
static int sklen(int set) { return set == 192 ? SLHDSA192S_SKLEN : SLHDSA256S_SKLEN; }
static int siglen(int set) { return set == 192 ? SLHDSA192S_SIGLEN : SLHDSA256S_SIGLEN; }

static int
keygen(int set, uchar *pk, uchar *sk)
{
	return set == 192 ? slhdsa192s_keygen(pk, sk) : slhdsa256s_keygen(pk, sk);
}

static int
sign(int set, uchar *sig, const uchar *msg, int n, const uchar *sk)
{
	return set == 192 ? slhdsa192s_sign(sig, msg, n, sk) : slhdsa256s_sign(sig, msg, n, sk);
}

static int
verify(int set, const uchar *sig, int siglen, const uchar *msg, int n, const uchar *pk)
{
	return set == 192 ? slhdsa192s_verify(sig, siglen, msg, n, pk) : slhdsa256s_verify(sig, siglen, msg, n, pk);
}

static int
signctx(int set, uchar *sig, const uchar *msg, int n, const uchar *ctx, int nctx, const uchar *sk)
{
	return set == 192 ? slhdsa192s_sign_ctx(sig, msg, n, ctx, nctx, sk) : slhdsa256s_sign_ctx(sig, msg, n, ctx, nctx, sk);
}

static int
verifyctx(int set, const uchar *sig, int siglen, const uchar *msg, int n, const uchar *ctx, int nctx, const uchar *pk)
{
	return set == 192 ? slhdsa192s_verify_ctx(sig, siglen, msg, n, ctx, nctx, pk) : slhdsa256s_verify_ctx(sig, siglen, msg, n, ctx, nctx, pk);
}

/* M' of the pure signature with an empty context string: 0 || 0 || M */
static uchar*
mprime(const uchar *msg, int n)
{
	uchar *m;

	m = malloc(n + 2);
	m[0] = m[1] = 0;
	memmove(m + 2, msg, n);
	return m;
}

/* verify a copy of sig[0:n] in a buffer of exactly n bytes */
static int
verifyexact(int set, const uchar *sig, int n, const uchar *msg, int msglen, const uchar *pk)
{
	uchar *b;
	int r;

	b = malloc(n ? n : 1);
	if(b == nil)
		abort();
	memmove(b, sig, n);
	r = verify(set, b, n, msg, msglen, pk);
	free(b);
	return r;
}

static int
vectors(const char *file, int quick)
{
	static char line[200000];
	char *f[8];
	FILE *fp;
	int nf, set, lineno, n, n1, n2, n3, n4, i, l, nkat[2], nsig, nref, nhkat, expect, L;
	long before;
	uchar *seed, *pk, *sk, *msg, *want, *sig, *mypk, *mysk, sum[32], *b;
	char *t;
	unsigned x;

	fp = fopen(file, "r");
	if(fp == nil){
		fprintf(stderr, "cannot open %s\n", file);
		return 1;
	}
	lineno = 0;
	nkat[0] = nkat[1] = nsig = nref = nhkat = 0;
	x = 12345;
	while(fgets(line, sizeof line, fp) != nil){
		lineno++;
		if(line[0] == '#')
			continue;
		nf = 0;
		for(t = strtok(line, " \n"); t != nil && nf < 8; t = strtok(nil, " \n"))
			f[nf++] = t;
		if(nf < 2)
			continue;
		set = atoi(f[1]);
		if(set != 192 && set != 256){
			check(0, "unknown parameter set", set, lineno);
			continue;
		}
		n = set == 192 ? 24 : 32;
		L = siglen(set);
		if(strcmp(f[0], "kat") == 0 && nf == 7){
			if(quick && nkat[set == 256]++ > 0)
				continue;
			if(!quick)
				nkat[set == 256]++;
			seed = unhex(f[2], &n1);
			pk = unhex(f[3], &n2);
			sk = unhex(f[4], &n3);
			msg = unhex(f[5], &n4);
			want = unhex(f[6], &i);
			check(n1 == 3*n && n2 == pklen(set) && n3 == sklen(set) && i == 32, "malformed kat line", set, lineno);
			mypk = malloc(pklen(set));
			mysk = malloc(sklen(set));
			sig = malloc(L);
			memmove(rngq, seed, n1);
			rngqn = n1;
			rngqp = 0;
			check(keygen(set, mypk, mysk) == 0, "keygen fails", set, lineno);
			check(rngqp == 3*n, "keygen does not take SK.seed, SK.prf, PK.seed in that order", set, lineno);
			rngqn = 0;
			check(memcmp(mypk, pk, n2) == 0, "public key differs from FIPS 205 slh_keygen_internal's", set, lineno);
			check(memcmp(mysk, sk, n3) == 0, "secret key differs from FIPS 205 slh_keygen_internal's", set, lineno);
			/* the deterministic variant: slh_sign_internal on M', no added randomness */
			memset(sig, 0, L);
			b = mprime(msg, n4);
			before = rngbytes;
			check(slhdsa_sign_internal(set, sig, b, n4 + 2, nil, sk) == 0, "sign_internal fails", set, lineno);
			check(rngbytes == before, "sign_internal took bytes from the generator", set, lineno);
			shake256(sig, L, sum, 32);
			check(memcmp(sum, want, 32) == 0, "signature differs from FIPS 205 slh_sign's (pure, empty context, deterministic)", set, lineno);
			check(verify(set, sig, L, msg, n4, pk) == 1, "own signature refused", set, lineno);
			check(slhdsa_verify_internal(set, sig, L, b, n4 + 2, pk) == 1, "verify_internal refuses the signature of M'", set, lineno);
			if(nkat[set == 256] == 2){
				/*
				 * hedged (FIPS 205 Algorithm 22 line 5): signing takes n
				 * bytes from the generator, the signature is
				 * slh_sign_internal's with them as opt_rand, and is not
				 * the deterministic one
				 */
				uchar *h1, *h2;

				h1 = malloc(L);
				h2 = malloc(L);
				memset(rngq, 0x5A, n);
				rngqn = n;
				rngqp = 0;
				before = rngbytes;
				check(sign(set, h1, msg, n4, sk) == 0, "sign fails", set, lineno);
				check(rngbytes - before == n && rngqp == n, "signing does not take n random bytes for opt_rand", set, lineno);
				rngqn = 0;
				check(slhdsa_sign_internal(set, h2, b, n4 + 2, rngq, sk) == 0, "sign_internal fails", set, lineno);
				check(memcmp(h1, h2, L) == 0, "signing is not slh_sign_internal with the generator's bytes as opt_rand", set, lineno);
				check(memcmp(h1, sig, L) != 0, "signing is deterministic: opt_rand is not the generator's bytes", set, lineno);
				check(verify(set, h1, L, msg, n4, pk) == 1, "own hedged signature refused", set, lineno);
				/* and with the generator's own bytes, two signatures differ */
				check(sign(set, h2, msg, n4, sk) == 0, "sign fails", set, lineno);
				check(memcmp(h1, h2, L) != 0 && memcmp(h2, sig, L) != 0, "two signatures of one message are the same: no randomness went into them", set, lineno);
				check(verify(set, h2, L, msg, n4, pk) == 1, "own hedged signature refused", set, lineno);
				free(h1); free(h2);
			}
			free(b);
			/* another message, another key (the seed's bytes as one) */
			if(n4 > 0){
				msg[0] ^= 1;
				check(verify(set, sig, L, msg, n4, pk) == 0, "signature accepted for another message", set, lineno);
				msg[0] ^= 1;
			}
			check(verify(set, sig, L, msg, n4, seed) == 0, "signature accepted under another key", set, lineno);
			free(seed); free(pk); free(sk); free(msg); free(want); free(mypk); free(mysk); free(sig);
		}else if(strcmp(f[0], "hkat") == 0 && nf == 7){
			/* hkat SET SK MSG CTX ADDRND SIGSUM */
			if(quick && nhkat > 0)
				continue;
			nhkat++;
			sk = unhex(f[2], &n1);
			msg = unhex(f[3], &n2);
			b = unhex(f[4], &n3);
			seed = unhex(f[5], &n4);
			want = unhex(f[6], &i);
			check(n1 == sklen(set) && n4 == n && i == 32, "malformed hkat line", set, lineno);
			sig = malloc(L);
			memmove(rngq, seed, n);
			rngqn = n;
			rngqp = 0;
			check(signctx(set, sig, msg, n2, b, n3, sk) == 0, "sign_ctx fails", set, lineno);
			check(rngqp == n, "signing does not take n random bytes for opt_rand", set, lineno);
			rngqn = 0;
			shake256(sig, L, sum, 32);
			check(memcmp(sum, want, 32) == 0, "signature differs from FIPS 205 slh_sign's with the same opt_rand", set, lineno);
			check(verifyctx(set, sig, L, msg, n2, b, n3, sk + 2*n) == 1, "own signature refused", set, lineno);
			if(n3 > 0){
				check(verify(set, sig, L, msg, n2, sk + 2*n) == 0, "a signature under a context string accepted with none", set, lineno);
				check(verifyctx(set, sig, L, msg, n2, b, n3 - 1, sk + 2*n) == 0, "a signature accepted under a shorter context string", set, lineno);
				/* FIPS 205 Algorithm 22 line 1: at most 255 bytes of context */
				mypk = malloc(256);
				memset(mypk, 'c', 256);
				memset(sig, 0xA5, L);
				check(signctx(set, sig, msg, n2, mypk, 256, sk) != 0, "a context string of 256 bytes signed under", set, lineno);
				check(sig[0] == 0xA5 && sig[L-1] == 0xA5, "a refused context string wrote to the signature", set, lineno);
				check(verifyctx(set, sig, L, msg, n2, mypk, 256, sk + 2*n) == 0, "a context string of 256 bytes verified under", set, lineno);
				free(mypk);
			}
			free(sk); free(msg); free(b); free(seed); free(want); free(sig);
		}else if(strcmp(f[0], "sig") == 0 && nf == 7){
			nsig++;
			expect = atoi(f[2]);
			pk = unhex(f[4], &n1);
			msg = unhex(f[5], &n2);
			sig = unhex(f[6], &n3);
			check(n1 == pklen(set) && n3 == L, "malformed sig line", set, lineno);
			if(verify(set, sig, n3, msg, n2, pk) != expect){
				fails++;
				fprintf(stderr, "FAIL: SLH-DSA-SHAKE-%ds: a %s signature is %s (vectors line %d)\n",
					set, f[3], expect ? "refused" : "accepted", lineno);
			}
			if(expect == 1){
				/*
				 * a signature made elsewhere, at other lengths and
				 * changed: every read is inside a buffer of exactly
				 * the length given
				 */
				nref++;
				static const int cut[] = { 0, 1, -1, -2, -3, -4, -5 };
				for(i = 0; i < nelem(cut); i++){
					l = cut[i];
					if(l == -1) l = n;
					else if(l == -2) l = n + 1;
					else if(l == -3) l = L - 1;
					else if(l == -4) l = L - n;
					else if(l == -5) l = L/2;
					check(verifyexact(set, sig, l, msg, n2, pk) == 0, "signature cut short accepted", set, lineno);
				}
				b = malloc(2*L);
				memmove(b, sig, L);
				b[L] = 0;
				check(verifyexact(set, b, L + 1, msg, n2, pk) == 0, "signature one byte longer accepted", set, lineno);
				memmove(b + L, sig, L);
				check(verifyexact(set, b, 2*L, msg, n2, pk) == 0, "signature twice accepted", set, lineno);
				/* one bit changed: in R, in FORS, in each layer, the last byte */
				for(i = 0; i < (quick ? 12 : 40); i++){
					x = x*1103515245 + 12345;
					l = i == 0 ? 0 : i == 1 ? L - 1 : (x >> 8) % L;
					memmove(b, sig, L);
					b[l] ^= 1 << ((x >> 4) & 7);
					check(verifyexact(set, b, L, msg, n2, pk) == 0, "signature with one bit changed accepted", set, lineno);
				}
				free(b);
			}
			free(pk); free(msg); free(sig);
		}else
			check(0, "unknown line", set, lineno);
	}
	fclose(fp);
	if(nkat[0] == 0 || nkat[1] == 0 || nref < 2 || nsig < 4){
		fprintf(stderr, "FAIL: %s has too few vectors (%d and %d kat, %d sig)\n", file, nkat[0], nkat[1], nsig);
		fails++;
	}
	if(nhkat == 0){
		fprintf(stderr, "FAIL: %s has no hedged known answers\n", file);
		fails++;
	}
	printf("%d and %d known answers (192s, 256s), %d hedged, %d signatures from elsewhere\n", nkat[0], nkat[1], nhkat, nsig);
	return fails != 0;
}

/*
 * The chained-forward signature.  m2 is m with digits raised, left to
 * right, until they sum to 256 more: no digit lower, and the checksum
 * (the sum of 15 - digit) 256 less, which mod 256 is the same.
 */
enum { N = 24, LEN = 51, HP = 9 };

static void
digits(int *d, const uchar *m)
{
	int i;

	for(i = 0; i < N; i++){
		d[2*i] = m[i] >> 4;
		d[2*i+1] = m[i] & 15;
	}
}

static int
raise(uchar *m2, const uchar *m)
{
	int d[2*N], i, left, r;

	left = 256;
	digits(d, m);
	for(i = 0; i < 2*N && left > 0; i++){
		r = 15 - d[i];
		if(r > left)
			r = left;
		d[i] += r;
		left -= r;
	}
	for(i = 0; i < N; i++)
		m2[i] = d[2*i] << 4 | d[2*i+1];
	return left == 0;
}

/* from sig on m to sig2 on m2 with F and public values only; checksum chains as they were */
static void
chainforward(uchar *sig2, const uchar *sig, const uchar *m, const uchar *m2, const uchar *pkseed, const uchar *adrs0)
{
	uchar adrs[32];
	int d[2*N], d2[2*N], i, j;

	digits(d, m);
	digits(d2, m2);
	memmove(sig2, sig, LEN*N);
	memmove(adrs, adrs0, 32);
	for(i = 0; i < 2*N; i++){
		slhdsa_adrs_set_chain(adrs, i);
		for(j = d[i]; j < d2[i]; j++){
			slhdsa_adrs_set_hash(adrs, j);
			slhdsa_F(sig2 + i*N, N, pkseed, N, adrs, sig2 + i*N, N);
		}
	}
}

static void
fill(uchar *p, int n, unsigned *x)
{
	int i;

	for(i = 0; i < n; i++){
		*x = *x*1103515245 + 12345;
		p[i] = *x >> 16;
	}
}

static int
forge(void)
{
	uchar pkseed[N], skseed[N], m[N], m2[N], adrs[32], a[32];
	uchar sig[LEN*N], sig2[LEN*N], pk[N], pk2[N];
	uchar xs[(LEN+HP)*N], xs2[(LEN+HP)*N], root[64], root2[64];
	unsigned x;
	int i, forged, tried;

	x = 205;
	forged = 0;
	tried = 0;
	for(i = 0; i < 8; i++){
		fill(pkseed, N, &x);
		fill(skseed, N, &x);
		do
			fill(m, N, &x);
		while(!raise(m2, m));

		/* WOTS+ alone */
		slhdsa_adrs_init(adrs);
		slhdsa_adrs_set_layer(adrs, 3);
		slhdsa_adrs_set_tree(adrs, 5);
		slhdsa_adrs_set_type(adrs, 0);
		slhdsa_adrs_set_keypair(adrs, 7);
		memmove(a, adrs, 32);
		slhdsa_wots_sign(sig, N, m, pkseed, N, skseed, N, a);
		memmove(a, adrs, 32);
		slhdsa_wots_pk_from_sig(pk, N, sig, m, pkseed, N, a);
		chainforward(sig2, sig, m, m2, pkseed, adrs);
		memmove(a, adrs, 32);
		slhdsa_wots_pk_from_sig(pk2, N, sig2, m2, pkseed, N, a);
		tried++;
		if(memcmp(pk, pk2, N) == 0){
			forged++;
			if(forged < 4)
				fprintf(stderr, "FAIL: a WOTS+ signature chained forward to another message gives the same public key\n");
		}

		/* under an XMSS tree: the signature and its authentication path */
		if(i >= 2)
			continue;
		slhdsa_xmss_sign(xs, N, m, pkseed, N, skseed, N, 6, 0, HP, 300);
		slhdsa_xmss_root_from_sig(root, N, xs, 300, m, pkseed, N, 6, 0, HP);
		slhdsa_adrs_init(adrs);
		slhdsa_adrs_set_layer(adrs, 6);
		slhdsa_adrs_set_tree(adrs, 0);
		slhdsa_adrs_set_type(adrs, 0);
		slhdsa_adrs_set_keypair(adrs, 300);
		memmove(xs2, xs, sizeof xs);
		chainforward(xs2, xs, m, m2, pkseed, adrs);
		slhdsa_xmss_root_from_sig(root2, N, xs2, 300, m2, pkseed, N, 6, 0, HP);
		tried++;
		if(memcmp(root, root2, N) == 0){
			forged++;
			if(forged < 4)
				fprintf(stderr, "FAIL: an XMSS tree's root vouches for a value its leaf never signed\n");
		}
	}
	printf("%d signatures chained forward to a message with digits raised by 256: %d taken\n", tried, forged);
	return forged != 0;
}

static int
cli(void)
{
	static char line[200000];
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
		if(set != 192 && set != 256)
			continue;
		if(strcmp(f[0], "keygen") == 0){
			a = unhex(f[2], &n1);
			if(n1 > sizeof rngq)
				n1 = sizeof rngq;
			memmove(rngq, a, n1);
			rngqn = n1;
			rngqp = 0;
			pk = malloc(pklen(set));
			sk = malloc(sklen(set));
			rc = keygen(set, pk, sk);
			rngqn = 0;
			printf("rc %d\n", rc);
			phex("pk", pk, pklen(set));
			phex("sk", sk, sklen(set));
			free(a); free(pk); free(sk);
		}else if(strcmp(f[0], "sign") == 0 && nf >= 4){
			/* sign SET SK MSG [ADDRND [CTX]]: ADDRND is given to the generator; "-" for the deterministic variant */
			a = unhex(f[2], &n1);
			b = unhex(f[3], &n2);
			c = unhex(nf >= 5 ? f[4] : "-", &n3);
			d = unhex(nf >= 6 ? f[5] : "-", &n4);
			sig = malloc(siglen(set));
			memset(sig, 0, siglen(set));
			if(n1 != sklen(set))
				rc = -2;
			else if(n3 == 0){
				uchar *m;

				m = mprime(b, n2);
				rc = slhdsa_sign_internal(set, sig, m, n2 + 2, nil, a);
				free(m);
			}else{
				memmove(rngq, c, n3);
				rngqn = n3;
				rngqp = 0;
				rc = signctx(set, sig, b, n2, d, n4, a);
				rngqn = 0;
			}
			printf("rc %d\n", rc);
			phex("sig", sig, siglen(set));
			free(a); free(b); free(c); free(d); free(sig);
		}else if(strcmp(f[0], "verify") == 0 && nf >= 5){
			/* verify SET PK MSG SIG [CTX] */
			a = unhex(f[2], &n1);
			b = unhex(f[3], &n2);
			c = unhex(f[4], &n3);
			d = unhex(nf >= 6 ? f[5] : "-", &n4);
			rc = n1 == pklen(set) ? verifyctx(set, c, n3, b, n2, d, n4, a) : -2;
			printf("ok %d\n", rc);
			free(a); free(b); free(c); free(d);
		}
		fflush(stdout);
	}
	return 0;
}

int
main(int argc, char **argv)
{
	if(argc >= 2 && strcmp(argv[1], "forge") == 0)
		return forge();
	if(argc >= 2 && strcmp(argv[1], "cli") == 0)
		return cli();
	if(argc >= 2)
		return vectors(argv[1], argc >= 3 && strcmp(argv[2], "quick") == 0);
	fprintf(stderr, "usage: slhtest vectors.txt [quick] | forge | cli\n");
	return 2;
}
