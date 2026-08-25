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

	vctl[irq].f = f;
	vctl[irq].a = a;
	vctl[irq].name = name;
	coherence();

	if(irq < 32)
		INTREGS->GPUenable[0] = 1 << irq;
	else if(irq < 64)
		INTREGS->GPUenable[1] = 1 << (irq - 32);
	else
		INTREGS->ARMenable = 1 << (irq - 64);
}

void
intrdisable(int irq, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(f); USED(a); USED(tbdf); USED(name);

	if(irq < 0 || irq >= Nirq)
		return;

	if(irq < 32)
		INTREGS->GPUdisable[0] = 1 << irq;
	else if(irq < 64)
		INTREGS->GPUdisable[1] = 1 << (irq - 32);
	else
		INTREGS->ARMdisable = 1 << (irq - 64);
	coherence();

	vctl[irq].f = nil;
	vctl[irq].a = nil;
	vctl[irq].name = nil;
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
	if(vctl[irq].f == nil)
		return 0;
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

	p = INTREGS->GPUpending[0];
	for(i = 0; p != 0; i++, p >>= 1)
		if(p & 1)
			handled |= intrrun(u, i);

	p = INTREGS->GPUpending[1];
	for(i = 32; p != 0; i++, p >>= 1)
		if(p & 1)
			handled |= intrrun(u, i);

	/*
	 * The basic pending register mirrors some GPU bits as a
	 * convenience; only the ARM-private sources in the low 8 bits are
	 * ours to dispatch, or they would be handled twice.
	 */
	p = INTREGS->ARMpending & 0xFF;
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
