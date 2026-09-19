implement AttTest;

#
# att(2): a GATT client against a server scripted here -- a mouse's
# attribute table, as a HID-over-GATT device presents it -- with the
# discovery cut at the ATT MTU so that every "continue from the last
# handle" path runs, plus reads, writes, subscriptions, notifications
# and the errors.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bthci.m";
	bthci: Bthci;
include "att.m";
	att: Att;
	Client, Characteristic, Service, Ev, Gattsrv: import att;
include "testing.m";
	testing: Testing;
	T: import testing;

AttTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/att_test.b";

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

# the server's table: (handle, type uuid16, value); a group end for
# service declarations is the handle before the next service
Attr: adt {
	handle:	int;
	uuid:	int;
	value:	array of byte;
};

get2(a: array of byte, i: int): int
{
	return int a[i] | (int a[i+1] << 8);
}

put2(a: array of byte, i, v: int)
{
	a[i] = byte v;
	a[i+1] = byte (v >> 8);
}

u16(v: int): array of byte
{
	a := array[2] of byte;
	put2(a, 0, v);
	return a;
}

chardecl(props, value, uuid: int): array of byte
{
	a := array[5] of byte;
	a[0] = byte props;
	put2(a, 1, value);
	put2(a, 3, uuid);
	return a;
}

# a mouse: GAP, then HID with protocol mode, a boot mouse input
# report (notify) with its CCCD, a report map, and an input Report
# with a Report Reference and CCCD; then the battery service
table(): list of ref Attr
{
	l: list of ref Attr;
	l = ref Attr(1, Att->Uprimary, u16(16r1800)) :: l;
	l = ref Attr(2, Att->Ucharacteristic, chardecl(Att->Pread, 3, 16r2a00)) :: l;
	l = ref Attr(3, 16r2a00, array of byte "Test Mouse") :: l;
	l = ref Attr(16r10, Att->Uprimary, u16(Att->Uhidservice)) :: l;
	l = ref Attr(16r11, Att->Ucharacteristic, chardecl(Att->Pread|Att->Pwritenorsp, 16r12, Att->Uprotocolmode)) :: l;
	l = ref Attr(16r12, Att->Uprotocolmode, array[] of { byte 1 }) :: l;
	l = ref Attr(16r13, Att->Ucharacteristic, chardecl(Att->Pread|Att->Pnotify, 16r14, Att->Ubootmousein)) :: l;
	l = ref Attr(16r14, Att->Ubootmousein, array[] of { byte 0, byte 0, byte 0 }) :: l;
	l = ref Attr(16r15, Att->Ucccd, u16(0)) :: l;
	l = ref Attr(16r16, Att->Ucharacteristic, chardecl(Att->Pread, 16r17, Att->Ureportmap)) :: l;
	l = ref Attr(16r17, Att->Ureportmap, array[] of { byte 16r05, byte 16r01, byte 16r09, byte 16r02 }) :: l;
	l = ref Attr(16r18, Att->Ucharacteristic, chardecl(Att->Pread|Att->Pnotify, 16r19, Att->Ureport)) :: l;
	l = ref Attr(16r19, Att->Ureport, array[] of { byte 0 }) :: l;
	l = ref Attr(16r1a, Att->Ucccd, u16(0)) :: l;
	l = ref Attr(16r1b, Att->Ureportref, array[] of { byte 1, byte 1 }) :: l;
	l = ref Attr(16r20, Att->Uprimary, u16(16r180f)) :: l;
	l = ref Attr(16r21, Att->Ucharacteristic, chardecl(Att->Pread, 16r22, 16r2a19)) :: l;
	l = ref Attr(16r22, 16r2a19, array[] of { byte 99 }) :: l;
	r: list of ref Attr;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# the group end of a service declaration
groupend(tab: list of ref Attr, start: int): int
{
	end := 16rffff;
	for(; tab != nil; tab = tl tab)
		if((hd tab).uuid == Att->Uprimary && (hd tab).handle > start && (hd tab).handle - 1 < end)
			end = (hd tab).handle - 1;
	return end;
}

errpdu(op, h, code: int): array of byte
{
	a := array[5] of byte;
	a[0] = byte Att->Oerror;
	a[1] = byte op;
	put2(a, 2, h);
	a[4] = byte code;
	return a;
}

# the server answers one request, within mtu bytes
serve(tab: list of ref Attr, req: array of byte, mtu: int, written: ref (int, array of byte)): array of byte
{
	op := int req[0];
	case op {
	Att->Omtureq =>
		a := array[3] of byte;
		a[0] = byte Att->Omtursp;
		put2(a, 1, 64);
		return a;
	Att->Oreadbygroupreq =>
		start := get2(req, 1);
		end := get2(req, 3);
		u := get2(req, 5);
		out := array[2] of byte;
		out[0] = byte Att->Oreadbygrouprsp;
		out[1] = byte 6;
		for(l := tab; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end || a.uuid != u)
				continue;
			if(len out + 6 > mtu)
				break;
			e := array[6] of byte;
			put2(e, 0, a.handle);
			put2(e, 2, groupend(tab, a.handle));
			e[4:] = a.value;
			out = cat(out, e);
		}
		if(len out == 2)
			return errpdu(op, start, Att->Eattrnotfound);
		return out;
	Att->Oreadbytypereq =>
		start := get2(req, 1);
		end := get2(req, 3);
		u := get2(req, 5);
		out := array[2] of byte;
		out[0] = byte Att->Oreadbytypersp;
		out[1] = byte 7;
		for(l := tab; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end || a.uuid != u)
				continue;
			if(len out + 7 > mtu)
				break;
			e := array[7] of byte;
			put2(e, 0, a.handle);
			e[2:] = a.value;
			out = cat(out, e);
		}
		if(len out == 2)
			return errpdu(op, start, Att->Eattrnotfound);
		return out;
	Att->Ofindinforeq =>
		start := get2(req, 1);
		end := get2(req, 3);
		out := array[2] of byte;
		out[0] = byte Att->Ofindinforsp;
		out[1] = byte 1;
		for(l := tab; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end)
				continue;
			if(len out + 4 > mtu)
				break;
			e := array[4] of byte;
			put2(e, 0, a.handle);
			put2(e, 2, a.uuid);
			out = cat(out, e);
		}
		if(len out == 2)
			return errpdu(op, start, Att->Eattrnotfound);
		return out;
	Att->Oreadreq =>
		h := get2(req, 1);
		for(l := tab; l != nil; l = tl l)
			if((hd l).handle == h)
				return cat(array[] of { byte Att->Oreadrsp }, (hd l).value);
		return errpdu(op, h, Att->Einvalidhandle);
	Att->Owritereq =>
		h := get2(req, 1);
		for(l := tab; l != nil; l = tl l)
			if((hd l).handle == h){
				(hd l).value = req[3:];
				*written = (h, req[3:]);
				return array[] of { byte Att->Owritersp };
			}
		return errpdu(op, h, Att->Einvalidhandle);
	}
	return errpdu(op, 0, Att->Enotsupported);
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# run the client's events through the server until nothing is in flight
Result: adt {
	found:	list of (ref Service, list of ref Characteristic);
	nosuch:	int;
	values:	list of (int, array of byte);
	written: int;
	notified: list of (int, array of byte);
	failed:	list of (int, int);
	mtu:	int;
	sent:	int;
};

drive(c: ref Client, tab: list of ref Attr, evs: list of ref Ev, mtu: int, r: ref Result, w: ref (int, array of byte))
{
	for(rounds := 0; evs != nil && rounds < 200; rounds++){
		more: list of ref Ev;
		for(; evs != nil; evs = tl evs){
			pick e := hd evs {
			Send =>
				r.sent++;
				if(int e.pdu[0] == Att->Owritecmd || int e.pdu[0] == Att->Oconfirm)
					continue;
				for(x := c.recv(serve(tab, e.pdu, mtu, w)); x != nil; x = tl x)
					more = hd x :: more;
			Found =>	r.found = (e.s, e.chars) :: r.found;
			Nosuch =>	r.nosuch = e.uuid;
			Value =>	r.values = (e.handle, e.value) :: r.values;
			Written =>	r.written = e.handle;
			Notified =>	r.notified = (e.handle, e.value) :: r.notified;
			Failed =>	r.failed = (e.op, e.code) :: r.failed;
			Mtu =>		r.mtu = e.mtu;
			}
		}
		for(; more != nil; more = tl more)
			evs = hd more :: evs;
	}
}

newresult(): ref Result
{
	return ref Result(nil, 0, nil, 0, nil, nil, 0, 0);
}

testDiscovery(t: ref T)
{
	tab := table();
	w := ref (0, array[0] of byte);
	for(mtu := 23; mtu <= 64; mtu += 41){
		c := Client.new();
		r := newresult();
		drive(c, tab, c.discover(Att->Uhidservice), mtu, r, w);
		t.asserteq(len r.found, 1, sys->sprint("the HID service is found at MTU %d", mtu));
		if(r.found == nil)
			continue;
		(s, chars) := hd r.found;
		t.asserteq(s.start, 16r10, "it starts at 0x10");
		t.asserteq(s.end, 16r1f, "and ends before the battery service");
		t.asserteq(len chars, 4, "with four characteristics");
		pm, boot, rmap, rep: ref Characteristic;
		for(l := chars; l != nil; l = tl l)
			case (hd l).uuid {
			Att->Uprotocolmode =>	pm = hd l;
			Att->Ubootmousein =>	boot = hd l;
			Att->Ureportmap =>	rmap = hd l;
			Att->Ureport =>		rep = hd l;
			}
		t.assert(pm != nil && boot != nil && rmap != nil && rep != nil, "protocol mode, boot mouse input, report map, report");
		if(boot != nil){
			t.asserteq(boot.value, 16r14, "the boot report's value handle");
			t.asserteq(boot.props & Att->Pnotify, Att->Pnotify, "which notifies");
			t.asserteq(boot.cccd(), 16r15, "and has a CCCD");
			t.asserteq(boot.reportref(), -1, "but no report reference");
		}
		if(rep != nil){
			t.asserteq(rep.cccd(), 16r1a, "the report's CCCD");
			t.asserteq(rep.reportref(), 16r1b, "and report reference");
		}
		if(rmap != nil)
			t.asserteq(len rmap.descs, 0, "the report map has no descriptors, and the gap before the next declaration is not one");
		t.assert(r.sent > 4, sys->sprint("discovery took %d requests at MTU %d", r.sent, mtu));
	}
	# a service that is not there
	c := Client.new();
	r := newresult();
	drive(c, tab, c.discover(16r1234), 23, r, w);
	t.asserteq(r.nosuch, 16r1234, "a missing service is reported as such, from the end of the table");
	t.asserteq(len r.found, 0, "and nothing found");
}

testUse(t: ref T)
{
	tab := table();
	w := ref (0, array[0] of byte);
	c := Client.new();
	r := newresult();
	drive(c, tab, c.exchangemtu(64), 64, r, w);
	t.asserteq(r.mtu, 64, "the MTU is the smaller of our offer and theirs (3.4.2.2): both said 64");
	drive(c, tab, c.read(16r17), 23, r, w);
	t.asserteq(len r.values, 1, "a read is answered");
	if(r.values != nil){
		(h, v) := hd r.values;
		t.asserteq(h, 16r17, "for the handle asked");
		t.asserteq(len v, 4, "with the report map");
	}
	drive(c, tab, c.subscribe(16r15, 0), 23, r, w);
	t.asserteq(r.written, 16r15, "subscribing writes the CCCD");
	(wh, wv) := *w;
	t.asserteq(wh, 16r15, "and the server saw it");
	t.asserteq(int wv[0], 1, "as notifications on");
	# two requests at once queue: the second goes when the first is answered
	evs := c.read(16r12);
	evs2 := c.read(16r22);
	t.asserteq(len evs, 1, "the first request goes at once");
	t.asserteq(len evs2, 0, "the second waits its turn");
	drive(c, tab, evs, 23, r, w);
	t.asserteq(len r.values, 3, "both are answered in turn");
	# a write command takes no turn
	evs = c.writecmd(16r12, array[] of { byte 0 });
	t.asserteq(len evs, 1, "a write command goes out");
	t.asserteq(c.pending, 0, "and awaits no answer");
	# a notification and an indication
	n := array[] of { byte Att->Onotify, byte 16r14, byte 0, byte 1, byte 5, byte 16rfe };
	drive(c, tab, c.recv(n), 23, r, w);
	t.asserteq(len r.notified, 1, "a notification is delivered");
	if(r.notified != nil){
		(nh, nv) := hd r.notified;
		t.asserteq(nh, 16r14, "from the boot report");
		t.asserteq(len nv, 3, "three bytes: buttons, dx, dy");
	}
	ind := array[] of { byte Att->Oindicate, byte 16r19, byte 0, byte 7 };
	evs = c.recv(ind);
	t.asserteq(len evs, 2, "an indication is confirmed and delivered");
	pick ce := hd evs {
	Send =>	t.asserteq(int ce.pdu[0], Att->Oconfirm, "confirmed first");
	* =>	t.error("expected the confirmation first");
	}
	# errors
	drive(c, tab, c.read(16r99), 23, r, w);
	t.asserteq(len r.failed, 1, "a read of a bad handle fails");
	if(r.failed != nil){
		(op, code) := hd r.failed;
		t.asserteq(op, Att->Oreadreq, "naming the request");
		t.asserteq(code, Att->Einvalidhandle, "and the reason");
	}
	t.assertseq(att->errtext(Att->Einsufauthn), "insufficient authentication", "error text");
}

#
# The server: the table the board will serve as a peripheral, asked by
# the library's own client and then by hand.
#

INFERNODE: con "6e6f6465-7265-666e-692d-000000000001";	# stands in for the service UUID #647 will fix

# the client against the library's server
drivesrv(c: ref Client, srv: ref Gattsrv, evs: list of ref Ev, r: ref Result)
{
	for(rounds := 0; evs != nil && rounds < 200; rounds++){
		more: list of ref Ev;
		for(; evs != nil; evs = tl evs){
			pick e := hd evs {
			Send =>
				r.sent++;
				rsp := srv.recv(e.pdu);
				if(rsp == nil)
					continue;
				for(x := c.recv(rsp); x != nil; x = tl x)
					more = hd x :: more;
			Found =>	r.found = (e.s, e.chars) :: r.found;
			Nosuch =>	r.nosuch = e.uuid;
			Value =>	r.values = (e.handle, e.value) :: r.values;
			Failed =>	r.failed = (e.op, e.code) :: r.failed;
			Mtu =>		r.mtu = e.mtu;
			}
		}
		for(; more != nil; more = tl more)
			evs = hd more :: evs;
	}
}

boardtable(): (ref Gattsrv, int, int)
{
	srv := Gattsrv.new();
	srv.service(att->uuidbytes(Att->Ugap));
	name := srv.characteristic(att->uuidbytes(Att->Udevname), array of byte "infernode", 0);
	srv.characteristic(att->uuidbytes(Att->Uappearance), array[] of { byte 16r80, byte 0 }, 0);
	srv.service(att->uuidbytes(Att->Ugatt));
	srv.service(att->parseuuid(INFERNODE));
	psm := srv.characteristic(att->parseuuid("6e6f6465-7265-666e-692d-000000000002"), array[] of { byte 16r80, byte 0 }, 1);
	return (srv, name, psm);
}

testServerWithClient(t: ref T)
{
	(srv, name, nil) := boardtable();
	c := Client.new();
	r := newresult();
	drivesrv(c, srv, c.exchangemtu(100), r);
	t.asserteq(r.mtu, 100, "the MTU settles on the smaller of the two offers");
	t.asserteq(srv.mtu, 100, "at the server too");
	drivesrv(c, srv, c.discover(Att->Ugap), r);
	t.asserteq(len r.found, 1, "the client finds the GAP service");
	if(r.found != nil){
		(sv, chars) := hd r.found;
		t.asserteq(sv.start, 1, "at handle 1");
		t.asserteq(sv.end, 5, "ending with its last characteristic's value");
		t.asserteq(len chars, 2, "with its two characteristics");
		for(; chars != nil; chars = tl chars)
			if((hd chars).uuid == Att->Udevname){
				t.asserteq((hd chars).value, name, "the device name where the server said it put it");
				t.asserteq((hd chars).props, Att->Pread, "readable and nothing else");
			}
	}
	drivesrv(c, srv, c.read(name), r);
	if(r.values == nil)
		t.fatal("no value read");
	(nil, v) := hd r.values;
	t.assertseq(string v, "infernode", "and it reads as the name");
	drivesrv(c, srv, c.discover(Att->Uhidservice), r);
	t.asserteq(r.nosuch, Att->Uhidservice, "a service that is not there is reported as such");
	drivesrv(c, srv, c.write(name, array of byte "x"), r);
	t.assert(r.failed != nil, "a write is refused");
	if(r.failed != nil){
		(nil, code) := hd r.failed;
		t.asserteq(code, Att->Ewritenotpermitted, "as not permitted");
	}
}

iserr(t: ref T, rsp: array of byte, op, code: int, what: string)
{
	if(len rsp != 5 || int rsp[0] != Att->Oerror){
		t.error(what + ": not an error response");
		return;
	}
	t.asserteq(int rsp[1], op, what + ": names the request");
	t.asserteq(int rsp[4], code, what);
}

req(op, start, end: int, rest: array of byte): array of byte
{
	p := array[5 + len rest] of byte;
	p[0] = byte op;
	p[1] = byte start; p[2] = byte (start >> 8);
	p[3] = byte end; p[4] = byte (end >> 8);
	p[5:] = rest;
	return p;
}

# what a phone does: find the service by its 128-bit UUID, find the
# characteristic in it, read the PSM -- and be made to pair first
testServerByHand(t: ref T)
{
	(srv, nil, psm) := boardtable();
	u := att->parseuuid(INFERNODE);
	t.asserteq(len u, 16, "a UUID string parses to sixteen bytes");
	t.asserteq(int u[15], 16r6e, "most significant octet last, as ATT carries it");
	t.assert(att->parseuuid("not-a-uuid") == nil, "and a malformed one to nil");

	# Find By Type Value: primary service, this UUID
	rsp := srv.recv(req(Att->Ofindbytypereq, 1, 16rffff, cat(att->uuidbytes(Att->Uprimary), u)));
	t.asserteq(int rsp[0], Att->Ofindbytypersp, "the service is found by its UUID");
	t.asserteq(len rsp, 5, "once");
	start := int rsp[1] | (int rsp[2] << 8);
	end := int rsp[3] | (int rsp[4] << 8);
	t.asserteq(end, psm, "its group ends at the PSM's value");

	# the characteristic declarations in that range
	rsp = srv.recv(req(Att->Oreadbytypereq, start, end, att->uuidbytes(Att->Ucharacteristic)));
	t.asserteq(int rsp[0], Att->Oreadbytypersp, "its characteristic is listed");
	t.asserteq(int rsp[1], 2 + 3 + 16, "with a 128-bit UUID: handle, properties, value handle, UUID");
	t.asserteq(int rsp[5] | (int rsp[6] << 8), psm, "pointing at the value");

	# the value, on a link that is not encrypted
	rd := array[] of { byte Att->Oreadreq, byte psm, byte (psm >> 8) };
	iserr(t, srv.recv(rd), Att->Oreadreq, Att->Einsufauthn, "the PSM is not read on an unencrypted link, which is a phone's cue to pair");
	iserr(t, srv.recv(req(Att->Oreadbytypereq, start, end, att->parseuuid("6e6f6465-7265-666e-692d-000000000002"))), Att->Oreadbytypereq, Att->Einsufauthn, "nor by type");
	srv.encrypted = 1;
	rsp = srv.recv(rd);
	t.asserteq(int rsp[0], Att->Oreadrsp, "encrypted, it is");
	t.asserteq(int rsp[1] | (int rsp[2] << 8), 16r80, "and it is the PSM");
	srv.set(psm, array[] of { byte 16r93, byte 0 });
	rsp = srv.recv(rd);
	t.asserteq(int rsp[1], 16r93, "a value that is set is what is read next");

	# all the services, as a central that discovers everything asks
	rsp = srv.recv(req(Att->Oreadbygroupreq, 1, 16rffff, att->uuidbytes(Att->Uprimary)));
	t.asserteq(int rsp[0], Att->Oreadbygrouprsp, "services are listed by group");
	t.asserteq(int rsp[1], 6, "the 16-bit ones first, six bytes each");
	t.asserteq(len rsp, 2 + 2*6, "two of them: a 128-bit UUID cannot share the response");
	rsp = srv.recv(req(Att->Oreadbygroupreq, start, 16rffff, att->uuidbytes(Att->Uprimary)));
	t.asserteq(int rsp[1], 20, "the 128-bit one next, twenty bytes");
	iserr(t, srv.recv(req(Att->Oreadbygroupreq, end + 1, 16rffff, att->uuidbytes(Att->Uprimary))), Att->Oreadbygroupreq, Att->Eattrnotfound, "and then no more");
	iserr(t, srv.recv(req(Att->Oreadbygroupreq, 1, 16rffff, att->uuidbytes(Att->Ucharacteristic))), Att->Oreadbygroupreq, Att->Eunsupportedgroup, "only services are groups");

	# Find Information, Read Blob, and the refusals
	rsp = srv.recv(req(Att->Ofindinforeq, 1, 3, nil));
	t.asserteq(int rsp[1], 1, "Find Information gives 16-bit UUIDs in the 16-bit format");
	t.asserteq(len rsp, 2 + 3*4, "one pair per attribute");
	blob := array[] of { byte Att->Oreadblobreq, byte 3, byte 0, byte 5, byte 0 };
	rsp = srv.recv(blob);
	t.assertseq(string rsp[1:], "node", "Read Blob reads from an offset");
	blob[3] = byte 99;
	iserr(t, srv.recv(blob), Att->Oreadblobreq, Att->Einvalidoffset, "an offset past the end");
	iserr(t, srv.recv(req(Att->Ofindinforeq, 0, 5, nil)), Att->Ofindinforeq, Att->Einvalidhandle, "handle 0 is not a handle");
	iserr(t, srv.recv(req(Att->Ofindinforeq, 9, 5, nil)), Att->Ofindinforeq, Att->Einvalidhandle, "nor is a range that runs backwards");
	iserr(t, srv.recv(array[] of { byte Att->Oreadreq, byte 200, byte 0 }), Att->Oreadreq, Att->Einvalidhandle, "a handle that is not there");
	iserr(t, srv.recv(array[] of { byte 16r20, byte 1, byte 0 }), 16r20, Att->Enotsupported, "a request it does not know");
	iserr(t, srv.recv(array[] of { byte Att->Oreadreq }), Att->Oreadreq, Att->Einvalidpdu, "a request cut short");
	t.assert(srv.recv(array[] of { byte Att->Owritecmd, byte 3, byte 0, byte 'x' }) == nil, "a command is not answered, even to refuse it");

	# a long value is cut to the MTU, and the rest comes by Read Blob
	long := array[60] of { * => byte 'n' };
	srv.set(3, long);
	rsp = srv.recv(array[] of { byte Att->Oreadreq, byte 3, byte 0 });
	t.asserteq(len rsp, Att->Defmtu, "a long value is cut to the MTU");

	t.assert(att->isrequest(array[] of { byte Att->Oreadreq }), "a Read Request is for the server");
	t.assert(att->isrequest(array[] of { byte Att->Owritecmd }), "so is a Write Command");
	t.assert(!att->isrequest(array[] of { byte Att->Oreadrsp }), "a Read Response is for the client");
	t.assert(!att->isrequest(array[] of { byte Att->Onotify }), "so is a notification");
	t.assert(!att->isrequest(array[] of { byte Att->Oerror }), "and an error");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	bthci = load Bthci Bthci->PATH;
	bthci->init();
	att = load Att Att->PATH;
	att->init(bthci);
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Discovery", testDiscovery);
	run("Use", testUse);
	run("ServerWithClient", testServerWithClient);
	run("ServerByHand", testServerByHand);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
