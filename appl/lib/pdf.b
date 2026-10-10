implement PDF;

#
# Native PDF parsing and rendering module.
#
# Parses PDF files in-memory, extracts text via ToUnicode CMaps,
# and renders pages to Draw images using Inferno graphics primitives.
#
# Phase 1: Vector graphics (paths, fills, strokes, colors)
# Phase 2: Text rendering (BT/ET, Tj/TJ, font mapping)
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Image, Font, Rect, Point: import drawm;

include "math.m";
	math: Math;

include "filter.m";
	filtermod: Filter;

include "pdf.m";

include "bufio.m";
	bufio: Bufio;

include "imagefile.m";
	readjpgmod: RImagefile;
	imageremap: Imageremap;

include "outlinefont.m";
	outlinefont: OutlineFont;
	Face: import outlinefont;

include "keyring.m";
	keyring: Keyring;

include "pdfenc.m";
	pdfenc: Pdfenc;

# ---- PDF internal types ----

Onull, Obool, Oint, Oreal, Ostring, Oname,
Oarray, Odict, Ostream, Oref: con iota;

PdfObj: adt {
	kind: int;
	ival: int;
	rval: real;
	sval: string;
	aval: list of ref PdfObj;
	dval: list of ref DictEntry;
	stream: array of byte;
};

DictEntry: adt {
	key: string;
	val: ref PdfObj;
};

XrefEntry: adt {
	offset: int;
	gen: int;
	inuse: int;
};

CMapEntry: adt {
	lo: int;
	hi: int;
	unicode: int;
};

# A font as a resource dictionary names it
FontMapEntry: adt {
	name: string;
	f: ref PdfFont;
};

# A font, made once a document (by its object), its face when first drawn
PdfFont: adt {
	kind: int;		# Fsimple, Fcid, Ftype3
	basefont: string;	# without a subset's tag
	fontobj: ref PdfObj;
	cidfont: ref PdfObj;	# a Type0's descendant
	twobyte: int;		# codes are two bytes
	cidmap: list of ref CMapEntry;	# an embedded CMap's codes to CIDs (nil: identity)
	codespace: array of (int, int, int);	# its codespace ranges: bytes, lo, hi
	entries: list of ref CMapEntry;	# ToUnicode
	names: array of string;	# a simple font's glyph name by code (nil: the font's own)
	code2uni: array of int;	# and their Unicode values, -1 none
	widths: array of int;	# by code, or a CID font's by CID; -1: dw
	dw: int;		# the default width (1/1000 of the size)
	loaded: int;		# fontload done
	face: ref OutlineFont->Face;
	embedded: ref OutlineFont->Face;	# the document's own, closed with it
	ttf: int;		# face is TrueType (glyphs by Unicode, not by name)
	subst: int;		# face stands in for a font not embedded
	hs: real;		# a substitute narrowed to the PDF's widths
	code2gid: array of int;	# a simple font's glyphs (FALLBACK+g: the fallback face's)
	cid2gid: array of int;	# CIDToGIDMap (nil: identity)
	fmatrix: array of real;	# Type 3
	charprocs: ref PdfObj;
	t3res: ref PdfObj;
	t3procs: array of array of byte;	# glyph content streams, by code, as decompressed
	t3widths: array of real;
};

PdfDoc: adt {
	data: array of byte;
	xref: array of ref XrefEntry;
	trailer: ref PdfObj;
	nobjs: int;
	enckey: array of byte;	# file encryption key (nil = not encrypted)
	encv: int;		# V value (1=RC4-40, 2=RC4-128, 4=AES-128, 5=AES-256)
	encr: int;		# R value (revision)
	enckeylen: int;		# key length in bytes
	encstmf: string;	# stream crypt filter name
	encstrf: string;	# string crypt filter name
	encobjnum: int;		# /Encrypt dict object number (never decrypt)
	fonts: list of (int, ref PdfFont);	# by object number
	deffont: ref PdfFont;
};

# ---- Graphics state types ----

GState: adt {
	ctm: array of real;        # 6-element affine [a b c d e f]
	fillcolor: (int, int, int);
	strokecolor: (int, int, int);
	linewidth: real;
	linecap: int;
	linejoin: int;
	miterlimit: real;
	fontname: string;
	fontsize: real;
	tm: array of real;         # text matrix [a b c d e f]
	tlm: array of real;        # text line matrix
	charspace: real;
	wordspace: real;
	hscale: real;
	leading: real;
	rise: real;
	rendermode: int;
	alpha: real;               # non-stroking opacity (ca from ExtGState)
	fillcscomps: int;          # fill color space component count (3=RGB, 4=CMYK, 1=gray)
	strokecscomps: int;        # stroke color space component count
	clipmask: ref Image;       # GREY8 clip mask (nil = no clip, white = visible)
	smask: ref Image;          # GREY8 soft mask from ExtGState SMask (nil = none)
	cliprect: Rect;            # the clip's bounds on the image (text is clipped to it)
	textclip: ref Image;       # GREY8: the glyphs shown to clip by (Tr 4-7) until ET
};

PathSeg: adt {
	pick {
	Move =>
		x, y: real;
	Line =>
		x, y: real;
	Curve =>
		x1, y1, x2, y2, x3, y3: real;
	Close =>
	}
};

# Color cache entry
ColorCacheEntry: adt {
	r, g, b: int;
	img: ref Image;
};

# ---- Module state ----
display: ref Display;
colorcache: list of ref ColorCacheEntry;

# Font paths


init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	math = load Math Math->PATH;
	keyring = load Keyring Keyring->PATH;
	if(sys == nil || drawm == nil || math == nil || keyring == nil)
		return "cannot load system modules";
	display = d;
	colorcache = nil;

	outlinefont = load OutlineFont OutlineFont->PATH;
	if(outlinefont != nil)
		outlinefont->init(d);

	return nil;
}

loadjpg(): string
{
	if(bufio == nil){
		bufio = load Bufio Bufio->PATH;
		if(bufio == nil)
			return sys->sprint("cannot load bufio: %r");
	}
	if(readjpgmod == nil){
		readjpgmod = load RImagefile RImagefile->READJPGPATH;
		if(readjpgmod == nil)
			return sys->sprint("cannot load readjpg: %r");
		readjpgmod->init(bufio);
	}
	if(imageremap == nil){
		imageremap = load Imageremap Imageremap->PATH;
		if(imageremap == nil)
			return sys->sprint("cannot load imageremap: %r");
		imageremap->init(display);
	}
	return nil;
}

open(data: array of byte, password: string): (ref Doc, string)
{
	if(len data < 20)
		return (nil, "file too small");

	(pdoc, err) := parsepdf(data);
	if(pdoc == nil)
		return (nil, err);

	# Initialize decryption if /Encrypt is present
	cerr := initcrypt(pdoc, password);
	if(cerr != nil)
		return (nil, cerr);

	# Store in docs table, return handle with index
	idx := adddoc(pdoc);
	return (ref Doc(idx), nil);
}

# Document table (supports multiple open documents)
doctab: array of ref PdfDoc;
ndocs := 0;

adddoc(pdoc: ref PdfDoc): int
{
	if(doctab == nil)
		doctab = array[4] of ref PdfDoc;
	if(ndocs >= len doctab){
		newtab := array[len doctab * 2] of ref PdfDoc;
		newtab[0:] = doctab;
		doctab = newtab;
	}
	idx := ndocs;
	doctab[idx] = pdoc;
	ndocs++;
	return idx;
}

getdoc(idx: int): ref PdfDoc
{
	if(doctab == nil || idx < 0 || idx >= ndocs)
		return nil;
	return doctab[idx];
}

Doc.close(d: self ref Doc)
{
	if(doctab != nil && d.idx >= 0 && d.idx < ndocs){
		pdoc := doctab[d.idx];
		if(pdoc != nil)
			for(l := pdoc.fonts; l != nil; l = tl l)
				if((hd l).t1.embedded != nil)
					(hd l).t1.embedded.close();
		doctab[d.idx] = nil;
	}
	d.idx = -1;
}

Doc.pagecount(d: self ref Doc): int
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return 0;
	return countpages(pdoc);
}

Doc.pagesize(d: self ref Doc, page: int): (real, real)
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return (0.0, 0.0);
	pobj := getpageobj(pdoc, page);
	if(pobj == nil)
		return (612.0, 792.0);  # default US Letter
	return getmediabox(pdoc, pobj);
}

Doc.renderpage(d: self ref Doc, page, dpi: int): (ref Image, string)
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return (nil, "no document");
	if(display == nil)
		return (nil, "no display");
	pobj := getpageobj(pdoc, page);
	if(pobj == nil)
		return (nil, sys->sprint("page %d not found", page));
	return renderpage(pdoc, pobj, dpi);
}

Doc.paint(d: self ref Doc, page: int, zoom: real, dst: ref Image): string
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return "no document";
	if(display == nil || dst == nil)
		return "no display";
	pobj := getpageobj(pdoc, page);
	if(pobj == nil)
		return sys->sprint("page %d not found", page);
	return renderto(pdoc, pobj, dst, zoom);
}

Doc.extracttext(d: self ref Doc, page: int): string
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return nil;
	pobj := getpageobj(pdoc, page);
	if(pobj == nil)
		return nil;
	return extractpagetext_full(pdoc, pobj);
}

Doc.extractall(d: self ref Doc): string
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return nil;
	(text, nil) := extracttext(pdoc);
	return text;
}

Doc.words(d: self ref Doc, page: int): list of (string, Rect)
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return nil;
	pobj := getpageobj(pdoc, page);
	if(pobj == nil)
		return nil;
	(nil, ph) := getmediabox(pdoc, pobj);
	fontmap := buildfontmap(pdoc, pobj);
	contents := dictget(pobj.dval, "Contents");
	if(contents == nil)
		return nil;
	contents = resolve(pdoc, contents);
	if(contents == nil)
		return nil;
	streams: list of ref PdfObj;
	if(contents.kind == Oarray){
		for(a := contents.aval; a != nil; a = tl a)
			if((st := resolve(pdoc, hd a)) != nil)
				streams = st :: streams;
	}else if(contents.kind == Ostream)
		streams = contents :: nil;
	# the streams in order, as one content stream
	data: array of byte;
	for(; streams != nil; streams = tl streams){
		(sd, nil) := decompressstream(hd streams);
		if(sd == nil)
			continue;
		nd := array[len sd + 1 + len data] of byte;
		nd[0:] = sd;
		nd[len sd] = byte '\n';
		nd[len sd + 1:] = data;
		data = nd;
	}
	if(data == nil)
		return nil;
	words: list of (string, Rect);
	{
		words = contentwords(pdoc, data, fontmap, ph);
	} exception {
	"*" =>
		;
	}
	# in the order shown
	r: list of (string, Rect);
	for(; words != nil; words = tl words)
		r = hd words :: r;
	return r;
}

Doc.dumppage(d: self ref Doc, page: int): string
{
	pdoc := getdoc(d.idx);
	if(pdoc == nil)
		return "no document";

	pobj := getpageobj(pdoc, page);
	if(pobj == nil)
		return sys->sprint("page %d not found", page);

	s := "";

	# Page dict keys
	s += "page dict keys:";
	for(dl := pobj.dval; dl != nil; dl = tl dl){
		e := hd dl;
		s += " /" + e.key;
		if(e.val != nil)
			s += sys->sprint("[%d]", e.val.kind);
	}
	s += "\n";

	# MediaBox (raw: walk up tree to find it)
	(pw, ph) := getmediabox(pdoc, pobj);
	s += sys->sprint("mediabox: %.2f x %.2f\n", pw, ph);

	# Dump raw MediaBox array
	node := pobj;
	depth := 0;
	while(node != nil && depth < 10){
		box := dictget(node.dval, "MediaBox");
		if(box != nil){
			box = resolve(pdoc, box);
			if(box != nil && box.kind == Oarray){
				s += "  raw MediaBox at depth " + string depth + ":";
				for(bl := box.aval; bl != nil; bl = tl bl){
					o := hd bl;
					if(o.kind == Oint)
						s += " " + string o.ival;
					else if(o.kind == Oreal)
						s += sys->sprint(" %.3f", o.rval);
					else
						s += sys->sprint(" kind=%d", o.kind);
				}
				s += "\n";
			}
			break;
		}
		parent := dictget(node.dval, "Parent");
		if(parent == nil) break;
		node = resolve(pdoc, parent);
		depth++;
	}

	# Resources
	res := dictget(pobj.dval, "Resources");
	if(res == nil)
		s += "resources: nil (not in page dict)\n";
	else {
		if(res.kind == Oref)
			s += sys->sprint("resources: ref %d\n", res.ival);
		else
			s += sys->sprint("resources: kind=%d\n", res.kind);
		rres := resolve(pdoc, res);
		if(rres == nil)
			s += "  resolved: nil!\n";
		else {
			s += "  resolved: kind=" + string rres.kind + " keys:";
			for(rl := rres.dval; rl != nil; rl = tl rl)
				s += " /" + (hd rl).key;
			s += "\n";
		}
	}

	# Contents
	contents := dictget(pobj.dval, "Contents");
	if(contents == nil){
		s += "contents: nil\n";
		return s;
	}
	s += sys->sprint("contents: kind=%d", contents.kind);
	if(contents.kind == Oref)
		s += sys->sprint(" ref=%d", contents.ival);
	s += "\n";

	contents = resolve(pdoc, contents);
	if(contents == nil){
		s += "contents resolved: nil!\n";
		return s;
	}
	s += sys->sprint("contents resolved: kind=%d\n", contents.kind);

	# Decompress content stream(s)
	csdata: array of byte;
	if(contents.kind == Oarray){
		s += sys->sprint("contents array: %d elements\n", lenlistobj(contents.aval));
		chunks: list of array of byte;
		total := 0;
		ci := 0;
		for(a := contents.aval; a != nil; a = tl a){
			stream := resolve(pdoc, hd a);
			if(stream == nil){
				s += sys->sprint("  chunk %d: resolve nil\n", ci);
			} else if(stream.kind != Ostream){
				s += sys->sprint("  chunk %d: kind=%d (not stream)\n", ci, stream.kind);
			} else {
				(sd, derr) := decompressstream(stream);
				if(sd == nil)
					s += sys->sprint("  chunk %d: decompress failed: %s\n", ci, derr);
				else {
					s += sys->sprint("  chunk %d: %d bytes\n", ci, len sd);
					chunks = sd :: chunks;
					total += len sd;
				}
			}
			ci++;
		}
		csdata = array[total] of byte;
		pos := total;
		for(; chunks != nil; chunks = tl chunks){
			chunk := hd chunks;
			pos -= len chunk;
			csdata[pos:] = chunk;
		}
	} else if(contents.kind == Ostream){
		(sd, derr) := decompressstream(contents);
		if(sd == nil)
			s += sys->sprint("decompress failed: %s\n", derr);
		else {
			s += sys->sprint("stream: %d bytes\n", len sd);
			csdata = sd;
		}
	}

	if(csdata == nil || len csdata == 0){
		s += "no content stream data\n";
		return s;
	}

	s += sys->sprint("total content: %d bytes\n", len csdata);

	# Show first 500 bytes of content stream as text
	preview := len csdata;
	if(preview > 500) preview = 500;
	s += "content preview:\n";
	for(i := 0; i < preview; i++){
		c := int csdata[i];
		if(c >= 16r20 && c < 16r7F)
			s[len s] = c;
		else if(c == '\n' || c == '\r')
			s[len s] = '\n';
		else
			s += sys->sprint("\\x%02x", c);
	}
	s += "\n";

	return s;
}

lenlistobj(l: list of ref PdfObj): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

# ---- Page tree navigation ----

countpages(doc: ref PdfDoc): int
{
	root := dictget(doc.trailer.dval, "Root");
	if(root == nil) return 0;
	root = resolve(doc, root);
	if(root == nil) return 0;
	pages := dictget(root.dval, "Pages");
	if(pages == nil) return 0;
	pages = resolve(doc, pages);
	if(pages == nil) return 0;
	return countpagenode(doc, pages, 0);
}

MAXPAGEDEPTH: con 64;

countpagenode(doc: ref PdfDoc, node: ref PdfObj, depth: int): int
{
	if(node == nil || depth > MAXPAGEDEPTH) return 0;
	typobj := dictget(node.dval, "Type");
	typ := "";
	if(typobj != nil && typobj.kind == Oname)
		typ = typobj.sval;
	if(typ == "Page")
		return 1;
	if(typ == "Pages"){
		count := 0;
		kids := dictget(node.dval, "Kids");
		if(kids != nil && kids.kind == Oarray){
			for(k := kids.aval; k != nil; k = tl k){
				child := resolve(doc, hd k);
				if(child != nil)
					count += countpagenode(doc, child, depth + 1);
			}
		}
		return count;
	}
	return 0;
}

# Get the Nth page object (1-indexed)
getpageobj(doc: ref PdfDoc, page: int): ref PdfObj
{
	root := dictget(doc.trailer.dval, "Root");
	if(root == nil) return nil;
	root = resolve(doc, root);
	if(root == nil) return nil;
	pages := dictget(root.dval, "Pages");
	if(pages == nil) return nil;
	pages = resolve(doc, pages);
	if(pages == nil) return nil;

	(pobj, nil) := findpage(doc, pages, page, 0, 0);
	return pobj;
}

# Find page by number, returns (page obj, count so far)
findpage(doc: ref PdfDoc, node: ref PdfObj, target, sofar, depth: int): (ref PdfObj, int)
{
	if(node == nil || depth > MAXPAGEDEPTH)
		return (nil, sofar);
	typobj := dictget(node.dval, "Type");
	typ := "";
	if(typobj != nil && typobj.kind == Oname)
		typ = typobj.sval;

	if(typ == "Page"){
		sofar++;
		if(sofar == target)
			return (node, sofar);
		return (nil, sofar);
	}

	if(typ == "Pages"){
		kids := dictget(node.dval, "Kids");
		if(kids != nil && kids.kind == Oarray){
			for(k := kids.aval; k != nil; k = tl k){
				child := resolve(doc, hd k);
				if(child == nil)
					continue;
				(pobj, ns) := findpage(doc, child, target, sofar, depth + 1);
				if(pobj != nil)
					return (pobj, ns);
				sofar = ns;
			}
		}
	}
	return (nil, sofar);
}

# Get MediaBox (or CropBox) dimensions in points.
# Walks up the page tree via Parent refs per PDF spec inheritance.
getmediabox(doc: ref PdfDoc, page: ref PdfObj): (real, real)
{
	box: ref PdfObj;

	# Walk up page tree to find CropBox or MediaBox
	node := page;
	depth := 0;
	while(node != nil && depth < 10){
		box = dictget(node.dval, "CropBox");
		if(box == nil)
			box = dictget(node.dval, "MediaBox");
		if(box != nil){
			box = resolve(doc, box);
			if(box != nil && box.kind == Oarray)
				break;
			box = nil;
		}
		parent := dictget(node.dval, "Parent");
		if(parent == nil)
			break;
		node = resolve(doc, parent);
		depth++;
	}

	if(box == nil || box.kind != Oarray)
		return (612.0, 792.0);

	vals := array[4] of { * => 0.0 };
	i := 0;
	for(l := box.aval; l != nil && i < 4; l = tl l){
		o := hd l;
		if(o.kind == Oint)
			vals[i] = real o.ival;
		else if(o.kind == Oreal)
			vals[i] = o.rval;
		i++;
	}
	w := vals[2] - vals[0];
	h := vals[3] - vals[1];
	if(w <= 0.0) w = 612.0;
	if(h <= 0.0) h = 792.0;
	return (w, h);
}

# Walk parent chain to find /Resources (like getmediabox)
getresources(doc: ref PdfDoc, page: ref PdfObj): ref PdfObj
{
	node := page;
	depth := 0;
	while(node != nil && depth < 10){
		res := dictget(node.dval, "Resources");
		if(res != nil){
			res = resolve(doc, res);
			if(res != nil)
				return res;
		}
		parent := dictget(node.dval, "Parent");
		if(parent == nil)
			break;
		node = resolve(doc, parent);
		depth++;
	}
	return nil;
}

# ---- Rendering engine ----

renderpage(doc: ref PdfDoc, page: ref PdfObj, dpi: int): (ref Image, string)
{
	(pw, ph) := getmediabox(doc, page);
	# Convert points to pixels: pw * dpi / 72, with rounding
	pixw := (int pw * dpi + 36) / 72;
	pixh := (int ph * dpi + 36) / 72;

	if(pixw <= 0) pixw = 1;
	if(pixh <= 0) pixh = 1;

	# Cap pixel dimensions to avoid enormous image allocations
	MAXPIX: con 8000;
	if(pixw > MAXPIX || pixh > MAXPIX){
		scalew := real MAXPIX / real pixw;
		scaleh := real MAXPIX / real pixh;
		s := scalew;
		if(scaleh < s) s = scaleh;
		pixw = int (real pixw * s);
		pixh = int (real pixh * s);
		if(pixw <= 0) pixw = 1;
		if(pixh <= 0) pixh = 1;
	}

	# Create page image with white background
	img := display.newimage(Rect(Point(0,0), Point(pixw, pixh)),
		drawm->RGB24, 0, drawm->White);
	if(img == nil)
		return (nil, "cannot allocate page image");
	return (img, renderto(doc, page, img, real pixw / pw));
}

# The page drawn onto img at scale pixels to the point, its top left at
# img.r.min.
renderto(doc: ref PdfDoc, page: ref PdfObj, img: ref Image, scale: real): string
{
	img.draw(img.r, display.white, nil, Point(0, 0));
	gs := newgstate();
	# PDF space (origin bottom left, y up) to the image (top left, y down)
	gs.ctm[0] = scale;
	gs.ctm[1] = 0.0;
	gs.ctm[2] = 0.0;
	gs.ctm[3] = -scale;
	gs.ctm[4] = real img.r.min.x;
	gs.ctm[5] = real img.r.max.y;

	# Get page resources (walk parent chain)
	resources := getresources(doc, page);

	# Build font map for text
	fontmap := buildfontmap(doc, page);

	# Get content streams
	contents := dictget(page.dval, "Contents");
	if(contents == nil){
		return nil;  # blank page
	}
	contents = resolve(doc, contents);
	if(contents == nil){
		return nil;
	}

	# Collect content stream data
	csdata: array of byte;
	if(contents.kind == Oarray){
		chunks: list of array of byte;
		total := 0;
		for(a := contents.aval; a != nil; a = tl a){
			stream := resolve(doc, hd a);
			if(stream != nil && stream.kind == Ostream){
				(sd, nil) := decompressstream(stream);
				if(sd != nil){
					chunks = sd :: chunks;
					total += len sd;
				}
			}
		}
		csdata = array[total] of byte;
		pos := total;
		for(; chunks != nil; chunks = tl chunks){
			chunk := hd chunks;
			pos -= len chunk;
			csdata[pos:] = chunk;
		}
	} else if(contents.kind == Ostream){
		(sd, nil) := decompressstream(contents);
		csdata = sd;
	}

	if(csdata == nil || len csdata == 0){
		return nil;
	}
	# Execute content stream (exception-safe: return partial render on error)
	{
		execcontentstream(doc, img, csdata, gs, resources, fontmap, 0);
	} exception e {
	"*" =>
		return "render warning: " + e;
	}
	return nil;
}

newgstate(): ref GState
{
	ctm := array[6] of { * => 0.0 };
	ctm[0] = 1.0; ctm[3] = 1.0;  # identity
	tm := array[6] of { * => 0.0 };
	tm[0] = 1.0; tm[3] = 1.0;
	tlm := array[6] of { * => 0.0 };
	tlm[0] = 1.0; tlm[3] = 1.0;
	return ref GState(
		ctm,
		(0, 0, 0),       # fillcolor (black)
		(0, 0, 0),       # strokecolor (black)
		1.0,              # linewidth
		0,                # linecap
		0,                # linejoin
		10.0,             # miterlimit
		nil,              # fontname
		12.0,             # fontsize
		tm,               # text matrix
		tlm,              # text line matrix
		0.0,              # charspace
		0.0,              # wordspace
		100.0,            # hscale
		0.0,              # leading
		0.0,              # rise
		0,                # rendermode
		1.0,              # alpha (fully opaque)
		3,                # fillcscomps (default RGB)
		3,                # strokecscomps (default RGB)
		nil,              # clipmask (no clip)
		nil,              # smask (no soft mask)
		Rect((-NOCLIP, -NOCLIP), (NOCLIP, NOCLIP)),
		nil               # textclip
	);
}

copygstate(gs: ref GState): ref GState
{
	ctm := array[6] of real;
	ctm[0:] = gs.ctm;
	tm := array[6] of real;
	tm[0:] = gs.tm;
	tlm := array[6] of real;
	tlm[0:] = gs.tlm;
	return ref GState(
		ctm,
		gs.fillcolor,
		gs.strokecolor,
		gs.linewidth,
		gs.linecap,
		gs.linejoin,
		gs.miterlimit,
		gs.fontname,
		gs.fontsize,
		tm, tlm,
		gs.charspace,
		gs.wordspace,
		gs.hscale,
		gs.leading,
		gs.rise,
		gs.rendermode,
		gs.alpha,
		gs.fillcscomps,
		gs.strokecscomps,
		gs.clipmask,     # shared ref — copy-on-write at W/W*
		gs.smask,        # shared ref from ExtGState
		gs.cliprect,
		gs.textclip
	);
}

# ---- Content stream interpreter ----

execcontentstream(doc: ref PdfDoc, img: ref Image, data: array of byte,
	gs: ref GState, resources: ref PdfObj, fontmap: list of ref FontMapEntry, depth: int)
{
	pos := 0;
	operands: list of real;
	stroperands: list of string;
	path: list of ref PathSeg;
	gsstack: list of ref GState;
	curfont: ref FontMapEntry;
	tjarraypos := -1;	# start pos of raw TJ array for outline font path
	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data)
			break;

		c := int data[pos];

		# Number
		if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'){
			(val, newpos) := readreal(data, pos);
			operands = val :: operands;
			pos = newpos;
			continue;
		}

		# String operand (...)
		if(c == '('){
			(s, newpos) := readlitstr(data, pos);
			stroperands = s :: stroperands;
			pos = newpos;
			continue;
		}

		# Hex string <...>
		if(c == '<' && (pos+1 >= len data || int data[pos+1] != '<')){
			(s, newpos) := readhexstr(data, pos);
			stroperands = s :: stroperands;
			pos = newpos;
			continue;
		}

		# Array [...] for TJ — save position for kerned rendering
		if(c == '['){
			tjarraypos = pos;
			pos = skiptjarray(data, pos);
			continue;
		}

		# Dict << >> (inline image dict etc)
		if(c == '<' && pos+1 < len data && int data[pos+1] == '<'){
			pos = skipdict(data, pos);
			continue;
		}

		# Name /Foo
		if(c == '/'){
			(name, newpos) := readcsname(data, pos);
			stroperands = name :: stroperands;
			pos = newpos;
			continue;
		}

		# Comment
		if(c == '%'){
			while(pos < len data && int data[pos] != '\n')
				pos++;
			continue;
		}

		# Operator
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   c == '\'' || c == '"' || c == '*'){
			(op, newpos) := readtoken(data, pos);
			pos = newpos;

			case op {
			# ---- Graphics state ----
			"q" =>
				gsstack = copygstate(gs) :: gsstack;
			"Q" =>
				if(gsstack != nil){
					ngs := hd gsstack;
					gsstack = tl gsstack;
					gs.fillcolor = ngs.fillcolor;
					gs.strokecolor = ngs.strokecolor;
					gs.linewidth = ngs.linewidth;
					gs.linecap = ngs.linecap;
					gs.linejoin = ngs.linejoin;
					gs.miterlimit = ngs.miterlimit;
					gs.fontname = ngs.fontname;
					gs.fontsize = ngs.fontsize;
					curfont = fontmaplookup(fontmap, gs.fontname);
					gs.charspace = ngs.charspace;
					gs.wordspace = ngs.wordspace;
					gs.hscale = ngs.hscale;
					gs.leading = ngs.leading;
					gs.rise = ngs.rise;
					gs.rendermode = ngs.rendermode;
					gs.ctm[0:] = ngs.ctm;
					gs.fillcscomps = ngs.fillcscomps;
					gs.strokecscomps = ngs.strokecscomps;
					gs.alpha = ngs.alpha;
					gs.clipmask = ngs.clipmask;
					gs.cliprect = ngs.cliprect;
					gs.smask = ngs.smask;
				}
			"cm" =>
				if(lenlist(operands) >= 6){
					(f, e, dd, cc, b, a, nil) := pop6(operands);
					operands = nil;
					newctm := matmul(array[] of {a, b, cc, dd, e, f}, gs.ctm);
					gs.ctm[0:] = newctm;
				}
			"w" =>
				if(operands != nil){
					gs.linewidth = hd operands;
					operands = nil;
				}
			"J" =>
				if(operands != nil){
					gs.linecap = int (hd operands);
					operands = nil;
				}
			"j" =>
				if(operands != nil){
					gs.linejoin = int (hd operands);
					operands = nil;
				}
			"M" =>
				if(operands != nil){
					gs.miterlimit = hd operands;
					operands = nil;
				}
			"d" =>
				# dash pattern - ignore for now
				operands = nil;
			"gs" =>
				if(stroperands != nil && resources != nil){
					gsname := hd stroperands;
					stroperands = nil;
					applyextgstate(doc, gs, gsname, resources, img, fontmap);
				} else
					stroperands = nil;
			"sh" =>
				if(stroperands != nil && resources != nil){
					shname := hd stroperands;
					stroperands = nil;
					renderaxialsh(doc, img, gs, shname, resources);
				} else
					stroperands = nil;
			"ri" or "i" =>
				operands = nil;
				stroperands = nil;

			# ---- Path construction ----
			"m" =>
				if(lenlist(operands) >= 2){
					(y, x, nil) := pop2(operands);
					operands = nil;
					path = ref PathSeg.Move(x, y) :: path;
				}
			"l" =>
				if(lenlist(operands) >= 2){
					(y, x, nil) := pop2(operands);
					operands = nil;
					path = ref PathSeg.Line(x, y) :: path;
				}
			"c" =>
				if(lenlist(operands) >= 6){
					(y3, x3, y2, x2, y1, x1, nil) := pop6(operands);
					operands = nil;
					path = ref PathSeg.Curve(x1, y1, x2, y2, x3, y3) :: path;
				}
			"v" =>
				# current point is first control point
				if(lenlist(operands) >= 4){
					(y3, x3, y2, x2, nil) := pop4(operands);
					operands = nil;
					(cx, cy) := currentpoint(path);
					path = ref PathSeg.Curve(cx, cy, x2, y2, x3, y3) :: path;
				}
			"y" =>
				# endpoint is second control point
				if(lenlist(operands) >= 4){
					(y3, x3, y1, x1, nil) := pop4(operands);
					operands = nil;
					path = ref PathSeg.Curve(x1, y1, x3, y3, x3, y3) :: path;
				}
			"h" =>
				path = ref PathSeg.Close :: path;
			"re" =>
				if(lenlist(operands) >= 4){
					(h, w, y, x, nil) := pop4(operands);
					operands = nil;
					path = ref PathSeg.Move(x, y) :: path;
					path = ref PathSeg.Line(x+w, y) :: path;
					path = ref PathSeg.Line(x+w, y+h) :: path;
					path = ref PathSeg.Line(x, y+h) :: path;
					path = ref PathSeg.Close :: path;
				}

			# ---- Paint operators ----
			"S" =>
				strokepath(img, gs, path);
				path = nil;
			"s" =>
				path = ref PathSeg.Close :: path;
				strokepath(img, gs, path);
				path = nil;
			"f" or "F" =>
				fillpath(img, gs, path, 0);
				path = nil;
			"f*" =>
				fillpath(img, gs, path, 1);
				path = nil;
			"B" =>
				fillpath(img, gs, path, 0);
				strokepath(img, gs, path);
				path = nil;
			"B*" =>
				fillpath(img, gs, path, 1);
				strokepath(img, gs, path);
				path = nil;
			"b" =>
				path = ref PathSeg.Close :: path;
				fillpath(img, gs, path, 0);
				strokepath(img, gs, path);
				path = nil;
			"b*" =>
				path = ref PathSeg.Close :: path;
				fillpath(img, gs, path, 1);
				strokepath(img, gs, path);
				path = nil;
			"n" =>
				path = nil;

			# ---- Clipping ----
			"W" or "W*" =>
				if(path != nil && display != nil){
					evenodd := 0;
					if(op == "W*") evenodd = 1;
					gs.clipmask = buildclipmask(img, gs, path, evenodd);
					gs.cliprect = clipbounds(gs, path);
				}

			# ---- Color operators ----
			"g" =>
				if(operands != nil){
					gray := hd operands;
					operands = nil;
					v := clampcolor(gray);
					gs.fillcolor = (v, v, v);
				}
			"G" =>
				if(operands != nil){
					gray := hd operands;
					operands = nil;
					v := clampcolor(gray);
					gs.strokecolor = (v, v, v);
				}
			"rg" =>
				if(lenlist(operands) >= 3){
					(bv, gv, rv, nil) := pop3(operands);
					operands = nil;
					gs.fillcolor = (clampcolor(rv), clampcolor(gv), clampcolor(bv));
				}
			"RG" =>
				if(lenlist(operands) >= 3){
					(bv, gv, rv, nil) := pop3(operands);
					operands = nil;
					gs.strokecolor = (clampcolor(rv), clampcolor(gv), clampcolor(bv));
				}
			"k" =>
				if(lenlist(operands) >= 4){
					(kk, yy, mm, cc, nil) := pop4(operands);
					operands = nil;
					(r, g, b) := cmyk2rgb(cc, mm, yy, kk);
					gs.fillcolor = (r, g, b);
				}
			"K" =>
				if(lenlist(operands) >= 4){
					(kk, yy, mm, cc, nil) := pop4(operands);
					operands = nil;
					(r, g, b) := cmyk2rgb(cc, mm, yy, kk);
					gs.strokecolor = (r, g, b);
				}
			"cs" =>
				# Set fill color space
				if(stroperands != nil){
					csname := hd stroperands;
					gs.fillcscomps = resolvecscomps(doc, csname, resources);
				}
				stroperands = nil;
			"CS" =>
				# Set stroke color space
				if(stroperands != nil){
					csname := hd stroperands;
					gs.strokecscomps = resolvecscomps(doc, csname, resources);
				}
				stroperands = nil;
			"sc" or "scn" =>
				# set fill color in current space
				n := lenlist(operands);
				if(n >= 4 && gs.fillcscomps == 4){
					# CMYK
					(kk, yy, mm, cc, nil) := pop4(operands);
					(r, g, b) := cmyk2rgb(cc, mm, yy, kk);
					gs.fillcolor = (r, g, b);
				} else if(n >= 3){
					(bv, gv, rv, nil) := pop3(operands);
					gs.fillcolor = (clampcolor(rv), clampcolor(gv), clampcolor(bv));
				} else if(n >= 1){
					v := clampcolor(hd operands);
					gs.fillcolor = (v, v, v);
				}
				operands = nil;
				stroperands = nil;
			"SC" or "SCN" =>
				n := lenlist(operands);
				if(n >= 4 && gs.strokecscomps == 4){
					# CMYK
					(kk, yy, mm, cc, nil) := pop4(operands);
					(r, g, b) := cmyk2rgb(cc, mm, yy, kk);
					gs.strokecolor = (r, g, b);
				} else if(n >= 3){
					(bv, gv, rv, nil) := pop3(operands);
					gs.strokecolor = (clampcolor(rv), clampcolor(gv), clampcolor(bv));
				} else if(n >= 1){
					v := clampcolor(hd operands);
					gs.strokecolor = (v, v, v);
				}
				operands = nil;
				stroperands = nil;

			# ---- Text operators (Phase 2) ----
			"BT" =>
				gs.tm[0] = 1.0; gs.tm[1] = 0.0;
				gs.tm[2] = 0.0; gs.tm[3] = 1.0;
				gs.tm[4] = 0.0; gs.tm[5] = 0.0;
				gs.tlm[0:] = gs.tm;
			"ET" =>
				# the glyphs shown to clip by (Tr 4-7) are the clip
				if(gs.textclip != nil){
					if(gs.clipmask != nil)
						intersectmask(gs.textclip, gs.clipmask);
					gs.clipmask = gs.textclip;
					gs.textclip = nil;
				}
			"Td" =>
				if(lenlist(operands) >= 2){
					(ty, tx, nil) := pop2(operands);
					operands = nil;
					delta4 := tx * gs.tlm[0] + ty * gs.tlm[2];
					delta5 := tx * gs.tlm[1] + ty * gs.tlm[3];
					gs.tlm[4] += delta4;
					gs.tlm[5] += delta5;
					gs.tm[0:] = gs.tlm;
				}
			"TD" =>
				if(lenlist(operands) >= 2){
					(ty, tx, nil) := pop2(operands);
					operands = nil;
					gs.leading = -ty;
					gs.tlm[4] += tx * gs.tlm[0] + ty * gs.tlm[2];
					gs.tlm[5] += tx * gs.tlm[1] + ty * gs.tlm[3];
					gs.tm[0:] = gs.tlm;
				}
			"Tm" =>
				if(lenlist(operands) >= 6){
					(f, e, dd, cc, b, a, nil) := pop6(operands);
					operands = nil;
					gs.tm[0] = a; gs.tm[1] = b;
					gs.tm[2] = cc; gs.tm[3] = dd;
					gs.tm[4] = e; gs.tm[5] = f;
					gs.tlm[0:] = gs.tm;
				}
			"T*" =>
				gs.tlm[4] += (-gs.leading) * gs.tlm[2];
				gs.tlm[5] += (-gs.leading) * gs.tlm[3];
				gs.tm[0:] = gs.tlm;
			"Tf" =>
				if(stroperands != nil){
					gs.fontname = hd stroperands;
					stroperands = tl stroperands;
					curfont = fontmaplookup(fontmap, gs.fontname);
				}
				if(operands != nil){
					gs.fontsize = hd operands;
					operands = nil;
				}
			"Tc" =>
				if(operands != nil){
					gs.charspace = hd operands;
					operands = nil;
				}
			"Tw" =>
				if(operands != nil){
					gs.wordspace = hd operands;
					operands = nil;
				}
			"Tz" =>
				if(operands != nil){
					gs.hscale = hd operands;
					operands = nil;
				}
			"TL" =>
				if(operands != nil){
					gs.leading = hd operands;
					operands = nil;
				}
			"Ts" =>
				if(operands != nil){
					gs.rise = hd operands;
					operands = nil;
				}
			"Tr" =>
				if(operands != nil){
					gs.rendermode = int (hd operands);
					operands = nil;
				}
			"Tj" =>
				if(stroperands != nil){
					s := hd stroperands;
					stroperands = nil;
					showtext(doc, img, gs, s, fontof(curfont), resources, depth);
				}
			"TJ" =>
				if(tjarraypos >= 0){
					showtj(doc, img, gs, data, tjarraypos, fontof(curfont), resources, depth);
					tjarraypos = -1;
				}
			"'" =>
				# newline + show
				gs.tlm[4] += (-gs.leading) * gs.tlm[2];
				gs.tlm[5] += (-gs.leading) * gs.tlm[3];
				gs.tm[0:] = gs.tlm;
				if(stroperands != nil){
					s := hd stroperands;
					stroperands = nil;
					showtext(doc, img, gs, s, fontof(curfont), resources, depth);
				}
			"\"" =>
				# set word/char space, newline, show
				if(lenlist(operands) >= 2){
					(ac, aw, nil) := pop2(operands);
					operands = nil;
					gs.wordspace = aw;
					gs.charspace = ac;
				}
				gs.tlm[4] += (-gs.leading) * gs.tlm[2];
				gs.tlm[5] += (-gs.leading) * gs.tlm[3];
				gs.tm[0:] = gs.tlm;
				if(stroperands != nil){
					s := hd stroperands;
					stroperands = nil;
					showtext(doc, img, gs, s, fontof(curfont), resources, depth);
				}

			# ---- XObject rendering ----
			"Do" =>
				if(stroperands != nil && resources != nil){
					xoname := hd stroperands;
					stroperands = nil;
					{
						xobjs := dictget(resources.dval, "XObject");
						if(xobjs != nil)
							xobjs = resolve(doc, xobjs);
						if(xobjs != nil){
							xoref := dictget(xobjs.dval, xoname);
							if(xoref != nil){
								xobj := resolve(doc, xoref);
								if(xobj != nil){
									subtype := dictget(xobj.dval, "Subtype");
									if(subtype == nil)
										subtype = dictget(xobj.dval, "S");
									stname := "";
									if(subtype != nil && subtype.kind == Oname)
										stname = subtype.sval;
									if(stname == "Image")
										renderimgxobj(doc, img, gs, xobj);
									else if(stname == "Form")
										renderformxobj(doc, img, gs, xobj, resources, fontmap, depth);
								}
							}
						}
					}
				} else
					stroperands = nil;

			# ---- Inline images ----
			"BI" =>
				pos = skipinlineimage(data, pos);

			# ---- Marked content ----
			"BDC" or "BMC" or "EMC" or "MP" or "DP" =>
				stroperands = nil;
				operands = nil;

			* =>
				# Unknown operator
				operands = nil;
				stroperands = nil;
			}
			continue;
		}

		# Skip unrecognized byte
		pos++;
	}
}

# ---- Text rendering ----

NOCLIP: con 1<<30;

# The clip's bounds on the image after clipping to path: exactly the
# clip when it is a rectangle, as most are.
clipbounds(gs: ref GState, path: list of ref PathSeg): Rect
{
	pts := flattenpath(reversepath(path), gs.ctm);
	if(pts == nil || len pts == 0)
		return gs.cliprect;
	r := Rect(pts[0], pts[0]);
	for(i := 1; i < len pts; i++){
		p := pts[i];
		if(p.x < r.min.x) r.min.x = p.x;
		if(p.y < r.min.y) r.min.y = p.y;
		if(p.x > r.max.x) r.max.x = p.x;
		if(p.y > r.max.y) r.max.y = p.y;
	}
	(c, ok) := r.clip(gs.cliprect);
	if(!ok)
		return Rect((0, 0), (0, 0));
	return c;
}

# ---- Text ----
#
# Every glyph is drawn from an outline (outlinefont(2)) through the
# text rendering matrix, at the device's resolution, placed by the
# PDF's own widths: a font embedded is drawn as itself, one not
# embedded by a face of its kind with the same metrics (TeX Gyre
# Termes, Heros and Cursor for Times, Helvetica and Courier), fitted
# to the PDF's widths.  A Type 3 font's glyphs are content streams.

# Show a string of character codes in fm, advancing the text matrix.
showtext(doc: ref PdfDoc, img: ref Image, gs: ref GState, s: string, fm: ref PdfFont,
	resources: ref PdfObj, depth: int)
{
	if(s == nil)
		return;
	if(fm == nil)
		fm = deffont(doc);
	fontload(doc, fm);
	mode := gs.rendermode;
	visible := mode != 3 && mode != 7 && gs.alpha >= 0.004 && img != nil;
	colimg: ref Image;
	if(visible){
		(r, g, b) := gs.fillcolor;
		if(mode == 1 || mode == 5)
			(r, g, b) = gs.strokecolor;
		colimg = textcolor(r, g, b, gs.alpha);
		if(colimg == nil)
			visible = 0;
	}
	tfs := gs.fontsize;
	th := gs.hscale / 100.0;
	ctm := gs.ctm;
	tm := gs.tm;
	# text space to device, without the translation
	a := tm[0]*ctm[0] + tm[1]*ctm[2];
	b := tm[0]*ctm[1] + tm[1]*ctm[3];
	c := tm[2]*ctm[0] + tm[3]*ctm[2];
	d := tm[2]*ctm[1] + tm[3]*ctm[3];
	# modes 4-7 add the glyphs to the clip, at ET
	clipping := mode >= 4 && img != nil && display != nil && fm.kind != Ftype3;
	if(clipping && gs.textclip == nil){
		gs.textclip = display.newimage(img.r, drawm->GREY8, 0, drawm->Black);
		if(gs.textclip == nil)
			clipping = 0;
	}
	m := array[4] of real;
	clipr: Rect;
	clipped := 0;
	if(visible){
		(cr, ok) := img.clipr.clip(gs.cliprect);
		if(!ok)
			visible = 0;
		else if(!cr.eq(img.clipr)){
			clipr = img.clipr;
			img.clipr = cr;
			clipped = 1;
		}
	}
	for(i := 0; i < len s; ){
		(code, step) := nextcode(fm, s, i);
		i += step;
		cid := code;
		if(fm.cidmap != nil)
			cid = cmapcid(fm.cidmap, code);
		if(visible && fm.kind == Ftype3)
			type3glyph(doc, img, gs, fm, code, resources, depth);
		else if(visible || clipping){
			(face, gid, hs) := glyphof(fm, code, cid);
			if(face != nil && gid > 0){
				ox := tm[4] + gs.rise*tm[2];
				oy := tm[5] + gs.rise*tm[3];
				k := tfs / real face.upem;
				m[0] = a*th*hs*k;
				m[1] = b*th*hs*k;
				m[2] = c*k;
				m[3] = d*k;
				x := ox*ctm[0] + oy*ctm[2] + ctm[4];
				y := ox*ctm[1] + oy*ctm[3] + ctm[5];
				if(visible)
					face.drawglyphm(gid, m, img, x, y, colimg);
				if(clipping)
					face.drawglyphm(gid, m, gs.textclip, x, y, display.white);
			}
		}
		tx := (codewidth(fm, cid)*tfs + gs.charspace) * th;
		if(step == 1 && code == 32)
			tx += gs.wordspace * th;
		tm[4] += tx*tm[0];
		tm[5] += tx*tm[1];
	}
	if(clipped)
		img.clipr = clipr;
}

# A TJ array: strings shown, numbers moving the text back (thousandths
# of the font size).
showtj(doc: ref PdfDoc, img: ref Image, gs: ref GState, data: array of byte, pos: int,
	fm: ref PdfFont, resources: ref PdfObj, depth: int)
{
	pos++;	# skip '['
	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data)
			break;
		c := int data[pos];
		if(c == ']')
			break;
		if(c == '(' || c == '<'){
			s: string;
			if(c == '(')
				(s, pos) = readlitstr(data, pos);
			else
				(s, pos) = readhexstr(data, pos);
			showtext(doc, img, gs, s, fm, resources, depth);
			continue;
		}
		if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'){
			val: real;
			(val, pos) = readreal(data, pos);
			tx := -val / 1000.0 * gs.fontsize * gs.hscale / 100.0;
			gs.tm[4] += tx * gs.tm[0];
			gs.tm[5] += tx * gs.tm[1];
			continue;
		}
		pos++;
	}
}

# a Type 3 glyph: its content stream, through the font matrix
type3glyph(doc: ref PdfDoc, img: ref Image, gs: ref GState, fm: ref PdfFont, code: int,
	resources: ref PdfObj, depth: int)
{
	if(depth > 6 || code < 0 || code > 255 || fm.t3procs == nil)
		return;
	if(fm.t3procs[code] == nil){
		name := fm.names[code];
		if(name == nil || fm.charprocs == nil)
			return;
		p := resolve(doc, dictget(fm.charprocs.dval, name));
		if(p == nil || p.kind != Ostream)
			return;
		(data, nil) := decompressstream(p);
		if(data == nil)
			data = array[0] of byte;
		fm.t3procs[code] = data;
	}
	data := fm.t3procs[code];
	if(len data == 0)
		return;
	g := copygstate(gs);
	th := gs.hscale / 100.0;
	ts := array[] of {gs.fontsize*th, 0.0, 0.0, gs.fontsize, 0.0, gs.rise};
	g.ctm[0:] = matmul(fm.fmatrix, matmul(ts, matmul(gs.tm, gs.ctm)));
	res := fm.t3res;
	if(res == nil)
		res = resources;
	{
		execcontentstream(doc, img, data, g, res, buildfontmapres(doc, res), depth + 1);
	} exception {
	"*" =>
		;
	}
}

textcolor(r, g, b: int, alpha: real): ref Image
{
	if(alpha >= 0.999)
		return getcolor(r, g, b);
	a := int (alpha * 255.0 + 0.5);
	rgba := drawm->setalpha((r << 24) | (g << 16) | (b << 8) | 16rFF, a);
	return display.newimage(Rect(Point(0,0), Point(1,1)), drawm->RGBA32, 1, rgba);
}

# A code's advance, in text space at font size 1.
codewidth(fm: ref PdfFont, code: int): real
{
	if(fm.kind == Ftype3){
		if(fm.t3widths != nil && code >= 0 && code < len fm.t3widths)
			return fm.t3widths[code] * fm.fmatrix[0];
		return 0.0;
	}
	w := -1;
	if(fm.widths != nil && code >= 0 && code < len fm.widths)
		w = fm.widths[code];
	if(w < 0)
		w = fm.dw;
	return real w / 1000.0;
}

# The face and glyph for a code, and how much the glyph is narrowed
# to fit the PDF's width (a substitute face).
glyphof(fm: ref PdfFont, code, cid: int): (ref OutlineFont->Face, int, real)
{
	if(fm.kind == Fsimple){
		if(fm.code2gid == nil || code < 0 || code > 255)
			return (nil, 0, 1.0);
		g := fm.code2gid[code];
		if(g >= FALLBACK)
			return (substface(SUBSTFALLBACK), g - FALLBACK, fm.hs);
		return (fm.face, g, fm.hs);
	}
	# CID
	face := fm.face;
	if(face == nil)
		return (nil, 0, 1.0);
	if(fm.subst){
		u := unicodeof(fm, code);
		g := face.lookup(u);
		if(g < 0){
			fb := substface(SUBSTFALLBACK);
			if(fb != nil && (g = fb.lookup(u)) > 0)
				return (fb, g, 1.0);
			return (nil, 0, 1.0);
		}
		return (face, g, 1.0);
	}
	if(face.iscid)
		return (face, face.cidtogid(cid), 1.0);
	if(fm.cid2gid != nil){
		if(cid < len fm.cid2gid)
			return (face, fm.cid2gid[cid], 1.0);
		return (face, 0, 1.0);
	}
	return (face, cid, 1.0);	# a program not CID-keyed: CIDs are GIDs
}

# The code at s[i], and how many bytes it is: the codespace range it
# falls in (shortest first), else one or two bytes by the font.
nextcode(fm: ref PdfFont, s: string, i: int): (int, int)
{
	if(fm.codespace != nil){
		c := 0;
		for(n := 1; n <= 4 && i + n <= len s; n++){
			c = c<<8 | (s[i+n-1] & 16rFF);
			for(k := 0; k < len fm.codespace; k++){
				(nb, lo, hi) := fm.codespace[k];
				if(nb == n && inrange(c, lo, hi, n))
					return (c, n);
			}
		}
		# in no range: one byte
		return (s[i] & 16rFF, 1);
	}
	if(fm.twobyte && i + 1 < len s)
		return ((s[i] & 16rFF)<<8 | (s[i+1] & 16rFF), 2);
	return (s[i] & 16rFF, 1);
}

# a codespace range holds a code if each of its bytes is within the
# range's bytes in that place
inrange(c, lo, hi, n: int): int
{
	for(k := 0; k < n; k++){
		b := (c >> (8*k)) & 16rFF;
		if(b < ((lo >> (8*k)) & 16rFF) || b > ((hi >> (8*k)) & 16rFF))
			return 0;
	}
	return 1;
}

# A CID from an embedded CMap's ranges.
cmapcid(m: list of ref CMapEntry, code: int): int
{
	for(; m != nil; m = tl m)
		if(code >= (hd m).lo && code <= (hd m).hi)
			return (hd m).unicode + code - (hd m).lo;
	return code;
}

# An embedded CMap (a Type0 font's Encoding): whether its codes are
# two bytes (its codespacerange), and its cidrange and cidchar
# mappings, as CMapEntries whose unicode is the CID.
parseencoding(text: string): (array of (int, int, int), list of ref CMapEntry)
{
	cs: list of (int, int, int);
	ncs := 0;
	i: int;
	for(p := 0; (i = strindexfrom(text, "begincodespacerange", p)) >= 0; ){
		e := strindexfrom(text, "endcodespacerange", i);
		if(e < 0)
			e = len text;
		q := i + 19;
		for(;;){
			while(q < e && text[q] != '<')
				q++;
			if(q >= e)
				break;
			k := q + 1;
			while(k < e && text[k] != '>')
				k++;
			nb := (k - q) / 2;
			(lo, q1) := cmaphex(text, q);
			if(q1 < 0 || q1 > e) break;
			(hi, q2) := cmaphex(text, q1);
			if(q2 < 0 || q2 > e) break;
			cs = (nb, lo, hi) :: cs;
			ncs++;
			q = q2;
		}
		p = e;
	}
	codespace: array of (int, int, int);
	if(ncs > 0){
		codespace = array[ncs] of (int, int, int);
		for(; cs != nil; cs = tl cs)
			codespace[--ncs] = hd cs;
	}
	m: list of ref CMapEntry;
	for(p = 0; (i = strindexfrom(text, "begincidrange", p)) >= 0; ){
		e := strindexfrom(text, "endcidrange", i);
		if(e < 0)
			e = len text;
		q := i + 13;
		for(;;){
			(lo, q1) := cmaphex(text, q);
			if(q1 < 0 || q1 > e) break;
			(hi, q2) := cmaphex(text, q1);
			if(q2 < 0 || q2 > e) break;
			(c, q3) := cmapint(text, q2);
			if(q3 < 0 || q3 > e) break;
			m = ref CMapEntry(lo, hi, c) :: m;
			q = q3;
		}
		p = e;
	}
	for(p = 0; (i = strindexfrom(text, "begincidchar", p)) >= 0; ){
		e := strindexfrom(text, "endcidchar", i);
		if(e < 0)
			e = len text;
		q := i + 12;
		for(;;){
			(lo, q1) := cmaphex(text, q);
			if(q1 < 0 || q1 > e) break;
			(c, q2) := cmapint(text, q1);
			if(q2 < 0 || q2 > e) break;
			m = ref CMapEntry(lo, lo, c) :: m;
			q = q2;
		}
		p = e;
	}
	return (codespace, m);
}

# a <hex> code after blanks, or -1
cmaphex(s: string, p: int): (int, int)
{
	while(p < len s && (s[p] == ' ' || s[p] == '\t' || s[p] == '\r' || s[p] == '\n'))
		p++;
	if(p >= len s || s[p] != '<')
		return (0, -1);
	return parsecmaphex(s, p);
}

cmapint(s: string, p: int): (int, int)
{
	while(p < len s && (s[p] == ' ' || s[p] == '\t' || s[p] == '\r' || s[p] == '\n'))
		p++;
	if(p >= len s || s[p] < '0' || s[p] > '9')
		return (0, -1);
	v := 0;
	while(p < len s && s[p] >= '0' && s[p] <= '9')
		v = v*10 + s[p++] - '0';
	return (v, p);
}

strindex(s, t: string): int
{
	return strindexfrom(s, t, 0);
}

strindexfrom(s, t: string, from: int): int
{
	for(i := from; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}

# The Unicode value of a code, as the font says: ToUnicode, else the
# encoding's glyph names, else the code.
unicodeof(fm: ref PdfFont, code: int): int
{
	if(fm.entries != nil){
		for(e := fm.entries; e != nil; e = tl e)
			if(code >= (hd e).lo && code <= (hd e).hi)
				return (hd e).unicode + code - (hd e).lo;
	}
	if(fm.code2uni != nil && code >= 0 && code < len fm.code2uni && fm.code2uni[code] > 0)
		return fm.code2uni[code];
	return code;
}

# ---- Fonts ----

Fsimple, Fcid, Ftype3: con iota;
FALLBACK: con 1<<24;	# code2gid: a glyph of the fallback face

# The faces standing in for fonts not embedded: serif, sans, mono, each
# regular, bold, italic, bold italic; and one for everything else (the
# Symbol and ZapfDingbats fonts, and characters the others lack).
SUBSTSERIF, SUBSTSANS, SUBSTMONO: con iota*4;
SUBSTFALLBACK: con 12;
substfiles := array[] of {
	"texgyre/texgyretermes-regular.otf", "texgyre/texgyretermes-bold.otf",
	"texgyre/texgyretermes-italic.otf", "texgyre/texgyretermes-bolditalic.otf",
	"texgyre/texgyreheros-regular.otf", "texgyre/texgyreheros-bold.otf",
	"texgyre/texgyreheros-italic.otf", "texgyre/texgyreheros-bolditalic.otf",
	"texgyre/texgyrecursor-regular.otf", "texgyre/texgyrecursor-bold.otf",
	"texgyre/texgyrecursor-italic.otf", "texgyre/texgyrecursor-bolditalic.otf",
	"ttf/dejavu/DejaVuSans.ttf",
};
substfaces: array of ref OutlineFont->Face;

substface(i: int): ref OutlineFont->Face
{
	if(outlinefont == nil)
		return nil;
	if(substfaces == nil)
		substfaces = array[len substfiles] of ref OutlineFont->Face;
	if(substfaces[i] == nil){
		data := readfontfile("/fonts/" + substfiles[i]);
		if(data != nil)
			(substfaces[i], nil) = outlinefont->open(data, "ttf");
		if(substfaces[i] == nil && i != SUBSTFALLBACK)
			substfaces[i] = substface(SUBSTFALLBACK);
	}
	return substfaces[i];
}

readfontfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, dir) := sys->fstat(fd);
	if(ok != 0 || dir.length <= big 0 || dir.length > big (16*1024*1024))
		return nil;
	data := array[int dir.length] of byte;
	for(n := 0; n < len data; ){
		r := sys->read(fd, data[n:], len data - n);
		if(r <= 0)
			return nil;
		n += r;
	}
	return data;
}

# the face for a font not embedded, by its name and descriptor's flags
substfor(basefont: string, flags: int): int
{
	n := "";
	for(i := 0; i < len basefont; i++){
		c := basefont[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		if(c != ' ' && c != '-' && c != '_' && c != ',')
			n[len n] = c;
	}
	if(contains(n, "symbol") || contains(n, "dingbat") || contains(n, "wingding"))
		return SUBSTFALLBACK;
	fam := SUBSTSANS;
	if(flags & 1 || contains(n, "courier") || contains(n, "mono") || contains(n, "consol") ||
	   contains(n, "typewriter") || contains(n, "fixed") || contains(n, "lucidaconsole"))
		fam = SUBSTMONO;
	else if(!contains(n, "sans") && (flags & 2 || contains(n, "times") || contains(n, "roman") ||
	   contains(n, "serif") || contains(n, "georgia") || contains(n, "garamond") ||
	   contains(n, "palatino") || contains(n, "bookman") || contains(n, "minion") ||
	   contains(n, "cambria") || contains(n, "century") || contains(n, "baskerville") ||
	   contains(n, "bodoni") || contains(n, "schoolbook") || contains(n, "cmr")))
		fam = SUBSTSERIF;
	style := 0;
	if(flags & (1<<18) || contains(n, "bold") || contains(n, "black") || contains(n, "heavy") ||
	   contains(n, "demi") || contains(n, "semibold"))
		style |= 1;
	if(flags & 64 || contains(n, "italic") || contains(n, "oblique") || contains(n, "slant"))
		style |= 2;
	return fam + style;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

# A font from its dictionary, as far as can be known without its
# program: the kind, codes, encoding, widths, ToUnicode.  The face is
# loaded when the first glyph is wanted (fontload).
newfont(doc: ref PdfDoc, fontobj: ref PdfObj): ref PdfFont
{
	fm := ref PdfFont;
	fm.kind = Fsimple;
	fm.dw = 0;
	fm.hs = 1.0;
	fm.basefont = "Helvetica";
	fm.fontobj = fontobj;
	if(fontobj == nil){
		fm.widths = array[256] of { * => -1 };
		fm.names = encnames("StandardEncoding");
		fm.code2uni = namesunicode(fm.names);
		return fm;
	}
	subtype := nameof(doc, dictget(fontobj.dval, "Subtype"));
	bf := nameof(doc, dictget(fontobj.dval, "BaseFont"));
	if(bf != nil){
		if(len bf > 7 && bf[6] == '+')
			bf = bf[7:];
		fm.basefont = bf;
	}

	# ToUnicode
	tu := resolve(doc, dictget(fontobj.dval, "ToUnicode"));
	if(tu != nil && tu.kind == Ostream){
		(cmapdata, derr) := decompressstream(tu);
		if(cmapdata != nil && derr == nil){
			(tb, ent) := parsecmap(string2(cmapdata));
			if(tb && subtype == "Type0")
				fm.twobyte = 1;
			fm.entries = ent;
		}
	}

	case subtype {
	"Type0" =>
		fm.kind = Fcid;
		fm.twobyte = 1;
		fm.dw = 1000;
		cf := fontobj;
		desc := resolve(doc, dictget(fontobj.dval, "DescendantFonts"));
		if(desc != nil && desc.kind == Oarray && desc.aval != nil)
			cf = resolve(doc, hd desc.aval);
		if(cf == nil)
			cf = fontobj;
		fm.cidfont = cf;
		enc := resolve(doc, dictget(fontobj.dval, "Encoding"));
		if(enc != nil && enc.kind == Ostream){
			(cm, nil) := decompressstream(enc);
			if(cm != nil)
				(fm.codespace, fm.cidmap) = parseencoding(string2(cm));
		}
		dwo := resolve(doc, dictget(cf.dval, "DW"));
		if(dwo != nil && (dwo.kind == Oint || dwo.kind == Oreal))
			fm.dw = numof(dwo);
		wo := resolve(doc, dictget(cf.dval, "W"));
		if(wo != nil && wo.kind == Oarray)
			fm.widths = parsepdfwidths(resolveall(doc, wo.aval), fm.dw);
		return fm;
	"Type3" =>
		fm.kind = Ftype3;
		fm.fmatrix = array[] of {0.001, 0.0, 0.0, 0.001, 0.0, 0.0};
		mo := resolve(doc, dictget(fontobj.dval, "FontMatrix"));
		if(mo != nil && mo.kind == Oarray && lenlistobj(mo.aval) == 6){
			i := 0;
			for(l := mo.aval; l != nil; l = tl l)
				fm.fmatrix[i++] = numreal(resolve(doc, hd l));
		}
		fm.charprocs = resolve(doc, dictget(fontobj.dval, "CharProcs"));
		fm.t3res = resolve(doc, dictget(fontobj.dval, "Resources"));
		fm.t3procs = array[256] of array of byte;
		fm.t3widths = array[256] of { * => 0.0 };
		(fc, wl) := firstwidths(doc, fontobj);
		for(; wl != nil && fc < 256; wl = tl wl){
			if(fc >= 0)
				fm.t3widths[fc] = numreal(resolve(doc, hd wl));
			fc++;
		}
		fm.names = simplenames(doc, fontobj, nil);
		fm.code2uni = namesunicode(fm.names);
		return fm;
	}

	# simple: Type1, MMType1, TrueType
	fm.widths = array[256] of { * => -1 };
	(fc, wl) := firstwidths(doc, fontobj);
	for(; wl != nil && fc < 256; wl = tl wl){
		if(fc >= 0)
			fm.widths[fc] = numof(resolve(doc, hd wl));
		fc++;
	}
	fd := resolve(doc, dictget(fontobj.dval, "FontDescriptor"));
	if(fd != nil){
		mw := resolve(doc, dictget(fd.dval, "MissingWidth"));
		if(mw != nil)
			fm.dw = numof(mw);
	}
	base: array of string;
	case substfor(fm.basefont, 0) {
	SUBSTFALLBACK =>
		if(contains(lower(fm.basefont), "dingbat"))
			base = encnames("ZapfDingbats");
		else if(contains(lower(fm.basefont), "symbol"))
			base = encnames("Symbol");
	}
	fm.names = simplenames(doc, fontobj, base);
	fm.code2uni = namesunicode(fm.names);
	return fm;
}

# The glyph name for each code of a simple font: the Encoding (a name,
# or a dictionary of a BaseEncoding and Differences), over base (the
# font's own encoding, when known; nil entries where only the font
# program knows).
simplenames(doc: ref PdfDoc, fontobj: ref PdfObj, base: array of string): array of string
{
	names := array[256] of string;
	if(base != nil)
		names[0:] = base;
	enc := resolve(doc, dictget(fontobj.dval, "Encoding"));
	if(enc == nil)
		return names;
	if(enc.kind == Oname){
		if((e := encnames(enc.sval)) != nil)
			names[0:] = e;
		return names;
	}
	if(enc.kind != Odict)
		return names;
	be := nameof(doc, dictget(enc.dval, "BaseEncoding"));
	if(be != nil && (e := encnames(be)) != nil)
		names[0:] = e;
	diffs := resolve(doc, dictget(enc.dval, "Differences"));
	if(diffs != nil && diffs.kind == Oarray){
		c := 0;
		for(l := diffs.aval; l != nil; l = tl l){
			o := resolve(doc, hd l);
			if(o == nil)
				continue;
			if(o.kind == Oint)
				c = o.ival;
			else if(o.kind == Oname){
				if(c >= 0 && c < 256)
					names[c] = o.sval;
				c++;
			}
		}
	}
	return names;
}

encnames(name: string): array of string
{
	if(pdfenc == nil){
		pdfenc = load Pdfenc Pdfenc->PATH;
		if(pdfenc == nil)
			return nil;
	}
	return pdfenc->encoding(name);
}

namesunicode(names: array of string): array of int
{
	if(names == nil || pdfenc == nil && encnames("StandardEncoding") == nil)
		return nil;
	u := array[len names] of int;
	for(i := 0; i < len names; i++)
		u[i] = pdfenc->unicode(names[i]);
	return u;
}

# The face and the glyph for each code, made the first time the font
# is drawn or measured.
fontload(doc: ref PdfDoc, fm: ref PdfFont)
{
	if(fm.loaded)
		return;
	fm.loaded = 1;
	if(fm.kind == Ftype3 || outlinefont == nil)
		return;
	df := fm.fontobj;
	if(fm.cidfont != nil)
		df = fm.cidfont;
	flags := 0;
	fdesc: ref PdfObj;
	if(df != nil)
		fdesc = resolve(doc, dictget(df.dval, "FontDescriptor"));
	if(fdesc != nil){
		flags = dictgetintres(doc, fdesc.dval, "Flags");
		(fm.face, fm.ttf) = embeddedface(doc, fdesc);
	}
	if(fm.face != nil)
		fm.embedded = fm.face;
	else {
		fm.face = substface(substfor(fm.basefont, flags));
		fm.subst = 1;
	}
	if(fm.face == nil)
		return;

	if(fm.kind == Fcid){
		cg := resolve(doc, dictget(fm.cidfont.dval, "CIDToGIDMap"));
		if(cg != nil && cg.kind == Ostream){
			(m, nil) := decompressstream(cg);
			if(m != nil){
				fm.cid2gid = array[len m / 2] of int;
				for(i := 0; i < len fm.cid2gid; i++)
					fm.cid2gid[i] = int m[2*i] << 8 | int m[2*i+1];
			}
		}
		return;
	}

	face := fm.face;
	symbolic := (flags & 4) != 0 && (flags & 32) == 0;
	fm.code2gid = array[256] of { * => 0 };
	fb := substface(SUBSTFALLBACK);
	for(c := 0; c < 256; c++){
		name := fm.names[c];
		g := -1;
		if(!fm.subst && !fm.ttf){
			# Type 1, CFF: by name, else the font's own encoding
			if(name != nil)
				g = face.namedgid(name);
			if(g < 0)
				g = face.lookup(c);
		} else if(!fm.subst){
			# TrueType: by name through Unicode, unless symbolic
			if(name != nil && !symbolic)
				g = face.lookup(fm.code2uni[c]);
			if(g <= 0)
				g = face.lookup(16rF000 + c);
			if(g <= 0)
				g = face.lookup(c);
			if(g <= 0 && name != nil)
				g = face.namedgid(name);
		} else {
			u := c;
			if(fm.code2uni != nil && fm.code2uni[c] > 0)
				u = fm.code2uni[c];
			else if(fm.entries != nil)
				u = unicodeof(fm, c);
			else if(name == nil && c < 32)
				u = -1;
			g = face.lookup(u);
			if(g <= 0 && fb != nil && fb != face && (g = fb.lookup(u)) > 0)
				g += FALLBACK;
		}
		if(g < 0)
			g = 0;
		fm.code2gid[c] = g;
	}
	# the widths the PDF does not give, from the face; a substitute
	# narrowed when the font it stands for is narrower
	pw := sw := 0.0;
	for(c = 0; c < 256; c++){
		g := fm.code2gid[c];
		f := face;
		if(g >= FALLBACK){
			f = fb;
			g -= FALLBACK;
		}
		if(g <= 0)
			continue;
		adv := f.advance(g, 1000.0);
		if(fm.widths[c] < 0 && fm.dw == 0)
			fm.widths[c] = int (adv + 0.5);
		else if(fm.subst && f == face && fm.widths[c] > 0 && adv > 0.0 && c > 32){
			pw += real fm.widths[c];
			sw += adv;
		}
	}
	if(sw > 0.0 && pw < 0.95*sw){
		fm.hs = pw / sw;
		if(fm.hs < 0.6)
			fm.hs = 0.6;
	}
}

# The font program a descriptor embeds: FontFile (Type 1), FontFile2
# (TrueType), FontFile3 (CFF, or OpenType); and whether it is TrueType.
embeddedface(doc: ref PdfDoc, fdesc: ref PdfObj): (ref OutlineFont->Face, int)
{
	fmt := "t1";
	ff := dictget(fdesc.dval, "FontFile");
	if(ff == nil){
		ff = dictget(fdesc.dval, "FontFile2");
		fmt = "ttf";
	}
	if(ff == nil){
		ff = dictget(fdesc.dval, "FontFile3");
		fmt = "cff";
	}
	ff = resolve(doc, ff);
	if(ff == nil || ff.kind != Ostream)
		return (nil, 0);
	if(fmt == "cff" && nameof(doc, dictget(ff.dval, "Subtype")) == "OpenType")
		fmt = "ttf";
	(data, err) := decompressstream(ff);
	if(data == nil || err != nil)
		return (nil, 0);
	if(fmt == "cff" && len data > 4 && string data[0:4] == "OTTO")
		fmt = "ttf";
	(f, nil) := outlinefont->open(data, fmt);
	if(f == nil && fmt == "t1" && len data > 4 && (string data[0:4] == "OTTO" || int data[0] == 1))
		(f, nil) = outlinefont->open(data, "cff");
	return (f, fmt == "ttf" && f != nil && f.glyphname(1) == nil);
}

# The font a page uses without naming one it has: Helvetica.
deffont(doc: ref PdfDoc): ref PdfFont
{
	if(doc.deffont == nil)
		doc.deffont = newfont(doc, nil);
	return doc.deffont;
}

firstwidths(doc: ref PdfDoc, fontobj: ref PdfObj): (int, list of ref PdfObj)
{
	w := resolve(doc, dictget(fontobj.dval, "Widths"));
	if(w == nil || w.kind != Oarray)
		return (0, nil);
	return (dictgetintres(doc, fontobj.dval, "FirstChar"), w.aval);
}

nameof(doc: ref PdfDoc, o: ref PdfObj): string
{
	o = resolve(doc, o);
	if(o == nil || o.kind != Oname)
		return nil;
	return o.sval;
}

numof(o: ref PdfObj): int
{
	if(o == nil)
		return 0;
	if(o.kind == Oint)
		return o.ival;
	if(o.kind == Oreal)
		return int o.rval;
	return 0;
}

numreal(o: ref PdfObj): real
{
	if(o == nil)
		return 0.0;
	if(o.kind == Oint)
		return real o.ival;
	if(o.kind == Oreal)
		return o.rval;
	return 0.0;
}

resolveall(doc: ref PdfDoc, l: list of ref PdfObj): list of ref PdfObj
{
	r: list of ref PdfObj;
	for(; l != nil; l = tl l)
		r = resolve(doc, hd l) :: r;
	o: list of ref PdfObj;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

lower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		r[len r] = tolower(s[i]);
	return r;
}

string2(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s[len s] = int d[i];
	return s;
}

tolower(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c - 'A' + 'a';
	return c;
}

# Skip past a TJ array [...] without parsing contents.
# Returns position after the closing ']'.
skiptjarray(data: array of byte, pos: int): int
{
	pos++;	# skip '['
	depth := 1;
	while(pos < len data && depth > 0){
		c := int data[pos];
		if(c == '[')
			depth++;
		else if(c == ']')
			depth--;
		else if(c == '('){
			# Skip literal string (handle escapes)
			pos++;
			while(pos < len data){
				sc := int data[pos];
				if(sc == '\\')
					pos++;
				else if(sc == ')')
					break;
				pos++;
			}
		}
		pos++;
	}
	return pos;
}

# ---- Path rendering ----

fillpath(img: ref Image, gs: ref GState, path: list of ref PathSeg, evenodd: int)
{
	if(path == nil)
		return;

	# Skip fully transparent fills (ca = 0)
	if(gs.alpha < 0.001)
		return;

	# Reverse path (it was built in reverse order)
	rpath := reversepath(path);

	(r, g, b) := gs.fillcolor;
	colimg := getcolor(r, g, b);
	if(colimg == nil)
		return;

	wind := ~0;
	if(evenodd)
		wind = 1;

	needalpha := gs.alpha < 0.999;

	if(gs.clipmask == nil && !needalpha){
		# No clip, fully opaque — fill directly (fast path)
		fillsubpaths(img, rpath, gs.ctm, wind, colimg);
	} else {
		# Need shape mask for alpha blending and/or clipping
		bbox := pathbbox(rpath, gs.ctm, img.r);
		if(bbox.dx() <= 0 || bbox.dy() <= 0) return;

		shapemask := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
		if(shapemask == nil) return;
		white := display.newimage(Rect(Point(0,0), Point(1,1)),
			drawm->GREY8, 1, drawm->White);
		if(white == nil) return;

		# Fill polygon into shape mask (white inside, black outside)
		fillsubpaths(shapemask, rpath, gs.ctm, wind, white);

		mask := shapemask;

		# Apply clip mask if present
		if(gs.clipmask != nil){
			combined := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
			if(combined == nil) return;
			combined.draw(bbox, shapemask, gs.clipmask, bbox.min);
			mask = combined;
		}

		# Scale mask by alpha for semi-transparent fills
		if(needalpha){
			aval := int (gs.alpha * 255.0);
			alphaimg := display.newimage(Rect(Point(0,0), Point(1,1)),
				drawm->GREY8, 1, aval);
			if(alphaimg != nil){
				# Multiply: draw alpha uniform through shape mask
				amask := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
				if(amask != nil){
					amask.draw(bbox, alphaimg, mask, bbox.min);
					mask = amask;
				}
			}
		}

		# Composite fill color through mask onto page
		img.draw(bbox, colimg, mask, bbox.min);
	}
}

# Fill subpaths of a reversed path onto a target image.
# For compound paths (multiple subpaths), uses a shape mask to correctly
# handle the winding rule — inner subpaths create holes via even-odd XOR
# or non-zero winding direction detection.
fillsubpaths(target: ref Image, rpath: list of ref PathSeg,
	ctm: array of real, wind: int, colimg: ref Image)
{
	# Collect all subpath point arrays
	allpts: list of array of Point;
	nsubpaths := 0;
	subpath: list of ref PathSeg;
	for(p := rpath; p != nil; p = tl p){
		seg := hd p;
		pick s := seg {
		Move =>
			if(subpath != nil){
				pts := flattenpath(reversepath(subpath), ctm);
				if(pts != nil && len pts >= 3){
					allpts = pts :: allpts;
					nsubpaths++;
				}
			}
			subpath = seg :: nil;
		* =>
			subpath = seg :: subpath;
		}
	}
	if(subpath != nil){
		pts := flattenpath(reversepath(subpath), ctm);
		if(pts != nil && len pts >= 3){
			allpts = pts :: allpts;
			nsubpaths++;
		}
	}

	if(nsubpaths == 0)
		return;

	# Reverse to get original path order
	revpts: list of array of Point;
	for(; allpts != nil; allpts = tl allpts)
		revpts = (hd allpts) :: revpts;
	allpts = revpts;

	# Single subpath — fast path, fill directly
	if(nsubpaths == 1){
		target.fillpoly(hd allpts, wind, colimg, Point(0,0));
		return;
	}

	# Multiple subpaths — compound fill via shape mask
	if(display == nil){
		# No display for mask creation — fall back to independent fills
		for(; allpts != nil; allpts = tl allpts)
			target.fillpoly(hd allpts, wind, colimg, Point(0,0));
		return;
	}

	# Compute bounding box of all subpaths
	minx := 16r7FFFFFFF; miny := 16r7FFFFFFF;
	maxx := -16r7FFFFFFF; maxy := -16r7FFFFFFF;
	for(pl := allpts; pl != nil; pl = tl pl){
		pts := hd pl;
		for(i := 0; i < len pts; i++){
			if(pts[i].x < minx) minx = pts[i].x;
			if(pts[i].y < miny) miny = pts[i].y;
			if(pts[i].x > maxx) maxx = pts[i].x;
			if(pts[i].y > maxy) maxy = pts[i].y;
		}
	}
	minx--; miny--; maxx++; maxy++;
	# Clip to target
	if(minx < target.r.min.x) minx = target.r.min.x;
	if(miny < target.r.min.y) miny = target.r.min.y;
	if(maxx > target.r.max.x) maxx = target.r.max.x;
	if(maxy > target.r.max.y) maxy = target.r.max.y;
	if(maxx <= minx || maxy <= miny)
		return;

	bbox := Rect(Point(minx, miny), Point(maxx, maxy));
	mask := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
	if(mask == nil){
		for(; allpts != nil; allpts = tl allpts)
			target.fillpoly(hd allpts, wind, colimg, Point(0,0));
		return;
	}
	white := display.newimage(Rect(Point(0,0), Point(1,1)),
		drawm->GREY8, 1, drawm->White);
	if(white == nil) return;
	black := display.newimage(Rect(Point(0,0), Point(1,1)),
		drawm->GREY8, 1, drawm->Black);
	if(black == nil) return;

	evenodd := wind == 1;
	firstsign := 0;

	for(pl = allpts; pl != nil; pl = tl pl){
		pts := hd pl;

		# Fill this subpath into a temp mask
		temp := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
		if(temp == nil) continue;
		temp.fillpoly(pts, ~0, white, Point(0,0));

		if(evenodd){
			# Even-odd: XOR each subpath onto the mask
			mask.drawop(bbox, temp, nil, bbox.min, drawm->SxorD);
		} else {
			# Non-zero winding: detect direction, fill or erase
			sign := polydir(pts);
			if(firstsign == 0)
				firstsign = sign;

			if(sign == firstsign || firstsign == 0){
				# Same direction as first subpath → additive (fill)
				mask.draw(bbox, white, temp, bbox.min);
			} else {
				# Opposite direction → subtractive (hole)
				mask.draw(bbox, black, temp, bbox.min);
			}
		}
	}

	# Composite fill color through compound mask onto target
	target.draw(bbox, colimg, mask, bbox.min);
}

# Compute signed area of a polygon to determine winding direction.
# Returns +1 for clockwise (in screen coords), -1 for counter-clockwise.
polydir(pts: array of Point): int
{
	n := len pts;
	if(n < 3) return 1;
	area := 0;
	for(i := 0; i < n; i++){
		j := (i + 1) % n;
		area += pts[i].x * pts[j].y;
		area -= pts[j].x * pts[i].y;
	}
	if(area >= 0) return 1;
	return -1;
}

strokepath(img: ref Image, gs: ref GState, path: list of ref PathSeg)
{
	if(path == nil)
		return;

	# Skip fully transparent strokes
	# PDF uses CA (uppercase) for stroke opacity; we store it in gs.alpha for now
	if(gs.alpha < 0.001)
		return;

	rpath := reversepath(path);

	(r, g, b) := gs.strokecolor;
	colimg := getcolor(r, g, b);
	if(colimg == nil)
		return;

	# Compute line width in pixels
	sx := math->sqrt(gs.ctm[0]*gs.ctm[0] + gs.ctm[1]*gs.ctm[1]);
	radius := int (gs.linewidth * sx / 2.0 + 0.5);
	if(radius < 0) radius = 0;

	# Map line cap
	end0 := drawm->Enddisc;
	case gs.linecap {
	0 => end0 = drawm->Endsquare;
	1 => end0 = drawm->Enddisc;
	2 => end0 = drawm->Endarrow;  # projecting square ~ arrow
	}

	needalpha := gs.alpha < 0.999;

	if(gs.clipmask == nil && !needalpha){
		# No clip, fully opaque — stroke directly (fast path)
		strokesubpaths(img, rpath, gs.ctm, end0, radius, colimg);
	} else {
		# Need shape mask for alpha blending and/or clipping
		bbox := pathbbox(rpath, gs.ctm, img.r);
		# Expand bbox by stroke radius
		bbox.min.x -= radius + 1;
		bbox.min.y -= radius + 1;
		bbox.max.x += radius + 1;
		bbox.max.y += radius + 1;
		# Re-clip to page
		if(bbox.min.x < img.r.min.x) bbox.min.x = img.r.min.x;
		if(bbox.min.y < img.r.min.y) bbox.min.y = img.r.min.y;
		if(bbox.max.x > img.r.max.x) bbox.max.x = img.r.max.x;
		if(bbox.max.y > img.r.max.y) bbox.max.y = img.r.max.y;
		if(bbox.dx() <= 0 || bbox.dy() <= 0) return;

		shapemask := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
		if(shapemask == nil) return;
		white := display.newimage(Rect(Point(0,0), Point(1,1)),
			drawm->GREY8, 1, drawm->White);
		if(white == nil) return;

		# Stroke into shape mask
		strokesubpaths(shapemask, rpath, gs.ctm, end0, radius, white);

		mask := shapemask;

		# Apply clip mask if present
		if(gs.clipmask != nil){
			combined := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
			if(combined == nil) return;
			combined.draw(bbox, shapemask, gs.clipmask, bbox.min);
			mask = combined;
		}

		# Scale mask by alpha for semi-transparent strokes
		if(needalpha){
			aval := int (gs.alpha * 255.0);
			alphaimg := display.newimage(Rect(Point(0,0), Point(1,1)),
				drawm->GREY8, 1, aval);
			if(alphaimg != nil){
				amask := display.newimage(bbox, drawm->GREY8, 0, drawm->Black);
				if(amask != nil){
					amask.draw(bbox, alphaimg, mask, bbox.min);
					mask = amask;
				}
			}
		}

		# Composite stroke color through mask onto page
		img.draw(bbox, colimg, mask, bbox.min);
	}
}

# Stroke subpaths of a reversed path onto a target image
strokesubpaths(target: ref Image, rpath: list of ref PathSeg,
	ctm: array of real, end0, radius: int, colimg: ref Image)
{
	subpath: list of ref PathSeg;
	for(p := rpath; p != nil; p = tl p){
		seg := hd p;
		pick s := seg {
		Move =>
			if(subpath != nil){
				pts := flattenpath(reversepath(subpath), ctm);
				if(pts != nil && len pts >= 2)
					target.poly(pts, end0, end0, radius, colimg, Point(0,0));
			}
			subpath = seg :: nil;
		* =>
			subpath = seg :: subpath;
		}
	}
	if(subpath != nil){
		pts := flattenpath(reversepath(subpath), ctm);
		if(pts != nil && len pts >= 2)
			target.poly(pts, end0, end0, radius, colimg, Point(0,0));
	}
}

# Reverse a path segment list
reversepath(path: list of ref PathSeg): list of ref PathSeg
{
	rev: list of ref PathSeg;
	for(; path != nil; path = tl path)
		rev = hd path :: rev;
	return rev;
}

# Flatten path to array of Points, transforming through CTM
flattenpath(path: list of ref PathSeg, ctm: array of real): array of Point
{
	pts: list of Point;
	npts := 0;
	cx := 0.0;
	cy := 0.0;
	startx := 0.0;
	starty := 0.0;

	for(; path != nil; path = tl path){
		seg := hd path;
		pick s := seg {
		Move =>
			cx = s.x; cy = s.y;
			startx = cx; starty = cy;
			(px, py) := xformpt(cx, cy, ctm);
			pts = Point(px, py) :: pts;
			npts++;
		Line =>
			cx = s.x; cy = s.y;
			(px, py) := xformpt(cx, cy, ctm);
			pts = Point(px, py) :: pts;
			npts++;
		Curve =>
			# De Casteljau subdivision to polyline
			bpts := flattenbezier(cx, cy, s.x1, s.y1, s.x2, s.y2, s.x3, s.y3, ctm);
			for(bp := bpts; bp != nil; bp = tl bp){
				pts = hd bp :: pts;
				npts++;
			}
			cx = s.x3; cy = s.y3;
		Close =>
			cx = startx; cy = starty;
			(px, py) := xformpt(cx, cy, ctm);
			pts = Point(px, py) :: pts;
			npts++;
		}
	}

	if(npts == 0)
		return nil;

	# Reverse to correct order
	result := array[npts] of Point;
	i := npts - 1;
	for(; pts != nil; pts = tl pts)
		result[i--] = hd pts;
	return result;
}

# Compute bounding box of a path in page pixel coordinates, clipped to pagerect.
pathbbox(rpath: list of ref PathSeg, ctm: array of real, pagerect: Rect): Rect
{
	minx := 16r7FFFFFFF;
	miny := 16r7FFFFFFF;
	maxx := -16r7FFFFFFF;
	maxy := -16r7FFFFFFF;

	for(p := rpath; p != nil; p = tl p){
		seg := hd p;
		pick s := seg {
		Move =>
			(px, py) := xformpt(s.x, s.y, ctm);
			if(px < minx) minx = px;
			if(py < miny) miny = py;
			if(px > maxx) maxx = px;
			if(py > maxy) maxy = py;
		Line =>
			(px, py) := xformpt(s.x, s.y, ctm);
			if(px < minx) minx = px;
			if(py < miny) miny = py;
			if(px > maxx) maxx = px;
			if(py > maxy) maxy = py;
		Curve =>
			# Include all control points for conservative bbox
			for(ci := 0; ci < 3; ci++){
				cx, cy: real;
				case ci {
				0 => (cx, cy) = (s.x1, s.y1);
				1 => (cx, cy) = (s.x2, s.y2);
				2 => (cx, cy) = (s.x3, s.y3);
				}
				(px, py) := xformpt(cx, cy, ctm);
				if(px < minx) minx = px;
				if(py < miny) miny = py;
				if(px > maxx) maxx = px;
				if(py > maxy) maxy = py;
			}
		Close =>
			;
		}
	}

	# Pad by 1 pixel for rounding
	minx--; miny--;
	maxx++; maxy++;

	# Clip to page
	if(minx < pagerect.min.x) minx = pagerect.min.x;
	if(miny < pagerect.min.y) miny = pagerect.min.y;
	if(maxx > pagerect.max.x) maxx = pagerect.max.x;
	if(maxy > pagerect.max.y) maxy = pagerect.max.y;

	return Rect(Point(minx, miny), Point(maxx, maxy));
}

# Build a GREY8 clip mask from the current path.
# White (16rFF) = visible, Black (0) = clipped.
# If gs already has a clipmask, intersect (AND) with the new one.
buildclipmask(img: ref Image, gs: ref GState, path: list of ref PathSeg, evenodd: int): ref Image
{
	if(path == nil || display == nil)
		return gs.clipmask;

	# Create GREY8 mask same size as page, filled black (all clipped)
	mask := display.newimage(img.r, drawm->GREY8, 0, drawm->Black);
	if(mask == nil)
		return gs.clipmask;

	# White fill image for painting visible areas
	white := display.newimage(Rect(Point(0,0), Point(1,1)),
		drawm->GREY8, 1, drawm->White);
	if(white == nil)
		return gs.clipmask;

	wind := ~0;
	if(evenodd)
		wind = 1;

	# Reverse path and split into subpaths at Move operators (same as fillpath)
	rpath := reversepath(path);
	subpath: list of ref PathSeg;
	for(p := rpath; p != nil; p = tl p){
		seg := hd p;
		pick s := seg {
		Move =>
			if(subpath != nil){
				pts := flattenpath(reversepath(subpath), gs.ctm);
				if(pts != nil && len pts >= 3)
					mask.fillpoly(pts, wind, white, Point(0,0));
			}
			subpath = seg :: nil;
		* =>
			subpath = seg :: subpath;
		}
	}
	if(subpath != nil){
		pts := flattenpath(reversepath(subpath), gs.ctm);
		if(pts != nil && len pts >= 3)
			mask.fillpoly(pts, wind, white, Point(0,0));
	}

	# If existing clipmask, intersect
	if(gs.clipmask != nil)
		intersectmask(mask, gs.clipmask);

	return mask;
}

# mask made the intersection of itself and old (each pixel the less)
intersectmask(mask, old: ref Image)
{
	w := mask.r.dx();
	oldbuf := array[w] of byte;
	newbuf := array[w] of byte;
	for(y := mask.r.min.y; y < mask.r.max.y; y++){
		rr := Rect(Point(mask.r.min.x, y), Point(mask.r.max.x, y + 1));
		old.readpixels(rr, oldbuf);
		mask.readpixels(rr, newbuf);
		for(x := 0; x < w; x++){
			if(int oldbuf[x] < int newbuf[x])
				newbuf[x] = oldbuf[x];
		}
		mask.writepixels(rr, newbuf);
	}
}

# Transform a point through CTM
xformpt(x, y: real, ctm: array of real): (int, int)
{
	px := x * ctm[0] + y * ctm[2] + ctm[4];
	py := x * ctm[1] + y * ctm[3] + ctm[5];
	return (int (px + 0.5), int (py + 0.5));
}

# Flatten a cubic bezier to polyline points via subdivision
FLAT_THRESH: con 1.0;  # pixel tolerance

flattenbezier(x0, y0, x1, y1, x2, y2, x3, y3: real,
	ctm: array of real): list of Point
{
	# Transform all control points
	(px0, py0) := xformpt(x0, y0, ctm);
	(px1, py1) := xformpt(x1, y1, ctm);
	(px2, py2) := xformpt(x2, y2, ctm);
	(px3, py3) := xformpt(x3, y3, ctm);

	return subdividebezier(
		real px0, real py0,
		real px1, real py1,
		real px2, real py2,
		real px3, real py3,
		0);
}

subdividebezier(x0, y0, x1, y1, x2, y2, x3, y3: real,
	depth: int): list of Point
{
	# Check flatness: if control points are close to the line x0,y0 -> x3,y3
	dx := x3 - x0;
	dy := y3 - y0;
	d2 := math->fabs((x1 - x3) * dy - (y1 - y3) * dx);
	d3 := math->fabs((x2 - x3) * dy - (y2 - y3) * dx);

	if((d2 + d3) * (d2 + d3) <= FLAT_THRESH * (dx*dx + dy*dy) || depth > 8){
		return Point(int (x3 + 0.5), int (y3 + 0.5)) :: nil;
	}

	# Subdivide at t=0.5
	mx01 := (x0 + x1) / 2.0;
	my01 := (y0 + y1) / 2.0;
	mx12 := (x1 + x2) / 2.0;
	my12 := (y1 + y2) / 2.0;
	mx23 := (x2 + x3) / 2.0;
	my23 := (y2 + y3) / 2.0;
	mx012 := (mx01 + mx12) / 2.0;
	my012 := (my01 + my12) / 2.0;
	mx123 := (mx12 + mx23) / 2.0;
	my123 := (my12 + my23) / 2.0;
	mx0123 := (mx012 + mx123) / 2.0;
	my0123 := (my012 + my123) / 2.0;

	left := subdividebezier(x0, y0, mx01, my01, mx012, my012, mx0123, my0123, depth+1);
	right := subdividebezier(mx0123, my0123, mx123, my123, mx23, my23, x3, y3, depth+1);

	# Concatenate: append right to left
	result := right;
	for(l := revpoints(left); l != nil; l = tl l)
		result = hd l :: result;
	return result;
}

revpoints(pts: list of Point): list of Point
{
	rev: list of Point;
	for(; pts != nil; pts = tl pts)
		rev = hd pts :: rev;
	return rev;
}

# Get current point from path
currentpoint(path: list of ref PathSeg): (real, real)
{
	# Path is reversed; head is most recent
	for(; path != nil; path = tl path){
		seg := hd path;
		pick s := seg {
		Move => return (s.x, s.y);
		Line => return (s.x, s.y);
		Curve => return (s.x3, s.y3);
		Close => ;  # keep looking
		}
	}
	return (0.0, 0.0);
}

# ---- Color helpers ----

# Resolve a named color space to component count
resolvecscomps(doc: ref PdfDoc, csname: string, resources: ref PdfObj): int
{
	# Standard color spaces
	case csname {
	"DeviceGray" or "G" =>
		return 1;
	"DeviceRGB" or "RGB" =>
		return 3;
	"DeviceCMYK" or "CMYK" =>
		return 4;
	}

	# Look up in resources /ColorSpace dict
	if(resources != nil){
		csdict := dictget(resources.dval, "ColorSpace");
		if(csdict != nil){
			csdict = resolve(doc, csdict);
			if(csdict != nil){
				csobj := dictget(csdict.dval, csname);
				if(csobj != nil){
					csobj = resolve(doc, csobj);
					if(csobj != nil && csobj.kind == Oarray){
						# [/ICCBased stream] or [/CalRGB dict] etc.
						typeo := hd csobj.aval;
						if(typeo != nil && typeo.kind == Oname){
							case typeo.sval {
							"ICCBased" =>
								# Look for /N in the stream dict
								if(tl csobj.aval != nil){
									iccstream := resolve(doc, hd tl csobj.aval);
									if(iccstream != nil){
										nobj := dictget(iccstream.dval, "N");
										if(nobj != nil){
											nobj = resolve(doc, nobj);
											if(nobj != nil && nobj.kind == Oint)
												return nobj.ival;
										}
									}
								}
							"CalRGB" or "Lab" =>
								return 3;
							"CalGray" =>
								return 1;
							"Separation" or "DeviceN" =>
								return 1;  # tint transform produces 1 value
							"Indexed" =>
								return 1;  # single index value
							}
						}
					}
				}
			}
		}
	}

	return 3;  # default to RGB
}

clampcolor(v: real): int
{
	i := int (v * 255.0 + 0.5);
	if(i < 0) i = 0;
	if(i > 255) i = 255;
	return i;
}

cmyk2rgb(c, m, y, k: real): (int, int, int)
{
	r := 1.0 - (c + k);
	g := 1.0 - (m + k);
	b := 1.0 - (y + k);
	if(r < 0.0) r = 0.0;
	if(g < 0.0) g = 0.0;
	if(b < 0.0) b = 0.0;
	return (clampcolor(r), clampcolor(g), clampcolor(b));
}

getcolor(r, g, b: int): ref Image
{
	# Check cache
	for(cl := colorcache; cl != nil; cl = tl cl){
		e := hd cl;
		if(e.r == r && e.g == g && e.b == b)
			return e.img;
	}
	# Create new color image
	rgb := (r << 24) | (g << 16) | (b << 8) | 16rFF;
	img := display.newimage(Rect(Point(0,0), Point(1,1)), drawm->RGB24, 1, rgb);
	if(img != nil)
		colorcache = ref ColorCacheEntry(r, g, b, img) :: colorcache;
	return img;
}

# ---- ExtGState ----

applyextgstate(doc: ref PdfDoc, gs: ref GState, gsname: string,
	resources: ref PdfObj, img: ref Image, fontmap: list of ref FontMapEntry)
{
	extgs := dictget(resources.dval, "ExtGState");
	if(extgs == nil) return;
	extgs = resolve(doc, extgs);
	if(extgs == nil) return;
	gsobj := dictget(extgs.dval, gsname);
	if(gsobj == nil) return;
	gsobj = resolve(doc, gsobj);
	if(gsobj == nil) return;

	# Non-stroking alpha (ca)
	caobj := dictget(gsobj.dval, "ca");
	if(caobj != nil){
		if(caobj.kind == Oreal)
			gs.alpha = caobj.rval;
		else if(caobj.kind == Oint)
			gs.alpha = real caobj.ival;
	}

	# Soft Mask (SMask)
	smobj := dictget(gsobj.dval, "SMask");
	if(smobj == nil)
		return;
	smobj = resolve(doc, smobj);
	if(smobj == nil)
		return;

	# SMask can be "None" (name) to clear the mask
	if(smobj.kind == Oname && smobj.sval == "None"){
		gs.smask = nil;
		return;
	}

	# SMask dict: /G (mask form), /S (Luminosity or Alpha), /BC (backdrop color)
	if(smobj.kind != Odict || display == nil)
		return;

	maskform := dictget(smobj.dval, "G");
	if(maskform == nil)
		return;
	maskform = resolve(doc, maskform);
	if(maskform == nil)
		return;

	# Render mask form to GREY8 image
	gs.smask = rendersmaskform(doc, img, gs, maskform, resources, fontmap);
}

# Render an SMask form to a GREY8 luminosity mask
rendersmaskform(doc: ref PdfDoc, pageimg: ref Image, gs: ref GState,
	maskform, resources: ref PdfObj, fontmap: list of ref FontMapEntry): ref Image
{
	if(maskform == nil || display == nil)
		return nil;

	# Get mask form's BBox
	bboxobj := dictget(maskform.dval, "BBox");
	if(bboxobj == nil) return nil;
	bboxobj = resolve(doc, bboxobj);
	if(bboxobj == nil || bboxobj.kind != Oarray) return nil;

	bvals := array[4] of { * => 0.0 };
	bi := 0;
	for(bl := bboxobj.aval; bl != nil && bi < 4; bl = tl bl){
		o := hd bl;
		if(o.kind == Oint) bvals[bi] = real o.ival;
		else if(o.kind == Oreal) bvals[bi] = o.rval;
		bi++;
	}

	# Apply mask form's own Matrix if present
	maskctm := array[6] of real;
	maskctm[0:] = gs.ctm;
	mobj := dictget(maskform.dval, "Matrix");
	if(mobj != nil){
		mobj = resolve(doc, mobj);
		if(mobj != nil && mobj.kind == Oarray){
			mvals := array[6] of { * => 0.0 };
			mi := 0;
			for(ml := mobj.aval; ml != nil && mi < 6; ml = tl ml){
				o := hd ml;
				if(o.kind == Oint) mvals[mi] = real o.ival;
				else if(o.kind == Oreal) mvals[mi] = o.rval;
				mi++;
			}
			maskctm = matmul(mvals, gs.ctm);
		}
	}

	# Transform BBox to pixel coordinates
	(px0, py0) := xformpt(bvals[0], bvals[1], maskctm);
	(px1, py1) := xformpt(bvals[2], bvals[3], maskctm);
	if(px0 > px1) { t := px0; px0 = px1; px1 = t; }
	if(py0 > py1) { t := py0; py0 = py1; py1 = t; }

	# Clip to page
	if(px0 < pageimg.r.min.x) px0 = pageimg.r.min.x;
	if(py0 < pageimg.r.min.y) py0 = pageimg.r.min.y;
	if(px1 > pageimg.r.max.x) px1 = pageimg.r.max.x;
	if(py1 > pageimg.r.max.y) py1 = pageimg.r.max.y;

	bw := px1 - px0; bh := py1 - py0;
	if(bw <= 0 || bh <= 0) return nil;
	if(bw * bh > 4096 * 4096) return nil;

	# Create RGB24 offscreen for mask form rendering
	bboxr := Rect(Point(px0, py0), Point(px1, py1));
	offscreen := display.newimage(bboxr, drawm->RGB24, 0, drawm->Black);
	if(offscreen == nil) return nil;

	# Set up graphics state for mask form
	maskgs := newgstate();
	maskgs.ctm[0:] = maskctm;

	# Get mask form's resources
	formres := dictget(maskform.dval, "Resources");
	if(formres != nil)
		formres = resolve(doc, formres);
	if(formres == nil)
		formres = resources;

	formfontmap := buildfontmapres(doc, formres);
	if(formfontmap == nil)
		formfontmap = fontmap;

	# Render mask form content
	(csdata, nil) := decompressstream(maskform);
	if(csdata != nil && len csdata > 0)
		execcontentstream(doc, offscreen, csdata, maskgs, formres, formfontmap, 5);

	# Convert rendered RGB to GREY8 luminosity mask
	# Luminosity = 0.2126*R + 0.7152*G + 0.0722*B
	mask := display.newimage(bboxr, drawm->GREY8, 0, drawm->Black);
	if(mask == nil) return nil;

	rowrgb := array[bw * 3] of byte;
	rowgrey := array[bw] of byte;
	for(y := py0; y < py1; y++){
		rr := Rect(Point(px0, y), Point(px1, y + 1));
		offscreen.readpixels(rr, rowrgb);
		for(x := 0; x < bw; x++){
			# Inferno RGB24 stores B, G, R in memory
			bb := int rowrgb[x*3];
			gg := int rowrgb[x*3+1];
			rr2 := int rowrgb[x*3+2];
			lum := (rr2 * 54 + gg * 183 + bb * 19) / 256;
			if(lum > 255) lum = 255;
			rowgrey[x] = byte lum;
		}
		mask.writepixels(rr, rowgrey);
	}

	# Expand mask to full page size so it can be used in draw() with page coords
	fullmask := display.newimage(pageimg.r, drawm->GREY8, 0, drawm->Black);
	if(fullmask == nil) return mask;
	fullmask.draw(bboxr, mask, nil, bboxr.min);
	return fullmask;
}

# ---- Shading ----

# Float version of xformpt for gradient precision
xformptf(x, y: real, ctm: array of real): (real, real)
{
	px := x * ctm[0] + y * ctm[2] + ctm[4];
	py := x * ctm[1] + y * ctm[3] + ctm[5];
	return (px, py);
}

# Render a Type 2 (axial) gradient shading
renderaxialsh(doc: ref PdfDoc, img: ref Image, gs: ref GState,
	shname: string, resources: ref PdfObj)
{
	# Look up shading in resources
	shdict := dictget(resources.dval, "Shading");
	if(shdict == nil) return;
	shdict = resolve(doc, shdict);
	if(shdict == nil) return;
	shobj := dictget(shdict.dval, shname);
	if(shobj == nil) return;
	shobj = resolve(doc, shobj);
	if(shobj == nil) return;

	# Only Type 2 (axial) supported
	shtype := dictgetintres(doc, shobj.dval, "ShadingType");
	if(shtype != 2) return;

	# Get gradient axis coordinates [x0, y0, x1, y1]
	coords := dictget(shobj.dval, "Coords");
	if(coords == nil) return;
	coords = resolve(doc, coords);
	if(coords == nil || coords.kind != Oarray) return;
	cvals := array[4] of { * => 0.0 };
	ci := 0;
	for(cl := coords.aval; cl != nil && ci < 4; cl = tl cl){
		o := hd cl;
		if(o.kind == Oint) cvals[ci] = real o.ival;
		else if(o.kind == Oreal) cvals[ci] = o.rval;
		ci++;
	}
	gx0 := cvals[0]; gy0 := cvals[1];
	gx1 := cvals[2]; gy1 := cvals[3];

	# Get function
	funcobj := dictget(shobj.dval, "Function");
	if(funcobj == nil) return;
	funcobj = resolve(doc, funcobj);
	if(funcobj == nil) return;

	ftype := dictgetintres(doc, funcobj.dval, "FunctionType");
	if(ftype != 0) return;  # only sampled functions

	bps := dictgetintres(doc, funcobj.dval, "BitsPerSample");
	if(bps != 8) return;

	# Get number of samples
	sizeobj := dictget(funcobj.dval, "Size");
	if(sizeobj == nil) return;
	sizeobj = resolve(doc, sizeobj);
	nsamples := 0;
	if(sizeobj != nil && sizeobj.kind == Oarray && sizeobj.aval != nil){
		first := hd sizeobj.aval;
		if(first.kind == Oint) nsamples = first.ival;
	}
	if(nsamples < 2) return;

	# Determine output components from Range
	nout := 3;
	rangeobj := dictget(funcobj.dval, "Range");
	if(rangeobj != nil){
		rangeobj = resolve(doc, rangeobj);
		if(rangeobj != nil && rangeobj.kind == Oarray){
			rlen := 0;
			for(rl := rangeobj.aval; rl != nil; rl = tl rl)
				rlen++;
			nout = rlen / 2;
		}
	}
	if(nout < 3) return;  # need at least RGB

	# Decompress function data
	(fdata, nil) := decompressstream(funcobj);
	if(fdata == nil || len fdata < nsamples * nout) return;

	# Transform gradient endpoints to pixel space
	(px0, py0) := xformptf(gx0, gy0, gs.ctm);
	(px1, py1) := xformptf(gx1, gy1, gs.ctm);

	# Gradient direction vector
	gdx := px1 - px0;
	gdy := py1 - py0;
	glen2 := gdx*gdx + gdy*gdy;
	if(glen2 < 0.001) return;

	# Paint every pixel in the page image
	imgw := img.r.dx();
	rowbuf := array[imgw * 3] of byte;
	nsm1 := real (nsamples - 1);

	# If clip mask active, read clip row and existing pixels for blending
	clipbuf: array of byte;
	dstbuf: array of byte;
	if(gs.clipmask != nil){
		clipbuf = array[imgw] of byte;
		dstbuf = array[imgw * 3] of byte;
	}

	for(py := img.r.min.y; py < img.r.max.y; py++){
		rr := Rect(Point(img.r.min.x, py), Point(img.r.max.x, py + 1));
		if(gs.clipmask != nil){
			gs.clipmask.readpixels(rr, clipbuf);
			img.readpixels(rr, dstbuf);
		}

		for(px := img.r.min.x; px < img.r.max.x; px++){
			di := (px - img.r.min.x) * 3;

			# Skip fully clipped pixels
			if(gs.clipmask != nil && int clipbuf[px - img.r.min.x] == 0){
				if(dstbuf != nil){
					rowbuf[di] = dstbuf[di];
					rowbuf[di+1] = dstbuf[di+1];
					rowbuf[di+2] = dstbuf[di+2];
				}
				continue;
			}

			# Project pixel onto gradient axis to get parameter t
			vx := real px - px0;
			vy := real py - py0;
			t := (vx * gdx + vy * gdy) / glen2;

			# Extend: clamp to [0, 1]
			if(t < 0.0) t = 0.0;
			if(t > 1.0) t = 1.0;

			# Sample function with linear interpolation
			fidx := t * nsm1;
			i0 := int fidx;
			if(i0 < 0) i0 = 0;
			if(i0 >= nsamples - 1) i0 = nsamples - 2;
			frac := fidx - real i0;
			ifrac := 1.0 - frac;

			si := i0 * nout;
			r := ifrac * real(int fdata[si]) + frac * real(int fdata[si+nout]);
			g := ifrac * real(int fdata[si+1]) + frac * real(int fdata[si+nout+1]);
			b := ifrac * real(int fdata[si+2]) + frac * real(int fdata[si+nout+2]);

			# Partial clip — blend with destination
			if(gs.clipmask != nil && int clipbuf[px - img.r.min.x] < 255){
				ca := int clipbuf[px - img.r.min.x];
				ia := 255 - ca;
				db := int dstbuf[di];
				dg := int dstbuf[di+1];
				dr := int dstbuf[di+2];
				rowbuf[di] = byte ((int(b + 0.5) * ca + db * ia) / 255);
				rowbuf[di+1] = byte ((int(g + 0.5) * ca + dg * ia) / 255);
				rowbuf[di+2] = byte ((int(r + 0.5) * ca + dr * ia) / 255);
			} else {
				# Inferno RGB24 stores bytes as B, G, R in memory
				rowbuf[di] = byte int (b + 0.5);
				rowbuf[di+1] = byte int (g + 0.5);
				rowbuf[di+2] = byte int (r + 0.5);
			}
		}
		img.writepixels(rr, rowbuf);
	}
}

# ---- Matrix operations ----

# Multiply two 3x3 affine matrices stored as [a b c d e f]
# Result = A * B
matmul(a, b: array of real): array of real
{
	r := array[6] of real;
	r[0] = a[0]*b[0] + a[1]*b[2];
	r[1] = a[0]*b[1] + a[1]*b[3];
	r[2] = a[2]*b[0] + a[3]*b[2];
	r[3] = a[2]*b[1] + a[3]*b[3];
	r[4] = a[4]*b[0] + a[5]*b[2] + b[4];
	r[5] = a[4]*b[1] + a[5]*b[3] + b[5];
	return r;
}

# ---- XObject rendering ----

# Render an Image XObject onto the page image
renderimgxobj(doc: ref PdfDoc, img: ref Image, gs: ref GState,
	xobj: ref PdfObj)
{
	if(xobj == nil || display == nil)
		return;

	w := dictgetintres(doc, xobj.dval, "Width");
	h := dictgetintres(doc, xobj.dval, "Height");
	if(w <= 0 || h <= 0)
		return;
	bpc := dictgetintres(doc, xobj.dval, "BitsPerComponent");
	if(bpc <= 0) bpc = 8;

	# Determine color space and component count
	ncomp := 3;  # default RGB
	csname := "";
	csobj := dictget(xobj.dval, "ColorSpace");
	if(csobj != nil)
		csobj = resolve(doc, csobj);
	if(csobj != nil){
		if(csobj.kind == Oname){
			csname = csobj.sval;
		} else if(csobj.kind == Oarray && csobj.aval != nil){
			first := hd csobj.aval;
			if(first != nil && first.kind == Oname)
				csname = first.sval;
			# ICCBased: get /N from the stream dict
			if(csname == "ICCBased" && tl csobj.aval != nil){
				iccref := hd tl csobj.aval;
				iccobj := resolve(doc, iccref);
				if(iccobj != nil)
					ncomp = dictgetintres(doc, iccobj.dval, "N");
			}
			# Indexed: underlying base + lookup table
			if(csname == "Indexed")
				ncomp = 1;  # index values
		}
	}
	if(csname == "DeviceGray" || csname == "CalGray")
		ncomp = 1;
	else if(csname == "DeviceRGB" || csname == "CalRGB")
		ncomp = 3;
	else if(csname == "DeviceCMYK")
		ncomp = 4;
	if(ncomp <= 0) ncomp = 3;

	# Compute destination rect (clipped to page) BEFORE decompressing
	(fdx0, fdy0) := xformpt(0.0, 0.0, gs.ctm);
	(fdx1, fdy1) := xformpt(1.0, 1.0, gs.ctm);
	if(fdx0 > fdx1) { t := fdx0; fdx0 = fdx1; fdx1 = t; }
	if(fdy0 > fdy1) { t := fdy0; fdy0 = fdy1; fdy1 = t; }
	fdw := fdx1 - fdx0;
	fdh := fdy1 - fdy0;
	if(fdw <= 0 || fdh <= 0)
		return;

	# Clip to page bounds
	cdx0 := fdx0; cdy0 := fdy0;
	cdx1 := fdx1; cdy1 := fdy1;
	if(cdx0 < img.r.min.x) cdx0 = img.r.min.x;
	if(cdy0 < img.r.min.y) cdy0 = img.r.min.y;
	if(cdx1 > img.r.max.x) cdx1 = img.r.max.x;
	if(cdy1 > img.r.max.y) cdy1 = img.r.max.y;
	cdw := cdx1 - cdx0;
	cdh := cdy1 - cdy0;
	if(cdw <= 0 || cdh <= 0)
		return;

	# Check estimated raw data size before decompressing.
	# Prevent heap exhaustion from extremely large images.
	bytespp := (bpc + 7) / 8;  # bytes per component: ceil(bpc/8)
	if(bytespp < 1) bytespp = 1;
	rawbytes := big w * big h * big ncomp * big bytespp;
	if(rawbytes > big (128 * 1024 * 1024))
		return;

	# Extract SMask (soft mask for alpha transparency)
	smaskdata: array of byte;
	smaskw := 0;
	smaskh := 0;
	smaskobj := dictget(xobj.dval, "SMask");
	if(smaskobj != nil){
		smaskobj = resolve(doc, smaskobj);
		if(smaskobj != nil && smaskobj.kind == Ostream){
			smaskw = dictgetintres(doc, smaskobj.dval, "Width");
			smaskh = dictgetintres(doc, smaskobj.dval, "Height");
			if(smaskw > 0 && smaskh > 0){
				(mdata, nil) := decompressstream(smaskobj);
				if(mdata != nil && len mdata >= smaskw * smaskh)
					smaskdata = mdata;
			}
			# SMask successfully extracted
		}
	}

	# Decompress stream data
	(sdata, derr) := decompressstream(xobj);
	if(sdata == nil || derr != nil)
		return;

	# JPEG data (DCTDecode the last filter)
	isjpeg := 0;
	if((fname := streamfilter(xobj)) == "DCTDecode" || fname == "DCT")
		isjpeg = 1;

	if(isjpeg){
		# Decode JPEG via readjpg module
		jerr := loadjpg();
		if(jerr != nil)
			return;
		iobuf := bufio->aopen(sdata);
		if(iobuf == nil)
			return;
		(rawimg, rerr) := readjpgmod->read(iobuf);
		if(rawimg == nil || rerr != nil)
			return;
		# Extract RGB pixels from Rawimage channels
		jw := rawimg.r.dx();
		jh := rawimg.r.dy();
		if(jw <= 0 || jh <= 0) return;
		jpix := jw * jh;
		if(rawimg.nchans == 3 && rawimg.chans != nil && len rawimg.chans >= 3){
			# Interleave R, G, B channels into RGB24
			jrgb := array[jpix * 3] of byte;
			rch := rawimg.chans[0];
			gch := rawimg.chans[1];
			bch := rawimg.chans[2];
			for(ji := 0; ji < jpix; ji++){
				jrgb[ji*3] = rch[ji];
				jrgb[ji*3+1] = gch[ji];
				jrgb[ji*3+2] = bch[ji];
			}
			blitpixels(img, jrgb, jw, jh, 3,
				fdx0, fdy0, fdw, fdh,
				cdx0, cdy0, cdx1, cdy1,
				smaskdata, smaskw, smaskh, gs.alpha,
				gs.clipmask);
		} else if(rawimg.nchans == 1 && rawimg.chans != nil){
			blitpixels(img, rawimg.chans[0], jw, jh, 1,
				fdx0, fdy0, fdw, fdh,
				cdx0, cdy0, cdx1, cdy1,
				smaskdata, smaskw, smaskh, gs.alpha,
				gs.clipmask);
		}
		return;
	}

	# For Indexed, decode to RGB first
	if(csname == "Indexed" && csobj != nil && csobj.kind == Oarray){
		rgb := decodeindexed(doc, csobj, sdata, w, h, bpc);
		if(rgb != nil)
			blitpixels(img, rgb, w, h, 3,
				fdx0, fdy0, fdw, fdh,
				cdx0, cdy0, cdx1, cdy1,
				smaskdata, smaskw, smaskh, gs.alpha,
				gs.clipmask);
		return;
	}

	# Direct blit from raw pixel data
	blitpixels(img, sdata, w, h, ncomp,
		fdx0, fdy0, fdw, fdh,
		cdx0, cdy0, cdx1, cdy1,
		smaskdata, smaskw, smaskh, gs.alpha,
		gs.clipmask);
}

# Blit raw pixel data directly onto the page image with scaling and clipping.
# No intermediate Draw images needed — converts and scales on the fly.
# sdata: raw pixel data (RGB, Gray, or CMYK depending on ncomp)
# srcw, srch: source pixel dimensions
# ncomp: bytes per pixel in sdata (1=gray, 3=RGB, 4=CMYK)
# fdx0, fdy0, fdw, fdh: full (unclipped) destination rect
# cdx0, cdy0, cdx1, cdy1: clipped destination rect (intersected with page)
# alpha: optional grayscale mask (same dims as sdata), nil for opaque
# aw, ah: alpha mask dimensions (used for scaling if different from srcw/srch)
# galpha: global opacity from ExtGState ca (1.0 = fully opaque)
# clipmask: GREY8 clip path mask (nil = no clip, white = visible)
blitpixels(pageimg: ref Image,
	sdata: array of byte, srcw, srch, ncomp: int,
	fdx0, fdy0, fdw, fdh: int,
	cdx0, cdy0, cdx1, cdy1: int,
	alpha: array of byte, aw, ah: int,
	galpha: real,
	clipmask: ref Image)
{
	cdw := cdx1 - cdx0;
	cdh := cdy1 - cdy0;
	if(cdw <= 0 || cdh <= 0)
		return;

	rowbuf := array[cdw * 3] of byte;
	hasalpha := alpha != nil && len alpha > 0;
	# Also blend if global alpha < 1.0
	if(galpha < 0.999)
		hasalpha = 1;

	# If alpha blending or clip mask, we need to read existing page pixels
	needblend := hasalpha || clipmask != nil;
	dstbuf: array of byte;
	if(needblend)
		dstbuf = array[cdw * 3] of byte;

	# Read clip mask row buffer if clipping active
	clipbuf: array of byte;
	if(clipmask != nil)
		clipbuf = array[cdw] of byte;

	for(dy := cdy0; dy < cdy1; dy++){
		# Map destination y to source y (nearest-neighbor)
		sy := (dy - fdy0) * srch / fdh;
		if(sy < 0) sy = 0;
		if(sy >= srch) sy = srch - 1;

		# Read existing page pixels for blending
		if(needblend){
			rr := Rect(Point(cdx0, dy), Point(cdx1, dy + 1));
			pageimg.readpixels(rr, dstbuf);
		}

		# Read clip mask row
		if(clipmask != nil){
			rr := Rect(Point(cdx0, dy), Point(cdx1, dy + 1));
			clipmask.readpixels(rr, clipbuf);
		}

		for(dx := cdx0; dx < cdx1; dx++){
			ci := dx - cdx0;

			# Skip clipped pixels
			if(clipmask != nil && int clipbuf[ci] == 0){
				di := ci * 3;
				rowbuf[di] = dstbuf[di];
				rowbuf[di+1] = dstbuf[di+1];
				rowbuf[di+2] = dstbuf[di+2];
				continue;
			}

			# Map destination x to source x
			sx := (dx - fdx0) * srcw / fdw;
			if(sx < 0) sx = 0;
			if(sx >= srcw) sx = srcw - 1;

			di := ci * 3;
			si := (sy * srcw + sx) * ncomp;

			# Get source RGB
			sr, sg, sb: int;
			if(ncomp == 3){
				if(si + 2 < len sdata){
					sr = int sdata[si];
					sg = int sdata[si+1];
					sb = int sdata[si+2];
				}
			} else if(ncomp == 4){
				# CMYK → RGB
				if(si + 3 < len sdata){
					cc := real(int sdata[si]) / 255.0;
					mm := real(int sdata[si+1]) / 255.0;
					yy := real(int sdata[si+2]) / 255.0;
					kk := real(int sdata[si+3]) / 255.0;
					(sr, sg, sb) = cmyk2rgb(cc, mm, yy, kk);
				}
			} else if(ncomp == 1){
				# Grayscale
				if(si < len sdata){
					sr = int sdata[si];
					sg = sr;
					sb = sr;
				}
			}

			# Inferno RGB24 stores bytes as B, G, R in memory
			if(hasalpha){
				# Sample SMask alpha at corresponding source position
				a := 255;
				if(alpha != nil && aw > 0 && ah > 0){
					ax := (dx - fdx0) * aw / fdw;
					ay := (dy - fdy0) * ah / fdh;
					if(ax < 0) ax = 0;
					if(ax >= aw) ax = aw - 1;
					if(ay < 0) ay = 0;
					if(ay >= ah) ay = ah - 1;
					ai := ay * aw + ax;
					if(ai < len alpha)
						a = int alpha[ai];
				}
				# Combine with global alpha (ExtGState ca)
				if(galpha < 0.999)
					a = int (real a * galpha);

				# Combine with clip mask alpha
				if(clipmask != nil && int clipbuf[ci] < 255)
					a = a * int clipbuf[ci] / 255;

				if(a == 0){
					# Fully transparent — keep destination
					rowbuf[di] = dstbuf[di];
					rowbuf[di+1] = dstbuf[di+1];
					rowbuf[di+2] = dstbuf[di+2];
				} else if(a >= 255){
					rowbuf[di] = byte sb;
					rowbuf[di+1] = byte sg;
					rowbuf[di+2] = byte sr;
				} else {
					# Alpha blend: out = src*a/255 + dst*(255-a)/255
					ia := 255 - a;
					db := int dstbuf[di];
					dg := int dstbuf[di+1];
					dr := int dstbuf[di+2];
					rowbuf[di] = byte ((sb * a + db * ia) / 255);
					rowbuf[di+1] = byte ((sg * a + dg * ia) / 255);
					rowbuf[di+2] = byte ((sr * a + dr * ia) / 255);
				}
			} else if(clipmask != nil && int clipbuf[ci] < 255){
				# Partial clip (anti-aliased edge) — blend with clip alpha
				ca := int clipbuf[ci];
				ia := 255 - ca;
				db := int dstbuf[di];
				dg := int dstbuf[di+1];
				dr := int dstbuf[di+2];
				rowbuf[di] = byte ((sb * ca + db * ia) / 255);
				rowbuf[di+1] = byte ((sg * ca + dg * ia) / 255);
				rowbuf[di+2] = byte ((sr * ca + dr * ia) / 255);
			} else {
				rowbuf[di] = byte sb;
				rowbuf[di+1] = byte sg;
				rowbuf[di+2] = byte sr;
			}
		}

		# Write this row to the page image
		r := Rect(Point(cdx0, dy), Point(cdx1, dy + 1));
		pageimg.writepixels(r, rowbuf);
	}
}

# Decode an Indexed color space image to RGB24
decodeindexed(doc: ref PdfDoc, csobj: ref PdfObj, sdata: array of byte,
	w, h, bpc: int): array of byte
{
	# /Indexed /base hival lookup
	al := csobj.aval;
	if(al == nil) return nil;
	al = tl al;  # skip "Indexed"
	if(al == nil) return nil;
	baseobj := hd al;
	al = tl al;
	if(al == nil) return nil;
	hivalobj := hd al;
	al = tl al;
	if(al == nil) return nil;
	lookupobj := hd al;

	# Resolve base color space to get component count
	basencomp := 3;
	baseobj = resolve(doc, baseobj);
	if(baseobj != nil && baseobj.kind == Oname){
		case baseobj.sval {
		"DeviceGray" or "CalGray" => basencomp = 1;
		"DeviceRGB" or "CalRGB" => basencomp = 3;
		"DeviceCMYK" => basencomp = 4;
		}
	}

	hival := 255;
	if(hivalobj != nil && hivalobj.kind == Oint)
		hival = hivalobj.ival;

	# Get lookup table
	lookup: array of byte;
	lookupobj = resolve(doc, lookupobj);
	if(lookupobj != nil){
		if(lookupobj.kind == Ostream){
			(ldata, nil) := decompressstream(lookupobj);
			lookup = ldata;
		} else if(lookupobj.kind == Ostring){
			lookup = array[len lookupobj.sval] of byte;
			for(i := 0; i < len lookupobj.sval; i++)
				lookup[i] = byte lookupobj.sval[i];
		}
	}
	if(lookup == nil)
		return nil;

	npix := w * h;
	rgb := array[npix * 3] of byte;
	for(i := 0; i < npix; i++){
		# Extract index based on bits per component
		idx := 0;
		if(bpc == 8){
			if(i < len sdata)
				idx = int sdata[i];
		} else if(bpc == 4){
			bi := i / 2;
			if(bi < len sdata){
				if(i % 2 == 0)
					idx = (int sdata[bi] >> 4) & 16rF;
				else
					idx = int sdata[bi] & 16rF;
			}
		} else if(bpc == 2){
			bi := i / 4;
			shift := (3 - (i % 4)) * 2;
			if(bi < len sdata)
				idx = (int sdata[bi] >> shift) & 16r3;
		} else if(bpc == 1){
			bi := i / 8;
			shift := 7 - (i % 8);
			if(bi < len sdata)
				idx = (int sdata[bi] >> shift) & 1;
		} else {
			if(i < len sdata)
				idx = int sdata[i];
		}
		if(idx > hival) idx = hival;
		li := idx * basencomp;
		if(basencomp == 3 && li + 2 < len lookup){
			rgb[i*3] = lookup[li];
			rgb[i*3+1] = lookup[li+1];
			rgb[i*3+2] = lookup[li+2];
		} else if(basencomp == 1 && li < len lookup){
			rgb[i*3] = lookup[li];
			rgb[i*3+1] = lookup[li];
			rgb[i*3+2] = lookup[li];
		} else if(basencomp == 4 && li + 3 < len lookup){
			c := real(int lookup[li]) / 255.0;
			m := real(int lookup[li+1]) / 255.0;
			y := real(int lookup[li+2]) / 255.0;
			k := real(int lookup[li+3]) / 255.0;
			(r, g, b) := cmyk2rgb(c, m, y, k);
			rgb[i*3] = byte r;
			rgb[i*3+1] = byte g;
			rgb[i*3+2] = byte b;
		}
	}
	return rgb;
}

# Render a Form XObject by recursively executing its content stream
renderformxobj(doc: ref PdfDoc, img: ref Image, gs: ref GState,
	xobj, pageresources: ref PdfObj, fontmap: list of ref FontMapEntry, depth: int)
{
	if(xobj == nil || depth > 10)
		return;

	# Save graphics state
	savedgs := copygstate(gs);

	# Apply form Matrix if present
	formctm := array[6] of real;
	formctm[0:] = gs.ctm;
	mobj := dictget(xobj.dval, "Matrix");
	if(mobj != nil){
		mobj = resolve(doc, mobj);
		if(mobj != nil && mobj.kind == Oarray){
			mvals := array[6] of { * => 0.0 };
			i := 0;
			for(ml := mobj.aval; ml != nil && i < 6; ml = tl ml){
				o := hd ml;
				if(o.kind == Oint)
					mvals[i] = real o.ival;
				else if(o.kind == Oreal)
					mvals[i] = o.rval;
				i++;
			}
			formctm = matmul(mvals, gs.ctm);
		}
	}
	gs.ctm[0:] = formctm;

	# Check for transparency group
	istransparent := 0;
	groupobj := dictget(xobj.dval, "Group");
	if(groupobj != nil){
		groupobj = resolve(doc, groupobj);
		if(groupobj != nil){
			sobj := dictget(groupobj.dval, "S");
			if(sobj != nil){
				sobj = resolve(doc, sobj);
				if(sobj != nil && sobj.sval == "Transparency")
					istransparent = 1;
			}
		}
	}

	# Get form's own resources, fall back to page resources
	formres := dictget(xobj.dval, "Resources");
	if(formres != nil)
		formres = resolve(doc, formres);
	if(formres == nil)
		formres = pageresources;

	# Build font map from form resources
	formfontmap := buildfontmapres(doc, formres);
	if(formfontmap == nil)
		formfontmap = fontmap;

	# Decompress content stream
	(csdata, nil) := decompressstream(xobj);
	if(csdata == nil || len csdata == 0){
		restoregs(gs, savedgs);
		return;
	}

	if(gs.smask != nil && display != nil){
		# SMask set by ExtGState — render to offscreen, composite through SMask
		renderformwithsmask(doc, img, gs, xobj, formres, formfontmap,
			csdata, depth);
	} else if(istransparent && display != nil){
		# Transparent group without SMask — render to offscreen, composite back
		renderformtransparent(doc, img, gs, xobj, formres, formfontmap,
			csdata, depth);
	} else {
		# Opaque form — render directly to page
		execcontentstream(doc, img, csdata, gs, formres, formfontmap, depth + 1);
	}

	# Restore graphics state
	restoregs(gs, savedgs);
}

# Render a Form XObject with ExtGState SMask compositing
renderformwithsmask(doc: ref PdfDoc, img: ref Image, gs: ref GState,
	xobj, formres: ref PdfObj, fontmap: list of ref FontMapEntry,
	csdata: array of byte, depth: int)
{
	# Get BBox from form dict for offscreen sizing
	bboxobj := dictget(xobj.dval, "BBox");
	if(bboxobj == nil){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}
	bboxobj = resolve(doc, bboxobj);
	if(bboxobj == nil || bboxobj.kind != Oarray){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}

	bvals := array[4] of { * => 0.0 };
	bi := 0;
	for(bl := bboxobj.aval; bl != nil && bi < 4; bl = tl bl){
		o := hd bl;
		if(o.kind == Oint) bvals[bi] = real o.ival;
		else if(o.kind == Oreal) bvals[bi] = o.rval;
		bi++;
	}

	(px0, py0) := xformpt(bvals[0], bvals[1], gs.ctm);
	(px1, py1) := xformpt(bvals[2], bvals[3], gs.ctm);
	if(px0 > px1) { t := px0; px0 = px1; px1 = t; }
	if(py0 > py1) { t := py0; py0 = py1; py1 = t; }

	if(px0 < img.r.min.x) px0 = img.r.min.x;
	if(py0 < img.r.min.y) py0 = img.r.min.y;
	if(px1 > img.r.max.x) px1 = img.r.max.x;
	if(py1 > img.r.max.y) py1 = img.r.max.y;

	bw := px1 - px0; bh := py1 - py0;
	if(bw <= 0 || bh <= 0 || bw * bh > 4096 * 4096){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}

	bboxr := Rect(Point(px0, py0), Point(px1, py1));
	offscreen := display.newimage(bboxr, drawm->RGB24, 0, drawm->Black);
	if(offscreen == nil){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}

	# Copy page backdrop (non-isolated)
	offscreen.draw(bboxr, img, nil, bboxr.min);

	# Clear SMask in gs so nested rendering doesn't re-apply it
	savedsmask := gs.smask;
	gs.smask = nil;

	# Render form content to offscreen
	execcontentstream(doc, offscreen, csdata, gs, formres, fontmap, depth + 1);

	gs.smask = savedsmask;

	# Composite offscreen back to page through the SMask
	img.draw(bboxr, offscreen, gs.smask, bboxr.min);
}

# Render a transparent Form XObject to an offscreen buffer and composite back
renderformtransparent(doc: ref PdfDoc, img: ref Image, gs: ref GState,
	xobj, formres: ref PdfObj, fontmap: list of ref FontMapEntry,
	csdata: array of byte, depth: int)
{
	# Get BBox from form dict
	bboxobj := dictget(xobj.dval, "BBox");
	if(bboxobj == nil){
		# No BBox — fall back to direct rendering
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}
	bboxobj = resolve(doc, bboxobj);
	if(bboxobj == nil || bboxobj.kind != Oarray){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}

	# Parse BBox [x0 y0 x1 y1]
	bvals := array[4] of { * => 0.0 };
	bi := 0;
	for(bl := bboxobj.aval; bl != nil && bi < 4; bl = tl bl){
		o := hd bl;
		if(o.kind == Oint) bvals[bi] = real o.ival;
		else if(o.kind == Oreal) bvals[bi] = o.rval;
		bi++;
	}

	# Transform BBox corners through CTM to pixel coordinates
	(px0, py0) := xformpt(bvals[0], bvals[1], gs.ctm);
	(px1, py1) := xformpt(bvals[2], bvals[3], gs.ctm);

	# Normalize to min/max
	if(px0 > px1) { t := px0; px0 = px1; px1 = t; }
	if(py0 > py1) { t := py0; py0 = py1; py1 = t; }

	# Clip to page bounds
	if(px0 < img.r.min.x) px0 = img.r.min.x;
	if(py0 < img.r.min.y) py0 = img.r.min.y;
	if(px1 > img.r.max.x) px1 = img.r.max.x;
	if(py1 > img.r.max.y) py1 = img.r.max.y;

	bw := px1 - px0;
	bh := py1 - py0;
	if(bw <= 0 || bh <= 0){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}

	# Limit offscreen size to prevent excessive memory use
	if(bw * bh > 4096 * 4096){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}

	# Create offscreen image covering the bbox area (non-isolated: copy page backdrop)
	bboxr := Rect(Point(px0, py0), Point(px1, py1));
	offscreen := display.newimage(bboxr, drawm->RGB24, 0, drawm->White);
	if(offscreen == nil){
		execcontentstream(doc, img, csdata, gs, formres, fontmap, depth + 1);
		return;
	}

	# Copy current page region as backdrop
	offscreen.draw(bboxr, img, nil, bboxr.min);

	# Save a copy of the backdrop for change detection
	backdrop := display.newimage(bboxr, drawm->RGB24, 0, drawm->White);
	if(backdrop != nil)
		backdrop.draw(bboxr, img, nil, bboxr.min);

	# Render form content to offscreen
	execcontentstream(doc, offscreen, csdata, gs, formres, fontmap, depth + 1);

	# Composite offscreen back to page.
	# For non-isolated groups with no explicit SMask, detect changed pixels
	# and only write those back (preserves page background for unchanged areas).
	if(backdrop != nil){
		# Compare offscreen vs backdrop row by row; composite changed pixels
		rowoff := array[bw * 3] of byte;
		rowbak := array[bw * 3] of byte;
		for(y := py0; y < py1; y++){
			rr := Rect(Point(px0, y), Point(px1, y + 1));
			offscreen.readpixels(rr, rowoff);
			backdrop.readpixels(rr, rowbak);
			changed := 0;
			for(x := 0; x < bw * 3; x++){
				if(rowoff[x] != rowbak[x]){
					changed = 1;
					break;
				}
			}
			if(changed)
				img.writepixels(rr, rowoff);
		}
	} else {
		# No backdrop copy — write everything back
		img.draw(bboxr, offscreen, nil, bboxr.min);
	}
}

# Restore graphics state from saved copy
restoregs(gs, saved: ref GState)
{
	gs.ctm[0:] = saved.ctm;
	gs.fillcolor = saved.fillcolor;
	gs.strokecolor = saved.strokecolor;
	gs.linewidth = saved.linewidth;
	gs.linecap = saved.linecap;
	gs.linejoin = saved.linejoin;
	gs.miterlimit = saved.miterlimit;
	gs.fontname = saved.fontname;
	gs.fontsize = saved.fontsize;
	gs.alpha = saved.alpha;
	gs.fillcscomps = saved.fillcscomps;
	gs.strokecscomps = saved.strokecscomps;
	gs.clipmask = saved.clipmask;
	gs.smask = saved.smask;
	gs.cliprect = saved.cliprect;
}

# ---- Operand stack helpers ----

lenlist(l: list of real): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

pop2(l: list of real): (real, real, list of real)
{
	a := hd l; l = tl l;
	b := hd l; l = tl l;
	return (a, b, l);
}

pop3(l: list of real): (real, real, real, list of real)
{
	a := hd l; l = tl l;
	b := hd l; l = tl l;
	c := hd l; l = tl l;
	return (a, b, c, l);
}

pop4(l: list of real): (real, real, real, real, list of real)
{
	a := hd l; l = tl l;
	b := hd l; l = tl l;
	c := hd l; l = tl l;
	d := hd l; l = tl l;
	return (a, b, c, d, l);
}

pop6(l: list of real): (real, real, real, real, real, real, list of real)
{
	a := hd l; l = tl l;
	b := hd l; l = tl l;
	c := hd l; l = tl l;
	d := hd l; l = tl l;
	e := hd l; l = tl l;
	f := hd l; l = tl l;
	return (a, b, c, d, e, f, l);
}

# ---- Read number from content stream ----

readreal(data: array of byte, pos: int): (real, int)
{
	start := pos;
	if(pos < len data && (int data[pos] == '-' || int data[pos] == '+'))
		pos++;
	isreal := 0;
	while(pos < len data){
		c := int data[pos];
		if(c >= '0' && c <= '9')
			pos++;
		else if(c == '.' && !isreal){
			isreal = 1;
			pos++;
		} else
			break;
	}
	if(pos == start)
		return (0.0, pos);
	s := slicestr(data, start, pos - start);
	return (real s, pos);
}

# ---- PDF Parser ----

parsepdf(data: array of byte): (ref PdfDoc, string)
{
	if(len data < 20)
		return (nil, "file too small");
	if(data[0] != byte '%' || data[1] != byte 'P' ||
	   data[2] != byte 'D' || data[3] != byte 'F')
		return (nil, "not a PDF file");

	(xrefoff, err) := findstartxref(data);

	# Parse the most recent xref (traditional or stream)
	trailer: ref PdfObj;
	xref: array of ref XrefEntry;
	nobjs := 0;
	xerr, xserr: string;

	if(xrefoff >= 0 && xrefoff < len data){
		traileroff: int;
		(xref, nobjs, traileroff, xerr) = parsexref(data, xrefoff);
		if(xref != nil){
			terr: string;
			(trailer, nil, terr) = parseobj(data, traileroff);
			if(trailer == nil){
				xref = nil;
				xerr = "cannot parse trailer: " + terr;
			}
		}
		if(xref == nil)
			(xref, nobjs, trailer, xserr) = parsexrefstream(data, xrefoff);
	}

	# Fallback: scan for "xref" keyword when startxref is missing or invalid
	if(xref == nil){
		scanoff := scanforxref(data);
		if(scanoff >= 0){
			traileroff: int;
			(xref, nobjs, traileroff, nil) = parsexref(data, scanoff);
			if(xref != nil){
				(trailer, nil, nil) = parseobj(data, traileroff);
				if(trailer == nil)
					xref = nil;
			}
		}
	}

	if(xref == nil){
		if(err != nil)
			return (nil, "cannot find startxref: " + err);
		return (nil, "cannot parse xref: " + xerr + "; xref stream: " + xserr);
	}

	# Hybrid xref: merge /XRefStm entries into traditional xref.
	# PDF 1.5+ allows a traditional xref + trailer that references
	# an xref stream via /XRefStm for objects stored in ObjStm.
	if(trailer != nil)
		(xref, nobjs) = mergehybridxref(data, trailer, xref, nobjs);

	# Follow /Prev chain to merge older xref sections.
	# Keep the newest trailer for the doc (it has the authoritative Root).
	# Use a cursor to walk /Prev links without clobbering the doc trailer.
	cursor := trailer;
	for(depth := 0; depth < 100; depth++){
		if(cursor == nil)
			break;
		prevobj := dictget(cursor.dval, "Prev");
		if(prevobj == nil)
			break;
		prevoff := 0;
		if(prevobj.kind == Oint)
			prevoff = prevobj.ival;
		else
			break;
		if(prevoff <= 0 || prevoff >= len data)
			break;

		# Try traditional xref first, then xref stream
		(oldxref, oldnobjs, oldtoff, nil) := parsexref(data, prevoff);
		oldtrailer: ref PdfObj;
		if(oldxref != nil){
			(oldtrailer, nil, nil) = parseobj(data, oldtoff);
			# Merge hybrid /XRefStm if present
			if(oldtrailer != nil)
				(oldxref, oldnobjs) = mergehybridxref(data, oldtrailer, oldxref, oldnobjs);
		} else {
			(oldxref, oldnobjs, oldtrailer, nil) = parsexrefstream(data, prevoff);
		}
		if(oldxref == nil)
			break;

		# Grow xref if older section is larger
		if(oldnobjs > len xref){
			newxref := array[oldnobjs] of ref XrefEntry;
			newxref[0:] = xref;
			xref = newxref;
			if(oldnobjs > nobjs)
				nobjs = oldnobjs;
		}

		# Merge: only fill slots that are nil in current xref
		for(i := 0; i < len oldxref; i++){
			if(i < len xref && xref[i] == nil)
				xref[i] = oldxref[i];
		}

		cursor = oldtrailer;
	}

	doc := ref PdfDoc(data, xref, trailer, nobjs, nil, 0, 0, 0, nil, nil, -1, nil, nil);
	return (doc, nil);
}

findstartxref(data: array of byte): (int, string)
{
	searchlen := 2048;
	if(searchlen > len data)
		searchlen = len data;
	start := len data - searchlen;

	needle := "startxref";
	pos := -1;
	for(i := start; i <= len data - len needle; i++){
		found := 1;
		for(j := 0; j < len needle; j++){
			if(data[i+j] != byte needle[j]){
				found = 0;
				break;
			}
		}
		if(found)
			pos = i;
	}
	if(pos < 0)
		return (-1, "startxref not found");

	pos += len needle;
	while(pos < len data && isws(int data[pos]))
		pos++;

	numstr := "";
	while(pos < len data && int data[pos] >= '0' && int data[pos] <= '9'){
		numstr[len numstr] = int data[pos];
		pos++;
	}
	if(len numstr == 0)
		return (-1, "no offset after startxref");
	return (int numstr, nil);
}

# Scan backward from end of file for "xref" keyword.
# Used as a fallback when startxref offset is invalid.
scanforxref(data: array of byte): int
{
	for(i := len data - 5; i >= 0; i--){
		if(data[i] == byte 'x' && i + 4 <= len data &&
		   data[i+1] == byte 'r' && data[i+2] == byte 'e' &&
		   data[i+3] == byte 'f'){
			# Make sure it's not "startxref"
			if(i >= 5 && data[i-1] == byte 't' && data[i-2] == byte 'r' &&
			   data[i-3] == byte 'a' && data[i-4] == byte 't' && data[i-5] == byte 's')
				continue;
			return i;
		}
	}
	return -1;
}

parsexref(data: array of byte, offset: int): (array of ref XrefEntry, int, int, string)
{
	pos := skipws(data, offset);
	if(pos + 4 > len data)
		return (nil, 0, 0, "truncated xref");
	tag := slicestr(data, pos, 4);
	if(tag != "xref")
		return (nil, 0, 0, "expected 'xref' at offset " + string offset);

	pos += 4;
	pos = skipws(data, pos);

	maxobj := 0;
	entries: list of (int, int, array of ref XrefEntry);

	for(;;){
		if(pos >= len data)
			break;
		if(pos + 7 <= len data && slicestr(data, pos, 7) == "trailer")
			break;

		(startobj, p1) := readint(data, pos);
		if(p1 == pos)
			break;
		pos = skipws(data, p1);

		(count, p2) := readint(data, pos);
		if(p2 == pos)
			break;
		pos = skipws(data, p2);

		# Sanity check: reject absurd object numbers from fuzzed data
		if(startobj < 0 || count < 0 || count > len data ||
		   startobj > len data || startobj + count > len data)
			return (nil, 0, 0, "truncated xref");

		if(startobj + count > maxobj)
			maxobj = startobj + count;

		sect := array[count] of ref XrefEntry;
		for(i := 0; i < count; i++){
			(eoff, p3) := readint(data, pos);
			pos = skipws(data, p3);
			(egen, p4) := readint(data, pos);
			pos = skipws(data, p4);
			inuse := 0;
			if(pos < len data){
				if(int data[pos] == 'n')
					inuse = 1;
				pos++;
			}
			pos = skipws(data, pos);
			sect[i] = ref XrefEntry(eoff, egen, inuse);
		}
		entries = (startobj, count, sect) :: entries;
	}

	xref := array[maxobj] of ref XrefEntry;
	for(; entries != nil; entries = tl entries){
		(sobj, cnt, sect) := hd entries;
		for(i := 0; i < cnt; i++)
			xref[sobj + i] = sect[i];
	}

	trailerpos := pos;
	if(trailerpos + 7 <= len data && slicestr(data, trailerpos, 7) == "trailer")
		trailerpos += 7;
	trailerpos = skipws(data, trailerpos);

	return (xref, maxobj, trailerpos, nil);
}

parsexrefstream(data: array of byte, offset: int): (array of ref XrefEntry, int, ref PdfObj, string)
{
	pos := skipws(data, offset);
	(nil, p1) := readint(data, pos);
	if(p1 == pos)
		return (nil, 0, nil, "expected object number");
	pos = skipws(data, p1);

	(nil, p2) := readint(data, pos);
	if(p2 == pos)
		return (nil, 0, nil, "expected generation number");
	pos = skipws(data, p2);

	if(pos + 3 > len data || slicestr(data, pos, 3) != "obj")
		return (nil, 0, nil, "expected 'obj' keyword");
	pos += 3;
	pos = skipws(data, pos);

	(obj, nil, perr) := parseobj(data, pos);
	if(obj == nil)
		return (nil, 0, nil, "cannot parse xref stream object: " + perr);
	if(obj.kind != Ostream)
		return (nil, 0, nil, "xref stream object is not a stream");

	typeobj := dictget(obj.dval, "Type");
	if(typeobj == nil || typeobj.kind != Oname || typeobj.sval != "XRef")
		return (nil, 0, nil, "/Type is not /XRef");

	size := dictgetint(obj.dval, "Size");
	if(size <= 0)
		return (nil, 0, nil, "missing or invalid /Size");

	wobj := dictget(obj.dval, "W");
	if(wobj == nil || wobj.kind != Oarray)
		return (nil, 0, nil, "missing /W array");
	wvals: list of int;
	for(wl := wobj.aval; wl != nil; wl = tl wl){
		w := hd wl;
		if(w.kind == Oint)
			wvals = w.ival :: wvals;
		else
			wvals = 0 :: wvals;
	}
	ww := array[3] of {* => 0};
	i := 0;
	for(wr := wvals; wr != nil; wr = tl wr)
		i++;
	if(i != 3)
		return (nil, 0, nil, sys->sprint("/W has %d entries, expected 3", i));
	i = 0;
	for(wr = wvals; wr != nil; wr = tl wr){
		ww[2 - i] = hd wr;
		i++;
	}

	entrysize := ww[0] + ww[1] + ww[2];
	if(entrysize <= 0)
		return (nil, 0, nil, "invalid /W field widths");

	idxobj := dictget(obj.dval, "Index");
	subsections: list of (int, int);
	if(idxobj != nil && idxobj.kind == Oarray){
		il := idxobj.aval;
		for(;;){
			if(il == nil) break;
			sobj := hd il; il = tl il;
			if(il == nil) break;
			cobj := hd il; il = tl il;
			sv := 0; cv := 0;
			if(sobj.kind == Oint) sv = sobj.ival;
			if(cobj.kind == Oint) cv = cobj.ival;
			subsections = (sv, cv) :: subsections;
		}
		rev: list of (int, int);
		for(; subsections != nil; subsections = tl subsections)
			rev = (hd subsections) :: rev;
		subsections = rev;
	} else
		subsections = (0, size) :: nil;

	(sdata, derr) := decompressstream(obj);
	if(sdata == nil)
		return (nil, 0, nil, "cannot decompress xref stream: " + derr);

	xref := array[size] of ref XrefEntry;
	dpos := 0;
	for(sl := subsections; sl != nil; sl = tl sl){
		(startobj, count) := hd sl;
		for(j := 0; j < count; j++){
			if(dpos + entrysize > len sdata)
				break;
			f0 := readfield(sdata, dpos, ww[0]);
			dpos += ww[0];
			f1 := readfield(sdata, dpos, ww[1]);
			dpos += ww[1];
			f2 := readfield(sdata, dpos, ww[2]);
			dpos += ww[2];

			ftype := f0;
			if(ww[0] == 0) ftype = 1;

			objnum := startobj + j;
			if(objnum >= size) break;

			case ftype {
			0 => xref[objnum] = ref XrefEntry(0, f2, 0);
			1 => xref[objnum] = ref XrefEntry(f1, f2, 1);
			2 => xref[objnum] = ref XrefEntry(f1, f2, 2);
			* => xref[objnum] = ref XrefEntry(0, 0, 0);
			}
		}
	}

	trailer := ref PdfObj(Odict, 0, 0.0, nil, nil, obj.dval, nil);
	return (xref, size, trailer, nil);
}

readfield(data: array of byte, pos, width: int): int
{
	v := 0;
	for(i := 0; i < width && pos + i < len data; i++)
		v = (v << 8) | int data[pos + i];
	return v;
}

# Hybrid xref: if trailer has /XRefStm, parse the xref stream
# and merge its entries (type 2 ObjStm refs) into the xref table.
mergehybridxref(data: array of byte, trailer: ref PdfObj, xref: array of ref XrefEntry, nobjs: int): (array of ref XrefEntry, int)
{
	xsobj := dictget(trailer.dval, "XRefStm");
	if(xsobj == nil || xsobj.kind != Oint)
		return (xref, nobjs);
	xsoff := xsobj.ival;
	if(xsoff <= 0 || xsoff >= len data)
		return (xref, nobjs);

	(sxref, snobjs, nil, nil) := parsexrefstream(data, xsoff);
	if(sxref == nil)
		return (xref, nobjs);

	# Grow xref if stream section is larger
	if(snobjs > len xref){
		newxref := array[snobjs] of ref XrefEntry;
		newxref[0:] = xref;
		xref = newxref;
		if(snobjs > nobjs)
			nobjs = snobjs;
	}

	# Merge: only fill nil slots (traditional entries take precedence)
	for(i := 0; i < len sxref; i++){
		if(i < len xref && xref[i] == nil)
			xref[i] = sxref[i];
	}

	return (xref, nobjs);
}

# ---- Object parser ----

parseobj(data: array of byte, pos: int): (ref PdfObj, int, string)
{
	if(pos >= len data)
		return (nil, pos, "unexpected end of data");
	pos = skipws(data, pos);
	if(pos >= len data)
		return (nil, pos, "unexpected end of data");

	c := int data[pos];

	if(c == '<' && pos+1 < len data && int data[pos+1] == '<')
		return parsedict(data, pos);
	if(c == '<')
		return parsehexstring(data, pos);
	if(c == '(')
		return parselitstring(data, pos);
	if(c == '/')
		return parsename(data, pos);
	if(c == '[')
		return parsearray(data, pos);
	if(c == 't' && pos+4 <= len data && slicestr(data, pos, 4) == "true")
		return (ref PdfObj(Obool, 1, 0.0, nil, nil, nil, nil), pos+4, nil);
	if(c == 'f' && pos+5 <= len data && slicestr(data, pos, 5) == "false")
		return (ref PdfObj(Obool, 0, 0.0, nil, nil, nil, nil), pos+5, nil);
	if(c == 'n' && pos+4 <= len data && slicestr(data, pos, 4) == "null")
		return (ref PdfObj(Onull, 0, 0.0, nil, nil, nil, nil), pos+4, nil);
	if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.')
		return parsenumber(data, pos);

	return (nil, pos, "unexpected character: " + string c);
}

parsedict(data: array of byte, pos: int): (ref PdfObj, int, string)
{
	pos += 2;
	pos = skipws(data, pos);
	entries: list of ref DictEntry;

	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data) break;
		if(int data[pos] == '>' && pos+1 < len data && int data[pos+1] == '>'){
			pos += 2;
			break;
		}
		if(int data[pos] != '/')
			return (nil, pos, "expected name key in dict");

		(keyobj, p1, kerr) := parsename(data, pos);
		if(keyobj == nil) return (nil, p1, kerr);
		pos = p1;

		(valobj, p2, verr) := parseobj(data, pos);
		if(valobj == nil) return (nil, p2, verr);
		pos = p2;

		entries = ref DictEntry(keyobj.sval, valobj) :: entries;
	}

	spos := skipws(data, pos);
	if(spos + 6 <= len data && slicestr(data, spos, 6) == "stream")
		return parsestreamdata(data, spos + 6, entries);

	return (ref PdfObj(Odict, 0, 0.0, nil, nil, entries, nil), pos, nil);
}

parsestreamdata(data: array of byte, pos: int,
	entries: list of ref DictEntry): (ref PdfObj, int, string)
{
	if(pos < len data && int data[pos] == '\r') pos++;
	if(pos < len data && int data[pos] == '\n') pos++;

	slen := dictgetint(entries, "Length");
	if(slen <= 0){
		(slen, pos) = findendstream(data, pos);
		if(slen < 0)
			return (nil, pos, "cannot determine stream length");
	}
	if(pos + slen > len data) slen = len data - pos;

	streamdata := array[slen] of byte;
	streamdata[0:] = data[pos:pos+slen];
	pos += slen;

	pos = skipws(data, pos);
	if(pos + 9 <= len data && slicestr(data, pos, 9) == "endstream")
		pos += 9;

	obj := ref PdfObj(Ostream, 0, 0.0, nil, nil, entries, streamdata);
	return (obj, pos, nil);
}

findendstream(data: array of byte, start: int): (int, int)
{
	needle := "endstream";
	for(i := start; i <= len data - len needle; i++){
		found := 1;
		for(j := 0; j < len needle; j++){
			if(data[i+j] != byte needle[j]){
				found = 0;
				break;
			}
		}
		if(found)
			return (i - start, start);
	}
	return (-1, start);
}

parsehexstring(data: array of byte, pos: int): (ref PdfObj, int, string)
{
	pos++;
	s := "";
	nibble := -1;
	while(pos < len data){
		c := int data[pos]; pos++;
		if(c == '>') break;
		if(isws(c)) continue;
		v := hexval(c);
		if(v < 0) continue;
		if(nibble < 0)
			nibble = v;
		else {
			s[len s] = nibble * 16 + v;
			nibble = -1;
		}
	}
	if(nibble >= 0)
		s[len s] = nibble * 16;
	return (ref PdfObj(Ostring, 0, 0.0, s, nil, nil, nil), pos, nil);
}

parselitstring(data: array of byte, pos: int): (ref PdfObj, int, string)
{
	pos++;
	depth := 1;
	s := "";
	while(pos < len data && depth > 0){
		c := int data[pos]; pos++;
		case c {
		'(' =>
			depth++;
			s[len s] = c;
		')' =>
			depth--;
			if(depth > 0) s[len s] = c;
		'\\' =>
			if(pos < len data){
				ec := int data[pos]; pos++;
				case ec {
				'n' => s[len s] = '\n';
				'r' => s[len s] = '\r';
				't' => s[len s] = '\t';
				'b' => s[len s] = '\b';
				'f' => s[len s] = 16r0c;
				'(' => s[len s] = '(';
				')' => s[len s] = ')';
				'\\' => s[len s] = '\\';
				'0' to '7' =>
					oct := ec - '0';
					if(pos < len data && int data[pos] >= '0' && int data[pos] <= '7'){
						oct = oct * 8 + (int data[pos] - '0');
						pos++;
					}
					if(pos < len data && int data[pos] >= '0' && int data[pos] <= '7'){
						oct = oct * 8 + (int data[pos] - '0');
						pos++;
					}
					s[len s] = oct;
				* => s[len s] = ec;
				}
			}
		* => s[len s] = c;
		}
	}
	return (ref PdfObj(Ostring, 0, 0.0, s, nil, nil, nil), pos, nil);
}

parsename(data: array of byte, pos: int): (ref PdfObj, int, string)
{
	pos++;
	name := "";
	while(pos < len data){
		c := int data[pos];
		if(isws(c) || c == '/' || c == '<' || c == '>' ||
		   c == '[' || c == ']' || c == '(' || c == ')' ||
		   c == '{' || c == '}' || c == '%')
			break;
		if(c == '#' && pos+2 < len data){
			h1 := hexval(int data[pos+1]);
			h2 := hexval(int data[pos+2]);
			if(h1 >= 0 && h2 >= 0){
				name[len name] = h1 * 16 + h2;
				pos += 3;
				continue;
			}
		}
		name[len name] = c;
		pos++;
	}
	return (ref PdfObj(Oname, 0, 0.0, name, nil, nil, nil), pos, nil);
}

parsearray(data: array of byte, pos: int): (ref PdfObj, int, string)
{
	pos++;
	pos = skipws(data, pos);
	items: list of ref PdfObj;
	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data) break;
		if(int data[pos] == ']'){
			pos++;
			break;
		}
		(obj, p, err) := parseobj(data, pos);
		if(obj == nil) return (nil, p, err);
		items = obj :: items;
		pos = p;
	}
	rev: list of ref PdfObj;
	for(; items != nil; items = tl items)
		rev = hd items :: rev;
	return (ref PdfObj(Oarray, 0, 0.0, nil, rev, nil, nil), pos, nil);
}

parsenumber(data: array of byte, pos: int): (ref PdfObj, int, string)
{
	numstr := "";
	isreal := 0;
	start := pos;
	if(pos < len data && (int data[pos] == '-' || int data[pos] == '+')){
		numstr[len numstr] = int data[pos]; pos++;
	}
	while(pos < len data){
		c := int data[pos];
		if(c >= '0' && c <= '9'){
			numstr[len numstr] = c; pos++;
		} else if(c == '.' && !isreal){
			isreal = 1;
			numstr[len numstr] = c; pos++;
		} else
			break;
	}
	if(len numstr == 0)
		return (nil, start, "expected number");
	if(isreal)
		return (ref PdfObj(Oreal, 0, real numstr, nil, nil, nil, nil), pos, nil);

	num := int numstr;
	svpos := pos;
	pos = skipws(data, pos);
	if(pos < len data && int data[pos] >= '0' && int data[pos] <= '9'){
		genstr := "";
		while(pos < len data && int data[pos] >= '0' && int data[pos] <= '9'){
			genstr[len genstr] = int data[pos]; pos++;
		}
		pos = skipws(data, pos);
		if(pos < len data && int data[pos] == 'R'){
			pos++;
			gen := int genstr;
			return (ref PdfObj(Oref, num, real gen, nil, nil, nil, nil), pos, nil);
		}
	}
	return (ref PdfObj(Oint, num, 0.0, nil, nil, nil, nil), svpos, nil);
}

# ---- Object resolution ----

resolve(doc: ref PdfDoc, obj: ref PdfObj): ref PdfObj
{
	if(obj == nil) return nil;
	if(obj.kind != Oref) return obj;

	objnum := obj.ival;
	if(objnum < 0 || objnum >= doc.nobjs)
		return nil;

	entry := doc.xref[objnum];
	if(entry == nil || entry.inuse == 0) return nil;

	if(entry.inuse == 2)
		return resolveobjstm(doc, entry.offset, entry.gen);

	offset := entry.offset;
	if(offset >= len doc.data) return nil;

	pos := skipws(doc.data, offset);
	(nil, p1) := readint(doc.data, pos);
	pos = skipws(doc.data, p1);
	(nil, p2) := readint(doc.data, pos);
	pos = skipws(doc.data, p2);
	if(pos + 3 <= len doc.data && slicestr(doc.data, pos, 3) == "obj")
		pos += 3;
	pos = skipws(doc.data, pos);

	(parsed, nil, nil) := parseobj(doc.data, pos);
	if(parsed != nil && doc.enckey != nil && objnum != doc.encobjnum)
		parsed = decryptobj(doc, parsed, objnum, entry.gen);
	return parsed;
}

resolveobjstm(doc: ref PdfDoc, stmnum, idx: int): ref PdfObj
{
	if(stmnum < 0 || stmnum >= doc.nobjs) return nil;
	stmentry := doc.xref[stmnum];
	if(stmentry == nil || stmentry.inuse != 1) return nil;

	offset := stmentry.offset;
	if(offset >= len doc.data) return nil;

	pos := skipws(doc.data, offset);
	(nil, p1) := readint(doc.data, pos);
	pos = skipws(doc.data, p1);
	(nil, p2) := readint(doc.data, pos);
	pos = skipws(doc.data, p2);
	if(pos + 3 <= len doc.data && slicestr(doc.data, pos, 3) == "obj")
		pos += 3;
	pos = skipws(doc.data, pos);

	(stmobj, nil, nil) := parseobj(doc.data, pos);
	if(stmobj == nil || stmobj.kind != Ostream) return nil;

	# Decrypt the ObjStm container stream (individual objects inside are not encrypted)
	if(doc.enckey != nil && stmobj.stream != nil)
		stmobj.stream = decryptbytes(doc, stmobj.stream, stmnum, stmentry.gen, doc.encstmf);

	n := dictgetintres(doc, stmobj.dval, "N");
	first := dictgetintres(doc, stmobj.dval, "First");
	if(n <= 0 || first <= 0 || idx >= n) return nil;

	(sdata, derr) := decompressstream(stmobj);
	if(sdata == nil || derr != nil) return nil;

	spos := 0;
	offsets := array[n] of int;
	for(i := 0; i < n; i++){
		spos = skipwsbytes(sdata, spos);
		(nil, sp1) := readint(sdata, spos);
		spos = skipwsbytes(sdata, sp1);
		(ooff, sp2) := readint(sdata, spos);
		spos = sp2;
		offsets[i] = first + ooff;
	}

	if(idx >= n) return nil;
	opos := offsets[idx];
	if(opos >= len sdata) return nil;

	(parsed, nil, nil) := parseobj(sdata, opos);
	return parsed;
}

skipwsbytes(data: array of byte, pos: int): int
{
	while(pos < len data){
		c := int data[pos];
		if(c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 0)
			pos++;
		else
			break;
	}
	return pos;
}

# ---- Stream decompression ----

# A stream's data through its filters, in order, each with its
# DecodeParms.  An image codec's data (DCT, JPX, CCITT, JBIG2) is
# left for the image decoder: streamfilter() names the last filter.
decompressstream(obj: ref PdfObj): (array of byte, string)
{
	if(obj == nil || obj.kind != Ostream)
		return (nil, "not a stream");
	data := obj.stream;
	if(data == nil)
		return (nil, "empty stream");

	filters := filterlist(dictget(obj.dval, "Filter"));
	if(filters == nil)
		filters = filterlist(dictget(obj.dval, "F"));
	parms: list of ref PdfObj;
	dp := dictget(obj.dval, "DecodeParms");
	if(dp == nil)
		dp = dictget(obj.dval, "DP");
	if(dp != nil && dp.kind == Oarray)
		parms = dp.aval;
	else if(dp != nil)
		parms = dp :: nil;

	derr: string;
	for(; filters != nil; filters = tl filters){
		parm: ref PdfObj;
		if(parms != nil){
			parm = hd parms;
			parms = tl parms;
		}
		case hd filters {
		"FlateDecode" or "Fl" =>
			(data, derr) = inflate(data);
		"LZWDecode" or "LZW" =>
			early := 1;
			if(parm != nil && parm.kind == Odict && dictget(parm.dval, "EarlyChange") != nil)
				early = dictgetint(parm.dval, "EarlyChange");
			(data, derr) = lzwdecode(data, early);
		"ASCIIHexDecode" or "AHx" =>
			(data, derr) = asciihexdecode(data);
		"ASCII85Decode" or "A85" =>
			(data, derr) = ascii85decode(data);
		"RunLengthDecode" or "RL" =>
			(data, derr) = runlengthdecode(data);
		* =>
			return (data, nil);	# an image codec's, or unknown
		}
		if(data == nil)
			return (nil, derr);
		(data, derr) = unpredict(data, parm);
		if(data == nil)
			return (nil, derr);
	}
	return (data, nil);
}

filterlist(f: ref PdfObj): list of string
{
	if(f == nil)
		return nil;
	if(f.kind == Oname)
		return f.sval :: nil;
	if(f.kind != Oarray)
		return nil;
	r: list of string;
	for(l := f.aval; l != nil; l = tl l)
		if((hd l).kind == Oname)
			r = (hd l).sval :: r;
	o: list of string;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# the last filter a stream names: the codec its data is left in
streamfilter(obj: ref PdfObj): string
{
	last: string;
	for(l := filterlist(dictget(obj.dval, "Filter")); l != nil; l = tl l)
		last = hd l;
	return last;
}

# PNG and TIFF predictors (DecodeParms Predictor)
unpredict(data: array of byte, dp: ref PdfObj): (array of byte, string)
{
	if(dp == nil || dp.kind != Odict)
		return (data, nil);
	predictor := dictgetint(dp.dval, "Predictor");
	if(predictor < 2)
		return (data, nil);
	columns := dictgetint(dp.dval, "Columns");
	if(columns <= 0) columns = 1;
	colors := dictgetint(dp.dval, "Colors");
	if(colors <= 0) colors = 1;
	bpc := dictgetint(dp.dval, "BitsPerComponent");
	if(bpc <= 0) bpc = 8;
	if(predictor >= 10)
		return pngunpredict(data, columns, colors, bpc);
	if(predictor == 2)
		return (tiffunpredict(data, columns, colors, bpc), nil);
	return (data, nil);
}

# ASCII85Decode: groups of five base-85 digits for four bytes, z for
# four zeros, ~> the end
ascii85decode(data: array of byte): (array of byte, string)
{
	out := array[len data * 4 / 5 + 4] of byte;
	n := 0;
	v := 0;
	k := 0;
	for(i := 0; i < len data; i++){
		c := int data[i];
		if(c == '~')
			break;
		if(isws(c))
			continue;
		if(c == 'z' && k == 0){
			if(n + 4 > len out)
				out = grow(out, n + 4);
			out[n:] = array[4] of { * => byte 0 };
			n += 4;
			continue;
		}
		if(c < '!' || c > 'u')
			return (nil, "bad ASCII85 data");
		v = v*85 + c - '!';
		if(++k == 5){
			if(n + 4 > len out)
				out = grow(out, n + 4);
			out[n++] = byte (v >> 24);
			out[n++] = byte (v >> 16);
			out[n++] = byte (v >> 8);
			out[n++] = byte v;
			v = k = 0;
		}
	}
	if(k > 1){
		# a partial group: padded with u, one byte fewer than its digits
		for(j := k; j < 5; j++)
			v = v*85 + 84;
		if(n + 4 > len out)
			out = grow(out, n + 4);
		for(j = 0; j < k - 1; j++)
			out[n++] = byte (v >> (24 - 8*j));
	}
	return (out[0:n], nil);
}

grow(a: array of byte, need: int): array of byte
{
	n := len a * 2;
	if(n < need)
		n = need;
	b := array[n] of byte;
	b[0:] = a;
	return b;
}

# RunLengthDecode: a length byte, then that many plus one bytes (0-127),
# or one byte repeated 257 less it times (129-255); 128 ends it
runlengthdecode(data: array of byte): (array of byte, string)
{
	out := array[len data * 2] of byte;
	n := 0;
	for(i := 0; i < len data; ){
		l := int data[i++];
		if(l == 128)
			break;
		if(l < 128){
			m := l + 1;
			if(i + m > len data)
				m = len data - i;
			if(n + m > len out)
				out = grow(out, n + m);
			out[n:] = data[i:i+m];
			n += m;
			i += m;
		} else {
			if(i >= len data)
				break;
			m := 257 - l;
			if(n + m > len out)
				out = grow(out, n + m);
			for(j := 0; j < m; j++)
				out[n++] = data[i];
			i++;
		}
	}
	return (out[0:n], nil);
}

# LZWDecode: 9- to 12-bit codes, MSB first; 256 clears, 257 ends;
# early (EarlyChange 1, the default) widens a code early
lzwdecode(data: array of byte, early: int): (array of byte, string)
{
	prefix := array[4096] of int;
	suffix := array[4096] of byte;
	length := array[4096] of int;
	for(c := 0; c < 256; c++){
		prefix[c] = -1;
		suffix[c] = byte c;
		length[c] = 1;
	}
	out := array[len data * 3 + 16] of byte;
	n := 0;
	next := 258;
	width := 9;
	prev := -1;
	bits := 0;
	nbits := 0;
	for(i := 0; ; ){
		while(nbits < width && i < len data){
			bits = (bits << 8) | int data[i++];
			nbits += 8;
		}
		if(nbits < width)
			break;
		code := (bits >> (nbits - width)) & ((1 << width) - 1);
		nbits -= width;
		bits &= (1 << nbits) - 1;
		if(code == 256){
			next = 258;
			width = 9;
			prev = -1;
			continue;
		}
		if(code == 257)
			break;
		if(code > next || (code == next && prev < 0))
			return (out[0:n], nil);	# corrupt: what there is
		# the string for code (or prev's plus its own first byte)
		ncode := code;
		if(code == next)
			ncode = prev;
		l := length[ncode];
		tot := l;
		if(code == next)
			tot++;
		if(n + tot > len out)
			out = grow(out, n + tot);
		p := ncode;
		for(j := l - 1; j >= 0; j--){
			out[n + j] = suffix[p];
			p = prefix[p];
		}
		if(code == next)
			out[n + l] = out[n];
		first := out[n];
		n += tot;
		if(prev >= 0 && next < 4096){
			prefix[next] = prev;
			suffix[next] = first;
			length[next] = length[prev] + 1;
			next++;
		}
		prev = code;
		if(next + early >= (1 << width) && width < 12)
			width++;
	}
	return (out[0:n], nil);
}

pngunpredict(data: array of byte, columns, colors, bpc: int): (array of byte, string)
{
	# Row width in bytes (the actual data, not including the filter byte)
	rowbytes := (columns * colors * bpc + 7) / 8;
	# Each row in the compressed data has 1 filter byte + rowbytes data bytes
	srcrow := 1 + rowbytes;

	if(srcrow <= 0)
		return (nil, "invalid predictor parameters");

	nrows := len data / srcrow;
	if(nrows <= 0)
		return (nil, "no rows in predicted data");

	out := array[nrows * rowbytes] of byte;
	prev := array[rowbytes] of {* => byte 0};
	bpp := (colors * bpc + 7) / 8;  # bytes per pixel (for Sub/Average/Paeth)

	for(row := 0; row < nrows; row++){
		soff := row * srcrow;
		doff := row * rowbytes;
		if(soff >= len data)
			break;
		ftype := int data[soff];
		soff++;

		case ftype {
		0 =>
			# None
			for(i := 0; i < rowbytes && soff + i < len data; i++)
				out[doff + i] = data[soff + i];
		1 =>
			# Sub
			for(i := 0; i < rowbytes && soff + i < len data; i++){
				a := 0;
				if(i >= bpp)
					a = int out[doff + i - bpp];
				out[doff + i] = byte ((int data[soff + i] + a) & 16rFF);
			}
		2 =>
			# Up
			for(i := 0; i < rowbytes && soff + i < len data; i++)
				out[doff + i] = byte ((int data[soff + i] + int prev[i]) & 16rFF);
		3 =>
			# Average
			for(i := 0; i < rowbytes && soff + i < len data; i++){
				a := 0;
				if(i >= bpp)
					a = int out[doff + i - bpp];
				b := int prev[i];
				out[doff + i] = byte ((int data[soff + i] + (a + b) / 2) & 16rFF);
			}
		4 =>
			# Paeth
			for(i := 0; i < rowbytes && soff + i < len data; i++){
				a := 0;
				if(i >= bpp)
					a = int out[doff + i - bpp];
				b := int prev[i];
				c := 0;
				if(i >= bpp)
					c = int prev[i - bpp];
				out[doff + i] = byte ((int data[soff + i] + paethpredict(a, b, c)) & 16rFF);
			}
		* =>
			# Unknown filter type — treat as None
			for(i := 0; i < rowbytes && soff + i < len data; i++)
				out[doff + i] = data[soff + i];
		}

		# Save this row as previous for next iteration
		prev[0:] = out[doff:doff + rowbytes];
	}

	return (out, nil);
}

paethpredict(a, b, c: int): int
{
	p := a + b - c;
	pa := p - a;
	if(pa < 0) pa = -pa;
	pb := p - b;
	if(pb < 0) pb = -pb;
	pc := p - c;
	if(pc < 0) pc = -pc;
	if(pa <= pb && pa <= pc) return a;
	if(pb <= pc) return b;
	return c;
}

# TIFF Predictor 2: horizontal differencing
tiffunpredict(data: array of byte, columns, colors, bpc: int): array of byte
{
	if(bpc != 8) return data;  # only handle 8-bit for now
	rowbytes := columns * colors;
	if(rowbytes <= 0) return data;

	nrows := len data / rowbytes;
	for(row := 0; row < nrows; row++){
		off := row * rowbytes;
		for(i := colors; i < rowbytes && off + i < len data; i++)
			data[off + i] = byte ((int data[off + i] + int data[off + i - colors]) & 16rFF);
	}
	return data;
}

inflate(data: array of byte): (array of byte, string)
{
	filtermod = load Filter Filter->INFLATEPATH;
	if(filtermod == nil)
		return (nil, sys->sprint("cannot load inflate: %r"));

	filtermod->init();
	rqchan := filtermod->start("z");

	rq := <-rqchan;
	pick r := rq {
	Start => ;
	* => return (nil, "inflate: unexpected initial message");
	}

	result: list of array of byte;
	resultlen := 0;
	inpos := 0;
	done := 0;

	while(!done){
		rq = <-rqchan;
		pick r := rq {
		Fill =>
			n := len data - inpos;
			if(n > len r.buf) n = len r.buf;
			if(n > 0) r.buf[0:] = data[inpos:inpos+n];
			inpos += n;
			r.reply <-= n;
		Result =>
			chunk := array[len r.buf] of byte;
			chunk[0:] = r.buf;
			result = chunk :: result;
			resultlen += len chunk;
			r.reply <-= 0;
		Info => ;
		Finished => done = 1;
		Error => return (nil, "inflate error: " + r.e);
		* => done = 1;
		}
	}

	out := array[resultlen] of byte;
	pos := resultlen;
	for(; result != nil; result = tl result){
		chunk := hd result;
		pos -= len chunk;
		out[pos:] = chunk;
	}
	return (out, nil);
}

asciihexdecode(data: array of byte): (array of byte, string)
{
	out := array[len data / 2 + 1] of byte;
	n := 0;
	nibble := -1;
	for(i := 0; i < len data; i++){
		c := int data[i];
		if(c == '>') break;
		if(isws(c)) continue;
		v := hexval(c);
		if(v < 0) continue;
		if(nibble < 0)
			nibble = v;
		else {
			out[n++] = byte (nibble * 16 + v);
			nibble = -1;
		}
	}
	if(nibble >= 0)
		out[n++] = byte (nibble * 16);
	return (out[0:n], nil);
}

# ---- Text extraction ----

extracttext(doc: ref PdfDoc): (string, string)
{
	root := dictget(doc.trailer.dval, "Root");
	if(root == nil) return (nil, "no Root in trailer");
	root = resolve(doc, root);
	if(root == nil) return (nil, "cannot resolve Root");

	pages := dictget(root.dval, "Pages");
	if(pages == nil) return (nil, "no Pages in catalog");
	pages = resolve(doc, pages);
	if(pages == nil) return (nil, "cannot resolve Pages");

	text := "";
	pagenum := 0;
	(text, pagenum) = extractpages(doc, pages, text, pagenum);
	if(pagenum == 0)
		return (nil, "no pages found");
	return (text, nil);
}

extractpages(doc: ref PdfDoc, node: ref PdfObj,
	text: string, pagenum: int): (string, int)
{
	if(node == nil)
		return (text, pagenum);

	typobj := dictget(node.dval, "Type");
	typ := "";
	if(typobj != nil && typobj.kind == Oname)
		typ = typobj.sval;

	if(typ == "Pages"){
		kids := dictget(node.dval, "Kids");
		if(kids != nil && kids.kind == Oarray){
			for(k := kids.aval; k != nil; k = tl k){
				child := resolve(doc, hd k);
				if(child != nil)
					(text, pagenum) = extractpages(doc, child, text, pagenum);
			}
		}
	} else if(typ == "Page"){
		pagenum++;
		if(len text > 0) text += "\n\n";
		if(pagenum > 1)
			text += "--- Page " + string pagenum + " ---\n\n";

		fontmap := buildfontmap(doc, node);
		contents := dictget(node.dval, "Contents");
		if(contents != nil){
			pagetext := extractpagetext_cs(doc, contents, fontmap);
			if(pagetext != nil)
				text += pagetext;
		}
	}
	return (text, pagenum);
}

# Extract text for a single page (public API)
extractpagetext_full(doc: ref PdfDoc, page: ref PdfObj): string
{
	fontmap := buildfontmap(doc, page);
	contents := dictget(page.dval, "Contents");
	if(contents == nil)
		return nil;
	return extractpagetext_cs(doc, contents, fontmap);
}

extractpagetext_cs(doc: ref PdfDoc, contents: ref PdfObj,
	fontmap: list of ref FontMapEntry): string
{
	if(contents == nil) return nil;
	contents = resolve(doc, contents);
	if(contents == nil) return nil;

	if(contents.kind == Oarray){
		text := "";
		for(a := contents.aval; a != nil; a = tl a){
			stream := resolve(doc, hd a);
			if(stream != nil){
				t := extractstreamtext(doc, stream, fontmap);
				if(t != nil) text += t;
			}
		}
		return text;
	}
	if(contents.kind == Ostream)
		return extractstreamtext(doc, contents, fontmap);
	return nil;
}

extractstreamtext(doc: ref PdfDoc, stream: ref PdfObj,
	fontmap: list of ref FontMapEntry): string
{
	(data, nil) := decompressstream(stream);
	if(data == nil) return nil;
	return parsecontentstream_text(data, fontmap);
}

# Parse content stream for text extraction only
parsecontentstream_text(data: array of byte, fontmap: list of ref FontMapEntry): string
{
	text := "";
	pos := 0;
	operands: list of string;
	curfont: ref FontMapEntry;

	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data) break;
		c := int data[pos];

		if(c == '('){
			(s, newpos) := readlitstr(data, pos);
			operands = s :: operands;
			pos = newpos;
			continue;
		}
		if(c == '<' && (pos+1 >= len data || int data[pos+1] != '<')){
			(s, newpos) := readhexstr(data, pos);
			operands = s :: operands;
			pos = newpos;
			continue;
		}
		if(c == '['){
			(s, newpos) := readtjarray(data, pos, curfont);
			operands = s :: operands;
			pos = newpos;
			continue;
		}
		if(c == '<' && pos+1 < len data && int data[pos+1] == '<'){
			pos = skipdict(data, pos);
			continue;
		}
		if(c == '/'){
			(tok, newpos) := readcsname(data, pos);
			operands = tok :: operands;
			pos = newpos;
			continue;
		}
		if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'){
			(tok, newpos) := readtoken(data, pos);
			operands = tok :: operands;
			pos = newpos;
			continue;
		}
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   c == '\'' || c == '"' || c == '*'){
			(op, newpos) := readtoken(data, pos);
			pos = newpos;

			case op {
			"Tj" =>
				if(operands != nil){
					s := hd operands;
					if(curfont != nil)
						s = decodecidstr(s, curfont);
					text += cleanpdftext(s);
				}
			"TJ" =>
				if(operands != nil)
					text += cleanpdftext(hd operands);
			"'" =>
				if(operands != nil){
					s := hd operands;
					if(curfont != nil)
						s = decodecidstr(s, curfont);
					text += "\n" + cleanpdftext(s);
				}
			"\"" =>
				if(operands != nil){
					s := hd operands;
					if(curfont != nil)
						s = decodecidstr(s, curfont);
					text += "\n" + cleanpdftext(s);
				}
			"Td" or "TD" =>
				if(operands != nil && tl operands != nil){
					ty := real (hd operands);
					tx := real (hd tl operands);
					if(ty < -1.5 || ty > 1.5)
						text += "\n";
					else if(tx > 5.0)
						text += " ";
				}
			"T*" =>
				text += "\n";
			"Tf" =>
				if(operands != nil && tl operands != nil)
					curfont = fontmaplookup(fontmap, hd tl operands);
			"BI" =>
				pos = skipinlineimage(data, pos);
			}
			operands = nil;
			continue;
		}
		if(c == '%'){
			while(pos < len data && int data[pos] != '\n')
				pos++;
			continue;
		}
		pos++;
	}
	return text;
}

# The words a content stream shows, with their boxes on a page ph
# points high: the text state (matrices, font, size, spacing) followed
# as the renderer follows it, each word measured as the renderer
# measures the text it draws. Newest first.
contentwords(doc: ref PdfDoc, data: array of byte, fontmap: list of ref FontMapEntry, ph: real): list of (string, Rect)
{
	words: list of (string, Rect);
	ctm := array[] of {1.0, 0.0, 0.0, 1.0, 0.0, 0.0};
	stack: list of array of real;
	tm := array[] of {1.0, 0.0, 0.0, 1.0, 0.0, 0.0};
	tlm := array[] of {1.0, 0.0, 0.0, 1.0, 0.0, 0.0};
	fs := 0.0;
	lead := 0.0;
	tc := 0.0;
	tw := 0.0;
	th := 1.0;
	curfont: ref FontMapEntry;
	operands: list of string;
	tjpos := -1;
	pos := 0;

	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data)
			break;
		c := int data[pos];
		if(c == '('){
			(st, np) := readlitstr(data, pos);
			operands = st :: operands;
			pos = np;
			continue;
		}
		if(c == '<' && (pos+1 >= len data || int data[pos+1] != '<')){
			(st, np) := readhexstr(data, pos);
			operands = st :: operands;
			pos = np;
			continue;
		}
		if(c == '['){
			tjpos = pos;
			pos = skiptjarray(data, pos);
			continue;
		}
		if(c == '<'){
			pos = skipdict(data, pos);
			continue;
		}
		if(c == '/'){
			(tok, np) := readcsname(data, pos);
			operands = tok :: operands;
			pos = np;
			continue;
		}
		if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'){
			(tok, np) := readtoken(data, pos);
			operands = tok :: operands;
			pos = np;
			continue;
		}
		if(c == '%'){
			while(pos < len data && int data[pos] != '\n')
				pos++;
			continue;
		}
		if(!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '\'' || c == '"' || c == '*')){
			pos++;
			continue;
		}
		(op, np) := readtoken(data, pos);
		pos = np;
		nums := numargs(operands);
		case op {
		"q" =>
			stack = copym(ctm) :: stack;
		"Q" =>
			if(stack != nil){
				ctm = hd stack;
				stack = tl stack;
			}
		"cm" =>
			if(len nums == 6)
				ctm = matmul(nums, ctm);
		"BT" =>
			tm = array[] of {1.0, 0.0, 0.0, 1.0, 0.0, 0.0};
			tlm = copym(tm);
		"Tm" =>
			if(len nums == 6){
				tm = nums;
				tlm = copym(tm);
			}
		"Td" or "TD" =>
			if(len nums == 2){
				if(op == "TD")
					lead = -nums[1];
				tlm = matmul(array[] of {1.0, 0.0, 0.0, 1.0, nums[0], nums[1]}, tlm);
				tm = copym(tlm);
			}
		"T*" =>
			tlm = matmul(array[] of {1.0, 0.0, 0.0, 1.0, 0.0, -lead}, tlm);
			tm = copym(tlm);
		"TL" =>
			if(len nums == 1)
				lead = nums[0];
		"Tc" =>
			if(len nums == 1)
				tc = nums[0];
		"Tw" =>
			if(len nums == 1)
				tw = nums[0];
		"Tz" =>
			if(len nums == 1)
				th = nums[0] / 100.0;
		"Tf" =>
			if(operands != nil && tl operands != nil){
				fs = real hd operands;
				curfont = fontmaplookup(fontmap, hd tl operands);
			}
		"Tj" or "'" or "\"" or "TJ" =>
			if(op == "\"" && len nums >= 2){
				tw = nums[0];
				tc = nums[1];
			}
			if(op == "'" || op == "\""){
				tlm = matmul(array[] of {1.0, 0.0, 0.0, 1.0, 0.0, -lead}, tlm);
				tm = copym(tlm);
			}
			items: list of (string, real);
			if(op == "TJ"){
				if(tjpos >= 0)
					items = tjitems(data, tjpos);
				tjpos = -1;
			} else if(operands != nil)
				items = (hd operands, 0.0) :: nil;
			if(items != nil){
				f := fontof(curfont);
				if(f == nil)
					f = deffont(doc);
				fontload(doc, f);
				adv: real;
				(words, adv) = showwords(words, f, items, fs, tc, tw, th, matmul(tm, ctm), ph);
				tm = matmul(array[] of {1.0, 0.0, 0.0, 1.0, adv, 0.0}, tm);
			}
		"BI" =>
			pos = skipinlineimage(data, pos);
		}
		operands = nil;
	}
	return words;
}

# The words of text shown at trm (text space to page, y up), each
# with its box on the page (y down), measured by the widths the
# renderer advances by; and how far the text advances.  The items are
# a TJ array's strings, each with the adjustment before it.
showwords(words: list of (string, Rect), f: ref PdfFont, items: list of (string, real),
	fs, tc, tw, th: real, trm: array of real, ph: real): (list of (string, Rect), real)
{
	x := 0.0;
	w := "";
	x0 := 0.0;
	for(; items != nil; items = tl items){
		(text, kern) := hd items;
		k := -kern / 1000.0 * fs * th;
		if(k > 0.2 * fs && w != ""){
			words = (w, wordbox(trm, x0, x, fs, ph)) :: words;
			w = "";
		}
		x += k;
		for(i := 0; i < len text; ){
			(code, step) := nextcode(f, text, i);
			i += step;
			cid := code;
			if(f.cidmap != nil)
				cid = cmapcid(f.cidmap, code);
			a := (codewidth(f, cid) * fs + tc) * th;
			if(step == 1 && code == 32)
				a += tw * th;
			u := unicodeof(f, code);
			if(u <= 32 || u == 16rA0){
				if(w != "")
					words = (w, wordbox(trm, x0, x, fs, ph)) :: words;
				w = "";
			} else {
				if(w == "")
					x0 = x;
				if(u >= 16rFB00 && u <= 16rFB06)
					w += ligatures[u - 16rFB00];
				else
					w[len w] = u;
			}
			x += a;
		}
	}
	if(w != "")
		words = (w, wordbox(trm, x0, x, fs, ph)) :: words;
	return (words, x);
}

ligatures := array[] of {"ff", "fi", "fl", "ffi", "ffl", "ft", "st"};

# A TJ array's strings, each with the number before it (0 if none),
# and one more for a number at the end.
tjitems(data: array of byte, pos: int): list of (string, real)
{
	r: list of (string, real);
	kern := 0.0;
	pos++;
	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data)
			break;
		c := int data[pos];
		if(c == ']')
			break;
		if(c == '(' || c == '<'){
			s: string;
			if(c == '(')
				(s, pos) = readlitstr(data, pos);
			else
				(s, pos) = readhexstr(data, pos);
			r = (s, kern) :: r;
			kern = 0.0;
		} else if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'){
			v: real;
			(v, pos) = readreal(data, pos);
			kern += v;
		} else
			pos++;
	}
	if(kern != 0.0)
		r = ("", kern) :: r;
	o: list of (string, real);
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# The box, on the page, of text space x0..x1 by the font's height
wordbox(trm: array of real, x0, x1, fs, ph: real): Rect
{
	ys := array[] of {-0.22 * fs, 0.88 * fs};
	xs := array[] of {x0, x1};
	minx := 1.0e9;
	miny := 1.0e9;
	maxx := -1.0e9;
	maxy := -1.0e9;
	for(i := 0; i < 2; i++)
		for(j := 0; j < 2; j++){
			px := xs[i]*trm[0] + ys[j]*trm[2] + trm[4];
			py := ph - (xs[i]*trm[1] + ys[j]*trm[3] + trm[5]);
			if(px < minx) minx = px;
			if(px > maxx) maxx = px;
			if(py < miny) miny = py;
			if(py > maxy) maxy = py;
		}
	return Rect((int minx, int miny), (int (maxx + 0.5), int (maxy + 0.5)));
}

# The numeric operands, in order (operands are newest first)
numargs(l: list of string): array of real
{
	n := 0;
	for(t := l; t != nil; t = tl t)
		n++;
	a := array[n] of real;
	for(i := n - 1; l != nil; l = tl l)
		a[i--] = real hd l;
	return a;
}

copym(m: array of real): array of real
{
	r := array[6] of real;
	r[0:] = m;
	return r;
}

# ---- Content stream reading helpers ----

readlitstr(data: array of byte, pos: int): (string, int)
{
	pos++;
	depth := 1;
	s := "";
	while(pos < len data && depth > 0){
		c := int data[pos]; pos++;
		case c {
		'(' =>
			depth++;
			s[len s] = c;
		')' =>
			depth--;
			if(depth > 0) s[len s] = c;
		'\\' =>
			if(pos < len data){
				ec := int data[pos]; pos++;
				case ec {
				'n' => s[len s] = '\n';
				'r' => s[len s] = '\r';
				't' => s[len s] = '\t';
				'(' => s[len s] = '(';
				')' => s[len s] = ')';
				'\\' => s[len s] = '\\';
				'0' to '7' =>
					oct := ec - '0';
					if(pos < len data && int data[pos] >= '0' && int data[pos] <= '7'){
						oct = oct * 8 + (int data[pos] - '0');
						pos++;
					}
					if(pos < len data && int data[pos] >= '0' && int data[pos] <= '7'){
						oct = oct * 8 + (int data[pos] - '0');
						pos++;
					}
					s[len s] = oct;
				* => s[len s] = ec;
				}
			}
		* => s[len s] = c;
		}
	}
	return (s, pos);
}

readhexstr(data: array of byte, pos: int): (string, int)
{
	pos++;
	s := "";
	nibble := -1;
	while(pos < len data){
		c := int data[pos]; pos++;
		if(c == '>') break;
		if(isws(c)) continue;
		v := hexval(c);
		if(v < 0) continue;
		if(nibble < 0)
			nibble = v;
		else {
			s[len s] = nibble * 16 + v;
			nibble = -1;
		}
	}
	if(nibble >= 0)
		s[len s] = nibble * 16;
	return (s, pos);
}

readtjarray(data: array of byte, pos: int, curfont: ref FontMapEntry): (string, int)
{
	pos++;
	s := "";
	# Always decode CID→Unicode here.  The outline font rendering path
	# uses rendertjraw()/skiptjarray() instead, so readtjarray() is only
	# called for text extraction and non-outline rendering — both need decoding.
	while(pos < len data){
		pos = skipws(data, pos);
		if(pos >= len data) break;
		c := int data[pos];
		if(c == ']'){
			pos++;
			break;
		}
		if(c == '('){
			(substr, newpos) := readlitstr(data, pos);
			if(curfont != nil) substr = decodecidstr(substr, curfont);
			s += substr;
			pos = newpos;
			continue;
		}
		if(c == '<'){
			(substr, newpos) := readhexstr(data, pos);
			if(curfont != nil) substr = decodecidstr(substr, curfont);
			s += substr;
			pos = newpos;
			continue;
		}
		if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'){
			numstr := "";
			while(pos < len data){
				nc := int data[pos];
				if((nc >= '0' && nc <= '9') || nc == '-' || nc == '+' || nc == '.')
					numstr[len numstr] = nc;
				else
					break;
				pos++;
			}
			if(len numstr > 0){
				kern := real numstr;
				if(kern < -100.0)
					s += " ";
			}
			continue;
		}
		pos++;
	}
	return (s, pos);
}

readtoken(data: array of byte, pos: int): (string, int)
{
	tok := "";
	while(pos < len data){
		c := int data[pos];
		if(isws(c) || c == '(' || c == ')' || c == '<' || c == '>' ||
		   c == '[' || c == ']' || c == '{' || c == '}' || c == '/' || c == '%')
			break;
		tok[len tok] = c;
		pos++;
	}
	return (tok, pos);
}

readcsname(data: array of byte, pos: int): (string, int)
{
	pos++;
	name := "";
	while(pos < len data){
		c := int data[pos];
		if(isws(c) || c == '/' || c == '<' || c == '>' ||
		   c == '[' || c == ']' || c == '(' || c == ')' ||
		   c == '{' || c == '}' || c == '%')
			break;
		name[len name] = c;
		pos++;
	}
	return (name, pos);
}

skipinlineimage(data: array of byte, pos: int): int
{
	while(pos < len data - 1){
		if(int data[pos] == 'I' && int data[pos+1] == 'D'){
			pos += 2;
			break;
		}
		pos++;
	}
	while(pos < len data - 1){
		if(int data[pos] == 'E' && int data[pos+1] == 'I'){
			if(pos > 0 && isws(int data[pos-1])){
				pos += 2;
				return pos;
			}
		}
		pos++;
	}
	return pos;
}

skipdict(data: array of byte, pos: int): int
{
	pos += 2;
	depth := 1;
	while(pos < len data - 1 && depth > 0){
		if(int data[pos] == '<' && int data[pos+1] == '<'){
			depth++;
			pos += 2;
		} else if(int data[pos] == '>' && int data[pos+1] == '>'){
			depth--;
			pos += 2;
		} else
			pos++;
	}
	return pos;
}

cleanpdftext(s: string): string
{
	if(s == nil) return nil;
	out := "";
	lastspace := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\r' || c == '\n'){
			if(!lastspace){
				out[len out] = '\n';
				lastspace = 1;
			}
		} else if(c < ' '){
			if(!lastspace){
				out[len out] = ' ';
				lastspace = 1;
			}
		} else {
			out[len out] = c;
			lastspace = 0;
		}
	}
	return out;
}

# ---- ToUnicode CMap support ----

parsecmap(text: string): (int, list of ref CMapEntry)
{
	entries: list of ref CMapEntry;
	twobyte := 0;
	pos := 0;
	tlen := len text;

	while(pos < tlen){
		if(pos + 19 <= tlen && text[pos:pos+19] == "begincodespacerange"){
			pos += 19;
			while(pos < tlen && text[pos] != '<') pos++;
			if(pos < tlen){
				(nil, np) := parsecmaphex(text, pos);
				hstart := pos + 1;
				ndigits := 0;
				for(h := hstart; h < tlen && text[h] != '>'; h++)
					ndigits++;
				if(ndigits >= 4) twobyte = 1;
				pos = np;
			}
			continue;
		}
		if(pos + 11 <= tlen && text[pos:pos+11] == "beginbfchar"){
			pos += 11;
			for(;;){
				while(pos < tlen && (text[pos] == ' ' || text[pos] == '\n' || text[pos] == '\r' || text[pos] == '\t'))
					pos++;
				if(pos + 9 <= tlen && text[pos:pos+9] == "endbfchar")
					break;
				if(pos >= tlen) break;
				if(text[pos] != '<'){
					pos++;
					continue;
				}
				(cid, np1) := parsecmaphex(text, pos);
				pos = np1;
				while(pos < tlen && text[pos] != '<') pos++;
				if(pos >= tlen) break;
				(uni, np2) := parsecmaphex(text, pos);
				pos = np2;
				entries = ref CMapEntry(cid, cid, uni) :: entries;
			}
			continue;
		}
		if(pos + 12 <= tlen && text[pos:pos+12] == "beginbfrange"){
			pos += 12;
			for(;;){
				while(pos < tlen && (text[pos] == ' ' || text[pos] == '\n' || text[pos] == '\r' || text[pos] == '\t'))
					pos++;
				if(pos + 10 <= tlen && text[pos:pos+10] == "endbfrange")
					break;
				if(pos >= tlen) break;
				if(text[pos] != '<'){
					pos++;
					continue;
				}
				(lo, np1) := parsecmaphex(text, pos);
				pos = np1;
				while(pos < tlen && text[pos] != '<') pos++;
				if(pos >= tlen) break;
				(hi, np2) := parsecmaphex(text, pos);
				pos = np2;
				while(pos < tlen && text[pos] != '<') pos++;
				if(pos >= tlen) break;
				(uni, np3) := parsecmaphex(text, pos);
				pos = np3;
				entries = ref CMapEntry(lo, hi, uni) :: entries;
			}
			continue;
		}
		pos++;
	}
	return (twobyte, entries);
}

parsecmaphex(s: string, pos: int): (int, int)
{
	slen := len s;
	if(pos >= slen || s[pos] != '<')
		return (0, pos);
	pos++;
	val := 0;
	while(pos < slen && s[pos] != '>'){
		c := s[pos]; pos++;
		v := hexval(c);
		if(v >= 0) val = (val << 4) | v;
	}
	if(pos < slen && s[pos] == '>') pos++;
	return (val, pos);
}

buildfontmap(doc: ref PdfDoc, page: ref PdfObj): list of ref FontMapEntry
{
	return buildfontmapres(doc, getresources(doc, page));
}

# The fonts a resource dictionary names, each made once a document
buildfontmapres(doc: ref PdfDoc, resources: ref PdfObj): list of ref FontMapEntry
{
	if(resources == nil) return nil;

	fonts := dictget(resources.dval, "Font");
	if(fonts == nil) return nil;
	fonts = resolve(doc, fonts);
	if(fonts == nil || (fonts.kind != Odict && fonts.kind != Ostream))
		return nil;

	fontmap: list of ref FontMapEntry;
	for(fl := fonts.dval; fl != nil; fl = tl fl){
		de := hd fl;
		f: ref PdfFont;
		num := -1;
		if(de.val != nil && de.val.kind == Oref){
			num = de.val.ival;
			for(l := doc.fonts; l != nil; l = tl l)
				if((hd l).t0 == num){
					f = (hd l).t1;
					break;
				}
		}
		if(f == nil){
			fontobj := resolve(doc, de.val);
			if(fontobj == nil || fontobj.kind != Odict)
				continue;
			f = newfont(doc, fontobj);
			if(num >= 0)
				doc.fonts = (num, f) :: doc.fonts;
		}
		fontmap = ref FontMapEntry(de.key, f) :: fontmap;
	}
	return fontmap;
}

fontof(e: ref FontMapEntry): ref PdfFont
{
	if(e == nil)
		return nil;
	return e.f;
}

# Parse the PDF W (widths) array into a per-GID width array.
# W array format: [cid_start [w1 w2 ...]] or [cid_start cid_end w]
parsepdfwidths(wlist: list of ref PdfObj, dw: int): array of int
{
	# the largest CID named: c [w ...] or c1 c2 w
	maxgid := 0;
	for(wl := wlist; wl != nil; wl = tl wl){
		o := hd wl;
		if(o.kind != Oint || tl wl == nil)
			continue;
		n := hd tl wl;
		last := o.ival;
		if(n.kind == Oarray)
			last += lenlistobj(n.aval);
		else if(n.kind == Oint){
			last = n.ival;
			if(tl tl wl != nil)
				wl = tl wl;
		}
		if(last > maxgid)
			maxgid = last;
		wl = tl wl;
	}
	maxgid++;
	if(maxgid > 65536)
		maxgid = 65536;

	widths := array[maxgid] of { * => -1 };

	# Second pass: parse entries
	wl = wlist;
	while(wl != nil){
		o := hd wl;
		wl = tl wl;
		if(o.kind != Oint)
			continue;
		cid_start := o.ival;

		if(wl == nil) break;
		next := hd wl;

		if(next.kind == Oarray){
			# [cid_start [w1 w2 w3 ...]]
			wl = tl wl;
			ci := cid_start;
			for(al := next.aval; al != nil; al = tl al){
				wo := hd al;
				w := dw;
				if(wo.kind == Oint)
					w = wo.ival;
				else if(wo.kind == Oreal)
					w = int wo.rval;
				if(ci >= 0 && ci < maxgid)
					widths[ci] = w;
				ci++;
			}
		} else if(next.kind == Oint){
			# [cid_start cid_end w]
			cid_end := next.ival;
			wl = tl wl;
			if(wl == nil) break;
			wo := hd wl;
			wl = tl wl;
			w := dw;
			if(wo.kind == Oint)
				w = wo.ival;
			else if(wo.kind == Oreal)
				w = int wo.rval;
			for(ci := cid_start; ci <= cid_end; ci++){
				if(ci >= 0 && ci < maxgid)
					widths[ci] = w;
			}
		}
	}

	return widths;
}

cmaplookup(entries: list of ref CMapEntry, cid: int): int
{
	for(; entries != nil; entries = tl entries){
		e := hd entries;
		if(cid >= e.lo && cid <= e.hi)
			return e.unicode + (cid - e.lo);
	}
	return cid;
}

decodecidstr(s: string, e: ref FontMapEntry): string
{
	if(e == nil || e.f == nil)
		return s;
	fm := e.f;
	if(fm.entries == nil && fm.code2uni == nil)
		return s;
	out := "";
	for(i := 0; i < len s; ){
		(code, n) := nextcode(fm, s, i);
		i += n;
		if(n > 1 && code == 0)
			continue;
		uni := unicodeof(fm, code);
		if(uni > 0)
			out[len out] = uni;
	}
	return out;
}

fontmaplookup(fontmap: list of ref FontMapEntry, name: string): ref FontMapEntry
{
	for(; fontmap != nil; fontmap = tl fontmap){
		fm := hd fontmap;
		if(fm.name == name)
			return fm;
	}
	return nil;
}

# ---- Utility functions ----

dictget(entries: list of ref DictEntry, key: string): ref PdfObj
{
	for(; entries != nil; entries = tl entries){
		e := hd entries;
		if(e.key == key) return e.val;
	}
	return nil;
}

dictgetint(entries: list of ref DictEntry, key: string): int
{
	obj := dictget(entries, key);
	if(obj == nil) return 0;
	if(obj.kind == Oint) return obj.ival;
	return 0;
}

# Like dictgetint but resolves indirect references first
dictgetintres(doc: ref PdfDoc, entries: list of ref DictEntry, key: string): int
{
	obj := dictget(entries, key);
	if(obj == nil) return 0;
	if(obj.kind == Oref)
		obj = resolve(doc, obj);
	if(obj != nil && obj.kind == Oint) return obj.ival;
	return 0;
}

slicestr(data: array of byte, pos, length: int): string
{
	if(pos + length > len data) length = len data - pos;
	s := "";
	for(i := 0; i < length; i++)
		s[len s] = int data[pos + i];
	return s;
}

readint(data: array of byte, pos: int): (int, int)
{
	start := pos;
	while(pos < len data && int data[pos] >= '0' && int data[pos] <= '9')
		pos++;
	if(pos == start) return (0, start);
	return (int slicestr(data, start, pos - start), pos);
}

skipws(data: array of byte, pos: int): int
{
	while(pos < len data){
		c := int data[pos];
		if(c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 0)
			pos++;
		else if(c == '%'){
			while(pos < len data && int data[pos] != '\n')
				pos++;
		} else
			break;
	}
	return pos;
}

isws(c: int): int
{
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 0;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'f') return c - 'a' + 10;
	if(c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

# ---- PDF Encryption / Decryption ----

# Standard PDF password padding (Table 3.19, 32 bytes)
PDFPAD := array[] of {
	byte 16r28, byte 16rBF, byte 16r4E, byte 16r5E,
	byte 16r4E, byte 16r75, byte 16r8A, byte 16r41,
	byte 16r64, byte 16r00, byte 16r4E, byte 16r56,
	byte 16rFF, byte 16rFA, byte 16r01, byte 16r08,
	byte 16r2E, byte 16r2E, byte 16r00, byte 16rB6,
	byte 16rD0, byte 16r68, byte 16r3E, byte 16r80,
	byte 16r2F, byte 16r0C, byte 16rA9, byte 16rFE,
	byte 16r64, byte 16r53, byte 16r69, byte 16r7A
};

# Convert Limbo string (byte values in chars) to byte array
strtobytes(s: string): array of byte
{
	b := array[len s] of byte;
	for(i := 0; i < len s; i++)
		b[i] = byte s[i];
	return b;
}

# Convert byte array to Limbo string (each byte becomes a char)
bytestostr(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++)
		s[len s] = int b[i];
	return s;
}

# Pad or truncate password to 32 bytes per PDF spec
padpassword(password: string): array of byte
{
	pw := strtobytes(password);
	padded := array[32] of byte;
	n := len pw;
	if(n > 32) n = 32;
	padded[0:] = pw[0:n];
	if(n < 32)
		padded[n:] = PDFPAD[0:32-n];
	return padded;
}

# Initialize encryption from /Encrypt dict and /ID in trailer.
# Returns nil on success, error string on failure.
initcrypt(doc: ref PdfDoc, password: string): string
{
	if(doc.trailer == nil)
		return nil;
	rawencobj := dictget(doc.trailer.dval, "Encrypt");
	if(rawencobj == nil)
		return nil;
	encobj := rawencobj;
	if(encobj.kind == Oref){
		doc.encobjnum = encobj.ival;
		encobj = resolvenocrypt(doc, encobj);
	}
	if(encobj == nil || encobj.kind != Odict)
		return "encrypted: cannot parse Encrypt dictionary";

	# Only standard password-based encryption is supported
	filter := dictgetname(encobj.dval, "Filter");
	if(filter != nil && filter != "Standard")
		return "encrypted: unsupported filter " + filter;

	v := dictgetint(encobj.dval, "V");
	r := dictgetint(encobj.dval, "R");
	p := dictgetint(encobj.dval, "P");

	keylen := dictgetint(encobj.dval, "Length");
	if(keylen == 0)
		keylen = 40;
	keylen /= 8;  # bits to bytes

	oobj := dictget(encobj.dval, "O");
	uobj := dictget(encobj.dval, "U");
	if(oobj == nil || uobj == nil || oobj.kind != Ostring || uobj.kind != Ostring)
		return "encrypted: missing O or U values";
	oval := strtobytes(oobj.sval);
	uval := strtobytes(uobj.sval);

	# Get file ID from trailer /ID array
	fileid: array of byte;
	idobj := dictget(doc.trailer.dval, "ID");
	if(idobj == nil && doc.trailer.kind == Ostream){
		# xref streams: ID might be in the stream dict
		idobj = dictget(doc.trailer.dval, "ID");
	}
	if(idobj != nil && idobj.kind == Oarray && idobj.aval != nil){
		id0 := hd idobj.aval;
		if(id0 != nil && id0.kind == Ostring)
			fileid = strtobytes(id0.sval);
	}
	if(fileid == nil)
		fileid = array[0] of byte;

	# Determine crypt filters
	stmf := "V2";  # default RC4
	strf := "V2";
	if(v == 4 || v == 5){
		cfobj := dictget(encobj.dval, "CF");
		if(cfobj != nil && cfobj.kind == Odict){
			stmfname := dictgetname(encobj.dval, "StmF");
			strfname := dictgetname(encobj.dval, "StrF");
			if(stmfname == nil || stmfname == "")
				stmfname = "StdCF";
			if(strfname == nil || strfname == "")
				strfname = "StdCF";
			cfentry := dictget(cfobj.dval, stmfname);
			if(cfentry != nil && cfentry.kind == Odict){
				cfm := dictgetname(cfentry.dval, "CFM");
				if(cfm == "AESV2")
					stmf = "AESV2";
				else if(cfm == "AESV3")
					stmf = "AESV3";
			}
			cfentry2 := dictget(cfobj.dval, strfname);
			if(cfentry2 != nil && cfentry2.kind == Odict){
				cfm2 := dictgetname(cfentry2.dval, "CFM");
				if(cfm2 == "AESV2")
					strf = "AESV2";
				else if(cfm2 == "AESV3")
					strf = "AESV3";
			}
		}
	}

	if(password == nil)
		password = "";

	# Get UE/OE for V=5 key unwrapping
	ueval: array of byte;
	oeval: array of byte;
	if(v == 5){
		ueobj := dictget(encobj.dval, "UE");
		oeobj := dictget(encobj.dval, "OE");
		if(ueobj != nil && ueobj.kind == Ostring)
			ueval = strtobytes(ueobj.sval);
		if(oeobj != nil && oeobj.kind == Ostring)
			oeval = strtobytes(oeobj.sval);
	}

	# Compute encryption key
	enckey: array of byte;
	case v {
	1 or 2 =>
		enckey = computekey(password, oval, p, fileid, keylen, r);
	4 =>
		enckey = computekey(password, oval, p, fileid, keylen, r);
	5 =>
		# AES-256 (R=5 or R=6): key from password + U/O validation/key salts
		enckey = computekey256(password, oval, uval, ueval, oeval, r);
	* =>
		return "encrypted: unsupported encryption version V=" + string v;
	}

	if(enckey == nil)
		return "encrypted: password required";

	# Validate user password
	ok := 0;
	case r {
	2 =>
		ok = validateuser2(enckey, uval);
	3 or 4 =>
		ok = validateuser34(enckey, uval, fileid);
	5 =>
		ok = validateuser5(enckey, password, uval);
	6 =>
		ok = validateuser5(enckey, password, uval);
	}
	if(!ok)
		return "encrypted: password required";

	doc.enckey = enckey;
	doc.encv = v;
	doc.encr = r;
	doc.enckeylen = keylen;
	doc.encstmf = stmf;
	doc.encstrf = strf;
	return nil;
}

# Get a /Name value as a string from a dict
dictgetname(entries: list of ref DictEntry, key: string): string
{
	obj := dictget(entries, key);
	if(obj == nil) return nil;
	if(obj.kind == Oname) return obj.sval;
	return nil;
}

# Resolve an object without decryption (for /Encrypt dict itself)
resolvenocrypt(doc: ref PdfDoc, obj: ref PdfObj): ref PdfObj
{
	if(obj == nil) return nil;
	if(obj.kind != Oref) return obj;

	objnum := obj.ival;
	if(objnum < 0 || objnum >= doc.nobjs) return nil;

	entry := doc.xref[objnum];
	if(entry == nil || entry.inuse == 0) return nil;

	# Handle objects stored in ObjStm (compressed object streams)
	if(entry.inuse == 2)
		return resolveobjstmnocrypt(doc, entry.offset, entry.gen);

	offset := entry.offset;
	if(offset >= len doc.data) return nil;

	pos := skipws(doc.data, offset);
	(nil, p1) := readint(doc.data, pos);
	pos = skipws(doc.data, p1);
	(nil, p2) := readint(doc.data, pos);
	pos = skipws(doc.data, p2);
	if(pos + 3 <= len doc.data && slicestr(doc.data, pos, 3) == "obj")
		pos += 3;
	pos = skipws(doc.data, pos);

	(parsed, nil, nil) := parseobj(doc.data, pos);
	return parsed;
}

# Resolve an object from an ObjStm without decryption.
# ObjStm streams are NOT individually encrypted in the PDF spec—
# only the container stream may be encrypted, but the /Encrypt dict
# itself should never require decryption to access.
resolveobjstmnocrypt(doc: ref PdfDoc, stmnum, idx: int): ref PdfObj
{
	if(stmnum < 0 || stmnum >= doc.nobjs) return nil;
	stmentry := doc.xref[stmnum];
	if(stmentry == nil || stmentry.inuse != 1) return nil;

	offset := stmentry.offset;
	if(offset >= len doc.data) return nil;

	pos := skipws(doc.data, offset);
	(nil, p1) := readint(doc.data, pos);
	pos = skipws(doc.data, p1);
	(nil, p2) := readint(doc.data, pos);
	pos = skipws(doc.data, p2);
	if(pos + 3 <= len doc.data && slicestr(doc.data, pos, 3) == "obj")
		pos += 3;
	pos = skipws(doc.data, pos);

	(stmobj, nil, nil) := parseobj(doc.data, pos);
	if(stmobj == nil || stmobj.kind != Ostream) return nil;

	n := dictgetint(stmobj.dval, "N");
	first := dictgetint(stmobj.dval, "First");
	if(n <= 0 || first <= 0 || idx >= n) return nil;

	(sdata, derr) := decompressstream(stmobj);
	if(sdata == nil || derr != nil) return nil;

	spos := 0;
	offsets := array[n] of int;
	for(i := 0; i < n; i++){
		spos = skipwsbytes(sdata, spos);
		(nil, sp1) := readint(sdata, spos);
		spos = skipwsbytes(sdata, sp1);
		(ooff, sp2) := readint(sdata, spos);
		spos = sp2;
		offsets[i] = first + ooff;
	}

	if(idx >= n) return nil;
	opos := offsets[idx];
	if(opos >= len sdata) return nil;

	(parsed, nil, nil) := parseobj(sdata, opos);
	return parsed;
}

# Compute encryption key for V=1,2,4 (R=2,3,4) — Algorithm 3.2
computekey(password: string, oval: array of byte, p: int, fileid: array of byte, keylen, r: int): array of byte
{
	padded := padpassword(password);

	# MD5(padded_password + O + P_le32 + fileID)
	digest := array[Keyring->MD5dlen] of byte;
	state := keyring->md5(padded, len padded, nil, nil);
	state = keyring->md5(oval, len oval, nil, state);

	# P as little-endian 32-bit
	pbuf := array[4] of byte;
	pbuf[0] = byte p;
	pbuf[1] = byte (p >> 8);
	pbuf[2] = byte (p >> 16);
	pbuf[3] = byte (p >> 24);
	state = keyring->md5(pbuf, 4, nil, state);

	state = keyring->md5(fileid, len fileid, nil, state);

	# For R>=4 and metadata not encrypted, hash 4 bytes of 16rFFFFFFFF
	# (we always decrypt metadata, so skip this)

	keyring->md5(nil, 0, digest, state);

	# For R>=3, iterate MD5 50 times on first keylen bytes
	if(r >= 3){
		for(i := 0; i < 50; i++){
			tmp := array[Keyring->MD5dlen] of byte;
			keyring->md5(digest[0:keylen], keylen, tmp, nil);
			digest = tmp;
		}
	}

	return digest[0:keylen];
}

# Compute encryption key for V=5 (R=5 or R=6) — ISO 32000-2
# The file encryption key is stored in UE/OE, encrypted with an
# intermediate key derived from SHA-256(password + key_salt).
computekey256(password: string, oval, uval, ueval, oeval: array of byte, r: int): array of byte
{
	pw := strtobytes(password);
	if(len pw > 127)
		pw = pw[0:127];

	# Try user password first
	# U = hash(32) + validation_salt(8) + key_salt(8) = 48 bytes
	if(len uval >= 48){
		uvsalt := uval[32:40];
		uksalt := uval[40:48];

		# Validate: SHA-256(password + validation_salt)
		uhash := array[Keyring->SHA256dlen] of byte;
		ustate := keyring->sha256(pw, len pw, nil, nil);
		keyring->sha256(uvsalt, 8, uhash, ustate);

		ok := 1;
		for(i := 0; i < 32; i++){
			if(uhash[i] != uval[i]){
				ok = 0;
				break;
			}
		}

		if(ok){
			# Intermediate key: SHA-256(password + key_salt)
			ikey := array[Keyring->SHA256dlen] of byte;
			kstate := keyring->sha256(pw, len pw, nil, nil);
			keyring->sha256(uksalt, 8, ikey, kstate);

			# Decrypt UE with intermediate key (AES-256-CBC, zero IV)
			if(ueval != nil && len ueval >= 32){
				zeroiv := array[16] of {* => byte 0};
				fek := array[32] of byte;
				fek[0:] = ueval[0:32];
				aes := keyring->aessetup(ikey, zeroiv);
				if(aes != nil){
					keyring->aescbc(aes, fek, 32, Keyring->Decrypt);
					return fek;
				}
			}
			# Fallback: use intermediate key directly if no UE
			return ikey;
		}
	}

	# Try owner password
	if(len oval >= 48){
		ovsalt := oval[32:40];
		oksalt := oval[40:48];

		ohash := array[Keyring->SHA256dlen] of byte;
		ostate := keyring->sha256(pw, len pw, nil, nil);
		ostate = keyring->sha256(ovsalt, 8, nil, ostate);
		keyring->sha256(uval[0:48], 48, ohash, ostate);

		ok := 1;
		for(j := 0; j < 32; j++){
			if(ohash[j] != oval[j]){
				ok = 0;
				break;
			}
		}
		if(ok){
			ikey := array[Keyring->SHA256dlen] of byte;
			okstate := keyring->sha256(pw, len pw, nil, nil);
			okstate = keyring->sha256(oksalt, 8, nil, okstate);
			keyring->sha256(uval[0:48], 48, ikey, okstate);

			# Decrypt OE with intermediate key (AES-256-CBC, zero IV)
			if(oeval != nil && len oeval >= 32){
				zeroiv := array[16] of {* => byte 0};
				fek := array[32] of byte;
				fek[0:] = oeval[0:32];
				aes := keyring->aessetup(ikey, zeroiv);
				if(aes != nil){
					keyring->aescbc(aes, fek, 32, Keyring->Decrypt);
					return fek;
				}
			}
			return ikey;
		}
	}

	return nil;
}

# Validate user password for R=2 — Algorithm 3.4
validateuser2(enckey, uval: array of byte): int
{
	# RC4-encrypt the 32-byte padding with the file encryption key
	test := array[32] of byte;
	test[0:] = PDFPAD;
	rc4state := keyring->rc4setup(enckey);
	keyring->rc4(rc4state, test, 32);

	n := len uval;
	if(n > 32) n = 32;
	for(i := 0; i < n; i++){
		if(test[i] != uval[i])
			return 0;
	}
	return 1;
}

# Validate user password for R=3,4 — Algorithm 3.5
validateuser34(enckey, uval, fileid: array of byte): int
{
	# MD5(padding + fileID)
	digest := array[Keyring->MD5dlen] of byte;
	state := keyring->md5(PDFPAD, 32, nil, nil);
	keyring->md5(fileid, len fileid, digest, state);

	# RC4-encrypt with enckey
	rc4state := keyring->rc4setup(enckey);
	keyring->rc4(rc4state, digest, Keyring->MD5dlen);

	# 19 rounds: XOR each byte of key with round number, RC4-encrypt
	for(round := 1; round <= 19; round++){
		xkey := array[len enckey] of byte;
		for(j := 0; j < len enckey; j++)
			xkey[j] = enckey[j] ^ byte round;
		rs := keyring->rc4setup(xkey);
		keyring->rc4(rs, digest, Keyring->MD5dlen);
	}

	# Compare first 16 bytes
	for(i := 0; i < Keyring->MD5dlen; i++){
		if(digest[i] != uval[i])
			return 0;
	}
	return 1;
}

# Validate user password for R=5,6 — ISO 32000-2
validateuser5(enckey: array of byte, password: string, uval: array of byte): int
{
	# Already validated during key computation in computekey256
	# If we have an enckey, the password was valid
	return enckey != nil;
}

# Decrypt an object's string and stream values
decryptobj(doc: ref PdfDoc, obj: ref PdfObj, objnum, gen: int): ref PdfObj
{
	if(obj == nil) return obj;
	case obj.kind {
	Ostring =>
		raw := strtobytes(obj.sval);
		dec := decryptbytes(doc, raw, objnum, gen, doc.encstrf);
		obj.sval = bytestostr(dec);
	Ostream =>
		if(obj.stream != nil)
			obj.stream = decryptbytes(doc, obj.stream, objnum, gen, doc.encstmf);
	Odict =>
		# Decrypt string values within dicts (but not /Type, /Subtype etc — those are names not strings)
		for(el := obj.dval; el != nil; el = tl el){
			e := hd el;
			if(e.val != nil && e.val.kind == Ostring){
				raw := strtobytes(e.val.sval);
				dec := decryptbytes(doc, raw, objnum, gen, doc.encstrf);
				e.val.sval = bytestostr(dec);
			}
		}
	Oarray =>
		# Decrypt string values within arrays
		for(al := obj.aval; al != nil; al = tl al){
			item := hd al;
			if(item != nil && item.kind == Ostring){
				raw := strtobytes(item.sval);
				dec := decryptbytes(doc, raw, objnum, gen, doc.encstrf);
				item.sval = bytestostr(dec);
			}
		}
	}
	return obj;
}

# Decrypt raw bytes for a given object number and generation
decryptbytes(doc: ref PdfDoc, data: array of byte, objnum, gen: int, filter: string): array of byte
{
	if(len data == 0) return data;

	if(filter == "AESV3"){
		# AES-256: use enckey directly, first 16 bytes of data are IV
		return aesdecrypt(doc.enckey, data);
	}

	# Compute per-object key: MD5(enckey + objnum_le3 + gen_le2 [+ "sAlT" for AES])
	extra := 5;
	if(filter == "AESV2")
		extra = 9;  # 5 + 4 bytes "sAlT"
	keybuf := array[len doc.enckey + extra] of byte;
	keybuf[0:] = doc.enckey;
	off := len doc.enckey;
	keybuf[off] = byte objnum;
	keybuf[off+1] = byte (objnum >> 8);
	keybuf[off+2] = byte (objnum >> 16);
	keybuf[off+3] = byte gen;
	keybuf[off+4] = byte (gen >> 8);
	if(filter == "AESV2"){
		keybuf[off+5] = byte 16r73;  # 's'
		keybuf[off+6] = byte 16r41;  # 'A'
		keybuf[off+7] = byte 16r6C;  # 'l'
		keybuf[off+8] = byte 16r54;  # 'T'
	}

	digest := array[Keyring->MD5dlen] of byte;
	keyring->md5(keybuf, len keybuf, digest, nil);

	# Key length is min(enckey_len + 5, 16)
	objkeylen := len doc.enckey + 5;
	if(objkeylen > 16)
		objkeylen = 16;
	objkey := digest[0:objkeylen];

	if(filter == "AESV2")
		return aesdecrypt(objkey, data);

	# RC4 decrypt in-place
	out := array[len data] of byte;
	out[0:] = data;
	rc4state := keyring->rc4setup(objkey);
	keyring->rc4(rc4state, out, len out);
	return out;
}

# AES-CBC decrypt: first 16 bytes = IV, rest = ciphertext, strip PKCS#7
aesdecrypt(key, data: array of byte): array of byte
{
	if(len data < 32) return data;  # need at least IV + one block
	if(len data % 16 != 0) return data;  # must be block-aligned

	iv := data[0:16];
	ct := array[len data - 16] of byte;
	ct[0:] = data[16:];

	aesstate := keyring->aessetup(key, iv);
	if(aesstate == nil) return data;
	keyring->aescbc(aesstate, ct, len ct, Keyring->Decrypt);

	# Strip PKCS#7 padding
	if(len ct == 0) return ct;
	padlen := int ct[len ct - 1];
	if(padlen < 1 || padlen > 16) return ct;

	# Validate padding bytes
	for(i := len ct - padlen; i < len ct; i++){
		if(int ct[i] != padlen)
			return ct;  # invalid padding, return as-is
	}
	return ct[0:len ct - padlen];
}
