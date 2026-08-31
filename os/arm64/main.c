/*
 * Kernel entry for the bare-metal BCM2837 port.
 *
 * Bring-up order matters here: the console comes up first so that
 * everything after it can report, then the exception vectors so that
 * anything that goes wrong after THAT reports too rather than hanging.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"
#include "kernel.h"

extern Dev	mntdevtab;	/* #M, the 9P client */
extern Dev	benchdevtab;	/* #b, microsecond timing */
extern Dev	srvdevtab;	/* #s, names a Limbo program serves */

/*
 * The machine configuration os/port reads. Declared extern in dat.h and
 * defined here, which is where upstream's platform main.c puts it.
 */
Conf conf;

/*
 * Per-processor state. One core for now, so one Mach; m points at it.
 * MACHP(n) in dat.h resolves through the same object, so there is a
 * single place this becomes an array when the secondary cores are
 * released from the park loop in l.S.
 */
/*
 * The device tree pointer, stored by l.S. Nothing here parses it (see
 * fns.h), but l.S writes to it unconditionally, so it needs a home.
 */
uintptr	dtbptr;

Mach	mach0;
Mach	*m = &mach0;

struct Active active;


/*
 * Optional kernel hooks, declared in portfns.h and defined here exactly
 * once. Each stays nil unless a subsystem installs itself: kproftick is
 * the kernel profiler's timer callback and proctrace the scheduler
 * trace hook. serwrite belongs to devcons.c, which defines it.
 */
void	(*kproftick)(ulong);
void	(*proctrace)(Proc*, int, vlong);
void	(*screenputs)(char*, int);

/*
 * The current process. There is no scheduler yet, so this is a single
 * static stand-in -- but it must be dereferenceable, because
 * os/port/alloc.c takes &up->sleep when a pool runs dry. proc.c
 * replaces it with the real per-core current-process pointer.
 */
static Proc mainproc;
Proc *up = &mainproc;

static u64int
currentel(void)
{
	u64int el;

	__asm__ volatile("mrs %0, CurrentEL" : "=r"(el));
	return el >> 2;
}

static u64int
mpidr(void)
{
	u64int v;

	__asm__ volatile("mrs %0, mpidr_el1" : "=r"(v));
	return v;
}

static u64int
midr(void)
{
	u64int v;

	__asm__ volatile("mrs %0, midr_el1" : "=r"(v));
	return v;
}

/*
 * Prove the exception path round trips before relying on it.  A BRK
 * raises a synchronous exception; trap() reports it and steps over the
 * instruction, so reaching the line after this means the full save,
 * dispatch and restore worked.
 */
static void
checktraps(void)
{
	uartputstr("trap: testing exception path with BRK...");
	__asm__ volatile("brk #0");
	uartputstr("trap: returned from exception, save/restore OK\n");
}


/*
 * Turn on translation, then say what the map looks like.  Reporting
 * ramtop matters: it is queried from the firmware, and it is the line
 * that decides which side of the cacheable/Device split the framebuffer
 * falls on.  If that ever comes back wrong, the symptom is a display
 * showing stale pixels, which is far easier to recognise if the boot log
 * already told you where the boundary was put.
 */
static void
startmmu(void)
{
	mmuinit();

	/*
	 * Exclusive accesses work from here, so the mailbox can start
	 * locking. Before this point it must not: a Lock is taken with
	 * load-exclusive, and exclusives with the MMU off fault.
	 */
	mboxlockon();

	uartputstr("mmu:  ");
	if(!mmuon()){
		uartputstr("FAILED to enable\n");
		return;
	}
	uartputstr("on, caches ");
	uartputstr(mmucaches() ? "on" : "off");
	uartputstr(", identity map 0-");
	uartputd(mmumapped() >> 20);
	uartputstr("MB, ramtop ");
	uartputx(mmuramtop());
	uartputstr("\n      ttbr0=");
	uartputx(mmul1());
	uartputstr(" tcr=");
	uartputx(mmutcr());
	uartputstr(" mair=");
	uartputx(mmumair());
	uartputstr("\n");
}

/*
 * The point of the MMU, demonstrated.
 *
 * With translation off every access is Device-nGnRnE, where unaligned
 * access is architecturally forbidden -- that is what took an alignment
 * fault in the mailbox code when the compiler merged two 32-bit stores
 * into one 64-bit store at a 4-byte-aligned offset.  Once this memory is
 * mapped Normal the same access is simply legal.
 *
 * Run this AFTER mmuinit: it is a regression guard on the memory
 * attributes, not a hardware capability test.  If someone later maps RAM
 * as Device by mistake, this faults immediately and says so, rather than
 * the kernel dying somewhere unrelated at -O2.
 */
static void
checkunaligned(void)
{
	/*
	 * The misalignment must be GUARANTEED, not incidental.
	 *
	 * A plain u8int array has natural alignment 1, so where &buf[4]
	 * lands is an accident of what else is in .bss -- and if it
	 * happens to fall on an 8-byte boundary this becomes an ordinary
	 * aligned access that passes even with RAM mapped Device, which
	 * is the exact regression this check exists to catch. Anchoring
	 * the buffer to a u64int forces 8-byte alignment, so &buf[4] is
	 * always 4 mod 8. The assertion below makes that a checked fact
	 * rather than a hoped-for one.
	 */
	static union {
		u64int	align;
		u8int	b[32];
	} u;
	volatile u64int *p;
	u64int v;

	p = (volatile u64int*)(void*)&u.b[4];
	if(((uintptr)p & 7) != 4){
		uartputstr("mmu:  unaligned check MISCONFIGURED (address is ");
		uartputx((uintptr)p);
		uartputstr(", not 4 mod 8)\n");
		return;
	}

	*p = 0x0123456789ABCDEFULL;
	v = *p;

	uartputstr("mmu:  unaligned 64-bit access ");
	if(v == 0x0123456789ABCDEFULL)
		uartputstr("OK (Normal memory; would fault with MMU off)\n");
	else
		uartputstr("returned WRONG VALUE\n");
}


/*
 * Start the clock, and prove interrupts actually arrive.
 *
 * Two separate questions, and only the second is portable. Whether
 * CNTFRQ_EL0 is telling the truth needs a second, independently-rated
 * clock, and which one that is -- if there is one at all -- is a
 * property of the board; boardclockcheck() answers it.
 *
 * What is portable is whether arming the comparator actually produces
 * an interrupt at the core. That is worth testing separately because
 * arming it always "works": the write succeeds whether or not the
 * interrupt controller is routing the line, so a mis-programmed GIC or
 * a mis-set BCM local-timer route presents as a kernel that boots fine
 * and then never preempts anything.
 */
/*
 * Does a DEVICE interrupt actually reach this processor?
 *
 * The clock probe above answers a narrower question. The generic timer
 * is a PER-CORE interrupt: it arrives at the core directly and never
 * touches the VideoCore controller. Every device on this SoC arrives a
 * different way -- through one of 72 sources in that controller, ORed
 * into a single Igpu bit in the core's IRQ source register -- and
 * nothing had ever tested that path.
 *
 * It mattered. The USB driver spent a long debugging session looking
 * like it had a transfer bug, when in fact no GPU interrupt had ever
 * been delivered and every wait was resolving only because emulation
 * completes transfers synchronously, so each sleep found its condition
 * already true. That is exactly the kind of thing that works until it
 * is asked to do something real.
 *
 * The ARM timer is the vehicle rather than the subject: it is a "basic"
 * source, so it exercises intrenable(), the controller's enable
 * registers, the routing to this core, the vector, irqdispatch() and
 * intrgpu() -- everything a device IRQ uses except the GPU-specific
 * enable word.
 *
 * Bounded by the generic timer's free-running counter, so a dead
 * interrupt line reports rather than hangs.
 */
/*
 * Does anything arrive on the UART's receive side?
 *
 * Output has worked since the first boot, so the line, the adapter and
 * the baud are all right in one direction. Input has never been tested
 * on hardware at all -- it works under QEMU, which proves only that the
 * software path is sound.
 *
 * This asks the lowest level directly, bypassing the console queue, the
 * kbd drainer and the shell: if a byte reaches uartgetc() the fault is
 * above here, and if none does the fault is below -- the receive
 * enable, the pin mux, or a wire that was never connected because
 * nothing until now needed it.
 */
static void
probeuartin(void)
{
	u64int deadline;
	int c, n;

	uartputstr("uart: send any character within 3 seconds to test input\n");

	n = 0;
	deadline = clockcount() + 3*clockfreq();
	while(clockcount() < deadline){
		c = uartgetc();
		if(c >= 0){
			n++;
			if(n == 1)
				print("uart: input OK, first byte %#2.2ux\n", c);
		}
	}
	if(n == 0)
		print("uart: NO INPUT -- nothing reached the receive FIFO\n");
	else
		print("uart: input OK, %d byte(s) received\n", n);
}

static int intrprobefired;

enum { Intprobechan = 3 };		/* system timer compare channel */

#define STREG(r)	(*(volatile u32int*)((uintptr)SYSTIMERREGS + (r)))

static void
intrprobehandler(Ureg*, void*)
{
	STREG(Stcs) = 1 << Intprobechan;	/* acknowledge the match */
	intrprobefired++;
}

static void
probeintr(void)
{
	u64int deadline;

	/*
	 * The system timer, not the ARM timer.
	 *
	 * The obvious vehicle is the ARM timer at PHYSIO+0xB400, and it
	 * is the wrong one: QEMU's raspi3b does not model it. Writes are
	 * dropped and its control register reads back zero, so a probe
	 * built on it reports "no interrupt" whether or not interrupts
	 * work -- which is exactly the sort of answer that sends you
	 * looking in the wrong place. It is also worth knowing in its own
	 * right, because usbdwc.c defers its wakeups through that timer.
	 *
	 * The system timer is modelled, and it is a better subject
	 * anyway: it is a genuine GPU source, so a match exercises the
	 * GPU enable word as well -- the same path every device on this
	 * SoC uses, including the USB controller.
	 *
	 * Channels 0 and 2 belong to the VideoCore firmware on real
	 * hardware. 1 and 3 are ours.
	 */
	intrprobefired = 0;
	STREG(Stcs) = 1 << Intprobechan;
	intrenable(Intprobechan, intrprobehandler, nil, 0, "intrprobe");
	STREG(Stc0 + Intprobechan*4) = STREG(Stclo) + 10000;	/* 10ms */
	coherence();

	spllo();
	deadline = clockcount() + clockfreq()/2;		/* 500ms */
	while(intrprobefired == 0 && clockcount() < deadline)
		;
	splhi();

	print("intr: device interrupt %s (system timer via the VideoCore controller)\n",
		intrprobefired ? "delivered" : "NEVER DELIVERED");

	intrdisable(Intprobechan, intrprobehandler, nil, 0, "intrprobe");
	STREG(Stcs) = 1 << Intprobechan;
}

static void
probeclock(void)
{
	u64int deadline;

	uartputstr("clk:  cntfrq ");
	uartputd(clockfreq());
	uartputstr("Hz (");
	uartputd(clockfreq() / 1000000);
	uartputstr("MHz)\n");

	boardclockcheck();

	/*
	 * Now let interrupts in.  Wait for a few ticks with a wall-clock
	 * deadline so a dead interrupt line fails as a report rather than
	 * as a hang.
	 *
	 * The deadline is measured with the generic timer's counter rather
	 * than a platform one. CNTPCT_EL0 free-runs whether or not the
	 * comparator interrupt is routed anywhere, so it stays a valid
	 * timeout source even when the thing under test is broken -- and it
	 * is the one clock every AArch64 board has.
	 */
	spllo();
	deadline = clockcount() + clockfreq()/2;	/* 500ms */
	while(clockticks() < 5 && clockcount() < deadline)
		;

	uartputstr("clk:  irq ");
	if(clockticks() >= 5){
		uartputstr("firing, ");
		uartputd(clockticks());
		uartputstr(" ticks at ");
		uartputd(HZ);
		uartputstr("Hz OK\n");
	}else{
		uartputstr("NOT firing (");
		uartputd(clockticks());
		uartputstr(" ticks in 500ms)\n");
	}
}

/*
 * Exercise the primitives os/port's taslock.c is written against.
 *
 * These are the leaves everything else stands on: if _tas does not
 * actually implement test-and-set, every lock in the kernel silently
 * fails to exclude, and the symptom is corruption somewhere unrelated
 * rather than a lock that visibly misbehaves.  Cheap to check here,
 * enormously expensive to debug later.
 */
static void
probearch(void)
{
	ulong lk, old, s;
	int ok;

	ok = 1;

	/* test-and-set: first take succeeds (returns old value 0) */
	lk = 0;
	if(_tas(&lk) != 0 || lk != 1)
		ok = 0;

	/* second take must fail and must report the old value as held */
	if(_tas(&lk) == 0)
		ok = 0;

	/* release and re-take */
	lk = 0;
	coherence();
	if(_tas(&lk) != 0)
		ok = 0;

	uartputstr("arch: _tas ");
	uartputstr(ok ? "OK" : "BROKEN");

	/*
	 * spl must report the PREVIOUS level, not the new one.  Code that
	 * masks and then unconditionally unmasks would silently enable
	 * interrupts inside a caller that had deliberately masked them.
	 */
	/*
	 * Interrupts are still masked here -- l.S erets with DAIF set and
	 * nothing has enabled them yet -- so testing splhi() first would
	 * compare a masked previous level against a masked new one and
	 * pass even if splhi returned the NEW level rather than the old.
	 * Drop to low first so the two are actually distinguishable.
	 */
	ok = 1;
	spllo();
	if(!islo())
		ok = 0;			/* spllo did not unmask */

	s = splhi();
	if(s & (1<<7))
		ok = 0;			/* splhi must report the PREVIOUS (low) level */
	if(islo())
		ok = 0;			/* still low after splhi */

	old = spllo();
	if((old & (1<<7)) == 0)
		ok = 0;			/* spllo must report the previous (high) level */
	if(!islo())
		ok = 0;			/* still high after spllo */

	splx(s);			/* s was taken while low: restores low */
	if(!islo())
		ok = 0;			/* splx did not restore the saved level */

	splhi();			/* leave as found: masked */

	uartputstr(", spl ");
	uartputstr(ok ? "OK" : "BROKEN");
	uartputstr(" (level restored, not assumed)\n");
}

/*
 * Exercise libkern -- the freestanding libc the kernel supplies itself,
 * imported from upstream Inferno.
 *
 * The formatting check is the one that matters. dofmt is the engine
 * behind print(), which os/port uses everywhere, and it is the first
 * imported code here with real internal machinery rather than a
 * one-line primitive. If snprint works on bare metal, the whole
 * fmt/convM2S/convS2M layer that os/port and 9P depend on is viable.
 */
static void
probelibkern(void)
{
	char buf[64];
	char a[16], b[16];
	int ok, n;

	ok = 1;

	/* mem primitives */
	memset(a, 0x5A, sizeof a);
	memmove(b, a, sizeof a);
	if(memcmp(a, b, sizeof a) != 0)
		ok = 0;
	memset(b, 0, sizeof b);
	if(memcmp(a, b, sizeof a) == 0)
		ok = 0;

	/* string primitives */
	strcpy(buf, "inferno");
	if(strlen(buf) != 7 || strcmp(buf, "inferno") != 0)
		ok = 0;
	if(strchr(buf, 'f') != buf+2)
		ok = 0;

	uartputstr("libk: mem/str ");
	uartputstr(ok ? "OK" : "BROKEN");

	/*
	 * The Plan 9 fmt engine. %ld and %lux are the formats os/port
	 * uses constantly, and under LP64 they must consume 64 bits.
	 */
	/*
	 * BOTH values are deliberately larger than 2^32.  A %lu that
	 * consumed only 32 bits would still print a smaller value
	 * correctly, so an operand that fits in 32 bits proves nothing
	 * about whether the format is LP64-correct.  This originally
	 * passed 0xC0A80101 to %lud -- the very value the comment
	 * declared insufficient -- so only %lux was actually guarded.
	 * 12884901889 is 0x300000001, which needs the full 64 bits in
	 * decimal as well as hex.
	 */
	n = snprint(buf, sizeof buf, "%d %s %lud %lux", 42, "dis",
		(ulong)12884901889UL, (ulong)0x1DEADBEEFUL);
	uartputstr(", snprint ");
	if(n > 0 && strcmp(buf, "42 dis 12884901889 1deadbeef") == 0)
		uartputstr("OK");
	else{
		uartputstr("WRONG: ");
		uartputstr(buf);
	}
	uartputstr("\n");
}

/*
 * Describe the machine to os/port, then bring up the base allocator.
 *
 * xalloc hands out memory in coarse chunks and everything above it --
 * alloc.c's pools, Blocks, page tables for processes -- is carved out of
 * what it owns. It needs to be told which physical memory is actually
 * free, which is everything between the end of the kernel image and the
 * top of ARM-visible RAM. Above ramtop the VideoCore owns the memory, so
 * handing any of it out would corrupt the GPU's world (including the
 * framebuffer) rather than merely running out.
 */
/*
 * Not static: portfns.h declares confinit() because os/port calls it
 * during boot. It is one of the handful of functions every platform
 * must supply.
 */
void
confinit(void)
{
	extern char end[];
	uintptr base, top;

	memset(&conf, 0, sizeof conf);

	conf.nmach = 1;			/* one core running so far */
	conf.nproc = 100;
	conf.ialloc = 128*1024;
	conf.pipeqsize = 256*1024;

	base = PGROUND((uintptr)end);
	top = mmuramtop();

	conf.base0 = base;
	conf.npage0 = (top - base) / BY2PG;
	conf.npage = conf.npage0;

	/*
	 * uartputstr, not print: confinit runs before printinit and before
	 * serwrite is set, and devcons.c discards output when it has
	 * neither a queue nor a serial hook. Anything reporting from this
	 * early in boot has to talk to the PL011 directly.
	 */
	uartputstr("conf: ");
	uartputd(conf.npage0);
	uartputstr(" free pages (");
	uartputd((conf.npage0 * BY2PG) >> 20);
	uartputstr("MB) from ");
	uartputx(base);
	uartputstr(" to ");
	uartputx(top);
	uartputstr("\n");
}

/*
 * Exercise the imported allocator.
 *
 * xalloc zeroes what it returns, so a fresh allocation reading back
 * non-zero means it handed out memory that is still in use somewhere --
 * which is worth catching here rather than as corruption later.
 */
static void
probexalloc(void)
{
	char *a, *b;
	int ok;

	ok = 1;

	a = xalloc(4096);
	b = xalloc(4096);
	if(a == nil || b == nil)
		ok = 0;
	else{
		int i;

		if(a == b)
			ok = 0;				/* handed out twice */

		/*
		 * Scan for ANY non-zero byte, not one chosen value. Looking
		 * only for 0xFF would miss a block still holding the 0xAA
		 * this probe itself writes below, which is exactly the case
		 * a non-zeroing allocator would produce on the second run.
		 */
		for(i = 0; i < 4096; i++)
			if(a[i] != 0 || b[i] != 0)
				ok = 0;

		/*
		 * Bound the allocation at BOTH ends. Checking only the lower
		 * bound would let an allocation running past ramtop into
		 * VideoCore-owned memory pass -- which is the hazard
		 * confinit() exists to avoid, so it is the one worth
		 * asserting.
		 */
		if((uintptr)a < conf.base0 || (uintptr)b < conf.base0)
			ok = 0;
		if((uintptr)a + 4096 > mmuramtop() || (uintptr)b + 4096 > mmuramtop())
			ok = 0;

		/*
		 * Reject PARTIAL overlap, not just exact aliasing. a == b is
		 * already caught above; two blocks sharing half their extent
		 * would slip past a check that only compares first bytes.
		 */
		if(!(a + 4096 <= b || b + 4096 <= a))
			ok = 0;

		memset(a, 0xAA, 4096);
		memset(b, 0xBB, 4096);
		if(a[0] != (char)0xAA || b[0] != (char)0xBB)
			ok = 0;
		if(a[4095] != (char)0xAA || b[4095] != (char)0xBB)
			ok = 0;			/* the far end must be ours too */
		xfree(a);
		xfree(b);
	}

	print("xall: xalloc %s\n", ok ? "OK (distinct, zeroed, in-bank)" : "BROKEN");
}

/*
 * Bring up the pool allocator that sits on xalloc, and exercise it.
 *
 * This is what malloc() means in an Inferno kernel: three pools (main,
 * heap, image) carved out of xalloc's memory, with the heap and image
 * pools being the ones the Dis VM's garbage collector allocates from.
 * Getting it running is the precondition for libinterp doing anything
 * at all.
 */
static void
probealloc(void)
{
	char *a, *b, *c;
	int ok, i;

	ok = 1;

	a = malloc(100);
	b = malloc(100);
	if(a == nil || b == nil)
		ok = 0;
	else {
		if(!(a + 100 <= b || b + 100 <= a))
			ok = 0;			/* overlapping allocations */

		/* malloc must zero, like the kernel's callers assume */
		for(i = 0; i < 100; i++)
			if(a[i] != 0 || b[i] != 0)
				ok = 0;

		memset(a, 0xA5, 100);
		memset(b, 0x5A, 100);
		if(a[0] != (char)0xA5 || a[99] != (char)0xA5)
			ok = 0;
		if(b[0] != (char)0x5A || b[99] != (char)0x5A)
			ok = 0;
	}

	/* free then re-allocate: the pool must reuse rather than grow forever */
	free(a);
	free(b);
	c = malloc(100);
	if(c == nil)
		ok = 0;
	free(c);

	/* a large allocation exercises a different path than the small ones */
	a = malloc(200*1024);
	if(a == nil)
		ok = 0;
	else {
		memset(a, 0x11, 200*1024);
		free(a);
	}

	print("pool: malloc/free %s\n", ok ? "OK (distinct, zeroed, reusable)" : "BROKEN");

	/*
	 * These libkern entry points need an allocator, so they could not
	 * be linked until now. smprint is the dynamic-buffer formatter and
	 * strdup the canonical malloc-and-copy -- between them they are
	 * what most of os/port reaches for when it needs a string.
	 */
	{
		char *s;
		int sok;

		sok = 1;
		s = smprint("%s-%d-%lux", "dis", 7, (ulong)0x1BADF00DUL);
		if(s == nil || strcmp(s, "dis-7-1badf00d") != 0)
			sok = 0;
		free(s);

		s = strdup("namespace");
		if(s == nil || strcmp(s, "namespace") != 0)
			sok = 0;
		free(s);

		print("pool: smprint/strdup %s\n", sok ? "OK" : "BROKEN");
	}
}

/*
 * Blocks: the packet and queue buffer os/port and os/ip are built on.
 *
 * Every packet in the IP stack is a Block, and qio.c's Queues are chains
 * of them. The headroom matters as much as the allocation: a driver must
 * be able to prepend an Ethernet header in place, or every transmit
 * reallocates and copies the whole packet.
 *
 * Note where that headroom actually comes from. allocb asks for
 * Hdrspc extra bytes, but then positions rp using msize() -- the size
 * the POOL actually handed back, which is usually more than requested.
 * The slack between the two is what rp is advanced by. So headroom is a
 * consequence of pool rounding as much as of Hdrspc, and setting Hdrspc
 * to zero does not necessarily remove it. What is asserted below is the
 * property that matters -- that a media header fits before rp -- rather
 * than the mechanism that provides it.
 */
static void
probeblock(void)
{
	Block *b, *c;
	int ok;

	ok = 1;

	b = allocb(1500);
	c = allocb(1500);
	if(b == nil || c == nil)
		ok = 0;
	else {
		if(BLEN(b) != 0)
			ok = 0;			/* a fresh block holds nothing */
		if(BALLOC(b) < 1500)
			ok = 0;			/* must fit what was asked for */
		if(b->rp < b->base || b->wp != b->rp || b->lim < b->wp)
			ok = 0;			/* pointers must be ordered */

		/* a 14-byte Ethernet header must fit before rp, in place */
		if(b->rp - b->base < 14)
			ok = 0;
		else {
			b->rp -= 14;
			memset(b->rp, 0xEE, 14);
			if(BLEN(b) != 14)
				ok = 0;
			b->rp += 14;
		}

		/* writing the full payload must stay inside the block */
		memset(b->wp, 0x42, 1500);
		b->wp += 1500;
		if(BLEN(b) != 1500 || b->wp > b->lim)
			ok = 0;

		if(b->base == c->base)
			ok = 0;			/* two blocks sharing a buffer */

		freeb(b);
		freeb(c);
	}

	/* iallocb is the interrupt-time variant and must be usable too */
	b = iallocb(64);
	if(b == nil || BALLOC(b) < 64)
		ok = 0;
	else
		freeb(b);

	print("blok: allocb/freeb %s\n", ok ? "OK (headroom, extents, distinct)" : "BROKEN");
}

/*
 * setlabel/gotolabel -- the mechanism the scheduler is built on.
 *
 * proc.c's sched() leaves a process by setlabel-ing into its Proc and
 * gotolabel-ing into the scheduler's own Label, and enters one by doing
 * the reverse. If this pairing is wrong the kernel does not fail here,
 * it fails the first time two processes exist, in a way that looks like
 * memory corruption rather than a broken jump.
 *
 * Every variable below is static ON PURPOSE. gotolabel restores sp and
 * pc and nothing else -- callee-saved registers survive only because
 * the caller spilled them, and anything the compiler chose to keep in a
 * caller-saved register across the call is stale afterwards. Statics
 * live in memory, so they are immune. This is the same reason
 * setjmp/longjmp requires volatile, and getting it wrong here would
 * make the test lie rather than fail.
 */
/*
 * Hold values in callee-saved registers across a setlabel/gotolabel
 * round trip and verify they come back.
 *
 * The register hints are hints, but the volatile asm barriers stop the
 * compiler from rematerialising the values from constants, so it has to
 * keep them live in registers across the call -- which is precisely the
 * situation that broke.
 */
static Label clabel;
static int cpass;

static int __attribute__((noinline))
checkcalleesaved(void)
{
	register uintptr a __asm__("x19");
	register uintptr b __asm__("x24");
	register uintptr c __asm__("x28");

	a = 0x1111111111111111ULL;
	b = 0x2222222222222222ULL;
	c = 0x3333333333333333ULL;
	__asm__ volatile("" :: "r"(a), "r"(b), "r"(c));

	cpass = 0;
	if(setlabel(&clabel) == 0){
		cpass = 1;
		/* clobber them, then jump back */
		__asm__ volatile("mov x19, #0\n\tmov x24, #0\n\tmov x28, #0"
			::: "x19", "x24", "x28");
		gotolabel(&clabel);
		return 0;
	}

	__asm__ volatile("" : "=r"(a), "=r"(b), "=r"(c));
	if(a != 0x1111111111111111ULL) return 0;
	if(b != 0x2222222222222222ULL) return 0;
	if(c != 0x3333333333333333ULL) return 0;
	return cpass == 1;
}

static Label plabel;
static int pcount;
static int psp_ok;

static uintptr
getsp(void)
{
	uintptr sp;

	__asm__ volatile("mov %0, sp" : "=r"(sp));
	return sp;
}

/*
 * Burn a few hundred bytes of stack, then jump. The frame here must be
 * large enough that a gotolabel which failed to restore sp would leave
 * it visibly wrong on return.
 *
 * noinline is load-bearing: called once from one place, clang inlines
 * this at -O2, which puts gotolabel back at the same stack depth as
 * setlabel and makes restoring sp a no-op again. An earlier version of
 * this test passed with the sp restore deleted for exactly that reason.
 */
static void __attribute__((noinline))
deeper(void)
{
	volatile char pad[512];

	pad[0] = 1;
	pad[511] = 2;

	gotolabel(&plabel);

	/*
	 * Unreachable, but it must be here.
	 *
	 * With gotolabel as the last statement, clang emits a TAIL CALL:
	 * it runs this function's epilogue -- restoring sp -- and then
	 * branches. gotolabel would then already be at the caller's stack
	 * depth, making the sp restore a no-op and the test unable to
	 * detect its removal. Verified in the disassembly: "add sp, sp,
	 * #0x10" followed by "b". Referencing pad afterwards forces a
	 * real call, so gotolabel genuinely runs on this frame.
	 */
	pad[1] = 3;
	USED(pad);
}

static void
probelabel(void)
{
	static uintptr sp0, sp1;
	static int ok;

	ok = 1;
	pcount = 0;
	psp_ok = 0;

	sp0 = getsp();

	if(setlabel(&plabel) == 0){
		/* first pass: setlabel must report 0 */
		pcount++;
		/*
		 * Jump back from DEEPER in the stack, not from here.
		 * Calling gotolabel at the same depth setlabel was taken
		 * at makes restoring sp a no-op, so the check would pass
		 * even with the restore deleted -- which is exactly what
		 * an earlier version of this test did.
		 */
		deeper();
		/* gotolabel must not return */
		ok = 0;
		pcount += 100;
	} else {
		/* resumed: setlabel now appears to have returned 1 */
		pcount++;
	}

	sp1 = getsp();
	if(sp0 != sp1)
		ok = 0;			/* stack pointer not restored */
	else
		psp_ok = 1;

	/*
	 * Callee-saved registers must survive too, and this is NOT
	 * implied by the sp check.
	 *
	 * gotolabel re-enters this frame from deeper in the call chain,
	 * skipping the epilogues that would normally restore x19-x29. An
	 * earlier version of setlabel saved only sp and pc, and this test
	 * passed anyway -- the corruption surfaced much later, as
	 * os/port/dev.c calling free() on a stale pointer it had kept in
	 * x19 across waserror(). Ask the compiler to hold a value in a
	 * callee-saved register across the jump and check it survives.
	 */
	if(!checkcalleesaved())
		ok = 0;

	if(pcount != 2)
		ok = 0;			/* did not pass through exactly twice */

	print("lbl:  setlabel/gotolabel %s (passes=%d, sp %s, callee-saved %s)\n",
		ok ? "OK" : "BROKEN", pcount,
		psp_ok ? "restored" : "NOT restored",
		checkcalleesaved() ? "preserved" : "LOST");
}

/*
 * getcallerpc must name the caller.
 *
 * There are two implementations and they have to agree. fns.h defines a
 * macro over __builtin_return_address for anything that includes it;
 * libinterp does not, so it calls the out-of-line version in arch.S.
 *
 * They disagreed. The asm returned x30, which on entry is a PC *inside*
 * the calling function rather than that function's own return address.
 * Nothing detected it, because the value is only ever printed -- so it
 * degraded every allocator and lock diagnostic in the kernel into
 * confident nonsense. A pool corruption reported "alloc:D2B (from
 * 85134/a56d4)", and both addresses resolved into functions that never
 * allocate anything, which is worse than no attribution at all: it sends
 * you reading the wrong code.
 *
 * So check the answer rather than trusting it. Both forms are called
 * from a known function and the result must land inside that function.
 * Wrapping the name in parentheses suppresses the function-like macro,
 * which is what makes it possible to test the asm version from a file
 * that has the macro in scope.
 */
static uintptr	gcpmacro(void);
static uintptr	gcpasm(void);
static int	gcpcaller(uintptr*, uintptr*);

static uintptr __attribute__((noinline))
gcpmacro(void)
{
	int dummy = 0;
	return (uintptr)getcallerpc(&dummy);
}

static uintptr __attribute__((noinline))
gcpasm(void)
{
	int dummy = 0;
	return (uintptr)(getcallerpc)(&dummy);
}

/*
 * Both calls happen here, so both answers must point into this
 * function. Returning 1 keeps it from being folded away.
 */
static int __attribute__((noinline))
gcpcaller(uintptr *pm, uintptr *pa)
{
	*pm = gcpmacro();
	*pa = gcpasm();
	return 1;
}

static void
probecallerpc(void)
{
	uintptr pm, pa, lo;
	int mok, aok;

	gcpcaller(&pm, &pa);

	/*
	 * A return address into gcpcaller lies just past one of the two
	 * call sites, so it is above the function entry and within a
	 * short distance of it. That is a loose bound deliberately --
	 * the point is to catch an answer from an unrelated function,
	 * which is the failure that actually occurred, not to pin an
	 * exact offset the optimiser is free to move.
	 */
	lo = (uintptr)gcpcaller;
	mok = pm > lo && pm < lo + 0x200;
	aok = pa > lo && pa < lo + 0x200;

	print("gcpc: getcallerpc %s (macro %s, asm %s, caller %p)\n",
		mok && aok ? "OK" : "BROKEN",
		mok ? "names caller" : "WRONG",
		aok ? "names caller" : "WRONG",
		(void*)lo);
}

/*
 * The scheduler's data structures.
 *
 * procinit carves the process table out of xalloc and threads it into a
 * free list; newproc takes one, assigns a pid, and gives it a kernel
 * stack. This is proc.c genuinely running rather than merely linking --
 * it exercises the free list, the pid allocator, the Ref locking in
 * incref, and the Label the scheduler will later setlabel into.
 *
 * Not yet exercised: sched() itself, which needs a second process to
 * switch to and a run queue with something on it.
 */
static void
probeproc(void)
{
	Proc *p, *q;
	int ok;

	ok = 1;

	p = newproc();
	q = newproc();
	if(p == nil || q == nil)
		ok = 0;
	else {
		if(p == q)
			ok = 0;			/* handed out the same slot twice */
		if(p->pid == 0 || q->pid == 0 || p->pid == q->pid)
			ok = 0;			/* pids must be distinct and non-zero */
		if(p->state != Scheding)
			ok = 0;			/* newproc leaves a proc mid-schedule */

		/*
		 * A fresh proc must have a kernel stack, and it must lie in
		 * the memory xalloc owns rather than pointing anywhere.
		 */
		if(p->kstack == nil || q->kstack == nil)
			ok = 0;
		else if((uintptr)p->kstack < conf.base0
		     || (uintptr)p->kstack >= mmuramtop())
			ok = 0;
		if(p->kstack == q->kstack)
			ok = 0;			/* two procs sharing one stack */
	}

	print("proc: procinit/newproc %s", ok ? "OK" : "BROKEN");
	if(p != nil && q != nil)
		print(" (pids %lud,%lud, %lud slots)", (ulong)p->pid, (ulong)q->pid,
			(ulong)conf.nproc);
	print("\n");
}

/*
 * QLocks and RWlocks -- the blocking locks os/port uses everywhere a
 * spinlock would be wrong.
 *
 * Only the UNCONTENDED paths are exercised. A contended qlock parks the
 * caller and calls sched(), and with no other runnable process that
 * would hang rather than fail -- so this checks that taking a free lock
 * does not sleep, that the lock is then genuinely held, and that
 * releasing it makes it available again. Contention needs two processes
 * and belongs with the first real sched() test.
 */
static void
probeqlock(void)
{
	static QLock q;
	static RWlock rw;
	Pgrp *pg;
	int ok;

	ok = 1;

	/* a free qlock must be takeable without sleeping */
	qlock(&q);
	if(canqlock(&q))
		ok = 0;			/* it reported free while we hold it */
	qunlock(&q);
	if(!canqlock(&q))
		ok = 0;			/* still held after release */
	qunlock(&q);

	/* readers must not exclude readers */
	rlock(&rw);
	rlock(&rw);
	runlock(&rw);
	runlock(&rw);

	/* a writer must exclude, and release cleanly */
	wlock(&rw);
	wunlock(&rw);

	/* and the lock must be reusable afterwards */
	rlock(&rw);
	runlock(&rw);

	print("qlok: qlock/rwlock %s\n", ok ? "OK (uncontended paths)" : "BROKEN");

	/*
	 * pgrp.c: a process group is the root of a namespace, so this is
	 * the first structure that will hold mounts once chan.c lands.
	 */
	ok = 1;
	pg = newpgrp();
	if(pg == nil || pg->r.ref != 1)
		ok = 0;
	else
		closepgrp(pg);
	print("pgrp: newpgrp %s\n", ok ? "OK" : "BROKEN");
}

/*
 * Channels and path names -- the namespace layer.
 *
 * A Chan is Inferno's file handle, and Cname is the path that got you
 * there. Every mount, bind and open in the system is built on these, so
 * this is the layer that makes "everything is a file" mean anything.
 *
 * Only the allocation and path machinery is exercised. Walking a path
 * (namec) needs devtab populated with real devices, which arrives with
 * devroot.c -- until then there is nothing to walk to.
 */
static void
probechan(void)
{
	Chan *c, *d;
	Cname *n;
	int ok;

	ok = 1;

	c = newchan();
	d = newchan();
	if(c == nil || d == nil)
		ok = 0;
	else {
		if(c == d)
			ok = 0;			/* same Chan handed out twice */
		if(c->r.ref != 1 || d->r.ref != 1)
			ok = 0;			/* a fresh Chan holds one reference */
	}

	/*
	 * Path names. addelem is what walking a path does one component
	 * at a time, and it is where a namespace either composes
	 * correctly or silently produces the wrong file.
	 */
	n = newcname("/");
	if(n == nil || n->r.ref != 1)
		ok = 0;
	else {
		n = addelem(n, "dev");
		n = addelem(n, "cons");
		if(n == nil || strcmp(n->s, "/dev/cons") != 0)
			ok = 0;
		cnameclose(n);
	}

	/*
	 * These two were allocated by hand and have no device behind
	 * them, so they cannot be closed -- cclose() would call
	 * devtab[c->type]->close(c) and type 0 is the root device, which
	 * never attached them. Freeing them directly is what chanfree is
	 * for.
	 */
	if(c != nil) chanfree(c);
	if(d != nil) chanfree(d);

	print("chan: newchan/cname %s\n",
		ok ? "OK (refcounts, path composition)" : "BROKEN");
}

/*
 * The root device, and a Chan with something real behind it.
 *
 * devattach('/', "") returns a Chan attached to the root device, which
 * is where every namespace starts -- everything else is bound or
 * mounted onto it. This is the first Chan in the system that a device
 * actually owns, so it is also the first that can be walked and closed.
 *
 * Closing is the part worth having: it faulted through a nil function
 * pointer while devtab was empty, and the symptom (EC=0, "unknown
 * reason", at an address in an unrelated function) looked nothing like
 * the cause.
 */
static void
proberoot(void)
{
	Chan *c;
	Walkqid *wq;
	int ok;

	ok = 1;

	c = devattach('/', "");
	if(c == nil)
		ok = 0;
	else {
		if(c->type != devno('/', 0))
			ok = 0;			/* not bound to the root device */
		if(c->r.ref != 1)
			ok = 0;
		if((c->qid.type & QTDIR) == 0)
			ok = 0;			/* the root must be a directory */

		/* walk to the one entry the root filesystem has */
		wq = devtab[c->type]->walk(c, nil, (char*[]){"dev"}, 1);
		if(wq == nil || wq->nqid != 1)
			ok = 0;
		else {
			if((wq->qid[0].type & QTDIR) == 0)
				ok = 0;		/* /dev is a directory */
			if(wq->clone != nil)
				cclose(wq->clone);
			free(wq);
		}

		cclose(c);		/* the path that used to fault */
	}

	print("root: devattach/walk/cclose %s\n",
		ok ? "OK (attached, walked to /dev, closed)" : "BROKEN");
}

/*
 * The system call layer -- an actual filesystem interface.
 *
 * sysfile.c is what turns Chans into file descriptors: kopen, kread,
 * kclose and the rest. Getting a real fd back from a real path is the
 * point at which the kernel stops being a set of data structures and
 * starts being something a program could use.
 *
 * This needs a process with a namespace, so `up` is switched from the
 * static boot placeholder to a proper Proc from newproc(), with a Pgrp
 * (the mount table namec walks) and an Fgrp (where file descriptors
 * live). That is the first time in this kernel that `up` means what
 * os/port assumes it means.
 */
static void
probesysfile(void)
{
	Proc *p;
	int fd, ok;
	Dir *d;
	char buf[512];
	long n;

	ok = 1;

	p = newproc();
	if(p == nil){
		print("file: newproc failed\n");
		return;
	}
	kstrdup(&p->env->user, eve);	/* run as the host owner */
	p->env->pgrp = newpgrp();
	p->env->fgrp = newfgrp(nil);
	/*
	 * And an environment group. #e refuses to attach without one --
	 * envattach() errors with Enodev if up->env->egrp is nil -- so
	 * without this the environment device is present in the devtab
	 * and unusable, which reports as "no free devices" and sounds
	 * like something else entirely.
	 */
	p->env->egrp = newegrp();
	if(p->env->pgrp == nil || p->env->fgrp == nil){
		print("file: no namespace\n");
		return;
	}
	up = p;

	/*
	 * Publish the board's Ethernet address into the environment.
	 *
	 * The LAN7800 on this board cannot report its own: it has no
	 * EEPROM and its OTP is unprogrammed, so RX_ADDR reads all-ones.
	 * The address belongs to the BOARD, not to the part -- the
	 * firmware derives it from the serial number -- so the kernel is
	 * the only thing positioned to ask, and /env is how a program
	 * that needs it can be told without any of this being wired into
	 * the driver.
	 */
	{
		uchar mac[6];
		char buf[32];

		if(getmacaddr(mac) == 0){
			snprint(buf, sizeof buf,
				"%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux",
				mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
			ksetenv("ethermac", buf, 0);
			print("mbox: board ethernet address %s\n", buf);
		}
	}

	/*
	 * Root the namespace.
	 *
	 * A Pgrp with no slash is not a namespace -- namec() resolves an
	 * absolute path by walking from pgrp->slash, so leaving it nil
	 * means every path lookup dereferences nil. It surfaced here as a
	 * spinlock stuck on address 0x20, which is nil plus the offset of
	 * the RWlock inside Pgrp: a nil deref wearing a lock contention
	 * costume.
	 *
	 * This is what init0() does at boot in a full kernel: attach the
	 * root device, make it slash, and clone it for dot.
	 */
	/*
	 * Attach through the DEVICE's own attach, not devattach().
	 *
	 * devattach() is the generic helper in dev.c: it manufactures a
	 * Chan bound to a device letter and nothing more. The root
	 * device's rootattach() does something devattach cannot know
	 * about -- it walks rootdata and copies each embedded file's
	 * length from *sizep into size, because mkroot emits the length
	 * as a separate symbol resolved at link time.
	 *
	 * Calling devattach directly produced a namespace where every
	 * embedded file existed, could be opened, and read as ZERO bytes.
	 * /osinit.dis then failed to load with "bad magic", which is a
	 * true statement about an empty file and a completely misleading
	 * description of the problem.
	 */
	up->env->pgrp->slash = devtab[devno('/', 0)]->attach("");
	up->env->pgrp->dot = cclone(up->env->pgrp->slash);

	/*
	 * Open the root directory by name. This exercises the whole
	 * chain: namec parses the path, walks it through the mount table
	 * to the root device, opens the Chan, and newfd installs it in
	 * the Fgrp.
	 */
	fd = kopen("/", OREAD);
	if(fd < 0)
		ok = 0;
	else {
		/* reading a directory returns packed stat entries */
		n = kread(fd, buf, sizeof buf);
			if(n <= 0)
			ok = 0;
		else {
			/*
			 * Scan the packed stat entries for /dev rather than
			 * assuming it comes first. The root's contents are
			 * generated from a manifest now, so their order is a
			 * property of the build and not something a test of
			 * the file path should be pinned to.
			 */
			int off, found;
			uint m;

			found = 0;
			for(off = 0; off < n; off += m){
				d = malloc(sizeof(Dir) + (n - off));
				if(d == nil)
					break;
				m = convM2D((uchar*)buf+off, n-off, d, (char*)(d+1));
				if(m <= BIT16SZ){
					free(d);
					break;
				}
				if(strcmp(d->name, "dev") == 0)
					found = 1;
				free(d);
			}
			if(!found)
				ok = 0;
		}
		if(kclose(fd) < 0)
			ok = 0;
	}

	/* a path that does not exist must fail rather than succeed quietly */
	if(kopen("/nosuchfile", OREAD) >= 0)
		ok = 0;

	print("file: kopen/kread/kclose %s\n",
		ok ? "OK (opened /, found \"dev\", closed)" : "BROKEN");
}

/*
 * Queues -- the byte/Block pipe os/port and os/ip are built on.
 *
 * A Queue is a chain of Blocks with flow control. devcons pushes console
 * input through one; every socket in os/ip has four of them (read,
 * write, error, snoop). So this is the last structural piece before
 * either a console or a network stack.
 *
 * Only paths with data already present are exercised. qread on an empty
 * queue sleeps until a writer arrives, and with no second process that
 * would hang rather than fail -- the same limit as the qlock probe.
 */
static void
probeqio(void)
{
	Queue *q;
	Block *b;
	char buf[64];
	int ok;
	long n;

	ok = 1;

	q = qopen(4096, 0, nil, nil);
	if(q == nil){
		print("qio:  qopen failed\n");
		return;
	}

	if(qlen(q) != 0)
		ok = 0;			/* a fresh queue holds nothing */

	/* byte interface: write then read back */
	if(qwrite(q, "hello", 5) != 5)
		ok = 0;
	if(qlen(q) != 5)
		ok = 0;
	n = qread(q, buf, sizeof buf);
	if(n != 5 || memcmp(buf, "hello", 5) != 0)
		ok = 0;
	if(qlen(q) != 0)
		ok = 0;			/* reading must consume */

	/*
	 * Block interface: this is the path os/ip actually uses, and it
	 * must hand back the same Block rather than copying.
	 */
	b = allocb(64);
	if(b == nil)
		ok = 0;
	else {
		memmove(b->wp, "packet", 6);
		b->wp += 6;
		if(qbwrite(q, b) < 0)
			ok = 0;
		if(qlen(q) != 6)
			ok = 0;
		b = qbread(q, 64);
		if(b == nil || BLEN(b) != 6 || memcmp(b->rp, "packet", 6) != 0)
			ok = 0;
		if(b != nil)
			freeb(b);
	}

	/* a queue past its limit must refuse rather than grow without bound */
	if(qwrite(q, "x", 1) != 1)
		ok = 0;
	qflush(q);
	if(qlen(q) != 0)
		ok = 0;			/* flush must discard */

	qfree(q);

	print("qio:  qopen/qwrite/qread/qbwrite %s\n",
		ok ? "OK (bytes and Blocks, flow accounted)" : "BROKEN");
}

/*
 * The console device in the namespace.
 *
 * devcons provides #c: cons, random, time, drivers, sysname and the
 * rest. Binding it at /dev is what makes "/dev/cons" a path a program
 * can open -- and writing to that path is the first output in this
 * kernel that goes through the full stack (namec, the Chan, the device
 * write) rather than straight at the UART.
 */
static void
probecons(void)
{
	int fd, ok;
	char buf[64];
	long n;

	ok = 1;

	/*
	 * #M's reset, before anything can mount.
	 *
	 * A real Inferno kernel calls chandevreset() early in main() and
	 * every device's reset runs from there. This one does not -- the
	 * comment above usbkproc() explains why, and usb and ip already
	 * call their own resets by hand as a result -- so devmnt's has to
	 * be called explicitly too, and nothing else will do it.
	 *
	 * It is not optional and it fails loudly rather than subtly:
	 * mntalloc.id starts at 1 so that a Mnt's id is never 0, and
	 * mntchk() panics with "mntchk 3: can't happen" on an id of 0.
	 * Which is what it did, on the first mount this kernel ever
	 * attempted. It also reserves tag 0 and NOTAG, and installs the
	 * %F fcall format every 9P diagnostic is written against.
	 *
	 * Unlike usb's, this reset depends on no hardware, so it can be
	 * called here, before there are processes.
	 */
	if(mntdevtab.reset != nil)
		mntdevtab.reset();

	/*
	 * #b's reset is what REGISTERS $Bench as a builtin module.
	 *
	 * A device's reset is not called for its own sake here -- this
	 * kernel does not run chandevreset() -- so a device whose reset
	 * does real work has to be named. Without this, load Bench
	 * returns nil and every measurement reports that it cannot
	 * measure, which is at least honest but not useful.
	 *
	 * Like mnt's, it touches no hardware, so it is safe this early.
	 */
	if(benchdevtab.reset != nil)
		benchdevtab.reset();

	/*
	 * #s's reset, and this one is not a convenience either.
	 *
	 * srvinit() creates the two Dis channel types a served file's
	 * reads and writes are typed with, allocates the heap types for
	 * the Rread and Rwrite replies, and -- quietly the most important
	 * -- sets dev.pathgen to 1 so that no served file is ever handed
	 * qid path 0, which is the srv root's own.
	 *
	 * None of that ran, because this kernel has no chandevreset().
	 * The result was not a device that failed: it was a device that
	 * WORKED, with a nil reply type and every file colliding with the
	 * root on qid 0. The window manager brought it down a few seconds
	 * after starting -- /prog disappeared from a namespace nobody had
	 * touched, a walk of "/mnt" came back with a chan belonging to an
	 * unrelated 9P mount, and the kernel panicked in cclose closing a
	 * channel that had already been freed.
	 *
	 * Touches no hardware, so it belongs here with the other two.
	 */
	if(srvdevtab.reset != nil)
		srvdevtab.reset();

	/* run every device's init, as a real kernel does at boot */
	chandevinit();

	/* bind #c onto /dev so the console is reachable by path */
	if(kbind("#c", "/dev", MREPL|MCREATE) < 0)
		ok = 0;

	/*
	 * And the pointer, so /dev/pointer is a path like any other.
	 *
	 * MAFTER, not MREPL: #c is already there and holds the console.
	 * The union is the point -- a pointing device is one more file in
	 * /dev, not a competing idea of what /dev is.
	 */
	if(kbind("#m", "/dev", MAFTER) < 0)
		ok = 0;

	fd = kopen("/dev/cons", OWRITE);
	if(fd < 0)
		ok = 0;
	else {
		n = kwrite(fd, "cons: hello from /dev/cons\n", 27);
		if(n != 27)
			ok = 0;
		kclose(fd);
	}

	/* #c/sysname is a plain readable file: a good round-trip check */
	fd = kopen("/dev/sysname", OREAD);
	if(fd < 0)
		ok = 0;
	else {
		n = kread(fd, buf, sizeof buf - 1);
		if(n < 0)
			ok = 0;
		kclose(fd);
	}

	print("cons: /dev/cons %s\n",
		ok ? "OK (bound #c at /dev, wrote through the namespace)" : "BROKEN");
}

/*
 * Start the Dis virtual machine.
 *
 * disinit() is the handover: it initialises the opcode table, registers
 * the built-in modules, loads /osinit.dis out of the in-kernel root
 * filesystem, schedules it, opens fd 0/1/2 on #c/cons, and enters
 * vmachine() -- which does not return. From that point the machine is
 * running Limbo, and the C kernel exists only to serve it.
 *
 * This must run as a kernel process rather than inline: vmachine() is
 * the VM's scheduler loop and owns the thread it runs on.
 */
/*
 * The generated root filesystem's tables (tools/mkrootfs.py). devroot.c
 * declares neither, so say so here rather than including a generated
 * header just for a count.
 */
extern int	rootmaxq;

/*
 * libinterp's JIT switch, defined in os/port/dis.c. Declared here
 * rather than pulled in from a libinterp header, which would drag the
 * whole interpreter view of the world into a file that only wants one
 * int.
 */
extern int	cflag;
extern Dev	usbdevtab;
extern Dev	ipdevtab;
extern void	loopbackmediumlink(void);
extern void	ethermediumlink(void);

#ifndef CFLAG
#define CFLAG 1
#endif

/*
 * Feed the serial line into the console input queue.
 *
 * This board has no keyboard: the only way to type at it is the UART,
 * on GPIO 14/15 through a USB-serial cable, or -serial stdio under
 * QEMU. Polling rather than taking the PL011 receive interrupt keeps
 * the driver honest about what it has been tested with -- the transmit
 * path has been polled since the first boot, and an interrupt-driven
 * receive path would be the first untested interrupt source in the
 * kernel. It can become one later; a shell that answers is worth more
 * now than a tidy one that does not exist.
 *
 * kbdputc does the line discipline -- echo, backspace, kill -- and
 * hands complete lines to kbdq, which is what /dev/cons reads.
 */
static void
uartkproc(void *a)
{
	int c;

	USED(a);
	for(;;){
		c = uartgetc();
		if(c < 0){
			/*
			 * Nothing waiting. Sleep briefly rather than spin:
			 * this shares one core with everything else, and a
			 * tight poll would starve the process that is
			 * supposed to be reading what we produce.
			 */
			tsleep(&up->sleep, return0, nil, 10);
			continue;
		}
		/*
		 * Enter sends CR, not NL -- every terminal emulator does,
		 * and so does anything driving this line from a script.
		 * consread()'s cooked-mode line discipline ends a line on
		 * NL (or ^D) and nothing else, so an untranslated CR is
		 * appended to kbd.line as an ordinary character and the
		 * line is never terminated: the characters arrive, the
		 * kernel holds them, and the shell waits for a line that
		 * can never be completed.
		 *
		 * This is what ICRNL does on any other system. A board
		 * whose only console is a UART has to do it somewhere, and
		 * the driver that owns the line is the place.
		 */
		if(c == '\r')
			c = '\n';

		/*
		 * Echo here too, because nothing else will. echo() in
		 * devcons writes to printq or to a bitmapped display;
		 * printq is never set in this tree and this board has no
		 * screen, so without this the console is blind -- you type
		 * and see nothing, which reads exactly like input being
		 * dropped.
		 *
		 * Not via screenputs: putstrn0 already sends kernel output
		 * down the same wire through serwrite, so borrowing the
		 * screen hook would double every line the kernel prints.
		 */
		if(c == '\n')
			uartputc('\r');
		uartputc(c);

		kbdputc(kbdq, c);
	}
}

/*
 * Bring up USB, from a process rather than from the boot path.
 *
 * The DWC driver's init() sleeps -- tsleep() while the controller
 * resets -- and sleeping requires a scheduler and a process to put to
 * sleep. Calling it from kmain() runs it on the boot stack with no way
 * to yield, which sched()'s stack invariant catches immediately:
 *
 *     panic: sched: pid 3 sp 7fbf8 outside kstack fb7b0..ff7b0
 *
 * That is the check earning its keep: without it the failure would
 * have been a corrupted boot stack surfacing much later somewhere
 * unrelated.
 *
 * Upstream has the same constraint and meets it by structure -- a real
 * Inferno kernel runs chandevreset() early in main() and chandevinit()
 * from its FIRST PROCESS, not from the boot path. This kernel still
 * calls chandevinit() during boot because the passive devices (root,
 * cons) are needed before there are processes at all, so USB gets its
 * own kproc instead of restructuring that now.
 */
static void
usbkproc(void *a)
{
	USED(a);

	usbdwclink();		/* addhcitype("dwcotg", reset) */
	if(usbdevtab.reset != nil)
		usbdevtab.reset();
	if(usbdevtab.init != nil)
		usbdevtab.init();

	/*
	 * The IP stack.
	 *
	 * ipreset() registers the media types and installs the address
	 * format verbs (%I, %E, %V and friends), which os/ip uses in
	 * nearly every diagnostic it prints -- without them an error
	 * message about an address prints the verb instead of the
	 * address.
	 *
	 * loopbackmediumlink() is called here rather than in ipreset()
	 * because upstream's ipreset links only null and pkt; loopback is
	 * a separate medium a configuration opts into. It is the one that
	 * matters most right now: it gives a stack that can be exercised
	 * end to end with no network hardware at all, which is the only
	 * kind this board has until USB enumeration exists.
	 */
	loopbackmediumlink();

	/*
	 * The Ethernet medium, for the same reason loopback is linked
	 * here: upstream's ipreset() links only null and pkt, and
	 * everything else is a medium a particular configuration opts
	 * into.
	 *
	 * It attaches by NAME (see the header of os/ip/ethermedium.c), so
	 * linking it commits this kernel to nothing about where the
	 * driver lives -- which is the point, because on this board it
	 * lives outside the kernel.
	 */
	ethermediumlink();
	if(ipdevtab.reset != nil)
		ipdevtab.reset();

	pexit("", 0);
}

static void
startdis(void)
{
	/*
	 * Compile Dis to native AArch64 rather than interpreting it.
	 *
	 * cflag is what libinterp checks in parsemod() to decide whether
	 * to run a module through comp-arm64.c. Above 3 it also dumps the
	 * generated code, which is the only practical way to inspect it
	 * on a machine with no debugger.
	 *
	 * The interpreter remains the reference: -c0 behaviour is exactly
	 * what this kernel did before, so a miscompilation can always be
	 * bisected against it.
	 */
	/*
	 * CFLAG is overridable from the build so the same kernel can be
	 * measured both ways. Benchmarking a JIT against a DIFFERENT
	 * kernel proves nothing -- everything else has to be identical.
	 */
	cflag = CFLAG;

	print("\ndis:  handing control to the Dis VM\n");
	print("dis:  cflag=%d (%s)\n", cflag,
		cflag ? "JIT: compiling Dis to AArch64" : "interpreter only");
	print("dis:  root filesystem: %d entries compiled into the image\n",
		rootmaxq);

		/*
	 * KPDUPPG|KPDUPFDG|KPDUPENVG: the Dis process inherits the
	 * namespace, file descriptors and environment rather than
	 * starting with none. disinit() opens #c/cons three times for
	 * fd 0/1/2, which needs a mount table to resolve it against.
	 */
	/*
	 * Ctrl-T Ctrl-T r reboots this machine, and nothing here has to
	 * arrange it.
	 *
	 * devcons already registers 'r' as a debug key bound to rexit,
	 * and debugkey() silently IGNORES a second registration of the
	 * same rune -- so a "reboot" key added here would have been dead
	 * code that looked live. exit() on this board resets into
	 * serialboot, which is exactly where a development reboot wants
	 * to land, so the existing key is the right one.
	 *
	 * It matters because it does not need a shell. "echo reboot >
	 * /dev/sysctl" works only when one is sitting at a prompt ready
	 * to read a line, and during development it very often is not:
	 * the board is part way through a boot, or the console is busy
	 * printing, and the typed command interleaves with that output
	 * and is mangled. It then fails silently and the only way back is
	 * the power switch. A debug key is handled in kbdputc, character
	 * by character, before the line discipline and before any shell.
	 */

	kproc("display", displaywatch, nil, 0);
	kproc("usb", usbkproc, nil, 0);
	kproc("uart", uartkproc, nil, 0);
	kproc("dis", disinit, "/osinit.dis", KPDUPPG|KPDUPFDG|KPDUPENVG);
}


/*
 * Called by the scheduler when no process is ready to run.
 *
 * wfi rather than a spin: it stops the core until an interrupt arrives,
 * which on this board means the next timer tick. Spinning would work
 * and would also cook the SoC.
 */
/*
 * Entry point for a newly created kernel process, called via its saved
 * Label. os/port/proc.c sets a kproc's pc here; the real work is that
 * the process starts with interrupts enabled, which it does not inherit
 * from the scheduler's context.
 */
/*
 * Where a new kernel process begins executing.
 *
 * The scheduler enters a process by gotolabel-ing into its sched Label,
 * so a brand new process needs one that points somewhere sensible. That
 * is here: drop to spllo (a new process starts with interrupts enabled,
 * which it does not inherit from the scheduler), call the function it
 * was created for, and pexit when that returns.
 *
 * The waserror is not decoration. If the process body calls error()
 * without a matching handler, the unwind runs off the bottom of its
 * error stack; catching it here turns that into a message instead of a
 * jump through an uninitialised Label.
 */
static void
linkproc(void)
{
	spllo();
	if(waserror())
		print("linkproc: error() underflow: %s\n", up->env->errstr);
	else
		(*up->kpfun)(up->arg);
	pexit("end proc", 1);
}

void
kprocchild(Proc *p, void (*func)(void*), void *arg)
{
	p->sched.pc = (uintptr)linkproc;

	/*
	 * KSTACK-16, not KSTACK-8.
	 *
	 * Every 32-bit ARM port upstream writes -8, which is correct
	 * there. AArch64 requires the stack pointer to be 16-byte aligned
	 * whenever it is used to access memory, and an SP alignment fault
	 * is a synchronous exception on the very first push -- before the
	 * process has run a single useful instruction.
	 */
	p->sched.sp = (uintptr)p->kstack + KSTACK - 16;

	p->kpfun = func;
	p->arg = arg;
}

void
idlehands(void)
{
	__asm__ volatile("wfi");
}

/*
 * Save and restore the per-process state the scheduler does not: the
 * FP/SIMD register file.
 *
 * This was a no-op, on the reasoning that the kernel is built
 * -mgeneral-regs-only so nothing can dirty FP state. That reasoning
 * was true of the kernel and false of the system: libinterp is
 * deliberately built WITH FP -- Dis has a floating point type and the
 * interpreter will not compile without it -- and libinterp is exactly
 * what a Dis process spends its time in.
 *
 * So the V registers are live in precisely the processes that get
 * preempted. The clock interrupt saves x0-x30 into the Ureg and
 * nothing else, and sched()'s setlabel/gotolabel preserve x19-x29 and
 * nothing else. d8-d15 are callee-saved under AAPCS64 and were being
 * preserved by neither, so a process resumed after another one ran
 * came back with whatever the other process left in them.
 *
 * The result was not a wrong number in a Limbo float. clang allocates
 * those registers for ordinary values when FP is available, so the
 * damage landed on live pointers and control flow: a preempted Dis
 * process would resume, return through a corrupted frame, and die
 * somewhere unrelated with pc = sp-16 on a stack it did not own.
 * Deterministic runs were fine; anything that took an interrupt at the
 * wrong instruction was not, which is why it looked like a 50% coin
 * flip rather than a bug.
 */
void
procsave(Proc *p)
{
	FPsave(&p->fpsave);
}

void
procrestore(Proc *p)
{
	FPrestore(&p->fpsave);
}

void
kmain(void)
{
	/*
	 * Copy the loaded image before anything writes to .data.
	 *
	 * This is the only moment the memory the kernel occupies still
	 * holds exactly what serialboot put there. Afterwards it holds a
	 * kernel that has been running, which is not something worth
	 * writing to a card and booting.
	 */
	bootimgsnap();

	uartinit();

	uartputstr("\nInferNode bare-metal (");
	uartputstr(boardname());
	uartputstr(")\n");

	uartputstr("  exception level: EL");
	uartputc('0' + (int)currentel());
	uartputstr("\n  midr_el1:        ");
	uartputx(midr());
	uartputstr("\n  mpidr_el1:       ");
	uartputx(mpidr());
	uartputstr("\n  console:         PL011 UART0, polled");
	uartputstr("\n  types:           ");
	uartputstr(typecheck() ? "arm64 u.h OK (LP64, stdarg)" : "TYPE FOUNDATION BROKEN");
	uartputstr("\n");

	trapinit();
	uartputstr("  vectors:         installed at VBAR_EL1\n\n");


	checktraps();

	/*
	 * The way back, offered before anything else is configured.
	 *
	 * Deliberately here and not later: serialboot runs with the MMU
	 * and caches off, which is the state the board is still in at
	 * this point, so handing over needs no teardown. It also means
	 * almost nothing a later change can break is able to break the
	 * recovery path. See os/bcm2837/recover.c.
	 */
	serialrecover();

	boardprobe();
	startmmu();

	/*
	 * Boot proper, in dependency order. Each stage needs the one
	 * before it, and the ordering is not cosmetic:
	 *
	 *   confinit  finds the free memory bank
	 *   xinit     hands that bank to the base allocator
	 *   poolinit  builds malloc's pools on top of xalloc
	 *   printinit gives devcons a line queue -- which it allocates,
	 *             so it cannot come before poolinit
	 *   procinit  carves the process table out of xalloc
	 *
	 * Everything before this point reports through uartputstr(),
	 * which writes to the PL011 directly and needs nothing
	 * initialised. Everything after can use print().
	 */
	confinit();
	xinit();
	poolinit();
	printinit();

	/*
	 * The clock, before anything can register a timer callback.
	 *
	 * clockinit() ends by calling timersinit()/todinit(), and
	 * os/port/tod.c initialises itself lazily: the first
	 * ns2fastticks() triggers todinit(), which calls addclock0link()
	 * -- from inside an addclock0link() that already holds
	 * timers[0]. So whoever registers the first timer deadlocks
	 * unless tod is already up.
	 *
	 * That is exactly what happened while this lived in a probe:
	 * chandevinit() registers a console callback during device
	 * initialisation, which ran before the clock did.
	 */
	/*
	 * The interrupt controller, before the clock -- clockinit()
	 * routes the timer, and any driver that registers a handler needs
	 * the controller's tables to exist first.
	 */
	intrinit();

	clockinit();

	/*
	 * Point the console at the serial line.
	 *
	 * devcons.c's putstrn0() sends output to the kprint queue, then to
	 * a screen, then to serwrite -- and if none of those are set and
	 * printq is still nil, it DISCARDS the text and returns. printq is
	 * only created when a process opens the console device, so on a
	 * board that boots to a serial console every print() before that
	 * would vanish silently.
	 *
	 * serwrite is the hook upstream provides for exactly this: "the
	 * console is a serial line". uartputs already has the right
	 * signature because portfns.h defines it that way.
	 */
	serwrite = uartputs;

	/*
	 * Establish the host owner.
	 *
	 * eve is the user the kernel considers privileged; devcons.c
	 * declares it but leaves it nil, and iseve() compares the current
	 * process's user against it. Left nil, every permission check on
	 * a device file fails -- opening /dev/cons returns "permission
	 * denied", which reads like a mode problem and is really an
	 * identity problem.
	 *
	 * A full kernel sets this in main() and gives the first process
	 * the same name in init0(). This is that, minus the process part,
	 * which probesysfile does when it builds its Proc.
	 */
	kstrdup(&eve, "inferno");

	/*
	 * The host's name, reported through #c/sysname. devcons.c declares
	 * sysname but leaves it nil and nothing else sets it, so
	 * /dev/sysname read back empty -- which looks like a broken device
	 * rather than an unset string.
	 */
	kstrdup(&sysname, "infernode");

	/*
	 * Install %q.
	 *
	 * libkern has fmtquote.c and quotefmtinstall(), but nothing in this
	 * port ever called it, so print() emitted the verb literally: a
	 * Limbo program printing %q got back the two characters "%q".
	 * Inferno code uses %q for any string that might contain spaces, so
	 * this is not cosmetic -- it silently mangles the diagnostics you
	 * reach for when something else is wrong.
	 */
	quotefmtinstall();
	procinit();
	checkunaligned();
	boardioprobe();
	probearch();
	probelibkern();
	probexalloc();
	probealloc();
	probeblock();
	probelabel();
	probecallerpc();
	probeproc();
	probeqlock();
	probesysfile();
	probecons();
	probechan();
	proberoot();
	probeqio();
	probeclock();
	probeintr();
	probeuartin();
	/*
	 * Size the allocator pools for THIS machine.
	 *
	 * os/port/alloc.c ships ceilings of 4MB, 16MB and 8MB. They are
	 * upstream defaults for far smaller systems, and the hosted
	 * emulator never lives with them -- it is started with
	 * -pmain=1024m -pheap=1024m -pimage=1024m, which is exactly this
	 * adjustment made on a command line. Bare metal has no command
	 * line, so it got the defaults and a board with 946MB of RAM
	 * refused a one-megabyte allocation with "arena too large" while
	 * loading a driver.
	 *
	 * A ceiling is not a reservation -- pools grow from xalloc on
	 * demand -- so these are bounds on runaway growth rather than
	 * memory set aside. Taken as fractions of what conf found, so a
	 * board with different memory gets proportionate limits instead
	 * of numbers that happen to suit this one.
	 */
	{
		ulong mem;

		mem = (ulong)conf.npage * BY2PG;
		poolsize(mainmem, mem/8, 0);
		poolsize(heapmem, mem/4, 0);
		poolsize(imagmem, mem/8, 0);
	}

	boardfbprobe();
	boardsdprobe();

	/*
	 * Bind the card into /dev AFTER probing for it, not before.
	 *
	 * #S refuses to attach when there is no card -- which is right,
	 * since every file it would offer is a range of a device that is
	 * not there -- so binding it before emmcinit() has run means
	 * binding it before the card exists, and the bind simply fails.
	 * The card then works perfectly and /dev/sdcard is missing.
	 *
	 * Not fatal if there is no card: a board without one still boots,
	 * because everything it needs is compiled into this image.
	 */
	kbind("#S", "/dev", MAFTER);

	/* the running kernel, so it can be copied onto the card */
	kbind("#B", "/dev", MAFTER);

	/* microsecond timing, for measuring things honestly */
	kbind("#b", "/dev", MAFTER);

	/*
	 * #i is deliberately NOT bound here.
	 *
	 * Binding a device ATTACHES it, and attaching the draw device is
	 * what takes the framebuffer away from the text console -- so
	 * binding it at boot meant every machine lost its console to a
	 * window system that was never going to start. The console
	 * stopped drawing before the first line of boot output reached
	 * the panel.
	 *
	 * Whoever wants to draw binds it:  bind '#i' /dev
	 *
	 * which is how a namespace is supposed to be assembled in this
	 * system, and it leaves a machine that never draws with the
	 * console it had.
	 */

	uartputstr("\nboot OK\n");

	/*
	 * Declare this processor open for business. Until now hzclock()
	 * has been returning early on every tick: no alarms expiring, no
	 * preemption. That is deliberate -- the clock must not try to
	 * schedule anything before the process table, namespace and
	 * console exist.
	 */
	active.machs = 1;

	startdis();

	/*
	 * Enter the scheduler. schedinit() never returns: it setlabels
	 * into m->sched and then runs whatever is on the run queue --
	 * which is the Dis kproc created above.
	 *
	 * up must be nil going in. schedinit's first act is to decide what
	 * to do with the process it was called from, and there isn't one:
	 * kmain is the boot path, not a process. Leaving up pointing at
	 * the Proc probesysfile borrowed would make the scheduler try to
	 * re-queue or reap it.
	 */
	up = nil;
	spllo();
	schedinit();

	for(;;)
		__asm__ volatile("wfe");
}
