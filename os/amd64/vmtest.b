implement Vmtest;

#
# The first Limbo program this kernel runs.  Its job is to exercise
# the parts of the interpreter a boot test can see: integer and real
# arithmetic, heap values with a type descriptor (string, array), the
# Sys module callable through os/port/inferno.c, and the console.
#
# A REAL is computed rather than only written, and printed with %g,
# which goes through libinterp's va_arg over a double: the whole FP
# path, from a Dis instruction to a formatted digit, is on the line.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Vmtest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

halt()
{
	fd := sys->open("#c/sysctl", Sys->OWRITE);
	if(fd != nil){
		buf := array of byte "halt\n";
		sys->write(fd, buf, len buf);
	}
}

fail(msg: string)
{
	sys->print("vmtest failed: %s\n", msg);
	halt();
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("vmtest: the Dis VM is running in the kernel\n");

	if(6*7 != 42)
		fail("integer multiply");
	sys->print("vmtest: 6*7=42\n");

	x := 1.5;
	y := 2.0;
	if(x*y != 3.0 || x+y != 3.5)
		fail("real arithmetic");
	sys->print("vmtest: 1.5*2.0=%g, 1.5+2.0=%g\n", x*y, x+y);

	s := "kernel";
	a := array[4] of { 1, 2, 3, 4 };
	a[3] = 40+2;
	if(len s != 6 || s[5] != 'l' || a[3] != 42)
		fail("strings and arrays");
	sys->print("vmtest: string \"%s\" array[3]=%d\n", s, a[3]);

	sys->print("vmtest passed\n");

	# The kernel-side floating point worker owns the halt: it measures
	# the scheduler for a second of ticks and says whether the sum it
	# kept in an XMM register survived being preempted by this VM.
	# Sleeping here leaves the interpreter idle, so the only FP user
	# running is the one being measured.
	sys->sleep(60000);
}
