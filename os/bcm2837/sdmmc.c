/*
 * The SD card, as blocks: the protocol half.
 *
 * Derived from Richard Miller's sdmmc.c in Plan 9 (sys/src/9/bcm,
 * Copyright © 2012 Richard Miller <r.miller@acm.org>, MIT): the
 * identification sequence, the raw-layout CSD parse and the SDio
 * split are his. Reduced to single-block transfers, return codes
 * instead of error(), and the five entry points devsd.c already used
 * when this protocol lived inside the Arasan driver.
 *
 * This file talks to a card and never to a register. What it needs
 * from a controller is the SDio vtable in board.h, and there are two
 * implementations of it -- sdhost.c and emmc.c -- because the SoC has
 * two controllers and the WiFi chip needs one of them. Keeping the
 * protocol here means the card can be moved between them by changing
 * one pointer, and means a CSD field is decoded in exactly one place.
 *
 * Still the mechanism half only: what is ON the card is policy and
 * belongs outside the kernel, the argument devsd.c makes.
 *
 * Polled throughout, for the reason the Arasan driver gave: the card
 * is read at boot and rarely afterwards, and a polled driver cannot
 * lose a wakeup.
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
	Sendcsd		= 9,
	Sendstatus	= 13,
	Setblocklen	= 16,
	Readsingle	= 17,
	Writesingle	= 24,
	Appcmd		= 55,
	Sdsendopcond	= 41,		/* ACMD41 */
	Setbuswidth	= 6,		/* ACMD6 */

	/* CMD8 argument: 2.7-3.6V and a pattern the card must echo */
	Ifcondarg	= 0x1AA,

	/* ACMD41 argument and OCR bits */
	Hcs		= 1<<30,	/* host understands high capacity */
	Ccs		= 1<<30,	/* card IS high capacity */
	Vddwindow	= 0x00FF8000,	/* 2.7-3.6V */
	Powerup		= 1<<31,	/* set means ready: NOT a busy bit */

	/* the card status word (R1) */
	Readyfordata	= 1<<8,

	Blocksize	= 512,
	Sdclk		= 25000000,	/* after identification */

	/*
	 * How long to wait and why it is bounded: this runs during boot,
	 * and a board that stops here stops before there is a console to
	 * ask what happened.
	 */
	Inittimeout	= 2000000,	/* 2s for the card to power up, in us */
	Writetimeout	= 1000000,	/* 1s for a written block to be programmed */
	Maxnocard	= 3,		/* consecutive dead commands = no card */
};

/*
 * Which controller.
 *
 * Chosen when the kernel is built, not when it boots, and that is the
 * honest option rather than the lazy one. A runtime choice would need
 * something to choose FROM: this port does not parse the device tree
 * or cmdline.txt (os/arm64/fns.h says so), and QEMU's raspi3b passes
 * a bare kernel8.img no device tree at all. It would also need a way
 * to switch back that behaves the same in both places, and there is
 * none -- returning the pins to the Arasan is ALT3 on the silicon but
 * function 0 under QEMU, whose mux recognises only those two settings
 * (hw/gpio/bcm2835_gpio.c), so a flip that passed the harness could
 * fail on the board or the reverse. One pointer, set here, and the
 * Arasan path kept buildable with -DSDCARD_ARASAN the way the other
 * single-purpose variants are.
 */
#ifdef SDCARD_ARASAN
static SDio *io = &emmcio;
#else
static SDio *io = &sdhostio;
#endif

static struct
{
	int	valid;		/* a card was found and initialised */
	int	hcs;		/* high capacity: addresses are blocks */
	u32int	rca;		/* the card's relative address */
	uvlong	nblocks;	/* 0 if unknown */
} card;

char*
sdcontroller(void)
{
	return io->name;
}

/*
 * A field of a 128-bit register held raw in four words, p[3] the most
 * significant, named by the bit numbers the specification uses. What
 * makes this worth a function is that the fields straddle words: C_SIZE
 * in a version 1 CSD is bits 73:62, two in one word and ten in the
 * next, and getting the halves the wrong way round once reported a
 * 64MB card as 30736MB.
 */
static u32int
rbits(u32int *p, int start, int len)
{
	u32int v;
	int w, off;

	w = start / 32;
	off = start % 32;
	v = p[w] >> off;
	if(off != 0 && w < 3)
		v |= p[w+1] << (32 - off);
	if(len < 32)
		v &= (1U << len) - 1;
	return v;
}

#define CSD(end, start)	rbits(csd, (start), (end)-(start)+1)

/*
 * The card's size from its CSD.
 *
 * Two encodings. Version 2 (high capacity) is C_SIZE+1 units of 512KB.
 * Version 1 is (C_SIZE+1) * 2^(C_SIZE_MULT+2) blocks of 2^READ_BL_LEN
 * bytes, and READ_BL_LEN need not be 9: QEMU reports 1024-byte blocks
 * for a small card, and the count is scaled to 512-byte blocks because
 * that is the only size the rest of the kernel moves.
 */
static void
identify(u32int *csd)
{
	u32int csz, mult, blen;

	blen = CSD(83, 80);			/* READ_BL_LEN */
	switch(CSD(127, 126)){			/* CSD_STRUCTURE */
	case 0:
		csz = CSD(73, 62);
		mult = CSD(49, 47);
		card.nblocks = ((uvlong)csz + 1) << (mult + 2);
		if(blen > 9)
			card.nblocks <<= blen - 9;
		break;
	case 1:
		csz = CSD(69, 48);
		card.nblocks = ((uvlong)csz + 1) * 1024;
		break;
	default:
		card.nblocks = 0;
		break;
	}
}

/*
 * An application command: CMD55 first, addressed to the card, then
 * the ACMD itself.
 */
static int
appcmd(int idx, u32int arg, int flags, u32int *resp)
{
	if(io->cmd(Appcmd, card.rca << 16, R48, nil) < 0)
		return -1;
	return io->cmd(idx, arg, flags, resp);
}

/*
 * Bring the controller and the card up. Returns 0 if there is a card.
 */
int
emmcinit(void)
{
	u32int resp[4];
	int i, ok, nofail;

	card.valid = 0;
	card.nblocks = 0;
	card.rca = 0;

	if(io->init() < 0)
		return -1;
	io->enable();

	if(io->cmd(Goidle, 0, Rnone, nil) < 0){
		uartputstr("sd: card will not go idle\n");
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
	if(io->cmd(Sendifcond, Ifcondarg, R48, resp) == 0)
		if((resp[0] & 0xFFF) == Ifcondarg)
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
		if(appcmd(Sdsendopcond, (ok? Hcs : 0) | Vddwindow, R48 | Rnocrc, resp) < 0){
			/*
			 * Give up quickly on a card that is not there.
			 *
			 * "Busy" and "absent" both present as ACMD41 not
			 * reporting ready, but they differ in whether the
			 * command COMPLETES: a card powering up answers and
			 * says it is busy, an empty slot answers nothing
			 * and every command times out. Retrying an empty
			 * slot for the full two seconds is time spent
			 * during boot on a certainty.
			 */
			if(++nofail >= Maxnocard){
				uartputstr("sd: no card in the slot\n");
				return -1;
			}
			microdelay(1000);
			continue;
		}
		nofail = 0;
		if(resp[0] & Powerup)
			break;
		microdelay(1000);
	}
	if((resp[0] & Powerup) == 0){
		uartputstr("sd: card never came ready\n");
		return -1;
	}
	card.hcs = (resp[0] & Ccs) != 0;

	if(io->cmd(Allsendcid, 0, R136, resp) < 0){
		uartputstr("sd: no CID\n");
		return -1;
	}
	if(io->cmd(Sendrelativeaddr, 0, R48, resp) < 0){
		uartputstr("sd: no relative address\n");
		return -1;
	}
	card.rca = resp[0] >> 16;

	/*
	 * The card's size, from the CSD, and it must be asked for HERE.
	 * SEND_CSD is only answered in the stand-by state -- after the
	 * card has an address and before it is selected -- so this sits
	 * between CMD3 and CMD7 rather than anywhere more convenient.
	 */
	if(io->cmd(Sendcsd, card.rca << 16, R136, resp) < 0){
		uartputstr("sd: no CSD\n");
		return -1;
	}
	identify(resp);

	if(io->cmd(Selectcard, card.rca << 16, R48busy, resp) < 0){
		uartputstr("sd: card will not select\n");
		return -1;
	}

	/* identification is over; run at a useful speed */
	io->bus(0, Sdclk);

	/*
	 * A standard-capacity card addresses BYTES and needs to be told
	 * the block length; a high-capacity one addresses BLOCKS and
	 * ignores this. Sending it either way is harmless and means the
	 * read path does not have to care which kind it has beyond the
	 * address it computes.
	 */
	if(io->cmd(Setblocklen, Blocksize, R48, resp) < 0){
		uartputstr("sd: cannot set block length\n");
		return -1;
	}

	/*
	 * Four-bit bus, and BOTH ends have to agree.
	 *
	 * Setting the controller's width without telling the card is
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
	if(appcmd(Setbuswidth, 2, R48, resp) == 0)
		io->bus(4, 0);
	else
		uartputstr("sd: card kept a 1-bit bus\n");

	card.valid = 1;

	uartputstr("sd: ");
	uartputstr(io->name);
	uartputstr(": card ready, ");
	uartputstr(card.hcs? "high capacity (block addressed), "
		: "standard capacity (byte addressed), ");
	uartputd(card.nblocks / 2048);
	uartputstr(" MB\n");
	return 0;
}

/*
 * A high-capacity card is addressed in BLOCKS and a standard-capacity
 * one in BYTES. Getting this backwards does not fail: it reads a
 * different, valid part of the card, which is far worse than an error.
 */
static u32int
blockaddr(uvlong blockno)
{
	return card.hcs? (u32int)blockno : (u32int)(blockno * Blocksize);
}

/*
 * Read one 512-byte block. Returns 0 on success.
 */
int
emmcread(uvlong blockno, void *a)
{
	if(!card.valid)
		return -1;

	io->iosetup(0, Blocksize, 1);
	if(io->cmd(Readsingle, blockaddr(blockno), R48 | Dread, nil) < 0){
		/*
		 * Which step failed is the whole diagnosis. The command
		 * not completing means the card never accepted the
		 * request; the data never arriving means it accepted it
		 * and the data lines are not working, which is a
		 * different fault with a different cause.
		 */
		uartputstr("sd: read command refused\n");
		return -1;
	}
	if(io->io(0, a, Blocksize) < 0){
		uartputstr("sd: no data from the card\n");
		return -1;
	}
	return 0;
}

/*
 * Write one 512-byte block. Returns 0 on success.
 *
 * The data leaving the FIFO is not the write being done: the card
 * takes it into a buffer and programs the flash afterwards, holding
 * DAT0 low meanwhile, and a command sent into that window is refused.
 * CMD13 asks the card itself rather than the controller, which makes
 * the wait correct on both controllers without either having to model
 * the card's busy line.
 */
int
emmcwrite(uvlong blockno, void *a)
{
	u32int resp[4];
	int i;

	if(!card.valid)
		return -1;

	io->iosetup(1, Blocksize, 1);
	if(io->cmd(Writesingle, blockaddr(blockno), R48 | Dwrite, nil) < 0){
		uartputstr("sd: write command refused\n");
		return -1;
	}
	if(io->io(1, a, Blocksize) < 0){
		uartputstr("sd: card did not take the data\n");
		return -1;
	}

	for(i = 0; i < Writetimeout; i += 100){
		if(io->cmd(Sendstatus, card.rca << 16, R48, resp) < 0)
			return -1;
		if(resp[0] & Readyfordata)
			return 0;
		microdelay(100);
	}
	uartputstr("sd: card stayed busy after a write\n");
	return -1;
}

int
emmcpresent(void)
{
	return card.valid;
}

uvlong
emmcnblocks(void)
{
	return card.nblocks;
}
