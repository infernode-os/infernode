/*
 * QEMU's RISC-V `virt' machine: where things are
 * (hw/riscv/virt.c, virt_memmap and the IRQ enum).
 */

enum
{
	TESTREGS	= 0x00100000,	/* sifive,test: poweroff and reset */
	RTCREGS		= 0x00101000,	/* goldfish RTC */
	CLINTREGS	= 0x02000000,	/* the firmware's; not touched from S-mode */
	PLICREGS	= 0x0C000000,
	UART0REGS	= 0x10000000,	/* NS16550A */
	VIRTIOREGS	= 0x10001000,	/* virtio-mmio transports */
	FWCFGREGS	= 0x10100000,

	Nvirtio		= 8,		/* how many, */
	Virtiostride	= 0x1000,	/* this far apart */

	Nirq		= 96,		/* PLIC sources 1..95 */
	IRQvirtio0	= 1,		/* transport n interrupts on IRQvirtio0+n */
	IRQuart		= 10,
	IRQrtc		= 11,
};

/* ../riscv64/uart16550.c's parameters: byte registers a byte apart */
#define	UARTREGS	UART0REGS
#define	UARTSHIFT	0
#define	UARTWIDE	0
#define	UARTCLK		3686400		/* virt's "clock-frequency" for the UART */
#define	UARTIRQ		IRQuart
