implement UdpEmptyTest;

#
# An empty UDP datagram read with headers is a read of the header.
#
# The hosted emulator's /net/udp (emu/port/devip.c) gives a reader in
# "headers" mode each datagram with its addresses before it.  For a
# datagram of no bytes it added the header's length only "if(r > 0)":
# the read returned 0, which every reader takes for the end of the
# file.  One empty datagram, from anyone who can reach the port, ended
# gpsfs's listened source.
#
# - four datagrams sent to a conversation announced with headers on the
#   loopback, the first and third empty: read as 52, 55, 52 and 55
#   bytes, each with its sender's port in its header, the data whole
# - datagrams sent to a port nobody listens on, then one received: the
#   read is that datagram, not an error (Windows reported the ICMP port
#   unreachable on the next read of any UDP socket)
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

UdpEmptyTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/udp_empty_test.b";
Udphdrlen: con 52;

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# a conversation announced with headers on the loopback: its data file and port
listener(base: int): (ref Sys->FD, int)
{
	for(port := base; port < base+50; port++){
		(ok, c) := sys->announce(sys->sprint("udp!127.0.0.1!%d", port));
		if(ok < 0)
			continue;
		if(sys->fprint(c.cfd, "headers") < 0)
			continue;
		fd := sys->open(c.dir + "/data", Sys->ORDWR);
		if(fd != nil)
			return (fd, port);
	}
	return (nil, 0);
}

# n bytes of data to 127.0.0.1!port, through a conversation with headers
send(fd: ref Sys->FD, port: int, data: array of byte): int
{
	p := array[Udphdrlen + len data] of {* => byte 0};
	p[10] = byte 16rff;
	p[11] = byte 16rff;
	p[12] = byte 127;
	p[15] = byte 1;
	p[48] = byte (port>>8);
	p[49] = byte port;
	p[Udphdrlen:] = data;
	return sys->write(fd, p, len p);
}

reader(fd: ref Sys->FD, n: int, c: chan of array of byte)
{
	for(i := 0; i < n; i++){
		buf := array[2048] of byte;
		r := sys->read(fd, buf, len buf);
		if(r < 0)
			r = 0;
		c <-= buf[0:r];
		if(r == 0)
			return;	# as a reader does at the end of a file
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

testEmpty(t: ref T)
{
	base := 17000 + sys->pctl(0, nil) % 4000;
	(rfd, rport) := listener(base);
	if(rfd == nil)
		t.skip(sys->sprint("no UDP on the loopback: %r"));
	(sfd, sport) := listener(rport+1);
	if(sfd == nil)
		t.skip(sys->sprint("no second UDP port on the loopback: %r"));

	what := array[] of {"", "one", "", "two"};
	got := chan of array of byte;
	spawn reader(rfd, len what, got);
	for(i := 0; i < len what; i++){
		n := send(sfd, rport, array of byte what[i]);
		t.asserteq(n, Udphdrlen + len what[i], sys->sprint("datagram %d written", i));
	}
	tc := chan of int;
	spawn timer(tc, 5000);
	for(i = 0; i < len what; i++){
		alt{
		b := <-got =>
			if(len b == 0)
				t.fatal(sys->sprint("datagram %d (%d bytes of data) read as the end of the file", i, len what[i]));
			t.asserteq(len b, Udphdrlen + len what[i], sys->sprint("datagram %d: its header and %d bytes", i, len what[i]));
			if(len b >= Udphdrlen){
				p := int b[48]<<8 | int b[49];
				t.asserteq(p, sport, sys->sprint("datagram %d: its sender's port in the header", i));
				t.assertseq(string b[Udphdrlen:], what[i], sys->sprint("datagram %d: its data", i));
			}
		<-tc =>
			t.fatal(sys->sprint("datagram %d was not read in five seconds", i));
		}
	}
}

# A datagram sent to a port nobody listens on fails no later read of an
# announced conversation: the ICMP port unreachable that answers it is
# for a peer that has gone, and a POSIX host reports it only on a
# connected socket.  Windows failed the next read of any UDP socket
# (WSAECONNRESET), and a server reading until an error (sdgsrv) ended
# when a client it had answered went away.
testUnreachable(t: ref T)
{
	base := 21000 + sys->pctl(0, nil) % 4000;
	(rfd, rport) := listener(base);
	if(rfd == nil)
		t.skip(sys->sprint("no UDP on the loopback: %r"));
	(gfd, gport) := listener(rport+1);
	if(gfd == nil)
		t.skip(sys->sprint("no second UDP port on the loopback: %r"));
	gfd = nil;	# gone: nothing listens on gport now
	(sfd, sport) := listener(gport+1);
	if(sfd == nil)
		t.skip(sys->sprint("no third UDP port on the loopback: %r"));

	for(i := 0; i < 3; i++)
		send(rfd, gport, array of byte "to nobody");
	sys->sleep(200);	# the unreachables come back
	got := chan of array of byte;
	spawn reader(rfd, 1, got);
	send(sfd, rport, array of byte "hello");
	tc := chan of int;
	spawn timer(tc, 5000);
	alt{
	b := <-got =>
		t.assert(len b == Udphdrlen + 5, sys->sprint("the read after them is the datagram sent (%d bytes)", len b));
		if(len b >= Udphdrlen){
			p := int b[48]<<8 | int b[49];
			t.asserteq(p, sport, "from its sender");
			t.assertseq(string b[Udphdrlen:], "hello", "its data");
		}
	<-tc =>
		t.fatal("the datagram was not read in five seconds");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Empty", testEmpty);
	run("Unreachable", testUnreachable);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
