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

static Lock rnglock;
static int rngready;

/*
 * Start the generator and let it warm up.
 *
 * Called once, lazily, under rnglock, so a kernel that never asks for
 * randomness never powers it on, and two cores asking at once do not
 * both start it.
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
 * One word, if the generator has one: 1 and *wp, else 0.
 *
 * The test and the read are one step under rnglock. This is a
 * four-core machine with preemption, and the generator is read from
 * the pool's producer and from whichever process wants a key: two of
 * them could both see one word waiting and both read it, and what a
 * read of an empty FIFO returns is not documented. That is two keys
 * sharing a word, or a key holding a stale one.
 */
static int
rngword(u32int *wp)
{
	int ok;

	ilock(&rnglock);
	rnginit();
	ok = (RNG(Rngstatus) >> Rngavailshift) != 0;
	if(ok)
		*wp = RNG(Rngdata);
	iunlock(&rnglock);
	return ok;
}

/*
 * Fill a buffer with hardware random bytes. Returns how many it
 * managed, which may be short -- the caller must cope rather than
 * assume. This SoC always has the generator, so it never says -1.
 *
 * Bounded: a generator that never reports words available would
 * otherwise hang the kernel here, which is the exact failure this file
 * exists to remove. Returning short is recoverable; spinning is not.
 * The lock is taken for each look, not across the wait, so a dry
 * generator holds no other core up.
 */
int
hwrandom(uchar *p, int n)
{
	int i, got, spins;
	u32int w;

	for(got = 0; got < n; ){
		for(spins = 0; !rngword(&w); spins++)
			if(spins > 100000)
				return got;
		for(i = 0; i < 4 && got < n; i++){
			p[got++] = w & 0xFF;
			w >>= 8;
		}
	}
	return got;
}

/*
 * genrandom, prng and prngtry -- what libsec's key generators call --
 * are os/port/random.c's: all n bytes from hwrandom, however long that
 * takes, never padded. Why it must never pad is told there; it was
 * found here (#658), where hwrandom comes back short while the
 * generator warms up.
 */
