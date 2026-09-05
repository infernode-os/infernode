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
 * The kernel command line, and the boot watchdog it controls.
 *
 * THE PROBLEM. A candidate kernel is one nobody has seen boot on this
 * board. If it panics, exit() resets the machine and the firmware --
 * its tryboot flag now spent -- loads the known-good kernel again; that
 * path has always worked. If it HANGS, nothing happens at all: the
 * classic failure of a JIT that forgot its instruction-cache
 * maintenance is a machine that prints half a boot and stops, and the
 * only way out was the power switch. A watchdog armed before the
 * candidate has done anything, and disarmed only once it has proved it
 * can run a shell, turns that hang into the same reset a panic gets.
 *
 * WHICH BOOTS ARM IT. Only the ones the command line says to: the word
 * "tryboot" marks a candidate boot, and "bootwatchdog" asks for the
 * guard without the candidate semantics; "nowatchdog" wins over both,
 * for a boot that is legitimately slow -- a kernel being stepped under
 * a debugger, say, whose budget would otherwise expire on a
 * breakpoint. "wdogtest" arms and then IGNORES the release, so that the
 * one thing emulation cannot show -- the count reaching zero and the
 * chip resetting -- can be watched on the board with a stopwatch. The
 * default is NOT to arm, for two reasons that were weighed against the
 * obvious alternative of guarding every boot.
 *
 * One is emulation. QEMU's model of this block (hw/misc/
 * bcm2835_powermgt.c) has no countdown: a write to PM_RSTC with the
 * full-reset WRCFG resets the machine on the spot, whatever PM_WDOG
 * holds. A kernel that armed unconditionally could not boot under
 * QEMU at all, and QEMU is where every check in the harness runs.
 * The other is that a known-good kernel which hangs has nowhere to
 * fall back to: a watchdog there produces a machine that resets every
 * ninety seconds and wipes its own console each time, which is a
 * worse thing to find than a hang with the last line still on the
 * screen. The candidate is the case a reset helps, and the operator
 * who wants the reset regardless has a word for it.
 *
 * HOW THE WORD GETS HERE. The firmware assembles the command line
 * from the cmdline file that the config in force names, and a
 * [tryboot] section of config.txt -- or a tryboot.txt -- can name a
 * different one from the known-good boot's. That is the whole channel:
 * the same kernel image can be booted as a candidate or as the
 * incumbent, and it learns which from the firmware rather than from
 * the build. QEMU's -append lands in the same place, which is what
 * lets the harness drive this. The line is published as
 * #B/bootargs so osinit can read it too.
 *
 * Because of that choice, the guard on a candidate rests on two
 * firmware behaviours, neither yet seen on this board: that the
 * SET_REBOOT_FLAGS tag makes the next boot take the [tryboot]
 * section at all, and that the section's cmdline= line is what the
 * firmware then hands GET_COMMAND_LINE. The second is the same
 * conditional-filter machinery that applies the section's kernel=
 * line, so a firmware that boots tryboot.img from the section but
 * serves the other cmdline would be a firmware bug rather than a
 * documented gap; but it is untested, and the failure would be
 * quiet: the candidate boots, prints "wdog: not armed (not a tryboot
 * candidate)", and runs unguarded. That line, on a boot that should
 * have been marked, is the tell -- and "bootwatchdog" in the
 * KNOWN-GOOD cmdline.txt is the way round it, since that file is
 * read on every boot the section does not override.
 *
 * WHEN THE LINE CANNOT BE READ. An unanswered GET_COMMAND_LINE, or a
 * line longer than the buffer (the protocol then copies nothing and
 * reports the length), leaves the kernel unable to say which boot
 * this is. It arms. A boot that reaches the shell releases the
 * watchdog and has lost nothing but a line explaining why; a
 * candidate that hangs unarmed because its line was 1100 bytes
 * would have lost the machine to the power switch, which is the one
 * outcome this whole mechanism exists to remove. "nowatchdog" cannot
 * be honoured on such a boot, because it cannot be seen.
 *
 * THE BUDGET. Ninety seconds, because a boot to the shell takes a few
 * seconds and the only things that legitimately take longer -- USB
 * enumeration behind a slow hub, a DHCP server that is not answering
 * -- are done in threads osinit spawns, so the shell is not behind
 * them. PM_WDOG cannot hold ninety seconds: it is a 20-bit count at
 * 65536Hz, sixteen seconds at most. So the hardware is loaded with
 * fifteen seconds and reloaded for as long as the budget has not run
 * out, and then left to expire.
 *
 * Two things reload it, because the boot path has two halves. Once
 * kmain's final spllo has let interrupts run, the clock tick on core 0
 * reloads it every 64 ticks. Before that -- from the arming write
 * through startmmu, the allocators, the probes, the SMP launch and
 * the card, up to schedinit -- interrupts are masked except for the
 * moments probeclock and probeintr open them, and the tick cannot
 * help; and that half is not short. probeuartin waits a deliberate
 * three seconds for a keypress, launchsmp waits up to five for cores
 * that never answer, emmcinit two for a card to power up plus its
 * command timeouts, and the sum on a bad day is past ten seconds
 * against a count that started at fifteen. So the same reload is
 * polled from microdelay(), which every one of those waits loops
 * around, and from probeuartin's own loop, whenever five seconds have
 * passed since the last reload. The count therefore never falls below
 * ten seconds in code that is waiting on purpose, however long it
 * waits, and reaches zero only when nothing has polled for fifteen
 * seconds -- a hang, or a spin that does not go through microdelay,
 * and the mailbox spin is the one of those worth knowing about. A
 * kernel that hangs with interrupts running is caught at the budget;
 * one that hangs with them off, or before they were ever on, within
 * fifteen seconds. Both end in the same place.
 *
 * The poll takes the watchdog lock, and exclusives fault with the
 * MMU off (see mboxlockon). It is safe because nothing between the
 * arming write and mmuon calls microdelay -- startmmu is table
 * building and register writes -- and because a poll returns before
 * the lock unless five seconds have passed since arming, which the
 * MMU set-up does not take. QEMU cannot show any of this: its PM
 * model resets on the arming write, so no poll ever runs armed
 * there; the reload interval is a board result.
 *
 * WHAT RELEASES IT. osinit writes "booted" to /dev/sysctl once the
 * shell is loaded and about to run; devcons calls booted(), which
 * lands in boardbooted() below. The disarm is PM_RSTC's reset value
 * written back with the password, which clears WRCFG -- the write
 * every reference driver uses (see io.h). One line is printed when
 * the watchdog is armed and one when it is released, so the harness
 * can see both ends of the handshake.
 */
enum
{
	Bootbudgetms	= 90*1000,	/* see above */
	Wdogmaxms	= 15*1000,	/* under the 16 s the 20-bit count can hold */
	Wdogkickevery	= 64,		/* ticks between reloads; well inside 15 s */
	Wdogpollms	= 5*1000,	/* microdelay reloads after this long without one */
};

static char cmdline[Mboxcmdlinemax];
static Lock wdoglock;
static int wdogarmed;		/* being kicked */
static int wdogspent;		/* budget ran out; the reset is coming */
static u64int wdogt0;		/* systimer() when armed */
static u64int wdoglast;		/* systimer() at the last reload */

char*
boardcmdline(void)
{
	return cmdline;
}

/*
 * A whole whitespace-delimited word, so that "tryboot" cannot be
 * found inside "tryboot.img" or "notryboot".
 */
static int
cmdlineword(char *w)
{
	char *p, *q;
	int n;

	n = strlen(w);
	for(p = cmdline; *p != 0; p = q){
		while(*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
			p++;
		for(q = p; *q != 0 && *q != ' ' && *q != '\t' && *q != '\r' && *q != '\n'; q++)
			;
		if(q - p == n && memcmp(p, w, n) == 0)
			return 1;
	}
	return 0;
}

int
boardcandidate(void)
{
	return cmdlineword("tryboot");
}

/*
 * Load the count, then make its expiry a full reset. In that order:
 * with WRCFG already set, a stale count could expire between the two
 * writes.
 */
static void
pmwdogset(int ms)
{
	volatile u32int *rstc, *wdog;
	u32int t;

	t = ((u64int)ms * Pmwdoghz) / 1000;
	if(t > Pmwdogmask)
		t = Pmwdogmask;
	if(t == 0)
		t = 1;
	rstc = (u32int*)(uintptr)(PMREGS + Pmrstc);
	wdog = (u32int*)(uintptr)(PMREGS + Pmwdog);
	*wdog = Pmpassword | t;
	*rstc = Pmpassword | (*rstc & Pmwrcfgclr) | Pmwrcfgfull;
	coherence();
	wdoglast = systimer();
}

static void
pmwdogoff(void)
{
	volatile u32int *rstc;

	rstc = (u32int*)(uintptr)(PMREGS + Pmrstc);
	*rstc = Pmpassword | Pmrstcreset;
	coherence();
}

/*
 * The block's three registers as the firmware left them. PM_RSTS is
 * the interesting one on the board: it holds the reset cause, and
 * after a tryboot it is where the firmware's own bookkeeping would
 * show if it used the register. QEMU reports its reset values,
 * 0x102/0x1000/0.
 */
static void
pmdump(void)
{
	uartputstr("pm:   rsts ");
	uartputx(*(volatile u32int*)(uintptr)(PMREGS + Pmrsts));
	uartputstr(" rstc ");
	uartputx(*(volatile u32int*)(uintptr)(PMREGS + Pmrstc));
	uartputstr(" wdog ");
	uartputx(*(volatile u32int*)(uintptr)(PMREGS + Pmwdog));
	uartputstr("\n");
}

/*
 * Called from kmain right after the mailbox has been proved to work
 * and before anything slow. uartputstr throughout: this runs before
 * print() has a queue, and the "armed" line must be out before the
 * arming write, because under QEMU that write IS the reset.
 */
void
boardbootwatchdog(void)
{
	int n, unread;

	n = mboxcmdline(cmdline, sizeof cmdline);
	unread = 0;
	uartputstr("boot: command line: ");
	if(n < 0){
		uartputstr("(UNREAD: the firmware did not answer GET_COMMAND_LINE)");
		unread = 1;
	}else if(n > Mboxcmdlinemax){
		/*
		 * The protocol copied nothing; see mboxcmdline. Say the
		 * length, so that the fix -- a bigger buffer, or a
		 * shorter cmdline.txt -- is obvious from the line.
		 */
		uartputstr("(UNREAD: the firmware reports ");
		uartputd(n);
		uartputstr(" bytes, more than the ");
		uartputd(Mboxcmdlinemax);
		uartputstr("-byte buffer)");
		unread = 1;
	}else if(cmdline[0] == 0)
		uartputstr("(empty)");
	else
		uartputstr(cmdline);
	uartputstr("\n");
	pmdump();

	if(unread){
		/*
		 * Which boot this is cannot be known, so guard it as if
		 * it were the candidate; see "WHEN THE LINE CANNOT BE
		 * READ" above.
		 */
		uartputstr("wdog: armed, ");
		uartputd(Bootbudgetms / 1000);
		uartputstr(" s boot budget; the command line could not be read, "
			"so this boot is guarded as a candidate would be\n");
	}else{
		if(cmdlineword("nowatchdog")){
			uartputstr("wdog: not armed (nowatchdog on the command line)\n");
			return;
		}
		if(!boardcandidate() && !cmdlineword("bootwatchdog") && !cmdlineword("wdogtest")){
			uartputstr("wdog: not armed (not a tryboot candidate)\n");
			return;
		}

		uartputstr("wdog: armed, ");
		uartputd(Bootbudgetms / 1000);
		uartputstr(" s boot budget; a hang resets");
		if(boardcandidate())
			uartputstr(" to config.txt's kernel");
		uartputstr("\n");
	}

	wdogt0 = systimer();
	wdogarmed = 1;
	coherence();
	pmwdogset(Wdogmaxms);
}

/*
 * Reload the count from what is left of the budget, or stop when the
 * budget is spent. canlock rather than lock, for both callers: the
 * tick is interrupt context, the poll runs inside arbitrary drivers'
 * delays, and if boardbooted() holds the lock the reload can simply
 * wait for the next tick or the next delay.
 */
static void
wdogkick(void)
{
	u64int ms;

	if(!canlock(&wdoglock))
		return;
	if(wdogarmed){
		ms = (systimer() - wdogt0) / 1000;
		if(ms >= Bootbudgetms){
			/*
			 * Stop kicking. The last reload was for exactly the
			 * time that was left, so the reset lands at the budget,
			 * not fifteen seconds after it.
			 */
			wdogarmed = 0;
			wdogspent = 1;
			uartputstr("wdog: boot budget spent; the reset is coming\n");
		}else{
			ms = Bootbudgetms - ms;
			pmwdogset(ms < Wdogmaxms ? (int)ms : Wdogmaxms);
		}
	}
	unlock(&wdoglock);
}

/* from clockintr on core 0, every tick */
void
boardwatchdogtick(void)
{
	static int n;

	if(!wdogarmed)
		return;
	if(++n < Wdogkickevery)
		return;
	n = 0;
	wdogkick();
}

/*
 * From microdelay(), and from the boot path's own busy-waits: the
 * reload for the stretch of kmain that runs with interrupts masked.
 * The first test is the whole cost on a boot that is not armed. The
 * second keeps a tight loop of short delays from reloading the count
 * on every pass; it also keeps the lock from being touched before the
 * MMU is on, as the comment on the budget explains.
 */
void
boardwatchdogpoll(void)
{
	if(!wdogarmed)
		return;
	if(systimer() - wdoglast < (u64int)Wdogpollms * 1000)
		return;
	wdogkick();
}

/*
 * "booted" on /dev/sysctl: the machine has a shell, so the boot is no
 * longer the thing the watchdog is guarding. Prints in every case,
 * because the release line is the harness's evidence that the write
 * reached this far -- including on a boot that never armed.
 */
void
boardbooted(void)
{
	int s, was;
	u64int ms;

	if(cmdlineword("wdogtest") && wdogarmed){
		print("wdog: NOT released (wdogtest): the reset should come at %d s\n",
			Bootbudgetms / 1000);
		return;
	}

	ms = 0;
	s = splhi();
	lock(&wdoglock);
	was = wdogarmed;
	if(was){
		wdogarmed = 0;
		pmwdogoff();
		ms = (systimer() - wdogt0) / 1000;
	}
	unlock(&wdoglock);
	splx(s);

	if(was)
		print("wdog: released after %llud ms; boot complete\n", ms);
	else if(wdogspent)
		print("wdog: boot complete AFTER the budget; the reset is already coming\n");
	else
		print("wdog: boot complete; no watchdog was armed\n");
}

/*
 * Before a deliberate reset: stop the tick from reloading PM_WDOG
 * under it. The flag alone is not enough -- a kick on core 0 that has
 * already passed its check would reload fifteen seconds over the
 * sixteen ticks below -- so wait out more than one tick as well. No
 * lock: this is called from exit(), where locks may be what broke.
 */
static void
wdogquiet(void)
{
	wdogarmed = 0;
	coherence();
	microdelay(2000);
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

	wdogquiet();

	rstc = (u32int*)(uintptr)(PMREGS + Pmrstc);
	wdog = (u32int*)(uintptr)(PMREGS + Pmwdog);

	*wdog = Pmpassword | 16;		/* a few ticks is plenty */
	*rstc = Pmpassword | (*rstc & Pmwrcfgclr) | Pmwrcfgfull;
	coherence();

	for(;;)
		;
}

/*
 * Reset with the firmware's one-shot tryboot flag raised, so that the
 * next boot -- and only the next -- takes its configuration from the
 * [tryboot] section of config.txt (or tryboot.txt). config.txt names
 * the known-good kernel, the tryboot configuration names the candidate
 * and marks its command line, and a candidate that crashes or hangs
 * costs one reset back to known-good: no loader work, no card surgery,
 * no serial rescue.
 *
 * The flag is asked for through the mailbox, which is how Linux does
 * it (SET_REBOOT_FLAGS then NOTIFY_REBOOT; see io.h). An earlier
 * version of this function set bit 5 of PM_RSTS instead and called it
 * the tryboot bit, with a comment saying the VideoCore reads it. That
 * was never tested against the firmware, and reading the downstream
 * Linux tree while writing the boot watchdog found that bit 5 is
 * HADWRQ -- a reset-cause bit the firmware sets -- and that Linux
 * never touches PM_RSTS for tryboot at all. Whether the firmware
 * honours the tag from THIS kernel is still the one thing here that
 * only the board can say: the line below records its answer.
 */
void
boardtryboot(void)
{
	if(mboxreboot(1) < 0)
		uartputstr("tryboot: firmware did NOT acknowledge the reboot flags; resetting anyway\n");
	else
		uartputstr("tryboot: firmware acknowledged reboot flags 0x1 (tryboot)\n");
	boardreboot();
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
enum { Sdtestblock = 10000 };

/*
 * Read back the pin mux the card driver set, the way boardioprobe does
 * for the UART and for the same reason: a mux that did not take is
 * otherwise invisible, and on this board it is the mux, not the
 * driver, that decides which controller the card is wired to. With
 * the card on SDHOST all six pins must read ALT0; on the Arasan they
 * read whatever the firmware left, which is ALT3 on the board and 0
 * under QEMU, and neither is asserted on.
 */
static void
boardsdmuxprobe(void)
{
	int pin, f, alt0;

	alt0 = 1;
	uartputstr("gpio:");
	for(pin = 48; pin <= 53; pin++){
		f = gpiogetfunc(pin);
		uartputstr(" pin");
		uartputd(pin);
		uartputstr(" func=");
		uartputd(f);
		if(f != Gpioalt0)
			alt0 = 0;
	}
	if(strcmp(sdcontroller(), "sdhost") == 0)
		uartputstr(alt0? " (ALT0/SDHOST as set) OK\n"
			: " UNEXPECTED (wanted ALT0 on all six)\n");
	else
		uartputstr(" (as the firmware left them, for the Arasan)\n");
}

void
boardsdprobe(void)
{
	static uchar sec[512];
	uchar *p;
	int i, type;
	u32int start, len;

	i = emmcinit();
	boardsdmuxprobe();
	if(i < 0)
		return;

	if(emmcread(0, sec) < 0){
		uartputstr("sd: cannot read sector 0\n");
		return;
	}

	if(sec[510] != 0x55 || sec[511] != 0xAA){
		uartputstr("sd: sector 0 has no boot signature "
			"(not a partitioned card?)\n");
		return;
	}
	uartputstr("sd: MBR ok, partitions:\n");

#ifdef SDWRITETEST
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
		if(emmcwrite(Sdtestblock, wbuf) < 0)
			uartputstr("sd: write failed\n");
		else if(emmcread(Sdtestblock, rbuf) < 0)
			uartputstr("sd: read back failed\n");
		else{
			bad = 0;
			for(j = 0; j < 512; j++)
				if(rbuf[j] != wbuf[j])
					bad++;
			if(bad)
				uartputstr("sd: WRITE ROUND TRIP CORRUPT\n");
			else
				uartputstr("sd: write/read round trip OK\n");
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
		uartputstr("sd:   ");
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
