/*
 * os/amd64/pcitest.c -- what the loader put on the PCI bus.
 *
 * Prints vendor and device for every function that answers, so the
 * virtio-net driver has something to point at when a device is not
 * found where it was expected.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

void
pcitest(void)
{
	int bus, dev, fn;
	uint32_t id;

	if(portprocinit() < 0){
		consprint("pcitest: no memory above the kernel\n");
		return;
	}
	for(bus = 0; bus < 2; bus++)
	for(dev = 0; dev < 32; dev++)
	for(fn = 0; fn < 8; fn++){
		id = pcicfgr32(bus, dev, fn, 0);
		if((id & 0xFFFF) == 0xFFFF)
			continue;
		print("pci %d:%d.%d %4.4ux:%4.4ux class %2.2ux rev %2.2ux\n",
			bus, dev, fn, id & 0xFFFF, id >> 16,
			pcicfgr8(bus, dev, fn, 0x0B),
			pcicfgr8(bus, dev, fn, 0x08));
	}
	print("pcitest passed\n");
	conshalt();
}
