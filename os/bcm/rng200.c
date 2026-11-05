/*
 * Random numbers: Broadcom's iProc RNG200, the generator in the
 * BCM2711 (Pi 4) and the BCM2712 (Pi 5). The board names where it is,
 * as RNG200REGS in its io.h; the BCM2837 has the BCM2835's generator
 * instead (../bcm2837/random.c) and leaves this file out.
 *
 * Its registers, from Linux's drivers/char/hw_random/iproc-rng200.c:
 *
 *	+0x00	RNG_CTRL	low 13 bits: enable the generator (1)
 *	+0x04	RNG_SOFT_RESET	bit 0
 *	+0x08	RBG_SOFT_RESET	bit 0
 *	+0x18	RNG_INT_STATUS	bit 31 master fail lockout, bit 5 NIST fail
 *	+0x20	RNG_FIFO_DATA	a 32-bit word of output
 *	+0x24	RNG_FIFO_COUNT	low 8 bits: words waiting
 *
 * The generator runs its own NIST health tests and says in
 * RNG_INT_STATUS when one has failed. Linux reads that before each
 * word and, when it is set, resets the block rather than hand out what
 * a failing source produced. So does this: the call that sees it takes
 * no more words, and the block is reset for the next. Until this file,
 * nothing here read the register at all.
 *
 * A word is tested for and read under rnglock as one step: these are
 * four-core machines with preemption, and two readers that both saw a
 * word waiting would both read it -- two keys sharing a word, or one
 * holding whatever an empty FIFO reads as.
 *
 * QEMU's raspi4b has no model of this block, and reading a register
 * that is not there is an external abort, so the first use asks first
 * (probe32, ../arm64/trap.c). If nothing answers, this machine has no
 * generator: hwrandom says -1 and os/port/random.c refuses to make a
 * key, unless the command line says "insecurerandom" (which the QEMU
 * harness passes). On a board that means the map is wrong; a Pi 5 has
 * no emulator, so on a Pi 5 it can only mean that.
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
	Rngctrl		= 0x00,
	Rngsoftreset	= 0x04,
	Rbgsoftreset	= 0x08,
	Rngintstatus	= 0x18,
	Rngfifodata	= 0x20,
	Rngfifocount	= 0x24,

	Rngenable	= 1,
	Rngenmask	= 0x1FFF,
	Softreset	= 1,
	Masterfail	= 1<<31,	/* master fail lockout */
	Nistfail	= 1<<5,
	Rngcountmask	= 0xFF,

	Spinmax		= 100000,	/* looks at an empty FIFO before saying how much */
};

#define RNG(r)	(*(volatile u32int*)((uintptr)RNG200REGS + (r)))

static Lock rnglock;
static int rngstate;	/* 0 not asked, 1 present, -1 absent */
static int restarts;	/* health-test failures seen, each answered by a reset */
static int told;	/* restarts when last reported */

static void
rngenable(int on)
{
	u32int v;

	v = RNG(Rngctrl) & ~Rngenmask;
	if(on)
		v |= Rngenable;
	RNG(Rngctrl) = v;
	coherence();
}

/* Linux's iproc_rng200_restart: off, clear the status, reset both halves, on */
static void
rngrestart(void)
{
	rngenable(0);
	RNG(Rngintstatus) = 0xFFFFFFFF;
	RNG(Rbgsoftreset) |= Softreset;
	RNG(Rngsoftreset) |= Softreset;
	coherence();
	RNG(Rngsoftreset) &= ~Softreset;
	RNG(Rbgsoftreset) &= ~Softreset;
	coherence();
	rngenable(1);
}

/* under rnglock */
static void
rnginit(void)
{
	u32int v;

	if(rngstate != 0)
		return;
	if(probe32(RNG200REGS + Rngctrl, &v) < 0){
		rngstate = -1;
		return;
	}
	RNG(Rngctrl) = (v & ~Rngenmask) | Rngenable;
	coherence();
	rngstate = 1;
}

/*
 * One word: 1 and *wp; 0 if the FIFO is empty; -1 if the generator's
 * health test has failed (it has been reset) or there is no generator.
 */
static int
rngword(u32int *wp)
{
	int r;

	ilock(&rnglock);
	rnginit();
	if(rngstate < 0)
		r = -1;
	else if(RNG(Rngintstatus) & (Masterfail|Nistfail)){
		rngrestart();
		restarts++;
		r = -1;
	}else if((RNG(Rngfifocount) & Rngcountmask) != 0){
		*wp = RNG(Rngfifodata);
		r = 1;
	}else
		r = 0;
	iunlock(&rnglock);
	return r;
}

int
hwrandom(uchar *p, int n)
{
	u32int w;
	int i, got, r, spins, warn;
	static int warned;

	ilock(&rnglock);
	rnginit();
	r = rngstate;
	warn = r < 0 && !warned;
	if(warn)
		warned = 1;
	iunlock(&rnglock);
	if(r < 0){
		/* the UART, not print: hwrandom may be reached with other locks held */
		if(warn)
			uartputstr("\nrng:  NO RNG200 AT ITS ADDRESS -- this is an emulator, or the map is wrong.\n"
				"      There is NO ENTROPY SOURCE: no key is made on this boot unless the\n"
				"      command line says insecurerandom.\n\n");
		return -1;
	}

	got = 0;
	while(got < n){
		spins = 0;
		while((r = rngword(&w)) == 0)
			if(++spins > Spinmax)
				return got;	/* dry: say how much; the caller must not spin */
		if(r < 0){
			/* the first failure, then every hundredth: one that keeps failing is retried often */
			if(told == 0 || restarts - told >= 100){
				told = restarts;
				uartputstr("\nrng:  the RNG200's own health test failed; it has been reset, and no word\n"
					"      is taken from it until it has come back\n");
			}
			return got;
		}
		for(i = 0; i < 4 && got < n; i++){
			p[got++] = w & 0xFF;
			w >>= 8;
		}
	}
	return got;
}
