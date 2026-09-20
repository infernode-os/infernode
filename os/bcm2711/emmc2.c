/*
 * EMMC2: the BCM2711's second SDHCI controller, which is where a
 * Raspberry Pi 4's SD card is.
 *
 * It is the same kind of controller as the Arasan that ../bcm/emmc.c
 * drives -- on a Pi 3 for the radio, or for the card when a kernel is
 * built that way -- and this is that driver, compiled a second time
 * with a different base, clock and name. emmc.c explains the
 * arrangement. The Arasan stays what it is on a Pi 3, the radio's, and
 * the two are driven at once.
 *
 * "The same kind" is an assumption that QEMU cannot test, because
 * QEMU's raspi4b puts the card on the Arasan: under emulation this
 * instance looks at EMMC2, finds no card, finds one on the Arasan, says
 * so, and drives that (EMMCALTBASE). So the code below has never
 * addressed a real EMMC2. What is known to differ on the silicon and is
 * NOT handled: EMMC2's bus is behind its own 1GB-limited DMA window on
 * early chip revisions (irrelevant while this driver is PIO), and the
 * card's 3.3V/1.8V supply is switched by a regulator on a firmware GPIO
 * (irrelevant until anyone asks for UHS speeds).
 */
#define EMMCIO		emmc2io
#define EMMCNAME	"emmc2"
#define EMMCBASE	EMMC2REGS
#define EMMCCLK		Clkemmc2
#define EMMCALTBASE	EMMCREGS
/* no EMMCCARDPINS: EMMC2's pins are its own */

#include "../bcm/emmc.c"
