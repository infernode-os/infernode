/*
 * The way back to a serial loader, which this board does not have.
 *
 * On the Pi 3B+ (../bcm2837/recover.c) every installed kernel carries
 * serialboot inside it and offers, for 50ms at the top of each boot, to
 * hand the machine back to it, so that a bad kernel costs a reset
 * rather than a walk to the card reader. serialboot is a program with a
 * link address and a UART of its own, and nobody has built or tried one
 * for a BCM2711; until someone does, there is nothing to offer.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

void
serialrecover(void)
{
}
