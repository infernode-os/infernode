implement NinepUtfTest;

#
# 9P messages carrying runes beyond U+FFFF (U+1F680, four bytes of
# UTF-8) pack whole and read back the same, through Styx (styx.m, the
# library styxservers serves with; styx_utf_test.b) and 9P2000 (9p.m,
# here).  Their utflen
# counted three bytes for any rune past 16r7FF: a message holding one
# (an error, a name in a stat or a walk) was packed past its end, and
# the server sending it died ("array bounds error"), luciuisrv among
# them, when a command it refused had a 🚀 in it.  A rune past U+10FFFF
# is sent as U+FFFD, three bytes.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "9p.m";
	ninep: Ninep;
	Rmsg, Tmsg: import ninep;
include "testing.m";
	testing: Testing;
	T: import testing;

NinepUtfTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ninep_utf_test.b";

passed := 0;
failed := 0;
skipped := 0;

ROCKET: con "🚀";

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

# The size a packed message says it is, from its first four bytes
size(d: array of byte): int
{
	return int d[0] | (int d[1] << 8) | (int d[2] << 16) | (int d[3] << 24);
}

beyond(): string
{
	s := "x";
	s[0] = 16r110000;
	return s;
}

dir(name: string): Sys->Dir
{
	d := sys->nulldir;
	d.name = name;
	d.uid = "é漢" + ROCKET;
	d.gid = "g";
	d.muid = ROCKET;
	d.qid = Sys->Qid(big 1, 0, 0);
	d.mode = 8r644;
	d.atime = d.mtime = 0;
	d.length = big 0;
	d.dtype = d.dev = 0;
	return d;
}

# ---------- 9P2000 ----------

nrerror(t: ref T, ename, want: string)
{
	m := ref Rmsg.Error(7, ename);
	d := m.pack();
	t.asserteq(len d, m.packedsize(), "packed as long as its size");
	t.asserteq(size(d), len d, "its size field says so");
	(n, r) := Rmsg.unpack(d);
	t.asserteq(n, len d, "read back whole");
	pick e := r {
	Error =>
		t.assertseq(e.ename, want, "the error read back");
	* =>
		t.error("read back as another message");
	}
}

testNinepError(t: ref T)
{
	nrerror(t, ROCKET + " lift-off", ROCKET + " lift-off");
	nrerror(t, beyond(), "�");
}

testNinepWalk(t: ref T)
{
	names := array[] of {"a", ROCKET, "é漢"};
	m := ref Tmsg.Walk(5, 1, 2, names);
	d := m.pack();
	t.asserteq(len d, m.packedsize(), "packed as long as its size");
	(n, r) := Tmsg.unpack(d);
	t.asserteq(n, len d, "read back whole");
	pick w := r {
	Walk =>
		for(i := 0; i < len names && i < len w.names; i++)
			t.assertseq(w.names[i], names[i], "a name read back");
	* =>
		t.error("read back as another message");
	}
}

testNinepStat(t: ref T)
{
	m := ref Rmsg.Stat(3, dir(ROCKET + ".txt"));
	d := m.pack();
	t.asserteq(len d, m.packedsize(), "packed as long as its size");
	(n, r) := Rmsg.unpack(d);
	t.asserteq(n, len d, "read back whole");
	pick s := r {
	Stat =>
		t.assertseq(s.stat.name, ROCKET + ".txt", "the name read back");
	* =>
		t.error("read back as another message");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	ninep = load Ninep Ninep->PATH;
	if(testing == nil || ninep == nil){
		sys->fprint(sys->fildes(2), "cannot load a module: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	ninep->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("NinepError", testNinepError);
	run("NinepWalk", testNinepWalk);
	run("NinepStat", testNinepStat);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
