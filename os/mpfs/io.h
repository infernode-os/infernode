/*
 * Microchip PolarFire SoC: where things are. The MSS (microprocessor
 * subsystem) map is the same on every PolarFire SoC board, and QEMU's
 * microchip-icicle-kit model follows it (hw/riscv/microchip_pfsoc.c).
 */

enum
{
	CLINTREGS	= 0x02000000,	/* the firmware's */
	PLICREGS	= 0x0C000000,
	MMUART0REGS	= 0x20000000,	/* the BeagleV-Fire's debug header */
	SYSREGREGS	= 0x20002000,
	EMMCSDREGS	= 0x20008000,	/* Cadence SD4HC */
	MMUART1REGS	= 0x20100000,
	MMUART2REGS	= 0x20102000,
	MMUART3REGS	= 0x20104000,
	MMUART4REGS	= 0x20106000,
	GEM0REGS	= 0x20110000,	/* Cadence GEM Ethernet */
	GEM1REGS	= 0x20112000,
	GPIO2REGS	= 0x20122000,
	RTCREGS		= 0x20124000,
	SCBCTRLREGS	= 0x37020000,	/* the system controller's service request */
	MAILBOXREGS	= 0x37020800,	/* the system controller's services */

	Nirq		= 187,		/* PLIC sources 1..186 */
	IRQgem0		= 64,
	IRQemmcsd	= 88,
	IRQmmuart0	= 90,
	IRQmmuart1	= 91,
	IRQmmuart2	= 92,
	IRQmmuart3	= 93,
	IRQmmuart4	= 94,
	IRQmailbox	= 96,
};

/*
 * ../riscv64/uart16550.c's parameters. The MMUART is 16550-compatible
 * with 32-bit registers four bytes apart. UARTCLK 0: the firmware has
 * the console at its rate already, and the MMUART's fractional divisor
 * is not a 16550's, so reprogramming it is for a driver that knows it.
 */
#define	UARTREGS	MMUART0REGS
#define	UARTSHIFT	2
#define	UARTWIDE	1
#define	UARTCLK		0
#define	UARTIRQ		IRQmmuart0
