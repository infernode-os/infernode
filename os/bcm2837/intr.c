/*
 * BCM2835/2837 interrupt controller.
 *
 * Until now this kernel handled exactly one interrupt source: the ARM
 * generic timer, routed to core 0 through the ARM local block and
 * dispatched by a hardcoded call. That was enough to get a scheduler
 * running and is not enough for a device driver, which needs to say
 * "call me when IRQ 9 fires" without knowing anything about the
 * dispatcher.
 *
 * There are two interrupt blocks on this SoC and they are stacked:
 *
 *   - The legacy VideoCore controller at PHYSIO+0xB200 owns 64 "GPU"
 *     IRQs plus 8 "basic" ARM ones. USB is GPU IRQ 9.
 *   - The ARM local block at ARMLOCAL, added with BCM2836 for
 *     multicore, decides WHICH CORE sees them. Every GPU interrupt
 *     arrives at a core as a single bit -- Igpu in the core's IRQ
 *     source register -- and the handler must then consult the
 *     controller above to find out which one actually fired.
 *
 * Missing that second level is a classic way to get a driver that
 * enables its interrupt, never receives it, and looks like a dead
 * device.
 *
 * The register layout matches Plan 9's sys/src/9/bcm/trap.c, which is
 * the same silicon and agrees with the Broadcom peripheral datasheet.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

typedef struct Intregs Intregs;
struct Intregs
{
	u32int	ARMpending;
	u32int	GPUpending[2];
	u32int	FIQctl;
	u32int	GPUenable[2];
	u32int	ARMenable;
	u32int	GPUdisable[2];
	u32int	ARMdisable;
};

typedef struct Vctl Vctl;
struct Vctl
{
	void	(*f)(Ureg*, void*);
	void	*a;
	char	*name;
};

enum {
	Fiqenable = 1<<7,	/* FIQ control: a source is selected */
};

static Vctl vctl[Nirq];

/*
 * A software copy of what we have actually enabled.
 *
 * The pending registers report sources that are ASSERTED, not sources
 * that are enabled -- a peripheral nobody is listening to still shows a
 * pending bit. Dispatching straight from pending therefore walks into
 * sources this kernel never asked for and has no handler for.
 *
 * That stayed invisible while the timer was the only thing that ever
 * fired. The moment USB began working on the board, the first unclaimed
 * bit panicked the kernel with "unhandled IRQ" -- immediately after the
 * transfer that finally succeeded.
 */
static u32int irqenabled[3];

/*
 * Guards irqenabled[] and the enable/disable registers behind it.
 *
 * intrenable() is called from kprocs, and a kproc runs on whichever core
 * picks it up; two drivers enabling their sources at once from two
 * cores would each read-modify-write the same word and one of the bits
 * would be lost -- a driver whose interrupt is unmasked in hardware and
 * masked in the software copy intrgpu() filters by, so it fires and is
 * never dispatched. The reads in intrgpu() and intrpending() are single
 * aligned words and need no lock; ilock because the writers may be
 * called with interrupts already off.
 */
static Lock intrlock;

/*
 * The last source that arrived with no handler, per core; -1 if none.
 *
 * Per core because irqdispatch() clears it at the top of every dispatch
 * and tests it at the bottom, and every core's clock tick is a dispatch.
 * With one word, a tick on core 1 could wipe out what intrrun() on core
 * 0 had just recorded, and the unhandled interrupt on core 0 would be
 * counted as spurious -- and left asserted, to fire again, for ever.
 */
int irqorphan[MAXMACH];

/* interrupts that had already gone away by the time we looked */
ulong nspurious;

/*
 * volatile, and not as a formality.
 *
 * These are Device-nGnRnE, where unaligned access is a fault regardless
 * of SCTLR_EL1.A -- and at -O2 clang will merge two adjacent 32-bit
 * stores into one 64-bit store. GPUdisable[0] and [1] sit at 0xB21C and
 * 0xB220, so the merged store lands 4-byte but not 8-byte aligned and
 * takes a data abort.
 *
 * This kernel has been bitten by it once already, on the mailbox, and
 * the README records it. It happened again here.
 */
#define INTREGS	((volatile Intregs*)(uintptr)(PHYSIO + 0x00B200))

/*
 * Register a handler and unmask the source.
 *
 * The signature is Plan 9's and Inferno's, which every os/ port and
 * every driver written against them expects. This kernel previously
 * used the name for "unmask IRQs on this CPU" -- a completely
 * different operation that spllo() already provides, so the name has
 * gone back to its established meaning rather than the two quietly
 * coexisting.
 *
 * tbdf identifies a PCI device upstream and is meaningless here; it is
 * accepted so drivers need no edit.
 */
void
intrenable(int irq, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(tbdf);

	if(irq < 0 || irq >= Nirq)
		panic("intrenable: irq %d out of range (%s)", irq, name);
	if(f == nil)
		panic("intrenable: nil handler for irq %d (%s)", irq, name);

	ilock(&intrlock);
	vctl[irq].f = f;
	vctl[irq].a = a;
	vctl[irq].name = name;
	coherence();

	if(irq < 32){
		irqenabled[0] |= 1 << irq;
		INTREGS->GPUenable[0] = 1 << irq;
	}else if(irq < 64){
		irqenabled[1] |= 1 << (irq - 32);
		INTREGS->GPUenable[1] = 1 << (irq - 32);
	}else{
		irqenabled[2] |= 1 << (irq - 64);
		INTREGS->ARMenable = 1 << (irq - 64);
	}
	iunlock(&intrlock);
}

void
intrdisable(int irq, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(f); USED(a); USED(tbdf); USED(name);

	if(irq < 0 || irq >= Nirq)
		return;

	ilock(&intrlock);
	if(irq < 32)
		INTREGS->GPUdisable[0] = 1 << irq;
	else if(irq < 64)
		INTREGS->GPUdisable[1] = 1 << (irq - 32);
	else
		INTREGS->ARMdisable = 1 << (irq - 64);
	coherence();

	if(irq < 32)
		irqenabled[0] &= ~(1 << irq);
	else if(irq < 64)
		irqenabled[1] &= ~(1 << (irq - 32));
	else
		irqenabled[2] &= ~(1 << (irq - 64));

	vctl[irq].f = nil;
	vctl[irq].a = nil;
	vctl[irq].name = nil;
	iunlock(&intrlock);
}

/*
 * Call the handler for one IRQ. Returns whether anyone claimed it, so
 * an interrupt nobody asked for is reported rather than silently
 * dropped -- a stuck line that is quietly ignored presents as the
 * kernel mysteriously making no progress.
 */
static int
intrrun(Ureg *u, int irq)
{
	if(vctl[irq].f == nil){
		/*
		 * Record it so the panic can say WHICH source nobody
		 * claimed. "unhandled IRQ" with no number sent the last
		 * diagnosis to the register dump and a guess.
		 */
		irqorphan[m->machno] = irq;
		return 0;
	}
	vctl[irq].f(u, vctl[irq].a);
	return 1;
}

/*
 * Service everything the VideoCore controller has pending. Called when
 * a core sees Igpu set.
 */
int
intrgpu(Ureg *u)
{
	int i, handled;
	u32int p;

	handled = 0;

	p = INTREGS->GPUpending[0] & irqenabled[0];
	for(i = 0; p != 0; i++, p >>= 1)
		if(p & 1)
			handled |= intrrun(u, i);

	p = INTREGS->GPUpending[1] & irqenabled[1];
	for(i = 32; p != 0; i++, p >>= 1)
		if(p & 1)
			handled |= intrrun(u, i);

	/*
	 * The basic pending register mirrors some GPU bits as a
	 * convenience; only the ARM-private sources in the low 8 bits are
	 * ours to dispatch, or they would be handled twice.
	 */
	p = INTREGS->ARMpending & 0xFF & irqenabled[2];
	for(i = 64; p != 0; i++, p >>= 1)
		if(p & 1)
			handled |= intrrun(u, i);

	return handled;
}

/*
 * Route every GPU interrupt to core 0.
 *
 * This is the default after reset, but saying so explicitly is worth
 * the one store: if it were ever not the default, the symptom would be
 * a driver whose interrupt simply never arrives, with nothing in the
 * controller to suggest why.
 */
void
intrinit(void)
{
	int i;
	u32int fiq;

	for(i = 0; i < Nirq; i++){
		vctl[i].f = nil;
		vctl[i].a = nil;
		vctl[i].name = nil;
	}
	for(i = 0; i < MAXMACH; i++)
		irqorphan[i] = -1;

	/*
	 * Report what we inherited before changing it.
	 *
	 * The FIQ source register survives a warm reboot, and whatever
	 * ran before us may have left one selected. That matters more
	 * than it sounds: on this controller an interrupt chosen as the
	 * FIQ source is REMOVED FROM THE IRQ PENDING REGISTERS
	 * altogether, so it silently stops arriving by the path every
	 * driver here expects -- with no bit set anywhere to explain
	 * why.
	 *
	 * Linux's Pi USB driver uses the FIQ, and for exactly IRQ 9. So
	 * rebooting out of Linux into this kernel is enough to make USB
	 * interrupts vanish while every other GPU interrupt keeps
	 * working, which is precisely what the first run on real
	 * hardware did.
	 */
	fiq = INTREGS->FIQctl;
	if(fiq & Fiqenable)
		print("intr: inherited FIQ source %d -- clearing\n", fiq & 0x7F);

	INTREGS->FIQctl = 0;		/* every source back on the IRQ path */

	INTREGS->GPUdisable[0] = ~0;
	INTREGS->GPUdisable[1] = ~0;
	INTREGS->ARMdisable = ~0;

	LOCAL(Lgpuirqrouting) = 0;	/* IRQ (not FIQ) to core 0 */
	coherence();
}

/*
 * Say what the interrupt controller actually shows, when nothing claimed
 * an interrupt.
 *
 * The first attempt at this reported only the source intrrun could not
 * place, which turned out to be the wrong question: irqorphan came back
 * -1, meaning nothing enabled-and-pending was rejected -- irqdispatch
 * simply found nothing to dispatch. So the interrupt arrives from
 * somewhere outside the GPU pending set, and the registers that would
 * name it are the local source register and the three pending registers,
 * none of which were being printed.
 *
 * uartputstr rather than print: this runs at splhi from the trap path,
 * where the console queue has no reader. The whole dump is emitted under
 * the console lock so that another core's output cannot land between
 * its pieces -- one line of register values with another core's line
 * spliced into the middle is exactly the report that cannot be read.
 * Lirqsource0 is core 0's summary register; this core's own is the slot
 * at 4*machno, and it is the one the dispatch on this core consulted.
 */
void
intrdump(void)
{
	int held;

	held = uartlock();
	uartputstr("intr: cpu");
	uartputd(m->machno);
	uartputstr(" Lirqsource ");
	uartputx(LOCAL(Lirqsource0 + 4*m->machno));
	uartputstr(" GPUpending ");
	uartputx(INTREGS->GPUpending[0]);
	uartputstr(" ");
	uartputx(INTREGS->GPUpending[1]);
	uartputstr(" ARMpending ");
	uartputx(INTREGS->ARMpending);
	uartputstr("\n      enabled ");
	uartputx(irqenabled[0]);
	uartputstr(" ");
	uartputx(irqenabled[1]);
	uartputstr(" ");
	uartputx(irqenabled[2]);
	uartputstr(" spurious ");
	uartputd(nspurious);
	uartputstr(" orphan ");
	if(irqorphan[m->machno] < 0)
		uartputstr("none");
	else
		uartputd(irqorphan[m->machno]);
	uartputstr("\n");
	uartunlock(held);
}

/*
 * Is anything asserted at all?
 *
 * Lives here because the controller registers do, and because the
 * question only has meaning next to the enable masks this file owns.
 */
int
intrpending(void)
{
	/*
	 * MASKED BY WHAT WE ENABLED, which is the whole point and was
	 * missing.
	 *
	 * The pending registers report sources that are ASSERTED, not
	 * sources anyone is listening to -- the same fact the top of this
	 * file records, and this function ignored it. So a peripheral
	 * nobody enabled, merely by asserting, made an interrupt look
	 * "genuinely pending and unhandled" and the caller panicked:
	 *
	 *     trap: unhandled IRQ
	 *     intr: Lirqsource0 0x100 GPUpending 0x200 0 ARMpending 0x800
	 *           enabled 0x200 0 0 spurious 10 orphan -1
	 *
	 * orphan -1 says it plainly -- nothing enabled and pending was
	 * ever rejected. Intermittent, because it needs a source to
	 * assert in the window between intrgpu reading the pending
	 * registers and this reading them again.
	 *
	 * Lirqsource0 has no enable mask of its own: it is the ARM local
	 * block's summary, one bit per core-level source. Igpu is
	 * excluded because it only means "look at the GPU controller",
	 * which the GPU words below answer properly; the rest are the
	 * per-core timers, which are enabled elsewhere and are ours.
	 */
	return ((LOCAL(Lirqsource0) & ~Igpu) != 0) ||
		(INTREGS->GPUpending[0] & irqenabled[0]) != 0 ||
		(INTREGS->GPUpending[1] & irqenabled[1]) != 0 ||
		(INTREGS->ARMpending & 0xFF & irqenabled[2]) != 0;
}
