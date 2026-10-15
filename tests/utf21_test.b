implement Utf21Test;

#
# Characters outside the Basic Multilingual Plane: emoji (U+1F680),
# CJK extension B (U+20000), up to the last rune, U+10FFFF.
#
# UTF-8 spends four bytes on these. A Dis string holds runes, and a
# rune used to be 16 bits on hosted platforms, with chartorune in
# lib9 decoding at most three bytes: a four-byte sequence came out as
# four error runes, so `len string bytes` was 4 for one emoji, and
# writing the string back out gave four C2 80 sequences in place of
# the original F0 9F 9A 80. Each case below would have failed then.
#
# The conversions under test are the VM's own (string array of byte,
# array of byte string, s[i] = c, %c, the Sys utf functions), so the
# test runs it both ways:
#   emu -c0 -r . /dis/tests/utf21_test.dis
#   emu -c1 -r . /dis/tests/utf21_test.dis	(s[i] compiled)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "convcs.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Utf21Test: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/utf21_test.b";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Each rune with its UTF-8.
Case: adt {
	name:	string;
	r:	int;
	utf:	array of byte;
};

cases(): list of Case
{
	return
		Case("U+10000 (first beyond the BMP)", 16r10000, array[] of {byte 16rF0, byte 16r90, byte 16r80, byte 16r80}) ::
		Case("U+1F680 (rocket)", 16r1F680, array[] of {byte 16rF0, byte 16r9F, byte 16r9A, byte 16r80}) ::
		Case("U+20000 (CJK extension B)", 16r20000, array[] of {byte 16rF0, byte 16rA0, byte 16r80, byte 16r80}) ::
		Case("U+1D400 (mathematical bold A)", 16r1D400, array[] of {byte 16rF0, byte 16r9D, byte 16r90, byte 16r80}) ::
		Case("U+10FFFF (the last rune)", 16r10FFFF, array[] of {byte 16rF4, byte 16r8F, byte 16rBF, byte 16rBF}) ::
		nil;
}

hex(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++){
		if(i > 0)
			s += " ";
		s += sys->sprint("%.2X", int b[i]);
	}
	return s;
}

# bytes -> string: one rune, the right one.
testDecode(t: ref T)
{
	for(l := cases(); l != nil; l = tl l){
		c := hd l;
		s := string c.utf;
		t.asserteq(len s, 1, c.name+": len of the string");
		if(len s > 0)
			t.asserteq(s[0], c.r, c.name+": the rune");
	}
}

# string -> bytes: four bytes, the ones we started from.
testRoundTrip(t: ref T)
{
	for(l := cases(); l != nil; l = tl l){
		c := hd l;
		b := array of byte string c.utf;
		t.assertseq(hex(b), hex(c.utf), c.name+": bytes -> string -> bytes");
	}
}

# A rune put into a string by index, encoded.
testEncode(t: ref T)
{
	for(l := cases(); l != nil; l = tl l){
		c := hd l;
		s := "x";
		s[0] = c.r;
		t.asserteq(len s, 1, c.name+": len after s[0] = r");
		t.asserteq(s[0], c.r, c.name+": s[0] read back");
		t.assertseq(hex(array of byte s), hex(c.utf), c.name+": string -> bytes");
		t.assertseq(sys->sprint("%c", c.r), s, c.name+": %c");
		# appended past the end, as a string grows
		g := "ab";
		g[len g] = c.r;
		t.asserteq(len g, 3, c.name+": len after appending");
		t.asserteq(g[2], c.r, c.name+": appended rune");
	}
}

# The rune among others: indexing, slicing, concatenation, comparison.
testMixed(t: ref T)
{
	rocket := string array[] of {byte 16rF0, byte 16r9F, byte 16r9A, byte 16r80};
	s := "a" + rocket + "b";
	t.asserteq(len s, 3, "len of a🚀b");
	t.asserteq(s[0], 'a', "s[0]");
	t.asserteq(s[1], 16r1F680, "s[1]");
	t.asserteq(s[2], 'b', "s[2]");
	t.assertseq(s[1:2], rocket, "s[1:2]");
	t.asserteq(len array of byte s, 6, "bytes in a🚀b");

	# a BMP rune beside it: a string that was all two-byte runes
	# must not keep them 16 bits wide when a wider one joins
	bmp := "é" + rocket + "�";
	t.asserteq(len bmp, 3, "len of é🚀\\uFFFD");
	t.asserteq(bmp[0], 16rE9, "é kept");
	t.asserteq(bmp[1], 16r1F680, "rocket beside a BMP rune");
	t.asserteq(bmp[2], 16rFFFD, "U+FFFD kept");

	# runes compare by value, so U+FFFF sorts before U+10000
	t.assert("￿" < rocket, "U+FFFF < U+1F680");
	t.assert(rocket < string array[] of {byte 16rF0, byte 16rA0, byte 16r80, byte 16r80}, "U+1F680 < U+20000");
	t.assert(rocket == "a🚀b"[1:2], "equal to the same rune from a literal");
}

# The same runes written in Limbo source: as themselves, and by \U.
testLiterals(t: ref T)
{
	lit := "🚀";
	t.asserteq(len lit, 1, "len \"🚀\"");
	t.asserteq(lit[0], 16r1F680, "\"🚀\"[0]");
	t.asserteq('🚀', 16r1F680, "'🚀'");
	t.assertseq("\U0001F680", lit, "\\U0001F680");
	t.asserteq(len "\U00020000", 1, "len \\U00020000");
	t.asserteq("\U00020000"[0], 16r20000, "\\U00020000");
	t.asserteq('\U0010FFFF', 16r10FFFF, "'\\U0010FFFF'");
	t.asserteq(len "𠀀𝐀", 2, "len of two literal runes beyond the BMP");
}

# What is not a rune decodes to Sys->UTFerror, one per byte as before,
# and what is not a rune encodes to it. Each bad sequence is followed
# by an 'x': a conversion drops a sequence still incomplete at the end
# of its bytes (a reader using utfbytes keeps those for the next read),
# which is checked on its own below.
testInvalid(t: ref T)
{
	t.asserteq(Sys->UTFerror, 16rFFFD, "Sys->UTFerror");
	t.asserteq(Sys->UTFmax, 4, "Sys->UTFmax");

	bad := array[] of {
		("beyond U+10FFFF", array[] of {byte 16rF4, byte 16r90, byte 16r80, byte 16r80}),
		("overlong U+0000", array[] of {byte 16rF0, byte 16r80, byte 16r80, byte 16r80}),
		("overlong U+FFFF", array[] of {byte 16rF0, byte 16r8F, byte 16rBF, byte 16rBF}),
		("surrogate U+D800", array[] of {byte 16rED, byte 16rA0, byte 16r80}),
		("five-byte lead", array[] of {byte 16rF8, byte 16r88, byte 16r80, byte 16r80, byte 16r80}),
		("truncated U+1F680", array[] of {byte 16rF0, byte 16r9F, byte 16r9A}),
	};
	for(i := 0; i < len bad; i++){
		(name, b) := bad[i];
		bx := array[len b + 1] of byte;
		bx[0:] = b;
		bx[len b] = byte 'x';
		s := string bx;
		t.asserteq(len s, len b + 1, name+": one error rune per byte");
		for(j := 0; j < len b && j < len s; j++)
			if(s[j] != Sys->UTFerror)
				t.error(sys->sprint("%s: s[%d] = %#ux, want UTFerror", name, j, s[j]));
		if(len s == len b + 1)
			t.asserteq(s[len b], 'x', name+": the byte after it");
	}
	t.asserteq(len string array[] of {byte 'a', byte 16rF0, byte 16r9F, byte 16r9A}, 1,
		"a rune incomplete at the end is left out, not taken for errors");

	# runes that cannot be encoded come out as U+FFFD (EF BF BD)
	for(r := array[] of {16r110000, 16rD800, 16rDFFF}; len r > 0; r = r[1:]){
		s := "x";
		s[0] = r[0];
		t.assertseq(hex(array of byte s), "EF BF BD", sys->sprint("%#ux encodes as U+FFFD", r[0]));
	}
}

# Sys's own UTF functions: the ones a reader of a byte stream uses to
# find where a rune ends.
testSysUtf(t: ref T)
{
	rocket := array[] of {byte 16rF0, byte 16r9F, byte 16r9A, byte 16r80};
	for(n := 0; n < 4; n++)
		t.asserteq(sys->utfbytes(rocket[0:n], n), 0, sys->sprint("utfbytes of the first %d bytes", n));
	t.asserteq(sys->utfbytes(rocket, 4), 4, "utfbytes of all four");
	both := array[8] of byte;
	both[0:] = rocket;
	both[4:] = rocket;
	t.asserteq(sys->utfbytes(both, 7), 4, "utfbytes stops before a partial second rune");

	(c, nb, ok) := sys->byte2char(rocket, 0);
	t.asserteq(c, 16r1F680, "byte2char rune");
	t.asserteq(nb, 4, "byte2char length");
	t.asserteq(ok, 1, "byte2char ok");
	(c, nb, ok) = sys->byte2char(rocket[0:3], 0);
	t.asserteq(ok, 0, "byte2char of a partial rune is not ok");

	buf := array[Sys->UTFmax] of byte;
	t.asserteq(sys->char2byte(16r20000, buf, 0), 4, "char2byte U+20000");
	t.assertseq(hex(buf), "F0 A0 80 80", "char2byte bytes");
}

# The report's reproduction: a file holding 🚀 read as a string and
# written back must hold 🚀, not four C2 80s.
testThroughFile(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	text := "launch 🚀 at 𠀀\n";
	sys->fprint(p[0], "%s", text);
	buf := array[64] of byte;
	n := sys->read(p[1], buf, len buf);
	t.asserteq(n, len array of byte text, "bytes through the pipe");
	t.assertseq(hex(buf[0:n]), hex(array of byte text), "bytes written");
	got := string buf[0:n];
	t.assertseq(got, text, "read back as a string");
	t.asserteq(len got, 14, "runes read back");
	t.assertseq(sys->sprint("%q", "🚀"), "🚀", "%q leaves the rune alone");
}

# UTF-16 carries a rune beyond U+FFFF as a surrogate pair; the
# converters must make one rune of the two and two units of the one.
testUtf16(t: ref T)
{
	btos := load Btos "/dis/lib/convcs/utf16_btos.dis";
	stob := load Stob "/dis/lib/convcs/utf16_stob.dis";
	if(btos == nil || stob == nil)
		t.fatal(sys->sprint("cannot load the utf-16 converters: %r"));
	btos->init("be");
	stob->init("be");

	s := "a🚀𠀀";
	(nil, b) := stob->stob(nil, s);
	t.assertseq(hex(b), "00 61 D8 3D DE 80 D8 40 DC 00", "a🚀𠀀 as UTF-16BE");

	(nil, got, nb) := btos->btos(nil, b, -1);
	t.assertseq(got, s, "UTF-16BE back to a string");
	t.asserteq(nb, len b, "bytes consumed");

	# a pair split between two reads: the first leaves the high half
	(st, part, n1) := btos->btos(nil, b[0:4], -1);
	t.assertseq(part, "a", "the pair's first half is held back");
	t.asserteq(n1, 2, "bytes consumed before the split pair");
	(nil, rest, nil) := btos->btos(st, b[n1:], -1);
	t.assertseq(rest, "🚀𠀀", "the pair completed by the next read");

	# halves that are not a pair are errors
	lone := array[] of {byte 16rD8, byte 16r3D, byte 0, byte 'x', byte 16rDE, byte 16r80};
	(nil, bad, nil) := btos->btos(nil, lone, 0);
	t.asserteq(len bad, 3, "lone surrogates: three runes");
	if(len bad == 3){
		t.asserteq(bad[0], Sys->UTFerror, "a high half alone");
		t.asserteq(bad[1], 'x', "the unit after it");
		t.asserteq(bad[2], Sys->UTFerror, "a low half alone");
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Decode", testDecode);
	run("RoundTrip", testRoundTrip);
	run("Encode", testEncode);
	run("Mixed", testMixed);
	run("Literals", testLiterals);
	run("Invalid", testInvalid);
	run("SysUtf", testSysUtf);
	run("ThroughFile", testThroughFile);
	run("Utf16", testUtf16);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
