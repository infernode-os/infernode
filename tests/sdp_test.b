implement SdpTest;

#
# sdp(2): elements round-trip through the wire form, a Serial Port
# record says which channel it is on, and a client finds it on a
# Server -- in one response and, with the peer's byte limit small,
# in several pieces joined by continuation state.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bthci.m";
	bthci: Bthci;
include "sdp.m";
	sdp: Sdp;
	Elem, Record, Server: import sdp;
include "testing.m";
	testing: Testing;
	T: import testing;

SdpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sdp_test.b";

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

# every element kind survives pack and unpack
testElements(t: ref T)
{
	e := sdp->seq(sdp->uuid(16r1101) :: sdp->uint8(3) :: sdp->uint16(16r656e) :: sdp->uint32(16r10000) ::
		sdp->str("Serial Port") :: ref Elem.Bool(1) :: ref Elem.Nil :: ref Elem.Int(big -5, 2) ::
		ref Elem.Alt(sdp->uuid(1) :: nil) :: ref Elem.Url("http://x") :: nil);
	b := e.pack();
	(f, n) := sdp->unpack(b, 0);
	t.assert(f != nil, "unpacks");
	t.asserteq(n, len b, "consumes exactly the bytes packed");
	t.assertseq(f.text(), e.text(), "the same element back");
	t.assertseq(e.text(), "(uuid 0x1101 0x3 0x656e 0x10000 'Serial Port' 1 nil -5 alt(uuid 0x0001) url http://x)", "text form");
	# a 128-bit UUID that is a 16-bit one in disguise, and one that is not
	u := array[16] of { * => byte 0 };
	u[2] = byte 16r11; u[3] = byte 16r01;
	u[6] = byte 16r10; u[8] = byte 16r80; u[11] = byte 16r80; u[12] = byte 16r5f; u[13] = byte 16r9b; u[14] = byte 16r34; u[15] = byte 16rfb;
	t.asserteq((ref Elem.Uuid(u)).uuid16(), 16r1101, "a 128-bit UUID on the Bluetooth base is its 16-bit form");
	u[15] = byte 0;
	t.asserteq((ref Elem.Uuid(u)).uuid16(), -1, "off the base it is not");
	# malformed: a sequence whose length runs past the end
	bad := array[] of { byte 16r35, byte 10, byte 16r19, byte 0, byte 1 };
	(g, nil) := sdp->unpack(bad, 0);
	t.assert(g == nil, "a truncated sequence is refused, not guessed at");
}

testRecord(t: ref T)
{
	r := sdp->spprecord(0, 7, "Serial Port");
	t.asserteq(r.rfcommchan(), 7, "the record names its RFCOMM channel");
	t.assertseq(r.name(), "Serial Port", "and its name");
	cl := r.classes();
	t.assert(cl != nil && hd cl == Sdp->Userialport, "its class is Serial Port");
	t.asserteq(sdp->spprecord(0, 1, "x").attr(Sdp->Aprofiles) != nil, 1, "a profile descriptor is present");
}

# a client asks a server; both are just functions on bytes here
query(t: ref T, srv: ref Server, uuids: list of int, maxbytes, mtu: int): (list of ref Record, int)
{
	body := array[0] of byte;
	cont: array of byte;
	rounds := 0;
	for(;;){
		req := sdp->searchattrreq(rounds + 1, uuids, (0, 16rffff) :: nil, maxbytes, cont);
		rsp := srv.request(req, mtu);
		t.assert(len rsp <= mtu, sys->sprint("a response fits the MTU (%d <= %d)", len rsp, mtu));
		(piece, nc, err) := sdp->searchattrrsp(rsp);
		if(err != nil){
			t.error("response: " + err);
			return (nil, rounds);
		}
		nb := array[len body + len piece] of byte;
		nb[0:] = body;
		nb[len body:] = piece;
		body = nb;
		rounds++;
		if(nc == nil)
			break;
		cont = nc;
		if(rounds > 50){
			t.error("continuation never ends");
			return (nil, rounds);
		}
	}
	return (sdp->records(body), rounds);
}

testSearch(t: ref T)
{
	srv := Server.new();
	h1 := srv.add(sdp->spprecord(0, 3, "Console"));
	h2 := srv.add(sdp->spprecord(0, 5, "Modem"));
	t.assertne(h1, h2, "two records, two handles");
	(recs, rounds) := query(t, srv, Sdp->Userialport :: nil, 16rffff, 672);
	t.asserteq(len recs, 2, "both serial ports found by class");
	t.asserteq(rounds, 1, "in one response when the peer allows it");
	if(len recs == 2){
		t.asserteq((hd recs).rfcommchan(), 3, "first is channel 3");
		t.assertseq((hd tl recs).name(), "Modem", "second is the modem");
		t.asserteq((hd recs).handle, h1, "the handle attribute matches the handle assigned");
	}
	(none, nil) := query(t, srv, Sdp->Uhid :: nil, 16rffff, 672);
	t.asserteq(len none, 0, "no HID device here, and no error saying so");
	(byboth, nil) := query(t, srv, Sdp->Userialport :: Sdp->Ul2cap :: nil, 16rffff, 672);
	t.asserteq(len byboth, 2, "a pattern of two UUIDs must match both, and does");
}

testContinuation(t: ref T)
{
	srv := Server.new();
	srv.add(sdp->spprecord(0, 3, "Console"));
	srv.add(sdp->spprecord(0, 5, "Modem"));
	(recs, rounds) := query(t, srv, Sdp->Userialport :: nil, 40, 672);
	t.asserteq(len recs, 2, "the whole answer arrives in 40-byte pieces");
	t.assert(rounds > 2, sys->sprint("and took several rounds (%d)", rounds));
	(recs2, rounds2) := query(t, srv, Sdp->Userialport :: nil, 16rffff, 64);
	t.asserteq(len recs2, 2, "a small MTU also splits it");
	t.assert(rounds2 > 1, sys->sprint("in %d rounds", rounds2));
}

testErrors(t: ref T)
{
	srv := Server.new();
	srv.add(sdp->spprecord(0, 3, "Console"));
	rsp := srv.request(array[] of { byte 16r06, byte 0, byte 1, byte 0, byte 3, byte 1, byte 2, byte 3 }, 672);
	t.asserteq(sdp->errorrsp(rsp), Sdp->Ebadsyntax, "a request with no pattern is a syntax error");
	rsp = srv.request(array[] of { byte 16r06, byte 0, byte 1, byte 0, byte 9 }, 672);
	t.asserteq(sdp->errorrsp(rsp), Sdp->Ebadpdusize, "a length that disagrees with the bytes is a size error");
	# an attribute request for a handle nobody has
	p := array[5 + 4 + 2 + 5 + 1] of byte;
	p[0] = byte Sdp->Pattrreq;
	p[3] = byte 0; p[4] = byte 12;
	p[5] = byte 0; p[6] = byte 9; p[7] = byte 9; p[8] = byte 9;
	p[9] = byte 16rff; p[10] = byte 16rff;
	p[11] = byte 16r35; p[12] = byte 3; p[13] = byte 16r09; p[14] = byte 0; p[15] = byte 0;
	p[16] = byte 0;
	rsp = srv.request(p, 672);
	t.asserteq(sdp->errorrsp(rsp), Sdp->Ebadhandle, "an unknown record handle is refused by name");
	# the plain service search returns handles
	q := array[5 + 5 + 2 + 1] of byte;
	q[0] = byte Sdp->Psearchreq; q[3] = byte 0; q[4] = byte 8;
	q[5] = byte 16r35; q[6] = byte 3; q[7] = byte 16r19; q[8] = byte 16r11; q[9] = byte 16r01;
	q[10] = byte 0; q[11] = byte 10; q[12] = byte 0;
	rsp = srv.request(q, 672);
	(id, nil, nil) := sdp->pduhdr(rsp);
	t.asserteq(id, Sdp->Psearchrsp, "a service search is answered");
	t.asserteq(int rsp[8], 1, "with one handle");
	srv.remove(16r10000);
	rsp = srv.request(q, 672);
	t.asserteq(int rsp[8], 0, "and none once the record is removed");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	bthci = load Bthci Bthci->PATH;
	bthci->init();
	sdp = load Sdp Sdp->PATH;
	sdp->init(bthci);
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Elements", testElements);
	run("Record", testRecord);
	run("Search", testSearch);
	run("Continuation", testContinuation);
	run("Errors", testErrors);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
