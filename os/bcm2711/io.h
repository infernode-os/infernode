/*
 * BCM2711 (Raspberry Pi 4) memory-mapped peripheral layout.
 *
 * The same family of blocks as the BCM2837, moved: the peripheral
 * window is at 0xFE000000 in the "low peripheral" mode the firmware
 * boots 64-bit kernels in (the datasheet's 0x7E000000 is the VideoCore's
 * bus address for the same thing), and the ARM-local block follows it
 * at 0xFF800000.
 *
 * What is NEW is how interrupts arrive. The BCM2837 funnels the
 * VideoCore's 72 sources into one bit of a per-core register
 * (../bcm2837/intr.c). The BCM2711 has an ARM GIC-400 -- a GICv2, which
 * is ../arm64/gic.c -- and every source has a number of its own:
 *
 *	INTID 30		the generic timer, per core
 *	INTID 64 + n		"ARMC" source n: the ARM timer, mailboxes, doorbells
 *	INTID 96 + n		VideoCore peripheral interrupt n -- the numbers
 *				../bcm2837/io.h has for the same devices, plus 96
 *
 * (In device-tree terms those are GIC_SPI 32+n and GIC_SPI 64+n; INTIDs
 * are 32 higher. Linux's bcm2711.dtsi has the PL011 at SPI 121, which is
 * VideoCore interrupt 57 -- the BCM2837's IRQuart.) The legacy
 * controller is still in the chip, and the firmware leaves interrupts
 * on the GIC unless config.txt says enable_gic=0. Do not say that.
 */

#define BOARDNAME	"BCM2711 / Raspberry Pi 4B"

enum
{
	PHYSIO		= 0xFE000000,	/* peripheral base */
	ARMLOCAL	= 0xFF800000,	/* ARM-local block: unused here, the GIC does its job */

	GICDREGS	= 0xFF841000,	/* GIC-400 distributor */
	GICCREGS	= 0xFF842000,	/* GIC-400 CPU interface */
};

enum
{
	Nirq		= 256,		/* the GIC-400 here has 192 shared interrupts */

	IRQcntpnsirq	= 30,		/* PPI: the non-secure physical timer */
	IRQspi		= 32,		/* first shared interrupt */
	IRQbasic	= 64,		/* ARMC source 0 */
	IRQvc		= 96,		/* VideoCore peripheral interrupt 0 */

	IRQtimerArm	= IRQbasic + 0,	/* the ARM-side timer; ../bcm/timers.c */
	IRQusb		= IRQvc + 9,	/* DWC OTG: the USB-C port on the board, the only USB under QEMU */
	IRQaux		= IRQvc + 29,	/* the AUX block: mini-UART */
	IRQgpio0	= IRQvc + 49,	/* GPIO bank 0 */
	IRQgpio1	= IRQvc + 50,	/* bank 1 */
	IRQgpio2	= IRQvc + 51,	/* bank 2 */
	IRQsdhost	= IRQvc + 56,	/* SDHOST: present, and wired to nothing on this board */
	IRQuart		= IRQvc + 57,	/* the PL011s, all of them, share this */
	IRQmmc		= IRQvc + 62,	/* both SDHCI controllers share this */

	/*
	 * ../arm64/gic.c's self-test wants a shared interrupt nothing
	 * drives. os/bcm/board.c does not use it -- it makes the system
	 * timer interrupt, which is a better test -- but gic.c is compiled
	 * whole.
	 */
	IRQprobe	= IRQspi + 191,
};

/*
 * The SD card is on EMMC2, a second SDHCI controller this SoC added for
 * it, with pins of its own; the first (the "Arasan", at +0x300000) is
 * wired to the radio, as on a Pi 3, and SDHOST to nothing. ../bcm/emmc.c
 * drives ONE controller, at EMMCREGS, so for now this board points it at
 * EMMC2 and builds the card onto it (SDCARD_ARASAN, in mem.h), which
 * means the radio has no controller: ether4330.c says so at boot and
 * does not probe. Wi-Fi on this board needs emmc.c to take an instance.
 */
#define EMMCOFF		0x340000
#define CLKEMMC		12		/* the mailbox's clock id for EMMC2 */

/*
 * ...and QEMU's raspi4b (as of 9.2) attaches the card to the first
 * controller instead, as if the board had a Pi 3's pin mux. emmc.c looks
 * here if, and only if, EMMC2 reports no card and this one reports one,
 * and says that it has.
 */
#define EMMCALTOFF	0x300000

#include "../bcm/bcmio.h"
