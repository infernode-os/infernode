/*
 * An SD card controller, as the card layer sees it.
 *
 * os/bcm/sdmmc.c speaks the card's protocol -- identification, the CSD,
 * block reads and writes -- and knows nothing about registers. A
 * controller is an SDio: the handful of operations the card layer needs
 * from whatever piece of silicon is wired to the card's pins. The
 * Raspberry Pis have three (os/bcm/sdhost.c, os/bcm/emmc.c and its
 * second instance os/bcm2711/emmc2.c); a PolarFire SoC has one
 * (os/mpfs/sd4hc.c). A board whose controller is not a Pi's names it
 * with SDCARD_IO in its board.h, and sdmmc.c drives that.
 *
 * Responses come back in the RAW layout, resp[3] = bits 127:96 down to
 * resp[0] = bits 31:0, whichever controller produced them.
 *
 * Shared by the boards of both architectures, which is why it is here
 * and not in a family directory.
 */

typedef struct SDio SDio;
struct SDio
{
	char	*name;			/* what the console calls it */
	int	(*init)(void);		/* reset and take the pins; -1 if absent */
	void	(*enable)(void);	/* power up, 400kHz identification clock */
	int	(*cmd)(int, u32int, int, u32int*);	/* index, arg, flags, resp[4] */
	void	(*bus)(int, int);	/* width (0 = keep), clock in Hz (0 = keep) */
	void	(*iosetup)(int, int, int);	/* write, block size, block count */
	int	(*io)(int, void*, int);	/* write, buffer, bytes */

	/*
	 * SDIO only, and nil on a controller that has no SDIO device:
	 * the card interrupt, DAT1 pulled low by an SDIO function that
	 * wants attention. wait = 0 asks whether it is pending and
	 * returns; wait = 1 sleeps a tick at a time until it is. Either
	 * way the latched bit is cleared on return.
	 */
	int	(*cardintr)(int);	/* wait; returns the status bits seen */
};

/* SDio.cmd flags: what kind of answer to expect, and whether data follows */
enum
{
	Rnone		= 0,
	R48		= 1,
	R48busy		= 2,		/* R1b: the card holds DAT0 low until done */
	R136		= 3,
	Rmask		= 3,
	Rnocrc		= 1<<2,		/* R3: the OCR reply carries no CRC */
	Dread		= 1<<3,		/* a block follows, card to host */
	Dwrite		= 1<<4,		/* a block follows, host to card */
};
