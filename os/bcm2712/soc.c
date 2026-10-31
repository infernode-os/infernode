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
