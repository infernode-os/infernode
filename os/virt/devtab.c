/*
 * The device table: which devices this board's kernel includes.
 *
 * os/bcm2837/devtab.c less what is soldered to a Raspberry Pi -- GPIO
 * (#G), the touch panel (#T), the audio jack (#A). #S is here, because
 * a virtio disk answers to it (devsd.c); #u is here and empty, because
 * osinit binds it and walks a bus with nothing on it without complaint,
 * and leaving it in keeps the two kernels' namespaces the same shape.
 *
 * Nil-terminated; see the board's for why that is not optional.
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
extern Dev usbdevtab;
extern Dev mntdevtab;
extern Dev envdevtab;
extern Dev ipdevtab;
extern Dev pointerdevtab;
extern Dev sddevtab;
extern Dev bootdevtab;
extern Dev benchdevtab;
extern Dev drawdevtab;
extern Dev srvdevtab;
extern Dev etherdevtab;
extern Dev ssldevtab;
extern Dev uartdevtab;

Dev*	devtab[] =
{
	&rootdevtab,		/* '/' -- the namespace root */
	&consdevtab,		/* 'c' -- /dev/cons and friends */
	&progdevtab,		/* 'p' -- #p, the process device */
	&pipedevtab,		/* '|' -- #|, pipes */
	&usbdevtab,		/* 'u' -- #u, USB: no controller on this machine */
	&mntdevtab,		/* 'M' -- #M, the 9P client */
	&envdevtab,		/* 'e' -- #e, the environment */
	&ipdevtab,		/* 'I' -- #I, the IP stack */
	&pointerdevtab,		/* 'm' -- #m, the pointer */
	&sddevtab,		/* 'S' -- #S, the disk as a file: a virtio block device */
	&bootdevtab,		/* 'B' -- #B, the running kernel image */
	&benchdevtab,		/* 'b' -- #b, microsecond timing for benchmarks */
	&drawdevtab,		/* 'i' -- #i, the draw device */
	&srvdevtab,		/* 's' -- #s, names a Limbo program serves */
	&etherdevtab,		/* 'l' -- #l, the kernel Ethernet data path */
	&ssldevtab,		/* 'D' -- #D, SSL/TLS record layer; secstore's transport */
	&uartdevtab,		/* 't' -- #t, serial ports: eia0 the PL011, the console */
	nil,
};
