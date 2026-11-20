/*
 * ML-DSA (FIPS 204) signature algorithm implementation for Inferno keyring
 *
 * ML-DSA-65 provides NIST Level 3 security (~128-bit classical):
 * - Secret key: 4032 bytes
 * - Public key: 1952 bytes
 * - Signature: 3309 bytes
 *
 * ML-DSA-87 provides NIST Level 5 security (~192-bit classical):
 * - Secret key: 4896 bytes
 * - Public key: 2592 bytes
 * - Signature: 4627 bytes
 *
 * Both levels use the same SigAlgVec interface with level-specific
 * key structures that store the actual byte sizes.
 */

#include <lib9.h>
#include <kernel.h>
#include <isa.h>
#include "interp.h"
#include "../libinterp/keyringif.h"
#include "mp.h"
#include "libsec.h"
#include "keys.h"

/*
 * ML-DSA key structures
 * We use max-sized arrays and track the actual level for size dispatch.
 */
typedef struct MLDSApriv MLDSApriv;
typedef struct MLDSApub MLDSApub;
typedef struct MLDSAsig MLDSAsig;

struct MLDSApriv {
	uchar	sk[MLDSA87_SKLEN];	/* sized to largest level */
	uchar	pk[MLDSA87_PKLEN];
	int	sklen;
	int	pklen;
	int	level;			/* 65 or 87 */
};

struct MLDSApub {
	uchar	key[MLDSA87_PKLEN];
	int	keylen;
	int	level;
};

struct MLDSAsig {
	uchar	sig[MLDSA87_SIGLEN];
	int	siglen;
	int	level;
};

/*
 * Allocation functions
 */
static MLDSApriv*
mldsaprivalloc(void)
{
	MLDSApriv *k;
	k = malloc(sizeof(MLDSApriv));
	if(k == nil)
		return nil;
	memset(k, 0, sizeof(MLDSApriv));
	return k;
}

static MLDSApub*
mldsapuballoc(void)
{
	MLDSApub *k;
	k = malloc(sizeof(MLDSApub));
	if(k == nil)
		return nil;
	memset(k, 0, sizeof(MLDSApub));
	return k;
}

static MLDSAsig*
mldsasigalloc(void)
{
	MLDSAsig *s;
	s = malloc(sizeof(MLDSAsig));
	if(s == nil)
		return nil;
	memset(s, 0, sizeof(MLDSAsig));
	return s;
}

/*
 * Free functions
 */
static void
mldsaprivfree(MLDSApriv *k)
{
	if(k == nil)
		return;
	secureZero(k, sizeof(MLDSApriv));	/* clear secret key */
	free(k);
}

static void
mldsapubfree(MLDSApub *k)
{
	free(k);
}

static void
mldsasigfree(MLDSAsig *s)
{
	free(s);
}

/*
 * Attribute lists for serialization
 */
static char* pkattr[] = { "pk", nil };
static char* skattr[] = { "sk", "pk", nil };
static char* sigattr[] = { "sig", nil };

/*
 * Base64 encoding/decoding for fixed-size byte arrays
 */
static int
bytes2base64(uchar *bytes, int len, char *buf, int buflen)
{
	int n;
	n = enc64(buf, buflen, bytes, len);
	if(n > 0 && n < buflen)
		buf[n++] = '\n';
	buf[n] = 0;
	return n;
}

static int
base64tobytes(char *str, uchar *bytes, int len, char **strp)
{
	char *p;
	int n;

	for(p = str; *p && *p != '\n'; p++)
		;
	n = dec64(bytes, len, str, p - str);
	if(strp){
		if(*p)
			p++;
		*strp = p;
	}
	return n;
}

/*
 * Helper: get key sizes for a level
 */
static void
mldsa_sizes(int level, int *sklen, int *pklen, int *siglen)
{
	if(level == 87){
		*sklen = MLDSA87_SKLEN;
		*pklen = MLDSA87_PKLEN;
		*siglen = MLDSA87_SIGLEN;
	} else {
		*sklen = MLDSA65_SKLEN;
		*pklen = MLDSA65_PKLEN;
		*siglen = MLDSA65_SIGLEN;
	}
}

/*
 * Are the secret vectors of a secret key short?  s1 and s2 are packed
 * after rho, K and tr (128 bytes) as eta - coefficient: for ML-DSA-65
 * (eta 4, l+k = 11 polynomials) half bytes from 0 to 8, for ML-DSA-87
 * (eta 2, l+k = 15) fields of three bits from 0 to 4.  A key text of
 * the right length was taken whatever its fields held (FIPS 204's
 * skDecode, Algorithm 25, leaves a key from elsewhere to its caller to
 * check), and signing with one that is not a key made signatures that
 * do not verify, slowly.  Every field is looked at, with no branch on
 * any: the key is secret.
 */
static int
mldsa_skshort(const uchar *sk, int level)
{
	const uchar *p;
	u32int bad, b;
	int i, j, n;

	p = sk + 128;
	bad = 0;
	if(level == 87){
		n = (7 + 8) * 96;
		for(i = 0; i < n; i += 3){
			b = p[i] | (u32int)p[i+1] << 8 | (u32int)p[i+2] << 16;
			for(j = 0; j < 24; j += 3)
				bad |= 4 - ((b >> j) & 7);	/* wraps if above 4 */
		}
	} else {
		n = (5 + 6) * 128;
		for(i = 0; i < n; i++){
			bad |= 8 - (u32int)(p[i] & 0x0F);
			bad |= 8 - (u32int)(p[i] >> 4);
		}
	}
	return (bad >> 31) == 0;
}

/*
 * String to key conversions for ML-DSA-65
 */
static void*
mldsa65_str2sk(char *str, char **strp)
{
	MLDSApriv *k;
	char *p;
	int n;

	k = mldsaprivalloc();
	if(k == nil)
		return nil;

	k->level = 65;
	k->sklen = MLDSA65_SKLEN;
	k->pklen = MLDSA65_PKLEN;

	/* Read secret key */
	n = base64tobytes(str, k->sk, MLDSA65_SKLEN, &p);
	if(n != MLDSA65_SKLEN || !mldsa_skshort(k->sk, 65)){
		mldsaprivfree(k);
		return nil;
	}

	/* Read public key */
	n = base64tobytes(p, k->pk, MLDSA65_PKLEN, &p);
	if(n != MLDSA65_PKLEN){
		mldsaprivfree(k);
		return nil;
	}

	if(strp)
		*strp = p;

	return k;
}

static void*
mldsa65_str2pk(char *str, char **strp)
{
	MLDSApub *k;
	char *p;
	int n;

	k = mldsapuballoc();
	if(k == nil)
		return nil;

	k->level = 65;
	k->keylen = MLDSA65_PKLEN;

	n = base64tobytes(str, k->key, MLDSA65_PKLEN, &p);
	if(n != MLDSA65_PKLEN){
		mldsapubfree(k);
		return nil;
	}

	if(strp)
		*strp = p;

	return k;
}

static void*
mldsa65_str2sig(char *str, char **strp)
{
	MLDSAsig *s;
	char *p;
	int n;

	s = mldsasigalloc();
	if(s == nil)
		return nil;

	s->level = 65;
	s->siglen = MLDSA65_SIGLEN;

	n = base64tobytes(str, s->sig, MLDSA65_SIGLEN, &p);
	if(n != MLDSA65_SIGLEN){
		mldsasigfree(s);
		return nil;
	}

	if(strp)
		*strp = p;

	return s;
}

/*
 * String to key conversions for ML-DSA-87
 */
static void*
mldsa87_str2sk(char *str, char **strp)
{
	MLDSApriv *k;
	char *p;
	int n;

	k = mldsaprivalloc();
	if(k == nil)
		return nil;

	k->level = 87;
	k->sklen = MLDSA87_SKLEN;
	k->pklen = MLDSA87_PKLEN;

	n = base64tobytes(str, k->sk, MLDSA87_SKLEN, &p);
	if(n != MLDSA87_SKLEN || !mldsa_skshort(k->sk, 87)){
		mldsaprivfree(k);
		return nil;
	}

	n = base64tobytes(p, k->pk, MLDSA87_PKLEN, &p);
	if(n != MLDSA87_PKLEN){
		mldsaprivfree(k);
		return nil;
	}

	if(strp)
		*strp = p;

	return k;
}

static void*
mldsa87_str2pk(char *str, char **strp)
{
	MLDSApub *k;
	char *p;
	int n;

	k = mldsapuballoc();
	if(k == nil)
		return nil;

	k->level = 87;
	k->keylen = MLDSA87_PKLEN;

	n = base64tobytes(str, k->key, MLDSA87_PKLEN, &p);
	if(n != MLDSA87_PKLEN){
		mldsapubfree(k);
		return nil;
	}

	if(strp)
		*strp = p;

	return k;
}

static void*
mldsa87_str2sig(char *str, char **strp)
{
	MLDSAsig *s;
	char *p;
	int n;

	s = mldsasigalloc();
	if(s == nil)
		return nil;

	s->level = 87;
	s->siglen = MLDSA87_SIGLEN;

	n = base64tobytes(str, s->sig, MLDSA87_SIGLEN, &p);
	if(n != MLDSA87_SIGLEN){
		mldsasigfree(s);
		return nil;
	}

	if(strp)
		*strp = p;

	return s;
}

/*
 * Key to string conversions (shared for both levels)
 */
static int
mldsa_sk2str(void *vk, char *buf, int len)
{
	MLDSApriv *k = (MLDSApriv*)vk;
	char *cp = buf;
	char *ep = buf + len - 1;

	cp += bytes2base64(k->sk, k->sklen, cp, ep - cp);
	cp += bytes2base64(k->pk, k->pklen, cp, ep - cp);
	*cp = 0;

	return cp - buf;
}

static int
mldsa_pk2str(void *vk, char *buf, int len)
{
	MLDSApub *k = (MLDSApub*)vk;
	char *cp = buf;
	char *ep = buf + len - 1;

	cp += bytes2base64(k->key, k->keylen, cp, ep - cp);
	*cp = 0;

	return cp - buf;
}

static int
mldsa_sig2str(void *vs, char *buf, int len)
{
	MLDSAsig *s = (MLDSAsig*)vs;
	char *cp = buf;
	char *ep = buf + len - 1;

	cp += bytes2base64(s->sig, s->siglen, cp, ep - cp);
	*cp = 0;

	return cp - buf;
}

/*
 * Convert secret key to public key
 */
static void*
mldsa_sk2pk(void *vs)
{
	MLDSApriv *sk = (MLDSApriv*)vs;
	MLDSApub *pk;

	pk = mldsapuballoc();
	if(pk == nil)
		return nil;

	pk->level = sk->level;
	pk->keylen = sk->pklen;
	memmove(pk->key, sk->pk, sk->pklen);

	return pk;
}

/*
 * Generate a new ML-DSA-65 keypair
 */
static void*
mldsa65_gen(int len)
{
	MLDSApriv *k;

	USED(len);

	k = mldsaprivalloc();
	if(k == nil)
		return nil;

	k->level = 65;
	k->sklen = MLDSA65_SKLEN;
	k->pklen = MLDSA65_PKLEN;

	if(mldsa65_keygen(k->pk, k->sk) != 0){
		mldsaprivfree(k);
		return nil;
	}

	return k;
}

/*
 * Generate a new ML-DSA-87 keypair
 */
static void*
mldsa87_gen(int len)
{
	MLDSApriv *k;

	USED(len);

	k = mldsaprivalloc();
	if(k == nil)
		return nil;

	k->level = 87;
	k->sklen = MLDSA87_SKLEN;
	k->pklen = MLDSA87_PKLEN;

	if(mldsa87_keygen(k->pk, k->sk) != 0){
		mldsaprivfree(k);
		return nil;
	}

	return k;
}

/*
 * Generate a new keypair from an existing public key
 * For ML-DSA, this just generates a new independent keypair
 */
static void*
mldsa65_genfrompk(void *vpub)
{
	USED(vpub);
	return mldsa65_gen(0);
}

static void*
mldsa87_genfrompk(void *vpub)
{
	USED(vpub);
	return mldsa87_gen(0);
}

/*
 * Sign bytes: Keyring's digest, at its length, as the message of the
 * pure ML-DSA signature with an empty context string (FIPS 204
 * Algorithm 2).
 */
static void*
mldsa_signb(uchar *m, int n, void *key)
{
	MLDSApriv *sk = (MLDSApriv*)key;
	MLDSAsig *sig;
	int rv, sklen, pklen, siglen;

	sig = mldsasigalloc();
	if(sig == nil)
		return nil;

	sig->level = sk->level;
	mldsa_sizes(sk->level, &sklen, &pklen, &siglen);
	sig->siglen = siglen;

	if(sk->level == 87)
		rv = mldsa87_sign(sig->sig, m, n, sk->sk);
	else
		rv = mldsa65_sign(sig->sig, m, n, sk->sk);

	/* -1: no memory, or the rejection loop's bound: no signature */
	if(rv != 0){
		mldsasigfree(sig);
		return nil;
	}

	return sig;
}

static int
mldsa_verifyb(uchar *m, int n, void *vsig, void *vkey)
{
	MLDSApub *pk = (MLDSApub*)vkey;
	MLDSAsig *sig = (MLDSAsig*)vsig;

	if(pk->level == 87)
		return mldsa87_verify(sig->sig, m, n, pk->key);
	return mldsa65_verify(sig->sig, m, n, pk->key);
}

/*
 * Sign a number (Keyring's signm): its bytes, most significant first,
 * with no leading zero.
 */
static void*
mldsa_sign_hash(mpint *mp, void *key)
{
	uchar hash[SHA512dlen];
	void *sig;
	int n;

	n = mptobe(mp, hash, sizeof(hash), nil);
	if(n < 0)
		return nil;
	sig = mldsa_signb(hash, n, key);
	secureZero(hash, sizeof(hash));
	return sig;
}

static int
mldsa_verify_hash(mpint *mp, void *vsig, void *vkey)
{
	uchar hash[SHA512dlen];
	int n, ok;

	n = mptobe(mp, hash, sizeof(hash), nil);
	if(n < 0)
		return 0;
	ok = mldsa_verifyb(hash, n, vsig, vkey);
	secureZero(hash, sizeof(hash));
	return ok;
}

/*
 * Free functions for SigAlgVec
 */
static void
mldsa_freepub(void *a)
{
	mldsapubfree((MLDSApub*)a);
}

static void
mldsa_freepriv(void *a)
{
	mldsaprivfree((MLDSApriv*)a);
}

static void
mldsa_freesig(void *a)
{
	mldsasigfree((MLDSAsig*)a);
}

/*
 * Initialize and return the ML-DSA-65 signature algorithm vector
 */
SigAlgVec*
mldsa65init(void)
{
	SigAlgVec *vec;

	vec = malloc(sizeof(SigAlgVec));
	if(vec == nil)
		return nil;

	vec->name = "mldsa65";

	vec->pkattr = pkattr;
	vec->skattr = skattr;
	vec->sigattr = sigattr;

	vec->str2sk = mldsa65_str2sk;
	vec->str2pk = mldsa65_str2pk;
	vec->str2sig = mldsa65_str2sig;

	vec->sk2str = mldsa_sk2str;
	vec->pk2str = mldsa_pk2str;
	vec->sig2str = mldsa_sig2str;

	vec->sk2pk = mldsa_sk2pk;

	vec->gensk = mldsa65_gen;
	vec->genskfrompk = mldsa65_genfrompk;
	vec->sign = mldsa_sign_hash;
	vec->verify = mldsa_verify_hash;
	vec->signb = mldsa_signb;
	vec->verifyb = mldsa_verifyb;

	vec->skfree = mldsa_freepriv;
	vec->pkfree = mldsa_freepub;
	vec->sigfree = mldsa_freesig;

	return vec;
}

/*
 * Initialize and return the ML-DSA-87 signature algorithm vector
 */
SigAlgVec*
mldsa87init(void)
{
	SigAlgVec *vec;

	vec = malloc(sizeof(SigAlgVec));
	if(vec == nil)
		return nil;

	vec->name = "mldsa87";

	vec->pkattr = pkattr;
	vec->skattr = skattr;
	vec->sigattr = sigattr;

	vec->str2sk = mldsa87_str2sk;
	vec->str2pk = mldsa87_str2pk;
	vec->str2sig = mldsa87_str2sig;

	vec->sk2str = mldsa_sk2str;
	vec->pk2str = mldsa_pk2str;
	vec->sig2str = mldsa_sig2str;

	vec->sk2pk = mldsa_sk2pk;

	vec->gensk = mldsa87_gen;
	vec->genskfrompk = mldsa87_genfrompk;
	vec->sign = mldsa_sign_hash;
	vec->verify = mldsa_verify_hash;
	vec->signb = mldsa_signb;
	vec->verifyb = mldsa_verifyb;

	vec->skfree = mldsa_freepriv;
	vec->pkfree = mldsa_freepub;
	vec->sigfree = mldsa_freesig;

	return vec;
}
