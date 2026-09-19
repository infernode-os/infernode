/*
 * #G -- GPIO pins as files.
 *
 *	#G/gpio/N/ctl	write "function in|out|alt0..alt5", "pull up|down|none",
 *			      "edge rising|falling|both|none"
 *			read  "function out\npull none\nedge none\n"
 *	#G/gpio/N/level	read "0\n" or "1\n"; write "0" or "1" to drive an output
 *	#G/gpio/N/event	read blocks for an edge, then a line per edge, oldest
 *			first: "<microseconds> <level>\n", the time the
 *			interrupt's, on #b/busec's clock; "overrun <n>\n"
 *			first if this reader fell behind and n were dropped
 *
 * One directory per pin, in BCM numbering because that is the only
 * numbering the hardware has, so that a namespace can hand a program
 * exactly one pin: bind '#G/gpio/29' /mnt/led. That is the difference
 * from the original Inferno Pi port's devgpio and from Plan 9's, which
 * are a single control file for all 54 pins -- a program that can
 * touch one can touch the UART's.
 *
 * This is the mechanism and nothing else: function select, pull,
 * level, edge. No pin names, no LED polarity, no PWM, no debounce, no
 * counting. Those are policy and compose on top of this from user space
 * (INFR-455). Edges came in later (#651) and are on the mechanism's side
 * of that line: what to do about an edge is policy, but that one
 * happened, and when, only the kernel can know, because only the kernel
 * takes the interrupt. A program polling level every millisecond learns
 * of an edge a millisecond late, cannot tell two from none, and makes a
 * thousand system calls a second for ever. Nothing is enabled for a pin
 * until a ctl write asks for an edge AND an event file is open. The
 * pins the kernel drives itself -- the console UART, the SD card --
 * are claimed by their drivers and refuse ctl writes: a stray echo
 * must not be able to take the console down.
 *
 * Pins 128..135 are the firmware's GPIO expander (io.h Gpioexpbase):
 * eight lines the VideoCore drives over its own I2C, reached through
 * the mailbox rather than GPIOREGS, numbered as the firmware and
 * 9front number them. On the 3B+ they are the radios' power enables
 * (128 BT_ON, 129 WL_ON), the Ethernet chip's reset (131 LAN_RUN),
 * the power LED and HDMI hot-plug. They are here, in the same
 * directory with the same two files, because a power switch is a pin
 * and a second schema for it would be a second thing to learn and to
 * grant. What differs is refused truthfully: the expander has no
 * function select and no pull to set, so ctl writes say so; ctl reads
 * report what the firmware says the line is configured as. The same
 * claiming applies -- ether4330 owns 129 and a write there says
 * "in use by ether4330" -- so the WiFi radio's power is readable but
 * not pullable from under its driver, and the Bluetooth radio's is a
 * program's to drive (docs/BLUETOOTH.md).
 *
 * Before this, every port -- the old Inferno Pi port, Plan 9, 9front
 * -- switched these lines with a kernel-internal function call and
 * nothing outside could see or ask. 9front's egpset() is the model
 * for the mailbox side and nothing else.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"
#include "../port/error.h"

enum{
	Npin	= 54,

	Qroot	= 0,
	Qgpio,		/* the gpio directory */
	Qpin,		/* a pin's directory */
	Qctl,
	Qlevel,
	Qevent,

	Nev	= 256,		/* edges a reader may fall behind by */

	Qshift	= 4,
	Qmask	= (1<<Qshift)-1,
};

#define QTYPE(p)	((int)((p) & Qmask))
#define QPIN(p)		((int)((p) >> Qshift))
#define QPATH(pin, t)	(((pin) << Qshift) | (t))

enum{
	CMfunction,
	CMpull,
	CMedge,
};

static Cmdtab gpiocmd[] = {
	{CMfunction,	"function",	2},
	{CMpull,	"pull",		2},
	{CMedge,	"edge",		2},
};

/* an edge setting is two bits: rising, falling */
static char *edgename[4] = { "none", "rising", "falling", "both" };
static int edgewant[Npin];

/*
 * One per open event file, on its pin's list. The interrupt handler
 * fills every reader of the pin; each drains at its own pace, and one
 * that falls Nev behind loses its oldest and is told how many.
 */
typedef struct Evq Evq;
struct Evq
{
	Evq	*next;
	int	pin;
	Rendez	r;
	int	ri, n;
	ulong	overrun;
	struct {
		uvlong	us;
		int	level;
	} ev[Nev];
};

static Lock evlock;		/* the lists, the queues, and GPREN/GPFEN */
static Evq *readers[Npin];

/* GPFSEL encoding -> name */
static char *funcname[8] = {
	"in", "out", "alt5", "alt4", "alt0", "alt1", "alt2", "alt3",
};

static char *pullname[3] = { "none", "down", "up" };
static int pullstate[Npin];	/* -1 = not set since boot: the hardware cannot be asked */

/*
 * What was last written to each expander line, or -1. A firmware that
 * answers GET_GPIO_STATE makes this redundant; QEMU's accepts the tag
 * and answers nothing, and then this is what a read reports rather
 * than a guess -- and "?" if nothing was ever written.
 */
static int expstate[Nexppin];

#define ISEXP(pin)	((pin) >= Gpioexpbase && (pin) < Gpioexpbase + Nexppin)

/* detection is on only while somebody both asked for an edge and is listening */
static void
applyedge(int pin)
{
	int w;

	w = readers[pin] != nil ? edgewant[pin] : 0;
	gpioedge(pin, w & 1, w & 2);
}

/*
 * The time is taken here, so it is good to tens of microseconds however
 * late a reader runs. All three bank interrupts come here; both status
 * registers are read, because a pin's bank is not its register.
 */
static void
gpiointr(Ureg*, void*)
{
	u32int eds;
	uvlong us;
	int reg, b, pin, level, slot;
	Evq *q;

	us = fastticks2ns(fastticks(nil)) / 1000;
	for(reg = 0; reg < 2; reg++){
		eds = gpioevents(reg);
		for(b = 0; eds != 0; b++, eds >>= 1){
			if((eds & 1) == 0)
				continue;
			pin = reg*32 + b;
			if(pin >= Npin)
				break;
			level = gpioin(pin);
			ilock(&evlock);
			for(q = readers[pin]; q != nil; q = q->next){
				if(q->n == Nev){
					q->ri = (q->ri + 1) % Nev;
					q->n--;
					q->overrun++;
				}
				slot = (q->ri + q->n) % Nev;
				q->ev[slot].us = us;
				q->ev[slot].level = level;
				q->n++;
				/*
				 * Woken with the lock held: close unlinks a
				 * reader under this lock and frees it after,
				 * so a reader seen here cannot be gone before
				 * its wakeup.
				 */
				wakeup(&q->r);
			}
			iunlock(&evlock);
		}
	}
}

static int
evready(void *a)
{
	Evq *q;

	q = a;
	return q->n > 0 || q->overrun > 0;
}

static void
gpioinit(void)
{
	int i;

	for(i = 0; i < Npin; i++)
		pullstate[i] = -1;
	for(i = 0; i < Nexppin; i++)
		expstate[i] = -1;
	intrenable(IRQgpio0, gpiointr, nil, 0, "gpio0");
	intrenable(IRQgpio1, gpiointr, nil, 0, "gpio1");
	intrenable(IRQgpio2, gpiointr, nil, 0, "gpio2");
}

static int
gpiogen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;
	int pin;
	char nm[8];

	USED(tab);
	USED(ntab);
	USED(name);
	switch(QTYPE(c->qid.path)){
	case Qroot:
		if(s == DEVDOTDOT){
			mkqid(&q, Qroot, 0, QTDIR);
			devdir(c, q, "#G", 0, eve, DMDIR|0555, dp);
			return 1;
		}
		if(s == 0){
			mkqid(&q, Qgpio, 0, QTDIR);
			devdir(c, q, "gpio", 0, eve, DMDIR|0555, dp);
			return 1;
		}
		return -1;
	case Qgpio:
		if(s == DEVDOTDOT){
			mkqid(&q, Qroot, 0, QTDIR);
			devdir(c, q, "#G", 0, eve, DMDIR|0555, dp);
			return 1;
		}
		/* the 54 SoC pins, then the expander's eight as 128..135 */
		if(s < 0 || s >= Npin + Nexppin)
			return -1;
		pin = s < Npin ? s : Gpioexpbase + s - Npin;
		snprint(nm, sizeof nm, "%d", pin);
		mkqid(&q, QPATH(pin, Qpin), 0, QTDIR);
		devdir(c, q, nm, 0, eve, DMDIR|0555, dp);
		return 1;
	case Qpin:
	case Qctl:
	case Qlevel:
	case Qevent:
		/*
		 * A pin's directory and the two files in it answer alike
		 * for s >= 0: the entries of the pin's directory. That is
		 * what devstat and devopen need of a gen called on a LEAF
		 * -- they walk the leaf's siblings looking for its own qid
		 * -- and this case used to answer -1 for every s >= 0 on a
		 * leaf, so stat(2) on /dev/gpio/N/ctl printed "devstat G"
		 * and failed with "file does not exist" while the
		 * directory listing showed the file and reads worked (open
		 * takes gen's -1 as "no entry to permission-check" and
		 * carries on). ls on a leaf, and ftest -e, were the ways to
		 * see it. Only ".." differs: the pin's parent is the gpio
		 * directory, a file's is the pin.
		 */
		pin = QPIN(c->qid.path);
		if(s == DEVDOTDOT){
			if(QTYPE(c->qid.path) == Qpin){
				mkqid(&q, Qgpio, 0, QTDIR);
				devdir(c, q, "gpio", 0, eve, DMDIR|0555, dp);
				return 1;
			}
			snprint(nm, sizeof nm, "%d", pin);
			mkqid(&q, QPATH(pin, Qpin), 0, QTDIR);
			devdir(c, q, nm, 0, eve, DMDIR|0555, dp);
			return 1;
		}
		if(s == 0){
			mkqid(&q, QPATH(pin, Qctl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0664, dp);
			return 1;
		}
		if(s == 1){
			mkqid(&q, QPATH(pin, Qlevel), 0, QTFILE);
			devdir(c, q, "level", 0, eve, 0664, dp);
			return 1;
		}
		/* the expander's lines have no interrupt, so no event file */
		if(s == 2 && !ISEXP(pin)){
			mkqid(&q, QPATH(pin, Qevent), 0, QTFILE);
			devdir(c, q, "event", 0, eve, 0444, dp);
			return 1;
		}
		return -1;
	}
	return -1;
}

static Chan*
gpioattach(char *spec)
{
	return devattach('G', spec);
}

static Walkqid*
gpiowalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, gpiogen);
}

static int
gpiostat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, gpiogen);
}

static Chan*
gpioopen(Chan *c, int omode)
{
	Evq *q;
	int pin;

	c = devopen(c, omode, nil, 0, gpiogen);
	if(QTYPE(c->qid.path) == Qevent){
		pin = QPIN(c->qid.path);
		q = mallocz(sizeof(Evq), 1);
		if(q == nil){
			c->flag &= ~COPEN;
			error(Enomem);
		}
		q->pin = pin;
		c->aux = q;
		ilock(&evlock);
		q->next = readers[pin];
		readers[pin] = q;
		applyedge(pin);
		iunlock(&evlock);
	}
	return c;
}

static void
gpioclose(Chan *c)
{
	Evq *q, **l;

	if(QTYPE(c->qid.path) != Qevent || (c->flag & COPEN) == 0 || c->aux == nil)
		return;
	q = c->aux;
	c->aux = nil;
	ilock(&evlock);
	for(l = &readers[q->pin]; *l != nil; l = &(*l)->next)
		if(*l == q){
			*l = q->next;
			break;
		}
	applyedge(q->pin);
	iunlock(&evlock);
	free(q);
}

/*
 * As many whole lines as fit, never part of one: a reader that asked
 * for little gets one edge at a time, and none is ever split.
 */
static long
eventread(Evq *q, char *a, long n)
{
	char line[48];
	long tot;
	int l, level;
	uvlong us;
	ulong lost;

	sleep(&q->r, evready, q);
	tot = 0;
	for(;;){
		ilock(&evlock);
		lost = q->overrun;
		if(lost == 0 && q->n == 0){
			iunlock(&evlock);
			break;
		}
		us = 0;
		level = 0;
		if(lost == 0){
			us = q->ev[q->ri].us;
			level = q->ev[q->ri].level;
		}
		iunlock(&evlock);
		if(lost != 0)
			l = snprint(line, sizeof line, "overrun %lud\n", lost);
		else
			l = snprint(line, sizeof line, "%llud %d\n", us, level);
		if(tot + l > n)
			break;
		memmove(a + tot, line, l);
		tot += l;
		ilock(&evlock);
		if(lost != 0)
			q->overrun -= lost;	/* more may have been lost meanwhile: they are reported next */
		else{
			q->ri = (q->ri + 1) % Nev;
			q->n--;
		}
		iunlock(&evlock);
	}
	if(tot == 0)
		error("read too short for an event line");
	return tot;
}

static long
gpioread(Chan *c, void *a, long n, vlong off)
{
	char buf[96];
	int pin, f, dir, pullup;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, gpiogen);
	pin = QPIN(c->qid.path);
	switch(QTYPE(c->qid.path)){
	case Qevent:
		return eventread(c->aux, a, n);
	case Qctl:
		if(ISEXP(pin)){
			if(mboxgpioconfig(pin, &dir, &pullup) < 0)
				snprint(buf, sizeof buf, "function unknown\npull unknown\n");
			else
				snprint(buf, sizeof buf, "function %s\npull %s\n",
					dir ? "out" : "in", pullup ? "up" : "none");
			return readstr(off, a, n, buf);
		}
		f = gpiogetfunc(pin);
		snprint(buf, sizeof buf, "function %s\npull %s\nedge %s\n",
			f >= 0 && f < 8 ? funcname[f] : "?",
			pullstate[pin] < 0 ? "unknown" : pullname[pullstate[pin]],
			edgename[edgewant[pin] & 3]);
		return readstr(off, a, n, buf);
	case Qlevel:
		if(ISEXP(pin)){
			f = mboxgetgpio(pin);
			if(f < 0)
				f = expstate[pin - Gpioexpbase];
			if(f < 0)
				snprint(buf, sizeof buf, "?\n");
			else
				snprint(buf, sizeof buf, "%d\n", f);
			return readstr(off, a, n, buf);
		}
		snprint(buf, sizeof buf, "%d\n", gpioin(pin));
		return readstr(off, a, n, buf);
	}
	error(Egreg);
	return 0;
}

static long
gpiowrite(Chan *c, void *a, long n, vlong off)
{
	Cmdbuf *cb;
	Cmdtab *ct;
	char *who, *s;
	int pin, i, dir, pullup;

	USED(off);
	if(c->qid.type & QTDIR)
		error(Eperm);
	pin = QPIN(c->qid.path);
	who = gpioclaimed(pin);
	switch(QTYPE(c->qid.path)){
	case Qctl:
		if(who != nil)
			errorf("in use by %s", who);
		if(ISEXP(pin))
			error("firmware expander line: no function select or pull to set");
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		ct = lookupcmd(cb, gpiocmd, nelem(gpiocmd));
		switch(ct->index){
		case CMfunction:
			for(i = 0; i < nelem(funcname); i++)
				if(strcmp(funcname[i], cb->f[1]) == 0)
					break;
			if(i >= nelem(funcname))
				error(Ebadctl);
			gpiofunc(pin, i);
			break;
		case CMpull:
			for(i = 0; i < nelem(pullname); i++)
				if(strcmp(pullname[i], cb->f[1]) == 0)
					break;
			if(i >= nelem(pullname))
				error(Ebadctl);
			gpiopull(pin, i);
			pullstate[pin] = i;
			break;
		case CMedge:
			for(i = 0; i < nelem(edgename); i++)
				if(strcmp(edgename[i], cb->f[1]) == 0)
					break;
			if(i >= nelem(edgename))
				error(Ebadctl);
			ilock(&evlock);
			edgewant[pin] = i;
			applyedge(pin);
			iunlock(&evlock);
			break;
		}
		poperror();
		free(cb);
		return n;
	case Qlevel:
		if(who != nil)
			errorf("in use by %s", who);
		s = a;
		if(n < 1 || (s[0] != '0' && s[0] != '1'))
			error(Ebadctl);
		if(ISEXP(pin)){
			/*
			 * An input line (HDMI hot-plug) refuses like a SoC
			 * pin does -- when the firmware will say which it is.
			 * QEMU's will not, and then the write goes through
			 * and is ignored, which is what QEMU does with it.
			 */
			if(mboxgpioconfig(pin, &dir, &pullup) == 0 && dir == 0)
				error("not an output");
			if(mboxsetgpio(pin, s[0] == '1') < 0){
				snprint(up->genbuf, sizeof up->genbuf,
					"firmware refused (code 0x%ux)", mboxlastcode());
				error(up->genbuf);
			}
			expstate[pin - Gpioexpbase] = s[0] == '1';
			return n;
		}
		if(gpiogetfunc(pin) != Gpioout)
			error("not an output");
		gpioout(pin, s[0] == '1');
		return n;
	}
	error(Egreg);
	return 0;
}

Dev gpiodevtab = {
	'G',
	"gpio",

	devreset,
	gpioinit,
	devshutdown,
	gpioattach,
	gpiowalk,
	gpiostat,
	gpioopen,
	devcreate,
	gpioclose,
	gpioread,
	devbread,
	gpiowrite,
	devbwrite,
	devremove,
	devwstat,
};
