/*
 * The CYW43455 WiFi radio, over SDIO on the Arasan: the dongle up.
 *
 * Derived from Richard Miller's ether4330.c (sys/src/9/bcm in the
 * 0intro/plan9-contrib mirror, repo-root LICENSE: Plan 9 Foundation,
 * MIT), the FullMAC driver for the Broadcom/Cypress 43xx family. This
 * is the first ~1170 lines of it -- SDIO bring-up, the Sonics
 * backplane, the firmware upload and the command path to the running
 * firmware -- with the parts that need a scheduler separated from the
 * parts that run at boot, every wait bounded, and the addresses the
 * backplane deals in held in u32int, since the original's ulong is
 * 32 bits on Plan 9 and 64 here.
 *
 * WHAT THIS MILESTONE DOES, AND STOPS AT. Route the Arasan to the
 * radio's pins, find the radio on the SDIO bus, scan its backplane
 * for the cores the upload needs, upload the firmware and NVRAM into
 * its RAM and read them back to check, start the firmware, and ask it
 * for its MAC address and version. That is "dongle up". No frames are
 * moved, no scan is issued and no network is joined: those are the
 * next milestones, and each adds to this file rather than to the
 * kernel around it.
 *
 * WHEN EACH HALF RUNS. The probe -- pins, SDIO identification,
 * backplane scan -- runs at board init, after sdhost.c has taken the
 * card off the Arasan, in kmain's context where there is no
 * scheduler: it is written with return codes and microdelay, and its
 * verdict is one line, "ether4330: no radio" or the chip it found.
 * The upload runs at attach, in the process that binds #l1, because
 * the firmware is a FILE and a file is found in a namespace: on this
 * system the card the firmware lives on is mounted at /n/dos by init,
 * long after board init, and a kernel process has no namespace at
 * all. So the board test is: let init mount the card, then
 *
 *	bind -a '#l1' /net
 *	cat /net/ether1/addr
 *
 * and the bind's error, if any, names the step that failed.
 *
 * WHERE THE FIRMWARE IS LOOKED FOR, in order:
 *
 *	/boot/<name>
 *	/sys/lib/firmware/<name>
 *	/n/dos/firmware/<name>
 *
 * The first two are where Miller's driver looks (Plan 9 keeps its
 * firmware in /sys/lib/firmware and its boot partition at /boot); the
 * third is this system's card. For the 43455 the names are
 * brcmfmac43455-sdio.bin, brcmfmac43455-sdio.txt (the NVRAM) and
 * brcmfmac43455-sdio.clm_blob (the regulatory table). None of them is
 * in this tree and none may be: they are Cypress binaries under a
 * redistribution-only licence. tools/pi-firmware.sh fetches them at a
 * pinned revision, checks them against tools/pi-firmware-manifest.txt
 * and puts them on the card; os/bcm2837/README.md says more.
 *
 * NEVER HANGS THE BOOT. Every loop here has a bound. A radio that is
 * absent costs two command timeouts at boot and one line; a firmware
 * that is missing costs the bind that asked for it and one line
 * naming the file and the three places it was not; a firmware that
 * loads and then does not answer costs a five-second wait in the
 * binding process and an error, never a stuck kernel.
 *
 * POLLED. The card interrupt (DAT1) is polled a tick at a time by
 * emmc.c's cardintr; IRQ 62 stays masked. Good enough for bring-up,
 * and the place to change when throughput is what is being measured.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../port/netif.h"
#include	"../port/etherif.h"
#include	"board.h"

#define ROUND(s, sz)	(((s)+((sz)-1))&~((sz)-1))
#define MAX(a, b)	((a) > (b)? (a) : (b))
#define MIN(a, b)	((a) < (b)? (a) : (b))

enum
{
	SDIODEBUG	= 0,
	SBDEBUG		= 0,
	EVENTDEBUG	= 0,
	VARDEBUG	= 0,
	FWDEBUG		= 0,

	Corescansz	= 512,
	Wlregon		= 129,		/* WL_REG_ON on the firmware GPIO expander (128+1) */
	Uploadsz	= 2048,
	Cfgmax		= 16*1024,	/* the NVRAM text, whole; the pinned file is ~2 KB */

	Firmwarecmp	= 1,		/* read the upload back and compare */

	ARMcm3		= 0x82A,
	ARM7tdmi	= 0x825,
	ARMcr4		= 0x83E,

	Fn0		= 0,
	Fn1		= 1,
	Fn2		= 2,
	Fbr1		= 0x100,
	Fbr2		= 0x200,

	/* CCCR */
	Ioenable	= 0x02,
	Ioready		= 0x03,
	Intenable	= 0x04,
	Intpend		= 0x05,
	Ioabort		= 0x06,
	Busifc		= 0x07,
	Capability	= 0x08,
	Blksize		= 0x10,
	Highspeed	= 0x13,

	/* SDIO commands */
	GO_IDLE_STATE		= 0,
	SEND_RELATIVE_ADDR	= 3,
	IO_SEND_OP_COND		= 5,
	SELECT_CARD		= 7,
	IO_RW_DIRECT		= 52,
	IO_RW_EXTENDED		= 53,

	Rcashift	= 16,

	/* IO_SEND_OP_COND argument and OCR */
	V3_3		= 3<<20,	/* 3.2-3.4 volts */
	Ocrready	= 1U<<31,	/* the radio has finished powering up */

	Sdclk		= 25000000,	/* after identification; no high speed yet */

	/* Sonics Silicon Backplane: how the cores on the chip are reached */
	Sbwsize		= 0x8000,
	Sb32bit		= 0x8000,
	Sbaddr		= 0x1000a,
		Enumbase	= 0x18000000,
	Framectl	= 0x1000d,
		Rfhalt		= 0x01,
		Wfhalt		= 0x02,
	Clkcsr		= 0x1000e,
		ForceALP	= 0x01,	/* active low-power clock */
		ForceHT		= 0x02,	/* high throughput clock */
		ForceILP	= 0x04,	/* idle low-power clock */
		ReqALP		= 0x08,
		ReqHT		= 0x10,
		Nohwreq		= 0x20,
		ALPavail	= 0x40,
		HTavail		= 0x80,
	Pullups		= 0x1000f,
	Wfrmcnt		= 0x10019,
	Rfrmcnt		= 0x1001b,

	/* core control regs */
	Ioctrl		= 0x408,
	Resetctrl	= 0x800,

	/* socram regs */
	Coreinfo	= 0x00,
	Bankidx		= 0x10,
	Bankinfo	= 0x40,
	Bankpda		= 0x44,

	/* armcr4 regs */
	Cr4Cap		= 0x04,
	Cr4Bankidx	= 0x40,
	Cr4Bankinfo	= 0x44,
	Cr4Cpuhalt	= 0x20,

	/* chipcommon regs */
	Gpiopullup	= 0x58,
	Gpiopulldown	= 0x5c,
	Chipctladdr	= 0x650,
	Chipctldata	= 0x654,

	/* sdio core regs */
	Intstatus	= 0x20,
		Fcstate		= 1<<4,
		Fcchange	= 1<<5,
		FrameInt	= 1<<6,
		MailboxInt	= 1<<7,
	Intmask		= 0x24,
	Sbmbox		= 0x40,
	Sbmboxdata	= 0x48,
	Hostmboxdata	= 0x4c,
		Fwready		= 0x80,

	/* wifi control commands */
	GetVar		= 262,
	SetVar		= 263,

	/*
	 * Bounds, in polls of the step given, for waits that have none
	 * in the original.
	 */
	Sbpolls		= 100000,	/* x10us = 1 s: a core to reset or a clock to come; Linux bounds the PMU at a second and says ALP alone may take 15 ms */
	Ocrtries	= 5,		/* x100ms: the OCR ready bit */
	Nocard		= 2,		/* consecutive silent CMD5s = no radio */
	Ioreadytries	= 10,		/* x100ms: a function to enable */
	Cmdtimeout	= 5000,		/* ms: the firmware to answer a command */
};

typedef struct Ctlr Ctlr;
struct Ctlr
{
	Ether	*edev;
	QLock	cmdlock;	/* one command in flight */
	QLock	pktlock;	/* one packet on the bus */
	QLock	alock;		/* one attach at a time */
	Rendez	cmdr;
	Block	*rsp;		/* the response rproc caught for wlcmd */

	int	present;	/* the probe found a radio */
	int	running;	/* firmware running and answering */
	int	reader;		/* rproc has been started */
	int	fwbytes;	/* size of the firmware uploaded */
	char	ver[128];	/* what the firmware says it is */

	int	chipid;
	int	chiprev;
	int	armcore;
	char	*regufile;
	Chan	*fwchan[3];	/* bin, nvram, clm -- named by the firmware ctl verb */
	union {
		u32int	i;
		uchar	c[4];
	} resetvec;
	u32int	chipcommon;
	u32int	armctl;
	u32int	armregs;
	u32int	d11ctl;
	u32int	socramregs;
	u32int	socramctl;
	u32int	sdregs;
	int	sdiorev;
	int	socramrev;
	u32int	socramsize;
	u32int	rambase;
	short	reqid;
	uchar	fcmask;
	uchar	txwindow;
	uchar	txseq;
	uchar	rxseq;
};

typedef struct Sdpcm Sdpcm;
typedef struct Cmd Cmd;
struct Sdpcm
{
	uchar	len[2];
	uchar	lenck[2];
	uchar	seq;
	uchar	chanflg;
	uchar	nextlen;
	uchar	doffset;
	uchar	fcmask;
	uchar	window;
	uchar	version;
	uchar	pad;
};

struct Cmd
{
	uchar	cmd[4];
	uchar	len[4];
	uchar	flags[2];
	uchar	id[2];
	uchar	status[4];
};

static char config40181[] = "bcmdhd.cal.40181";
static char config40183[] = "bcmdhd.cal.40183.26MHz";

/*
 * Miller's table, kept whole: the mechanism is the same for every
 * chip in it and the one on this board is the last line.
 */
static struct
{
	int	chipid;
	int	chiprev;
	char	*fwfile;
	char	*cfgfile;
	char	*regufile;
} firmware[] = {
	{ 0x4330, 3,	"fw_bcm40183b1.bin", config40183, 0 },
	{ 0x4330, 4,	"fw_bcm40183b2.bin", config40183, 0 },
	{ 43362, 0,	"fw_bcm40181a0.bin", config40181, 0 },
	{ 43362, 1,	"fw_bcm40181a2.bin", config40181, 0 },
	{ 43430, 1,	"brcmfmac43430-sdio.bin", "brcmfmac43430-sdio.txt", 0 },
	{ 43430, 2,	"brcmfmac43436-sdio.bin", "brcmfmac43436-sdio.txt",  "brcmfmac43436-sdio.clm_blob" },
	{ 0x4345, 6,	"brcmfmac43455-sdio.bin", "brcmfmac43455-sdio.txt", "brcmfmac43455-sdio.clm_blob" },
};


static Ctlr ctlr4330;
static SDio *sdio = &emmcio;	/* the radio is wired to the Arasan and nothing else */
static QLock sdiolock;
static int booting;		/* in kmain: no scheduler, so no tsleep */
static int iodebug;

static uchar*
put2(uchar *p, int v)
{
	p[0] = v;
	p[1] = v >> 8;
	return p + 2;
}

static uchar*
put4(uchar *p, u32int v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
	return p + 4;
}

static u32int
get4(uchar *p)
{
	return p[0] | p[1]<<8 | p[2]<<16 | (u32int)p[3]<<24;
}

static void
dump(char *s, void *a, int n)
{
	int i;
	uchar *p;

	p = a;
	print("%s:", s);
	for(i = 0; i < n; i++)
		print("%c%2.2x", i&15? ' ' : '\n', *p++);
	print("\n");
}

/*
 * A wait of some milliseconds that is a sleep when there is a
 * scheduler and a spin when there is not (the boot probe).
 */
static void
pause(int ms)
{
	if(booting)
		microdelay(ms * 1000);
	else
		tsleep(&up->sleep, return0, nil, ms);
}

/*
 * The boot probe's messages. print() may go through the console
 * device; the uart routines are what the rest of board init trusts.
 */
static void
bootsay(char *step, u32int v, int hex)
{
	uartputstr("ether4330: ");
	uartputstr(step);
	if(hex >= 0){
		uartputstr(" ");
		if(hex)
			uartputx(v);
		else
			uartputd(v);
	}
	uartputstr("\n");
}

/*
 * SDIO: the bus the radio hangs on.
 *
 * Return codes throughout, -1 on failure, so that this layer serves
 * the boot probe (no error()) and the attach path alike. Every
 * failure has already been described by the controller or is
 * described by the caller, which knows what step it was.
 */

static int
sdiocmd(int cmd, u32int arg, int flags, u32int *resp)
{
	u32int r[4];
	int rc;

	qlock(&sdiolock);
	rc = sdio->cmd(cmd, arg, flags, r);
	qunlock(&sdiolock);
	if(rc < 0){
		if(SDIODEBUG) print("ether4330: cmd %d arg %ux failed\n", cmd, arg);
		return -1;
	}
	if(resp != nil)
		*resp = r[0];
	return 0;
}

/*
 * CMD52: one byte, and the R5 response says whether the function
 * took it. Returns the byte read (or written) or -1.
 */
static int sdiobit(int, int, int);

static int
sdiord(int fn, int addr)
{
	u32int r;

	if(sdiocmd(IO_RW_DIRECT, (0U<<31)|((fn&7)<<28)|((addr&0x1FFFF)<<9), R48, &r) < 0)
		return -1;
	if(r & 0xCF00){
		print("ether4330: sdiord(%x, %x) fail: %2.2ux %2.2ux\n", fn, addr, (r>>8)&0xFF, r&0xFF);
		return -1;
	}
	return r & 0xFF;
}

static int
sdiowr(int fn, int addr, int data)
{
	u32int r;
	int retry;

	r = 0;
	for(retry = 0; retry < 10; retry++){
		if(sdiocmd(IO_RW_DIRECT, (1U<<31)|((fn&7)<<28)|((addr&0x1FFFF)<<9)|(data&0xFF), R48, &r) < 0)
			return -1;
		if((r & 0xCF00) == 0)
			return 0;
	}
	print("ether4330: sdiowr(%x, %x, %x) fail: %2.2ux %2.2ux\n", fn, addr, data, (r>>8)&0xFF, r&0xFF);
	return -1;
}

static int
sdioabort(int fn)
{
	return sdiowr(Fn0, Ioabort, fn);
}

/*
 * CMD53: bytes or blocks, through the Arasan's data port. The block
 * size is the function's (64 for F1, 512 for F2, set in the FBRs at
 * init); a transfer shorter than a block goes as that many bytes
 * with a count of one, which is how the controller learns that a
 * transfer is single-block.
 */
static int
sdiorwext(int fn, int write, void *a, int len, int addr, int incr)
{
	int bsize, blk, bcount, m, rc;

	bsize = fn == Fn2? 512 : 64;
	while(len > 0){
		if(len >= 511*bsize){
			blk = 1;
			bcount = 511;
			m = bcount*bsize;
		}else if(len > bsize){
			blk = 1;
			bcount = len/bsize;
			m = bcount*bsize;
		}else{
			blk = 0;
			bcount = len;
			m = bcount;
		}
		qlock(&sdiolock);
		if(blk)
			sdio->iosetup(write, bsize, bcount);
		else
			sdio->iosetup(write, bcount, 1);
		rc = sdio->cmd(IO_RW_EXTENDED,
			(u32int)write<<31 | (fn&7)<<28 | blk<<27 | incr<<26 | (addr&0x1FFFF)<<9 | (bcount&0x1FF),
			R48 | (write? Dwrite : Dread), nil);
		if(rc == 0)
			rc = sdio->io(write, a, m);
		qunlock(&sdiolock);
		if(rc < 0){
			if(SDIODEBUG) print("ether4330: sdiorwext fn %d %s %d at %x failed\n",
				fn, write? "write" : "read", m, addr);
			sdioabort(fn);
			return -1;
		}
		len -= m;
		a = (char*)a + m;
		if(incr)
			addr += m;
	}
	return 0;
}

static int
sdioset(int fn, int addr, int bits)
{
	int v;

	v = sdiord(fn, addr);
	if(v < 0)
		return -1;
	return sdiowr(fn, addr, v | bits);
}

/*
 * Find the radio and bring the bus up: pins, CMD0, CMD5 until the
 * OCR says ready, CMD3, CMD7, then the CCCR -- high speed, four-bit
 * bus, block sizes for F1 and F2, F1 enabled and its interrupt off.
 * Miller's sdioinit, with the silence of an absent radio told apart
 * from the busy reply of a present one: a CMD5 that is not answered
 * at all, twice, is no radio, and costs two command timeouts rather
 * than five hundred milliseconds of hope.
 *
 * The pins: GPIO 34-39 are the radio's SDIO lines, and ALT3 is the
 * routing that puts the Arasan on them -- not officially documented,
 * as Miller notes, but it is what Linux's device tree selects. 34 is
 * the clock and gets no pull; the others get pull-ups, as an SD bus
 * does. Under QEMU this write is a no-op (its mux knows only ALT0 and
 * function 0 for 48-53 and nothing for 34-39), which is why the probe
 * that follows finds nothing there.
 *
 * GPIO 48-53 are not touched: they became sdhost.c's at milestone 1.
 */
static int
sdioinit(void)
{
	u32int ocr, rca;
	int i, silent;

	for(i = 34; i <= 39; i++){
		gpiofunc(i, Gpioalt3);
		gpiopull(i, i == 34? Pullnone : Pullup);
		gpioclaim(i, "ether4330");
	}
	if(sdio->init() < 0){
		bootsay("controller will not reset", 0, -1);
		return -1;
	}
	sdio->enable();
	if(sdiocmd(GO_IDLE_STATE, 0, Rnone, nil) < 0){
		bootsay("no radio", 0, -1);
		return -1;
	}
	ocr = 0;
	silent = 0;
	for(i = 0; i <= Ocrtries; i++){
		if(sdiocmd(IO_SEND_OP_COND, i == 0? 0 : V3_3, R48 | Rnocrc, &ocr) < 0){
			if(++silent >= Nocard){
				bootsay("no radio", 0, -1);
				return -1;
			}
			ocr = 0;
			pause(100);
			continue;
		}
		silent = 0;
		if(ocr & Ocrready)
			break;
		pause(100);
	}
	if((ocr & Ocrready) == 0){
		bootsay("radio never came ready: ocr", ocr, 1);
		return -1;
	}
	if(sdiocmd(SEND_RELATIVE_ADDR, 0, R48, &rca) < 0){
		bootsay("no relative address (CMD3)", 0, -1);
		return -1;
	}
	rca >>= Rcashift;
	if(sdiocmd(SELECT_CARD, rca << Rcashift, R48busy, nil) < 0){
		bootsay("radio will not select (CMD7)", 0, -1);
		return -1;
	}
	sdio->bus(0, Sdclk);
	if(sdioset(Fn0, Highspeed, 2) < 0){
		bootsay("CCCR high-speed write refused", 0, -1);
		return -1;
	}
	if(sdioset(Fn0, Busifc, 2) < 0){	/* bus width 4 */
		bootsay("CCCR bus-width write refused", 0, -1);
		return -1;
	}
	sdio->bus(4, 0);
	if(sdiowr(Fn0, Fbr1+Blksize, 64) < 0 ||
	   sdiowr(Fn0, Fbr1+Blksize+1, 64>>8) < 0 ||
	   sdiowr(Fn0, Fbr2+Blksize, 512 & 0xFF) < 0 ||
	   sdiowr(Fn0, Fbr2+Blksize+1, 512>>8) < 0){
		bootsay("function block sizes refused", 0, -1);
		return -1;
	}
	if(sdioset(Fn0, Ioenable, 1<<Fn1) < 0 || sdiowr(Fn0, Intenable, 0) < 0){
		bootsay("cannot enable function 1", 0, -1);
		return -1;
	}
	for(i = 0; ; i++){
		if(sdiobit(Fn0, Ioready, 1<<Fn1))
			break;
		if(i == Ioreadytries){
			bootsay("function 1 never became ready", 0, -1);
			return -1;
		}
		pause(100);
	}
	return 0;
}

static void
sdioreset(void)
{
	sdiowr(Fn0, Ioabort, 1<<3);	/* reset */
}

/*
 * Chip register and memory access via SDIO function 1
 */

static int
cfgw(u32int off, int val)
{
	return sdiowr(Fn1, off, val);
}

static int
cfgr(u32int off)
{
	return sdiord(Fn1, off);
}

/*
 * A bit of a register, or 0 when the read itself failed. sdiord()
 * answers -1 on a bus failure, and -1 has every bit set: a caller
 * that masks it reads a dead bus as "ready", "clock available", or
 * whatever it was hoping for, and carries on into the dark.
 */
static int
sdiobit(int fn, int addr, int mask)
{
	int v;

	v = sdiord(fn, addr);
	if(v < 0)
		return 0;
	return v & mask;
}

static int
cfgreadl(int fn, u32int off, u32int *v)
{
	uchar p[4];

	memset(p, 0, 4);
	if(sdiorwext(fn, 0, p, 4, off|Sb32bit, 1) < 0)
		return -1;
	if(SDIODEBUG) print("cfgreadl %ux: %2.2x %2.2x %2.2x %2.2x\n", off, p[0], p[1], p[2], p[3]);
	*v = get4(p);
	return 0;
}

static int
cfgwritel(int fn, u32int off, u32int data)
{
	uchar p[4];
	int retry;

	put4(p, data);
	if(SDIODEBUG) print("cfgwritel %ux: %2.2x %2.2x %2.2x %2.2x\n", off, p[0], p[1], p[2], p[3]);
	for(retry = 0; retry < 3; retry++){
		if(sdiorwext(fn, 1, p, 4, off|Sb32bit, 1) == 0)
			return 0;
		print("ether4330: cfgwritel retry %ux %ux\n", off, data);
		sdioabort(fn);
	}
	return -1;
}

/*
 * Point the 32KB backplane window at addr.
 */
static int
sbwindow(u32int addr)
{
	addr &= ~(Sbwsize-1);
	if(cfgw(Sbaddr, addr>>8) < 0 ||
	   cfgw(Sbaddr+1, addr>>16) < 0 ||
	   cfgw(Sbaddr+2, addr>>24) < 0)
		return -1;
	return 0;
}

static int
sbrw(int fn, int write, uchar *buf, int len, u32int off)
{
	int n;

	USED(fn);
	if(len >= 4){
		n = len & ~3;
		if(sdiorwext(Fn1, write, buf, n, off|Sb32bit, 1) < 0){
			print("ether4330: sbrw err off %ux len %ud\n", off, len);
			return -1;
		}
		off += n;
		buf += n;
		len -= n;
	}
	while(len > 0){
		if(write){
			if(sdiowr(Fn1, off|Sb32bit, *buf) < 0)
				return -1;
		}else{
			n = sdiord(Fn1, off|Sb32bit);
			if(n < 0)
				return -1;
			*buf = n;
		}
		off++;
		buf++;
		len--;
	}
	return 0;
}

/*
 * Read or write chip memory across window boundaries.
 */
static int
sbmem(int write, uchar *buf, int len, u32int off)
{
	u32int n;

	n = ROUND(off, Sbwsize) - off;
	if(n == 0)
		n = Sbwsize;
	while(len > 0){
		if(n > (u32int)len)
			n = (u32int)len;
		if(sbwindow(off) < 0)
			return -1;
		if(sbrw(Fn1, write, buf, n, off & (Sbwsize-1)) < 0)
			return -1;
		off += n;
		buf += n;
		len -= n;
		n = Sbwsize;
	}
	return 0;
}

/*
 * A packet to or from the firmware, over function 2.
 */
static int
packetrw(int write, uchar *buf, int len)
{
	int n, retry;

	n = 2048;
	while(len > 0){
		if(n > len)
			n = ROUND(len, 4);
		for(retry = 0; ; retry++){
			if(sdiorwext(Fn2, write, buf, n, Enumbase, 0) == 0)
				break;
			sdioabort(Fn2);
			if(retry == 2)
				return -1;
		}
		buf += n;
		len -= n;
	}
	return 0;
}

/*
 * Configuration and control of chip cores via the backplane
 */

static int
sbdisable(u32int regs, int pre, int ioctl)
{
	u32int v;
	int i;

	if(sbwindow(regs) < 0 || cfgreadl(Fn1, regs + Resetctrl, &v) < 0)
		return -1;
	if((v & 1) != 0){
		if(cfgwritel(Fn1, regs + Ioctrl, 3|ioctl) < 0 ||
		   cfgreadl(Fn1, regs + Ioctrl, &v) < 0)
			return -1;
		return 0;
	}
	if(cfgwritel(Fn1, regs + Ioctrl, 3|pre) < 0 ||
	   cfgreadl(Fn1, regs + Ioctrl, &v) < 0 ||
	   cfgwritel(Fn1, regs + Resetctrl, 1) < 0)
		return -1;
	microdelay(10);
	for(i = 0; ; i++){
		if(cfgreadl(Fn1, regs + Resetctrl, &v) < 0)
			return -1;
		if(v & 1)
			break;
		if(i == Sbpolls){
			print("ether4330: core %ux would not disable\n", regs);
			return -1;
		}
		microdelay(10);
	}
	if(cfgwritel(Fn1, regs + Ioctrl, 3|ioctl) < 0 ||
	   cfgreadl(Fn1, regs + Ioctrl, &v) < 0)
		return -1;
	return 0;
}

static int
sbreset(u32int regs, int pre, int ioctl)
{
	u32int v;
	int i;

	if(sbdisable(regs, pre, ioctl) < 0)
		return -1;
	if(sbwindow(regs) < 0)
		return -1;
	for(i = 0; ; i++){
		if(cfgreadl(Fn1, regs + Resetctrl, &v) < 0)
			return -1;
		if((v & 1) == 0)
			break;
		if(i == Sbpolls){
			print("ether4330: core %ux would not leave reset\n", regs);
			return -1;
		}
		if(cfgwritel(Fn1, regs + Resetctrl, 0) < 0)
			return -1;
		microdelay(40);
	}
	if(cfgwritel(Fn1, regs + Ioctrl, 1|ioctl) < 0 ||
	   cfgreadl(Fn1, regs + Ioctrl, &v) < 0)
		return -1;
	return 0;
}

/*
 * Walk the enumeration ROM for the cores the upload needs: the ARM,
 * its RAM, the SDIO core, the 802.11 core and chipcommon. A static
 * buffer, because this runs at boot before anything else has asked
 * the allocator for memory and there is no reason to be the first.
 */
static int
corescan(Ctlr *ctl, u32int r)
{
	static uchar buf[Corescansz];
	int i, coreid, corerev;
	u32int addr;

	if(sbmem(0, buf, Corescansz, r) < 0)
		return -1;
	coreid = 0;
	corerev = 0;
	for(i = 0; i < Corescansz; i += 4){
		switch(buf[i]&0xF){
		case 0xF:	/* end */
			return 0;
		case 0x1:	/* core info */
			if((buf[i+4]&0xF) != 0x1)
				break;
			coreid = (buf[i+1] | buf[i+2]<<8) & 0xFFF;
			i += 4;
			corerev = buf[i+3];
			break;
		case 0x05:	/* address */
			addr = buf[i+1]<<8 | buf[i+2]<<16 | (u32int)buf[i+3]<<24;
			addr &= ~0xFFF;
			if(SBDEBUG) print("core %x %s %ux\n", coreid, buf[i]&0xC0? "ctl" : "mem", addr);
			switch(coreid){
			case 0x800:
				if((buf[i] & 0xC0) == 0)
					ctl->chipcommon = addr;
				break;
			case ARMcm3:
			case ARM7tdmi:
			case ARMcr4:
				ctl->armcore = coreid;
				if(buf[i] & 0xC0){
					if(ctl->armctl == 0)
						ctl->armctl = addr;
				}else{
					if(ctl->armregs == 0)
						ctl->armregs = addr;
				}
				break;
			case 0x80E:
				if(buf[i] & 0xC0)
					ctl->socramctl = addr;
				else if(ctl->socramregs == 0)
					ctl->socramregs = addr;
				ctl->socramrev = corerev;
				break;
			case 0x829:
				if((buf[i] & 0xC0) == 0)
					ctl->sdregs = addr;
				ctl->sdiorev = corerev;
				break;
			case 0x812:
				if(buf[i] & 0xC0)
					ctl->d11ctl = addr;
				break;
			}
		}
	}
	return 0;
}

/*
 * How much RAM the firmware is uploaded into, and where it starts.
 */
static int
ramscan(Ctlr *ctl)
{
	u32int r, n, size;
	int banks, i;

	if(ctl->armcore == ARMcr4){
		r = ctl->armregs;
		if(sbwindow(r) < 0 || cfgreadl(Fn1, r + Cr4Cap, &n) < 0)
			return -1;
		if(SBDEBUG) print("cr4 banks %ux\n", n);
		banks = ((n>>4) & 0xF) + (n & 0xF);
		size = 0;
		for(i = 0; i < banks; i++){
			if(cfgwritel(Fn1, r + Cr4Bankidx, i) < 0 ||
			   cfgreadl(Fn1, r + Cr4Bankinfo, &n) < 0)
				return -1;
			if(SBDEBUG) print("bank %d reg %ux size %ud\n", i, n, 8192 * ((n & 0x3F) + 1));
			size += 8192 * ((n & 0x3F) + 1);
		}
		ctl->socramsize = size;
		ctl->rambase = 0x198000;
		return 0;
	}
	if(ctl->socramrev <= 7 || ctl->socramrev == 12){
		print("ether4330: SOCRAM rev %d not supported\n", ctl->socramrev);
		return -1;
	}
	if(sbreset(ctl->socramctl, 0, 0) < 0)
		return -1;
	r = ctl->socramregs;
	if(sbwindow(r) < 0 || cfgreadl(Fn1, r + Coreinfo, &n) < 0)
		return -1;
	if(SBDEBUG) print("socramrev %d coreinfo %ux\n", ctl->socramrev, n);
	banks = (n>>4) & 0xF;
	size = 0;
	for(i = 0; i < banks; i++){
		if(cfgwritel(Fn1, r + Bankidx, i) < 0 ||
		   cfgreadl(Fn1, r + Bankinfo, &n) < 0)
			return -1;
		if(SBDEBUG) print("bank %d reg %ux size %ud\n", i, n, 8192 * ((n & 0x3F) + 1));
		size += 8192 * ((n & 0x3F) + 1);
	}
	ctl->socramsize = size;
	ctl->rambase = 0;
	if(ctl->chipid == 43430){
		if(cfgwritel(Fn1, r + Bankidx, 3) < 0 ||
		   cfgwritel(Fn1, r + Bankpda, 0) < 0)
			return -1;
	}
	return 0;
}

/*
 * Identify the chip, find its cores, hold the ARM, size the RAM and
 * bring the backplane clock up. Runs at boot, so it reports through
 * the uart and returns -1 rather than erroring.
 */
static int
sbinit(Ctlr *ctl)
{
	u32int r, v;
	int chipid, i;

	if(sbwindow(Enumbase) < 0 || cfgreadl(Fn1, Enumbase, &r) < 0){
		bootsay("backplane does not answer", 0, -1);
		return -1;
	}
	chipid = r & 0xFFFF;
	switch(chipid){
	case 0x4330:
	case 43362:
	case 43430:
	case 0x4345:
		ctl->chipid = chipid;
		ctl->chiprev = (r>>16)&0xF;
		break;
	default:
		bootsay("chip not supported: id", chipid, 1);
		return -1;
	}
	uartputstr("ether4330: chip ");	/* uartputx prints its own 0x */
	uartputx(chipid);
	uartputstr(" rev ");
	uartputd(ctl->chiprev);
	uartputstr(" type ");
	uartputd((r>>28)&0xF);
	uartputstr("\n");

	if(cfgreadl(Fn1, Enumbase + 63*4, &r) < 0 || corescan(ctl, r) < 0){
		bootsay("core scan failed", 0, -1);
		return -1;
	}
	if(ctl->armctl == 0 || ctl->d11ctl == 0 ||
	   (ctl->armcore == ARMcm3 && (ctl->socramctl == 0 || ctl->socramregs == 0))){
		bootsay("core scan did not find the essential cores", 0, -1);
		return -1;
	}
	if(ctl->armcore == ARMcr4)
		i = sbreset(ctl->armctl, Cr4Cpuhalt, Cr4Cpuhalt);
	else
		i = sbdisable(ctl->armctl, 0, 0);
	if(i < 0 || sbreset(ctl->d11ctl, 8|4, 4) < 0){
		bootsay("cannot hold the ARM and reset the 802.11 core", 0, -1);
		return -1;
	}
	if(ramscan(ctl) < 0){
		bootsay("RAM scan failed", 0, -1);
		return -1;
	}
	if(SBDEBUG) print("ARM %ux D11 %ux SOCRAM %ux,%ux %ud bytes @ %ux\n",
		ctl->armctl, ctl->d11ctl, ctl->socramctl, ctl->socramregs, ctl->socramsize, ctl->rambase);
	if(cfgw(Clkcsr, 0) < 0)
		return -1;
	microdelay(10);
	if(cfgw(Clkcsr, Nohwreq | ReqALP) < 0)
		return -1;
	for(i = 0; ; i++){
		v = cfgr(Clkcsr);
		if(v >= 0 && (v & (HTavail|ALPavail)))
			break;
		if(i == Sbpolls){
			bootsay("backplane clock never came", 0, -1);
			return -1;
		}
		microdelay(10);
	}
	if(cfgw(Clkcsr, Nohwreq | ForceALP) < 0)
		return -1;
	microdelay(65);
	if(cfgw(Pullups, 0) < 0 ||
	   sbwindow(ctl->chipcommon) < 0 ||
	   cfgwritel(Fn1, ctl->chipcommon + Gpiopullup, 0) < 0 ||
	   cfgwritel(Fn1, ctl->chipcommon + Gpiopulldown, 0) < 0)
		return -1;
	if(ctl->chipid != 0x4330 && ctl->chipid != 43362)
		return 0;
	if(cfgwritel(Fn1, ctl->chipcommon + Chipctladdr, 1) < 0 ||
	   cfgreadl(Fn1, ctl->chipcommon + Chipctladdr, &v) < 0)
		return -1;
	if(v != 1)
		print("ether4330: can't set Chipctladdr\n");
	else{
		if(cfgreadl(Fn1, ctl->chipcommon + Chipctldata, &r) < 0)
			return -1;
		/* set SDIO drive strength >= 6mA */
		r &= ~0x3800;
		if(ctl->chipid == 0x4330)
			r |= 3<<11;
		else
			r |= 7<<11;
		if(cfgwritel(Fn1, ctl->chipcommon + Chipctldata, r) < 0)
			return -1;
	}
	return 0;
}

/*
 * From here on, the attach path: a process, a scheduler, error().
 */

static void
sbenable(Ctlr *ctl)
{
	int i;

	if(SBDEBUG) print("enabling HT clock...");
	cfgw(Clkcsr, 0);
	pause(1);
	cfgw(Clkcsr, ReqHT);
	for(i = 0; sdiobit(Fn1, Clkcsr, HTavail) == 0; i++){
		if(i == 50){
			print("ether4330: can't enable HT clock: csr %x\n", cfgr(Clkcsr));
			error("ether4330: no HT clock");
		}
		pause(100);
	}
	cfgw(Clkcsr, cfgr(Clkcsr) | ForceHT);
	pause(10);
	if(SBDEBUG) print("chipclk: %x\n", cfgr(Clkcsr));
	if(sbwindow(ctl->sdregs) < 0 ||
	   cfgwritel(Fn1, ctl->sdregs + Sbmboxdata, 4 << 16) < 0 ||	/* protocol version */
	   cfgwritel(Fn1, ctl->sdregs + Intmask, FrameInt | MailboxInt | Fcchange) < 0)
		error("ether4330: cannot set up the SDIO core");
	if(sdioset(Fn0, Ioenable, 1<<Fn2) < 0)
		error("ether4330: cannot enable function 2");
	for(i = 0; !sdiobit(Fn0, Ioready, 1<<Fn2); i++){
		if(i == Ioreadytries){
			print("ether4330: can't enable SDIO function 2 - ioready %x\n", sdiord(Fn0, Ioready));
			error("ether4330: function 2 never became ready");
		}
		pause(100);
	}
	if(sdiowr(Fn0, Intenable, (1<<Fn1) | (1<<Fn2) | 1) < 0)
		error("ether4330: cannot enable the card interrupt");
}

/*
 * Firmware and config file uploading
 */

/*
 * Condense config file contents (in buffer buf with length n)
 * to 'var=value\0' list for firmware:
 *	- remove comments (starting with '#') and blank lines
 *	- remove carriage returns
 *	- convert newlines to nulls
 *	- mark end with two nulls
 *	- pad with nulls to multiple of 4 bytes total length
 */
static int
condense(uchar *buf, int n)
{
	uchar *p, *ep, *lp, *op;
	int c, skipping;

	skipping = 0;	/* true if in a comment */
	ep = buf + n;	/* end of input */
	op = buf;	/* end of output */
	lp = buf;	/* start of current output line */
	for(p = buf; p < ep; p++){
		switch(c = *p){
		case '#':
			skipping = 1;
			break;
		case '\0':
		case '\n':
			skipping = 0;
			if(op != lp){
				*op++ = '\0';
				lp = op;
			}
			break;
		case '\r':
			break;
		default:
			if(!skipping)
				*op++ = c;
			break;
		}
	}
	if(!skipping && op != lp)
		*op++ = '\0';
	*op++ = '\0';
	for(n = op - buf; n & 03; n++)
		*op++ = '\0';
	return n;
}

/*
 * Upload one file into the dongle's RAM: the firmware from the base
 * up, the condensed config at the top with its length word to
 * follow. Then, with Firmwarecmp, read the whole of it back and
 * compare, because an upload that went wrong does not fail here, it
 * fails later as a firmware that never answers. Returns the number
 * of bytes uploaded.
 */
static int
upload(Ctlr *ctl, Chan *c, int isconfig)
{
	uchar *buf;
	uchar *cbuf;
	int off, n, total;

	buf = cbuf = nil;
	if(waserror()){
		free(buf);
		free(cbuf);
		nexterror();
	}
	buf = malloc(isconfig? Cfgmax : Uploadsz);
	if(buf == nil)
		error(Enomem);
	if(Firmwarecmp){
		cbuf = malloc(isconfig? Cfgmax : Uploadsz);
		if(cbuf == nil)
			error(Enomem);
	}
	off = 0;
	total = 0;
	for(;;){
		if(isconfig){
			/*
			 * The NVRAM text is condensed as a whole: a chunk
			 * boundary falls mid-line, and the first version
			 * condensed one 2048-byte read of a 2074-byte file
			 * and dropped its last two settings -- which the
			 * read-back verify, comparing the upload with
			 * itself, could never see. Read it all, then condense.
			 */
			for(n = 0;;){
				int m;

				if(n >= Cfgmax)
					error("ether4330: NVRAM file too large");
				m = devtab[c->type]->read(c, buf+n, Cfgmax-n, n);
				if(m <= 0)
					break;
				n += m;
			}
			if(n <= 0)
				error("ether4330: NVRAM file is empty");
			n = condense(buf, n);
			off = ctl->socramsize - n - 4;
		}else{
			n = devtab[c->type]->read(c, buf, Uploadsz, off);
			if(n <= 0)
				break;
		}
		if(!isconfig && off == 0)
			memmove(ctl->resetvec.c, buf, sizeof(ctl->resetvec.c));
		while(n&3)
			buf[n++] = 0;
		if(sbmem(1, buf, n, ctl->rambase + off) < 0){
			print("ether4330: firmware write failed offset %d\n", off);
			error(Eio);
		}
		total += n;
		if(isconfig)
			break;
		off += n;
	}
	if(Firmwarecmp){
		if(FWDEBUG) print("compare...");
		if(!isconfig)
			off = 0;
		for(;;){
			if(!isconfig){
				n = devtab[c->type]->read(c, buf, Uploadsz, off);
				if(n <= 0)
					break;
				while(n&3)
					buf[n++] = 0;
			}
			if(sbmem(0, cbuf, n, ctl->rambase + off) < 0){
				print("ether4330: firmware read-back failed offset %d\n", off);
				error(Eio);
			}
			if(memcmp(buf, cbuf, n) != 0){
				print("ether4330: firmware load failed offset %d\n", off);
				error("ether4330: firmware did not read back");
			}
			if(isconfig)
				break;
			off += n;
		}
	}
	if(FWDEBUG) print("\n");
	poperror();
	free(buf);
	free(cbuf);
	return isconfig? n : total;
}

static void wlsetvar(Ctlr*, char*, void*, int);

/*
 * Upload regulatory file (.clm) to firmware.
 * Packet format is
 *	[2]flag [2]type [4]len [4]crc [len]data
 */
static void
reguload(Ctlr *ctl, Chan *c)
{
	uchar *buf;
	int off, n, flag;
	enum {
		Reguhdr = 2+2+4+4,
		Regusz	= 1400,
		Regutyp	= 2,
		Flagclm	= 1<<12,
		Firstpkt= 1<<1,
		Lastpkt	= 1<<2,
	};

	buf = nil;
	if(waserror()){
		free(buf);
		nexterror();
	}
	buf = malloc(Reguhdr+Regusz+1);
	if(buf == nil)
		error(Enomem);
	put2(buf+2, Regutyp);
	put2(buf+8, 0);
	off = 0;
	flag = Flagclm | Firstpkt;
	while((flag&Lastpkt) == 0){
		n = devtab[c->type]->read(c, buf+Reguhdr, Regusz+1, off);
		if(n <= 0)
			break;
		if(n == Regusz+1)
			--n;
		else{
			while(n&7)
				buf[Reguhdr+n++] = 0;
			flag |= Lastpkt;
		}
		put2(buf+0, flag);
		put4(buf+4, n);
		wlsetvar(ctl, "clmload", buf, Reguhdr + n);
		off += n;
		flag &= ~Firstpkt;
	}
	poperror();
	free(buf);
}

/*
 * Firmware, then NVRAM, then the length-and-checksum word the
 * firmware checks the NVRAM by, then release the ARM. The checksum
 * arithmetic is in u32int on purpose: the original's ulong was 32
 * bits and the result is what the dongle compares.
 */
static void
fwload(Ctlr *ctl)
{
	uchar buf[4];
	u32int n;
	int i, j;

	i = 0;
	while(firmware[i].chipid != ctl->chipid ||
		   firmware[i].chiprev != ctl->chiprev){
		if(++i == nelem(firmware)){
			print("ether4330: no firmware for chipid %x (%d) chiprev %d\n",
				ctl->chipid, ctl->chipid, ctl->chiprev);
			error("ether4330: no firmware known for this chip");
		}
	}
	ctl->regufile = firmware[i].regufile;
	cfgw(Clkcsr, ReqALP);
	for(j = 0; sdiobit(Fn1, Clkcsr, ALPavail) == 0; j++){
		if(j == Sbpolls)
			error("ether4330: ALP clock never came");
		microdelay(10);
	}
	memset(buf, 0, 4);
	if(sbmem(1, buf, 4, ctl->rambase + ctl->socramsize - 4) < 0)
		error("ether4330: cannot write the dongle's RAM");
	if(FWDEBUG) print("firmware load...");
	ctl->fwbytes = upload(ctl, ctl->fwchan[0], 0);
	print("ether4330: firmware %d bytes loaded, verified\n", ctl->fwbytes);
	if(FWDEBUG) print("config load...");
	n = upload(ctl, ctl->fwchan[1], 1);
	n /= 4;
	n = (n & 0xFFFF) | (~n << 16);
	put4(buf, n);
	if(sbmem(1, buf, 4, ctl->rambase + ctl->socramsize - 4) < 0)
		error("ether4330: cannot write the NVRAM length word");
	if(ctl->armcore == ARMcr4){
		if(sbwindow(ctl->sdregs) < 0 ||
		   cfgwritel(Fn1, ctl->sdregs + Intstatus, ~0) < 0)
			error("ether4330: cannot clear the SDIO core's interrupts");
		if(ctl->resetvec.i != 0){
			if(SBDEBUG) print("%ux\n", ctl->resetvec.i);
			if(sbmem(1, ctl->resetvec.c, sizeof(ctl->resetvec.c), 0) < 0)
				error("ether4330: cannot write the reset vector");
		}
		j = sbreset(ctl->armctl, Cr4Cpuhalt, 0);
	}else
		j = sbreset(ctl->armctl, 0, 0);
	if(j < 0)
		error("ether4330: cannot release the ARM");
}

/*
 * Communication of data and control packets
 */

/*
 * Wait for the dongle to say something: the card interrupt, then
 * the SDIO core's status word. A mailbox interrupt carries the
 * firmware's "ready"; a frame interrupt means a packet is waiting.
 */
static void
intwait1(Ctlr *ctlr, int wait)
{
	u32int ints, mbox;
	int i;

	for(;;){
		sdio->cardintr(wait);
		if(sbwindow(ctlr->sdregs) < 0)
			return;
		i = sdiord(Fn0, Intpend);
		if(i <= 0){
			pause(10);
			if(i < 0)
				return;
			continue;
		}
		if(cfgreadl(Fn1, ctlr->sdregs + Intstatus, &ints) < 0 ||
		   cfgwritel(Fn1, ctlr->sdregs + Intstatus, ints) < 0)
			return;
		if(0) print("INTS: (%x) %ux\n", i, ints);
		if(ints & MailboxInt){
			if(cfgreadl(Fn1, ctlr->sdregs + Hostmboxdata, &mbox) < 0)
				return;
			cfgwritel(Fn1, ctlr->sdregs + Sbmbox, 2);	/* ack */
			if(mbox & 0x8)
				print("ether4330: firmware ready\n");
		}
		if(ints & FrameInt)
			break;
	}
}

/*
 * tsleep() raises when the process is killed, and a kproc that
 * sleeps with no error label in place takes the longjmp into whatever
 * label was last pushed. Miller's version began the same way.
 */
static void
intwait(Ctlr *ctlr, int wait)
{
	if(waserror())
		return;
	intwait1(ctlr, wait);
	poperror();
}


static Block*
wlreadpkt(Ctlr *ctl)
{
	Block *b;
	Sdpcm *p;
	int len, lenck;

	b = allocb(2048);
	p = (Sdpcm*)b->wp;
	qlock(&ctl->pktlock);
	if(waserror()){
		qunlock(&ctl->pktlock);
		freeb(b);
		nexterror();
	}
	for(;;){
		if(packetrw(0, b->wp, sizeof(*p)) < 0)
			error(Eio);
		len = p->len[0] | p->len[1]<<8;
		if(len == 0){
			freeb(b);
			b = nil;
			break;
		}
		lenck = p->lenck[0] | p->lenck[1]<<8;
		if(lenck != (len ^ 0xFFFF) ||
		   len < (int)sizeof(*p) || len > 2048){
			print("ether4330: wlreadpkt error len %.4x lenck %.4x\n", len, lenck);
			cfgw(Framectl, Rfhalt);
			while(cfgr(Rfrmcnt+1) > 0)
				;
			while(cfgr(Rfrmcnt) > 0)
				;
			continue;
		}
		if(len > (int)sizeof(*p))
			if(packetrw(0, b->wp + sizeof(*p), len - sizeof(*p)) < 0)
				error(Eio);
		b->wp += len;
		break;
	}
	poperror();
	qunlock(&ctl->pktlock);
	return b;
}

static void bcmevent(Ctlr*, uchar*, int);

/*
 * The reader: one kproc, forever, taking packets off function 2.
 * Command responses wake wlcmd; events are decoded; data frames are
 * COUNTED AND DROPPED in this milestone -- the netif has nowhere to
 * put them yet, and delivering them is the next milestone's work.
 */
static void
rproc(void *a)
{
	Ether *edev;
	Ctlr *ctl;
	Block *b;
	Sdpcm *p;
	Cmd *q;
	int bdc;

	edev = a;
	ctl = edev->ctlr;
	for(;;){
		if(waserror()){
			print("ether4330: reader: %s\n", up->env->errstr);
			/* the pause can itself raise (a kill); it needs its own label */
			if(!waserror()){
				pause(1000);
				poperror();
			}
			continue;
		}
		b = wlreadpkt(ctl);
		poperror();
		if(b == nil){
			intwait(ctl, 1);
			continue;
		}
		p = (Sdpcm*)b->rp;
		if(p->window != ctl->txwindow)
			ctl->txwindow = p->window;
		if(p->fcmask != ctl->fcmask)
			ctl->fcmask = p->fcmask;
		switch(p->chanflg & 0xF){
		case 0:
			if(iodebug) dump("rsp", b->rp, BLEN(b));
			if(BLEN(b) < (long)(sizeof(Sdpcm) + sizeof(Cmd)))
				break;
			q = (Cmd*)(b->rp + sizeof(*p));
			if((q->id[0] | q->id[1]<<8) != ctl->reqid)
				break;
			ctl->rsp = b;
			wakeup(&ctl->cmdr);
			continue;
		case 1:
			if(iodebug) dump("event", b->rp, BLEN(b));
			if(BLEN(b) > p->doffset + 4){
				bdc = 4 + (b->rp[p->doffset + 3] << 2);
				if(BLEN(b) > p->doffset + bdc){
					b->rp += p->doffset + bdc;	/* skip BDC header */
					bcmevent(ctl, b->rp, BLEN(b));
					break;
				}
			}
			if(iodebug && BLEN(b) != p->doffset)
				print("short event %ld %d\n", BLEN(b), p->doffset);
			break;
		case 2:
			if(iodebug) dump("packet", b->rp, BLEN(b));
			edev->nif.inpackets++;	/* seen, not delivered: milestone 4 */
			break;
		default:
			dump("ether4330: bad packet", b->rp, BLEN(b));
			break;
		}
		freeb(b);
	}
}

/*
 * Command interface between host and firmware
 */

static char *eventnames[] = {
	[0] = "set ssid",
	[1] = "join",
	[2] = "start",
	[3] = "auth",
	[4] = "auth ind",
	[5] = "deauth",
	[6] = "deauth ind",
	[7] = "assoc",
	[8] = "assoc ind",
	[9] = "reassoc",
	[10] = "reassoc ind",
	[11] = "disassoc",
	[12] = "disassoc ind",
	[13] = "quiet start",
	[14] = "quiet end",
	[15] = "beacon rx",
	[16] = "link",
	[17] = "mic error",
	[18] = "ndis link",
	[19] = "roam",
	[20] = "txfail",
	[21] = "pmkid cache",
	[22] = "retrograde tsf",
	[23] = "prune",
	[24] = "autoauth",
	[25] = "eapol msg",
	[26] = "scan complete",
	[27] = "addts ind",
	[28] = "delts ind",
	[29] = "bcnsent ind",
	[30] = "bcnrx msg",
	[31] = "bcnlost msg",
	[32] = "roam prep",
	[33] = "pfn net found",
	[34] = "pfn net lost",
	[35] = "reset complete",
	[36] = "join start",
	[37] = "roam start",
	[38] = "assoc start",
	[39] = "ibss assoc",
	[40] = "radio",
	[41] = "psm watchdog",
	[44] = "probreq msg",
	[45] = "scan confirm ind",
	[46] = "psk sup",
	[47] = "country code changed",
	[48] = "exceeded medium time",
	[49] = "icv error",
	[50] = "unicast decode error",
	[51] = "multicast decode error",
	[52] = "trace",
	[53] = "bta hci event",
	[54] = "if",
	[55] = "p2p disc listen complete",
	[56] = "rssi",
	[57] = "pfn scan complete",
	[58] = "extlog msg",
	[59] = "action frame",
	[60] = "action frame complete",
	[61] = "pre assoc ind",
	[62] = "pre reassoc ind",
	[63] = "channel adopted",
	[64] = "ap started",
	[65] = "dfs ap stop",
	[66] = "dfs ap resume",
	[67] = "wai sta event",
	[68] = "wai msg",
	[69] = "escan result",
	[70] = "action frame off chan complete",
	[71] = "probresp msg",
	[72] = "p2p probreq msg",
	[73] = "dcs request",
	[74] = "fifo credit map",
	[75] = "action frame rx",
	[76] = "wake event",
	[77] = "rm complete",
	[78] = "htsfsync",
	[79] = "overlay req",
	[80] = "csa complete ind",
	[81] = "excess pm wake event",
	[82] = "pfn scan none",
	[83] = "pfn scan allgone",
	[84] = "gtk plumbed",
	[85] = "assoc ind ndis",
	[86] = "reassoc ind ndis",
	[87] = "assoc req ie",
	[88] = "assoc resp ie",
	[89] = "assoc recreated",
	[90] = "action frame rx ndis",
	[91] = "auth req",
	[92] = "tdls peer event",
	[127] = "bcmc credit support"
};

static char*
evstring(uint event)
{
	static char buf[12];

	if(event >= nelem(eventnames) || eventnames[event] == 0){
		/* not reentrant but only called from one kproc */
		snprint(buf, sizeof buf, "%d", event);
		return buf;
	}
	return eventnames[event];
}

/*
 * Events from the firmware. Nothing is joined in this milestone, so
 * nothing here changes state; what it does is name an event that
 * carries an error, which is what a board test will want to see.
 */
static void
bcmevent(Ctlr *ctl, uchar *p, int len)
{
	int flags;
	long event, status, reason;

	USED(ctl);
	if(len < ETHERHDRSIZE + 10 + 46)
		return;
	p += ETHERHDRSIZE + 10;			/* skip bcm_ether header */
	len -= ETHERHDRSIZE + 10;
	flags = nhgets(p + 2);
	event = nhgets(p + 6);
	status = nhgetl(p + 8);
	reason = nhgetl(p + 12);
	if(EVENTDEBUG)
		print("ether4330: [%s] status %ld flags %#x reason %ld\n",
			evstring(event), status, flags, reason);
	switch(event){
	case 26:	/* E_SCAN_COMPLETE */
	case 69:	/* E_ESCAN_RESULT */
	case 16:	/* E_LINK */
		break;
	default:
		if(status){
			if(!EVENTDEBUG)
				print("ether4330: [%s] error status %ld flags %#x reason %ld\n",
					evstring(event), status, flags, reason);
			dump("event", p, len);
		}
	}
}

static int
cmddone(void *a)
{
	return ((Ctlr*)a)->rsp != nil;
}

/*
 * One command to the firmware and its answer. Bounded: a dongle that
 * took its firmware and then says nothing is an error after five
 * seconds, not a process stuck in the kernel for ever.
 */
static void
wlcmd(Ctlr *ctl, int write, int op, void *data, int dlen, void *res, int rlen)
{
	Block *b;
	Sdpcm *p;
	Cmd *q;
	int len, tlen;

	if(write)
		tlen = dlen + rlen;
	else
		tlen = MAX(dlen, rlen);
	len = sizeof(Sdpcm) + sizeof(Cmd) + tlen;
	b = allocb(len);
	qlock(&ctl->cmdlock);
	if(waserror()){
		freeb(b);
		qunlock(&ctl->cmdlock);
		nexterror();
	}
	memset(b->wp, 0, len);
	qlock(&ctl->pktlock);
	p = (Sdpcm*)b->wp;
	put2(p->len, len);
	put2(p->lenck, ~len);
	p->seq = ctl->txseq;
	p->doffset = sizeof(Sdpcm);
	b->wp += sizeof(*p);

	q = (Cmd*)b->wp;
	put4(q->cmd, op);
	put4(q->len, tlen);
	put2(q->flags, write? 2 : 0);
	put2(q->id, ++ctl->reqid);
	put4(q->status, 0);
	b->wp += sizeof(*q);

	if(dlen > 0)
		memmove(b->wp, data, dlen);
	if(write)
		memmove(b->wp + dlen, res, rlen);
	b->wp += tlen;

	if(iodebug) dump("cmd", b->rp, len);
	if(packetrw(1, b->rp, len) < 0){
		qunlock(&ctl->pktlock);
		error("ether4330: cannot send a command to the firmware");
	}
	ctl->txseq++;
	qunlock(&ctl->pktlock);
	freeb(b);
	b = nil;
	USED(b);
	tsleep(&ctl->cmdr, cmddone, ctl, Cmdtimeout);
	b = ctl->rsp;
	ctl->rsp = nil;
	if(b == nil){
		print("ether4330: no answer to cmd %d\n", op);
		error("ether4330: firmware does not answer");
	}
	p = (Sdpcm*)b->rp;
	q = (Cmd*)(b->rp + p->doffset);
	if(q->status[0] | q->status[1] | q->status[2] | q->status[3]){
		print("ether4330: cmd %d error status %ud\n", op, get4(q->status));
		dump("ether4330: cmd error", b->rp, BLEN(b));
		freeb(b);
		error("ether4330: firmware refused a command");
	}
	if(!write)
		memmove(res, q + 1, rlen);
	freeb(b);
	qunlock(&ctl->cmdlock);
	poperror();
}

static void
wlcmdint(Ctlr *ctl, int op, int val)
{
	uchar buf[4];

	put4(buf, val);
	wlcmd(ctl, 1, op, buf, 4, nil, 0);
}

static void
wlgetvar(Ctlr *ctl, char *name, void *val, int len)
{
	wlcmd(ctl, 0, GetVar, name, strlen(name) + 1, val, len);
}

static void
wlsetvar(Ctlr *ctl, char *name, void *val, int len)
{
	if(VARDEBUG){
		char buf[32];
		snprint(buf, sizeof buf, "wlsetvar %s:", name);
		dump(buf, val, len);
	}
	wlcmd(ctl, 1, SetVar, name, strlen(name) + 1, val, len);
}

static void
wlsetint(Ctlr *ctl, char *name, int val)
{
	uchar buf[4];

	put4(buf, val);
	wlsetvar(ctl, name, buf, 4);
}

/*
 * The dongle up: read its MAC address, set the constants the
 * firmware wants set before it is any use, bring it UP and ask what
 * version it is. Miller's wlinit, minus the WEP key it seeds for a
 * later join.
 */
static void
wlinit(Ether *edev, Ctlr *ctlr)
{
	uchar ea[Eaddrlen];
	uchar eventmask[16];
	char *p;
	static uchar keepalive[12] = {1, 0, 11, 0, 0xd8, 0xd6, 0, 0, 0, 0, 0, 0};

	wlgetvar(ctlr, "cur_etheraddr", ea, Eaddrlen);
	memmove(edev->ea, ea, Eaddrlen);
	memmove(edev->nif.addr, ea, Eaddrlen);
	edev->nif.alen = Eaddrlen;
	memset(edev->nif.bcast, 0xFF, Eaddrlen);
	print("ether4330: addr %E\n", edev->ea);
	wlsetint(ctlr, "assoc_listen", 10);
	if(ctlr->chipid == 43430 || ctlr->chipid == 0x4345)
		wlcmdint(ctlr, 0x56, 0);	/* powersave off */
	else
		wlcmdint(ctlr, 0x56, 2);	/* powersave FAST */
	wlsetint(ctlr, "bus:txglom", 0);
	wlsetint(ctlr, "bcn_timeout", 10);
	wlsetint(ctlr, "assoc_retry_max", 3);
	if(ctlr->chipid == 0x4330){
		wlsetint(ctlr, "btc_wire", 4);
		wlsetint(ctlr, "btc_mode", 1);
		wlsetvar(ctlr, "mkeep_alive", keepalive, 11);
	}
	memset(eventmask, 0xFF, sizeof eventmask);
#define ENABLE(n)	eventmask[n/8] |= 1<<(n%8)
#define DISABLE(n)	eventmask[n/8] &= ~(1<<(n%8))
	DISABLE(40);	/* E_RADIO */
	DISABLE(44);	/* E_PROBREQ_MSG */
	DISABLE(54);	/* E_IF */
	DISABLE(71);	/* E_PROBRESP_MSG */
	DISABLE(20);	/* E_TXFAIL */
	DISABLE(124);	/* ? */
	wlsetvar(ctlr, "event_msgs", eventmask, sizeof eventmask);
	wlcmdint(ctlr, 0xb9, 0x28);	/* SET_SCAN_CHANNEL_TIME */
	wlcmdint(ctlr, 0xbb, 0x28);	/* SET_SCAN_UNASSOC_TIME */
	wlcmdint(ctlr, 0x102, 0x82);	/* SET_SCAN_PASSIVE_TIME */
	wlcmdint(ctlr, 2, 0);		/* UP */
	memset(ctlr->ver, 0, sizeof ctlr->ver);
	wlgetvar(ctlr, "ver", ctlr->ver, sizeof ctlr->ver - 1);
	if((p = strchr(ctlr->ver, '\n')) != nil)
		*p = '\0';
	print("ether4330: %s\n", ctlr->ver);
	wlsetint(ctlr, "roam_off", 1);
	wlcmdint(ctlr, 0x14, 1);	/* SET_INFRA 1 */
	wlcmdint(ctlr, 10, 0);		/* SET_PROMISC */
	wlcmdint(ctlr, 2, 1);		/* UP */
}

/*
 * The devether interface
 */

/*
 * Bring the dongle up, in the process that bound #l1. Idempotent:
 * a second bind finds it up and does nothing; a bind after a failed
 * one -- the firmware was not on the card yet -- tries the upload
 * again, which is what makes "copy the files, bind again" a
 * recovery rather than a reboot.
 */
static void
etherbcmattach(Ether *edev)
{
	Ctlr *ctl;

	ctl = edev->ctlr;
	qlock(&ctl->alock);
	if(waserror()){
		qunlock(&ctl->alock);
		nexterror();
	}
	/*
	 * Attaching proves a radio is there and nothing more. The
	 * firmware is not loaded here because the kernel does not know
	 * where it is: the files are named by whoever writes
	 * "firmware <bin> <nvram> <clm>" to the ctl file, and opened in
	 * that writer's namespace. Until then ifstats says "not loaded".
	 */
	if(!ctl->present)
		error("ether4330: no radio");
	qunlock(&ctl->alock);
	poperror();
}

static void
closefw(Ctlr *ctl)
{
	int i;

	for(i = 0; i < nelem(ctl->fwchan); i++){
		if(ctl->fwchan[i] != nil)
			cclose(ctl->fwchan[i]);
		ctl->fwchan[i] = nil;
	}
}

/*
 * Load the named firmware, NVRAM and regulatory files and bring the
 * dongle up. Called with alock held and the three Chans open.
 */
static void
bringup(Ether *edev)
{
	Ctlr *ctl;

	ctl = edev->ctlr;
	fwload(ctl);
	sbenable(ctl);
	if(!ctl->reader){
		kproc("wifireader", rproc, edev, 0);
		ctl->reader = 1;
	}
	if(ctl->fwchan[2] != nil)
		reguload(ctl, ctl->fwchan[2]);
	wlinit(edev, ctl);
	ctl->running = 1;
	edev->nif.link = 0;	/* up is not associated */
}

/*
 * The ctl verbs. "firmware <bin> <nvram> <clm>" names the three files
 * the dongle needs, as paths in the WRITER's namespace -- the same
 * trick devether's bind verb uses -- so the kernel carries no path
 * and whoever mounted the card says where they are.
 */
static long
etherbcmctl(Ether *edev, void *a, long n)
{
	Ctlr *ctl;
	Cmdbuf *cb;
	int i;

	ctl = edev->ctlr;
	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf == 4 && strcmp(cb->f[0], "firmware") == 0){
		if(!ctl->present)
			error("ether4330: no radio");
		qlock(&ctl->alock);
		if(waserror()){
			closefw(ctl);
			qunlock(&ctl->alock);
			nexterror();
		}
		if(ctl->running)
			error("ether4330: firmware already running");
		for(i = 0; i < 3; i++)
			ctl->fwchan[i] = namec(cb->f[1+i], Aopen, OREAD, 0);
		bringup(edev);
		closefw(ctl);
		poperror();
		qunlock(&ctl->alock);
	}else
		error(Ebadctl);
	poperror();
	free(cb);
	return n;
}

/*
 * What a reader of /net/ether1/ifstats sees. "status:" is the line a
 * supplicant will poll; it can only say unassociated until there is
 * a join.
 */
static long
etherbcmifstat(Ether *edev, void *a, long n, ulong offset)
{
	Ctlr *ctl;
	char *p;
	int l;

	ctl = edev->ctlr;
	p = malloc(512);
	if(p == nil)
		error(Enomem);
	l = 0;
	l += snprint(p+l, 512-l, "radio: %s\n", ctl->present? "present" : "absent");
	if(ctl->present)
		l += snprint(p+l, 512-l, "chip: %#ux rev %d\n", ctl->chipid, ctl->chiprev);
	l += snprint(p+l, 512-l, "firmware: %s\n", ctl->running? ctl->ver : "not loaded");
	if(ctl->running)
		l += snprint(p+l, 512-l, "firmware bytes: %d\n", ctl->fwbytes);
	l += snprint(p+l, 512-l, "status: unassociated\n");
	USED(l);
	n = readstr(offset, a, n, p);
	free(p);
	return n;
}

static void
etherbcmshutdown(Ether *edev)
{
	Ctlr *ctl;

	ctl = edev->ctlr;
	if(ctl->present)
		sdioreset();
}

/*
 * Board init, after sdhost.c has the card: find the radio, or say in
 * one line that there is none, and register with devether either
 * way -- an absent radio makes #l1 refuse with "no radio" rather
 * than not exist, so the answer to "why is there no ether1" is in
 * the bind's error and the boot log both.
 *
 * With the card built onto the Arasan (-DSDCARD_ARASAN) the
 * controller is not free and the radio is not probed at all.
 */
void
ether4330probe(void)
{
	Ether *e;
	Ctlr *ctl;

	ctl = &ctlr4330;
	e = etherinstance(1);
	if(e == nil)
		return;
	e->ctlr = ctl;
	ctl->edev = e;
	e->attach = etherbcmattach;
	e->ifstat = etherbcmifstat;
	e->shutdown = etherbcmshutdown;
	e->ctl = etherbcmctl;
	/* transmit and ctl stay nil: no frames, no verbs, until milestone 4 */

#ifdef SDCARD_ARASAN
	bootsay("the Arasan holds the card (-DSDCARD_ARASAN), radio not probed", 0, -1);
	return;
#endif
	/*
	 * WL_REG_ON, the radio's power enable, is on the firmware's GPIO
	 * expander, not a BCM pin: pin 129 on the 3B+ (Linux's
	 * wifi_pwrseq, expgpio 1). The firmware normally leaves it on;
	 * asserting it here and giving the regulator its 150ms is what
	 * Linux does before the first CMD5, and costs nothing if it was
	 * already on.
	 */
	if(mboxsetgpio(Wlregon, 1) < 0)
		uartputstr("ether4330: WL_REG_ON: mailbox refused; trying anyway\n");
	microdelay(150000);
	booting = 1;
	if(sdioinit() < 0 || sbinit(ctl) < 0){
		booting = 0;
		return;
	}
	booting = 0;
	ctl->present = 1;
	uartputstr("ether4330: radio present, ");
	uartputd(ctl->socramsize / 1024);
	uartputstr(" KB of RAM; firmware loads when its files are named on ctl\n");
}
