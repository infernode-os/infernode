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
#	LE credit-based channels (4.22-4.24, 10.1) the same way: the
#	parameters exchanged, an SDU cut into K-frames and put back
#	together, a sender stalled for want of credit and released by it,
#	refusal on an unencrypted link, and a peer that breaks each of the
#	rules the receiver must police.
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
	Sendable =>	sendables++;
	}
}

sendables := 0;

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

# an open LE channel between two fresh links: (a, b, ca, cb, sa, sb)
lepair(t: ref T, psm: int): (ref Link, ref Link, ref Chan, ref Chan, ref Seen, ref Seen)
{
	a := Link.new(16r42);
	b := Link.new(16r42);
	a.encrypted = b.encrypted = 1;
	b.accept = psm :: nil;
	sa := ref Seen(nil, nil, nil, nil);
	sb := ref Seen(nil, nil, nil, nil);
	(ca, evs) := a.leconnect(psm);
	if(ca == nil)
		t.fatal("leconnect gave no channel");
	pump(a, b, evs, sa, sb);
	if(sb.opened == nil || sa.opened == nil)
		t.fatal("the LE channel did not open");
	return (a, b, ca, hd sb.opened, sa, sb);
}

# one frame, as the peer's controller would deliver it
feed(l: ref Link, f: array of byte): list of ref Ev
{
	evs: list of ref Ev;
	for(pl := l2cap->fragment(l.handle, f, Aclmtu); pl != nil; pl = tl pl)
		evs = cat(evs, l.recv(hd pl));
	return evs;
}

# is this event a Disconnection Request on the LE signalling channel?
isledisc(e: ref Ev): int
{
	pick ev := e {
	Send =>
		return bthci->get2(ev.frame, 2) == L2cap->Cidlesig && int ev.frame[4] == L2cap->Cdiscreq;
	}
	return 0;
}

pattern(n: int): array of byte
{
	d := array[n] of byte;
	for(i := 0; i < n; i++)
		d[i] = byte (i * 7 + (i >> 8));
	return d;
}

testLeConnectAndData(t: ref T)
{
	(a, b, ca, cb, sa, sb) := lepair(t, 16r80);

	t.asserteq(len sb.incoming, 1, "the acceptor saw an incoming LE channel");
	t.asserteq(ca.state, L2cap->Open, "open on the response, with no configuration phase");
	t.asserteq(cb.state, L2cap->Open, "and at the acceptor on its own response");
	t.assert(ca.le && cb.le, "both know it is credit-based");
	t.asserteq(ca.dcid, cb.scid, "the initiator's destination is the acceptor's source CID");
	t.asserteq(cb.dcid, ca.scid, "and the other way");
	t.assert(ca.scid >= L2cap->Cidledyn && ca.scid <= L2cap->Cidlemax, "an LE dynamic CID");
	t.asserteq(ca.mtu, L2cap->Lemtu, "each learned the other's MTU");
	t.asserteq(cb.mps, L2cap->Lemps, "and MPS");
	t.asserteq(ca.txcredits, L2cap->Lecredits, "and was given its initial credits");
	t.asserteq(cb.txcredits, L2cap->Lecredits, "both ways");

	# a small SDU: one K-frame, one credit
	pump(a, b, a.send(ca, array of byte "Tversion"), sa, sb);
	t.asserteq(len sb.data, 1, "one SDU arrived");
	if(sb.data != nil){
		(c, sdu) := hd sb.data;
		t.assert(c == cb, "on its channel");
		t.assertseq(string sdu, "Tversion", "intact");
	}
	t.asserteq(ca.txcredits, L2cap->Lecredits - 1, "at the cost of one credit");

	# the largest SDU: 2048 + 2 bytes of length is five K-frames of 512
	whole := pattern(L2cap->Lemtu);
	pump(b, a, b.send(cb, whole), sb, sa);
	t.asserteq(len sa.data, 1, "the largest SDU arrived as one");
	if(sa.data != nil){
		(nil, sdu) := hd sa.data;
		t.assert(sameb(sdu, whole), "put back together from its K-frames, byte for byte");
	}
	t.assert(a.send(ca, array[L2cap->Lemtu + 1] of byte) == nil, "an SDU over the peer's MTU is not sent");

	# an empty SDU is a K-frame holding only its length
	pump(a, b, a.send(ca, array[0] of byte), sa, sb);
	t.asserteq(len sb.data, 2, "an empty SDU arrives");
	if(sb.data != nil){
		(nil, sdu) := hd sb.data;
		t.asserteq(len sdu, 0, "empty");
	}

	# hang up: on the LE signalling channel, not the classic one
	evs := a.disconnect(ca);
	t.assert(evs != nil && isledisc(hd evs), "the Disconnection Request goes on the LE signalling channel");
	pump(a, b, evs, sa, sb);
	t.asserteq(ca.state, L2cap->Closed, "initiator Closed");
	t.asserteq(cb.state, L2cap->Closed, "acceptor Closed");
	t.assert(a.find(ca.scid) == nil && b.find(cb.scid) == nil, "and forgotten at both ends");
}

testLeCredits(t: ref T)
{
	(a, b, ca, cb, sa, sb) := lepair(t, 16r81);
	sendables = 0;

	# forty SDUs of 600 bytes, two K-frames each, written before the
	# peer has been heard from: sixteen go, sixty-four wait
	out: list of ref Ev;
	for(i := 0; i < 40; i++){
		d := pattern(600);
		d[0] = byte i;
		out = cat(out, a.send(ca, d));
	}
	t.asserteq(len out, L2cap->Lecredits, "only as many K-frames leave as there are credits");
	t.asserteq(ca.txcredits, 0, "the credits are spent");
	t.asserteq(ca.queued(), 80 - L2cap->Lecredits, "and the rest wait in the channel");

	# let the peer answer: it returns credit as it consumes, and the queue drains
	pump(a, b, out, sa, sb);
	t.asserteq(len sb.data, 40, "every SDU arrived once the credits came back");
	t.asserteq(ca.queued(), 0, "nothing left waiting");
	t.assert(sendables > 0, "and the writer was told the queue had drained");
	n := 39;
	for(dl := sb.data; dl != nil; dl = tl dl){
		(nil, sdu) := hd dl;
		if(len sdu != 600 || int sdu[0] != n){
			t.error(sys->sprint("SDU %d out of order or damaged (len %d first %d)", n, len sdu, int sdu[0]));
			break;
		}
		n--;
	}
	t.assert(cb.rxcredits > L2cap->Lecredits/2, "the receiver kept its grant topped up");
}

testLeRefused(t: ref T)
{
	a := Link.new(3);
	b := Link.new(3);
	b.accept = 16r80 :: nil;
	sa := ref Seen(nil, nil, nil, nil);
	sb := ref Seen(nil, nil, nil, nil);

	# the link is not encrypted, and a fresh Link wants it to be
	(ca, evs) := a.leconnect(16r80);
	pump(a, b, evs, sa, sb);
	t.asserteq(len sb.incoming, 0, "nothing opens on an unencrypted link");
	t.asserteq(len sa.closed, 1, "the initiator is told");
	if(sa.closed != nil){
		(nil, why) := hd sa.closed;
		t.assertseq(why, "connection refused: insufficient authentication", "to pair and ask again");
	}
	t.assert(a.find(ca.scid) == nil, "and its channel is gone");

	# encrypted, but nobody announced the PSM
	a.encrypted = b.encrypted = 1;
	sa.closed = nil;
	(nil, evs) = a.leconnect(16r99);
	pump(a, b, evs, sa, sb);
	if(sa.closed == nil)
		t.fatal("no refusal for an unannounced PSM");
	(nil, why) := hd sa.closed;
	t.assertseq(why, "connection refused: PSM not supported", "an unannounced PSM is refused");

	# a caller that says its PSM needs no encryption gets none asked of it
	b.needenc = 0;
	b.encrypted = 0;
	(nil, evs) = a.leconnect(16r80);
	pump(a, b, evs, sa, sb);
	t.asserteq(len sb.opened, 1, "needenc off: the channel opens in the clear");

	# 64 CIDs and no more
	c := Link.new(4);
	for(i := 0; i < 64; i++){
		(cc, nil) := c.leconnect(16r80);
		if(cc == nil)
			t.fatal(sys->sprint("CID space ran out at %d", i));
	}
	(cc, nil) := c.leconnect(16r80);
	t.assert(cc == nil, "the sixty-fifth LE channel on a link is not made");
}

testLeMisbehaviour(t: ref T)
{
	# a K-frame with no credit to pay for it
	(a, b, ca, cb, sa, sb) := lepair(t, 16r82);
	cb.rxcredits = 0;
	kf := array[2+1] of byte;
	bthci->put2(kf, 0, 1);
	kf[2] = byte 'x';
	evs := feed(b, l2cap->frame(cb.scid, kf));
	t.assert(evs != nil && isledisc(hd evs), "a K-frame sent without credit disconnects the channel");
	pump(b, a, evs, sb, sa);
	t.asserteq(ca.state, L2cap->Closed, "at both ends");
	t.asserteq(len sb.data, 0, "and its data is not delivered");

	# an SDU that claims more than our MTU
	(a, b, ca, cb, sa, sb) = lepair(t, 16r82);
	bthci->put2(kf, 0, L2cap->Lemtu + 1);
	evs = feed(b, l2cap->frame(cb.scid, kf));
	t.assert(evs != nil && isledisc(hd evs), "an SDU longer than our MTU disconnects");

	# a K-frame longer than our MPS
	(a, b, ca, cb, sa, sb) = lepair(t, 16r82);
	long := array[L2cap->Lemps + 1] of { * => byte 0 };
	bthci->put2(long, 0, L2cap->Lemps - 1);
	evs = feed(b, l2cap->frame(cb.scid, long));
	t.assert(evs != nil && isledisc(hd evs), "a K-frame over our MPS disconnects");

	# more bytes than the SDU said it had
	(a, b, ca, cb, sa, sb) = lepair(t, 16r82);
	over := array[2+10] of { * => byte 0 };
	bthci->put2(over, 0, 4);
	evs = feed(b, l2cap->frame(cb.scid, over));
	t.assert(evs != nil && isledisc(hd evs), "an SDU that overruns its own length disconnects");
	t.asserteq(len sb.data, 0, "and nothing of it is delivered");

	# credit beyond what can be counted
	(a, b, ca, cb, sa, sb) = lepair(t, 16r82);
	cr := array[4] of byte;
	bthci->put2(cr, 0, cb.scid);
	bthci->put2(cr, 2, 65535);
	evs = feed(a, l2cap->frame(L2cap->Cidlesig, l2cap->sigcmd(L2cap->Clecredit, 9, cr)));
	t.assert(evs != nil && isledisc(hd evs), "credit past 65535 disconnects");

	# a link going down takes its LE channels and their queues with it
	(a, b, ca, cb, sa, sb) = lepair(t, 16r82);
	for(i := 0; i < 20; i++)
		a.send(ca, pattern(600));
	t.assert(ca.queued() > 0, "frames are waiting");
	for(el := a.down("link lost"); el != nil; el = tl el)
		note(sa, hd el);
	t.asserteq(len sa.closed, 1, "the channel closes with the link");
	t.asserteq(ca.state, L2cap->Closed, "Closed");
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
	run("ConnectAndData", testConnectAndData);
	run("Refused", testRefused);
	run("RemoteHangupAndDown", testRemoteHangupAndDown);
	run("InfoEchoAndJunk", testInfoEchoAndJunk);
	run("LeConnectAndData", testLeConnectAndData);
	run("LeCredits", testLeCredits);
	run("LeRefused", testLeRefused);
	run("LeMisbehaviour", testLeMisbehaviour);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
