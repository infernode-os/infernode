/*
 * #J -- the Pi 4's camera and display I2C: BSC0, on GPIO 44 and 45 at
 * ALT1, the bus on the board's two ribbon connectors.
 *
 *	#J/i2c0ctl	write "addr N", "subaddress N"; read them
 *	#J/i2c0data	read and write the device at addr
 *
 * EACH OPEN OF i2c0data TAKES addr AND subaddress AS THEY ARE THEN, and
 * keeps them: a program holds an open for each device it talks to, and
 * another program setting ctl afterwards cannot redirect it. Only the
 * moment between a ctl write and the open is shared, as it must be with
 * one ctl file.
 *
 * With subaddress N, a transfer starts with the file offset in N bytes,
 * high first, as in Inferno's #J and ../bcm2712/devi2c.c. A read writes
 * the offset, stops, and reads: this block has no dependable repeated
 * start, and register devices take a read at the current address.
 *
 * An address nothing answers is an error, "no device"; that is how to
 * scan a bus. Polled, one transfer at a time.
 *
 * THE FIRMWARE USES THIS BUS TOO, when a DSI panel is attached, to poll
 * its touch controller, and there is no way to take turns. A transfer
 * can fail, and a read or a write can be silently wrong. That is said
 * here rather than hidden, because what to do about it (retry, read a
 * write back) is the program's, which knows what the data means.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/error.h"
#include "board.h"

#define I(o)	(*(volatile u32int*)((uintptr)BSCBASE + (o)))

enum
{
	BSCBASE		= PHYSIO + 0x205000,
	Pinsda		= 44,
	Pinscl		= 45,
	Fsalt1		= 5,

	Ic		= 0x00,
		Icen		= 1<<15,
		Icst		= 1<<7,
		Icclear		= 3<<4,
		Icread		= 1<<0,
	Is		= 0x04,
		Isclkt		= 1<<9,
		Iserr		= 1<<8,
		Isrxd		= 1<<5,
		Istxd		= 1<<4,
		Isdone		= 1<<1,
	Idlen		= 0x08,
	Ia		= 0x0C,
	Ififo		= 0x10,
	Idiv		= 0x14,
	Iclkt		= 0x1C,

	Hz		= 400000,
	Maxio		= 4096,
	Patience	= 10000,	/* polls of 10us without progress: 100 ms */
	Maxsub		= 4,

	Qroot		= 0,
	Qctl,
	Qdata,
};

static Dirtab i2ctab[] = {
	".",		{Qroot, 0, QTDIR},	0,	0555,
	"i2c0ctl",	{Qctl},			0,	0660,
	"i2c0data",	{Qdata},		0,	0660,
};

typedef struct Dev1 Dev1;
struct Dev1
{
	int	addr;
	int	sub;
};

static struct {
	QLock	lk;
	int	setup;
	int	addr;		/* what ctl says, for the next open */
	int	sub;
	Dev1	*cur;		/* the device of the transfer under way */
} i2c;

static void
setup(void)
{
	u32int core, div;

	if(i2c.setup)
		return;
	gpiofunc(Pinsda, Fsalt1);
	gpiofunc(Pinscl, Fsalt1);
	gpioclaim(Pinsda, "i2c");
	gpioclaim(Pinscl, "i2c");
	core = mboxclockrate(Clkcore);
	if(core == 0)
		core = 500000000;
	div = core / Hz;
	I(Idiv) = (div + 1) & ~1;
	I(Iclkt) = 0;
	i2c.setup = 1;
}

/* one transfer, all of it: 0, or -1 with what went wrong in *why */
static int
xfer(uchar *b, int n, int rd, char **why)
{
	int got, sent, idle;
	u32int s;

	I(Ic) = Icen | Icclear;
	I(Is) = Iserr | Isclkt | Isdone;
	I(Ia) = i2c.cur->addr;
	I(Idlen) = n;
	got = sent = 0;
	while(!rd && sent < n && (I(Is) & Istxd))
		I(Ififo) = b[sent++];
	I(Ic) = Icen | Icst | (rd? Icread: 0);
	for(idle = 0; idle < Patience; idle++){
		s = I(Is);
		while(rd && got < n && (I(Is) & Isrxd)){
			b[got++] = I(Ififo);
			idle = 0;
		}
		while(!rd && sent < n && (I(Is) & Istxd)){
			I(Ififo) = b[sent++];
			idle = 0;
		}
		if(s & (Iserr|Isclkt)){
			*why = (s & Iserr)? "no device": "clock stretched too long";
			I(Is) = Iserr | Isclkt | Isdone;
			I(Ic) = Icen | Icclear;
			return -1;
		}
		if(s & Isdone){
			while(rd && got < n && (I(Is) & Isrxd))
				b[got++] = I(Ififo);
			I(Is) = Isdone;
			if(rd && got != n){
				*why = "short read";
				return -1;
			}
			return 0;
		}
		microdelay(10);
	}
	I(Ic) = Icen | Icclear;
	*why = "i2c timed out";
	return -1;
}

static void
subaddr(Dev1 *d, uchar *b, vlong off)
{
	int i;

	for(i = 0; i < d->sub; i++)
		b[i] = off >> 8*(d->sub-1-i);
}

static long
dataio(Dev1 *d, void *a, long n, vlong off, int rd)
{
	uchar buf[Maxsub + Maxio];
	char *why;

	if(n > Maxio)
		n = Maxio;
	qlock(&i2c.lk);
	if(waserror()){
		qunlock(&i2c.lk);
		nexterror();
	}
	setup();
	i2c.cur = d;
	why = nil;
	subaddr(d, buf, off);
	if(rd){
		if(d->sub > 0 && xfer(buf, d->sub, 0, &why) < 0)
			error(why);
		if(xfer(buf, n, 1, &why) < 0)
			error(why);
		memmove(a, buf, n);
	}else{
		memmove(buf + d->sub, a, n);
		if(xfer(buf, d->sub + n, 0, &why) < 0)
			error(why);
	}
	poperror();
	qunlock(&i2c.lk);
	return n;
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
	Dev1 *d;

	if((ulong)c->qid.path == Qdata){
		qlock(&i2c.lk);
		if(i2c.addr == 0){
			qunlock(&i2c.lk);
			error("i2c: no addr");
		}
		d = smalloc(sizeof(Dev1));
		d->addr = i2c.addr;
		d->sub = i2c.sub;
		qunlock(&i2c.lk);
		c = devopen(c, omode, i2ctab, nelem(i2ctab), devgen);
		c->aux = d;
		return c;
	}
	return devopen(c, omode, i2ctab, nelem(i2ctab), devgen);
}

static void
i2cclose(Chan *c)
{
	if((c->flag & COPEN) && (ulong)c->qid.path == Qdata && c->aux != nil){
		free(c->aux);
		c->aux = nil;
	}
}

static long
i2cread(Chan *c, void *a, long n, vlong off)
{
	char buf[64];

	switch((ulong)c->qid.path){
	case Qroot:
		return devdirread(c, a, n, i2ctab, nelem(i2ctab), devgen);
	case Qctl:
		snprint(buf, sizeof buf, "addr %#x\nsubaddress %d\n", i2c.addr, i2c.sub);
		return readstr(off, a, n, buf);
	case Qdata:
		return dataio(c->aux, a, n, off, 1);
	}
	error(Egreg);
	return 0;
}

static long
i2cwrite(Chan *c, void *a, long n, vlong off)
{
	Cmdbuf *cb;
	int v;

	switch((ulong)c->qid.path){
	case Qctl:
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf != 2)
			error(Ebadarg);
		v = strtol(cb->f[1], nil, 0);
		qlock(&i2c.lk);
		if(strcmp(cb->f[0], "addr") == 0 && v > 0 && v < 0x78)
			i2c.addr = v;
		else if(strcmp(cb->f[0], "subaddress") == 0 && v >= 0 && v <= Maxsub)
			i2c.sub = v;
		else{
			qunlock(&i2c.lk);
			error(Ebadarg);
		}
		qunlock(&i2c.lk);
		poperror();
		free(cb);
		return n;
	case Qdata:
		return dataio(c->aux, a, n, off, 0);
	}
	error(Egreg);
	return 0;
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
