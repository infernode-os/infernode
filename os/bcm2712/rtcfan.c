/*
 * The two things a Pi 5 has for looking after itself: the clock, served
 * as #r by devrtc.c, and the fan, in #P by ../bcm/devarch.c.
 *
 * The real-time clock is the firmware's, reached by two mailbox tags
 * (Linux's drivers/rtc/rtc-rpi.c): seconds since 1970. It keeps counting
 * across a reset, and across power only with a battery on the J5
 * connector; without one it starts again from nothing.
 *
 * The fan is on RP1's PWM1 channel 3, GPIO 45: an inverted 24kHz signal
 * (the Pi 5's device tree), from the 50MHz crystal. It starts at a safe
 * middle speed, because an Active Cooler nobody drives is no cooling at
 * all. What speed to want is policy, and belongs above #P/fan.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define RP1(o)		(*(volatile u32int*)(uintptr)(RP1REGS + (o)))
#define GIO(o)		(*(volatile u32int*)(uintptr)(0x107D508500ULL + (o)))
#define GIOAON(o)	(*(volatile u32int*)(uintptr)(0x107D517C00ULL + (o)))

enum
{
	Taggetrtc	= 0x00030087,
	Tagsetrtc	= 0x00038087,
	Rtctime		= 0,
	Rtcbattvolts	= 7,		/* microvolts */
	Taggettemp	= 0x00030006,

	Actled		= 9,		/* ACT: AON GPIO 9, active low */
	Pwrbutton	= 20,		/* GPIO 20, low when pressed */
	Giodata		= 0x04,
	Gioiodir	= 0x08,

	Clkpwm1ctrl	= 0x18000 + 0x84,	/* RP1's clock generators */
	Clkpwm1int	= 0x18000 + 0x88,
	Clkpwm1frac	= 0x18000 + 0x8C,
	Clkpwm1sel	= 0x18000 + 0x90,
	Clkenable	= 1<<11,
	Clkauxxosc	= 2<<5,
	Clkauxsel	= 1,

	Pwm1		= 0x9C000,
	Pwmglobal	= Pwm1 + 0x00,
		Pwmupdate	= 1U<<31,
	Pwmchan3	= 3,
	Pwmctrl		= Pwm1 + 0x14 + 16*Pwmchan3,
		Pwmdefault	= 1<<8 | 1<<0,
		Pwmpolarity	= 1<<3,
	Pwmrange	= Pwm1 + 0x18 + 16*Pwmchan3,
	Pwmduty		= Pwm1 + 0x20 + 16*Pwmchan3,
	Pwmrpm		= Pwm1 + 0x3C,
	Period		= 2078,		/* 41566ns at 20ns a count */

	Gpio45ctrl	= 0xD8000 + 8*11 + 4,	/* bank 2, pin 11; function 0 is pwm1 */
	Gpio45pad	= 0xF8000 + 4 + 4*11,

	Fanstart	= 125,		/* Linux's middle cooling level, of 255 */
	Plausible	= 1600000000,	/* a clock before 2020 was never set */
};

extern vlong boottime;		/* ../port/devcons.c: what /dev/time is kept from */

static int fanlevel;

/* the firmware's clock, or -1 */
vlong
rtcget(void)
{
	u32int v[2];

	v[0] = Rtctime;
	v[1] = 0;
	if(mboxprop(Taggetrtc, v, 1, 2) < 0)
		return -1;
	return v[1];
}

/* the battery on J5, in millivolts, or -1 */
int
rtcbatt(void)
{
	u32int v[2];

	v[0] = Rtcbattvolts;
	v[1] = 0;
	if(mboxprop(Taggetrtc, v, 1, 2) < 0)
		return -1;
	return v[1]/1000;
}

int
rtcset(u32int secs)
{
	u32int v[2];

	v[0] = Rtctime;
	v[1] = secs;
	return mboxprop(Tagsetrtc, v, 2, 2);
}

/* the board's ACT light, the power button (1 while pressed) */
void
ledset(int on)
{
	GIOAON(Gioiodir) &= ~(u32int)(1<<Actled);
	if(on)
		GIOAON(Giodata) &= ~(u32int)(1<<Actled);
	else
		GIOAON(Giodata) |= 1<<Actled;
}

int
buttonget(void)
{
	return (GIO(Giodata) >> Pwrbutton & 1) == 0;
}

void
fanset(int level)
{
	if(level < 0)
		level = 0;
	if(level > 255)
		level = 255;
	RP1(Pwmduty) = level*Period/255;
	RP1(Pwmglobal) |= Pwmupdate;
	coherence();
	fanlevel = level;
}

int
fanget(void)
{
	return fanlevel;
}

int
fanrpm(void)
{
	return RP1(Pwmrpm);
}

/*
 * Until someone writes #P/fan, the fan follows the temperature, by the
 * trips of the Pi 5's device tree, each with a 5 degree fall before it
 * lets go. It is here and not above #P because a board that overheats
 * when nothing has started yet is not a matter of policy. Writing a
 * level takes over; writing "auto" gives it back.
 */
static int fanmanual;
static Rendez fanr;

void
fanauto(int on)
{
	fanmanual = !on;
}

static void
fanproc(void*)
{
	static int trip[] = {50000, 60000, 67000, 75000};
	static int lev[] = {75, 125, 175, 250};
	u32int v[2];
	int i, t, want;

	want = -1;
	while(waserror())
		;
	for(;;){
		tsleep(&fanr, return0, nil, 2000);
		if(fanmanual)
			continue;
		v[0] = 0;
		v[1] = 0;
		if(mboxprop(Taggettemp, v, 1, 2) < 0)
			continue;
		t = v[1];
		while(want+1 < nelem(trip) && t >= trip[want+1])
			want++;
		while(want >= 0 && t < trip[want] - 5000)
			want--;
		i = want < 0 ? 0 : lev[want];
		if(i != fanget())
			fanset(i);
	}
}

/* #P's init: there is a scheduler by then */
void
fanstart(void)
{
	kproc("fan", fanproc, nil, 0);
	nvmestart();
}

void
rtcfanlink(void)
{
	vlong t;

	RP1(Clkpwm1ctrl) &= ~(u32int)Clkenable;
	RP1(Clkpwm1int) = 1;
	RP1(Clkpwm1frac) = 0;
	RP1(Clkpwm1ctrl) = Clkauxxosc | Clkauxsel;
	RP1(Clkpwm1sel);
	RP1(Clkpwm1ctrl) |= Clkenable;

	RP1(Gpio45pad) = (RP1(Gpio45pad) | 1<<6) & ~(u32int)(1<<7);
	RP1(Gpio45ctrl) = 0;
	gpioclaim(45, "fan");

	RP1(Pwmctrl) = Pwmdefault | Pwmpolarity;
	RP1(Pwmrange) = Period;
	RP1(Pwmglobal) |= 1<<Pwmchan3;
	fanset(Fanstart);

	t = rtcget();
	print("rtc: %lld seconds%s\n", t, t >= Plausible ? "" : ": not set, the clock is left alone");
	if(t >= Plausible)
		boottime = t - TK2SEC(MACHP(0)->ticks);
}
