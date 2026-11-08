/*
 * #V -- Unicam, the camera receiver on the board's CSI connector.
 *
 *	#V/unicam/ctl	"format W H", "power on|off", "stream on|off";
 *			reads back the same, with what the receiver saw
 *	#V/unicam/frame	an open waits for the next frame; reads return
 *			it, W*H samples of 16 bits, little-endian, row by
 *			row. One reader at a time.
 *
 * Mechanism and nothing else: power, clocks, lanes, memory, interrupt.
 * What is on the far end of the ribbon, how to program it over I2C,
 * and what to do with its samples are a program's (camsrv(4)). A frame
 * is RAW10 on two lanes of a non-continuous clock, the Camera Module
 * 3's, because those are what has been run; the receiver unpacks them,
 * and camsrv's frames arrive as 16-bit samples with no work here.
 *
 * THE CONNECTOR IS CSI1 to the chip: a two-lane Unicam at 0x7E801000,
 * GIC SPI 103, the firmware's power domain 13. The sensor's enable is
 * line 5 of the firmware's GPIO expander, driven here and not left to
 * #G because the desktop's namespace has no #G.
 *
 * THE FIRMWARE'S DOMAIN IS NOT ENOUGH. It powers the registers and not
 * the analogue side, which has its own regulator in the power manager;
 * without it the lanes are deaf, registers read back, the sensor
 * streams and nothing is received, not even a clock. Only the
 * high-power regulator: with the low-power one on as well there is
 * sync and no packets.
 *
 * THE SENSOR MUST STAY OFF A WHILE. Off and on again within a few
 * milliseconds, a Camera Module 3 comes back half reset: it answers
 * I2C, takes every setting, reports itself streaming, and its frame
 * counter never moves. Measured on the bench: 30 cycles with 100 ms
 * off failed once, with 250 ms none. So power on waits until the
 * sensor has been off Mintoff ms, however soon a program asks.
 *
 * THREE BUFFERS: one being written, the newest complete, and the one a
 * reader is in, so the receiver always has one nobody is reading. The
 * next buffer is set at a frame's start and taken at the following one.
 *
 * PROVENANCE. Not a clean-room implementation. Broadcom publishes no
 * document for Unicam or for the camera's regulator, and the code is
 * this tree's, but the facts below were read from Linux drivers in
 * Raspberry Pi's tree (rpi-6.6.y): the Unicam register map, offsets and
 * bit fields, from drivers/media/platform/bcm2835/vc4-regs-unicam.h and
 * bcm2835-unicam.c (GPL-2.0-only); PM_CAM1 at 0x48 and its CTRLEN,
 * LDOLPEN and LDOHPEN bits from drivers/pmdomain/bcm/bcm2835-power.c
 * (GPL-2.0+); the firmware's domain 13 from
 * include/dt-bindings/power/raspberrypi-power.h (GPL-2.0). Where the
 * camera clock's registers (CM_CAM1CTL, CM_CAM1DIV) came from was not
 * recorded. That the domain alone leaves the lanes deaf, the low-power
 * regulator breaking packets, and the minimum off time are this tree's
 * own measurements.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/error.h"
#include "board.h"

#define R(o)	(*(volatile u32int*)((uintptr)UNICAMBASE + (o)))
#define PM(o)	(*(volatile u32int*)((uintptr)PMREGS + (o)))
#define CM(o)	(*(volatile u32int*)((uintptr)CMBASE + (o)))

enum
{
	UNICAMBASE	= PHYSIO + 0x801000,
	UNICAMGATE	= PHYSIO + 0x802004,
	CMBASE		= PHYSIO + 0x101000,

	IRQunicam	= IRQspi + 103,
	Camenable	= 128 + 5,
	Tagsetdomain	= 0x00038030,
	Domunicam1	= 13,

	Pmcam1		= 0x48,
		Pmctrlen	= 1<<0,
		Pmldolp		= 1<<1,
		Pmldohp		= 1<<2,

	Cmcam1ctl	= 0x48,
	Cmcam1div	= 0x4C,
	Cmpass		= 0x5A000000,
	Cmbusy		= 1<<7,
	Cmen		= 1<<4,
	Cmkill		= 1<<5,
	Cmplld		= 6,
	Cmdiv		= 8,		/* PLLD's 750 MHz to 94 MHz */

	Uctrl		= 0x000,
		Ucpe		= 1<<0,
		Umem		= 1<<1,
		Ucpr		= 1<<2,
		Usoe		= 1<<4,
		Upft		= 0xf<<8,
		Uoet		= 128<<12,
	Usta		= 0x004,
		Upi0		= 1<<15,
		Ustaall		= 0x1ffffff,
	Uana		= 0x008,
		Uar		= 1<<2,
		Uddl		= 1<<3,
		Uadj		= 7<<4 | 7<<8,
	Upri		= 0x00C,
		Uprival		= 1 | 2<<1 | 8<<4 | 0xe<<8,
	Uclk		= 0x010,
	Uclt		= 0x014,
	Udat0		= 0x018,
	Udat1		= 0x01C,
	Udlt		= 0x028,
		Ulane		= 1<<0 | 1<<2,	/* enable, low-power receiver */
	Ucmp0		= 0x02C,
		Ucmpfe		= 1<<31 | 1<<9 | 1<<8 | 1,	/* frame end: a short packet */
	Uictl		= 0x100,
		Ufsie		= 1<<0,
		Ufeie		= 1<<1,
		Uibob		= 1<<2,
		Ulip		= 1<<5,
	Uista		= 0x104,
		Ufsi		= 1<<0,
		Ufei		= 1<<1,
	Uidi0		= 0x108,
		Draw10		= 0x2B,
	Uipipe		= 0x10C,
		Uunpack10	= 4,
		Upack16		= 5<<7,
	Uibsa0		= 0x110,
	Uibea0		= 0x114,
	Uibls		= 0x118,
	Uihwin		= 0x120,
	Uivwin		= 0x128,
	Umisc		= 0x400,
		Ufl		= 1<<6 | 1<<9,

	Nbuf		= 3,
	Maxbuf		= 8*1024*1024,	/* the most a format may take: three fit the DMA arena's 32 MB */
	Framems		= 1000,
	Powerms		= 20,		/* the sensor's start, from enable */
	Minoff		= 500,		/* ms the sensor must be off before it is on again: twice what was seen to suffice */

	Qroot		= 0,
	Qdir,
	Qctl,
	Qframe,
};

static Dirtab utab[] = {
	"ctl",		{Qctl},		0,	0660,
	"frame",	{Qframe},	0,	0440,
};

static struct {
	QLock	lk;		/* settings, and one reader of frame */
	Lock	ilk;		/* what the interrupt shares */
	Rendez	r;
	uchar	*buf[Nbuf];
	ulong	bufsz;		/* what each of buf holds: the frame, to a page */
	int	w, h;
	int	power;
	ulong	offat;		/* when power went off, in ms of TK2MS(ticks); 0 never */
	int	on;
	int	reader;		/* frame is open */
	ulong	frames;
	int	cur, nxt, ready, busy, started;
	ulong	intrs, fs, fe;
	int	irqon;
} u;

static void
gate(u32int v)
{
	*(volatile u32int*)(uintptr)UNICAMGATE = Cmpass | v;
}

static void
setaddr(int b)
{
	uintptr a;

	a = BUSADDR(u.buf[b]);
	R(Uibsa0) = a;
	R(Uibea0) = a + u.w*2*u.h;
}

static int
pick(void)
{
	int i, spare;

	spare = -1;
	for(i = 0; i < Nbuf; i++){
		if(i == u.cur || i == u.busy)
			continue;
		if(i != u.ready)
			return i;
		spare = i;
	}
	return spare;
}

static void
intr(Ureg*, void*)
{
	u32int sta, ista;

	ilock(&u.ilk);
	sta = R(Usta);
	R(Usta) = sta;
	ista = R(Uista);
	R(Uista) = ista;
	u.intrs++;
	/* a frame's end first: the next one's start can be here with it */
	if(((ista & Ufei) != 0 || (sta & Upi0) != 0) && u.started){
		u.fe++;
		u.ready = u.cur;
		u.frames++;
		u.started = 0;
		wakeup(&u.r);
	}
	if(ista & Ufsi){
		u.fs++;
		u.cur = u.nxt;
		u.nxt = pick();
		setaddr(u.nxt);
		u.started = 1;
	}
	iunlock(&u.ilk);
}

static void
clock(int on)
{
	int i;

	CM(Cmcam1ctl) = Cmpass | Cmplld | Cmkill;
	for(i = 0; i < 1000 && (CM(Cmcam1ctl) & Cmbusy); i++)
		microdelay(10);
	if(!on)
		return;
	CM(Cmcam1div) = Cmpass | Cmdiv<<12;
	CM(Cmcam1ctl) = Cmpass | Cmplld;
	CM(Cmcam1ctl) = Cmpass | Cmplld | Cmen;
	for(i = 0; i < 1000 && !(CM(Cmcam1ctl) & Cmbusy); i++)
		microdelay(10);
}

static void
ldo(int on)
{
	u32int v;

	v = PM(Pmcam1) & 0xFFFFFF & ~(Pmctrlen|Pmldolp|Pmldohp);
	if(on){
		PM(Pmcam1) = Cmpass | v | Pmctrlen;
		microdelay(100);
		PM(Pmcam1) = Cmpass | v | Pmctrlen | Pmldohp;
		microdelay(100);
	}else
		PM(Pmcam1) = Cmpass | v;
}

static void
domain(int on)
{
	u32int b[2];

	b[0] = Domunicam1;
	b[1] = on;
	if(mboxprop(Tagsetdomain, b, 2, 2) < 0)
		error("unicam: the firmware refused the receiver's power");
}

static void
campower(int on)
{
	if(on == u.power)
		return;
	if(on){
		if(u.offat != 0){
			long w;

			w = Minoff - (long)(TK2MS(MACHP(0)->ticks) - u.offat);
			if(w > 0)
				tsleep(&up->sleep, return0, nil, w);
		}
		mboxsetgpio(Camenable, 1);
		tsleep(&up->sleep, return0, nil, Powerms);
		domain(1);
		ldo(1);
		clock(1);
	}else{
		clock(0);
		ldo(0);
		domain(0);
		mboxsetgpio(Camenable, 0);
		u.offat = TK2MS(MACHP(0)->ticks);
		if(u.offat == 0)
			u.offat = 1;
	}
	u.power = on;
}

static void
start(void)
{
	int i;
	ulong sz;

	if(u.w == 0)
		error("unicam: no format");
	if(!u.power)
		error("unicam: not powered");
	sz = (ulong)u.w*2*u.h;
	if(sz > Maxbuf)
		error("unicam: frame too large");
	/* buffers of the frame's size: a format that needs more takes new ones */
	if(u.bufsz < sz){
		for(i = 0; i < Nbuf; i++)
			if(u.buf[i] != nil){
				dmafree(u.buf[i], u.bufsz);
				u.buf[i] = nil;
			}
		u.bufsz = 0;
		for(i = 0; i < Nbuf; i++){
			u.buf[i] = dmaalloc(((sz + BY2PG-1) & ~(BY2PG-1)), BY2PG);
			if(u.buf[i] == nil)
				error("unicam: no DMA memory for frames");
		}
		u.bufsz = ((sz + BY2PG-1) & ~(BY2PG-1));
	}
	for(i = 0; i < Nbuf; i++)
		cachedwbinvse(u.buf[i], sz);
	if(!u.irqon){
		intrenable(IRQunicam, intr, nil, 0, "unicam");
		u.irqon = 1;
	}
	gate(1<<4 | 1<<2 | 1);		/* the clock lane and both data lanes */
	R(Uctrl) = Umem;
	R(Uana) = Uar | Uadj;
	microdelay(1500);
	R(Uana) &= ~Uar;
	R(Uctrl) |= Ucpr;
	R(Uctrl) &= ~Ucpr;
	R(Uctrl) &= ~Ucpe;
	R(Uctrl) = (R(Uctrl) & ~(1<<3 | 1<<5)) | Upft | Uoet;	/* CSI-2, strobe */
	R(Uihwin) = 0;
	R(Uivwin) = 0;
	R(Upri) = Uprival;
	R(Uana) &= ~Uddl;
	R(Uictl) = Ufsie | Ufeie | Uibob;
	R(Usta) = Ustaall;
	R(Uista) = Ufsi | Ufei | 1<<2;
	R(Uclt) = 2 | 6<<8;
	R(Udlt) = 2 | 6<<8;
	R(Uctrl) &= ~Usoe;
	R(Ucmp0) = Ucmpfe;
	R(Uclk) = Ulane;
	R(Udat0) = Ulane;
	R(Udat1) = Ulane;
	R(Uibls) = u.w*2;
	u.cur = u.nxt = 0;
	u.ready = u.busy = -1;
	u.started = 0;
	u.frames = u.intrs = u.fs = u.fe = 0;
	setaddr(0);
	R(Uipipe) = Uunpack10 | Upack16;
	R(Uidi0) = Draw10;
	R(Umisc) |= Ufl;
	R(Uctrl) |= Ucpe;
	R(Uictl) |= Ulip;
	u.on = 1;
}

static void
stop(void)
{
	ilock(&u.ilk);
	R(Uana) |= Uddl;
	R(Uctrl) |= Usoe;
	R(Udat0) = 0;
	R(Udat1) = 0;
	R(Uctrl) |= Ucpr;
	microdelay(100);
	R(Uctrl) &= ~Ucpr;
	R(Uctrl) &= ~Ucpe;
	R(Uictl) = 0;
	gate(0);
	u.on = 0;
	wakeup(&u.r);
	iunlock(&u.ilk);
}

typedef struct Since Since;
struct Since
{
	ulong	n;
};

static int
newframe(void *a)
{
	return u.frames != ((Since*)a)->n || !u.on;
}

/* the next frame, into u.busy */
static void
take(void)
{
	Since was;

	was.n = u.frames;
	tsleep(&u.r, newframe, &was, Framems);
	if(!u.on)
		error("unicam: stopped");
	if(!newframe(&was))
		error("unicam: no frame");
	ilock(&u.ilk);
	u.busy = u.ready;
	iunlock(&u.ilk);
	cachedwbinvse(u.buf[u.busy], (ulong)u.w*2*u.h);
}

static int
ugen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;

	USED(name, tab, ntab);
	if(s == DEVDOTDOT){
		if((ulong)c->qid.path == Qdir || (ulong)c->qid.path == Qroot){
			mkqid(&q, Qroot, 0, QTDIR);
			devdir(c, q, "#V", 0, eve, DMDIR|0555, dp);
		}else{
			mkqid(&q, Qdir, 0, QTDIR);
			devdir(c, q, "unicam", 0, eve, DMDIR|0555, dp);
		}
		return 1;
	}
	if((ulong)c->qid.path == Qroot){
		if(s != 0)
			return -1;
		mkqid(&q, Qdir, 0, QTDIR);
		devdir(c, q, "unicam", 0, eve, DMDIR|0555, dp);
		return 1;
	}
	if(s < 0 || s >= nelem(utab))
		return -1;
	devdir(c, utab[s].qid, utab[s].name, 0, eve, utab[s].perm, dp);
	return 1;
}

static Chan*
uattach(char *spec)
{
	return devattach('V', spec);
}

static Walkqid*
uwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, ugen);
}

static int
ustat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, ugen);
}

static Chan*
uopen(Chan *c, int omode)
{
	int path;

	path = (ulong)c->qid.path;
	c = devopen(c, omode, nil, 0, ugen);
	if(path == Qframe){
		qlock(&u.lk);
		if(waserror()){
			c->flag &= ~COPEN;
			qunlock(&u.lk);
			nexterror();
		}
		if(u.reader)
			error(Einuse);
		if(!u.on)
			error("unicam: not streaming");
		take();
		u.reader = 1;
		poperror();
		qunlock(&u.lk);
	}
	return c;
}

static void
uclose(Chan *c)
{
	if((c->flag & COPEN) == 0 || (ulong)c->qid.path != Qframe)
		return;
	ilock(&u.ilk);
	u.busy = -1;
	iunlock(&u.ilk);
	u.reader = 0;
}

static long
uread(Chan *c, void *a, long n, vlong off)
{
	char buf[256];
	long sz;

	switch((ulong)c->qid.path){
	case Qroot:
	case Qdir:
		return devdirread(c, a, n, nil, 0, ugen);
	case Qctl:
		snprint(buf, sizeof buf, "format %d %d\npower %s\nstream %s\nframes %lud\nstarts %lud\nends %lud\nintrs %lud\npmcam1 %.8ux\n",
			u.w, u.h, u.power? "on": "off", u.on? "on": "off", u.frames, u.fs, u.fe, u.intrs, PM(Pmcam1));
		return readstr(off, a, n, buf);
	case Qframe:
		sz = (long)u.w*2*u.h;
		if(off >= sz || u.busy < 0)
			return 0;
		if(n > sz - off)
			n = sz - off;
		memmove(a, u.buf[u.busy] + off, n);
		return n;
	}
	error(Egreg);
	return 0;
}

static long
uwrite(Chan *c, void *a, long n, vlong)
{
	Cmdbuf *cb;
	int w, h;

	if((ulong)c->qid.path != Qctl)
		error(Eperm);
	cb = parsecmd(a, n);
	qlock(&u.lk);
	if(waserror()){
		qunlock(&u.lk);
		free(cb);
		nexterror();
	}
	if(cb->nf == 3 && strcmp(cb->f[0], "format") == 0){
		if(u.on)
			error("unicam: streaming");
		w = strtol(cb->f[1], nil, 0);
		h = strtol(cb->f[2], nil, 0);
		if(w <= 0 || h <= 0 || (w*2 & 15) != 0 || (uvlong)w*2*h > Maxbuf)
			error(Ebadarg);
		u.w = w;
		u.h = h;
	}else if(cb->nf == 2 && strcmp(cb->f[0], "power") == 0){
		if(u.on)
			error("unicam: streaming");
		campower(strcmp(cb->f[1], "on") == 0);
	}else if(cb->nf == 2 && strcmp(cb->f[0], "stream") == 0){
		if(strcmp(cb->f[1], "on") == 0){
			if(!u.on)
				start();
		}else if(u.on)
			stop();
	}else
		error(Ebadarg);
	poperror();
	qunlock(&u.lk);
	free(cb);
	return n;
}

Dev camdevtab = {
	'V',
	"cam",

	devreset,
	devinit,
	devshutdown,
	uattach,
	uwalk,
	ustat,
	uopen,
	devcreate,
	uclose,
	uread,
	devbread,
	uwrite,
	devbwrite,
	devremove,
	devwstat,
};
