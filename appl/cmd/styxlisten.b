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
	# -A with an algorithm asked for both: it started, and its first
	# caller ended the listener (the count of callers being
	# authenticated is kept only when there is authentication)
	if (!doauth && algs != nil)
		arg->usage();
	arg = nil;
	if (doauth && algs == nil)
		algs = "aes_256_gcm" :: nil;
	if (doauth && algs == nil)
		error("authentication requested, but no SSL algorithms are available");
	if (doauth) {
		checkalgs(algs);
		warnuser();
	}
	addr := netmkaddr(hd argv, "tcp", "styx");
	cmd := tl argv;

	# What is hidden from the command (the key file, /mnt/keys) is
	# hidden in a name space of the listener's own.  With -A there was
	# none, and the unmount below took /mnt/keys from whoever started
	# the listener as well.
	if(!trusted && sys->pctl(Sys->FORKNS, nil) < 0)
		error("cannot fork key namespace");
	authinfo: ref Keyring->Authinfo;
	if (doauth) {
		authslots = chan[authlimit] of int;
		srclock = chan[1] of int;
		if (keyfile == nil)
			keyfile = "/usr/" + user() + "/keyring/default";
		# Keep key masking private to this listener.  Children need the
		# in-memory Authinfo, never the credential file itself.
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

	sesslock = chan[1] of int;
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
					} else if(!rateallow(src)) {
						srcrelease(src);
						<-authslots;
						if(verbose)
							sys->fprint(stderr(), "styxlisten: pre-auth rate limit reached for %s\n", src);
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

# One address may start at most half of a second's exchanges (and
# always one): the budget was one count for every caller, so eight
# connections a second from one address, each within its own limit of
# exchanges in flight, used all of it and every other caller was hung
# up.  Called only by the listener's own process.
Srcrate: adt {
	host:	string;
	n:	int;
};
srcrates: list of ref Srcrate;

rateallow(host: string): int
{
	now := sys->millisec();
	if(ratecount == 0 || now < ratewindow || now-ratewindow >= 1000) {
		ratewindow = now;
		ratecount = 0;
		srcrates = nil;
	}
	if(ratecount >= authrate)
		return 0;
	share := (authrate+1)/2;
	sr: ref Srcrate;
	for(l := srcrates; l != nil; l = tl l)
		if((hd l).host == host)
			sr = hd l;
	if(sr == nil){
		sr = ref Srcrate(host, 0);
		srcrates = sr :: srcrates;
	}
	if(sr.n >= share)
		return 0;
	sr.n++;
	ratecount++;
	return 1;
}

# authenticate a connection and set the user id.
authenticator(dfd, cfd: ref Sys->FD, authinfo: ref Keyring->Authinfo, mfd: ref Sys->FD,
		algs: list of string, hostname: string, src: string)
{
	# authenticate and change user id appropriately
	cancel := chan[1] of int;
	decided := chan[1] of int;
	spawn authwatchdog(cancel, decided, sys->pctl(0, nil), cfd, authtimeout, src);
	(fd, err) := auth->server(algs, authinfo, dfd, 1);
	alt {
	decided <-= 1 =>
		;
	* =>
		return;	# the deadline came first: the watchdog has hung up
	}
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

authwatchdog(cancel, decided: chan of int, pid: int, cfd: ref Sys->FD, ms: int, src: string)
{
	tmo := chan[1] of int;
	spawn timerproc(tmo, ms);
	alt {
	<-cancel =>
		<-authslots;
		srcrelease(src);
		return;
	<-tmo =>
		# with both ready alt takes either: an exchange that ended at
		# its deadline was killed all the same.  Whichever of the two
		# puts its word in decided first has the connection.
		alt {
		decided <-= 1 =>
			<-authslots;
			srcrelease(src);
			nethangup(cfd);
			kill(pid, "kill");
			if(verbose)
				sys->fprint(stderr(), "styxlisten: authentication of %s not finished in %d ms: hung up\n", src, ms);
		* =>
			<-cancel;
			<-authslots;
			srcrelease(src);
		}
	}
}

# The processes serving callers, for the command's end: they were left
# when the command exited, each exporting a mount of a pipe nobody
# answered on until its caller went away.
sessions: list of int;
sesslock: chan of int;

session(pid: int, add: int)
{
	sesslock <-= 1;
	if(add)
		sessions = pid :: sessions;
	else{
		l: list of int;
		for(; sessions != nil; sessions = tl sessions)
			if(hd sessions != pid)
				l = hd sessions :: l;
		sessions = l;
	}
	<-sesslock;
}

exportproc(sync: chan of int, fd: ref Sys->FD, uname, hostname: string, dfd: ref Sys->FD)
{
	pid := sys->pctl(Sys->NEWFD | Sys->NEWNS, 2 :: fd.fd :: dfd.fd :: nil);
	fd = sys->fildes(fd.fd);
	dfd = sys->fildes(dfd.fd);
	session(pid, 1);
	sync <-= 1;

	# XXX unfortunately we cannot pass through the aname from
	# the original attach, an inherent shortcoming of this scheme.
	if (sys->mount(fd, nil, "/", Sys->MREPL|Sys->MCREATE, hostname) == -1)
	{
		session(pid, 0);
		error(sys->sprint("cannot mount for user '%s': %r\n", uname));
	}

	sys->export(dfd, "/", Sys->EXPWAIT);
	session(pid, 0);
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
	# its own end of the pipe and the standard files, and nothing else:
	# a copy of the whole table (FORKFD) held the listener's end too,
	# so the command never saw the end of its input when the listener
	# and every caller had gone
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: stdin.fd :: nil);
	sys->dup(stdin.fd, 0);
	stdin = nil;
	sync <-= 0;
	sh := load Sh Sh->PATH;
	e := sh->run(ctxt, argv);
	kill(<-lsync, "kill");		# kill listener, as command has exited
	# and what serves its callers: there is nothing left to serve them
	sesslock <-= 1;
	l := sessions;
	sessions = nil;
	<-sesslock;
	for(; l != nil; l = tl l)
		kill(hd l, "kill");
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

PROG: con "styxlisten";

# The algorithms a listener is given are checked when it starts, not at
# each call.  A name ssl(3) does not have (a mistyped one; the rc4_256
# and sha1 of old scripts) was passed on as it was, and a list of such
# names let a caller that named nothing have a clear session.  "none"
# may stand beside an algorithm: each caller's choice is confirmed under
# the secret the two ends authenticated with and is part of the keys
# (security-auth(2)), so nobody on the path can change it.  (While the
# choice went in clear that mixture needed -M; the option is gone.)
checkalgs(algs: list of string)
{
	known := getalgs();
	bad := "";
	for(l := algs; l != nil; l = tl l){
		a := hd l;
		if(a != "none" && a != "clear" && !member(a, known))
			bad += " " + a;
	}
	if(bad != nil){
		have := "";
		for(; known != nil; known = tl known)
			have += " " + hd known;
		sys->fprint(stderr(), "%s: -a:%s: not an algorithm of ssl(3), which has:%s\n", PROG, bad, have);
		raise "fail:bad algorithm";
	}
}

# Each caller is to run as itself: Auth->server writes the caller's name
# to /dev/user, which the system takes only from the host owner.  A
# listener started by anyone else serves every caller under its own
# name, with its own rights to files; it said nothing of it.
warnuser()
{
	me := readfile("/dev/user");
	owner := readfile("/dev/hostowner");
	if(owner != nil && me != owner)
		sys->fprint(stderr(), "%s: running as %s, not the host owner %s: cannot become the callers it authenticates, so each is served as %s\n", PROG, me, owner, me);
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
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
