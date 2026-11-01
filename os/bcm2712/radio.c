/*
 * The Wi-Fi radio's connection to the SoC: SDIO2, on the SoC's own
 * GPIOs 30-35, and its power enable, WL_ON, on GPIO 28. Neither is
 * RP1's. A BCM43455, the Pi 4's chip: ../bcm/ether4330.c is the driver,
 * and emmcio below is the controller it talks through.
 *
 * The pin mux is from Linux's pinctrl-bcm2712.c: four bits a pin, 0 is
 * GPIO. The D0 stepping has the registers in other places and other
 * functions in them, and nothing else that matters here, GIO lines and
 * all being where they were. Which it is, is in the device tree: the
 * firmware passes D0's its own pinctrl. D0 HAS NOT RUN: there is none
 * on the bench.
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

typedef struct Pinreg Pinreg;
struct Pinreg
{
	uchar	mr;		/* mux register, and field of four bits */
	uchar	mb;
	uchar	pr;		/* pad register, and field of two */
	uchar	pb;
};

/* GPIOs 24-35 */
static Pinreg c0pins[] = {
	{ 3, 0, 9, 1 },	/* 24 */
	{ 3, 1, 9, 2 },	/* 25 */
	{ 3, 2, 9, 3 },	/* 26 */
	{ 3, 3, 9, 4 },	/* 27 */
	{ 3, 4, 9, 5 },	/* 28 */
	{ 3, 5, 9, 6 },	/* 29 */
	{ 3, 6, 9, 7 },	/* 30 */
	{ 3, 7, 9, 8 },	/* 31 */
	{ 4, 0, 9, 9 },	/* 32 */
	{ 4, 1, 9, 10 },	/* 33 */
	{ 4, 2, 9, 11 },	/* 34 */
	{ 4, 3, 9, 12 },	/* 35 */
};

static Pinreg d0pins[] = {
	{ 2, 0, 5, 6 },	/* 24 */
	{ 2, 1, 5, 7 },	/* 25 */
	{ 2, 2, 5, 8 },	/* 26 */
	{ 2, 3, 5, 9 },	/* 27 */
	{ 2, 4, 5, 10 },	/* 28 */
	{ 2, 5, 5, 11 },	/* 29 */
	{ 2, 6, 5, 12 },	/* 30 */
	{ 2, 7, 5, 13 },	/* 31 */
	{ 3, 0, 5, 14 },	/* 32 */
	{ 3, 1, 6, 0 },	/* 33 */
	{ 3, 2, 6, 1 },	/* 34 */
	{ 3, 3, 6, 2 },	/* 35 */
};

/* uart0 on 24-27, sd2 on 30-35 */
static uchar c0uart[] = { 3, 4, 4, 4 };
static uchar d0uart[] = { 4, 4, 4, 4 };
static uchar c0sd[] = { 4, 4, 4, 3, 4, 3 };
static uchar d0sd[] = { 1, 1, 1, 1, 1, 1 };

static Pinreg *pins;
static uchar *uartf, *sdf;

static void
pinstepping(void)
{
	extern uintptr dtbptr;
	static char want[] = "brcm,bcm2712d0-pinctrl";
	uchar *h;
	u32int n, i;
	int d0;

	if(pins != nil)
		return;
	d0 = 0;
	h = (uchar*)dtbptr;
	if(h != nil && h[0] == 0xD0 && h[1] == 0x0D && h[2] == 0xFE && h[3] == 0xED){
		n = h[4]<<24 | h[5]<<16 | h[6]<<8 | h[7];
		for(i = 0; i + sizeof want <= n && !d0; i++)
			d0 = memcmp(h+i, want, sizeof want) == 0;
	}
	print("radio: BCM2712 %s pin mux\n", d0 ? "D0" : "C0/C1");
	pins = d0 ? d0pins : c0pins;
	uartf = d0 ? d0uart : c0uart;
	sdf = d0 ? d0sd : c0sd;
}

static void
muxset(int pin, int f)
{
	Pinreg *p;
	int shift;

	p = &pins[pin - 24];
	shift = 4*p->mb;
	PINMUX(4*p->mr) = (PINMUX(4*p->mr) & ~((u32int)0xF<<shift)) | (u32int)f<<shift;
}

static void
pullset(int pin, int pull)
{
	Pinreg *p;
	int shift;

	p = &pins[pin - 24];
	shift = 2*p->pb;
	PINMUX(4*p->pr) = (PINMUX(4*p->pr) & ~((u32int)3<<shift)) | (u32int)(pull ? 2 : 0)<<shift;
}

void
radiopins(void)
{
	int i;

	pinstepping();
	muxset(28, 0);			/* a GPIO */
	for(i = 30; i <= 35; i++)
		muxset(i, sdf[i-30]);
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
	int i;

	if(done)
		return;
	done = 1;
	pinstepping();
	for(i = 24; i <= 27; i++)
		muxset(i, uartf[i-24]);
	muxset(29, 0);			/* a GPIO */
	pullset(24, 0);
	pullset(25, 1);
	pullset(26, 0);
	pullset(27, 1);
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
