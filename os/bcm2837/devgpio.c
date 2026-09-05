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

static void
gpioinit(void)
{
	int i;

	for(i = 0; i < Npin; i++)
		pullstate[i] = -1;
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
		if(s < 0 || s >= Npin)
			return -1;
		snprint(nm, sizeof nm, "%d", s);
		mkqid(&q, QPATH(s, Qpin), 0, QTDIR);
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
	int pin, f;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, gpiogen);
	pin = QPIN(c->qid.path);
	switch(QTYPE(c->qid.path)){
	case Qctl:
		f = gpiogetfunc(pin);
		snprint(buf, sizeof buf, "function %s\npull %s\n",
			f >= 0 && f < 8 ? funcname[f] : "?",
			pullstate[pin] < 0 ? "unknown" : pullname[pullstate[pin]]);
		return readstr(off, a, n, buf);
	case Qlevel:
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
	int pin, i;

	USED(off);
	if(c->qid.type & QTDIR)
		error(Eperm);
	pin = QPIN(c->qid.path);
	who = gpioclaimed(pin);
	switch(QTYPE(c->qid.path)){
	case Qctl:
		if(who != nil)
			errorf("in use by %s", who);
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
		if(gpiogetfunc(pin) != Gpioout)
			error("not an output");
		s = a;
		if(n < 1 || (s[0] != '0' && s[0] != '1'))
			error(Ebadctl);
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
