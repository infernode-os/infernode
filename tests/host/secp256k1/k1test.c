/*
 * libsec/secp256k1.c on the host, built by tests/host/secp256k1_test.sh.
 *
 *   k1test vectors.txt	known answers (tests/host/secp256k1/gen.py, its
 *			Python reference checked against OpenSSL): d*G,
 *			signatures byte for byte (RFC 6979, low S, v),
 *			recovery (high S, the other parity, r and s at and
 *			past the order, an x with no point, a key at
 *			infinity), verification; the complete formulas' edge
 *			cases; keygen, sign, recover and verify round trips;
 *			field and scalar arithmetic against a slow reference;
 *			timing
 *   k1test ct WHAT	one operation with its secret marked undefined for
 *			valgrind's memcheck (ctgrind): a branch or an address
 *			that depends on it is reported
 *
 * secp256k1.c is included, so its static functions are reachable.
 */
#include "../../../libsec/secp256k1.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

static int secretrng;	/* mark what prng makes undefined (ct mode) */

void
prng(uchar *p, int n)
{
	static int fd = -1;

	if(fd < 0)
		fd = open("/dev/urandom", O_RDONLY);
	if(fd < 0 || read(fd, p, n) != n)
		abort();
	if(secretrng)
		VALGRIND_MAKE_MEM_UNDEFINED(p, n);
}

static int fails;

static void
check(int ok, const char *what, const char *line)
{
	if(!ok){
		fails++;
		if(fails < 20)
			fprintf(stderr, "FAIL: %s %s\n", what, line);
	}
}

static int
unhex(const char *s, uchar *o, int max)
{
	unsigned v;
	int i, n;

	n = strlen(s)/2;
	if(n > max)
		abort();
	for(i = 0; i < n; i++){
		sscanf(s + 2*i, "%2x", &v);
		o[i] = v;
	}
	return n;
}

static double
now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec/1e9;
}

static int
pteq(const Pt *a, const Pt *b)
{
	felem ax, ay, bx, by;
	int ia, ib;

	ia = ptaffine(ax, ay, a);
	ib = ptaffine(bx, by, b);
	if(ia < 0 || ib < 0)
		return ia == ib;
	return fequal(ax, bx) && fequal(ay, by);
}

static int
isidentity(const Pt *a)
{
	felem x, y;

	return ptaffine(x, y, a) < 0;
}

static void
vectors(const char *file)
{
	FILE *f;
	char line[4096], kind[16], a[256], b[256], c[256], d[256], e[256], g[256];
	uchar priv[32], hash[64], want[65], got[65], sig[65];
	int hl, n, ok;

	f = fopen(file, "r");
	if(f == NULL){
		perror(file);
		exit(2);
	}
	n = 0;
	while(fgets(line, sizeof line, f) != NULL){
		if(sscanf(line, "%15s", kind) != 1)
			continue;
		n++;
		if(strcmp(kind, "pub") == 0){
			sscanf(line, "%*s %255s %255s %255s", a, b, c);
			unhex(a, priv, 32);
			want[0] = 4;
			unhex(b, want+1, 32);
			unhex(c, want+33, 32);
			check(secp256k1_pubkey(got, priv) == 0 && memcmp(got, want, 65) == 0, "d*G", line);
		}else if(strcmp(kind, "sig") == 0){
			sscanf(line, "%*s %255s %255s %255s %255s %255s", a, b, c, d, e);
			unhex(a, priv, 32);
			hl = unhex(b, hash, 64);
			unhex(c, want, 32);
			unhex(d, want+32, 32);
			unhex(e, want+64, 1);
			check(secp256k1_sign(got, priv, hash, hl) == 0 && memcmp(got, want, 65) == 0, "sign, byte for byte", line);
		}else if(strcmp(kind, "rec") == 0){
			sscanf(line, "%*s %255s %255s %255s %255s %255s %255s", a, b, c, d, e, g);
			hl = unhex(a, hash, 64);
			unhex(b, sig, 32);
			unhex(c, sig+32, 32);
			unhex(d, sig+64, 1);
			if(strcmp(e, "-") == 0)
				check(secp256k1_recover(got, hash, hl, sig) != 0, "recover refuses", line);
			else{
				want[0] = 4;
				unhex(e, want+1, 32);
				unhex(g, want+33, 32);
				check(secp256k1_recover(got, hash, hl, sig) == 0 && memcmp(got, want, 65) == 0, "recover", line);
			}
		}else if(strcmp(kind, "ver") == 0){
			sscanf(line, "%*s %255s %255s %255s %255s %255s %d", a, b, c, d, e, &ok);
			want[0] = 4;
			unhex(a, want+1, 32);
			unhex(b, want+33, 32);
			hl = unhex(c, hash, 64);
			unhex(d, sig, 32);
			unhex(e, sig+32, 32);
			check(secp256k1_verify(sig, want, hash, hl) == ok, "verify", line);
			if(ok){
				hash[0] ^= 0x80;
				check(secp256k1_verify(sig, want, hash, hl) == 0, "verify refuses a changed hash", line);
				hash[0] ^= 0x80;
				sig[7] ^= 1;
				check(secp256k1_verify(sig, want, hash, hl) == 0, "verify refuses a changed r", line);
			}
		}
	}
	fclose(f);
	check(n >= 600, "vectors read", file);
	printf("%d known answers\n", n);
}

static void
edgecases(void)
{
	Pt g, o, t, u, neg, a;
	felem b3, x, y;
	uchar k[32], pub[65], sig[65], hash[32];
	int i;

	b3mont(b3);
	ptbase(&g);
	ptidentity(&o);
	ptadd(&t, &g, &g, b3);
	ptdouble(&u, &g, b3);
	check(pteq(&t, &u), "P+P == 2P", "");
	neg = g;
	mneg(&K1P, neg.y, g.y);
	ptadd(&t, &g, &neg, b3);
	check(isidentity(&t), "P + -P == O", "");
	ptadd(&t, &g, &o, b3);
	check(pteq(&t, &g), "P + O == P", "");
	ptadd(&t, &o, &g, b3);
	check(pteq(&t, &g), "O + P == P", "");
	ptadd(&t, &o, &o, b3);
	check(isidentity(&t), "O + O == O", "");
	ptdouble(&t, &o, b3);
	check(isidentity(&t), "2O == O", "");
	/* G with Z != 1 */
	a = g;
	for(i = 0; i < 3; i++){
		mmul(&K1P, a.x, a.x, b3);
		mmul(&K1P, a.y, a.y, b3);
		mmul(&K1P, a.z, a.z, b3);
	}
	check(pteq(&a, &g), "scaled G == G", "");
	ptadd(&t, &a, &g, b3);
	check(pteq(&t, &u), "scaled G + G == 2G", "");
	ptadd(&t, &a, &a, b3);
	check(pteq(&t, &u), "scaled G + scaled G == 2G", "");
	memset(k, 0, sizeof k);
	ptmul(&t, k, &g);
	check(isidentity(&t), "0G == O", "");
	ftobytes(k, K1N.m);
	ptmul(&t, k, &g);
	check(isidentity(&t), "nG == O", "");
	k[31]++;
	ptmul(&t, k, &g);
	check(pteq(&t, &g), "(n+1)G == G", "");
	k[31] -= 2;
	ptmul(&t, k, &g);
	check(pteq(&t, &neg), "(n-1)G == -G", "");

	/* out-of-range private keys */
	memset(k, 0, sizeof k);
	check(secp256k1_privkey_valid(k) == 0 && secp256k1_pubkey(pub, k) != 0, "0 refused as a key", "");
	memset(hash, 0x11, sizeof hash);
	check(secp256k1_sign(sig, k, hash, 32) != 0, "sign refuses key 0", "");
	ftobytes(k, K1N.m);
	check(secp256k1_privkey_valid(k) == 0 && secp256k1_pubkey(pub, k) != 0, "n refused as a key", "");
	check(secp256k1_sign(sig, k, hash, 32) != 0, "sign refuses key n", "");
	memset(k, 0xFF, sizeof k);
	check(secp256k1_privkey_valid(k) == 0, "2^256-1 refused as a key", "");
	ftobytes(k, K1N.m);
	k[31]--;
	check(secp256k1_privkey_valid(k) == 1 && secp256k1_pubkey(pub, k) == 0, "n-1 is a key", "");

	/* a public key off the curve, or with a coordinate >= p, refused by verify */
	ptbase(&g);
	ptaffine(x, y, &g);
	memset(k, 0, sizeof k);
	k[31] = 1;
	check(secp256k1_sign(sig, k, hash, 32) == 0, "sign with key 1", "");
	pubbytes(pub, x, y);
	check(secp256k1_verify(sig, pub, hash, 32) == 1, "verify with G", "");
	pub[64] ^= 1;
	check(secp256k1_verify(sig, pub, hash, 32) == 0, "verify refuses a key off the curve", "");
	pub[64] ^= 1;
	pub[0] = 2;
	check(secp256k1_verify(sig, pub, hash, 32) == 0, "verify refuses a key not 04", "");
	pub[0] = 4;
	fcopy(y, K1P.m);
	ftobytes(pub+33, y);
	check(secp256k1_verify(sig, pub, hash, 32) == 0, "verify refuses y = p", "");
}

/* the arithmetic against plain big-number reference, on random inputs */
static void
mulref(limb *r, const limb *a, const limb *b, const limb *m)
{
	/* (a*b) mod m by shift and subtract: slow, obviously right */
	limb acc[NLIMB], t[NLIMB];
	int i, j;
	limb top, borrow;

	fzero(acc);
	for(i = 4*64 - 1; i >= 0; i--){
		/* acc = 2 acc mod m */
		top = acc[NLIMB-1] >> 63;
		for(j = NLIMB-1; j > 0; j--)
			acc[j] = acc[j] << 1 | acc[j-1] >> 63;
		acc[0] <<= 1;
		borrow = fsubb(t, acc, m);
		if(top || !borrow)
			fcopy(acc, t);
		if((b[i/64] >> (i%64)) & 1){
			top = 0;
			{
				u128 c = U128_FROM64(0);
				for(j = 0; j < NLIMB; j++){
					c = ADD128_64(ADD128_64(c, acc[j]), a[j]);
					acc[j] = LO128(c);
					c = U128_FROM64(SHR128_64(c));
				}
				top = LO128(c);
			}
			borrow = fsubb(t, acc, m);
			if(top || !borrow)
				fcopy(acc, t);
		}
	}
	fcopy(r, acc);
}

/* a random value < m: uniform, or just below m, or small */
static void
randbelow(limb *r, const Mont *M)
{
	uchar b[32];
	felem small;

	do{
		prng(b, 32);
		switch(b[0] % 8){
		case 0:
			fzero(small);
			small[0] = 1 + b[1];
			fsubb(r, M->m, small);
			break;
		case 1:
			fzero(r);
			r[0] = b[1];
			break;
		default:
			bytestof(r, b);
		}
	}while(!fless(r, M->m));
}

static void
arith(void)
{
	const Mont *Ms[2] = {&K1P, &K1N};
	felem a, b, am, bm, r, w, one;
	int i, k;

	fzero(one);
	one[0] = 1;
	for(k = 0; k < 2; k++){
		const Mont *M = Ms[k];
		for(i = 0; i < 2000; i++){
			randbelow(a, M);
			randbelow(b, M);
			mto(M, am, a);
			mto(M, bm, b);
			mmul(M, r, am, bm);
			mfrom(M, r, r);
			mulref(w, a, b, M->m);
			check(fequal(r, w) != 0, "mmul", k ? "mod n" : "mod p");
			if(i < 200){
				if(k == 0)
					pinv(r, am);
				else
					ninv(r, am);
				mmul(M, r, r, am);
				mfrom(M, r, r);
				check(fiszero(a) ? fiszero(r) != 0 : fequal(r, one) != 0, "inverse", k ? "mod n" : "mod p");
			}
			if(k == 0 && i < 200){
				/* sqrt(a^2)^2 == a^2 */
				msqr(M, w, am);
				psqrt(r, w);
				msqr(M, r, r);
				check(fequal(r, w) != 0, "square root", "");
			}
		}
	}
}

static void
roundtrips(void)
{
	uchar priv[32], pub[65], pub2[65], sig[65], hash[32];
	int i;

	for(i = 0; i < 100; i++){
		check(secp256k1_keygen(priv, pub) == 0, "keygen", "");
		check(secp256k1_pubkey(pub2, priv) == 0 && memcmp(pub, pub2, 65) == 0, "keygen's public key", "");
		prng(hash, sizeof hash);
		check(secp256k1_sign(sig, priv, hash, 32) == 0, "sign", "");
		check(sig[64] <= 1, "v is 0 or 1", "");
		check(secp256k1_recover(pub2, hash, 32, sig) == 0 && memcmp(pub, pub2, 65) == 0, "sign, then recover", "");
		check(secp256k1_verify(sig, pub, hash, 32) == 1, "sign, then verify", "");
		hash[31] ^= 1;
		check(secp256k1_verify(sig, pub, hash, 32) == 0, "verify refuses another hash", "");
		check(secp256k1_recover(pub2, hash, 32, sig) != 0 || memcmp(pub, pub2, 65) != 0, "recover from another hash is another key", "");
	}
}

static void
timing(void)
{
	uchar priv[32], pub[65], sig[65], hash[32];
	double t0;
	int i, n;

	n = 200;
	memset(hash, 0x5a, sizeof hash);
	t0 = now();
	for(i = 0; i < n; i++)
		secp256k1_keygen(priv, pub);
	printf("secp256k1_keygen  %.3f ms\n", (now()-t0)*1000/n);
	t0 = now();
	for(i = 0; i < n; i++)
		secp256k1_sign(sig, priv, hash, 32);
	printf("secp256k1_sign    %.3f ms\n", (now()-t0)*1000/n);
	t0 = now();
	for(i = 0; i < n; i++)
		secp256k1_recover(pub, hash, 32, sig);
	printf("secp256k1_recover %.3f ms\n", (now()-t0)*1000/n);
	t0 = now();
	for(i = 0; i < n; i++)
		secp256k1_verify(sig, pub, hash, 32);
	printf("secp256k1_verify  %.3f ms\n", (now()-t0)*1000/n);
}

/* keep a result live: unused, the compiler deletes the work that made it */
static volatile uchar sinkv;

static void
sink(const void *p, int n)
{
	const uchar *b = p;
	uchar x;
	int i;

	x = 0;
	for(i = 0; i < n; i++)
		x ^= b[i];
	VALGRIND_MAKE_MEM_DEFINED(&x, 1);
	sinkv = x;
}

/* one operation, its secret undefined to memcheck */
static int
ct(const char *what)
{
	uchar d[32], pub[65], sig[65], h[32];
	felem a, b, r;
	Pt g, p;

	memset(&p, 0, sizeof p);
	memset(r, 0, sizeof r);
	memset(pub, 0, sizeof pub);
	memset(sig, 0, sizeof sig);
	prng(d, sizeof d);
	d[0] &= 0x7F;	/* < n */
	prng(h, sizeof h);
	prng((uchar*)a, sizeof a);
	prng((uchar*)b, sizeof b);
	a[3] &= 0x7FFFFFFFFFFFFFFFULL;	/* < n < p */
	b[3] &= 0x7FFFFFFFFFFFFFFFULL;
	VALGRIND_MAKE_MEM_UNDEFINED(d, sizeof d);
	VALGRIND_MAKE_MEM_UNDEFINED(a, sizeof a);
	VALGRIND_MAKE_MEM_UNDEFINED(b, sizeof b);
	if(strcmp(what, "ptmul") == 0){
		ptbase(&g);
		ptmul(&p, d, &g);
	}else if(strcmp(what, "fieldmul") == 0){
		/* field multiplication and reduction, addition, subtraction */
		mmul(&K1P, r, a, b);
		madd(&K1P, r, r, a);
		msub(&K1P, r, r, b);
		mto(&K1P, r, r);
		mfrom(&K1P, r, r);
	}else if(strcmp(what, "fieldinv") == 0)
		pinv(r, a);
	else if(strcmp(what, "scalarmul") == 0){
		mmul(&K1N, r, a, b);
		madd(&K1N, r, r, a);
		msub(&K1N, r, r, b);
		mneg(&K1N, r, r);
	}else if(strcmp(what, "scalarinv") == 0)
		ninv(r, a);
	else if(strcmp(what, "pubkey") == 0)
		secp256k1_pubkey(pub, d);
	else if(strcmp(what, "sign") == 0)
		secp256k1_sign(sig, d, h, 32);
	else if(strcmp(what, "keygen") == 0){
		secretrng = 1;	/* the new private key */
		secp256k1_keygen(d, pub);
	}else{
		fprintf(stderr, "ct: unknown %s\n", what);
		return 2;
	}
	sink(&p, sizeof p);
	sink(r, sizeof r);
	sink(pub, sizeof pub);
	sink(sig, sizeof sig);
	return 0;
}

int
main(int argc, char **argv)
{
	if(argc == 3 && strcmp(argv[1], "ct") == 0)
		return ct(argv[2]);
	if(argc != 2){
		fprintf(stderr, "usage: k1test vectors.txt | k1test ct what\n");
		return 2;
	}
	vectors(argv[1]);
	edgecases();
	arith();
	roundtrips();
	timing();
	if(fails){
		printf("%d FAILED\n", fails);
		return 1;
	}
	printf("ALL PASS\n");
	return 0;
}
