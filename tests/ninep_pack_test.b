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
	Tmsg: import ninep;

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

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
