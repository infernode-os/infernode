implement BthciTest;

#
#	bthci(2) -- H4 framing, HCI decoding, and the command host --
#	against btmock(2) on the far end of a pipe.
#
#	The packet layouts asserted here are the Core Specification's
#	(Vol 4 Part A for H4, Vol 4 Part E 7.7 for the events); the
#	Broadcom opcodes are the ones BlueZ's hciattach and Linux's btbcm
#	use.  What the pipe proves is that the host survives a controller
#	that answers slowly, withholds credits, answers out of order, or
#	dies -- which is where an HCI host goes wrong -- with no radio
#	anywhere.  What it cannot prove is that a CYW43455 agrees; only
#	the board can say that (docs/BLUETOOTH.md, M3).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "bthci.m";
	bthci: Bthci;
	Pkt, Event, Deframer, Transport, Hci, Version, Found: import bthci;

include "btmock.m";
	btmock: Btmock;
	Ctlr: import btmock;

BthciTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/bthci_test.b";

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

#
# A controller on the far end of a pipe: one process owns the mock,
# fed by a reader of the pipe and by a ticker, so the mock's state is
# touched from one place. ticks <= 0 disables time, for the tests that
# want a controller that never refunds a credit.
#

Fake: adt {
	host:	ref Sys->FD;		# what the Hci under test opens
	ctlr:	ref Ctlr;
	pid:	int;
	rpid:	int;
	tpid:	int;
};

startfake(addr: string, tickms: int): ref Fake
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return nil;
	f := ref Fake(fds[0], Ctlr.new(addr), 0, 0, 0);
	pidc := chan of int;
	spawn fakeproc(f, fds[1], tickms, pidc);
	f.pid = <-pidc;
	f.rpid = <-pidc;
	f.tpid = <-pidc;
	return f;
}

fakeproc(f: ref Fake, fd: ref Sys->FD, tickms: int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	inc := chan of array of byte;
	tick := chan of int;
	rp := chan of int;
	spawn pipereader(fd, inc, rp);
	pidc <-= <-rp;
	if(tickms > 0){
		spawn faketicker(tick, tickms, rp);
		pidc <-= <-rp;
	}else
		pidc <-= 0;
	for(;;){
		out: array of byte;
		alt {
		b := <-inc =>
			if(b == nil)
				return;
			out = f.ctlr.feed(b);
		<-tick =>
			out = f.ctlr.tick();
		}
		if(len out > 0)
			sys->write(fd, out, len out);
	}
}

pipereader(fd: ref Sys->FD, c: chan of array of byte, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[512] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0){
			c <-= nil;
			return;
		}
		b := array[n] of byte;
		b[0:] = buf[0:n];
		c <-= b;
	}
}

faketicker(c: chan of int, ms: int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

kill(pid: int)
{
	if(pid <= 0)
		return;
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

stopfake(f: ref Fake)
{
	kill(f.tpid);
	kill(f.rpid);
	kill(f.pid);
}

bytes(l: list of int): array of byte
{
	a := array[len l] of byte;
	for(i := 0; l != nil; l = tl l)
		a[i++] = byte hd l;
	return a;
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

#
# Framing.
#

testFrame(t: ref T)
{
	# Reset: indicator 01, opcode 0c03 little-endian, no parameters
	p := bthci->command(Bthci->Reset, nil);
	t.assert(sameb(bthci->frame(p), bytes(16r01 :: 16r03 :: 16r0c :: 16r00 :: nil)),
		"a Reset command frames as 01 03 0c 00");

	# a Command Complete for it: 04 0e 04 01 03 0c 00
	ev := bytes(16r04 :: 16r0e :: 16r04 :: 16r01 :: 16r03 :: 16r0c :: 16r00 :: nil);
	d := Deframer.new();
	l := d.feed(ev);
	t.asserteq(len l, 1, "one whole event yields one packet");
	if(l != nil){
		t.asserteq((hd l).kind, Bthci->Hevt, "its kind is event");
		e := Event.parse(hd l);
		t.assert(e != nil, "it parses as an event");
		if(e != nil){
			t.asserteq(e.code, Bthci->EvCmdComplete, "it is Command Complete");
			(ncmd, op, ret) := bthci->cmdcomplete(e);
			t.asserteq(ncmd, 1, "one command credit");
			t.asserteq(op, Bthci->Reset, "for Reset");
			t.asserteq(len ret, 1, "with a one-byte return: the status");
			t.asserteq(int ret[0], Bthci->Sok, "status success");
		}
	}
}

testDeframeBytewise(t: ref T)
{
	# the same event one byte at a time, as a UART delivers it
	ev := bytes(16r04 :: 16r0e :: 16r04 :: 16r01 :: 16r03 :: 16r0c :: 16r00 :: nil);
	d := Deframer.new();
	got := 0;
	for(i := 0; i < len ev; i++){
		l := d.feed(ev[i:i+1]);
		if(i < len ev - 1)
			t.asserteq(len l, 0, sys->sprint("nothing whole after byte %d", i));
		got += len l;
	}
	t.asserteq(got, 1, "the packet completes on its last byte");
	t.asserteq(d.n, 0, "and nothing is left over");
}

testDeframeSplitAndJoined(t: ref T)
{
	# two packets in one buffer, the second an ACL frame split across two feeds
	ev := bytes(16r04 :: 16r0e :: 16r04 :: 16r01 :: 16r03 :: 16r0c :: 16r00 :: nil);
	acl := bytes(16r02 :: 16r41 :: 16r20 :: 16r03 :: 16r00 :: 16raa :: 16rbb :: 16rcc :: nil);
	d := Deframer.new();
	both := array[len ev + 3] of byte;
	both[0:] = ev;
	both[len ev:] = acl[0:3];
	l := d.feed(both);
	t.asserteq(len l, 1, "the whole event comes out, the ACL header waits");
	l = d.feed(acl[3:]);
	t.asserteq(len l, 1, "the rest of the ACL frame completes it");
	if(l != nil){
		t.asserteq((hd l).kind, Bthci->Hacl, "it is ACL");
		t.asserteq(len (hd l).data, 7, "handle 2 + len 2 + 3 payload bytes");
		t.asserteq(bthci->get2((hd l).data, 0), 16r2041, "handle and flags read little-endian");
	}
}

testDeframeResync(t: ref T)
{
	# noise before the indicator: 0x00 and 0xff are not indicators; drop and count
	junk := bytes(16r00 :: 16rff :: 16r04 :: 16r0e :: 16r04 :: 16r01 :: 16r03 :: 16r0c :: 16r00 :: nil);
	d := Deframer.new();
	l := d.feed(junk);
	t.asserteq(len l, 1, "the packet after the noise is found");
	t.asserteq(d.junk, 2, "and both noise bytes are counted");
}

#
# Decoding.
#

testBdaddr(t: ref T)
{
	a := bthci->parsebdaddr("b8:27:eb:5a:6b:7c");
	t.assert(a != nil, "a well-formed address parses");
	if(a != nil){
		t.asserteq(int a[0], 16r7c, "least significant byte first on the wire");
		t.asserteq(int a[5], 16rb8, "most significant last");
		t.assertseq(bthci->bdaddr(a, 0), "b8:27:eb:5a:6b:7c", "and prints back the same");
	}
	t.assert(bthci->parsebdaddr("b8:27:eb:5a:6b") == nil, "a short address is refused");
	t.assert(bthci->parsebdaddr("b8-27-eb-5a-6b-7c") == nil, "so is one with the wrong separator");
	t.assert(bthci->parsebdaddr("b8:27:eb:5a:6b:7g") == nil, "and one with a non-hex digit");
}

testVersion(t: ref T)
{
	# hci 8 (4.2), rev 0x1234, lmp 8, manufacturer 15 (Broadcom), subversion 0x0421
	v := Version.parse(bytes(8 :: 16r34 :: 16r12 :: 8 :: 15 :: 0 :: 16r21 :: 16r04 :: nil));
	t.assert(v != nil, "eight bytes parse");
	if(v != nil){
		t.asserteq(v.hci, 8, "hci version");
		t.asserteq(v.hcirev, 16r1234, "hci revision");
		t.asserteq(v.manuf, 15, "manufacturer");
		t.asserteq(v.lmpsub, 16r0421, "lmp subversion");
		t.assertseq(v.text(), "hci 4.2 lmp 4.2 manufacturer 15 (Broadcom)", "and prints as the spec names them");
	}
	t.assert(Version.parse(bytes(8 :: 0 :: nil)) == nil, "a short return is refused");
	t.assertseq(bthci->vername(9), "5.0", "version 9 is 5.0");
	t.assertseq(bthci->manufacturer(93), "Realtek", "manufacturer 93 is Realtek");
}

testInquiryResults(t: ref T)
{
	# Inquiry Result with RSSI (0x22), one device: n, addr, psrm, res, class, clock, rssi
	p := bytes(1 :: 16r04 :: 16r61 :: 16r44 :: 16r43 :: 16rbb :: 16r94 :: 1 :: 0 ::
		16r0c :: 16r01 :: 16r1c :: 0 :: 0 :: 16rc3 :: nil);
	l := bthci->inquiryresults(ref Event(Bthci->EvInquiryResultRssi, p));
	t.asserteq(len l, 1, "one device");
	if(l != nil){
		f := hd l;
		t.assertseq(f.addr, "94:bb:43:44:61:04", "its address");
		t.asserteq(f.class, 16r1c010c, "its class of device");
		t.asserteq(f.rssi, -61, "its RSSI, signed");
	}

	# the classic form (0x02), two devices, fields as arrays
	p = bytes(2 ::
		1 :: 2 :: 3 :: 4 :: 5 :: 6 ::  16r11 :: 16r12 :: 16r13 :: 16r14 :: 16r15 :: 16r16 ::	# addrs
		1 :: 1 ::						# psrm
		0 :: 0 ::  0 :: 0 ::					# reserved x2
		16r0a :: 16r0b :: 16r0c ::  16r1a :: 16r1b :: 16r1c ::	# classes
		0 :: 0 ::  0 :: 0 :: nil);				# clock offsets
	l = bthci->inquiryresults(ref Event(Bthci->EvInquiryResult, p));
	t.asserteq(len l, 2, "two devices");
	if(len l == 2){
		t.assertseq((hd l).addr, "06:05:04:03:02:01", "first address");
		t.asserteq((hd l).class, 16r0c0b0a, "first class");
		t.assertseq((hd tl l).addr, "16:15:14:13:12:11", "second address");
		t.asserteq((hd tl l).class, 16r1c1b1a, "second class");
		t.asserteq((hd l).rssi, 0, "no RSSI in this form");
	}

	# the extended form (0x2f): one device with an EIR carrying a complete local name
	eir := array[240] of { * => byte 0 };
	nm := array of byte "hephaestus";
	eir[0] = byte (1 + len nm);
	eir[1] = byte 16r09;
	eir[2:] = nm;
	p = array[15 + 240] of byte;
	p[0:] = bytes(1 :: 16r04 :: 16r61 :: 16r44 :: 16r43 :: 16rbb :: 16r94 :: 1 :: 0 ::
		16r0c :: 16r01 :: 16r1c :: 0 :: 0 :: 16rc3 :: nil);
	p[15:] = eir;
	l = bthci->inquiryresults(ref Event(Bthci->EvExtInquiryResult, p));
	t.asserteq(len l, 1, "one device in the extended form");
	if(l != nil)
		t.assertseq((hd l).name, "hephaestus", "with its name taken from the EIR");
}

#
# The host against the mock.
#

Ms: con 2000;

testResetAndIdentity(t: ref T)
{
	f := startfake("b8:27:eb:5a:6b:7c", 50);
	if(f == nil)
		t.fatal("cannot make a pipe");
	h := Hci.new(Transport.h4(f.host));

	(st, ret, err) := h.cmd(Bthci->Reset, nil, Ms);
	t.assertnil(err, "Reset is answered");
	t.asserteq(st, Bthci->Sok, "with success");
	t.asserteq(len ret, 0, "and no return parameters");
	t.asserteq(f.ctlr.seen(Bthci->Reset), 1, "the controller saw one Reset");

	(st, ret, err) = h.cmd(Bthci->ReadBdaddr, nil, Ms);
	t.assertnil(err, "Read_BD_ADDR is answered");
	t.asserteq(len ret, 6, "with six bytes");
	t.assertseq(bthci->bdaddr(ret, 0), "b8:27:eb:5a:6b:7c", "the controller's address");

	(st, ret, err) = h.cmd(Bthci->ReadLocalVersion, nil, Ms);
	t.assertnil(err, "Read_Local_Version_Information is answered");
	v := Version.parse(ret);
	t.assert(v != nil, "and parses");
	if(v != nil)
		t.asserteq(v.manuf, 15, "manufacturer Broadcom, as the mock claims");

	(st, ret, err) = h.cmd(Bthci->ReadLocalName, nil, Ms);
	t.assertnil(err, "Read_Local_Name is answered");
	t.asserteq(len ret, 248, "with the 248-byte name field");

	name := array of byte "infernode";
	params := array[248] of { * => byte 0 };
	params[0:] = name;
	(st, nil, err) = h.cmd(Bthci->WriteLocalName, params, Ms);
	t.assertnil(err, "Write_Local_Name is answered");
	t.asserteq(st, Bthci->Sok, "with success");
	t.assertseq(f.ctlr.name, "infernode", "and the controller took the name");

	h.stop();
	stopfake(f);
}

testUnknownCommand(t: ref T)
{
	f := startfake("00:11:22:33:44:55", 50);
	if(f == nil)
		t.fatal("cannot make a pipe");
	h := Hci.new(Transport.h4(f.host));
	(st, nil, err) := h.cmd(bthci->opcode(Bthci->OGFtest, 16r3ff), nil, Ms);
	t.assertnil(err, "an unknown command is still answered");
	t.asserteq(st, Bthci->Sunknowncmd, "by Command Status: unknown HCI command");
	t.assertseq(bthci->statusname(st), "unknown HCI command", "which has a name");
	h.stop();
	stopfake(f);
}

testQueueInOrder(t: ref T)
{
	# two commands issued from two processes before either is answered
	# both complete, and the controller saw them both
	f := startfake("00:11:22:33:44:55", 50);
	if(f == nil)
		t.fatal("cannot make a pipe");
	h := Hci.new(Transport.h4(f.host));
	done := chan of string;
	spawn issue(h, Bthci->ReadBdaddr, done);
	spawn issue(h, Bthci->ReadLocalVersion, done);
	e1 := <-done;
	e2 := <-done;
	t.assertnil(e1, "the first concurrent command completed");
	t.assertnil(e2, "the second concurrent command completed");
	t.asserteq(f.ctlr.seen(Bthci->ReadBdaddr) + f.ctlr.seen(Bthci->ReadLocalVersion), 2,
		"the controller saw both");
	h.stop();
	stopfake(f);
}

issue(h: ref Hci, op: int, done: chan of string)
{
	(nil, nil, err) := h.cmd(op, nil, Ms);
	done <-= err;
}

testFlowControl(t: ref T)
{
	# a stingy controller answers with no credit and refunds one on its
	# next tick: the second command must wait for it, then go
	f := startfake("00:11:22:33:44:55", 50);
	if(f == nil)
		t.fatal("cannot make a pipe");
	f.ctlr.stingy = 1;
	h := Hci.new(Transport.h4(f.host));
	(nil, nil, err) := h.cmd(Bthci->Reset, nil, Ms);
	t.assertnil(err, "the first command is answered (with no credit)");
	t0 := sys->millisec();
	(nil, nil, err) = h.cmd(Bthci->ReadBdaddr, nil, Ms);
	dt := sys->millisec() - t0;
	t.assertnil(err, "the second command completes once a credit is refunded");
	t.assert(dt >= 20, sys->sprint("and it waited for the refund (%d ms)", dt));
	h.stop();
	stopfake(f);

	# the same controller with time stopped never refunds: the second
	# command times out saying why, rather than being sent regardless
	f = startfake("00:11:22:33:44:55", 0);
	if(f == nil)
		t.fatal("cannot make a pipe");
	f.ctlr.stingy = 1;
	h = Hci.new(Transport.h4(f.host));
	(nil, nil, err) = h.cmd(Bthci->Reset, nil, Ms);
	t.assertnil(err, "first command answered");
	(nil, nil, err) = h.cmd(Bthci->ReadBdaddr, nil, 300);
	t.assertseq(err, "timeout: no command credit", "the second times out for want of a credit");
	t.asserteq(f.ctlr.seen(Bthci->ReadBdaddr), 0, "and was never sent");
	h.stop();
	stopfake(f);
}

testTimeoutAndDeath(t: ref T)
{
	# nobody on the far end: a command times out, in about the time asked
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal("cannot make a pipe");
	h := Hci.new(Transport.h4(fds[0]));
	t0 := sys->millisec();
	(nil, nil, err) := h.cmd(Bthci->Reset, nil, 300);
	dt := sys->millisec() - t0;
	t.assertseq(err, "timeout", "a silent controller is a timeout");
	t.assert(dt >= 250 && dt < 1500, sys->sprint("in about the time asked (%d ms)", dt));

	# the far end closes: the transport dies, and says so
	fds[1] = nil;
	e := <-h.events;
	t.assert(e == nil, "the events channel yields nil when the transport dies");
	(nil, nil, err) = h.cmd(Bthci->Reset, nil, 300);
	t.assertseq(err, "controller gone", "a command after death fails at once");
	h.stop();
}

testInquiry(t: ref T)
{
	f := startfake("00:11:22:33:44:55", 30);
	if(f == nil)
		t.fatal("cannot make a pipe");
	f.ctlr.nearby = ref Found("94:bb:43:44:61:04", 16r1c010c, -61, nil, -1) ::
			ref Found("aa:bb:cc:dd:ee:ff", 16r000104, -80, nil, -1) :: nil;
	h := Hci.new(Transport.h4(f.host));
	params := bytes(16r33 :: 16r8b :: 16r9e :: 8 :: 0 :: nil);	# GIAC, 8*1.28s, unlimited
	(st, nil, err) := h.cmd(Bthci->Inquiry, params, Ms);
	t.assertnil(err, "Inquiry is answered");
	t.asserteq(st, Bthci->Sok, "by Command Status success");

	found: list of ref Found;
	complete := 0;
	for(i := 0; i < 10 && !complete; i++){
		e := <-h.events;
		if(e == nil)
			break;
		case e.code {
		Bthci->EvInquiryResultRssi =>
			for(l := bthci->inquiryresults(e); l != nil; l = tl l)
				found = hd l :: found;
		Bthci->EvInquiryComplete =>
			complete = 1;
		}
	}
	t.asserteq(complete, 1, "Inquiry Complete arrived");
	t.asserteq(len found, 2, "after two results");
	if(len found == 2){
		t.assertseq((hd found).addr, "aa:bb:cc:dd:ee:ff", "the second device");
		t.asserteq((hd found).rssi, -80, "with its RSSI");
		t.assertseq((hd tl found).addr, "94:bb:43:44:61:04", "the first device");
	}
	h.stop();
	stopfake(f);
}

testBroadcomVendor(t: ref T)
{
	# the patch-upload sequence's opcodes are accepted, and Write_BD_ADDR takes
	f := startfake("00:00:00:00:00:00", 50);
	if(f == nil)
		t.fatal("cannot make a pipe");
	h := Hci.new(Transport.h4(f.host));
	(st, nil, err) := h.cmd(Bthci->BcmDownloadMinidriver, nil, Ms);
	t.assertnil(err, "Download_Minidriver answered");
	t.asserteq(st, Bthci->Sok, "success");
	(st, nil, err) = h.cmd(Bthci->BcmWriteRam, bytes(0 :: 0 :: 0 :: 0 :: 16rde :: 16rad :: nil), Ms);
	t.assertnil(err, "Write_RAM answered");
	(st, nil, err) = h.cmd(Bthci->BcmLaunchRam, bytes(16rff :: 16rff :: 16rff :: 16rff :: nil), Ms);
	t.assertnil(err, "Launch_RAM answered");
	a := bthci->parsebdaddr("b8:27:eb:00:00:01");
	(st, nil, err) = h.cmd(Bthci->BcmWriteBdaddr, a, Ms);
	t.assertnil(err, "Write_BD_ADDR answered");
	ret: array of byte;
	(nil, ret, err) = h.cmd(Bthci->ReadBdaddr, nil, Ms);
	t.assertseq(bthci->bdaddr(ret, 0), "b8:27:eb:00:00:01", "and Read_BD_ADDR returns the new one");
	h.stop();
	stopfake(f);
}

testLeAndNames(t: ref T)
{
	# an LE Advertising Report: subevent 2, one report, ADV_IND, public,
	# addr, 12 bytes of data carrying a complete name, RSSI -70
	nm := array of byte "hephaestus";
	p := array[11 + 2 + len nm + 1] of byte;
	p[0] = byte Bthci->LeAdvReport;
	p[1] = byte 1;
	p[2] = byte 0;
	p[3] = byte 1;
	p[4:] = bthci->parsebdaddr("c0:ff:ee:00:00:01");
	p[10] = byte (2 + len nm);
	p[11] = byte (1 + len nm);
	p[12] = byte 16r09;
	p[13:] = nm;
	p[13 + len nm] = byte 16rba;
	l := bthci->leadvreports(ref Event(Bthci->EvLeMeta, p));
	t.asserteq(len l, 1, "one advertising report");
	if(l != nil){
		f := hd l;
		t.assertseq(f.addr, "c0:ff:ee:00:00:01", "its address");
		t.asserteq(f.letype, 1, "a random address");
		t.asserteq(f.rssi, -70, "its RSSI, signed");
		t.assertseq(f.name, "hephaestus", "its name from the advertising data");
	}
	t.assert(bthci->leadvreports(ref Event(Bthci->EvLeMeta, bytes(16r01 :: 0 :: nil))) == nil,
		"another subevent yields nothing");

	# Remote Name Request Complete: status, addr, name[248]
	q := array[255] of { * => byte 0 };
	q[0] = byte 0;
	q[1:] = bthci->parsebdaddr("94:bb:43:44:61:04");
	q[7:] = array of byte "kiln";
	(st, who, name) := bthci->remotename(ref Event(Bthci->EvRemoteName, q));
	t.asserteq(st, Bthci->Sok, "name request succeeded");
	t.assertseq(who, "94:bb:43:44:61:04", "for this address");
	t.assertseq(name, "kiln", "with this name");
	q[0] = byte Bthci->Spagetimeout;
	(st, nil, nil) = bthci->remotename(ref Event(Bthci->EvRemoteName, q));
	t.asserteq(st, Bthci->Spagetimeout, "a page timeout is reported as its status");
}

testHcdRecords(t: ref T)
{
	# two Write_RAM records and a Launch_RAM, as a .hcd lays them out
	hcd := bytes(16r4c :: 16rfc :: 3 :: 1 :: 2 :: 3 ::
		16r4c :: 16rfc :: 1 :: 16raa ::
		16r4e :: 16rfc :: 4 :: 16rff :: 16rff :: 16rff :: 16rff :: nil);
	(l, bad) := bthci->hcdrecords(hcd);
	t.asserteq(len l, 3, "three records");
	t.asserteq(bad, -1, "none malformed");
	if(len l == 3){
		(op, p) := hd l;
		t.asserteq(op, Bthci->BcmWriteRam, "the first is Write_RAM");
		t.asserteq(len p, 3, "with three bytes");
		(op, p) = hd tl tl l;
		t.asserteq(op, Bthci->BcmLaunchRam, "the last is Launch_RAM");
		t.asserteq(bthci->get4(p, 0), -1, "to address 0xffffffff");
	}
	# a record whose length runs past the end is refused, and where
	(l, bad) = bthci->hcdrecords(bytes(16r4c :: 16rfc :: 9 :: 1 :: 2 :: nil));
	t.assert(l == nil, "a truncated record yields nothing");
	t.asserteq(bad, 0, "and names the offset");
	(l, bad) = bthci->hcdrecords(bytes(16r4c :: 16rfc :: 1 :: 16raa :: 16r4e :: nil));
	t.asserteq(bad, 4, "a trailing partial header names its offset");
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
	if(bthci == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Bthci->PATH);
		raise "fail:cannot load bthci";
	}
	bthci->init();
	btmock = load Btmock Btmock->PATH;
	if(btmock == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Btmock->PATH);
		raise "fail:cannot load btmock";
	}
	btmock->init(bthci);

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Frame", testFrame);
	run("DeframeBytewise", testDeframeBytewise);
	run("DeframeSplitAndJoined", testDeframeSplitAndJoined);
	run("DeframeResync", testDeframeResync);
	run("Bdaddr", testBdaddr);
	run("Version", testVersion);
	run("InquiryResults", testInquiryResults);
	run("ResetAndIdentity", testResetAndIdentity);
	run("UnknownCommand", testUnknownCommand);
	run("QueueInOrder", testQueueInOrder);
	run("FlowControl", testFlowControl);
	run("TimeoutAndDeath", testTimeoutAndDeath);
	run("Inquiry", testInquiry);
	run("BroadcomVendor", testBroadcomVendor);
	run("HcdRecords", testHcdRecords);
	run("LeAndNames", testLeAndNames);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
