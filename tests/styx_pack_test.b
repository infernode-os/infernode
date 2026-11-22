implement StyxPackTest;

#
# styx_pack_test - 9P messages packed and unpacked by the 9P libraries.
#
# A Twstat whose stat is 256 bytes or more (a name of 210 bytes) is
# unpacked by Styx: it read its stat count's high byte
# shifted as a byte, so lost it, and refused the message; the reader of
# a styxlib server ended on the refusal, and memfs, on the native
# kernel's /tmp, waited for ever with every client of it (nativefuzz).
#
# Names with runes beyond U+FFFF, and with what is not
# a rune at all, packed by Styx and Venti: a
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
# What is not a message is refused, in Styx as in the kernel's convM2S:
# bytes after a message's last field (they were passed over, and the
# count returned was short of the message), an Rwalk of more qids than
# a walk has names, a string with a zero byte in it (kept as a
# character: a\0b was a three-character name); an Rerror with no text
# has one (an empty string is nil, which reads as no error); a string
# longer than its 16-bit count can say is not packed (it was, with the
# count cut and all its bytes after it), an error's text being cut to
# fit; text() is one line whatever is in a name; nothing is printed on
# standard output for a bad type or a bad stat count; a message the
# connection ends in the middle of is "truncated", not the process's
# last error string or a clean end; istmsg of less than a header is
# false.
#
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "styx.m";
	styx: Styx;

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

# ---- what is not a message, or cannot be one ----

Tclunk: con 120;
Tcreate: con 114;
Twalk: con 110;
Tattach: con 104;
Tversion: con 100;
Rerror: con 107;
Rwalk: con 111;
Rclunk: con 121;

le16(v: int): array of byte
{
	return array[] of {byte v, byte (v>>8)};
}

# a string as a message carries it
str16(s: string): array of byte
{
	b := array of byte s;
	return cat(le16(len b) :: b :: nil);
}

# a message of this type whose size is its length
msg(mtype: int, rest: array of byte): array of byte
{
	return rawmsg(7 + len rest, mtype, rest);
}

# A message's fields end where its size says the message does.  A byte
# after them was passed over, and the count returned was the fields': a
# caller with several messages in hand then took the padding for the
# next message's start.
testTrailingBytes(t: ref T)
{
	Twrite: con 118;
	Rread: con 117;
	pad := array[] of {byte 16rAA};
	fid := le32(7);
	off := array[8] of {* => byte 0};

	t.asserteq(tunpack(msg(Tclunk, fid)), 11, "a Tclunk");
	t.asserteq(tunpack(msg(Tclunk, cat(fid :: pad :: nil))), -1, "a Tclunk with a byte after its fid");
	t.asserteq(tunpack(msg(Tversion, cat(le32(8192) :: str16("9P2000") :: pad :: nil))), -1, "a Tversion with a byte after its version");
	t.asserteq(tunpack(msg(Tattach, cat(fid :: le32(-1) :: str16("u") :: str16("") :: pad :: nil))), -1, "a Tattach with a byte after its names");
	t.asserteq(tunpack(msg(Twalk, cat(fid :: le32(8) :: le16(1) :: str16("a") :: pad :: nil))), -1, "a Twalk with a byte after its names");
	t.asserteq(tunpack(msg(Tcreate, cat(fid :: str16("f") :: le32(8r644) :: array[] of {byte 1} :: pad :: nil))), -1, "a Tcreate with a byte after its mode");
	t.asserteq(tunpack(msg(Twrite, cat(fid :: off :: le32(5) :: array of byte "hello" :: pad :: nil))), -1, "a Twrite with a byte after its data");
	t.asserteq(runpack(msg(Rclunk, nil)), 7, "an Rclunk");
	t.asserteq(runpack(msg(Rclunk, pad)), -1, "an Rclunk with a byte after it");
	t.asserteq(runpack(msg(Rerror, cat(str16("no") :: pad :: nil))), -1, "an Rerror with a byte after its text");
	t.asserteq(runpack(msg(Rread, cat(le32(2) :: array of byte "ok" :: pad :: nil))), -1, "an Rread with a byte after its data");
	t.asserteq(runpack(msg(Rwalk, cat(le16(1) :: array[13] of {* => byte 0} :: pad :: nil))), -1, "an Rwalk with a byte after its qids");

	# two whole messages in hand: the first, by its own size
	two := cat(msg(Tclunk, fid) :: msg(Tclunk, le32(9)) :: nil);
	t.asserteq(tunpack(two), 11, "the first of two messages");
	t.asserteq(tunpack(two[11:]), 11, "and the second");
}

# No more qids come back from a walk than a walk has names.
testWalkCount(t: ref T)
{
	t.asserteq(runpack(msg(Rwalk, cat(le16(16) :: array[16*13] of {* => byte 0} :: nil))), 7+2+16*13, "an Rwalk of 16 qids");
	t.asserteq(runpack(msg(Rwalk, cat(le16(17) :: array[17*13] of {* => byte 0} :: nil))), -1, "an Rwalk of 17 qids");
	names: list of array of byte;
	for(i := 0; i < 17; i++)
		names = str16("a") :: names;
	t.asserteq(tunpack(msg(Twalk, cat(le32(1) :: le32(2) :: le16(17) :: cat(names) :: nil))), -1, "a Twalk of 17 names");

	# and neither is packed
	t.assert((ref Tmsg.Walk(1, 1, 2, array[17] of {* => "a"})).pack() == nil, "a Twalk of 17 names is not packed");
	t.assert((ref Rmsg.Walk(1, array[17] of Sys->Qid)).pack() == nil, "an Rwalk of 17 qids is not packed");
	t.assert((ref Tmsg.Walk(1, 1, 2, array[16] of {* => "a"})).pack() != nil, "a Twalk of 16 is");
}

# A zero byte in a name, a user, a version or an error is no part of a
# string: the message is refused.
testNulInStrings(t: ref T)
{
	fid := le32(7);
	nul := array[] of {byte 3, byte 0, byte 'a', byte 0, byte 'b'};	# "a\0b"
	t.asserteq(tunpack(msg(Tcreate, cat(fid :: nul :: le32(8r644) :: array[] of {byte 1} :: nil))), -1, "a Tcreate of a\\0b");
	t.asserteq(tunpack(msg(Twalk, cat(fid :: le32(8) :: le16(2) :: str16("ok") :: nul :: nil))), -1, "a Twalk to a\\0b");
	t.asserteq(tunpack(msg(Tattach, cat(fid :: le32(-1) :: nul :: str16("") :: nil))), -1, "a Tattach by a\\0b");
	t.asserteq(tunpack(msg(Tattach, cat(fid :: le32(-1) :: str16("u") :: nul :: nil))), -1, "a Tattach to a\\0b");
	t.asserteq(tunpack(msg(Tversion, cat(le32(8192) :: nul :: nil))), -1, "a Tversion of a\\0b");
	t.asserteq(runpack(msg(Rerror, nul)), -1, "an Rerror of a\\0b");
	t.asserteq(tunpack(msg(Tcreate, cat(fid :: str16("ab") :: le32(8r644) :: array[] of {byte 1} :: nil))), 7+4+4+4+1, "a Tcreate of ab is still taken");

	# in a stat's name
	d := styx->packdir(dirnamed("a.b"));
	d[41+2+1] = byte 0;
	(n, nil) := styx->unpackdir(d);
	t.asserteq(n, 0, "a stat whose name is a\\0b");
}

# An Rerror with no text is still an error to whoever reads it.
testEmptyError(t: ref T)
{
	(n, m) := Rmsg.unpack(msg(Rerror, str16("")));
	t.asserteq(n, 9, "an Rerror with no text is a message");
	if(m != nil)
		pick e := m {
		Error =>
			t.assert(e.ename != nil, "and its text is not nil, which reads as no error");
		* =>
			t.error("not an Rmsg.Error");
		}
}

# A string too long for its 16-bit count is not packed with the count
# cut and all of its bytes after it; an error's text is cut instead.
testLongStrings(t: ref T)
{
	s := "";
	for(i := 0; i < 70000; i++)
		s[i] = 'x';
	t.assert((ref Tmsg.Create(1, 1, s, 8r644, 0)).pack() == nil, "a Tcreate of a 70000-byte name is not packed");
	t.assert((ref Tmsg.Attach(1, 1, -1, s, "")).pack() == nil, "nor a Tattach by such a user");
	t.assert((ref Tmsg.Walk(1, 1, 2, array[] of {"a", s})).pack() == nil, "nor a Twalk to such a name");
	t.assert((ref Tmsg.Version(1, 8192, s)).pack() == nil, "nor a Tversion");
	t.assert((ref Tmsg.Wstat(1, 1, dirnamed(s))).pack() == nil, "nor a Twstat");
	t.assert((ref Rmsg.Stat(1, dirnamed(s))).pack() == nil, "nor an Rstat");
	t.assert((ref Tmsg.Create(1, 1, s[0:65535], 8r644, 0)).pack() != nil, "one of 65535 bytes is");

	r := ref Rmsg.Error(1, s);
	a := r.pack();
	t.assert(a != nil, "an Rerror of 70000 bytes is packed");
	if(a == nil)
		return;
	t.asserteq(len a, r.packedsize(), "as long as its packedsize");
	(n, m) := Rmsg.unpack(a);
	t.asserteq(n, len a, "and unpacks as one message");
	if(m != nil)
		pick e := m {
		Error =>
			t.asserteq(len e.ename, 65535, "its text cut to what the count can say");
		}
	# a text of runes is cut between them
	u := "";
	for(i = 0; i < 30000; i++)
		u[i] = 16r4e16;	# three bytes each
	a = (ref Rmsg.Error(1, u)).pack();
	(n, m) = Rmsg.unpack(a);
	t.asserteq(n, len a, "an Rerror of 90000 bytes of runes unpacks as one message");
	if(m != nil)
		pick e := m {
		Error =>
			t.asserteq(len e.ename, 21845, "of whole runes");
		}
}

hasnl(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || s[i] == '\r')
			return 1;
	return 0;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# text() writes one message as one line, whatever is in its names.
testTextOneLine(t: ref T)
{
	evil := "a\"\nTmsg.Clunk(9,9)";
	s := (ref Tmsg.Walk(1, 1, 2, array[] of {evil})).text();
	t.assert(!hasnl(s), "a Twalk's text: " + s);
	t.assert(contains(s, "\\\"") && contains(s, "\\n"), "the quote and the newline written as Limbo writes them");
	t.assert(!hasnl((ref Tmsg.Create(1, 1, evil, 8r644, 0)).text()), "a Tcreate's text");
	t.assert(!hasnl((ref Tmsg.Attach(1, 1, -1, evil, evil)).text()), "a Tattach's text");
	t.assert(!hasnl((ref Tmsg.Version(1, 8192, evil)).text()), "a Tversion's text");
	t.assert(!hasnl((ref Tmsg.Wstat(1, 1, dirnamed(evil))).text()), "a Twstat's text");
	t.assert(!hasnl((ref Rmsg.Error(1, evil + "\r")).text()), "an Rerror's text");
	t.assert(!hasnl((ref Rmsg.Stat(1, dirnamed(evil))).text()), "an Rstat's text");
	t.assertseq((ref Tmsg.Walk(1, 1, 2, array[] of {"plain", "names"})).text(),
		"Tmsg.Walk(1,1,2,array[] of {\"plain\",\"names\"})", "plain names as before");
}

# unpack in a process whose standard output is p: what it wrote there
quiet(a: array of byte, p: ref Sys->FD, done: chan of int)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(p.fd, 1);
	p = nil;
	Tmsg.unpack(a);
	Rmsg.unpack(a);
	done <-= 1;
}

# A message of no known type, or a stat whose count is wrong, is
# refused and nothing is printed: the unpackers wrote of it on standard
# output, which is the server's own (a file being served, a pipe to
# another program).
testQuiet(t: ref T)
{
	Twstat: con 126;
	Rstat: con 125;
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.skip("no pipe");
	done := chan of int;
	bad := msg(2, array[4] of {* => byte 0});
	spawn quiet(bad, fds[1], done);
	<-done;
	spawn quiet(msg(3, array[4] of {* => byte 0}), fds[1], done);
	<-done;
	# a stat inside a count two bytes too long
	d := styx->packdir(dirnamed("f"));
	w := msg(Twstat, cat(le32(7) :: le16(len d + 2) :: d :: array[2] of {* => byte 0} :: nil));
	spawn quiet(w, fds[1], done);
	<-done;
	r := msg(Rstat, cat(le16(len d + 2) :: d :: array[2] of {* => byte 0} :: nil));
	spawn quiet(r, fds[1], done);
	<-done;
	fds[1] = nil;
	buf := array[256] of byte;
	n := sys->read(fds[0], buf, len buf);
	if(n < 0)
		n = 0;
	t.assertseq(string buf[0:n], "", "written on standard output");
	t.asserteq(tunpack(bad), -1, "a message of type 2 is refused");

	# a runt has no type to be a T-message by
	t.asserteq(styx->istmsg(array[3] of {* => byte 0}), 0, "istmsg of three bytes");
	t.asserteq(styx->istmsg(msg(Tclunk, le32(7))), 1, "istmsg of a Tclunk");
	t.asserteq(styx->istmsg(msg(Rclunk, nil)), 0, "istmsg of an Rclunk");
}

# what readmsg gives for these bytes and then the end of the file
cut(b: array of byte): (array of byte, string)
{
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	if(len b > 0)
		sys->write(fds[1], b, len b);
	fds[1] = nil;
	# an error string from some earlier call, as a server always has
	sys->open("/nonexistent/styx_pack_test", Sys->OREAD);
	return styx->readmsg(fds[0], 8192);
}

# A message the connection ended in the middle of is said to be that:
# not another call's error, and not a clean end.
testCutMessage(t: ref T)
{
	(a, err) := cut(nil);
	t.assert(a == nil && err == nil, "no bytes at all is the end: " + err);
	(a, err) = cut(array[] of {byte 9, byte 0});
	t.assert(a == nil, "two bytes of a header are no message");
	t.assertseq(err, "9P message truncated", "and the error says so");
	(a, err) = cut(array[] of {byte 11, byte 0, byte 0, byte 0, byte Tclunk, byte 1});
	t.assert(a == nil, "a header and part of a body are no message");
	t.assertseq(err, "9P message truncated", "and the error says so");
	(a, err) = cut(array[] of {byte 11, byte 0, byte 0, byte 0});
	t.assertseq(err, "9P message truncated", "a size and nothing after it");
	(a, err) = cut(msg(Tclunk, le32(7)));
	t.assert(a != nil && len a == 11 && err == nil, "a whole message is read: " + err);

	# through Tmsg.read: an error, not the nil of a clean end
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	sys->write(fds[1], array[] of {byte 9, byte 0}, 2);
	fds[1] = nil;
	sys->werrstr("");
	m := Tmsg.read(fds[0], 8192);
	t.assert(m != nil && tagof m == tagof Tmsg.Readerror, "Tmsg.read of two bytes is a Readerror");
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
	venti = load Venti Venti->PATH;
	if(styx == nil || venti == nil){
		sys->fprint(sys->fildes(2), "cannot load Styx or Venti: %r\n");
		raise "fail:load";
	}
	styx->init();
	venti->init();

	run("UtfBytes", testUtfBytes);
	run("StyxPackdir", testStyxPackdir);
	run("StyxMessages", testStyxMessages);
	run("LongStat", testLongStat);
	run("Venti", testVenti);
	run("HostileLengths", testHostileLengths);
	run("TrailingBytes", testTrailingBytes);
	run("WalkCount", testWalkCount);
	run("NulInStrings", testNulInStrings);
	run("EmptyError", testEmptyError);
	run("LongStrings", testLongStrings);
	run("TextOneLine", testTextOneLine);
	run("Quiet", testQuiet);
	run("CutMessage", testCutMessage);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
