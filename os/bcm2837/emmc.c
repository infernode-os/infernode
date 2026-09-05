/*
 * The Arasan SDHCI controller, as an SDio backend.
 *
 * This is where the SD card protocol used to live. It moved to
 * sdmmc.c when the card moved to the SDHOST controller (sdhost.c says
 * why: the CYW43455 WiFi chip can only be reached through THIS
 * controller, so the card had to give it up). What is left here is
 * the register half -- reset, clock, one command, the data port --
 * and it now serves two masters: the card, when built with
 * -DSDCARD_ARASAN, and the radio, which speaks SDIO over it in every
 * build. A working card driver on this controller is what makes a
 * SDHOST failure bisectable rather than a mystery, so that path stays.
 *
 * The SDIO half is derived from Richard Miller's emmc.c (sys/src/9/bcm
 * in the 0intro/plan9-contrib mirror, repo-root LICENSE: Plan 9
 * Foundation, MIT; Copyright © 2012 Richard Miller <r.miller@acm.org>):
 * the command-set entries for CMD5, CMD52 and CMD53, the direction and
 * multi-block decision for CMD53, the reset of width and speed on
 * CMD0, the card-interrupt handling and the register-write pacing are
 * his. Reduced to polling and PIO: this tree has no DMA engine and
 * takes no SD interrupt.
 *
 * The register layout is SDHCI's at a non-standard spacing, which is
 * why io.h names the offsets rather than borrowing a generic header.
 *
 * Polled, not interrupt-driven, like everything else on this board's
 * slow paths: the interrupt bits latch whether or not delivery is
 * enabled, so polling them is the same information a handler would
 * get, and a polled driver cannot lose a wakeup. The one wait that
 * can be long -- the radio's card interrupt -- sleeps a tick between
 * polls rather than spinning, because the process waiting on it is
 * a kproc and the core is shared.
 *
 * WRITE PACING. Miller found, and the Linux sdhci-bcm2835 driver
 * documents, that this controller can lose the second of two register
 * writes that land within two SD-clock cycles of each other -- a
 * clock-domain crossing, not a software bug -- so every control
 * register write is preceded by a delay of 20us at the 400kHz
 * identification clock and 2us once the clock is fast. The block path
 * never showed it because a read intervened between its writes; a
 * CMD53 stream would not be so lucky. The data port is exempt: the
 * same Linux comment records that the data register does not have the
 * problem, and pacing 128 words a block would cost more than the
 * transfer.
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

	Goidle		= 0,
	Iorwextended	= 53,		/* SDIO: the data command */

	/*
	 * How long to wait, in microseconds. Bounded, because this runs
	 * during boot and a board that stops here stops before there is
	 * a console to ask what happened.
	 */
	Cmdwait		= 200000,	/* 200ms for a command to complete */
	Busywait	= 1000000,	/* 1s for an R1b card to release DAT0 */
	Datawait	= 500000,	/* 500ms for a block to move */
	Resetwait	= 100000,	/* 100ms for a circuit reset to finish */
	Pollstep	= 10,
};

static struct
{
	int	fastclock;	/* above the identification clock: short pacing */
	int	bsize;		/* the transfer being set up, from iosetup */
	int	bcount;
	Rendez	cardr;		/* the card interrupt, polled a tick at a time */
} arasan;

static u32int
emmcrd(int off)
{
	return *(volatile u32int*)(uintptr)(EMMCREGS + off);
}

/*
 * A control register write, paced as the header explains.
 */
static void
emmcwr(int off, u32int v)
{
	microdelay(arasan.fastclock? 2 : 20);
	*(volatile u32int*)(uintptr)(EMMCREGS + off) = v;
	coherence();
}

/*
 * The data port, unpaced: it does not share the fault.
 */
static void
datawr(u32int v)
{
	*(volatile u32int*)(uintptr)(EMMCREGS + Emmcdata) = v;
}

/*
 * Wait for status bits to clear, bounded. Returns -1 on timeout.
 */
static int
emmcwaitstatus(u32int mask)
{
	int i;

	for(i = 0; i < Cmdwait; i += Pollstep){
		if((emmcrd(Emmcstatus) & mask) == 0)
			return 0;
		microdelay(Pollstep);
	}
	return -1;
}

/*
 * Wait for an interrupt-status bit, bounded, WITHOUT taking an
 * interrupt. Returns -1 on timeout or if the controller reports an
 * error, and clears whatever it saw so the next command starts from a
 * known state. The card interrupt is left alone: it belongs to
 * whoever is waiting for it, and it latches for as long as the card
 * holds DAT1 low.
 *
 * *sts, if given, receives the interrupt word that ended the wait, so
 * a caller can tell "nothing answered" from "something went wrong".
 */
static int
emmcwaitintr(u32int mask, int us, u32int *sts)
{
	int i;
	u32int intr;

	for(i = 0; i < us; i += Pollstep){
		intr = emmcrd(Emmcinterrupt) & ~Cardintr;
		if(intr & Interrorbit){
			if(sts != nil)
				*sts = intr;
			emmcwr(Emmcinterrupt, intr);
			return -1;
		}
		if(intr & mask){
			if(sts != nil)
				*sts = intr;
			emmcwr(Emmcinterrupt, intr & mask);
			return 0;
		}
		microdelay(Pollstep);
	}
	if(sts != nil)
		*sts = 0;
	return -1;
}

/*
 * Reset one circuit -- Srstcmd or Srstdata -- and wait for the
 * controller to say it is done. Used after a command that failed
 * with a line still inhibited: without it the next command waits out
 * its whole bound on a controller that is never going to answer.
 */
static void
emmcresetline(u32int bit)
{
	int i;

	emmcwr(Emmccontrol1, emmcrd(Emmccontrol1) | bit);
	for(i = 0; i < Resetwait; i += Pollstep){
		if((emmcrd(Emmccontrol1) & bit) == 0)
			return;
		microdelay(Pollstep);
	}
	uartputstr("emmc: circuit reset did not complete\n");
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

	for(i = 0; i < Cmdwait; i += Pollstep){
		if(emmcrd(Emmccontrol1) & Clkstable)
			break;
		microdelay(Pollstep);
	}
	if((emmcrd(Emmccontrol1) & Clkstable) == 0)
		return -1;

	emmcwr(Emmccontrol1, emmcrd(Emmccontrol1) | Clken);
	microdelay(10);
	/*
	 * The pacing follows the clock: two SD-clock cycles at 400kHz
	 * are 5us, at 25MHz they are 80ns.
	 */
	arasan.fastclock = hz > Initfreq;
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
 * The pins are NOT touched here; whose they are depends on the build.
 * With the card on this controller they are GPIO 48-53 at ALT3, where
 * start.elf leaves them on the board and where function 0, the reset
 * value, puts them under QEMU -- both "as found", so the one setting
 * right in both places is the one already there, and they are only
 * claimed so that #G cannot move them from under the card. In the
 * default build those pins belong to sdhost.c, and the radio driver
 * routes this controller to GPIO 34-39 itself before calling this,
 * because that routing is its business and its failure to report.
 */
static int
arasaninit(void)
{
	int i;

#ifdef SDCARD_ARASAN
	for(i = 48; i <= 53; i++)
		gpioclaim(i, "emmc");
#endif
	arasan.fastclock = 0;
	arasan.bsize = 0;
	arasan.bcount = 0;

	emmcwr(Emmccontrol0, 0);
	emmcwr(Emmccontrol1, emmcrd(Emmccontrol1) | Srsthc);
	for(i = 0; i < Cmdwait; i += Pollstep){
		if((emmcrd(Emmccontrol1) & (Srsthc|Srstcmd|Srstdata)) == 0)
			break;
		microdelay(Pollstep);
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
 *
 * SDIO's three commands need nothing the flags do not already say --
 * CMD5's R4 is a 48-bit reply without CRC, CMD52's R5 is an ordinary
 * one, CMD53 is R5 with data -- except that CMD53 carries its own
 * direction in bit 31 of the argument, which is taken from there
 * rather than trusted from the flags, and moves as many blocks as the
 * last iosetup named: one block is a single transfer, anything else
 * is multi-block with the count enabled, as Miller decides it.
 *
 * CMD0 is a new card, or a radio being probed from scratch: the bus
 * width and high-speed bit are dropped and the clock returned to the
 * identification rate, because a card that has just been reset is at
 * one bit and 400kHz whatever this end remembers.
 */
static int
arasancmd(int idx, u32int arg, int flags, u32int *resp)
{
	u32int cmd, r0, r1, r2, r3, sts;
	int data;

	if(idx == Goidle){
		emmcwr(Emmccontrol0, emmcrd(Emmccontrol0) & ~(Hctldwidth4|Hctlhsen));
		emmcsetclock(Initfreq);
	}

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
	data = flags & (Dread|Dwrite);
	if(idx == Iorwextended){
		data = (arg & (1U<<31))? Dwrite : Dread;
		if(arasan.bcount != 1)
			cmd |= Tmmultiblock | Tmblkcnten;
	}
	if(data){
		cmd |= Cmdisdata;
		if(data == Dread)
			cmd |= Tmdatdirread;
	}

	/*
	 * A line still inhibited from a command that went wrong is
	 * reset rather than waited on: the controller will not clear
	 * it by itself, and every later command would wait out its
	 * whole bound behind it.
	 */
	if(emmcwaitstatus(Cmdinhibit) < 0){
		emmcresetline(Srstcmd);
		if(emmcwaitstatus(Cmdinhibit) < 0)
			return -1;
	}
	if(data || (flags & Rmask) == R48busy)
		if(emmcwaitstatus(Datinhibit) < 0){
			emmcresetline(Srstdata);
			if(emmcwaitstatus(Datinhibit) < 0)
				return -1;
		}

	emmcwr(Emmcinterrupt, emmcrd(Emmcinterrupt) & ~Cardintr);	/* clear stale bits */
	emmcwr(Emmcarg1, arg);
	emmcwr(Emmccmdtm, cmd);

	if(emmcwaitintr(Cmddone, Cmdwait, &sts) < 0){
		/*
		 * A command timeout on its own is silence -- an empty
		 * slot, or a radio that is not there -- and the caller
		 * reports that in its own words. Anything else is the
		 * controller objecting, and worth the detail once.
		 */
		if(sts != 0 && (sts & ~Interrorbit) != Ctoerr){
			uartputstr("emmc: cmd ");
			uartputd(idx);
			uartputstr(" error intr ");
			uartputx(sts);
			uartputstr(" status ");
			uartputx(emmcrd(Emmcstatus));
			uartputstr("\n");
		}
		if(emmcrd(Emmcstatus) & Cmdinhibit)
			emmcresetline(Srstcmd);
		if(data && (emmcrd(Emmcstatus) & Datinhibit))
			emmcresetline(Srstdata);
		return -1;
	}

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

	/*
	 * R1b: the card holds DAT0 low until it has finished, and the
	 * controller reports that as a transfer complete. Waited for
	 * here so the caller's next command does not meet a busy card;
	 * a card that never releases the line is reported and not
	 * waited on again, since the card layer asks CMD13 itself
	 * before anything that matters.
	 */
	if((flags & Rmask) == R48busy)
		if(emmcwaitintr(Datadone, Busywait, nil) < 0){
			uartputstr("emmc: no Datadone after CMD");
			uartputd(idx);
			uartputstr("\n");
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
	arasan.bsize = bsize;
	arasan.bcount = bcount;
	emmcwr(Emmcblksizecnt, ((u32int)bcount << 16) | bsize);
}

/*
 * Move the data of a command already issued with Dread or Dwrite:
 * for each block, wait for the controller to say its buffer is ready,
 * move the words; then wait for it to say the transfer is over.
 *
 * Per block, not per transfer, because the buffer holds one block and
 * the ready bit is raised once for each: reading on past the block
 * before the next ready is reading a buffer that has not been filled,
 * which does not fail, it returns the previous contents. A single
 * 512-byte block -- the card path -- is one iteration, exactly what
 * this did before it learned to count.
 *
 * On any failure the data circuit is reset, so that a CMD53 that went
 * wrong on the radio does not leave DAT inhibited for the next one.
 */
static int
arasanio(int write, void *a, int len)
{
	u32int *p;
	int i, n, bsize;

	if(len & 3){
		uartputstr("emmc: transfer is not a whole number of words\n");
		return -1;
	}
	bsize = arasan.bsize;
	if(bsize <= 0 || bsize > len)
		bsize = len;

	p = a;
	while(len > 0){
		n = bsize;
		if(n > len)
			n = len;
		if(emmcwaitintr(write? Writerdy : Readrdy, Datawait, nil) < 0){
			emmcresetline(Srstdata);
			return -1;
		}
		for(i = 0; i < n/4; i++){
			if(write)
				datawr(p[i]);
			else
				p[i] = emmcrd(Emmcdata);
		}
		p += n/4;
		len -= n;
	}

	if(emmcwaitintr(Datadone, Datawait, nil) < 0){
		emmcresetline(Srstdata);
		return -1;
	}
	return 0;
}

static int
cardintready(void *a)
{
	USED(a);
	return emmcrd(Emmcinterrupt) & Cardintr;
}

/*
 * The SDIO card interrupt: the radio pulling DAT1 low because a
 * frame, an event or a command response is waiting. The bit latches
 * for as long as the line is held, so it is cleared before looking,
 * and cleared again after, the way Miller's sdiocardintr does it.
 *
 * Polled a tick at a time -- HZ is 1000 here, so a millisecond --
 * rather than delivered through IRQ 62, which stays masked in the
 * VideoCore controller. The latency is bounded and the kproc that
 * waits here yields the core meanwhile; enabling the interrupt is the
 * change to make when the throughput of the radio is what is being
 * measured, and not before.
 */
static int
arasancardintr(int wait)
{
	u32int i;

	emmcwr(Emmcinterrupt, Cardintr);
	while(((i = emmcrd(Emmcinterrupt)) & Cardintr) == 0){
		if(!wait)
			return 0;
		tsleep(&arasan.cardr, cardintready, nil, 1);
	}
	emmcwr(Emmcinterrupt, Cardintr);
	return i;
}

SDio emmcio = {
	"emmc",
	arasaninit,
	arasanenable,
	arasancmd,
	arasanbus,
	arasaniosetup,
	arasanio,
	arasancardintr,
};
