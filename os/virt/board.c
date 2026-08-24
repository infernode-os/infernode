/*
 * QEMU virt board hooks.
 *
 * The virt machine is not a simulation of any real board -- it is a
 * synthetic one, defined by QEMU's hw/arm/virt.c and described to the
 * kernel by the device tree it passes in x0. That makes it the better
 * DEVELOPMENT target of the two ports in this tree, for reasons that
 * are worth stating because they are what justify carrying a second
 * platform at all:
 *
 *   It has a GIC. Writing that driver is what the Pi 4 and Pi 5 need
 *   too, so the work is portable forward rather than being scaffolding
 *   for an emulator.
 *
 *   It has virtio-mmio, which means a network interface, a block
 *   device, a GPU and a multitouch input device are all reachable. None
 *   of those are modelled on QEMU's raspi3b: it has no NIC at all, and
 *   the Pi's own touchscreen path (firmware tag 0x0004000F) is defined
 *   in QEMU's headers but not implemented. So os/ip and any GUI input
 *   work can be developed here and nowhere else in emulation.
 *
 *   It is a second machine that does not share BCM2837's quirks, which
 *   makes it a differential-diagnosis tool: a bug that reproduces on
 *   both is in os/port, and one that reproduces on neither is in the
 *   board code.
 *
 * What it is NOT is a substitute for the board. Nothing here models
 * caches, and it is a synthetic machine with no errata.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define VIRTIO(s, r) \
	(*(volatile u32int*)((uintptr)VIRTIOREGS + (s)*Virtiostride + (r)))

char*
boardname(void)
{
	return "QEMU virt / GICv2";
}

static char*
virtioname(u32int id)
{
	switch(id){
	case 1:  return "net";
	case 2:  return "block";
	case 3:  return "console";
	case 4:  return "entropy";
	case 9:  return "9p";
	case 16: return "gpu";
	case 18: return "input";
	case 19: return "vsock";
	}
	return "unknown";
}

/*
 * Earliest platform bring-up: the device tree, then the GIC.
 *
 * The GIC must exist before clockinit() arms the timer. Arming it
 * succeeds either way -- the comparator does not care whether anything
 * is listening -- so a clock brought up before its interrupt controller
 * produces a kernel that boots normally and never ticks, with nothing
 * in the log to say why.
 */
void
boardprobe(void)
{
	uintptr base, size;

	uartputstr("fdt:  ");
	if(!fdtvalid()){
		uartputstr("none at ");
		uartputx(dtbptr);
		uartputstr(" -- memory size will be a guess\n");
	}else{
		uartputstr("at ");
		uartputx(dtbptr);
		uartputstr(", ");
		uartputd(fdtsize());
		uartputstr(" bytes");
		if(fdtmemory(&base, &size) == 0){
			uartputstr(", memory ");
			uartputd(size >> 20);
			uartputstr("MB at ");
			uartputx(base);
		}else
			uartputstr(", no /memory node");
		uartputstr("\n");
	}

	gicinit();
	uartputstr("gic:  GICv2, ");
	uartputd(gicnirq());
	uartputstr(" INTIDs, dist ");
	uartputx(GICDREGS);
	uartputstr(" cpu ");
	uartputx(GICCREGS);
	uartputstr("\n");
}

/*
 * Walk the virtio-mmio transport slots.
 *
 * QEMU populates them from the TOP down, so slot 31 holds the first
 * -device on the command line. A scan that stopped at the first empty
 * slot would report nothing at all, which is why this walks all of
 * them -- the bug is easy to write and looks like "virtio is broken".
 *
 * Nothing is driven here. This is a presence check: it says what the
 * command line actually attached, which is the fact that is otherwise
 * invisible until a driver exists to fail against it.
 */
void
boardioprobe(void)
{
	int s, found;
	u32int magic, ver, id;

	found = 0;
	for(s = 0; s < Nvirtio; s++){
		magic = VIRTIO(s, Vmagic);
		if(magic != Vmagicval)
			continue;
		id = VIRTIO(s, Vdeviceid);
		if(id == 0)
			continue;		/* slot present but empty */

		ver = VIRTIO(s, Vversion);
		if(found == 0)
			uartputstr("virtio:");
		uartputstr(" [");
		uartputd(s);
		uartputstr("]");
		uartputstr(virtioname(id));
		uartputstr(ver == 1 ? "(legacy)" : "");
		found++;
	}

	if(found == 0)
		uartputstr("virtio: no devices attached "
			"(try -device virtio-net-device,netdev=...)\n");
	else{
		uartputstr(", irq base ");
		uartputd(Spivirtio0);
		uartputstr("\n");
	}
}

/*
 * There is nothing to cross-check CNTFRQ_EL0 against.
 *
 * BCM2837 has a second counter whose 1MHz rate is fixed by hardware
 * rather than reported by firmware, so timing the same interval with
 * both catches a CNTFRQ that lies. virt's only other clock is a PL031
 * RTC at 1Hz, which cannot resolve the 50ms interval that check needs.
 *
 * So this says so. The alternative -- measuring the generic timer
 * against itself -- would print "clocks AGREE" unconditionally, which
 * is worse than printing nothing: it would claim a guarantee the
 * machine cannot provide, on the one target where a developer is most
 * likely to believe the log.
 */
void
boardclockcheck(void)
{
	uartputstr("clk:  no independent reference on this machine "
		"(PL031 is 1Hz) -- cntfrq unverified\n");
}

/*
 * No framebuffer yet.
 *
 * virt has no firmware framebuffer -- there is no VideoCore and no
 * mailbox. The two routes are ramfb, which is configured through fw_cfg
 * and is the smaller job, and virtio-gpu, which is the real one and
 * would also bring virtio-input (and therefore multitouch) within
 * reach. Both are the natural next step for this port; neither is
 * started, and saying so is better than a silent absence.
 */
void
boardfbprobe(void)
{
	uartputstr("fb:   none (virt has no firmware framebuffer; "
		"ramfb/virtio-gpu not implemented)\n");
}
