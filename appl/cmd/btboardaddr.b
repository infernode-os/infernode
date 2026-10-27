implement Btboardaddr;

#
# btboardaddr - give a Raspberry Pi 3's Bluetooth controller the board's
# own address, when it has none of its own
#
# A 3B+'s CYW43455 has no address in OTP: after BCM4345C0.hcd is
# uploaded it reports the patch's default, 43:45:c0:00:1f:ac, and so
# does every other 3B+. Two boards would be one device to everything
# they pair with. Raspberry Pi OS gives the controller an address made
# from the board's serial number (pi-bluetooth's btuart): b8:27:eb and
# the serial's low three bytes, each XORed with 0xaa. This does the
# same, through bt9p's "bdaddr" verb, and only when the controller is
# at the patch's default: a 4B's controller reports its own address,
# and one already given an address is left alone.
#
# The serial is the firmware's, from the command line it hands the
# kernel (bcm2709.serial=0x<hex>), read from /dev/bootargs.
#
# Usage:
#   btboardaddr [-m mnt] [-b bootargs]
#     -m   where bt9p is mounted (default /net/bt)
#     -b   the file holding the command line (default /dev/bootargs)
#
# Prints the address the controller has after, or why it was left.
# os/init/osinit.b runs it after a card's bt file, unless that file
# names a bdaddr of its own. Exit status: nil (the address is the
# board's, or was not the default), "no serial" or "bdaddr failed".
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Btboardaddr: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Patchaddr: con "43:45:c0:00:1f:ac";
Serialpfx: con "bcm2709.serial=0x";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	mnt := "/net/bt";
	bootargs := "/dev/bootargs";
	arg->init(argv);
	arg->setusage("btboardaddr [-m mnt] [-b bootargs]");
	while((c := arg->opt()) != 0)
		case c {
		'm' =>	mnt = arg->earg();
		'b' =>	bootargs = arg->earg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	addr := readline(mnt + "/addr");
	if(addr == nil){
		sys->print("btboardaddr: the controller has no address yet (no \"up\"); left alone\n");
		return;
	}
	if(addr != Patchaddr){
		sys->print("btboardaddr: %s is the controller's own; left alone\n", addr);
		return;
	}
	want := boardaddr(readline(bootargs));
	if(want == nil){
		sys->fprint(sys->fildes(2), "btboardaddr: the controller is at the patch's default, %s, and %s has no %s<hex> to make the board's from\n", Patchaddr, bootargs, Serialpfx);
		raise "fail:no serial";
	}
	fd := sys->open(mnt + "/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "bdaddr %s", want) < 0){
		sys->fprint(sys->fildes(2), "btboardaddr: bdaddr %s: %r\n", want);
		raise "fail:bdaddr failed";
	}
	sys->print("btboardaddr: %s, from the board's serial (was the patch's default)\n", readline(mnt + "/addr"));
}

#
# The address from the command line's serial: b8:27:eb and its low three
# bytes, each ^ 0xaa. nil if there is no serial with six hex digits.
#
boardaddr(cmdline: string): string
{
	(nil, words) := sys->tokenize(cmdline, " \t\r\n");
	for(; words != nil; words = tl words){
		w := hd words;
		if(len w < len Serialpfx + 6 || w[0:len Serialpfx] != Serialpfx)
			continue;
		hex := w[len w - 6:];
		s := "b8:27:eb";
		for(k := 0; k < 6; k += 2){
			v := hexbyte(hex[k:k+2]);
			if(v < 0)
				return nil;
			s += sys->sprint(":%.2x", v ^ 16raa);
		}
		return s;
	}
	return nil;
}

hexbyte(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'0' to '9' =>	v = v*16 + c - '0';
		'a' to 'f' =>	v = v*16 + c - 'a' + 10;
		'A' to 'F' =>	v = v*16 + c - 'A' + 10;
		* =>	return -1;
		}
	}
	return v;
}

readline(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[1100] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == '\r'))
		s = s[0:len s-1];
	return s;
}
