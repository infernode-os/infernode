/*
 * The interrupt controller: an ARM GICv2.
 *
 * For any board whose io.h defines GICDREGS and GICCREGS: QEMU's virt,
 * and the BCM2711 of a Raspberry Pi 4, whose GIC-400 is this part. A
 * board with a controller of its own (os/bcm2837/intr.c) has the harness
 * leave this file out (ARCHSKIP).
 *
 * It does the job os/bcm2837/intr.c does, and the interface is the same one
 * -- intrenable(irq, f, a, tbdf, name) registers a handler for a source,
 * and irqdispatch() runs it -- but the hardware underneath is a
 * different kind of thing, and the differences are the reason to have
 * this port at all. The BCM2837 routes 72 sources through a vendor
 * block with pending bits and no acknowledge; the GIC is the
 * architecture's own controller, the one in the Pi 4 (a GIC-400) and
 * nearly every other 64-bit ARM board, and it has a protocol:
 *
 *   read GICC_IAR	"what is the highest-priority pending interrupt,
 *			 and I am taking it" -- the read ACKNOWLEDGES, and
 *			 the source goes from pending to active
 *   run the handler
 *   write GICC_EOIR	"done", with the value IAR returned -- the source
 *			 goes inactive and may fire again
 *
 * An interrupt acknowledged and never ended stays active for ever and
 * is never delivered again, to any core; that is this controller's
 * version of a lost interrupt, and it is silent. So irqdispatch ends
 * EVERY interrupt it acknowledges, handler or no handler -- and ends
 * the timer's before its handler, because that handler may not come
 * back for a while. See irqdispatch.
 *
 * Two halves. The DISTRIBUTOR is one per machine: enables, priorities,
 * which core an SPI goes to. The CPU INTERFACE is one per core, at the
 * same address on each -- the hardware banks it -- and each core turns
 * its own on: core 0 in intrinit, the others in gicsecinit from
 * secclockinit. The first 32 INTIDs (software-generated and
 * per-processor) are banked in the distributor the same way, which is
 * why the timer's enable is each core's own business too.
 *
 * GICv2, not v3: QEMU's virt defaults to v2 for up to eight cores, v2
 * is memory-mapped throughout so there are no system registers for a
 * wrong exception level to trap on, and the Pi 4's controller is a v2.
 * Start QEMU with gic-version=3 and this driver finds no CPU interface
 * where it looks; intrinit says so rather than hanging.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

enum
{
	/* distributor */
	Dctlr		= 0x000,
	Dtyper		= 0x004,
	Disenabler	= 0x100,	/* set-enable, one bit per INTID */
	Dicenabler	= 0x180,	/* clear-enable */
	Dispendr	= 0x200,	/* set-pending: also reads as "is pending" */
	Dicpendr	= 0x280,
	Disactiver	= 0x300,	/* reads as "is active" */
	Dicactiver	= 0x380,
	Dipriorityr	= 0x400,	/* one BYTE per INTID */
	Ditargetsr	= 0x800,	/* one byte per INTID: a mask of cores */
	Dicfgr		= 0xC00,	/* two bits per INTID: level or edge */

	/* CPU interface */
	Cctlr		= 0x00,
	Cpmr		= 0x04,		/* priority mask: only higher priorities pass */
	Cbpr		= 0x08,
	Ciar		= 0x0C,
	Ceoir		= 0x10,

	Intidmask	= 0x3FF,
	Spurious	= 1020,		/* 1020-1023: nothing to acknowledge */

	/*
	 * One priority for everything. Lower numbers are more urgent and
	 * 0xFF in the mask means "let anything through"; with a single
	 * level there is no preemption between handlers, which is what
	 * os/port assumes -- it has splhi and spllo, not priority levels.
	 */
	Prio		= 0xA0,
};

#define GICD(r)	(*(volatile u32int*)((uintptr)GICDREGS + (r)))
#define GICDB(r) (*(volatile uchar*)((uintptr)GICDREGS + (r)))
#define GICC(r)	(*(volatile u32int*)((uintptr)GICCREGS + (r)))

typedef struct Vctl Vctl;
struct Vctl
{
	void	(*f)(Ureg*, void*);
	void	*a;
	char	*name;
	ulong	count;
};

static Vctl vctl[Nirq];
static Lock intrlock;
static int nintid;		/* how many INTIDs this distributor implements */

/* os/arm64/trap.c and intrdump read these; see os/bcm2837/intr.c */
int irqorphan[MAXMACH];
ulong nspurious;

static void
gicenable(int irq)
{
	GICD(Disenabler + 4*(irq/32)) = 1 << (irq%32);
}

static void
gicdisable(int irq)
{
	GICD(Dicenabler + 4*(irq/32)) = 1 << (irq%32);
}

/*
 * Make a shared interrupt edge-triggered: call before intrenable. The
 * reset state is level, which is right for a wire from a device and
 * wrong for a message-signalled interrupt -- an MSI frame PULSES its
 * line, and a level-sensitive input that is low again by the time
 * anyone looks has nothing pending.
 */
void
gicedge(int irq)
{
	u32int v;

	if(irq < IRQspi || irq >= Nirq)
		panic("gicedge: irq %d is not a shared interrupt", irq);
	ilock(&intrlock);
	v = GICD(Dicfgr + 4*(irq/16));
	v |= 2 << 2*(irq%16);
	GICD(Dicfgr + 4*(irq/16)) = v;
	iunlock(&intrlock);
}

/*
 * Register a handler and enable the source.
 *
 * Shared interrupts go to core 0 and only core 0. The GIC would spread
 * them (a target mask with several bits set delivers to whichever core
 * takes it first) but the drivers here were written on a board whose
 * device interrupts all arrive on core 0, and "may run concurrently
 * with itself on another core" is not a property to hand a driver by
 * surprise.
 *
 * tbdf is upstream's bus argument and means nothing here.
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
	if(irq >= IRQspi){
		GICDB(Dipriorityr + irq) = Prio;
		GICDB(Ditargetsr + irq) = 1<<0;
	}
	gicenable(irq);
	iunlock(&intrlock);
}

void
intrdisable(int irq, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(f); USED(a); USED(tbdf); USED(name);
	if(irq < 0 || irq >= Nirq)
		return;
	ilock(&intrlock);
	gicdisable(irq);
	coherence();
	vctl[irq].f = nil;
	vctl[irq].a = nil;
	vctl[irq].name = nil;
	iunlock(&intrlock);
}

/*
 * This core's half: its CPU interface, and its banked copy of the
 * per-processor interrupts. Every core runs this once.
 */
static void
giccpuinit(void)
{
	int i;

	/* the banked INTIDs 0-31: all off, all one priority */
	GICD(Dicenabler) = ~0;
	GICD(Dicpendr) = ~0;
	GICD(Dicactiver) = ~0;
	for(i = 0; i < 32; i++)
		GICDB(Dipriorityr + i) = Prio;

	GICC(Cpmr) = 0xFF;
	GICC(Cbpr) = 0;
	GICC(Cctlr) = 1;
	coherence();
}

void
gicsecinit(void)
{
	giccpuinit();
}

/*
 * A per-processor interrupt, for the core that calls this. The timer
 * is the one that matters: clock.c turns it on for each core as that
 * core's clock starts.
 */
void
gicppienable(int irq)
{
	if(irq < 16 || irq >= IRQspi)
		panic("gicppienable: %d is not a PPI", irq);
	gicenable(irq);
	coherence();
}

void
intrinit(void)
{
	int i;

	for(i = 0; i < Nirq; i++){
		vctl[i].f = nil;
		vctl[i].a = nil;
		vctl[i].name = nil;
	}
	for(i = 0; i < MAXMACH; i++)
		irqorphan[i] = -1;

	/*
	 * Off while it is configured. Nothing ran before this kernel, so
	 * there is no inherited state to distrust the way intr.c distrusts
	 * the VideoCore's -- but a kernel that has been rebooted INTO
	 * (PSCI reset keeps no state, a future kexec would) costs nothing
	 * to be ready for.
	 */
	GICD(Dctlr) = 0;
	coherence();

	nintid = 32 * ((GICD(Dtyper) & 0x1F) + 1);
	if(nintid > Nirq)
		nintid = Nirq;
	for(i = 32; i < nintid; i += 32){
		GICD(Dicenabler + 4*(i/32)) = ~0;
		GICD(Dicpendr + 4*(i/32)) = ~0;
		GICD(Dicactiver + 4*(i/32)) = ~0;
	}
	for(i = 32; i < nintid; i++){
		GICDB(Dipriorityr + i) = Prio;
		GICDB(Ditargetsr + i) = 1<<0;
	}
	/* Dicfgr stays zero: every source on this machine is level-sensitive */

	giccpuinit();

	GICD(Dctlr) = 1;
	coherence();

	/*
	 * A GICv3 has no memory-mapped CPU interface; the write above to
	 * GICC_CTLR went nowhere and reads back zero. Say so now: the
	 * alternative is a kernel whose first spllo() is followed by
	 * nothing, for ever.
	 */
	if((GICC(Cctlr) & 1) == 0)
		uartputstr("gic:  NO GICv2 CPU INTERFACE -- was QEMU started with gic-version=3?\n");
}

/*
 * Take and end every interrupt that is pending for this core.
 *
 * A loop, not a single acknowledge: a second source pending behind the
 * first would otherwise cost a full exception exit and entry, and the
 * GIC makes the loop free -- IAR returns 1023 when there is nothing
 * left.
 *
 * Returns whether the exception was accounted for, which trap() turns
 * into a panic when it was not. What counts as accounted for:
 *
 *   a handler ran, or the timer claimed it
 *   IAR said "spurious" straight away. The source went away between
 *	the CPU latching the exception and this read -- a level-
 *	sensitive line a driver quietened at splhi does exactly that.
 *	Normal, counted, not fatal; os/bcm2837/clock.c tells the story.
 *
 * and what does not: an enabled source with no handler. Nothing here
 * enables a source without one, so it means the tables are corrupt or
 * something enabled an interrupt behind this file's back. It is
 * DISABLED before the panic is raised, because a level-sensitive
 * source nobody quietens would otherwise re-enter here the instant the
 * panic path lowers spl, and the report would never finish printing.
 */
int
irqdispatch(Ureg *u)
{
	u32int iar;
	int irq, handled;

	irqorphan[m->machno] = -1;
	handled = 0;
	for(;;){
		iar = GICC(Ciar);
		irq = iar & Intidmask;
		if(irq >= Spurious)
			break;

		if(irq == IRQcntpnsirq){
			/*
			 * The timer is ended BEFORE its handler runs, and it
			 * is the only source that is.
			 *
			 * clockintr reaches hzclock, and hzclock PREEMPTS: it
			 * calls sched() from in here, and this function does
			 * not continue until the interrupted process is next
			 * run -- some other time, and as likely as not on
			 * some other core. An end-of-interrupt written after
			 * the handler would come that much later, to whichever
			 * core's banked CPU interface it then found itself
			 * on; and until it came, this core's interface would
			 * sit at the timer's running priority and deliver
			 * nothing of equal priority, which is everything. The
			 * first boot of this port showed exactly that: the
			 * preemption check in main.c found one core, a
			 * different one each boot, where a wired kproc waited
			 * the hog's whole quarter second. The board cannot
			 * have this bug. Its controller has no acknowledge
			 * and no end; an interrupt there is over when the
			 * device stops asking.
			 *
			 * Ending first is safe because the line is level-
			 * sensitive and we are at splhi: the timer is still
			 * asserting, so the interrupt goes straight back to
			 * pending, but it cannot be taken until the exception
			 * returns, and clockintr's re-arm has dropped the
			 * line -- and with it the pending state -- long
			 * before that.
			 */
			GICC(Ceoir) = iar;
			clockintr(u);
			handled = 1;
			continue;
		}else if(irq < Nirq && vctl[irq].f != nil){
			vctl[irq].count++;
			vctl[irq].f(u, vctl[irq].a);
			handled = 1;
		}else{
			irqorphan[m->machno] = irq;
			gicdisable(irq);
		}
		GICC(Ceoir) = iar;
	}

	if(irqorphan[m->machno] >= 0)
		return 0;
	if(!handled)
		ainc(&nspurious);
	return 1;
}

void
intrdump(void)
{
	int held, i;

	held = uartlock();
	uartputstr("intr: cpu");
	uartputd(m->machno);
	uartputstr(" GICC ctlr ");
	uartputx(GICC(Cctlr));
	uartputstr(" pmr ");
	uartputx(GICC(Cpmr));
	uartputstr("\n      enabled/pending/active");
	for(i = 0; i < nintid; i += 32){
		uartputstr("\n      ");
		uartputd(i);
		uartputstr(": ");
		uartputx(GICD(Disenabler + 4*(i/32)));
		uartputstr(" ");
		uartputx(GICD(Dispendr + 4*(i/32)));
		uartputstr(" ");
		uartputx(GICD(Disactiver + 4*(i/32)));
	}
	uartputstr("\n      spurious ");
	uartputd(nspurious);
	uartputstr(" orphan ");
	if(irqorphan[m->machno] < 0)
		uartputstr("none");
	else
		uartputd(irqorphan[m->machno]);
	uartputstr("\n");
	uartunlock(held);
}

/* is anything enabled also pending? for the probes, not the fast path */
int
intrpending(void)
{
	int i;

	for(i = 0; i < nintid; i += 32)
		if(GICD(Disenabler + 4*(i/32)) & GICD(Dispendr + 4*(i/32)))
			return 1;
	return 0;
}

/*
 * What #c/... would want to show: which sources have handlers and how
 * often each has run. Printed by the interrupt probe at boot.
 */
void
intrsummary(void)
{
	int i;

	for(i = 0; i < Nirq; i++)
		if(vctl[i].f != nil)
			print("intr: %3d %-12s %lud\n", i, vctl[i].name, vctl[i].count);
}

/*
 * gicintrprobe: does an interrupt reach a handler? For a board to call
 * from its boardintrprobe if it has nothing better -- a Raspberry Pi
 * makes a real device, a system-timer channel, interrupt instead, which
 * on a Pi 4 tests this file AND the wire.
 *
 * A Raspberry Pi makes a system-timer channel match. A GIC needs no device
 * at all: a write to the distributor's set-pending register makes any
 * interrupt pending exactly as its wire would, so the whole path --
 * distributor enable, target, priority, CPU interface, the IRQ vector,
 * irqdispatch, the handler table, end-of-interrupt -- is exercised
 * with nothing borrowed. The INTID is one virt wires to nothing
 * (its shared interrupts 10-15 are spare).
 *
 * Twice, because once does not prove the END worked: an interrupt
 * acknowledged and never ended is delivered exactly once.
 */
/* IRQprobe is the board's io.h: a shared interrupt nothing is wired to */

static int intrprobefired;

static void
intrprobehandler(Ureg*, void*)
{
	GICD(Dicpendr + 4*(IRQprobe/32)) = 1 << (IRQprobe%32);
	intrprobefired++;
}

void
gicintrprobe(void)
{
	u64int deadline;
	int want;

	intrprobefired = 0;
	intrenable(IRQprobe, intrprobehandler, nil, 0, "intrprobe");
	for(want = 1; want <= 2; want++){
		GICD(Dispendr + 4*(IRQprobe/32)) = 1 << (IRQprobe%32);
		coherence();
		spllo();
		deadline = clockcount() + clockfreq()/2;	/* 500ms */
		while(intrprobefired < want && clockcount() < deadline)
			;
		splhi();
	}
	print("intr: device interrupt %s (software-set pending, through the GIC)\n",
		intrprobefired == 2 ? "delivered" :
		intrprobefired == 1 ? "DELIVERED ONCE AND NEVER AGAIN -- end-of-interrupt is not working" :
		"NEVER DELIVERED");
	intrdisable(IRQprobe, intrprobehandler, nil, 0, "intrprobe");
}
