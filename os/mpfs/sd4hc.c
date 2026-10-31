/*
 * The PolarFire SoC's card controller: a Cadence SD4HC, as an SDio for
 * the card layer (../bcm/sdmmc.c, which the board names in board.h).
 *
 * The SD4HC is a standard SDHCI with two register sets: the Cadence
 * host registers (HRS) at the base, which hold the software reset and
 * the PHY, and the standard set (SRS) 0x200 above them, which is
 * SDHCI's own layout at SDHCI's own offsets. Everything here but the
 * reset is the standard set, read and written 32 bits at a time -- the
 * view ../bcm/emmc.c takes of the Arasan's, whose bit names these are.
 *
 * On the board the Hart Software Services have already brought the
 * controller and its PHY up to read the payload from the card; this
 * driver resets the standard set, not the PHY, and so relies on that.
 * QEMU's model has no PHY to set.
 *
 * Polled, and PIO through the data port, like the Pi's drivers and for
 * their reasons: the card is read at boot and rarely after, and a
 * polled driver cannot lose a wakeup. Every wait is bounded.
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
	/* HRS: Cadence host registers */
	Hrs00		= 0x000,	/* bit 0: software reset of the whole controller */
	Hrs00swr	= 1<<0,

	Srs		= 0x200,	/* the standard SDHCI set */

	/* SRS, 32-bit views of SDHCI's registers */
	Blksizecnt	= Srs + 0x04,	/* block size | block count << 16 */
	Arg1		= Srs + 0x08,
	Cmdtm		= Srs + 0x0C,	/* transfer mode | command << 16 */
	Resp0		= Srs + 0x10,
	Resp1		= Srs + 0x14,
	Resp2		= Srs + 0x18,
	Resp3		= Srs + 0x1C,
	Data		= Srs + 0x20,
	Status		= Srs + 0x24,	/* present state */
	Control0	= Srs + 0x28,	/* host control 1 | power << 8 | gap | wakeup */
	Control1	= Srs + 0x2C,	/* clock control | timeout << 16 | reset << 24 */
	Interrupt	= Srs + 0x30,	/* normal | error << 16 */
	Irptmask	= Srs + 0x34,	/* status enables */
	Irpten		= Srs + 0x38,	/* signal enables */
	Caps		= Srs + 0x40,	/* capabilities, low word */

	/* Cmdtm */
	Tmblkcnten	= 1<<1,
	Tmdatdirread	= 1<<4,
	Tmmultiblock	= 1<<5,
	Cmdrspnone	= 0<<16,
	Cmdrsp136	= 1<<16,
	Cmdrsp48	= 2<<16,
	Cmdrsp48busy	= 3<<16,
	Cmdcrcchk	= 1<<19,
	Cmdidxchk	= 1<<20,
	Cmdisdata	= 1<<21,

	/* Status */
	Cmdinhibit	= 1<<0,
	Datinhibit	= 1<<1,
	Cardinserted	= 1<<16,

	/* Control0 */
	Hctldwidth4	= 1<<1,
	Hctlhsen	= 1<<2,
	Pwron		= 1<<8,
	Pwr33v		= 7<<9,

	/* Control1 */
	Clkinten	= 1<<0,
	Clkstable	= 1<<1,
	Clken		= 1<<2,
	Srsthc		= 1<<24,
	Srstcmd		= 1<<25,
	Srstdata	= 1<<26,

	/* Interrupt */
	Cmddone		= 1<<0,
	Datadone	= 1<<1,
	Writerdy	= 1<<4,
	Readrdy		= 1<<5,
	Cardintr	= 1<<8,
	Interrorbit	= 1<<15,
	Ctoerr		= 1<<16,

	Goidle		= 0,
	Initfreq	= 400000,
	Basefallback	= 200000000,	/* the SD4HC's reference on the SoC */

	Cmdwait		= 200000,	/* us */
	Busywait	= 1000000,
	Datawait	= 500000,
	Resetwait	= 100000,
	Pollstep	= 10,
};

static struct
{
	int	bsize;
	int	bcount;
	ulong	base;		/* the SD clock's reference, Hz */
} sd;

static u32int
rd(int off)
{
	return *(volatile u32int*)((uintptr)EMMCSDREGS + off);
}

static void
wr(int off, u32int v)
{
	*(volatile u32int*)((uintptr)EMMCSDREGS + off) = v;
	coherence();
}

static int
waitstatus(u32int mask)
{
	int i;

	for(i = 0; i < Cmdwait; i += Pollstep){
		if((rd(Status) & mask) == 0)
			return 0;
		microdelay(Pollstep);
	}
	return -1;
}

static int
waitintr(u32int mask, int us, u32int *sts)
{
	int i;
	u32int intr;

	for(i = 0; i < us; i += Pollstep){
		intr = rd(Interrupt) & ~Cardintr;
		if(intr & Interrorbit){
			if(sts != nil)
				*sts = intr;
			wr(Interrupt, intr);
			return -1;
		}
		if(intr & mask){
			if(sts != nil)
				*sts = intr;
			wr(Interrupt, intr & mask);
			return 0;
		}
		microdelay(Pollstep);
	}
	if(sts != nil)
		*sts = 0;
	return -1;
}

static void
resetline(u32int bit)
{
	int i;

	wr(Control1, rd(Control1) | bit);
	for(i = 0; i < Resetwait; i += Pollstep){
		if((rd(Control1) & bit) == 0)
			return;
		microdelay(Pollstep);
	}
	uartputstr("sd4hc: circuit reset did not complete\n");
}

/*
 * The SD clock: the reference divided by 2N, N ten bits split across
 * the clock register (8 low bits at 15:8, 2 high at 7:6).
 */
static int
setclock(ulong hz)
{
	u32int div, c1;
	int i;

	for(div = 0; div < 0x400; div++)
		if((div == 0 ? sd.base : sd.base / (2*div)) <= hz)
			break;
	c1 = rd(Control1);
	c1 &= ~Clken;
	wr(Control1, c1);
	microdelay(10);
	c1 &= ~0x0000FFC0;
	c1 |= (div & 0xFF) << 8;
	c1 |= ((div >> 8) & 0x3) << 6;
	c1 |= Clkinten;
	c1 = (c1 & ~(0xF << 16)) | (0xE << 16);	/* data timeout: the maximum */
	wr(Control1, c1);
	for(i = 0; i < Cmdwait; i += Pollstep){
		if(rd(Control1) & Clkstable)
			break;
		microdelay(Pollstep);
	}
	if((rd(Control1) & Clkstable) == 0)
		return -1;
	wr(Control1, rd(Control1) | Clken);
	microdelay(10);
	return 0;
}

static int
sd4hcinit(void)
{
	int i;
	u32int caps;

	sd.bsize = sd.bcount = 0;

	/* the Cadence reset, then SDHCI's */
	wr(Hrs00, rd(Hrs00) | Hrs00swr);
	for(i = 0; i < Resetwait && (rd(Hrs00) & Hrs00swr); i += Pollstep)
		microdelay(Pollstep);

	wr(Control0, 0);
	wr(Control1, rd(Control1) | Srsthc);
	for(i = 0; i < Cmdwait; i += Pollstep){
		if((rd(Control1) & (Srsthc|Srstcmd|Srstdata)) == 0)
			break;
		microdelay(Pollstep);
	}
	if(rd(Control1) & Srsthc){
		uartputstr("sd4hc: controller will not reset\n");
		return -1;
	}

	/* the reference clock, from the capabilities, in MHz (SDHCI v3: 8 bits) */
	caps = rd(Caps);
	sd.base = ((caps >> 8) & 0xFF) * 1000000;
	if(sd.base == 0)
		sd.base = Basefallback;

	if((rd(Status) & Cardinserted) == 0){
		uartputstr("sd4hc: no card inserted\n");
		return -1;
	}
	return 0;
}

static void
sd4hcenable(void)
{
	wr(Control0, Pwron | Pwr33v);
	microdelay(1000);
	if(setclock(Initfreq) < 0)
		uartputstr("sd4hc: no clock\n");
	wr(Irpten, 0);
	wr(Irptmask, ~0);	/* latch everything; we poll */
	wr(Interrupt, ~0);
}

static int
sd4hccmd(int idx, u32int arg, int flags, u32int *resp)
{
	u32int cmd, r0, r1, r2, r3, sts;
	int data;

	if(idx == Goidle){
		wr(Control0, rd(Control0) & ~(Hctldwidth4|Hctlhsen));
		setclock(Initfreq);
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
	if(data){
		cmd |= Cmdisdata;
		if(data == Dread)
			cmd |= Tmdatdirread;
		if(sd.bcount > 1)
			cmd |= Tmmultiblock | Tmblkcnten;
	}

	if(waitstatus(Cmdinhibit) < 0){
		resetline(Srstcmd);
		if(waitstatus(Cmdinhibit) < 0)
			return -1;
	}
	if(data || (flags & Rmask) == R48busy)
		if(waitstatus(Datinhibit) < 0){
			resetline(Srstdata);
			if(waitstatus(Datinhibit) < 0)
				return -1;
		}

	wr(Interrupt, rd(Interrupt) & ~Cardintr);
	wr(Arg1, arg);
	wr(Cmdtm, cmd);

	if(waitintr(Cmddone, Cmdwait, &sts) < 0){
		/* a bare timeout is silence -- no card, or no such command -- and the caller says so */
		if(sts != 0 && (sts & ~(Interrorbit|Cmddone)) != Ctoerr){
			uartputstr("sd4hc: cmd ");
			uartputd(idx);
			uartputstr(" error intr ");
			uartputx(sts);
			uartputstr("\n");
		}
		if(rd(Status) & Cmdinhibit)
			resetline(Srstcmd);
		if(data && (rd(Status) & Datinhibit))
			resetline(Srstdata);
		return -1;
	}

	if(resp != nil){
		resp[0] = resp[1] = resp[2] = resp[3] = 0;
		switch(flags & Rmask){
		case R136:
			/* SDHCI drops the CRC byte: shift back to the raw layout */
			r0 = rd(Resp0);
			r1 = rd(Resp1);
			r2 = rd(Resp2);
			r3 = rd(Resp3);
			resp[0] = r0 << 8;
			resp[1] = r0 >> 24 | r1 << 8;
			resp[2] = r1 >> 24 | r2 << 8;
			resp[3] = r2 >> 24 | r3 << 8;
			break;
		case R48:
		case R48busy:
			resp[0] = rd(Resp0);
			break;
		}
	}

	/* R1b: the card holds DAT0 until it is done, reported as a transfer complete */
	if((flags & Rmask) == R48busy)
		if(waitintr(Datadone, Busywait, nil) < 0){
			uartputstr("sd4hc: no Datadone after CMD");
			uartputd(idx);
			uartputstr("\n");
		}
	return 0;
}

static void
sd4hcbus(int width, int hz)
{
	u32int c0;

	if(width == 4 || width == 1){
		c0 = rd(Control0) & ~Hctldwidth4;
		if(width == 4)
			c0 |= Hctldwidth4;
		wr(Control0, c0);
	}
	if(hz > 0)
		if(setclock(hz) < 0)
			uartputstr("sd4hc: cannot set the clock\n");
}

static void
sd4hciosetup(int write, int bsize, int bcount)
{
	USED(write);
	sd.bsize = bsize;
	sd.bcount = bcount;
	wr(Blksizecnt, ((u32int)bcount << 16) | bsize);
}

static int
sd4hcxfer(int write, void *a, int len)
{
	u32int *p;
	int i, n, bsize;

	if(len & 3){
		uartputstr("sd4hc: transfer is not a whole number of words\n");
		return -1;
	}
	bsize = sd.bsize;
	if(bsize <= 0 || bsize > len)
		bsize = len;

	p = a;
	while(len > 0){
		n = bsize;
		if(n > len)
			n = len;
		if(waitintr(write ? Writerdy : Readrdy, Datawait, nil) < 0){
			resetline(Srstdata);
			return -1;
		}
		for(i = 0; i < n/4; i++){
			if(write)
				*(volatile u32int*)((uintptr)EMMCSDREGS + Data) = p[i];
			else
				p[i] = rd(Data);
		}
		p += n/4;
		len -= n;
	}
	if(waitintr(Datadone, Datawait, nil) < 0){
		resetline(Srstdata);
		return -1;
	}
	return 0;
}

SDio sd4hcio = {
	"sd4hc",
	sd4hcinit,
	sd4hcenable,
	sd4hccmd,
	sd4hcbus,
	sd4hciosetup,
	sd4hcxfer,
	nil,
};
