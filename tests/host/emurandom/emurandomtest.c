/*
 * The emulator's generator (libsec/genrandom.c: HMAC_DRBG over the
 * host's) on the host, its host generator scripted here, against a
 * model of HMAC_DRBG written from SP 800-90A over libsec's hmac_sha512
 * (as kernrandom_helper.c's, so the test does not read the code it
 * tests): the entropy input and nonce taken, the personalization, a
 * reseed after 1M bytes, after 65536 Generates and in another process,
 * requests past one Generate's 64K, and nothing given when the host
 * has no generator, at the first seed and at a reseed.
 * Built by tests/host/emurandom_test.sh.
 */
#define getpid fakegetpid	/* the process asking: a fork changes it */
#include "../../../libsec/genrandom.c"
#undef getpid

static int fakepid = 100;
int fakegetpid(void) { return fakepid; }

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int fprint(int fd, char *fmt, ...) { (void)fd; fputs(fmt, stderr); return 0; }
void _genrandomqlock(void) {}
void _genrandomqunlock(void) {}

/* the host's generator: bytes counting up from hostnext, or none */
static int hostdry, hostcalls, hostlast;
static uchar hostnext;

int
prngtry(uchar *p, int n)
{
	int i;

	hostcalls++;
	hostlast = n;
	if(hostdry)
		return -1;
	for(i = 0; i < n; i++)
		p[i] = hostnext++;
	return 0;
}

typedef struct Model Model;
struct Model { uchar k[64], v[64]; };

static void
mupdate(Model *m, uchar *data, int n)
{
	uchar buf[64+1+256];
	int round;

	for(round = 0; round < 2; round++){
		if(round == 1 && n == 0)
			break;
		memmove(buf, m->v, 64);
		buf[64] = round;
		memmove(buf+65, data, n);
		hmac_sha512(buf, 65+n, m->k, 64, m->k, nil);
		hmac_sha512(m->v, 64, m->k, 64, m->v, nil);
	}
}

static void
mgenerate(Model *m, uchar *out, int n)
{
	int k;

	for(; n > 0; n -= k, out += k){
		hmac_sha512(m->v, 64, m->k, 64, m->v, nil);
		k = n < 64 ? n : 64;
		memmove(out, m->v, k);
	}
	mupdate(m, nil, 0);
}

static void
mfill(Model *m, uchar *out, int n)
{
	int k;

	for(; n > 0; n -= k, out += k){
		k = n < 65536 ? n : 65536;
		mgenerate(m, out, k);
	}
}

/* the host's next n bytes, as prngtry will give them */
static void
hostbytes(uchar *p, int n, uchar from)
{
	int i;

	for(i = 0; i < n; i++)
		p[i] = from++;
}

static int fails;

static void
check(int ok, char *what)
{
	printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
	if(!ok)
		fails++;
}

static char want_personal[] = "InferNode libsec/genrandom.c HMAC_DRBG SHA-512";

static uchar got[300000], want[300000];

int
main(void)
{
	Model m;
	uchar seed[64+16+sizeof want_personal], e[48];
	int i, calls, before;

	/* no host generator: nothing given, -1, and a seed asked for */
	hostdry = 1;
	memset(got, 0xAA, 100);
	check(genrandomtry(got, 100) == -1 && hostcalls == 1, "no host generator: -1");
	for(i = 0; i < 100 && got[i] == 0xAA; i++)
		;
	check(i == 100, "no host generator: the buffer untouched");
	check(d.checked == 1, "NIST's CAVP vectors checked before the first output");
	hostdry = 0;

	/* instantiation: 48 bytes of entropy input, 16 of nonce, the personalization */
	hostnext = 7;
	check(genrandomtry(got, 100) == 0 && hostlast == 64, "instantiated from 64 of the host's bytes");
	hostbytes(seed, 64, 7);
	memmove(seed+64, want_personal, strlen(want_personal));
	memset(m.k, 0, 64);
	memset(m.v, 1, 64);
	mupdate(&m, seed, 64 + strlen(want_personal));
	mfill(&m, want, 100);
	check(memcmp(got, want, 100) == 0, "output is HMAC_DRBG's: entropy, nonce, personalization");

	/* the next request goes on, no reseed */
	calls = hostcalls;
	genrandomtry(got, 1000);
	mfill(&m, want, 1000);
	check(memcmp(got, want, 1000) == 0 && hostcalls == calls, "the next request goes on without a reseed");

	/* past one Generate: 64K at a time */
	genrandomtry(got, 200000);
	mfill(&m, want, 200000);
	check(memcmp(got, want, 200000) == 0 && hostcalls == calls, "a request past 64K, a Generate for each 64K");

	/* reseed after 1M bytes: 48 of the host's, Update(entropy) */
	while(d.since < (1<<20)){
		genrandomtry(got, 250000);
		mfill(&m, want, 250000);
	}
	before = hostnext;
	genrandomtry(got, 100);
	hostbytes(e, 48, before);
	mupdate(&m, e, 48);
	mfill(&m, want, 100);
	check(hostcalls == calls+1 && hostlast == 48 && memcmp(got, want, 100) == 0, "reseeded after 1M bytes, from 48 of the host's");

	/* reseed after 65536 Generates */
	calls = hostcalls;
	for(i = 1; i < 65536; i++){
		genrandomtry(got, 1);
		mfill(&m, want, 1);
	}
	check(hostcalls == calls, "no reseed before 65536 Generates");
	before = hostnext;
	genrandomtry(got, 32);
	hostbytes(e, 48, before);
	mupdate(&m, e, 48);
	mfill(&m, want, 32);
	check(hostcalls == calls+1 && memcmp(got, want, 32) == 0, "reseeded after 65536 Generates");

	/* another process (a fork): reseeded before its first output */
	calls = hostcalls;
	fakepid = 101;
	before = hostnext;
	genrandomtry(got, 64);
	hostbytes(e, 48, before);
	mupdate(&m, e, 48);
	mfill(&m, want, 64);
	check(hostcalls == calls+1 && memcmp(got, want, 64) == 0, "reseeded in another process before its first output");

	/* the host dry at a reseed: nothing given */
	fakepid = 102;
	hostdry = 1;
	memset(got, 0xAA, 64);
	check(genrandomtry(got, 64) == -1, "the host dry at a reseed: -1");
	for(i = 0; i < 64 && got[i] == 0xAA; i++)
		;
	check(i == 64, "the host dry at a reseed: the buffer untouched");
	hostdry = 0;
	before = hostnext;
	genrandomtry(got, 64);
	hostbytes(e, 48, before);
	mupdate(&m, e, 48);
	mfill(&m, want, 64);
	check(memcmp(got, want, 64) == 0, "and reseeded when it has some again");

	return fails != 0;
}
