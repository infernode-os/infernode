/*
 * The devices this SoC has and the rest of the family does not. None
 * yet: the card, RP1's USB and Ethernet come next (README.md, the plan).
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

void
socdevprobe(void)
{
	rp1link();
	rp1uartlink();
	rtcfanlink();
	gpioclaim(14, "console");
	gpioclaim(15, "console");
	gpioclaim(12, "console");
	gpioclaim(13, "console");
	gpioclaim(32, "ether");
	gpioclaim(42, "usb");
	gpioclaim(43, "usb");
	etherrp1link();
	nvmelink();
}

void
socusblink(void)
{
	usbxhcirp1link();
}

/*
 * halt: off, by PSCI, which leaves the board waiting for its button.
 * If the firmware will not, the caller resets.
 */
void
boardpoweroff(void)
{
	register u64int x0 __asm__("x0");

	nvmeshutdown();
	uartputstr("halt: powering off; the button starts it again\n");
	microdelay(100000);
	x0 = 0x84000008;	/* SYSTEM_OFF */
	__asm__ volatile("smc #0" : "+r"(x0) : : "memory", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
		"x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17");
}
