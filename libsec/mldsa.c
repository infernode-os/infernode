/*
 * ML-DSA Digital Signature Algorithm (FIPS 204)
 *
 * Implements ML-DSA-65 (NIST Level 3) and ML-DSA-87 (NIST Level 5).
 * Based on the Module Learning With Errors / Short Integer Solution
 * (MLWE/MSIS) problems.
 *
 * Working state is heap-allocated to avoid stack overflow in the
 * Inferno emulator's 32KB thread stacks.
 *
 * Reference: NIST FIPS 204 "Module-Lattice-Based Digital Signature
 * Standard" (August 2024).
 */
#include "os.h"
#include <libsec.h>

enum {
	MLDSA_N = 256,
	MLDSA_Q = 8380417,
	MLDSA_D = 13,	/* dropped bits from t */

	/* ML-DSA-65 parameters */
	MLDSA65_K = 6,
	MLDSA65_L = 5,
	MLDSA65_ETA = 4,
	MLDSA65_TAU = 49,
	MLDSA65_BETA = 196,		/* tau * eta */
	MLDSA65_GAMMA1 = (1 << 19),
	MLDSA65_GAMMA2 = (MLDSA_Q - 1) / 32,	/* 261888 */
	MLDSA65_OMEGA = 55,
	MLDSA65_CTILDELEN = 48,

	/* ML-DSA-87 parameters */
	MLDSA87_K = 8,
	MLDSA87_L = 7,
	MLDSA87_ETA = 2,
	MLDSA87_TAU = 60,
	MLDSA87_BETA = 120,		/* tau * eta */
	MLDSA87_GAMMA1 = (1 << 19),
	MLDSA87_GAMMA2 = (MLDSA_Q - 1) / 32,	/* 261888 */
	MLDSA87_OMEGA = 75,
	MLDSA87_CTILDELEN = 64,

	MLDSA_MAXK = 8,
	MLDSA_MAXL = 7,
};

/* Forward declarations for poly operations (mldsa_poly.c) */
extern void	mldsa_poly_uniform(int32 r[MLDSA_N], const uchar rho[32], uchar i, uchar j);
extern void	mldsa_poly_uniform_eta(int32 r[MLDSA_N], const uchar rhoprime[64], u16int nonce, int eta);
extern void	mldsa_poly_uniform_gamma1(int32 r[MLDSA_N], const uchar seed[64], u16int nonce, int gamma1_bits);
extern void	mldsa_poly_pack_t1(uchar *out, const int32 r[MLDSA_N]);
extern void	mldsa_poly_unpack_t1(int32 r[MLDSA_N], const uchar *in);
extern void	mldsa_poly_pack_t0(uchar *out, const int32 r[MLDSA_N]);
extern void	mldsa_poly_unpack_t0(int32 r[MLDSA_N], const uchar *in);
extern int	mldsa_poly_chknorm(const int32 r[MLDSA_N], int32 bound);
extern void	mldsa_power2round(int32 *a1, int32 *a0, int32 a);
extern int32	mldsa_highbits(int32 a, int32 gamma2);
extern int32	mldsa_lowbits(int32 a, int32 gamma2);
extern int	mldsa_makehint(int32 z, int32 r, int32 gamma2);
extern int32	mldsa_usehint(int32 h, int32 a, int32 gamma2);
extern void	mldsa_poly_pack_eta(uchar *out, const int32 r[MLDSA_N], int eta);
extern void	mldsa_poly_unpack_eta(int32 r[MLDSA_N], const uchar *in, int eta);
extern int	mldsa_pack_hint(uchar *out, int outlen, const int32 h[][MLDSA_N], int k, int omega);
extern int	mldsa_unpack_hint(int32 h[][MLDSA_N], int k, const uchar *in, int omega);

/*
 * Sample challenge polynomial c with exactly tau +/-1 coefficients.
 */
static void
sample_challenge(int32 c[MLDSA_N], const uchar *seed, int seedlen, int tau)
{
	SHA3state s;
	uchar buf[8];
	u64int signs;
	int i, b, pos;

	memset(c, 0, MLDSA_N * sizeof(int32));

	shake256_init(&s);
	shake256_absorb(&s, seed, seedlen);
	shake256_finalize(&s);

	/* First 8 bytes encode sign bits */
	shake256_squeeze(&s, buf, 8);
	signs = 0;
	for(i = 0; i < 8; i++)
		signs |= (u64int)buf[i] << (8*i);

	for(i = MLDSA_N - tau; i < MLDSA_N; i++){
		/* Sample j uniform in [0, i] */
		do {
			shake256_squeeze(&s, buf, 1);
			b = buf[0];
		} while(b > i);

		pos = b;
		c[i] = c[pos];
		c[pos] = 1 - 2 * (int32)(signs & 1);
		signs >>= 1;
	}
}

/*
 * Matrix-vector multiplication in NTT domain: t = A * s
 * A is k x l, s is l-vector, t is k-vector.
 * Uses heap-allocated temporaries to avoid stack overflow.
 */
static int
matvec_mul_dsa(int32 t[][MLDSA_N],
	const uchar rho[32], int k, int l,
	int32 s[][MLDSA_N])
{
	int i, j;
	int32 *a_ij, *tmp;

	a_ij = malloc(MLDSA_N * sizeof(int32));
	tmp = malloc(MLDSA_N * sizeof(int32));
	if(a_ij == nil || tmp == nil){
		free(a_ij);
		free(tmp);
		return -1;
	}

	for(i = 0; i < k; i++){
		mldsa_poly_uniform(a_ij, rho, (uchar)i, 0);
		mldsa_poly_pointwise(t[i], a_ij, s[0]);

		for(j = 1; j < l; j++){
			mldsa_poly_uniform(a_ij, rho, (uchar)i, (uchar)j);
			mldsa_poly_pointwise(tmp, a_ij, s[j]);
			mldsa_poly_add(t[i], t[i], tmp);
		}
		mldsa_poly_reduce(t[i]);
	}

	/* tmp held a product with s (the secret s1, or a signature's mask) */
	secureZero(tmp, MLDSA_N * sizeof(int32));
	free(a_ij);
	free(tmp);
	return 0;
}

/*
 * Heap-allocated state for keygen to avoid stack overflow.
 */
typedef struct {
	int32	s1[MLDSA_MAXL][MLDSA_N];
	int32	s2[MLDSA_MAXK][MLDSA_N];
	int32	t[MLDSA_MAXK][MLDSA_N];
	int32	t1[MLDSA_N];
	int32	t0[MLDSA_N];
} MLDSAKeygenState;

/*
 * ML-DSA.KeyGen_internal: the key pair of the seed xi.
 * Algorithm 6 in FIPS 204.
 */
static int
keygen_xi(uchar *pk, uchar *sk, const uchar xi[32],
	int k, int l, int eta)
{
	MLDSAKeygenState *st;
	uchar seed[32], buf[128];
	uchar rho[32], rhoprime[64], K[32];
	int i, j;
	u16int nonce;
	int pkoff, skoff, eta_bytes;

	st = malloc(sizeof(MLDSAKeygenState));
	if(st == nil)
		return -1;

	memmove(seed, xi, 32);

	/* (rho, rhoprime, K) = H(seed || k || l) */
	{
		SHA3state hs;
		uchar kl[2];

		kl[0] = (uchar)k;
		kl[1] = (uchar)l;
		shake256_init(&hs);
		shake256_absorb(&hs, seed, 32);
		shake256_absorb(&hs, kl, 2);
		shake256_finalize(&hs);
		shake256_squeeze(&hs, buf, 128);
		secureZero(&hs, sizeof(hs));
	}
	memmove(rho, buf, 32);
	memmove(rhoprime, buf+32, 64);
	memmove(K, buf+96, 32);
	secureZero(buf, sizeof(buf));	/* rho' and K: the secret key's seeds */

	/* Sample s1 (l polynomials) and s2 (k polynomials) */
	nonce = 0;
	for(i = 0; i < l; i++){
		mldsa_poly_uniform_eta(st->s1[i], rhoprime, nonce, eta);
		nonce++;
	}
	for(i = 0; i < k; i++){
		mldsa_poly_uniform_eta(st->s2[i], rhoprime, nonce, eta);
		nonce++;
	}

	/* Pack s1, s2 into sk BEFORE NTT (eta-dependent bit packing) */
	eta_bytes = (eta == 4) ? 128 : 96;
	skoff = 128;	/* skip rho(32) + K(32) + tr(64) header */
	for(i = 0; i < l; i++){
		mldsa_poly_pack_eta(sk + skoff, st->s1[i], eta);
		skoff += eta_bytes;
	}
	for(i = 0; i < k; i++){
		mldsa_poly_pack_eta(sk + skoff, st->s2[i], eta);
		skoff += eta_bytes;
	}

	/* NTT(s1) for matrix multiplication */
	for(i = 0; i < l; i++)
		mldsa_ntt(st->s1[i]);

	/* t = A * NTT(s1) */
	if(matvec_mul_dsa(st->t, rho, k, l, st->s1) != 0){
		secureZero(seed, sizeof(seed));
		secureZero(rhoprime, sizeof(rhoprime));
		secureZero(K, sizeof(K));
		secureZero(st, sizeof(MLDSAKeygenState));
		free(st);
		return -1;
	}

	/* t = INTT(t) + s2 */
	for(i = 0; i < k; i++){
		mldsa_invntt(st->t[i]);
		mldsa_poly_add(st->t[i], st->t[i], st->s2[i]);
		mldsa_poly_reduce(st->t[i]);
	}

	/* Power2Round: t = t1 * 2^d + t0 */
	/* Public key: pk = (rho || t1) */
	memmove(pk, rho, 32);
	pkoff = 32;

	for(i = 0; i < k; i++){
		for(j = 0; j < MLDSA_N; j++){
			int32 hi, lo;
			mldsa_power2round(&hi, &lo, st->t[i][j]);
			st->t1[j] = hi;
			st->t0[j] = lo;
		}
		mldsa_poly_pack_t1(pk + pkoff, st->t1);
		pkoff += 320;

		/* Pack t0 into sk */
		mldsa_poly_pack_t0(sk + skoff, st->t0);
		skoff += 416;
	}

	/* Fill sk header: rho || K || tr */
	{
		uchar tr[64];
		shake256((const uchar *)pk, pkoff, tr, 64);

		memmove(sk, rho, 32);
		memmove(sk + 32, K, 32);
		memmove(sk + 64, tr, 64);
	}

	/* Clear sensitive data */
	secureZero(seed, sizeof(seed));
	secureZero(rhoprime, sizeof(rhoprime));
	secureZero(K, sizeof(K));
	secureZero(st, sizeof(MLDSAKeygenState));
	free(st);

	return 0;
}

/*
 * Heap-allocated state for signing to avoid stack overflow.
 */
typedef struct {
	int32	s1[MLDSA_MAXL][MLDSA_N];
	int32	s2[MLDSA_MAXK][MLDSA_N];
	int32	t0[MLDSA_MAXK][MLDSA_N];
	int32	y[MLDSA_MAXL][MLDSA_N];
	int32	w[MLDSA_MAXK][MLDSA_N];
	int32	w1[MLDSA_MAXK][MLDSA_N];
	int32	z[MLDSA_MAXL][MLDSA_N];
	int32	c[MLDSA_N];
	int32	h[MLDSA_MAXK][MLDSA_N];
	int32	yhat[MLDSA_MAXL][MLDSA_N];
	int32	chat[MLDSA_N];
	int32	tmp[MLDSA_N];
	int32	tmp2[MLDSA_N];
} MLDSASignState;

/*
 * The most rounds of the rejection loop before signing gives up.  FIPS
 * 204 Appendix C allows a bound and gives 814 as one a key that is a
 * key reaches with probability below 2^-256 (a round succeeds about
 * once in five).  A secret key whose s1 or s2 is not short (a damaged
 * or made-up key file) may never be accepted; the loop used to have no
 * end, and its counter of masks, 16 bits, came round.
 */
#ifndef MLDSA_MAXROUNDS
#define MLDSA_MAXROUNDS	814	/* a test builds with less, to see the bound kept */
#endif

/*
 * ML-DSA.Sign_internal: Signature generation.
 * Algorithm 7 in FIPS 204.  M' is pre || msg (the header of Algorithm 2
 * and the message, which need not be joined to be hashed); or, with
 * extmu not nil, mu is given and no message is hashed (the standard's
 * note on line 6: mu may be made outside the module).  rnd is the 32
 * bytes of Algorithm 2 line 5: fresh random bytes for the hedged
 * variant, zeros for the deterministic one.
 *
 * Returns 0, or -1 with nothing written to sig.
 */
static int
sign_core(uchar *sig, const uchar *pre, int prelen,
	const uchar *msg, ulong msglen, const uchar *extmu,
	const uchar rnd[32],
	const uchar *sk, int k, int l, int eta, int tau, int32 beta,
	int gamma1_bits, int32 gamma2, int omega, int ctildelen)
{
	MLDSASignState *st;
	uchar rho[32], K[32], tr[64];
	uchar mu[64], rhoprime[64];
	uchar ctilde[64];
	int skoff, i, j;
	u16int kappa;
	int reject, hints_n, rounds;
	int sigoff, eta_bytes;

	st = malloc(sizeof(MLDSASignState));
	if(st == nil)
		return -1;

	/* Unpack secret key */
	eta_bytes = (eta == 4) ? 128 : 96;
	skoff = 0;
	memmove(rho, sk + skoff, 32); skoff += 32;
	memmove(K, sk + skoff, 32); skoff += 32;
	memmove(tr, sk + skoff, 64); skoff += 64;

	for(i = 0; i < l; i++){
		mldsa_poly_unpack_eta(st->s1[i], sk + skoff, eta);
		skoff += eta_bytes;
	}
	for(i = 0; i < k; i++){
		mldsa_poly_unpack_eta(st->s2[i], sk + skoff, eta);
		skoff += eta_bytes;
	}
	for(i = 0; i < k; i++){
		mldsa_poly_unpack_t0(st->t0[i], sk + skoff);
		skoff += 416;
	}

	/* mu = H(tr || M') */
	if(extmu != nil)
		memmove(mu, extmu, 64);
	else{
		SHA3state hs;
		shake256_init(&hs);
		shake256_absorb(&hs, tr, 64);
		shake256_absorb(&hs, pre, prelen);
		shake256_absorb(&hs, msg, msglen);
		shake256_finalize(&hs);
		shake256_squeeze(&hs, mu, 64);
	}

	/*
	 * rho'' = H(K || rnd || mu): FIPS 204 Algorithm 7 line 7.  It was
	 * H(K || mu), with no rnd at all: neither the hedged variant nor
	 * the deterministic one (rnd of 32 zero bytes), and the same masks
	 * every time a message was signed, which is what an induced fault
	 * needs to recover the key from two signatures.  A verifier never
	 * sees rho''.
	 */
	{
		SHA3state hs;
		shake256_init(&hs);
		shake256_absorb(&hs, K, 32);
		shake256_absorb(&hs, rnd, 32);
		shake256_absorb(&hs, mu, 64);
		shake256_finalize(&hs);
		shake256_squeeze(&hs, rhoprime, 64);
		secureZero(&hs, sizeof(hs));	/* it absorbed K */
	}

	/* NTT(s1), NTT(s2), NTT(t0) for later use */
	for(i = 0; i < l; i++)
		mldsa_ntt(st->s1[i]);
	for(i = 0; i < k; i++){
		mldsa_ntt(st->s2[i]);
		mldsa_ntt(st->t0[i]);
	}

	/* Rejection sampling loop */
	kappa = 0;
	for(rounds = 0;; rounds++){
		if(rounds >= MLDSA_MAXROUNDS){
			secureZero(K, sizeof(K));
			secureZero(rhoprime, sizeof(rhoprime));
			secureZero(st, sizeof(MLDSASignState));
			free(st);
			return -1;
		}

		/* Sample y */
		for(i = 0; i < l; i++)
			mldsa_poly_uniform_gamma1(st->y[i], rhoprime, kappa + (u16int)i, gamma1_bits);
		kappa += (u16int)l;

		/* w = A * NTT(y) */
		for(i = 0; i < l; i++){
			memmove(st->yhat[i], st->y[i], sizeof(st->y[i]));
			mldsa_ntt(st->yhat[i]);
		}
		if(matvec_mul_dsa(st->w, rho, k, l, st->yhat) != 0){
			secureZero(K, sizeof(K));
			secureZero(rhoprime, sizeof(rhoprime));
			secureZero(st, sizeof(MLDSASignState));
			free(st);
			return -1;
		}

		for(i = 0; i < k; i++){
			mldsa_invntt(st->w[i]);
			mldsa_poly_reduce(st->w[i]);
		}

		/* w1 = HighBits(w) */
		for(i = 0; i < k; i++)
			for(j = 0; j < MLDSA_N; j++)
				st->w1[i][j] = mldsa_highbits(st->w[i][j], gamma2);

		/* ctilde = H(mu || w1_encoded)
		 * FIPS 204: w1 coefficients are packed as 4-bit nibbles
		 * for gamma2 = (q-1)/32, values in [0,15].
		 */
		{
			SHA3state hs;
			uchar w1_packed;

			shake256_init(&hs);
			shake256_absorb(&hs, mu, 64);
			for(i = 0; i < k; i++)
				for(j = 0; j < MLDSA_N; j += 2){
					w1_packed = (uchar)((st->w1[i][j] & 0x0F) |
						((st->w1[i][j+1] & 0x0F) << 4));
					shake256_absorb(&hs, &w1_packed, 1);
				}
			shake256_finalize(&hs);
			shake256_squeeze(&hs, ctilde, ctildelen);
		}

		/* c = SampleInBall(ctilde) */
		sample_challenge(st->c, ctilde, ctildelen, tau);

		/* z = y + c * s1 (NTT domain) */
		memmove(st->chat, st->c, sizeof(st->c));
		mldsa_ntt(st->chat);

		reject = 0;
		for(i = 0; i < l; i++){
			mldsa_poly_pointwise(st->tmp, st->chat, st->s1[i]);
			mldsa_invntt(st->tmp);
			mldsa_poly_add(st->z[i], st->y[i], st->tmp);
			mldsa_poly_reduce(st->z[i]);
		}

		/* Check ||z||_inf < gamma1 - beta */
		for(i = 0; i < l; i++)
			reject |= mldsa_poly_chknorm(st->z[i], (1 << gamma1_bits) - beta);

		if(reject)
			continue;

		/* r0 = LowBits(w - c*s2) */
		/* Check ||r0||_inf < gamma2 - beta */
		for(i = 0; i < k; i++){
			mldsa_poly_pointwise(st->tmp2, st->chat, st->s2[i]);
			mldsa_invntt(st->tmp2);
			mldsa_poly_sub(st->tmp, st->w[i], st->tmp2);
			mldsa_poly_reduce(st->tmp);
			for(j = 0; j < MLDSA_N; j++){
				int32 r0 = mldsa_lowbits(st->tmp[j], gamma2);
				int32 sgn = r0 >> 31;
				r0 = (r0 ^ sgn) - sgn;	/* |r0|, with no branch on its sign */
				if(r0 >= gamma2 - beta){
					reject = 1;
					break;
				}
			}
			if(reject) break;
		}
		if(reject)
			continue;

		/* Compute hints */
		hints_n = 0;
		for(i = 0; i < k; i++){
			mldsa_poly_pointwise(st->tmp2, st->chat, st->t0[i]);
			mldsa_invntt(st->tmp2);

			/* Check ||ct0||_inf < gamma2 */
			if(mldsa_poly_chknorm(st->tmp2, gamma2)){
				reject = 1;
				break;
			}

			/* w - cs2 + ct0 */
			{
				int32 *cs2 = st->tmp;
				mldsa_poly_pointwise(cs2, st->chat, st->s2[i]);
				mldsa_invntt(cs2);
				mldsa_poly_sub(st->tmp, st->w[i], cs2);
				mldsa_poly_add(st->tmp, st->tmp, st->tmp2);
				mldsa_poly_reduce(st->tmp);
			}

			for(j = 0; j < MLDSA_N; j++){
				st->h[i][j] = mldsa_makehint(-st->tmp2[j], st->tmp[j], gamma2);
				hints_n += st->h[i][j];
			}
		}
		if(reject)
			continue;

		if(hints_n > omega)
			continue;

		break;	/* Success! */
	}

	/* Pack signature: (ctilde || z || hints) */
	sigoff = 0;
	memmove(sig + sigoff, ctilde, ctildelen);
	sigoff += ctildelen;

	/* Pack z: gamma1_bits+1 bits per coefficient */
	for(i = 0; i < l; i++){
		if(gamma1_bits == 17){
			/* 18-bit packing: 4 coefficients per 9 bytes (contiguous) */
			for(j = 0; j < MLDSA_N/4; j++){
				u32int t[4];
				int jj;
				for(jj = 0; jj < 4; jj++)
					t[jj] = (u32int)((1 << 17) - st->z[i][4*j+jj]);
				sig[sigoff+0] = (uchar)(t[0]);
				sig[sigoff+1] = (uchar)(t[0] >> 8);
				sig[sigoff+2] = (uchar)((t[0] >> 16) | (t[1] << 2));
				sig[sigoff+3] = (uchar)(t[1] >> 6);
				sig[sigoff+4] = (uchar)((t[1] >> 14) | (t[2] << 4));
				sig[sigoff+5] = (uchar)(t[2] >> 4);
				sig[sigoff+6] = (uchar)((t[2] >> 12) | (t[3] << 6));
				sig[sigoff+7] = (uchar)(t[3] >> 2);
				sig[sigoff+8] = (uchar)(t[3] >> 10);
				sigoff += 9;
			}
		} else {
			/* gamma1_bits == 19: 20-bit packing */
			for(j = 0; j < MLDSA_N/2; j++){
				u32int t0v, t1v;
				t0v = (u32int)((1 << 19) - st->z[i][2*j+0]);
				t1v = (u32int)((1 << 19) - st->z[i][2*j+1]);
				sig[sigoff+0] = (uchar)t0v;
				sig[sigoff+1] = (uchar)(t0v>>8);
				sig[sigoff+2] = (uchar)((t0v>>16) | (t1v<<4));
				sig[sigoff+3] = (uchar)(t1v>>4);
				sig[sigoff+4] = (uchar)(t1v>>12);
				sigoff += 5;
			}
		}
	}

	/* Pack hints */
	mldsa_pack_hint(sig + sigoff, omega + k, st->h, k, omega);

	/* Clear sensitive data */
	secureZero(K, sizeof(K));
	secureZero(rhoprime, sizeof(rhoprime));
	secureZero(st, sizeof(MLDSASignState));
	free(st);

	return 0;
}

/*
 * Heap-allocated state for verification.
 */
typedef struct {
	int32	t1[MLDSA_MAXK][MLDSA_N];
	int32	z[MLDSA_MAXL][MLDSA_N];
	int32	c[MLDSA_N];
	int32	h[MLDSA_MAXK][MLDSA_N];
	int32	w1prime[MLDSA_MAXK][MLDSA_N];
	int32	zhat[MLDSA_MAXL][MLDSA_N];
	int32	chat[MLDSA_N];
	int32	tmp[MLDSA_N];
} MLDSAVerifyState;

/*
 * ML-DSA.Verify_internal: Signature verification.
 * Algorithm 8 in FIPS 204; M' is pre || msg, or mu is given, as in
 * sign_core.
 */
static int
verify_core(const uchar *sig, const uchar *pre, int prelen,
	const uchar *msg, ulong msglen, const uchar *extmu,
	const uchar *pk, int k, int l, int eta, int tau, int32 beta,
	int gamma1_bits, int32 gamma2, int omega, int ctildelen, int siglen)
{
	MLDSAVerifyState *st;
	uchar rho[32];
	uchar mu[64], tr[64];
	const uchar *ctilde;
	uchar ctilde2[64];
	int pkoff, sigoff, i, j;
	int result;

	int expected_siglen;

	USED(eta);

	/* Validate signature length */
	expected_siglen = ctildelen + l * (MLDSA_N * (1 + gamma1_bits) / 8) + omega + k;
	if(siglen != expected_siglen)
		return 0;

	st = malloc(sizeof(MLDSAVerifyState));
	if(st == nil)
		return 0;

	/* Unpack public key */
	memmove(rho, pk, 32);
	pkoff = 32;
	for(i = 0; i < k; i++){
		mldsa_poly_unpack_t1(st->t1[i], pk + pkoff);
		pkoff += 320;
	}

	/* tr = H(pk) */
	shake256((const uchar *)pk, pkoff, tr, 64);

	/* mu = H(tr || M') */
	if(extmu != nil)
		memmove(mu, extmu, 64);
	else{
		SHA3state hs;
		shake256_init(&hs);
		shake256_absorb(&hs, tr, 64);
		shake256_absorb(&hs, pre, prelen);
		shake256_absorb(&hs, msg, msglen);
		shake256_finalize(&hs);
		shake256_squeeze(&hs, mu, 64);
	}

	/* Unpack signature: (ctilde || z || hints) */
	sigoff = 0;
	ctilde = sig + sigoff;
	sigoff += ctildelen;

	/* Unpack z */
	for(i = 0; i < l; i++){
		if(gamma1_bits == 19){
			for(j = 0; j < MLDSA_N/2; j++){
				u32int t0v, t1v;
				t0v  = (u32int)sig[sigoff+0];
				t0v |= (u32int)sig[sigoff+1] << 8;
				t0v |= ((u32int)sig[sigoff+2] & 0x0F) << 16;
				t1v  = (u32int)sig[sigoff+2] >> 4;
				t1v |= (u32int)sig[sigoff+3] << 4;
				t1v |= (u32int)sig[sigoff+4] << 12;
				t0v &= 0xFFFFF;
				t1v &= 0xFFFFF;
				st->z[i][2*j+0] = (1 << 19) - (int32)t0v;
				st->z[i][2*j+1] = (1 << 19) - (int32)t1v;
				sigoff += 5;
			}
		} else {
			/* gamma1_bits == 17: 18-bit unpacking (contiguous) */
			for(j = 0; j < MLDSA_N/4; j++){
				u32int t0v, t1v, t2v, t3v;
				t0v  = (u32int)sig[sigoff+0];
				t0v |= (u32int)sig[sigoff+1] << 8;
				t0v |= (u32int)sig[sigoff+2] << 16;
				t0v &= 0x3FFFF;

				t1v  = (u32int)sig[sigoff+2] >> 2;
				t1v |= (u32int)sig[sigoff+3] << 6;
				t1v |= (u32int)sig[sigoff+4] << 14;
				t1v &= 0x3FFFF;

				t2v  = (u32int)sig[sigoff+4] >> 4;
				t2v |= (u32int)sig[sigoff+5] << 4;
				t2v |= (u32int)sig[sigoff+6] << 12;
				t2v &= 0x3FFFF;

				t3v  = (u32int)sig[sigoff+6] >> 6;
				t3v |= (u32int)sig[sigoff+7] << 2;
				t3v |= (u32int)sig[sigoff+8] << 10;
				t3v &= 0x3FFFF;

				st->z[i][4*j+0] = (1 << 17) - (int32)t0v;
				st->z[i][4*j+1] = (1 << 17) - (int32)t1v;
				st->z[i][4*j+2] = (1 << 17) - (int32)t2v;
				st->z[i][4*j+3] = (1 << 17) - (int32)t3v;
				sigoff += 9;
			}
		}
	}

	/* Check ||z||_inf < gamma1 - beta */
	for(i = 0; i < l; i++)
		if(mldsa_poly_chknorm(st->z[i], (1 << gamma1_bits) - beta)){
			free(st);
			return 0;
		}

	/* Unpack hints */
	if(mldsa_unpack_hint(st->h, k, sig + sigoff, omega) < 0){
		free(st);
		return 0;
	}

	/* c = SampleInBall(ctilde) */
	sample_challenge(st->c, ctilde, ctildelen, tau);

	/* w1' = UseHint(h, A*NTT(z) - NTT(c)*NTT(t1*2^d)) */
	for(i = 0; i < l; i++){
		memmove(st->zhat[i], st->z[i], sizeof(st->z[i]));
		mldsa_ntt(st->zhat[i]);
	}
	memmove(st->chat, st->c, sizeof(st->c));
	mldsa_ntt(st->chat);

	/* Az = A * NTT(z) */
	if(matvec_mul_dsa(st->w1prime, rho, k, l, st->zhat) != 0){
		free(st);
		return 0;
	}

	/* w1' = Az - c * t1 * 2^d */
	for(i = 0; i < k; i++){
		int32 *t1_scaled = st->tmp;
		for(j = 0; j < MLDSA_N; j++)
			t1_scaled[j] = st->t1[i][j] << MLDSA_D;
		mldsa_ntt(t1_scaled);
		mldsa_poly_pointwise(st->tmp, st->chat, t1_scaled);
		mldsa_poly_sub(st->w1prime[i], st->w1prime[i], st->tmp);
		/*
		 * Reduced before the inverse transform, as every other
		 * input to it is: a difference of a reduced sum and a
		 * product can be 12.7M either way, and invntt adds 256 of
		 * them into one coefficient, which an int32 holds only if
		 * they do not all lean one way.  The signature decides them.
		 */
		mldsa_poly_reduce(st->w1prime[i]);
		mldsa_invntt(st->w1prime[i]);
		mldsa_poly_reduce(st->w1prime[i]);

		/* Apply hints */
		for(j = 0; j < MLDSA_N; j++)
			st->w1prime[i][j] = mldsa_usehint(st->h[i][j], st->w1prime[i][j], gamma2);
	}

	/* ctilde' = H(mu || w1'_encoded)
	 * FIPS 204: w1 coefficients are packed as 4-bit nibbles
	 * for gamma2 = (q-1)/32, values in [0,15].
	 */
	{
		SHA3state hs;
		uchar w1_packed;

		shake256_init(&hs);
		shake256_absorb(&hs, mu, 64);
		for(i = 0; i < k; i++)
			for(j = 0; j < MLDSA_N; j += 2){
				w1_packed = (uchar)((st->w1prime[i][j] & 0x0F) |
					((st->w1prime[i][j+1] & 0x0F) << 4));
				shake256_absorb(&hs, &w1_packed, 1);
			}
		shake256_finalize(&hs);
		shake256_squeeze(&hs, ctilde2, ctildelen);
	}

	/* Compare ctilde == ctilde' */
	{
		int diff = 0;
		for(i = 0; i < ctildelen; i++)
			diff |= ctilde[i] ^ ctilde2[i];
		result = (diff == 0);
	}

	free(st);
	return result;
}

/*
 * The two parameter sets, by number.
 */
static int
keygen_set(int set, uchar *pk, uchar *sk, const uchar xi[32])
{
	if(set == 65)
		return keygen_xi(pk, sk, xi, MLDSA65_K, MLDSA65_L, MLDSA65_ETA);
	if(set == 87)
		return keygen_xi(pk, sk, xi, MLDSA87_K, MLDSA87_L, MLDSA87_ETA);
	return -1;
}

static int
sign_set(int set, uchar *sig, const uchar *pre, int prelen,
	const uchar *msg, ulong msglen, const uchar *mu,
	const uchar rnd[32], const uchar *sk)
{
	if(set == 65)
		return sign_core(sig, pre, prelen, msg, msglen, mu, rnd, sk,
			MLDSA65_K, MLDSA65_L, MLDSA65_ETA, MLDSA65_TAU, MLDSA65_BETA,
			19, MLDSA65_GAMMA2, MLDSA65_OMEGA, MLDSA65_CTILDELEN);
	if(set == 87)
		return sign_core(sig, pre, prelen, msg, msglen, mu, rnd, sk,
			MLDSA87_K, MLDSA87_L, MLDSA87_ETA, MLDSA87_TAU, MLDSA87_BETA,
			19, MLDSA87_GAMMA2, MLDSA87_OMEGA, MLDSA87_CTILDELEN);
	return -1;
}

static int
verify_set(int set, const uchar *sig, const uchar *pre, int prelen,
	const uchar *msg, ulong msglen, const uchar *mu, const uchar *pk)
{
	if(set == 65)
		return verify_core(sig, pre, prelen, msg, msglen, mu, pk,
			MLDSA65_K, MLDSA65_L, MLDSA65_ETA, MLDSA65_TAU, MLDSA65_BETA,
			19, MLDSA65_GAMMA2, MLDSA65_OMEGA, MLDSA65_CTILDELEN, MLDSA65_SIGLEN);
	if(set == 87)
		return verify_core(sig, pre, prelen, msg, msglen, mu, pk,
			MLDSA87_K, MLDSA87_L, MLDSA87_ETA, MLDSA87_TAU, MLDSA87_BETA,
			19, MLDSA87_GAMMA2, MLDSA87_OMEGA, MLDSA87_CTILDELEN, MLDSA87_SIGLEN);
	return 0;
}

/*
 * ML-DSA.KeyGen, FIPS 204 Algorithm 1: a key pair from 32 random bytes.
 */
static int
keygen(int set, uchar *pk, uchar *sk)
{
	uchar xi[32];
	int r;

	genrandom(xi, sizeof(xi));
	r = keygen_set(set, pk, sk, xi);
	secureZero(xi, sizeof(xi));
	return r;
}

/*
 * ML-DSA.Sign, FIPS 204 Algorithm 2: the pure signature of msg under the
 * context string ctx (at most 255 bytes, line 1), hedged (line 5: rnd
 * is 32 fresh random bytes).  What is signed is
 *	M' = IntegerToBytes(0, 1) || IntegerToBytes(|ctx|, 1) || ctx || M
 * (line 10).  These functions used to be Sign_internal on the caller's
 * bytes, the interface section 5 keeps for testing: with no header, a
 * signature made here on 00 00 || X was to every conforming verifier
 * the signature of X, and none made here verified elsewhere.
 */
static int
sign(int set, uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *sk)
{
	uchar pre[2+255], rnd[32];
	int r;

	if(ctxlen < 0 || ctxlen > 255 || (ctxlen > 0 && ctx == nil))
		return -1;
	pre[0] = 0;
	pre[1] = ctxlen;
	if(ctxlen > 0)
		memmove(pre+2, ctx, ctxlen);
	genrandom(rnd, sizeof(rnd));
	r = sign_set(set, sig, pre, 2+ctxlen, msg, msglen, nil, rnd, sk);
	secureZero(rnd, sizeof(rnd));
	return r;
}

/*
 * ML-DSA.Verify, FIPS 204 Algorithm 3.
 */
static int
verify(int set, const uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *pk)
{
	uchar pre[2+255];

	if(ctxlen < 0 || ctxlen > 255 || (ctxlen > 0 && ctx == nil))
		return 0;
	pre[0] = 0;
	pre[1] = ctxlen;
	if(ctxlen > 0)
		memmove(pre+2, ctx, ctxlen);
	return verify_set(set, sig, pre, 2+ctxlen, msg, msglen, nil, pk);
}

/*
 * The standard's internal interfaces (Algorithms 6, 7 and 8), which
 * take the randomness as an argument: for known-answer tests (NIST's
 * ACVP vectors are of these as well as of the external ones), not for
 * an application (FIPS 204 section 5).  set is 65 or 87.  mp is M'
 * whole; with mu not nil it is used and mp is not looked at.
 */
int
mldsa_keygen_internal(int set, uchar *pk, uchar *sk, const uchar xi[32])
{
	return keygen_set(set, pk, sk, xi);
}

int
mldsa_sign_internal(int set, uchar *sig, const uchar *mp, ulong mplen,
	const uchar *mu, const uchar rnd[32], const uchar *sk)
{
	return sign_set(set, sig, nil, 0, mp, mplen, mu, rnd, sk);
}

int
mldsa_verify_internal(int set, const uchar *sig, const uchar *mp, ulong mplen,
	const uchar *mu, const uchar *pk)
{
	return verify_set(set, sig, nil, 0, mp, mplen, mu, pk);
}

/*
 * Public API: ML-DSA-65
 */

int
mldsa65_keygen(uchar *pk, uchar *sk)
{
	return keygen(65, pk, sk);
}

int
mldsa65_sign(uchar *sig, const uchar *msg, ulong msglen, const uchar *sk)
{
	return sign(65, sig, msg, msglen, nil, 0, sk);
}

int
mldsa65_sign_ctx(uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *sk)
{
	return sign(65, sig, msg, msglen, ctx, ctxlen, sk);
}

int
mldsa65_verify(const uchar *sig, const uchar *msg, ulong msglen, const uchar *pk)
{
	return verify(65, sig, msg, msglen, nil, 0, pk);
}

int
mldsa65_verify_ctx(const uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *pk)
{
	return verify(65, sig, msg, msglen, ctx, ctxlen, pk);
}

/*
 * Public API: ML-DSA-87
 */

int
mldsa87_keygen(uchar *pk, uchar *sk)
{
	return keygen(87, pk, sk);
}

int
mldsa87_sign(uchar *sig, const uchar *msg, ulong msglen, const uchar *sk)
{
	return sign(87, sig, msg, msglen, nil, 0, sk);
}

int
mldsa87_sign_ctx(uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *sk)
{
	return sign(87, sig, msg, msglen, ctx, ctxlen, sk);
}

int
mldsa87_verify(const uchar *sig, const uchar *msg, ulong msglen, const uchar *pk)
{
	return verify(87, sig, msg, msglen, nil, 0, pk);
}

int
mldsa87_verify_ctx(const uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *pk)
{
	return verify(87, sig, msg, msglen, ctx, ctxlen, pk);
}
