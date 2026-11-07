#include "os.h"
#include "kernel.h"
#include <mp.h>
#include <libsec.h>

static void
init(ChaChastate *cs)
{
	u32int seed[11];
	int i;

	for(i = 0; i < nelem(seed); i++)
		seed[i] = truerand();
	setupChaChastate(cs, (uchar*)seed, 32, (uchar*)&seed[8], 12, 20);
	memset(seed, 0, sizeof(seed));
}

static void
fill(ChaChastate *cs, uchar *p, int n)
{
	ChaChastate c;

	c = *cs;
	/* Rekey before exposing output, then partition calls by nonce. */
	chacha_encrypt((uchar*)&cs->state[4], 32, &c);
	if(++cs->state[13] == 0)
		if(++cs->state[14] == 0)
			++cs->state[15];
	memset(p, 0, n);
	chacha_encrypt(p, n, &c);
	memset(&c, 0, sizeof(c));
}

void
genrandom(uchar *p, int n)
{
	static ChaChastate cs;

	if(n <= 0)
		return;
	_genrandomqlock();
	if(cs.rounds == 0)
		init(&cs);
	cs.state[4] ^= getpid();	/* fork protection */
	fill(&cs, p, n);
	_genrandomqunlock();
}
