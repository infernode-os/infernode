implement Troffpage;

#
# troffpage - troff's output read, its pages painted (troffpage(2)).
#
# A document is indexed once: where each page begins, and what is
# mounted and selected when it does, so any page can be painted
# without reading those before it.  A page is read again each time it
# is painted; reading is cheap beside drawing.
#
# A glyph is found by its name in the font description of its font
# position (troff(6)): the description gives the glyph's name in the
# font program, found with namedgid, or its Unicode value, found
# through the cmap.  Font descriptions and font programs are read once
# and kept for every document.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "outlinefont.m";
	outlinefont: OutlineFont;
	Face: import outlinefont;

include "troffpage.m";

NFONTS:	con 32;
NOGID:	con -2;		# not looked up yet

display: ref Display;

# a font description, as much of it as a page needs
Fdesc: adt {
	path:	string;
	fontpath:	string;
	face:	ref Face;
	facetried:	int;
	names:	array of string;	# characters, by index
	ids:	array of string;	# their glyphs' names in the font
	codes:	array of int;		# their Unicode values, or -1
	wids:	array of int;		# their widths, at unitwidth
	gids:	array of int;		# glyphs in face, once found
	n:	int;
	map:	array of list of (string, int);	# names to indices
	spacewid:	int;
	uwid:	int;		# the device's unitwidth
};

# what a page begins with
Start: adt {
	off:	int;		# where it is in the data
	mounts:	array of string;	# the font names at each position
	f, s, m:	int;
};

State: adt {
	data:	array of byte;
	fontdir:	string;
	uwid:	int;
	pages:	array of ref Start;
	links:	array of array of Link;
	names:	list of (string, int);	# named destinations: name, page
};

docs: array of ref State;
fdescs: list of ref Fdesc;
colours: list of (int, ref Image);

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	display = d;
	outlinefont = load OutlineFont OutlineFont->PATH;
	if(outlinefont == nil)
		return sys->sprint("cannot load %s: %r", OutlineFont->PATH);
	outlinefont->init(d);
	return nil;
}

istroff(data: array of byte): int
{
	return len data >= 4 && int data[0] == 'x' && int data[1] == ' ' && int data[2] == 'T' && int data[3] == ' ';
}

#
# reading the output
#

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

# a signed number at i; and where it stops
num(b: array of byte, i: int): (int, int)
{
	while(i < len b && (int b[i] == ' ' || int b[i] == '\t'))
		i++;
	neg := 0;
	if(i < len b && (int b[i] == '-' || int b[i] == '+')){
		neg = int b[i] == '-';
		i++;
	}
	n := 0;
	while(i < len b && isdigit(int b[i]))
		n = n * 10 + int b[i++] - '0';
	if(neg)
		n = -n;
	return (n, i);
}

# the end of the line at i, before its newline
eol(b: array of byte, i: int): int
{
	while(i < len b && int b[i] != '\n')
		i++;
	return i;
}

# the next word of b[i:e]; and where it stops
word(b: array of byte, i, e: int): (string, int)
{
	while(i < e && (int b[i] == ' ' || int b[i] == '\t'))
		i++;
	s := i;
	while(i < e && !isspace(int b[i]))
		i++;
	return (string b[s:i], i);
}

# an argument as neatpost reads one: "quoted" (with "" for ") or a word
qword(b: array of byte, i, e: int): (string, int)
{
	while(i < e && (int b[i] == ' ' || int b[i] == '\t'))
		i++;
	if(i < e && int b[i] == '"'){
		i++;
		s := "";
		while(i < e){
			if(int b[i] == '"'){
				if(i + 1 < e && int b[i + 1] == '"'){
					s[len s] = '"';
					i += 2;
					continue;
				}
				i++;
				break;
			}
			# a UTF-8 sequence, whole
			j := i + 1;
			while(j < e && (int b[j] & 16rC0) == 16r80)
				j++;
			s += string b[i:j];
			i = j;
		}
		return (s, i);
	}
	return word(b, i, e);
}

open(data: array of byte, fontdir: string): (ref Doc, string)
{
	if(!istroff(data))
		return (nil, "not troff output");
	st := ref State(data, fontdir, 10, nil, nil, nil);
	d := ref Doc("utf", 720, 612, 792, 0, 0);
	mounts := array[NFONTS] of string;
	f := 1;
	s := 10;
	m := 0;
	pl := -1;
	pw := -1;
	ph := -1;
	starts: list of ref Start;
	npages := 0;
	b := data;
	for(i := 0; i < len b; ){
		c := int b[i];
		e := eol(b, i);
		case c {
		'x' =>
			(w, j) := word(b, i + 1, e);
			case w {
			"T" =>
				(d.dev, nil) = word(b, j, e);
			"res" =>
				(d.res, nil) = num(b, j);
			"font" =>
				(pos, k) := num(b, j);
				(name, nil) := word(b, k, e);
				if(pos >= 0 && pos < NFONTS)
					mounts[pos] = name;
			"X" =>
				(cmd, k) := word(b, j, e);
				case cmd {
				"papersize" =>
					(pw, k) = num(b, k);
					if(k < e && int b[k] == 'x')
						k++;
					(ph, nil) = num(b, k);
				"name" =>
					(nm, k2) := qword(b, k, e);
					(pg, nil) := num(b, k2);
					st.names = (nm, pg - 1) :: st.names;
				}
			}
		'p' =>
			pm := array[NFONTS] of string;
			pm[0:] = mounts;
			starts = ref Start(i, pm, f, s, m) :: starts;
			npages++;
		's' =>
			(s, nil) = num(b, i + 1);
		'f' =>
			(f, nil) = num(b, i + 1);
		'm' =>
			m = colour(string b[i+1:e]);
		'V' =>
			(pl, nil) = num(b, i + 1);	# the last is the page length
		}
		i = e + 1;
	}
	d.npages = npages;
	st.pages = array[npages] of ref Start;
	for(k := npages - 1; k >= 0; k--){
		st.pages[k] = hd starts;
		starts = tl starts;
	}
	st.links = array[npages] of array of Link;
	if(st.fontdir == nil)
		st.fontdir = "/lib/troff/dev" + d.dev;
	st.uwid = devuwid(st.fontdir);
	if(pw > 0 && ph > 0){
		d.width = pw;
		d.height = ph;
	}else if(pl > 0){
		d.height = (pl * 72 + d.res / 2) / d.res;
		if(d.height >= 835 && d.height <= 850)	# A4: 297mm
			d.width = 595;
		else
			d.width = 612;
	}
	d.x = add(st);
	return (d, nil);
}

# the device's unitwidth
devuwid(dir: string): int
{
	fd := sys->open(dir + "/DESC", Sys->OREAD);
	if(fd == nil)
		return 10;
	b := array[4096] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return 10;
	s := string b[0:n];
	for(i := 0; i + 9 < len s; i++)
		if(s[i:i+9] == "unitwidth"){
			(u, nil) := num(b, i + 9);
			if(u > 0)
				return u;
		}
	return 10;
}

colour(s: string): int
{
	while(s != nil && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	if(len s == 7 && s[0] == '#'){
		v := 0;
		for(i := 1; i < 7; i++){
			c := s[i];
			d := 0;
			if(c >= '0' && c <= '9')
				d = c - '0';
			else if(c >= 'a' && c <= 'f')
				d = c - 'a' + 10;
			else if(c >= 'A' && c <= 'F')
				d = c - 'A' + 10;
			v = v * 16 + d;
		}
		return v;
	}
	return 0;
}

colourimage(rgb: int): ref Image
{
	for(l := colours; l != nil; l = tl l){
		(c, im) := hd l;
		if(c == rgb)
			return im;
	}
	im := display.color((rgb << 8) | 16rFF);
	colours = (rgb, im) :: colours;
	return im;
}

Doc.close(d: self ref Doc)
{
	if(d.x >= 0 && d.x < len docs)
		docs[d.x] = nil;
}

add(s: ref State): int
{
	for(i := 0; i < len docs; i++)
		if(docs[i] == nil){
			docs[i] = s;
			return i;
		}
	n := array[len docs + 4] of ref State;
	n[0:] = docs;
	n[len docs] = s;
	h := len docs;
	docs = n;
	return h;
}

#
# font descriptions
#

hash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h * 31 + s[i];
	return h & 16r7fffffff;
}

fdesc(dir, name: string, uwid: int): ref Fdesc
{
	path := name;
	if(name == nil)
		return nil;
	if(strchr(name, '/') < 0)
		path = dir + "/" + name;
	for(l := fdescs; l != nil; l = tl l)
		if((hd l).path == path)
			return hd l;
	fd := readdesc(path, uwid);
	fdescs = fd :: fdescs;
	return fd;
}

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, dir) := sys->fstat(fd);
	if(ok != 0)
		return nil;
	n := int dir.length;
	b := array[n] of byte;
	for(t := 0; t < n; ){
		m := sys->read(fd, b[t:], n - t);
		if(m <= 0)
			return b[0:t];
		t += m;
	}
	return b;
}

# read the characters of a font description; its rules are not needed
readdesc(path: string, uwid: int): ref Fdesc
{
	f := ref Fdesc(path, nil, nil, 0, nil, nil, nil, nil, nil, 0,
		array[1024] of list of (string, int), 0, uwid);
	b := readfile(path);
	if(b == nil)
		return f;
	sz := 1024;
	f.names = array[sz] of string;
	f.ids = array[sz] of string;
	f.codes = array[sz] of int;
	f.wids = array[sz] of int;
	last := -1;
	for(i := 0; i < len b; ){
		e := eol(b, i);
		(w, j) := word(b, i, e);
		case w {
		"fontpath" =>
			(f.fontpath, nil) = word(b, j, e);
		"spacewidth" =>
			(f.spacewid, nil) = num(b, j);
		"char" =>
			name, wid, id: string;
			(name, j) = word(b, j, e);
			(wid, j) = word(b, j, e);
			if(wid == "\""){
				if(last >= 0)
					addname(f, name, last);
			}else{
				typ: string;
				(typ, j) = word(b, j, e);
				(id, j) = word(b, j, e);
				(code, k) := word(b, j, e);
				k = k;
				if(f.n == sz){
					sz *= 2;
					f.names = grows(f.names, sz);
					f.ids = grows(f.ids, sz);
					f.codes = growi(f.codes, sz);
					f.wids = growi(f.wids, sz);
				}
				if(name == "---")
					name = sys->sprint("c%.4d", f.n);
				f.names[f.n] = name;
				f.ids[f.n] = id;
				f.codes[f.n] = -1;
				if(code != nil && isdigit(code[0]))
					f.codes[f.n] = int code;
				(f.wids[f.n], nil) = num(array of byte wid, 0);
				addname(f, name, f.n);
				last = f.n++;
			}
		"gsec" or "ggrp" or "kern" =>
			i = len b;	# the rules: nothing more to read
			continue;
		}
		i = e + 1;
	}
	f.gids = array[f.n] of {* => NOGID};
	return f;
}

addname(f: ref Fdesc, name: string, i: int)
{
	h := hash(name) % len f.map;
	f.map[h] = (name, i) :: f.map[h];
}

# the character's index in f, or -1
fchar(f: ref Fdesc, name: string): int
{
	for(l := f.map[hash(name) % len f.map]; l != nil; l = tl l){
		(n, i) := hd l;
		if(n == name)
			return i;
	}
	return -1;
}

grows(a: array of string, n: int): array of string
{
	b := array[n] of string;
	b[0:] = a;
	return b;
}

growi(a: array of int, n: int): array of int
{
	b := array[n] of int;
	b[0:] = a;
	return b;
}

# the font program, read the first time a glyph is drawn
face(f: ref Fdesc): ref Face
{
	if(f.facetried)
		return f.face;
	f.facetried = 1;
	if(f.fontpath == nil)
		return nil;
	data := readfile(f.fontpath);
	if(data == nil)
		return nil;
	fmt := "ttf";
	if(len data > 4 && int data[0] == 1 && int data[1] == 0 && int data[2] == 4)
		fmt = "cff";	# a bare CFF font
	else if(len data > 2 && (int data[0] == '%' || int data[0] == 16r80))
		fmt = "t1";
	(fc, nil) := outlinefont->open(data, fmt);
	f.face = fc;
	return fc;
}

# the glyph of character i of f in its font program, or -1
gid(f: ref Fdesc, i: int): int
{
	if(f.gids[i] != NOGID)
		return f.gids[i];
	g := -1;
	fc := face(f);
	if(fc != nil){
		id := f.ids[i];
		if(len id > 4 && id[0:4] == "gid=")
			g = int id[4:];
		else{
			g = fc.namedgid(id);
			if(g < 0 && f.codes[i] >= 0)
				g = fc.lookup(f.codes[i]);
			if(g < 0 && len f.names[i] == 1)
				g = fc.lookup(f.names[i][0]);
		}
	}
	f.gids[i] = g;
	return g;
}

#
# reading a page
#

# what a walk over a page does
Wpaint, Wtext, Wlinks: con iota;

Walk: adt {
	what:	int;
	st:	ref State;
	d:	ref Doc;
	k:	real;		# pixels to a unit
	dst:	ref Image;
	ox, oy:	real;		# where the page's origin is on dst
	clip:	Rect;
	# text
	words:	list of Word;
	cur:	string;
	cr:	Rect;
	lasth, lastv:	int;	# where the last glyph ended
	lastsz:	int;
	text:	string;
	links:	list of Link;
};

# the text of character i of f
chartext(f: ref Fdesc, name: string, i: int): string
{
	if(len name == 1)
		return name;
	if(i >= 0 && f.codes[i] > 0){
		s := "";
		s[0] = f.codes[i];
		return s;
	}
	case name {
	"hy" or "-" or "\\-" or "mi" =>
		return "-";
	"em" =>
		return "—";
	"en" =>
		return "–";
	"fi" =>	return "fi";
	"fl" =>	return "fl";
	"ff" =>	return "ff";
	"ffi" =>	return "ffi";
	"ffl" =>	return "ffl";
	"lq" =>	return "“";
	"rq" =>	return "”";
	"oq" =>	return "‘";
	"cq" =>	return "’";
	"bu" =>	return "•";
	"dg" =>	return "†";
	"dd" =>	return "‡";
	"pl" =>	return "+";
	"eq" =>	return "=";
	"sl" =>	return "/";
	"dq" =>	return "\"";
	}
	if(len name > 3 && name[0:3] == "uni")
		return "";
	return name;
}

flushword(w: ref Walk)
{
	if(w.cur != nil)
		w.words = Word(w.cur, w.cr) :: w.words;
	w.cur = nil;
}

# a glyph, character name c, at (h, v) in font fpos and size sz
glyph(w: ref Walk, mounts: array of string, fpos, sz: int, c: string, h, v: int, colour: int): int
{
	if(fpos < 0 || fpos >= NFONTS)
		return 0;
	f := fdesc(w.st.fontdir, mounts[fpos], w.st.uwid);
	if(f == nil)
		return 0;
	i := fchar(f, c);
	adv := 0;
	if(i >= 0)
		adv = (f.wids[i] * sz + f.uwid / 2) / f.uwid;
	case w.what {
	Wpaint =>
		if(i < 0)
			return adv;
		g := gid(f, i);
		fc := f.face;
		if(g < 0 || fc == nil)
			return adv;
		px := real sz * real w.d.res / 72.0 * w.k;	# the size in pixels
		x := w.ox + real h * w.k;
		y := w.oy + real v * w.k;
		# a glyph wholly outside the clip is not drawn
		if(x > real w.clip.max.x + px || x < real w.clip.min.x - 2.0 * px ||
				y > real w.clip.max.y + px || y < real w.clip.min.y - px)
			return adv;
		k := px / real fc.upem;
		fc.drawglyphm(g, array[] of {k, 0.0, 0.0, -k}, w.dst, x, y, colourimage(colour));
	Wtext =>
		t := chartext(f, c, i);
		em := sz * w.d.res / 72;
		if(v != w.lastv || h > w.lasth + em / 5 || h < w.lasth - em){
			flushword(w);
			if(w.text != nil){
				if(v != w.lastv)
					w.text += "\n";
				else
					w.text += " ";
			}
		}
		if(t == nil)
			t = "";
		top := v - em * 3 / 4;
		bot := v + em / 4;
		r := Rect((pt(w, h), pt(w, top)), (pt(w, h + adv), pt(w, bot)));
		if(w.cur == nil)
			w.cr = r;
		else
			w.cr = w.cr.combine(r);
		w.cur += t;
		w.text += t;
		w.lasth = h + adv;
		w.lastv = v;
		w.lastsz = sz;
	}
	return adv;
}

# a position in points
pt(w: ref Walk, u: int): int
{
	return (u * 72 + w.d.res / 2) / w.d.res;
}

# walk page n
walk(w: ref Walk, n: int)
{
	st := w.st;
	ps := st.pages[n];
	mounts := array[NFONTS] of string;
	mounts[0:] = ps.mounts;
	f := ps.f;
	s := ps.s;
	m := ps.m;
	h := 0;
	v := 0;
	b := st.data;
	i := ps.off;
	first := 1;
	while(i < len b){
		c := int b[i++];
		case c {
		' ' or '\t' or '\n' or '\r' =>
			;
		'p' =>
			(nil, i) = num(b, i);
			if(!first)
				return;
			first = 0;
		's' =>
			(s, i) = num(b, i);
		'f' =>
			(f, i) = num(b, i);
		'H' =>
			(h, i) = num(b, i);
		'V' =>
			(v, i) = num(b, i);
		'h' =>
			d: int;
			(d, i) = num(b, i);
			h += d;
		'v' =>
			d: int;
			(d, i) = num(b, i);
			v += d;
		'c' =>
			# one character, of however many bytes
			j := i + 1;
			while(j < len b && (int b[j] & 16rC0) == 16r80)
				j++;
			glyph(w, mounts, f, s, string b[i:j], h, v, m);
			i = j;
		'C' =>
			j := i;
			while(j < len b && !isspace(int b[j]))
				j++;
			glyph(w, mounts, f, s, string b[i:j], h, v, m);
			i = j;
		'N' =>
			# a glyph by its number; not drawn
			(nil, i) = num(b, i);
		'w' =>
			;
		'n' =>
			(nil, i) = num(b, i);
			(nil, i) = num(b, i);
		'm' =>
			e := eol(b, i);
			m = colour(string b[i:e]);
			i = e;
		'x' =>
			e := eol(b, i);
			devctl(w, mounts, b, i, e, h, v, n);
			i = e;
		'D' =>
			e := eol(b, i);
			(h, v) = drawing(w, b, i, e, h, v, s, m);
			i = e;
		'#' =>
			i = eol(b, i);
		* =>
			if(isdigit(c)){
				# two digits of motion, then a character (old troff)
				if(i < len b && isdigit(int b[i])){
					h += (c - '0') * 10 + int b[i] - '0';
					i++;
					j := i + 1;
					while(j < len b && (int b[j] & 16rC0) == 16r80)
						j++;
					glyph(w, mounts, f, s, string b[i:j], h, v, m);
					i = j;
				}
			}else
				i = eol(b, i);
		}
	}
}

devctl(w: ref Walk, mounts: array of string, b: array of byte, i, e: int, h, v, n: int)
{
	(cmd, j) := word(b, i, e);
	case cmd {
	"font" =>
		(pos, k) := num(b, j);
		(name, nil) := word(b, k, e);
		if(pos >= 0 && pos < NFONTS)
			mounts[pos] = name;
	"X" =>
		if(w.what != Wlinks)
			return;
		(x, k) := word(b, j, e);
		if(x != "link")
			return;
		(url, k2) := qword(b, k, e);
		(hw, k3) := num(b, k2);
		(vw, nil) := num(b, k3);
		r := Rect((pt(w, h), pt(w, v)), (pt(w, h + hw), pt(w, v + vw))).canon();
		if(url != nil && url[0] == '#'){
			pg := -1;
			for(l := w.st.names; l != nil; l = tl l){
				(nm, p) := hd l;
				if(nm == url[1:])
					pg = p;
			}
			if(pg < 0)
				return;
			url = sys->sprint("#page=%d", pg + 1);
		}
		w.links = Link(n, r, url) :: w.links;
	}
}

# a drawing command; returns where it leaves the current point
drawing(w: ref Walk, b: array of byte, i, e: int, h, v: int, sz: int, colour: int): (int, int)
{
	if(i >= e)
		return (h, v);
	c := int b[i++];
	nums: list of int;
	nn := 0;
	while(i < e){
		while(i < e && (int b[i] == ' ' || int b[i] == '\t'))
			i++;
		if(i >= e)
			break;
		if(!isdigit(int b[i]) && int b[i] != '-' && int b[i] != '+'){
			# a non-numeric argument (a drawing option): skip
			while(i < e && !isspace(int b[i]))
				i++;
			continue;
		}
		x: int;
		(x, i) = num(b, i);
		nums = x :: nums;
		nn++;
	}
	a := array[nn] of int;
	for(k := nn - 1; k >= 0; k--){
		a[k] = hd nums;
		nums = tl nums;
	}
	nh := h;
	nv := v;
	case c {
	'l' or 'L' =>
		if(nn >= 2){
			nh = h + a[0];
			nv = v + a[1];
		}
	'c' or 'C' =>
		if(nn >= 1)
			nh = h + a[0];
	'e' or 'E' =>
		if(nn >= 1)
			nh = h + a[0];
	'a' or 'A' =>
		if(nn >= 4){
			nh = h + a[0] + a[2];
			nv = v + a[1] + a[3];
		}
	'~' or 'p' or 'P' =>
		for(k = 0; k + 1 < nn; k += 2){
			nh += a[k];
			nv += a[k + 1];
		}
	}
	if(w.what != Wpaint)
		return (nh, nv);
	src := colourimage(colour);
	px := real sz * real w.d.res / 72.0 * w.k;
	thick := int (px / 20.0);	# a twentieth of an em, as dpost draws
	if(thick < 0)
		thick = 0;
	r := (thick + 1) / 2;
	case c {
	'l' or 'L' =>
		if(nn >= 2)
			w.dst.line(dpt(w, h, v), dpt(w, nh, nv), Draw->Endsquare, Draw->Endsquare, r, src, (0, 0));
	'c' or 'C' =>
		if(nn >= 1){
			rad := int (real a[0] * w.k / 2.0);
			ctr := dpt(w, h + a[0] / 2, v);
			if(c == 'C')
				w.dst.fillellipse(ctr, rad, rad, src, (0, 0));
			else
				w.dst.ellipse(ctr, rad, rad, r, src, (0, 0));
		}
	'e' or 'E' =>
		if(nn >= 2){
			ra := int (real a[0] * w.k / 2.0);
			rb := int (real a[1] * w.k / 2.0);
			ctr := dpt(w, h + a[0] / 2, v);
			if(c == 'E')
				w.dst.fillellipse(ctr, ra, rb, src, (0, 0));
			else
				w.dst.ellipse(ctr, ra, rb, r, src, (0, 0));
		}
	'a' or 'A' =>
		if(nn >= 4){
			# from the current point, about the centre (h+a[0], v+a[1]), to the end
			cx := h + a[0];
			cy := v + a[1];
			ex := nh;
			ey := nv;
			rad := isqrt(a[0] * a[0] + a[1] * a[1]);
			a0 := angle(h - cx, cy - v);
			a1 := angle(ex - cx, cy - ey);
			span := a1 - a0;
			if(span <= 0)
				span += 360;
			rp := int (real rad * w.k);
			w.dst.arc(dpt(w, cx, cy), rp, rp, r, src, (0, 0), a0, span);
		}
	'~' or 'p' or 'P' =>
		pts := array[nn / 2 + 1] of Point;
		pts[0] = dpt(w, h, v);
		x := h;
		y := v;
		for(k = 0; k + 1 < nn; k += 2){
			x += a[k];
			y += a[k + 1];
			pts[k / 2 + 1] = dpt(w, x, y);
		}
		case c {
		'~' =>
			w.dst.bezspline(pts, Draw->Endsquare, Draw->Endsquare, r, src, (0, 0));
		'P' =>
			w.dst.fillpoly(pts, ~0, src, (0, 0));
		* =>
			p := array[len pts + 1] of Point;
			p[0:] = pts;
			p[len pts] = pts[0];
			w.dst.poly(p, Draw->Endsquare, Draw->Endsquare, r, src, (0, 0));
		}
	}
	return (nh, nv);
}

dpt(w: ref Walk, h, v: int): Point
{
	return (int (w.ox + real h * w.k), int (w.oy + real v * w.k));
}

isqrt(n: int): int
{
	if(n <= 0)
		return 0;
	x := n;
	y := (x + 1) / 2;
	while(y < x){
		x = y;
		y = (x + n / x) / 2;
	}
	return x;
}

# the angle of (x, y), y up, in degrees from 0 to 359
angle(x, y: int): int
{
	if(x == 0 && y == 0)
		return 0;
	# an octant, then a linear step within it: enough for a drawn arc
	ax := x;
	if(ax < 0)
		ax = -ax;
	ay := y;
	if(ay < 0)
		ay = -ay;
	a: int;
	if(ax >= ay)
		a = 45 * ay / ax;
	else
		a = 90 - 45 * ax / ay;
	if(x < 0 && y >= 0)
		a = 180 - a;
	else if(x < 0 && y < 0)
		a = 180 + a;
	else if(x >= 0 && y < 0)
		a = 360 - a;
	return a % 360;
}

getstate(d: ref Doc): ref State
{
	if(d.x < 0 || d.x >= len docs)
		return nil;
	return docs[d.x];
}

Doc.paint(d: self ref Doc, n: int, scale: real, dst: ref Image, r: Rect, org: Point): string
{
	st := getstate(d);
	if(st == nil || n < 0 || n >= d.npages)
		return "no such page";
	k := scale * 72.0 / real d.res;
	w := ref Walk(Wpaint, st, d, k, dst, real (r.min.x - org.x), real (r.min.y - org.y), r,
		nil, nil, ((0, 0), (0, 0)), 0, 0, 0, nil, nil);
	oclip := dst.clipr;
	dst.clipr = r.clip(oclip).t0;
	{
		dst.draw(r, display.white, nil, (0, 0));
		walk(w, n);
	} exception e {
	"*" =>
		dst.clipr = oclip;
		return "troff page: " + e;
	}
	dst.clipr = oclip;
	return nil;
}

Doc.text(d: self ref Doc, n: int): string
{
	st := getstate(d);
	if(st == nil || n < 0 || n >= d.npages)
		return nil;
	w := ref Walk(Wtext, st, d, 0.0, nil, 0.0, 0.0, ((0, 0), (0, 0)),
		nil, nil, ((0, 0), (0, 0)), -1, -1, 0, nil, nil);
	walk(w, n);
	return w.text;
}

Doc.words(d: self ref Doc, n: int): array of Word
{
	st := getstate(d);
	if(st == nil || n < 0 || n >= d.npages)
		return nil;
	w := ref Walk(Wtext, st, d, 0.0, nil, 0.0, 0.0, ((0, 0), (0, 0)),
		nil, nil, ((0, 0), (0, 0)), -1, -1, 0, nil, nil);
	walk(w, n);
	flushword(w);
	k := 0;
	for(l := w.words; l != nil; l = tl l)
		k++;
	a := array[k] of Word;
	for(l = w.words; l != nil; l = tl l)
		a[--k] = hd l;
	return a;
}

Doc.links(d: self ref Doc, n: int): array of Link
{
	st := getstate(d);
	if(st == nil || n < 0 || n >= d.npages)
		return nil;
	if(st.links[n] == nil){
		w := ref Walk(Wlinks, st, d, 0.0, nil, 0.0, 0.0, ((0, 0), (0, 0)),
			nil, nil, ((0, 0), (0, 0)), -1, -1, 0, nil, nil);
		walk(w, n);
		k := 0;
		for(l := w.links; l != nil; l = tl l)
			k++;
		a := array[k] of Link;
		for(l = w.links; l != nil; l = tl l)
			a[--k] = hd l;
		st.links[n] = a;
	}
	return st.links[n];
}
