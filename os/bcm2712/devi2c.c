/*
 * #J -- I2C, on the two buses the 40-pin header gives by convention:
 * i2c0 on GPIO 0 and 1, i2c1 on GPIO 2 and 3. RP1's are DesignWare
 * blocks, run here as a polled master, 7-bit addresses only.
 *
 *	#J/i2cNctl	write "addr N", "subaddress N", "speed N"; read them
 *	#J/i2cNdata	read and write the device at addr
 *
 * With subaddress N, a transfer starts with the file offset in N bytes,
 * high first, and a read is a repeated start after them: which is how
 * almost every register and EEPROM device is read, as in Inferno's #J.
 *
 * The pins become I2C's at the first open, and stay it. An address
 * nothing answers is an error, "no device"; that is how to scan a bus.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"board.h"

enum{
	Nbus		= 2,
	Maxio		= 4096,
	Rxdepth		= 8,		/* reads in flight, a FIFO's worth at least */
	Patience	= 100000,	/* 10us polls without progress: a second */

	Con		= 0x00,
		Conmaster	= 1<<0 | 1<<6,	/* and slave disabled */
		Constd		= 1<<1,
		Confast		= 2<<1,
		Conrestart	= 1<<5,
	Tar		= 0x04,
	Datacmd		= 0x10,
		Cmdread		= 1<<8,
		Cmdstop		= 1<<9,
		Cmdrestart	= 1<<10,
	Sshcnt		= 0x14,
	Sslcnt		= 0x18,
	Fshcnt		= 0x1C,
	Fslcnt		= 0x20,
	Intrmask	= 0x30,
	Rawintr		= 0x34,
		Inttxabrt	= 1<<6,
		Intstop		= 1<<9,
	Clrintr		= 0x40,
	Enable		= 0x6C,
	Status		= 0x70,
		Tfnf		= 1<<1,
	Rxflr		= 0x78,
	Abrtsource	= 0x80,
		Abrtaddr	= 1<<0,
		Abrtdata	= 1<<3,
		Abrtarb		= 1<<12,
	Enstatus	= 0x9C,

	/* counts of the 200MHz system clock: the block adds nothing to them */
	Stdhigh		= 950,		/* 4.75us, of a 4us minimum */
	Stdlow		= 1050,		/* 5.25us, of 4.7 */
	Fasthigh	= 200,		/* 1us, of 0.6 */
	Fastlow		= 300,		/* 1.5us, of 1.3 */
};

typedef struct Bus Bus;
struct Bus
{
	QLock	lk;
	uintptr	base;
	int	sda;
	int	scl;
	int	on;
	int	addr;
	int	sub;
	int	speed;
};

static Bus buses[Nbus] = {
	{ .base = RP1REGS + 0x70000, .sda = 0, .scl = 1, .addr = -1, .speed = 100000 },
	{ .base = RP1REGS + 0x74000, .sda = 2, .scl = 3, .addr = -1, .speed = 100000 },
};

#define R(b, o)	(*(volatile u32int*)((b)->base + (o)))

enum{
	Qdir,
	Qctl0,
	Qdata0,
	Qctl1,
	Qdata1,
};

static Dirtab i2ctab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"i2c0ctl",	{Qctl0},		0,	0664,
	"i2c0data",	{Qdata0},		0,	0664,
	"i2c1ctl",	{Qctl1},		0,	0664,
	"i2c1data",	{Qdata1},		0,	0664,
};

#define BUS(c)		(&buses[((ulong)(c)->qid.path - 1) / 2])
#define ISDATA(c)	(((ulong)(c)->qid.path - 1) & 1)

/* the block must be off for any of these */
static void
disable(Bus *b)
{
	int i;

	R(b, Enable) = 0;
	for(i = 0; i < 1000 && (R(b, Enstatus) & 1) != 0; i++)
		microdelay(10);
}

static void
setup(Bus *b)
{
	disable(b);
	R(b, Intrmask) = 0;
	R(b, Sshcnt) = Stdhigh;
	R(b, Sslcnt) = Stdlow;
	R(b, Fshcnt) = Fasthigh;
	R(b, Fslcnt) = Fastlow;
	R(b, Con) = Conmaster | Conrestart | (b->speed > 100000 ? Confast : Constd);
}

/* qlocked: the pins and the block, once */
static void
buson(Bus *b)
{

	if(b->on)
		return;
	if(gpioclaimed(b->sda) != nil || gpioclaimed(b->scl) != nil)
		error("i2c: pins in use");
	gpioclaim(b->sda, "i2c");
	gpioclaim(b->scl, "i2c");
	gpiopull(b->sda, Pullup);
	gpiopull(b->scl, Pullup);
	gpiofunc(b->sda, Gpioalt3);
	gpiofunc(b->scl, Gpioalt3);
	setup(b);
	b->on = 1;
}

/*
 * nw bytes out, then nr in, in one transaction; nil, or what went wrong.
 * Every command goes in by hand, the last with the stop bit, which is
 * how Linux drives these too: a block built to hold the bus when its
 * FIFO empties sends no stop of its own.
 */
static char*
transfer(Bus *b, uchar *w, int nw, uchar *r, int nr)
{
	int sent, got, total, idle;
	u32int cmd, src;
	char *err;

	disable(b);
	R(b, Tar) = b->addr;
	R(b, Enable) = 1;
	R(b, Clrintr);

	err = nil;
	total = nw + nr;
	sent = got = idle = 0;
	while(sent < total || got < nr){
		if(R(b, Rawintr) & Inttxabrt)
			break;
		idle++;
		if(sent < total && (R(b, Status) & Tfnf) != 0 && (sent < nw || sent - nw - got < Rxdepth)){
			if(sent < nw)
				cmd = w[sent];
			else{
				cmd = Cmdread;
				if(sent == nw && nw != 0)
					cmd |= Cmdrestart;
			}
			if(sent == total-1)
				cmd |= Cmdstop;
			R(b, Datacmd) = cmd;
			sent++;
			idle = 0;
		}
		if(got < nr && R(b, Rxflr) != 0){
			r[got++] = R(b, Datacmd);
			idle = 0;
		}
		if(idle > Patience){
			err = "i2c: timed out";
			break;
		}
		if(idle != 0)
			microdelay(10);
	}
	for(idle = 0; err == nil && (R(b, Rawintr) & (Intstop|Inttxabrt)) == 0; idle++){
		if(idle > Patience)
			err = "i2c: no stop";
		microdelay(10);
	}
	if(R(b, Rawintr) & Inttxabrt){
		src = R(b, Abrtsource);
		if(src & Abrtaddr)
			err = "no device";
		else if(src & Abrtdata)
			err = "i2c: data not acknowledged";
		else if(src & Abrtarb)
			err = "i2c: arbitration lost";
		else
			err = "i2c: aborted";
	}
	R(b, Clrintr);
	disable(b);
	return err;
}

static int
offsetbytes(Bus *b, uchar *p, vlong off)
{
	int i;

	for(i = 0; i < b->sub; i++)
		p[i] = off >> 8*(b->sub-1-i);
	return b->sub;
}

static Chan*
i2cattach(char *spec)
{
	return devattach('J', spec);
}

static Walkqid*
i2cwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, i2ctab, nelem(i2ctab), devgen);
}

static int
i2cstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, i2ctab, nelem(i2ctab), devgen);
}

static Chan*
i2copen(Chan *c, int omode)
{
	Bus *b;

	c = devopen(c, omode, i2ctab, nelem(i2ctab), devgen);
	if((ulong)c->qid.path != Qdir){
		b = BUS(c);
		qlock(&b->lk);
		if(waserror()){
			qunlock(&b->lk);
			c->flag &= ~COPEN;
			nexterror();
		}
		buson(b);
		qunlock(&b->lk);
		poperror();
	}
	return c;
}

static void
i2cclose(Chan *c)
{
	USED(c);
}

static long
i2cread(Chan *c, void *a, long n, vlong off)
{
	Bus *b;
	uchar sub[4];
	char buf[64], *err;
	int ns;

	if((ulong)c->qid.path == Qdir)
		return devdirread(c, a, n, i2ctab, nelem(i2ctab), devgen);
	b = BUS(c);
	if(!ISDATA(c)){
		snprint(buf, sizeof buf, "addr %#x subaddress %d speed %d\n", b->addr, b->sub, b->speed);
		return readstr(off, a, n, buf);
	}
	if(n <= 0)
		return 0;
	if(n > Maxio)
		n = Maxio;
	qlock(&b->lk);
	if(b->addr < 0){
		qunlock(&b->lk);
		error("i2c: no addr set");
	}
	ns = offsetbytes(b, sub, off);
	err = transfer(b, sub, ns, a, n);
	qunlock(&b->lk);
	if(err != nil)
		error(err);
	return n;
}

static long
i2cctl(Bus *b, char *a, long n)
{
	Cmdbuf *cb;
	ulong v;

	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf != 2)
		error(Ebadctl);
	v = strtoul(cb->f[1], nil, 0);
	qlock(&b->lk);
	if(strcmp(cb->f[0], "addr") == 0 && v < 0x80)
		b->addr = v;
	else if(strcmp(cb->f[0], "subaddress") == 0 && v <= 4)
		b->sub = v;
	else if(strcmp(cb->f[0], "speed") == 0 && (v == 100000 || v == 400000)){
		b->speed = v;
		setup(b);
	}else{
		qunlock(&b->lk);
		error(Ebadctl);
	}
	qunlock(&b->lk);
	poperror();
	free(cb);
	return n;
}

static long
i2cwrite(Chan *c, void *a, long n, vlong off)
{
	Bus *b;
	uchar *p;
	char *err;
	int ns;

	if((ulong)c->qid.path == Qdir)
		error(Eperm);
	b = BUS(c);
	if(!ISDATA(c))
		return i2cctl(b, a, n);
	if(n > Maxio)
		error(Etoobig);
	if(n <= 0)
		return 0;
	p = smalloc(n + 4);
	qlock(&b->lk);
	if(b->addr < 0){
		qunlock(&b->lk);
		free(p);
		error("i2c: no addr set");
	}
	ns = offsetbytes(b, p, off);
	memmove(p+ns, a, n);
	err = transfer(b, p, ns+n, nil, 0);
	qunlock(&b->lk);
	free(p);
	if(err != nil)
		error(err);
	return n;
}

Dev i2cdevtab = {
	'J',
	"i2c",

	devreset,
	devinit,
	devshutdown,
	i2cattach,
	i2cwalk,
	i2cstat,
	i2copen,
	devcreate,
	i2cclose,
	i2cread,
	devbread,
	i2cwrite,
	devbwrite,
	devremove,
	devwstat,
};
