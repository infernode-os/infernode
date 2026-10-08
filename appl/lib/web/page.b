implement Page;

#
# A web page.  See module/web/page.m.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "imagefile.m";
	imageremap: Imageremap;
include "encoding.m";
	base64: Encoding;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/html.m";
	html: Html;
include "web/css.m";
	css: Css;
include "web/style.m";
	style: Style;
	Styles, Env: import style;
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
	layout: Layout;
	Box: import layout;
include "web/page.m";

display: ref Display;

# Layout's state is the module's, not a page's: one page lays out or
# paints at a time, so that a page loading behind the one shown, or
# images arriving for it, do not lay out under a paint.  Held for the
# work, never across a fetch.
plk: chan of int;

plock()
{
	plk <-= 1;
}

punlock()
{
	<-plk;
}

init(d: ref Display): string
{
	plk = chan[1] of int;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	dom = load Dom Dom->PATH;
	html = load Html Html->PATH;
	css = load Css Css->PATH;
	style = load Style Style->PATH;
	layout = load Layout Layout->PATH;
	imageremap = load Imageremap Imageremap->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	if(html == nil || css == nil || style == nil || layout == nil)
		return sys->sprint("cannot load modules: %r");
	display = d;
	html->init();
	css->init();
	if((err := style->init()) != nil)
		return err;
	style->setmetrics(fontmetrics);
	if((err = layout->init(d)) != nil)
		return err;
	if(imageremap != nil)
		imageremap->init(d);
	return nil;
}

open(url: string, width, height: int): (ref Pg, string)
{
	return request(url, "GET", nil, nil, width, height);
}

request(url, method, reqctype: string, body: array of byte, width, height: int): (ref Pg, string)
{
	(p, err) := begin(url, method, reqctype, body, width, height);
	if(p == nil)
		return (nil, err);
	if((urls := p.wanted()) != nil) {
		pics: list of ref Pic;
		for(got := fetchall(urls); got != nil; got = tl got) {
			g := hd got;
			pics = picture(g.url, g.data, g.ctype, g.err) :: pics;
		}
		p.install(pics);
	}
	p.frames();
	return (p, nil);
}

begin(url, method, reqctype: string, body: array of byte, width, height: int): (ref Pg, string)
{
	data: array of byte;
	ctype, err, final: string;
	if(method == "POST")
		(data, ctype, err, final) = webfs(url, method, reqctype, body);
	else
		(data, ctype, err, final) = fetchfinal(url);
	if(err != nil && len data == 0)
		return (nil, err);	# (webfs gives a failed dial an empty body, not none)
	url = final;	# a redirected page's links are relative to where it is
	charset := param(ctype, "charset");
	p := ref Pg(url, nil, Styles.new(), nil, nil,
		ref Env(width, height, 1.0, 0, 0, 0, 0, 0, 0), nil, width, height, nil, nil, nil);
	if(prefix(lower(ctype), "text/plain")) {
		# as a page of its own bytes, so that its charset applies
		p.doc = html->parse(escapebytes(data), charset, url);
	} else if(prefix(lower(ctype), "image/")) {
		p.doc = html->parsestring("<body style='margin:0'><img src=\"" + url + "\">", url);
	} else if(isxml(ctype))
		p.doc = html->parsexml(data, charset, url);
	else
		p.doc = html->parse(data, charset, url);
	d := p.doc;
	# <base href>
	if((b := d.find(1, Dom->Tbase)) != 0 && (h := d.attr(b, "href")) != nil) {
		d.url = style->resolveurl(url, h);
		p.url = d.url;
	}
	if((t := d.find(1, Dom->Ttitle)) != 0)
		p.title = squash(d.textof(t));
	loadsheets(p);
	loadfonts(p);
	findobjects(p);
	plock();
	{
		p.computed = style->compute(d, p.styles, p.env);
		rebuild(p);
	} exception e {
	"*" =>
		punlock();
		raise e;
	}
	punlock();
	return (p, nil);
}

# Build the boxes again from the computed styles, with the images the
# page has, and lay them out.  Under plk.
rebuild(p: ref Pg)
{
	bgpage = nil;	# its background images, again with any new ones
	usebg(p);
	old := p.root;
	layout->setobjects(p.objects);
	p.root = layout->build(p.doc, p.computed);
	if(old != nil)
		carryimages(old, p.root);
	applypics(p, p.root);
	layout->lay(p.root, p.width, p.height);
	if(old != nil)
		carrysvgs(p, inlinesvgs(p, old, nil), p.root);	# after: an inline SVG's picture is not its size
	inlinesvg(p, p.root);
}

# Layout keeps one table of background images: the page that last
# painted or laid out's.
bgpage: ref Pg;

usebg(p: ref Pg)
{
	if(bgpage == p)
		return;
	layout->clearbgimages();
	for(l := p.pics; l != nil; l = tl l) {
		pic := hd l;
		if(pic.img != nil) {
			layout->setbgimage(pic.url, pic.img);
			if(pic.svg != nil)
				layout->setbgsvg(pic.url, pic.svg);
		}
	}
	bgpage = p;
}

Pg.wanted(p: self ref Pg): list of string
{
	urls: list of string;
	plock();
	{
		curdoc = p.doc;
		for(l := replacedboxes(p.root, nil); l != nil; l = tl l)
			urls = (hd l).url :: urls;
		c := p.computed;
		for(i := 0; i < len c.st; i++) {
			if(c.st[i] != nil && c.st[i].display != Style->Dnone)
				for(lb := layout->bgurls(c.st[i]); lb != nil; lb = tl lb)
					urls = hd lb :: urls;
			if(c.before != nil && c.before[i] != nil)
				for(la := layout->bgurls(c.before[i]); la != nil; la = tl la)
					urls = hd la :: urls;
			if(c.after != nil && c.after[i] != nil)
				for(lc := layout->bgurls(c.after[i]); lc != nil; lc = tl lc)
					urls = hd lc :: urls;
		}
	} exception e {
	"*" =>
		punlock();
		raise e;
	}
	punlock();
	r: list of string;
	for(; urls != nil; urls = tl urls) {
		u := hd urls;
		if(u == nil || picof(p, u) != nil)
			continue;
		for(t := r; t != nil; t = tl t)
			if(hd t == u)
				break;
		if(t == nil)
			r = u :: r;
	}
	return r;
}

Pg.install(p: self ref Pg, pics: list of ref Pic)
{
	for(; pics != nil; pics = tl pics) {
		pic := hd pics;
		if(pic == nil || picof(p, pic.url) != nil)
			continue;
		if(pic.err != nil)
			p.errors = pic.url + ": " + pic.err :: p.errors;
		p.pics = pic :: p.pics;
	}
	plock();
	{
		rebuild(p);
	} exception e {
	"*" =>
		punlock();
		raise e;
	}
	punlock();
}

Pg.frames(p: self ref Pg)
{
	loadframes(p);
}

picof(p: ref Pg, url: string): ref Pic
{
	for(l := p.pics; l != nil; l = tl l)
		if((hd l).url == url)
			return hd l;
	return nil;
}

# An image fetched, decoded; or why not.
picture(url: string, data: array of byte, ctype, err: string): ref Pic
{
	if(err != nil)
		return ref Pic(url, nil, nil, err);
	img := decodeimage(data, ctype, url);
	if(img == nil)
		return ref Pic(url, nil, nil, "cannot decode " + ctype);
	svg: array of byte;
	if(prefix(lower(ctype), "image/svg") || looksvg(data))
		svg = data;
	return ref Pic(url, img, svg, nil);
}

# ---- nested documents ----
#
# An <iframe>, and an <object> whose data is a document, shows another
# page: the same pipeline run again at the frame's content size, and
# the result painted into an image the frame's box shows as a replaced
# element would.  A picture of the page, for now: no scrolling or
# clicking inside it.  Frames nest to FRAMEDEPTH, and a page does not
# frame itself.

FRAMEDEPTH: con 3;
framedepth := 0;
framing: list of string;	# the URLs of the pages being framed, innermost first

loadframes(p: ref Pg)
{
	if(framedepth >= FRAMEDEPTH)
		return;
	for(l := frameboxes(p, p.root, nil); l != nil; l = tl l) {
		b := hd l;
		w := b.w - b.bl - b.br - b.pl - b.pr;
		h := b.h - b.bt - b.bb - b.pt - b.pb;
		if(w <= 0 || h <= 0)
			continue;
		if(b.img != nil && b.img.r.dx() == w && b.img.r.dy() == h)
			continue;	# a relayout at the same size
		url := b.url;
		if(url == "about:srcdoc")
			url = "data:text/html;charset=utf-8," + pctencode(p.doc.attr(b.node, "srcdoc"));
		if(framed(url) || unfrag(url) == unfrag(p.url))
			continue;
		framedepth++;
		framing = p.url :: framing;
		sub: ref Pg;
		{
			(sub, nil) = request(url, "GET", nil, nil, w, h);
		} exception {
		"*" =>
			sub = nil;
		}
		framing = tl framing;
		framedepth--;
		img := display.newimage(Rect((0, 0), (w, h)), Draw->RGB24, 0, Draw->White);
		if(img == nil)
			continue;
		if(sub != nil)
			sub.paint(img, Point(0, 0));
		b.img = img;
		b.iw = w;
		b.ih = h;
		b.text = nil;
	}
}

framed(url: string): int
{
	for(l := framing; l != nil; l = tl l)
		if(unfrag(hd l) == unfrag(url))
			return 1;
	return 0;
}

unfrag(u: string): string
{
	for(i := 0; i < len u; i++)
		if(u[i] == '#')
			return u[0:i];
	return u;
}

# the boxes that show documents: <iframe>s, and <object>s whose data
# turned out to be one
frameboxes(p: ref Pg, b: ref Box, acc: list of ref Box): list of ref Box
{
	if(b.kind == Layout->Kreplaced && b.node != 0 && isframe(p, b))
		acc = b :: acc;
	for(i := 0; i < len b.kids; i++)
		acc = frameboxes(p, b.kids[i], acc);
	for(l := b.pos; l != nil; l = tl l)
		acc = frameboxes(p, hd l, acc);
	for(i = 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++)
			if(ln.frags[j].kind == Layout->Fatomic)
				acc = frameboxes(p, ln.frags[j].box, acc);
	}
	return acc;
}

isframe(p: ref Pg, b: ref Box): int
{
	nd := p.doc.nodes[b.node];
	if(nd.ns != Dom->HTML)
		return 0;
	if(nd.tag == Dom->Tiframe)
		return b.url != nil;
	if(nd.tag == Dom->Tobject)
		for(l := p.objects; l != nil; l = tl l) {
			(n, kind, u) := hd l;
			if(n == b.node && kind == Layout->Odoc) {
				b.url = u;
				return 1;
			}
		}
	return 0;
}

pctencode(s: string): string
{
	r := "";
	b := array of byte s;
	for(i := 0; i < len b; i++) {
		c := int b[i];
		if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == '_' || c == '~')
			r[len r] = c;
		else
			r += sys->sprint("%%%.2X", c);
	}
	return r;
}

Pg.relayout(p: self ref Pg, width, height: int)
{
	if(width == p.width && height == p.height)
		return;
	p.width = width;
	p.height = height;
	p.env.width = width;
	p.env.height = height;
	p.update();
}

Pg.target(p: self ref Pg, frag: string): int
{
	frag = pctdecode(frag);
	d := p.doc;
	n := 0;
	for(i := 1; i < d.n && n == 0; i++) {
		nd := d.nodes[i];
		if(nd.kind != Dom->Element || !attached(d, i))
			continue;
		if(d.attr(i, "id") == frag || nd.tag == Dom->Ta && d.attr(i, "name") == frag)
			n = i;
	}
	if(n == 0)
		return 0;
	if(p.env.target != n) {
		p.env.target = n;
		p.update();
	}
	for(l := layout->boxes(p.root, n); l != nil; l = tl l) {
		y := 0;
		for(b := hd l; b != nil; b = b.parent)
			y += b.y;
		return y;
	}
	return 0;
}

# in the document, not detached (the parser discards a few nodes)
attached(d: ref Doc, n: int): int
{
	while(n > 1)
		n = d.nodes[n].parent;
	return n == 1;
}

Pg.update(p: self ref Pg)
{
	plock();
	{
		p.computed = style->compute(p.doc, p.styles, p.env);
		rebuild(p);
	} exception e {
	"*" =>
		punlock();
		raise e;
	}
	punlock();
	loadframes(p);
}

Pg.paint(p: self ref Pg, dst: ref Image, scroll: Point)
{
	plock();
	{
		usebg(p);
		layout->paint(p.root, dst, dst.r.min.sub(scroll), dst.r);
	} exception e {
	"*" =>
		punlock();
		raise e;
	}
	punlock();
}

Pg.pageheight(p: self ref Pg): int
{
	return layout->height(p.root);
}

# <style> and <link rel=stylesheet>, in document order, then @imports.
loadsheets(p: ref Pg)
{
	d := p.doc;
	# the sheets in document order: (inline text, nil, nil) or (nil, url,
	# the link's charset attribute)
	sheets: list of (string, string, string);
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Element || nd.ns != Dom->HTML)
			continue;
		case nd.tag {
		Dom->Tstyle =>
			if(!style->mediamatch(css->tokenize(d.attr(n, "media")), p.env))
				continue;
			sheets = (d.textof(n), nil, nil) :: sheets;
		Dom->Tlink =>
			rel := " " + lower(d.attr(n, "rel")) + " ";
			if(index(rel, " stylesheet ") < 0 || index(rel, " alternate ") >= 0)
				continue;
			if(d.hasattr(n, "disabled"))
				continue;
			if(!style->mediamatch(css->tokenize(d.attr(n, "media")), p.env))
				continue;
			href := d.attr(n, "href");
			if(href == nil)
				continue;
			sheets = (nil, style->resolveurl(d.url, href), d.attr(n, "charset")) :: sheets;
		}
	}
	a := array[len sheets] of (string, string, string);
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd sheets;
		sheets = tl sheets;
	}
	urls: list of string;
	for(i = 0; i < len a; i++)
		if(a[i].t1 != nil)
			urls = a[i].t1 :: urls;
	got := fetchall(urls);
	for(i = 0; i < len a; i++) {
		(text, u, hint) := a[i];
		if(u == nil) {
			p.styles.add(css->parse(text), Style->Author, d.url);
			continue;
		}
		(data, ctype, err) := fetched(got, u);
		if(err != nil) {
			p.errors = u + ": " + err :: p.errors;
			continue;
		}
		if(!d.quirks && ctype != nil && lower(mediatype(ctype)) != "text/css") {
			# in standards mode a linked sheet must be served as text/css (HTML §4.2.4.3; content-type-000)
			p.errors = u + ": not text/css (" + ctype + ")" :: p.errors;
			continue;
		}
		p.styles.add(css->parse(html->cssdecode(data, param(ctype, "charset"), hint, d.charset)), Style->Author, u);
	}
	# @import, to a depth of 4
	for(depth := 0; depth < 4; depth++) {
		urls = p.styles.imports(p.env);
		if(urls == nil)
			break;
		got = fetchall(urls);
		for(; urls != nil; urls = tl urls) {
			(data, ctype, err) := fetched(got, hd urls);
			if(err != nil) {
				p.errors = hd urls + ": " + err :: p.errors;
				data = nil;
			}
			style->addimport(hd urls, css->parse(html->cssdecode(data, param(ctype, "charset"), nil, d.charset)));
		}
		p.styles.idx = nil;
	}
}

# ex and ch, measured in the fonts layout sets text in
fontsm: Fonts;
Typeface: import fontsm;

fontmetrics(family: list of string, weight, italic: int, size: real): (real, real)
{
	if(fontsm == nil)
		fontsm = layout->fontmod();
	f := fontsm->face(family, weight, italic, size);
	if(f == nil)
		return (size/2.0, size/2.0);
	return (f.xheight(), f.width("0"));
}

# ---- @font-face ----

Fontsrc: adt {
	family:	string;
	weight, italic:	int;
	ranges:	array of int;
	url:	string;
};

# Download the faces @font-face rules describe that this document's
# text needs (by unicode-range), in formats we read, and register them
# with the fonts layout uses.
loadfonts(p: ref Pg)
{
	fm := layout->fontmod();
	fm->clearfaces();
	srcs: list of ref Fontsrc;
	for(l := p.styles.sheets; l != nil; l = tl l) {
		(sh, nil, base) := hd l;
		srcs = fontrules(p, sh.rules, base, srcs);
	}
	if(srcs == nil)
		return;
	used := doctext(p.doc);
	urls: list of string;
	keep: list of ref Fontsrc;
	for(s := srcs; s != nil; s = tl s)
		if(needed((hd s).ranges, used)) {
			urls = (hd s).url :: urls;
			keep = hd s :: keep;
		}
	got := fetchall(urls);
	for(; keep != nil; keep = tl keep) {
		f := hd keep;
		(data, nil, err) := fetched(got, f.url);
		if(err == nil)
			err = fm->addface(f.family, f.weight, f.italic, f.ranges, data);
		if(err != nil)
			p.errors = f.url + ": " + err :: p.errors;
	}
}

fontrules(p: ref Pg, rs: array of ref Css->Rule, base: string, acc: list of ref Fontsrc): list of ref Fontsrc
{
	for(i := 0; i < len rs; i++)
		pick r := rs[i] {
		Fontface =>
			if((f := fontface(r.decls, base)) != nil)
				acc = f :: acc;
		Media =>
			if(style->mediamatch(r.cond, p.env))
				acc = fontrules(p, r.rules, base, acc);
		Supports =>
			if(style->supports(r.cond))
				acc = fontrules(p, r.rules, base, acc);
		Layer =>
			acc = fontrules(p, r.rules, base, acc);
		}
	return acc;
}

fontface(decls: array of ref Css->Decl, base: string): ref Fontsrc
{
	f := ref Fontsrc(nil, 400, 0, nil, nil);
	for(i := 0; i < len decls; i++) {
		d := decls[i];
		v := d.val;
		case d.name {
		"font-family" =>
			f.family = "";
			for(j := 0; j < len v; j++)
				case v[j].kind {
				Css->Kstring =>
					f.family = v[j].s;
				Css->Kident =>
					if(f.family != "")
						f.family += " ";
					f.family += v[j].s;
				}
			f.family = lower(f.family);
		"font-weight" =>
			for(j := 0; j < len v; j++)
				if(v[j].kind == Css->Knumber) {
					f.weight = int v[j].n;
					break;
				} else if(v[j].kind == Css->Kident) {
					if(v[j].s == "bold")
						f.weight = 700;
					break;
				}
		"font-style" =>
			if(len v > 0 && v[0].kind == Css->Kident && (v[0].s == "italic" || v[0].s == "oblique"))
				f.italic = 1;
		"unicode-range" =>
			f.ranges = uranges(css->tostring(v));
		"src" =>
			f.url = fontsrc(v, base);
		}
	}
	if(f.family == nil || f.family == "" || f.url == nil)
		return nil;
	return f;
}

# The first url() in src whose format we read; local() faces are not
# looked for.
fontsrc(v: array of ref Css->Tok, base: string): string
{
	u: string;
	ok := 1;
	for(j := 0; j <= len v; j++) {
		if(j == len v || v[j].kind == Css->Kcomma) {
			if(u != nil && ok)
				return style->resolveurl(base, u);
			u = nil;
			ok = 1;
			continue;
		}
		t := v[j];
		case t.kind {
		Css->Kurl =>
			u = t.s;
		Css->Kfunction =>
			case t.s {
			"url" =>
				for(k := 0; k < len t.kids; k++)
					if(t.kids[k].kind == Css->Kstring)
						u = t.kids[k].s;
			"format" =>
				fmt := "";
				for(k := 0; k < len t.kids; k++)
					if(t.kids[k].kind == Css->Kstring || t.kids[k].kind == Css->Kident)
						fmt = lower(t.kids[k].s);
				case fmt {
				"truetype" or "opentype" or "woff" or "woff2" or
				"truetype-variations" or "opentype-variations" or "woff-variations" or "woff2-variations" =>
					;
				* =>
					ok = 0;	# embedded-opentype, svg, collection
				}
			"tech" =>
				ok = 0;
			}
		}
	}
	return nil;
}

# "u+0460-052f, u+20b4, u+4??" as pairs; nil (everything) if unreadable
uranges(s: string): array of int
{
	(nil, l) := sys->tokenize(lower(s), ", \t\n");
	r: list of int;
	for(; l != nil; l = tl l) {
		t := hd l;
		if(len t < 3 || t[0:2] != "u+")
			return nil;
		t = t[2:];
		lo := 0;
		hi := 0;
		dash := 0;
		for(i := 0; i < len t; i++) {
			c := t[i];
			d := -1;
			if(c >= '0' && c <= '9')
				d = c - '0';
			else if(c >= 'a' && c <= 'f')
				d = c - 'a' + 10;
			if(c == '-' && !dash) {
				dash = 1;
				hi = 0;
				continue;
			}
			if(c == '?') {
				lo = lo*16;
				hi = hi*16 + 15;
				continue;
			}
			if(d < 0)
				return nil;
			if(dash)
				hi = hi*16 + d;
			else {
				lo = lo*16 + d;
				hi = hi*16 + d;
			}
		}
		r = hi :: lo :: r;
	}
	a := array[len r] of int;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd r;
		r = tl r;
	}
	return a;
}

# the code points the document's text uses, as a bitmap of the BMP
doctext(d: ref Dom->Doc): array of byte
{
	b := array[65536/8] of {* => byte 0};
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Text)
			continue;
		s := nd.text;
		for(i := 0; i < len s; i++)
			if(s[i] < 65536)
				b[s[i]>>3] |= byte (1 << (s[i]&7));
	}
	# what generated content and form controls may show
	for(c := 16r20; c < 16r7F; c++)
		b[c>>3] |= byte (1 << (c&7));
	return b;
}

needed(ranges: array of int, used: array of byte): int
{
	if(ranges == nil)
		return 1;
	for(i := 0; i + 1 < len ranges; i += 2)
		for(c := ranges[i]; c <= ranges[i+1] && c < 65536; c++)
			if(int used[c>>3] & (1 << (c&7)))
				return 1;
	return 0;
}

# <object data=...>: fetch each, and keep those whose data is an image
# (or a document, shown as an empty frame until there are nested
# documents).  The rest fall back to their contents: data that fails to
# load, or is of a type we cannot show (HTML 4.01 §13.3.1; Acid2).
findobjects(p: ref Pg)
{
	d := p.doc;
	urls: list of (int, string);
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Element || nd.tag != Dom->Tobject && nd.tag != Dom->Tembed || nd.ns != Dom->HTML)
			continue;
		an := "data";
		if(nd.tag == Dom->Tembed)
			an = "src";	# <embed src> shows an image as <object data> does (aspect-ratio/replaced-element-018)
		if((data := d.attr(n, an)) == nil)
			continue;
		urls = (n, style->resolveurl(d.url, data)) :: urls;
	}
	if(urls == nil)
		return;
	ul: list of string;
	for(l := urls; l != nil; l = tl l)
		ul = (hd l).t1 :: ul;
	got := fetchall(ul);
	r: list of (int, int, string);
	for(l = urls; l != nil; l = tl l) {
		(n, u) := hd l;
		(data, ctype, err) := fetched(got, u);
		if(err != nil)
			continue;
		ct := lower(ctype);
		if(decodeimage(data, ctype, u) != nil)
			r = (n, Layout->Oimage, u) :: r;
		else if(prefix(ct, "text/html") || prefix(ct, "application/xhtml") || prefix(ct, "text/plain"))
			r = (n, Layout->Odoc, u) :: r;
	}
	p.objects = r;
}

# Images for replaced boxes
curdoc: ref Doc;	# the document whose boxes replacedboxes walks

# The images the page has, on the boxes that show them.
applypics(p: ref Pg, root: ref Box)
{
	curdoc = p.doc;
	for(l := replacedboxes(root, nil); l != nil; l = tl l) {
		b := hd l;
		pic := picof(p, b.url);
		if(pic == nil || pic.img == nil)
			continue;
		b.img = pic.img;
		b.iw = pic.img.r.dx();
		b.ih = pic.img.r.dy();
		b.text = nil;
		if(pic.svg != nil) {
			nd := p.doc.nodes[b.node];
			svgdims(b, pic.svg, nd.ns == Dom->HTML && (nd.tag == Dom->Tobject || nd.tag == Dom->Tembed));
		}
	}
}

# An SVG image's intrinsic size is its root element's (SVG 2 §8.6):
# each dimension it has and its ratio.  Shown by <object>, it is a
# document whose root's percentage dimensions, and omitted ones (100%),
# are of the box it fills (replaced-intrinsic-001); as an image, a
# percentage is no dimension at all (CSS Images 3 §4.1).
svgdims(b: ref Box, data: array of byte, obj: int)
{
	(iw, ih, ratio, pw, ph) := layout->svgintrinsic(data);
	b.svg = 1;
	b.iw = 0;
	b.ih = 0;
	if(iw > 0)
		b.iw = iw;
	if(ih > 0)
		b.ih = ih;
	b.iratio = ratio;
	if(obj) {
		if(iw < 0 && pw == 0.0)
			pw = 100.0;
		if(ih < 0 && ph == 0.0)
			ph = 100.0;
		b.ipw = pw;
		b.iph = ph;
	}
}

# Inline <svg>: the subtree as markup, rendered at the box's size.
inlinesvg(p: ref Pg, b: ref Box)
{
	if(b.kind == Layout->Kreplaced && b.url == nil && b.node != 0) {
		nd := p.doc.nodes[b.node];
		if(nd.ns == Dom->SVG && nd.name == "svg") {
			w := b.w - b.bl - b.br - b.pl - b.pr;
			h := b.h - b.bt - b.bb - b.pt - b.pb;
			if(w > 0 && h > 0 && (b.img == nil || b.img.r.dx() != w || b.img.r.dy() != h))
				b.img = decodeimage(array of byte svgmarkup(p.doc, b.node, w, h, b.st), "image/svg+xml", nil);
		}
	} else if(b.kind == Layout->Kreplaced && b.url != nil && b.img != nil) {
		# an SVG image: drawn at the size it is shown, not scaled
		w := b.w - b.bl - b.br - b.pl - b.pr;
		h := b.h - b.bt - b.bb - b.pt - b.pb;
		if(w > 0 && h > 0 && (b.img.r.dx() != w || b.img.r.dy() != h))
			if((pic := picof(p, b.url)) != nil && pic.svg != nil)
				if((img := decodeimage(layout->svgresize(pic.svg, w, h), "image/svg+xml", nil)) != nil)
					b.img = img;
	}
	for(i := 0; i < len b.kids; i++)
		inlinesvg(p, b.kids[i]);
	for(l := b.pos; l != nil; l = tl l)
		inlinesvg(p, hd l);
	for(i = 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++)
			if(ln.frags[j].kind == Layout->Fatomic)
				inlinesvg(p, ln.frags[j].box);
	}
}

# Inline <svg>s drawn already, by node, to keep across a rebuild.
inlinesvgs(p: ref Pg, b: ref Box, acc: list of (int, ref Image)): list of (int, ref Image)
{
	if(b.kind == Layout->Kreplaced && b.url == nil && b.node != 0 && b.img != nil && p.doc.nodes[b.node].ns == Dom->SVG)
		acc = (b.node, b.img) :: acc;
	for(i := 0; i < len b.kids; i++)
		acc = inlinesvgs(p, b.kids[i], acc);
	for(l := b.pos; l != nil; l = tl l)
		acc = inlinesvgs(p, hd l, acc);
	for(i = 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++)
			if(ln.frags[j].kind == Layout->Fatomic)
				acc = inlinesvgs(p, ln.frags[j].box, acc);
	}
	return acc;
}

carrysvgs(p: ref Pg, imgs: list of (int, ref Image), b: ref Box)
{
	if(imgs == nil)
		return;
	if(b.kind == Layout->Kreplaced && b.url == nil && b.node != 0 && b.img == nil)
		for(l := imgs; l != nil; l = tl l)
			if((hd l).t0 == b.node) {
				b.img = (hd l).t1;
				break;
			}
	for(i := 0; i < len b.kids; i++)
		carrysvgs(p, imgs, b.kids[i]);
	for(pl := b.pos; pl != nil; pl = tl pl)
		carrysvgs(p, imgs, hd pl);
	for(i = 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++)
			if(ln.frags[j].kind == Layout->Fatomic)
				carrysvgs(p, imgs, ln.frags[j].box);
	}
}

svgmarkup(d: ref Doc, n, w, h: int, st: ref Style->St): string
{
	s := "<svg xmlns=\"http://www.w3.org/2000/svg\"";
	s += sys->sprint(" width=\"%d\" height=\"%d\"", w, h);
	# what CSS gives the svg element: its color (currentColor) and a
	# fill or stroke a stylesheet set, which wins over its attributes
	# and passes down to what it holds (an icon's svg { fill:
	# currentColor }); rules aimed at the shapes inside are not seen
	css := sys->sprint("color:#%.6x", (st.color >> 8) & 16rFFFFFF);
	if(st.svgfill != nil)
		css += ";fill:" + st.svgfill;
	if(st.svgstroke != nil)
		css += ";stroke:" + st.svgstroke;
	vb := 0;
	for(a := d.nodes[n].attrs; a != nil; a = tl a) {
		(k, v) := hd a;
		case k {
		"width" or "height" or "xmlns" =>
			continue;
		"style" =>
			css += ";" + v;	# its own style attribute still has the last word
			continue;
		"viewBox" =>
			vb = 1;
		}
		s += " " + k + "=\"" + xmlesc(v) + "\"";
	}
	s += " style=\"" + xmlesc(css) + "\"";
	if(!vb) {
		# without a viewBox the drawing keeps its own units
		ow := d.attr(n, "width");
		oh := d.attr(n, "height");
		if(ow != nil && oh != nil)
			s += " viewBox=\"0 0 " + xmlesc(num(ow)) + " " + xmlesc(num(oh)) + "\"";
	}
	s += ">";
	for(c := d.nodes[n].first; c != 0; c = d.nodes[c].next)
		s += xmlnode(d, c);
	return s + "</svg>";
}

num(s: string): string
{
	i := 0;
	while(i < len s && (s[i] >= '0' && s[i] <= '9' || s[i] == '.'))
		i++;
	return s[0:i];
}

xmlnode(d: ref Doc, n: int): string
{
	nd := d.nodes[n];
	case nd.kind {
	Dom->Text =>
		return xmlesc(nd.text);
	Dom->Element =>
		s := "<" + nd.name;
		for(a := nd.attrs; a != nil; a = tl a)
			s += " " + (hd a).t0 + "=\"" + xmlesc((hd a).t1) + "\"";
		if(nd.first == 0)
			return s + "/>";
		s += ">";
		for(c := nd.first; c != 0; c = d.nodes[c].next)
			s += xmlnode(d, c);
		return s + "</" + nd.name + ">";
	}
	return "";
}

xmlesc(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'<' => r += "&lt;";
		'>' => r += "&gt;";
		'&' => r += "&amp;";
		'"' => r += "&quot;";
		* => r[len r] = s[i];
		}
	return r;
}

replacedboxes(b: ref Box, acc: list of ref Box): list of ref Box
{
	if(b.kind == Layout->Kreplaced && b.url != nil && !(b.node != 0 && curdoc != nil && curdoc.nodes[b.node].tag == Dom->Tiframe))
		acc = b :: acc;
	for(i := 0; i < len b.kids; i++)
		acc = replacedboxes(b.kids[i], acc);
	return acc;
}

carryimages(old, new: ref Box)
{
	curdoc = nil;	# frames' pictures carry over too; loadframes checks their size
	imgs: list of (string, ref Image);
	for(l := replacedboxes(old, nil); l != nil; l = tl l)
		if((hd l).img != nil)
			imgs = ((hd l).url, (hd l).img) :: imgs;
	for(l = replacedboxes(new, nil); l != nil; l = tl l)
		for(i := imgs; i != nil; i = tl i)
			if((hd i).t0 == (hd l).url) {
				b := hd l;
				b.img = (hd i).t1;
				b.iw = b.img.r.dx();
				b.ih = b.img.r.dy();
				b.text = nil;
				break;
			}
}

decodeimage(data: array of byte, ctype, url: string): ref Image
{
	if(imageremap == nil || len data < 4)
		return nil;
	path := "";
	ct := lower(ctype);
	if(len data >= 8 && data[0] == byte 16r89 && data[1] == byte 'P' && data[2] == byte 'N' && data[3] == byte 'G')
		path = RImagefile->READPNGPATH;
	else if(data[0] == byte 16rFF && data[1] == byte 16rD8)
		path = RImagefile->READJPGPATH;
	else if(data[0] == byte 'G' && data[1] == byte 'I' && data[2] == byte 'F')
		path = RImagefile->READGIFPATH;
	else if(len data >= 12 && string data[0:4] == "RIFF" && string data[8:12] == "WEBP")
		path = RImagefile->READWEBPPATH;
	else if(len data >= 12 && string data[4:8] == "ftyp")
		path = RImagefile->READAVIFPATH;
	else if(prefix(ct, "image/svg") || suffix(lower(url), ".svg") || looksvg(data))
		path = RImagefile->READSVGPATH;
	if(path == "")
		return nil;
	rd := load RImagefile path;
	if(rd == nil)
		return nil;
	# a decoder that faults on one image costs that image, not the page
	{
		rd->init(bufio);
		(raw, err) := rd->read(bufio->aopen(data));
		if(raw == nil || err != nil)
			return nil;
		(img, nil) := imageremap->remap(raw, display, 0);
		return img;
	} exception e {
	"*" =>
		sys->fprint(sys->fildes(2), "charon: %s: %s: %s\n", url, path, e);
		return nil;
	}
}

looksvg(data: array of byte): int
{
	n := len data;
	if(n > 512)
		n = 512;
	return index(string data[0:n], "<svg") >= 0;
}

# ---- fetching ----

NFETCH: con 6;	# fetches at once, as browsers do per host

Got: adt {
	url:	string;
	data:	array of byte;
	ctype:	string;
	err:	string;
};

# Fetch urls concurrently, each distinct URL once.
fetchall(urls: list of string): list of ref Got
{
	todo: list of string;
	n := 0;
	for(; urls != nil; urls = tl urls) {
		u := hd urls;
		if(u == nil)
			continue;
		for(t := todo; t != nil; t = tl t)
			if(hd t == u)
				break;
		if(t == nil) {
			todo = u :: todo;
			n++;
		}
	}
	if(n == 0)
		return nil;
	work := chan[n] of string;
	for(; todo != nil; todo = tl todo)
		work <-= hd todo;
	res := chan of ref Got;
	nw := NFETCH;
	if(nw > n)
		nw = n;
	for(i := 0; i < nw; i++)
		spawn fetcher(work, res);
	got: list of ref Got;
	for(i = 0; i < n; i++)
		got = <-res :: got;
	return got;
}

fetcher(work: chan of string, res: chan of ref Got)
{
	for(;;) alt {
	u := <-work =>
		(data, ctype, err) := fetch(u);
		res <-= ref Got(u, data, ctype, err);
	* =>
		return;
	}
}

fetched(got: list of ref Got, url: string): (array of byte, string, string)
{
	for(; got != nil; got = tl got)
		if((hd got).url == url)
			return ((hd got).data, (hd got).ctype, (hd got).err);
	return (nil, nil, "not fetched");
}

fetch(url: string): (array of byte, string, string)
{
	(data, ctype, err, nil) := fetchfinal(url);
	return (data, ctype, err);
}

# fetch, and the URL the resource came from in the end
fetchfinal(url: string): (array of byte, string, string, string)
{
	(scheme, rest) := splitscheme(url);
	case scheme {
	"file" =>
		path := rest;
		if(prefix(path, "//")) {
			path = path[2:];
			i := 0;
			while(i < len path && path[i] != '/')
				i++;
			path = path[i:];	# file://host/path: the host is ignored
		}
		path = pctdecode(cutquery(cutfrag(path)));
		(d, c, e) := readfile(path);
		return (d, c, e, url);
	"data" =>
		(d, c, e) := dataurl(rest);
		return (d, c, e, url);
	"http" or "https" =>
		return webfs(url, "GET", nil, nil);
	"" =>
		(d, c, e) := readfile(url);
		return (d, c, e, url);
	}
	return (nil, nil, "unsupported scheme: " + scheme, url);
}

splitscheme(u: string): (string, string)
{
	for(i := 0; i < len u; i++) {
		c := u[i];
		if(c == ':')
			return (lower(u[0:i]), u[i+1:]);
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'))
			break;
	}
	return ("", u);
}

cutquery(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '?')
			return s[0:i];
	return s;
}

cutfrag(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '#' || s[i] == '?')
			return s[0:i];
	return s;
}

readfile(path: string): (array of byte, string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, nil, sys->sprint("%r"));
	data := readall(fd);
	return (data, mimetype(path, data), nil);
}

readall(fd: ref Sys->FD): array of byte
{
	buf := array[8192] of byte;
	n := 0;
	for(;;) {
		if(n == len buf) {
			nb := array[2*len buf] of byte;
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

# an XML document type, parsed as XML (image/svg+xml is an image)
isxml(ctype: string): int
{
	t := lower(ctype);
	for(i := 0; i < len t; i++)
		if(t[i] == ';' || t[i] == ' ') {
			t = t[0:i];
			break;
		}
	return t == "application/xhtml+xml" || t == "application/xml" || t == "text/xml";
}

mimetype(path: string, data: array of byte): string
{
	p := lower(path);
	if(suffix(p, ".html") || suffix(p, ".htm"))
		return "text/html";
	if(suffix(p, ".xht") || suffix(p, ".xhtml"))
		return "application/xhtml+xml";
	if(suffix(p, ".xml"))
		return "application/xml";
	if(suffix(p, ".css"))
		return "text/css";
	if(suffix(p, ".txt") || suffix(p, ".b") || suffix(p, ".m"))
		return "text/plain";
	if(suffix(p, ".svg"))
		return "image/svg+xml";
	if(suffix(p, ".png") || suffix(p, ".jpg") || suffix(p, ".jpeg") || suffix(p, ".gif") || suffix(p, ".webp"))
		return "image/" + p[len p - 3:];
	return "text/html";
}

# data:[<mediatype>][;base64],<data>
dataurl(s: string): (array of byte, string, string)
{
	c := 0;
	while(c < len s && s[c] != ',')
		c++;
	if(c == len s)
		return (nil, nil, "malformed data: URL");
	meta := s[0:c];
	payload := s[c+1:];
	isb64 := 0;
	ctype := meta;
	if(suffix(lower(meta), ";base64")) {
		isb64 = 1;
		ctype = meta[0:len meta - 7];
	}
	if(ctype == "")
		ctype = "text/plain;charset=US-ASCII";
	if(isb64) {
		if(base64 == nil)
			return (nil, nil, "no base64 decoder");
		clean := "";
		for(i := 0; i < len payload; i++)
			if(payload[i] != ' ' && payload[i] != '\n' && payload[i] != '\t' && payload[i] != '\r')
				clean[len clean] = payload[i];
		return (base64->dec(pctdecode(clean)), ctype, nil);
	}
	return (array of byte pctdecode(payload), ctype, nil);
}

pctdecode(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '%')
			break;
	if(i == len s)
		return s;
	# decode to bytes, then to UTF-8
	b := array[len s * 3] of byte;
	n := 0;
	for(i = 0; i < len s; i++) {
		if(s[i] == '%' && i+2 < len s && hexv(s[i+1]) >= 0 && hexv(s[i+2]) >= 0) {
			b[n++] = byte (hexv(s[i+1])*16 + hexv(s[i+2]));
			i += 2;
		} else {
			u := array of byte s[i:i+1];
			b[n:] = u;
			n += len u;
		}
	}
	return string b[0:n];
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

# http and https through webfs (see webfs(4)): clone a connection,
# write its URL, read its body.
webfs(url, method, reqctype: string, body: array of byte): (array of byte, string, string, string)
{
	cfd := sys->open(WEBFS + "/clone", Sys->OREAD);
	if(cfd == nil)
		return (nil, nil, "no webfs at " + WEBFS + ": " + sys->sprint("%r"), url);
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return (nil, nil, sys->sprint("webfs clone: %r"), url);
	id := squash(string buf[0:n]);
	dir := WEBFS + "/" + id;
	ctl := sys->open(dir + "/ctl", Sys->OWRITE);
	if(ctl == nil || sys->fprint(ctl, "url %s", url) < 0)
		return (nil, nil, sys->sprint("webfs: %r"), url);
	if(method != "GET") {
		if(sys->fprint(ctl, "method %s", method) < 0 ||
		   reqctype != nil && sys->fprint(ctl, "header Content-Type: %s", reqctype) < 0)
			return (nil, nil, sys->sprint("webfs: %r"), url);
		pfd := sys->open(dir + "/postbody", Sys->OWRITE);
		if(pfd == nil || sys->write(pfd, body, len body) != len body)
			return (nil, nil, sys->sprint("webfs postbody: %r"), url);
	}
	bfd := sys->open(dir + "/body", Sys->OREAD);
	if(bfd == nil)
		return (nil, nil, sys->sprint("%s: %r", url), url);
	data := readall(bfd);
	final := readstr(dir + "/url");
	if(final == "")
		final = url;	# an older webfs
	ctype := readstr(dir + "/contenttype");
	# an error's body comes too: a page shows a 404's, nothing else does
	status := readstr(dir + "/status");
	if(status != "" && !prefix(status, "2"))
		return (data, ctype, status, final);
	return (data, ctype, nil, final);
}

readstr(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	return squash(string readall(fd));
}

# ---- small things ----

param(ctype, name: string): string
{
	(nil, l) := sys->tokenize(ctype, ";");
	for(; l != nil; l = tl l) {
		s := squash(hd l);
		if(prefix(lower(s), name + "=")) {
			v := s[len name + 1:];
			if(len v >= 2 && v[0] == '"')
				v = v[1:len v - 1];
			return v;
		}
	}
	return nil;
}

# the bytes of a text/plain page wrapped in a <pre>, with the two
# characters that would be markup escaped (in any ASCII-compatible
# charset; UTF-16 pages are not expected as plain text)
escapebytes(data: array of byte): array of byte
{
	n := 0;
	for(i := 0; i < len data; i++)
		if(data[i] == byte '<')
			n += 4;
		else if(data[i] == byte '&')
			n += 5;
		else
			n++;
	pre := array of byte "<pre>";
	post := array of byte "</pre>";
	r := array[len pre + n + len post] of byte;
	r[0:] = pre;
	k := len pre;
	for(i = 0; i < len data; i++)
		case int data[i] {
		'<' =>
			r[k:] = array of byte "&lt;";
			k += 4;
		'&' =>
			r[k:] = array of byte "&amp;";
			k += 5;
		* =>
			r[k++] = data[i];
		}
	r[k:] = post;
	return r;
}

escape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'<' => r += "&lt;";
		'&' => r += "&amp;";
		* => r[len r] = s[i];
		}
	return r;
}

squash(s: string): string
{
	r := "";
	sp := 1;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r') {
			if(!sp)
				r[len r] = ' ';
			sp = 1;
		} else {
			r[len r] = c;
			sp = 0;
		}
	}
	if(len r > 0 && r[len r - 1] == ' ')
		r = r[0:len r - 1];
	return r;
}

# the media type of a Content-Type, without its parameters
mediatype(ct: string): string
{
	e := len ct;
	for(i := 0; i < len ct; i++)
		if(ct[i] == ';') {
			e = i;
			break;
		}
	st := 0;
	while(st < e && (ct[st] == ' ' || ct[st] == '\t'))
		st++;
	while(e > st && (ct[e-1] == ' ' || ct[e-1] == '\t'))
		e--;
	return ct[st:e];
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

suffix(s, t: string): int
{
	return len s >= len t && s[len s - len t:] == t;
}

index(s, t: string): int
{
	for(i := 0; i+len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}
