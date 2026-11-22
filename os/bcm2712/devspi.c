/*
 * #Q -- SPI: RP1's SPI0 on the header, a polled master.
 *
 *	#Q/spi0, #Q/spi1	a write is one transfer with chip select 0 or 1
 *				(GPIO 8, 7) held low; a read returns what came
 *				back during the last one
 *	#Q/spictl		write "clock HZ", "mode 0-3", "loop 0|1"; read them
 *
 * The reading of a transfer back comes from 9 pi's devspi, whose files
 * these are, as SPI's full duplex needs some such thing.
 *
 * MOSI is GPIO 10, MISO 9, SCLK 11. The chip selects are plain GPIO, as
 * Linux drives them too: the block's own lets go of the device whenever
 * its FIFO runs dry. "loop 1" joins the block's output to its input,
 * inside the chip.
 *
 * The pins become SPI's at the first open, and stay it.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"board.h"

#define R(o)	(*(volatile u32int*)(uintptr)(RP1REGS + 0x50000 + (o)))

enum{
	Maxio		= 8192,
	Inflight	= 8,		/* no more than the FIFO holds */
	Patience	= 100000,	/* 10us polls without progress: a second */
	Sysclock	= 200000000,

	Ctrlr0		= 0x00,
		Dfs8		= 7 | 7<<16,	/* the field's two places; which is real depends on the build */
		Scph		= 1<<6,
		Scpol		= 1<<7,
		Srl		= 1<<11,
	Ssienr		= 0x08,
	Ser		= 0x10,
	Baudr		= 0x14,
	Rxflr		= 0x24,
	Sr		= 0x28,
		Busy		= 1<<0,
		Tfnf		= 1<<1,
		Rfne		= 1<<3,
	Imr		= 0x2C,
	Datareg		= 0x60,

	Sclk		= 11,
	Mosi		= 10,
	Miso		= 9,
	Ce0		= 8,
	Ce1		= 7,
};

static struct
{
	QLock	lk;
	int	on;
	int	clock;
	int	mode;
	int	loop;
	int	n;		/* of buf: what the last transfer read */
	uchar	buf[Maxio];
} spi = {
	.clock = 1000000,
};

enum{
	Qdir,
	Qspi0,
	Qspi1,
	Qctl,
};

static Dirtab spitab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"spi0",		{Qspi0},		0,	0664,
	"spi1",		{Qspi1},		0,	0664,
	"spictl",	{Qctl},			0,	0664,
};

static void
setup(void)
{
	u32int c;
	int div;

	R(Ssienr) = 0;
	R(Imr) = 0;
	c = Dfs8;
	if(spi.mode & 1)
		c |= Scph;
	if(spi.mode & 2)
		c |= Scpol;
	if(spi.loop)
		c |= Srl;
	R(Ctrlr0) = c;
	div = Sysclock / spi.clock;
	if(Sysclock % spi.clock)
		div++;
	div = (div + 1) & ~1;		/* even, and at least two */
	if(div < 2)
		div = 2;
	if(div > 65534)
		div = 65534;
	R(Baudr) = div;
	R(Ser) = 1;
}

static void
spion(void)
{
	static int pins[] = { Sclk, Mosi, Miso, Ce0, Ce1 };
	int i;

	if(spi.on)
		return;
	for(i = 0; i < nelem(pins); i++)
		if(gpioclaimed(pins[i]) != nil)
			error("spi: pins in use");
	for(i = 0; i < nelem(pins); i++)
		gpioclaim(pins[i], "spi");
	gpioout(Ce0, 1);
	gpioout(Ce1, 1);
	gpiofunc(Ce0, Gpioout);
	gpiofunc(Ce1, Gpioout);
	gpiofunc(Sclk, Gpioalt0);
	gpiofunc(Mosi, Gpioalt0);
	gpiofunc(Miso, Gpioalt0);
	setup();
	spi.on = 1;
}

/* n bytes both ways, nil or what went wrong */
static char*
transfer(int ce, uchar *w, int n)
{
	int sent, got, idle;
	char *err;

	err = nil;
	sent = got = idle = 0;
	gpioout(ce, 0);
	R(Ssienr) = 1;
	while(got < n){
		idle++;
		if(sent < n && sent - got < Inflight && (R(Sr) & Tfnf) != 0){
			R(Datareg) = w[sent++];
			idle = 0;
		}
		if(R(Sr) & Rfne){
			spi.buf[got++] = R(Datareg);
			idle = 0;
		}
		if(idle > Patience){
			err = "spi: timed out";
			break;
		}
		if(idle > 16)
			microdelay(10);
	}
	while(err == nil && (R(Sr) & Busy) != 0 && idle++ < Patience)
		microdelay(10);
	R(Ssienr) = 0;
	gpioout(ce, 1);
	spi.n = got;
	return err;
}

static Chan*
spiattach(char *spec)
{
	return devattach('Q', spec);
}

static Walkqid*
spiwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, spitab, nelem(spitab), devgen);
}

static int
spistat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, spitab, nelem(spitab), devgen);
}

static Chan*
spiopen(Chan *c, int omode)
{
	c = devopen(c, omode, spitab, nelem(spitab), devgen);
	if((ulong)c->qid.path != Qdir){
		qlock(&spi.lk);
		if(waserror()){
			qunlock(&spi.lk);
			c->flag &= ~COPEN;
			nexterror();
		}
		spion();
		qunlock(&spi.lk);
		poperror();
	}
	return c;
}

static void
spiclose(Chan *c)
{
	USED(c);
}

static long
spiread(Chan *c, void *a, long n, vlong off)
{
	char buf[64];

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, spitab, nelem(spitab), devgen);
	case Qctl:
		snprint(buf, sizeof buf, "clock %d mode %d loop %d\n", spi.clock, spi.mode, spi.loop);
		return readstr(off, a, n, buf);
	}
	qlock(&spi.lk);
	if(off >= spi.n)
		n = 0;
	else{
		if(n > spi.n - off)
			n = spi.n - off;
		memmove(a, spi.buf + off, n);
	}
	qunlock(&spi.lk);
	return n;
}

static long
spictl(char *a, long n)
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
	qlock(&spi.lk);
	if(strcmp(cb->f[0], "clock") == 0 && v >= Sysclock/65534 && v <= Sysclock/2)
		spi.clock = v;
	else if(strcmp(cb->f[0], "mode") == 0 && v <= 3)
		spi.mode = v;
	else if(strcmp(cb->f[0], "loop") == 0 && v <= 1)
		spi.loop = v;
	else{
		qunlock(&spi.lk);
		error(Ebadctl);
	}
	setup();
	qunlock(&spi.lk);
	poperror();
	free(cb);
	return n;
}

static long
spiwrite(Chan *c, void *a, long n, vlong off)
{
	char *err;

	USED(off);
	switch((ulong)c->qid.path){
	case Qdir:
		error(Eperm);
	case Qctl:
		return spictl(a, n);
	}
	if(n > Maxio)
		error(Etoobig);
	if(n <= 0)
		return 0;
	qlock(&spi.lk);
	err = transfer((ulong)c->qid.path == Qspi0 ? Ce0 : Ce1, a, n);
	qunlock(&spi.lk);
	if(err != nil)
		error(err);
	return n;
}

Dev spidevtab = {
	'Q',
	"spi",

	devreset,
	devinit,
	devshutdown,
	spiattach,
	spiwalk,
	spistat,
	spiopen,
	devcreate,
	spiclose,
	spiread,
	devbread,
	spiwrite,
	devbwrite,
	devremove,
	devwstat,
};
