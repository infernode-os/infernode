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

include "sh.m";

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

	#
	# A fixed arithmetic loop, timed. Reported so the harness can run
	# the same kernel with the JIT on and off and compare -- which is
	# the only comparison that means anything, since everything else
	# about the two images is identical.
	#
	# Deliberately integer-only and allocation-free: this measures the
	# code the JIT generates, not the allocator or the garbage
	# collector.
	#
	t0 := sys->millisec();
	acc := 0;
	for(k := 0; k < 2000000; k++)
		acc += (k*3) ^ (k>>2);
	t1 := sys->millisec();
	sys->print("bench: %d iterations in %d ms (acc=%d)\n", 2000000, t1-t0, acc);

	#
	# Put the IP stack where Inferno expects it.
	#
	# #I is the device; /net is the conventional path, and everything
	# that speaks to the network -- including the shell -- looks there
	# rather than at the device name. It also makes the stack
	# reachable by typing: in the shell a bare '#' begins a comment,
	# so '#I/ipifc' cannot be written without quoting it.
	#
	if(sys->bind("#I", "/net", Sys->MREPL) < 0)
		sys->print("init: cannot bind #I on /net: %r\n");

	#
	# Bring up loopback.
	#
	# This is the first thing that exercises the stack rather than
	# merely linking it: cloning an interface, binding a medium to it,
	# and assigning an address all run real code, and the address
	# assignment is what inserts a route -- the v4addroute path whose
	# end-address arithmetic was wrong under LP64 until it was fixed.
	#
	# Loopback needs no hardware, which is the point. This board has
	# no usable network device until USB enumeration exists, so
	# loopback is the only way to exercise the stack at all.
	#
	ifc := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(ifc == nil)
		sys->print("init: cannot clone an interface: %r\n");
	else {
		nbuf := array[32] of byte;
		n := sys->read(ifc, nbuf, len nbuf);
		if(n <= 0)
			sys->print("init: cloned interface has no number: %r\n");
		else {
			ifcno := string nbuf[0:n];
			sys->print("init: ipifc %s cloned\n", ifcno);

			# The medium first: an address cannot be assigned to
			# an interface that is not bound to anything.
			if(sys->fprint(ifc, "bind loopback") < 0)
				sys->print("init: bind loopback failed: %r\n");
			else if(sys->fprint(ifc, "add 127.0.0.1 255.0.0.0") < 0)
				sys->print("init: add 127.0.0.1 failed: %r\n");
			else
				sys->print("init: 127.0.0.1/8 configured on ipifc %s\n", ifcno);
		}
	}

	sys->print("\ninit: starting the shell\n\n");

	#
	# Hand over to /dis/sh.dis.
	#
	# Inferno has no exec(2): a command IS a Dis module, so running the
	# shell means loading it and calling its init(). It never returns
	# while the shell is running.
	#
	# sh's own initialise() loads Filepat, String, Bufio, Env and Arg
	# and calls badmodule() -- which is fatal -- on any that are
	# missing, so all five have to be in the kernel's root filesystem
	# alongside sh.dis itself.
	#
	sh := load Command Command->PATH;
	if(sh == nil){
		sys->print("init: cannot load %s: %r\n", Command->PATH);
		return;
	}

	sh->init(nil, "sh" :: nil);

	sys->print("init: the shell returned\n");
}
