implement RfcommTest;

#
# rfcomm(2): two Muxes fed each other's frames, no radio. The FCS
# against known values, a session and a DLC brought up in the order
# the specification gives, bytes both ways under credit-based flow
# control until the credits run out and come back, a refused channel,
# and the two ways down.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bthci.m";
	bthci: Bthci;
include "rfcomm.m";
	rfcomm: Rfcomm;
	Mux, Dlc, Ev: import rfcomm;
include "testing.m";
	testing: Testing;
	T: import testing;

RfcommTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/rfcomm_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	"*" => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# what one side's events mean for the other: Sends cross over, and the
# rest are collected for the test to look at
Side: adt {
	m:	ref Mux;
	opened:	list of ref Dlc;
	incoming: list of ref Dlc;
	closed:	list of (ref Dlc, string);
	got:	array of byte;
	down:	string;
	sent:	int;		# frames sent
};

# deliver evs from a to b, and whatever b says back to a, until quiet
exchange(a, b: ref Side, evs: list of ref Ev)
{
	for(rounds := 0; evs != nil && rounds < 100; rounds++){
		back: list of ref Ev;
		for(; evs != nil; evs = tl evs){
			pick e := hd evs {
			Send =>
				a.sent++;
				for(r := b.m.recv(e.sdu); r != nil; r = tl r)
					back = hd r :: back;
			Opened =>	a.opened = e.d :: a.opened;
			Incoming =>	a.incoming = e.d :: a.incoming;
			Closed =>	a.closed = (e.d, e.reason) :: a.closed;
			Data =>
				n := array[len a.got + len e.data] of byte;
				n[0:] = a.got;
				n[len a.got:] = e.data;
				a.got = n;
			Muxdown =>	a.down = e.reason;
			}
		}
		rev: list of ref Ev;
		for(; back != nil; back = tl back)
			rev = hd back :: rev;
		# now b's replies go to a
		(a, b) = (b, a);
		evs = rev;
	}
}

newside(initiator: int, accept: list of int): ref Side
{
	m := Mux.new(initiator, 672);
	m.accept = accept;
	return ref Side(m, nil, nil, nil, array[0] of byte, nil, 0);
}

testFcs(t: ref T)
{
	# SABM on DLCI 0 from the initiator: 03 3f 01, FCS 1c -- the frame
	# every RFCOMM session starts with, as btmon shows it
	f := array[] of { byte 16r03, byte 16r3f, byte 16r01 };
	t.asserteq(int rfcomm->fcs(f, 3), 16r1c, "SABM DLCI 0 has FCS 0x1c");
	m := Mux.new(1, 672);
	evs := m.start();
	t.asserteq(len evs, 1, "start sends one frame");
	pick e := hd evs {
	Send =>	t.assertseq(bthci->hex(e.sdu), "03 3f 01 1c", "and it is that frame");
	* =>	t.error("start did not send");
	}
}

testSession(t: ref T)
{
	a := newside(1, nil);		# we dial
	b := newside(0, 1 :: nil);	# the peer serves channel 1
	(d, evs) := a.m.connect(1);
	t.assert(d != nil, "a DLC to channel 1 is made");
	t.asserteq(d.dlci, 2, "the initiator's DLCI for channel 1 is 2: direction bit 0");
	exchange(a, b, evs);
	t.asserteq(a.m.up, 1, "the multiplexer came up at the initiator");
	t.asserteq(b.m.up, 1, "and at the responder");
	t.asserteq(d.state, Rfcomm->Open, "the DLC is open");
	t.asserteq(len a.opened, 1, "the initiator was told");
	t.asserteq(len b.incoming, 1, "the responder saw it arrive");
	t.asserteq(len b.opened, 1, "and open");
	pd := b.m.find(2);
	t.assert(pd != nil, "the responder has the same DLCI");
	if(pd != nil){
		t.asserteq(pd.framesize, d.framesize, "both agree on the frame size");
		t.asserteq(d.framesize, 666, "which is the L2CAP MTU less RFCOMM's six");
		t.asserteq(d.msc, 1, "our MSC was answered");
		t.asserteq(pd.msc, 1, "and theirs");
	}
	# bytes both ways
	exchange(a, b, a.m.send(d, array of byte "hello from a"));
	t.assertseq(string b.got, "hello from a", "the responder got the bytes");
	exchange(b, a, b.m.send(pd, array of byte "and back"));
	t.assertseq(string a.got, "and back", "and the initiator got the reply");
	# a second channel refused: nobody accepts 5
	(d5, evs5) := a.m.connect(5);
	exchange(a, b, evs5);
	t.asserteq(len a.closed, 1, "channel 5 was refused");
	if(a.closed != nil){
		(cd, why) := hd a.closed;
		t.assert(cd == d5, "the refusal names the DLC");
		t.assertseq(why, "refused", "with DM's meaning");
	}
	t.assert(a.m.find(d5.dlci) == nil, "and it is gone");
	# hangup from the initiator
	exchange(a, b, a.m.disconnect(d));
	t.assert(a.m.find(2) == nil, "the DLC is gone at the initiator");
	t.assert(b.m.find(2) == nil, "and at the responder");
	t.asserteq(len b.closed, 1, "who was told hangup");
	# and the session
	exchange(a, b, a.m.shutdown());
	t.asserteq(b.m.up, 0, "DISC on DLCI 0 took the responder's multiplexer down");
	t.assertseq(b.down, "hangup", "and it said so");
}

testCredits(t: ref T)
{
	a := newside(1, nil);
	b := newside(0, 3 :: nil);
	(d, evs) := a.m.connect(3);
	exchange(a, b, evs);
	t.asserteq(d.txcredits, Rfcomm->Initcredits, "the peer granted its initial credits at PN");
	# more frames than credits: 20 one-byte writes with a 1-byte frame size
	d.framesize = 1;
	before := a.sent;
	for(i := 0; i < 20; i++)
		a.m.send(d, array of byte "x");
	# nothing crossed yet: the sends returned frames we have not delivered
	# (send() returns the frames for the caller to send; here we sent
	# them into the void and check only what was permitted)
	t.asserteq(d.txcredits, 0, "credits ran out");
	t.asserteq(len d.txq, 20 - Rfcomm->Initcredits, "the rest is queued");
	# the peer consumes and grants credits back; deliver its grant
	pd := b.m.find(d.dlci);
	pd.rxcredits = 0;
	grant := b.m.consumed(pd);
	t.asserteq(len grant, 1, "an empty frame carries the credits back");
	exchange(b, a, grant);
	t.assert(len d.txq < 20 - Rfcomm->Initcredits, "and the queue drained by that many");
	t.asserteq(d.txcredits, 0, "spending them all again");
	# a frame over the size limit is split
	d.framesize = 4;
	d.txcredits = 10;
	d.txq = array[0] of byte;
	b.got = array[0] of byte;
	out := a.m.send(d, array of byte "0123456789");
	t.asserteq(len out, 3, "ten bytes at four a frame is three frames");
	exchange(a, b, out);
	t.assertseq(string b.got, "0123456789", "which arrive whole and in order");
	t.asserteq(a.sent - before > 0, 1, "frames went");
}

testRefusedSession(t: ref T)
{
	# a peer that does not do RFCOMM at all answers SABM on DLCI 0 with DM
	a := newside(1, nil);
	(d, nil) := a.m.connect(1);
	f := array[] of { byte 16r01, byte 16r1f, byte 16r01, byte 0 };
	f[3] = rfcomm->fcs(f, 3);
	for(e := a.m.recv(f); e != nil; e = tl e)
		pick x := hd e {
		Closed =>	a.closed = (x.d, x.reason) :: a.closed;
		Muxdown =>	a.down = x.reason;
		}
	t.assertseq(a.down, "refused", "DM on DLCI 0 is a refused session");
	t.asserteq(len a.closed, 1, "and the DLC waiting on it is closed");
	t.assert(d != nil && a.m.find(d.dlci) == nil, "and forgotten");
	# garbage: a bad FCS is dropped silently
	g := array[] of { byte 16r03, byte 16r3f, byte 16r01, byte 16r00 };
	t.asserteq(len a.m.recv(g), 0, "a frame with a wrong FCS produces nothing");
}

# frames as a peer of our choosing would send them
ctlf(dlci, ctl: int): array of byte
{
	f := array[] of { byte (1 | (dlci << 2)), byte (ctl | 16r10), byte 1, byte 0 };
	f[3] = rfcomm->fcs(f, 3);
	return f;
}

uihf(dlci, credits: int, data: array of byte): array of byte
{
	n := len data;
	hl := 3;
	if(n >= 128)
		hl++;
	if(credits >= 0)
		hl++;
	f := array[hl + n + 1] of byte;
	f[0] = byte (1 | (dlci << 2));
	f[1] = byte 16ref;
	if(credits >= 0)
		f[1] = byte 16rff;
	i := 2;
	if(n < 128)
		f[i++] = byte ((n << 1) | 1);
	else{
		f[i++] = byte ((n & 16r7f) << 1);
		f[i++] = byte (n >> 7);
	}
	if(credits >= 0)
		f[i++] = byte credits;
	f[i:] = data;
	f[hl + n] = rfcomm->fcs(f, 2);
	return f;
}

# a control message for DLCI 0, its length in as many bytes as it needs
mccf(t, cmd: int, v: array of byte): array of byte
{
	n := len v;
	hl := 2;
	if(n >= 128)
		hl = 3;
	b := array[hl + n] of byte;
	b[0] = byte ((t << 2) | (cmd << 1) | 1);
	if(n < 128)
		b[1] = byte ((n << 1) | 1);
	else{
		b[1] = byte ((n & 16r7f) << 1);
		b[2] = byte (((n >> 7) << 1) | 1);
	}
	b[hl:] = v;
	return uihf(0, -1, b);
}

pnf(dlci, cl, fs, k: int): array of byte
{
	v := array[8] of { * => byte 0 };
	v[0] = byte dlci;
	v[1] = byte (cl << 4);
	v[4] = byte fs;
	v[5] = byte (fs >> 8);
	v[7] = byte k;
	return mccf(16r20, 1, v);
}

# what a Mux said to a frame
Said: adt {
	sends:	list of array of byte;	# in order
	opened, incoming, closed, data, refused: int;
};

feed(m: ref Mux, f: array of byte): ref Said
{
	s := ref Said(nil, 0, 0, 0, 0, 0);
	rev: list of array of byte;
	for(l := m.recv(f); l != nil; l = tl l)
		pick e := hd l {
		Send =>		rev = e.sdu :: rev;
		Opened =>	s.opened++;
		Incoming =>	s.incoming++;
		Closed =>	s.closed++;
		Data =>		s.data++;
		Refused =>	s.refused++;
		}
	for(; rev != nil; rev = tl rev)
		s.sends = hd rev :: s.sends;
	return s;
}

# an open session: a dialled channel 1 of b
session(): (ref Side, ref Side, ref Dlc, ref Dlc)
{
	a := newside(1, nil);
	b := newside(0, 1 :: nil);
	(d, evs) := a.m.connect(1);
	exchange(a, b, evs);
	return (a, b, d, b.m.find(2));
}

testNegotiation(t: ref T)
{
	(a, b, d, pd) := session();
	t.assert(pd != nil && pd.state == Rfcomm->Open, "a session is open");
	if(pd == nil)
		return;
	# parameters are settled before a port opens, and stay settled
	fs := pd.framesize;
	pd.txcredits = 5;
	s := feed(b.m, pnf(2, 16rf, 10, 0));
	t.asserteq(pd.framesize, fs, "a PN for an open port leaves its frame size");
	t.asserteq(pd.txcredits, 5, "and its credits");
	t.asserteq(len s.sends, 0, "and is not answered");
	# nor does the peer set the parameters of a port we are opening
	s = feed(a.m, pnf(2, 16rf, 10, 0));
	t.asserteq(d.framesize, fs, "a PN command for a port we dialled changes nothing");
	t.asserteq(len s.sends, 0, "and is not answered");
	# before it opens, the peer may ask again
	c := newside(0, 1 :: nil);
	feed(c.m, ctlf(0, 16r2f));
	s = feed(c.m, pnf(2, 16rf, 100, 3));
	t.asserteq(len s.sends, 1, "a first PN is answered");
	s = feed(c.m, pnf(2, 16rf, 50, 3));
	t.asserteq(len s.sends, 1, "and a second, the port not yet open");
	cd := c.m.find(2);
	t.assert(cd != nil && cd.framesize == 50, "with the size it asked for");
}

testOpening(t: ref T)
{
	(nil, b, nil, pd) := session();
	if(pd == nil){
		t.fatal("no session");
		return;
	}
	# a SABM for a port already open is a retransmission
	s := feed(b.m, ctlf(2, 16r2f));
	t.asserteq(len s.sends, 1, "a second SABM is answered");
	t.asserteq(s.incoming + s.opened, 0, "and the port announced to nobody again");
	# one for a port being closed does not bring it back
	b.m.disconnect(pd);
	t.asserteq(pd.state, Rfcomm->Waitdisc, "the port is closing");
	s = feed(b.m, ctlf(2, 16r2f));
	t.asserteq(pd.state, Rfcomm->Waitdisc, "a SABM leaves it closing");
	t.asserteq(s.incoming + s.opened, 0, "and opens nothing");

	# a UA opens what we asked to open, not what the peer is to open
	c := newside(0, 1 :: nil);
	feed(c.m, ctlf(0, 16r2f));
	feed(c.m, pnf(2, 16rf, 100, 3));
	cd := c.m.find(2);
	t.assert(cd != nil && cd.state == Rfcomm->Waitua, "the peer's port waits for its SABM");
	s = feed(c.m, ctlf(2, 16r63));
	t.asserteq(s.opened, 0, "a UA for it opens nothing");
	if(cd != nil)
		t.asserteq(cd.state, Rfcomm->Waitua, "and it goes on waiting");
	# and bytes for a port not open are not delivered
	s = feed(c.m, uihf(2, -1, array of byte "early"));
	t.asserteq(s.data, 0, "data for a port not yet open is not delivered");
	s = feed(c.m, ctlf(2, 16r2f));
	t.asserteq(s.incoming, 1, "the SABM opens it");
	s = feed(c.m, uihf(2, -1, array of byte "now"));
	t.asserteq(s.data, 1, "and then data is delivered");
	over := array[101] of { * => byte 16r78 };
	s = feed(c.m, uihf(2, -1, over));
	t.asserteq(s.data, 0, "but not a frame over the size agreed");

	# the peer opens ports on its side of the DLCIs, and only the user's
	e := newside(0, 1 :: 31 :: nil);
	feed(e.m, ctlf(0, 16r2f));
	s = feed(e.m, ctlf(3, 16r2f));
	t.asserteq(s.refused, 1, "a SABM on a DLCI of ours is refused");
	t.assert(e.m.find(3) == nil, "and no port made");
	s = feed(e.m, pnf(3, 16rf, 100, 3));
	t.asserteq(s.refused, 1, "a PN the same");
	s = feed(e.m, ctlf(62, 16r2f));
	t.asserteq(s.refused, 1, "DLCI 62 is not a user's");
	t.assert(e.m.find(62) == nil, "and no port made");
}

testControlLength(t: ref T)
{
	c := newside(0, nil);
	feed(c.m, ctlf(0, 16r2f));
	v := array[200] of byte;
	for(i := 0; i < len v; i++)
		v[i] = byte i;
	s := feed(c.m, mccf(16r08, 1, v));	# Test: echoed
	t.asserteq(len s.sends, 1, "a Test command of 200 bytes is answered");
	if(s.sends == nil)
		return;
	r := hd s.sends;
	# address, control, two bytes of frame length, then the message
	t.asserteq(len r, 4 + 3 + 200 + 1, "by a frame that holds them all");
	if(len r != 4 + 3 + 200 + 1)
		return;
	t.asserteq(int r[5], (200 & 16r7f) << 1, "its length's first byte says another follows");
	t.asserteq(int r[6], ((200 >> 7) << 1) | 1, "and the second is the last");
	same := 1;
	for(i = 0; i < 200; i++)
		if(r[7+i] != v[i])
			same = 0;
	t.assert(same, "and the bytes are the ones sent");
}

testCreditBound(t: ref T)
{
	(nil, b, nil, pd) := session();
	if(pd == nil){
		t.fatal("no session");
		return;
	}
	for(i := 0; i < 200; i++)
		feed(b.m, uihf(2, 255, array[0] of byte));
	t.assert(pd.txcredits > 0 && pd.txcredits <= 4096, sys->sprint("credits stay bounded (%d)", pd.txcredits));
}

testSessionEdges(t: ref T)
{
	# DM on DLCI 0 of a session that was up: it is down, and the next
	# connect begins a session
	(a, nil, nil, nil) := session();
	t.asserteq(a.m.up, 1, "a session is up");
	feed(a.m, ctlf(0, 16r0f));
	t.asserteq(a.m.up, 0, "DM on DLCI 0 takes it down");
	(nil, evs) := a.m.connect(4);
	first := "";
	if(evs != nil)
		pick e := hd evs {
		Send =>	first = bthci->hex(e.sdu);
		}
	t.assertseq(first, "03 3f 01 1c", "and the next connect starts with SABM on DLCI 0");

	# our connect waits for the session; the peer's SABM brings it up
	b := newside(0, nil);
	(d, nil) := b.m.connect(5);
	t.assert(d != nil && b.m.pending != nil, "a connect waits for the session");
	s := feed(b.m, ctlf(0, 16r2f));
	t.asserteq(b.m.up, 1, "the peer's SABM brings the session up");
	t.asserteq(len s.sends, 2, "answered, and our waiting connect's PN sent");
	t.assert(b.m.pending == nil, "nothing waits");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	bthci = load Bthci Bthci->PATH;
	bthci->init();
	rfcomm = load Rfcomm Rfcomm->PATH;
	rfcomm->init(bthci);
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Fcs", testFcs);
	run("Session", testSession);
	run("Credits", testCredits);
	run("RefusedSession", testRefusedSession);
	run("Negotiation", testNegotiation);
	run("Opening", testOpening);
	run("ControlLength", testControlLength);
	run("CreditBound", testCreditBound);
	run("SessionEdges", testSessionEdges);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
