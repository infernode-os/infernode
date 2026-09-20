/*
 * Where things are on QEMU's `virt` machine, and their registers.
 *
 * The addresses are hw/arm/virt.c's base_memmap[]. They are also in the
 * device tree QEMU hands over, and a kernel meant for more than one
 * machine would read them from there; this one is meant for exactly
 * this machine, whose map QEMU has kept fixed since 2.x because guests
 * like this one exist. What DOES vary -- how much RAM, which virtio
 * slots hold what -- is read at boot and not written down here.
 *
 * Everything in this file is below RAMZERO. That is the inverse of the
 * board, where peripherals sit above memory, and it is the first thing
 * to get wrong: see mmu.c.
 */
enum
{
	GICDREGS	= 0x08000000,	/* GICv2 distributor */
	GICCREGS	= 0x08010000,	/* GICv2 CPU interface */
	GICV2MREGS	= 0x08020000,	/* GICv2m: the frame a PCI device writes to for an MSI; pciecam.c */
	UART0REGS	= 0x09000000,	/* PL011 */
	RTCREGS		= 0x09010000,	/* PL031 */
	FWCFGREGS	= 0x09020000,	/* fw_cfg: how ramfb is configured */
	VIRTIOREGS	= 0x0A000000,	/* virtio-mmio transports */
	PCIMMIO		= 0x10000000,	/* where PCI devices' registers are put; pciecam.c */
	PCIMMIOSIZE	= 0x2EFF0000,
	PCIECAMLOW	= 0x3F000000,	/* PCI configuration space, if highmem-ecam=off */

	Nvirtio		= 32,		/* how many, */
	Virtiostride	= 0x200,	/* this far apart */
};

/*
 * ...and the one thing that is above it: PCI configuration space, by
 * default. 256GB up; mmu.c maps the gigabyte it is in.
 */
#define PCIECAMHIGH	0x4010000000ULL

/*
 * Interrupts, as GIC INTIDs: 0-15 are software-generated, 16-31 are
 * private to a core, and the shared peripheral interrupts the device
 * tree numbers from zero start at 32 -- so the tree's "SPI 1" for the
 * PL011 is 33 here.
 */
enum
{
	Nirq		= 160,		/* wires end at 32+95; the MSI frame's 64 interrupts follow, 80-143 */

	IRQcntvirq	= 27,		/* PPI: the virtual timer */
	IRQcntpnsirq	= 30,		/* PPI: the non-secure physical timer -- ours */

	IRQspi		= 32,
	IRQuart		= IRQspi + 1,
	IRQrtc		= IRQspi + 2,
	IRQpcie		= IRQspi + 3,	/* and the next three: the PCIe bridge's INTA-INTD */
	IRQvirtio0	= IRQspi + 16,	/* transport n interrupts on IRQvirtio0+n */
	IRQprobe	= IRQspi + 15,	/* wired to nothing (10-15 are spare): ../arm64/gic.c's self-test */
};

/*
 * The PL011. Offsets and bits are os/bcm2837/io.h's, because the part
 * is the same part; only its address and its clock differ.
 */
enum
{
	Dr		= 0x00,		/* data */
	Rsrecr		= 0x04,		/* receive status; write clears errors */
	Fr		= 0x18,		/* flag */
	Ibrd		= 0x24,		/* integer baud rate divisor */
	Fbrd		= 0x28,		/* fractional baud rate divisor */
	Lcrh		= 0x2C,		/* line control */
	Cr		= 0x30,		/* control */
	Ifls		= 0x34,		/* FIFO interrupt levels */
	Imsc		= 0x38,		/* interrupt mask */
	Ris		= 0x3C,		/* raw interrupt status */
	Mis		= 0x40,		/* masked interrupt status */
	Icr		= 0x44,		/* interrupt clear */
};

enum
{
	Frcts		= 1<<0,		/* clear to send (the peer's RTS) */
	Frbusy		= 1<<3,		/* transmitting */
	Rxfe		= 1<<4,		/* receive FIFO empty */
	Txff		= 1<<5,		/* transmit FIFO full */
	Frrxff		= 1<<6,		/* receive FIFO full */
	Frtxfe		= 1<<7,		/* transmit FIFO empty */
};

/* Dr bits: the receive errors ride along with the byte */
enum
{
	Rxerrors	= 0xF<<8,	/* framing, parity, break, overrun */
	Rxfe_err	= 1<<8,		/* framing */
	Rxpe_err	= 1<<9,		/* parity */
	Rxbe_err	= 1<<10,	/* break */
	Rxoe_err	= 1<<11,	/* overrun */
};

/* Lcrh bits */
enum
{
	Lcrbrk		= 1<<0,		/* send break */
	Lcrpen		= 1<<1,		/* parity enable */
	Lcreps		= 1<<2,		/* even parity */
	Lcrstp2		= 1<<3,		/* two stop bits */
	Fen		= 1<<4,		/* enable FIFOs */
	Wlen5		= 0<<5,
	Wlen6		= 1<<5,
	Wlen7		= 2<<5,
	Wlen8		= 3<<5,		/* 8-bit words */
	Wlenmask	= 3<<5,
};

/* Cr bits */
enum
{
	Uarten		= 1<<0,
	Txe		= 1<<8,
	Rxe		= 1<<9,
	Crrts		= 1<<11,	/* drive RTS (active low on the pin) */
	Crrtsen		= 1<<14,	/* hardware flow control: RTS follows FIFO room */
	Crctsen		= 1<<15,	/* hardware flow control: transmit only while CTS */
};

/* Imsc / Mis / Icr bits */
enum
{
	Imcts		= 1<<1,		/* CTS changed */
	Imrx		= 1<<4,		/* receive FIFO at level */
	Imtx		= 1<<5,		/* transmit FIFO at level */
	Imrt		= 1<<6,		/* receive timeout: bytes waiting below level */
	Imfe		= 1<<7,
	Impe		= 1<<8,
	Imbe		= 1<<9,
	Imoe		= 1<<10,
	Imrxerr		= Imfe|Impe|Imbe|Imoe,
};

/* Ifls: 1/8 full for receive so a single HCI byte is seen promptly */
enum
{
	Txiflsel1_8	= 0<<0,
	Rxiflsel1_8	= 0<<3,
	Rxiflsel1_2	= 2<<3,
};
