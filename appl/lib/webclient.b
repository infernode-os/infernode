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

	cfg := tls->defaultconfig();
	cfg.servername = servername;

	(conn, terr) := tls->client(c.dfd, cfg);
	if(terr != nil)
		return (nil, "tls: " + terr);

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
	for(;;) {
		n := conn.read(buf, len buf);
		if(n <= 0)
			break;
		if(sys->write(fd, buf[:n], n) != n)
			break;
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
	return request0(method, requrl, hdrs, body, 0, nil);
}

requestpublic(method, requrl: string, hdrs: list of Header, body: array of byte): (ref Response, string)
{
	return request0(method, requrl, hdrs, body, 1, nil);
}

requestjar(method, requrl: string, hdrs: list of Header, body: array of byte, jar: ref Jar): (ref Response, string)
{
	(resp, err) := request0(method, requrl, hdrs, body, 0, jar);
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
request0(method, requrl: string, hdrs: list of Header, body: array of byte, public: int, jar: ref Jar): (ref Response, string)
{
	for(redir := 0; redir < MAXREDIRECTS; redir++) {
		rh := hdrs;
		if(jar != nil && (c := jar.header(requrl)) != nil)
			rh = Header("Cookie", c) :: rh;
		verr := validrequesttext(method, requrl, rh);
		if(verr != nil)
			return (nil, verr);
		(resp, err) := dorequest(method, requrl, rh, body, public);
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
	s := url->schemes[u.scheme] + "://" + u.host;
	if(port != "80" && port != "443")
		s += ":" + port;
	return s;
}

# [private]
dorequest(method, requrl: string, hdrs: list of Header, body: array of byte, public: int): (ref Response, string)
{
	u := url->makeurl(requrl);
	if(u == nil)
		return (nil, "bad url: " + requrl);

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
	return linkrequest(method, u, host, addr, ishttps, hdrs, body);
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
	buf:	array of byte;
	p, n:	int;	# buf[p:n] read and not yet taken
	idle:	int;	# sys->millisec() when it was put back
	reused:	int;

	read:	fn(l: self ref Link, a: array of byte): int;
	write:	fn(l: self ref Link, a: array of byte): int;
	getc:	fn(l: self ref Link): int;
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

Link.close(l: self ref Link)
{
	if(l.tls != nil)
		l.tls.close();
	l.tls = nil;
	l.fd = nil;
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

newlink(key, addr, host: string, ishttps: int): (ref Link, string)
{
	c := dial->dial(addr, nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s: %r", addr));
	l := ref Link(key, nil, c.dfd, array[16384] of byte, 0, 0, 0, 0);
	if(ishttps) {
		cfg := tls->defaultconfig();
		cfg.servername = host;
		(conn, terr) := tls->client(c.dfd, cfg);
		if(terr != nil)
			return (nil, "tls: " + terr);
		l.tls = conn;
	}
	return (l, nil);
}

# [private]
linkrequest(method: string, u: ref ParsedUrl, host, addr: string, ishttps: int,
	hdrs: list of Header, body: array of byte): (ref Response, string)
{
	req := array of byte buildrequest(method, u, host, hdrs, body);
	key := addr;
	if(ishttps)
		key = "tls!" + addr + "!" + host;
	for(try := 0; ; try++) {
		l: ref Link;
		if(try == 0)
			l = takelink(key);
		if(l != nil)
			l.reused = 1;
		else {
			err: string;
			(l, err) = newlink(key, addr, host, ishttps);
			if(l == nil)
				return (nil, err);
		}
		again := l.reused && try == 0 && (method == "GET" || method == "HEAD");
		if(l.write(req) != len req || body != nil && l.write(body) != len body) {
			l.close();
			if(again)
				continue;
			return (nil, "write failed");
		}
		(resp, keep, err) := readresponse(l, method);
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

# [private]
# The response to a request: its header, and its body as the header
# frames it.  Whether the connection can carry another request after.
readresponse(l: ref Link, method: string): (ref Response, int, string)
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
	clen := resp.hdrval("Content-Length");
	te := str->tolower(resp.hdrval("Transfer-Encoding"));
	code := resp.statuscode;
	if(method == "HEAD" || code == 204 || code == 304 || code < 200)
		return (resp, keep, nil);
	if(te != nil && contains(te, "chunked")) {
		ok: int;
		(resp.body, ok) = readchunked(l);
		return (resp, keep && ok, nil);
	}
	if(clen != nil) {
		nbytes := int clen;
		if(nbytes > MAXBODY) {
			nbytes = MAXBODY;
			keep = 0;
		}
		if(nbytes <= 0)
			return (resp, keep, nil);
		resp.body = array[nbytes] of byte;
		off := 0;
		while(off < nbytes) {
			n := l.read(resp.body[off:]);
			if(n <= 0)
				break;
			off += n;
		}
		if(off < nbytes) {
			resp.body = resp.body[:off];
			keep = 0;
		}
		return (resp, keep, nil);
	}
	# the body runs to the end of the connection
	chunks: list of array of byte;
	total := 0;
	rbuf := array[16384] of byte;
	while(total < MAXBODY) {
		n := l.read(rbuf);
		if(n <= 0)
			break;
		chunk := array[n] of byte;
		chunk[0:] = rbuf[:n];
		chunks = chunk :: chunks;
		total += n;
	}
	resp.body = concatchunks(chunks, total);
	return (resp, 0, nil);
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
	return (string hbuf[:hlen], nil);	# as much as came, as before
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

	# Parse "HTTP/1.1 200 OK"
	(nf, fields) := sys->tokenize(statusline, " ");
	if(nf < 2)
		return (nil, 0, "bad status line: " + statusline);
	code := int hd tl fields;
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

	resp := ref Response(code, status, headers, nil, nil);
	return (resp, bodystart, nil);
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
# A chunked body (RFC 9112 §7.1), and whether it ended as it should:
# the last chunk and the trailer section read, so that the connection
# is at the next response.
readchunked(l: ref Link): (array of byte, int)
{
	chunks: list of array of byte;
	total := 0;
	for(;;) {
		line := readline(l);
		if(line == nil)
			return (concatchunks(chunks, total), 0);
		chunksize := hexval(line);
		if(chunksize <= 0)
			break;
		trunc := 0;
		if(total + chunksize > MAXBODY) {
			chunksize = MAXBODY - total;
			trunc = 1;
		}
		chunk := array [chunksize] of byte;
		off := 0;
		while(off < chunksize) {
			n := l.read(chunk[off:]);
			if(n <= 0)
				break;
			off += n;
		}
		chunks = chunk[:off] :: chunks;
		total += off;
		if(off < chunksize || trunc)
			return (concatchunks(chunks, total), 0);
		readline(l);	# the CRLF after the data
	}
	# the trailer section, to its blank line
	for(;;) {
		line := readline(l);
		if(line == nil)
			return (concatchunks(chunks, total), 0);
		if(line == "\r\n" || line == "\n")
			break;
	}
	return (concatchunks(chunks, total), 1);
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
		n = n * 16 + d;
	}
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

# ---- cookies (RFC 6265 §5) ----

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
			continue;
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
	(nil, parts) := sys->tokenize(sc, ";");
	if(parts == nil)
		return;
	nv := trimsp(hd parts);
	eq := -1;
	for(i := 0; i < len nv; i++)
		if(nv[i] == '=') {
			eq = i;
			break;
		}
	if(eq <= 0)
		return;
	c := ref Cookie(trimsp(nv[0:eq]), trimsp(nv[eq+1:]), host, defaultpath(path), 1, 0, 0, 0);
	maxage := -1;
	hasmaxage := 0;
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
		case str->tolower(k) {
		"domain" =>
			d := str->tolower(v);
			if(len d > 0 && d[0] == '.')
				d = d[1:];
			if(d == "")
				break;
			if(!domainmatch(host, d))
				return;	# a cookie for some other site
			c.domain = d;
			c.hostonly = 0;
		"path" =>
			if(len v > 0 && v[0] == '/')
				c.path = v;
		"max-age" =>
			hasmaxage = 1;
			maxage = int v;
		"expires" =>
			if(!hasmaxage && now() != 0) {
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
	if(c.secure && scheme != "https")
		return;
	# replace any cookie with the same name, domain and path
	keep: list of ref Cookie;
	for(l := j.cookies; l != nil; l = tl l) {
		o := hd l;
		if(o.name == c.name && o.domain == c.domain && o.path == c.path)
			continue;
		keep = o :: keep;
	}
	if(c.expires == 0 || c.expires > now())
		keep = c :: keep;
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

jaradd(j: ref Jar, line: string): string
{
	(n, f) := sys->tokenize(line, " \t");
	if(n < 3)
		return "bad cookie line: want domain path name=value [expires secure httponly hostonly]";
	dom := str->tolower(hd f);
	path := hd tl f;
	nv := hd tl tl f;
	f = tl tl tl f;
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
	keep: list of ref Cookie;
	for(l := j.cookies; l != nil; l = tl l) {
		o := hd l;
		if(!(o.name == c.name && o.domain == c.domain && o.path == c.path))
			keep = o :: keep;
	}
	j.cookies = c :: nil;
	for(; keep != nil; keep = tl keep)
		j.cookies = hd keep :: j.cookies;
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
