implement Webclient;

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";
	dial: Dial;

include "url.m";
	url: Url;
	ParsedUrl: import url;

include "keyring.m";

include "tls.m";
	tls: TLS;
	Conn: import tls;

include "string.m";
	str: String;

include "webclient.m";
include "publicnet.m";
	publicnet: Publicnet;
include "brotli.m";
	brotli: Brotli;
include "filter.m";
	inflate: Filter;
include "daytime.m";
	daytime: Daytime;

MAXREDIRECTS: con 10;
MAXTRAILER: con 64;	# trailer fields read after a chunked body

init(): string
{
	sys = load Sys Sys->PATH;

	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("load String: %r");

	dial = load Dial Dial->PATH;
	if(dial == nil)
		return sys->sprint("load Dial: %r");

	url = load Url Url->PATH;
	if(url == nil)
		return sys->sprint("load Url: %r");
	url->init();
	publicnet = load Publicnet Publicnet->PATH;
	if(publicnet == nil)
		return sys->sprint("load Publicnet: %r");
	publicnet->init();

	# TLS loaded lazily on first HTTPS use
	return nil;
}

# [private]
loadtls(): string
{
	if(tls != nil)
		return nil;
	tls = load TLS TLS->PATH;
	if(tls == nil)
		return sys->sprint("load TLS: %r");
	err := tls->init();
	if(err != nil)
		return "tls init: " + err;
	return nil;
}

Response.hdrval(r: self ref Response, name: string): string
{
	lname := str->tolower(name);
	for(h := r.headers; h != nil; h = tl h) {
		hdr := hd h;
		if(str->tolower(hdr.name) == lname)
			return hdr.value;
	}
	return nil;
}

get(requrl: string): (ref Response, string)
{
	return request("GET", requrl, nil, nil);
}

post(requrl, contenttype: string, body: array of byte): (ref Response, string)
{
	hdrs: list of Header;
	if(contenttype != nil)
		hdrs = Header("Content-Type", contenttype) :: hdrs;
	return request("POST", requrl, hdrs, body);
}

tlsdial(addr, servername: string): (ref Sys->FD, string)
{
	err := loadtls();
	if(err != nil)
		return (nil, err);

	c := dial->dial(addr, nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s: %r", addr));

	return tlsclient(c.dfd, servername);
}

tlsclient(fd: ref Sys->FD, servername: string): (ref Sys->FD, string)
{
	err := loadtls();
	if(err != nil)
		return (nil, err);

	cfg := tls->defaultconfig();
	cfg.servername = servername;

	(conn, terr) := tls->client(fd, cfg);
	if(terr != nil) {
		if(len terr < 4 || terr[0:4] != "tls:")
			terr = "tls: " + terr;
		return (nil, terr);
	}

	# Wrap TLS conn as a pipe-like FD pair
	return tlsconnfd(conn);
}

# [private]
# Create a bidirectional FD from a TLS connection using a pipe
tlsconnfd(conn: ref Conn): (ref Sys->FD, string)
{
	fds := array [2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return (nil, sys->sprint("pipe: %r"));

	# Spawn read and write pumps
	spawn tlsreadpump(conn, fds[1]);
	spawn tlswritepump(conn, fds[1]);

	return (fds[0], nil);
}

# [private]
tlsreadpump(conn: ref Conn, fd: ref Sys->FD)
{
	buf := array [16384] of byte;
	{
		for(;;) {
			n := conn.read(buf, len buf);
			if(n <= 0)
				break;
			if(sys->write(fd, buf[:n], n) != n)
				break;
		}
	} exception {
	"write on closed pipe" =>
		# the caller closed its end while the server still sent
		# (an SMTP server's 221 after QUIT): nobody to read it
		;
	}
	# Signal EOF by closing our end
	fd = nil;
}

# [private]
tlswritepump(conn: ref Conn, fd: ref Sys->FD)
{
	buf := array [16384] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		if(conn.write(buf[:n], n) != n)
			break;
	}
	conn.close();
}

request(method, requrl: string, hdrs: list of Header, body: array of byte): (ref Response, string)
{
	return request0(newreq(0, 0), method, requrl, hdrs, body, 0, nil, nil);
}

requestpublic(method, requrl: string, hdrs: list of Header, body: array of byte): (ref Response, string)
{
	return request0(newreq(0, 0), method, requrl, hdrs, body, 1, nil, nil);
}

# ---- a request with a deadline ----
#
# A caller that gave up on a request (a tool with 30 seconds for its
# fetch) used to leave it running: the process in its read, the
# connection open, and the body's buffer, which was allocated whole from
# Content-Length before a byte of it came.  A server sending "64 MB
# follow" and nothing more cost 64 MB of the heap every program shares,
# for as long as it kept the connection, for each request.
#
# The request is now the one that keeps the time.  It runs in a process
# of its own; at the deadline the connection it is using is hung up,
# which ends its read (or its TLS handshake), no new one is made, and
# the caller has its answer at once.  A process cannot be killed here
# by number (a tool's name space has no /prog entry but its own, and one
# killed holding the pool's lock would stop every later request), so it
# is the hangup that ends it; one still in a connect is not reachable so
# and ends when the connect does, holding nothing.

Etimeout: con "request timed out";
# A body that ended before its header said it would.  It was a
# response like any other, its first bytes its body: whoever could cut
# the connection of a download (no need to break its TLS) chose where
# the file ended, and the caller was told 200.  It is not `truncated',
# which is the caller's own limit reached.
Ecut: con "response body cut short";
Ebadlength: con "bad Content-Length in response";
POLLMS: con 100;	# how often the deadline is looked at

Req: adt {
	ms:	int;		# from the start to the end of the body; 0: no deadline
	t0:	int;
	maxbody:	int;	# bytes of body kept
	lk:	chan of int;	# cur and over
	cur:	ref Link;	# the connection in use
	over:	int;	# the deadline passed: nothing more is read or dialled
	done:	int;	# answered: the watch ends

	attach:	fn(r: self ref Req, l: ref Link): int;
	detach:	fn(r: self ref Req);
	expire:	fn(r: self ref Req);
};

newreq(ms, maxbody: int): ref Req
{
	if(maxbody <= 0 || maxbody > MAXBODY)
		maxbody = MAXBODY;
	return ref Req(ms, sys->millisec(), maxbody, chan[1] of int, nil, 0, 0);
}

# l is the connection in use, unless the time is up (0)
Req.attach(r: self ref Req, l: ref Link): int
{
	r.lk <-= 1;
	ok := !r.over;
	if(ok)
		r.cur = l;
	<-r.lk;
	return ok;
}

# the connection is no longer this request's to hang up (it may go
# back to the pool, for another's use)
Req.detach(r: self ref Req)
{
	r.lk <-= 1;
	r.cur = nil;
	<-r.lk;
}

Req.expire(r: self ref Req)
{
	r.lk <-= 1;
	r.over = 1;
	if(r.cur != nil)
		r.cur.hangup();	# under the lock: it is still this request's
	<-r.lk;
}

requestbounded(method, requrl: string, hdrs: list of Header, body: array of byte, public, ms, maxbody: int): (ref Response, string)
{
	rq := newreq(ms, maxbody);
	if(ms <= 0)
		return request0(rq, method, requrl, hdrs, body, public, nil, nil);
	res := chan[1] of (ref Response, string);
	late := chan[1] of int;
	spawn bounded(rq, method, requrl, hdrs, body, public, res);
	spawn watch(rq, late);
	alt {
	(r, e) := <-res =>
		rq.done = 1;
		return (r, e);
	<-late =>
		return (nil, Etimeout);
	}
}

bounded(rq: ref Req, method, requrl: string, hdrs: list of Header, body: array of byte, public: int, res: chan of (ref Response, string))
{
	r: ref Response;
	e: string;
	{
		(r, e) = request0(rq, method, requrl, hdrs, body, public, nil, nil);
	} exception x {
	"*" =>
		r = nil;
		e = "internal error: " + x;
	}
	if(rq.over)
		(r, e) = (nil, Etimeout);
	res <-= (r, e);
}

# ends within POLLMS of the answer, or at the deadline
watch(rq: ref Req, late: chan of int)
{
	for(;;) {
		sys->sleep(POLLMS);
		if(rq.done)
			return;
		if(sys->millisec() - rq.t0 >= rq.ms) {
			rq.expire();
			late <-= 1;
			return;
		}
	}
}

requestjar(method, requrl: string, hdrs: list of Header, body: array of byte, jar: ref Jar): (ref Response, string)
{
	return requesttypes(method, requrl, hdrs, body, jar, nil);
}

requesttypes(method, requrl: string, hdrs: list of Header, body: array of byte, jar: ref Jar, types: list of string): (ref Response, string)
{
	(resp, err) := request0(newreq(0, 0), method, requrl, hdrs, body, 0, jar, types);
	if(resp != nil && resp.body != nil) {
		ce := str->tolower(resp.hdrval("Content-Encoding"));
		case ce {
		"gzip" or "x-gzip" =>
			if((b := decompress(resp.body, "h")) != nil)
				resp.body = b;
		"deflate" =>
			# servers send both zlib-wrapped and raw deflate
			if((b := decompress(resp.body, "z")) != nil)
				resp.body = b;
			else if((b = decompress(resp.body, "")) != nil)
				resp.body = b;
		"br" =>
			if(brotli == nil)
				brotli = load Brotli Brotli->PATH;
			if(brotli != nil) {
				(b, nil) := brotli->decompress(resp.body, -1);
				if(b != nil)
					resp.body = b;
			}
		}
	}
	return (resp, err);
}

# Inflate data: param "h" for a gzip stream, "z" for zlib, "" for raw.
decompress(data: array of byte, param: string): array of byte
{
	if(inflate == nil) {
		inflate = load Filter Filter->INFLATEPATH;
		if(inflate == nil)
			return nil;
		inflate->init();
	}
	rq := inflate->start(param);
	out: list of array of byte;
	total := 0;
	in := 0;
	for(;;) {
		pick m := <-rq {
		Start =>
			;
		Fill =>
			n := len data - in;
			if(n > len m.buf)
				n = len m.buf;
			m.buf[0:] = data[in:in+n];
			in += n;
			m.reply <-= n;
		Result =>
			b := array[len m.buf] of byte;
			b[0:] = m.buf;
			out = b :: out;
			total += len b;
			m.reply <-= 0;
			if(total > MAXBODY)
				return nil;
		Info =>
			;
		Finished =>
			return concatchunks(out, total);
		Error =>
			return nil;
		}
	}
}

# Revalidates every redirect target. Public mode resolves first and dials the
# exact validated address, preventing redirect and DNS-rebinding SSRF.
request0(rq: ref Req, method, requrl: string, hdrs: list of Header, body: array of byte, public: int, jar: ref Jar, types: list of string): (ref Response, string)
{
	for(redir := 0; redir < MAXREDIRECTS; redir++) {
		if(rq.over)
			return (nil, Etimeout);
		requrl = encodeurl(requrl);
		rh := hdrs;
		if(jar != nil && (c := jar.header(requrl)) != nil)
			rh = Header("Cookie", c) :: rh;
		verr := validrequesttext(method, requrl, rh);
		if(verr != nil)
			return (nil, verr);
		(resp, err) := dorequest(rq, method, requrl, rh, body, public, types);
		if(err != nil)
			return (nil, err);
		resp.url = requrl;
		if(jar != nil)
			for(h := resp.headers; h != nil; h = tl h)
				if(str->tolower((hd h).name) == "set-cookie")
					jar.set(requrl, (hd h).value);

		# Handle redirects
		case resp.statuscode {
		301 or 302 or 303 or 307 or 308 =>
			loc := resp.hdrval("Location");
			if(loc == nil)
				return (resp, nil);
			oldorigin := schemehost(requrl);
			requrl = resolve(requrl, loc);
			# Credentials are scoped to the origin selected by the caller. Never
			# forward them when a redirect changes scheme, host, or port.
			if(schemehost(requrl) != oldorigin)
				hdrs = redirectheaders(hdrs);
			# 303, and 301/302 after a POST, change to GET (as browsers do)
			if(resp.statuscode == 303 || (resp.statuscode == 301 || resp.statuscode == 302) && method == "POST") {
				method = "GET";
				body = nil;
			}
		* =>
			return (resp, nil);
		}
	}
	return (nil, "too many redirects");
}

# Resolve a reference against a base URL (RFC 3986 §5.2).
resolve(base, rel: string): string
{
	for(i := 0; i < len rel; i++) {
		c := rel[i];
		if(c == ':')
			return rel;
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'))
			break;
	}
	sh := schemehost(base);
	scheme := "";
	for(i = 0; i < len base; i++)
		if(base[i] == ':') {
			scheme = base[0:i];
			break;
		}
	if(len rel >= 2 && rel[0:2] == "//")
		return scheme + ":" + rel;
	if(len rel > 0 && rel[0] == '/')
		return sh + rel;
	# relative to the base's directory
	path := base[len sh:];
	for(i = 0; i < len path; i++)
		if(path[i] == '?' || path[i] == '#') {
			path = path[0:i];
			break;
		}
	if(len rel > 0 && rel[0] == '?')
		return sh + path + rel;
	for(i = len path - 1; i >= 0; i--)
		if(path[i] == '/')
			break;
	return sh + path[0:i+1] + rel;
}

# A URL as a browser sends it: a space, a character outside ASCII (as
# its UTF-8 bytes) and " < > ` { } percent-encoded (WHATWG URL, the
# path and query percent-encode sets).  A link to
# https://pantip.com/tag/ดูแล... was sent with its Thai as it was, and
# answered 400; one with a space was refused.  Control characters are
# left, for validrequesttext to refuse.
encodeurl(u: string): string
{
	for(i := 0; i < len u; i++) {
		c := u[i];
		if(c == ' ' || c >= 16r80 || c == '"' || c == '<' || c == '>' || c == '`' || c == '{' || c == '}')
			break;
	}
	if(i == len u)
		return u;
	r := u[0:i];
	for(; i < len u; i++) {
		c := u[i];
		if(c == ' ' || c >= 16r80 || c == '"' || c == '<' || c == '>' || c == '`' || c == '{' || c == '}') {
			b := array of byte u[i:i+1];
			for(j := 0; j < len b; j++)
				r += sys->sprint("%%%.2X", int b[j]);
		} else
			r[len r] = c;
	}
	return r;
}

validrequesttext(method, requrl: string, hdrs: list of Header): string
{
	if(!validtoken(method))
		return "invalid HTTP method";
	if(!validurltext(requrl))
		return "invalid URL text";
	for(; hdrs != nil; hdrs = tl hdrs) {
		h := hd hdrs;
		if(!validheadername(h.name))
			return "invalid HTTP header name";
		if(!validheadervalue(h.value))
			return "invalid HTTP header value";
	}
	return nil;
}

validtoken(s: string): int
{
	if(s == nil || len s == 0)
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c <= ' ' || c == 16r7F)
			return 0;
	}
	return 1;
}

validurltext(s: string): int
{
	if(s == nil || len s == 0)
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c <= ' ' || c == 16r7F)
			return 0;
	}
	return 1;
}

validheadername(s: string): int
{
	if(s == nil || len s == 0)
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c <= ' ' || c == ':' || c == 16r7F)
			return 0;
	}
	return 1;
}

validheadervalue(s: string): int
{
	if(s == nil)
		return 1;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < ' ' || c == 16r7F)
			return 0;
	}
	return 1;
}

redirectheaders(hdrs: list of Header): list of Header
{
	kept: list of Header;
	for(; hdrs != nil; hdrs = tl hdrs) {
		h := hd hdrs;
		name := str->tolower(h.name);
		# Generic callers can use arbitrary credential header names, so preserve
		# only representation metadata rather than trying to enumerate secrets.
		if(name != "accept" && name != "accept-encoding" &&
		   name != "accept-language" && name != "content-type" &&
		   name != "user-agent")
			continue;
		kept = h :: kept;
	}
	result: list of Header;
	for(; kept != nil; kept = tl kept)
		result = hd kept :: result;
	return result;
}

# [private]
schemehost(requrl: string): string
{
	u := url->makeurl(requrl);
	if(u == nil)
		return "";
	port := u.port;
	if(port == nil) {
		case u.scheme {
		Url->HTTPS => port = "443";
		* => port = "80";
		}
	}
	h := u.host;
	for(i := 0; i < len h; i++)
		if(h[i] == ':'){	# an IPv6 address, as a URL writes it
			h = "[" + h + "]";
			break;
		}
	s := url->schemes[u.scheme] + "://" + h;
	if(port != "80" && port != "443")
		s += ":" + port;
	return s;
}

# [private]
dorequest(rq: ref Req, method, requrl: string, hdrs: list of Header, body: array of byte, public: int, types: list of string): (ref Response, string)
{
	u := url->makeurl(requrl);
	if(u == nil)
		return (nil, "bad url: " + requrl);
	# (a redirect to file:///x was a request to localhost, port 80)
	if(u.scheme != Url->HTTP && u.scheme != Url->HTTPS)
		return (nil, "not an http or https address: " + requrl);

	host := u.host;
	port := u.port;
	ishttps := u.scheme == Url->HTTPS;

	if(port == nil) {
		if(ishttps)
			port = "443";
		else
			port = "80";
	}

	addr := "tcp!" + host + "!" + port;
	if(public) {
		(paddr, err) := publicaddr(host, port);
		if(err != nil)
			return (nil, err);
		addr = paddr;
	}

	if(ishttps) {
		err := loadtls();
		if(err != nil)
			return (nil, err);
	}
	return linkrequest(rq, method, u, host, addr, ishttps, hdrs, body, types);
}

publicaddr(host, port: string): (string, string)
{
	return publicnet->dialaddr(host, port);
}

# [private]
buildrequest(method: string, u: ref ParsedUrl, host: string,
	hdrs: list of Header, body: array of byte): string
{
	path := u.pstart + u.path;
	if(path == nil || path == "")
		path = "/";
	if(u.query != nil)
		path += "?" + u.query;

	req := method + " " + path + " HTTP/1.1\r\n";
	req += "Host: " + host + "\r\n";
	ua := "Infernode/1.0";
	for(h := hdrs; h != nil; h = tl h)
		if(str->tolower((hd h).name) == "user-agent")
			ua = nil;	# the caller's
	if(ua != nil)
		req += "User-Agent: " + ua + "\r\n";

	if(body != nil && len body > 0)
		req += "Content-Length: " + string len body + "\r\n";

	# Add user headers
	for(h = hdrs; h != nil; h = tl h) {
		hdr := hd h;
		req += hdr.name + ": " + hdr.value + "\r\n";
	}

	req += "\r\n";
	return req;
}

# ---- connections ----
#
# A connection whose response had a known length is kept for the next
# request to the same place (RFC 9112 §9.3, persistence): a page's
# style sheets and images come from a few hosts, and a new connection
# for each costs a TCP and a TLS handshake.  One request at a time on
# each; a kept connection the server has since closed answers nothing,
# and a GET is sent again on a new one.

Link: adt {
	key:	string;	# where it goes: the address, and the TLS server name
	tls:	ref Conn;
	fd:	ref Sys->FD;
	cfd:	ref Sys->FD;	# its ctl file, to hang it up
	buf:	array of byte;
	p, n:	int;	# buf[p:n] read and not yet taken
	idle:	int;	# sys->millisec() when it was put back
	reused:	int;

	read:	fn(l: self ref Link, a: array of byte): int;
	write:	fn(l: self ref Link, a: array of byte): int;
	getc:	fn(l: self ref Link): int;
	hangup:	fn(l: self ref Link);
	close:	fn(l: self ref Link);
};

MAXIDLE: con 6;		# kept for each place, as many as fetch at once
MAXPOOL: con 32;	# kept at all
IDLEMS: con 30*1000;	# not reused after; servers close idle connections

pool: list of ref Link;
poollk: chan of int;

Link.read(l: self ref Link, a: array of byte): int
{
	if(l.p < l.n) {
		m := l.n - l.p;
		if(m > len a)
			m = len a;
		a[0:] = l.buf[l.p:l.p+m];
		l.p += m;
		return m;
	}
	if(l.tls != nil)
		return l.tls.read(a, len a);
	return sys->read(l.fd, a, len a);
}

Link.getc(l: self ref Link): int
{
	if(l.p >= l.n) {
		l.p = l.n = 0;
		m: int;
		if(l.tls != nil)
			m = l.tls.read(l.buf, len l.buf);
		else
			m = sys->read(l.fd, l.buf, len l.buf);
		if(m <= 0)
			return -1;
		l.n = m;
	}
	return int l.buf[l.p++];
}

Link.write(l: self ref Link, a: array of byte): int
{
	if(len a == 0)
		return 0;
	if(l.tls != nil)
		return l.tls.write(a, len a);
	return sys->write(l.fd, a, len a);
}

# Hang it up: a read outstanding on it fails.
Link.hangup(l: self ref Link)
{
	if(l.cfd != nil)
		sys->fprint(l.cfd, "hangup");
}

Link.close(l: self ref Link)
{
	if(l.tls != nil)
		l.tls.close();
	l.tls = nil;
	l.fd = nil;
	l.cfd = nil;
}

lockpool()
{
	if(poollk == nil)
		poollk = chan[1] of int;	# (init runs once, before any request)
	poollk <-= 1;
}

# A kept connection to key, or nil.
takelink(key: string): ref Link
{
	lockpool();
	now := sys->millisec();
	l: ref Link;
	keep: list of ref Link;
	for(pl := pool; pl != nil; pl = tl pl) {
		k := hd pl;
		if(now - k.idle > IDLEMS)
			continue;	# dropped, and closed when collected
		if(l == nil && k.key == key)
			l = k;
		else
			keep = k :: keep;
	}
	pool = keep;
	<-poollk;
	return l;
}

putlink(l: ref Link)
{
	l.idle = sys->millisec();
	lockpool();
	n := 0;
	t := 0;
	for(pl := pool; pl != nil; pl = tl pl) {
		t++;
		if((hd pl).key == l.key)
			n++;
	}
	if(n < MAXIDLE && t < MAXPOOL) {
		pool = l :: pool;
		l = nil;
	}
	<-poollk;
	if(l != nil)
		l.close();
}

# A new connection, the request's own (attached) from before its TLS
# handshake, which is a read like any other to a server that says nothing.
newlink(rq: ref Req, key, addr, host: string, ishttps: int): (ref Link, string)
{
	if(rq.over)
		return (nil, Etimeout);
	c := dial->dial(addr, nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s: %r", addr));
	l := ref Link(key, nil, c.dfd, c.cfd, array[16384] of byte, 0, 0, 0, 0);
	if(!rq.attach(l)) {
		l.hangup();
		l.close();
		return (nil, Etimeout);
	}
	if(ishttps) {
		cfg := tls->defaultconfig();
		cfg.servername = host;
		(conn, terr) := tls->client(c.dfd, cfg);
		if(terr != nil) {
			rq.detach();
			l.hangup();
			l.close();
			if(rq.over)
				return (nil, Etimeout);
			return (nil, "tls: " + terr);
		}
		l.tls = conn;
	}
	return (l, nil);
}

# [private]
linkrequest(rq: ref Req, method: string, u: ref ParsedUrl, host, addr: string, ishttps: int,
	hdrs: list of Header, body: array of byte, types: list of string): (ref Response, string)
{
	req := array of byte buildrequest(method, u, host, hdrs, body);
	key := addr;
	if(ishttps)
		key = "tls!" + addr + "!" + host;
	for(try := 0; ; try++) {
		l: ref Link;
		if(try == 0)
			l = takelink(key);
		if(l != nil) {
			l.reused = 1;
			if(!rq.attach(l)) {
				l.close();
				return (nil, Etimeout);
			}
		} else {
			err: string;
			(l, err) = newlink(rq, key, addr, host, ishttps);
			if(l == nil)
				return (nil, err);
		}
		again := l.reused && try == 0 && (method == "GET" || method == "HEAD");
		if(l.write(req) != len req || body != nil && l.write(body) != len body) {
			rq.detach();
			l.close();
			if(rq.over)
				return (nil, Etimeout);
			if(again)
				continue;
			return (nil, "write failed");
		}
		(resp, keep, err) := readresponse(rq, l, method, types);
		# from here it is not the request's to hang up; if the time
		# ran out it may have been, and what was read is not the answer
		rq.detach();
		if(rq.over) {
			l.close();
			return (nil, Etimeout);
		}
		if(resp == nil) {
			l.close();
			if(again && err == "empty response")
				continue;	# it had been closed at the other end
			return (nil, err);
		}
		if(keep)
			putlink(l);
		else
			l.close();
		return (resp, nil);
	}
}

# ---- bodies ----
#
# A body is read into a buffer that grows as its bytes come, to what the
# header promised and no further than the request's limit.  It was
# allocated whole from Content-Length (and each chunk from its size
# line) before anything was read: what a server said, not what it sent,
# decided how much memory a request took.

Grow: adt {
	a:	array of byte;
	n:	int;	# bytes held
	max:	int;	# never more than this

	room:	fn(g: self ref Grow, want: int): int;
	bytes:	fn(g: self ref Grow): array of byte;
};

# Room for some of want more bytes, at a[n:]: how many (0 at the limit).
# The buffer doubles when it is full, never past what is wanted, so one
# that is filled is exactly as long as its body.
Grow.room(g: self ref Grow, want: int): int
{
	if(want > g.max - g.n)
		want = g.max - g.n;
	if(want <= 0)
		return 0;
	free := len g.a - g.n;
	if(free == 0) {
		sz := 2 * len g.a;
		if(sz < 65536)
			sz = 65536;
		if(sz > g.n + want)
			sz = g.n + want;
		na := array[sz] of byte;
		na[0:] = g.a[0:g.n];
		g.a = na;
		free = sz - g.n;
	}
	if(free > want)
		free = want;
	return free;
}

Grow.bytes(g: self ref Grow): array of byte
{
	if(g.n == 0)
		return nil;
	if(g.n == len g.a)
		return g.a;
	return g.a[0:g.n];
}

# Up to want more bytes of l into g: how many came.
readinto(rq: ref Req, l: ref Link, g: ref Grow, want: int): int
{
	got := 0;
	while(got < want && !rq.over) {
		m := g.room(want - got);
		if(m == 0)
			break;
		n := l.read(g.a[g.n:g.n+m]);
		if(n <= 0)
			break;
		g.n += n;
		got += n;
	}
	return got;
}

# [private]
# The response to a request: its header, and its body as the header
# frames it.  Whether the connection can carry another request after.
readresponse(rq: ref Req, l: ref Link, method: string, types: list of string): (ref Response, int, string)
{
	resp: ref Response;
	for(;;) {
		(hdr, herr) := readheader(l);
		if(herr != nil)
			return (nil, 0, herr);
		err: string;
		(resp, nil, err) = parseresponse(hdr);
		if(err != nil)
			return (nil, 0, err);
		if(resp.statuscode < 100 || resp.statuscode >= 200 || resp.statuscode == 101)
			break;
		# 1xx: an interim response; the real one follows
	}
	keep := 1;
	conn := str->tolower(resp.hdrval("Connection"));
	if(str->prefix("HTTP/1.0", resp.status))
		keep = conn == "keep-alive";
	else if(contains(conn, "close"))
		keep = 0;
	(cl, clerr) := contentlength(resp);
	if(clerr != nil)
		return (nil, 0, clerr);
	te := str->tolower(resp.hdrval("Transfer-Encoding"));
	if(te == "identity")
		te = nil;
	code := resp.statuscode;
	if(code == 101)
		keep = 0;	# what follows is not HTTP
	if(method == "HEAD" || code == 204 || code == 304 || code < 200)
		return (resp, keep, nil);
	if(code < 300 && types != nil && !typeok(resp.hdrval("Content-Type"), types))
		return (resp, 0, nil);	# not wanted: not read, and the connection with it not kept
	g := ref Grow(nil, 0, rq.maxbody);
	if(te != nil && contains(te, "chunked")) {
		(ok, trunc, cerr) := readchunked(rq, l, g);
		if(cerr != nil) {
			if(rq.over)
				cerr = Etimeout;
			return (nil, 0, cerr);
		}
		resp.truncated = trunc;
		resp.body = g.bytes();
		# with a Content-Length too the two may disagree about where
		# the next response begins (RFC 9112 §6.3): not kept
		return (resp, keep && ok && cl < big 0, nil);
	}
	if(te == nil && cl >= big 0) {
		nbytes := g.max;
		if(cl > big g.max) {
			resp.truncated = 1;
			keep = 0;
		} else
			nbytes = int cl;
		if(nbytes <= 0)
			return (resp, keep, nil);
		got := readinto(rq, l, g, nbytes);
		if(got < nbytes) {
			if(rq.over)
				return (nil, 0, Etimeout);
			return (nil, 0, sys->sprint("%s: %d bytes of %bd", Ecut, got, cl));
		}
		resp.body = g.bytes();
		return (resp, keep, nil);
	}
	# the body runs to the end of the connection (as it does under a
	# transfer coding that is not chunked, RFC 9112 §6.3)
	readinto(rq, l, g, g.max);
	if(g.n == g.max) {
		one := array[1] of byte;
		resp.truncated = l.read(one) > 0;
	}
	resp.body = g.bytes();
	return (resp, 0, nil);
}

# The length Content-Length gives a body: -1 with none.  One that is
# not a number, or two that differ, is an error (RFC 9112 §6.3): "-1"
# read as no body, and the connection went back to the pool with the
# body, or whatever the server sent in its place, as the next answer.
contentlength(resp: ref Response): (big, string)
{
	cl := big -1;
	for(h := resp.headers; h != nil; h = tl h) {
		if(str->tolower((hd h).name) != "content-length")
			continue;
		(nil, vl) := sys->tokenize((hd h).value, ",");
		if(vl == nil)
			return (big -1, Ebadlength);
		for(; vl != nil; vl = tl vl) {
			v := trimsp(hd vl);
			if(v == "" || len v > 18)
				return (big -1, Ebadlength);
			for(i := 0; i < len v; i++)
				if(v[i] < '0' || v[i] > '9')
					return (big -1, Ebadlength);
			n := big v;
			if(cl >= big 0 && n != cl)
				return (big -1, Ebadlength);
			cl = n;
		}
	}
	return (cl, nil);
}

# [private]
# whether a Content-Type is one of types (see requesttypes)
typeok(ctype: string, types: list of string): int
{
	t := str->tolower(ctype);
	for(i := 0; i < len t; i++)
		if(t[i] == ';' || t[i] == ' ' || t[i] == '\t') {
			t = t[0:i];
			break;
		}
	if(t == "")
		return 1;
	for(; types != nil; types = tl types) {
		e := str->tolower(hd types);
		if(e == "")
			continue;
		if(e[len e - 1] == '/') {
			if(str->prefix(e, t))
				return 1;
		} else if(e[0] == '+') {
			if(len t >= len e && t[len t - len e:] == e)
				return 1;
		} else if(t == e)
			return 1;
	}
	return 0;
}

# [private]
# Up to and including the blank line that ends a header.
readheader(l: ref Link): (string, string)
{
	hbuf := array[65536] of byte;
	hlen := 0;
	while(hlen < len hbuf) {
		c := l.getc();
		if(c < 0)
			break;
		hbuf[hlen++] = byte c;
		if(hlen >= 4 && c == '\n' && hbuf[hlen-2] == byte '\r' && hbuf[hlen-3] == byte '\n' && hbuf[hlen-4] == byte '\r')
			return (string hbuf[:hlen], nil);
	}
	if(hlen == 0)
		return (nil, "empty response");
	if(hlen == len hbuf)
		return (nil, "response header too long");
	# (as much as came was taken for the header, and nothing for the body)
	return (nil, "response header cut short");
}

# [private]
contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

# [private]
parseresponse(hdrstr: string): (ref Response, int, string)
{
	# Find end of status line
	(statusline, rest) := splitline(hdrstr);
	if(statusline == nil)
		return (nil, 0, "no status line");

	# Parse "HTTP/1.1 200 OK".  Anything else is not an answer (an
	# SMTP server's greeting was status 0 and no error).
	if(len statusline < 5 || statusline[0:5] != "HTTP/")
		return (nil, 0, "not an HTTP response: " + printable(statusline));
	(nf, fields) := sys->tokenize(statusline, " ");
	if(nf < 2)
		return (nil, 0, "bad status line: " + printable(statusline));
	sc := hd tl fields;
	if(len sc != 3 || sc[0] < '1' || sc[0] > '9' || sc[1] < '0' || sc[1] > '9' || sc[2] < '0' || sc[2] > '9')
		return (nil, 0, "bad status line: " + printable(statusline));
	code := int sc;
	status := statusline;

	# Parse headers
	headers: list of Header;
	bodystart := len statusline + 2;	# past \r\n

	for(;;) {
		(line, nrest) := splitline(rest);
		if(line == nil || line == "")
			break;
		bodystart += len line + 2;
		rest = nrest;
		(hname, hval) := splitheader(line);
		if(hname != nil)
			headers = Header(hname, hval) :: headers;
	}
	bodystart += 2;	# past final \r\n

	resp := ref Response(code, status, headers, nil, nil, 0);
	return (resp, bodystart, nil);
}

# [private]
# the start of what a server sent, fit for an error message
printable(s: string): string
{
	if(len s > 60)
		s = s[0:60];
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] < ' ' || s[i] == 16r7F)
			r[len r] = '?';
		else
			r[len r] = s[i];
	return r;
}

# [private]
splitline(s: string): (string, string)
{
	for(i := 0; i < len s - 1; i++) {
		if(s[i] == '\r' && s[i+1] == '\n')
			return (s[:i], s[i+2:]);
	}
	return (s, "");
}

# [private]
splitheader(line: string): (string, string)
{
	for(i := 0; i < len line; i++) {
		if(line[i] == ':') {
			name := line[:i];
			val := line[i+1:];
			# Strip leading whitespace from value
			j := 0;
			while(j < len val && (val[j] == ' ' || val[j] == '\t'))
				j++;
			return (name, val[j:]);
		}
	}
	return (nil, nil);
}

# [private]
# A chunked body (RFC 9112 §7.1) into g: whether it ended as it should
# (the last chunk and the trailer section read, so that the connection
# is at the next response), whether it was cut at g's limit, and what
# was wrong with it: a connection that ended before the last chunk, a
# size that is no number.
readchunked(rq: ref Req, l: ref Link, g: ref Grow): (int, int, string)
{
	for(;;) {
		line := readline(l);
		if(line == nil)
			return (0, 0, Ecut);
		chunksize := hexval(line);
		if(chunksize < 0)
			return (0, 0, "bad chunk size in response");
		if(chunksize == 0)
			break;
		if(chunksize > g.max - g.n) {
			want := g.max - g.n;
			if(readinto(rq, l, g, want) < want)
				return (0, 0, Ecut);
			return (0, 1, nil);
		}
		if(readinto(rq, l, g, chunksize) < chunksize)
			return (0, 0, Ecut);
		line = readline(l);	# the CRLF after the data
		if(line == nil)
			return (0, 0, Ecut);
		if(line != "\r\n" && line != "\n")
			return (0, 0, "bad chunked encoding in response");
	}
	# the trailer section, to its blank line.  The body is whole
	# without it; the connection is not kept.
	for(n := 0; ; n++) {
		line := readline(l);
		if(line == nil || n >= MAXTRAILER)
			return (0, 0, nil);
		if(line == "\r\n" || line == "\n")
			break;
	}
	return (1, 0, nil);
}

# [private]
# A line, with its end; nil at the end of the connection.
readline(l: ref Link): string
{
	s := "";
	while(len s < 8192) {
		c := l.getc();
		if(c < 0)
			return nil;
		s[len s] = c;
		if(c == '\n')
			return s;
	}
	return s;
}

# [private]
hexval(s: string): int
{
	# Strip any extension (e.g., ";ext")
	for(i := 0; i < len s; i++) {
		if(s[i] == ';') {
			s = s[:i];
			break;
		}
	}
	s = str->drop(s, " \t");
	n := 0;
	for(i = 0; i < len s; i++) {
		c := s[i];
		d := 0;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			break;
		if(n >= 16r8000000)
			return 16r7fffffff;	# more than any body kept; not left to wrap
		n = n * 16 + d;
	}
	if(i == 0)
		return -1;	# no number (it was 0: the end of the body)
	return n;
}

# [private]
# Concatenate a list of byte arrays (in reverse order) into one
concatchunks(chunks: list of array of byte, total: int): array of byte
{
	if(total <= 0)
		return nil;
	result := array [total] of byte;
	# chunks is in reverse order, reverse it first
	rev: list of array of byte;
	for(l := chunks; l != nil; l = tl l)
		rev = hd l :: rev;
	off := 0;
	for(l = rev; l != nil; l = tl l) {
		chunk := hd l;
		result[off:] = chunk;
		off += len chunk;
	}
	return result;
}

# ---- cookies (RFC 6265 §5, as RFC 6265bis tightens it) ----
#
# What a response may put in the jar.  A Set-Cookie was taken on the
# strength of its Domain matching the host's tail and nothing else, so a
# page at evil.com set a cookie for "com", sent from then on to every
# .com site (one site choosing another's session); with a control
# character in its value every request that cookie matched was refused
# as a bad header, until it expired; and a response over plain http
# replaced or deleted a cookie a site had marked Secure.  Now:
#
# - a header with a control character in it, or a name and value past
#   4096 characters, is ignored whole (6265bis, the Set-Cookie header);
# - a Domain must be a name of at least two labels that is not one
#   sites are registered under (publicsuffix below), and the host must
#   be it or end in it; a Domain that is such a name, or an address, is
#   taken only from the host of that very name, as a cookie for that
#   host alone (RFC 6265 §5.3 steps 5 and 6);
# - a response not over https sets no Secure cookie, and none of the
#   name of a Secure cookie it would be sent beside ("leave secure
#   cookies alone", 6265bis); __Secure- and __Host- names keep their
#   promises (6265bis, cookie name prefixes);
# - a jar holds MAXPERDOMAIN cookies for a domain and MAXCOOKIES in
#   all, the oldest going first.

MAXCOOKIE: con 4096;	# a name and its value
MAXATTR: con 1024;	# an attribute's value
MAXPERDOMAIN: con 180;
MAXCOOKIES: con 3000;
MAXAGE: con 400*24*60*60;	# the longest a cookie is kept (6265bis)

Jar.new(): ref Jar
{
	return ref Jar(nil, chan[1] of int);
}

now(): int
{
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return 0;
	return daytime->now();
}

# (scheme, host, path) of a URL, host lower case
urlparts(u: string): (string, string, string)
{
	pu := url->makeurl(u);
	if(pu == nil)
		return (nil, nil, nil);
	path := pu.pstart + pu.path;
	if(path == "")
		path = "/";
	return (url->schemes[pu.scheme], str->tolower(pu.host), path);
}

domainmatch(host, domain: string): int
{
	if(host == domain)
		return 1;
	n := len host - len domain;
	return n > 0 && host[n:] == domain && host[n-1] == '.' && !isip(host);
}

isip(h: string): int
{
	for(i := 0; i < len h; i++)
		if(!(h[i] >= '0' && h[i] <= '9' || h[i] == '.' || h[i] == ':'))
			return 0;
	return 1;
}

# A cookie's name or value as it can be sent: nothing a header refuses
# (validheadervalue), which would refuse every request it went with.
cookietext(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < ' ' || s[i] == 16r7F)
			return 0;
	return 1;
}

# Names sites are registered under, which no site may set a cookie for.
# There is no Public Suffix List in the tree (it is some 15000 lines and
# changes weekly); this is the part of it that can be carried:
# - a name of one label (com, uk, localhost);
# - under a country's two-letter domain, the second-level labels
#   registries use the world over (co.uk, com.au, ac.jp, gov.br);
# - the entries below, taken by hand from the list
#   (publicsuffix.org/list/public_suffix_list.dat): second levels the
#   rule misses, and the hosting services whose customers are each a
#   name under theirs.
# What it misses (k12.ca.us, a city's registry, a small host) is a
# domain whose customers can still set cookies for one another.
sld2 := array[] of {
	"ac", "co", "com", "edu", "go", "gob", "gouv", "gov", "govt",
	"mil", "ne", "net", "nom", "or", "org", "sch",
};

suffixes := array[] of {
	# registries
	"me.uk", "ltd.uk", "plc.uk", "nhs.uk", "police.uk",
	"ad.jp", "ed.jp", "gr.jp", "lg.jp",
	"asn.au", "id.au",
	"geek.nz", "gen.nz", "school.nz", "maori.nz", "iwi.nz",
	"firm.in", "gen.in", "ind.in", "res.in", "nic.in",
	"re.kr", "pe.kr",
	"uk.com", "us.com", "eu.com", "de.com", "gb.net", "uk.net",
	# hosting services
	"github.io", "githubusercontent.com", "gitlab.io", "codeberg.page",
	"herokuapp.com", "appspot.com", "blogspot.com", "cloudfront.net",
	"s3.amazonaws.com", "azurewebsites.net", "web.app", "firebaseapp.com",
	"netlify.app", "vercel.app", "now.sh", "pages.dev", "workers.dev",
	"glitch.me", "fly.dev", "onrender.com", "neocities.org",
	"readthedocs.io", "surge.sh", "ngrok.io", "myshopify.com", "wixsite.com",
};

publicsuffix(d: string): int
{
	dot := -1;
	ndot := 0;
	for(i := 0; i < len d; i++)
		if(d[i] == '.') {
			dot = i;
			ndot++;
		}
	if(ndot == 0)
		return 1;
	if(ndot == 1 && len d - dot - 1 == 2) {
		s := d[0:dot];
		for(i = 0; i < len sld2; i++)
			if(s == sld2[i])
				return 1;
	}
	for(i = 0; i < len suffixes; i++)
		if(d == suffixes[i])
			return 1;
	return 0;
}

# a domain name: labels with something in each
validdomain(d: string): int
{
	if(d == "" || d[0] == '.' || d[len d - 1] == '.')
		return 0;
	for(i := 1; i < len d; i++)
		if(d[i] == '.' && d[i-1] == '.')
			return 0;
	return 1;
}

hasblank(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t')
			return 1;
	return 0;
}

# case folded: whether s begins with p (lower case)
hasprefix(s, p: string): int
{
	return len s >= len p && str->tolower(s[0:len p]) == p;
}

pathmatch(rpath, cpath: string): int
{
	if(rpath == cpath)
		return 1;
	if(len rpath > len cpath && rpath[0:len cpath] == cpath)
		return cpath[len cpath - 1] == '/' || rpath[len cpath] == '/';
	return 0;
}

# the default path: the request path up to its last '/'
defaultpath(p: string): string
{
	if(p == "" || p[0] != '/')
		return "/";
	for(i := len p - 1; i > 0; i--)
		if(p[i] == '/')
			return p[0:i];
	return "/";
}

Jar.header(j: self ref Jar, u: string): string
{
	j.lk <-= 1;
	r := jarheader(j, u);
	<-j.lk;
	return r;
}

jarheader(j: ref Jar, u: string): string
{
	(scheme, host, path) := urlparts(u);
	if(host == nil)
		return nil;
	t := now();
	r := "";
	keep: list of ref Cookie;
	for(l := j.cookies; l != nil; l = tl l) {
		c := hd l;
		if(c.expires != 0 && c.expires <= t)
			continue;	# expired: dropped
		keep = c :: keep;
		if(c.hostonly && host != c.domain || !c.hostonly && !domainmatch(host, c.domain))
			continue;
		if(!pathmatch(path, c.path))
			continue;
		if(c.secure && scheme != "https")
			continue;	# never in clear
		if(r != "")
			r += "; ";
		r += c.name + "=" + c.value;
	}
	j.cookies = nil;
	for(; keep != nil; keep = tl keep)
		j.cookies = hd keep :: j.cookies;
	if(r == "")
		return nil;
	return r;
}

Jar.set(j: self ref Jar, u, sc: string)
{
	j.lk <-= 1;
	jarset(j, u, sc);
	<-j.lk;
}

jarset(j: ref Jar, u, sc: string)
{
	(scheme, host, path) := urlparts(u);
	if(host == nil)
		return;
	for(i := 0; i < len sc; i++)
		if(sc[i] < ' ' && sc[i] != '\t' || sc[i] == 16r7F)
			return;
	(nil, parts) := sys->tokenize(sc, ";");
	if(parts == nil)
		return;
	nv := trimsp(hd parts);
	eq := -1;
	for(i = 0; i < len nv; i++)
		if(nv[i] == '=') {
			eq = i;
			break;
		}
	if(eq <= 0)
		return;
	c := ref Cookie(trimsp(nv[0:eq]), trimsp(nv[eq+1:]), host, defaultpath(path), 1, 0, 0, 0);
	if(c.name == "" || !cookietext(c.name) || !cookietext(c.value) || len c.name + len c.value > MAXCOOKIE)
		return;
	maxage := 0;
	hasmaxage := 0;
	haspath := 0;
	dom: string;	# the last Domain attribute is the one
	for(parts = tl parts; parts != nil; parts = tl parts) {
		a := trimsp(hd parts);
		k := a;
		v := "";
		for(i = 0; i < len a; i++)
			if(a[i] == '=') {
				k = trimsp(a[0:i]);
				v = trimsp(a[i+1:]);
				break;
			}
		if(len v > MAXATTR)
			continue;
		case str->tolower(k) {
		"domain" =>
			d := str->tolower(v);
			if(len d > 0 && d[0] == '.')
				d = d[1:];
			dom = d;
		"path" =>
			# (a blank in it: no request's path has one, and
			# text() could not write it)
			if(len v > 0 && v[0] == '/' && !hasblank(v)) {
				c.path = v;
				haspath = 1;
			}
		"max-age" =>
			(ok, n) := cookieage(v);
			if(ok) {
				hasmaxage = 1;
				maxage = n;
			}
		"expires" =>
			if(now() != 0) {
				tm := daytime->string2tm(v);
				if(tm != nil)
					c.expires = daytime->tm2epoch(tm);
			}
		"secure" =>
			c.secure = 1;
		"httponly" =>
			c.httponly = 1;
		}
	}
	if(hasmaxage) {
		if(maxage <= 0)
			c.expires = 1;	# in the past: delete
		else
			c.expires = now() + maxage;
	}
	if(dom != nil) {
		if(!validdomain(dom))
			return;
		if(publicsuffix(dom) || isip(dom)) {
			if(dom != host)
				return;	# a cookie for every site under it
			# its own name: this host's alone
		} else {
			if(!domainmatch(host, dom))
				return;	# a cookie for some other site
			c.domain = dom;
			c.hostonly = 0;
		}
	}
	if(hasprefix(c.name, "__secure-") && !c.secure)
		return;
	if(hasprefix(c.name, "__host-") && !(c.secure && c.hostonly && haspath && c.path == "/"))
		return;
	t := now();
	if(scheme != "https") {
		if(c.secure)
			return;
		# nor one that would be sent where a Secure cookie of its
		# name is: it would replace it, delete it, or shadow it
		for(l := j.cookies; l != nil; l = tl l) {
			o := hd l;
			if(o.secure && o.name == c.name && (o.expires == 0 || o.expires > t) &&
			   (domainmatch(o.domain, c.domain) || domainmatch(c.domain, o.domain)) &&
			   pathmatch(c.path, o.path))
				return;
		}
	}
	# replace any cookie with the same name, domain and path
	keep: list of ref Cookie;
	for(l := j.cookies; l != nil; l = tl l) {
		o := hd l;
		if(o.name == c.name && o.domain == c.domain && o.hostonly == c.hostonly && o.path == c.path)
			continue;
		keep = o :: keep;
	}
	if(c.expires == 0 || c.expires > t)
		keep = c :: keep;
	j.cookies = nil;
	for(; keep != nil; keep = tl keep)
		j.cookies = hd keep :: j.cookies;
	jarlimit(j, c.domain);
}

# Max-Age's seconds: (whether it is a number, the number, no more than
# a cookie is kept).  Text that was no number was 0, which deletes.
cookieage(v: string): (int, int)
{
	i := 0;
	if(len v > 0 && v[0] == '-')
		i = 1;
	if(i == len v)
		return (0, 0);
	for(k := i; k < len v; k++)
		if(v[k] < '0' || v[k] > '9')
			return (0, 0);
	if(i == 1)
		return (1, 0);
	if(len v > 9)
		return (1, MAXAGE);
	n := int v;
	if(n > MAXAGE)
		n = MAXAGE;
	return (1, n);
}

# No more than MAXPERDOMAIN cookies for domain and MAXCOOKIES in all:
# the oldest (the first in the list) go.
jarlimit(j: ref Jar, domain: string)
{
	nd := 0;
	n := 0;
	for(l := j.cookies; l != nil; l = tl l) {
		n++;
		if((hd l).domain == domain)
			nd++;
	}
	if(nd <= MAXPERDOMAIN && n <= MAXCOOKIES)
		return;
	keep: list of ref Cookie;
	for(l = j.cookies; l != nil; l = tl l) {
		o := hd l;
		if(nd > MAXPERDOMAIN && o.domain == domain) {
			nd--;
			n--;
			continue;
		}
		if(n > MAXCOOKIES) {
			n--;
			continue;
		}
		keep = o :: keep;
	}
	j.cookies = nil;
	for(; keep != nil; keep = tl keep)
		j.cookies = hd keep :: j.cookies;
}

Jar.text(j: self ref Jar): string
{
	j.lk <-= 1;
	r := jartext(j);
	<-j.lk;
	return r;
}

jartext(j: ref Jar): string
{
	s := "";
	for(l := j.cookies; l != nil; l = tl l) {
		c := hd l;
		s += sys->sprint("%s %s %s=%s %d %d %d %d\n", c.domain, c.path, c.name, c.value,
			c.expires, c.secure, c.httponly, c.hostonly);
	}
	return s;
}

Jar.add(j: self ref Jar, line: string): string
{
	j.lk <-= 1;
	r := jaradd(j, line);
	<-j.lk;
	return r;
}

# A line of text(): "domain path name=value expires secure httponly
# hostonly", the four numbers optional when written by hand.  A value
# may hold blanks ("a=b c"); a line of more than seven fields ends in
# its four numbers and what lies between the path and them is the
# cookie.  (Its second word was read as the expiry and the rest as the
# flags, so a host's cookie "x=y 0 0 0 0" came back as one for every
# name under the host.)  What a response could not have set is refused
# here too, and a cookie for a name sites are registered under is that
# host's alone.
jaradd(j: ref Jar, line: string): string
{
	(n, f) := sys->tokenize(line, " \t");
	if(n < 3)
		return "bad cookie line: want domain path name=value [expires secure httponly hostonly]";
	dom := str->tolower(hd f);
	path := hd tl f;
	nv := hd tl tl f;
	f = tl tl tl f;
	for(n -= 3; n > 4; n--) {
		nv += " " + hd f;
		f = tl f;
	}
	for(i := 0; i < len nv; i++)
		if(nv[i] == '=')
			break;
	if(i == 0 || i == len nv)
		return "bad cookie: want name=value";
	c := ref Cookie(nv[0:i], nv[i+1:], dom, path, 0, 0, 0, 0);
	if(f != nil) {
		c.expires = int hd f;
		f = tl f;
	}
	if(f != nil) {
		c.secure = int hd f;
		f = tl f;
	}
	if(f != nil) {
		c.httponly = int hd f;
		f = tl f;
	}
	if(f != nil)
		c.hostonly = int hd f;
	if(!cookietext(c.name) || !cookietext(c.value) || !cookietext(path) || len c.name + len c.value > MAXCOOKIE)
		return "bad cookie: a control character, or too long";
	if(!validdomain(dom))
		return "bad cookie: not a domain: " + dom;
	if(publicsuffix(dom) || isip(dom))
		c.hostonly = 1;	# never one for every site under it
	keep: list of ref Cookie;
	for(l := j.cookies; l != nil; l = tl l) {
		o := hd l;
		if(!(o.name == c.name && o.domain == c.domain && o.hostonly == c.hostonly && o.path == c.path))
			keep = o :: keep;
	}
	j.cookies = c :: nil;
	for(; keep != nil; keep = tl keep)
		j.cookies = hd keep :: j.cookies;
	jarlimit(j, c.domain);
	return nil;
}

Jar.clear(j: self ref Jar)
{
	j.lk <-= 1;
	jarclear(j);
	<-j.lk;
}

jarclear(j: ref Jar)
{
	j.cookies = nil;
}

trimsp(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	e := len s;
	while(e > i && (s[e-1] == ' ' || s[e-1] == '\t'))
		e--;
	return s[i:e];
}
