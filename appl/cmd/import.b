implement Import;

include "sys.m";
	sys: Sys;

include "draw.m";
include "dial.m";
include "arg.m";

Import: module
{
	init:	 fn(nil: ref Draw->Context, nil: list of string);
};

fail(status, msg: string)
{
	sys->fprint(sys->fildes(2), "import: %s\n", msg);
	raise "fail:"+status;
}

nomod(mod: string)
{
	fail("load", sys->sprint("can't load %s: %r", mod));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	dial := load Dial Dial->PATH;
	if(dial == nil)
		nomod(Dial->PATH);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);

	arg->init(args);
	arg->setusage("import -A [-a|-b] [-c] [-e clear] host file [localfile]");
	flags := 0;
	cryptalg := "";
	noauth := 0;
	while((o := arg->opt()) != 0)
		case o {
		'a' =>
			flags |= Sys->MAFTER;
		'b' =>
			flags |= Sys->MBEFORE;
		'c' =>
			flags |= Sys->MCREATE;
		'e' =>
			cryptalg = arg->earg();
			if(cryptalg == "clear")
				cryptalg = nil;
		'A' =>
			noauth = 1;
		'9' =>
			;
		*   =>
			arg->usage();
		}
	args = arg->argv();
	if(len args != 2 && len args != 3)
		arg->usage();
	arg = nil;
	# Both are said before anything is dialled.  Plan 9's own
	# authentication (p9any offering p9sk1, whose tickets are DES) is not
	# in this system, so there is no key to encrypt with and nobody is
	# authenticated: -A, Plan 9's own flag for that, says the caller
	# knows.  Without it import used to ask factotum for p9any, on the
	# connection and again on the attach, which could only fail.
	if(cryptalg != nil)
		fail("import", "-e: there is no key to encrypt with when the far end is not authenticated; leave it out for clear text, on a network you trust");
	if(!noauth)
		fail("p9sk1", "Plan 9 authentication (p9sk1) is not in this system; import -A imports with no authentication and in clear text, from a system on a network you trust that exports that way (9export -A; Plan 9's exportfs without -a); for an InferNode machine use mount(1)");
	addr := hd args;
	file := hd tl args;
	mountpt := file;
	if(len args > 2)
		mountpt = hd tl tl args;

	sys->pctl(Sys->FORKFD, nil);

	dest := dial->netmkaddr(addr, "net", "exportfs");
	c := dial->dial(dest, nil);
	if(c == nil)
		fail("dial failed",  sys->sprint("can't dial %s: %r", dest));
	if(sys->fprint(c.dfd, "%s", file) < 0)
		fail("import", sys->sprint("can't write to remote: %r"));
	buf := array[256] of byte;
	if((n := sys->read(c.dfd, buf, len buf)) != 2 || buf[0] != byte 'O' || buf[1] != byte 'K'){
		# what the far end said, as text and no more of it than a
		# line: it went to the terminal as it came, or (under four
		# bytes) the message was whatever error had been left behind
		why: string;
		if(n < 0)
			why = sys->sprint("%r");
		else if(n == 0)
			why = "the far end hung up";
		else
			why = "the far end refused the tree: " + printable(buf[0:n]);
		fail("import", sys->sprint("import %s %s: %s", addr, file, why));
	}
	if(sys->fprint(c.dfd, "impo nofilter clear\n") < 0)
			fail("import", sys->sprint("can't write to remote: %r"));
	# no Tauth: the export at the far end attaches whoever it was
	# started for, as Plan 9's own import assumes
	if(sys->mount(c.dfd, nil, mountpt, flags, "") < 0)
		fail("mount failed", sys->sprint("import %s %s: mount failed: %r", addr, file));
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
