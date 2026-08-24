/*
 * QEMU "virt" machine memory-mapped layout.
 *
 * Unlike a real SoC this map is not silicon, it is a contract: QEMU's
 * hw/arm/virt.c fixes these addresses and the device tree it hands the
 * kernel describes them.  Hardcoding them here rather than reading the
 * DTB is a deliberate simplification for the console and the interrupt
 * controller -- the two things needed before a DTB parser can report
 * anything -- and memory sizing, which genuinely varies with -m, is read
 * from the device tree instead (see ../arm64/fdt.c).
 *
 * The whole low 1GB is peripheral space; RAM starts at 1GB.  That is the
 * opposite of BCM2837, where RAM starts at 0 and peripherals sit above
 * it, which is why mmu.c here cannot simply be the Pi's with a different
 * constant.
 */

enum
{
	/* interrupt controller: GICv2, as -M virt,gic-version=2 provides */
	GICDREGS	= 0x08000000,	/* distributor */
	GICCREGS	= 0x08010000,	/* CPU interface */

	UART0REGS	= 0x09000000,	/* PL011, wired to serial0 */
	RTCREGS		= 0x09010000,	/* PL031 */
	FWCFGREGS	= 0x09020000,
	GPIOREGS	= 0x09030000,	/* PL061 */

	/*
	 * 32 virtio-mmio transport slots.  QEMU populates them from the
	 * TOP down, so slot 31 holds the first -device on the command
	 * line and a scan that stops at the first empty slot finds
	 * nothing.  boardioprobe() walks all of them.
	 */
	VIRTIOREGS	= 0x0A000000,
	Nvirtio		= 32,
	Virtiostride	= 0x200,

	PHYSMEM		= 0x40000000,	/* RAM base */
};

/*
 * Interrupt numbers, as INTIDs rather than as the SPI/PPI numbers
 * QEMU's source uses.  The translation is the usual one: PPI n is
 * INTID 16+n, SPI n is INTID 32+n.  Getting this wrong is quiet --
 * enabling the wrong INTID succeeds and the interrupt simply never
 * arrives -- so the arithmetic is written out rather than folded in.
 */
enum
{
	Ppitimer	= 30,		/* PPI 14: non-secure EL1 physical timer */
	Spiuart		= 33,		/* SPI 1:  PL011 */
	Spivirtio0	= 48,		/* SPI 16: first virtio-mmio slot */

	Nirq		= 256,		/* INTIDs this port configures */
};

/* GICv2 distributor register offsets */
enum
{
	Gicdctlr	= 0x000,
	Gicdtyper	= 0x004,
	Gicdigroup0	= 0x080,
	Gicdisenable0	= 0x100,
	Gicdicenable0	= 0x180,
	Gicdicpend0	= 0x280,
	Gicdipriority0	= 0x400,
	Gicditargets0	= 0x800,
	Gicdicfg0	= 0xC00,
};

/* GICv2 CPU interface register offsets */
enum
{
	Giccctlr	= 0x00,
	Giccpmr		= 0x04,
	Giccbpr		= 0x08,
	Gicciar		= 0x0C,
	Gicceoir	= 0x10,
};

enum
{
	Gicspurious	= 1023,		/* IAR value meaning "nothing pending" */
	Gicidmask	= 0x3FF,
};

/* virtio-mmio register offsets (the few a presence scan needs) */
enum
{
	Vmagic		= 0x000,
	Vversion	= 0x004,
	Vdeviceid	= 0x008,
	Vvendorid	= 0x00C,

	Vmagicval	= 0x74726976,	/* "virt", little-endian */
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
