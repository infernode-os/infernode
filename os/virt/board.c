/*
 * QEMU's `virt` machine: the hooks ../arm64/fns.h asks a board for.
 *
 * virt is not a model of any hardware. It is the machine QEMU invented
 * for guests that do not care what they run on: a GIC, a PL011, a
 * PL031 clock, and thirty-two virtio-mmio slots that hold whatever the
 * command line put there. For this kernel that makes it three things
 * the Raspberry Pi model (-M raspi3b) cannot be:
 *
 *   a machine with a NETWORK CARD and a DISK that are fast and need no
 *   USB stack underneath them, so everything above the driver -- os/ip,
 *   dossrv, 9P, the desktop -- can be exercised in CI at full speed;
 *
 *   a machine with the ARCHITECTURE'S interrupt controller, which is
 *   the Pi 4's and nearly every other board's, written and tested
 *   before any such board is on the bench;
 *
 *   a SECOND machine, which is what finds out whether a line of
 *   os/arm64 is about AArch64 or about the BCM2837. Four hooks were
 *   added to fns.h by this port for the lines that were not.
 *
 * What it is NOT is evidence about the board. Nothing here has timing,
 * a cache, a bus that can NAK or a card that can wear; a fix proved
 * only here has been proved for software. The bcm2837 harness and the
 * acceptance batteries remain what says the Pi works.
 *
 * There is no firmware. QEMU enters the kernel directly, at EL1, with
 * a device tree in x0 and the secondary cores held off; what a board
 * would ask firmware for is asked of the device tree (memory size, the
 * command line, how to make a PSCI call) or of PSCI itself, which QEMU
 * implements in place of the firmware that is not there.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "virtio.h"

char*
boardname(void)
{
	return "QEMU virt";
}

/*
 * PSCI: power state coordination, the standard way an ARM kernel asks
 * whatever is beneath it to start a core, reset, or power off.
 *
 * The call is a trap to the next exception level up, with a function
 * number in x0 and arguments in x1-x3. WHICH trap depends on what is up
 * there: hvc when QEMU plays hypervisor for a guest entered at EL1 (the
 * default), smc when the machine was started with virtualization=on or
 * secure=on and the guest owns EL2. The device tree's /psci node says
 * which, and guessing wrong is an undefined-instruction exception in
 * the middle of SMP bring-up, so it is read and not assumed.
 */
enum
{
	Pscicpuon	= 0xC4000003,	/* SMC64: target mpidr, entry, context */
	Pscioff		= 0x84000008,
	Pscireset	= 0x84000009,
	Psciversion	= 0x84000000,

	Pscisuccess	= 0,
	Pscialreadyon	= -4,
};

static int pscismc;		/* the conduit: 0 hvc, 1 smc */
static int pscifound;

static vlong
psci(u64int fn, u64int a1, u64int a2, u64int a3)
{
	register u64int x0 __asm__("x0") = fn;
	register u64int x1 __asm__("x1") = a1;
	register u64int x2 __asm__("x2") = a2;
	register u64int x3 __asm__("x3") = a3;

	/* SMCCC: the callee may use x4-x17 and must preserve the rest */
	if(pscismc)
		__asm__ volatile("smc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3)
			: "x4","x5","x6","x7","x8","x9","x10","x11","x12",
			  "x13","x14","x15","x16","x17");
	else
		__asm__ volatile("hvc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3)
			: "x4","x5","x6","x7","x8","x9","x10","x11","x12",
			  "x13","x14","x15","x16","x17");
	return (vlong)x0;
}

static char cmdline[1024];

char*
boardcmdline(void)
{
	return cmdline;
}

/*
 * Earliest bring-up, before the MMU: read what the device tree has to
 * say, because everything it says is needed soon. Byte-wise reads
 * throughout (fdt.c) -- memory is Device until mmuinit, and an
 * unaligned load faults.
 */
void
boardprobe(void)
{
	uchar *p;
	uintptr base, size;
	int n, i;

	uartputstr("fdt:  ");
	if(!fdtvalid()){
		uartputstr("NO DEVICE TREE at ");
		uartputx(dtbptr);
		uartputstr(" -- was this image loaded as an ELF? virt passes the tree only to a flat image\n");
		return;
	}
	uartputstr("at ");
	uartputx(dtbptr);
	uartputstr(", ");
	uartputd(fdtsize());
	uartputstr(" bytes");
	if(fdtmemory(&base, &size) == 0){
		uartputstr("; memory ");
		uartputd(size >> 20);
		uartputstr("MB at ");
		uartputx(base);
	}
	uartputstr("\n");

	p = fdtgetprop("psci", "method", &n);
	if(p != nil){
		pscifound = 1;
		pscismc = n >= 3 && p[0] == 's' && p[1] == 'm' && p[2] == 'c';
	}
	uartputstr("psci: ");
	if(pscifound){
		uartputstr(pscismc ? "smc" : "hvc");
		uartputstr(", version ");
		uartputx((u64int)psci(Psciversion, 0, 0, 0));
		uartputstr("\n");
	}else
		uartputstr("NOT IN THE DEVICE TREE -- no secondary cores, no reset\n");

	/* -append "..." arrives as /chosen/bootargs */
	p = fdtgetprop("chosen", "bootargs", &n);
	if(p != nil){
		if(n > (int)sizeof cmdline - 1)
			n = sizeof cmdline - 1;
		for(i = 0; i < n && p[i] != 0; i++)
			cmdline[i] = p[i];
		cmdline[i] = 0;
	}
}

/*
 * The clock that knows what day it is: a PL031, which QEMU sets from
 * the host. One register matters -- the data register at offset 0 is
 * seconds since 1970 -- and it needs no initialisation to read.
 *
 * The board has no such thing and boots in 1970 until something on the
 * network tells it otherwise. Here the kernel's time of day is right
 * from the first process, which is what lets certificate checks and
 * file times be tested without a time server in the loop.
 */
extern ulong boottime;		/* ../port/devcons.c */

ulong
rtcseconds(void)
{
	return *(volatile u32int*)(uintptr)RTCREGS;
}

/*
 * After the allocators and the process table, before the devices'
 * resets: find out what QEMU's command line put in the virtio slots,
 * and bring up the one device the kernel itself depends on. The pool
 * in os/port/random.c is primed from hwrandom() when #c initialises,
 * which is soon.
 */
void
boardioprobe(void)
{
	ulong s;

	virtioscan();
	rnginit();

	/*
	 * Two clocks want telling, because this kernel has two: tod.c's,
	 * in nanoseconds, and devcons.c's boottime, which is what
	 * /dev/time and therefore date(1) read. Setting only the first
	 * printed "time of day set" over a machine that then said 1970,
	 * which the harness's date check caught.
	 */
	s = rtcseconds();
	if(s != 0){
		todset((vlong)s * 1000000000LL, 0, 0);
		boottime = s - TK2SEC(MACHP(0)->ticks);
		print("rtc:  PL031 says %lud seconds since the epoch; time of day set\n", s);
	}else
		print("rtc:  PL031 reads zero; time of day not set\n");
}

/*
 * The board cross-checks CNTFRQ_EL0 against a clock whose rate is fixed
 * in silicon, because firmware writes CNTFRQ and can write it wrong.
 * Here QEMU supplies the counter AND the number, with no firmware
 * between them; there is nothing independent to check against that is
 * finer than the RTC's whole seconds, and a two-second pause on every
 * boot to confirm that an emulator agrees with itself is a poor trade.
 * The rate is printed by probeclock; a wrong one would show there as a
 * tick count that does not match.
 */
void
boardclockcheck(void)
{
}

/* no boot watchdog: nothing A/B-boots this machine. See tryboot below. */
void
boardbootwatchdog(void)
{
}

void
boardwatchdogtick(void)
{
}

void
boardwatchdogpoll(void)
{
}

void
boardbooted(void)
{
}

int
boardcandidate(void)
{
	return 0;
}

/*
 * Release the secondary cores.
 *
 * QEMU holds them powered off -- they have executed nothing, which is
 * tidier than the board's spin table -- and CPU_ON starts one at a
 * given address, at the caller's exception level, MMU off, with the
 * third argument in x0. The target is named by MPIDR affinity, which
 * on virt is simply the core number for the first eight.
 *
 * The entry is l.S's secentry, the same one the board's spin table
 * jumps to: it works out which core it is from mpidr and takes its
 * stack and Mach from the smpboot slot launchsmp filled in, so the
 * context argument has nothing to carry.
 *
 * A core that is not there (-smp 2 with MAXMACH 4) fails here with
 * INVALID_PARAMETERS, and launchsmp then reports it as not answering;
 * said once here with the reason, since "did not answer" alone reads
 * like a hang.
 */
void
boardstartcpus(uintptr entry)
{
	vlong r;
	int i;

	if(!pscifound)
		return;
	for(i = 1; i < MAXMACH; i++){
		r = psci(Pscicpuon, i, entry, 0);
		if(r != Pscisuccess && r != Pscialreadyon)
			print("psci: CPU_ON cpu%d refused (%lld) -- is -smp less than %d?\n",
				i, r, MAXMACH);
	}
}

/* a GIC can be asked to interrupt with no device's help: ../arm64/gic.c */
void
boardintrprobe(void)
{
	gicintrprobe();
}

/* nothing in this directory needs to wait for exclusives */
void
boardlockon(void)
{
}

/* no USB host controller on this machine; #u is present and empty */
void
boardusblink(void)
{
}

void
boardreboot(void)
{
	if(pscifound)
		psci(Pscireset, 0, 0, 0);
	uartputstr("boardreboot: PSCI SYSTEM_RESET returned; halting\n");
	for(;;)
		__asm__ volatile("wfi");
}

/*
 * With -no-reboot a reset ends QEMU, and so does this; without it this
 * is the only way a guest can end the emulator, which is what a test
 * harness wants at the end of a run.
 */
void
boardpoweroff(void)
{
	if(pscifound)
		psci(Pscioff, 0, 0, 0);
	for(;;)
		__asm__ volatile("wfi");
}

/*
 * There is no A/B boot here: the "card" is a file QEMU was pointed at
 * and the kernel is another, and trying a new kernel is starting QEMU
 * again. A tryboot request is an ordinary reset.
 */
void
boardtryboot(void)
{
	boardreboot();
}

/*
 * The way back to a serial loader, on the board. There is no loader
 * here and no need of one: the kernel arrives by -kernel.
 */
void
serialrecover(void)
{
}

/*
 * The board asks its firmware for the address the firmware derived from
 * the serial number, because its Ethernet chip has none of its own. A
 * virtio network card carries its address in its configuration space,
 * where the driver reads it; nobody needs to be told.
 */
int
getmacaddr(uchar *mac)
{
	USED(mac);
	return -1;
}

/*
 * The display, if QEMU was given one, and then the things that point
 * at it. The console moves onto it exactly as it does on the board:
 * fbcons draws the kernel's text until something binds #i, and the
 * serial line carries it regardless.
 */
static Fbinfo fb;

void
boardfbprobe(void)
{
	if(ramfbinit(&fb) < 0){
		fb.base = 0;
		inputvirtioinit();	/* a keyboard is still a keyboard */
		return;
	}
	print("fb:   ramfb %udx%udx%ud at %#p\n", fb.width, fb.height, fb.depth, (void*)fb.base);

	if(fbconsinit(&fb) == 0){
		screenputs = fbconsputs;
		consoleprint = 1;
	}
	pointerbounds((int)fb.width, (int)fb.height);
	inputvirtioinit();
}

Fbinfo*
boardfb(void)
{
	if(fb.base == 0)
		return nil;
	return &fb;
}

/* a second display cannot be plugged into this machine */
void
displaywatch(void *a)
{
	USED(a);
}

/*
 * The devices that are found late: after devether's reset has made its
 * instances, before kmain binds #S. On the Pi these are the card and the
 * radio; here, the disk and the network card.
 */
void
boarddevprobe(void)
{
	blkvirtioinit();
	ethervirtiolink();
	pciecamlink();
}
