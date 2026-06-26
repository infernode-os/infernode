implement Listen;
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "keyring.m";
	keyring: Keyring;
include "security.m";
	auth: Auth;
include "sh.m";
	sh: Sh;
	Context: import sh;

Listen: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

badmodule(p: string)
{
	sys->fprint(stderr(), "listen: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

serverkey: ref Keyring->Authinfo;
verbose := 0;

# Upper bound (ms) on the pre-authentication handshake. A client that
# connects but never completes keyring auth (half-open / slowloris)
# would otherwise pin the authenticator proc — and its host kproc
# thread — indefinitely, because auth->server reads the socket with no
# timeout of its own. Left unbounded, a stream of such connections grows
# the emu's kproc thread pool without limit (a pre-auth DoS). Legitimate
# keyring auth completes in well under a second even over a slow remote
# link, so 30s is generous. See INFR-353.
AUTHTIMEOUT: con 30*1000;

init(drawctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	keyring = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	if (auth == nil)
		badmodule(Auth->PATH);
	sh = load Sh Sh->PATH;
	if (sh == nil)
		badmodule(Sh->PATH);
	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmodule(Arg->PATH);
	auth->init();
	algs: list of string;
	arg->init(argv);
	keyfile: string;
	initscript: string;
	doauth := 1;
	synchronous := 0;
	trusted := 0;
	arg->setusage("listen [-i {initscript}] [-Ast] [-k keyfile] [-a alg]... addr command [arg...]");
	while ((opt := arg->opt()) != 0) {
		case opt {
		'a' =>
			algs = arg->earg() :: algs;
		'A' =>
			doauth = 0;
		'f' or
		'k' =>
			keyfile = arg->earg();
			if (! (keyfile[0] == '/' || (len keyfile > 2 &&  keyfile[0:2] == "./")))
				keyfile = "/usr/" + user() + "/keyring/" + keyfile;
		'i' =>
			initscript = arg->earg();
		'v' =>
			verbose = 1;
		's' =>
			synchronous = 1;
		't' =>
			trusted = 1;
		* =>
			arg->usage();
		}
	}
	if (doauth && algs == nil)
		algs = getalgs();
	if (doauth && algs == nil) {
		sys->fprint(stderr(), "listen: authentication requested, but no SSL algorithms are available\n");
		raise "fail:no auth algorithms";
	}
	if (algs != nil) {
		if (keyfile == nil)
			keyfile = "/usr/" + user() + "/keyring/default";
		serverkey = keyring->readauthinfo(keyfile);
		if (serverkey == nil) {
			sys->fprint(stderr(), "listen: cannot read %s: %r\n", keyfile);
			raise "fail:bad keyfile";
		}
	}
	if(!trusted){
		sys->unmount(nil, "/mnt/keys");	# should do for now
		# become none?
	}

	argv = arg->argv();
	n := len argv;
	if (n < 2)
		arg->usage();
	arg = nil;

	sync := chan[1] of string;
	spawn listen(drawctxt, hd argv, tl argv, algs,  initscript, sync);
	e := <-sync;
	if(e != nil)
		raise "fail:" + e;
	if(synchronous){
		# Positive, fail-loud serving indication: in synchronous
		# (daemon) mode the announce has succeeded by now, so emit a
		# line a supervisor/journal can latch onto. Without this the
		# only post-startup evidence is the absence of a crash, which
		# is indistinguishable from a silent wedge (INFR-353).
		sys->fprint(stderr(), "listen: listening on %s\n", hd argv);
		e = <-sync;
		if(e != nil)
			raise "fail:" + e;
	}
}

listen(drawctxt: ref Draw->Context, addr: string, argv: list of string,
		algs: list of string, initscript: string, sync: chan of string)
{
	{
		listen1(drawctxt, addr, argv, algs, initscript, sync);
	} exception e {
	"fail:*" =>
		sync <-= e;
	}
}

listen1(drawctxt: ref Draw->Context, addr: string, argv: list of string,
		algs: list of string, initscript: string, sync: chan of string)
{
	sys->pctl(Sys->FORKFD, nil);

	ctxt := Context.new(drawctxt);
	(ok, acon) := sys->announce(addr);
	if (ok == -1) {
		sys->fprint(stderr(), "listen: failed to announce on '%s': %r\n", addr);
		sync <-= "cannot announce";
		exit;
	}
	ctxt.set("user", nil);
	if (initscript != nil) {
		ctxt.setlocal("net", ref Sh->Listnode(nil, acon.dir) :: nil);
		ctxt.run(ref Sh->Listnode(nil, initscript) :: nil, 0);
		initscript = nil;
	}

	# make sure the shell command is parsed only once.
	cmd := sh->stringlist2list(argv);
	if((hd argv) != nil && (hd argv)[0] == '{'){
		(c, e) := sh->parse(hd argv);
		if(c == nil){
			sys->fprint(stderr(), "listen: %s\n", e);
			sync <-= "parse error";
			exit;
		}
		cmd = ref Sh->Listnode(c, hd argv) :: tl cmd;
	}

	sync <-= nil;
	listench := chan of (int, Sys->Connection);
	authch := chan of (string, Sys->Connection);
	spawn listener(listench, acon, addr);
	for (;;) {
		user := "";
		ccon: Sys->Connection;
		alt {
		(lok, c) := <-listench =>
			if (lok == -1){
				sync <-= "listen";
				exit;
			}
			if (algs != nil) {
				spawn authenticator(authch, c, algs, addr);
				continue;
			}
			ccon = c;
		(user, ccon) = <-authch =>
			;
		}
		if (user != nil)
			ctxt.set("user", sh->stringlist2list(user :: nil));
		ctxt.set("net", ref Sh->Listnode(nil, ccon.dir) :: nil);

		# XXX could do this in a separate process too, to
		# allow new connections to arrive and start authenticating
		# while the shell command is still running.
		sys->dup(ccon.dfd.fd, 0);
		sys->dup(ccon.dfd.fd, 1);
		ccon.dfd = ccon.cfd = nil;
		ctxt.run(cmd, 0);
		sys->dup(2, 0);
		sys->dup(2, 1);
	}
}

listener(listench: chan of (int, Sys->Connection), c: Sys->Connection, addr: string)
{
	for (;;) {
		(ok, nc) := sys->listen(c);
		if (ok == -1) {
			sys->fprint(stderr(), "listen: listen error on '%s': %r\n", addr);
			listench <-= (-1, nc);
			exit;
		}
		if (verbose)
			sys->fprint(stderr(), "listen: got connection on %s from %s",
					addr, readfile(nc.dir + "/remote"));
		nc.dfd = sys->open(nc.dir + "/data", Sys->ORDWR);
		if (nc.dfd == nil)
			sys->fprint(stderr(), "listen: cannot open %s: %r\n", nc.dir + "/data");
		else{
			if(nc.cfd != nil)
				sys->fprint(nc.cfd, "keepalive");
			listench <-= (ok, nc);
		}
	}
}

authenticator(authch: chan of (string, Sys->Connection),
		c: Sys->Connection, algs: list of string, addr: string)
{
	# Arm a watchdog before the (potentially blocking, un-timed) auth
	# handshake. cancel is buffered so the post-handshake send never
	# blocks, whether or not the watchdog has already woken. INFR-353.
	cancel := chan[1] of int;
	spawn authtimeout(c.cfd, cancel, addr);

	err: string;
	(c.dfd, err) = auth->server(algs, serverkey, c.dfd, 1);
	cancel <-= 1;
	if (c.dfd == nil) {
		sys->fprint(stderr(), "listen: auth on %s failed: %s\n", addr, err);
		return;
	}
	if (verbose)
		sys->fprint(stderr(), "listen: authenticated on %s as %s\n", addr, err);
	authch <-= (err, c);
}

# Hang up the connection if the authentication handshake has not
# completed within AUTHTIMEOUT. Writing "hangup" to the connection's
# control fd tears down the transport, which unblocks the auth read in
# auth->server so the authenticator proc (and its kproc thread) exits.
authtimeout(cfd: ref Sys->FD, cancel: chan of int, addr: string)
{
	sys->sleep(AUTHTIMEOUT);
	alt {
	<-cancel =>
		;	# handshake finished in time; nothing to do
	* =>
		if (verbose)
			sys->fprint(stderr(), "listen: pre-auth timeout on %s; hanging up\n", addr);
		if (cfd != nil)
			sys->fprint(cfd, "hangup");
	}
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

user(): string
{
	u := readfile("/dev/user");
	if (u == nil)
		return "nobody";
	return u;
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
	return "none" :: algs;
}
