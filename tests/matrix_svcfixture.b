implement MatrixSvcFixture;

#
# matrix_svcfixture - a Matrix service that misbehaves on request,
# for matrix_test's service lifecycle checks.  The test copies it
# into /dis/matrix under a test name and composes it; what it does
# is the first word of <mount>/mode, read at init:
#
#	ok	run until shutdown (the well-behaved case)
#	exit	return from run at once
#	raise	raise from run
#	block	ignore shutdown, with a child proc doing the same
#	exitchild	start a child proc, then return from run
#	initfail	refuse at init
#
# run writes its pid (and its child's, if it has one) to <outdir>/pids;
# shutdown writes <outdir>/shutdown.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "matrix.m";

MatrixSvcFixture: module
{
	init:	fn(mount: string, outdir: string): string;
	run:	fn();
	shutdown:	fn();
};

mode: string;
outdir_g: string;
stop: int;

init(mount: string, outdir: string): string
{
	sys = load Sys Sys->PATH;
	outdir_g = outdir;
	mode = "ok";
	fd := sys->open(mount + "/mode", Sys->OREAD);
	if(fd != nil) {
		buf := array[64] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0) {
			(nil, toks) := sys->tokenize(string buf[0:n], " \t\n");
			if(toks != nil)
				mode = hd toks;
		}
	}
	if(mode == "initfail")
		return "nope";
	return nil;
}

run()
{
	case mode {
	"exit" =>
		pids("");
		return;
	"raise" =>
		raise "boom";
	"block" =>
		pidc := chan of int;
		spawn child(pidc);
		pids(sys->sprint(" %d", <-pidc));
		for(;;)
			sys->sleep(100);
	"exitchild" =>
		pidc := chan of int;
		spawn child(pidc);
		pids(sys->sprint(" %d", <-pidc));
		return;
	* =>
		pids("");
		while(!stop)
			sys->sleep(50);
	}
}

pids(more: string)
{
	fd := sys->create(outdir_g + "/pids", Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "%d%s\n", sys->pctl(0, nil), more);
}

child(pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;)
		sys->sleep(100);
}

shutdown()
{
	stop = 1;
	fd := sys->create(outdir_g + "/shutdown", Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "%s\n", mode);
}
