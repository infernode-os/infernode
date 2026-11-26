implement Nettest;

#
# The network, end to end, with no hardware: #I is bound at /net, the
# loopback medium is bound to a fresh interface, 127.0.0.1/8 is put on
# it, and an ICMP echo goes out through ipoput4, across loopback, back
# in through ipiput4, is answered by icmp.c, and is delivered to this
# conversation.  Checksums, the route lookup, the interface's self
# addresses and the protocol demultiplexer are all on that path.
#
# It also mounts the host's namespace channel, when the loader offers
# one, which is the other half of what makes this an Infernode: /n/remote
# is a 9P file server reached through #~, not through a network device.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Nettest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

Ipsize:		con 20;		# an IPv4 header, which icmpkick fills in
Hdrsize:	con 8;		# ICMP header
Echoreq:	con 8;
Echoreply:	con 0;
Pingwait:	con 20000;	# ms; loopback answers in one, QEMU TCG is slow
Tcpport:	con "9999";

halt()
{
	# #c, not /dev: this module does not bind the console device.
	fd := sys->open("#c/sysctl", Sys->OWRITE);
	if(fd != nil){
		b := array of byte "halt\n";
		sys->write(fd, b, len b);
	}
}

fail(msg: string)
{
	sys->print("nettest failed: %s\n", msg);
	halt();
}

clone(dir: string): (ref Sys->FD, string)
{
	fd := sys->open(dir + "/clone", Sys->ORDWR);
	if(fd == nil)
		return (nil, "");
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return (nil, "");
	return (fd, string buf[0:n]);
}

watchdog()
{
	sys->sleep(Pingwait);
	sys->print("nettest failed: the network test did not finish\n");
	halt();
}

#
# The listening half of the TCP echo.  The listener has to be a
# separate thread because opening .../listen blocks until somebody
# connects; when it does, the open returns the NEW conversation that
# carries the accepted connection.
#
tcplistener(sync: chan of int)
{
	(a, aconv) := clone("/net/tcp");
	if(a == nil){
		sync <-= 0;
		return;
	}
	if(sys->fprint(a, "announce " + Tcpport) < 0){
		sync <-= 0;
		return;
	}
	sync <-= 1;

	l := sys->open("/net/tcp/" + aconv + "/listen", Sys->ORDWR);
	if(l == nil)
		return;
	nbuf := array[32] of byte;
	ln := sys->read(l, nbuf, len nbuf);
	if(ln <= 0)
		return;
	d := sys->open("/net/tcp/" + string nbuf[0:ln] + "/data", Sys->ORDWR);
	if(d == nil)
		return;
	rbuf := array[64] of byte;
	rn := sys->read(d, rbuf, len rbuf);
	if(rn > 0)
		sys->write(d, rbuf[0:rn], rn);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	if(sys->bind("#I", "/net", Sys->MREPL) < 0)
		fail("bind #I /net: " + sys->sprint("%r"));
	sys->print("nettest: #I bound at /net\n");

	(ifc, ifcno) := clone("/net/ipifc");
	if(ifc == nil)
		fail("clone ipifc: " + sys->sprint("%r"));
	if(sys->fprint(ifc, "bind loopback") < 0)
		fail("bind loopback: " + sys->sprint("%r"));
	if(sys->fprint(ifc, "add 127.0.0.1 255.0.0.0") < 0)
		fail("add 127.0.0.1/8: " + sys->sprint("%r"));
	sys->print("nettest: 127.0.0.1/8 on ipifc %s\n", ifcno);

	(icmp, conv) := clone("/net/icmp");
	if(icmp == nil)
		fail("clone icmp: " + sys->sprint("%r"));
	if(sys->fprint(icmp, "connect 127.0.0.1!1") < 0)
		fail("icmp connect: " + sys->sprint("%r"));
	d := sys->open("/net/icmp/" + conv + "/data", Sys->ORDWR);
	if(d == nil)
		fail("open icmp data: " + sys->sprint("%r"));

	req := array[Ipsize + Hdrsize + 8] of byte;
	req[Ipsize] = byte Echoreq;
	req[Ipsize + 7] = byte 1;		# sequence
	spawn watchdog();
	if(sys->write(d, req, len req) != len req)
		fail("icmp write: " + sys->sprint("%r"));

	rep := array[256] of byte;
	n := sys->read(d, rep, len rep);
	if(n < Ipsize + Hdrsize)
		fail(sys->sprint("no echo reply (read %d): %r", n));
	if(int rep[Ipsize] != Echoreply)
		fail(sys->sprint("unexpected icmp type %d", int rep[Ipsize]));
	sys->print("nettest: icmp echo reply, %d bytes\n", n);

	#
	# TCP proves the hard part: a three-way handshake, sequence
	# numbers advancing on both sides, windows, and an ordered byte
	# stream in each direction.  Every segment compares sequence
	# numbers through seq_lt and friends, so a wrong answer stalls the
	# connection rather than corrupting it.
	#
	sync := chan of int;
	spawn tcplistener(sync);
	if(<-sync != 1)
		fail("tcp announce: " + sys->sprint("%r"));

	(c, tconv) := clone("/net/tcp");
	if(c == nil)
		fail("clone tcp: " + sys->sprint("%r"));
	if(sys->fprint(c, "connect 127.0.0.1!" + Tcpport) < 0)
		fail("tcp connect: " + sys->sprint("%r"));
	td := sys->open("/net/tcp/" + tconv + "/data", Sys->ORDWR);
	if(td == nil)
		fail("open tcp data: " + sys->sprint("%r"));
	msg := array of byte "hello-tcp";
	if(sys->write(td, msg, len msg) != len msg)
		fail("tcp write: " + sys->sprint("%r"));
	tbuf := array[64] of byte;
	tn := sys->read(td, tbuf, len tbuf);
	if(tn != len msg || string tbuf[0:tn] != "hello-tcp")
		fail(sys->sprint("tcp echo: read %d: %r", tn));
	sys->print("nettest: tcp echo over loopback\n");

	#
	# The host namespace, when this loader offers one.  9vm publishes
	# #~/ns only when it was given a server to relay to; QEMU has no
	# ring at all.  A loader without one is not a failure.
	#
	ns := sys->open("#~/ns", Sys->ORDWR);
	if(ns == nil)
		sys->print("nettest: no #~ namespace on this loader\n");
	else {
		if(sys->mount(ns, nil, "/n/remote", Sys->MREPL, "") < 0)
			fail("mount #~/ns: " + sys->sprint("%r"));
		sys->print("nettest: #~/ns mounted at /n/remote\n");
		fd := sys->open("/n/remote/hello", Sys->OREAD);
		if(fd == nil)
			fail("open /n/remote/hello: " + sys->sprint("%r"));
		buf := array[64] of byte;
		rn := sys->read(fd, buf, len buf);
		if(rn != 14 || string buf[0:rn] != "hello from ns\n")
			fail(sys->sprint("read /n/remote/hello: %d bytes: %r", rn));
		sys->print("nettest: ns read %d \"hello from ns\"\n", rn);
	}

	sys->print("nettest passed\n");
	halt();
}
