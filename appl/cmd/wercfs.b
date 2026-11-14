implement Wercfs;

#
# wercfs - a werc site as the files a web server sends
#
# werc (werc.cat-v.org) is rc run as CGI; here it is a file server,
# mounted where httpd(8) serves, and httpd has no CGI.  wercfs
# overlays a werc site directory, read-only:
#
#	/			the site
#	/index.html		index.md, index.html or index.txt in the master
#				template; with none, werc's directory listing in it
#	/foo			foo.md, foo.html or foo.txt in the master template
#	/foo.md, /img.png	the site's own files, as they are
#	/dir/			a directory: the same, a level down
#	/pub/...		the site's pub/, else werc's pub/ (its style sheet)
#	/_werc/pub/...		the site's own pub/ (its style.css)
#
# Nothing else of _werc/ is served (configuration and templates are the
# site's source, not its pages), and no name beginning with '.'.  A
# directory and a page of one name: the directory, as in werc.  A page
# hides a file of its name.
#
# A page's stat gives its length: it is made when it is looked at and
# kept, with what it was made from (the source, each _werc/config down
# its path, the lib files, the directories its menu lists), each as its
# stat.  It is made again when one of those has changed, and its qid's
# version is a hash of what it holds, so httpd's ETag for a page changes
# when an edit changes the page, and not otherwise.
#
# What a page is made of, as werc 1.5 makes it (bin/werc.rc,
# bin/corehandlers.rc, bin/werclib.rc, lib/headers.tpl,
# lib/default_master.tpl): the body by the handler for its source
# (md_handler through mdhtml(2), html_handler's <body>, txt_handler's
# <pre>, dir_listing_handler with _header.md and _footer.md), the menu
# by nav_tree, the title by get_file_title or else from the path, and
# top_bar.inc, footer.inc and headers.inc where get_lib_file finds them.
# _werc/config files are read as werc sources them, root first; of rc,
# plain assignments and conf_hide_paths are taken, and every other line
# is reported once on standard error, so a site's owner sees what was
# not.  See wercfs(4).
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
	Enotfound, Eperm, Ebadfid: import styxservers;

include "regex.m";
	regex: Regex;

include "daytime.m";
	daytime: Daytime;

include "mdhtml.m";
	mdhtml: Mdhtml;

Wercfs: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# what a name is
Kdir,		# a directory of the site: its files and its pages
Kraw,		# a directory served as it is (pub/)
Kwerc,		# _werc: pub/ alone
Kfile,		# a file as it is
Kpage,		# a page: src is its source
Kindex		# a directory's index.html: src is the directory
	: con iota;

Ent: adt {
	kind:	int;
	src:	string;
	d:	ref Sys->Dir;	# src's stat, for Kdir Kraw Kwerc Kfile
	also:	string;	# Kraw: where a name not in src is looked for (werc's pub/)
};

# a page, and what it was made from: (name, its stat or "-")
Page: adt {
	data:	array of byte;
	vers:	int;	# a hash of data: an ETag changes as the page does
	mtime:	int;	# the newest of what it was made from
	made:	int;	# when it was made
	deps:	list of (string, string);
};

# what a fid has open
Open: adt {
	fid:	int;
	d:	ref Sys->Dir;
	data:	array of byte;	# a page
	fd:	ref Sys->FD;	# a file
};

# a request of the serve loop to the navigator's process: what an open
# of path reads
Creq: adt {
	path:	big;
	reply:	chan of (ref Sys->Dir, array of byte, string, string);
};

MAXFILE: con 16*1024*1024;

sitedir: string;
wercroot: string;
user := "werc";

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	regex = load Regex Regex->PATH;
	mdhtml = load Mdhtml Mdhtml->PATH;
	daytime = load Daytime Daytime->PATH;
	if(arg == nil || styx == nil || styxservers == nil || regex == nil || mdhtml == nil || daytime == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	styx->init();
	styxservers->init(styx);
	mdhtml->init();

	arg->init(args);
	arg->setusage("wercfs [-w wercroot] sitedir");
	while((o := arg->opt()) != 0)
		case o {
		'w' =>	wercroot = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	sitedir = cleanpath(hd args);
	if(!isdir(sitedir))
		fatal(sitedir + ": not a directory");
	if(wercroot == nil){
		# a site in werc's own tree, wercroot/sites/<name>
		(p, nil) := splitlast(sitedir);
		(r, s) := splitlast(p);
		if(s == "sites" && isdir(r + "/lib"))
			wercroot = r;
	}else{
		wercroot = cleanpath(wercroot);
		if(!isdir(wercroot))
			fatal(wercroot + ": not a directory");
	}
	if((u := readsmall("/dev/user")) != nil)
		user = u;

	# Read the site as httpd reads it: in a name space of our own
	# where no device is attached by name, so the emulator follows
	# no host symbolic link (fs(3)), and one in the site cannot take
	# a page, or a file served as it is, from outside it.
	if(sys->pctl(Sys->FORKNS|Sys->NODEVS, nil) < 0)
		fatal(sys->sprint("cannot confine: %r"));

	navops := chan of ref Navop;
	creqs := chan of ref Creq;
	spawn core(navops, creqs);
	(tc, srv) := Styxserver.new(sys->fildes(0), Navigator.new(navops), big 0);
	serve(tc, srv, creqs);
}

fatal(s: string)
{
	sys->fprint(stderr, "wercfs: %s\n", s);
	raise "fail:" + s;
}

#
# The serve loop: opens, reads and stats of what is open; the rest is
# styxservers' through the navigator
#

serve(tc: chan of ref Tmsg, srv: ref Styxserver, creqs: chan of ref Creq)
{
	opens: list of ref Open;
	creply := chan of (ref Sys->Dir, array of byte, string, string);
Serve:
	while((gm := <-tc) != nil){
		pick m := gm {
		Readerror =>
			break Serve;
		Open =>
			(c, mode, d, err) := srv.canopen(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(d.mode & Sys->DMDIR){
				c.open(mode, d.qid);
				srv.reply(ref Rmsg.Open(m.tag, d.qid, srv.iounit()));
				break;
			}
			creqs <-= ref Creq(c.path, creply);
			(od, data, src, cerr) := <-creply;
			if(cerr != nil){
				srv.reply(ref Rmsg.Error(m.tag, cerr));
				break;
			}
			o := ref Open(c.fid, od, data, nil);
			if(src != nil){
				o.fd = sys->open(src, Sys->OREAD);
				if(o.fd == nil){
					srv.reply(ref Rmsg.Error(m.tag, sys->sprint("%r")));
					break;
				}
			}
			opens = o :: dropopen(opens, c.fid);
			c.open(mode, od.qid);
			srv.reply(ref Rmsg.Open(m.tag, od.qid, srv.iounit()));
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR){
				srv.read(m);
				break;
			}
			o := findopen(opens, c.fid);
			if(o == nil){
				srv.reply(ref Rmsg.Error(m.tag, Ebadfid));
				break;
			}
			if(o.fd == nil){
				srv.reply(styxservers->readbytes(m, o.data));
				break;
			}
			n := m.count;
			if(n > srv.iounit())
				n = srv.iounit();
			buf := array[n] of byte;
			k := sys->pread(o.fd, buf, n, m.offset);
			if(k < 0)
				srv.reply(ref Rmsg.Error(m.tag, sys->sprint("%r")));
			else
				srv.reply(ref Rmsg.Read(m.tag, buf[0:k]));
		Stat =>
			c := srv.getfid(m.fid);
			if(c != nil && (o := findopen(opens, c.fid)) != nil)
				srv.reply(ref Rmsg.Stat(m.tag, *o.d));
			else
				srv.stat(m);
		Clunk =>
			opens = dropopen(opens, m.fid);
			srv.clunk(m);
		Remove =>
			opens = dropopen(opens, m.fid);
			srv.remove(m);
		* =>
			srv.default(gm);
		}
	}
	srv.t.c <-= nil;
}

findopen(l: list of ref Open, fid: int): ref Open
{
	for(; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

dropopen(l: list of ref Open, fid: int): list of ref Open
{
	r: list of ref Open;
	for(; l != nil; l = tl l)
		if((hd l).fid != fid)
			r = hd l :: r;
	return r;
}

#
# The navigator, and what an open reads: one process, which keeps the
# names and the pages made
#

core(navops: chan of ref Navop, creqs: chan of ref Creq)
{
	for(;;) alt {
	op := <-navops =>
		if(op == nil)
			exit;
		pick n := op {
		Stat =>
			n.reply <-= stat(n.path);
		Walk =>
			n.reply <-= walk(n.path, n.name);
		Readdir =>
			readdir(n.path, n.offset, n.count, n.reply);
		}
	r := <-creqs =>
		r.reply <-= content(r.path);
	}
}

stat(q: big): (ref Sys->Dir, string)
{
	p := pathof(q);
	if(p == nil && q != big 0)
		return (nil, Enotfound);
	e := resolve(p);
	if(e == nil)
		return (nil, Enotfound);
	return (dirof(p, e), nil);
}

walk(q: big, name: string): (ref Sys->Dir, string)
{
	p := pathof(q);
	if(p == nil && q != big 0)
		return (nil, Enotfound);
	if(name == ".."){
		(pp, nil) := splitlast(p);
		return stat(big idof(pp));
	}
	if(p != nil)
		p += "/";
	p += name;
	e := resolve(p);
	if(e == nil)
		return (nil, Enotfound);
	return (dirof(p, e), nil);
}

readdir(q: big, offset, count: int, reply: chan of (ref Sys->Dir, string))
{
	p := pathof(q);
	e: ref Ent;
	if(p != nil || q == big 0)
		e = resolve(p);
	if(e != nil){
		names := entries(p, e);
		pre := "";
		if(p != nil)
			pre = p + "/";
		i := 0;
		for(; names != nil && count > 0; names = tl names){
			ce := child(e, p, hd names);
			if(ce == nil)
				continue;
			if(i++ < offset)
				continue;
			reply <-= (dirof(pre + hd names, ce), nil);
			count--;
		}
	}
	reply <-= (nil, nil);
}

content(q: big): (ref Sys->Dir, array of byte, string, string)
{
	p := pathof(q);
	e := resolve(p);
	if(e == nil)
		return (nil, nil, nil, Enotfound);
	case e.kind {
	Kfile =>
		return (dirof(p, e), nil, e.src, nil);
	Kpage or Kindex =>
		pg := page(p, e);
		return (pagedir(p, pg), pg.data, nil, nil);
	}
	return (nil, nil, nil, Eperm);
}

#
# Names
#

# qid paths: each name looked at is given one, the site's root 0
NHASH: con 1024;
ids := array[NHASH] of list of (string, int);
idnames := array[64] of string;
nnames := 1;

idof(p: string): int
{
	if(p == nil)
		return 0;
	h := strhash(p) % NHASH;
	for(l := ids[h]; l != nil; l = tl l)
		if((hd l).t0 == p)
			return (hd l).t1;
	if(nnames == len idnames){
		a := array[2*len idnames] of string;
		a[0:] = idnames;
		idnames = a;
	}
	idnames[nnames] = p;
	ids[h] = (p, nnames) :: ids[h];
	return nnames++;
}

pathof(q: big): string
{
	if(q <= big 0 || q >= big nnames)
		return nil;
	return idnames[int q];
}

strhash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = (h*31 + s[i]) & 16r7fffffff;
	return h;
}

# What the site path p (no leading /; nil the root) is, or nil
resolve(p: string): ref Ent
{
	(ok, d) := sys->stat(sitedir);
	if(ok < 0)
		return nil;
	e := ref Ent(Kdir, sitedir, ref d, nil);
	parent := "";
	for(l := split(p, '/'); l != nil && e != nil; l = tl l){
		e = child(e, parent, hd l);
		if(parent != nil)
			parent += "/";
		parent += hd l;
	}
	return e;
}

# The name in directory e (the site path pp), or nil
child(e: ref Ent, pp, name: string): ref Ent
{
	if(name == nil || name[0] == '.' || contains(name, "/"))
		return nil;
	full := e.src + "/" + name;
	case e.kind {
	Kraw =>
		also: string;
		if(e.also != nil)
			also = e.also + "/" + name;
		(ok, d) := sys->stat(full);
		if(ok < 0){
			if(also == nil)
				return nil;
			(ok, d) = sys->stat(also);
			if(ok < 0)
				return nil;
			(full, also) = (also, nil);
		}
		if(d.mode & Sys->DMDIR){
			if(also != nil && !isdir(also))
				also = nil;
			return ref Ent(Kraw, full, ref d, also);
		}
		return ref Ent(Kfile, full, ref d, nil);
	Kwerc =>
		if(name != "pub")
			return nil;
		(ok, d) := sys->stat(full);
		if(ok < 0 || (d.mode & Sys->DMDIR) == 0)
			return nil;
		return ref Ent(Kraw, full, ref d, nil);
	Kdir =>
		# werc's pub/: the site's, and werc's for what the site's has not
		wpub: string;
		if(pp == nil && name == "pub" && wercroot != nil && isdir(wercroot + "/pub"))
			wpub = wercroot + "/pub";
		(ok, d) := sys->stat(full);
		if(ok >= 0 && (d.mode & Sys->DMDIR)){
			if(name == "_werc"){
				if(isdir(full + "/pub"))
					return ref Ent(Kwerc, full, ref d, nil);
				return nil;
			}
			if(pp == nil && name == "pub")
				return ref Ent(Kraw, full, ref d, wpub);
			return ref Ent(Kdir, full, ref d, nil);
		}
		if(name == "index.html")
			return ref Ent(Kindex, e.src, nil, nil);
		if(wpub != nil){
			(nil, wd) := sys->stat(wpub);
			return ref Ent(Kraw, wpub, ref wd, nil);
		}
		if(name != "index" && (src := pagesrc(e.src + "/" + name)) != nil)
			return ref Ent(Kpage, src, nil, nil);
		if(ok >= 0)
			return ref Ent(Kfile, full, ref d, nil);
	}
	return nil;
}

# A page's source, in werc's order (setup_handlers): .md, .html, .txt
pagesrc(base: string): string
{
	for(l := list of {".md", ".html", ".txt"}; l != nil; l = tl l){
		(ok, d) := sys->stat(base + hd l);
		if(ok >= 0 && (d.mode & Sys->DMDIR) == 0)
			return base + hd l;
	}
	return nil;
}

# The names in directory e, sorted
entries(p: string, e: ref Ent): list of string
{
	(dirs, nil) := readdirnames(e.src);
	if(e.kind == Kraw && e.also != nil){
		(more, nil) := readdirnames(e.also);
		a := array[len dirs + len more] of ref Sys->Dir;
		a[0:] = dirs;
		a[len dirs:] = more;
		dirs = a;
	}
	l: list of string;
	for(i := 0; i < len dirs; i++){
		n := dirs[i].name;
		if(n == nil || n[0] == '.')
			continue;
		l = n :: l;
		if(e.kind == Kdir && (dirs[i].mode & Sys->DMDIR) == 0)
			for(x := list of {".md", ".html", ".txt"}; x != nil; x = tl x)
				if(suffix(n, hd x) && len n > len hd x)
					l = n[0:len n - len hd x] :: l;
	}
	if(e.kind == Kdir){
		l = "index.html" :: l;
		if(p == nil && wercroot != nil)
			l = "pub" :: l;
	}
	return uniq(sort(l));
}

dirof(p: string, e: ref Ent): ref Sys->Dir
{
	case e.kind {
	Kpage or Kindex =>
		return pagedir(p, page(p, e));
	}
	d := ref sys->zerodir;
	(nil, d.name) = splitlast(p);
	if(p == nil)
		d.name = ".";
	d.uid = d.gid = d.muid = user;
	d.qid = Qid(big idof(p), e.d.qid.vers, Sys->QTFILE);
	d.mtime = d.atime = e.d.mtime;
	if(e.kind == Kfile){
		d.mode = 8r444;
		d.length = e.d.length;
	}else{
		d.mode = Sys->DMDIR | 8r555;
		d.qid.qtype = Sys->QTDIR;
	}
	return d;
}

pagedir(p: string, pg: ref Page): ref Sys->Dir
{
	d := ref sys->zerodir;
	(nil, d.name) = splitlast(p);
	d.uid = d.gid = d.muid = user;
	d.qid = Qid(big idof(p), pg.vers, Sys->QTFILE);
	d.mode = 8r444;
	d.mtime = d.atime = pg.mtime;
	d.length = big len pg.data;
	return d;
}

#
# Pages
#

PHASH: con 256;
pages := array[PHASH] of list of (string, ref Page);

# The page at p, made again only if what it was made from has
# changed.  A stat's times are in seconds, so what changed in the
# second the page was made can change again unseen: a page made from
# something that new is made again each time, until it is older.
page(p: string, e: ref Ent): ref Page
{
	h := strhash(p) % PHASH;
	for(l := pages[h]; l != nil; l = tl l)
		if((hd l).t0 == p){
			pg := (hd l).t1;
			if(pg.made > pg.mtime + 1 && current(pg.deps))
				return pg;
			break;
		}
	pg := make(p, e);
	r: list of (string, ref Page);
	for(l = pages[h]; l != nil; l = tl l)
		if((hd l).t0 != p)
			r = hd l :: r;
	pages[h] = (p, pg) :: r;
	return pg;
}

current(deps: list of (string, string)): int
{
	for(; deps != nil; deps = tl deps){
		(name, was) := hd deps;
		if(statsig(name) != was)
			return 0;
	}
	return 1;
}

statsig(name: string): string
{
	(ok, d) := sys->stat(name);
	if(ok < 0)
		return "-";
	return sys->sprint("%bux %ud %ud %bd", d.qid.path, d.qid.vers, d.mtime, d.length);
}

# What a page is being made from
Mk: adt {
	deps:	list of (string, string);
	mtime:	int;
	vars:	list of (string, string);
	hides:	list of Regex->Re;

	probe:	fn(mk: self ref Mk, name: string): (int, Sys->Dir);
	isdir:	fn(mk: self ref Mk, name: string): int;
	isfile:	fn(mk: self ref Mk, name: string): int;
	read:	fn(mk: self ref Mk, name: string): string;
	ls:	fn(mk: self ref Mk, name: string): array of ref Sys->Dir;
	get:	fn(mk: self ref Mk, var: string): string;
	set:	fn(mk: self ref Mk, var, val: string);
	hidden:	fn(mk: self ref Mk, path: string): int;
};

Mk.probe(mk: self ref Mk, name: string): (int, Sys->Dir)
{
	for(l := mk.deps; l != nil; l = tl l)
		if((hd l).t0 == name)
			break;
	(ok, d) := sys->stat(name);
	if(l == nil){
		sig := "-";
		if(ok >= 0){
			sig = sys->sprint("%bux %ud %ud %bd", d.qid.path, d.qid.vers, d.mtime, d.length);
			if(d.mtime > mk.mtime)
				mk.mtime = d.mtime;
		}
		mk.deps = (name, sig) :: mk.deps;
	}
	return (ok, d);
}

Mk.isdir(mk: self ref Mk, name: string): int
{
	(ok, d) := mk.probe(name);
	return ok >= 0 && (d.mode & Sys->DMDIR);
}

Mk.isfile(mk: self ref Mk, name: string): int
{
	(ok, d) := mk.probe(name);
	return ok >= 0 && (d.mode & Sys->DMDIR) == 0;
}

Mk.read(mk: self ref Mk, name: string): string
{
	if(!mk.isfile(name))
		return nil;
	return readfile(name);
}

Mk.ls(mk: self ref Mk, name: string): array of ref Sys->Dir
{
	if(!mk.isdir(name))
		return nil;
	(a, nil) := readdirnames(name);
	return a;
}

Mk.get(mk: self ref Mk, var: string): string
{
	for(l := mk.vars; l != nil; l = tl l)
		if((hd l).t0 == var)
			return (hd l).t1;
	return nil;
}

Mk.set(mk: self ref Mk, var, val: string)
{
	r: list of (string, string);
	for(l := mk.vars; l != nil; l = tl l)
		if((hd l).t0 != var)
			r = hd l :: r;
	mk.vars = (var, val) :: r;
}

# conf_hide_paths: path is a site path, from its leading /
Mk.hidden(mk: self ref Mk, path: string): int
{
	for(l := mk.hides; l != nil; l = tl l)
		if(regex->execute(hd l, path) != nil)
			return 1;
	return 0;
}

# werc_exec_request and setup_handlers, for the page at p
make(p: string, e: ref Ent): ref Page
{
	mk := ref Mk(nil, 0, nil, nil);

	# the request's path and its elements, as werc has them
	reqpath := "/" + p;
	if(e.kind == Kindex){
		(reqpath, nil) = splitlast(reqpath);
		reqpath += "/";
	}
	args := split(reqpath, '/');

	# _werc/config, at the root, then down the path
	readconfig(mk, sitedir + "/_werc/config", "/");
	confwd := "/";
	reqpaths := "/" :: nil;
	for(a := args; a != nil; a = tl a){
		confwd += hd a;
		reqpaths = confwd :: reqpaths;
		if(mk.isdir(sitedir + confwd)){
			confwd += "/";
			readconfig(mk, sitedir + confwd + "_werc/config", confwd);
		}
	}
	reqpaths = rev(reqpaths);

	# the title from the path, until the page has one
	pagetitle := "";
	if(args != nil)
		pagetitle = pathtitle(args);

	# the body
	head, body, foot: string;
	localfile: string;
	if(e.kind == Kindex){
		for(x := list of {"index.md", "index.html", "index.txt"}; x != nil; x = tl x)
			if(mk.isfile(e.src + "/" + hd x)){
				localfile = e.src + "/" + hd x;
				break;
			}
	}else
		localfile = e.src;
	if(localfile != nil)
		body = handler(mk, localfile);
	else{
		body = dirlisting(mk, reqpath, e.src);
		if((t := mk.read(e.src + "/_header.md")) != nil)
			head = mdhtml->html(t);
		if((t = mk.read(e.src + "/_footer.md")) != nil)
			foot = mdhtml->html(t);
	}
	if(localfile != nil && (t := filetitle(mk, localfile)) != nil)
		pagetitle = t;
	if(pagetitle == nil)
		pagetitle = mk.get("siteTitle") + " " + mk.get("siteSubTitle");

	s := master(mk, pagetitle, navtree(mk, reqpath, reqpaths), head, body, foot);
	data := array of byte s;
	return ref Page(data, bytehash(data), mk.mtime, daytime->now(), mk.deps);
}

bytehash(a: array of byte): int
{
	h := int 16r811c9dc5;	# FNV-1a, in an int's 32 bits
	for(i := 0; i < len a; i++)
		h = (h ^ int a[i]) * 16r01000193;
	return h;
}

# md_handler, html_handler, txt_handler
handler(mk: ref Mk, f: string): string
{
	t := mk.read(f);
	if(suffix(f, ".md"))
		return mdhtml->html(t);
	if(suffix(f, ".html"))
		return htmlbody(t);
	return "<pre>\n" + mdhtml->escape(t) + "</pre>\n";
}

# An HTML file's body: between <body ...> and </body>, or all of it
htmlbody(t: string): string
{
	l := lower(t);
	s := 0;
	e := len t;
	if((i := find(l, "<body", 0)) >= 0){
		j := find(l, ">", i);
		if(j >= 0)
			s = j+1;
	}
	if((i = find(l, "</body", s)) >= 0)
		e = i;
	return t[s:e];
}

# dir_listing_handler
dirlisting(mk: ref Mk, reqpath, dir: string): string
{
	h := reqpath[0:len reqpath - 1];	# without its final /
	t := "";
	for(i := 0; i < len h; i++)
		if(h[i] == '/')
			t += " / ";
		else
			t[len t] = h[i];
	s := "<h1 class=\"dir-list-head\">" + t + "</h1> <ul class=\"dir-list\">\n";
	a := mk.ls(dir);
	l: list of string;
	for(i = 0; i < len a; i++){
		n := a[i].name;
		isd := a[i].mode & Sys->DMDIR;
		if(dirfiltered(mk, reqpath + n, n, isd))
			continue;
		if(isd)
			n += "/";
		else
			n = dirclean(n);
		l = n :: l;
	}
	for(l = uniq(sort(l)); l != nil; l = tl l)
		s += "<li><a href=\"" + hd l + "\">" + hd l + "</a></li>\n";
	return s + "</ul>\n";
}

# werc's $dirfilter, for the entry n at the site path path
dirfiltered(mk: ref Mk, path, n: string, isd: int): int
{
	if(n == nil || n[0] == '.' || n[0] == '_')
		return 1;
	for(i := 0; i < len n; i++){
		c := n[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		     c == '_' || c == '+' || c == '-' || c == '.' || c == ',' || c == ':'))
			return 1;
	}
	case n {
	"index.md" or "index.html" or "index.txt" or "index.tpl" or
	"robots.txt" or "sitemap.txt" or "sitemap.xml" =>
		return 1;
	}
	if(isd)
		path += "/";
	return mk.hidden(path);
}

# $dirclean
dirclean(n: string): string
{
	for(x := list of {".md", ".html", ".txt"}; x != nil; x = tl x)
		if(suffix(n, hd x))
			return n[0:len n - len hd x];
	return n;
}

# nav_tree: each directory on the request's path listed, nested
navtree(mk: ref Mk, reqpath: string, reqpaths: list of string): string
{
	l: list of string;
	for(; reqpaths != nil; reqpaths = tl reqpaths){
		rp := hd reqpaths;
		a := mk.ls(sitedir + rp);
		if(rp[len rp - 1] != '/')
			rp += "/";
		for(i := 0; i < len a; i++){
			n := a[i].name;
			isd := a[i].mode & Sys->DMDIR;
			if(dirfiltered(mk, rp + n, n, isd))
				continue;
			if(isd)
				l = rp + n + "/" :: l;
			else if(suffix(n, ".md") || suffix(n, ".html") || suffix(n, ".txt"))
				l = rp + dirclean(n) :: l;
		}
	}
	s := "";
	if((t := mk.get("sideBarNavTitle")) != nil)
		s += "<p class=\"sideBarTitle\">" + t + ":</p>\n";
	s += "<ul>\n";
	lnf := 2;
	for(l = uniq(sort(l)); l != nil; l = tl l){
		path := hd l;
		d := "";
		if(suffix(path, "/")){
			d = "/";
			path = path[0:len path - 1];
		}
		nf := 1;
		for(i := 0; i < len path; i++)
			if(path[i] == '/')
				nf++;
		for(i = lnf; i < nf; i++)
			s += "<li><ul>\n";
		for(i = nf; i < lnf; i++)
			s += "</ul></li>\n";
		lnf = nf;
		(nil, bname) := splitlast(path);
		bname += d;
		for(i = 0; i < len bname; i++)
			if(bname[i] == '-' || bname[i] == '_')
				bname[i] = ' ';
		path += d;
		pa := path;
		if(!suffix(pa, "/"))
			pa += "/";
		if(prefix(reqpath + "/", pa))
			s += "<li><a href=\"" + path + "\" class=\"thisPage\">&raquo;<i> " + bname + "</i></a></li>\n";
		else
			s += "<li><a href=\"" + path + "\">&rsaquo; " + bname + "</a></li>\n";
	}
	for(i := 2; i < lnf; i++)
		s += "</ul></li>\n";
	return s + "</ul>\n";
}

# pageTitle from the path's elements: joined by " - ", a-b and _ as blanks
pathtitle(args: list of string): string
{
	s := "";
	for(; args != nil; args = tl args){
		if(s != nil)
			s += " ";
		s += hd args;
	}
	t := "";
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			t += " - ";
		else
			t[len t] = s[i];
	s = t;
	t = "";
	for(i = 0; i < len s; i++){
		if(i+2 < len s && islower(s[i]) && s[i+1] == '-' && islower(s[i+2])){
			t[len t] = s[i];
			t[len t] = ' ';
			t[len t] = s[i+2];
			i += 2;
			continue;
		}
		t[len t] = s[i];
	}
	for(i = 0; i < len t; i++)
		if(t[i] == '_')
			t[i] = ' ';
	return t;
}

# get_file_title: a .md's first line over ===, a .html's <title>
filetitle(mk: ref Mk, f: string): string
{
	t := mk.read(f);
	ls := split(t, '\n');
	if(suffix(f, ".md")){
		if(ls == nil || tl ls == nil)
			return nil;
		u := trim(hd tl ls);
		if(len u < 2 || len hd tl ls != len u)
			return nil;
		for(i := 0; i < len u; i++)
			if(u[i] != '=')
				return nil;
		if(tl tl ls != nil && trim(hd tl tl ls) != nil)
			return nil;
		return words(hd ls);
	}
	if(!suffix(f, ".html"))
		return nil;
	n := 0;
	for(l := ls; l != nil && n < 31; l = tl l){
		s := hd l;
		k := find(lower(s), "<title>", 0);
		if(k >= 0){
			s = s[k+7:];
			e := 0;
			while(e < len s && s[e] != '<')
				e++;
			if(e > 0 && (e == len s || prefix(lower(s[e:]), "</title>")))
				return words(s[0:e]);
		}
		n++;
	}
	# else the first text not in a tag
	n = 0;
	for(l = ls; l != nil && n < 31; l = tl l){
		s := hd l;
		i := 0;
		while(i < len s && s[i] == '<'){
			while(i < len s && s[i] != '>')
				i++;
			if(i < len s)
				i++;
		}
		e := i;
		while(e < len s && s[e] != '<')
			e++;
		if(e > i)
			return words(s[i:e]);
		n++;
	}
	return nil;
}

# headers.tpl, default_master.tpl and $res_tail, as werc writes them
master(mk: ref Mk, title, menu, head, body, foot: string): string
{
	s := "<!DOCTYPE HTML>\n<html>\n<head>\n\n";
	s += "    <title>" + title + "</title>\n\n";
	s += "    <link rel=\"stylesheet\" href=\"/pub/style/style.css\" type=\"text/css\" media=\"screen, handheld\" title=\"default\">\n";
	s += "    <link rel=\"shortcut icon\" href=\"/favicon.ico\" type=\"image/vnd.microsoft.icon\">\n";
	if(mk.isfile(sitedir + "/_werc/pub/style.css"))
		s += "    <link rel=\"stylesheet\" href=\"/_werc/pub/style.css\" type=\"text/css\" media=\"screen\" title=\"default\">\n";
	s += "\n    <meta charset=\"UTF-8\">\n";
	s += "    <meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n\n";
	if((v := mk.get("meta_description")) != nil)
		s += "    <meta name=\"description\" content=\"" + v + "\">\n";
	if((v = mk.get("meta_keywords")) != nil)
		s += "    <meta name=\"keywords\" content=\"" + v + "\">\n";
	s += libfile(mk, "headers.inc");
	if((v = mk.get("extraHeaders")) != nil)
		s += "    " + v + "\n";
	s += "\n</head>\n<body>\n";

	s += "<header>\n    <nav>\n" + libfile(mk, "top_bar.inc") + "    </nav>\n";
	s += "    <h1><a href=\"/\">" + mk.get("siteTitle") + " <span id=\"headerSubTitle\">" +
		mk.get("siteSubTitle") + "</span></a></h1>\n</header>\n\n";
	s += "    <nav id=\"side-bar\">\n        <div>\n" + menu + "        </div>\n    </nav>\n\n";
	s += "<article>\n" + head + body + foot + "</article>\n\n";
	s += "<footer>\n" + libfile(mk, "footer.inc") + "</footer>\n";
	return s + "</body></html>\n";
}

# get_lib_file: the site's _werc/lib, $masterSite's, then werc's lib;
# its contents, as werc's cat gives them
libfile(mk: ref Mk, name: string): string
{
	l := sitedir + "/_werc/lib/" :: nil;
	if((m := mk.get("masterSite")) != nil && wercroot != nil && !contains(m, "/") && m[0] != '.')
		l = wercroot + "/sites/" + m + "/_werc/lib/" :: l;
	if(wercroot != nil)
		l = wercroot + "/lib/" :: l;
	for(l = rev(l); l != nil; l = tl l)
		if(mk.isfile(hd l + name))
			return mk.read(hd l + name);
	return nil;
}

#
# _werc/config: rc, of which plain assignments and conf_hide_paths
# are taken; inside braces nothing is, as it may not run
#

said: list of string;

readconfig(mk: ref Mk, f, confwd: string)
{
	t := mk.read(f);
	if(t == nil)
		return;
	depth := 0;
	n := 0;
	for(ls := split(t, '\n'); ls != nil; ls = tl ls){
		line := hd ls;
		n++;
		(w, nb) := rcwords(line);
		if(w == nil){
			depth += nb;
			continue;
		}
		if(depth > 0 || nb != 0){
			depth += nb;
			notdone(f, n, line);
			continue;
		}
		first := hd w;
		if((eq := find(first, "=", 0)) > 0 && isname(first[0:eq])){
			# name=value, name=(a b), name=() ...
			val := first[eq+1:];
			rest := tl w;
			if(val == "(" || val == "(" + ")"){
				vs: list of string;
				for(; rest != nil && hd rest != ")"; rest = tl rest)
					vs = hd rest :: vs;
				if(rest != nil)
					rest = tl rest;
				val = joinwords(rev(vs));
			}
			if(rest != nil)
				notdone(f, n, line);
			else
				mk.set(first[0:eq], val);
			continue;
		}
		if(first == "conf_hide_paths"){
			for(w = tl w; w != nil; w = tl w){
				(re, err) := regex->compile("^" + confwd + hd w, 0);
				if(re != nil)
					mk.hides = re :: mk.hides;
				else
					notdone(f, n, line + " (" + err + ")");
			}
			continue;
		}
		notdone(f, n, line);
	}
}

notdone(f: string, n: int, line: string)
{
	k := sys->sprint("%s:%d: %s", f, n, line);
	for(l := said; l != nil; l = tl l)
		if(hd l == k)
			return;
	said = k :: said;
	sys->fprint(stderr, "wercfs: not taken: %s\n", k);
}

# A line's words as rc reads them (quotes removed, ( ) and = kept in
# place, # to the end a comment), and the braces it opens less those it
# closes; ( and ) are words of their own after an =
rcwords(s: string): (list of string, int)
{
	w: list of string;
	nb := 0;
	cur := "";
	inword := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'\'' =>
			inword = 1;
			for(i++; i < len s; i++){
				if(s[i] == '\''){
					if(i+1 < len s && s[i+1] == '\''){
						cur[len cur] = '\'';
						i++;
						continue;
					}
					break;
				}
				cur[len cur] = s[i];
			}
		'#' =>
			i = len s;
		' ' or '\t' or ';' =>
			if(inword)
				w = cur :: w;
			cur = "";
			inword = 0;
		'(' or ')' =>
			if(c == '(' && inword && suffix(cur, "=")){
				cur[len cur] = c;
				w = cur :: w;
				cur = "";
				inword = 0;
				continue;
			}
			if(inword)
				w = cur :: w;
			w = s[i:i+1] :: w;
			cur = "";
			inword = 0;
		'{' =>
			nb++;
			if(inword)
				w = cur :: w;
			cur = "";
			inword = 0;
			w = "{" :: w;
		'}' =>
			nb--;
			if(inword)
				w = cur :: w;
			cur = "";
			inword = 0;
			w = "}" :: w;
		'^' =>
			;
		* =>
			cur[len cur] = c;
			inword = 1;
		}
	}
	if(inword)
		w = cur :: w;
	return (rev(w), nb);
}

isname(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || i > 0 && c >= '0' && c <= '9'))
			return 0;
	}
	return 1;
}

#
# Files and strings
#

readfile(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	a := array[0] of byte;
	while(len a < MAXFILE && (n := sys->read(fd, buf, len buf)) > 0){
		b := array[len a + n] of byte;
		b[0:] = a;
		b[len a:] = buf[0:n];
		a = b;
	}
	return string a;
}

readsmall(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

readdirnames(name: string): (array of ref Sys->Dir, int)
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return (nil, -1);
	a: array of ref Sys->Dir;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		b := array[len a + n] of ref Sys->Dir;
		b[0:] = a;
		for(i := 0; i < n; i++)
			b[len a + i] = ref d[i];
		a = b;
	}
	return (a, len a);
}

isdir(name: string): int
{
	(ok, d) := sys->stat(name);
	return ok >= 0 && (d.mode & Sys->DMDIR);
}

cleanpath(s: string): string
{
	while(len s > 1 && s[len s - 1] == '/')
		s = s[0:len s - 1];
	return s;
}

# (all before the last /, all after it)
splitlast(s: string): (string, string)
{
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == '/')
			return (s[0:i], s[i+1:]);
	return (nil, s);
}

# s's fields between c's, empty ones left out
split(s: string, c: int): list of string
{
	l: list of string;
	st := 0;
	for(i := 0; i <= len s; i++)
		if(i == len s || s[i] == c){
			if(i > st || c == '\n')
				l = s[st:i] :: l;
			st = i+1;
		}
	if(c == '\n' && l != nil && hd l == nil)
		l = tl l;
	return rev(l);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

sort(l: list of string): list of string
{
	n := 0;
	for(p := l; p != nil; p = tl p)
		n++;
	a := array[n] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	# insertion sort: directories are small
	for(i = 1; i < n; i++){
		s := a[i];
		j := i;
		for(; j > 0 && a[j-1] > s; j--)
			a[j] = a[j-1];
		a[j] = s;
	}
	r: list of string;
	for(i = n-1; i >= 0; i--)
		r = a[i] :: r;
	return r;
}

uniq(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		if(r == nil || hd r != hd l)
			r = hd l :: r;
	return rev(r);
}

# s's words with one blank between them
words(s: string): string
{
	t := "";
	sp := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\r' || c == '\n'){
			sp = 1;
			continue;
		}
		if(sp && t != nil)
			t[len t] = ' ';
		sp = 0;
		t[len t] = c;
	}
	return t;
}

joinwords(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != nil)
			s += " ";
		s += hd l;
	}
	return s;
}

trim(s: string): string
{
	return words(s);
}

find(s, t: string, from: int): int
{
	for(i := from; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}

contains(s, t: string): int
{
	return find(s, t, 0) >= 0;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

suffix(s, x: string): int
{
	return len s >= len x && s[len s - len x:] == x;
}

lower(s: string): string
{
	t := s;
	for(i := 0; i < len t; i++)
		if(t[i] >= 'A' && t[i] <= 'Z')
			t[i] += 'a' - 'A';
	return t;
}

islower(c: int): int
{
	return c >= 'a' && c <= 'z';
}
