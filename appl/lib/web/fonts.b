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
		parts := webparts(hd l, weight, italic);
		if(parts == nil)
			continue;
		# what stands in for the characters this family lacks is part
		# of the face: "Ahem", serif and "Ahem", sans-serif differ
		next := shipped(tl l, weight, italic, size);
		h := ((hashstr(hd l) + weight + italic*7 + int (size*4.0)) & 16r7FFFFFFF) % Nfaces;
		for(cl := cache[h]; cl != nil; cl = tl cl) {
			c := hd cl;
			if(c.size == size && c.parts == parts && c.next == next)
				return c;
		}
		o := parts[0].outline;
		asc := real o.ascent * size / real o.upem;
		desc := real -o.descent * size / real o.upem;
		f := ref Typeface(o, size, asc, desc, asc + desc, 0.0, fallback(size), parts, nil, 0);
		f.next = next;
		f.space = advance(f, ' ');
		cache[h] = f :: cache[h];
		return f;
	}
	return shipped(families, weight, italic, size);
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
		f = ref Typeface(o, size, asc, desc, asc + desc, 0.0, fallback(size), nil, nil, 0);
	} else {
		# no outline file: the bitmap fallback is the face
		fb := fallback(size);
		asc := size * 0.8;
		desc := size * 0.2;
		if(fb != nil) {
			asc = real fb.ascent;
			desc = real (fb.height - fb.ascent);
		}
		f = ref Typeface(nil, size, asc, desc, asc + desc, 0.0, fb, nil, nil, 0);
	}
	f.space = advance(f, ' ');
	cache[h] = f :: cache[h];
	return f;
}

# The face and glyph that draw c: this family's faces whose range
# covers it, the next family's, else (nil, -1) for the bitmap fallback.
glyph(f: ref Typeface, c: int): (ref OutlineFont->Face, int)
{
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
	(o, g) := glyph(f, c);
	return advanceg(f, o, g, c);
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

# kerning between s[i-1] and s[i]: not where either is a space, as
# browsers shape a word at a time
kerns(s: string, i: int): int
{
	return s[i] != ' ' && s[i] != 16rA0 && s[i-1] != ' ' && s[i-1] != 16rA0;
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
	(o, g) := glyph(f, 'x');
	if(o != nil && (y := o.ymax(g)) > 0)
		return real y * f.size / real o.upem;
	return f.size / 2.0;	# CSS's fallback: 0.5em
}

Typeface.width(f: self ref Typeface, s: string): real
{
	w := 0.0;
	po: ref OutlineFont->Face;
	pg := -1;
	for(i := 0; i < len s; i++) {
		(o, g) := glyph(f, s[i]);
		if(o != nil && o == po && !f.nokern && kerns(s, i))
			w += real o.kern(pg, g) * f.size / real o.upem;
		(po, pg) = (o, g);
		w += advanceg(f, o, g, s[i]);
	}
	return w;
}

Typeface.draw(f: self ref Typeface, dst: ref Image, p: Point, s: string, src: ref Image): real
{
	x := real p.x;
	po: ref OutlineFont->Face;
	pg := -1;
	for(i := 0; i < len s; i++) {
		c := s[i];
		(o, g) := glyph(f, c);
		if(o != nil && o == po && !f.nokern && kerns(s, i))
			x += real o.kern(pg, g) * f.size / real o.upem;	# pair kerning
		(po, pg) = (o, g);
		if(o == nil && f.fallback != nil) {
			t := "";
			t[0] = c;
			# bitmap fallback: align its baseline with ours
			dst.text(Point(int x, p.y - f.fallback.ascent), src, Point(0, 0), f.fallback, t);
			x += real f.fallback.width(t);
			continue;
		}
		if(o == nil) {
			o = f.outline;
			g = 0;
			if(o == nil) {
				x += f.size / 2.0;
				continue;
			}
		}
		if(c != ' ' && c != ' ')
			o.drawglyph(g, f.size, dst, Point(int x, p.y), src);
		x += o.advance(g, f.size);
	}
	return x - real p.x;
}

# ---- web fonts ----

Web: adt {
	family:	string;
	weight:	int;
	italic:	int;
	part:	ref Part;
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
	webfaces = ref Web(family, weight, italic, ref Part(o, ranges)) :: webfaces;
	return nil;
}

# The faces of a downloaded family for a weight and slant, by the CSS
# font matching rules, simplified: the right slant if there is one,
# then the nearest weight (heavier first for bold, lighter for light).
# Every face of that weight and slant comes, one per unicode-range.
# the faces chosen for a family, weight and style, made once so that
# the Typeface cache can compare them
partsmade: list of (string, int, int, array of ref Part);

webparts(family: string, weight, italic: int): array of ref Part
{
	for(pl := partsmade; pl != nil; pl = tl pl) {
		(pf, pw, pi, pa) := hd pl;
		if(pf == family && pw == weight && pi == italic)
			return pa;
	}
	a := webparts1(family, weight, italic);
	if(a != nil)
		partsmade = (family, weight, italic, a) :: partsmade;
	return a;
}

webparts1(family: string, weight, italic: int): array of ref Part
{
	best := -1;
	bestit := -1;
	for(l := webfaces; l != nil; l = tl l) {
		w := hd l;
		if(w.family != family)
			continue;
		it := w.italic == italic;
		if(bestit < 0 || it && !bestit || it == bestit && closer(weight, w.weight, best)) {
			best = w.weight;
			bestit = it;
		}
	}
	if(best < 0)
		return nil;
	r: list of ref Part;
	for(l = webfaces; l != nil; l = tl l) {
		w := hd l;
		if(w.family == family && w.weight == best && (w.italic == italic) == bestit)
			r = w.part :: r;
	}
	a := array[len r] of ref Part;
	for(i := 0; r != nil; r = tl r)
		a[i++] = hd r;
	return a;
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
