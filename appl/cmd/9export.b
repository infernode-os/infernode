implement P9export;

include "sys.m";
	sys: Sys;

include "draw.m";
include "arg.m";

P9export: module
{
	init:	 fn(nil: ref Draw->Context, nil: list of string);
};

done: chan of int;	# tells the watchdog the caller's time is no longer counted

fail(status, msg: string)
{
	sys->fprint(sys->fildes(2), "9export: %s\n", msg);
	# the watchdog shares the connection's files: left to its timer it
	# kept a refused caller's connection open
	if(done != nil)
		alt{
		done <-= 1 =>
			;
		* =>
			;
		}
	raise "fail:"+status;
}

nomod(mod: string)
{
	fail("load", sys->sprint("can't load %s: %r", mod));
}

# The caller has so long to authenticate, name its tree and say how it
# will speak; there was no limit, and listen(1)'s own does not cover what
# its command does with the connection.
Deadline: con 30000;

watchdog(pid: int, done: chan of int)
{
	t := chan[1] of int;
	spawn timer(t);
	alt{
	<-done =>
		;
	<-t =>
		fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
		if(fd == nil)
			return;	# it ended some other way
		sys->fprint(sys->fildes(2), "9export: the caller did not finish in %d s\n", Deadline/1000);
		sys->fprint(fd, "kill");
	}
}

timer(t: chan of int)
{
	sys->pctl(Sys->NEWFD, nil);	# it only sleeps: it holds no connection open
	sys->sleep(Deadline);
	t <-= 1;
}

printable(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a && i < 120; i++){
		c := int a[i];
		if(c < ' ' || c >= 16r7f)
			c = '?';
		s[len s] = c;
	}
	return s;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);

	arg->init(args);
	arg->setusage("9export -A [-a9] [-e clear]");
	cryptalg := "";
	noauth := 0;
	xflag := Sys->EXPWAIT;
	while((o := arg->opt()) != 0)
		case o {
		'a' =>
			xflag = Sys->EXPASYNC;
		'A' =>
			noauth = 1;
		'e' =>
			cryptalg = arg->earg();
			if(cryptalg == "clear")
				cryptalg = nil;
		'9' =>
			;
		*   =>
			arg->usage();
		}
	args = arg->argv();
	arg = nil;
	# Both are said before the caller is spoken to.  Plan 9's own
	# authentication (p9any offering p9sk1, whose tickets are DES) is not
	# in this system, so the caller is nobody and there is no key to
	# encrypt with: -A says whoever runs this knows.  Without it factotum
	# used to be asked for p9any, which could only fail.
	if(cryptalg != nil)
		fail("9export", "-e: there is no key to encrypt with when the caller is not authenticated; leave it out for clear text, on a network you trust");
	if(!noauth)
		fail("p9sk1", "Plan 9 authentication (p9sk1) is not in this system; 9export -A exports to anyone who can reach it, in clear text, for a network you trust (for an InferNode caller use listen(1) with export(4))");

	pid := sys->pctl(Sys->FORKFD|Sys->FORKNS, nil);

	fd := sys->fildes(0);

	done = chan[1] of int;
	spawn watchdog(pid, done);
	# read tree; it's a Plan 9 bug that there's no reliable delimiter
	btree := array[2048] of byte;
	n := sys->read(fd, btree, len btree);
	if(n <= 0)
		fail("tree", sys->sprint("can't read tree: %r"));
	tree := string btree[0:n];
	if(sys->chdir(tree) < 0){
		# the caller is told no, not this system's reason; and its
		# bytes go to the log as text
		e := sys->sprint("%r");
		sys->fprint(fd, "cannot export that tree");
		fail("tree", sys->sprint("bad tree %s: %s", printable(btree[0:n]), e));
	}
	if(sys->write(fd, array of byte "OK", 2) != 2)
		fail("tree", sys->sprint("can't OK tree: %r"));
	impo := array[2048] of byte;
	for(n = 0; n < len impo; n++)
		if(sys->read(fd, impo[n:], 1) != 1)
			fail("impo", sys->sprint("can't read impo: %r"));
		else if(impo[n] == byte 0 || impo[n] == byte '\n')
			break;
	# "impo" then how the caller will speak: "nofilter" or "aan", and
	# "clear", "ssl" or "tls".  The words were not read: a caller that
	# said ssl, and then spoke it, was exported to in clear.  Only
	# what is done here is taken.
	(nw, words) := sys->tokenize(string impo[0:n], " \t\r");
	if(nw < 1 || hd words != "impo")
		fail("impo", "wasn't impo: possibly old import/cpu");
	if(nw != 3 || hd tl words != "nofilter" || hd tl tl words != "clear")
		fail("impo", "the caller asked for \"" + printable(impo[0:n]) + "\": only \"impo nofilter clear\" is done here");
	done <-= 1;
	if(sys->export(fd, ".", xflag) < 0)
		fail("export", sys->sprint("can't export %s: %r", tree));
}
