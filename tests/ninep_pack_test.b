implement NinepPackTest;

#
# ninep_pack_test - Ninep (9p.m) unpacks a Twstat whose stat is 256
# bytes or more. It read the stat count's high byte shifted as a byte,
# so lost it, and refused the message, as Styx did (styx_pack_test).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "9p.m";
	ninep: Ninep;
	Tmsg, Rmsg: import ninep;

include "testing.m";
	testing: Testing;
	T: import testing;

NinepPackTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ninep_pack_test.b";

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

testLongStat(t: ref T)
{
	for(nl := 190; nl <= 1000; nl += nl/7){
		d := sys->nulldir;
		d.name = "";
		for(i := 0; i < nl; i++)
			d.name[i] = 'a' + i%26;
		d.uid = "\U0001F680";
		w := ref Tmsg.Wstat(3, 16r66, d);
		a := w.pack();
		t.asserteq(len a, w.packedsize(), sys->sprint("Twstat, name of %d: packed length", nl));
		(n, u) := Tmsg.unpack(a);
		t.asserteq(n, len a, sys->sprint("Twstat, name of %d: unpacked whole", nl));
		if(u != nil)
			pick m := u {
			Wstat =>
				t.assertseq(m.stat.name, d.name, sys->sprint("Twstat, name of %d: the name", nl));
				t.assertseq(m.stat.uid, d.uid, sys->sprint("Twstat, name of %d: the uid", nl));
			* =>
				t.error("Twstat unpacked as something else");
			}
	}
}

# a message of n bytes whose size field says size, of this type, tag 1
rawmsg(size, mtype: int, rest: array of byte): array of byte
{
	a := array[7 + len rest] of byte;
	a[0] = byte size;
	a[1] = byte (size>>8);
	a[2] = byte (size>>16);
	a[3] = byte (size>>24);
	a[4] = byte mtype;
	a[5] = byte 1;
	a[6] = byte 0;
	a[7:] = rest;
	return a;
}

le32(v: int): array of byte
{
	return array[] of {byte v, byte (v>>8), byte (v>>16), byte (v>>24)};
}

cat(l: list of array of byte): array of byte
{
	n := 0;
	for(p := l; p != nil; p = tl p)
		n += len hd p;
	a := array[n] of byte;
	o := 0;
	for(p = l; p != nil; p = tl p){
		a[o:] = hd p;
		o += len hd p;
	}
	return a;
}

# what unpack makes of a: its count, or -2 if it raised
tunpack(a: array of byte): int
{
	{
		(n, nil) := Tmsg.unpack(a);
		return n;
	} exception {
	* =>
		return -2;
	}
}

runpack(a: array of byte): int
{
	{
		(n, nil) := Rmsg.unpack(a);
		return n;
	} exception {
	* =>
		return -2;
	}
}

# lengths in a message that are the sender's to choose: refused as an
# illegal message (-1), never an exception in whoever unpacks it
testHostileLengths(t: ref T)
{
	Twrite: con 118;
	Rread: con 117;
	Twstat: con 126;
	fid := le32(7);
	off := array[8] of {* => byte 0};

	# Twrite: count ff ff ff ff is -1 here, less than the bytes left
	a := rawmsg(23, Twrite, cat(fid :: off :: le32(-1) :: nil));
	t.asserteq(tunpack(a), -1, "Twrite with a count of -1");
	a = rawmsg(23, Twrite, cat(fid :: off :: le32(16r7fffffff) :: nil));
	t.asserteq(tunpack(a), -1, "Twrite with a count past its bytes");
	a = rawmsg(28, Twrite, cat(fid :: off :: le32(5) :: array of byte "hello" :: nil));
	t.asserteq(tunpack(a), 28, "Twrite of five bytes is still taken");

	# Rread: the same, and a count so large that header+count wraps
	a = rawmsg(11, Rread, le32(-1));
	t.asserteq(runpack(a), -1, "Rread with a count of -1");
	a = rawmsg(11, Rread, le32(16r7ffffff5));
	t.asserteq(runpack(a), -1, "Rread with a count that wraps the sum");
	a = rawmsg(13, Rread, cat(le32(2) :: array of byte "ok" :: nil));
	t.asserteq(runpack(a), 13, "Rread of two bytes is still taken");

	# the size field itself, in a buffer longer than it says
	long := cat(fid :: off :: le32(0) :: array[20] of {* => byte 0} :: nil);
	t.asserteq(tunpack(rawmsg(int 16r80000000, Twrite, long)), -1, "a size with its top bit set (T)");
	t.asserteq(tunpack(rawmsg(3, Twrite, long)), -1, "a size less than a header (T)");
	t.asserteq(runpack(rawmsg(int 16r80000000, Rread, long)), -1, "a size with its top bit set (R)");
	t.asserteq(runpack(rawmsg(3, Rread, long)), -1, "a size less than a header (R)");

	# Twstat with a stat of no bytes: not a stat of all zeros
	a = rawmsg(13, Twstat, cat(fid :: array[] of {byte 0, byte 0} :: nil));
	t.asserteq(tunpack(a), -1, "Twstat with a stat of no bytes");

	# a Tversion's size is an offer: one no message fits is none
	for(l := 0 :: -1 :: 10 :: 255 :: nil; l != nil; l = tl l){
		(nil, v) := ninep->compatible(ref Tmsg.Version(16rffff, hd l, "9P2000"), 8216, nil);
		t.assertseq(v, "unknown", sys->sprint("a Tversion offering %d bytes is not agreed to", hd l));
	}
	(m, v) := ninep->compatible(ref Tmsg.Version(16rffff, 256, "9P2000"), 8216, nil);
	t.assert(m == 256 && v == "9P2000", sys->sprint("an offer of 256 is taken (%d %s)", m, v));
	(m, v) = ninep->compatible(ref Tmsg.Version(16rffff, 65536, "9P2000"), 8216, nil);
	t.assert(m == 8216 && v == "9P2000", sys->sprint("a larger offer is held to ours (%d %s)", m, v));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	ninep = load Ninep Ninep->PATH;
	if(ninep == nil){
		sys->fprint(sys->fildes(2), "cannot load Ninep: %r\n");
		raise "fail:load";
	}
	ninep->init();

	run("LongStat", testLongStat);
	run("HostileLengths", testHostileLengths);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
