/*
 * Random numbers: the BCM2711's RNG200, and what to do without one.
 *
 * The BCM2835's generator (../bcm2837/random.c) is not in this SoC.
 * What is there, at the same offset in the peripheral window, is
 * Broadcom's iProc RNG200, a different block with a FIFO:
 *
 *	+0x00	RNG_CTRL	low 13 bits: enable the generator (1)
 *	+0x20	RNG_FIFO_DATA	a 32-bit word of output
 *	+0x24	RNG_FIFO_COUNT	low 8 bits: words waiting
 *
 * THE REGISTER LAYOUT IS FROM LINUX'S iproc-rng200.c AND HAS NEVER BEEN
 * RUN ON A BOARD. It cannot be tried under QEMU either: QEMU's raspi4b
 * has no model of this block, and a read of a register that is not
 * there is an external abort. So rnginit asks first (probe32,
 * ../arm64/trap.c), and the two cases are:
 *
 *   the block answers	a board. Use it.
 *
 *   it does not		an emulator. There is no entropy to be had, and
 *			this says so in capitals on the console and hands
 *			out a counter stirred with the time, so that the
 *			machine boots and a test that does not care still
 *			runs -- exactly what os/virt/random.c does when
 *			QEMU is started without its entropy device.
 *			NOTHING CRYPTOGRAPHIC DONE ON SUCH A BOOT IS WORTH
 *			ANYTHING.
 *
 * genrandom never pads a short read with zeros; ../bcm2837/random.c
 * tells how that turned into zero-tailed private keys.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

enum
{
	RNGREGS		= PHYSIO+0x104000,

	Rngctrl		= 0x00,
	Rngfifodata	= 0x20,
	Rngfifocount	= 0x24,

	Rngenable	= 1,
	Rngenmask	= 0x1FFF,
	Rngcountmask	= 0xFF,
};

#define RNG(r)	(*(volatile u32int*)((uintptr)RNGREGS + (r)))

static int rngstate;	/* 0 not asked, 1 present, -1 absent */
static int warned;

static void
rnginit(void)
{
	u32int v;

	if(rngstate != 0)
		return;
	if(probe32(RNGREGS + Rngctrl, &v) < 0){
		rngstate = -1;
		return;
	}
	RNG(Rngctrl) = (v & ~Rngenmask) | Rngenable;
	coherence();
	rngstate = 1;
}

int
hwrandom(uchar *p, int n)
{
	static u64int weak;
	u32int w;
	int i, got, spins;

	rnginit();
	got = 0;
	if(rngstate > 0){
		while(got < n){
			for(spins = 0; (RNG(Rngfifocount) & Rngcountmask) == 0; spins++)
				if(spins > 100000)
					return got;	/* dry: say how much; the caller must not spin */
			w = RNG(Rngfifodata);
			for(i = 0; i < 4 && got < n; i++){
				p[got++] = w & 0xFF;
				w >>= 8;
			}
		}
		return got;
	}

	if(!warned){
		warned = 1;
		uartputstr("\nrng:  NO RNG200 AT ITS ADDRESS -- this is an emulator, or the map is wrong.\n"
			"      There is NO ENTROPY SOURCE. Keys made on this boot are PREDICTABLE.\n\n");
	}
	while(got < n){
		weak = weak*6364136223846793005ULL + clockcount() + 1442695040888963407ULL;
		p[got++] = weak >> 56;
	}
	return got;
}

/* libsec's names, and what its key generators call: all n bytes, never padding */
void
genrandom(uchar *p, int n)
{
	int got, r, waited;

	waited = 0;
	for(got = 0; got < n; got += r){
		r = hwrandom(p + got, n - got);
		if(r > 0)
			continue;
		r = 0;
		microdelay(1000);
		if(++waited % 5000 == 0)
			print("random: the hardware generator has produced nothing for %d seconds; still waiting for %d bytes\n",
				waited/1000, n - got);
	}
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
