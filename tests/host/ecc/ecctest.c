/*
 * libsec/ecc.c (P-256, P-384) on the host, built by tests/host/ecc_test.sh.
 *
 *   ecctest vectors.txt	known answers from OpenSSL (d*G, ECDH, OpenSSL's
 *			ECDSA signatures verified, tampered ones refused);
 *			the complete formulas' edge cases (P+P, P+-P, the
 *			identity, a point with Z != 1, 0*G, n*G, (n+1)*G);
 *			keygen and ECDH round trips, sign then verify;
 *			invalid peer points refused; timing
 *   ecctest ct WHAT	one operation with its secret marked undefined for
 *			valgrind's memcheck (ctgrind): a branch or an address
 *			that depends on it is reported
 *
 * ecc.c is included, so its static functions are reachable.
 */
#include "../../../libsec/ecc.c"
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

void *mallocz(ulong n, int clr){ void *p = malloc(n); if(p != nil && clr) memset(p, 0, n); return p; }

static int secretrng;	/* mark what genrandom makes undefined (ct mode) */

void
genrandom(uchar *p, int n)
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
			fprintf(stderr, "FAIL: %s %.70s\n", what, line);
	}
}

static void
unhex(const char *s, uchar *o, int n)
{
	unsigned v;
	int i;

	for(i = 0; i < n; i++){
		sscanf(s + 2*i, "%2x", &v);
		o[i] = v;
	}
}

static double
now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec/1e9;
}

static int
pteq(const Curve *C, const Pt *a, const Pt *b)
{
	felem ax, ay, bx, by;
	int ia, ib;

	ia = ptaffine(C, ax, ay, a);
	ib = ptaffine(C, bx, by, b);
	if(ia < 0 || ib < 0)
		return ia == ib;
	return fequal(ax, bx, C->p.n) && fequal(ay, by, C->p.n);
}

static int
isidentity(const Curve *C, const Pt *a)
{
	felem x, y;

	return ptaffine(C, x, y, a) < 0;
}

static void
edgecases(const Curve *C, const char *name)
{
	Pt g, o, t, u, neg, a;
	felem bm;
	uchar k[48];
	int i;

	mto(&C->p, bm, C->b);
	ptbase(C, &g);
	ptidentity(C, &o);
	ptadd(C, &t, &g, &g, bm);
	ptdouble(C, &u, &g, bm);
	check(pteq(C, &t, &u), "P+P == 2P", name);
	neg = g;
	fzero(neg.y, C->p.n);
	msub(&C->p, neg.y, neg.y, g.y);
	ptadd(C, &t, &g, &neg, bm);
	check(isidentity(C, &t), "P + -P == O", name);
	ptadd(C, &t, &g, &o, bm);
	check(pteq(C, &t, &g), "P + O == P", name);
	ptadd(C, &t, &o, &g, bm);
	check(pteq(C, &t, &g), "O + P == P", name);
	ptadd(C, &t, &o, &o, bm);
	check(isidentity(C, &t), "O + O == O", name);
	ptdouble(C, &t, &o, bm);
	check(isidentity(C, &t), "2O == O", name);
	/* G with Z != 1 */
	a = g;
	for(i = 0; i < 3; i++){
		mmul(&C->p, a.x, a.x, bm);
		mmul(&C->p, a.y, a.y, bm);
		mmul(&C->p, a.z, a.z, bm);
	}
	check(pteq(C, &a, &g), "scaled G == G", name);
	ptadd(C, &t, &a, &g, bm);
	check(pteq(C, &t, &u), "scaled G + G == 2G", name);
	memset(k, 0, sizeof k);
	ptmul(C, &t, k, &g);
	check(isidentity(C, &t), "0G == O", name);
	ftobytes(k, C->q.m, C->q.n);
	ptmul(C, &t, k, &g);
	check(isidentity(C, &t), "nG == O", name);
	k[C->nbytes-1]++;
	ptmul(C, &t, k, &g);
	check(pteq(C, &t, &g), "(n+1)G == G", name);
}

static void
vectors(const char *file)
{
	FILE *f;
	char line[4096], kind[16], a[256], b[256], c[256], d[256], e[256];
	uchar priv[48], px[48], py[48], want[48], got[48], gx[48], gy[48], sig[96], hash[64];
	int bits, nb, hl, n;
	const Curve *C;
	ECpoint p2;
	ECpoint384 p3;
	Pt G, R;
	felem x, y;

	f = fopen(file, "r");
	if(f == NULL){
		perror(file);
		exit(2);
	}
	n = 0;
	while(fgets(line, sizeof line, f) != NULL){
		if(sscanf(line, "%15s %d", kind, &bits) != 2)
			continue;
		n++;
		nb = bits/8;
		C = bits == 256 ? &P256 : &P384;
		if(strcmp(kind, "pub") == 0){
			sscanf(line, "%*s %*d %255s %255s %255s", a, b, c);
			unhex(a, priv, nb);
			unhex(b, px, nb);
			unhex(c, py, nb);
			ptbase(C, &G);
			ptmul(C, &R, priv, &G);
			check(ptaffine(C, x, y, &R) == 0, "d*G is the identity", line);
			ftobytes(gx, x, C->p.n);
			ftobytes(gy, y, C->p.n);
			check(memcmp(gx, px, nb) == 0 && memcmp(gy, py, nb) == 0, "d*G", line);
		}else if(strcmp(kind, "ecdh") == 0){
			sscanf(line, "%*s %*d %255s %255s %255s %255s", a, b, c, d);
			unhex(a, priv, nb);
			unhex(b, px, nb);
			unhex(c, py, nb);
			unhex(d, want, nb);
			if(bits == 256){
				memmove(p2.x, px, 32);
				memmove(p2.y, py, 32);
				check(p256_ecdh(got, priv, &p2) == 0 && memcmp(got, want, 32) == 0, "p256_ecdh", line);
			}else{
				memmove(p3.x, px, 48);
				memmove(p3.y, py, 48);
				check(p384_ecdh(got, priv, &p3) == 0 && memcmp(got, want, 48) == 0, "p384_ecdh", line);
			}
		}else if(strcmp(kind, "sig") == 0){
			sscanf(line, "%*s %*d %255s %255s %255s %255s %255s", a, b, c, d, e);
			unhex(a, px, nb);
			unhex(b, py, nb);
			hl = strlen(c)/2;
			unhex(c, hash, hl);
			unhex(d, sig, nb);
			unhex(e, sig+nb, nb);
			if(bits == 256){
				memmove(p2.x, px, 32);
				memmove(p2.y, py, 32);
				check(p256_ecdsa_verify(sig, &p2, hash, hl) == 1, "p256 verifies OpenSSL's signature", line);
				sig[5] ^= 1;
				check(p256_ecdsa_verify(sig, &p2, hash, hl) == 0, "p256 refuses a changed r", line);
				sig[5] ^= 1;
				hash[0] ^= 0x80;
				check(p256_ecdsa_verify(sig, &p2, hash, hl) == 0, "p256 refuses a changed hash", line);
			}else{
				memmove(p3.x, px, 48);
				memmove(p3.y, py, 48);
				check(p384_ecdsa_verify(sig, &p3, hash, hl) == 1, "p384 verifies OpenSSL's signature", line);
				sig[nb+5] ^= 1;
				check(p384_ecdsa_verify(sig, &p3, hash, hl) == 0, "p384 refuses a changed s", line);
				sig[nb+5] ^= 1;
				hash[0] ^= 0x80;
				check(p384_ecdsa_verify(sig, &p3, hash, hl) == 0, "p384 refuses a changed hash", line);
			}
		}
	}
	fclose(f);
	check(n >= 100, "vectors read", file);
	printf("%d known answers\n", n);
}

static void
roundtrips(void)
{
	uchar da[48], db[48], s1[48], s2[48], sig[64], hash[32];
	ECpoint A, B;
	ECpoint384 A3, B3;
	int i;

	for(i = 0; i < 50; i++){
		check(p256_keygen(da, &A) == 0 && p256_keygen(db, &B) == 0, "p256_keygen", "");
		check(p256_ecdh(s1, da, &B) == 0 && p256_ecdh(s2, db, &A) == 0 && memcmp(s1, s2, 32) == 0, "p256 ECDH round trip", "");
		check(p384_keygen(da, &A3) == 0 && p384_keygen(db, &B3) == 0, "p384_keygen", "");
		check(p384_ecdh(s1, da, &B3) == 0 && p384_ecdh(s2, db, &A3) == 0 && memcmp(s1, s2, 48) == 0, "p384 ECDH round trip", "");
		genrandom(hash, sizeof hash);
		check(p256_ecdsa_sign(sig, da, hash, 32) == 0, "p256 sign", "");
		check(p256_keygen(da, &A) == 0 && p256_ecdsa_sign(sig, da, hash, 32) == 0, "p256 sign", "");
		check(p256_ecdsa_verify(sig, &A, hash, 32) == 1, "p256 sign, then verify", "");
		hash[31] ^= 1;
		check(p256_ecdsa_verify(sig, &A, hash, 32) == 0, "p256 verify refuses another hash", "");
	}
}

static void
badpoints(void)
{
	uchar d[48], s[48];
	ECpoint A, bad;
	ECpoint384 A3, bad3;

	p256_keygen(d, &A);
	bad = A;
	bad.x[31] ^= 1;
	check(p256_ecdh(s, d, &bad) != 0, "P-256 off-curve point refused", "");
	memset(&bad, 0, sizeof bad);
	check(p256_ecdh(s, d, &bad) != 0, "P-256 (0,0) refused", "");
	bad = A;
	ftobytes(bad.x, P256.p.m, 4);
	check(p256_ecdh(s, d, &bad) != 0, "P-256 x = p refused", "");
	p384_keygen(d, &A3);
	bad3 = A3;
	bad3.y[0] ^= 0x10;
	check(p384_ecdh(s, d, &bad3) != 0, "P-384 off-curve point refused", "");
	memset(&bad3, 0, sizeof bad3);
	check(p384_ecdh(s, d, &bad3) != 0, "P-384 (0,0) refused", "");
	bad3 = A3;
	ftobytes(bad3.y, P384.p.m, 6);
	check(p384_ecdh(s, d, &bad3) != 0, "P-384 y = p refused", "");
}

static void
timing(void)
{
	uchar d[48], s[48];
	ECpoint A;
	ECpoint384 A3;
	double t0;
	int i, n;

	n = 50;
	t0 = now();
	for(i = 0; i < n; i++)
		p256_keygen(d, &A);
	printf("p256_keygen %.3f ms\n", (now()-t0)*1000/n);
	t0 = now();
	for(i = 0; i < n; i++)
		p256_ecdh(s, d, &A);
	printf("p256_ecdh   %.3f ms\n", (now()-t0)*1000/n);
	t0 = now();
	for(i = 0; i < n; i++)
		p384_keygen(d, &A3);
	printf("p384_keygen %.3f ms\n", (now()-t0)*1000/n);
	t0 = now();
	for(i = 0; i < n; i++)
		p384_ecdh(s, d, &A3);
	printf("p384_ecdh   %.3f ms\n", (now()-t0)*1000/n);
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
	uchar d[48], s[48], sig[96], h[48];
	ECpoint A;
	ECpoint384 A3;
	Pt g, r;

	memset(&r, 0, sizeof r);
	memset(s, 0, sizeof s);
	memset(sig, 0, sizeof sig);
	p256_keygen(d, &A);
	p384_keygen(d, &A3);
	genrandom(d, sizeof d);
	d[0] &= 0x7F;	/* < n for both curves */
	genrandom(h, sizeof h);
	VALGRIND_MAKE_MEM_UNDEFINED(d, sizeof d);
	if(strcmp(what, "ptmul256") == 0){
		ptbase(&P256, &g);
		ptmul(&P256, &r, d, &g);
	}else if(strcmp(what, "ptmul384") == 0){
		ptbase(&P384, &g);
		ptmul(&P384, &r, d, &g);
	}else if(strcmp(what, "ecdh256") == 0)
		p256_ecdh(s, d, &A);
	else if(strcmp(what, "ecdh384") == 0)
		p384_ecdh(s, d, &A3);
	else{
		secretrng = 1;	/* the nonce, the new private key */
		if(strcmp(what, "sign256") == 0)
			p256_ecdsa_sign(sig, d, h, 32);
		else if(strcmp(what, "keygen256") == 0)
			p256_keygen(s, &A);
		else if(strcmp(what, "keygen384") == 0)
			p384_keygen(s, &A3);
		else{
			fprintf(stderr, "ct: unknown %s\n", what);
			return 2;
		}
	}
	sink(&r, sizeof r);
	sink(s, sizeof s);
	sink(sig, sizeof sig);
	return 0;
}

int
main(int argc, char **argv)
{
	if(argc == 3 && strcmp(argv[1], "ct") == 0)
		return ct(argv[2]);
	if(argc != 2){
		fprintf(stderr, "usage: ecctest vectors.txt | ecctest ct what\n");
		return 2;
	}
	vectors(argv[1]);
	edgecases(&P256, "P-256");
	edgecases(&P384, "P-384");
	roundtrips();
	badpoints();
	timing();
	if(fails){
		printf("%d FAILED\n", fails);
		return 1;
	}
	printf("ALL PASS\n");
	return 0;
}
