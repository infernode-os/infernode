/*
 * The emulator's random numbers for keys: HMAC_DRBG with SHA-512 (NIST
 * SP 800-90A, hmacdrbg.c), the native kernels' generator, seeded and
 * reseeded from the host's (prngtry: arc4random_buf, getrandom,
 * BCryptGenRandom).  It was ChaCha20 keyed from the host's, which no
 * NIST or CNSA list admits as a generator.  (The native kernels define
 * genrandom in os/port/random.c, over a board's hardware generator, so
 * this file is the emulator's alone.)
 *
 * Instantiated from Seedbytes of entropy input and Noncebytes of nonce,
 * with a personalization string naming this generator; reseeded every
 * Reseedbytes or Reseedgens requests, and when the process is not the
 * one that seeded it (a fork).  The host's generator is a conditioned,
 * full-entropy source, so its bytes are not put through SP 800-90B's
 * health tests here as a board's raw ones are.  hmacdrbgcheck runs
 * NIST's CAVP vectors before the first output.
 *
 * With no host generator nothing is given: genrandomtry says so and
 * genrandom, whose callers cannot be told, stops the emulator rather
 * than make a key from nothing (as prng does).  There is no fallback to
 * a weaker source.
 */
#include "os.h"
#include "kernel.h"
#include <mp.h>
#include <libsec.h>

enum
{
	Seedbytes	= 48,		/* 384 bits of the host's full-entropy output */
	Noncebytes	= 16,
	Reseedbytes	= 1<<20,
	Reseedgens	= 1<<16,
};

static char personal[] = "InferNode libsec/genrandom.c HMAC_DRBG SHA-512";

static struct
{
	uchar	k[HMACDRBGlen];
	uchar	v[HMACDRBGlen];
	int	seeded;
	int	checked;
	int	pid;
	uvlong	since;		/* bytes since the last seed */
	ulong	gens;		/* Generates since the last seed */
} d;

/* locked: a seed from the host; 0, or -1 when it has none to give */
static int
seed(void)
{
	uchar s[Seedbytes+Noncebytes];
	int n;

	n = d.seeded ? Seedbytes : Seedbytes+Noncebytes;	/* a nonce at instantiation only */
	if(prngtry(s, n) < 0){
		memset(s, 0, sizeof s);
		return -1;
	}
	if(!d.seeded)
		hmacdrbginit(d.k, d.v, s, Seedbytes, s+Seedbytes, Noncebytes, (uchar*)personal, strlen(personal));
	else
		hmacdrbgreseed(d.k, d.v, s, Seedbytes);
	secureZero(s, sizeof s);
	d.seeded = 1;
	d.pid = getpid();
	d.since = 0;
	d.gens = 0;
	return 0;
}

/* n random bytes at p: 0, or -1 when the host has no generator (nothing given) */
int
genrandomtry(uchar *p, int n)
{
	int m;

	if(n <= 0)
		return 0;
	_genrandomqlock();
	if(!d.checked){
		if(hmacdrbgcheck() < 0){
			_genrandomqunlock();
			fprint(2, "genrandom: HMAC_DRBG does not give NIST's CAVP vectors; this emulator cannot make keys\n");
			abort();
		}
		d.checked = 1;
	}
	if(!d.seeded || d.pid != getpid() || d.since >= Reseedbytes || d.gens >= Reseedgens)
		if(seed() < 0){
			_genrandomqunlock();
			return -1;
		}
	while(n > 0){
		m = n;
		if(m > HMACDRBGmax)
			m = HMACDRBGmax;
		hmacdrbggen(d.k, d.v, p, m);
		d.since += m;
		d.gens++;
		p += m;
		n -= m;
	}
	_genrandomqunlock();
	return 0;
}

void
genrandom(uchar *p, int n)
{
	if(genrandomtry(p, n) < 0){
		/* no secure random source: stop rather than make a key from nothing */
		fprint(2, "genrandom: no secure random source available, aborting\n");
		abort();
	}
}
