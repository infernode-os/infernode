/*
 * This board's interrupt controller is ../arm64/gic.c, whole. What is
 * here is the one question about it that is this board's to ask.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

/*
 * boardintrprobe: does a device interrupt reach a handler?
 *
 * First the family's way: make a system-timer channel match and wait
 * for VideoCore interrupt 3 -- here GIC interrupt 99. That is the real
 * test, because it involves a wire: the right block, raising the right
 * line, numbered the way io.h says.
 *
 * QEMU's raspi4b (9.2) does not connect that wire. The timer counts and
 * matches and nothing becomes pending in the GIC, as the dump this
 * prints shows. So if it fails, ask the GIC itself, which can be told to
 * raise an interrupt with no device's help (gicintrprobe). That one
 * passing says the controller, the vector and end-of-interrupt work and
 * the missing piece is the source -- which is what an emulator that has
 * not modelled the wire looks like. BOTH failing is a broken GIC.
 *
 * On a board the first should pass. If it does not, do not be consoled
 * by the second: it means the interrupt numbers in io.h are wrong.
 */
void
boardintrprobe(void)
{
	if(bcmintrprobe())
		return;
	print("intr: asking the GIC directly; if this passes, the system timer is not wired to it (QEMU) or io.h's numbers are wrong (a board)\n");
	gicintrprobe();
}
