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
	Stchi		= 0x08,
};

/* ARM local peripheral register offsets */
enum
{
	Lcontrol	= 0x00,
	Lprescaler	= 0x08,
	Ltimerirq0	= 0x40,		/* core 0 timer IRQ control */
	Lirqsource0	= 0x60,		/* core 0 IRQ source */
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

	Taggettouchbuf	= 0x0004000F,

	Tagend		= 0x00000000,
};

/* PL011 UART register offsets */
enum
{
	Dr		= 0x00,		/* data */
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
