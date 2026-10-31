/*
 * The Wi-Fi radio's connection to the SoC: SDIO2, on the SoC's own
 * GPIOs 30-35, and its power enable, WL_ON, on GPIO 28. Neither is
 * RP1's. A BCM43455, the Pi 4's chip: ../bcm/ether4330.c is the driver,
 * and emmcio below is the controller it talks through.
 *
 * The pin mux is Linux's pinctrl-bcm2712.c for the C0 and C1 steppings:
 * four bits a pin, 0 is GPIO. D0 moved the registers (the 2GB boards);
 * that stepping is not handled.
 */
#define EMMCIO		emmcio
#define EMMCNAME	"sdio2"
#define EMMCBASE	0x1001100000ULL
#define EMMCCLK		0
#define EMMCBASEHZ	200000000
#define EMMCBUSPOWER

#include "../bcm/emmc.c"

#define PINMUX(o)	(*(volatile u32int*)(uintptr)(0x107D504100ULL + (o)))
#define SDIOCFG(o)	(*(volatile u32int*)(uintptr)(EMMCBASE + 0x400 + (o)))
#define GIO(o)		(*(volatile u32int*)(uintptr)(0x107D508500ULL + (o)))

enum
{
	Giodata	= 0x04,
	Gioiodir= 0x08,		/* 1 is input */

	Wlon	= 28,
};

static void
muxset(int reg, int shift, int f)
{
	PINMUX(4*reg) = (PINMUX(4*reg) & ~((u32int)0xF<<shift)) | (u32int)f<<shift;
}

static void
pullset(int pin, int pull)
{
	int bit;

	bit = 2*(pin - 30 + 7);		/* pads: register 9, field 7 is GPIO 30 */
	PINMUX(4*9) = (PINMUX(4*9) & ~((u32int)3<<bit)) | (u32int)(pull ? 2 : 0)<<bit;
}

void
radiopins(void)
{
	muxset(3, 16, 0);		/* 28: a GPIO */
	muxset(3, 24, 4);		/* 30, 31, 32, 34: sd2 is function 4 */
	muxset(3, 28, 4);
	muxset(4, 0, 4);
	muxset(4, 4, 3);		/* 33, 35: function 3 */
	muxset(4, 8, 4);
	muxset(4, 12, 3);
	pullset(30, 0);
	pullset(31, 1);
	pullset(32, 1);
	pullset(33, 1);
	pullset(34, 1);
	pullset(35, 1);
	GIO(Gioiodir) &= ~(1<<Wlon);

	/*
	 * The radio is soldered on, with no card-detect line: tell the
	 * controller it is present (Linux's sdhci-brcmstb.c), or it will
	 * not talk.
	 */
	SDIOCFG(0) = (SDIOCFG(0) & ~(u32int)(1<<30)) | (u32int)1<<31;
	coherence();
}

/*
 * Bluetooth: the same chip's other half, on the SoC's UART on GPIOs
 * 24-27 (uartbt.c); BT_ON is GPIO 29, a cycle of which resets it.
 */
void
btpins(void)
{
	static int done;

	if(done)
		return;
	done = 1;
	muxset(3, 0, 3);		/* 24, RTS: uart0 is function 3 */
	muxset(3, 4, 4);		/* 25, 26, 27: function 4 */
	muxset(3, 8, 4);
	muxset(3, 12, 4);
	muxset(3, 20, 0);		/* 29: a GPIO */
	/* pads: register 9, fields 1-4 are GPIOs 24-27 */
	PINMUX(4*9) = (PINMUX(4*9) & ~((u32int)0xFF<<2)) | (u32int)(2<<4 | 2<<8)<<0;
	GIO(Gioiodir) &= ~(u32int)(1<<Wlon+1);
	GIO(Giodata) &= ~(u32int)(1<<Wlon+1);
	microdelay(10000);
	GIO(Giodata) |= (u32int)(1<<Wlon+1);
	microdelay(100000);
}

void
radiopower(int on)
{
	if(on)
		GIO(Giodata) |= 1<<Wlon;
	else
		GIO(Giodata) &= ~(1<<Wlon);
}
