/*
 * BCM2837 hardware random number generator.
 *
 * This file supplies hwrandom() for the BCM2835-family generator
 * (BCM2835, BCM2836, BCM2837): it starts the block with the warm-up
 * count Broadcom's code uses, reads how many words are waiting from the
 * top byte of the status register, and tests for a word and reads it as
 * one step under one lock, so two cores never take the same word. It
 * returns what the generator had, which may be short, and never makes
 * bytes up.
 *
 * Everything above that is os/port/random.c's: the HMAC_DRBG with
 * SHA-512 (SP 800-90A) that every reader is served from, its
 * instantiation and reseeding from hwrandom() alone, the SP 800-90B
 * repetition-count and adaptive-proportion tests on the bytes this
 * file returns, and what readers do while the hardware has nothing.
 * Its header comment tells that policy; nothing here sets it.
 *
 * Unlike the RNG200 of the Pi 4 and later (os/bcm/rng200.c), this block
 * exposes no health-test status: there is no failure bit to read and no
 * reset to answer one with. The only health tests on its output are the
 * port's.
 *
 * History. The driver was written when os/port/random.c still gathered
 * entropy as Plan 9 had: a background process spinning a counter, the
 * clock interrupt sampling it, and callers sleeping in randomread()
 * until a pool filled. On this machine the pool never filled, and the
 * failure was silent and total. The path that found it was five levels
 * deep and looked nothing like a randomness problem:
 *
 *     connect 127.0.0.1!1        (an ICMP conversation)
 *       -> Fsstdconnect
 *       -> setlport              picks a local port
 *       -> nrand                 needs a seed
 *       -> seedrand
 *       -> randomread            slept for entropy that never arrived
 *
 * So the machine could bring up an interface, insert routes and print
 * statistics, and hung the moment anything tried to open a
 * conversation. The SoC has a hardware generator, so the fix was to use
 * it rather than make the jitter loop work harder. That pool is gone
 * now, and nrand no longer waits on it (devcons.c's seedrand), but the
 * lesson stands: hwrandom() must never spin, which is why it is bounded
 * below.
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
