/*
 * GICv2 -- the ARM Generic Interrupt Controller.
 *
 * This is the piece BCM2837 does not have. The Pi routes its per-core
 * timer through a small vendor-specific "ARM local peripherals" block:
 * one register, one bit per timer, no priorities and no acknowledge
 * cycle. The GIC is the architectural alternative, and it is what the
 * Pi 4 (GIC-400), the Pi 5, and essentially every other modern Arm SoC
 * use -- so this driver is the forward-investment part of the virt
 * port, not throwaway scaffolding for an emulator.
 *
 * Two register banks:
 *
 *   The DISTRIBUTOR is global. It decides which interrupts exist, what
 *   priority they have, and which CPU each is delivered to.
 *
 *   The CPU INTERFACE is per-core. It is what the core reads to find
 *   out what fired and writes to say it has finished.
 *
 * The acknowledge cycle is the part with no BCM equivalent and the part
 * that goes wrong quietly. Reading IAR both tells you the interrupt
 * number and MASKS that interrupt until you write the same value back
 * to EOIR. Forget the EOIR and you do not get an error -- you get
 * exactly one interrupt, ever, and a kernel that boots fine and then
 * never preempts anything.
 *
 * INTID numbering, which is easy to get wrong because two conventions
 * are in circulation:
 *
 *   0-15    SGI, software-generated (inter-processor)
 *   16-31   PPI, private peripheral -- per-core. The generic timer is
 *           here, at INTID 30 for the non-secure EL1 physical timer.
 *   32-1019 SPI, shared peripheral. QEMU's "SPI n" is INTID 32+n.
 *
 * PPI and SGI configuration registers are BANKED: each core sees its
 * own copy through the same distributor address. That is why enabling
 * the timer touches ISENABLER0 rather than needing a per-core base.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define GICD(r)	(*(volatile u32int*)((uintptr)GICDREGS + (r)))
#define GICC(r)	(*(volatile u32int*)((uintptr)GICCREGS + (r)))

enum
{
	/*
	 * Priority. The GIC masks any interrupt whose priority value is
	 * numerically >= the CPU interface's priority mask, so "lower
	 * number" means "more urgent". Everything is given the same
	 * middling priority and the mask is opened wide: this kernel has
	 * no priority ladder to express, and pretending otherwise would
	 * mean silently dropping interrupts that sort the wrong side of
	 * a threshold nobody chose deliberately.
	 */
	Defprio		= 0xA0,
	Prioallow	= 0xF0,

	Targetcpu0	= 0x01,		/* ITARGETSR is a CPU bitmask */
};

static int nirq;			/* INTIDs this GIC actually implements */

int
gicnirq(void)
{
	return nirq;
}

/*
 * Bring the controller up.
 *
 * Must run before clockinit(): arming the timer comparator succeeds
 * whether or not anything is listening, so a clock started before its
 * interrupt controller exists looks correct and delivers nothing.
 */
void
gicinit(void)
{
	int i, n;

	/*
	 * TYPER's low 5 bits give (number of INTIDs / 32) - 1. Ask,
	 * rather than assuming 1020: configuring interrupts that do not
	 * exist is harmless on QEMU and is exactly the sort of thing
	 * that faults on real silicon.
	 */
	n = ((GICD(Gicdtyper) & 0x1F) + 1) * 32;
	if(n > Nirq)
		n = Nirq;
	nirq = n;

	GICD(Gicdctlr) = 0;		/* quiet while reconfiguring */

	/*
	 * Disable and de-pend everything first. The kernel may be
	 * re-entering a GIC that firmware already touched, and an
	 * interrupt left enabled and pending from before fires the
	 * instant DAIF.I is cleared -- long after the code that would
	 * explain it has gone.
	 */
	for(i = 0; i < n; i += 32){
		GICD(Gicdicenable0 + (i/32)*4) = ~0U;
		GICD(Gicdicpend0   + (i/32)*4) = ~0U;
	}

	/* everything in group 0, the only group this kernel uses */
	for(i = 0; i < n; i += 32)
		GICD(Gicdigroup0 + (i/32)*4) = 0;

	/* one priority byte per INTID */
	for(i = 0; i < n; i += 4)
		GICD(Gicdipriority0 + i) = (Defprio<<24) | (Defprio<<16) |
					   (Defprio<<8)  | Defprio;

	/*
	 * Target CPU 0. SGIs and PPIs (INTID 0-31) have no targets
	 * register -- they are inherently per-core -- so start at 32.
	 */
	for(i = 32; i < n; i += 4)
		GICD(Gicditargets0 + i) = (Targetcpu0<<24) | (Targetcpu0<<16) |
					  (Targetcpu0<<8)  | Targetcpu0;

	GICD(Gicdctlr) = 1;		/* forward group 0 to the interfaces */

	GICC(Giccpmr) = Prioallow;
	GICC(Giccbpr) = 0;		/* no preemption grouping */
	GICC(Giccctlr) = 1;
}

/*
 * Let one INTID through.
 *
 * Nothing arrives until this is called, even for an interrupt whose
 * device is happily asserting -- the distributor holds it pending
 * instead. That is the failure mode to reach for when a device "does
 * not interrupt": check the enable bit before the device.
 */
void
gicenable(int irq)
{
	if(irq < 0 || irq >= nirq)
		return;
	GICD(Gicdisenable0 + (irq/32)*4) = 1U << (irq % 32);
}

void
gicdisable(int irq)
{
	if(irq < 0 || irq >= nirq)
		return;
	GICD(Gicdicenable0 + (irq/32)*4) = 1U << (irq % 32);
}

/*
 * Acknowledge: what fired?
 *
 * The returned value is the whole IAR, not just the INTID, because
 * giceoi() must be given back exactly what was read -- on a multicore
 * GIC the upper bits identify the originating core for an SGI, and
 * masking them off before the EOI leaves the interrupt active forever.
 */
u32int
gicack(void)
{
	return GICC(Gicciar);
}

void
giceoi(u32int iar)
{
	GICC(Gicceoir) = iar;
}
