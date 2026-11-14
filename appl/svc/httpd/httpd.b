implement Httpd;

#
# httpd(8): a web server for a name space.
#
# What it serves is a directory, root, and whatever is bound or mounted
# under it: a device's 9P server bound at root/gps is a page whose GET
# reads the position.  Each connection runs in a name space of its own
# in which root is / and devices cannot be attached (FORKNS, a bind
# over /, NODEVS), with an empty environment and no descriptors but its
# connection's and the log's: a path that got past the checks below
# would find nothing outside the site to open.
#
# HTTP/1.1, over TLS 1.3 (tls(2)'s server) with -c and -k.  GET and
# HEAD of files and directories; POST only to the paths named by -p
# (the body is written to the file) and to /magic/wikipost with -w
# (wikifs(4)'s edit form).  Requests are parsed strictly and bounded:
# a request line or header line of 8K, 64 headers, 16K of them in all,
# no folded or bare-CR lines, one Host, no Transfer-Encoding, one
# Content-Length; a path with a NUL, a control character, a "." or
# ".." segment or bad UTF-8 is refused; one starting with "." is not
# found.  Every phase has a deadline (the TLS handshake, the headers,
# the idle time between requests, each read and write); a connection
# past one is hung up and its processes killed by the listener, which
# also caps connections in all and from one address.
#

include "sys.m";
	sys: Sys;
	FD, Dir, Connection: import Sys;

include "draw.m";

include "daytime.m";
	daytime: Daytime;
	Tm: import daytime;

include "arg.m";

include "tls.m";
	tls: TLS;
	Conn, ServerConfig: import tls;

include "keyring.m";
	keyring: Keyring;

include "encoding.m";
	base64: Encoding;

include "asn1.m";
include "pkcs.m";
include "x509.m";

Httpd: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# Limits
MAXLINE:	con 8192;		# a request line or one header line
MAXHDRS:	con 64;		# headers in a request
MAXHDRBYTES:	con 16384;		# all of a request's headers
MAXPATH:	con 2048;		# a decoded path
MAXREQS:	con 1000;		# requests on one connection (nginx's keepalive_requests)
BUFSIZE:	con 16384;

# Deadlines, in milliseconds
TLSWAIT:	con 10*1000;	# the TLS handshake
HDRWAIT:	con 10*1000;	# a request's headers, from the first request
IDLEWAIT:	con 15*1000;	# between requests on a kept connection, and its headers
IOWAIT:		con 30*1000;	# each read of a body, write of a response, read of a file
BEATWAIT:	con 15*1000;	# an event stream's silence before a comment keeps it open

# Options
root := "";
addr := "";
listdirs := 0;
posts: list of string;		# paths a POST writes to
wikibase := "";		# where wikifs is in the site, for /magic/wikipost
redirport := "";		# -r: send every request to https on this port
hsts := 0;			# -S: Strict-Transport-Security max-age
maxconns := 64;
maxpersource := 16;
maxbody := 65536;
verbose := 0;
maxage := 0;			# -C: Cache-Control max-age for files that are not HTML

scfg: ref ServerConfig;

# Who may have what (-A, -P, -x)
trustfile := "";		# -A: CA certificates (and CRLs) whose client certificates are taken
pwfile := "";			# -P: passwords (svc/httpd/passwd makes the lines)
rulesfile := "";		# -x: which paths need which; without it the defaults (rules())
realm := "InferNode";

Anyone, Password, Cert: con iota;
Term: adt {
	kind:	int;
	name:	string;	# nil: any user, any certificate; else the one (a user, a CN, sha256:hex)
};
Rule: adt {
	meth:	string;	# GET (for HEAD too) or POST; nil: both
	prefix:	string;	# lower case, so a host whose files are named without case (macOS, Windows) cannot be asked another way
	orig:	string;	# as the rules file has it
	depth:	int;	# its names: / is 0, /admin 1
	terms:	list of ref Term;	# any one of them will do
	# what it names, if that was there when httpd started (findrule)
	resolved:	int;
	qpath:	big;
	dtype:	int;
	dev:	int;
};
rules: list of ref Rule;
maxresolved := 0;	# the depth of the deepest protecting rule found by identity: no stat past it
rulesprotect := 0;	# a rule protects something
authc: chan of (string, string, string, chan of int);	# (user, password, address, answer) to the authenticator
Ok, Bad, Locked: con iota;

logfd: ref FD;
logfile := "";
logmax := big (1024*1024);	# -m: the log's size at which it is rotated; 0: never
logold := 2;			# -M: how many old logs are kept (log.1 the newest)
logc: chan of array of byte;	# the connections' lines, to the logger, which alone writes the log
stderr: ref FD;

# /dev/time, opened before the connections are confined and kept by
# them: the clock as it is now, set after httpd started or not (a
# board's clock is often set by timesync(8) or NTP after boot).  If
# there is none, the time at start and the millisecond clock since.
timefd: ref FD;
ntfs := 0;		# the emulator is Windows's (its emuhost is Nt)
epoch0 := 0;
ms0 := 0;

# A connection's state as the listener's watchdog sees it
Watch: adt {
	deadline:	int;	# sys->millisec() past which it is hung up; 0: none
	pid:	int;	# its process (group), to kill
	orphans:	int;	# it leaves a process behind (an event stream's reader blocked in a read), killed with its group when it ends
	ip:	string;	# the client's address
	stream:	int;	# it holds an event stream (the watchdog's to set)
};

Entry: adt {
	w:	ref Watch;
	cfd:	ref FD;
	ip:	string;
};

admitc: chan of (string, ref FD, chan of ref Watch);
donec: chan of ref Watch;
streamc: chan of (ref Watch, chan of int);	# may this connection hold an event stream?	# a connection's end, told at once: a client's next connection is not refused for one it has finished with

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		fatal(sys->sprint("cannot load %s: %r", Daytime->PATH));
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fatal(sys->sprint("cannot load %s: %r", Arg->PATH));

	certfile, keyfile: string;
	keyring = load Keyring Keyring->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	if(keyring == nil || base64 == nil)
		fatal(sys->sprint("cannot load keyring or base64: %r"));
	arg->init(argv);
	arg->setusage("svc/httpd/httpd [-Lv] [-a addr] [-c cert -k key] [-l log] [-p path]... [-w wikibase]\n\t[-r httpsport] [-S hstssecs] [-C maxage] [-m maxlog] [-M oldlogs]\n\t[-A clientcas] [-P passwords] [-x rules] [-n maxconns] [-s persource] [-b maxbody] root");
	while((o := arg->opt()) != 0)
		case o {
		'a' =>	addr = arg->earg();
		'c' =>	certfile = arg->earg();
		'k' =>	keyfile = arg->earg();
		'l' =>	logfile = arg->earg();
		'L' =>	listdirs = 1;
		'p' =>
			p := cleanpath(arg->earg());
			if(p == nil)
				fatal("-p: not a path in the site");
			posts = p :: posts;
		'w' =>
			wikibase = cleanpath(arg->earg());
			if(wikibase == nil)
				fatal("-w: not a path in the site");
		'r' =>	redirport = arg->earg();
		'S' =>	hsts = posint(arg->earg());
		'n' =>	maxconns = posint(arg->earg());
		's' =>	maxpersource = posint(arg->earg());
		'b' =>	maxbody = posint(arg->earg());
		'v' =>	verbose = 1;
		'C' =>	maxage = posint(arg->earg());
		'm' =>	logmax = size(arg->earg());
		'M' =>	logold = posint(arg->earg());
		'A' =>	trustfile = arg->earg();
		'P' =>	pwfile = arg->earg();
		'x' =>	rulesfile = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(len argv != 1 || maxconns <= 0 || maxpersource <= 0 || maxbody <= 0 || hsts < 0 || maxage < 0 || logmax < big 0 || logold < 1)
		arg->usage();
	if(redirport != nil && (posint(redirport) <= 0 || posint(redirport) > 65535))
		fatal("-r: not a port");

	root = hd argv;
	if(root[0] != '/' && root[0] != '#') {
		cwd := sys->fd2path(sys->open(".", Sys->OREAD));
		if(cwd == nil)
			fatal("cannot find the current directory");
		root = cwd + "/" + root;
	}
	(ok, d) := sys->stat(root);
	if(ok < 0 || (d.mode & Sys->DMDIR) == 0)
		fatal(sys->sprint("%s is not a directory", root));

	if(certfile != nil || keyfile != nil) {
		if(certfile == nil || keyfile == nil)
			fatal("-c and -k go together");
		tls = load TLS TLS->PATH;
		if(tls == nil)
			fatal(sys->sprint("cannot load %s: %r", TLS->PATH));
		if((e := tls->init()) != nil)
			fatal(e);
		scfg = loadidentity(certfile, keyfile);
		# the AEAD fastest here first: clients put AES-GCM first, as
		# theirs has AES instructions, and where ours has none
		# ChaCha20-Poly1305 is several times faster
		scfg.suites = tls->fastsuites();
		if(verbose) {
			t := "";
			for(l := scfg.suites; l != nil; l = tl l)
				t += sys->sprint(" %04x", hd l);
			sys->fprint(stderr, "httpd: TLS suites, fastest first:%s\n", t);
		}
	} else if(hsts)
		fatal("-S needs TLS (-c, -k)");
	if(scfg == nil && (trustfile != nil || pwfile != nil))
		fatal("-A and -P need TLS (-c, -k): a password must not cross the network in clear");
	if(redirport != nil && (trustfile != nil || pwfile != nil || rulesfile != nil))
		fatal("-r answers every request with a redirect: -A, -P and -x are the TLS server's");
	if(addr == nil) {
		if(scfg != nil)
			addr = "tcp!*!443";
		else
			addr = "tcp!*!80";
	}

	if(logfile != nil) {
		if(logfile[0] != '/' && logfile[0] != '#') {
			cwd := sys->fd2path(sys->open(".", Sys->OREAD));
			logfile = cwd + "/" + logfile;
		}
		logfd = openlog();
		if(logfd == nil)
			fatal(sys->sprint("cannot open %s: %r", logfile));
	} else
		logfd = sys->fildes(1);
	logc = chan[128] of array of byte;
	spawn logger();

	timefd = sys->open("/dev/time", Sys->OREAD);
	ntfs = trim(readfile("/env/emuhost", 64)) == "Nt";
	epoch0 = daytime->now();
	ms0 = sys->millisec();

	if(trustfile != nil)
		loadtrust();
	if(rulesfile != nil)
		loadrules();
	if(pwfile != nil) {
		if(loadpasswords() == nil)
			fatal(pwfile + ": no users");
		authc = chan of (string, string, string, chan of int);
		spawn authenticator();
	}
	if(rulesfile != nil)
		for(rl := rules; rl != nil; rl = tl rl)
			for(tm := (hd rl).terms; tm != nil; tm = tl tm) {
				if((hd tm).kind == Cert && trustfile == nil)
					fatal(rulesfile + ": a rule takes a certificate, and there is no -A");
				if((hd tm).kind == Password && pwfile == nil)
					fatal(rulesfile + ": a rule takes a password, and there is no -P");
			}

	(aok, c) := sys->announce(addr);
	if(aok < 0)
		fatal(sys->sprint("cannot announce %s: %r", addr));

	admitc = chan of (string, ref FD, chan of ref Watch);
	donec = chan[16] of ref Watch;
	streamc = chan of (ref Watch, chan of int);
	spawn watchdog();
	for(;;) {
		(lok, nc) := sys->listen(c);
		if(lok < 0) {
			sys->fprint(stderr, "httpd: listen: %r\n");
			sys->sleep(1000);
			continue;
		}
		dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(dfd == nil)
			continue;
		remote := readfile(nc.dir + "/remote", 128);
		(ip, nil) := splitlast(trim(remote), '!');
		rc := chan of ref Watch;
		admitc <-= (ip, nc.cfd, rc);
		w := <-rc;
		if(w == nil)
			continue;	# over a limit: closed unanswered
		sync := chan of int;
		spawn connection(dfd, ip, w, sync);
		w.pid = <-sync;
		dfd = nil;
	}
}

loadidentity(certfile, keyfile: string): ref ServerConfig
{
	ctext := readfile(certfile, 1<<20);
	if(ctext == nil)
		fatal(sys->sprint("cannot read %s: %r", certfile));
	certs := tls->pemblocks(ctext, "CERTIFICATE");
	if(certs == nil)
		fatal(certfile + ": no PEM certificate");
	ktext := readfile(keyfile, 65536);
	if(ktext == nil)
		fatal(sys->sprint("cannot read %s: %r", keyfile));
	kb := tls->pemblocks(ktext, "PRIVATE KEY");
	if(kb == nil)
		kb = tls->pemblocks(ktext, "EC PRIVATE KEY");
	if(kb == nil)
		fatal(keyfile + ": no PEM P-256 private key (PRIVATE KEY or EC PRIVATE KEY)");
	(key, err) := tls->p256key(hd kb);
	ktext = nil;
	if(err != nil)
		fatal(keyfile + ": " + err);
	cfg := ref ServerConfig(certs, key, "http/1.1" :: nil, 0, nil, nil, nil, 0, nil);
	if((err = tls->checkserver(cfg)) != nil)
		fatal(certfile + ", " + keyfile + ": " + err);
	return cfg;
}

# The listener's side: admits connections, and hangs up and kills the
# ones past their deadlines.  It alone holds their ctl files.
watchdog()
{
	tick := chan of int;
	spawn ticker(tick);
	conns: list of ref Entry;
	n := 0;
	for(;;) alt {
	(ip, cfd, rc) := <-admitc =>
		k := 0;
		for(l := conns; l != nil; l = tl l)
			if((hd l).ip == ip)
				k++;
		if(n >= maxconns || k >= maxpersource) {
			if(verbose)
				sys->fprint(stderr, "httpd: %s refused: %d connections, %d from it\n", ip, n, k);
			rc <-= nil;
			continue;
		}
		w := ref Watch(sys->millisec() + TLSWAIT + HDRWAIT, 0, 0, ip, 0);
		conns = ref Entry(w, cfd, ip) :: conns;
		n++;
		rc <-= w;
	(sw, src) := <-streamc =>
		# event streams have no deadline: at most half the
		# connections, and half of one address's, so a few clients
		# holding streams leave room for the rest
		ns := 0;
		nip := 0;
		for(l := conns; l != nil; l = tl l)
			if((hd l).w.stream) {
				ns++;
				if((hd l).ip == sw.ip)
					nip++;
			}
		if(ns >= max(1, maxconns / 2) || nip >= max(1, maxpersource / 2))
			src <-= 0;
		else {
			sw.stream = 1;
			src <-= 1;
		}
	w := <-donec =>
		if(w.orphans && w.pid > 0)
			writefile("/prog/" + string w.pid + "/ctl", "killgrp");
		keep: list of ref Entry;
		for(l := conns; l != nil; l = tl l)
			if((hd l).w == w)
				n--;
			else
				keep = hd l :: keep;
		conns = keep;
	<-tick =>
		now := sys->millisec();
		keep: list of ref Entry;
		for(l := conns; l != nil; l = tl l) {
			e := hd l;
			w := e.w;
			if(w.deadline != 0 && now - w.deadline > 0) {
				if(verbose)
					sys->fprint(stderr, "httpd: %s: past its deadline, hung up\n", e.ip);
				if(w.pid > 0)
					writefile("/prog/" + string w.pid + "/ctl", "killgrp");
				sys->fprint(e.cfd, "hangup");
				n--;
				continue;
			}
			keep = e :: keep;
		}
		conns = keep;
	}
}

ticker(c: chan of int)
{
	for(;;) {
		sys->sleep(250);
		c <-= 1;
	}
}

# A connection: confined, then served
connection(dfd: ref FD, ip: string, w: ref Watch, sync: chan of int)
{
	pid := sys->pctl(Sys->NEWPGRP, nil);
	keep := dfd.fd :: stderr.fd :: nil;	# not the log's: the logger writes it
	if(timefd != nil)
		keep = timefd.fd :: keep;
	if(tls != nil)
		for(l := tls->keptfds(); l != nil; l = tl l)
			keep = hd l :: keep;
	sys->pctl(Sys->FORKNS|Sys->NEWENV|Sys->NEWFD, keep);
	sync <-= pid;
	if(sys->bind(root, "/", Sys->MREPL) < 0 || sys->chdir("/") < 0) {
		sys->fprint(stderr, "httpd: cannot make %s the root: %r\n", root);
		donec <-= w;
		return;
	}
	sys->pctl(Sys->NODEVS, nil);
	{
		serve(ref Io(dfd, nil, array[BUFSIZE] of byte, 0, 0, nil, 0, w, nil, nil), ip);
	} exception e {
	"*" =>
		if(verbose)
			sys->fprint(stderr, "httpd: %s: %s\n", ip, e);
	}
	donec <-= w;
}

# ================================================================
# The connection's bytes, plain or under TLS
# ================================================================

Io: adt {
	fd:	ref FD;
	tc:	ref Conn;
	rbuf:	array of byte;
	rp:	int;
	re:	int;
	obuf:	array of byte;
	on:	int;
	w:	ref Watch;
	cn:	string;	# the client's certificate's common name, if it gave one (verified)
	fp:	string;	# and its fingerprint

	fill:	fn(io: self ref Io): int;
	getline:	fn(io: self ref Io, max: int): (string, string);
	read:	fn(io: self ref Io, n: int): array of byte;
	put:	fn(io: self ref Io, b: array of byte): int;
	puts:	fn(io: self ref Io, s: string): int;
	flush:	fn(io: self ref Io): int;
	deadline:	fn(io: self ref Io, ms: int);
};

Io.deadline(io: self ref Io, ms: int)
{
	io.w.deadline = sys->millisec() + ms;
}

# More bytes into the buffer: how many, 0 at end of file, -1 on error
Io.fill(io: self ref Io): int
{
	if(io.rp == io.re)
		io.rp = io.re = 0;
	else if(io.re == len io.rbuf) {
		io.rbuf[0:] = io.rbuf[io.rp:io.re];
		io.re -= io.rp;
		io.rp = 0;
	}
	if(io.re == len io.rbuf)
		return -1;
	n: int;
	if(io.tc != nil)
		n = io.tc.read(io.rbuf[io.re:], len io.rbuf - io.re);
	else
		n = sys->read(io.fd, io.rbuf[io.re:], len io.rbuf - io.re);
	if(n > 0)
		io.re += n;
	return n;
}

# A line ending CRLF, without it: (line, nil), or (nil, why).  A bare
# CR, a NUL, or no LF within max bytes is an error.
Io.getline(io: self ref Io, max: int): (string, string)
{
	for(;;) {
		for(i := io.rp; i < io.re; i++) {
			c := int io.rbuf[i];
			if(c == '\n') {
				if(i - io.rp > max)
					return (nil, "too long");
				if(i == io.rp || io.rbuf[i-1] != byte '\r')
					return (nil, "bare LF");
				s := io.rbuf[io.rp:i-1];
				io.rp = i + 1;
				for(j := 0; j < len s; j++)
					if(s[j] == byte '\r' || s[j] == byte 0)
						return (nil, "CR or NUL in a line");
				return (latin1(s), nil);
			}
		}
		if(io.re - io.rp >= max)
			return (nil, "too long");
		n := io.fill();
		if(n == 0)
			return (nil, "eof");
		if(n < 0)
			return (nil, "read error");
	}
}

# n bytes exactly, or nil
Io.read(io: self ref Io, n: int): array of byte
{
	b := array[n] of byte;
	i := 0;
	io.deadline(IOWAIT);	# the whole body, not each piece: a byte every 29 s does not hold a connection
	while(i < n) {
		if(io.rp == io.re) {
			if(io.fill() <= 0)
				return nil;
		}
		m := io.re - io.rp;
		if(m > n - i)
			m = n - i;
		b[i:] = io.rbuf[io.rp:io.rp+m];
		io.rp += m;
		i += m;
	}
	return b;
}

Io.put(io: self ref Io, b: array of byte): int
{
	if(io.obuf == nil)
		io.obuf = array[BUFSIZE] of byte;
	for(i := 0; i < len b; ) {
		if(io.on == len io.obuf && io.flush() < 0)
			return -1;
		m := len b - i;
		if(m > len io.obuf - io.on)
			m = len io.obuf - io.on;
		io.obuf[io.on:] = b[i:i+m];
		io.on += m;
		i += m;
	}
	return 0;
}

Io.puts(io: self ref Io, s: string): int
{
	return io.put(array of byte s);
}

Io.flush(io: self ref Io): int
{
	if(io.on == 0)
		return 0;
	io.deadline(IOWAIT);
	n: int;
	if(io.tc != nil)
		n = io.tc.write(io.obuf, io.on);
	else
		n = sys->write(io.fd, io.obuf, io.on);
	m := io.on;
	io.on = 0;
	if(n != m)
		return -1;
	return 0;
}

# Header and request-line bytes as Latin-1, one rune each: what is not
# ASCII in a path is percent-encoded (and decoded as UTF-8 later); in a
# header value it is kept as it came.
latin1(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++)
		s[i] = int b[i];
	return s;
}

# ================================================================
# Requests
# ================================================================

Req: adt {
	meth:	string;
	target:	string;
	path:	string;	# decoded and checked; nil if not a file path
	query:	string;
	vers:	int;	# 10 or 11
	host:	string;
	clen:	big;	# -1: none
	close:	int;	# Connection: close
	keepalive:	int;	# Connection: keep-alive (HTTP/1.0)
	rng:	string;
	ifnonematch:	string;
	ifmodsince:	string;
	ifrange:	string;
	origin:	string;
	fetchsite:	string;
	expect:	string;
	ctype:	string;
	referer:	string;
	agent:	string;
	accept:	string;
	acceptenc:	string;
	auth:	string;	# Authorization
	user:	string;	# who it was found to be: a user, or cert:CN
};

serve(io: ref Io, ip: string)
{
	if(scfg != nil) {
		io.deadline(TLSWAIT);
		(tc, err) := tls->server(io.fd, scfg);
		if(err != nil) {
			if(verbose)
				sys->fprint(stderr, "httpd: %s: %s\n", ip, err);
			return;
		}
		io.tc = tc;
		if(tc.peercerts != nil) {
			io.cn = tls->certcn(hd tc.peercerts);
			io.fp = tls->certfingerprint(hd tc.peercerts);
		}
	}
	for(nreq := 0; nreq < MAXREQS; nreq++) {
		if(nreq == 0)
			io.deadline(HDRWAIT);
		else
			io.deadline(IDLEWAIT);
		(r, code, why) := readreq(io);
		if(r == nil && code == 0)
			break;	# the client went
		if(code != 0) {
			if(r == nil)
				r = ref Req("-", "-", nil, nil, 11, nil, big -1, 1, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil);
			r.close = 1;
			if(verbose && why != nil)
				sys->fprint(stderr, "httpd: %s: %d: %s\n", ip, code, why);
			(nil, n, nil) := errorpage(io, r, code, nil);
			logreq(ip, r, code, n);
			io.flush();
			break;
		}
		if(nreq == MAXREQS - 1)
			r.close = 1;
		(status, n, keep) := handle(io, r);
		logreq(ip, r, status, n);
		if(io.flush() < 0 || !keep || r.close)
			break;
	}
	if(io.tc != nil)
		io.tc.close();
}

# A request's line and headers: (req, 0, nil) to answer; (nil, 0, nil)
# at end of file before a request; (req or nil, status, why) to refuse.
readreq(io: ref Io): (ref Req, int, string)
{
	(line, err) := io.getline(MAXLINE);
	if(err == "eof")
		return (nil, 0, nil);
	if(err == nil && line == "") {
		# RFC 9112 §2.2: an empty line before a request is ignored
		(line, err) = io.getline(MAXLINE);
		if(err == "eof")
			return (nil, 0, nil);
	}
	if(err == "too long")
		return (nil, 414, "request line too long");
	if(err != nil)
		return (nil, 400, "request line: " + err);

	# method SP request-target SP HTTP-version, single spaces
	(meth, rest) := splitfirst(line, ' ');
	(target, version) := splitfirst(rest, ' ');
	if(!token(meth) || target == nil || hasbyte(target, ' ') || hasbyte(version, ' '))
		return (nil, 400, "malformed request line");
	r := ref Req(meth, target, nil, nil, 11, nil, big -1, 0, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil);
	case version {
	"HTTP/1.1" =>
		r.vers = 11;
	"HTTP/1.0" =>
		r.vers = 10;
	* =>
		if(len version > 5 && version[0:5] == "HTTP/")
			return (r, 505, "version " + version);
		return (r, 400, "malformed version");
	}

	nh := 0;
	total := 0;
	hosts := 0;
	for(;;) {
		(h, herr) := io.getline(MAXLINE);
		if(herr == "too long")
			return (r, 431, "header line too long");
		if(herr != nil)
			return (r, 400, "header: " + herr);
		if(h == "")
			break;
		nh++;
		total += len h;
		if(nh > MAXHDRS || total > MAXHDRBYTES)
			return (r, 431, "too many headers");
		if(h[0] == ' ' || h[0] == '\t')
			return (r, 400, "folded header");
		(name, value) := splitfirst(h, ':');
		if(!token(name))
			return (r, 400, "malformed header name");
		value = trimows(value);
		for(i := 0; i < len value; i++) {
			c := value[i];
			if(c < 16r20 && c != '\t' || c == 16r7F)
				return (r, 400, "control character in a header");
		}
		case lower(name) {
		"host" =>
			hosts++;
			r.host = lower(value);	# "" (no authority) is nil
		"content-length" =>
			n := decimal(value);
			if(n < big 0)
				return (r, 400, "bad Content-Length");
			if(r.clen >= big 0 && r.clen != n)
				return (r, 400, "two Content-Lengths");
			r.clen = n;
		"transfer-encoding" =>
			# no request body we take needs it, and with a
			# Content-Length it is how requests are smuggled
			return (r, 501, "Transfer-Encoding");
		"connection" =>
			for(t := tokens(lower(value)); t != nil; t = tl t)
				case hd t {
				"close" =>	r.close = 1;
				"keep-alive" =>	r.keepalive = 1;
				}
		"range" =>	r.rng = value;
		"if-none-match" =>	r.ifnonematch = value;
		"if-modified-since" =>	r.ifmodsince = value;
		"if-range" =>	r.ifrange = value;
		"origin" =>	r.origin = lower(value);
		"sec-fetch-site" =>	r.fetchsite = lower(value);
		"expect" =>	r.expect = lower(value);
		"content-type" =>	r.ctype = lower(value);
		"referer" =>	r.referer = value;
		"accept" =>	r.accept = lower(value);
		"accept-encoding" =>	r.acceptenc = lower(value);
		"user-agent" =>	r.agent = value;
		"authorization" =>
			if(r.auth != nil)
				return (r, 400, "two Authorization headers");
			r.auth = value;
		}
	}
	if(r.vers == 10 && !r.keepalive)
		r.close = 1;
	if(hosts > 1 || r.vers == 11 && hosts == 0)
		return (r, 400, "Host missing or repeated");
	if(r.host != nil && !hostport(r.host))
		return (r, 400, "bad Host");

	# the target: origin-form, or absolute-form (RFC 9112 §3.2.2)
	t := target;
	if(len t > 8 && lower(t[0:8]) == "https://")
		t = t[8:];
	else if(len t > 7 && lower(t[0:7]) == "http://")
		t = t[7:];
	else if(t == "*")
		return (r, 501, "OPTIONS *");
	else if(t[0] != '/')
		return (r, 400, "target not a path");
	if(t[0] != '/') {
		(auth, p) := splitbefore(t, '/');
		if(!hostport(lower(auth)))
			return (r, 400, "bad authority in the target");
		r.host = lower(auth);
		t = p;
		if(t == nil)
			t = "/";
	}
	if(hasbyte(t, '#'))
		return (r, 400, "fragment in the target");
	(p, q) := splitfirst(t, '?');
	r.query = q;
	(path, perr) := decodepath(p);
	if(perr != nil)
		return (r, 400, perr);
	r.path = path;
	return (r, 0, nil);
}

# A path's percent-encoding decoded, as UTF-8, and checked: (path, nil)
# or (nil, why).  The path is cleaned of empty segments; a "." or ".."
# segment is refused (a browser removes them before it sends), as are
# NUL, control characters and bytes that are not UTF-8.
decodepath(p: string): (string, string)
{
	b := array[len p] of byte;
	n := 0;
	for(i := 0; i < len p; i++) {
		c := p[i];
		if(c == '%') {
			if(i + 2 >= len p || hexdigit(p[i+1]) < 0 || hexdigit(p[i+2]) < 0)
				return (nil, "bad percent-encoding");
			c = (hexdigit(p[i+1]) << 4) | hexdigit(p[i+2]);
			i += 2;
		} else if(c > 16r7E)
			return (nil, "path not ASCII");
		if(c < 16r20 || c == 16r7F)
			return (nil, "control character in the path");
		b[n++] = byte c;
	}
	s := string b[0:n];
	if(len array of byte s != n || hasbyte(s, 16rFFFD))
		return (nil, "path not UTF-8");
	if(len s > MAXPATH)
		return (nil, "path too long");
	out := "";
	for(segs := split(s, '/'); segs != nil; segs = tl segs) {
		seg := hd segs;
		if(seg == "")
			continue;
		if(seg == "." || seg == "..")
			return (nil, "dot segment in the path");
		# a name a Windows host would take as another: "admin." and
		# "admin " are "admin" there, and \ separates its names
		c := seg[len seg - 1];
		if(c == '.' || c == ' ')
			return (nil, "a segment ending in a dot or blank");
		if(hasbyte(seg, '\\'))
			return (nil, "a backslash in the path");
		if(dosdevice(seg))
			return (nil, "a Windows device's name");
		out += "/" + seg;
	}
	if(out == "")
		out = "/";
	else if(s[len s - 1] == '/')
		out += "/";
	return (out, nil);
}

# A path as -p and -w take it, cleaned as a request's is
cleanpath(p: string): string
{
	if(p == nil || p[0] != '/')
		return nil;
	out := "";
	for(segs := split(p, '/'); segs != nil; segs = tl segs) {
		seg := hd segs;
		if(seg == "" || seg == ".")
			continue;
		if(seg == "..")
			return nil;
		out += "/" + seg;
	}
	return out;
}

# ================================================================
# Answers
# ================================================================

# (status, body bytes sent, whether the connection may go on)
handle(io: ref Io, r: ref Req): (int, big, int)
{
	if(redirport != nil)
		return redirect(io, r);
	# who may: before anything of the site is opened, so a refusal
	# says nothing of what is there
	(acode, ahdr) := authorise(io, r);
	if(acode != 0)
		return errorpage(io, r, acode, ahdr);
	case r.meth {
	"GET" or "HEAD" =>
		return get(io, r);
	"POST" =>
		return post(io, r);
	"PUT" or "DELETE" or "PATCH" or "OPTIONS" or "TRACE" or "CONNECT" =>
		return errorpage(io, r, 405, nil);
	* =>
		return errorpage(io, r, 501, nil);
	}
}

# -r: every request to the same place under https
redirect(io: ref Io, r: ref Req): (int, big, int)
{
	if(r.host == nil)
		return errorpage(io, r, 400, nil);
	(h, nil) := splithostport(r.host);
	if(redirport != "443")
		h += ":" + redirport;
	loc := "https://" + h + urlpath(r.path);
	if(r.query != nil)
		loc += "?" + queryclean(r.query);
	return errorpage(io, r, 301, "Location: " + loc + "\r\n");
}

get(io: ref Io, r: ref Req): (int, big, int)
{
	if(r.clen > big 0)
		return errorpage(io, r, 400, nil);	# a GET with a body: not ours to read
	path := r.path;
	if(dotfile(path))
		return errorpage(io, r, 404, nil);
	fd := sys->open(stripslash(path), Sys->OREAD);
	if(fd == nil)
		return openerror(io, r);
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return errorpage(io, r, 404, nil);
	if(d.mode & Sys->DMDIR) {
		if(path[len path - 1] != '/') {
			loc := urlpath(path + "/");
			if(r.query != nil)
				loc += "?" + queryclean(r.query);
			return errorpage(io, r, 301, "Location: " + loc + "\r\n");
		}
		ifd := sys->open(path + "index.html", Sys->OREAD);
		if(ifd != nil) {
			(iok, id) := sys->fstat(ifd);
			if(iok >= 0 && (id.mode & Sys->DMDIR) == 0)
				return sendvariant(io, r, path + "index.html", ifd, id);
		}
		if(!listdirs)
			return errorpage(io, r, 403, nil);
		return listing(io, r, path, fd);
	}
	if(contains(r.accept, "text/event-stream"))
		return eventstream(io, r, fd);
	return sendvariant(io, r, path, fd, d);
}

# A file with a compressed copy beside it (name.gz, a file with a
# length) is sent as that to a client that takes gzip, as nginx's
# gzip_static does: compressed once, ahead of time, not per request.
sendvariant(io: ref Io, r: ref Req, path: string, fd: ref FD, d: Dir): (int, big, int)
{
	if(d.length == big 0 || len path > 3 && path[len path - 3:] == ".gz")
		return sendfile(io, r, path, fd, d, Plain);
	gfd := sys->open(path + ".gz", Sys->OREAD);
	if(gfd == nil)
		return sendfile(io, r, path, fd, d, Plain);
	(ok, gd) := sys->fstat(gfd);
	if(ok < 0 || (gd.mode & Sys->DMDIR) || gd.length == big 0)
		return sendfile(io, r, path, fd, d, Plain);
	if(acceptsgzip(r.acceptenc))
		return sendfile(io, r, path, gfd, gd, Gzip);
	return sendfile(io, r, path, fd, d, Varies);
}

# Accept-Encoding names gzip (or *) with a q that is not 0
acceptsgzip(h: string): int
{
	for(l := split(h, ','); l != nil; l = tl l) {
		(coding, params) := splitfirst(trimows(hd l), ';');
		coding = trimows(coding);
		if(coding != "gzip" && coding != "x-gzip" && coding != "*")
			continue;
		params = trimows(params);
		if(prefix(params, "q=")) {
			q := params[2:];
			zero := 1;
			for(i := 0; i < len q; i++)
				if(q[i] != '0' && q[i] != '.')
					zero = 0;
			if(zero)
				continue;
		}
		return 1;
	}
	return 0;
}

# A file read as Server-Sent Events (the client's Accept names
# text/event-stream, as a browser's EventSource sends): each read of
# the file is an event, its lines its data.  A device's event file
# (gpsfs's, themefs's) waits for a change before it answers, so there
# is no deadline on the file's reads, only on the writes; every 15
# seconds of silence a comment goes out, which keeps proxies from
# closing the stream and finds a client gone.  The file ending ends
# the stream (and an EventSource opens it again).
eventstream(io: ref Io, r: ref Req, fd: ref FD): (int, big, int)
{
	ok := chan[1] of int;
	streamc <-= (io.w, ok);
	if(<-ok == 0)
		return errorpage(io, r, 503, "Retry-After: 30\r\n");
	(code, n, keep) := eventstream0(io, r, fd);
	io.w.stream = 0;	# a kept connection that streamed once is not a stream now
	return (code, n, keep);
}

eventstream0(io: ref Io, r: ref Req, fd: ref FD): (int, big, int)
{
	hdr := "Content-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n";
	chunked := r.vers == 11;
	if(chunked)
		hdr += "Transfer-Encoding: chunked\r\n";
	else
		r.close = 1;
	(nil, nil, keep) := header(io, r, 200, hdr, big -2);
	if(r.meth == "HEAD")
		return (200, big 0, keep);
	if(io.flush() < 0)
		return (200, big 0, 0);

	c := chan of array of byte;
	io.w.orphans = 1;	# the reader may be in a read that never ends
	spawn eventreader(fd, c);
	sent := big 0;
	for(;;) {
		io.w.deadline = 0;	# a file may wait as long as it likes
		beat := chan[1] of int;
		spawn sleeper(BEATWAIT, beat);
		ev: string;
		alt {
		b := <-c =>
			if(b == nil) {
				io.w.orphans = 0;	# the reader saw the end, and has gone
				if(chunked) {
					io.puts("0\r\n\r\n");
					return (200, sent, keep);
				}
				return (200, sent, 0);
			}
			ev = sseevent(b);
		<-beat =>
			ev = ": keep-alive\n\n";
		}
		eb := array of byte ev;
		if(chunked)
			io.puts(sys->sprint("%x\r\n", len eb));
		io.put(eb);
		if(chunked)
			io.puts("\r\n");
		if(io.flush() < 0)
			return (200, sent, 0);
		sent += big len eb;
	}
}

eventreader(fd: ref FD, c: chan of array of byte)
{
	buf := array[BUFSIZE] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0) {
			c <-= nil;
			return;
		}
		b := array[n] of byte;
		b[0:] = buf[0:n];
		c <-= b;
	}
}

sleeper(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

# One read's bytes as an event: each line a data: line, CRs dropped
# (a CR is a line break to an EventSource), one final newline not a line
sseevent(b: array of byte): string
{
	nb := array[len b] of byte;
	n := 0;
	for(i := 0; i < len b; i++)
		if(b[i] != byte '\r')
			nb[n++] = b[i];
	s := string nb[0:n];	# as UTF-8 (they were taken as Latin-1, and sent twice encoded)
	if(s == nil)
		return "data:\n\n";
	if(s[len s - 1] == '\n')
		s = s[0:len s - 1];
	ev := "";
	for(l := split(s, '\n'); l != nil; l = tl l)
		ev += "data: " + hd l + "\n";
	return ev + "\n";
}

openerror(io: ref Io, r: ref Req): (int, big, int)
{
	e := sys->sprint("%r");
	if(contains(e, "permission"))
		return errorpage(io, r, 403, nil);
	return errorpage(io, r, 404, nil);
}

Plain, Gzip, Varies: con iota;	# the file as it is; its compressed copy; as it is, a compressed copy beside it

sendfile(io: ref Io, r: ref Req, path: string, fd: ref FD, d: Dir, enc: int): (int, big, int)
{
	ctype := contenttype(path);
	hdr := "Content-Type: " + ctype + "\r\nX-Content-Type-Options: nosniff\r\n";
	if(enc == Gzip)
		hdr += "Content-Encoding: gzip\r\n";
	if(enc != Plain)
		hdr += "Vary: Accept-Encoding\r\n";

	# a file whose length its server does not know (0: a device's
	# status, a log) is read to its end, and not cached
	if(d.length == big 0)
		return sendstream(io, r, fd, hdr + "Cache-Control: no-store\r\n");

	etag := sys->sprint("\"%bx-%ux-%ux\"", d.qid.path, d.qid.vers, d.mtime);
	hdr += "ETag: " + etag + "\r\nAccept-Ranges: bytes\r\n";
	if(d.mtime > 0)
		hdr += "Last-Modified: " + httpdate(d.mtime) + "\r\n";
	# -C: files other than pages kept by the browser for a while; a
	# page is asked about each time (its ETag answers 304), so a
	# changed site is seen at once and its assets can be renamed
	if(maxage > 0 && !prefix(ctype, "text/html"))
		hdr += sys->sprint("Cache-Control: max-age=%d\r\n", maxage);

	# RFC 9110 §13.2.2: If-None-Match decides, else If-Modified-Since
	if(r.ifnonematch != nil) {
		if(etagmatch(r.ifnonematch, etag))
			return header(io, r, 304, hdr, big -1);
	} else if(r.ifmodsince != nil && d.mtime > 0) {
		t := parsedate(r.ifmodsince);
		if(t > 0 && d.mtime <= t)
			return header(io, r, 304, hdr, big -1);
	}

	off := big 0;
	n := d.length;
	code := 200;
	if(r.rng != nil && (r.ifrange == nil || r.ifrange == etag)) {
		(ok, a, b) := parserange(r.rng, d.length);
		if(ok < 0)
			return errorpage(io, r, 416, sys->sprint("Content-Range: bytes */%bd\r\n", d.length));
		if(ok > 0) {
			code = 206;
			off = a;
			n = b - a + big 1;
			hdr += sys->sprint("Content-Range: bytes %bd-%bd/%bd\r\n", a, b, d.length);
		}
	}
	(nil, nil, keep) := header(io, r, code, hdr, n);
	if(r.meth == "HEAD")
		return (code, big 0, keep);
	buf := array[BUFSIZE] of byte;
	sent := big 0;
	while(sent < n) {
		m := BUFSIZE;
		if(big m > n - sent)
			m = int (n - sent);
		io.deadline(IOWAIT);
		k := sys->pread(fd, buf, m, off + sent);
		if(k <= 0)
			return (code, sent, 0);	# shorter than it said: the client sees the connection end
		if(io.put(buf[0:k]) < 0)
			return (code, sent, 0);
		sent += big k;
	}
	return (code, sent, keep);
}

# A body of a length not known: chunked under HTTP/1.1, to the
# connection's end under 1.0.  A file that is empty is said to be.
sendstream(io: ref Io, r: ref Req, fd: ref FD, hdr: string): (int, big, int)
{
	buf := array[BUFSIZE] of byte;
	io.deadline(IOWAIT);
	k := sys->read(fd, buf, len buf);
	if(k <= 0) {
		(nil, nil, keep) := header(io, r, 200, hdr, big 0);
		return (200, big 0, keep);
	}
	if(r.meth == "HEAD") {
		if(r.vers == 10)
			r.close = 1;
		else
			hdr += "Transfer-Encoding: chunked\r\n";
		(nil, nil, keep) := header(io, r, 200, hdr, big -2);
		return (200, big 0, keep);
	}
	chunked := r.vers == 11;
	if(chunked)
		hdr += "Transfer-Encoding: chunked\r\n";
	else
		r.close = 1;
	(nil, nil, keep) := header(io, r, 200, hdr, big -2);
	sent := big 0;
	while(k > 0) {
		if(chunked)
			io.puts(sys->sprint("%x\r\n", k));
		if(io.put(buf[0:k]) < 0)
			return (200, sent, 0);
		if(chunked)
			io.puts("\r\n");
		sent += big k;
		if(io.flush() < 0)
			return (200, sent, 0);
		io.deadline(IOWAIT);
		k = sys->read(fd, buf, len buf);
	}
	if(k < 0)
		return (200, sent, 0);	# cut short: no last chunk, so the client knows
	if(chunked)
		io.puts("0\r\n\r\n");
	return (200, sent, keep);
}

listing(io: ref Io, r: ref Req, path: string, fd: ref FD): (int, big, int)
{
	names: list of string;
	count := 0;
	for(;;) {
		io.deadline(IOWAIT);
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n && count < 10000; i++) {
			if(d[i].name == nil || d[i].name[0] == '.')
				continue;
			nm := d[i].name;
			if(protection() && !mayshow(io, r, path + nm, d[i]))
				continue;	# not one this client may have: not named either
			if(d[i].mode & Sys->DMDIR)
				nm += "/";
			names = nm :: names;
			count++;
		}
	}
	names = sort(names);
	t := htmlescape(path);
	s := "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" + t + "</title></head>\n<body><h1>" + t + "</h1>\n<ul>\n";
	if(path != "/")
		s += "<li><a href=\"../\">../</a></li>\n";
	for(; names != nil; names = tl names)
		s += "<li><a href=\"" + urlpath(hd names) + "\">" + htmlescape(hd names) + "</a></li>\n";
	s += "</ul>\n</body></html>\n";
	return page(io, r, 200, "Cache-Control: no-store\r\n", s);
}

# POST: to a path named by -p, the body written to the file; to
# /magic/wikipost with -w, wikifs's edit form.  Either only from a
# page of this site (RFC 6454's Origin, or Fetch's Sec-Fetch-Site).
post(io: ref Io, r: ref Req): (int, big, int)
{
	wiki := wikibase != nil && r.path == "/magic/wikipost";
	if(!wiki && !member(posts, r.path))
		return errorpage(io, r, 405, nil);
	if(!sameorigin(r))
		return errorpage(io, r, 403, nil);
	if(r.clen < big 0)
		return errorpage(io, r, 411, nil);
	if(r.clen > big maxbody)
		return errorpage(io, r, 413, nil);
	if(r.expect != nil) {
		if(r.expect != "100-continue")
			return errorpage(io, r, 417, nil);
		if(r.vers == 11) {
			io.puts("HTTP/1.1 100 Continue\r\n\r\n");
			if(io.flush() < 0)
				return (100, big 0, 0);
		}
	}
	body := io.read(int r.clen);
	if(body == nil && r.clen > big 0)
		return (400, big 0, 0);
	r.clen = big 0;	# read: what follows on the connection is the next request
	if(wiki)
		return wikipost(io, r, body);

	io.deadline(IOWAIT);
	# the body replaces what the file held, as the shell's > does; a
	# device's ctl file that will not be truncated is written as it is
	fd := sys->open(r.path, Sys->ORDWR|Sys->OTRUNC);
	if(fd == nil)
		fd = sys->open(r.path, Sys->ORDWR);
	readable := fd != nil;
	if(fd == nil)
		fd = sys->open(r.path, Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil)
		fd = sys->open(r.path, Sys->OWRITE);
	if(fd == nil)
		return openerror(io, r);
	if(sys->write(fd, body, len body) != len body)
		return page(io, r, 422, nil, sys->sprint("%r\n"));
	if(readable) {
		# what the file says back (a ctl file's answer), if anything
		sys->seek(fd, big 0, Sys->SEEKSTART);
		buf := array[65536] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			return reply(io, r, 200, "Content-Type: text/plain; charset=utf-8\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\n", buf[0:n]);
	}
	return header(io, r, 204, "Cache-Control: no-store\r\n", big -1);
}

# wikifs(4)'s new file takes a page as the old /magic/wikipost wrote it:
# title, D<version>, A<author>, C<comment>, an empty line, the text;
# then an empty write commits it, and a read gives the page's name.
wikipost(io: ref Io, r: ref Req, body: array of byte): (int, big, int)
{
	if(r.ctype == nil || !prefix(r.ctype, "application/x-www-form-urlencoded"))
		return errorpage(io, r, 415, nil);
	(form, ferr) := parseform(string body);
	if(ferr != nil)
		return errorpage(io, r, 400, nil);
	title := oneline(lookup(form, "title"));
	author := oneline(lookup(form, "author"));
	comment := oneline(lookup(form, "comment"));
	version := decimal(lookup(form, "version"));
	text := lookup(form, "text");
	if(title == nil || version < big 0 || version > big 16rFFFFFFFF)
		return errorpage(io, r, 400, nil);
	# the form's own "base" is not trusted: it would send the
	# browser where it says
	text = crlf2lf(text);

	io.deadline(IOWAIT);
	fd := sys->open(wikibase + "/new", Sys->ORDWR);
	if(fd == nil)
		return errorpage(io, r, 503, nil);
	m := title + "\nD" + string version + "\nA" + author + "\n";
	if(comment != nil)
		m += "C" + comment + "\n";
	m += "\n" + text;
	b := array of byte m;
	if(sys->write(fd, b, len b) != len b || sys->write(fd, b, 0) != 0)
		return page(io, r, 422, nil, sys->sprint("%r\n"));
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return errorpage(io, r, 500, nil);
	name := string buf[0:n];
	if(hasbyte(name, '/') || name == "." || name == "..")
		return errorpage(io, r, 500, nil);
	# 303: the browser GETs the page it changed
	return errorpage(io, r, 303, "Location: " + urlpath(wikibase + "/" + name + "/index.html") + "\r\n");
}

sameorigin(r: ref Req): int
{
	if(r.origin != nil) {
		if(r.host == nil)
			return 0;
		scheme := "http://";
		if(scfg != nil)
			scheme = "https://";
		return r.origin == scheme + r.host;
	}
	if(r.fetchsite != nil)
		return r.fetchsite == "same-origin" || r.fetchsite == "none";
	return 1;	# not a browser: curl, a script
}

# The status line and headers; n is the body's length (-1: none,
# -2: not known, for chunked or to the end).  (status, 0, keep)
header(io: ref Io, r: ref Req, code: int, hdr: string, n: big): (int, big, int)
{
	keep := !r.close;
	s := sys->sprint("HTTP/1.1 %d %s\r\nDate: %s\r\nServer: InferNode\r\n", code, reason(code), httpdate(now()));
	if(hsts)
		s += sys->sprint("Strict-Transport-Security: max-age=%d\r\n", hsts);
	s += hdr;
	if(n >= big 0)
		s += sys->sprint("Content-Length: %bd\r\n", n);
	else if(n == big -1 && code != 304 && code != 204 && code != 100)
		s += "Content-Length: 0\r\n";
	if(!keep)
		s += "Connection: close\r\n";
	else if(r.vers == 10)
		s += "Connection: keep-alive\r\n";
	s += "\r\n";
	io.puts(s);
	return (code, big 0, keep);
}

reply(io: ref Io, r: ref Req, code: int, hdr: string, body: array of byte): (int, big, int)
{
	(nil, nil, keep) := header(io, r, code, hdr, big len body);
	if(r.meth == "HEAD")
		return (code, big 0, keep);
	if(io.put(body) < 0)
		return (code, big 0, 0);
	return (code, big len body, keep);
}

# A page of our own making: HTML that loads nothing and runs nothing
page(io: ref Io, r: ref Req, code: int, hdr: string, body: string): (int, big, int)
{
	ctype := "text/html; charset=utf-8";
	if(len body > 0 && body[0] != '<')
		ctype = "text/plain; charset=utf-8";
	return reply(io, r, code, hdr + "Content-Type: " + ctype + "\r\n" +
		"X-Content-Type-Options: nosniff\r\n" +
		"Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n", array of byte body);
}

errorpage(io: ref Io, r: ref Req, code: int, hdr: string): (int, big, int)
{
	if(code == 405)
		hdr += "Allow: GET, HEAD" + postallowed(r) + "\r\n";
	if(code >= 400 && code != 404 && code != 403 && code != 401 && code != 304)
		r.close = 1;
	if(r.clen > big 0)
		r.close = 1;	# a body not read: it is not the next request (a proxy in front would be out of step)
	t := sys->sprint("%d %s", code, reason(code));
	return page(io, r, code, hdr, "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" + t +
		"</title></head>\n<body><h1>" + t + "</h1></body></html>\n");
}

postallowed(r: ref Req): string
{
	if(r.path != nil && (member(posts, r.path) || wikibase != nil && r.path == "/magic/wikipost"))
		return ", POST";
	return "";
}

reason(code: int): string
{
	case code {
	100 =>	return "Continue";
	200 =>	return "OK";
	204 =>	return "No Content";
	206 =>	return "Partial Content";
	301 =>	return "Moved Permanently";
	303 =>	return "See Other";
	304 =>	return "Not Modified";
	400 =>	return "Bad Request";
	403 =>	return "Forbidden";
	404 =>	return "Not Found";
	405 =>	return "Method Not Allowed";
	411 =>	return "Length Required";
	413 =>	return "Content Too Large";
	414 =>	return "URI Too Long";
	415 =>	return "Unsupported Media Type";
	416 =>	return "Range Not Satisfiable";
	417 =>	return "Expectation Failed";
	422 =>	return "Unprocessable Content";
	429 =>	return "Too Many Requests";
	431 =>	return "Request Header Fields Too Large";
	500 =>	return "Internal Server Error";
	501 =>	return "Not Implemented";
	503 =>	return "Service Unavailable";
	505 =>	return "HTTP Version Not Supported";
	}
	return "Status";
}

# Common Log Format, with the referer and agent (Apache's "combined")
logreq(ip: string, r: ref Req, code: int, n: big)
{
	t := daytime->gmt(now());
	s := sys->sprint("%s - %s [%02d/%s/%d:%02d:%02d:%02d +0000] \"%s %s %s\" %d %bd \"%s\" \"%s\"\n",
		ip, logname(r.user), t.mday, months[t.mon], t.year + 1900, t.hour, t.min, t.sec,
		logesc(r.meth), logesc(r.target), vers(r.vers), code, n, logesc(r.referer), logesc(r.agent));
	logc <-= array of byte s;
}

# The log, opened to append
openlog(): ref FD
{
	fd := sys->open(logfile, Sys->OWRITE);
	if(fd == nil)
		fd = sys->create(logfile, Sys->OWRITE, Sys->DMAPPEND|8r644);
	if(fd != nil)
		sys->seek(fd, big 0, Sys->SEEKEND);
	return fd;
}

# The listener's side of the log: each connection's line written
# whole (none interleaved), and with -l the file rotated when it
# reaches -m bytes: log.M removed, log.i renamed log.i+1, log renamed
# log.1, a new log begun.  A device's storage then holds at most
# about (M+1) times -m of log, whatever the traffic.
logger()
{
	written := big 0;
	if(logfile != nil) {
		(ok, d) := sys->fstat(logfd);
		if(ok >= 0)
			written = d.length;
	}
	for(;;) {
		b := <-logc;
		if(logfd != nil)
			sys->write(logfd, b, len b);
		written += big len b;
		if(logfile != nil && logmax > big 0 && written >= logmax) {
			rotate();
			written = big 0;
		}
	}
}

rotate()
{
	logfd = nil;
	sys->remove(logfile + "." + string logold);
	for(i := logold - 1; i >= 1; i--)
		rename(logfile + "." + string i, logfile + "." + string (i + 1));
	if(rename(logfile, logfile + ".1") < 0) {
		# a file server that cannot rename: start the log again rather
		# than let it grow
		sys->fprint(stderr, "httpd: cannot rotate %s: %r; truncating it\n", logfile);
		logfd = sys->create(logfile, Sys->OWRITE|Sys->OTRUNC, Sys->DMAPPEND|8r644);
		return;
	}
	logfd = openlog();
	if(logfd == nil)
		sys->fprint(stderr, "httpd: cannot open %s after rotating it: %r\n", logfile);
}

rename(old, new: string): int
{
	(nil, name) := splitlast(new, '/');
	d := sys->nulldir;
	d.name = name;
	return sys->wstat(old, d);
}

# A size: digits, then k or m for kilobytes and megabytes; -1 if not one
size(s: string): big
{
	m := big 1;
	if(s != nil && (s[len s - 1] == 'k' || s[len s - 1] == 'K')) {
		m = big 1024;
		s = s[0:len s - 1];
	} else if(s != nil && (s[len s - 1] == 'm' || s[len s - 1] == 'M')) {
		m = big (1024*1024);
		s = s[0:len s - 1];
	}
	n := decimal(s);
	if(n < big 0)
		return big -1;
	return n * m;
}

vers(v: int): string
{
	if(v == 10)
		return "HTTP/1.0";
	return "HTTP/1.1";
}

# What a client sent, safe in a log line: no quotes, backslashes or
# control characters, at most 512 bytes
logesc(s: string): string
{
	if(s == nil)
		return "-";
	if(len s > 512)
		s = s[0:512] + "...";
	t := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < 16r20 || c == 16r7F || c == '"' || c == '\\' || c > 16rFF)
			t += sys->sprint("\\x%02x", c & 16rFF);
		else
			t[len t] = c;
	}
	return t;
}

# ================================================================
# Pieces
# ================================================================

now(): int
{
	if(timefd != nil) {
		b := array[32] of byte;
		n := sys->pread(timefd, b, len b, big 0);
		if(n > 0) {
			us := big string b[0:n];
			if(us > big 0)
				return int (us / big 1000000);
		}
	}
	return epoch0 + (sys->millisec() - ms0) / 1000;
}

days := array[] of {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
months := array[] of {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

# RFC 9110 §5.6.7's IMF-fixdate
httpdate(t: int): string
{
	tm := daytime->gmt(t);
	return sys->sprint("%s, %02d %s %d %02d:%02d:%02d GMT", days[tm.wday], tm.mday,
		months[tm.mon], tm.year + 1900, tm.hour, tm.min, tm.sec);
}

# An IMF-fixdate's time, or -1 (the obsolete forms are not taken)
parsedate(s: string): int
{
	f := tokens(s);
	if(len f != 6 || hd tl tl tl tl tl f != "gmt" && hd tl tl tl tl tl f != "GMT")
		return -1;
	f = tl f;
	mday := int hd f;
	f = tl f;
	mon := -1;
	for(i := 0; i < len months; i++)
		if(hd f == months[i])
			mon = i;
	f = tl f;
	year := int hd f;
	f = tl f;
	hms := split(hd f, ':');
	if(mon < 0 || mday < 1 || mday > 31 || year < 1970 || len hms != 3)
		return -1;
	tm := ref Tm(int hd tl tl hms, int hd tl hms, int hd hms, mday, mon, year - 1900, 0, 0, "GMT", 0);
	return daytime->tm2epoch(tm);
}

# A single range of a file of length len (RFC 9110 §14.1.2):
# (1, first, last), (0, ...) to send it whole (several ranges, or a
# form not taken), (-1, ...) if not satisfiable.
parserange(s: string, length: big): (int, big, big)
{
	if(!prefix(s, "bytes="))
		return (0, big 0, big 0);
	s = trimows(s[6:]);
	if(hasbyte(s, ','))
		return (0, big 0, big 0);
	(a, b) := splitfirst(s, '-');
	if(!hasbyte(s, '-'))
		return (0, big 0, big 0);
	if(a == nil) {
		n := decimal(b);
		if(n < big 0)
			return (0, big 0, big 0);
		if(n == big 0)
			return (-1, big 0, big 0);
		if(n > length)
			n = length;
		return (1, length - n, length - big 1);
	}
	first := decimal(a);
	if(first < big 0)
		return (0, big 0, big 0);
	last := length - big 1;
	if(b != nil) {
		last = decimal(b);
		if(last < big 0 || last < first)
			return (0, big 0, big 0);
		if(last >= length)
			last = length - big 1;
	}
	if(first >= length)
		return (-1, big 0, big 0);
	return (1, first, last);
}

etagmatch(header, etag: string): int
{
	if(trimows(header) == "*")
		return 1;
	for(l := split(header, ','); l != nil; l = tl l) {
		t := trimows(hd l);
		if(prefix(t, "W/"))
			t = t[2:];
		if(t == etag)
			return 1;
	}
	return 0;
}

contenttype(path: string): string
{
	(nil, ext) := splitlast(path, '.');
	case lower(ext) {
	"html" or "htm" =>	return "text/html; charset=utf-8";
	"css" =>	return "text/css; charset=utf-8";
	"js" or "mjs" =>	return "text/javascript; charset=utf-8";
	"json" =>	return "application/json";
	"txt" or "b" or "m" or "c" or "h" or "sh" =>	return "text/plain; charset=utf-8";
	"md" =>	return "text/markdown; charset=utf-8";
	"csv" =>	return "text/csv; charset=utf-8";
	"xml" =>	return "application/xml";
	"svg" =>	return "image/svg+xml";
	"png" =>	return "image/png";
	"jpg" or "jpeg" =>	return "image/jpeg";
	"gif" =>	return "image/gif";
	"webp" =>	return "image/webp";
	"ico" =>	return "image/vnd.microsoft.icon";
	"pdf" =>	return "application/pdf";
	"wasm" =>	return "application/wasm";
	"mp4" =>	return "video/mp4";
	"webm" =>	return "video/webm";
	"mp3" =>	return "audio/mpeg";
	"ogg" =>	return "audio/ogg";
	"wav" =>	return "audio/wav";
	"woff" =>	return "font/woff";
	"woff2" =>	return "font/woff2";
	"ttf" =>	return "font/ttf";
	"otf" =>	return "font/otf";
	"zip" =>	return "application/zip";
	"gz" =>	return "application/gzip";
	"tar" =>	return "application/x-tar";
	}
	return "application/octet-stream";
}

# A path as it goes in a URL: what is not unreserved or '/' encoded
urlpath(p: string): string
{
	b := array of byte p;
	s := "";
	for(i := 0; i < len b; i++) {
		c := int b[i];
		if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		   c == '-' || c == '.' || c == '_' || c == '~' || c == '/')
			s[len s] = c;
		else
			s += sys->sprint("%%%02X", c);
	}
	return s;
}

# A query as it came, if it holds only what a query may (RFC 3986)
queryclean(q: string): string
{
	for(i := 0; i < len q; i++) {
		c := q[i];
		if(c <= 16r20 || c >= 16r7F || c == '"' || c == '<' || c == '>' || c == '\\')
			return "";
	}
	return q;
}

htmlescape(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'&' =>	t += "&amp;";
		'<' =>	t += "&lt;";
		'>' =>	t += "&gt;";
		'"' =>	t += "&quot;";
		'\'' =>	t += "&#39;";
		* =>	t[len t] = s[i];
		}
	return t;
}

# application/x-www-form-urlencoded
parseform(s: string): (list of (string, string), string)
{
	form: list of (string, string);
	for(l := split(s, '&'); l != nil; l = tl l) {
		if(hd l == "")
			continue;
		(k, v) := splitfirst(hd l, '=');
		(dk, e1) := formdecode(k);
		(dv, e2) := formdecode(v);
		if(e1 != nil || e2 != nil)
			return (nil, "bad encoding");
		form = (dk, dv) :: form;
	}
	return (form, nil);
}

formdecode(s: string): (string, string)
{
	b := array[len s] of byte;
	n := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '+')
			c = ' ';
		else if(c == '%') {
			if(i + 2 >= len s || hexdigit(s[i+1]) < 0 || hexdigit(s[i+2]) < 0)
				return (nil, "bad");
			c = (hexdigit(s[i+1]) << 4) | hexdigit(s[i+2]);
			i += 2;
		}
		if(c == 0)
			return (nil, "NUL");
		b[n++] = byte c;
	}
	return (string b[0:n], nil);
}

lookup(form: list of (string, string), k: string): string
{
	for(; form != nil; form = tl form)
		if((hd form).t0 == k)
			return (hd form).t1;
	return nil;
}

# a field that must stay on its line in wikifs's format
oneline(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '\n' || c == '\r' || c < 16r20)
			c = ' ';
		t[len t] = c;
	}
	return t;
}

crlf2lf(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++)
		if(!(s[i] == '\r' && i + 1 < len s && s[i+1] == '\n'))
			t[len t] = s[i];
	return t;
}

# host or host:port, a name, IPv4 or [IPv6]
hostport(s: string): int
{
	if(s == nil || len s > 300)
		return 0;
	(h, port) := splithostport(s);
	if(port != nil && (posint(port) <= 0 || posint(port) > 65535))
		return 0;
	if(h == nil)
		return 0;
	if(h[0] == '[') {
		for(i := 1; i < len h - 1; i++)
			if(hexdigit(h[i]) < 0 && h[i] != ':' && h[i] != '.')
				return 0;
		return h[len h - 1] == ']';
	}
	for(i := 0; i < len h; i++) {
		c := h[i];
		if(!(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == '_'))
			return 0;
	}
	return 1;
}

splithostport(s: string): (string, string)
{
	if(s != nil && s[0] == '[') {
		for(i := 0; i < len s; i++)
			if(s[i] == ']') {
				if(i + 1 < len s) {
					if(s[i+1] != ':')
						return (nil, nil);
					return (s[0:i+1], s[i+2:]);
				}
				return (s, nil);
			}
		return (nil, nil);
	}
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == ':')
			return (s[0:i], s[i+1:]);
	return (s, nil);
}

dotfile(path: string): int
{
	for(l := split(path, '/'); l != nil; l = tl l)
		if(hd l != nil && (hd l)[0] == '.')
			return 1;
	return 0;
}

stripslash(p: string): string
{
	if(len p > 1 && p[len p - 1] == '/')
		return p[0:len p - 1];
	return p;
}

# RFC 9110's token
token(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		     c == '!' || c == '#' || c == '$' || c == '%' || c == '&' || c == '\'' || c == '*' ||
		     c == '+' || c == '-' || c == '.' || c == '^' || c == '_' || c == '`' || c == '|' || c == '~'))
			return 0;
	}
	return 1;
}

# A decimal of at most 18 digits, or -1
decimal(s: string): big
{
	if(s == nil || len s > 18)
		return big -1;
	n := big 0;
	for(i := 0; i < len s; i++) {
		if(s[i] < '0' || s[i] > '9')
			return big -1;
		n = n * big 10 + big (s[i] - '0');
	}
	return n;
}

posint(s: string): int
{
	n := decimal(s);
	if(n < big 0 || n > big 16r7FFFFFFF)
		return -1;
	return int n;
}

hexdigit(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

lower(s: string): string
{
	t := s;
	for(i := 0; i < len t; i++)
		if(t[i] >= 'A' && t[i] <= 'Z')
			t[i] += 'a' - 'A';
	return t;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

hasbyte(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

member(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

# (before c, after c), the first c; (s, nil) if none
splitfirst(s: string, c: int): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return (s[0:i], s[i+1:]);
	return (s, nil);
}

# (before c, c and after), the first c
splitbefore(s: string, c: int): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return (s[0:i], s[i:]);
	return (s, nil);
}

splitlast(s: string, c: int): (string, string)
{
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == c)
			return (s[0:i], s[i+1:]);
	return (s, nil);
}

split(s: string, c: int): list of string
{
	l: list of string;
	j := len s;
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == c) {
			l = s[i+1:j] :: l;
			j = i;
		}
	return s[0:j] :: l;
}

tokens(s: string): list of string
{
	(nil, l) := sys->tokenize(s, " \t,");
	return l;
}

trim(s: string): string
{
	while(s != nil && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

trimows(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t'))
		j--;
	return s[i:j];
}

sort(l: list of string): list of string
{
	a := array[len l] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	for(i = 1; i < len a; i++) {
		s := a[i];
		for(j := i; j > 0 && a[j-1] > s; j--)
			a[j] = a[j-1];
		a[j] = s;
	}
	r: list of string;
	for(i = len a - 1; i >= 0; i--)
		r = a[i] :: r;
	return r;
}

readfile(f: string, max: int): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[max] of byte;
	n := 0;
	while(n < max) {
		m := sys->read(fd, b[n:], max - n);
		if(m <= 0)
			break;
		n += m;
	}
	return string b[0:n];
}

writefile(f, s: string)
{
	fd := sys->open(f, Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "httpd: %s\n", s);
	raise "fail:" + s;
}

# ================================================================
# Who may (-A, -P, -x)
# ================================================================

logname(s: string): string
{
	if(s == nil)
		return "-";
	t := "";
	for(i := 0; i < len s && i < 64; i++) {
		c := s[i];
		if(c <= 16r20 || c == 16r7F || c == '"' || c == '\\' || c > 16r7E)
			c = '_';
		t[len t] = c;
	}
	return t;
}

# The rule for a path, by name: the deepest rule that is the path or a
# directory of it, a rule for the method before one for both, paths in
# lower case; nil if none (refused, with -x).
#
# And the rules it must meet as well, by identity: a host that takes
# /ADMIN, /ADMINI~1 or a folded /admın for /admin (macOS's APFS) opens
# the same directory whatever the name, so each directory on the
# request's way is stat'ed and a protecting rule whose path had that
# identity (qid, dtype, dev) when httpd started applies too.  Identity
# only ever adds a rule to meet, never takes one away: an identity
# shared by accident (an inode used again after a delete, a server's
# small qids) can protect too much, not too little.
findrules(path, meth: string, ident: int): (ref Rule, list of ref Rule)
{
	if(meth == "HEAD")
		meth = "GET";
	lp := lower(path);
	best: ref Rule;
	for(l := rules; l != nil; l = tl l) {
		ru := hd l;
		if(ru.meth != nil && ru.meth != meth)
			continue;
		if(under(lp, ru.prefix))
			best = better(best, ru);
	}
	if(!ident || maxresolved == 0)
		return (best, nil);
	extra: list of ref Rule;
	p := "";
	depth := 0;
	for(sl := split(path, '/'); sl != nil && depth < maxresolved; sl = tl sl) {
		if(hd sl == "")
			continue;
		p += "/" + hd sl;
		depth++;
		(ok, d) := sys->stat(p);
		if(ok < 0)
			break;
		extra = identityrules(d, meth, extra);
	}
	return (best, extra);
}

# The protecting rules (for meth) whose path had d's identity
identityrules(d: Dir, meth: string, extra: list of ref Rule): list of ref Rule
{
	for(l := rules; l != nil; l = tl l) {
		ru := hd l;
		if(!ru.resolved || !protects(ru.terms) || ru.meth != nil && ru.meth != meth)
			continue;
		if(ru.qpath == d.qid.path && ru.dtype == d.dtype && ru.dev == d.dev)
			extra = ru :: extra;
	}
	return extra;
}

better(best, ru: ref Rule): ref Rule
{
	if(best == nil || ru.depth > best.depth ||
	   ru.depth == best.depth && ru.meth != nil && best.meth == nil)
		return ru;
	return best;
}

# path is prefix, or below it: /admin is not /administrator
under(path, p: string): int
{
	if(p == "/")
		return 1;
	if(!prefix(path, p))
		return 0;
	return len path == len p || path[len p] == '/';
}

# Without -x: with -P every request needs a password (or a client
# certificate); with -A a POST needs a client certificate
defaultterms(meth: string): list of ref Term
{
	t: list of ref Term;
	if(meth == "POST") {
		if(trustfile != nil)
			return ref Term(Cert, nil) :: nil;
		if(pwfile != nil)
			return ref Term(Password, nil) :: nil;
		return ref Term(Anyone, nil) :: nil;
	}
	if(pwfile != nil) {
		t = ref Term(Password, nil) :: t;
		if(trustfile != nil)
			t = ref Term(Cert, nil) :: t;
		return t;
	}
	return ref Term(Anyone, nil) :: nil;
}

protection(): int
{
	return trustfile != nil || pwfile != nil || rulesprotect;
}

# (0, nil) to go on; else the status to refuse with, and its headers.
# Every path the request may be answered from is authorised, each as
# strictly as its own rule says: the path, a compressed copy's original
# (name.gz is the file name's, whatever a rule says of name.gz), a
# directory's index.html, and for the wiki's form the wiki's own
# new file, which it writes.
authorise(io: ref Io, r: ref Req): (int, string)
{
	# with anything protected, a name a Windows host might take for
	# another's (ADMIN~1, an 8.3 name) is refused whatever its rule
	if(protection() && shortname(r.path))
		return (400, nil);
	# a Windows host folds the case of letters past ASCII (ı is I, ſ
	# is S) and the emulator's identity for a file there is a hash of
	# its name: a path not ASCII cannot be matched to its rule, and
	# is refused while anything is protected
	if(protection() && ntfs && !ascii(r.path))
		return (400, nil);
	paths := r.path :: nil;
	if(len r.path > 3 && r.path[len r.path - 3:] == ".gz")
		paths = r.path[0:len r.path - 3] :: paths;
	if(r.path[len r.path - 1] == '/')
		paths = r.path + "index.html" :: paths;
	meths := r.meth :: nil;
	if(wikibase != nil && r.path == "/magic/wikipost") {
		paths = wikibase + "/new" :: wikibase :: paths;
		meths = "POST" :: nil;
	}
	for(; paths != nil; paths = tl paths) {
		(code, hdr) := authorise1(io, r, hd paths, hd meths);
		if(code != 0)
			return (code, hdr);
	}
	return (0, nil);
}

authorise1(io: ref Io, r: ref Req, path, meth: string): (int, string)
{
	if(rulesfile == nil)
		return termsok(io, r, defaultterms(meth));
	(ru, extra) := findrules(path, meth, 1);
	if(ru == nil)
		return (403, nil);	# no rule names it: refused
	(code, hdr) := termsok(io, r, ru.terms);
	for(; extra != nil && code == 0; extra = tl extra)
		if(hd extra != ru)
			(code, hdr) = termsok(io, r, (hd extra).terms);
	return (code, hdr);
}

# a term t a certificate meets: a name is a CN, or a fingerprint if it
# says sha256:, never either (a CN of "sha256:..." is no fingerprint)
certmeets(io: ref Io, t: ref Term): int
{
	if(io.fp == nil)
		return 0;
	if(t.name == nil)
		return 1;
	if(prefix(t.name, "sha256:"))
		return t.name == io.fp;
	return t.name == io.cn;
}

# (0, nil) if the request meets one of terms; else the refusal
termsok(io: ref Io, r: ref Req, terms: list of ref Term): (int, string)
{
	wantpw := 0;
	for(l := terms; l != nil; l = tl l) {
		t := hd l;
		case t.kind {
		Anyone =>
			return (0, nil);
		Cert =>
			if(certmeets(io, t)) {
				if(r.user == nil)
					r.user = "cert:" + io.cn;
				return (0, nil);
			}
		Password =>
			wantpw = 1;
		}
	}
	if(!wantpw)
		return (403, nil);

	challenge := "WWW-Authenticate: Basic realm=\"" + realm + "\", charset=\"UTF-8\"\r\n";
	if(r.auth == nil)
		return (401, challenge);
	(user, pass) := basicauth(r.auth);
	if(user == nil)
		return (401, challenge);
	# the answer's channel holds it: a connection killed while its
	# password is checked must not leave the authenticator waiting to
	# tell it (every later login would wait for ever)
	rc := chan[1] of int;
	io.deadline(IOWAIT);
	authc <-= (user, pass, io.w.ip, rc);
	case <-rc {
	Locked =>
		return (429, "Retry-After: 600\r\n");
	Bad =>
		return (401, challenge);
	}
	for(l = terms; l != nil; l = tl l)
		if((hd l).kind == Password && ((hd l).name == nil || (hd l).name == user)) {
			if(r.user == nil || prefix(r.user, "cert:"))
				r.user = user;
			return (0, nil);
		}
	return (403, nil);	# the right password, but not a user this path names
}

# Whether a listing shows an entry: not one the requester could not
# have, by what it has already shown (its certificate, or the user its
# password was found to be), under the entry's rule by name and, by
# identity, the entry's own Dir (no further stat: a listing of 10000
# names costs none)
mayshow(io: ref Io, r: ref Req, path: string, d: Dir): int
{
	if(rulesfile == nil)
		return termsmet(io, r, defaultterms(r.meth));
	(ru, nil) := findrules(path, r.meth, 0);
	if(ru == nil || !termsmet(io, r, ru.terms))
		return 0;
	if(maxresolved == 0)
		return 1;
	for(l := identityrules(d, r.meth, nil); l != nil; l = tl l)
		if(!termsmet(io, r, (hd l).terms))
			return 0;
	return 1;
}

termsmet(io: ref Io, r: ref Req, terms: list of ref Term): int
{
	for(; terms != nil; terms = tl terms) {
		t := hd terms;
		case t.kind {
		Anyone =>
			return 1;
		Cert =>
			if(certmeets(io, t))
				return 1;
		Password =>
			if(r.user != nil && !prefix(r.user, "cert:") && (t.name == nil || t.name == r.user))
				return 1;
		}
	}
	return 0;
}

protects(terms: list of ref Term): int
{
	for(; terms != nil; terms = tl terms)
		if((hd terms).kind == Anyone)
			return 0;
	return 1;
}

# a segment such as ADMIN~1 (a Windows volume's 8.3 alias)
shortname(path: string): int
{
	for(i := 0; i + 1 < len path; i++)
		if(path[i] == '~' && path[i+1] >= '0' && path[i+1] <= '9')
			return 1;
	return 0;
}

# Authorization: Basic base64(user:password), strictly: (user, password) or nil
basicauth(h: string): (string, string)
{
	(scheme, rest) := splitfirst(trimows(h), ' ');
	if(lower(scheme) != "basic")
		return (nil, nil);
	rest = trimows(rest);
	if(rest == nil || len rest > 1024)
		return (nil, nil);
	for(i := 0; i < len rest; i++) {
		c := rest[i];
		if(!(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/' || c == '='))
			return (nil, nil);
	}
	b := base64->dec(rest);
	if(b == nil)
		return (nil, nil);
	s := string b;
	if(len array of byte s != len b)
		return (nil, nil);	# not UTF-8
	(user, pass) := splitfirst(s, ':');
	if(user == nil || len user > 64 || !hasbyte(s, ':') || len b > 512)
		return (nil, nil);
	for(i = 0; i < len s; i++)
		if(s[i] < 16r20 || s[i] == 16r7F)
			return (nil, nil);
	return (user, pass);
}

loadtrust()
{
	text := readfile(trustfile, 1<<20);
	if(text == nil)
		fatal(sys->sprint("cannot read %s: %r", trustfile));
	roots := tls->pemblocks(text, "CERTIFICATE");
	crls := tls->pemblocks(text, "X509 CRL");
	if(roots == nil)
		fatal(trustfile + ": no PEM CA certificate");
	# the roots and CRLs as a handshake will take them, now: a CRL no
	# root signed would refuse every client
	x := load X509 X509->PATH;
	if(x == nil || x->init() != nil)
		fatal(sys->sprint("cannot load %s: %r", X509->PATH));
	for(l := roots; l != nil; l = tl l) {
		(ok, err) := x->verify_certchain_roots(hd l :: nil, roots, crls, now());
		if(!ok)
			fatal(trustfile + ": " + err);
	}
	scfg.clientroots = roots;
	scfg.clientcrls = crls;
	scfg.clientneed = 0;	# asked for; each path says whether it needs one
	scfg.clock = timefd;
}

# -x: a line is [GET|POST] path term..., a term none, password,
# password=user, cert, cert=CN or cert=sha256:hex; or realm name...
loadrules()
{
	text := readfile(rulesfile, 1<<20);
	if(text == nil)
		fatal(sys->sprint("cannot read %s: %r", rulesfile));
	n := 0;
	rev: list of ref Rule;
	for(ls := split(text, '\n'); ls != nil; ls = tl ls) {
		n++;
		line := hd ls;
		(line, nil) = splitfirst(line, '#');
		(nil, f) := sys->tokenize(line, " \t\r");
		if(f == nil)
			continue;
		where := sys->sprint("%s:%d: ", rulesfile, n);
		if(hd f == "realm") {
			realm = "";
			for(f = tl f; f != nil; f = tl f) {
				if(realm != "")
					realm += " ";
				realm += hd f;
			}
			for(i := 0; i < len realm; i++)
				if(realm[i] == '"' || realm[i] == '\\' || realm[i] < 16r20 || realm[i] > 16r7E)
					fatal(where + "a realm of printable ASCII, no quote or backslash");
			continue;
		}
		ru := ref Rule;
		if(hd f == "GET" || hd f == "POST") {
			ru.meth = hd f;
			f = tl f;
		}
		if(f == nil)
			fatal(where + "no path");
		ru.orig = cleanpath(hd f);
		if(hd f == "/")
			ru.orig = "/";
		if(ru.orig == nil)
			fatal(where + "not a path: " + hd f);
		ru.prefix = lower(ru.orig);
		for(i := 0; i < len ru.orig; i++)
			if(ru.orig[i] == '/' && ru.orig != "/")
				ru.depth++;
		for(f = tl f; f != nil; f = tl f) {
			(k, v) := splitfirst(hd f, '=');
			if(hasbyte(hd f, '=') && v == nil)
				fatal(where + "nothing after = in " + hd f);
			case k {
			"none" =>
				if(v != nil)
					fatal(where + "none names no one");
				ru.terms = ref Term(Anyone, nil) :: ru.terms;
			"password" =>
				ru.terms = ref Term(Password, v) :: ru.terms;
			"cert" =>
				if(prefix(v, "sha256:"))
					v = lower(v);
				ru.terms = ref Term(Cert, v) :: ru.terms;
			* =>
				fatal(where + "not a term: " + hd f);
			}
		}
		if(ru.terms == nil)
			fatal(where + "no terms: say none, password or cert");
		if(!protects(ru.terms) && tl ru.terms != nil)
			fatal(where + "none with other terms: say one or the other");
		if(protects(ru.terms))
			rulesprotect = 1;
		# its identity, while httpd can see the site whole
		if(ru.orig != "/") {
			(ok, d) := sys->stat(root + ru.orig);
			if(ok >= 0) {
				ru.resolved = 1;
				ru.qpath = d.qid.path;
				ru.dtype = d.dtype;
				ru.dev = d.dev;
				if(protects(ru.terms) && ru.depth > maxresolved)
					maxresolved = ru.depth;
			}
		}
		rev = ru :: rev;
	}
	rules = rev;
}

# ---------------------------------------------------------------- passwords

User: adt {
	name:	string;
	iters:	int;
	salt:	array of byte;
	hash:	array of byte;
};

users: list of ref User;
pwqid: Sys->Qid;
pwmtime := -1;

DEFITERS: con 100000;
WINDOW: con 600;	# seconds a source's failures are counted, and it is refused for after ten
MAXFAIL: con 10;
CACHETIME: con 300;	# seconds a checked password is taken again without its hash

# user:pbkdf2-sha256:iterations:salt:hash, the last two base64
loadpasswords(): list of ref User
{
	(ok, d) := sys->stat(pwfile);
	if(ok < 0) {
		sys->fprint(stderr, "httpd: cannot stat %s: %r\n", pwfile);
		return users;
	}
	text := readfile(pwfile, 1<<20);
	if(text == nil)
		return users;
	nu: list of ref User;
	n := 0;
	for(ls := split(text, '\n'); ls != nil; ls = tl ls) {
		n++;
		line := trim(hd ls);
		if(line == nil || line[0] == '#')
			continue;
		f := split(line, ':');
		u: ref User;
		if(len f == 5 && hd tl f == "pbkdf2-sha256") {
			name := hd f;
			f = tl tl f;
			it := posint(hd f);
			salt := base64->dec(hd tl f);
			hash := base64->dec(hd tl tl f);
			if(name != nil && it >= 1000 && salt != nil && len salt >= 8 && hash != nil && len hash == Keyring->SHA256dlen)
				u = ref User(name, it, salt, hash);
		}
		if(u == nil) {
			sys->fprint(stderr, "httpd: %s:%d: not a password line, left out\n", pwfile, n);
			continue;
		}
		nu = u :: nu;
	}
	users = nu;
	pwqid = d.qid;
	pwmtime = d.mtime;
	return users;
}

Fail: adt {
	ip:	string;
	n:	int;
	first:	int;
};

Cached: adt {
	key:	array of byte;	# SHA-256 of user, NUL, password
	until:	int;
};

# Passwords are checked here, one at a time: a guess costs its
# PBKDF2 whatever it guesses (an unknown user's too, against a salt of
# no one's and as many iterations as the file's most, so a name is not
# learnt by the time).  Ten wrong from one network (an IPv4 address, an
# IPv6 /64) in ten minutes and it is refused for the rest of them;
# fifty wrong for one user from anywhere and that user is.  A password
# found right is taken again for five minutes without its hash (a
# browser sends it with every request), lockout or not, so one guesser
# behind a NAT does not lock out those already in.  The password file
# is read again when it changes.
authenticator()
{
	fails: list of ref Fail;
	cache: list of ref Cached;
	dummysalt := array of byte "no one's salt, for no one";
	for(;;) {
		(user, pass, ip, rc) := <-authc;
		{
			rc <-= check(user, pass, ip, fails, cache, dummysalt);
		} exception e {
		"*" =>
			sys->fprint(stderr, "httpd: checking a password: %s\n", e);
			rc <-= Bad;	# (rc holds one: this does not wait)
		}
		(fails, cache) = (cfails, ccache);
	}
}

# check's lists, as it leaves them (Limbo has no reference parameters)
cfails: list of ref Fail;
ccache: list of ref Cached;

USERFAIL: con 50;

check(user, pass, ip: string, fails: list of ref Fail, cache: list of ref Cached, dummysalt: array of byte): int
{
	cfails = fails;
	ccache = cache;
	t := now();
	(ok, d) := sys->stat(pwfile);
	if(ok >= 0 && (d.mtime != pwmtime || d.qid.vers != pwqid.vers || d.qid.path != pwqid.path)) {
		loadpasswords();
		cache = nil;
	}
	key := sha256(array of byte (user + "\0" + pass));
	nc: list of ref Cached;
	hit := 0;
	for(cl := cache; cl != nil; cl = tl cl)
		if((hd cl).until > t) {
			nc = hd cl :: nc;
			if(bytesame((hd cl).key, key))
				hit = 1;
		}
	ccache = cache = nc;
	if(hit)
		return Ok;

	net := netof(ip);
	ukey := "user " + user;
	nf: list of ref Fail;
	fnet, fuser: ref Fail;
	for(l := fails; l != nil; l = tl l)
		if(t - (hd l).first < WINDOW) {
			nf = hd l :: nf;
			if((hd l).ip == net)
				fnet = hd l;
			if((hd l).ip == ukey)
				fuser = hd l;
		}
	cfails = fails = nf;
	if(fnet != nil && fnet.n >= MAXFAIL || fuser != nil && fuser.n >= USERFAIL)
		return Locked;

	u: ref User;
	most := DEFITERS;
	for(ul := users; ul != nil; ul = tl ul) {
		if((hd ul).name == user)
			u = hd ul;
		if((hd ul).iters > most)
			most = (hd ul).iters;
	}
	good := 0;
	if(u != nil)
		good = bytesame(pbkdf2(array of byte pass, u.salt, u.iters), u.hash);
	else
		pbkdf2(array of byte pass, dummysalt, most);
	if(good) {
		if(len cache < 64)
			ccache = ref Cached(key, t + CACHETIME) :: cache;
		return Ok;
	}
	if(fnet == nil)
		cfails = fails = ref Fail(net, 1, t) :: fails;
	else
		fnet.n++;
	if(fuser == nil)
		cfails = ref Fail(ukey, 1, t) :: fails;
	else
		fuser.n++;
	if(verbose)
		sys->fprint(stderr, "httpd: %s: a wrong password for %s\n", ip, logname(user));
	return Bad;
}

# The network an address's guesses are counted for: an IPv4 address
# alone, an IPv6 address's /64 (one host has as many addresses of it as
# it likes); an IPv4-mapped IPv6 address as its IPv4
netof(ip: string): string
{
	if(!hasbyte(ip, ':'))
		return ip;
	(nil, last) := splitlast(ip, ':');
	if(hasbyte(last, '.'))
		return last;
	# expand "::" to the zero groups it stands for, then keep four
	groups := split(ip, ':');
	n := 0;
	for(g := groups; g != nil; g = tl g)
		if(hd g != "")
			n++;
	full: list of string;
	gap := 0;
	for(g = groups; g != nil; g = tl g) {
		if(hd g == "") {
			if(!gap) {
				for(i := n; i < 8; i++)
					full = "0" :: full;
				gap = 1;
			}
			continue;
		}
		full = lower(hd g) :: full;
	}
	r: list of string;
	for(; full != nil; full = tl full)
		r = hd full :: r;
	s := "";
	for(i := 0; i < 4 && r != nil; i++) {
		s += hd r + ":";
		r = tl r;
	}
	return s + ":/64";
}

# PBKDF2-HMAC-SHA-256 (RFC 8018), one block: 32 bytes
pbkdf2(pass, salt: array of byte, iters: int): array of byte
{
	s := array[len salt + 4] of byte;
	s[0:] = salt;
	s[len salt:] = array[] of {byte 0, byte 0, byte 0, byte 1};
	u := array[Keyring->SHA256dlen] of byte;
	keyring->hmac_sha256(s, len s, pass, u, nil);
	t := array[len u] of byte;
	t[0:] = u;
	v := array[len u] of byte;
	for(i := 1; i < iters; i++) {
		keyring->hmac_sha256(u, len u, pass, v, nil);
		(u, v) = (v, u);
		for(j := 0; j < len t; j++)
			t[j] ^= u[j];
	}
	return t;
}

sha256(b: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(b, len b, d, nil);
	return d;
}

# equal, in time that does not depend on where they differ
bytesame(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	x := 0;
	for(i := 0; i < len a; i++)
		x |= int a[i] ^ int b[i];
	return x == 0;
}

# CON, NUL, COM1 and the like, with any extension: on a Windows host
# the device, wherever the name is
dosdevice(seg: string): int
{
	(base, nil) := splitfirst(lower(seg), '.');
	case base {
	"con" or "prn" or "aux" or "nul" or "conin$" or "conout$" or "clock$" =>
		return 1;
	}
	# COM1-9, LPT1-9, and COM¹²³ and LPT¹²³ (Windows reserves those too)
	if(len base == 4 && (prefix(base, "com") || prefix(base, "lpt")) &&
	   (base[3] >= '0' && base[3] <= '9' || base[3] == 16rB9 || base[3] == 16rB2 || base[3] == 16rB3))
		return 1;
	return 0;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

ascii(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] > 16r7E)
			return 0;
	return 1;
}
