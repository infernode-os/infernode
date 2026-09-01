/*
 * BCM2837 board hooks.
 *
 * The five functions ../arm64/fns.h declares as this platform's half of
 * the boot sequence, and nothing else. Everything here touches hardware
 * that exists only on this SoC: the VideoCore mailbox, the GPIO block,
 * the fixed-rate system timer and the firmware framebuffer.
 *
 * These were inline in main.c until os/virt arrived, which is the point
 * at which "which board is this" stopped being a rhetorical question.
 * The split is worth keeping at two boards rather than deferring: it is
 * what stops the shared kmain from growing #ifdefs.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

char*
boardname(void)
{
	return "BCM2837 / Raspberry Pi 3B+";
}

/*
 * Ask the firmware what board this is.  Cheap, and it is the first
 * confirmation that the mailbox round trip works at all -- worth having
 * before anything depends on the mailbox for something harder to debug.
 */
void
boardprobe(void)
{
	u32int v[2];

	uartputstr("mbox: ");
	v[0] = 0;
	if(mboxprop(Taggetrev, v, 0, 1) == 0){
		uartputstr("board rev ");
		uartputx(v[0]);
	}else{
		uartputstr("board rev query FAILED");
	}

	v[0] = 0;
	v[1] = 0;
	if(mboxprop(Taggetarmmem, v, 0, 2) == 0){
		uartputstr(", ARM memory ");
		uartputd(v[1] >> 20);
		uartputstr("MB at ");
		uartputx(v[0]);
	}
	uartputstr("\n");
}

/*
 * Read back the pin mux the UART set up.
 *
 * Deliberately non-invasive: it only READS function selects, and only
 * for pins this kernel already configured.  Driving an arbitrary pin as
 * a self-test would be reckless on real hardware, where something may be
 * wired to it -- the header pins are attached to whatever the owner
 * plugged in, and a test that asserts an output could short a driven
 * line.  Reading back proves the mux took, which is the part that is
 * otherwise invisible.
 */
void
boardioprobe(void)
{
	int f14, f15;

	f14 = gpiogetfunc(14);
	f15 = gpiogetfunc(15);

	uartputstr("gpio: pin14 func=");
	uartputd(f14);
	uartputstr(" pin15 func=");
	uartputd(f15);
	if(f14 == Gpioalt0 && f15 == Gpioalt0)
		uartputstr(" (ALT0/UART as set) OK\n");
	else
		uartputstr(" UNEXPECTED (wanted ALT0 on both)\n");
}

/*
 * Cross-check CNTFRQ_EL0 against the BCM system timer.
 *
 * CNTFRQ_EL0 is not derived by the hardware -- it is a value firmware
 * writes, and firmware can write the wrong one. If it lies, every delay
 * and timeout in the kernel is off by that ratio, and the symptom is
 * never "the clock is wrong": it is flaky networking, or a display that
 * tears, or timeouts that fire early under load.
 *
 * The BCM system timer runs at a fixed 1MHz set by the hardware rather
 * than reported by firmware, so timing the same interval with both and
 * comparing catches it immediately. Having a second, independently-rated
 * clock is exactly what makes this check possible -- and is the reason
 * it is a board hook rather than portable code.
 */
void
boardclockcheck(void)
{
	u64int c0, c1, s0, s1, genus, sysus, lo, hi;

	/* time 50ms by both clocks */
	s0 = systimer();
	c0 = clockcount();
	microdelay(50000);
	c1 = clockcount();
	s1 = systimer();

	sysus = s1 - s0;
	genus = ((c1 - c0) * 1000000) / clockfreq();

	uartputstr("clk:  50ms measured: systimer ");
	uartputd(sysus);
	uartputstr("us, generic ");
	uartputd(genus);
	uartputstr("us -- ");

	/* agree within 5%? */
	lo = (sysus * 95) / 100;
	hi = (sysus * 105) / 100;
	if(genus >= lo && genus <= hi)
		uartputstr("clocks AGREE\n");
	else
		uartputstr("clocks DISAGREE (cntfrq is lying)\n");
}

/*
 * Static, because the console keeps a pointer to it.
 *
 * This was a local, which was correct while the framebuffer was only
 * ever painted once from inside this function. A console outlives the
 * probe that finds the screen.
 */
static Fbinfo fb;
static Fbinfo fb2;

enum { Dispwatchival = 2000 };	/* ms between EDID probes */

void
boardfbprobe(void)
{
	int ndisp;
	static uchar edid[128];

	/*
	 * Bring up every display, not just the one the firmware favours.
	 *
	 * With the 7in DSI panel attached the firmware makes it the
	 * default, so a machine with a monitor on HDMI and a panel on the
	 * ribbon put its console on the panel and left the monitor
	 * showing the firmware's rainbow. Most people do not own the
	 * panel, so HDMI is the display that matters most -- and the
	 * answer is not to choose between them but to drive both.
	 *
	 * Display 0 first, so that a firmware which reports a second
	 * display and then refuses to allocate on it still leaves a
	 * working console.
	 */
	ndisp = mboxfbnumdisplays();
	uartputstr("fb:   displays: ");
	uartputd(ndisp);
	uartputstr("\n");

	if(fbinitdisp(0, &fb) < 0){
		uartputstr("fb:   no framebuffer (no display attached?)\n");
		return;
	}

	/*
	 * Make the screen Normal non-cacheable before drawing on it.
	 *
	 * It falls in the range mapped Device-nGnRnE at boot, which is
	 * correct for peripherals and wrong for a framebuffer: no write
	 * combining means every pixel and every byte of a scroll is its
	 * own bus transaction, and a console write was measured at
	 * 1780ms because of it.
	 */
	mmunormalnc(fb.base, fb.size);

	uartputstr("fb:   ");
	uartputd(fb.width);
	uartputstr("x");
	uartputd(fb.height);
	uartputstr("x");
	uartputd(fb.depth);
	uartputstr(" pitch=");
	uartputd(fb.pitch);
	uartputstr(" base=");
	uartputx(fb.base);
	uartputstr(" size=");
	uartputd(fb.size);
	uartputstr("\n");

	/*
	 * Paint something identifiable.  On the 7in panel this is the
	 * first thing that will ever be visible, so make it unambiguous
	 * rather than a single colour that could be a stuck backlight.
	 */
	fbfill(&fb, 0x00101018);
	fbrect(&fb, 0, 0, (int)fb.width, 8, 0x00C03020);
	fbrect(&fb, 20, 40, 120, 80, 0x00FF0000);
	fbrect(&fb, 160, 40, 120, 80, 0x0000FF00);
	fbrect(&fb, 300, 40, 120, 80, 0x000000FF);
	uartputstr("fb:   test pattern drawn\n");

	/*
	 * Take the screen as a console.
	 *
	 * putstrn0 already calls screenputs when there is one; installing
	 * it here is what makes every kernel print appear on the panel as
	 * well as on the wire. consoleprint has to be set too: it
	 * defaults to 0, which gates both this and the echo of typed
	 * characters.
	 */
	if(fbconsinit(&fb) == 0){
		screenputs = fbconsputs;
		consoleprint = 1;
	}

	/*
	 * Tell the pointer how big the screen is.
	 *
	 * A mouse reports movement, never position, so without a bound
	 * the accumulated position walks off the display and does not
	 * come back. The console knows the size; the pointer device has
	 * no way to find out on its own.
	 */
	pointerbounds((int)fb.width, (int)fb.height);

	/*
	 * The second display, if there is one and it will have us.
	 *
	 * Its framebuffer must be a DIFFERENT buffer from the first: the
	 * firmware has historically kept one, and one buffer handed back
	 * twice would mean the second display was never really allocated
	 * and the console would be drawing the same pixels twice through
	 * two aliases. Comparing the bases is what tells those apart.
	 */
	/*
	 * Only bring up a second display if something is ACTUALLY on it.
	 *
	 * The display count is not evidence: the firmware reports two
	 * whether or not a monitor is plugged in, and hands out a
	 * fallback mode -- 720x480 with an empty HDMI socket -- so
	 * trusting the count means allocating a megabyte and a half of
	 * framebuffer and faithfully drawing the console into a buffer
	 * that reaches no glass at all.
	 *
	 * EDID is the display describing itself over the monitor's data
	 * channel, so a display that is not there cannot answer. That is
	 * the question actually being asked. It is asked of the second
	 * display only: display 0 is whatever the firmware chose as
	 * primary and is known to work, and a DSI panel has no EDID to
	 * give -- it is not on a channel that carries one -- so demanding
	 * EDID of it would reject the one display that certainly exists.
	 */
	if(ndisp > 1 && mboxfbdispnum(1) >= 0 && mboxedid(0, edid) < 0){
		uartputstr("fb:   display 1 has no EDID; nothing connected\n");
		ndisp = 1;
	}
	mboxfbdispnum(0);

	if(ndisp > 1 && fbinitdisp(1, &fb2) == 0){
		if(fb2.base == fb.base){
			uartputstr("fb:   display 1 shares display 0's buffer; "
				"not mirroring\n");
		}else{
			uartputstr("fb:   ");
			uartputd(fb2.width);
			uartputstr("x");
			uartputd(fb2.height);
			uartputstr(" on display 1, base ");
			uartputx(fb2.base);
			uartputstr("\n");
			mmunormalnc(fb2.base, fb2.size);
			fbconsadd(&fb2);
		}
	}
	mboxfbdispnum(0);
}

/*
 * Reset the machine.
 *
 * This SoC has no reset line to assert: rebooting means arming the
 * watchdog with a short timeout and letting it expire. Every write to
 * the power-management block needs the password in the top half, and a
 * write without it is ignored SILENTLY -- which is the failure mode to
 * watch for if this ever stops working.
 *
 * It matters for more than tidiness here. The kernel is delivered over
 * the serial line by serialboot, which only runs at reset, so without
 * a way to reset from software every iteration needs a human to pull
 * the power. With it, the loop closes: send a kernel, run it, write
 * "reboot" to #c/sysctl, send the next one.
 */
void
boardreboot(void)
{
	volatile u32int *rstc, *wdog;

	rstc = (u32int*)(uintptr)(PMREGS + Pmrstc);
	wdog = (u32int*)(uintptr)(PMREGS + Pmwdog);

	*wdog = Pmpassword | 16;		/* a few ticks is plenty */
	*rstc = Pmpassword | (*rstc & Pmwrcfgclr) | Pmwrcfgfull;
	coherence();

	for(;;)
		;
}

/*
 * Reset with the firmware's one-shot TRYBOOT flag raised.
 *
 * The VideoCore reads PM_RSTS at boot; with this bit set it clears
 * the bit and loads tryboot.txt instead of config.txt, exactly once.
 * That is the whole A/B kernel mechanism on this platform: config.txt
 * names the known-good kernel, tryboot.txt names the candidate, and a
 * candidate that crashes costs one watchdog reset back to known-good
 * -- no loader work, no card surgery, no serial rescue. The bit is
 * survived by the reset on purpose; everything else about the reset
 * is boardreboot()'s.
 *
 * PM_RSTS also holds partition-select and reset-cause bits the
 * firmware owns, so read-modify-write rather than store: clobbering
 * them has no documented recovery.
 */
void
boardtryboot(void)
{
	volatile u32int *rstc, *rsts, *wdog;

	rstc = (u32int*)(uintptr)(PMREGS + Pmrstc);
	rsts = (u32int*)(uintptr)(PMREGS + Pmrsts);
	wdog = (u32int*)(uintptr)(PMREGS + Pmwdog);

	*rsts = Pmpassword | *rsts | Pmrststryboot;
	*wdog = Pmpassword | 16;
	*rstc = Pmpassword | (*rstc & Pmwrcfgclr) | Pmwrcfgfull;
	coherence();

	for(;;)
		;
}

/*
 * Read sector 0 and say what is on the card.
 *
 * A driver that initialises and is never asked for a block proves
 * nothing: the interesting failures -- a byte-addressed card treated as
 * block-addressed, a clock divider computed from the wrong base -- all
 * produce a controller that comes up perfectly and then reads the wrong
 * data, or none. So read something whose shape is known.
 *
 * The master boot record is the right thing to read for that. It ends
 * in 0x55 0xAA, which is a two-byte check that no amount of reading the
 * wrong sector is likely to pass, and the four partition entries in
 * front of it are what a filesystem will need next anyway.
 */
enum { Emmctestblock = 10000 };

void
boardsdprobe(void)
{
	static uchar sec[512];
	uchar *p;
	int i, type;
	u32int start, len;

	if(emmcinit() < 0)
		return;

	if(emmcread(0, sec) < 0){
		uartputstr("emmc: cannot read sector 0\n");
		return;
	}

	if(sec[510] != 0x55 || sec[511] != 0xAA){
		uartputstr("emmc: sector 0 has no boot signature "
			"(not a partitioned card?)\n");
		return;
	}
	uartputstr("emmc: MBR ok, partitions:\n");

#ifdef EMMCWRITETEST
	/*
	 * Write a block and read it back.
	 *
	 * Behind a build flag, and it stays there. A write test needs
	 * somewhere to write, and on a real board the only card present
	 * is the one holding the firmware and the loader that put this
	 * kernel in memory -- so a test that picks a sector "that looks
	 * free" is a test that eventually destroys the machine it runs
	 * on. The emulator gets a scratch image and the shipped kernel
	 * never contains this code at all.
	 */
	{
		static uchar wbuf[512], rbuf[512];
		int j, bad;

		for(j = 0; j < 512; j++)
			wbuf[j] = (uchar)(j ^ 0x5A);
		if(emmcwrite(Emmctestblock, wbuf) < 0)
			uartputstr("emmc: write failed\n");
		else if(emmcread(Emmctestblock, rbuf) < 0)
			uartputstr("emmc: read back failed\n");
		else{
			bad = 0;
			for(j = 0; j < 512; j++)
				if(rbuf[j] != wbuf[j])
					bad++;
			if(bad)
				uartputstr("emmc: WRITE ROUND TRIP CORRUPT\n");
			else
				uartputstr("emmc: write/read round trip OK\n");
		}
	}
#endif

	for(i = 0; i < 4; i++){
		p = sec + 446 + i*16;
		type = p[4];
		if(type == 0)
			continue;
		start = p[8] | p[9]<<8 | p[10]<<16 | (u32int)p[11]<<24;
		len   = p[12] | p[13]<<8 | p[14]<<16 | (u32int)p[15]<<24;
		uartputstr("emmc:   ");
		uartputd(i);
		uartputstr(": type ");
		uartputx(type);
		uartputstr(" start ");
		uartputd(start);
		uartputstr(" sectors ");
		uartputd(len);
		uartputstr("\n");
	}
}

/*
 * Watch for a display being plugged in.
 *
 * EDID was read once, at boot, so a monitor connected afterwards was
 * invisible until the machine was restarted -- which looks exactly like
 * the monitor not working. The firmware answers EDID whenever it is
 * asked, so there is no reason to only ask once.
 *
 * Only the second display is watched. Display 0 is whatever the
 * firmware chose as primary and is already the console; a DSI panel has
 * no EDID to give in any case.
 *
 * One direction only: a display that appears is brought up, a display
 * that goes away is left alone. Removing a screen from under a console
 * that may be drawing on it needs the console to stop using it first,
 * and that is worth doing properly rather than racing.
 */
void
displaywatch(void *a)
{
	static uchar edid[128];
	int ndisp, have;

	USED(a);

	have = 0;
	ndisp = mboxfbnumdisplays();
	if(ndisp <= 1)
		return;			/* nowhere for one to appear */

	for(;;){
		tsleep(&up->sleep, return0, nil, Dispwatchival);

		/*
		 * Nothing to watch for once a draw client has the screen.
		 * Adding a text console to a framebuffer a window system
		 * is drawing on puts two writers on the same pixels.
		 */
		if(fbconsreleased())
			return;

		/*
		 * Nothing to do if the display is already up -- and this
		 * test comes FIRST, before anything is asked of the
		 * firmware, because fbinitdisp REALLOCATES a
		 * framebuffer. Probing a display the console is already
		 * drawing on is not a harmless look: it hands back a new
		 * buffer at a possibly different pitch while text is
		 * being written into the old one.
		 *
		 * Two conditions, because there are two ways it can
		 * already be up. `have` is this watcher's own doing;
		 * screens > 1 is the boot walk's, for a display that was
		 * plugged in before power-on. Neither is derivable from
		 * the other, and the screen count alone was the bug
		 * above: it also reads zero after the console gives the
		 * screen up.
		 */
		if(have || fbconsscreens() > 1)
			continue;

		if(mboxfbdispnum(1) < 0)
			continue;
		if(mboxedid(0, edid) < 0){
			mboxfbdispnum(0);
			continue;
		}
		mboxfbdispnum(0);

		if(fbinitdisp(1, &fb2) < 0)
			continue;
		if(fb2.base == fb.base)
			continue;	/* one buffer handed back twice */

		uartputstr("fb:   display 1 connected, ");
		uartputd(fb2.width);
		uartputstr("x");
		uartputd(fb2.height);
		uartputstr("\n");

		mmunormalnc(fb2.base, fb2.size);
		if(fbconsadd(&fb2) == 0)
			have = 1;
	}
}

/*
 * The display, for anything that needs the raw framebuffer.
 *
 * Returns display 0 -- whatever the firmware chose as primary. A second
 * display is driven by the console, which mirrors onto it, but the draw
 * device gets one screen: /dev/draw has no notion of two, and choosing
 * which one a window system lives on is a decision for a window system.
 */
Fbinfo*
boardfb(void)
{
	if(fb.base == 0)
		return nil;
	return &fb;
}
