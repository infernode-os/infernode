implement L2capTest;

#
#	l2cap(2): two Links driven against each other, every frame from
#	one fragmented into ACL packets and fed to the other, as a
#	controller pair would. Connection, configuration, data both ways,
#	disconnection from either side, refusal of a PSM nobody announced,
#	reassembly of a frame split across fragments, and the information
#	request every real peer sends first. Layouts are the Core
#	Specification's, Vol 3 Part A 3 and 4.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "bthci.m";
	bthci: Bthci;
	Pkt: import bthci;

include "l2cap.m";
	l2cap: L2cap;
	Link, Chan, Ev: import l2cap;

L2capTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/l2cap_test.b";

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

Aclmtu: con 27;	# small, so every signalling frame fragments

# what one side saw, apart from frames
Seen: adt {
	opened:	list of ref Chan;
	incoming: list of ref Chan;
	closed:	list of (ref Chan, string);
	data:	list of (ref Chan, array of byte);
};

# deliver a's events to b and b's to a until nothing more moves; in
# order, as a link delivers them
pump(a, b: ref Link, evs: list of ref Ev, sa, sb: ref Seen)
{
	fromb: list of ref Ev;
	for(round := 0; round < 50 && (evs != nil || fromb != nil); round++){
		# a's output to b
		next: list of ref Ev;
		for(; evs != nil; evs = tl evs){
			pick e := hd evs {
			Send =>
				for(pl := l2cap->fragment(a.handle, e.frame, Aclmtu); pl != nil; pl = tl pl)
					fromb = cat(fromb, b.recv(hd pl));
			* =>
				note(sa, hd evs);
			}
		}
		# b's output to a
		for(; fromb != nil; fromb = tl fromb){
			pick e := hd fromb {
			Send =>
				for(pl := l2cap->fragment(b.handle, e.frame, Aclmtu); pl != nil; pl = tl pl)
					next = cat(next, a.recv(hd pl));
			* =>
				note(sb, hd fromb);
			}
		}
		evs = next;
	}
}

cat(l, m: list of ref Ev): list of ref Ev
{
	if(l == nil)
		return m;
	return hd l :: cat(tl l, m);
}

note(s: ref Seen, e: ref Ev)
{
	pick ev := e {
	Opened =>	s.opened = ev.c :: s.opened;
	Incoming =>	s.incoming = ev.c :: s.incoming;
	Closed =>	s.closed = (ev.c, ev.reason) :: s.closed;
	Data =>		s.data = (ev.c, ev.sdu) :: s.data;
	}
}

sameb(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

testConnectAndData(t: ref T)
{
	a := Link.new(16r41);
	b := Link.new(16r41);
	b.accept = 16r1001 :: nil;
	sa := ref Seen(nil, nil, nil, nil);
	sb := ref Seen(nil, nil, nil, nil);

	(ca, evs) := a.connect(16r1001);
	t.asserteq(ca.state, L2cap->Waitconn, "the initiator waits for a connection response");
	pump(a, b, evs, sa, sb);

	t.asserteq(len sb.incoming, 1, "the acceptor saw an incoming connection");
	t.asserteq(len sa.opened, 1, "the initiator's channel opened");
	t.asserteq(len sb.opened, 1, "the acceptor's channel opened");
	t.asserteq(ca.state, L2cap->Open, "initiator state Connected");
	if(sb.opened == nil)
		t.fatal("no channel on the acceptor");
	cb := hd sb.opened;
	t.asserteq(cb.state, L2cap->Open, "acceptor state Connected");
	t.asserteq(cb.psm, 16r1001, "on the PSM asked for");
	t.asserteq(ca.dcid, cb.scid, "the initiator's destination is the acceptor's source CID");
	t.asserteq(cb.dcid, ca.scid, "and the other way");
	t.asserteq(ca.mtu, L2cap->Ourmtu, "each learned the other's MTU");
	t.asserteq(cb.mtu, L2cap->Ourmtu, "both ways");
	t.assert(ca.scid >= L2cap->Ciddyn && cb.scid >= L2cap->Ciddyn, "CIDs are dynamic");

	# data a -> b: 100 bytes, so it fragments across four ACL packets
	msg := array[100] of byte;
	for(i := 0; i < len msg; i++)
		msg[i] = byte i;
	pump(a, b, a.send(ca, msg), sa, sb);
	t.asserteq(len sb.data, 1, "one SDU arrived at b");
	if(sb.data != nil){
		(c, sdu) := hd sb.data;
		t.assert(c == cb, "on its channel");
		t.assert(sameb(sdu, msg), "intact across fragments");
	}
	# and b -> a
	pump(b, a, b.send(cb, array of byte "pong"), sb, sa);
	t.asserteq(len sa.data, 1, "one SDU arrived at a");
	if(sa.data != nil){
		(nil, sdu) := hd sa.data;
		t.assertseq(string sdu, "pong", "the reply");
	}

	# an SDU larger than the peer's MTU is refused locally
	toolarge := array[L2cap->Ourmtu + 1] of byte;
	t.assert(a.send(ca, toolarge) == nil, "an SDU over the peer's MTU is not sent");

	# hang up from the initiator
	pump(a, b, a.disconnect(ca), sa, sb);
	t.asserteq(len sa.closed, 1, "initiator saw its channel close");
	t.asserteq(len sb.closed, 1, "acceptor saw the hangup");
	if(sb.closed != nil){
		(nil, why) := hd sb.closed;
		t.assertseq(why, "remote hangup", "as a remote hangup");
	}
	t.asserteq(ca.state, L2cap->Closed, "initiator Closed");
	t.asserteq(cb.state, L2cap->Closed, "acceptor Closed");
	t.assert(a.find(ca.scid) == nil, "and forgotten");
}

testRefused(t: ref T)
{
	a := Link.new(1);
	b := Link.new(1);
	sa := ref Seen(nil, nil, nil, nil);
	sb := ref Seen(nil, nil, nil, nil);
	(ca, evs) := a.connect(16r1005);	# b announced nothing
	pump(a, b, evs, sa, sb);
	t.asserteq(len sa.closed, 1, "the initiator's channel closed");
	if(sa.closed != nil){
		(nil, why) := hd sa.closed;
		t.assertseq(why, "connection refused: PSM not supported", "because the PSM is not served");
	}
	t.asserteq(ca.state, L2cap->Closed, "and is Closed");
	t.asserteq(len sb.incoming, 0, "the acceptor saw nothing incoming");
	t.assert(b.chans == nil, "and made no channel");
}

testRemoteHangupAndDown(t: ref T)
{
	a := Link.new(7);
	b := Link.new(7);
	b.accept = 3 :: nil;
	sa := ref Seen(nil, nil, nil, nil);
	sb := ref Seen(nil, nil, nil, nil);
	(ca, evs) := a.connect(3);
	pump(a, b, evs, sa, sb);
	if(sb.opened == nil)
		t.fatal("no channel");
	cb := hd sb.opened;
	# the acceptor hangs up
	pump(b, a, b.disconnect(cb), sb, sa);
	t.asserteq(len sa.closed, 1, "initiator saw the remote hangup");
	t.asserteq(len sb.closed, 1, "acceptor saw its own");
	t.asserteq(ca.state, L2cap->Closed, "initiator Closed");

	# a link that dies closes every channel on it, with the reason
	(c1, e1) := a.connect(3);
	pump(a, b, e1, sa, sb);
	(c2, e2) := a.connect(3);
	pump(a, b, e2, sa, sb);
	t.asserteq(c1.state + c2.state, 2 * L2cap->Open, "two channels open");
	evs = a.down("link lost");
	t.asserteq(len evs, 2, "down closes both");
	t.asserteq(c1.state, L2cap->Closed, "first Closed");
	t.asserteq(c2.state, L2cap->Closed, "second Closed");
	t.assert(a.chans == nil, "and the link is empty");
}

testInfoEchoAndJunk(t: ref T)
{
	a := Link.new(9);
	# an Information Request for extended features, as a peer sends before connecting
	d := array[2] of byte;
	bthci->put2(d, 0, 2);
	req := l2cap->frame(L2cap->Cidsig, l2cap->sigcmd(L2cap->Cinforeq, 16r2a, d));
	evs := a.recv(hd l2cap->fragment(9, req, 1000));
	t.asserteq(len evs, 1, "one reply");
	if(evs != nil){
		pick e := hd evs {
		Send =>
			f := e.frame;
			t.asserteq(bthci->get2(f, 2), L2cap->Cidsig, "on the signalling channel");
			t.asserteq(int f[4], L2cap->Cinforsp, "an Information Response");
			t.asserteq(int f[5], 16r2a, "with the request's identifier");
			t.asserteq(bthci->get2(f, 8), 2, "for the type asked");
			t.asserteq(bthci->get2(f, 10), 0, "result success");
			t.asserteq(bthci->get4(f, 12), 0, "no extended features: basic mode");
		* =>
			t.error("not a Send");
		}
	}
	# an echo request comes back as an echo response with the same data
	echo := l2cap->frame(L2cap->Cidsig, l2cap->sigcmd(L2cap->Cechoreq, 5, array of byte "hi"));
	evs = a.recv(hd l2cap->fragment(9, echo, 1000));
	if(evs != nil){
		pick e := hd evs {
		Send =>
			t.asserteq(int e.frame[4], L2cap->Cechorsp, "echo response");
			t.assertseq(string e.frame[8:], "hi", "with the data");
		* =>
			t.error("not a Send");
		}
	}
	# data for a CID nobody has is dropped, not delivered
	junk := l2cap->frame(16r55, array of byte "nope");
	t.assert(a.recv(hd l2cap->fragment(9, junk, 1000)) == nil, "data on an unknown CID is dropped");
	# a packet for another handle is not ours
	other := hd l2cap->fragment(10, echo, 1000);
	t.assert(a.recv(other) == nil, "a packet for another handle is ignored");
	# a continuation with no start is dropped
	frags := l2cap->fragment(9, echo, 5);
	t.assert(len frags > 1, "the echo fragments at 5 bytes");
	t.assert(a.recv(hd tl frags) == nil, "a continuation without its start is dropped");
	# an unknown command is rejected
	bad := l2cap->frame(L2cap->Cidsig, l2cap->sigcmd(16r7f, 3, nil));
	evs = a.recv(hd l2cap->fragment(9, bad, 1000));
	if(evs != nil){
		pick e := hd evs {
		Send =>
			t.asserteq(int e.frame[4], L2cap->Creject, "an unknown command is rejected");
		* =>
			t.error("not a Send");
		}
	}
}

testFragment(t: ref T)
{
	f := array[60] of byte;
	for(i := 0; i < len f; i++)
		f[i] = byte i;
	l := l2cap->fragment(16r123, f, 27);
	t.asserteq(len l, 3, "60 bytes at 27 per packet is three packets");
	p := hd l;
	t.asserteq(bthci->get2(p.data, 0), 16r123 | (2<<12), "the first carries the handle and the start flag");
	t.asserteq(bthci->get2(p.data, 2), 27, "and 27 bytes");
	p = hd tl l;
	t.asserteq(bthci->get2(p.data, 0), 16r123 | (1<<12), "the second is a continuation");
	p = hd tl tl l;
	t.asserteq(bthci->get2(p.data, 2), 6, "the last carries the remainder");
	t.asserteq(int p.data[4], 54, "which is the right remainder");
}

#
# One L2CAP signalling command, as the ACL packets that carry it.
#
sigpkts(handle, code, id: int, d: array of byte): list of ref Bthci->Pkt
{
	f := array[4+4+len d] of byte;
	n := 4 + len d;
	f[0] = byte n; f[1] = byte (n>>8);
	f[2] = byte L2cap->Cidsig; f[3] = byte 0;
	f[4] = byte code; f[5] = byte id;
	f[6] = byte len d; f[7] = byte (len d >> 8);
	f[8:] = d;
	return l2cap->fragment(handle, f, 1024);
}

deliver(l: ref Link, pl: list of ref Bthci->Pkt): list of ref Ev
{
	evs: list of ref Ev;
	for(; pl != nil; pl = tl pl)
		evs = cat(evs, l.recv(hd pl));
	return evs;
}

# the result field of the first Connection Response among the events, or -1
connresult(evs: list of ref Ev): int
{
	for(; evs != nil; evs = tl evs)
		pick e := hd evs {
		Send =>
			f := e.frame;
			if(len f >= 8+8 && int f[4] == L2cap->Cconnrsp)
				return int f[12] | int f[13]<<8;
		}
	return -1;
}

connreq(psm, scid: int): array of byte
{
	d := array[4] of byte;
	d[0] = byte psm; d[1] = byte (psm>>8);
	d[2] = byte scid; d[3] = byte (scid>>8);
	return d;
}

#
# A peer may hold Maxchans channels on a link and no more, one for each of
# its own channel ids; a source id is never given to two live channels.
#
testChannelBound(t: ref T)
{
	b := Link.new(16r41);
	b.accept = 16r1001 :: nil;

	# requests that are never configured: each stays half open for ever
	for(i := 0; i < L2cap->Maxchans; i++){
		evs := deliver(b, sigpkts(16r41, L2cap->Cconnreq, 1+(i&16r7f), connreq(16r1001, L2cap->Ciddyn+i)));
		if(connresult(evs) != L2cap->Rok){
			t.fatal(sys->sprint("request %d of %d was refused", i+1, L2cap->Maxchans));
			return;
		}
	}
	t.asserteq(len b.chans, L2cap->Maxchans, "the link holds as many channels as it may");

	evs := deliver(b, sigpkts(16r41, L2cap->Cconnreq, 5, connreq(16r1001, L2cap->Ciddyn+1000)));
	t.asserteq(connresult(evs), L2cap->Rnoresources, "one more is refused: no resources");
	t.asserteq(len b.chans, L2cap->Maxchans, "and makes no channel");
	for(e := evs; e != nil; e = tl e)
		pick ev := hd e {
		Incoming =>
			t.error("a refused request was announced as incoming");
		}

	# a second request from the same source id is not a second channel
	c := Link.new(16r42);
	c.accept = 16r1001 :: nil;
	evs = deliver(c, sigpkts(16r42, L2cap->Cconnreq, 1, connreq(16r1001, 16r50)));
	t.asserteq(connresult(evs), L2cap->Rok, "a first request is accepted");
	evs = deliver(c, sigpkts(16r42, L2cap->Cconnreq, 2, connreq(16r1001, 16r50)));
	t.asserteq(connresult(evs), L2cap->Rnoresources, "the same source id again is refused");
	t.asserteq(len c.chans, 1, "one channel for one source id");

	# the id counter coming round does not hand out an id in use
	d := Link.new(16r43);
	(c1, nil) := d.connect(16r1001);
	d.nextcid = c1.scid;	# as it will be after 65472 more allocations
	(c2, nil) := d.connect(16r1001);
	t.assert(c1.scid != c2.scid, "two live channels have two source ids");
	t.assert(d.find(c1.scid) == c1 && d.find(c2.scid) == c2, "and each is found by its own");
}

#
# A Connection Response is ours only if it names our channel, and opens
# nothing on a fixed channel id.
#
testConnectResponse(t: ref T)
{
	a := Link.new(16r41);
	(ca, nil) := a.connect(16r1001);
	t.asserteq(ca.state, L2cap->Waitconn, "waiting for the response");

	r := array[8] of byte;
	for(i := 0; i < len r; i++)
		r[i] = byte 0;
	# dcid 0x60, scid NOT ours, result ok
	r[0] = byte 16r60; r[2] = byte (ca.scid+1); r[3] = byte ((ca.scid+1)>>8);
	deliver(a, sigpkts(16r41, L2cap->Cconnrsp, ca.ident, r));
	t.asserteq(ca.state, L2cap->Waitconn, "a response naming another channel changes nothing");

	# ours, but "accepted" on the signalling channel's own id
	r[0] = byte L2cap->Cidsig; r[1] = byte 0; r[2] = byte ca.scid; r[3] = byte (ca.scid>>8);
	deliver(a, sigpkts(16r41, L2cap->Cconnrsp, ca.ident, r));
	t.assert(ca.state != L2cap->Config && ca.state != L2cap->Open, "a response accepting on a fixed id opens no channel");
}

#
# An LE peer's connection parameters are accepted only when a controller
# could be given them.
#
testLEParams(t: ref T)
{
	cases := array[] of {
		# min, max, latency, timeout, accepted
		(6, 6, 0, 10, 1),
		(24, 40, 0, 500, 1),
		(3200, 3200, 0, 3200, 1),
		(3200, 3200, 0, 800, 0),	# the timeout is not longer than two intervals
		(800, 800, 0, 3200, 1),
		(5, 40, 0, 500, 0),	# interval below 7.5 ms
		(24, 3201, 0, 3200, 0),	# above 4 s
		(40, 24, 0, 500, 0),	# out of order
		(24, 40, 500, 3200, 0),	# latency past 499
		(24, 40, 0, 9, 0),	# timeout below 100 ms
		(24, 40, 0, 3201, 0),	# above 32 s
		(24, 40, 499, 3200, 0),	# shorter than the latency allows
		(16rC80, 6, 0, 500, 0),
		(0, 0, 0, 0, 0),
		(16rFFFF, 16rFFFF, 16rFFFF, 16rFFFF, 0),
	};
	l := Link.new(16r41);
	for(i := 0; i < len cases; i++){
		(min, max, lat, tmo, want) := cases[i];
		d := array[8] of byte;
		d[0] = byte min; d[1] = byte (min>>8);
		d[2] = byte max; d[3] = byte (max>>8);
		d[4] = byte lat; d[5] = byte (lat>>8);
		d[6] = byte tmo; d[7] = byte (tmo>>8);
		f := array[4+4+len d] of byte;
		f[0] = byte (4+len d); f[1] = byte 0;
		f[2] = byte L2cap->Cidlesig; f[3] = byte 0;
		f[4] = byte 16r12; f[5] = byte 7; f[6] = byte len d; f[7] = byte 0;
		f[8:] = d;
		evs := deliver(l, l2cap->fragment(16r41, f, 1024));
		result := -1;
		params := 0;
		for(; evs != nil; evs = tl evs)
			pick e := hd evs {
			Send =>
				if(len e.frame >= 10 && int e.frame[4] == 16r13)
					result = int e.frame[8] | int e.frame[9]<<8;
			Params =>
				params = 1;
			}
		what := sys->sprint("interval %d-%d latency %d timeout %d", min, max, lat, tmo);
		if(want){
			t.asserteq(result, 0, what+": accepted");
			t.asserteq(params, 1, what+": handed to the caller");
		}else{
			t.asserteq(result, 1, what+": rejected");
			t.asserteq(params, 0, what+": not handed to the caller");
		}
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
	bthci = load Bthci Bthci->PATH;
	l2cap = load L2cap L2cap->PATH;
	if(bthci == nil || l2cap == nil){
		sys->fprint(sys->fildes(2), "cannot load bthci or l2cap: %r\n");
		raise "fail:cannot load";
	}
	bthci->init();
	l2cap->init(bthci);

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Fragment", testFragment);
	run("ChannelBound", testChannelBound);
	run("ConnectResponse", testConnectResponse);
	run("LEParams", testLEParams);
	run("ConnectAndData", testConnectAndData);
	run("Refused", testRefused);
	run("RemoteHangupAndDown", testRemoteHangupAndDown);
	run("InfoEchoAndJunk", testInfoEchoAndJunk);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
