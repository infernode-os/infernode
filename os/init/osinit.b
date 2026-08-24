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
	# And the USB device framework on /usb. Same reason as the others:
	# '#' begins a comment in the shell, so the device name cannot be
	# typed, and a bus you cannot look at is a bus you cannot bring up.
	#
	if(sys->bind("#u", "/usb", Sys->MREPL) < 0)
		sys->print("init: cannot bind #u on /usb: %r\n");

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
	spawn usbprobe();

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

#
# Ask the USB root hub about its port.
#
# This is the first thing that drives the DWC OTG controller through
# the interface a real enumerator would use: an 8-byte setup packet
# written to the root hub's control endpoint, and the reply read back.
# devusb.c intercepts requests to the root hub and turns them into
# hp->portstatus(), so a correct answer means the whole chain works --
# #u's endpoint machinery, the Hci binding, and usbdwc's register
# access.
#
# The root hub is ep1.0, not ep0.0: devusb numbers devices from 1 and
# the hub is the first device on the bus.
#
Rd2h:		con 16r80;	# device to host
Rh2d:		con 16r00;	# host to device
Rclass:		con 16r20;	# class request
Rother:		con 3;		# recipient: other (a port)

Rgetstatus:	con 0;
Rsetfeature:	con 3;
Rgetdesc:	con 6;
Rportreset:	con 4;		# hub feature selector

Ddev:		con 1;		# descriptor type: device

HPpresent:	con 16r1;
HPenable:	con 16r2;
HPpower:	con 16r100;
HPslow:		con 16r200;
HPhigh:		con 16r400;

#
# A control request is eight bytes on the wire in every case, so one
# helper covers the whole protocol: write the setup packet, read the
# reply. The endpoint file is the transaction -- there is no ioctl, no
# submit-and-poll, and nothing to free.
#
ctlreq(d: ref Sys->FD, rtype, req, value, index, length: int, rep: array of byte): int
{
	setup := array[8] of byte;
	setup[0] = byte rtype;
	setup[1] = byte req;
	setup[2] = byte (value & 16rFF);
	setup[3] = byte ((value >> 8) & 16rFF);
	setup[4] = byte (index & 16rFF);
	setup[5] = byte ((index >> 8) & 16rFF);
	setup[6] = byte (length & 16rFF);
	setup[7] = byte ((length >> 8) & 16rFF);

	if(sys->write(d, setup, len setup) != len setup)
		return -1;

	#
	# The reply must always be collected, even when it is not wanted.
	# devusb stashes it in ep->rhrepl and rhubread refuses to answer
	# twice; leaving one behind means the NEXT request reads a stale
	# value, or falls through to the controller and blocks there.
	#
	return sys->read(d, rep, len rep);
}

portstatus(d: ref Sys->FD): int
{
	rep := array[8] of byte;

	# devusb switches on wValue, not on the request code, so wValue
	# carries the feature selector -- 0 here selects portstatus.
	if(ctlreq(d, Rd2h|Rclass|Rother, Rgetstatus, 0, 1, 4, rep) < 2)
		return -1;
	return int rep[0] | (int rep[1] << 8);
}

statusflags(status: int): string
{
	# Limbo has no conditional expression -- if is a statement.
	flags := "";
	if(status & HPpresent)
		flags += " present";
	if(status & HPenable)
		flags += " enabled";
	if(status & HPpower)
		flags += " powered";
	if(status & HPslow)
		flags += " lowspeed";
	if(status & HPhigh)
		flags += " highspeed";
	return flags;
}

#
# Speed is only meaningful after a reset: before one the port has not
# yet negotiated, so asking is guesswork. Read it rather than assume it
# -- newdev takes the speed as an argument and gets the maximum packet
# size wrong if it is told the wrong one.
#
speedname(status: int): string
{
	if(status & HPhigh)
		return "high";
	if(status & HPslow)
		return "low";
	return "full";
}

usbprobe()
{
	d := sys->open("/usb/usb/ep1.0/data", Sys->ORDWR);
	if(d == nil){
		sys->print("init: cannot open the usb root hub: %r\n");
		return;
	}

	status := portstatus(d);
	if(status < 0){
		sys->print("init: usb port status failed: %r\n");
		return;
	}
	sys->print("init: USB root hub port 1 status %#4.4x%s\n",
		status, statusflags(status));

	if((status & HPpresent) == 0){
		sys->print("init: USB bus is empty\n");
		return;
	}

	#
	# Reset the port. A device that is merely present is not yet
	# addressable: until the port is reset it has not negotiated a
	# speed and does not answer on the default address.
	#
	rep := array[8] of byte;
	if(ctlreq(d, Rh2d|Rclass|Rother, Rsetfeature, Rportreset, 1, 0, rep) < 2){
		sys->print("init: usb port reset failed: %r\n");
		return;
	}

	status = portstatus(d);
	if(status < 0){
		sys->print("init: usb port status after reset failed: %r\n");
		return;
	}
	sys->print("init: USB port 1 after reset %#4.4x%s\n",
		status, statusflags(status));

	if((status & HPenable) == 0){
		sys->print("init: USB port did not enable\n");
		return;
	}

	enumerate(speedname(status));
}

#
# Allocate a device on the bus and ask it what it is.
#
# This is the point where the port stops being a register and starts
# being a device: every transfer from here on is a real USB transaction
# carried over the wire by the DWC controller, not a request devusb
# answers on the root hub's behalf.
#
enumerate(speed: string)
{
	c := sys->open("/usb/usb/ep1.0/ctl", Sys->ORDWR);
	if(c == nil){
		sys->print("init: cannot open the root hub ctl: %r\n");
		return;
	}

	#
	# newdev allocates the endpoint and leaves its NAME to be read
	# back from the same fd -- devusb stashes it in Chan.aux. So the
	# ctl file has to be held open across both operations; opening it
	# twice would allocate a device and then lose its name.
	#
	if(sys->fprint(c, "newdev %s 1", speed) < 0){
		sys->print("init: usb newdev failed: %r\n");
		return;
	}

	#
	# pread at 0, not read. The write above advanced the fd's offset
	# past the end of the (not yet written) name, and ctlread ends in
	# readstr(offset, ...), which answers 0 for any offset past the
	# string. That looks exactly like an empty ctl file, and %r then
	# prints whatever unrelated error was last set -- here "file does
	# not exist", from an open that had succeeded minutes earlier.
	# Plan 9's usbd preads at 0 for the same reason.
	#
	nbuf := array[32] of byte;
	n := sys->pread(c, nbuf, len nbuf, big 0);
	if(n <= 0){
		sys->print("init: usb newdev gave no name (%d)\n", n);
		return;
	}
	name := string nbuf[0:n];

	sys->print("init: USB device allocated as %s at %s speed\n", name, speed);

	d := sys->open("/usb/usb/" + name + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("init: cannot open %s: %r\n", name);
		return;
	}

	#
	# GET_DESCRIPTOR(DEVICE) on the default address. The device has
	# not been given an address yet, and does not need one for this:
	# usbdwc leaves the address field zero while the device is in
	# Dconfig, which is exactly what the bus expects of a device that
	# has just been reset.
	#
	desc := array[18] of byte;
	n = ctlreq(d, Rd2h, Rgetdesc, Ddev << 8, 0, len desc, desc);
	if(n < len desc){
		sys->print("init: device descriptor read failed (%d): %r\n", n);
		return;
	}

	vendor := int desc[8] | (int desc[9] << 8);
	product := int desc[10] | (int desc[11] << 8);

	sys->print("init: USB device %#4.4x:%#4.4x class %d maxpkt %d usb %d.%d\n",
		vendor, product, int desc[4], int desc[7],
		int desc[3], int desc[2] >> 4);
}
