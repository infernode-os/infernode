/*
 * Random numbers: hwrandom() and the three names libsec calls.
 *
 * A PolarFire SoC's true random number generator is in its system
 * controller, reached through the mailbox as the "nonce" service. That
 * driver is not written yet (QEMU's Icicle Kit does not model the
 * service, so it cannot be tested here), and until it is this board has
 * NO ENTROPY SOURCE: it says so in capitals, as ../virt/random.c does
 * with no virtio-rng, and hands out a counter stirred with the time so
 * that the machine still boots. NOTHING CRYPTOGRAPHIC DONE ON SUCH A
 * BOOT IS WORTH ANYTHING.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

static int warned;

void
rnginit(void)
{
	print("rng:  NO ENTROPY SOURCE (the system controller's TRNG service is not driven yet)\n");
}

int
hwrandom(uchar *p, int n)
{
	static u64int weak;
	int got;

	if(!warned){
		warned = 1;
		uartputstr("\nrng:  NO ENTROPY SOURCE. Keys made on this boot are PREDICTABLE.\n\n");
	}
	for(got = 0; got < n; got++){
		weak = weak*6364136223846793005ULL + clockcount() + 1442695040888963407ULL;
		p[got] = weak >> 56;
	}
	return got;
}

void
genrandom(uchar *p, int n)
{
	hwrandom(p, n);
}

void
prng(uchar *p, int n)
{
	genrandom(p, n);
}

int
prngtry(uchar *p, int n)
{
	genrandom(p, n);
	return 0;
}
