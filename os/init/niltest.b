implement Niltest;

#
# A nil dereference in JIT-compiled code is the program's exception, not
# the machine's panic.
#
# The JIT emits no nil checks: a load through Dis's nil (H, which is -1)
# faults in hardware, and the system turns the fault into "dereference
# of nil" in the program that did it. The hosted emulator always did
# (its SIGSEGV handler); the bare-metal kernel's trap handler did not,
# and every such load panicked the machine (found by a remote session
# running wm/wm with no display, 2026-09-30).
#
# This loads the first field of a nil ref adt -- offset 0, so the
# address is exactly -1 -- inside an exception block, and says what
# happened. "CAUGHT dereference of nil" then "STILL RUNNING" is a pass.
# On an unfixed kernel nothing after the load prints: the machine is gone.
#
include "sys.m";
	sys: Sys;
include "draw.m";

Niltest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

R: adt {
	a: int;
	b: int;
};

nilr(): ref R
{
	return nil;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	r := nilr();
	{
		x := r.a;
		sys->print("niltest: FAIL: no exception (read %d through nil)\n", x);
	} exception e {
	"*" =>
		sys->print("niltest: CAUGHT %s\n", e);
	}
	# the second field: nil is -1, so this is address 7, which faults
	# only where page zero is not mapped (#735)
	{
		x := r.b;
		sys->print("niltest: OFFSET FAIL: no exception (read %d at address 7)\n", x);
	} exception e {
	"*" =>
		sys->print("niltest: OFFSET CAUGHT %s\n", e);
	}
	sys->print("niltest: STILL RUNNING\n");
}
