implement Mouseusb;

#
# A USB boot-protocol mouse, as a program.
#
# Same reasoning as kbdusb and etherusb: the kernel provides the
# mechanism -- raw endpoints through #u and a pointer through #m -- and
# what to say to a particular class of device is policy, which belongs
# outside it.
#
# BOOT protocol, so the report is a fixed three bytes and no report
# descriptor has to be parsed: buttons, then dx, then dy. Some mice add
# a fourth byte for the wheel; it is read when the endpoint offers it
# and ignored otherwise, because there is nothing to scroll yet.
#

include "sys.m";
	sys: Sys;

include "draw.m";

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

Dconf:		con 2;

Bootproto:	con 0;		# SET_PROTOCOL: 0 is boot, 1 is report

Reportlen:	con 3;		# buttons, dx, dy
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
	ep0 = sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
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

	#
	# Boot protocol, so the three bytes below mean what they say. A
	# mouse left in report protocol sends whatever its report
	# descriptor describes, which this cannot decode.
	#
	if(ctlout(Rh2d|Rclass|Riface, Rsetproto, Bootproto, 0) < 0)
		sys->print("mouseusb: SET_PROTOCOL(boot) failed: %r\n");

	#
	# Idle 0: report only when something changes. Without it a mouse
	# repeats its current state for ever and the pointer is woken
	# constantly to be told it has not moved.
	#
	if(ctlout(Rh2d|Rclass|Riface, Rsetidle, 0, 0) < 0)
		sys->print("mouseusb: SET_IDLE failed: %r\n");

	fd := openintr(epnum, maxpkt, ival);
	if(fd == nil)
		return;

	ptr := sys->open("/dev/pointer", Sys->OWRITE);
	if(ptr == nil){
		sys->print("mouseusb: cannot open /dev/pointer: %r\n");
		return;
	}

	sys->print("mouseusb: %s ready on endpoint %d maxpkt %d ival %d\n",
		dev, epnum, maxpkt, ival);

	poll(fd, ptr, ival, maxpkt);
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
			if(++nerr >= Maxerr){
				sys->print("mouseusb: %s stopped responding; unplugged?\n", dev);
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
