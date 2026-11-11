/*
 * GPIO: RP1's 54 pins, of which the 40-pin header has 0-27, behind the
 * same functions ../bcm/gpio.c gives a BCM2837, so that ../bcm/devgpio.c
 * serves them as it serves those. From Linux's pinctrl-rp1.c.
 *
 * Each pin has a control word for its function and interrupts, a pad
 * register, and a bit in its bank's RIO block, which is what drives and
 * reads it when its function is the GPIO one. "in", "out" and alt0-alt5
 * here are RP1's functions 0-5 with 5 (sys_rio) split in two: alt5 as a
 * name would be the RIO itself, so devgpio's alt5 is RP1's a6.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define R(o)		(*(volatile u32int*)(uintptr)(RP1REGS + (o)))

enum
{
	Npin		= 54,
	Nbank		= 3,

	Iobase		= 0xD0000,	/* 0x4000 a bank */
	Riobase		= 0xE0000,
	Padbase		= 0xF0000,

	Ioctrl		= 4,
	Iointe		= 0x11C,
	Ioints		= 0x124,
		Irqfalling	= 1<<20,
		Irqrising	= 1<<21,
		Irqreset	= 1<<28,
	Fselmask	= 0x1F,
	Fselrio		= 5,

	Rioout		= 0,
	Riooe		= 4,
	Rioin		= 8,

	Atomicset	= 0x2000,
	Atomicclr	= 0x3000,

	Padpd		= 1<<2,
	Padpu		= 1<<3,
	Padie		= 1<<6,
	Padod		= 1<<7,
};

static int bankfirst[Nbank+1] = { 0, 28, 34, 54 };

static int
bank(int pin)
{
	int b;

	for(b = Nbank-1; b > 0; b--)
		if(pin >= bankfirst[b])
			break;
	return b;
}

#define BPIN(pin)	((pin) - bankfirst[bank(pin)])
#define CTRL(pin)	(Iobase + 0x4000*bank(pin) + 8*BPIN(pin) + Ioctrl)
#define PAD(pin)	(Padbase + 0x4000*bank(pin) + 4 + 4*BPIN(pin))
#define RIO(pin)	(Riobase + 0x4000*bank(pin))

/* devgpio's alternates, by its function codes, as RP1's a0-a4 and a6 */
static int
rp1alt(int func)
{
	switch(func){
	case Gpioalt0:	return 0;
	case Gpioalt1:	return 1;
	case Gpioalt2:	return 2;
	case Gpioalt3:	return 3;
	case Gpioalt4:	return 4;
	case Gpioalt5:	return 6;
	}
	return Fselrio;
}

void
gpiofunc(int pin, int func)
{
	u32int c;

	if(pin < 0 || pin >= Npin)
		return;
	c = R(CTRL(pin)) & ~(u32int)Fselmask;
	R(PAD(pin)) = (R(PAD(pin)) | Padie) & ~(u32int)Padod;
	if(func == Gpioin)
		R(RIO(pin) + Riooe + Atomicclr) = 1<<BPIN(pin);
	else if(func == Gpioout)
		R(RIO(pin) + Riooe + Atomicset) = 1<<BPIN(pin);
	R(CTRL(pin)) = c | rp1alt(func);
}

int
gpiogetfunc(int pin)
{
	int f;

	if(pin < 0 || pin >= Npin)
		return Gpioin;
	f = R(CTRL(pin)) & Fselmask;
	switch(f){
	case 0:		return Gpioalt0;
	case 1:		return Gpioalt1;
	case 2:		return Gpioalt2;
	case 3:		return Gpioalt3;
	case 4:		return Gpioalt4;
	case 6:		return Gpioalt5;
	case Fselrio:
		if(R(RIO(pin) + Riooe) & (1<<BPIN(pin)))
			return Gpioout;
		return Gpioin;
	}
	return Gpioin;
}

void
gpiopull(int pin, int pull)
{
	u32int p;

	if(pin < 0 || pin >= Npin)
		return;
	p = R(PAD(pin)) & ~(u32int)(Padpd|Padpu);
	if(pull == Pullup)
		p |= Padpu;
	else if(pull == Pulldown)
		p |= Padpd;
	R(PAD(pin)) = p;
}

void
gpioout(int pin, int on)
{
	if(pin < 0 || pin >= Npin)
		return;
	R(RIO(pin) + Rioout + (on ? Atomicset : Atomicclr)) = 1<<BPIN(pin);
}

int
gpioin(int pin)
{
	if(pin < 0 || pin >= Npin)
		return 0;
	return (R(RIO(pin) + Rioin) >> BPIN(pin)) & 1;
}

void
gpioedge(int pin, int rising, int falling)
{
	int b;
	u32int c;

	if(pin < 0 || pin >= Npin)
		return;
	b = bank(pin);
	c = R(CTRL(pin)) & ~(u32int)(Irqrising|Irqfalling);
	if(rising)
		c |= Irqrising;
	if(falling)
		c |= Irqfalling;
	R(CTRL(pin)) = c;
	R(CTRL(pin) + Atomicset) = Irqreset;
	R(Iobase + 0x4000*b + Iointe + (rising || falling ? Atomicset : Atomicclr)) = 1<<BPIN(pin);
}

/*
 * The pins that have had an edge since last asked, and the asking
 * clears them: reg 0 is pins 0-31, reg 1 is 32-53, as on a BCM2837.
 */
u32int
gpioevents(int reg)
{
	u32int ev, s;
	int b, i, pin;

	ev = 0;
	for(b = 0; b < Nbank; b++){
		s = R(Iobase + 0x4000*b + Ioints);
		for(i = 0; s != 0; i++, s >>= 1){
			if((s & 1) == 0)
				continue;
			pin = bankfirst[b] + i;
			if(pin/32 != reg)
				continue;
			R(CTRL(pin) + Atomicset) = Irqreset;
			ev |= 1U << (pin%32);
		}
	}
	return ev;
}

/* pins the kernel drives itself: ../bcm/gpio.c says why */
static char *claimed[Npin];

void
gpioclaim(int pin, char *who)
{
	if(pin >= 0 && pin < Npin)
		claimed[pin] = who;
}

char*
gpioclaimed(int pin)
{
	if(pin < 0 || pin >= Npin)
		return "nobody";
	return claimed[pin];
}
