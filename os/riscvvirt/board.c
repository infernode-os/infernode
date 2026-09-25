/*
 * QEMU's RISC-V `virt' machine: the hooks ../riscv64/fns.h asks a
 * board for.
 *
 * The RISC-V counterpart of ../virt, and there for the same reasons
 * (../virt/board.c): a machine with a network card and a disk that need
 * no USB stack, so everything above the drivers can be exercised in CI
 * at full speed; and a second machine for os/riscv64, so that what is
 * RISC-V's and what is the PolarFire's (../mpfs) can be told apart.
 * Its virtio devices are the same virtio-mmio transport arm64's virt
 * has, and the drivers are the same files (../virtio).
 *
 * The firmware is OpenSBI (QEMU's -bios default), which enters the
 * kernel in S-mode with a device tree; what a board would ask firmware
 * for is asked of the tree or of SBI.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "../virtio/virtio.h"

char*
boardname(void)
{
	return "QEMU riscv64 virt";
}

static char cmdline[1024];
static uvlong timebase;

char*
boardcmdline(void)
{
	return cmdline;
}

static u32int
be32(uchar *p)
{
	return ((u32int)p[0]<<24) | ((u32int)p[1]<<16) | ((u32int)p[2]<<8) | p[3];
}

/*
 * Before anything else: what the device tree says. Byte-wise reads
 * (fdt.c): nothing here may assume alignment.
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
		uartputstr("\n");
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

	p = fdtgetprop("cpus", "timebase-frequency", &n);
	if(p != nil && n >= 4)
		timebase = be32(p);
	uartputstr("time: ");
	uartputd(timebase);
	uartputstr(" Hz timebase\n");

	p = fdtgetprop("chosen", "bootargs", &n);
	if(p != nil){
		if(n > (int)sizeof cmdline - 1)
			n = sizeof cmdline - 1;
		for(i = 0; i < n && p[i] != 0; i++)
			cmdline[i] = p[i];
		cmdline[i] = 0;
	}
}

uvlong
boardtimebase(void)
{
	return timebase != 0 ? timebase : 10000000;
}

void
boardmemory(uintptr *base, uintptr *size)
{
	if(fdtmemory(base, size) < 0){
		*base = RAMZERO;
		*size = 128*1024*1024;
	}
}

/* every hart has an M and an S context: S is the odd one */
int
boardplicctx(ulong hartid)
{
	return 2*hartid + 1;
}

int
boardharts(ulong *ids, int max)
{
	return fdtcpus(ids, max);
}

/*
 * The goldfish RTC: nanoseconds since the epoch, which QEMU takes from
 * the host. Reading the low word latches the high one.
 */
extern ulong boottime;		/* ../port/devcons.c */

ulong
rtcseconds(void)
{
	uvlong ns;
	u32int lo, hi;

	lo = *(volatile u32int*)(uintptr)(RTCREGS + 0x00);
	hi = *(volatile u32int*)(uintptr)(RTCREGS + 0x04);
	ns = ((uvlong)hi << 32) | lo;
	return ns / 1000000000ULL;
}

void
boardioprobe(void)
{
	ulong s;

	virtioscan();
	rnginit();

	s = rtcseconds();
	if(s != 0){
		todset((vlong)s * 1000000000LL, 0, 0);
		boottime = s - TK2SEC(MACHP(0)->ticks);
		print("rtc:  goldfish says %lud seconds since the epoch; time of day set\n", s);
	}else
		print("rtc:  reads zero; time of day not set\n");
}

void
boardclockcheck(void)
{
}

/* no boot watchdog and no A/B boot: see ../virt/board.c */
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

/* harts are started by launchsmp through SBI; nothing board-specific */
void
boardstartcpus(uintptr entry)
{
	USED(entry);
}

void
boardintrprobe(void)
{
	plicintrprobe();
}

void
boardlockon(void)
{
}

void
boardusblink(void)
{
}

/*
 * Reset and power-off: SBI's system reset if the firmware has it, and
 * the sifive,test device's magic words if not.
 */
void
boardreboot(void)
{
	sbireset(1);
	*(volatile u32int*)(uintptr)TESTREGS = 0x7777;
	uartputstr("boardreboot: reset returned; halting\n");
	for(;;)
		idlewfi();
}

void
boardpoweroff(void)
{
	sbireset(0);
	*(volatile u32int*)(uintptr)TESTREGS = 0x5555;
	for(;;)
		idlewfi();
}

void
boardtryboot(void)
{
	boardreboot();
}

void
serialrecover(void)
{
}

/* a virtio network card carries its own address */
int
getmacaddr(uchar *mac)
{
	USED(mac);
	return -1;
}

/*
 * The display, if QEMU was given one (-device ramfb), and then the
 * things that point at it: exactly ../virt/board.c's. The console moves
 * onto the screen; the serial line carries it regardless.
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

void
boarddevprobe(void)
{
	blkvirtioinit();
	ethervirtiolink();
}
