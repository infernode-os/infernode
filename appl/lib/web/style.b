implement Style;

#
# The cascade.  See module/web/style.m.
#
# Per element: gather candidate rules from the index (by id, class and
# tag of the rightmost compound selector), match them right to left,
# sort the declarations of those that match into cascade order (CSS
# Cascade 5 §6: origin and importance, layer, specificity, order), then
# apply them in that order to a style that starts as the parent's
# inherited values over initial values; the last one applied wins.
# Custom properties are settled first, so that var() can be substituted
# before each declaration is parsed, and font-size before everything
# else, so that em units can be computed.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;
include "web/dom.m";
	dom: Dom;
	Doc, Node: import dom;
include "web/css.m";
	css: Css;
	Tok, Decl, Rule, Sel, Simple, Sheet: import css;
	Kident, Kfunction, Katkeyword, Khash, Kstring, Kurl, Kdelim, Knumber,
	Kpercent, Kdimension, Kws, Kcolon, Ksemicolon, Kcomma, Kblock: import Css;
include "web/style.m";

uasheet: ref Sheet;

init(): string
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	dom = load Dom Dom->PATH;
	css = load Css Css->PATH;
	if(dom == nil || css == nil || math == nil)
		return sys->sprint("cannot load modules: %r");
	css->init();
	f := bufio->open(UACSS, Bufio->OREAD);
	if(f == nil)
		return sys->sprint("cannot open %s: %r", UACSS);
	s := "";
	while((l := f.gets('\n')) != nil)
		s += l;
	uasheet = css->parse(s);
	initial = St.new();
	return nil;
}

# ---- lengths ----

Len.resolve(l: self Len, basis: real): real
{
	case l.kind {
	Lpx =>
		return l.px + l.pct*basis/100.0;
	Lnum =>
		return l.px;
	Lcalc =>
		return evalexpr(l.e, basis);
	}
	return 0.0;
}

Len.isauto(l: self Len): int
{
	return l.kind == Lauto;
}

px(v: real): Len
{
	return Len(Lpx, v, 0.0, nil);
}

kw(k: int): Len
{
	return Len(k, 0.0, 0.0, nil);
}

evalexpr(e: ref Expr, basis: real): real
{
	case e.op {
	'n' =>
		return e.px + e.pct*basis/100.0;
	'k' =>
		return e.px;
	'+' =>
		return evalexpr(e.kids[0], basis) + evalexpr(e.kids[1], basis);
	'-' =>
		return evalexpr(e.kids[0], basis) - evalexpr(e.kids[1], basis);
	'*' =>
		return evalexpr(e.kids[0], basis) * evalexpr(e.kids[1], basis);
	'/' =>
		d := evalexpr(e.kids[1], basis);
		if(d == 0.0)
			return 0.0;
		return evalexpr(e.kids[0], basis) / d;
	'm' or 'M' =>
		v := evalexpr(e.kids[0], basis);
		for(i := 1; i < len e.kids; i++) {
			w := evalexpr(e.kids[i], basis);
			if((e.op == 'm' && w < v) || (e.op == 'M' && w > v))
				v = w;
		}
		return v;
	'c' =>
		lo := evalexpr(e.kids[0], basis);
		v := evalexpr(e.kids[1], basis);
		hi := evalexpr(e.kids[2], basis);
		if(v > hi)
			v = hi;
		if(v < lo)
			v = lo;
		return v;
	}
	return 0.0;
}

# ---- custom properties ----

Nvars: con 32;

Vars.get(v: self ref Vars, name: string): array of ref Tok
{
	if(v == nil)
		return nil;
	for(l := v.tab[strhash(name, Nvars)]; l != nil; l = tl l)
		if((hd l).t0 == name)
			return (hd l).t1;
	return nil;
}

varset(v: ref Vars, name: string, val: array of ref Tok): ref Vars
{
	n := ref Vars(array[Nvars] of list of (string, array of ref Tok));
	if(v != nil)
		n.tab[0:] = v.tab;
	h := strhash(name, Nvars);
	n.tab[h] = (name, val) :: n.tab[h];
	return n;
}

# ---- sheets and the rule index ----

Styles.new(): ref Styles
{
	return ref Styles(nil, nil);
}

Styles.add(s: self ref Styles, sh: ref Sheet, origin: int, base: string)
{
	s.sheets = (sh, origin, base) :: s.sheets;
	s.idx = nil;
}

imported: list of (string, ref Sheet);	# @import URL -> its sheet, for this module instance

Styles.imports(s: self ref Styles, env: ref Env): list of string
{
	urls: list of string;
	for(l := s.sheets; l != nil; l = tl l) {
		(sh, nil, base) := hd l;
		urls = importsof(sh.rules, base, env, urls);
	}
	return urls;
}

importsof(rs: array of ref Rule, base: string, env: ref Env, acc: list of string): list of string
{
	for(i := 0; i < len rs; i++)
		pick r := rs[i] {
		Import =>
			u := resolveurl(base, r.url);
			if(mediamatch(r.cond, env) && lookimport(u) == nil)
				acc = u :: acc;
		}
	return acc;
}

lookimport(u: string): ref Sheet
{
	for(l := imported; l != nil; l = tl l)
		if((hd l).t0 == u)
			return (hd l).t1;
	return nil;
}

# Supply the sheet fetched for an @import URL.
addimport(u: string, sh: ref Sheet)
{
	imported = (u, sh) :: imported;
}

Nbucket: con 512;

Ix: adt {
	idx:	ref Index;
	order:	int;
	layerpos:	list of (string, int);
	nlayers:	int;
	env:	ref Env;
};

buildindex(s: ref Styles, env: ref Env): ref Index
{
	ix := ref Ix(ref Index(array[Nbucket] of list of ref Entry, array[Nbucket] of list of ref Entry,
		array[Nbucket] of list of ref Entry, nil, 0, nil, nil), 0, nil, 0, env);
	# layer names first, in order of first appearance, so tiers are known
	sheets: list of (ref Sheet, int, string);
	for(l := s.sheets; l != nil; l = tl l)
		sheets = hd l :: sheets;
	sheets = (uasheet, UA, "") :: sheets;
	for(sl := sheets; sl != nil; sl = tl sl)
		if((hd sl).t1 == Author)
			findlayers(ix, (hd sl).t0.rules, (hd sl).t2, "");
	for(sl = sheets; sl != nil; sl = tl sl) {
		(sh, origin, base) := hd sl;
		indexrules(ix, sh.rules, origin, nil, base, 0);
	}
	ix.idx.n = ix.order;
	for(ll := ix.layerpos; ll != nil; ll = tl ll)
		ix.idx.layers = (hd ll).t0 :: ix.idx.layers;
	return ix.idx;
}

findlayers(ix: ref Ix, rs: array of ref Rule, base, pfx: string)
{
	for(i := 0; i < len rs; i++)
		pick r := rs[i] {
		Layer =>
			for(n := r.names; n != nil; n = tl n) {
				nm := hd n;
				if(nm == "")
					nm = sys->sprint("#anon%d", i);
				nm = pfx + nm;
				if(layerpos(ix, nm) < 0)
					ix.layerpos = (nm, ix.nlayers++) :: ix.layerpos;
				if(r.rules != nil)
					findlayers(ix, r.rules, base, nm + ".");
			}
		Media =>
			findlayers(ix, r.rules, base, pfx);
		Supports =>
			findlayers(ix, r.rules, base, pfx);
		Import =>
			if(r.layer != nil) {
				nm := pfx + r.layer;
				if(r.layer == "")
					nm = pfx + "#import" + r.url;
				if(layerpos(ix, nm) < 0)
					ix.layerpos = (nm, ix.nlayers++) :: ix.layerpos;
			}
			if((sh := lookimport(resolveurl(base, r.url))) != nil)
				findlayers(ix, sh.rules, resolveurl(base, r.url), pfx);
		}
}

layerpos(ix: ref Ix, nm: string): int
{
	for(l := ix.layerpos; l != nil; l = tl l)
		if((hd l).t0 == nm)
			return (hd l).t1;
	return -1;
}

# Cascade tiers, before importance is folded in (see tierof).
Tua: con 0;
Thints: con 99;		# presentational hints: below every author style
Tauthor: con 100;	# + layer position; unlayered is highest

indexrules(ix: ref Ix, rs: array of ref Rule, origin: int, layer, base: string, depth: int)
{
	if(depth > 16)
		return;
	for(i := 0; i < len rs; i++)
		pick r := rs[i] {
		Style =>
			tier := Tua;
			if(origin == Author) {
				lp := ix.nlayers;	# unlayered
				if(layer != nil)
					lp = layerpos(ix, layer);
				tier = Tauthor + lp;
			}
			decls := absurls(r.decls, base);
			for(k := 0; k < len r.sels; k++)
				addentry(ix.idx, ref Entry(r.sels[k], decls, tier, ix.order, ancbits(r.sels[k]), 0));
			ix.order++;
		Media =>
			if(mediamatch(r.cond, ix.env))
				indexrules(ix, r.rules, origin, layer, base, depth+1);
		Supports =>
			if(supports(r.cond))
				indexrules(ix, r.rules, origin, layer, base, depth+1);
		Container =>
			indexrules(ix, r.rules, origin, layer, base, depth+1);
		Layer =>
			if(r.rules == nil)
				continue;
			nm := hd r.names;
			if(nm == "")
				nm = sys->sprint("#anon%d", i);
			if(layer != nil)
				nm = layer + "." + nm;
			indexrules(ix, r.rules, origin, nm, base, depth+1);
		Import =>
			u := resolveurl(base, r.url);
			if(!mediamatch(r.cond, ix.env))
				continue;
			if((sh := lookimport(u)) == nil)
				continue;
			l := layer;
			if(r.layer != nil) {
				l = r.layer;
				if(l == "")
					l = "#import" + r.url;
				if(layer != nil)
					l = layer + "." + l;
			}
			indexrules(ix, sh.rules, origin, l, u, depth+1);
		}
}

# Make url() values in declarations absolute against the sheet's address.
absurls(d: array of ref Decl, base: string): array of ref Decl
{
	if(base == nil)
		return d;
	for(i := 0; i < len d; i++)
		if(hasurl(d[i].val)) {
			nd := array[len d] of ref Decl;
			nd[0:] = d;
			for(; i < len d; i++)
				if(hasurl(d[i].val))
					nd[i] = ref Decl(d[i].name, fixurls(d[i].val, base), d[i].important);
			return nd;
		}
	return d;
}

hasurl(v: array of ref Tok): int
{
	for(i := 0; i < len v; i++) {
		if(v[i].kind == Kurl || (v[i].kind == Kfunction && v[i].s == "url"))
			return 1;
		if(v[i].kids != nil && hasurl(v[i].kids))
			return 1;
	}
	return 0;
}

fixurls(v: array of ref Tok, base: string): array of ref Tok
{
	r := array[len v] of ref Tok;
	for(i := 0; i < len v; i++) {
		t := v[i];
		if(t.kind == Kurl)
			t = ref Tok(Kurl, resolveurl(base, t.s), 0.0, 0, nil);
		else if(t.kind == Kfunction && t.s == "url" && len (uk := nows(t.kids)) > 0 && uk[0].kind == Kstring)
			t = ref Tok(Kurl, resolveurl(base, uk[0].s), 0.0, 0, nil);
		else if(t.kids != nil)
			t = ref Tok(t.kind, t.s, t.n, t.flag, fixurls(t.kids, base));
		r[i] = t;
	}
	return r;
}

addentry(idx: ref Index, e: ref Entry)
{
	parts := e.sel.parts;
	last := parts[len parts - 1];
	# a compound that is only :is()/:where() whose every branch names a
	# tag, class or id goes in each of those buckets
	if(len last == 1 && last[0].kind == Css->Spseudo && (last[0].name == "is" || last[0].name == "where")) {
		keys: list of (int, string);
		for(i := 0; i < len last[0].sub; i++) {
			b := last[0].sub[i];
			(k, v) := keyof(b.parts[len b.parts - 1]);
			if(k < 0 || b.pseudo != nil) {
				keys = nil;
				break;
			}
			keys = (k, v) :: keys;
		}
		if(keys != nil) {
			for(; keys != nil; keys = tl keys) {
				(k, v) := hd keys;
				h := strhash(v, Nbucket);
				case k {
				Css->Sid => idx.id[h] = e :: idx.id[h];
				Css->Sclass => idx.class[h] = e :: idx.class[h];
				Css->Stype => idx.tag[h] = e :: idx.tag[h];
				}
			}
			return;
		}
	}
	tag: string;
	for(i := 0; i < len last; i++) {
		x := last[i];
		case x.kind {
		Css->Sid =>
			h := strhash(x.name, Nbucket);
			idx.id[h] = e :: idx.id[h];
			return;
		Css->Stype =>
			tag = x.name;
		}
	}
	for(i = 0; i < len last; i++)
		if(last[i].kind == Css->Sclass) {
			h := strhash(last[i].name, Nbucket);
			idx.class[h] = e :: idx.class[h];
			return;
		}
	if(tag != nil) {
		h := strhash(tag, Nbucket);
		idx.tag[h] = e :: idx.tag[h];
		return;
	}
	idx.other = e :: idx.other;
}

# The most selective key of a compound: (Sid, id), (Sclass, class),
# (Stype, tag), or (-1, nil).
keyof(c: array of ref Simple): (int, string)
{
	k := -1;
	v: string;
	for(i := 0; i < len c; i++)
		case c[i].kind {
		Css->Sid =>
			return (Css->Sid, c[i].name);
		Css->Sclass =>
			if(k != Css->Sclass) {
				k = Css->Sclass;
				v = c[i].name;
			}
		Css->Stype =>
			if(k < 0) {
				k = Css->Stype;
				v = c[i].name;
			}
		}
	return (k, v);
}

# ---- the ancestor filter ----
#
# Each element gets a small Bloom filter of the tags, ids and classes of
# its ancestors.  A selector's compounds that must match ancestors (those
# joined to the subject by descendant and child combinators) contribute
# the bits they require; if the element's filter lacks any, the selector
# cannot match and is skipped without walking the tree.

Nbloom: con 256;	# bits

ancbits(s: ref Sel): array of int
{
	bits: list of int;
	for(k := len s.parts - 1; k > 0; k--) {
		c := s.combs[k];
		if(c != ' ' && c != '>')
			break;
		cp := s.parts[k-1];
		for(i := 0; i < len cp; i++)
			case cp[i].kind {
			Css->Stype =>
				bits = bloomhash("t" + cp[i].name) :: bits;
			Css->Sid =>
				bits = bloomhash("#" + cp[i].name) :: bits;
			Css->Sclass =>
				bits = bloomhash("." + cp[i].name) :: bits;
			}
	}
	if(bits == nil)
		return nil;
	a := array[len bits] of int;
	for(i := 0; bits != nil; bits = tl bits)
		a[i++] = hd bits;
	return a;
}

bloomhash(s: string): int
{
	return strhash(s, Nbloom);
}

# the filter for n's children: n's own filter plus n's features
childfilter(m: ref M, n: int, f: array of int): array of int
{
	c := array[Nbloom/32] of {* => 0};
	if(f != nil)
		c[0:] = f;
	nd := m.d.nodes[n];
	nm := nd.name;
	if(nd.ns != Dom->HTML)
		nm = lower(nm);
	bloomset(c, "t" + nm);
	if((id := m.d.attr(n, "id")) != nil)
		bloomset(c, "#" + id);
	for(cl := classesof(m, n); cl != nil; cl = tl cl)
		if(hd cl != "")
			bloomset(c, "." + hd cl);
	return c;
}

bloomset(f: array of int, s: string)
{
	b := bloomhash(s);
	f[b>>5] |= 1 << (b & 31);
}

bloomok(f, bits: array of int): int
{
	if(f == nil)
		return 0;
	for(i := 0; i < len bits; i++) {
		b := bits[i];
		if((f[b>>5] & (1 << (b & 31))) == 0)
			return 0;
	}
	return 1;
}

# ---- selector matching ----

M: adt {
	d:	ref Doc;
	env:	ref Env;
	classes:	array of list of string;	# per node, lazily
	index:	array of int;	# per node: 1-based index among element siblings, lazily
	count:	array of int;	# per node: number of element children, lazily (+1)
};

matcher(d: ref Doc, env: ref Env): ref M
{
	return ref M(d, env, array[d.n] of list of string, array[d.n] of {* => 0}, array[d.n] of {* => 0});
}

# n's position among its element siblings, from the previous sibling's
# when that is known, so a walk over siblings costs O(1) each.
elindex(m: ref M, n: int): int
{
	if(n < len m.index && m.index[n] != 0)
		return m.index[n];
	i := 1;
	p := prevel(m.d, n);
	if(p != 0)
		i = elindex(m, p) + 1;
	if(n < len m.index)
		m.index[n] = i;
	return i;
}

elcount(m: ref M, parent: int): int
{
	if(parent < len m.count && m.count[parent] != 0)
		return m.count[parent] - 1;
	k := 0;
	for(c := m.d.nodes[parent].first; c != 0; c = m.d.nodes[c].next)
		if(m.d.nodes[c].kind == Dom->Element)
			k++;
	if(parent < len m.count)
		m.count[parent] = k + 1;
	return k;
}

match(d: ref Doc, n: int, sel: ref Sel, env: ref Env): int
{
	if(sys == nil)
		init();
	if(env == nil)
		env = ref Env(1024, 768, 1.0, 0, 0, 0, 0, 0, 0);
	return matchsel(matcher(d, env), sel, n);
}

classesof(m: ref M, n: int): list of string
{
	if(n >= len m.classes) {
		a := array[m.d.n] of list of string;
		a[0:] = m.classes;
		m.classes = a;
	}
	c := m.classes[n];
	if(c == nil) {
		v := m.d.attr(n, "class");
		if(v == nil)
			c = "" :: nil;
		else {
			(nil, c) = sys->tokenize(v, " \t\n\r\f");
			if(c == nil)
				c = "" :: nil;
		}
		m.classes[n] = c;
	}
	return c;
}

hasclass(m: ref M, n: int, cl: string): int
{
	for(l := classesof(m, n); l != nil; l = tl l)
		if(hd l == cl)
			return 1;
	return 0;
}

parentel(d: ref Doc, n: int): int
{
	p := d.nodes[n].parent;
	if(p != 0 && d.nodes[p].kind == Dom->Element)
		return p;
	return 0;
}

prevel(d: ref Doc, n: int): int
{
	for(n = d.nodes[n].prev; n != 0; n = d.nodes[n].prev)
		if(d.nodes[n].kind == Dom->Element)
			return n;
	return 0;
}

nextel(d: ref Doc, n: int): int
{
	for(n = d.nodes[n].next; n != 0; n = d.nodes[n].next)
		if(d.nodes[n].kind == Dom->Element)
			return n;
	return 0;
}

matchsel(m: ref M, s: ref Sel, n: int): int
{
	return matchfrom(m, s, len s.parts - 1, n, 0);
}

# Does compound k (and everything to its left) match at n?  anchor is
# the :has() anchor for relative selectors, else 0.
matchfrom(m: ref M, s: ref Sel, k, n, anchor: int): int
{
	if(!compound(m, s.parts[k], n))
		return 0;
	d := m.d;
	c := s.combs[k];
	if(k == 0) {
		if(anchor == 0 || c == 0)
			return 1;
		# relative selector: relate n to the anchor
		case c {
		' ' =>
			for(p := parentel(d, n); p != 0; p = parentel(d, p))
				if(p == anchor)
					return 1;
		'>' =>
			return parentel(d, n) == anchor;
		'+' =>
			return prevel(d, n) == anchor;
		'~' =>
			for(p := prevel(d, n); p != 0; p = prevel(d, p))
				if(p == anchor)
					return 1;
		}
		return 0;
	}
	case c {
	' ' =>
		for(p := parentel(d, n); p != 0; p = parentel(d, p))
			if(matchfrom(m, s, k-1, p, anchor))
				return 1;
	'>' =>
		if((p := parentel(d, n)) != 0)
			return matchfrom(m, s, k-1, p, anchor);
	'+' =>
		if((p := prevel(d, n)) != 0)
			return matchfrom(m, s, k-1, p, anchor);
	'~' =>
		for(p := prevel(d, n); p != 0; p = prevel(d, p))
			if(matchfrom(m, s, k-1, p, anchor))
				return 1;
	}
	return 0;
}

compound(m: ref M, c: array of ref Simple, n: int): int
{
	d := m.d;
	nd := d.nodes[n];
	for(i := 0; i < len c; i++) {
		x := c[i];
		case x.kind {
		Css->Stype =>
			if(nd.ns == Dom->HTML) {
				if(nd.name != x.name)
					return 0;
			} else if(lower(nd.name) != x.name)
				return 0;
		Css->Suniversal =>
			;
		Css->Sid =>
			if(d.attr(n, "id") != x.name)
				return 0;
		Css->Sclass =>
			if(!hasclass(m, n, x.name))
				return 0;
		Css->Sattr =>
			# not d.attr() != nil: an empty value is nil in Limbo
			if(!d.hasattr(n, x.name) || !matchattr(d.attr(n, x.name), x, !d.xml && htmlcaseless(x.name)))
				return 0;
		Css->Spseudo =>
			if(!pseudo(m, x, n))
				return 0;
		}
	}
	return 1;
}

# HTML attributes whose values are compared case-insensitively in
# HTML documents (Selectors 4 §6.3, the list from HTML §4.17)
htmlcaseless(nm: string): int
{
	case nm {
	"accept" or "accept-charset" or "align" or "alink" or "axis" or "bgcolor" or "charset" or
	"checked" or "clear" or "codetype" or "color" or "compact" or "declare" or "defer" or "dir" or
	"direction" or "disabled" or "enctype" or "face" or "frame" or "hreflang" or "http-equiv" or
	"lang" or "language" or "link" or "media" or "method" or "multiple" or "nohref" or "noresize" or
	"noshade" or "nowrap" or "readonly" or "rel" or "rev" or "rules" or "scope" or "scrolling" or
	"selected" or "shape" or "target" or "text" or "type" or "valign" or "valuetype" or "vlink" =>
		return 1;
	}
	return 0;
}

matchattr(v: string, x: ref Simple, caseless: int): int
{
	want := x.val;
	if(x.icase || caseless) {
		v = lower(v);
		want = lower(want);
	}
	case x.op {
	Css->Aexists =>
		return 1;
	Css->Aequals =>
		return v == want;
	Css->Aword =>
		if(want == "")
			return 0;
		(nil, l) := sys->tokenize(v, " \t\n\r\f");
		for(; l != nil; l = tl l)
			if(hd l == want)
				return 1;
		return 0;
	Css->Adash =>
		return v == want || prefix(v, want + "-");
	Css->Aprefix =>
		return want != "" && prefix(v, want);
	Css->Asuffix =>
		return want != "" && len v >= len want && v[len v - len want:] == want;
	Css->Asubstr =>
		return want != "" && index(v, want, 0) >= 0;
	}
	return 0;
}

pseudo(m: ref M, x: ref Simple, n: int): int
{
	d := m.d;
	nd := d.nodes[n];
	case x.name {
	"root" or "scope" =>
		return parentel(d, n) == 0;
	"is" or "where" =>
		for(i := 0; i < len x.sub; i++)
			if(matchsel(m, x.sub[i], n))
				return 1;
		return 0;
	"not" =>
		for(i := 0; i < len x.sub; i++)
			if(matchsel(m, x.sub[i], n))
				return 0;
		return 1;
	"has" =>
		return has(m, x.sub, n);
	"empty" =>
		for(c := nd.first; c != 0; c = d.nodes[c].next) {
			k := d.nodes[c].kind;
			if(k == Dom->Element || (k == Dom->Text && d.nodes[c].text != ""))
				return 0;
		}
		return 1;
	"first-child" =>
		return elindex(m, n) == 1;
	"last-child" =>
		return nextel(d, n) == 0;
	"only-child" =>
		return prevel(d, n) == 0 && nextel(d, n) == 0;
	"first-of-type" =>
		for(p := prevel(d, n); p != 0; p = prevel(d, p))
			if(d.nodes[p].name == nd.name)
				return 0;
		return 1;
	"last-of-type" =>
		for(p := nextel(d, n); p != 0; p = nextel(d, p))
			if(d.nodes[p].name == nd.name)
				return 0;
		return 1;
	"only-of-type" =>
		for(p := prevel(d, n); p != 0; p = prevel(d, p))
			if(d.nodes[p].name == nd.name)
				return 0;
		for(p = nextel(d, n); p != 0; p = nextel(d, p))
			if(d.nodes[p].name == nd.name)
				return 0;
		return 1;
	"nth-child" or "nth-last-child" or "nth-of-type" or "nth-last-of-type" =>
		if(x.sub != nil && !anymatch(m, x.sub, n))
			return 0;
		idx := 1;
		back := x.name == "nth-last-child" || x.name == "nth-last-of-type";
		oftype := x.name == "nth-of-type" || x.name == "nth-last-of-type";
		if(!oftype && x.sub == nil) {
			idx = elindex(m, n);
			if(back)
				idx = elcount(m, nd.parent) - idx + 1;
			return nth(x.a, x.b, idx);
		}
		p: int;
		if(back)
			p = nextel(d, n);
		else
			p = prevel(d, n);
		while(p != 0) {
			if(oftype) {
				if(d.nodes[p].name == nd.name)
					idx++;
			} else if(x.sub == nil || anymatch(m, x.sub, p))
				idx++;
			if(back)
				p = nextel(d, p);
			else
				p = prevel(d, p);
		}
		return nth(x.a, x.b, idx);
	"link" or "any-link" =>
		return islink(nd);
	"visited" =>
		return 0;
	"hover" =>
		return contains(d, n, m.env.hover);
	"active" =>
		return contains(d, n, m.env.active);
	"focus" or "focus-visible" =>
		return n == m.env.focus;
	"focus-within" =>
		return contains(d, n, m.env.focus);
	"target" =>
		return n == m.env.target;
	"target-within" =>
		return contains(d, n, m.env.target);
	"checked" =>
		case nd.tag {
		Dom->Tinput =>
			t := lower(d.attr(n, "type"));
			return (t == "checkbox" || t == "radio") && d.hasattr(n, "checked");
		Dom->Toption =>
			return d.hasattr(n, "selected");
		}
		return 0;
	"disabled" =>
		return formcontrol(nd) && d.hasattr(n, "disabled");
	"enabled" =>
		return formcontrol(nd) && !d.hasattr(n, "disabled");
	"required" =>
		return formcontrol(nd) && d.hasattr(n, "required");
	"optional" =>
		return formcontrol(nd) && !d.hasattr(n, "required");
	"read-only" =>
		return !editable(d, n);
	"read-write" =>
		return editable(d, n);
	"placeholder-shown" =>
		return (nd.tag == Dom->Tinput || nd.tag == Dom->Ttextarea) &&
			d.hasattr(n, "placeholder") && d.attr(n, "value") == "";
	"popover-open" =>
		# opened by its invoker (browser.b): a mark markup cannot make
		return d.hasattr(n, "popover") && d.hasattr(n, Dom->POPOPEN);
	"open" =>
		return d.hasattr(n, "open");
	"closed" =>
		return !d.hasattr(n, "open");
	"defined" or "valid" or "in-range" or "user-valid" =>
		return 1;
	"lang" =>
		for(p := n; p != 0; p = parentel(d, p)) {
			l := d.attr(p, "lang");
			if(l == nil)
				l = d.attr(p, "xml:lang");	# XHTML
			if(l != nil)
				return langmatch(lower(l), x.val);
		}
		if(d.lang != nil)
			return langmatch(lower(d.lang), x.val);	# the document's, from <meta http-equiv> (lang-selector-006)
		return 0;
	"dir" =>
		return lower(x.val) == "ltr";
	"host" or "host-context" or "state" =>
		return 0;
	}
	return 0;
}

# :lang(<ranges>): the tag against each comma-separated language range,
# quoted or not, by extended filtering (Selectors 4 §14.1, RFC 4647
# §3.3.2): the primary subtags agree (or the range's is *), and the
# range's remaining subtags appear in order in the tag, skipping tag
# subtags that are not singletons.
langmatch(tag, ranges: string): int
{
	for(rl := splitlist(ranges); rl != nil; rl = tl rl) {
		r := lower(trim1(hd rl));
		if(len r >= 2 && (r[0] == '"' || r[0] == '\''))
			r = r[1:len r - 1];
		if(r == "")
			continue;
		if(r != "*" && !(r[0] >= 'a' && r[0] <= 'z'))
			return 0;	# not a language range (BCP 47 starts with a letter): the selector is invalid
		if(tag == "")
			continue;	# lang="": no language, matched by nothing
		rs := subtags(r);
		ts := subtags(tag);
		if(rs == nil || ts == nil)
			continue;
		if(hd rs != "*" && hd rs != hd ts)
			continue;
		rs = tl rs;
		ts = tl ts;
		ok := 1;
		while(rs != nil) {
			if(hd rs == "*") {
				rs = tl rs;
				continue;
			}
			if(ts == nil) {
				ok = 0;
				break;
			}
			if(hd rs == hd ts) {
				rs = tl rs;
				ts = tl ts;
				continue;
			}
			if(len hd ts == 1) {
				ok = 0;	# a singleton: an extension starts here
				break;
			}
			ts = tl ts;
		}
		if(ok)
			return 1;
	}
	return 0;
}

subtags(s: string): list of string
{
	r: list of string;
	st := 0;
	for(i := 0; i <= len s; i++)
		if(i == len s || s[i] == '-') {
			r = s[st:i] :: r;
			st = i + 1;
		}
	o: list of string;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

splitlist(s: string): list of string
{
	r: list of string;
	st := 0;
	for(i := 0; i <= len s; i++)
		if(i == len s || s[i] == ',') {
			r = s[st:i] :: r;
			st = i + 1;
		}
	o: list of string;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

trim1(s: string): string
{
	a := 0;
	b := len s;
	while(a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n'))
		a++;
	while(b > a && (s[b-1] == ' ' || s[b-1] == '\t' || s[b-1] == '\n'))
		b--;
	return s[a:b];
}

anymatch(m: ref M, l: array of ref Sel, n: int): int
{
	for(i := 0; i < len l; i++)
		if(matchsel(m, l[i], n))
			return 1;
	return 0;
}

nth(a, b, idx: int): int
{
	if(a == 0)
		return idx == b;
	k := idx - b;
	return k % a == 0 && k / a >= 0;
}

# is n an inclusive ancestor of t?
contains(d: ref Doc, n, t: int): int
{
	for(; t != 0; t = d.nodes[t].parent)
		if(t == n)
			return 1;
	return 0;
}

islink(nd: ref Node): int
{
	if(nd.ns != Dom->HTML || (nd.tag != Dom->Ta && nd.tag != Dom->Tarea))
		return 0;
	for(l := nd.attrs; l != nil; l = tl l)
		if((hd l).t0 == "href")
			return 1;
	return 0;
}

formcontrol(nd: ref Node): int
{
	case nd.tag {
	Dom->Tinput or Dom->Tbutton or Dom->Tselect or Dom->Ttextarea or
	Dom->Toption or Dom->Toptgroup or Dom->Tfieldset =>
		return nd.ns == Dom->HTML;
	}
	return 0;
}

editable(d: ref Doc, n: int): int
{
	nd := d.nodes[n];
	if(nd.tag == Dom->Ttextarea || nd.tag == Dom->Tinput)
		return !d.hasattr(n, "readonly") && !d.hasattr(n, "disabled");
	ce := d.attr(n, "contenteditable");
	return ce != nil && lower(ce) != "false";
}

# :has(): some element relative to n matches one of the selectors
has(m: ref M, l: array of ref Sel, n: int): int
{
	d := m.d;
	for(i := 0; i < len l; i++) {
		s := l[i];
		c := s.combs[0];
		# candidates: descendants for ' ' and '>', later siblings and
		# their descendants for '+' and '~'
		if(c == '+' || c == '~') {
			for(sib := nextel(d, n); sib != 0; sib = nextel(d, sib))
				if(hassub(m, s, sib, sib, n))
					return 1;
		} else if(hassub(m, s, n, 0, n))
			return 1;
	}
	return 0;
}

# check the subtree of top (and top itself if incl != 0)
hassub(m: ref M, s: ref Sel, top, incl, anchor: int): int
{
	d := m.d;
	if(incl != 0 && matchfrom(m, s, len s.parts - 1, incl, anchor))
		return 1;
	for(c := d.nodes[top].first; c != 0; c = next(d, c, top))
		if(d.nodes[c].kind == Dom->Element && matchfrom(m, s, len s.parts - 1, c, anchor))
			return 1;
	return 0;
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

# ---- media queries (Media Queries 4) ----

mediamatch(q: array of ref Tok, env: ref Env): int
{
	if(len q == 0)
		return 1;
	if(env == nil)
		return 1;
	for(l := splitcommas(q); l != nil; l = tl l)
		if(onequery(trim(hd l), env))
			return 1;
	return 0;
}

onequery(v: array of ref Tok, env: ref Env): int
{
	i := 0;
	v = nows(v);
	if(len v == 0)
		return 0;
	neg := 0;
	if(v[0].kind == Kident) {
		case lower(v[0].s) {
		"not" =>
			neg = 1;
			i++;
		"only" =>
			i++;
		}
	}
	ok := 1;
	if(i < len v && v[i].kind == Kident) {
		case lower(v[i].s) {
		"all" =>
			;
		"screen" =>
			ok = !env.print;
		"print" =>
			ok = env.print;
		* =>
			ok = 0;
		}
		i++;
		if(i < len v && v[i].kind == Kident && lower(v[i].s) == "and")
			i++;
	}
	if(i < len v)
		ok = ok && condition(v[i:], env, 1);
	if(neg)
		return !ok;
	return ok;
}

# <media-condition>: features joined by and/or, with not and parentheses.
# media: 1 for media features, 0 for @supports conditions
condition(v: array of ref Tok, env: ref Env, media: int): int
{
	v = nows(v);
	if(len v == 0)
		return 0;
	if(v[0].kind == Kident && lower(v[0].s) == "not")
		return !condition(v[1:], env, media);
	res := -1;
	op := "";
	for(i := 0; i < len v; i++) {
		t := v[i];
		r: int;
		if(t.kind == Kblock && t.s == "(")
			r = inparens(t.kids, env, media);
		else if(t.kind == Kfunction && !media && t.s == "selector")
			r = css->parsesels(css->tostring(t.kids)) != nil;
		else if(t.kind == Kident && (lower(t.s) == "and" || lower(t.s) == "or")) {
			op = lower(t.s);
			continue;
		} else
			return 0;
		if(res < 0)
			res = r;
		else if(op == "or")
			res = res || r;
		else
			res = res && r;
	}
	return res > 0;
}

inparens(v: array of ref Tok, env: ref Env, media: int): int
{
	v = nows(v);
	if(len v == 0)
		return 0;
	# a nested condition?
	if(v[0].kind == Kblock || (v[0].kind == Kident && lower(v[0].s) == "not"))
		return condition(v, env, media);
	if(!media)
		return supportsdecl(v);
	return feature(v, env);
}

feature(v: array of ref Tok, env: ref Env): int
{
	# name, name: value, or a range: name op value, value op name, value op name op value
	if(len v == 1 && v[0].kind == Kident)
		return boolfeature(lower(v[0].s), env);
	if(len v >= 3 && v[0].kind == Kident && v[1].kind == Kcolon) {
		nm := lower(v[0].s);
		val := v[2:];
		if(prefix(nm, "min-"))
			return cmpfeature(nm[4:], ">=", val, env);
		if(prefix(nm, "max-"))
			return cmpfeature(nm[4:], "<=", val, env);
		return cmpfeature(nm, "=", val, env);
	}
	# range syntax
	ops: list of (int, string);
	for(i := 0; i < len v; i++)
		if(v[i].kind == Kdelim && (v[i].s == "<" || v[i].s == ">" || v[i].s == "=")) {
			o := v[i].s;
			if(i+1 < len v && v[i+1].kind == Kdelim && v[i+1].s == "=") {
				o += "=";
				i++;
			}
			ops = (i, o) :: ops;
		}
	if(len ops == 1) {
		(at, o) := hd ops;
		st := at - len o + 1;
		if(v[0].kind == Kident && st == 1)
			return cmpfeature(lower(v[0].s), o, v[at+1:], env);
		if(v[len v-1].kind == Kident)
			return cmpfeature(lower(v[len v-1].s), flip(o), v[0:st], env);
		return 0;
	}
	if(len ops == 2) {
		(at2, o2) := hd ops;
		(at1, o1) := hd tl ops;
		st1 := at1 - len o1 + 1;
		st2 := at2 - len o2 + 1;
		if(st2 - (at1+1) != 1 || v[at1+1].kind != Kident)
			return 0;
		nm := lower(v[at1+1].s);
		return cmpfeature(nm, flip(o1), v[0:st1], env) && cmpfeature(nm, o2, v[at2+1:], env);
	}
	return 0;
}

flip(o: string): string
{
	case o {
	"<" => return ">";
	">" => return "<";
	"<=" => return ">=";
	">=" => return "<=";
	}
	return o;
}

boolfeature(nm: string, env: ref Env): int
{
	case nm {
	"color" or "hover" or "pointer" or "any-hover" or "any-pointer" or "width" or "height" or "grid" =>
		return nm != "grid";
	"monochrome" or "inverted-colors" or "forced-colors" or "prefers-reduced-motion" or
	"prefers-reduced-transparency" or "prefers-contrast" or "scripting" =>
		return 0;
	}
	return 0;
}

cmpfeature(nm, op: string, val: array of ref Tok, env: ref Env): int
{
	val = nows(val);
	if(len val == 0)
		return 0;
	v0 := val[0];
	case nm {
	"width" or "height" or "device-width" or "device-height" =>
		have := real env.width;
		if(nm == "height" || nm == "device-height")
			have = real env.height;
		(ok, l) := length(val, ref Ctx(16.0, 16.0, 19.2, env, 0, nil, 400, 0));
		if(!ok || l.kind != Lpx)
			return 0;
		return cmp(have, op, l.px);
	"aspect-ratio" or "device-aspect-ratio" =>
		if(len val < 1 || v0.kind != Knumber)
			return 0;
		r := v0.n;
		if(len val >= 3 && val[1].kind == Kdelim && val[1].s == "/" && val[2].kind == Knumber && val[2].n != 0.0)
			r = v0.n / val[2].n;
		return cmp(real env.width / real env.height, op, r);
	"orientation" =>
		o := "landscape";
		if(env.height >= env.width)
			o = "portrait";
		return v0.kind == Kident && lower(v0.s) == o;
	"prefers-color-scheme" =>
		s := "light";
		if(env.dark)
			s = "dark";
		return v0.kind == Kident && lower(v0.s) == s;
	"prefers-reduced-motion" or "prefers-reduced-transparency" or "prefers-reduced-data" =>
		return v0.kind == Kident && lower(v0.s) == "no-preference";
	"prefers-contrast" or "forced-colors" or "inverted-colors" =>
		return v0.kind == Kident && (lower(v0.s) == "no-preference" || lower(v0.s) == "none");
	"hover" or "any-hover" =>
		return v0.kind == Kident && lower(v0.s) == "hover";
	"pointer" or "any-pointer" =>
		return v0.kind == Kident && lower(v0.s) == "fine";
	"resolution" or "min-resolution" or "max-resolution" =>
		dppx := 1.0;
		case v0.kind {
		Kdimension =>
			case v0.s {
			"dppx" or "x" => dppx = v0.n;
			"dpi" => dppx = v0.n / 96.0;
			"dpcm" => dppx = v0.n * 2.54 / 96.0;
			}
		* =>
			return 0;
		}
		return cmp(env.dpr, op, dppx);
	"-webkit-device-pixel-ratio" or "-webkit-min-device-pixel-ratio" or "-webkit-max-device-pixel-ratio" =>
		if(v0.kind != Knumber)
			return 0;
		return cmp(env.dpr, op, v0.n);
	"color" =>
		return v0.kind == Knumber && cmp(8.0, op, v0.n);
	"color-gamut" =>
		return v0.kind == Kident && lower(v0.s) == "srgb";
	"display-mode" =>
		return v0.kind == Kident && lower(v0.s) == "browser";
	"scripting" =>
		return v0.kind == Kident && lower(v0.s) == "none";
	"update" =>
		return v0.kind == Kident && lower(v0.s) == "fast";
	"grid" or "monochrome" =>
		return v0.kind == Knumber && cmp(0.0, op, v0.n);
	}
	return 0;
}

cmp(have: real, op: string, want: real): int
{
	case op {
	"=" => return have == want;
	"<" => return have < want;
	">" => return have > want;
	"<=" => return have <= want;
	">=" => return have >= want;
	}
	return 0;
}

# ---- @supports ----

supports(cond: array of ref Tok): int
{
	return condition(cond, nil, 0);
}

# (property: value): supported if the property is known and the value
# parses for it.
supportsdecl(v: array of ref Tok): int
{
	if(len v < 3 || v[0].kind != Kident || v[1].kind != Kcolon)
		return 0;
	nm := lower(v[0].s);
	if(prefix(nm, "--"))
		return 1;
	for(k := 2; k < len v; k++)
		if(v[k].kind == Kfunction && v[k].s == "var")
			return css->validvars(v[2:]);	# a var() makes any value valid at parse time, unless it is malformed itself (Variables 1 §3; variable-supports-09)
	s := St.new();
	ctx := ref Ctx(16.0, 16.0, 19.2, ref Env(1024, 768, 1.0, 0, 0, 0, 0, 0, 0), 0, nil, 400, 0);
	lh := longhands(nm, trim(v[2:]));
	if(lh == nil)
		return 0;
	for(; lh != nil; lh = tl lh) {
		(n, val) := hd lh;
		if(!apply(s, n, val, St.new(), ctx))
			return 0;
	}
	return 1;
}

# ---- URLs (RFC 3986 §5.2) ----

resolveurl(base, rel: string): string
{
	if(rel == nil || base == nil)
		return rel;
	# absolute already?
	for(i := 0; i < len rel; i++) {
		c := rel[i];
		if(c == ':')
			return rel;
		if(!(isalnum(c) || c == '+' || c == '-' || c == '.'))
			break;
	}
	(scheme, auth, path, query) := spliturl(base);
	if(prefix(rel, "//"))
		return scheme + ":" + rel;
	if(rel == "")
		return base;
	if(rel[0] == '#') {
		e := index(base, "#", 0);
		if(e >= 0)
			base = base[0:e];
		return base + rel;
	}
	if(rel[0] == '?')
		return scheme + ":" + auth + path + rel;
	if(rel[0] == '/')
		return scheme + ":" + auth + dotsegs(rel);
	query = nil;
	d := path;
	for(i = len d - 1; i >= 0; i--)
		if(d[i] == '/')
			break;
	d = d[0:i+1];
	if(d == "" && auth != "")
		d = "/";
	return scheme + ":" + auth + dotsegs(d + rel);
}

# (scheme, "//authority" or "", path, "?query")
spliturl(u: string): (string, string, string, string)
{
	e := index(u, "#", 0);
	if(e >= 0)
		u = u[0:e];
	c := index(u, ":", 0);
	scheme := "";
	if(c > 0) {
		scheme = u[0:c];
		u = u[c+1:];
	}
	auth := "";
	if(prefix(u, "//")) {
		k := 2;
		while(k < len u && u[k] != '/' && u[k] != '?')
			k++;
		auth = u[0:k];
		u = u[k:];
	}
	q := index(u, "?", 0);
	query := "";
	if(q >= 0) {
		query = u[q:];
		u = u[0:q];
	}
	return (scheme, auth, u, query);
}

dotsegs(p: string): string
{
	q := "";
	e := index(p, "?", 0);
	if(e < 0)
		e = index(p, "#", 0);
	if(e >= 0) {
		q = p[e:];
		p = p[0:e];
	}
	# RFC 3986 §5.2.4; an empty segment is a segment (a//b stays)
	if(p == "" || p[0] != '/')
		p = "/" + p;
	out: list of string;
	s := 1;
	for(i := 1; i <= len p; i++) {
		if(i < len p && p[i] != '/')
			continue;
		seg := p[s:i];
		last := i == len p;
		s = i + 1;
		case seg {
		"." =>
			if(last)
				out = "" :: out;
		".." =>
			if(out != nil)
				out = tl out;
			if(last)
				out = "" :: out;
		* =>
			out = seg :: out;
		}
	}
	r := "";
	for(; out != nil; out = tl out)
		r = "/" + hd out + r;
	if(r == "")
		r = "/";
	return r + q;
}

suffix(s, t: string): int
{
	return len s >= len t && s[len s - len t:] == t;
}

# ---- small things ----

strhash(s: string, m: int): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h*31 + s[i];
	return (h & 16r7FFFFFFF) % m;
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

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

index(s, t: string, from: int): int
{
	n := len t;
	for(i := from; i+n <= len s; i++)
		if(s[i] == t[0] && s[i:i+n] == t)
			return i;
	return -1;
}

isalnum(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

trim(v: array of ref Tok): array of ref Tok
{
	i := 0;
	while(i < len v && v[i].kind == Kws)
		i++;
	e := len v;
	while(e > i && v[e-1].kind == Kws)
		e--;
	return v[i:e];
}

# v split at its commas
commas(v: array of ref Tok): list of array of ref Tok
{
	r: list of array of ref Tok;
	st := 0;
	for(i := 0; i <= len v; i++)
		if(i == len v || v[i].kind == Kcomma) {
			r = v[st:i] :: r;
			st = i+1;
		}
	o: list of array of ref Tok;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# v without whitespace tokens
nows(v: array of ref Tok): array of ref Tok
{
	n := 0;
	for(i := 0; i < len v; i++)
		if(v[i].kind != Kws)
			n++;
	if(n == len v)
		return v;
	r := array[n] of ref Tok;
	n = 0;
	for(i = 0; i < len v; i++)
		if(v[i].kind != Kws)
			r[n++] = v[i];
	return r;
}

splitcommas(v: array of ref Tok): list of array of ref Tok
{
	r: list of array of ref Tok;
	st := 0;
	for(i := 0; i <= len v; i++)
		if(i == len v || v[i].kind == Kcomma) {
			r = v[st:i] :: r;
			st = i+1;
		}
	o: list of array of ref Tok;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}
# named colours (CSS Color 4 §6.1) and system colours, the deprecated ones
# as the colours they are defined to equal (Appendix A), sorted for binary search
colornames := array[] of {
	("accentcolor", int 16r2266CCFF),
	("accentcolortext", int 16rFFFFFFFF),
	("activeborder", int 16r767676FF),
	("activecaption", int 16rFFFFFFFF),
	("activetext", int 16rFF0000FF),
	("aliceblue", int 16rF0F8FFFF),
	("antiquewhite", int 16rFAEBD7FF),
	("appworkspace", int 16rFFFFFFFF),
	("aqua", int 16r00FFFFFF),
	("aquamarine", int 16r7FFFD4FF),
	("azure", int 16rF0FFFFFF),
	("background", int 16rFFFFFFFF),
	("beige", int 16rF5F5DCFF),
	("bisque", int 16rFFE4C4FF),
	("black", int 16r000000FF),
	("blanchedalmond", int 16rFFEBCDFF),
	("blue", int 16r0000FFFF),
	("blueviolet", int 16r8A2BE2FF),
	("brown", int 16rA52A2AFF),
	("burlywood", int 16rDEB887FF),
	("buttonborder", int 16r767676FF),
	("buttonface", int 16rEFEFEFFF),
	("buttonhighlight", int 16rEFEFEFFF),
	("buttonshadow", int 16rEFEFEFFF),
	("buttontext", int 16r000000FF),
	("cadetblue", int 16r5F9EA0FF),
	("canvas", int 16rFFFFFFFF),
	("canvastext", int 16r000000FF),
	("captiontext", int 16r000000FF),
	("chartreuse", int 16r7FFF00FF),
	("chocolate", int 16rD2691EFF),
	("coral", int 16rFF7F50FF),
	("cornflowerblue", int 16r6495EDFF),
	("cornsilk", int 16rFFF8DCFF),
	("crimson", int 16rDC143CFF),
	("cyan", int 16r00FFFFFF),
	("darkblue", int 16r00008BFF),
	("darkcyan", int 16r008B8BFF),
	("darkgoldenrod", int 16rB8860BFF),
	("darkgray", int 16rA9A9A9FF),
	("darkgreen", int 16r006400FF),
	("darkgrey", int 16rA9A9A9FF),
	("darkkhaki", int 16rBDB76BFF),
	("darkmagenta", int 16r8B008BFF),
	("darkolivegreen", int 16r556B2FFF),
	("darkorange", int 16rFF8C00FF),
	("darkorchid", int 16r9932CCFF),
	("darkred", int 16r8B0000FF),
	("darksalmon", int 16rE9967AFF),
	("darkseagreen", int 16r8FBC8FFF),
	("darkslateblue", int 16r483D8BFF),
	("darkslategray", int 16r2F4F4FFF),
	("darkslategrey", int 16r2F4F4FFF),
	("darkturquoise", int 16r00CED1FF),
	("darkviolet", int 16r9400D3FF),
	("deeppink", int 16rFF1493FF),
	("deepskyblue", int 16r00BFFFFF),
	("dimgray", int 16r696969FF),
	("dimgrey", int 16r696969FF),
	("dodgerblue", int 16r1E90FFFF),
	("field", int 16rFFFFFFFF),
	("fieldtext", int 16r000000FF),
	("firebrick", int 16rB22222FF),
	("floralwhite", int 16rFFFAF0FF),
	("forestgreen", int 16r228B22FF),
	("fuchsia", int 16rFF00FFFF),
	("gainsboro", int 16rDCDCDCFF),
	("ghostwhite", int 16rF8F8FFFF),
	("gold", int 16rFFD700FF),
	("goldenrod", int 16rDAA520FF),
	("gray", int 16r808080FF),
	("graytext", int 16r808080FF),
	("green", int 16r008000FF),
	("greenyellow", int 16rADFF2FFF),
	("grey", int 16r808080FF),
	("highlight", int 16r3390FFFF),
	("highlighttext", int 16rFFFFFFFF),
	("honeydew", int 16rF0FFF0FF),
	("hotpink", int 16rFF69B4FF),
	("inactiveborder", int 16r767676FF),
	("inactivecaption", int 16rFFFFFFFF),
	("inactivecaptiontext", int 16r808080FF),
	("indianred", int 16rCD5C5CFF),
	("indigo", int 16r4B0082FF),
	("infobackground", int 16rFFFFFFFF),
	("infotext", int 16r000000FF),
	("ivory", int 16rFFFFF0FF),
	("khaki", int 16rF0E68CFF),
	("lavender", int 16rE6E6FAFF),
	("lavenderblush", int 16rFFF0F5FF),
	("lawngreen", int 16r7CFC00FF),
	("lemonchiffon", int 16rFFFACDFF),
	("lightblue", int 16rADD8E6FF),
	("lightcoral", int 16rF08080FF),
	("lightcyan", int 16rE0FFFFFF),
	("lightgoldenrodyellow", int 16rFAFAD2FF),
	("lightgray", int 16rD3D3D3FF),
	("lightgreen", int 16r90EE90FF),
	("lightgrey", int 16rD3D3D3FF),
	("lightpink", int 16rFFB6C1FF),
	("lightsalmon", int 16rFFA07AFF),
	("lightseagreen", int 16r20B2AAFF),
	("lightskyblue", int 16r87CEFAFF),
	("lightslategray", int 16r778899FF),
	("lightslategrey", int 16r778899FF),
	("lightsteelblue", int 16rB0C4DEFF),
	("lightyellow", int 16rFFFFE0FF),
	("lime", int 16r00FF00FF),
	("limegreen", int 16r32CD32FF),
	("linen", int 16rFAF0E6FF),
	("linktext", int 16r0000EEFF),
	("magenta", int 16rFF00FFFF),
	("mark", int 16rFFFF00FF),
	("marktext", int 16r000000FF),
	("maroon", int 16r800000FF),
	("mediumaquamarine", int 16r66CDAAFF),
	("mediumblue", int 16r0000CDFF),
	("mediumorchid", int 16rBA55D3FF),
	("mediumpurple", int 16r9370DBFF),
	("mediumseagreen", int 16r3CB371FF),
	("mediumslateblue", int 16r7B68EEFF),
	("mediumspringgreen", int 16r00FA9AFF),
	("mediumturquoise", int 16r48D1CCFF),
	("mediumvioletred", int 16rC71585FF),
	("menu", int 16rFFFFFFFF),
	("menutext", int 16r000000FF),
	("midnightblue", int 16r191970FF),
	("mintcream", int 16rF5FFFAFF),
	("mistyrose", int 16rFFE4E1FF),
	("moccasin", int 16rFFE4B5FF),
	("navajowhite", int 16rFFDEADFF),
	("navy", int 16r000080FF),
	("oldlace", int 16rFDF5E6FF),
	("olive", int 16r808000FF),
	("olivedrab", int 16r6B8E23FF),
	("orange", int 16rFFA500FF),
	("orangered", int 16rFF4500FF),
	("orchid", int 16rDA70D6FF),
	("palegoldenrod", int 16rEEE8AAFF),
	("palegreen", int 16r98FB98FF),
	("paleturquoise", int 16rAFEEEEFF),
	("palevioletred", int 16rDB7093FF),
	("papayawhip", int 16rFFEFD5FF),
	("peachpuff", int 16rFFDAB9FF),
	("peru", int 16rCD853FFF),
	("pink", int 16rFFC0CBFF),
	("plum", int 16rDDA0DDFF),
	("powderblue", int 16rB0E0E6FF),
	("purple", int 16r800080FF),
	("rebeccapurple", int 16r663399FF),
	("red", int 16rFF0000FF),
	("rosybrown", int 16rBC8F8FFF),
	("royalblue", int 16r4169E1FF),
	("saddlebrown", int 16r8B4513FF),
	("salmon", int 16rFA8072FF),
	("sandybrown", int 16rF4A460FF),
	("scrollbar", int 16rFFFFFFFF),
	("seagreen", int 16r2E8B57FF),
	("seashell", int 16rFFF5EEFF),
	("selecteditem", int 16r3390FFFF),
	("selecteditemtext", int 16rFFFFFFFF),
	("sienna", int 16rA0522DFF),
	("silver", int 16rC0C0C0FF),
	("skyblue", int 16r87CEEBFF),
	("slateblue", int 16r6A5ACDFF),
	("slategray", int 16r708090FF),
	("slategrey", int 16r708090FF),
	("snow", int 16rFFFAFAFF),
	("springgreen", int 16r00FF7FFF),
	("steelblue", int 16r4682B4FF),
	("tan", int 16rD2B48CFF),
	("teal", int 16r008080FF),
	("thistle", int 16rD8BFD8FF),
	("threeddarkshadow", int 16r767676FF),
	("threedface", int 16rEFEFEFFF),
	("threedhighlight", int 16r767676FF),
	("threedlightshadow", int 16r767676FF),
	("threedshadow", int 16r767676FF),
	("tomato", int 16rFF6347FF),
	("turquoise", int 16r40E0D0FF),
	("violet", int 16rEE82EEFF),
	("visitedtext", int 16r551A8BFF),
	("wheat", int 16rF5DEB3FF),
	("white", int 16rFFFFFFFF),
	("whitesmoke", int 16rF5F5F5FF),
	("window", int 16rFFFFFFFF),
	("windowframe", int 16r767676FF),
	("windowtext", int 16r000000FF),
	("yellow", int 16rFFFF00FF),
	("yellowgreen", int 16r9ACD32FF),
};

# ---- initial values ----

initial: ref St;

St.new(): ref St
{
	z := px(0.0);
	a := kw(Lauto);
	nogrid := Gline(0, 0, nil);
	return ref St(
		Dinline, Pstatic, Fnone, Cnone, 0,
		a, a, a, a, kw(Lnone), kw(Lnone), 0.0,
		z, z, z, z,
		z, z, z, z,
		3, 3, 3, 3,
		Bnone, Bnone, Bnone, Bnone,
		Ccurrent, Ccurrent, Ccurrent, Ccurrent,
		z, z, z, z,
		a, a, a, a,
		0, 1,
		Ovisible, Ovisible,
		Vvisible,
		1.0,
		int 16r000000FF,
		Ctransparent,
		nil, nil,
		3, Bnone, Ccurrent, 0,
		"serif" :: nil, 16.0, 400, FSnormal, 0,
		kw(Lnormal),
		Astart, Aauto,
		z,
		TTnone,
		0.0, 0.0,
		Wnormal, 0, 0, 0, 0,
		0, Ccurrent, 0,
		VAbaseline, z,
		nil,
		0,
		8.0,
		"disc", 0, nil,
		nil, nil, nil, nil, nil,
		0, 0,
		ALnormal, ALnormal, ALauto, ALnormal, ALnormal, ALauto,
		0.0, 1.0,
		a,
		0,
		kw(Lnormal), kw(Lnormal),
		nil, nil, nil, nil, nil, 0,
		nogrid, nogrid, nogrid, nogrid, nil,
		0, 0, 0.0, 0.0, 0, 0,	# border-spacing: 0 (the UA sheet gives <table> 2px)
		0, a, 3, Bnone, Ccurrent,
		0, "auto", 1, 1, 0, Ccurrent,
		nil, 0, 0, UBnormal, 0,
		0, z, z, nil, Len(Lpx, 0.0, 50.0, nil), Len(Lpx, 0.0, 50.0, nil), 0,
		0, 0, kw(Lnormal), 0, 0, 0, 0, 0, kw(Lnone), kw(Lnone), 0, nil, 0, 1, "\u2010", 0, 0, 1, 0, nil, nil, nil, nil, 0, nil, 100.0, 0.0, 3);
}

nextsid := 1;

# A new style inheriting the inherited properties of p.
inherit(p: ref St): ref St
{
	s := ref *initial;
	s.sid = nextsid++;
	if(p == nil)
		return s;
	s.color = p.color;
	s.dark = p.dark;
	s.family = p.family;
	s.fontsize = p.fontsize;
	s.weight = p.weight;
	s.fontstyle = p.fontstyle;
	s.stretch = p.stretch;
	s.slant = p.slant;
	s.synth = p.synth;
	s.smallcaps = p.smallcaps;
	s.lineheight = p.lineheight;
	s.align = p.align;
	s.alignlast = p.alignlast;
	s.indent = p.indent;
	s.transform = p.transform;
	s.letterspacing = p.letterspacing;
	s.nokern = p.nokern;
	s.fontvars = p.fontvars;
	s.wordspacing = p.wordspacing;
	s.whitespace = p.whitespace;
	s.breakall = p.breakall;
	s.keepall = p.keepall;
	s.anywhere = p.anywhere;
	s.lbmode = p.lbmode;
	s.wst = p.wst;
	s.hyphens = p.hyphens;
	s.hyphenchar = p.hyphenchar;
	s.textjustify = p.textjustify;
	s.hangpunct = p.hangpunct;
	s.textautospace = p.textautospace;
	s.textwrap = p.textwrap;
	s.textshadows = p.textshadows;
	s.dirrtl = p.dirrtl;
	s.tabsize = p.tabsize;
	s.visibility = p.visibility;
	s.liststyle = p.liststyle;
	s.listinside = p.listinside;
	s.listimage = p.listimage;
	s.quotes = p.quotes;
	s.cursor = p.cursor;
	s.pointer = p.pointer;
	s.collapse = p.collapse;
	s.spacingx = p.spacingx;
	s.spacingy = p.spacingy;
	s.captionbottom = p.captionbottom;
	s.hideempty = p.hideempty;
	s.accent = p.accent;
	s.caret = p.caret;
	s.svgfill = p.svgfill;
	s.svgstroke = p.svgstroke;
	s.vars = p.vars;
	return s;
}

# The style of an anonymous box: inherited values, initial otherwise.
anon(parent: ref St, display: int): ref St
{
	s := inherit(parent);
	s.display = display;
	# initial border and outline widths are medium, but their styles are
	# none: used widths 0, as fixup makes them for an element
	s.bt = s.br = s.bb = s.bl = 0;
	s.outlinew = 0;
	s.colrulew = 0;
	return s;
}

isinherited(nm: string): int
{
	case nm {
	"color" or "font-family" or "font-size" or "font-weight" or "font-style" or "font-stretch" or "font-width" or "font-synthesis" or "font-synthesis-weight" or "font-synthesis-style" or
	"font-variant" or "font-variant-caps" or "line-height" or "text-align" or
	"text-align-last" or "text-indent" or "text-transform" or "letter-spacing" or
	"word-spacing" or "white-space" or "white-space-collapse" or "text-wrap" or
	"text-wrap-mode" or "word-break" or "line-break" or "overflow-wrap" or "word-wrap" or "word-space-transform" or
	"hyphens" or "hyphenate-character" or "text-justify" or "hanging-punctuation" or "text-autospace" or "text-wrap-style" or
	"text-shadow" or "direction" or "tab-size" or "visibility" or
	"list-style-type" or "list-style-position" or "list-style-image" or "quotes" or
	"cursor" or "pointer-events" or "border-collapse" or "border-spacing" or
	"caption-side" or "empty-cells" or "accent-color" or "caret-color" or "fill" or "stroke" or
	"font-kerning" or "font-feature-settings" or "font-variation-settings" =>
		return 1;
	}
	return 0;
}

# ---- the cascade ----

Ctx: adt {
	fs:	real;		# font size for em units
	rootfs:	real;	# for rem units
	lh:	real;		# line height for lh units
	env:	ref Env;
	pct:	int;		# percentages allowed (unused)
	fam:	list of string;	# the font, for ex and ch units
	weight, italic:	int;
};

# (x-height, width of "0") in px for a font, from whoever lays the text
# out; without it, CSS's fallbacks of 0.5em
fontmetrics: ref fn(family: list of string, weight, italic: int, size: real): (real, real);

setmetrics(f: ref fn(family: list of string, weight, italic: int, size: real): (real, real))
{
	fontmetrics = f;
}

# a matched declaration with its cascade key
Md: adt {
	tier:	int;
	spec:	int;
	order:	int;
	decl:	ref Decl;
};

lastenv: ref Env;
mixcur: int;	# what currentcolor is in a color-mix() being applied: the colour so far (the inherited one for 'color')

sameenv(a, b: ref Env): int
{
	return a != nil && b != nil && a.width == b.width && a.height == b.height &&
		a.dark == b.dark && a.print == b.print;
}

compute(d: ref Doc, s: ref Styles, env: ref Env): ref Computed
{
	if(sys == nil)
		init();
	if(env == nil)
		env = ref Env(1024, 768, 1.0, 0, 0, 0, 0, 0, 0);
	# the index reflects the media queries of one environment: this
	# document's, not the last one computed (two pages at two widths)
	if(s.idx == nil || !sameenv(s.idx.env, env)) {
		s.idx = buildindex(s, env);
		s.idx.env = ref *env;
	}
	lastenv = ref *env;	# for light-dark() in colours parsed without a context
	c := ref Computed(array[d.n] of ref St, array[d.n] of ref St, array[d.n] of ref St, array[d.n] of ref St, array[d.n] of ref St, array[d.n] of ref St, array[d.n] of ref St);
	m := matcher(d, env);
	root := d.root();
	if(root == 0)
		return c;
	ctx := ref Ctx(16.0, 16.0, 19.2, env, 0, nil, 400, 0);
	share := array[Nshare] of list of (string, ref Shared);
	filters := array[d.n] of array of int;	# filter for each element's children
	n := root;
	while(n != 0) {
		nd := d.nodes[n];
		skip := 0;
		if(nd.kind == Dom->Element) {
			p := parentel(d, n);
			ps: ref St;
			if(p != 0)
				ps = c.st[p];
			if(p != 0 && ps == nil)
				skip = 1;	# inside display: none
			else {
				pf: array of int;
				if(p != 0)
					pf = filters[p];
				st := styleof(m, s.idx, n, ps, ctx, c, share, pf);
				if(nd.first != 0)
					filters[n] = childfilter(m, n, pf);
				c.st[n] = st;
				if(n == root)
					ctx.rootfs = st.fontsize;
				if(st.display == Dnone)
					skip = 1;
			}
		}
		if(skip || nd.kind != Dom->Element)
			n = nextskip(d, n, root);
		else
			n = next(d, n, root);
	}
	schemedark = -1;
	return c;
}

nextskip(d: ref Doc, n, top: int): int
{
	while(n != top && n != 0) {
		if(d.nodes[n].next != 0)
			return d.nodes[n].next;
		n = d.nodes[n].parent;
	}
	return 0;
}

Tstyleattr: con 1<<30;

Nshare: con 1024;

Shared: adt {
	st, before, after, marker:	ref St;
	firstletter:	ref St;
	firstline:	ref St;
	placeholder:	ref St;
};

# Elements whose style is computed from the same inputs -- parent style,
# matched rules, style attribute, presentational attributes -- share
# one St: siblings in a list or a table row cascade once between them.
styleof(m: ref M, idx: ref Index, n: int, parent: ref St, ctx: ref Ctx, c: ref Computed, share: array of list of (string, ref Shared), filter: array of int): ref St
{
	d := m.d;
	mds: list of ref Md;
	pse: list of (string, ref Md);
	nmd := 0;
	unlayered := Tauthor + idxlayers(idx);
	matched: list of ref Entry;
	for(cl := candidates(m, idx, n); cl != nil; cl = tl cl) {
		e := hd cl;
		if(e.anc != nil && !bloomok(filter, e.anc))
			continue;
		if(matchsel(m, e.sel, n))
			matched = e :: matched;
	}
	key := sharekey(d, n, parent, matched);
	slot := 0;
	if(key != nil) {
		slot = strhash(key, Nshare);
		for(l := share[slot]; l != nil; l = tl l)
			if((hd l).t0 == key) {
				x := (hd l).t1;
				c.before[n] = x.before;
				c.after[n] = x.after;
				c.marker[n] = x.marker;
				c.firstletter[n] = x.firstletter;
				c.firstline[n] = x.firstline;
				c.placeholder[n] = x.placeholder;
				return x.st;
			}
	}
	for(cl = matched; cl != nil; cl = tl cl) {
		e := hd cl;
		for(k := 0; k < len e.decls; k++) {
			md := ref Md(tierof(e.tier, e.decls[k].important, unlayered), e.sel.spec, e.order<<10 | (k & 1023), e.decls[k]);
			if(e.sel.pseudo != nil)
				pse = (e.sel.pseudo, md) :: pse;
			else {
				mds = md :: mds;
				nmd++;
			}
		}
	}
	for(h := hints(d, n); h != nil; h = tl h) {
		mds = ref Md(Thints, 0, 0, hd h) :: mds;
		nmd++;
	}
	if((sa := d.attr(n, "style")) != nil) {
		decls := absurls(css->parsedecls(sa), d.url);	# relative to the document
		for(k := 0; k < len decls; k++) {
			mds = ref Md(tierof(unlayered, decls[k].important, unlayered), Tstyleattr, k, decls[k]) :: mds;
			nmd++;
		}
	}
	st := cascade(sortmd(mds, nmd), parent, ctx);
	fixup(st, parent, d, n);
	if(pse != nil) {
		c.before[n] = pseudostyle(pse, "before", st, ctx);
		c.after[n] = pseudostyle(pse, "after", st, ctx);
		c.marker[n] = pseudostyle(pse, "marker", st, ctx);
		# the first letter of generated content before the element is
		# that content's: the pseudo-element inherits from ::before then
		fparent := st;
		if((bs := c.before[n]) != nil && len bs.content > 0 && bs.content[0].kind == Kstring)
			fparent = bs;
		c.firstletter[n] = pseudostyle(pse, "first-letter", fparent, ctx);
		c.firstline[n] = pseudostyle(pse, "first-line", st, ctx);
		c.placeholder[n] = pseudostyle(pse, "placeholder", st, ctx);
	}
	if(key != nil)
		share[slot] = (key, ref Shared(st, c.before[n], c.after[n], c.marker[n], c.firstletter[n], c.firstline[n], c.placeholder[n])) :: share[slot];
	return st;
}

# The inputs to an element's style, as a string; nil if it must not be
# shared (the root, whose style also sets rem units).
sharekey(d: ref Doc, n: int, parent: ref St, matched: list of ref Entry): string
{
	if(parent == nil)
		return nil;
	k := string parent.sid;
	for(; matched != nil; matched = tl matched)
		k += " " + string (hd matched).order + "." + string (hd matched).sel.spec + (hd matched).sel.pseudo;
	nd := d.nodes[n];
	if(nd.tag == Dom->Ttd || nd.tag == Dom->Tth)
		return nil;	# cellpadding and border come from the table
	if(rowish(nd.tag) && tablerules(d, n) != nil)
		return nil;	# so do its rules
	if(nd.attrs != nil) {
		k += "|" + nd.name;
		for(l := nd.attrs; l != nil; l = tl l)
			case (hd l).t0 {
			"style" or "width" or "height" or "bgcolor" or "align" or "valign" or "border" or
			"color" or "face" or "size" or "type" or "background" or "text" or "cellspacing" or
			"cellpadding" or "hspace" or "vspace" or "nowrap" or "noshade" or "cols" or "rows" or "rules" or
			"start" or "reversed" =>
				k += "|" + (hd l).t0 + "=" + (hd l).t1;
			}
	}
	return k;
}

# the rules attribute of the table n is in, lower-cased, if it is one
# of the values that mean something (HTML §15.3.11)
tablerules(d: ref Doc, n: int): string
{
	for(t := d.nodes[n].parent; t != 0; t = d.nodes[t].parent)
		if(d.nodes[t].tag == Dom->Ttable && d.nodes[t].ns == Dom->HTML)
			return rulesof(d, t);
	return nil;
}

rulesof(d: ref Doc, t: int): string
{
	case r := lower(d.attr(t, "rules")) {
	"none" or "groups" or "rows" or "cols" or "all" =>
		return r;
	}
	return nil;
}

rowish(tag: int): int
{
	case tag {
	Dom->Ttr or Dom->Tthead or Dom->Ttbody or Dom->Ttfoot or Dom->Tcolgroup or Dom->Tcol =>
		return 1;
	}
	return 0;
}

idxlayers(idx: ref Index): int
{
	return len idx.layers;
}

# Fold importance into the tier: important declarations reverse the
# order of origins and of layers (Cascade 5 §6.2, §6.4).
tierof(tier, important, unlayered: int): int
{
	if(!important)
		return tier;
	if(tier == Tua)
		return 900;
	if(tier >= Tauthor)
		return 500 + (unlayered - tier);	# unlayered lowest
	return 400;
}

pseudostyle(pse: list of (string, ref Md), name: string, parent: ref St, ctx: ref Ctx): ref St
{
	mds: list of ref Md;
	n := 0;
	for(; pse != nil; pse = tl pse)
		if((hd pse).t0 == name) {
			mds = (hd pse).t1 :: mds;
			n++;
		}
	if(n == 0)
		return nil;
	st := cascade(sortmd(mds, n), parent, ctx);
	if(name != "marker" && name != "first-letter" && name != "first-line" && name != "placeholder" && st.content == nil)
		return nil;	# content: normal/none generates no box
	if(st.display == Dnone && name != "marker")
		return nil;	# not generated: its counters do not count either
	fixup(st, parent, nil, 0);
	return st;
}

candgen := 0;

candidates(m: ref M, idx: ref Index, n: int): list of ref Entry
{
	d := m.d;
	candgen++;
	r := idx.other;
	nd := d.nodes[n];
	nm := nd.name;
	if(nd.ns != Dom->HTML)
		nm = lower(nm);
	r = appendmatching(idx.tag[strhash(nm, Nbucket)], r);
	if((id := d.attr(n, "id")) != nil)
		r = appendmatching(idx.id[strhash(id, Nbucket)], r);
	for(cl := classesof(m, n); cl != nil; cl = tl cl)
		if(hd cl != "")
			r = appendmatching(idx.class[strhash(hd cl, Nbucket)], r);
	return r;
}

appendmatching(l, r: list of ref Entry): list of ref Entry
{
	for(; l != nil; l = tl l) {
		e := hd l;
		if(e.mark != candgen) {
			e.mark = candgen;
			r = e :: r;
		}
	}
	return r;
}

sortmd(l: list of ref Md, n: int): array of ref Md
{
	a := array[n] of ref Md;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	msort(a, array[n] of ref Md);
	return a;
}

mdless(x, y: ref Md): int
{
	if(x.tier != y.tier)
		return x.tier < y.tier;
	if(x.spec != y.spec)
		return x.spec < y.spec;
	return x.order < y.order;
}

msort(a, t: array of ref Md)
{
	n := len a;
	if(n < 2)
		return;
	if(n < 12) {
		for(i := 1; i < n; i++)
			for(j := i; j > 0 && mdless(a[j], a[j-1]); j--)
				(a[j], a[j-1]) = (a[j-1], a[j]);
		return;
	}
	h := n/2;
	msort(a[0:h], t[0:h]);
	msort(a[h:], t[h:]);
	i := 0;
	j := h;
	k := 0;
	while(i < h && j < n)
		if(mdless(a[j], a[i]))
			t[k++] = a[j++];
		else
			t[k++] = a[i++];
	while(i < h)
		t[k++] = a[i++];
	while(j < n)
		t[k++] = a[j++];
	a[0:] = t[0:n];
}

cascade(mds: array of ref Md, parent: ref St, ctx: ref Ctx): ref St
{
	curmds = mds;
	st := inherit(parent);
	pfs := 16.0;
	if(parent != nil)
		pfs = parent.fontsize;
	# custom properties
	custom: list of (string, array of ref Tok);
	for(i := 0; i < len mds; i++) {
		nm := mds[i].decl.name;
		if(prefix(nm, "--"))
			custom = (nm, mds[i].decl.val) :: custom;
	}
	if(custom != nil)
		st.vars = setvars(st.vars, custom);
	# color-scheme, before any colour: light-dark() is resolved with the
	# element's own (Color Adjust 1 §2.1), not the page's
	for(i = 0; i < len mds; i++)
		if(mds[i].decl.name == "color-scheme")
			st.dark = schemeof(mds[i].decl.val, parent, ctx.env);
	schemedark = st.dark;
	# the font first, for em, ex and ch units; a font-size in those
	# units is the parent's
	ctx.fs = pfs;
	pst := parent;
	if(pst == nil)
		pst = initial;
	ctx.fam = pst.family;
	ctx.weight = pst.weight;
	ctx.italic = pst.fontstyle != FSnormal;
	for(i = 0; i < len mds; i++) {
		nm := mds[i].decl.name;
		if(nm == "font-size" || nm == "font" || nm == "all" ||
		   nm == "font-family" || nm == "font-weight" || nm == "font-style")
			applydecl(st, mds[i].decl, parent, ctx);
	}
	ctx.fs = st.fontsize;
	ctx.fam = st.family;
	ctx.weight = st.weight;
	ctx.italic = st.fontstyle != FSnormal;
	# then the line height, for lh units (its own lh is the parent's)
	ctx.lh = lineheightpx(pst);
	for(i = 0; i < len mds; i++)
		if(mds[i].decl.name == "line-height")
			applydecl(st, mds[i].decl, parent, ctx);
	ctx.lh = lineheightpx(st);
	for(i = 0; i < len mds; i++) {
		nm := mds[i].decl.name;
		if(nm == "font")	# its line-height's em is this element's font size
			applyonly(st, mds[i].decl, parent, ctx, "line-height");
		else if(nm != "font-size" && nm != "font-family" && nm != "font-weight" &&
		   nm != "font-style" && !prefix(nm, "--"))
			applydecl(st, mds[i].decl, parent, ctx);
	}
	return st;
}

# Settle this element's custom properties: winners in order, then var()
# among them resolved, with cycles making the property invalid.
setvars(parent: ref Vars, custom: list of (string, array of ref Tok)): ref Vars
{
	# custom is in reverse cascade order: the first of each name wins
	raw: list of (string, array of ref Tok);
	for(l := custom; l != nil; l = tl l) {
		seen := 0;
		for(r := raw; r != nil; r = tl r)
			if((hd r).t0 == (hd l).t0)
				seen = 1;
		if(!seen)
			raw = hd l :: raw;
	}
	v := parent;
	for(r := raw; r != nil; r = tl r) {
		(nm, val) := hd r;
		if(len val == 1 && val[0].kind == Kident) {
			case lower(val[0].s) {
			"initial" =>
				v = varset(v, nm, nil);
				continue;
			"inherit" or "unset" or "revert" or "revert-layer" =>
				v = varset(v, nm, parent.get(nm));
				continue;
			}
		}
		(ok, sv) := subvars(val, raw, parent, nm :: nil);
		if(!ok)
			sv = nil;
		v = varset(v, nm, sv);
	}
	return v;
}

lookvar(nm: string, raw: list of (string, array of ref Tok), parent: ref Vars, busy: list of string): (int, array of ref Tok)
{
	for(b := busy; b != nil; b = tl b)
		if(hd b == nm)
			return (0, nil);	# cycle
	for(r := raw; r != nil; r = tl r)
		if((hd r).t0 == nm)
			return subvars((hd r).t1, raw, parent, nm :: busy);
	v := parent.get(nm);
	return (v != nil, v);
}

# Substitute var() in v.  raw are this element's unresolved custom
# properties (nil after cascade), parent the inherited ones.
subvars(v: array of ref Tok, raw: list of (string, array of ref Tok), vars: ref Vars, busy: list of string): (int, array of ref Tok)
{
	if(!hasvar(v))
		return (1, v);
	out: list of ref Tok;
	for(i := 0; i < len v; i++) {
		t := v[i];
		if(t.kind == Kfunction && t.s == "var") {
			args := trim(t.kids);
			if(len args == 0 || args[0].kind != Kident)
				return (0, nil);
			(ok, val) := lookvar(args[0].s, raw, vars, busy);
			if(!ok) {
				# fallback after the first comma
				k := 1;
				while(k < len args && args[k].kind != Kcomma)
					k++;
				if(k >= len args)
					return (0, nil);
				(ok, val) = subvars(trim(args[k+1:]), raw, vars, busy);
				if(!ok)
					return (0, nil);
			}
			for(k := 0; k < len val; k++)
				out = val[k] :: out;
			continue;
		}
		if(t.kind == Kfunction && t.s == "env") {
			# environment variables (Environment Variables 1): the
			# safe-area, titlebar and keyboard insets are none on a
			# window with nothing over it; any other name takes its
			# fallback, or makes the value invalid
			args := trim(t.kids);
			if(len args == 0 || args[0].kind != Kident)
				return (0, nil);
			val: array of ref Tok;
			nm := lower(args[0].s);
			if(prefix(nm, "safe-area-") || prefix(nm, "titlebar-area-") || prefix(nm, "keyboard-inset-"))
				val = array[] of {ref Tok(Kdimension, "px", 0.0, 0, nil)};
			else {
				k := 1;
				while(k < len args && args[k].kind != Kcomma)
					k++;
				if(k >= len args)
					return (0, nil);
				ok: int;
				(ok, val) = subvars(trim(args[k+1:]), raw, vars, busy);
				if(!ok)
					return (0, nil);
			}
			for(k := 0; k < len val; k++)
				out = val[k] :: out;
			continue;
		}
		if(t.kids != nil && hasvar(t.kids)) {
			(ok, kids) := subvars(t.kids, raw, vars, busy);
			if(!ok)
				return (0, nil);
			t = ref Tok(t.kind, t.s, t.n, t.flag, kids);
		}
		out = t :: out;
	}
	a := array[len out] of ref Tok;
	for(i = len a - 1; i >= 0; i--) {
		a[i] = hd out;
		out = tl out;
	}
	return (1, a);
}

hasvar(v: array of ref Tok): int
{
	for(i := 0; i < len v; i++) {
		if(v[i].kind == Kfunction && (v[i].s == "var" || v[i].s == "env"))
			return 1;
		if(v[i].kids != nil && hasvar(v[i].kids))
			return 1;
	}
	return 0;
}

applydecl(st: ref St, d: ref Decl, parent: ref St, ctx: ref Ctx)
{
	aliasrtl = st.dirrtl;
	val := d.val;
	if(hasvar(val)) {
		ok: int;
		(ok, val) = subvars(val, nil, st.vars, nil);
		if(!ok) {
			# invalid at computed-value time: as if unset
			for(l := longhands(d.name, nil); l != nil; l = tl l)
				wide(st, (hd l).t0, "unset", parent, ctx);
			return;
		}
		val = trim(val);
	}
	for(l := longhands(d.name, val); l != nil; l = tl l) {
		(nm, v) := hd l;
		apply(st, nm, v, parent, ctx);
	}
}

# One longhand of a shorthand declaration.
applyonly(st: ref St, d: ref Decl, parent: ref St, ctx: ref Ctx, only: string)
{
	aliasrtl = st.dirrtl;
	val := d.val;
	if(hasvar(val)) {
		ok: int;
		(ok, val) = subvars(val, nil, st.vars, nil);
		if(!ok)
			return;	# applydecl has made it unset already
		val = trim(val);
	}
	for(l := longhands(d.name, val); l != nil; l = tl l)
		if((hd l).t0 == only)
			apply(st, only, (hd l).t1, parent, ctx);
}

# CSS-wide keywords.
wide(st: ref St, nm, k: string, parent: ref St, ctx: ref Ctx)
{
	src: ref St;
	case k {
	"inherit" =>
		src = parent;
	"initial" =>
		src = initial;
	"revert" =>
		# the value the UA sheet (or a presentational hint) gave, if any
		# (Cascade 5 §7.3.1), else as unset
		for(i := len curmds - 1; i >= 0; i--) {
			md := curmds[i];
			if(md.tier < Tauthor && md.decl.name != "all" && setslonghand(md.decl, nm)) {
				applyonly(st, md.decl, parent, ctx, nm);
				return;
			}
		}
		if(isinherited(nm))
			src = parent;
		else
			src = initial;
	"unset" or "revert-layer" =>
		if(isinherited(nm))
			src = parent;
		else
			src = initial;
	}
	if(src == nil)
		src = initial;
	copyprop(st, src, nm);
}

# the declarations of the element being cascaded, for revert
curmds: array of ref Md;

# does the declaration set the longhand nm?
setslonghand(d: ref Decl, nm: string): int
{
	for(l := longhands(d.name, d.val); l != nil; l = tl l)
		if((hd l).t0 == nm)
			return 1;
	return 0;
}

iswide(v: array of ref Tok): string
{
	if(len v == 1 && v[0].kind == Kident)
		case lower(v[0].s) {
		"inherit" or "initial" or "unset" or "revert" or "revert-layer" =>
			return lower(v[0].s);
		}
	return nil;
}

# Values settled once everything has been applied.
fixup(st, parent: ref St, d: ref Doc, n: int)
{
	if(st.bct == Ccurrent) st.bct = st.color;
	if(st.bcr == Ccurrent) st.bcr = st.color;
	if(st.bcb == Ccurrent) st.bcb = st.color;
	if(st.bcl == Ccurrent) st.bcl = st.color;
	if(st.outlinec == Ccurrent) st.outlinec = st.color;
	if(st.decorationcolor == Ccurrent) st.decorationcolor = st.color;
	if(st.colrulec == Ccurrent) st.colrulec = st.color;
	if(st.bst == Bnone || st.bst == Bhidden) st.bt = 0;
	if(st.bsr == Bnone || st.bsr == Bhidden) st.br = 0;
	if(st.bsb == Bnone || st.bsb == Bhidden) st.bb = 0;
	if(st.bsl == Bnone || st.bsl == Bhidden) st.bl = 0;
	if(st.outlines == Bnone)
		st.outlinew = 0;
	if(st.colrules == Bnone)
		st.colrulew = 0;
	for(i := 0; i < len st.shadows; i++)
		if(st.shadows[i].color == Ccurrent)
			st.shadows[i] = ref Shadow(st.shadows[i].x, st.shadows[i].y, st.shadows[i].blur,
				st.shadows[i].spread, st.color, st.shadows[i].inset);
	# blockification (CSS Display 3 §2.7)
	blockify := 0;
	if(st.position == Pabsolute || st.position == Pfixed) {
		st.float = Fnone;
		blockify = 1;
	}
	if(st.float != Fnone)
		blockify = 1;
	if(parent != nil)
		case parent.display {
		Dflex or Dinlineflex or Dgrid or Dinlinegrid or Dgridlanes or Dinlinegridlanes =>
			blockify = 1;
		}
	if(d != nil && parentel(d, n) == 0)
		blockify = 1;
	if(blockify) {
		case st.display {
		Dinline or Dinlineblock or Dinlineflex or Dinlinegrid or Dinlinegridlanes =>
			st.wasinline = 1;
		}
		case st.display {
		Dinline or Dinlineblock or Dtablerowgroup or Dtableheadergroup or
		Dtablefootergroup or Dtablerow or Dtablecell or Dtablecolumngroup or
		Dtablecolumn or Dtablecaption =>
			st.display = Dblock;
		Dinlineflex =>
			st.display = Dflex;
		Dinlinegrid =>
			st.display = Dgrid;
		Dinlinegridlanes =>
			st.display = Dgridlanes;
		Dinlinetable =>
			st.display = Dtable;
		}
	}
	if(d != nil && parentel(d, n) == 0 && st.display == Dcontents)
		st.display = Dblock;
}

# ---- value parsing ----

# A <length-percentage>, or a calc() family function.
length(v: array of ref Tok, ctx: ref Ctx): (int, Len)
{
	v = trim(v);
	if(len v != 1)
		return (0, kw(Lauto));
	t := v[0];
	case t.kind {
	Kdimension =>
		(ok, p) := unit(t.n, t.s, ctx);
		return (ok, px(p));
	Knumber =>
		if(t.n == 0.0)
			return (1, px(0.0));
	Kpercent =>
		return (1, Len(Lpx, 0.0, t.n, nil));
	Kfunction =>
		case t.s {
		"calc" or "min" or "max" or "clamp" or "-webkit-calc" =>
			e := calcexpr(t, ctx);
			if(e == nil)
				return (0, kw(Lauto));
			(lin, p, pc) := fold(e);
			if(lin)
				return (1, Len(Lpx, p, pc, nil));
			return (1, Len(Lcalc, 0.0, 0.0, e));
		}
	}
	return (0, kw(Lauto));
}

unit(n: real, u: string, ctx: ref Ctx): (int, real)
{
	case u {
	"px" => return (1, n);
	"em" => return (1, n*ctx.fs);
	"rem" => return (1, n*ctx.rootfs);
	"ex" or "cap" or "ch" =>
		if(fontmetrics != nil) {
			(xh, zw) := fontmetrics(ctx.fam, ctx.weight, ctx.italic, ctx.fs);
			if(u == "ch")
				return (1, n*zw);
			return (1, n*xh);
		}
		return (1, n*ctx.fs*0.5);
	"ic" => return (1, n*ctx.fs);
	"lh" => return (1, n*ctx.lh);
	"rlh" => return (1, n*ctx.rootfs*1.2);
	"vw" or "svw" or "lvw" or "dvw" or "cqw" or "cqi" => return (1, n*real ctx.env.width/100.0);
	"vh" or "svh" or "lvh" or "dvh" or "cqh" or "cqb" => return (1, n*real ctx.env.height/100.0);
	"vmin" or "svmin" or "lvmin" or "dvmin" or "cqmin" =>
		m := ctx.env.width;
		if(ctx.env.height < m)
			m = ctx.env.height;
		return (1, n*real m/100.0);
	"vmax" or "svmax" or "lvmax" or "dvmax" or "cqmax" =>
		m := ctx.env.width;
		if(ctx.env.height > m)
			m = ctx.env.height;
		return (1, n*real m/100.0);
	"pt" => return (1, n*96.0/72.0);
	"pc" => return (1, n*16.0);
	"in" => return (1, n*96.0);
	"cm" => return (1, n*96.0/2.54);
	"mm" => return (1, n*96.0/25.4);
	"q" => return (1, n*96.0/101.6);
	}
	return (0, 0.0);
}

# calc() and friends (CSS Values 4 §10) as an expression tree.
calcexpr(t: ref Tok, ctx: ref Ctx): ref Expr
{
	args := splitcommas(t.kids);
	case t.s {
	"calc" or "-webkit-calc" =>
		if(len args != 1)
			return nil;
		return sum(nows(hd args), ctx);
	"min" or "max" =>
		kids := array[len args] of ref Expr;
		i := 0;
		for(; args != nil; args = tl args)
			if((kids[i++] = sum(nows(hd args), ctx)) == nil)
				return nil;
		op := 'm';
		if(t.s == "max")
			op = 'M';
		return ref Expr(op, 0.0, 0.0, kids);
	"clamp" =>
		if(len args != 3)
			return nil;
		kids := array[3] of ref Expr;
		for(i := 0; i < 3; i++) {
			if((kids[i] = sum(nows(hd args), ctx)) == nil)
				return nil;
			args = tl args;
		}
		return ref Expr('c', 0.0, 0.0, kids);
	}
	return nil;
}

sum(v: array of ref Tok, ctx: ref Ctx): ref Expr
{
	# split at top-level + and - (with whitespace removed, a signed
	# number token like -5px is an operand; a delim is an operator)
	e: ref Expr;
	op := '+';
	st := 0;
	for(i := 0; i <= len v; i++)
		if(i == len v || (v[i].kind == Kdelim && (v[i].s == "+" || v[i].s == "-") && i > st)) {
			p := product(v[st:i], ctx);
			if(p == nil)
				return nil;
			if(e == nil)
				e = p;
			else
				e = ref Expr(op, 0.0, 0.0, array[] of {e, p});
			if(i < len v)
				op = v[i].s[0];
			st = i+1;
		}
	return e;
}

product(v: array of ref Tok, ctx: ref Ctx): ref Expr
{
	if(len v == 0)
		return nil;
	e := operand(v[0], ctx);
	for(i := 1; e != nil && i+1 < len v; i += 2) {
		if(v[i].kind != Kdelim || (v[i].s != "*" && v[i].s != "/"))
			return nil;
		r := operand(v[i+1], ctx);
		if(r == nil)
			return nil;
		e = ref Expr(v[i].s[0], 0.0, 0.0, array[] of {e, r});
	}
	if(len v % 2 == 0)
		return nil;
	return e;
}

operand(t: ref Tok, ctx: ref Ctx): ref Expr
{
	case t.kind {
	Knumber =>
		return ref Expr('k', t.n, 0.0, nil);
	Kpercent =>
		return ref Expr('n', 0.0, t.n, nil);
	Kdimension =>
		(ok, p) := unit(t.n, t.s, ctx);
		if(!ok)
			return nil;
		return ref Expr('n', p, 0.0, nil);
	Kblock =>
		if(t.s == "(")
			return sum(nows(t.kids), ctx);
	Kfunction =>
		return calcexpr(t, ctx);
	Kident =>
		case lower(t.s) {
		"pi" => return ref Expr('k', Math->Pi, 0.0, nil);
		"e" => return ref Expr('k', 2.718281828459045, 0.0, nil);
		}
	}
	return nil;
}

# Reduce an expression to px + pct% if it is linear: (ok, px, pct).
fold(e: ref Expr): (int, real, real)
{
	case e.op {
	'n' or 'k' =>
		return (1, e.px, e.pct);
	'+' or '-' =>
		(a, ap, apc) := fold(e.kids[0]);
		(b, bp, bpc) := fold(e.kids[1]);
		if(!a || !b)
			return (0, 0.0, 0.0);
		if(e.op == '-')
			return (1, ap-bp, apc-bpc);
		return (1, ap+bp, apc+bpc);
	'*' =>
		(a, ap, apc) := fold(e.kids[0]);
		(b, bp, bpc) := fold(e.kids[1]);
		if(!a || !b)
			return (0, 0.0, 0.0);
		if(e.kids[0].op == 'k' || isnum(e.kids[0]))
			return (1, bp*ap, bpc*ap);
		return (1, ap*bp, apc*bp);
	'/' =>
		(a, ap, apc) := fold(e.kids[0]);
		(b, bp, nil) := fold(e.kids[1]);
		if(!a || !b || bp == 0.0)
			return (0, 0.0, 0.0);
		return (1, ap/bp, apc/bp);
	'm' or 'M' or 'c' =>
		# without percentages, evaluate now
		for(i := 0; i < len e.kids; i++) {
			(ok, nil, pc) := fold(e.kids[i]);
			if(!ok || pc != 0.0)
				return (0, 0.0, 0.0);
		}
		return (1, evalexpr(e, 0.0), 0.0);
	}
	return (0, 0.0, 0.0);
}

isnum(e: ref Expr): int
{
	case e.op {
	'k' =>
		return 1;
	'n' =>
		return 0;
	'*' or '/' =>
		return isnum(e.kids[0]) && isnum(e.kids[1]);
	'+' or '-' =>
		return isnum(e.kids[0]);
	}
	return 0;
}

# a bare number, possibly computed with calc()
# an angle, in radians
angle(v: array of ref Tok, nil: ref Ctx): (int, real)
{
	v = trim(v);
	if(len v != 1)
		return (0, 0.0);
	t := v[0];
	if(t.kind == Knumber && t.n == 0.0)
		return (1, 0.0);
	if(t.kind != Kdimension)
		return (0, 0.0);
	case t.s {
	"deg" =>	return (1, t.n * Math->Pi / 180.0);
	"grad" =>	return (1, t.n * Math->Pi / 200.0);
	"rad" =>	return (1, t.n);
	"turn" =>	return (1, t.n * 2.0 * Math->Pi);
	}
	return (0, 0.0);
}

number(v: array of ref Tok, ctx: ref Ctx): (int, real)
{
	v = trim(v);
	if(len v != 1)
		return (0, 0.0);
	t := v[0];
	if(t.kind == Knumber)
		return (1, t.n);
	if(t.kind == Kfunction) {
		e := calcexpr(t, ctx);
		if(e != nil && isnum(e))
			return (1, evalexpr(e, 0.0));
	}
	return (0, 0.0);
}

# lengths that may also be auto (or the sizing keywords)
lenauto(v: array of ref Tok, ctx: ref Ctx): (int, Len)
{
	v = trim(v);
	if(len v == 1 && v[0].kind == Kident)
		case lower(v[0].s) {
		"auto" =>
			return (1, kw(Lauto));
		"stretch" or "-webkit-fill-available" or "-moz-available" =>
			return (1, kw(Lstretch));
		"min-content" or "-webkit-min-content" =>
			return (1, kw(Lmin));
		"max-content" or "-webkit-max-content" =>
			return (1, kw(Lmax));
		"fit-content" or "-webkit-fit-content" or "-moz-fit-content" =>
			return (1, kw(Lfit));
		}
	if(len v == 1 && v[0].kind == Kfunction && v[0].s == "fit-content") {
		# fit-content(<length-percentage>): the argument in px and pct
		(ok, l) := length(nows(v[0].kids), ctx);
		if(ok && l.kind == Lpx)
			return (1, Len(Lfit, l.px, l.pct, nil));
		return (1, kw(Lfit));
	}
	return length(v, ctx);
}

lennone(v: array of ref Tok, ctx: ref Ctx): (int, Len)
{
	v = trim(v);
	if(len v == 1 && v[0].kind == Kident && lower(v[0].s) == "none")
		return (1, kw(Lnone));
	(ok, l) := lenauto(v, ctx);
	if(ok && l.kind == Lauto)
		return (1, kw(Lnone));
	return (ok, l);
}

ident(v: array of ref Tok): string
{
	v = trim(v);
	if(len v == 1 && v[0].kind == Kident)
		return lower(v[0].s);
	return nil;
}

# ---- colours (CSS Color 4) ----

color(v: array of ref Tok): (int, int)
{
	if(sys == nil)
		init();
	v = trim(v);
	if(len v != 1)
		return (0, 0);
	t := v[0];
	case t.kind {
	Kident =>
		nm := lower(t.s);
		case nm {
		"transparent" =>
			return (1, Ctransparent);
		"currentcolor" =>
			return (1, Ccurrent);
		}
		lo := 0;
		hi := len colornames;
		while(lo < hi) {
			m := (lo+hi)/2;
			if(colornames[m].t0 == nm)
				return (1, colornames[m].t1);
			if(colornames[m].t0 < nm)
				lo = m+1;
			else
				hi = m;
		}
	Khash =>
		return hexcolor(t.s);
	Kfunction =>
		return colorfn(t);
	}
	return (0, 0);
}

hexcolor(s: string): (int, int)
{
	for(i := 0; i < len s; i++)
		if(hexval(s[i]) < 0)
			return (0, 0);
	r, g, b: int;
	a := 255;
	case len s {
	3 or 4 =>
		r = hexval(s[0])*17;
		g = hexval(s[1])*17;
		b = hexval(s[2])*17;
		if(len s == 4)
			a = hexval(s[3])*17;
	6 or 8 =>
		r = hexval(s[0])*16 + hexval(s[1]);
		g = hexval(s[2])*16 + hexval(s[3]);
		b = hexval(s[4])*16 + hexval(s[5]);
		if(len s == 8)
			a = hexval(s[6])*16 + hexval(s[7]);
	* =>
		return (0, 0);
	}
	return (1, rgba(r, g, b, a));
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

rgba(r, g, b, a: int): int
{
	return (clamp(r) << 24) | (clamp(g) << 16) | (clamp(b) << 8) | clamp(a);
}

clamp(x: int): int
{
	if(x < 0)
		return 0;
	if(x > 255)
		return 255;
	return x;
}

# Limbo's real-to-int conversion rounds to nearest
round(x: real): int
{
	return int x;
}

# The arguments of a colour function: up to three channels and an alpha,
# from either the legacy comma syntax or the modern space syntax.
# A channel is (kind, value): Knumber, Kpercent, Kdimension (an angle,
# converted to degrees) or Kident "none".
channels(t: ref Tok): (int, array of (int, real), (int, real))
{
	v := nows(t.kids);
	ch := array[4] of (int, real);
	n := 0;
	alpha := (Knumber, 1.0);
	slash := 0;
	for(i := 0; i < len v; i++) {
		x := v[i];
		case x.kind {
		Kcomma =>
			continue;
		Kdelim =>
			if(x.s != "/")
				return (0, nil, alpha);
			slash = 1;
			continue;
		}
		c: (int, real);
		case x.kind {
		Knumber =>
			c = (Knumber, x.n);
		Kpercent =>
			c = (Kpercent, x.n);
		Kdimension =>
			case x.s {
			"deg" => c = (Kdimension, x.n);
			"rad" => c = (Kdimension, x.n*180.0/Math->Pi);
			"grad" => c = (Kdimension, x.n*0.9);
			"turn" => c = (Kdimension, x.n*360.0);
			* => return (0, nil, alpha);
			}
		Kident =>
			if(lower(x.s) != "none")
				return (0, nil, alpha);
			c = (Knumber, 0.0);
		Kfunction =>
			e := calcexpr(x, ref Ctx(16.0, 16.0, 19.2, ref Env(1024, 768, 1.0, 0, 0, 0, 0, 0, 0), 0, nil, 400, 0));
			if(e == nil)
				return (0, nil, alpha);
			(nil, p, pc) := fold(e);
			if(pc != 0.0)
				c = (Kpercent, pc);
			else
				c = (Knumber, p);
		* =>
			return (0, nil, alpha);
		}
		if(slash || n == 3) {
			alpha = c;
			if(!slash)
				n++;
		} else if(n >= 4)
			return (0, nil, alpha);	# too many values
		else
			ch[n++] = c;
	}
	if(n < 3)
		return (0, nil, alpha);
	return (1, ch[0:3], alpha);
}

alphaof(a: (int, real)): int
{
	(k, x) := a;
	if(k == Kpercent)
		x /= 100.0;
	return round(x*255.0);
}

# number or percentage, scaled so 100% = full
chval(c: (int, real), full: real): real
{
	(k, x) := c;
	if(k == Kpercent)
		return x*full/100.0;
	return x;
}

# Whether a color-scheme value comes out dark: "dark" alone, or with
# "light" when the user prefers dark; "normal" and "light" do not.
# A value that is no scheme is ignored, inherited instead.
schemeof(v: array of ref Tok, parent: ref St, env: ref Env): int
{
	light := 0;
	dark := 0;
	other := 0;
	for(i := 0; i < len v; i++) {
		t := v[i];
		if(t.kind == Css->Kws)
			continue;
		if(t.kind != Css->Kident) {
			other = 1;
			continue;
		}
		case lower(t.s) {
		"light" =>
			light = 1;
		"dark" =>
			dark = 1;
		"normal" or "only" =>
			;
		"inherit" or "unset" =>
			if(parent != nil)
				return parent.dark;
			return 0;
		* =>
			;	# a scheme the page names that is not supported
		}
	}
	if(other) {
		if(parent != nil)
			return parent.dark;
		return 0;
	}
	if(dark && light)
		return env != nil && env.dark;
	return dark;
}

schemedark := -1;	# the element being cascaded's, or -1 outside the cascade

colorfn(t: ref Tok): (int, int)
{
	case t.s {
	"light-dark" =>
		args := splitcommas(t.kids);
		if(len args != 2)
			return (0, 0);
		dark := schemedark;
		if(dark < 0 && lastenv != nil)
			dark = lastenv.dark;
		if(dark > 0)
			return color(hd tl args);
		return color(hd args);
	"color-mix" =>
		return colormix(t);
	"color" =>
		return colorspace(t);
	}
	(ok, ch, a) := channels(t);
	if(!ok)
		return (0, 0);
	al := alphaof(a);
	case t.s {
	"rgb" or "rgba" =>
		return (1, rgba(round(chval(ch[0], 255.0)), round(chval(ch[1], 255.0)), round(chval(ch[2], 255.0)), al));
	"hsl" or "hsla" =>
		(r, g, b) := hsl2rgb(chval(ch[0], 360.0), chval(ch[1], 100.0)/100.0, chval(ch[2], 100.0)/100.0);
		return (1, rgba(round(r*255.0), round(g*255.0), round(b*255.0), al));
	"hwb" =>
		h := chval(ch[0], 360.0);
		w := chval(ch[1], 100.0)/100.0;
		bk := chval(ch[2], 100.0)/100.0;
		if(w + bk >= 1.0) {
			gr := w/(w+bk);
			return (1, rgba(round(gr*255.0), round(gr*255.0), round(gr*255.0), al));
		}
		(r, g, b) := hsl2rgb(h, 1.0, 0.5);
		f := 1.0 - w - bk;
		return (1, rgba(round((r*f+w)*255.0), round((g*f+w)*255.0), round((b*f+w)*255.0), al));
	"lab" =>
		# lightness is clamped to its range (Color 4 §9.2); at the
		# ends the colour is white or black whatever the chroma
		l := clampl(chval(ch[0], 100.0), 100.0);
		return (1, lab2rgb(l, chval(ch[1], 125.0), chval(ch[2], 125.0), al));
	"lch" =>
		l := clampl(chval(ch[0], 100.0), 100.0);
		c := chval(ch[1], 150.0);
		if(c < 0.0)
			c = 0.0;
		h := chval(ch[2], 360.0)*Math->Pi/180.0;
		return (1, lab2rgb(l, c*math->cos(h), c*math->sin(h), al));
	"oklab" =>
		l := clampl(chval(ch[0], 1.0), 1.0);
		return (1, oklab2rgb(l, chval(ch[1], 0.4), chval(ch[2], 0.4), al));
	"oklch" =>
		l := clampl(chval(ch[0], 1.0), 1.0);
		c := chval(ch[1], 0.4);
		if(c < 0.0)
			c = 0.0;
		h := chval(ch[2], 360.0)*Math->Pi/180.0;
		return (1, oklab2rgb(l, c*math->cos(h), c*math->sin(h), al));
	}
	return (0, 0);
}

hsl2rgb(h, s, l: real): (real, real, real)
{
	h = h - 360.0*math->floor(h/360.0);
	if(s < 0.0) s = 0.0;
	if(s > 1.0) s = 1.0;
	if(l < 0.0) l = 0.0;
	if(l > 1.0) l = 1.0;
	return (hslf(0.0, h, s, l), hslf(8.0, h, s, l), hslf(4.0, h, s, l));
}

hslf(n, h, s, l: real): real
{
	k := n + h/30.0;
	k = k - 12.0*math->floor(k/12.0);
	a := s * l;
	if(1.0 - l < l)
		a = s * (1.0 - l);
	m := k - 3.0;
	if(9.0 - k < m)
		m = 9.0 - k;
	if(m > 1.0)
		m = 1.0;
	if(m < -1.0)
		m = -1.0;
	return l - a*m;
}

# linear-light sRGB component to gamma-encoded 0..255
srgb(x: real): int
{
	if(x <= 0.0031308)
		x = 12.92*x;
	else
		x = 1.055*math->pow(x, 1.0/2.4) - 0.055;
	return clamp(round(x*255.0));
}

clampl(l, top: real): real
{
	if(l < 0.0)
		return 0.0;
	if(l > top)
		return top;
	return l;
}

# white or black with the alpha: the ends of the lightness range
lend(l: real, al: int): int
{
	if(l > 0.0)
		return rgba(255, 255, 255, al);
	return rgba(0, 0, 0, al);
}

lab2rgb(l, a, b: real, al: int): int
{
	# CIE Lab (D50) -> XYZ -> Bradford to D65 -> linear sRGB
	fy := (l + 16.0)/116.0;
	fx := fy + a/500.0;
	fz := fy - b/200.0;
	x := labf(fx) * 0.3457/0.3585;
	y := labf(fy);
	z := labf(fz) * (1.0 - 0.3457 - 0.3585)/0.3585;
	(x65, y65, z65) := d50to65(x, y, z);
	return xyz2rgb(x65, y65, z65, al);
}

# CIE XYZ under D50 adapted to D65 (Bradford)
d50to65(x, y, z: real): (real, real, real)
{
	return (0.9554734527042182*x - 0.023098536874261423*y + 0.0632593086610217*z,
		-0.028369706963208136*x + 1.0099954580058226*y + 0.021041398966943008*z,
		0.012314001688319899*x - 0.020507696433477912*y + 1.3303659366080753*z);
}

# CIE XYZ (D65) to an sRGB pixel
xyz2rgb(x65, y65, z65: real, al: int): int
{
	r := 3.2409699419045226*x65 - 1.537383177570094*y65 - 0.4986107602930034*z65;
	g := -0.9692436362808796*x65 + 1.8759675015077202*y65 + 0.04155505740717559*z65;
	bb := 0.05563007969699366*x65 - 0.20397695888897652*y65 + 1.0569715142428786*z65;
	return topixel(r, g, bb, al);
}

# color(<space> c1 c2 c3 [/ alpha]) (Color 4 §10): the predefined RGB
# spaces through their transfer functions and matrices to XYZ, then to
# sRGB; xyz, xyz-d65 and xyz-d50 directly
colorspace(t: ref Tok): (int, int)
{
	v := nows(t.kids);
	if(len v < 1 || v[0].kind != Kident)
		return (0, 0);
	space := lower(v[0].s);
	(ok, ch, a) := channels(ref Tok(Kfunction, "color", 0.0, 0, v[1:]));
	if(!ok)
		return (0, 0);
	al := alphaof(a);
	c0 := chval(ch[0], 1.0);
	c1 := chval(ch[1], 1.0);
	c2 := chval(ch[2], 1.0);
	x, y, z: real;
	case space {
	"srgb" =>
		if(ingamut(c0, c1, c2))
			return (1, rgba(round(c0*255.0), round(c1*255.0), round(c2*255.0), al));
		return (1, topixel(srgblin(c0), srgblin(c1), srgblin(c2), al));
	"srgb-linear" =>
		return (1, topixel(c0, c1, c2, al));
	"display-p3" or "display-p3-linear" =>
		(r, g, b) := (srgblin(c0), srgblin(c1), srgblin(c2));
		if(space == "display-p3-linear")
			(r, g, b) = (c0, c1, c2);
		x = 0.4865709486482162*r + 0.26566769316909306*g + 0.1982172852343625*b;
		y = 0.2289745640697488*r + 0.6917385218365064*g + 0.079286914093745*b;
		z = 0.04511338185890264*g + 1.043944368900976*b;
	"a98-rgb" =>
		(r, g, b) := (gammalin(c0, 563.0/256.0), gammalin(c1, 563.0/256.0), gammalin(c2, 563.0/256.0));
		x = 0.5766690429101305*r + 0.1855582379065463*g + 0.1882286462349947*b;
		y = 0.29734497525053605*r + 0.6273635662554661*g + 0.07529145849399788*b;
		z = 0.02703136138641234*r + 0.07068885253582723*g + 0.9913375368376388*b;
	"prophoto-rgb" =>
		(r, g, b) := (prophotolin(c0), prophotolin(c1), prophotolin(c2));
		(x, y, z) = d50to65(0.7977604896723027*r + 0.13518583717574031*g + 0.0313493495815248*b,
			0.2880711282292934*r + 0.7118432178101014*g + 0.00008565396060525902*b,
			0.8251046025104601*b);
	"rec2020" =>
		(r, g, b) := (rec2020lin(c0), rec2020lin(c1), rec2020lin(c2));
		x = 0.6369580483012914*r + 0.14461690358620832*g + 0.1688809751641721*b;
		y = 0.2627002120112671*r + 0.6779980715188708*g + 0.05930171646986196*b;
		z = 0.028072693049087428*g + 1.060985057710791*b;
	"xyz" or "xyz-d65" =>
		(x, y, z) = (c0, c1, c2);
	"xyz-d50" =>
		(x, y, z) = d50to65(c0, c1, c2);
	* =>
		return (0, 0);
	}
	return (1, xyz2rgb(x, y, z, al));
}

# the transfer functions, to linear light
srgblin(v: real): real
{
	s := 1.0;
	if(v < 0.0) {
		s = -1.0;
		v = -v;
	}
	if(v <= 0.04045)
		return s*v/12.92;
	return s*math->pow((v + 0.055)/1.055, 2.4);
}

gammalin(v, g: real): real
{
	if(v < 0.0)
		return -math->pow(-v, g);
	return math->pow(v, g);
}

prophotolin(v: real): real
{
	s := 1.0;
	if(v < 0.0) {
		s = -1.0;
		v = -v;
	}
	if(v <= 16.0/512.0)
		return s*v/16.0;
	return s*math->pow(v, 1.8);
}

rec2020lin(v: real): real
{
	al := 1.09929682680944;
	be := 0.018053968510807;
	s := 1.0;
	if(v < 0.0) {
		s = -1.0;
		v = -v;
	}
	if(v < be*4.5)
		return s*v/4.5;
	return s*math->pow((v + al - 1.0)/al, 1.0/0.45);
}

labf(t: real): real
{
	if(t*t*t > 216.0/24389.0)
		return t*t*t;
	return (116.0*t - 16.0)/(24389.0/27.0);
}

oklab2rgb(l, a, b: real, al: int): int
{
	# the ends of lightness, and what lies within an epsilon of them
	# (oklch-009: oklch(100% 110 60) is white; oklab-l-almost-1:
	# 99.9999% renders as 100%)
	if(l >= 1.0 - 0.00001)
		return rgba(255, 255, 255, al);
	if(l <= 0.00001)
		return rgba(0, 0, 0, al);
	l_ := l + 0.3963377774*a + 0.2158037573*b;
	m_ := l - 0.1055613458*a - 0.0638541728*b;
	s_ := l - 0.0894841775*a - 1.2914855480*b;
	l3 := l_*l_*l_;
	m3 := m_*m_*m_;
	s3 := s_*s_*s_;
	r := 4.0767416621*l3 - 3.3077115913*m3 + 0.2309699292*s3;
	g := -1.2684380046*l3 + 2.6097574011*m3 - 0.3413193965*s3;
	bb := -0.0041960863*l3 - 0.7034186147*m3 + 1.7076147010*s3;
	return topixel(r, g, bb, al);
}

oklab2lin(l, a, b: real): (real, real, real)
{
	l_ := l + 0.3963377774*a + 0.2158037573*b;
	m_ := l - 0.1055613458*a - 0.0638541728*b;
	s_ := l - 0.0894841775*a - 1.2914855480*b;
	l3 := l_*l_*l_;
	m3 := m_*m_*m_;
	s3 := s_*s_*s_;
	return (4.0767416621*l3 - 3.3077115913*m3 + 0.2309699292*s3,
		-1.2684380046*l3 + 2.6097574011*m3 - 0.3413193965*s3,
		-0.0041960863*l3 - 0.7034186147*m3 + 1.7076147010*s3);
}

lin2oklab(r, g, b: real): (real, real, real)
{
	l := cbrt(0.4122214708*r + 0.5363325363*g + 0.0514459929*b);
	m := cbrt(0.2119034982*r + 0.6806995451*g + 0.1073969566*b);
	s := cbrt(0.0883024619*r + 0.2817188376*g + 0.6299787005*b);
	return (0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
		1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
		0.0259040371*l + 0.7827717662*m - 0.8086757660*s);
}

cbrt(x: real): real
{
	if(x < 0.0)
		return -math->pow(-x, 1.0/3.0);
	return math->pow(x, 1.0/3.0);
}

ingamut(r, g, b: real): int
{
	return r >= -0.00001 && r <= 1.00001 && g >= -0.00001 && g <= 1.00001 && b >= -0.00001 && b <= 1.00001;
}

clip01(x: real): real
{
	if(x < 0.0)
		return 0.0;
	if(x > 1.0)
		return 1.0;
	return x;
}

# Linear sRGB to the pixel.  A colour outside the gamut is mapped into
# it as Color 4 §13.2 says: white or black at the ends of lightness,
# else its Oklch chroma is reduced until it fits, or until it is
# within a just noticeable difference of its clipped self
# (oklab-l-almost-1, lch-009).
topixel(r, g, b: real, al: int): int
{
	if(!ingamut(r, g, b)) {
		(l, a, bb) := lin2oklab(r, g, b);
		if(l >= 1.0)
			(r, g, b) = (1.0, 1.0, 1.0);
		else if(l <= 0.0)
			(r, g, b) = (0.0, 0.0, 0.0);
		else {
			# the chroma is bisected to the point where the clipped
			# colour is just a noticeable difference from the wanted
			# one, as §13.2.1 says: a search that stops at the first
			# near-enough step lands differently for inputs that
			# differ in the sixth figure (xyz-d50-004)
			c := math->sqrt(a*a + bb*bb);
			h := math->atan2(bb, a);
			lo := 0.0;
			hi := c;
			loin := 1;
			(r, g, b) = oklab2lin(l, 0.0, 0.0);
			for(i := 0; i < 40 && hi - lo > 0.0001; i++) {
				mid := (lo + hi)/2.0;
				(mr, mg, mb) := oklab2lin(l, mid*math->cos(h), mid*math->sin(h));
				if(loin && ingamut(mr, mg, mb)) {
					lo = mid;
					(r, g, b) = (mr, mg, mb);
					continue;
				}
				(cr, cg, cb) := (clip01(mr), clip01(mg), clip01(mb));
				(cl, ca, cbb) := lin2oklab(cr, cg, cb);
				dl := cl - l;
				da := ca - mid*math->cos(h);
				db := cbb - mid*math->sin(h);
				e := math->sqrt(dl*dl + da*da + db*db);
				if(e < 0.02) {
					(r, g, b) = (cr, cg, cb);
					if(0.02 - e < 0.0001)
						break;
					loin = 0;
					lo = mid;
				} else
					hi = mid;
			}
		}
	}
	return (srgb(r) << 24) | (srgb(g) << 16) | (srgb(b) << 8) | clamp(al);
}

# color-mix(in <space>, c1 [p1], c2 [p2]): mixed in sRGB whatever the space
colormix(t: ref Tok): (int, int)
{
	(ok, ch) := colormixr(t);
	if(!ok)
		return (0, 0);
	mix := 0;
	for(i := 0; i < 4; i++)
		mix |= clamp(round(ch[i])) << (24 - 8*i);
	return (1, mix);
}

# the mix's channels unrounded (a, r, g, b in 0..255), so that a mix
# within a mix loses nothing to rounding
colormixr(t: ref Tok): (int, array of real)
{
	args := splitcommas(t.kids);
	if(len args != 3)
		return (0, nil);
	args = tl args;
	(ok1, c1, p1) := mixarg(hd args);
	(ok2, c2, p2) := mixarg(hd tl args);
	if(!ok1 || !ok2)
		return (0, nil);
	if(p1 < 0.0 && p2 < 0.0) {
		p1 = 50.0;
		p2 = 50.0;
	} else if(p1 < 0.0)
		p1 = 100.0 - p2;
	else if(p2 < 0.0)
		p2 = 100.0 - p1;
	tot := p1 + p2;
	if(tot <= 0.0)
		return (0, nil);
	w := p1/tot;
	ch := array[4] of real;
	for(i := 0; i < 4; i++)
		ch[i] = c1[i]*w + c2[i]*(1.0-w);
	return (1, ch);
}

mixarg(v: array of ref Tok): (int, array of real, real)
{
	v = nows(v);
	p := -1.0;
	cv := v;
	if(len v == 2) {
		if(v[1].kind == Kpercent) {
			p = v[1].n;
			cv = v[0:1];
		} else if(v[0].kind == Kpercent) {
			p = v[0].n;
			cv = v[1:];
		}
	}
	if(len cv == 1 && cv[0].kind == Kfunction && lower(cv[0].s) == "color-mix") {
		(ok, ch) := colormixr(cv[0]);
		return (ok, ch, p);
	}
	(ok, c) := color(cv);
	if(ok && c == Ccurrent)
		c = mixcur;
	ch := array[4] of real;
	for(i := 0; i < 4; i++)
		ch[i] = real ((c >> (24 - 8*i)) & 255);
	return (ok, ch, p);
}

# ---- shorthands ----

# The longhands a declaration sets, with their values.  For a longhand,
# itself.  nil if the value is invalid for a shorthand.  With v nil (an
# invalid var() substitution) the longhands are listed with nil values.
longhands(nm: string, v: array of ref Tok): list of (string, array of ref Tok)
{
	nm = alias(nm);
	sub := shorthand(nm);
	if(sub == nil)
		return (nm, v) :: nil;
	if(v == nil || iswide(v) != nil) {
		r: list of (string, array of ref Tok);
		for(; sub != nil; sub = tl sub)
			r = (hd sub, v) :: r;
		return r;
	}
	x := nows(v);
	case nm {
	"margin" or "padding" or "inset" or "border-width" or "border-style" or "border-color" or "border-radius" =>
		if(nm == "border-radius") {
			# horizontal radii only
			for(k := 0; k < len x; k++)
				if(x[k].kind == Kdelim && x[k].s == "/")
					x = x[0:k];
		}
		return box(sub, x);
	"margin-block" or "margin-inline" or "padding-block" or "padding-inline" or
	"inset-block" or "inset-inline" or "border-block-width" or "border-inline-width" or
	"border-block-style" or "border-inline-style" or "border-block-color" or "border-inline-color" =>
		if(len x == 1)
			return (hd sub, x) :: (hd tl sub, x) :: nil;
		if(len x == 2)
			return (hd sub, x[0:1]) :: (hd tl sub, x[1:2]) :: nil;
		return nil;
	"border" or "border-top" or "border-right" or "border-bottom" or "border-left" or
	"border-block" or "border-inline" or "outline" or "column-rule" =>
		return borderparts(sub, x);
	"background" =>
		return background(v);
	"mask" =>
		return mask(v);
	"font" =>
		return font(x);
	"flex" =>
		return flex(x);
	"flex-flow" =>
		r: list of (string, array of ref Tok);
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kident)
				return nil;
			case lower(x[k].s) {
			"row" or "row-reverse" or "column" or "column-reverse" =>
				r = ("flex-direction", x[k:k+1]) :: r;
			* =>
				r = ("flex-wrap", x[k:k+1]) :: r;
			}
		}
		return r;
	"gap" or "grid-gap" =>
		if(len x == 1)
			return ("row-gap", x) :: ("column-gap", x) :: nil;
		if(len x == 2)
			return ("row-gap", x[0:1]) :: ("column-gap", x[1:2]) :: nil;
		return nil;
	"place-items" or "place-content" or "place-self" =>
		a := x;
		b := x;
		if(len x >= 2) {
			# split before the second keyword group
			k := 1;
			if(x[0].kind == Kident && (lower(x[0].s) == "first" || lower(x[0].s) == "last" ||
			   lower(x[0].s) == "safe" || lower(x[0].s) == "unsafe"))
				k = 2;
			a = x[0:k];
			b = x[k:];
		}
		return (hd sub, a) :: (hd tl sub, b) :: nil;
	"overflow" =>
		if(len x == 1)
			return ("overflow-x", x) :: ("overflow-y", x) :: nil;
		if(len x == 2)
			return ("overflow-x", x[0:1]) :: ("overflow-y", x[1:2]) :: nil;
		return nil;
	"list-style" =>
		r: list of (string, array of ref Tok);
		nones := 0;
		for(k := 0; k < len x; k++) {
			t := x[k];
			if(t.kind == Kident) {
				case lower(t.s) {
				"inside" or "outside" =>
					r = ("list-style-position", x[k:k+1]) :: r;
				"none" =>
					nones++;
				* =>
					r = ("list-style-type", x[k:k+1]) :: r;
				}
			} else if(t.kind == Kurl || t.kind == Kfunction)
				r = ("list-style-image", x[k:k+1]) :: r;
			else if(t.kind == Kstring)
				r = ("list-style-type", x[k:k+1]) :: r;
			else
				return nil;
		}
		if(nones + haslh(r, "list-style-type") + haslh(r, "list-style-image") > 2)
			return nil;	# a none with nothing left for it to be
		if(nones > 0) {
			nonev := array[] of {ref Tok(Kident, "none", 0.0, 0, nil)};
			if(!haslh(r, "list-style-type"))
				r = ("list-style-type", nonev) :: r;
			if(!haslh(r, "list-style-image"))
				r = ("list-style-image", nonev) :: r;
		}
		return fill(sub, r);
	"text-decoration" =>
		r: list of (string, array of ref Tok);
		lines: list of ref Tok;
		for(k := 0; k < len x; k++) {
			t := x[k];
			if(t.kind == Kident) {
				case lower(t.s) {
				"underline" or "overline" or "line-through" or "blink" or "none" =>
					lines = t :: lines;
					continue;
				"solid" or "double" or "dotted" or "dashed" or "wavy" =>
					r = ("text-decoration-style", x[k:k+1]) :: r;
					continue;
				"auto" or "from-font" =>
					continue;
				}
			}
			if(t.kind == Kdimension || t.kind == Kpercent)
				continue;	# thickness
			(ok, nil) := color(x[k:k+1]);
			if(!ok)
				return nil;
			r = ("text-decoration-color", x[k:k+1]) :: r;
		}
		if(lines != nil) {
			a := array[len lines] of ref Tok;
			for(k = len a - 1; k >= 0; k--) {
				a[k] = hd lines;
				lines = tl lines;
			}
			r = ("text-decoration-line", a) :: r;
		}
		return fill(sub, r);
	"columns" =>
		r: list of (string, array of ref Tok);
		for(k := 0; k < len x; k++)
			if(x[k].kind == Knumber)
				r = ("column-count", x[k:k+1]) :: r;
			else if(x[k].kind != Kident || lower(x[k].s) != "auto")
				r = ("column-width", x[k:k+1]) :: r;
		return fill(sub, r);
	"grid-row" or "grid-column" =>
		for(k := 0; k < len x; k++)
			if(x[k].kind == Kdelim && x[k].s == "/")
				return (hd sub, x[0:k]) :: (hd tl sub, x[k+1:]) :: nil;
		# a single <custom-ident> sets both; otherwise the end is auto
		if(len x == 1 && x[0].kind == Kident)
			return (hd sub, x) :: (hd tl sub, x) :: nil;
		return (hd sub, x) :: (hd tl sub, autov()) :: nil;
	"grid-area" =>
		# row-start / column-start / row-end / column-end; a missing
		# value repeats a <custom-ident> before it, else is auto
		parts := slashes(x);
		if(len parts > 4)
			return nil;
		v := array[4] of array of ref Tok;
		for(k := 0; k < 4; k++) {
			if(k < len parts)
				v[k] = parts[k];
			else {
				from := v[0];
				if(k == 3)
					from = v[1];
				if(len from == 1 && from[0].kind == Kident)
					v[k] = from;
				else
					v[k] = autov();
			}
		}
		r := ("grid-row-start", v[0]) :: ("grid-column-start", v[1]) ::
			("grid-row-end", v[2]) :: ("grid-column-end", v[3]) :: nil;
		if(len x == 1 && x[0].kind == Kident)
			r = ("-x-grid-area-name", x) :: r;
		return r;
	"grid-template" or "grid" =>
		parts := slashes(x);
		if(len parts == 1 && len x == 1 && x[0].kind == Kident && lower(x[0].s) == "none")
			return ("grid-template-rows", x) :: ("grid-template-columns", x) :: ("grid-template-areas", x) :: nil;
		if(len parts != 2)
			return nil;
		# strings in the rows part are the areas
		rows: list of ref Tok;
		areas: list of ref Tok;
		for(k := 0; k < len parts[0]; k++)
			if(parts[0][k].kind == Kstring)
				areas = parts[0][k] :: areas;
			else
				rows = parts[0][k] :: rows;
		r := ("grid-template-columns", parts[1]) :: nil;
		if(rows != nil)
			r = ("grid-template-rows", toarray(rows)) :: r;
		if(areas != nil)
			r = ("grid-template-areas", toarray(areas)) :: r;
		return fill(sub, r);
	"all" =>
		return nil;	# only the CSS-wide keywords, handled above
	"border-image" =>
		return borderimage(x);
	"transition" or "animation" or "text-emphasis" or "offset" or
	"container" or "scroll-margin" or "scroll-padding" or "font-variant" =>
		return nil;
	}
	return nil;
}

# Properties that are other names for a longhand, in writing mode
# horizontal-tb: the inline ones depend on the direction of the element
# being styled (aliasrtl, set by whoever applies declarations).
aliasrtl := 0;

alias(nm: string): string
{
	if(aliasrtl)
		case nm {
		"margin-inline-start" => return "margin-right";
		"margin-inline-end" => return "margin-left";
		"padding-inline-start" => return "padding-right";
		"padding-inline-end" => return "padding-left";
		"inset-inline-start" => return "right";
		"inset-inline-end" => return "left";
		"border-inline-start" => return "border-right";
		"border-inline-end" => return "border-left";
		"border-inline-start-width" => return "border-right-width";
		"border-inline-end-width" => return "border-left-width";
		"border-inline-start-color" => return "border-right-color";
		"border-inline-end-color" => return "border-left-color";
		"border-inline-start-style" => return "border-right-style";
		"border-inline-end-style" => return "border-left-style";
		}
	case nm {
	"margin-block-start" => return "margin-top";
	"margin-block-end" => return "margin-bottom";
	"margin-inline-start" => return "margin-left";
	"margin-inline-end" => return "margin-right";
	"padding-block-start" => return "padding-top";
	"padding-block-end" => return "padding-bottom";
	"padding-inline-start" => return "padding-left";
	"padding-inline-end" => return "padding-right";
	"inset-block-start" => return "top";
	"inset-block-end" => return "bottom";
	"inset-inline-start" => return "left";
	"inset-inline-end" => return "right";
	"inline-size" => return "width";
	"block-size" => return "height";
	"min-inline-size" => return "min-width";
	"min-block-size" => return "min-height";
	"max-inline-size" => return "max-width";
	"max-block-size" => return "max-height";
	"border-block-start" => return "border-top";
	"border-block-end" => return "border-bottom";
	"border-inline-start" => return "border-left";
	"border-inline-end" => return "border-right";
	"border-block-start-width" => return "border-top-width";
	"border-block-end-width" => return "border-bottom-width";
	"border-inline-start-width" => return "border-left-width";
	"border-inline-end-width" => return "border-right-width";
	"border-block-start-color" => return "border-top-color";
	"border-block-end-color" => return "border-bottom-color";
	"border-inline-start-color" => return "border-left-color";
	"border-inline-end-color" => return "border-right-color";
	"border-block-start-style" => return "border-top-style";
	"border-block-end-style" => return "border-bottom-style";
	"border-inline-start-style" => return "border-left-style";
	"border-inline-end-style" => return "border-right-style";
	"border-start-start-radius" => return "border-top-left-radius";
	"border-start-end-radius" => return "border-top-right-radius";
	"border-end-start-radius" => return "border-bottom-left-radius";
	"border-end-end-radius" => return "border-bottom-right-radius";
	"word-wrap" => return "overflow-wrap";
	"grid-row-gap" => return "row-gap";
	"grid-column-gap" => return "column-gap";
	"-webkit-box-sizing" or "-moz-box-sizing" => return "box-sizing";
	"-webkit-text-decoration" => return "text-decoration";
	"-webkit-appearance" or "-moz-appearance" => return "appearance";
	"-webkit-flex" => return "flex";
	"-webkit-box-shadow" => return "box-shadow";
	"-webkit-border-radius" => return "border-radius";
	"-webkit-transform" => return "transform";
	"-webkit-mask" => return "mask";
	"-webkit-mask-image" => return "mask-image";
	"-webkit-mask-repeat" => return "mask-repeat";
	"-webkit-mask-position" => return "mask-position";
	"-webkit-mask-size" => return "mask-size";
	"-webkit-mask-origin" => return "mask-origin";
	"-webkit-mask-clip" => return "mask-clip";
	}
	return nm;
}

shorthand(nm: string): list of string
{
	case nm {
	"margin" => return list of {"margin-top", "margin-right", "margin-bottom", "margin-left"};
	"padding" => return list of {"padding-top", "padding-right", "padding-bottom", "padding-left"};
	"inset" => return list of {"top", "right", "bottom", "left"};
	"margin-block" => return list of {"margin-top", "margin-bottom"};
	"margin-inline" => return list of {"margin-left", "margin-right"};
	"padding-block" => return list of {"padding-top", "padding-bottom"};
	"padding-inline" => return list of {"padding-left", "padding-right"};
	"inset-block" => return list of {"top", "bottom"};
	"inset-inline" => return list of {"left", "right"};
	"border-width" => return list of {"border-top-width", "border-right-width", "border-bottom-width", "border-left-width"};
	"border-style" => return list of {"border-top-style", "border-right-style", "border-bottom-style", "border-left-style"};
	"border-color" => return list of {"border-top-color", "border-right-color", "border-bottom-color", "border-left-color"};
	"border-block-width" => return list of {"border-top-width", "border-bottom-width"};
	"border-inline-width" => return list of {"border-left-width", "border-right-width"};
	"border-block-style" => return list of {"border-top-style", "border-bottom-style"};
	"border-inline-style" => return list of {"border-left-style", "border-right-style"};
	"border-block-color" => return list of {"border-top-color", "border-bottom-color"};
	"border-inline-color" => return list of {"border-left-color", "border-right-color"};
	"border-radius" => return list of {"border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius"};
	"border" => return list of {"border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
		"border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
		"border-top-color", "border-right-color", "border-bottom-color", "border-left-color", "border-image-source"};
	"border-top" => return list of {"border-top-width", "border-top-style", "border-top-color"};
	"border-right" => return list of {"border-right-width", "border-right-style", "border-right-color"};
	"border-bottom" => return list of {"border-bottom-width", "border-bottom-style", "border-bottom-color"};
	"border-left" => return list of {"border-left-width", "border-left-style", "border-left-color"};
	"border-block" => return list of {"border-top-width", "border-bottom-width", "border-top-style", "border-bottom-style", "border-top-color", "border-bottom-color"};
	"border-inline" => return list of {"border-left-width", "border-right-width", "border-left-style", "border-right-style", "border-left-color", "border-right-color"};
	"outline" => return list of {"outline-width", "outline-style", "outline-color"};
	"column-rule" => return list of {"column-rule-width", "column-rule-style", "column-rule-color"};
	"background" => return list of {"background-color", "background-image", "background-repeat",
		"background-position", "background-size", "background-attachment", "background-origin", "background-clip"};
	"font" => return list of {"font-style", "font-variant", "font-weight", "font-size", "line-height", "font-family"};
	"flex" => return list of {"flex-grow", "flex-shrink", "flex-basis"};
	"flex-flow" => return list of {"flex-direction", "flex-wrap"};
	"gap" or "grid-gap" => return list of {"row-gap", "column-gap"};
	"place-items" => return list of {"align-items", "justify-items"};
	"place-content" => return list of {"align-content", "justify-content"};
	"place-self" => return list of {"align-self", "justify-self"};
	"overflow" => return list of {"overflow-x", "overflow-y"};
	"list-style" => return list of {"list-style-type", "list-style-position", "list-style-image"};
	"text-decoration" => return list of {"text-decoration-line", "text-decoration-style", "text-decoration-color"};
	"columns" => return list of {"column-width", "column-count"};
	"grid-row" => return list of {"grid-row-start", "grid-row-end"};
	"grid-column" => return list of {"grid-column-start", "grid-column-end"};
	"grid-area" => return list of {"grid-row-start", "grid-column-start", "grid-row-end", "grid-column-end"};
	"grid-template" or "grid" => return list of {"grid-template-rows", "grid-template-columns", "grid-template-areas"};
	"all" =>
		r: list of string;
		for(i := len allprops - 1; i >= 0; i--)
			r = allprops[i] :: r;
		return r;
	"border-image" => return list of {"border-image-source", "border-image-slice", "border-image-width", "border-image-outset", "border-image-repeat"};
	"mask" => return list of {"mask-image", "mask-repeat", "mask-position", "mask-size", "mask-origin", "mask-clip"};
	"transition" or "animation" or "text-emphasis" or "offset" or
	"container" or "scroll-margin" or "scroll-padding" =>
		return "-x-ignored" :: nil;
	}
	return nil;
}

allprops := array[] of {
	"display", "position", "float", "clear", "box-sizing", "width", "height",
	"min-width", "min-height", "max-width", "max-height", "margin-top", "margin-right",
	"margin-bottom", "margin-left", "padding-top", "padding-right", "padding-bottom",
	"padding-left", "border-top-width", "border-right-width", "border-bottom-width",
	"border-left-width", "border-top-style", "border-right-style", "border-bottom-style",
	"border-left-style", "border-top-color", "border-right-color", "border-bottom-color",
	"border-left-color", "top", "right", "bottom", "left", "z-index", "overflow-x",
	"overflow-y", "visibility", "opacity", "transform", "transform-origin", "color", "background-color", "background-image",
	"mask-image",
	"font-family", "font-size", "font-weight", "font-style", "line-height", "text-align",
	"text-indent", "text-transform", "white-space", "text-decoration-line", "vertical-align",
};

# a copy of the box's border-image to change, the initial values
# where it has none (source none, slice 100%, width 1, outset 0, stretch)
bimageof(st: ref St): ref Bimage
{
	if(st.bimage != nil)
		return ref *st.bimage;
	return ref Bimage(nil, array[] of {Len(Lpx, 0.0, 100.0, nil), Len(Lpx, 0.0, 100.0, nil), Len(Lpx, 0.0, 100.0, nil), Len(Lpx, 0.0, 100.0, nil)}, 0,
		array[] of {Len(Lnum, 1.0, 0.0, nil), Len(Lnum, 1.0, 0.0, nil), Len(Lnum, 1.0, 0.0, nil), Len(Lnum, 1.0, 0.0, nil)},
		array[] of {px(0.0), px(0.0), px(0.0), px(0.0)}, BIstretch, BIstretch);
}

# one to four values, in reverse, to top, right, bottom, left
foursides(vals: list of Len): array of Len
{
	n := len vals;
	if(n < 1 || n > 4)
		return nil;
	a := array[n] of Len;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd vals;
		vals = tl vals;
	}
	case n {
	1 =>	return array[] of {a[0], a[0], a[0], a[0]};
	2 =>	return array[] of {a[0], a[1], a[0], a[1]};
	3 =>	return array[] of {a[0], a[1], a[2], a[1]};
	}
	return a;
}

birepeat(t: ref Tok): int
{
	if(t.kind != Kident)
		return -1;
	case lower(t.s) {
	"stretch" =>	return BIstretch;
	"repeat" =>	return BIrepeat;
	"round" =>	return BIround;
	"space" =>	return BIspace;
	}
	return -1;
}

# the border-image shorthand: <source> || <slice> [ / <width> | /
# <width>? / <outset> ]? || <repeat>, every longhand it leaves out
# taking its initial value
borderimage(x: array of ref Tok): list of (string, array of ref Tok)
{
	none := array[] of {ref Tok(Kident, "none", 0.0, 0, nil)};
	src := none;
	slice := array[] of {ref Tok(Kpercent, "", 100.0, 0, nil)};
	width := array[] of {ref Tok(Knumber, "", 1.0, 0, nil)};
	outset := array[] of {ref Tok(Knumber, "", 0.0, 0, nil)};
	rep := array[] of {ref Tok(Kident, "stretch", 0.0, 0, nil)};
	gotsrc := 0;
	gotslice := 0;
	gotrep := 0;
	i := 0;
	while(i < len x) {
		t := x[i];
		if(t.kind == Kident && (lower(t.s) == "none" || birepeat(t) >= 0)) {
			if(lower(t.s) == "none") {
				if(gotsrc)
					return nil;
				gotsrc = 1;
				src = none;
				i++;
			} else {
				if(gotrep)
					return nil;
				gotrep = 1;
				j := i + 1;
				if(j < len x && birepeat(x[j]) >= 0)
					j++;
				rep = x[i:j];
				i = j;
			}
			continue;
		}
		if(t.kind == Kurl || t.kind == Kfunction) {
			if(gotsrc)
				return nil;
			gotsrc = 1;
			src = x[i:i+1];
			i++;
			continue;
		}
		if(t.kind == Knumber || t.kind == Kpercent || t.kind == Kident && lower(t.s) == "fill") {
			if(gotslice)
				return nil;
			gotslice = 1;
			j := i;
			while(j < len x && (x[j].kind == Knumber || x[j].kind == Kpercent || x[j].kind == Kident && lower(x[j].s) == "fill"))
				j++;
			slice = x[i:j];
			i = j;
			if(i < len x && x[i].kind == Kdelim && x[i].s == "/") {
				i++;
				j = i;
				while(j < len x && !(x[j].kind == Kdelim && x[j].s == "/") && (x[j].kind == Knumber || x[j].kind == Kpercent || x[j].kind == Kdimension || x[j].kind == Kident && lower(x[j].s) == "auto"))
					j++;
				if(j > i)
					width = x[i:j];
				i = j;
				if(i < len x && x[i].kind == Kdelim && x[i].s == "/") {
					i++;
					j = i;
					while(j < len x && (x[j].kind == Knumber || x[j].kind == Kdimension))
						j++;
					if(j == i)
						return nil;
					outset = x[i:j];
					i = j;
				}
			}
			continue;
		}
		return nil;
	}
	return ("border-image-source", src) :: ("border-image-slice", slice) :: ("border-image-width", width) ::
		("border-image-outset", outset) :: ("border-image-repeat", rep) :: nil;
}

wrapstyle(w: string): int
{
	case w {
	"balance" => return 1;
	"stable" => return 2;
	"pretty" => return 3;
	}
	return 0;
}

autov(): array of ref Tok
{
	return array[] of {ref Tok(Kident, "auto", 0.0, 0, nil)};
}

toarray(l: list of ref Tok): array of ref Tok
{
	a := array[len l] of ref Tok;
	for(k := len a - 1; k >= 0; k--) {
		a[k] = hd l;
		l = tl l;
	}
	return a;
}

slashes(x: array of ref Tok): array of array of ref Tok
{
	r: list of array of ref Tok;
	st := 0;
	for(k := 0; k <= len x; k++)
		if(k == len x || (x[k].kind == Kdelim && x[k].s == "/")) {
			r = x[st:k] :: r;
			st = k+1;
		}
	a := array[len r] of array of ref Tok;
	for(k = len a - 1; k >= 0; k--) {
		a[k] = hd r;
		r = tl r;
	}
	return a;
}

haslh(r: list of (string, array of ref Tok), nm: string): int
{
	for(; r != nil; r = tl r)
		if((hd r).t0 == nm)
			return 1;
	return 0;
}

# longhands the shorthand did not mention are reset to initial
fill(sub: list of string, r: list of (string, array of ref Tok)): list of (string, array of ref Tok)
{
	init := array[] of {ref Tok(Kident, "initial", 0.0, 0, nil)};
	for(; sub != nil; sub = tl sub)
		if(!haslh(r, hd sub))
			r = (hd sub, init) :: r;
	return r;
}

# 1-4 values: top right bottom left
box(sub: list of string, x: array of ref Tok): list of (string, array of ref Tok)
{
	n := len x;
	if(n < 1 || n > 4)
		return nil;
	idx := array[] of {
		array[] of {0, 0, 0, 0},
		array[] of {0, 1, 0, 1},
		array[] of {0, 1, 2, 1},
		array[] of {0, 1, 2, 3},
	};
	r: list of (string, array of ref Tok);
	for(k := 0; k < 4; k++) {
		j := idx[n-1][k];
		r = (hd sub, x[j:j+1]) :: r;
		sub = tl sub;
	}
	return r;
}

# border-like shorthands: <width> || <style> || <color>
borderparts(sub: list of string, x: array of ref Tok): list of (string, array of ref Tok)
{
	w, s, c: array of ref Tok;
	for(k := 0; k < len x; k++) {
		t := x[k:k+1];
		if(x[k].kind == Kident && isbstyle(lower(x[k].s)) >= 0 || x[k].kind == Kident && lower(x[k].s) == "auto") {
			if(s != nil)
				return nil;
			s = t;
		} else if(x[k].kind == Kdimension || (x[k].kind == Knumber && x[k].n == 0.0) ||
			  (x[k].kind == Kident && (lower(x[k].s) == "thin" || lower(x[k].s) == "medium" || lower(x[k].s) == "thick")) ||
			  (x[k].kind == Kfunction && (x[k].s == "calc" || x[k].s == "min" || x[k].s == "max" || x[k].s == "clamp"))) {
			if(w != nil || x[k].kind == Kdimension && x[k].n < 0.0)
				return nil;	# a negative width makes the whole shorthand invalid (border-width-010)
			w = t;
		} else {
			(ok, nil) := color(t);
			if(!ok || c != nil)
				return nil;
			c = t;
		}
	}
	if(w == nil)
		w = array[] of {ref Tok(Kident, "medium", 0.0, 0, nil)};
	if(s == nil)
		s = array[] of {ref Tok(Kident, "none", 0.0, 0, nil)};
	if(c == nil)
		c = array[] of {ref Tok(Kident, "currentcolor", 0.0, 0, nil)};
	r: list of (string, array of ref Tok);
	for(; sub != nil; sub = tl sub) {
		nm := hd sub;
		if(suffix(nm, "-width"))
			r = (nm, w) :: r;
		else if(suffix(nm, "-style"))
			r = (nm, s) :: r;
		else if(nm == "border-image-source")
			r = (nm, array[] of {ref Tok(Kident, "none", 0.0, 0, nil)}) :: r;	# reset, never set (Backgrounds 3 §4.4): a function colour was taken for an image
		else
			r = (nm, c) :: r;
	}
	return r;
}

isbstyle(s: string): int
{
	case s {
	"none" => return Bnone;
	"hidden" => return Bhidden;
	"solid" => return Bsolid;
	"dashed" => return Bdashed;
	"dotted" => return Bdotted;
	"double" => return Bdouble;
	"groove" => return Bgroove;
	"ridge" => return Bridge;
	"inset" => return Binset;
	"outset" => return Boutset;
	}
	return -1;
}

background(v: array of ref Tok): list of (string, array of ref Tok)
{
	layers := splitcommas(v);
	nl := len layers;
	img, rep, pos, size, att, org, clip: list of ref Tok;
	col := array[] of {ref Tok(Kident, "transparent", 0.0, 0, nil)};
	comma := ref Tok(Kcomma, ",", 0.0, 0, nil);
	li := 0;
	colset := 0;
	for(; layers != nil; layers = tl layers) {
		x := nows(hd layers);
		limg, lrep, lpos, lsize, latt: list of ref Tok;
		boxes: list of ref Tok;
		for(k := 0; k < len x; k++) {
			t := x[k];
			if(t.kind == Kurl || (t.kind == Kfunction && (t.s == "url" || suffix(t.s, "gradient") || t.s == "image-set" || t.s == "-webkit-image-set"))) {
				limg = t :: limg;
				continue;
			}
			if(t.kind == Kident) {
				case lower(t.s) {
				"none" =>
					limg = t :: limg;
					continue;
				"repeat" or "no-repeat" or "repeat-x" or "repeat-y" or "space" or "round" =>
					lrep = t :: lrep;
					continue;
				"scroll" or "fixed" or "local" =>
					latt = t :: latt;
					continue;
				"border-box" or "padding-box" or "content-box" or "text" or "border-area" =>
					boxes = t :: boxes;
					continue;
				"left" or "right" or "top" or "bottom" or "center" =>
					lpos = t :: lpos;
					continue;
				}
			}
			if(t.kind == Kdelim && t.s == "/") {
				# size follows the position
				k++;
				for(; k < len x; k++) {
					u := x[k];
					if(u.kind == Kdimension || u.kind == Kpercent || u.kind == Knumber || u.kind == Kfunction ||
					   (u.kind == Kident && (lower(u.s) == "auto" || lower(u.s) == "cover" || lower(u.s) == "contain")))
						lsize = u :: lsize;
					else
						break;
				}
				k--;
				continue;
			}
			if(t.kind == Kdimension || t.kind == Kpercent || t.kind == Knumber || (t.kind == Kfunction && t.s == "calc")) {
				lpos = t :: lpos;
				continue;
			}
			(ok, nil) := color(x[k:k+1]);
			if(ok && li == nl-1 && !colset) {
				col = x[k:k+1];
				colset = 1;	# a second colour makes the declaration invalid
				continue;
			}
			return nil;
		}
		if(li > 0) {
			img = comma :: img;
			rep = comma :: rep;
			pos = comma :: pos;
			size = comma :: size;
			att = comma :: att;
			org = comma :: org;
			clip = comma :: clip;
		}
		img = joinl(limg, "none", img);
		rep = joinl(lrep, "repeat", rep);
		pos = joinl(lpos, "0%", pos);
		size = joinl(lsize, "auto", size);
		att = joinl(latt, "scroll", att);
		bl := rev(boxes);
		if(bl == nil) {
			org = ref Tok(Kident, "padding-box", 0.0, 0, nil) :: org;
			clip = ref Tok(Kident, "border-box", 0.0, 0, nil) :: clip;
		} else {
			org = hd bl :: org;
			if(tl bl != nil)
				clip = hd tl bl :: clip;
			else
				clip = hd bl :: clip;
		}
		li++;
	}
	# the lists were built backwards; toarray turns them round
	return ("background-color", col) :: ("background-image", toarray(img)) ::
		("background-repeat", toarray(rep)) :: ("background-position", toarray(pos)) ::
		("background-size", toarray(size)) :: ("background-attachment", toarray(att)) ::
		("background-origin", toarray(org)) :: ("background-clip", toarray(clip)) :: nil;
}

rev(l: list of ref Tok): list of ref Tok
{
	r: list of ref Tok;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# prepend the layer's tokens (given reversed) to acc, or the default
joinl(l: list of ref Tok, dflt: string, acc: list of ref Tok): list of ref Tok
{
	if(l == nil) {
		if(dflt == "0%")	# a position: both axes, as one value would centre the other
			return ref Tok(Kpercent, nil, 0.0, 0, nil) :: ref Tok(Kws, " ", 0.0, 0, nil) ::
				ref Tok(Kpercent, nil, 0.0, 0, nil) :: acc;
		return ref Tok(Kident, dflt, 0.0, 0, nil) :: acc;
	}
	ws := ref Tok(Kws, " ", 0.0, 0, nil);
	first := 1;
	for(r := rev(l); r != nil; r = tl r) {
		if(!first)
			acc = ws :: acc;
		acc = hd r :: acc;
		first = 0;
	}
	return acc;
}

font(x: array of ref Tok): list of (string, array of ref Tok)
{
	if(len x == 1 && x[0].kind == Kident)
		case lower(x[0].s) {
		"caption" or "icon" or "menu" or "message-box" or "small-caption" or "status-bar" =>
			x = css->tokenize("13.333px sans-serif");
			x = nows(x);
		}
	r: list of (string, array of ref Tok);
	k := 0;
	for(; k < len x; k++) {
		t := x[k];
		if(t.kind == Kident) {
			case lower(t.s) {
			"normal" =>
				continue;
			"italic" or "oblique" =>
				r = ("font-style", x[k:k+1]) :: r;
				continue;
			"small-caps" =>
				r = ("font-variant", x[k:k+1]) :: r;
				continue;
			"bold" or "bolder" or "lighter" =>
				r = ("font-weight", x[k:k+1]) :: r;
				continue;
			"ultra-condensed" or "extra-condensed" or "condensed" or "semi-condensed" or
			"semi-expanded" or "expanded" or "extra-expanded" or "ultra-expanded" =>
				continue;
			}
		}
		if(t.kind == Knumber && k+1 < len x) {
			r = ("font-weight", x[k:k+1]) :: r;
			continue;
		}
		break;
	}
	# size [/ line-height] family
	if(k >= len x)
		return nil;
	r = ("font-size", x[k:k+1]) :: r;
	k++;
	if(k < len x && x[k].kind == Kdelim && x[k].s == "/") {
		if(k+1 >= len x)
			return nil;
		r = ("line-height", x[k+1:k+2]) :: r;
		k += 2;
	}
	if(k >= len x)
		return nil;
	r = ("font-family", x[k:]) :: r;
	return fill(shorthand("font"), r);
}

flex(x: array of ref Tok): list of (string, array of ref Tok)
{
	num := array[] of {ref Tok(Knumber, nil, 1.0, 1, nil)};
	if(len x == 1 && x[0].kind == Kident) {
		case lower(x[0].s) {
		"none" =>
			return ("flex-grow", css->tokenize("0")) :: ("flex-shrink", css->tokenize("0")) :: ("flex-basis", autov()) :: nil;
		"auto" =>
			return ("flex-grow", num) :: ("flex-shrink", num) :: ("flex-basis", autov()) :: nil;
		}
	}
	grow, shrink, basis: array of ref Tok;
	for(k := 0; k < len x; k++) {
		if(x[k].kind == Knumber && grow == nil)
			grow = x[k:k+1];
		else if(x[k].kind == Knumber && shrink == nil && grow != nil && basis == nil)
			shrink = x[k:k+1];
		else if(basis == nil)
			basis = x[k:k+1];
		else
			return nil;
	}
	if(grow == nil)
		grow = num;
	if(shrink == nil)
		shrink = num;
	if(basis == nil)
		basis = array[] of {ref Tok(Kpercent, nil, 0.0, 0, nil)};
	return ("flex-grow", grow) :: ("flex-shrink", shrink) :: ("flex-basis", basis) :: nil;
}

# ---- applying a longhand ----

apply(st: ref St, nm: string, v: array of ref Tok, parent: ref St, ctx: ref Ctx): int
{
	if(v == nil)
		return 0;
	if((w := iswide(v)) != nil) {
		wide(st, nm, w, parent, ctx);
		return 1;
	}
	mixcur = st.color;
	if(nm == "color" && parent != nil)
		mixcur = parent.color;
	id := ident(v);
	case nm {
	"display" =>
		d := display(nows(v));
		if(d < 0)
			return 0;
		st.display = d;
	"position" =>
		case id {
		"static" => st.position = Pstatic;
		"relative" => st.position = Prelative;
		"absolute" => st.position = Pabsolute;
		"fixed" => st.position = Pfixed;
		"sticky" or "-webkit-sticky" => st.position = Psticky;
		* => return 0;
		}
	"float" =>
		case id {
		"none" => st.float = Fnone;
		"left" or "inline-start" => st.float = Fleft;
		"right" or "inline-end" => st.float = Fright;
		* => return 0;
		}
	"clear" =>
		case id {
		"none" => st.clear = Cnone;
		"left" or "inline-start" => st.clear = Cleft;
		"right" or "inline-end" => st.clear = Cright;
		"both" => st.clear = Cboth;
		* => return 0;
		}
	"box-sizing" =>
		case id {
		"border-box" => st.borderbox = 1;
		"content-box" => st.borderbox = 0;
		* => return 0;
		}
	"width" or "height" or "min-width" or "min-height" or "flex-basis" =>
		(ok, l) := lenauto(v, ctx);
		if(!ok && nm == "flex-basis" && id == "content")
			(ok, l) = (1, kw(Lcontent));
		if(!ok || l.kind == Lpx && (l.px < 0.0 && l.pct == 0.0 || l.pct < 0.0 && l.px == 0.0))
			return 0;	# a negative length or percentage is invalid (height-089)
		case nm {
		"width" => st.width = l;
		"height" => st.height = l;
		"min-width" => st.minwidth = l;
		"min-height" => st.minheight = l;
		"flex-basis" => st.basis = l;
		}
	"max-width" or "max-height" =>
		(ok, l) := lennone(v, ctx);
		if(!ok)
			return 0;
		if(nm == "max-width")
			st.maxwidth = l;
		else
			st.maxheight = l;
	"aspect-ratio" =>
		x := nows(v);
		auto := 0;
		if(len x >= 1 && x[0].kind == Kident && lower(x[0].s) == "auto") {
			x = x[1:];
			auto = 1;
		} else if(len x >= 2 && x[len x - 1].kind == Kident && lower(x[len x - 1].s) == "auto") {
			x = x[0:len x - 1];
			auto = 1;
		}
		if(len x == 0) {
			st.aspect = 0.0;
			st.aspectauto = 0;
			return 1;
		}
		if(x[0].kind != Knumber)
			return 0;
		r := x[0].n;
		if(len x >= 3 && x[1].kind == Kdelim && x[1].s == "/" && x[2].kind == Knumber) {
			if(x[2].n == 0.0)
				r = 0.0;	# a degenerate ratio (0 or infinity) is auto
			else
				r /= x[2].n;
		}
		st.aspect = r;
		st.aspectauto = auto;
	"margin-top" or "margin-right" or "margin-bottom" or "margin-left" =>
		(ok, l) := lenauto(v, ctx);
		if(!ok || (l.kind != Lpx && l.kind != Lauto && l.kind != Lcalc))
			return 0;
		case nm {
		"margin-top" => st.mt = l;
		"margin-right" => st.mr = l;
		"margin-bottom" => st.mb = l;
		"margin-left" => st.ml = l;
		}
	"padding-top" or "padding-right" or "padding-bottom" or "padding-left" =>
		(ok, l) := length(v, ctx);
		if(!ok || l.kind == Lpx && (l.px < 0.0 && l.pct == 0.0 || l.pct < 0.0 && l.px == 0.0))
			return 0;	# a negative length or percentage is invalid (padding-top-089); a calc() is clamped
		case nm {
		"padding-top" => st.pt = l;
		"padding-right" => st.pr = l;
		"padding-bottom" => st.pb = l;
		"padding-left" => st.pl = l;
		}
	"top" or "right" or "bottom" or "left" =>
		(ok, l) := lenauto(v, ctx);
		if(!ok)
			return 0;
		case nm {
		"top" => st.top = l;
		"right" => st.right = l;
		"bottom" => st.bottom = l;
		"left" => st.left = l;
		}
	"border-top-width" or "border-right-width" or "border-bottom-width" or "border-left-width" or
	"outline-width" or "column-rule-width" =>
		w := -1;
		case id {
		"thin" => w = 1;
		"medium" => w = 3;
		"thick" => w = 5;
		* =>
			(ok, l) := length(v, ctx);
			if(!ok || l.kind != Lpx || l.pct != 0.0 || l.px < 0.0)
				return 0;
			w = int l.px;
			if(l.px > 0.0 && w == 0)
				w = 1;	# hairlines are at least a pixel
		}
		case nm {
		"border-top-width" => st.bt = w;
		"border-right-width" => st.br = w;
		"border-bottom-width" => st.bb = w;
		"border-left-width" => st.bl = w;
		"outline-width" => st.outlinew = w;
		"column-rule-width" => st.colrulew = w;
		}
	"border-top-style" or "border-right-style" or "border-bottom-style" or "border-left-style" or
	"outline-style" or "column-rule-style" =>
		b := isbstyle(id);
		if(nm == "outline-style" && id == "auto")
			b = Bsolid;
		if(b < 0)
			return 0;
		case nm {
		"border-top-style" => st.bst = b;
		"border-right-style" => st.bsr = b;
		"border-bottom-style" => st.bsb = b;
		"border-left-style" => st.bsl = b;
		"outline-style" => st.outlines = b;
		"column-rule-style" => st.colrules = b;
		}
	"border-top-color" or "border-right-color" or "border-bottom-color" or "border-left-color" or
	"outline-color" or "text-decoration-color" or "column-rule-color" or "accent-color" or "caret-color" =>
		(ok, c) := color(v);
		if(!ok) {
			if(id == "auto" && (nm == "accent-color" || nm == "caret-color" || nm == "outline-color"))
				c = Ccurrent;
			else
				return 0;
		}
		case nm {
		"border-top-color" => st.bct = c;
		"border-right-color" => st.bcr = c;
		"border-bottom-color" => st.bcb = c;
		"border-left-color" => st.bcl = c;
		"outline-color" => st.outlinec = c;
		"text-decoration-color" => st.decorationcolor = c;
		"column-rule-color" => st.colrulec = c;
		"accent-color" => st.accent = c;
		"caret-color" => st.caret = c;
		}
	"fill" or "stroke" =>
		# for inline svg, which readsvg draws: kept as it can read it
		x := nows(v);
		if(len x != 1)
			return 0;
		pv: string;
		if(x[0].kind == Kident && lower(x[0].s) == "none")
			pv = "none";
		else if(x[0].kind == Kident && lower(x[0].s) == "currentcolor")
			pv = "currentcolor";
		else if(x[0].kind == Kurl)
			pv = "url(" + x[0].s + ")";
		else {
			(ok, c) := color(x);
			if(!ok)
				return 0;
			if(c == Ccurrent)
				pv = "currentcolor";
			else
				pv = sys->sprint("#%.6x", (c >> 8) & 16rFFFFFF);
		}
		if(nm == "fill")
			st.svgfill = pv;
		else
			st.svgstroke = pv;
	"border-image-source" =>
		x := nows(v);
		if(len x != 1)
			return 0;
		bi := bimageof(st);
		if(x[0].kind == Kident && lower(x[0].s) == "none")
			bi.src = nil;
		else if(x[0].kind == Kurl || x[0].kind == Kfunction)
			bi.src = lentoks(x[0:1], ctx)[0];
		else
			return 0;
		st.bimage = bi;
	"border-image-slice" =>
		# [<number> | <percentage>]{1,4} && fill?
		x := nows(v);
		vals: list of Len;
		fl := 0;
		for(k := 0; k < len x; k++) {
			case x[k].kind {
			Kident =>
				if(lower(x[k].s) != "fill" || fl)
					return 0;
				fl = 1;
			Knumber =>
				if(x[k].n < 0.0)
					return 0;
				vals = Len(Lpx, x[k].n, 0.0, nil) :: vals;
			Kpercent =>
				if(x[k].n < 0.0)
					return 0;
				vals = Len(Lpx, 0.0, x[k].n, nil) :: vals;
			* =>
				return 0;
			}
		}
		a := foursides(vals);
		if(a == nil)
			return 0;
		bi := bimageof(st);
		bi.slice = a;
		bi.fill = fl;
		st.bimage = bi;
	"border-image-width" =>
		# [<length-percentage> | <number> | auto]{1,4}
		x := nows(v);
		vals: list of Len;
		for(k := 0; k < len x; k++) {
			if(x[k].kind == Kident && lower(x[k].s) == "auto")
				vals = kw(Lauto) :: vals;
			else if(x[k].kind == Knumber) {
				if(x[k].n < 0.0)
					return 0;
				vals = Len(Lnum, x[k].n, 0.0, nil) :: vals;
			} else {
				(ok, l) := length(x[k:k+1], ctx);
				if(!ok || l.px < 0.0 || l.pct < 0.0)
					return 0;
				vals = l :: vals;
			}
		}
		a := foursides(vals);
		if(a == nil)
			return 0;
		bi := bimageof(st);
		bi.width = a;
		st.bimage = bi;
	"border-image-outset" =>
		# [<length> | <number>]{1,4}
		x := nows(v);
		vals: list of Len;
		for(k := 0; k < len x; k++) {
			if(x[k].kind == Knumber) {
				if(x[k].n < 0.0)
					return 0;
				vals = Len(Lnum, x[k].n, 0.0, nil) :: vals;
			} else {
				(ok, l) := length(x[k:k+1], ctx);
				if(!ok || l.px < 0.0 || l.pct != 0.0)
					return 0;
				vals = l :: vals;
			}
		}
		a := foursides(vals);
		if(a == nil)
			return 0;
		bi := bimageof(st);
		bi.outset = a;
		st.bimage = bi;
	"border-image-repeat" =>
		x := nows(v);
		if(len x < 1 || len x > 2)
			return 0;
		rx := birepeat(x[0]);
		ry := rx;
		if(len x == 2)
			ry = birepeat(x[1]);
		if(rx < 0 || ry < 0)
			return 0;
		bi := bimageof(st);
		bi.repx = rx;
		bi.repy = ry;
		st.bimage = bi;
	"outline-offset" =>
		(ok, l) := length(v, ctx);
		if(!ok)
			return 0;
		st.outlineoff = int l.px;
	"border-top-left-radius" or "border-top-right-radius" or "border-bottom-right-radius" or "border-bottom-left-radius" =>
		x := nows(v);
		if(len x < 1)
			return 0;
		(ok, l) := length(x[0:1], ctx);
		if(!ok)
			return 0;
		case nm {
		"border-top-left-radius" => st.rtl = l;
		"border-top-right-radius" => st.rtr = l;
		"border-bottom-right-radius" => st.rbr = l;
		"border-bottom-left-radius" => st.rbl = l;
		}
	"z-index" =>
		if(id == "auto") {
			st.zauto = 1;
			st.z = 0;
		} else {
			(ok, n) := number(v, ctx);
			if(!ok)
				return 0;
			st.z = int n;
			st.zauto = 0;
		}
	"margin-trim" =>
		# none | block | inline | [ block-start || inline-start || block-end || inline-end ] (Box 4 §4)
		x := nows(v);
		t := 0;
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kident)
				return 0;
			case lower(x[k].s) {
			"none" => t = 0;
			"block" => t |= 3;
			"inline" => t |= 12;
			"block-start" => t |= 1;
			"block-end" => t |= 2;
			"inline-start" => t |= 4;
			"inline-end" => t |= 8;
			* => return 0;
			}
		}
		st.margintrim = t;
	"clip" =>
		# auto | rect(<top>, <right>, <bottom>, <left>), each a length or
		# auto, commas or spaces between (CSS 2.2 §11.1.2)
		if(id == "auto") {
			st.cliprect = nil;
			return 1;
		}
		x := nows(v);
		if(len x != 1 || x[0].kind != Kfunction || x[0].s != "rect")
			return 0;
		a := array[4] of Len;
		k := 0;
		args := nows(x[0].kids);
		for(i := 0; i < len args; i++) {
			if(args[i].kind == Kcomma)
				continue;
			if(k >= 4)
				return 0;
			if(args[i].kind == Kident && lower(args[i].s) == "auto")
				a[k] = kw(Lauto);
			else {
				(ok, l) := length(args[i:i+1], ctx);
				if(!ok || l.kind != Lpx || l.pct != 0.0)
					return 0;
				a[k] = l;
			}
			k++;
		}
		if(k != 4)
			return 0;
		st.cliprect = a;
	"hyphens" =>
		case id {
		"none" => st.hyphens = 0;
		"manual" => st.hyphens = 1;
		"auto" => st.hyphens = 2;
		* => return 0;
		}
	"text-wrap-style" =>
		# auto | balance | stable | pretty (Text 4 §6.3)
		wx := nows(v);
		if(len wx != 1 || wx[0].kind != Kident)
			return 0;
		w := lower(wx[0].s);
		if(w != "auto" && w != "balance" && w != "stable" && w != "pretty")
			return 0;
		st.textwrap = wrapstyle(w);
	"text-autospace" =>
		# normal | auto | no-autospace | [ ideograph-alpha || ideograph-numeric ] (Text 4 §8.3)
		ax := nows(v);
		if(len ax == 0)
			return 0;
		for(k := 0; k < len ax; k++) {
			if(ax[k].kind != Kident)
				return 0;
			case lower(ax[k].s) {
			"normal" or "auto" or "ideograph-alpha" or "ideograph-numeric" or "punctuation" => st.textautospace = 0;
			"no-autospace" => st.textautospace = 1;
			* => return 0;
			}
		}
	"hanging-punctuation" =>
		# none | [ first || [ force-end | allow-end ] || last ] (Text 3 §5.3)
		hx := nows(v);
		hp := 0;
		for(k := 0; k < len hx; k++) {
			if(hx[k].kind != Kident)
				return 0;
			case lower(hx[k].s) {
			"none" =>
				if(len hx != 1)
					return 0;
			"first" => hp |= 1;
			"last" => hp |= 2;
			"force-end" => hp |= 4;
			"allow-end" => hp |= 8;
			* => return 0;
			}
		}
		if((hp & 12) == 12)
			return 0;
		st.hangpunct = hp;
	"text-justify" =>
		case id {
		"auto" => st.textjustify = 0;
		"none" => st.textjustify = 1;
		"inter-word" => st.textjustify = 2;
		"inter-character" or "distribute" => st.textjustify = 3;
		* => return 0;
		}
	"hyphenate-character" =>
		hx := nows(v);
		if(id == "auto")
			st.hyphenchar = "\u2010";	# the hyphen, or hyphen-minus where the font has none (hyphenate())
		else if(len hx == 1 && hx[0].kind == Kstring)
			st.hyphenchar = hx[0].s;
		else
			return 0;
	"word-space-transform" =>
		# none | [ space | ideographic-space ] && auto-phrase? (Text 4 §8.3)
		x := nows(v);
		t := 0;
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kident)
				return 0;
			case lower(x[k].s) {
			"none" => t = 0;
			"space" => t = 1;
			"ideographic-space" => t = 2;
			"auto-phrase" => ;
			* => return 0;
			}
		}
		st.wst = t;
	"contain-intrinsic-size" or "contain-intrinsic-width" or "contain-intrinsic-height" or
	"contain-intrinsic-inline-size" or "contain-intrinsic-block-size" =>
		# one or two of: none | <length> | auto <length> (Sizing 4 §5.1;
		# the last remembered size of auto is not kept, so the length stands)
		x := nows(v);
		a := kw(Lnone);
		bv := kw(Lnone);
		got := 0;
		for(k := 0; k < len x; k++) {
			l := kw(Lnone);
			if(!(x[k].kind == Kident && lower(x[k].s) == "none")) {
				if(x[k].kind == Kident && lower(x[k].s) == "auto") {
					k++;
					if(k >= len x)
						return 0;
				}
				(ok, ll) := length(x[k:k+1], ctx);
				if(!ok || ll.kind != Lpx || ll.pct != 0.0 || ll.px < 0.0)
					return 0;
				l = ll;
			}
			if(got == 0)
				a = l;
			else if(got == 1)
				bv = l;
			else
				return 0;
			got++;
		}
		if(got == 0 || got == 2 && nm != "contain-intrinsic-size")
			return 0;
		if(got == 1)
			bv = a;
		case nm {
		"contain-intrinsic-size" =>
			st.cisw = a;
			st.cish = bv;
		"contain-intrinsic-width" or "contain-intrinsic-inline-size" =>
			st.cisw = a;
		"contain-intrinsic-height" or "contain-intrinsic-block-size" =>
			st.cish = a;
		}
	"contain" =>
		c := 0;
		for(k := 0; k < len v; k++) {
			if(v[k].kind != Css->Kident)
				return 0;
			case lower(v[k].s) {
			"none" => ;
			"strict" => c |= CTpaint|CTlayout|CTsize|CTstyle;
			"content" => c |= CTpaint|CTlayout|CTstyle;
			"paint" => c |= CTpaint;
			"layout" => c |= CTlayout;
			"size" => c |= CTsize;
			"inline-size" => c |= CTinlinesize;
			"style" => c |= CTstyle;
			* => return 0;
			}
		}
		st.contain = c;
	"overflow-x" or "overflow-y" =>
		o: int;
		case id {
		"visible" => o = Ovisible;
		"hidden" => o = Ohidden;
		"clip" => o = Oclip;
		"scroll" => o = Oscroll;
		"auto" or "overlay" => o = Oauto;
		* => return 0;
		}
		if(nm == "overflow-x")
			st.overflowx = o;
		else
			st.overflowy = o;
	"visibility" =>
		case id {
		"visible" => st.visibility = Vvisible;
		"hidden" => st.visibility = Vhidden;
		"collapse" => st.visibility = Vcollapse;
		* => return 0;
		}
	"opacity" =>
		x := trim(v);
		if(len x != 1)
			return 0;
		o: real;
		case x[0].kind {
		Knumber => o = x[0].n;
		Kpercent => o = x[0].n/100.0;
		* => return 0;
		}
		if(o < 0.0) o = 0.0;
		if(o > 1.0) o = 1.0;
		st.opacity = o;
	"transform" =>
		# a list of transform functions (the 2D ones; 3D ones are
		# taken for their 2D part or ignored).  Translations alone
		# are kept as one offset, the general case as the list.
		if(id == "none") {
			st.translated = 0;
			st.tx = st.ty = px(0.0);
			st.tfs = nil;
			return 1;
		}
		x := nows(v);
		if(len x == 0)
			return 0;
		tfl: list of ref Tf;
		pure := 1;
		tx := 0.0;
		ty := 0.0;
		ptx := 0.0;
		pty := 0.0;
		for(i := 0; i < len x; i++) {
			t := x[i];
			if(t.kind != Kfunction)
				return 0;
			args := commas(t.kids);
			n := len args;
			case t.s {	# function names come lowercased
			"translate" or "translatex" or "translatey" or "translate3d" =>
				if(n < 1 || t.s == "translatey" && n > 1 || t.s == "translatex" && n > 1 || t.s == "translate" && n > 2 || t.s == "translate3d" && n != 3)
					return 0;
				lx := px(0.0);
				ly := px(0.0);
				for(k := 0; k < n && k < 2; k++) {
					(ok, l) := length(hd args, ctx);
					args = tl args;
					if(!ok || l.kind != Lpx)
						return 0;
					if(t.s == "translatey" || k == 1)
						ly = l;
					else
						lx = l;
				}
				tx += lx.px;
				ptx += lx.pct;
				ty += ly.px;
				pty += ly.pct;
				tfl = ref Tf(TFtranslate, nil, lx, ly) :: tfl;
			"rotate" or "rotatez" =>
				if(n != 1)
					return 0;
				(ok, a) := angle(hd args, ctx);
				if(!ok)
					return 0;
				tfl = ref Tf(TFrotate, array[] of {a}, px(0.0), px(0.0)) :: tfl;
				pure = 0;
			"scale" or "scalex" or "scaley" or "scale3d" =>
				if(n < 1 || n > 3)
					return 0;
				sx := 1.0;
				sy := 1.0;
				(ok, f) := number(hd args, ctx);
				if(!ok)
					return 0;
				if(t.s == "scaley")
					sy = f;
				else {
					sx = f;
					if(t.s == "scale")
						sy = f;
				}
				if(n > 1 && t.s != "scalex" && t.s != "scaley") {
					(ok, f) = number(hd tl args, ctx);
					if(!ok)
						return 0;
					sy = f;
				}
				tfl = ref Tf(TFscale, array[] of {sx, sy}, px(0.0), px(0.0)) :: tfl;
				pure = 0;
			"skew" or "skewx" or "skewy" =>
				if(n < 1 || n > 2)
					return 0;
				ax := 0.0;
				ay := 0.0;
				(ok, a) := angle(hd args, ctx);
				if(!ok)
					return 0;
				if(t.s == "skewy")
					ay = a;
				else
					ax = a;
				if(n > 1 && t.s == "skew") {
					(ok, a) = angle(hd tl args, ctx);
					if(!ok)
						return 0;
					ay = a;
				}
				tfl = ref Tf(TFskew, array[] of {ax, ay}, px(0.0), px(0.0)) :: tfl;
				pure = 0;
			"matrix" =>
				if(n != 6)
					return 0;
				m := array[6] of real;
				for(k := 0; k < 6; k++) {
					(ok, f) := number(hd args, ctx);
					args = tl args;
					if(!ok)
						return 0;
					m[k] = f;
				}
				tfl = ref Tf(TFmatrix, m, px(0.0), px(0.0)) :: tfl;
				pure = 0;
			"rotatex" or "rotatey" or "rotate3d" or "scalez" or "matrix3d" or "perspective" =>
				;	# no depth here
			* =>
				return 0;
			}
		}
		st.translated = 1;
		st.tx = Len(Lpx, tx, ptx, nil);
		st.ty = Len(Lpx, ty, pty, nil);
		st.tfs = nil;
		if(!pure) {
			st.tfs = array[len tfl] of ref Tf;
			for(k := len tfl - 1; tfl != nil; tfl = tl tfl)
				st.tfs[k--] = hd tfl;
		}
	"transform-origin" =>
		x := nows(v);
		if(len x == 3)
			x = x[0:2];	# a z offset: ignored
		(ok, ox, oy) := position(x, ctx);
		if(!ok)
			return 0;
		st.tox = ox;
		st.toy = oy;
	"color" =>
		(ok, c) := color(v);
		if(!ok)
			return 0;
		if(c == Ccurrent) {
			if(parent != nil)
				c = parent.color;
			else
				c = initial.color;
		}
		st.color = c;
	"background-color" =>
		(ok, c) := color(v);
		if(!ok)
			return 0;
		st.bgcolor = c;
	"background-image" or "background-repeat" or "background-position" or "background-size" or
	"background-attachment" or "background-origin" or "background-clip" or "background-position-x" or
	"background-position-y" =>
		return bglonghand(st, nm, v, ctx);
	"mask-image" or "mask-repeat" or "mask-position" or "mask-size" or "mask-origin" or "mask-clip" =>
		return masklonghand(st, nm, v, ctx);
	"box-shadow" or "text-shadow" =>
		if(id == "none") {
			if(nm == "box-shadow")
				st.shadows = nil;
			else
				st.textshadows = nil;
			return 1;
		}
		sh := shadows(v, ctx);
		if(sh == nil)
			return 0;
		if(nm == "box-shadow")
			st.shadows = sh;
		else
			st.textshadows = sh;
	"font-family" =>
		f := families(v);
		if(f == nil)
			return 0;
		st.family = f;
	"font-size" =>
		pfs := 16.0;
		if(parent != nil)
			pfs = parent.fontsize;
		sz := -1.0;
		case id {
		"xx-small" => sz = 9.0;
		"x-small" => sz = 10.0;
		"small" => sz = 13.0;
		"medium" => sz = 16.0;
		"large" => sz = 18.0;
		"x-large" => sz = 24.0;
		"xx-large" => sz = 32.0;
		"xxx-large" => sz = 48.0;
		"smaller" => sz = pfs/1.2;
		"larger" => sz = pfs*1.2;
		"math" => sz = pfs;
		* =>
			oldfs := ctx.fs;
			ctx.fs = pfs;
			(ok, l) := length(v, ctx);
			ctx.fs = oldfs;
			if(!ok)
				return 0;
			sz = l.resolve(pfs);
			if(sz < 0.0)
				return 0;
		}
		st.fontsize = sz;
	"font-weight" =>
		pw := 400;
		if(parent != nil)
			pw = parent.weight;
		case id {
		"normal" => st.weight = 400;
		"bold" => st.weight = 700;
		"bolder" =>
			if(pw < 350) st.weight = 400;
			else if(pw < 550) st.weight = 700;
			else st.weight = 900;
		"lighter" =>
			if(pw < 550) st.weight = 100;
			else if(pw < 750) st.weight = 400;
			else st.weight = 700;
		* =>
			(ok, n) := number(v, ctx);
			if(!ok || n < 1.0 || n > 1000.0)
				return 0;
			st.weight = int n;
		}
	"font-style" =>
		case id {
		"normal" => st.fontstyle = FSnormal;
		"italic" => st.fontstyle = FSitalic;
		* =>
			x := nows(v);
			if(len x >= 1 && x[0].kind == Kident && lower(x[0].s) == "oblique") {
				# oblique [<angle>]: 14deg unless given (Fonts 4 §3.3)
				a := 14.0;
				if(len x >= 2) {
					(ok, r) := angle(x[1:2], ctx);
					if(!ok)
						return 0;
					a = r * 180.0 / Math->Pi;
					if(a < -90.0 || a > 90.0)
						return 0;
				}
				st.fontstyle = FSoblique;
				st.slant = a;
			} else
				return 0;
		}
	"font-synthesis" =>
		# none, or the kinds a browser may make up (Fonts 4 §5.1)
		x := nows(v);
		b := 0;
		for(i := 0; i < len x; i++) {
			if(x[i].kind != Kident)
				return 0;
			case lower(x[i].s) {
			"none" =>
				if(len x != 1)
					return 0;
			"weight" =>	b |= 1;
			"style" =>	b |= 2;
			"small-caps" or "position" =>	;
			* =>	return 0;
			}
		}
		st.synth = b;
	"font-synthesis-weight" or "font-synthesis-style" =>
		bit := 1;
		if(nm == "font-synthesis-style")
			bit = 2;
		case id {
		"auto" =>	st.synth |= bit;
		"none" =>	st.synth &= ~bit;
		* =>	return 0;
		}
	"font-stretch" or "font-width" =>
		x := nows(v);
		if(len x != 1)
			return 0;
		w := -1.0;
		if(x[0].kind == Kpercent && x[0].n >= 0.0)
			w = x[0].n;
		else if(x[0].kind == Kident)
			case lower(x[0].s) {
			"ultra-condensed" =>	w = 50.0;
			"extra-condensed" =>	w = 62.5;
			"condensed" =>	w = 75.0;
			"semi-condensed" =>	w = 87.5;
			"normal" =>	w = 100.0;
			"semi-expanded" =>	w = 112.5;
			"expanded" =>	w = 125.0;
			"extra-expanded" =>	w = 150.0;
			"ultra-expanded" =>	w = 200.0;
			}
		if(w < 0.0)
			return 0;
		st.stretch = w;
	"font-variant" or "font-variant-caps" =>
		case id {
		"small-caps" or "all-small-caps" => st.smallcaps = 1;
		"normal" or "none" => st.smallcaps = 0;
		* => ;
		}
	"line-height" =>
		if(id == "normal") {
			st.lineheight = kw(Lnormal);
			return 1;
		}
		(ok, n) := number(v, ctx);
		if(ok) {
			if(n < 0.0)
				return 0;
			st.lineheight = Len(Lnum, n, 0.0, nil);
			return 1;
		}
		(okl, l) := length(v, ctx);
		if(!okl)
			return 0;
		st.lineheight = px(l.resolve(st.fontsize));	# % is of the font size
	"text-align" =>
		case id {
		"start" => st.align = Astart;
		"end" => st.align = Aend;
		"left" or "-webkit-left" => st.align = Aleft;
		"right" or "-webkit-right" => st.align = Aright;
		"center" or "-webkit-center" or "-moz-center" or "-internal-center" => st.align = Acenter;
		"justify" => st.align = Ajustify;
		"justify-all" =>
			st.align = Ajustify;
			st.alignlast = Ajustify;	# the last line too (Text 3 §7.1)
		"match-parent" =>
			if(parent != nil)
				st.align = parent.align;
		* => return 0;
		}
	"text-align-last" =>
		case id {
		"auto" => st.alignlast = Aauto;
		"start" => st.alignlast = Astart;
		"end" => st.alignlast = Aend;
		"left" => st.alignlast = Aleft;
		"right" => st.alignlast = Aright;
		"center" => st.alignlast = Acenter;
		"justify" => st.alignlast = Ajustify;
		* => return 0;
		}
	"text-indent" =>
		x := nows(v);
		if(len x < 1)
			return 0;
		(ok, l) := length(x[0:1], ctx);
		if(!ok)
			return 0;
		st.indent = l;
	"text-transform" =>
		case id {
		"none" => st.transform = TTnone;
		"uppercase" => st.transform = TTupper;
		"lowercase" => st.transform = TTlower;
		"capitalize" => st.transform = TTcap;
		"full-width" => st.transform = TTfull;
		"full-size-kana" => ;
		* => return 0;
		}
	"letter-spacing" or "word-spacing" =>
		sp := 0.0;
		if(id != "normal") {
			(ok, l) := length(v, ctx);
			if(!ok)
				return 0;
			sp = l.resolve(st.fontsize);
		}
		if(nm == "letter-spacing")
			st.letterspacing = sp;
		else
			st.wordspacing = sp;
	"font-variation-settings" =>
		# normal, or "tag" number, ... (Fonts 4 §7.3); a tag given twice,
		# the last
		if(id == "normal") {
			st.fontvars = nil;
			return 1;
		}
		r: list of (string, real);
		x := nows(v);
		for(i := 0; i < len x; ) {
			if(x[i].kind != Kstring || len x[i].s != 4 || i + 1 >= len x || x[i+1].kind != Knumber)
				return 0;
			r = (x[i].s, x[i+1].n) :: r;
			i += 2;
			if(i < len x) {
				if(x[i].kind != Kcomma)
					return 0;
				i++;
			}
		}
		fv: list of (string, real);
		for(; r != nil; r = tl r)
			fv = hd r :: fv;
		st.fontvars = fv;
	"font-kerning" =>
		case id {
		"none" => st.nokern = 1;
		"normal" or "auto" => st.nokern = 0;
		* => return 0;
		}
	"font-feature-settings" =>
		# only "kern" matters here: off or 0 turns kerning off
		on := -1;
		for(k := 0; k < len v; k++)
			if(v[k].kind == Kstring && v[k].s == "kern") {
				on = 1;
				for(j := k+1; j < len v && v[j].kind != Kcomma; j++)
					if(v[j].kind == Kident && lower(v[j].s) == "off" || v[j].kind == Knumber && v[j].n == 0.0)
						on = 0;
			}
		if(id == "normal")
			on = 1;
		if(on >= 0)
			st.nokern = !on;
	"white-space" or "white-space-collapse" or "text-wrap-mode" or "text-wrap" =>
		x := nows(v);
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kident)
				return 0;
			case lower(x[k].s) {
			"normal" or "collapse" => if(nm != "text-wrap" && nm != "text-wrap-mode") st.whitespace = Wnormal;
				else if(st.whitespace == Wnowrap) st.whitespace = Wnormal;
			"pre" or "preserve" =>
				if(nm == "white-space") st.whitespace = Wpre;
				else st.whitespace = Wprewrap;
			"nowrap" =>
				if(nm == "white-space")
					st.whitespace = Wnowrap;	# the shorthand: collapsing too
				else case st.whitespace {
				Wprewrap or Wbreakspaces => st.whitespace = Wpre;
				Wpre => ;
				* => st.whitespace = Wnowrap;
				}
			"wrap" or "balance" or "pretty" or "stable" =>
				case st.whitespace {
				Wpre => st.whitespace = Wprewrap;
				Wnowrap => st.whitespace = Wnormal;
				}
				if(nm == "text-wrap")
					st.textwrap = wrapstyle(lower(x[k].s));
			"pre-wrap" => st.whitespace = Wprewrap;
			"pre-line" or "preserve-breaks" => st.whitespace = Wpreline;
			"break-spaces" => st.whitespace = Wbreakspaces;
			"-moz-pre-space" => ;
			* => return 0;
			}
		}
	"word-break" =>
		case id {
		"normal" =>
			st.keepall = 0;
			if(st.breakall == 1)
				st.breakall = 0;	# (line-break: anywhere, 2, is another property's)
		"break-all" =>
			if(st.breakall != 2)
				st.breakall = 1;	# anywhere already breaks everywhere break-all does
		"keep-all" or "auto-phrase" => st.keepall = 1;	# auto-phrase: as keep-all, there being no phrase segmenter (word-break-auto-phrase-001)
		"break-word" => st.anywhere = 2;	# as overflow-wrap: anywhere (Text 4 §5.2)
		* => return 0;
		}
	"line-break" =>
		case id {
		"auto" or "loose" or "normal" or "strict" =>
			if(st.breakall == 2)
				st.breakall = 0;
			st.lbmode = 0;
			if(id == "loose")
				st.lbmode = 1;
			else if(id == "strict")
				st.lbmode = 2;
		"anywhere" =>
			st.breakall = 2;
			st.lbmode = 0;
		* => return 0;
		}
	"overflow-wrap" =>
		case id {
		"normal" => st.anywhere = 0;
		"break-word" => st.anywhere = 1;	# only where a word fails to fit; not counted for min-content
		"anywhere" => st.anywhere = 2;	# counted for min-content too (Text 4 §5.5)
		* => return 0;
		}
	"text-overflow" =>
		st.ellipsis = id == "ellipsis";
	"text-decoration-line" =>
		dl := 0;
		x := nows(v);
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kident)
				return 0;
			case lower(x[k].s) {
			"underline" => dl |= TDunder;
			"overline" => dl |= TDover;
			"line-through" => dl |= TDthrough;
			"none" or "blink" or "spelling-error" or "grammar-error" => ;
			* => return 0;
			}
		}
		st.decoration = dl;
	"text-decoration-style" =>
		case id {
		"solid" => st.decorationstyle = Bsolid;
		"double" => st.decorationstyle = Bdouble;
		"dotted" => st.decorationstyle = Bdotted;
		"dashed" => st.decorationstyle = Bdashed;
		"wavy" => st.decorationstyle = Bgroove;
		* => return 0;
		}
	"vertical-align" =>
		case id {
		"baseline" => st.valign = VAbaseline;
		"top" => st.valign = VAtop;
		"middle" => st.valign = VAmiddle;
		"bottom" => st.valign = VAbottom;
		"text-top" => st.valign = VAtexttop;
		"text-bottom" => st.valign = VAtextbottom;
		"sub" => st.valign = VAsub;
		"super" => st.valign = VAsuper;
		* =>
			(ok, l) := length(v, ctx);
			if(!ok)
				return 0;
			st.valign = VAlen;
			st.valignlen = px(l.resolve(lineheightpx(st)));
		}
	"direction" =>
		case id {
		"ltr" => st.dirrtl = 0;
		"rtl" => st.dirrtl = 1;
		* => return 0;
		}
	"unicode-bidi" =>
		case id {
		"normal" => st.unicodebidi = UBnormal;
		"embed" => st.unicodebidi = UBembed;
		"isolate" => st.unicodebidi = UBisolate;
		"bidi-override" => st.unicodebidi = UBoverride;
		"isolate-override" => st.unicodebidi = UBisolateoverride;
		"plaintext" => st.unicodebidi = UBplaintext;
		* => return 0;
		}
	"tab-size" =>
		# a number of spaces, or a length (kept negated: px)
		(ok, n) := number(v, ctx);
		if(ok) {
			if(n < 0.0)
				return 0;
			st.tabsize = n;
		} else {
			(okl, l) := length(v, ctx);
			if(!okl || l.pct != 0.0 || l.px < 0.0)
				return 0;
			st.tabsize = -l.px;
		}
	"list-style-type" =>
		x := trim(v);
		if(len x != 1)
			return 0;
		if(x[0].kind == Kstring)
			st.liststyle = "\"" + x[0].s;
		else if(x[0].kind == Kident)
			st.liststyle = lower(x[0].s);
		else if(x[0].kind == Kfunction && x[0].s == "symbols")
			st.liststyle = "disc";
		else
			return 0;
	"list-style-position" =>
		case id {
		"inside" => st.listinside = 1;
		"outside" => st.listinside = 0;
		* => return 0;
		}
	"list-style-image" =>
		if(id == "none")
			st.listimage = nil;
		else {
			x := trim(v);
			if(len x != 1 || (x[0].kind != Kurl && x[0].kind != Kfunction))
				return 0;
			st.listimage = x[0];
		}
	"content" =>
		x := trim(v);
		if(id == "normal" || id == "none")
			st.content = nil;
		else
			st.content = x;
	"quotes" =>
		if(id == "none")
			st.quotes = array[0] of string;
		else if(id == "auto")
			st.quotes = nil;
		else {
			x := nows(v);
			if(len x % 2 != 0)
				return 0;
			q := array[len x] of string;
			for(k := 0; k < len x; k++) {
				if(x[k].kind != Kstring)
					return 0;
				q[k] = x[k].s;
			}
			st.quotes = q;
		}
	"counter-reset" =>
		st.counterreset = counters(v);
	"counter-increment" =>
		st.counterincrement = counters(v);
	"counter-set" =>
		st.counterset = counters(v);
	"flex-direction" =>
		case id {
		"row" => st.flexdir = 0;
		"row-reverse" => st.flexdir = 1;
		"column" => st.flexdir = 2;
		"column-reverse" => st.flexdir = 3;
		* => return 0;
		}
	"flex-wrap" =>
		case id {
		"nowrap" => st.flexwrap = 0;
		"wrap" => st.flexwrap = 1;
		"wrap-reverse" => st.flexwrap = 2;
		* => return 0;
		}
	"flex-grow" or "flex-shrink" =>
		(ok, n) := number(v, ctx);
		if(!ok || n < 0.0)
			return 0;
		if(nm == "flex-grow")
			st.grow = n;
		else
			st.shrink = n;
	"order" =>
		(ok, n) := number(v, ctx);
		if(!ok)
			return 0;
		st.order = int n;
	"justify-content" or "align-items" or "align-self" or "align-content" or "justify-items" or "justify-self" =>
		a := alignment(nows(v));
		if(a < 0)
			return 0;
		bit := 0;
		case nm {
		"justify-content" => st.justifycontent = a; bit = 2;
		"align-items" => st.alignitems = a; bit = 4;
		"align-self" => st.alignself = a; bit = 4;
		"align-content" => st.aligncontent = a; bit = 1;
		"justify-items" => st.justifyitems = a; bit = 8;
		"justify-self" => st.justifyself = a; bit = 8;
		}
		if(sawsafe)
			st.safe |= bit;
		else
			st.safe &= ~bit;
	"row-gap" or "column-gap" =>
		l: Len;
		if(id == "normal")
			l = kw(Lnormal);
		else {
			ok: int;
			(ok, l) = length(v, ctx);
			if(!ok)
				return 0;
		}
		if(nm == "row-gap")
			st.rowgap = l;
		else
			st.colgap = l;
	"grid-template-columns" or "grid-template-rows" or "grid-auto-columns" or "grid-auto-rows" =>
		x := trim(v);
		sub := 0;
		if(len x > 0 && x[0].kind == Kident && lower(x[0].s) == "subgrid" && nm[5] == 't') {
			sub = 1;	# subgrid: what follows names its lines
			x = trim(x[1:]);
		}
		if(id == "none")
			x = nil;
		else
			x = lentoks(x, ctx);
		case nm {
		"grid-template-columns" =>
			st.gridcols = x;
			st.subcols = sub;
		"grid-template-rows" =>
			st.gridrows = x;
			st.subrows = sub;
		"grid-auto-columns" => st.autocols = x;
		"grid-auto-rows" => st.autorows = x;
		}
	"grid-template-areas" =>
		if(id == "none") {
			st.gridareas = nil;
			return 1;
		}
		x := nows(v);
		a := array[len x] of string;
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kstring)
				return 0;
			a[k] = x[k].s;
		}
		st.gridareas = a;
	"grid-auto-flow" =>
		f := 0;
		x := nows(v);
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kident)
				return 0;
			case lower(x[k].s) {
			"row" => ;
			"column" => f |= 1;
			"dense" => f |= 2;
			* => return 0;
			}
		}
		st.autoflow = f;
	"grid-lanes-direction" =>
		f := 0;
		x := nows(v);
		for(k := 0; k < len x; k++) {
			if(x[k].kind != Kident)
				return 0;
			case lower(x[k].s) {
			"normal" => ;
			"row" => f |= 1;
			"column" => f |= 2;
			"fill-reverse" => f |= 4;
			"track-reverse" => f |= 8;
			* => return 0;
			}
		}
		if((f & 3) == 3)
			return 0;
		st.lanesdir = f;
	"grid-lanes-pack" =>
		case id {
		"normal" => st.lanespack = 0;
		"dense" => st.lanespack = 1;
		* => return 0;
		}
	"flow-tolerance" =>
		case id {
		"normal" => st.tolerance = kw(Lnormal);
		"infinite" => st.tolerance = kw(Lnone);
		* =>
			(ok, l) := length(v, ctx);
			if(!ok)
				return 0;
			st.tolerance = l;
		}
	"grid-row-start" or "grid-row-end" or "grid-column-start" or "grid-column-end" =>
		(ok, g) := gridline(nows(v));
		if(!ok)
			return 0;
		case nm {
		"grid-row-start" => st.rowstart = g;
		"grid-row-end" => st.rowend = g;
		"grid-column-start" => st.colstart = g;
		"grid-column-end" => st.colend = g;
		}
	"-x-grid-area-name" =>
		st.gridarea = trim(v)[0].s;
	"table-layout" =>
		case id {
		"auto" => st.tablefixed = 0;
		"fixed" => st.tablefixed = 1;
		* => return 0;
		}
	"border-collapse" =>
		case id {
		"collapse" => st.collapse = 1;
		"separate" => st.collapse = 0;
		* => return 0;
		}
	"border-spacing" =>
		x := nows(v);
		if(len x < 1 || len x > 2)
			return 0;
		(ok, l) := length(x[0:1], ctx);
		if(!ok)
			return 0;
		st.spacingx = st.spacingy = l.px;
		if(len x == 2) {
			(ok, l) = length(x[1:2], ctx);
			if(!ok)
				return 0;
			st.spacingy = l.px;
		}
	"caption-side" =>
		st.captionbottom = id == "bottom";
	"empty-cells" =>
		st.hideempty = id == "hide";
	"column-count" =>
		if(id == "auto")
			st.colcount = 0;
		else {
			(ok, n) := number(v, ctx);
			if(!ok || n < 1.0)
				return 0;
			st.colcount = int n;
		}
	"column-width" =>
		(ok, l) := lenauto(v, ctx);
		if(!ok)
			return 0;
		st.colwidth = l;
	"object-fit" =>
		case id {
		"fill" => st.objectfit = 0;
		"contain" => st.objectfit = 1;
		"cover" => st.objectfit = 2;
		"none" => st.objectfit = 3;
		"scale-down" => st.objectfit = 4;
		* => return 0;
		}
	"cursor" =>
		x := nows(v);
		if(len x > 0 && x[len x - 1].kind == Kident)
			st.cursor = lower(x[len x - 1].s);
	"pointer-events" =>
		st.pointer = id != "none";
	"appearance" =>
		st.appearance = id != "none";
	"-x-ignored" =>
		;
	* =>
		return 0;	# unknown property: the declaration is ignored
	}
	return 1;
}

lineheightpx(st: ref St): real
{
	case st.lineheight.kind {
	Lnum =>
		return st.lineheight.px * st.fontsize;
	Lpx =>
		return st.lineheight.px;
	}
	return st.fontsize * 1.2;
}

display(x: array of ref Tok): int
{
	outer := "";
	inner := "";
	li := 0;
	for(k := 0; k < len x; k++) {
		if(x[k].kind != Kident)
			return -1;
		s := lower(x[k].s);
		case s {
		"none" => return Dnone;
		"contents" => return Dcontents;
		"block" or "inline" or "run-in" => outer = s;
		"flow" or "flow-root" or "table" or "flex" or "grid" or "grid-lanes" or "ruby" => inner = s;
		"list-item" => li = 1;
		"inline-block" => return Dinlineblock;
		"inline-flex" or "-webkit-inline-flex" or "-webkit-inline-box" => return Dinlineflex;
		"inline-grid" => return Dinlinegrid;
		"inline-grid-lanes" => return Dinlinegridlanes;
		"inline-table" => return Dinlinetable;
		"-webkit-flex" => return Dflex;
		"-webkit-box" or "-moz-box" => return Dblock;
		"table-row-group" => return Dtablerowgroup;
		"table-header-group" => return Dtableheadergroup;
		"table-footer-group" => return Dtablefootergroup;
		"table-row" => return Dtablerow;
		"table-cell" => return Dtablecell;
		"table-column-group" => return Dtablecolumngroup;
		"table-column" => return Dtablecolumn;
		"table-caption" => return Dtablecaption;
		"ruby-base" or "ruby-text" or "ruby-base-container" or "ruby-text-container" => return Dinline;
		* => return -1;
		}
	}
	if(li)
		return Dlistitem;
	if(outer == "inline") {
		case inner {
		"" or "flow" or "ruby" => return Dinline;
		"flow-root" => return Dinlineblock;
		"table" => return Dinlinetable;
		"flex" => return Dinlineflex;
		"grid" => return Dinlinegrid;
		"grid-lanes" => return Dinlinegridlanes;
		}
	}
	case inner {
	"flow-root" => return Dflowroot;
	"table" => return Dtable;
	"flex" => return Dflex;
	"grid" => return Dgrid;
	"grid-lanes" => return Dgridlanes;
	"ruby" => return Dinline;
	}
	return Dblock;
}

# whether the last alignment value parsed had the "safe" keyword
sawsafe := 0;

alignment(x: array of ref Tok): int
{
	a := -1;
	sawsafe = 0;
	for(k := 0; k < len x; k++) {
		if(x[k].kind != Kident)
			return -1;
		case lower(x[k].s) {
		"normal" => a = ALnormal;
		"stretch" => a = ALstretch;
		"start" or "flex-start" or "self-start" => a = ALstart;
		"end" or "flex-end" or "self-end" => a = ALend;
		"center" => a = ALcenter;
		"baseline" or "first" or "last" => a = ALbaseline;
		"space-between" => a = ALbetween;
		"space-around" => a = ALaround;
		"space-evenly" => a = ALevenly;
		"left" => a = ALleft;
		"right" => a = ALright;
		"auto" => a = ALauto;
		"flow-start" => a = ALflowstart;
		"flow-end" => a = ALflowend;
		"safe" => sawsafe = 1;
		"unsafe" or "legacy" => ;
		* => return -1;
		}
	}
	return a;
}

gridline(x: array of ref Tok): (int, Gline)
{
	g := Gline(0, 0, nil);
	for(k := 0; k < len x; k++) {
		t := x[k];
		case t.kind {
		Kident =>
			case lower(t.s) {
			"auto" => ;
			"span" => g.span = 1;
			* => g.name = t.s;
			}
		Knumber =>
			if(g.span)
				g.span = int t.n;
			else
				g.n = int t.n;
		* =>
			return (0, g);
		}
	}
	if(g.span && g.n != 0) {
		g.span = g.n;
		g.n = 0;
	}
	return (1, g);
}

counters(v: array of ref Tok): array of ref Tok
{
	if(ident(v) == "none")
		return nil;
	return nows(v);
}

# Compute the lengths inside a token list (grid tracks, transforms) to
# px dimensions, leaving the structure for layout to interpret.
lentoks(v: array of ref Tok, ctx: ref Ctx): array of ref Tok
{
	r := array[len v] of ref Tok;
	for(k := 0; k < len v; k++) {
		t := v[k];
		if(t.kind == Kdimension) {
			(ok, p) := unit(t.n, t.s, ctx);
			if(ok)
				t = ref Tok(Kdimension, "px", p, 0, nil);
		} else if(t.kind == Kfunction && (t.s == "calc" || t.s == "min" || t.s == "max" || t.s == "clamp")) {
			e := calcexpr(t, ctx);
			if(e != nil) {
				(lin, p, pc) := fold(e);
				if(lin && pc == 0.0)
					t = ref Tok(Kdimension, "px", p, 0, nil);
				else if(lin && p == 0.0)
					t = ref Tok(Kpercent, nil, pc, 0, nil);
			}
		} else if(t.kids != nil)
			t = ref Tok(t.kind, t.s, t.n, t.flag, lentoks(t.kids, ctx));
		r[k] = t;
	}
	return r;
}

families(v: array of ref Tok): list of string
{
	r: list of string;
	for(l := splitcommas(v); l != nil; l = tl l) {
		x := nows(hd l);
		if(len x == 0)
			return nil;
		nm := "";
		for(k := 0; k < len x; k++) {
			case x[k].kind {
			Kstring =>
				nm = x[k].s;
			Kident =>
				if(nm != "")
					nm += " ";
				nm += x[k].s;
			* =>
				return nil;
			}
		}
		r = lower(nm) :: r;
	}
	o: list of string;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

shadows(v: array of ref Tok, ctx: ref Ctx): array of ref Shadow
{
	parts := splitcommas(v);
	a := array[len parts] of ref Shadow;
	i := 0;
	for(; parts != nil; parts = tl parts) {
		x := nows(hd parts);
		s := ref Shadow(0.0, 0.0, 0.0, 0.0, Ccurrent, 0);
		nl := 0;
		for(k := 0; k < len x; k++) {
			if(x[k].kind == Kident && lower(x[k].s) == "inset") {
				s.inset = 1;
				continue;
			}
			(ok, l) := length(x[k:k+1], ctx);
			if(ok && l.kind == Lpx) {
				case nl++ {
				0 => s.x = l.px;
				1 => s.y = l.px;
				2 => s.blur = l.px;
				3 => s.spread = l.px;
				* => return nil;
				}
				continue;
			}
			(okc, c) := color(x[k:k+1]);
			if(!okc)
				return nil;
			s.color = c;
		}
		if(nl < 2)
			return nil;
		a[i++] = s;
	}
	return a;
}

# mask-image and the rest: the background longhands' grammar, on the
# mask layers, whose origin is the border box (Masking 1 §6.6)
masking := 0;

masklonghand(st: ref St, nm: string, v: array of ref Tok, ctx: ref Ctx): int
{
	saved := st.bg;
	st.bg = st.mask;
	masking = 1;
	ok := bglonghand(st, "background-" + nm[len "mask-":], v, ctx);
	masking = 0;
	st.mask = st.bg;
	st.bg = saved;
	return ok;
}

deforigin(): int
{
	if(masking)
		return BOXborder;
	return BOXpadding;
}

# The mask shorthand: the background shorthand's layers without a
# colour or an attachment; mask-mode and mask-composite keywords are
# accepted and not modelled (alpha and source-over are what icons use).
mask(v: array of ref Tok): list of (string, array of ref Tok)
{
	kept: list of ref Tok;
	boxes := 0;
	for(i := 0; i < len v; i++) {
		t := v[i];
		if(t.kind == Kident)
			case lower(t.s) {
			"alpha" or "luminance" or "match-source" or "add" or "subtract" or "intersect" or "exclude" or "no-clip" =>
				continue;
			"border-box" or "padding-box" or "content-box" or "fill-box" or "stroke-box" or "view-box" =>
				boxes = 1;
			}
		kept = t :: kept;
	}
	r := background(toarray(kept));
	if(r == nil)
		return nil;
	out: list of (string, array of ref Tok);
	for(; r != nil; r = tl r) {
		(n, x) := hd r;
		case n {
		"background-color" or "background-attachment" =>
			continue;
		"background-origin" or "background-clip" =>
			if(!boxes)
				x = array[] of {ref Tok(Kident, "border-box", 0.0, 0, nil)};
		}
		out = ("mask-" + n[len "background-":], x) :: out;
	}
	return out;
}

bglonghand(st: ref St, nm: string, v: array of ref Tok, ctx: ref Ctx): int
{
	vals := splitcommas(v);
	n := len vals;
	if(n == 0)
		return 0;
	# the image list says how many layers there are; the other lists
	# are repeated to fill them (Backgrounds 3 §2.3)
	nl := n;
	if(nm != "background-image" && st.bg != nil)
		nl = len st.bg;
	nb := array[nl] of ref Bg;
	for(k := 0; k < nl; k++) {
		if(st.bg != nil)
			nb[k] = ref *st.bg[k % len st.bg];	# the lists set so far repeat
		else
			nb[k] = ref Bg(nil, Rrepeat, Rrepeat, px(0.0), px(0.0), kw(Lauto), kw(Lauto), BOXborder, deforigin(), 0);
	}
	st.bg = nb;
	layers := array[n] of array of ref Tok;
	for(k = 0; vals != nil; vals = tl vals)
		layers[k++] = nows(hd vals);
	for(k = 0; k < nl; k++) {
		x := layers[k % n];
		b := st.bg[k];
		if(len x == 0)
			return 0;
		case nm {
		"background-image" =>
			if(x[0].kind == Kident && lower(x[0].s) == "none")
				b.img = nil;
			else if(x[0].kind == Kurl || x[0].kind == Kfunction)
				b.img = lentoks(x[0:1], ctx)[0];
			else
				return 0;
		"background-repeat" =>
			rx, ry: int;
			case lower(x[0].s) {
			"repeat-x" => (rx, ry) = (Rrepeat, Rnorepeat);
			"repeat-y" => (rx, ry) = (Rnorepeat, Rrepeat);
			* =>
				rx = repeat(x[0]);
				ry = rx;
				if(len x > 1)
					ry = repeat(x[1]);
			}
			if(rx < 0 || ry < 0)
				return 0;
			b.rx = rx;
			b.ry = ry;
		"background-position" or "background-position-x" or "background-position-y" =>
			(ok, px, py) := position(x, ctx);
			if(!ok)
				return 0;
			if(nm != "background-position-y")
				b.posx = px;
			if(nm == "background-position-y")
				b.posy = px;
			else if(nm == "background-position")
				b.posy = py;
		"background-size" =>
			if(x[0].kind == Kident && lower(x[0].s) == "cover") {
				b.sizex = Len(Lcontent, -1.0, 0.0, nil);
				b.sizey = kw(Lauto);
			} else if(x[0].kind == Kident && lower(x[0].s) == "contain") {
				b.sizex = Len(Lcontent, -2.0, 0.0, nil);
				b.sizey = kw(Lauto);
			} else {
				(ok, l) := lenauto(x[0:1], ctx);
				if(!ok)
					return 0;
				b.sizex = l;
				b.sizey = kw(Lauto);
				if(len x > 1) {
					(ok, l) = lenauto(x[1:2], ctx);
					if(!ok)
						return 0;
					b.sizey = l;
				}
			}
		"background-attachment" =>
			b.attfixed = lower(x[0].s) == "fixed";
		"background-origin" or "background-clip" =>
			bx: int;
			case lower(x[0].s) {
			"border-box" => bx = BOXborder;
			"padding-box" => bx = BOXpadding;
			"content-box" => bx = BOXcontent;
			"text" => bx = BOXtext;
			"border-area" => bx = BOXborderarea;
			* => return 0;
			}
			if(nm == "background-origin" && (bx == BOXtext || bx == BOXborderarea))
				return 0;
			if(nm == "background-origin")
				b.origin = bx;
			else
				b.clip = bx;
		}
	}
	return 1;
}

repeat(t: ref Tok): int
{
	if(t.kind != Kident)
		return -1;
	case lower(t.s) {
	"repeat" => return Rrepeat;
	"no-repeat" => return Rnorepeat;
	"space" => return Rspace;
	"round" => return Rround;
	}
	return -1;
}

# background-position: up to four values, keywords and offsets
position(x: array of ref Tok, ctx: ref Ctx): (int, Len, Len)
{
	h := Len(Lpx, 0.0, 50.0, nil);
	v := h;
	hset := 0;
	vset := 0;
	for(k := 0; k < len x; k++) {
		t := x[k];
		if(t.kind == Kident) {
			kwd := lower(t.s);
			off := px(0.0);
			# an offset after an edge keyword measures from that edge,
			# in the three- and four-value forms only: "right 10px" is
			# a horizontal keyword and a vertical length (Backgrounds 3 §3.6)
			if(len x >= 3 && k+1 < len x && x[k+1].kind != Kident && kwd != "center") {
				(ok, l) := length(x[k+1:k+2], ctx);
				if(!ok)
					return (0, h, v);
				off = l;
				k++;
			}
			case kwd {
			"left" =>
				h = off;
				hset = 1;
			"right" =>
				h = Len(Lpx, -off.px, 100.0 - off.pct, nil);
				hset = 1;
			"top" =>
				v = off;
				vset = 1;
			"bottom" =>
				v = Len(Lpx, -off.px, 100.0 - off.pct, nil);
				vset = 1;
			"center" =>
				;
			* =>
				return (0, h, v);
			}
			continue;
		}
		(ok, l) := length(x[k:k+1], ctx);
		if(!ok)
			return (0, h, v);
		if(!hset) {
			h = l;
			hset = 1;
		} else {
			v = l;
			vset = 1;
		}
	}
	return (1, h, v);
}

# 'inherit', 'initial' and friends: copy one longhand's computed value.
copyprop(d, s: ref St, nm: string)
{
	aliasrtl = d.dirrtl;
	case alias(nm) {
	"display" => d.display = s.display;
	"position" => d.position = s.position;
	"float" => d.float = s.float;
	"clear" => d.clear = s.clear;
	"box-sizing" => d.borderbox = s.borderbox;
	"width" => d.width = s.width;
	"height" => d.height = s.height;
	"min-width" => d.minwidth = s.minwidth;
	"min-height" => d.minheight = s.minheight;
	"max-width" => d.maxwidth = s.maxwidth;
	"max-height" => d.maxheight = s.maxheight;
	"aspect-ratio" => d.aspect = s.aspect; d.aspectauto = s.aspectauto;
	"margin-top" => d.mt = s.mt;
	"margin-right" => d.mr = s.mr;
	"margin-bottom" => d.mb = s.mb;
	"margin-left" => d.ml = s.ml;
	"padding-top" => d.pt = s.pt;
	"padding-right" => d.pr = s.pr;
	"padding-bottom" => d.pb = s.pb;
	"padding-left" => d.pl = s.pl;
	"border-top-width" => d.bt = s.bt;
	"border-right-width" => d.br = s.br;
	"border-bottom-width" => d.bb = s.bb;
	"border-left-width" => d.bl = s.bl;
	"border-top-style" => d.bst = s.bst;
	"border-right-style" => d.bsr = s.bsr;
	"border-bottom-style" => d.bsb = s.bsb;
	"border-left-style" => d.bsl = s.bsl;
	"border-top-color" => d.bct = s.bct;
	"border-right-color" => d.bcr = s.bcr;
	"border-bottom-color" => d.bcb = s.bcb;
	"border-left-color" => d.bcl = s.bcl;
	"border-top-left-radius" => d.rtl = s.rtl;
	"border-top-right-radius" => d.rtr = s.rtr;
	"border-bottom-right-radius" => d.rbr = s.rbr;
	"border-bottom-left-radius" => d.rbl = s.rbl;
	"top" => d.top = s.top;
	"right" => d.right = s.right;
	"bottom" => d.bottom = s.bottom;
	"left" => d.left = s.left;
	"z-index" =>
		d.z = s.z;
		d.zauto = s.zauto;
	"overflow-x" => d.overflowx = s.overflowx;
	"contain" => d.contain = s.contain;
	"word-space-transform" => d.wst = s.wst;
	"hyphens" => d.hyphens = s.hyphens;
	"hyphenate-character" => d.hyphenchar = s.hyphenchar;
	"text-justify" => d.textjustify = s.textjustify;
	"hanging-punctuation" => d.hangpunct = s.hangpunct;
	"text-autospace" => d.textautospace = s.textautospace;
	"text-wrap-style" => d.textwrap = s.textwrap;
	"clip" => d.cliprect = s.cliprect;
	"margin-trim" => d.margintrim = s.margintrim;
	"contain-intrinsic-size" or "contain-intrinsic-width" or "contain-intrinsic-inline-size" or
	"contain-intrinsic-height" or "contain-intrinsic-block-size" =>
		d.cisw = s.cisw;
		d.cish = s.cish;
	"overflow-y" => d.overflowy = s.overflowy;
	"visibility" => d.visibility = s.visibility;
	"opacity" => d.opacity = s.opacity;
	"transform" =>
		d.translated = s.translated;
		d.tx = s.tx;
		d.ty = s.ty;
		d.tfs = s.tfs;
	"transform-origin" =>
		d.tox = s.tox;
		d.toy = s.toy;
	"color" => d.color = s.color;
	"background-color" => d.bgcolor = s.bgcolor;
	"background-image" or "background-repeat" or "background-position" or "background-size" or
	"background-attachment" or "background-origin" or "background-clip" =>
		d.bg = s.bg;
	"mask-image" or "mask-repeat" or "mask-position" or "mask-size" or "mask-origin" or "mask-clip" =>
		d.mask = s.mask;
	"box-shadow" => d.shadows = s.shadows;
	"text-shadow" => d.textshadows = s.textshadows;
	"outline-width" => d.outlinew = s.outlinew;
	"outline-style" => d.outlines = s.outlines;
	"outline-color" => d.outlinec = s.outlinec;
	"outline-offset" => d.outlineoff = s.outlineoff;
	"border-image-source" or "border-image-slice" or "border-image-width" or "border-image-outset" or "border-image-repeat" => d.bimage = s.bimage;
	"font-family" => d.family = s.family;
	"font-size" => d.fontsize = s.fontsize;
	"font-weight" => d.weight = s.weight;
	"font-style" =>
		d.fontstyle = s.fontstyle;
		d.slant = s.slant;
	"font-stretch" or "font-width" => d.stretch = s.stretch;
	"font-synthesis" or "font-synthesis-weight" or "font-synthesis-style" => d.synth = s.synth;
	"font-variant" or "font-variant-caps" => d.smallcaps = s.smallcaps;
	"line-height" => d.lineheight = s.lineheight;
	"text-align" => d.align = s.align;
	"text-align-last" => d.alignlast = s.alignlast;
	"text-indent" => d.indent = s.indent;
	"text-transform" => d.transform = s.transform;
	"letter-spacing" => d.letterspacing = s.letterspacing;
	"font-kerning" or "font-feature-settings" => d.nokern = s.nokern;
	"font-variation-settings" => d.fontvars = s.fontvars;
	"word-spacing" => d.wordspacing = s.wordspacing;
	"white-space" or "white-space-collapse" or "text-wrap-mode" => d.whitespace = s.whitespace;
	"text-wrap" =>
		d.whitespace = s.whitespace;
		d.textwrap = s.textwrap;
	"word-break" or "line-break" =>
		d.breakall = s.breakall;
		d.keepall = s.keepall;
		d.lbmode = s.lbmode;
	"overflow-wrap" => d.anywhere = s.anywhere;
	"text-overflow" => d.ellipsis = s.ellipsis;
	"text-decoration-line" => d.decoration = s.decoration;
	"text-decoration-color" => d.decorationcolor = s.decorationcolor;
	"text-decoration-style" => d.decorationstyle = s.decorationstyle;
	"vertical-align" =>
		d.valign = s.valign;
		d.valignlen = s.valignlen;
	"direction" => d.dirrtl = s.dirrtl;
	"unicode-bidi" => d.unicodebidi = s.unicodebidi;
	"tab-size" => d.tabsize = s.tabsize;
	"list-style-type" => d.liststyle = s.liststyle;
	"list-style-position" => d.listinside = s.listinside;
	"list-style-image" => d.listimage = s.listimage;
	"content" => d.content = s.content;
	"quotes" => d.quotes = s.quotes;
	"counter-reset" => d.counterreset = s.counterreset;
	"counter-increment" => d.counterincrement = s.counterincrement;
	"counter-set" => d.counterset = s.counterset;
	"flex-direction" => d.flexdir = s.flexdir;
	"flex-wrap" => d.flexwrap = s.flexwrap;
	"flex-grow" => d.grow = s.grow;
	"flex-shrink" => d.shrink = s.shrink;
	"flex-basis" => d.basis = s.basis;
	"order" => d.order = s.order;
	"justify-content" => d.justifycontent = s.justifycontent;
	"align-items" => d.alignitems = s.alignitems;
	"align-self" => d.alignself = s.alignself;
	"align-content" => d.aligncontent = s.aligncontent;
	"justify-items" => d.justifyitems = s.justifyitems;
	"justify-self" => d.justifyself = s.justifyself;
	"row-gap" => d.rowgap = s.rowgap;
	"column-gap" => d.colgap = s.colgap;
	"grid-template-columns" => d.gridcols = s.gridcols; d.subcols = s.subcols;
	"grid-template-rows" => d.gridrows = s.gridrows; d.subrows = s.subrows;
	"grid-template-areas" => d.gridareas = s.gridareas;
	"grid-auto-columns" => d.autocols = s.autocols;
	"grid-auto-rows" => d.autorows = s.autorows;
	"grid-auto-flow" => d.autoflow = s.autoflow;
	"grid-lanes-direction" => d.lanesdir = s.lanesdir;
	"grid-lanes-pack" => d.lanespack = s.lanespack;
	"flow-tolerance" => d.tolerance = s.tolerance;
	"grid-row-start" => d.rowstart = s.rowstart;
	"grid-row-end" => d.rowend = s.rowend;
	"grid-column-start" => d.colstart = s.colstart;
	"grid-column-end" => d.colend = s.colend;
	"table-layout" => d.tablefixed = s.tablefixed;
	"border-collapse" => d.collapse = s.collapse;
	"border-spacing" =>
		d.spacingx = s.spacingx;
		d.spacingy = s.spacingy;
	"caption-side" => d.captionbottom = s.captionbottom;
	"empty-cells" => d.hideempty = s.hideempty;
	"column-count" => d.colcount = s.colcount;
	"column-width" => d.colwidth = s.colwidth;
	"column-rule-width" => d.colrulew = s.colrulew;
	"column-rule-style" => d.colrules = s.colrules;
	"column-rule-color" => d.colrulec = s.colrulec;
	"object-fit" => d.objectfit = s.objectfit;
	"cursor" => d.cursor = s.cursor;
	"pointer-events" => d.pointer = s.pointer;
	"appearance" => d.appearance = s.appearance;
	"accent-color" => d.accent = s.accent;
	"caret-color" => d.caret = s.caret;
	"fill" => d.svgfill = s.svgfill;
	"stroke" => d.svgstroke = s.svgstroke;
	}
}

# ---- presentational hints (HTML §15) ----

hints(d: ref Doc, n: int): list of ref Decl
{
	nd := d.nodes[n];
	if(nd.ns == Dom->SVG && nd.name == "svg" && nd.attrs != nil) {
		# an outer svg's width and height attributes are its CSS width
		# and height (SVG 2 §7.2); px or %, as img's
		p := parentel(d, n);
		if(p == 0 || d.nodes[p].ns != Dom->SVG) {
			h := dimhint(d, n, "width", "width") + dimhint(d, n, "height", "height");
			if(h == "")
				return nil;
			decls := css->parsedecls(h);
			r: list of ref Decl;
			for(k := len decls - 1; k >= 0; k--)
				r = decls[k] :: r;
			return r;
		}
	}
	if(nd.ns != Dom->HTML)
		return nil;
	# a cell's hints come from its table's attributes (cellpadding,
	# border) whether or not it has any of its own
	if(nd.attrs == nil && nd.tag != Dom->Ttd && nd.tag != Dom->Tth && !rowish(nd.tag))
		return nil;
	s := "";
	rules := tablerules(d, n);
	case nd.tag {
	Dom->Tbody =>
		s += colorhint(d, n, "bgcolor", "background-color");
		s += colorhint(d, n, "text", "color");
		if((b := d.attr(n, "background")) != nil)
			s += "background-image:url(\"" + b + "\");";
	Dom->Ttable =>
		s += dimhint(d, n, "width", "width") + dimhint(d, n, "height", "height");
		s += colorhint(d, n, "bgcolor", "background-color");
		if(d.hasattr(n, "border")) {
			b := d.attr(n, "border");
			w := atoi(b);
			if(b == "")
				w = 1;
			s += sys->sprint("border-width:%dpx;", w);
		}
		if((cs := d.attr(n, "cellspacing")) != nil)
			s += sys->sprint("border-spacing:%dpx;", atoi(cs));
		case lower(d.attr(n, "align")) {
		"left" => s += "float:left;";
		"right" => s += "float:right;";
		"center" => s += "margin-left:auto;margin-right:auto;";
		}
		if(rulesof(d, n) != nil) {
			# rules= (HTML §15.3.11): the collapsing model, the parts
			# ruled below; the table's own border hidden unless given
			s += "border-collapse:collapse;";
			if(!d.hasattr(n, "border"))
				s += "border-style:hidden;";
		}
	Dom->Ttd or Dom->Tth =>
		s += dimhint(d, n, "width", "width") + dimhint(d, n, "height", "height");
		s += colorhint(d, n, "bgcolor", "background-color");
		if(d.hasattr(n, "nowrap"))
			s += "white-space:nowrap;";
		s += alignhint(d, n) + valignhint(d, n);
		# cellpadding of the table; and border=0 on it gives its
		# cells no border (HTML §15.3.9: only a value above zero does)
		for(t := d.nodes[n].parent; t != 0; t = d.nodes[t].parent)
			if(d.nodes[t].tag == Dom->Ttable) {
				if((cp := d.attr(t, "cellpadding")) != nil)
					s += sys->sprint("padding:%dpx;", atoi(cp));
				if(d.hasattr(t, "border") && (tb := d.attr(t, "border")) != "" && atoi(tb) == 0)
					s += "border-width:0;";
				break;
			}
		# (widths and styles only: the colour stays the table's, inherited)
		case rules {
		"cols" => s += "border-left-width:1px;border-left-style:solid;border-right-width:1px;border-right-style:solid;";
		"all" => s += "border-width:1px;border-style:solid;";
		"none" => s += "border-style:none;";
		}
	Dom->Ttr or Dom->Tthead or Dom->Ttbody or Dom->Ttfoot =>
		s += colorhint(d, n, "bgcolor", "background-color") + alignhint(d, n) + valignhint(d, n);
		s += dimhint(d, n, "height", "height");
		if(nd.tag == Dom->Ttr && (rules == "rows" || rules == "all") ||
		   nd.tag != Dom->Ttr && rules == "groups")
			s += "border-top-width:1px;border-top-style:solid;border-bottom-width:1px;border-bottom-style:solid;";
	Dom->Tcolgroup or Dom->Tcol =>
		s += dimhint(d, n, "width", "width");	# <col width=40> (HTML §15.3.9; border-image-repeat-002's reference)
		if(nd.tag == Dom->Tcolgroup && rules == "groups" || rules == "cols" || rules == "all")
			s += "border-left-width:1px;border-left-style:solid;border-right-width:1px;border-right-style:solid;";
	Dom->Timg or Dom->Tobject or Dom->Tvideo or Dom->Tcanvas or Dom->Tiframe or Dom->Tembed or Dom->Tinput =>
		if(nd.tag == Dom->Tiframe && d.hasattr(n, "frameborder") && atoi(d.attr(n, "frameborder")) == 0)
			s += "border-width:0;";
		if(nd.tag != Dom->Tinput || lower(d.attr(n, "type")) == "image") {
			if(nd.tag != Dom->Tcanvas)	# a canvas's width and height are its bitmap's: its natural size, not a hint
				s += dimhint(d, n, "width", "width") + dimhint(d, n, "height", "height");
			if((h := d.attr(n, "hspace")) != nil)
				s += sys->sprint("margin-left:%dpx;margin-right:%dpx;", atoi(h), atoi(h));
			if((v := d.attr(n, "vspace")) != nil)
				s += sys->sprint("margin-top:%dpx;margin-bottom:%dpx;", atoi(v), atoi(v));
			if((b := d.attr(n, "border")) != nil)
				s += sys->sprint("border:%dpx solid;", atoi(b));
			case lower(d.attr(n, "align")) {
			"left" => s += "float:left;";
			"right" => s += "float:right;";
			"middle" or "center" or "absmiddle" => s += "vertical-align:middle;";
			"top" => s += "vertical-align:top;";
			"bottom" or "baseline" => s += "vertical-align:baseline;";
			}
		}
	Dom->Tfont =>
		s += colorhint(d, n, "color", "color");
		if((f := d.attr(n, "face")) != nil)
			s += "font-family:" + f + ";";
		if((sz := d.attr(n, "size")) != nil && sz != "") {
			k := 3;
			if(sz[0] == '+')
				k = 3 + atoi(sz[1:]);
			else if(sz[0] == '-')
				k = 3 - atoi(sz[1:]);
			else
				k = atoi(sz);
			if(k < 1) k = 1;
			if(k > 7) k = 7;
			s += "font-size:" + names0[k] + ";";
		}
	Dom->Thr =>
		s += dimhint(d, n, "width", "width");
		if((sz := d.attr(n, "size")) != nil)
			s += sys->sprint("height:%dpx;border-width:0;", atoi(sz) - 2);
		if((c := d.attr(n, "color")) != nil)
			s += "background-color:" + c + ";border-color:" + c + ";";
		if(d.hasattr(n, "noshade"))
			s += "border-style:solid;background-color:gray;";
		case lower(d.attr(n, "align")) {
		"left" => s += "margin-left:0;";
		"right" => s += "margin-right:0;";
		}
	Dom->Tdiv or Dom->Tp or Dom->Th1 or Dom->Th2 or Dom->Th3 or Dom->Th4 or Dom->Th5 or
	Dom->Th6 or Dom->Tcaption or Dom->Tlegend =>
		s += alignhint(d, n);
	Dom->Tul or Dom->Tol or Dom->Tli =>
		if((t := d.attr(n, "type")) != nil)
			case t {
			"1" => s += "list-style-type:decimal;";
			"a" => s += "list-style-type:lower-alpha;";
			"A" => s += "list-style-type:upper-alpha;";
			"i" => s += "list-style-type:lower-roman;";
			"I" => s += "list-style-type:upper-roman;";
			* => s += "list-style-type:" + lower(t) + ";";
			}
		if(nd.tag == Dom->Tol) {
			# start= and reversed (HTML §15.3.8): the list-item counter
			# counts from start, or down (to 1, or from start)
			st := d.attr(n, "start");
			if(d.hasattr(n, "reversed")) {
				s += "counter-reset:reversed(list-item)";
				if(st != nil)
					s += " " + string (int st + 1);	# (int, not atoi: start may be negative)
				s += ";";
			} else if(st != nil)
				s += sys->sprint("counter-reset:list-item %d;", int st - 1);
		}
	Dom->Ttextarea =>
		if((c := d.attr(n, "cols")) != nil)
			s += sys->sprint("width:%dch;", atoi(c));
		if((r := d.attr(n, "rows")) != nil)
			s += sys->sprint("height:%dem;", atoi(r)+atoi(r)/5);
	Dom->Tcenter =>
		;
	}
	if(s == "")
		return nil;
	decls := css->parsedecls(s);
	r: list of ref Decl;
	for(k := len decls - 1; k >= 0; k--)
		r = decls[k] :: r;
	return r;
}

colorhint(d: ref Doc, n: int, attr, prop: string): string
{
	v := d.attr(n, attr);
	if(v == nil || v == "")
		return "";
	v = trimstr(v);
	# legacy colour values: bare hex digits are hex
	if(len v == 6 || len v == 3) {
		allhex := 1;
		for(k := 0; k < len v; k++)
			if(hexval(v[k]) < 0)
				allhex = 0;
		if(allhex)
			v = "#" + v;
	}
	return prop + ":" + v + ";";
}

dimhint(d: ref Doc, n: int, attr, prop: string): string
{
	v := d.attr(n, attr);
	if(v == nil)
		return "";
	v = trimstr(v);
	k := 0;
	while(k < len v && (v[k] >= '0' && v[k] <= '9' || v[k] == '.'))
		k++;
	if(k == 0)
		return "";
	if(k < len v && v[k] == '%')
		return prop + ":" + v[0:k] + "%;";
	return prop + ":" + v[0:k] + "px;";
}

alignhint(d: ref Doc, n: int): string
{
	case lower(d.attr(n, "align")) {
	"left" => return "text-align:left;";
	"right" => return "text-align:right;";
	"center" or "middle" => return "text-align:center;";
	"justify" => return "text-align:justify;";
	}
	return "";
}

valignhint(d: ref Doc, n: int): string
{
	case lower(d.attr(n, "valign")) {
	"top" => return "vertical-align:top;";
	"middle" or "center" => return "vertical-align:middle;";
	"bottom" => return "vertical-align:bottom;";
	"baseline" => return "vertical-align:baseline;";
	}
	return "";
}

trimstr(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	e := len s;
	while(e > i && (s[e-1] == ' ' || s[e-1] == '\t' || s[e-1] == '\n'))
		e--;
	return s[i:e];
}

atoi(s: string): int
{
	v := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		v = v*10 + s[i] - '0';
	return v;
}

# ---- text form of a computed style ----

names0 := array[] of {"", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"};
names1 := array[] of {"static", "relative", "absolute", "fixed", "sticky"};
names2 := array[] of {"none", "left", "right"};
names3 := array[] of {"normal", "italic", "oblique"};
names4 := array[] of {"start", "end", "left", "right", "center", "justify"};
names5 := array[] of {"normal", "pre", "nowrap", "pre-wrap", "pre-line", "break-spaces"};
names6 := array[] of {"visible", "hidden", "collapse"};
names7 := array[] of {"row", "row-reverse", "column", "column-reverse"};

dump(st: ref St): string
{
	s := "";
	s += "display " + displaynames[st.display] + "\n";
	s += "position " + names1[st.position] + "\n";
	s += "float " + names2[st.float] + "\n";
	s += "width " + lenstr(st.width) + "\n";
	s += "height " + lenstr(st.height) + "\n";
	s += "margin " + lenstr(st.mt) + " " + lenstr(st.mr) + " " + lenstr(st.mb) + " " + lenstr(st.ml) + "\n";
	s += "padding " + lenstr(st.pt) + " " + lenstr(st.pr) + " " + lenstr(st.pb) + " " + lenstr(st.pl) + "\n";
	s += sys->sprint("border-width %d %d %d %d\n", st.bt, st.br, st.bb, st.bl);
	s += "color " + colstr(st.color) + "\n";
	s += "background-color " + colstr(st.bgcolor) + "\n";
	fam := "";
	for(l := st.family; l != nil; l = tl l) {
		if(fam != "")
			fam += ",";
		fam += hd l;
	}
	s += "font-family " + fam + "\n";
	s += "font-size " + realstr(st.fontsize) + "px\n";
	s += sys->sprint("font-weight %d\n", st.weight);
	s += "font-style " + names3[st.fontstyle] + "\n";
	s += "line-height " + lenstr(st.lineheight) + "\n";
	s += "text-align " + names4[st.align] + "\n";
	s += "white-space " + names5[st.whitespace] + "\n";
	s += "opacity " + realstr(st.opacity) + "\n";
	if(st.translated)
		s += "transform translate(" + lenstr(st.tx) + ", " + lenstr(st.ty) + ")\n";
	s += "visibility " + names6[st.visibility] + "\n";
	if(st.display == Dflex || st.display == Dinlineflex) {
		s += "flex-direction " + names7[st.flexdir] + "\n";
		s += "flex " + realstr(st.grow) + " " + realstr(st.shrink) + " " + lenstr(st.basis) + "\n";
	}
	if(st.content != nil)
		s += "content " + css->tostring(st.content) + "\n";
	return s;
}

displaynames := array[] of {
	"none", "contents", "block", "inline", "inline-block", "flow-root", "list-item",
	"flex", "inline-flex", "grid", "inline-grid", "table", "inline-table",
	"table-row-group", "table-header-group", "table-footer-group", "table-row",
	"table-cell", "table-column-group", "table-column", "table-caption",
};

lenstr(l: Len): string
{
	case l.kind {
	Lpx =>
		if(l.pct == 0.0)
			return realstr(l.px) + "px";
		if(l.px == 0.0)
			return realstr(l.pct) + "%";
		return "calc(" + realstr(l.pct) + "% + " + realstr(l.px) + "px)";
	Lauto => return "auto";
	Lnone => return "none";
	Lnormal => return "normal";
	Lnum => return realstr(l.px);
	Lmin => return "min-content";
	Lmax => return "max-content";
	Lfit => return "fit-content";
	Lstretch => return "stretch";
	Lcontent => return "content";
	Lcalc => return "calc(...)";
	}
	return "?";
}

realstr(r: real): string
{
	if(r == real int r)
		return string int r;
	return sys->sprint("%.4g", r);
}

colstr(c: int): string
{
	if(c == Ccurrent)
		return "currentcolor";
	return sys->sprint("#%.8ux", c);
}
