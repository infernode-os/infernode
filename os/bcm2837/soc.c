/*
 * The devices this SoC has and the rest of the family does not: none.
 * Everything on a BCM2837 is in ../bcm. ../bcm2711/soc.c is the one
 * with something to say.
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
}

void
socusblink(void)
{
}
