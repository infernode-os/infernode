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
include "bufio.m";
	bufio: Bufio;
include "imagefile.m";
	readsvg: RImagefile;
	imageremap: Imageremap;
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
	counters:	list of ref Ctr;	# the counters in scope, innermost first
	qdepth:	int;		# quotes open (CSS 2.2 §12.3.2)
};

# A counter instance (CSS Lists 3 §4).  Its scope is the element that
# created it, that element's descendants and its following siblings with
# theirs; b.counters is cut back to an element's own list when the
# element ends, so what its descendants created goes out of scope and
# what it created itself stays for the siblings to come.
Ctr: adt {
	name:	string;
	val:	int;
	rev:	int;	# reversed: a list item counts down
	origin:	int;	# the node that instantiated it
	nested:	int;	# inside an ancestor's of the same name: for the subtree only
};

newbox(kind, inl, node: int, st: ref St): ref Box
{
	return ref Box(kind, inl, node, st, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, nil, nil, nil, 0, 0, 0, 0.0, 0.0, 0.0, nil, nil, nil, nil, 0, 0, 0, 0, 0, 0,
		nil, nil, nil, nil, 0, 0, nil, nil, 0, nil);
}

build(d: ref Doc, c: ref Computed): ref Box
{
	curdoc = d;
	root := d.root();
	if(root == 0 || c.st[root] == nil)
		return newbox(Kblock, 0, 0, style->anon(nil, Style->Dblock));
	b := ref B(d, c, nil, 0);
	l := element(b, root);
	if(l == nil) {
		# display: none on the root: nothing, not even its background
		# (Backgrounds 3 §2.11.2; CSS 2.2's root-box-003 wanted otherwise)
		r := newbox(Kblock, 0, 0, style->anon(nil, Style->Dblock));
		r.doc = d;
		return r;
	}
	setparents(hd l);
	(hd l).doc = d;
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

# The box kind a display value makes, and whether it is inline-level.
boxkind(st: ref St): (int, int)
{
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
	Style->Dgridlanes =>
		kind = Kgrid;
	Style->Dinlinegridlanes =>
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
	return (kind, inl);
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
	(kind, inl) := boxkind(st);
	if(nd.tag == Dom->Tbr && nd.ns == Dom->HTML)
		return newbox(Kbr, 1, n, st) :: nil;
	if(nd.tag == Dom->Twbr && nd.ns == Dom->HTML) {
		# a line break opportunity: as a zero-width space (HTML §4.5.29)
		t := newbox(Ktext, 1, n, st);
		t.text = "\u200B";
		return t :: nil;
	}
	box := newbox(kind, inl, n, st);
	# (ol, ul and menu reset list-item by the UA sheet; start= and reversed are hints)
	ctrprops(b, n, st, st.display == Style->Dlistitem);
	own := b.counters;
	kids: list of ref Box;
	if(st.display == Style->Dlistitem)
		kids = marker(b, n, st) :: nil;
	if((bs := b.c.before[n]) != nil && (gb := generated(b, n, bs)) != nil)
		kids = gb :: kids;
	for(l := children(b, n, st); l != nil; l = tl l)
		kids = hd l :: kids;
	if((as := b.c.after[n]) != nil && (ga := generated(b, n, as)) != nil)
		kids = ga :: kids;
	b.counters = ctrleave(own, n);
	kids = rev(kids);
	if(kind == Kinline) {
		# cells in it go in an anonymous inline table first (§17.2.1);
		# then an inline box around blocks is split into inline pieces
		# either side of them (CSS 2.2 §9.2.1.1)
		kids = orphans(box, kids);
		hasblock := 0;
		for(l = kids; l != nil; l = tl l)
			if(isblocklevel(hd l))
				hasblock = 1;
		if(hasblock)
			return splitinline(box, kids);
	}
	box.kids = fixkids(box, kids);
	if((kind == Kblock || kind == Kcell) && (fs := b.c.firstletter[n]) != nil)
		firstletter(box, fs);
	if(kind == Kblock || kind == Kcell)
		box.fl = b.c.firstline[n];
	return box :: nil;
}

# The ::first-line style that applies to the first line of the block
# container b: its own, or that of an ancestor whose first formatted
# line this is, b being the first in-flow block-level box all the way
# up (CSS 2.2 §5.12.1; first-line-selector-004).  Only the colour is
# honoured as yet: the line is laid out in the element's own font.
firstlinest(b: ref Box): ref St
{
	for(p := b; p != nil; p = p.parent) {
		if(p.fl != nil)
			return p.fl;
		if(p.inl || isoof(p) || p.parent == nil || p.parent.kind != Kblock && p.parent.kind != Kcell || !firstinflow(p))
			return nil;	# (not into a flex, grid or table container: grid-first-line-002)
	}
	return nil;
}

firstinflow(p: ref Box): int
{
	q := p.parent;
	for(i := 0; i < len q.kids; i++) {
		k := q.kids[i];
		if(isoof(k))
			continue;
		return k == p && isblocklevel(k) || k.kind == Ktext && k.text != nil && isblankrun(k.text) && i + 1 < len q.kids && q.kids[i+1] == p;
	}
	return 0;
}

# ::first-letter: the first letter of the block's first formatted
# line, with the punctuation around it, goes in a box of the
# pseudo-element's style (CSS 2.2 §5.12.2); the letter's own marks go
# with it.  Only a letter in one text run, after any punctuation in
# that run: punctuation alone before a letter in the next run is not
# gathered.
firstletter(box: ref Box, st: ref St)
{
	(p, i) := firsttext(box);
	if(p == nil)
		return;
	t := p.kids[i];
	s := t.text;
	n := len s;
	a := 0;
	while(a < n && iswhite(s[a]))
		a++;
	j := a;
	while(j < n && bidi->punct(s[j]))
		j++;
	if(j >= n || isspacesep(s[j]))
		return;	# punctuation alone, or a space where the letter would be: no first letter
	j++;
	while(j < n && bidi->joining(s[j]) == Bidi->JT)
		j++;
	while(j < n && bidi->punct(s[j]))
		j++;
	ft := newbox(Ktext, 1, t.node, st);
	ft.text = s[a:j];
	fk := Kinline;
	finl := 1;
	if(st.float != Style->Fnone || st.display != Style->Dinline) {
		fk = Kblock;
		finl = 0;
	}
	fb := newbox(fk, finl, 0, st);
	fb.kids = array[] of {ft};
	pieces: list of ref Box;
	if(a > 0) {
		lead := newbox(Ktext, 1, t.node, t.st);
		lead.text = s[0:a];
		pieces = lead :: pieces;
	}
	pieces = fb :: pieces;
	if(j < n) {
		t.text = s[j:];
		pieces = t :: pieces;
	}
	np := len p.kids - 1;
	for(l := pieces; l != nil; l = tl l)
		np++;
	kids := array[np] of ref Box;
	kids[0:] = p.kids[0:i];
	m := i;
	for(l = rev(pieces); l != nil; l = tl l)
		kids[m++] = hd l;
	kids[m:] = p.kids[i+1:];
	p.kids = kids;
}

# a space separator that is a break opportunity and hangs at a line's
# end: the ideographic space, the ogham space mark, the en and em
# spaces and their kin (not the no-break ones)
hangsp(c: int): int
{
	return c == 16r3000 || c == 16r1680 || c >= 16r2000 && c <= 16r200A && c != 16r2007 || c == 16r205F;	# (the figure space is glue)
}

hangsep(t: string): int
{
	return len t == 1 && hangsp(t[0]);
}

# a space separator (General_Category Zs) other than the ASCII space
isspacesep(c: int): int
{
	return c == 16rA0 || c == 16r1680 || c >= 16r2000 && c <= 16r200A || c == 16r202F || c == 16r205F || c == 16r3000;
}

# the first text box of a block's first formatted line (its parent
# and index): through inline boxes and into a first block child, past
# markers and out-of-flow boxes; nil at a line break or an atomic box
firsttext(box: ref Box): (ref Box, int)
{
	for(i := 0; i < len box.kids; i++) {
		k := box.kids[i];
		if(k.kind == Kmarker || isoof(k))
			continue;
		case k.kind {
		Ktext =>
			all := 1;
			for(c := 0; c < len k.text; c++)
				if(!iswhite(k.text[c]))
					all = 0;
			if(all)
				continue;
			return (box, i);
		Kinline =>
			(p, j) := firsttext(k);
			if(p != nil)
				return (p, j);
			continue;	# an empty inline box
		Kblock =>
			if(k.inl)
				return (nil, 0);
			return firsttext(k);
		}
		return (nil, 0);
	}
	return (nil, 0);
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
	pieces: list of ref Box;
	for(; kids != nil; kids = tl kids) {
		k := hd kids;
		if(isblocklevel(k)) {
			if(run != nil) {
				p := ref *box;
				p.kids = toarray(rev(run));
				r = p :: r;
				pieces = p :: pieces;
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
		pieces = p :: pieces;
	}
	# the box's start edges belong to its first piece and its end
	# edges to its last (§9.2.1.1, as for the fragments of one box
	# across lines; margin-right-114)
	if(pieces != nil && tl pieces != nil) {
		last := hd pieces;
		for(pl := pieces; pl != nil; pl = tl pl) {
			p := hd pl;
			p.st = ref *p.st;
			if(p != last) {
				p.st.mr = p.st.pr = Style->Len(Style->Lpx, 0.0, 0.0, nil);
				p.st.br = 0;
			}
			if(tl pl != nil) {
				p.st.ml = p.st.pl = Style->Len(Style->Lpx, 0.0, 0.0, nil);
				p.st.bl = 0;
			}
		}
	}
	return rev(r);
}

# Children of a block container are all block-level or all inline-level:
# runs of inline-level boxes beside blocks go in anonymous blocks, and
# runs of nothing but collapsible white space are dropped.
fixkids(box: ref Box, kids: list of ref Box): array of ref Box
{
	if(box.kind == Kinline)
		return toarray(orphans(box, kids));	# cells in an inline box: an inline table
	# anonymous table objects (CSS 2.2 §17.2.1)
	if(box.kind == Ktable)
		return toarray(tablekids(box, kids));
	if(isrowgroup(box))
		return toarray(wrapruns(box, kids, isrow, Krow, Style->Dtablerow));
	if(box.kind == Krow)
		return toarray(wrapruns(box, kids, iscell, Kcell, Style->Dtablecell));
	if(iscolumn(box))
		return toarray(kids);	# a column group's columns are at home
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
	# out-of-flow boxes go with an inline run they sit in, else stand
	# alone; in a flex or grid container one ends the run, so the text
	# either side is two items (anonymous-flex-item-004)
	items := box.kind == Kflex || box.kind == Kgrid;
	r: list of ref Box;
	run: list of ref Box;
	for(l = kids; l != nil; l = tl l) {
		k := hd l;
		if(isblocklevel(k) || isoof(k) && (run == nil || items)) {
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
	if(run == nil)
		return r;
	kids := rev(run);
	if(blankrun(run, 0)) {
		# absolutely positioned boxes stand where they are (a positioned
		# row group is a block among the table's children); floats are
		# wrapped like any other content, as browsers do
		fl: list of ref Box;
		for(l := kids; l != nil; l = tl l)
			if(isfloat(hd l))
				fl = hd l :: fl;
			else if(isoof(hd l))
				r = hd l :: r;
		if(fl == nil)
			return r;
		kids = rev(fl);
	}
	a := newbox(kind, 0, 0, style->anon(parent.st, display));
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
		if(isinternal(k) || run != nil && k.kind == Ktext && blankrun(k :: nil, 0))
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
	return k.kind == Krow || k.kind == Kcell || isrowgroup(k) || iscolumn(k) ||
		k.kind != Ktext && k.st.display == Style->Dtablecaption;
}

flushtable(parent: ref Box, run, r: list of ref Box): list of ref Box
{
	if(run == nil)
		return r;
	# in an inline box the anonymous table is an inline table (§17.2.1)
	inl := parent.kind == Kinline;
	d := Style->Dtable;
	if(inl)
		d = Style->Dinlinetable;
	t := newbox(Ktable, inl, 0, style->anon(parent.st, d));
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
	if(!blankrun(run, 1))
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

# nothing but white space (and out-of-flow boxes): preserved white
# space is content in a block (pre), never between the parts of a
# table, where such text generates no box (CSS 2.2 §17.2.1)
blankrun(l: list of ref Box, pre: int): int
{
	for(; l != nil; l = tl l) {
		k := hd l;
		if(isoof(k))
			continue;
		if(k.kind != Ktext)
			return 0;
		if(pre)
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
	if(st.display == Style->Dtablecolumn || st.display == Style->Dtablecolumngroup)
		return nil;	# a column shows no content (before-content-display-012)
	(kind, inl) := boxkind(st);
	g := newbox(kind, inl, n, st);
	# A pseudo-element is the element's first (or last) child for
	# counters: one it creates afresh is in scope for the children that
	# follow it (content-021), one it nests inside an ancestor's is its
	# own (counters-scope-001).
	pid := -(2*n);
	if(st != b.c.before[n])
		pid = -(2*n + 1);
	li := st.display == Style->Dlistitem;
	ctrprops(b, pid, st, li);
	kids: list of ref Box;
	if(li)
		kids = marker(b, n, st) :: kids;
	# its text, with each url() an image: a replaced inline box
	v := st.content;
	s0 := 0;
	for(i := 0; i <= len v; i++) {
		if(i < len v && v[i].kind != Css->Kurl)
			continue;
		if((txt := contentof(b, n, st, v[s0:i])) != "") {
			t := newbox(Ktext, 1, n, st);
			t.text = txt;
			kids = t :: kids;
		}
		if(i < len v) {
			r := newbox(Kreplaced, 1, n, style->anon(st, Style->Dinline));
			r.url = v[i].s;
			kids = r :: kids;
		}
		s0 = i + 1;
	}
	b.counters = ctrleave(b.counters, pid);
	g.kids = fixkids(g, rev(kids));	# a table's text goes in an anonymous row and cell, as an element's would
	return g;
}

# counter-reset, counter-increment and counter-set on an element or
# pseudo-element, in that order (CSS Lists 3 §4.4); a list item counts
# itself in list-item unless its counter-increment names it, and an
# li's value attribute sets it.  A counter named by an increment or set
# that no reset put in scope is created here at 0.
ctrprops(b: ref B, n: int, st: ref St, li: int)
{
	v := st.counterreset;
	for(i := 0; i < len v; i++)
		if(v[i].kind == Css->Kident) {
			x := 0;
			if(i+1 < len v && v[i+1].kind == Css->Knumber)
				x = int v[i+1].n;
			instantiate(b, n, v[i].s, x, 0);
		} else if(v[i].kind == Css->Kfunction && v[i].s == "reversed" && len v[i].kids > 0 && v[i].kids[0].kind == Css->Kident) {
			# reversed(name [value]) (Lists 3 §4.2): counting down; with no
			# value, from what its scope's increments add up to
			nm := v[i].kids[0].s;
			x := 0;
			given := 0;
			for(k := 1; k < len v[i].kids; k++)
				if(v[i].kids[k].kind == Css->Knumber) {
					x = int v[i].kids[k].n;
					given = 1;
				}
			if(!given && i+1 < len v && v[i+1].kind == Css->Knumber) {
				x = int v[i+1].n;
				given = 1;
			}
			if(!given) {
				el := n;
				if(el < 0)
					el = (-el) / 2;	# a pseudo-element: its element's subtree
				x = reversedinit(b, el, nm);
			}
			instantiate(b, n, nm, x, 1);
		}
	v = st.counterincrement;
	if(li && !ctrnamed(v, "list-item")) {
		c := ctrfind(b, n, "list-item");
		if(c.rev)
			c.val--;
		else
			c.val++;
	}
	for(i = 0; i < len v; i++)
		if(v[i].kind == Css->Kident) {
			x := 1;
			if(i+1 < len v && v[i+1].kind == Css->Knumber)
				x = int v[i+1].n;
			ctrincr(b, n, v[i].s, x);
		}
	if(li && n > 0 && (s := b.d.attr(n, "value")) != nil)
		ctrset(b, n, "list-item", int s);	# (a pseudo-element, numbered below zero, has no attributes)
	v = st.counterset;
	for(i = 0; i < len v; i++)
		if(v[i].kind == Css->Kident) {
			x := 0;
			if(i+1 < len v && v[i+1].kind == Css->Knumber)
				x = int v[i+1].n;
			ctrset(b, n, v[i].s, x);
		}
}

ctrnamed(v: array of ref Tok, nm: string): int
{
	for(i := 0; i < len v; i++)
		if(v[i].kind == Css->Kident && v[i].s == nm)
			return 1;
	return 0;
}

ctrfind(b: ref B, n: int, nm: string): ref Ctr
{
	for(l := b.counters; l != nil; l = tl l)
		if((hd l).name == nm)
			return hd l;
	c := ref Ctr(nm, 0, 0, n, 0);
	b.counters = c :: b.counters;
	return c;
}

# A new counter replaces one of its name that the element itself or a
# previous sibling instantiated, and nests inside one an ancestor did
# (Lists 3 §4.4.2).
instantiate(b: ref B, n: int, nm: string, x, rev: int)
{
	nested := 0;
	for(l := b.counters; l != nil; l = tl l)
		if((hd l).name == nm) {
			o := (hd l).origin;
			if(o == n || o != 0 && parentof(b, o) == parentof(b, n))
				b.counters = ctrremove(b.counters, hd l);
			else
				nested = 1;	# an ancestor's: this one is for the subtree (counters-001)
			break;
		}
	b.counters = ref Ctr(nm, x, rev, n, nested) :: b.counters;
}

# the parent of a counter's originating element; a pseudo-element,
# numbered -(2n) for ::before and -(2n+1) for ::after, is a child of n
parentof(b: ref B, o: int): int
{
	if(o < 0)
		return (-o) / 2;
	return b.d.nodes[o].parent;
}

# what an element leaves its following siblings: its own list without
# the counters it nested inside an ancestor's
ctrleave(l: list of ref Ctr, n: int): list of ref Ctr
{
	for(x := l; x != nil; x = tl x)
		if((hd x).origin == n && (hd x).nested)
			l = ctrremove(l, hd x);
	return l;
}

ctrremove(l: list of ref Ctr, c: ref Ctr): list of ref Ctr
{
	r, o: list of ref Ctr;
	for(; l != nil; l = tl l)
		if(hd l != c)
			r = hd l :: r;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# A reversed counter's initial value when none is given: the magnitudes
# of the increments in its scope (the element's subtree, then its
# following siblings' subtrees, up to and including the first element
# that sets it) plus what it is set to there, or else plus the last
# increment, so that it counts down to that.  An inner reset of the
# same name starts another counter: its subtree is skipped.
Rv: adt {
	sum:	int;	# the increments negated, and the first set value
	last:	int;	# the last increment negated that was not 0
	found:	int;	# a set ended the scan
};

reversedinit(b: ref B, n: int, nm: string): int
{
	rv := ref Rv(0, 0, 0);
	for(k := b.d.nodes[n].first; k != 0 && !rv.found; k = b.d.nodes[k].next)
		revscan(b, k, nm, rv);
	# the following siblings, until one instantiates the counter afresh
	for(k = b.d.nodes[n].next; k != 0 && !rv.found; k = b.d.nodes[k].next) {
		if(b.d.nodes[k].kind == Dom->Element && b.c.st[k] != nil && resetsctr(b.c.st[k].counterreset, nm))
			break;
		revscan(b, k, nm, rv);
	}
	return rv.sum + rv.last;
}

revscan(b: ref B, m: int, nm: string, rv: ref Rv)
{
	if(b.d.nodes[m].kind != Dom->Element)
		return;
	st := b.c.st[m];
	if(st == nil || st.display == Style->Dnone)
		return;
	if(resetsctr(st.counterreset, nm))
		return;
	# the element, then its ::before, its children, its ::after: tree order
	revprops(b, m, st, nm, rv, 1);
	if(rv.found)
		return;
	if((bs := b.c.before[m]) != nil)
		revprops(b, m, bs, nm, rv, 0);
	if(rv.found)
		return;
	for(k := b.d.nodes[m].first; k != 0 && !rv.found; k = b.d.nodes[k].next)
		revscan(b, k, nm, rv);
	if(!rv.found && (as := b.c.after[m]) != nil)
		revprops(b, m, as, nm, rv, 0);
}

revprops(b: ref B, m: int, st: ref St, nm: string, rv: ref Rv, el: int)
{
	v := st.counterincrement;
	inc := 0;
	any := 0;
	for(i := 0; i < len v; i++)
		if(v[i].kind == Css->Kident && v[i].s == nm) {
			inc = 1;
			if(i+1 < len v && v[i+1].kind == Css->Knumber)
				inc = int v[i+1].n;
			any = 1;
		}
	if(!any && el && nm == "list-item" && st.display == Style->Dlistitem) {
		inc = -1;
		any = 1;
	}
	if(any && inc != 0)
		rv.last = -inc;
	# a set ends it: its value counts, the element's increment does not
	if(el && nm == "list-item" && st.display == Style->Dlistitem && (s := b.d.attr(m, "value")) != nil) {
		rv.found = 1;
		rv.sum += int s;
		return;
	}
	v = st.counterset;
	for(i = 0; i < len v; i++)
		if(v[i].kind == Css->Kident && v[i].s == nm) {
			rv.found = 1;
			if(i+1 < len v && v[i+1].kind == Css->Knumber)
				rv.sum += int v[i+1].n;
			return;
		}
	if(any)
		rv.sum -= inc;
}

resetsctr(v: array of ref Tok, nm: string): int
{
	for(i := 0; i < len v; i++) {
		if(v[i].kind == Css->Kident && v[i].s == nm)
			return 1;
		if(v[i].kind == Css->Kfunction && v[i].s == "reversed" && len v[i].kids > 0 && v[i].kids[0].kind == Css->Kident && v[i].kids[0].s == nm)
			return 1;
	}
	return 0;
}

ctrincr(b: ref B, n: int, nm: string, d: int)
{
	c := ctrfind(b, n, nm);
	c.val += d;
}

ctrset(b: ref B, n: int, nm: string, x: int)
{
	c := ctrfind(b, n, nm);
	c.val = x;
}

# The text of a content property.
content(b: ref B, n: int, st: ref St): string
{
	return contentof(b, n, st, st.content);
}

contentof(b: ref B, n: int, st: ref St, v: array of ref Css->Tok): string
{
	s := "";
	for(i := 0; i < len v; i++) {
		t := v[i];
		case t.kind {
		Css->Kstring =>
			s += t.s;
		Css->Kfunction =>
			case t.s {
			"attr" =>
				if(len t.kids > 0 && t.kids[0].kind == Css->Kident) {
					an := t.kids[0].s;
					if(!b.d.xml)
						an = lower(an);	# HTML attributes match regardless of case; XML's exactly
					s += b.d.attr(n, an);
				}
			"counter" or "counters" =>
				if(len t.kids > 0 && t.kids[0].kind == Css->Kident) {
					sty := "decimal";
					sep := "";
					for(k := 1; k < len t.kids; k++)
						if(t.kids[k].kind == Css->Kident)
							sty = lower(t.kids[k].s);
						else if(t.kids[k].kind == Css->Kstring)
							sep = t.kids[k].s;
					if(t.s == "counter")
						s += counterrep(sty, counter(b, t.kids[0].s));
					else
						s += counters(b, t.kids[0].s, sep, sty);
				}
			}
		Css->Kident =>
			# quotes: the pair for the nesting depth, the last pair
			# beyond them (CSS 2.2 §12.3.2); none shows nothing
			q := st.quotes;
			if(q == nil)
				q = defaultquotes;
			case lower(t.s) {
			"open-quote" =>
				s += quotemark(q, b.qdepth, 0);
				b.qdepth++;
			"close-quote" =>
				# one with no open quote before it shows nothing, as
				# browsers have it (content-056)
				if(b.qdepth > 0) {
					b.qdepth--;
					s += quotemark(q, b.qdepth, 1);
				}
			"no-open-quote" =>
				b.qdepth++;
			"no-close-quote" =>
				if(b.qdepth > 0)
					b.qdepth--;
			}
		}
	}
	return s;
}

defaultquotes := array[] of {"“", "”", "‘", "’"};

quotemark(q: array of string, depth, close: int): string
{
	n := len q / 2;
	if(n == 0)
		return "";
	if(depth >= n)
		depth = n - 1;
	return q[2*depth + close];
}

counter(b: ref B, nm: string): int
{
	for(l := b.counters; l != nil; l = tl l)
		if((hd l).name == nm)
			return (hd l).val;
	return 0;
}

# counters(): every counter of the name in scope, outermost first.
counters(b: ref B, nm, sep, sty: string): string
{
	s := "";
	for(l := b.counters; l != nil; l = tl l)
		if((hd l).name == nm) {
			if(s != nil)
				s = sep + s;
			s = counterrep(sty, (hd l).val) + s;
		}
	return s;
}

marker(b: ref B, n: int, st: ref St): ref Box
{
	v := counter(b, "list-item");
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

# A marker's text: the counter's representation and the style's suffix.
markertext(ls: string, v: int): string
{
	if(len ls > 0 && ls[0] == '"')
		return ls[1:];
	case ls {
	"none" =>
		return "";
	"disc" or "circle" or "square" or "disclosure-closed" or "disclosure-open" =>
		return counterrep(ls, v) + " ";
	}
	return counterrep(ls, v) + ". ";
}

# A counter value in a counter style, without the suffix.
counterrep(ls: string, v: int): string
{
	case ls {
	"none" =>
		return "";
	"disc" =>
		return "•";
	"circle" =>
		return "◦";
	"square" =>
		return "▪";
	"disclosure-closed" =>
		return "▸";
	"disclosure-open" =>
		return "▾";
	"decimal-leading-zero" =>
		if(v < 10 && v >= 0)
			return "0" + string v;
		if(v > -10 && v < 0)
			return "-0" + string -v;
		return string v;
	"lower-alpha" or "lower-latin" =>
		return alpha(v, 'a');
	"upper-alpha" or "upper-latin" =>
		return alpha(v, 'A');
	"lower-roman" =>
		return lower(roman(v));
	"upper-roman" =>
		return roman(v);
	"lower-greek" =>
		return alpha(v, 16r3b1);
	"armenian" or "upper-armenian" =>
		return armenian(v, 16r531);
	"lower-armenian" =>
		return armenian(v, 16r561);
	"georgian" =>
		return georgian(v);
	}
	return string v;
}

# Armenian numerals (Counter Styles 3 §6.2): additive, a letter for
# each digit of each power of ten up to 9999, in alphabet order
armenian(v, base: int): string
{
	if(v <= 0 || v >= 10000)
		return string v;
	s := "";
	for(k := 0; v > 0; k++) {
		d := v % 10;
		v /= 10;
		if(d > 0) {
			c := "";
			c[0] = base + 9*k + d - 1;
			s = c + s;
		}
	}
	return s;
}

georgianvals := array[] of {10000, 9000, 8000, 7000, 6000, 5000, 4000, 3000, 2000, 1000,
	900, 800, 700, 600, 500, 400, 300, 200, 100, 90, 80, 70, 60, 50, 40, 30, 20, 10,
	9, 8, 7, 6, 5, 4, 3, 2, 1};
georgiansyms := array[] of {16r10F5, 16r10F0, 16r10EF, 16r10F4, 16r10EE, 16r10ED, 16r10EC, 16r10EB, 16r10EA, 16r10E9,
	16r10E8, 16r10E7, 16r10E6, 16r10E5, 16r10E4, 16r10F3, 16r10E2, 16r10E1, 16r10E0, 16r10DF, 16r10DE, 16r10DD, 16r10F2, 16r10DC, 16r10DB, 16r10DA, 16r10D9, 16r10D8,
	16r10D7, 16r10F1, 16r10D6, 16r10D5, 16r10D4, 16r10D3, 16r10D2, 16r10D1, 16r10D0};

# Georgian numerals: additive, up to 19999
georgian(v: int): string
{
	if(v <= 0 || v >= 20000)
		return string v;
	s := "";
	for(i := 0; i < len georgianvals; i++)
		while(v >= georgianvals[i]) {
			c := "";
			c[0] = georgiansyms[i];
			s += c;
			v -= georgianvals[i];
		}
	return s;
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
	Style->Dblock or Style->Dlistitem or Style->Dflowroot or Style->Dflex or Style->Dgrid or Style->Dgridlanes or Style->Dtable =>
		inl = 0;
	}
	if(nd.ns == Dom->SVG && nd.name == "svg") {
		r := newbox(Kreplaced, inl, n, st);
		r.iw = dimattr(b.d.attr(n, "width"), 300);
		r.ih = dimattr(b.d.attr(n, "height"), 150);
		if(b.d.attr(n, "width") == nil && b.d.attr(n, "height") == nil && (vb := viewbox(b.d.attr(n, "viewBox"))) != nil && vb[2] > 0.0 && vb[3] > 0.0) {
			# no size of its own: its ratio is the viewBox's (SVG 2 §8.6),
			# at the default 300 wide
			r.iw = 300;
			r.ih = ir(300.0 * vb[3] / vb[2]);
		}
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
		if(nd.tag == Dom->Tcanvas) {
			# its bitmap's size (HTML §4.12.5: 300 by 150 by default)
			r.iw = dimattr(b.d.attr(n, "width"), 300);
			r.ih = dimattr(b.d.attr(n, "height"), 150);
		}
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
		return nil;	# a block of its text, laid out as pre-wrap (the UA sheet); sized by cols and rows
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
	area:	ref Rect;	# a grid area that is its containing block instead, in cb's coordinates (Grid 2 §9)
	icb:	ref Box;	# a positioned inline box whose padding box is the containing block (§10.1): cb is its block container, and area is set from its fragments once laid out
	flexsp:	int;		# how area serves: 1, 2 a flex container's child, its static position as the sole item of a row or column container (Flexbox §4.1), area being the content box once laid out; 3 a grid's child likewise, in its content box (Grid 2 §9.2); 4 a grid's descendant, whose area is the containing block only, the static position its own
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
	if(b.kind == Kflex || b.kind == Kgrid)
		return 1;	# its items stretch or grow into it, or its rows are sized by it
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
	if(root.doc != nil)
		curdoc = root.doc;	# a frame's document may have been built since
	laygen++;
	l := ref L(width, height, root, nil);
	edges(root, width);
	sizew(root, width, height);
	layblock(l, root, width, height, ref Fctx(nil, nil), root.ml, root.mt);
	root.x = root.ml;
	root.y = root.mt;
	# boxes whose containing block is the viewport, in document order
	# (pending is newest first; pos lists are kept newest first too)
	vp: list of ref Abs;
	for(p := l.pending; p != nil; p = tl p)
		if((hd p).cb == nil)
			vp = hd p :: vp;
	for(; vp != nil; vp = tl vp) {
		a := hd vp;
		if(a.icb != nil && a.area == nil)
			a.area = inlinearea(root, a.icb);
		if(a.flexsp >= 1 && a.flexsp <= 3 && a.area == nil)
			a.area = flexarea(root, a.sparent);
		layabs(l, a, root, Rect((-root.x, -root.y), (width - root.x, height - root.y)));
	}
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
	if(b.kind == Ktable && st.collapse) {
		b.pt = b.pr = b.pb = b.pl = 0;	# no padding in the collapsing model (§17.6.2)
		# and its borders are the outer halves of the collapsed ones,
		# so that a specified width is the grid's, line to line
		t := tgrid(curdoc, b);
		if(t.tb != nil)
			tablehalves(t, b);
	}
	b.mt = res(st.mt, cbw);
	b.mr = res(st.mr, cbw);
	b.mb = res(st.mb, cbw);
	b.ml = res(st.ml, cbw);
	if(b.kind == Kinline || b.kind == Ktext) {
		# vertical margins of inline boxes have no effect on layout
		b.mt = b.mb = 0;
	}
	if(b.kind == Kcell || b.kind == Krow || isrowgroup(b) || iscolumn(b))
		b.mt = b.mr = b.mb = b.ml = 0;	# margins do not apply to internal table boxes (§8.3; margin-applies-to-007)
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
		if(b == nowidth)
			return -1;	# being measured for this very keyword: it does not bound itself
		(mn, mx) := intrinsic(b);	# margin-box widths: the keywords name the border box
		if(b.st.width.kind == Style->Lpx || b.st.width.kind == Style->Lcalc) {
			# a min or max keyword beside a definite width: the
			# content's size, not the width's (fit-content-length-percentage-007)
			onw := nowidth;
			nowidth = b;
			(mn, mx) = intrinsic1(b);
			nowidth = onw;
		}
		mg := mgs(b);
		case v.kind {
		Style->Lmin => return mn - mg;
		Style->Lmax => return mx - mg;
		}
		avail := cbw;
		if(v.px != 0.0 || v.pct != 0.0) {
			# fit-content(<length-percentage>): the argument, a content
			# box size, stands in for the available space (Sizing 3 §4.1)
			if(cbw < 0 && v.pct != 0.0)
				return -1;
			avail = ir(v.px + v.pct * real cbw / 100.0) + mg;
			if(!b.st.borderbox)
				avail += hextra(b);
		}
		return fit(mn, mx, avail) - mg;
	Style->Lstretch =>
		if(cbw < 0)
			return -1;
		return cbw - b.ml - b.mr;	# the stretch-fit size (Sizing 4 §3)
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
	Style->Lstretch =>
		if(cbh < 0)
			return -1;
		return cbh - b.mt - b.mb;
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
# min-height and max-height transferred through the aspect ratio bound
# the width (Sizing 4 §5.2.1); the explicit min-width and max-width,
# applied after, still win
transferw(b: ref Box, w, cbh: int): int
{
	st := b.st;
	if(st.aspect <= 0.0 || b.kind == Kreplaced)
		return w;
	if(st.maxheight.kind != Style->Lnone && (mh := spech(b, st.maxheight, cbh)) >= 0 && (mw := ratiow(b, mh)) >= 0 && w > mw) {
		if(st.minwidth.kind == Style->Lauto && st.width.kind == Style->Lauto && !isscroller(b)) {
			# not below the automatic minimum of an auto width, the content's (Sizing 4 §5.2.2)
			noratio = b;
			(mn, nil) := intrinsic1(b);
			noratio = nil;
			mn -= mgs(b);
			if(mn > mw)
				mw = mn;
		}
		if(w > mw)
			w = mw;
	}
	if((nh := spech(b, st.minheight, cbh)) > 0 && (nw := ratiow(b, nh)) >= 0 && w < nw)
		w = nw;
	return w;
}

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

# a scroll container (overflow other than visible or clip): its
# automatic minimum size is 0 (Sizing 3 §5.1)
isscroller(b: ref Box): int
{
	return b.st.overflowx != Style->Ovisible && b.st.overflowx != Style->Oclip ||
		b.st.overflowy != Style->Ovisible && b.st.overflowy != Style->Oclip;
}

# aspect-ratio (Sizing 4 §5): a non-replaced box with a preferred ratio
# and one size definite takes the other from it.  The ratio is of the
# box box-sizing names.  Border-box sizes in and out; -1 without a ratio.
ratiow(b: ref Box, h: int): int
{
	if(b.st.aspect <= 0.0 || b.kind == Kreplaced)
		return -1;
	if(b.st.borderbox && !b.st.aspectauto)
		return ir(real h * b.st.aspect);
	return ir(real (h - vextra(b)) * b.st.aspect) + hextra(b);
}

# the width transferred from a definite height h (a border box)
# through the ratio: no less than the content's min-content width
# unless min-width says so or the box scrolls (the automatic minimum,
# Sizing 4 §5.2.2); -1 without a ratio
noratio: ref Box;	# being measured without its ratio
transferred(b: ref Box, h: int): int
{
	w := ratiow(b, h);
	if(w >= 0 && b.st.minwidth.kind == Style->Lauto && !isscroller(b)) {
		noratio = b;
		(mn, nil) := intrinsic1(b);
		noratio = nil;
		mn -= mgs(b);
		if(mn > w)
			w = mn;
	}
	return w;
}

ratioh(b: ref Box, w: int): int
{
	if(b.st.aspect <= 0.0 || b.kind == Kreplaced)
		return -1;
	if(b.st.borderbox && !b.st.aspectauto)
		return ir(real w / b.st.aspect);
	return ir(real (w - hextra(b)) / b.st.aspect) + vextra(b);
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
sizew(b: ref Box, cbw, cbh: int)
{
	opcth := pcth;
	pcth = cbh;	# what percentage heights inside see, should its contents be measured
	sizew1(b, cbw, cbh);
	pcth = opcth;
}

sizew1(b: ref Box, cbw, cbh: int)
{
	st := b.st;
	w := specw(b, st.width, cbw);
	if(w < 0 && st.aspect > 0.0 && b.kind != Kreplaced && (sh := spech(b, st.height, cbh)) >= 0)
		w = transferred(b, clamph(b, sh, cbh));	# the height as used, within its min and max
	if(w < 0) {
		if(b.kind == Kreplaced) {
			(iw, nil) := replacedsize(b, cbw, cbh);	# a percentage height transfers to the width
			w = iw + hextra(b);
		} else if(b.kind == Ktable && st.width.kind == Style->Lauto) {
			(mn, mx) := intrinsic(b);
			w = fit(mn, mx, cbw - b.ml - b.mr);
		} else {
			# auto: fill, but if min/max-width step in, auto
			# margins take up the difference
			w = cbw - b.ml - b.mr;
			cw := clampw(b, transferw(b, w, cbh), cbw);
			b.w = cw;
			if(cw == w)
				return;
			w = cw;
		}
	}
	if(st.width.kind != Style->Lpx && st.width.kind != Style->Lcalc)
		w = transferw(b, w, cbh);	# a keyword width is bounded through the ratio like an auto one
	w = clampw(b, w, cbw);
	b.w = w;
	automargins(b, cbw);
}

# auto margins share what is left over of the width cbw (§10.3.3); the
# margins hold their non-auto values (an auto one 0) on entry
automargins(b: ref Box, cbw: int)
{
	st := b.st;
	w := b.w;
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
	} else if(free != 0 && b.parent != nil && b.parent.st.dirrtl)
		b.ml += free;	# over-constrained in a right-to-left block: margin-left gives (§10.3.3)
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
		if(kwsize(b.st.minheight) || kwsize(b.st.maxheight)) {
			# a keyword min or max height: the height the used width
			# gives through the ratio (replaced-min-height-min-content)
			cw := b.w - hextra(b);
			ratio := aspect(b, b.iw, b.ih);
			if(ratio <= 0.0 && b.img != nil)
				ratio = aspect(b, b.img.r.dx(), b.img.r.dy());
			if(ratio > 0.0 && cw > 0) {
				kh := ir(real cw / ratio) + vextra(b);
				if(kwsize(b.st.maxheight) && h > kh)
					h = kh;
				if(kwsize(b.st.minheight) && h < kh)
					h = kh;
			}
		}
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
	else if((rh := ratioh(b, b.w)) >= 0 && b.st.minheight.kind == Style->Lauto)
		ch = rh - vextra(b);	# from its width through its ratio: definite (Sizing 4 §5.3)
	else if(curdoc != nil && curdoc.quirks && b.kind == Kblock && !(b.parent != nil && b.parent.kind == Kcell))
		ch = cbh;	# the percentage height calculation quirk: through auto-height blocks to the nearest definite one, but not a cell's child
	bfc := isbfc(b) || b == l.root || fc == nil;	# the root holds the initial formatting context
	if(bfc) {
		fc = ref Fctx(nil, nil);
		ox = oy = 0;
	}
	cx := ox + b.bl + b.pl;	# content box, in fc
	cy := oy + b.bt + b.pt;
	passtop := !bfc && b.bt == 0 && b.pt == 0;
	passbot := !bfc && b.bb == 0 && b.pb == 0 && sh < 0;
	passempty := !bfc && b.bb == 0 && b.pb == 0 && sh <= 0;	# margins may collapse through it if nothing is in it: a height of zero or auto (§8.3.1)
	mnh := b.st.minheight;
	mhhold := passbot && !(mnh.kind == Style->Lauto || mnh.kind == Style->Lpx && mnh.px == 0.0 && mnh.pct == 0.0);
	if(mhhold)
		passbot = 0;	# a min-height stops the last child's margin collapsing through (§8.3.1)
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
			if(passtop && passempty && b.kind == Kblock &&
			   (mh.kind == Style->Lauto || mh.kind == Style->Lpx && mh.px == 0.0 && mh.pct == 0.0))
				empty = 1;
		}
	} else {
		pending := Margin(0, 0);
		pendingclear := 0;	# the pending margins are an empty cleared box's: they end in this box (§8.3.1)
		cury := 0;
		adjoining := passtop;	# still at the top, margins adjoin ours
		# margin-trim: the first in-flow child's start margin and the
		# last's end margin, what collapses with them included, are
		# trimmed away (Box 4 §4)
		firstflow := 1;
		lastflow := -1;
		if(b.st.margintrim & 2)
			for(j := 0; j < len b.kids; j++)
				if(!isabs(b.kids[j]) && !isfloat(b.kids[j]))
					lastflow = j;
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
				l.pending = ref Abs(k, cbof(l, k), b, sx, b.bt + b.pt + cury + msum(pending), nil, b.st.dirrtl, nil, icbof(k), 0) :: l.pending;
				continue;
			}
			if(isfloat(k)) {
				placefloat(l, k, fc, cx, cy + cury + msum(pending), cw, ch, ox, oy);
				continue;
			}
			edges(k, cw);
			trimtop := (b.st.margintrim & 1) && firstflow;
			trimbot := i == lastflow;
			firstflow = 0;
			if(trimtop)
				k.mt = 0;
			if(trimbot)
				k.mb = 0;
			sizew(k, cw, ch);
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
					# clearance: the margins above no longer collapse with
					# it, and its top border edge goes at the clearance,
					# its own margins (a child's collapsed through it
					# included) used up (margin-collapse-039)
					if(adjoining)
						adjoining = 0;
					cury = cl - msum(collapse(pending, topmargin(k, cw)));
					ky = cl;
				}
			}
			k.x = b.bl + b.pl + k.ml;
			if(isbfc(k) && fc.left != nil || isbfc(k) && fc.right != nil) {
				# a new formatting context does not overlap floats: it
				# narrows beside them, or, when it cannot get narrow
				# enough, moves down past them (CSS 2.2 §9.5); its whole
				# border box keeps clear when its height is known
				# (floats-wrap-top-below-bfc-001l)
				bh := 1;
				if((sh0 := spech(k, k.st.height, ch)) >= 0)
					bh = nz1(clamph(k, sh0, ch) + vextra(k));
				(lx, rx) := band(fc, cy + ky, cy + ky + bh, cx, cx + cw);
				if(lx > cx || rx < cx + cw) {
					# a box of auto width narrows to what is left (and may
					# overflow), but its margins must fit, and a table is
					# never narrower than its minimum; one with a width
					# moves down if its margin box does not fit.  Auto
					# margins take what is left beside the floats, not
					# of the whole width (floats-wrap-top-below-bfc-001r)
					if(k.st.ml.kind == Style->Lauto)
						k.ml = 0;
					if(k.st.mr.kind == Style->Lauto)
						k.mr = 0;
					need := k.ml + k.mr;	# of auto width: its margins at least (floats-wrap-bfc-with-margin-005)
					if(k.st.width.kind != Style->Lauto && k.st.width.kind != Style->Lstretch)
						need = k.ml + k.w;
					else if(k.kind == Ktable) {
						(tmn, nil) := contribution(k);
						need = tmn - k.mr;
					}
					for(tries := 0; tries < 1000 && rx - lx < need && (lx > cx || rx < cx + cw); tries++) {
						n := nextfloat(fc, cy + ky);
						if(n < 0)
							break;
						ky = n - cy;
						cury = ky - msum(collapse(pending, mval(k.mt)));
						cleared = 1;
						adjoining = 0;
						(lx, rx) = band(fc, cy + ky, cy + ky + bh, cx, cx + cw);
					}
					avail := rx - lx - k.ml - k.mr;
					if(k.w > avail && (k.st.width.kind == Style->Lauto || k.st.width.kind == Style->Lstretch))
						k.w = clampw(k, avail, cw);
					automargins(k, rx - lx);
					k.x = lx - ox + k.ml;
				}
			}
			(kt, kb, kempty) := layblock(l, k, cw, ch, fc, ox + k.x, oy + b.bt + b.pt + ky);
			if(trimtop) {
				kt = Margin(0, 0);
				if(kempty)
					kb = Margin(0, 0);	# one collapsed set at the container's start
			}
			if(trimbot) {
				kb = Margin(0, 0);
				if(kempty)
					kt = Margin(0, 0);
			}
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
					k.y = b.bt + b.pt + ky;
					# its collapsed margins end where the clearance put it;
					# a following margin joins them rather than adding
					cury = k.y - b.bt - b.pt - msum(m);
					pending = m;
					pendingclear = 1;
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
			if(cleared)
				k.y = b.bt + b.pt + ky;	# at the clearance, whatever its margins collapsed to (nested-clearance-new-formatting-context)
			cury = k.y - b.bt - b.pt + k.h;
			pending = kb;
			pendingclear = 0;
			relative(k, cw, ch);
		}
		if(b.st.margintrim & 2)
			pending = Margin(0, 0);	# the collapsed set at the end, trimmed whole
		if(adjoining) {
			# no in-flow content at all
			mh := b.st.minheight;
			if(passempty && (mh.kind == Style->Lauto || mh.kind == Style->Lpx && mh.px == 0.0 && mh.pct == 0.0) &&
			   b.kind == Kblock) {
				empty = 1;
				top = collapse(top, pending);
			}
		} else if(passbot && !pendingclear)
			bot = collapse(bot, pending);
		else if(mhhold && !pendingclear) {
			# a min-height that raises the box above its content holds
			# the last child's margin: it neither escapes nor adds to the
			# content, as browsers have it (margin-collapse-min-height-001);
			# one that does not lets it collapse through as usual (-003)
			mn := spech(b, b.st.minheight, cbh);
			if(mn >= 0 && cury >= mn - vextra(b))
				bot = collapse(bot, pending);
		} else
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
	if(h < 0) {
		h = contenth + vextra(b);
		if(b.st.contain & Style->CTsize) {
			# size containment: its explicit intrinsic height, whatever is in it
			h = vextra(b);
			if(b.st.cish.kind == Style->Lpx)
				h += ir(b.st.cish.px);
			if(h > 0)
				empty = 0;
		}
		(nil, rows) := textarea(b);
		if(rows > 0)
			h = ir(real rows * lineheight(b.st, face(b.st))) + vextra(b);	# rows lines, whatever it holds
		if((ah := ratioh(b, b.w)) >= 0) {
			# from its width; an auto min-height keeps the content in
			# (the automatic minimum, Sizing 4 §5.2.2)
			if(ah > h || b.st.minheight.kind != Style->Lauto || isscroller(b))
				h = ah;
			if(h > 0)
				empty = 0;
		}
	}
	# min-content, max-content and fit-content block sizes are the
	# content's (Sizing 3 §3.1: for a block, its auto height), as a
	# min or a max beside another height (block-size-with-min-or-max-content-2)
	hauto := contenth + vextra(b);
	if(kwsize(b.st.maxheight) && h > hauto)
		h = hauto;
	b.h = clamph(b, h, cbh);
	if(kwsize(b.st.minheight) && b.h < hauto)
		b.h = hauto;
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
			l.pending = ref Abs(k, cbof(l, k), b, b.bl + b.pl, b.bt + b.pt, nil, 0, nil, icbof(k), 2 - row) :: l.pending;
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
					# the content size suggestion: its content's, not
					# its width's (Flexbox §4.5)
					nowidth = k;
					(mn, nil) := intrinsic1(k);
					nowidth = nil;
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
		if(mnv.kind == Style->Lauto && fi.maxm >= 0.0 && fi.minm > fi.maxm)
			fi.minm = fi.maxm;	# the automatic minimum is clamped by a definite maximum (§4.5; auto-margins-002)
		fi.hyp = clampr(fi.base, fi.minm, fi.maxm);
	}

	# flex lines (§9.3)
	lines: list of ref Fline;
	st0 := 0;
	used := 0.0;
	# (the margins margin-trim takes off a line's first and last item
	# do not count against the line: flex-row-inline-multiline)
	trimstart := b.st.margintrim & 4;
	trimend := b.st.margintrim & 8;
	if(!row) {
		trimstart = b.st.margintrim & 1;
		trimend = b.st.margintrim & 2;
	}
	for(i = 0; i < n; i++) {
		k := fa[i].box;
		(ms, me) := (k.ml, k.mr);
		if(!row)
			(ms, me) = (k.mt, k.mb);
		outer := fa[i].hyp + real fa[i].mm;
		need := outer;
		if(trimend)
			need -= real me;
		if(i > st0) {
			outer += real gapmain;
			need += real gapmain;
		} else if(trimstart) {
			outer -= real ms;
			need -= real ms;
		}
		if(wrap && i > st0 && mainavail >= 0 && used + need > real mainavail + 0.5) {
			lines = ref Fline(fa[st0:i], 0, 0) :: lines;
			st0 = i;
			used = fa[i].hyp + real fa[i].mm;
			if(trimstart)
				used -= real ms;
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
	# margin-trim: the items' margins at the container's edges go
	# (Box 4 §4.2): on the main axis the first and last item of each
	# line, on the cross axis every item of the first and last line
	if(b.st.margintrim != 0)
		for(i = 0; i < len la; i++) {
			ln := la[i];
			for(j := 0; j < len ln.items; j++) {
				k := ln.items[j].box;
				mainfirst := j == 0;
				mainlast := j == len ln.items - 1;
				crossfirst := i == 0;
				crosslast := i == len la - 1;
				if(row) {
					if(mainfirst && b.st.margintrim & 4) k.ml = 0;
					if(mainlast && b.st.margintrim & 8) k.mr = 0;
					if(crossfirst && b.st.margintrim & 1) k.mt = 0;
					if(crosslast && b.st.margintrim & 2) k.mb = 0;
					ln.items[j].mm = k.ml + k.mr;
				} else {
					if(mainfirst && b.st.margintrim & 1) k.mt = 0;
					if(mainlast && b.st.margintrim & 2) k.mb = 0;
					if(crossfirst && b.st.margintrim & 4) k.ml = 0;
					if(crosslast && b.st.margintrim & 8) k.mr = 0;
					ln.items[j].mm = k.mt + k.mb;
				}
			}
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
			# then the container's min-height and max-height (§9.2 step 4)
			avail = clamph(b, avail + vextra(b), cbh) - vextra(b);
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
		Style->ALend or Style->ALflowend =>
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
			space = clamph(b, usedmain + vextra(b), cbh) - vextra(b);	# auto, within min-height and max-height
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
		# in fractions of a pixel, each position rounded, so that the
		# shares of the free space do not pile their remainders up
		rstart := real start;
		rgap := real gap;
		case jc {
		Style->ALend or Style->ALflowend =>
			rstart = real freem;
		Style->ALright =>
			# physical: the end of a row, the start of a reversed one
			# (the line is mirrored after placing); in a column, left and
			# right are start (Align 3 §5.1)
			if(row && !rev || !row && rev)
				rstart = real freem;	# (a column's start is its top, the end of a reversed one)
		Style->ALleft =>
			if(rev)
				rstart = real freem;
		Style->ALcenter =>
			rstart = real freem / 2.0;
		Style->ALbetween =>
			if(nit > 1 && freem > 0)
				rgap += real freem / real (nit - 1);
		Style->ALaround =>
			if(freem > 0) {
				rgap += real freem / real nz1(nit);
				rstart = real freem / real nz1(nit) / 2.0;
			}
		Style->ALevenly =>
			if(freem > 0) {
				rgap += real freem / real (nit + 1);
				rstart = real freem / real (nit + 1);
			}
		}
		mp := rstart;
		for(j = 0; j < nit; j++) {
			fi := ln.items[j];
			fi.pos = ir(mp);
			mp += real (ir(fi.main) + fi.mm) + rgap;
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
	Style->ALend or Style->ALright or Style->ALflowend =>
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
	if(k.kind == Kreplaced && k.svg && k.iw == 0 && k.ih == 0)
		mn = mgs(k);	# no natural width: the default size is contained in the room there is (Images 3 §4.3; align-items-007)
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
Tfixed, Tpct, Tfr, Tauto, Tmin, Tmax, Tfit: con iota;	# Tfit: fit-content(v), max-content no wider than v

Tsz: adt {
	kind:	int;
	v:	real;		# px, percent or fr
};

Track: adt {
	lo, hi:	Tsz;		# minmax(lo, hi); a plain size has lo == hi
	base:	real;		# the track's size as it is worked out
	limit:	real;		# growth limit (-1: infinite)
	fit:	int;		# from an auto-fit repeat: 1, or 2 once collapsed for want of items (§7.2.3.2)
	endp:	int;		# where it ends, set with its position by trackpos: the next track's start less the gutter and any distributed space
};

Gi: adt {
	box:	ref Box;
	r0, r1, c0, c1:	int;	# lines, 0-based: rows r0..r1-1, columns c0..c1-1
	extra:	int;		# added to its contribution: a subgrid's edges, for the items at them
	empty:	int;		# contributes nothing but extra: a subgrid's edge with no item in that track
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
			return ref Track(lo, hi, 0.0, 0.0, 0, 0);
		"fit-content" =>
			x := nows(t.kids);
			if(len x != 1)
				return nil;
			(ok, hi) := tsz(x[0]);
			if(!ok)
				return nil;
			if(hi.kind == Tfixed)
				hi = Tsz(Tfit, hi.v);
			return ref Track(Tsz(Tauto, 0.0), hi, 0.0, 0.0, 0, 0);
		}
		return nil;
	}
	(ok, sz) := tsz(t);
	if(!ok)
		return nil;
	lo := sz;
	if(sz.kind == Tfr)
		lo = Tsz(Tauto, 0.0);	# 1fr is minmax(auto, 1fr)
	return ref Track(lo, sz, 0.0, 0.0, 0, 0);
}

# what an intrinsically sized track in an auto-repeat counts as when
# the repetitions are counted: grid lanes set it to the smallest
# contribution an item makes to a lane (Grid 3 §5.1)
repsize := 0.0;

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
						if(sz.kind != Tfixed && sz.kind != Tpct && sz.kind != Tfit)
							sz = rt[k].lo;
						case sz.kind {
						Tfixed or Tfit => per += sz.v;
						Tpct => per += sz.v * real avail / 100.0;
						* => per += repsize;
						}
					}
					per += real (gap * len rt);
					reps = 1;
					if(avail > 0 && per > 0.0)
						reps = int ((real avail + real gap) / per - 0.4999);
					if(reps < 1)
						reps = 1;
				}
				fit := cnt[0].kind == Css->Kident && (cnt[0].s == "auto-fit" || cnt[0].s == "AUTO-FIT");
				for(k := 0; k < reps; k++) {
					for(m := 0; m < len rt; m++) {
						for(nl := rn[m]; nl != nil; nl = tl nl)
							names = (nt, hd nl) :: names;
						c := ref *rt[m];
						c.fit = fit;
						tlist = c :: tlist;
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

# an auto-fit repeat's tracks that no item occupies collapse: no size,
# and the gutters around them join (Grid 2 §7.2.3.2)
collapsefit(t: array of ref Track, items: array of ref Gi, cols: int)
{
	for(i := 0; i < len t; i++) {
		if(t[i].fit != 1)
			continue;
		used := 0;
		for(j := 0; j < len items && !used; j++) {
			(a0, a1) := (items[j].c0, items[j].c1);
			if(!cols)
				(a0, a1) = (items[j].r0, items[j].r1);
			if(a0 <= i && i < a1)
				used = 1;
		}
		if(!used) {
			t[i].fit = 2;
			t[i].lo = Tsz(Tfixed, 0.0);
			t[i].hi = Tsz(Tfixed, 0.0);
		}
	}
}

anypct(t: array of ref Track): int
{
	for(i := 0; i < len t; i++)
		if(t[i].lo.kind == Tpct || t[i].hi.kind == Tpct)
			return 1;
	return 0;
}

# the gaps between n tracks, less those collapsed away
ngaps(t: array of ref Track): int
{
	n := 0;
	for(i := 0; i < len t; i++)
		if(t[i].fit != 2)
			n++;
	return nz(n - 1);
}

# the line a Gline names, 0-based, given the explicit grid's line names;
# -1 if auto
lineof(g: Style->Gline, names: array of list of string, ntracks: int, end: int): int
{
	if(g.name != nil && !g.span) {
		# the nth line so named (the first; from the end if negative);
		# past them, the implicit lines all have the name (§8.3)
		suffix := "-start";
		if(end)
			suffix = "-end";
		want := g.n;
		if(want == 0)
			want = 1;
		if(want > 0) {
			seen := 0;
			for(i := 0; i < len names; i++)
				if(hasname(names[i], g.name, suffix) && ++seen == want)
					return i;
			if(seen == 0 && g.n == 0)
				return -1;
			n := ntracks + want - seen;
			if(n > MAXTRACKS)
				n = MAXTRACKS;
			return n;
		}
		seen := 0;
		for(i := len names - 1; i >= 0; i--)
			if(hasname(names[i], g.name, suffix) && ++seen == -want)
				return i;
		return 0;
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

hasname(l: list of string, name, suffix: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == name || hd l == name + suffix)
			return 1;
	return 0;
}

# the line n lines named so from line from, in direction dir (§8.3:
# "span a" counts lines with that name); past the grid, implicit lines
namedspan(names: array of list of string, from: int, name: string, n, dir, ntracks: int): int
{
	seen := 0;
	for(i := from + dir; i >= 0 && i < len names; i += dir)
		if(hasname(names[i], name, "") && ++seen == n)
			return i;
	if(dir < 0)
		return 0;
	r := ntracks + n - seen;
	if(from + 1 > r)
		r = from + 1;
	if(r > MAXTRACKS)
		r = MAXTRACKS;
	return r;
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
	if(islanes(b)) {
		laylanes(l, b, cbw, cbh);
		return;
	}
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
	# a subgrid's tracks in an axis are its parent's, as the parent
	# sized them (Grid 2 §9)
	if(b.subcw != nil) {
		colgap = b.subcgap;
		own := copyints(b.subcw);	# this layout may run again
		if((gs := subgap(b, 1, colgap)) >= 0) {
			regap(own, gs - colgap);
			colgap = gs;
		}
		cols = fixedtracks(own);
		colnames = b.subcnames;
	}
	if(b.subrh != nil) {
		rowgap = b.subrgap;
		own := copyints(b.subrh);
		if((gs := subgap(b, 0, rowgap)) >= 0) {
			regap(own, gs - rowgap);
			rowgap = gs;
		}
		rows = fixedtracks(own);
		rownames = b.subrnames;
		# its height is its tracks', whatever its properties say (§9.3)
		ch = rowgap * nz(len rows - 1);
		for(i := 0; i < len rows; i++)
			ch += own[i];
		sh = ch + vextra(b);
	}
	ncexp := len cols;
	nrexp := len rows;
	rowpct := anypct(rows) && b.subrh == nil;
	ars := areas(st.gridareas);
	for(a := ars; a != nil; a = tl a) {
		(nil, nil, r1, nil, c1) := hd a;
		if(c1 > len cols)
			cols = growtracks(cols, c1, st.autocols, cw);
		if(r1 > len rows)
			rows = growtracks(rows, r1, st.autorows, ch);
	}
	(items, ncols, nrows) := gridplace(b, len cols, len rows, colnames, rownames, ars);
	cols = growtracks(cols, ncols, st.autocols, cw);
	rows = growtracks(rows, nrows, st.autorows, ch);
	collapsefit(cols, items, 1);
	collapsefit(rows, items, 0);

	# column sizes, then rows (laying items out at their column widths);
	# a subgrid in an axis stands aside for its items, and is told the
	# tracks it spans before it is laid out
	for(i := 0; i < len items; i++) {
		k := items[i].box;
		k.subcw = nil;
		k.subrh = nil;
	}
	colsizing := subgridded(items, 1, colgap);
	sizetracks(cols, colsizing, 1, cw, colgap, b);
	cpos := trackpos(cols, colgap, cw, st.justifycontent);
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		edges(k, areaw(cols, cpos, g.c0, g.c1, colgap));
		if(b.st.margintrim != 0) {
			# margin-trim: the margins of items at the grid's edges go (Box 4 §4.2)
			if(g.c0 == 0 && b.st.margintrim & 4) k.ml = 0;
			if(g.c1 == ncols && b.st.margintrim & 8) k.mr = 0;
			if(g.r0 == 0 && b.st.margintrim & 1) k.mt = 0;
			if(g.r1 == nrows && b.st.margintrim & 2) k.mb = 0;
		}
		if(issubgrid(k, 1)) {
			k.subcw = subtracks(tracksizes(cols, g.c0, g.c1), k.ml + k.bl + k.pl, k.mr + k.br + k.pr);
			k.subcnames = mergenames(colnames, g.c0, g.c1, subnames(k.st.gridcols));
			k.subcgap = colgap;
		}
	}
	# items' heights at their widths
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		aw := areaw(cols, cpos, g.c0, g.c1, colgap);
		k.w = gridw(k, aw, b);
		layblock(l, k, aw, -1, nil, 0, 0);
	}
	rowsizing := subgridded(items, 0, rowgap);
	sizetracks(rows, rowsizing, 0, ch, rowgap, b);
	gh := 0;
	for(i = 0; i < len rows; i++)
		gh += ir(rows[i].base);
	gh += rowgap * ngaps(rows);
	if(ch < 0 && rowpct) {
		# percentage rows in a container whose height they decide:
		# auto for that height, then resolved against it (§7.2.1)
		(again, nil) := tracks(st.gridrows, gh, rowgap);
		again = growtracks(again, len rows, st.autorows, gh);
		collapsefit(again, items, 0);
		sizetracks(again, rowsizing, 0, gh, rowgap, b);
		rows = again;
	}
	avh := ch;
	if(avh < 0)
		avh = gh;
	rpos := trackpos(rows, rowgap, avh, st.aligncontent);
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		if(issubgrid(k, 0)) {
			k.subrh = subtracks(tracksizes(rows, g.r0, g.r1), k.mt + k.bt + k.pt, k.mb + k.bb + k.pb);
			k.subrnames = mergenames(rownames, g.r0, g.r1, subnames(k.st.gridrows));
			k.subrgap = rowgap;
		}
	}

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
		if(issubgrid(k, 0)) {
			# its height is its tracks', whatever its properties say (§9.3)
			imposeh(l, k, ah - k.mt - k.mb, aw, ah);
		} else if((as == Style->ALnormal || as == Style->ALstretch) && ks.height.kind == Style->Lauto &&
		   ks.mt.kind != Style->Lauto && ks.mb.kind != Style->Lauto && k.kind != Kreplaced) {
			imposeh(l, k, clamph(k, ah - k.mt - k.mb, ah), aw, ah);
		} else if(ks.height.pct != 0.0 || ks.minheight.pct != 0.0 || ks.maxheight.pct != 0.0 || heightmatters(k)) {
			# the area's height is definite for it (Grid 2 §6.6)
			layblock(l, k, aw, ah, nil, 0, 0);
		}
		x := ax + k.ml + crossoff(js, aw, k.w + k.ml + k.mr);
		if(ks.ml.kind == Style->Lauto && ks.mr.kind == Style->Lauto)
			x = ax + (aw - k.w)/2;
		if(st.dirrtl && !issubgrid(b, 1) && !islanes(b)) {
			# the columns run from the right (Grid 2 §7.1): the area
			# is mirrored, start being its right edge; left and right
			# stay physical (a subgrid's tracks are its parent's, in
			# the parent's order; grid lanes mirror their own)
			x = cw - ax - aw + k.ml + (aw - k.w - k.ml - k.mr) - crossoff(js, aw, k.w + k.ml + k.mr);
			if(js == Style->ALleft || js == Style->ALright)
				x = cw - ax - aw + k.ml + crossoff(js, aw, k.w + k.ml + k.mr);
			if(ks.ml.kind == Style->Lauto && ks.mr.kind == Style->Lauto)
				x = cw - ax - aw + (aw - k.w)/2;
		}
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
	hauto := gh + vextra(b);
	if(kwsize(b.st.maxheight) && h > hauto)
		h = hauto;	# a keyword block size is the content's (block-size-with-min-or-max-content-3)
	b.h = clamph(b, h, cbh);
	if(kwsize(b.st.minheight) && b.h < hauto)
		b.h = hauto;
	gridabs(l, b, cols, cpos, colgap, colnames, ncexp, rows, rpos, rowgap, rownames, nrexp, ars);
}

# Place a grid container's items (Grid 2 §8.5): definite in both
# axes, then those definite in the axis items flow along, then the
# rest, sparsely or densely.  The children are first put in
# order-modified document order, which is the painting order too
# (§10.1); absolutely positioned children are not items and keep their
# places.  Returns the items and the implicit grid's size.
gridplace(b: ref Box, lencols, lenrows: int, colnames, rownames: array of list of string, ars: list of (string, int, int, int, int)): (array of ref Gi, int, int)
{
	st := b.st;
	clampc := b.subcw != nil;	# a subgrid has no implicit grid: lines past its own are clamped (§9.4)
	clampr := b.subrh != nil;
	ncols := lencols;
	if(ncols == 0)
		ncols = 1;
	nrows := lenrows;
	if(nrows == 0)
		nrows = 1;
	# the children in order-modified document order, which is the
	# painting order too (Grid 2 §10.1); absolutely positioned
	# children are not items and keep their places
	for(oi := 1; oi < len b.kids; oi++)
		for(om := oi; om > 0 && orderof(b.kids[om]) < orderof(b.kids[om-1]); om--)
			(b.kids[om], b.kids[om-1]) = (b.kids[om-1], b.kids[om]);

	# placement
	gi: list of ref Gi;
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k))
			continue;	# placed once the tracks are: gridabs
		ks := k.st;
		g := ref Gi(k, -1, -1, -1, -1, 0, 0);
		if(ks.gridarea != nil) {
			for(a := ars; a != nil; a = tl a) {
				(an, r0, r1, c0, c1) := hd a;
				if(an == ks.gridarea) {
					(g.r0, g.r1, g.c0, g.c1) = (r0, r1, c0, c1);
					break;
				}
			}
		}
		if(g.r0 < 0) {
			(g.c0, g.c1) = gridspan(ks.colstart, ks.colend, colnames, lencols, ars, 1);
			(g.r0, g.r1) = gridspan(ks.rowstart, ks.rowend, rownames, lenrows, ars, 0);
		}
		if(clampc && g.c0 >= 0)
			(g.c0, g.c1) = clamplines(g.c0, g.c1, lencols);
		if(clampr && g.r0 >= 0)
			(g.r0, g.r1) = clamplines(g.r0, g.r1, lenrows);
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
	# definite in the axis items flow along only: the first free cells
	# in that row (or column), past what this step put there (§8.5 step 1)
	rcur := array[nrows] of {* => 0};
	ccur := array[ncols] of {* => 0};
	for(i = 0; i < len items; i++) {
		g := items[i];
		ks := g.box.st;
		if(!colflow && g.r0 >= 0 && g.c0 < 0) {
			cs := spanof(g.c0, g.c1, ks.colstart, ks.colend);
			c := rcur[g.r0];
			while(!occ.free(g.r0, g.r1, c, c + cs))
				c++;
			g.c0 = c;
			g.c1 = c + cs;
			rcur[g.r0] = g.c1;
			if(g.c1 > ncols)
				ncols = g.c1;
			occ.mark(g.r0, g.r1, g.c0, g.c1);
		} else if(colflow && g.c0 >= 0 && g.r0 < 0) {
			rs := spanof(g.r0, g.r1, ks.rowstart, ks.rowend);
			r := ccur[g.c0];
			while(!occ.free(r, r + rs, g.c0, g.c1))
				r++;
			g.r0 = r;
			g.r1 = r + rs;
			ccur[g.c0] = g.r1;
			if(g.r1 > nrows)
				nrows = g.r1;
			occ.mark(g.r0, g.r1, g.c0, g.c1);
		}
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
			}
		}
		if(g.c1 > ncols)
			ncols = g.c1;
		occ.mark(g.r0, g.r1, g.c0, g.c1);
	}
	nrows = lenrows;
	for(i = 0; i < len items; i++) {
		# every item spans at least one track: a negative index later
		# is a crash under the JIT
		g := items[i];
		if(g.c0 < 0)
			g.c0 = 0;
		if(g.r0 < 0)
			g.r0 = 0;
		if(g.c1 <= g.c0)
			g.c1 = g.c0 + 1;
		if(g.r1 <= g.r0)
			g.r1 = g.r0 + 1;
		if(g.r1 > nrows)
			nrows = g.r1;
		if(g.c1 > ncols)
			ncols = g.c1;
	}
	return (items, ncols, nrows);
}

clamplines(a0, a1, n: int): (int, int)
{
	if(n < 1)
		n = 1;
	if(a1 > n)
		a1 = n;
	if(a0 >= a1)
		a0 = a1 - 1;
	if(a0 < 0)
		a0 = 0;
	if(a1 <= a0)
		a1 = a0 + 1;
	return (a0, a1);
}

# whether k is a subgrid in an axis: its tracks there are its parent's
issubgrid(k: ref Box, cols: int): int
{
	if(k.kind != Kgrid || islanes(k))
		return 0;
	if(cols)
		return k.st.subcols;
	return k.st.subrows;
}

fixedtracks(a: array of int): array of ref Track
{
	t := array[len a] of ref Track;
	for(i := 0; i < len a; i++)
		t[i] = ref Track(Tsz(Tfixed, real a[i]), Tsz(Tfixed, real a[i]), 0.0, 0.0, 0, 0);
	return t;
}

# the tracks a subgrid spans, as its own: its margin, border and
# padding at either edge come out of the first and last (§9.5), so
# that its lines stay its parent's
subtracks(a: array of int, lead, trail: int): array of int
{
	if(len a == 0)
		return a;
	a[0] -= lead;
	a[len a - 1] -= trail;
	if(a[0] < 0)
		a[0] = 0;
	if(a[len a - 1] < 0)
		a[len a - 1] = 0;
	return a;
}

copyints(a: array of int): array of int
{
	b := array[len a] of int;
	b[0:] = a;
	return b;
}

# a subgrid's gutters widened by d (narrowed if negative): the tracks
# either side of each give up half of it, so the lines stay put
regap(a: array of int, d: int)
{
	for(i := 0; i + 1 < len a; i++) {
		a[i] -= d - d/2;
		a[i+1] -= d/2;
		if(a[i] < 0)
			a[i] = 0;
		if(a[i+1] < 0)
			a[i+1] = 0;
	}
}

tracksizes(t: array of ref Track, a0, a1: int): array of int
{
	if(a1 > len t)
		a1 = len t;
	if(a0 > a1)
		a0 = a1;
	a := array[a1 - a0] of int;
	for(i := a0; i < a1; i++)
		a[i - a0] = ir(t[i].base);
	return a;
}

# a subgrid's line names: its parent's for the lines it spans, and its
# own, given in order ([a] [b] ...) after the subgrid keyword
subnames(v: array of ref Tok): array of list of string
{
	l: list of list of string;
	n := 0;
	for(i := 0; i < len v; i++) {
		t := v[i];
		if(t.kind != Css->Kblock || t.s != "[")
			continue;
		names: list of string;
		for(k := 0; k < len t.kids; k++)
			if(t.kids[k].kind == Css->Kident)
				names = t.kids[k].s :: names;
		l = names :: l;
		n++;
	}
	a := array[n] of list of string;
	for(i = n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

mergenames(parent: array of list of string, a0, a1: int, own: array of list of string): array of list of string
{
	n := a1 - a0 + 1;
	if(n < 1)
		n = 1;
	a := array[n] of list of string;
	for(i := 0; i < n; i++) {
		if(a0 + i < len parent)
			a[i] = parent[a0 + i];
		if(i < len own)
			for(l := own[i]; l != nil; l = tl l)
				a[i] = hd l :: a[i];
	}
	return a;
}

# the items that size an axis: a subgrid in it stands aside for its
# items, which take the lines it spans and, at its edges, its margin,
# border and padding (Grid 2 §9.5); so on down through nested subgrids
subgridded(items: array of ref Gi, cols, pgap: int): array of ref Gi
{
	l: list of ref Gi;
	n := 0;
	for(i := 0; i < len items; i++) {
		g := items[i];
		if(issubgrid(g.box, cols)) {
			for(sl := subitems(g.box, g, cols, pgap); sl != nil; sl = tl sl) {
				l = hd sl :: l;
				n++;
			}
		} else {
			l = g :: l;
			n++;
		}
	}
	a := array[n] of ref Gi;
	for(i = n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

# a subgrid's own gap, if it gives one, replaces its parent's within
# it: the difference is half a margin on each item beside the gutter
# (Grid 2 §9.3); -1 when it gives none
subgap(k: ref Box, cols, pgap: int): int
{
	ks := k.st;
	if(cols) {
		if(ks.colgap.kind == Style->Lnormal)
			return -1;
		return res(ks.colgap, 0);
	}
	if(ks.rowgap.kind == Style->Lnormal)
		return -1;
	return res(ks.rowgap, 0);
}

subitems(k: ref Box, g: ref Gi, cols, pgap: int): list of ref Gi
{
	ks := k.st;
	gd := 0;	# the gap difference items beside a gutter carry, half each
	if((gs := subgap(k, cols, pgap)) >= 0)
		gd = gs - pgap;
	(kcols, kcn) := tracks(ks.gridcols, -1, 0);
	(krows, krn) := tracks(ks.gridrows, -1, 0);
	nc := len kcols;
	nr := len krows;
	if(ks.subcols)
		nc = g.c1 - g.c0;
	if(ks.subrows)
		nr = g.r1 - g.r0;
	# placed as a subgrid would place them (lines past its own clamped)
	ocw := k.subcw;
	orh := k.subrh;
	if(ks.subcols && ocw == nil)
		k.subcw = array[nc] of {* => 0};
	if(ks.subrows && orh == nil)
		k.subrh = array[nr] of {* => 0};
	(inner, nil, nil) := gridplace(k, nc, nr, kcn, krn, areas(ks.gridareas));
	k.subcw = ocw;
	k.subrh = orh;
	if(k.ml == 0 && k.mr == 0 && k.bl == 0 && k.pl == 0)
		edges(k, 0);
	span := nc;
	lead := k.ml + k.bl + k.pl;
	trail := k.mr + k.br + k.pr;
	if(!cols) {
		span = nr;
		lead = k.mt + k.bt + k.pt;
		trail = k.mb + k.bb + k.pb;
	}
	r: list of ref Gi;
	for(i := 0; i < len inner; i++) {
		ig := inner[i];
		v := ref Gi(ig.box, g.r0, g.r1, g.c0, g.c1, 0, 0);
		first := 0;
		last := 0;
		if(cols) {
			if(ks.subcols) {
				v.c0 = g.c0 + ig.c0;
				v.c1 = g.c0 + ig.c1;
				if(v.c1 > g.c1)
					v.c1 = g.c1;
				first = ig.c0 == 0;
				last = ig.c1 >= span;
			}
		} else if(ks.subrows) {
			v.r0 = g.r0 + ig.r0;
			v.r1 = g.r0 + ig.r1;
			if(v.r1 > g.r1)
				v.r1 = g.r1;
			first = ig.r0 == 0;
			last = ig.r1 >= span;
		}
		if(first)
			v.extra += lead;
		else
			v.extra += gd - gd/2;
		if(last)
			v.extra += trail;
		else
			v.extra += gd/2;
		if(issubgrid(ig.box, cols)) {
			for(sl := subitems(ig.box, v, cols, pgap); sl != nil; sl = tl sl) {
				w := hd sl;
				if(cols && w.c0 == v.c0 || !cols && w.r0 == v.r0)
					w.extra += lead;
				if(cols && w.c1 == v.c1 || !cols && w.r1 == v.r1)
					w.extra += trail;
				r = w :: r;
			}
		} else
			r = v :: r;
	}
	# an edge with no item in its track still counts, as an empty item would
	seenfirst := 0;
	seenlast := 0;
	for(rl := r; rl != nil; rl = tl rl) {
		w := hd rl;
		if(cols && w.c0 == g.c0 || !cols && w.r0 == g.r0)
			seenfirst = 1;
		if(cols && w.c1 == g.c1 || !cols && w.r1 == g.r1)
			seenlast = 1;
	}
	if(!seenfirst && lead > 0) {
		e := ref Gi(k, g.r0, g.r0 + 1, g.c0, g.c0 + 1, lead, 1);
		if(!cols)
			(e.c0, e.c1) = (g.c0, g.c1);
		else
			(e.r0, e.r1) = (g.r0, g.r1);
		r = e :: r;
	}
	if(!seenlast && trail > 0) {
		e := ref Gi(k, g.r1 - 1, g.r1, g.c1 - 1, g.c1, trail, 1);
		if(!cols)
			(e.c0, e.c1) = (g.c0, g.c1);
		else
			(e.r0, e.r1) = (g.r0, g.r1);
		r = e :: r;
	}
	return r;
}

# An absolutely positioned child of a grid container: its static
# position is the padding box's start, and, when the container is its
# containing block, the lines it names bound that block (Grid 2 §9)
gridabs(l: ref L, b: ref Box, cols: array of ref Track, cpos: array of int, colgap: int, colnames: array of list of string, ncexp: int,
	rows: array of ref Track, rpos: array of int, rowgap: int, rownames: array of list of string, nrexp: int, ars: list of (string, int, int, int, int))
{
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(!isabs(k))
			continue;
		cb := cbof(l, k);
		if(cb == b)
			l.pending = ref Abs(k, cb, b, b.bl, b.bt, nil, 0, ref gridabsarea(b, k, cols, cpos, colgap, colnames, ncexp, rows, rpos, rowgap, rownames, nrexp, ars), nil, 0) :: l.pending;
		else
			l.pending = ref Abs(k, cb, b, b.bl, b.bt, nil, 0, nil, nil, 3) :: l.pending;	# the static position is in the grid's content box, the containing block elsewhere (grid-abspos-staticpos-align-items-center)
	}
	# a descendant whose containing block is the grid takes its grid
	# area too (§9.1), its static position its own (descendant-static-position-001)
	for(pl := l.pending; pl != nil; pl = tl pl) {
		a := hd pl;
		if(a.cb != b || a.sparent == b || a.area != nil || a.icb != nil || a.flexsp != 0)
			continue;
		a.area = ref gridabsarea(b, a.box, cols, cpos, colgap, colnames, ncexp, rows, rpos, rowgap, rownames, nrexp, ars);
		a.flexsp = 4;
	}
}

# the grid area that is the containing block of the absolutely
# positioned box k: each edge a line of the explicit grid, or else the
# padding edge (§9.1)
gridabsarea(b, k: ref Box, cols: array of ref Track, cpos: array of int, colgap: int, colnames: array of list of string, ncexp: int,
	rows: array of ref Track, rpos: array of int, rowgap: int, rownames: array of list of string, nrexp: int, ars: list of (string, int, int, int, int)): Rect
{
	r := Rect((b.bl, b.bt), (b.w - b.br, b.h - b.bb));
	(c0, c1) := abslines(k.st.colstart, k.st.colend, colnames, ncexp, ars, 1);
	if(b.st.dirrtl) {
		# the columns run from the right: the start line is the area's right edge
		cw := b.w - hextra(b);
		if(c0 >= 0)
			r.max.x = b.bl + b.pl + cw - gridlinestart(cols, cpos, c0, colgap);
		if(c1 >= 0)
			r.min.x = b.bl + b.pl + cw - gridlineend(cols, cpos, c1, colgap);
	} else {
		if(c0 >= 0)
			r.min.x = b.bl + b.pl + gridlinestart(cols, cpos, c0, colgap);
		if(c1 >= 0)
			r.max.x = b.bl + b.pl + gridlineend(cols, cpos, c1, colgap);
	}
	(r0, r1) := abslines(k.st.rowstart, k.st.rowend, rownames, nrexp, ars, 0);
	if(r0 >= 0)
		r.min.y = b.bt + b.pt + gridlinestart(rows, rpos, r0, rowgap);
	if(r1 >= 0)
		r.max.y = b.bt + b.pt + gridlineend(rows, rpos, r1, rowgap);
	return r;
}

# the lines an absolutely positioned child names in one axis: -1 for
# auto, a span, or a line outside the explicit grid, each of which is
# the padding edge; the two swapped if backwards, and one alone if equal
abslines(sg, eg: Style->Gline, names: array of list of string, nexp: int, ars: list of (string, int, int, int, int), cols: int): (int, int)
{
	a := absline(sg, names, nexp, 0, ars, cols);
	e := absline(eg, names, nexp, 1, ars, cols);
	if(a >= 0 && e >= 0 && e < a)
		(a, e) = (e, a);
	if(a >= 0 && a == e)
		e = -1;
	return (a, e);
}

absline(g: Style->Gline, names: array of list of string, nexp, end: int, ars: list of (string, int, int, int, int), cols: int): int
{
	if(g.span || g.n == 0 && g.name == nil)
		return -1;
	if(g.n < 0 && nexp + 1 + g.n < 0)
		return -1;
	i := lineof(g, names, nexp, end);
	if(i < 0 && g.name != nil)
		for(l := ars; l != nil; l = tl l) {
			(an, r0, r1, c0, c1) := hd l;
			if(an != g.name)
				continue;
			if(cols)
				i = c0;
			else
				i = r0;
			if(end) {
				i = r1;
				if(cols)
					i = c1;
			}
		}
	if(i < 0 || i > nexp)
		return -1;
	return i;
}

# where line i is: the start of track i, or the end of the last track
gridlinestart(t: array of ref Track, pos: array of int, i, gap: int): int
{
	if(len t == 0)
		return 0;
	if(i < len t)
		return pos[i];
	return trackend(t, pos, len t - 1, gap);
}

# where line i is as an area's end: the end of track i-1
gridlineend(t: array of ref Track, pos: array of int, i, gap: int): int
{
	if(len t == 0)
		return 0;
	if(i <= 0)
		return pos[0];
	if(i > len t)
		i = len t;
	return trackend(t, pos, i - 1, gap);
}

# ---- grid lanes (Grid 3) ----
#
# Tracks in one axis, as a grid has; in the other, the items stack one
# after another, each going into whichever lane is shortest.

islanes(b: ref Box): int
{
	return b.kind == Kgrid && (b.st.display == Style->Dgridlanes || b.st.display == Style->Dinlinegridlanes);
}

# the lanes run down (the tracks are columns) unless the direction says
# row, or says nothing and only rows are given
lanesdown(b: ref Box): int
{
	st := b.st;
	case st.lanesdir & 3 {
	1 =>	return 0;
	2 =>	return 1;
	}
	return st.gridcols != nil || st.gridrows == nil;
}

# an item's lines in the grid axis
glines(g: ref Gi, down: int): (int, int)
{
	if(down)
		return (g.c0, g.c1);
	return (g.r0, g.r1);
}

setlines(g: ref Gi, down, a0, a1: int)
{
	if(down)
		(g.c0, g.c1) = (a0, a1);
	else
		(g.r0, g.r1) = (a0, a1);
}

# room left in a lane behind an item that spans past it: an item may
# start at a and must end by e (leaving the gutter before the next)
Gap: adt {
	a, e:	int;
	prev:	int;	# the item before it, whose alignment container it is part of; -1 at the lane's start
};

# the width an item takes stacking along the inline axis: its own
# (it does not stretch), fitting the container
lanesw(k: ref Box, cw: int): int
{
	w := specw(k, k.st.width, cw);
	if(w >= 0)
		return clampw(k, w, cw);
	if(k.kind == Kreplaced) {
		(rw, nil) := replacedsize(k, cw, -1);
		return clampw(k, rw + hextra(k), cw);
	}
	(mn, mx) := intrinsic(k);
	if(k.kind == Kreplaced && k.svg && k.iw == 0 && k.ih == 0)
		mn = mgs(k);	# no natural width: the default size is contained in the room there is (Images 3 §4.3; align-items-007)
	return clampw(k, fit(mn, mx, cw) - mgs(k), cw);
}

laylanes(l: ref L, b: ref Box, cbw, cbh: int)
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
	down := lanesdown(b);
	fillrev := st.lanesdir & 4;
	trackrev := st.lanesdir & 8;
	# the grid axis: its tracks, size and gap; the stacking axis: its size and gutter
	tmpl := st.gridcols;
	auto := st.autocols;
	avail := cw;
	tgap := colgap;
	savail := ch;
	sgap := rowgap;
	if(!down) {
		tmpl = st.gridrows;
		auto = st.autorows;
		avail = ch;
		tgap = rowgap;
		savail = cw;
		sgap = colgap;
	}
	# an auto-repeat of intrinsic lanes: as many as the items'
	# smallest max-content contribution fills (across, only a height
	# given counts)
	first := 1;
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k))
			continue;
		edges(k, cw);
		kmn: int;
		span: int;
		if(down) {
			(nil, kmn) = contribution(k);	# its max-content
			(ka0, ka1) := gridspan(k.st.colstart, k.st.colend, nil, 0, nil, 1);
			span = spanof(ka0, ka1, k.st.colstart, k.st.colend);
		} else {
			kmn = specheight(k, ch);
			if(kmn < 0)
				continue;
			kmn += k.mt + k.mb;
			(ka0, ka1) := gridspan(k.st.rowstart, k.st.rowend, nil, 0, nil, 0);
			span = spanof(ka0, ka1, k.st.rowstart, k.st.rowend);
		}
		per := real (kmn - tgap * (span - 1)) / real span;
		if(first || per < repsize)
			repsize = per;
		first = 0;
	}
	(tr, names) := tracks(tmpl, avail, tgap);
	repsize = 0.0;
	tpct := anypct(tr);
	if(len tr == 0)
		tr = growtracks(tr, 1, auto, avail);

	# the children in order-modified document order, which is the
	# painting order too (Grid 2 §10.1); absolutely positioned
	# children are not items and keep their places
	for(oi := 1; oi < len b.kids; oi++)
		for(om := oi; om > 0 && orderof(b.kids[om]) < orderof(b.kids[om-1]); om--)
			(b.kids[om], b.kids[om-1]) = (b.kids[om-1], b.kids[om]);
	# the items, with their lines where those are definite
	gi: list of ref Gi;
	for(i = 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k))
			continue;	# placed once the tracks are: gridabs
		ks := k.st;
		g := ref Gi(k, -1, -1, -1, -1, 0, 0);
		if(down)
			(g.c0, g.c1) = gridspan(ks.colstart, ks.colend, names, len tr, nil, 1);
		else
			(g.r0, g.r1) = gridspan(ks.rowstart, ks.rowend, names, len tr, nil, 0);
		(a0, a1) := glines(g, down);
		if(a1 > len tr)
			tr = growtracks(tr, a1, auto, avail);
		gi = g :: gi;
	}
	n := len tr;
	items := array[len gi] of ref Gi;
	for(i = len items - 1; i >= 0; i--) {
		items[i] = hd gi;
		gi = tl gi;
	}
	spans := array[len items] of int;
	for(i = 0; i < len items; i++) {
		g := items[i];
		ks := g.box.st;
		(a0, a1) := glines(g, down);
		if(down)
			spans[i] = spanof(a0, a1, ks.colstart, ks.colend);
		else
			spans[i] = spanof(a0, a1, ks.rowstart, ks.rowend);
		if(spans[i] > n)
			spans[i] = n;
	}

	# track sizing: an item not yet placed may land in any lane, so it
	# contributes as if placed at every start it could have (Grid 3 §5)
	sz: list of ref Gi;
	for(i = 0; i < len items; i++) {
		g := items[i];
		g.box.subcw = nil;
		g.box.subrh = nil;
		(a0, nil) := glines(g, down);
		if(a0 >= 0) {
			if(issubgrid(g.box, down)) {
				if(g.box.ml == 0 && g.box.mr == 0)
					edges(g.box, cw);
				for(sl := subitems(g.box, g, down, tgap); sl != nil; sl = tl sl)
					sz = hd sl :: sz;
			} else
				sz = g :: sz;
			continue;
		}
		for(t := 0; t + spans[i] <= n; t++) {
			v := ref Gi(g.box, -1, -1, -1, -1, 0, 0);
			setlines(v, down, t, t + spans[i]);
			if(issubgrid(g.box, down)) {
				for(sl := subitems(g.box, v, down, tgap); sl != nil; sl = tl sl)
					sz = hd sl :: sz;
			} else
				sz = v :: sz;
		}
	}
	sizing := array[len sz] of ref Gi;
	for(i = len sizing - 1; i >= 0; i--) {
		sizing[i] = hd sz;
		sz = tl sz;
	}
	if(down) {
		for(i = 0; i < len items; i++)
			edges(items[i].box, cw);
	} else {
		# stacking along the inline axis: the items' own widths, and
		# their heights at those, size the rows
		for(i = 0; i < len items; i++) {
			k := items[i].box;
			edges(k, cw);
			k.w = lanesw(k, cw);
			layblock(l, k, cw, ch, nil, 0, 0);
		}
	}
	sizetracks(tr, sizing, down, avail, tgap, b);
	tsum := tgap * nz(n - 1);
	for(i = 0; i < n; i++)
		tsum += ir(tr[i].base);
	tsum0 := tsum;	# the container's size across, which percentage rows do not change
	if(!down && ch < 0 && tpct) {
		# percentage rows in a container whose height they decide:
		# auto for that height, then resolved against it (Grid 2 §7.2.1)
		(again, nil) := tracks(tmpl, tsum, tgap);
		again = growtracks(again, n, auto, tsum);
		sizetracks(again, sizing, 0, tsum, tgap, b);
		tr = again;
	}
	# tracks in their physical order
	ptr := tr;
	if(trackrev) {
		ptr = array[n] of ref Track;
		for(i = 0; i < n; i++)
			ptr[i] = tr[n - 1 - i];
	}
	tavail := avail;
	if(tavail < 0)
		tavail = tsum0;
	talign := st.justifycontent;
	if(!down)
		talign = st.aligncontent;
	pos := trackpos(ptr, tgap, tavail, flowal(talign, trackrev));

	# the stacking axis: each item's size along it
	o := array[len items] of int;
	awat := array[len items] of {* => -1};	# the lane width an item was laid out at
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		ks := k.st;
		if(down) {
			# its width is settled once its lane is: lay it out at
			# the narrowest area it might get, for its height
			(a0, a1) := glines(g, down);
			aw := 0;
			if(a0 >= 0) {
				(p0, p1) := phys(a0, a1, n, trackrev);
				aw = areaw(ptr, pos, p0, p1, tgap);
			} else {
				aw = -1;
				for(t := 0; t + spans[i] <= n; t++) {
					(p0, p1) := phys(t, t + spans[i], n, trackrev);
					w := areaw(ptr, pos, p0, p1, tgap);
					if(aw < 0 || w < aw)
						aw = w;
				}
			}
			edges(k, aw);
			if(a0 >= 0)
				lanessub(k, tr, names, a0, a1, tgap, down);
			k.w = gridw(k, aw, b);
			layblock(l, k, aw, -1, nil, 0, 0);
			o[i] = k.h + k.mt + k.mb;
			awat[i] = aw;
		} else
			o[i] = k.w + k.ml + k.mr;
	}

	# placement: into the shortest lane, or the first within the tolerance
	# at or after the cursor (Grid 3 §4)
	tol := lanestol(b, avail);
	dense := st.lanespack;
	ls := newlanes(n, sgap, tol, dense);
	ext := array[len items] of {* => -1};	# where an item's alignment container ends, if room follows it
	y := array[len items] of int;
	for(i = 0; i < len items; i++) {
		g := items[i];
		(a0, a1) := glines(g, down);
		span := spans[i];
		if(a0 < 0) {
			a0 = ls.choose(span, o[i]);
			a1 = a0 + span;
			setlines(g, down, a0, a1);
		}
		if(down) {
			# its lane is settled: its width, and so its height, may
			# differ from the narrowest it was measured at
			(p0, p1) := phys(a0, a1, n, trackrev);
			aw := areaw(ptr, pos, p0, p1, tgap);
			if(aw != awat[i] || issubgrid(g.box, 1) && g.box.subcw == nil) {
				k := g.box;
				edges(k, aw);
				lanessub(k, tr, names, a0, a1, tgap, down);
				k.w = gridw(k, aw, b);
				layblock(l, k, aw, -1, nil, 0, 0);
				o[i] = k.h + k.mt + k.mb;
				awat[i] = aw;
			}
		}
		y[i] = fitsat(a0, a1, o[i], ls.run, ls.gaps, dense);
		ls.take(i, a0, a1, y[i], o[i], ext);
	}
	last := ls.last;
	# lanes from an auto-fit repeat that nothing landed in collapse,
	# and the rest are sized and placed again
	nfit := 0;
	for(ti := 0; ti < n; ti++)
		if(tr[ti].fit == 1)
			nfit++;
	if(nfit > 0) {
		collapsefit(tr, items, down);
		sizetracks(tr, sizing, down, avail, tgap, b);
		tsum = tgap * ngaps(tr);
		for(ti = 0; ti < n; ti++)
			tsum += ir(tr[ti].base);
		tavail = avail;
		if(tavail < 0)
			tavail = tsum;
		pos = trackpos(ptr, tgap, tavail, flowal(talign, trackrev));
		if(down)
			for(i = 0; i < len items; i++) {
				g := items[i];
				k := g.box;
				(a0, a1) := glines(g, down);
				(p0, p1) := phys(a0, a1, n, trackrev);
				aw := areaw(ptr, pos, p0, p1, tgap);
				if(aw != awat[i]) {
					edges(k, aw);
					k.w = gridw(k, aw, b);
					layblock(l, k, aw, -1, nil, 0, 0);
					awat[i] = aw;
				}
			}
	}
	range := 0;
	for(i = 0; i < len items; i++)
		if(y[i] + o[i] > range)
			range = y[i] + o[i];

	# the stacking range in the container, aligned as a whole
	size := savail;
	if(size < 0)
		size = range;
	free := size - range;
	off := 0;
	if(free > 0) {
		al := st.aligncontent;
		if(!down)
			al = st.justifycontent;
		case flowal(al, fillrev) {
		Style->ALend or Style->ALright =>
			off = free;
		Style->ALcenter =>
			off = free/2;
		Style->ALnormal or Style->ALstretch =>
			if(fillrev)
				off = free;
		}
	}
	# the last item in a lane has the room to the container's end
	last0 := range + off;
	if(!fillrev)
		last0 = size - off;
	for(t := 0; t < n; t++)
		if(last[t] >= 0 && ext[last[t]] < 0)
			ext[last[t]] = last0;
	# an item with room after it (before a spanning item, or the last
	# in its lane) aligns within that room (Grid 3 §7.2) if asked to;
	# start and end name the container's physical edges, which
	# stacking in reverse swaps
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		ks := k.st;
		room := ext[i] - (y[i] + o[i]);
		if(room <= 0)
			continue;
		as := ks.alignself;
		if(as == Style->ALauto)
			as = st.alignitems;
		if(!down) {
			as = ks.justifyself;
			if(as == Style->ALauto)
				as = st.justifyitems;
		}
		if(as == Style->ALnormal)
			continue;
		as = flowal(as, fillrev);
		if(fillrev)
			case as {
			Style->ALstart or Style->ALleft =>	as = Style->ALend;
			Style->ALend or Style->ALright =>	as = Style->ALstart;
			}
		case as {
		Style->ALstretch =>
			if(k.kind == Kreplaced)
				break;
			if(down) {
				if(ks.height.kind == Style->Lauto && ks.mt.kind != Style->Lauto && ks.mb.kind != Style->Lauto) {
					(a0, a1) := glines(g, down);
					(p0, p1) := phys(a0, a1, n, trackrev);
					aw := areaw(ptr, pos, p0, p1, tgap);
					imposeh(l, k, clamph(k, k.h + room, -1), aw, k.h + room);
					o[i] = k.h + k.mt + k.mb;
				}
			} else if(ks.width.kind == Style->Lauto && ks.ml.kind != Style->Lauto && ks.mr.kind != Style->Lauto) {
				k.w = clampw(k, k.w + room, cw);
				layblock(l, k, cw, ch, nil, 0, 0);
				o[i] = k.w + k.ml + k.mr;
			}
		Style->ALend or Style->ALright =>
			y[i] += room;
		Style->ALcenter =>
			y[i] += room/2;
		}
	}

	# place each item: its lane, and its position along the stack
	for(i = 0; i < len items; i++) {
		g := items[i];
		k := g.box;
		ks := k.st;
		(a0, a1) := glines(g, down);
		(p0, p1) := phys(a0, a1, n, trackrev);
		p := off + y[i];
		if(fillrev)
			p = off + range - (y[i] + o[i]);
		aw := cw;
		ah := ch;
		if(down) {
			ax := pos[p0];
			aw = areaw(ptr, pos, p0, p1, tgap);
			js := ks.justifyself;
			if(js == Style->ALauto)
				js = st.justifyitems;
			js = flowal(js, trackrev);
			x := ax + k.ml + crossoff(js, aw, k.w + k.ml + k.mr);
			if(ks.ml.kind == Style->Lauto && ks.mr.kind == Style->Lauto)
				x = ax + (aw - k.w)/2;
			if(st.dirrtl) {
				# the lanes run from the right, as a grid's columns do
				# (grid-lanes-item-placement-004)
				x = cw - ax - aw + k.ml + (aw - k.w - k.ml - k.mr) - crossoff(js, aw, k.w + k.ml + k.mr);
				if(js == Style->ALleft || js == Style->ALright)
					x = cw - ax - aw + k.ml + crossoff(js, aw, k.w + k.ml + k.mr);
				if(ks.ml.kind == Style->Lauto && ks.mr.kind == Style->Lauto)
					x = cw - ax - aw + (aw - k.w)/2;
			}
			k.x = b.bl + b.pl + x;
			k.y = b.bt + b.pt + p + k.mt;
			ah = o[i];
		} else {
			ay := pos[p0];
			ah = areaw(ptr, pos, p0, p1, tgap);
			as := ks.alignself;
			if(as == Style->ALauto)
				as = st.alignitems;
			as = flowal(as, trackrev);
			lanessub(k, tr, names, a0, a1, tgap, down);
			if(issubgrid(k, 0))
				imposeh(l, k, ah - k.mt - k.mb, k.w, ah);
			else if((as == Style->ALnormal || as == Style->ALstretch) && ks.height.kind == Style->Lauto &&
			   ks.mt.kind != Style->Lauto && ks.mb.kind != Style->Lauto && k.kind != Kreplaced)
				imposeh(l, k, clamph(k, ah - k.mt - k.mb, ah), k.w, ah);
			yy := ay + k.mt + crossoff(as, ah, k.h + k.mt + k.mb);
			if(ks.mt.kind == Style->Lauto && ks.mb.kind == Style->Lauto)
				yy = ay + (ah - k.h)/2;
			if(st.dirrtl)
				p = size - p - o[i];
			k.x = b.bl + b.pl + p + k.ml;
			k.y = b.bt + b.pt + yy;
			aw = o[i];
		}
		relative(k, aw, ah);
	}
	h := sh;
	if(h < 0) {
		h = range;
		if(!down)
			h = tsum0;
		h += vextra(b);
	}
	b.h = clamph(b, h, cbh);
	none := array[0] of ref Track;
	if(down)
		gridabs(l, b, ptr, pos, tgap, names, n, none, nil, 0, nil, 0, nil);
	else
		gridabs(l, b, none, nil, 0, nil, 0, ptr, pos, tgap, names, n, nil);
}

# flow-start and flow-end name the ends of the flow in an axis: the
# physical start and end, unless that axis runs in reverse
flowal(a, rev: int): int
{
	case a {
	Style->ALflowstart =>
		if(rev)
			return Style->ALend;
		return Style->ALstart;
	Style->ALflowend =>
		if(rev)
			return Style->ALstart;
		return Style->ALend;
	}
	return a;
}

# the tie threshold: positions within it of the shortest count as
# equally good; normal is 1em, a percentage is of the grid axis
lanestol(b: ref Box, avail: int): int
{
	st := b.st;
	case st.tolerance.kind {
	Style->Lnormal =>	return ir(st.fontsize);
	Style->Lnone =>		return 16r3fffffff;
	}
	return res(st.tolerance, nz(avail));
}

# The lanes as items are placed in them: where each lane's next item
# starts, the room spanning items skipped (for dense packing), and the
# auto-placement cursor.
Lanes: adt {
	n, sgap, tol, dense:	int;
	run:	array of int;		# where the next item in each lane starts
	last:	array of int;		# the last item placed in each lane
	gaps:	array of list of ref Gap;
	cursor:	int;
	choose:	fn(s: self ref Lanes, span, o: int): int;
	take:	fn(s: self ref Lanes, i, a0, a1, y, o: int, ext: array of int);
};

newlanes(n, sgap, tol, dense: int): ref Lanes
{
	return ref Lanes(n, sgap, tol, dense, array[n] of {* => 0}, array[n] of {* => -1}, array[n] of list of ref Gap, 0);
}

# the shortest lanes for an item of that span and size, or the first
# within the tolerance at or after the cursor (Grid 3 §4), which only
# an item placed this way moves
Lanes.choose(s: self ref Lanes, span, o: int): int
{
	n := s.n;
	cand := array[n] of {* => -1};
	miny := -1;
	for(t := 0; t + span <= n; t++) {
		cand[t] = fitsat(t, t + span, o, s.run, s.gaps, s.dense);
		if(miny < 0 || cand[t] < miny)
			miny = cand[t];
	}
	best := -1;
	if(!s.dense)	# packing densely takes the first position, as a grid does
		for(t = s.cursor; t + span <= n && best < 0; t++)
			if(cand[t] >= 0 && cand[t] <= miny + s.tol)
				best = t;
	for(t = 0; t + span <= n && best < 0; t++)
		if(cand[t] >= 0 && cand[t] <= miny + s.tol)
			best = t;
	if(best < 0)
		best = 0;
	s.cursor = best + span;
	return best;
}

# item i takes lanes a0..a1-1 from y for o: what it skips stays as a
# gap, and a lane's running position never moves back (a negative
# margin ends an item above where it began)
Lanes.take(s: self ref Lanes, i, a0, a1, y, o: int, ext: array of int)
{
	sgap := s.sgap;
	end := y + o;
	for(t := a0; t < a1; t++) {
		if(y >= s.run[t]) {
			if(y - sgap > s.run[t]) {
				s.gaps[t] = ref Gap(s.run[t], y - sgap, s.last[t]) :: s.gaps[t];
				if(s.last[t] >= 0)
					ext[s.last[t]] = minext(ext[s.last[t]], y - sgap);
			}
			if(end + sgap > s.run[t])
				s.run[t] = end + sgap;
			s.last[t] = i;
			continue;
		}
		# in a gap: what is left of it stays one
		left: list of ref Gap;
		for(gl := s.gaps[t]; gl != nil; gl = tl gl) {
			gp := hd gl;
			if(gp.a <= y && end <= gp.e) {
				if(y - sgap > gp.a)
					left = ref Gap(gp.a, y - sgap, gp.prev) :: left;
				if(gp.prev >= 0)
					ext[gp.prev] = minext(ext[gp.prev], y - sgap);
				if(end + sgap < gp.e)
					left = ref Gap(end + sgap, gp.e, i) :: left;
				ext[i] = minext(ext[i], gp.e);
			} else
				left = gp :: left;
		}
		s.gaps[t] = left;
	}
}

# a subgrid item of grid lanes gets the lanes it spans as its tracks
# (in their logical order) before it is laid out
lanessub(k: ref Box, tr: array of ref Track, names: array of list of string, a0, a1, gap, down: int)
{
	if(a0 < 0)
		return;
	if(down && issubgrid(k, 1)) {
		k.subcw = subtracks(tracksizes(tr, a0, a1), k.ml + k.bl + k.pl, k.mr + k.br + k.pr);
		k.subcnames = mergenames(names, a0, a1, subnames(k.st.gridcols));
		k.subcgap = gap;
	} else if(!down && issubgrid(k, 0)) {
		k.subrh = subtracks(tracksizes(tr, a0, a1), k.mt + k.bt + k.pt, k.mb + k.bb + k.pb);
		k.subrnames = mergenames(names, a0, a1, subnames(k.st.gridrows));
		k.subrgap = gap;
	}
}

# lines a0..a1 in the tracks' physical order
phys(a0, a1, n, rev: int): (int, int)
{
	if(rev)
		return (n - a1, n - a0);
	return (a0, a1);
}

minext(e, v: int): int
{
	if(e < 0 || v < e)
		return v;
	return e;
}

# the nearest position where an item of size o fits across lanes
# a0..a1-1: beyond everything in them, or, packing densely, in a gap
# they all have room in
fitsat(a0, a1, o: int, run: array of int, gaps: array of list of ref Gap, dense: int): int
{
	best := -1;
	for(t := a0; t < a1; t++) {
		if(lanesfit(run[t], a0, a1, o, run, gaps, dense) && (best < 0 || run[t] < best))
			best = run[t];
		if(dense)
			for(gl := gaps[t]; gl != nil; gl = tl gl) {
				gp := hd gl;
				if(gp.a < best || best < 0)
					if(lanesfit(gp.a, a0, a1, o, run, gaps, dense))
						best = gp.a;
			}
	}
	return best;
}

lanesfit(y, a0, a1, o: int, run: array of int, gaps: array of list of ref Gap, dense: int): int
{
	for(t := a0; t < a1; t++) {
		if(y >= run[t])
			continue;
		ok := 0;
		if(dense)
			for(gl := gaps[t]; gl != nil && !ok; gl = tl gl) {
				gp := hd gl;
				if(gp.a <= y && y + o <= gp.e)
					ok = 1;
			}
		if(!ok)
			return 0;
	}
	return 1;
}

# the inline size a grid lanes container needs: lanes running down add
# up its columns, each as wide as anything that might land in it; lanes
# running across stack the items along the inline axis
# an item's contribution to the columns c0..c1-1 it spans: less the
# fixed ones, spread over the others
spreadspan(cols: array of ref Track, cmn, cmx: array of int, c0, c1, kmn, kmx, gap: int)
{
	taken := gap * (c1 - c0 - 1);
	nvar := 0;
	for(c := c0; c < c1; c++)
		if(cols[c].lo.kind == Tfixed && cols[c].hi.kind == Tfixed)
			taken += int cols[c].hi.v;
		else
			nvar++;
	if(nvar == 0)
		return;
	# shares that add up to the whole: the first get the odd pixels
	rmn := (kmn - taken) % nvar;
	rmx := (kmx - taken) % nvar;
	smn := (kmn - taken) / nvar;
	smx := (kmx - taken) / nvar;
	for(c = c0; c < c1; c++) {
		if(cols[c].lo.kind == Tfixed && cols[c].hi.kind == Tfixed)
			continue;
		m := smn;
		if(rmn > 0) {
			m++;
			rmn--;
		}
		x := smx;
		if(rmx > 0) {
			x++;
			rmx--;
		}
		if(m > cmn[c])
			cmn[c] = m;
		if(x > cmx[c])
			cmx[c] = x;
	}
}

lanesintrinsic(b: ref Box): (int, int)
{
	st := b.st;
	down := lanesdown(b);
	gap := 0;
	if(st.colgap.kind != Style->Lnormal)
		gap = res(st.colgap, 0);
	if(!down) {
		# lanes running across: the stacking range when the items are
		# placed in the rows at their min-content widths, and again at
		# their max-content widths
		rgap := 0;
		if(st.rowgap.kind != Style->Lnormal)
			rgap = res(st.rowgap, 0);
		(rows, names) := tracks(st.gridrows, 0, rgap);
		if(len rows == 0)
			rows = growtracks(rows, 1, st.autorows, 0);
		nk := 0;
		for(i := 0; i < len b.kids; i++)
			if(!isabs(b.kids[i]))
				nk++;
		kmn := array[nk] of int;
		kmx := array[nk] of int;
		ka0 := array[nk] of int;
		kspan := array[nk] of int;
		j := 0;
		for(i = 0; i < len b.kids; i++) {
			k := b.kids[i];
			if(isabs(k))
				continue;
			edges(k, 0);
			(kmn[j], kmx[j]) = contribution(k);
			(a0, a1) := gridspan(k.st.rowstart, k.st.rowend, names, len rows, nil, 0);
			if(a1 > len rows)
				rows = growtracks(rows, a1, st.autorows, 0);
			ka0[j] = a0;
			kspan[j] = spanof(a0, a1, k.st.rowstart, k.st.rowend);
			j++;
		}
		n := len rows;
		rng := array[2] of {* => 0};
		for(pass := 0; pass < 2; pass++) {
			ls := newlanes(n, gap, lanestol(b, 0), st.lanespack);
			ext := array[nk] of {* => -1};
			for(j = 0; j < nk; j++) {
				o := kmn[j];
				if(pass == 1)
					o = kmx[j];
				span := kspan[j];
				if(span > n)
					span = n;
				a0 := ka0[j];
				if(a0 < 0)
					a0 = ls.choose(span, o);
				a1 := a0 + span;
				if(a1 > n)
					a1 = n;
				y := fitsat(a0, a1, o, ls.run, ls.gaps, st.lanespack);
				ls.take(j, a0, a1, y, o, ext);
				if(y + o > rng[pass])
					rng[pass] = y + o;
			}
		}
		return (rng[0], rng[1]);
	}
	(cols, names) := tracks(st.gridcols, 0, gap);
	if(len cols == 0)
		cols = growtracks(cols, 1, st.autocols, 0);
	n := len cols;
	cmn := array[n] of {* => 0};
	cmx := array[n] of {* => 0};
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k))
			continue;
		edges(k, 0);
		(kmn, kmx) := contribution(k);
		(a0, a1) := gridspan(k.st.colstart, k.st.colend, names, n, nil, 1);
		span := spanof(a0, a1, k.st.colstart, k.st.colend);
		if(span > n)
			span = n;
		# wherever it may land: a spanning item's contribution, less
		# the fixed lanes it spans, is spread over the others
		for(t := 0; t + span <= n; t++)
			if(a0 < 0 || t == a0)
				spreadspan(cols, cmn, cmx, t, t + span, kmn, kmx, gap);
	}
	wmn := gap * (n - 1);
	wmx := wmn;
	for(i = 0; i < n; i++)
		if(cols[i].lo.kind == Tfixed && cols[i].hi.kind == Tfixed) {
			wmn += int cols[i].hi.v;
			wmx += int cols[i].hi.v;
		} else {
			wmn += cmn[i];
			wmx += cmx[i];
		}
	return (wmn, wmx);
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
		if(e.span && e.name != nil) {
			y := namedspan(names, a, e.name, n, 1, ntracks);
			if(y <= a)
				y = a + 1;
			return (a, y);
		}
		return (a, a + n);
	}
	if(b >= 0) {
		n := 1;
		if(s.span)
			n = clampspan(s.span);
		if(s.span && s.name != nil) {
			x := namedspan(names, b, s.name, n, -1, ntracks);
			if(x >= b) {
				x = b - 1;
				if(x < 0)
					return (0, 1);
			}
			return (x, b);
		}
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
			r[i] = ref Track(Tsz(Tauto, 0.0), Tsz(Tauto, 0.0), 0.0, 0.0, 0, 0);
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
	# content contributions: single-span items, then spanning ones by
	# span, each group's increases planned against the same bases and
	# the largest taken (§12.5.1)
	maxspan := 1;
	for(i = 0; i < len items; i++) {
		g := items[i];
		ns := g.c1 - g.c0;
		if(!cols)
			ns = g.r1 - g.r0;
		if(ns > maxspan)
			maxspan = ns;
	}
	if(maxspan > n)
		maxspan = n;
	inc := array[n] of real;
	for(pass := 1; pass <= maxspan; pass++) {
		for(q := 0; q < n; q++)
			inc[q] = 0.0;
		for(i = 0; i < len items; i++) {
			g := items[i];
			a0 := g.c0;
			a1 := g.c1;
			if(!cols) {
				a0 = g.r0;
				a1 = g.r1;
			}
			nspan := a1 - a0;
			if(nspan != pass && !(pass == maxspan && nspan > maxspan))
				continue;
			k := g.box;
			mn, mx: int;
			if(g.empty)
				mn = mx = 0;
			else if(cols)
				(mn, mx) = contribution(k);
			else {
				mn = k.h + k.mt + k.mb;
				mx = mn;
			}
			mn += g.extra;
			mx += g.extra;
			if(b.st.margintrim != 0 && !g.empty) {
				# margin-trim: the margins at the grid's edges are not part of the contribution (grid-inline)
				tr := 0;
				if(cols) {
					if(a0 == 0 && b.st.margintrim & 4) tr += k.ml;
					if(a1 == n && b.st.margintrim & 8) tr += k.mr;
				} else {
					if(a0 == 0 && b.st.margintrim & 1) tr += k.mt;
					if(a1 == n && b.st.margintrim & 2) tr += k.mb;
				}
				mn -= tr;
				mx -= tr;
			}
			if(nspan == 1 && a0 < n && t[a0].lo.kind == Tauto && (t[a0].hi.kind == Tfixed || t[a0].hi.kind == Tpct) &&
			   t[a0].limit >= 0.0 && real mn > t[a0].limit && autosized(k, cols) && seethrough(k.st.overflowx) && !g.empty)
				mn = int t[a0].limit;	# an automatic minimum is clamped by a definite max track size (§6.6)
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
			if(pass >= 2 && hasfr)
				continue;	# spanning fr tracks: left to the fr step
			need := real mn - have;
			if(need > 0.0 && nintr > 0) {
				per := need / real nintr;
				for(j = a0; j < a1 && j < n; j++)
					if(intrinsiclo(t[j])) {
						if(pass == 1)
							t[j].base += per;
						else if(per > inc[j])
							inc[j] = per;
					}
			}
			# growth limits for auto and max-content tracks
			if(nspan == 1 && a0 < n) {
				tr := t[a0];
				if(tr.hi.kind == Tauto || tr.hi.kind == Tmax || tr.hi.kind == Tfit) {
					lim := real mx;
					if(tr.hi.kind == Tfit && lim > tr.hi.v)
						lim = tr.hi.v;	# fit-content: no wider than its argument
					if(tr.limit < lim)
						tr.limit = lim;
				}
				if(tr.hi.kind == Tmin && tr.limit < real mn)
					tr.limit = real mn;
			}
		}
		for(q = 0; q < n; q++)
			t[q].base += inc[q];
	}
	for(i = 0; i < n; i++)
		if(t[i].limit >= 0.0 && t[i].limit < t[i].base)
			t[i].limit = t[i].base;
	# free space
	used := real (gap * ngaps(t));
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
	# else stretch auto tracks, when the content is to be stretched (§12.8)
	al := b.st.justifycontent;
	if(!cols)
		al = b.st.aligncontent;
	if(free > 0.0 && (al == Style->ALnormal || al == Style->ALstretch)) {
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

# whether an item's size in an axis is automatic (auto, or a
# percentage of a track being sized), so its minimum is content-based
autosized(k: ref Box, cols: int): int
{
	st := k.st;
	sz := st.width;
	mn := st.minwidth;
	if(!cols) {
		sz = st.height;
		mn = st.minheight;
	}
	return (sz.kind == Style->Lauto || sz.kind == Style->Lpx && sz.pct != 0.0) && mn.kind == Style->Lauto;
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
	used := gap * ngaps(t);
	for(i := 0; i < n; i++)
		used += ir(t[i].base);
	free := avail - used;
	start := 0;
	extra := 0;
	nv := 0;	# the tracks that are there: collapsed ones take no share (grid-content-distribution-with-collapsed-tracks-001)
	for(i = 0; i < n; i++)
		if(t[i].fit != 2)
			nv++;
	if(free > 0)
		case align {
		Style->ALend or Style->ALright or Style->ALflowend =>
			start = free;
		Style->ALcenter =>
			start = free/2;
		Style->ALbetween =>
			if(nv > 1)
				extra = free / (nv - 1);
		Style->ALaround =>
			extra = free / nz1(nv);
			start = extra/2;
		Style->ALevenly =>
			extra = free / (nv + 1);
			start = extra;
		}
	# accumulate in reals and round each edge, so fractional tracks
	# tile without gaps
	p := real start;
	any := 0;
	for(i = 0; i < n; i++) {
		pos[i] = ir(p);
		t[i].endp = pos[i];
		if(t[i].fit == 2)
			continue;	# collapsed: nothing, and no gutter
		t[i].endp = ir(p + t[i].base);	# the track's own end: distributed space is not the track's (grid-content-distribution-with-collapsed-tracks-002)
		p += t[i].base + real (gap + extra);
		any = 1;
	}
	pos[n] = ir(p);
	if(any)
		pos[n] -= gap + extra;
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
	if(t[i].fit == 2)
		return pos[i];
	if(t[i].endp > pos[i])
		return t[i].endp;
	if(i + 1 < len t)
		return pos[i+1] - gap;
	return pos[i] + ir(t[i].base);
}

gridw(k: ref Box, aw: int, b: ref Box): int
{
	ks := k.st;
	if(issubgrid(k, 1))	# a subgrid's width is its tracks' (§9.3)
		return aw - k.ml - k.mr;
	w := specw(k, ks.width, aw);
	if(w >= 0)
		return clampw(k, w, aw);
	js := ks.justifyself;
	if(js == Style->ALauto)
		js = b.st.justifyitems;
	if((js == Style->ALstretch || js == Style->ALnormal && ks.aspect == 0.0) && ks.ml.kind != Style->Lauto && ks.mr.kind != Style->Lauto && k.kind != Kreplaced)
		return clampw(k, aw - k.ml - k.mr, aw);	# normal is start for a box with a ratio (Grid 2 §6.2)
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
	base:	int;		# a baseline-aligned cell's baseline from its top edge, once laid out; -1 for others
};

Tgrid: adt {
	rows:	array of ref Box;	# row boxes, in display order
	groups:	array of ref Box;	# each row's group (nil if directly in the table)
	cells:	list of ref Tcell;
	ncols:	int;
	captions:	list of ref Box;
	colw:	array of int;	# widths from <col>/<colgroup>, 0 if none
	colpct:	array of real;	# percentage widths from them, -1 if none
	colhid:	array of int;	# the column is visibility: collapse
	tb:	ref Tb;		# the collapsed borders, if border-collapse: collapse
};

# (a text box carries its parent's style, display included: it is never a table part)
isrowgroup(k: ref Box): int
{
	if(k.kind == Ktext)
		return 0;
	case k.st.display {
	Style->Dtablerowgroup or Style->Dtableheadergroup or Style->Dtablefootergroup =>
		return 1;
	}
	return 0;
}

iscolumn(k: ref Box): int
{
	return k.kind != Ktext && (k.st.display == Style->Dtablecolumn || k.st.display == Style->Dtablecolumngroup);
}

# The table's grid: rows in header, body, footer order; cells with their
# slots, rowspans reserving slots below.
tgrid(d: ref Doc, b: ref Box): ref Tgrid
{
	head, body, foot: list of (ref Box, ref Box);	# (row, group), reversed
	hadhead := 0;
	hadfoot := 0;
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
			if(k.st.visibility == Style->Vcollapse)
				continue;	# a collapsed row group takes no room (CSS 2.2 §17.5.5)
			rl: list of (ref Box, ref Box);
			for(j := 0; j < len k.kids; j++)
				if(k.kids[j].kind == Krow && k.kids[j].st.visibility != Style->Vcollapse)
					rl = (k.kids[j], k) :: rl;
			# the first header group goes first and the first footer
			# group last; any others stay where they are (Tables 3 §2.1)
			d := k.st.display;
			if(d == Style->Dtableheadergroup && head == nil && !hadhead) {
				hadhead = 1;
				for(rr := rev2(rl); rr != nil; rr = tl rr)
					head = hd rr :: head;
			} else if(d == Style->Dtablefootergroup && foot == nil && !hadfoot) {
				hadfoot = 1;
				for(rr := rev2(rl); rr != nil; rr = tl rr)
					foot = hd rr :: foot;
			} else
				for(rr := rev2(rl); rr != nil; rr = tl rr)
					body = hd rr :: body;
		} else if(k.kind == Krow && k.st.visibility != Style->Vcollapse)
			body = (k, nil) :: body;
	}
	all := head;	# (each list is reversed; the final rev2 puts them all in order)
	for(bl := rev2(body); bl != nil; bl = tl bl)
		all = hd bl :: all;
	for(fl := rev2(foot); fl != nil; fl = tl fl)
		all = hd fl :: all;
	all = rev2(all);
	t := ref Tgrid(array[len all] of ref Box, array[len all] of ref Box, nil, 0, rev(caps), nil, nil, nil, nil);
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
			if(cell.kind != Kcell && (cell.inl || isoof(cell)))
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
			t.cells = ref Tcell(cell, row, r, c, rs, cs, -1) :: t.cells;
			c += cs;
			if(c > t.ncols)
				t.ncols = c;
		}
	}
	# column widths from <col> and <colgroup>; a column element with
	# a definite width is a column even with no cells in it, one
	# without is nothing past the cells (col-definite-size-001)
	raw := rev(cols);
	cols = expandcols(raw);
	nc := 0;
	last := 0;
	for(ncl := cols; ncl != nil; ncl = tl ncl) {
		nc += colspan(hd ncl);
		if(colwidth(hd ncl) > 0)
			last = nc;
	}
	if(last > t.ncols)
		t.ncols = last;
	t.colw = array[t.ncols] of {* => 0};
	t.colpct = array[t.ncols] of {* => -1.0};
	t.colhid = array[t.ncols] of {* => 0};
	c := 0;
	for(cl := cols; cl != nil; cl = tl cl) {
		k := hd cl;
		n := 1;
		if(k.node != 0 && d != nil)
			n = spanattr(d.attr(k.node, "span"), 1000);
		w := colwidth(k);
		pc := -1.0;
		if(w < 0) {
			w = 0;
			if(k.st.width.kind == Style->Lpx && k.st.width.px == 0.0)
				pc = k.st.width.pct;
		}
		hid := k.st.visibility == Style->Vcollapse;
		for(m := 0; m < n && c < t.ncols; m++) {
			t.colpct[c] = pc;
			t.colhid[c] = hid;
			t.colw[c++] = w;
		}
	}
	if(b.st.collapse)
		t.tb = collapsed(t, b, raw);
	return t;
}

# a column element's definite width in px: its width or min-width,
# whichever is more (max-width does not apply to columns); -1 for none
colwidth(k: ref Box): int
{
	st := k.st;
	w := -1;
	if(st.width.kind == Style->Lpx && st.width.pct == 0.0)
		w = ir(st.width.px);
	if(st.maxwidth.kind == Style->Lpx && st.maxwidth.pct == 0.0 && w >= 0 && ir(st.maxwidth.px) < w)
		w = ir(st.maxwidth.px);
	if(st.minwidth.kind == Style->Lpx && st.minwidth.pct == 0.0 && ir(st.minwidth.px) > w)
		w = ir(st.minwidth.px);
	return w;
}

# the column boxes in order, a group with columns in it standing for them
expandcols(cols: list of ref Box): list of ref Box
{
	r: list of ref Box;
	for(; cols != nil; cols = tl cols) {
		k := hd cols;
		any := 0;
		if(k.st.display == Style->Dtablecolumngroup)
			for(j := 0; j < len k.kids; j++)
				if(iscolumn(k.kids[j])) {
					r = k.kids[j] :: r;
					any = 1;
				}
		if(!any)
			r = k :: r;
	}
	return rev(r);
}

# ---- the collapsing border model (CSS 2.2 §17.6.2) ----

# The border at each segment of the grid lines is the one that wins
# among the cells, rows, row groups, columns, column groups and the
# table meeting there: hidden beats all, else the widest, else the
# style (double, solid, dashed, dotted, ridge, outset, groove, inset),
# else the nearer origin (cell first), else the leftmost or topmost.
collapsed(t: ref Tgrid, b: ref Box, cols: list of ref Box): ref Tb
{
	n := t.ncols;
	nr := len t.rows;
	tb := ref Tb(n, nr, nil, nil, array[nr*(n+1)] of ref Bd, array[(nr+1)*n] of ref Bd, 0);
	for(i := 0; i < len tb.v; i++)
		tb.v[i] = ref Bd(0, Style->Bnone, 0, 9);
	for(i = 0; i < len tb.h; i++)
		tb.h[i] = ref Bd(0, Style->Bnone, 0, 9);
	# cells first, so that on a full tie the leftmost and topmost wins
	for(cl := t.cells; cl != nil; cl = tl cl) {
		c := hd cl;
		ks := c.box.st;
		for(r := c.r; r < c.r + c.rs && r < nr; r++) {
			fight(tb.v[r*(n+1) + c.c], ks.bl, ks.bsl, bcolor(ks, ks.bcl), 0, 1);
			fight(tb.v[r*(n+1) + c.c + c.cs], ks.br, ks.bsr, bcolor(ks, ks.bcr), 0, 0);
		}
		for(cc := c.c; cc < c.c + c.cs && cc < n; cc++) {
			fight(tb.h[c.r*n + cc], ks.bt, ks.bst, bcolor(ks, ks.bct), 0, 1);
			fight(tb.h[(c.r + c.rs)*n + cc], ks.bb, ks.bsb, bcolor(ks, ks.bcb), 0, 0);
		}
	}
	for(r := 0; r < nr; r++) {
		rs := t.rows[r].st;
		for(c := 0; c < n; c++) {
			fight(tb.h[r*n + c], rs.bt, rs.bst, bcolor(rs, rs.bct), 1, 1);
			fight(tb.h[(r+1)*n + c], rs.bb, rs.bsb, bcolor(rs, rs.bcb), 1, 0);
		}
		fight(tb.v[r*(n+1)], rs.bl, rs.bsl, bcolor(rs, rs.bcl), 1, 1);
		fight(tb.v[r*(n+1) + n], rs.br, rs.bsr, bcolor(rs, rs.bcr), 1, 0);
		g := t.groups[r];
		if(g == nil)
			continue;
		gs := g.st;
		if(r == 0 || t.groups[r-1] != g)
			for(c = 0; c < n; c++)
				fight(tb.h[r*n + c], gs.bt, gs.bst, bcolor(gs, gs.bct), 2, 1);
		if(r == nr - 1 || t.groups[r+1] != g)
			for(c = 0; c < n; c++)
				fight(tb.h[(r+1)*n + c], gs.bb, gs.bsb, bcolor(gs, gs.bcb), 2, 0);
		fight(tb.v[r*(n+1)], gs.bl, gs.bsl, bcolor(gs, gs.bcl), 2, 1);
		fight(tb.v[r*(n+1) + n], gs.br, gs.bsr, bcolor(gs, gs.bcr), 2, 0);
	}
	# columns and column groups: left and right on their lines, top
	# and bottom on the outer ones; a group's columns within it
	c := 0;
	for(; cols != nil && c < n; cols = tl cols) {
		k := hd cols;
		span := colspan(k);
		if(c + span > n)
			span = n - c;
		if(k.st.display == Style->Dtablecolumngroup) {
			colfight(tb, k, c, span, 4);
			cc := c;
			for(j := 0; j < len k.kids && cc < c + span; j++) {
				col := k.kids[j];
				if(!iscolumn(col))
					continue;
				sp := colspan(col);
				if(cc + sp > c + span)
					sp = c + span - cc;
				colfight(tb, col, cc, sp, 3);
				cc += sp;
			}
		} else
			colfight(tb, k, c, span, 3);
		c += span;
	}
	st := b.st;
	for(r = 0; r < nr; r++) {
		fight(tb.v[r*(n+1)], st.bl, st.bsl, bcolor(st, st.bcl), 5, 0);
		fight(tb.v[r*(n+1) + n], st.br, st.bsr, bcolor(st, st.bcr), 5, 1);
	}
	for(c = 0; c < n; c++) {
		fight(tb.h[c], st.bt, st.bst, bcolor(st, st.bct), 5, 0);
		fight(tb.h[nr*n + c], st.bb, st.bsb, bcolor(st, st.bcb), 5, 1);
	}
	# a cell spanning columns or rows has no grid lines inside it: the
	# borders of the columns and rows it crosses stop at it
	# (border-collapse-spanning-cells-001)
	for(sl := t.cells; sl != nil; sl = tl sl) {
		sc := hd sl;
		for(sr := sc.r; sr < sc.r + sc.rs && sr < nr; sr++)
			for(scc := sc.c + 1; scc < sc.c + sc.cs && scc < n; scc++)
				tb.v[sr*(n+1) + scc] = ref Bd(0, Style->Bnone, 0, 9);
		for(sr = sc.r + 1; sr < sc.r + sc.rs && sr < nr; sr++)
			for(scc = sc.c; scc < sc.c + sc.cs && scc < n; scc++)
				tb.h[sr*n + scc] = ref Bd(0, Style->Bnone, 0, 9);
	}
	return tb;
}

# side: 0 for a candidate on the left of or above the line (it wins a
# full tie, CSS 2.2 §17.6.2.1), 1 for one on the right or below
# a border colour as painted: currentcolor is the owner's text colour
bcolor(st: ref St, c: int): int
{
	if(c == Style->Ccurrent)
		return st.color;
	return c;	# transparent (0) stays so
}

colfight(tb: ref Tb, k: ref Box, c, span, origin: int)
{
	n := tb.ncols;
	nr := tb.nrows;
	cs := k.st;
	for(r := 0; r < nr; r++) {
		fight(tb.v[r*(n+1) + c], cs.bl, cs.bsl, bcolor(cs, cs.bcl), origin, 1);
		fight(tb.v[r*(n+1) + c + span], cs.br, cs.bsr, bcolor(cs, cs.bcr), origin, 0);
	}
	for(cc := c; cc < c + span; cc++) {
		fight(tb.h[cc], cs.bt, cs.bst, bcolor(cs, cs.bct), origin, 1);
		fight(tb.h[nr*n + cc], cs.bb, cs.bsb, bcolor(cs, cs.bcb), origin, 0);
	}
}

fight(e: ref Bd, w, sty, col, origin, side: int)
{
	origin = origin*2 + side;
	if(e.style == Style->Bhidden)
		return;
	if(sty == Style->Bhidden) {
		e.w = 0;
		e.style = sty;
		e.origin = origin;
		return;
	}
	if(sty == Style->Bnone || w <= 0)
		return;
	take := e.style == Style->Bnone || w > e.w;
	if(!take && w == e.w) {
		take = stylerank(sty) > stylerank(e.style) ||
			stylerank(sty) == stylerank(e.style) && origin < e.origin;
	}
	if(take) {
		e.w = w;
		e.style = sty;
		e.color = col;
		e.origin = origin;
	}
}

stylerank(sty: int): int
{
	case sty {
	Style->Bdouble =>	return 8;
	Style->Bsolid =>	return 7;
	Style->Bdashed =>	return 6;
	Style->Bdotted =>	return 5;
	Style->Bridge =>	return 4;
	Style->Boutset =>	return 3;
	Style->Bgroove =>	return 2;
	Style->Binset =>	return 1;
	}
	return 0;
}

# a collapsed border straddles its grid line: this much lies before
# it (left or above) and the rest after
bhalf(w: int): int
{
	return w / 2;
}

# the widest border along a run of segments
widest(a: array of ref Bd, from, step, count: int): int
{
	w := 0;
	for(i := 0; i < count; i++)
		if(a[from + i*step].w > w)
			w = a[from + i*step].w;
	return w;
}

# a cell's borders in the collapsing model: its share of the borders
# on its four edges, the widest along each
cellhalves(t: ref Tgrid, c: ref Tcell)
{
	tb := t.tb;
	n := tb.ncols;
	nr := tb.nrows;
	k := c.box;
	rs := c.rs;
	if(c.r + rs > nr)
		rs = nr - c.r;
	cs := c.cs;
	if(c.c + cs > n)
		cs = n - c.c;
	wl := widest(tb.v, c.r*(n+1) + c.c, n+1, rs);
	wr := widest(tb.v, c.r*(n+1) + c.c + cs, n+1, rs);
	wt := widest(tb.h, c.r*n + c.c, 1, cs);
	wb := widest(tb.h, (c.r + rs)*n + c.c, 1, cs);
	k.bl = wl - bhalf(wl);
	k.br = bhalf(wr);
	k.bt = wt - bhalf(wt);
	k.bb = bhalf(wb);
}

# and the table's: the outer halves of the outer lines, no padding
tablehalves(t: ref Tgrid, b: ref Box)
{
	tb := t.tb;
	n := tb.ncols;
	nr := tb.nrows;
	b.bl = bhalf(widest(tb.v, 0, n+1, nr));
	w := widest(tb.v, n, n+1, nr);
	b.br = w - bhalf(w);
	b.bt = bhalf(widest(tb.h, 0, 1, n));
	w = widest(tb.h, nr*n, 1, n);
	b.bb = w - bhalf(w);
	b.pl = b.pr = b.pt = b.pb = 0;
}

# The column and column group boxes get the grid's extent of their
# spans, cell edge to cell edge, for their backgrounds (§17.5.1).
placecolumns(b: ref Box, cx, colw, rowy: array of int, sx, sy, rtl: int)
{
	n := len colw;
	nr := len rowy - 1;
	c := 0;
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(!iscolumn(k))
			continue;
		span := colspan(k);
		if(c + span > n)
			span = n - c;
		colbox(k, cx, colw, rowy, sx, sy, c, span, rtl);
		if(k.st.display == Style->Dtablecolumngroup) {
			cc := c;
			for(j := 0; j < len k.kids && cc < c + span; j++) {
				col := k.kids[j];
				if(!iscolumn(col))
					continue;
				sp := colspan(col);
				if(cc + sp > c + span)
					sp = c + span - cc;
				colbox(col, cx, colw, rowy, sx, sy, cc, sp, rtl);
				col.x -= k.x;	# in its group
				col.y -= k.y;
				cc += sp;
			}
		}
		c += span;
	}
}

# a column's span attribute; a group with columns in it spans theirs
colspan(k: ref Box): int
{
	if(k.st.display == Style->Dtablecolumngroup) {
		n := 0;
		for(j := 0; j < len k.kids; j++)
			if(iscolumn(k.kids[j]))
				n += colspan(k.kids[j]);
		if(n > 0)
			return n;
	}
	if(k.node != 0 && curdoc != nil)
		return spanattr(curdoc.attr(k.node, "span"), 1000);
	return 1;
}

colbox(k: ref Box, cx, colw, rowy: array of int, sx, sy, c, span, rtl: int)
{
	nr := len rowy - 1;
	k.w = k.h = 0;
	if(span <= 0 || nr <= 0)
		return;
	first := c;	# the leftmost of its columns
	if(rtl)
		first = c + span - 1;
	k.x = cx[first];
	k.y = rowy[0];
	k.w = sx * (span - 1);
	for(i := c; i < c + span; i++)
		k.w += colw[i];
	k.h = rowy[nr] - sy - k.y;
}

# the table box within a table's border box r: the captions above and
# below are outside it (CSS 2.2 §17.4)
tablerect(b: ref Box, r: Rect): Rect
{
	tb := b.tb;
	if(tb.nrows == 0 || tb.rows == nil)
		return r;
	(nil, sy) := tspacing(b);
	top := tb.rows[0] - sy - b.bt - b.pt;
	bot := tb.rows[tb.nrows] + b.bb + b.pb;
	if(top <= 0 && bot >= b.h)
		return r;
	return Rect((r.min.x, r.min.y + top), (r.max.x, r.min.y + bot));
}

# the physical column (from the left) and grid line of logical ones
pcol(tb: ref Tb, c: int): int
{
	if(tb.rtl)
		return tb.ncols - 1 - c;
	return c;
}

pline(tb: ref Tb, c: int): int
{
	if(tb.rtl)
		return tb.ncols - c;
	return c;
}

# Paint a table's collapsed borders, each segment centred on its grid
# line; the horizontal ones reach out over the corners.
paintcollapsed(dst: ref Image, b: ref Box, r: Rect)
{
	tb := b.tb;
	n := tb.ncols;
	nr := tb.nrows;
	for(rr := 0; rr < nr; rr++)
		for(c := 0; c <= n; c++) {
			e := tb.v[rr*(n+1) + c];
			if(e.w <= 0)
				continue;
			x := r.min.x + tb.cols[pline(tb, c)];
			side(dst, Rect((x - bhalf(e.w), r.min.y + tb.rows[rr]), (x - bhalf(e.w) + e.w, r.min.y + tb.rows[rr+1])),
				e.w, e.color, e.style, 1, c < n);
		}
	for(rr = 0; rr <= nr; rr++)
		for(c = 0; c < n; c++) {
			e := tb.h[rr*n + c];
			if(e.w <= 0)
				continue;
			y := r.min.y + tb.rows[rr];
			# out to the far edges of the vertical borders at its ends
			lw := 0;
			rw := 0;
			if(rr < nr) {
				lw = tb.v[rr*(n+1) + c].w;
				rw = tb.v[rr*(n+1) + c + 1].w;
			}
			if(rr > 0) {
				if(tb.v[(rr-1)*(n+1) + c].w > lw)
					lw = tb.v[(rr-1)*(n+1) + c].w;
				if(tb.v[(rr-1)*(n+1) + c + 1].w > rw)
					rw = tb.v[(rr-1)*(n+1) + c + 1].w;
			}
			if(tb.rtl)
				(lw, rw) = (rw, lw);	# the line at its right end is logical c, physically on the left
			x0 := r.min.x + tb.cols[pcol(tb, c)] - bhalf(lw);
			x1 := r.min.x + tb.cols[pcol(tb, c) + 1] + rw - bhalf(rw);
			side(dst, Rect((x0, y - bhalf(e.w)), (x1, y - bhalf(e.w) + e.w)), e.w, e.color, e.style, 0, rr < nr);
		}
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
# The columns' minimum and maximum widths, percentages (-1 for none)
# with the padding and borders of the cell that gave one (a cell's
# percentage is of its content box; a column's is of the column), and
# which have a specified width.
tcolumns(t: ref Tgrid, tw: int): (array of int, array of int, array of real, array of int, array of int)
{
	n := t.ncols;
	mn := array[n] of {* => 0};
	mx := array[n] of {* => 0};
	pct := array[n] of {* => -1.0};
	pex := array[n] of {* => 0};
	fixw := array[n] of {* => 0};	# has a specified width
	hascell := array[n] of {* => 0};
	for(hl := t.cells; hl != nil; hl = tl hl)
		for(hi := (hd hl).c; hi < (hd hl).c + (hd hl).cs && hi < n; hi++)
			hascell[hi] = 1;
	for(i := 0; i < n; i++) {
		if(t.colw[i] > 0) {
			mn[i] = mx[i] = t.colw[i];
			fixw[i] = 1;
		}
		if(t.colpct[i] >= 0.0 && hascell[i])
			pct[i] = t.colpct[i];	# a percentage column with no cells takes nothing
	}
	# single-column cells first, then spanning ones spread their excess
	for(pass := 1; pass <= 2; pass++)
		for(cl := t.cells; cl != nil; cl = tl cl) {
			c := hd cl;
			if((pass == 1) != (c.cs == 1))
				continue;
			k := c.box;
			edges(k, tw);
			if(t.tb != nil)
				cellhalves(t, c);
			(cmn, cmx) := contribution(k);
			ks := k.st;
			if(ks.width.kind == Style->Lpx && ks.width.pct != 0.0 && ks.width.px == 0.0) {
				if(c.cs == 1 && ks.width.pct > pct[c.c]) {
					pct[c.c] = ks.width.pct;
					pex[c.c] = 0;
					if(!ks.borderbox)
						pex[c.c] = hextra(k);
				}
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
	return (mn, mx, pct, pex, fixw);
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
	if(t.tb != nil)
		tablehalves(t, b);
	(mn, mx, nil, nil, nil) := tcolumns(t, 0);
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

# Absolutely positioned boxes among a table's parts (a positioned
# row group is a block, CSS 2.2 §9.7) await their containing block,
# with the table's content box start as their static position.
tableabs(l: ref L, t, b: ref Box)
{
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k))
			l.pending = ref Abs(k, cbof(l, k), t, t.bl + t.pl, t.bt + t.pt, nil, t.st.dirrtl, nil, icbof(k), 0) :: l.pending;
		else if(isrowgroup(k) || k.kind == Krow)
			tableabs(l, t, k);
	}
}

laytable(l: ref L, b: ref Box, cbw, cbh: int)
{
	st := b.st;
	tableabs(l, b, b);
	t := tgrid(curdoc, b);
	if(t.tb != nil)
		tablehalves(t, b);
	n := t.ncols;
	(sx, sy) := tspacing(b);
	cw := b.w - hextra(b);	# the width the table's grid gets
	(mn, mx, pct, pex, fixw) := tcolumns(t, cw);
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
	} else if(!st.tablefixed) {
		if(cw < summn)
			cw = summn;
	} else {
		# fixed layout: not the cells' contents, but the columns'
		# given widths plus the spacing, if that is more (§17.5.2.1)
		summf := sx * (n + 1);
		for(i = 0; i < n; i++)
			if(t.colw[i] > 0)
				summf += t.colw[i];
			else if(fixw[i])
				summf += mn[i];
		if(cw < summf)
			cw = summf;
	}
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
			else if(fixw[i])
				colw[i] = mn[i];	# a cell's width in the first row (§17.5.2.1)
			else if(pct[i] >= 0.0)
				colw[i] = ir(pct[i] * real avail / 100.0) + pex[i];
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
				w := ir(pct[i] * real avail / 100.0) + pex[i];
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
	# a collapsed column is removed, its width and spacing with it,
	# and the table shrinks by as much (§17.5.5)
	hidw := array[n] of {* => 0};
	for(i = 0; i < n; i++)
		if(t.colhid[i]) {
			cw -= colw[i] + sx;
			hidw[i] = colw[i];
			colw[i] = 0;
		}
	b.w = cw + hextra(b);
	colx := array[n + 1] of int;
	x := b.bl + b.pl + sx;
	for(i = 0; i < n; i++) {
		colx[i] = x;
		if(!t.colhid[i])
			x += colw[i] + sx;
	}
	colx[n] = x;
	# where each column is, right to left in a right-to-left table
	cx := colx;
	if(st.dirrtl) {
		cx = array[n] of int;
		start := b.bl + b.pl;
		for(i = 0; i < n; i++)
			cx[i] = start + cw - (colx[i] - start) - colw[i];
	}

	# captions above (or below); collapsed borders are drawn at the
	# grid's edge, so the captions lie outside them
	y := b.bt + b.pt;
	if(t.tb != nil)
		y = 0;
	for(cl := t.captions; cl != nil; cl = tl cl) {
		k := hd cl;
		if(k.st.captionbottom)
			continue;
		y = laycaption(l, k, b, cw, y);
	}
	gridtop := y;
	if(t.tb != nil)
		gridtop += b.bt + b.pt;
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
		w := colx[c.c + c.cs] - sx - colx[c.c];
		# a cell in a collapsed column is gone; one crossing it is
		# clipped to what is left of it (§17.5.5)
		nhid := 0;
		for(i = c.c; i < c.c + c.cs; i++)
			nhid += t.colhid[i];
		if(nhid > 0)
			k.clip = 1;
		edges(k, cw);
		fw := w;	# the width the content is laid out at: with the collapsed columns
		lead := 0;	# of which before the first column still showing
		if(nhid == c.cs) {
			w = fw = 0;
			k.bl = k.br = k.bt = k.bb = 0;
			k.pl = k.pr = k.pt = k.pb = 0;
		} else if(nhid > 0) {
			nlead := 0;
			for(i = c.c; i < c.c + c.cs; i++)
				if(t.colhid[i]) {
					fw += hidw[i] + sx;
					if(i == c.c + nlead) {
						nlead++;
						lead += hidw[i];	# the spacing goes from the table, not the content
					}
				}
		}
		if(t.tb != nil)
			cellhalves(t, c);
		k.w = fw;
		layblock(l, k, fw, -1, nil, 0, 0);
		if(fw != w) {
			# the content over the collapsed columns is cut away: what
			# is before the first visible column slides out to the left
			k.w = w;
			shiftx(k, -lead);
		}
		if(c.rs == 1 && k.h > rowh[c.r] && nhid < c.cs)
			rowh[c.r] = k.h;
		if(c.rs == 1 && k.st.height.kind == Style->Lpx && k.st.height.pct == 0.0)
			rowspec[c.r] = 1;
		if(c.rs == 1 && k.st.valign == Style->VAbaseline)
			c.base = cellbaseline(k);
	}
	# baseline-aligned cells of a row share a baseline, the lowest of
	# theirs; the others move down to it, and the row grows to hold
	# them (§17.5.3)
	rowbase := array[nr] of {* => -1};
	for(cl2 = t.cells; cl2 != nil; cl2 = tl cl2) {
		c := hd cl2;
		if(c.base >= 0 && c.base > rowbase[c.r])
			rowbase[c.r] = c.base;
	}
	for(cl2 = t.cells; cl2 != nil; cl2 = tl cl2) {
		c := hd cl2;
		if(c.base >= 0 && rowbase[c.r] - c.base + c.box.h > rowh[c.r])
			rowh[c.r] = rowbase[c.r] - c.base + c.box.h;
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
	# a specified table height, within its min and max, grows the rows
	sh := specheight(b, cbh);
	if(sh >= 0)
		sh = clamph(b, sh, cbh);
	if(sh >= 0) {
		gh := sy * (nr + 1);
		for(r = 0; r < nr; r++)
			gh += rowh[r];
		# the height is the table box's: captions are outside it (§17.4)
		extra := sh - vextra(b) - gh;
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
	b.tb = t.tb;
	if(b.tb == nil)
		b.tb = ref Tb(n, nr, nil, nil, nil, nil, 0);	# the grid lines
	b.tb.cols = colx;
	b.tb.rows = rowy;
	b.tb.rtl = st.dirrtl;
	placecolumns(b, cx, colw, rowy, sx, sy, st.dirrtl);
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
		Style->VAbaseline =>
			if(c.base >= 0)
				dy = rowbase[c.r] - c.base;
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
		k.x = cx[c.c] - rx;
		if(st.dirrtl)
			k.x = cx[c.c + c.cs - 1] - rx;
		k.y = rowy[c.r] - ry;
		relative(k, cw, -1);
	}
	# relatively positioned rows and row groups move once their cells
	# are placed within them (position-relative-table-tr-top, -tbody-top)
	for(r = 0; r < nr; r++) {
		relative(t.rows[r], cw, -1);
		g := t.groups[r];
		if(g != nil && (r == 0 || t.groups[r-1] != g))
			relative(g, cw, -1);
	}
	capsh := gridtop - b.bt - b.pt;	# the captions, above and below, outside the table box
	if(t.tb != nil)
		y += b.bb + b.pb;	# past the bottom border half
	gridbot := y;
	for(cl = t.captions; cl != nil; cl = tl cl) {
		k := hd cl;
		if(k.st.captionbottom)
			y = laycaption(l, k, b, cw, y);
	}
	capsh += y - gridbot;
	h := y - b.bt - b.pt + vextra(b);
	if(t.tb != nil)
		h = y;
	if(sh + capsh > h)
		h = sh + capsh;
	b.h = h;
}

curdoc: ref Doc;

# a cell's baseline: its first in-flow line box's, from its top border
# edge (§17.5.3); -1 for a cell with none, which is not baseline-aligned
# but sits at the row's top, as browsers have it (baseline-empty-cell-001)
cellbaseline(k: ref Box): int
{
	(ok, by) := firstbaseline(k);
	if(ok)
		return by;
	return -1;
}

rowgroupof(t: ref Tgrid, row: ref Box): ref Box
{
	for(i := 0; i < len t.rows; i++)
		if(t.rows[i] == row)
			return t.groups[i];
	return nil;
}

laycaption(l: ref L, k, b: ref Box, cw, y: int): int
{
	x := b.bl + b.pl;
	if(b.st.collapse) {
		# outside the collapsed borders: the table's whole width
		cw += hextra(b);
		x = 0;
	}
	edges(k, cw);
	sizew(k, cw, -1);
	layblock(l, k, cw, -1, nil, 0, 0);
	k.x = x + k.ml;
	k.y = y + k.mt;
	end := k.y + k.h + k.mb;
	relative(k, cw, -1);	# (position-relative-table-caption)
	return end;
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

# the content of b moved dx to the right
shiftx(b: ref Box, dx: int)
{
	for(i := 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++)
			shiftfrag(ln.frags[j], dx, 0);
	}
	if(b.lines == nil)
		for(i = 0; i < len b.kids; i++)
			b.kids[i].x += dx;
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

# the positioned inline box that is k's containing block, if the
# nearest positioned ancestor is one
icbof(k: ref Box): ref Box
{
	if(k.st.position == Style->Pfixed)
		return nil;
	for(p := k.parent; p != nil; p = p.parent)
		if(ispositioned(p)) {
			if(p.kind == Kinline)
				return p;
			return nil;
		}
	return nil;
}

# A positioned inline box's containing block: its padding box, from
# its first fragment's start to its last fragment's end (CSS 2.2
# §10.1), in the coordinates of the block container cb that holds
# the lines; nil when it has no fragment yet (position-absolute-in-
# inline-003)
inlinearea(cb, p: ref Box): ref Rect
{
	(ok, r) := spanextent(cb, p, 0, 0, 0, Rect((0, 0), (0, 0)));
	if(!ok)
		return nil;
	return ref r;
}

spanextent(b, p: ref Box, ox, oy, ok: int, r: Rect): (int, Rect)
{
	for(i := 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++) {
			f := ln.frags[j];
			if(f.kind == Fatomic) {
				(ok, r) = spanextent(f.box, p, ox + f.box.x, oy + f.box.y, ok, r);	# (an inline-block holding it: position-absolute-in-inline-005)
				continue;
			}
			# a block inside the inline splits it into pieces, each a
			# box of its own: the pieces are one inline here (position-absolute-in-inline-003)
			if(f.kind != Fspan || f.box != p && (p.node == 0 || f.box.node != p.node))
				continue;
			x0 := ox + f.x;
			x1 := x0 + f.w;
			if(leftedge(f))
				x0 += p.ml + p.bl;
			if(rightedge(f))
				x1 -= p.mr + p.br;
			fr := Rect((x0, oy + f.y + p.bt), (x1, oy + f.y + f.h - p.bb));
			# the top and start edge of the first fragment, the bottom
			# and end edge of the last (CSS 2.1 §10.1, position-absolute-in-inline-005)
			if(!ok)
				r = fr;
			else {
				r.max.y = fr.max.y;
				if(p.st.dirrtl)
					r.min.x = fr.min.x;
				else
					r.max.x = fr.max.x;
			}
			ok = 1;
		}
	}
	if(b.lines == nil)
		for(i = 0; i < len b.kids; i++) {
			k := b.kids[i];
			if(k.kind == Kinline || k.kind == Ktext)
				continue;
			(ok, r) = spanextent(k, p, ox + k.x, oy + k.y, ok, r);
		}
	return (ok, r);
}

# a flex container's content box, in the coordinates of the
# containing block cb that holds it (or is it): the static position
# rectangle of its absolutely positioned children (Flexbox §4.1)
flexarea(cb, fcb: ref Box): ref Rect
{
	x := fcb.bl + fcb.pl;
	y := fcb.bt + fcb.pt;
	for(p := fcb; p != nil && p != cb; p = p.parent) {
		x += p.x;
		y += p.y;
	}
	return ref Rect((x, y), (x + fcb.w - hextra(fcb), y + fcb.h - vextra(fcb)));
}

# how a flex container's absolutely positioned child aligns in its
# static position rectangle along the x (horiz 1) or y axis: as the
# sole item, by the container's justify-content on the main axis and
# the item's align-self on the cross axis (position-absolute-center-001)
flexspalign(a: ref Abs, k: ref Box, horiz: int): int
{
	fcb := a.sparent;
	main := a.flexsp == 1 && horiz || a.flexsp == 2 && !horiz;
	if(main) {
		case fcb.st.justifycontent {
		Style->ALend or Style->ALright or Style->ALflowend =>
			return Style->ALend;
		Style->ALcenter or Style->ALaround or Style->ALevenly =>
			return Style->ALcenter;
		}
		return Style->ALstart;
	}
	al := k.st.alignself;
	if(al == Style->ALauto)
		al = fcb.st.alignitems;
	case al {
	Style->ALend or Style->ALflowend =>
		return Style->ALend;
	Style->ALcenter =>
		return Style->ALcenter;
	}
	return Style->ALstart;
}

# and whether that alignment is "safe", keeping a box that overflows
# the rectangle at its start (flex-abspos-staticpos-align-self-safe-001)
flexspsafe(a: ref Abs, k: ref Box, horiz: int): int
{
	fcb := a.sparent;
	main := a.flexsp == 1 && horiz || a.flexsp == 2 && !horiz;
	if(main)
		return fcb.st.safe & 2;
	if(k.st.alignself == Style->ALauto)
		return fcb.st.safe & 4;
	return k.st.safe & 4;
}

# A grid's absolutely positioned child aligns in its static rectangle
# by its own justify-self or align-self, auto being the grid's
# justify-items or align-items (Grid 2 §9.2, Align 3 §6); in the
# inline axis start and end follow the grid's direction
# (grid-abspos-staticpos-align-self-001, -rtl-001, -align-items-center).
gridspalign(a: ref Abs, k: ref Box, horiz: int): int
{
	g := a.sparent;
	al := k.st.alignself;
	if(horiz)
		al = k.st.justifyself;
	if(al == Style->ALauto) {
		al = g.st.alignitems;
		if(horiz)
			al = g.st.justifyitems;
	}
	rtl := horiz && g.st.dirrtl;
	case al {
	Style->ALend or Style->ALflowend =>
		if(rtl)
			return Style->ALstart;
		return Style->ALend;
	Style->ALcenter =>
		return Style->ALcenter;
	Style->ALright =>
		if(horiz)
			return Style->ALend;
	}
	if(rtl)
		return Style->ALend;
	return Style->ALstart;
}

# relative and sticky positioning: shift the box after it is placed
relative(k: ref Box, cbw, cbh: int)
{
	st := k.st;
	if(st.position != Style->Prelative && st.position != Style->Psticky)
		return;
	# both left and right set: the one at the containing block's start wins (§9.4.3)
	rtl := st.dirrtl;
	if(k.parent != nil)
		rtl = k.parent.st.dirrtl;
	if(st.left.kind != Style->Lauto && (st.right.kind == Style->Lauto || !rtl))
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
	for(; mine != nil; mine = tl mine) {
		a := hd mine;
		if(a.icb != nil && a.area == nil)
			a.area = inlinearea(b, a.icb);
		if(a.flexsp >= 1 && a.flexsp <= 3 && a.area == nil)
			a.area = flexarea(b, a.sparent);
		layabs(l, a, b, pr);
	}
}

layabs(l: ref L, a: ref Abs, cb: ref Box, pr: Rect)
{
	k := a.box;
	st := k.st;
	sr := pr;	# the static position rectangle: the containing block's padding box, a grid area, or a flex or grid container's content box
	if(a.area != nil) {
		sr = *a.area;
		if(a.flexsp == 0 || a.flexsp == 4)
			pr = *a.area;	# a grid area is the containing block too
	}
	spa := a.area != nil && a.icb == nil && a.flexsp != 4;	# the static position is sr's start, the box aligned in sr
	cbw := pr.dx();
	cbh := pr.dy();
	# static position, in cb coordinates
	sx := a.sx;
	sy := a.sy;
	if(a.frag != nil)
		sx = a.frag.x;
	if(spa) {
		sx = sr.min.x;	# a grid area or a flex or grid container: the static position is its start
		sy = sr.min.y;
	}
	for(p := a.sparent; p != nil && p != cb; p = p.parent) {
		sx += p.x;
		sy += p.y;
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
	if(st.width.kind == Style->Lstretch) {
		# stretch: what the insets leave, from the static position when both are auto
		avail := cbw;
		if(!lauto)
			avail -= left;
		if(!rauto)
			avail -= right;
		if(lauto && rauto)
			avail -= sx - pr.min.x;
		w = avail - k.ml - k.mr;
	}
	if(w < 0 && (lauto || rauto) && (sh := spech(k, st.height, cbh)) >= 0)
		w = transferred(k, sh);
	if(w < 0 && truereplaced(k)) {
		# its own size, whatever the insets say (§10.3.8: an inset is
		# dropped instead); a form control is not replaced that way and stretches
		(rw, nil) := replacedsize(k, cbw, cbh);
		w = rw + hextra(k);
	} else if(w < 0) {
		# both insets set: the width is what they leave, except for a
		# table, whose auto width is always its own (CSS 2.1 §17.5.2);
		# auto margins then centre it (position-absolute-center-006)
		if(!lauto && !rauto && k.kind != Ktable)
			w = cbw - left - right - k.ml - k.mr;
		else {
			if((ih := spech(k, st.height, cbh)) >= 0) {
				# its height is known before its width: its children's
				# percentage heights see it while it is measured
				pcthbox = k;
				pcthval = ih - vextra(k);
			} else if(st.height.kind == Style->Lauto && !tauto && !bauto) {
				# as the insets settle it
				pcthbox = k;
				pcthval = cbh - top - bottom - k.mt - k.mb - vextra(k);
			}
			(mn, mx) := intrinsic(k);
			pcthbox = nil;
			avail := cbw - k.ml - k.mr;
			if(!lauto)
				avail -= left;
			if(!rauto)
				avail -= right;
			if(lauto && rauto && !spa) {
				# the static position is the left (or right) inset
				# (§10.3.7): shrink-to-fit in what it leaves, even
				# past the containing block (descendant-static-
				# position-001); a table, in no more than the
				# containing block has (absolute-tables-010)
				room := cbw - (sx - pr.min.x);
				if(a.rightedge)
					room = sx - pr.min.x;
				if(k.kind == Ktable && room > cbw)
					room = cbw;
				avail = room - k.ml - k.mr;
			}
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
			if(free < 0) {
				# not negative: the one at the direction's start is 0
				# and the other takes the overflow (§10.3.7)
				k.ml = 0;
				k.mr = free;
				if(st.dirrtl) {
					k.mr = 0;
					k.ml = free;
				}
			}
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
		# auto insets in a grid area: aligned in it as justify-self
		# says, normal being its start (Grid 2 §9, Position 3 §3.5);
		# safe keeps a box that overflows it at the start
		if(spa) {
			ja := abspalign(st.justifyself);
			jsafe := st.safe & 8;
			if(a.flexsp == 1 || a.flexsp == 2) {
				ja = flexspalign(a, k, 1);
				jsafe = flexspsafe(a, k, 1);
			} else if(a.sparent.kind == Kgrid)
				ja = gridspalign(a, k, 1);
			if(jsafe && k.w + k.ml + k.mr > cbw)	# against the containing block, not the static rectangle (flex-abspos-align-self-safe-outer-cb-003)
				ja = Style->ALstart;
			case ja {
			Style->ALstart or Style->ALleft =>
				x = sr.min.x + k.ml;
			Style->ALend or Style->ALright =>
				x = sr.max.x - k.mr - k.w;
			Style->ALcenter =>
				x = sr.min.x + (sr.dx() - k.w - k.ml - k.mr)/2 + k.ml;
			}
		}
	}
	layblock(l, k, cbw, cbh, nil, 0, 0);
	h := k.h;
	if((st.height.kind == Style->Lauto && !truereplaced(k) || st.height.kind == Style->Lstretch) && !tauto && !bauto) {
		h = clamph(k, cbh - top - bottom - k.mt - k.mb, cbh);
		k.h = h;
	} else if(st.height.kind == Style->Lstretch) {
		avail := cbh;
		if(!tauto)
			avail -= top;
		if(!bauto)
			avail -= bottom;
		if(tauto && bauto)
			avail -= sy - pr.min.y;
		h = clamph(k, avail - k.mt - k.mb, cbh);
		k.h = h;
	} else if(!tauto && !bauto && (st.mt.kind == Style->Lauto || st.mb.kind == Style->Lauto)) {
		# a definite or intrinsic (fit-content) height: auto margins
		# auto margins take what the insets and height leave (§10.6.4)
		free := cbh - top - bottom - h;
		if(st.mt.kind == Style->Lauto && st.mb.kind == Style->Lauto) {
			k.mt = free/2;
			k.mb = free - k.mt;
		} else if(st.mt.kind == Style->Lauto)
			k.mt = free - k.mb;
		else
			k.mb = free - k.mt;
	}
	y: int;
	if(!tauto)
		y = pr.min.y + top + k.mt;
	else if(!bauto)
		y = pr.max.y - bottom - k.mb - h;
	else {
		y = sy + k.mt;
		if(spa) {
			aa := abspalign(st.alignself);
			asafe := st.safe & 4;
			if(a.flexsp == 1 || a.flexsp == 2) {
				aa = flexspalign(a, k, 0);
				asafe = flexspsafe(a, k, 0);
			} else if(a.sparent.kind == Kgrid)
				aa = gridspalign(a, k, 0);
			if(asafe && h + k.mt + k.mb > cbh)
				aa = Style->ALstart;
			case aa {
			Style->ALstart =>
				y = sr.min.y + k.mt;
			Style->ALend =>
				y = sr.max.y - k.mb - h;
			Style->ALcenter =>
				y = sr.min.y + (sr.dy() - h - k.mt - k.mb)/2 + k.mt;
			}
		}
	}
	k.x = x;
	k.y = y;
	for(pl := cb.pos; pl != nil; pl = tl pl)
		if(hd pl == k)
			break;
	if(pl == nil)
		cb.pos = k :: cb.pos;
	k.parent = cb;
}

# an absolutely positioned box's self-alignment: auto is normal, and
# stretch, with its insets auto, behaves as start
abspalign(a: int): int
{
	case a {
	Style->ALauto or Style->ALstretch =>
		return Style->ALnormal;
	}
	return a;
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
floatwidth(k: ref Box, cw, ch: int): int
{
	edges(k, cw);
	w := specw(k, k.st.width, cw);
	wauto := w < 0;
	if(w < 0 && k.st.aspect > 0.0 && k.kind != Kreplaced && (sh := spech(k, k.st.height, ch)) >= 0)
		w = transferred(k, clamph(k, sh, ch));
	if(w < 0) {
		if(k.kind == Kreplaced) {
			(rw, nil) := replacedsize(k, cw, ch);
			w = rw + hextra(k);
		} else {
			# its percentage height, and those within it, are of the
			# containing block's height while it is measured
			# (intrinsic-percent-replaced-003, -006)
			opcth := pcth;
			pcth = ch;
			(mn, mx) := intrinsic(k);
			pcth = opcth;
			w = fit(mn, mx, cw) - mgs(k);
		}
	}
	if(k.st.ml.kind == Style->Lauto)
		k.ml = 0;
	if(k.st.mr.kind == Style->Lauto)
		k.mr = 0;
	if(wauto)
		w = transferw(k, w, ch);	# min/max-height bound an auto width through the ratio
	k.w = clampw(k, w, cw);
	return k.ml + k.w + k.mr;
}

placefloat(l: ref L, k: ref Box, fc: ref Fctx, cx, y, cw, ch, ox, oy: int)
{
	floatwidth(k, cw, ch);
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
	if(b.img != nil && iw == 0 && ih == 0 && !b.svg) {
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
	if((st.width.kind == Style->Lpx || st.width.kind == Style->Lcalc) && b != nowidth) {	# (measured for a keyword min or max: its width aside, replaced-min-width-min-content)
		if(!(cbw < 0 && st.width.pct != 0.0)) {
			w = res(st.width, cbw);
			if(st.borderbox)
				w -= hextra(b);
		}
	}
	if(st.height.kind == Style->Lpx && (st.height.pct == 0.0 || cbh >= 0) && b != asauto) {
		h = res(st.height, cbh);
		if(st.borderbox)
			h -= vextra(b);
	}
	# a specified dimension is used as its min and max constrain it,
	# and the other follows the ratio from that (CSS 2.2 §10.4)
	if(h >= 0) {
		if((mh := spech(b, st.maxheight, cbh)) >= 0 && h > mh - vextra(b))
			h = mh - vextra(b);
		if((nh := spech(b, st.minheight, cbh)) >= 0 && h < nh - vextra(b))
			h = nh - vextra(b);
	}
	if(w >= 0) {
		if(st.maxwidth.kind != Style->Lnone && (mw := specw(b, st.maxwidth, cbw)) >= 0 && w > mw - hextra(b))
			w = mw - hextra(b);
		if((nw := specw(b, st.minwidth, cbw)) >= 0 && w < nw - hextra(b))
			w = nw - hextra(b);
	}
	ratio := aspect(b, iw, ih);
	if(b.svg) {
		# an SVG's dimensions (SVG 2 §8.6, CSS 2.2 §10.3.2, §10.6.2): its
		# own, a percentage of the containing block, a ratio alone
		# filling the containing block's width, else 300 by 150
		# (replaced-intrinsic-001..005)
		# a specified dimension and the ratio give the other first
		# (CSS 2.2 §10.3.2; replaced-elements-height-20)
		if(w < 0 && h >= 0 && ratio > 0.0)
			w = ir(real h * ratio);
		if(h < 0 && w >= 0 && ratio > 0.0)
			h = ir(real w / ratio);
		if(w < 0 && iw > 0)
			w = iw;
		if(h < 0 && ih > 0)
			h = ih;
		# a percentage width, and a ratio alone, fill the width the
		# containing block leaves after the box's padding and borders,
		# as browsers have it (replaced-intrinsic-003)
		if(w < 0 && b.ipw > 0.0 && cbw >= 0)
			w = ir(real (cbw - hextra(b)) * b.ipw / 100.0);
		if(h < 0 && b.iph > 0.0 && cbh >= 0)
			h = ir(real (cbh - vextra(b)) * b.iph / 100.0);
		if(w < 0 && h < 0 && ratio > 0.0 && cbw >= 0)
			w = cbw - hextra(b);
		if(w < 0) {
			if(h >= 0 && ratio > 0.0)
				w = ir(real h * ratio);
			else
				w = 300;
		}
		if(h < 0) {
			if(ratio > 0.0)
				h = ir(real w / ratio);
			else
				h = 150;
		}
	} else if(w < 0 && h < 0) {
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
	if(ratio > 0.0 && w > 0) {
		# a keyword min or max height: the height the width gives
		# through the ratio (replaced-min-height-min-content)
		kh := ir(real w / ratio);
		if(kwsize(st.maxheight) && h > kh)
			h = kh;
		if(kwsize(st.minheight) && h < kh)
			h = kh;
	}
	if(ratio > 0.0) {
		# min/max constraint violations with a ratio (CSS 2.2 §10.4's
		# table): a constrained dimension takes the other with it
		# (replaced-elements-max-height-20, -min-height-40); lengths
		# and percentages only (a keyword asks for the intrinsic size,
		# which is this).  A flex item's base size ignores its main
		# axis constraints, which clamp the flexed size later, but
		# takes the cross axis ones transferred through the ratio
		# (Flexbox §9.2; flex-aspect-ratio-img-row-007, -010,
		# flex-minimum-width-flex-items-009)
		fw := 1;	# the width constraints count
		fh := 1;
		if(b.parent != nil && b.parent.kind == Kflex) {
			if(b.parent.st.flexdir < 2)
				fw = 0;
			else
				fh = 0;
		}
		mw := -1;
		if(fw && plainlen(st.maxwidth) && (mw = specw(b, st.maxwidth, cbw)) >= 0)
			mw -= hextra(b);
		nw := 0;
		if(fw && plainlen(st.minwidth) && (nw = specw(b, st.minwidth, cbw)) >= 0)
			nw -= hextra(b);
		if(nw < 0)
			nw = 0;
		mh := -1;
		if(fh && plainlen(st.maxheight) && (mh = spech(b, st.maxheight, cbh)) >= 0)
			mh -= vextra(b);
		nh := 0;
		if(fh && plainlen(st.minheight) && (nh = spech(b, st.minheight, cbh)) >= 0)
			nh -= vextra(b);
		if(nh < 0)
			nh = 0;
		if(mw >= 0 && w > mw && mh >= 0 && h > mh) {
			if(real mw * real h <= real mh * real w) {
				w = mw;
				h = ir(real w / ratio);
				if(h < nh)
					h = nh;
			} else {
				h = mh;
				w = ir(real h * ratio);
				if(w < nw)
					w = nw;
			}
		} else if(mw >= 0 && w > mw) {
			w = mw;
			h = ir(real w / ratio);
			if(h < nh)
				h = nh;
		} else if(mh >= 0 && h > mh) {
			h = mh;
			w = ir(real h * ratio);
			if(w < nw)
				w = nw;
		} else if(w < nw && h < nh) {
			if(real nw * real nz1(h) <= real nh * real nz1(w)) {
				h = nh;
				w = ir(real h * ratio);
				if(mw >= 0 && w > mw)
					w = mw;
			} else {
				w = nw;
				h = ir(real w / ratio);
				if(mh >= 0 && h > mh)
					h = mh;
			}
		} else if(w < nw) {
			w = nw;
			h = ir(real w / ratio);
			if(mh >= 0 && h > mh)
				h = mh;
		} else if(h < nh) {
			h = nh;
			w = ir(real h * ratio);
			if(mw >= 0 && w > mw)
				w = mw;
		}
	}
	return (w, h);
}

# a length or a percentage, not a keyword
plainlen(l: Style->Len): int
{
	return l.kind == Style->Lpx || l.kind == Style->Lcalc;
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
	if(ratio == 0.0 || b.st.aspectauto) {
		if(b.svg)
			ratio = b.iratio;
		else if(iw > 0 && ih > 0 && hasratio(b))
			ratio = real iw / real ih;
	}
	return ratio;
}

# a replaced box in CSS 2.2's sense (an image, video, canvas, frame,
# object or svg): one with its own size; a form control is a box of
# its own kind that stretches like a block
truereplaced(b: ref Box): int
{
	if(b.kind != Kreplaced)
		return 0;
	if(b.node == 0 || curdoc == nil)
		return 1;
	nd := curdoc.nodes[b.node];
	if(nd.ns == Dom->SVG)
		return 1;
	case nd.tag {
	Dom->Timg or Dom->Tvideo or Dom->Tcanvas or Dom->Tiframe or Dom->Tembed or Dom->Tobject =>
		return 1;
	}
	return 0;
}

# the default 300x150 of an iframe, embed or object, or of an svg with
# neither its dimensions nor a viewBox, is a size, not a ratio (CSS 2.2
# §10.3.2 gives them none); a canvas's bitmap has one
hasratio(b: ref Box): int
{
	if(b.node == 0 || curdoc == nil)
		return 1;
	nd := curdoc.nodes[b.node];
	if(nd.ns == Dom->SVG)
		return curdoc.attr(b.node, "viewBox") != nil || curdoc.attr(b.node, "width") != nil && curdoc.attr(b.node, "height") != nil;
	case nd.tag {
	Dom->Tiframe or Dom->Tembed or Dom->Tobject =>
		return b.img != nil;
	}
	return 1;
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
	ex := hextra(b) + mgs(b) + (pcth + 1) * 131072;	# the height its percentages see is part of the answer
	if(b.igen == laygen && b.iex == ex)
		return (b.imn, b.imx);
	(mn, mx) := intrinsic1(b);
	# a keyword width is that size, whatever is inside
	wv := b.st.width;
	case wv.kind {
	Style->Lmax =>	mn = mx;
	Style->Lmin =>	mx = mn;
	Style->Lfit =>
		if(wv.px != 0.0 && wv.pct == 0.0) {
			# fit-content(<length>): min(max-content, max(min-content,
			# the length)) is its contribution either way
			# (Sizing 3 §4.1; fit-content-length-percentage-011)
			a := ir(wv.px) + mgs(b);
			if(!b.st.borderbox)
				a += hextra(b);
			if(a < mn)
				a = mn;
			if(a > mx)
				a = mx;
			mn = mx = a;
		}
	}
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
	if(st.minwidth.kind == Style->Lpx && st.minwidth.pct == 0.0 || sizekw(st.minwidth)) {
		w := ir(st.minwidth.px) + mg;
		if(!st.borderbox)
			w += hextra(b);
		if(sizekw(st.minwidth)) {
			# min-content, max-content, fit-content(<length>); a
			# percentage argument is cyclic here, and the clamp leaves
			# the min-content size (fit-content-length-percentage-012)
			v := st.minwidth;
			if(v.kind == Style->Lfit && v.pct != 0.0)
				v = Style->Len(Style->Lmin, 0.0, 0.0, nil);
			w = specw(b, v, -1) + mg;
		}
		if(mn < w)
			mn = w;
		if(mx < w)
			mx = w;
	}
	if(st.maxwidth.kind == Style->Lpx && st.maxwidth.pct == 0.0 || sizekw(st.maxwidth)) {
		w := ir(st.maxwidth.px) + mg;
		if(!st.borderbox)
			w += hextra(b);
		if(sizekw(st.maxwidth)) {
			# a cyclic percentage argument: as none, clamped to the
			# max-content size (fit-content-length-percentage-013)
			v := st.maxwidth;
			if(v.kind == Style->Lfit && v.pct != 0.0)
				v = Style->Len(Style->Lmax, 0.0, 0.0, nil);
			w = specw(b, v, -1) + mg;
		}
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

kwsize(l: Style->Len): int
{
	return l.kind == Style->Lmin || l.kind == Style->Lmax || l.kind == Style->Lfit;
}

# an intrinsic sizing keyword that needs no containing block width
sizekw(l: Style->Len): int
{
	return l.kind == Style->Lmin || l.kind == Style->Lmax || l.kind == Style->Lfit && (l.px != 0.0 || l.pct != 0.0);
}

nowidth: ref Box;	# being measured for its content's width: its width property is ignored

# a textarea's cols and rows (HTML §4.10.11: 20 and 2 by default)
textarea(b: ref Box): (int, int)
{
	if(b.node == 0 || curdoc == nil || curdoc.nodes[b.node].tag != Dom->Ttextarea || curdoc.nodes[b.node].ns != Dom->HTML)
		return (0, 0);
	cols := 20;
	rows := 2;
	if((s := curdoc.attr(b.node, "cols")) != nil && int s > 0)
		cols = int s;
	if((s = curdoc.attr(b.node, "rows")) != nil && int s > 0)
		rows = int s;
	return (cols, rows);
}

intrinsic1(b: ref Box): (int, int)
{
	ex := hextra(b) + mgs(b);
	st := b.st;
	(cols, nil) := textarea(b);
	if(cols > 0 && st.width.kind == Style->Lauto) {
		w := ir(real cols * face(st).width("0")) + ex;	# cols characters wide, whatever it holds
		return (w, w);
	}
	if(st.width.kind == Style->Lpx && st.width.pct == 0.0 && b != nowidth) {
		w := ir(st.width.px);
		if(!st.borderbox)
			w += hextra(b);
		return (w + mgs(b), w + mgs(b));
	}
	if(st.contain & (Style->CTsize|Style->CTinlinesize)) {
		# size containment: as if empty, but for its explicit intrinsic
		# size (Contain 2 §4, Sizing 4 §5.1)
		w := 0;
		if(st.cisw.kind == Style->Lpx)
			w = ir(st.cisw.px);
		return (w + ex, w + ex);
	}
	if(b.kind == Kreplaced) {
		# a percentage height resolves against a definite containing
		# block height and transfers through the ratio (Sizing 3 §5.2.1)
		(w, nil) := replacedsize(b, -1, pcth);
		return (w + ex, w + ex);
	}
	if(st.aspect > 0.0 && st.height.kind == Style->Lpx && st.height.pct == 0.0 && b != noratio) {
		# transferred from its height (Sizing 4 §5.2.1); a scroll
		# container's min-content contribution is nothing (its automatic minimum)
		h := ir(st.height.px);
		if(!st.borderbox)
			h += vextra(b);
		h = clamph(b, h, pcth);	# as used, within min-height and max-height
		w := transferred(b, h) + mgs(b);
		if(isscroller(b))
			return (mgs(b), w);
		return (w, w);
	}
	if(b.kind == Ktable) {
		(tmn, tmx) := tableintrinsic(b);
		return (tmn + mgs(b), tmx + mgs(b));
	}
	if(islanes(b)) {
		(lmn, lmx) := lanesintrinsic(b);
		return (lmn + ex, lmx + ex);
	}
	if(b.kind == Kgrid && (st.gridcols != nil || st.autoflow & 1)) {
		# the columns add up: a fixed one is its size, any other is
		# the largest contribution of the items placed in it (the
		# items taken in order, one per column, as auto-placement
		# would put them without spans); flowing by column without
		# a template, each item gets an implicit column of its own
		gap := 0;
		if(st.colgap.kind != Style->Lnormal)
			gap = res(st.colgap, 0);
		(cols, names) := tracks(st.gridcols, 0, gap);
		kcol := array[len b.kids] of {* => -1};	# the column each item starts in
		if(len cols == 0 && st.autoflow & 1) {
			# flowing by column with no template: as many implicit
			# columns as placing the items down the rows takes (an
			# item given a row takes the first free cell in it)
			nrows := 1;
			for(i := 0; i < len b.kids; i++) {
				k := b.kids[i];
				if(isabs(k))
					continue;
				(r0, r1) := gridspan(k.st.rowstart, k.st.rowend, nil, 0, nil, 0);
				rs := spanof(r0, r1, k.st.rowstart, k.st.rowend);
				if(r1 > nrows)
					nrows = r1;
				if(rs > nrows)
					nrows = rs;
			}
			occ := ref Occ(array[0] of array of byte, 0);
			ncols := 0;
			cc := 0;
			cr := 0;
			for(i = 0; i < len b.kids; i++) {
				k := b.kids[i];
				if(isabs(k))
					continue;
				(r0, r1) := gridspan(k.st.rowstart, k.st.rowend, nil, 0, nil, 0);
				rs := spanof(r0, r1, k.st.rowstart, k.st.rowend);
				cs := spanof(-1, -1, k.st.colstart, k.st.colend);
				c := 0;
				if(r0 >= 0) {
					while(!occ.free(r0, r1, c, c + cs))
						c++;
					occ.mark(r0, r1, c, c + cs);
				} else {
					c = cc;
					r := cr;
					for(;;) {
						if(r + rs > nrows) {
							r = 0;
							c++;
							continue;
						}
						if(occ.free(r, r + rs, c, c + cs))
							break;
						r++;
					}
					occ.mark(r, r + rs, c, c + cs);
					cc = c;
					cr = r + rs;
				}
				kcol[i] = c;
				if(c + cs > ncols)
					ncols = c + cs;
			}
			cols = growtracks(cols, ncols, st.autocols, 0);
		}
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
				(a0, a1) := gridspan(k.st.colstart, k.st.colend, names, len cols, nil, 1);
				span := spanof(a0, a1, k.st.colstart, k.st.colend);
				if(span > len cols)
					span = len cols;
				if(kcol[i] >= 0)
					a0 = kcol[i];
				else if(a0 < 0) {
					if(c + span > len cols)
						c = 0;
					a0 = c;
				}
				if(a0 + span > len cols)
					a0 = len cols - span;
				if(st.margintrim != 0) {
					# margin-trim: the margins at the grid's edges are not part of the contribution (grid-inline)
					tr := 0;
					if(a0 == 0 && st.margintrim & 4) tr += k.ml;
					if(a0 + span == len cols && st.margintrim & 8) tr += k.mr;
					kmn -= tr;
					kmx -= tr;
				}
				spreadspan(cols, cmn, cmx, a0, a0 + span, kmn, kmx, gap);
				c = (a0 + span) % len cols;
			}
			wmn := gap * (len cols - 1) + ex;
			wmx := wmn;
			for(i = 0; i < len cols; i++)
				if(cols[i].lo.kind == Tfixed && cols[i].hi.kind == Tfixed) {
					wmn += int cols[i].hi.v;
					wmx += int cols[i].hi.v;
				} else {
					wmn += cmn[i];
					x := cmx[i];
					if(cols[i].hi.kind == Tfit && x > int cols[i].hi.v)
						x = int cols[i].hi.v;	# fit-content: no wider than its argument
					if(x < cmn[i])
						x = cmn[i];
					wmx += x;
				}
			return (wmn, wmx);
		}
	}
	mn := 0;
	mx := 0;
	opcth := pcth;
	pcth = definiteh(b);
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
			if(b.kind == Kflex && pcth >= 0 && b.st.flexwrap == 0 && stretched(b, k)) {
				# a stretched item is as tall as the line: its
				# percentage heights see that while it is measured
				pcthbox = k;
				pcthval = pcth - k.mt - k.mb - vextra(k);
			}
			(kmn, kmx) := contribution(k);
			pcthbox = nil;
			if(b.st.flexwrap != 0) {
				if(kmn > mn)
					mn = kmn;
			} else
				mn += kmn;
			mx += kmx;
		}
	} else if(b.kind == Kflex && b.st.flexwrap != 0 && (ph := packh(b)) >= 0) {
		# a wrapping column flex container of definite height (or a
		# max-height): the items fill columns by their flex base sizes,
		# and the columns' widths add up, with the gaps between
		# (Flexbox §9.9.1)
		rg := 0;
		if(b.st.rowgap.kind != Style->Lnormal)
			rg = res(b.st.rowgap, 0);
		cg := 0;
		if(b.st.colgap.kind != Style->Lnormal)
			cg = res(b.st.colgap, 0);
		y := 0;
		colw := 0;
		ncol := 0;
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			if(isabs(k))
				continue;
			edges(k, 0);
			(kmn, kmx) := contribution(k);
			hb := spech(k, k.st.basis, ph);
			if(hb < 0)
				hb = spech(k, k.st.height, ph);
			if(hb < 0)
				hb = 0;	# its content height is not known here
			hb += k.mt + k.mb;
			if(y > 0 && y + rg + hb > ph) {
				mx += colw + cg;
				colw = 0;
				y = 0;
			}
			if(y > 0)
				y += rg;
			y += hb;
			if(kmx > colw)
				colw = kmx;
			if(kmn > mn)
				mn = kmn;
			ncol++;
		}
		mx += colw;
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
	pcth = opcth;
	if(mx < mn)	# negative margins can make a sum smaller than its largest part
		mx = mn;
	return (mn + ex, mx + ex);
}

# The definite content height of the box whose children are being
# measured, which their percentage heights resolve against (Sizing 3
# §5.2.1); -1 when there is none.  An absolute's insets can impose one
# from outside while it is measured.
pcth := -1;
pcthbox: ref Box;
pcthval := -1;

definiteh(b: ref Box): int
{
	if(b == pcthbox)
		return pcthval;
	st := b.st;
	if(st.height.kind == Style->Lauto && b.kind == Kblock && curdoc != nil && curdoc.quirks && !(b.parent != nil && b.parent.kind == Kcell))
		return pcth;	# the percentage height calculation quirk: through auto-height blocks (not a cell's child)
	if(st.height.kind == Style->Lauto && st.aspect > 0.0 && b.kind != Kreplaced &&
	   st.width.kind == Style->Lpx && st.width.pct == 0.0) {
		# from a definite width through its aspect ratio (Sizing 4 §5.3)
		w := ir(st.width.px);
		if(!st.borderbox)
			w += hextra(b);
		h := ratioh(b, w) - vextra(b);
		if(h < 0)
			h = 0;
		return h;
	}
	if(st.height.kind != Style->Lpx)
		return -1;
	h := -1;
	if(st.height.pct == 0.0)
		h = ir(st.height.px);
	else if(pcth >= 0)
		h = ir(st.height.px + st.height.pct * real pcth / 100.0);
	else
		return -1;
	if(st.borderbox)
		h -= vextra(b);
	if(h < 0)
		h = 0;
	return h;
}

# the height a wrapping column flex container packs its columns into:
# its definite content height, else its max-height
packh(b: ref Box): int
{
	if(pcth >= 0)
		return pcth;
	if(b.st.maxheight.kind != Style->Lnone && (mh := spech(b, b.st.maxheight, -1)) >= 0)
		return mh - vextra(b);
	return -1;
}

# is the flex item k stretched across the line (align-self: stretch or
# normal with an auto height)?
stretched(b, k: ref Box): int
{
	a := k.st.alignself;
	if(a == Style->ALauto)
		a = b.st.alignitems;
	return (a == Style->ALnormal || a == Style->ALstretch) && k.st.height.kind == Style->Lauto;
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
	wstpass(items);
	lspass(items);
	items = hangpass(items);
	autospacepass(items);
	mn := 0.0;
	mx := 0.0;
	line := 0.0;
	word := 0.0;
	# collapsible spaces count only between content: those at a line's
	# ends are removed when it is laid out
	sp := 0.0;	# collapsible space waiting for content after it
	content := 0;	# the line has content
	prevw: ref Item;	# the word before, with nothing but inline box edges since
	shy := 0;		# a soft hyphen came between: still one word for the min-content size
	trail := 0.0;	# the letter spacing after the line's last character so far: trimmed at a line's end
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		case it.kind {
		Iword =>
			w := it.w;
			if(it.hang)
				w = 0.0;	# a hanging mark takes no room
			if(it.nowrap || shy || prevw != nil && !wordgap(prevw.box, prevw.text, it, 1))
				word += w;	# no break between: one unit
			else
				word = w;
			shy = 0;
			if(word - it.tls > mn)
				mn = word - it.tls;
			line += sp + w;
			trail = it.tls;
			sp = 0.0;
			content = 1;
			prevw = it;
		Ispace =>
			shy = it.text == "\u00AD";
			if(it.nowrap && !hangsep(it.text) || shy) {
				# an unbreakable space is part of the word (a hanging one
				# is never: trailing-ogham-003); so is a soft hyphen: the
				# min-content size does not hyphenate (word-break-auto-phrase-006)
				word += it.w;
				if(word > mn)
					mn = word;
			} else
				word = 0.0;
			if(it.text == " " && collapsible(it.box.st) || hangsep(it.text) && it.box.st.whitespace != Style->Wbreakspaces) {
				if(content)
					sp += it.w;	# at the end it hangs
			} else {
				line += sp + it.w;
				trail = it.tls;
				sp = 0.0;
				content = 1;
			}
		Iopen or Iclose =>
			line += it.w;
			word += it.w;
			if(it.w > 0.0) {
				content = 1;
				trail = 0.0;
			}
			continue;	# (prevw stays: edges are no opportunity)
		Iatomic =>
			edges(it.box, 0);	# its padding and borders count; % ones are 0 here
			(kmn, kmx) := contribution(it.box);
			if(real kmn > mn)
				mn = real kmn;
			line += sp + real kmx;
			trail = 0.0;
			sp = 0.0;
			word = 0.0;
			content = 1;
		Ibreak =>
			if(line - trail > mx)
				mx = line - trail;
			line = 0.0;
			trail = 0.0;
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
		if(it.kind != Iword)
			prevw = nil;
	}
	if(line - trail > mx)
		mx = line - trail;
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
	tls:	real;		# text: the letter spacing after its last character (lspass)
	hang:	int;		# hanging punctuation: 1 an opening mark that starts the block, 2 a closing one that ends it (hangpass)
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
	(deco, decocolor) := flowdeco(b);
	f := ref Fl(nil, 1, deco, decocolor);
	for(i := 0; i < len b.kids; i++)
		flat(f, b.kids[i]);
	r: list of ref Item;
	for(l := f.items; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# The text decorations of the block container b's inline content: its
# own and those propagated to it from its ancestors, down through
# in-flow boxes (blocks, table parts, anonymous boxes) but not into
# floats, absolutes or atomic inlines (CSS 2.2 §16.3.1); the colour is
# the nearest decorated box's.
flowdeco(b: ref Box): (int, int)
{
	d := 0;
	c := 0;
	for(k := b; k != nil; k = k.parent) {
		if(k.st.decoration != 0) {
			if(d == 0)
				c = k.st.decorationcolor;
			d |= k.st.decoration;
		}
		if(k.inl || isoof(k))
			break;
	}
	return (d, c);
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
		emit(f, ref Item(Ibreak, nil, 0.0, b, nil, 0, 0, 0, 0, 0, 0.0, 0));
		f.space = 1;
	Kinline =>
		edges(b, 0);
		odeco := f.deco;
		ocol := f.decocolor;
		if(b.st.decoration != 0) {
			f.deco |= b.st.decoration;
			f.decocolor = b.st.decorationcolor;
		}
		emit(f, ref Item(Iopen, nil, real (b.ml + b.bl + b.pl), b, nil, 0, 0, 0, 0, 0, 0.0, 0));
		for(i := 0; i < len b.kids; i++)
			flat(f, b.kids[i]);
		emit(f, ref Item(Iclose, nil, real (b.mr + b.br + b.pr), b, nil, 0, 0, 0, 0, 0, 0.0, 0));
		f.deco = odeco;
		f.decocolor = ocol;
	* =>
		if(isabs(b))
			emit(f, ref Item(Iabs, nil, 0.0, b, nil, 0, 0, 0, 0, 0, 0.0, 0));
		else if(isfloat(b))
			emit(f, ref Item(Ifloat, nil, 0.0, b, nil, 0, 0, 0, 0, 0, 0.0, 0));
		else {
			emit(f, ref Item(Iatomic, nil, 0.0, b, nil, 0, 0, 0, 0, 0, 0.0, 0));
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
		emit(f, ref Item(Iopen, nil, 0.0, b, nil, 0, 0, 0, 0, 0, 0.0, 0));
	emit(f, ref Item(Iword, b.text, fc.width(b.text), b, fc, 1, 0, 0, 0, 0, 0.0, 0));
	if(iso)
		emit(f, ref Item(Iclose, nil, 0.0, b, nil, 0, 0, 0, 0, 0, 0.0, 0));
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

# Whether a line may break between a and b with no space between them
# (UAX #14, the part that matters inside a run of letters): on either
# side of an ideograph or a Hangul syllable, except before closing
# punctuation, non-starters, marks and the like (LB13, LB21, LB22,
# LB24), after opening punctuation (LB14), around quotation marks
# (LB19), across glue and joiners (LB11, LB12) and inside a Hangul
# syllable's jamo (LB26).  Letters without spaces do not break.
lbmode := 0;	# line-break of the text being broken: 0 normal, 1 loose, 2 strict (Text 4 §5.3)
lbcjk := 0;	# its language is Chinese or Japanese
lbbreakall := 0;	# word-break: break-all: letters break like ideographs, punctuation keeps its rules
lbkeepall := 0;	# word-break: keep-all: no break between the letters of Chinese, Japanese and Korean

lbbreak(a, b: int): int
{
	if(bidi == nil)
		return isideo(a) || isideo(b);
	ca := bidi->lbclass(a);
	cb := bidi->lbclass(b);
	if(lbkeepall && cjkletter(ca) && cjkletter(cb))
		return 0;	# keep-all (Text 4 §5.2; word-break-keep-all-005: the ideographic space is not a letter)
	if(lbbreakall) {
		if(ca == Bidi->LBAL || ca == Bidi->LBNU)
			ca = Bidi->LBID;
		if(cb == Bidi->LBAL || cb == Bidi->LBNU)
			cb = Bidi->LBID;
	}
	if(lbmode == 2 && cb == Bidi->LBCJ)
		cb = Bidi->LBNS;	# strict: no break before small kana and the prolonged sound mark
	# line-break: loose in Chinese and Japanese (Text 4 §5.3) also
	# breaks before non-starters (iteration marks, centred punctuation,
	# small kana), before postfixes and after prefixes
	loosecjk := lbmode == 1 && lbcjk;
	case cb {
	Bidi->LBNS =>
		if(lbmode != 2 && lbcjk && (b == 16r301C || b == 16r30A0))
			break;	# normal and loose, in Chinese and Japanese: before 〜 and ゠
		if(loosecjk)
			break;
		return 0;
	Bidi->LBBA =>
		if(lbmode == 1 && (b == 16r2010 || b == 16r2013))
			break;	# loose: before a hyphen and an en dash
		return 0;
	Bidi->LBEX or Bidi->LBPO =>
		if(loosecjk)
			break;
		return 0;
	Bidi->LBCL or Bidi->LBCP or Bidi->LBIS or Bidi->LBSY or
	Bidi->LBHY or Bidi->LBCM or Bidi->LBZWJ or Bidi->LBIN or Bidi->LBWJ or Bidi->LBGL or Bidi->LBQU =>
		return 0;
	}
	case ca {
	Bidi->LBPR =>
		if(!loosecjk)
			return 0;
	Bidi->LBOP or Bidi->LBBB or Bidi->LBZWJ or Bidi->LBWJ or Bidi->LBGL or Bidi->LBQU or Bidi->LBCM =>
		return 0;
	Bidi->LBBA =>
		return 1;	# break after (LB31), a soft hyphen's included (text() keeps it as an item)
	Bidi->LBJL =>
		if(cb == Bidi->LBJL || cb == Bidi->LBJV || cb == Bidi->LBH2 || cb == Bidi->LBH3)
			return 0;
	Bidi->LBJV or Bidi->LBH2 =>
		if(cb == Bidi->LBJV || cb == Bidi->LBJT)
			return 0;
	Bidi->LBJT or Bidi->LBH3 =>
		if(cb == Bidi->LBJT)
			return 0;
	}
	return lbideo(ca) || lbideo(cb);
}

# an SVG viewBox attribute's four numbers, or nil
viewbox(s: string): array of real
{
	if(s == nil)
		return nil;
	a := array[4] of real;
	k := 0;
	i := 0;
	while(k < 4) {
		while(i < len s && (s[i] == ' ' || s[i] == ',' || s[i] == '\t' || s[i] == '\n'))
			i++;
		if(i >= len s)
			return nil;
		st := i;
		while(i < len s && (s[i] >= '0' && s[i] <= '9' || s[i] == '.' || s[i] == '-' || s[i] == '+' || s[i] == 'e' || s[i] == 'E'))
			i++;
		if(i == st)
			return nil;
		a[k++] = real s[st:i];
	}
	return a;
}

# the character the break rules see before s[i]: a combining mark
# takes its base's class (LB9), so look back past them (not a joiner:
# nothing breaks after one, LB8a)
lbbase(s: string, i, st0: int): int
{
	if(bidi == nil)
		return i;
	while(i > st0 && bidi->lbclass(s[i]) == Bidi->LBCM)
		i--;
	return i;
}

# the classes a line breaks beside: ideographs, emoji, Hangul (CJ as
# in line-break: normal)
lbideo(cl: int): int
{
	case cl {
	Bidi->LBID or Bidi->LBCJ or Bidi->LBEB or Bidi->LBEM or Bidi->LBH2 or Bidi->LBH3 or
	Bidi->LBJL or Bidi->LBJV or Bidi->LBJT =>
		return 1;
	}
	return 0;
}

isideo(c: int): int
{
	return (c >= 16r2E80 && c <= 16r9FFF) || (c >= 16rAC00 && c <= 16rD7AF) ||
		(c >= 16rF900 && c <= 16rFAFF) || (c >= 16rFF00 && c <= 16rFFEF) || c >= 16r20000;
}

# text-transform (Text 3 §2.1): Unicode case mapping, with the content
# language's tailoring; capitalize takes the first letter of each word
# (after white space or punctuation) to title case; full-width maps
# ASCII to the full-width forms
transform(s: string, t: int, first: int, lang: string): string
{
	case t {
	Style->TTupper =>
		if(bidi != nil)
			return bidi->toupper(s, lang);
		for(i := 0; i < len s; i++)
			if(s[i] >= 'a' && s[i] <= 'z')
				s[i] -= 32;
	Style->TTlower =>
		if(bidi != nil)
			return bidi->tolower(s, lang);
		for(i := 0; i < len s; i++)
			if(s[i] >= 'A' && s[i] <= 'Z')
				s[i] += 32;
	Style->TTcap =>
		at := first;
		r := "";
		for(i := 0; i < len s; i++) {
			c := s[i];
			if(at && bidi != nil && !isspace(c) && !bidi->punct(c))
				r += bidi->totitle(c, lang);
			else if(at && c >= 'a' && c <= 'z')
				r[len r] = c - 32;
			else
				r[len r] = c;
			at = isspace(c) || bidi != nil && bidi->punct(c) || c == '-';
		}
		return r;
	Style->TTfull =>
		# spaces are mapped by text() once collapsed
		for(i := 0; i < len s; i++)
			if(s[i] >= '!' && s[i] <= '~')
				s[i] += 16rFF01 - '!';
	}
	return s;
}

# the content language of node n: the nearest lang attribute, lower-cased
langof(n: int): string
{
	if(curdoc == nil)
		return nil;
	for(p := n; p != 0; p = curdoc.nodes[p].parent) {
		l := curdoc.attr(p, "lang");
		if(l == nil)
			l = curdoc.attr(p, "xml:lang");
		if(l != nil)
			return lower(l);
	}
	return nil;
}

# East Asian Width F, W or H (not A), and not Hangul: the characters a
# segment break between is removed (Text 3 §4.1.2)
eaw(c: int): int
{
	if(c >= 16r1100 && c <= 16r115F || c >= 16r3130 && c <= 16r318F || c >= 16rAC00 && c <= 16rD7AF)
		return 0;	# Hangul
	return c >= 16r2E80 && c <= 16r303E || c >= 16r3041 && c <= 16r33FF || c >= 16r3400 && c <= 16r4DBF ||
		c >= 16r4E00 && c <= 16r9FFF || c >= 16rA000 && c <= 16rA4CF || c >= 16rF900 && c <= 16rFAFF ||
		c >= 16rFE30 && c <= 16rFE4F || c >= 16rFF00 && c <= 16rFF60 || c >= 16rFF61 && c <= 16rFF9F ||
		c >= 16rFFE0 && c <= 16rFFEE || c >= 16r1F300 && c <= 16r1F64F || c >= 16r1F900 && c <= 16r1F9FF ||
		c >= 16r20000 && c <= 16r3FFFD;
}

# Collapsible segment breaks that are removed go now, with the white
# space collapsed about them, so that the text either side is one run
# to the word splitter (it rounds per word: segment-break-
# transformation-punctuation-001).  The rest become spaces later.
segbreaks(s: string, keepnl, cj: int): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' && !keepnl)
			break;
	if(i == len s)
		return s;
	r := "";
	i = 0;
	while(i < len s) {
		c := s[i];
		if(!isspace(c) || c == '\n' && keepnl) {
			r[len r] = c;
			i++;
			continue;
		}
		i0 := i;
		nl := 0;
		while(i < len s && isspace(s[i]) && !(s[i] == '\n' && keepnl)) {
			if(s[i] == '\n')
				nl = 1;
			i++;
		}
		if(nl && i0 > 0 && i < len s) {
			# removed or a space by the characters about it, default-
			# ignorable ones aside (Text 4 §4.3.3, the rules the UA's)
			p := i0 - 1;
			while(p > 0 && ignorable(s[p]))
				p--;
			q := i;
			while(q < len s - 1 && ignorable(s[q]))
				q++;
			if(removable(s[p], s[q], cj))
				continue;
		}
		r += s[i0:i];
	}
	return r;
}

# Is the segment break between a and b removed?  Beside a zero width
# space; between East Asian wide characters; and in Chinese or Japanese
# text beside East Asian punctuation, a symbol or the ideographic space
# (segment-break-transformation-removable-1, -punctuation-001..003)
removable(a, b, cj: int): int
{
	if(a == 16r200B || b == 16r200B)
		return 1;
	if(eaw(a) && eaw(b))
		return 1;
	return cj && (cjkpunct(a) || cjkpunct(b));
}

# East Asian punctuation and symbols of width F, W or H
cjkpunct(c: int): int
{
	if(c >= 16r3005 && c <= 16r3007)
		return 0;	# 々 〆 〇: letters
	return c >= 16r3000 && c <= 16r303F || c == 16r30FB || c >= 16rFE30 && c <= 16rFE6B ||
		c >= 16rFF01 && c <= 16rFF0F || c >= 16rFF1A && c <= 16rFF20 || c >= 16rFF3B && c <= 16rFF40 ||
		c >= 16rFF5B && c <= 16rFF65 || c >= 16rFFE0 && c <= 16rFFEE;
}

# default-ignorable: variation selectors, joiners, marks of direction,
# the soft hyphen (segment-break-transformation-ignorable-1)
ignorable(c: int): int
{
	return c == 16rAD || c == 16r34F || c == 16r180E || c >= 16r200C && c <= 16r200F ||
		c >= 16r2060 && c <= 16r206F || c >= 16rFE00 && c <= 16rFE0F || c == 16rFEFF;
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
	if(st.fontsize <= 0.0) {
		# font-size: 0 shows nothing, but a preserved newline still ends
		# the line, and a preserved tab is as wide as a tab-size length
		ws0 := st.whitespace;
		fc0 := face(st);
		for(k0 := 0; k0 < len b.text; k0++) {
			c0 := b.text[k0];
			if(c0 == '\n' && ws0 != Style->Wnormal && ws0 != Style->Wnowrap) {
				emit(f, ref Item(Ibreak, nil, 0.0, b, fc0, 0, 0, 0, 0, 0, 0.0, 0));
				f.space = 1;
			} else if(c0 == '\t' && ws0 != Style->Wnormal && ws0 != Style->Wnowrap && ws0 != Style->Wpreline && st.tabsize < 0.0) {
				emit(f, ref Item(Ispace, "\t", -st.tabsize, b, fc0, ws0 == Style->Wpre, f.deco, f.decocolor, 0, 0, 0.0, 0));
				f.space = 0;
			}
		}
		# and its words, though they show nothing, are content: a line
		# box with a baseline (inline-block-baseline-016)
		for(k1 := 0; k1 < len b.text; k1++)
			if(!isspace(b.text[k1])) {
				emit(f, ref Item(Iword, "", 0.0, b, fc0, 1, f.deco, f.decocolor, 0, 0, 0.0, 0));
				f.space = 0;
				break;
			}
		return;
	}
	lbmode = st.lbmode;
	lbcjk = cjklang(langof(b.node));
	lbkeepall = st.keepall;
	fc := face(st);
	s := b.text;
	if(st.transform != Style->TTnone)
		s = transform(s, st.transform, f.space, langof(b.node));
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
	if(collapsesp)
		s = segbreaks(s, keepnl, cjklang(langof(b.node)));
	i := 0;
	while(i < len s) {
		c := s[i];
		if(c == '\n' && keepnl) {
			emit(f, ref Item(Ibreak, nil, 0.0, b, fc, 0, 0, 0, 0, 0, 0.0, 0));
			f.space = 1;
			i++;
			continue;
		}
		if(isspace(c) && collapsesp) {
			i0 := i;
			nl := 0;
			while(i < len s && isspace(s[i]) && !(s[i] == '\n' && keepnl)) {
				if(s[i] == '\n')
					nl = 1;
				i++;
			}
			if(f.space && !nowrap) {
				# collapsed into a space before it: a break opportunity is
				# decided on the text before collapsing (Text 3 §4.1.1), so
				# that space may break if this one could
				for(pl := f.items; pl != nil; pl = tl pl) {
					if((hd pl).kind == Iopen || (hd pl).kind == Iclose)
						continue;
					if((hd pl).kind == Ispace)
						(hd pl).nowrap = 0;
					break;
				}
			}
			if(!f.space) {
				if(st.transform == Style->TTfull)	# full-width: the space that is left is an ideographic one
					emit(f, ref Item(Ispace, "　", fc.width("　") + st.wordspacing + ls, b, fc, nowrap, f.deco, f.decocolor, 0, 0, 0.0, 0));
				else
					emit(f, ref Item(Ispace, " ", fc.space + st.wordspacing + ls, b, fc, nowrap, f.deco, f.decocolor, 0, 0, 0.0, 0));
				f.space = 1;
			}
			continue;
		}
		if(c == ' ' && st.transform == Style->TTfull)
			c = '　';
		if(c == ' ' || c == '\t' || hangsp(c)) {
			# preserved spaces: each is a break opportunity (unless nowrap)
			w := fc.space + st.wordspacing + ls;
			t := " ";
			if(c == '\t') {
				w = fc.space * st.tabsize;
				if(st.tabsize < 0.0)
					w = -st.tabsize;	# a length
				t = "\t";
			} else if(hangsp(c)) {
				# an ideographic space, or another space separator: not
				# collapsible, it keeps its width at a line's end, where
				# it hangs (Text 3 §4.1.3; trailing-ogham-001)
				t = "";
				t[0] = c;
				w = fc.width(t);
			}
			emit(f, ref Item(Ispace, t, w, b, fc, nowrap, f.deco, f.decocolor, 0, 0, 0.0, 0));
			f.space = 0;
			i++;
			continue;
		}
		if(c == 16r200B) {
			# a zero-width space: a break opportunity that shows nothing
			emit(f, ref Item(Ispace, "", 0.0, b, fc, nowrap, f.deco, f.decocolor, 0, 0, 0.0, 0));
			f.space = 0;
			i++;
			continue;
		}
		# a word: up to the next space or break opportunity
		st0 := i;
		while(i < len s && !isspace(s[i]) && s[i] != 16r200B && !hangsp(s[i])) {
			if(i > st0 && (s[i-1] != 16rAD || st.hyphens != 0 && !joinedacross(s, i, st0)) && lbbreak(s[lbbase(s, i-1, st0)], s[i]))
				break;	# (a soft hyphen is nothing under hyphens: none, or between letters that join)
			i++;
			if(s[i-1] == '-' && i < len s && !isspace(s[i]) && i - st0 > 2)
				break;	# break after a hyphen inside a word
		}
		if(i == st0) {
			i++;	# a control character no case above takes (form feed): dropped
			continue;
		}
		word := noshy(s[st0:i]);	# soft hyphens show nothing unless a line ends there
		if(word == "") {
			if(st.hyphens == 0)
				continue;
			# nothing but soft hyphens: a break opportunity that shows
			# nothing and, unlike a zero-width space, does not come
			# between the letters around it for shaping
			emit(f, ref Item(Ispace, "\u00AD", 0.0, b, fc, nowrap, f.deco, f.decocolor, 0, 0, 0.0, 0));
			f.space = 0;
			continue;
		}
		w := fc.width(word) + ls * real len word;
		if(st.breakall && !nowrap) {
			# break-all: letters break like ideographs, but punctuation
			# keeps its rules (Text 4 §5.2: no break before a full stop);
			# anywhere: every character
			lbbreakall = st.breakall == 1;
			k0 := 0;
			for(k := 1; k <= len word; k++)
				if(k == len word || st.breakall == 2 || lbbreak(word[k-1], word[k])) {
					ch := word[k0:k];
					emit(f, ref Item(Iword, ch, fc.width(ch) + ls * real len ch, b, fc, 0, f.deco, f.decocolor, 0, 0, 0.0, 0));
					k0 = k;
				}
			lbbreakall = 0;
		} else
			emit(f, ref Item(Iword, word, w, b, fc, nowrap, f.deco, f.decocolor, 0, 0, 0.0, 0));
		f.space = 0;
		if(s[i-1] == 16rAD && st.hyphens != 0)	# the soft hyphen it ended with: a break opportunity whose hyphen shows only at a line's end
			emit(f, ref Item(Ispace, "\u00AD", 0.0, b, fc, nowrap, f.deco, f.decocolor, 0, 0, 0.0, 0));
	}
}

# word-space-transform (Text 4 §8.3): a zero-width space (a <wbr> is
# one) becomes a space, or an ideographic one, unless it is first or
# last on its line, next to a forced break or the block's edges, the
# edges of inline boxes apart.
# The spacing after a character is that of the innermost box holding
# it and the next character (Text 4 §8.2): between boxes of different
# letter-spacing the common ancestor's applies (letter-spacing-
# nesting-001, -002); at a line's end it is trimmed, finish() taking
# it off the last fragment (-end-of-line-001, letter-spacing-200).
# Each text item carries its own box's spacing after its last
# character; this adjusts that and records what is left (tls).
lspass(items: list of ref Item)
{
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		if(it.kind != Iword && it.kind != Ispace || len it.text == 0)
			continue;
		own := it.box.st.letterspacing;
		it.tls = own;
		if(own == 0.0)
			continue;
		next: ref Item;
		for(nl := tl l; nl != nil && next == nil; nl = tl nl) {
			n := hd nl;
			case n.kind {
			Iword or Ispace =>
				if(len n.text > 0 || n.kind == Iword)
					next = n;
			Iatomic or Ibreak =>
				break;
			}
		}
		if(next == nil)
			continue;	# the paragraph's end: a line's end, trimmed there
		after := commonbox(it.box, next.box).st.letterspacing;
		it.w += after - own;
		it.tls = after;
	}
}

# text-autospace (Text 4 §8.3): an eighth of an em between an
# ideograph and a letter or numeral of another script beside it,
# as spacing after the first of the two, trimmed at a line's end like
# letter spacing (text-autospace-001).
autospacepass(items: list of ref Item)
{
	prev: ref Item;
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		case it.kind {
		Iword =>
			if(prev != nil && len it.text > 0 && prev.box.st.textautospace == 0 && it.box.st.textautospace == 0) {
				# the characters beside the join, past any combining marks (text-autospace-mixed-001)
				pa := len prev.text - 1;
				while(pa > 0 && bidi != nil && bidi->lbclass(prev.text[pa]) == Bidi->LBCM)
					pa--;
				pc := 0;
				while(pc < len it.text - 1 && bidi != nil && bidi->lbclass(it.text[pc]) == Bidi->LBCM)
					pc++;
				a := prev.text[pa];
				c := it.text[pc];
				if(isideograph(a) && isalnumeral(c) || isalnumeral(a) && isideograph(c)) {
					sp := prev.box.st.fontsize/8.0;
					prev.w += sp;
					prev.tls += sp;
				}
			}
			prev = it;
			if(len it.text == 0)
				prev = nil;
		Iopen or Iclose =>
			if(it.w != 0.0)
				prev = nil;
		* =>
			prev = nil;
		}
	}
}

# an ideograph as text-autospace sees it: Han, Hiragana, Katakana,
# their radicals and iteration marks; not punctuation
isideograph(c: int): int
{
	return c >= 16r3041 && c <= 16r30FF && c != 16r30FB || c == 16r3005 || c == 16r3007 || c == 16r303B ||
		c >= 16r31F0 && c <= 16r31FF || c >= 16r3400 && c <= 16r4DBF || c >= 16r4E00 && c <= 16r9FFF ||
		c >= 16rF900 && c <= 16rFAFF || c >= 16rFF66 && c <= 16rFF9F || c >= 16r2E80 && c <= 16r2FDF ||
		c >= 16r20000 && c <= 16r3FFFF;
}

# a letter or numeral of a non-ideographic script (Latin, Greek,
# Cyrillic, Arabic, Hebrew letters; decimal digits)
isalnumeral(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c >= 16rC0 && c <= 16r24F && c != 16rD7 && c != 16rF7 || c >= 16r370 && c <= 16r3FF ||
		c >= 16r400 && c <= 16r52F || c >= 16r5D0 && c <= 16r5EA || c >= 16r620 && c <= 16r64A ||
		c >= 16r660 && c <= 16r669 || c >= 16r6F0 && c <= 16r6F9;
}

# hanging-punctuation first and last (Text 3 §5.3): an opening mark
# that starts the block's content, with nothing but zero-width inline
# box edges before it, hangs before the first line's start edge; a
# closing mark that ends it hangs past the last line's end edge.  The
# marks go in items of their own, flagged, taking no room in the line
# (finish) or the intrinsic sizes.  force-end and allow-end are not
# done yet.
hangpass(items: list of ref Item): list of ref Item
{
	first: ref Item;	# the first text item, and the last
	last: ref Item;
	seen := 0;	# something that takes room came before the first text
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		case it.kind {
		Iword or Ispace =>
			if(it.kind == Ispace && (it.text == " " || it.text == "" || it.text == "\u00AD"))
				continue;	# (collapsible or zero-width: before the first text it is dropped anyway)
			if(!seen)
				first = it;
			seen = 1;
			last = it;
		Iatomic =>
			seen = 1;
			last = nil;
		Ibreak =>
			last = nil;
		}
	}
	# a mark hangs only at the box's very edge: a border or padding of
	# an inline box on that side comes between (the end side being the
	# left in right-to-left text)
	if(first != nil && edged(first.box, !first.box.st.dirrtl))
		first = nil;
	if(last != nil && edged(last.box, last.box.st.dirrtl))
		last = nil;
	fmark, lmark: ref Item;	# the marks split off, to go before first and after last
	if(first != nil && first.kind == Ispace && first.box.st.hangpunct & 1 && hangsep(first.text) && first.text[0] == 16r3000)
		first.hang = 1;	# an ideographic space hangs too (hanging-punctuation-first-002)
	if(first != nil && first.kind == Iword && first.box.st.hangpunct & 1 && hangopen(first.text[0])) {
		if(len first.text > 1) {
			fmark = ref *first;
			fmark.text = first.text[0:1];
			fmark.w = fmark.face.width(fmark.text) + fmark.box.st.letterspacing;
			first.text = first.text[1:];
			first.w = first.face.width(first.text) + first.box.st.letterspacing * real len first.text;
			fmark.hang = 1;
		} else
			first.hang = 1;
	}
	if(last != nil && last.kind == Iword && last.box.st.hangpunct & 2 && hangclose(last.text[len last.text - 1])) {
		n := len last.text;
		if(n > 1) {
			lmark = ref *last;
			lmark.text = last.text[n-1:];
			lmark.w = lmark.face.width(lmark.text) + lmark.box.st.letterspacing;
			last.text = last.text[0:n-1];
			last.w = last.face.width(last.text) + last.box.st.letterspacing * real (n - 1);
			lmark.hang = 2;
			lmark.nowrap = 1;
		} else {
			last.hang = 2;
			last.nowrap = 1;
		}
	}
	if(fmark == nil && lmark == nil)
		return items;
	r: list of ref Item;
	for(l = items; l != nil; l = tl l) {
		it := hd l;
		if(it == first && fmark != nil)
			r = fmark :: r;
		r = it :: r;
		if(it == last && lmark != nil)
			r = lmark :: r;
	}
	o: list of ref Item;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# does an inline box holding the text box b have a border or padding
# on its left (left 1) or right side?
edged(b: ref Box, left: int): int
{
	for(p := b.parent; p != nil && p.kind == Kinline; p = p.parent) {
		if(left && p.bl + p.pl > 0 || !left && p.br + p.pr > 0)
			return 1;
	}
	return 0;
}

# an opening bracket or quote (Ps, Pi, the ASCII quotes), or the
# ideographic space, which may hang at a line's start
hangopen(c: int): int
{
	case c {
	'(' or '[' or '{' or 16r2018 or 16r201C or 16r00AB or 16r2039 or 16r3008 or 16r300A or 16r300C or 16r300E or
	16r3010 or 16r3014 or 16r3016 or 16r3018 or 16r301A or 16rFF08 or 16rFF3B or 16rFF5B or 16rFF5F or 16rFF62 or
	'\'' or '"' or 16r3000 =>
		return 1;
	}
	return 0;
}

# a closing bracket or quote (Pe, Pf, the ASCII quotes)
hangclose(c: int): int
{
	case c {
	')' or ']' or '}' or 16r2019 or 16r201D or 16r00BB or 16r203A or 16r3009 or 16r300B or 16r300D or 16r300F or
	16r3011 or 16r3015 or 16r3017 or 16r3019 or 16r301B or 16rFF09 or 16rFF3D or 16rFF5D or 16rFF60 or 16rFF63 or
	'\'' or '"' =>
		return 1;
	}
	return 0;
}

# the nearest box holding both a and b
commonbox(a, b: ref Box): ref Box
{
	for(p := a; p != nil; p = p.parent)
		for(q := b; q != nil; q = q.parent)
			if(p == q)
				return p;
	return a;
}

wstpass(items: list of ref Item)
{
	prev: ref Item;	# content before it on the line
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		case it.kind {
		Iopen or Iclose or Ifloat or Iabs =>
			continue;
		Ibreak =>
			prev = nil;
			continue;
		}
		if(it.kind == Ispace && it.text == "" && it.box.st.wst != 0 && prev != nil) {
			after := 0;
			done := 0;
			for(m := tl l; m != nil && !done; m = tl m)
				case (hd m).kind {
				Iopen or Iclose or Ifloat or Iabs =>
					;
				Ibreak =>
					done = 1;
				* =>
					after = 1;
					done = 1;
				}
			if(after) {
				if(it.box.st.wst == 1) {
					it.text = " ";
					it.w = it.face.space + it.box.st.wordspacing;
				} else {
					it.text = "　";
					it.w = it.face.width("　");
				}
			}
		}
		prev = it;
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
	below:	list of ref Abs;	# block-level absolutes met mid-line: their static position is under it
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

# A tall atomic box reaches floats that the line's strut does not: the
# line keeps clear of them for its whole height (CSS 2.2 §9.5), so it
# narrows to the band at that height, what is on it moving right past a
# float on the left.
tallband(f: ref Ifc, ln: ref Ln, h: int)
{
	if(f.fc == nil || h <= f.strut)
		return;
	cx := f.ox + f.b.bl + f.b.pl;
	ly := f.oy + f.y;
	(lx, rx) := band(f.fc, ly, ly + h, cx, cx + f.cw);
	if(rx - cx < ln.avail)
		ln.avail = rx - cx;
	if(lx - cx > ln.left) {
		shiftline(ln, lx - cx - ln.left);
		ln.left = lx - cx;
	}
}

# move a line's content right by d: its fragments and the inline boxes open on it
shiftline(ln: ref Ln, d: int)
{
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

# text-wrap: balance (Text 4 §6.3): the lines are broken at a width
# cut back as far as it can be without one more line, so that they
# come out about equal; each run of lines between forced breaks is
# balanced on its own.  The cut is found by bisection, the block laid
# out again each time: what a trial lays out (floats, pending
# absolutes) is put back before the next, and the lines are still
# aligned in their full width.
balancing: int;			# a block is being balanced
balancecuts: array of int;	# the cut per forced-break group, nil when none applies
balancegroup: int;		# the group of the line being laid
balancecount: array of int;	# lines laid per group, nil when not counting
Maxgroups: con 64;		# forced-break groups balanced at most

layinline(l: ref L, b: ref Box, cw, ch: int, fc: ref Fctx, ox, oy: int): int
{
	if(balancing) {
		# a block inside the one being balanced (an inline-block's):
		# laid out plainly, its lines not counted
		(ocuts, ogroup, ocount) := (balancecuts, balancegroup, balancecount);
		balancecuts = nil;
		balancecount = nil;
		h := layinline1(l, b, cw, ch, fc, ox, oy);
		(balancecuts, balancegroup, balancecount) = (ocuts, ogroup, ocount);
		return h;
	}
	if(b.st.textwrap != 1 || cw <= 0)
		return layinline1(l, b, cw, ch, fc, ox, oy);
	balancing = 1;
	(fleft, fright) := (fc.left, fc.right);
	pending := l.pending;
	balancecuts = nil;
	balancecount = array[Maxgroups] of {* => 0};
	balancegroup = 0;
	layinline1(l, b, cw, ch, fc, ox, oy);
	want := balancecount;
	ngroups := balancegroup + 1;
	if(ngroups > Maxgroups)
		ngroups = Maxgroups;
	cuts := array[ngroups] of {* => 0};
	for(g := 0; g < ngroups; g++) {
		if(want[g] < 2)
			continue;
		lo := 0;
		hi := cw;
		while(hi - lo > 1) {
			mid := (lo + hi)/2;
			cuts[g] = mid;
			balancecuts = cuts;
			balancecount = array[Maxgroups] of {* => 0};
			balancegroup = 0;
			(fc.left, fc.right) = (fleft, fright);
			l.pending = pending;
			layinline1(l, b, cw, ch, fc, ox, oy);
			if(balancecount[g] == want[g])
				lo = mid;
			else
				hi = mid;
		}
		cuts[g] = lo;
	}
	balancecuts = cuts;
	balancecount = nil;
	balancegroup = 0;
	(fc.left, fc.right) = (fleft, fright);
	l.pending = pending;
	h := layinline1(l, b, cw, ch, fc, ox, oy);
	balancing = 0;
	balancecuts = nil;
	return h;
}

# the width a line may fill before it breaks: less the balancing cut
cutavail(ln: ref Ln): real
{
	if(balancecuts != nil && balancegroup < len balancecuts)
		return real (ln.avail - balancecuts[balancegroup]);
	return real ln.avail;
}

layinline1(l: ref L, b: ref Box, cw, ch: int, fc: ref Fctx, ox, oy: int): int
{
	items := flatten(b);
	wstpass(items);
	lspass(items);
	items = hangpass(items);
	autospacepass(items);
	st := b.st;
	lines: list of ref Line;
	f := ref Ifc(l, b, cw, fc, ox, oy, b.bt + b.pt, ir(lineheight(st, face(st))), ch);
	x0 := b.bl + b.pl;
	para := 0;
	joinruns(items);
	(items, para) = bidiitems(b, items);
	ln := ref Ln(para, nil, 0.0, cw, 0, 0, nil, real res(st.indent, cw), nil, nil);
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
			if(it.w > 0.0 || it.box.bl + it.box.pl > 0)
				ln.content = 1;	# margin, border or padding: not a phantom line (CSS 2.2 §9.4.2), even with a negative margin taking the width back (margin-right-114)
		Iclose =>
			ln.x += it.w;
			if(it.w > 0.0 || it.box.br + it.box.pr > 0)
				ln.content = 1;
			fr := span(ln, it.box, 1);
			fr.level = it.level;
			ln.frags = fr :: ln.frags;
			opened = removebox(opened, it.box);
		Ispace =>
			if(!ln.content && it.text == " " && collapsible(it.box.st))
				continue;
			w := tabw(ln, it);
			if(it.box.st.whitespace == Style->Wbreakspaces && !it.nowrap && ln.content && ln.x + w > cutavail(ln) + 0.5) {
				# break-spaces: a space never hangs, and the opportunity
				# is after it, so one that does not fit wraps, taking the
				# word before it along when something it could break
				# from precedes that word (Text 3 §4.1.3, §5.4.2)
				word: ref Frag;
				wrap := 1;
				prev := ln.frags;
				while(prev != nil && (hd prev).kind == Fspan)
					prev = tl prev;
				if(it.box.st.breakall != 2 && prev != nil && (hd prev).kind == Ftext && !isblankrun((hd prev).text) && !hangsep((hd prev).text)) {
					# after a word: that goes too, or nothing does when
					# the word starts the line, unless overflow-wrap
					# lets the space break from it (line-break: anywhere
					# breaks before the space itself; break-spaces-
					# before-first-char-002, -012)
					wrap = it.box.st.anywhere != 0;
					for(fl := tl prev; fl != nil; fl = tl fl)
						if((hd fl).kind == Ftext) {
							word = hd prev;
							wrap = 1;
							break;
						}
				}
				if(wrap) {
					if(word != nil) {
						ln.frags = removefrag(ln.frags, word);
						ln.x -= real word.w;
					}
					lines = endline(f, ln, x0, first, 0) :: lines;
					first = 0;
					ln = newline(f, ln, opened);
					if(word != nil) {
						word.x = ir(ln.x);
						ln.frags = word :: ln.frags;
						ln.x += real word.w;
						ln.content = 1;
					}
					w = tabw(ln, it);
				}
			}
			if(it.text == "" && ln.content && !it.nowrap && ln.x > cutavail(ln) + 0.5) {
				# a zero width space after preserved spaces that
				# overflow: the line breaks here, and they hang at
				# its end (letter-spacing-201)
				lines = endline(f, ln, x0, first, 0) :: lines;
				first = 0;
				ln = newline(f, ln, opened);
			}
			fr := textfrag(ln, it);
			fr.w = ir(w);
			ln.frags = fr :: ln.frags;
			ln.x += w;
			if(it.hang == 1)
				ln.x -= w;	# a hanging mark takes no room (finish moves it before the start edge)
			if(!collapsible(it.box.st) || hangsep(it.text))
				ln.content = 1;	# preserved white space is content; so is an ideographic space, which hangs but is never removed (trailing-ideographic-space-023)
		Iword =>
			if(it.box.kind == Kmarker && !it.box.st.listinside) {
				fr := textfrag(ln, it);
				fr.x = ir(ln.x - it.w);
				ln.frags = fr :: ln.frags;
				ln.content = 1;
				continue;
			}
			if(it.hang != 2 && ln.content && ln.x + segwidth(il) > cutavail(ln) + 0.5 && !endhangs(ln, il) && (!it.nowrap || spacebefore(ln, it)) && canbreak(ln, it)) {
				hyphenate(ln);
				lines = endline(f, ln, x0, first, 0) :: lines;
				first = 0;
				ln = newline(f, ln, opened);
			}
			while(!ln.content && ln.x + it.w > real ln.avail + 0.01 && movedown(f, ln))
				;
			if(!ln.content && ln.x + it.w > real ln.avail && (it.box.st.anywhere || keptall(it)) && len it.text > 1) {
				# (keep-all is relaxed to normal breaking when the line
				# has no other opportunity, as browsers do: overflow-wrap-normal-keep-all-001)
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
			if(it.hang == 1)
				ln.x -= it.w;	# a hanging mark takes no room (finish moves it before the start edge)
			ln.content = 1;
		Iatomic =>
			k := it.box;
			layatomic(l, k, cw, f.ch);
			w := k.ml + k.w + k.mr;
			ah := k.mt + k.h + k.mb;
			tallband(f, ln, ah);
			if(ln.content && ln.x + real w > cutavail(ln) + 0.01 && atomicbreak(ln, k))  {
				lines = endline(f, ln, x0, first, 0) :: lines;
				first = 0;
				ln = newline(f, ln, opened);
				tallband(f, ln, ah);
			}
			while(!ln.content && ln.x + real w > real ln.avail + 0.01 && movedown(f, ln))
				tallband(f, ln, ah);
			fr := ref Frag(Fatomic, ir(ln.x) + k.ml, 0, k.w, k.h, 0, k, nil, nil, 0, 0, 0, 0, it.level, 0, 0);
			ln.frags = fr :: ln.frags;
			ln.x += real w;
			ln.content = 1;
		Ifloat =>
			tx := ln.x;
			if(ln.frags != nil && (hd ln.frags).kind == Ftext && (hd ln.frags).text == " " && collapsible((hd ln.frags).box.st))
				tx = real (hd ln.frags).x;	# a trailing space goes at the line's end: the float may have its room
			if(!ln.content || real floatwidth(it.box, cw, f.ch) <= real ln.avail - tx + 0.01) {
				# on this line: at its top, beside what is on it already
				# (CSS 2.2 §9.5.1 rules 4 and 7)
				oldleft := ln.left;
				oldx := ln.x;
				placefloat(l, it.box, fc, ox + x0, oy + f.y, cw, f.ch, ox, oy);
				edgesat(f, ln);
				if(ln.left > oldleft && !ln.content) {
					# a left float before any content: the line's start,
					# with its indent and open edges, moves right past it
					ln.x = oldx + real (ln.left - oldleft);
				} else if(ln.left > oldleft) {
					# a left float: the line's content moves right past it
					# (edgesat may have put ln.x at the float's edge already,
					# as for an empty line: floats-placement-vertical-001a)
					d := ln.left - oldleft;
					for(fl := ln.frags; fl != nil; fl = tl fl)
						(hd fl).x += d;
					ln.x = oldx + real d;
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
				mark := ref Frag(Ftext, ir(ln.x), 0, 0, 0, 0, it.box, "", face(it.box.st), 0, 0, 0, 0, it.level, 0, 0);
				ln.frags = mark :: ln.frags;
				l.pending = ref Abs(it.box, cbof(l, it.box), b, x0 + ir(ln.x), f.y, mark, b.st.dirrtl, nil, icbof(it.box), 0) :: l.pending;
			} else {
				# a block-level one's is where a block would go: the
				# start of this line, or under it once content is on it
				a := ref Abs(it.box, cbof(l, it.box), b, staticx(b), f.y, nil, b.st.dirrtl, nil, icbof(it.box), 0);
				if(ln.content)
					ln.below = a :: ln.below;
				l.pending = a :: l.pending;
			}
		Ibreak =>
			ln.content = 1;
			lines = endline(f, ln, x0, first, 1) :: lines;
			first = 0;
			ln = newline(f, ln, opened);
			ln.content = 0;
			balancegroup++;
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
	if(balancecount != nil && balancegroup < len balancecount)
		balancecount[balancegroup]++;
	line := finish(f.l, f.b, ln, f.y, x0, first, forced);
	f.y += line.h;
	for(bl := ln.below; bl != nil; bl = tl bl)
		(hd bl).sy = f.y;
	placepending(f, ln);
	return line;
}

collapsible(st: ref St): int
{
	ws := st.whitespace;
	return ws == Style->Wnormal || ws == Style->Wnowrap || ws == Style->Wpreline;
}

# hanging-punctuation: allow-end, force-end.  Does the word at the
# head of il fit the line once the stop or comma ending it hangs past
# the end edge?  Only the one mark hangs, and only when it is what
# overflows (hanging-punctuation-allow-end-basic).
endhangs(ln: ref Ln, il: list of ref Item): int
{
	it := hd il;
	if(!(it.box.st.hangpunct & 12) || len it.text < 2 || it.face == nil)
		return 0;
	c := it.text[len it.text - 1];
	if(!hangstop(c))
		return 0;
	# the line must be able to break after it: not into a word or an
	# atomic box glued to it (a nowrap span: hanging-punctuation-allow-end)
	for(nl := tl il; nl != nil; nl = tl nl) {
		x := hd nl;
		case x.kind {
		Iopen or Iclose or Ifloat or Iabs =>
			continue;
		Iword =>
			if(!wordgap(it.box, it.text, x, 0))
				return 0;
		Iatomic =>
			if(nowrapbetween(it.box, x.box))
				return 0;
		}
		break;
	}
	hw := it.face.width(it.text[len it.text - 1:]);
	return ln.x + segwidth(il) - hw <= cutavail(ln) + 0.5;
}

# the stops and commas that may hang at a line's end (Text 4 §8.2)
hangstop(c: int): int
{
	case c {
	',' or '.' or 16r60C or 16r6D4 or 16r3001 or 16r3002 or 16rFF0C or 16rFF0E or 16rFE50 or 16rFE51 or 16rFE52 or 16rFF61 or 16rFF64 =>
		return 1;
	}
	return 0;
}

# May the line break before the word it?  Not between two words with
# nothing between them (a float or an absolute does not come between:
# white-space-processing-048), unless the characters at the join give
# an opportunity (UAX #14), and never into nowrap text.
canbreak(ln: ref Ln, it: ref Item): int
{
	for(fl := ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan || f.kind == Ftext && f.box != nil && f.box.kind != Ktext)
			continue;	# inline box edges, the marks of absolutes, an outside marker
		if(f.kind == Fatomic) {
			# after an atomic inline, as after a contingent break (UAX
			# #14 LB20; line-breaking-atomic-002, -009), unless what
			# follows attaches to it or glues: a mark, a joiner, a word
			# joiner, a glue character other than a no-break space
			if(len it.text == 0 || it.text[0] == 16rA0 || bidi == nil)
				return 1;
			case bidi->lbclass(it.text[0]) {
			Bidi->LBCM or Bidi->LBZWJ or Bidi->LBWJ or Bidi->LBGL =>
				return 0;
			}
			return 1;
		}
		if(f.kind == Ftext && f.text == "\u00AD")	# a soft hyphen: if its hyphen has room, or nothing else on the line could break (shy-styling-001)
			return f.face == nil || ln.x + f.face.width(hyphenchar(f)) <= real ln.avail + 0.5 || !earlierbreak(ln, f);
		if(f.kind != Ftext || f.text == "" || f.text == " " || isblankrun(f.text) || hangsep(f.text))
			return 1;	# a space, a zero-width one
		return wordgap(f.box, f.text, it, 0);
	}
	return 1;
}

# Do the letters either side of the soft hyphen at i-1 join (Arabic
# and the like)?  Then it stays inside the word, for shaping's sake,
# and no line breaks there (hyphens-shaping-001).
joinedacross(s: string, i, st0: int): int
{
	if(bidi == nil || i >= len s)
		return 0;
	p := i - 2;
	while(p >= st0 && bidi->joining(s[p]) == Bidi->JT)
		p--;
	if(p < st0)
		return 0;
	jp := bidi->joining(s[p]);
	jn := bidi->joining(s[i]);
	return jp != Bidi->JU && jp != Bidi->JT && jn != Bidi->JU && jn != Bidi->JT;
}

# A soft hyphen at the end of a line shows the hyphenate character
# (Text 4 §5.4; hyphens-manual-011).
hyphenate(ln: ref Ln)
{
	for(fl := ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan)
			continue;
		if(f.kind == Ftext && f.text == "\u00AD" && f.face != nil) {
			f.text = hyphenchar(f);
			f.w = ir(f.face.width(f.text));
			ln.x += real f.w;
		}
		return;
	}
}

# the hyphenate character as drawn at the soft hyphen fragment f:
# the hyphen (U+2010) only where the font has it, else hyphen-minus
hyphenchar(f: ref Frag): string
{
	t := f.box.st.hyphenchar;
	if(t == "\u2010" && f.face != nil && !f.face.has(16r2010))
		t = "-";
	return t;
}

# is there a break opportunity on the line already (a space, an
# ideographic one, a zero-width one), before the fragment g?
earlierbreak(ln: ref Ln, g: ref Frag): int
{
	for(fl := ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f == g || f.kind != Ftext)
			continue;
		if(f.text == " " || f.text == "" || hangsep(f.text) || f.text == "\u00AD")
			return 1;
	}
	return 0;
}

# Is the item preceded on the line by a collapsible space whose boundary
# with it is outside nowrap text?  A word of a nowrap box may then start
# a line after it, as the opportunity is the space's (white-space-007).
spacebefore(ln: ref Ln, it: ref Item): int
{
	for(fl := ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan || f.kind == Ftext && f.box != nil && f.box.kind != Ktext)
			continue;
		return f.kind == Ftext && (f.text == " " || hangsep(f.text)) && !nowrapbetween(f.box, it.box);
	}
	return 0;
}

# May the line break before an atomic inline?  It breaks like an
# ideograph: not after a glue character such as a no-break space, nor
# after an opening one (Text 3 §5.1, UAX #14).
atomicbreak(ln: ref Ln, k: ref Box): int
{
	for(fl := ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan || f.kind == Ftext && f.box != nil && f.box.kind != Ktext)
			continue;
		if(f.kind != Ftext || f.text == "" || f.text == "\u00AD" || f.text == " " || isblankrun(f.text) || hangsep(f.text))
			return 1;
		if(nowrapbetween(f.box, k))
			return 0;
		c := f.text[len f.text - 1];
		if(bidi != nil && bidi->lbclass(c) == Bidi->LBCM)
			return 0;	# a combining mark holds what follows to its base (line-breaking-atomic-016)
		if(c == 16rA0)
			return 1;	# a no-break space beside an atomic inline breaks, as browsers have it (line-breaking-atomic-001)
		if(bidi == nil)
			return 1;
		case bidi->lbclass(c) {
		Bidi->LBGL or Bidi->LBWJ or Bidi->LBZWJ or Bidi->LBOP or Bidi->LBBB or Bidi->LBQU =>
			return 0;	# glue, joiners, openers and quotes hold it (UAX #14 LB12, LB14, LB19)
		}
		return 1;
	}
	return 1;
}

# Is the boundary between the boxes a and b inside nowrap or pre text?
# The white-space of their nearest common ancestor decides (Text 3
# §4.1.1), not either box's own.
nowrapbetween(a, b: ref Box): int
{
	for(p := a; p != nil; p = p.parent)
		for(q := b; q != nil; q = q.parent)
			if(p == q)
				return p.st.whitespace == Style->Wnowrap || p.st.whitespace == Style->Wpre;
	return 0;
}

# May a line break between the word ptext of the text box pbox and the
# word it, with nothing between them?  Words of one text were split
# where it may (text()); between texts the characters at the join
# decide (UAX #14), unless either text is nowrap.  overflow-wrap breaks
# anywhere when a sequence fails to fit, which is when a line asks
# (min 0); for the min-content size (min 1) only overflow-wrap:
# anywhere and word-break: break-word count (Text 4 §5.5).
wordgap(pbox: ref Box, ptext: string, it: ref Item, min: int): int
{
	if(pbox == it.box)
		return 1;
	if(len ptext == 0 || len it.text == 0)
		return 1;
	if(nowrapbetween(pbox, it.box))
		return 0;
	if(it.box.st.breakall == 2 || pbox.st.breakall == 2)
		return 1;	# line-break: anywhere
	if(it.box.st.anywhere == 2 || pbox.st.anywhere == 2 || !min && (it.box.st.anywhere || pbox.st.anywhere))
		return 1;
	lbmode = it.box.st.lbmode;
	lbcjk = cjklang(langof(it.box.node));
	lbbreakall = it.box.st.breakall == 1 || pbox.st.breakall == 1;
	lbkeepall = it.box.st.keepall || pbox.st.keepall;
	r := lbbreak(ptext[len ptext - 1], it.text[0]);
	lbbreakall = 0;
	lbkeepall = 0;
	return r;
}

# a word kept whole by keep-all that normal breaking would split
keptall(it: ref Item): int
{
	if(!it.box.st.keepall || bidi == nil)
		return 0;
	for(i := 1; i < len it.text; i++)
		if(cjkletter(bidi->lbclass(it.text[i-1])) && cjkletter(bidi->lbclass(it.text[i])))
			return 1;
	return 0;
}

# a letter of Chinese, Japanese or Korean, by line-break class
cjkletter(c: int): int
{
	case c {
	Bidi->LBID or Bidi->LBCJ or Bidi->LBH2 or Bidi->LBH3 or Bidi->LBJL or Bidi->LBJV or Bidi->LBJT =>
		return 1;
	}
	return 0;
}

# is the language Chinese or Japanese? (the 〜 rule of Text 4 §5.3)
cjklang(l: string): int
{
	return len l >= 2 && (l[0:2] == "ja" || l[0:2] == "zh");
}

# The width of the unbreakable run of items starting at the word at the
# head of il: words with no opportunity between them, the edges of
# inline boxes among them (a float or an absolute takes no room).  It
# reaches to the farthest right edge: a negative margin at its end
# does not pull the glyphs before it back in.
segwidth(il: list of ref Item): real
{
	w := 0.0;
	pos := 0.0;
	trail := 0.0;	# the letter spacing after the segment's last character: trimmed if the line ends there
	tailneg := 0.0;	# negative inline box edges after the last word: they pull the segment's end back
	prev: ref Item;
	for(; il != nil; il = tl il) {
		x := hd il;
		case x.kind {
		Iword =>
			if(prev != nil && wordgap(prev.box, prev.text, x, 0))
				return segend(w, pos, trail, tailneg);
			pos += x.w;
			trail = x.tls;
			tailneg = 0.0;
			prev = x;
		Iopen or Iclose =>
			pos += x.w;
			if(x.w > 0.0)
				trail = 0.0;
			else
				tailneg += x.w;
		Ifloat or Iabs =>
			;
		* =>
			return segend(w, pos, trail, tailneg);
		}
		if(pos > w)
			w = pos;
	}
	return segend(w, pos, trail, tailneg);
}

# the width a segment needs: its furthest extent (a negative margin
# closing it does not pull a word back into the line: browsers fit the
# word before its box's end edge, firefox-bug-1881495), less the
# letter spacing after its last character
segend(w, pos, trail, nil: real): real
{
	if(pos >= w)
		return pos - trail;
	return w;
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
	ln := ref Ln(old.para, nil, 0.0, f.cw, 0, 0, nil, 0.0, nil, nil);
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

# is k inside b (b itself counts)?
inbox(k, b: ref Box): int
{
	for(; k != nil; k = k.parent)
		if(k == b)
			return 1;
	return 0;
}

removefrag(l: list of ref Frag, f: ref Frag): list of ref Frag
{
	r, o: list of ref Frag;
	for(; l != nil; l = tl l)
		if(hd l != f)
			r = hd l :: r;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# a space's width on the line: a tab's is to the next tab stop, a
# multiple of the tab size from the content edge (CSS Text 3 §4.1); a
# tab at a stop is a whole one
tabw(ln: ref Ln, it: ref Item): real
{
	w := it.w;
	if(it.text == "\t" && w > 0.0) {
		w -= math->fmod(ln.x, w);
		# too close to the next stop for a tab to show: the one after
		# (as browsers have it; tab-stop-threshold-002)
		if(it.face != nil && w < it.face.space/2.0)
			w += it.w;
	}
	return w;
}

textfrag(ln: ref Ln, it: ref Item): ref Frag
{
	return ref Frag(Ftext, ir(ln.x), 0, ir(it.w), 0, 0, it.box, it.text, it.face, 0, 0, it.deco, it.decocolor, it.level, ir(it.tls), it.hang);
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
	return ref Frag(Fspan, ir(x), 0, ir(ln.x) - ir(x), 0, 0, b, nil, nil, first, last, 0, 0, level, 0, 0);	# ends where the next content starts
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
		if(f.kind == Ftext && f.text == " " && collapsible(f.box.st) && hanging == nil) {
			ln.x -= real f.w;
			f.w = 0;
			continue;
		}
		if(f.kind == Ftext && isblankrun(f.text) && f.box.st.whitespace == Style->Wprewrap && !forced ||
		   f.kind == Ftext && hangsep(f.text) && f.box.st.whitespace != Style->Wbreakspaces ||
		   f.kind == Ftext && f.text == " " && collapsible(f.box.st)) {
			# so does an ideographic space (Text 3 §4.1.3, other space
			# separators), and a space among them, which is not at
			# the line's end and so is not removed (trailing-ideographic-space-002)
			ln.x -= real f.w;
			hanging = f :: hanging;
			continue;
		}
		break;
	}
	# the letter spacing after the line's last character is trimmed (Text 4 §8.2)
	for(fl = ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan || ishanging(f, hanging) || f.kind == Ftext && f.text == " " && f.w == 0)
			continue;
		if(f.kind == Ftext && f.tls > 0) {
			f.w -= f.tls;
			ln.x -= real f.tls;
			f.tls = 0;
		}
		break;
	}
	# an inline box closed over the dropped spaces ends with the content
	ex := ir(ln.x);
	for(fl = ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan && f.x + f.w > ex) {
			f.w = ex - f.x;
			if(f.w < 0) {
				f.x = ex;
				f.w = 0;
			}
		}
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
	line := ref Line(y, h, y + base, frags, nil);
	if(first)
		line.fl = firstlinest(b);
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
	# hanging punctuation: an opening mark at the first line's start
	# hangs before the start edge, the content moving back by its
	# width; a closing mark at the last line's end hangs past the end
	# edge, the line measured without it (Text 3 §5.3)
	hangfirst, hanglast: ref Frag;
	if(first)
		for(i = 0; i < len frags; i++) {
			f := frags[i];
			if(f.kind == Fspan)
				continue;
			if(f.kind == Ftext && f.hang == 1 && f.w > 0) {
				hangfirst = f;	# took no room on the line; moves before the start edge below
				if(!b.st.dirrtl)
					f.x -= f.w;
			}
			break;
		}
	if(forced)
		for(i = len frags - 1; i >= 0; i--) {
			f := frags[i];
			if(f.kind == Fspan || f.kind == Ftext && f.text == " " && f.w == 0)
				continue;
			if(f.kind == Ftext && f.hang == 2 && f.w > 0) {
				hanglast = f;
				ln.x -= real f.w;	# measured without it: it hangs past the end edge
			}
			break;
		}
	# horizontal alignment
	extra := real ln.avail - ln.x;
	align := b.st.align;
	if(forced) {
		# the last line: text-align-last's, or, under justify, start (Text 3 §7.2; text-align-last-center)
		if(b.st.alignlast != Style->Aauto)
			align = b.st.alignlast;
		else if(align == Style->Ajustify)
			align = Style->Astart;
	}
	if(align == Style->Ajustify && b.st.textjustify == 1)
		align = Style->Astart;	# text-justify: none (text-justify-none-001)
	off := 0.0;
	if(ln.para % 2 == 1 && align == Style->Aend)
		align = Style->Aleft;	# the end of a right-to-left line is its left
	case align {
	Style->Aright or Style->Aend =>
		off = extra;
		if(b.st.dirrtl)
			off -= ln.indent;	# the indent is at the start, the right
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
		if(nsp > 0 && extra > 0.0) {	# (a last line is here only when text-align-last says justify)
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
		off = extra - ln.indent;	# the start is the right; the indent is there
	else if(ln.para % 2 == 1 && align == Style->Ajustify)
		off = -real ln.indent;	# justified from the end edge; the indent, taken at the start, moves the content the other way
	if(off < 0.0 && !b.st.dirrtl)
		off = 0.0;	# too wide: the content overflows the end edge, the right in a left-to-right block, the left in a right-to-left one (hyphens-shaping-001)
	else if(b.st.dirrtl && extra < 0.0 && off > extra)
		off = extra;
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
	if(b.st.dirrtl) {
		# the hanging marks in a right-to-left line: the opening one
		# past the right edge, the closing one past the left, the rest
		# of the line keeping to the right edge
		# (the opening mark is already past the right edge: it took no
		# room, so the reorder put it after everything)
		if(hanglast != nil)
			for(i = 0; i < len frags; i++)
				frags[i].x -= hanglast.w;
	}
	if(hanging != nil) {
		# then past the line's end: the right in a left-to-right paragraph,
		# the left in a right-to-left one
		lo := 1 << 30;
		hi := -(1 << 30);
		for(i = 0; i < len frags; i++) {
			f := frags[i];
			if(f.kind == Fspan || ishanging(f, hanging) || f.kind == Ftext && f.w == 0)
				continue;	# a collapsed space among the hanging ones keeps its old place, which is not the line's end (trailing-ideographic-space-002)
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
			# the inline boxes it is in reach out to it: its background is theirs
			for(i = 0; i < len frags; i++) {
				sp := frags[i];
				if(sp.kind != Fspan || !inbox(f.box, sp.box))
					continue;
				if(f.x < sp.x) {
					sp.w += sp.x - f.x;
					sp.x = f.x;
				}
				if(f.x + f.w > sp.x + sp.w)
					sp.w = f.x + f.w - sp.x;
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
			if(prev != nil && len prev.text > 0 && len it.text > 0 && prev.face == it.face &&
			   (k := it.face.ligspan(prev.text, it.text)) > 0) {
				# a ligature across the edge: its characters move to
				# the first word, so one glyph can stand for them
				prev.text += it.text[0:k];
				it.text = it.text[k:];
				rewidth(prev);
				rewidth(it);
				if(it.text == "")
					continue;	# wholly taken: the word before is still the one to join to
			}
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
		Ispace =>
			if(it.text != "\u00AD")
				prev = nil;	# a soft hyphen is transparent to joining (hyphens-shaping-001)
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
layatomic(l: ref L, k: ref Box, cbw, cbh: int)
{
	edges(k, cbw);
	w := specw(k, k.st.width, cbw);
	if(w < 0) {
		if(k.kind == Kreplaced) {
			(rw, nil) := replacedsize(k, cbw, cbh);	# a percentage height transfers to the width
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
	layblock(l, k, cbw, cbh, nil, 0, 0);
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

# b is the box of an HTML element with this tag
istag(b: ref Box, tag: int): int
{
	return b.node != 0 && curdoc != nil && curdoc.nodes[b.node].tag == tag && curdoc.nodes[b.node].ns == Dom->HTML;
}

hasimage(st: ref St): int
{
	for(i := 0; i < len st.bg; i++)
		if(st.bg[i].img != nil)
			return 1;
	return 0;
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
	if(root.doc != nil)
		curdoc = root.doc;
	viewport = clip;
	scrolled = clip.min.sub(origin);
	oclip := dst.clipr;
	dst.clipr = clip;
	# the canvas takes the root's background, or else the body's
	# (Backgrounds 3 §2.11.2; not through paint containment)
	bg := root.st.bgcolor;
	bgbox := root;
	if(!visible(bg) && !hasimage(root.st) && !(root.st.contain & Style->CTpaint) && istag(root, Dom->Thtml)) {
		for(i := 0; i < len root.kids; i++)
			if(istag(root.kids[i], Dom->Tbody)) {
				if(!(root.kids[i].st.contain & Style->CTpaint)) {
					bgbox = root.kids[i];
					bg = bgbox.st.bgcolor;
				}
				break;
			}
	}
	dst.draw(clip, display.white, nil, (0, 0));
	if(visible(bg))
		dst.draw(clip, colorimg(bg), nil, (0, 0));
	if(bgbox.st.bg != nil) {
		# its images too, positioned as if on the root element whichever
		# box they came from (Backgrounds 3 §2.11.2), shown over the canvas
		r := Rect((origin.x + root.x, origin.y + root.y), (origin.x + root.x + root.w, origin.y + root.y + root.h));
		oncanvas = 1;
		for(i := len bgbox.st.bg - 1; i >= 0; i--)
			if(bgbox.st.bg[i].img != nil)
				paintbg(dst, root, r, bgbox.st.bg[i]);
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
	if(st.visibility == Style->Vvisible && rectok(clip)) {
		# its own background and borders within what clips it too
		# (an overflow-clipping ancestor, its clip property)
		oclip := dst.clipr;
		dst.clipr = intersect(oclip, clip);
		paintself(dst, b, r, canvasbg);
		dst.clipr = oclip;
	}
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
	b := l.box;
	cr := b.st.cliprect;
	if(cr != nil && (b.st.position == Style->Pabsolute || b.st.position == Style->Pfixed)) {
		# clip: rect(top, right, bottom, left): offsets from the border
		# box's top and left edges, auto being that edge (CSS 2.2 §11.1.2)
		x := l.o.x + b.x;
		y := l.o.y + b.y;
		r := Rect((x, y), (x + b.w, y + b.h));
		if(cr[0].kind != Style->Lauto)
			r.min.y = y + ir(cr[0].px);
		if(cr[1].kind != Style->Lauto)
			r.max.x = x + ir(cr[1].px);
		if(cr[2].kind != Style->Lauto)
			r.max.y = y + ir(cr[2].px);
		if(cr[3].kind != Style->Lauto)
			r.min.x = x + ir(cr[3].px);
		c = intersect(c, r);
	}
	return c;
}

# the intersection of two rectangles, empty (max at min) when they miss
intersect(a, b: Rect): Rect
{
	r := Rect((max(a.min.x, b.min.x), max(a.min.y, b.min.y)), (min(a.max.x, b.max.x), min(a.max.y, b.max.y)));
	if(r.max.x < r.min.x)
		r.max.x = r.min.x;
	if(r.max.y < r.min.y)
		r.max.y = r.min.y;
	return r;
}

innerclip(b: ref Box, r, clip: Rect): Rect
{
	st := b.st;
	if(b.clip)
		return intersect(clip, r);
	if(st.overflowx == Style->Ovisible && st.overflowy == Style->Ovisible)
		return clip;
	if(b.kind == Krow || isrowgroup(b) || iscolumn(b))
		return clip;	# overflow does not apply to rows, row groups and columns (CSS 2.2 §11.1.1; overflow-applies-to-001)
	if(istag(b, Dom->Thtml) || istag(b, Dom->Tbody) && b.parent != nil && istag(b.parent, Dom->Thtml) &&
	   b.parent.st.overflowx == Style->Ovisible && b.parent.st.overflowy == Style->Ovisible)
		return clip;	# the root's overflow, or the body's when the root's is visible, is the viewport's, not a clip of its own (Overflow 3 §3.3)
	pr := Rect((r.min.x + b.bl, r.min.y + b.bt), (r.max.x - b.br, r.max.y - b.bb));
	(c, nil) := clip.clip(pr);
	return c;
}

# a box that is a layer of its stacking context rather than flow content
islayer(k: ref Box): int
{
	return (ispositioned(k) || k.st.translated || zitem(k)) && k.kind != Ktext && k.kind != Kinline;
}

# a flex or grid item with a z-index: painted as if positioned, a
# stacking context of its own (Flexbox §4.3, Grid 2 §10;
# grid-z-axis-ordering-001)
zitem(k: ref Box): int
{
	return !k.st.zauto && k.parent != nil && (k.parent.kind == Kflex || k.parent.kind == Kgrid) && !k.inl && !isabs(k);
}

# a box that establishes a stacking context (CSS 2.2 §9.9.1, Position 3)
isctx(k: ref Box): int
{
	st := k.st;
	return k == painted || st.position == Style->Pfixed || st.opacity < 1.0 || st.translated ||
		ispositioned(k) && !st.zauto || zitem(k);
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
	if(textmask)
		return;	# only text goes into the mask
	if(b.tb != nil)
		r = tablerect(b, r);	# the table box: its captions lie outside its background and borders
	if(b == canvasbg)
		paintshadows(dst, b, r);	# the background went to the canvas; the shadow is still its own
	else if(b.kind == Krow || isrowgroup(b) || iscolumn(b))
		painttablepart(dst, b, r);
	else
		paintbackground(dst, b, r);
	if(b.tb != nil && b.tb.v != nil || b.st.collapse && b.kind == Kcell || b.kind == Krow || isrowgroup(b) || iscolumn(b))
		return;	# collapsed borders: the table paints them over its content; rows, row groups and columns have none in the separated model (§17.6.1)
	paintborders(dst, b, r);
}

paintcontent(dst: ref Image, b: ref Box, r, clip: Rect, canvasbg: ref Box)
{
	if(b.kind == Kreplaced) {
		if(b.st.visibility == Style->Vvisible)
			paintreplaced(dst, b, r);
		return;
	}
	if(hasitems(b)) {
		paintitems(dst, b, r.min, clip, canvasbg);
		return;
	}
	# CSS 2.2 Appendix E: the in-flow blocks' backgrounds and borders,
	# then the floats, then the inline content, each in tree order
	flowbgs(dst, b, r.min, clip, canvasbg);
	flowfloats(dst, b, r.min, clip, canvasbg);
	flowinline(dst, b, r.min, clip, canvasbg);
}

# a flex or grid container: its items paint as inline blocks do, each
# whole before the next, in order-modified document order (Flexbox
# §5.4, Grid 2 §10), in the inline content pass of the flow it is in
# (column-fill-reverse-definite-size-001)
hasitems(b: ref Box): int
{
	return (b.kind == Kflex || b.kind == Kgrid) && b.lines == nil;
}

paintitems(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(isabs(k) || islayer(k))
			continue;	# (a float is an item like any other: float does not apply)
		paintflow(dst, k, o, clip, canvasbg);
	}
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
	if(b.tb != nil)
		paintcolumns(dst, b, o);
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(!inflowblock(k))
			continue;
		r := kidrect(k, o);
		if(offscreen(k, r, clip))
			continue;
		if(k.st.visibility == Style->Vvisible)
			paintself(dst, k, r, canvasbg);
		if(k.kind == Kreplaced || hasitems(k))
			continue;
		inner := innerclip(k, r, clip);
		if(rectok(inner)) {
			oc := withclip(dst, inner);
			flowbgs(dst, k, r.min, inner, canvasbg);
			dst.clipr = oc;
		}
	}
	if(b.tb != nil && b.tb.v != nil && b.st.visibility == Style->Vvisible)
		paintcollapsed(dst, b, Rect(o, (o.x + b.w, o.y + b.h)));	# over the cells' backgrounds, under their content
}

# A table's columns' and column groups' backgrounds, over its own and
# under the rows' (CSS 2.2 §17.5.1), each on the box placecolumns gave it.
paintcolumns(dst: ref Image, b: ref Box, o: Point)
{
	for(i := 0; i < len b.kids; i++) {
		k := b.kids[i];
		if(!iscolumn(k))
			continue;
		if(k.st.visibility == Style->Vvisible && k.w > 0)
			paintbackground(dst, k, kidrect(k, o));
		for(j := 0; j < len k.kids; j++) {
			col := k.kids[j];
			if(iscolumn(col) && col.st.visibility == Style->Vvisible && col.w > 0)
				paintbackground(dst, col, kidrect(col, o));
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
		if(!inflowblock(k) || k.kind == Kreplaced || hasitems(k))
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
				if(hasitems(k))
					paintitems(dst, k, r.min, inner, canvasbg);
				else
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
	if(textmask || st.visibility != Style->Vvisible || st.outlinew <= 0 || st.outlines == Style->Bnone)
		return;
	if(iscolumn(b))
		return;	# columns and column groups are not rendered boxes (outline-applies-to-005)
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

paintshadows(dst: ref Image, b: ref Box, r: Rect)
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
}

# The background of a row, row group, column or column group shows
# only through its cells: the spacing between them is the table's
# (CSS 2.2 §17.5.1).  It is positioned on the part's own box and
# painted once per cell, clipped to the cell.
painttablepart(dst: ref Image, b: ref Box, r: Rect)
{
	st := b.st;
	paintshadows(dst, b, r);	# a shadow is the part's own box's (box-shadow-table-row-display)
	if(!visible(st.bgcolor) && len st.bg == 0)
		return;
	oclip := dst.clipr;
	for(cl := partcells(b, r); cl != nil; cl = tl cl) {
		dst.clipr = intersect(oclip, hd cl);
		if(rectok(dst.clipr))
			paintbackground(dst, b, r);
	}
	dst.clipr = oclip;
}

# the cells a table part's background shows through, as rectangles
# on the canvas: a row's or row group's own, a column's those its
# columns cross
partcells(b: ref Box, r: Rect): list of Rect
{
	cl: list of Rect;
	if(b.kind == Krow)
		return rowcells(b, r.min, nil);
	if(isrowgroup(b)) {
		for(i := 0; i < len b.kids; i++)
			if(b.kids[i].kind == Krow)
				cl = rowcells(b.kids[i], Point(r.min.x + b.kids[i].x, r.min.y + b.kids[i].y), cl);
		return cl;
	}
	# a column: the table's origin from its own, through a group's
	o := Point(r.min.x - b.x, r.min.y - b.y);
	t := b.parent;
	if(t != nil && t.kind != Ktable) {
		o = Point(o.x - t.x, o.y - t.y);
		t = t.parent;
	}
	if(t == nil || t.kind != Ktable)
		return nil;
	all: list of Rect;
	for(i := 0; i < len t.kids; i++) {
		k := t.kids[i];
		if(k.kind == Krow)
			all = rowcells(k, Point(o.x + k.x, o.y + k.y), all);
		else if(isrowgroup(k))
			for(j := 0; j < len k.kids; j++)
				if(k.kids[j].kind == Krow)
					all = rowcells(k.kids[j], Point(o.x + k.x + k.kids[j].x, o.y + k.y + k.kids[j].y), all);
	}
	for(; all != nil; all = tl all) {
		c := hd all;
		if(c.min.x < r.max.x && c.max.x > r.min.x)
			cl = c :: cl;
	}
	return cl;
}

rowcells(row: ref Box, o: Point, cl: list of Rect): list of Rect
{
	for(i := 0; i < len row.kids; i++) {
		k := row.kids[i];
		if(k.kind == Kcell && !isoof(k))
			cl = kidrect(k, o) :: cl;
	}
	return cl;
}

paintbackground(dst: ref Image, b: ref Box, r: Rect)
{
	paintshadows(dst, b, r);
	ck := bgclip(b.st);
	if(ck == Style->BOXtext || ck == Style->BOXborderarea)
		maskedbackground(dst, b, r, ck);
	else
		plainbackground(dst, b, r);
}

# background-clip: text or border-area (Backgrounds 4 §2.8): the
# background is painted into a layer over the border box and comes
# through a mask, the box's text (glyphs and decorations, painted in
# white with textmask set) or the border area (the border box less
# the padding box) (clip-text-multi-line, clip-border-area-solid)
textmask: int;

maskedbackground(dst: ref Image, b: ref Box, r: Rect, ck: int)
{
	(lr, ok) := dst.clipr.clip(r);
	if(!ok || !rectok(lr))
		return;
	layer := display.newimage(lr, Draw->RGBA32, 0, Draw->Transparent);
	m := display.newimage(lr, Draw->GREY8, 0, Draw->Black);
	if(layer == nil || m == nil)
		return;
	plainbackground(layer, b, r);
	if(ck == Style->BOXborderarea)
		borderareamask(m, b, r, 1, 1);
	else {
		textmask++;
		paintcontent(m, b, r, lr, nil);
		textmask--;
	}
	dst.draw(lr, layer, m, lr.min);
}

# the border area of the box r into the mask m: the box's border box
# less its padding box, the left and right sides being the box's own
# or not (a fragment of an inline box in the middle has neither)
borderareamask(m: ref Image, b: ref Box, r: Rect, left, right: int)
{
	(rtl, rtr, rbr, rbl) := radii(b);
	m.fillpath(rrect(r, rtl, rtr, rbr, rbl), 1, display.white, (0, 0));
	bl := b.bl;
	br := b.br;
	if(!left)
		bl = 0;
	if(!right)
		br = 0;
	pr := Rect((r.min.x + bl, r.min.y + b.bt), (r.max.x - br, r.max.y - b.bb));
	m.fillpath(rrect(pr, innerradius(rtl, bl, b.bt), innerradius(rtr, br, b.bt), innerradius(rbr, br, b.bb), innerradius(rbl, bl, b.bb)), 1, display.black, (0, 0));
}

# a corner's inner radius: the outer less the wider border beside it
innerradius(r, w1, w2: int): int
{
	if(w2 > w1)
		w1 = w2;
	r -= w1;
	if(r < 0)
		r = 0;
	return r;
}

# is k the box b or inside it?
within(k, b: ref Box): int
{
	for(; k != nil; k = k.parent)
		if(k == b)
			return 1;
	return 0;
}

plainbackground(dst: ref Image, b: ref Box, r: Rect)
{
	st := b.st;
	if(visible(bcolor(st, st.bgcolor))) {
		br := r;
		case bgclip(st) {
		Style->BOXpadding =>
			br = Rect((r.min.x + b.bl, r.min.y + b.bt), (r.max.x - b.br, r.max.y - b.bb));
		Style->BOXcontent =>
			br = Rect((r.min.x + b.bl + b.pl, r.min.y + b.bt + b.pt), (r.max.x - b.br - b.pr, r.max.y - b.bb - b.pb));
		}
		fillbox(dst, b, br, bcolor(st, st.bgcolor));	# currentcolor is the box's own colour (currentcolor-001)
	}
	for(i := len st.bg - 1; i >= 0; i--)
		if(st.bg[i].img != nil)
			paintbg(dst, b, r, st.bg[i]);
}

# border-image (Backgrounds 3 §6): the image is cut into nine parts by
# the slices; the corners go into the corners of the border image
# area, the edges along its sides, stretched or tiled, the middle into
# the rest when fill is asked; it takes the place of the border styles
paintborderimage(dst: ref Image, b: ref Box, r: Rect): int
{
	bi := b.st.bimage;
	if(bi == nil || bi.src == nil)
		return 0;
	# outsets: the image area reaches past the border box (§6.4)
	ot := bimoutset(bi.outset[0], b.bt);
	oright := bimoutset(bi.outset[1], b.br);
	ob := bimoutset(bi.outset[2], b.bb);
	ol := bimoutset(bi.outset[3], b.bl);
	area := Rect((r.min.x - ol, r.min.y - ot), (r.max.x + oright, r.max.y + ob));
	img: ref Image;
	u := bgurl(bi.src);
	if(u == nil) {
		# a gradient: it has no size of its own, so it is the area's
		# (border-image-outset-003)
		if(bi.src.kind != Css->Kfunction || !rectok(area))
			return 0;
		img = display.newimage(Rect((0, 0), (area.dx(), area.dy())), Draw->RGBA32, 0, Draw->Transparent);
		if(img == nil)
			return 0;
		paintgradient(img, b, img.r, ref Style->Bg(bi.src, Style->Rrepeat, Style->Rrepeat, Style->Len(Style->Lpx, 0.0, 0.0, nil), Style->Len(Style->Lpx, 0.0, 0.0, nil),
			Style->Len(Style->Lauto, 0.0, 0.0, nil), Style->Len(Style->Lauto, 0.0, 0.0, nil), Style->BOXborder, Style->BOXpadding, 0));
	} else if((svg := bgsvgof(u)) != nil) {
		# an SVG at its own size, or the area's where it has none
		# (border-image-image-type-001)
		(siw, sih, sratio, nil, nil) := svgintrinsic(svg);
		if(siw < 0 && sih < 0) {
			siw = area.dx();
			sih = area.dy();
			if(sratio > 0.0)
				sih = ir(real siw / sratio);
		} else if(siw < 0) {
			siw = area.dx();
			if(sratio > 0.0)
				siw = ir(real sih * sratio);
		} else if(sih < 0) {
			sih = area.dy();
			if(sratio > 0.0)
				sih = ir(real siw / sratio);
		}
		if(siw > 0 && sih > 0)
			img = svgraster(u, svg, siw, sih);
	} else {
		for(l := bgimages; l != nil; l = tl l)
			if((hd l).t0 == u) {
				img = (hd l).t1;
				break;
			}
	}
	if(img == nil)
		return 0;
	iw := img.r.dx();
	ih := img.r.dy();
	if(iw <= 0 || ih <= 0)
		return 0;
	# slices: numbers are pixels of the image, percentages of it; two
	# that overlap are scaled down together, to whole pixels rounded
	# up, so that a 1 by 1 image sliced at 100% still has its corners
	# (§6.2; border-image-006)
	st := slicev(bi.slice[0], ih);
	sr := slicev(bi.slice[1], iw);
	sb := slicev(bi.slice[2], ih);
	sl := slicev(bi.slice[3], iw);
	if(st + sb > ih) {
		f := real ih / real (st + sb);
		st = ceil(real st * f);
		sb = ceil(real sb * f);
	}
	if(sl + sr > iw) {
		f := real iw / real (sl + sr);
		sl = ceil(real sl * f);
		sr = ceil(real sr * f);
	}
	# widths: a number is that many border widths, auto the slice, else
	# a length or a percentage of the border box; too wide, they are
	# scaled down together (§6.3)
	wt := bimwidth(bi.width[0], b.bt, st, r.dy());
	wr := bimwidth(bi.width[1], b.br, sr, r.dx());
	wb := bimwidth(bi.width[2], b.bb, sb, r.dy());
	wl := bimwidth(bi.width[3], b.bl, sl, r.dx());
	f := 1.0;
	if(wl + wr > area.dx() && wl + wr > 0)
		f = real area.dx() / real (wl + wr);
	if(wt + wb > area.dy() && wt + wb > 0)
		f = minf(f, real area.dy() / real (wt + wb));
	if(f < 1.0) {
		wt = ir(real wt * f);
		wr = ir(real wr * f);
		wb = ir(real wb * f);
		wl = ir(real wl * f);
	}
	oclip := dst.clipr;
	(cr, ok) := oclip.clip(area);
	if(!ok)
		return 1;
	dst.clipr = cr;
	(x0, y0, x1, y1) := (area.min.x, area.min.y, area.max.x, area.max.y);
	S := Style->BIstretch;
	bimpart(dst, img, Rect((0, 0), (sl, st)), Rect((x0, y0), (x0 + wl, y0 + wt)), S, S, 0.0, 0.0);
	bimpart(dst, img, Rect((iw - sr, 0), (iw, st)), Rect((x1 - wr, y0), (x1, y0 + wt)), S, S, 0.0, 0.0);
	bimpart(dst, img, Rect((iw - sr, ih - sb), (iw, ih)), Rect((x1 - wr, y1 - wb), (x1, y1)), S, S, 0.0, 0.0);
	bimpart(dst, img, Rect((0, ih - sb), (sl, ih)), Rect((x0, y1 - wb), (x0 + wl, y1)), S, S, 0.0, 0.0);
	bimpart(dst, img, Rect((sl, 0), (iw - sr, st)), Rect((x0 + wl, y0), (x1 - wr, y0 + wt)), bi.repx, S, 0.0, 0.0);
	bimpart(dst, img, Rect((sl, ih - sb), (iw - sr, ih)), Rect((x0 + wl, y1 - wb), (x1 - wr, y1)), bi.repx, S, 0.0, 0.0);
	bimpart(dst, img, Rect((0, st), (sl, ih - sb)), Rect((x0, y0 + wt), (x0 + wl, y1 - wb)), S, bi.repy, 0.0, 0.0);
	bimpart(dst, img, Rect((iw - sr, st), (iw, ih - sb)), Rect((x1 - wr, y0 + wt), (x1, y1 - wb)), S, bi.repy, 0.0, 0.0);
	if(bi.fill) {
		# the middle is scaled as the top and left edges are (§6.5)
		fx := 1.0;
		if(st > 0)
			fx = real wt / real st;
		else if(sb > 0)
			fx = real wb / real sb;
		fy := 1.0;
		if(sl > 0)
			fy = real wl / real sl;
		else if(sr > 0)
			fy = real wr / real sr;
		bimpart(dst, img, Rect((sl, st), (iw - sr, ih - sb)), Rect((x0 + wl, y0 + wt), (x1 - wr, y1 - wb)), bi.repx, bi.repy, fx, fy);
	}
	dst.clipr = oclip;
	return 1;
}

ceil(x: real): int
{
	n := int x;	# to the nearest
	if(real n < x)
		n++;
	return n;
}

slicev(l: Style->Len, size: int): int
{
	v := ir(l.px + l.pct * real size / 100.0);
	if(v < 0)
		v = 0;
	if(v > size)
		v = size;
	return v;
}

bimwidth(l: Style->Len, bw, slice, box: int): int
{
	case l.kind {
	Style->Lnum =>	return ir(l.px * real bw);
	Style->Lauto =>	return slice;
	}
	return ir(l.resolve(real box));
}

bimoutset(l: Style->Len, bw: int): int
{
	if(l.kind == Style->Lnum)
		return ir(l.px * real bw);
	return ir(l.px);
}

# One part: the slice src of img into the region dr, along each axis
# stretched to the region or tiled at the tile size (an edge's is
# scaled with its thickness, the middle's given) repeated from the
# centre, rounded to whole tiles, or spaced with the room left shared
# around them (§6.5).
bimpart(dst, img: ref Image, src, dr: Rect, repx, repy: int, fx, fy: real)
{
	sw := src.dx();
	sh := src.dy();
	dw := dr.dx();
	dh := dr.dy();
	if(sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0)
		return;
	tw := dw;
	th := dh;
	if(repx != Style->BIstretch) {
		if(fx > 0.0)
			tw = ir(real sw * fx);
		else
			tw = ir(real sw * real dh / real sh);
	}
	if(repy != Style->BIstretch) {
		if(fy > 0.0)
			th = ir(real sh * fy);
		else
			th = ir(real sh * real dw / real sw);
	}
	sub := subimage(img, src);
	if(sub == nil)
		return;
	oclip := dst.clipr;
	(cr, ok) := oclip.clip(dr);
	if(!ok)
		return;
	dst.clipr = cr;
	for(yl := bimplaces(repy, dr.min.y, dh, th); yl != nil; yl = tl yl) {
		(y, h) := hd yl;
		for(xl := bimplaces(repx, dr.min.x, dw, tw); xl != nil; xl = tl xl) {
			(x, w) := hd xl;
			t := scale(sub, w, h);
			if(t != nil)
				dst.draw(Rect((x, y), (x + w, y + h)), t, nil, t.r.min);
		}
	}
	dst.clipr = oclip;
}

# the tiles along one axis of a part: (start, size) each
bimplaces(rep, x0, dw, tw: int): list of (int, int)
{
	l: list of (int, int);
	case rep {
	Style->BIrepeat =>
		if(tw <= 0)
			return nil;
		start := x0 + (dw - tw)/2;
		while(start > x0)
			start -= tw;
		for(x := start; x < x0 + dw; x += tw)
			l = (x, tw) :: l;
	Style->BIround =>
		if(tw <= 0)
			return nil;
		n := nearest(real dw / real tw);
		if(n < 1)
			n = 1;
		for(i := n - 1; i >= 0; i--) {
			a := x0 + ir(real i * real dw / real n);
			e := x0 + ir(real (i + 1) * real dw / real n);
			l = (a, e - a) :: l;
		}
	Style->BIspace =>
		if(tw <= 0)
			return nil;
		n := dw / tw;
		if(n == 0)
			return nil;
		gap := real (dw - n*tw) / real (n + 1);
		for(i := n - 1; i >= 0; i--)
			l = (x0 + ir(real (i + 1) * gap + real (i * tw)), tw) :: l;
	* =>
		return (x0, dw) :: nil;
	}
	return l;
}

# the part of an image within sr, as an image of its own (kept, as
# the border image is drawn at every paint)
subimages: list of (ref Image, Rect, ref Image);

subimage(img: ref Image, sr: Rect): ref Image
{
	for(l := subimages; l != nil; l = tl l) {
		(si, r, d) := hd l;
		if(si == img && r.eq(sr))
			return d;
	}
	d := display.newimage(Rect((0, 0), (sr.dx(), sr.dy())), img.chans, 0, Draw->Transparent);
	if(d == nil)
		return nil;
	d.draw(d.r, img, nil, sr.min);
	if(len subimages >= 32)
		subimages = nil;
	subimages = (img, sr, d) :: subimages;
	return d;
}

# an outer shadow shows only outside the border box (Backgrounds 3
# §7.1): it goes through a mask with the box cleared from it, so that
# a box without a background of its own shows nothing of it inside
# (slice-inline-fragmentation-001)
shadowfill(dst: ref Image, b: ref Box, sr, r: Rect, c: int)
{
	if(!rectok(sr))
		return;
	(mr, ok) := dst.clipr.clip(sr);
	if(!ok || !rectok(mr))
		return;
	(rtl, rtr, rbr, rbl) := radii(b);
	m := display.newimage(mr, Draw->GREY8, 0, Draw->Black);
	if(m == nil)
		return;
	m.fillpath(rrect(sr, rtl, rtr, rbr, rbl), 1, display.white, (0, 0));
	m.fillpath(rrect(r, rtl, rtr, rbr, rbl), 1, display.black, (0, 0));
	dst.draw(mr, colorimg(c), m, mr.min);
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
	if(paintborderimage(dst, b, r))
		return;
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
	bgsvgs = nil;
	svgrasters = nil;
}

# SVG background images: their source, drawn again at each size they
# are shown at rather than scaled (background-size-vector-*)
bgsvgs: list of (string, array of byte);
svgrasters: list of (string, int, int, ref Image);

setbgsvg(url: string, data: array of byte)
{
	for(l := bgsvgs; l != nil; l = tl l)
		if((hd l).t0 == url)
			return;
	bgsvgs = (url, data) :: bgsvgs;
}

bgsvgof(url: string): array of byte
{
	for(l := bgsvgs; l != nil; l = tl l)
		if((hd l).t0 == url)
			return (hd l).t1;
	return nil;
}

svgraster(url: string, data: array of byte, w, h: int): ref Image
{
	for(l := svgrasters; l != nil; l = tl l) {
		(cu, cw, ch, ci) := hd l;
		if(cu == url && cw == w && ch == h)
			return ci;
	}
	if(readsvg == nil) {
		bufio = load Bufio Bufio->PATH;
		readsvg = load RImagefile RImagefile->READSVGPATH;
		imageremap = load Imageremap Imageremap->PATH;
		if(bufio == nil || readsvg == nil || imageremap == nil) {
			readsvg = nil;
			return nil;
		}
		readsvg->init(bufio);
		imageremap->init(display);
	}
	(raw, err) := readsvg->read(bufio->aopen(svgresize(data, w, h)));
	if(raw == nil || err != nil)
		return nil;
	(img, nil) := imageremap->remap(raw, display, 0);
	if(img == nil)
		return nil;
	if(len svgrasters > 64)
		svgrasters = nil;
	svgrasters = (url, w, h, img) :: svgrasters;
	return img;
}

# the root <svg> tag's text (between "<svg" and ">") and where it lies
svgroot(s: string): (int, int)
{
	i := 0;
	for(;;) {
		i = strindex(s, "<svg", i);
		if(i < 0 || i + 4 >= len s)
			return (-1, -1);
		c := s[i+4];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '>' || c == '/')
			break;
		i += 4;
	}
	e := strindex(s, ">", i);
	if(e < 0)
		return (-1, -1);
	return (i, e);
}

# The SVG with its root element's size set to w by h: the content is
# then drawn to fit, through a viewBox (one made from the old size if it
# had none).
svgresize(data: array of byte, w, h: int): array of byte
{
	s := string data;
	(i, e) := svgroot(s);
	if(i < 0)
		return data;
	tag := s[i+4:e];
	ow, oh: string;
	(tag, ow) = dropattr(tag, "width");
	(tag, oh) = dropattr(tag, "height");
	vb := "";
	if(strindex(tag, "viewBox", 0) < 0 && strindex(tag, "viewbox", 0) < 0) {
		# "65px" converts as 65; a percentage gives no box to fit
		if(svglen(ow) > 0 && svglen(oh) > 0)
			vb = sys->sprint(" viewBox=\"0 0 %d %d\"", svglen(ow), svglen(oh));
	}
	n := s[0:i] + sys->sprint("<svg width=\"%d\" height=\"%d\"%s", w, h, vb) + tag + s[e:];
	return array of byte n;
}

# An SVG's intrinsic width and height (-1: none; a percentage is none)
# and ratio (0: none): the root's width and height, the ratio theirs
# when both are there, else the viewBox's (SVG 2 §8.6, Images 3 §4.1).
svgintrinsic(data: array of byte): (int, int, real, real, real)
{
	s := string data;
	(i, e) := svgroot(s);
	if(i < 0)
		return (-1, -1, 0.0, 0.0, 0.0);
	tag := s[i+4:e];
	(nil, ws) := dropattr(tag, "width");
	(nil, hs) := dropattr(tag, "height");
	(nil, vs) := dropattr(tag, "viewBox");
	iw := svglen(ws);
	ih := svglen(hs);
	ratio := 0.0;
	if(iw > 0 && ih > 0)
		ratio = real iw / real ih;
	else if((vb := viewbox(vs)) != nil && vb[2] > 0.0 && vb[3] > 0.0)
		ratio = vb[2] / vb[3];
	return (iw, ih, ratio, svgpct(ws), svgpct(hs));
}

# an SVG length that is a percentage: its value, else 0
svgpct(s: string): real
{
	if(s == nil || len s < 2 || s[len s - 1] != '%')
		return 0.0;
	i := 0;
	while(i < len s - 1 && (s[i] >= '0' && s[i] <= '9' || s[i] == '.' || s[i] == ' '))
		i++;
	if(i == 0)
		return 0.0;
	return real s[0:i];
}

# an SVG length in CSS pixels, -1 for none or a percentage
svglen(s: string): int
{
	if(s == nil)
		return -1;
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	st := i;
	while(i < len s && (s[i] >= '0' && s[i] <= '9' || s[i] == '.' || s[i] == '-' || s[i] == '+' || s[i] == 'e' || s[i] == 'E'))
		i++;
	if(i == st)
		return -1;
	v := real s[st:i];
	u := s[i:];
	while(len u > 0 && (u[len u-1] == ' ' || u[len u-1] == '\t' || u[len u-1] == '\n' || u[len u-1] == '\r'))
		u = u[0:len u-1];
	case lower(u) {
	"" or "px" =>	;
	"pt" =>	v = v * 96.0 / 72.0;
	"pc" =>	v = v * 16.0;
	"in" =>	v = v * 96.0;
	"cm" =>	v = v * 96.0 / 2.54;
	"mm" =>	v = v * 96.0 / 25.4;
	"em" or "rem" =>	v = v * 16.0;
	* =>	return -1;
	}
	if(v < 0.0)
		return -1;
	return int v;	# to the nearest
}

# remove attribute nm="..." from a tag's text; its value
dropattr(tag, nm: string): (string, string)
{
	for(i := 0; (i = strindex(tag, nm, i)) >= 0; i += len nm) {
		if(i > 0 && tag[i-1] != ' ' && tag[i-1] != '\t' && tag[i-1] != '\n' && tag[i-1] != '\r')
			continue;
		j := i + len nm;
		while(j < len tag && (tag[j] == ' ' || tag[j] == '\t'))
			j++;
		if(j >= len tag || tag[j] != '=')
			continue;
		j++;
		while(j < len tag && (tag[j] == ' ' || tag[j] == '\t'))
			j++;
		if(j >= len tag)
			return (tag, nil);
		q := tag[j];
		v0, v1, end: int;
		if(q == '"' || q == '\'') {
			v0 = j + 1;
			for(v1 = v0; v1 < len tag && tag[v1] != q; v1++)
				;
			end = v1 + 1;
		} else {
			v0 = j;
			for(v1 = v0; v1 < len tag && tag[v1] != ' ' && tag[v1] != '>' && tag[v1] != '/'; v1++)
				;
			end = v1;
		}
		if(end > len tag)
			end = len tag;
		return (tag[0:i] + tag[end:], tag[v0:v1]);
	}
	return (tag, nil);
}

strindex(s, t: string, from: int): int
{
	for(i := from; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}

# The concrete size of a background image (Backgrounds 3 §3.9, Images
# 3 §4.4) from its intrinsic width and height (-1: none), its ratio
# (0: none) and the positioning area: contain and cover keep the ratio
# when there is one, else fill the area; auto takes the intrinsic
# size, one side from the other through the ratio, a ratio alone as
# contain, and nothing as the area's size.
concretesize(bg: ref Style->Bg, iw, ih: int, ratio: real, aw, ah: int): (real, real)
{
	w := real aw;
	h := real ah;
	if(bg.sizex.kind == Style->Lcontent && (bg.sizex.px == -1.0 || bg.sizex.px == -2.0)) {
		if(ratio > 0.0) {
			h = w / ratio;
			if(bg.sizex.px == -2.0 && h > real ah || bg.sizex.px == -1.0 && h < real ah) {
				h = real ah;
				w = h * ratio;
			}
		}
		return (w, h);
	}
	xa := bg.sizex.isauto();
	ya := bg.sizey.isauto();
	if(!xa)
		w = bg.sizex.resolve(real aw);
	if(!ya)
		h = bg.sizey.resolve(real ah);
	if(xa && ya) {
		if(iw >= 0 && ih >= 0)
			(w, h) = (real iw, real ih);
		else if(iw >= 0) {
			w = real iw;
			if(ratio > 0.0)
				h = w / ratio;
		} else if(ih >= 0) {
			h = real ih;
			if(ratio > 0.0)
				w = h * ratio;
		} else if(ratio > 0.0) {
			h = w / ratio;
			if(h > real ah) {
				h = real ah;
				w = h * ratio;
			}
		}
	} else if(!xa && ya) {
		if(ratio > 0.0)
			h = w / ratio;
		else if(ih >= 0)
			h = real ih;
	} else if(xa && !ya) {
		if(ratio > 0.0)
			w = h * ratio;
		else if(iw >= 0)
			w = real iw;
	}
	return (w, h);
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
	if(st.bimage != nil && st.bimage.src != nil && (bu := bgurl(st.bimage.src)) != nil)
		r = bu :: r;
	return r;
}

paintbg(dst: ref Image, b: ref Box, r: Rect, bg: ref Style->Bg)
{
	grad := bg.img.kind == Css->Kfunction && bg.img.s != "url";
	img: ref Image;
	u := "";
	if(!grad) {
		u = bgurl(bg.img);
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
	iw := -1;	# the intrinsic size: a gradient has none
	ih := -1;
	ratio := 0.0;
	svg: array of byte;
	if(!grad) {
		svg = bgsvgof(u);
		if(svg != nil)
			(iw, ih, ratio, nil, nil) = svgintrinsic(svg);
		else {
			iw = img.r.dx();
			ih = img.r.dy();
			if(iw <= 0 || ih <= 0)
				return;
			ratio = real iw / real ih;
		}
	}
	(w, h) := concretesize(bg, iw, ih, ratio, aw, ah);
	# round: as many whole tiles as fit nearest, each scaled to fit
	# exactly; an auto other dimension keeps the ratio (background-size-029)
	if(bg.rx == Style->Rround && w > 0.0) {
		w = real aw / real nearest(real aw / w);
		if(bg.ry != Style->Rround && bg.sizey.isauto() && ratio > 0.0)
			h = w / ratio;
	}
	if(bg.ry == Style->Rround && h > 0.0) {
		h = real ah / real nearest(real ah / h);
		if(bg.rx != Style->Rround && bg.sizex.isauto() && ratio > 0.0)
			w = h * ratio;
	}
	tw := int w;	# int rounds
	th := int h;
	if(w > 0.0 && tw < 1 && bg.rx != Style->Rnorepeat)	# a sliver still shows when it is repeated into a fill; alone it is nothing (tall--contain--height)
		tw = 1;
	if(h > 0.0 && th < 1 && bg.ry != Style->Rnorepeat)
		th = 1;
	if(tw <= 0 || th <= 0)
		return;
	if(!grad) {
		if(svg != nil)
			img = svgraster(u, svg, tw, th);
		else if(tw != iw || th != ih)
			img = scale(img, tw, th);
		if(img == nil)
			return;
	}
	# background-position: a percentage of the room left over
	px := area.min.x + int (bg.posx.px + bg.posx.pct * real (aw - tw) / 100.0);
	py := area.min.y + int (bg.posy.px + bg.posy.pct * real (ah - th) / 100.0);
	xs := tileplaces(bg.rx, px, tw, area.min.x, aw, clip.min.x, clip.max.x);
	ys := tileplaces(bg.ry, py, th, area.min.y, ah, clip.min.y, clip.max.y);
	oclip := dst.clipr;
	(cr, ok) := oclip.clip(clip);
	if(!ok)
		return;
	dst.clipr = cr;
	for(yl := ys; yl != nil; yl = tl yl)
		for(xl := xs; xl != nil; xl = tl xl) {
			x := hd xl;
			y := hd yl;
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

# where the tiles of size t go along one axis, the first at p by
# background-position: repeated and round fill the clip from there;
# space fits whole tiles in the positioning area [a0, a0+aw) with the
# room left shared between them, the first and last touching its
# edges, or one alone at p (Backgrounds 3 §3.4; background-repeat-space-10)
tileplaces(rep, p, t, a0, aw, c0, c1: int): list of int
{
	l: list of int;
	case rep {
	Style->Rnorepeat =>
		return p :: nil;
	Style->Rspace =>
		n := aw / t;
		if(n < 2)
			return p :: nil;
		# the same spacing goes on past the positioning area, into
		# the rest of the painting area (gradient-repeat-spaced-with-borders)
		step := real (aw - t) / real (n - 1);
		i := 0;
		while(a0 + ir(real i * step) > c0)
			i--;
		for(; a0 + ir(real i * step) < c1; i++)
			l = a0 + ir(real i * step) :: l;
		r: list of int;
		for(; l != nil; l = tl l)
			r = hd l :: r;
		return r;
	}
	x0 := p;
	while(x0 > c0)
		x0 -= t;
	for(x := x0; x < c1; x += t)
		l = x :: l;
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
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
	cols := array[2*n] of int;
	pos := array[2*n] of real;
	k := 0;
	for(; args != nil; args = tl args) {
		a := nows(hd args);
		if(len a == 0)
			continue;
		(ok, c) := style->color(a[0:1]);
		if(!ok)
			continue;
		# a colour with two positions is two stops (Images 4 §3.4.1:
		# "yellow 0% 25%" is a band; border-image-repeat-round-003)
		for(j := 1; j < len a && j <= 2; j++) {
			cols[k] = c;
			pos[k] = -1.0;
			if(a[j].kind == Css->Kpercent)
				pos[k] = a[j].n / 100.0;
			else if(a[j].kind == Css->Kdimension && a[j].s == "px" && linelen > 0.0)
				pos[k] = a[j].n / linelen;
			else if(a[j].kind == Css->Knumber && a[j].n == 0.0)
				pos[k] = 0.0;
			else
				break;
			k++;
		}
		if(len a == 1) {
			cols[k] = c;
			pos[k] = -1.0;
			k++;
		}
	}
	if(k == 0)
		return;
	cols = cols[0:k];
	pos = pos[0:k];
	if(pos[0] < 0.0)
		pos[0] = 0.0;
	if(pos[k-1] < 0.0)
		pos[k-1] = 1.0;
	for(q := 1; q < k; q++)
		if(pos[q] >= 0.0 && pos[q] < pos[q-1] && pos[q-1] >= 0.0)
			pos[q] = pos[q-1];	# a stop before the one before it is at it (§3.4.2)
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
	if(textmask)
		return;
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
		# inline box backgrounds and borders first, outermost first:
		# the fragments come in closing order, inner boxes first, so
		# they are taken by depth (an inner box's background covers
		# its outer box's: inline-formatting-context-002)
		ns := 0;
		for(k := 0; k < len ln.frags; k++)
			if(ln.frags[k].kind == Fspan)
				ns++;
		if(ns > 0) {
			sp := array[ns] of ref Frag;
			dp := array[ns] of int;
			ns = 0;
			for(k = 0; k < len ln.frags; k++) {
				f := ln.frags[k];
				if(f.kind != Fspan)
					continue;
				d := 0;
				for(p := f.box; p != nil; p = p.parent)
					d++;
				j := ns++;
				for(; j > 0 && dp[j-1] > d; j--) {
					sp[j] = sp[j-1];
					dp[j] = dp[j-1];
				}
				sp[j] = f;
				dp[j] = d;
			}
			for(k = 0; k < ns; k++)
				if(sp[k].box.st.visibility == Style->Vvisible)
					paintspan(dst, sp[k], o, ln);
		}
		ofl := linefl;
		obase := lineflbase;
		for(k = 0; k < len ln.frags; k++) {
			f := ln.frags[k];
			linefl = ln.fl;
			lineflbase = b.st.color;
			case f.kind {
			Ftext =>
				if(f.box.st.visibility == Style->Vvisible)
					painttext(dst, f, o);
			Fatomic =>
				if(!islayer(f.box))
					paintflow(dst, f.box, o, clip, canvasbg);
			}
		}
		linefl = ofl;
		lineflbase = obase;
	}
}

hasatomic(ln: ref Line): int
{
	for(k := 0; k < len ln.frags; k++)
		if(ln.frags[k].kind == Fatomic)
			return 1;
	return 0;
}

paintspan(dst: ref Image, f: ref Frag, o: Point, ln: ref Line)
{
	if(textmask)
		return;
	b := f.box;
	st := b.st;
	x0 := o.x + f.x;
	if(leftedge(f))
		x0 += b.ml;
	x1 := o.x + f.x + f.w;
	if(rightedge(f))
		x1 -= b.mr;
	r := Rect((x0, o.y + f.y), (x1, o.y + f.y + f.h));
	if(len st.shadows > 0) {
		# the shadow of the unbroken box, sliced at the fragment's
		# ends (Break 3 §5.1: slice-inline-fragmentation-001)
		oclip := dst.clipr;
		cr := oclip;
		br := r;	# the box as if unbroken: it goes on past the ends that are not its own
		if(!leftedge(f)) {
			if(r.min.x > cr.min.x)
				cr.min.x = r.min.x;
			br.min.x -= 1000;
		}
		if(!rightedge(f)) {
			if(r.max.x < cr.max.x)
				cr.max.x = r.max.x;
			br.max.x += 1000;
		}
		dst.clipr = cr;
		paintshadows(dst, b, br);
		dst.clipr = oclip;
	}
	ck := bgclip(st);
	if(ck == Style->BOXtext || ck == Style->BOXborderarea)
		maskedspan(dst, f, o, ln, r, ck);
	else
		spanbackground(dst, b, r);
	side(dst, Rect(r.min, (r.max.x, r.min.y + b.bt)), b.bt, st.bct, st.bst, 0, 1);
	side(dst, Rect((r.min.x, r.max.y - b.bb), r.max), b.bb, st.bcb, st.bsb, 0, 0);
	if(leftedge(f))
		side(dst, Rect(r.min, (r.min.x + b.bl, r.max.y)), b.bl, st.bcl, st.bsl, 1, 1);
	if(rightedge(f))
		side(dst, Rect((r.max.x - b.br, r.min.y), r.max), b.br, st.bcr, st.bsr, 1, 0);
}

spanbackground(dst: ref Image, b: ref Box, r: Rect)
{
	st := b.st;
	if(visible(st.bgcolor))
		dst.draw(r, colorimg(st.bgcolor), nil, (0, 0));
	for(i := len st.bg - 1; i >= 0; i--)
		if(st.bg[i].img != nil)
			paintbg(dst, b, r, st.bg[i]);
}

# an inline box's fragment with background-clip: text or border-area:
# as maskedbackground, the text being the line's fragments inside the
# box (clip-text-inline)
maskedspan(dst: ref Image, f: ref Frag, o: Point, ln: ref Line, r: Rect, ck: int)
{
	b := f.box;
	(lr, ok) := dst.clipr.clip(r);
	if(!ok || !rectok(lr))
		return;
	layer := display.newimage(lr, Draw->RGBA32, 0, Draw->Transparent);
	m := display.newimage(lr, Draw->GREY8, 0, Draw->Black);
	if(layer == nil || m == nil)
		return;
	spanbackground(layer, b, r);
	if(ck == Style->BOXborderarea)
		borderareamask(m, b, r, leftedge(f), rightedge(f));
	else {
		textmask++;
		for(k := 0; k < len ln.frags; k++) {
			g := ln.frags[k];
			if(g == f || !within(g.box, b))
				continue;
			case g.kind {
			Ftext =>
				painttext(m, g, o);
			Fatomic =>
				paintflow(m, g.box, o, lr, nil);
			}
		}
		textmask--;
	}
	dst.draw(lr, layer, m, lr.min);
}

linefl: ref St;	# the ::first-line style of the line being painted, if any
lineflbase: int;	# and the block's own colour: text of another colour has its own (display-contents-first-line-002)

painttext(dst: ref Image, f: ref Frag, o: Point)
{
	st := f.box.st;
	if(linefl != nil && linefl.color != st.color && st.color == lineflbase) {
		# the first line's colour (its other properties are not honoured yet)
		st = ref *st;
		st.color = linefl.color;
	}
	if(f.text == "")
		return;	# an absolutely positioned box's place
	if(f.text == " " || f.text == "\t")
		return paintdeco(dst, f, o);
	fc := f.face;
	p := Point(o.x + f.x, o.y + f.base);
	text := visual(f);
	if(textmask) {
		# into a mask: the glyphs and decorations, whatever the colour
		drawtext(dst, fc, p, text, display.white, st.letterspacing, f.level % 2);
		paintdeco(dst, f, o);
		return;
	}
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
	if(textmask)
		img = display.white;
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
				Fspan =>
					s += sys->sprint("%s    span %d %d %d %d %d %d%d\n", ind, f.box.node, x + f.x, y + f.y, f.w, f.h, f.first, f.last);
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
