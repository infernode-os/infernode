implement Webfs;

#
# webfs - Multi-Connection HTTP Filesystem
#
# Plan 9-style Styx server exposing HTTP as a filesystem with
# clone-based multiplexing for concurrent connections.
#
# Filesystem layout:
#   /mnt/web/
#       clone           read: allocates connection N, returns "N\n"
#       ctl             read/write: global config (useragent)
#       cookies         read: the cookie jar, one cookie per line;
#                       write: a line in the same form, or "clear"
#       N/              per-connection directory
#           ctl         write: "url https://...", "method POST", "header Key: Value"
#           body        open triggers HTTP fetch; read returns response body
#           postbody    write: POST request body (before opening body)
#           contenttype read: response Content-Type header
#           status      read: "200 OK" or "error: ..."
#           url         read: the URL that answered, after redirects
#           header      read: the response header, "Name: value" per line
#           parsed/     subdirectory of parsed URL components
#               url scheme host port path query fragment
#
# Usage:
#   webfs /mnt/web
#   cat /mnt/web/clone              # → "1"
#   echo 'url https://example.com' > /mnt/web/1/ctl
#   cat /mnt/web/1/body             # → HTML content
#   cat /mnt/web/1/status           # → "200 OK"
#
# Fetches run concurrently: a request that needs a response waits for
# its own connection's fetch, not for anyone else's.  All connections
# share one cookie jar, so webfs is one browsing session.  Bodies sent
# gzip, deflate or brotli encoded arrive decoded.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

include "webclient.m";
	webclient: Webclient;
	Response, Header, Jar: import webclient;

include "url.m";
	urlmod: Url;
	ParsedUrl: import urlmod;

Webfs: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# File types (low byte of qid path)
Qroot: con 0;
Qclone: con 1;
Qgctl: con 2;
# Per-connection files start at 16
Qconndir: con 16;
Qctl: con 17;
Qbody: con 18;
Qpostbody: con 19;
Qcontenttype: con 20;
Qstatus: con 21;
# Parsed URL subdirectory
Qparseddir: con 22;
Qpurl: con 23;
Qpscheme: con 24;
Qphost: con 25;
Qpport: con 26;
Qppath: con 27;
Qpquery: con 28;
Qpfragment: con 29;
Qurl: con 30;
Qheader: con 31;
Qcookies: con 3;

# Per-connection state
ConnState: adt {
	id:          int;
	url:         string;
	method:      string;
	headers:     list of Header;
	postdata:    array of byte;
	resp:        ref Response;
	status:      string;
	fetched:     int;
	contenttype: string;
	gen:         int;               # bumped when the request changes
	fetching:    int;               # a fetch for gen is running
	pending:     list of ref Tmsg;  # waiting for it, newest first
	nopen:       int;               # open fids on its files
	nocookies:   int;               # "cookies off": the jar is neither sent nor filled
};

# Connections nobody has open are kept, so that a client may write ctl
# and read body with separate opens; past this many the oldest go.
MAXIDLE: con 32;

# a finished fetch
Done: adt {
	conn:	ref ConnState;
	gen:	int;
	resp:	ref Response;
	err:	string;
};

stderr: ref Sys->FD;
user: string;
vers: int;

# Connection pool
conns: array of ref ConnState;
nconns: int;
nextid: int;

# Global config
useragent := "Mozilla/5.0 (Inferno) Webfs/1.0";
jar: ref Jar;
done: chan of ref Done;

usage()
{
	sys->fprint(stderr, "Usage: webfs [-D] [mountpoint]\n");
	raise "fail:usage";
}

nomod(s: string)
{
	sys->fprint(stderr, "webfs: can't load %s: %r\n", s);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	styx = load Styx Styx->PATH;
	if(styx == nil)
		nomod(Styx->PATH);
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		nomod(Styxservers->PATH);
	styxservers->init(styx);

	webclient = load Webclient Webclient->PATH;
	if(webclient == nil)
		nomod(Webclient->PATH);
	err := webclient->init();
	if(err != nil) {
		sys->fprint(stderr, "webfs: webclient init: %s\n", err);
		raise "fail:init";
	}

	urlmod = load Url Url->PATH;
	if(urlmod == nil)
		nomod(Url->PATH);
	urlmod->init();

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);
	arg->init(args);

	while((o := arg->opt()) != 0)
		case o {
		'D' =>	styxservers->traceset(1);
		* =>	usage();
		}
	args = arg->argv();
	arg = nil;

	mountpt := "/mnt/web";
	if(args != nil)
		mountpt = hd args;

	# Initialize connection pool
	conns = array[16] of ref ConnState;
	nconns = 0;
	nextid = 1;
	vers = 0;
	jar = Jar.new();
	done = chan of ref Done;

	sys->pctl(Sys->FORKFD, nil);

	user = rf("/dev/user");
	if(user == nil)
		user = "inferno";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "webfs: can't create pipe: %r\n");
		raise "fail:pipe";
	}

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc, navops);
	<-pidc;

	ensuredir(mountpt);

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "webfs: mount failed: %r\n");
		raise "fail:mount";
	}
}

# Allocate a new connection, return its ID
newconn(): ref ConnState
{
	id := nextid++;
	c := ref ConnState(id, "", "GET", nil, nil, nil, "", 0, "", 0, 0, nil, 0, 0);

	# Grow pool if needed
	if(nconns >= len conns) {
		nc := array[len conns * 2] of ref ConnState;
		nc[0:] = conns[0:nconns];
		conns = nc;
	}
	conns[nconns++] = c;
	vers++;
	reap();
	return c;
}

# Forget the oldest idle connections beyond MAXIDLE, and their responses.
reap()
{
	idle := 0;
	for(i := nconns - 1; i >= 0; i--) {
		c := conns[i];
		if(c.nopen > 0 || c.fetching || c.pending != nil)
			continue;
		if(++idle > MAXIDLE)
			freeconn(c.id);
	}
}

# Find connection by ID
findconn(id: int): ref ConnState
{
	for(i := 0; i < nconns; i++)
		if(conns[i].id == id)
			return conns[i];
	return nil;
}

# Free a connection
freeconn(id: int)
{
	for(i := 0; i < nconns; i++) {
		if(conns[i].id == id) {
			conns[i:] = conns[i+1:nconns];
			nconns--;
			conns[nconns] = nil;
			vers++;
			return;
		}
	}
}

# Encode qid path: connid << 8 | filetype
MKPATH(connid, filetype: int): big
{
	return big ((connid << 8) | filetype);
}

# Decode connection ID from qid path
CONNID(path: big): int
{
	return (int path >> 8) & 16rFFFFFF;
}

# Decode file type from qid path
FTYPE(path: big): int
{
	return int path & 16rFF;
}

# Start c's fetch, if it needs one; m waits for it.  Returns 0 if
# c's response is already there and m can be answered now.
needfetch(c: ref ConnState, m: ref Tmsg): int
{
	if(c.fetched)
		return 0;
	c.pending = m :: c.pending;
	if(c.fetching)
		return 1;
	c.fetching = 1;
	if(c.url == "") {
		spawn fetchdone(ref Done(c, c.gen, nil, "no URL set"));
		return 1;
	}

	hdrs := c.headers;
	has_ua := 0;
	has_ae := 0;
	for(h := hdrs; h != nil; h = tl h)
		case tolower((hd h).name) {
		"user-agent" =>
			has_ua = 1;
		"accept-encoding" =>
			has_ae = 1;
		}
	if(!has_ua)
		hdrs = Header("User-Agent", useragent) :: hdrs;
	if(!has_ae)
		hdrs = Header("Accept-Encoding", "gzip, deflate, br") :: hdrs;
	j := jar;
	if(c.nocookies)
		j = nil;
	spawn fetcher(c, c.gen, c.method, c.url, hdrs, c.postdata, j);
	return 1;
}

fetcher(c: ref ConnState, gen: int, method, url: string, hdrs: list of Header, body: array of byte, j: ref Jar)
{
	resp: ref Response;
	err: string;
	{
		(resp, err) = webclient->requestjar(method, url, hdrs, body, j);
	} exception e {
	"*" =>
		resp = nil;
		err = "fetch failed: " + e;
	}
	done <-= ref Done(c, gen, resp, err);
}

fetchdone(d: ref Done)
{
	done <-= d;
}

# A fetch finished: record it and answer what waited for it.
finish(srv: ref Styxserver, d: ref Done)
{
	c := d.conn;
	c.fetching = 0;
	if(d.gen == c.gen) {
		if(d.err != nil) {
			c.status = "error: " + d.err;
			c.resp = nil;
			c.contenttype = "";
		} else {
			c.resp = d.resp;
			c.status = string d.resp.statuscode + " " + d.resp.status;
			c.contenttype = d.resp.hdrval("Content-Type");
			if(c.contenttype == nil)
				c.contenttype = "";
		}
		c.fetched = 1;
		vers++;
	}
	# a stale fetch leaves fetched unset, so these start the new one
	p := c.pending;
	c.pending = nil;
	r: list of ref Tmsg;
	for(; p != nil; p = tl p)
		r = hd p :: r;
	for(; r != nil; r = tl r)
		handle(srv, hd r);
}

# Forget a flushed request that is waiting for a fetch.
flushpending(tag: int)
{
	for(i := 0; i < nconns; i++) {
		c := conns[i];
		keep: list of ref Tmsg;
		for(p := c.pending; p != nil; p = tl p)
			if((hd p).tag != tag)
				keep = hd p :: keep;
		c.pending = nil;
		for(; keep != nil; keep = tl keep)
			c.pending = hd keep :: c.pending;
	}
}

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int, navops: chan of ref Navop)
{
	pidc <-= sys->pctl(Sys->FORKNS|Sys->NEWFD, 1::2::srv.fd.fd::nil);

Serve:
	for(;;) alt {
	gm := <-tchan =>
		if(gm == nil)
			break Serve;
		if(tagof gm == tagof Tmsg.Readerror) {
			pick m := gm {
			Readerror =>
				sys->fprint(stderr, "webfs: fatal read error: %s\n", m.error);
			}
			break Serve;
		}
		handle(srv, gm);
	d := <-done =>
		finish(srv, d);
	}
	navops <-= nil;
}

handle(srv: ref Styxserver, gm: ref Tmsg)
{
		pick m := gm {
		Open =>
			c := srv.getfid(m.fid);
			if(c == nil) {
				srv.open(m);
				break;
			}

			mode := styxservers->openmode(m.mode);
			if(mode < 0) {
				srv.reply(ref Rmsg.Error(m.tag, Ebadarg));
				break;
			}

			ft := FTYPE(c.path);
			# Trigger fetch when body is opened for reading
			if(ft == Qbody && (mode == Sys->OREAD || mode == Sys->ORDWR)) {
				connid := CONNID(c.path);
				conn := findconn(connid);
				if(conn != nil && needfetch(conn, gm))
					break;
			}

			if((conn := findconn(CONNID(c.path))) != nil)
				conn.nopen++;
			qid := Qid(c.path, 0, c.qtype);
			c.open(mode, qid);
			srv.reply(ref Rmsg.Open(m.tag, qid, srv.iounit()));

		Read =>
			(c, err) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}

			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}

			ft := FTYPE(c.path);
			connid := CONNID(c.path);

			case ft {
			Qclone =>
				conn := newconn();
				data := array of byte (string conn.id + "\n");
				srv.reply(styxservers->readbytes(m, data));

			Qgctl =>
				data := array of byte ("useragent " + useragent + "\n");
				srv.reply(styxservers->readbytes(m, data));

			Qctl =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				info := "url " + conn.url + "\n" +
					"method " + conn.method + "\n";
				for(h := conn.headers; h != nil; h = tl h)
					info += "header " + (hd h).name + ": " + (hd h).value + "\n";
				srv.reply(styxservers->readbytes(m, array of byte info));

			Qbody =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(needfetch(conn, gm))
					break;
				if(conn.resp != nil && conn.resp.body != nil)
					srv.reply(styxservers->readbytes(m, conn.resp.body));
				else
					srv.reply(styxservers->readbytes(m, array[0] of byte));

			Qpostbody =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(conn.postdata != nil)
					srv.reply(styxservers->readbytes(m, conn.postdata));
				else
					srv.reply(styxservers->readbytes(m, array[0] of byte));

			Qcontenttype =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(needfetch(conn, gm))
					break;
				srv.reply(styxservers->readbytes(m, array of byte conn.contenttype));

			Qstatus =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(needfetch(conn, gm))
					break;
				srv.reply(styxservers->readbytes(m, array of byte conn.status));

			Qurl or Qheader =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(needfetch(conn, gm))
					break;
				val := "";
				if(conn.resp != nil && ft == Qurl)
					val = conn.resp.url + "\n";
				else if(conn.resp != nil) {
					for(h := conn.resp.headers; h != nil; h = tl h)
						val += (hd h).name + ": " + (hd h).value + "\n";
				}
				srv.reply(styxservers->readbytes(m, array of byte val));

			Qcookies =>
				srv.reply(styxservers->readbytes(m, array of byte jar.text()));

			# Parsed URL components
			Qpurl or Qpscheme or Qphost or Qpport or
			Qppath or Qpquery or Qpfragment =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				val := parsedfield(conn, ft);
				srv.reply(styxservers->readbytes(m, array of byte val));

			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Write =>
			(c, merr) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, merr));
				break;
			}

			ft := FTYPE(c.path);
			connid := CONNID(c.path);
			data := string m.data;

			# Strip trailing newline
			if(len data > 0 && data[len data - 1] == '\n')
				data = data[0:len data - 1];

			case ft {
			Qgctl =>
				# Global ctl: "useragent <string>"
				if(hasprefix(data, "useragent "))
					useragent = data[len "useragent ":];
				else {
					srv.reply(ref Rmsg.Error(m.tag, "unknown ctl command"));
					break;
				}
				vers++;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qcookies =>
				# one cookie per line, as read gives them, or "clear"
				(nil, lines) := sys->tokenize(data, "\n");
				err: string;
				for(; lines != nil && err == nil; lines = tl lines)
					if(hd lines == "clear")
						jar.clear();
					else
						err = jar.add(hd lines);
				if(err != nil) {
					srv.reply(ref Rmsg.Error(m.tag, err));
					break;
				}
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qctl =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				cerr := connctl(conn, data);
				if(cerr != nil) {
					srv.reply(ref Rmsg.Error(m.tag, cerr));
					break;
				}
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qpostbody =>
				conn := findconn(connid);
				if(conn == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				conn.postdata = m.data;
				conn.fetched = 0;
				conn.gen++;
				vers++;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Flush =>
			flushpending(m.oldtag);
			srv.default(gm);

		Clunk =>
			closed(srv.clunk(m));

		Remove =>
			closed(srv.remove(m));

		* =>
			srv.default(gm);
		}
}

# A fid is gone; if it was open on a connection's file, that's one less.
closed(f: ref Fid)
{
	if(f != nil && f.isopen && (conn := findconn(CONNID(f.path))) != nil)
		conn.nopen--;
}

# Process connection ctl commands
connctl(c: ref ConnState, data: string): string
{
	if(hasprefix(data, "url ")) {
		c.url = data[len "url ":];
		c.fetched = 0;
		c.gen++;
		c.resp = nil;
		c.status = "";
		c.contenttype = "";
		vers++;
		return nil;
	}
	if(hasprefix(data, "method ")) {
		m := toupper(data[len "method ":]);
		case m {
		"GET" or "POST" or "PUT" or "DELETE" or "HEAD" or "PATCH" or "OPTIONS" =>
			c.method = m;
		* =>
			return "invalid method: " + m;
		}
		c.fetched = 0;
		c.gen++;
		vers++;
		return nil;
	}
	if(data == "cookies off" || data == "cookies on") {
		c.nocookies = data == "cookies off";
		c.fetched = 0;
		c.gen++;
		vers++;
		return nil;
	}
	if(hasprefix(data, "header ")) {
		hdr := data[len "header ":];
		# Find ": " separator
		for(i := 0; i < len hdr - 1; i++) {
			if(hdr[i] == ':' && hdr[i+1] == ' ') {
				c.headers = Header(hdr[0:i], hdr[i+2:]) :: c.headers;
				c.fetched = 0;
				c.gen++;
				vers++;
				return nil;
			}
		}
		return "bad header format (use: header Name: Value)";
	}
	return "unknown ctl command: " + data;
}

# Get parsed URL field value
parsedfield(c: ref ConnState, ft: int): string
{
	if(c.url == "")
		return "";
	pu := urlmod->makeurl(c.url);
	if(pu == nil)
		return "";
	case ft {
	Qpurl =>      return pu.tostring();
	Qpscheme =>   return schemename(pu.scheme);
	Qphost =>     return pu.host;
	Qpport =>     return pu.port;
	Qppath =>     return pu.path;
	Qpquery =>    return pu.query;
	Qpfragment => return pu.frag;
	}
	return "";
}

schemename(scheme: int): string
{
	case scheme {
	Url->HTTP =>   return "http";
	Url->HTTPS =>  return "https";
	Url->FTP =>    return "ftp";
	Url->FILE =>   return "file";
	}
	return "unknown";
}

# --- Directory generation ---

dir(qid: Sys->Qid, name: string, length: big, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = length;
	return d;
}

dirgen(p: big): (ref Sys->Dir, string)
{
	ft := FTYPE(p);
	connid := CONNID(p);

	case ft {
	Qroot =>
		return (dir(Qid(p, vers, Sys->QTDIR), "/", big 0, 8r755), nil);

	Qclone =>
		return (dir(Qid(p, vers, Sys->QTFILE), "clone", big 0, 8r444), nil);

	Qgctl =>
		return (dir(Qid(p, vers, Sys->QTFILE), "ctl", big 0, 8r644), nil);

	Qcookies =>
		return (dir(Qid(p, vers, Sys->QTFILE), "cookies", big 0, 8r600), nil);

	Qconndir =>
		return (dir(Qid(p, vers, Sys->QTDIR), string connid, big 0, 8r755), nil);

	Qurl =>
		return (dir(Qid(p, vers, Sys->QTFILE), "url", big 0, 8r444), nil);

	Qheader =>
		return (dir(Qid(p, vers, Sys->QTFILE), "header", big 0, 8r444), nil);

	Qctl =>
		return (dir(Qid(p, vers, Sys->QTFILE), "ctl", big 0, 8r644), nil);

	Qbody =>
		return (dir(Qid(p, vers, Sys->QTFILE), "body", big 0, 8r444), nil);

	Qpostbody =>
		return (dir(Qid(p, vers, Sys->QTFILE), "postbody", big 0, 8r644), nil);

	Qcontenttype =>
		return (dir(Qid(p, vers, Sys->QTFILE), "contenttype", big 0, 8r444), nil);

	Qstatus =>
		return (dir(Qid(p, vers, Sys->QTFILE), "status", big 0, 8r444), nil);

	Qparseddir =>
		return (dir(Qid(p, vers, Sys->QTDIR), "parsed", big 0, 8r555), nil);

	Qpurl =>
		return (dir(Qid(p, vers, Sys->QTFILE), "url", big 0, 8r444), nil);

	Qpscheme =>
		return (dir(Qid(p, vers, Sys->QTFILE), "scheme", big 0, 8r444), nil);

	Qphost =>
		return (dir(Qid(p, vers, Sys->QTFILE), "host", big 0, 8r444), nil);

	Qpport =>
		return (dir(Qid(p, vers, Sys->QTFILE), "port", big 0, 8r444), nil);

	Qppath =>
		return (dir(Qid(p, vers, Sys->QTFILE), "path", big 0, 8r444), nil);

	Qpquery =>
		return (dir(Qid(p, vers, Sys->QTFILE), "query", big 0, 8r444), nil);

	Qpfragment =>
		return (dir(Qid(p, vers, Sys->QTFILE), "fragment", big 0, 8r444), nil);
	}

	return (nil, Enotfound);
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);

		Walk =>
			ft := FTYPE(n.path);
			connid := CONNID(n.path);

			case ft {
			Qroot =>
				case n.name {
				".." =>
					;  # stay at root
				"clone" =>
					n.path = MKPATH(0, Qclone);
				"ctl" =>
					n.path = MKPATH(0, Qgctl);
				"cookies" =>
					n.path = MKPATH(0, Qcookies);
				* =>
					# Try as connection ID
					id := strtoint(n.name);
					if(id > 0 && findconn(id) != nil)
						n.path = MKPATH(id, Qconndir);
					else {
						n.reply <-= (nil, Enotfound);
						continue;
					}
				}
				n.reply <-= dirgen(n.path);

			Qconndir =>
				case n.name {
				".." =>
					n.path = big Qroot;
				"ctl" =>
					n.path = MKPATH(connid, Qctl);
				"body" =>
					n.path = MKPATH(connid, Qbody);
				"postbody" =>
					n.path = MKPATH(connid, Qpostbody);
				"contenttype" =>
					n.path = MKPATH(connid, Qcontenttype);
				"status" =>
					n.path = MKPATH(connid, Qstatus);
				"url" =>
					n.path = MKPATH(connid, Qurl);
				"header" =>
					n.path = MKPATH(connid, Qheader);
				"parsed" =>
					n.path = MKPATH(connid, Qparseddir);
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			Qparseddir =>
				case n.name {
				".." =>
					n.path = MKPATH(connid, Qconndir);
				"url" =>
					n.path = MKPATH(connid, Qpurl);
				"scheme" =>
					n.path = MKPATH(connid, Qpscheme);
				"host" =>
					n.path = MKPATH(connid, Qphost);
				"port" =>
					n.path = MKPATH(connid, Qpport);
				"path" =>
					n.path = MKPATH(connid, Qppath);
				"query" =>
					n.path = MKPATH(connid, Qpquery);
				"fragment" =>
					n.path = MKPATH(connid, Qpfragment);
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			* =>
				n.reply <-= (nil, "not a directory");
			}

		Readdir =>
			ft := FTYPE(m.path);
			connid := CONNID(m.path);

			case ft {
			Qroot =>
				# Root: clone, ctl, plus connection directories
				entries: list of big;
				entries = MKPATH(0, Qclone) :: entries;
				entries = MKPATH(0, Qgctl) :: entries;
				entries = MKPATH(0, Qcookies) :: entries;
				for(i := 0; i < nconns; i++)
					entries = MKPATH(conns[i].id, Qconndir) :: entries;

				# Reverse to preserve order
				rev: list of big;
				for(; entries != nil; entries = tl entries)
					rev = hd entries :: rev;
				entries = rev;

				i = 0;
				for(e := entries; e != nil; e = tl e) {
					if(i >= n.offset && n.count > 0) {
						n.reply <-= dirgen(hd e);
						n.count--;
					}
					i++;
				}
				n.reply <-= (nil, nil);

			Qconndir =>
				files := array[] of {
					MKPATH(connid, Qctl),
					MKPATH(connid, Qbody),
					MKPATH(connid, Qpostbody),
					MKPATH(connid, Qcontenttype),
					MKPATH(connid, Qstatus),
					MKPATH(connid, Qurl),
					MKPATH(connid, Qheader),
					MKPATH(connid, Qparseddir),
				};
				i := n.offset;
				for(; i < len files && n.count > 0; i++) {
					n.reply <-= dirgen(files[i]);
					n.count--;
				}
				n.reply <-= (nil, nil);

			Qparseddir =>
				files := array[] of {
					MKPATH(connid, Qpurl),
					MKPATH(connid, Qpscheme),
					MKPATH(connid, Qphost),
					MKPATH(connid, Qpport),
					MKPATH(connid, Qppath),
					MKPATH(connid, Qpquery),
					MKPATH(connid, Qpfragment),
				};
				i := n.offset;
				for(; i < len files && n.count > 0; i++) {
					n.reply <-= dirgen(files[i]);
					n.count--;
				}
				n.reply <-= (nil, nil);

			* =>
				n.reply <-= (nil, "not a directory");
			}
		}
	}
}

# --- Helpers ---

ensuredir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil)
		return;

	for(i := len path - 1; i > 0; i--) {
		if(path[i] == '/') {
			ensuredir(path[0:i]);
			break;
		}
	}

	fd = sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd == nil)
		sys->fprint(stderr, "webfs: cannot create directory %s: %r\n", path);
}

rf(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	return string b[0:n];
}

strtoint(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return -1;
		n = n * 10 + (c - '0');
	}
	if(len s == 0)
		return -1;
	return n;
}

toupper(s: string): string
{
	b := array of byte s;
	for(i := 0; i < len b; i++) {
		c := int b[i];
		if(c >= 'a' && c <= 'z')
			b[i] = byte (c - 'a' + 'A');
	}
	return string b;
}

tolower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}
