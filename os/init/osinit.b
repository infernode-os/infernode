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
	# And the process device on /prog. sh reaches it as #p directly
	# for its wait file, so nothing has needed the conventional path
	# until now -- but a system you cannot list the processes of is
	# one you cannot diagnose, and that is exactly what #p is for.
	#
	if(sys->bind("#p", "/prog", Sys->MREPL) < 0)
		sys->print("init: cannot bind #p on /prog: %r\n");

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

	#
	# Send a packet.
	#
	# Everything above proves the stack is present and configured.
	# This proves it MOVES DATA: an ICMP echo request goes out through
	# ipoput4, across the loopback medium, back in through ipiput4, is
	# recognised by icmp.c, answered, and delivered back to this
	# conversation. Checksums, the route lookup, the interface's self
	# addresses and the protocol demultiplexer are all on that path,
	# and none of them can be verified by reading a stats file.
	#
	# The write is 20 bytes of IP header the stack fills in itself,
	# then the ICMP header at offset 20 -- that layout is icmpkick's
	# contract, not a convention: it requires at least
	# ICMP_IPSIZE + ICMP_HDRSIZE and overwrites the addresses,
	# protocol, id and checksum.
	#
	#
	# In its own thread: if it blocks, the shell still comes up and
	# the machine stays inspectable. A diagnostic that takes the
	# system down with it cannot be used to diagnose anything.
	#
	spawn pingit();
	spawn tcpecho();

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

Echoreq:	con 8;		# ICMP type: echo request
Echoreply:	con 0;		# ICMP type: echo reply
Ipsize:		con 20;		# icmp.c ICMP_IPSIZE
Hdrsize:	con 8;		# icmp.c ICMP_HDRSIZE

pingit()
{
	c := sys->open("/net/icmp/clone", Sys->ORDWR);
	if(c == nil){
		sys->print("init: cannot clone an icmp conversation: %r\n");
		return;
	}

	nbuf := array[32] of byte;
	n := sys->read(c, nbuf, len nbuf);
	if(n <= 0){
		sys->print("init: icmp clone gave no number: %r\n");
		return;
	}
	conv := string nbuf[0:n];

	#
	# The "!1" is not a port ICMP has any use for -- it has none. The
	# generic connect parser in devip.c requires an addr!port pair and
	# rejects a bare address as "malformed address", so every protocol
	# has to supply one whether it means anything or not.
	#
	if(sys->fprint(c, "connect 127.0.0.1!1") < 0){
		sys->print("init: icmp connect failed: %r\n");
		return;
	}

	d := sys->open("/net/icmp/" + conv + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("init: cannot open icmp data: %r\n");
		return;
	}

	req := array[Ipsize + Hdrsize + 8] of byte;
	for(i := 0; i < len req; i++)
		req[i] = byte 0;
	req[Ipsize] = byte Echoreq;		# type
	req[Ipsize + 1] = byte 0;		# code
	req[Ipsize + 6] = byte 0;		# sequence, high
	req[Ipsize + 7] = byte 1;		# sequence, low

	if(sys->write(d, req, len req) != len req){
		sys->print("init: icmp write failed: %r\n");
		return;
	}

	rep := array[256] of byte;
	n = sys->read(d, rep, len rep);
	if(n < Ipsize + Hdrsize){
		sys->print("init: no echo reply (read %d): %r\n", n);
		return;
	}

	if(int rep[Ipsize] == Echoreply)
		sys->print("init: ICMP echo reply from 127.0.0.1 (%d bytes)\n", n);
	else
		sys->print("init: unexpected ICMP type %d\n", int rep[Ipsize]);
}

#
# A TCP connection to ourselves over loopback.
#
# ICMP proves the stack moves packets. TCP proves it does the hard
# part: a three-way handshake, sequence numbers advancing on both
# sides, windows, and an ordered byte stream in each direction. It is
# also the direct exercise of the arithmetic that was wrong under LP64
# -- every segment compares sequence numbers through seq_lt and
# friends, and the connection simply stalls if they answer wrongly.
#
# The listener has to be a separate thread because opening the listen
# file blocks until somebody connects.
#
Tcpport:	con "9999";

tcpecho()
{
	sync := chan of int;

	spawn tcplistener(sync);
	if(<-sync != 1){
		sys->print("init: tcp listener failed to announce\n");
		return;
	}

	c := sys->open("/net/tcp/clone", Sys->ORDWR);
	if(c == nil){
		sys->print("init: cannot clone a tcp conversation: %r\n");
		return;
	}
	nbuf := array[32] of byte;
	n := sys->read(c, nbuf, len nbuf);
	if(n <= 0){
		sys->print("init: tcp clone gave no number: %r\n");
		return;
	}
	conv := string nbuf[0:n];

	if(sys->fprint(c, "connect 127.0.0.1!" + Tcpport) < 0){
		sys->print("init: tcp connect failed: %r\n");
		return;
	}

	d := sys->open("/net/tcp/" + conv + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("init: cannot open tcp data: %r\n");
		return;
	}

	msg := array of byte "hello-tcp";
	if(sys->write(d, msg, len msg) != len msg){
		sys->print("init: tcp write failed: %r\n");
		return;
	}

	rbuf := array[64] of byte;
	rn := sys->read(d, rbuf, len rbuf);
	if(rn <= 0){
		sys->print("init: tcp read failed: %r\n");
		return;
	}

	sys->print("init: TCP echo over loopback returned %q\n",
		string rbuf[0:rn]);
}

tcplistener(sync: chan of int)
{
	a := sys->open("/net/tcp/clone", Sys->ORDWR);
	if(a == nil){
		sync <-= 0;
		return;
	}
	nbuf := array[32] of byte;
	n := sys->read(a, nbuf, len nbuf);
	if(n <= 0){
		sync <-= 0;
		return;
	}
	conv := string nbuf[0:n];

	if(sys->fprint(a, "announce " + Tcpport) < 0){
		sync <-= 0;
		return;
	}
	sync <-= 1;

	# Blocks until the other side connects; returns the NEW
	# conversation carrying the accepted connection.
	l := sys->open("/net/tcp/" + conv + "/listen", Sys->ORDWR);
	if(l == nil)
		return;
	ln := sys->read(l, nbuf, len nbuf);
	if(ln <= 0)
		return;
	nconv := string nbuf[0:ln];

	d := sys->open("/net/tcp/" + nconv + "/data", Sys->ORDWR);
	if(d == nil)
		return;

	buf := array[64] of byte;
	rn := sys->read(d, buf, len buf);
	if(rn > 0)
		sys->write(d, buf[0:rn], rn);
}
