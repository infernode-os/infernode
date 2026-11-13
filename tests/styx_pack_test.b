implement StyxPackTest;

#
# styx_pack_test - 9P messages packed and unpacked by the 9P libraries.
#
# A Twstat whose stat is 256 bytes or more (a name of 210 bytes) is
# unpacked by Styx and Ninep: they read its stat count's high byte
# shifted as a byte, so lost it, and refused the message; the reader of
# a styxlib server ended on the refusal, and memfs, on the native
# kernel's /tmp, waited for ever with every client of it (nativefuzz).
#
# Names with runes beyond U+FFFF, and with what is not
# a rune at all, packed by the 9P libraries (Styx, Ninep) and Venti: a
# message or directory entry is the length its packedsize says, and
# unpacks to what was packed.
#
# Lengths the sender chooses (a Twrite's or an Rread's count, the size
# field, a Twstat's stat) are refused as an illegal message, where a
# count of ff ff ff ff, -1 here, passed the check against the bytes left
# and the slice f[O:O-1] ended the server's reader; and a Tversion that
# offers a size no message fits is not agreed to.
#
# Their utflen counted 16-bit runes, three bytes at most; U+1F680 is
# four in UTF-8, so packdir's array was a byte short of a name with it,
# and the server packing a directory read with such a file in it died
# of an array bounds error (tools/nativefuzz: memfs on the native
# kernel's /tmp, then every program using /tmp hung on it). A rune that
# is not one (negative, or past U+10FFFF) is U+FFFD's three bytes, and
# was counted as one.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "styx.m";
	styx: Styx;

include "9p.m";
	ninep: Ninep;

include "venti.m";
	venti: Venti;

	Tmsg, Rmsg: import styx;
	Vmsg: import venti;

include "testing.m";
	testing: Testing;
	T: import testing;

StyxPackTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/styx_pack_test.b";

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

# names, with the bytes each is in UTF-8
names(): array of (string, int)
{
	s := "x";
	neg := "a";
	neg[0] = -1;
	far := "b";
	far[0] = 16r110000;
	sur := "c";
	sur[0] = 16rD800;
	return array[] of {
		("plain", 5),
		("é", 2),
		("€", 3),
		("￿", 3),
		("\U0001F680", 4),
		("é\U0001F680" + s, 7),
		("\U0010FFFF\U00010000", 8),
		(neg, 3),
		(far, 3),
		(sur, 3),
	};
}

dirnamed(n: string): Sys->Dir
{
	d := sys->nulldir;
	d.name = n;
	d.uid = n;
	d.gid = "g" + n;
	d.muid = n + "m";
	d.qid = Sys->Qid(big 42, 7, Sys->QTFILE);
	d.mode = 8r644;
	d.length = big 99;
	return d;
}

testUtfBytes(t: ref T)
{
	ns := names();
	for(i := 0; i < len ns; i++){
		(n, want) := ns[i];
		t.asserteq(len array of byte n, want, sys->sprint("name %d is %d bytes in UTF-8", i, want));
	}
}

testStyxPackdir(t: ref T)
{
	ns := names();
	for(i := 0; i < len ns; i++){
		(n, nil) := ns[i];
		d := dirnamed(n);
		a: array of byte;
		{
			a = styx->packdir(d);
		} exception e {
		"*" =>
			t.error(sys->sprint("name %d: packdir raised %s", i, e));
			continue;
		}
		t.asserteq(len a, styx->packdirsize(d), sys->sprint("name %d: packdir's length is packdirsize", i));
		(m, u) := styx->unpackdir(a);
		t.asserteq(m, len a, sys->sprint("name %d: unpackdir takes all of it", i));
		t.assertseq(u.uid, string array of byte n, sys->sprint("name %d: uid unpacked", i));
		t.assertseq(u.muid, string array of byte (n + "m"), sys->sprint("name %d: muid unpacked", i));
	}
}

testStyxMessages(t: ref T)
{
	ns := names();
	for(i := 0; i < len ns; i++){
		(n, nil) := ns[i];
		msgs := array[] of {
			ref Tmsg.Walk(1, 2, 3, array[] of {n, "b" + n, n}),
			ref Tmsg.Create(1, 2, n, 8r666, Sys->OWRITE),
			ref Tmsg.Wstat(1, 2, dirnamed(n)),
			ref Tmsg.Attach(1, 2, Styx->NOFID, n, n),
		};
		for(j := 0; j < len msgs; j++){
			a: array of byte;
			{
				a = msgs[j].pack();
			} exception e {
			"*" =>
				t.error(sys->sprint("name %d message %d: pack raised %s", i, j, e));
				continue;
			}
			t.asserteq(len a, msgs[j].packedsize(), sys->sprint("name %d message %d: packed length", i, j));
			(m, nil) := Tmsg.unpack(a);
			t.asserteq(m, len a, sys->sprint("name %d message %d: unpacks whole", i, j));
		}
		rs := array[] of {
			ref Rmsg.Stat(1, dirnamed(n)),
			ref Rmsg.Error(1, n),
		};
		for(j = 0; j < len rs; j++){
			a: array of byte;
			{
				a = rs[j].pack();
			} exception e {
			"*" =>
				t.error(sys->sprint("name %d reply %d: pack raised %s", i, j, e));
				continue;
			}
			t.asserteq(len a, rs[j].packedsize(), sys->sprint("name %d reply %d: packed length", i, j));
		}
	}
}

testNinep(t: ref T)
{
	ns := names();
	for(i := 0; i < len ns; i++){
		(n, nil) := ns[i];
		d := dirnamed(n);
		a: array of byte;
		{
			a = ninep->packdir(d);
		} exception e {
		"*" =>
			t.error(sys->sprint("name %d: Ninep packdir raised %s", i, e));
			continue;
		}
		t.asserteq(len a, ninep->packdirsize(d), sys->sprint("name %d: Ninep packdir's length", i));
	}
}

# a Twstat, a Tcreate and an Rstat around the 255-byte boundary, both ways
testLongStat(t: ref T)
{
	for(nl := 190; nl <= 1000; nl += nl/7){
		d := dirnamed("");
		d.name = "";
		for(i := 0; i < nl; i++)
			d.name[i] = 'a' + i%26;
		w := ref Tmsg.Wstat(3, 16r66, d);
		a := w.pack();
		(n, u) := Tmsg.unpack(a);
		t.asserteq(n, len a, sys->sprint("Styx Twstat, name of %d: unpacked whole", nl));
		if(u != nil)
			pick m := u {
			Wstat =>
				t.assertseq(m.stat.name, d.name, sys->sprint("Styx Twstat, name of %d: the name", nl));
			* =>
				t.error("Styx Twstat unpacked as something else");
			}
		# Ninep's Tmsg cannot be imported beside Styx's: ninep_pack_test
		r := ref Rmsg.Stat(3, d);
		ra := r.pack();
		(rn, nil) := Rmsg.unpack(ra);
		t.asserteq(rn, len ra, sys->sprint("Styx Rstat, name of %d: unpacked whole", nl));
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
		(nil, v) := styx->compatible(ref Tmsg.Version(16rffff, hd l, "9P2000"), 8216, nil);
		t.assertseq(v, "unknown", sys->sprint("a Tversion offering %d bytes is not agreed to", hd l));
	}
	(m, v) := styx->compatible(ref Tmsg.Version(16rffff, 256, "9P2000"), 8216, nil);
	t.assert(m == 256 && v == "9P2000", sys->sprint("an offer of 256 is taken (%d %s)", m, v));
	(m, v) = styx->compatible(ref Tmsg.Version(16rffff, 65536, "9P2000"), 8216, nil);
	t.assert(m == 8216 && v == "9P2000", sys->sprint("a larger offer is held to ours (%d %s)", m, v));
}

testVenti(t: ref T)
{
	ns := names();
	for(i := 0; i < len ns; i++){
		(n, nil) := ns[i];
		m := ref Vmsg.Rerror(0, 1, n);
		{
			a := m.pack();
			t.asserteq(len a, m.packedsize(), sys->sprint("name %d: Venti Rerror's length", i));
		} exception e {
		"*" =>
			t.error(sys->sprint("name %d: Venti Rerror pack raised %s", i, e));
		}
	}
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

	styx = load Styx Styx->PATH;
	ninep = load Ninep Ninep->PATH;
	venti = load Venti Venti->PATH;
	if(styx == nil || ninep == nil || venti == nil){
		sys->fprint(sys->fildes(2), "cannot load Styx, Ninep or Venti: %r\n");
		raise "fail:load";
	}
	styx->init();
	ninep->init();
	venti->init();

	run("UtfBytes", testUtfBytes);
	run("StyxPackdir", testStyxPackdir);
	run("StyxMessages", testStyxMessages);
	run("Ninep", testNinep);
	run("LongStat", testLongStat);
	run("Venti", testVenti);
	run("HostileLengths", testHostileLengths);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
