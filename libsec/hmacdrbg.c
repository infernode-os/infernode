/*
 * HMAC_DRBG with SHA-512 (NIST SP 800-90A Rev. 1, 10.1.2), without
 * prediction resistance or additional input: the deterministic part of
 * every generator InferNode has.  The native kernels' (os/port/random.c)
 * is seeded by a board's hardware generator under SP 800-90B's health
 * tests; the emulator's (genrandom.c) by the host's.  The state is K and
 * V, HMACDRBGlen bytes each, kept by the caller, which also keeps the
 * reseed counter and the policy for when to reseed.
 *
 * hmacdrbgcheck checks this code against NIST's CAVP vectors; a
 * generator runs it once before its first output and refuses to give
 * any if it fails.
 */
#include "os.h"
#include <libsec.h>

/* not a dead store the compiler may drop */
static void
wipe(void *a, int n)
{
	volatile uchar *p;

	for(p = a; n > 0; n--)
		*p++ = 0;
}

/*
 * HMAC-SHA-512 (RFC 2104), its digest states on the stack: libsec's
 * hmac_x allocates the outer one, and a generator's caller may hold a lock
 * where an allocation could wait or fail (os/port/random.c does). A key's two padded blocks are
 * hashed once (hkey), since a Generate uses one key for every block of
 * its output; this halves what a byte costs.
 */
typedef struct Hkey Hkey;
struct Hkey
{
	SHA512state	i;	/* after K ^ ipad */
	SHA512state	o;	/* after K ^ opad */
};

static void
hkey(Hkey *h, uchar *key)
{
	uchar pad[SHA512bsize];
	int i;

	memset(h, 0, sizeof *h);
	memset(pad, 0x36, sizeof pad);
	for(i = 0; i < HMACDRBGlen; i++)
		pad[i] ^= key[i];
	sha512(pad, sizeof pad, nil, &h->i);
	memset(pad, 0x5c, sizeof pad);
	for(i = 0; i < HMACDRBGlen; i++)
		pad[i] ^= key[i];
	sha512(pad, sizeof pad, nil, &h->o);
	wipe(pad, sizeof pad);
}

/* HMAC under h of the pieces p[0..n-1], one after another */
static void
hmacwith(Hkey *h, uchar **p, int *len, int n, uchar *out)
{
	SHA512state s;
	uchar in[SHA512dlen];
	int i;

	s = h->i;
	for(i = 0; i < n; i++)
		if(len[i] > 0)
			sha512(p[i], len[i], nil, &s);
	sha512(nil, 0, in, &s);
	s = h->o;
	sha512(in, sizeof in, out, &s);
	wipe(in, sizeof in);
	wipe(&s, sizeof s);
}

static void
hmac(uchar *key, uchar **p, int *len, int n, uchar *out)
{
	Hkey h;

	hkey(&h, key);
	hmacwith(&h, p, len, n, out);
	wipe(&h, sizeof h);
}

/* V = HMAC(K, V) */
static void
nextv(uchar *k, uchar *v)
{
	uchar *p[1];
	int len[1];

	p[0] = v;
	len[0] = HMACDRBGlen;
	hmac(k, p, len, 1, v);
}

/*
 * SP 800-90A 10.1.2.2, HMAC_DRBG_Update, of the state k and v with the
 * provided data, which is the pieces d0..d2 one after another.
 */
static void
update(uchar *k, uchar *v, uchar *d0, int n0, uchar *d1, int n1, uchar *d2, int n2)
{
	static uchar zero[1] = {0x00}, one[1] = {0x01};
	uchar *p[5];
	int len[5];

	p[0] = v;	len[0] = HMACDRBGlen;
	p[1] = zero;	len[1] = 1;
	p[2] = d0;	len[2] = n0;
	p[3] = d1;	len[3] = n1;
	p[4] = d2;	len[4] = n2;
	hmac(k, p, len, 5, k);		/* K = HMAC(K, V || 0x00 || provided) */
	nextv(k, v);
	if(n0 + n1 + n2 == 0)
		return;
	p[0] = v;	/* the new V */
	p[1] = one;
	hmac(k, p, len, 5, k);		/* K = HMAC(K, V || 0x01 || provided) */
	nextv(k, v);
}

/* 10.1.2.3, Instantiate: K = 0x00.., V = 0x01.., Update(entropy || nonce || personal) */
void
hmacdrbginit(uchar *k, uchar *v, uchar *e, int ne, uchar *nonce, int nn, uchar *ps, int nps)
{
	memset(k, 0x00, HMACDRBGlen);
	memset(v, 0x01, HMACDRBGlen);
	update(k, v, e, ne, nonce, nn, ps, nps);
}

/* 10.1.2.4, Reseed: Update(entropy || additional), none here */
void
hmacdrbgreseed(uchar *k, uchar *v, uchar *e, int ne)
{
	update(k, v, e, ne, nil, 0, nil, 0);
}

/* 10.1.2.5, Generate, n <= HMACDRBGmax, no additional input; Update(nil) after */
void
hmacdrbggen(uchar *k, uchar *v, uchar *p, int n)
{
	Hkey h;
	uchar *pv[1];
	int m, lv[1];

	hkey(&h, k);
	pv[0] = v;
	lv[0] = HMACDRBGlen;
	while(n > 0){
		hmacwith(&h, pv, lv, 1, v);	/* V = HMAC(K, V) */
		m = n < HMACDRBGlen ? n : HMACDRBGlen;
		memmove(p, v, m);
		p += m;
		n -= m;
	}
	wipe(&h, sizeof h);
	update(k, v, nil, 0, nil, 0, nil, 0);
}

static int
unhex(char *s, uchar *b)
{
	int n, d, i;

	for(n = 0; s[0] && s[1]; s += 2, n++){
		b[n] = 0;
		for(i = 0; i < 2; i++){
			d = s[i];
			if(d >= '0' && d <= '9')
				d -= '0';
			else if(d >= 'a' && d <= 'f')
				d -= 'a' - 10;
			else
				return -1;
			b[n] = b[n]<<4 | d;
		}
	}
	return n;
}

/*
 * NIST CAVP drbgtestvectors, HMAC_DRBG.rsp, [SHA-512],
 * PredictionResistance False, 256-bit entropy, 128-bit nonce, no
 * personalization or additional input, 2048 bits returned: COUNT 0 of
 * drbgvectors_no_reseed, and COUNT 0 of drbgvectors_pr_false (a reseed
 * between instantiation and the first Generate). The vector's bits are
 * the second Generate's.
 */
static struct {
	char	*entropy;
	char	*nonce;
	char	*reseed;
	char	*want;
} kats[] = {
	{
	"35049f389a33c0ecb1293238fd951f8ffd517dfde06041d32945b3e26914ba15",
	"f7328760be6168e6aa9fb54784989a11",
	nil,
	"e76491b0260aacfded01ad39fbf1a66a88284caa5123368a2ad9330ee48335e3c9c9ba90e6cbc9429962d60c1a6661edcfaa31d972b8264b9d4562cf18494128a092c17a8da6f3113e8a7edfcd4427082bd390675e9662408144971717303d8dc352c9e8b95e7f35fa2ac9f549b292bc7c4bc7f01ee0a577859ef6e82d79ef23892d167c140d22aac32b64ccdfeee2730528a38763b24227f91ac3ffe47fb11538e435307e77481802b0f613f370ffb0dbeab774fe1efbb1a80d01154a9459e73ad361108bbc86b0914f095136cbe634555ce0bb263618dc5c367291ce0825518987154fe9ecb052b3f0a256fcc30cc14572531c9628973639beda456f2bddf6",
	},
	{
	"48c121b18733af15c27e1dd9ba66a9a81a5579cdba0f5b657ec53c2b9e90bbf6",
	"bbb7c777428068fad9970891f879b1af",
	"e0ffefdadb9ccf990504d568bdb4d862cbe17ccce6e22dfcab8b4804fd21421a",
	"05da6aac7d980da038f65f392841476d37fe70fbd3e369d1f80196e66e54b8fadb1d60e1a0f3d4dc173769d75fc3410549d7a843270a54a068b4fe767d7d9a59604510a875ad1e9731c8afd0fd50b825e2c50d062576175106a9981be37e02ec7c5cd0a69aa0ca65bddaee1b0de532e10cfa1f5bf6a026e47379736a099d6750ab121dbe3622b841baf8bdcbe875c85ba4b586b8b5b57b0fecbec08c12ff2a9453c47c6e32a52103d972c62ab9affb8e728a31fcefbbccc556c0f0a35f4b10ace2d96b906e36cbb72233201e536d3e13b045187b417d2449cad1edd192e061f12d22147b0a176ea8d9c4c35404395b6502ef333a813b6586037479e0fa3c6a23",
	},
};

int
hmacdrbgcheck(void)
{
	uchar k[HMACDRBGlen], v[HMACDRBGlen], e[32], nonce[16], r[32], want[256], out[256+3], *o;
	int i;

	for(i = 0; i < nelem(kats); i++){
		unhex(kats[i].entropy, e);
		unhex(kats[i].nonce, nonce);
		unhex(kats[i].want, want);
		hmacdrbginit(k, v, e, 32, nonce, 16, nil, 0);
		if(kats[i].reseed != nil){
			unhex(kats[i].reseed, r);
			hmacdrbgreseed(k, v, r, 32);
		}
		o = out + 3;	/* not word-aligned, as a reader's buffer need not be */
		hmacdrbggen(k, v, o, 256);
		hmacdrbggen(k, v, o, 256);
		if(memcmp(o, want, 256) != 0){
			wipe(k, sizeof k);
			wipe(v, sizeof v);
			return -1;
		}
	}
	wipe(k, sizeof k);
	wipe(v, sizeof v);
	return 0;
}
