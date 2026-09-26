/*
 * Random numbers: hwrandom() and the three names libsec calls.
 *
 * A PolarFire SoC's random numbers come from its system controller,
 * the FPGA's own processor, which keeps a NIST SP 800-90 generator
 * seeded from a true random source. The U54s ask for them through the
 * mailbox as the nonce service (opcode 0x21): 32 bytes a request.
 *
 * The protocol, as the system controller's services are driven from
 * any MSS processor:
 *
 *   SERVICES_CR (the control block + 0x50): bits 31:16 the request --
 *   the mailbox offset of the command's data << 7 | the opcode -- and
 *   bit 0 REQ, set to ask. Bit 3 asks for an interrupt when done; this
 *   driver polls instead, because hwrandom is called before interrupts
 *   are on and from whatever context wants a key.
 *
 *   SERVICES_SR (+ 0x54): bit 1 BUSY while the service runs; once it
 *   clears, bits 31:16 are the service's status, 0 for success.
 *
 *   The mailbox (0x37020800): the response, at the offset the service
 *   defines -- 0 for the nonce.
 *
 *   The MSS system registers' MESSAGE_INT (0x20002000 + 0x18c): the
 *   completion interrupt, cleared by writing 0. Nothing enables it; it
 *   is cleared anyway so that a later interrupt-driven driver starts
 *   clean.
 *
 * QEMU's Icicle Kit models the control block and the mailbox as far as
 * failing every service with status 1, so under QEMU this driver takes
 * its refusal path, and the harness checks that it does. The success
 * path is proved only on silicon.
 *
 * When the service is refused or does not answer, this board has NO
 * ENTROPY SOURCE: it says so in capitals, as ../virt/random.c does
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

enum
{
	ServicesCR	= 0x50,
	ServicesSR	= 0x54,
		Req		= 1<<0,
		Busy		= 1<<1,
		Notify		= 1<<3,
		Cmdshift	= 16,
		Statusshift	= 16,
	Messageint	= 0x18c,	/* in the MSS system registers */

	Opnonce		= 0x21,
	Noncebytes	= 32,

	Waitus		= 100000,	/* how long one request may take */
	Pollus		= 10,
};

static Lock rnglock;
static int hastrng;
static int warned;
static uchar nonce[Noncebytes];
static int noncepos = Noncebytes;	/* bytes of nonce[] already handed out */

#define	SCB(o)	(*(volatile u32int*)(uintptr)(SCBCTRLREGS + (o)))
#define	MBOX(o)	(*(volatile u32int*)(uintptr)(MAILBOXREGS + (o)))

/*
 * One nonce request, polled: 0 and nonce[] filled on success, else the
 * service's status (or -1 for a controller that is busy or does not
 * answer).
 */
static int
noncereq(void)
{
	u32int sr, w;
	int i, t, zero;

	if(SCB(ServicesSR) & Busy)
		return -1;
	SCB(ServicesCR) = ((0<<7 | Opnonce) << Cmdshift) | Req;
	/*
	 * BUSY may not rise at once: give the controller a moment to take
	 * the request before reading its absence as completion.
	 */
	microdelay(Pollus);
	for(t = 0; (sr = SCB(ServicesSR)) & Busy; t += Pollus){
		if(t >= Waitus)
			return -1;
		microdelay(Pollus);
	}
	*(volatile u32int*)(uintptr)(SYSREGREGS + Messageint) = 0;
	if((sr >> Statusshift) != 0)
		return sr >> Statusshift;

	zero = 1;
	for(i = 0; i < Noncebytes; i += 4){
		w = MBOX(i);
		if(w != 0)
			zero = 0;
		nonce[i] = w;
		nonce[i+1] = w >> 8;
		nonce[i+2] = w >> 16;
		nonce[i+3] = w >> 24;
	}
	/* 256 zero bits is a controller that answered without doing the work */
	if(zero)
		return -1;
	return 0;
}

void
rnginit(void)
{
	int s;

	ilock(&rnglock);
	s = noncereq();
	if(s == 0){
		hastrng = 1;
		noncepos = 0;
	}
	iunlock(&rnglock);
	if(hastrng)
		print("rng:  system controller nonce service (TRNG-seeded DRBG)\n");
	else if(s > 0)
		print("rng:  the system controller refused the nonce service (status %d): NO ENTROPY SOURCE\n", s);
	else
		print("rng:  the system controller did not answer: NO ENTROPY SOURCE\n");
}

static int
weakrandom(uchar *p, int n)
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

int
hwrandom(uchar *p, int n)
{
	int got, m;

	if(!hastrng)
		return weakrandom(p, n);
	ilock(&rnglock);
	for(got = 0; got < n; got += m){
		if(noncepos == Noncebytes){
			if(noncereq() != 0){
				/*
				 * It worked at boot and has stopped: say so,
				 * and do not pretend what follows is random.
				 */
				hastrng = 0;
				iunlock(&rnglock);
				uartputstr("\nrng:  the system controller's nonce service has FAILED\n");
				return got + weakrandom(p + got, n - got);
			}
			noncepos = 0;
		}
		m = Noncebytes - noncepos;
		if(m > n - got)
			m = n - got;
		memmove(p + got, nonce + noncepos, m);
		/* handed out once only */
		memset(nonce + noncepos, 0, m);
		noncepos += m;
	}
	iunlock(&rnglock);
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
