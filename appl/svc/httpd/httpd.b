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
logfd: ref FD;
stderr: ref FD;

# /dev/time, opened before the connections are confined and kept by
# them: the clock as it is now, set after httpd started or not (a
# board's clock is often set by timesync(8) or NTP after boot).  If
# there is none, the time at start and the millisecond clock since.
timefd: ref FD;
epoch0 := 0;
ms0 := 0;

# A connection's state as the listener's watchdog sees it
Watch: adt {
	deadline:	int;	# sys->millisec() past which it is hung up; 0: none
	pid:	int;	# its process (group), to kill
	orphans:	int;	# it leaves a process behind (an event stream's reader blocked in a read), killed with its group when it ends
};

Entry: adt {
	w:	ref Watch;
	cfd:	ref FD;
	ip:	string;
};

admitc: chan of (string, ref FD, chan of ref Watch);
donec: chan of ref Watch;	# a connection's end, told at once: a client's next connection is not refused for one it has finished with

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

	certfile, keyfile, logfile: string;
	arg->init(argv);
	arg->setusage("svc/httpd/httpd [-Lv] [-a addr] [-c cert -k key] [-l log] [-p path]... [-w wikibase]\n\t[-r httpsport] [-S hstssecs] [-C maxage] [-n maxconns] [-s persource] [-b maxbody] root");
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
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(len argv != 1 || maxconns <= 0 || maxpersource <= 0 || maxbody <= 0 || hsts < 0 || maxage < 0)
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
	if(addr == nil) {
		if(scfg != nil)
			addr = "tcp!*!443";
		else
			addr = "tcp!*!80";
	}

	if(logfile != nil) {
		logfd = sys->open(logfile, Sys->OWRITE);
		if(logfd == nil)
			logfd = sys->create(logfile, Sys->OWRITE, Sys->DMAPPEND|8r644);
		if(logfd == nil)
			fatal(sys->sprint("cannot open %s: %r", logfile));
		sys->seek(logfd, big 0, Sys->SEEKEND);
	} else
		logfd = sys->fildes(1);

	timefd = sys->open("/dev/time", Sys->OREAD);
	epoch0 = daytime->now();
	ms0 = sys->millisec();

	(aok, c) := sys->announce(addr);
	if(aok < 0)
		fatal(sys->sprint("cannot announce %s: %r", addr));

	admitc = chan of (string, ref FD, chan of ref Watch);
	donec = chan[16] of ref Watch;
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
	cfg := ref ServerConfig(certs, key, "http/1.1" :: nil, 0, nil);
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
		w := ref Watch(sys->millisec() + TLSWAIT + HDRWAIT, 0, 0);
		conns = ref Entry(w, cfd, ip) :: conns;
		n++;
		rc <-= w;
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
	keep := dfd.fd :: logfd.fd :: stderr.fd :: nil;
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
		serve(ref Io(dfd, nil, array[BUFSIZE] of byte, 0, 0, nil, 0, w), ip);
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
	while(i < n) {
		if(io.rp == io.re) {
			io.deadline(IOWAIT);
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
				r = ref Req("-", "-", nil, nil, 11, nil, big -1, 1, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil);
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
	r := ref Req(meth, target, nil, nil, 11, nil, big -1, 0, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil);
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
	t := "";
	for(i := 0; i < len b; i++)
		if(b[i] != byte '\r')
			t[len t] = int b[i];
	s := string array of byte t;	# the bytes back as UTF-8
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
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n && count < 10000; i++) {
			if(d[i].name == nil || d[i].name[0] == '.')
				continue;
			nm := d[i].name;
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
	if(code >= 400 && code != 404 && code != 403 && code != 304)
		r.close = 1;	# what was left of the request is not read
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
	s := sys->sprint("%s - - [%02d/%s/%d:%02d:%02d:%02d +0000] \"%s %s %s\" %d %bd \"%s\" \"%s\"\n",
		ip, t.mday, months[t.mon], t.year + 1900, t.hour, t.min, t.sec,
		logesc(r.meth), logesc(r.target), vers(r.vers), code, n, logesc(r.referer), logesc(r.agent));
	b := array of byte s;
	sys->write(logfd, b, len b);
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
