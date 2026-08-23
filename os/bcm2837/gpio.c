/*
 * BCM2837 GPIO.
 *
 * 54 pins, each with eight possible functions (input, output, and six
 * alternates), selected three bits at a time across six GPFSEL
 * registers.  Set and clear are separate write-only registers rather
 * than a read-modify-write on a level register, which is what makes a
 * single pin safe to drive without a lock.
 *
 * This is the whole of the hardware layer.  The intended shape for
 * InferNode is a 9P server presenting pins as files, so that GPIO is
 * scriptable from sh and reachable by agents without an API -- but that
 * needs the Dis VM, so it waits.  Keeping the driver this thin is what
 * makes that later step small.
 */

#include "u.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

#define GPIO(r)	(*(volatile u32int*)((uintptr)GPIOREGS + (r)))

enum
{
	Npin		= 54,
	Fselperreg	= 10,	/* 10 pins per GPFSEL, 3 bits each */
	Fselbits	= 3,
	Fselmask	= 7,
};

/*
 * The pull-up/pull-down control is a clocked sequence, not a plain
 * register write: drive GPPUD with the wanted state, wait, clock it into
 * the target pins with GPPUDCLK, wait, then release.  The waits are
 * required by the peripheral spec -- 150 cycles is the documented
 * figure.  Skipping them leaves pins in whatever state they had.
 */
static void
pudwait(void)
{
	int i;

	for(i = 0; i < 150; i++)
		__asm__ volatile("nop");
}

void
gpiofunc(int pin, int func)
{
	int reg, shift;
	u32int v;

	if(pin < 0 || pin >= Npin)
		return;

	reg = (pin / Fselperreg) * 4;
	shift = (pin % Fselperreg) * Fselbits;

	v = GPIO(Gpfsel0 + reg);
	v &= ~((u32int)Fselmask << shift);
	v |= ((u32int)func & Fselmask) << shift;
	GPIO(Gpfsel0 + reg) = v;
}

void
gpiopull(int pin, int pull)
{
	int reg, bit;

	if(pin < 0 || pin >= Npin)
		return;

	reg = (pin / 32) * 4;
	bit = pin % 32;

	GPIO(Gppud) = (u32int)pull & 3;
	pudwait();
	GPIO(Gppudclk0 + reg) = (u32int)1 << bit;
	pudwait();
	GPIO(Gppud) = 0;
	GPIO(Gppudclk0 + reg) = 0;
}

void
gpioout(int pin, int on)
{
	int reg, bit;

	if(pin < 0 || pin >= Npin)
		return;

	reg = (pin / 32) * 4;
	bit = pin % 32;

	/*
	 * Separate set and clear registers: writing a 1 acts, writing a 0
	 * is ignored.  No read-modify-write, so no lost update if another
	 * core is driving a different pin in the same bank.
	 */
	if(on)
		GPIO(Gpset0 + reg) = (u32int)1 << bit;
	else
		GPIO(Gpclr0 + reg) = (u32int)1 << bit;
}

int
gpioin(int pin)
{
	int reg, bit;

	if(pin < 0 || pin >= Npin)
		return -1;

	reg = (pin / 32) * 4;
	bit = pin % 32;

	return (GPIO(Gplev0 + reg) >> bit) & 1;
}

/*
 * Read back the function select for a pin.  Mostly useful for proving
 * that a mux actually took, which is otherwise invisible.
 */
int
gpiogetfunc(int pin)
{
	int reg, shift;

	if(pin < 0 || pin >= Npin)
		return -1;

	reg = (pin / Fselperreg) * 4;
	shift = (pin % Fselperreg) * Fselbits;

	return (GPIO(Gpfsel0 + reg) >> shift) & Fselmask;
}
