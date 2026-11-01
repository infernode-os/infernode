/*
 * BCM2712 (Raspberry Pi 5) memory-mapped peripheral layout.
 *
 * Everything is above 4GB, which is why these are macros: they do not
 * fit the int enums of ../bcm/bcmio.h, and the blocks are not at the
 * family's offsets from any one base. os/bcm2712/README.md has what the
 * board reported; the addresses are from Linux's bcm2712.dtsi.
 */

#define BOARDNAME	"BCM2712 / Raspberry Pi 5"

#define BCMBLOCKS	1
#define MBOXREGS	0x107C013880ULL
#define SYSTIMERREGS	0x107C003000ULL
#define PMREGS		0x107D200000ULL
#define GICDREGS	0x107FFF9000ULL
#define GICCREGS	0x107FFFA000ULL
#define GICRREGS	0

/*
 * RP1, behind PCIe, where the firmware leaves it; Linux's 0x1F00000000
 * is what Linux programs the bridge to. Its UART0 is on GPIO14/15.
 */
#define RP1REGS		0x1C00000000ULL
#define RP1UART0	(RP1REGS + 0x30000)
#define RP1UART4	(RP1REGS + 0x40000)
#define UART10		0x107D001000ULL
#define RP1ETH		(RP1REGS + 0x100000)
#define PCIE2REGS	0x1000120000ULL
#define PCIE1REGS	0x1000110000ULL	/* the external connector: pcie1.c */
#define PCIE1WIN	0x1B80000000ULL	/* its devices' registers */

enum
{
	Nirq		= 352,		/* the GIC reports 320 */

	IRQcntpnsirq	= 30,		/* PPI: the non-secure physical timer */
	IRQspi		= 32,
	IRQvc		= 96,		/* SPI 64: the system timer's channel 0, as on a Pi 4 */

	IRQprobe	= IRQspi + 287,	/* nothing drives it; ../arm64/gic.c's self-test */
};

#include "../bcm/bcmio.h"
