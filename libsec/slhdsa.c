/*
 * SLH-DSA Digital Signature Algorithm (FIPS 205)
 *
 * Stateless Hash-Based Digital Signature Standard.
 * Implements SLH-DSA-SHAKE-192s (NIST Level 3) and
 * SLH-DSA-SHAKE-256s (NIST Level 5).
 *
 * SLH-DSA provides conservative, hash-based signatures with no
 * lattice assumptions — security relies only on the hash function
 * (SHAKE-256). This makes it a valuable backup for ML-DSA in case
 * lattice problems are unexpectedly broken.
 *
 * Key sizes:
 *   192s: pk=48, sk=96, sig=16224  (NIST Level 3)
 *   256s: pk=64, sk=128, sig=29792 (NIST Level 5)
 *
 * Working state is heap-allocated to avoid stack overflow in the
 * Inferno emulator's 32KB thread stacks.
 *
 * Reference: NIST FIPS 205 "Stateless Hash-Based Digital Signature
 * Standard" (August 2024).
 */
#include "os.h"
#include <libsec.h>

/*
 * SLH-DSA-SHAKE-192s parameters (FIPS 205 Table 2)
 *   n=24, h=63, d=7, h'=9, a=14, k=17, lg(w)=4
 *   len = 2*24 + 3 = 51  (WOTS+ chains)
 *
 * SLH-DSA-SHAKE-256s parameters (FIPS 205 Table 2)
 *   n=32, h=64, d=8, h'=8, a=14, k=22, lg(w)=4
 *   len = 2*32 + 3 = 67
 */
enum {
	/* SLH-DSA-SHAKE-192s (FIPS 205 Table 2) */
	S192_N		= 24,
	S192_H		= 63,
	S192_D		= 7,
	S192_HPRIME	= 9,	/* h/d = 63/7 */
	S192_A		= 14,
	S192_K		= 17,
	S192_WLEN	= 51,	/* 2*24 + 3 */

	/* SLH-DSA-SHAKE-256s (FIPS 205 Table 2) */
	S256_N		= 32,
	S256_H		= 64,
	S256_D		= 8,
	S256_HPRIME	= 8,	/* h/d = 64/8 */
	S256_A		= 14,
	S256_K		= 22,
	S256_WLEN	= 67,	/* 2*32 + 3 */

	/* Message digest sizes: ceil(k*a/8) + ceil((h-h')/8) + ceil(h'/8) */
	S192_MD_LEN	= 30 + 7 + 2,	/* 39 bytes */
	S256_MD_LEN	= 39 + 7 + 1,	/* 47 bytes */
	MAX_MD_LEN	= S256_MD_LEN,
};

/* Forward declarations */
extern void slhdsa_adrs_init(uchar*);
extern void slhdsa_adrs_set_layer(uchar*, u32int);
extern void slhdsa_adrs_set_tree(uchar*, u64int);
extern void slhdsa_adrs_set_type(uchar*, u32int);
extern void slhdsa_adrs_set_keypair(uchar*, u32int);
extern void slhdsa_adrs_copy(uchar*, const uchar*);
extern void slhdsa_H_msg(uchar*, int, const uchar*, int, const uchar*, int, const uchar*, int, const uchar*, int, const uchar*, ulong);
extern void slhdsa_PRF_msg(uchar*, int, const uchar*, int, const uchar*, int, const uchar*, int, const uchar*, ulong);

extern int  slhdsa_treehash(uchar*, uchar*, int, const uchar*, int, const uchar*, int, u32int, u64int, int, int);
extern int  slhdsa_fors_sign(uchar*, int, const uchar*, const uchar*, int, const uchar*, int, uchar*, int, int);
extern int  slhdsa_fors_pk_from_sig(uchar*, int, const uchar*, const uchar*, const uchar*, int, uchar*, int, int);
extern int  slhdsa_ht_sign(uchar*, int, const uchar*, const uchar*, int, const uchar*, int, u64int, u32int, int, int);
extern int  slhdsa_ht_verify(const uchar*, int, const uchar*, const uchar*, int, const uchar*, u64int, u32int, int, int);
extern int  slhdsa_wots_len(int);

/*
 * M' for the pure signature: FIPS 205 Algorithms 22 (slh_sign) and 24
 * (slh_verify),
 *	M' = toByte(0, 1) || toByte(|ctx|, 1) || ctx || M
 * with ctx a context string of at most 255 bytes.  The header and the
 * message are hashed one after the other and need not be joined: the
 * functions below take M' as pre || msg.  (The caller's message used to
 * be hashed as it came: the internal interface, which section 9 says is
 * not to be an application's, and under which a message beginning 00 00
 * was to a conforming verifier a signature on the rest of it.)
 */
enum { Maxctx = 255 };

static int
mheader(uchar *pre, const uchar *ctx, int ctxlen)
{
	if(ctxlen < 0 || ctxlen > Maxctx || (ctxlen > 0 && ctx == nil))
		return -1;
	pre[0] = 0;
	pre[1] = ctxlen;
	if(ctxlen > 0)
		memmove(pre+2, ctx, ctxlen);
	return 2+ctxlen;
}

/*
 * Tree index and leaf index from the message digest.
 *
 * FIPS 205 Algorithm 19 (and Algorithm 20, the same lines): H_msg's
 * m bytes are three byte strings,
 *	md           ceil(k*a/8) bytes           the FORS message
 *	tmp_idx_tree ceil((h - h/d)/8) bytes
 *	tmp_idx_leaf ceil(h/(8d)) bytes
 * and the indices are the two integers reduced:
 *	idx_tree = toInt(tmp_idx_tree) mod 2^(h - h/d)
 *	idx_leaf = toInt(tmp_idx_leaf) mod 2^(h/d)
 * that is, the low bits of each byte string.  (They used to be read as
 * one bit string from bit k*a on, which is other bits of the digest
 * whenever k*a or h - h/d is not a multiple of 8, as in both sets here.)
 */
static void
split_digest(const uchar *digest,
	int k, int a, int h, int hprime,
	u64int *idx_tree, u32int *idx_leaf)
{
	int mdlen, treelen, leaflen, i;
	u64int treev;
	u32int leafv;

	mdlen = (k * a + 7) / 8;
	treelen = (h - hprime + 7) / 8;	/* 7 for both sets */
	leaflen = (hprime + 7) / 8;

	treev = 0;
	for(i = 0; i < treelen; i++)
		treev = (treev << 8) | digest[mdlen + i];
	if(h - hprime < 64)
		treev &= (1ULL << (h - hprime)) - 1;

	leafv = 0;
	for(i = 0; i < leaflen; i++)
		leafv = (leafv << 8) | digest[mdlen + treelen + i];
	leafv &= (1U << hprime) - 1;

	*idx_tree = treev;
	*idx_leaf = leafv;
}

/*
 * slh_keygen_internal, FIPS 205 Algorithm 18: the key pair of the three
 * n-byte seeds.
 *
 * SK = (SK.seed || SK.prf || PK.seed || PK.root)
 * PK = (PK.seed || PK.root)
 */
static int
keygen_seeds(uchar *pk, uchar *sk,
	const uchar *skseed0, const uchar *skprf0, const uchar *pkseed0,
	int n, int hprime, int d)
{
	uchar skseed[32], skprf[32], pkseed[32];
	uchar root[32];

	memmove(skseed, skseed0, n);
	memmove(skprf, skprf0, n);
	memmove(pkseed, pkseed0, n);

	/* Compute root of the top XMSS tree */
	if(slhdsa_treehash(root, nil, n, pkseed, n, skseed, n,
		d - 1, 0, hprime, -1) != 0){
		secureZero(skseed, sizeof(skseed));
		secureZero(skprf, sizeof(skprf));
		return -1;
	}

	/* Assemble SK: SK.seed || SK.prf || PK.seed || PK.root */
	memmove(sk, skseed, n);
	memmove(sk + n, skprf, n);
	memmove(sk + 2*n, pkseed, n);
	memmove(sk + 3*n, root, n);

	/* Assemble PK: PK.seed || PK.root */
	memmove(pk, pkseed, n);
	memmove(pk + n, root, n);

	secureZero(skseed, sizeof(skseed));
	secureZero(skprf, sizeof(skprf));

	return 0;
}

/*
 * slh_keygen, FIPS 205 Algorithm 21: the seeds are random.
 */
static int
slhdsa_keygen(uchar *pk, uchar *sk, int n, int hprime, int d)
{
	uchar seeds[3*32];
	int r;

	genrandom(seeds, 3*n);
	r = keygen_seeds(pk, sk, seeds, seeds+n, seeds+2*n, n, hprime, d);
	secureZero(seeds, sizeof(seeds));
	return r;
}

/*
 * slh_sign_internal, FIPS 205 Algorithm 19, on M' = pre || msg.
 * addrnd is the n bytes of additional randomness: opt_rand is addrnd,
 * or with none (nil) PK.seed, the deterministic variant.
 *
 * Returns 0 with the signature in sig, or -1 with sig cleared.
 *
 * sig = R || SIG_FORS || SIG_HT
 */
static int
sign_core(uchar *sig, const uchar *pre, int prelen,
	const uchar *msg, ulong msglen, const uchar *addrnd,
	const uchar *sk, int n, int h, int d, int hprime, int a, int k)
{
	const uchar *skseed, *skprf, *pkseed, *pkroot;
	uchar adrs[32];
	uchar *sig0, *R;
	const uchar *opt_rand;
	uchar digest[MAX_MD_LEN];
	int digestlen;
	int fors_siglen, siglen;
	u64int idx_tree;
	u32int idx_leaf;
	uchar fors_pk[32];

	skseed = sk;
	skprf = sk + n;
	pkseed = sk + 2*n;
	pkroot = sk + 3*n;

	fors_siglen = k * (a + 1) * n;
	siglen = n + fors_siglen + d * (slhdsa_wots_len(n) + hprime) * n;
	digestlen = (k * a + 7) / 8 + (h - hprime + 7) / 8 + (hprime + 7) / 8;
	if(digestlen > sizeof(digest))
		return -1;

	sig0 = sig;
	R = sig;

	/* Algorithm 19 lines 2 to 4 */
	opt_rand = addrnd;
	if(opt_rand == nil)
		opt_rand = pkseed;

	/* R = PRF_msg(SK.prf, opt_rand, M') */
	slhdsa_PRF_msg(R, n, skprf, n, opt_rand, n,
		pre, prelen, msg, msglen);
	sig += n;

	/* Compute message digest */
	slhdsa_H_msg(digest, digestlen, R, n, pkseed, n, pkroot, n,
		pre, prelen, msg, msglen);

	/* Extract tree and leaf indices */
	split_digest(digest, k, a, h, hprime, &idx_tree, &idx_leaf);

	/* FORS signature */
	slhdsa_adrs_init(adrs);
	slhdsa_adrs_set_tree(adrs, idx_tree);
	slhdsa_adrs_set_type(adrs, 3);	/* FORS_TREE */
	slhdsa_adrs_set_keypair(adrs, idx_leaf);

	if(slhdsa_fors_sign(sig, n, digest, pkseed, n, skseed, n, adrs, k, a) != 0)
		goto fail;

	/* Compute FORS public key */
	slhdsa_adrs_set_type(adrs, 3);
	slhdsa_adrs_set_keypair(adrs, idx_leaf);
	if(slhdsa_fors_pk_from_sig(fors_pk, n, sig, digest, pkseed, n, adrs, k, a) != 0)
		goto fail;
	sig += fors_siglen;

	/* Hypertree signature on FORS public key */
	if(slhdsa_ht_sign(sig, n, fors_pk, pkseed, n, skseed, n,
		idx_tree, idx_leaf, hprime, d) != 0)
		goto fail;

	/*
	 * What was made must lead to PK.root, or it does not leave: a
	 * computation that went wrong on the way up (and was not told of
	 * above) has had one-time keys sign values that are not the
	 * tree's.  A few thousand hashes after three million.
	 */
	if(slhdsa_ht_verify(sig, n, fors_pk, pkseed, n, pkroot,
		idx_tree, idx_leaf, hprime, d) != 1)
		goto fail;

	secureZero(fors_pk, sizeof(fors_pk));
	return 0;

fail:
	/*
	 * No signature, and nothing of one: a part made before the failure
	 * (a FORS signature with no hypertree over it, some layers' WOTS+
	 * signatures) is still the secret key's work on this message.
	 * The whole buffer is cleared, R included, and the caller is told.
	 * It used to be told 0 with the signature half made.
	 */
	secureZero(sig0, siglen);
	secureZero(fors_pk, sizeof(fors_pk));
	return -1;
}

/*
 * slh_verify_internal, FIPS 205 Algorithm 20, on M' = pre || msg.
 *
 * Returns 1 if valid, 0 if invalid, or if the answer could not be
 * worked out (no memory): a step that fails is a refusal, where it used
 * to leave the walk going on with whatever its buffer held.
 */
static int
verify_core(const uchar *sig, ulong siglen,
	const uchar *pre, int prelen, const uchar *msg, ulong msglen,
	const uchar *pk, int n, int h, int d, int hprime, int a, int k)
{
	const uchar *pkseed, *pkroot;
	const uchar *R;
	uchar adrs[32];
	uchar digest[MAX_MD_LEN];
	int digestlen;
	int fors_siglen, ht_siglen;
	int xmss_siglen;
	u64int idx_tree;
	u32int idx_leaf;
	uchar fors_pk[32];
	ulong expected_siglen;

	pkseed = pk;
	pkroot = pk + n;

	/* Compute expected signature length */
	xmss_siglen = (slhdsa_wots_len(n) + hprime) * n;
	fors_siglen = k * (a + 1) * n;
	ht_siglen = d * xmss_siglen;
	expected_siglen = n + fors_siglen + ht_siglen;

	if(siglen != expected_siglen)
		return 0;

	R = sig;
	sig += n;

	/* Compute message digest */
	digestlen = (k * a + 7) / 8 + (h - hprime + 7) / 8 + (hprime + 7) / 8;
	if(digestlen > sizeof(digest))
		return 0;

	slhdsa_H_msg(digest, digestlen, R, n, pkseed, n, pkroot, n,
		pre, prelen, msg, msglen);

	/* Extract tree and leaf indices */
	split_digest(digest, k, a, h, hprime, &idx_tree, &idx_leaf);

	/* Compute FORS public key from signature */
	slhdsa_adrs_init(adrs);
	slhdsa_adrs_set_tree(adrs, idx_tree);
	slhdsa_adrs_set_type(adrs, 3);	/* FORS_TREE */
	slhdsa_adrs_set_keypair(adrs, idx_leaf);

	if(slhdsa_fors_pk_from_sig(fors_pk, n, sig, digest, pkseed, n, adrs, k, a) != 0)
		return 0;
	sig += fors_siglen;

	/* Verify hypertree signature on FORS public key */
	return slhdsa_ht_verify(sig, n, fors_pk, pkseed, n, pkroot,
		idx_tree, idx_leaf, hprime, d);
}

/*
 * The two parameter sets, by number.
 */
typedef struct Set Set;
struct Set
{
	int	n, h, d, hprime, a, k;
};
static const Set s192 = { S192_N, S192_H, S192_D, S192_HPRIME, S192_A, S192_K };
static const Set s256 = { S256_N, S256_H, S256_D, S256_HPRIME, S256_A, S256_K };

static const Set*
setof(int set)
{
	if(set == 192)
		return &s192;
	if(set == 256)
		return &s256;
	return nil;
}

/*
 * slh_sign, FIPS 205 Algorithm 22: the pure signature of msg under the
 * context string ctx, hedged.  addrnd is n fresh random bytes (line 5;
 * section 9.2 makes this the default: without it every signature of a
 * message is the same, which is what a fault induced while signing
 * needs to have one-time keys sign twice).  It was the deterministic
 * variant, opt_rand = PK.seed.  With no generator nothing is signed:
 * genrandom gives bytes or does not return.
 */
static int
sign(const Set *p, uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *sk)
{
	uchar pre[2+Maxctx], addrnd[32];
	int prelen, r;

	prelen = mheader(pre, ctx, ctxlen);
	if(prelen < 0)
		return -1;
	genrandom(addrnd, p->n);
	r = sign_core(sig, pre, prelen, msg, msglen, addrnd, sk,
		p->n, p->h, p->d, p->hprime, p->a, p->k);
	secureZero(addrnd, sizeof(addrnd));
	return r;
}

/*
 * slh_verify, FIPS 205 Algorithm 24.
 */
static int
verify(const Set *p, const uchar *sig, ulong siglen,
	const uchar *msg, ulong msglen, const uchar *ctx, int ctxlen,
	const uchar *pk)
{
	uchar pre[2+Maxctx];
	int prelen;

	prelen = mheader(pre, ctx, ctxlen);
	if(prelen < 0)
		return 0;
	return verify_core(sig, siglen, pre, prelen, msg, msglen, pk,
		p->n, p->h, p->d, p->hprime, p->a, p->k);
}

/*
 * The standard's internal interfaces (Algorithms 18, 19 and 20), which
 * take the randomness as an argument: for known-answer tests (NIST's
 * ACVP vectors are of these as well as of the external ones), not for
 * an application (FIPS 205 section 9).  set is 192 or 256; the seeds
 * and addrnd are n bytes (24 or 32); mp is M' whole; with addrnd nil
 * the signature is the deterministic one.
 */
int
slhdsa_keygen_internal(int set, uchar *pk, uchar *sk,
	const uchar *skseed, const uchar *skprf, const uchar *pkseed)
{
	const Set *p;

	p = setof(set);
	if(p == nil)
		return -1;
	return keygen_seeds(pk, sk, skseed, skprf, pkseed, p->n, p->hprime, p->d);
}

int
slhdsa_sign_internal(int set, uchar *sig, const uchar *mp, ulong mplen,
	const uchar *addrnd, const uchar *sk)
{
	const Set *p;

	p = setof(set);
	if(p == nil)
		return -1;
	return sign_core(sig, nil, 0, mp, mplen, addrnd, sk,
		p->n, p->h, p->d, p->hprime, p->a, p->k);
}

int
slhdsa_verify_internal(int set, const uchar *sig, ulong siglen,
	const uchar *mp, ulong mplen, const uchar *pk)
{
	const Set *p;

	p = setof(set);
	if(p == nil)
		return 0;
	return verify_core(sig, siglen, nil, 0, mp, mplen, pk,
		p->n, p->h, p->d, p->hprime, p->a, p->k);
}

/*
 * Public API: SLH-DSA-SHAKE-192s
 */
int
slhdsa192s_keygen(uchar *pk, uchar *sk)
{
	return slhdsa_keygen(pk, sk, S192_N, S192_HPRIME, S192_D);
}

int
slhdsa192s_sign(uchar *sig, const uchar *msg, ulong msglen, const uchar *sk)
{
	return sign(&s192, sig, msg, msglen, nil, 0, sk);
}

int
slhdsa192s_sign_ctx(uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *sk)
{
	return sign(&s192, sig, msg, msglen, ctx, ctxlen, sk);
}

int
slhdsa192s_verify(const uchar *sig, ulong siglen,
	const uchar *msg, ulong msglen, const uchar *pk)
{
	return verify(&s192, sig, siglen, msg, msglen, nil, 0, pk);
}

int
slhdsa192s_verify_ctx(const uchar *sig, ulong siglen,
	const uchar *msg, ulong msglen, const uchar *ctx, int ctxlen,
	const uchar *pk)
{
	return verify(&s192, sig, siglen, msg, msglen, ctx, ctxlen, pk);
}

/*
 * Public API: SLH-DSA-SHAKE-256s
 */
int
slhdsa256s_keygen(uchar *pk, uchar *sk)
{
	return slhdsa_keygen(pk, sk, S256_N, S256_HPRIME, S256_D);
}

int
slhdsa256s_sign(uchar *sig, const uchar *msg, ulong msglen, const uchar *sk)
{
	return sign(&s256, sig, msg, msglen, nil, 0, sk);
}

int
slhdsa256s_sign_ctx(uchar *sig, const uchar *msg, ulong msglen,
	const uchar *ctx, int ctxlen, const uchar *sk)
{
	return sign(&s256, sig, msg, msglen, ctx, ctxlen, sk);
}

int
slhdsa256s_verify(const uchar *sig, ulong siglen,
	const uchar *msg, ulong msglen, const uchar *pk)
{
	return verify(&s256, sig, siglen, msg, msglen, nil, 0, pk);
}

int
slhdsa256s_verify_ctx(const uchar *sig, ulong siglen,
	const uchar *msg, ulong msglen, const uchar *ctx, int ctxlen,
	const uchar *pk)
{
	return verify(&s256, sig, siglen, msg, msglen, ctx, ctxlen, pk);
}
