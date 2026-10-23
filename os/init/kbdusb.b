implement Kbdusb;

#
# A USB boot-protocol keyboard, as a program.
#
# Same reasoning as etherusb: the kernel provides the mechanism -- raw
# endpoints through #u -- and what to say to a particular class of device
# is policy, which belongs outside it. See "Decision: device protocols
# live outside the kernel, mechanism inside" in os/bcm2837/README.md.
#
# BOOT protocol first, report protocol when it has to be. The boot
# protocol exists so that a machine which has just started can read a
# keyboard without parsing anything: eight fixed bytes, modifiers, a
# reserved byte, and up to six keycodes held down. Every keyboard whose
# interface says it can speak it (subclass 1) is read that way, as it
# always was.
#
# Some keyboards cannot: an interface of subclass 0 has no boot
# protocol, and what it sends is whatever its HID report descriptor
# describes -- a report ID first, an n-key-rollover bitmap, a vendor
# byte. Read as eight boot bytes that is garbage. For those the
# descriptor is read and parsed (the Hid library, /dis/lib/hid.dis,
# the same one Bluetooth's mouse uses) and the reports decoded by it.
# A boot keyboard can be asked for its reports too -- every key at
# once rather than six, on an n-key-rollover board -- by the card's
# quirks file (/n/dos/usbquirks, "vid:pid report"), or for every
# keyboard by "kbdusb=report" on the kernel's command line. "boot" in
# the quirks file insists on the boot protocol, "ignore" leaves the
# device alone.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "hid.m";
	hid: Hid;
	Keys: import hid;

Kbdusb: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

#
# Control requests. The class-specific ones go to the INTERFACE, which
# is what Rclass|Riface means -- addressing the device would be accepted
# and ignored.
#
Rh2d:		con 16r00;
Rd2h:		con 16r80;
Rclass:		con 16r20;
Riface:		con 1;

Rgetdesc:	con 6;
Rsetproto:	con 11;		# HID: SET_PROTOCOL
Rsetidle:	con 10;		# HID: SET_IDLE

Dconf:		con 2;

Bootproto:	con 0;		# SET_PROTOCOL: 0 is boot, 1 is report
Reportproto:	con 1;
Dreport:	con 16r22;	# GET_DESCRIPTOR: the HID report descriptor
Quirkfile:	con "/n/dos/usbquirks";
Maxreport:	con 64;		# the longest report read, one packet's worth

Reportlen:	con 8;		# the boot keyboard report
Maxerr:		con 100;	# failed reads before deciding it is gone

#
# Modifier bits in byte 0 of the report.
#
Mlshift:	con 16r02;
Mrshift:	con 16r20;
Mlctrl:		con 16r01;
Mrctrl:		con 16r10;
Malt:		con 16r04;
Mraltgr:	con 16r40;

#
# The compose key, as a rune.
#
# Inferno composes accented and symbolic characters through devcons: the
# Latin rune puts kbdputc into a collecting state and the keystrokes
# after it are looked up in os/port/latin1.h, so Alt then ' then e gives
# e-acute. All of that machinery is already in the kernel and already
# linked -- what was missing is that nothing ever sent the rune, because
# this driver ignored the Alt modifier entirely.
#
# It matters beyond typing prose: a file or a host in a namespace can
# have accented characters in its name, and a console that cannot enter
# them cannot reach it.
#
Latin:		con 16rE06F;	# Spec|0x6f, include/keyboard.h

dev: string;
ctlfd: ref Sys->FD;	# the device's ctl file
ep0: ref Sys->FD;	# its control endpoint's data file, held open
iface := 0;		# the HID interface: class requests and the report descriptor go to it

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	args = tl args;
	if(args == nil){
		sys->print("kbdusb: no device given\n");
		return;
	}
	dev = hd args;

	ctlfd = sys->open("/usb/usb/" + dev + "/ctl", Sys->ORDWR);
	if(ctlfd == nil){
		sys->print("kbdusb: cannot open %s ctl: %r\n", dev);
		return;
	}

	#
	# Held open, not reopened per request. devusb stashes a control
	# reply against the endpoint and refuses to answer twice, so a
	# fresh fd for every request leaves replies behind for the next
	# one to trip over -- which osinit's ctlreq says in as many words.
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
		sys->print("kbdusb: cannot open %s data: %r\n", dev);
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
		sys->print("kbdusb: %s has no interrupt endpoint\n", dev);
		return;
	}

	#
	# The interface, the device's vid:pid and the interface's
	# subclass, when the walk gives them. Started by hand with only
	# the endpoint, the keyboard is taken to be interface 0 and boot
	# capable, which is what this driver always assumed.
	#
	vidpid := "";
	sub := 1;
	args = tl tl tl args;
	if(args != nil){
		iface = int hd args;
		if(tl args != nil){
			vidpid = hd tl args;
			if(tl tl args != nil)
				sub = int hd tl tl args;
		}
	}
	wantreport := sub != 1 || cmdlinesays("kbdusb=report");
	for(q := quirks(vidpid); q != nil; q = tl q)
		case hd q {
		"ignore" =>
			sys->print("kbdusb: %s (%s) ignored by %s\n", dev, vidpid, Quirkfile);
			return;
		"report" =>	wantreport = 1;
		"boot" =>	wantreport = 0;
		* =>	;	# the pointer driver's words share the line
		}

	#
	# The report descriptor, when its reports are wanted: what each
	# byte of a report means. A keyboard that has no boot protocol and
	# no usable descriptor cannot be read, and says so; a boot
	# keyboard falls back to the boot protocol.
	#
	keys: list of ref Keys;
	if(wantreport)
		keys = readkeys();
	if(keys == nil && sub != 1){
		sys->print("kbdusb: %s (%s) has no boot protocol and no keyboard report it can read\n", dev, vidpid);
		return;
	}

	#
	# The protocol, before reading anything. A boot keyboard comes
	# out of reset in report protocol, which is the same eight bytes
	# on most but not all of them; asking makes it so. SET_PROTOCOL
	# is a boot device's request -- one without the boot protocol may
	# refuse it -- so a subclass-0 keyboard is left as it is.
	#
	if(sub == 1){
		proto := Bootproto;
		if(keys != nil)
			proto = Reportproto;
		if(ctlout(Rh2d|Rclass|Riface, Rsetproto, proto, iface) < 0)
			sys->print("kbdusb: SET_PROTOCOL(%s) failed: %r\n", protoname(proto));
	}

	#
	# Idle rate: report the current state every Idlems, changed or
	# not, as well as on every change.
	#
	# This used to be idle 0 -- report only on change -- and key
	# repeat was built on top of it by assuming a key held down is
	# silence and a key let go is a report. On this controller a
	# report CAN be missed between polls (the HID endpoints share
	# the bus with the mouse and the network), and a missed release
	# meant a key that repeated for ever, dots marching off the edge
	# of the login screen. Silence cannot be trusted to mean "still
	# held"; a report saying so can. With a periodic report the
	# repeater repeats only while the keyboard keeps confirming the
	# key is down, and a lost report stops the repeat instead of
	# running it away. Identical reports cost nothing: the loop only
	# acts on keys that were not already held.
	#
	if(ctlout(Rh2d|Rclass|Riface, Rsetidle, (Idlems / 4) << 8, iface) < 0)
		sys->print("kbdusb: SET_IDLE failed: %r\n");

	fd := openintr(epnum, maxpkt, ival);
	if(fd == nil)
		return;

	kbd := sys->open("/dev/keyboard", Sys->OWRITE);
	if(kbd == nil){
		sys->print("kbdusb: cannot open /dev/keyboard: %r\n");
		return;
	}

	if(keys == nil){
		sys->print("kbdusb: %s ready on endpoint %d maxpkt %d ival %d\n",
			dev, epnum, maxpkt, ival);
		poll(fd, kbd, ival);
		return;
	}
	ids := "";
	for(l := keys; l != nil; l = tl l)
		ids += sys->sprint(" %d", (hd l).id);
	sys->print("kbdusb: %s ready on endpoint %d maxpkt %d ival %d (report protocol, report%s)\n",
		dev, epnum, maxpkt, ival, ids);
	pollreport(fd, kbd, ival, maxpkt, keys);
}

protoname(p: int): string
{
	if(p == Reportproto)
		return "report";
	return "boot";
}

#
# The keyboard reports the interface's report descriptor describes; nil
# if it cannot be read, the library cannot be loaded, or it describes
# none.
#
readkeys(): list of ref Keys
{
	hid = load Hid Hid->PATH;
	if(hid == nil){
		sys->print("kbdusb: %s: cannot load %s: %r; boot protocol\n", dev, Hid->PATH);
		return nil;
	}
	hid->init();
	buf := array[1024] of byte;
	n := ctlin(Rd2h|Riface, Rgetdesc, Dreport << 8, iface, buf);
	if(n <= 0){
		sys->print("kbdusb: %s report descriptor unreadable (%r)\n", dev);
		return nil;
	}
	keys := hid->keyboard(buf[0:n]);
	if(keys == nil)
		sys->print("kbdusb: %s report descriptor (%d bytes) describes no keyboard report\n", dev, n);
	return keys;
}

#
# The card's word on this device: the words after "vid:pid" on its line
# of the quirks file, or nil. A missing file is the usual case. The
# pointer driver reads the same file; a line can carry words for both.
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

# is this word on the kernel's command line (/dev/bootargs)?
cmdlinesays(word: string): int
{
	fd := sys->open("/dev/bootargs", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	(nil, w) := sys->tokenize(string buf[0:n], " \t\n");
	for(; w != nil; w = tl w)
		if(hd w == word)
			return 1;
	return 0;
}

#
# The interrupt IN endpoint, its packet size and its polling interval,
# from the configuration descriptor. Walked rather than indexed: a
# configuration is a run of variable-length descriptors packed end to
# end, each "length, type".
#
intrendpoint(): (int, int, int)
{
	hdr := array[9] of byte;

	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, hdr) < len hdr)
		return (-1, 0, 0);
	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 512)
		return (-1, 0, 0);

	cfg := array[total] of byte;
	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, cfg) < total)
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
		sys->print("kbdusb: cannot create endpoint %d: %r\n", epnum);
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
		sys->print("kbdusb: cannot set %s packet size: %r\n", name);
		return nil;
	}
	sys->fprint(efd, "pollival %d", ival);

	fd := sys->open("/usb/usb/" + name + "/data", Sys->OREAD);
	if(fd == nil)
		sys->print("kbdusb: cannot open %s: %r\n", name);
	return fd;
}

#
# Read reports and turn them into keystrokes.
#
# Only newly pressed keys are emitted. The report lists what is held
# down, so a key that appears in two consecutive reports is one that has
# not been released -- typing it again on every poll is what turns a
# keyboard into a stuck key.
#
poll(fd, kbd: ref Sys->FD, ival: int)
{
	#
	# One report per read, not a bufferful.
	#
	# Reading 64 bytes from an 8-byte endpoint does not mean "give me
	# whatever is there". It programs the controller for EIGHT packets,
	# so the read cannot finish until eight reports have arrived -- four
	# keystrokes, since a key press and its release are one report each
	# -- and seven of the eight are then thrown away by the decoder
	# below, which only ever looks at the first Reportlen bytes.
	#
	# Asking for exactly one report is what makes a keystroke a
	# keystroke.
	#
	buf := array[Reportlen] of byte;
	i: int;

	spawn repeater(kbd);

	nempty := 0;
	nerr := 0;
	nslow := 0;
	for(;;){
		#
		# Time the read.
		n := sys->read(fd, buf, len buf);
		if(n < 0){
			if(isdetached()){
				sys->print("kbdusb: %s detached\n", dev);
				alive = 0;
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
				sys->print("kbdusb: %s read failed: %r\n", dev);
			if(++nerr >= Maxerr){
				sys->print("kbdusb: %s stopped responding (%r); unplugged?\n", dev);
				alive = 0;
				return;
			}
			sys->sleep(ival);
			continue;
		}
		nerr = 0;
		#
		# Say what the endpoint returns, a few times. A read that
		# returns nothing and a read that returns a report we then
		# decode to nothing look identical from the shell, and they
		# are opposite faults.
		#
		if(n < Reportlen){
			#
			# Wait a poll interval. Without this the loop spins
			# as fast as the endpoint can say "nothing", which
			# starves everything else on a single core and is
			# how this driver behaved on its first run.
			#
			nempty++;
			if(nempty == 200)
				sys->print("kbdusb: %d empty reads; no reports from the keyboard\n",
					nempty);
			sys->sleep(ival);
			continue;
		}
		nempty = 0;

		down: list of int;
		for(i = Reportlen - 1; i >= 2; i--)
			if(int buf[i] != 0)
				down = int buf[i] :: down;
		press(kbd, int buf[0], down);
	}
}

#
# One report's worth of keyboard state, from either protocol: the
# modifier byte in the boot layout and the keys held, as HID usages.
# Only newly pressed keys are emitted; the previous report's are in
# prevmod and prevdown.
#
prevmod := 0;
prevdown: list of int;

press(kbd: ref Sys->FD, mod: int, down: list of int)
{
	lastreport = sys->millisec();

	#
	# Alt is a PREFIX, not a held modifier.
	#
	# Emitted once when it goes down, which is what devcons
	# expects: the rune starts a collecting state that consumes
	# the next keystrokes, rather than modifying the one
	# pressed with it. Sending it on every report while the key
	# is held would restart that collection on each poll and
	# nothing would ever compose.
	#
	if((mod & (Malt|Mraltgr)) != 0 && (prevmod & (Malt|Mraltgr)) == 0)
		emit(kbd, Latin);

	for(l := down; l != nil; l = tl l){
		k := hd l;
		if(member(prevdown, k))
			continue;
		c := decode(k, mod);
		if(c > 0){
			emit(kbd, c);
			heldk = k;
			heldc = c;
			heldat = sys->millisec();
		}
	}
	#
	# The held key, for the repeater: the report says what is
	# down NOW, so a key that has left the report is up.
	#
	if(heldk != 0 && !member(down, heldk)){
		heldk = 0;
		heldc = 0;
	}
	prevmod = mod;
	prevdown = down;
}

member(l: list of int, k: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == k)
			return 1;
	return 0;
}

#
# Reports in report protocol, decoded by the descriptor.
#
# A read is one packet, and a keyboard's report fits in one; maxpkt is
# asked for rather than the report's length because a device with
# several reports (keys, media keys) sends them at different lengths.
# A report with an ID the descriptor gives no keyboard fields to -- a
# media key, a vendor report -- says nothing about the keys, and must
# not be taken to mean they were all let go.
#
pollreport(fd, kbd: ref Sys->FD, ival, maxpkt: int, keys: list of ref Keys)
{
	if(maxpkt <= 0 || maxpkt > Maxreport)
		maxpkt = Maxreport;
	buf := array[maxpkt] of byte;
	hasids := (hd keys).id != 0;

	spawn repeater(kbd);

	nerr := 0;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0){
			if(isdetached()){
				sys->print("kbdusb: %s detached\n", dev);
				alive = 0;
				return;
			}
			if(nerr == 0)
				sys->print("kbdusb: %s read failed: %r\n", dev);
			if(++nerr >= Maxerr){
				sys->print("kbdusb: %s stopped responding (%r); unplugged?\n", dev);
				alive = 0;
				return;
			}
			sys->sleep(ival);
			continue;
		}
		nerr = 0;
		if(n == 0){
			sys->sleep(ival);
			continue;
		}
		k: ref Keys;
		data := buf[0:n];
		if(hasids){
			k = hid->findkeys(keys, int buf[0]);
			data = buf[1:n];
		} else
			k = hd keys;
		if(k == nil)
			continue;
		if(8*len data < k.bits)
			continue;	# short: not a whole report
		(mod, down) := k.held(data);
		press(kbd, mod, down);
	}
}

#
# Key repeat.
#
# Hosted InferNode never needed this: the host's keyboard driver
# repeats a held key and the emulator only ever sees the stream. A
# boot keyboard reports only CHANGES (idle 0), so a key held down is a
# single report followed by silence, and without this holding
# Backspace deleted one character. The report loop records the key it
# last pressed; this thread re-emits it after the usual half-second,
# then thirty times a second, until the report loop sees it go up.
#
Repeatdelay:	con 500;	# ms before the first repeat
Repeatrate:	con 33;		# ms between repeats
Idlems:		con 100;	# how often the keyboard restates what is held
Stalems:	con 350;	# no report for this long = do not trust the held state

heldk := 0;			# HID usage of the key held down, 0 = none
heldc := 0;			# what it decoded to
heldat := 0;			# when it went down, sys->millisec()
alive := 1;			# cleared when the report loop ends, so the repeater leaves too and the module can die
lastreport := 0;		# when the keyboard last said anything at all

repeater(kbd: ref Sys->FD)
{
	for(; alive;){
		sys->sleep(Repeatrate);
		if(heldc == 0)
			continue;
		now := sys->millisec();
		if(now - heldat < Repeatdelay)
			continue;
		if(now - lastreport > Stalems)
			continue;	# the keyboard has gone quiet; a release may have been lost
		emit(kbd, heldc);
	}
}

#
# Send one rune to /dev/keyboard.
#
# As UTF-8, because that is what the write path decodes: devcons walks
# the buffer with chartorune and hands each rune to kbdputc. Runes above
# ASCII -- the compose key among them -- would otherwise arrive as
# whatever their low byte happened to be.
#
emit(kbd: ref Sys->FD, c: int)
{
	b := array of byte sys->sprint("%c", c);
	sys->write(kbd, b, len b);
}

#
# HID usage to character, US layout.
#
# Written out rather than tabulated because the ranges do most of the
# work and the exceptions are few enough to read.
#
decode(k, mod: int): int
{
	shift := (mod & (Mlshift|Mrshift)) != 0;
	ctrl := (mod & (Mlctrl|Mrctrl)) != 0;

	if(k >= 16r04 && k <= 16r1D){		# a-z
		c := k - 16r04 + 'a';
		if(ctrl)
			return c - 'a' + 1;	# control characters
		if(shift)
			return c - 'a' + 'A';
		return c;
	}

	if(k >= 16r1E && k <= 16r26){		# 1-9
		if(shift)
			return "!@#$%^&*("[k - 16r1E];
		return k - 16r1E + '1';
	}
	if(k == 16r27){				# 0
		if(shift)
			return ')';
		return '0';
	}

	case k {
	16r28 =>	return '\n';		# Enter
	16r29 =>	return 16r1B;		# Escape
	16r2A =>	return '\b';		# Backspace
	16r2B =>	return '\t';		# Tab
	16r2C =>	return ' ';
	16r2D =>	if(shift) return '_'; else return '-';
	16r2E =>	if(shift) return '+'; else return '=';
	16r2F =>	if(shift) return '{'; else return '[';
	16r30 =>	if(shift) return '}'; else return ']';
	16r31 =>	if(shift) return '|'; else return '\\';
	16r33 =>	if(shift) return ':'; else return ';';
	16r34 =>	if(shift) return '"'; else return '\'';
	16r35 =>	if(shift) return '~'; else return '`';
	16r36 =>	if(shift) return '<'; else return ',';
	16r37 =>	if(shift) return '>'; else return '.';
	16r38 =>	if(shift) return '?'; else return '/';

	#
	# Navigation keys, as the runes in module/keyboard.m: Spec|View
	# is 16rE010, and Home..BackTab count up from there. These are
	# what the editor, the file tree and Tk's text widgets read for
	# cursor movement and paging; a keyboard without them can type
	# but cannot move.
	#
	16r49 =>	return 16rE063;		# Insert
	16r4A =>	return 16rE010;		# Home
	16r4B =>	return 16rE016;		# Page Up
	16r4C =>	return 16r7F;		# Delete (forward): DEL, as the hosted emulator sends it and Tk's entry binds it
	16r4D =>	return 16rE011;		# End
	16r4E =>	return 16rE017;		# Page Down
	16r4F =>	return 16rE015;		# Right
	16r50 =>	return 16rE014;		# Left
	16r51 =>	return 16rE013;		# Down
	16r52 =>	return 16rE012;		# Up

	#
	# Keypad, always as digits: there is no Num Lock state to keep
	# and a keypad that types numbers is what everyone reaches for.
	#
	16r54 =>	return '/';
	16r55 =>	return '*';
	16r56 =>	return '-';
	16r57 =>	return '+';
	16r58 =>	return '\n';
	16r62 =>	return '0';
	16r63 =>	return '.';
	}
	if(k >= 16r59 && k <= 16r61)		# keypad 1-9
		return k - 16r59 + '1';
	return 0;
}

#
# "ep5.0" and an endpoint number -> "ep5.1".
#
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

ctlin(rtype, req, value, index: int, data: array of byte): int
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
