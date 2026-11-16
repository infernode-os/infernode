/*
 * libsec's digests and HMACs on the host, built by
 * tests/host/digest_edge_test.sh with the libsec sources (malloc in them
 * renamed to this file's, which refuses when told to):
 *
 *	digesttest vectors.txt [big]
 *
 * Every hash and hmac vector is computed three ways: in one call, in
 * pieces through a caller's state, and in one call with every
 * allocation refused.  "big" does the vectors of 2^29 bytes too.
 */
#include "lib9.h"
#include <libsec.h>
#include <stdio.h>

#undef malloc
#undef free

static int fails, checks, refuse, refused;

void*
xmalloc(size_t n)
{
	if(refuse){
		refused++;
		return nil;
	}
	return malloc(n);
}

void
xfree(void *p)
{
	free(p);
}

typedef DigestState* (*Hash)(uchar*, ulong, uchar*, DigestState*);
typedef DigestState* (*Hmac)(uchar*, ulong, uchar*, ulong, uchar*, DigestState*);

static struct {
	char	*name;
	Hash	h;
	Hmac	m;
	int	dlen;
} algs[] = {
	{ "md5",	md5,	hmac_md5,	MD5dlen },
	{ "sha1",	sha1,	hmac_sha1,	SHA1dlen },
	{ "sha224",	sha224,	nil,		SHA224dlen },
	{ "sha256",	sha256,	hmac_sha256,	SHA256dlen },
	{ "sha384",	sha384,	hmac_sha384,	SHA384dlen },
	{ "sha512",	sha512,	hmac_sha512,	SHA512dlen },
};

static void
check(int ok, char *fmt, ...)
{
	va_list ap;

	checks++;
	if(ok)
		return;
	fails++;
	printf("FAIL: ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

static int
unhex(char *s, uchar *b)
{
	int n;
	unsigned v;

	for(n = 0; s[0] != 0 && s[1] != 0; s += 2, n++){
		sscanf(s, "%2x", &v);
		b[n] = v;
	}
	return n;
}

static int
alg(char *name)
{
	int i;

	for(i = 0; i < nelem(algs); i++)
		if(strcmp(algs[i].name, name) == 0)
			return i;
	return -1;
}

int
main(int argc, char **argv)
{
	FILE *f;
	static char line[1024], w[5][256];
	static uchar msg[1024], key[1024], zeros[1<<20];
	uchar want[64], got[64];
	DigestState ds, *s;
	int nf, a, n, kl, i, big, nbig;
	long left;

	if(argc < 2 || (f = fopen(argv[1], "r")) == nil){
		fprintf(stderr, "usage: digesttest vectors.txt [big]\n");
		return 2;
	}
	big = argc > 2;
	nbig = 0;
	for(i = 0; i < sizeof msg; i++)
		msg[i] = i % 251;
	memset(key, 0xaa, sizeof key);
	while(fgets(line, sizeof line, f) != nil){
		nf = sscanf(line, "%255s %255s %255s %255s %255s", w[0], w[1], w[2], w[3], w[4]);
		if(nf < 4 || (a = alg(w[1])) < 0)
			continue;
		if(strcmp(w[0], "hash") == 0){
			n = atoi(w[2]);
			unhex(w[3], want);
			memset(got, 0xee, sizeof got);
			algs[a].h(msg, n, got, nil);
			check(memcmp(got, want, algs[a].dlen) == 0, "%s of %d bytes, one call", w[1], n);
			/* in pieces, through a state of the caller's */
			memset(&ds, 0, sizeof ds);
			memset(got, 0xee, sizeof got);
			for(i = 0; i+64 <= n; i += 64)
				algs[a].h(msg+i, 64, nil, &ds);
			algs[a].h(msg+i, n-i, got, &ds);
			check(memcmp(got, want, algs[a].dlen) == 0, "%s of %d bytes, in pieces", w[1], n);
			/* with no memory to be had */
			memset(got, 0xee, sizeof got);
			refuse = 1;
			algs[a].h(msg, n, got, nil);
			refuse = 0;
			check(memcmp(got, want, algs[a].dlen) == 0, "%s of %d bytes, one call with no memory", w[1], n);
		}else if(strcmp(w[0], "hmac") == 0 && nf == 5 && algs[a].m != nil){
			kl = atoi(w[2]);
			n = atoi(w[3]);
			unhex(w[4], want);
			memset(got, 0xee, sizeof got);
			algs[a].m(msg, n, key, kl, got, nil);
			check(memcmp(got, want, algs[a].dlen) == 0, "hmac_%s, key %d, %d bytes, one call", w[1], kl, n);
			memset(&ds, 0, sizeof ds);
			memset(got, 0xee, sizeof got);
			algs[a].m(msg, n/2, key, kl, nil, &ds);
			algs[a].m(msg+n/2, n-n/2, key, kl, got, &ds);
			check(memcmp(got, want, algs[a].dlen) == 0, "hmac_%s, key %d, %d bytes, in pieces", w[1], kl, n);
			/* with no memory: as devssl's records (a state of the caller's) and its HKDF (none) */
			memset(&ds, 0, sizeof ds);
			memset(got, 0xee, sizeof got);
			refuse = 1;
			algs[a].m(msg, n/2, key, kl, nil, &ds);
			algs[a].m(msg+n/2, n-n/2, key, kl, got, &ds);
			refuse = 0;
			check(memcmp(got, want, algs[a].dlen) == 0, "hmac_%s, key %d, %d bytes, in pieces with no memory", w[1], kl, n);
			memset(got, 0xee, sizeof got);
			refuse = 1;
			algs[a].m(msg, n, key, kl, got, nil);
			refuse = 0;
			check(memcmp(got, want, algs[a].dlen) == 0, "hmac_%s, key %d, %d bytes, one call with no memory", w[1], kl, n);
		}else if(strcmp(w[0], "zeros") == 0 && big){
			left = atol(w[2]);
			unhex(w[3], want);
			s = nil;
			for(; left > sizeof zeros; left -= sizeof zeros)
				s = algs[a].h(zeros, sizeof zeros, nil, s);
			algs[a].h(zeros, left, got, s);
			check(memcmp(got, want, algs[a].dlen) == 0, "%s of %s bytes of zero", w[1], w[2]);
			nbig++;
		}
	}
	fclose(f);
	/* a message begun with no state and no digest wanted does allocate, and says when it cannot */
	refuse = 1;
	check(sha256(msg, 10, nil, nil) == nil && hmac_sha256(msg, 10, key, 4, nil, nil) == nil,
		"a state was given with no memory to make one");
	refuse = 0;
	check(checks > 700, "only %d checks", checks);
	check(!big || nbig == 6, "%d of the long vectors", nbig);
	if(fails){
		printf("digesttest: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("digesttest: %d checks passed%s\n", checks, big? ", 2^29 bytes among them": "");
	return 0;
}
