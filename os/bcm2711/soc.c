/*
 * The devices this SoC has and the rest of the family does not.
 * ../bcm/board.c's boarddevprobe calls this after the family's own
 * probes (the card, the radio), at board init, in kmain.
 *
 * None of them exists under QEMU, and each says so for itself.
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
	ethergenetlink();
}
