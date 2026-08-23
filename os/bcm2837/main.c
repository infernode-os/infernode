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

/*
 * The machine configuration os/port reads. Declared extern in dat.h and
 * defined here, which is where upstream's platform main.c puts it.
 */
Conf conf;

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
	uartputs("trap: testing exception path with BRK...");
	__asm__ volatile("brk #0");
	uartputs("trap: returned from exception, save/restore OK\n");
}

/*
 * Ask the firmware what board this is.  Cheap, and it is the first
 * confirmation that the mailbox round trip works at all -- worth having
 * before anything depends on the mailbox for something harder to debug.
 */
static void
probehw(void)
{
	u32int v[2];

	uartputs("mbox: ");
	v[0] = 0;
	if(mboxprop(Taggetrev, v, 0, 1) == 0){
		uartputs("board rev ");
		uartputx(v[0]);
	}else{
		uartputs("board rev query FAILED");
	}

	v[0] = 0;
	v[1] = 0;
	if(mboxprop(Taggetarmmem, v, 0, 2) == 0){
		uartputs(", ARM memory ");
		uartputd(v[1] >> 20);
		uartputs("MB at ");
		uartputx(v[0]);
	}
	uartputs("\n");
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

	uartputs("mmu:  ");
	if(!mmuon()){
		uartputs("FAILED to enable\n");
		return;
	}
	uartputs("on, caches ");
	uartputs(mmucaches() ? "on" : "off");
	uartputs(", identity map 0-");
	uartputd(mmumapped() >> 20);
	uartputs("MB, ramtop ");
	uartputx(mmuramtop());
	uartputs("\n      ttbr0=");
	uartputx(mmul1());
	uartputs(" tcr=");
	uartputx(mmutcr());
	uartputs(" mair=");
	uartputx(mmumair());
	uartputs("\n");
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
	static u8int buf[32];
	volatile u64int *p;
	u64int v;

	/* 4-byte aligned but deliberately not 8-byte aligned */
	p = (volatile u64int*)(void*)&buf[4];
	*p = 0x0123456789ABCDEFULL;
	v = *p;

	uartputs("mmu:  unaligned 64-bit access ");
	if(v == 0x0123456789ABCDEFULL)
		uartputs("OK (Normal memory; would fault with MMU off)\n");
	else
		uartputs("returned WRONG VALUE\n");
}

/*
 * Read back the pin mux the UART set up.
 *
 * Deliberately non-invasive: it only READS function selects, and only
 * for pins this kernel already configured.  Driving an arbitrary pin as
 * a self-test would be reckless on real hardware, where something may be
 * wired to it -- the header pins are attached to whatever the owner
 * plugged in, and a test that asserts an output could short a driven
 * line.  Reading back proves the mux took, which is the part that is
 * otherwise invisible.
 */
static void
probegpio(void)
{
	int f14, f15;

	f14 = gpiogetfunc(14);
	f15 = gpiogetfunc(15);

	uartputs("gpio: pin14 func=");
	uartputd(f14);
	uartputs(" pin15 func=");
	uartputd(f15);
	if(f14 == Gpioalt0 && f15 == Gpioalt0)
		uartputs(" (ALT0/UART as set) OK\n");
	else
		uartputs(" UNEXPECTED (wanted ALT0 on both)\n");
}

/*
 * Start the clock, and check it against an independent reference.
 *
 * CNTFRQ_EL0 is not derived by the hardware -- it is a value firmware
 * writes, and firmware can write the wrong one.  If it lies, every delay
 * and timeout in the kernel is off by that ratio, and the symptom is
 * never "the clock is wrong": it is flaky networking, or a display that
 * tears, or timeouts that fire early under load.  The BCM system timer
 * runs at a fixed 1MHz set by the hardware, so timing the same interval
 * with both and comparing catches it immediately.
 *
 * Then prove interrupts actually arrive, rather than assuming that
 * arming the comparator was enough.
 */
static void
probeclock(void)
{
	u64int c0, c1, s0, s1, genus, sysus, lo, hi;
	u64int deadline;

	clockinit();

	uartputs("clk:  cntfrq ");
	uartputd(clockfreq());
	uartputs("Hz (");
	uartputd(clockfreq() / 1000000);
	uartputs("MHz)\n");

	/* time 50ms by both clocks */
	s0 = systimer();
	c0 = clockcount();
	microdelay(50000);
	c1 = clockcount();
	s1 = systimer();

	sysus = s1 - s0;
	genus = ((c1 - c0) * 1000000) / clockfreq();

	uartputs("clk:  50ms measured: systimer ");
	uartputd(sysus);
	uartputs("us, generic ");
	uartputd(genus);
	uartputs("us -- ");

	/* agree within 5%? */
	lo = (sysus * 95) / 100;
	hi = (sysus * 105) / 100;
	if(genus >= lo && genus <= hi)
		uartputs("clocks AGREE\n");
	else
		uartputs("clocks DISAGREE (cntfrq is lying)\n");

	/*
	 * Now let interrupts in.  Wait for a few ticks with a wall-clock
	 * deadline so a dead interrupt line fails as a report rather than
	 * as a hang.
	 */
	intrenable();
	deadline = systimer() + 500000;		/* 500ms */
	while(clockticks() < 5 && systimer() < deadline)
		;

	uartputs("clk:  irq ");
	if(clockticks() >= 5){
		uartputs("firing, ");
		uartputd(clockticks());
		uartputs(" ticks at 100Hz OK\n");
	}else{
		uartputs("NOT firing (");
		uartputd(clockticks());
		uartputs(" ticks in 500ms)\n");
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

	uartputs("arch: _tas ");
	uartputs(ok ? "OK" : "BROKEN");

	/*
	 * spl must report the PREVIOUS level, not the new one.  Code that
	 * masks and then unconditionally unmasks would silently enable
	 * interrupts inside a caller that had deliberately masked them.
	 */
	ok = 1;
	s = splhi();
	if(islo())
		ok = 0;			/* still low after splhi */
	old = spllo();
	if(!islo())
		ok = 0;			/* still high after spllo */
	if((old & (1<<7)) == 0)
		ok = 0;			/* spllo should have reported I set */
	splx(s);
	if(islo())
		ok = 0;			/* splx did not restore the masked state */

	uartputs(", spl ");
	uartputs(ok ? "OK" : "BROKEN");
	uartputs(" (level restored, not assumed)\n");
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

	uartputs("libk: mem/str ");
	uartputs(ok ? "OK" : "BROKEN");

	/*
	 * The Plan 9 fmt engine. %ld and %lux are the formats os/port
	 * uses constantly, and under LP64 they must consume 64 bits.
	 */
	/*
	 * The %lux value is deliberately larger than 2^32.  A %lu that
	 * consumed only 32 bits would still print 0xC0A80101 correctly,
	 * so a test using a value that fits in 32 bits proves nothing
	 * about whether the format is LP64-correct.
	 */
	n = snprint(buf, sizeof buf, "%d %s %lud %lux", 42, "dis",
		(ulong)3232235777UL, (ulong)0x1DEADBEEFUL);
	uartputs(", snprint ");
	if(n > 0 && strcmp(buf, "42 dis 3232235777 1deadbeef") == 0)
		uartputs("OK");
	else{
		uartputs("WRONG: ");
		uartputs(buf);
	}
	uartputs("\n");
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
static void
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

	print("conf: %lud free pages (%ludMB) from %lux to %lux\n",
		conf.npage0, (conf.npage0 * BY2PG) >> 20,
		(ulong)base, (ulong)top);
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

	confinit();
	xinit();

	ok = 1;

	a = xalloc(4096);
	b = xalloc(4096);
	if(a == nil || b == nil)
		ok = 0;
	else{
		if(a == b)
			ok = 0;				/* handed out twice */
		if(memchr(a, 0xFF, 4096) != nil)
			ok = 0;				/* not zeroed */
		if((uintptr)a < conf.base0)
			ok = 0;				/* outside its own bank */
		memset(a, 0xAA, 4096);
		memset(b, 0xBB, 4096);
		if(a[0] != (char)0xAA || b[0] != (char)0xBB)
			ok = 0;				/* they overlap */
		xfree(a);
		xfree(b);
	}

	print("xall: xalloc %s\n", ok ? "OK (distinct, zeroed, in-bank)" : "BROKEN");
}

static void
probefb(void)
{
	Fbinfo fb;

	if(fbinit(&fb) < 0){
		uartputs("fb:   no framebuffer (no display attached?)\n");
		return;
	}

	uartputs("fb:   ");
	uartputd(fb.width);
	uartputs("x");
	uartputd(fb.height);
	uartputs("x");
	uartputd(fb.depth);
	uartputs(" pitch=");
	uartputd(fb.pitch);
	uartputs(" base=");
	uartputx(fb.base);
	uartputs(" size=");
	uartputd(fb.size);
	uartputs("\n");

	/*
	 * Paint something identifiable.  On the 7in panel this is the
	 * first thing that will ever be visible, so make it unambiguous
	 * rather than a single colour that could be a stuck backlight.
	 */
	fbfill(&fb, 0x00101018);
	fbrect(&fb, 0, 0, (int)fb.width, 8, 0x00C03020);
	fbrect(&fb, 20, 40, 120, 80, 0x00FF0000);
	fbrect(&fb, 160, 40, 120, 80, 0x0000FF00);
	fbrect(&fb, 300, 40, 120, 80, 0x000000FF);
	uartputs("fb:   test pattern drawn\n");
}

void
kmain(void)
{
	uartinit();

	uartputs("\nInferNode bare-metal (BCM2837 / Raspberry Pi 3B+)\n");

	uartputs("  exception level: EL");
	uartputc('0' + (int)currentel());
	uartputs("\n  midr_el1:        ");
	uartputx(midr());
	uartputs("\n  mpidr_el1:       ");
	uartputx(mpidr());
	uartputs("\n  console:         PL011 UART0, polled");
	uartputs("\n  types:           ");
	uartputs(typecheck() ? "arm64 u.h OK (LP64, stdarg)" : "TYPE FOUNDATION BROKEN");
	uartputs("\n");

	trapinit();
	uartputs("  vectors:         installed at VBAR_EL1\n\n");

	checktraps();

	probehw();
	startmmu();
	checkunaligned();
	probegpio();
	probearch();
	probelibkern();
	probexalloc();
	probeclock();
	probefb();

	uartputs("\nboot OK\n");

	for(;;)
		__asm__ volatile("wfe");
}
