implement Init;

#
# Initial Dis program for the bare-metal AArch64 ports.
#
# Shared by os/bcm2837 and os/virt: nothing in it is board-specific,
# and having one file means a divergence between the two ports cannot
# hide in a second copy of the first program either of them runs.
#
# This is what disinit() loads and schedmod() runs -- the first Limbo
# code the kernel executes, and the point at which the machine stops
# being a C program and starts being Inferno.
#
# Deliberately smaller than upstream's geninit.b, which loads the
# keyring, binds a mouse and serial device, starts a ramfile server for
# DNS, and finally execs /dis/sh.dis. None of those exist in this
# kernel's root filesystem yet: it carries this module and nothing else,
# because every file in it is compiled into the kernel image. Adding the
# shell means adding sh.dis and everything it loads.
#
# So this does the one thing worth proving: that Dis bytecode runs, that
# it can reach the namespace the C kernel built, and that Sys calls
# cross back into the kernel correctly.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Init: module
{
	init:	fn();
};

init()
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return;

	sys->print("*** Dis is running on bare metal ***\n");

	#
	# Prove the namespace the C kernel built is reachable from Limbo.
	# fd 0/1/2 are already #c/cons, opened by disinit before we ran.
	#
	sys->print("init: reading /dev/sysname ... ");
	fd := sys->open("/dev/sysname", Sys->OREAD);
	if(fd == nil)
		sys->print("cannot open: %r\n");
	else {
		buf := array[64] of byte;
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			sys->print("empty\n");
		else
			sys->print("%q\n", string buf[0:n]);
	}

	#
	# Write through the namespace, from Limbo, to the device the C
	# kernel registered. If this line appears, the whole stack works:
	# Dis -> Sys module -> sysfile -> chan -> devcons -> UART.
	#
	sys->print("init: writing to /dev/cons ... ");
	cons := sys->open("/dev/cons", Sys->OWRITE);
	if(cons == nil)
		sys->print("cannot open: %r\n");
	else {
		msg := array of byte "hello from Limbo\n";
		if(sys->write(cons, msg, len msg) != len msg)
			sys->print("write failed: %r\n");
	}

	#
	# Exercise the allocator and the garbage collector from Limbo,
	# which is the part of the VM the C kernel's pool allocator is
	# actually underneath.
	#
	total := 0;
	for(i := 0; i < 1000; i++){
		s := array[256] of byte;
		total += len s;
	}
	sys->print("init: allocated %d bytes through the Dis heap\n", total);

	sys->print("\ninit: done\n");
}
