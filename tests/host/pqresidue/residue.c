/*
 * What libsec's post-quantum code leaves of its secrets on the C stack
 * it has returned from, built by tests/host/pq_residue_test.sh.
 *
 * Each case runs an operation in a frame of its own, then copies the
 * dead stack below and looks in it for values a reader of that memory
 * (through some other defect: an uninitialised buffer sent somewhere, a
 * core file) could take the key from:
 *
 *   ML-KEM key generation	sigma, the seed of s and e (it stayed in a
 *				copy of G's output); the bits its last noise
 *				polynomial was made of
 *   ML-KEM decapsulation	the Keccak state of J(z || c), which gives z
 *   ML-DSA key generation	K and rho', the secret key's seeds (they
 *				stayed in a copy of H's output); the half
 *				bytes its last secret polynomial was made of
 *   ML-DSA signing		rho'', the seed of the masks; a mask
 *				polynomial's bytes
 *   SLH-DSA key generation	SK.seed, SK.prf
 *
 * A value still found is printed and is the exit status.  The search is
 * for the bytes wherever they lie, so it also sees a copy the compiler
 * made; it does not see registers, or the heap.
 */
#define _GNU_SOURCE
#include "os.h"
#include <libsec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

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

static uchar snap[1<<16];
static int found;

/*
 * The dead stack below the caller, as the operation before left it.
 * The address is laundered through a volatile and the bytes read
 * through one: a compiler that can see the copy starts outside the
 * local it is taken from may leave the copy out (clang does).
 */
static void __attribute__((noinline))
grab(void)
{
	volatile uchar here;
	volatile uintptr a;
	const volatile uchar *p;
	long i;

	a = (uintptr)&here;
	p = (const volatile uchar*)(a - sizeof snap);
	for(i = 0; i < sizeof snap; i++)
		snap[i] = p[i];
}

static void
find(const char *what, const uchar *pat, int n)
{
	if(memmem(snap, sizeof snap, pat, n) != NULL){
		printf("left on the stack: %s\n", what);
		found++;
	}
}

static void __attribute__((noinline)) kemkeygen(uchar *pk, uchar *sk){ if(mlkem768_keygen(pk, sk) != 0) abort(); }
static void __attribute__((noinline)) kemdecaps(uchar *ss, uchar *ct, uchar *sk){ if(mlkem768_decaps(ss, ct, sk) != 0) abort(); }
static void __attribute__((noinline)) mldsakeygen_(int set, uchar *pk, uchar *sk){ if((set == 65 ? mldsa65_keygen(pk, sk) : mldsa87_keygen(pk, sk)) != 0) abort(); }
static void __attribute__((noinline)) mldsasign_(uchar *sig, uchar *sk){ if(mldsa65_sign(sig, (uchar*)"msg", 3, sk) != 0) abort(); }
static void __attribute__((noinline)) slhkeygen(uchar *pk, uchar *sk){ if(slhdsa192s_keygen(pk, sk) != 0) abort(); }

static void
xof(uchar *out, int n, const uchar *a, int na, const uchar *b, int nb, const uchar *c, int nc)
{
	SHA3state h;

	shake256_init(&h);
	shake256_absorb(&h, a, na);
	shake256_absorb(&h, b, nb);
	shake256_absorb(&h, c, nc);
	shake256_finalize(&h);
	shake256_squeeze(&h, out, n);
}

int
main(void)
{
	static uchar pk[4096], sk[8192], ct[2048], ss[32], ss2[32], sig[8192], buf[1024], tr[64], mu[64];
	uchar d[65], g[64], rnd[32], nb[2];
	SHA3state js;
	int i, set, k, l;

	/* ML-KEM key generation: (rho, sigma) = G(d || k) */
	for(i = 0; i < 64; i++)
		d[i] = 0x40 + i;
	queue(d, 64);
	kemkeygen(pk, sk);
	grab();
	memmove(buf, d, 32);
	buf[32] = 3;
	sha3_512(buf, 33, g);
	find("ML-KEM key generation: sigma, the seed of s and e", g + 32, 32);
	find("ML-KEM key generation: d", d, 32);
	find("ML-KEM key generation: z", d + 32, 32);
	nb[0] = 5;	/* the last noise polynomial: e[2] */
	xof(buf, 128, g + 32, 32, nb, 1, nb, 0);
	find("ML-KEM key generation: the bits of a noise polynomial", buf, 32);

	/* ML-KEM decapsulation: the state of J(z || c) */
	if(mlkem768_encaps(ct, ss, pk) != 0)
		abort();
	kemdecaps(ss2, ct, sk);
	grab();
	shake256_init(&js);
	shake256_absorb(&js, sk + MLKEM768_SKLEN - 32, 32);
	shake256_absorb(&js, ct, MLKEM768_CTLEN);
	shake256_finalize(&js);
	shake256_squeeze(&js, buf, 32);
	find("ML-KEM decapsulation: the Keccak state of J(z || c), which gives z", (uchar*)js.a, 200);
	find("ML-KEM decapsulation: z", sk + MLKEM768_SKLEN - 32, 32);

	/* ML-DSA key generation: (rho, rho', K) = H(xi || k || l) */
	for(set = 65; set <= 87; set += 22){
		k = set == 65 ? 6 : 8;
		l = set == 65 ? 5 : 7;
		for(i = 0; i < 32; i++)
			d[i] = 0x80 + i + set;
		queue(d, 32);
		mldsakeygen_(set, pk, sk);
		grab();
		nb[0] = k;
		nb[1] = l;
		xof(buf, 128, d, 32, nb, 2, nb, 0);
		find("ML-DSA key generation: K", buf + 96, 32);
		find("ML-DSA key generation: rho', the seed of s1 and s2", buf + 32, 64);
		find("ML-DSA key generation: xi", d, 32);
		memmove(g, buf + 32, 64);
		nb[0] = k + l - 1;	/* the last secret polynomial */
		nb[1] = 0;
		xof(buf, 136, g, 64, nb, 2, nb, 0);
		find("ML-DSA key generation: the half bytes of a secret polynomial", buf, 32);
	}

	/* ML-DSA signing: rho'' = H(K || rnd || mu), and the masks from it */
	for(i = 0; i < 32; i++)
		d[i] = 0x20 + i;
	queue(d, 32);
	mldsakeygen_(65, pk, sk);
	for(i = 0; i < 32; i++)
		rnd[i] = 0xD0 + i;
	queue(rnd, 32);
	mldsasign_(sig, sk);
	grab();
	shake256(pk, MLDSA65_PKLEN, tr, 64);
	xof(mu, 64, tr, 64, (uchar*)"msg", 3, nb, 0);
	xof(g, 64, sk + 32, 32, rnd, 32, mu, 64);
	find("ML-DSA signing: rho'', the seed of the masks", g, 64);
	find("ML-DSA signing: K", sk + 32, 32);
	find("ML-DSA signing: rnd", rnd, 32);
	for(i = 0; i < 400; i++){	/* whichever mask polynomial was the last */
		nb[0] = i;
		nb[1] = i >> 8;
		xof(buf, 32, g, 64, nb, 2, nb, 0);
		if(memmem(snap, sizeof snap, buf, 32) != NULL){
			printf("left on the stack: ML-DSA signing: the bytes of a mask polynomial (y %d)\n", i);
			found++;
		}
	}

	/* SLH-DSA key generation */
	for(i = 0; i < 72; i++)
		d[i % 64] = 0, rngq[i] = 0xC0 + (i & 31);
	rngqn = 72;
	rngqp = 0;
	slhkeygen(pk, sk);
	grab();
	find("SLH-DSA key generation: SK.seed", sk, 24);
	find("SLH-DSA key generation: SK.prf", sk + 24, 24);

	if(found == 0)
		printf("none of the seeds, sampler buffers and hash states looked for is left on the stack\n");
	return found != 0;
}
