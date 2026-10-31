/*
 * The device table: which devices this board's kernel includes.
 * ../virt/devtab.c's, less what this board has no hardware or driver
 * for yet: USB (no host controller). #i and #m are here with no display
 * behind them, as on a Pi with no monitor plugged in.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern Dev rootdevtab;
extern Dev consdevtab;
extern Dev progdevtab;
extern Dev pipedevtab;
extern Dev mntdevtab;
extern Dev envdevtab;
extern Dev ipdevtab;
extern Dev sddevtab;
extern Dev bootdevtab;
extern Dev benchdevtab;
extern Dev srvdevtab;
extern Dev etherdevtab;
extern Dev ssldevtab;
extern Dev uartdevtab;
extern Dev pointerdevtab;
extern Dev drawdevtab;

Dev*	devtab[] =
{
	&rootdevtab,		/* '/' -- the namespace root */
	&consdevtab,		/* 'c' -- /dev/cons and friends */
	&progdevtab,		/* 'p' -- #p, the process device */
	&pipedevtab,		/* '|' -- #|, pipes */
	&mntdevtab,		/* 'M' -- #M, the 9P client */
	&envdevtab,		/* 'e' -- #e, the environment */
	&ipdevtab,		/* 'I' -- #I, the IP stack */
	&sddevtab,		/* 'S' -- #S, the disk as a file: a virtio block device */
	&bootdevtab,		/* 'B' -- #B, the running kernel image */
	&benchdevtab,		/* 'b' -- #b, microsecond timing */
	&srvdevtab,		/* 's' -- #s, names a Limbo program serves */
	&etherdevtab,		/* 'l' -- #l, the kernel Ethernet data path */
	&ssldevtab,		/* 'D' -- #D, SSL/TLS record layer */
	&uartdevtab,		/* 't' -- #t, serial ports: eia0 the 16550, the console */
	&pointerdevtab,		/* 'm' -- #m, the pointer */
	&drawdevtab,		/* 'i' -- #i, the draw device */
	nil,
};
