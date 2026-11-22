implement Mount;

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
include "styxpersist.m";
include "arg.m";
include "sh.m";

Mount: module
{
	init:	 fn(nil: ref Draw->Context, nil: list of string);
};

verbose := 0;
doauth := 1;
persist := 0;
showstyx := 0;

alg := "aes_256_gcm";
keyfile: string;
spec: string;
addr: string;
peer: string;	# -u: who the far end must be; with -P, who it was at first

fail(status, msg: string)
{
	sys->fprint(sys->fildes(2), "mount: %s\n", msg);
	raise "fail:"+status;
}

nomod(mod: string)
{
	fail("load", sys->sprint("can't load %s: %r", mod));
}

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);

	arg->init(args);
	arg->setusage("mount [-a|-b] [-cRoAP] [-C cryptoalg] [-k keyfile] [-u user] net!addr|file|{command} mountpoint [spec]");
	flags := 0;
	while((o := arg->opt()) != 0){
		case o {
		'a' =>
			flags |= Sys->MAFTER;
		'b' =>
			flags |= Sys->MBEFORE;
		'c' =>
			flags |= Sys->MCREATE;
		'R' =>
			flags |= Sys->MREADONLY;
		'C' =>
			alg = arg->earg();
		'k' or
		'f' =>
			keyfile = arg->earg();
		'u' =>
			peer = arg->earg();
			if(peer == nil)
				arg->usage();
		'A' =>
			doauth = 0;
		'9' =>
			# it authenticated to a Plan 9 file server through
			# factotum's p9any, which could only fail once p9sk1
			# (DES) had gone; a server that asks for no
			# authentication was always -A's
			fail("p9sk1", "-9: Plan 9 authentication (p9sk1) is not in this system; a 9P server that asks for none is mounted with -A (its service is 9fs)");
		'v' =>
			verbose = 1;
		'P' =>
			persist = 1;
		'S' =>
			showstyx = 1;
		*   =>
			arg->usage();
		}
	}
	args = arg->argv();
	if(len args != 2){
		if(len args != 3)
			arg->usage();
		spec = hd tl tl args;
	}
	arg = nil;
	addr = hd args;
	mountpoint := hd tl args;
	# -u names who the far end must authenticate as: with nothing
	# authenticated there is nobody to name
	if(peer != nil && !doauth)
		fail("usage", "-u needs an authenticated connection (not -A, a file or a command)");

	fd := connect(ctxt, addr);
	err: string;
	if(!persist){
		(fd, err) = authcvt(fd);
		if(fd == nil)
			fail("error", err);
	}
	fd = styxlog(fd);
	ok := sys->mount(fd, nil, mountpoint, flags, spec);
	if(ok < 0)
		fail("mount failed", sys->sprint("mount failed: %r"));
}

connect(ctxt: ref Draw->Context, dest: string): ref Sys->FD
{
	if(dest != nil && dest[0] == '{' && dest[len dest - 1] == '}'){
		if(persist)
			fail("usage", "cannot persistently mount a command");
		if(peer != nil)
			fail("usage", "-u needs an authenticated connection, not a command");
		doauth = 0;
		return popen(ctxt, dest :: nil);
	}
	(n, nil) := sys->tokenize(dest, "!");
	if(n == 1){
		fd := sys->open(dest, Sys->ORDWR);
		if(fd != nil){
			if(persist)
				fail("usage", "cannot persistently mount a file");
			if(peer != nil)
				fail("usage", "-u needs an authenticated connection, not a file");
			return fd;
		}
		if(dest[0] == '/')
			fail("open failed", sys->sprint("can't open %s: %r", dest));
	}
	dest = netmkaddr(dest, "net", "styx");
	if(persist){
		styxpersist := load Styxpersist Styxpersist->PATH;
		if(styxpersist == nil)
			fail("bad module", sys->sprint("cannot load %s: %r", Styxpersist->PATH));
		sys->pipe(p := array[2] of ref Sys->FD);
		(c, err) := styxpersist->init(p[0]);
		if(c == nil)
			fail("error", "styxpersist: "+err);
		spawn dialler(c, dest);
		return p[1];
	}
	(ok, c) := sys->dial(dest, nil);
	if(ok < 0)
			fail("dial failed",  sys->sprint("can't dial %s: %r", dest));
	return c.dfd;
}

dialler(dialc: chan of chan of ref Sys->FD, dest: string)
{
	while((reply := <-dialc) != nil){
		if(verbose)
			sys->print("dialling %s\n", addr);
		(ok, c) := sys->dial(dest, nil);
		if(ok == -1){
			reply <-= nil;
			continue;
		}
		# authcvt holds the far end to who it was the first time: a
		# reconnection was given to whoever answered with a certificate
		# of the same signer, mid-session and without a word
		(fd, err) := authcvt(c.dfd);
		if(fd == nil)
			sys->fprint(sys->fildes(2), "mount: %s: %s\n", dest, err);
		reply <-= fd;
	}
}

authcvt(fd: ref Sys->FD): (ref Sys->FD, string)
{
	err: string;
	if(doauth){
		(fd, err) = authenticate(keyfile, alg, fd, addr);
		if(fd == nil)
			return (nil, err);
		if(verbose)
			sys->print("remote username is %s\n", err);
		# the far end is whoever holds a certificate of our signer;
		# -u says which of them it must be, and a persistent mount's
		# far end stays who it was
		if(peer != nil && err != peer)
			return (nil, sys->sprint("the far end is %s, not %s", err, peer));
		if(persist && peer == nil)
			peer = err;
	}
	return (fd, nil);
}

popen(ctxt: ref Draw->Context, argv: list of string): ref Sys->FD
{
	sh := load Sh Sh->PATH;
	if(sh == nil)
		nomod(Sh->PATH);
	sync := chan of int;
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	spawn runcmd(sh, ctxt, argv, fds[0], sync);
	<-sync;
	return fds[1];
}

runcmd(sh: Sh, ctxt: ref Draw->Context, argv: list of string, stdin: ref Sys->FD, sync: chan of int)
{
	# its own end of the pipe and the standard files, and nothing else:
	# a copy of the whole table (FORKFD) had the mount's end of the pipe
	# in it too, so the command never saw the end of its input when it
	# was unmounted, and stayed for good
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: stdin.fd :: nil);
	sys->dup(stdin.fd, 0);
	stdin = nil;
	sync <-= 0;
	sh->run(ctxt, argv);
}

authenticate(keyfile, alg: string, dfd: ref Sys->FD, addr: string): (ref Sys->FD, string)
{
	cert : string;

	kr := load Keyring Keyring->PATH;
	if(kr == nil)
		return (nil, sys->sprint("cannot load %s: %r", Keyring->PATH));

	# with no name the key directory was /usr//keyring/, whatever is there
	u := user();
	if(u == nil)
		return (nil, "cannot read /dev/user to find the key directory");
	kd := "/usr/" + u + "/keyring/";
	if(keyfile == nil) {
		cert = kd + netmkaddr(addr, "tcp", "");
		(ok, nil) := sys->stat(cert);
		if (ok < 0)
			cert = kd + "default";
	}
	else if(len keyfile > 0 && keyfile[0] != '/')
		cert = kd + keyfile;
	else
		cert = keyfile;
	ai := kr->readauthinfo(cert);
	if(ai == nil)
		return (nil, sys->sprint("cannot read %s: %r", cert));

	# an error, not an exception: this runs in a persistent mount's
	# dialler too, which an exception ended, leaving the mount waiting
	auth := load Auth Auth->PATH;
	if(auth == nil)
		return (nil, sys->sprint("cannot load %s: %r", Auth->PATH));

	err := auth->init();
	if(err != nil)
		return (nil, "cannot init auth: "+err);

	fd: ref Sys->FD;
	(fd, err) = auth->client(alg, ai, dfd);
	if(fd == nil)
		return (nil, "authentication failed: "+err);
	return (fd, err);
}

user(): string
{
	fd := sys->open("/dev/user", sys->OREAD);
	if(fd == nil)
		return "";

	buf := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return "";

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

kill(pid: int)
{
	if ((fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE)) != nil)
		sys->fprint(fd, "kill");
}

include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;

styxlog(fd: ref Sys->FD): ref Sys->FD
{
	if(showstyx){
		sys->pipe(p := array[2] of ref Sys->FD);
		styx = load Styx Styx->PATH;
		styx->init();
		spawn tmsgreader(p[0], fd, p1 := chan[1] of int, p2 := chan[1] of int);
		spawn rmsgreader(fd, p[0], p2, p1);
		fd = p[1];
	}
	return fd;
}

tmsgreader(cfd, sfd: ref Sys->FD, p1, p2: chan of int)
{
	p1 <-= sys->pctl(0, nil);
	m: ref Tmsg;
	do{
		m = Tmsg.read(cfd, 9000);
		if(m == nil)
			break;	# the end: it was printed, through nil
		sys->print("%s\n", m.text());
		d := m.pack();
		if(sys->write(sfd, d, len d) != len d)
			sys->print("tmsg write error: %r\n");
	} while(tagof(m) != tagof(Tmsg.Readerror));
	kill(<-p2);
}

rmsgreader(sfd, cfd: ref Sys->FD, p1, p2: chan of int)
{
	p1 <-= sys->pctl(0, nil);
	m: ref Rmsg;
	do{
		m = Rmsg.read(sfd, 9000);
		if(m == nil)
			break;
		sys->print("%s\n", m.text());
		d := m.pack();
		if(sys->write(cfd, d, len d) != len d)
			sys->print("rmsg write error: %r\n");
	} while(tagof(m) != tagof(Rmsg.Readerror));
	kill(<-p2);
}
