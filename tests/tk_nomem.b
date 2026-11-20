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
# heap, sweep: with the Dis heap full instead, a Tk command that sends
# a string to the program is refused the string, by an exception, inside
# the toplevel's lock.  The lock was left held: the Prog's next call on
# the toplevel waited for itself (heap), and so did whoever freed the
# toplevel (sweep).
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

big4k: list of array of byte;
small: list of array of byte;

# fill the Dis heap: large blocks, then the smallest
fillheap()
{
	{
		for(;;)
			big4k = array[4096] of byte :: big4k;
	} exception {
	"out of memory*" =>
		;
	}
	{
		for(;;)
			small = array[8] of byte :: small;
	} exception {
	"out of memory*" =>
		;
	}
}

hung(c: chan of int)
{
	for(k := 0; k < 300; k++){
		alt {
		<-c =>
			return;
		* =>
			sys->sleep(100);
		}
	}
	sys->print("HUNG\n");
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	sys->fprint(fd, "halt");
}

# a toplevel whose builtin was ended by an exception: a string for the
# program's channel is refused with the heap full, inside the toplevel's
# lock
stuck(d: ref Display): ref Toplevel
{
	top := tk->toplevel(d, "");
	c := chan[4096] of string;
	tk->namechan(top, c, "c");
	fillheap();
	raised := 0;
	# what the collector frees meanwhile is used up by the sends that work
	for(k := 0; k < 4000 && !raised; k++){
		{
			tk->cmd(top, "send c x");
		} exception {
		"out of memory*" =>
			raised = 1;
		}
	}
	big4k = nil;
	small = nil;
	if(!raised)
		return nil;
	return top;
}

heap(d: ref Display, what: string)
{
	c := chan[1] of int;
	spawn hung(c);
	top := stuck(d);
	if(top == nil){
		sys->print("NORAISE\n");
		c <-= 1;
		return;
	}
	sys->print("RAISED\n");
	if(what == "heap"){
		# the Prog that was refused goes on using the toplevel
		if(cmd(top, "frame .f; pack .f; update") == nil && cmd(top, ".f cget -width") != nil)
			sys->print("AGAIN ok\n");
		else
			sys->print("AGAIN refused\n");
	}else{
		# or drops it as it was when refused: it is freed, and the
		# collector runs on
		top = nil;
		if(swept(150))
			sys->print("SWEPT\n");
		else
			sys->print("NOTSWEPT\n");
	}
	c <-= 1;
}

init(nil: ref Draw->Context, args: list of string)
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
	if(len args > 1){
		heap(d, hd tl args);
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
	ns := 0;
	for(; ns < 2000000; ns++){
		e := cmd(top, sys->sprint("variable s%d x", ns));
		if(e != nil && e[0] == '!')
			break;
	}
	sys->print("FILLED %d %d\n", n, ns);

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
