implement Browser;

#
# browser.b - a browsing session (see browser.m).
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Point: import draw;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/css.m";
include "web/style.m";
	style: Style;
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
	layout: Layout;
	Box, Line, Frag: import layout;
include "web/page.m";
	page: Page;
	Pg: import page;
include "web/browser.m";

# how a navigation changes history
Hnew, Hback, Hforward, Hreload, Hnone: con iota;

init(d: ref Draw->Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	dom = load Dom Dom->PATH;
	style = load Style Style->PATH;
	page = load Page Page->PATH;
	if(dom == nil || style == nil || page == nil)
		return sys->sprint("cannot load modules: %r");
	if((err := style->init()) != nil)
		return err;
	if((err = page->init(d)) != nil)
		return err;
	# page's own: a Layout of our own would know nothing of where page
	# put things (sticky boxes as last painted, for a click)
	layout = page->layoutmod();
	return nil;
}

Session.new(width, height: int): ref Session
{
	return ref Session(nil, "", "", "", nil, nil, width, height, 0, 0, chan[1] of int, nil);
}

lock(s: ref Session)
{
	s.lk <-= 1;
}

unlock(s: ref Session)
{
	<-s.lk;
}

event(s: ref Session, e: string)
{
	lock(s);
	l := s.listeners;
	unlock(s);
	for(; l != nil; l = tl l)
		alt {
		hd l <-= e =>
			;
		* =>
			;	# a listener that does not keep up misses events
		}
}

Session.listen(s: self ref Session): chan of string
{
	c := chan[64] of string;
	lock(s);
	s.listeners = c :: s.listeners;
	unlock(s);
	return c;
}

Session.unlisten(s: self ref Session, c: chan of string)
{
	lock(s);
	r: list of chan of string;
	for(l := s.listeners; l != nil; l = tl l)
		if(hd l != c)
			r = hd l :: r;
	s.listeners = r;
	unlock(s);
}

# ---- navigation ----

Session.open(s: self ref Session, url: string)
{
	navigate(s, typed(s, url), "GET", nil, nil, Hnew);
}

Session.show(s: self ref Session, data: array of byte, ctype, url: string): string
{
	if(ctype == nil)
		ctype = "text/html";
	pg: ref Pg;
	{
		pg = page->parse(data, ctype, url, s.width, s.height);
	} exception e {
	"*" =>
		return "internal error: " + e;
	}
	lock(s);
	s.gen++;	# whatever was loading is superseded
	if(unfrag(pg.url) != unfrag(s.url))
		history(s, s.url, Hnew);
	s.pg = pg;
	s.url = pg.url;
	s.title = pg.title;
	s.status = "done";
	unlock(s);
	event(s, "done " + s.url);
	return nil;
}

# What the user typed, as a URL.
typed(s: ref Session, u: string): string
{
	u = trim(u);
	if(u == "")
		return "about:blank";
	if(scheme(u) != nil)
		return u;
	if(u[0] == '/')
		return "file://" + u;
	if(s.url != "" && (u[0] == '#' || u[0] == '.' || u[0] == '?'))
		return resolve(s.url, u);
	return "https://" + u;
}

Session.goback(s: self ref Session): string
{
	lock(s);
	if(s.back == nil) {
		unlock(s);
		return "no previous page";
	}
	u := hd s.back;
	unlock(s);
	navigate(s, u, "GET", nil, nil, Hback);
	return nil;
}

Session.goforward(s: self ref Session): string
{
	lock(s);
	if(s.fwd == nil) {
		unlock(s);
		return "no next page";
	}
	u := hd s.fwd;
	unlock(s);
	navigate(s, u, "GET", nil, nil, Hforward);
	return nil;
}

Session.reload(s: self ref Session)
{
	if(s.url != "")
		navigate(s, s.url, "GET", nil, nil, Hreload);
}

Session.stop(s: self ref Session)
{
	lock(s);
	s.gen++;
	stopped := prefix(s.status, "loading");
	if(stopped)
		s.status = "done";
	unlock(s);
	if(stopped)
		event(s, "stopped");
}

Session.resize(s: self ref Session, width, height: int)
{
	lock(s);
	s.width = width;
	s.height = height;
	if(s.pg != nil)
		s.pg.relayout(width, height);
	unlock(s);
}

navigate(s: ref Session, url, method, ctype: string, body: array of byte, hist: int)
{
	if(url == "about:blank")
		url = "data:text/html,";
	lock(s);
	s.gen++;
	g := s.gen;
	# a link to elsewhere in this page moves the view, not the page
	if(s.pg != nil && method == "GET" && hist != Hreload &&
	   (frag := fragment(url)) != nil && unfrag(url) == unfrag(s.url)) {
		prev := s.url;
		history(s, prev, hist);
		s.url = url;
		s.scroll = target(s.pg, frag);
		s.status = "done";
		unlock(s);
		event(s, "shown " + url);
		event(s, "done " + url);
		return;
	}
	s.status = "loading " + url;
	unlock(s);
	event(s, "loading " + url);
	spawn loader(s, g, url, method, ctype, body, hist);
}

history(s: ref Session, prev: string, hist: int)
{
	case hist {
	Hnew =>
		if(prev != "")
			s.back = prev :: s.back;
		s.fwd = nil;
	Hback =>
		if(s.back != nil)
			s.back = tl s.back;
		if(prev != "")
			s.fwd = prev :: s.fwd;
	Hforward =>
		if(s.fwd != nil)
			s.fwd = tl s.fwd;
		if(prev != "")
			s.back = prev :: s.back;
	}
}

loader(s: ref Session, g: int, url, method, ctype: string, body: array of byte, hist: int)
{
	pg: ref Pg;
	err: string;
	{
		(pg, err) = page->begin(url, method, ctype, body, s.width, s.height);
	} exception e {
	"*" =>
		pg = nil;
		err = "internal error: " + e;
	}
	ep: ref Pg;
	if(pg == nil) {
		# a page saying so, where the page would have been
		{
			(ep, nil) = page->request(errorpage(url, err), "GET", nil, nil, s.width, s.height);
		} exception {
		"*" =>
			ep = nil;
		}
	}
	lock(s);
	if(g != s.gen) {
		unlock(s);
		return;	# superseded or stopped
	}
	if(pg == nil) {
		if(ep != nil) {
			history(s, s.url, hist);
			s.pg = ep;
			s.url = url;	# so that reload tries it again
			s.title = ep.title;
			s.scroll = 0;
		}
		s.status = "error " + err;
		unlock(s);
		event(s, "error " + err);
		return;
	}
	history(s, s.url, hist);
	s.pg = pg;
	s.url = pg.url;
	if((frag := fragment(url)) != nil && fragment(s.url) == nil)
		s.url += "#" + frag;
	s.title = pg.title;
	s.scroll = 0;
	if(frag != nil)
		s.scroll = target(pg, frag);
	u := s.url;
	s.status = "loading images " + u;
	unlock(s);
	event(s, "shown " + u);
	# the page is up; what it shows comes in behind it
	{
		images(s, g, pg);
		pg.frames();
	} exception e {
	"*" =>
		sys->fprint(sys->fildes(2), "charon: %s: %s\n", u, e);
	}
	lock(s);
	if(g != s.gen) {
		unlock(s);
		return;
	}
	s.status = "done";
	unlock(s);
	event(s, "done " + u);
	refresh(s, g, pg);
}

# Fetch and decode the page's images NFETCH at a time, and lay the page
# out again with those that have come, at most every BATCHMS, so that
# it fills in as they arrive.
NFETCH: con 6;
BATCHMS: con 250;

images(s: ref Session, g: int, pg: ref Pg)
{
	urls := pg.wanted();
	n := len urls;
	if(n == 0)
		return;
	work := chan[n] of string;
	for(; urls != nil; urls = tl urls)
		work <-= hd urls;
	res := chan of ref Page->Pic;
	nw := NFETCH;
	if(nw > n)
		nw = n;
	for(i := 0; i < nw; i++)
		spawn picfetcher(s, g, work, res);
	tick := chan of int;
	stop := chan[1] of int;
	spawn ticker(tick, stop);
	batch: list of ref Page->Pic;
	live := 1;
	for(got := 0; got < n; ) alt {
	pic := <-res =>
		got++;
		if(pic != nil)
			batch = pic :: batch;
	<-tick =>
		if(batch != nil && live) {
			live = apply(s, g, pg, batch, got, n);
			batch = nil;
		}
	}
	stop <-= 1;
	if(batch != nil && live)
		apply(s, g, pg, batch, n, n);
}

picsome(s: ref Session, g: int, pg: ref Pg, urls: list of string)
{
	pics: list of ref Page->Pic;
	for(; urls != nil; urls = tl urls) {
		u := hd urls;
		pic: ref Page->Pic;
		{
			(data, ctype, err) := page->fetchimage(u);
			pic = page->picture(u, data, ctype, err);
		} exception e {
		"*" =>
			pic = ref Page->Pic(u, nil, nil, "internal error: " + e, nil, 0, 0, nil, nil);
		}
		pics = pic :: pics;
	}
	apply(s, g, pg, pics, len pics, len pics);
}

Session.images(s: self ref Session)
{
	pg := s.pg;
	if(pg == nil)
		return;
	pg.wantall();
	spawn images(s, s.gen, pg);
}

setting(name: string): string
{
	return page->setting(name);
}

Session.configure(s: self ref Session, line: string): string
{
	(nil, l) := sys->tokenize(line, " \t\n");
	if(l == nil)
		return "usage: name value";
	was := page->setting(hd l);
	if((err := page->set(line)) != nil)
		return err;
	now := page->setting(hd l);
	if(now == was || s.pg == nil)
		return nil;
	case hd l {
	"images" =>
		if(now == "on")
			spawn images(s, s.gen, s.pg);
	"fonts" =>
		s.reload();
	"effects" =>
		event(s, "update 0 0");	# drawn again, as it is
	}
	return nil;
}

settings(): string
{
	return page->settings();
}

savesettings(): string
{
	return page->save();
}

apply(s: ref Session, g: int, pg: ref Pg, batch: list of ref Page->Pic, got, n: int): int
{
	lock(s);
	if(g != s.gen) {
		unlock(s);
		return 0;
	}
	pg.install(batch);
	unlock(s);
	event(s, sys->sprint("update %d %d", got, n));
	return 1;
}

picfetcher(s: ref Session, g: int, work: chan of string, res: chan of ref Page->Pic)
{
	for(;;) alt {
	u := <-work =>
		if(g != s.gen) {
			res <-= nil;	# superseded: count it, fetch nothing
			continue;
		}
		pic: ref Page->Pic;
		{
			(data, ctype, err) := page->fetchimage(u);
			pic = page->picture(u, data, ctype, err);
		} exception e {
		"*" =>
			pic = ref Page->Pic(u, nil, nil, "internal error: " + e, nil, 0, 0, nil, nil);
		}
		res <-= pic;
	* =>
		return;
	}
}

ticker(tick, stop: chan of int)
{
	for(;;) {
		sys->sleep(BATCHMS);
		alt {
		<-stop =>
			return;
		tick <-= 1 =>
			;
		}
	}
}

# <meta http-equiv=refresh content="N[; url=U]"> (HTML §4.2.5.3): go to
# U, or load this page again, after N seconds, unless something else
# has happened to the session by then.
refresh(s: ref Session, g: int, pg: ref Pg)
{
	d := pg.doc;
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Element || nd.ns != Dom->HTML || nd.tag != Dom->Tmeta)
			continue;
		if(lower(d.attr(n, "http-equiv")) != "refresh")
			continue;
		(secs, u) := refreshcontent(d.attr(n, "content"));
		if(secs < 0)
			continue;
		if(u == "")
			u = unfrag(pg.url);
		else
			u = resolve(pg.url, u);
		spawn refresher(s, g, u, secs);
		return;
	}
}

refresher(s: ref Session, g: int, url: string, secs: int)
{
	if(secs > 0)
		sys->sleep(secs * 1000);
	lock(s);
	live := s.gen == g;
	unlock(s);
	if(live)
		navigate(s, url, "GET", nil, nil, Hnew);
}

# "5; url=http://x", "0;URL='x'", "3" -> (seconds, url); seconds -1 if unreadable
refreshcontent(c: string): (int, string)
{
	i := 0;
	while(i < len c && isws(c[i]))
		i++;
	j := i;
	while(j < len c && c[j] >= '0' && c[j] <= '9')
		j++;
	if(j == i)
		return (-1, nil);
	secs := int c[i:j];
	while(j < len c && (c[j] >= '0' && c[j] <= '9' || c[j] == '.'))
		j++;	# a fraction is ignored
	while(j < len c && (isws(c[j]) || c[j] == ';' || c[j] == ','))
		j++;
	if(j >= len c)
		return (secs, "");
	u := c[j:];
	if(len u >= 4 && lower(u[0:3]) == "url") {
		k := 3;
		while(k < len u && (isws(u[k]) || u[k] == '='))
			k++;
		u = u[k:];
	}
	u = trim(u);
	if(len u >= 2 && (u[0] == '\'' || u[0] == '"') && u[len u - 1] == u[0])
		u = u[1:len u - 1];
	return (secs, trim(u));
}

isws(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

# The page shown for one that could not be fetched.
errorpage(url, err: string): string
{
	h := "<!doctype html><title>Cannot load page</title>" +
		"<body style='font-family: sans-serif; margin: 2em 3em; color: #333'>" +
		"<h1 style='font-size: 1.4em; font-weight: normal'>Cannot load this page</h1>" +
		"<p style='overflow-wrap: anywhere; color: #555'>" + htmlesc(url) + "</p>" +
		"<p style='overflow-wrap: anywhere'>" + htmlesc(err) + "</p>";
	if(contains(err, "invalid IP address") || contains(err, "cs: ") || contains(err, "/net/cs"))
		h += "<p>The host name was not translated to an address: nothing is serving /net/cs " +
			"(ndb/cs, and on a machine without a host system ndb/dns too).</p>";
	return "data:text/html;charset=utf-8," + pctenc(h);
}

htmlesc(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'<' => r += "&lt;";
		'>' => r += "&gt;";
		'&' => r += "&amp;";
		'\'' => r += "&#39;";
		'"' => r += "&quot;";
		* => r[len r] = s[i];
		}
	return r;
}

# percent-encode all but what a data: URL can carry plainly
pctenc(s: string): string
{
	b := array of byte s;
	r := "";
	for(i := 0; i < len b; i++) {
		c := int b[i];
		if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == ' ' || c == '-' || c == '.' || c == ':' || c == ';' || c == '/' || c == '=' || c == ',')
			r[len r] = c;
		else
			r += sys->sprint("%%%.2X", c);
	}
	return r;
}

# Make the element the fragment names the :target, and return its y.
target(pg: ref Pg, frag: string): int
{
	return pg.target(frag);
}

absy(b: ref Box): int
{
	y := 0;
	for(; b != nil; b = b.parent)
		y += b.y;
	return y;
}

absx(b: ref Box): int
{
	x := 0;
	for(; b != nil; b = b.parent)
		x += b.x;
	return x;
}

# ---- the page as text ----

Session.text(s: self ref Session): string
{
	pg := s.pg;
	if(pg == nil)
		return "";
	r := "";
	for(l := rev(blocktext(pg, pg.root, nil)); l != nil; l = tl l)
		r += hd l + "\n";
	return r;
}

# The text of b and its descendants, one string per block, reversed.
blocktext(pg: ref Pg, b: ref Box, acc: list of string): list of string
{
	if(b.st != nil && b.st.visibility != Style->Vvisible && b.kids == nil)
		return acc;
	if(b.kind == Layout->Krow) {
		row := "";
		for(i := 0; i < len b.kids; i++) {
			t := join(rev(blocktext(pg, b.kids[i], nil)), " ");
			if(row != "")
				row += "\t";
			row += t;
		}
		if(trim(row) != "")
			acc = row :: acc;
		return acc;
	}
	if(len b.lines > 0) {
		pre := b.st != nil && (b.st.whitespace == Style->Wpre ||
			b.st.whitespace == Style->Wprewrap || b.st.whitespace == Style->Wbreakspaces);
		t := "";
		for(i := 0; i < len b.lines; i++) {
			lt := linetext(pg, b.lines[i]);
			if(pre) {
				acc = lt :: acc;
				continue;
			}
			if(t != "" && lt != "" && t[len t - 1] != ' ' && lt[0] != ' ')
				t += " ";
			t += lt;
		}
		t = squash(t);
		if(t != "")
			acc = t :: acc;
		# floats and positioned boxes among the inline content
		for(i = 0; i < len b.kids; i++) {
			k := b.kids[i];
			if(!k.inl && k.kind != Layout->Ktext && k.kind != Layout->Kmarker)
				acc = blocktext(pg, k, acc);
		}
	} else
		for(i := 0; i < len b.kids; i++)
			acc = blocktext(pg, b.kids[i], acc);
	for(l := b.pos; l != nil; l = tl l)
		acc = blocktext(pg, hd l, acc);
	return acc;
}

linetext(pg: ref Pg, ln: ref Line): string
{
	t := "";
	end := -1;
	for(i := 0; i < len ln.frags; i++) {
		f := ln.frags[i];
		piece := "";
		case f.kind {
		Layout->Ftext =>
			piece = f.text;
		Layout->Fatomic =>
			piece = atomtext(pg, f.box);
		}
		if(piece == "")
			continue;
		if(t != "" && f.x > end + 1 && t[len t - 1] != ' ' && piece[0] != ' ')
			t += " ";
		t += piece;
		end = f.x + f.w;
	}
	return t;
}

atomtext(pg: ref Pg, b: ref Box): string
{
	if(b.kind == Layout->Kreplaced) {
		if(b.node != 0 && pg.doc.nodes[b.node].tag == Dom->Timg)
			return pg.doc.attr(b.node, "alt");
		return b.text;
	}
	return join(rev(blocktext(pg, b, nil)), " ");
}

Session.find(s: self ref Session, what: string): string
{
	if(what == "")
		return "";
	w := lower(what);
	r := "";
	(nil, l) := sys->tokenize(s.text(), "\n");
	for(; l != nil; l = tl l)
		if(contains(lower(hd l), w))
			r += hd l + "\n";
	return r;
}

# ---- links ----

Session.links(s: self ref Session): array of ref Link
{
	pg := s.pg;
	if(pg == nil)
		return nil;
	d := pg.doc;
	r: list of ref Link;
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Element || nd.ns != Dom->HTML || nd.tag != Dom->Ta && nd.tag != Dom->Tarea)
			continue;
		if(!d.hasattr(n, "href"))
			continue;
		u := resolve(d.url, d.attr(n, "href"));
		if(lower(scheme(u)) == "javascript")
			continue;
		t := squash(d.textof(n));
		if(t == "") {
			if((img := d.find(n, Dom->Timg)) != 0)
				t = d.attr(img, "alt");
			if(t == "")
				t = d.attr(n, "title");
			if(t == "")
				t = d.attr(n, "alt");
		}
		r = ref Link(n, u, squash(t)) :: r;
	}
	return toarray(r);
}

toarray(l: list of ref Link): array of ref Link
{
	a := array[len l] of ref Link;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

linkstext(a: array of ref Link): string
{
	r := "";
	for(i := 0; i < len a; i++)
		r += sys->sprint("%d %s %s\n", i+1, a[i].url, a[i].text);
	return r;
}

Session.follow(s: self ref Session, n: int): string
{
	a := s.links();
	if(n < 1 || n > len a)
		return sys->sprint("no link %d", n);
	navigate(s, a[n-1].url, "GET", nil, nil, Hnew);
	return nil;
}

# ---- forms ----

iscontrol(d: ref Doc, n: int): int
{
	nd := d.nodes[n];
	if(nd.kind != Dom->Element || nd.ns != Dom->HTML)
		return 0;
	case nd.tag {
	Dom->Tinput or Dom->Tselect or Dom->Ttextarea or Dom->Tbutton =>
		return 1;
	}
	return 0;
}

# form numbers: forms[n] is the number of the form node n is in, 0 if none
formnumbers(d: ref Doc): (array of int, array of int)
{
	forms := array[d.n] of {* => 0};
	nodes: list of int;	# the form elements, reversed
	nf := 0;
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind == Dom->Element && nd.ns == Dom->HTML && nd.tag == Dom->Tform) {
			nf++;
			nodes = n :: nodes;
		}
		p := nd.parent;
		if(nd.kind == Dom->Element && nd.ns == Dom->HTML && nd.tag == Dom->Tform)
			forms[n] = nf;
		else if(p > 0 && p < d.n)
			forms[n] = forms[p];
	}
	fnode := array[nf+1] of {* => 0};
	for(i := nf; nodes != nil; nodes = tl nodes)
		fnode[i--] = hd nodes;
	return (forms, fnode);
}

kindof(d: ref Doc, n: int): string
{
	case d.nodes[n].tag {
	Dom->Tselect =>
		return "select";
	Dom->Ttextarea =>
		return "textarea";
	Dom->Tbutton =>
		t := lower(d.attr(n, "type"));
		if(t == "reset" || t == "button")
			return t;
		return "submit";
	}
	t := lower(d.attr(n, "type"));
	case t {
	"" or "text" or "search" or "email" or "url" or "tel" or "password" or "number" or
	"hidden" or "checkbox" or "radio" or "submit" or "reset" or "button" or "image" or
	"file" or "range" or "color" or "date" or "time" or "datetime-local" or "month" or "week" =>
		if(t == "")
			t = "text";
		return t;
	}
	return "text";
}

field(d: ref Doc, form, n: int): ref Field
{
	f := ref Field(form, n, kindof(d, n), d.attr(n, "name"), nil, 0, nil);
	case f.kind {
	"select" =>
		first := "";
		got := 0;
		ops: list of (string, string, int);
		for(o := d.nodes[n].first; o != 0; o = nextin(d, o, n)) {
			if(d.nodes[o].tag != Dom->Toption)
				continue;
			label := squash(d.textof(o));
			v := label;
			if(d.hasattr(o, "value"))
				v = d.attr(o, "value");
			sel := d.hasattr(o, "selected");
			if(first == "" && ops == nil)
				first = v;
			if(sel && !got) {
				f.value = v;
				got = 1;
			}
			ops = (v, label, sel) :: ops;
		}
		if(!got)
			f.value = first;
		for(; ops != nil; ops = tl ops)
			f.options = hd ops :: f.options;
	"textarea" =>
		f.value = d.textof(n);
	"button" or "submit" or "reset" =>
		f.value = d.attr(n, "value");
		if(d.nodes[n].tag == Dom->Tbutton && f.value == "")
			f.value = squash(d.textof(n));
	"checkbox" or "radio" =>
		f.value = d.attr(n, "value");
		if(!d.hasattr(n, "value"))
			f.value = "on";
		f.checked = d.hasattr(n, "checked");
	* =>
		f.value = d.attr(n, "value");
	}
	return f;
}

nextin(d: ref Doc, n, top: int): int
{
	if(d.nodes[n].first != 0)
		return d.nodes[n].first;
	while(n != top && n != 0) {
		if(d.nodes[n].next != 0)
			return d.nodes[n].next;
		n = d.nodes[n].parent;
	}
	return 0;
}

Session.fields(s: self ref Session): array of ref Field
{
	pg := s.pg;
	if(pg == nil)
		return nil;
	d := pg.doc;
	(forms, nil) := formnumbers(d);
	r: list of ref Field;
	for(n := 1; n < d.n; n++)
		if(iscontrol(d, n))
			r = field(d, forms[n], n) :: r;
	a := array[len r] of ref Field;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd r;
		r = tl r;
	}
	return a;
}

fieldstext(a: array of ref Field): string
{
	r := "";
	for(i := 0; i < len a; i++) {
		f := a[i];
		name := f.name;
		if(name == "")
			name = "-";
		r += sys->sprint("%d %d %s %s %s", f.form, f.node, f.kind, name, oneline(f.value));
		if(f.checked)
			r += " checked";
		r += "\n";
		for(o := f.options; o != nil; o = tl o) {
			(v, label, sel) := hd o;
			r += "\toption " + oneline(v) + " " + oneline(label);
			if(sel)
				r += " selected";
			r += "\n";
		}
	}
	return r;
}

Session.set(s: self ref Session, n: int, value: string): string
{
	pg := s.pg;
	if(pg == nil)
		return "no page";
	d := pg.doc;
	if(n <= 0 || n >= d.n || !iscontrol(d, n))
		return sys->sprint("node %d is not a form control", n);
	if(d.hasattr(n, "disabled"))
		return sys->sprint("node %d is disabled", n);
	lock(s);
	err := setfield(d, n, value);
	if(err == nil)
		pg.update();
	unlock(s);
	if(err == nil)
		event(s, "update");
	return err;
}

setfield(d: ref Doc, n: int, value: string): string
{
	case kindof(d, n) {
	"checkbox" =>
		case lower(value) {
		"" or "0" or "off" or "false" or "no" or "unchecked" =>
			d.delattr(n, "checked");
		* =>
			d.setattr(n, "checked", "");
		}
	"radio" =>
		case lower(value) {
		"" or "0" or "off" or "false" or "no" or "unchecked" =>
			d.delattr(n, "checked");
		* =>
			# one of a group: the others in its form with its name go off
			(forms, nil) := formnumbers(d);
			name := d.attr(n, "name");
			for(m := 1; m < d.n; m++)
				if(m != n && iscontrol(d, m) && kindof(d, m) == "radio" &&
				   forms[m] == forms[n] && name != "" && d.attr(m, "name") == name)
					d.delattr(m, "checked");
			d.setattr(n, "checked", "");
		}
	"select" =>
		found := 0;
		for(o := d.nodes[n].first; o != 0; o = nextin(d, o, n)) {
			if(d.nodes[o].tag != Dom->Toption)
				continue;
			v := squash(d.textof(o));
			if(d.hasattr(o, "value"))
				v = d.attr(o, "value");
			if(v == value && !found) {
				d.setattr(o, "selected", "");
				found = 1;
			} else if(!d.hasattr(n, "multiple"))
				d.delattr(o, "selected");
		}
		if(!found)
			return "no option " + value;
	"textarea" =>
		while((c := d.nodes[n].first) != 0)
			d.remove(c);
		t := d.create(Dom->Text, nil, Dom->HTML);
		d.settext(t, value);
		d.append(n, t);
	"submit" or "reset" or "button" or "image" or "file" =>
		return "cannot set a " + kindof(d, n);
	* =>
		d.setattr(n, "value", value);
	}
	return nil;
}

Session.submit(s: self ref Session, form, submitter: int): string
{
	pg := s.pg;
	if(pg == nil)
		return "no page";
	d := pg.doc;
	(forms, fnode) := formnumbers(d);
	if(form < 1 || form >= len fnode)
		return sys->sprint("no form %d", form);
	fe := fnode[form];
	action := d.attr(fe, "action");
	method := lower(d.attr(fe, "method"));
	if(submitter > 0 && submitter < d.n) {
		if(d.hasattr(submitter, "formaction"))
			action = d.attr(submitter, "formaction");
		if(d.hasattr(submitter, "formmethod"))
			method = lower(d.attr(submitter, "formmethod"));
	}
	url := resolve(d.url, action);
	q := "";
	for(n := 1; n < d.n; n++) {
		if(forms[n] != form || !iscontrol(d, n) || d.hasattr(n, "disabled"))
			continue;
		f := field(d, form, n);
		if(f.name == "")
			continue;
		case f.kind {
		"submit" or "image" =>
			if(n != submitter)
				continue;
			q = pair(q, f.name, f.value);
		"reset" or "button" or "file" =>
			continue;
		"checkbox" or "radio" =>
			if(f.checked)
				q = pair(q, f.name, f.value);
		"select" =>
			for(o := f.options; o != nil; o = tl o)
				if((hd o).t2)
					q = pair(q, f.name, (hd o).t0);
			if(f.options != nil && !anyselected(f.options))
				q = pair(q, f.name, f.value);
		* =>
			q = pair(q, f.name, f.value);
		}
	}
	if(method == "post")
		navigate(s, url, "POST", "application/x-www-form-urlencoded", array of byte q, Hnew);
	else {
		u := unfrag(url);
		for(i := 0; i < len u; i++)
			if(u[i] == '?') {
				u = u[0:i];
				break;
			}
		navigate(s, u + "?" + q, "GET", nil, nil, Hnew);
	}
	return nil;
}

anyselected(l: list of (string, string, int)): int
{
	for(; l != nil; l = tl l)
		if((hd l).t2)
			return 1;
	return 0;
}

pair(q, name, value: string): string
{
	if(q != "")
		q += "&";
	return q + formencode(name) + "=" + formencode(value);
}

# application/x-www-form-urlencoded
formencode(s: string): string
{
	r := "";
	b := array of byte s;
	for(i := 0; i < len b; i++) {
		c := int b[i];
		if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		   c == '*' || c == '-' || c == '.' || c == '_')
			r[len r] = c;
		else if(c == ' ')
			r[len r] = '+';
		else
			r += sys->sprint("%%%.2X", c);
	}
	return r;
}

# ---- pointing ----

Session.nodeat(s: self ref Session, x, y: int): int
{
	pg := s.pg;
	if(pg == nil)
		return 0;
	(n, nil) := layout->boxat(pg.root, Point(x, y));
	return n;
}

Session.paint(s: self ref Session, dst: ref Draw->Image, scroll: Point)
{
	lock(s);
	if(s.pg != nil)
		s.pg.paint(dst, scroll);
	unlock(s);
}

Session.boxof(s: self ref Session, n: int): (int, Draw->Rect)
{
	pg := s.pg;
	if(pg == nil)
		return (0, ((0, 0), (0, 0)));
	for(l := layout->boxes(pg.root, n); l != nil; l = tl l) {
		b := hd l;
		x := absx(b);
		y := absy(b);
		return (1, ((x, y), (x + b.w, y + b.h)));
	}
	return (0, ((0, 0), (0, 0)));
}

Session.linkat(s: self ref Session, x, y: int): string
{
	pg := s.pg;
	if(pg == nil)
		return nil;
	d := pg.doc;
	for(m := s.nodeat(x, y); m > 1; m = d.nodes[m].parent) {
		nd := d.nodes[m];
		if(nd.kind == Dom->Element && nd.ns == Dom->HTML && (nd.tag == Dom->Ta || nd.tag == Dom->Tarea) && d.hasattr(m, "href"))
			return resolve(d.url, d.attr(m, "href"));
	}
	return nil;
}

Session.findat(s: self ref Session, what: string, after: int): (int, Draw->Rect)
{
	pg := s.pg;
	if(pg == nil || what == "")
		return (0, ((0, 0), (0, 0)));
	(ok, r) := findin(pg.root, lower(what), after, 0, 0);
	return (ok, r);
}

# The first text fragment below y=after containing what, in page
# coordinates; ox, oy are b's parent's position.
findin(b: ref Box, what: string, after, ox, oy: int): (int, Draw->Rect)
{
	x := ox + b.x;
	y := oy + b.y;
	for(i := 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++) {
			f := ln.frags[j];
			if(f.kind == Layout->Ftext && y + ln.y + f.y > after && contains(lower(f.text), what))
				return (1, ((x + f.x, y + ln.y + f.y), (x + f.x + f.w, y + ln.y + f.y + ln.h)));
		}
	}
	for(i = 0; i < len b.kids; i++) {
		(ok, r) := findin(b.kids[i], what, after, x, y);
		if(ok)
			return (ok, r);
	}
	for(l := b.pos; l != nil; l = tl l) {
		(ok, r) := findin(hd l, what, after, x, y);
		if(ok)
			return (ok, r);
	}
	return (0, ((0, 0), (0, 0)));
}

Session.pageheight(s: self ref Session): int
{
	if(s.pg == nil)
		return 0;
	return s.pg.pageheight();
}

Session.click(s: self ref Session, n: int): string
{
	pg := s.pg;
	if(pg == nil)
		return "no page";
	d := pg.doc;
	if(n <= 0 || n >= d.n)
		return sys->sprint("no node %d", n);
	if(popovers(s, pg, n))
		return nil;
	if((us := pg.want(n)) != nil) {
		# an image left to be clicked for: this click loads it (and
		# what is shown with it), and does not follow a link it is in
		spawn picsome(s, s.gen, pg, us);
		return nil;
	}
	for(m := n; m > 1; m = d.nodes[m].parent) {
		nd := d.nodes[m];
		if(nd.kind != Dom->Element || nd.ns != Dom->HTML)
			continue;
		case nd.tag {
		Dom->Ta or Dom->Tarea =>
			if(d.hasattr(m, "href")) {
				u := resolve(d.url, d.attr(m, "href"));
				if(lower(scheme(u)) == "javascript")
					return "javascript: links need a script engine";
				navigate(s, u, "GET", nil, nil, Hnew);
				return nil;
			}
		Dom->Tlabel =>
			if((id := d.attr(m, "for")) != nil) {
				for(c := 1; c < d.n; c++)
					if(iscontrol(d, c) && d.attr(c, "id") == id)
						return s.click(c);
			}
			for(c := nextin(d, m, m); c != 0; c = nextin(d, c, m))
				if(iscontrol(d, c))
					return s.click(c);
		Dom->Tinput or Dom->Tbutton =>
			if(d.hasattr(m, "disabled"))
				return nil;
			(forms, nil) := formnumbers(d);
			case kindof(d, m) {
			"submit" or "image" =>
				if(forms[m] == 0)
					return nil;
				return s.submit(forms[m], m);
			"checkbox" =>
				if(d.hasattr(m, "checked"))
					return s.set(m, "off");
				return s.set(m, "on");
			"radio" =>
				return s.set(m, "on");
			"reset" =>
				return nil;	# a reset would need the original values
			}
			return nil;
		Dom->Tsummary =>
			p := d.nodes[m].parent;
			if(p > 0 && d.nodes[p].tag == Dom->Tdetails) {
				lock(s);
				if(d.hasattr(p, "open"))
					d.delattr(p, "open");
				else
					d.setattr(p, "open", "");
				pg.update();
				unlock(s);
				event(s, "update");
			}
			return nil;
		}
	}
	return nil;
}

# Popovers (HTML §6.12) without a script: a button with popovertarget
# shows, hides or toggles the element it names; a click outside an open
# auto popover closes it (light dismiss).  Whether the click was taken.
popovers(s: ref Session, pg: ref Pg, n: int): int
{
	d := pg.doc;
	changed := 0;
	invoked := 0;
	for(m := n; m > 1 && !invoked; m = d.nodes[m].parent) {
		nd := d.nodes[m];
		if(nd.kind != Dom->Element || nd.ns != Dom->HTML || (nd.tag != Dom->Tbutton && nd.tag != Dom->Tinput))
			continue;
		if((id := d.attr(m, "popovertarget")) == nil || d.hasattr(m, "disabled"))
			continue;
		t := byid(d, id);
		if(t == 0 || !d.hasattr(t, "popover"))
			continue;
		open := d.hasattr(t, Dom->POPOPEN);
		case lower(d.attr(m, "popovertargetaction")) {
		"show" =>
			if(!open) {
				d.setattr(t, Dom->POPOPEN, "");
				changed = 1;
			}
		"hide" =>
			if(open) {
				d.delattr(t, Dom->POPOPEN);
				changed = 1;
			}
		* =>
			if(open)
				d.delattr(t, Dom->POPOPEN);
			else
				d.setattr(t, Dom->POPOPEN, "");
			changed = 1;
		}
		invoked = t;
	}
	# light dismiss: open auto popovers the click is not inside
	for(p := 1; p < d.n; p++) {
		if(p == invoked || !d.hasattr(p, Dom->POPOPEN) || lower(d.attr(p, "popover")) == "manual")
			continue;
		if(inside(d, n, p))
			continue;
		d.delattr(p, Dom->POPOPEN);
		changed = 1;
	}
	if(changed) {
		lock(s);
		pg.update();
		unlock(s);
		event(s, "update");
	}
	return invoked != 0;
}

byid(d: ref Doc, id: string): int
{
	for(i := 1; i < d.n; i++)
		if(d.nodes[i].kind == Dom->Element && d.attr(i, "id") == id)
			return i;
	return 0;
}

inside(d: ref Doc, n, p: int): int
{
	for(; n > 0; n = d.nodes[n].parent)
		if(n == p)
			return 1;
	return 0;
}

# ---- the document, node by node ----

kindnames := array[] of {
	"block", "inline", "text", "br", "replaced", "flex", "grid", "table", "row", "cell", "marker",
};

Session.dom(s: self ref Session, n: int, what: string): (string, string)
{
	pg := s.pg;
	if(pg == nil)
		return (nil, "no page");
	d := pg.doc;
	if(n <= 0 || n >= d.n)
		return (nil, "no such node");
	nd := d.nodes[n];
	case what {
	"tag" =>
		case nd.kind {
		Dom->Element =>
			return (nd.name + "\n", nil);
		Dom->Text =>
			return ("#text\n", nil);
		Dom->Comment =>
			return ("#comment\n", nil);
		Dom->Doctype =>
			return ("#doctype\n", nil);
		}
		return ("#document\n", nil);
	"attrs" =>
		r := "";
		for(l := nd.attrs; l != nil; l = tl l)
			r += (hd l).t0 + " " + oneline((hd l).t1) + "\n";
		return (r, nil);
	"text" =>
		if(nd.kind == Dom->Text || nd.kind == Dom->Comment)
			return (nd.text, nil);
		return (d.textof(n), nil);
	"style" =>
		if(pg.computed == nil || n >= len pg.computed.st || pg.computed.st[n] == nil)
			return ("", nil);
		return (style->dump(pg.computed.st[n]), nil);
	"box" =>
		r := "";
		for(l := layout->boxes(pg.root, n); l != nil; l = tl l) {
			b := hd l;
			k := "?";
			if(b.kind >= 0 && b.kind < len kindnames)
				k = kindnames[b.kind];
			r += sys->sprint("%s %d %d %d %d\n", k, absx(b), absy(b), b.w, b.h);
		}
		return (r, nil);
	"children" =>
		r := "";
		for(c := nd.first; c != 0; c = d.nodes[c].next)
			r += string c + "\n";
		return (r, nil);
	}
	return (nil, "no such file");
}

# ---- URLs and strings ----

resolve(base, rel: string): string
{
	return style->resolveurl(base, rel);
}

scheme(u: string): string
{
	for(i := 0; i < len u; i++) {
		c := u[i];
		if(c == ':')
			return u[0:i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')))
			break;
	}
	return nil;
}

fragment(u: string): string
{
	for(i := 0; i < len u; i++)
		if(u[i] == '#')
			return u[i+1:];
	return nil;
}

unfrag(u: string): string
{
	for(i := 0; i < len u; i++)
		if(u[i] == '#')
			return u[0:i];
	return u;
}

pctdecode(s: string): string
{
	b := array of byte s;
	o := array[len b] of byte;
	n := 0;
	for(i := 0; i < len b; i++) {
		if(b[i] == byte '%' && i + 2 < len b && hex(int b[i+1]) >= 0 && hex(int b[i+2]) >= 0) {
			o[n++] = byte (hex(int b[i+1])*16 + hex(int b[i+2]));
			i += 2;
		} else
			o[n++] = b[i];
	}
	return string o[0:n];
}

hex(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

join(l: list of string, sep: string): string
{
	r := "";
	for(; l != nil; l = tl l) {
		if(r != "" && hd l != "")
			r += sep;
		r += hd l;
	}
	return r;
}

# collapse white space, as rendered text does
squash(s: string): string
{
	r := "";
	sp := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') {
			sp = 1;
			continue;
		}
		if(sp && r != "")
			r[len r] = ' ';
		sp = 0;
		r[len r] = c;
	}
	return r;
}

oneline(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'\n' =>
			r += "\\n";
		'\r' =>
			;
		* =>
			r[len r] = s[i];
		}
	return r;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

lower(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
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
