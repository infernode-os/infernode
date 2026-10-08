implement Fonts;

#
# Faces for the web engine.  See module/web/fonts.m.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;
include "outlinefont.m";
	ofont: OutlineFont;
	Face: import ofont;
include "filter.m";
	inflate: Filter;
include "woff2.m";
	woff2: Woff2;
include "bidi.m";
	bidi: Bidi;
include "web/fonts.m";

# bitmap fallbacks for what the outlines lack (CJK, symbols), by size
fallbacksizes := array[] of {12, 14, 18, 24, 32, 48};
FALLBACK: con "/fonts/combined/unicode.sans.%d.font";

display: ref Display;

# the twelve shipped faces: family * 4 + (bold?1:0) + (italic?2:0)
Sans, Serif, Mono: con iota;
files := array[] of {
	"DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans-Oblique.ttf", "DejaVuSans-BoldOblique.ttf",
	"DejaVuSerif.ttf", "DejaVuSerif-Bold.ttf", "DejaVuSerif-Italic.ttf", "DejaVuSerif-BoldItalic.ttf",
	"DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf", "DejaVuSansMono-Oblique.ttf", "DejaVuSansMono-BoldOblique.ttf",
};
loaded: array of ref OutlineFont->Face;
fallbacks: array of ref Font;

# faces made, by (file, size)
Nfaces: con 64;
cache: array of list of ref Typeface;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	ofont = load OutlineFont OutlineFont->PATH;
	if(ofont == nil)
		return sys->sprint("cannot load %s: %r", OutlineFont->PATH);
	display = d;
	ofont->init(d);
	bidi = load Bidi Bidi->PATH;
	if(bidi != nil && bidi->init() != nil)
		bidi = nil;
	loaded = array[len files] of ref OutlineFont->Face;
	cache = array[Nfaces] of list of ref Typeface;
	fallbacks = array[len fallbacksizes] of ref Font;
	return nil;
}

# the bitmap font nearest in size, opened on first use
fallback(size: real): ref Font
{
	if(display == nil)
		return nil;
	k := 0;
	for(i := 1; i < len fallbacksizes; i++)
		if(real fallbacksizes[i] <= size + 1.0)
			k = i;
	if(fallbacks[k] == nil)
		fallbacks[k] = Font.open(display, sys->sprint(FALLBACK, fallbacksizes[k]));
	return fallbacks[k];
}

loadface(i: int): ref OutlineFont->Face
{
	if(loaded[i] != nil)
		return loaded[i];
	fd := sys->open(DIR + "/" + files[i], Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, dir) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	data := array[int dir.length] of byte;
	n := 0;
	while(n < len data) {
		k := sys->read(fd, data[n:], len data - n);
		if(k <= 0)
			break;
		n += k;
	}
	(f, nil) := ofont->open(data[0:n], "ttf");
	loaded[i] = f;
	return f;
}

# which shipped family stands in for a CSS family name, or -1
family(nm: string): int
{
	case nm {
	"serif" or "ui-serif" or "times" or "times new roman" or "georgia" or "garamond" or
	"cambria" or "palatino" or "palatino linotype" or "book antiqua" or "baskerville" or
	"linux libertine" or "libertinus serif" or "noto serif" or "dejavu serif" or
	"liberation serif" or "source serif pro" or "merriweather" or "charter" or "iowan old style" =>
		return Serif;
	"monospace" or "ui-monospace" or "courier" or "courier new" or "consolas" or "menlo" or
	"monaco" or "sf mono" or "sfmono-regular" or "dejavu sans mono" or "liberation mono" or
	"source code pro" or "fira code" or "fira mono" or "jetbrains mono" or "roboto mono" or
	"ubuntu mono" or "lucida console" or "andale mono" or "cascadia code" or "ibm plex mono" =>
		return Mono;
	"sans-serif" or "system-ui" or "ui-sans-serif" or "-apple-system" or "blinkmacsystemfont" or
	"segoe ui" or "roboto" or "helvetica" or "helvetica neue" or "arial" or "verdana" or
	"tahoma" or "trebuchet ms" or "open sans" or "inter" or "noto sans" or "ubuntu" or
	"cantarell" or "fira sans" or "liberation sans" or "dejavu sans" or "lato" or "montserrat" or
	"source sans pro" or "pt sans" or "lucida grande" or "geneva" or "ibm plex sans" or
	"cursive" or "fantasy" or "math" or "emoji" =>
		return Sans;
	}
	return -1;
}

# Ahem, the test suites' font, as if installed
AHEM: con "/fonts/ttf/ahem/Ahem.ttf";
ahemloaded := 0;

face(families: list of string, weight, italic: int, size: real): ref Typeface
{
	return facevar(families, weight, italic, 14.0, 100.0, size, nil, 3);
}

facevar(families: list of string, weight, style: int, slant, stretch, size: real, vars: list of (string, real), synth: int): ref Typeface
{
	italic := style != 0;
	if(size < 1.0)
		size = 1.0;
	if(!ahemloaded) {
		for(l := families; l != nil; l = tl l)
			if(hd l == "ahem") {
				ahemloaded = 1;
				if((d := readall(AHEM)) != nil)
					addface("ahem", 400, 0, nil, d);
				break;
			}
	}
	# the first family this document has downloaded, then what stands
	# in for the rest
	for(l := families; l != nil; l = tl l) {
		(parts, fw) := webparts(hd l, weight, style, slant, stretch, vars);
		if(parts == nil)
			continue;
		# no face heavy enough: a bold made up, as browsers make it (a
		# pixel's smear per 24 of size, as Skia's fake bold thickens)
		emb := 0;
		if(synth & 1 && weight >= 600 && fw <= 500)
			emb = int (size / 24.0);	# (int rounds)
		if(synth & 1 && weight >= 600 && fw <= 500 && emb < 1)
			emb = 1;
		# what stands in for the characters this family lacks is part
		# of the face: "Ahem", serif and "Ahem", sans-serif differ
		next := shipped(tl l, weight, italic, size);
		h := ((hashstr(hd l) + weight + italic*7 + int (size*4.0)) & 16r7FFFFFFF) % Nfaces;
		for(cl := cache[h]; cl != nil; cl = tl cl) {
			c := hd cl;
			if(c.size == size && c.parts == parts && c.next == next && c.embolden == emb)
				return c;
		}
		o := parts[0].outline;
		asc := real o.ascent * size / real o.upem;
		desc := real -o.descent * size / real o.upem;
		f := ref Typeface(o, size, asc, desc, normal(asc, desc), 0.0, fallback(size), parts, nil, 0, emb);
		f.next = next;
		f.space = advance(f, ' ');
		cache[h] = f :: cache[h];
		return f;
	}
	return shipped(families, weight, italic, size);
}

# line-height: normal, as browsers have it: the ascent and descent
# each rounded to whole pixels (DejaVu Sans at 13.333px: 12 + 3, not
# 15.52 rounded to 16)
normal(asc, desc: real): real
{
	return real (int asc + int desc);	# (int rounds)
}

xmetrics(f: ref Typeface): (real, real)
{
	if(f == nil || f.outline == nil || f.outline.upem <= 0)
		return (0.0, 0.0);
	(avg, bbox) := f.outline.xmetrics();
	scale := f.size / real f.outline.upem;
	return (real avg * scale, real bbox * scale);
}

shipped(families: list of string, weight, italic: int, size: real): ref Typeface
{
	fam := Serif;
	for(l := families; l != nil; l = tl l)
		if((fi := family(hd l)) >= 0) {
			fam = fi;
			break;
		}
	i := fam*4;
	if(weight >= 600)
		i += 1;
	if(italic)
		i += 2;
	h := (i*131 + int (size*4.0)) % Nfaces;
	for(cl := cache[h]; cl != nil; cl = tl cl) {
		c := hd cl;
		if(c.size == size && c.parts == nil && c.outline == loaded[i])
			return c;
	}
	o := loadface(i);
	if(o == nil)
		o = loadface(fam*4);
	f: ref Typeface;
	if(o != nil) {
		asc := real o.ascent * size / real o.upem;
		desc := real -o.descent * size / real o.upem;
		f = ref Typeface(o, size, asc, desc, normal(asc, desc), 0.0, fallback(size), nil, nil, 0, 0);
	} else {
		# no outline file: the bitmap fallback is the face
		fb := fallback(size);
		asc := size * 0.8;
		desc := size * 0.2;
		if(fb != nil) {
			asc = real fb.ascent;
			desc = real (fb.height - fb.ascent);
		}
		f = ref Typeface(nil, size, asc, desc, asc + desc, 0.0, fb, nil, nil, 0, 0);
	}
	f.space = advance(f, ' ');
	cache[h] = f :: cache[h];
	return f;
}

# The face and glyph that draw c: this family's faces whose range
# covers it, the next family's, else (nil, -1) for the bitmap fallback.
glyph(f: ref Typeface, c: int): (ref OutlineFont->Face, int)
{
	if(c == 16rA0)
		c = ' ';	# a no-break space is as wide as a space (float-nowrap-5)
	for(; f != nil; f = f.next) {
		if(f.parts != nil) {
			for(i := 0; i < len f.parts; i++) {
				p := f.parts[i];
				if(!inranges(p.ranges, c))
					continue;
				if((g := p.outline.lookup(c)) >= 0)
					return (p.outline, g);
			}
		} else if(f.outline != nil && (g := f.outline.lookup(c)) >= 0)
			return (f.outline, g);
	}
	return (nil, -1);
}

inranges(r: array of int, c: int): int
{
	if(r == nil)
		return 1;
	for(i := 0; i + 1 < len r; i += 2)
		if(c >= r[i] && c <= r[i+1])
			return 1;
	return 0;
}

advance(f: ref Typeface, c: int): real
{
	if(zerowidth(c))
		return 0.0;
	(o, g) := glyph(f, c);
	return advanceg(f, o, g, c);
}

# format characters (bidi controls, joiners, the byte-order mark, the
# soft hyphen): no glyph, no advance
zerowidth(c: int): int
{
	return c >= 16r200B && c <= 16r200F || c >= 16r202A && c <= 16r202E ||
		c >= 16r2060 && c <= 16r2064 || c >= 16r2066 && c <= 16r2069 || c == 16rFEFF || c == 16rAD;
}

# the advance of c, its glyph (o, g) already looked up
advanceg(f: ref Typeface, o: ref OutlineFont->Face, g, c: int): real
{
	if(o == nil) {
		if(f.fallback != nil) {
			s := "";
			s[0] = c;
			return real f.fallback.width(s);
		}
		if(f.outline == nil)
			return f.size / 2.0;
		return f.outline.advance(0, f.size);
	}
	return o.advance(g, f.size);
}

# kerning between the characters a and b: not where either is a
# space, as browsers shape a word at a time
kernc(a, b: int): int
{
	return a != ' ' && a != 16rA0 && b != ' ' && b != 16rA0;
}

Typeface.kernpair(f: self ref Typeface, a, b: int): real
{
	(oa, ga) := glyph(f, a);
	(ob, gb) := glyph(f, b);
	if(oa == nil || oa != ob)
		return 0.0;
	return real oa.kern(ga, gb) * f.size / real oa.upem;
}

Typeface.xheight(f: self ref Typeface): real
{
	# the first available font's (Values 4 §6.1.1): the first whose
	# unicode-range has the space (Fonts 4 §5.2), x or no x
	o := firstface(f);
	if(o != nil && (g := o.lookup('x')) >= 0 && (y := o.ymax(g)) > 0)
		return real y * f.size / real o.upem;
	if(o == nil) {
		(xo, xg) := glyph(f, 'x');
		if(xo != nil && (y := xo.ymax(xg)) > 0)
			return real y * f.size / real xo.upem;
	}
	return f.size / 2.0;	# CSS's fallback: 0.5em
}

firstface(f: ref Typeface): ref OutlineFont->Face
{
	for(; f != nil; f = f.next) {
		if(f.parts != nil) {
			for(i := 0; i < len f.parts; i++)
				if(inranges(f.parts[i].ranges, ' '))
					return f.parts[i].outline;
		} else if(f.outline != nil)
			return f.outline;
	}
	return nil;
}

# A string shaped: one slot per glyph drawn.  Each character's face
# and glyph, then the ligatures of the font's liga, clig and rlig
# features over each run of one face (an icon font's ligature names,
# fi and fl).  A slot from the bitmap fallback keeps its character.
Slot: adt {
	o:	ref OutlineFont->Face;	# nil: the bitmap fallback draws c
	g:	int;
	c:	int;		# the character, 0 for a ligature of several
	n:	int;		# how many characters it stands for
	at:	int;		# the index of its first character in the string shaped
};

ligfeats(): list of string
{
	return "liga" :: "clig" :: "rlig" :: nil;
}

hasligs(o: ref OutlineFont->Face): int
{
	for(l := ligfeats(); l != nil; l = tl l)
		if(o.hasfeature(hd l))
			return 1;
	return 0;
}

shape(f: ref Typeface, s: string): array of ref Slot
{
	a := array[len s] of ref Slot;
	slot := array[len s] of int;	# each character's slot, or -1
	n := 0;
	for(i := 0; i < len s; i++) {
		slot[i] = -1;
		if(zerowidth(s[i]))
			continue;
		(o, g) := glyph(f, s[i]);
		slot[i] = n;
		a[n++] = ref Slot(o, g, s[i], 1, i);
	}
	a = a[0:n];
	joinforms(s, slot, a);
	# ligatures, over runs of one outline face
	for(i = 0; i < n; ) {
		o := a[i].o;
		j := i + 1;
		while(j < n && a[j].o == o)
			j++;
		if(o != nil && j - i > 1 && hasligs(o)) {
			gids := array[j - i] of int;
			for(k := i; k < j; k++)
				gids[k - i] = a[k].g;
			(r, cnt) := o.ligatures(gids, ligfeats());
			if(len r != len gids) {
				b := array[n - (j - i) + len r] of ref Slot;
				b[0:] = a[0:i];
				for(k = 0; k < len r; k++) {
					c := 0;
					if(cnt[k] == 1)
						c = a[i + k].c;
					b[i + k] = ref Slot(o, r[k], c, cnt[k], 0);
				}
				# each result begins where its first component did
				at := i;
				for(k = 0; k < len r; k++) {
					b[i + k].at = a[at].at;
					at += cnt[k];
				}
				b[i + len r:] = a[j:];
				a = b;
				n = len a;
				j = i + len r;
			}
		}
		i = j;
	}
	return a;
}

# Cursive joining (Unicode chapter 9): each letter takes its initial,
# medial, final or isolated form by whether its neighbours join to it,
# through the font's init, medi, fina and isol features.  Transparent
# characters (marks) are looked past; a zero width joiner at either
# end stands for a joining neighbour beyond this run (layout puts one
# there where a run continues across an inline box's edge).
joinforms(s: string, slot: array of int, a: array of ref Slot)
{
	if(bidi == nil)
		return;
	jt := array[len s] of int;
	any := 0;
	for(i := 0; i < len s; i++) {
		jt[i] = bidi->joining(s[i]);
		if(jt[i] != Bidi->JU && jt[i] != Bidi->JT)
			any = 1;
	}
	if(!any)
		return;
	for(i = 0; i < len s; i++) {
		t := jt[i];
		if(t != Bidi->JD && t != Bidi->JR && t != Bidi->JL || slot[i] < 0 || a[slot[i]].o == nil)
			continue;
		prev := Bidi->JU;
		for(j := i - 1; j >= 0; j--)
			if(jt[j] != Bidi->JT) {
				prev = jt[j];
				break;
			}
		next := Bidi->JU;
		for(j = i + 1; j < len s; j++)
			if(jt[j] != Bidi->JT) {
				next = jt[j];
				break;
			}
		before := (t == Bidi->JD || t == Bidi->JR) && (prev == Bidi->JD || prev == Bidi->JL || prev == Bidi->JC);
		after := (t == Bidi->JD || t == Bidi->JL) && (next == Bidi->JD || next == Bidi->JR || next == Bidi->JC);
		feat := "isol";
		if(before && after)
			feat = "medi";
		else if(before)
			feat = "fina";
		else if(after)
			feat = "init";
		k := slot[i];
		a[k].g = a[k].o.subst(feat, a[k].g);
	}
}

# Where each shaped glyph goes: its x, its advance, and its y offset
# (up), in logical order; the total width.  Pair kerning between
# glyphs of one face; a combining mark the font attaches to its base
# sits on the base's anchor and advances nothing.
positions(f: ref Typeface, a: array of ref Slot): (array of real, array of real, array of real, array of int, real)
{
	xs := array[len a] of real;
	adv := array[len a] of real;
	ys := array[len a] of real;
	on := array[len a] of int;	# the base a mark sits on, or -1
	x := 0.0;
	po: ref OutlineFont->Face;
	pg := -1;
	pc := ' ';
	base := -1;	# the last glyph that was not a mark
	for(i := 0; i < len a; i++) {
		(o, g, c) := (a[i].o, a[i].g, a[i].c);
		ys[i] = 0.0;
		on[i] = -1;
		if(o != nil && base >= 0 && a[base].o == o && bidi != nil && bidi->joining(c) == Bidi->JT) {
			(ok, dx, dy) := o.markanchor(a[base].g, g);
			if(ok) {
				k := f.size / real o.upem;
				xs[i] = xs[base] + real dx * k;
				ys[i] = real dy * k;
				adv[i] = 0.0;
				on[i] = base;
				continue;
			}
		}
		if(o != nil && o == po && !f.nokern && kernc(pc, c))
			x += real o.kern(pg, g) * f.size / real o.upem;
		(po, pg, pc) = (o, g, c);
		xs[i] = x;
		adv[i] = advanceg(f, o, g, c);
		x += adv[i];
		base = i;
	}
	return (xs, adv, ys, on, x);
}

Typeface.ligspan(f: self ref Typeface, a, b: string): int
{
	if(len a == 0 || len b == 0)
		return 0;
	sl := shape(f, a + b);
	for(i := 0; i < len sl; i++) {
		end := len a + len b;	# a slot's characters run to the next slot's
		if(i + 1 < len sl)
			end = sl[i+1].at;
		if(sl[i].at < len a && end > len a)
			return end - len a;
	}
	return 0;
}

Typeface.has(f: self ref Typeface, c: int): int
{
	(o, nil) := glyph(f, c);
	return o != nil;
}

Typeface.width(f: self ref Typeface, s: string): real
{
	(nil, nil, nil, nil, w) := positions(f, shape(f, s));
	return w;
}

Typeface.draw(f: self ref Typeface, dst: ref Image, p: Point, s: string, src: ref Image, rtl: int): real
{
	a := shape(f, s);
	(xs, adv, ys, on, w) := positions(f, a);
	for(i := 0; i < len a; i++) {
		(o, g, c) := (a[i].o, a[i].g, a[i].c);
		gx := real p.x + xs[i];
		if(rtl) {	# the first glyph at the right end
			gx = real p.x + w - xs[i] - adv[i];
			if(on[i] >= 0)	# a mark keeps its offset from its base
				gx = real p.x + w - xs[on[i]] - adv[on[i]] + xs[i] - xs[on[i]];
		}
		gy := p.y - int ys[i];
		if(o == nil && f.fallback != nil) {
			t := "";
			t[0] = c;
			# bitmap fallback: align its baseline with ours
			dst.text(Point(int gx, gy - f.fallback.ascent), src, Point(0, 0), f.fallback, t);
			continue;
		}
		if(o == nil) {
			o = f.outline;
			g = 0;
			if(o == nil)
				continue;
		}
		if(c != ' ' && c != ' ' && c != 16rAD) {	# a soft hyphen shows nothing (Text 3 §6.1: not taken as a break)
			o.drawglyph(g, f.size, dst, Point(int gx, gy), src);
			for(k := 1; k <= f.embolden; k++)	# synthetic bold: smeared to the right
				o.drawglyph(g, f.size, dst, Point(int gx + k, gy), src);
		}
	}
	return w;
}

# ---- web fonts ----

Web: adt {
	family:	string;
	weight:	int;	# for matching: the weight, or the range's own nearest
	italic:	int;
	part:	ref Part;
	desc:	ref Desc;
};

webfaces: list of ref Web;

clearfaces()
{
	webfaces = nil;
	partsmade = nil;
	ahemloaded = 0;
	# the faces made from them go too; the shipped ones stay
	for(h := 0; h < len cache; h++) {
		r: list of ref Typeface;
		for(cl := cache[h]; cl != nil; cl = tl cl)
			if((hd cl).parts == nil)
				r = hd cl :: r;
		cache[h] = r;
	}
}

readall(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	b := array[int d.length] of byte;
	n := 0;
	while(n < len b && (k := sys->read(fd, b[n:], len b - n)) > 0)
		n += k;
	return b[0:n];
}

addface(family: string, weight, italic: int, ranges: array of int, data: array of byte): string
{
	if(len data >= 4 && string data[0:4] == "wOFF") {
		err: string;
		(data, err) = woff(data);
		if(err != nil)
			return err;
	} else if(len data >= 4 && string data[0:4] == "wOF2") {
		if(woff2 == nil && (woff2 = load Woff2 Woff2->PATH) == nil)
			return sys->sprint("cannot load %s: %r", Woff2->PATH);
		err: string;
		(data, err) = woff2->decode(data);
		if(err != nil)
			return err;
	}
	(o, err) := ofont->open(data, "ttf");
	if(o == nil)
		return "cannot read the font: " + err;
	webfaces = ref Web(family, weight, italic, ref Part(o, ranges), nil) :: webfaces;
	return nil;
}

addfacedesc(family: string, d: ref Desc, ranges: array of int, data: array of byte): string
{
	w := 400;
	if(d.wmin > 0)
		w = d.wmin;
	if((err := addface(family, w, d.style > 0, ranges, data)) != nil)
		return err;
	wf := hd webfaces;
	wf.desc = d;
	# font-weight auto: the face's own weight, its OS/2 weight class (a
	# Bold file declared without a weight is bold, not made bolder:
	# font-synthesis-weight-webfont-bold)
	if(d.wmax <= 0 && (wc := weightclass(sfntof(data))) > 0)
		wf.weight = wc;
	return nil;
}

# the sfnt inside a WOFF or WOFF2, as addface unpacked it, or the data
sfntof(data: array of byte): array of byte
{
	if(len data >= 4 && string data[0:4] == "wOFF") {
		(d, nil) := woff(data);
		return d;
	}
	if(len data >= 4 && string data[0:4] == "wOF2" && woff2 != nil) {
		(d, nil) := woff2->decode(data);
		return d;
	}
	return data;
}

# OS/2 usWeightClass, or 0
weightclass(d: array of byte): int
{
	if(d == nil || len d < 12)
		return 0;
	n := int d[4] << 8 | int d[5];
	for(i := 0; i < n && 12 + 16*i + 16 <= len d; i++) {
		t := 12 + 16*i;
		if(string d[t:t+4] != "OS/2")
			continue;
		o := int d[t+8] << 24 | int d[t+9] << 16 | int d[t+10] << 8 | int d[t+11];
		if(o < 0 || o + 6 > len d)
			return 0;
		return int d[o+4] << 8 | int d[o+5];
	}
	return 0;
}

# The faces of a downloaded family for a weight and slant, by the CSS
# font matching rules, simplified: the right slant if there is one,
# then the nearest weight (heavier first for bold, lighter for light).
# Every face of that weight and slant comes, one per unicode-range.
# the faces chosen for a family, weight and style, made once so that
# the Typeface cache can compare them
partsmade: list of (string, string, array of ref Part, int);

# the faces, and the weight they stand at (for synthetic bold)
webparts(family: string, weight, style: int, slant, stretch: real, vars: list of (string, real)): (array of ref Part, int)
{
	vk := sys->sprint("%d %d %g %g ", weight, style, slant, stretch);
	for(vl := vars; vl != nil; vl = tl vl)
		vk += sys->sprint("%s=%g,", (hd vl).t0, (hd vl).t1);
	for(pl := partsmade; pl != nil; pl = tl pl) {
		(pf, pv, pa, pw) := hd pl;
		if(pf == family && pv == vk)
			return (pa, pw);
	}
	(a, w) := webparts1(family, weight, style, slant, stretch, vars);
	if(a != nil)
		partsmade = (family, vk, a, w) :: partsmade;
	return (a, w);
}

# the weight a face is matched by: a range's nearest to the one wanted
faceweight(w: ref Web, weight: int): int
{
	d := w.desc;
	if(d != nil && d.wmax <= 0) {
		# auto: a variable face's own wght range
		for(al := ofont->axes(w.part.outline); al != nil; al = tl al) {
			(tag, mn, nil, mx) := hd al;
			if(tag == "wght") {
				if(real weight < mn)
					return int mn;
				if(real weight > mx)
					return int mx;
				return weight;
			}
		}
	}
	if(d == nil || d.wmax <= 0)
		return w.weight;
	if(weight < d.wmin)
		return d.wmin;
	if(weight > d.wmax)
		return d.wmax;
	return weight;
}

webparts1(family: string, weight, style: int, slant, stretch: real, vars: list of (string, real)): (array of ref Part, int)
{
	italic := style != 0;
	best := -1;
	bestit := -1;
	for(l := webfaces; l != nil; l = tl l) {
		w := hd l;
		if(w.family != family)
			continue;
		it := w.italic == italic;
		fw := faceweight(w, weight);
		if(bestit < 0 || it && !bestit || it == bestit && closer(weight, fw, best)) {
			best = fw;
			bestit = it;
		}
	}
	if(best < 0)
		return (nil, 0);
	r: list of ref Part;
	sw := best;	# the weight it stands at, for synthetic bold
	for(l = webfaces; l != nil; l = tl l) {
		w := hd l;
		if(w.family == family && faceweight(w, weight) == best && (w.italic == italic) == bestit) {
			r = varied(w, weight, style, slant, stretch, vars) :: r;
			# a variable face whose weight is its own (auto) is not
			# made bolder past its range (synthetic-bold-out-of-
			# capabilities-range); one its rule holds to a weight is
			# (font-weight-3)
			if((w.desc == nil || w.desc.wmax <= 0) && hasaxis(ofont->axes(w.part.outline), "wght"))
				sw = weight;
		}
	}
	a := array[len r] of ref Part;
	for(i := 0; r != nil; r = tl r)
		a[i++] = hd r;
	return (a, sw);
}

# A variable face (one with a wght axis) at the weight wanted: one
# file serves every weight (github.com's Mona Sans, nasa.gov's Inter);
# without this all of them were drawn at the default instance.
#
# The axes take, in order (Fonts 4 §7.2; vary takes the last value an
# axis is given): the weight, width and slant asked for, each within
# what the @font-face rule says of the face; the rule's
# font-variation-settings; the style's.
varied(w: ref Web, weight, style: int, slant, stretch: real, vars: list of (string, real)): ref Part
{
	p := w.part;
	axes := ofont->axes(p.outline);
	if(axes == nil)
		return p;
	d := w.desc;
	values: list of (string, real);
	for(al := axes; al != nil; al = tl al) {
		(tag, nil, nil, nil) := hd al;
		case tag {
		"wght" =>
			values = ("wght", real faceweight(w, weight)) :: values;
		"wdth" =>
			x := stretch;
			if(d != nil && d.smax > 0.0) {
				if(x < d.smin) x = d.smin;
				if(x > d.smax) x = d.smax;
			}
			values = ("wdth", x) :: values;
		"slnt" =>
			# oblique's angle, or italic's 14deg where the face has
			# no ital axis: slnt is the negative of the angle
			a := 0.0;
			if(style == 2)
				a = slant;
			else if(style == 1 && !hasaxis(axes, "ital"))
				a = 14.0;
			if(d != nil && d.style == 2) {
				if(a < d.amin) a = d.amin;
				if(a > d.amax) a = d.amax;
			} else if(d != nil && d.style >= 0)
				a = 0.0;	# a normal or italic face does not slant by the axis
			values = ("slnt", -a) :: values;
		"ital" =>
			it := 0.0;
			if(style == 1 && (d == nil || d.style != 0))
				it = 1.0;
			values = ("ital", it) :: values;
		}
	}
	if(d != nil)
		for(dl := d.vars; dl != nil; dl = tl dl)
			values = hd dl :: values;
	for(; vars != nil; vars = tl vars)
		values = hd vars :: values;
	r: list of (string, real);
	for(; values != nil; values = tl values)
		r = hd values :: r;
	return ref Part(ofont->vary(p.outline, r), p.ranges);
}

hasaxis(axes: list of (string, real, real, real), tag: string): int
{
	for(; axes != nil; axes = tl axes)
		if((hd axes).t0 == tag)
			return 1;
	return 0;
}

# is weight w a better match for want than the best so far?
closer(want, w, best: int): int
{
	if(best < 0)
		return 1;
	dw := w - want;
	db := best - want;
	if(dw == db)
		return 0;
	if(dw == 0)
		return 1;
	if(db == 0)
		return 0;
	# CSS: above 500 look heavier first, below 400 lighter first
	if(want > 500) {
		if((dw > 0) != (db > 0))
			return dw > 0;
	} else if(want < 400) {
		if((dw < 0) != (db < 0))
			return dw < 0;
	}
	if(dw < 0)
		dw = -dw;
	if(db < 0)
		db = -db;
	return dw < db;
}

hashstr(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = (h*31 + s[i]) & 16r7FFFFFF;
	return h;
}

# A table's declared uncompressed length is the page's word for how much
# to allocate: bound it, and the font as a whole.
MAXTABLE: con 32*1024*1024;
MAXFONT: con 64*1024*1024;

# WOFF 1.0: the sfnt's tables, each zlib-compressed if that made it
# smaller; put them back into an sfnt.
woff(d: array of byte): (array of byte, string)
{
	if(len d < 44)
		return (nil, "short WOFF");
	flavor := be32(d, 4);
	ntab := be16(d, 12);
	if(44 + ntab*20 > len d)
		return (nil, "bad WOFF directory");
	tabs := array[ntab] of array of byte;
	tags := array[ntab] of int;
	sums := array[ntab] of int;
	size := 12 + 16*ntab;
	for(i := 0; i < ntab; i++) {
		e := 44 + i*20;
		tags[i] = be32(d, e);
		off := be32(d, e+4);
		clen := be32(d, e+8);
		olen := be32(d, e+12);
		sums[i] = be32(d, e+16);
		if(off < 0 || clen < 0 || off + clen > len d || olen < 0 || olen > MAXTABLE)
			return (nil, "bad WOFF table");
		t := d[off:off+clen];
		if(clen < olen) {
			t = unzlib(t, olen);
			if(t == nil)
				return (nil, "bad WOFF compression");
		}
		tabs[i] = t;
		size += (len t + 3) & ~3;
		if(size > MAXFONT)
			return (nil, "WOFF too large");
	}
	o := array[size] of {* => byte 0};
	put32(o, 0, flavor);
	put16(o, 4, ntab);
	es := 1;
	lg := 0;
	while(es*2 <= ntab) {
		es *= 2;
		lg++;
	}
	put16(o, 6, es*16);
	put16(o, 8, lg);
	put16(o, 10, ntab*16 - es*16);
	off := 12 + 16*ntab;
	for(i = 0; i < ntab; i++) {
		e := 12 + i*16;
		put32(o, e, tags[i]);
		put32(o, e+4, sums[i]);
		put32(o, e+8, off);
		put32(o, e+12, len tabs[i]);
		o[off:] = tabs[i];
		off += (len tabs[i] + 3) & ~3;
	}
	return (o, nil);
}

unzlib(data: array of byte, size: int): array of byte
{
	if(inflate == nil) {
		inflate = load Filter Filter->INFLATEPATH;
		if(inflate == nil)
			return nil;
		inflate->init();
	}
	out := array[size] of byte;
	n := 0;
	in := 0;
	rq := inflate->start("z");
	for(;;) {
		pick m := <-rq {
		Start =>
			;
		Fill =>
			k := len data - in;
			if(k > len m.buf)
				k = len m.buf;
			m.buf[0:] = data[in:in+k];
			in += k;
			m.reply <-= k;
		Result =>
			if(n + len m.buf > len out) {
				m.reply <-= -1;
				return nil;
			}
			out[n:] = m.buf;
			n += len m.buf;
			m.reply <-= 0;
		Info =>
			;
		Finished =>
			if(n != size)
				return nil;
			return out;
		Error =>
			return nil;
		}
	}
}

be16(d: array of byte, i: int): int
{
	return int d[i]<<8 | int d[i+1];
}

be32(d: array of byte, i: int): int
{
	return int d[i]<<24 | int d[i+1]<<16 | int d[i+2]<<8 | int d[i+3];
}

put16(d: array of byte, i, v: int)
{
	d[i] = byte (v>>8);
	d[i+1] = byte v;
}

put32(d: array of byte, i, v: int)
{
	d[i] = byte (v>>24);
	d[i+1] = byte (v>>16);
	d[i+2] = byte (v>>8);
	d[i+3] = byte v;
}
