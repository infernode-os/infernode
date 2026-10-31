implement Iplocktest;

#
# The interface lock after an unanswerable IPv6 datagram (#721).
#
# A UDP datagram for a port nobody listens on is answered with an ICMPv6
# port unreachable by icmphostunr (os/ip/icmp6.c), which takes the
# interface's read lock to find a source address. It used to keep it:
# both returns of its non-free path left the lock held, so the first
# such datagram put the interface's read count up for ever, and the next
# writer -- dhcp's "remove 0.0.0.0 0.0.0.0", say -- waited for a reader
# that was never coming back, holding the outer lock, which then failed
# every reader on the interface as well. On the bench that was a Wi-Fi
# that authenticated and never got an address; on the wired side it was
# an interface that went silent the moment anything wrote to its ctl.
#
# This does exactly that, on an interface of its own bound to the
# loopback medium so that nothing else is at risk: add ::1, send one
# datagram to ::1!9, and then write "remove" from a process of its own
# with a watchdog on it. The remove returns, or the lock is leaked.
#
# The datagram's path is checked, not assumed: /net/udp/stats says how
# many datagrams found no conversation, and that must go up by one.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Iplocktest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Watchdog: con 5000;	# ms a remove may take before it is a hang

say(s: string)
{
	sys->print("iplocktest: %s\n", s);
}

# a conversation's number from its clone file, which stays open as its ctl
clone(path: string): (ref Sys->FD, string)
{
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return (nil, nil);
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return (nil, nil);
	return (fd, string buf[0:n]);
}

# the NoPorts line of /net/udp/stats: datagrams that found no conversation
noports(): int
{
	fd := sys->open("/net/udp/stats", Sys->OREAD);
	if(fd == nil)
		return -1;
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return -1;
	s := string buf[0:n];
	for(i := 0; i < len s; i++){
		if(s[i:] != nil && len s[i:] >= 8 && s[i:i+8] == "NoPorts:"){
			v := 0;
			for(j := i+8; j < len s && s[j] != '\n'; j++)
				if(s[j] >= '0' && s[j] <= '9')
					v = v*10 + (s[j] - '0');
			return v;
		}
	}
	return -1;
}

# the writer under test: a ctl write, timed, from a process of its own
writer(ifc: ref Sys->FD, cmd: string, done: chan of int)
{
	t0 := sys->millisec();
	if(sys->fprint(ifc, "%s", cmd) < 0)
		sys->print("iplocktest: %s failed: %r\n", cmd);
	done <-= sys->millisec() - t0;
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	(ifc, ifcno) := clone("/net/ipifc/clone");
	if(ifc == nil){
		sys->print("iplocktest: FAIL: cannot make an interface: %r\n");
		return;
	}
	if(sys->fprint(ifc, "bind loopback") < 0){
		sys->print("iplocktest: FAIL: bind loopback: %r\n");
		return;
	}
	if(sys->fprint(ifc, "add ::1 /128") < 0){
		sys->print("iplocktest: FAIL: add ::1: %r\n");
		return;
	}
	say(sys->sprint("::1/128 on ipifc %s (loopback)", ifcno));

	before := noports();

	# one datagram to a port with no conversation on it
	(udp, udpno) := clone("/net/udp/clone");
	if(udp == nil || sys->fprint(udp, "connect ::1!9") < 0){
		sys->print("iplocktest: FAIL: udp connect ::1!9: %r\n");
		return;
	}
	data := sys->open("/net/udp/" + udpno + "/data", Sys->OWRITE);
	if(data == nil || sys->write(data, array of byte "nobody home", 11) != 11){
		sys->print("iplocktest: FAIL: udp write: %r\n");
		return;
	}
	sys->sleep(300);		# loopbackread delivers it; udpiput finds no conversation
	after := noports();
	say(sys->sprint("udp NoPorts %d -> %d (the datagram reached udpiput with no conversation)", before, after));
	if(before < 0 || after != before + 1)
		say("FAIL: the datagram did not take the path under test");

	# the writer that used to hang for ever
	done := chan of int;
	late := chan of int;
	spawn writer(ifc, "remove ::1 /128", done);
	spawn timer(Watchdog, late);
	alt {
	ms := <-done =>
		if(before >= 0 && after == before + 1)
			say(sys->sprint("PASS: remove ::1 returned in %d ms after an unanswerable IPv6 datagram; the interface lock is balanced", ms));
		else
			say(sys->sprint("remove ::1 returned in %d ms, but see above", ms));
		sys->fprint(ifc, "unbind");
	<-late =>
		say(sys->sprint("FAIL: remove ::1 has not returned after %d ms: the interface's read lock was leaked by the unreachable reply (#721)", Watchdog));
	}
}
