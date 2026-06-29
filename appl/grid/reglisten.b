implement Listen;

#
# Copyright © 2003 Vita Nuova Holdings Limited.  All rights reserved.
#

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
include "registries.m";
	registries: Registries;
	Registry, Attributes, Service: import registries;

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
authtimeout := 30000;
authlimit := 32;
authslots: chan of int;
authrate := 8;
ratewindow := 0;
ratecount := 0;

registered: ref Registries->Registered;

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
	regattrs: list of (string, string);
	arg->setusage("listen [-i {initscript}] [-Ast] [-L maxauth] [-R authrate] [-T ms] [-f keyfile] [-a alg]... addr command [arg...]");
	while ((opt := arg->opt()) != 0) {
		case opt {
		'a' =>
			algs = arg->earg() :: algs;
		'A' =>
			doauth = 0;
		'f' =>
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
		'r' =>
			a := arg->earg();
			v := arg->earg();
			regattrs = (a, v) :: regattrs;
		* =>
			arg->usage();
		}
	}
	if(regattrs != nil){
		registries = load Registries Registries->PATH;
		if(registries == nil)
			badmodule(Registries->PATH);
		registries->init();
	}

	if (doauth && algs == nil)
		algs = getalgs();
	if (algs != nil) {
		authslots = chan[authlimit] of int;
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
	spawn listen(drawctxt, hd argv, tl argv, algs, regattrs, initscript, sync);
	e := <-sync;
	if(e != nil)
		raise "fail:" + e;
	if(synchronous){
		e = <-sync;
		if(e != nil)
			raise "fail:" + e;
	}
}

regmonitor(addr: string, attrs: ref Attributes, persist: int)
{
	for(;;){
		(n, nil) := sys->stat("/mnt/registry/" + addr);
		if(n != 0)
			regain(addr, attrs, persist);
		sys->sleep(1000*60*10);
	}
}

regain(addr: string, attrs: ref Attributes, persist: int)
{
	err: string;
	reg: ref Registry;
	reg = Registry.new("/mnt/registry");
	if (reg == nil){
		svc := ref Service("net!$registry!registry", Attributes.new(("auth", "infpk1") :: nil));
		reg = Registry.connect(svc, nil, nil);
	}
	if (reg == nil){
		sys->fprint(sys->fildes(2), "Could not find registry: %r\n");
		return;
	}
	(registered, err) = reg.register(addr, attrs, persist);
	if (err != nil) 
		sys->fprint(sys->fildes(2), "%s\n", "could not register with registry: "+err);
}

listen(drawctxt: ref Draw->Context, addr: string, argv: list of string,
		algs: list of string, regattrs: list of (string, string),
		initscript: string, sync: chan of string)
{
	{
		listen1(drawctxt, addr, argv, algs, regattrs, initscript, sync);
	} exception e {
	"fail:*" =>
		sync <-= e;
	}
}

listen1(drawctxt: ref Draw->Context, addr: string, argv: list of string,
		algs: list of string, regattrs: list of (string, string),
		initscript: string, sync: chan of string)
{
	sys->pctl(Sys->FORKFD, nil);
	ctxt := Context.new(drawctxt);
	(myaddr, conn) := announce(addr);
	if(myaddr == nil){
		sys->fprint(stderr(), "listen: failed to announce on '%s': %r\n", addr);
		sync <-= "cannot announce";
		exit;
	}
	addr = myaddr;
	acon := *conn;

	spawn regmonitor(myaddr, Attributes.new(regattrs), 0);

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
			if (lok == -1)
				sync <-= "listen";
			if (algs != nil) {
				if(!rateallow()) {
					nethangup(c.cfd);
					c.dfd = c.cfd = nil;
					continue;
				}
				alt {
				authslots <-= 1 =>
					spawn authenticator(authch, c, algs, addr);
				* =>
					nethangup(c.cfd);
					c.dfd = c.cfd = nil;
				}
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
		else
			listench <-= (ok, nc);
	}
}

authenticator(authch: chan of (string, Sys->Connection),
		c: Sys->Connection, algs: list of string, addr: string)
{
	err: string;
	(c.dfd, err) = authserver(algs, serverkey, c.dfd, c.cfd, 0);
	<-authslots;
	if (c.dfd == nil) {
		sys->fprint(stderr(), "listen: auth on %s failed: %s\n", addr, err);
		return;
	}
	if (verbose)
		sys->fprint(stderr(), "listen: authenticated on %s as %s\n", addr, err);
	authch <-= (err, c);
}

authworker(pidc: chan of int, rc: chan of (ref Sys->FD, string),
		algs: list of string, ai: ref Keyring->Authinfo, dfd: ref Sys->FD, setid: int)
{
	pidc <-= sys->pctl(0, nil);
	rc <-= auth->server(algs, ai, dfd, setid);
}

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

nethangup(cfd: ref Sys->FD)
{
	if(cfd != nil)
		sys->fprint(cfd, "hangup");
}

kill(pid: int, how: string)
{
	if(pid <= 0)
		return;
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", how);
}

authserver(algs: list of string, ai: ref Keyring->Authinfo,
		dfd, cfd: ref Sys->FD, setid: int): (ref Sys->FD, string)
{
	pidc := chan[1] of int;
	rc := chan[1] of (ref Sys->FD, string);
	tmo := chan[1] of int;
	spawn authworker(pidc, rc, algs, ai, dfd, setid);
	pid := <-pidc;
	spawn timerproc(tmo, authtimeout);
	alt {
	(fd, err) := <-rc =>
		return (fd, err);
	<-tmo =>
		nethangup(cfd);
		kill(pid, "kill");
		return (nil, "authentication timeout");
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

announce(addr: string): (string, ref Sys->Connection)
{
	sysname := readfile("/dev/sysname");
	(ok, c) := sys->announce(addr);
	if(ok == -1)
		return (nil, nil);
	local := readfile(c.dir + "/local");
	if(local == nil)
		return (nil, nil);
	for(i := len local - 1; i >= 0; i--)
		if(local[i] == '!')
			break;
	port := local[i+1:];
	if(port == nil)
		return (nil, nil);
	if(port[len port - 1] == '\n')
		port = port[0:len port - 1];
	return ("tcp!" + sysname + "!" + port, ref c);
}
