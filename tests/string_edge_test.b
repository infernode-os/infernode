implement StringEdgeTest;

#
# Strings at their edges (libinterp/string.c).
#
# An empty string that is not nil (string array[0] of byte) has room
# counted in bytes.  A rune stored at its end was allowed for as many
# runes as it had bytes of room, four bytes each: the stores went on over
# the blocks after it, with values the program chooses.
#
# A string made from bytes whose last few are no rune and no start of one
# lost them and everything after: `a E2 b` was "a".
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

StringEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/string_edge_test.b";

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

changed(guards: array of array of byte): int
{
	bad := 0;
	for(i := 0; i < len guards; i++)
		for(j := 0; j < len guards[i]; j++)
			if(guards[i][j] != byte 16r55)
				bad++;
	return bad;
}

# n empty strings that are not nil, with a guard array allocated after each
empties(n: int): (array of string, array of array of byte)
{
	strs := array[n] of string;
	guards := array[n] of array of byte;
	e := array[0] of byte;
	for(i := 0; i < n; i++){
		strs[i] = string e;
		guards[i] = array[24] of {* => byte 16r55};
	}
	return (strs, guards);
}

fill(t: ref T, what: string, r: int)
{
	N: con 200;
	(strs, guards) := empties(N);
	bad := 0;
	for(i := 0; i < N; i++){
		s := strs[i];
		strs[i] = nil;	# one reference: the store is in place
		for(j := 0; j < 64; j++)
			s[j] = r;
		if(len s != 64)
			bad++;
		for(j = 0; j < len s; j++)
			if(s[j] != r){
				bad++;
				break;
			}
		strs[i] = s;
	}
	t.asserteq(bad, 0, what + ": each string is its 64 characters");
	t.asserteq(changed(guards), 0, what + ": and the arrays allocated between them are as they were");
}

testEmptyString(t: ref T)
{
	fill(t, "runes stored into empty strings", 16rE9);
	fill(t, "large runes", 16r1F680);
	fill(t, "ASCII", 'x');

	# appended to
	(strs, guards) := empties(100);
	bad := 0;
	for(i := 0; i < len strs; i++){
		s := strs[i];
		strs[i] = nil;
		for(j := 0; j < 20; j++)
			s += "éa€";
		if(len s != 60 || s[0] != 16rE9 || s[59] != 16r20AC)
			bad++;
		strs[i] = s;
	}
	t.asserteq(bad, 0, "runes appended to empty strings");
	t.asserteq(changed(guards), 0, "the arrays between them");

	# a rune, then ASCII, then a rune past the room there was
	(strs, guards) = empties(100);
	bad = 0;
	for(i = 0; i < len strs; i++){
		s := strs[i];
		strs[i] = nil;
		s[0] = 16r263A;
		for(j := 1; j < 40; j++)
			s[j] = 'a' + j % 26;
		s[40] = 16rE9;
		if(len s != 41 || s[0] != 16r263A || s[39] != 'a' + 39 % 26 || s[40] != 16rE9)
			bad++;
		strs[i] = s;
	}
	t.asserteq(bad, 0, "a rune, ASCII and a rune stored into empty strings");
	t.asserteq(changed(guards), 0, "the arrays between them");

	# an index past the end is still refused, and the string still empty
	s := string array[0] of byte;
	e := "";
	{
		s[1] = 16rE9;
	} exception ex {
	"*" =>
		e = ex;
	}
	t.assertseq(e, "array bounds error", "a rune stored past an empty string's end");
	t.asserteq(len s, 0, "which is still empty");
}

runes(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		if(i > 0)
			r += " ";
		r += sys->sprint("%x", s[i]);
	}
	return r;
}

conv(t: ref T, b: array of byte, want: string, what: string)
{
	# at the very end of an array, and with bytes after it
	t.assertseq(runes(string b), want, what);
	c := array[len b + 8] of {* => byte 'Z'};
	c[0:] = b;
	t.assertseq(runes(string c[0:len b]), want, what + ", as a slice");
}

testBadTail(t: ref T)
{
	conv(t, array[] of {byte 'a', byte 16rE2, byte 'b'}, "61 fffd 62", "a E2 b");
	conv(t, array[] of {byte 'a', byte 16rF0, byte 'b', byte 'c'}, "61 fffd 62 63", "a F0 b c");
	conv(t, array[] of {byte 'a', byte 16rE2, byte 'b', byte 'c', byte 'd'}, "61 fffd 62 63 64", "a E2 b c d");
	conv(t, array[] of {byte 'a', byte 16rFF}, "61 fffd", "a FF");
	conv(t, array[] of {byte 'a', byte 16rFF, byte 'b'}, "61 fffd 62", "a FF b");
	conv(t, array[] of {byte 'a', byte 16r80}, "61 fffd", "a 80");
	conv(t, array[] of {byte 'a', byte 16rC3, byte '\n'}, "61 fffd a", "a C3 newline");
	conv(t, array[] of {byte 16rE2, byte 16r82, byte 'x'}, "fffd fffd 78", "E2 82 x");
	# the start of a rune, cut off: left out
	conv(t, array[] of {byte 'a', byte 16rE2}, "61", "a E2");
	conv(t, array[] of {byte 'a', byte 16rE2, byte 16r82}, "61", "a E2 82");
	conv(t, array[] of {byte 16rF0, byte 16r9F, byte 16r9A}, "", "F0 9F 9A");
	conv(t, array[] of {byte 'a', byte 16rC3}, "61", "a C3");
	# whole
	conv(t, array[] of {byte 'a', byte 16rE2, byte 16r82, byte 16rAC}, "61 20ac", "a and a euro");
	conv(t, array[] of {byte 16rF0, byte 16r9F, byte 16r9A, byte 16r80}, "1f680", "a rocket");
	conv(t, array[] of {byte 16rC3, byte 16rA9}, "e9", "e acute");
	conv(t, array[0] of byte, "", "no bytes");
	conv(t, array[] of {byte 'a', byte 'b'}, "61 62", "ASCII");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("BadTail", testBadTail);
	run("EmptyString", testEmptyString);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
