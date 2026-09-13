/*
 * #G -- GPIO pins as files.
 *
 *	#G/gpio/N/ctl	write "function in|out|alt0..alt5", "pull up|down|none"
 *			read  "function out\npull none\n"
 *	#G/gpio/N/level	read "0\n" or "1\n"; write "0" or "1" to drive an output
 *
 * One directory per pin, in BCM numbering because that is the only
 * numbering the hardware has, so that a namespace can hand a program
 * exactly one pin: bind '#G/gpio/29' /mnt/led. That is the difference
 * from the original Inferno Pi port's devgpio and from Plan 9's, which
 * are a single control file for all 54 pins -- a program that can
 * touch one can touch the UART's.
 *
 * This is the mechanism and nothing else: function select, pull,
 * level. No pin names, no LED polarity, no PWM, no events. Those are
 * policy and compose on top of this from user space (INFR-455). The
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

	Qshift	= 4,
	Qmask	= (1<<Qshift)-1,
};

#define QTYPE(p)	((int)((p) & Qmask))
#define QPIN(p)		((int)((p) >> Qshift))
#define QPATH(pin, t)	(((pin) << Qshift) | (t))

enum{
	CMfunction,
	CMpull,
};

static Cmdtab gpiocmd[] = {
	{CMfunction,	"function",	2},
	{CMpull,	"pull",		2},
};

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

static void
gpioinit(void)
{
	int i;

	for(i = 0; i < Npin; i++)
		pullstate[i] = -1;
	for(i = 0; i < Nexppin; i++)
		expstate[i] = -1;
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
	return devopen(c, omode, nil, 0, gpiogen);
}

static void
gpioclose(Chan *c)
{
	USED(c);
}

static long
gpioread(Chan *c, void *a, long n, vlong off)
{
	char buf[64];
	int pin, f, dir, pullup;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, gpiogen);
	pin = QPIN(c->qid.path);
	switch(QTYPE(c->qid.path)){
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
		snprint(buf, sizeof buf, "function %s\npull %s\n",
			f >= 0 && f < 8 ? funcname[f] : "?",
			pullstate[pin] < 0 ? "unknown" : pullname[pullstate[pin]]);
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
			if(mboxsetgpio(pin, s[0] == '1') < 0)
				error("firmware refused");
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
