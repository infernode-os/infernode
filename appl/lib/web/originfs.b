implement Originfs;

#
# originfs - webfs as one origin's page may use it.
#
# A page's realm sees this, not webfs, at /mnt/web (docs/JS-ENGINE.md
# §6.2).  It is started by the realm while it confines itself, forks its
# own name space (which still has webfs), and is mounted in the realm's;
# a script, or a bug in the engine, can do only what this lets through,
# because nothing else of the network is in the realm's name space.
#
#	clone		read: a request directory's number
#	cookies		the jar's cookies this origin's documents may see
#			(not HttpOnly; Secure only for an https page);
#			writing a line in webfs's form sets one for this
#			origin's host or a domain above it, never HttpOnly
#	N/ctl		written before the request: url (http or https only),
#			method, header (the Fetch standard's forbidden
#			request headers are dropped), mode (cors, no-cors or
#			same-origin; cors when not said) and credentials
#			(omit, same-origin or include; same-origin when not
#			said)
#	N/postbody	the request body
#	N/body, status, url, contenttype, header
#			the response, as webfs's, once this has let it
#			through; reading one makes the request
#
# What the realm cannot do through it: name a file: or other URL, send
# Cookie, Origin, Host or Referer of its own, read the jar's HttpOnly
# cookies, or read a response another origin did not offer it.  A
# cross-origin cors request carries this origin, is preflighted when it
# is not simple, and is given back only if the response allows this
# origin, with only the headers CORS exposes.  A cross-origin no-cors
# request (a classic script the page loads) is given back unless it is
# HTML, XML or JSON, as Opaque Response Blocking has it: a page can run
# another site's script, not read another site's documents.  Cookies go
# with a request when its credentials say so.
#
# Not done: SameSite (webfs's jar does not keep it), partitioned jars,
# Content-Security-Policy.  A redirect is judged by where it ends.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Fid: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "web/originfs.m";

# paths: 0 root, 1 clone, 2 cookies; a request's are (N << 4) | its kind
Qroot, Qclone, Qcookies: con iota;
Kdir, Kctl, Kpostbody, Kbody, Kstatus, Kurl, Kctype, Kheader: con 1 + iota;
Knames := array[] of {"", "", "ctl", "postbody", "body", "status", "url", "contenttype", "header"};

Req: adt {
	n:	int;
	url:	string;
	method:	string;
	headers:	list of string;	# "Name: value", most recent first
	mode:	string;
	creds:	string;
	post:	array of byte;
	started:	int;
	done:	int;
	opens:	int;
	pending:	list of ref Tmsg.Read;
	# the response, once done
	status:	string;
	rurl:	string;
	ctype:	string;
	header:	string;
	body:	array of byte;
};

pageorigin: string;
pagehttps := 0;
webfs: string;
reqs: array of ref Req;
nreq := 0;
user := "web";

serve(fd: ref Sys->FD, o: string, w: string, ready: chan of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	if(styx == nil || styxservers == nil || nametree == nil) {
		ready <-= sys->sprint("originfs: cannot load its modules: %r");
		return;
	}
	styx->init();
	styxservers->init(styx);
	nametree->init();
	# the realm changes its name space next: this keeps its own, and
	# none of the realm's descriptors
	sys->pctl(Sys->FORKNS, nil);
	sys->pctl(Sys->NEWFD, fd.fd :: nil);
	pageorigin = o;
	pagehttps = len o > 8 && o[0:8] == "https://";
	webfs = w;
	reqs = array[16] of ref Req;
	(tree, treeop) := nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot, dir("clone", 8r444, Qclone));
	tree.create(big Qroot, dir("cookies", 8r666, Qcookies));
	(tc, srv) := Styxserver.new(fd, Navigator.new(treeop), big Qroot);
	ready <-= nil;
	donec := chan of ref Req;
	for(;;) alt {
	m := <-tc =>
		if(m == nil) {
			tree.quit();
			return;
		}
		pick tm := m {
		Readerror =>
			tree.quit();
			return;
		* =>
			tmsg(srv, tree, m, donec);
		}
	r := <-donec =>
		r.done = 1;
		for(l := r.pending; l != nil; l = tl l)
			answer(srv, r, hd l);
		r.pending = nil;
		release(tree, r);
	}
}

dir(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

reqof(path: big): (ref Req, int)
{
	p := int path;
	n := p >> 4;
	if(n < 1 || n > nreq || reqs[n] == nil)
		return (nil, 0);
	return (reqs[n], p & 16rF);
}

tmsg(srv: ref Styxserver, tree: ref Tree, m: ref Tmsg, donec: chan of ref Req)
{
	pick tm := m {
	Open =>
		f := srv.open(tm);
		if(f != nil) {
			(r, nil) := reqof(f.path);
			if(r != nil && f.path > big 16)
				r.opens++;
		}
	Clunk =>
		f := srv.getfid(tm.fid);
		if(f != nil && f.isopen) {
			(r, nil) := reqof(f.path);
			if(r != nil) {
				r.opens--;
				srv.clunk(tm);
				release(tree, r);
				return;
			}
		}
		srv.clunk(tm);
	Read =>
		(f, err) := srv.canread(tm);
		if(f == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, err));
			return;
		}
		if(f.qtype & Sys->QTDIR) {
			srv.read(tm);
			return;
		}
		case int f.path {
		Qclone =>
			r := newreq(tree);
			if(r == nil) {
				srv.reply(ref Rmsg.Error(tm.tag, "originfs: cannot make a request"));
				return;
			}
			srv.reply(styxservers->readstr(tm, string r.n));
			return;
		Qcookies =>
			srv.reply(styxservers->readstr(tm, cookiesread()));
			return;
		}
		(r, k) := reqof(f.path);
		if(r == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, styxservers->Enotfound));
			return;
		}
		case k {
		Kctl =>
			srv.reply(styxservers->readstr(tm, ctltext(r)));
		Kpostbody =>
			srv.reply(styxservers->readbytes(tm, r.post));
		* =>
			if(r.done) {
				answer(srv, r, tm);
				return;
			}
			r.pending = tm :: r.pending;
			if(!r.started) {
				r.started = 1;
				spawn perform(r, donec);
			}
		}
	Write =>
		(f, err) := srv.canwrite(tm);
		if(f == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, err));
			return;
		}
		if(int f.path == Qcookies) {
			if((e := cookieswrite(string tm.data)) != nil)
				srv.reply(ref Rmsg.Error(tm.tag, e));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			return;
		}
		(r, k) := reqof(f.path);
		if(r == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, styxservers->Eperm));
			return;
		}
		if(r.started) {
			srv.reply(ref Rmsg.Error(tm.tag, "originfs: the request is made"));
			return;
		}
		case k {
		Kctl =>
			if((e := ctl(r, string tm.data)) != nil)
				srv.reply(ref Rmsg.Error(tm.tag, e));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		Kpostbody =>
			if(r.post == nil)
				r.post = array[0] of byte;
			off := int tm.offset;
			if(off < 0 || off > len r.post)
				off = len r.post;
			nb := array[off + len tm.data] of byte;
			nb[0:] = r.post[0:off];
			nb[off:] = tm.data;
			r.post = nb;
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, styxservers->Eperm));
		}
	Flush =>
		for(i := 1; i <= nreq; i++) {
			r := reqs[i];
			if(r == nil)
				continue;
			kept: list of ref Tmsg.Read;
			for(l := r.pending; l != nil; l = tl l)
				if((hd l).tag != tm.oldtag)
					kept = hd l :: kept;
			r.pending = kept;
		}
		srv.reply(ref Rmsg.Flush(tm.tag));
	* =>
		srv.default(m);
	}
}

newreq(tree: ref Tree): ref Req
{
	n := nreq + 1;
	if(n >= len reqs) {
		a := array[2 * len reqs] of ref Req;
		a[0:] = reqs;
		reqs = a;
	}
	q := n << 4;
	if(tree.create(big Qroot, dir(string n, Sys->DMDIR|8r555, q | Kdir)) != nil)
		return nil;
	for(k := Kctl; k <= Kheader; k++) {
		perm := 8r444;
		if(k == Kctl || k == Kpostbody)
			perm = 8r666;
		tree.create(big (q | Kdir), dir(Knames[k], perm, q | k));
	}
	nreq = n;
	r := ref Req(n, nil, "GET", nil, "cors", "same-origin", nil, 0, 0, 0, nil, nil, nil, nil, nil, nil);
	reqs[n] = r;
	return r;
}

# a request done with, and no file of it open, is let go
release(tree: ref Tree, r: ref Req)
{
	if(!r.done || r.opens > 0 || r.pending != nil)
		return;
	q := r.n << 4;
	for(k := Kctl; k <= Kheader; k++)
		tree.remove(big (q | k));
	tree.remove(big (q | Kdir));
	reqs[r.n] = nil;
}

answer(srv: ref Styxserver, r: ref Req, m: ref Tmsg.Read)
{
	f := srv.getfid(m.fid);
	if(f == nil) {
		srv.reply(ref Rmsg.Error(m.tag, styxservers->Ebadfid));
		return;
	}
	(nil, k) := reqof(f.path);
	case k {
	Kbody =>
		srv.reply(styxservers->readbytes(m, r.body));
	Kstatus =>
		srv.reply(styxservers->readstr(m, r.status + "\n"));
	Kurl =>
		srv.reply(styxservers->readstr(m, r.rurl + "\n"));
	Kctype =>
		srv.reply(styxservers->readstr(m, r.ctype + "\n"));
	Kheader =>
		srv.reply(styxservers->readstr(m, r.header));
	* =>
		srv.reply(ref Rmsg.Error(m.tag, styxservers->Eperm));
	}
}

ctltext(r: ref Req): string
{
	s := "url " + r.url + "\nmethod " + r.method + "\nmode " + r.mode + "\ncredentials " + r.creds + "\n";
	for(l := rev(r.headers); l != nil; l = tl l)
		s += "header " + hd l + "\n";
	return s;
}

ctl(r: ref Req, s: string): string
{
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines) {
		ln := trim(hd lines);
		(verb, arg) := splitword(ln);
		case verb {
		"url" =>
			case lower(scheme(arg)) {
			"http" or "https" =>
				r.url = arg;
			* =>
				return "originfs: not an http or https URL";
			}
		"method" =>
			m := upper(arg);
			case m {
			"GET" or "HEAD" or "POST" or "PUT" or "DELETE" or "PATCH" or "OPTIONS" =>
				r.method = m;
			* =>
				return "originfs: method not allowed";
			}
		"header" =>
			(name, nil) := splitheader(arg);
			if(name == nil)
				return "originfs: bad header";
			if(!forbidden(lower(name)))
				r.headers = arg :: r.headers;
		"mode" =>
			case arg {
			"cors" or "no-cors" or "same-origin" =>
				r.mode = arg;
			* =>
				return "originfs: bad mode";
			}
		"credentials" =>
			case arg {
			"omit" or "same-origin" or "include" =>
				r.creds = arg;
			* =>
				return "originfs: bad credentials";
			}
		"cookies" =>
			# webfs's form: off is omit, on is include
			case arg {
			"off" =>
				r.creds = "omit";
			"on" =>
				r.creds = "include";
			* =>
				return "originfs: bad cookies";
			}
		"" =>
			;
		* =>
			return "originfs: unknown ctl " + verb;
		}
	}
	return nil;
}

# the Fetch standard's forbidden request headers
forbidden(n: string): int
{
	case n {
	"accept-charset" or "accept-encoding" or "access-control-request-headers" or
	"access-control-request-method" or "connection" or "content-length" or "cookie" or
	"cookie2" or "date" or "dnt" or "expect" or "host" or "keep-alive" or "origin" or
	"referer" or "set-cookie" or "te" or "trailer" or "transfer-encoding" or "upgrade" or
	"via" =>
		return 1;
	}
	return prefix(n, "proxy-") || prefix(n, "sec-");
}

# ---- the request ----

Resp: adt {
	status:	string;	# "200 HTTP/1.1 200 OK", or "error: why"
	url:	string;
	ctype:	string;
	header:	string;
	body:	array of byte;
};

perform(r: ref Req, donec: chan of ref Req)
{
	{
		perform1(r);
	} exception e {
	"*" =>
		r.status = "error: originfs: " + e;
		r.body = nil;
		r.header = "";
	}
	donec <-= r;
}

perform1(r: ref Req)
{
	if(r.url == nil) {
		fail(r, "no url");
		return;
	}
	same := origin(r.url) == pageorigin;
	if(!same && r.mode == "same-origin") {
		fail(r, "cross-origin request in same-origin mode");
		return;
	}
	creds := r.creds == "include";
	cookies := creds || r.creds == "same-origin" && same;
	headers := rev(r.headers);
	cors := !same && r.mode == "cors";
	simple := r.method == "GET" || r.method == "HEAD" || r.method == "POST";
	if(!same && r.mode == "no-cors" && !simple) {
		fail(r, "no-cors needs a simple method");
		return;
	}
	if(cors) {
		extra: list of string;
		for(l := headers; l != nil; l = tl l) {
			(n, v) := splitheader(hd l);
			n = lower(n);
			if(!safeheader(n, v))
				extra = n :: extra;
		}
		if(!simple || extra != nil) {
			pre := "Origin: " + pageorigin :: "Access-Control-Request-Method: " + r.method :: nil;
			if(extra != nil)
				pre = "Access-Control-Request-Headers: " + join(sort(extra), ",") :: pre;
			p := fetch(r.url, "OPTIONS", pre, 0, nil);
			if(!preflightok(p, r.method, extra, creds)) {
				fail(r, "blocked by CORS: the preflight to " + r.url + " did not allow it");
				return;
			}
		}
	}
	if(cors || !(r.method == "GET" || r.method == "HEAD"))
		headers = "Origin: " + pageorigin :: headers;
	resp := fetch(r.url, r.method, headers, cookies, r.post);
	if(prefix(resp.status, "error:")) {
		r.status = resp.status;
		return;
	}
	if(resp.url == nil)
		resp.url = r.url;
	if(origin(resp.url) != pageorigin) {
		case r.mode {
		"same-origin" =>
			fail(r, "redirected to another origin in same-origin mode");
			return;
		"no-cors" =>
			if(orbblocks(resp.ctype, resp.body)) {
				fail(r, "blocked: " + resp.url + " is another origin's " + essence(resp.ctype));
				return;
			}
			resp.header = "Content-Type: " + resp.ctype + "\n";
		* =>
			if(!corsok(resp.header, creds)) {
				fail(r, "blocked by CORS: " + resp.url + " does not allow " + pageorigin);
				return;
			}
			resp.header = exposed(resp.header);
		}
	}
	r.status = resp.status;
	r.rurl = resp.url;
	r.ctype = resp.ctype;
	r.header = resp.header;
	r.body = resp.body;
}

fail(r: ref Req, why: string)
{
	r.status = "error: " + why;
	r.rurl = r.url;
	r.ctype = "";
	r.header = "";
	r.body = nil;
}

# one request through webfs
fetch(url, method: string, headers: list of string, cookies: int, post: array of byte): ref Resp
{
	resp := ref Resp("", url, "", "", nil);
	cfd := sys->open(webfs + "/clone", Sys->OREAD);
	if(cfd == nil) {
		resp.status = sys->sprint("error: no network: %r");
		return resp;
	}
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0) {
		resp.status = sys->sprint("error: webfs clone: %r");
		return resp;
	}
	d := webfs + "/" + trim(string buf[0:n]);
	ctl := sys->open(d + "/ctl", Sys->OWRITE);
	if(ctl == nil || sys->fprint(ctl, "url %s", url) < 0) {
		resp.status = sys->sprint("error: webfs: %r");
		return resp;
	}
	if(method != "GET" && sys->fprint(ctl, "method %s", method) < 0) {
		resp.status = sys->sprint("error: webfs: method %s: %r", method);
		return resp;
	}
	if(!cookies && sys->fprint(ctl, "cookies off") < 0) {
		resp.status = sys->sprint("error: webfs: cookies off: %r");
		return resp;
	}
	for(; headers != nil; headers = tl headers)
		if(sys->fprint(ctl, "header %s", hd headers) < 0) {
			resp.status = sys->sprint("error: webfs: header: %r");
			return resp;
		}
	if(post != nil) {
		pfd := sys->open(d + "/postbody", Sys->OWRITE);
		if(pfd == nil || sys->write(pfd, post, len post) != len post) {
			resp.status = sys->sprint("error: webfs postbody: %r");
			return resp;
		}
	}
	if((bfd := sys->open(d + "/body", Sys->OREAD)) != nil)
		resp.body = readall(bfd);
	resp.status = readline(d + "/status");
	resp.url = readline(d + "/url");
	resp.ctype = readline(d + "/contenttype");
	if((hfd := sys->open(d + "/header", Sys->OREAD)) != nil)
		resp.header = string readall(hfd);
	return resp;
}

statuscode(s: string): int
{
	(nil, l) := sys->tokenize(s, " ");
	if(l == nil)
		return 0;
	return int hd l;
}

# ---- CORS ----

safeheader(n, v: string): int
{
	case n {
	"accept" or "accept-language" or "content-language" =>
		return 1;
	"content-type" =>
		case essence(v) {
		"application/x-www-form-urlencoded" or "multipart/form-data" or "text/plain" =>
			return 1;
		}
	}
	return 0;
}

corsok(header: string, creds: int): int
{
	acao := headerval(header, "access-control-allow-origin");
	if(acao == "*")
		return !creds;
	if(acao != pageorigin)
		return 0;
	return !creds || headerval(header, "access-control-allow-credentials") == "true";
}

preflightok(p: ref Resp, method: string, extra: list of string, creds: int): int
{
	c := statuscode(p.status);
	if(prefix(p.status, "error:") || c < 200 || c >= 300 || !corsok(p.header, creds))
		return 0;
	if(method != "GET" && method != "HEAD" && method != "POST") {
		ms := commalist(upper(headerval(p.header, "access-control-allow-methods")));
		if(!member(method, ms) && !(member("*", ms) && !creds))
			return 0;
	}
	hs := commalist(lower(headerval(p.header, "access-control-allow-headers")));
	for(; extra != nil; extra = tl extra) {
		x := hd extra;
		if(!member(x, hs) && !(member("*", hs) && !creds && x != "authorization"))
			return 0;
	}
	return 1;
}

# the response headers a cross-origin script may read: the safelisted and
# those Access-Control-Expose-Headers names
exposed(header: string): string
{
	ex := commalist(lower(headerval(header, "access-control-expose-headers")));
	s := "";
	(nil, lines) := sys->tokenize(header, "\n");
	for(; lines != nil; lines = tl lines) {
		(n, nil) := splitheader(hd lines);
		n = lower(n);
		case n {
		"cache-control" or "content-language" or "content-length" or "content-type" or
		"expires" or "last-modified" or "pragma" =>
			s += hd lines + "\n";
		* =>
			if(member(n, ex) || member("*", ex) && n != "set-cookie" && n != "set-cookie2")
				s += hd lines + "\n";
		}
	}
	return s;
}

# Opaque Response Blocking, simply: another origin's HTML, XML or JSON
# is not given to a no-cors request, by its type or by what it begins with
orbblocks(ctype: string, body: array of byte): int
{
	e := essence(ctype);
	if(e == "text/html" || e == "application/json" || e == "text/json" || e == "text/xml" ||
	   e == "application/xml" || suffix(e, "+json") || suffix(e, "+xml") && e != "image/svg+xml")
		return 1;
	case e {
	"" or "text/plain" or "application/octet-stream" =>
		i := 0;
		if(len body >= 3 && body[0] == byte 16rEF && body[1] == byte 16rBB && body[2] == byte 16rBF)
			i = 3;
		while(i < len body && (body[i] == byte ' ' || body[i] == byte '\t' || body[i] == byte '\n' || body[i] == byte '\r'))
			i++;
		head := lower(string body[i:min(i + 16, len body)]);
		return prefix(head, "<!doctype html") || prefix(head, "<html") || prefix(head, "<head") ||
			prefix(head, "<body") || prefix(head, "{\"") || prefix(head, ")]}'");
	}
	return 0;
}

# ---- cookies ----
#
# webfs's jar lines: domain path name=value expires secure httponly hostonly

pagehost(): string
{
	s := pageorigin;
	for(i := 0; i + 2 < len s; i++)
		if(s[i:i+3] == "://") {
			s = s[i+3:];
			break;
		}
	for(i = len s - 1; i >= 0; i--)
		if(s[i] == ':')
			return s[0:i];
		else if(s[i] < '0' || s[i] > '9')
			break;
	return s;
}

domainmatch(host, domain: string, hostonly: int): int
{
	if(host == domain)
		return 1;
	return !hostonly && len host > len domain + 1 && suffix(host, "." + domain);
}

cookiesread(): string
{
	if(pageorigin == "null")
		return "";
	fd := sys->open(webfs + "/cookies", Sys->OREAD);
	if(fd == nil)
		return "";
	host := pagehost();
	s := "";
	(nil, lines) := sys->tokenize(string readall(fd), "\n");
	for(; lines != nil; lines = tl lines) {
		(n, f) := sys->tokenize(hd lines, " ");
		if(n < 7)
			continue;
		a := array[n] of string;
		for(i := 0; f != nil; f = tl f)
			a[i++] = hd f;
		if(a[5] != "0" || a[4] != "0" && !pagehttps || !domainmatch(host, a[0], a[6] != "0"))
			continue;
		s += hd lines + "\n";
	}
	return s;
}

cookieswrite(s: string): string
{
	if(pageorigin == "null")
		return "originfs: this page has no cookies";
	host := pagehost();
	(nil, lines) := sys->tokenize(s, "\n");
	out := "";
	for(; lines != nil; lines = tl lines) {
		(n, f) := sys->tokenize(hd lines, " ");
		if(n != 7)
			return "originfs: bad cookie line";
		a := array[n] of string;
		for(i := 0; f != nil; f = tl f)
			a[i++] = hd f;
		dom := lower(a[0]);
		if(prefix(dom, "."))
			dom = dom[1:];
		hostonly := a[6] != "0";
		# a domain above the host, not a top-level one
		if(!domainmatch(host, dom, hostonly) || !hostonly && dom != host && !contains(dom, '.'))
			return "originfs: not this origin's cookie";
		if(a[5] != "0")
			return "originfs: a script cannot set an HttpOnly cookie";
		if(a[4] != "0" && !pagehttps)
			return "originfs: a Secure cookie needs an https page";
		a[0] = dom;
		ln := a[0];
		for(i = 1; i < n; i++)
			ln += " " + a[i];
		out += ln + "\n";
	}
	fd := sys->open(webfs + "/cookies", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("originfs: cookies: %r");
	b := array of byte out;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("originfs: cookies: %r");
	return nil;
}

# ---- origins ----

origin(url: string): string
{
	sch := lower(scheme(url));
	if(sch != "http" && sch != "https")
		return "null";
	s := url[len sch + 1:];
	if(!prefix(s, "//"))
		return "null";
	s = s[2:];
	for(i := 0; i < len s; i++)
		if(s[i] == '/' || s[i] == '?' || s[i] == '#' || s[i] == '\\')
			break;
	auth := s[0:i];
	for(i = len auth - 1; i >= 0; i--)
		if(auth[i] == '@') {
			auth = auth[i+1:];
			break;
		}
	auth = lower(auth);
	host := auth;
	port := "";
	if(!prefix(auth, "[") || contains(auth, ']')) {
		for(i = len auth - 1; i >= 0 && auth[i] != ']'; i--)
			if(auth[i] == ':') {
				host = auth[0:i];
				port = auth[i+1:];
				break;
			}
	}
	if(port == "" || sch == "http" && port == "80" || sch == "https" && port == "443")
		return sch + "://" + host;
	return sch + "://" + host + ":" + port;
}

# ---- text ----

scheme(url: string): string
{
	for(i := 0; i < len url; i++) {
		c := url[i];
		if(c == ':')
			return url[0:i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')))
			break;
	}
	return "";
}

essence(ctype: string): string
{
	for(i := 0; i < len ctype; i++)
		if(ctype[i] == ';')
			break;
	return lower(trim(ctype[0:i]));
}

headerval(header, name: string): string
{
	(nil, lines) := sys->tokenize(header, "\n");
	for(; lines != nil; lines = tl lines) {
		(n, v) := splitheader(hd lines);
		if(lower(n) == name)
			return v;
	}
	return "";
}

splitheader(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ':')
			return (trim(s[0:i]), trim(s[i+1:]));
	return (nil, nil);
}

splitword(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			return (s[0:i], trim(s[i+1:]));
	return (s, "");
}

commalist(s: string): list of string
{
	r: list of string;
	(nil, l) := sys->tokenize(s, ",");
	for(; l != nil; l = tl l)
		if((t := trim(hd l)) != "")
			r = t :: r;
	return r;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

join(l: list of string, sep: string): string
{
	s := "";
	for(; l != nil; l = tl l) {
		if(s != "")
			s += sep;
		s += hd l;
	}
	return s;
}

sort(l: list of string): list of string
{
	a := array[len l] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	for(i = 1; i < len a; i++)
		for(j := i; j > 0 && a[j] < a[j-1]; j--)
			(a[j], a[j-1]) = (a[j-1], a[j]);
	r: list of string;
	for(i = len a - 1; i >= 0; i--)
		r = a[i] :: r;
	return r;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

upper(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'a' && s[i] <= 'z')
			s[i] -= 'a' - 'A';
	return s;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

suffix(s, p: string): int
{
	return len s >= len p && s[len s - len p:] == p;
}

contains(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

readline(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	return trim(string readall(fd));
}

readall(fd: ref Sys->FD): array of byte
{
	buf := array[8192] of byte;
	n := 0;
	for(;;) {
		if(n == len buf) {
			nb := array[2 * len buf] of byte;
			nb[0:] = buf;
			buf = nb;
		}
		k := sys->read(fd, buf[n:], len buf - n);
		if(k <= 0)
			break;
		n += k;
	}
	return buf[0:n];
}
