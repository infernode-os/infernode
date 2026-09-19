/*
 * BCM2837 (Raspberry Pi 3B+) memory-mapped peripheral layout.
 *
 * The BCM2837 maps peripherals at physical 0x3F000000, unlike the
 * BCM2835 (Pi 1 / Zero) which used 0x20000000.  QEMU's raspi3b machine
 * model matches the real silicon here.  Once the MMU is enabled these
 * become virtual addresses and only this file should need to change.
 */

enum
{
	PHYSIO		= 0x3F000000,	/* peripheral base */

	/*
	 * ARM local peripherals: per-core timer and mailbox routing.
	 * These live OUTSIDE the 0x3F000000 peripheral window, at a
	 * separate base introduced with the BCM2836 for multicore.
	 */
	ARMLOCAL	= 0x40000000,
};

/* ARM local peripheral register offsets */
enum
{
	Lcontrol	= 0x00,
	Lprescaler	= 0x08,
	Lgpuirqrouting	= 0x0C,		/* which core sees GPU interrupts */
	Ltimerirq0	= 0x40,		/* core 0 timer IRQ control */
	Lirqsource0	= 0x60,		/* core 0 IRQ source */
};

/*
 * Accessor for the ARM local block. A separate window from the
 * 0x3F000000 peripheral base -- it arrived with BCM2836 for multicore.
 */
#define LOCAL(r)	(*(volatile u32int*)((uintptr)ARMLOCAL + (r)))

/*
 * Bits in a core's IRQ source register.
 *
 * Igpu is the one that matters for devices: EVERY one of the 72
 * interrupts owned by the VideoCore controller arrives here as this
 * single bit, and the handler must then ask that controller which one
 * actually fired.
 */
enum
{
	Igpu		= 1<<8,		/* some GPU interrupt is pending */
};

/*
 * The VideoCore interrupt controller: 64 GPU sources then 8 ARM ones.
 */
enum
{
	Nirq		= 72,
	IRQusb		= 9,		/* DWC OTG host controller */
	IRQaux		= 29,		/* the AUX block: mini-UART (and SPI1/2, unused) */
	IRQgpio0	= 49,		/* GPIO bank 0, pins 0-27 */
	IRQgpio1	= 50,		/* bank 1, pins 28-45 */
	IRQgpio2	= 51,		/* bank 2, pins 46-53 */
	IRQsdhost	= 56,		/* the BCM2835 SDHOST controller */
	IRQuart		= 57,		/* the PL011 */
	IRQmmc		= 62,		/* the Arasan SDHCI controller */
	IRQbasic	= 64,		/* first ARM-private source */
	IRQtimerArm	= IRQbasic + 0,	/* the ARM-side timer below */
};

/*
 * Core timer IRQ control bits.  We run at EL1 non-secure, so the
 * physical timer we can reach is the non-secure one: CNTPNSIRQ.
 */
enum
{
	Cntpsirq	= 1<<0,		/* secure physical */
	Cntpnsirq	= 1<<1,		/* non-secure physical -- ours */
	Cntphpirq	= 1<<2,		/* hypervisor physical */
	Cntvirq		= 1<<3,		/* virtual */
};

/*
 * Everything else -- the register layouts of the blocks this SoC shares
 * with the rest of the family, at addresses relative to PHYSIO -- is the
 * family's. It has to come after PHYSIO and the interrupt numbers, which
 * it and the shared drivers are written in terms of.
 */
#include "../bcm/bcmio.h"
