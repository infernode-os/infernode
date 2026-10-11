#
# jsidom.b - a web page's realm (Js->page): the natives the DOM is
# built on, the event loop, fetching, and the realm's confinement.
# Included by jsi.b.  The rules are appl/lib/js/jsdom.b's: the DOM's
# interfaces are JavaScript, in /lib/js/dom.js, over the natives here,
# which name nodes by their index in the host's Dom->Doc.  The prelude
# is a function given the natives; it returns the hooks the loop calls:
#
#	start()			run the document's scripts, then its load events
#	timer(id)		a timer set with N.timer has fired
#	fetched(id, status, statustext, url, header, body, err)
#	event(kind, node, x, y, key)	from the host; true if the default was prevented
#	resolve(base, ref)	a URL resolved, for module specifiers
#

pgh: ref Js->Host;
pgd: ref Dom->Doc;
pghooks: ref Obj;	# the prelude's hooks object
pgt0 := 0;		# when the page started, for performance.now()
# where a page's time went (/env/jstime): the preludes, its scripts
# (parsed, compiled, run), every task, and when the last one ended
jstime := 0;
tprelude, nscripts, scriptchars, tparse, tcompile, trun, tbusy, ntasks, tlastbusy, treported, nselect, tselect, nbox, tbox, ncomputed, tcomputed: int;
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
Intlsrc: con "/lib/js/intl.js";

# the natives' ids (Ndombase + iota)
NDkind, NDname, NDns, NDparent, NDfirst, NDlast, NDnext, NDprev, NDattr, NDsetattr, NDdelattr,
NDattrs, NDdata, NDsetdata, NDtextof, NDcreate, NDinsert, NDremove, NDchildren, NDdescendants,
NDmatch, NDattachshadow, NDadopt, NDshadowroots, NDselect, NDparsehtml, NDmarkup, NDbox, NDcomputed,
NDmedia, NDviewport, NDpagenow, NDtimer, NDfetch, NDfetchsync, NDnavigate, NDscroll, NDlog, NDeval,
NDevalmodule, NDrandom, NDgen, NDstoreload, NDjar, NDjaradd, NDstoresave, NDdrain: con Ndombase + iota;

# run the page's realm until it closes, then free it: a realm left to
# the collector waits for the emulator to be idle
page(h: ref Js->Host): string
{
	err: string;
	{
		err = page1(h);
	} exception e {
	"*" =>
		shutdown();
		raise e;
	}
	shutdown();
	return err;
}

page1(h: ref Js->Host): string
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
	# the clock and the time zone, which are /dev/time and /locale
	now();
	daytime->local(daytime->now());
	kr();
	if(originfs == nil)
		originfs = load Originfs Originfs->PATH;
	if(originfs == nil)
		return sys->sprint("cannot load %s: %r", Originfs->PATH);
	(jt, nil) := sys->stat("/env/jstime");
	jstime = jt >= 0;
	nlazy = tlazy = 0;
	tprelude = nscripts = scriptchars = tparse = tcompile = trun = tbusy = ntasks = tlastbusy = treported = nselect = tselect = nbox = tbox = ncomputed = tcomputed = 0;
	jsparse->parse("/(?:)/u; class C { #x; m() { return this.#x; } }", 0, 0);	# its checker and the regular expressions
	(src, rerr) := readsrc(Prelude);
	if(rerr != nil)
		return rerr;
	(isrc, ierr) := readsrc(Intlsrc);
	if(ierr != nil)
		return ierr;
	pgh = h;
	pgd = h.doc;
	pgt0 = sys->millisec();
	pgpending = nil;
	timerc = chan of int;
	fetchc = chan of ref Fetched;
	setloader(pageloader);
	prefetcher = pagemodprefetch;
	modfetches = nil;
	modlk = chan[1] of int;
	setoutput(pageconsole);
	if((err = confine(h.grants, originfs->origin(h.url))) != nil)
		return err;
	h.lock(h.id);
	tp0 := sys->millisec();
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		call1(pagescript(isrc, Intlsrc), undef, nil);
		f := pagescript(src, Prelude);
		hk := call1(f, undef, array[] of {objv(domnatives())});
		if(hk.t != Tobj)
			throwtype("the DOM prelude returned no hooks");
		pghooks = hk.o;
	} exception {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		h.unlock(h.id);
		return "the DOM prelude: " + showexc(thrown);
	}
	tprelude = sys->millisec() - tp0;
	h.unlock(h.id);
	hook("start", nil);
	for(;;) alt {
	e := <-h.events =>
		pick ev := e {
		Quit =>
			if(jstime)
				pageconsole(timereport());
			return nil;
		Click =>
			ev.reply <-= hook("event", array[] of {strv("click"), intv(ev.node), intv(ev.x), intv(ev.y), undef});
		Input =>
			ev.reply <-= hook("event", array[] of {strv("input"), intv(ev.node), undef, undef, undef});
		Submit =>
			ev.reply <-= hook("event", array[] of {strv("submit"), intv(ev.form), intv(ev.submitter), undef, undef});
		Key =>
			ev.reply <-= hook("event", array[] of {strv("key"), intv(ev.node), undef, undef, intv(ev.key)});
		Resize =>
			hook("event", array[] of {strv("resize"), undef, undef, undef, undef});
		Scroll =>
			hook("event", array[] of {strv("scroll"), undef, undef, undef, undef});
		}
	id := <-timerc =>
		hook("timer", array[] of {intv(id)});
	f := <-fetchc =>
		body := undef;
		if(f.body != nil)
			body = strv(jslex->utf16(f.body));
		hook("fetched", array[] of {intv(f.id), intv(f.status), strv(f.statustext),
			strv(f.url), strv(f.header), body, strnil(f.err)});
	}
}

# a prelude: a script whose completion value is a function
pagescript(src, name: string): V
{
	cururl = name;
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		throwerr(ESyntax, name + ":" + err);
	(pos, msg) := jscheck->check(prog);
	if(msg != nil)
		throwerr(ESyntax, sys->sprint("%s:%d: %s", name, pos, msg));
	pick p := prog {
	Program =>
		(c, cerr) := compilescript(p, src, 0, nil, 0);
		if(cerr != nil)
			throwerr(ESyntax, name + ": " + cerr);
		return rununit(c, globalthis, nil);
	}
	return undef;
}

timereport(): string
{
	return sys->sprint("time: prelude %d ms; %d scripts, %d characters: parse %d ms, compile %d ms, run %d ms; lazy compiles %d, %d ms; querySelector %d, %d ms; boxes %d, %d ms; computed styles %d, %d ms; %d tasks, busy %d ms, last ended at %d ms",
		tprelude, nscripts, scriptchars, tparse, tcompile, trun, nlazy, tlazy, nselect, tselect, nbox, tbox, ncomputed, tcomputed, ntasks, tbusy, tlastbusy);
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
	t0 := sys->millisec();
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		f := getv(pghooks, intern(name));
		if(f.t == Tobj)
			r = tobool(call1(f, objv(pghooks), args));
		jerr := runjobs();
		if(jerr != nil)
			pageconsole(jerr);
		gcpoint();
	} exception e {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		pageconsole("uncaught " + showexc(thrown));
	"JSgenret" or "JSopt" or "JSkill" or "JSnoclose" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		pageconsole("internal error: stray " + e);
	"*" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		pageconsole("internal error: " + e);
	}
	ntasks++;
	tbusy += sys->millisec() - t0;
	tlastbusy = sys->millisec() - pgt0;
	h.unlock(h.id);
	if(jstime && tlastbusy - treported >= 2000) {
		# (as it goes: the last said is where the time went, though
		# the page be closed in the middle of a task)
		treported = tlastbusy;
		pageconsole(timereport());
	}
	for(l := revpending(pgpending); l != nil; l = tl l)
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

revpending(l: list of ref Pending): list of ref Pending
{
	r: list of ref Pending;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

pageconsole(s: string)
{
	if(pgh != nil && pgh.console != nil)
		pgh.console(pgh.id, s);
}

# ---- confinement (§6.1) ----
#
# A new process group and namespace holding only the grants, bound into
# an empty tree (/tmp/.js/<pid>, which the host removes when the page is
# gone) that then replaces the root; no file descriptors but standard
# error; no devices.  webfs is not granted as it is: the realm gets an
# origin filter in front of it (originfs.b, §6.2), in its process group,
# so it ends with the page.

confine(grants: list of (string, string, int), origin: string): string
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
		if(dst == Webfs) {
			p := array[2] of ref Sys->FD;
			if(sys->pipe(p) < 0)
				return sys->sprint("confine: pipe: %r");
			ready := chan of string;
			spawn originfs->serve(p[1], origin, src, ready);
			if((e := <-ready) != nil)
				return "confine: " + e;
			p[1] = nil;
			if(sys->mount(p[0], nil, shadow + dst, Sys->MREPL, nil) < 0)
				return sys->sprint("confine: mount the origin filter: %r");
			continue;
		}
		flag := Sys->MREPL;
		if(!rw)
			flag |= Sys->MREADONLY;
		else
			flag |= Sys->MCREATE;
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

# all of a file (the buffer doubles: a script of megabytes is read in
# linear time, not copied again at every block)
readfd(fd: ref Sys->FD): array of byte
{
	buf := array[65536] of byte;
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

# Dis strings hold 16-bit characters, so the engine's UTF-16 strings
# and the document's are the same thing.  Only bytes for the network
# need converting: UTF-16 as UTF-8 (a lone surrogate as U+FFFD)
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

# ---- the natives ----

domnatives(): ref Obj
{
	o := plainobj();
	defmethod(o, "kind", NDkind, 1);
	defmethod(o, "name", NDname, 1);
	defmethod(o, "ns", NDns, 1);
	defmethod(o, "parent", NDparent, 1);
	defmethod(o, "first", NDfirst, 1);
	defmethod(o, "last", NDlast, 1);
	defmethod(o, "next", NDnext, 1);
	defmethod(o, "prev", NDprev, 1);
	defmethod(o, "attr", NDattr, 2);
	defmethod(o, "setattr", NDsetattr, 3);
	defmethod(o, "delattr", NDdelattr, 2);
	defmethod(o, "attrs", NDattrs, 1);
	defmethod(o, "data", NDdata, 1);
	defmethod(o, "setdata", NDsetdata, 2);
	defmethod(o, "textof", NDtextof, 1);
	defmethod(o, "create", NDcreate, 3);
	defmethod(o, "insert", NDinsert, 3);
	defmethod(o, "remove", NDremove, 1);
	defmethod(o, "children", NDchildren, 2);
	defmethod(o, "descendants", NDdescendants, 3);
	defmethod(o, "match", NDmatch, 3);
	defmethod(o, "attachshadow", NDattachshadow, 2);
	defmethod(o, "adopt", NDadopt, 2);
	defmethod(o, "shadowroots", NDshadowroots, 0);
	defmethod(o, "select", NDselect, 3);
	defmethod(o, "parse", NDparsehtml, 2);
	defmethod(o, "markup", NDmarkup, 2);
	defmethod(o, "box", NDbox, 1);
	defmethod(o, "computed", NDcomputed, 2);
	defmethod(o, "media", NDmedia, 1);
	defmethod(o, "viewport", NDviewport, 0);
	defmethod(o, "now", NDpagenow, 0);
	defmethod(o, "timer", NDtimer, 2);
	defmethod(o, "fetch", NDfetch, 5);
	defmethod(o, "fetchsync", NDfetchsync, 1);
	defmethod(o, "navigate", NDnavigate, 2);
	defmethod(o, "scroll", NDscroll, 2);
	defmethod(o, "log", NDlog, 1);
	defmethod(o, "eval", NDeval, 2);
	defmethod(o, "evalmodule", NDevalmodule, 2);
	defmethod(o, "random", NDrandom, 1);
	defmethod(o, "gen", NDgen, 0);
	defmethod(o, "storeload", NDstoreload, 1);
	defmethod(o, "jar", NDjar, 0);
	defmethod(o, "jaradd", NDjaradd, 1);
	defmethod(o, "storesave", NDstoresave, 2);
	defmethod(o, "drain", NDdrain, 0);
	defval(o, "url", strv(pgh.url), Awrite|Aenum|Aconf);
	return o;
}

nodearg(args: array of V, i: int): int
{
	v := arg(args, i);
	if(!isnum(v))
		throwtype("not a node");
	x := int numof(v);
	if(x < 1 || x >= pgd.n)
		throwtype("not a node");
	return x;
}

# a node or 0
nodearg0(args: array of V, i: int): int
{
	v := arg(args, i);
	if(!isnum(v) || int numof(v) == 0)
		return 0;
	return nodearg(args, i);
}

sarg(args: array of V, i: int): string
{
	return tostr(arg(args, i));
}

intarr(a: array of int): V
{
	v := array[len a] of V;
	for(i := 0; i < len a; i++)
		v[i] = intv(a[i]);
	return objv(mkarray(v));
}

natdom(id: int, args: array of V): V
{
	case id {
	NDkind =>
		return intv(pgd.nodes[nodearg(args, 0)].kind);
	NDname =>
		return strv(pgd.nodes[nodearg(args, 0)].name);
	NDns =>
		return intv(pgd.nodes[nodearg(args, 0)].ns);
	NDparent =>
		return intv(pgd.nodes[nodearg(args, 0)].parent);
	NDfirst =>
		return intv(pgd.nodes[nodearg(args, 0)].first);
	NDlast =>
		return intv(pgd.nodes[nodearg(args, 0)].last);
	NDnext =>
		return intv(pgd.nodes[nodearg(args, 0)].next);
	NDprev =>
		return intv(pgd.nodes[nodearg(args, 0)].prev);
	NDattr =>
		x := nodearg(args, 0);
		name := sarg(args, 1);
		for(l := pgd.nodes[x].attrs; l != nil; l = tl l)
			if((hd l).t0 == name)
				return strv((hd l).t1);
		return nullv;
	NDsetattr =>
		x := nodearg(args, 0);
		pgd.setattr(x, sarg(args, 1), sarg(args, 2));
		return undef;
	NDdelattr =>
		x := nodearg(args, 0);
		pgd.delattr(x, sarg(args, 1));
		return undef;
	NDattrs =>
		# [name, value, name, value, ...]
		x := nodearg(args, 0);
		l := pgd.nodes[x].attrs;
		r := array[2 * len l] of V;
		for(i := 0; l != nil; l = tl l) {
			r[i++] = strv((hd l).t0);
			r[i++] = strv((hd l).t1);
		}
		return objv(mkarray(r));
	NDdata =>
		return strv(pgd.nodes[nodearg(args, 0)].text);
	NDsetdata =>
		x := nodearg(args, 0);
		pgd.settext(x, sarg(args, 1));
		return undef;
	NDtextof =>
		return strv(pgd.textof(nodearg(args, 0)));
	NDcreate =>
		kind := toint32(arg(args, 0));
		if(kind < Dom->Document || kind > Dom->Comment)
			throwtype("no such kind of node");
		ns := toint32(arg(args, 2));
		x := pgd.create(kind, sarg(args, 1), ns);
		if(kind == Dom->Document)
			pgd.nodes[x].name = "#document-fragment";
		return intv(x);
	NDinsert =>
		p := nodearg(args, 0);
		c := nodearg(args, 1);
		b := nodearg0(args, 2);
		pgd.insert(p, c, b);
		return undef;
	NDremove =>
		pgd.remove(nodearg(args, 0));
		return undef;
	NDchildren =>
		return dnchildren(args);
	NDdescendants =>
		return dndescendants(args);
	NDmatch =>
		x := nodearg(args, 0);
		scope := 0;
		if(isnum(sv := arg(args, 2)))
			scope = int numof(sv);
		return intv(pgh.match(pgh.id, x, sarg(args, 1), scope));
	NDattachshadow =>
		# the host's shadow root is a fragment root: style and layout use the flat tree
		host := nodearg(args, 0);
		root := nodearg(args, 1);
		if(pgd.nodes[host].kind != Dom->Element || pgd.nodes[root].kind != Dom->Document)
			throwtype("not a host and a shadow root");
		pgd.attachshadow(host, root);
		return undef;
	NDadopt =>
		# the text of the style sheets root (a shadow root, or the document) has adopted
		root := nodearg(args, 0);
		l := arg(args, 1);
		if(l.t != Tobj)
			throwtype("not an array");
		k := int lengthof(l.o);
		t := array[k] of string;
		for(i := 0; i < k; i++)
			t[i] = tostr(gidx(l.o, real i, l));
		pgd.adopt(root, t);
		return undef;
	NDshadowroots =>
		return dnshadowroots();
	NDselect =>
		return dnselect(args);
	NDparsehtml =>
		return dnparse(args);
	NDmarkup =>
		# node x as HTML (§13.3): itself and what it holds, or only what it holds
		x := nodearg(args, 0);
		outer := tobool(arg(args, 1));
		parts: list of string;
		if(outer)
			parts = markup(x, parts);
		else
			for(c := pgd.nodes[x].first; c != 0; c = pgd.nodes[c].next)
				parts = markup(c, parts);
		return strv(joinrev(parts));
	NDbox =>
		# [shown, x, y, width, height]
		x := nodearg(args, 0);
		bt0 := sys->millisec();
		(shown, bx, by, bw, bh) := pgh.box(pgh.id, x);
		nbox++;
		tbox += sys->millisec() - bt0;
		return intarr(array[] of {shown, bx, by, bw, bh});
	NDcomputed =>
		x := nodearg(args, 0);
		ct0 := sys->millisec();
		cv := pgh.computed(pgh.id, x, sarg(args, 1));
		ncomputed++;
		tcomputed += sys->millisec() - ct0;
		return strv(cv);
	NDmedia =>
		return boolv(pgh.media(pgh.id, sarg(args, 0)) > 0);
	NDviewport =>
		(w, h, sx, sy) := pgh.viewport(pgh.id);
		return intarr(array[] of {w, h, sx, sy});
	NDpagenow =>
		return intv(sys->millisec() - pgt0);
	NDtimer =>
		id := toint32(arg(args, 0));
		ms := toint32(arg(args, 1));
		if(ms < 0)
			ms = 0;
		spawn sleeper(timerc, id, ms);
		return undef;
	NDfetch =>
		# fetch(id, method, url, header lines, body): the result comes to the fetched hook
		id := toint32(arg(args, 0));
		method := sarg(args, 1);
		url := sarg(args, 2);
		hdr := sarg(args, 3);
		body: array of byte;
		if(isstr(arg(args, 4)))
			body = utf8bytes(sarg(args, 4));
		spawn fetcher(fetchc, id, method, url, hdr, body);
		return undef;
	NDfetchsync =>
		# fetchsync(url): [status, content type, body, url] or [0, error]
		f := webget(0, "GET", sarg(args, 0), nil, nil);
		if(f.err != nil)
			return objv(mkarray(array[] of {intv(0), strv(f.err)}));
		return objv(mkarray(array[] of {intv(f.status), strv(f.ctype),
			strv(jslex->utf16(f.body)), strv(f.url)}));
	NDnavigate =>
		pgpending = ref Pending.Navigate(sarg(args, 0), tobool(arg(args, 1))) :: pgpending;
		return undef;
	NDscroll =>
		pgpending = ref Pending.Scroll(toint32(arg(args, 0)), toint32(arg(args, 1))) :: pgpending;
		return undef;
	NDlog =>
		pageconsole(sarg(args, 0));
		return undef;
	NDeval =>
		return dneval(args);
	NDevalmodule =>
		return dnevalmodule(args);
	NDrandom =>
		k := toint32(arg(args, 0));
		if(k < 0 || k > 65536)
			throwerr(ERange, "too many random bytes");
		v := array[k] of V;
		if(k > 0) {
			r := IPint.random(8*k, 8*k).iptobytes();
			for(i := 0; i < k; i++) {
				b := 0;
				if(i < len r)
					b = int r[i];
				v[i] = intv(b);
			}
		}
		return objv(mkarray(v));
	NDgen =>
		return intv(pgd.gen);
	NDstoreload =>
		(ok, nil) := sys->stat(Store);
		if(ok < 0)
			return nullv;
		fd := sys->open(storefile(sarg(args, 0)), Sys->OREAD);
		if(fd == nil)
			return strv("");
		return strv(jslex->utf16(readfd(fd)));
	NDjar =>
		# webfs's cookie jar, for document.cookie: its lines, or null if there
		# is no webfs (the page's own cookies are chosen from them by the prelude)
		fd := sys->open(Webfs + "/cookies", Sys->OREAD);
		if(fd == nil)
			return nullv;
		return strv(jslex->utf16(readfd(fd)));
	NDjaradd =>
		line := sarg(args, 0);
		for(i := 0; i < len line; i++)
			if(line[i] == '\n')
				return falsev;
		fd := sys->open(Webfs + "/cookies", Sys->OWRITE);
		if(fd == nil)
			return falsev;
		b := utf8bytes(line);
		return boolv(sys->write(fd, b, len b) == len b);
	NDstoresave =>
		return dnstoresave(args);
	NDdrain =>
		# run the jobs waiting (promise reactions), as after each script
		jerr := runjobs();
		if(jerr != nil)
			pageconsole(jerr);
		return undef;
	}
	throwerr(EError, "unknown page built-in");
	return undef;
}

# the children of x, all or only its elements
dnchildren(args: array of V): V
{
	x := nodearg(args, 0);
	elems := tobool(arg(args, 1));
	k := 0;
	for(c := pgd.nodes[x].first; c != 0; c = pgd.nodes[c].next)
		if(!elems || pgd.nodes[c].kind == Dom->Element)
			k++;
	r := array[k] of V;
	k = 0;
	for(c = pgd.nodes[x].first; c != 0; c = pgd.nodes[c].next)
		if(!elems || pgd.nodes[c].kind == Dom->Element)
			r[k++] = intv(c);
	return objv(mkarray(r));
}

# the elements under x in document order: those with a name ("*": all),
# or (by "class") those having every one of a set of classes, or (by
# "id") the first with an id
dndescendants(args: array of V): V
{
	x := nodearg(args, 0);
	how := sarg(args, 1);
	what := sarg(args, 2);
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
			return intv(m);
		"nameattr" =>
			if(pgd.attr(m, "name") != what)
				continue;
		}
		r = m :: r;
		k++;
	}
	if(how == "id")
		return intv(0);
	v := array[k] of V;
	for(; r != nil; r = tl r)
		v[--k] = intv(hd r);
	return objv(mkarray(v));
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

# the document's shadow roots as the page came (declarative ones):
# [host, root, mode, ...]
dnshadowroots(): V
{
	r: list of V;
	k := 0;
	for(l := pgd.shadows; l != nil; l = tl l) {
		(h, s) := hd l;
		r = strv(pgd.attr(s, "mode")) :: intv(s) :: intv(h) :: r;
		k += 3;
	}
	v := array[k] of V;
	for(i := 0; r != nil; r = tl r)
		v[i++] = hd r;
	# (r was built backwards in threes: put each three in order)
	for(i = 0; i + 2 < k; i += 3)
		(v[i], v[i+2]) = (v[i+2], v[i]);
	return objv(mkarray(v));
}

# all: an array of nodes; else the first, or 0; null if not a valid selector
dnselect(args: array of V): V
{
	x := nodearg(args, 0);
	all := tobool(arg(args, 2));
	st0 := sys->millisec();
	(ok, l) := pgh.select(pgh.id, x, sarg(args, 1), all);
	nselect++;
	tselect += sys->millisec() - st0;
	if(ok < 0)
		return nullv;
	if(!all) {
		if(l == nil)
			return intv(0);
		return intv(hd l);
	}
	r := array[len l] of V;
	for(i := 0; l != nil; l = tl l)
		r[i++] = intv(hd l);
	return objv(mkarray(r));
}

# markup parsed into new nodes of the document, not in the tree: the
# nodes of a body's content; whole, a document's [html, head, body],
# the html element without its children
dnparse(args: array of V): V
{
	s := sarg(args, 0);
	whole := tobool(arg(args, 1));
	src := pgh.parse(pgh.id, s, whole);
	if(src == nil)
		return objv(mkarray(array[0] of V));
	if(whole) {
		v := array[3] of {* => intv(0)};
		if((h := src.find(1, Dom->Thtml)) != 0) {
			y := pgd.create(src.nodes[h].kind, src.nodes[h].name, src.nodes[h].ns);
			pgd.nodes[y].attrs = src.nodes[h].attrs;
			v[0] = intv(y);
		}
		if((hn := src.find(1, Dom->Thead)) != 0)
			v[1] = intv(copynode(src, hn));
		if((b := src.find(1, Dom->Tbody)) != 0)
			v[2] = intv(copynode(src, b));
		return objv(mkarray(v));
	}
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
		v[--k] = intv(hd r);
	return objv(mkarray(v));
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

sleeper(c: chan of int, id, ms: int)
{
	sys->sleep(ms);
	c <-= id;
}

# the origin's storage, granted at /mnt/store if this origin has any:
# a file's text, or null if there is no store
Store: con "/mnt/store";
Storemax: con 5*1024*1024;	# a browser's usual localStorage quota

storefile(name: string): string
{
	for(i := 0; i < len name; i++)
		if(!(name[i] >= 'a' && name[i] <= 'z'))
			throwtype("bad store name");
	return Store + "/" + name;
}

dnstoresave(args: array of V): V
{
	(ok, nil) := sys->stat(Store);
	if(ok < 0)
		return falsev;
	f := storefile(sarg(args, 0));
	b := utf8bytes(sarg(args, 1));
	if(len b > Storemax)
		throwerr(ERange, "QuotaExceededError: the origin's storage is full");
	tmp := f + ".new";
	fd := sys->create(tmp, Sys->OWRITE, 8r600);
	if(fd == nil || sys->write(fd, b, len b) != len b)
		return falsev;
	fd = nil;
	sys->remove(f);
	d := sys->nulldir;
	d.name = f[len Store + 1:];
	if(sys->wstat(tmp, d) < 0)
		return falsev;
	return truev;
}

# [0, completion value] or [1, what was thrown]
dneval(args: array of V): V
{
	src := sarg(args, 0);
	name := sarg(args, 1);
	t0 := sys->millisec();
	(prog, err) := jsparse->parse(src, 0, 0);
	t1 := sys->millisec();
	if(err != nil)
		return objv(mkarray(array[] of {intv(1), objv(mkerror(ESyntax, name + ":" + err + near(src, err)))}));
	(pos, msg) := jscheck->check(prog);
	if(msg != nil)
		return objv(mkarray(array[] of {intv(1), objv(mkerror(ESyntax, sys->sprint("%s:%d: %s", name, pos, msg)))}));
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		pick p := prog {
		Program =>
			cururl = name;
			(c, cerr) := compilescript(p, src, 0, nil, 0);
			if(cerr != nil)
				return objv(mkarray(array[] of {intv(1), objv(mkerror(ESyntax, name + ": " + cerr))}));
			t2 := sys->millisec();
			v := rununit(c, globalthis, nil);
			t3 := sys->millisec();
			nscripts++;
			scriptchars += len src;
			tparse += t1 - t0;
			tcompile += t2 - t1;
			trun += t3 - t2;
			slow(name, len src, t0, t1, t2);
			return objv(mkarray(array[] of {intv(0), v}));
		}
	} exception {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		return objv(mkarray(array[] of {intv(1), thrown}));
	}
	return undef;
}

Slowms: con 1000;

# a script that took long, said so with where the time went
slow(name: string, size, t0, t1, t2: int)
{
	t3 := sys->millisec();
	if(t3 - t0 >= Slowms)
		pageconsole(sys->sprint("slow script %s (%d characters): parse %d ms, compile %d ms, run %d ms",
			name, size, t1 - t0, t2 - t1, t3 - t2));
}

# the text around a parse error's "line:col: ..."
near(src, err: string): string
{
	(n, l) := sys->tokenize(err, ":");
	if(n < 2)
		return "";
	line := int hd l;
	col := int hd tl l;
	p := 0;
	for(i := 1; i < line && p < len src; p++)
		if(src[p] == '\n')
			i++;
	p += col - 1;
	if(p < 0 || p > len src)
		return "";
	a := p - 40;
	if(a < 0)
		a = 0;
	b := p + 40;
	if(b > len src)
		b = len src;
	t := src[a:b];
	for(i = 0; i < len t; i++)
		if(t[i] == '\n' || t[i] == '\t')
			t[i] = ' ';
	return " near «" + t + "»";
}

dnevalmodule(args: array of V): V
{
	src := sarg(args, 0);
	url := sarg(args, 1);
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		runmodule(src, url);
		return objv(mkarray(array[] of {intv(0), undef}));
	} exception {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		return objv(mkarray(array[] of {intv(1), thrown}));
	}
	return undef;
}

# ---- modules ----
#
# A module's imports are fetched all at once, as a browser fetches a
# module graph: when a module is parsed (pagemodprefetch, through its
# resolve hook), and before that, when its source comes, by a scan of it
# for static imports with relative or absolute URLs (in the fetching
# thread).  The loader takes each from here, so the graph comes in about
# the time of its deepest path, not the sum of its fetches.
Modfetch: adt {
	done:	chan of int;
	f:	ref Fetched;
	got:	int;
};
modfetches: list of (string, ref Modfetch);
modlk: chan of int;

modfetchof(url: string): ref Modfetch
{
	modlk <-= 1;
	for(l := modfetches; l != nil; l = tl l)
		if((hd l).t0 == url) {
			<-modlk;
			return (hd l).t1;
		}
	<-modlk;
	return nil;
}

# start fetching url unless it is already
modstart(url: string)
{
	modlk <-= 1;
	for(l := modfetches; l != nil; l = tl l)
		if((hd l).t0 == url) {
			<-modlk;
			return;
		}
	mf := ref Modfetch(chan[1] of int, nil, 0);
	modfetches = (url, mf) :: modfetches;
	<-modlk;
	spawn modfetcher(mf, url);
}

pagemodprefetch(referrer: string, specs: list of string)
{
	for(; specs != nil; specs = tl specs) {
		(url, err) := modresolve(referrer, hd specs);
		if(err == nil)
			modstart(url);
	}
}

modfetcher(mf: ref Modfetch, url: string)
{
	{
		mf.f = webget(0, "GET", url, nil, nil);
		if(mf.f.err == nil && mf.f.status >= 200 && mf.f.status < 300)
			for(l := staticimports(string mf.f.body); l != nil; l = tl l)
				if((u := urljoin(mf.f.url, hd l)) != nil)
					modstart(u);
	} exception e {
	"*" =>
		mf.f = ref Fetched(0, 0, "", url, "", "", nil, e);
	}
	mf.done <-= 1;
}

# the specifiers a module's static imports name by URL (from "x",
# import "x"): a scan of the text, which may find one in a string or a
# comment too, costing no more than a fetch never used
staticimports(s: string): list of string
{
	l: list of string;
	n := len s;
	for(i := 0; i + 6 < n; i++) {
		k := 0;
		if(s[i] == 'f' && s[i:i+4] == "from")
			k = 4;
		else if(s[i] == 'i' && s[i:i+6] == "import")
			k = 6;
		else
			continue;
		if(i > 0 && isidchar(s[i-1]))
			continue;
		j := i + k;
		while(j < n && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r'))
			j++;
		if(j >= n || s[j] != '"' && s[j] != '\'')
			continue;
		q := s[j];
		e := j + 1;
		while(e < n && s[e] != q && s[e] != '\n' && e - j < 1024)
			e++;
		if(e >= n || s[e] != q)
			continue;
		spec := s[j+1:e];
		if(len spec > 0 && (spec[0] == '.' || spec[0] == '/' || len spec > 7 && (spec[0:7] == "http://" || spec[0:8] == "https://")))
			l = spec :: l;
		i = e;
	}
	return l;
}

isidchar(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '$' || c >= 16r80;
}

# rel against base, for an http(s) base: absolute, scheme-relative,
# root-relative and path-relative references (with . and ..); nil if
# it is none of them
urljoin(base, rel: string): string
{
	if(len rel > 7 && rel[0:7] == "http://" || len rel > 8 && rel[0:8] == "https://")
		return rel;
	(scheme, rest) := urlscheme(base);
	if(scheme != "http" && scheme != "https" || len rest < 2 || rest[0:2] != "//")
		return nil;
	# authority, path
	e := 2;
	while(e < len rest && rest[e] != '/' && rest[e] != '?' && rest[e] != '#')
		e++;
	auth := rest[2:e];
	path := rest[e:];
	for(k := 0; k < len path; k++)
		if(path[k] == '?' || path[k] == '#') {
			path = path[0:k];
			break;
		}
	if(len rel > 1 && rel[0:2] == "//")
		return scheme + ":" + rel;
	np: string;
	if(len rel > 0 && rel[0] == '/')
		np = rel;
	else {
		d := len path;
		while(d > 0 && path[d-1] != '/')
			d--;
		np = path[0:d] + rel;
		if(np == "" || np[0] != '/')
			np = "/" + np;
	}
	# remove . and .. segments
	(nil, segs) := sys->tokenize(np, "/");
	out: list of string;
	for(; segs != nil; segs = tl segs)
		case hd segs {
		"." =>
			;
		".." =>
			if(out != nil)
				out = tl out;
		* =>
			out = hd segs :: out;
		}
	r := "";
	for(; out != nil; out = tl out)
		r = "/" + hd out + r;
	if(r == "" || np[len np - 1] == '/')
		r += "/";
	return scheme + "://" + auth + r;
}

# a module specifier, as the page's resolve hook has it
modresolve(referrer, spec: string): (string, string)
{
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		f := getv(pghooks, intern("resolve"));
		u := call1(f, objv(pghooks), array[] of {strv(referrer), strv(spec)});
		if(!isstr(u))
			return (nil, "cannot resolve module " + spec);
		return (flat(u), nil);
	} exception {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		return (nil, "cannot resolve module " + spec + ": " + showexc(thrown));
	}
}

pageloader(referrer, spec: string): (string, string, string)
{
	(url, rerr) := modresolve(referrer, spec);
	if(rerr != nil)
		return (nil, nil, rerr);
	f: ref Fetched;
	if((mf := modfetchof(url)) != nil) {
		if(!mf.got) {
			<-mf.done;
			mf.got = 1;
		}
		f = mf.f;
	} else
		f = webget(0, "GET", url, nil, nil);
	if(f.err != nil)
		return (nil, nil, "cannot load module " + spec + ": " + f.err);
	if(f.status != 200 && f.status != 0)
		return (nil, nil, sys->sprint("cannot load module %s: %d %s", spec, f.status, f.statustext));
	return (f.url, jslex->utf16(f.body), nil);
}

# ---- fetching ----

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
		if(b[i] == byte '%' && i + 2 < len b && hexval(int b[i+1]) >= 0 && hexval(int b[i+2]) >= 0) {
			r[k++] = byte (hexval(int b[i+1]) * 16 + hexval(int b[i+2]));
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
	# the header lines, and "cookies off" for a request that must not carry
	# the jar's (a script's cross-origin request without credentials)
	# and the request's mode and credentials, for the origin filter
	(nil, hl) := sys->tokenize(hdr, "\n");
	for(; hl != nil; hl = tl hl)
		if(hd hl == "cookies off" || len hd hl > 5 && (hd hl)[0:5] == "mode " ||
		   len hd hl > 12 && (hd hl)[0:12] == "credentials ") {
			if(sys->fprint(ctl, "%s", hd hl) < 0) {
				f.err = sys->sprint("webfs: %s: %r", hd hl);
				return;
			}
		} else if(sys->fprint(ctl, "header %s", hd hl) < 0) {
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
