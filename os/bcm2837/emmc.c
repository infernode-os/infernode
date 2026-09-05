/*
 * The Arasan SDHCI controller, as an SDio backend.
 *
 * This is where the SD card protocol used to live. It moved to
 * sdmmc.c when the card moved to the SDHOST controller (sdhost.c says
 * why: the CYW43455 WiFi chip can only be reached through THIS
 * controller, so the card had to give it up). What is left here is
 * the register half only -- reset, clock, one command, one block --
 * and it is kept, buildable with -DSDCARD_ARASAN, for two reasons:
 * the WiFi work will need an Arasan command path, and a working card
 * driver on the other controller is what makes a SDHOST failure
 * bisectable rather than a mystery.
 *
 * The register layout is SDHCI's at a non-standard spacing, which is
 * why io.h names the offsets rather than borrowing a generic header.
 *
 * Polled, not interrupt-driven, like everything else on this board's
 * slow paths: the interrupt bits latch whether or not delivery is
 * enabled, so polling them is the same information a handler would
 * get, and a polled driver cannot lose a wakeup.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"board.h"

enum
{
	Initfreq	= 400000,	/* identification, per the spec */
	Corefallback	= 41666667,	/* the usual base clock if unasked */

	/*
	 * How long to wait, in microseconds. Bounded, because this runs
	 * during boot and a board that stops here stops before there is
	 * a console to ask what happened.
	 */
	Cmdwait		= 200000,	/* 200ms for a command to complete */
};

static u32int
emmcrd(int off)
{
	return *(volatile u32int*)(uintptr)(EMMCREGS + off);
}

static void
emmcwr(int off, u32int v)
{
	*(volatile u32int*)(uintptr)(EMMCREGS + off) = v;
	coherence();
}

/*
 * Wait for status bits to clear, bounded. Returns -1 on timeout.
 */
static int
emmcwaitstatus(u32int mask)
{
	int i;

	for(i = 0; i < Cmdwait; i += 10){
		if((emmcrd(Emmcstatus) & mask) == 0)
			return 0;
		microdelay(10);
	}
	return -1;
}

/*
 * Wait for an interrupt-status bit, bounded, WITHOUT taking an
 * interrupt. Returns -1 on timeout or if the controller reports an
 * error, and clears whatever it saw so the next command starts from a
 * known state.
 */
static int
emmcwaitintr(u32int mask)
{
	int i;
	u32int intr;

	for(i = 0; i < Cmdwait; i += 10){
		intr = emmcrd(Emmcinterrupt);
		if(intr & Interrorbit){
			emmcwr(Emmcinterrupt, intr);
			return -1;
		}
		if(intr & mask){
			emmcwr(Emmcinterrupt, intr & mask);
			return 0;
		}
		microdelay(10);
	}
	return -1;
}

/*
 * Set the card clock.
 *
 * The divider is the awkward part: this controller wants the value in
 * the SDHCI "8-bit divided clock" form split across two fields, and the
 * base clock is whatever the firmware left it at rather than something
 * fixed, so it is asked for rather than assumed.
 */
static int
emmcsetclock(u32int hz)
{
	u32int base, div, c1;
	int i;

	base = mboxclockrate(Clkemmc);
	if(base == 0)
		base = Corefallback;

	for(div = 1; div < 0x400; div++)
		if(base / (div * 2) <= hz)
			break;

	c1 = emmcrd(Emmccontrol1);
	c1 &= ~Clken;
	emmcwr(Emmccontrol1, c1);
	microdelay(10);

	c1 &= ~0x0000FFE0;			/* clear both divider fields */
	c1 |= (div & 0xFF) << 8;
	c1 |= ((div >> 8) & 0x3) << 6;
	c1 |= Clkintlen;
	c1 |= 0xE << 16;			/* data timeout, the maximum */
	emmcwr(Emmccontrol1, c1);

	for(i = 0; i < Cmdwait; i += 10){
		if(emmcrd(Emmccontrol1) & Clkstable)
			break;
		microdelay(10);
	}
	if((emmcrd(Emmccontrol1) & Clkstable) == 0)
		return -1;

	emmcwr(Emmccontrol1, emmcrd(Emmccontrol1) | Clken);
	microdelay(10);
	return 0;
}

/*
 * Reset the host controller.
 *
 * The firmware has already used this controller to load the kernel,
 * so it is not in its power-on state: it has a clock running, a card
 * selected, and a block length set. Starting from whatever it left is
 * how a driver works on one boot and not the next.
 *
 * The pins are NOT touched. The card reaches this controller through
 * GPIO 48-53 at ALT3, which is where start.elf leaves them on the
 * board; under QEMU the same routing is function 0, the reset value,
 * and ALT3 means nothing to its mux. Both are "as found", so the one
 * setting that is right in both places is the one already there.
 * They are claimed so that #G cannot move them from under the card.
 */
static int
arasaninit(void)
{
	int pin, i;

	for(pin = 48; pin <= 53; pin++)
		gpioclaim(pin, "emmc");

	emmcwr(Emmccontrol0, 0);
	emmcwr(Emmccontrol1, emmcrd(Emmccontrol1) | Srsthc);
	for(i = 0; i < Cmdwait; i += 10){
		if((emmcrd(Emmccontrol1) & (Srsthc|Srstcmd|Srstdata)) == 0)
			break;
		microdelay(10);
	}
	if(emmcrd(Emmccontrol1) & Srsthc){
		uartputstr("emmc: controller will not reset\n");
		return -1;
	}
	return 0;
}

static void
arasanenable(void)
{
	if(emmcsetclock(Initfreq) < 0)
		uartputstr("emmc: no clock\n");
	emmcwr(Emmcirpten, 0);
	emmcwr(Emmcirptmask, ~0);	/* latch everything; we poll it */
	emmcwr(Emmcinterrupt, ~0);
}

/*
 * Issue one command.
 *
 * The 136-bit response is stored the SDHCI way, with the CRC byte
 * dropped: RESP3 holds bits 127:104, RESP2 103:72, RESP1 71:40 and
 * RESP0 39:8. The card layer wants the raw layout SDHOST produces,
 * RESP3 = bits 127:96, so it is shifted into that form here, the way
 * Miller's emmc.c does it -- the bit numbers in the specification
 * then mean the same thing whichever controller answered.
 */
static int
arasancmd(int idx, u32int arg, int flags, u32int *resp)
{
	u32int cmd, r0, r1, r2, r3;

	cmd = (u32int)idx << 24;
	switch(flags & Rmask){
	case Rnone:
		cmd |= Cmdrspnone;
		break;
	case R48:
		cmd |= Cmdrsp48;
		if((flags & Rnocrc) == 0)
			cmd |= Cmdcrcchk | Cmdidxchk;
		break;
	case R48busy:
		cmd |= Cmdrsp48busy | Cmdcrcchk | Cmdidxchk;
		break;
	case R136:
		cmd |= Cmdrsp136 | Cmdcrcchk;
		break;
	}
	if(flags & Dread)
		cmd |= Cmdisdata | Tmdatdirread;
	if(flags & Dwrite)
		cmd |= Cmdisdata;

	if(emmcwaitstatus(Cmdinhibit) < 0)
		return -1;
	if((flags & (Dread|Dwrite)) || (flags & Rmask) == R48busy)
		if(emmcwaitstatus(Datinhibit) < 0)
			return -1;

	emmcwr(Emmcinterrupt, emmcrd(Emmcinterrupt));	/* clear stale bits */
	emmcwr(Emmcarg1, arg);
	emmcwr(Emmccmdtm, cmd);

	if(emmcwaitintr(Cmddone) < 0)
		return -1;

	if(resp != nil){
		resp[0] = resp[1] = resp[2] = resp[3] = 0;
		switch(flags & Rmask){
		case R136:
			r0 = emmcrd(Emmcresp0);
			r1 = emmcrd(Emmcresp1);
			r2 = emmcrd(Emmcresp2);
			r3 = emmcrd(Emmcresp3);
			resp[0] = r0 << 8;
			resp[1] = r0 >> 24 | r1 << 8;
			resp[2] = r1 >> 24 | r2 << 8;
			resp[3] = r2 >> 24 | r3 << 8;
			break;
		case R48:
		case R48busy:
			resp[0] = emmcrd(Emmcresp0);
			break;
		}
	}
	return 0;
}

static void
arasanbus(int width, int hz)
{
	u32int c0;

	if(width == 4 || width == 1){
		c0 = emmcrd(Emmccontrol0) & ~Hctldwidth4;
		if(width == 4)
			c0 |= Hctldwidth4;
		emmcwr(Emmccontrol0, c0);
	}
	if(hz > 0)
		if(emmcsetclock(hz) < 0)
			uartputstr("emmc: cannot set the clock\n");
}

static void
arasaniosetup(int write, int bsize, int bcount)
{
	USED(write);
	emmcwr(Emmcblksizecnt, (bcount << 16) | bsize);
}

/*
 * Move the data of a command already issued with Dread or Dwrite:
 * wait for the controller to say the buffer is ready, move the words,
 * wait for it to say the transfer is over.
 */
static int
arasanio(int write, void *a, int len)
{
	u32int *p;
	int i;

	if(emmcwaitintr(write? Writerdy : Readrdy) < 0)
		return -1;

	p = a;
	for(i = 0; i < len/4; i++){
		if(write)
			emmcwr(Emmcdata, p[i]);
		else
			p[i] = emmcrd(Emmcdata);
	}

	if(emmcwaitintr(Datadone) < 0)
		return -1;
	return 0;
}

SDio emmcio = {
	"emmc",
	arasaninit,
	arasanenable,
	arasancmd,
	arasanbus,
	arasaniosetup,
	arasanio,
};
