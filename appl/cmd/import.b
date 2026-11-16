implement Import;

include "sys.m";
	sys: Sys;

include "draw.m";
include "dial.m";
include "keyring.m";
include "factotum.m";
include "arg.m";

Import: module
{
	init:	 fn(nil: ref Draw->Context, nil: list of string);
};

factotumfile := "/mnt/factotum/rpc";

fail(status, msg: string)
{
	sys->fprint(sys->fildes(2), "import: %s\n", msg);
	raise "fail:"+status;
}

nomod(mod: string)
{
	fail("load", sys->sprint("can't load %s: %r", mod));
}

# Plan 9's p9sk1 enciphers its tickets with DES, which was the VM's
# $Crypt module; no kernel is built with it now, so the protocol cannot
# run here and factotum's attempt ends in an exception inside it.  That
# is said before anything is dialled or answered.
P9des: module
{
	PATH:	con "$Crypt";
};

nop9sk1(): int
{
	return (load P9des P9des->PATH) == nil;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	factotum := load Factotum Factotum->PATH;
	if(factotum == nil)
		nomod(Factotum->PATH);
	factotum->init();
	dial := load Dial Dial->PATH;
	if(dial == nil)
		nomod(Dial->PATH);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);

	arg->init(args);
	arg->setusage("import [-a|-b] [-c] [-k keyspec] [-e clear] host file [localfile]");
	flags := 0;
	cryptalg := "";	# none: -e naming one is refused (p9sk1 below)
	keyspec := "";
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
		'k' =>
			keyspec = arg->earg();
		'9' =>
			;
		*   =>
			arg->usage();
		}
	args = arg->argv();
	if(len args != 2 && len args != 3)
		arg->usage();
	arg = nil;
	# said before anything is dialled: it used to be said once the
	# far end had been authenticated to and told the tree
	if(cryptalg != nil)
		fail("import", "Plan 9's p9sk1 gives a 56-bit key, too weak for ssl(3)'s aes_256_gcm and hmac_sha384; leave out -e for clear text, on a network you trust");
	if(nop9sk1())
		fail("p9sk1", "Plan 9 authentication (p9sk1) cannot run in this system, which has no DES, and import has no way without it; for an InferNode machine use mount(1)");
	addr := hd args;
	file := hd tl args;
	mountpt := file;
	if(len args > 2)
		mountpt = hd tl tl args;

	sys->pctl(Sys->FORKFD, nil);

	facfd := sys->open(factotumfile, Sys->ORDWR);
	if(facfd == nil)
		fail("factotum", sys->sprint("can't open %s: %r", factotumfile));

	dest := dial->netmkaddr(addr, "net", "exportfs");
	c := dial->dial(dest, nil);
	if(c == nil)
		fail("dial failed",  sys->sprint("can't dial %s: %r", dest));
	ai := factotum->proxy(c.dfd, facfd, "proto=p9any role=client "+keyspec);
	if(ai == nil)
		fail("auth", sys->sprint("can't authenticate import: %r"));
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
	# the attach is authenticated with the key the connection was (it
	# was not given -k's), and not mounted if that fails (it was)
	afd := sys->fauth(c.dfd, "");
	if(afd != nil && factotum->proxy(afd, facfd, "proto=p9any role=client "+keyspec) == nil)
		fail("auth", sys->sprint("can't authenticate the attach: %r"));
	if(sys->mount(c.dfd, afd, mountpt, flags, "") < 0)
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
