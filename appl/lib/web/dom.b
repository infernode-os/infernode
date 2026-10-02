implement Dom;

#
# The document tree.  See module/web/dom.m.
#

include "sys.m";
	sys: Sys;
include "web/dom.m";

tagnames := array[] of {
	"",
	"a",
	"abbr",
	"address",
	"applet",
	"area",
	"article",
	"aside",
	"audio",
	"b",
	"base",
	"basefont",
	"bdi",
	"bdo",
	"bgsound",
	"big",
	"blockquote",
	"body",
	"br",
	"button",
	"canvas",
	"caption",
	"center",
	"cite",
	"code",
	"col",
	"colgroup",
	"data",
	"datalist",
	"dd",
	"del",
	"details",
	"dfn",
	"dialog",
	"dir",
	"div",
	"dl",
	"dt",
	"em",
	"embed",
	"fieldset",
	"figcaption",
	"figure",
	"font",
	"footer",
	"form",
	"frame",
	"frameset",
	"h1",
	"h2",
	"h3",
	"h4",
	"h5",
	"h6",
	"head",
	"header",
	"hgroup",
	"hr",
	"html",
	"i",
	"iframe",
	"image",
	"img",
	"input",
	"ins",
	"kbd",
	"keygen",
	"label",
	"legend",
	"li",
	"link",
	"listing",
	"main",
	"map",
	"mark",
	"marquee",
	"menu",
	"meta",
	"meter",
	"nav",
	"nobr",
	"noembed",
	"noframes",
	"noscript",
	"object",
	"ol",
	"optgroup",
	"option",
	"output",
	"p",
	"param",
	"picture",
	"plaintext",
	"pre",
	"progress",
	"q",
	"rb",
	"rp",
	"rt",
	"rtc",
	"ruby",
	"s",
	"samp",
	"script",
	"search",
	"section",
	"select",
	"slot",
	"small",
	"source",
	"span",
	"strike",
	"strong",
	"style",
	"sub",
	"summary",
	"sup",
	"table",
	"tbody",
	"td",
	"template",
	"textarea",
	"tfoot",
	"th",
	"thead",
	"time",
	"title",
	"tr",
	"track",
	"tt",
	"u",
	"ul",
	"var",
	"video",
	"wbr",
	"xmp",
	"svg",
	"math",
	"desc",
	"foreignObject",
	"mi",
	"mo",
	"mn",
	"ms",
	"mtext",
	"annotation-xml",
};

Nhash: con 256;
taghash: array of list of int;

hash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h*31 + s[i];
	return (h & 16r7FFFFFFF) % Nhash;
}

atom(name: string): int
{
	if(taghash == nil) {
		t := array[Nhash] of list of int;
		for(i := 1; i < len tagnames; i++) {
			h := hash(tagnames[i]);
			t[h] = i :: t[h];
		}
		taghash = t;
	}
	for(l := taghash[hash(name)]; l != nil; l = tl l)
		if(tagnames[hd l] == name)
			return hd l;
	return Tnone;
}

tagname(tag: int): string
{
	if(tag <= 0 || tag >= len tagnames)
		return "";
	return tagnames[tag];
}

Doc.new(url: string): ref Doc
{
	d := ref Doc(array[256] of ref Node, 1, 0, 0, url);
	d.create(Document, "#document", HTML);
	return d;
}

Doc.create(d: self ref Doc, kind: int, name: string, ns: int): int
{
	if(d.n >= len d.nodes) {
		a := array[2*len d.nodes] of ref Node;
		a[0:] = d.nodes[0:d.n];
		d.nodes = a;
	}
	tag := Tnone;
	if(kind == Element && ns == HTML)
		tag = atom(name);
	n := d.n++;
	d.nodes[n] = ref Node(kind, tag, ns, name, 0, 0, 0, 0, 0, nil, nil);
	d.gen++;
	return n;
}

Doc.append(d: self ref Doc, parent, child: int)
{
	d.insert(parent, child, 0);
}

Doc.insert(d: self ref Doc, parent, child, before: int)
{
	# A script host can ask for the impossible: a node before itself,
	# before a node elsewhere, or inside its own descendant.  Each
	# would make a cycle, so the tree is left as it was.
	if(child == before || child == parent || before != 0 && d.nodes[before].parent != parent)
		return;
	for(a := parent; a != 0; a = d.nodes[a].parent)
		if(a == child)
			return;
	if(d.nodes[child].parent != 0)
		d.remove(child);
	p := d.nodes[parent];
	c := d.nodes[child];
	c.parent = parent;
	if(before == 0) {
		c.prev = p.last;
		c.next = 0;
		if(p.last != 0)
			d.nodes[p.last].next = child;
		else
			p.first = child;
		p.last = child;
	} else {
		b := d.nodes[before];
		c.next = before;
		c.prev = b.prev;
		if(b.prev != 0)
			d.nodes[b.prev].next = child;
		else
			p.first = child;
		b.prev = child;
	}
	d.gen++;
}

Doc.remove(d: self ref Doc, child: int)
{
	c := d.nodes[child];
	if(c.parent == 0)
		return;
	p := d.nodes[c.parent];
	if(c.prev != 0)
		d.nodes[c.prev].next = c.next;
	else
		p.first = c.next;
	if(c.next != 0)
		d.nodes[c.next].prev = c.prev;
	else
		p.last = c.prev;
	c.parent = c.next = c.prev = 0;
	d.gen++;
}

Doc.setattr(d: self ref Doc, n: int, name, val: string)
{
	nd := d.nodes[n];
	r: list of (string, string);
	found := 0;
	for(l := nd.attrs; l != nil; l = tl l) {
		(k, v) := hd l;
		if(k == name) {
			v = val;
			found = 1;
		}
		r = (k, v) :: r;
	}
	if(!found)
		r = (name, val) :: r;
	for(nd.attrs = nil; r != nil; r = tl r)
		nd.attrs = hd r :: nd.attrs;
	d.gen++;
}

Doc.delattr(d: self ref Doc, n: int, name: string)
{
	nd := d.nodes[n];
	r: list of (string, string);
	for(l := nd.attrs; l != nil; l = tl l)
		if((hd l).t0 != name)
			r = hd l :: r;
	for(nd.attrs = nil; r != nil; r = tl r)
		nd.attrs = hd r :: nd.attrs;
	d.gen++;
}

Doc.settext(d: self ref Doc, n: int, s: string)
{
	d.nodes[n].text = s;
	d.gen++;
}

Doc.attr(d: self ref Doc, n: int, name: string): string
{
	for(l := d.nodes[n].attrs; l != nil; l = tl l)
		if((hd l).t0 == name)
			return (hd l).t1;
	return nil;
}

Doc.hasattr(d: self ref Doc, n: int, name: string): int
{
	for(l := d.nodes[n].attrs; l != nil; l = tl l)
		if((hd l).t0 == name)
			return 1;
	return 0;
}

Doc.root(d: self ref Doc): int
{
	for(c := d.nodes[1].first; c != 0; c = d.nodes[c].next)
		if(d.nodes[c].kind == Element)
			return c;
	return 0;
}

# First descendant of from (in document order) with the given tag.
Doc.find(d: self ref Doc, from, tag: int): int
{
	n := d.nodes[from].first;
	while(n != 0) {
		if(d.nodes[n].tag == tag && d.nodes[n].kind == Element)
			return n;
		n = nextnode(d, n, from);
	}
	return 0;
}

# Next node in document order within the subtree rooted at top.
nextnode(d: ref Doc, n, top: int): int
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

Doc.textof(d: self ref Doc, n: int): string
{
	s := "";
	for(m := d.nodes[n].first; m != 0; m = nextnode(d, m, n))
		if(d.nodes[m].kind == Text)
			s += d.nodes[m].text;
	return s;
}

# The tree in the format of the html5lib tree-construction tests.
Doc.dump(d: self ref Doc): string
{
	s := "";
	for(c := d.nodes[1].first; c != 0; c = d.nodes[c].next)
		s = dumpnode(d, c, 1, s);
	return s;
}

dumpnode(d: ref Doc, n, depth: int, s: string): string
{
	ind := "| ";
	for(i := 1; i < depth; i++)
		ind += "  ";
	nd := d.nodes[n];
	case nd.kind {
	Doctype =>
		s += ind + "<!DOCTYPE " + nd.name + ">\n";
	Comment =>
		s += ind + "<!-- " + nd.text + " -->\n";
	Text =>
		s += ind + "\"" + nd.text + "\"\n";
	Element =>
		pfx := "";
		case nd.ns {
		SVG => pfx = "svg ";
		MathML => pfx = "math ";
		}
		s += ind + "<" + pfx + nd.name + ">\n";
		for(a := sortattrs(nd.attrs); a != nil; a = tl a)
			s += ind + "  " + (hd a).t0 + "=\"" + (hd a).t1 + "\"\n";
		if(nd.tag == Ttemplate && nd.ns == HTML) {
			s += ind + "  content\n";
			depth++;
		}
		for(c := nd.first; c != 0; c = d.nodes[c].next)
			s = dumpnode(d, c, depth+1, s);
	}
	return s;
}

sortattrs(l: list of (string, string)): list of (string, string)
{
	a := array[len l] of (string, string);
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	for(i = 1; i < len a; i++)
		for(j := i; j > 0 && a[j-1].t0 > a[j].t0; j--)
			(a[j-1], a[j]) = (a[j], a[j-1]);
	r: list of (string, string);
	for(i = len a - 1; i >= 0; i--)
		r = a[i] :: r;
	return r;
}
