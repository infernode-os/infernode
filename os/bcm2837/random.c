/*
 * BCM2837 hardware random number generator.
 *
 * os/port/random.c gathers entropy the way Plan 9 always has: a
 * background process spins a counter, the clock interrupt samples it,
 * and the jitter between them is the randomness. That works on hardware
 * with no RNG, which is what it was written for.
 *
 * It does not work here, and the failure is silent and total. Nothing
 * blocks visibly -- the first caller that wants a random number sleeps
 * in randomread() waiting for the pool to fill, and never wakes. The
 * path that found it was five levels deep and looked nothing like a
 * randomness problem:
 *
 *     connect 127.0.0.1!1        (an ICMP conversation)
 *       -> Fsstdconnect
 *       -> setlport              picks a local port
 *       -> nrand                 needs a seed
 *       -> seedrand
 *       -> randomread            sleeps for entropy that never arrives
 *
 * So the machine could bring up an interface, insert routes and print
 * statistics, and hang the moment anything tried to open a
 * conversation.
 *
 * This SoC has a hardware RNG, so the honest fix is to use it rather
 * than to make the jitter loop work harder. It is also the better
 * source: jitter entropy on a single-core in-order machine running one
 * mostly-idle workload is thin, and its quality is impossible to argue
 * for from first principles.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

enum
{
	RNGREGS		= PHYSIO+0x104000,

	/* register offsets */
	Rngctrl		= 0x00,
	Rngstatus	= 0x04,
	Rngdata		= 0x08,
	Rngffthreshold	= 0x0C,

	Rngenable	= 1<<0,

	/*
	 * The warm-up count lives in the top of the status register. The
	 * hardware discards this many samples before its output is
	 * trustworthy; 0x40000 is the value Broadcom's own code uses and
	 * every other BCM283x driver copies.
	 */
	Rngwarmup	= 0x40000,

	/* how many words are ready, in the top byte of status */
	Rngavailshift	= 24,
};

#define RNG(r)	(*(volatile u32int*)((uintptr)RNGREGS + (r)))

static int rngready;

/*
 * Start the generator and let it warm up.
 *
 * Called once, lazily, so a kernel that never asks for randomness
 * never powers it on.
 */
static void
rnginit(void)
{
	if(rngready)
		return;

	RNG(Rngstatus) = Rngwarmup;
	coherence();
	RNG(Rngctrl) = Rngenable;
	coherence();

	rngready = 1;
}

/*
 * Fill a buffer with hardware random bytes. Returns how many it
 * managed, which may be short -- the caller must cope rather than
 * assume.
 *
 * Bounded: a generator that never reports words available would
 * otherwise hang the kernel here, which is the exact failure this file
 * exists to remove. Returning short is recoverable; spinning is not.
 */
int
hwrandom(uchar *p, int n)
{
	int i, got;
	u32int w;
	static int spins;

	rnginit();

	for(got = 0; got < n; ){
		for(spins = 0; (RNG(Rngstatus) >> Rngavailshift) == 0; spins++)
			if(spins > 100000)
				return got;

		w = RNG(Rngdata);
		for(i = 0; i < 4 && got < n; i++){
			p[got++] = w & 0xFF;
			w >>= 8;
		}
	}
	return got;
}

/*
 * genrandom -- the fast, explicitly non-cryptographic source behind
 * #c/notquiterandom.
 *
 * devcons.c calls this as genrandom(buf, n). An earlier stub here
 * declared it as "ulong genrandom(void)" and returned 0, which is a
 * different function wearing the same name: it linked, because nothing
 * declared a prototype, and it would have handed callers whatever
 * happened to be in the register.
 */
void
genrandom(uchar *p, int n)
{
	int got;

	got = hwrandom(p, n);

	/*
	 * Short reads are padded rather than left as stale stack, so the
	 * result is at worst repetitive instead of a disclosure of
	 * whatever the buffer held.
	 */
	while(got < n)
		p[got++] = 0;
}

/*
 * libsec's entropy entry points, which its host build (prng.c) fills
 * from getentropy/urandom. On bare metal the hardware generator is the
 * secure source, so both delegate here -- and prngtry never fails,
 * because there is no "no secure source" case to report.
 */
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
