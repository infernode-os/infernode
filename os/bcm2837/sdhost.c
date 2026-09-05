/*
 * The BCM2835 SDHOST controller: the SD card's controller from now on.
 *
 * Derived from Richard Miller's sdhost.c in Plan 9 (sys/src/9/bcm,
 * Copyright © 2016 Richard Miller <r.miller@acm.org>, MIT), with the
 * register semantics cross-checked against 9front's sdhost.c and the
 * Linux bcm2835 driver. Reduced to what a polled block driver needs:
 * no DMA engine (this tree has none) and no interrupt, so the FIFO is
 * moved by the CPU a burst at a time and every wait is a bounded poll.
 *
 * Why this controller and not the Arasan the firmware booted from.
 *
 * The SoC has two SD controllers and the Pi 3B+ has two SD devices:
 * the card slot on GPIO 48-53 and the CYW43455 WiFi chip on GPIO
 * 34-39, which speaks SDIO. The Arasan is the only one that can be
 * routed to the WiFi pins, so if the card stays on it there is no
 * controller left for the radio. Linux makes the same choice on this
 * board -- the card on SDHOST, the Arasan for the radio -- so the
 * silicon path is well trodden even though ours has not walked it.
 *
 * Which controller sees the card is a GPIO question. The pin mux
 * connects pins 48-53 to SDHOST at ALT0 and to the Arasan at ALT3, and
 * start.elf leaves them at ALT3 because it loaded the kernel through
 * the Arasan. Writing ALT0 here is what moves the card; nothing else
 * in this file would have any effect without it.
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
	Corefallback	= 250000000,	/* if the mailbox will not say */
	Initfreq	= 400000,	/* identification, per the spec */

	Stoptransmission= 12,

	/*
	 * FIFO thresholds, in words. Four rather than anything larger:
	 * "limit fifo usage due to silicon bug" is the Linux driver's
	 * comment and Miller kept the value. The burst is what one
	 * poll of the fill count moves; eight is Linux's PIO burst and
	 * half the FIFO, so a read never waits for more than it holds.
	 */
	Fifothreshold	= 4,
	Fifoburst	= 8,

	/*
	 * How long to wait, in microseconds, and why it is bounded.
	 *
	 * Every wait here has a limit for the reason emmc.c gives: this
	 * runs during boot, and a card that never answers must produce
	 * an error rather than a kernel that stops before there is a
	 * console to ask what happened.
	 */
	Cmdwait		= 200000,	/* a command to complete */
	Busywait	= 1000000,	/* the card to leave R1b busy */
	Datawait	= 500000,	/* the FIFO to fill or drain */
	Pollstep	= 10,
};

static struct
{
	u32int	core;		/* the clock the divider divides */
	int	sdclk;		/* what the card is being clocked at */
} sdhost;

static u32int
rd(int off)
{
	return *(volatile u32int*)(uintptr)(SDHOSTREGS + off);
}

static void
wr(int off, u32int v)
{
	*(volatile u32int*)(uintptr)(SDHOSTREGS + off) = v;
	coherence();
}

static int
fifofill(void)
{
	return (rd(Sdedm) >> Edmfifoshift) & Edmfifomask;
}

static int
fsm(void)
{
	return rd(Sdedm) & Edmfsmmask;
}

/*
 * Set the card clock: sdclk = core/(div+2), rounded so that the result
 * never EXCEEDS what was asked for. Overclocking a card does not fail,
 * it corrupts, which is the worse of the two.
 *
 * This is Linux's formula rather than Miller's. His rounding test
 * compares the wrong pair of values (core/freq against freq), which
 * happens to be harmless at the three frequencies he uses and would
 * not be at others.
 *
 * The data timeout is set alongside, as a count of SD clocks: half a
 * second's worth, so it scales with the clock rather than becoming a
 * different duration at every speed.
 */
static void
sdhostclock(int hz)
{
	u32int div;

	div = sdhost.core / hz;
	if(div < 2)
		div = 2;
	if(sdhost.core / div > (u32int)hz)
		div++;
	div -= 2;
	if(div > Sdcdivmax)
		div = Sdcdivmax;
	sdhost.sdclk = sdhost.core / (div + 2);
	wr(Sdcdiv, div);
	wr(Sdtout, sdhost.sdclk / 2);
}

/*
 * Take the pins, find the clock, and put the controller in a known
 * state. Returns 0: the controller is on the SoC, so it cannot be
 * absent, and whether there is a card behind it is the card layer's
 * question.
 */
static int
sdhostinit(void)
{
	u32int edm;
	int pin;

	/*
	 * ALT0 on all six pins is what connects the card to this
	 * controller. Under QEMU it is also what reparents the card
	 * device from the SDHCI model to the SDHOST model, and it does
	 * so only when all six agree -- so the loop must complete
	 * before anything below touches a register.
	 */
	for(pin = 48; pin <= 53; pin++){
		gpiofunc(pin, Gpioalt0);
		gpioclaim(pin, "sdhost");
	}

	/*
	 * SDHOST is clocked from the VPU core clock, which the firmware
	 * sets and may scale, so it is asked for rather than assumed.
	 * The fallback is the Pi 3's nominal 250MHz: a divider computed
	 * from a rate that is too LOW overclocks the card, so if the
	 * mailbox is silent this errs towards the slower reading.
	 */
	sdhost.core = mboxclockrate(Clkcore);
	if(sdhost.core == 0){
		sdhost.core = Corefallback;
		uartputstr("sdhost: mailbox gave no core clock, assuming 250MHz\n");
	}

	/*
	 * Reset, register by register: this controller has no reset
	 * bit. The order is Linux's, which is the one the silicon has
	 * been through most.
	 */
	wr(Sdvdd, 0);
	wr(Sdcmd, 0);
	wr(Sdarg, 0);
	wr(Sdtout, 0xF00000);
	wr(Sdcdiv, 0);
	wr(Sdhsts, Hstall);
	wr(Sdhcfg, 0);
	wr(Sdhbct, 0);
	wr(Sdhblc, 0);

	edm = rd(Sdedm);
	edm &= ~((u32int)Edmthreshmask << Edmrdthreshshift);
	edm &= ~((u32int)Edmthreshmask << Edmwrthreshshift);
	edm |= (u32int)Fifothreshold << Edmrdthreshshift;
	edm |= (u32int)Fifothreshold << Edmwrthreshshift;
	wr(Sdedm, edm);
	microdelay(20);
	return 0;
}

/*
 * Power on and clock for identification.
 *
 * Hcfgbusyinten is set even though no interrupt is ever taken. It is
 * not merely an enable for delivery: the BUSY status bit that an R1b
 * command completes with is only LATCHED when it is set, in the
 * datasheet's controller and in QEMU's model of it alike. Without it
 * every CMD7 and CMD12 waits out its full bound and the driver looks
 * like it has a slow card.
 */
static void
sdhostenable(void)
{
	wr(Sdvdd, 1);
	microdelay(10000);
	wr(Sdhcfg, Hcfgintbuswide | Hcfgslowcard | Hcfgbusyinten);
	sdhostclock(Initfreq);
}

/*
 * Issue one command and collect its response.
 */
static int
sdhostcmd(int idx, u32int arg, int flags, u32int *resp)
{
	u32int c, v, sts;
	int i, state;

	/*
	 * A state machine still in a data state means the previous
	 * transfer never finished, and a new command on top of it
	 * would hang rather than fail. CMD12 is the exception because
	 * it is how a transfer is ended.
	 */
	state = fsm();
	if(state > Edmfsmread && idx != Stoptransmission){
		uartputstr("sdhost: previous command stuck, fsm ");
		uartputd(state);
		uartputstr("\n");
		return -1;
	}

	c = (idx & Cmdindexmask) | Cmdstart;
	switch(flags & Rmask){
	case Rnone:
		c |= Cmdnoresp;
		break;
	case R136:
		c |= Cmdlongresp;
		break;
	case R48busy:
		c |= Cmdbusywait;
		break;
	}
	if(flags & Dread)
		c |= Cmdcard2host;
	if(flags & Dwrite)
		c |= Cmdhost2card;

	/* stale status, including a previous command's busy completion */
	wr(Sdhsts, Hsterrors | Hstdataflag | Hstbusyint | Hstblkint);

	wr(Sdarg, arg);
	wr(Sdcmd, c);

	v = 0;
	for(i = 0; i < Cmdwait; i += Pollstep){
		v = rd(Sdcmd);
		if((v & Cmdstart) == 0)
			break;
		microdelay(Pollstep);
	}
	if(v & Cmdstart){
		uartputstr("sdhost: cmd ");
		uartputd(idx);
		uartputstr(" never completed\n");
		return -1;
	}
	sts = rd(Sdhsts);
	if((v & Cmdfailed) || (sts & Hsterrors)){
		wr(Sdhsts, sts & Hsterrors);
		/*
		 * A bare command timeout is what an empty slot looks
		 * like, and the card layer probes for one deliberately,
		 * so it is reported by return value rather than noise.
		 */
		if((sts & Hsterrors) != Hstcmdtimeout){
			uartputstr("sdhost: cmd ");
			uartputd(idx);
			uartputstr(" failed, status ");
			uartputx(sts);
			uartputstr("\n");
		}
		return -1;
	}

	if(resp != nil){
		resp[0] = resp[1] = resp[2] = resp[3] = 0;
		switch(flags & Rmask){
		case R136:
			resp[0] = rd(Sdrsp0);
			resp[1] = rd(Sdrsp1);
			resp[2] = rd(Sdrsp2);
			resp[3] = rd(Sdrsp3);
			break;
		case R48:
		case R48busy:
			resp[0] = rd(Sdrsp0);
			break;
		}
	}

	/*
	 * R1b: the command has been answered but the card is holding
	 * DAT0 low while it works. The controller says when that ends
	 * -- see sdhostenable for what makes it say so.
	 */
	if((flags & Rmask) == R48busy){
		for(i = 0; i < Busywait; i += Pollstep){
			if(rd(Sdhsts) & Hstbusyint)
				break;
			microdelay(Pollstep);
		}
		if((rd(Sdhsts) & Hstbusyint) == 0){
			uartputstr("sdhost: cmd ");
			uartputd(idx);
			uartputstr(": card stayed busy\n");
			return -1;
		}
		wr(Sdhsts, Hstbusyint);
	}
	return 0;
}

/*
 * The bus as the card layer negotiated it: width once the card has
 * agreed to it with ACMD6, clock once identification is over.
 */
static void
sdhostbus(int width, int hz)
{
	if(width == 4)
		wr(Sdhcfg, rd(Sdhcfg) | Hcfgextbus4);
	else if(width == 1)
		wr(Sdhcfg, rd(Sdhcfg) & ~Hcfgextbus4);
	if(hz > 0)
		sdhostclock(hz);
}

/*
 * Size first, count second: writing the count is what arms the
 * transfer, and it is armed with whatever size it finds.
 */
static void
sdhostiosetup(int write, int bsize, int bcount)
{
	USED(write);
	wr(Sdhbct, bsize);
	wr(Sdhblc, bcount);
}

/*
 * Wait for the FIFO to hold at least n words (reading) or have room
 * for n (writing). Returns -1 if it never does.
 */
static int
fifowait(int write, int n)
{
	int i, have;

	for(i = 0; i < Datawait; i += Pollstep){
		have = fifofill();
		if(write)
			have = Sdfifowords - have;
		if(have >= n)
			return 0;
		microdelay(Pollstep);
	}
	return -1;
}

/*
 * Move the data of a command already issued with Dread or Dwrite.
 *
 * A burst at a time: read the fill count once, move up to Fifoburst
 * words, read it again. Reading the count before EVERY word would
 * work and would double the register traffic for no information.
 * The card and the state machine run on their own clock, so the
 * count is a snapshot and the burst never exceeds what it reported.
 */
static int
sdhostdata(int write, void *a, int len)
{
	u32int *p, sts;
	int words, n, i, state;

	p = a;
	words = len / 4;
	while(words > 0){
		n = words;
		if(n > Fifoburst)
			n = Fifoburst;
		if(fifowait(write, n) < 0){
			uartputstr(write? "sdhost: FIFO never drained, fsm "
				: "sdhost: FIFO never filled, fsm ");
			uartputd(fsm());
			uartputstr(" status ");
			uartputx(rd(Sdhsts));
			uartputstr("\n");
			wr(Sdhsts, Hsterrors | Hstdataflag);
			return -1;
		}
		for(i = 0; i < n; i++){
			if(write)
				wr(Sddata, *p++);
			else
				*p++ = rd(Sddata);
		}
		words -= n;
	}

	/*
	 * The words have moved; the transfer has not necessarily
	 * ended. The CRC is exchanged after the last word and the state
	 * machine does not return to an idle state until it has, so an
	 * error that arrives with it is only visible afterwards.
	 */
	for(i = 0; i < Datawait; i += Pollstep){
		state = fsm();
		if(state == Edmfsmident || state == Edmfsmdata)
			break;
		microdelay(Pollstep);
	}
	sts = rd(Sdhsts);
	wr(Sdhsts, Hsterrors | Hstdataflag | Hstblkint);
	if(sts & Hsterrors){
		uartputstr("sdhost: data error, status ");
		uartputx(sts);
		uartputstr("\n");
		return -1;
	}
	return 0;
}

SDio sdhostio = {
	"sdhost",
	sdhostinit,
	sdhostenable,
	sdhostcmd,
	sdhostbus,
	sdhostiosetup,
	sdhostdata,
};
