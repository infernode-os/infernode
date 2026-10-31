implement Isotest;

#
# Isochronous transfers, exercised: find a USB audio streaming interface
# with an isochronous OUT endpoint, select the alternate setting that
# has it, and stream silence at it for a while, timing the writes. A
# check for the host controller drivers' iso paths -- which, being paced
# by the controller's frame counter rather than by the device, are the
# one kind of transfer nothing else in this tree exercises. Under QEMU
# the device is -device usb-audio (48 kHz, 16-bit stereo: 192 bytes a
# frame); on a board it would be any USB speaker or headset.
#
# What is asserted is the PACING: a write of N frames' worth of samples
# must take N ms of real time, near enough, because the driver queues
# each frame for its own (micro)frame and waits. A driver that took the
# data and returned at once, or that dribbled it, would show as a rate
# far from what the sample rate demands. No sound comes out anywhere.
#
#	isotest [seconds [milliseconds-per-write]]
#
# A test program, not a driver: nothing starts it but the harness.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Isotest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Rh2d:		con 16r00;
Rd2h:		con 16r80;
Rstd:		con 16r00;
Rdev:		con 0;
Riface:		con 1;
Rgetdesc:	con 6;
Rsetiface:	con 11;
Dconf:		con 2;

Claudio:	con 1;
Sstreaming:	con 2;

Hz:		con 48000;
Samplesz:	con 4;		# 16-bit stereo
Framebytes:	con Hz / 1000 * Samplesz;	# 192: one millisecond

ep0: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	secs := 2;
	msperwrite := 100;
	if(tl args != nil){
		secs = int hd tl args;
		if(tl tl args != nil)
			msperwrite = int hd tl tl args;
	}
	if(secs < 1)
		secs = 1;
	if(msperwrite < 1)
		msperwrite = 1;

	dev := "";
	ifnum := -1;
	altn := -1;
	epn := -1;
	maxpkt := -1;
	for(n := 2; n < 32 && dev == ""; n++){
		name := "ep" + string n + ".0";
		fd := sys->open("/usb/usb/" + name + "/data", Sys->ORDWR);
		if(fd == nil)
			continue;		# nothing there, or a driver has it
		ep0 = fd;
		(ifnum, altn, epn, maxpkt) = findiso();
		if(epn >= 0)
			dev = name;
		else
			ep0 = nil;
	}
	if(dev == ""){
		sys->print("isotest: no USB audio streaming interface with an iso OUT endpoint\n");
		return;
	}
	sys->print("isotest: %s: interface %d altn %d, iso out ep%d maxpkt %d\n", dev, ifnum, altn, epn, maxpkt);

	if(ctlout(Rh2d|Rstd|Riface, Rsetiface, altn, ifnum) < 0){
		sys->print("isotest: SET_INTERFACE failed: %r\n");
		return;
	}

	dctl := sys->open("/usb/usb/" + dev + "/ctl", Sys->OWRITE);
	if(dctl == nil || (sys->fprint(dctl, "new %d iso w", epn) < 0 && !inuse())){
		sys->print("isotest: cannot create the iso endpoint: %r\n");
		return;
	}
	epname := dev[0:len dev - 1] + string epn;
	ectl := sys->open("/usb/usb/" + epname + "/ctl", Sys->OWRITE);
	if(ectl == nil){
		sys->print("isotest: cannot open %s ctl: %r\n", epname);
		return;
	}
	# pollival 1 is every frame (2^0): the interval this device declares
	for(l := list of {"pollival 1", "samplesz " + string Samplesz, "hz " + string Hz, "ntds 1"}; l != nil; l = tl l)
		if(sys->fprint(ectl, "%s", hd l) < 0){
			sys->print("isotest: %s: '%s' refused: %r\n", epname, hd l);
			return;
		}
	data := sys->open("/usb/usb/" + epname + "/data", Sys->OWRITE);
	if(data == nil){
		sys->print("isotest: cannot open %s data: %r\n", epname);
		return;
	}

	#
	# A tenth of a second a write, unless told otherwise. The driver
	# returns from a write when all but the last few frames of it have
	# been sent, so a write's length is the stream's latency.
	#
	chunk := array[Framebytes * msperwrite] of { * => byte 0 };
	total := 0;
	errs := 0;
	t0 := sys->millisec();
	while(sys->millisec() - t0 < secs * 1000){
		n := sys->write(data, chunk, len chunk);
		if(n != len chunk){
			if(++errs > 5){
				sys->print("isotest: write failed: %r\n");
				break;
			}
			continue;
		}
		total += n;
	}
	ms := sys->millisec() - t0;
	if(ms <= 0)
		ms = 1;
	rate := total / ms;
	verdict := "PACED";
	if(rate < Framebytes * 85 / 100 || rate > Framebytes * 115 / 100)
		verdict = "NOT PACED";
	sys->print("isotest: %s: wrote %d bytes in %d ms = %d bytes/ms (%d expected at %d Hz): %s, %d errors\n",
		epname, total, ms, rate, Framebytes, Hz, verdict, errs);
}

#
# The configuration descriptor, walked for an audio streaming interface
# whose alternate setting has an isochronous OUT endpoint. Returns
# (interface, alternate, endpoint, maxpkt), or an endpoint of -1.
#
findiso(): (int, int, int, int)
{
	hdr := array[9] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Dconf << 8, 0, hdr) < len hdr)
		return (-1, -1, -1, -1);
	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 1024)
		return (-1, -1, -1, -1);
	cfg := array[total] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Dconf << 8, 0, cfg) < total)
		return (-1, -1, -1, -1);
	ifnum := -1;
	altn := -1;
	streaming := 0;
	for(i := 0; i + 2 <= total; ){
		dlen := int cfg[i];
		if(dlen < 2)
			break;
		case int cfg[i+1] {
		4 =>
			if(i + 9 <= total){
				ifnum = int cfg[i+2];
				altn = int cfg[i+3];
				streaming = int cfg[i+5] == Claudio && int cfg[i+6] == Sstreaming;
			}
		5 =>
			if(streaming && i + 7 <= total){
				addr := int cfg[i+2];
				if((addr & 16r80) == 0 && (int cfg[i+3] & 3) == 1)
					return (ifnum, altn, addr & 16rF, int cfg[i+4] | (int cfg[i+5] << 8));
			}
		}
		i += dlen;
	}
	return (-1, -1, -1, -1);
}

inuse(): int
{
	e := sys->sprint("%r");
	for(i := 0; i + 6 <= len e; i++)
		if(e[i:i+6] == "in use")
			return 1;
	return 0;
}

ctlin(rtype, req, value, index: int, data: array of byte): int
{
	setup := array[8] of byte;
	setup[0] = byte rtype;
	setup[1] = byte req;
	setup[2] = byte (value & 16rFF);
	setup[3] = byte ((value >> 8) & 16rFF);
	setup[4] = byte (index & 16rFF);
	setup[5] = byte ((index >> 8) & 16rFF);
	setup[6] = byte (len data & 16rFF);
	setup[7] = byte ((len data >> 8) & 16rFF);
	if(sys->write(ep0, setup, len setup) != len setup)
		return -1;
	return sys->read(ep0, data, len data);
}

ctlout(rtype, req, value, index: int): int
{
	buf := array[8] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	buf[2] = byte (value & 16rFF);
	buf[3] = byte ((value >> 8) & 16rFF);
	buf[4] = byte (index & 16rFF);
	buf[5] = byte ((index >> 8) & 16rFF);
	buf[6] = byte 0;
	buf[7] = byte 0;
	if(sys->write(ep0, buf, len buf) != len buf)
		return -1;
	rep := array[8] of byte;
	sys->read(ep0, rep, len rep);	# collect the empty reply; devusb parks it otherwise
	return 0;
}
