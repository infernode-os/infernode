implement Mouseusb;

#
# A USB pointer -- mouse, touchscreen or tablet -- as a program.
#
# Same reasoning as kbdusb and etherusb: the kernel provides the
# mechanism -- raw endpoints through #u and a pointer through #m -- and
# what to say to a particular class of device is policy, which belongs
# outside it.
#
# The device says what its reports mean, in its HID report descriptor,
# and this reads it (issue #927). That is how one driver serves a mouse
# (relative X and Y: "d dx dy b" to /dev/pointer), a touchscreen or a
# tablet (absolute X and Y: "a x y b", a fraction of the screen the
# kernel scales), and a touchscreen that calls itself a mouse, as a
# Waveshare 10.1" panel's does -- its interface says boot mouse, its
# reports are absolute positions. A digitizer's tip switch is button 1.
#
# A touch screen's finger means what the Pi's panel's does (touch.b),
# by touchgest(2): held still it is button 3, the context menus; two
# dragged are the wheel; and each finger goes to /dev/fingers as well,
# for the keyboard on the screen. A touch screen is a digitizer that
# says it is one, or reports fingers -- a multi-touch panel, asked by
# its Device Mode feature to report every finger, as Windows and Linux
# ask -- or an absolute pointer with one button and no wheel, as a
# touchscreen that calls itself a mouse is. A tablet with a mouse's
# buttons (QEMU's usb-tablet) is a pointer.
#
# The BOOT protocol -- three fixed bytes, buttons then dx then dy, and
# a fourth for the wheel when the endpoint has one -- is the fallback,
# for a device whose descriptor cannot be read or describes no X and Y.
#
# What is particular to one device -- axes swapped or mirrored, or a
# device to leave alone -- is data on the card, /n/dos/usbquirks, one
# line per device: "vid:pid word ...", words swapxy, invertx, inverty,
# boot, ignore, and touch or notouch (a touch screen or not, whatever
# its descriptor suggests). Never a change to this file.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "touchgest.m";
	touchgest: Touchgest;
	Gest: import touchgest;

Mouseusb: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Rh2d:		con 16r00;
Rd2h:		con 16r80;
Rclass:		con 16r20;
Riface:		con 1;

Rgetdesc:	con 6;
Rsetproto:	con 11;		# HID: SET_PROTOCOL
Rsetidle:	con 10;		# HID: SET_IDLE
Rgetreport:	con 1;		# HID: GET_REPORT
Rsetreport:	con 9;		# HID: SET_REPORT
Rfeature:	con 3;		# a feature report, in GET_REPORT's and SET_REPORT's value

Dconf:		con 2;

Bootproto:	con 0;		# SET_PROTOCOL: 0 is boot, 1 is report
Reportproto:	con 1;
Dreport:	con 16r22;	# GET_DESCRIPTOR: the HID report descriptor
Quirkfile:	con "/n/dos/usbquirks";

# usage pages and usages, from the HID usage tables
Pgdesktop:	con 16r01;
Pgbutton:	con 16r09;
Pgdigitizer:	con 16r0D;
Ux:		con 16r30;
Uy:		con 16r31;
Uwheel:		con 16r38;
Utip:		con 16r42;	# digitizer: tip switch, the finger is down
Utouchscreen:	con 16r04;	# digitizer: a touch screen (an application collection)
Ufinger:	con 16r22;	# digitizer: one finger's fields (a logical collection)
Ucid:		con 16r51;	# digitizer: contact identifier, the finger's while it is down
Umode:		con 16r52;	# digitizer: device mode (feature): 0 mouse, 2 multi-touch
Ucount:		con 16r54;	# digitizer: contact count, the fingers in this frame
Multiinput:	con 2;		# the device mode that reports every finger

# One input field: where it is in the report, how wide, what it means.
Field: adt {
	page:	int;
	usage:	int;
	off:	int;		# bit offset, after the report id byte if there is one
	size:	int;		# bits
	lmin:	int;
	lmax:	int;
	rel:	int;		# relative (a mouse's dx) rather than absolute
	finger:	int;		# which Finger collection it is in, from 0; -1 none
	app:	int;		# its application collection's page<<16 | usage
};

# One finger's fields in a multi-touch report.
Slot: adt {
	tip:	ref Field;
	cid:	ref Field;
	x, y:	ref Field;
};

# A multi-touch report: a slot for each finger it can carry, and how many
# fingers this frame has, which may be more than the slots (the rest
# come in the reports after, whose count is 0: "hybrid" mode).
Multi: adt {
	id:	int;
	slots:	array of ref Slot;
	count:	ref Field;
};

# The report this driver decodes: the first one carrying both X and Y.
Report: adt {
	id:	int;		# report id, or 0 if the device has none
	hasids:	int;		# the device numbers its reports: byte 0 is the id
	x, y:	ref Field;
	wheel:	ref Field;
	tip:	ref Field;
	btn:	array of ref Field;	# HID buttons 1, 2, 3
	touch:	int;		# its application collection is a touch screen
	mt:	ref Multi;	# the device's multi-touch report, if it has one
	mode:	ref Field;	# the device mode feature, to ask for multi-touch
	modeid:	int;		# its report id
	modelen:	int;	# that feature report's length in bytes, with its id
};

swapxy := 0;
invertx := 0;
inverty := 0;

Reportlen:	con 3;		# buttons, dx, dy

# A touch screen's gesture distances (touchgest(2)), as fractions of the
# screen: the Pi panel's 16 and 40 pixels of its 800 by 480, so a
# finger moves as much of any screen to make them.
Slopfrac:	con 16*65536/800;
Stepfrac:	con 40*65536/480;
Maxerr:		con 100;	# failed reads before deciding it is gone

#
# Buttons, and they are NOT in the same order on both sides.
#
# HID numbers them left, right, middle. Inferno -- like Plan 9 before
# it -- numbers them 1, 2, 3 from the left, so the middle button is bit
# 1 and the right is bit 2. Passing the HID byte through unchanged
# swaps the middle and right buttons, which is the sort of fault that
# is obvious the moment a menu appears under the wrong finger and
# invisible until then.
#
Hidleft:	con 16r01;
Hidright:	con 16r02;
Hidmiddle:	con 16r04;

Mleft:		con 1;
Mmiddle:	con 2;
Mright:		con 4;

dev: string;
ctlfd: ref Sys->FD;	# the device's ctl file
ep0: ref Sys->FD;	# its control endpoint's data file, held open

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	args = tl args;
	if(args != nil && hd args == "-t"){
		selftest();
		return;
	}
	if(args == nil){
		sys->print("mouseusb: no device given\n");
		return;
	}
	dev = hd args;

	ctlfd = sys->open("/usb/usb/" + dev + "/ctl", Sys->ORDWR);
	if(ctlfd == nil){
		sys->print("mouseusb: cannot open %s ctl: %r\n", dev);
		return;
	}

	#
	# Held open, not reopened per request. devusb stashes a control
	# reply against the endpoint and refuses to answer twice, so a
	# fresh fd for every request leaves replies behind for the next
	# one to trip over.
	#
	#
	# The enumerator that found this device may still be letting go of
	# its control endpoint, which is exclusive-open; its release is not
	# instantaneous. Ask a few times before calling it in use.
	#
	ep0 = sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
	for(retry := 0; ep0 == nil && retry < 40 && isinuse(); retry++){
		sys->sleep(50);
		ep0 = sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
	}
	if(ep0 == nil){
		sys->print("mouseusb: cannot open %s data: %r\n", dev);
		return;
	}

	#
	# The endpoint comes from the bus walk when it is given.
	#
	# It has just read this device's configuration descriptor to
	# decide which driver to start, so it already knows the endpoint,
	# its packet size and its interval. Reading the descriptor a
	# second time here asked the same fragile low-speed control pipe
	# for the same three numbers -- and that read happens later, once
	# other drivers are running and the bus is busy, which is exactly
	# when it comes back as 0x55 and the device ends up with no
	# driver.
	#
	# intrendpoint() is kept for a device started by hand from a
	# shell, where there is no walk to be told by.
	#
	epnum := -1;
	maxpkt := 0;
	ival := 0;
	args = tl args;
	if(len args >= 3){
		epnum = int hd args;
		maxpkt = int hd tl args;
		ival = int hd tl tl args;
	} else
		(epnum, maxpkt, ival) = intrendpoint();
	if(epnum < 0){
		sys->print("mouseusb: %s has no interrupt endpoint\n", dev);
		return;
	}

	# the HID interface and the device's vid:pid, when the walk gives them
	iface := 0;
	vidpid := "";
	proto := 2;	# what the interface declared: 2 boot mouse, 0 none
	args = tl tl tl args;
	if(args != nil){
		iface = int hd args;
		if(tl args != nil){
			vidpid = hd tl args;
			if(tl tl args != nil)
				proto = int hd tl tl args;
		}
	}
	forceboot := 0;
	touchq := -1;	# the card's word on gestures: 1 touch, 0 notouch
	for(q := quirks(vidpid); q != nil; q = tl q)
		case hd q {
		"ignore" =>
			sys->print("mouseusb: %s (%s) ignored by %s\n", dev, vidpid, Quirkfile);
			return;
		"boot" =>	forceboot = 1;
		"swapxy" =>	swapxy = 1;
		"invertx" =>	invertx = 1;
		"inverty" =>	inverty = 1;
		"touch" =>	touchq = 1;
		"notouch" =>	touchq = 0;
		"report" =>	;	# a keyboard's word; a combined receiver's line carries both
		* =>	sys->print("mouseusb: %s: unknown word %s for %s\n", Quirkfile, hd q, vidpid);
		}

	#
	# What the reports mean, from the device itself. A mouse's
	# descriptor says relative X and Y; a touchscreen's says absolute,
	# whatever its interface claims to be. With no usable descriptor,
	# the boot protocol, whose three bytes mean the same on every mouse.
	#
	report: ref Report;
	if(!forceboot)
		report = readreport(iface);
	#
	# The boot protocol is a mouse's alone. An interface that declared
	# none and describes no X and Y -- a gamepad, a media-key pad -- is
	# not a pointer, and is left to whatever comes for it later.
	#
	if(report == nil && proto != 2){
		sys->print("mouseusb: %s (%s) is not a pointer: no X and Y, and no boot mouse\n", dev, vidpid);
		return;
	}
	if(report != nil){
		if(ctlout(Rh2d|Rclass|Riface, Rsetproto, Reportproto, iface) < 0)
			sys->print("mouseusb: SET_PROTOCOL(report) failed: %r\n");
		if(report.mt != nil && report.mode != nil)
			setmode(report, iface);
	} else if(ctlout(Rh2d|Rclass|Riface, Rsetproto, Bootproto, iface) < 0)
		sys->print("mouseusb: SET_PROTOCOL(boot) failed: %r\n");

	#
	# Idle 0: report only when something changes. Without it a mouse
	# repeats its current state for ever and the pointer is woken
	# constantly to be told it has not moved.
	#
	if(ctlout(Rh2d|Rclass|Riface, Rsetidle, 0, iface) < 0)
		sys->print("mouseusb: SET_IDLE failed: %r\n");

	fd := openintr(epnum, maxpkt, ival);
	if(fd == nil)
		return;

	ptr := sys->open("/dev/pointer", Sys->OWRITE);
	if(ptr == nil){
		sys->print("mouseusb: cannot open /dev/pointer: %r\n");
		return;
	}

	if(report == nil){
		sys->print("mouseusb: %s ready on endpoint %d maxpkt %d ival %d (boot protocol)\n",
			dev, epnum, maxpkt, ival);
		poll(fd, ptr, ival, maxpkt);
		return;
	}
	kind := "relative";
	if(!report.x.rel)
		kind = sys->sprint("absolute %d..%d x %d..%d", report.x.lmin, report.x.lmax, report.y.lmin, report.y.lmax);
	gest := istouch(report);
	if(touchq >= 0 && !report.x.rel)
		gest = touchq;
	g: ref Gest;
	if(gest){
		touchgest = load Touchgest Touchgest->PATH;
		if(touchgest == nil)
			sys->print("mouseusb: %s: cannot load %s: %r; no touch gestures\n", dev, Touchgest->PATH);
		else
			g = Gest.new("a", Slopfrac, Stepfrac);
	}
	sys->print("mouseusb: %s ready on endpoint %d maxpkt %d ival %d (report %d, %s%s%s%s)\n",
		dev, epnum, maxpkt, ival, report.id, kind, tipsay(report), mtsay(report), gestsay(g));
	pollreport(fd, ptr, ival, maxpkt, report, g);
}

#
# Whether an absolute pointer is a touch screen, whose finger is to mean
# what the Pi's panel's does (touchgest(2)): a digitizer that says it is
# one, or reports fingers; or a "mouse" with absolute X and Y and only
# the one button, as a touchscreen that calls itself a mouse is (a
# Waveshare panel). Not a tablet with a mouse's buttons and wheel (QEMU's
# usb-tablet), whose button 1 held still is a button held. The card's
# quirks file says otherwise for a device with "touch" or "notouch".
#
istouch(r: ref Report): int
{
	if(r.x.rel)
		return 0;
	if(r.mt != nil || r.touch)
		return 1;
	return r.btn[1] == nil && r.btn[2] == nil && r.wheel == nil;
}

mtsay(r: ref Report): string
{
	if(r.mt == nil)
		return "";
	s := sys->sprint(", %d fingers in report %d", len r.mt.slots, r.mt.id);
	if(r.mode != nil)
		s += ", multi-touch mode asked for";
	return s;
}

gestsay(g: ref Gest): string
{
	if(g == nil)
		return "";
	return ", touch gestures";
}

tipsay(r: ref Report): string
{
	if(r.tip != nil)
		return ", tip switch";
	return "";
}

#
# Read reports and turn them into pointer movement.
#
poll(fd, ptr: ref Sys->FD, ival: int, maxpkt: int)
{
	#
	# Exactly one report per read.
	#
	# Asking for more does not mean "give me whatever is there": it
	# programs the controller for that many PACKETS, so the read
	# cannot finish until that many reports have arrived. The
	# keyboard driver learnt this the expensive way -- a 64-byte read
	# from an 8-byte endpoint waited for eight keystrokes and threw
	# seven away.
	#
	n := Reportlen;
	if(maxpkt > n)
		n = maxpkt;
	buf := array[n] of byte;

	nerr := 0;
	for(;;){
		nr := sys->read(fd, buf, len buf);
		if(nr < 0){
			if(isdetached()){
				sys->print("mouseusb: %s detached\n", dev);
				return;
			}
		#
		# A run of read ERRORS means the device is gone.
		#
		# Unplugging one does not stop the driver polling it: every
		# transfer then fails, and a loop that treats a failure the
		# same as "nothing to report" polls a dead endpoint for
		# ever, at a hundred failures a second. Distinguish them --
		# a short read is an idle device, a negative one is a
		# broken transfer -- and give up on a run of the latter.
		#
		# The count resets on any successful read, so a device that
		# glitches and recovers is not abandoned.
		#
			#
			# Say WHY, once per run: the controller's completion
			# code is the difference between a device that went
			# away and a transfer the host got wrong.
			#
			if(nerr == 0)
				sys->print("mouseusb: %s read failed: %r\n", dev);
			if(++nerr >= Maxerr){
				sys->print("mouseusb: %s stopped responding (%r); unplugged?\n", dev);
				return;
			}
			sys->sleep(ival);
			continue;
		}
		if(nr < Reportlen){
			#
			# Wait a poll interval rather than spinning as fast
			# as the endpoint can say "nothing", which starves
			# everything else on a single core.
			#
			sys->sleep(ival);
			continue;
		}

		nerr = 0;
		b := buttons(int buf[0]);
		dx := signed(int buf[1]);
		dy := signed(int buf[2]);

		#
		# "d", not "m": this is MOVEMENT.
		#
		# A mouse has no idea where it is and never reports a
		# position. The accumulated position -- and the clamp that
		# keeps it on the screen -- lives in the pointer device,
		# so that every source of pointer data shares one answer
		# rather than each keeping its own.
		#
		s := sys->sprint("d%d %d %d", dx, dy, b);
		if(sys->write(ptr, array of byte s, len array of byte s) < 0){
			sys->print("mouseusb: write to /dev/pointer failed: %r\n");
			return;
		}

		#
		# The wheel, when the report carries one: byte 3, signed,
		# positive rolling away from the hand. Delivered the way the
		# hosted emulator delivers it (emu/MacOSX/win.c): one pointer
		# event per tick with button 8 for up or 16 for down, and the
		# bit cleared again straight after, so an application counts
		# each event as one tick rather than seeing a wheel button
		# "held" across every later motion. Every wm application in
		# the tree already scrolls on exactly these bits; none of
		# them could, because this byte was read and dropped.
		#
		if(nr >= 4){
			w := signed(int buf[3]);
			bit := 8;
			if(w < 0){
				bit = 16;
				w = -w;
			}
			for(; w > 0; w--){
				t := sys->sprint("d0 0 %d", b | bit);
				sys->write(ptr, array of byte t, len array of byte t);
				t = sys->sprint("d0 0 %d", b);
				sys->write(ptr, array of byte t, len array of byte t);
			}
		}
	}
}

#
# A HID report byte is SIGNED, and Limbo's >> is logical rather than
# arithmetic, so the usual sign-extension trick silently does the wrong
# thing here. Comparing against 128 says what is meant.
#
signed(v: int): int
{
	if(v > 127)
		return v - 256;
	return v;
}

buttons(hid: int): int
{
	b := 0;
	if(hid & Hidleft)
		b |= Mleft;
	if(hid & Hidmiddle)
		b |= Mmiddle;
	if(hid & Hidright)
		b |= Mright;
	return b;
}

intrendpoint(): (int, int, int)
{
	hdr := array[9] of byte;

	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, hdr) < len hdr)
		return (-1, 0, 0);
	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 512)
		return (-1, 0, 0);

	cfg := array[total] of byte;
	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, cfg) < total)
		return (-1, 0, 0);

	for(i := 0; i + 2 <= total; ){
		dlen := int cfg[i];
		if(dlen < 2)
			break;
		# 5 is an endpoint descriptor; attributes 3 is interrupt
		if(int cfg[i+1] == 5 && i + 6 < total && (int cfg[i+3] & 3) == 3){
			addr := int cfg[i+2];
			if(addr & 16r80){	# IN
				mp := int cfg[i+4] | (int cfg[i+5] << 8);
				ival := 10;
				if(i + 6 < total && int cfg[i+6] > 0)
					ival = int cfg[i+6];
				return (addr & 16rF, mp, ival);
			}
		}
		i += dlen;
	}
	return (-1, 0, 0);
}

openintr(epnum, maxpkt, ival: int): ref Sys->FD
{
	#
	# "interrupt", not "intr".
	#
	# devusb's table spells it in full, and name2ttype falls back to
	# strtol() for anything it does not recognise -- so "intr" parsed
	# as 0 and produced an endpoint of some other type entirely,
	# without an error. Reads on it then took a different path in
	# devusb and returned zero without ever reaching the controller
	# driver, which is why neither the completion log nor the failure
	# log in usbdwc ever printed: the transfer was never attempted.
	#
	if(sys->fprint(ctlfd, "new %d interrupt r", epnum) < 0){
		sys->print("mouseusb: cannot create endpoint %d: %r\n", epnum);
		return nil;
	}
	name := epname(dev, epnum);

	#
	# The endpoint inherits nothing: devusb leaves maxpkt at the 8
	# every endpoint starts with, and the polling interval at zero.
	# A boot keyboard's report is eight bytes so the size happens to
	# be right, but relying on that would break the moment something
	# reports more.
	#
	efd := sys->open("/usb/usb/" + name + "/ctl", Sys->ORDWR);
	if(efd == nil || sys->fprint(efd, "maxpkt %d", maxpkt) < 0){
		sys->print("mouseusb: cannot set %s packet size: %r\n", name);
		return nil;
	}
	sys->fprint(efd, "pollival %d", ival);

	fd := sys->open("/usb/usb/" + name + "/data", Sys->OREAD);
	if(fd == nil)
		sys->print("mouseusb: cannot open %s: %r\n", name);
	return fd;
}

epname(d: string, n: int): string
{
	for(i := 0; i < len d; i++)
		if(d[i] == '.')
			return d[0:i] + "." + string n;
	return d;
}
ctlout(rtype, req, value, index: int): int
{
	buf := array[8] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	buf[2] = byte value;
	buf[3] = byte (value >> 8);
	buf[4] = byte index;
	buf[5] = byte (index >> 8);
	buf[6] = byte 0;
	buf[7] = byte 0;

	if(sys->write(ep0, buf, len buf) != len buf)
		return -1;
	#
	# The reply decides whether it worked, and this threw it away.
	#
	# A stalled control request -- which is what a device answers when
	# it does not support a request, or does not support it addressed
	# the way it was -- fails on the READ, not the write. Returning 0
	# regardless meant SET_PROTOCOL and SET_IDLE could both be
	# refused in silence, and this driver would report itself ready
	# having configured nothing.
	#
	rep := array[8] of byte;
	if(sys->read(ep0, rep, len rep) < 0)
		return -1;
	return 0;
}
ctlin(rtype, req, value: int, data: array of byte): int
{
	buf := array[8] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	buf[2] = byte value;
	buf[3] = byte (value >> 8);
	buf[4] = byte 0;
	buf[5] = byte 0;
	buf[6] = byte (len data);
	buf[7] = byte ((len data) >> 8);

	if(sys->write(ep0, buf, len buf) != len buf)
		return -1;
	return sys->read(ep0, data, len data);
}

#
# devusb answers every transfer to a detached device with this, at
# once; there is nothing to wait out.
#
isdetached(): int
{
	e := sys->sprint("%r");
	for(i := 0; i + 8 <= len e; i++)
		if(e[i:i+8] == "detached")
			return 1;
	return 0;
}

isinuse(): int
{
	e := sys->sprint("%r");
	for(i := 0; i + 6 <= len e; i++)
		if(e[i:i+6] == "in use")
			return 1;
	return 0;
}

#
# The card's word on this device: the words after "vid:pid" on its line
# of the quirks file, or nil. A missing file is the usual case.
#
quirks(vidpid: string): list of string
{
	if(vidpid == nil)
		return nil;
	fd := sys->open(Quirkfile, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nw, w) := sys->tokenize(hd lines, " \t");
		if(nw > 0 && hd w == vidpid)
			return tl w;
	}
	return nil;
}

#
# The interface's report descriptor, read and parsed; nil if it cannot
# be read or describes no X and Y.
#
readreport(iface: int): ref Report
{
	buf := array[1024] of byte;
	n := ctlin2(Rd2h|Riface, Rgetdesc, Dreport << 8, iface, buf);
	if(n <= 0){
		sys->print("mouseusb: %s report descriptor unreadable (%r); boot protocol\n", dev);
		return nil;
	}
	r := parsereport(buf[0:n]);
	if(r == nil)
		sys->print("mouseusb: %s report descriptor (%d bytes) has no X and Y; boot protocol\n", dev, n);
	return r;
}

#
# A HID report descriptor, as far as a pointer needs it: every variable
# input field with its page, usage, place, width, range and whether it
# is relative; then the first report that has both X and Y, and in that
# report the buttons, the wheel and a digitizer's tip switch. Arrays of
# usages (a keyboard's) and constant fields are only stepped over.
# PUSH and POP are not followed; no pointer seen yet uses them.
#
parsereport(d: array of byte): ref Report
{
	off := array[256] of {* => 0};
	page := 0;
	lmin := 0;
	lmax := 0;
	lmaxu := 0;
	rsize := 0;
	rcount := 0;
	rid := 0;
	hasids := 0;
	usages: list of int;	# extended (page<<16 | usage) or plain, in reverse order
	umin := -1;
	umax := -1;
	fields: list of (int, ref Field);
	foff := array[256] of {* => 0};	# feature reports' bit offsets
	colls: list of (int, int, int);	# open collections: (kind, usage, finger)
	nfinger := 0;
	mode: ref Field;
	modeid := 0;

	for(i := 0; i < len d; ){
		b := int d[i];
		if(b == 16rFE){	# long item: skipped
			if(i + 1 >= len d)
				break;
			i += 3 + int d[i+1];
			continue;
		}
		sz := b & 3;
		if(sz == 3)
			sz = 4;
		typ := (b >> 2) & 3;
		tag := (b >> 4) & 16rF;
		if(i + 1 + sz > len d)
			break;
		v := 0;
		for(k := 0; k < sz; k++)
			v |= int d[i+1+k] << (8*k);
		sv := v;
		if(sz == 1 && (v & 16r80))
			sv = v - 16r100;
		else if(sz == 2 && (v & 16r8000))
			sv = v - 16r10000;
		i += 1 + sz;

		case typ {
		0 =>	# main
			# where this item is: its application and its finger
			app := 0;
			fing := -1;
			for(cl := colls; cl != nil; cl = tl cl){
				(ck, cu, cf) := hd cl;
				if(fing < 0 && cf >= 0)
					fing = cf;
				if(app == 0 && ck == 1)
					app = cu;
			}
			if(tag == 16rA){	# collection: its usage the latest given
				cu := 0;
				if(usages != nil){
					cu = hd usages;
					if((cu >> 16) == 0)
						cu |= page << 16;
				}
				cf := -1;
				if(cu == (Pgdigitizer<<16 | Ufinger))
					cf = nfinger++;
				colls = (v, cu, cf) :: colls;
			} else if(tag == 16rC){	# end collection
				if(colls != nil)
					colls = tl colls;
			} else if(tag == 16rB){	# feature: only the device mode is wanted
				if((v & 1) == 0 && (v & 2) != 0){
					ul: list of int;
					for(us := usages; us != nil; us = tl us)
						ul = hd us :: ul;
					for(k = 0; k < rcount; k++){
						u := 0;
						if(ul != nil){
							u = hd ul;
							ul = tl ul;
						}
						up := page;
						if(u >> 16){
							up = (u >> 16) & 16rFFFF;
							u &= 16rFFFF;
						}
						if(up == Pgdigitizer && u == Umode && mode == nil){
							mode = ref Field(up, u, foff[rid], rsize, lmin, lmax, 0, -1, app);
							modeid = rid;
						}
						foff[rid] += rsize;
					}
				} else
					foff[rid] += rsize*rcount;
			}
			if(tag == 8){	# input
				n := rsize*rcount;
				if((v & 1) || (v & 2) == 0)	# constant, or an array
					off[rid] += n;
				else {
					ul: list of int;
					for(us := usages; us != nil; us = tl us)
						ul = hd us :: ul;	# into the order they were given
					last := 0;
					for(k = 0; k < rcount; k++){
						u := 0;
						if(ul != nil){
							u = hd ul;
							last = u;
							ul = tl ul;
						} else if(usages != nil)
							u = last;
						else if(umin >= 0 && umin + k <= umax)
							u = umin + k;
						up := page;
						if(u >> 16){
							up = (u >> 16) & 16rFFFF;
							u &= 16rFFFF;
						}
						mx := lmax;
						if(lmin >= 0 && lmax < lmin)
							mx = lmaxu;	# a maximum with its top bit set is unsigned
						fields = (rid, ref Field(up, u, off[rid], rsize, lmin, mx, (v >> 2) & 1, fing, app)) :: fields;
						off[rid] += rsize;
					}
				}
			}
			usages = nil;
			umin = umax = -1;
		1 =>	# global
			case tag {
			0 =>	page = v;
			1 =>	lmin = sv;
			2 =>	lmax = sv; lmaxu = v;
			7 =>	rsize = v;
			8 =>	rid = v & 16rFF; hasids = 1;
			9 =>	rcount = v;
			}
		2 =>	# local
			case tag {
			0 =>
				if(sz == 4)
					usages = v :: usages;
				else
					usages = (v & 16rFFFF) :: usages;
			1 =>	umin = v & 16rFFFF;
			2 =>	umax = v & 16rFFFF;
			}
		}
	}

	# the fields went on in reverse
	fl: list of (int, ref Field);
	for(; fields != nil; fields = tl fields)
		fl = hd fields :: fl;

	r: ref Report;
	for(l := fl; l != nil && r == nil; l = tl l){
		(id, f) := hd l;
		if(f.page != Pgdesktop || f.usage != Ux)
			continue;
		for(m := fl; m != nil; m = tl m){
			(id2, g) := hd m;
			if(id2 == id && g.page == Pgdesktop && g.usage == Uy){
				r = ref Report(id, hasids, f, g, nil, nil, array[3] of ref Field,
					f.app == (Pgdigitizer<<16 | Utouchscreen), nil, nil, 0, 0);
				break;
			}
		}
	}
	if(r == nil)
		return nil;
	for(l = fl; l != nil; l = tl l){
		(id, f) := hd l;
		if(id != r.id)
			continue;
		if(f.page == Pgbutton && f.usage >= 1 && f.usage <= 3 && r.btn[f.usage-1] == nil)
			r.btn[f.usage-1] = f;
		else if(f.page == Pgdesktop && f.usage == Uwheel && r.wheel == nil)
			r.wheel = f;
		else if(f.page == Pgdigitizer && f.usage == Utip && r.tip == nil)
			r.tip = f;
	}

	#
	# The fingers: a slot for each Finger collection with an X and a Y,
	# all in one report, and that report's contact count.
	#
	if(nfinger > 0){
		slots := array[nfinger] of ref Slot;
		mtid := -1;
		for(l = fl; l != nil; l = tl l){
			(id, f) := hd l;
			if(f.finger < 0 || f.finger >= nfinger)
				continue;
			if(mtid < 0)
				mtid = id;
			if(id != mtid)
				continue;
			sl := slots[f.finger];
			if(sl == nil)
				sl = slots[f.finger] = ref Slot;
			if(f.page == Pgdigitizer && f.usage == Utip && sl.tip == nil)
				sl.tip = f;
			else if(f.page == Pgdigitizer && f.usage == Ucid && sl.cid == nil)
				sl.cid = f;
			else if(f.page == Pgdesktop && f.usage == Ux && sl.x == nil)
				sl.x = f;
			else if(f.page == Pgdesktop && f.usage == Uy && sl.y == nil)
				sl.y = f;
		}
		ns := 0;
		for(k := 0; k < nfinger; k++)
			if(slots[k] != nil && slots[k].tip != nil && slots[k].x != nil && slots[k].y != nil)
				slots[ns++] = slots[k];
		if(ns > 0){
			m := ref Multi(mtid, slots[0:ns], nil);
			for(l = fl; l != nil; l = tl l){
				(id, f) := hd l;
				if(id == mtid && f.page == Pgdigitizer && f.usage == Ucount && m.count == nil)
					m.count = f;
			}
			r.mt = m;
			r.touch = 1;
		}
	}
	if(mode != nil){
		r.mode = mode;
		r.modeid = modeid;
		r.modelen = (foff[modeid] + 7) / 8;
		if(hasids)
			r.modelen++;
	}
	return r;
}

#
# A field's value out of a report, sign-extended when its range is
# signed; ok is 0 if the report is too short to hold it.
#
getf(data: array of byte, base: int, f: ref Field): (int, int)
{
	if(f == nil || f.size <= 0 || f.size > 32 || base + f.off + f.size > 8*len data)
		return (0, 0);
	v := 0;
	for(k := 0; k < f.size; k++){
		bit := base + f.off + k;
		if((int data[bit >> 3] >> (bit & 7)) & 1)
			v |= 1 << k;
	}
	if(f.lmin < 0 && f.size < 32 && (v & (1 << (f.size-1))))
		v -= 1 << f.size;
	return (v, 1);
}

# an absolute value as a fraction of the screen, 0..65535
scale(v: int, f: ref Field): int
{
	if(f.lmax <= f.lmin)
		return 0;
	if(v < f.lmin)
		v = f.lmin;
	if(v > f.lmax)
		v = f.lmax;
	return int ((big (v - f.lmin) * big 65535) / big (f.lmax - f.lmin));
}

#
# One report per read, as poll() above, decoded by the descriptor.
#
# With g, the device is a touch screen: its fingers go through g, which
# says what they are as a pointer, and to /dev/fingers each as itself.
# A finger held still sends nothing, so a clock wakes this when g says
# a hold falls due.
#
pollreport(fd, ptr: ref Sys->FD, ival, maxpkt: int, r: ref Report, g: ref Gest)
{
	if(maxpkt < 1)
		maxpkt = 8;
	rc := chan of array of byte;
	spawn reader(fd, ival, maxpkt, rc);
	alarm := chan of int;
	waiting := 0;		# an alarm is set
	if(g != nil)
		fingers = sys->open("/dev/fingers", Sys->OWRITE);
	st := ref State(ref Frame, 0, -1, -1);
	for(;;){
		out: list of string;
		alt {
		buf := <-rc =>
			if(buf == nil)
				return;
			out = onreport(buf, r, g, st, sys->millisec());
		<-alarm =>
			waiting = 0;
			out = g.tick(sys->millisec());
		}
		for(; out != nil; out = tl out){
			a := array of byte hd out;
			if(sys->write(ptr, a, len a) < 0){
				sys->print("mouseusb: write to /dev/pointer failed: %r\n");
				return;
			}
		}
		if(g != nil && !waiting && (t := g.due()) >= 0){
			waiting = 1;
			spawn wake(alarm, t - sys->millisec());
		}
	}
}

# What pollreport keeps between reports
State: adt {
	fr:	ref Frame;	# a multi-touch frame being gathered
	lastb:	int;		# an absolute pointer's last buttons and place
	lastx:	int;
	lasty:	int;
};

#
# One report: what to write to /dev/pointer for it, in order.
#
onreport(buf: array of byte, r: ref Report, g: ref Gest, st: ref State, now: int): list of string
{
	if(r.mt != nil && g != nil){
		(count, c, ok) := decodemt(buf, r);
		if(ok){
			(done, frame) := st.fr.add(count, c);
			if(!done)
				return nil;
			pts: list of (int, int);
			for(; frame != nil; frame = tl frame){
				(id, on, x, y) := hd frame;
				if(on)
					pts = (x, y) :: pts;
				seefinger(id, on, x, y);
			}
			endframe();
			return g.frame(revpts(pts), now);
		}
	}
	(b, x, y, w, ok) := decode(buf, r);
	if(!ok)
		return nil;	# another report of the device's, or a short one
	if(g != nil){
		# one finger: the tip or button 1
		pts: list of (int, int);
		if(b & Mleft)
			pts = (x, y) :: nil;
		seefinger(0, b & Mleft, x, y);
		endframe();
		return g.frame(pts, now);
	}
	s: string;
	if(r.x.rel)
		s = sys->sprint("d%d %d %d", x, y, b);
	else {
		#
		# Lifting the finger ends the touch where it was. Some
		# panels report 0,0 with the release, which taken at
		# its word would fling the pointer to a corner just as
		# the button comes up.
		#
		if(b == 0 && st.lastb != 0 && st.lastx >= 0){
			x = st.lastx;
			y = st.lasty;
		}
		if(x == st.lastx && y == st.lasty && b == st.lastb)
			return nil;
		s = sys->sprint("a%d %d %d", x, y, b);
		st.lastx = x;
		st.lasty = y;
	}
	st.lastb = b;
	# the wheel as poll() delivers it: a button-8 or -16 press and release per tick
	out: list of string;
	bit := 8;
	if(w < 0){
		bit = 16;
		w = -w;
	}
	for(; w > 0; w--)
		out = sys->sprint("d0 0 %d", b | bit) :: sys->sprint("d0 0 %d", b) :: out;
	return s :: out;	# the move first
}

wake(c: chan of int, ms: int)
{
	if(ms > 0)
		sys->sleep(ms);
	c <-= 1;
}

#
# The interrupt endpoint's reports, one a read, to c; nil when the
# device is gone.
#
reader(fd: ref Sys->FD, ival, maxpkt: int, c: chan of array of byte)
{
	buf := array[maxpkt] of byte;
	nerr := 0;
	for(;;){
		nr := sys->read(fd, buf, len buf);
		if(nr < 0){
			if(isdetached()){
				sys->print("mouseusb: %s detached\n", dev);
				break;
			}
			if(nerr == 0)
				sys->print("mouseusb: %s read failed: %r\n", dev);
			if(++nerr >= Maxerr){
				sys->print("mouseusb: %s stopped responding (%r); unplugged?\n", dev);
				break;
			}
			sys->sleep(ival);
			continue;
		}
		nerr = 0;
		if(nr == 0){
			sys->sleep(ival);
			continue;
		}
		d := array[nr] of byte;
		d[0:] = buf[0:nr];
		c <-= d;
	}
	c <-= nil;
}

revpts(l: list of (int, int)): list of (int, int)
{
	r: list of (int, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

#
# The fingers to /dev/fingers (pointer(3)), as the Pi's panel's are, for
# a program that needs each (a keyboard on the screen typed with two
# thumbs): "a<id> x y on", a fraction of the screen, the kernel scaling
# it. The device's contact ids are its own, and may be large; each is
# given a small one while it is down. seefinger notes each contact of a
# frame, endframe lifts those the frame did not have.
#
Maxfinger:	con 16;
fingers: ref Sys->FD;
fcid := array[Maxfinger] of {* => -1};	# the device's id on each of ours
fx := array[Maxfinger] of {* => 0};
fy := array[Maxfinger] of {* => 0};
fseen := array[Maxfinger] of {* => 0};

seefinger(cid, on, x, y: int)
{
	if(fingers == nil)
		return;
	if(!on)
		return;	# endframe lifts what the frame did not have down
	i := 0;
	for(; i < Maxfinger; i++)
		if(fcid[i] == cid)
			break;
	if(i == Maxfinger){
		for(i = 0; i < Maxfinger; i++)
			if(fcid[i] < 0)
				break;
		if(i == Maxfinger)
			return;	# more fingers than ids: this one is not told
		fcid[i] = cid;
		fx[i] = fy[i] = -1;
	}
	fseen[i] = 1;
	if(fx[i] != x || fy[i] != y){
		fx[i] = x;
		fy[i] = y;
		postfinger(i, x, y, 1);
	}
}

endframe()
{
	if(fingers == nil)
		return;
	for(i := 0; i < Maxfinger; i++){
		if(fcid[i] >= 0 && !fseen[i]){
			postfinger(i, fx[i], fy[i], 0);
			fcid[i] = -1;
		}
		fseen[i] = 0;
	}
}

postfinger(id, x, y, on: int)
{
	a := array of byte sys->sprint("a%d %d %d %d", id, x, y, on);
	if(sys->write(fingers, a, len a) < 0){
		sys->print("mouseusb: write to /dev/fingers failed: %r\n");
		fingers = nil;
	}
}

#
# One report: (buttons, x, y, wheel, ok). x and y are movement for a
# relative device and a fraction of the screen (0..65535, the quirks
# applied) for an absolute one. ok is 0 for a report this is not.
#
decode(data: array of byte, r: ref Report): (int, int, int, int, int)
{
	base := 0;
	if(r.hasids){
		if(len data < 1 || int data[0] != r.id)
			return (0, 0, 0, 0, 0);
		base = 8;
	}
	(x, okx) := getf(data, base, r.x);
	(y, oky) := getf(data, base, r.y);
	if(!okx || !oky)
		return (0, 0, 0, 0, 0);
	b := 0;
	(v, ok) := getf(data, base, r.btn[0]);
	if(ok && v)
		b |= Mleft;
	(v, ok) = getf(data, base, r.btn[1]);
	if(ok && v)
		b |= Mright;
	(v, ok) = getf(data, base, r.btn[2]);
	if(ok && v)
		b |= Mmiddle;
	(v, ok) = getf(data, base, r.tip);
	if(ok && v)
		b |= Mleft;
	w := 0;
	if(r.wheel != nil)
		(w, nil) = getf(data, base, r.wheel);
	if(!r.x.rel){
		x = scale(x, r.x);
		y = scale(y, r.y);
		if(invertx)
			x = 65535 - x;
		if(inverty)
			y = 65535 - y;
	} else {
		if(invertx)
			x = -x;
		if(inverty)
			y = -y;
	}
	if(swapxy)
		(x, y) = (y, x);
	return (b, x, y, w, 1);
}

ctlin2(rtype, req, value, index: int, data: array of byte): int
{
	buf := array[8] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	buf[2] = byte value;
	buf[3] = byte (value >> 8);
	buf[4] = byte index;
	buf[5] = byte (index >> 8);
	buf[6] = byte (len data);
	buf[7] = byte ((len data) >> 8);

	if(sys->write(ep0, buf, len buf) != len buf)
		return -1;
	return sys->read(ep0, data, len data);
}

#
# A control transfer with an OUT data stage: devusb takes the setup
# packet and its data as one write (etherusb's ctlout says why).
#
ctloutd(rtype, req, value, index: int, data: array of byte): int
{
	buf := array[8 + len data] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	buf[2] = byte value;
	buf[3] = byte (value >> 8);
	buf[4] = byte index;
	buf[5] = byte (index >> 8);
	buf[6] = byte (len data);
	buf[7] = byte ((len data) >> 8);
	buf[8:] = data;
	if(sys->write(ep0, buf, len buf) != len buf)
		return -1;
	rep := array[8] of byte;
	if(sys->read(ep0, rep, len rep) < 0)
		return -1;
	return 0;
}

#
# A multi-touch report's fingers: (count, contacts, ok), each contact
# (id, on, x, y), x and y fractions of the screen as decode's, the
# quirks applied.  count is the frame's contact count, -1 if the report
# has none; ok 0 for a report this is not.
#
decodemt(data: array of byte, r: ref Report): (int, list of (int, int, int, int), int)
{
	m := r.mt;
	base := 0;
	if(r.hasids){
		if(len data < 1 || int data[0] != m.id)
			return (0, nil, 0);
		base = 8;
	}
	count := -1;
	if(m.count != nil){
		(c, ok) := getf(data, base, m.count);
		if(!ok)
			return (0, nil, 0);
		count = c;
	}
	l: list of (int, int, int, int);
	for(i := len m.slots - 1; i >= 0; i--){
		sl := m.slots[i];
		(on, ok) := getf(data, base, sl.tip);
		(x, okx) := getf(data, base, sl.x);
		(y, oky) := getf(data, base, sl.y);
		if(!ok || !okx || !oky)
			continue;
		id := i;
		if(sl.cid != nil)
			(id, nil) = getf(data, base, sl.cid);
		(x, y) = absxy(x, y, sl.x, sl.y);
		l = (id, on != 0, x, y) :: l;
	}
	return (count, l, 1);
}

# an absolute position as a fraction of the screen, the quirks applied
absxy(x, y: int, fx, fy: ref Field): (int, int)
{
	x = scale(x, fx);
	y = scale(y, fy);
	if(invertx)
		x = 65535 - x;
	if(inverty)
		y = 65535 - y;
	if(swapxy)
		(x, y) = (y, x);
	return (x, y);
}

#
# The contacts of one frame.  A device that can carry fewer fingers in
# a report than are down ("hybrid" mode) sends the frame's count in its
# first report and 0 in those after; one that carries them all
# ("parallel") a count no more than its slots.  A device with no count
# sends a whole frame each report.
#
Frame: adt {
	pend:	list of (int, int, int, int);	# in reverse
	want:	int;

	add:	fn(f: self ref Frame, count: int, c: list of (int, int, int, int)): (int, list of (int, int, int, int));
};

Frame.add(f: self ref Frame, count: int, c: list of (int, int, int, int)): (int, list of (int, int, int, int))
{
	if(count < 0)
		return (1, c);
	if(count > 0){
		f.pend = nil;
		f.want = count;
	} else if(f.want <= 0)
		return (1, nil);	# a count of 0 with nothing begun: no fingers
	for(; c != nil && len f.pend < f.want; c = tl c)
		f.pend = hd c :: f.pend;
	if(len f.pend < f.want)
		return (0, nil);
	l: list of (int, int, int, int);
	for(; f.pend != nil; f.pend = tl f.pend)
		l = hd f.pend :: l;
	f.want = 0;
	return (1, l);
}

#
# The device mode feature report asking for multi-input: cur as the
# device gave it (or zeros), the mode field 2, the rest as they were.
#
modereport(r: ref Report, cur: array of byte): array of byte
{
	b := array[r.modelen] of {* => byte 0};
	if(cur != nil && len cur == len b)
		b[0:] = cur;
	base := 0;
	if(r.hasids){
		b[0] = byte r.modeid;
		base = 8;
	}
	f := r.mode;
	for(k := 0; k < f.size; k++){
		bit := base + f.off + k;
		if(bit >= 8*len b)
			break;
		if((Multiinput >> k) & 1)
			b[bit>>3] |= byte (1 << (bit & 7));
		else
			b[bit>>3] &= byte ~(1 << (bit & 7));
	}
	return b;
}

#
# Ask a multi-touch device for every finger.  Until told, such a device
# reports as a mouse, one finger and a button (the mode Windows 7's
# drivers set, and Linux's hid-multitouch).
#
setmode(r: ref Report, iface: int)
{
	cur := array[r.modelen] of byte;
	if(ctlin2(Rd2h|Rclass|Riface, Rgetreport, Rfeature<<8 | r.modeid, iface, cur) != len cur)
		cur = nil;
	if(ctloutd(Rh2d|Rclass|Riface, Rsetreport, Rfeature<<8 | r.modeid, iface, modereport(r, cur)) < 0)
		sys->print("mouseusb: %s: SET_REPORT(device mode multi-touch) failed: %r\n", dev);
}

#
# Touch screens: which pointers are one, and a multi-touch digitizer's
# descriptor as Windows asks for one (two Finger collections, tip,
# contact id, X and Y each; a contact count; a Device Mode feature in a
# Device Configuration collection), its frames gathered whole and its
# fingers through touchgest(2).
#
selftestmt(tablet, touch: array of byte): int
{
	ok := 1;
	if(istouch(parsereport(tablet))){
		sys->print("mouseusb: selftest: QEMU's usb-tablet (three buttons, a wheel) taken for a touch screen\n");
		ok = 0;
	}
	if(!istouch(parsereport(touch))){
		sys->print("mouseusb: selftest: a Touch Screen digitizer not taken for one\n");
		ok = 0;
	}
	finger := array[] of {
		byte 16r09, byte 16r22, byte 16rA1, byte 16r02,		# Finger, logical
		byte 16r09, byte 16r42, byte 16r15, byte 16r00, byte 16r25, byte 16r01,
		byte 16r75, byte 16r01, byte 16r95, byte 16r01, byte 16r81, byte 16r02,	# tip
		byte 16r95, byte 16r07, byte 16r81, byte 16r03,		# pad
		byte 16r75, byte 16r08, byte 16r95, byte 16r01, byte 16r09, byte 16r51,
		byte 16r81, byte 16r02,					# contact id
		byte 16r05, byte 16r01, byte 16r26, byte 16rFF, byte 16r0F,
		byte 16r75, byte 16r10, byte 16r09, byte 16r30, byte 16r09, byte 16r31,
		byte 16r95, byte 16r02, byte 16r81, byte 16r02,		# X, Y 0..4095
		byte 16r05, byte 16r0D, byte 16rC0,
	};
	head := array[] of {
		byte 16r05, byte 16r0D, byte 16r09, byte 16r04, byte 16rA1, byte 16r01,	# Touch Screen
		byte 16r85, byte 16r01,
	};
	tail := array[] of {
		byte 16r09, byte 16r54, byte 16r25, byte 16r0A, byte 16r75, byte 16r08,
		byte 16r95, byte 16r01, byte 16r81, byte 16r02,		# contact count
		byte 16r09, byte 16r55, byte 16rB1, byte 16r02,		# contact count maximum (feature)
		byte 16rC0,
		byte 16r09, byte 16r0E, byte 16rA1, byte 16r01, byte 16r85, byte 16r03,	# Device Configuration
		byte 16r09, byte 16r23, byte 16rA1, byte 16r02,
		byte 16r09, byte 16r52, byte 16r09, byte 16r53, byte 16r15, byte 16r00,
		byte 16r25, byte 16r0A, byte 16r75, byte 16r08, byte 16r95, byte 16r02,
		byte 16rB1, byte 16r02,					# device mode, device identifier
		byte 16rC0, byte 16rC0,
	};
	mt := array[len head + 2*len finger + len tail] of byte;
	mt[0:] = head;
	mt[len head:] = finger;
	mt[len head + len finger:] = finger;
	mt[len head + 2*len finger:] = tail;
	r := parsereport(mt);
	if(r == nil || r.mt == nil || len r.mt.slots != 2 || r.mt.id != 1 || r.mt.count == nil
	|| r.mt.count.off != 96 || r.mt.slots[1].x.off != 64 || r.mt.slots[1].cid.off != 56
	|| r.mode == nil || r.modeid != 3 || r.modelen != 3 || r.mode.off != 0 || !istouch(r)){
		sys->print("mouseusb: selftest: multi-touch descriptor parsed wrong\n");
		return 0;
	}
	m := modereport(r, nil);
	if(len m != 3 || int m[0] != 3 || int m[1] != 2 || int m[2] != 0){
		sys->print("mouseusb: selftest: device mode report wrong\n");
		ok = 0;
	}
	m = modereport(r, array[] of {byte 3, byte 16rFF, byte 7});
	if(int m[1] != 2 || int m[2] != 7){
		sys->print("mouseusb: selftest: device mode report did not keep the rest\n");
		ok = 0;
	}

	if(touchgest == nil)
		touchgest = load Touchgest Touchgest->PATH;
	if(touchgest == nil){
		sys->print("mouseusb: selftest: cannot load %s: %r\n", Touchgest->PATH);
		return 0;
	}
	g := Gest.new("a", Slopfrac, Stepfrac);
	st := ref State(ref Frame, 0, -1, -1);
	# finger 5 down at x 2048, y 1024 of 4095: half across, a quarter down
	e := expect("one finger", onreport(rep(5, 2048, 1024, -1, 0, 0, 1), r, g, st, 0),
		"a 32775 16387 1");
	e += expect("held", g.tick(Touchgest->Longms), "a 32775 16387 4");
	e += expect("lifted", onreport(rep(-1, 0, 0, -1, 0, 0, 0), r, g, st, 1000), "a 32775 16387 0");
	# two fingers (between them x 2000), then both a quarter of the screen up:
	# the wheel's down, three ticks of Stepfrac
	e += expect("two fingers", onreport(rep(5, 1000, 2048, 9, 3000, 2048, 2), r, g, st, 2000), "");
	e += expect("two fingers up", onreport(rep(5, 1000, 1024, 9, 3000, 1024, 2), r, g, st, 2100),
		"a 32006 16387 16 a 32006 16387 0 a 32006 16387 16 a 32006 16387 0 a 32006 16387 16 a 32006 16387 0");
	e += expect("lifted", onreport(rep(-1, 0, 0, -1, 0, 0, 0), r, g, st, 2200), "");
	# hybrid: three fingers, two in the first report and one in the next
	e += expect("hybrid's first report: nothing yet",
		onreport(rep(1, 100, 100, 2, 200, 200, 3), r, g, st, 3000), "");
	e += expect("hybrid's second: the frame, three fingers, a gesture",
		onreport(rep(3, 300, 300, -1, 0, 0, 0), r, g, st, 3010), "");
	if(len st.fr.pend != 0)
		e += " [hybrid frame left pending]";
	fr := ref Frame;
	(c1, l1, nil) := decodemt(rep(1, 100, 100, 2, 200, 200, 3), r);
	(done, f) := fr.add(c1, l1);
	if(done || f != nil)
		e += " [hybrid: a frame of 3 taken from a report of 2]";
	(c2, l2, nil) := decodemt(rep(3, 300, 300, -1, 0, 0, 0), r);
	(done, f) = fr.add(c2, l2);
	if(!done || len f != 3)
		e += sys->sprint(" [hybrid: %d fingers in the frame, not 3]", len f);
	else {
		ids := "";
		for(; f != nil; f = tl f){
			(id, on, nil, nil) := hd f;
			ids += sys->sprint(" %d/%d", id, on);
		}
		if(ids != " 1/1 2/1 3/1")
			e += " [hybrid: fingers" + ids + ", not 1 2 3 down]";
	}
	(c3, l3, nil) := decodemt(rep(4, 10, 10, 6, 20, 20, 1), r);
	(done, f) = fr.add(c3, l3);
	if(!done || len f != 1)
		e += " [parallel: a count of 1 not one finger]";
	e += expect("lifted", onreport(rep(-1, 0, 0, -1, 0, 0, 0), r, g, st, 3100), "");
	if(e != nil){
		sys->print("mouseusb: selftest: multi-touch:%s\n", e);
		ok = 0;
	}
	return ok;
}

# The multi-touch descriptor's report 1: two slots (an id of -1 is a slot
# with no finger) and the contact count.
rep(id1, x1, y1, id2, x2, y2, n: int): array of byte
{
	b := array[14] of {* => byte 0};
	b[0] = byte 1;
	slot := array[] of {(id1, x1, y1), (id2, x2, y2)};
	for(i := 0; i < 2; i++){
		(id, x, y) := slot[i];
		o := 1 + 6*i;
		if(id >= 0){
			b[o] = byte 1;
			b[o+1] = byte id;
		}
		b[o+2] = byte x;
		b[o+3] = byte (x >> 8);
		b[o+4] = byte y;
		b[o+5] = byte (y >> 8);
	}
	b[13] = byte n;
	return b;
}

# "" if got is want (its lines joined by blanks), else what differed
expect(what: string, got: list of string, want: string): string
{
	s := "";
	for(; got != nil; got = tl got){
		if(s != "")
			s += " ";
		s += hd got;
	}
	if(s == want)
		return "";
	return sys->sprint(" [%s: got '%s', want '%s']", what, s, want);
}

#
# The parser and decoder against two descriptors, with no device:
# QEMU's usb-tablet (a mouse interface with absolute X and Y, as the
# Waveshare panel's is) and a minimal touchscreen digitizer with a
# report id and a tip switch. mouseusb -t
#
selftest()
{
	ok := 1;
	tablet := array[] of {
		byte 16r05, byte 16r01, byte 16r09, byte 16r02, byte 16rA1, byte 16r01, byte 16r09, byte 16r01,
		byte 16rA1, byte 16r00, byte 16r05, byte 16r09, byte 16r19, byte 16r01, byte 16r29, byte 16r03,
		byte 16r15, byte 16r00, byte 16r25, byte 16r01, byte 16r95, byte 16r03, byte 16r75, byte 16r01,
		byte 16r81, byte 16r02, byte 16r95, byte 16r01, byte 16r75, byte 16r05, byte 16r81, byte 16r01,
		byte 16r05, byte 16r01, byte 16r09, byte 16r30, byte 16r09, byte 16r31, byte 16r15, byte 16r00,
		byte 16r26, byte 16rFF, byte 16r7F, byte 16r35, byte 16r00, byte 16r46, byte 16rFF, byte 16r7F,
		byte 16r75, byte 16r10, byte 16r95, byte 16r02, byte 16r81, byte 16r02, byte 16r05, byte 16r01,
		byte 16r09, byte 16r38, byte 16r15, byte 16r81, byte 16r25, byte 16r7F, byte 16r35, byte 16r00,
		byte 16r45, byte 16r00, byte 16r75, byte 16r08, byte 16r95, byte 16r01, byte 16r81, byte 16r06,
		byte 16rC0, byte 16rC0,
	};
	r := parsereport(tablet);
	if(r == nil){
		sys->print("mouseusb: selftest: tablet: no X and Y found\n");
		ok = 0;
	} else {
		if(r.hasids || r.x.off != 8 || r.x.size != 16 || r.x.rel || r.x.lmax != 32767
		|| r.y.off != 24 || r.btn[0] == nil || r.btn[0].off != 0 || r.wheel == nil || !r.wheel.rel){
			sys->print("mouseusb: selftest: tablet parsed wrong: ids %d x off %d size %d rel %d max %d y off %d\n",
				r.hasids, r.x.off, r.x.size, r.x.rel, r.x.lmax, r.y.off);
			ok = 0;
		}
		# left button, x 16384 (half), y 8192 (a quarter), wheel -1
		(b, x, y, w, dok) := decode(array[] of {byte 1, byte 0, byte 16r40, byte 0, byte 16r20, byte 16rFF}, r);
		if(!dok || b != Mleft || x != 32768 || y != 16384 || w != -1){
			sys->print("mouseusb: selftest: tablet decoded b %d x %d y %d w %d\n", b, x, y, w);
			ok = 0;
		}
	}

	touch := array[] of {
		byte 16r05, byte 16r0D, byte 16r09, byte 16r04, byte 16rA1, byte 16r01, byte 16r85, byte 16r01,
		byte 16r09, byte 16r22, byte 16rA1, byte 16r02, byte 16r09, byte 16r42, byte 16r15, byte 16r00,
		byte 16r25, byte 16r01, byte 16r75, byte 16r01, byte 16r95, byte 16r01, byte 16r81, byte 16r02,
		byte 16r75, byte 16r07, byte 16r81, byte 16r03, byte 16r05, byte 16r01, byte 16r09, byte 16r30,
		byte 16r09, byte 16r31, byte 16r15, byte 16r00, byte 16r26, byte 16rFF, byte 16r0F, byte 16r75,
		byte 16r10, byte 16r95, byte 16r02, byte 16r81, byte 16r02, byte 16rC0, byte 16rC0,
	};
	r = parsereport(touch);
	if(r == nil || !r.hasids || r.id != 1 || r.tip == nil || r.x.lmax != 4095 || r.x.off != 8){
		sys->print("mouseusb: selftest: touchscreen parsed wrong\n");
		ok = 0;
	} else {
		# report 1: finger down at x 4095 (the right edge), y 2048 (about half)
		(b, x, y, nil, dok) := decode(array[] of {byte 1, byte 1, byte 16rFF, byte 16r0F, byte 0, byte 16r08}, r);
		if(!dok || b != Mleft || x != 65535 || y < 32760 || y > 32775){
			sys->print("mouseusb: selftest: touchscreen decoded b %d x %d y %d\n", b, x, y);
			ok = 0;
		}
		# a report with another id is not this one
		(nil, nil, nil, nil, dok) = decode(array[] of {byte 2, byte 1, byte 0, byte 0, byte 0, byte 0}, r);
		if(dok){
			sys->print("mouseusb: selftest: touchscreen took report 2 for report 1\n");
			ok = 0;
		}
	}
	ok &= selftestmt(tablet, touch);
	if(ok)
		sys->print("mouseusb: selftest OK\n");
	else
		sys->print("mouseusb: selftest FAILED\n");
}
