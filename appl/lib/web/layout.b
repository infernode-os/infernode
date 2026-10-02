implement Layout;

#
# Boxes.  See module/web/layout.m.
#
# The three passes are build (document to box tree), lay (box tree to
# geometry) and paint (geometry to pixels).  Each is a recursive walk;
# none keeps state between calls beyond the font and colour caches.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Path: import draw;
include "math.m";
	math: Math;
include "web/dom.m";
	dom: Dom;
	Doc, Node: import dom;
include "web/css.m";
	css: Css;
	Tok: import css;
include "web/style.m";
	style: Style;
	St, Len, Computed: import style;
include "outlinefont.m";
include "web/fonts.m";
include "bidi.m";
	bidi: Bidi;
	fonts: Fonts;
	Typeface: import fonts;
include "web/layout.m";

display: ref Display;

objects: list of (int, int, string);

setobjects(objs: list of (int, int, string))
{
	objects = objs;
}

fontmod(): Fonts
{
	return fonts;
}

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	dom = load Dom Dom->PATH;
	css = load Css Css->PATH;
	style = load Style Style->PATH;
	fonts = load Fonts Fonts->PATH;
	bidi = load Bidi Bidi->PATH;
	if(bidi != nil && bidi->init() != nil)
		bidi = nil;
	if(dom == nil || css == nil || style == nil || fonts == nil || math == nil)
		return sys->sprint("cannot load modules: %r");
	display = d;
	if((err := style->init()) != nil)
		return err;
	if((err = fonts->init(d)) != nil)
		return err;
	colors = array[Ncolors] of list of (int, ref Image);
	faces = array[Nfacecache] of list of (int, ref Typeface);
	return nil;
}

# ---- building the box tree ----

B: adt {
	d:	ref Doc;
	c:	ref Computed;
	counters:	list of (string, int);	# list-item numbering, innermost first
};

newbox(kind, inl, node: int, st: ref St): ref Box
{
	return ref Box(kind, inl, node, st, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, nil, nil, nil, 0, 0, nil, nil, nil, nil, 0, 0, 0, 0, 0, 0);
}

build(d: ref Doc, c: ref Computed): ref Box
{
	curdoc = d;
	root := d.root();
	if(root == 0 || c.st[root] == nil)
		return newbox(Kblock, 0, 0, style->anon(nil, Style->Dblock));
	b := ref B(d, c, nil);
	l := element(b, root);
	if(l == nil)
		return newbox(Kblock, 0, 0, style->anon(nil, Style->Dblock));
	setparents(hd l);
	return hd l;
}

setparents(b: ref Box)
{
	for(i := 0; i < len b.kids; i++) {
		b.kids[i].parent = b;
		setparents(b.kids[i]);
	}
}

# Out of flow: floats and absolutely positioned boxes.
isfloat(x: ref Box): int
{
	return x.st.float != Style->Fnone && x.kind != Ktext && x.kind != Kinline;
}

isabs(x: ref Box): int
{
	return x.st.position == Style->Pabsolute || x.st.position == Style->Pfixed;
}

isoof(x: ref Box): int
{
	return x.kind != Ktext && x.kind != Kmarker && (isabs(x) || isfloat(x));
}

# an in-flow block-level box
isblocklevel(x: ref Box): int
{
	return !x.inl && !isoof(x);
}

# The boxes an element generates (usually one; none for display:none,
# several for display:contents or an inline split around a block).
element(b: ref B, n: int): list of ref Box
{
	st := b.c.st[n];
	if(st == nil || st.display == Style->Dnone)
		return nil;
	nd := b.d.nodes[n];
	if(st.display == Style->Dcontents)
		return children(b, n, st);
	if((r := replaced(b, n, st)) != nil)
		return r :: nil;
	kind := Kblock;
	inl := 0;
	case st.display {
	Style->Dinline =>
		kind = Kinline;
		inl = 1;
	Style->Dinlineblock =>
		inl = 1;
	Style->Dflex =>
		kind = Kflex;
	Style->Dinlineflex =>
		kind = Kflex;
		inl = 1;
	Style->Dgrid =>
		kind = Kgrid;
	Style->Dinlinegrid =>
		kind = Kgrid;
		inl = 1;
	Style->Dtable =>
		kind = Ktable;
	Style->Dinlinetable =>
		kind = Ktable;
		inl = 1;
	Style->Dtablerow =>
		kind = Krow;
	Style->Dtablecell =>
		kind = Kcell;
	}
	if(nd.tag == Dom->Tbr && nd.ns == Dom->HTML)
		return newbox(Kbr, 1, n, st) :: nil;
	box := newbox(kind, inl, n, st);
	pushed := 0;
	if(st.counterreset != nil || nd.tag == Dom->Tol || nd.tag == Dom->Tul || nd.tag == Dom->Tmenu) {
		start := 1;
		if(nd.tag == Dom->Tol && (s := b.d.attr(n, "start")) != nil)
			start = int s;
		b.counters = ("list-item", start - 1) :: b.counters;
		pushed = 1;
	}
	kids: list of ref Box;
	if(st.display == Style->Dlistitem)
		kids = marker(b, n, st) :: nil;
	if((bs := b.c.before[n]) != nil)
		kids = generated(b, n, bs) :: kids;
	for(l := children(b, n, st); l != nil; l = tl l)
		kids = hd l :: kids;
	if((as := b.c.after[n]) != nil)
		kids = generated(b, n, as) :: kids;
	if(pushed)
		b.counters = tl b.counters;
	kids = rev(kids);
	if(kind == Kinline) {
		# an inline box around blocks is split into inline pieces
		# either side of them (CSS 2.2 §9.2.1.1)
		hasblock := 0;
		for(l = kids; l != nil; l = tl l)
			if(isblocklevel(hd l))
				hasblock = 1;
		if(hasblock)
			return splitinline(box, kids);
	}
	box.kids = fixkids(box, kids);
	return box :: nil;
}

children(b: ref B, n: int, st: ref St): list of ref Box
{
	r: list of ref Box;
	for(c := b.d.nodes[n].first; c != 0; c = b.d.nodes[c].next) {
		cn := b.d.nodes[c];
		case cn.kind {
		Dom->Text =>
			t := newbox(Ktext, 1, c, st);
			t.text = cn.text;
			r = t :: r;
		Dom->Element =>
			for(l := element(b, c); l != nil; l = tl l)
				r = hd l :: r;
		}
	}
	return rev(r);
}

splitinline(box: ref Box, kids: list of ref Box): list of ref Box
{
	r: list of ref Box;
	run: list of ref Box;
	for(; kids != nil; kids = tl kids) {
		k := hd kids;
		if(isblocklevel(k)) {
			if(run != nil) {
				p := ref *box;
				p.kids = toarray(rev(run));
				r = p :: r;
				run = nil;
			}
			r = k :: r;
		} else
			run = k :: run;
	}
	if(run != nil) {
		p := ref *box;
		p.kids = toarray(rev(run));
		r = p :: r;
	}
	return rev(r);
}

# Children of a block container are all block-level or all inline-level:
# runs of inline-level boxes beside blocks go in anonymous blocks, and
# runs of nothing but collapsible white space are dropped.
fixkids(box: ref Box, kids: list of ref Box): array of ref Box
{
	if(box.kind == Kinline)
		return toarray(kids);
	# anonymous table objects (CSS 2.2 §17.2.1)
	if(box.kind == Ktable)
		return toarray(tablekids(box, kids));
	if(isrowgroup(box))
		return toarray(wrapruns(box, kids, isrow, Krow, Style->Dtablerow));
	if(box.kind == Krow)
		return toarray(wrapruns(box, kids, iscell, Kcell, Style->Dtablecell));
	kids = orphans(box, kids);
	nblock := 0;
	ninline := 0;
	for(l := kids; l != nil; l = tl l)
		if(isblocklevel(hd l))
			nblock++;
		else if(!isoof(hd l))
			ninline++;
	# flex and grid items are blockified already; their text is wrapped
	if(nblock == 0 && box.kind != Kflex && box.kind != Kgrid)
		return toarray(kids);
	if(ninline == 0)
		return toarray(kids);
	# out-of-flow boxes go with an inline run they sit in, else stand alone
	r: list of ref Box;
	run: list of ref Box;
	for(l = kids; l != nil; l = tl l) {
		k := hd l;
		if(isblocklevel(k) || isoof(k) && run == nil) {
			r = flushrun(box, run, r);
			run = nil;
			r = k :: r;
		} else
			run = k :: run;
	}
	r = flushrun(box, run, r);
	return toarray(rev(r));
}

isrow(k: ref Box): int
{
	return k.kind == Krow;
}

iscell(k: ref Box): int
{
	return k.kind == Kcell;
}

# a table's own children: row groups, rows, captions, columns
istablepart(k: ref Box): int
{
	return k.kind == Krow || isrowgroup(k) || iscolumn(k) || k.st.display == Style->Dtablecaption;
}

# Runs of children that are not what the parent holds (rows in a row
# group, cells in a row) go in an anonymous box that is; runs of
# nothing but white space go.
wrapruns(parent: ref Box, kids: list of ref Box, ok: ref fn(k: ref Box): int, kind, display: int): list of ref Box
{
	r: list of ref Box;
	run: list of ref Box;
	for(l := kids; l != nil; l = tl l) {
		k := hd l;
		if(ok(k)) {
			r = flushwrap(parent, run, r, kind, display);
			run = nil;
			r = k :: r;
		} else
			run = k :: run;
	}
	r = flushwrap(parent, run, r, kind, display);
	return rev(r);
}

flushwrap(parent: ref Box, run, r: list of ref Box, kind, display: int): list of ref Box
{
	if(run == nil || blankrun(run))
		return r;
	a := newbox(kind, 0, 0, style->anon(parent.st, display));
	kids := rev(run);
	case kind {
	Krow =>
		kids = wrapruns(a, kids, iscell, Kcell, Style->Dtablecell);
	Kcell =>
		a.kids = fixkids(a, kids);
		return a :: r;
	}
	a.kids = toarray(kids);
	return a :: r;
}

tablekids(t: ref Box, kids: list of ref Box): list of ref Box
{
	r: list of ref Box;
	run: list of ref Box;
	for(l := kids; l != nil; l = tl l) {
		k := hd l;
		if(istablepart(k)) {
			r = flushwrap(t, run, r, Krow, Style->Dtablerow);
			run = nil;
			r = k :: r;
		} else
			run = k :: run;
	}
	r = flushwrap(t, run, r, Krow, Style->Dtablerow);
	return rev(r);
}

# Rows, cells and row groups outside a table get an anonymous one.
orphans(parent: ref Box, kids: list of ref Box): list of ref Box
{
	any := 0;
	for(l := kids; l != nil; l = tl l)
		if(isinternal(hd l))
			any = 1;
	if(!any)
		return kids;
	r: list of ref Box;
	run: list of ref Box;
	for(l = kids; l != nil; l = tl l) {
		k := hd l;
		if(isinternal(k) || run != nil && k.kind == Ktext && blankrun(k :: nil))
			run = k :: run;
		else {
			r = flushtable(parent, run, r);
			run = nil;
			r = k :: r;
		}
	}
	r = flushtable(parent, run, r);
	return rev(r);
}

isinternal(k: ref Box): int
{
	return k.kind == Krow || k.kind == Kcell || isrowgroup(k);
}

flushtable(parent: ref Box, run, r: list of ref Box): list of ref Box
{
	if(run == nil)
		return r;
	t := newbox(Ktable, 0, 0, style->anon(parent.st, Style->Dtable));
	# cells straight in the table: tablekids wraps them in a row
	t.kids = toarray(tablekids(t, rev(run)));
	return t :: r;
}

# end an inline run: wrapped in an anonymous block, unless it is only
# collapsible white space (and out-of-flow boxes, which stand alone)
flushrun(box: ref Box, run, r: list of ref Box): list of ref Box
{
	if(run == nil)
		return r;
	if(!blankrun(run))
		return anonblock(box, rev(run)) :: r;
	for(l := rev(run); l != nil; l = tl l)
		if(isoof(hd l))
			r = hd l :: r;
	return r;
}

anonblock(parent: ref Box, kids: list of ref Box): ref Box
{
	a := newbox(Kblock, 0, 0, style->anon(parent.st, Style->Dblock));
	a.kids = toarray(kids);
	return a;
}

blankrun(l: list of ref Box): int
{
	for(; l != nil; l = tl l) {
		k := hd l;
		if(isoof(k))
			continue;
		if(k.kind != Ktext)
			return 0;
		case k.st.whitespace {
		Style->Wpre or Style->Wprewrap or Style->Wbreakspaces =>
			return 0;
		}
		for(i := 0; i < len k.text; i++)
			if(!iswhite(k.text[i]))
				return 0;
	}
	return 1;
}

iswhite(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

# ::before and ::after: an inline box (or a block, per its display) holding
# the generated content.
generated(b: ref B, n: int, st: ref St): ref Box
{
	kind := Kinline;
	inl := 1;
	case st.display {
	Style->Dblock or Style->Dlistitem or Style->Dflowroot =>
		kind = Kblock;
		inl = 0;
	Style->Dinlineblock =>
		kind = Kblock;
	Style->Dflex =>
		kind = Kflex;
		inl = 0;
	}
	g := newbox(kind, inl, n, st);
	t := newbox(Ktext, 1, n, st);
	t.text = content(b, n, st);
	g.kids = array[] of {t};
	return g;
}

# The text of a content property.
content(b: ref B, n: int, st: ref St): string
{
	s := "";
	v := st.content;
	for(i := 0; i < len v; i++) {
		t := v[i];
		case t.kind {
		Css->Kstring =>
			s += t.s;
		Css->Kfunction =>
			case t.s {
			"attr" =>
				if(len t.kids > 0 && t.kids[0].kind == Css->Kident)
					s += b.d.attr(n, lower(t.kids[0].s));
			"counter" or "counters" =>
				if(len t.kids > 0 && t.kids[0].kind == Css->Kident) {
					v := counter(b, t.kids[0].s);
					sty := "decimal";
					for(k := 1; k < len t.kids; k++)
						if(t.kids[k].kind == Css->Kident)
							sty = lower(t.kids[k].s);
					s += markertext(sty, v);
				}
			}
		Css->Kident =>
			case lower(t.s) {
			"open-quote" =>
				s += "“";
			"close-quote" =>
				s += "”";
			}
		}
	}
	return s;
}

counter(b: ref B, nm: string): int
{
	for(l := b.counters; l != nil; l = tl l)
		if((hd l).t0 == nm)
			return (hd l).t1;
	return 0;
}

bumplistitem(b: ref B, n: int): int
{
	v := 1;
	if((s := b.d.attr(n, "value")) != nil) {
		v = int s;
		if(b.counters != nil && (hd b.counters).t0 == "list-item")
			b.counters = ("list-item", v) :: tl b.counters;
		return v;
	}
	if(b.counters != nil && (hd b.counters).t0 == "list-item") {
		v = (hd b.counters).t1 + 1;
		b.counters = ("list-item", v) :: tl b.counters;
	}
	return v;
}

marker(b: ref B, n: int, st: ref St): ref Box
{
	v := bumplistitem(b, n);
	m := newbox(Kmarker, 1, n, st);
	ms := b.c.marker[n];
	if(ms != nil && ms.content != nil)
		m.text = content(b, n, ms);
	else
		m.text = markertext(st.liststyle, v);
	if(ms != nil)
		m.st = ms;
	return m;
}

markertext(ls: string, v: int): string
{
	if(len ls > 0 && ls[0] == '"')
		return ls[1:];
	case ls {
	"none" =>
		return "";
	"disc" =>
		return "• ";
	"circle" =>
		return "◦ ";
	"square" =>
		return "▪ ";
	"disclosure-closed" =>
		return "▸ ";
	"disclosure-open" =>
		return "▾ ";
	"decimal-leading-zero" =>
		if(v < 10 && v >= 0)
			return "0" + string v + ". ";
		return string v + ". ";
	"lower-alpha" or "lower-latin" =>
		return alpha(v, 'a') + ". ";
	"upper-alpha" or "upper-latin" =>
		return alpha(v, 'A') + ". ";
	"lower-roman" =>
		return lower(roman(v)) + ". ";
	"upper-roman" =>
		return roman(v) + ". ";
	"lower-greek" =>
		return alpha(v, 16r3b1) + ". ";
	}
	return string v + ". ";
}

alpha(v, base: int): string
{
	if(v <= 0)
		return string v;
	s := "";
	while(v > 0) {
		v--;
		c := "";
		c[0] = base + v % 26;
		s = c + s;
		v /= 26;
	}
	return s;
}

roman(v: int): string
{
	if(v <= 0 || v >= 4000)
		return string v;
	vals := array[] of {1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1};
	syms := array[] of {"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"};
	s := "";
	for(i := 0; i < len vals; i++)
		while(v >= vals[i]) {
			s += syms[i];
			v -= vals[i];
		}
	return s;
}

# Replaced and form-control elements.
replaced(b: ref B, n: int, st: ref St): ref Box
{
	nd := b.d.nodes[n];
	inl := 1;
	case st.display {
	Style->Dblock or Style->Dlistitem or Style->Dflowroot or Style->Dflex or Style->Dgrid or Style->Dtable =>
		inl = 0;
	}
	if(nd.ns == Dom->SVG && nd.name == "svg") {
		r := newbox(Kreplaced, inl, n, st);
		r.iw = dimattr(b.d.attr(n, "width"), 300);
		r.ih = dimattr(b.d.attr(n, "height"), 150);
		return r;
	}
	if(nd.ns != Dom->HTML)
		return nil;
	case nd.tag {
	Dom->Timg =>
		r := newbox(Kreplaced, inl, n, st);
		src := imgsrc(b.d, n);
		if(src != nil)
			r.url = style->resolveurl(b.d.url, src);
		r.text = b.d.attr(n, "alt");
		return r;
	Dom->Tobject =>
		for(ol := objects; ol != nil; ol = tl ol) {
			(on, kind, url) := hd ol;
			if(on != n)
				continue;
			r := newbox(Kreplaced, inl, n, st);
			if(kind == Oimage)
				r.url = url;
			else {
				r.iw = 300;
				r.ih = 150;
			}
			return r;
		}
		# not renderable: its contents, as an ordinary element
	Dom->Tvideo or Dom->Tcanvas or Dom->Tiframe or Dom->Tembed =>
		r := newbox(Kreplaced, inl, n, st);
		r.iw = 300;
		r.ih = 150;
		if(nd.tag == Dom->Tvideo && (p := b.d.attr(n, "poster")) != nil)
			r.url = style->resolveurl(b.d.url, p);
		if(nd.tag == Dom->Tiframe) {
			# the document shown, fetched and rendered by page
			if((src := b.d.attr(n, "src")) != nil)
				r.url = style->resolveurl(b.d.url, src);
			else if(b.d.hasattr(n, "srcdoc"))
				r.url = "about:srcdoc";
		}
		return r;
	Dom->Tinput =>
		t := lower(b.d.attr(n, "type"));
		r := newbox(Kreplaced, inl, n, st);
		case t {
		"checkbox" or "radio" =>
			r.iw = r.ih = 13;
		"submit" or "reset" or "button" =>
			r.text = b.d.attr(n, "value");
			if(r.text == nil)
				case t {
				"submit" => r.text = "Submit";
				"reset" => r.text = "Reset";
				}
		"image" =>
			if((src := b.d.attr(n, "src")) != nil)
				r.url = style->resolveurl(b.d.url, src);
		"range" =>
			r.iw = 129;
			r.ih = 16;
		"color" =>
			r.iw = 50;
			r.ih = 27;
		* =>
			r.text = b.d.attr(n, "value");
			if(r.text == "") {
				r.text = b.d.attr(n, "placeholder");
				r.hint = 1;
			}
			r.iw = int (st.fontsize * 10.0);	# about 20 characters
			r.ih = ir(lineheight(st, face(st)));	# a line
		}
		return r;
	Dom->Ttextarea =>
		r := newbox(Kreplaced, inl, n, st);
		r.text = b.d.textof(n);
		r.iw = int (st.fontsize * 10.0);
		r.ih = int (st.fontsize * 2.4);
		return r;
	Dom->Tselect =>
		r := newbox(Kreplaced, inl, n, st);
		# the first selected option, else the first
		sel := "";
		for(o := nd.first; o != 0; o = next(b.d, o, n))
			if(b.d.nodes[o].tag == Dom->Toption) {
				if(sel == "" || b.d.hasattr(o, "selected"))
					sel = b.d.textof(o);
				if(b.d.hasattr(o, "selected"))
					break;
			}
		r.text = squash(sel) + " ▾";
		return r;
	}
	return nil;
}

next(d: ref Doc, n, top: int): int
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

dimattr(s: string, dflt: int): int
{
	if(s == nil)
		return dflt;
	v := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		v = v*10 + s[i] - '0';
	if(i == 0 || i < len s && s[i] == '%')
		return dflt;
	return v;
}

squash(s: string): string
{
	r := "";
	sp := 1;
	for(i := 0; i < len s; i++)
		if(iswhite(s[i])) {
			if(!sp)
				r[len r] = ' ';
			sp = 1;
		} else {
			r[len r] = s[i];
			sp = 0;
		}
	if(len r > 0 && r[len r - 1] == ' ')
		r = r[0:len r - 1];
	return r;
}

rev(l: list of ref Box): list of ref Box
{
	r: list of ref Box;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

toarray(l: list of ref Box): array of ref Box
{
	a := array[len l] of ref Box;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

lower(s: string): string
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

# ---- geometry ----

L: adt {
	vw, vh:	int;		# viewport: the initial containing block
	root:	ref Box;
	pending:	list of ref Abs;	# absolutely positioned boxes awaiting their containing block
};

# an absolutely positioned box, its containing block (nil: the initial
# one) and its static position, relative to the border box of sparent
Abs: adt {
	box:	ref Box;
	cb:	ref Box;
	sparent:	ref Box;
	sx, sy:	int;
	frag:	ref Frag;	# an inline-level box's place on its line, once the line is aligned (else nil)
	rightedge:	int;	# sx is the hypothetical box's right edge: its static parent is right-to-left (§10.3.7)
};

# the static position's x: the content box's start edge, which is the
# right one in a right-to-left block
staticx(b: ref Box): int
{
	if(b.st.dirrtl)
		return b.w - b.br - b.pr;
	return b.bl + b.pl;
}

# Floats placed in a block formatting context, as margin-box rectangles
# in the coordinates of the context's root border box.
Fctx: adt {
	left, right:	list of Rect;
};

Margin: adt {
	pos, neg:	int;	# largest positive, most negative
};

collapse(a, b: Margin): Margin
{
	if(b.pos > a.pos)
		a.pos = b.pos;
	if(b.neg < a.neg)
		a.neg = b.neg;
	return a;
}

mval(m: int): Margin
{
	if(m < 0)
		return Margin(0, m);
	return Margin(m, 0);
}

msum(m: Margin): int
{
	return m.pos + m.neg;
}

laygen := 0;	# which lay() this is: stamps the intrinsic-width cache

# A flex or grid container, or a table, gives an item a height of its
# own choosing (a stretched item's cross size, a column item's main
# size, a cell's row height).  That height is definite for the item's
# content (Flexbox §9.8): percentages inside resolve against it, and
# boxes positioned against it find it.  The container lays the item
# out with its height imposed; specheight hands it over.
imposed: ref Box;
imposedh: int;

specheight(b: ref Box, cbh: int): int
{
	if(b == imposed)
		return imposedh;
	if(b == asauto)
		return -1;
	return spech(b, b.st.height, cbh);
}

asauto: ref Box;	# being measured for its content height: its height property is ignored

# k's content height: its height as if auto (the max-content block
# size, CSS Sizing 3 §5.2), laid out at its width k.w
contentheightof(l: ref L, k: ref Box, cw: int): int
{
	outer := asauto;
	asauto = k;
	layblock(l, k, cw, -1, nil, 0, 0);
	asauto = outer;
	if(k.st.aspect > 0.0 && k.kind != Kreplaced) {
		# an aspect ratio gives an auto height from the width
		ah := ir(real (k.w - hextra(k)) / k.st.aspect) + vextra(k);
		if(ah > k.h)
			k.h = ah;
	}
	return k.h;
}

# lay k out again with the height h (its border box) imposed, if its
# content would come out differently for knowing it
imposeh(l: ref L, k: ref Box, h, cbw, cbh: int)
{
	if(heightmatters(k)) {	# even when h is what it had: it is definite now
		outer := imposed;
		outerh := imposedh;
		imposed = k;
		imposedh = h;
		layblock(l, k, cbw, cbh, nil, 0, 0);
		imposed = outer;
		imposedh = outerh;
	}
	k.h = h;
}

seethrough(o: int): int
{
	return o == Style->Ovisible || o == Style->Oclip;
}

# Would b's content come out differently if its height were known?
# Percentage heights, and boxes positioned against it.
heightmatters(b: ref Box): int
{
	if(b.kind == Kflex && b.st.flexdir < 2 || b.kind == Kgrid)
		return 1;	# its items stretch to it, or its rows are sized by it
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(k.kind == Ktext || k.kind == Kmarker)
			continue;
		st := k.st;
		if(st.height.pct != 0.0 || st.minheight.pct != 0.0 || st.maxheight.pct != 0.0 || isabs(k) ||
		   st.basis.pct != 0.0 && b.kind == Kflex && b.st.flexdir >= 2)	# a column item's percentage basis
			return 1;
		if(heightmatters(k))
			return 1;
	}
	return 0;
}

lay(root: ref Box, width, height: int)
{
	laygen++;
	l := ref L(width, height, root, nil);
	edges(root, width);
	sizew(root, width);
	layblock(l, root, width, height, ref Fctx(nil, nil), root.ml, root.mt);
	root.x = root.ml;
	root.y = root.mt;
	# boxes whose containing block is the viewport, in document order
	# (pending is newest first; pos lists are kept newest first too)
	vp: list of ref Abs;
	for(p := l.pending; p != nil; p = tl p)
		if((hd p).cb == nil)
			vp = hd p :: vp;
	for(; vp != nil; vp = tl vp)
		layabs(l, hd vp, root, Rect((-root.x, -root.y), (width - root.x, height - root.y)));
	l.pending = nil;
	number(root, 1);
}

# Give every box its place in tree order (flex items in order-modified
# order, as their container sorted them), which decides the painting
# order of layers with equal z-index whatever path collects them.
number(b: ref Box, n: int): int
{
	b.seq = n++;
	for(i := 0; i < len b.kids; i++)
		n = number(b.kids[i], n);
	for(pl := b.pos; pl != nil; pl = tl pl)
		if((hd pl).seq == 0)
			n = number(hd pl, n);
	return n;
}

ir(x: real): int
{
	return int x;	# rounds
}

res(v: Len, basis: int): int
{
	return ir(v.resolve(real basis));
}

# used padding, borders and margins (auto margins as 0, for now)
edges(b: ref Box, cbw: int)
{
	st := b.st;
	b.bt = st.bt;
	b.br = st.br;
	b.bb = st.bb;
	b.bl = st.bl;
	b.pt = res(st.pt, cbw);
	b.pr = res(st.pr, cbw);
	b.pb = res(st.pb, cbw);
	b.pl = res(st.pl, cbw);
	b.mt = res(st.mt, cbw);
	b.mr = res(st.mr, cbw);
	b.mb = res(st.mb, cbw);
	b.ml = res(st.ml, cbw);
	if(b.kind == Kinline || b.kind == Ktext) {
		# vertical margins of inline boxes have no effect on layout
		b.mt = b.mb = 0;
	}
}

hextra(b: ref Box): int
{
	return b.bl + b.br + b.pl + b.pr;
}

vextra(b: ref Box): int
{
	return b.bt + b.bb + b.pt + b.pb;
}

# a specified width as a border-box width, or -1 for auto
specw(b: ref Box, v: Len, cbw: int): int
{
	case v.kind {
	Style->Lpx or Style->Lcalc =>
		if(cbw < 0 && v.kind == Style->Lpx && v.pct != 0.0)
			return -1;
		w := res(v, cbw);
		if(!b.st.borderbox)
			w += hextra(b);
		return w;
	Style->Lmin or Style->Lmax or Style->Lfit =>
		(mn, mx) := intrinsic(b);	# margin-box widths: the keywords name the border box
		mg := mgs(b);
		case v.kind {
		Style->Lmin => return mn - mg;
		Style->Lmax => return mx - mg;
		}
		return fit(mn, mx, cbw) - mg;
	}
	return -1;
}

spech(b: ref Box, v: Len, cbh: int): int
{
	case v.kind {
	Style->Lpx or Style->Lcalc =>
		if(cbh < 0 && (v.kind == Style->Lcalc || v.pct != 0.0))
			return -1;
		h := res(v, cbh);
		if(!b.st.borderbox)
			h += vextra(b);
		return h;
	}
	return -1;
}

fit(mn, mx, avail: int): int
{
	w := avail;
	if(w > mx)
		w = mx;
	if(w < mn)
		w = mn;
	return w;
}

# Clamp a border-box width by min-width and max-width.
clampw(b: ref Box, w, cbw: int): int
{
	if(b.st.maxwidth.kind != Style->Lnone) {
		mx := specw(b, b.st.maxwidth, cbw);
		if(mx >= 0 && w > mx)
			w = mx;
	}
	mn := specw(b, b.st.minwidth, cbw);
	if(mn >= 0 && w < mn)
		w = mn;
	if(w < hextra(b))
		w = hextra(b);
	return w;
}

clamph(b: ref Box, h, cbh: int): int
{
	if(b.st.maxheight.kind != Style->Lnone) {
		mx := spech(b, b.st.maxheight, cbh);
		if(mx >= 0 && h > mx)
			h = mx;
	}
	mn := spech(b, b.st.minheight, cbh);
	if(mn >= 0 && h < mn)
		h = mn;
	if(h < vextra(b))
		h = vextra(b);
	return h;
}

# Does b establish a new block formatting context?
isbfc(b: ref Box): int
{
	st := b.st;
	if(b.inl || b.kind != Kblock)
		return 1;
	if(st.float != Style->Fnone || st.position == Style->Pabsolute || st.position == Style->Pfixed)
		return 1;
	if(st.overflowx != Style->Ovisible || st.overflowy != Style->Ovisible)
		return 1;
	case st.display {
	Style->Dflowroot or Style->Dtablecell or Style->Dtablecaption or Style->Dinlineblock =>
		return 1;
	}
	return 0;
}

# The used width of a block-level box in a containing block cbw wide
# (CSS 2.2 §10.3.3): auto fills, auto margins centre.
sizew(b: ref Box, cbw: int)
{
	st := b.st;
	w := specw(b, st.width, cbw);
	if(w < 0) {
		if(b.kind == Kreplaced) {
			(iw, nil) := replacedsize(b, cbw, -1);
			w = iw + hextra(b);
		} else if(b.kind == Ktable && st.width.kind == Style->Lauto) {
			(mn, mx) := intrinsic(b);
			w = fit(mn, mx, cbw - b.ml - b.mr);
		} else {
			# auto: fill, but if min/max-width step in, auto
			# margins take up the difference
			w = cbw - b.ml - b.mr;
			cw := clampw(b, w, cbw);
			b.w = cw;
			if(cw == w)
				return;
			w = cw;
		}
	}
	w = clampw(b, w, cbw);
	b.w = w;
	# auto margins share what is left over
	free := cbw - w - b.ml - b.mr;
	lauto := st.ml.kind == Style->Lauto;
	rauto := st.mr.kind == Style->Lauto;
	if(lauto && rauto) {
		b.ml = free/2;
		if(b.ml < 0)
			b.ml = 0;
		b.mr = cbw - w - b.ml;
	} else if(lauto)
		b.ml += free;
	else if(rauto)
		b.mr += free;
	else if(free > 0 && incenter(b)) {
		# <center> centres its block children too (HTML §15.3.3:
		# text-align: -webkit-center), as pages of its era expect
		b.ml += free/2;
		b.mr += free - free/2;
	}
}

# is b a block child of <center> (or of its anonymous blocks)?
incenter(b: ref Box): int
{
	for(p := b.parent; p != nil; p = p.parent) {
		if(p.node != 0)
			return curdoc != nil && curdoc.nodes[p.node].tag == Dom->Tcenter &&
				curdoc.nodes[p.node].ns == Dom->HTML;
		if(p.kind != Kblock)
			break;
	}
	return 0;
}

# Lay out a block-level box whose width is settled; set its height and
# its children's geometry.  fc is the block formatting context its
# content takes part in and (ox, oy) where its border box sits in it.
# Returns its top and bottom margins, collapsed with any of its
# children's that adjoin them, and whether its own margins collapse
# through it.
layblock(l: ref L, b: ref Box, cbw, cbh: int, fc: ref Fctx, ox, oy: int): (Margin, Margin, int)
{
	case b.kind {
	Kreplaced =>
		h := specheight(b, cbh);
		if(h < 0)
			h = replacedheight(b, cbw, cbh) + vextra(b);
		b.h = clamph(b, h, cbh);
		return (mval(b.mt), mval(b.mb), 0);
	Kflex =>
		layflex(l, b, cbw, cbh);
		positioned(l, b);
		return (mval(b.mt), mval(b.mb), 0);
	Kgrid =>
		laygrid(l, b, cbw, cbh);
		positioned(l, b);
		return (mval(b.mt), mval(b.mb), 0);
	Ktable =>
		laytable(l, b, cbw, cbh);
		positioned(l, b);
		return (mval(b.mt), mval(b.mb), 0);
	}
	cw := b.w - hextra(b);
	if(cw < 0)
		cw = 0;
	sh := specheight(b, cbh);
	ch := -1;		# content height for percentages inside
	if(sh >= 0)
		ch = sh - vextra(b);
	bfc := isbfc(b) || b == l.root || fc == nil;	# the root holds the initial formatting context
	if(bfc) {
		fc = ref Fctx(nil, nil);
		ox = oy = 0;
	}
	cx := ox + b.bl + b.pl;	# content box, in fc
	cy := oy + b.bt + b.pt;
	passtop := !bfc && b.bt == 0 && b.pt == 0;
	passbot := !bfc && b.bb == 0 && b.pb == 0 && sh < 0;
	top := mval(b.mt);
	bot := mval(b.mb);
	contenth := 0;
	empty := 0;
	if(haslines(b)) {
		contenth = layinline(l, b, cw, ch, fc, ox, oy);
		if(len b.lines > 0)
			passtop = passbot = 0;
		else {
			# only collapsible white space: no line boxes, so its
			# margins may collapse through it (§8.3.1)
			mh := b.st.minheight;
			if(passtop && passbot && sh <= 0 && b.kind == Kblock &&
			   (mh.kind == Style->Lauto || mh.kind == Style->Lpx && mh.px == 0.0 && mh.pct == 0.0))
				empty = 1;
		}
	} else {
		pending := Margin(0, 0);
		cury := 0;
		adjoining := passtop;	# still at the top, margins adjoin ours
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			if(isabs(k)) {
				sx := staticx(b);
				if(k.st.wasinline && fc != nil) {
					# an inline-level box's static position: on a line
					# of its own here, aligned as text would be (Position 3 §3.1)
					sy := cy + cury + msum(pending);
					(lx, rx) := band(fc, sy, sy + 1, cx, cx + cw);
					sx = b.bl + b.pl + lx - cx;
					al := b.st.align;
					if(b.st.dirrtl && al == Style->Astart || !b.st.dirrtl && al == Style->Aend)
						al = Style->Aright;
					case al {
					Style->Acenter =>	sx += (rx - lx)/2;
					Style->Aright =>	sx += rx - lx;
					}
				}
				l.pending = ref Abs(k, cbof(l, k), b, sx, b.bt + b.pt + cury + msum(pending), nil, b.st.dirrtl) :: l.pending;
				continue;
			}
			if(isfloat(k)) {
				placefloat(l, k, fc, cx, cy + cury + msum(pending), cw, ch, ox, oy);
				continue;
			}
			edges(k, cw);
			sizew(k, cw);
			# where it will go, before its own margins collapse
			ky := cury;
			if(!adjoining)
				ky += msum(collapse(pending, mval(k.mt)));
			cleared := 0;
			if(k.st.clear != Style->Cnone) {
				# the border edge goes no higher than the floats' bottom
				# margin edges (CSS 2.2 §9.5.2)
				cl := clearance(fc, k.st.clear) - cy;
				# its hypothetical position: a top margin collapsing
				# through this box still moves it down
				hyp := ky + msum(collapse(pending, topmargin(k, cw))) - msum(collapse(pending, mval(k.mt)));
				if(adjoining)
					hyp = ky + msum(collapse(top, topmargin(k, cw))) - msum(top);
				if(cl > hyp) {
					cleared = 1;
					# clearance: the margins above no longer collapse with it
					if(adjoining)
						adjoining = 0;
					cury = cl - msum(collapse(pending, mval(k.mt)));
					ky = cl;
				}
			}
			k.x = b.bl + b.pl + k.ml;
			if(isbfc(k) && fc.left != nil || isbfc(k) && fc.right != nil) {
				# a new formatting context does not overlap floats: it
				# narrows beside them, or, when it cannot get narrow
				# enough, moves down past them (CSS 2.2 §9.5)
				(lx, rx) := band(fc, cy + ky, cy + ky + 1, cx, cx + cw);
				if(lx > cx || rx < cx + cw) {
					need := k.w + k.ml + k.mr;
					if(k.st.width.kind == Style->Lauto) {
						(kmn, nil) := intrinsic(k);
						need = kmn;
					}
					for(tries := 0; tries < 1000 && rx - lx < need && (lx > cx || rx < cx + cw); tries++) {
						n := nextfloat(fc, cy + ky);
						if(n < 0)
							break;
						ky = n - cy;
						cury = ky - msum(collapse(pending, mval(k.mt)));
						cleared = 1;
						adjoining = 0;
						(lx, rx) = band(fc, cy + ky, cy + ky + 1, cx, cx + cw);
					}
					avail := rx - lx - k.ml - k.mr;
					if(k.w > avail && k.st.width.kind == Style->Lauto)
						k.w = clampw(k, avail, cw);
					k.x = lx - ox + k.ml;
				}
			}
			(kt, kb, kempty) := layblock(l, k, cw, ch, fc, ox + k.x, oy + b.bt + b.pt + ky);
			if(kempty) {
				# margins collapse through an empty box
				m := collapse(kt, kb);
				# where its top border edge would be with a bottom border
				# (§8.3.1): after the margins above, its own top included
				if(adjoining) {
					top = collapse(top, m);
					k.y = b.bt + b.pt + cury;
				} else if(cleared) {
					# the clearance has taken the place of its margins
					k.y = b.bt + b.pt + cury + msum(collapse(pending, kt));
					# its collapsed margins end where the clearance put it;
					# a following margin joins them rather than adding
					cury = k.y - b.bt - b.pt - msum(m);
					pending = m;
				} else {
					k.y = b.bt + b.pt + cury + msum(collapse(pending, kt));
					pending = collapse(pending, m);
				}
				relative(k, cw, ch);
				continue;
			}
			if(adjoining) {
				top = collapse(top, kt);
				k.y = b.bt + b.pt + cury;
				adjoining = 0;
			} else {
				m := collapse(pending, kt);
				k.y = b.bt + b.pt + cury + msum(m);
			}
			cury = k.y - b.bt - b.pt + k.h;
			pending = kb;
			relative(k, cw, ch);
		}
		if(adjoining) {
			# no in-flow content at all
			mh := b.st.minheight;
			if(passbot && sh <= 0 && (mh.kind == Style->Lauto || mh.kind == Style->Lpx && mh.px == 0.0 && mh.pct == 0.0) &&
			   b.kind == Kblock) {
				empty = 1;
				top = collapse(top, pending);
			}
		} else if(passbot)
			bot = collapse(bot, pending);
		else
			cury += msum(pending);
		contenth = cury;
	}
	if(bfc) {
		# a formatting context's height takes in its floats
		fb := floatbottom(fc) - b.bt - b.pt;
		if(fb > contenth)
			contenth = fb;
		if(contenth > 0)
			empty = 0;
	}
	h := sh;
	if(h < 0)
		h = contenth + vextra(b);
	b.h = clamph(b, h, cbh);
	if(empty && b.h != 0)
		empty = 0;
	positioned(l, b);
	return (top, bot, empty);
}

# ---- flex layout (CSS Flexbox 1 §9) ----

Fi: adt {
	box:	ref Box;
	base:	real;		# flex base size (outer main margins excluded)
	hyp:	real;		# hypothetical main size: base clamped
	main:	real;		# target main size
	minm, maxm:	real;	# main-size clamps (maxm < 0: none)
	frozen:	int;
	mm:	int;		# main-axis margins
	cross:	int;		# outer cross size
	pos:	int;		# main position (margin edge)
};

Fline: adt {
	items:	array of ref Fi;
	cross:	int;
	pos:	int;
};

# a box's border-box main size from a length, or -1
mainsize(k: ref Box, v: Len, row, avail: int): int
{
	if(row)
		return specw(k, v, avail);
	return spech(k, v, avail);
}

# an absolutely positioned child of a flex container is not an item:
# order does not move it
orderof(k: ref Box): int
{
	if(isabs(k))
		return 0;
	return k.st.order;
}

layflex(l: ref L, b: ref Box, cbw, cbh: int)
{
	st := b.st;
	row := st.flexdir < 2;
	rev := st.flexdir == 1 || st.flexdir == 3;
	if(row && st.dirrtl)
		rev = !rev;	# main-start is the right (§5.1)
	wrap := st.flexwrap != 0;
	cw := b.w - hextra(b);
	if(cw < 0)
		cw = 0;
	sh := specheight(b, cbh);
	ch := -1;
	if(sh >= 0)
		ch = clamph(b, sh, cbh) - vextra(b);
	# the main and cross space; a column's main size is definite only
	# when its height is (§9.2), the space to flex into may come from
	# max-height as well
	maindef := cw;
	mainavail := cw;
	if(!row) {
		maindef = ch;
		mainavail = ch;
		if(mainavail < 0) {
			mx := spech(b, st.maxheight, cbh);
			if(mx >= 0)
				mainavail = mx - vextra(b);
		}
	}
	gapmain := res(st.colgap, cw);
	gapcross := res(st.rowgap, cw);
	if(!row) {
		(gapmain, gapcross) = (gapcross, gapmain);
		if(st.rowgap.kind == Style->Lnormal)
			gapmain = 0;
	}
	if(st.colgap.kind == Style->Lnormal && row)
		gapmain = 0;
	if(st.rowgap.kind == Style->Lnormal && row)
		gapcross = 0;

	# items, in order-modified document order
	items: list of ref Fi;
	n := 0;
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k)) {
			l.pending = ref Abs(k, cbof(l, k), b, b.bl + b.pl, b.bt + b.pt, nil, 0) :: l.pending;
			continue;
		}
		items = ref Fi(k, 0.0, 0.0, 0.0, 0.0, -1.0, 0, 0, 0, 0) :: items;
		n++;
	}
	fa := array[n] of ref Fi;
	for(i = n-1; i >= 0; i--) {
		fa[i] = hd items;
		items = tl items;
	}
	for(i = 1; i < n; i++)
		for(j := i; j > 0 && fa[j].box.st.order < fa[j-1].box.st.order; j--)
			(fa[j], fa[j-1]) = (fa[j-1], fa[j]);
	# the children too: order-modified document order is also the
	# painting order (§5.4); absolutely positioned children are not
	# items and keep their places
	for(i = 1; i < len b.kids; i++)
		for(m := i; m > 0 && orderof(b.kids[m]) < orderof(b.kids[m-1]); m--)
			(b.kids[m], b.kids[m-1]) = (b.kids[m-1], b.kids[m]);

	# flex base sizes and hypothetical main sizes (§9.2)
	for(i = 0; i < n; i++) {
		fi := fa[i];
		k := fi.box;
		edges(k, cw);
		if(k.st.ml.kind == Style->Lauto) k.ml = 0;
		if(k.st.mr.kind == Style->Lauto) k.mr = 0;
		if(k.st.mt.kind == Style->Lauto) k.mt = 0;
		if(k.st.mb.kind == Style->Lauto) k.mb = 0;
		if(row)
			fi.mm = k.ml + k.mr;
		else
			fi.mm = k.mt + k.mb;
		ks := k.st;
		base := -1;
		basis := ks.basis;
		if(basis.kind == Style->Lauto) {
			if(row)
				basis = ks.width;
			else
				basis = ks.height;
		}
		if(basis.kind != Style->Lauto && basis.kind != Style->Lcontent)
			base = mainsize(k, basis, row, maindef);
		contenth := -1;	# a column item's content height, once known
		if(base < 0) {
			# content size
			if(row) {
				(nil, mx) := intrinsic(k);
				base = mx - mgs(k);
			} else {
				k.w = flexcrossw(k, b, cw);
				base = contenth = contentheightof(l, k, cw);
			}
		}
		fi.base = real base;
		# automatic minimum size: the min-content size
		mnv := ks.minwidth;
		mxv := ks.maxwidth;
		if(!row) {
			mnv = ks.minheight;
			mxv = ks.maxheight;
		}
		minm := mainsize(k, mnv, row, maindef);
		if(minm < 0) {
			minm = 0;
			# (overflow: clip does not take the minimum away, Overflow 3 §3.1)
			if(mnv.kind == Style->Lauto && seethrough(ks.overflowx) && seethrough(ks.overflowy)) {
				if(row) {
					(mn, nil) := intrinsic(k);
					minm = mn - mgs(k);
					# no larger than a definite specified size
					if((sw := specw(k, ks.width, mainavail)) >= 0 && sw < minm)
						minm = sw;
				} else {
					if(contenth < 0) {
						k.w = flexcrossw(k, b, cw);
						contenth = contentheightof(l, k, cw);
					}
					minm = contenth;
					if((sh := spech(k, ks.height, maindef)) >= 0 && sh < minm)
						minm = sh;
				}
			}
		}
		if(row && minm < hextra(k))
			minm = hextra(k);
		if(!row && minm < vextra(k))
			minm = vextra(k);
		fi.minm = real minm;
		if(mxv.kind != Style->Lnone)
			fi.maxm = real mainsize(k, mxv, row, maindef);
		fi.hyp = clampr(fi.base, fi.minm, fi.maxm);
	}

	# flex lines (§9.3)
	lines: list of ref Fline;
	st0 := 0;
	used := 0.0;
	for(i = 0; i < n; i++) {
		outer := fa[i].hyp + real fa[i].mm;
		if(i > st0)
			outer += real gapmain;
		if(wrap && i > st0 && mainavail >= 0 && used + outer > real mainavail + 0.5) {
			lines = ref Fline(fa[st0:i], 0, 0) :: lines;
			st0 = i;
			used = fa[i].hyp + real fa[i].mm;
		} else
			used += outer;
	}
	if(n > 0 || lines == nil)
		lines = ref Fline(fa[st0:n], 0, 0) :: lines;
	la := array[len lines] of ref Fline;
	for(i = len la - 1; i >= 0; i--) {
		la[i] = hd lines;
		lines = tl lines;
	}

	# resolve flexible lengths (§9.7), then lay each item out at its size
	usedmain := 0;
	for(i = 0; i < len la; i++) {
		ln := la[i];
		avail := mainavail;
		if(avail < 0) {
			# indefinite (a column with auto height): sizes are hypothetical
			avail = 0;
			for(j := 0; j < len ln.items; j++)
				avail += ir(ln.items[j].hyp) + ln.items[j].mm;
			avail += gapmain * nz(len ln.items - 1);
		}
		resolveflex(ln.items, real (avail - gapmain * nz(len ln.items - 1)));
		cross := 0;
		for(j := 0; j < len ln.items; j++) {
			fi := ln.items[j];
			k := fi.box;
			m := ir(fi.main);
			if(row) {
				k.w = m;
				hch := -1;
				if(ch >= 0 && !wrap)
					hch = ch;
				layblock(l, k, cw, hch, nil, 0, 0);
				fi.cross = k.h + k.mt + k.mb;
			} else {
				k.w = flexcrossw(k, b, cw);
				# a column item's main size is definite for its content
				# only when the container's is (§9.8)
				# ... or when the item cannot flex from a definite basis,
				# which fixes its size as surely
				ks := k.st;
				fixedmain := ks.grow == 0.0 && ks.shrink == 0.0 &&
					(ks.basis.kind == Style->Lpx || ks.basis.kind == Style->Lauto && ks.height.kind == Style->Lpx);
				outer := imposed;
				outerh := imposedh;
				if(ch >= 0 || fixedmain) {
					imposed = k;
					imposedh = m;
				}
				layblock(l, k, cw, m, nil, 0, 0);
				imposed = outer;
				imposedh = outerh;
				k.h = m;
				fi.cross = k.w + k.ml + k.mr;
			}
			if(fi.cross > cross)
				cross = fi.cross;
		}
		# a single line in a definite cross size takes all of it
		if(len la == 1 && !wrap) {
			if(row && ch >= 0)
				cross = ch;
			if(!row)
				cross = cw;
		}
		ln.cross = cross;
		tot := 0;
		for(j = 0; j < len ln.items; j++)
			tot += ir(ln.items[j].main) + ln.items[j].mm;
		tot += gapmain * nz(len ln.items - 1);
		if(tot > usedmain)
			usedmain = tot;
	}

	# the container's cross size
	crosssum := 0;
	for(i = 0; i < len la; i++)
		crosssum += la[i].cross;
	crosssum += gapcross * nz(len la - 1);
	containercross := crosssum;
	if(row && ch >= 0)
		containercross = ch;
	if(row && ch < 0)	# auto height: still bound by min- and max-height
		containercross = clamph(b, crosssum + vextra(b), cbh) - vextra(b);
	if(!row)
		containercross = cw;
	if(len la == 1 && !wrap)	# a single line fills the container (§9.4 step 8)
		la[0].cross = containercross;

	# align-content: distribute extra cross space among lines (§9.4.15)
	ac := st.aligncontent;
	free := containercross - crosssum;
	off := 0;
	between := 0;
	if(len la > 1 || wrap) {
		case ac {
		Style->ALnormal or Style->ALstretch =>
			if(free > 0 && len la > 0) {
				per := free / len la;
				for(i = 0; i < len la; i++)
					la[i].cross += per;
			}
		Style->ALend =>
			off = free;
		Style->ALcenter =>
			off = free/2;
		Style->ALbetween =>
			if(len la > 1)
				between = free / (len la - 1);
		Style->ALaround =>
			between = free / nz1(len la);
			off = between/2;
		Style->ALevenly =>
			between = free / (len la + 1);
			off = between;
		}
		if(between < 0)
			between = 0;
	}
	cpos := off;
	for(i = 0; i < len la; i++) {
		la[i].pos = cpos;
		cpos += la[i].cross + gapcross + between;
	}
	# wrap-reverse: the lines run from the cross end (§5.2); so do
	# they in a column container whose direction is rtl, whose cross
	# start is the right; both at once cancel
	wrapr := st.flexwrap == 2;
	if(free < 0 && (st.safe & 1)) {
		# safe: the lines overflow, so they align to the start and spill
		# past the end edge, whichever way they run (Box Alignment 3 §4.4)
		for(i = 0; i < len la; i++)
			la[i].pos -= off;
		off = 0;
	} else if(wrapr != (!row && st.dirrtl))
		for(i = 0; i < len la; i++)
			la[i].pos = containercross - la[i].pos - la[i].cross;

	# main-axis alignment (§9.5) and cross-axis alignment (§9.6)
	for(i = 0; i < len la; i++) {
		ln := la[i];
		nit := len ln.items;
		space := 0;
		if(row)
			space = cw;
		else if(ch >= 0)
			space = ch;
		else
			space = usedmain;
		used2 := gapmain * nz(nit - 1);
		autos := 0;
		for(j := 0; j < nit; j++) {
			fi := ln.items[j];
			used2 += ir(fi.main) + fi.mm;
			ks := fi.box.st;
			if(row) {
				if(ks.ml.kind == Style->Lauto) autos++;
				if(ks.mr.kind == Style->Lauto) autos++;
			} else {
				if(ks.mt.kind == Style->Lauto) autos++;
				if(ks.mb.kind == Style->Lauto) autos++;
			}
		}
		freem := space - used2;
		start := 0;
		gap := gapmain;
		if(autos > 0 && freem > 0) {
			# auto margins take the free space
			per := freem / autos;
			for(j = 0; j < nit; j++) {
				k := ln.items[j].box;
				ks := k.st;
				if(row) {
					if(ks.ml.kind == Style->Lauto) k.ml = per;
					if(ks.mr.kind == Style->Lauto) k.mr = per;
					ln.items[j].mm = k.ml + k.mr;
				} else {
					if(ks.mt.kind == Style->Lauto) k.mt = per;
					if(ks.mb.kind == Style->Lauto) k.mb = per;
					ln.items[j].mm = k.mt + k.mb;
				}
			}
			freem = 0;
		}
		# Items are placed as if the direction were forward, and a
		# reversed line is then mirrored in its space: that reverses
		# both the order and the justification at once.
		jc := st.justifycontent;
		if(freem < 0 && (st.safe & 2))
			jc = Style->ALstart;	# safe: overflow past the end edge
		case jc {
		Style->ALend or Style->ALright =>
			start = freem;
		Style->ALcenter =>
			start = freem/2;
		Style->ALbetween =>
			if(nit > 1 && freem > 0)
				gap += freem / (nit - 1);
		Style->ALaround =>
			if(freem > 0) {
				gap += freem / nz1(nit);
				start = freem / nz1(nit) / 2;
			}
		Style->ALevenly =>
			if(freem > 0) {
				gap += freem / (nit + 1);
				start = freem / (nit + 1);
			}
		}
		mp := start;
		for(j = 0; j < nit; j++) {
			fi := ln.items[j];
			fi.pos = mp;
			mp += ir(fi.main) + fi.mm + gap;
		}
		if(rev)
			for(j = 0; j < nit; j++) {
				fi := ln.items[j];
				fi.pos = space - fi.pos - ir(fi.main) - fi.mm;
			}
		for(j = 0; j < nit; j++) {
			fi := ln.items[j];
			k := fi.box;
			ks := k.st;
			al := ks.alignself;
			if(al == Style->ALauto)
				al = st.alignitems;
			if(al == Style->ALnormal)
				al = Style->ALstretch;
			if(wrapr) {	# cross-start and cross-end change places too
				if(al == Style->ALstart)
					al = Style->ALend;
				else if(al == Style->ALend)
					al = Style->ALstart;
			}
			lc := ln.cross;
			cpos = 0;
			if(row) {
				if(al == Style->ALstretch && ks.height.kind == Style->Lauto &&
				   ks.mt.kind != Style->Lauto && ks.mb.kind != Style->Lauto) {
					hch := -1;
					if(ch >= 0 && !wrap)
						hch = ch;
					imposeh(l, k, clamph(k, lc - k.mt - k.mb, ch), cw, hch);
				}
				outer := k.h + k.mt + k.mb;
				if(ks.mt.kind == Style->Lauto && ks.mb.kind == Style->Lauto)
					cpos = (lc - outer)/2;
				else if(ks.mt.kind == Style->Lauto)
					cpos = lc - outer;
				else
					cpos = crossoff(al, lc, outer);
				k.x = b.bl + b.pl + fi.pos + k.ml;
				k.y = b.bt + b.pt + ln.pos + cpos + k.mt;
			} else {
				if(al == Style->ALstretch && ks.width.kind == Style->Lauto &&
				   ks.ml.kind != Style->Lauto && ks.mr.kind != Style->Lauto)
					k.w = clampw(k, lc - k.ml - k.mr, cw);
				outer := k.w + k.ml + k.mr;
				if(ks.ml.kind == Style->Lauto && ks.mr.kind == Style->Lauto)
					cpos = (lc - outer)/2;
				else
					cpos = crossoff(al, lc, outer);
				k.x = b.bl + b.pl + ln.pos + cpos + k.ml;
				k.y = b.bt + b.pt + fi.pos + k.mt;
			}
			relative(k, cw, ch);
		}
	}
	# the container's height
	h := sh;
	if(h < 0) {
		if(row)
			h = containercross + vextra(b);
		else
			h = usedmain + vextra(b);
	}
	b.h = clamph(b, h, cbh);
}

crossoff(al, space, outer: int): int
{
	case al {
	Style->ALend or Style->ALright =>
		return space - outer;
	Style->ALcenter =>
		return (space - outer)/2;
	}
	return 0;
}

clampr(v, mn, mx: real): real
{
	if(mx >= 0.0 && v > mx)
		v = mx;
	if(v < mn)
		v = mn;
	return v;
}

# the width of an item in a column flex container: stretched to the
# container, or fit to its content
flexcrossw(k, b: ref Box, cw: int): int
{
	ks := k.st;
	w := specw(k, ks.width, cw);
	if(w >= 0)
		return clampw(k, w, cw);
	al := ks.alignself;
	if(al == Style->ALauto)
		al = b.st.alignitems;
	if(al == Style->ALnormal || al == Style->ALstretch)
		return clampw(k, cw - k.ml - k.mr, cw);
	(mn, mx) := intrinsic(k);
	return clampw(k, fit(mn, mx, cw) - mgs(k), cw);
}

# §9.7: grow or shrink items to fill avail, freezing those that hit a limit
resolveflex(items: array of ref Fi, avail: real)
{
	n := len items;
	if(n == 0)
		return;
	sum := 0.0;
	for(i := 0; i < n; i++)
		sum += items[i].hyp + real items[i].mm;
	grow := sum < avail;
	for(i = 0; i < n; i++) {
		fi := items[i];
		fi.frozen = 0;
		ks := fi.box.st;
		if(grow && ks.grow == 0.0 || !grow && ks.shrink == 0.0 ||
		   grow && fi.base > fi.hyp || !grow && fi.base < fi.hyp) {
			fi.frozen = 1;
			fi.main = fi.hyp;
		} else
			fi.main = fi.base;
	}
	for(iter := 0; iter < n + 2; iter++) {
		free := avail;
		factor := 0.0;
		unfrozen := 0;
		for(i = 0; i < n; i++) {
			fi := items[i];
			if(fi.frozen)
				free -= fi.main + real fi.mm;
			else {
				free -= fi.base + real fi.mm;
				unfrozen++;
				if(grow)
					factor += fi.box.st.grow;
				else
					factor += fi.box.st.shrink * fi.base;
			}
		}
		if(unfrozen == 0)
			break;
		if(grow && factor < 1.0 && factor > 0.0) {
			# flex factors summing to less than 1 take only that share
			f := 0.0;
			for(i = 0; i < n; i++)
				if(!items[i].frozen)
					f += items[i].box.st.grow;
			if(free * f < free)
				free = free * f;
		}
		viol := 0.0;
		for(i = 0; i < n; i++) {
			fi := items[i];
			if(fi.frozen)
				continue;
			t := fi.base;
			if(factor > 0.0) {
				if(grow)
					t += free * fi.box.st.grow / factor;
				else
					t += free * fi.box.st.shrink * fi.base / factor;
			}
			c := clampr(t, fi.minm, fi.maxm);
			if(c < 0.0)
				c = 0.0;
			viol += c - t;
			fi.main = c;
		}
		# freeze the violators of the direction of the total violation
		done := 1;
		for(i = 0; i < n; i++) {
			fi := items[i];
			if(fi.frozen)
				continue;
			t := fi.base;
			if(factor > 0.0) {
				if(grow)
					t += free * fi.box.st.grow / factor;
				else
					t += free * fi.box.st.shrink * fi.base / factor;
			}
			if(viol == 0.0 || viol > 0.0 && fi.main > t || viol < 0.0 && fi.main < t)
				fi.frozen = 1;
			else
				done = 0;
		}
		if(done)
			break;
	}
}

# ---- grid layout (CSS Grid 1) ----

# a track sizing function's two ends
Tfixed, Tpct, Tfr, Tauto, Tmin, Tmax: con iota;

Tsz: adt {
	kind:	int;
	v:	real;		# px, percent or fr
};

Track: adt {
	lo, hi:	Tsz;		# minmax(lo, hi); a plain size has lo == hi
	base:	real;		# the track's size as it is worked out
	limit:	real;		# growth limit (-1: infinite)
};

Gi: adt {
	box:	ref Box;
	r0, r1, c0, c1:	int;	# lines, 0-based: rows r0..r1-1, columns c0..c1-1
};

# the size a track function names, or Tauto if it is not one
tsz(t: ref Tok): (int, Tsz)
{
	case t.kind {
	Css->Kdimension =>
		if(t.s == "fr")
			return (1, Tsz(Tfr, t.n));
		if(t.s == "px")
			return (1, Tsz(Tfixed, t.n));
	Css->Kpercent =>
		return (1, Tsz(Tpct, t.n));
	Css->Knumber =>
		if(t.n == 0.0)
			return (1, Tsz(Tfixed, 0.0));
	Css->Kident =>
		case lower(t.s) {
		"auto" => return (1, Tsz(Tauto, 0.0));
		"min-content" => return (1, Tsz(Tmin, 0.0));
		"max-content" => return (1, Tsz(Tmax, 0.0));
		}
	}
	return (0, Tsz(Tauto, 0.0));
}

# one track from a token: a size, minmax() or fit-content()
track(t: ref Tok): ref Track
{
	if(t.kind == Css->Kfunction) {
		a := commas(t.kids);
		case t.s {
		"minmax" =>
			if(len a != 2)
				return nil;
			x := nows(hd a);
			y := nows(hd tl a);
			if(len x != 1 || len y != 1)
				return nil;
			(ok1, lo) := tsz(x[0]);
			(ok2, hi) := tsz(y[0]);
			if(!ok1 || !ok2)
				return nil;
			if(lo.kind == Tfr)
				lo = Tsz(Tauto, 0.0);
			return ref Track(lo, hi, 0.0, 0.0);
		"fit-content" =>
			x := nows(t.kids);
			if(len x != 1)
				return nil;
			(ok, hi) := tsz(x[0]);
			if(!ok)
				return nil;
			return ref Track(Tsz(Tauto, 0.0), hi, 0.0, 0.0);
		}
		return nil;
	}
	(ok, sz) := tsz(t);
	if(!ok)
		return nil;
	lo := sz;
	if(sz.kind == Tfr)
		lo = Tsz(Tauto, 0.0);	# 1fr is minmax(auto, 1fr)
	return ref Track(lo, sz, 0.0, 0.0);
}

# A track list, with repeat() expanded (auto-fill/auto-fit against
# avail) and line names collected: names[i] are the names of line i.
tracks(v: array of ref Tok, avail, gap: int): (array of ref Track, array of list of string)
{
	tlist: list of ref Track;
	names: list of (int, string);
	nt := 0;
	for(i := 0; i < len v; i++) {
		t := v[i];
		case t.kind {
		Css->Kws =>
			continue;
		Css->Kblock =>
			if(t.s == "[")
				for(k := 0; k < len t.kids; k++)
					if(t.kids[k].kind == Css->Kident)
						names = (nt, t.kids[k].s) :: names;
			continue;
		Css->Kfunction =>
			if(t.s == "repeat") {
				a := commas(t.kids);
				if(len a < 2)
					continue;
				cnt := nows(hd a);
				if(len cnt != 1)
					continue;
				rest := tl a;
				# the repeated part is everything after the first comma
				x := array[0] of ref Tok;
				for(r := rest; r != nil; r = tl r) {
					if(len x > 0) {
						y := array[len x + 1 + len hd r] of ref Tok;
						y[0:] = x;
						y[len x] = ref Tok(Css->Kcomma, ",", 0.0, 0, nil);
						y[len x + 1:] = hd r;
						x = y;
					} else
						x = hd r;
				}
				(rt, rn) := tracks(x, -1, gap);
				if(len rt == 0)
					continue;
				reps := 1;
				if(cnt[0].kind == Css->Knumber) {
					reps = int cnt[0].n;
					if(reps < 1)
						reps = 1;
					if(reps * len rt > MAXTRACKS)
						reps = MAXTRACKS / len rt;
				} else if(cnt[0].kind == Css->Kident) {
					# auto-fill, auto-fit: as many as fit
					per := 0.0;
					for(k := 0; k < len rt; k++) {
						sz := rt[k].hi;
						if(sz.kind != Tfixed && sz.kind != Tpct)
							sz = rt[k].lo;
						case sz.kind {
						Tfixed => per += sz.v;
						Tpct => per += sz.v * real avail / 100.0;
						}
					}
					per += real (gap * len rt);
					reps = 1;
					if(avail > 0 && per > 0.0)
						reps = int ((real avail + real gap) / per - 0.4999);
					if(reps < 1)
						reps = 1;
				}
				for(k := 0; k < reps; k++) {
					for(m := 0; m < len rt; m++) {
						for(nl := rn[m]; nl != nil; nl = tl nl)
							names = (nt, hd nl) :: names;
						tlist = ref *rt[m] :: tlist;
						nt++;
					}
				}
				if(len rn > len rt)
					for(nl := rn[len rt]; nl != nil; nl = tl nl)
						names = (nt, hd nl) :: names;
				continue;
			}
		}
		tr := track(t);
		if(tr != nil) {
			tlist = tr :: tlist;
			nt++;
		}
	}
	a := array[nt] of ref Track;
	for(i = nt - 1; i >= 0; i--) {
		a[i] = hd tlist;
		tlist = tl tlist;
	}
	n := array[nt + 1] of list of string;
	for(; names != nil; names = tl names) {
		(at, nm) := hd names;
		if(at <= nt)
			n[at] = nm :: n[at];
	}
	return (a, n);
}

# the line a Gline names, 0-based, given the explicit grid's line names;
# -1 if auto
lineof(g: Style->Gline, names: array of list of string, ntracks: int, end: int): int
{
	if(g.name != nil && g.n == 0 && !g.span) {
		suffix := "-start";
		if(end)
			suffix = "-end";
		for(i := 0; i < len names; i++)
			for(l := names[i]; l != nil; l = tl l)
				if(hd l == g.name || hd l == g.name + suffix)
					return i;
		return -1;
	}
	if(g.span || g.n == 0)
		return -1;
	if(g.n > 0) {
		if(g.n > MAXTRACKS)
			return MAXTRACKS - 1;
		return g.n - 1;
	}
	n := ntracks + 1 + g.n;	# -1 is the last line
	if(n < 0)
		n = 0;
	return n;
}

# named areas as lines: (name, r0, r1, c0, c1)
areas(rows: array of string): list of (string, int, int, int, int)
{
	r: list of (string, int, int, int, int);
	for(i := 0; i < len rows; i++) {
		(nil, cells) := sys->tokenize(rows[i], " \t\n");
		j := 0;
		for(; cells != nil; cells = tl cells) {
			nm := hd cells;
			if(nm != "." && nm[0] != '.') {
				found := 0;
				nr: list of (string, int, int, int, int);
				for(a := r; a != nil; a = tl a) {
					(an, r0, r1, c0, c1) := hd a;
					if(an == nm) {
						found = 1;
						if(i+1 > r1) r1 = i+1;
						if(j+1 > c1) c1 = j+1;
						if(i < r0) r0 = i;
						if(j < c0) c0 = j;
					}
					nr = (an, r0, r1, c0, c1) :: nr;
				}
				r = nr;
				if(!found)
					r = (nm, i, i+1, j, j+1) :: r;
			}
			j++;
		}
	}
	return r;
}

laygrid(l: ref L, b: ref Box, cbw, cbh: int)
{
	st := b.st;
	cw := b.w - hextra(b);
	if(cw < 0)
		cw = 0;
	sh := specheight(b, cbh);
	ch := -1;
	if(sh >= 0)
		ch = clamph(b, sh, cbh) - vextra(b);
	colgap := 0;
	rowgap := 0;
	if(st.colgap.kind != Style->Lnormal)
		colgap = res(st.colgap, cw);
	if(st.rowgap.kind != Style->Lnormal)
		rowgap = res(st.rowgap, nz(ch));
	(cols, colnames) := tracks(st.gridcols, cw, colgap);
	(rows, rownames) := tracks(st.gridrows, ch, rowgap);
	ars := areas(st.gridareas);
	for(a := ars; a != nil; a = tl a) {
		(nil, nil, r1, nil, c1) := hd a;
		if(c1 > len cols)
			cols = growtracks(cols, c1, st.autocols, cw);
		if(r1 > len rows)
			rows = growtracks(rows, r1, st.autorows, ch);
	}
	ncols := len cols;
	if(ncols == 0)
		ncols = 1;
	nrows := len rows;
	if(nrows == 0)
		nrows = 1;

	# placement
	gi: list of ref Gi;
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k)) {
			l.pending = ref Abs(k, cbof(l, k), b, b.bl + b.pl, b.bt + b.pt, nil, 0) :: l.pending;
			continue;
		}
		ks := k.st;
		g := ref Gi(k, -1, -1, -1, -1);
		if(ks.gridarea != nil) {
			for(a = ars; a != nil; a = tl a) {
				(an, r0, r1, c0, c1) := hd a;
				if(an == ks.gridarea) {
					(g.r0, g.r1, g.c0, g.c1) = (r0, r1, c0, c1);
					break;
				}
			}
		}
		if(g.r0 < 0) {
			(g.c0, g.c1) = gridspan(ks.colstart, ks.colend, colnames, len cols, ars, 1);
			(g.r0, g.r1) = gridspan(ks.rowstart, ks.rowend, rownames, len rows, ars, 0);
		}
		gi = g :: gi;
	}
	items := array[len gi] of ref Gi;
	for(i = len items - 1; i >= 0; i--) {
		items[i] = hd gi;
		gi = tl gi;
	}
	colflow := st.autoflow & 1;
	dense := st.autoflow & 2;
	# The implicit grid grows to hold definite placements, and, in the
	# axis items flow across, the largest span of an item placed
	# automatically in it (§8.5 step 1): otherwise it could never fit.
	for(i = 0; i < len items; i++) {
		g := items[i];
		if(g.c1 > ncols)
			ncols = g.c1;
		if(g.r1 > nrows)
			nrows = g.r1;
		if(!colflow && g.c0 < 0) {
			cs := spanof(g.c0, g.c1, g.box.st.colstart, g.box.st.colend);
			if(cs > ncols)
				ncols = cs;
		}
		if(colflow && g.r0 < 0) {
			rs := spanof(g.r0, g.r1, g.box.st.rowstart, g.box.st.rowend);
			if(rs > nrows)
				nrows = rs;
		}
	}
	occ := ref Occ(array[0] of array of byte, ncols);
	# 1: definite in both
	for(i = 0; i < len items; i++) {
		g := items[i];
		if(g.r0 >= 0 && g.c0 >= 0)
			occ.mark(g.r0, g.r1, g.c0, g.c1);
	}
	# 2: definite in one axis, then 3: fully automatic
	cr := 0;
	cc := 0;
	for(i = 0; i < len items; i++) {
		g := items[i];
		if(g.r0 >= 0 && g.c0 >= 0)
			continue;
		rs := spanof(g.r0, g.r1, items[i].box.st.rowstart, items[i].box.st.rowend);
		cs := spanof(g.c0, g.c1, items[i].box.st.colstart, items[i].box.st.colend);
		if(cs > ncols && !colflow)
			cs = ncols;
		if(rs > nrows && colflow)
			rs = nrows;
		if(colflow) {
			# column-major: transpose the search
			if(g.c0 < 0) {
				c := cc;
				r := cr;
				if(dense) {
					c = 0;
					r = 0;
				}
				for(;; ) {
					if(g.r0 >= 0)
						r = g.r0;
					if(r + rs > nrows && g.r0 < 0) {
						r = 0;
						c++;
						continue;
					}
					if(occ.free(r, r + rs, c, c + cs))
						break;
					r++;
					if(g.r0 >= 0) {
						c++;
						r = g.r0;
					}
				}
				g.c0 = c;
				g.c1 = c + cs;
				if(g.r0 < 0) {
					g.r0 = r;
					g.r1 = r + rs;
				}
				cc = g.c0;
				cr = g.r1;
			} else {
				r := 0;
				while(!occ.free(r, r + rs, g.c0, g.c1))
					r++;
				g.r0 = r;
				g.r1 = r + rs;
			}
		} else {
			if(g.r0 < 0) {
				r := cr;
				c := cc;
				if(dense) {
					r = 0;
					c = 0;
				} else if(g.c0 >= 0 && g.c0 < cc)
					r++;	# a definite column before the cursor: the next row (§8.5 step 3)
				for(;;) {
					if(g.c0 >= 0)
						c = g.c0;
					if(c + cs > ncols) {
						c = 0;
						r++;
						continue;
					}
					if(occ.free(r, r + rs, c, c + cs))
						break;
					if(g.c0 >= 0) {
						r++;
						continue;
					}
					c++;
				}
				if(g.c0 < 0) {
					g.c0 = c;
					g.c1 = c + cs;
				}
				g.r0 = r;
				g.r1 = r + rs;
				cr = g.r0;
				cc = g.c1;
			} else {
				r := 0;
				while(!occ.free(r, r + rs, g.c0, g.c1))
					r++;
				g.r0 = r;
				g.r1 = r + rs;
			}
		}
		if(g.c1 > ncols)
			ncols = g.c1;
		occ.mark(g.r0, g.r1, g.c0, g.c1);
	}
	nrows = len rows;
	for(i = 0; i < len items; i++)
		if(items[i].r1 > nrows)
			nrows = items[i].r1;
	cols = growtracks(cols, ncols, st.autocols, cw);
	rows = growtracks(rows, nrows, st.autorows, ch);

	# column sizes, then rows (laying items out at their column widths)
	sizetracks(cols, items, 1, cw, colgap, b);
	cpos := trackpos(cols, colgap, cw, st.justifycontent);
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		edges(k, areaw(cols, cpos, g.c0, g.c1, colgap));
	}
	# items' heights at their widths
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		aw := areaw(cols, cpos, g.c0, g.c1, colgap);
		k.w = gridw(k, aw, b);
		layblock(l, k, aw, -1, nil, 0, 0);
	}
	sizetracks(rows, items, 0, ch, rowgap, b);
	gh := 0;
	for(i = 0; i < len rows; i++)
		gh += ir(rows[i].base);
	gh += rowgap * nz(len rows - 1);
	avh := ch;
	if(avh < 0)
		avh = gh;
	rpos := trackpos(rows, rowgap, avh, st.aligncontent);

	# place each item in its area, aligned
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		ks := k.st;
		ax := cpos[g.c0];
		aw := areaw(cols, cpos, g.c0, g.c1, colgap);
		ay := rpos[g.r0];
		ah := trackend(rows, rpos, g.r1 - 1, rowgap) - ay;
		js := ks.justifyself;
		if(js == Style->ALauto)
			js = st.justifyitems;
		as := ks.alignself;
		if(as == Style->ALauto)
			as = st.alignitems;
		if((as == Style->ALnormal || as == Style->ALstretch) && ks.height.kind == Style->Lauto &&
		   ks.mt.kind != Style->Lauto && ks.mb.kind != Style->Lauto && k.kind != Kreplaced) {
			imposeh(l, k, clamph(k, ah - k.mt - k.mb, ah), aw, ah);
		} else if(ks.height.pct != 0.0 || ks.minheight.pct != 0.0 || ks.maxheight.pct != 0.0 || heightmatters(k)) {
			# the area's height is definite for it (Grid 2 §6.6)
			layblock(l, k, aw, ah, nil, 0, 0);
		}
		x := ax + k.ml + crossoff(js, aw, k.w + k.ml + k.mr);
		if(ks.ml.kind == Style->Lauto && ks.mr.kind == Style->Lauto)
			x = ax + (aw - k.w)/2;
		y := ay + k.mt + crossoff(as, ah, k.h + k.mt + k.mb);
		if(ks.mt.kind == Style->Lauto && ks.mb.kind == Style->Lauto)
			y = ay + (ah - k.h)/2;
		k.x = b.bl + b.pl + x;
		k.y = b.bt + b.pt + y;
		relative(k, aw, ah);
	}
	h := sh;
	if(h < 0)
		h = gh + vextra(b);
	b.h = clamph(b, h, cbh);
}

Occ: adt {
	rows:	array of array of byte;
	ncols:	int;
	free:	fn(o: self ref Occ, r0, r1, c0, c1: int): int;
	mark:	fn(o: self ref Occ, r0, r1, c0, c1: int);
};

Occ.free(o: self ref Occ, r0, r1, c0, c1: int): int
{
	for(r := r0; r < r1 && r < len o.rows; r++)
		for(c := c0; c < c1; c++)
			if(c < len o.rows[r] && o.rows[r][c] != byte 0)
				return 0;
	return 1;
}

Occ.mark(o: self ref Occ, r0, r1, c0, c1: int)
{
	if(r1 > len o.rows) {
		a := array[r1] of array of byte;
		a[0:] = o.rows;
		for(i := len o.rows; i < r1; i++)
			a[i] = array[0] of byte;
		o.rows = a;
	}
	for(r := r0; r < r1; r++) {
		if(c1 > len o.rows[r]) {
			a := array[c1] of {* => byte 0};
			a[0:] = o.rows[r];
			o.rows[r] = a;
		}
		for(c := c0; c < c1; c++)
			o.rows[r][c] = byte 1;
	}
}

# lines (start, end) for one axis; (-1, -1) when automatic
gridspan(s, e: Style->Gline, names: array of list of string, ntracks: int, ars: list of (string, int, int, int, int), cols: int): (int, int)
{
	a := lineof(s, names, ntracks, 0);
	b := lineof(e, names, ntracks, 1);
	# a name that is an area names its edge lines
	if(s.name != nil && a < 0)
		for(l := ars; l != nil; l = tl l) {
			(an, r0, nil, c0, nil) := hd l;
			if(an == s.name) {
				a = r0;
				if(cols)
					a = c0;
			}
		}
	if(e.name != nil && b < 0)
		for(m := ars; m != nil; m = tl m) {
			(an, nil, r1, nil, c1) := hd m;
			if(an == e.name) {
				b = r1;
				if(cols)
					b = c1;
			}
		}
	if(a >= 0 && b >= 0) {
		if(b < a)
			(a, b) = (b, a);
		if(b == a)
			b = a + 1;
		return (a, b);
	}
	if(a >= 0) {
		n := 1;
		if(e.span)
			n = clampspan(e.span);
		return (a, a + n);
	}
	if(b >= 0) {
		n := 1;
		if(s.span)
			n = clampspan(s.span);
		if(b - n < 0)
			return (0, n);
		return (b - n, b);
	}
	return (-1, -1);
}

spanof(a0, a1: int, s, e: Style->Gline): int
{
	if(a0 >= 0)
		return a1 - a0;
	n := 1;
	if(s.span)
		n = s.span;
	if(e.span)
		n = e.span;
	return clampspan(n);
}

# A grid has at most this many lines in an axis (as in other engines):
# a style sheet's "grid-column: 2000000000" or "repeat(1e9, 1px)" must
# not be an allocation.
MAXTRACKS: con 10000;

clampspan(n: int): int
{
	if(n < 1)
		return 1;
	if(n > MAXTRACKS)
		return MAXTRACKS;
	return n;
}

# make tracks n long, the new ones from the implicit track sizes
growtracks(t: array of ref Track, n: int, auto: array of ref Tok, avail: int): array of ref Track
{
	if(n <= len t)
		return t;
	(at, nil) := tracks(auto, avail, 0);
	r := array[n] of ref Track;
	r[0:] = t;
	for(i := len t; i < n; i++) {
		if(len at > 0)
			r[i] = ref *at[(i - len t) % len at];
		else
			r[i] = ref Track(Tsz(Tauto, 0.0), Tsz(Tauto, 0.0), 0.0, 0.0);
	}
	return r;
}

# The track sizing algorithm (§11), much simplified: fixed sizes; content
# sizes from items spanning one track, then spanning items spread over
# the intrinsic tracks they cross; leftover space to fr tracks, else to
# auto tracks.
sizetracks(t: array of ref Track, items: array of ref Gi, cols: int, avail, gap: int, b: ref Box)
{
	n := len t;
	if(n == 0)
		return;
	for(i := 0; i < n; i++) {
		tr := t[i];
		tr.base = 0.0;
		tr.limit = -1.0;
		# a percentage of an indefinite size is auto (Grid §7.2.3)
		if(avail < 0 && tr.lo.kind == Tpct)
			tr.lo = Tsz(Tauto, 0.0);
		if(avail < 0 && tr.hi.kind == Tpct)
			tr.hi = Tsz(Tauto, 0.0);
		case tr.lo.kind {
		Tfixed => tr.base = tr.lo.v;
		Tpct => tr.base = tr.lo.v * real avail / 100.0;
		}
		case tr.hi.kind {
		Tfixed => tr.limit = tr.hi.v;
		Tpct => tr.limit = tr.hi.v * real avail / 100.0;
		}
		if(tr.limit >= 0.0 && tr.limit < tr.base)
			tr.limit = tr.base;
	}
	# content contributions, single-span items first
	for(pass := 1; pass <= 2; pass++)
		for(i = 0; i < len items; i++) {
			g := items[i];
			a0 := g.c0;
			a1 := g.c1;
			if(!cols) {
				a0 = g.r0;
				a1 = g.r1;
			}
			nspan := a1 - a0;
			if(pass == 1 && nspan != 1 || pass == 2 && nspan == 1)
				continue;
			k := g.box;
			mn, mx: int;
			if(cols)
				(mn, mx) = contribution(k);
			else {
				mn = k.h + k.mt + k.mb;
				mx = mn;
			}
			# what the spanned tracks already provide
			have := 0.0;
			nintr := 0;
			hasfr := 0;
			for(j := a0; j < a1 && j < n; j++) {
				have += t[j].base;
				if(t[j].hi.kind == Tfr)
					hasfr = 1;
				if(intrinsiclo(t[j]))
					nintr++;
			}
			have += real (gap * (nspan - 1));
			if(pass == 2 && hasfr)
				continue;	# spanning fr tracks: left to the fr step
			need := real mn - have;
			if(need > 0.0 && nintr > 0) {
				per := need / real nintr;
				for(j = a0; j < a1 && j < n; j++)
					if(intrinsiclo(t[j]))
						t[j].base += per;
			}
			# growth limits for auto and max-content tracks
			if(nspan == 1 && a0 < n) {
				tr := t[a0];
				if(tr.hi.kind == Tauto || tr.hi.kind == Tmax) {
					lim := real mx;
					if(tr.limit < lim)
						tr.limit = lim;
				}
				if(tr.hi.kind == Tmin && tr.limit < real mn)
					tr.limit = real mn;
			}
		}
	for(i = 0; i < n; i++)
		if(t[i].limit >= 0.0 && t[i].limit < t[i].base)
			t[i].limit = t[i].base;
	# free space
	used := real (gap * (n - 1));
	for(i = 0; i < n; i++)
		used += t[i].base;
	if(avail < 0) {
		# indefinite: intrinsic tracks grow to their limits; fr as max-content
		for(i = 0; i < n; i++)
			if(t[i].limit > t[i].base)
				t[i].base = t[i].limit;
		return;
	}
	free := real avail - used;
	# grow tracks with a finite limit toward it
	if(free > 0.0) {
		want := 0.0;
		for(i = 0; i < n; i++)
			if(t[i].hi.kind != Tfr && t[i].limit > t[i].base)
				want += t[i].limit - t[i].base;
		if(want > 0.0) {
			f := 1.0;
			if(want > free)
				f = free / want;
			for(i = 0; i < n; i++)
				if(t[i].hi.kind != Tfr && t[i].limit > t[i].base) {
					d := (t[i].limit - t[i].base) * f;
					t[i].base += d;
					free -= d;
				}
		}
	}
	# fr tracks share what is left (§11.7), never below their base
	sumfr := 0.0;
	for(i = 0; i < n; i++)
		if(t[i].hi.kind == Tfr)
			sumfr += t[i].hi.v;
	if(sumfr > 0.0) {
		left := free;
		for(i = 0; i < n; i++)
			if(t[i].hi.kind == Tfr)
				left += t[i].base;
		inflex := array[n] of {* => 0};
		for(iter := 0; iter < n; iter++) {
			fs := 0.0;
			sp := left;
			for(i = 0; i < n; i++)
				if(t[i].hi.kind == Tfr && !inflex[i])
					fs += t[i].hi.v;
				else if(t[i].hi.kind == Tfr)
					sp -= t[i].base;
			if(fs <= 0.0)
				break;
			unit := sp / maxr(fs, 1.0);
			changed := 0;
			for(i = 0; i < n; i++)
				if(t[i].hi.kind == Tfr && !inflex[i] && unit * t[i].hi.v < t[i].base) {
					inflex[i] = 1;
					changed = 1;
				}
			if(changed)
				continue;
			for(i = 0; i < n; i++)
				if(t[i].hi.kind == Tfr && !inflex[i])
					t[i].base = unit * t[i].hi.v;
			break;
		}
		return;
	}
	# else stretch auto tracks
	if(free > 0.0) {
		na := 0;
		for(i = 0; i < n; i++)
			if(t[i].hi.kind == Tauto)
				na++;
		if(na > 0)
			for(i = 0; i < n; i++)
				if(t[i].hi.kind == Tauto)
					t[i].base += free / real na;
	}
}

maxr(a, b: real): real
{
	if(a > b)
		return a;
	return b;
}

intrinsiclo(t: ref Track): int
{
	return t.lo.kind == Tauto || t.lo.kind == Tmin || t.lo.kind == Tmax;
}

# track start positions, with justify/align-content distribution
trackpos(t: array of ref Track, gap, avail, align: int): array of int
{
	n := len t;
	pos := array[n + 1] of int;
	used := gap * nz(n - 1);
	for(i := 0; i < n; i++)
		used += ir(t[i].base);
	free := avail - used;
	start := 0;
	extra := 0;
	if(free > 0)
		case align {
		Style->ALend or Style->ALright =>
			start = free;
		Style->ALcenter =>
			start = free/2;
		Style->ALbetween =>
			if(n > 1)
				extra = free / (n - 1);
		Style->ALaround =>
			extra = free / nz1(n);
			start = extra/2;
		Style->ALevenly =>
			extra = free / (n + 1);
			start = extra;
		}
	# accumulate in reals and round each edge, so fractional tracks
	# tile without gaps
	p := real start;
	for(i = 0; i < n; i++) {
		pos[i] = ir(p);
		p += t[i].base + real (gap + extra);
	}
	pos[n] = ir(p) - gap - extra;
	return pos;
}

areaw(t: array of ref Track, pos: array of int, a0, a1, gap: int): int
{
	if(a0 < 0 || a1 > len t || a1 <= a0)
		return 0;
	return trackend(t, pos, a1 - 1, gap) - pos[a0];
}

# where track i ends: the next track's start less the gap, so rounded
# tracks meet exactly
trackend(t: array of ref Track, pos: array of int, i, gap: int): int
{
	if(i + 1 < len t)
		return pos[i+1] - gap;
	return pos[i] + ir(t[i].base);
}

gridw(k: ref Box, aw: int, b: ref Box): int
{
	ks := k.st;
	w := specw(k, ks.width, aw);
	if(w >= 0)
		return clampw(k, w, aw);
	js := ks.justifyself;
	if(js == Style->ALauto)
		js = b.st.justifyitems;
	if((js == Style->ALnormal || js == Style->ALstretch) && ks.ml.kind != Style->Lauto && ks.mr.kind != Style->Lauto && k.kind != Kreplaced)
		return clampw(k, aw - k.ml - k.mr, aw);
	if(k.kind == Kreplaced) {
		(rw, nil) := replacedsize(k, aw, -1);
		return clampw(k, rw + hextra(k), aw);
	}
	(mn, mx) := intrinsic(k);
	return clampw(k, fit(mn, mx, aw) - mgs(k), aw);
}

# the height of a box's content (its last line or lowest child), with
# its bottom padding and border, whatever height it was given
contentheight(k: ref Box): int
{
	h := 0;
	if(len k.lines > 0) {
		ln := k.lines[len k.lines - 1];
		h = ln.y + ln.h;
	}
	for(i := 0; i < len k.kids; i++) {
		c := k.kids[i];
		if(c.inl || isabs(c) || c.kind == Ktext)
			continue;
		if(c.y + c.h + c.mb > h)
			h = c.y + c.h + c.mb;
	}
	return h + k.pb + k.bb;
}

# ---- tables (CSS 2.2 §17) ----

Tcell: adt {
	box:	ref Box;
	row:	ref Box;
	r, c:	int;		# first row and column
	rs, cs:	int;		# spans
};

Tgrid: adt {
	rows:	array of ref Box;	# row boxes, in display order
	groups:	array of ref Box;	# each row's group (nil if directly in the table)
	cells:	list of ref Tcell;
	ncols:	int;
	captions:	list of ref Box;
	colw:	array of int;	# widths from <col>/<colgroup>, 0 if none
};

isrowgroup(k: ref Box): int
{
	case k.st.display {
	Style->Dtablerowgroup or Style->Dtableheadergroup or Style->Dtablefootergroup =>
		return 1;
	}
	return 0;
}

iscolumn(k: ref Box): int
{
	return k.st.display == Style->Dtablecolumn || k.st.display == Style->Dtablecolumngroup;
}

# The table's grid: rows in header, body, footer order; cells with their
# slots, rowspans reserving slots below.
tgrid(d: ref Doc, b: ref Box): ref Tgrid
{
	head, body, foot: list of (ref Box, ref Box);	# (row, group), reversed
	caps: list of ref Box;
	cols: list of ref Box;
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(k.st.display == Style->Dtablecaption) {
			caps = k :: caps;
			continue;
		}
		if(iscolumn(k)) {
			cols = k :: cols;
			continue;
		}
		if(isrowgroup(k)) {
			rl: list of (ref Box, ref Box);
			for(j := 0; j < len k.kids; j++)
				if(k.kids[j].kind == Krow)
					rl = (k.kids[j], k) :: rl;
			case k.st.display {
			Style->Dtableheadergroup =>
				for(rr := rev2(rl); rr != nil; rr = tl rr)
					head = hd rr :: head;
			Style->Dtablefootergroup =>
				for(rr := rev2(rl); rr != nil; rr = tl rr)
					foot = hd rr :: foot;
			* =>
				for(rr := rev2(rl); rr != nil; rr = tl rr)
					body = hd rr :: body;
			}
		} else if(k.kind == Krow)
			body = (k, nil) :: body;
	}
	all := rev2(head);
	for(bl := rev2(body); bl != nil; bl = tl bl)
		all = hd bl :: all;
	for(fl := rev2(foot); fl != nil; fl = tl fl)
		all = hd fl :: all;
	all = rev2(all);
	t := ref Tgrid(array[len all] of ref Box, array[len all] of ref Box, nil, 0, rev(caps), nil);
	i = 0;
	for(; all != nil; all = tl all) {
		(t.rows[i], t.groups[i]) = hd all;
		i++;
	}
	# slots: occupied[r] is a list of taken columns
	taken := array[len t.rows] of list of int;
	for(r := 0; r < len t.rows; r++) {
		row := t.rows[r];
		c := 0;
		for(j := 0; j < len row.kids; j++) {
			cell := row.kids[j];
			if(cell.kind != Kcell && cell.inl)
				continue;
			while(intlist(taken[r], c))
				c++;
			cs := 1;
			rs := 1;
			if(cell.node != 0 && d != nil) {
				cs = spanattr(d.attr(cell.node, "colspan"), 1000);
				rs = spanattr(d.attr(cell.node, "rowspan"), 65534);
				if(d.attr(cell.node, "rowspan") == "0")
					rs = len t.rows - r;
			}
			if(r + rs > len t.rows)
				rs = len t.rows - r;
			for(rr := r; rr < r + rs; rr++)
				for(cc := c; cc < c + cs; cc++)
					taken[rr] = cc :: taken[rr];
			t.cells = ref Tcell(cell, row, r, c, rs, cs) :: t.cells;
			c += cs;
			if(c > t.ncols)
				t.ncols = c;
		}
	}
	# column widths from <col> and <colgroup>
	t.colw = array[t.ncols] of {* => 0};
	c := 0;
	for(cl := rev(cols); cl != nil; cl = tl cl) {
		k := hd cl;
		n := 1;
		if(k.node != 0 && d != nil)
			n = spanattr(d.attr(k.node, "span"), 1000);
		w := 0;
		if(k.st.width.kind == Style->Lpx && k.st.width.pct == 0.0)
			w = ir(k.st.width.px);
		for(m := 0; m < n && c < t.ncols; m++)
			t.colw[c++] = w;
	}
	return t;
}

rev2(l: list of (ref Box, ref Box)): list of (ref Box, ref Box)
{
	r: list of (ref Box, ref Box);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

intlist(l: list of int, v: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == v)
			return 1;
	return 0;
}

spanattr(s: string, max: int): int
{
	v := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		v = v*10 + s[i] - '0';
	if(v < 1)
		return 1;
	if(v > max)
		return max;
	return v;
}

# column (min, max) widths, and percentages (-1 if none)
tcolumns(t: ref Tgrid, tw: int): (array of int, array of int, array of real, array of int)
{
	n := t.ncols;
	mn := array[n] of {* => 0};
	mx := array[n] of {* => 0};
	pct := array[n] of {* => -1.0};
	fixw := array[n] of {* => 0};	# has a specified width
	for(i := 0; i < n; i++)
		if(t.colw[i] > 0) {
			mn[i] = mx[i] = t.colw[i];
			fixw[i] = 1;
		}
	# single-column cells first, then spanning ones spread their excess
	for(pass := 1; pass <= 2; pass++)
		for(cl := t.cells; cl != nil; cl = tl cl) {
			c := hd cl;
			if((pass == 1) != (c.cs == 1))
				continue;
			k := c.box;
			edges(k, tw);
			(cmn, cmx) := contribution(k);
			ks := k.st;
			if(ks.width.kind == Style->Lpx && ks.width.pct != 0.0 && ks.width.px == 0.0) {
				if(c.cs == 1 && ks.width.pct > pct[c.c])
					pct[c.c] = ks.width.pct;
			} else if(ks.width.kind == Style->Lpx && ks.width.pct == 0.0) {
				w := ir(ks.width.px);
				if(!ks.borderbox)
					w += hextra(k);
				if(w > cmn)
					cmx = cmn = w;
				else
					cmx = cmn;
				if(c.cs == 1)
					fixw[c.c] = 1;
			}
			if(c.cs == 1) {
				if(cmn > mn[c.c])
					mn[c.c] = cmn;
				if(cmx > mx[c.c])
					mx[c.c] = cmx;
				continue;
			}
			# spanning: grow the spanned columns in proportion to their max
			smn := 0;
			smx := 0;
			for(j := c.c; j < c.c + c.cs; j++) {
				smn += mn[j];
				smx += mx[j];
			}
			if(cmn > smn)
				spread(mn, c.c, c.cs, cmn - smn, mx);
			if(cmx > smx)
				spread(mx, c.c, c.cs, cmx - smx, mx);
		}
	for(i = 0; i < n; i++)
		if(mx[i] < mn[i])
			mx[i] = mn[i];
	return (mn, mx, pct, fixw);
}

spread(a: array of int, c0, n, extra: int, weights: array of int)
{
	tot := 0;
	for(j := c0; j < c0 + n; j++)
		tot += weights[j];
	given := 0;
	for(j = c0; j < c0 + n; j++) {
		d := extra / n;
		if(tot > 0)
			d = extra * weights[j] / tot;
		if(j == c0 + n - 1)
			d = extra - given;
		a[j] += d;
		given += d;
	}
}

tspacing(b: ref Box): (int, int)
{
	if(b.st.collapse)
		return (0, 0);
	return (ir(b.st.spacingx), ir(b.st.spacingy));
}

# the table's intrinsic (min, max) border-box widths
tableintrinsic(b: ref Box): (int, int)
{
	t := tgrid(curdoc, b);
	(mn, mx, nil, nil) := tcolumns(t, 0);
	(sx, nil) := tspacing(b);
	smn := sx * (t.ncols + 1);
	smx := smn;
	for(i := 0; i < t.ncols; i++) {
		smn += mn[i];
		smx += mx[i];
	}
	for(cl := t.captions; cl != nil; cl = tl cl) {
		(cmn, nil) := contribution(hd cl);
		if(cmn > smn)
			smn = cmn;
	}
	return (smn + hextra(b), smx + hextra(b));
}

laytable(l: ref L, b: ref Box, cbw, cbh: int)
{
	st := b.st;
	t := tgrid(curdoc, b);
	n := t.ncols;
	(sx, sy) := tspacing(b);
	cw := b.w - hextra(b);	# the width the table's grid gets
	(mn, mx, pct, fixw) := tcolumns(t, cw);
	summn := sx * (n + 1);
	summx := summn;
	for(i := 0; i < n; i++) {
		summn += mn[i];
		summx += mx[i];
	}
	autow := st.width.kind == Style->Lauto;
	if(autow) {
		# shrink to fit, between min and the available width
		w := summx;
		if(w > cw)
			w = cw;
		if(w < summn)
			w = summn;
		cw = w;
	} else if(cw < summn)
		cw = summn;
	b.w = cw + hextra(b);
	# column widths
	colw := array[n] of int;
	avail := cw - sx * (n + 1);
	if(st.tablefixed && !autow) {
		# fixw layout: specified widths, the rest shared equally
		fixedw := 0;
		nfree := 0;
		for(i = 0; i < n; i++) {
			if(t.colw[i] > 0)
				colw[i] = t.colw[i];
			else if(pct[i] >= 0.0)
				colw[i] = ir(pct[i] * real avail / 100.0);
			else
				colw[i] = -1;
			if(colw[i] >= 0)
				fixedw += colw[i];
			else
				nfree++;
		}
		for(i = 0; i < n; i++)
			if(colw[i] < 0)
				colw[i] = nz(avail - fixedw) / nz1(nfree);
	} else {
		# percentages first, then between min and max
		for(i = 0; i < n; i++)
			if(pct[i] >= 0.0) {
				w := ir(pct[i] * real avail / 100.0);
				if(w > mn[i])
					mn[i] = mx[i] = w;
			}
		tmn := 0;
		tmx := 0;
		for(i = 0; i < n; i++) {
			tmn += mn[i];
			tmx += mx[i];
		}
		if(avail <= tmn) {
			for(i = 0; i < n; i++)
				colw[i] = mn[i];
		} else if(avail <= tmx && tmx > tmn) {
			f := real (avail - tmn) / real (tmx - tmn);
			for(i = 0; i < n; i++)
				colw[i] = mn[i] + ir(f * real (mx[i] - mn[i]));
		} else {
			# wider than the content wants: the rest goes to the auto
			# columns by their max width, and to the others only if there
			# are none (CSS Tables 3 §3.9.3, simplified)
			for(i = 0; i < n; i++)
				colw[i] = mx[i];
			wt := array[n] of {* => 0};
			nauto := 0;
			for(i = 0; i < n; i++)
				if(!fixw[i] && pct[i] < 0.0) {
					wt[i] = mx[i];
					nauto++;
				}
			if(nauto == 0)
				wt = mx;
			tw := 0;
			for(i = 0; i < n; i++)
				tw += wt[i];
			if(tw == 0) {
				# no widths to go by: equally, among the auto ones if any
				for(i = 0; i < n; i++)
					if(nauto == 0 || !fixw[i] && pct[i] < 0.0)
						wt[i] = 1;
			}
			if(n > 0)
				spread(colw, 0, n, avail - tmx, wt);
		}
	}
	# fix rounding so the columns fill the table exactly
	tot := 0;
	for(i = 0; i < n; i++)
		tot += colw[i];
	if(n > 0 && tot != avail && avail > 0)
		colw[n-1] += avail - tot;
	colx := array[n + 1] of int;
	x := b.bl + b.pl + sx;
	for(i = 0; i < n; i++) {
		colx[i] = x;
		x += colw[i] + sx;
	}
	colx[n] = x;

	# captions above (or below)
	y := b.bt + b.pt;
	for(cl := t.captions; cl != nil; cl = tl cl) {
		k := hd cl;
		if(k.st.captionbottom)
			continue;
		y = laycaption(l, k, b, cw, y);
	}
	gridtop := y;
	nr := len t.rows;
	rowh := array[nr] of {* => 0};
	rowspec := array[nr] of {* => 0};	# the row's height was specified (by it or a cell)
	for(r := 0; r < nr; r++) {
		row := t.rows[r];
		edges(row, cw);
		if((sh := spech(row, row.st.height, -1)) > 0) {
			rowh[r] = sh;
			rowspec[r] = 1;
		}
	}
	# lay each cell out at its width; single-row cells set row heights
	for(cl2 := t.cells; cl2 != nil; cl2 = tl cl2) {
		c := hd cl2;
		k := c.box;
		w := colx[c.c + c.cs - 1] + colw[c.c + c.cs - 1] - colx[c.c];
		edges(k, cw);
		if(st.collapse) {
			# collapsed borders (§17.6.2), simply: a border shared with
			# the next cell or the table's own is drawn once
			if(c.c + c.cs < n)
				k.br = 0;
			else if(b.br > 0)
				k.br = 0;
			if(c.r + c.rs < nr)
				k.bb = 0;
			else if(b.bb > 0)
				k.bb = 0;
			if(c.c == 0 && b.bl > 0)
				k.bl = 0;
			if(c.r == 0 && b.bt > 0)
				k.bt = 0;
		}
		k.w = w;
		layblock(l, k, w, -1, nil, 0, 0);
		if(c.rs == 1 && k.h > rowh[c.r])
			rowh[c.r] = k.h;
		if(c.rs == 1 && k.st.height.kind == Style->Lpx && k.st.height.pct == 0.0)
			rowspec[c.r] = 1;
	}
	for(cl2 = t.cells; cl2 != nil; cl2 = tl cl2) {
		c := hd cl2;
		if(c.rs < 2)
			continue;
		have := sy * (c.rs - 1);
		for(r = c.r; r < c.r + c.rs; r++)
			have += rowh[r];
		if(c.box.h > have)
			rowh[c.r + c.rs - 1] += c.box.h - have;
	}
	# a specified table height grows the rows
	sh := specheight(b, cbh);
	if(sh >= 0) {
		gh := sy * (nr + 1);
		for(r = 0; r < nr; r++)
			gh += rowh[r];
		capsh := gridtop - b.bt - b.pt;
		extra := sh - vextra(b) - capsh - gh;
		if(extra > 0 && nr > 0) {
			# to the rows of unspecified height, equally; failing
			# any, to all in proportion (§17.5.3 leaves it open)
			wt := array[nr] of int;
			nauto := 0;
			for(r = 0; r < nr; r++) {
				wt[r] = !rowspec[r];
				nauto += wt[r];
			}
			if(nauto == 0)
				wt = rowh;
			spread(rowh, 0, nr, extra, wt);
		}
	}
	rowy := array[nr + 1] of int;
	y = gridtop + sy;
	for(r = 0; r < nr; r++) {
		rowy[r] = y;
		y += rowh[r] + sy;
	}
	rowy[nr] = y;
	# rows and groups as boxes, then cells within their rows
	for(r = 0; r < nr; r++) {
		row := t.rows[r];
		g := t.groups[r];
		ox := 0;
		oy := 0;
		if(g != nil) {
			ox = g.x;
			oy = g.y;
		}
		row.x = b.bl + b.pl - ox;
		row.y = rowy[r] - oy;
		row.w = cw;
		row.h = rowh[r];
		if(g != nil && (r == 0 || t.groups[r-1] != g)) {
			# the group spans its rows
			last := r;
			while(last + 1 < nr && t.groups[last + 1] == g)
				last++;
			g.x = b.bl + b.pl;
			g.y = rowy[r];
			g.w = cw;
			g.h = rowy[last] + rowh[last] - rowy[r];
			row.x = 0;
			row.y = 0;
		} else if(g != nil) {
			row.x = 0;
			row.y = rowy[r] - g.y;
		}
	}
	for(cl2 = t.cells; cl2 != nil; cl2 = tl cl2) {
		c := hd cl2;
		k := c.box;
		h := rowy[c.r + c.rs - 1] + rowh[c.r + c.rs - 1] - rowy[c.r];
		# the content's height: the cell's own when that came from its
		# content (child margins that collapsed through it included),
		# else measured, as a specified height may be less than the content
		contenth := k.h;
		if(k.st.height.kind != Style->Lauto)
			contenth = contentheight(k);
		# the row's height is definite for the cell's content when the
		# table's or the row's own height is (browsers resolve a
		# percentage inside an auto-height table's cell to auto)
		rowh := c.row.st.height;
		if(sh >= 0 || rowh.kind == Style->Lpx && rowh.pct == 0.0) {
			imposeh(l, k, h, k.w - hextra(k), h);
			if(heightmatters(k))
				contenth = h;	# laid out again to fill the cell
		} else
			k.h = h;
		# vertical-align within the cell
		va := k.st.valign;
		dy := 0;
		case va {
		Style->VAmiddle =>
			dy = (h - contenth)/2;
		Style->VAbottom =>
			dy = h - contenth;
		}
		if(dy > 0)
			shiftcontent(k, dy);
		# coordinates relative to the cell's row
		row := c.row;
		rx := row.x;
		ry := row.y;
		g := rowgroupof(t, row);
		if(g != nil) {
			rx += g.x;
			ry += g.y;
		}
		k.x = colx[c.c] - rx;
		k.y = rowy[c.r] - ry;
	}
	for(cl = t.captions; cl != nil; cl = tl cl) {
		k := hd cl;
		if(k.st.captionbottom)
			y = laycaption(l, k, b, cw, y);
	}
	h := y - b.bt - b.pt + vextra(b);
	if(sh > h)
		h = sh;
	b.h = h;
}

curdoc: ref Doc;

rowgroupof(t: ref Tgrid, row: ref Box): ref Box
{
	for(i := 0; i < len t.rows; i++)
		if(t.rows[i] == row)
			return t.groups[i];
	return nil;
}

laycaption(l: ref L, k, b: ref Box, cw, y: int): int
{
	edges(k, cw);
	sizew(k, cw);
	layblock(l, k, cw, -1, nil, 0, 0);
	k.x = b.bl + b.pl + k.ml;
	k.y = y + k.mt;
	return k.y + k.h + k.mb;
}

# move a box's content down (vertical-align in table cells)
shiftcontent(b: ref Box, dy: int)
{
	for(i := 0; i < len b.lines; i++) {
		ln := b.lines[i];
		ln.y += dy;
		ln.base += dy;
		for(j := 0; j < len ln.frags; j++) {
			f := ln.frags[j];
			f.y += dy;
			f.base += dy;
			if(f.kind == Fatomic)
				f.box.y += dy;
		}
	}
	if(b.lines == nil)
		for(i = 0; i < len b.kids; i++)
			b.kids[i].y += dy;
}

# ---- positioning (CSS 2.2 §9.3, §10.3.7, §10.6.4) ----

ispositioned(b: ref Box): int
{
	return b.st.position != Style->Pstatic;
}

# the containing block of an absolutely positioned box: its nearest
# positioned ancestor, or nil for the initial containing block
cbof(l: ref L, k: ref Box): ref Box
{
	if(k.st.position == Style->Pfixed)
		return nil;
	# A positioned inline box's padding box would be the containing
	# block (CSS 2.2 §10.1); its block container stands in for it,
	# which places the box rather than never laying it out.
	for(p := k.parent; p != nil; p = p.parent)
		if(ispositioned(p) && p.kind != Kinline)
			return p;
	return nil;
}

# relative and sticky positioning: shift the box after it is placed
relative(k: ref Box, cbw, cbh: int)
{
	st := k.st;
	if(st.position != Style->Prelative && st.position != Style->Psticky)
		return;
	if(st.left.kind != Style->Lauto)
		k.x += res(st.left, cbw);
	else if(st.right.kind != Style->Lauto)
		k.x -= res(st.right, cbw);
	if(st.top.kind != Style->Lauto && (cbh >= 0 || st.top.pct == 0.0))
		k.y += res(st.top, cbh);
	else if(st.bottom.kind != Style->Lauto && (cbh >= 0 || st.bottom.pct == 0.0))
		k.y -= res(st.bottom, cbh);
}

# b is laid out: lay out the absolutely positioned boxes it contains
positioned(l: ref L, b: ref Box)
{
	if(!ispositioned(b) || l.pending == nil)
		return;
	mine, rest: list of ref Abs;
	for(p := l.pending; p != nil; p = tl p)
		if((hd p).cb == b)
			mine = hd p :: mine;
		else
			rest = hd p :: rest;
	if(mine == nil)
		return;
	l.pending = nil;
	for(; rest != nil; rest = tl rest)
		l.pending = hd rest :: l.pending;
	# the padding box, in b's border-box coordinates
	pr := Rect((b.bl, b.bt), (b.w - b.br, b.h - b.bb));
	for(; mine != nil; mine = tl mine)
		layabs(l, hd mine, b, pr);
}

layabs(l: ref L, a: ref Abs, cb: ref Box, pr: Rect)
{
	k := a.box;
	st := k.st;
	cbw := pr.dx();
	cbh := pr.dy();
	# static position, in cb coordinates
	sx := a.sx;
	sy := a.sy;
	if(a.frag != nil)
		sx = a.frag.x;
	for(p := a.sparent; p != nil && p != cb; p = p.parent) {
		sx += p.x;
		sy += p.y;
	}
	if(cb == l.root && a.cb == nil) {
		# the viewport: undo the root's own offset
		sx += cb.x;
		sy += cb.y;
	}
	edges(k, cbw);
	lauto := st.left.kind == Style->Lauto;
	rauto := st.right.kind == Style->Lauto;
	tauto := st.top.kind == Style->Lauto;
	bauto := st.bottom.kind == Style->Lauto;
	left := res(st.left, cbw);
	right := res(st.right, cbw);
	top := res(st.top, cbh);
	bottom := res(st.bottom, cbh);
	mlauto := st.ml.kind == Style->Lauto;
	mrauto := st.mr.kind == Style->Lauto;
	if(mlauto)
		k.ml = 0;
	if(mrauto)
		k.mr = 0;
	w := specw(k, st.width, cbw);
	if(w < 0) {
		if(!lauto && !rauto)
			w = cbw - left - right - k.ml - k.mr;
		else if(k.kind == Kreplaced) {
			(rw, nil) := replacedsize(k, cbw, cbh);
			w = rw + hextra(k);
		} else {
			(mn, mx) := intrinsic(k);
			avail := cbw - k.ml - k.mr;
			if(!lauto)
				avail -= left;
			if(!rauto)
				avail -= right;
			w = fit(mn, mx, avail + mgs(k)) - mgs(k);
		}
	}
	k.w = clampw(k, w, cbw);
	x: int;
	if(!lauto && !rauto && (mlauto || mrauto)) {
		free := cbw - left - right - k.w;
		if(mlauto && mrauto) {
			k.ml = free/2;
			k.mr = free - k.ml;
		} else if(mlauto)
			k.ml = free - k.mr;
		else
			k.mr = free - k.ml;
	}
	if(!lauto)
		x = pr.min.x + left + k.ml;
	else if(!rauto)
		x = pr.max.x - right - k.mr - k.w;
	else {
		x = sx + k.ml;
		if(a.rightedge)
			x = sx - k.w - k.mr;
	}
	layblock(l, k, cbw, cbh, nil, 0, 0);
	h := k.h;
	if(spech(k, st.height, cbh) < 0 && !tauto && !bauto) {
		h = clamph(k, cbh - top - bottom - k.mt - k.mb, cbh);
		k.h = h;
	}
	y: int;
	if(!tauto)
		y = pr.min.y + top + k.mt;
	else if(!bauto)
		y = pr.max.y - bottom - k.mb - h;
	else
		y = sy + k.mt;
	k.x = x;
	k.y = y;
	for(pl := cb.pos; pl != nil; pl = tl pl)
		if(hd pl == k)
			break;
	if(pl == nil)
		cb.pos = k :: cb.pos;
	k.parent = cb;
}

# ---- floats (CSS 2.2 §9.5) ----

# the band [left, right) free of floats between y0 and y1, within [x0, x1)
band(fc: ref Fctx, y0, y1, x0, x1: int): (int, int)
{
	if(fc == nil)
		return (x0, x1);
	for(l := fc.left; l != nil; l = tl l) {
		r := hd l;
		if(r.min.y < y1 && r.max.y > y0 && r.max.x > x0)
			x0 = r.max.x;
	}
	for(l = fc.right; l != nil; l = tl l) {
		r := hd l;
		if(r.min.y < y1 && r.max.y > y0 && r.min.x < x1)
			x1 = r.min.x;
	}
	return (x0, x1);
}

# the lowest float bottom at or below y, above which a band is blocked
nextfloat(fc: ref Fctx, y: int): int
{
	n := -1;
	for(l := fc.left; l != nil; l = tl l)
		if((hd l).max.y > y && (n < 0 || (hd l).max.y < n))
			n = (hd l).max.y;
	for(l = fc.right; l != nil; l = tl l)
		if((hd l).max.y > y && (n < 0 || (hd l).max.y < n))
			n = (hd l).max.y;
	return n;
}

clearance(fc: ref Fctx, side: int): int
{
	y := -1000000;
	if(fc == nil)
		return y;
	if(side == Style->Cleft || side == Style->Cboth)
		for(l := fc.left; l != nil; l = tl l)
			if((hd l).max.y > y)
				y = (hd l).max.y;
	if(side == Style->Cright || side == Style->Cboth)
		for(m := fc.right; m != nil; m = tl m)
			if((hd m).max.y > y)
				y = (hd m).max.y;
	return y;
}

floatbottom(fc: ref Fctx): int
{
	y := 0;
	for(l := fc.left; l != nil; l = tl l)
		if((hd l).max.y > y)
			y = (hd l).max.y;
	for(l = fc.right; l != nil; l = tl l)
		if((hd l).max.y > y)
			y = (hd l).max.y;
	return y;
}

# Lay out float k and place it at or below y in the content box
# [cx, cx+cw) of the block whose border box is at (ox, oy) in fc.
# A block's top margin collapsed with its first children's, as far as
# they adjoin (§8.3.1), before it is laid out: for clearance.
topmargin(k: ref Box, cw: int): Margin
{
	m := mval(k.mt);
	for(depth := 0; depth < 32; depth++) {
		if(k.bt != 0 || k.pt != 0 || isbfc(k) || haslines(k) || k.kind != Kblock)
			break;
		next: ref Box;
		for(i := 0; i < len k.kids; i++) {
			c := k.kids[i];
			if(isabs(c) || isfloat(c))
				continue;
			next = c;
			break;
		}
		if(next == nil || next.inl)
			break;
		edges(next, cw);
		m = collapse(m, mval(next.mt));
		k = next;
	}
	return m;
}

# a float's margin-box width, its edges and width set
floatwidth(k: ref Box, cw: int): int
{
	edges(k, cw);
	w := specw(k, k.st.width, cw);
	if(w < 0) {
		if(k.kind == Kreplaced) {
			(rw, nil) := replacedsize(k, cw, -1);
			w = rw + hextra(k);
		} else {
			(mn, mx) := intrinsic(k);
			w = fit(mn, mx, cw) - mgs(k);
		}
	}
	if(k.st.ml.kind == Style->Lauto)
		k.ml = 0;
	if(k.st.mr.kind == Style->Lauto)
		k.mr = 0;
	k.w = clampw(k, w, cw);
	return k.ml + k.w + k.mr;
}

placefloat(l: ref L, k: ref Box, fc: ref Fctx, cx, y, cw, ch, ox, oy: int)
{
	floatwidth(k, cw);
	layblock(l, k, cw, ch, nil, 0, 0);	# % heights against a definite one
	mw := k.ml + k.w + k.mr;	# a table may have come out wider than specified
	mh := k.mt + k.h + k.mb;
	if(k.st.clear != Style->Cnone) {
		c := clearance(fc, k.st.clear);
		if(c > y)
			y = c;
	}
	# not above an earlier float
	for(fl := fc.left; fl != nil; fl = tl fl)
		if((hd fl).min.y > y)
			y = (hd fl).min.y;
	for(fl = fc.right; fl != nil; fl = tl fl)
		if((hd fl).min.y > y)
			y = (hd fl).min.y;
	# a float wider than its containing block reaches past it, and must
	# not overlap other floats out there either (§9.5.1 rule 3)
	(bx0, bx1) := (cx, cx + cw);
	if(mw > cw) {
		if(k.st.float == Style->Fleft)
			bx1 = cx + mw;
		else
			bx0 = cx + cw - mw;
	}
	for(tries := 0; tries < 1000; tries++) {
		(lx, rx) := band(fc, y, y + nz1(mh), bx0, bx1);
		if(rx - lx >= mw || (lx == bx0 && rx == bx1))
			break;
		n := nextfloat(fc, y);
		if(n < 0)
			break;
		y = n;
	}
	(lx, rx) := band(fc, y, y + nz1(mh), bx0, bx1);
	r: Rect;
	if(k.st.float == Style->Fleft) {
		r = Rect((lx, y), (lx + mw, y + mh));
		fc.left = r :: fc.left;
	} else {
		r = Rect((rx - mw, y), (rx, y + mh));
		fc.right = r :: fc.right;
	}
	k.x = r.min.x - ox + k.ml;
	k.y = r.min.y - oy + k.mt;
	relative(k, cw, -1);
}




asblock(l: ref L, b: ref Box, cbw, cbh: int)
{
	k := b.kind;
	b.kind = Kblock;
	layblock(l, b, cbw, cbh, nil, 0, 0);
	b.kind = k;
}

haslines(b: ref Box): int
{
	if(b.kind != Kblock && b.kind != Kcell && b.kind != Kflex && b.kind != Kgrid && b.kind != Ktable && b.kind != Krow)
		return 0;
	for(i := 0; i < len b.kids; i++)
		if(b.kids[i].inl)
			return 1;
	return 0;
}

# A replaced element's content size: (width, height).
replacedsize(b: ref Box, cbw, cbh: int): (int, int)
{
	iw := b.iw;
	ih := b.ih;
	if(b.img != nil && iw == 0 && ih == 0) {
		iw = b.img.r.dx();
		ih = b.img.r.dy();
	}
	if(b.text != nil && b.iw == 0 && b.img == nil && b.node != 0) {
		# a form control or an image's alt text: size to the text; a
		# text field to its size attribute (20 characters by default),
		# as browsers do, whatever it holds
		f := face(b.st);
		iw = ir(f.width(b.text)) + 2;
		ih = ir(lineheight(b.st, f));
		if(curdoc != nil && curdoc.nodes[b.node].tag == Dom->Tinput && textfield(curdoc, b.node)) {
			size := 20;
			if((sz := curdoc.attr(b.node, "size")) != nil && int sz > 0)
				size = int sz;
			sw := ir(real size * f.width("0")) + 2;
			if(sw > iw)
				iw = sw;
		}
	}
	st := b.st;
	w := -1;
	h := -1;
	if(st.width.kind == Style->Lpx || st.width.kind == Style->Lcalc) {
		if(!(cbw < 0 && st.width.pct != 0.0)) {
			w = res(st.width, cbw);
			if(st.borderbox)
				w -= hextra(b);
		}
	}
	if(st.height.kind == Style->Lpx && (st.height.pct == 0.0 || cbh >= 0)) {
		h = res(st.height, cbh);
		if(st.borderbox)
			h -= vextra(b);
	}
	ratio := aspect(b, iw, ih);
	if(w < 0 && h < 0) {
		w = iw;
		h = ih;
	} else if(w < 0) {
		if(ratio > 0.0)
			w = ir(real h * ratio);
		else
			w = iw;
	} else if(h < 0) {
		if(ratio > 0.0)
			h = ir(real w / ratio);
		else
			h = ih;
	}
	if(w < 0)
		w = 0;
	if(h < 0)
		h = 0;
	return (w, h);
}

# The image an <img> shows (HTML §4.8.4.3, reduced): a <source> of its
# <picture> whose type we decode and that has no media condition
# (media conditions are left to the <img> fallback, which pages make
# the small, safe choice), else its own srcset, else src.
imgsrc(d: ref Doc, n: int): string
{
	p := d.nodes[n].parent;
	if(p != 0 && d.nodes[p].tag == Dom->Tpicture && d.nodes[p].ns == Dom->HTML)
		for(c := d.nodes[p].first; c != 0 && c != n; c = d.nodes[c].next) {
			nd := d.nodes[c];
			if(nd.kind != Dom->Element || nd.tag != Dom->Tsource)
				continue;
			if(d.hasattr(c, "media") && trimsp(d.attr(c, "media")) != "")
				continue;
			if(d.hasattr(c, "type") && !decodes(d.attr(c, "type")))
				continue;
			if((u := srcset(d.attr(c, "srcset"))) != nil)
				return u;
		}
	if((u := srcset(d.attr(n, "srcset"))) != nil)
		return u;
	return d.attr(n, "src");
}

# image types the engine decodes
decodes(t: string): int
{
	case lower(trimsp(t)) {
	"image/png" or "image/jpeg" or "image/jpg" or "image/gif" or "image/webp" or
	"image/svg+xml" or "image/avif" or "image/x-icon" or "image/vnd.microsoft.icon" =>
		return 1;
	}
	return 0;
}

# The candidate of a srcset for a 1x display: among density
# descriptors the one nearest 1x; among width descriptors the
# narrowest that is at least a typical viewport wide, else the widest.
srcset(s: string): string
{
	best := "";
	bestd := 0.0;
	bestw := 0;
	i := 0;
	while(i < len s) {
		while(i < len s && (isblank(s[i]) || s[i] == ','))
			i++;
		# the URL runs to white space; a URL may hold commas (data:),
		# so only trailing ones end the candidate
		j := i;
		while(j < len s && !isblank(s[j]))
			j++;
		if(j == i)
			break;
		u := s[i:j];
		i = j;
		d := 0.0;	# density
		w := 0;		# width
		ended := 0;
		while(len u > 0 && u[len u - 1] == ',') {
			u = u[0:len u - 1];
			ended = 1;
		}
		# the descriptors, up to the next comma
		for(; !ended; ) {
			while(i < len s && isblank(s[i]))
				i++;
			if(i >= len s || s[i] == ',') {
				if(i < len s)
					i++;
				break;
			}
			k := i;
			while(k < len s && !isblank(s[k]) && s[k] != ',')
				k++;
			desc := s[i:k];
			i = k;
			if(len desc > 1) {
				v := desc[0:len desc - 1];
				case desc[len desc - 1] {
				'x' =>	d = real v;
				'w' =>	w = int v;
				}
			}
		}
		if(w > 0) {
			if(bestw == 0 || bestw < SRCSETW && w > bestw || w >= SRCSETW && w < bestw) {
				best = u;
				bestw = w;
			}
		} else {
			if(d == 0.0)
				d = 1.0;
			dd := d - 1.0;
			if(dd < 0.0)
				dd = -dd;
			bd := bestd - 1.0;
			if(bd < 0.0)
				bd = -bd;
			if(best == "" || bestw == 0 && dd < bd) {
				best = u;
				bestd = d;
			}
		}
	}
	return best;
}

SRCSETW: con 1024;	# the width a w-descriptor candidate should cover

isblank(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

trimsp(s: string): string
{
	i := 0;
	while(i < len s && isblank(s[i]))
		i++;
	j := len s;
	while(j > i && isblank(s[j-1]))
		j--;
	return s[i:j];
}

# an <input> that takes typed text
textfield(d: ref Doc, n: int): int
{
	case lower(d.attr(n, "type")) {
	"" or "text" or "search" or "email" or "url" or "tel" or "password" or "number" =>
		return 1;
	}
	return 0;
}

# the ratio a replaced box keeps: aspect-ratio, else its content's
aspect(b: ref Box, iw, ih: int): real
{
	ratio := b.st.aspect;
	if(ratio == 0.0 && iw > 0 && ih > 0)
		ratio = real iw / real ih;
	return ratio;
}

# The content height of a replaced box whose height is auto, once its
# width is used: if min/max-width (or a flex or grid container) made
# the width other than what replacedsize chose, the height follows the
# ratio (CSS 2.2 §10.4), so an img { max-width: 100% } keeps its shape.
replacedheight(b: ref Box, cbw, cbh: int): int
{
	(w, h) := replacedsize(b, cbw, cbh);
	cw := b.w - hextra(b);
	if(cw != w && cw > 0) {
		iw := b.iw;
		ih := b.ih;
		if(b.img != nil && iw == 0 && ih == 0) {
			iw = b.img.r.dx();
			ih = b.img.r.dy();
		}
		ratio := aspect(b, iw, ih);
		if(ratio > 0.0)
			return ir(real cw / ratio);
	}
	return h;
}

# ---- intrinsic widths (CSS Sizing 3) ----

# (min-content, max-content) border-box widths, plus margins.
# The min- and max-content widths of b's margin box.  Measured once
# per layout: a nest of shrink-to-fit, flex and table contexts asks
# for the same box's widths at every level, and without the cache the
# text at the bottom is re-measured for each (exponentially in depth).
# The edges are part of the answer, so a change in them (percentages
# resolved against another width) measures again.
intrinsic(b: ref Box): (int, int)
{
	ex := hextra(b) + mgs(b);
	if(b.igen == laygen && b.iex == ex)
		return (b.imn, b.imx);
	(mn, mx) := intrinsic1(b);
	b.imn = mn;
	b.imx = mx;
	b.iex = ex;
	b.igen = laygen;
	return (mn, mx);
}

# What b contributes to the intrinsic size of its parent: its own
# widths, bounded by its min-width and max-width (CSS Sizing 3 §5.2).
# A box's own size ignores them (a flex base size is measured before
# the min and max are applied), so the two are kept apart.
contribution(b: ref Box): (int, int)
{
	(mn, mx) := intrinsic(b);
	st := b.st;
	mg := mgs(b);
	if(st.minwidth.kind == Style->Lpx && st.minwidth.pct == 0.0) {
		w := ir(st.minwidth.px) + mg;
		if(!st.borderbox)
			w += hextra(b);
		if(mn < w)
			mn = w;
		if(mx < w)
			mx = w;
	}
	if(st.maxwidth.kind == Style->Lpx && st.maxwidth.pct == 0.0) {
		w := ir(st.maxwidth.px) + mg;
		if(!st.borderbox)
			w += hextra(b);
		if(mx > w)
			mx = w;
		# a table is never narrower than its minimum (CSS 2.2 §17.5.2)
		if(mn > w && b.kind != Ktable)
			mn = w;
		if(mx < mn)
			mx = mn;
	}
	return (mn, mx);
}

intrinsic1(b: ref Box): (int, int)
{
	ex := hextra(b) + mgs(b);
	st := b.st;
	if(st.width.kind == Style->Lpx && st.width.pct == 0.0) {
		w := ir(st.width.px);
		if(!st.borderbox)
			w += hextra(b);
		return (w + mgs(b), w + mgs(b));
	}
	if(b.kind == Kreplaced) {
		(w, nil) := replacedsize(b, -1, -1);
		return (w + ex, w + ex);
	}
	if(b.kind == Ktable) {
		(tmn, tmx) := tableintrinsic(b);
		return (tmn + mgs(b), tmx + mgs(b));
	}
	if(b.kind == Kgrid && st.gridcols != nil) {
		# the columns add up: a fixed one is its size, any other is
		# the largest contribution of the items placed in it (the
		# items taken in order, one per column, as auto-placement
		# would put them without spans)
		gap := 0;
		if(st.colgap.kind != Style->Lnormal)
			gap = res(st.colgap, 0);
		(cols, nil) := tracks(st.gridcols, 0, gap);
		if(len cols > 0) {
			cmn := array[len cols] of {* => 0};
			cmx := array[len cols] of {* => 0};
			c := 0;
			for(i := 0; i < len b.kids; i++) {
				k := b.kids[i];
				if(isabs(k))
					continue;
				edges(k, 0);
				(kmn, kmx) := contribution(k);
				if(kmn > cmn[c])
					cmn[c] = kmn;
				if(kmx > cmx[c])
					cmx[c] = kmx;
				c = (c + 1) % len cols;
			}
			wmn := gap * (len cols - 1) + ex;
			wmx := wmn;
			for(i = 0; i < len cols; i++)
				if(cols[i].lo.kind == Tfixed && cols[i].hi.kind == Tfixed) {
					wmn += int cols[i].hi.v;
					wmx += int cols[i].hi.v;
				} else {
					wmn += cmn[i];
					wmx += cmx[i];
				}
			return (wmn, wmx);
		}
	}
	mn := 0;
	mx := 0;
	if(haslines(b) || b.kind == Kinline) {
		(mn, mx) = inlineintrinsic(b);
	} else if(b.kind == Kflex && b.st.flexdir < 2 || b.kind == Krow) {
		# a row: maxima add up, with the gaps between
		if(b.kind == Kflex && b.st.colgap.kind != Style->Lnormal && len b.kids > 1) {
			g := res(b.st.colgap, 0) * (len b.kids - 1);
			mx += g;
			if(b.st.flexwrap == 0)
				mn += g;
		}
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			edges(k, 0);
			(kmn, kmx) := contribution(k);
			if(b.st.flexwrap != 0) {
				if(kmn > mn)
					mn = kmn;
			} else
				mn += kmn;
			mx += kmx;
		}
	} else {
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			edges(k, 0);
			(kmn, kmx) := contribution(k);
			if(kmn > mn)
				mn = kmn;
			if(kmx > mx)
				mx = kmx;
		}
	}
	if(mx < mn)	# negative margins can make a sum smaller than its largest part
		mx = mn;
	return (mn + ex, mx + ex);
}

# a box's horizontal margins together, negative ones and all (auto
# ones are 0 here); they are part of what it contributes to a parent
mgs(b: ref Box): int
{
	return b.ml + b.mr;
}

nz(m: int): int
{
	if(m < 0)
		return 0;
	return m;
}

inlineintrinsic(b: ref Box): (int, int)
{
	items := flatten(b);
	mn := 0.0;
	mx := 0.0;
	line := 0.0;
	word := 0.0;
	# collapsible spaces count only between content: those at a line's
	# ends are removed when it is laid out
	sp := 0.0;	# collapsible space waiting for content after it
	content := 0;	# the line has content
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		case it.kind {
		Iword =>
			w := it.w;
			if(it.nowrap)
				word += w;
			else
				word = w;
			if(word > mn)
				mn = word;
			line += sp + w;
			sp = 0.0;
			content = 1;
		Ispace =>
			if(it.nowrap) {
				# an unbreakable space is part of the word
				word += it.w;
				if(word > mn)
					mn = word;
			} else
				word = 0.0;
			if(it.text == " " && collapsible(it.box.st)) {
				if(content)
					sp += it.w;
			} else {
				line += sp + it.w;
				sp = 0.0;
				content = 1;
			}
		Iopen or Iclose =>
			line += it.w;
			word += it.w;
			if(it.w > 0.0)
				content = 1;
		Iatomic =>
			edges(it.box, 0);	# its padding and borders count; % ones are 0 here
			(kmn, kmx) := contribution(it.box);
			if(real kmn > mn)
				mn = real kmn;
			line += sp + real kmx;
			sp = 0.0;
			word = 0.0;
			content = 1;
		Ibreak =>
			if(line > mx)
				mx = line;
			line = 0.0;
			word = 0.0;
			sp = 0.0;
			content = 0;
		Ifloat =>
			edges(it.box, 0);
			(kmn, kmx) := contribution(it.box);
			if(real kmn > mn)
				mn = real kmn;
			line += real kmx;
		}
	}
	if(line > mx)
		mx = line;
	return (ir(mn + 0.49), ir(mx + 0.49));
}

# ---- inline formatting (CSS 2.2 §9.4.2, §10.8; CSS Text 3) ----

Iword, Ispace, Iopen, Iclose, Iatomic, Ibreak, Ifloat, Iabs: con iota;

Item: adt {
	kind:	int;
	text:	string;
	w:	real;
	box:	ref Box;	# text run, inline box or atomic box
	face:	ref Typeface;
	nowrap:	int;		# no soft wrap here
	deco:	int;
	decocolor:	int;
	level:	int;		# bidi embedding level, set by bidiitems
	para:	int;		# the level of the paragraph it is in (plaintext: per forced break)
};

Fl: adt {
	items:	list of ref Item;	# reversed
	space:	int;		# the last thing emitted was a collapsible space
	deco:	int;
	decocolor:	int;
};

# The inline content of b as a list of items, white space processed.
flatten(b: ref Box): list of ref Item
{
	f := ref Fl(nil, 1, b.st.decoration, b.st.decorationcolor);
	for(i := 0; i < len b.kids; i++)
		flat(f, b.kids[i]);
	r: list of ref Item;
	for(l := f.items; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

emit(f: ref Fl, it: ref Item)
{
	f.items = it :: f.items;
}

flat(f: ref Fl, b: ref Box)
{
	case b.kind {
	Ktext =>
		text(f, b);
	Kmarker =>
		markeritem(f, b);
	Kbr =>
		emit(f, ref Item(Ibreak, nil, 0.0, b, nil, 0, 0, 0, 0, 0));
		f.space = 1;
	Kinline =>
		edges(b, 0);
		odeco := f.deco;
		ocol := f.decocolor;
		if(b.st.decoration != 0) {
			f.deco |= b.st.decoration;
			f.decocolor = b.st.decorationcolor;
		}
		emit(f, ref Item(Iopen, nil, real (b.ml + b.bl + b.pl), b, nil, 0, 0, 0, 0, 0));
		for(i := 0; i < len b.kids; i++)
			flat(f, b.kids[i]);
		emit(f, ref Item(Iclose, nil, real (b.mr + b.br + b.pr), b, nil, 0, 0, 0, 0, 0));
		f.deco = odeco;
		f.decocolor = ocol;
	* =>
		if(isabs(b))
			emit(f, ref Item(Iabs, nil, 0.0, b, nil, 0, 0, 0, 0, 0));
		else if(isfloat(b))
			emit(f, ref Item(Ifloat, nil, 0.0, b, nil, 0, 0, 0, 0, 0));
		else {
			emit(f, ref Item(Iatomic, nil, 0.0, b, nil, 0, 0, 0, 0, 0));
			f.space = 0;
		}
	}
}

# A list marker is one unbreakable piece; outside the content it takes
# no room on the line.
markeritem(f: ref Fl, b: ref Box)
{
	if(b.text == "")
		return;
	fc := face(b.st);
	# an inside marker is its own bidi isolate (::marker in html.css)
	iso := b.st.listinside && isolating(b.st.unicodebidi);
	if(iso)
		emit(f, ref Item(Iopen, nil, 0.0, b, nil, 0, 0, 0, 0, 0));
	emit(f, ref Item(Iword, b.text, fc.width(b.text), b, fc, 1, 0, 0, 0, 0));
	if(iso)
		emit(f, ref Item(Iclose, nil, 0.0, b, nil, 0, 0, 0, 0, 0));
	f.space = 1;
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

# CJK and the like break between any two characters
# s without its soft hyphens (U+00AD)
noshy(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == 16rAD)
			break;
	if(i == len s)
		return s;
	r := "";
	for(i = 0; i < len s; i++)
		if(s[i] != 16rAD)
			r[len r] = s[i];
	return r;
}

isideo(c: int): int
{
	return (c >= 16r2E80 && c <= 16r9FFF) || (c >= 16rAC00 && c <= 16rD7AF) ||
		(c >= 16rF900 && c <= 16rFAFF) || (c >= 16rFF00 && c <= 16rFFEF) || c >= 16r20000;
}

transform(s: string, t: int, first: int): string
{
	case t {
	Style->TTupper =>
		for(i := 0; i < len s; i++)
			if(s[i] >= 'a' && s[i] <= 'z' || s[i] >= 16rE0 && s[i] <= 16rFE && s[i] != 16rF7)
				s[i] -= 32;
	Style->TTlower =>
		for(i := 0; i < len s; i++)
			if(s[i] >= 'A' && s[i] <= 'Z' || s[i] >= 16rC0 && s[i] <= 16rDE && s[i] != 16rD7)
				s[i] += 32;
	Style->TTcap =>
		at := first;
		for(i := 0; i < len s; i++) {
			if(at && s[i] >= 'a' && s[i] <= 'z')
				s[i] -= 32;
			at = isspace(s[i]) || s[i] == '-';
		}
	}
	return s;
}

crtospace(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] == '\r')
			r[i] = ' ';
	return r;
}

text(f: ref Fl, b: ref Box)
{
	st := b.st;
	fc := face(st);
	s := b.text;
	if(st.transform != Style->TTnone)
		s = transform(s, st.transform, f.space);
	# a carriage return is a space in every respect (CSS Text 3 §4.1)
	for(k := 0; k < len s; k++)
		if(s[k] == '\r') {
			s = crtospace(s);
			break;
		}
	ws := st.whitespace;
	collapsesp := ws == Style->Wnormal || ws == Style->Wnowrap || ws == Style->Wpreline;
	keepnl := !(ws == Style->Wnormal || ws == Style->Wnowrap);
	nowrap := ws == Style->Wnowrap || ws == Style->Wpre;
	ls := st.letterspacing;
	i := 0;
	while(i < len s) {
		c := s[i];
		if(c == '\n' && keepnl) {
			emit(f, ref Item(Ibreak, nil, 0.0, b, fc, 0, 0, 0, 0, 0));
			f.space = 1;
			i++;
			continue;
		}
		if(isspace(c) && collapsesp) {
			while(i < len s && isspace(s[i]) && !(s[i] == '\n' && keepnl))
				i++;
			if(!f.space) {
				emit(f, ref Item(Ispace, " ", fc.space + st.wordspacing + ls, b, fc, nowrap, f.deco, f.decocolor, 0, 0));
				f.space = 1;
			}
			continue;
		}
		if(c == ' ' || c == '\t' || c == '　') {
			# preserved spaces: each is a break opportunity (unless nowrap)
			w := fc.space + st.wordspacing + ls;
			t := " ";
			if(c == '\t') {
				w = fc.space * st.tabsize;
				if(st.tabsize < 0.0)
					w = -st.tabsize;	# a length
				t = "\t";
			} else if(c == '　')
				w = fc.width("　");
			emit(f, ref Item(Ispace, t, w, b, fc, nowrap, f.deco, f.decocolor, 0, 0));
			f.space = 0;
			i++;
			continue;
		}
		if(c == 16r200B) {
			# a zero-width space: a break opportunity that shows nothing
			emit(f, ref Item(Ispace, "", 0.0, b, fc, nowrap, f.deco, f.decocolor, 0, 0));
			f.space = 0;
			i++;
			continue;
		}
		# a word: up to the next space or break opportunity
		st0 := i;
		while(i < len s && !isspace(s[i]) && s[i] != 16r200B && !(isideo(s[i]) && i > st0)) {
			i++;
			if(s[i-1] == '-' && i < len s && !isspace(s[i]) && i - st0 > 2)
				break;	# break after a hyphen inside a word
			if(isideo(s[i-1]))
				break;
		}
		if(i == st0) {
			i++;	# a control character no case above takes (form feed): dropped
			continue;
		}
		word := noshy(s[st0:i]);	# soft hyphens show nothing (no break there yet)
		if(word == "")
			continue;
		w := fc.width(word) + ls * real len word;
		if(st.breakall && !nowrap) {
			# every character is a break opportunity
			for(k := 0; k < len word; k++) {
				ch := word[k:k+1];
				emit(f, ref Item(Iword, ch, fc.width(ch) + ls, b, fc, 0, f.deco, f.decocolor, 0, 0));
			}
		} else
			emit(f, ref Item(Iword, word, w, b, fc, nowrap, f.deco, f.decocolor, 0, 0));
		f.space = 0;
	}
}

# a line under construction
Ln: adt {
	para:	int;			# the paragraph's bidi level
	frags:	list of ref Frag;	# reversed
	x:	real;			# where the next thing goes
	avail:	int;			# right edge, in content coordinates
	left:	int;			# left edge (past left floats)
	content:	int;		# something has been placed
	open:	list of (ref Box, real, int, int);	# inline boxes open on this line: (box, start x, first?, the level of its bidi control)
	indent:	real;		# text-indent (the first line only): content starts this far past the left edge
	floats:	list of ref Box;	# floats met mid-line, placed when the line ends
};

# the inline formatting state of one block container
Ifc: adt {
	l:	ref L;
	b:	ref Box;
	cw:	int;
	fc:	ref Fctx;
	ox, oy:	int;		# b's border box in fc
	y:	int;		# top of the next line, in b's border box
	strut:	int;		# the block's own line height, for float bands
	ch:	int;		# b's content height if definite, else -1: for floats' percentages
};

# Set ln's edges from the floats beside the line at f.y.
edgesat(f: ref Ifc, ln: ref Ln)
{
	cx := f.ox + f.b.bl + f.b.pl;
	ly := f.oy + f.y;
	(lx, rx) := band(f.fc, ly, ly + nz1(f.strut), cx, cx + f.cw);
	ln.left = lx - cx;
	ln.avail = rx - cx;
	if(ln.x < real ln.left)
		ln.x = real ln.left;
}

# a line starts past the floats at its left, and its text-indent
linestart(f: ref Ifc, ln: ref Ln)
{
	ln.x = 0.0;
	edgesat(f, ln);
	ln.x = real ln.left + ln.indent;
}

# Nothing fits beside the floats here: move the (empty) line down past one.
movedown(f: ref Ifc, ln: ref Ln): int
{
	if(f.fc == nil || ln.left == 0 && ln.avail == f.cw)
		return 0;
	n := nextfloat(f.fc, f.oy + f.y);
	if(n < 0)
		return 0;
	f.y = n - f.oy;
	linestart(f, ln);
	return 1;
}

placepending(f: ref Ifc, ln: ref Ln)
{
	for(fl := rev(ln.floats); fl != nil; fl = tl fl)
		placefloat(f.l, hd fl, f.fc, f.ox + f.b.bl + f.b.pl, f.oy + f.y, f.cw, f.ch, f.ox, f.oy);
	ln.floats = nil;
}

layinline(l: ref L, b: ref Box, cw, ch: int, fc: ref Fctx, ox, oy: int): int
{
	items := flatten(b);
	st := b.st;
	lines: list of ref Line;
	f := ref Ifc(l, b, cw, fc, ox, oy, b.bt + b.pt, ir(lineheight(st, face(st))), ch);
	x0 := b.bl + b.pl;
	para := 0;
	joinruns(items);
	(items, para) = bidiitems(b, items);
	ln := ref Ln(para, nil, 0.0, cw, 0, 0, nil, real res(st.indent, cw), nil);
	linestart(f, ln);
	first := 1;
	opened: list of ref Box;	# inline boxes open, outermost last
	for(il := items; il != nil; il = tl il) {
		it := hd il;
		case it.kind {
		Iopen =>
			ln.open = (it.box, ln.x, 1, it.level) :: ln.open;
			opened = it.box :: opened;
			ln.x += it.w;
			if(it.w > 0.0)
				ln.content = 1;	# margin, border or padding: not a phantom line (CSS 2.2 §9.4.2)
		Iclose =>
			ln.x += it.w;
			if(it.w > 0.0)
				ln.content = 1;
			fr := span(ln, it.box, 1);
			fr.level = it.level;
			ln.frags = fr :: ln.frags;
			opened = removebox(opened, it.box);
		Ispace =>
			if(!ln.content && it.text == " " && collapsible(it.box.st))
				continue;
			fr := textfrag(ln, it);
			w := it.w;
			if(it.text == "\t" && w > 0.0) {
				# to the next tab stop, a multiple of the tab size from
				# the content edge (CSS Text 3 §4.1); a tab at a stop is a whole one
				w -= math->fmod(ln.x, w);
				fr.w = ir(w);
			}
			ln.frags = fr :: ln.frags;
			ln.x += w;
			if(!collapsible(it.box.st))
				ln.content = 1;	# preserved white space is content
		Iword =>
			if(it.box.kind == Kmarker && !it.box.st.listinside) {
				fr := textfrag(ln, it);
				fr.x = ir(ln.x - it.w);
				ln.frags = fr :: ln.frags;
				ln.content = 1;
				continue;
			}
			if(ln.content && ln.x + it.w > real ln.avail + 0.01 && !it.nowrap && !prevnowrap(ln)) {
				lines = endline(f, ln, x0, first, 0) :: lines;
				first = 0;
				ln = newline(f, ln, opened);
			}
			while(!ln.content && ln.x + it.w > real ln.avail + 0.01 && movedown(f, ln))
				;
			if(!ln.content && ln.x + it.w > real ln.avail && it.box.st.anywhere && len it.text > 1) {
				# overflow-wrap: break the word where it must
				(head, tail) := splitword(it, real ln.avail - ln.x);
				if(head != nil) {
					ln.frags = textfrag(ln, head) :: ln.frags;
					ln.x += head.w;
					ln.content = 1;
					lines = endline(f, ln, x0, first, 0) :: lines;
					first = 0;
					ln = newline(f, ln, opened);
					il = it :: tail :: tl il;	# the loop steps on to the rest
					continue;
				}
			}
			ln.frags = textfrag(ln, it) :: ln.frags;
			ln.x += it.w;
			ln.content = 1;
		Iatomic =>
			k := it.box;
			layatomic(l, k, cw);
			w := k.ml + k.w + k.mr;
			if(ln.content && ln.x + real w > real ln.avail + 0.01)  {
				lines = endline(f, ln, x0, first, 0) :: lines;
				first = 0;
				ln = newline(f, ln, opened);
			}
			while(!ln.content && ln.x + real w > real ln.avail + 0.01 && movedown(f, ln))
				;
			fr := ref Frag(Fatomic, ir(ln.x) + k.ml, 0, k.w, k.h, 0, k, nil, nil, 0, 0, 0, 0, it.level);
			ln.frags = fr :: ln.frags;
			ln.x += real w;
			ln.content = 1;
		Ifloat =>
			if(!ln.content || real floatwidth(it.box, cw) <= real ln.avail - ln.x + 0.01) {
				# on this line: at its top, beside what is on it already
				# (CSS 2.2 §9.5.1 rules 4 and 7)
				oldleft := ln.left;
				placefloat(l, it.box, fc, ox + x0, oy + f.y, cw, f.ch, ox, oy);
				edgesat(f, ln);
				if(ln.left > oldleft && ln.content) {
					# a left float: the line's content moves right past it
					d := ln.left - oldleft;
					for(fl := ln.frags; fl != nil; fl = tl fl)
						(hd fl).x += d;
					ln.x += real d;
					r: list of (ref Box, real, int, int);
					for(ol := ln.open; ol != nil; ol = tl ol) {
						(ob, ostart, ofirst, olevel) := hd ol;
						r = (ob, ostart + real d, ofirst, olevel) :: r;
					}
					for(ln.open = nil; r != nil; r = tl r)
						ln.open = hd r :: ln.open;
				}
			} else
				ln.floats = it.box :: ln.floats;	# after this line
		Iabs =>
			if(it.box.st.wasinline) {
				# an inline-level box's static position is where it
				# would have been on the line: a fragment of no width
				# marks the place through alignment and reordering
				mark := ref Frag(Ftext, ir(ln.x), 0, 0, 0, 0, it.box, "", face(it.box.st), 0, 0, 0, 0, it.level);
				ln.frags = mark :: ln.frags;
				l.pending = ref Abs(it.box, cbof(l, it.box), b, x0 + ir(ln.x), f.y, mark, b.st.dirrtl) :: l.pending;
			} else	# a block-level one's is the start of the line
				l.pending = ref Abs(it.box, cbof(l, it.box), b, staticx(b), f.y, nil, b.st.dirrtl) :: l.pending;
		Ibreak =>
			ln.content = 1;
			lines = endline(f, ln, x0, first, 1) :: lines;
			first = 0;
			ln = newline(f, ln, opened);
			ln.content = 0;
			if(tl il != nil)
				ln.para = (hd tl il).para;	# the next paragraph's level
		}
	}
	# a last line of nothing but white space and empty inline boxes is
	# a phantom: no height (the inline boxes' edges were content above)
	if(ln.content)
		lines = endline(f, ln, x0, first, 1) :: lines;
	else {
		placepending(f, ln);
		for(fl := ln.frags; fl != nil; fl = tl fl)
			(hd fl).x += x0;	# the marks of absolutes on a phantom line, which is never aligned
	}
	a := array[len lines] of ref Line;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd lines;
		lines = tl lines;
	}
	b.lines = a;
	return f.y - b.bt - b.pt;
}

endline(f: ref Ifc, ln: ref Ln, x0, first, forced: int): ref Line
{
	line := finish(f.l, f.b, ln, f.y, x0, first, forced);
	f.y += line.h;
	placepending(f, ln);
	return line;
}

collapsible(st: ref St): int
{
	ws := st.whitespace;
	return ws == Style->Wnormal || ws == Style->Wnowrap || ws == Style->Wpreline;
}

prevnowrap(ln: ref Ln): int
{
	# no break between two pieces of nowrap text with no space between
	if(ln.frags == nil)
		return 0;
	f := hd ln.frags;
	return f.kind == Ftext && f.box != nil && f.box.kind != Kinline && f.text != " " &&
		(f.box.st.whitespace == Style->Wnowrap || f.box.st.whitespace == Style->Wpre) && f.text[len f.text-1] != ' ';
}

removebox(l: list of ref Box, b: ref Box): list of ref Box
{
	r: list of ref Box;
	for(; l != nil; l = tl l)
		if(hd l != b)
			r = hd l :: r;
	o: list of ref Box;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

newline(f: ref Ifc, old: ref Ln, opened: list of ref Box): ref Ln
{
	ln := ref Ln(old.para, nil, 0.0, f.cw, 0, 0, nil, 0.0, nil);
	linestart(f, ln);
	# inline boxes still open continue on the new line
	r: list of ref Box;
	for(l := opened; l != nil; l = tl l)
		r = hd l :: r;
	for(; r != nil; r = tl r)
		ln.open = (hd r, ln.x, 0, -1) :: ln.open;
	return ln;
}

splitword(it: ref Item, avail: real): (ref Item, ref Item)
{
	s := it.text;
	w := 0.0;
	for(k := 0; k < len s - 1; k++) {
		cw := it.face.width(s[k:k+1]);
		if(w + cw > avail && k > 0)
			break;
		w += cw;
	}
	if(k == 0)
		k = 1;
	h := ref *it;
	h.text = s[0:k];
	h.w = it.face.width(h.text);
	t := ref *it;
	t.text = s[k:];
	t.w = it.face.width(t.text);
	return (h, t);
}

textfrag(ln: ref Ln, it: ref Item): ref Frag
{
	return ref Frag(Ftext, ir(ln.x), 0, ir(it.w), 0, 0, it.box, it.text, it.face, 0, 0, it.deco, it.decocolor, it.level);
}

# close an inline box's fragment on this line
span(ln: ref Ln, b: ref Box, last: int): ref Frag
{
	x := 0.0;
	first := 0;
	level := -1;
	r: list of (ref Box, real, int, int);
	for(l := ln.open; l != nil; l = tl l) {
		(ob, ox, ofirst, olevel) := hd l;
		if(ob == b) {
			x = ox;
			first = ofirst;
			level = olevel;
		} else
			r = hd l :: r;
	}
	ln.open = nil;
	for(; r != nil; r = tl r)
		ln.open = hd r :: ln.open;
	return ref Frag(Fspan, ir(x), 0, ir(ln.x) - ir(x), 0, 0, b, nil, nil, first, last, 0, 0, level);	# ends where the next content starts
}

lineheight(st: ref St, f: ref Typeface): real
{
	case st.lineheight.kind {
	Style->Lnum =>
		return st.lineheight.px * st.fontsize;
	Style->Lpx =>
		return st.lineheight.px;
	}
	return f.normal;
}

# Finish a line: drop trailing spaces, close open inline boxes, then
# align vertically (baselines, line-height) and horizontally.
finish(l: ref L, b: ref Box, ln: ref Ln, y, x0, first, forced: int): ref Line
{
	# trailing collapsible white space hangs; so does preserved
	# white space at the end of a line (white-space: pre-wrap), which
	# keeps its width but takes no part in alignment (Text 3 §4.1.3)
	hanging: list of ref Frag;
	for(fl := ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan)
			continue;
		if(f.kind == Ftext && f.text == " " && collapsible(f.box.st)) {
			ln.x -= real f.w;
			f.w = 0;
			continue;
		}
		if(f.kind == Ftext && isblankrun(f.text) && f.box.st.whitespace == Style->Wprewrap && !forced) {
			ln.x -= real f.w;
			hanging = f :: hanging;
			continue;
		}
		break;
	}
	for(; ln.open != nil; )
		ln.frags = span(ln, (hd ln.open).t0, 0) :: ln.frags;
	frags := array[len ln.frags] of ref Frag;
	i := len frags - 1;
	for(fl = ln.frags; fl != nil; fl = tl fl)
		frags[i--] = hd fl;

	# vertical: each fragment's extent above and below the baseline
	sf := face(b.st);
	slh := lineheight(b.st, sf);
	shl := (slh - sf.ascent - sf.descent)/2.0;
	above := sf.ascent + shl;
	below := sf.descent + shl;
	if(!ln.content && !forced) {
		above = 0.0;
		below = 0.0;
	}
	# An aligned subtree (a top- or bottom-aligned inline box and all
	# it holds) is placed as one: its extent above and below its
	# baseline is what touches the line's edge, and what is inside
	# keeps its place relative to it (CSS 2.2 §10.8.1).
	subtrees: list of (ref Box, real, real);	# (box, above, below)
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		(a, d, shift, nil, anchor) := fragmetrics(f, b, sf);
		f.base = ir(shift);
		if(anchor != nil) {
			subtrees = extend(subtrees, anchor, a - shift, d + shift);
			continue;
		}
		if(a - shift > above)
			above = a - shift;
		if(d + shift > below)
			below = d + shift;
	}
	h := ir(above + below);
	# top- and bottom-aligned things may make the line taller
	for(sl := subtrees; sl != nil; sl = tl sl) {
		(nil, sa, sd) := hd sl;
		if(ir(sa + sd) > h)
			h = ir(sa + sd);
	}
	base := ir(above);
	line := ref Line(y, h, y + base, frags);
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		(a, d, shift, va, anchor) := fragmetrics(f, b, sf);
		fb := real line.base + shift;
		if(anchor != nil) {
			(sa, sd) := extent(subtrees, anchor);
			case va {
			Style->VAtop =>
				fb = real y + sa + shift;
			Style->VAbottom =>
				fb = real (y + h) - sd + shift;
			}
		}
		case f.kind {
		Ftext =>
			f.base = ir(fb);
			f.y = ir(fb - f.face.ascent);
			f.h = ir(f.face.ascent + f.face.descent);
		Fatomic =>
			k := f.box;
			f.y = ir(fb) - k.base + k.mt;
			k.y = f.y;
		Fspan =>
			k := f.box;
			fc := face(k.st);
			f.base = ir(fb);
			f.y = ir(fb - fc.ascent) - k.pt - k.bt;
			f.h = ir(fc.ascent + fc.descent) + k.pt + k.bt + k.pb + k.bb;
		}
	}
	# horizontal alignment
	extra := real ln.avail - ln.x;
	align := b.st.align;
	if(forced && align == Style->Ajustify)
		align = b.st.alignlast;
	off := 0.0;
	case align {
	Style->Aright or Style->Aend =>
		off = extra;
	Style->Acenter =>
		off = extra/2.0;
	Style->Ajustify =>
		# only the spaces after the last tab expand: the tab stops
		# before it must stay where they are (CSS Text 3 §7.3)
		from := 0;
		nsp := 0;
		for(i = 0; i < len frags; i++) {
			f := frags[i];
			if(f.kind != Ftext)
				continue;
			if(f.text == "\t") {
				from = i;
				nsp = 0;
			} else if(f.text == " " && f.w > 0 && !ishanging(f, hanging))
				nsp++;
		}
		if(!forced && nsp > 0 && extra > 0.0) {
			per := extra / real nsp;
			acc := 0.0;
			for(i = from; i < len frags; i++) {
				f := frags[i];
				f.x += ir(acc);
				if(f.kind == Ftext && f.text == " " && f.w > 0 && !ishanging(f, hanging)) {
					acc += per;
					f.w += ir(per);
				}
			}
		}
	}
	if(ln.para % 2 == 1 && align == Style->Astart)
		off = extra;
	if(off < 0.0)
		off = 0.0;
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		f.x += x0 + ir(off);
	}
	relativeinlines(frags, ln.avail);
	hw := 0;
	for(hl := hanging; hl != nil; hl = tl hl) {	# set aside while the rest is ordered
		hw += (hd hl).w;
		(hd hl).w = 0;
	}
	reorderline(frags, ln.para);
	if(hanging != nil) {
		# then past the line's end: the right in a left-to-right paragraph,
		# the left in a right-to-left one
		lo := 1 << 30;
		hi := -(1 << 30);
		for(i = 0; i < len frags; i++) {
			f := frags[i];
			if(f.kind == Fspan || ishanging(f, hanging))
				continue;
			if(f.x < lo)
				lo = f.x;
			if(f.x + f.w > hi)
				hi = f.x + f.w;
		}
		if(hi < lo) {
			lo = x0 + ir(off);
			hi = lo;
		}
		for(hl = hanging; hl != nil; hl = tl hl) {
			f := hd hl;
			f.w = ir(f.face.width(f.text));
			if(ln.para % 2 == 1) {
				lo -= f.w;
				f.x = lo;
			} else {
				f.x = hi;
				hi += f.w;
			}
		}
	}
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		if(f.kind == Fatomic) {
			f.box.x = f.x;
			relative(f.box, ln.avail, -1);
		}
	}
	return line;
}

# position: relative on an inline box moves its fragments and what
# they hold (CSS 2.2 §9.4.3); the line is laid out as if it were
# static.  Membership is by the fragments' places before any move, so
# that a box inside a moved box moves with it and then by its own.
relativeinlines(frags: array of ref Frag, cbw: int)
{
	n := len frags;
	ox := array[n] of int;
	for(i := 0; i < n; i++)
		ox[i] = frags[i].x;
	for(i = 0; i < n; i++) {
		f := frags[i];
		if(f.kind != Fspan)
			continue;
		st := f.box.st;
		if(st.position != Style->Prelative && st.position != Style->Psticky)
			continue;
		dx := 0;
		dy := 0;
		if(st.left.kind != Style->Lauto)
			dx = res(st.left, cbw);
		else if(st.right.kind != Style->Lauto)
			dx = -res(st.right, cbw);
		if(st.top.kind != Style->Lauto && st.top.pct == 0.0)
			dy = ir(st.top.px);
		else if(st.bottom.kind != Style->Lauto && st.bottom.pct == 0.0)
			dy = -ir(st.bottom.px);
		if(dx == 0 && dy == 0)
			continue;
		for(k := 0; k < n; k++) {
			g := frags[k];
			if(g == f || g.kind == Fspan)
				continue;
			if(ox[k] >= ox[i] && ox[k] + g.w <= ox[i] + f.w)
				shiftfrag(g, dx, dy);
		}
		shiftfrag(f, dx, dy);
	}
}

shiftfrag(g: ref Frag, dx, dy: int)
{
	g.x += dx;
	g.y += dy;
	g.base += dy;
	if(g.kind == Fatomic)
		g.box.y += dy;
}

# ---- bidi (UAX #9 through CSS Writing Modes 3 §2) ----

# The items of a block container's inline content with their bidi
# levels resolved: the whole content is one paragraph (forced breaks
# separate paragraphs), inline boxes with unicode-bidi add the
# controls the property stands for, and a word whose characters come
# out at different levels is split so that each item has one.  Also
# the paragraph's level.  Content with nothing right-to-left in it is
# left as it is.
# Cursive text shaped across an inline box's edge (CSS Text 3 §8.3):
# where a word ends and the next begins with nothing between them but
# edges of no width, each gets a zero width joiner on that side, so
# the font joins them as if they were one word.
joinruns(items: list of ref Item)
{
	if(bidi == nil)
		return;
	prev: ref Item;	# the word before, unless something with width intervened
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		case it.kind {
		Iword =>
			if(prev != nil && len prev.text > 0 && len it.text > 0 && joins(prev.text[len prev.text - 1], it.text[0])) {
				prev.text[len prev.text] = 16r200D;
				rewidth(prev);
				z := "";
				z[0] = 16r200D;
				it.text = z + it.text;
				rewidth(it);
			}
			prev = it;
		Iopen or Iclose =>
			if(it.w > 0.0)
				prev = nil;
		* =>
			prev = nil;
		}
	}
}

# does a letter a, followed by b, join with it?
joins(a, b: int): int
{
	ja := bidi->joining(a);
	jb := bidi->joining(b);
	return (ja == Bidi->JD || ja == Bidi->JL || ja == Bidi->JC) && (jb == Bidi->JD || jb == Bidi->JR || jb == Bidi->JC);
}

rewidth(it: ref Item)
{
	n := 0;
	for(i := 0; i < len it.text; i++)
		if(it.text[i] != 16r200D)
			n++;
	it.w = it.face.width(it.text) + it.box.st.letterspacing * real n;
}

bidiitems(b: ref Box, items: list of ref Item): (list of ref Item, int)
{
	st := b.st;
	if(bidi == nil)
		return (items, 0);
	need := st.dirrtl || st.unicodebidi == Style->UBplaintext;
	for(l := items; l != nil && !need; l = tl l) {
		it := hd l;
		case it.kind {
		Iword or Ispace =>
			for(i := 0; i < len it.text; i++)
				if(it.text[i] >= 16r590) {
					need = 1;
					break;
				}
		Iopen =>
			if(it.box.st.unicodebidi != Style->UBnormal)
				need = 1;
		}
	}
	if(!need)
		return (items, 0);
	# the paragraph's characters, and where each item's are
	n := 0;
	for(l = items; l != nil; l = tl l)
		n += len (hd l).text + 4;
	text := array[n] of int;
	n = 0;
	starts: list of int;	# reversed; one per item
	for(l = items; l != nil; l = tl l) {
		it := hd l;
		starts = n :: starts;
		case it.kind {
		Iword or Ispace =>
			if(it.text == "")
				text[n++] = 16r200B;
			for(i := 0; i < len it.text; i++)
				text[n++] = it.text[i];
		Iatomic =>
			text[n++] = 16rFFFC;
		Ibreak =>
			text[n++] = 16r2029;
		Iopen =>
			n = controls(text, n, it.box.st, 1);
		Iclose =>
			n = controls(text, n, it.box.st, 0);
		}
	}
	# each paragraph (forced breaks separate them) resolved on its own:
	# under plaintext each takes its direction from its own first
	# strong character (P2, P3)
	dir := st.dirrtl;
	if(st.unicodebidi == Style->UBplaintext)
		dir = -1;
	lev := array[n] of int;
	plev := array[n] of int;	# the paragraph level at each character
	para := 0;
	for(ps := 0; ps < n; ) {
		pe := ps;
		while(pe < n && text[pe] != 16r2029)
			pe++;
		if(pe < n)
			pe++;	# the separator belongs to its paragraph
		seg := text[ps:pe];
		sl := bidi->levels(seg, dir);
		pl := dir;
		if(pl < 0) {
			pl = bidi->basedir(seg);
			if(pl < 0)
				pl = 0;
		}
		for(i := ps; i < pe; i++) {
			lev[i] = sl[i - ps];
			plev[i] = pl;
		}
		if(ps == 0)
			para = pl;
		ps = pe;
	}
	# back to items, words split where their level changes
	sa := array[len starts] of int;
	for(i := len sa - 1; starts != nil; starts = tl starts)
		sa[i--] = hd starts;
	r: list of ref Item;
	i = 0;
	for(l = items; l != nil; l = tl l) {
		it := hd l;
		s := sa[i++];
		if(it.kind == Iword && len it.text > 1) {
			a := 0;
			while(a < len it.text) {
				e := a + 1;
				while(e < len it.text && lev[s + e] == lev[s + a])
					e++;
				piece := it;
				if(a > 0 || e < len it.text) {
					piece = ref *it;
					piece.text = it.text[a:e];
					piece.w = partwidth(it, a, e);
					if(a > 0)
						piece.nowrap = 1;	# still one word: no break inside it
				}
				piece.level = lev[s + a];
				piece.para = plev[s + a];
				r = piece :: r;
				a = e;
			}
			continue;
		}
		if(s < n) {
			it.level = lev[s];
			it.para = plev[s];
		} else {
			it.level = para;
			it.para = para;
		}
		r = it :: r;
	}
	out: list of ref Item;
	for(; r != nil; r = tl r)
		out = hd r :: out;
	return (out, para);
}

# the width of a word's characters [a:e), letter-spacing included
partwidth(it: ref Item, a, e: int): real
{
	if(a == 0 && e == len it.text)
		return it.w;
	fw := it.face.width(it.text);
	pw := it.face.width(it.text[a:e]);
	extra := it.w - fw;	# letter-spacing over the word
	if(extra != 0.0 && len it.text > 0)
		pw += extra * real (e - a) / real len it.text;
	return pw;
}

# the bidi control characters an inline box's unicode-bidi stands for
# at its start (open) or end, into text at n
controls(text: array of int, n: int, st: ref St, open: int): int
{
	case st.unicodebidi {
	Style->UBembed =>
		if(open) {
			if(st.dirrtl)
				text[n++] = 16r202B;	# RLE
			else
				text[n++] = 16r202A;	# LRE
		} else
			text[n++] = 16r202C;	# PDF
	Style->UBisolate =>
		if(open) {
			if(st.dirrtl)
				text[n++] = 16r2067;	# RLI
			else
				text[n++] = 16r2066;	# LRI
		} else
			text[n++] = 16r2069;	# PDI
	Style->UBoverride =>
		if(open) {
			if(st.dirrtl)
				text[n++] = 16r202E;	# RLO
			else
				text[n++] = 16r202D;	# LRO
		} else
			text[n++] = 16r202C;
	Style->UBisolateoverride =>
		if(open) {
			text[n++] = 16r2068;	# FSI
			if(st.dirrtl)
				text[n++] = 16r202E;
			else
				text[n++] = 16r202D;
		} else {
			text[n++] = 16r202C;
			text[n++] = 16r2069;
		}
	Style->UBplaintext =>
		if(open)
			text[n++] = 16r2068;	# FSI
		else
			text[n++] = 16r2069;
	}
	return n;
}

# L1 and L2 for a line: its text and atomic fragments, in logical
# order with their levels, take their visual order; trailing white
# space takes the paragraph level.  Inline boxes' fragments then
# cover what they hold.
# a thing on a line with a place in the visual order: a text or
# atomic fragment, or the start or end edge (margin, border, padding)
# of an inline box's fragment
Vis: adt {
	frag:	ref Frag;
	edge:	int;		# 0 content, 1 start edge, 2 end edge
	logx:	int;		# logical place
	x, w:	int;		# visual place, and width
	level:	int;
};

reorderline(frags: array of ref Frag, para: int)
{
	any := para % 2;
	for(i := 0; i < len frags; i++)
		if(frags[i].kind != Fspan && frags[i].level % 2 == 1)
			any = 1;
	if(!any)
		return;
	# The content in logical order, without the edges of the inline
	# boxes: those go back in afterwards, at the ends of each box.  An
	# isolate's controls are there, at the level outside it, so that
	# its content and its neighbours are reversed as separate runs.
	vl: list of ref Vis;
	n := 0;
	x0 := 1 << 30;
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		if(f.x < x0)
			x0 = f.x;
		if(f.kind == Fspan) {
			if(f.level < 0 || !isolating(f.box.st.unicodebidi))
				continue;
			if(f.first) {
				vl = ref Vis(f, 1, f.x, f.x, 0, f.level) :: vl;
				n++;
			}
			if(f.last) {
				vl = ref Vis(f, 2, f.x + f.w, f.x + f.w, 0, f.level) :: vl;
				n++;
			}
			continue;
		}
		vl = ref Vis(f, 0, f.x, f.x, f.w, f.level) :: vl;
		n++;
	}
	if(n == 0)
		return;
	v := array[n] of ref Vis;
	for(k := n - 1; vl != nil; vl = tl vl)
		v[k--] = hd vl;
	for(i = 1; i < n; i++)
		for(j := i; j > 0 && visbefore(v[j], v[j-1]); j--)
			(v[j], v[j-1]) = (v[j-1], v[j]);
	lev := array[n] of int;
	for(i = 0; i < n; i++)
		lev[i] = v[i].level;
	# L1: trailing white space at the paragraph level
	for(k = n - 1; k >= 0 && (v[k].edge != 0 || v[k].frag.kind == Ftext && isblankrun(v[k].frag.text)); k--)
		lev[k] = para;
	order := bidi->reorder(lev);
	# each one's room is up to the next one's logical place, less any
	# edges between: the rounding of the logical positions is kept
	room := array[n] of int;
	for(k = 0; k < n; k++) {
		room[k] = v[k].w;
		if(k + 1 < n)
			room[k] = v[k+1].logx - v[k].logx - edgesin(frags, v[k].logx + v[k].w, v[k+1].logx);
	}
	x := x0;
	for(k = 0; k < n; k++) {
		e := v[order[k]];
		e.x = x;
		x += room[order[k]];
	}
	# An inline box covers its content wherever that is now.  Its start
	# edge goes at the line-left end of that if the box is left-to-right,
	# at the line-right end if not; the end edge at the other.  Inner
	# boxes first (the fragments come in closing order), so that an
	# outer box covers their edges too.
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		if(f.kind != Fspan)
			continue;
		lo := 1 << 30;
		hi := -(1 << 30);
		for(k = 0; k < n; k++) {
			e := v[k];
			if(oldin(e, f)) {
				if(e.x < lo)
					lo = e.x;
				if(e.x + e.w > hi)
					hi = e.x + e.w;
			}
		}
		if(hi < lo)
			continue;
		b := f.box;
		el := 0;
		er := 0;
		if(leftedge(f))
			el = b.ml + b.bl + b.pl;
		if(rightedge(f))
			er = b.mr + b.br + b.pr;
		if(el > 0) {
			for(k = 0; k < n; k++)
				if(v[k].x >= lo)
					v[k].x += el;
			v = append(v, ref Vis(f, 1, f.x, lo, el, 0));
			n++;
			hi += el;
		}
		if(er > 0) {
			for(k = 0; k < n; k++)
				if(v[k].x >= hi)
					v[k].x += er;
			v = append(v, ref Vis(f, 2, f.x + f.w - er, hi, er, 0));
			n++;
		}
		f.x = lo;
		f.w = hi + er - lo;
	}
	for(k = 0; k < n; k++)
		if(v[k].edge == 0)
			v[k].frag.x = v[k].x;
}

isolating(ub: int): int
{
	return ub == Style->UBisolate || ub == Style->UBisolateoverride || ub == Style->UBplaintext;
}

visbefore(a, b: ref Vis): int
{
	if(a.logx != b.logx)
		return a.logx < b.logx;
	# at the same place: a closing control, then an opening one, then content
	return visrank(a) < visrank(b);
}

visrank(e: ref Vis): int
{
	case e.edge {
	2 =>	return 0;
	1 =>	return 1;
	}
	return 2;
}

# the inline box edges whose logical place lies within [a, b]
edgesin(frags: array of ref Frag, a, b: int): int
{
	w := 0;
	for(i := 0; i < len frags; i++) {
		f := frags[i];
		if(f.kind != Fspan)
			continue;
		k := f.box;
		if(leftedge(f) && (e := k.ml + k.bl + k.pl) > 0 && 2*f.x + e >= 2*a && 2*f.x + e <= 2*b)
			w += e;
		if(rightedge(f) && (e = k.mr + k.br + k.pr) > 0 && 2*(f.x + f.w) - e >= 2*a && 2*(f.x + f.w) - e <= 2*b)
			w += e;
	}
	return w;
}

# Which physical edges an inline box's fragment carries: the box's
# start edge is on its first fragment and its end edge on its last,
# and in a right-to-left box the start is the right (Writing Modes
# §2.2); the sides themselves (left border, right padding) stay put.
leftedge(f: ref Frag): int
{
	if(f.box.st.dirrtl)
		return f.last;
	return f.first;
}

rightedge(f: ref Frag): int
{
	if(f.box.st.dirrtl)
		return f.first;
	return f.last;
}

append(v: array of ref Vis, e: ref Vis): array of ref Vis
{
	a := array[len v + 1] of ref Vis;
	a[0:] = v;
	a[len v] = e;
	return a;
}

# was content e within the inline box fragment f, before anything moved?
oldin(e: ref Vis, f: ref Frag): int
{
	return e.w > 0 && e.logx >= f.x && e.logx + e.w <= f.x + f.w;	# a collapsed space is nowhere
}

ishanging(f: ref Frag, l: list of ref Frag): int
{
	for(; l != nil; l = tl l)
		if(hd l == f)
			return 1;
	return 0;
}

isblankrun(s: string): int
{
	for(i := 0; i < len s; i++)
		if(!isspace(s[i]))
			return 0;
	return 1;
}

# a right-to-left run is drawn with its characters reversed, each
# mirrored where Unicode says (brackets)
# a right-to-left run's text as drawn: still in logical order (the
# font draws it from the right, shaped as written), brackets mirrored
visual(f: ref Frag): string
{
	if(f.level % 2 == 0 || bidi == nil)
		return f.text;
	s := f.text;
	r := "";
	for(i := 0; i < len s; i++)
		r[len r] = bidi->mirror(s[i]);
	return r;
}

# A fragment's ascent and descent around its baseline, half-leading
# included; how far its baseline is shifted down from the line's; and
# whether it is aligned to the line box instead (VAtop, VAbottom).
#
# The shift is the vertical-align of the inline box the fragment is
# (or, for a text run, is in), plus that of every inline box enclosing
# it up to the block b, each relative to its parent (CSS 2.2 §10.8.1):
# the glyphs of <sup> move with it.  A box aligned to the line box
# ends the walk; what it holds is shifted with respect to it.
# the extents of aligned subtrees, by their box
extend(l: list of (ref Box, real, real), k: ref Box, a, d: real): list of (ref Box, real, real)
{
	r: list of (ref Box, real, real);
	found := 0;
	for(; l != nil; l = tl l) {
		(kb, ka, kd) := hd l;
		if(kb == k) {
			found = 1;
			if(a > ka)
				ka = a;
			if(d > kd)
				kd = d;
		}
		r = (kb, ka, kd) :: r;
	}
	if(!found)
		r = (k, a, d) :: r;
	return r;
}

extent(l: list of (ref Box, real, real), k: ref Box): (real, real)
{
	for(; l != nil; l = tl l) {
		(kb, ka, kd) := hd l;
		if(kb == k)
			return (ka, kd);
	}
	return (0.0, 0.0);
}

# the fifth value is the top- or bottom-aligned inline box the fragment
# is in (or is), with shift then relative to that box's baseline
fragmetrics(f: ref Frag, b: ref Box, sf: ref Typeface): (real, real, real, int, ref Box)
{
	st := f.box.st;
	a, d: real;
	case f.kind {
	Ftext or Fspan =>
		fc := f.face;
		if(fc == nil)
			fc = face(st);
		lh := lineheight(st, fc);
		hl := (lh - fc.ascent - fc.descent)/2.0;
		a = fc.ascent + hl;
		d = fc.descent + hl;
	Fatomic =>
		k := f.box;
		a = real (k.base);
		d = real (k.mt + k.h + k.mb - k.base);
	}
	k := f.box;
	if(f.kind == Ftext && k.kind == Ktext)
		k = k.parent;	# a text run aligns as its inline box does
	shift := 0.0;
	va := Style->VAbaseline;
	anchor: ref Box;
	ka := a;
	kd := d;
	for(; k != nil && k != b; k = k.parent) {
		if(k != f.box && k.kind != Kinline)
			break;
		kva := k.st.valign;
		if(kva == Style->VAtop || kva == Style->VAbottom) {
			va = kva;
			anchor = k;
			break;
		}
		pf := sf;
		if(k.parent != nil && k.parent != b)
			pf = face(k.parent.st);
		shift += vshift(k.st, kva, ka, kd, pf);
		if(k.parent != nil && k.parent != b && k.parent.kind == Kinline)
			(ka, kd) = boxmetrics(k.parent);
	}
	return (a, d, shift, va, anchor);
}

# an inline box's ascent and descent around its baseline, half-leading included
boxmetrics(k: ref Box): (real, real)
{
	fc := face(k.st);
	lh := lineheight(k.st, fc);
	hl := (lh - fc.ascent - fc.descent)/2.0;
	return (fc.ascent + hl, fc.descent + hl);
}

# how far a box with ascent a and descent d is shifted down from its
# parent's baseline, by its vertical-align; parent is the parent's face
vshift(st: ref St, va: int, a, d: real, parent: ref Typeface): real
{
	case va {
	Style->VAsub =>
		return parent.size * 0.2;
	Style->VAsuper =>
		return -parent.size * 0.35;
	Style->VAmiddle =>
		# the middle of the box at half the parent's x-height
		return (a - d)/2.0 - parent.size * 0.27;
	Style->VAtexttop =>
		return a - parent.ascent;
	Style->VAtextbottom =>
		return parent.descent - d;
	Style->VAlen =>
		return -st.valignlen.px;
	}
	return 0.0;
}

# Lay out an atomic inline (inline-block, inline replaced, inline flex...).
layatomic(l: ref L, k: ref Box, cbw: int)
{
	edges(k, cbw);
	w := specw(k, k.st.width, cbw);
	if(w < 0) {
		if(k.kind == Kreplaced) {
			(rw, nil) := replacedsize(k, cbw, -1);
			w = rw + hextra(k);
		} else {
			(mn, mx) := intrinsic(k);
			w = fit(mn, mx, cbw) - mgs(k);
		}
	}
	k.w = clampw(k, w, cbw);
	if(k.st.ml.kind == Style->Lauto)
		k.ml = 0;
	if(k.st.mr.kind == Style->Lauto)
		k.mr = 0;
	layblock(l, k, cbw, -1, nil, 0, 0);
	# baseline: the last line box's, else the bottom margin edge
	k.base = k.mt + k.h;
	if(k.kind == Ktable || k.kind == Kflex || k.kind == Kgrid) {
		# an inline table's is its first row's (CSS 2.2 §10.8.1); a flex
		# or grid container's its first item's (Flexbox §8.5, Grid §10.1)
		(ok, by) := firstbaseline(k);
		if(ok)
			k.base = k.mt + by;
	} else if(k.kind != Kreplaced && k.st.overflowy == Style->Ovisible) {
		(ok, by) := lastbaseline(k);
		if(ok)
			k.base = k.mt + by;
	}
}

firstbaseline(b: ref Box): (int, int)
{
	if(b.lines != nil && len b.lines > 0)
		return (1, b.lines[0].base);
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(k.inl || k.st.display == Style->Dtablecaption)
			continue;
		(ok, by) := firstbaseline(k);
		if(ok)
			return (1, k.y + by);
	}
	return (0, 0);
}

lastbaseline(b: ref Box): (int, int)
{
	if(b.lines != nil && len b.lines > 0)
		return (1, b.lines[len b.lines - 1].base);
	for(i := len b.kids - 1; i >= 0; i--) {
		k := b.kids[i];
		if(k.inl)
			continue;
		(ok, by) := lastbaseline(k);
		if(ok)
			return (1, k.y + by);
	}
	return (0, 0);
}

# ---- caches ----

Nfacecache: con 256;
faces: array of list of (int, ref Typeface);

face(st: ref St): ref Typeface
{
	h := st.sid % Nfacecache;
	if(h < 0)
		h = -h;
	for(l := faces[h]; l != nil; l = tl l)
		if((hd l).t0 == st.sid)
			return (hd l).t1;
	f := fonts->face(st.family, st.weight, st.fontstyle != Style->FSnormal, st.fontsize);
	if(f != nil && st.nokern) {
		f = ref *f;
		f.nokern = 1;
	}
	faces[h] = (st.sid, f) :: faces[h];
	return f;
}

# ---- painting (CSS 2.2 Appendix E, simplified to tree order) ----

Ncolors: con 256;
colors: array of list of (int, ref Image);

# An image of one colour, for filling.  Colours with alpha become
# premultiplied, as draw(3) composites.
colorimg(c: int): ref Image
{
	h := (c ^ (c >> 13)) & (Ncolors-1);
	if(h < 0)
		h = -h;
	for(l := colors[h]; l != nil; l = tl l)
		if((hd l).t0 == c)
			return (hd l).t1;
	a := c & 255;
	pc := c;
	if(a != 255) {
		r := ((c >> 24) & 255) * a / 255;
		g := ((c >> 16) & 255) * a / 255;
		b := ((c >> 8) & 255) * a / 255;
		pc = (r << 24) | (g << 16) | (b << 8) | a;
	}
	img := display.newimage(Rect((0, 0), (1, 1)), Draw->RGBA32, 1, pc);
	colors[h] = (c, img) :: colors[h];
	return img;
}

visible(c: int): int
{
	return (c & 255) != 0;
}

height(root: ref Box): int
{
	return root.y + root.h + root.mb;
}

viewport: Rect;	# being painted: what background-attachment: fixed is relative to
oncanvas := 0;	# painting the root's background over the canvas: clipped to the viewport, not the box
scrolled: Point;	# how far the document is scrolled in it; fixed boxes do not move

paint(root: ref Box, dst: ref Image, origin: Point, clip: Rect)
{
	viewport = clip;
	scrolled = clip.min.sub(origin);
	oclip := dst.clipr;
	dst.clipr = clip;
	# the canvas takes the root's background, or else the body's
	bg := root.st.bgcolor;
	bgbox := root;
	if(!visible(bg) && root.st.bg == nil) {
		for(i := 0; i < len root.kids; i++)
			if(root.kids[i].node != 0) {
				bgbox = root.kids[i];
				bg = bgbox.st.bgcolor;
				break;
			}
	}
	dst.draw(clip, display.white, nil, (0, 0));
	if(visible(bg))
		dst.draw(clip, colorimg(bg), nil, (0, 0));
	if(bgbox.st.bg != nil) {
		# its images too, positioned as on the box, shown over the canvas
		r := Rect((origin.x + root.x, origin.y + root.y), (origin.x + root.x + root.w, origin.y + root.y + root.h));
		if(bgbox != root)
			r = Rect((r.min.x + bgbox.x, r.min.y + bgbox.y), (r.min.x + bgbox.x + bgbox.w, r.min.y + bgbox.y + bgbox.h));
		oncanvas = 1;
		for(i := len bgbox.st.bg - 1; i >= 0; i--)
			if(bgbox.st.bg[i].img != nil)
				paintbg(dst, bgbox, r, bgbox.st.bg[i]);
		oncanvas = 0;
	}
	painted = root;
	paintctx(dst, root, origin, clip, bgbox);
	painted = nil;
	dst.clipr = oclip;
}

# A layer of a stacking context: a positioned box to paint after (or,
# with a negative z-index, before) the context's flow content.
Lyr: adt {
	box:	ref Box;
	o:	Point;		# its parent's border-box origin
	z:	int;
	clip:	Rect;		# what the overflow of the boxes between it and the context allows
};

NOCLIP: con 1 << 29;
noclip := Rect((-NOCLIP, -NOCLIP), (NOCLIP, NOCLIP));

# Paint b as a stacking context (CSS 2.2 Appendix E, simplified): its
# background and borders, layers with negative z-index, its in-flow
# content, then layers with z-index auto or 0 in tree order, then the
# positive ones.  o is the origin of b's parent's border box.
paintctx(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	st := b.st;
	if(st.opacity == 0.0)
		return;
	if(st.opacity < 1.0 && b.kind != Ktext && b != translucent) {
		layer(dst, b, o, clip, canvasbg);
		return;
	}
	if(st.position == Style->Pfixed) {
		# laid out against the initial containing block; painted
		# against the viewport, whatever its ancestors clip
		o = o.add(scrolled);
		clip = viewport;
	}
	if(st.translated) {	# moved as drawn: its place in the flow is unchanged
		if(st.tfs != nil && b != warped) {
			warp(dst, b, o, clip, canvasbg);
			return;
		}
		o = o.add(Point(res(st.tx, b.w), res(st.ty, b.h)));
		intransform++;
	}
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	# A positioned box with z-index: auto is painted as a layer but is
	# not a stacking context: its positioned descendants are layers of
	# the context it is in, collected there (Appendix E).
	layers: list of ref Lyr;
	if(isctx(b))
		layers = sortlayers(collectlayers(b, r.min, noclip, nil));
	if(st.visibility == Style->Vvisible)
		paintself(dst, b, r, canvasbg);
	inner := innerclip(b, r, clip);
	for(l := layers; l != nil; l = tl l)
		if((hd l).z < 0)
			paintctx(dst, (hd l).box, (hd l).o, layerclip(inner, hd l), canvasbg);
	if(rectok(inner)) {
		oclip := dst.clipr;
		dst.clipr = inner;
		paintcontent(dst, b, r, inner, canvasbg);
		dst.clipr = oclip;
	}
	for(l = layers; l != nil; l = tl l)
		if((hd l).z >= 0)
			paintctx(dst, (hd l).box, (hd l).o, layerclip(inner, hd l), canvasbg);
	paintoutline(dst, b, r, clip);
	if(st.translated)
		intransform--;
}

intransform := 0;	# painting inside a transformed box: fixed backgrounds attach to it, not the viewport
warped: ref Box;	# the box being painted for its transform (into its own image)

# A box with a transform beyond translation (CSS Transforms 1): painted
# untransformed into an image of its own, which is then mapped onto dst
# through the transform's matrix about the transform-origin, one
# destination pixel at a time from the nearest source pixel.
warp(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	st := b.st;
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	# the matrix, about the origin: M = T(c) · F1 · F2 … · T(-c)
	cx := real r.min.x + st.tox.resolve(real b.w);
	cy := real r.min.y + st.toy.resolve(real b.h);
	m := array[] of {1.0, 0.0, 0.0, 1.0, 0.0, 0.0};	# a b c d e f: x' = a x + c y + e, y' = b x + d y + f
	for(i := 0; i < len st.tfs; i++) {
		t := st.tfs[i];
		f: array of real;
		case t.kind {
		Style->TFtranslate =>
			f = array[] of {1.0, 0.0, 0.0, 1.0, t.x.resolve(real b.w), t.y.resolve(real b.h)};
		Style->TFrotate =>
			(sn, cs) := (math->sin(t.v[0]), math->cos(t.v[0]));
			f = array[] of {cs, sn, -sn, cs, 0.0, 0.0};
		Style->TFscale =>
			f = array[] of {t.v[0], 0.0, 0.0, t.v[1], 0.0, 0.0};
		Style->TFskew =>
			f = array[] of {1.0, math->tan(t.v[1]), math->tan(t.v[0]), 1.0, 0.0, 0.0};
		Style->TFmatrix =>
			f = t.v;
		* =>
			continue;
		}
		m = mmul(m, f);
	}
	m = mmul(array[] of {1.0, 0.0, 0.0, 1.0, cx, cy}, mmul(m, array[] of {1.0, 0.0, 0.0, 1.0, -cx, -cy}));
	det := m[0]*m[3] - m[1]*m[2];
	if(math->fabs(det) < 1e-9)
		return;	# flattened to nothing
	# the box's picture, untransformed
	src := inkbounds(b, r);
	img := display.newimage(src, Draw->RGBA32, 0, Draw->Transparent);
	if(img == nil)
		return;
	outer := warped;
	warped = b;
	intransform++;
	paintctx(img, b, o, src, canvasbg);
	intransform--;
	warped = outer;
	# where it lands: the bounds of the mapped corners
	lo := Point(1 << 29, 1 << 29);
	hi := Point(-(1 << 29), -(1 << 29));
	for(k := 0; k < 4; k++) {
		px := real src.min.x;
		py := real src.min.y;
		if(k & 1)
			px = real src.max.x;
		if(k & 2)
			py = real src.max.y;
		qx := m[0]*px + m[2]*py + m[4];
		qy := m[1]*px + m[3]*py + m[5];
		lo = Point(min(lo.x, int math->floor(qx)), min(lo.y, int math->floor(qy)));
		hi = Point(max(hi.x, int math->ceil(qx)), max(hi.y, int math->ceil(qy)));
	}
	(dr, ok) := Rect(lo, hi).clip(clip);
	if(!ok || !rectok(dr))
		return;
	sw := src.dx();
	sh := src.dy();
	sp := array[sw*sh*4] of byte;
	img.readpixels(src, sp);
	dw := dr.dx();
	dh := dr.dy();
	dp := array[dw*dh*4] of { * => byte 0 };
	# the inverse, for each destination pixel's source
	ia := m[3]/det;
	ib := -m[1]/det;
	ic := -m[2]/det;
	id := m[0]/det;
	ie := -(ia*m[4] + ic*m[5]);
	iff := -(ib*m[4] + id*m[5]);
	for(y := 0; y < dh; y++) {
		dy := real (dr.min.y + y) + 0.5;
		for(x := 0; x < dw; x++) {
			dx := real (dr.min.x + x) + 0.5;
			sx := int math->floor(ia*dx + ic*dy + ie) - src.min.x;
			sy := int math->floor(ib*dx + id*dy + iff) - src.min.y;
			if(sx < 0 || sy < 0 || sx >= sw || sy >= sh)
				continue;
			si := (sy*sw + sx)*4;
			di := (y*dw + x)*4;
			dp[di:] = sp[si:si+4];
		}
	}
	out := display.newimage(dr, Draw->RGBA32, 0, Draw->Transparent);
	if(out == nil)
		return;
	out.writepixels(dr, dp);
	dst.draw(dr, out, nil, dr.min);
}

mmul(p, q: array of real): array of real
{
	return array[] of {
		p[0]*q[0] + p[2]*q[1], p[1]*q[0] + p[3]*q[1],
		p[0]*q[2] + p[2]*q[3], p[1]*q[2] + p[3]*q[3],
		p[0]*q[4] + p[2]*q[5] + p[4], p[1]*q[4] + p[3]*q[5] + p[5],
	};
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

# a layer's clip: the context's, and that of any overflow-clipping box
# between (a positioned box that is not a stacking context clips its
# absolutely positioned descendants all the same)
layerclip(inner: Rect, l: ref Lyr): Rect
{
	(c, nil) := inner.clip(l.clip);
	return c;
}

innerclip(b: ref Box, r, clip: Rect): Rect
{
	st := b.st;
	if(st.overflowx == Style->Ovisible && st.overflowy == Style->Ovisible)
		return clip;
	pr := Rect((r.min.x + b.bl, r.min.y + b.bt), (r.max.x - b.br, r.max.y - b.bb));
	(c, nil) := clip.clip(pr);
	return c;
}

# a box that is a layer of its stacking context rather than flow content
islayer(k: ref Box): int
{
	return (ispositioned(k) || k.st.translated) && k.kind != Ktext && k.kind != Kinline;
}

# a box that establishes a stacking context (CSS 2.2 §9.9.1, Position 3)
isctx(k: ref Box): int
{
	st := k.st;
	return k == painted || st.position == Style->Pfixed || st.opacity < 1.0 || st.translated ||
		ispositioned(k) && !st.zauto;
}

painted: ref Box;	# the root being painted
translucent: ref Box;	# the box whose opacity layer is being painted (into its own image)

# the layers of b's stacking context: positioned descendants, found
# without descending into layers or nested stacking contexts
collectlayers(b: ref Box, o: Point, clip: Rect, acc: list of ref Lyr): list of ref Lyr
{
	for(pl := revboxes(b.pos); pl != nil; pl = tl pl)
		acc = addlayer(hd pl, o, clip, acc);
	if(b.lines != nil) {
		for(i := 0; i < len b.lines; i++) {
			ln := b.lines[i];
			for(k := 0; k < len ln.frags; k++) {
				f := ln.frags[k];
				if(f.kind != Fatomic)
					continue;
				if(islayer(f.box))
					acc = addlayer(f.box, o, clip, acc);
				else if(f.box.st.opacity >= 1.0)
					acc = collectlayers(f.box, o.add(Point(f.box.x, f.box.y)), clipby(f.box, o, clip), acc);
			}
		}
		return floatlayers(b, o, clip, acc);
	}
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k) || k.inl)
			continue;	# painted from its containing block's pos list
		if(islayer(k))
			acc = addlayer(k, o, clip, acc);
		else if(k.st.opacity >= 1.0)
			acc = collectlayers(k, o.add(Point(k.x, k.y)), clipby(k, o, clip), acc);
	}
	return acc;
}

# clip narrowed by k's overflow, k's border box being at o
clipby(k: ref Box, o: Point, clip: Rect): Rect
{
	r := Rect((o.x + k.x, o.y + k.y), (o.x + k.x + k.w, o.y + k.y + k.h));
	return innerclip(k, r, clip);
}

# floats among inline content (in b, or in its inline boxes): not in
# the line boxes, but layers if positioned, and holding layers if not
floatlayers(b: ref Box, o: Point, clip: Rect, acc: list of ref Lyr): list of ref Lyr
{
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k))
			continue;
		if(k.kind == Kinline) {
			if(k.st.opacity > 0.0)
				acc = floatlayers(k, o, clip, acc);
		}
		else if(isfloat(k)) {
			if(islayer(k))
				acc = addlayer(k, o, clip, acc);
			else if(k.st.opacity >= 1.0)
				acc = collectlayers(k, o.add(Point(k.x, k.y)), clipby(k, o, clip), acc);
		}
	}
	return acc;
}

addlayer(k: ref Box, o: Point, clip: Rect, acc: list of ref Lyr): list of ref Lyr
{
	z := 0;
	if(!k.st.zauto)
		z = k.st.z;
	acc = ref Lyr(k, o, z, clip) :: acc;
	if(!isctx(k))	# its own layers belong to this context
		acc = collectlayers(k, o.add(Point(k.x, k.y)), clipby(k, o, clip), acc);
	return acc;
}

revboxes(l: list of ref Box): list of ref Box
{
	r: list of ref Box;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# in z order, tree order among equals (acc arrives reversed)
sortlayers(l: list of ref Lyr): list of ref Lyr
{
	n := len l;
	if(n == 0)
		return nil;
	a := array[n] of ref Lyr;
	for(i := n-1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	# by z-index, then document order: layers reach here by more than
	# one path (a containing block's pos list, the tree), and only the
	# document decides among equals
	for(i = 1; i < n; i++)
		for(j := i; j > 0 && before(a[j], a[j-1]); j--)
			(a[j], a[j-1]) = (a[j-1], a[j]);
	r: list of ref Lyr;
	for(i = n-1; i >= 0; i--)
		r = a[i] :: r;
	return r;
}

before(a, b: ref Lyr): int
{
	if(a.z != b.z)
		return a.z < b.z;
	return a.box.seq < b.box.seq;
}

paintself(dst: ref Image, b: ref Box, r: Rect, canvasbg: ref Box)
{
	if(b != canvasbg)
		paintbackground(dst, b, r);
	paintborders(dst, b, r);
}

paintcontent(dst: ref Image, b: ref Box, r, clip: Rect, canvasbg: ref Box)
{
	if(b.kind == Kreplaced) {
		if(b.st.visibility == Style->Vvisible)
			paintreplaced(dst, b, r);
		return;
	}
	# CSS 2.2 Appendix E: the in-flow blocks' backgrounds and borders,
	# then the floats, then the inline content, each in tree order
	flowbgs(dst, b, r.min, clip, canvasbg);
	flowfloats(dst, b, r.min, clip, canvasbg);
	flowinline(dst, b, r.min, clip, canvasbg);
}

# the in-flow block-level boxes of the flow b holds, not stacking
# contexts of their own
inflowblock(k: ref Box): int
{
	return !k.inl && !isabs(k) && !islayer(k) && !isfloat(k) && k.st.opacity >= 1.0;
}

kidrect(k: ref Box, o: Point): Rect
{
	return Rect((o.x + k.x, o.y + k.y), (o.x + k.x + k.w, o.y + k.y + k.h));
}

offscreen(k: ref Box, r, clip: Rect): int
{
	return r.min.y > clip.max.y || r.max.y < clip.min.y && k.kind != Kinline && !overflows(k);
}

withclip(dst: ref Image, clip: Rect): Rect
{
	oclip := dst.clipr;
	dst.clipr = clip;
	return oclip;
}

flowbgs(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	if(b.lines != nil)
		return;
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(!inflowblock(k))
			continue;
		r := kidrect(k, o);
		if(offscreen(k, r, clip))
			continue;
		if(k.st.visibility == Style->Vvisible)
			paintself(dst, k, r, canvasbg);
		if(k.kind == Kreplaced)
			continue;
		inner := innerclip(k, r, clip);
		if(rectok(inner)) {
			oc := withclip(dst, inner);
			flowbgs(dst, k, r.min, inner, canvasbg);
			dst.clipr = oc;
		}
	}
}

# floats, each painted whole, as if a stacking context
flowfloats(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k) || islayer(k))
			continue;
		if(isfloat(k)) {
			paintflow(dst, k, o, clip, canvasbg);
			continue;
		}
		if(k.kind == Kinline) {
			# a float inside an inline box; an invisible box hides it
			# (translucent ones are not composited yet)
			if(k.st.opacity > 0.0)
				flowfloats(dst, k, o, clip, canvasbg);
			continue;
		}
		if(!inflowblock(k) || k.kind == Kreplaced)
			continue;
		r := kidrect(k, o);
		inner := innerclip(k, r, clip);
		if(rectok(inner)) {
			oc := withclip(dst, inner);
			flowfloats(dst, k, r.min, inner, canvasbg);
			dst.clipr = oc;
		}
	}
}

flowinline(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	if(b.lines != nil) {
		paintlines(dst, b, o, clip, canvasbg);
		return;
	}
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(k.inl || isabs(k) || islayer(k) || isfloat(k))
			continue;
		if(k.st.opacity < 1.0) {
			paintctx(dst, k, o, clip, canvasbg);	# a stacking context of its own
			continue;
		}
		r := kidrect(k, o);
		if(offscreen(k, r, clip))
			continue;
		if(k.kind == Kreplaced) {
			if(k.st.visibility == Style->Vvisible)
				paintreplaced(dst, k, r);
		} else {
			inner := innerclip(k, r, clip);
			if(rectok(inner)) {
				oc := withclip(dst, inner);
				flowinline(dst, k, r.min, inner, canvasbg);
				dst.clipr = oc;
			}
		}
		paintoutline(dst, k, r, clip);
	}
}

# a box in normal flow (not a layer): itself and its content
paintflow(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	st := b.st;
	if(st.opacity < 1.0) {
		paintctx(dst, b, o, clip, canvasbg);	# a stacking context of its own
		return;
	}
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	if(r.min.y > clip.max.y || r.max.y < clip.min.y && b.kind != Kinline && !overflows(b))
		return;
	if(st.visibility == Style->Vvisible)
		paintself(dst, b, r, canvasbg);
	inner := innerclip(b, r, clip);
	if(rectok(inner)) {
		oclip := dst.clipr;
		dst.clipr = inner;
		paintcontent(dst, b, r, inner, canvasbg);
		dst.clipr = oclip;
	}
	paintoutline(dst, b, r, clip);
}

# could b's content paint outside its box?
overflows(b: ref Box): int
{
	return b.st.overflowy == Style->Ovisible;
}

paintoutline(dst: ref Image, b: ref Box, r, clip: Rect)
{
	st := b.st;
	if(st.visibility != Style->Vvisible || st.outlinew <= 0 || st.outlines == Style->Bnone)
		return;
	oclip := dst.clipr;
	dst.clipr = clip;
	w := st.outlinew;
	orect := r.inset(-(st.outlineoff + w));
	edge(dst, orect, w, st.outlinec, st.outlines);
	dst.clipr = oclip;
}

rectok(r: Rect): int
{
	return r.dx() > 0 && r.dy() > 0;
}

# Paint b into a layer and composite it with its opacity.
layer(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	(lr, ok) := clip.clip(inkbounds(b, r));
	if(!ok || !rectok(lr))
		return;
	img := display.newimage(lr, Draw->RGBA32, 0, Draw->Transparent);
	if(img == nil)
		return;
	outer := translucent;
	translucent = b;
	paintctx(img, b, o, lr, canvasbg);
	translucent = outer;
	a := int (b.st.opacity * 255.0);
	mask := display.newimage(Rect((0, 0), (1, 1)), Draw->GREY8, 1, (a << 24) | (a << 16) | (a << 8) | 255);
	dst.draw(lr, img, mask, lr.min);
}

# a generous bound on what b paints: its box, its descendants' boxes
inkbounds(b: ref Box, r: Rect): Rect
{
	return r.inset(-64);
}

paintbackground(dst: ref Image, b: ref Box, r: Rect)
{
	st := b.st;
	for(i := len st.shadows - 1; i >= 0; i--) {
		s := st.shadows[i];
		if(s.inset || !visible(s.color))
			continue;
		sr := Rect((r.min.x + int s.x - int s.spread, r.min.y + int s.y - int s.spread),
			(r.max.x + int s.x + int s.spread, r.max.y + int s.y + int s.spread));
		blur := int s.blur;
		if(blur <= 0)
			shadowfill(dst, b, sr, r, s.color);
		else {
			# approximate the blur with a few widening translucent layers
			steps := 4;
			c := s.color;
			a := (c & 255) / (steps + 1);
			for(k := steps; k >= 1; k--)
				shadowfill(dst, b, sr.inset(-blur*k/steps), r, (c & int 16rFFFFFF00) | a);
			shadowfill(dst, b, sr.inset(blur/2), r, (c & int 16rFFFFFF00) | a);
		}
	}
	if(visible(st.bgcolor)) {
		br := r;
		case bgclip(st) {
		Style->BOXpadding =>
			br = Rect((r.min.x + b.bl, r.min.y + b.bt), (r.max.x - b.br, r.max.y - b.bb));
		Style->BOXcontent =>
			br = Rect((r.min.x + b.bl + b.pl, r.min.y + b.bt + b.pt), (r.max.x - b.br - b.pr, r.max.y - b.bb - b.pb));
		}
		fillbox(dst, b, br, st.bgcolor);
	}
	for(i = len st.bg - 1; i >= 0; i--)
		if(st.bg[i].img != nil)
			paintbg(dst, b, r, st.bg[i]);
}

# an outer shadow shows only outside the border box (Backgrounds 3 §7.1)
shadowfill(dst: ref Image, b: ref Box, sr, r: Rect, c: int)
{
	if(!rectok(sr))
		return;
	(rtl, rtr, rbr, rbl) := radii(b);
	p := rrect(sr, rtl, rtr, rbr, rbl);
	addrrect(p, r, rtl, rtr, rbr, rbl);
	dst.fillpath(p, 1, colorimg(c), (0, 0));	# even-odd: the box is a hole
}

bgclip(st: ref St): int
{
	if(st.bg != nil && len st.bg > 0)
		return st.bg[len st.bg - 1].clip;
	return Style->BOXborder;
}

radii(b: ref Box): (int, int, int, int)
{
	st := b.st;
	return (res(st.rtl, b.w), res(st.rtr, b.w), res(st.rbr, b.w), res(st.rbl, b.w));
}

hasradius(b: ref Box): int
{
	(a, c, d, e) := radii(b);
	return a > 0 || c > 0 || d > 0 || e > 0;
}

fillbox(dst: ref Image, b: ref Box, r: Rect, c: int)
{
	if(!rectok(r))
		return;
	if(hasradius(b)) {
		(rtl, rtr, rbr, rbl) := radii(b);
		dst.fillpath(rrect(r, rtl, rtr, rbr, rbl), ~0, colorimg(c), (0, 0));
	} else
		dst.draw(r, colorimg(c), nil, (0, 0));
}

K: con 0.5522847498;	# cubic approximation of a quarter circle

# a rounded rectangle path
rrect(r: Rect, rtl, rtr, rbr, rbl: int): ref Path
{
	return addrrect(Path.new(), r, rtl, rtr, rbr, rbl);
}

addrrect(p: ref Path, r: Rect, rtl, rtr, rbr, rbl: int): ref Path
{
	w := r.dx();
	h := r.dy();
	# scale radii down if they overlap (CSS Backgrounds 3 §5.5)
	f := 1.0;
	f = minf(f, real w / real nz1(rtl + rtr));
	f = minf(f, real w / real nz1(rbl + rbr));
	f = minf(f, real h / real nz1(rtl + rbl));
	f = minf(f, real h / real nz1(rtr + rbr));
	x0 := real r.min.x;
	y0 := real r.min.y;
	x1 := real r.max.x;
	y1 := real r.max.y;
	a := real rtl * f;
	bb := real rtr * f;
	c := real rbr * f;
	d := real rbl * f;
	p.moveto(x0 + a, y0);
	p.lineto(x1 - bb, y0);
	if(bb > 0.0)
		p.curveto(x1 - bb + bb*K, y0, x1, y0 + bb - bb*K, x1, y0 + bb);
	p.lineto(x1, y1 - c);
	if(c > 0.0)
		p.curveto(x1, y1 - c + c*K, x1 - c + c*K, y1, x1 - c, y1);
	p.lineto(x0 + d, y1);
	if(d > 0.0)
		p.curveto(x0 + d - d*K, y1, x0, y1 - d + d*K, x0, y1 - d);
	p.lineto(x0, y0 + a);
	if(a > 0.0)
		p.curveto(x0, y0 + a - a*K, x0 + a - a*K, y0, x0 + a, y0);
	p.close();
	return p;
}

nz1(x: int): int
{
	if(x <= 0)
		return 1;
	return x;
}

minf(a, b: real): real
{
	if(b < a)
		return b;
	return a;
}

paintborders(dst: ref Image, b: ref Box, r: Rect)
{
	st := b.st;
	if(b.bt == 0 && b.br == 0 && b.bb == 0 && b.bl == 0)
		return;
	if(hasradius(b) && b.bt == b.br && b.bt == b.bb && b.bt == b.bl && st.bct == st.bcr && st.bct == st.bcb && st.bct == st.bcl) {
		# a uniform rounded border: outer path minus inner path
		(rtl, rtr, rbr, rbl) := radii(b);
		w := b.bt;
		p := rrect(r, rtl, rtr, rbr, rbl);
		irect := r.inset(w);
		if(rectok(irect)) {
			addrrect(p, irect, nz(rtl-w), nz(rtr-w), nz(rbr-w), nz(rbl-w));
		}
		dst.fillpath(p, 1, colorimg(st.bct), (0, 0));
		return;
	}
	# solid sides are trapezoids, meeting their neighbours on the
	# diagonal through each corner (CSS Backgrounds 3 §4.4): that is
	# what makes a border's corners, and border triangles, look right
	(x0, y0, x1, y1) := (r.min.x, r.min.y, r.max.x, r.max.y);
	(ix0, iy0, ix1, iy1) := (x0 + b.bl, y0 + b.bt, x1 - b.br, y1 - b.bb);
	if(!trapside(dst, array[] of {Point(x0, y0), Point(x1, y0), Point(ix1, iy0), Point(ix0, iy0)}, b.bt, st.bct, st.bst, 1))
		side(dst, Rect(r.min, (r.max.x, r.min.y + b.bt)), b.bt, st.bct, st.bst, 0, 1);
	if(!trapside(dst, array[] of {Point(x0, y1), Point(ix0, iy1), Point(ix1, iy1), Point(x1, y1)}, b.bb, st.bcb, st.bsb, 0))
		side(dst, Rect((r.min.x, r.max.y - b.bb), r.max), b.bb, st.bcb, st.bsb, 0, 0);
	if(!trapside(dst, array[] of {Point(x0, y0), Point(ix0, iy0), Point(ix0, iy1), Point(x0, y1)}, b.bl, st.bcl, st.bsl, 1))
		side(dst, Rect((r.min.x, r.min.y + b.bt), (r.min.x + b.bl, r.max.y - b.bb)), b.bl, st.bcl, st.bsl, 1, 1);
	if(!trapside(dst, array[] of {Point(x1, y0), Point(x1, y1), Point(ix1, iy1), Point(ix1, iy0)}, b.br, st.bcr, st.bsr, 0))
		side(dst, Rect((r.max.x - b.br, r.min.y + b.bt), (r.max.x, r.max.y - b.bb)), b.br, st.bcr, st.bsr, 1, 0);
}

# A side in a style drawn as one colour, as a polygon; 0 for the
# patterned styles, which side draws.
trapside(dst: ref Image, pts: array of Point, w, c, sty, topleft: int): int
{
	case sty {
	Style->Bdotted or Style->Bdashed or Style->Bdouble =>
		return 0;
	Style->Bnone or Style->Bhidden =>
		return 1;
	Style->Binset or Style->Bgroove =>
		if(topleft)
			c = shade(c, 0.6);
	Style->Boutset or Style->Bridge =>
		if(!topleft)
			c = shade(c, 0.6);
	}
	if(w <= 0 || !visible(c))
		return 1;
	dst.fillpoly(pts, ~0, colorimg(c), (0, 0));
	return 1;
}

# One border side as a rectangle, in its style.
# vert: a left/right side; topleft: the top or left side (for 3-D styles)
side(dst: ref Image, r: Rect, w, c, sty, vert, topleft: int)
{
	if(w <= 0 || !rectok(r) || !visible(c))
		return;
	case sty {
	Style->Bnone or Style->Bhidden =>
		return;
	Style->Bdotted or Style->Bdashed =>
		seg := w;
		if(sty == Style->Bdashed)
			seg = 3*w;
		img := colorimg(c);
		if(vert) {
			for(y := r.min.y; y < r.max.y; y += 2*seg)
				dst.draw(Rect((r.min.x, y), (r.max.x, min(y + seg, r.max.y))), img, nil, (0, 0));
		} else {
			for(x := r.min.x; x < r.max.x; x += 2*seg)
				dst.draw(Rect((x, r.min.y), (min(x + seg, r.max.x), r.max.y)), img, nil, (0, 0));
		}
		return;
	Style->Bdouble =>
		if(w >= 3) {
			t := (w + 1)/3;
			img := colorimg(c);
			if(vert) {
				dst.draw(Rect(r.min, (r.min.x + t, r.max.y)), img, nil, (0, 0));
				dst.draw(Rect((r.max.x - t, r.min.y), r.max), img, nil, (0, 0));
			} else {
				dst.draw(Rect(r.min, (r.max.x, r.min.y + t)), img, nil, (0, 0));
				dst.draw(Rect((r.min.x, r.max.y - t), r.max), img, nil, (0, 0));
			}
			return;
		}
	Style->Binset or Style->Bgroove =>
		if(topleft)
			c = shade(c, 0.6);
	Style->Boutset or Style->Bridge =>
		if(!topleft)
			c = shade(c, 0.6);
	}
	dst.draw(r, colorimg(c), nil, (0, 0));
}

shade(c: int, f: real): int
{
	r := int (real ((c >> 24) & 255) * f);
	g := int (real ((c >> 16) & 255) * f);
	b := int (real ((c >> 8) & 255) * f);
	return (r << 24) | (g << 16) | (b << 8) | (c & 255);
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

edge(dst: ref Image, r: Rect, w, c, sty: int)
{
	side(dst, Rect(r.min, (r.max.x, r.min.y + w)), w, c, sty, 0, 1);
	side(dst, Rect((r.min.x, r.max.y - w), r.max), w, c, sty, 0, 0);
	side(dst, Rect((r.min.x, r.min.y + w), (r.min.x + w, r.max.y - w)), w, c, sty, 1, 1);
	side(dst, Rect((r.max.x - w, r.min.y + w), (r.max.x, r.max.y - w)), w, c, sty, 1, 0);
}

# ---- background images ----

bgimages: list of (string, ref Image);

setbgimage(url: string, img: ref Image)
{
	for(l := bgimages; l != nil; l = tl l)
		if((hd l).t0 == url)
			return;
	bgimages = (url, img) :: bgimages;
}

clearbgimages()
{
	bgimages = nil;
}

bgurl(t: ref Css->Tok): string
{
	if(t.kind == Css->Kurl)
		return t.s;
	if(t.kind == Css->Kfunction && t.s == "url")
		for(k := 0; k < len t.kids; k++)
			if(t.kids[k].kind == Css->Kstring)
				return t.kids[k].s;
	return nil;
}

bgurls(st: ref St): list of string
{
	r: list of string;
	for(i := 0; i < len st.bg; i++)
		if(st.bg[i].img != nil && (u := bgurl(st.bg[i].img)) != nil)
			r = u :: r;
	if(st.listimage != nil && (lu := bgurl(st.listimage)) != nil)
		r = lu :: r;
	return r;
}

paintbg(dst: ref Image, b: ref Box, r: Rect, bg: ref Style->Bg)
{
	grad := bg.img.kind == Css->Kfunction && bg.img.s != "url";
	img: ref Image;
	if(!grad) {
		u := bgurl(bg.img);
		if(u == nil)
			return;
		for(l := bgimages; l != nil; l = tl l)
			if((hd l).t0 == u) {
				img = (hd l).t1;
				break;
			}
		if(img == nil)
			return;
	}
	pad := Rect((r.min.x + b.bl, r.min.y + b.bt), (r.max.x - b.br, r.max.y - b.bb));
	cbox := Rect((pad.min.x + b.pl, pad.min.y + b.pt), (pad.max.x - b.pr, pad.max.y - b.pb));
	area := pad;	# background-origin
	case bg.origin {
	Style->BOXborder =>	area = r;
	Style->BOXcontent =>	area = cbox;
	}
	if(bg.attfixed && intransform == 0)
		area = viewport;	# placed against the viewport, still shown only in the box
	clip := r;	# background-clip
	case bg.clip {
	Style->BOXpadding =>	clip = pad;
	Style->BOXcontent =>	clip = cbox;
	}
	if(oncanvas)
		clip = viewport;	# the root's background covers the canvas
	aw := area.dx();
	ah := area.dy();
	iw := aw;	# a gradient has no size of its own: it is the area's
	ih := ah;
	if(!grad) {
		iw = img.r.dx();
		ih = img.r.dy();
	}
	if(iw <= 0 || ih <= 0)
		return;
	# background-size
	w := real iw;
	h := real ih;
	if(bg.sizex.kind == Style->Lcontent && (bg.sizex.px == -1.0 || bg.sizex.px == -2.0)) {
		sx := real aw / real iw;
		sy := real ah / real ih;
		k := sx;
		if(bg.sizex.px == -1.0 && sy > sx || bg.sizex.px == -2.0 && sy < sx)
			k = sy;	# cover: the larger scale; contain: the smaller
		w = real iw * k;
		h = real ih * k;
	} else {
		xa := bg.sizex.isauto();
		ya := bg.sizey.isauto();
		if(!xa)
			w = bg.sizex.resolve(real aw);
		if(!ya)
			h = bg.sizey.resolve(real ah);
		if(!grad) {
			if(!xa && ya)
				h = w * real ih / real iw;
			else if(xa && !ya)
				w = h * real iw / real ih;
		}
	}
	# round: as many whole tiles as fit nearest, each scaled to fit exactly
	if(bg.rx == Style->Rround && w > 0.0)
		w = real aw / real nearest(real aw / w);
	if(bg.ry == Style->Rround && h > 0.0)
		h = real ah / real nearest(real ah / h);
	tw := int w;	# int rounds
	th := int h;
	if(w > 0.0 && tw < 1)	# a sliver still shows (it is repeated into a fill)
		tw = 1;
	if(h > 0.0 && th < 1)
		th = 1;
	if(tw <= 0 || th <= 0)
		return;
	if(!grad && (tw != iw || th != ih)) {
		img = scale(img, tw, th);
		if(img == nil)
			return;
	}
	# background-position: a percentage of the room left over
	px := area.min.x + int (bg.posx.px + bg.posx.pct * real (aw - tw) / 100.0);
	py := area.min.y + int (bg.posy.px + bg.posy.pct * real (ah - th) / 100.0);
	x0 := px;
	x1 := px + 1;
	if(bg.rx != Style->Rnorepeat) {
		while(x0 > clip.min.x)
			x0 -= tw;
		x1 = clip.max.x;
	}
	y0 := py;
	y1 := py + 1;
	if(bg.ry != Style->Rnorepeat) {
		while(y0 > clip.min.y)
			y0 -= th;
		y1 = clip.max.y;
	}
	oclip := dst.clipr;
	(cr, ok) := oclip.clip(clip);
	if(!ok)
		return;
	dst.clipr = cr;
	for(y := y0; y < y1; y += th)
		for(x := x0; x < x1; x += tw) {
			tile := Rect((x, y), (x + tw, y + th));
			(t, tok) := tile.clip(cr);
			if(!tok)
				continue;
			if(grad)
				paintgradient(dst, b, tile, bg);
			else
				dst.draw(t, img, nil, img.r.min.add(t.min.sub(Point(x, y))));
		}
	dst.clipr = oclip;
}

nearest(x: real): int
{
	n := int x;	# int rounds
	if(n < 1)
		n = 1;
	return n;
}

# linear-gradient() and radial-gradient() backgrounds, as bands of colour
paintgradient(dst: ref Image, b: ref Box, r: Rect, bg: ref Style->Bg)
{
	t := bg.img;
	if(t.kind != Css->Kfunction)
		return;
	lin := t.s == "linear-gradient" || t.s == "-webkit-linear-gradient" || t.s == "repeating-linear-gradient";
	if(!lin && t.s != "radial-gradient")
		return;
	args := commas(t.kids);
	if(args == nil)
		return;
	angle := 180.0;	# to bottom
	if(lin) {
		a := nows(hd args);
		if(len a > 0 && a[0].kind == Css->Kdimension) {
			case a[0].s {
			"deg" => angle = a[0].n;
			"turn" => angle = a[0].n * 360.0;
			"rad" => angle = a[0].n * 180.0 / Math->Pi;
			}
			args = tl args;
		} else if(len a > 0 && a[0].kind == Css->Kident && lower(a[0].s) == "to") {
			dir := "";
			for(k := 1; k < len a; k++)
				if(a[k].kind == Css->Kident)
					dir += lower(a[k].s);
			case dir {
			"top" => angle = 0.0;
			"right" => angle = 90.0;
			"bottom" => angle = 180.0;
			"left" => angle = 270.0;
			"topright" or "righttop" => angle = 45.0;
			"bottomright" or "rightbottom" => angle = 135.0;
			"bottomleft" or "leftbottom" => angle = 225.0;
			"topleft" or "lefttop" => angle = 315.0;
			}
			args = tl args;
		}
	} else {
		a := nows(hd args);
		if(len a > 0 && a[0].kind == Css->Kident) {
			(ok, nil) := style->color(a[0:1]);
			if(!ok)
				args = tl args;	# shape and position: drawn centred, circular
		}
	}
	# the gradient line's length, for stops given as lengths
	rad := angle * Math->Pi / 180.0;
	dx := math->sin(rad);
	dy := -math->cos(rad);
	linelen := math->fabs(real r.dx()*dx) + math->fabs(real r.dy()*dy);
	if(!lin)
		linelen = math->sqrt(real (r.dx()*r.dx() + r.dy()*r.dy()))/2.0;
	# colour stops
	n := len args;
	if(n < 1)
		return;
	cols := array[n] of int;
	pos := array[n] of real;
	k := 0;
	for(; args != nil; args = tl args) {
		a := nows(hd args);
		if(len a == 0)
			continue;
		(ok, c) := style->color(a[0:1]);
		if(!ok)
			continue;
		cols[k] = c;
		pos[k] = -1.0;
		if(len a > 1 && a[1].kind == Css->Kpercent)
			pos[k] = a[1].n / 100.0;
		else if(len a > 1 && a[1].kind == Css->Kdimension && a[1].s == "px" && linelen > 0.0)
			pos[k] = a[1].n / linelen;
		else if(len a > 1 && a[1].kind == Css->Knumber && a[1].n == 0.0)
			pos[k] = 0.0;
		k++;
	}
	if(k == 0)
		return;
	cols = cols[0:k];
	pos = pos[0:k];
	if(pos[0] < 0.0)
		pos[0] = 0.0;
	if(pos[k-1] < 0.0)
		pos[k-1] = 1.0;
	for(i := 1; i < k-1; i++)
		if(pos[i] < 0.0) {
			j := i;
			while(pos[j] < 0.0)
				j++;
			for(m := i; m < j; m++)
				pos[m] = pos[i-1] + (pos[j] - pos[i-1]) * real (m - i + 1) / real (j - i + 1);
		}
	oclip := dst.clipr;
	(cr, ok) := oclip.clip(r);
	if(!ok)
		return;
	dst.clipr = cr;
	if(lin) {
		# bands perpendicular to the gradient line
		w := real r.dx();
		h := real r.dy();
		glen := linelen;
		cx := real r.min.x + w/2.0;
		cy := real r.min.y + h/2.0;
		steps := int glen;
		if(steps < 1)
			steps = 1;
		if(steps > 512)
			steps = 512;
		for(s := 0; s < steps; s++) {
			t0 := real s / real steps;
			t1 := real (s+1) / real steps;
			c := gradcolor(cols, pos, (t0 + t1)/2.0);
			# the band from t0 to t1 along the line, as a polygon
			p := Path.new();
			ext := w + h;
			px := cx + dx*glen*(t0 - 0.5);
			py := cy + dy*glen*(t0 - 0.5);
			qx := cx + dx*glen*(t1 - 0.5) + dx*0.6;
			qy := cy + dy*glen*(t1 - 0.5) + dy*0.6;
			p.moveto(px - dy*ext, py + dx*ext);
			p.lineto(px + dy*ext, py - dx*ext);
			p.lineto(qx + dy*ext, qy - dx*ext);
			p.lineto(qx - dy*ext, qy + dx*ext);
			p.close();
			dst.fillpath(p, ~0, colorimg(c), (0, 0));
		}
	} else {
		cx := real (r.min.x + r.max.x)/2.0;
		cy := real (r.min.y + r.max.y)/2.0;
		rr := math->sqrt(real (r.dx()*r.dx() + r.dy()*r.dy()))/2.0;
		steps := int rr;
		if(steps > 256)
			steps = 256;
		dst.draw(r, colorimg(cols[k-1]), nil, (0, 0));
		for(s := steps; s > 0; s--) {
			t := real s / real steps;
			p := Path.new();
			p.ellipse(cx, cy, rr*t, rr*t);
			dst.fillpath(p, ~0, colorimg(gradcolor(cols, pos, t)), (0, 0));
		}
	}
	dst.clipr = oclip;
}

gradcolor(cols: array of int, pos: array of real, t: real): int
{
	if(t <= pos[0])
		return cols[0];
	for(i := 1; i < len cols; i++)
		if(t <= pos[i]) {
			span := pos[i] - pos[i-1];
			f := 1.0;
			if(span > 0.0)
				f = (t - pos[i-1]) / span;
			return mix(cols[i-1], cols[i], f);
		}
	return cols[len cols - 1];
}

mix(a, b: int, f: real): int
{
	r := 0;
	for(sh := 24; sh >= 0; sh -= 8) {
		x := real ((a >> sh) & 255) * (1.0 - f) + real ((b >> sh) & 255) * f;
		r |= (int x & 255) << sh;
	}
	return r;
}

commas(v: array of ref Tok): list of array of ref Tok
{
	r: list of array of ref Tok;
	st := 0;
	for(i := 0; i <= len v; i++)
		if(i == len v || v[i].kind == Css->Kcomma) {
			r = v[st:i] :: r;
			st = i+1;
		}
	o: list of array of ref Tok;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

nows(v: array of ref Tok): array of ref Tok
{
	n := 0;
	for(i := 0; i < len v; i++)
		if(v[i].kind != Css->Kws)
			n++;
	r := array[n] of ref Tok;
	n = 0;
	for(i = 0; i < len v; i++)
		if(v[i].kind != Css->Kws)
			r[n++] = v[i];
	return r;
}

paintreplaced(dst: ref Image, b: ref Box, r: Rect)
{
	cr := Rect((r.min.x + b.bl + b.pl, r.min.y + b.bt + b.pt), (r.max.x - b.br - b.pr, r.max.y - b.bb - b.pb));
	if(b.img != nil) {
		img := b.img;
		if(img.r.dx() != cr.dx() || img.r.dy() != cr.dy())
			img = scale(img, cr.dx(), cr.dy());
		if(img != nil)
			dst.draw(cr, img, nil, img.r.min);
		return;
	}
	if(b.text != nil) {
		# alt text, or a form control's value, label or placeholder:
		# one line, centred in the box, cut off at its edge
		f := face(b.st);
		c := b.st.color;
		if(b.hint)
			c = int 16r757575FF;	# a placeholder, as browsers show one
		y := cr.min.y + (cr.dy() - ir(f.ascent + f.descent)) / 2 + ir(f.ascent);
		oc := dst.clipr;
		(cl, ok) := cr.clip(oc);
		if(ok) {
			dst.clipr = cl;
			f.draw(dst, Point(cr.min.x + 1, y), b.text, colorimg(c), 0);
			dst.clipr = oc;
		}
	}
}

# Nearest-neighbour scaling, for images drawn at other than their
# size.  The last few are kept: a page repaints at every scroll, and
# scaling a photograph each time is most of the cost.
Nscaled: con 24;
scaled: list of (ref Image, int, int, ref Image);

scale(src: ref Image, w, h: int): ref Image
{
	for(l := scaled; l != nil; l = tl l) {
		(s, sw, sh, d) := hd l;
		if(s == src && sw == w && sh == h)
			return d;
	}
	d := scale1(src, w, h);
	if(d != nil) {
		if(len scaled >= Nscaled) {
			r: list of (ref Image, int, int, ref Image);
			n := 0;
			for(l = scaled; l != nil && n < Nscaled - 1; l = tl l)
				r = hd l :: r;
			scaled = nil;
			for(; r != nil; r = tl r)
				scaled = hd r :: scaled;
		}
		scaled = (src, w, h, d) :: scaled;
	}
	return d;
}

scale1(src: ref Image, w, h: int): ref Image
{
	if(w <= 0 || h <= 0)
		return nil;
	dst := display.newimage(Rect((0, 0), (w, h)), src.chans, 0, Draw->Transparent);
	if(dst == nil)
		return nil;
	sw := src.r.dx();
	sh := src.r.dy();
	# columns first into a strip, then rows
	strip := display.newimage(Rect((0, 0), (w, sh)), src.chans, 0, Draw->Transparent);
	if(strip == nil)
		return nil;
	for(x := 0; x < w; x++) {
		sx := src.r.min.x + x * sw / w;
		strip.draw(Rect((x, 0), (x+1, sh)), src, nil, (sx, src.r.min.y));
	}
	for(y := 0; y < h; y++) {
		sy := y * sh / h;
		dst.draw(Rect((0, y), (w, y+1)), strip, nil, (0, sy));
	}
	return dst;
}

paintlines(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	for(i := 0; i < len b.lines; i++) {
		ln := b.lines[i];
		if(o.y + ln.y > clip.max.y)
			break;
		if(o.y + ln.y + ln.h < clip.min.y && !hasatomic(ln))
			continue;
		# inline box backgrounds and borders first, outermost first
		for(k := 0; k < len ln.frags; k++) {
			f := ln.frags[k];
			if(f.kind == Fspan && f.box.st.visibility == Style->Vvisible)
				paintspan(dst, f, o);
		}
		for(k = 0; k < len ln.frags; k++) {
			f := ln.frags[k];
			case f.kind {
			Ftext =>
				if(f.box.st.visibility == Style->Vvisible)
					painttext(dst, f, o);
			Fatomic =>
				if(!islayer(f.box))
					paintflow(dst, f.box, o, clip, canvasbg);
			}
		}
	}
}

hasatomic(ln: ref Line): int
{
	for(k := 0; k < len ln.frags; k++)
		if(ln.frags[k].kind == Fatomic)
			return 1;
	return 0;
}

paintspan(dst: ref Image, f: ref Frag, o: Point)
{
	b := f.box;
	st := b.st;
	x0 := o.x + f.x;
	if(leftedge(f))
		x0 += b.ml;
	x1 := o.x + f.x + f.w;
	if(rightedge(f))
		x1 -= b.mr;
	r := Rect((x0, o.y + f.y), (x1, o.y + f.y + f.h));
	if(visible(st.bgcolor))
		dst.draw(r, colorimg(st.bgcolor), nil, (0, 0));
	for(i := len st.bg - 1; i >= 0; i--)
		if(st.bg[i].img != nil)
			paintbg(dst, b, r, st.bg[i]);
	side(dst, Rect(r.min, (r.max.x, r.min.y + b.bt)), b.bt, st.bct, st.bst, 0, 1);
	side(dst, Rect((r.min.x, r.max.y - b.bb), r.max), b.bb, st.bcb, st.bsb, 0, 0);
	if(leftedge(f))
		side(dst, Rect(r.min, (r.min.x + b.bl, r.max.y)), b.bl, st.bcl, st.bsl, 1, 1);
	if(rightedge(f))
		side(dst, Rect((r.max.x - b.br, r.min.y), r.max), b.br, st.bcr, st.bsr, 1, 0);
}

painttext(dst: ref Image, f: ref Frag, o: Point)
{
	st := f.box.st;
	if(f.text == "")
		return;	# an absolutely positioned box's place
	if(f.text == " " || f.text == "\t")
		return paintdeco(dst, f, o);
	fc := f.face;
	p := Point(o.x + f.x, o.y + f.base);
	text := visual(f);
	for(i := 0; i < len st.textshadows; i++) {
		s := st.textshadows[i];
		if(visible(s.color))
			drawtext(dst, fc, p.add(Point(int s.x, int s.y)), text, colorimg(s.color), st.letterspacing, f.level % 2);
	}
	if(visible(st.color))
		drawtext(dst, fc, p, text, colorimg(st.color), st.letterspacing, f.level % 2);
	paintdeco(dst, f, o);
}

drawtext(dst: ref Image, fc: ref Typeface, p: Point, s: string, c: ref Image, ls: real, rtl: int)
{
	if(ls == 0.0) {
		fc.draw(dst, p, s, c, rtl);
		return;
	}
	# spaced out: one character at a time, the last one leftmost if rtl
	x := real p.x;
	for(i := 0; i < len s; i++) {
		k := i;
		if(rtl)
			k = len s - 1 - i;
		x += fc.draw(dst, Point(int x, p.y), s[k:k+1], c, rtl) + ls;
	}
}

paintdeco(dst: ref Image, f: ref Frag, o: Point)
{
	d := f.deco | f.box.st.decoration;
	if(f.box.kind == Ktext)
		d = f.deco;
	if(d == 0 || f.w <= 0)
		return;
	fc := f.face;
	c := f.decocolor;
	if(c == Style->Ccurrent || c == 0)
		c = f.box.st.color;
	t := int (fc.size / 14.0);
	if(t < 1)
		t = 1;
	x0 := o.x + f.x;
	x1 := x0 + f.w;
	img := colorimg(c);
	if(d & Style->TDunder) {
		y := o.y + f.base + int (fc.descent * 0.35) + 1;
		dst.draw(Rect((x0, y), (x1, y + t)), img, nil, (0, 0));
	}
	if(d & Style->TDover) {
		y := o.y + f.base - int fc.ascent;
		dst.draw(Rect((x0, y), (x1, y + t)), img, nil, (0, 0));
	}
	if(d & Style->TDthrough) {
		y := o.y + f.base - int (fc.size * 0.3);
		dst.draw(Rect((x0, y), (x1, y + t)), img, nil, (0, 0));
	}
}

# ---- finding things ----

boxat(root: ref Box, p: Point): (int, ref Box)
{
	return findin(root, p, Point(0, 0));
}

findin(b: ref Box, p, o: Point): (int, ref Box)
{
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	org := r.min;
	for(pl := b.pos; pl != nil; pl = tl pl) {
		(n, x) := findin(hd pl, p, org);
		if(x != nil)
			return (n, x);
	}
	if(b.lines != nil) {
		for(i := 0; i < len b.lines; i++) {
			ln := b.lines[i];
			for(k := len ln.frags - 1; k >= 0; k--) {
				f := ln.frags[k];
				fr := Rect((org.x + f.x, org.y + f.y), (org.x + f.x + f.w, org.y + f.y + f.h));
				if(f.kind == Fatomic) {
					(n, x) := findin(f.box, p, org);
					if(x != nil)
						return (n, x);
					continue;
				}
				if(p.in(fr))
					return (f.box.node, f.box);
			}
		}
	} else
		for(i := len b.kids - 1; i >= 0; i--) {
			if(isabs(b.kids[i]))
				continue;
			(n, x) := findin(b.kids[i], p, org);
			if(x != nil)
				return (n, x);
		}
	if(p.in(r))
		return (b.node, b);
	return (0, nil);
}

boxes(root: ref Box, n: int): list of ref Box
{
	return collect(root, n, nil);
}

collect(b: ref Box, n: int, acc: list of ref Box): list of ref Box
{
	if(b.node == n && b.kind != Ktext)
		acc = b :: acc;
	for(i := 0; i < len b.kids; i++)
		acc = collect(b.kids[i], n, acc);
	return acc;
}

kindnames := array[] of {"block", "inline", "text", "br", "replaced", "flex", "grid", "table", "row", "cell", "marker"};

dump(root: ref Box): string
{
	return dumpbox(root, "", Point(0, 0));
}

dumpbox(b: ref Box, ind: string, o: Point): string
{
	x := o.x + b.x;
	y := o.y + b.y;
	k := kindnames[b.kind];
	if(b.inl && b.kind != Kinline && b.kind != Ktext && b.kind != Kbr)
		k = "inline-" + k;
	s := sys->sprint("%s%s %d %d %d %d %d\n", ind, k, b.node, x, y, b.w, b.h);
	if(b.lines != nil) {
		for(i := 0; i < len b.lines; i++) {
			ln := b.lines[i];
			s += sys->sprint("%s  line %d %d\n", ind, y + ln.y, ln.h);
			for(j := 0; j < len ln.frags; j++) {
				f := ln.frags[j];
				case f.kind {
				Ftext =>
					s += sys->sprint("%s    text %d %d %d %d \"%s\"\n", ind, x + f.x, y + f.y, f.w, f.h, f.text);
				Fatomic =>
					s += dumpbox(f.box, ind + "    ", Point(x, y));
				}
			}
		}
	} else
		for(i := 0; i < len b.kids; i++)
			if(!isabs(b.kids[i]))
				s += dumpbox(b.kids[i], ind + "  ", Point(x, y));
	for(pl := revboxes(b.pos); pl != nil; pl = tl pl)
		s += dumpbox(hd pl, ind + "  ", Point(x, y));
	return s;
}
