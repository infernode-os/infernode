implement CPU;

include "sys.m";
	sys: Sys;
	stderr: ref Sys->FD;
include "draw.m";
	Context: import Draw;
include "string.m";
	str: String;
include "arg.m";
include "keyring.m";
include "security.m";

DEFCMD:	con "/dis/sh";

CPU: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

badmodule(p: string)
{
	sys->fprint(stderr, "cpu: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

usage()
{
	sys->fprint(stderr, "Usage: cpu [-C cryptoalg] [-e exportroot] mach command args...\n");
	raise "fail:usage";
}

# The default level of security is NOSSL, unless
# the keyring directory doesn't exist, in which case
# it's disallowed.
init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	arg := load Arg Arg->PATH;
	if (arg == nil) badmodule(Arg->PATH);

	str = load String String->PATH;
	if (str == nil) badmodule(String->PATH);

	au := load Auth Auth->PATH;
	if (au == nil) badmodule(Auth->PATH);

	kr := load Keyring Keyring->PATH;
	if (kr == nil) badmodule(Keyring->PATH);

	arg->init(argv);
	alg := "";
	exportroot: string;
	while ((opt := arg->opt()) != 0) {
		if (opt == 'C') {
			alg = arg->arg();
		} else if(opt == 'e') {
			exportroot = arg->arg();
			if(exportroot == nil || !exists(exportroot))
				usage();
		} else
			usage();
	}
	argv = arg->argv();
	args := "auxi/cpuslave";
#	if(ctxt != nil && ctxt.screen != nil)
#		args += " -s" + string ctxt.screen.id;
#	else
		args += " --";

	mach: string;
	case len argv {
	0 =>
		usage();
	1 =>
		mach = hd argv;
		args += " " + DEFCMD;
	* =>
		mach = hd argv;
		args += " " + str->quoted(tl argv);
	}

	user := getuser();
	kd := "/usr/" + user + "/keyring/";
	cert := kd + netmkaddr(mach, "tcp", "");
	if (!exists(cert)) {
		cert = kd + "default";
		if (!exists(cert)) {
			sys->fprint(stderr, "cpu: cannot find certificate in %s; use getauthinfo\n", kd);
			raise "fail:no certificate";
		}
	}

	# To make visible remotely: the remote end binds our /dev over its
	# own, and a program there draws on /dev/draw. The draw device is
	# #i in this tree (devdraw.c), not upstream's #d; with #d this bind
	# did nothing and every caller had to bind '#i' by hand first.
	if(!exists("/dev/draw/new"))
		sys->bind("#i", "/dev", Sys->MBEFORE);

	(ok, c) := sys->dial(netmkaddr(mach, "net", "rstyx"), nil);
	if(ok < 0){
		sys->fprint(stderr, "Error: cpu: dial: %r\n");
		return;
	}

	ai := kr->readauthinfo(cert);

	# Encrypt and authenticate every record unless told otherwise. The
	# session carries keystrokes and every caller capability explicitly
	# placed in the export root;
	# upstream's default was "none", which authenticates the peers and
	# then sends everything in clear. AES-CBC alone would hide the bytes
	# but let anyone on the path alter them undetected, so the SHA-256
	# MAC comes with it. A bare-metal node's listener requires both.
	# -C none still asks for cleartext, for a server offering nothing else.
	if (alg == nil)
		alg = "aes_256_cbc sha256";
	err := au->init();
	if(err != nil) {
		sys->fprint(stderr, "cpu: cannot initialise auth module: %s\n", err);
		raise "fail:auth init failed";
	}

	fd := ref Sys->FD;
	#sys->fprint(stderr, "cpu: authenticating using alg '%s'\n", alg);		
	(fd, err) = au->client(alg, ai, c.dfd);
	if(fd == nil) {
		sys->fprint(stderr, "cpu: authentication failed: %s\n", err);
		raise "fail:authentication failure";
	}

	t := array of byte sys->sprint("%d\n%s\n", len (array of byte args)+1, args);
	if(sys->write(fd, t, len t) != len t){
		sys->fprint(stderr, "cpu: export args write error: %r\n");
		raise "fail:write error";
	}

	# The remote command needs the caller's devices, not its credentials,
	# home directory and host mounts.  Build a one-use export root containing
	# only /dev unless the caller explicitly supplies a wider tree with -e.
	# FORKNS keeps the temporary bind private to this cpu invocation.
	private := 0;
	if(exportroot == nil) {
		if(sys->pctl(Sys->FORKNS, nil) < 0) {
			sys->fprint(stderr, "cpu: cannot fork export namespace: %r\n");
			raise "fail:export namespace";
		}
		exportroot = mkexportroot();
		private = 1;
	}
	dev := exportroot + "/dev";
	if(exportroot == "/")
		dev = "/dev";
	if(!exists(dev)) {
		sys->fprint(stderr, "cpu: export root %s has no dev directory\n", exportroot);
		if(private)
			rmexportroot(exportroot);
		raise "fail:bad export root";
	}

	rc := sys->export(fd, exportroot, sys->EXPWAIT);
	if(private)
		rmexportroot(exportroot);
	if(rc < 0){
		sys->fprint(stderr, "cpu: export failed: %r\n");
		raise "fail:export error";
	}
}

mkexportroot(): string
{
	base := "/tmp/cpu-export-" + string sys->pctl(0, nil) + "-" + string sys->millisec();
	root := base;
	for(i := 0; i < 10; i++) {
		if(i > 0)
			root = base + "-" + string i;
		fd := sys->create(root, Sys->OREAD, Sys->DMDIR|8r700);
		if(fd == nil)
			continue;
		fd = nil;
		fd = sys->create(root + "/dev", Sys->OREAD, Sys->DMDIR|8r700);
		if(fd == nil) {
			sys->remove(root);
			continue;
		}
		fd = nil;
		if(sys->bind("/dev", root + "/dev", Sys->MREPL) < 0) {
			sys->remove(root + "/dev");
			sys->remove(root);
			continue;
		}
		return root;
	}
	sys->fprint(stderr, "cpu: cannot make private export root: %r\n");
	raise "fail:export root";
}

rmexportroot(root: string)
{
	sys->unmount(nil, root + "/dev");
	sys->remove(root + "/dev");
	sys->remove(root);
}

exists(file: string): int
{
	(ok, nil) := sys->stat(file);
	return ok != -1;
}

getuser(): string
{
	fd := sys->open("/dev/user", sys->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "cpu: cannot open /dev/user: %r\n");
		raise "fail:no user id";
	}

	buf := array[50] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0){
		sys->fprint(stderr, "cpu: cannot read /dev/user: %r\n");
		raise "fail:no user id";
	}

	return string buf[0:n];	
}

netmkaddr(addr, net, svc: string): string
{
	if(net == nil)
		net = "net";
	(n, nil) := sys->tokenize(addr, "!");
	if(n <= 1){
		if(svc== nil)
			return sys->sprint("%s!%s", net, addr);
		return sys->sprint("%s!%s!%s", net, addr, svc);
	}
	if(svc == nil || n > 2)
		return addr;
	return sys->sprint("%s!%s", addr, svc);
}
