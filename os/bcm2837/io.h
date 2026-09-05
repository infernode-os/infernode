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
	IRQsdhost	= 56,		/* the BCM2835 SDHOST controller */
	IRQmmc		= 62,		/* the Arasan SDHCI controller */
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
	SDHOSTREGS	= PHYSIO+0x202000,	/* BCM2835 SDHOST: the card */
	EMMCREGS	= PHYSIO+0x300000,	/* Arasan SDHCI: for the WiFi chip */

	/*
	 * The watchdog, which is how this SoC reboots: there is no reset
	 * line to pull. Arm it with a short timeout and let it expire.
	 * Every write needs the password in the top half or it is
	 * ignored silently.
	 *
	 * The same block is the boot watchdog (board.c): PM_WDOG is a
	 * 20-bit down-counter at 65536Hz -- 16 seconds is the longest
	 * timeout it can hold, which is why a 90-second boot budget is
	 * kept by re-arming from the clock tick rather than by one write.
	 * PM_RSTC's WRCFG field (bits 5:4) is what makes expiry reset the
	 * chip; writing PM_RSTC's reset value 0x102 back, with the
	 * password, clears that field and disarms it. That is the disarm
	 * every reference driver uses -- Linux bcm2835_wdt.c and FreeBSD
	 * bcm2835_wdog.c both write PM_PASSWORD|0x102 -- and the Broadcom
	 * documentation of the block is not public, so the drivers ARE the
	 * register description.
	 *
	 * PM_RSTS is the firmware's: reset cause and boot-partition bits.
	 * Bit 5 (0x20) is HADWRQ, "the last reset was the watchdog", not
	 * a tryboot request; the tryboot flag is asked for through the
	 * mailbox (Tagsetrebootflags) and the firmware keeps it where it
	 * likes. An earlier version of board.c set 0x20 here and called it
	 * tryboot; see boardtryboot() for how that was found.
	 */
	Pmrstc		= 0x1C,
	Pmrsts		= 0x20,
	Pmwdog		= 0x24,
	Pmpassword	= 0x5A000000,
	Pmwrcfgclr	= 0xFFFFFFCF,
	Pmwrcfgfull	= 0x00000020,	/* WRCFG = full reset on expiry */
	Pmrstcreset	= 0x00000102,	/* PM_RSTC's reset value: watchdog disarmed */
	Pmwdogmask	= 0x000FFFFF,	/* the 20-bit count */
	Pmwdoghz	= 65536,	/* the count's rate */

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
	Tagsettouchbuf	= 0x0004801F,	/* hand the firmware a buffer of ours instead */
	Taggetclockrate	= 0x00030002,	/* a peripheral clock's actual rate */
	Taggetmaxclockrate= 0x00030004,	/* the most the firmware will ever run it at */
	Taggetedidblock	= 0x00030020,	/* the display's own description */

	/*
	 * The kernel command line, as the firmware assembled it from
	 * cmdline.txt plus its own additions (vc_mem.*, the MAC, ...).
	 * QEMU answers it with -append. It is the one channel through
	 * which config.txt -- and so a [tryboot] section or a tryboot.txt
	 * -- can tell a kernel which boot it is.
	 */
	Taggetcmdline	= 0x00050001,

	/*
	 * How Linux on a Pi asks for a tryboot: SET_REBOOT_FLAGS with bit
	 * 0, then NOTIFY_REBOOT, then the ordinary watchdog reset
	 * (drivers/firmware/raspberrypi.c, rpi_firmware_notify_reboot).
	 * The firmware records the flag itself; nothing in PM_RSTS is
	 * ours to set.
	 */
	Tagnotifyreboot	= 0x00030048,
	Tagsetrebootflags = 0x00038064,
	Rebootflagtryboot = 1,

	Clkemmc		= 1,		/* clock id for the SD controller */
	Clkcore		= 4,		/* the VPU core clock; SDHOST divides it */

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

/*
 * SDHOST register offsets.
 *
 * The BCM2835's own SD controller, older and simpler than the Arasan
 * above: a 16-word FIFO at Sddata, a state machine readable through
 * Sdedm, and responses stored RAW -- Sdrsp3 holds bits 127:96 of a
 * 136-bit response, where the Arasan drops the CRC byte and stores bits
 * 127:104 in its RESP3. The two controllers share the card's six GPIO
 * pins and the mux decides which one is wired to them: ALT0 for this
 * one, ALT3 for the Arasan. See sdhost.c for why the card lives here.
 */
enum
{
	Sdcmd		= 0x00,		/* command and its flags */
	Sdarg		= 0x04,
	Sdtout		= 0x08,		/* data timeout, in SD clocks */
	Sdcdiv		= 0x0C,		/* clock divider: sdclk = core/(div+2) */
	Sdrsp0		= 0x10,		/* response bits 31:0 */
	Sdrsp1		= 0x14,		/* 63:32 */
	Sdrsp2		= 0x18,		/* 95:64 */
	Sdrsp3		= 0x1C,		/* 127:96 */
	Sdhsts		= 0x20,		/* status; write 1 to clear */
	Sdvdd		= 0x30,		/* power */
	Sdedm		= 0x34,		/* state machine and FIFO thresholds */
	Sdhcfg		= 0x38,		/* host configuration */
	Sdhbct		= 0x3C,		/* block size */
	Sddata		= 0x40,		/* the FIFO */
	Sdhblc		= 0x50,		/* block count; writing it arms a transfer */

	/* Sdcmd */
	Cmdstart	= 1<<15,	/* set to issue; clear when done */
	Cmdfailed	= 1<<14,	/* set, with Cmdstart clear, on error */
	Cmdbusywait	= 1<<11,	/* R1b: wait for the card to leave busy */
	Cmdnoresp	= 1<<10,
	Cmdlongresp	= 1<<9,		/* 136-bit response */
	Cmdhost2card	= 1<<7,		/* data follows, out */
	Cmdcard2host	= 1<<6,		/* data follows, in */
	Cmdindexmask	= 0x3F,

	/* Sdhsts */
	Hstbusyint	= 1<<10,	/* the R1b busy period ended */
	Hstblkint	= 1<<9,
	Hstsdioint	= 1<<8,
	Hstrewtimeout	= 1<<7,		/* read/erase/write data timeout */
	Hstcmdtimeout	= 1<<6,		/* no response: the usual "no card" */
	Hstcrc16	= 1<<5,
	Hstcrc7		= 1<<4,
	Hstfifoerror	= 1<<3,
	Hstdataflag	= 1<<0,		/* the FIFO has data, or room */
	Hsterrors	= Hstrewtimeout|Hstcmdtimeout|Hstcrc16|Hstcrc7|Hstfifoerror,
	Hstall		= 0x7F8,	/* every W1C bit (3..10); above are reserved -- Linux's SDHSTS_CLEAR_MASK */

	/* Sdhcfg */
	Hcfgbusyinten	= 1<<10,	/* needed even when polling; see sdhost.c */
	Hcfgblkinten	= 1<<8,
	Hcfgsdiointen	= 1<<5,
	Hcfgdatainten	= 1<<4,
	Hcfgslowcard	= 1<<3,
	Hcfgextbus4	= 1<<2,		/* four data lines to the card */
	Hcfgintbuswide	= 1<<1,
	Hcfgcmdrelease	= 1<<0,

	/* Sdedm */
	Edmfsmmask	= 0xF,
	Edmfsmident	= 0,		/* idle, identification clock */
	Edmfsmdata	= 1,		/* idle, data clock */
	Edmfsmread	= 2,
	Edmfsmwrite	= 3,
	Edmfsmreadwait	= 4,		/* parked after a read with no stop command */
	Edmfsmwritestart1= 0xA,		/* parked after a write with no stop command */
	Edmforcedata	= 1<<19,	/* kick a parked state machine back to data idle */
	Edmfifoshift	= 4,		/* words in the FIFO, 5 bits */
	Edmfifomask	= 0x1F,
	Edmwrthreshshift= 9,
	Edmrdthreshshift= 14,
	Edmthreshmask	= 0x1F,

	Sdfifowords	= 16,
	Sdcdivmax	= 0x7FF,
};
