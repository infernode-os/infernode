implement PresLaunchTest;

#
# pres_launch_test.b - exec does not claim to launch GUI apps
#
# GUI apps reach Lucifer's presentation zone through the launch tool,
# which writes /mnt/ui/activity/<id>/presentation/ctl.  The exec tool used
# to drop the app's path in /n/pres-launch or /tmp/veltro/pres-launch for
# a lucifer goroutine to poll, but that reader went with the unified tab
# model (48174e2fb), and exec went on answering "launched ... in
# presentation zone" for a launch that never happened.
#
# This checks, inside the namespace tools9p gives exec (nsconstruct's
# restrictns, forked so the parent is untouched), that each way of naming
# a /dis/wm/ app is refused with a pointer to launch, and that nothing is
# left in /tmp/veltro/pres-launch for a reader that does not exist.
#
# Run: ./emu/Linux/o.emu -r. /tests/pres_launch_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "nsconstruct.m";
	nsconstruct: NsConstruct;
	Capabilities: import nsconstruct;

include "tool.m";

PresLaunchTest: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

EXEC_PATH: con "/dis/veltro/tools/exec.dis";
PRES_LAUNCH: con "/tmp/veltro/pres-launch";

pass := 0;
fail := 0;

check(name, got, want: string)
{
	if(got == want) {
		sys->fprint(sys->fildes(1), "PASS: %s\n", name);
		pass++;
	} else {
		sys->fprint(sys->fildes(1), "FAIL: %s\n  got:  %q\n  want: %q\n", name, got, want);
		fail++;
	}
}

checkint(name: string, got, want: int)
{
	if(got == want) {
		sys->fprint(sys->fildes(1), "PASS: %s\n", name);
		pass++;
	} else {
		sys->fprint(sys->fildes(1), "FAIL: %s (got %d, want %d)\n", name, got, want);
		fail++;
	}
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	nsconstruct = load NsConstruct NsConstruct->PATH;
	if(nsconstruct == nil) {
		sys->fprint(sys->fildes(2), "FATAL: cannot load nsconstruct: %r\n");
		raise "fail:load";
	}
	(cok, nil) := sys->stat("/dis/wm/clock.dis");
	if(cok < 0)
		raise "skip:no /dis/wm/clock.dis (build appl/wm)";

	sys->remove(PRES_LAUNCH);

	result := chan of string;
	for(forms := "/dis/wm/clock.dis" :: "/dis/wm/clock" :: "wm/clock" :: nil; forms != nil; forms = tl forms) {
		form := hd forms;
		spawn restrictedexec(form, result);
		got := <-result;
		check("exec " + form + " refused, pointing at launch", got,
			"error: use 'launch clock' — exec cannot open GUI apps; launch puts them in the presentation zone");
	}

	(pok, nil) := sys->stat(PRES_LAUNCH);
	checkint("nothing left in " + PRES_LAUNCH, pok < 0, 1);

	sys->fprint(sys->fildes(1), "\n%d passed, %d failed\n", pass, fail);
	if(fail > 0)
		raise "fail:tests failed";
}

# Run the exec tool the way tools9p does: loaded and initialised first,
# then the namespace restricted to its capabilities, then called.
restrictedexec(cmd: string, result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	tool := load Tool EXEC_PATH;
	if(tool == nil) {
		result <-= sys->sprint("cannot load %s: %r", EXEC_PATH);
		return;
	}
	ierr := tool->init();
	if(ierr != nil) {
		result <-= "exec init: " + ierr;
		return;
	}

	caps := ref Capabilities(
		"exec" :: "launch" :: nil,
		"/dis/wm" :: nil,
		nil,
		nil,
		nil,
		nil,
		0,
		0,
		-1,
		nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= "restrictns failed: " + err;
		return;
	}

	result <-= tool->exec(cmd);
}
