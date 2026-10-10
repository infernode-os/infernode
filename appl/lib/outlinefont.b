implement OutlineFont;

#
# Outline font renderer — CFF (Compact Font Format) backend.
#
# Parses CFF font programs, interprets Type 2 charstrings to extract
# glyph outlines, and rasterizes them via Draw->fillpoly.
#
# References:
#   Adobe Technical Note #5176 — CFF specification
#   Adobe Technical Note #5177 — Type 2 Charstring Format
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Image, Path, Rect, Point: import drawm;

include "math.m";
	math: Math;

include "outlinefont.m";

# ---- Internal types ----

# Path segment for glyph outlines (font units)
PathSeg: adt {
	pick {
	Move =>
		x, y: real;
	Line =>
		x, y: real;
	Curve =>
		x1, y1, x2, y2, x3, y3: real;	# cubic Bezier
	Close =>
	}
};

# CFF INDEX data
CffIndex: adt {
	count:	int;
	data:	array of array of byte;
};

# CFF top-level DICT values
CffTopDict: adt {
	charstrings_off:	int;
	charset_off:		int;
	encoding_off:		int;
	private_size:		int;
	private_off:		int;
	fdarray_off:		int;
	fdselect_off:		int;
	ros:			int;	# 1 if CIDFont
	fontname:		string;
	# Font metrics (font units; defaults per spec)
	ascent:			int;
	descent:		int;
};

# CFF private DICT values
CffPrivateDict: adt {
	subrs_off:		int;	# relative to private dict start
	defaultw:		int;
	nominalw:		int;
};

# Per-glyph outline data
GlyphOutline: adt {
	path:	list of ref PathSeg;
	width:	int;	# advance width in font units
};

# Glyph cache entry: a glyph rasterised through a matrix (the matrix
# to 1/64 px per em, matkey()) at an origin's fraction of a pixel
CacheEntry: adt {
	faceidx:	int;	# face index (different fonts have different GID assignments)
	gid:	int;
	k:	array of int;	# the matrix
	phase:	int;	# x and y quarter pixels, x*4+y
	img:	ref Image;
	width:	int;	# advance width in pixels
	ox, oy:	int;	# offset from draw point to image origin
};

# Internal face data (opaque to consumers)
FaceData: adt {
	cffdata:	array of byte;
	nglyphs:	int;
	upem:		int;
	ascent:		int;
	descent:	int;
	fontname:	string;
	charstrings:	ref CffIndex;
	gsubrs:		ref CffIndex;
	# For non-CID fonts: single private dict + local subrs
	privdict:	ref CffPrivateDict;
	lsubrs:		ref CffIndex;
	# For CID fonts: per-FD private dicts + local subrs
	iscid:		int;
	fdcount:	int;
	fdprivate:	array of ref CffPrivateDict;
	fdlsubrs:	array of ref CffIndex;
	fdselect:	array of byte;	# gid -> fd index
	# CID -> GID mapping (for CID-keyed fonts)
	cidmap:		array of int;	# indexed by CID, value is GID; -1 = unmapped
	# TrueType fields (when isttf != 0)
	isttf:		int;
	ttfdata:	array of byte;
	glyfoff:	int;
	glyflen:	int;
	locaoffs:	array of int;	# per-glyph byte offset into glyf table
	ttfcmap:	array of int;	# charcode → GID
	ttfwidths:	array of int;	# per-glyph advance width (font units)
	kernpairs:	int;		# 'kern' format 0: offset of the sorted pairs in ttfdata
	nkern:	int;		# and how many
	gsub:	ref Gsub;	# glyph substitution, or nil
	gpos:	ref Gsub;	# glyph positioning, or nil (the same shape of table)
	# variations (OpenType 1.9 fvar, avar, gvar): the axes, and for an
	# instance (vary) the normalised coordinates, one per axis
	axes:	array of ref Axis;
	avaroff:	int;
	gvaroff:	int;
	coords:	array of real;	# nil: the default instance
	varwidths:	array of int;	# advances at coords, -1 not yet worked out
	# glyph names: a CFF's charset (SIDs) and String INDEX, or a Type 1's
	# names; and the names hashed, made when first looked up
	sids:	array of int;
	strings:	ref CffIndex;
	names:	array of string;
	namehash:	array of list of (string, int);
	# Type 1: the charstrings, decrypted, by GID, and the subroutines
	t1cs:	array of array of byte;
	t1subrs:	array of array of byte;
};

Axis: adt {
	tag:	string;
	min, def, max:	real;
};

# Module state
display: ref Display;
facetab: array of ref FaceData;
nfaces: int;
cachetab: array of list of ref CacheEntry;	# hashed on (face, gid, matrix, phase)
NCACHEHASH: con 1024;
MAXCACHE: con 8192;
MAXCACHEPIX: con 3*1024*1024;	# the glyphs' pixels, together
ncached: int;
cachepix: int;

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	math = load Math Math->PATH;
	display = d;
	facetab = array[8] of ref FaceData;
	nfaces = 0;
	cachetab = array[NCACHEHASH] of list of ref CacheEntry;
	ncached = 0;
	cachepix = 0;
}

open(data: array of byte, format: string): (ref Face, string)
{
	if(len data < 4)
		return (nil, "data too small");

	fd: ref FaceData;
	err: string;

	case format {
	"cff" =>
		(fd, err) = parsecff(data);
	"ttf" =>
		(fd, err) = parsettf(data);
	"t1" =>
		(fd, err) = parset1(data);
	* =>
		return (nil, "unsupported format: " + format);
	}
	if(fd == nil)
		return (nil, err);

	# Store face data
	idx := addface(fd);

	face := ref Face(
		fd.nglyphs,
		fd.upem,
		fd.ascent,
		fd.descent,
		fd.fontname,
		fd.iscid
	);
	face.name = fd.fontname + "\t" + string idx;

	return (face, nil);
}

addface(fd: ref FaceData): int
{
	if(nfaces >= len facetab){
		newtab := array[len facetab * 2] of ref FaceData;
		newtab[0:] = facetab;
		facetab = newtab;
	}
	idx := nfaces;
	facetab[idx] = fd;
	nfaces++;
	return idx;
}

getfaceidx(f: ref Face): int
{
	nm := f.name;
	for(i := len nm - 1; i >= 0; i--){
		if(nm[i] == '\t')
			return int nm[i+1:];
	}
	return -1;
}

getfacedata(f: ref Face): ref FaceData
{
	idx := getfaceidx(f);
	if(idx >= 0 && idx < nfaces)
		return facetab[idx];
	return nil;
}

# ---- variations ----

parsefvar(data: array of byte, off: int): array of ref Axis
{
	if(off == 0 || off + 16 > len data)
		return nil;
	ao := off + getu16be(data, off + 4);
	n := getu16be(data, off + 8);
	sz := getu16be(data, off + 10);
	if(n == 0 || sz < 20 || ao + n*sz > len data)
		return nil;
	a := array[n] of ref Axis;
	for(i := 0; i < n; i++) {
		r := ao + i*sz;
		a[i] = ref Axis(string data[r:r+4], fix1616(data, r+4), fix1616(data, r+8), fix1616(data, r+12));
	}
	return a;
}

fix1616(data: array of byte, off: int): real
{
	v := getu32be(data, off);	# an int is 32 bits: negative values come out negative
	return real v / 65536.0;
}

axes(f: ref Face): list of (string, real, real, real)
{
	fd := getfacedata(f);
	if(fd == nil || fd.axes == nil)
		return nil;
	r: list of (string, real, real, real);
	for(i := len fd.axes - 1; i >= 0; i--)
		r = (fd.axes[i].tag, fd.axes[i].min, fd.axes[i].def, fd.axes[i].max) :: r;
	return r;
}

vary(f: ref Face, values: list of (string, real)): ref Face
{
	fd := getfacedata(f);
	if(fd == nil || fd.axes == nil || fd.gvaroff == 0)
		return f;
	coords := array[len fd.axes] of { * => 0.0 };
	any := 0;
	for(i := 0; i < len fd.axes; i++) {
		ax := fd.axes[i];
		v := ax.def;
		for(l := values; l != nil; l = tl l)
			if((hd l).t0 == ax.tag)
				v = (hd l).t1;
		if(v < ax.min) v = ax.min;
		if(v > ax.max) v = ax.max;
		# normalised (OpenType §avar): -1 at min, 0 at default, 1 at max
		n := 0.0;
		if(v < ax.def && ax.def > ax.min)
			n = (v - ax.def) / (ax.def - ax.min);
		else if(v > ax.def && ax.max > ax.def)
			n = (v - ax.def) / (ax.max - ax.def);
		coords[i] = avarmap(fd, i, n);
		if(coords[i] != 0.0)
			any = 1;
	}
	if(!any)
		return f;
	nf := ref *fd;
	nf.coords = coords;
	nf.varwidths = array[fd.nglyphs] of { * => -1 };
	idx := addface(nf);
	face := ref Face(nf.nglyphs, nf.upem, nf.ascent, nf.descent, nf.fontname, nf.iscid);
	face.name = nf.fontname + "\t" + string idx;
	return face;
}

# avar's piecewise linear map of axis i's normalised value
avarmap(fd: ref FaceData, axis: int, v: real): real
{
	data := fd.ttfdata;
	o := fd.avaroff;
	if(o == 0 || o + 8 > len data)
		return v;
	n := getu16be(data, o + 6);
	if(axis >= n)
		return v;
	p := o + 8;
	for(i := 0; i < axis; i++) {
		if(p + 2 > len data)
			return v;
		p += 2 + 4*getu16be(data, p);
	}
	cnt := getu16be(data, p);
	p += 2;
	if(cnt < 2 || p + 4*cnt > len data)
		return v;
	pf := getf2dot14(data, p);
	pt := getf2dot14(data, p + 2);
	if(v <= pf)
		return pt;
	for(i = 1; i < cnt; i++) {
		f := getf2dot14(data, p + 4*i);
		t := getf2dot14(data, p + 4*i + 2);
		if(v <= f) {
			if(f == pf)
				return t;
			return pt + (t - pt) * (v - pf) / (f - pf);
		}
		pf = f;
		pt = t;
	}
	return pt;
}

# The deltas gvar gives glyph gid's n points and its four phantom
# points (n, n+1: the origin and the advance) at fd.coords, summed over
# the tuples that apply, each scaled; points a tuple leaves out are
# interpolated from those it moves (IUP) along each contour, endpts
# and the outline's (x, y) given; nil, nil when there are none.
glyphdeltas(fd: ref FaceData, gid, n: int, endpts, xs, ys: array of int): (array of real, array of real)
{
	data := fd.ttfdata;
	g := fd.gvaroff;
	if(g == 0 || g + 20 > len data)
		return (nil, nil);
	axiscount := getu16be(data, g + 4);
	nshared := getu16be(data, g + 6);
	sharedoff := g + getu32be(data, g + 8);
	glyphcount := getu16be(data, g + 12);
	flags := getu16be(data, g + 14);
	arrayoff := g + getu32be(data, g + 16);
	if(gid >= glyphcount || axiscount != len fd.coords)
		return (nil, nil);
	o0, o1: int;
	if(flags & 1) {
		o0 = getu32be(data, g + 20 + gid*4);
		o1 = getu32be(data, g + 20 + (gid+1)*4);
	} else {
		o0 = getu16be(data, g + 20 + gid*2) * 2;
		o1 = getu16be(data, g + 20 + (gid+1)*2) * 2;
	}
	if(o1 <= o0)
		return (nil, nil);
	gv := arrayoff + o0;
	if(gv + 4 > len data)
		return (nil, nil);
	tcount := getu16be(data, gv);
	sp := gv + getu16be(data, gv + 2);	# the serialized data
	np := n + 4;
	dx := array[np] of { * => 0.0 };
	dy := array[np] of { * => 0.0 };
	shared: array of int;
	if(tcount & 16r8000)
		(shared, sp) = packedpoints(data, sp);
	h := gv + 4;
	moved := 0;
	for(t := 0; t < (tcount & 16rFFF); t++) {
		if(h + 4 > len data)
			break;
		size := getu16be(data, h);
		tidx := getu16be(data, h + 2);
		h += 4;
		peak := array[axiscount] of real;
		if(tidx & 16r8000) {
			for(a := 0; a < axiscount; a++)
				peak[a] = getf2dot14(data, h + 2*a);
			h += 2*axiscount;
		} else {
			si := tidx & 16rFFF;
			if(si >= nshared)
				break;
			for(a := 0; a < axiscount; a++)
				peak[a] = getf2dot14(data, sharedoff + (si*axiscount + a)*2);
		}
		istart, iend: array of real;
		if(tidx & 16r4000) {
			istart = array[axiscount] of real;
			iend = array[axiscount] of real;
			for(a := 0; a < axiscount; a++) {
				istart[a] = getf2dot14(data, h + 2*a);
				iend[a] = getf2dot14(data, h + 2*(axiscount + a));
			}
			h += 4*axiscount;
		}
		tdata := sp;
		sp += size;
		sc := tuplescalar(fd.coords, peak, istart, iend);
		if(sc == 0.0)
			continue;
		pts := shared;
		p := tdata;
		if(tidx & 16r2000)
			(pts, p) = packedpoints(data, p);
		cnt := np;
		if(pts != nil)
			cnt = len pts;
		ddx, ddy: array of int;
		(ddx, p) = packeddeltas(data, p, cnt);
		(ddy, p) = packeddeltas(data, p, cnt);
		if(pts == nil) {
			for(i := 0; i < np; i++) {
				dx[i] += sc * real ddx[i];
				dy[i] += sc * real ddy[i];
			}
		} else {
			# the points it names; the rest of each contour inferred
			tx := array[np] of { * => 0.0 };
			ty := array[np] of { * => 0.0 };
			touched := array[np] of { * => 0 };
			for(i := 0; i < len pts; i++)
				if(pts[i] < np) {
					tx[pts[i]] = real ddx[i];
					ty[pts[i]] = real ddy[i];
					touched[pts[i]] = 1;
				}
			if(endpts != nil && xs != nil) {
				iup(tx, touched, xs, endpts);
				iup(ty, touched, ys, endpts);
			}
			for(i = 0; i < np; i++) {
				dx[i] += sc * tx[i];
				dy[i] += sc * ty[i];
			}
		}
		moved = 1;
	}
	if(!moved)
		return (nil, nil);
	return (dx, dy);
}

# a tuple's weight at coords (OpenType gvar, "Algorithm for
# calculating scalars")
tuplescalar(coords, peak, istart, iend: array of real): real
{
	s := 1.0;
	for(a := 0; a < len coords; a++) {
		p := peak[a];
		if(p == 0.0)
			continue;
		v := coords[a];
		if(v == 0.0)
			return 0.0;
		if(istart != nil) {
			st := istart[a];
			en := iend[a];
			if(v < st || v > en)
				return 0.0;
			if(v < p) {
				if(p != st)
					s *= (v - st) / (p - st);
			} else if(v > p) {
				if(en != p)
					s *= (en - v) / (en - p);
			}
		} else {
			if(v < 0.0 && p > 0.0 || v > 0.0 && p < 0.0)
				return 0.0;
			if(v < 0.0 && v < p || v > 0.0 && v > p)
				continue;	# beyond the peak: its full weight
			s *= v / p;
		}
	}
	return s;
}

# packed point numbers: nil means every point
packedpoints(data: array of byte, p: int): (array of int, int)
{
	if(p >= len data)
		return (nil, p);
	n := int data[p++];
	if(n == 0)
		return (nil, p);
	if(n & 16r80) {
		if(p >= len data)
			return (nil, p);
		n = (n & 16r7F) << 8 | int data[p++];
	}
	r := array[n] of int;
	last := 0;
	i := 0;
	while(i < n && p < len data) {
		c := int data[p++];
		run := (c & 16r7F) + 1;
		for(k := 0; k < run && i < n; k++) {
			d: int;
			if(c & 16r80) {
				if(p + 2 > len data)
					return (r[0:i], p);
				d = getu16be(data, p);
				p += 2;
			} else {
				if(p >= len data)
					return (r[0:i], p);
				d = int data[p++];
			}
			last += d;
			r[i++] = last;
		}
	}
	return (r[0:i], p);
}

packeddeltas(data: array of byte, p, n: int): (array of int, int)
{
	r := array[n] of { * => 0 };
	i := 0;
	while(i < n && p < len data) {
		c := int data[p++];
		run := (c & 16r3F) + 1;
		for(k := 0; k < run && i < n; k++) {
			if(c & 16r80)
				r[i] = 0;
			else if(c & 16r40) {
				if(p + 2 > len data)
					return (r, p);
				r[i] = geti16be(data, p);
				p += 2;
			} else {
				if(p >= len data)
					return (r, p);
				r[i] = geti8(data, p);
				p++;
			}
			i++;
		}
	}
	return (r, p);
}

# Interpolate the deltas of the points a tuple did not name, contour by
# contour, from the named ones either side (gvar, "Inferred deltas for
# un-referenced point numbers")
iup(d: array of real, touched: array of int, c: array of int, endpts: array of int)
{
	start := 0;
	for(ci := 0; ci < len endpts; ci++) {
		end := endpts[ci];
		if(end >= len c)
			break;
		first := -1;
		nt := 0;
		for(i := start; i <= end; i++)
			if(touched[i]) {
				if(first < 0)
					first = i;
				nt++;
			}
		if(nt > 0 && nt < end - start + 1) {
			if(nt == 1) {
				for(i = start; i <= end; i++)
					d[i] = d[first];
			} else {
				# walk from each touched point to the next, round the contour
				p := first;
				for(;;) {
					q := p + 1;
					if(q > end)
						q = start;
					while(!touched[q]) {
						q++;
						if(q > end)
							q = start;
					}
					# the untouched between p and q
					k := p + 1;
					if(k > end)
						k = start;
					while(k != q) {
						d[k] = between(real c[k], real c[p], real c[q], d[p], d[q]);
						k++;
						if(k > end)
							k = start;
					}
					p = q;
					if(p == first)
						break;
				}
			}
		}
		start = end + 1;
	}
}

between(x, x1, x2, d1, d2: real): real
{
	if(x1 == x2) {
		if(d1 == d2)
			return d1;
		return 0.0;
	}
	if(x1 > x2) {
		(x1, x2) = (x2, x1);
		(d1, d2) = (d2, d1);
	}
	if(x <= x1)
		return d1;
	if(x >= x2)
		return d2;
	return d1 + (x - x1) * (d2 - d1) / (x2 - x1);
}

# components in a composite glyph
ncomponents(data: array of byte, off: int): int
{
	pos := off + 10;
	n := 0;
	for(;;) {
		if(pos + 4 > len data)
			break;
		cf := getu16be(data, pos);
		pos += 4;
		if(cf & 16r01)
			pos += 4;
		else
			pos += 2;
		if(cf & 16r08)
			pos += 2;
		else if(cf & 16r40)
			pos += 4;
		else if(cf & 16r80)
			pos += 8;
		n++;
		if(!(cf & 16r20))
			break;
	}
	return n;
}

Face.cidtogid(f: self ref Face, cid: int): int
{
	fd := getfacedata(f);
	if(fd == nil || fd.cidmap == nil)
		return -1;
	if(cid < 0 || cid >= len fd.cidmap)
		return -1;
	return fd.cidmap[cid];
}

# The glyph for a character, or -1 if the font has none (no fallbacks).
Face.lookup(f: self ref Face, charcode: int): int
{
	fd := getfacedata(f);
	if(fd == nil || fd.ttfcmap == nil || charcode < 0 || charcode >= len fd.ttfcmap)
		return -1;
	gid := fd.ttfcmap[charcode];
	if(gid <= 0)
		return -1;
	return gid;
}

Face.chartogid(f: self ref Face, charcode: int): int
{
	fd := getfacedata(f);
	if(fd == nil || fd.ttfcmap == nil)
		return charcode;	# CFF: identity mapping
	if(charcode >= 0 && charcode < len fd.ttfcmap){
		gid := fd.ttfcmap[charcode];
		if(gid >= 0)
			return gid;
	}
	# Try symbolic encoding: PDF TrueType subsets often use
	# cmap platform 3, encoding 0 with codes at 0xF000+charcode
	symcode := charcode + 16rF000;
	if(symcode >= 0 && symcode < len fd.ttfcmap){
		gid := fd.ttfcmap[symcode];
		if(gid >= 0)
			return gid;
	}
	return charcode;	# unmapped: identity fallback
}

Face.drawglyph(f: self ref Face, gid: int, size: real,
	dst: ref Image, p: Point, src: ref Image): int
{
	if(display == nil || dst == nil || src == nil)
		return 0;
	fd := getfacedata(f);
	if(fd == nil || gid < 0 || gid >= fd.nglyphs)
		return 0;
	sc := size / real fd.upem;
	ce := glyph(getfaceidx(f), fd, gid, array[] of {sc, 0.0, 0.0, -sc}, 0, 0);
	if(ce == nil)
		return 0;
	if(ce.img != nil)
		dst.draw(ce.img.r.addpt((p.x + ce.ox, p.y + ce.oy)), src, ce.img, Point(0, 0));
	return ce.width;
}

Face.drawglyphm(f: self ref Face, gid: int, m: array of real,
	dst: ref Image, x, y: real, src: ref Image)
{
	if(display == nil || dst == nil || src == nil || len m < 4)
		return;
	fd := getfacedata(f);
	if(fd == nil || gid < 0 || gid >= fd.nglyphs)
		return;
	# the origin to a quarter pixel; upright text on a whole row
	ix := int math->floor(x);
	px := int ((x - real ix) * 4.0 + 0.5);
	if(px == 4){
		ix++;
		px = 0;
	}
	iy, py: int;
	if(upright(m)){
		iy = int math->floor(y + 0.5);
		py = 0;
	} else {
		iy = int math->floor(y);
		py = int ((y - real iy) * 4.0 + 0.5);
		if(py == 4){
			iy++;
			py = 0;
		}
	}
	ce := glyph(getfaceidx(f), fd, gid, m, px, py);
	if(ce != nil && ce.img != nil)
		dst.draw(ce.img.r.addpt((ix + ce.ox, iy + ce.oy)), src, ce.img, Point(0, 0));
}

# not slanted, rotated or mirrored: its tops and bottoms are hinted
upright(m: array of real): int
{
	return m[1] == 0.0 && m[2] == 0.0 && m[0] > 0.0 && m[3] < 0.0;
}

# A glyph through matrix m at an origin px/4, py/4 of a pixel in, from
# the cache or rasterised into it.
glyph(fidx: int, fd: ref FaceData, gid: int, m: array of real, px, py: int): ref CacheEntry
{
	k := matkey(m, fd.upem);
	phase := px*4 + py;
	ce := cachelookup(fidx, gid, k, phase);
	if(ce != nil)
		return ce;
	outline := getoutline(fd, gid);
	if(outline == nil)
		return nil;
	advpx := int (real outline.width * m[0] + 0.5);
	gimg: ref Image;
	ox, oy: int;
	if(outline.path != nil)
		(gimg, ox, oy) = rasterize(outline.path, m, real px / 4.0, real py / 4.0, upright(m));
	return cachestore(fidx, gid, k, phase, gimg, advpx, ox, oy);
}

Face.glyphname(f: self ref Face, gid: int): string
{
	fd := getfacedata(f);
	if(fd == nil)
		return nil;
	return fdglyphname(fd, gid);
}

fdglyphname(fd: ref FaceData, gid: int): string
{
	if(gid < 0 || gid >= fd.nglyphs)
		return nil;
	if(fd.names != nil)
		return fd.names[gid];
	if(fd.sids == nil || gid >= len fd.sids)
		return nil;
	return sidname(fd, fd.sids[gid]);
}

sidname(fd: ref FaceData, sid: int): string
{
	if(sid < NCFFSTD)
		return cffstd(sid);
	sid -= NCFFSTD;
	if(fd.strings == nil || sid >= fd.strings.count)
		return nil;
	return string fd.strings.data[sid];
}

Face.namedgid(f: self ref Face, name: string): int
{
	fd := getfacedata(f);
	if(fd == nil)
		return -1;
	return fdnamedgid(fd, name);
}

fdnamedgid(fd: ref FaceData, name: string): int
{
	if(name == nil || (fd.names == nil && fd.sids == nil))
		return -1;
	if(fd.namehash == nil){
		fd.namehash = array[NNAMEHASH] of list of (string, int);
		for(g := fd.nglyphs - 1; g >= 0; g--){
			n := fdglyphname(fd, g);
			if(n != nil){
				h := namehash(n);
				fd.namehash[h] = (n, g) :: fd.namehash[h];
			}
		}
	}
	for(l := fd.namehash[namehash(name)]; l != nil; l = tl l)
		if((hd l).t0 == name)
			return (hd l).t1;
	return -1;
}

NNAMEHASH: con 256;

namehash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h*31 + s[i];
	return (h & 16r7FFFFFFF) % NNAMEHASH;
}

# The standard strings, split when first wanted.
stdstrings: array of string;
NCFFSTD: con 391;

cffstd(sid: int): string
{
	if(stdstrings == nil){
		stdstrings = array[NCFFSTD] of string;
		s := Cffstrings;
		n := 0;
		for(i := 0; i < len s && n < NCFFSTD; ){
			for(j := i; j < len s && s[j] != ' '; j++)
				;
			stdstrings[n++] = s[i:j];
			i = j + 1;
		}
	}
	if(sid < 0 || sid >= NCFFSTD)
		return nil;
	return stdstrings[sid];
}

Face.close(f: self ref Face)
{
	idx := getfaceidx(f);
	if(idx >= 0 && idx < nfaces)
		facetab[idx] = nil;
}

Face.glyphwidth(f: self ref Face, gid: int, size: real): int
{
	fidx := getfaceidx(f);
	fd := getfacedata(f);
	if(fd == nil)
		return 0;

	if(gid < 0 || gid >= fd.nglyphs)
		return 0;

	if(fidx < 0)
		return 0;

	# Extract outline for width
	outline := getoutline(fd, gid);
	if(outline == nil)
		return 0;

	scale := size / real fd.upem;
	return int (real outline.width * scale + 0.5);
}

# Advance width in pixels, unrounded, for laying out text.  TrueType
# widths come straight from hmtx; CFF ones from the glyph's charstring.
Face.advance(f: self ref Face, gid: int, size: real): real
{
	fd := getfacedata(f);
	if(fd == nil || gid < 0 || gid >= fd.nglyphs)
		return 0.0;
	if(fd.isttf && fd.ttfwidths != nil && fd.coords == nil)
		return real fd.ttfwidths[gid] * size / real fd.upem;
	if(fd.varwidths != nil && fd.varwidths[gid] >= 0)
		return real fd.varwidths[gid] * size / real fd.upem;
	outline := getoutline(fd, gid);
	if(outline == nil)
		return 0.0;
	if(fd.varwidths != nil)
		fd.varwidths[gid] = outline.width;
	return real outline.width * size / real fd.upem;
}

Face.ymax(f: self ref Face, gid: int): int
{
	fd := getfacedata(f);
	if(fd == nil || !fd.isttf || gid < 0 || gid >= fd.nglyphs ||
	   fd.locaoffs == nil || gid + 1 >= len fd.locaoffs)
		return 0;
	off := fd.glyfoff + fd.locaoffs[gid];
	if(off >= fd.glyfoff + fd.locaoffs[gid+1] || off + 10 > len fd.ttfdata)
		return 0;
	return geti16be(fd.ttfdata, off + 8);
}

Face.xmetrics(f: self ref Face): (int, int)
{
	fd := getfacedata(f);
	if(fd == nil || !fd.isttf)
		return (0, 0);
	d := fd.ttfdata;
	avg := 0;
	bbox := 0;
	if((o := sfnttable(d, "OS/2")) > 0 && o + 4 <= len d)
		avg = geti16be(d, o + 2);
	if((h := sfnttable(d, "head")) > 0 && h + 44 <= len d)
		bbox = geti16be(d, h + 40) - geti16be(d, h + 36);
	return (avg, bbox);
}

# the offset of an sfnt table, 0 if the font has none
sfnttable(d: array of byte, tag: string): int
{
	if(len d < 12)
		return 0;
	n := getu16be(d, 4);
	for(i := 0; i < n && 12 + i*16 + 16 <= len d; i++) {
		e := 12 + i*16;
		if(string d[e:e+4] == tag)
			return getu32be(d, e + 8);
	}
	return 0;
}

Face.kern(f: self ref Face, left, right: int): int
{
	fd := getfacedata(f);
	if(fd == nil || left < 0 || right < 0)
		return 0;
	if(fd.nkern == 0) {
		if(fd.gpos != nil)
			return gposkern(fd, left, right);
		return 0;
	}
	key := (left << 16) | right;
	d := fd.ttfdata;
	lo := 0;
	hi := fd.nkern - 1;
	while(lo <= hi) {
		m := (lo + hi) / 2;
		o := fd.kernpairs + m*6;
		k := (getu16be(d, o) << 16) | getu16be(d, o + 2);
		if(k == key)
			return geti16be(d, o + 4);
		if(k < key)
			lo = m + 1;
		else
			hi = m - 1;
	}
	return 0;
}

# GPOS pair adjustment (lookup type 2): the advance change of left
# before right, from the kern feature's lookups
gposkern(fd: ref FaceData, left, right: int): int
{
	g := fd.gpos;
	data := g.data;
	for(ll := featurelookups(g, "kern"); ll != nil; ll = tl ll) {
		lk := g.lookups[hd ll];
		if(lk.kind != 2)
			continue;
		for(j := 0; j < len lk.subs; j++) {
			so := lk.subs[j];
			if(so + 10 > len data)
				continue;
			fmt := getu16be(data, so);
			ci := coverage(data, so + getu16be(data, so + 2), left);
			if(ci < 0)
				continue;
			vf1 := getu16be(data, so + 4);
			vf2 := getu16be(data, so + 6);
			n1 := bits(vf1);
			n2 := bits(vf2);
			if(!(vf1 & 4))	# no horizontal advance in this subtable
				continue;
			adv := 2 * bits(vf1 & 3);	# XPlacement, YPlacement come before XAdvance
			if(fmt == 1) {
				nsets := getu16be(data, so + 8);
				if(ci >= nsets || so + 10 + ci*2 + 2 > len data)
					continue;
				ps := so + getu16be(data, so + 10 + ci*2);
				if(ps + 2 > len data)
					continue;
				npairs := getu16be(data, ps);
				rec := 2 + 2*(n1 + n2);
				lo := 0;
				hi := npairs - 1;
				while(lo <= hi) {	# sorted by second glyph
					m := (lo + hi) / 2;
					r := ps + 2 + m*rec;
					if(r + rec > len data)
						break;
					gid := getu16be(data, r);
					if(gid == right)
						return geti16be(data, r + 2 + adv);
					if(gid < right)
						lo = m + 1;
					else
						hi = m - 1;
				}
			} else if(fmt == 2 && so + 16 <= len data) {
				c1 := classof(data, so + getu16be(data, so + 8), left);
				c2 := classof(data, so + getu16be(data, so + 10), right);
				n1c := getu16be(data, so + 12);
				n2c := getu16be(data, so + 14);
				if(c1 < 0 || c2 < 0 || c1 >= n1c || c2 >= n2c)
					continue;
				rec := 2*(n1 + n2);
				r := so + 16 + (c1*n2c + c2)*rec;
				if(r + rec <= len data)
					return geti16be(data, r + adv);
			}
		}
	}
	return 0;
}

bits(v: int): int
{
	n := 0;
	for(; v != 0; v >>= 1)
		n += v & 1;
	return n;
}

# the class of gid in a class definition table, 0 if not listed, -1 if the table is bad
classof(data: array of byte, off, gid: int): int
{
	if(off + 4 > len data)
		return -1;
	fmt := getu16be(data, off);
	if(fmt == 1) {
		start := getu16be(data, off + 2);
		n := getu16be(data, off + 4);
		if(gid < start || gid >= start + n || off + 6 + n*2 > len data)
			return 0;
		return getu16be(data, off + 6 + (gid - start)*2);
	}
	if(fmt == 2) {
		n := getu16be(data, off + 2);
		if(off + 4 + n*6 > len data)
			return -1;
		for(i := 0; i < n; i++) {
			r := off + 4 + i*6;
			if(gid >= getu16be(data, r) && gid <= getu16be(data, r + 2))
				return getu16be(data, r + 4);
		}
		return 0;
	}
	return -1;
}

# an anchor table's point
anchor(data: array of byte, off: int): (int, int)
{
	if(off + 6 > len data)
		return (0, 0);
	return (geti16be(data, off + 2), geti16be(data, off + 4));
}

Face.markanchor(f: self ref Face, base, mark: int): (int, int, int)
{
	fd := getfacedata(f);
	if(fd == nil || fd.gpos == nil)
		return (0, 0, 0);
	g := fd.gpos;
	data := g.data;
	for(ll := featurelookups(g, "mark"); ll != nil; ll = tl ll) {
		lk := g.lookups[hd ll];
		if(lk.kind != 4)
			continue;
		for(j := 0; j < len lk.subs; j++) {
			so := lk.subs[j];
			if(so + 12 > len data || getu16be(data, so) != 1)
				continue;
			mi := coverage(data, so + getu16be(data, so + 2), mark);
			bi := coverage(data, so + getu16be(data, so + 4), base);
			if(mi < 0 || bi < 0)
				continue;
			nclass := getu16be(data, so + 6);
			ma := so + getu16be(data, so + 8);
			ba := so + getu16be(data, so + 10);
			if(ma + 2 + mi*4 + 4 > len data || ba + 2 > len data)
				continue;
			if(mi >= getu16be(data, ma))
				continue;
			cls := getu16be(data, ma + 2 + mi*4);
			mao := getu16be(data, ma + 4 + mi*4);
			if(cls >= nclass || bi >= getu16be(data, ba))
				continue;
			r := ba + 2 + (bi*nclass + cls)*2;
			if(r + 2 > len data)
				continue;
			bao := getu16be(data, r);
			if(bao == 0)
				continue;
			(bx, by) := anchor(data, ba + bao);
			(mx, my) := anchor(data, ma + mao);
			return (1, bx - mx, by - my);
		}
	}
	return (0, 0, 0);
}

# ---- GSUB: glyph substitution (OpenType Layout) ----

Gsub: adt {
	data:	array of byte;
	lookups:	array of ref Lookup;
	features:	list of (string, array of int);	# tag, lookup indices
};

Lookup: adt {
	kind:	int;		# 1 single, 4 ligature, 0 other (not applied)
	subs:	array of int;	# subtable offsets, extension lookups resolved
};

# GSUB and GPOS share a layout: a feature list naming lookups, each
# of subtables; ext is the lookup type that wraps another (7, 9)
parsegsub(data: array of byte, off, ext: int): ref Gsub
{
	if(off <= 0 || off + 10 > len data)
		return nil;
	flist := off + getu16be(data, off + 6);
	llist := off + getu16be(data, off + 8);
	if(flist + 2 > len data || llist + 2 > len data)
		return nil;
	nl := getu16be(data, llist);
	if(llist + 2 + nl*2 > len data)
		return nil;
	lookups := array[nl] of ref Lookup;
	for(i := 0; i < nl; i++) {
		lo := llist + getu16be(data, llist + 2 + i*2);
		if(lo + 6 > len data) {
			lookups[i] = ref Lookup(0, nil);
			continue;
		}
		kind := getu16be(data, lo);
		ns := getu16be(data, lo + 4);
		if(lo + 6 + ns*2 > len data)
			ns = 0;
		subs := array[ns] of int;
		for(j := 0; j < ns; j++) {
			so := lo + getu16be(data, lo + 6 + j*2);
			if(kind == ext && so + 8 <= len data)
				subs[j] = so + getu32be(data, so + 4);	# an extension: the subtable is elsewhere
			else
				subs[j] = so;
		}
		if(kind == ext && ns > 0) {
			so := lo + getu16be(data, lo + 6);
			if(so + 4 <= len data)
				kind = getu16be(data, so + 2);
		}
		lookups[i] = ref Lookup(kind, subs);
	}
	nf := getu16be(data, flist);
	feats: list of (string, array of int);
	for(i = 0; i < nf && flist + 2 + i*6 + 6 <= len data; i++) {
		e := flist + 2 + i*6;
		tag := string data[e:e+4];
		fo := flist + getu16be(data, e + 4);
		if(fo + 4 > len data)
			continue;
		cnt := getu16be(data, fo + 2);
		if(fo + 4 + cnt*2 > len data)
			continue;
		li := array[cnt] of int;
		for(j := 0; j < cnt; j++)
			li[j] = getu16be(data, fo + 4 + j*2);
		feats = (tag, li) :: feats;
	}
	return ref Gsub(data, lookups, feats);
}

# the coverage index of gid in the coverage table at off, or -1
coverage(data: array of byte, off, gid: int): int
{
	if(off + 4 > len data)
		return -1;
	fmt := getu16be(data, off);
	n := getu16be(data, off + 2);
	if(fmt == 1) {
		if(off + 4 + n*2 > len data)
			return -1;
		lo := 0;
		hi := n - 1;
		while(lo <= hi) {
			m := (lo + hi) / 2;
			g := getu16be(data, off + 4 + m*2);
			if(g == gid)
				return m;
			if(g < gid)
				lo = m + 1;
			else
				hi = m - 1;
		}
		return -1;
	}
	if(fmt == 2) {
		if(off + 4 + n*6 > len data)
			return -1;
		for(i := 0; i < n; i++) {
			r := off + 4 + i*6;
			s := getu16be(data, r);
			e := getu16be(data, r + 2);
			if(gid >= s && gid <= e)
				return getu16be(data, r + 4) + gid - s;
		}
	}
	return -1;
}

# the lookups a feature names, in index order, without repeats
featurelookups(g: ref Gsub, feat: string): list of int
{
	r: list of int;
	for(l := g.features; l != nil; l = tl l) {
		(tag, li) := hd l;
		if(tag != feat)
			continue;
		for(i := 0; i < len li; i++) {
			for(m := r; m != nil; m = tl m)
				if(hd m == li[i])
					break;
			if(m == nil)
				r = li[i] :: r;
		}
	}
	a := array[len r] of int;
	for(i := 0; r != nil; r = tl r)
		a[i++] = hd r;
	for(i = 1; i < len a; i++)
		for(j := i; j > 0 && a[j] < a[j-1]; j--)
			(a[j], a[j-1]) = (a[j-1], a[j]);
	s: list of int;
	for(i = len a - 1; i >= 0; i--)
		s = a[i] :: s;
	return s;
}

Face.hasfeature(f: self ref Face, feat: string): int
{
	fd := getfacedata(f);
	if(fd == nil || fd.gsub == nil)
		return 0;
	for(l := fd.gsub.features; l != nil; l = tl l)
		if((hd l).t0 == feat)
			return 1;
	return 0;
}

Face.ligatures(f: self ref Face, gids: array of int, feats: list of string): (array of int, array of int)
{
	cnt := array[len gids] of {* => 1};
	fd := getfacedata(f);
	if(fd == nil || fd.gsub == nil || len gids < 2)
		return (gids, cnt);
	g := fd.gsub;
	for(; feats != nil; feats = tl feats)
		for(ll := featurelookups(g, hd feats); ll != nil; ll = tl ll) {
			lk := g.lookups[hd ll];
			if(lk.kind != 4)
				continue;
			for(j := 0; j < len lk.subs; j++)
				(gids, cnt) = applylig(g.data, lk.subs[j], gids, cnt);
		}
	return (gids, cnt);
}

# a ligature subtable (format 1) over a run of glyphs: at each glyph
# the first ligature of its set whose components follow is taken
applylig(data: array of byte, so: int, gids, cnt: array of int): (array of int, array of int)
{
	if(so + 6 > len data || getu16be(data, so) != 1)
		return (gids, cnt);
	cov := so + getu16be(data, so + 2);
	nsets := getu16be(data, so + 4);
	if(so + 6 + nsets*2 > len data)
		return (gids, cnt);
	out := array[len gids] of int;
	ocnt := array[len gids] of int;
	n := 0;
	i := 0;
	while(i < len gids) {
		ci := coverage(data, cov, gids[i]);
		if(ci >= 0 && ci < nsets) {
			seto := so + getu16be(data, so + 6 + ci*2);
			took := 0;
			if(seto + 2 <= len data) {
				nlig := getu16be(data, seto);
				for(k := 0; k < nlig && seto + 4 + k*2 <= len data; k++) {
					lo := seto + getu16be(data, seto + 2 + k*2);
					if(lo + 4 > len data)
						continue;
					lig := getu16be(data, lo);
					nc := getu16be(data, lo + 2);
					if(nc < 1 || i + nc > len gids || lo + 4 + (nc-1)*2 > len data)
						continue;
					ok := 1;
					for(m := 1; m < nc; m++)
						if(gids[i+m] != getu16be(data, lo + 4 + (m-1)*2)) {
							ok = 0;
							break;
						}
					if(ok) {
						out[n] = lig;
						ocnt[n] = 0;
						for(m = 0; m < nc; m++)
							ocnt[n] += cnt[i + m];
						n++;
						i += nc;
						took = 1;
						break;
					}
				}
			}
			if(took)
				continue;
		}
		ocnt[n] = cnt[i];
		out[n++] = gids[i++];
	}
	return (out[0:n], ocnt[0:n]);
}

Face.subst(f: self ref Face, feat: string, gid: int): int
{
	fd := getfacedata(f);
	if(fd == nil || fd.gsub == nil)
		return gid;
	g := fd.gsub;
	data := g.data;
	for(ll := featurelookups(g, feat); ll != nil; ll = tl ll) {
		lk := g.lookups[hd ll];
		if(lk.kind != 1)
			continue;
		for(j := 0; j < len lk.subs; j++) {
			so := lk.subs[j];
			if(so + 6 > len data)
				continue;
			fmt := getu16be(data, so);
			ci := coverage(data, so + getu16be(data, so + 2), gid);
			if(ci < 0)
				continue;
			if(fmt == 1)
				return (gid + getu16be(data, so + 4)) & 16rFFFF;
			if(fmt == 2) {
				n := getu16be(data, so + 4);
				if(ci < n && so + 6 + ci*2 + 2 <= len data)
					return getu16be(data, so + 6 + ci*2);
			}
		}
	}
	return gid;
}

Face.metrics(f: self ref Face, size: real): (int, int, int)
{
	fd := getfacedata(f);
	if(fd == nil)
		return (0, 0, 0);

	scale := size / real fd.upem;
	asc := int (real fd.ascent * scale + 0.5);
	desc := int (real fd.descent * scale - 0.5);	# descent is negative
	if(desc > 0) desc = -desc;
	height := asc - desc;
	return (height, asc, desc);
}

# ---- Glyph cache ----

# A matrix's cache key: its terms in 1/64 px per em.  Sizes as close
# as 16px and 16.08px (0.67em of 24px) are two keys, so a page draws
# its 16px text with the 16px raster, whatever an earlier page made.
matkey(m: array of real, upem: int): array of int
{
	k := array[4] of int;
	for(i := 0; i < 4; i++)
		k[i] = int (m[i] * real upem * 64.0);	# int of a real rounds
	return k;
}

cachehash(faceidx, gid: int, k: array of int, phase: int): int
{
	return ((((faceidx * 7919 + gid) * 31 + k[0]) * 31 + k[1] + k[2]) * 31 + k[3] + phase) & (NCACHEHASH - 1);
}

cachelookup(faceidx, gid: int, k: array of int, phase: int): ref CacheEntry
{
	if(cachetab == nil)
		return nil;
	for(cl := cachetab[cachehash(faceidx, gid, k, phase)]; cl != nil; cl = tl cl){
		ce := hd cl;
		if(ce.faceidx == faceidx && ce.gid == gid && ce.phase == phase &&
		   ce.k[0] == k[0] && ce.k[1] == k[1] && ce.k[2] == k[2] && ce.k[3] == k[3])
			return ce;
	}
	return nil;
}

cachestore(faceidx, gid: int, k: array of int, phase: int, img: ref Image, width, ox, oy: int): ref CacheEntry
{
	if(cachetab == nil)
		cachetab = array[NCACHEHASH] of list of ref CacheEntry;
	# When full, start again: rendering a page touches a working set
	# far smaller than the cache, so this is rare.
	npix := 0;
	if(img != nil)
		npix = img.r.dx() * img.r.dy();
	if(ncached >= MAXCACHE || cachepix + npix > MAXCACHEPIX){
		cachetab = array[NCACHEHASH] of list of ref CacheEntry;
		ncached = 0;
		cachepix = 0;
	}
	h := cachehash(faceidx, gid, k, phase);
	ce := ref CacheEntry(faceidx, gid, k, phase, img, width, ox, oy);
	cachetab[h] = ce :: cachetab[h];
	ncached++;
	cachepix += npix;
	return ce;
}

# ---- Outline extraction ----

getoutline(fd: ref FaceData, gid: int): ref GlyphOutline
{
	if(fd.isttf)
		return getttfoutline(fd, gid);
	if(fd.t1cs != nil)
		return t1outline(fd, gid);

	if(fd.charstrings == nil || gid < 0 || gid >= fd.charstrings.count)
		return nil;

	csdata := fd.charstrings.data[gid];
	if(csdata == nil || len csdata == 0)
		return ref GlyphOutline(nil, 0);

	# Select private dict and local subrs based on FD
	privd := fd.privdict;
	lsubrs := fd.lsubrs;
	if(fd.iscid && fd.fdselect != nil && gid < len fd.fdselect){
		fdi := int fd.fdselect[gid];
		if(fdi >= 0 && fdi < fd.fdcount){
			if(fd.fdprivate != nil && fdi < len fd.fdprivate)
				privd = fd.fdprivate[fdi];
			if(fd.fdlsubrs != nil && fdi < len fd.fdlsubrs)
				lsubrs = fd.fdlsubrs[fdi];
		}
	}

	nomw := 0;
	defw := 0;
	if(privd != nil){
		nomw = privd.nominalw;
		defw = privd.defaultw;
	}

	return interpcharstring(csdata, fd.gsubrs, lsubrs, nomw, defw);
}

# ---- Type 2 charstring interpreter ----

# Operand stack
T2MAXSTACK: con 48;

interpcharstring(csdata: array of byte, gsubrs, lsubrs: ref CffIndex,
	nominalw, defaultw: int): ref GlyphOutline
{
	stack := array[T2MAXSTACK] of { * => 0.0 };
	sp := 0;
	path: list of ref PathSeg;
	cx := 0.0;
	cy := 0.0;
	width := defaultw;
	widthset := 0;
	nhints := 0;
	firstmove := 1;

	# Call stack for subrs
	MAXCALLSTACK: con 10;
	callstack := array[MAXCALLSTACK] of {* => (array[0] of byte, 0)};
	calldepth := 0;

	data := csdata;
	pos := 0;

	for(;;){
		if(pos >= len data){
			# Return from subr?
			if(calldepth > 0){
				calldepth--;
				(data, pos) = callstack[calldepth];
				continue;
			}
			break;
		}

		b0 := int data[pos];
		pos++;

		# ---- Number encoding ----
		if(b0 >= 32 && b0 <= 246){
			if(sp < T2MAXSTACK)
				stack[sp++] = real (b0 - 139);
			continue;
		}
		if(b0 >= 247 && b0 <= 250){
			if(pos >= len data) break;
			b1 := int data[pos]; pos++;
			if(sp < T2MAXSTACK)
				stack[sp++] = real ((b0 - 247) * 256 + b1 + 108);
			continue;
		}
		if(b0 >= 251 && b0 <= 254){
			if(pos >= len data) break;
			b1 := int data[pos]; pos++;
			if(sp < T2MAXSTACK)
				stack[sp++] = real (-(b0 - 251) * 256 - b1 - 108);
			continue;
		}
		if(b0 == 255){
			# 5-byte fixed point: 16.16
			if(pos + 4 > len data) break;
			v := (int data[pos] << 24) | (int data[pos+1] << 16) |
			     (int data[pos+2] << 8) | int data[pos+3];
			pos += 4;
			# int is 32-bit signed — sign extension is automatic
			if(sp < T2MAXSTACK)
				stack[sp++] = real v / 65536.0;
			continue;
		}

		# ---- Two-byte operators (escape) ----
		if(b0 == 12){
			if(pos >= len data) break;
			b1 := int data[pos]; pos++;
			case b1 {
			34 =>	# hflex
				if(sp >= 7){
					dx1 := stack[0]; dy1 := 0.0;
					dx2 := stack[1]; dy2 := stack[2];
					dx3 := stack[3]; dy3 := 0.0;
					dx4 := stack[4]; dy4 := 0.0;
					dx5 := stack[5]; dy5 := -dy2;
					dx6 := stack[6]; dy6 := 0.0;
					x1 := cx + dx1; y1 := cy + dy1;
					x2 := x1 + dx2; y2 := y1 + dy2;
					x3 := x2 + dx3; y3 := y2 + dy3;
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
					x4 := cx + dx4; y4 := cy + dy4;
					x5 := x4 + dx5; y5 := y4 + dy5;
					x6 := x5 + dx6; y6 := y5 + dy6;
					path = ref PathSeg.Curve(x4, y4, x5, y5, x6, y6) :: path;
					cx = x6; cy = y6;
				}
				sp = 0;
			35 =>	# flex
				if(sp >= 13){
					dx1 := stack[0]; dy1 := stack[1];
					dx2 := stack[2]; dy2 := stack[3];
					dx3 := stack[4]; dy3 := stack[5];
					dx4 := stack[6]; dy4 := stack[7];
					dx5 := stack[8]; dy5 := stack[9];
					dx6 := stack[10]; dy6 := stack[11];
					# stack[12] is fd (flex depth), ignored
					x1 := cx + dx1; y1 := cy + dy1;
					x2 := x1 + dx2; y2 := y1 + dy2;
					x3 := x2 + dx3; y3 := y2 + dy3;
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
					x4 := cx + dx4; y4 := cy + dy4;
					x5 := x4 + dx5; y5 := y4 + dy5;
					x6 := x5 + dx6; y6 := y5 + dy6;
					path = ref PathSeg.Curve(x4, y4, x5, y5, x6, y6) :: path;
					cx = x6; cy = y6;
				}
				sp = 0;
			36 =>	# hflex1
				if(sp >= 9){
					dx1 := stack[0]; dy1 := stack[1];
					dx2 := stack[2]; dy2 := stack[3];
					dx3 := stack[4]; dy3 := 0.0;
					dx4 := stack[5]; dy4 := 0.0;
					dx5 := stack[6]; dy5 := stack[7];
					dx6 := stack[8];
					dy6 := -(dy1 + dy2 + dy3 + dy4 + dy5);
					x1 := cx + dx1; y1 := cy + dy1;
					x2 := x1 + dx2; y2 := y1 + dy2;
					x3 := x2 + dx3; y3 := y2 + dy3;
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
					x4 := cx + dx4; y4 := cy + dy4;
					x5 := x4 + dx5; y5 := y4 + dy5;
					x6 := x5 + dx6; y6 := y5 + dy6;
					path = ref PathSeg.Curve(x4, y4, x5, y5, x6, y6) :: path;
					cx = x6; cy = y6;
				}
				sp = 0;
			37 =>	# flex1
				if(sp >= 11){
					dx1 := stack[0]; dy1 := stack[1];
					dx2 := stack[2]; dy2 := stack[3];
					dx3 := stack[4]; dy3 := stack[5];
					dx4 := stack[6]; dy4 := stack[7];
					dx5 := stack[8]; dy5 := stack[9];
					# last arg is either dx6 or dy6
					sdx := dx1+dx2+dx3+dx4+dx5;
					sdy := dy1+dy2+dy3+dy4+dy5;
					dx6 := 0.0;
					dy6 := 0.0;
					if(fabs(sdx) > fabs(sdy)){
						dx6 = stack[10];
						dy6 = -sdy;
					} else {
						dx6 = -sdx;
						dy6 = stack[10];
					}
					x1 := cx + dx1; y1 := cy + dy1;
					x2 := x1 + dx2; y2 := y1 + dy2;
					x3 := x2 + dx3; y3 := y2 + dy3;
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
					x4 := cx + dx4; y4 := cy + dy4;
					x5 := x4 + dx5; y5 := y4 + dy5;
					x6 := x5 + dx6; y6 := y5 + dy6;
					path = ref PathSeg.Curve(x4, y4, x5, y5, x6, y6) :: path;
					cx = x6; cy = y6;
				}
				sp = 0;
			* =>
				# Other 2-byte ops: arithmetic, etc. — ignore
				sp = 0;
			}
			continue;
		}

		# ---- Single-byte operators ----
		case b0 {
		1 or 3 or 18 or 23 =>
			# hstem, vstem, hstemhm, vstemhm
			# Consume hint pairs; check for width
			if(!widthset && (sp & 1) != 0){
				width = int stack[0] + nominalw;
				widthset = 1;
				# Shift stack down by 1
				for(si := 0; si < sp - 1; si++)
					stack[si] = stack[si+1];
				sp--;
			}
			nhints += sp / 2;
			sp = 0;
		19 or 20 =>
			# hintmask, cntrmask
			if(!widthset && (sp & 1) != 0){
				width = int stack[0] + nominalw;
				widthset = 1;
				for(si := 0; si < sp - 1; si++)
					stack[si] = stack[si+1];
				sp--;
			}
			nhints += sp / 2;
			sp = 0;
			# Skip mask bytes
			nbytes := (nhints + 7) / 8;
			pos += nbytes;
			if(pos > len data) pos = len data;
		21 =>
			# rmoveto
			if(!widthset && sp > 2){
				width = int stack[0] + nominalw;
				widthset = 1;
				stack[0] = stack[sp-2];
				stack[1] = stack[sp-1];
				sp = 2;
			}
			widthset = 1;
			if(sp >= 2){
				if(!firstmove)
					path = ref PathSeg.Close :: path;
				firstmove = 0;
				cx += stack[0]; cy += stack[1];
				path = ref PathSeg.Move(cx, cy) :: path;
			}
			sp = 0;
		22 =>
			# hmoveto
			if(!widthset && sp > 1){
				width = int stack[0] + nominalw;
				widthset = 1;
				stack[0] = stack[sp-1];
				sp = 1;
			}
			widthset = 1;
			if(sp >= 1){
				if(!firstmove)
					path = ref PathSeg.Close :: path;
				firstmove = 0;
				cx += stack[0];
				path = ref PathSeg.Move(cx, cy) :: path;
			}
			sp = 0;
		4 =>
			# vmoveto
			if(!widthset && sp > 1){
				width = int stack[0] + nominalw;
				widthset = 1;
				stack[0] = stack[sp-1];
				sp = 1;
			}
			widthset = 1;
			if(sp >= 1){
				if(!firstmove)
					path = ref PathSeg.Close :: path;
				firstmove = 0;
				cy += stack[0];
				path = ref PathSeg.Move(cx, cy) :: path;
			}
			sp = 0;
		5 =>
			# rlineto
			i := 0;
			while(i + 1 < sp){
				cx += stack[i]; cy += stack[i+1];
				path = ref PathSeg.Line(cx, cy) :: path;
				i += 2;
			}
			sp = 0;
		6 =>
			# hlineto — alternating horizontal/vertical lines
			i := 0;
			while(i < sp){
				cx += stack[i];
				path = ref PathSeg.Line(cx, cy) :: path;
				i++;
				if(i >= sp) break;
				cy += stack[i];
				path = ref PathSeg.Line(cx, cy) :: path;
				i++;
			}
			sp = 0;
		7 =>
			# vlineto — alternating vertical/horizontal lines
			i := 0;
			while(i < sp){
				cy += stack[i];
				path = ref PathSeg.Line(cx, cy) :: path;
				i++;
				if(i >= sp) break;
				cx += stack[i];
				path = ref PathSeg.Line(cx, cy) :: path;
				i++;
			}
			sp = 0;
		8 =>
			# rrcurveto
			i := 0;
			while(i + 5 < sp){
				x1 := cx + stack[i];   y1 := cy + stack[i+1];
				x2 := x1 + stack[i+2]; y2 := y1 + stack[i+3];
				x3 := x2 + stack[i+4]; y3 := y2 + stack[i+5];
				path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
				cx = x3; cy = y3;
				i += 6;
			}
			sp = 0;
		27 =>
			# hhcurveto
			i := 0;
			dy1 := 0.0;
			if((sp & 1) != 0){
				dy1 = stack[0];
				i = 1;
			}
			while(i + 3 < sp){
				x1 := cx + stack[i];
				y1 := cy + dy1;
				x2 := x1 + stack[i+1]; y2 := y1 + stack[i+2];
				x3 := x2 + stack[i+3]; y3 := y2;
				path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
				cx = x3; cy = y3;
				dy1 = 0.0;
				i += 4;
			}
			sp = 0;
		26 =>
			# vvcurveto
			i := 0;
			dx1 := 0.0;
			if((sp & 1) != 0){
				dx1 = stack[0];
				i = 1;
			}
			while(i + 3 < sp){
				x1 := cx + dx1;
				y1 := cy + stack[i];
				x2 := x1 + stack[i+1]; y2 := y1 + stack[i+2];
				x3 := x2;              y3 := y2 + stack[i+3];
				path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
				cx = x3; cy = y3;
				dx1 = 0.0;
				i += 4;
			}
			sp = 0;
		31 =>
			# hvcurveto — alternating h-start/v-start curves
			i := 0;
			phase := 0;
			while(i + 3 < sp){
				if(phase == 0){
					# h-start
					x1 := cx + stack[i]; y1 := cy;
					x2 := x1 + stack[i+1]; y2 := y1 + stack[i+2];
					x3 := x2; y3 := y2 + stack[i+3];
					# last curve may have extra dx
					if(i + 4 == sp - 1){
						x3 += stack[i+4];
						i++;
					}
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
				} else {
					# v-start
					x1 := cx; y1 := cy + stack[i];
					x2 := x1 + stack[i+1]; y2 := y1 + stack[i+2];
					x3 := x2 + stack[i+3]; y3 := y2;
					# last curve may have extra dy
					if(i + 4 == sp - 1){
						y3 += stack[i+4];
						i++;
					}
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
				}
				i += 4;
				phase = 1 - phase;
			}
			sp = 0;
		30 =>
			# vhcurveto — alternating v-start/h-start curves
			i := 0;
			phase := 0;
			while(i + 3 < sp){
				if(phase == 0){
					# v-start
					x1 := cx; y1 := cy + stack[i];
					x2 := x1 + stack[i+1]; y2 := y1 + stack[i+2];
					x3 := x2 + stack[i+3]; y3 := y2;
					if(i + 4 == sp - 1){
						y3 += stack[i+4];
						i++;
					}
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
				} else {
					# h-start
					x1 := cx + stack[i]; y1 := cy;
					x2 := x1 + stack[i+1]; y2 := y1 + stack[i+2];
					x3 := x2; y3 := y2 + stack[i+3];
					if(i + 4 == sp - 1){
						x3 += stack[i+4];
						i++;
					}
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
					cx = x3; cy = y3;
				}
				i += 4;
				phase = 1 - phase;
			}
			sp = 0;
		24 =>
			# rcurveline — curves then a line
			i := 0;
			while(i + 7 < sp){
				x1 := cx + stack[i];   y1 := cy + stack[i+1];
				x2 := x1 + stack[i+2]; y2 := y1 + stack[i+3];
				x3 := x2 + stack[i+4]; y3 := y2 + stack[i+5];
				path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
				cx = x3; cy = y3;
				i += 6;
			}
			if(i + 1 < sp){
				cx += stack[i]; cy += stack[i+1];
				path = ref PathSeg.Line(cx, cy) :: path;
			}
			sp = 0;
		25 =>
			# rlinecurve — lines then a curve
			i := 0;
			nlines := (sp - 6) / 2;
			nl := 0;
			while(nl < nlines && i + 1 < sp){
				cx += stack[i]; cy += stack[i+1];
				path = ref PathSeg.Line(cx, cy) :: path;
				i += 2;
				nl++;
			}
			if(i + 5 < sp){
				x1 := cx + stack[i];   y1 := cy + stack[i+1];
				x2 := x1 + stack[i+2]; y2 := y1 + stack[i+3];
				x3 := x2 + stack[i+4]; y3 := y2 + stack[i+5];
				path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
				cx = x3; cy = y3;
			}
			sp = 0;
		14 =>
			# endchar
			if(!widthset && sp > 0){
				width = int stack[0] + nominalw;
				widthset = 1;
			}
			if(!firstmove)
				path = ref PathSeg.Close :: path;
			sp = 0;
			# End of glyph
			if(calldepth > 0){
				calldepth = 0;
			}
			break;
		10 =>
			# callsubr (local)
			if(sp > 0 && lsubrs != nil){
				sp--;
				subridx := int stack[sp];
				subridx += subrbiasn(lsubrs.count);
				if(subridx >= 0 && subridx < lsubrs.count){
					if(calldepth < MAXCALLSTACK){
						callstack[calldepth] = (data, pos);
						calldepth++;
						data = lsubrs.data[subridx];
						pos = 0;
					}
				}
			} else
				sp = 0;
		29 =>
			# callgsubr (global)
			if(sp > 0 && gsubrs != nil){
				sp--;
				subridx := int stack[sp];
				subridx += subrbiasn(gsubrs.count);
				if(subridx >= 0 && subridx < gsubrs.count){
					if(calldepth < MAXCALLSTACK){
						callstack[calldepth] = (data, pos);
						calldepth++;
						data = gsubrs.data[subridx];
						pos = 0;
					}
				}
			} else
				sp = 0;
		11 =>
			# return
			if(calldepth > 0){
				calldepth--;
				(data, pos) = callstack[calldepth];
			}
		* =>
			# Unknown operator — clear stack
			sp = 0;
		}
	}

	return ref GlyphOutline(path, width);
}

subrbiasn(n: int): int
{
	if(n < 1240) return 107;
	if(n < 33900) return 1131;
	return 32768;
}

fabs(x: real): real
{
	if(x < 0.0) return -x;
	return x;
}

# ---- Rasterizer ----

# A glyph's outline as a GREY8 coverage mask, filled non-zero (the
# convention both CFF and TrueType outlines follow) by the draw device
# (Image.fillpath), and where the mask sits relative to the glyph's
# origin, in pixels.  The outline goes through m (see drawglyphm),
# offset by fx, fy (the origin's fraction of a pixel).
rasterize(path: list of ref PathSeg, m: array of real, fx, fy: real, hint: int): (ref Image, int, int)
{
	rpath := revsegs(path);	# built in reverse by the charstring interpreter
	(a, b, c, d) := (m[0], m[1], m[2], m[3]);

	# the bounds of every point, control points included: the curves
	# lie inside them
	minx := miny := 1.0e30;
	maxx := maxy := -1.0e30;
	n := 0;
	for(p := rpath; p != nil; p = tl p){
		pts: array of real;
		pick s := hd p {
		Move or Line =>
			pts = array[] of {s.x, s.y};
		Curve =>
			pts = array[] of {s.x1, s.y1, s.x2, s.y2, s.x3, s.y3};
		}
		for(i := 0; i < len pts; i += 2){
			x := a*pts[i] + c*pts[i+1] + fx;
			y := b*pts[i] + d*pts[i+1] + fy;
			if(x < minx) minx = x;
			if(x > maxx) maxx = x;
			if(y < miny) miny = y;
			if(y > maxy) maxy = y;
			n++;
		}
	}
	if(n == 0)
		return (nil, 0, 0);
	# Light hinting, for upright text: the glyph's top and bottom edges
	# land on pixel rows (the baseline, at 0, already does), the outline
	# stretched linearly between them.  A flat edge is then crisp, as in
	# a hinted rasteriser, rather than smeared over two rows.
	sy := 1.0;
	ty := 0.0;
	if(hint && maxy - miny > 0.0) {
		bot := math->floor(miny + 0.5);
		top := math->floor(maxy + 0.5);
		if(top <= bot)
			top = bot + 1.0;
		sy = (top - bot) / (maxy - miny);
		ty = bot - miny*sy;
		miny = bot;
		maxy = top;
	}
	ox := int math->floor(minx) - 1;
	oy := int math->floor(miny) - 1;
	w := int math->ceil(maxx) + 1 - ox;
	h := int math->ceil(maxy) + 1 - oy;
	if(w <= 0 || h <= 0 || w > 8192 || h > 8192)
		return (nil, 0, 0);

	# device point: x = a*u + c*v + fx - ox, y = (b*u + d*v + fy)*sy + ty - oy
	tx := fx - real ox;
	ty += fy*sy - real oy;
	(b, d) = (b*sy, d*sy);
	outline := Path.new();
	for(p = rpath; p != nil; p = tl p){
		pick s := hd p {
		Move =>
			outline.moveto(a*s.x + c*s.y + tx, b*s.x + d*s.y + ty);
		Line =>
			outline.lineto(a*s.x + c*s.y + tx, b*s.x + d*s.y + ty);
		Curve =>
			outline.curveto(a*s.x1 + c*s.y1 + tx, b*s.x1 + d*s.y1 + ty,
				a*s.x2 + c*s.y2 + tx, b*s.x2 + d*s.y2 + ty,
				a*s.x3 + c*s.y3 + tx, b*s.x3 + d*s.y3 + ty);
		Close =>
			outline.close();
		}
	}
	mask := display.newimage(Rect((0, 0), (w, h)), Draw->GREY8, 0, Draw->Transparent);
	if(mask == nil)
		return (nil, 0, 0);
	mask.fillpath(outline, ~0, display.opaque, (0, 0));
	return (mask, ox, oy);
}

revsegs(path: list of ref PathSeg): list of ref PathSeg
{
	rev: list of ref PathSeg;
	for(; path != nil; path = tl path)
		rev = hd path :: rev;
	return rev;
}

# ---- Type 1 ----
#
# Adobe Type 1 Font Format (1990): the clear text names the font, its
# matrix and encoding; the rest is eexec-encrypted, and in it the
# Private dictionary's Subrs and CharStrings, each encrypted again.
# A PDF's FontFile is the clear text then the encrypted part, binary
# or hex; a PFB has segment headers.

parset1(data: array of byte): (ref FaceData, string)
{
	clear, enc: array of byte;
	if(len data > 6 && int data[0] == 16r80){
		# PFB: segments of 0x80, type, length (little-endian)
		for(p := 0; p + 6 <= len data && int data[p] == 16r80; ){
			t := int data[p+1];
			if(t == 3)
				break;
			n := int data[p+2] | (int data[p+3]<<8) | (int data[p+4]<<16) | (int data[p+5]<<24);
			p += 6;
			if(n < 0 || p + n > len data)
				n = len data - p;
			if(t == 1 && clear == nil)
				clear = data[p:p+n];
			else if(t == 2)
				enc = catbytes(enc, data[p:p+n]);
			p += n;
		}
	} else {
		e := findbytes(data, 0, "eexec");
		if(e < 0)
			return (nil, "Type 1: no eexec");
		clear = data[0:e];
		p := e + 5;
		while(p < len data && (int data[p] == ' ' || int data[p] == '\t' || int data[p] == '\r' || int data[p] == '\n'))
			p++;
		enc = data[p:];
	}
	if(clear == nil || len enc < 4)
		return (nil, "Type 1: no font program");
	if(ishex(enc))
		enc = unhex(enc);
	priv := t1decrypt(enc, 55665, 4);

	fd := ref FaceData;
	fd.upem = 1000;
	fd.ascent = 800;
	fd.descent = -200;
	fd.fontname = t1name(clear);
	(fm, nfm) := t1nums(clear, "/FontMatrix", 6);
	if(nfm == 6 && fm[0] > 0.0)
		fd.upem = int (1.0/fm[0] + 0.5);
	(bb, nbb) := t1nums(clear, "/FontBBox", 4);
	if(nbb == 4 && bb[3] > bb[1]){
		fd.ascent = int bb[3];
		fd.descent = int bb[1];
	}

	leniv := 4;
	if((li := findbytes(priv, 0, "/lenIV")) >= 0)
		(leniv, nil) = t1int(priv, li + 6);

	# Subrs: dup i n RD <n bytes> NP
	subrs: array of array of byte;
	if((si := findbytes(priv, 0, "/Subrs")) >= 0){
		(n, p) := t1int(priv, si + 6);
		if(n > 0 && n < 65536)
			subrs = array[n] of array of byte;
		(nil, p) = t1tok(priv, p);	# array
		for(;;){
			tok: string;
			(tok, p) = t1tok(priv, p);
			if(tok == "dup"){
				i, ln: int;
				(i, p) = t1int(priv, p);
				(ln, p) = t1int(priv, p);
				(nil, p) = t1tok(priv, p);	# RD or -|
				p++;
				if(ln < 0 || p + ln > len priv)
					break;
				if(subrs != nil && i >= 0 && i < len subrs)
					subrs[i] = t1decrypt(priv[p:p+ln], 4330, leniv);
				p += ln;
			} else if(tok != "NP" && tok != "|" && tok != "noaccess" && tok != "put" && tok != "readonly")
				break;
		}
	}

	# CharStrings: /name n RD <n bytes> ND
	names: list of string;
	css: list of array of byte;
	ng := 0;
	if((ci := findbytes(priv, 0, "/CharStrings")) >= 0){
		p := findbytes(priv, ci, "begin");
		if(p >= 0)
			p += 5;
		while(p >= 0 && p < len priv){
			tok: string;
			(tok, p) = t1tok(priv, p);
			if(tok == nil || tok == "end")
				break;
			if(tok[0] != '/')
				continue;
			ln: int;
			(ln, p) = t1int(priv, p);
			(nil, p) = t1tok(priv, p);
			p++;
			if(ln < 0 || p + ln > len priv)
				break;
			names = tok[1:] :: names;
			css = t1decrypt(priv[p:p+ln], 4330, leniv) :: css;
			ng++;
			p += ln;
		}
	}
	if(ng == 0)
		return (nil, "Type 1: no CharStrings");
	# .notdef is glyph 0
	fd.names = array[ng] of string;
	fd.t1cs = array[ng] of array of byte;
	for(g := ng - 1; g >= 0; g--){
		fd.names[g] = hd names;
		fd.t1cs[g] = hd css;
		names = tl names;
		css = tl css;
	}
	for(g = 1; g < ng; g++)
		if(fd.names[g] == ".notdef"){
			(fd.names[0], fd.names[g]) = (fd.names[g], fd.names[0]);
			(fd.t1cs[0], fd.t1cs[g]) = (fd.t1cs[g], fd.t1cs[0]);
			break;
		}
	fd.t1subrs = subrs;
	fd.nglyphs = ng;

	# the built-in encoding, as codes to GIDs
	cmap := array[256] of { * => -1 };
	ei := findbytes(clear, 0, "/Encoding");
	if(ei >= 0 && (se := findbytes(clear[ei:], 0, "StandardEncoding")) >= 0 && se < 40){
		for(c := 0; c < 256; c++)
			if(stdsids[c] != 0)
				cmap[c] = fdnamedgid(fd, cffstd(stdsids[c]));
	} else if(ei >= 0){
		# dup code /name put, to the def that ends it
		p := ei + 9;
		for(;;){
			tok: string;
			(tok, p) = t1tok(clear, p);
			if(tok == nil || tok == "def" || tok == "readonly")
				break;
			if(tok != "dup")
				continue;
			c: int;
			(c, p) = t1int(clear, p);
			(tok, p) = t1tok(clear, p);
			if(c >= 0 && c < 256 && tok != nil && tok[0] == '/')
				cmap[c] = fdnamedgid(fd, tok[1:]);
		}
	}
	fd.ttfcmap = cmap;
	return (fd, nil);
}

catbytes(a, b: array of byte): array of byte
{
	if(a == nil)
		return b;
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

findbytes(d: array of byte, from: int, s: string): int
{
	n := len s;
	for(i := from; i + n <= len d; i++){
		j := 0;
		while(j < n && int d[i+j] == s[j])
			j++;
		if(j == n)
			return i;
	}
	return -1;
}

ishex(d: array of byte): int
{
	for(i := 0; i < 4; i++)
		if(hexval(int d[i]) < 0)
			return 0;
	return 1;
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

unhex(d: array of byte): array of byte
{
	o := array[len d / 2] of byte;
	n := 0;
	hi := -1;
	for(i := 0; i < len d; i++){
		c := int d[i];
		if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
			continue;
		v := hexval(c);
		if(v < 0)
			break;
		if(hi < 0)
			hi = v;
		else {
			o[n++] = byte (hi<<4 | v);
			hi = -1;
		}
	}
	return o[0:n];
}

# eexec (r 55665) and charstring (r 4330) decryption, the first skip
# bytes dropped (lenIV -1: a charstring not encrypted)
t1decrypt(d: array of byte, r, skip: int): array of byte
{
	if(skip < 0)
		return d;
	o := array[len d] of byte;
	for(i := 0; i < len d; i++){
		c := int d[i];
		o[i] = byte (c ^ (r >> 8));
		r = ((c + r) * 52845 + 22719) & 16rFFFF;
	}
	if(skip > len o)
		skip = len o;
	return o[skip:];
}

t1tok(d: array of byte, p: int): (string, int)
{
	while(p < len d && (int d[p] == ' ' || int d[p] == '\t' || int d[p] == '\r' || int d[p] == '\n'))
		p++;
	if(p >= len d)
		return (nil, p);
	s := p;
	p++;
	while(p < len d){
		c := int d[p];
		if(c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '/' || c == '[' || c == ']' || c == '{' || c == '}')
			break;
		p++;
	}
	return (string d[s:p], p);
}

t1int(d: array of byte, p: int): (int, int)
{
	(t, np) := t1tok(d, p);
	if(t == nil)
		return (-1, np);
	return (int t, np);
}

t1name(d: array of byte): string
{
	i := findbytes(d, 0, "/FontName");
	if(i < 0)
		return "Type1";
	(t, nil) := t1tok(d, i + 9);
	if(t != nil && t[0] == '/')
		return t[1:];
	return "Type1";
}

# up to n numbers in the [ ] after key
t1nums(d: array of byte, key: string, n: int): (array of real, int)
{
	v := array[n] of real;
	i := findbytes(d, 0, key);
	if(i < 0)
		return (v, 0);
	p := i + len key;
	while(p < len d && int d[p] != '[' && int d[p] != '{')
		p++;
	p++;
	k := 0;
	while(k < n){
		t: string;
		(t, p) = t1tok(d, p);
		if(t == nil || t == "]" || t == "}")
			break;
		v[k++] = real t;
	}
	return (v, k);
}

# A Type 1 charstring's outline, in font units.
T1state: adt {
	fd:	ref FaceData;
	st:	array of real;
	sp:	int;
	ps:	list of real;	# the PostScript stack callothersubr leaves
	x, y:	real;
	ox, oy:	real;	# where the outline is drawn from (an accent's place)
	width:	real;
	path:	list of ref PathSeg;
	open:	int;
	flex:	int;
	fx, fy:	real;	# where a flex begins
	flexpts:	list of (real, real);
	depth:	int;
	done:	int;
};

t1outline(fd: ref FaceData, gid: int): ref GlyphOutline
{
	if(gid < 0 || gid >= len fd.t1cs)
		return nil;
	s := t1state(fd, 0.0, 0.0);
	t1run(s, fd.t1cs[gid]);
	if(s.open)
		s.path = ref PathSeg.Close :: s.path;
	return ref GlyphOutline(s.path, int (s.width + 0.5));
}

t1state(fd: ref FaceData, ox, oy: real): ref T1state
{
	return ref T1state(fd, array[64] of real, 0, nil, 0.0, 0.0, ox, oy, 0.0,
		nil, 0, 0, 0.0, 0.0, nil, 0, 0);
}

# seac: an accented character, the base and the accent from
# StandardEncoding, the accent's side bearing (asb) put at adx, ady
t1seac(s: ref T1state, asb, adx, ady: real, bchar, achar: int)
{
	if(bchar < 0 || bchar > 255 || achar < 0 || achar > 255)
		return;
	if(s.open){
		s.path = ref PathSeg.Close :: s.path;
		s.open = 0;
	}
	fd := s.fd;
	bg := fdnamedgid(fd, cffstd(stdsids[bchar]));
	ag := fdnamedgid(fd, cffstd(stdsids[achar]));
	if(bg >= 0)
		s.path = t1sub(s, fd.t1cs[bg], s.ox, s.oy);
	if(ag >= 0)
		s.path = t1sub(s, fd.t1cs[ag], s.ox + adx - asb, s.oy + ady);
}

# a part of a glyph drawn from another's charstring, put before the path
t1sub(s: ref T1state, cs: array of byte, ox, oy: real): list of ref PathSeg
{
	sub := t1state(s.fd, ox, oy);
	sub.depth = s.depth;
	t1run(sub, cs);
	if(sub.open)
		sub.path = ref PathSeg.Close :: sub.path;
	p := s.path;
	r: list of ref PathSeg;
	for(l := sub.path; l != nil; l = tl l)
		r = hd l :: r;
	for(; r != nil; r = tl r)
		p = hd r :: p;
	return p;
}

t1abscurve(s: ref T1state, p1, p2, p3: (real, real))
{
	(x1, y1) := p1;
	(x2, y2) := p2;
	(x3, y3) := p3;
	s.path = ref PathSeg.Curve(s.ox + x1, s.oy + y1, s.ox + x2, s.oy + y2, s.ox + x3, s.oy + y3) :: s.path;
	(s.x, s.y) = (x3, y3);
}

t1move(s: ref T1state)
{
	if(s.open)
		s.path = ref PathSeg.Close :: s.path;
	s.path = ref PathSeg.Move(s.ox + s.x, s.oy + s.y) :: s.path;
	s.open = 1;
}

t1line(s: ref T1state)
{
	if(!s.open)
		t1move(s);
	s.path = ref PathSeg.Line(s.ox + s.x, s.oy + s.y) :: s.path;
}

t1curve(s: ref T1state, dx1, dy1, dx2, dy2, dx3, dy3: real)
{
	if(!s.open)
		t1move(s);
	x1 := s.x + dx1;
	y1 := s.y + dy1;
	x2 := x1 + dx2;
	y2 := y1 + dy2;
	s.x = x2 + dx3;
	s.y = y2 + dy3;
	s.path = ref PathSeg.Curve(s.ox + x1, s.oy + y1, s.ox + x2, s.oy + y2, s.ox + s.x, s.oy + s.y) :: s.path;
}

t1run(s: ref T1state, cs: array of byte)
{
	if(cs == nil || s.depth > 10)
		return;
	s.depth++;
	st := s.st;
	for(i := 0; i < len cs && !s.done; ){
		v := int cs[i++];
		if(v >= 32){
			n: int;
			if(v <= 246)
				n = v - 139;
			else if(v <= 250){
				if(i >= len cs) break;
				n = (v - 247)*256 + int cs[i++] + 108;
			} else if(v <= 254){
				if(i >= len cs) break;
				n = -(v - 251)*256 - int cs[i++] - 108;
			} else {
				if(i + 4 > len cs) break;
				n = (int cs[i]<<24) | (int cs[i+1]<<16) | (int cs[i+2]<<8) | int cs[i+3];
				i += 4;
			}
			if(s.sp < len st)
				st[s.sp++] = real n;
			continue;
		}
		sp := s.sp;
		case v {
		1 or 3 =>	# hstem vstem
			;
		4 =>	# vmoveto
			if(sp >= 1){
				s.y += st[sp-1];
				t1moved(s);
			}
		5 =>	# rlineto
			if(sp >= 2){
				s.x += st[0];
				s.y += st[1];
				t1line(s);
			}
		6 =>	# hlineto
			if(sp >= 1){
				s.x += st[0];
				t1line(s);
			}
		7 =>	# vlineto
			if(sp >= 1){
				s.y += st[0];
				t1line(s);
			}
		8 =>	# rrcurveto
			if(sp >= 6)
				t1curve(s, st[0], st[1], st[2], st[3], st[4], st[5]);
		9 =>	# closepath
			if(s.open){
				s.path = ref PathSeg.Close :: s.path;
				s.open = 0;
			}
		10 =>	# callsubr
			if(sp >= 1){
				n := int st[sp-1];
				s.sp = sp - 1;
				if(s.fd.t1subrs != nil && n >= 0 && n < len s.fd.t1subrs)
					t1run(s, s.fd.t1subrs[n]);
				continue;
			}
		11 =>	# return
			s.depth--;
			return;
		12 =>
			if(i >= len cs) break;
			e := int cs[i++];
			case e {
			6 =>	# seac asb adx ady bchar achar
				if(sp >= 5){
					t1seac(s, st[0], st[1], st[2], int st[3], int st[4]);
					s.done = 1;
				}
			7 =>	# sbw sbx sby wx wy
				if(sp >= 4){
					s.x = st[0];
					s.y = st[1];
					s.width = st[2];
				}
			12 =>	# div
				if(sp >= 2){
					if(st[sp-1] != 0.0)
						st[sp-2] = st[sp-2] / st[sp-1];
					s.sp = sp - 1;
					continue;
				}
			16 =>	# callothersubr: args... n othersubr#
				if(sp >= 2){
					oth := int st[sp-1];
					n := int st[sp-2];
					sp -= 2;
					if(n < 0 || n > sp)
						n = sp;
					args := st[sp-n:sp];
					s.sp = sp - n;
					t1othersubr(s, oth, args);
					continue;
				}
			17 =>	# pop
				if(s.ps != nil){
					if(s.sp < len st)
						st[s.sp++] = hd s.ps;
					s.ps = tl s.ps;
				}
				continue;
			33 =>	# setcurrentpoint
				if(sp >= 2){
					s.x = st[0];
					s.y = st[1];
				}
			}
		13 =>	# hsbw sbx wx
			if(sp >= 2){
				s.x = st[0];
				s.y = 0.0;
				s.width = st[1];
			}
		14 =>	# endchar
			s.done = 1;
		21 =>	# rmoveto
			if(sp >= 2){
				s.x += st[sp-2];
				s.y += st[sp-1];
				t1moved(s);
			}
		22 =>	# hmoveto
			if(sp >= 1){
				s.x += st[sp-1];
				t1moved(s);
			}
		30 =>	# vhcurveto dy1 dx2 dy2 dx3
			if(sp >= 4)
				t1curve(s, 0.0, st[0], st[1], st[2], st[3], 0.0);
		31 =>	# hvcurveto dx1 dx2 dy2 dy3
			if(sp >= 4)
				t1curve(s, st[0], 0.0, st[1], st[2], 0.0, st[3]);
		}
		s.sp = 0;
	}
	s.depth--;
}

# a moveto: during a flex only the point is noted
t1moved(s: ref T1state)
{
	if(s.flex)
		return;
	t1move(s);
}

t1othersubr(s: ref T1state, oth: int, args: array of real)
{
	case oth {
	0 =>	# end of flex: from where it began, the two curves through
		# the six points after the reference point
		pts := array[7] of (real, real);
		n := 0;
		for(l := s.flexpts; l != nil; l = tl l)
			n++;
		s.flex = 0;
		if(n == 7){
			l = s.flexpts;
			for(k := 6; k >= 0; k--){
				pts[k] = hd l;
				l = tl l;
			}
			(s.x, s.y) = (s.fx, s.fy);
			if(!s.open)
				t1move(s);
			t1abscurve(s, pts[1], pts[2], pts[3]);
			t1abscurve(s, pts[4], pts[5], pts[6]);
		}
		s.flexpts = nil;
		# for the pop pop setcurrentpoint that follows
		s.ps = s.x :: s.y :: nil;
	1 =>	# start of flex
		s.flex = 1;
		s.flexpts = nil;
		s.fx = s.x;
		s.fy = s.y;
	2 =>	# a flex point
		s.flexpts = (s.x, s.y) :: s.flexpts;
	3 =>	# hint replacement: the subroutine number back, to be called
		s.ps = nil;
		if(len args >= 1)
			s.ps = args[0] :: nil;
	* =>
		s.ps = nil;
		for(k := 0; k < len args; k++)
			s.ps = args[k] :: s.ps;
	}
}

# ---- CFF parser ----

parsecff(data: array of byte): (ref FaceData, string)
{
	if(len data < 4)
		return (nil, "too short for CFF");

	# CFF header
	major := int data[0];
	# minor := int data[1];
	hdrsize := int data[2];
	if(major != 1)
		return (nil, sys->sprint("unsupported CFF version %d", major));

	pos := hdrsize;

	# Name INDEX
	(nameidx, np1, nerr) := parseindex(data, pos);
	if(nerr != nil)
		return (nil, "Name INDEX: " + nerr);
	pos = np1;

	fontname := "";
	if(nameidx.count > 0 && nameidx.data[0] != nil)
		fontname = string nameidx.data[0];

	# Top DICT INDEX
	(tdidx, np2, terr) := parseindex(data, pos);
	if(terr != nil)
		return (nil, "Top DICT INDEX: " + terr);
	pos = np2;

	if(tdidx.count < 1)
		return (nil, "no Top DICT");

	# Parse Top DICT
	td := parsetopdict(tdidx.data[0]);
	td.fontname = fontname;

	# String INDEX: the glyph names beyond the standard strings
	(strings, np3, serr) := parseindex(data, pos);
	if(serr != nil)
		return (nil, "String INDEX: " + serr);
	pos = np3;

	# Global Subr INDEX
	(gsubrs, np4, gerr) := parseindex(data, pos);
	if(gerr != nil)
		return (nil, "Global Subr INDEX: " + gerr);

	# suppress unused warning
	if(np4 < 0) np4 = np4;

	# Parse CharStrings INDEX
	if(td.charstrings_off <= 0 || td.charstrings_off >= len data)
		return (nil, "bad CharStrings offset");
	(csidx, nil, cerr) := parseindex(data, td.charstrings_off);
	if(cerr != nil)
		return (nil, "CharStrings INDEX: " + cerr);

	nglyphs := csidx.count;

	# Parse charset (GID -> SID/CID mapping)
	cidmap: array of int;
	if(td.ros && td.charset_off > 0 && td.charset_off < len data)
		cidmap = parsecharset(data, td.charset_off, nglyphs);

	# Parse Private DICT
	privd: ref CffPrivateDict;
	lsubrs: ref CffIndex;
	if(td.private_size > 0 && td.private_off > 0 && td.private_off + td.private_size <= len data){
		pdata := data[td.private_off:td.private_off + td.private_size];
		privd = parseprivatedict(pdata);
		# Local subrs
		if(privd.subrs_off > 0){
			lsoff := td.private_off + privd.subrs_off;
			if(lsoff < len data){
				(ls, nil, lerr) := parseindex(data, lsoff);
				if(lerr == nil)
					lsubrs = ls;
			}
		}
	}

	# CID font handling
	iscid := td.ros;
	fdcount := 0;
	fdprivate: array of ref CffPrivateDict;
	fdlsubrs: array of ref CffIndex;
	fdsel: array of byte;

	if(iscid){
		# FDArray
		if(td.fdarray_off > 0 && td.fdarray_off < len data){
			(fdaidx, nil, faerr) := parseindex(data, td.fdarray_off);
			if(faerr == nil && fdaidx.count > 0){
				fdcount = fdaidx.count;
				fdprivate = array[fdcount] of ref CffPrivateDict;
				fdlsubrs = array[fdcount] of ref CffIndex;
				for(i := 0; i < fdcount; i++){
					fdict := parsetopdict(fdaidx.data[i]);
					if(fdict.private_size > 0 && fdict.private_off > 0 &&
					   fdict.private_off + fdict.private_size <= len data){
						fpdata := data[fdict.private_off:fdict.private_off + fdict.private_size];
						fdprivate[i] = parseprivatedict(fpdata);
						if(fdprivate[i].subrs_off > 0){
							flsoff := fdict.private_off + fdprivate[i].subrs_off;
							if(flsoff < len data){
								(fls, nil, flerr) := parseindex(data, flsoff);
								if(flerr == nil)
									fdlsubrs[i] = fls;
							}
						}
					}
				}
			}
		}

		# FDSelect
		if(td.fdselect_off > 0 && td.fdselect_off < len data){
			fdsel = parsefdselect(data, td.fdselect_off, nglyphs);
		}
	}

	# For non-CID CFF fonts, build charcode→GID mapping from CFF encoding
	cffcmap: array of int;
	sids: array of int;
	if(!iscid){
		# Parse charset SIDs for use with encoding builder
		if(td.charset_off > 2 && td.charset_off < len data)
			sids = parsecharset_sids(data, td.charset_off, nglyphs);
		else if(td.charset_off == 0){
			# ISOAdobe: GID n is SID n
			sids = array[nglyphs] of int;
			for(i := 0; i < nglyphs; i++)
				sids[i] = i;
		}

		cffcmap = parsecffencoding(data, td.encoding_off, nglyphs, sids);
	}

	# Default metrics
	upem := 1000;
	ascent := td.ascent;
	descent := td.descent;
	if(ascent == 0) ascent = 800;
	if(descent == 0) descent = -200;

	fd := ref FaceData(
		data,
		nglyphs,
		upem,
		ascent,
		descent,
		fontname,
		csidx,
		gsubrs,
		privd,
		lsubrs,
		iscid,
		fdcount,
		fdprivate,
		fdlsubrs,
		fdsel,
		cidmap,
		0, nil, 0, 0, nil, cffcmap, nil,	# ttfcmap = cffcmap for charcode→GID
		0, 0,
		nil, nil,		# gsub, gpos
		nil, 0, 0, nil, nil,	# no variations
		sids, strings, nil, nil,
		nil, nil
	);

	return (fd, nil);
}

# Parse a CFF INDEX structure
parseindex(data: array of byte, offset: int): (ref CffIndex, int, string)
{
	pos := offset;
	if(pos + 2 > len data)
		return (nil, 0, "truncated INDEX count");

	count := (int data[pos] << 8) | int data[pos+1];
	pos += 2;

	if(count == 0)
		return (ref CffIndex(0, nil), pos, nil);

	if(pos >= len data)
		return (nil, 0, "truncated INDEX offSize");
	offsize := int data[pos];
	pos++;

	if(offsize < 1 || offsize > 4)
		return (nil, 0, sys->sprint("bad INDEX offSize %d", offsize));

	# Read offset array (count+1 entries)
	offsets := array[count + 1] of int;
	for(i := 0; i <= count; i++){
		if(pos + offsize > len data)
			return (nil, 0, "truncated INDEX offsets");
		v := 0;
		for(j := 0; j < offsize; j++)
			v = (v << 8) | int data[pos + j];
		offsets[i] = v;
		pos += offsize;
	}

	# Data starts at current pos, offsets are 1-based
	datastart := pos - 1;	# offsets are 1-based in CFF
	endpos := datastart + offsets[count];

	items := array[count] of array of byte;
	for(i = 0; i < count; i++){
		start := datastart + offsets[i];
		end := datastart + offsets[i + 1];
		if(start < 0 || end > len data || start > end){
			items[i] = nil;
			continue;
		}
		item := array[end - start] of byte;
		item[0:] = data[start:end];
		items[i] = item;
	}

	return (ref CffIndex(count, items), endpos, nil);
}

# Parse CFF Top DICT
parsetopdict(data: array of byte): ref CffTopDict
{
	td := ref CffTopDict(0, 0, 0, 0, 0, 0, 0, 0, "", 0, 0);
	if(data == nil || len data == 0)
		return td;

	operands: list of int;
	pos := 0;

	while(pos < len data){
		b0 := int data[pos];

		# Number: bytes 28-30 and 32-254 are number encodings in CFF DICT
		if(b0 >= 28 && b0 != 31){
			(val, np) := dictreadnum(data, pos);
			operands = val :: operands;
			pos = np;
			continue;
		}

		# Operator: bytes 0-27 and 31
		pos++;
		if(b0 == 12){
			if(pos >= len data) break;
			b1 := int data[pos]; pos++;
			op := 3000 + b1;
			case op {
			3030 =>	# ROS (12 30) — CIDFont
				td.ros = 1;
			3036 =>	# FDArray (12 36)
				td.fdarray_off = popint(operands);
			3037 =>	# FDSelect (12 37)
				td.fdselect_off = popint(operands);
			}
			operands = nil;
			continue;
		}

		case b0 {
		15 =>	# charset
			td.charset_off = popint(operands);
		16 =>	# Encoding
			td.encoding_off = popint(operands);
		17 =>	# CharStrings
			td.charstrings_off = popint(operands);
		18 =>	# Private (size, offset)
			if(operands != nil){
				td.private_off = hd operands;
				operands = tl operands;
			}
			if(operands != nil){
				td.private_size = hd operands;
				operands = tl operands;
			}
		}
		operands = nil;
	}

	return td;
}

# Parse CFF Private DICT
parseprivatedict(data: array of byte): ref CffPrivateDict
{
	pd := ref CffPrivateDict(0, 0, 0);
	if(data == nil || len data == 0)
		return pd;

	operands: list of int;
	pos := 0;

	while(pos < len data){
		b0 := int data[pos];

		# Number: bytes 28-30 and 32-254 are number encodings in CFF DICT
		if(b0 >= 28 && b0 != 31){
			(val, np) := dictreadnum(data, pos);
			operands = val :: operands;
			pos = np;
			continue;
		}

		pos++;
		if(b0 == 12){
			if(pos >= len data) break;
			pos++;	# skip 2nd byte
			operands = nil;
			continue;
		}

		case b0 {
		19 =>	# Subrs
			pd.subrs_off = popint(operands);
		20 =>	# defaultWidthX
			pd.defaultw = popint(operands);
		21 =>	# nominalWidthX
			pd.nominalw = popint(operands);
		}
		operands = nil;
	}

	return pd;
}

# Read a DICT number (integer or real encoded as integer)
dictreadnum(data: array of byte, pos: int): (int, int)
{
	if(pos >= len data)
		return (0, pos);

	b0 := int data[pos];
	pos++;

	if(b0 == 28){
		if(pos + 1 >= len data)
			return (0, pos);
		v := (int data[pos] << 8) | int data[pos+1];
		if(v & 16r8000) v -= 16r10000;
		return (v, pos + 2);
	}
	if(b0 == 29){
		if(pos + 3 >= len data)
			return (0, pos);
		v := (int data[pos] << 24) | (int data[pos+1] << 16) |
		     (int data[pos+2] << 8) | int data[pos+3];
		return (v, pos + 4);
	}
	if(b0 == 30){
		# Real number — skip nibbles until end sentinel
		while(pos < len data){
			b := int data[pos];
			pos++;
			n1 := (b >> 4) & 16rF;
			n2 := b & 16rF;
			if(n1 == 16rF || n2 == 16rF)
				break;
		}
		return (0, pos);	# return 0 for reals (we only need ints)
	}
	if(b0 >= 32 && b0 <= 246)
		return (b0 - 139, pos);
	if(b0 >= 247 && b0 <= 250){
		if(pos >= len data)
			return (0, pos);
		b1 := int data[pos]; pos++;
		return ((b0 - 247) * 256 + b1 + 108, pos);
	}
	if(b0 >= 251 && b0 <= 254){
		if(pos >= len data)
			return (0, pos);
		b1 := int data[pos]; pos++;
		return (-(b0 - 251) * 256 - b1 - 108, pos);
	}
	return (0, pos);
}

popint(operands: list of int): int
{
	if(operands == nil)
		return 0;
	return hd operands;
}

# Parse FDSelect (format 0 and 3)
parsefdselect(data: array of byte, offset, nglyphs: int): array of byte
{
	fdsel := array[nglyphs] of { * => byte 0 };
	if(offset >= len data)
		return fdsel;

	fmt := int data[offset];
	pos := offset + 1;

	case fmt {
	0 =>
		# Format 0: one byte per glyph
		for(i := 0; i < nglyphs && pos < len data; i++){
			fdsel[i] = data[pos];
			pos++;
		}
	3 =>
		# Format 3: ranges
		if(pos + 1 >= len data)
			return fdsel;
		nranges := (int data[pos] << 8) | int data[pos+1];
		pos += 2;
		for(i := 0; i < nranges; i++){
			if(pos + 2 >= len data) break;
			first := (int data[pos] << 8) | int data[pos+1];
			fd := int data[pos + 2];
			pos += 3;
			# Next range start (or sentinel)
			nextfirst := nglyphs;
			if(i + 1 < nranges && pos + 1 < len data)
				nextfirst = (int data[pos] << 8) | int data[pos+1];
			for(g := first; g < nextfirst && g < nglyphs; g++)
				fdsel[g] = byte fd;
		}
	}

	return fdsel;
}

# Parse CFF Encoding table and build charcode -> GID lookup.
# For non-CID CFF fonts, the encoding maps character codes (0-255) to GIDs.
# encoding_off: 0 = Standard Encoding, 1 = Expert Encoding, >1 = custom offset.
# charset: GID -> SID mapping from parsecharset_sids(), used for Standard Encoding.
parsecffencoding(data: array of byte, encoding_off, nglyphs: int,
	charset: array of int): array of int
{
	if(encoding_off <= 1){
		# Standard or Expert encoding — use charset SIDs to infer charcode mapping
		if(charset == nil)
			return nil;
		# For Standard Encoding, SIDs map to standard glyph names with known charcodes.
		# Build charcode -> GID from SID -> charcode for common glyphs.
		cmap := array[256] of { * => -1 };
		for(gid := 1; gid < nglyphs && gid < len charset; gid++){
			sid := charset[gid];
			cc := sidtocharcode(sid);
			if(cc >= 0 && cc < 256)
				cmap[cc] = gid;
		}
		return cmap;
	}

	# Custom encoding at offset
	if(encoding_off >= len data)
		return nil;

	fmt := int data[encoding_off] & 16r7F;	# high bit = supplement flag
	cmap := array[256] of { * => -1 };

	case fmt {
	0 =>
		# Format 0: nCodes followed by code bytes (code[i] = charcode for GID i+1)
		if(encoding_off + 1 >= len data)
			return nil;
		ncodes := int data[encoding_off + 1];
		for(i := 0; i < ncodes; i++){
			if(encoding_off + 2 + i >= len data)
				break;
			code := int data[encoding_off + 2 + i];
			gid := i + 1;
			if(gid < nglyphs && code < 256)
				cmap[code] = gid;
		}
	1 =>
		# Format 1: nRanges of (first, nLeft) for sequential GIDs
		if(encoding_off + 1 >= len data)
			return nil;
		nranges := int data[encoding_off + 1];
		gid := 1;
		for(i := 0; i < nranges; i++){
			roff := encoding_off + 2 + i * 2;
			if(roff + 1 >= len data)
				break;
			first := int data[roff];
			nleft := int data[roff + 1];
			for(j := 0; j <= nleft; j++){
				code := first + j;
				if(gid < nglyphs && code < 256)
					cmap[code] = gid;
				gid++;
			}
		}
	* =>
		return nil;
	}

	return cmap;
}

# Map CFF Standard SID to ASCII character code for common glyphs.
# SIDs 0-390 are standard strings defined in CFF spec Appendix A.
# SIDs 1-95 map linearly to ASCII 32-126:
#   SID 1=space(32), SID 34=A(65), SID 54=U(85), SID 66=a(97), SID 95=tilde(126)
sidtocharcode(sid: int): int
{
	if(sid >= 1 && sid <= 95)
		return sid + 31;
	return -1;
}

# Build GID->SID array from charset (for use with encoding builder).
# Unlike parsecharset() which builds CID->GID reverse map, this returns
# the forward GID->SID mapping.
parsecharset_sids(data: array of byte, offset, nglyphs: int): array of int
{
	if(offset >= len data)
		return nil;

	sids := array[nglyphs] of { * => 0 };
	fmt := int data[offset];
	pos := offset + 1;

	case fmt {
	0 =>
		for(gid := 1; gid < nglyphs; gid++){
			if(pos + 1 >= len data) break;
			sids[gid] = (int data[pos] << 8) | int data[pos+1];
			pos += 2;
		}
	1 =>
		gid := 1;
		while(gid < nglyphs && pos + 2 < len data){
			first := (int data[pos] << 8) | int data[pos+1];
			nleft := int data[pos+2];
			pos += 3;
			for(j := 0; j <= nleft && gid < nglyphs; j++){
				sids[gid] = first + j;
				gid++;
			}
		}
	2 =>
		gid := 1;
		while(gid < nglyphs && pos + 3 < len data){
			first := (int data[pos] << 8) | int data[pos+1];
			nleft := (int data[pos+2] << 8) | int data[pos+3];
			pos += 4;
			for(j := 0; j <= nleft && gid < nglyphs; j++){
				sids[gid] = first + j;
				gid++;
			}
		}
	* =>
		return nil;
	}

	return sids;
}

# Parse CFF charset table and build a CID->GID reverse map.
# For CID-keyed fonts, the charset maps GID -> CID.
# We invert it to CID -> GID for efficient lookup during rendering.
parsecharset(data: array of byte, offset, nglyphs: int): array of int
{
	if(offset >= len data)
		return nil;

	# Build GID -> CID array first
	gidtocid := array[nglyphs] of { * => 0 };
	# GID 0 is always .notdef (CID 0)
	maxcid := 0;

	fmt := int data[offset];
	pos := offset + 1;

	case fmt {
	0 =>
		# Format 0: one 2-byte SID/CID per glyph (starting at GID 1)
		for(gid := 1; gid < nglyphs; gid++){
			if(pos + 1 >= len data) break;
			cid := (int data[pos] << 8) | int data[pos+1];
			pos += 2;
			gidtocid[gid] = cid;
			if(cid > maxcid) maxcid = cid;
		}
	1 =>
		# Format 1: ranges with 1-byte count
		gid := 1;
		while(gid < nglyphs && pos + 2 < len data){
			first := (int data[pos] << 8) | int data[pos+1];
			nleft := int data[pos+2];
			pos += 3;
			for(j := 0; j <= nleft && gid < nglyphs; j++){
				cid := first + j;
				gidtocid[gid] = cid;
				if(cid > maxcid) maxcid = cid;
				gid++;
			}
		}
	2 =>
		# Format 2: ranges with 2-byte count
		gid := 1;
		while(gid < nglyphs && pos + 3 < len data){
			first := (int data[pos] << 8) | int data[pos+1];
			nleft := (int data[pos+2] << 8) | int data[pos+3];
			pos += 4;
			for(j := 0; j <= nleft && gid < nglyphs; j++){
				cid := first + j;
				gidtocid[gid] = cid;
				if(cid > maxcid) maxcid = cid;
				gid++;
			}
		}
	* =>
		return nil;	# unknown format
	}

	# Build reverse map: CID -> GID
	cidmap := array[maxcid + 1] of { * => -1 };
	cidmap[0] = 0;	# .notdef
	for(gid := 1; gid < nglyphs; gid++){
		cid := gidtocid[gid];
		if(cid >= 0 && cid <= maxcid)
			cidmap[cid] = gid;
	}

	return cidmap;
}

# ---- TrueType / OpenType sfnt parsing ----

getu16be(data: array of byte, off: int): int
{
	return (int data[off] << 8) | int data[off+1];
}

geti16be(data: array of byte, off: int): int
{
	v := (int data[off] << 8) | int data[off+1];
	if(v >= 16r8000)
		v -= 16r10000;
	return v;
}

geti8(data: array of byte, off: int): int
{
	v := int data[off];
	if(v >= 16r80)
		v -= 16r100;
	return v;
}

getu32be(data: array of byte, off: int): int
{
	return (int data[off] << 24) | (int data[off+1] << 16) |
		(int data[off+2] << 8) | int data[off+3];
}

getf2dot14(data: array of byte, off: int): real
{
	v := geti16be(data, off);
	return real v / 16384.0;
}

# Parse TrueType sfnt font data
parsettf(data: array of byte): (ref FaceData, string)
{
	if(len data >= 12 && string data[0:4] == "OTTO")
		return parseotf(data);
	if(len data < 12)
		return (nil, "data too small for sfnt");

	numtables := getu16be(data, 4);
	if(numtables < 1 || numtables > 256)
		return (nil, "bad sfnt table count");

	# Parse table directory
	glyfoff := 0; glyflen := 0;
	locaoff := 0;
	headoff := 0;
	maxpoff := 0;
	cmapoff := 0; cmaplen := 0;
	hheaoff := 0;
	hmtxoff := 0;
	kernoff := 0;
	gsuboff := 0;
	gposoff := 0;
	nameoff := 0;
	fvaroff := 0;
	avaroff := 0;
	gvaroff := 0;

	for(i := 0; i < numtables; i++){
		toff := 12 + i * 16;
		if(toff + 16 > len data)
			break;
		tag := string data[toff:toff+4];
		tableoff := getu32be(data, toff + 8);
		tablelen := getu32be(data, toff + 12);
		case tag {
		"glyf" =>
			glyfoff = tableoff; glyflen = tablelen;
		"loca" =>
			locaoff = tableoff;
		"head" =>
			headoff = tableoff;
		"maxp" =>
			maxpoff = tableoff;
		"cmap" =>
			cmapoff = tableoff; cmaplen = tablelen;
		"hhea" =>
			hheaoff = tableoff;
		"hmtx" =>
			hmtxoff = tableoff;
		"name" =>
			nameoff = tableoff;
		"kern" =>
			kernoff = tableoff;
		"GSUB" =>
			gsuboff = tableoff;
		"GPOS" =>
			gposoff = tableoff;
		"fvar" =>
			fvaroff = tableoff;
		"avar" =>
			avaroff = tableoff;
		"gvar" =>
			gvaroff = tableoff;
		}
	}

	if(glyfoff == 0 || locaoff == 0 || headoff == 0 || maxpoff == 0)
		return (nil, "missing required TrueType tables");

	# Parse head table
	if(headoff + 54 > len data)
		return (nil, "head table truncated");
	upem := getu16be(data, headoff + 18);
	if(upem == 0) upem = 1000;
	indexToLocFormat := geti16be(data, headoff + 50);
	if(indexToLocFormat != 0 && indexToLocFormat != 1)
		indexToLocFormat = 1;	# default to long format for safety

	# Parse maxp table
	if(maxpoff + 6 > len data)
		return (nil, "maxp table truncated");
	nglyphs := getu16be(data, maxpoff + 4);
	if(nglyphs == 0)
		return (nil, "no glyphs");

	# Parse hhea for metrics
	numhmetrics := 0;
	ascent := 0;
	descent := 0;
	if(hheaoff != 0 && hheaoff + 36 <= len data){
		ascent = geti16be(data, hheaoff + 4);
		descent = geti16be(data, hheaoff + 6);
		numhmetrics = getu16be(data, hheaoff + 34);
	}
	if(ascent == 0) ascent = int (real upem * 0.8);
	if(descent == 0) descent = -int (real upem * 0.2);

	# Parse loca table
	locaoffs := array[nglyphs + 1] of { * => 0 };
	if(indexToLocFormat == 0){
		# Short format: uint16 offsets * 2
		for(i = 0; i <= nglyphs && locaoff + i*2 + 1 < len data; i++)
			locaoffs[i] = getu16be(data, locaoff + i*2) * 2;
	} else {
		# Long format: uint32 offsets
		for(i = 0; i <= nglyphs && locaoff + i*4 + 3 < len data; i++)
			locaoffs[i] = getu32be(data, locaoff + i*4);
	}

	# Parse hmtx table (advance widths)
	ttfwidths := array[nglyphs] of { * => 0 };
	lastwidth := 0;
	if(hmtxoff != 0){
		for(i = 0; i < numhmetrics && i < nglyphs && hmtxoff + i*4 + 1 < len data; i++){
			ttfwidths[i] = getu16be(data, hmtxoff + i*4);
			lastwidth = ttfwidths[i];
		}
		for(i = numhmetrics; i < nglyphs; i++)
			ttfwidths[i] = lastwidth;
	}

	# Parse cmap table
	ttfcmap: array of int;
	if(cmapoff != 0 && cmaplen > 0)
		ttfcmap = parsettfcmap(data, cmapoff, cmaplen);

	# 'kern' (version 0): the first horizontal format 0 subtable
	kernpairs := 0;
	nkern := 0;
	if(kernoff != 0 && kernoff + 4 <= len data && getu16be(data, kernoff) == 0) {
		nt := getu16be(data, kernoff + 2);
		st := kernoff + 4;
		for(i = 0; i < nt && st + 14 <= len data; i++) {
			slen := getu16be(data, st + 2);
			cov := getu16be(data, st + 4);
			# format 0, horizontal, not minimum or cross-stream
			if((cov >> 8) == 0 && (cov & 16r7) == 1) {
				n := getu16be(data, st + 6);
				if(st + 14 + n*6 <= len data) {
					kernpairs = st + 14;
					nkern = n;
				}
				break;
			}
			if(slen <= 0)
				break;
			st += slen;
		}
	}

	# Get font name
	fontname := "TrueType";
	if(nameoff != 0)
		fontname = parsettfname(data, nameoff);

	fd := ref FaceData(
		nil,			# cffdata
		nglyphs,
		upem,
		ascent,
		descent,
		fontname,
		nil,			# charstrings
		nil,			# gsubrs
		nil,			# privdict
		nil,			# lsubrs
		0,			# iscid
		0,			# fdcount
		nil,			# fdprivate
		nil,			# fdlsubrs
		nil,			# fdselect
		nil,			# cidmap
		1,			# isttf
		data,			# ttfdata
		glyfoff,
		glyflen,
		locaoffs,
		ttfcmap,
		ttfwidths,
		kernpairs,
		nkern,
		parsegsub(data, gsuboff, 7),
		parsegsub(data, gposoff, 9),
		parsefvar(data, fvaroff),
		avaroff,
		gvaroff,
		nil,
		nil,
		nil, nil, nil, nil,	# no glyph names
		nil, nil
	);

	return (fd, nil);
}

# OpenType with CFF outlines: the glyphs from the 'CFF ' table, the
# character mapping and vertical metrics from the sfnt's own tables
parseotf(data: array of byte): (ref FaceData, string)
{
	ntab := getu16be(data, 4);
	cffoff, cfflen, cmapoff, cmaplen, headoff, hheaoff, gsuboff, gposoff: int;
	cffoff = cfflen = cmapoff = cmaplen = headoff = hheaoff = gsuboff = gposoff = 0;
	for(i := 0; i < ntab; i++) {
		e := 12 + i*16;
		if(e + 16 > len data)
			break;
		off := getu32be(data, e + 8);
		ln := getu32be(data, e + 12);
		if(off < 0 || ln < 0 || off + ln > len data)
			continue;
		case string data[e:e+4] {
		"CFF " =>	(cffoff, cfflen) = (off, ln);
		"cmap" =>	(cmapoff, cmaplen) = (off, ln);
		"head" =>	headoff = off;
		"hhea" =>	hheaoff = off;
		"GSUB" =>	gsuboff = off;
		"GPOS" =>	gposoff = off;
		}
	}
	if(cfflen == 0)
		return (nil, "OpenType font without CFF outlines (CFF2 is not supported)");
	(fd, err) := parsecff(data[cffoff:cffoff + cfflen]);
	if(fd == nil)
		return (nil, err);
	fd.gsub = parsegsub(data, gsuboff, 7);
	fd.gpos = parsegsub(data, gposoff, 9);
	if(cmaplen > 0)
		fd.ttfcmap = parsettfcmap(data, cmapoff, cmaplen);
	if(headoff != 0 && hheaoff != 0 && hheaoff + 8 <= len data) {
		upem := getu16be(data, headoff + 18);
		if(upem > 0) {
			# head's units are the outlines' (an OpenType CFF's FontMatrix
			# is 1/unitsPerEm), not the 1000 a bare CFF program assumes
			fd.upem = upem;
			fd.ascent = geti16be(data, hheaoff + 4);
			fd.descent = geti16be(data, hheaoff + 6);
		}
	}
	return (fd, nil);
}

# Parse cmap table — build charcode → GID lookup
parsettfcmap(data: array of byte, cmapoff, cmaplen: int): array of int
{
	if(cmapoff + 4 > len data)
		return nil;

	numsubtables := getu16be(data, cmapoff + 2);

	# Find best subtable
	bestoff := 0;
	bestprio := 0;
	for(i := 0; i < numsubtables; i++){
		recoff := cmapoff + 4 + i * 8;
		if(recoff + 8 > len data)
			break;
		platformID := getu16be(data, recoff);
		encodingID := getu16be(data, recoff + 2);
		subtableoff := getu32be(data, recoff + 4);
		prio := 0;
		if(platformID == 3 && encodingID == 1) prio = 4;
		else if(platformID == 0) prio = 3;
		else if(platformID == 1 && encodingID == 0) prio = 2;
		else prio = 1;
		if(prio > bestprio){
			bestprio = prio;
			bestoff = cmapoff + subtableoff;
		}
	}

	if(bestoff == 0 || bestoff + 2 > len data)
		return nil;

	format := getu16be(data, bestoff);
	case format {
	0 =>
		return parsecmapfmt0(data, bestoff);
	4 =>
		return parsecmapfmt4(data, bestoff);
	6 =>
		return parsecmapfmt6(data, bestoff);
	* =>
		return nil;
	}
}

# cmap format 0: byte encoding table (256 entries)
parsecmapfmt0(data: array of byte, off: int): array of int
{
	if(off + 262 > len data)
		return nil;
	cmap := array[256] of { * => -1 };
	for(i := 0; i < 256; i++)
		cmap[i] = int data[off + 6 + i];
	return cmap;
}

# cmap format 4: segment mapping
parsecmapfmt4(data: array of byte, off: int): array of int
{
	if(off + 14 > len data)
		return nil;
	segCountX2 := getu16be(data, off + 6);
	segCount := segCountX2 / 2;
	if(segCount == 0 || off + 14 + segCount * 8 > len data)
		return nil;

	endCodeOff := off + 14;
	startCodeOff := endCodeOff + segCount*2 + 2;	# +2 for reservedPad
	idDeltaOff := startCodeOff + segCount*2;
	idRangeOff := idDeltaOff + segCount*2;

	# Determine max code for array sizing
	maxcode := 0;
	for(i := 0; i < segCount; i++){
		ec := getu16be(data, endCodeOff + i*2);
		if(ec > maxcode && ec < 16rFFFF)
			maxcode = ec;
	}
	if(maxcode == 0) maxcode = 255;
	cmapsize := maxcode + 1;
	if(cmapsize > 65536) cmapsize = 65536;

	cmap := array[cmapsize] of { * => -1 };
	for(i = 0; i < segCount; i++){
		startCode := getu16be(data, startCodeOff + i*2);
		endCode := getu16be(data, endCodeOff + i*2);
		idDelta := geti16be(data, idDeltaOff + i*2);
		idRangeOffset := getu16be(data, idRangeOff + i*2);

		if(startCode == 16rFFFF)
			break;

		for(c := startCode; c <= endCode && c < cmapsize; c++){
			gid := 0;
			if(idRangeOffset == 0){
				gid = (c + idDelta) & 16rFFFF;
			} else {
				gidoff := idRangeOff + i*2 + idRangeOffset + (c - startCode)*2;
				if(gidoff + 1 < len data){
					gid = getu16be(data, gidoff);
					if(gid != 0)
						gid = (gid + idDelta) & 16rFFFF;
				}
			}
			if(gid > 0)
				cmap[c] = gid;
		}
	}
	return cmap;
}

# cmap format 6: trimmed table mapping
parsecmapfmt6(data: array of byte, off: int): array of int
{
	if(off + 10 > len data)
		return nil;
	firstCode := getu16be(data, off + 6);
	entryCount := getu16be(data, off + 8);
	if(off + 10 + entryCount*2 > len data)
		return nil;

	cmapsize := firstCode + entryCount;
	if(cmapsize > 65536) cmapsize = 65536;
	cmap := array[cmapsize] of { * => -1 };
	for(i := 0; i < entryCount && firstCode + i < cmapsize; i++)
		cmap[firstCode + i] = getu16be(data, off + 10 + i*2);
	return cmap;
}

# Parse TrueType name table for font name
parsettfname(data: array of byte, nameoff: int): string
{
	if(nameoff + 6 > len data)
		return "TrueType";
	count := getu16be(data, nameoff + 2);
	stringoff := nameoff + getu16be(data, nameoff + 4);

	# Look for name ID 4 (Full Name) then 1 (Family Name)
	for(pass := 0; pass < 2; pass++){
		target := 4;
		if(pass == 1) target = 1;
		for(i := 0; i < count; i++){
			recoff := nameoff + 6 + i * 12;
			if(recoff + 12 > len data)
				break;
			platformID := getu16be(data, recoff);
			nameID := getu16be(data, recoff + 6);
			slen := getu16be(data, recoff + 8);
			soff := getu16be(data, recoff + 10);
			if(nameID != target)
				continue;
			noff := stringoff + soff;
			if(noff + slen > len data)
				continue;
			if(platformID == 1){
				# Mac Roman: single-byte
				s := "";
				for(j := 0; j < slen; j++)
					s[len s] = int data[noff + j];
				return s;
			}
			if(platformID == 3 || platformID == 0){
				# Windows/Unicode: big-endian UTF-16
				s := "";
				for(j := 0; j + 1 < slen; j += 2){
					ch := getu16be(data, noff + j);
					if(ch > 0 && ch < 16rFFFF)
						s[len s] = ch;
				}
				if(len s > 0)
					return s;
			}
		}
	}
	return "TrueType";
}

# ---- TrueType glyph outline extraction ----

getttfoutline(fd: ref FaceData, gid: int): ref GlyphOutline
{
	return getttfglyphrecur(fd, gid, 0);
}

getttfglyphrecur(fd: ref FaceData, gid: int, depth: int): ref GlyphOutline
{
	if(depth > 10 || gid < 0 || gid >= fd.nglyphs)
		return nil;
	if(fd.locaoffs == nil || gid + 1 >= len fd.locaoffs)
		return nil;

	off := fd.glyfoff + fd.locaoffs[gid];
	nextoff := fd.glyfoff + fd.locaoffs[gid + 1];

	# Advance width
	w := 0;
	if(fd.ttfwidths != nil && gid < len fd.ttfwidths)
		w = fd.ttfwidths[gid];

	# Empty glyph (space, etc.)
	if(off >= nextoff || off + 10 > len fd.ttfdata)
		return ref GlyphOutline(nil, w);

	data := fd.ttfdata;
	ncontours := geti16be(data, off);

	if(ncontours >= 0)
		return parsesimpleglyph(fd, gid, data, off, ncontours, w);
	return parsecompositeglyph(fd, gid, data, off, w, depth);
}

# Parse a simple TrueType glyph
parsesimpleglyph(fd: ref FaceData, gid: int, data: array of byte, off, ncontours, advwidth: int): ref GlyphOutline
{
	if(ncontours == 0)
		return ref GlyphOutline(nil, advwidth);

	pos := off + 10;	# skip header (numberOfContours + bbox)

	# Read endPtsOfContours
	if(pos + ncontours * 2 > len data)
		return ref GlyphOutline(nil, advwidth);
	endpts := array[ncontours] of { * => 0 };
	for(i := 0; i < ncontours; i++){
		endpts[i] = getu16be(data, pos);
		pos += 2;
	}

	npoints := endpts[ncontours - 1] + 1;
	if(npoints <= 0 || npoints > 16384)
		return ref GlyphOutline(nil, advwidth);

	# Skip instructions
	if(pos + 2 > len data)
		return ref GlyphOutline(nil, advwidth);
	instlen := getu16be(data, pos);
	pos += 2 + instlen;

	# Read flags (packed with repeat)
	pflags := array[npoints] of { * => 0 };
	fi := 0;
	while(fi < npoints && pos < len data){
		f := int data[pos]; pos++;
		pflags[fi] = f; fi++;
		if(f & 16r08){	# REPEAT
			if(pos >= len data) break;
			rcount := int data[pos]; pos++;
			for(r := 0; r < rcount && fi < npoints; r++){
				pflags[fi] = f;
				fi++;
			}
		}
	}

	# Read X coordinates (deltas → cumulative)
	xcoords := array[npoints] of { * => 0 };
	xval := 0;
	for(i = 0; i < npoints; i++){
		f := pflags[i];
		if(f & 16r02){	# X_SHORT
			if(pos >= len data) break;
			dx := int data[pos]; pos++;
			if(!(f & 16r10))	# negative
				dx = -dx;
			xval += dx;
		} else if(!(f & 16r10)){	# 2-byte signed delta
			if(pos + 1 >= len data) break;
			xval += geti16be(data, pos); pos += 2;
		}
		# else: same as previous (delta = 0)
		xcoords[i] = xval;
	}

	# Read Y coordinates
	ycoords := array[npoints] of { * => 0 };
	yval := 0;
	for(i = 0; i < npoints; i++){
		f := pflags[i];
		if(f & 16r04){	# Y_SHORT
			if(pos >= len data) break;
			dy := int data[pos]; pos++;
			if(!(f & 16r20))	# negative
				dy = -dy;
			yval += dy;
		} else if(!(f & 16r20)){	# 2-byte signed delta
			if(pos + 1 >= len data) break;
			yval += geti16be(data, pos); pos += 2;
		}
		ycoords[i] = yval;
	}

	# an instance of a variable font: the points moved by its deltas
	if(fd.coords != nil) {
		(dx, dy) := glyphdeltas(fd, gid, npoints, endpts, xcoords, ycoords);
		if(dx != nil) {
			# the left phantom point is the origin: the outline moves
			# against it, and the advance is the phantoms' distance
			d0 := dx[npoints];
			for(i = 0; i < npoints; i++) {
				xcoords[i] = int (real xcoords[i] + dx[i] - d0);	# (int rounds)
				ycoords[i] = int (real ycoords[i] + dy[i]);
			}
			advwidth = int (real advwidth + dx[npoints+1] - d0);
		}
	}

	# Build PathSeg list from contours
	path: list of ref PathSeg;
	startpt := 0;
	for(ci := 0; ci < ncontours; ci++){
		endpt := endpts[ci];
		npts := endpt - startpt + 1;
		if(npts >= 2)
			path = ttfcontourpath(xcoords, ycoords, pflags, startpt, endpt, path);
		startpt = endpt + 1;
	}
	return ref GlyphOutline(path, advwidth);
}

# Convert a TrueType contour to PathSeg list segments (quadratic → cubic)
ttfcontourpath(xc, yc, flags: array of int, startpt, endpt: int,
	path: list of ref PathSeg): list of ref PathSeg
{
	npts := endpt - startpt + 1;

	# Find first on-curve point
	firstoncurve := -1;
	for(i := 0; i < npts; i++){
		if(flags[startpt + i] & 1){
			firstoncurve = i;
			break;
		}
	}

	# Starting position
	sx, sy: real;
	startidx: int;
	if(firstoncurve >= 0){
		startidx = firstoncurve;
		sx = real xc[startpt + startidx];
		sy = real yc[startpt + startidx];
	} else {
		# All off-curve: start at midpoint of first and last
		sx = (real xc[startpt] + real xc[endpt]) / 2.0;
		sy = (real yc[startpt] + real yc[endpt]) / 2.0;
		startidx = 0;
	}

	path = ref PathSeg.Move(sx, sy) :: path;
	curx := sx;
	cury := sy;

	i = 1;
	while(i < npts){
		idx := startpt + (startidx + i) % npts;
		oncurve := flags[idx] & 1;
		px := real xc[idx];
		py := real yc[idx];

		if(oncurve){
			path = ref PathSeg.Line(px, py) :: path;
			curx = px;
			cury = py;
			i++;
		} else {
			# Off-curve control point; determine endpoint
			nextidx := startpt + (startidx + i + 1) % npts;
			nextoncurve := flags[nextidx] & 1;
			endx, endy: real;

			if(nextoncurve){
				endx = real xc[nextidx];
				endy = real yc[nextidx];
				i += 2;
			} else {
				# Implied on-curve at midpoint of consecutive off-curves
				endx = (px + real xc[nextidx]) / 2.0;
				endy = (py + real yc[nextidx]) / 2.0;
				i++;
			}

			# Quadratic → Cubic bezier conversion
			c1x := curx + 2.0/3.0 * (px - curx);
			c1y := cury + 2.0/3.0 * (py - cury);
			c2x := endx + 2.0/3.0 * (px - endx);
			c2y := endy + 2.0/3.0 * (py - endy);

			path = ref PathSeg.Curve(c1x, c1y, c2x, c2y, endx, endy) :: path;
			curx = endx;
			cury = endy;
		}
	}

	path = ref PathSeg.Close :: path;
	return path;
}

# Parse a composite TrueType glyph
parsecompositeglyph(fd: ref FaceData, gid: int, data: array of byte,
	off, advwidth, depth: int): ref GlyphOutline
{
	pos := off + 10;	# skip header + bbox
	path: list of ref PathSeg;
	# an instance: each component's offset is a point the deltas move,
	# and the four phantom points follow them
	cdx, cdy: array of real;
	if(fd.coords != nil) {
		nc := ncomponents(data, off);
		(cdx, cdy) = glyphdeltas(fd, gid, nc, nil, nil, nil);
		if(cdx != nil)
			advwidth = int (real advwidth + cdx[nc+1] - cdx[nc]);
	}
	ci := 0;

	for(;;){
		if(pos + 4 > len data)
			break;

		cflags := getu16be(data, pos); pos += 2;
		glyphidx := getu16be(data, pos); pos += 2;

		# Read translation arguments
		dx := 0.0;
		dy := 0.0;
		if(cflags & 16r01){	# ARG_1_AND_2_ARE_WORDS
			if(cflags & 16r02){	# ARGS_ARE_XY_VALUES
				dx = real geti16be(data, pos);
				dy = real geti16be(data, pos + 2);
			}
			pos += 4;
		} else {
			if(cflags & 16r02){
				dx = real geti8(data, pos);
				dy = real geti8(data, pos+1);
			}
			pos += 2;
		}

		# Read optional transform: x' = a*x + c*y + dx, y' = b*x + d*y + dy
		a := 1.0;
		b := 0.0;
		c := 0.0;
		d := 1.0;
		if(cflags & 16r08){	# WE_HAVE_A_SCALE
			a = getf2dot14(data, pos);
			d = a;
			pos += 2;
		} else if(cflags & 16r40){	# WE_HAVE_AN_X_AND_Y_SCALE
			a = getf2dot14(data, pos);
			d = getf2dot14(data, pos + 2);
			pos += 4;
		} else if(cflags & 16r80){	# WE_HAVE_A_TWO_BY_TWO
			a = getf2dot14(data, pos);
			b = getf2dot14(data, pos + 2);
			c = getf2dot14(data, pos + 4);
			d = getf2dot14(data, pos + 6);
			pos += 8;
		}

		if(cdx != nil && ci < len cdx - 4 && cflags & 16r02) {
			dx += cdx[ci] - cdx[len cdx - 4];
			dy += cdy[ci];
		}
		ci++;

		# Get component glyph outline recursively
		comp := getttfglyphrecur(fd, glyphidx, depth + 1);
		if(comp != nil && comp.path != nil){
			# Paths are kept in reverse order (see rasterize), so the
			# component's segments go on the front in the order they
			# are: transform into a reversed copy, then reverse that on.
			r: list of ref PathSeg;
			for(seg := comp.path; seg != nil; seg = tl seg){
				pick ps := hd seg {
				Move =>
					r = ref PathSeg.Move(a*ps.x + c*ps.y + dx, b*ps.x + d*ps.y + dy) :: r;
				Line =>
					r = ref PathSeg.Line(a*ps.x + c*ps.y + dx, b*ps.x + d*ps.y + dy) :: r;
				Curve =>
					r = ref PathSeg.Curve(
						a*ps.x1 + c*ps.y1 + dx, b*ps.x1 + d*ps.y1 + dy,
						a*ps.x2 + c*ps.y2 + dx, b*ps.x2 + d*ps.y2 + dy,
						a*ps.x3 + c*ps.y3 + dx, b*ps.x3 + d*ps.y3 + dy) :: r;
				Close =>
					r = ref PathSeg.Close :: r;
				}
			}
			for(; r != nil; r = tl r)
				path = hd r :: path;
		}

		if(!(cflags & 16r20))	# MORE_COMPONENTS
			break;
	}

	return ref GlyphOutline(path, advwidth);
}

# The CFF standard strings (Adobe TN 5176, Appendix A), SID order
Cffstrings: con
	".notdef space exclam quotedbl numbersign dollar percent ampersand " +
	"quoteright parenleft parenright asterisk plus comma hyphen period " +
	"slash zero one two three four five six seven eight nine colon " +
	"semicolon less equal greater question at A B C D E F G H I J K L M N " +
	"O P Q R S T U V W X Y Z bracketleft backslash bracketright " +
	"asciicircum underscore quoteleft a b c d e f g h i j k l m n o p q r " +
	"s t u v w x y z braceleft bar braceright asciitilde exclamdown cent " +
	"sterling fraction yen florin section currency quotesingle " +
	"quotedblleft guillemotleft guilsinglleft guilsinglright fi fl endash " +
	"dagger daggerdbl periodcentered paragraph bullet quotesinglbase " +
	"quotedblbase quotedblright guillemotright ellipsis perthousand " +
	"questiondown grave acute circumflex tilde macron breve dotaccent " +
	"dieresis ring cedilla hungarumlaut ogonek caron emdash AE " +
	"ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash " +
	"oe germandbls onesuperior logicalnot mu trademark Eth onehalf " +
	"plusminus Thorn onequarter divide brokenbar degree thorn " +
	"threequarters twosuperior registered minus eth multiply " +
	"threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring " +
	"Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute " +
	"Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis " +
	"Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave Yacute " +
	"Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde " +
	"ccedilla eacute ecircumflex edieresis egrave iacute icircumflex " +
	"idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde " +
	"scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron " +
	"exclamsmall Hungarumlautsmall dollaroldstyle dollarsuperior " +
	"ampersandsmall Acutesmall parenleftsuperior parenrightsuperior " +
	"twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle " +
	"threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle " +
	"eightoldstyle nineoldstyle commasuperior threequartersemdash " +
	"periodsuperior questionsmall asuperior bsuperior centsuperior " +
	"dsuperior esuperior isuperior lsuperior msuperior nsuperior " +
	"osuperior rsuperior ssuperior tsuperior ff ffi ffl parenleftinferior " +
	"parenrightinferior Circumflexsmall hyphensuperior Gravesmall Asmall " +
	"Bsmall Csmall Dsmall Esmall Fsmall Gsmall Hsmall Ismall Jsmall " +
	"Ksmall Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall Ssmall " +
	"Tsmall Usmall Vsmall Wsmall Xsmall Ysmall Zsmall colonmonetary " +
	"onefitted rupiah Tildesmall exclamdownsmall centoldstyle Lslashsmall " +
	"Scaronsmall Zcaronsmall Dieresissmall Brevesmall Caronsmall " +
	"Dotaccentsmall Macronsmall figuredash hypheninferior Ogoneksmall " +
	"Ringsmall Cedillasmall questiondownsmall oneeighth threeeighths " +
	"fiveeighths seveneighths onethird twothirds zerosuperior " +
	"foursuperior fivesuperior sixsuperior sevensuperior eightsuperior " +
	"ninesuperior zeroinferior oneinferior twoinferior threeinferior " +
	"fourinferior fiveinferior sixinferior seveninferior eightinferior " +
	"nineinferior centinferior dollarinferior periodinferior " +
	"commainferior Agravesmall Aacutesmall Acircumflexsmall Atildesmall " +
	"Adieresissmall Aringsmall AEsmall Ccedillasmall Egravesmall " +
	"Eacutesmall Ecircumflexsmall Edieresissmall Igravesmall Iacutesmall " +
	"Icircumflexsmall Idieresissmall Ethsmall Ntildesmall Ogravesmall " +
	"Oacutesmall Ocircumflexsmall Otildesmall Odieresissmall OEsmall " +
	"Oslashsmall Ugravesmall Uacutesmall Ucircumflexsmall Udieresissmall " +
	"Yacutesmall Thornsmall Ydieresissmall 001.000 001.001 001.002 " +
	"001.003 Black Bold Book Light Medium Regular Roman Semibold";

# StandardEncoding, the SID for each code (TN 5176, Appendix B)
stdsids := array[] of {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
	17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
	33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
	49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
	65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
	81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
	0, 111, 112, 113, 114, 0, 115, 116, 117, 118, 119, 120, 121, 122, 0, 123,
	0, 124, 125, 126, 127, 128, 129, 130, 131, 0, 132, 133, 0, 134, 135, 136,
	137, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 138, 0, 139, 0, 0, 0, 0, 140, 141, 142, 143, 0, 0, 0, 0,
	0, 144, 0, 0, 0, 145, 0, 0, 146, 147, 148, 149, 0, 0, 0, 0
};
