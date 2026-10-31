implement Styxlisten;
include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	keyring: Keyring;
include "security.m";
	auth: Auth;
include "arg.m";
include "sh.m";

Styxlisten: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

badmodule(p: string)
{
	sys->fprint(stderr(), "styxlisten: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

verbose := 0;
passhostnames := 0;
authtimeout := 30000;
authlimit := 32;
authslots: chan of int;
authrate := 8;
ratewindow := 0;
ratecount := 0;

# Pre-auth slots per source address, as in listen(1) (#729): one host
# may hold at most perlimit of the authlimit slots. -P 0 turns it off.
perlimit := 4;
Srccount: adt {
	host:	string;
	n:	int;
};
srccounts: list of ref Srccount;
srclock: chan of int;

srcacquire(host: string): int
{
	srclock <-= 1;
	for(l := srccounts; l != nil; l = tl l)
		if((hd l).host == host){
			if(perlimit > 0 && (hd l).n >= perlimit){
				<-srclock;
				return 0;
			}
			(hd l).n++;
			<-srclock;
			return 1;
		}
	srccounts = ref Srccount(host, 1) :: srccounts;
	<-srclock;
	return 1;
}

srcrelease(host: string)
{
	srclock <-= 1;
	nl: list of ref Srccount;
	for(l := srccounts; l != nil; l = tl l){
		c := hd l;
		if(c.host == host)
			c.n--;
		if(c.n > 0)
			nl = c :: nl;
	}
	srccounts = nl;
	<-srclock;
}

srchost(dir: string): string
{
	(nil, f) := sys->tokenize(readfile(dir + "/remote"), "!\n");
	if(f == nil)
		return "?";
	return hd f;
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	auth = load Auth Auth->PATH;
	if (auth == nil)
		badmodule(Auth->PATH);
	if ((e := auth->init()) != nil)
		error("auth init failed: " + e);
	keyring = load Keyring Keyring->PATH;
	if (keyring == nil)
		badmodule(Keyring->PATH);

	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmodule(Arg->PATH);

	arg->init(argv);
	arg->setusage("styxlisten [-a alg]... [-Atsv] [-L maxauth] [-P persource] [-R authrate] [-T ms] [-k keyfile] address cmd [arg...]");

	algs: list of string;
	doauth := 1;
	synchronous := 0;
	trusted := 0;
	keyfile: string;

	while ((opt := arg->opt()) != 0) {
		case opt {
		'v' =>
			verbose = 1;
		'a' =>
			algs = arg->earg() :: algs;
		'f' or
		'k' =>
			keyfile = arg->earg();
			if (! (keyfile[0] == '/' || (len keyfile > 2 &&  keyfile[0:2] == "./")))
				keyfile = "/usr/" + user() + "/keyring/" + keyfile;
		'h' =>
			passhostnames = 1;
		't' =>
			trusted = 1;
		'T' =>
			authtimeout = int arg->earg();
			if(authtimeout < 1000)
				authtimeout = 1000;
		'L' =>
			authlimit = int arg->earg();
			if(authlimit < 1)
				arg->usage();
		'R' =>
			authrate = int arg->earg();
			if(authrate < 1)
				arg->usage();
		'P' =>
			perlimit = int arg->earg();
			if(perlimit < 0)
				arg->usage();
		's' =>
			synchronous = 1;
		'A' =>
			doauth = 0;
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if (len argv < 2)
		arg->usage();
	arg = nil;
	if (doauth && algs == nil)
		algs = "aes_256_cbc" :: "sha256" :: nil;
	if (doauth && algs == nil)
		error("authentication requested, but no SSL algorithms are available");
	addr := netmkaddr(hd argv, "tcp", "styx");
	cmd := tl argv;

	authinfo: ref Keyring->Authinfo;
	if (doauth) {
		authslots = chan[authlimit] of int;
		srclock = chan[1] of int;
		if (keyfile == nil)
			keyfile = "/usr/" + user() + "/keyring/default";
		# Keep key masking private to this listener.  Children need the
		# in-memory Authinfo, never the credential file itself.
		if(!trusted && sys->pctl(Sys->FORKNS, nil) < 0)
			error("cannot fork key namespace");
		authinfo = keyring->readauthinfo(keyfile);
		if (authinfo == nil)
			error(sys->sprint("cannot read %s: %r", keyfile));
		if(!trusted && sys->bind("/dev/null", keyfile, Sys->MREPL) < 0)
			error(sys->sprint("cannot hide %s: %r", keyfile));
	}

	(ok, c) := sys->announce(addr);
	if (ok == -1)
		error(sys->sprint("cannot announce on %s: %r", addr));
	if(!trusted){
		sys->unmount(nil, "/mnt/keys");	# should do for now
		# become none?
	}

	lsync := chan[1] of int;
	if(synchronous)
		listener(c, popen(ctxt, cmd, lsync), authinfo, algs, lsync);
	else
		spawn listener(c, popen(ctxt, cmd, lsync), authinfo, algs, lsync);
}

listener(c: Sys->Connection, mfd: ref Sys->FD, authinfo: ref Keyring->Authinfo, algs: list of string, lsync: chan of int)
{
	lsync <-= sys->pctl(0, nil);
	for (;;) {
		(n, nc) := sys->listen(c);
		if (n == -1)
			error(sys->sprint("listen failed: %r"));
		if (verbose)
			sys->fprint(stderr(), "styxlisten: got connection from %s",
					readfile(nc.dir + "/remote"));
		dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if (dfd != nil) {
			if(nc.cfd != nil)
				sys->fprint(nc.cfd, "keepalive");
			hostname: string;
			if(passhostnames){
				hostname = readfile(nc.dir + "/remote");
				if(hostname != nil)
					hostname = hostname[0:len hostname - 1];
			}
			if (algs == nil) {
				sync := chan of int;
				spawn exportproc(sync, mfd, nil, hostname, dfd);
				<-sync;
			} else alt {
				authslots <-= 1 =>
					src := srchost(nc.dir);
					if(!srcacquire(src)) {
						<-authslots;
						if(verbose)
							sys->fprint(stderr(), "styxlisten: pre-auth limit per source (%d) reached for %s\n", perlimit, src);
						nethangup(nc.cfd);
						dfd = nil;
						nc.cfd = nil;
					} else if(!rateallow()) {
						srcrelease(src);
						<-authslots;
						if(verbose)
							sys->fprint(stderr(), "styxlisten: pre-auth rate limit reached\n");
						nethangup(nc.cfd);
						dfd = nil;
						nc.cfd = nil;
					} else
						spawn authenticator(dfd, nc.cfd, authinfo, mfd, algs, hostname, src);
				* =>
					if(verbose)
						sys->fprint(stderr(), "styxlisten: pre-auth limit reached\n");
					nethangup(nc.cfd);
					dfd = nil;
					nc.cfd = nil;
				}
		}
	}
}

rateallow(): int
{
	now := sys->millisec();
	if(ratecount == 0 || now < ratewindow || now-ratewindow >= 1000) {
		ratewindow = now;
		ratecount = 0;
	}
	if(ratecount >= authrate)
		return 0;
	ratecount++;
	return 1;
}

# authenticate a connection and set the user id.
authenticator(dfd, cfd: ref Sys->FD, authinfo: ref Keyring->Authinfo, mfd: ref Sys->FD,
		algs: list of string, hostname: string, src: string)
{
	# authenticate and change user id appropriately
	cancel := chan[1] of int;
	spawn authwatchdog(cancel, sys->pctl(0, nil), cfd, authtimeout, src);
	(fd, err) := auth->server(algs, authinfo, dfd, 1);
	cancel <-= 1;
	if (fd == nil) {
		if (verbose)
			sys->fprint(stderr(), "styxlisten: authentication failed: %s\n", err);
		return;
	}
	if (verbose)
		sys->fprint(stderr(), "styxlisten: client authenticated as %s\n", err);
	sync := chan of int;
	spawn exportproc(sync, mfd, err, hostname, fd);
	<-sync;
}

timerproc(c: chan of int, ms: int)
{
	# A successful authentication cancels the watcher, but this timer still
	# sleeps to its deadline.  Do not let that sleeper retain the accepted
	# socket and delay EOF or consume connection resources.
	sys->pctl(Sys->NEWFD, nil);
	sys->sleep(ms);
	c <-= 1;
}

nethangup(cfd: ref Sys->FD)
{
	if(cfd != nil)
		sys->fprint(cfd, "hangup");
}

authwatchdog(cancel: chan of int, pid: int, cfd: ref Sys->FD, ms: int, src: string)
{
	tmo := chan[1] of int;
	spawn timerproc(tmo, ms);
	alt {
	<-cancel =>
		<-authslots;
		srcrelease(src);
		return;
	<-tmo =>
		<-authslots;
		srcrelease(src);
		nethangup(cfd);
		kill(pid, "kill");
	}
}

exportproc(sync: chan of int, fd: ref Sys->FD, uname, hostname: string, dfd: ref Sys->FD)
{
	sys->pctl(Sys->NEWFD | Sys->NEWNS, 2 :: fd.fd :: dfd.fd :: nil);
	fd = sys->fildes(fd.fd);
	dfd = sys->fildes(dfd.fd);
	sync <-= 1;

	# XXX unfortunately we cannot pass through the aname from
	# the original attach, an inherent shortcoming of this scheme.
	if (sys->mount(fd, nil, "/", Sys->MREPL|Sys->MCREATE, hostname) == -1)
		error(sys->sprint("cannot mount for user '%s': %r\n", uname));

	sys->export(dfd, "/", Sys->EXPWAIT);
}

error(e: string)
{
	sys->fprint(stderr(), "styxlisten: %s\n", e);
	raise "fail:error";
}
	

popen(ctxt: ref Draw->Context, argv: list of string, lsync: chan of int): ref Sys->FD
{
	sync := chan of int;
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	spawn runcmd(ctxt, argv, fds[0], sync, lsync);
	<-sync;
	return fds[1];
}

runcmd(ctxt: ref Draw->Context, argv: list of string, stdin: ref Sys->FD,
		sync: chan of int, lsync: chan of int)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(stdin.fd, 0);
	stdin = nil;
	sync <-= 0;
	sh := load Sh Sh->PATH;
	e := sh->run(ctxt, argv);
	kill(<-lsync, "kill");		# kill listener, as command has exited
	if(verbose){
		if(e != nil)
			sys->fprint(stderr(), "styxlisten: command exited with error: %s\n", e);
		else
			sys->fprint(stderr(), "styxlisten: command exited\n");
	}
}

kill(pid: int, how: string)
{
	sys->fprint(sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE), "%s", how);
}

user(): string
{
	if ((s := readfile("/dev/user")) == nil)
		return "none";
	return s;
}

readfile(f: string): string
{
	fd := sys->open(f, sys->OREAD);
	if(fd == nil)
		return nil;

	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;

	return string buf[0:n];	
}

getalgs(): list of string
{
	sslctl := readfile("#D/clone");
	if (sslctl == nil) {
		sslctl = readfile("#D/ssl/clone");
		if (sslctl == nil)
			return nil;
		sslctl = "#D/ssl/" + sslctl;
	} else
		sslctl = "#D/" + sslctl;
	(nil, algs) := sys->tokenize(readfile(sslctl + "/encalgs") + " " + readfile(sslctl + "/hashalgs"), " \t\n");
	# Keep authenticated transport protected by default.  An operator who
	# truly wants plaintext must select that policy explicitly.
	return algs;
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
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
