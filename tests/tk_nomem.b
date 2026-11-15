implement TkNomem;

#
# tk->toplevel with the emulator's main pool full
# (tests/host/tk_nomem_test.sh runs this in an emulator of its own,
# with a small main pool: it fills it, and the kernel says so).
#
# A toplevel that cannot be finished is freed by the builtin that began
# it, before it has a context.  Freeing it took the context's lock all
# the same, through nil: the fault came out as the caller's exception,
# from inside destroy(), which had stopped the collector for the call
# and so left it stopped for good.  Garbage only the collector frees
# then filled the heap.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;

TkNomem: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

FDLoop: adt {
	fd:	ref Sys->FD;
	next:	cyclic ref FDLoop;
};

Junk: adt {
	a, b:	big;
};

churn(stop: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	ring := array[4096] of ref Junk;
	for(i := 0;; i++){
		ring[i % len ring] = ref Junk(big 16r4141414141414141, big 16r4242424242424242);
		if(i % 256 == 0){
			alt {
			<-stop =>
				return;
			* =>
				sys->sleep(2);
			}
		}
	}
}

# an ORCLOSE file in a cycle is gone once the collector has swept it
swept(tenths: int): int
{
	p := "/env/tknomemsweep";
	stop := chan of int;
	pidc := chan of int;
	spawn churn(stop, pidc);
	<-pidc;
	fd := sys->create(p, Sys->ORDWR|Sys->ORCLOSE, 8r666);
	gone := 0;
	if(fd != nil){
		l := ref FDLoop(fd, nil);
		l.next = l;
		l = nil;
		fd = nil;
		for(k := 0; k < tenths && !gone; k++){
			if(sys->stat(p).t0 < 0)
				gone = 1;
			else
				sys->sleep(100);
		}
	}
	stop <-= 1;
	return gone;
}

# a Tk command, its error or its exception
cmd(top: ref Toplevel, s: string): string
{
	{
		return tk->cmd(top, s);
	} exception e {
	"*" =>
		return "!" + e;
	}
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	d := Display.allocate(nil);
	if(d == nil || tk == nil){
		sys->print("SKIP no display or no Tk: %r\n");
		sys->print("DONE\n");
		fd := sys->open("/dev/sysctl", Sys->OWRITE);
		sys->fprint(fd, "halt");
		return;
	}
	top := tk->toplevel(d, "");

	# use up the main pool with Tk variables, which are C strings: long
	# ones, then short
	fill := "";
	for(k := 0; k < 4000; k++)
		fill += "x";
	n := 0;
	for(;;){
		e := cmd(top, sys->sprint("variable v%d %s", n, fill));
		if(e != nil && e[0] == '!')
			break;
		n++;
	}
	small := 0;
	for(; small < 2000000; small++){
		e := cmd(top, sys->sprint("variable s%d x", small));
		if(e != nil && e[0] == '!')
			break;
	}
	sys->print("FILLED %d %d\n", n, small);

	made := 0;
	refused := 0;
	raised := 0;
	for(k = 0; k < 8; k++){
		{
			t := tk->toplevel(d, "");
			if(t == nil)
				refused++;
			else
				made++;
		} exception {
		"*" =>
			raised++;
		}
	}
	sys->print("TOPLEVELS made %d refused %d raised %d\n", made, refused, raised);

	# the variables go with their toplevel, and there is room again
	top = nil;
	if(swept(150))
		sys->print("SWEPT\n");
	else
		sys->print("NOTSWEPT\n");

	t := tk->toplevel(d, "");
	if(t != nil && cmd(t, "frame .f; pack .f; update") == nil)
		sys->print("ROOM ok\n");
	else
		sys->print("ROOM no toplevel: %r\n");

	sys->print("DONE\n");
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	sys->fprint(fd, "halt");
}
