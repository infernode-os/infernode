implement GateProbe;

# gateprobe — directly load /dis/limbo.dis via `load Command` and compile
# good and bad inputs, mirroring exactly what limbo.b's gate() does.
# This lets us tell whether the gate's code path is sound or whether
# /dis/limbo.dis itself is broken on this branch.

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

GateProbe: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

Command: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;

	probe(ctxt, "/gate-good.b", "GOOD");
	probe(ctxt, "/gate-bad.b", "BAD");
}

probe(ctxt: ref Draw->Context, src: string, label: string)
{
	sys->print("=== %s: %s ===\n", label, src);

	# Mirror limbo.b's gate(): redirect fd 2 to a file, run limbo, restore.
	errpath := "/tmp/gateprobe-" + label + ".err";
	saved := sys->dup(2, -1);
	if(saved < 0) {
		sys->print("dup failed\n");
		return;
	}
	errfd := sys->create(errpath, Sys->OWRITE, 8r644);
	if(errfd == nil) {
		sys->print("create errfile failed\n");
		sys->dup(saved, 2);
		return;
	}
	sys->dup(errfd.fd, 2);
	errfd = nil;

	ok := 1;
	threw := "";
	limbo := load Command "/dis/limbo.dis";
	if(limbo == nil) {
		ok = 0;
		threw = "load Command nil";
	} else {
		{
			limbo->init(ctxt, "limbo" :: "-I" :: "/module" :: src :: nil);
		} exception e {
		"*" =>
			ok = 0;
			threw = "exception: " + e;
		}
	}
	limbo = nil;

	# Compute expected .dis path (replace .b with .dis).
	dispath := "";
	if(len src > 2 && src[len src - 2:] == ".b")
		dispath = src[:len src - 2] + ".dis";
	(stok, nil) := sys->stat(dispath);
	if(stok < 0) {
		if(ok) threw = "no .dis produced";
		ok = 0;
	}

	sys->dup(saved, 2);

	# Read captured stderr.
	fd := sys->open(errpath, Sys->OREAD);
	errtxt := "";
	if(fd != nil) {
		buf := array[8192] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			errtxt = string buf[0:n];
	}

	sys->print("ok=%d threw=%q\n", ok, threw);
	sys->print("dispath=%s present=%d\n", dispath, stok >= 0);
	sys->print("stderr-len=%d\n", len errtxt);
	if(len errtxt > 0) {
		# Truncate noisy output for readability.
		shown := errtxt;
		if(len shown > 400)
			shown = shown[:400] + "...";
		sys->print("stderr:\n%s\n", shown);
	}

	# Cleanup
	sys->remove(errpath);
	if(stok >= 0)
		sys->remove(dispath);
}
