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
	pcibcmlink();
}

/*
 * The USB-A sockets: a VL805 xHCI controller, if pcibcmlink found the
 * bridge and the bus scan found it. Under QEMU there is no bus and this
 * finds nothing, silently; pcibcmlink has already said why.
 */
void
socusblink(void)
{
	usbxhcipcilink();
}
