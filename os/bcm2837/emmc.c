/*
 * The SD card, as blocks.
 *
 * This is the mechanism half only: bring the controller up, get the
 * card out of its identification states, and read or write 512-byte
 * blocks. What is ON the card -- a partition table, a filesystem -- is
 * policy and belongs outside the kernel, the same argument that keeps
 * the USB class drivers in Limbo.
 *
 * Polled, not interrupt-driven, like everything else on this board's
 * slow paths. The card is read at boot and rarely afterwards, an
 * interrupt would have to be routed through the VideoCore controller
 * for no gain at these rates, and a polled driver is one that cannot
 * lose a wakeup -- which is the failure mode that cost the most time in
 * the USB driver.
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
	/* SD commands, by index */
	Goidle		= 0,
	Allsendcid	= 2,
	Sendrelativeaddr= 3,
	Selectcard	= 7,
	Sendifcond	= 8,
	Stoptransmission= 12,
	Setblocklen	= 16,
	Readsingle	= 17,
	Readmultiple	= 18,
	Writesingle	= 24,
	Writemultiple	= 25,
	Appcmd		= 55,
	Sdsendopcond	= 41,		/* ACMD41 */
	Setbuswidth	= 6,		/* ACMD6 */

	Blocksize	= 512,

	/*
	 * How long to wait, in microseconds, and why it is bounded.
	 *
	 * A card that never answers must produce an error, not a hung
	 * kernel: this runs during boot, and a board that stops here
	 * stops before there is a console to ask what happened. Every
	 * wait in this file has a limit for that reason.
	 */
	Cmdtimeout	= 200000,	/* 200ms for a command to complete */
	Inittimeout	= 2000000,	/* 2s for the card to power up */
	Maxnocard	= 3,		/* consecutive dead commands = no card */
};

static struct
{
	int	valid;		/* a card was found and initialised */
	int	hcs;		/* high capacity: addresses are blocks */
	u32int	rca;		/* the card's relative address */
	uvlong	nblocks;	/* 0 if unknown */
} sdcard;

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

	for(i = 0; i < Cmdtimeout; i += 10){
		if((emmcrd(Emmcstatus) & mask) == 0)
			return 0;
		microdelay(10);
	}
	return -1;
}

/*
 * Wait for an interrupt-status bit, bounded, WITHOUT taking an
 * interrupt: the bits latch in the register whether or not delivery is
 * enabled, so polling them is the same information a handler would get.
 *
 * Returns -1 on timeout or if the controller reports an error, and
 * clears whatever it saw so the next command starts from a known state.
 */
static int
emmcwaitintr(u32int mask)
{
	int i;
	u32int intr;

	for(i = 0; i < Cmdtimeout; i += 10){
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
		base = 41666667;	/* the usual BCM2837 core clock */

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

	for(i = 0; i < Cmdtimeout; i += 10){
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
 * Issue one command. resp is filled with as much of the response as the
 * command's type carries.
 */
static int
emmccmd(int idx, u32int arg, u32int flags, u32int *resp)
{
	u32int cmd;

	if(emmcwaitstatus(Cmdinhibit) < 0)
		return -1;
	if((flags & Cmdisdata) || (flags & Cmdrsp48busy) == Cmdrsp48busy)
		if(emmcwaitstatus(Datinhibit) < 0)
			return -1;

	emmcwr(Emmcinterrupt, emmcrd(Emmcinterrupt));	/* clear stale bits */
	emmcwr(Emmcarg1, arg);

	cmd = (idx << 24) | flags;
	emmcwr(Emmccmdtm, cmd);

	if(emmcwaitintr(Cmddone) < 0)
		return -1;

	if(resp != nil){
		resp[0] = emmcrd(Emmcresp0);
		if((flags & Cmdrsp136) == Cmdrsp136){
			resp[1] = emmcrd(Emmcresp1);
			resp[2] = emmcrd(Emmcresp2);
			resp[3] = emmcrd(Emmcresp3);
		}
	}
	return 0;
}

/*
 * An application command: CMD55 first, addressed to the card, then the
 * ACMD itself.
 */
static int
emmcappcmd(int idx, u32int arg, u32int flags, u32int *resp)
{
	if(emmccmd(Appcmd, sdcard.rca << 16, Cmdrsp48 | Cmdcrcchk | Cmdidxchk, nil) < 0)
		return -1;
	return emmccmd(idx, arg, flags, resp);
}

/*
 * Bring the controller and the card up. Returns 0 if there is a card.
 */
int
emmcinit(void)
{
	u32int resp[4], c1;
	int i, ok, nofail;

	/*
	 * Reset the host controller before anything else.
	 *
	 * The firmware has already used this controller to load the
	 * kernel, so it is not in its power-on state: it has a clock
	 * running, a card selected, and a block length set. Starting from
	 * whatever it left is how a driver works on one boot and not the
	 * next.
	 */
	emmcwr(Emmccontrol0, 0);
	emmcwr(Emmccontrol1, emmcrd(Emmccontrol1) | Srsthc);
	for(i = 0; i < Cmdtimeout; i += 10){
		if((emmcrd(Emmccontrol1) & (Srsthc|Srstcmd|Srstdata)) == 0)
			break;
		microdelay(10);
	}
	if(emmcrd(Emmccontrol1) & Srsthc){
		uartputstr("emmc: controller will not reset\n");
		return -1;
	}

	/* identification happens at 400kHz, per the spec */
	if(emmcsetclock(400000) < 0){
		uartputstr("emmc: no clock\n");
		return -1;
	}

	emmcwr(Emmcirpten, 0);
	emmcwr(Emmcirptmask, ~0);	/* latch everything; we poll it */
	emmcwr(Emmcinterrupt, ~0);

	sdcard.rca = 0;
	if(emmccmd(Goidle, 0, Cmdrspnone, nil) < 0){
		uartputstr("emmc: card will not go idle\n");
		return -1;
	}

	/*
	 * CMD8 separates SD 2.0 and later from older cards, and its reply
	 * has to be checked rather than merely received: a card that does
	 * not understand it simply does not answer, and one that does
	 * echoes back the check pattern. Only a card that echoes it may
	 * be offered the high-capacity bit below.
	 */
	ok = 0;
	if(emmccmd(Sendifcond, 0x1AA, Cmdrsp48 | Cmdcrcchk | Cmdidxchk, resp) == 0)
		if((resp[0] & 0xFFF) == 0x1AA)
			ok = 1;

	/*
	 * ACMD41 until the card says it has finished powering up. The
	 * busy bit is inverted -- bit 31 SET means ready -- which is easy
	 * to read the wrong way round and produces a driver that gives up
	 * exactly when the card becomes usable.
	 */
	resp[0] = 0;
	nofail = 0;
	for(i = 0; i < Inittimeout; i += 1000){
		if(emmcappcmd(Sdsendopcond, (ok? 0x40000000 : 0) | 0x00FF8000,
		    Cmdrsp48, resp) < 0){
			/*
			 * Give up quickly on a card that is not there.
			 *
			 * "Busy" and "absent" both present as ACMD41 not
			 * reporting ready, but they differ in whether the
			 * command COMPLETES: a card powering up answers and
			 * says it is busy, an empty slot answers nothing
			 * and every command times out. Retrying an empty
			 * slot for the full two seconds is time spent
			 * during boot on a certainty -- and it showed up
			 * as the console having drawn less by the time
			 * anything looked at it.
			 */
			if(++nofail >= Maxnocard){
				uartputstr("emmc: no card in the slot\n");
				return -1;
			}
			microdelay(1000);
			continue;
		}
		nofail = 0;
		if(resp[0] & 0x80000000)
			break;
		microdelay(1000);
	}
	if((resp[0] & 0x80000000) == 0){
		uartputstr("emmc: card never came ready\n");
		return -1;
	}
	sdcard.hcs = (resp[0] & 0x40000000) != 0;

	if(emmccmd(Allsendcid, 0, Cmdrsp136 | Cmdcrcchk, resp) < 0){
		uartputstr("emmc: no CID\n");
		return -1;
	}
	if(emmccmd(Sendrelativeaddr, 0, Cmdrsp48 | Cmdcrcchk | Cmdidxchk, resp) < 0){
		uartputstr("emmc: no relative address\n");
		return -1;
	}
	sdcard.rca = resp[0] >> 16;

	if(emmccmd(Selectcard, sdcard.rca << 16, Cmdrsp48busy | Cmdcrcchk, resp) < 0){
		uartputstr("emmc: card will not select\n");
		return -1;
	}

	/*
	 * A standard-capacity card addresses BYTES and needs to be told
	 * the block length; a high-capacity one addresses BLOCKS and
	 * ignores this. Sending it either way is harmless and means the
	 * read path does not have to care which kind it has beyond the
	 * address it computes.
	 */
	if(emmccmd(Setblocklen, Blocksize, Cmdrsp48 | Cmdcrcchk | Cmdidxchk, resp) < 0){
		uartputstr("emmc: cannot set block length\n");
		return -1;
	}

	/* identification is over; run at a useful speed */
	if(emmcsetclock(25000000) < 0){
		uartputstr("emmc: cannot raise the clock\n");
		return -1;
	}

	/*
	 * Four-bit bus, and BOTH ends have to agree.
	 *
	 * Setting the host controller's width without telling the card is
	 * the whole bug: the host then clocks four data lines while the
	 * card is still driving one, so commands keep working -- they go
	 * over CMD, which is unaffected -- and every DATA transfer
	 * returns nothing. The controller comes up, the card is
	 * identified, and sector 0 will not read. QEMU's model tolerates
	 * the mismatch, so it only appears on real silicon.
	 *
	 * ACMD6 first, and the host follows only if the card agreed. A
	 * card that refuses stays at one bit, which is slower and
	 * correct.
	 */
	if(emmcappcmd(Setbuswidth, 2, Cmdrsp48 | Cmdcrcchk | Cmdidxchk, resp) == 0){
		c1 = emmcrd(Emmccontrol0);
		emmcwr(Emmccontrol0, c1 | Hctldwidth4);
	}else
		uartputstr("emmc: card kept a 1-bit bus\n");

	sdcard.valid = 1;

	uartputstr("emmc: card ready, ");
	uartputstr(sdcard.hcs? "high capacity (block addressed)\n"
		: "standard capacity (byte addressed)\n");
	return 0;
}

/*
 * Read one 512-byte block. Returns 0 on success.
 */
int
emmcread(uvlong blockno, void *a)
{
	u32int *p, addr;
	int i;

	if(!sdcard.valid)
		return -1;

	/*
	 * A high-capacity card is addressed in BLOCKS and a
	 * standard-capacity one in BYTES. Getting this backwards does not
	 * fail: it reads a different, valid part of the card, which is
	 * far worse than an error.
	 */
	addr = sdcard.hcs? (u32int)blockno : (u32int)(blockno * Blocksize);

	emmcwr(Emmcblksizecnt, (1 << 16) | Blocksize);
	if(emmccmd(Readsingle, addr,
	    Cmdrsp48 | Cmdcrcchk | Cmdidxchk | Cmdisdata | Tmdatdirread, nil) < 0){
		/*
		 * Which step failed is the whole diagnosis here. The
		 * command not completing means the card never accepted the
		 * request; data never becoming ready means it accepted it
		 * and the data lines are not working, which is a different
		 * fault with a different cause.
		 */
		uartputstr("emmc: read command refused\n");
		return -1;
	}

	if(emmcwaitintr(Readrdy) < 0){
		uartputstr("emmc: no data from the card\n");
		return -1;
	}

	p = a;
	for(i = 0; i < Blocksize/4; i++)
		p[i] = emmcrd(Emmcdata);

	if(emmcwaitintr(Datadone) < 0)
		return -1;
	return 0;
}

/*
 * Write one 512-byte block. Returns 0 on success.
 */
int
emmcwrite(uvlong blockno, void *a)
{
	u32int *p, addr;
	int i;

	if(!sdcard.valid)
		return -1;

	addr = sdcard.hcs? (u32int)blockno : (u32int)(blockno * Blocksize);

	emmcwr(Emmcblksizecnt, (1 << 16) | Blocksize);
	if(emmccmd(Writesingle, addr,
	    Cmdrsp48 | Cmdcrcchk | Cmdidxchk | Cmdisdata, nil) < 0)
		return -1;

	if(emmcwaitintr(Writerdy) < 0)
		return -1;

	p = a;
	for(i = 0; i < Blocksize/4; i++)
		emmcwr(Emmcdata, p[i]);

	if(emmcwaitintr(Datadone) < 0)
		return -1;
	return 0;
}

int
emmcpresent(void)
{
	return sdcard.valid;
}
