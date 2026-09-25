/*
 * Microchip PolarFire SoC: the hooks ../riscv64/fns.h asks a board for.
 *
 * The SoC of the BeagleV-Fire and the Icicle Kit: four U54 application
 * harts (1-4) that run this kernel, an E51 monitor hart (0) that the
 * firmware keeps, and the MSS peripherals at the same addresses on
 * every board (io.h). The firmware is the Hart Software Services, which
 * runs on the E51 and gives the U54s OpenSBI, entering the kernel in
 * S-mode with the board's device tree -- exactly the contract QEMU's
 * -bios gives on the virt machine, so ../riscv64 needs nothing new.
 *
 * Under QEMU the machine is microchip-icicle-kit, which models the MSS
 * but not the FPGA fabric, and has no device tree of its own:
 * qemu-icicle.dts in this directory describes it, and the harness
 * passes it with -dtb.
 *
 * The card is the Cadence SD4HC (sd4hc.c) under the Pis' card protocol
 * (../bcm/sdmmc.c). What is not here yet: the Cadence GEM Ethernet MAC
 * and the system controller's TRNG service for entropy -- until then,
 * loopback networking and a loud warning that there is no entropy
 * source.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

static char cmdline[1024];
static uvlong timebase;
static char model[128];

char*
boardname(void)
{
	if(model[0] != 0)
		return model;
	return "Microchip PolarFire SoC";
}

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
 * The device tree's root node, whose "model" names the board: it is
 * not a depth-2 node, which is all fdtgetprop looks at, so find it by
 * walking the properties that come before the first child.
 */
static void
fdtmodel(void)
{
	uchar *base, *p, *end, *strs, *data;
	u32int tok, len, nameoff;
	int depth, n, i;

	if(!fdtvalid())
		return;
	base = (uchar*)dtbptr;
	p = base + be32(base + 8);
	end = p + be32(base + 36);
	strs = base + be32(base + 12);
	depth = 0;
	while(p + 4 <= end){
		tok = be32(p);
		p += 4;
		if(tok == 1){		/* begin node */
			if(++depth > 1)
				return;
			while(*p != 0)
				p++;
			p = (uchar*)(((uintptr)p + 4) & ~3);
		}else if(tok == 3){	/* property */
			len = be32(p);
			nameoff = be32(p + 4);
			data = p + 8;
			p = data + ((len + 3) & ~3);
			if(depth == 1 && strcmp((char*)strs + nameoff, "model") == 0){
				n = len < sizeof model - 1 ? len : sizeof model - 1;
				for(i = 0; i < n && data[i] != 0; i++)
					model[i] = data[i];
				model[i] = 0;
				return;
			}
		}else if(tok == 4)	/* nop */
			;
		else
			return;
	}
}

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
	fdtmodel();
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
	if(model[0] != 0){
		uartputstr("board: ");
		uartputstr(model);
		uartputstr("\n");
	}

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

/* 1 MHz on every PolarFire SoC (the RTC reference feeds mtime) */
uvlong
boardtimebase(void)
{
	return timebase != 0 ? timebase : 1000000;
}

void
boardmemory(uintptr *base, uintptr *size)
{
	if(fdtmemory(base, size) < 0){
		*base = RAMZERO;
		*size = 1024*1024*1024;
	}
}

/*
 * The PLIC's contexts are "M" for the E51 (context 0) and "M,S" for
 * each U54: hart h's S-mode context is 2h.
 */
int
boardplicctx(ulong hartid)
{
	if(hartid == 0)
		return -1;
	return 2*hartid;
}

int
boardharts(ulong *ids, int max)
{
	return fdtcpus(ids, max);
}

/*
 * The MSS RTC keeps time only once software has set it; nothing does
 * yet, so the kernel starts in 1970 until the network says otherwise.
 */
ulong
rtcseconds(void)
{
	return 0;
}

void
boardioprobe(void)
{
	rnginit();
	print("rtc:  not set (the MSS RTC is not read yet)\n");
}

void
boardclockcheck(void)
{
}

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

void
boardreboot(void)
{
	sbireset(1);
	uartputstr("boardreboot: SBI system reset returned; halting\n");
	for(;;)
		idlewfi();
}

void
boardpoweroff(void)
{
	sbireset(0);
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

int
getmacaddr(uchar *mac)
{
	USED(mac);
	return -1;
}

void
boardfbprobe(void)
{
}

Fbinfo*
boardfb(void)
{
	return nil;
}

void
fbfill(Fbinfo *fb, u32int colour)
{
	USED(fb);
	USED(colour);
}

int
fbdisplay(u32int disp)
{
	USED(disp);
	return -1;
}

int
fbvoffset(u32int x, u32int y)
{
	USED(x);
	USED(y);
	return -1;
}

void
displaywatch(void *a)
{
	USED(a);
}

/* the devices found late: the card */
void
boarddevprobe(void)
{
	emmcinit();
}
