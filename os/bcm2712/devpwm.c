/*
 * #W -- PWM: RP1's PWM0, four channels from the 50MHz crystal, so times
 * go in steps of 20ns and up to 85 seconds.
 *
 *	#W/pwm0 .. pwm3		write "period NS", "duty NS", "on", "off",
 *				several to a write; read them
 *
 * Channels 0-3 are GPIO 12, 13, 18 and 19. 12 and 13 are this kernel's
 * second console, so those two refuse "on" while it has them. A pin
 * becomes PWM's at "on" and stays it. Registers from Linux's pwm-rp1.c.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"board.h"

#define R(o)	(*(volatile u32int*)(uintptr)(RP1REGS + (o)))

enum{
	Nchan		= 4,
	Nanos		= 20,		/* a count */

	Pwm0		= 0x98000,
	Global		= Pwm0 + 0x00,
		Update		= 1U<<31,
	Chanctrl	= Pwm0 + 0x14,	/* each channel, 16 apart */
		Chandefault	= 1<<8 | 1<<0,
	Chanrange	= Pwm0 + 0x18,
	Chanduty	= Pwm0 + 0x20,

	Clkctrl		= 0x18000 + 0x74,
	Clkint		= 0x18000 + 0x78,
	Clkfrac		= 0x18000 + 0x7C,
	Clksel		= 0x18000 + 0x80,
	Clkenable	= 1<<11,
	Clkauxxosc	= 2<<5,
	Clkauxsel	= 1,
};

typedef struct Chan1 Chan1;
struct Chan1
{
	int	pin;
	int	alt;
	u32int	period;		/* in counts */
	u32int	duty;
	int	on;
};

static Chan1 chans[Nchan] = {
	{ .pin = 12, .alt = Gpioalt0 },
	{ .pin = 13, .alt = Gpioalt0 },
	{ .pin = 18, .alt = Gpioalt3 },
	{ .pin = 19, .alt = Gpioalt3 },
};

static QLock pwmlock;
static int clocked;

enum{
	Qdir,
	Qchan0,
};

static Dirtab pwmtab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"pwm0",		{Qchan0+0},		0,	0664,
	"pwm1",		{Qchan0+1},		0,	0664,
	"pwm2",		{Qchan0+2},		0,	0664,
	"pwm3",		{Qchan0+3},		0,	0664,
};

static void
clockon(void)
{
	if(clocked)
		return;
	R(Clkctrl) &= ~(u32int)Clkenable;
	R(Clkint) = 1;
	R(Clkfrac) = 0;
	R(Clkctrl) = Clkauxxosc | Clkauxsel;
	R(Clksel);
	R(Clkctrl) |= Clkenable;
	clocked = 1;
}

static void
apply(int n)
{
	Chan1 *c;
	u32int g;

	c = &chans[n];
	clockon();
	R(Chanctrl + 16*n) = Chandefault;
	R(Chanrange + 16*n) = c->period;
	R(Chanduty + 16*n) = c->duty;
	g = R(Global) & ~(u32int)(1<<n);
	if(c->on)
		g |= 1<<n;
	R(Global) = g;
	R(Global) = g | Update;
}

static void
chanon(int n)
{
	Chan1 *c;
	char *who;

	c = &chans[n];
	who = gpioclaimed(c->pin);
	if(who != nil && strcmp(who, "pwm") != 0)
		error("pwm: pin in use");
	gpioclaim(c->pin, "pwm");
	gpiofunc(c->pin, c->alt);
	c->on = 1;
}

static u32int
counts(char *s)
{
	uvlong v;

	v = strtoull(s, nil, 0) / Nanos;
	if(v > 0xFFFFFFFFULL)
		error("pwm: too long");
	return v;
}

static Chan*
pwmattach(char *spec)
{
	return devattach('W', spec);
}

static Walkqid*
pwmwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, pwmtab, nelem(pwmtab), devgen);
}

static int
pwmstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, pwmtab, nelem(pwmtab), devgen);
}

static Chan*
pwmopen(Chan *c, int omode)
{
	return devopen(c, omode, pwmtab, nelem(pwmtab), devgen);
}

static void
pwmclose(Chan *c)
{
	USED(c);
}

static long
pwmread(Chan *c, void *a, long n, vlong off)
{
	Chan1 *p;
	char buf[64];

	if((ulong)c->qid.path == Qdir)
		return devdirread(c, a, n, pwmtab, nelem(pwmtab), devgen);
	p = &chans[(ulong)c->qid.path - Qchan0];
	snprint(buf, sizeof buf, "period %llud duty %llud %s\n",
		(uvlong)p->period*Nanos, (uvlong)p->duty*Nanos, p->on ? "on" : "off");
	return readstr(off, a, n, buf);
}

static long
pwmwrite(Chan *c, void *a, long n, vlong off)
{
	Cmdbuf *cb;
	Chan1 *p;
	int i, ch;

	USED(off);
	if((ulong)c->qid.path == Qdir)
		error(Eperm);
	ch = (ulong)c->qid.path - Qchan0;
	p = &chans[ch];
	cb = parsecmd(a, n);
	qlock(&pwmlock);
	if(waserror()){
		qunlock(&pwmlock);
		free(cb);
		nexterror();
	}
	for(i = 0; i < cb->nf; i++){
		if(strcmp(cb->f[i], "on") == 0)
			chanon(ch);
		else if(strcmp(cb->f[i], "off") == 0)
			p->on = 0;
		else if(strcmp(cb->f[i], "period") == 0 && i+1 < cb->nf)
			p->period = counts(cb->f[++i]);
		else if(strcmp(cb->f[i], "duty") == 0 && i+1 < cb->nf)
			p->duty = counts(cb->f[++i]);
		else
			error(Ebadctl);
	}
	if(p->duty > p->period)
		p->duty = p->period;
	apply(ch);
	qunlock(&pwmlock);
	poperror();
	free(cb);
	return n;
}

Dev pwmdevtab = {
	'W',
	"pwm",

	devreset,
	devinit,
	devshutdown,
	pwmattach,
	pwmwalk,
	pwmstat,
	pwmopen,
	devcreate,
	pwmclose,
	pwmread,
	devbread,
	pwmwrite,
	devbwrite,
	devremove,
	devwstat,
};
