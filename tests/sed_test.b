implement SedTest;

#
# sed(1): malformed scripts are errors, not crashes; D ends.
#
# Found on the bare-metal Pi during a soak: a mistyped `sed s/ ...`
# killed sed with "dereference of nil" -- recomp read the pattern past
# the end of the script. Scanning every command letter in short forms
# then found `echo abc | sed D` never returned (D with no newline
# restarted the cycle on the same text instead of acting as d), and that
# D's restart ran D again on the remainder rather than the script from
# the top, so N;P;D printed only its first line.
#
# Each case runs a fresh sed (its state is module-global) in its own
# process with piped input and output, under a timeout, so a crash is a
# failed case and a hang a timed-out one rather than a stuck suite.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

SedTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# what /dis/sed.dis is, for loading it
SedCmd: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sed_test.b";
TIMEOUT: con 5000;

passed := 0;
failed := 0;
skipped := 0;

# Cases are called by name, not passed as ref fn: a module that takes a
# reference to its own function, then loads another (sed, here), links
# that load against the wrong import list ("link failed fn
# Sed->testDRestart() not implemented"), a compiler bug of its own.
run(name: string)
{
	t := testing->newTsrc(name, SRCFILE);
	{
		case name {
		"Unclosed" =>		testUnclosed(t);
		"ShortScripts" =>	testShortScripts(t);
		"DWithoutNewline" =>	testDWithoutNewline(t);
		"DRestart" =>		testDRestart(t);
		"Ordinary" =>		testOrdinary(t);
		}
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

# run sed with args on input: (what it wrote, how it ended)
# how: "ok", "error" (sed reported a fault), "crash: <exception>", "timeout"
runsed(args: list of string, input: string): (string, string)
{
	inp := array[2] of ref Sys->FD;
	outp := array[2] of ref Sys->FD;
	if(sys->pipe(inp) < 0 || sys->pipe(outp) < 0)
		return (nil, "crash: no pipe");
	how := chan[1] of string;
	spawn child(args, inp[1], outp[1], how);
	inp[1] = outp[1] = nil;
	got := chan[1] of string;
	spawn reader(outp[0], got);
	outp[0] = nil;
	sys->write(inp[0], array of byte input, len array of byte input);
	inp[0] = nil;
	tmo := chan[1] of int;
	spawn timer(tmo);
	out: string;
	alt {
	out = <-got =>
		;
	<-tmo =>
		return (nil, "timeout");
	}
	alt {
	h := <-how =>
		return (out, h);
	* =>
		return (out, "ok");	# sed ends with exit, which sends nothing
	}
}

child(args: list of string, i, o: ref Sys->FD, how: chan of string)
{
	sys->pctl(Sys->NEWFD, i.fd :: o.fd :: nil);
	sys->dup(i.fd, 0);
	sys->dup(o.fd, 1);
	sys->dup(o.fd, 2);
	i = o = nil;
	cmd := load SedCmd "/dis/sed.dis";
	if(cmd == nil){
		how <-= sys->sprint("crash: cannot load /dis/sed.dis: %r");
		return;
	}
	{
		cmd->init(nil, "sed" :: args);
	} exception e {
	"fail:*" =>
		how <-= "error";
	"*" =>
		how <-= "crash: " + e;
	}
}

reader(fd: ref Sys->FD, got: chan of string)
{
	s := "";
	buf := array[1024] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	got <-= s;
}

timer(c: chan of int)
{
	sys->sleep(TIMEOUT);
	c <-= 1;
}

# unclosed patterns are reported, not crashes
testUnclosed(t: ref T)
{
	for(l := list of {"s/", "s/a", "s/x\\\\", "s", "/a", "/a/p;s/"}; l != nil; l = tl l){
		(out, how) := runsed(hd l :: nil, "abc\n");
		t.assertseq(how, "error", "sed '" + hd l + "' ends in an error");
		t.assert(len out > 0, "sed '" + hd l + "' says what is wrong");
	}
}

# every command letter, alone and with a stray delimiter: no crash, no hang
testShortScripts(t: ref T)
{
	cmds := "abcdDgGhHilnNpPqrstwxy={}:!";
	for(i := 0; i < len cmds; i++){
		c := cmds[i:i+1];
		for(l := list of {c, c + "/", "1" + c, c + "/a"}; l != nil; l = tl l){
			if(hd l == "w" || hd l == "1w" || hd l == "r" || hd l == "1r")
				continue;	# names a file: not this test's business
			(nil, how) := runsed(hd l :: nil, "abc\n");
			t.assert(how == "ok" || how == "error",
				sys->sprint("sed '%s' ended %s", hd l, how));
		}
	}
}

# D with no newline is d
testDWithoutNewline(t: ref T)
{
	(out, how) := runsed("D" :: nil, "abc\n");
	t.assertseq(how, "ok", "sed D returns");
	t.assertseq(out, "", "and deletes the line");
}

# D restarts the script on what is left
testDRestart(t: ref T)
{
	(out, how) := runsed("$!N;$!D" :: nil, "a\nb\nc\nd\n");
	t.assertseq(how, "ok", "$!N;$!D returns");
	t.assertseq(out, "c\nd\n", "$!N;$!D keeps the last two lines");

	(out, how) = runsed("N;P;D" :: nil, "a\nb\nc\n");
	t.assertseq(how, "ok", "N;P;D returns");
	t.assertseq(out, "a\nb\n", "N;P;D prints each line but the last (N at end of input quits, POSIX)");
}

# the ordinary cases still work
testOrdinary(t: ref T)
{
	(out, nil) := runsed("s/b/X/" :: nil, "abc\n");
	t.assertseq(out, "aXc\n", "s/b/X/");
	(out, nil) = runsed("-n" :: "/b/p" :: nil, "abc\nxyz\n");
	t.assertseq(out, "abc\n", "-n /b/p");
	(out, nil) = runsed("s/a//g" :: nil, "aXa\n");
	t.assertseq(out, "X\n", "s/a//g");
	(out, nil) = runsed("2d" :: nil, "1\n2\n3\n");
	t.assertseq(out, "1\n3\n", "2d");
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

	run("Unclosed");
	run("ShortScripts");
	run("DWithoutNewline");
	run("DRestart");
	run("Ordinary");

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
