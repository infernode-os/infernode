/*
 * A signature's nonce: RFC 6979's generator (3.2), with the additional
 * data of its 3.6 ("hedged": FIPS 186-5 A.3.3's deterministic procedure
 * with fresh randomness beside it).
 *
 * ECDSA, DSA and ElGamal each need a number k that is new for every
 * signature and that nobody learns: two signatures made with one k, or
 * a k a few of whose bits are known, give the private key away.  The
 * k was drawn from the random number generator and nothing else, so
 * the key was as good as the generator at every single signature: one
 * whose state repeats (a machine's image started twice, a process
 * copied, a generator that has failed in a way nothing notices) signs
 * two messages with one k.
 *
 * Here k is HMAC_DRBG's output (the RFC's steps d to h), keyed with
 * the private key and the message's digest, so that it differs
 * whenever the message does, whatever the generator gives; and with
 * random bytes from the generator beside them, so that the same
 * message is not always signed with the same k (which helps whoever
 * can make the signer's arithmetic fault, or measure it over and
 * over).  With no random bytes given it is RFC 6979 exactly, which the
 * tests use for their known answers.
 *
 * The HMAC is SHA-256's for numbers up to 256 bits, SHA-384's to 384
 * and SHA-512's beyond (the RFC lets the hash differ from the
 * message's: 3.6).
 */
#include "os.h"
#include <libsec.h>

typedef DigestState* Hmac(uchar*, ulong, uchar*, ulong, uchar*, DigestState*);

static Hmac*
hmacof(int hlen)
{
	if(hlen == SHA256dlen)
		return hmac_sha256;
	if(hlen == SHA384dlen)
		return hmac_sha384;
	return hmac_sha512;
}

/* the digest length for a number of nbits */
int
noncehlen(int nbits)
{
	if(nbits <= 256)
		return SHA256dlen;
	if(nbits <= 384)
		return SHA384dlen;
	return SHA512dlen;
}

/* K = HMAC_K(V || sep || x || h1 || extra); V = HMAC_K(V) */
static void
update(Noncestate *s, int sep, uchar *x, int nx, uchar *h1, int nh, uchar *extra, int nextra)
{
	Hmac *h;
	DigestState ds;
	uchar b[1];

	h = hmacof(s->hlen);
	memset(&ds, 0, sizeof ds);
	b[0] = sep;
	(*h)(s->v, s->hlen, s->k, s->hlen, nil, &ds);
	if(nx > 0){
		(*h)(b, 1, s->k, s->hlen, nil, &ds);
		(*h)(x, nx, s->k, s->hlen, nil, &ds);
		if(nextra > 0){
			(*h)(h1, nh, s->k, s->hlen, nil, &ds);
			(*h)(extra, nextra, s->k, s->hlen, s->k, &ds);
		}else
			(*h)(h1, nh, s->k, s->hlen, s->k, &ds);
	}else
		(*h)(b, 1, s->k, s->hlen, s->k, &ds);
	(*h)(s->v, s->hlen, s->k, s->hlen, s->v, nil);
	secureZero(&ds, sizeof ds);
}

/*
 * x is the private key and h1 the digest, each as the RFC's octets
 * (int2octets(x) and bits2octets(H(m)): big-endian, as long as the
 * order); extra is random, or nothing.  hlen is noncehlen's.
 */
void
noncestart(Noncestate *s, int hlen, uchar *x, int nx, uchar *h1, int nh, uchar *extra, int nextra)
{
	memset(s, 0, sizeof *s);
	s->hlen = hlen;
	memset(s->v, 0x01, hlen);
	memset(s->k, 0x00, hlen);
	update(s, 0x00, x, nx, h1, nh, extra, nextra);
	update(s, 0x01, x, nx, h1, nh, extra, nextra);
}

/*
 * The next candidate: n bytes of T (step h.2).  The caller takes its
 * leftmost bits as a number and uses it if it is one it can use; each
 * call after the first is the RFC's "K = HMAC_K(V || 00), V = HMAC_K(V)"
 * and another T.
 */
void
noncenext(Noncestate *s, uchar *t, int n)
{
	Hmac *h;
	int m;

	h = hmacof(s->hlen);
	if(s->used)
		update(s, 0x00, nil, 0, nil, 0, nil, 0);
	s->used = 1;
	while(n > 0){
		(*h)(s->v, s->hlen, s->k, s->hlen, s->v, nil);
		m = n;
		if(m > s->hlen)
			m = s->hlen;
		memmove(t, s->v, m);
		t += m;
		n -= m;
	}
}

void
nonceclear(Noncestate *s)
{
	secureZero(s, sizeof *s);
}
