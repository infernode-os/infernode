implement Import;

include "sys.m";
	sys: Sys;

include "draw.m";
include "dial.m";
include "keyring.m";
include "security.m";
include "factotum.m";
include "encoding.m";
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

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	factotum := load Factotum Factotum->PATH;
	if(factotum == nil)
		nomod(Factotum->PATH);
	factotum->init();
	dial := load Dial Dial->PATH;

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);

	arg->init(args);
	arg->setusage("import [-a|-b] [-c] [-e enc digest] host file [localfile]");
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
		if(n >= 4)
			sys->werrstr("bad remote tree: "+string buf[0:n]);
		fail("import", sys->sprint("import %s %s: %r", addr, file));
	}
	if(cryptalg != nil)
		fail("import", "Plan 9's p9sk1 gives a 56-bit key, too weak for ssl(3)'s aes_256_gcm and hmac_sha384; leave out -e for clear text, on a network you trust");
	if(sys->fprint(c.dfd, "impo nofilter clear\n") < 0)
			fail("import", sys->sprint("can't write to remote: %r"));
	afd := sys->fauth(c.dfd, "");
	if(afd != nil)
		factotum->proxy(afd, facfd, "proto=p9any role=client");
	if(sys->mount(c.dfd, afd, mountpt, flags, "") < 0)
		fail("mount failed", sys->sprint("import %s %s: mount failed: %r", addr, file));
}

S(a: array of byte): string
{
	s := "";
	for(i:=0; i<len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

pushssl(fd: ref Sys->FD, secretin, secretout: array of byte, alg: string): (ref Sys->FD, string)
{
	ssl := load SSL SSL->PATH;
	if(ssl == nil)
		nomod(SSL->PATH);

	(err, c) := ssl->connect(fd);
	if(err != nil)
		return (nil, "can't connect ssl: " + err);

	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return (nil, "can't write secret: " + err);
	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		return (nil, sys->sprint("can't push algorithm %s: %r", alg));

	return (c.dfd, nil);
}
