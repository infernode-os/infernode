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

	GPIOREGS	= PHYSIO+0x200000,
	UART0REGS	= PHYSIO+0x201000,	/* PL011 */
	MBOXREGS	= PHYSIO+0x00B880,	/* VideoCore mailbox */
	SYSTIMERREGS	= PHYSIO+0x003000,	/* free-running 1MHz counter */

	/*
	 * ARM local peripherals: per-core timer and mailbox routing.
	 * These live OUTSIDE the 0x3F000000 peripheral window, at a
	 * separate base introduced with the BCM2836 for multicore.
	 */
	ARMLOCAL	= 0x40000000,
};

/* BCM system timer: a 64-bit free-running counter ticking at 1MHz */
enum
{
	Stcs		= 0x00,
	Stclo		= 0x04,
	Stc0		= 0x0C,		/* compare 0..3; a match raises GPU IRQ n */
	Stchi		= 0x08,
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
	IRQbasic	= 64,		/* first ARM-private source */
	IRQtimerArm	= IRQbasic + 0,	/* the ARM-side timer below */
};

/*
 * The ARM-side timer (an SP804 variant), separate from both the
 * generic timer and the VideoCore system timer.
 *
 * This kernel does not need it to keep time -- the generic timer does
 * that. It is here because usbdwc.c uses it as a deferral mechanism:
 * the USB interrupt does the hardware work, then schedules this timer
 * to raise an ordinary interrupt on which it is safe to call wakeup().
 */
enum
{
	ARMTIMERREGS	= PHYSIO+0x00B400,
	PMREGS		= PHYSIO+0x100000,	/* power management / watchdog */
	EMMCREGS	= PHYSIO+0x300000,	/* SD card host controller */

	/*
	 * The watchdog, which is how this SoC reboots: there is no reset
	 * line to pull. Arm it with a short timeout and let it expire.
	 * Every write needs the password in the top half or it is
	 * ignored silently.
	 */
	Pmrstc		= 0x1C,
	Pmrsts		= 0x20,
	Pmwdog		= 0x24,
	Pmpassword	= 0x5A000000,
	Pmwrcfgclr	= 0xFFFFFFCF,
	Pmwrcfgfull	= 0x00000020,	/* full reset */
	Pmrststryboot	= 0x00000020,	/* one-shot: firmware loads tryboot.txt */

	TmrEnable	= 1<<7,
	TmrIntEnable	= 1<<5,
};

/*
 * VideoCore power domains, indices for the mailbox set-power tag.
 * USB is off at reset and the controller reads back as absent until
 * the firmware is asked to power it on.
 */
enum
{
	PowerSd		= 0,
	PowerUart0,
	PowerUart1,
	PowerUsb,
	PowerI2c0,
	PowerI2c1,
	PowerI2c2,
	PowerSpi,
	PowerCcp2tx,
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
 * The VideoCore sees memory through its own bus addresses.  ORing in
 * 0xC0000000 selects the alias that bypasses the VC L2 cache, which is
 * what we want for buffers the ARM has written: it means the GPU is not
 * reading through a cache the ARM cannot flush.
 */
#define BUSADDR(a)	(((uintptr)(a) & ~0xC0000000UL) | 0xC0000000UL)

/* mailbox register offsets */
enum
{
	Mboxread	= 0x00,
	Mboxstatus	= 0x18,
	Mboxwrite	= 0x20,

	Mboxfull	= 0x80000000,
	Mboxempty	= 0x40000000,

	Mboxchanprop	= 8,	/* ARM -> VC property tags */
};

/* property interface response codes */
enum
{
	Propreq		= 0x00000000,
	Propok		= 0x80000000,
	Properr		= 0x80000001,
};

/* property tags we use */
enum
{
	Taggetfwrev	= 0x00000001,
	Taggetmodel	= 0x00010001,
	Taggetrev	= 0x00010002,
	Taggetmac	= 0x00010003,
	Taggetserial	= 0x00010004,
	Taggetarmmem	= 0x00010005,
	Taggetvcmem	= 0x00010006,

	Tagfballoc	= 0x00040001,
	Tagfbgetdim	= 0x00040003,	/* physical (display) w/h */
	Tagfbgetpitch	= 0x00040008,
	Tagfbsetdim	= 0x00048003,	/* physical w/h */
	Tagfbsetvdim	= 0x00048004,	/* virtual w/h */
	Tagfbsetdepth	= 0x00048005,
	Tagfbsetorder	= 0x00048006,
	Tagfbsetvoff	= 0x00048009,
	Tagfbgetvoff	= 0x00040009,
	Tagfbgetnumdisp	= 0x00040013,	/* how many displays the firmware has */
	Tagfbsetdispnum	= 0x00048013,	/* which one later fb tags apply to */

	Taggettouchbuf	= 0x0004000F,
	Taggetclockrate	= 0x00030002,	/* a peripheral clock's actual rate */
	Taggetedidblock	= 0x00030020,	/* the display's own description */

	Clkemmc		= 1,		/* clock id for the SD controller */

	Tagend		= 0x00000000,
};

/* PL011 UART register offsets */
enum
{
	Dr		= 0x00,		/* data */
	Rsrecr		= 0x04,		/* receive status; write clears errors */
	Fr		= 0x18,		/* flag */
	Ibrd		= 0x24,		/* integer baud rate divisor */
	Fbrd		= 0x28,		/* fractional baud rate divisor */
	Lcrh		= 0x2C,		/* line control */
	Cr		= 0x30,		/* control */
	Imsc		= 0x38,		/* interrupt mask */
	Icr		= 0x44,		/* interrupt clear */
};

/* Fr bits */
enum
{
	Txff		= 1<<5,		/* transmit FIFO full */
	Rxfe		= 1<<4,		/* receive FIFO empty */
};

/* Dr bits: the receive errors ride along with the byte */
enum
{
	Rxerrors	= 0xF<<8,	/* framing, parity, break, overrun */
};

/* Lcrh bits */
enum
{
	Fen		= 1<<4,		/* enable FIFOs */
	Wlen8		= 3<<5,		/* 8-bit words */
};

/* Cr bits */
enum
{
	Uarten		= 1<<0,
	Txe		= 1<<8,
	Rxe		= 1<<9,
};

/*
 * GPIO register offsets.  GPFSEL is six registers of ten pins, three
 * bits each; SET/CLR/LEV are two registers of 32 pins, one bit each.
 * Set and clear are separate write-only registers so a single pin can be
 * driven without a read-modify-write.
 */
enum
{
	Gpfsel0		= 0x00,
	Gpfsel1		= 0x04,
	Gpset0		= 0x1C,
	Gpclr0		= 0x28,
	Gplev0		= 0x34,
	Gppud		= 0x94,
	Gppudclk0	= 0x98,
};

/* GPIO pin functions, as encoded in GPFSEL */
enum
{
	Gpioin		= 0,
	Gpioout		= 1,
	Gpioalt0	= 4,
	Gpioalt1	= 5,
	Gpioalt2	= 6,
	Gpioalt3	= 7,
	Gpioalt4	= 3,
	Gpioalt5	= 2,
};

/* GPPUD pull states */
enum
{
	Pullnone	= 0,
	Pulldown	= 1,
	Pullup		= 2,
};

/*
 * EMMC register offsets.
 *
 * The BCM2837's SD host controller is an SDHCI-like design: an
 * Arasan controller with the standard register block at a non-standard
 * spacing, which is why these are named rather than taken from a
 * generic SDHCI header.
 */
enum
{
	Emmcarg2	= 0x00,
	Emmcblksizecnt	= 0x04,		/* block size and count */
	Emmcarg1	= 0x08,
	Emmccmdtm	= 0x0C,		/* command and transfer mode */
	Emmcresp0	= 0x10,
	Emmcresp1	= 0x14,
	Emmcresp2	= 0x18,
	Emmcresp3	= 0x1C,
	Emmcdata	= 0x20,
	Emmcstatus	= 0x24,
	Emmccontrol0	= 0x28,
	Emmccontrol1	= 0x2C,
	Emmcinterrupt	= 0x30,
	Emmcirptmask	= 0x34,
	Emmcirpten	= 0x38,
	Emmccontrol2	= 0x3C,
	Emmcslotisrver	= 0xFC,

	/* Emmcstatus */
	Cmdinhibit	= 1<<0,		/* command line in use */
	Datinhibit	= 1<<1,		/* data lines in use */
	Bufwriteen	= 1<<10,
	Bufreaden	= 1<<11,

	/* Emmccontrol0 */
	Hctldwidth4	= 1<<1,
	Hctlhsen	= 1<<2,

	/* Emmccontrol1 */
	Clkintlen	= 1<<0,		/* enable the internal clock */
	Clkstable	= 1<<1,
	Clken		= 1<<2,		/* clock to the card */
	Srsthc		= 1<<24,	/* reset the whole host controller */
	Srstcmd		= 1<<25,
	Srstdata	= 1<<26,

	/* Emmcinterrupt / irptmask / irpten */
	Cmddone		= 1<<0,
	Datadone	= 1<<1,
	Writerdy	= 1<<4,
	Readrdy		= 1<<5,
	Interrorbit	= 1<<15,	/* any error; the detail is above */

	/* Emmccmdtm */
	Tmblkcnten	= 1<<1,
	Tmautocmd12	= 1<<2,
	Tmdatdirread	= 1<<4,
	Tmmultiblock	= 1<<5,
	Cmdrspnone	= 0<<16,
	Cmdrsp136	= 1<<16,
	Cmdrsp48	= 2<<16,
	Cmdrsp48busy	= 3<<16,
	Cmdcrcchk	= 1<<19,
	Cmdidxchk	= 1<<20,
	Cmdisdata	= 1<<21,
};
