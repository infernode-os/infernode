implement Scene;

#
# scene — the 2-D scene model, record grammar, camera and renderer
# (see module/scene.m and docs/scene-design.md).
#
# The model is a set of stanzas: every entity, feature and layer is the
# attr=value list its producer wrote, kept verbatim (so a server can
# serve it back and a recording can reproduce it) plus fields parsed
# from it for drawing.  Nothing here knows what the things are.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	drawm: Draw;
	Display, Font, Image, Path, Point, Rect: import drawm;
include "math.m";
	math: Math;
include "string.m";
	str: String;
include "lucitheme.m";
include "geoproj.m";
	geoproj: Geoproj;
include "scene.m";

include "bufio.m";
include "imagefile.m";
include "imgload.m";
	imgload: Imgload;

NBUCKET:	con 257;
TILE:		con 256.0;
EARTHC:		con 40075016.686;	# equatorial circumference, metres
MAXTRAIL:	con 4096;

display: ref Display;
font: ref Font;

# chrome colours (theme), as RRGGBBAA
bgc, gridc, gtextc, hudc, textc: int;

# colour cache: RRGGBBAA -> 1x1 replicated image
ccache: array of list of (int, ref Image);

# image-layer cache: one resampled image per layer file, valid for one camera
Imgc: adt {
	file:	string;
	src:	ref Image;	# decoded, RGBA32
	key:	string;		# camera+rect it was resampled for
	out:	ref Image;
	outr:	Rect;
};
imgcache: list of ref Imgc;

inited := 0;

initbase()
{
	if(inited)
		return;
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;	# Rect and Point methods, display or not
	math = load Math Math->PATH;
	str = load String String->PATH;
	geoproj = load Geoproj Geoproj->PATH;
	if(geoproj != nil)
		geoproj->init();
	inited = 1;
}

init(d: ref Display, f: ref Font)
{
	initbase();
	display = d;
	font = f;
	ccache = array[NBUCKET] of list of (int, ref Image);
	imgcache = nil;
	retheme();
}

retheme()
{
	bgc = int 16r0E1116FF; gridc = int 16r223044FF;
	gtextc = int 16r5A6B82FF; hudc = int 16rB8C4D4FF; textc = int 16rDDE3EAFF;
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgc = th.bg; gridc = th.border; gtextc = th.dim; hudc = th.text2; textc = th.text;
	}
}

# ── Colour ───────────────────────────────────────────────────

# Draw colours are premultiplied by alpha; stanzas are not.
premul(c: int): int
{
	a := c & 16rFF;
	if(a == 16rFF)
		return c;
	r := ((c >> 24) & 16rFF) * a / 255;
	g := ((c >> 16) & 16rFF) * a / 255;
	b := ((c >> 8) & 16rFF) * a / 255;
	return (r << 24) | (g << 16) | (b << 8) | a;
}

color(c: int): ref Image
{
	h := (c ^ (c >> 13)) & 16r7FFFFFFF;
	h %= NBUCKET;
	for(l := ccache[h]; l != nil; l = tl l) {
		(k, im) := hd l;
		if(k == c)
			return im;
	}
	im := display.color(premul(c));
	ccache[h] = (c, im) :: ccache[h];
	return im;
}

withalpha(c, a: int): int
{
	return (c & ~16rFF) | ((c & 16rFF) * a / 255);
}

parsecolor(s: string): (int, int)
{
	if(len s != 6 && len s != 8)
		return (0, 0);
	v := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		d: int;
		if(c >= '0' && c <= '9') d = c - '0';
		else if(c >= 'a' && c <= 'f') d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F') d = c - 'A' + 10;
		else return (0, 0);
		v = v * 16 + d;
	}
	if(len s == 6)
		v = (v << 8) | 16rFF;
	return (1, v);
}

# Categorical colours, distinguishable on dark and light grounds.  A
# group named for a colour gets that colour; any other name hashes to a
# stable slot, so the same group is the same colour in every run.
PALETTE := array[] of {
	int 16r4EA8DEFF, int 16rF2A541FF, int 16r3DBE8BFF, int 16rE8D44DFF,
	int 16rD980C0FF, int 16rF06A4AFF, int 16r8E9BFFFF, int 16rB0B8C4FF,
};

groupcolor(name: string): int
{
	case name {
	"blue" =>	return int 16r4EA8DEFF;
	"red" =>	return int 16rF06A4AFF;
	"green" =>	return int 16r3DBE8BFF;
	"yellow" =>	return int 16rE8D44DFF;
	"orange" =>	return int 16rF2A541FF;
	"purple" or "pink" =>	return int 16rD980C0FF;
	"white" =>	return int 16rE6EAF0FF;
	"grey" or "gray" =>	return int 16rB0B8C4FF;
	}
	return PALETTE[strhash(name) % len PALETTE];
}

affilcolor(a: string): int
{
	case a {
	"friend" =>	return int 16r35C7FFFF;
	"hostile" =>	return int 16rFF4D4DFF;
	"neutral" =>	return int 16r5BE37AFF;
	}
	return int 16rF2C14EFF;
}

entcolor(o: ref Obj): int
{
	if(o.hascol)
		return o.col;
	g := o.get("group");
	if(g != nil)
		return groupcolor(g);
	return affilcolor(o.get("affil"));
}

# ── Parsing ──────────────────────────────────────────────────

stanza(text: string): list of (string, string)
{
	initbase();
	kv: list of (string, string);
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines) {
		line := trim(hd lines);
		if(line == "" || line[0] == '#')
			continue;
		(k, v, ok) := splitkv(line);
		if(ok)
			kv = (k, v) :: kv;
	}
	return rev(kv);
}

attrs(toks: list of string): list of (string, string)
{
	initbase();
	kv: list of (string, string);
	for(; toks != nil; toks = tl toks) {
		(k, v, ok) := splitkv(hd toks);
		if(ok)
			kv = (k, v) :: kv;
	}
	return rev(kv);
}

splitkv(s: string): (string, string, int)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '=')
			return (trim(s[0:i]), trim(s[i+1:]), i > 0);
	return (nil, nil, 0);
}

getattr(kv: list of (string, string), k: string): string
{
	for(; kv != nil; kv = tl kv) {
		(ak, av) := hd kv;
		if(ak == k)
			return av;
	}
	return nil;
}

realattr(kv: list of (string, string), k: string): (int, real)
{
	s := getattr(kv, k);
	if(s == nil)
		return (0, 0.0);
	return (1, real s);
}

parsepts(s: string): array of (real, real)
{
	(n, toks) := sys->tokenize(s, " \t");
	pa := array[n] of (real, real);
	i := 0;
	for(; toks != nil; toks = tl toks) {
		(nil, ll) := sys->tokenize(hd toks, ",");
		if(len ll >= 2)
			pa[i++] = (real hd ll, real hd tl ll);
	}
	return pa[0:i];
}

kindname(kind: int): string
{
	case kind {
	ENT =>	return "ent";
	FEAT =>	return "feat";
	LAYER =>	return "layer";
	}
	return nil;
}

kindof(name: string): int
{
	case name {
	"ent" or "entities" =>	return ENT;
	"feat" or "features" =>	return FEAT;
	"layer" or "layers" =>	return LAYER;
	}
	return -1;
}

dirname(kind: int): string
{
	case kind {
	ENT =>	return "entities";
	FEAT =>	return "features";
	LAYER =>	return "layers";
	}
	return nil;
}

shapeof(s, kind: string): int
{
	case s {
	"dot" =>	return SDOT;
	"square" =>	return SSQUARE;
	"triangle" =>	return STRIANGLE;
	"diamond" =>	return SDIAMOND;
	"circle" =>	return SCIRCLE;
	"cross" =>	return SCROSS;
	"ring" =>	return SRING;
	}
	# the geo contract's kind vocabulary
	case kind {
	"air" =>	return STRIANGLE;
	"sea" or "subsurface" =>	return SDIAMOND;
	"ground" or "installation" =>	return SSQUARE;
	}
	return SDOT;
}

# Parse the drawing fields of o from its attrs, in frame f.
parseobj(o: ref Obj, f: int)
{
	kv := o.attrs;
	o.label = getattr(kv, "label");
	(o.hascol, o.col) = parsecolor(getattr(kv, "color"));
	(o.hasfill, o.fill) = parsecolor(getattr(kv, "fill"));
	o.width = 1;
	if((s := getattr(kv, "width")) != nil)
		o.width = int s;
	if(o.width < 1)
		o.width = 1;
	o.dash = getattr(kv, "dash") == "1";
	o.dim = getattr(kv, "dim") == "1";
	o.hide = getattr(kv, "hide") == "1";
	case o.kind {
	ENT =>
		if(o.label == nil)
			o.label = o.id;
		ka := "x"; kb := "y";
		if(f == GEO) {
			ka = "lat"; kb = "lon";
		}
		(oka, a) := realattr(kv, ka);
		(okb, b) := realattr(kv, kb);
		o.haspos = oka && okb;
		o.a = a; o.b = b;
		o.shape = shapeof(getattr(kv, "shape"), getattr(kv, "kind"));
		(o.hascourse, o.course) = realattr(kv, "course");
		(o.hasstale, o.stale) = realattr(kv, "stale");
		o.size = 6;
		if((s = getattr(kv, "size")) != nil)
			o.size = int s;
		if(o.size < 2)
			o.size = 2;
		o.trail = -1;
		if((s = getattr(kv, "trail")) != nil)
			o.trail = int s;
	FEAT =>
		o.typ = getattr(kv, "type");
		if(o.typ == nil)
			o.typ = "polyline";
		o.pts = parsepts(getattr(kv, "points"));
		(nil, o.radius) = realattr(kv, "radius");
	LAYER =>
		o.typ = getattr(kv, "kind");
		(nil, o.step) = realattr(kv, "step");
		o.file = getattr(kv, "file");
		o.dir = getattr(kv, "dir");
		o.bounds = parsepts(getattr(kv, "bounds"));
		o.opacity = 255;
		if((s = getattr(kv, "opacity")) != nil)
			o.opacity = int s;
	}
}

# ── Obj ──────────────────────────────────────────────────────

Obj.get(o: self ref Obj, k: string): string
{
	return getattr(o.attrs, k);
}

Obj.text(o: self ref Obj): string
{
	s := "";
	for(kv := o.attrs; kv != nil; kv = tl kv) {
		(k, v) := hd kv;
		s += k + "=" + v + "\n";
	}
	return s;
}

Obj.record(o: self ref Obj): string
{
	return kindname(o.kind) + " " + recattrs(o.id :: nil, o.attrs);
}

recattrs(head: list of string, kv: list of (string, string)): string
{
	l := rev_s(head);
	for(; kv != nil; kv = tl kv) {
		(k, v) := hd kv;
		l = (k + "=" + v) :: l;
	}
	return str->quoted(rev_s(l));
}

# ── Table ────────────────────────────────────────────────────

newtab(): ref Tab
{
	return ref Tab(array[NBUCKET] of list of ref Obj, 0, nil);
}

strhash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = (h * 31 + s[i]) & 16r7FFFFFF;
	return h;
}

tabfind(t: ref Tab, id: string): ref Obj
{
	for(l := t.b[strhash(id) % NBUCKET]; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

tabdel(t: ref Tab, id: string): int
{
	h := strhash(id) % NBUCKET;
	nl: list of ref Obj;
	found := 0;
	for(l := t.b[h]; l != nil; l = tl l)
		if((hd l).id == id)
			found = 1;
		else
			nl = hd l :: nl;
	if(found) {
		t.b[h] = nl;
		t.n--;
		t.sorted = nil;
	}
	return found;
}

# ── Model ────────────────────────────────────────────────────

Model.new(): ref Model
{
	initbase();
	m := ref Model;
	m.frame = GEO;
	m.proj = "mercator";
	m.units = "m";
	m.tabs = array[] of {newtab(), newtab(), newtab()};
	return m;
}

Model.find(m: self ref Model, kind: int, id: string): ref Obj
{
	if(kind < 0 || kind >= len m.tabs)
		return nil;
	return tabfind(m.tabs[kind], id);
}

Model.set(m: self ref Model, kind: int, id: string, kv: list of (string, string))
{
	if(kind < 0 || kind >= len m.tabs || id == nil)
		return;
	t := m.tabs[kind];
	o := tabfind(t, id);
	if(o == nil) {
		o = ref Obj;
		o.kind = kind;
		o.id = id;
		h := strhash(id) % NBUCKET;
		t.b[h] = o :: t.b[h];
		t.n++;
		t.sorted = nil;
	}
	o.attrs = kv;
	parseobj(o, m.frame);
	m.gen++;
}

Model.del(m: self ref Model, kind: int, id: string): int
{
	if(kind < 0 || kind >= len m.tabs)
		return 0;
	if(tabdel(m.tabs[kind], id)) {
		m.gen++;
		return 1;
	}
	return 0;
}

Model.clear(m: self ref Model)
{
	for(i := 0; i < len m.tabs; i++)
		m.tabs[i] = newtab();
	m.gen++;
}

Model.setmeta(m: self ref Model, kv: list of (string, string))
{
	m.meta = kv;
	oldf := m.frame;
	m.frame = GEO;
	if(getattr(kv, "frame") == "xy")
		m.frame = XY;
	m.proj = getattr(kv, "projection");
	if(m.proj == nil)
		m.proj = "mercator";
	m.units = getattr(kv, "units");
	if(m.units == nil)
		m.units = "m";
	m.title = getattr(kv, "title");
	m.trail = 0;
	if((s := getattr(kv, "trail")) != nil)
		m.trail = int s;
	if(m.frame != oldf)	# positions are frame-relative: reparse
		for(k := 0; k < len m.tabs; k++)
			for(i := 0; i < NBUCKET; i++)
				for(l := m.tabs[k].b[i]; l != nil; l = tl l)
					parseobj(hd l, m.frame);
	m.gen++;
}

Model.settime(m: self ref Model, t: real)
{
	if(m.hast && t == m.t)
		return;
	m.t = t;
	m.hast = 1;
	m.gen++;
}

Model.objs(m: self ref Model, kind: int): array of ref Obj
{
	if(kind < 0 || kind >= len m.tabs)
		return nil;
	t := m.tabs[kind];
	if(t.sorted != nil || t.n == 0) {
		if(t.sorted == nil)
			t.sorted = array[0] of ref Obj;
		return t.sorted;
	}
	a := array[t.n] of ref Obj;
	j := 0;
	for(i := 0; i < NBUCKET; i++)
		for(l := t.b[i]; l != nil; l = tl l)
			a[j++] = hd l;
	sortobjs(a[0:j]);
	t.sorted = a[0:j];
	return t.sorted;
}

Model.count(m: self ref Model, kind: int): int
{
	if(kind < 0 || kind >= len m.tabs)
		return 0;
	return m.tabs[kind].n;
}

Model.metatext(m: self ref Model): string
{
	s := "";
	for(kv := m.meta; kv != nil; kv = tl kv) {
		(k, v) := hd kv;
		s += k + "=" + v + "\n";
	}
	return s;
}

Model.dump(m: self ref Model): string
{
	s := "clear\n";
	if(m.meta != nil)
		s += recattrs("meta" :: nil, m.meta) + "\n";
	if(m.hast)
		s += "time " + fmtreal(m.t) + "\n";
	for(k := LAYER; k >= ENT; k--) {
		a := m.objs(k);
		for(i := 0; i < len a; i++)
			s += a[i].record() + "\n";
	}
	return s;
}

Model.apply(m: self ref Model, rec: string): string
{
	rec = trim(rec);
	if(rec == "" || rec[0] == '#')
		return nil;
	toks := str->unquoted(rec);
	if(toks == nil)
		return nil;
	verb := hd toks;
	toks = tl toks;
	case verb {
	"time" =>
		if(toks == nil)
			return "time: missing value";
		m.settime(real hd toks);
	"ent" or "feat" or "layer" =>
		if(toks == nil)
			return verb + ": missing id";
		id := hd toks;
		if(!goodid(id))
			return verb + ": bad id: " + id;
		m.set(kindof(verb), id, attrs(tl toks));
	"meta" =>
		m.setmeta(attrs(toks));
	"del" =>
		if(toks == nil || tl toks == nil)
			return "del: usage: del ent|feat|layer id";
		k := kindof(hd toks);
		if(k < 0)
			return "del: unknown kind: " + hd toks;
		m.del(k, hd tl toks);
	"clear" =>
		m.clear();
	* =>
		return "unknown record: " + verb;
	}
	return nil;
}

# An id is a file name: no slash, not . or .., no control characters.
goodid(id: string): int
{
	if(id == "" || id == "." || id == "..")
		return 0;
	for(i := 0; i < len id; i++)
		if(id[i] == '/' || id[i] < 16r20)
			return 0;
	return 1;
}

MAXDEPTH: con 4;	# scene layers nest; a scene that layers itself stops here

Model.read(dir: string): ref Model
{
	return readat(dir, 0);
}

readat(dir: string, depth: int): ref Model
{
	m := readflat(dir);
	resolveat(m, depth);
	return m;
}

Model.resolve(m: self ref Model)
{
	resolveat(m, 0);
}

# Read the scenes a model's scene layers name.  The names resolve in the
# reader's namespace: a viewer overlays what it can see.
resolveat(m: ref Model, depth: int)
{
	layers := m.objs(LAYER);
	for(i := 0; i < len layers; i++) {
		l := layers[i];
		l.sub = nil;
		if(l.typ == "scene" && l.dir != nil && depth < MAXDEPTH)
			l.sub = readat(l.dir, depth + 1);
	}
}

readflat(dir: string): ref Model
{
	m := Model.new();
	(ok, nil) := sys->stat(dir + "/meta");
	if(ok >= 0)
		m.setmeta(stanza(readfile(dir + "/meta")));
	ts := trim(readfile(dir + "/time"));
	if(ts != "")
		m.settime(real ts);
	for(k := ENT; k <= LAYER; k++) {
		d := dir + "/" + dirname(k);
		for(nl := filenames(d); nl != nil; nl = tl nl)
			m.set(k, hd nl, stanza(readfile(d + "/" + hd nl)));
	}
	return m;
}

Model.extent(m: self ref Model): (int, real, real, real, real)
{
	ok := 0;
	a0, b0, a1, b1: real;
	ents := m.objs(ENT);
	for(i := 0; i < len ents; i++) {
		e := ents[i];
		if(!e.haspos)
			continue;
		(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, e.a, e.b);
	}
	feats := m.objs(FEAT);
	for(i = 0; i < len feats; i++) {
		f := feats[i];
		for(j := 0; j < len f.pts; j++) {
			(pa, pb) := f.pts[j];
			if(f.typ == "circle" && m.frame == XY) {
				(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, pa - f.radius, pb - f.radius);
				(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, pa + f.radius, pb + f.radius);
			} else
				(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, pa, pb);
		}
	}
	# the layers' extents too: a stack may have nothing of its own
	layers := m.objs(LAYER);
	for(i = 0; i < len layers; i++) {
		l := layers[i];
		if(l.hide)
			continue;
		if(l.typ == "scene" && l.sub != nil && l.sub.frame == m.frame) {
			(sok, sa0, sb0, sa1, sb1) := l.sub.extent();
			if(sok) {
				(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, sa0, sb0);
				(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, sa1, sb1);
			}
		} else if(l.typ == "image" && len l.bounds >= 2) {
			for(j := 0; j < 2; j++) {
				(ia, ib) := l.bounds[j];
				(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, ia, ib);
			}
		}
	}
	if(!ok) {
		bd := parsepts(getattr(m.meta, "bounds"));
		if(len bd >= 2) {
			(ba0, bb0) := bd[0];
			(ba1, bb1) := bd[1];
			(ok, a0, b0, a1, b1) = grow(0, 0.0, 0.0, 0.0, 0.0, ba0, bb0);
			(ok, a0, b0, a1, b1) = grow(ok, a0, b0, a1, b1, ba1, bb1);
		}
	}
	return (ok, a0, b0, a1, b1);
}

grow(ok: int, a0, b0, a1, b1, a, b: real): (int, real, real, real, real)
{
	if(!ok)
		return (1, a, b, a, b);
	if(a < a0) a0 = a;
	if(a > a1) a1 = a;
	if(b < b0) b0 = b;
	if(b > b1) b1 = b;
	return (1, a0, b0, a1, b1);
}

# ── Change signatures ────────────────────────────────────────

signature(dir: string): string
{
	initbase();
	return sigat(dir, 0);
}

# The contents themselves, hashed: mtimes have one-second grain and a
# synthetic server's files have none, so nothing cheaper is reliable.
# (A plain directory is the simple path; scenefs's gen is the fast one.)
sigat(dir: string, depth: int): string
{
	s := sys->sprint("m%ux t%ux ", hash(readfile(dir + "/meta")), hash(readfile(dir + "/time")));
	for(k := ENT; k <= LAYER; k++) {
		d := dir + "/" + dirname(k);
		h := 0;
		n := 0;
		for(nl := filenames(d); nl != nil; nl = tl nl) {
			text := readfile(d + "/" + hd nl);
			h += hash(hd nl + "\n" + text);	# order-free: a sum
			n++;
			if(k == LAYER && depth < MAXDEPTH) {
				kv := stanza(text);
				if(getattr(kv, "kind") == "scene" && (sd := getattr(kv, "dir")) != nil)
					s += "[" + sigat(sd, depth + 1) + "]";
			}
		}
		s += sys->sprint("%d:%d:%ux ", k, n, h);
	}
	return s;
}

hash(s: string): int
{
	h := 5381;
	for(i := 0; i < len s; i++)
		h = (h * 33) ^ s[i];
	return h;
}

subsignature(m: ref Model): string
{
	initbase();
	s := "";
	layers := m.objs(LAYER);
	for(i := 0; i < len layers; i++)
		if(layers[i].typ == "scene" && layers[i].dir != nil)
			s += "[" + sigat(layers[i].dir, 1) + "]";
	return s;
}

# ── Camera ───────────────────────────────────────────────────

Cam.new(r: Rect): ref Cam
{
	initbase();
	return ref Cam(r, 0.0, 0.0, 2.0, nil, nil);
}

# Frame coordinates to the world plane: y grows downward in both.
world(m: ref Model, a, b: real): (real, real)
{
	if(m.frame == XY)
		return (a, -b);
	p := geoproj->lookup(m.proj);
	if(p == nil)
		p = geoproj->lookup("");
	return geoproj->fwd(p, a, b);
}

unworld(m: ref Model, wx, wy: real): (real, real)
{
	if(m.frame == XY)
		return (wx, -wy);
	p := geoproj->lookup(m.proj);
	if(p == nil)
		p = geoproj->lookup("");
	return geoproj->inv(p, wx, wy);
}

scale(c: ref Cam, m: ref Model): real
{
	s := math->pow(2.0, c.zoom);
	if(m.frame == GEO)
		s *= TILE;
	return s;
}

mid(r: Rect): Point
{
	return Point((r.min.x + r.max.x) / 2, (r.min.y + r.max.y) / 2);
}

Cam.fwd(c: self ref Cam, m: ref Model, a, b: real): Point
{
	s := scale(c, m);
	(wx, wy) := world(m, a, b);
	(cx, cy) := world(m, c.ca, c.cb);
	o := mid(c.r);
	return Point(o.x + rnd((wx - cx) * s), o.y + rnd((wy - cy) * s));
}

Cam.inv(c: self ref Cam, m: ref Model, p: Point): (real, real)
{
	s := scale(c, m);
	(cx, cy) := world(m, c.ca, c.cb);
	o := mid(c.r);
	return unworld(m, cx + real (p.x - o.x) / s, cy + real (p.y - o.y) / s);
}

Cam.pan(c: self ref Cam, m: ref Model, dx, dy: int)
{
	s := scale(c, m);
	(cx, cy) := world(m, c.ca, c.cb);
	(c.ca, c.cb) = unworld(m, cx - real dx / s, cy - real dy / s);
}

zlimits(m: ref Model): (real, real)
{
	if(m.frame == GEO)
		return (0.0, 22.0);
	return (-24.0, 24.0);
}

Cam.zoomby(c: self ref Cam, m: ref Model, dz: real)
{
	(lo, hi) := zlimits(m);
	c.zoom += dz;
	if(c.zoom < lo) c.zoom = lo;
	if(c.zoom > hi) c.zoom = hi;
}

# Zoom keeping the point under p fixed (wheel zoom).
Cam.zoomat(c: self ref Cam, m: ref Model, p: Point, dz: real)
{
	(a, b) := c.inv(m, p);
	c.zoomby(m, dz);
	q := c.fwd(m, a, b);
	c.pan(m, p.x - q.x, p.y - q.y);
}

Cam.fit(c: self ref Cam, m: ref Model)
{
	(ok, a0, b0, a1, b1) := m.extent();
	if(!ok || c.r.dx() <= 0 || c.r.dy() <= 0)
		return;
	(wx0, wy0) := world(m, a0, b0);
	(wx1, wy1) := world(m, a1, b1);
	(c.ca, c.cb) = unworld(m, (wx0 + wx1) / 2.0, (wy0 + wy1) / 2.0);
	dw := fabs(wx1 - wx0);
	dh := fabs(wy1 - wy0);
	w := real c.r.dx() * 0.8;
	h := real c.r.dy() * 0.8;
	s := 0.0;
	if(dw > 0.0)
		s = w / dw;
	if(dh > 0.0 && (s == 0.0 || h / dh < s))
		s = h / dh;
	if(s <= 0.0) {	# a single point: a sensible close-up
		if(m.frame == GEO)
			c.zoom = 14.0;
		else
			c.zoom = 0.0;
		return;
	}
	if(m.frame == GEO)
		s /= TILE;
	c.zoom = math->log(s) / math->log(2.0);
	c.zoomby(m, 0.0);	# clamp
}

Cam.upp(c: self ref Cam, m: ref Model): real
{
	s := scale(c, m);
	if(m.frame == GEO)
		return EARTHC * math->cos(c.ca * Math->Degree) / s;
	return 1.0 / s;
}

Cam.text(c: self ref Cam, m: ref Model): string
{
	f := "geo";
	if(m != nil && m.frame == XY)
		f = "xy";
	return sys->sprint("frame %s center %s %s zoom %s sel %s follow %s",
		f, fmtreal(c.ca), fmtreal(c.cb), fmtreal(c.zoom), orDash(c.sel), orDash(c.follow));
}

Cam.parse(c: self ref Cam, s: string): int
{
	(nil, toks) := sys->tokenize(s, " \t\n");
	ch := 0;
	while(toks != nil) {
		k := hd toks;
		toks = tl toks;
		case k {
		"center" =>
			if(toks == nil || tl toks == nil)
				return ch;
			a := real hd toks; b := real hd tl toks;
			toks = tl tl toks;
			if(a != c.ca || b != c.cb) {
				c.ca = a; c.cb = b; ch = 1;
			}
		"zoom" =>
			if(toks == nil)
				return ch;
			z := real hd toks;
			toks = tl toks;
			if(z != c.zoom) {
				c.zoom = z; ch = 1;
			}
		"sel" or "follow" =>
			if(toks == nil)
				return ch;
			v := hd toks;
			toks = tl toks;
			if(v == "-")
				v = nil;
			if(k == "sel" && v != c.sel) {
				c.sel = v; ch = 1;
			} else if(k == "follow" && v != c.follow) {
				c.follow = v; ch = 1;
			}
		* =>	# frame and anything newer: skip one value
			if(toks != nil)
				toks = tl toks;
		}
	}
	return ch;
}

orDash(s: string): string
{
	if(s == nil)
		return "-";
	return s;
}

# ── Trails ───────────────────────────────────────────────────

Trails.new(): ref Trails
{
	initbase();
	return ref Trails(array[NBUCKET] of list of (string, ref Ring));
}

Trails.reset(t: self ref Trails)
{
	t.ids = array[NBUCKET] of list of (string, ref Ring);
}

ring(t: ref Trails, id: string, n: int): ref Ring
{
	h := strhash(id) % NBUCKET;
	for(l := t.ids[h]; l != nil; l = tl l) {
		(k, r) := hd l;
		if(k == id) {
			if(n > 0 && len r.pts != n) {	# resize: keep newest
				old := ringpts(r);
				r.pts = array[n] of (real, real);
				r.n = 0; r.head = 0;
				s := len old - n;
				if(s < 0) s = 0;
				for(i := s; i < len old; i++)
					ringadd(r, old[i]);
			}
			return r;
		}
	}
	if(n <= 0)
		return nil;
	r := ref Ring(array[n] of (real, real), 0, 0);
	t.ids[h] = (id, r) :: t.ids[h];
	return r;
}

ringadd(r: ref Ring, p: (real, real))
{
	if(r.n > 0) {	# a stationary entity adds nothing
		(la, lb) := r.pts[(r.head + len r.pts - 1) % len r.pts];
		(pa, pb) := p;
		if(la == pa && lb == pb)
			return;
	}
	r.pts[r.head] = p;
	r.head = (r.head + 1) % len r.pts;
	if(r.n < len r.pts)
		r.n++;
}

ringpts(r: ref Ring): array of (real, real)
{
	a := array[r.n] of (real, real);
	s := (r.head + len r.pts - r.n) % len r.pts;
	for(i := 0; i < r.n; i++)
		a[i] = r.pts[(s + i) % len r.pts];
	return a;
}

trailfor(m: ref Model, e: ref Obj): int
{
	n := e.trail;
	if(n < 0)
		n = m.trail;
	if(n > MAXTRAIL)
		n = MAXTRAIL;
	return n;
}

Trails.note(t: self ref Trails, m: ref Model)
{
	ents := m.objs(ENT);
	for(i := 0; i < len ents; i++) {
		e := ents[i];
		n := trailfor(m, e);
		if(n <= 0 || !e.haspos)
			continue;
		r := ring(t, e.id, n);
		ringadd(r, (e.a, e.b));
	}
}

Trails.get(t: self ref Trails, id: string): array of (real, real)
{
	r := ring(t, id, 0);
	if(r == nil)
		return nil;
	return ringpts(r);
}

# ── Rendering ────────────────────────────────────────────────

# Labels are placed after all geometry, most important first, each at
# the first candidate position that collides with nothing already
# placed: no overprinting, and the HUD never hides behind a label.
Label: adt {
	s:	string;
	col:	ref Image;
	cands:	list of Point;	# top-left positions to try, in order
	prio:	int;		# 0 selected, 1 entity, 2 feature, 3 grid
	halo:	int;
};
labels: list of ref Label;
LABELGAP: con 3;	# px kept clear around a label
obstacles: list of Rect;

addlabel(s: string, col: ref Image, cands: list of Point, prio, halo: int)
{
	if(s == nil || font == nil)
		return;
	labels = ref Label(s, col, cands, prio + labeldepth * 4, halo) :: labels;
}

placelabels(dst: ref Image, bounds: Rect)
{
	halo := color(withalpha(bgc, 200));
	for(prio := 0; prio < (MAXDEPTH + 1) * 4; prio++)
		for(l := revlabels(labels); l != nil; l = tl l) {
			lb := hd l;
			if(lb.prio != prio)
				continue;
			w := font.width(lb.s);
			for(c := lb.cands; c != nil; c = tl c) {
				r := Rect(hd c, (hd c).add((w, font.height)));
				if(!r.inrect(bounds) || collides(r.inset(-LABELGAP), obstacles))
					continue;
				obstacles = r :: obstacles;
				if(lb.halo)
					for(i := 0; i < len HALO; i++)
						dst.text(r.min.add(HALO[i]), halo, (0, 0), font, lb.s);
				dst.text(r.min, lb.col, (0, 0), font, lb.s);
				break;
			}
		}
	labels = nil;
}

HALO := array[] of {Point(-1, 0), Point(1, 0), Point(0, -1), Point(0, 1)};

collides(r: Rect, l: list of Rect): int
{
	for(; l != nil; l = tl l)
		if(rectXrect(r, hd l))
			return 1;
	return 0;
}

revlabels(l: list of ref Label): list of ref Label
{
	r: list of ref Label;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

render(dst: ref Image, m: ref Model, c: ref Cam, tr: ref Trails, flags: int, hud: string)
{
	if(display == nil || dst == nil || m == nil || c == nil)
		return;
	r := c.r;
	oclip := dst.clipr;
	dst.clipr = r;
	dst.draw(r, color(bgc), nil, (0, 0));
	labels = nil;
	obstacles = nil;
	layeralpha = 255;
	labeldepth = 0;
	if(flags & RHUD)
		obstacles = hudrects(m, c, hud);
	if(flags & RCHIPS) {
		(zi, nil, zf) := chiprects(c);
		obstacles = Rect(zi.min, zf.max).inset(-2) :: obstacles;
	}
	if(!drawlayers(dst, m, c, 0) && (flags & RGRID))
		drawgrid(dst, m, c, nil);
	drawcontent(dst, m, c, tr);
	# every layer's labels, placed together
	placelabels(dst, r);
	if(flags & RHUD)
		drawhud(dst, m, c, hud);
	if(flags & RCHIPS)
		drawchips(dst, c);
	dst.clipr = oclip;
}

# The layer stack, in name order, under the scene's own features and
# entities.  Returns 1 if a grid layer was drawn.
#
# A scene layer is another scene (kind=scene dir=...) drawn with the
# same camera: the stack composes, and nests.  Its labels join the one
# placement pass; at an opacity below 255 its geometry is drawn off
# screen and blended in, so overlaps within it do not double up.
layeralpha := 255;	# the opacity of the scene layer being drawn
labeldepth := 0;	# its depth: the scene in view labels first, its layers after

drawlayers(dst: ref Image, m: ref Model, c: ref Cam, depth: int): int
{
	grid := 0;
	layers := m.objs(LAYER);
	for(i := 0; i < len layers; i++) {
		l := layers[i];
		if(l.hide)
			continue;
		case l.typ {
		"grid" =>
			drawgrid(dst, m, c, l);
			grid = 1;
		"image" =>
			drawimagelayer(dst, m, c, l);
		"scene" =>
			if(l.sub == nil || l.sub.frame != m.frame || depth >= MAXDEPTH)
				continue;	# a scene in another frame cannot share the camera
			a := l.opacity;
			if(a <= 0)
				continue;
			if(a > 255)
				a = 255;
			oa := layeralpha;
			layeralpha = layeralpha * a / 255;
			labeldepth = depth + 1;
			if(a == 255) {
				drawlayers(dst, l.sub, c, depth + 1);
				drawcontent(dst, l.sub, c, nil);
			} else {
				off := display.newimage(c.r, Draw->RGBA32, 0, Draw->Transparent);
				if(off != nil) {
					drawlayers(off, l.sub, c, depth + 1);
					drawcontent(off, l.sub, c, nil);
					dst.draw(c.r, off, display.color(premul((a << 24) | (a << 16) | (a << 8) | a)), c.r.min);
				}
			}
			layeralpha = oa;
			labeldepth = depth;
		}
	}
	return grid;
}

# A scene's own features, trails and entities.
drawcontent(dst: ref Image, m: ref Model, c: ref Cam, tr: ref Trails)
{
	feats := m.objs(FEAT);
	for(i := 0; i < len feats; i++)
		if(feats[i].hasfill && !feats[i].hide)
			drawfeature(dst, m, c, feats[i]);
	for(i = 0; i < len feats; i++)
		if(!feats[i].hasfill && !feats[i].hide)
			drawfeature(dst, m, c, feats[i]);

	ents := m.objs(ENT);
	if(tr != nil)
		for(i = 0; i < len ents; i++)
			if(!ents[i].hide)
				drawtrail(dst, m, c, ents[i], tr.get(ents[i].id));
	# the selection draws last, so it is never hidden under another glyph
	for(i = 0; i < len ents; i++)
		if(ents[i].id != c.sel && !ents[i].hide)
			drawentity(dst, m, c, ents[i]);
	if(c.sel != nil && (e := m.find(ENT, c.sel)) != nil && !e.hide)
		drawentity(dst, m, c, e);
}

lcol(cv: int): ref Image
{
	if(layeralpha < 255)
		cv = withalpha(cv, layeralpha);
	return color(cv);
}

isdim(m: ref Model, e: ref Obj): int
{
	return e.dim || (e.hasstale && m.hast && m.t > e.stale);
}

drawentity(dst: ref Image, m: ref Model, c: ref Cam, e: ref Obj)
{
	if(!e.haspos)
		return;
	p := c.fwd(m, e.a, e.b);
	sz := e.size;
	if(p.x < c.r.min.x - 4*sz || p.x > c.r.max.x + 4*sz ||
	   p.y < c.r.min.y - 4*sz || p.y > c.r.max.y + 4*sz)
		return;
	cv := entcolor(e);
	if(isdim(m, e))
		cv = withalpha(cv, 90);
	col := color(cv);

	# a triangle is itself a heading arrow; other shapes get a leader
	if(e.hascourse && e.shape != STRIANGLE) {
		L := real (3 * sz);
		a := e.course * Math->Degree;
		tip := Point(p.x + rnd(math->sin(a) * L), p.y - rnd(math->cos(a) * L));
		aaline(dst, p, tip, 2, col);
	}
	course := 0.0;
	if(e.hascourse)
		course = e.course;
	glyph(dst, p, e.shape, sz, course, col, color(withalpha(bgc, 220)));
	if(e.id == c.sel)
		aaring(dst, p, 2*sz, 2*sz, 2, color(textc));
	glyphr := Rect((p.x - sz - 1, p.y - sz - 1), (p.x + sz + 2, p.y + sz + 2));
	obstacles = glyphr :: obstacles;
	if(e.label != nil && font != nil) {
		w := font.width(e.label);
		h := font.height;
		g := sz;
		if(e.id == c.sel)	# clear the selection ring
			g = 2*sz + 1;
		# clear of the glyph (and of the gap labels keep, LABELGAP)
		cands := Point(p.x + g + 6, p.y - h/2) ::	# right
			Point(p.x - g - 6 - w, p.y - h/2) ::	# left
			Point(p.x - w/2, p.y - g - 5 - h) ::	# above
			Point(p.x - w/2, p.y + g + 6) :: nil;	# below
		prio := 1;
		if(e.id == c.sel)
			prio = 0;
		addlabel(e.label, lcol(cv), cands, prio, 1);
	}
}

glyph(dst: ref Image, p: Point, shape, s: int, course: real, col, edge: ref Image)
{
	case shape {
	STRIANGLE =>	# an arrowhead pointing along course (0 = up, clockwise)
		a := course * Math->Degree;
		sn := math->sin(a);
		cs := math->cos(a);
		S := real s * 1.2;
		# a slim dart: the tip well ahead of the wings, so it reads
		# as a direction at any angle
		tri := array[] of {(0.0, -1.25*S), (-0.6*S, 0.8*S), (0.0, 0.4*S), (0.6*S, 0.8*S)};
		pa := array[len tri] of Point;
		for(i := 0; i < len tri; i++) {
			(x, y) := tri[i];
			pa[i] = Point(p.x + rnd(x*cs - y*sn), p.y + rnd(x*sn + y*cs));
		}
		aafill(dst, pa, col);
	SDIAMOND =>
		aafill(dst, array[] of {Point(p.x, p.y - s), Point(p.x - s, p.y),
			Point(p.x, p.y + s), Point(p.x + s, p.y)}, col);
	SSQUARE =>
		d := s * 5 / 6;
		dst.draw(Rect((p.x - d, p.y - d), (p.x + d + 1, p.y + d + 1)), col, nil, (0, 0));
	SCROSS =>
		aaline(dst, (p.x - s, p.y - s), (p.x + s, p.y + s), 2, col);
		aaline(dst, (p.x - s, p.y + s), (p.x + s, p.y - s), 2, col);
	SRING =>
		aaring(dst, p, s, s, 2, col);
	SCIRCLE =>
		aadisc(dst, p, s, s, col);
		aaring(dst, p, s, s, 1, edge);
	* =>
		aadisc(dst, p, s - 1, s - 1, col);
		aaring(dst, p, s, s, 1, edge);
	}
}

drawtrail(dst: ref Image, m: ref Model, c: ref Cam, e: ref Obj, pts: array of (real, real))
{
	if(len pts < 2)
		return;
	base := entcolor(e);
	n := len pts;
	prev := c.fwd(m, pts[0].t0, pts[0].t1);
	for(i := 1; i < n; i++) {
		q := c.fwd(m, pts[i].t0, pts[i].t1);
		if(q.x == prev.x && q.y == prev.y)
			continue;
		# older segments fade out
		a := 40 + 160 * i / n;
		aaline(dst, prev, q, 1, color(withalpha(base, a)));
		prev = q;
	}
}

drawfeature(dst: ref Image, m: ref Model, c: ref Cam, f: ref Obj)
{
	cv := textc;
	if(f.hascol)
		cv = f.col;
	col := color(cv);
	case f.typ {
	"circle" =>
		if(len f.pts < 1)
			return;
		(a, b) := f.pts[0];
		p := c.fwd(m, a, b);
		upp := c.upp(m);
		if(m.frame == GEO)
			upp = EARTHC * math->cos(a * Math->Degree) / scale(c, m);
		rad := rnd(f.radius / upp);
		if(rad < 1)
			rad = 1;
		if(f.hasfill)
			aadisc(dst, p, rad, rad, color(f.fill));
		if(f.dash)
			dashpoly(dst, circlepts(p, rad), f.width, col);
		else
			aaring(dst, p, rad, rad, f.width, col);
	"polygon" =>
		pa := projpts(m, c, f.pts);
		if(len pa < 2)
			return;
		if(f.hasfill && len pa >= 3)
			aafill(dst, pa, color(f.fill));
		closed := array[len pa + 1] of Point;
		closed[0:] = pa;
		closed[len pa] = pa[0];
		stroke(dst, closed, f.width, f.dash, col);
	"point" =>
		pa := projpts(m, c, f.pts);
		for(i := 0; i < len pa; i++)
			aadisc(dst, pa[i], f.width + 2, f.width + 2, col);
	* =>	# polyline
		pa := projpts(m, c, f.pts);
		if(len pa == 1)
			aadisc(dst, pa[0], f.width + 2, f.width + 2, col);
		else
			stroke(dst, pa, f.width, f.dash, col);
	}
	if(f.label != nil && len f.pts > 0 && font != nil)
		addlabel(f.label, lcol(cv), featlabelpos(m, c, f), 2, 1);
}

# Where a feature's label may go: above a circle, inside the top-left
# corner of a polygon's box, just past a line's first point.
featlabelpos(m: ref Model, c: ref Cam, f: ref Obj): list of Point
{
	w := font.width(f.label);
	h := font.height;
	(a, b) := f.pts[0];
	p := c.fwd(m, a, b);
	case f.typ {
	"circle" =>
		upp := c.upp(m);
		if(m.frame == GEO)
			upp = EARTHC * math->cos(a * Math->Degree) / scale(c, m);
		rad := rnd(f.radius / upp);
		return Point(p.x - w/2, p.y - rad - h - 2) :: Point(p.x - w/2, p.y + rad + 2) :: nil;
	"polygon" =>
		pa := projpts(m, c, f.pts);
		bb := Rect(pa[0], pa[0]);
		for(i := 1; i < len pa; i++) {
			if(pa[i].x < bb.min.x) bb.min.x = pa[i].x;
			if(pa[i].y < bb.min.y) bb.min.y = pa[i].y;
			if(pa[i].x > bb.max.x) bb.max.x = pa[i].x;
			if(pa[i].y > bb.max.y) bb.max.y = pa[i].y;
		}
		return Point(bb.min.x + 4, bb.min.y + 3) :: Point(bb.min.x + 4, bb.max.y - h - 3) :: nil;
	}
	return p.add((6, 2)) :: p.add((-w - 6, 2)) :: p.add((6, -h - 2)) :: nil;
}

circlepts(p: Point, r: int): array of Point
{
	n := 16 + r / 2;
	if(n > 256)
		n = 256;
	pa := array[n + 1] of Point;
	for(i := 0; i <= n; i++) {
		a := 2.0 * Math->Pi * real i / real n;
		pa[i] = Point(p.x + rnd(real r * math->cos(a)), p.y + rnd(real r * math->sin(a)));
	}
	return pa;
}

# One stroke, so a translucent line is blended once where segments meet.
stroke(dst: ref Image, pa: array of Point, w, dash: int, col: ref Image)
{
	if(dash) {
		dashpoly(dst, pa, w, col);
		return;
	}
	aapolyline(dst, pa, w, col);
}

DASHON: con 8.0;
DASHOFF: con 6.0;

dashpoly(dst: ref Image, pa: array of Point, w: int, col: ref Image)
{
	phase := 0.0;	# distance along the current on+off period
	for(i := 1; i < len pa; i++) {
		x0 := real pa[i-1].x; y0 := real pa[i-1].y;
		dx := real pa[i].x - x0; dy := real pa[i].y - y0;
		L := math->sqrt(dx*dx + dy*dy);
		if(L < 0.5)
			continue;
		d := 0.0;
		while(d < L) {
			per := DASHON + DASHOFF;
			left := per - phase;
			step := left;
			if(phase < DASHON)
				step = DASHON - phase;
			if(d + step > L)
				step = L - d;
			if(phase < DASHON) {
				p := Point(rnd(x0 + dx * d / L), rnd(y0 + dy * d / L));
				q := Point(rnd(x0 + dx * (d + step) / L), rnd(y0 + dy * (d + step) / L));
				aaline(dst, p, q, w, col);
			}
			d += step;
			phase += step;
			if(phase >= per)
				phase -= per;
		}
	}
}

projpts(m: ref Model, c: ref Cam, g: array of (real, real)): array of Point
{
	pa := array[len g] of Point;
	for(i := 0; i < len g; i++) {
		(a, b) := g[i];
		pa[i] = c.fwd(m, a, b);
	}
	return pa;
}

# Grid lines in frame units (a graticule in the geo frame).  A grid layer
# may fix the step and colour; otherwise ~6 "nice" lines per axis.
drawgrid(dst: ref Image, m: ref Model, c: ref Cam, l: ref Obj)
{
	r := c.r;
	gc := gridc;
	if(l != nil && l.hascol)
		gc = l.col;
	gcol := color(gc);
	tcol := color(gtextc);
	(a0, b0) := c.inv(m, r.min);
	(a1, b1) := c.inv(m, r.max);
	# (a, b) → which is horizontal?  xy: a=x (horizontal), b=y.
	# geo: a=lat (vertical), b=lon (horizontal).
	hx0, hx1, vy0, vy1: real;
	if(m.frame == XY) {
		hx0 = a0; hx1 = a1; vy0 = b1; vy1 = b0;
	} else {
		hx0 = b0; hx1 = b1; vy0 = a1; vy1 = a0;
	}
	hstep := nicestep(hx1 - hx0);
	vstep := nicestep(vy1 - vy0);
	if(l != nil && l.step > 0.0) {
		hstep = l.step; vstep = l.step;
		# too dense to read: thin it
		while((hx1 - hx0) / hstep > 200.0) hstep *= 2.0;
		while((vy1 - vy0) / vstep > 200.0) vstep *= 2.0;
	}
	# vertical lines (constant horizontal coordinate)
	n := 0;
	for(h := math->floor(hx0 / hstep) * hstep; h <= hx1 && n < 400; h += hstep) {
		n++;
		p: Point;
		if(m.frame == XY)
			p = c.fwd(m, h, c.cb);
		else
			p = c.fwd(m, c.ca, h);
		if(p.x < r.min.x || p.x >= r.max.x)
			continue;
		dst.line((p.x, r.min.y), (p.x, r.max.y - 1), 0, 0, 0, gcol, (0, 0));
		addlabel(fmtnum(h), tcol, Point(p.x + 3, r.max.y - font.height - 2) :: nil, 3, 0);
	}
	n = 0;
	for(v := math->floor(vy0 / vstep) * vstep; v <= vy1 && n < 400; v += vstep) {
		n++;
		p: Point;
		if(m.frame == XY)
			p = c.fwd(m, c.ca, v);
		else
			p = c.fwd(m, v, c.cb);
		if(p.y < r.min.y || p.y >= r.max.y)
			continue;
		dst.line((r.min.x, p.y), (r.max.x - 1, p.y), 0, 0, 0, gcol, (0, 0));
		addlabel(fmtnum(v), tcol, Point(r.min.x + 3, p.y + 1) :: nil, 3, 0);
	}
}

# A raster pinned to two frame-coordinate corners, resampled (nearest
# neighbour) to the camera and cached until the camera or rect changes.
drawimagelayer(dst: ref Image, m: ref Model, c: ref Cam, l: ref Obj)
{
	if(l.file == nil || len l.bounds < 2)
		return;
	ic := getimg(l.file);
	if(ic == nil || ic.src == nil)
		return;
	(a0, b0) := l.bounds[0];
	(a1, b1) := l.bounds[1];
	p0 := c.fwd(m, a0, b0);
	p1 := c.fwd(m, a1, b1);
	lr := Rect(p0, p1).canon();
	if(lr.dx() <= 0 || lr.dy() <= 0)
		return;
	(vis, ok) := lr.clip(c.r);
	if(!ok)
		return;
	key := sys->sprint("%d %d %d %d %d %d %d %d %d", lr.min.x, lr.min.y, lr.max.x, lr.max.y,
		vis.min.x, vis.min.y, vis.max.x, vis.max.y, l.opacity);
	if(ic.key != key || ic.out == nil) {
		ic.out = resample(ic.src, lr, vis, l.opacity);
		ic.outr = vis;
		ic.key = key;
	}
	if(ic.out != nil)
		dst.draw(ic.outr, ic.out, nil, ic.outr.min);
}

getimg(file: string): ref Imgc
{
	for(l := imgcache; l != nil; l = tl l)
		if((hd l).file == file)
			return hd l;
	# only a decoded image is cached: a file that is not there yet is
	# tried again next frame
	ic := ref Imgc(file, nil, nil, nil, Rect((0,0),(0,0)));
	if(imgload == nil) {
		imgload = load Imgload Imgload->PATH;
		if(imgload == nil)
			return ic;
		imgload->init(display);
	}
	(im, nil) := imgload->readimage(file);
	if(im == nil)
		return ic;
	# normalise to RGBA32 so the resampler reads one pixel layout
	src := display.newimage(Rect((0, 0), (im.r.dx(), im.r.dy())), Draw->RGBA32, 0, Draw->Transparent);
	if(src == nil)
		return ic;
	src.draw(src.r, im, nil, im.r.min);
	ic.src = src;
	imgcache = ic :: imgcache;
	return ic;
}

# (The image is upright whichever corners bounds names: its top row is
# the top of lr, north or +y.)
resample(src: ref Image, lr, vis: Rect, opacity: int): ref Image
{
	sw := src.r.dx(); sh := src.r.dy();
	if(sw <= 0 || sh <= 0)
		return nil;
	sp := array[sw * sh * 4] of byte;
	if(src.readpixels(src.r, sp) < 0)
		return nil;
	vw := vis.dx(); vh := vis.dy();
	op := array[vw * vh * 4] of byte;
	if(opacity < 0) opacity = 0;
	if(opacity > 255) opacity = 255;
	for(y := 0; y < vh; y++) {
		# in real: a zoomed-in layer overflows int arithmetic
		fy := int (real (vis.min.y + y - lr.min.y) * real sh / real lr.dy() - 0.5);
		if(fy < 0) fy = 0;
		if(fy >= sh) fy = sh - 1;
		row := fy * sw * 4;
		o := y * vw * 4;
		for(x := 0; x < vw; x++) {
			fx := int (real (vis.min.x + x - lr.min.x) * real sw / real lr.dx() - 0.5);
			if(fx < 0) fx = 0;
			if(fx >= sw) fx = sw - 1;
			s := row + fx * 4;
			# RGBA32 is stored little-endian: A B G R, premultiplied
			for(k := 0; k < 4; k++)
				op[o + k] = byte (int sp[s + k] * opacity / 255);
			o += 4;
		}
	}
	out := display.newimage(Rect((0, 0), (vw, vh)).addpt(vis.min), Draw->RGBA32, 0, Draw->Transparent);
	if(out == nil)
		return nil;
	out.writepixels(out.r, op);
	return out;
}

# The HUD: a title/state strip across the top left and a scale bar at
# the bottom left.  hudrects reserves their space before labels are
# placed; drawhud paints them last.
hudtext(m: ref Model, c: ref Cam, extra: string): string
{
	s := "";
	if(m.title != nil)
		s = m.title + "  ";
	if(m.frame == GEO)
		s += sys->sprint("%s z%.1f %.4f,%.4f", m.proj, c.zoom, c.ca, c.cb);
	else
		s += sys->sprint("xy z%.1f %s,%s", c.zoom, fmtnum(c.ca), fmtnum(c.cb));
	if(m.hast)
		s += "  t=" + fmtnum(m.t);
	if(extra != nil)
		s += "  " + extra;
	return s;
}

scalebar(m: ref Model, c: ref Cam): (real, int)
{
	upp := c.upp(m);
	bar := niceround(90.0 * upp);
	return (bar, rnd(bar / upp));
}

hudrects(m: ref Model, c: ref Cam, extra: string): list of Rect
{
	if(font == nil)
		return nil;
	r := c.r;
	s := hudtext(m, c, extra);
	top := Rect(r.min, (r.min.x + font.width(s) + 16, r.min.y + font.height + 8));
	(bar, barpx) := scalebar(m, c);
	y := r.max.y - font.height - 10;
	sb := Rect((r.min.x, y - font.height/2 - 4),
		(r.min.x + 16 + barpx + font.width(dist(bar, m)), r.max.y));
	return top :: sb :: nil;
}

drawhud(dst: ref Image, m: ref Model, c: ref Cam, extra: string)
{
	if(font == nil)
		return;
	r := c.r;
	hcol := color(hudc);
	(bar, barpx) := scalebar(m, c);
	if(barpx > 0 && barpx < r.dx()) {
		y := r.max.y - font.height - 10;
		x0 := r.min.x + 8;
		for(i := 0; i < len HALO; i++)
			dst.line(Point(x0, y).add(HALO[i]), Point(x0 + barpx, y).add(HALO[i]), 0, 0, 0, color(bgc), (0, 0));
		dst.line((x0, y), (x0 + barpx, y), 0, 0, 0, hcol, (0, 0));
		dst.line((x0, y - 3), (x0, y + 3), 0, 0, 0, hcol, (0, 0));
		dst.line((x0 + barpx, y - 3), (x0 + barpx, y + 3), 0, 0, 0, hcol, (0, 0));
		dst.text((x0 + barpx + 6, y - font.height / 2), hcol, (0, 0), font, dist(bar, m));
	}
	s := hudtext(m, c, extra);
	sr := Rect(r.min, (r.min.x + font.width(s) + 16, r.min.y + font.height + 8));
	dst.draw(sr, color(withalpha(bgc, 220)), nil, (0, 0));
	dst.text((r.min.x + 8, r.min.y + 4), hcol, (0, 0), font, s);
}

# Zoom-in, zoom-out and fit buttons, top right: drawn here so labels
# keep clear of them, hit-tested by the viewer (chiprects).
chiprects(c: ref Cam): (Rect, Rect, Rect)
{
	ch := 22;
	if(font != nil)
		ch = font.height + 8;
	x1 := c.r.max.x - 8;
	zf := Rect((x1 - ch, c.r.min.y + 8), (x1, c.r.min.y + 8 + ch));
	zo := zf.subpt((ch + 4, 0));
	zi := zo.subpt((ch + 4, 0));
	return (zi, zo, zf);
}

drawchips(dst: ref Image, c: ref Cam)
{
	if(font == nil)
		return;
	(zi, zo, zf) := chiprects(c);
	chip(dst, zi, "+");
	chip(dst, zo, "-");
	chip(dst, zf, "o");
}

chip(dst: ref Image, r: Rect, s: string)
{
	dst.draw(r, color(withalpha(bgc, 230)), nil, (0, 0));
	dst.border(r, 1, color(gridc), (0, 0));
	dst.text(Point(r.min.x + (r.dx() - font.width(s)) / 2,
		r.min.y + (r.dy() - font.height) / 2), color(hudc), (0, 0), font, s);
}

hit(m: ref Model, c: ref Cam, p: Point, radius: int): string
{
	best := radius + 1;
	id: string;
	ents := m.objs(ENT);
	for(i := 0; i < len ents; i++) {
		e := ents[i];
		if(!e.haspos || e.hide)
			continue;
		q := c.fwd(m, e.a, e.b);
		d := iabs(q.x - p.x) + iabs(q.y - p.y);
		if(d < best) {
			best = d;
			id = e.id;
		}
	}
	return id;
}

# ── anti-aliased shapes: Draw's paths, on pixel centres ──────

pc(v: int): real
{
	return real v + 0.5;
}

aaline(dst: ref Image, p, q: Point, w: int, col: ref Image)
{
	aapolyline(dst, array[] of {p, q}, w, col);
}

aapolyline(dst: ref Image, pa: array of Point, w: int, col: ref Image)
{
	if(len pa < 2)
		return;
	if(w < 1)
		w = 1;
	path := Path.new().moveto(pc(pa[0].x), pc(pa[0].y));
	for(i := 1; i < len pa; i++)
		path.lineto(pc(pa[i].x), pc(pa[i].y));
	dst.strokepath(path, real w, Draw->Capround, Draw->Joinround, col, pa[0]);
}

aaring(dst: ref Image, p: Point, a, b, w: int, col: ref Image)
{
	if(a < 1 || b < 1)
		return;
	if(w < 1)
		w = 1;
	dst.strokepath(Path.new().ellipse(pc(p.x), pc(p.y), real a, real b), real w,
		Draw->Capbutt, Draw->Joinround, col, p);
}

aadisc(dst: ref Image, p: Point, a, b: int, col: ref Image)
{
	if(a < 1 || b < 1)
		return;
	dst.fillpath(Path.new().ellipse(pc(p.x), pc(p.y), real a, real b), ~0, col, p);
}

aafill(dst: ref Image, pa: array of Point, col: ref Image)
{
	if(len pa < 3)
		return;
	path := Path.new().moveto(pc(pa[0].x), pc(pa[0].y));
	for(i := 1; i < len pa; i++)
		path.lineto(pc(pa[i].x), pc(pa[i].y));
	dst.fillpath(path.close(), 1, col, pa[0]);
}

# ── small helpers ────────────────────────────────────────────

rectXrect(a, b: Rect): int
{
	return a.min.x < b.max.x && b.min.x < a.max.x &&
	       a.min.y < b.max.y && b.min.y < a.max.y;
}

nicestep(span: real): real
{
	span = fabs(span);
	if(span <= 0.0)
		return 1.0;
	step := span / 6.0;
	p := 1.0;
	while(step >= 10.0) { step /= 10.0; p *= 10.0; }
	while(step < 1.0) { step *= 10.0; p /= 10.0; }
	if(step < 2.0) return p;
	if(step < 5.0) return 2.0 * p;
	return 5.0 * p;
}

niceround(v: real): real
{
	if(v <= 0.0)
		return 1.0;
	p := 1.0;
	while(v >= 10.0) { v /= 10.0; p *= 10.0; }
	while(v < 1.0) { v *= 10.0; p /= 10.0; }
	if(v < 1.5) return p;
	if(v < 3.5) return 2.0 * p;
	if(v < 7.5) return 5.0 * p;
	return 10.0 * p;
}

dist(v: real, m: ref Model): string
{
	if(m.frame == GEO) {
		if(v >= 1000.0)
			return fmtnum(v / 1000.0) + " km";
		return fmtnum(v) + " m";
	}
	if(m.units == "m" && v >= 1000.0)
		return fmtnum(v / 1000.0) + " km";
	return fmtnum(v) + " " + m.units;
}

# Shortest decimal that reads cleanly: no float noise, no trailing zeros.
fmtnum(v: real): string
{
	s: string;
	if(fabs(v) >= 1000.0 || v == real int v)
		s = sys->sprint("%.0f", v);
	else
		s = sys->sprint("%.4f", v);
	return stripz(s);
}

# Full-precision number for records and view lines.
fmtreal(v: real): string
{
	if(v == real int v && fabs(v) < 1e9)
		return sys->sprint("%d", int v);
	return stripz(sys->sprint("%.9f", v));
}

stripz(s: string): string
{
	dot := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '.')
			dot = 1;
	if(!dot)
		return s;
	while(len s > 1 && s[len s - 1] == '0')
		s = s[0:len s - 1];
	if(len s > 1 && s[len s - 1] == '.')
		s = s[0:len s - 1];
	if(s == "-0")
		s = "0";
	return s;
}

rnd(x: real): int
{
	# keep far-off points finite for Draw
	if(x > 1e7) x = 1e7;
	if(x < -1e7) x = -1e7;
	return int x;	# Limbo's real->int conversion rounds to nearest
}

fabs(x: real): real
{
	if(x < 0.0)
		return -x;
	return x;
}

iabs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

trim(s: string): string
{
	i := 0;
	j := len s;
	while(i < j && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

rev(l: list of (string, string)): list of (string, string)
{
	r: list of (string, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

rev_s(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

sortobjs(a: array of ref Obj)
{
	# insertion sort into runs, then merge: ids are few-hundred-scale
	n := len a;
	if(n < 2)
		return;
	b := array[n] of ref Obj;
	for(w := 1; w < n; w *= 2) {
		for(lo := 0; lo < n; lo += 2*w) {
			m := lo + w;
			if(m > n) m = n;
			hi := lo + 2*w;
			if(hi > n) hi = n;
			i := lo; j := m; k := lo;
			while(i < m && j < hi)
				if(a[i].id <= a[j].id)
					b[k++] = a[i++];
				else
					b[k++] = a[j++];
			while(i < m)
				b[k++] = a[i++];
			while(j < hi)
				b[k++] = a[j++];
		}
		a[0:] = b[0:n];
	}
}

filenames(dir: string): list of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(!(d[i].mode & Sys->DMDIR))
				l = d[i].name :: l;
	}
	return l;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}
