#
# jsdom.b - a web page's realm (Js->page): the natives the DOM
# is built on, the event loop, fetching, and the realm's confinement.
# Included by js.b.
#
# The DOM's interfaces (Node, Element, Event, URL, fetch, ...) are
# written in JavaScript, in /lib/js/dom.js, over the natives here, which
# name nodes by their index in the host's Dom->Doc.  The prelude is a
# function given the natives; it returns the hooks the loop calls:
#
#	start()			run the document's scripts, then its load events
#	timer(id)		a timer set with N.timer has fired
#	fetched(id, status, statustext, url, header, body, err)
#	event(kind, node, x, y, key)	from the host; true if the default was prevented
#	resolve(base, ref)	a URL resolved, for module specifiers
#

pgh: ref Js->Host;
pgd: ref Dom->Doc;
pghooks := -1;		# the prelude's hooks object
pgt0 := 0;		# when the page started, for performance.now()
pgpending: list of ref Pending;	# what a task asked of the host, done when it ends
timerc: chan of int;
fetchc: chan of ref Fetched;

Pending: adt {
	pick {
	Navigate =>
		url:	string;
		replace:	int;
	Scroll =>
		x, y:	int;
	}
};

Fetched: adt {
	id:	int;
	status:	int;
	statustext:	string;
	url:	string;
	header:	string;
	ctype:	string;
	body:	array of byte;
	err:	string;
};

Prelude: con "/lib/js/dom.js";

page(h: ref Js->Host): string
{
	err := init();
	if(err != nil)
		return err;
	dom = load Dom Dom->PATH;
	if(dom == nil)
		return sys->sprint("cannot load %s: %r", Dom->PATH);
	# what the realm would otherwise load when first used, which the
	# confined namespace will not have
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
	if(keyring == nil)
		keyring = load Keyring Keyring->PATH;
	jsparse->parse("/(?:)/u; class C { #x; m() { return this.#x; } }", 0, 0);	# its checker and the regular expressions
	(src, rerr) := readsrc(Prelude);
	if(rerr != nil)
		return rerr;
	pgh = h;
	pgd = h.doc;
	pgt0 = sys->millisec();
	pgpending = nil;
	timerc = chan of int;
	fetchc = chan of ref Fetched;
	setloader(pageloader);
	setoutput(pageconsole);
	if((err = confine(h.grants)) != nil)
		return err;
	h.lock(h.id);
	{
		f := selfhost(src);
		hk := call(f, undef, array[] of {objv(domnatives())});
		if(hk.t != Tobj)
			typeerr("the DOM prelude returned no hooks");
		pghooks = keep(hk.x);
	} exception {
	"js:throw" =>
		h.unlock(h.id);
		return "the DOM prelude: " + showexc(thrown);
	}
	h.unlock(h.id);
	hook("start", nil);
	for(;;) alt {
	e := <-h.events =>
		pick ev := e {
		Quit =>
			return nil;
		Click =>
			ev.reply <-= hook("event", array[] of {strv("click"), num(real ev.node), num(real ev.x), num(real ev.y), undef});
		Input =>
			ev.reply <-= hook("event", array[] of {strv("input"), num(real ev.node), undef, undef, undef});
		Submit =>
			ev.reply <-= hook("event", array[] of {strv("submit"), num(real ev.form), num(real ev.submitter), undef, undef});
		Key =>
			ev.reply <-= hook("event", array[] of {strv("key"), num(real ev.node), undef, undef, num(real ev.key)});
		Resize =>
			hook("event", array[] of {strv("resize"), undef, undef, undef, undef});
		Scroll =>
			hook("event", array[] of {strv("scroll"), undef, undef, undef, undef});
		}
	id := <-timerc =>
		hook("timer", array[] of {num(real id)});
	f := <-fetchc =>
		body := undef;
		if(f.body != nil)
			body = strv(jslex->utf16(f.body));
		hook("fetched", array[] of {num(real f.id), num(real f.status), strv(f.statustext),
			strv(tojs(f.url)), strv(f.header), body, strnil(f.err)});
	}
}

strnil(s: string): V
{
	if(s == nil)
		return undef;
	return strv(s);
}

# One task: the hook called with the host's lock held, then its
# microtasks; what it asked of the host is done once the lock is let
# go.  Its result, as a truth value.
hook(name: string, args: array of V): int
{
	h := pgh;
	h.lock(h.id);
	gen := pgd.gen;
	r := 0;
	sp0 := sp;
	nf := nframe;
	{
		f := getv(objv(pghooks), intern(name));
		if(f.t == Tobj)
			r = truthy(call(f, objv(pghooks), args));
		runjobs();
	} exception e {
	"js:throw" =>
		sp = sp0;
		nframe = nf;
		pageconsole("uncaught " + showexc(thrown));
	"*" =>
		sp = sp0;
		nframe = nf;
		pageconsole("internal error: " + e);
	}
	h.unlock(h.id);
	for(l := rev(pgpending); l != nil; l = tl l)
		pick p := hd l {
		Navigate =>
			h.navigate(h.id, p.url, p.replace);
		Scroll =>
			h.scroll(h.id, p.x, p.y);
		}
	pgpending = nil;
	if(pgd.gen != gen)
		h.changed(h.id);
	return r;
}

rev(l: list of ref Pending): list of ref Pending
{
	r: list of ref Pending;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

pageconsole(s: string)
{
	if(pgh != nil && pgh.console != nil)
		pgh.console(pgh.id, fromjs(s));
}

# ---- confinement (§6.1) ----
#
# A new process group and namespace holding only the grants, bound into
# an empty tree (/tmp/.js/<pid>, which the host removes when the page is
# gone) that then replaces the root; no file descriptors but standard
# error; no devices.

confine(grants: list of (string, string, int)): string
{
	pid := sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->NEWENV, nil);
	top := "/tmp/.js";
	sys->create(top, Sys->OREAD, Sys->DMDIR|8r700);
	shadow := sys->sprint("%s/%d", top, pid);
	if(mkdirs(shadow) < 0)
		return sys->sprint("confine: %s: %r", shadow);
	for(l := grants; l != nil; l = tl l) {
		(dst, src, rw) := hd l;
		if(mkdirs(shadow + dst) < 0)
			return sys->sprint("confine: %s: %r", dst);
		flag := Sys->MREPL;
		if(!rw)
			flag |= Sys->MREADONLY;
		if(sys->bind(src, shadow + dst, flag) < 0)
			return sys->sprint("confine: bind %s %s: %r", src, dst);
	}
	if(sys->bind(shadow, "/", Sys->MREPL|Sys->MREADONLY) < 0)
		return sys->sprint("confine: bind %s /: %r", shadow);
	sys->pctl(Sys->NEWFD, 2 :: nil);
	sys->pctl(Sys->NODEVS, nil);
	return nil;
}

mkdirs(path: string): int
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return 0;
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/')
			break;
	if(i > 0 && mkdirs(path[0:i]) < 0)
		return -1;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r755);
	if(fd == nil)
		return -1;
	return 0;
}

readsrc(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	return (jslex->utf16(readfd(fd)), nil);
}

readfd(fd: ref Sys->FD): array of byte
{
	buf := array[0] of byte;
	b := array[65536] of byte;
	for(;;) {
		n := sys->read(fd, b, len b);
		if(n <= 0)
			break;
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = b[0:n];
		buf = nb;
	}
	return buf;
}

# ---- strings ----
#
# Dis strings hold 16-bit characters, so the engine's UTF-16 strings
# and the document's are the same thing: a character past the BMP is a
# surrogate pair in both.  Only bytes for the network need converting.

tojs(s: string): string
{
	return s;
}

fromjs(s: string): string
{
	return s;
}

# UTF-16 as UTF-8 (a lone surrogate as U+FFFD)
utf8bytes(s: string): array of byte
{
	n := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < 16r80)
			n++;
		else if(c < 16r800)
			n += 2;
		else if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF) {
			n += 4;
			i++;
		} else
			n += 3;
	}
	b := array[n] of byte;
	k := 0;
	for(i = 0; i < len s; i++) {
		c := s[i];
		if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF) {
			c = 16r10000 + ((c - 16rD800) << 10) + (s[i+1] - 16rDC00);
			i++;
		} else if(c >= 16rD800 && c <= 16rDFFF)
			c = 16rFFFD;
		if(c < 16r80)
			b[k++] = byte c;
		else if(c < 16r800) {
			b[k++] = byte (16rC0 | (c >> 6));
			b[k++] = byte (16r80 | (c & 16r3F));
		} else if(c < 16r10000) {
			b[k++] = byte (16rE0 | (c >> 12));
			b[k++] = byte (16r80 | ((c >> 6) & 16r3F));
			b[k++] = byte (16r80 | (c & 16r3F));
		} else {
			b[k++] = byte (16rF0 | (c >> 18));
			b[k++] = byte (16r80 | ((c >> 12) & 16r3F));
			b[k++] = byte (16r80 | ((c >> 6) & 16r3F));
			b[k++] = byte (16r80 | (c & 16r3F));
		}
	}
	return b;
}

jsarg(a, n, i: int): string
{
	return fromjs(tostring(arg(a, n, i)));
}

# ---- the natives ----

domnatives(): int
{
	o := newplain();
	method(o, "kind", 1, dn_kind);
	method(o, "name", 1, dn_name);
	method(o, "ns", 1, dn_ns);
	method(o, "parent", 1, dn_parent);
	method(o, "first", 1, dn_first);
	method(o, "last", 1, dn_last);
	method(o, "next", 1, dn_next);
	method(o, "prev", 1, dn_prev);
	method(o, "attr", 2, dn_attr);
	method(o, "setattr", 3, dn_setattr);
	method(o, "delattr", 2, dn_delattr);
	method(o, "attrs", 1, dn_attrs);
	method(o, "data", 1, dn_data);
	method(o, "setdata", 2, dn_setdata);
	method(o, "textof", 1, dn_textof);
	method(o, "create", 3, dn_create);
	method(o, "insert", 3, dn_insert);
	method(o, "remove", 1, dn_remove);
	method(o, "children", 2, dn_children);
	method(o, "descendants", 3, dn_descendants);
	method(o, "match", 2, dn_match);
	method(o, "select", 3, dn_select);
	method(o, "parse", 1, dn_parse);
	method(o, "markup", 2, dn_markup);
	method(o, "box", 1, dn_box);
	method(o, "computed", 2, dn_computed);
	method(o, "media", 1, dn_media);
	method(o, "viewport", 0, dn_viewport);
	method(o, "now", 0, dn_now);
	method(o, "timer", 2, dn_timer);
	method(o, "fetch", 5, dn_fetch);
	method(o, "fetchsync", 1, dn_fetchsync);
	method(o, "navigate", 2, dn_navigate);
	method(o, "scroll", 2, dn_scroll);
	method(o, "log", 1, dn_log);
	method(o, "eval", 2, dn_eval);
	method(o, "evalmodule", 2, dn_evalmodule);
	method(o, "random", 1, dn_random);
	method(o, "gen", 0, dn_gen);
	method(o, "drain", 0, dn_drain);
	value(o, "url", strv(tojs(pgh.url)));
	return o;
}

nodearg(a, n, i: int): int
{
	v := arg(a, n, i);
	if(v.t != Tnum)
		typeerr("not a node");
	x := int v.n;
	if(x < 1 || x >= pgd.n)
		typeerr("not a node");
	return x;
}

# a node or 0
nodearg0(a, n, i: int): int
{
	v := arg(a, n, i);
	if(v.t != Tnum || int v.n == 0)
		return 0;
	return nodearg(a, n, i);
}

inum(i: int): V
{
	return V(Tnum, 0, real i);
}

dn_kind(nil: V, a, n: int, nil: V, nil: int): V
{
	return inum(pgd.nodes[nodearg(a, n, 0)].kind);
}

dn_name(nil: V, a, n: int, nil: V, nil: int): V
{
	return strv(tojs(pgd.nodes[nodearg(a, n, 0)].name));
}

dn_ns(nil: V, a, n: int, nil: V, nil: int): V
{
	return inum(pgd.nodes[nodearg(a, n, 0)].ns);
}

dn_parent(nil: V, a, n: int, nil: V, nil: int): V
{
	return inum(pgd.nodes[nodearg(a, n, 0)].parent);
}

dn_first(nil: V, a, n: int, nil: V, nil: int): V
{
	return inum(pgd.nodes[nodearg(a, n, 0)].first);
}

dn_last(nil: V, a, n: int, nil: V, nil: int): V
{
	return inum(pgd.nodes[nodearg(a, n, 0)].last);
}

dn_next(nil: V, a, n: int, nil: V, nil: int): V
{
	return inum(pgd.nodes[nodearg(a, n, 0)].next);
}

dn_prev(nil: V, a, n: int, nil: V, nil: int): V
{
	return inum(pgd.nodes[nodearg(a, n, 0)].prev);
}

dn_attr(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	name := jsarg(a, n, 1);
	for(l := pgd.nodes[x].attrs; l != nil; l = tl l)
		if((hd l).t0 == name)
			return strv(tojs((hd l).t1));
	return null;
}

dn_setattr(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	pgd.setattr(x, jsarg(a, n, 1), jsarg(a, n, 2));
	return undef;
}

dn_delattr(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	pgd.delattr(x, jsarg(a, n, 1));
	return undef;
}

# [name, value, name, value, ...]
dn_attrs(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	l := pgd.nodes[x].attrs;
	r := array[2 * len l] of V;
	for(i := 0; l != nil; l = tl l) {
		r[i++] = strv(tojs((hd l).t0));
		r[i++] = strv(tojs((hd l).t1));
	}
	return objv(arrayof(r));
}

dn_data(nil: V, a, n: int, nil: V, nil: int): V
{
	return strv(tojs(pgd.nodes[nodearg(a, n, 0)].text));
}

dn_setdata(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	pgd.settext(x, jsarg(a, n, 1));
	return undef;
}

dn_textof(nil: V, a, n: int, nil: V, nil: int): V
{
	return strv(tojs(pgd.textof(nodearg(a, n, 0))));
}

dn_create(nil: V, a, n: int, nil: V, nil: int): V
{
	kind := toint32(arg(a, n, 0));
	if(kind < Dom->Document || kind > Dom->Comment)
		typeerr("no such kind of node");
	ns := toint32(arg(a, n, 2));
	x := pgd.create(kind, jsarg(a, n, 1), ns);
	if(kind == Dom->Document)
		pgd.nodes[x].name = "#document-fragment";
	return inum(x);
}

dn_insert(nil: V, a, n: int, nil: V, nil: int): V
{
	p := nodearg(a, n, 0);
	c := nodearg(a, n, 1);
	b := nodearg0(a, n, 2);
	pgd.insert(p, c, b);
	return undef;
}

dn_remove(nil: V, a, n: int, nil: V, nil: int): V
{
	pgd.remove(nodearg(a, n, 0));
	return undef;
}

# the children of x, all or only its elements
dn_children(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	elems := truthy(arg(a, n, 1));
	k := 0;
	for(c := pgd.nodes[x].first; c != 0; c = pgd.nodes[c].next)
		if(!elems || pgd.nodes[c].kind == Dom->Element)
			k++;
	r := array[k] of V;
	k = 0;
	for(c = pgd.nodes[x].first; c != 0; c = pgd.nodes[c].next)
		if(!elems || pgd.nodes[c].kind == Dom->Element)
			r[k++] = inum(c);
	return objv(arrayof(r));
}

# the elements under x in document order: those with a name ("*": all),
# or (by "class") those having every one of a set of classes, or (by
# "id") the first with an id
dn_descendants(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	how := jsarg(a, n, 1);
	what := jsarg(a, n, 2);
	classes: list of string;
	if(how == "class")
		(nil, classes) = sys->tokenize(what, " \t\n\r\f");
	lname := lowerascii(what);
	r: list of int;
	k := 0;
	for(m := pgd.nodes[x].first; m != 0; m = nextin(m, x)) {
		nd := pgd.nodes[m];
		if(nd.kind != Dom->Element)
			continue;
		case how {
		"name" =>
			if(what != "*" && nd.name != what && !(nd.ns == Dom->HTML && nd.name == lname))
				continue;
		"class" =>
			if(classes == nil || !hasclasses(pgd.attr(m, "class"), classes))
				continue;
		"id" =>
			if(pgd.attr(m, "id") != what)
				continue;
			return inum(m);
		"nameattr" =>
			if(pgd.attr(m, "name") != what)
				continue;
		}
		r = m :: r;
		k++;
	}
	if(how == "id")
		return inum(0);
	v := array[k] of V;
	for(; r != nil; r = tl r)
		v[--k] = inum(hd r);
	return objv(arrayof(v));
}

nextin(m, top: int): int
{
	if(pgd.nodes[m].first != 0)
		return pgd.nodes[m].first;
	while(m != top && m != 0) {
		if(pgd.nodes[m].next != 0)
			return pgd.nodes[m].next;
		m = pgd.nodes[m].parent;
	}
	return 0;
}

hasclasses(attr: string, want: list of string): int
{
	(nil, have) := sys->tokenize(attr, " \t\n\r\f");
	for(; want != nil; want = tl want) {
		l := have;
		for(; l != nil; l = tl l)
			if(hd l == hd want)
				break;
		if(l == nil)
			return 0;
	}
	return 1;
}

lowerascii(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			break;
	if(i == len s)
		return s;
	r := s;
	for(; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

# 1, 0, or -1 if not a valid selector
dn_match(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	return inum(pgh.match(pgh.id, x, jsarg(a, n, 1)));
}

# all: an array of nodes; else the first, or 0; null if not a valid selector
dn_select(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	all := truthy(arg(a, n, 2));
	(ok, l) := pgh.select(pgh.id, x, jsarg(a, n, 1), all);
	if(ok < 0)
		return null;
	if(!all) {
		if(l == nil)
			return inum(0);
		return inum(hd l);
	}
	r := array[len l] of V;
	for(i := 0; l != nil; l = tl l)
		r[i++] = inum(hd l);
	return objv(arrayof(r));
}

# markup parsed into new nodes of the document, not in the tree: an
# array of the top ones
dn_parse(nil: V, a, n: int, nil: V, nil: int): V
{
	s := jsarg(a, n, 0);
	src := pgh.parse(pgh.id, s);
	if(src == nil)
		return objv(arrayof(array[0] of V));
	body := src.find(1, Dom->Tbody);
	r: list of int;
	k := 0;
	if(body != 0) {
		for(c := src.nodes[body].first; c != 0; c = src.nodes[c].next) {
			r = copynode(src, c) :: r;
			k++;
		}
	}
	v := array[k] of V;
	for(; r != nil; r = tl r)
		v[--k] = inum(hd r);
	return objv(arrayof(v));
}

copynode(src: ref Dom->Doc, x: int): int
{
	s := src.nodes[x];
	y := pgd.create(s.kind, s.name, s.ns);
	d := pgd.nodes[y];
	d.attrs = s.attrs;
	d.text = s.text;
	for(c := s.first; c != 0; c = src.nodes[c].next)
		pgd.append(y, copynode(src, c));
	return y;
}

# node x as HTML (§13.3): itself and what it holds, or only what it holds
dn_markup(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	outer := truthy(arg(a, n, 1));
	parts: list of string;
	if(outer)
		parts = markup(x, parts);
	else
		for(c := pgd.nodes[x].first; c != 0; c = pgd.nodes[c].next)
			parts = markup(c, parts);
	return strv(tojs(joinrev(parts)));
}

# the strings of l, last first, joined: halves at a time, so that
# each character is copied O(log n) times, not O(n)
joinrev(l: list of string): string
{
	a := array[len l] of string;
	for(i := len a - 1; l != nil; l = tl l)
		a[i--] = hd l;
	return joinarr(a);
}

joinarr(a: array of string): string
{
	case len a {
	0 =>
		return "";
	1 =>
		return a[0];
	}
	m := len a / 2;
	return joinarr(a[0:m]) + joinarr(a[m:]);
}

voidel(name: string): int
{
	case name {
	"area" or "base" or "basefont" or "bgsound" or "br" or "col" or "embed" or "frame" or
	"hr" or "img" or "input" or "keygen" or "link" or "meta" or "param" or "source" or
	"track" or "wbr" =>
		return 1;
	}
	return 0;
}

rawtext(name: string): int
{
	case name {
	"style" or "script" or "xmp" or "iframe" or "noembed" or "noframes" or "plaintext" or "noscript" =>
		return 1;
	}
	return 0;
}

markup(x: int, parts: list of string): list of string
{
	nd := pgd.nodes[x];
	case nd.kind {
	Dom->Element =>
		s := "<" + nd.name;
		for(l := nd.attrs; l != nil; l = tl l)
			s += " " + (hd l).t0 + "=\"" + escapehtml((hd l).t1, 1) + "\"";
		parts = s + ">" :: parts;
		if(nd.ns == Dom->HTML && voidel(nd.name))
			return parts;
		for(c := nd.first; c != 0; c = pgd.nodes[c].next)
			parts = markup(c, parts);
		parts = "</" + nd.name + ">" :: parts;
	Dom->Text =>
		p := pgd.nodes[nd.parent];
		if(nd.parent != 0 && p.kind == Dom->Element && p.ns == Dom->HTML && rawtext(p.name))
			parts = nd.text :: parts;
		else
			parts = escapehtml(nd.text, 0) :: parts;
	Dom->Comment =>
		parts = "<!--" + nd.text + "-->" :: parts;
	Dom->Doctype =>
		parts = "<!DOCTYPE " + nd.name + ">" :: parts;
	Dom->Document =>
		for(c := nd.first; c != 0; c = pgd.nodes[c].next)
			parts = markup(c, parts);
	}
	return parts;
}

escapehtml(s: string, attr: int): string
{
	for(i := 0; i < len s; i++)
		if(needesc(s[i]))
			break;
	if(i == len s)
		return s;
	r := s[0:i];
	for(; i < len s; i++) {
		c := s[i];
		case c {
		'&' =>
			r += "&amp;";
		16rA0 =>
			r += "&nbsp;";
		'<' =>
			if(attr)
				r[len r] = c;
			else
				r += "&lt;";
		'>' =>
			if(attr)
				r[len r] = c;
			else
				r += "&gt;";
		'"' =>
			if(attr)
				r += "&quot;";
			else
				r[len r] = c;
		* =>
			r[len r] = c;
		}
	}
	return r;
}

needesc(c: int): int
{
	return c == '&' || c == '<' || c == '>' || c == '"' || c == 16rA0;
}

# [shown, x, y, width, height]
dn_box(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	(shown, bx, by, bw, bh) := pgh.box(pgh.id, x);
	return objv(arrayof(array[] of {inum(shown), inum(bx), inum(by), inum(bw), inum(bh)}));
}

dn_computed(nil: V, a, n: int, nil: V, nil: int): V
{
	x := nodearg(a, n, 0);
	return strv(tojs(pgh.computed(pgh.id, x, jsarg(a, n, 1))));
}

dn_media(nil: V, a, n: int, nil: V, nil: int): V
{
	return bool(pgh.media(pgh.id, jsarg(a, n, 0)) > 0);
}

dn_viewport(nil: V, nil, nil: int, nil: V, nil: int): V
{
	(w, h, sx, sy) := pgh.viewport(pgh.id);
	return objv(arrayof(array[] of {inum(w), inum(h), inum(sx), inum(sy)}));
}

dn_now(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return inum(sys->millisec() - pgt0);
}

dn_timer(nil: V, a, n: int, nil: V, nil: int): V
{
	id := toint32(arg(a, n, 0));
	ms := toint32(arg(a, n, 1));
	if(ms < 0)
		ms = 0;
	spawn sleeper(timerc, id, ms);
	return undef;
}

sleeper(c: chan of int, id, ms: int)
{
	sys->sleep(ms);
	c <-= id;
}

dn_navigate(nil: V, a, n: int, nil: V, nil: int): V
{
	pgpending = ref Pending.Navigate(jsarg(a, n, 0), truthy(arg(a, n, 1))) :: pgpending;
	return undef;
}

dn_scroll(nil: V, a, n: int, nil: V, nil: int): V
{
	pgpending = ref Pending.Scroll(toint32(arg(a, n, 0)), toint32(arg(a, n, 1))) :: pgpending;
	return undef;
}

dn_log(nil: V, a, n: int, nil: V, nil: int): V
{
	pageconsole(tostring(arg(a, n, 0)));
	return undef;
}

# run the jobs waiting (promise reactions), as after each script
dn_drain(nil: V, nil, nil: int, nil: V, nil: int): V
{
	runjobs();
	return undef;
}

dn_gen(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return inum(pgd.gen);
}

# [0, completion value] or [1, what was thrown]
dn_eval(nil: V, a, n: int, nil: V, nil: int): V
{
	src := tostring(arg(a, n, 0));
	name := tostring(arg(a, n, 1));
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		return objv(arrayof(array[] of {inum(1), objv(newerror(SyntaxError, name + ":" + err))}));
	sp0 := sp;
	nf := nframe;
	{
		pick p := prog {
		Program =>
			c := compilescript(p, src, 0, 0);
			setfile(c, fromjs(name));
			keepcode(c);
			v := runcode(c);
			sp = sp0;
			return objv(arrayof(array[] of {inum(0), v}));
		}
	} exception {
	"js:throw" =>
		sp = sp0;
		nframe = nf;
		return objv(arrayof(array[] of {inum(1), thrown}));
	}
	return undef;
}

dn_evalmodule(nil: V, a, n: int, nil: V, nil: int): V
{
	src := tostring(arg(a, n, 0));
	url := jsarg(a, n, 1);
	sp0 := sp;
	nf := nframe;
	{
		runmodule(src, url);
		sp = sp0;
		return objv(arrayof(array[] of {inum(0), undef}));
	} exception {
	"js:throw" =>
		sp = sp0;
		nframe = nf;
		return objv(arrayof(array[] of {inum(1), thrown}));
	}
	return undef;
}

# a module's URL from its referrer's and the specifier, and its source
pageloader(referrer, spec: string): (string, string, string)
{
	url := spec;
	{
		f := getv(objv(pghooks), intern("resolve"));
		u := call(f, objv(pghooks), array[] of {strv(tojs(referrer)), strv(tojs(spec))});
		if(u.t != Tstr)
			return (nil, nil, "cannot resolve module " + spec);
		url = fromjs(str(u.x));
	} exception {
	"js:throw" =>
		return (nil, nil, "cannot resolve module " + spec + ": " + showexc(thrown));
	}
	f := webget(0, "GET", url, nil, nil);
	if(f.err != nil)
		return (nil, nil, "cannot load module " + spec + ": " + f.err);
	if(f.status != 200 && f.status != 0)
		return (nil, nil, sys->sprint("cannot load module %s: %d %s", spec, f.status, f.statustext));
	return (f.url, jslex->utf16(f.body), nil);
}

dn_random(nil: V, a, n: int, nil: V, nil: int): V
{
	k := toint32(arg(a, n, 0));
	if(k < 0 || k > 65536)
		throwerr(RangeError, "too many random bytes");
	b := array[k] of byte;
	if(k > 0) {
		r := IPint.random(8*k, 8*k).iptobytes();
		for(i := 0; i < k; i++)
			if(i < len r)
				b[i] = r[i];
	}
	v := array[k] of V;
	for(i := 0; i < k; i++)
		v[i] = inum(int b[i]);
	return objv(arrayof(v));
}

# ---- fetching ----

# fetch(id, method, url, header lines, body): the result comes to the
# fetched hook
dn_fetch(nil: V, a, n: int, nil: V, nil: int): V
{
	id := toint32(arg(a, n, 0));
	method := jsarg(a, n, 1);
	url := jsarg(a, n, 2);
	hdr := jsarg(a, n, 3);
	body: array of byte;
	if(arg(a, n, 4).t == Tstr)
		body = utf8bytes(jsarg(a, n, 4));
	spawn fetcher(fetchc, id, method, url, hdr, body);
	return undef;
}

fetcher(c: chan of ref Fetched, id: int, method, url, hdr: string, body: array of byte)
{
	f: ref Fetched;
	{
		f = webget(id, method, url, hdr, body);
	} exception e {
	"*" =>
		f = ref Fetched(id, 0, "", url, "", "", nil, "internal error: " + e);
	}
	c <-= f;
}

# fetchsync(url): [status, content type, body, url] or [0, error]
dn_fetchsync(nil: V, a, n: int, nil: V, nil: int): V
{
	f := webget(0, "GET", jsarg(a, n, 0), nil, nil);
	if(f.err != nil)
		return objv(arrayof(array[] of {inum(0), strv(f.err)}));
	return objv(arrayof(array[] of {inum(f.status), strv(f.ctype),
		strv(jslex->utf16(f.body)), strv(tojs(f.url))}));
}

webget(id: int, method, url, hdr: string, body: array of byte): ref Fetched
{
	f := ref Fetched(id, 0, "", url, "", "", nil, nil);
	(scheme, rest) := urlscheme(url);
	case scheme {
	"data" =>
		(f.ctype, f.body, f.err) = dataurl(rest);
		if(f.err == nil) {
			f.status = 200;
			f.statustext = "OK";
		}
	"file" =>
		path := rest;
		if(len path > 2 && path[0:2] == "//") {
			for(i := 2; i < len path && path[i] != '/'; i++)
				;
			path = path[i:];
		}
		for(i := 0; i < len path; i++)
			if(path[i] == '?' || path[i] == '#')
				break;
		path = path[0:i];
		fd := sys->open(path, Sys->OREAD);
		if(fd == nil)
			f.err = sys->sprint("%s: %r", path);
		else {
			f.body = readfd(fd);
			f.status = 200;
			f.statustext = "OK";
		}
	"http" or "https" =>
		webfsget(f, method, hdr, body);
	* =>
		f.err = "cannot fetch " + scheme + ": URLs";
	}
	return f;
}

urlscheme(url: string): (string, string)
{
	for(i := 0; i < len url; i++) {
		c := url[i];
		if(c == ':')
			return (lowerascii(url[0:i]), url[i+1:]);
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')))
			break;
	}
	return ("", url);
}

dataurl(s: string): (string, array of byte, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ',')
			break;
	if(i == len s)
		return (nil, nil, "bad data: URL");
	meta := s[0:i];
	data := s[i+1:];
	b64 := 0;
	if(len meta >= 7 && lowerascii(meta[len meta - 7:]) == ";base64") {
		b64 = 1;
		meta = meta[0:len meta - 7];
	}
	if(meta == "")
		meta = "text/plain;charset=US-ASCII";
	raw := pctdecode(data);
	if(!b64)
		return (meta, raw, nil);
	return (meta, base64dec(raw), nil);
}

pctdecode(s: string): array of byte
{
	b := array of byte s;
	r := array[len b] of byte;
	k := 0;
	for(i := 0; i < len b; i++) {
		if(b[i] == byte '%' && i + 2 < len b && hexv(int b[i+1]) >= 0 && hexv(int b[i+2]) >= 0) {
			r[k++] = byte (hexv(int b[i+1]) * 16 + hexv(int b[i+2]));
			i += 2;
		} else
			r[k++] = b[i];
	}
	return r[0:k];
}

base64dec(b: array of byte): array of byte
{
	r := array[len b * 3 / 4 + 3] of byte;
	k := 0;
	acc := 0;
	nb := 0;
	for(i := 0; i < len b; i++) {
		c := int b[i];
		v: int;
		if(c >= 'A' && c <= 'Z')
			v = c - 'A';
		else if(c >= 'a' && c <= 'z')
			v = c - 'a' + 26;
		else if(c >= '0' && c <= '9')
			v = c - '0' + 52;
		else if(c == '+' || c == '-')
			v = 62;
		else if(c == '/' || c == '_')
			v = 63;
		else
			continue;
		acc = (acc << 6) | v;
		nb += 6;
		if(nb >= 8) {
			nb -= 8;
			r[k++] = byte (acc >> nb);
		}
	}
	return r[0:k];
}

Webfs: con "/mnt/web";

webfsget(f: ref Fetched, method, hdr: string, body: array of byte)
{
	cfd := sys->open(Webfs + "/clone", Sys->OREAD);
	if(cfd == nil) {
		f.err = sys->sprint("no network: %r");
		return;
	}
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0) {
		f.err = sys->sprint("webfs clone: %r");
		return;
	}
	id := trimsp(string buf[0:n]);
	dir := Webfs + "/" + id;
	ctl := sys->open(dir + "/ctl", Sys->OWRITE);
	if(ctl == nil || sys->fprint(ctl, "url %s", f.url) < 0) {
		f.err = sys->sprint("webfs: %r");
		return;
	}
	(nil, hl) := sys->tokenize(hdr, "\n");
	for(; hl != nil; hl = tl hl)
		if(sys->fprint(ctl, "header %s", hd hl) < 0) {
			f.err = sys->sprint("webfs: header: %r");
			return;
		}
	if(method != "GET" && method != "") {
		if(sys->fprint(ctl, "method %s", method) < 0) {
			f.err = sys->sprint("webfs: method %s: %r", method);
			return;
		}
		if(body != nil) {
			pfd := sys->open(dir + "/postbody", Sys->OWRITE);
			if(pfd == nil || sys->write(pfd, body, len body) != len body) {
				f.err = sys->sprint("webfs postbody: %r");
				return;
			}
		}
	}
	bfd := sys->open(dir + "/body", Sys->OREAD);
	if(bfd != nil)
		f.body = readfd(bfd);
	status := readline(dir + "/status");
	if(len status > 6 && status[0:6] == "error:") {
		f.err = trimsp(status[6:]);
		return;
	}
	# "200 HTTP/1.1 200 OK"
	(nil, sl) := sys->tokenize(status, " ");
	if(sl != nil) {
		f.status = int hd sl;
		if(tl sl != nil && tl tl sl != nil) {
			st := "";
			for(l := tl tl tl sl; l != nil; l = tl l) {
				if(st != "")
					st += " ";
				st += hd l;
			}
			f.statustext = st;
		}
	}
	if((u := readline(dir + "/url")) != "")
		f.url = u;
	f.ctype = readline(dir + "/contenttype");
	hfd := sys->open(dir + "/header", Sys->OREAD);
	if(hfd != nil)
		f.header = string readfd(hfd);
}

readline(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	return trimsp(string readfd(fd));
}

trimsp(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\n' || s[j-1] == '\r' || s[j-1] == '\t'))
		j--;
	return s[i:j];
}
