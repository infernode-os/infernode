implement Bthid;

#
# bthid: a Bluetooth HID device into the pointer.
#
#	bthid [-v] addr
#
# Dials bt!addr!hid -- bt9p(4) pairs if it must, finds the HID service
# and subscribes to the device's boot-protocol input reports -- and
# turns each report into pointer movement, as os/init/mouseusb.b does
# for a USB mouse: the boot mouse report begins with the same three
# bytes, buttons then dx then dy -- the profile lets a device append
# up to five more, and a Microsoft mouse does -- and /dev/pointer
# takes "d dx dy buttons". Which kind of report is coming is what
# the conversation's status says ("Connected boot-mouse"), not a
# guess from the length. A peripheral that sleeps drops its link;
# when it wakes it advertises again, and the next dial finds it, so
# this dials again for as long as it runs. Boot keyboard reports are
# recognised and, for now, counted rather than typed: kbdusb.b's
# decoder is the shape they need, and there is no keyboard here yet.
# Report-protocol devices need their report map read, which nobody
# does yet; they are refused with a word.
#
# Mechanism/protocol as the tree draws it: bt9p speaks the radio and
# GATT; this program knows what a mouse report means and where the
# pointer is. Neither knows the other's business.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Bthid: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

# HID boot mouse report buttons and the pointer device's
Hidleft:	con 16r01;
Hidright:	con 16r02;
Hidmiddle:	con 16r04;
Mleft:		con 1;
Mmiddle:	con 2;
Mright:		con 4;

Redialms:	con 2000;	# between dials while the device is away

verbose := 0;
stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("bthid [-v] addr");
	while((c := arg->opt()) != 0)
		case c {
		'v' =>	verbose = 1;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	who := hd args;

	ptr := sys->open("/dev/pointer", Sys->OWRITE);
	if(ptr == nil){
		sys->fprint(stderr, "bthid: cannot open /dev/pointer: %r\n");
		raise "fail:pointer";
	}
	for(;;){
		(ok, conn) := sys->dial("bt!" + who + "!hid", nil);
		if(ok < 0){
			if(verbose)
				sys->fprint(stderr, "bthid: %s: %r\n", who);
			sys->sleep(Redialms);
			continue;
		}
		kind := hidkind(conn.dir);
		if(verbose)
			sys->fprint(stderr, "bthid: %s connected: %s\n", who, kind);
		case kind {
		"boot-mouse" =>
			reports(conn.dfd, ptr);
		"boot-keyboard" =>
			sys->fprint(stderr, "bthid: %s is a keyboard; its reports are not decoded yet\n", who);
			drain(conn.dfd);
		* =>
			sys->fprint(stderr, "bthid: %s sends %s reports, which need its report map; not decoded\n", who, kind);
			drain(conn.dfd);
		}
		if(verbose)
			sys->fprint(stderr, "bthid: %s gone; dialling again\n", who);
		sys->sleep(Redialms);
	}
}

# "Connected boot-mouse" and the like: the word after Connected
hidkind(dir: string): string
{
	fd := sys->open(dir + "/status", Sys->OREAD);
	if(fd == nil)
		return "?";
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "?";
	(nf, f) := sys->tokenize(string buf[0:n], " \n");
	if(nf < 2 || hd f != "Connected")
		return "?";
	return hd tl f;
}

# hold the link, for a device we cannot yet make sense of
drain(fd: ref Sys->FD)
{
	buf := array[64] of byte;
	while(sys->read(fd, buf, len buf) > 0)
		;
}

# one report per read, as bt9p hands them, until the link goes
reports(fd, ptr: ref Sys->FD)
{
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		if(n < 3)
			continue;
		b := 0;
		h := int buf[0];
		if(h & Hidleft)
			b |= Mleft;
		if(h & Hidmiddle)
			b |= Mmiddle;
		if(h & Hidright)
			b |= Mright;
		dx := signed(int buf[1]);
		dy := signed(int buf[2]);
		# "d", not "m": a mouse reports movement; where the pointer is
		# lives in the pointer device, for every source to share
		s := sys->sprint("d%d %d %d", dx, dy, b);
		if(sys->write(ptr, array of byte s, len s) < 0){
			sys->fprint(stderr, "bthid: /dev/pointer: %r\n");
			return;
		}
	}
}

signed(v: int): int
{
	if(v >= 128)
		return v - 256;
	return v;
}
