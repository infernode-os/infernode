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

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
