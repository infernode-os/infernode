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
	# MBEFORE, not MREPL. devip's files must come first, but the
	# directory underneath carries /net/ether0 -- the mount point the
	# USB Ethernet driver publishes itself on -- and MREPL would hide
	# it, leaving the driver with nowhere to appear.
	if(sys->bind("#I", "/net", Sys->MBEFORE) < 0)
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
	# And the environment on /env.
	#
	# Inferno has no environ array: a variable IS a file, and
	# inheritance is a namespace operation rather than a copy. Until
	# #e was imported this kernel had noenv.c -- whose own header
	# said "use this when devenv.c not used" -- so a Limbo program
	# could not read or set a variable at all.
	#
	# MCREATE as well as MREPL: setting a variable CREATES a file, so
	# a mount point that forbids creation makes the environment
	# readable and not writable -- "mounted directory forbids
	# creation" from the shell, on what looks like an ordinary
	# assignment.
	if(sys->bind("#e", "/env", Sys->MREPL|Sys->MCREATE) < 0)
		sys->print("init: cannot bind #e on /env: %r\n");

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
Rsetaddress:	con 5;
Rsetconfig:	con 9;
Rgetdesc:	con 6;

#
# Hub feature selectors. The root hub understands only the first two,
# because devusb answers for it and switches on wValue rather than on
# the request code. A REAL hub is a device like any other: the request
# code matters, and it also has to be told to turn its ports on.
#
Fportenable:	con 1;
Fportreset:	con 4;
Fportpower:	con 8;

Ddev:		con 1;		# descriptor type: device
Dconf:		con 2;		# descriptor type: configuration
Dhub:		con 16r29;	# descriptor type: hub
Clhub:		con 9;		# device class: hub
Clcomm:		con 2;		# device class: communications

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

#
# GET_STATUS on a hub port. wValue is 0 for a real hub because the
# standard says so, and 0 for the root hub because devusb switches on
# wValue and 0 is what selects portstatus there -- so one shape serves
# both.
#
portstatus(d: ref Sys->FD, port: int): int
{
	rep := array[4] of byte;

	if(ctlreq(d, Rd2h|Rclass|Rother, Rgetstatus, 0, port, len rep, rep) < len rep)
		return -1;
	return int rep[0] | (int rep[1] << 8);
}

#
# SET_FEATURE on a hub port, with no data stage. The read still has to
# happen: for the root hub devusb parks the reply in ep->rhrepl and
# refuses to answer twice, so an uncollected one is handed to the NEXT
# request instead.
#
portfeature(d: ref Sys->FD, port, feature: int): int
{
	rep := array[4] of byte;

	return ctlreq(d, Rh2d|Rclass|Rother, Rsetfeature, feature, port, 0, rep);
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

	status := portstatus(d, 1);
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
	if(portfeature(d, 1, Fportreset) < 0){
		sys->print("init: usb port reset failed: %r\n");
		return;
	}

	status = portstatus(d, 1);
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

	enumerate("/usb/usb/ep1.0/ctl", 1, speedname(status), "");
}

#
# Bring one device up on a port of some hub, and if it turns out to be
# a hub itself, walk it too.
#
# hubctl is the ctl file of the hub the device hangs off -- the root
# hub's for the first call, a real hub's for the recursive ones. depth
# is only used to indent the report.
#
enumerate(hubctl: string, port: int, speed, indent: string)
{
	c := sys->open(hubctl, Sys->ORDWR);
	if(c == nil){
		sys->print("init: cannot open %s: %r\n", hubctl);
		return;
	}

	#
	# newdev allocates the endpoint and leaves its NAME to be read
	# back from the same fd -- devusb stashes it in Chan.aux. So the
	# ctl file has to be held open across both operations; opening it
	# twice would allocate a device and then lose its name.
	#
	if(sys->fprint(c, "newdev %s %d", speed, port) < 0){
		sys->print("init: usb newdev failed: %r\n");
		return;
	}

	#
	# pread at 0, not read. The write above advanced the fd's offset
	# past the end of the (not yet written) name, and ctlread ends in
	# readstr(offset, ...), which answers 0 for any offset past the
	# string. That looks exactly like an empty ctl file, and %r then
	# prints whatever unrelated error was last set. Plan 9's usbd
	# preads at 0 for the same reason.
	#
	nbuf := array[32] of byte;
	n := sys->pread(c, nbuf, len nbuf, big 0);
	if(n <= 0){
		sys->print("init: usb newdev gave no name (%d)\n", n);
		return;
	}
	name := string nbuf[0:n];

	d := sys->open("/usb/usb/" + name + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("init: cannot open %s: %r\n", name);
		return;
	}

	#
	# GET_DESCRIPTOR(DEVICE) on the default address. The device has
	# not been given an address yet and does not need one for this:
	# usbdwc leaves the address field zero while the device is in
	# Dconfig, which is what the bus expects of a device that has just
	# been reset.
	#
	#
	# Retried, because the first attempt is also how the driver
	# discovers which DMA address form this controller understands:
	# it flips after a timeout, and the retry is what tests the
	# other one. A device that answers on the second attempt has
	# told us something the first attempt could not.
	#
	desc := array[18] of byte;
	for(try := 0; try < 3; try++){
		n = ctlreq(d, Rd2h, Rgetdesc, Ddev << 8, 0, len desc, desc);
		if(n >= len desc)
			break;
		sys->print("init: device descriptor read failed (%d): %r\n", n);
	}
	if(n < len desc)
		return;
	if(try > 0)
		sys->print("init: descriptor read succeeded on attempt %d\n", try+1);

	vendor := int desc[8] | (int desc[9] << 8);
	product := int desc[10] | (int desc[11] << 8);
	class := int desc[4];
	maxpkt := int desc[7];

	what := "";
	if(class == Clhub)
		what = " (hub)";

	sys->print("init: %sUSB %s %#4.4x:%#4.4x class %d%s maxpkt %d usb %d.%d\n",
		indent, name, vendor, product, class, what, maxpkt,
		int desc[3], int desc[2] >> 4);

	#
	# Now give it an address. Two steps that must happen in this
	# order: the request goes out on the wire while the device is
	# still answering on address 0, and only then is the kernel told,
	# because that is what makes usbdwc start putting the address in
	# the channel register.
	#
	# maxpkt first. devusb assumes 64 for anything not low speed, and
	# this device says 8; a control transfer split into the wrong
	# packet size is a bus error rather than a short read.
	#
	dctl := sys->open("/usb/usb/" + name + "/ctl", Sys->ORDWR);
	if(dctl == nil){
		sys->print("init: cannot open %s ctl: %r\n", name);
		return;
	}
	sys->fprint(dctl, "maxpkt %d", maxpkt);

	nb := devnum(name);
	rep := array[4] of byte;
	if(ctlreq(d, Rh2d, Rsetaddress, nb, 0, 0, rep) < 0){
		sys->print("init: %s set address %d failed: %r\n", name, nb);
		return;
	}
	sys->fprint(dctl, "address");

	#
	# SET_CONFIGURATION, which was missing entirely.
	#
	# SET_ADDRESS leaves the device in the Address state, where the
	# spec requires it to answer standard requests and nothing else.
	# Class-specific requests -- which is all of the hub port status
	# and port feature traffic below -- are only defined once the
	# device is Configured.
	#
	# QEMU's hub answered them anyway, so the bus walk worked in
	# emulation and the omission was invisible. The 3B+'s USB2514
	# follows the spec: every one of its four ports read back 0x0000,
	# with not even PORT_POWER set, and the SET_FEATURE that was meant
	# to turn that power on reported no error because the hub is
	# entitled to ignore it in that state.
	#
	if(configure(name, d, indent) < 0)
		return;

	if(class == Clhub){
		hubwalk(name, d, dctl, indent + "  ");
		return;
	}

	dumpconfig(d, indent + "  ");

	#
	# Hand it to a class driver, which is a program. The bus walk's
	# job ends at "there is a device of this class at this endpoint";
	# what to say to it is not the kernel's business.
	#
	if(class == Clcomm)
		startdriver("/dis/etherusb.dis", name);
}

#
# Load a class driver and let it run in its own process.
#
# A command in Inferno is a Dis module -- there is no exec(2) -- so
# starting one means loading it and calling init(). It is spawned
# rather than called so that a driver which blocks waiting for its
# device does not stop the rest of the bus walk.
#
startdriver(path, name: string)
{
	drv := load Command path;
	if(drv == nil){
		sys->print("init: cannot load %s: %r\n", path);
		return;
	}
	spawn drv->init(nil, "etherusb" :: name :: nil);
}

#
# Read the configuration descriptor and report what the device offers.
#
# A device descriptor says what the device IS; the configuration
# descriptor says what it can DO -- which interfaces it has, and which
# endpoints each one needs. That is what a class driver has to read
# before it can open anything, because endpoint numbers are the
# device's choice, not a convention.
#
# It arrives as a run of variable-length descriptors packed end to end,
# each "length, type, ...", so it is walked rather than indexed.
#
#
# Read the configuration descriptor for its bConfigurationValue and
# select it. Returns -1 if the device cannot be configured, in which
# case nothing class-specific will work and there is no point going on.
#
configure(name: string, d: ref Sys->FD, indent: string): int
{
	hdr := array[9] of byte;
	rep := array[4] of byte;

	n := ctlreq(d, Rd2h, Rgetdesc, Dconf << 8, 0, len hdr, hdr);
	if(n < len hdr){
		sys->print("init: %s%s config descriptor failed (%d): %r\n",
			indent, name, n);
		return -1;
	}

	# byte 5 is bConfigurationValue; 0 would mean "unconfigured"
	cfgval := int hdr[5];
	if(cfgval == 0){
		sys->print("init: %s%s offers no configuration to select\n",
			indent, name);
		return -1;
	}

	if(ctlreq(d, Rh2d, Rsetconfig, cfgval, 0, 0, rep) < 0){
		sys->print("init: %s%s set configuration %d failed: %r\n",
			indent, name, cfgval);
		return -1;
	}
	sys->print("init: %s%s configured (value %d)\n", indent, name, cfgval);
	return 0;
}

dumpconfig(d: ref Sys->FD, indent: string)
{
	# The first nine bytes are enough to learn the total length.
	hdr := array[9] of byte;
	n := ctlreq(d, Rd2h, Rgetdesc, Dconf << 8, 0, len hdr, hdr);
	if(n < len hdr){
		sys->print("init: %sconfig descriptor header failed (%d)\n",
			indent, n);
		return;
	}

	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 512){
		sys->print("init: %sconfig descriptor length %d unreasonable\n",
			indent, total);
		return;
	}

	cfg := array[total] of byte;
	n = ctlreq(d, Rd2h, Rgetdesc, Dconf << 8, 0, total, cfg);
	if(n < total){
		sys->print("init: %sconfig descriptor short (%d of %d)\n",
			indent, n, total);
		return;
	}

	sys->print("init: %sconfig: %d interface(s), %d bytes, value %d\n",
		indent, int cfg[4], total, int cfg[5]);

	for(i := 0; i + 2 <= total; ){
		dlen := int cfg[i];
		dtype := int cfg[i+1];
		if(dlen < 2)
			break;

		case dtype {
		4 =>	# interface
			if(i + 9 <= total)
				sys->print("init: %s  if %d alt %d: class %d.%d.%d, %d endpoint(s)\n",
					indent, int cfg[i+2], int cfg[i+3],
					int cfg[i+5], int cfg[i+6], int cfg[i+7],
					int cfg[i+4]);
		5 =>	# endpoint
			if(i + 7 <= total){
				addr := int cfg[i+2];
				attr := int cfg[i+3];
				mx := int cfg[i+4] | (int cfg[i+5] << 8);
				dir := "out";
				if(addr & 16r80)
					dir = "in";
				sys->print("init: %s    ep%d %s %s maxpkt %d\n",
					indent, addr & 16rF, dir,
					eptype(attr & 3), mx);
			}
		* =>
			;
		}
		i += dlen;
	}
}

eptype(t: int): string
{
	case t {
	0 =>	return "control";
	1 =>	return "iso";
	2 =>	return "bulk";
	3 =>	return "interrupt";
	}
	return "?";
}


#
# Walk a real hub: read how many ports it has, power them, and
# enumerate whatever is plugged into each.
#
# Nothing here is intercepted by the kernel. Every one of these is a
# control transfer to a device on the wire, which is the difference
# between this and the root hub -- there the request code was ignored
# and only wValue mattered.
#
hubwalk(name: string, d, dctl: ref Sys->FD, indent: string)
{
	#
	# devusb refuses newdev on anything that has not been declared a
	# hub, because a hub is the only kind of device that can have
	# something behind it.
	#
	sys->fprint(dctl, "hub");

	# Not "hd": that is the list-head operator, and using it as a
	# variable makes the parser reject every later line that touches
	# it rather than the declaration itself.
	hubd := array[8] of byte;
	n := ctlreq(d, Rd2h|Rclass, Rgetdesc, Dhub << 8, 0, len hubd, hubd);
	if(n < 5){
		sys->print("init: %s hub descriptor failed (%d): %r\n", name, n);
		return;
	}

	nports := int hubd[2];

	#
	# bPwrOn2PwrGood is in units of 2ms: how long after switching a
	# port on before its power is good. Reading a port before then
	# reports it empty, which looks exactly like nothing being
	# plugged in.
	#
	pwrgood := int hubd[5] * 2;
	if(pwrgood < 10)
		pwrgood = 10;

	sys->print("init: %s%s is a hub with %d port(s), power good in %dms\n",
		indent, name, nports, pwrgood);

	for(port := 1; port <= nports; port++){
		if(portfeature(d, port, Fportpower) < 0){
			sys->print("init: %sport %d power failed: %r\n", indent, port);
			continue;
		}
	}
	sys->sleep(pwrgood);

	for(port = 1; port <= nports; port++){
		#
		# Poll, rather than asking once.
		#
		# Powering a port is not the same as a device having
		# signalled attach on it: the hub reports power good after
		# pwrgood ms, but the device downstream then has to be seen
		# to connect, and that is its own timescale. Asking exactly
		# once at pwrgood reports an empty port for anything slower
		# than the hub -- which is every port on this board except
		# the one whose device was already up.
		#
		status := -1;
		for(try := 0; try < 10; try++){
			status = portstatus(d, port);
			if(status < 0 || (status & HPpresent))
				break;
			sys->sleep(50);
		}
		if(status < 0){
			sys->print("init: %sport %d status failed: %r\n", indent, port);
			continue;
		}
		#
		# Report every port, not only the ones with something on
		# them. A port that is skipped silently is indistinguishable
		# from a port that was never looked at: the 3B+'s hub walk
		# printed nothing at all for all four ports, which could
		# equally have meant an empty hub, a failed status read or a
		# loop that never ran.
		#
		sys->print("init: %sport %d %#4.4x%s\n",
			indent, port, status, statusflags(status));
		if((status & HPpresent) == 0)
			continue;

		if(portfeature(d, port, Fportreset) < 0){
			sys->print("init: %sport %d reset failed: %r\n", indent, port);
			continue;
		}
		sys->sleep(50);

		status = portstatus(d, port);
		sys->print("init: %sport %d %#4.4x%s\n",
			indent, port, status, statusflags(status));
		if((status & HPenable) == 0)
			continue;

		enumerate("/usb/usb/" + name + "/ctl", port,
			speedname(status), indent);
	}
}

#
# "ep2.0" -> 2. The device number is what SET_ADDRESS has to carry:
# devusb allocated it, the device does not know it yet, and the two
# only agree once the request has gone out on the wire.
#
devnum(name: string): int
{
	n := 0;

	for(i := 0; i < len name; i++){
		c := name[i];
		if(c >= '0' && c <= '9')
			n = n * 10 + (c - '0');
		else if(n != 0)
			break;
	}
	return n;
}
