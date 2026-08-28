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

include "bench.m";

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

	jitstress();

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
	# And the server device on /chan, which is where a Limbo program
	# that wants to BE a file server puts its names.
	#
	# sys->file2chan(dir, file) makes a file whose reads and writes
	# arrive on a channel the program owns. The kernel side of that is
	# #s, and by convention it lives at /chan -- so the argument
	# programs actually pass is the literal "/chan", and without this
	# bind they get "'/chan' file does not exist" and stop. wm/wm does
	# exactly that on its first line of work, because the window
	# manager reaches its clients through a served namespace and not
	# through anything privileged.
	#
	# MCREATE, because serving a name means CREATING it.
	#
	if(sys->bind("#s", "/chan", Sys->MREPL|Sys->MCREATE) < 0)
		sys->print("init: cannot bind #s on /chan: %r\n");

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
	sdsetup();

	#
	# Spawned, and the shell starts straight after it.
	#
	# Making the shell WAIT for this walk was tried, so that the
	# prompt would be the last thing on screen rather than buried
	# under two screens of enumeration. It has to be reverted: every
	# build carrying that change failed to enumerate the low-speed
	# keyboard -- control transfers coming back as 0x55 -- and every
	# build without it enumerated cleanly, five to nothing against
	# four to nothing for. The mechanism is not understood, which is
	# exactly why the change does not stay: a prompt in a tidier
	# place is not worth a keyboard that does not work, and shipping
	# it while calling the failure intermittent would be shipping a
	# known regression under a friendlier name.
	#
	# What made it findable was building the last known-good commit
	# from a pristine copy and re-applying changes in groups, rather
	# than reasoning about which one looked guilty.
	#
	spawn usbprobe();

	#
	# A console over the network, so the serial cable is not the only
	# way in.
	#
	spawn netconsole();

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

	#
	# -l, so the shell reads /lib/sh/profile.
	#
	# That is where "load std" happens, and without it sh can run
	# commands and pipelines but has no control flow whatever: if,
	# while and for live in loadable modules under /dis/sh rather than
	# in the shell itself, so "for(i in 1 2 3)" fails looking for
	# ./for.
	#
	sh->init(nil, "sh" :: "-l" :: nil);

	sys->print("init: the shell returned\n");
}

#
# How long boot may hold the prompt back for the bus walk, in
# milliseconds. Generous, because the walk is known to finish and the
# keyboard driver is on the other side of it; bounded, because a walk
# that hangs must not cost the shell.
#

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

#
# How long to let a device settle after its port is reset, and how many
# times to reset it before giving up on it.
#
Resetrecovery:	con 50;
Watchival:	con 1000;	# how often a hub's ports are re-read, ms
Enumattempts:	con 3;
Fportpower:	con 8;

Ddev:		con 1;		# descriptor type: device
Dconf:		con 2;		# descriptor type: configuration
Dhub:		con 16r29;	# descriptor type: hub
Clhub:		con 9;		# device class: hub
Clhid:		con 3;		# interface class: human interface
Hidkbd:		con 1;		# HID boot protocol: keyboard
Hidmouse:	con 2;		# HID boot protocol: mouse
Clvendor:	con 255;	# device class: vendor-specific
Vmicrochip:	con 16r0424;	# Microchip/SMSC: the LAN78xx family
Clcomm:		con 2;		# device class: communications

HPpresent:	con 16r1;
HPenable:	con 16r2;
HPreset:	con 16r10;	# the hub clears this itself when the reset is done
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
# What dumpconfig last saw on a HID interface; 0 if none.
hidproto := 0;
hidep := -1;
hidmaxpkt := 0;
hidival := 0;

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
	#
	# Signal completion however this returns.
	#
	# Every early exit below is a plain "return", and the shell is
	# waiting on this channel; a probe that gives up quietly must not
	# also hold the prompt back.
	#
	{
		usbwalk();
	} exception {
	* =>
		sys->print("init: usb probe failed\n");
	}
}

usbwalk()
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

	walking = 1;
	enumerate("/usb/usb/ep1.0/ctl", d, 1, speedname(status), "");
	startpending();
}

#
# Bring one device up on a port of some hub, and if it turns out to be
# a hub itself, walk it too.
#
# hubctl is the ctl file of the hub the device hangs off -- the root
# hub's for the first call, a real hub's for the recursive ones. depth
# is only used to indent the report.
#
#
# Reset a hub port again and wait for the device to come back.
#
# Takes the hub's OPEN fd rather than reopening it by path. Reopening
# was wrong twice over: devusb hands out an endpoint to one opener, so
# the second open failed and the retry gave up immediately -- and the
# failed namespace walk left a channel that was then closed twice,
# panicking the kernel with "cclose" the moment any device failed to
# enumerate. A device failing to enumerate is common enough on this
# board that it took the machine down on most boots.
#
reresetport(d: ref Sys->FD, port: int, indent: string): int
{
	sys->print("init: %sport %d did not answer; resetting it again\n",
		indent, port);
	if(portfeature(d, port, Fportreset) < 0)
		return -1;

	for(w := 0; w < 25; w++){		# up to half a second
		sys->sleep(20);
		status := portstatus(d, port);
		if(status < 0)
			return -1;
		if(status & HPenable)
			break;
		if((status & HPreset) == 0)
			break;
	}
	sys->sleep(Resetrecovery);
	return 0;
}

enumerate(hubctl: string, hubd: ref Sys->FD, port: int, speed, indent: string): int
{
	c := sys->open(hubctl, Sys->ORDWR);
	if(c == nil){
		sys->print("init: cannot open %s: %r\n", hubctl);
		return -1;
	}

	#
	# newdev allocates the endpoint and leaves its NAME to be read
	# back from the same fd -- devusb stashes it in Chan.aux. So the
	# ctl file has to be held open across both operations; opening it
	# twice would allocate a device and then lose its name.
	#
	if(sys->fprint(c, "newdev %s %d", speed, port) < 0){
		sys->print("init: usb newdev failed: %r\n");
		return -1;
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
		return -1;
	}
	name := string nbuf[0:n];

	d := sys->open("/usb/usb/" + name + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("init: cannot open %s: %r\n", name);
		return -1;
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
	#
	# Check the descriptor, do not just count the bytes.
	#
	# A device descriptor begins with its own length (18) and its type
	# (1). Accepting any 18 bytes means accepting 18 bytes of
	# anything -- which is exactly what happened: a low-speed
	# keyboard whose transfer returned 0x55 repeating was reported as
	# "0x5555:0x5555 class 85 maxpkt 85 usb 85.5", the retry loop saw
	# a full-length read and stopped, and the driver then programmed
	# a maximum packet size of 85 from a field that was never a
	# field.
	#
	# Two bytes of validation turn that into a retry, and a retry is
	# worth having: the identical device on the next port enumerates
	# correctly, so this is a transfer that fails sometimes rather
	# than a device that cannot be read.
	#
	#
	# Between attempts, RESET THE PORT AGAIN -- on this same device.
	#
	# Re-reading a descriptor does not help one that came out of reset
	# wrong; only another reset does. But it has to be another reset
	# of the device already allocated, not another trip through
	# enumeration: newdev hands out a fresh device each time it is
	# called, so retrying from the top left the same keyboard
	# enumerated twice, and the second copy -- ep8.0 -- had no
	# endpoints for the driver to open.
	#
	desc := array[18] of byte;
	ok := 0;
	for(try := 0; try < Enumattempts; try++){
		if(try > 0 && reresetport(hubd, port, indent) < 0)
			break;
		n = ctlreq(d, Rd2h, Rgetdesc, Ddev << 8, 0, len desc, desc);
		if(n < len desc){
			sys->print("init: %sdevice descriptor read failed (%d): %r\n",
				indent, n);
			continue;
		}
		if(int desc[0] != len desc || int desc[1] != Ddev){
			sys->print("init: %sdevice descriptor is not one (len %d type %d)\n",
				indent, int desc[0], int desc[1]);
			continue;
		}
		ok = 1;
		break;
	}
	if(!ok){
		sys->print("init: %s%s never answered after reset\n", indent, name);
		return -1;
	}
	if(try > 0)
		sys->print("init: %sdescriptor read succeeded on attempt %d\n",
			indent, try+1);

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
		return -1;
	}
	sys->fprint(dctl, "maxpkt %d", maxpkt);

	nb := devnum(name);
	rep := array[4] of byte;
	if(ctlreq(d, Rh2d, Rsetaddress, nb, 0, 0, rep) < 0){
		sys->print("init: %s set address %d failed: %r\n", name, nb);
		return -1;
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
		return -1;

	if(class == Clhub){
		hubwalk(name, d, dctl, indent + "  ");
		return -1;
	}

	hidproto = 0;
	hidep = -1;
	dumpconfig(d, indent + "  ");

	#
	# Hand the endpoint over rather than making the driver find it.
	#
	# The walk has just read and parsed this device's configuration
	# descriptor; the driver used to read and parse it AGAIN over the
	# same fragile low-speed control pipe, for the same three numbers.
	# Once was already a coin toss on this controller -- doing it
	# twice doubled the chance of a device coming up without a driver,
	# and the second attempt happens later, when the bus is busier.
	#
	if(hidproto == Hidkbd)
		startdriver("/dis/kbdusb.dis", name, hidep, hidmaxpkt, hidival);
	else if(hidproto == Hidmouse)
		startdriver("/dis/mouseusb.dis", name, hidep, hidmaxpkt, hidival);

	#
	# Hand it to a class driver, which is a program. The bus walk's
	# job ends at "there is a device of this class at this endpoint";
	# what to say to it is not the kernel's business.
	#
	#
	# Hand over on class OR on identity.
	#
	# CDC devices announce themselves by class. The LAN78xx does not:
	# the 3B+'s onboard Ethernet enumerates as 0424:7800 with class
	# 255, vendor-specific, because its control interface is a set of
	# vendor register reads and writes rather than anything the CDC
	# spec describes. Dispatching on class alone finds every USB
	# Ethernet device except the one soldered to this board.
	#
	# The id check is deliberately narrow -- Microchip's vendor id,
	# which covers the LAN78xx family etherusb knows -- rather than
	# "start the driver for anything vendor-specific", which would
	# spawn a driver per unknown device and call that discovery.
	#
	if(class == Clcomm || (class == Clvendor && vendor == Vmicrochip))
		startdriver("/dis/etherusb.dis", name, -1, 0, 0);
	return 0;
}


#
# A shell on a TCP port.
#
# The serial line is the only way to reach this board, and it is a poor
# one: it carries the console AND every kernel message, a window system
# reading /dev/keyboard splits typed input with the shell (they are the
# same queue in devcons), and it tethers the machine to a desk. A
# network console has none of those problems -- each connection gets
# its own shell with its own file descriptors, and kernel output still
# goes to the serial console where it belongs.
#
# styxlisten would be the usual way to do this, and it is not used
# because it loads $Keyring unconditionally, which would mean linking
# the whole crypto stack into a kernel that has no other use for it
# yet. This is the same idea in thirty lines of the Sys module.
#
# THERE IS NO AUTHENTICATION. Anything that can reach port 17010 gets a
# shell. That is a deliberate choice for a development board on a
# private network and it must not survive into anything shipped -- see
# the ring-fence rule in CLAUDE.md for the shape of that argument. It
# is here because the alternative is a serial cable.
#
Netconsport: con "tcp!*!17010";

netconsole()
{
	(ok, c) := sys->announce(Netconsport);
	if(ok < 0){
		sys->print("init: no network console: %r\n");
		return;
	}
	sys->print("init: network console on %s\n", Netconsport);
	for(;;){
		(lok, nc) := sys->listen(c);
		if(lok < 0){
			sys->print("init: network console listen: %r\n");
			return;
		}
		fd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(fd == nil){
			sys->print("init: network console open: %r\n");
			continue;
		}
		spawn netshell(fd);
	}
}

netshell(fd: ref Sys->FD)
{
	#
	# A private set of file descriptors and a private namespace, so
	# one session cannot disturb another or the console shell. NEWFD
	# keeps only this connection; the dups then make it stdin, stdout
	# and stderr, which is all a shell needs.
	#
	sys->pctl(Sys->NEWFD | Sys->FORKNS, fd.fd :: nil);
	sys->dup(fd.fd, 0);
	sys->dup(fd.fd, 1);
	sys->dup(fd.fd, 2);

	sh := load Command "/dis/sh.dis";
	if(sh == nil){
		sys->fprint(fd, "cannot load /dis/sh.dis: %r\n");
		return;
	}
	sh->init(nil, "sh" :: nil);
}

#
# Load a class driver and let it run in its own process.
#
# A command in Inferno is a Dis module -- there is no exec(2) -- so
# starting one means loading it and calling init(). It is spawned
# rather than called so that a driver which blocks waiting for its
# device does not stop the rest of the bus walk.
#
#
# Name the partitions on the SD card, and serve the FAT one.
#
# The kernel offers named byte ranges and knows nothing about partition
# tables; reading the master boot record is policy, so it happens here.
# Whoever reads it decides what the ranges are called, and dossrv --
# an ordinary Limbo program with no special privilege -- turns the FAT
# one into a namespace.
#
sdsetup()
{
	fd := sys->open("/dev/sdcard", Sys->OREAD);
	if(fd == nil)
		return;			# no card, which is not an error

	sec := array[512] of byte;
	if(sys->pread(fd, sec, len sec, big 0) != len sec){
		sys->print("init: cannot read the card\n");
		return;
	}
	if(int sec[510] != 16r55 || int sec[511] != 16rAA){
		sys->print("init: card has no partition table\n");
		return;
	}

	ctl := sys->open("/dev/sdctl", Sys->OWRITE);
	if(ctl == nil){
		sys->print("init: cannot open /dev/sdctl: %r\n");
		return;
	}

	dos := "";
	for(i := 0; i < 4; i++){
		p := 446 + i*16;
		ptype := int sec[p+4];	# 'type' is a Limbo keyword
		if(ptype == 0)
			continue;
		start := int sec[p+8] | (int sec[p+9] << 8) |
			(int sec[p+10] << 16) | (int sec[p+11] << 24);
		nsec := int sec[p+12] | (int sec[p+13] << 8) |
			(int sec[p+14] << 16) | (int sec[p+15] << 24);

		name := sys->sprint("sd%d", i);
		if(sys->fprint(ctl, "part %s %d %d", name, start, nsec) < 0){
			sys->print("init: cannot name partition %d: %r\n", i);
			continue;
		}
		sys->print("init: /dev/%s: type %#2.2x, %d sectors\n",
			name, ptype, nsec);

		#
		# The FAT types, and only the first one found.
		#
		# 0x0B and 0x0C are FAT32, 0x06 and 0x0E FAT16, 0x04 small
		# FAT16, 0x01 FAT12. The Pi's boot partition is 0x0C.
		#
		if(dos == "" && (ptype == 16r01 || ptype == 16r04 ||
		    ptype == 16r06 || ptype == 16r0B || ptype == 16r0C ||
		    ptype == 16r0E))
			dos = name;
	}

	if(dos == "")
		return;

	srv := load Command "/dis/dossrv.dis";
	if(srv == nil){
		sys->print("init: cannot load dossrv: %r\n");
		return;
	}
	#
	# Called, NOT spawned, and that is the whole difference between
	# this working and not.
	#
	# dossrv mounts the filesystem in the process that calls it and
	# returns once the mount is done; the server itself carries on in
	# a process it spawned. sh, meanwhile, forks its namespace the
	# moment it starts -- so a mount that lands after that is made in
	# a namespace the shell does not share, and /n/dos stays the empty
	# directory it was in the image. Spawning this raced the shell and
	# lost.
	#
	{
		srv->init(nil, "dossrv" :: "-f" :: "/dev/" + dos ::
			"-m" :: "/n/dos" :: nil);
		sys->print("init: /dev/%s mounted on /n/dos\n", dos);
	} exception {
	* =>
		sys->print("init: dossrv could not serve /dev/%s\n", dos);
	}
}

#
# Class drivers are started AFTER the bus walk, not during it.
#
# A driver begins talking to its device the moment it starts, and on
# this controller that traffic is not innocent: the DWC has eight
# channels and one periodic schedule shared by every device on the
# bus, and a low-speed device behind a hub reaches it through split
# transactions that have to be issued in the right microframe. Bulk
# transfers from a high-speed device -- which is what etherusb starts
# doing immediately, and at line rate -- take channels and shift that
# schedule.
#
# The symptom was a mouse whose device descriptor read cleanly and
# whose configuration descriptor then came back as 0x55 repeating
# three times running, while the log showed etherusb's LAN78xx bring-up
# interleaved line for line with the walk that was failing. The same
# mouse enumerates perfectly on a boot where the ordering happens to
# differ, which is the signature of a timing collision rather than a
# bad device.
#
# So collect them and start them at the end. This is also what Plan 9's
# usbd does -- it enumerates the bus, then execs a driver per device --
# and for the same reason.
#
# Deferral only applies WHILE a walk is running. A device plugged in
# later is a walk of one device with nothing to collide with, so its
# driver starts straight away; queueing it would mean it never started
# at all, since nothing drains the queue outside a walk.
#
walking := 0;
pending: list of (string, string, int, int, int);

startdriver(path, name: string, ep, maxpkt, ival: int)
{
	if(walking){
		pending = (path, name, ep, maxpkt, ival) :: pending;
		return;
	}
	runstart(path, name, ep, maxpkt, ival);
}

runstart(path, name: string, ep, maxpkt, ival: int)
{
	drv := load Command path;
	if(drv == nil){
		sys->print("init: cannot load %s: %r\n", path);
		return;
	}
	argv := path :: name :: nil;
	if(ep >= 0)
		argv = path :: name :: string ep :: string maxpkt ::
			string ival :: nil;
	spawn drv->init(nil, argv);
}

#
# Start what the walk found, in the order it was found.
#
# pending is built by prepending, so it is reversed here. The order is
# not cosmetic: the first device found is the one closest to the root
# hub, and bringing the bus up outward from there is the order the
# devices themselves were enumerated in.
#
startpending()
{
	walking = 0;
	l: list of (string, string, int, int, int);
	for(p := pending; p != nil; p = tl p)
		l = hd p :: l;
	pending = nil;
	for(; l != nil; l = tl l){
		(path, name, ep, maxpkt, ival) := hd l;
		runstart(path, name, ep, maxpkt, ival);
	}
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

	#
	# Read it, and CHECK IT, and retry if it is nonsense.
	#
	# A control transfer that comes back wrong does not report an
	# error -- it hands over whatever the buffer held, and on this
	# board a failed low-speed split fills it with 0x55, alternating
	# bits, a bus sampled at the wrong rate. Accepting that meant
	# SET_CONFIGURATION with a value of 85, which the device rejects
	# or ignores, so no endpoint ever worked and the keyboard driver
	# was never started -- with nothing in the log but a plausible
	# looking "configured (value 85)".
	#
	# A configuration descriptor names its own length and type, so it
	# can say whether it is one. The device descriptor is already
	# validated this way for the same reason; this is the other half.
	#
	cfgval := 0;
	for(try := 0; try < 3; try++){
		n := ctlreq(d, Rd2h, Rgetdesc, Dconf << 8, 0, len hdr, hdr);
		if(n < len hdr){
			sys->print("init: %s%s config descriptor failed (%d): %r\n",
				indent, name, n);
			continue;
		}
		if(int hdr[0] != 9 || int hdr[1] != Dconf){
			sys->print("init: %s%s bad config descriptor (len %d type %d), retrying\n",
				indent, name, int hdr[0], int hdr[1]);
			continue;
		}
		# byte 5 is bConfigurationValue; 0 would mean "unconfigured"
		cfgval = int hdr[5];
		break;
	}
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
	#
	# Read it until it looks like a configuration descriptor.
	#
	# Control transfers to a low-speed device behind a translator come
	# back as 0x55 -- alternating bits -- often enough that a single
	# attempt is a coin toss, and the failure does NOT arrive as an
	# error: the length field reads 21845, which is 0x5555, and the
	# type reads 85. This device descriptor and this device's own
	# nine-byte config header both succeeded moments earlier, so it is
	# a transfer that fails sometimes and not a device that cannot be
	# read.
	#
	# It is worth retrying rather than reporting, because what is lost
	# is not a diagnostic: the interface class lives in here, and the
	# class is how a device is matched to a driver. A keyboard whose
	# configuration cannot be read is a keyboard with no driver, which
	# is the whole of "the keys do nothing".
	#
	total := 0;
	hdr := array[9] of byte;
	cfg: array of byte;
	for(try := 0; try < Enumattempts; try++){
		n := ctlreq(d, Rd2h, Rgetdesc, Dconf << 8, 0, len hdr, hdr);
		if(n < len hdr){
			sys->print("init: %sconfig descriptor header failed (%d)\n",
				indent, n);
			continue;
		}
		if(int hdr[0] != 9 || int hdr[1] != Dconf){
			sys->print("init: %sconfig header is not one (len %d type %d)\n",
				indent, int hdr[0], int hdr[1]);
			continue;
		}
		total = int hdr[2] | (int hdr[3] << 8);
		if(total < len hdr || total > 512){
			sys->print("init: %sconfig descriptor length %d unreasonable\n",
				indent, total);
			total = 0;
			continue;
		}

		cfg = array[total] of byte;
		n = ctlreq(d, Rd2h, Rgetdesc, Dconf << 8, 0, total, cfg);
		if(n < total){
			sys->print("init: %sconfig descriptor short (%d of %d)\n",
				indent, n, total);
			total = 0;
			continue;
		}
		#
		# The full read repeats the header, so it can be checked
		# against itself: a second transfer that returned garbage
		# disagrees with the first about what this descriptor is.
		#
		if(int cfg[0] != 9 || int cfg[1] != Dconf){
			sys->print("init: %sconfig body is not one (len %d type %d)\n",
				indent, int cfg[0], int cfg[1]);
			total = 0;
			continue;
		}
		break;
	}
	if(total == 0){
		sys->print("init: %sconfiguration unreadable; no driver can be matched\n",
			indent);
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
			if(i + 9 <= total){
				sys->print("init: %s  if %d alt %d: class %d.%d.%d, %d endpoint(s)\n",
					indent, int cfg[i+2], int cfg[i+3],
					int cfg[i+5], int cfg[i+6], int cfg[i+7],
					int cfg[i+4]);
				#
				# HID lives on the INTERFACE, not the device:
				# a keyboard's device class is 0 and its
				# interface class is 3.1.1. Dispatching on
				# the device class alone therefore never sees
				# an input device at all.
				#
				if(int cfg[i+5] == Clhid && hidproto == 0)
					hidproto = int cfg[i+7];
			}
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
				#
				# Keep the first interrupt-IN endpoint that
				# follows a HID interface. Endpoint
				# descriptors belong to the interface they
				# come after, so this is that interface's,
				# and the first is the one a boot-protocol
				# device reports on.
				#
				if(hidproto != 0 && hidep < 0
				&& (addr & 16r80) && (attr & 3) == 3){
					hidep = addr & 16rF;
					hidmaxpkt = mx;
					hidival = int cfg[i+6];
				}
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
# Reset a port and enumerate whatever is on it.
#
# Split out of the boot walk so the hub watcher can call exactly the
# same code when something is plugged in later. A device that arrives
# after boot has to go through precisely what a device present at boot
# goes through -- if the two paths differ, one of them is the one that
# never gets exercised.
#
portsetup(d: ref Sys->FD, name: string, port: int, indent: string): int
{
	#
	# Reset, and try again if the port does not enable.
	#
	# The root port needed exactly this and for the same reason: a
	# device that fluffs its reset handshake usually manages on a
	# second attempt, and giving up after one leaves it invisible.
	#
	# Issue the reset, then WAIT for the hub to finish it. An earlier
	# version slept a flat 50ms and re-issued the reset if the port
	# was not enabled, which made things worse: re-issuing
	# SET_FEATURE(PORT_RESET) RESTARTS the reset, so a port needing
	# longer than 50ms was interrupted and restarted three times and
	# never converged -- reporting 0x0311 (present, powered, low
	# speed, reset still asserted) every attempt.
	#
	# A hub clears the reset bit itself when it is done and sets
	# enable, so poll for that and only re-issue if the hub has
	# finished and still not enabled the port.
	#
	status := -1;
	for(rtry := 0; rtry < 3; rtry++){
		if(portfeature(d, port, Fportreset) < 0){
			sys->print("init: %sport %d reset failed: %r\n", indent, port);
			return -1;
		}
		for(w := 0; w < 25; w++){		# up to half a second
			sys->sleep(20);
			status = portstatus(d, port);
			if(status < 0)
				break;
			if(status & HPenable)
				break;
			if((status & HPreset) == 0)
				break;		# hub finished, port not enabled
		}
		if(status < 0 || (status & HPenable))
			break;
		sys->print("init: %sport %d %#4.4x not enabled after reset, retrying\n",
			indent, port, status);
	}

	sys->print("init: %sport %d %#4.4x%s\n",
		indent, port, status, statusflags(status));
	if(status < 0 || (status & HPenable) == 0)
		return -1;

	#
	# Let the device recover before speaking to it.
	#
	# A port that reports itself enabled is not yet a device that will
	# answer: the spec gives one up to 10ms after reset (TRSTRCY)
	# before it has to respond, and asking inside that window gets
	# nothing back -- which arrives as a buffer still holding 0x55
	# rather than as an error, because a control transfer that returns
	# no data does not report one.
	#
	sys->sleep(Resetrecovery);

	enumerate("/usb/usb/" + name + "/ctl", d, port, speedname(status), indent);
	return 0;
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

		portsetup(d, name, port, indent);
	}

	#
	# Keep watching, so plugging something in later works.
	#
	# Without this the bus is walked exactly once and never again: a
	# keyboard connected after boot is invisible until the machine is
	# restarted, which is indistinguishable from the keyboard being
	# broken. Every hub reports port changes, so there is no reason
	# for a device to go unnoticed.
	#
	spawn hubwatch(d, name, nports, indent);
}

#
# Watch a hub's ports and act on what changes.
#
# Polled, not driven by the hub's status-change interrupt endpoint.
# The endpoint is the tidier mechanism and this should move to it, but
# it would be the third consumer of an interrupt endpoint on a
# controller whose split-transaction handling has been the single
# largest source of bugs in this port -- whereas GET_PORT_STATUS is an
# ordinary control transfer over a path that is exercised at every
# boot. Correct and boring first.
#
# A second a poll is imperceptible to a person plugging something in
# and negligible beside what the HID drivers already ask of the bus.
#
hubwatch(d: ref Sys->FD, name: string, nports: int, indent: string)
{
	was := array[nports+1] of int;
	for(i := 1; i <= nports; i++){
		st := portstatus(d, i);
		was[i] = st >= 0 && (st & HPpresent);
	}

	for(;;){
		sys->sleep(Watchival);
		for(port := 1; port <= nports; port++){
			status := portstatus(d, port);
			if(status < 0)
				continue;
			now := (status & HPpresent) != 0;
			if(now == was[port])
				continue;
			was[port] = now;

			if(now){
				sys->print("init: %s%s port %d: device attached\n",
					indent, name, port);
				#
				# The same code the boot walk runs. A device
				# that arrives later must not take a
				# different path to one that was already
				# there.
				#
				portsetup(d, name, port, indent);
			}else{
				#
				# Say so, and leave it there.
				#
				# The driver notices on its own -- every
				# transfer to a device that has gone fails,
				# and kbdusb and mouseusb give up after a run
				# of those. What is NOT done here is
				# releasing the devusb endpoints, so the
				# device number is not reused: plug the same
				# keyboard back in and it enumerates as a new
				# one. That needs devusb's detach, and doing
				# it wrong orphans an endpoint a driver still
				# holds, so it is deliberately left until the
				# teardown can be tested properly.
				#
				sys->print("init: %s%s port %d: device removed\n",
					indent, name, port);
			}
		}
	}
}

#
# Exercise the JIT across the instruction set, not across one loop.
#
# The existing benchmark runs "acc += (k*3) ^ (k>>2)" two million times.
# That is six opcodes. A miscompilation in loads and stores, calls,
# 64-bit arithmetic, floating point, arrays, strings or channels would
# pass it without a murmur -- and comp-arm64.c is the riskiest thing in
# this tree running somewhere it has never run.
#
# Each class folds its results into a checksum and prints it. The value
# itself means nothing; what means something is that the JIT and the
# interpreter produce the SAME one. The harness builds both kernels and
# compares every line, so a divergence names the class it is in rather
# than reporting that something, somewhere, is wrong.
#
# Timings are printed per class too, which is what makes "benchmarked"
# more than a single arithmetic loop.
#
jitfold(h, v: int): int
{
	return h * 31 + v;
}

#
# The measurement apparatus, per "Reliable Benchmarking with Limbo on
# Inferno" (Vita Nuova, 1999, revised 2000).
#
# Three things distinguish this from timing something once:
#
#   MICROSECONDS. sys->millisec() cannot see a workload that takes less
#   than a millisecond, and reports one that takes 1.6ms as either 1 or
#   2. $Bench gives the generic timer directly -- 52ns a step here.
#
#   REPETITION, and the MINIMUM rather than the mean. Every disturbance
#   -- an interrupt, a driver poll, a cache eviction caused by something
#   else -- makes a sample LONGER, never shorter. So the minimum of many
#   samples is the closest thing to the cost of the work itself, and the
#   spread between minimum and median says how disturbed the machine
#   was while measuring. A mean folds those together and hides both.
#
#   NO COLLECTOR. A garbage collection landing inside a sample is not
#   part of what is being measured and is indistinguishable from a real
#   outlier.
#
Nrep:	con 5;		# samples per workload

bench: Bench;

jitstress()
{
	bench = load Bench Bench->PATH;
	if(bench == nil){
		sys->print("jit: no $Bench; cannot measure\n");
		return;
	}

	sys->print("jit: stress begins\n");

	#
	# What it costs to take a measurement at all, subtracted from
	# every sample below. Measured the same way it will be used --
	# the doc's point is that this number is only meaningful if it is
	# obtained under the same conditions as the thing it corrects.
	#
	base := big 0;
	for(i := 0; i < Nrep; i++){
		t := bench->microsec();
		d := bench->microsec() - t;
		if(i == 0 || d < base)
			base = d;
	}
	sys->print("jit: measurement overhead %bd us\n", base);

	sample("int", base);
	sample("big", base);
	sample("real", base);
	sample("array", base);
	sample("string", base);
	sample("call", base);
	sample("chan", base);

	sys->print("jit: stress ends\n");
}

#
# Run one workload Nrep times and report what the samples say.
#
sample(what: string, base: big)
{
	lo, hi, mid: big;
	h := 0;

	bench->disablegc();
	for(i := 0; i < Nrep; i++){
		t0 := bench->microsec();
		case what {
		"int" =>	h = jitint();
		"big" =>	h = jitbig();
		"real" =>	h = jitreal();
		"array" =>	h = jitarray();
		"string" =>	h = jitstring();
		"call" =>	h = jitcall();
		"chan" =>	h = jitchan();
		}
		d := bench->microsec() - t0 - base;
		if(d < big 0)
			d = big 0;
		if(i == 0){
			lo = d;
			hi = d;
			mid = d;
		}else{
			if(d < lo)
				lo = d;
			if(d > hi)
				hi = d;
		}
	}
	bench->enablegc();

	#
	# The checksum is the point of the whole exercise and the timings
	# are secondary: it must be IDENTICAL to the interpreter's, and
	# the harness compares the two kernels line by line. A JIT that is
	# merely fast is a miscompilation waiting to be found.
	#
	sys->print("jit: %s %8.8ux min %bd us max %bd us\n", what, h, lo, hi);
}

#
# Integer arithmetic, including the cases that are easy to get wrong:
# negative operands, division and remainder truncation, and shifts.
#
jitint(): int
{
	h := 0;
	for(i := -5000; i < 5000; i++){
		h = jitfold(h, i + 7);
		h = jitfold(h, i - 9);
		h = jitfold(h, i * 3);
		if(i != 0){
			h = jitfold(h, 1000000 / i);
			h = jitfold(h, 1000000 % i);
		}
		h = jitfold(h, i & 16r5A5A);
		h = jitfold(h, i | 16r0F0F);
		h = jitfold(h, i ^ 16r1234);
		h = jitfold(h, i << (i & 7));
		h = jitfold(h, i >> (i & 7));
		if(i < 0)
			h = jitfold(h, -i);
	}
	return h;
}

#
# 64-bit arithmetic. This tree is LP64 and the JIT is new; big is where
# a 32-bit assumption would show up first.
#
jitbig(): int
{
	h := 0;
	b := big 1;
	for(i := 0; i < 20000; i++){
		b = b * big 3 + big i;
		b = b ^ big 16r5A5A5A5A;
		if(b < big 0)
			b = -b;
		b = b % big 1000000007;
		h = jitfold(h, int b);
		h = jitfold(h, int (b >> 16));
	}
	return h;
}

#
# Floating point, including comparisons and the int/real conversions
# either side of it.
#
jitreal(): int
{
	h := 0;
	r := 1.0;
	for(i := 1; i < 20000; i++){
		r = r * 1.0000001 + real i / 1000.0;
		if(r > 1000000.0)
			r = r / 1000.0;
		h = jitfold(h, int (r * 100.0));
		if(r < 1.0)
			h = jitfold(h, 1);
	}
	return h;
}

#
# Loads and stores: indexing, slicing and copying, which is where a
# wrong addressing mode hides.
#
jitarray(): int
{
	h := 0;
	a := array[256] of int;
	b := array[256] of byte;
	for(i := 0; i < len a; i++){
		a[i] = i * i;
		b[i] = byte (i & 16rFF);
	}
	for(n := 0; n < 200; n++){
		for(i = 0; i < len a; i++){
			a[i] = a[i] + a[(i + n) & 16rFF];
			h = jitfold(h, a[i]);
		}
		c := array[64] of byte;
		c[0:] = b[n & 16r7F : (n & 16r7F) + 64];
		for(i = 0; i < len c; i++)
			h = jitfold(h, int c[i]);
	}
	return h;
}

#
# Strings: concatenation, comparison and indexing, which go through the
# runtime rather than being open-coded.
#
jitstring(): int
{
	h := 0;
	for(n := 0; n < 2000; n++){
		s := "";
		for(i := 0; i < 16; i++)
			s += string ((n + i) & 16rF);
		h = jitfold(h, len s);
		for(i = 0; i < len s; i++)
			h = jitfold(h, s[i]);
		if(s < "9")
			h = jitfold(h, 1);
		if(s == "")
			h = jitfold(h, 2);
	}
	return h;
}

#
# Calls: deep recursion and several arguments, exercising frame setup
# and the return path rather than the body.
#
jitrec(n, a, b, c: int): int
{
	if(n <= 0)
		return a ^ b ^ c;
	return jitrec(n - 1, b + 1, c + 2, a + 3) + 1;
}

jitcall(): int
{
	h := 0;
	for(i := 0; i < 2000; i++)
		h = jitfold(h, jitrec(100, i, i * 2, i * 3));
	return h;
}

#
# Channels and spawn: the Dis operations with no C equivalent, and the
# ones a compiler is most likely to leave to the interpreter.
#
jitproducer(c: chan of int, n: int)
{
	for(i := 0; i < n; i++)
		c <-= i * 7;
	c <-= -1;
}

jitchan(): int
{
	h := 0;
	c := chan of int;
	spawn jitproducer(c, 20000);
	for(;;){
		v := <-c;
		if(v < 0)
			break;
		h = jitfold(h, v);
	}
	return h;
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
