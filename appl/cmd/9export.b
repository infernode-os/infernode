implement P9export;

include "sys.m";
	sys: Sys;

include "draw.m";
include "keyring.m";
include "security.m";
include "factotum.m";
include "encoding.m";
include "arg.m";

P9export: module
{
	init:	 fn(nil: ref Draw->Context, nil: list of string);
};

factotumfile := "/mnt/factotum/rpc";

fail(status, msg: string)
{
	sys->fprint(sys->fildes(2), "9export: %s\n", msg);
	raise "fail:"+status;
}

nomod(mod: string)
{
	fail("load", sys->sprint("can't load %s: %r", mod));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);

	arg->init(args);
	arg->setusage("9export [-aA9] [-k keyspec] [-e enc digest]");
	cryptalg := "";	# none: -e naming one is refused (p9sk1 below)
	keyspec := "";
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
		'k' =>
			keyspec = arg->earg();
		'9' =>
			;
		*   =>
			arg->usage();
		}
	args = arg->argv();
	arg = nil;

	sys->pctl(Sys->FORKFD|Sys->FORKNS, nil);

	fd := sys->fildes(0);

	secret: array of byte;
	if(noauth == 0){
		factotum := load Factotum Factotum->PATH;
		if(factotum == nil)
			nomod(Factotum->PATH);
		factotum->init();
		facfd := sys->open(factotumfile, Sys->ORDWR);
		if(facfd == nil)
			fail("factotum", sys->sprint("can't open %s: %r", factotumfile));
		ai := factotum->proxy(fd, facfd, "proto=p9any role=server "+keyspec);
		if(ai == nil)
			fail("auth", sys->sprint("can't authenticate 9export: %r"));
		secret = ai.secret;
	}

	# read tree; it's a Plan 9 bug that there's no reliable delimiter
	btree := array[2048] of byte;
	n := sys->read(fd, btree, len btree);
	if(n <= 0)
		fail("tree", sys->sprint("can't read tree: %r"));
	tree := string btree[0:n];
	if(sys->chdir(tree) < 0){
		sys->fprint(fd, "chdir(%d:\"%s\"): %r", n, tree);
		fail("tree", sys->sprint("bad tree: %s", tree));
	}
	if(sys->write(fd, array of byte "OK", 2) != 2)
		fail("tree", sys->sprint("can't OK tree: %r"));
	impo := array[2048] of byte;
	for(n = 0; n < len impo; n++)
		if(sys->read(fd, impo[n:], 1) != 1)
			fail("impo", sys->sprint("can't read impo: %r"));
		else if(impo[n] == byte 0 || impo[n] == byte '\n')
			break;
	if(n < 4 || string impo[0:4] != "impo")
		fail("impo", "wasn't impo: possibly old import/cpu");
	if(noauth == 0 && cryptalg != nil)
		fail("9export", "Plan 9's p9sk1 gives a 56-bit key, too weak for ssl(3)'s aes_256_gcm and hmac_sha384; leave out -e for clear text, on a network you trust");
	if(sys->export(fd, ".", xflag) < 0)
		fail("export", sys->sprint("can't export %s: %r", tree));
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
