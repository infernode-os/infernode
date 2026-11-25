/*
 * The first component of the seL4 target: it prints that it started.
 * It is replaced by the Inferno component (docs/SEL4.md, "Order of work");
 * until then tests/host/sel4_test.sh boots it to check the toolchain,
 * the pinned SDK and QEMU.
 */
#include <microkit.h>

void
init(void)
{
	microkit_dbg_puts("sel4: inferno component started\n");
}

void
notified(microkit_channel ch)
{
	(void)ch;
}
