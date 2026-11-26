implement Nettest;

#
# The network, end to end.
#
# #I is bound at /net and #l is merged beside it, then loopback is
# brought up at 127.0.0.1/8.  If the machine has a virtio-net device
# (QEMU with -device virtio-net-pci; 9vm when it has a TAP it is
# allowed to open), ether0 is bound as a second interface with
# 10.0.2.15/24 and an ICMP echo goes to the QEMU user-network gateway,
# which is the only path that exercises the NIC.
#
# TCP is a loopback echo: a listener announces 9999, a client connects
# to 127.0.0.1!9999, and the listener sends back what it reads.  That
# is the handshake, the sequence arithmetic and an ordered stream in
# both directions.
#
# Last, the host namespace: #~/ns mounted at /n/remote and a file read
# through it, when the loader offers the channel.
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
Nicport:	con "45999";	# the host's echo server, reached through slirp

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

Pingread: con 8000;	# ms to wait: slirp under TCG can take seconds

pingread(d: ref Sys->FD, rep: array of byte, got: chan of int)
{
	got <-= sys->read(d, rep, len rep);
}

pingtimer(t: chan of int, ms: int)
{
	sys->sleep(ms);
	t <-= 1;
}

#
# One ICMP echo to addr, through a conversation of its own.  Returns 0
# on a reply and -1 otherwise; the caller decides whether that is a
# failure.  The reply is waited for with a bound, so a wrong answer
# prints the driver's counters instead of hanging the boot.
#
ping(addr: string): int
{
	c: ref Sys->FD;
	n: int;
	conv: string;

	(c, conv) = clone("/net/icmp");
	if(c == nil){
		sys->print("nettest: clone icmp: %r\n");
		return -1;
	}
	if(sys->fprint(c, "%s", "connect " + addr + "!1") < 0){
		sys->print("nettest: icmp connect %s: %r\n", addr);
		return -1;
	}
	d := sys->open("/net/icmp/" + conv + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("nettest: open icmp data: %r\n");
		return -1;
	}
	req := array[Ipsize + Hdrsize + 8] of byte;
	req[Ipsize] = byte Echoreq;
	req[Ipsize + 7] = byte 1;
	if(sys->write(d, req, len req) != len req){
		sys->print("nettest: icmp write to %s: %r\n", addr);
		return -1;
	}
	rep := array[256] of byte;
	got := chan[1] of int;
	spawn pingread(d, rep, got);
	t := chan[1] of int;
	spawn pingtimer(t, Pingread);
	alt {
	n = <-got =>
		;
	<-t =>
		sys->print("nettest: no echo reply from %s in %d ms\n", addr, Pingread);
		return -1;
	}
	if(n < Ipsize + Hdrsize || int rep[Ipsize] != Echoreply){
		sys->print("nettest: no echo reply from %s\n", addr);
		return -1;
	}
	sys->print("nettest: icmp echo reply from %s (%d bytes)\n", addr, n);
	return 0;
}

dumpfile(path: string)
{
	fd: ref Sys->FD;

	fd = sys->open(path, Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	sys->print("nettest: %s:\n%s\n", path, string buf[0:n]);
}

tcplistener(sync: chan of int)
{
	a: ref Sys->FD;
	aconv: string;

	(a, aconv) = clone("/net/tcp");
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
	if(sys->bind("#l", "/net", Sys->MAFTER) < 0)
		sys->print("nettest: bind #l /net: %r\n");
	sys->print("nettest: #I bound at /net\n");

	spawn watchdog();

	#
	# Loopback first: it is always there, and the TCP echo below uses
	# it whatever else the machine has.
	#
	(ifc, ifcno) := clone("/net/ipifc");
	if(ifc == nil)
		fail("clone ipifc: " + sys->sprint("%r"));
	if(sys->fprint(ifc, "bind loopback") < 0)
		fail("bind loopback: " + sys->sprint("%r"));
	if(sys->fprint(ifc, "add 127.0.0.1 255.0.0.0") < 0)
		fail("add 127.0.0.1/8: " + sys->sprint("%r"));
	sys->print("nettest: 127.0.0.1/8 on ipifc %s\n", ifcno);

	#
	# The card, when there is one.  devether makes ether0 whether or
	# not a driver filled it in; a driver that did leaves the device's
	# address in /net/ether0/addr, and an unfilled one is all zeroes.
	#
	ether := 0;
	if((afd := sys->open("/net/ether0/addr", Sys->OREAD)) != nil) {
		abuf := array[64] of byte;
		an := sys->read(afd, abuf, len abuf);
		for(i := 0; i < an; i++){
			c := int abuf[i];
			if(c != '0' && c != ':' && c != '\n'){
				ether = 1;
				break;
			}
		}
	}
	if(ether){
		(eifc, eifcno) := clone("/net/ipifc");
		if(eifc == nil)
			fail("clone ipifc for ether: " + sys->sprint("%r"));
		if(sys->fprint(eifc, "bind ether /net/ether0") < 0)
			fail("bind ether /net/ether0: " + sys->sprint("%r"));
		if(sys->fprint(eifc, "add 10.0.2.15 255.255.255.0") < 0)
			fail("add 10.0.2.15/24: " + sys->sprint("%r"));
		sys->print("nettest: ether0 up at 10.0.2.15/24 on ipifc %s\n", eifcno);
	} else
		sys->print("nettest: no ethernet device\n");

	if(ether){
		if(ping("10.0.2.2") < 0){
			dumpfile("/net/ether0/stats");
			dumpfile("/net/ether0/ifstats");
			fail("no ICMP reply from the gateway");
		}

		#
		# And TCP across the card: slirp forwards 10.0.2.2 to the
		# host's loopback, where the harness has an echo server.
		# This is the handshake and the ordered stream travelling
		# over virtio rather than over loopback.
		#
		(nc, nconv) := clone("/net/tcp");
		if(nc == nil)
			fail("clone tcp for ether: " + sys->sprint("%r"));
		if(sys->fprint(nc, "connect 10.0.2.2!" + Nicport) < 0)
			fail("tcp/ether connect: " + sys->sprint("%r"));
		nd := sys->open("/net/tcp/" + nconv + "/data", Sys->ORDWR);
		if(nd == nil)
			fail("open tcp/ether data: " + sys->sprint("%r"));
		nmsg := array of byte "hello-nic";
		if(sys->write(nd, nmsg, len nmsg) != len nmsg)
			fail("tcp/ether write: " + sys->sprint("%r"));
		nbuf := array[64] of byte;
		nn := sys->read(nd, nbuf, len nbuf);
		if(nn != len nmsg || string nbuf[0:nn] != "hello-nic")
			fail(sys->sprint("tcp/ether echo: read %d: %r", nn));
		sys->print("nettest: tcp echo over ether0\n");
	} else {
		if(ping("127.0.0.1") < 0)
			fail("no ICMP reply from loopback");
	}

	#
	# TCP over loopback: a listener announces 9999, this connects to
	# it, and the listener echoes.  The sequence comparisons are where
	# LP64 broke silently elsewhere in this tree, so a wrong answer
	# stalls the connection rather than corrupting it.
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
	# The host namespace, when this loader offers one.
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
