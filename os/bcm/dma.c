/*
 * The BCM2835 DMA controller, as much of it as a peripheral that
 * streams from memory needs.
 *
 * Fifteen channels at PHYSIO+0x7000, 0x100 apart (channel 15 lives
 * elsewhere and is not offered). A channel runs a chain of control
 * blocks: each names a source, a destination, a length, transfer
 * flags, and the next block or none. The peripheral paces the
 * transfer through its DREQ line (Ti Permap), so a chain that loops
 * back on itself plays forever at the device's rate, and an interrupt
 * at the end of each block tells the owner which buffer is free again.
 * That is exactly the shape audio wants (audiopwm.c), and it is the
 * shape Plan 9's bcm/dma.c gives the SD controller.
 *
 * Control blocks must be 32-byte aligned and, like the data they name,
 * visible to the DMA engine through the uncached alias (BUSADDR), so
 * everything the engine reads is written back from the ARM's caches
 * first (cachedwbse) -- the same discipline usbdwc.c follows for the
 * OTG core, and for the same reason: the VideoCore side of the chip
 * does not snoop the ARM's caches.
 *
 * Ownership is by channel number: a driver asks for a channel with
 * dmaenable() and owns it until it calls dmadisable(). Nothing here
 * chooses channels; the Linux device tree reserves 0-6 for the ARM and
 * the drivers pick from those.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"

enum {
	DMAREGS		= PHYSIO + 0x007000,
	Nchan		= 7,		/* 0-6: the full-featured channels the ARM may use */
	Chanstride	= 0x100,
	IRQdma0		= IRQvc + 16,	/* VideoCore IRQ of channel 0; channel n is 16+n for n < 11 */

	/* per-channel registers */
	Cs		= 0x00,
	Conblkad	= 0x04,
	Ti		= 0x08,
	Sourcead	= 0x0C,
	Destad		= 0x10,
	Txfrlen		= 0x14,
	Stride		= 0x18,
	Nextconbk	= 0x1C,
	Debug		= 0x20,

	/* global */
	Intstatus	= 0xFE0,
	Enable		= 0xFF0,

	/* Cs */
	Active		= 1<<0,
	End		= 1<<1,
	Int		= 1<<2,
	Dreq		= 1<<3,
	Paused		= 1<<4,
	Dreqstopsdma	= 1<<5,
	Waitingow	= 1<<6,
	Error		= 1<<8,
	Priority	= 8<<16,
	Panicpriority	= 15<<20,
	Waitwrites	= 1<<28,
	Disdebug	= 1<<29,
	Abort		= 1<<30,
	Reset		= 1<<31,
};

#define DREG(c, r)	(*(volatile u32int*)((uintptr)DMAREGS + (c)*Chanstride + (r)))
#define DGLOBAL(r)	(*(volatile u32int*)((uintptr)DMAREGS + (r)))

typedef struct Dmachan Dmachan;
struct Dmachan {
	void	(*intr)(void*);
	void	*arg;
	char	*owner;
};

static Dmachan chans[Nchan];

static void
dmaintr(Ureg*, void *a)
{
	Dmachan *ch;
	int c;
	u32int cs;

	ch = a;
	c = ch - chans;
	cs = DREG(c, Cs);
	if((cs & Int) == 0)
		return;
	DREG(c, Cs) = cs | Int;		/* Int is write-1-to-clear; End likewise */
	if(cs & Error)
		print("dma%d: error, debug %#ux\n", c, DREG(c, Debug));
	if(ch->intr != nil)
		ch->intr(ch->arg);
}

/*
 * Take channel c: reset it, enable it in the controller, and route its
 * interrupt to f(arg). Returns -1 if the channel is taken or out of
 * range; the owner's name is for the message.
 */
int
dmaenable(int c, void (*f)(void*), void *arg, char *owner)
{
	if(c < 0 || c >= Nchan)
		return -1;
	if(chans[c].owner != nil){
		print("dma%d: in use by %s\n", c, chans[c].owner);
		return -1;
	}
	chans[c].intr = f;
	chans[c].arg = arg;
	chans[c].owner = owner;
	DGLOBAL(Enable) |= 1 << c;
	DREG(c, Cs) = Reset;
	microdelay(10);
	DREG(c, Cs) = Int | End;	/* clear what a previous life left */
	DREG(c, Debug) = 7;		/* clear the error flags */
	intrenable(IRQdma0 + c, dmaintr, &chans[c], 0, owner);
	return 0;
}

/*
 * Start channel c on the control block chain at cb (a kernel address;
 * the caller wrote the blocks back to memory). Priority is modest and
 * panic priority high: audio underruns are audible, and this is the
 * knob the datasheet gives for that.
 */
void
dmastart(int c, void *cb)
{
	DREG(c, Cs) = Int | End;
	DREG(c, Conblkad) = BUSADDR(PADDR(cb));
	coherence();
	DREG(c, Cs) = Active | Priority | Panicpriority | Waitwrites | Disdebug;
}

void
dmastop(int c)
{
	DREG(c, Cs) = Abort;
	microdelay(10);
	DREG(c, Cs) = Reset;
	microdelay(10);
	DREG(c, Cs) = Int | End;
}

int
dmaactive(int c)
{
	return (DREG(c, Cs) & Active) != 0;
}

/* which control block the channel is on, as the bus address it was given */
u32int
dmawhere(int c)
{
	return DREG(c, Conblkad);
}

void
dmadisable(int c)
{
	if(c < 0 || c >= Nchan || chans[c].owner == nil)
		return;
	dmastop(c);
	chans[c].intr = nil;
	chans[c].arg = nil;
	chans[c].owner = nil;
}
