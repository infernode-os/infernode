implement Kbdusb;

#
# A USB boot-protocol keyboard, as a program.
#
# Same reasoning as etherusb: the kernel provides the mechanism -- raw
# endpoints through #u -- and what to say to a particular class of device
# is policy, which belongs outside it. See "Decision: device protocols
# live outside the kernel, mechanism inside" in os/bcm2837/README.md.
#
# BOOT protocol, not report protocol. A HID device describes its reports
# in a report descriptor, and parsing those is a real piece of work; the
# boot protocol exists precisely so that a machine which has just started
# can read a keyboard without doing any of it. The report is eight fixed
# bytes: modifiers, a reserved byte, and up to six keycodes held down.
# That is enough to type, which is what is wanted here.
#

include "sys.m";
	sys: Sys;

include "draw.m";

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

Reportlen:	con 8;		# the boot keyboard report

#
# Modifier bits in byte 0 of the report.
#
Mlshift:	con 16r02;
Mrshift:	con 16r20;
Mlctrl:		con 16r01;
Mrctrl:		con 16r10;

dev: string;
ctlfd: ref Sys->FD;	# the device's ctl file
ep0: ref Sys->FD;	# its control endpoint's data file, held open

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
	ep0 = sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
	if(ep0 == nil){
		sys->print("kbdusb: cannot open %s data: %r\n", dev);
		return;
	}

	(epnum, maxpkt, ival) := intrendpoint();
	if(epnum < 0){
		sys->print("kbdusb: %s has no interrupt endpoint\n", dev);
		return;
	}

	#
	# Ask for the boot protocol before reading anything. A keyboard
	# left in report protocol sends whatever its report descriptor
	# describes, which is not the eight bytes below and is not
	# something this can decode.
	#
	if(ctlout(Rh2d|Rclass|Riface, Rsetproto, Bootproto, 0) < 0)
		sys->print("kbdusb: SET_PROTOCOL(boot) failed: %r\n");

	#
	# Idle 0: report only when something changes. Without it the
	# keyboard repeats the current state forever and every read
	# returns the same keys held down, which reads as a stuck key.
	#
	if(ctlout(Rh2d|Rclass|Riface, Rsetidle, 0, 0) < 0)
		sys->print("kbdusb: SET_IDLE failed: %r\n");

	fd := openintr(epnum, maxpkt, ival);
	if(fd == nil)
		return;

	kbd := sys->open("/dev/keyboard", Sys->OWRITE);
	if(kbd == nil){
		sys->print("kbdusb: cannot open /dev/keyboard: %r\n");
		return;
	}

	sys->print("kbdusb: %s ready on endpoint %d maxpkt %d ival %d\n",
		dev, epnum, maxpkt, ival);

	#
	# Prove the injection path before blaming the keyboard.
	#
	# Nothing appears when keys are pressed, and that has two quite
	# different causes: reports are not arriving from the device, or
	# they are and the characters are not reaching the console. This
	# writes one character that no key produced, so if a stray 'K'
	# turns up at the shell the second half works and the fault is
	# upstream of it.
	#
	tst := array of byte "K";
	if(sys->write(kbd, tst, len tst) != len tst)
		sys->print("kbdusb: cannot write /dev/keyboard: %r\n");
	else
		sys->print("kbdusb: wrote a test K to /dev/keyboard\n");

	poll(fd, kbd, ival);
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
	buf := array[64] of byte;
	prev := array[Reportlen] of byte;
	for(i := 0; i < len prev; i++)
		prev[i] = byte 0;

	nempty := 0;
	nslow := 0;
	for(;;){
		#
		# Time the read.
		#
		# Latency is still tens of seconds after bounding the split
		# retry, and the arithmetic does not account for it: a poll
		# should cost at most a second or so. Guessing at where the
		# rest goes has been wrong twice, so measure it -- a read
		# that takes seconds and a read that is called seconds apart
		# are different faults.
		#
		t0 := sys->millisec();
		n := sys->read(fd, buf, len buf);
		dt := sys->millisec() - t0;
		if(dt > 250 && nslow < 8){
			nslow++;
			sys->print("kbdusb: read took %d ms (returned %d)\n", dt, n);
		}
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

		mod := int buf[0];
		for(i = 2; i < Reportlen; i++){
			k := int buf[i];
			if(k == 0)
				continue;
			if(held(prev, k))
				continue;
			c := decode(k, mod);
			if(c > 0){
				s := sys->sprint("%c", c);
				sys->write(kbd, array of byte s, len array of byte s);
			}
		}
		prev[0:] = buf[0:Reportlen];
	}
}

held(prev: array of byte, k: int): int
{
	for(i := 2; i < Reportlen; i++)
		if(int prev[i] == k)
			return 1;
	return 0;
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
	}
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
