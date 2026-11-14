/*
 * #V -- the Pi 5's camera receiver: RP1's CSI-2 front end on either
 * CAM/DISP connector, serving the files ../bcm2711/devcam.c serves for
 * the Pi 4's Unicam, so camsrv(4) and what reads it are the same:
 *
 *	#V/unicam/ctl	"format W H", "power on|off", "stream on|off",
 *			"port 0|1" (the connector); reads back the same,
 *			"i2c i2cN" (the bus in #J of the sensor on that
 *			connector), and what the receiver saw
 *	#V/unicam/frame	an open waits for the next frame; reads return
 *			it, W*H samples of 16 bits, little-endian, row by
 *			row. One reader at a time.
 *
 * Mechanism and nothing else, as on the Pi 4: the connector's power,
 * the receiver's clock, its D-PHY and one CSI-2 channel writing frames
 * to memory. What is on the far end of the ribbon and how to program it
 * over I2C are camsrv's. A frame is RAW10 on two lanes at 900 Mbit/s a
 * lane (camsrv's Camera Module 3 mode); the channel's REMAP mode writes
 * each sample as 16 bits, its 10 bits at the top (RP1's SRGGB16, as
 * Linux's rp1-cfe asks for it), and they are moved to the bottom here,
 * as the Pi 4's Unicam leaves them, before a reader has the frame.
 *
 * From Linux's drivers/media/platform/raspberrypi/rp1_cfe (cfe.c,
 * csi2.c, dphy.c) and the Pi 5's device tree: each connector has its
 * CSI-2 block (DMA at +0, the DesignWare host and D-PHY at +0x4000, the
 * MIPI configuration at +0x10000 or +0x10000), RP1 interrupt 47 or 48,
 * a configuration clock from the 50 MHz crystal, the sensor's power on
 * an RP1 GPIO (34 or 46) and its I2C on i2c6 or i2c4. The PiSP front
 * end is not used.
 *
 * RP1 writes memory at its physical address (see etherrp1.c), below
 * 2 GB, through PCIe; frames are cached, invalidated before a reader has
 * one, as on the Pi 4.
 *
 * THREE BUFFERS: one being written, the newest complete, and the one a
 * reader is in. The channel double-buffers its address: one written at
 * a frame's start is taken for the next frame.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "board.h"

#define RP1(o)		(*(volatile u32int*)(uintptr)(RP1REGS + (o)))
#define CSI(o)		RP1(u.p->csi + (o))
#define HOST(o)		RP1(u.p->csi + 0x4000 + (o))
#define CFG(o)		RP1(u.p->cfg + (o))

enum
{
	/* clocks: RP1's clock generators */
	Clkbase		= 0x18000,
		Clkenable	= 1<<11,
		Clkauxsel	= 1,		/* the aux mux; its first source is the crystal */
	Xoschz		= 50000000,
	Cfghz		= 25000000,

	/* MIPI configuration */
	Mcfg		= 0x004,
		Mselcsi		= 1<<0,
	Mintr		= 0x028,
	Minte		= 0x02c,
	Mints		= 0x034,
		Mcsidma		= 1<<0,

	/* the CSI-2 DMA block */
	Cstatus		= 0x000,
	Cdovf		= 0x008,
	Cdinact		= 0x00c,
	Cdunmatch	= 0x010,
	Cdlen		= 0x014,
	Cirqmask	= 0x020,
	Cctrl		= 0x024,
		Ceopiseol	= 1<<0,
	Cchctrl		= 0x028,		/* channel 0's */
		Dmaen		= 1<<0,
		Force		= 1<<3,
		Irqenfs		= 1<<13,
		Irqenfeack	= 1<<15,
		Packline	= 1<<29,
		Moderemap	= 1<<1,
		Dtshift		= 7,
		Draw10		= 0x2B,
	Cchaddr0	= 0x02c,
	Cchstride	= 0x030,
	Cchlength	= 0x034,
	Cchdebug	= 0x038,
	Cchaddr1	= 0x03c,
	Cchframe	= 0x040,
		Irqfs		= 1<<0,
		Irqfe		= 1<<4,
		Irqfeack	= 1<<8,

	/* the DesignWare host and D-PHY */
	Hversion	= 0x000,
	Hlanes		= 0x004,
	Hresetn		= 0x008,
	Hshutdownz	= 0x040,
	Hrstz		= 0x044,
	Hstopstate	= 0x04c,
	Htst0		= 0x050,
	Htst1		= 0x054,
	Hsfreqrange	= 0x44,		/* the PHY's lane 0 HS receive control */

	Lanes		= 2,
	Mbps		= 900,		/* camsrv's: a 450 MHz clock, both edges */

	Nbuf		= 3,
	Maxbuf		= 8*1024*1024,
	Dmalimit	= 0x80000000,	/* RP1's own registers are above */
	Framems		= 1000,
	Powerms		= 20,		/* the sensor's start, from enable */
	Minoff		= 500,		/* ms off before on again, as on the Pi 4 */

	Qroot		= 0,
	Qdir,
	Qctl,
	Qframe,
};

typedef struct Port Port;
struct Port
{
	uintptr	csi;		/* RP1 offsets */
	uintptr	cfg;
	uintptr	clk;		/* its configuration clock's ctrl; div at +4, sel at +0xC */
	int	irq;		/* RP1 interrupt */
	int	enable;		/* the sensor's power, an RP1 GPIO */
	char	*i2c;		/* the sensor's bus, in #J */
};

static Port ports[2] = {
	{ 0x110000, 0x120000, Clkbase + 0xC4, 47, 34, "i2c6" },	/* CAM/DISP 0 */
	{ 0x128000, 0x138000, Clkbase + 0xD4, 48, 46, "i2c4" },	/* CAM/DISP 1 */
};

static Dirtab utab[] = {
	"ctl",		{Qctl},		0,	0660,
	"frame",	{Qframe},	0,	0440,
};

static struct {
	QLock	lk;		/* settings, and one reader of frame */
	Lock	ilk;		/* what the interrupt shares */
	Rendez	r;
	Port	*p;
	uchar	*buf[Nbuf];
	ulong	bufsz;
	int	w, h;
	int	power;
	ulong	offat;		/* when power went off, in ms; 0 never */
	int	on;
	int	reader;
	ulong	frames;
	int	cur, nxt, ready, busy, started;
	ulong	intrs, fs, fe;
	int	irqon[2];
	int	claimed[2];
} u = { .p = &ports[0] };

static void
setbuf(int b)
{
	uvlong a;

	a = (uvlong)PADDR(u.buf[b]) >> 4;
	CSI(Cchlength) = ((ulong)u.w*2*u.h) >> 4;
	CSI(Cchstride) = ((ulong)u.w*2) >> 4;
	CSI(Cchaddr1) = a >> 32;
	CSI(Cchaddr0) = a;		/* last: it arms the others */
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
	u32int sta;

	ilock(&u.ilk);
	u.intrs++;
	if((CFG(Mints) & Mcsidma) == 0){
		iunlock(&u.ilk);
		return;
	}
	sta = CSI(Cstatus);
	CSI(Cstatus) = sta;
	/* a frame's end first: the next one's start can be here with it */
	if((sta & Irqfeack) != 0 && u.started){
		u.fe++;
		u.ready = u.cur;
		u.frames++;
		u.started = 0;
		wakeup(&u.r);
	}
	if(sta & Irqfs){
		u.fs++;
		u.cur = u.nxt;
		u.nxt = pick();
		if(u.nxt >= 0)
			setbuf(u.nxt);
		u.started = 1;
	}
	iunlock(&u.ilk);
}

static void
cfgclock(int on)
{
	Port *p;

	p = u.p;
	RP1(p->clk) &= ~(u32int)Clkenable;
	if(!on)
		return;
	RP1(p->clk + 4) = Xoschz / Cfghz;	/* integer divider */
	RP1(p->clk) = Clkauxsel;
	USED(RP1(p->clk + 0xC));
	RP1(p->clk) |= Clkenable;
	microdelay(10);
}

static void
campower(int on)
{
	Port *p;
	int n;

	if(on == u.power)
		return;
	p = u.p;
	n = p - ports;
	if(on){
		if(!u.claimed[n]){
			if(gpioclaimed(p->enable) != nil)
				error("unicam: the connector's power pin is in use");
			gpioclaim(p->enable, "camera");
			u.claimed[n] = 1;
		}
		if(u.offat != 0){
			long w;

			w = Minoff - (long)(TK2MS(MACHP(0)->ticks) - u.offat);
			if(w > 0)
				tsleep(&up->sleep, return0, nil, w);
		}
		gpioout(p->enable, 1);
		gpiofunc(p->enable, Gpioout);
		tsleep(&up->sleep, return0, nil, Powerms);
		cfgclock(1);
	}else{
		cfgclock(0);
		gpioout(p->enable, 0);
		u.offat = TK2MS(MACHP(0)->ticks);
		if(u.offat == 0)
			u.offat = 1;
	}
	u.power = on;
}

/* the D-PHY's test interface: a code, then its data (the PHY's databook) */
static void
tstclk(int v)
{
	HOST(Htst0) = (HOST(Htst0) & ~2) | v<<1;
}

static void
tstclr(int v)
{
	HOST(Htst0) = (HOST(Htst0) & ~1) | v;
}

static void
testen(int v)
{
	HOST(Htst1) = (HOST(Htst1) & ~(1<<16)) | v<<16;
}

static void
testdin(int v)
{
	HOST(Htst1) = (HOST(Htst1) & ~0xFF) | v;
}

static void
phytest(int code, int data)
{
	tstclk(1);
	testen(0);
	testdin(code);
	testen(1);
	tstclk(0);
	testen(0);
	testdin(data);
	tstclk(1);
}

/* the PHY's HS receive range for a lane rate, its databook's Table 5-1 */
static int
hsfreqrange(int mbps)
{
	static ushort t[][2] = {
		{ 89, 0x00 }, { 99, 0x10 }, { 109, 0x20 }, { 129, 0x01 }, { 139, 0x11 }, { 149, 0x21 },
		{ 169, 0x02 }, { 179, 0x12 }, { 199, 0x22 }, { 219, 0x03 }, { 239, 0x13 }, { 249, 0x23 },
		{ 269, 0x04 }, { 299, 0x14 }, { 329, 0x05 }, { 359, 0x15 }, { 399, 0x25 }, { 449, 0x06 },
		{ 499, 0x16 }, { 549, 0x07 }, { 599, 0x17 }, { 649, 0x08 }, { 699, 0x18 }, { 749, 0x09 },
		{ 799, 0x19 }, { 849, 0x29 }, { 899, 0x39 }, { 949, 0x0A }, { 999, 0x1A }, { 1049, 0x2A },
		{ 1099, 0x3A }, { 1149, 0x0B }, { 1199, 0x1B }, { 1249, 0x2B }, { 1299, 0x3B }, { 1349, 0x0C },
		{ 1399, 0x1C }, { 1449, 0x2C }, { 1500, 0x3C },
	};
	int i;

	for(i = 0; i < nelem(t)-1; i++)
		if(mbps <= t[i][0])
			break;
	return t[i][1];
}

static void
phyon(void)
{
	HOST(Hlanes) = Lanes - 1;
	HOST(Hrstz) = 0;
	HOST(Hshutdownz) = 0;
	tstclk(1);
	testen(0);
	tstclr(1);
	microdelay(20);
	tstclr(0);
	microdelay(20);
	phytest(Hsfreqrange, hsfreqrange(Mbps) << 1);
	microdelay(10);
	HOST(Hshutdownz) = 1;
	microdelay(10);
	HOST(Hrstz) = 1;
	HOST(Hresetn) = ~0;
	microdelay(50);
}

static void
phyoff(void)
{
	HOST(Hlanes) = 0;
	HOST(Hresetn) = 0;
}

static void
start(void)
{
	int i, n;
	ulong sz;

	if(u.w == 0)
		error("unicam: no format");
	if(!u.power)
		error("unicam: not powered");
	sz = (ulong)u.w*2*u.h;
	if(sz > Maxbuf)
		error("unicam: frame too large");
	if(u.bufsz < sz){
		/* kernel memory, not given back: the first format's size, or a larger one's */
		if(u.bufsz != 0)
			error("unicam: a frame larger than the first needs a reboot");
		sz = (sz + BY2PG-1) & ~(BY2PG-1);
		for(i = 0; i < Nbuf; i++){
			u.buf[i] = xspanalloc(sz, BY2PG, 0);
			if(u.buf[i] == nil || PADDR(u.buf[i]) + sz > Dmalimit)
				error("unicam: no memory RP1 can reach for frames");
		}
		u.bufsz = sz;
		sz = (ulong)u.w*2*u.h;
	}
	for(i = 0; i < Nbuf; i++)
		cachedwbinvse(u.buf[i], u.bufsz);
	n = u.p - ports;
	if(!u.irqon[n]){
		rp1intrenable(u.p->irq, intr, nil, 1, "camera");
		u.irqon[n] = 1;
	}
	CFG(Mcfg) = Mselcsi;
	CFG(Minte) = Mcsidma;
	CSI(Cirqmask) = 0;
	phyon();
	CSI(Cctrl) = Ceopiseol;

	u.cur = u.nxt = 0;
	u.ready = u.busy = -1;
	u.started = 0;
	u.frames = u.intrs = u.fs = u.fe = 0;
	CSI(Cchctrl) = 0;
	CSI(Cchdebug) = 0;
	CSI(Cstatus) = Irqfs | Irqfe | Irqfeack | 1<<12 | 1<<16;
	CSI(Cchframe) = u.h<<16 | u.w;
	CSI(Cchctrl) = Dmaen | Irqenfs | Irqenfeack | Packline | Moderemap | Draw10<<Dtshift;
	setbuf(0);
	u.on = 1;
}

static void
stop(void)
{
	ilock(&u.ilk);
	CSI(Cchctrl) = Force;
	CSI(Cchaddr0) = 0;		/* latches the stop; twice, as Linux's driver does */
	CSI(Cchaddr0) = 0;
	phyoff();
	CSI(Cirqmask) = 0;
	CFG(Minte) = 0;
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

/*
 * The next frame, into u.busy, its samples moved from RP1's top 10 bits
 * of 16 to the bottom 10, where the Pi 4's are.
 */
static void
take(void)
{
	Since was;
	ushort *s, *e;

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
	s = (ushort*)u.buf[u.busy];
	for(e = s + (ulong)u.w*u.h; s < e; s++)
		*s >>= 6;
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
	char buf[640];
	long sz;
	int on;

	switch((ulong)c->qid.path){
	case Qroot:
	case Qdir:
		return devdirread(c, a, n, nil, 0, ugen);
	case Qctl:
		on = u.power;
		snprint(buf, sizeof buf,
			"format %d %d\npower %s\nstream %s\nport %ld\ni2c %s\n"
			"frames %lud\nstarts %lud\nends %lud\nintrs %lud\n"
			"csistatus %.8ux chdebug %.8ux chframe %.8ux discards %ud %ud %ud %ud\n"
			"phy %.8ux stopstate %.8ux clk %.8ux\n",
			u.w, u.h, on? "on": "off", u.on? "on": "off", u.p - ports, u.p->i2c,
			u.frames, u.fs, u.fe, u.intrs,
			on? CSI(Cstatus): 0, on? CSI(Cchdebug): 0, on? CSI(Cchframe): 0,
			on? CSI(Cdovf): 0, on? CSI(Cdinact): 0, on? CSI(Cdunmatch): 0, on? CSI(Cdlen): 0,
			on? HOST(Hversion): 0, on? HOST(Hstopstate): 0, RP1(u.p->clk));
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
	int w, h, p;

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
		if(w <= 0 || h <= 0 || w > 0xFFFF || h > 0xFFFF || (w*2 & 15) != 0 || (uvlong)w*2*h > Maxbuf)
			error(Ebadarg);
		u.w = w;
		u.h = h;
	}else if(cb->nf == 2 && strcmp(cb->f[0], "port") == 0){
		if(u.on || u.power)
			error("unicam: powered");
		p = strtol(cb->f[1], nil, 0);
		if(p < 0 || p >= nelem(ports))
			error(Ebadarg);
		u.p = &ports[p];
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
