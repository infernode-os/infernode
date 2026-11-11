implement Visrec;

#
# Records and pictures for vision(1)'s commands. See module/visrec.m.
#

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "filter.m";
	deflate: Filter;
include "visrec.m";

init(): string
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load String: %r");
	return nil;
}

# ---- records ----

parse(line: string): ref Rec
{
	r := ref Rec;
	for(ws := str->unquoted(line); ws != nil; ws = tl ws){
		(k, v) := str->splitl(hd ws, "=");
		if(v != nil)
			v = v[1:];
		r.kv = (k, v) :: r.kv;
	}
	kv: list of (string, string);
	for(l := r.kv; l != nil; l = tl l)
		kv = hd l :: kv;
	r.kv = kv;
	return r;
}

format(kv: list of (string, string)): string
{
	s := "";
	for(; kv != nil; kv = tl kv){
		(k, v) := hd kv;
		f := k + "=" + v;
		if(needsquote(v))
			f = str->quoted(f :: nil);
		if(s != nil)
			s += " ";
		s += f;
	}
	return s;
}

needsquote(v: string): int
{
	for(i := 0; i < len v; i++)
		case v[i] {
		' ' or '\t' or '\'' or '\n' =>
			return 1;
		}
	return 0;
}

Rec.get(r: self ref Rec, k: string): string
{
	for(l := r.kv; l != nil; l = tl l)
		if((hd l).t0 == k)
			return (hd l).t1;
	return nil;
}

Rec.box(r: self ref Rec): (int, int, int, int, int)
{
	v := array[4] of int;
	ks := array[] of {"x0", "y0", "x1", "y1"};
	for(i := 0; i < 4; i++){
		s := r.get(ks[i]);
		if(s == nil)
			return (0, 0, 0, 0, 0);
		(n, rest) := str->toint(s, 10);
		if(rest != nil)
			return (0, 0, 0, 0, 0);
		v[i] = n;
	}
	return (v[0], v[1], v[2], v[3], 1);
}

Rec.label(r: self ref Rec): string
{
	if((l := r.get("label")) != nil)
		return l;
	c := r.get("class");
	if((s := r.get("score")) != nil)
		c += " " + s;
	return c;
}

Rec.text(r: self ref Rec): string
{
	return format(r.kv);
}

# ---- drawing, on Draw->RGB24 pixels (blue, green, red) ----

# a colour by name, so a class keeps its colour from picture to picture
palette := array[] of {
	(16rE6, 16r19, 16r4B), (16r3C, 16rB4, 16r4B), (16rFF, 16rB0, 16r00), (16r43, 16r63, 16rD8),
	(16rF5, 16r82, 16r31), (16r91, 16r1E, 16rB4), (16r42, 16rD4, 16rF4), (16rF0, 16r32, 16rE6),
};

colour(name: string): (int, int, int)
{
	# the class's name alone, not its score
	(name, nil) = str->splitl(name, " ");
	h := 0;
	for(i := 0; i < len name; i++)
		h = (h*31 + name[i]) & 16r7FFFFFFF;
	return palette[h % len palette];
}

fill(pix: array of byte, w, h: int, x0, y0, x1, y1: int, c: (int, int, int))
{
	if(x0 < 0)
		x0 = 0;
	if(y0 < 0)
		y0 = 0;
	if(x1 > w)
		x1 = w;
	if(y1 > h)
		y1 = h;
	(r, g, b) := c;
	for(y := y0; y < y1; y++)
		for(x := x0; x < x1; x++){
			p := 3*(y*w + x);
			pix[p] = byte b;
			pix[p+1] = byte g;
			pix[p+2] = byte r;
		}
}

drawbox(pix: array of byte, w, h: int, x0, y0, x1, y1: int, label: string)
{
	if(w < 1 || h < 1 || len pix < 3*w*h)
		return;
	c := colour(label);
	m := w;
	if(h < m)
		m = h;
	t := m / 200;
	if(t < 2)
		t = 2;
	fill(pix, w, h, x0, y0, x1, y0+t, c);
	fill(pix, w, h, x0, y1-t, x1, y1, c);
	fill(pix, w, h, x0, y0, x0+t, y1, c);
	fill(pix, w, h, x1-t, y0, x1, y1, c);
	if(label == nil)
		return;
	# the label above the box, or inside it at the picture's top
	s := m / 300;
	if(s < 1)
		s = 1;
	lw := len label * 6 * s + 2*s;
	lh := 9 * s;
	ly := y0 - lh;
	if(ly < 0)
		ly = y0;
	fill(pix, w, h, x0, ly, x0+lw, ly+lh, c);
	(r, g, b) := c;
	ink := (255, 255, 255);
	if(r*299 + g*587 + b*114 > 150000)
		ink = (0, 0, 0);
	text(pix, w, h, x0 + s, ly + s, s, label, ink);
}

# 5x7 glyphs, a row each, bit 4 at the left
glyphs := array[] of {
	('0', array[] of {16r0E, 16r11, 16r13, 16r15, 16r19, 16r11, 16r0E}),
	('1', array[] of {16r04, 16r0C, 16r04, 16r04, 16r04, 16r04, 16r0E}),
	('2', array[] of {16r0E, 16r11, 16r01, 16r02, 16r04, 16r08, 16r1F}),
	('3', array[] of {16r1F, 16r02, 16r04, 16r02, 16r01, 16r11, 16r0E}),
	('4', array[] of {16r02, 16r06, 16r0A, 16r12, 16r1F, 16r02, 16r02}),
	('5', array[] of {16r1F, 16r10, 16r1E, 16r01, 16r01, 16r11, 16r0E}),
	('6', array[] of {16r06, 16r08, 16r10, 16r1E, 16r11, 16r11, 16r0E}),
	('7', array[] of {16r1F, 16r01, 16r02, 16r04, 16r08, 16r08, 16r08}),
	('8', array[] of {16r0E, 16r11, 16r11, 16r0E, 16r11, 16r11, 16r0E}),
	('9', array[] of {16r0E, 16r11, 16r11, 16r0F, 16r01, 16r02, 16r0C}),
	('a', array[] of {16r00, 16r00, 16r0E, 16r01, 16r0F, 16r11, 16r0F}),
	('b', array[] of {16r10, 16r10, 16r16, 16r19, 16r11, 16r11, 16r1E}),
	('c', array[] of {16r00, 16r00, 16r0E, 16r10, 16r10, 16r11, 16r0E}),
	('d', array[] of {16r01, 16r01, 16r0D, 16r13, 16r11, 16r11, 16r0F}),
	('e', array[] of {16r00, 16r00, 16r0E, 16r11, 16r1F, 16r10, 16r0E}),
	('f', array[] of {16r06, 16r09, 16r08, 16r1C, 16r08, 16r08, 16r08}),
	('g', array[] of {16r00, 16r0F, 16r11, 16r11, 16r0F, 16r01, 16r0E}),
	('h', array[] of {16r10, 16r10, 16r16, 16r19, 16r11, 16r11, 16r11}),
	('i', array[] of {16r04, 16r00, 16r0C, 16r04, 16r04, 16r04, 16r0E}),
	('j', array[] of {16r02, 16r00, 16r06, 16r02, 16r02, 16r12, 16r0C}),
	('k', array[] of {16r10, 16r10, 16r12, 16r14, 16r18, 16r14, 16r12}),
	('l', array[] of {16r0C, 16r04, 16r04, 16r04, 16r04, 16r04, 16r0E}),
	('m', array[] of {16r00, 16r00, 16r1A, 16r15, 16r15, 16r11, 16r11}),
	('n', array[] of {16r00, 16r00, 16r16, 16r19, 16r11, 16r11, 16r11}),
	('o', array[] of {16r00, 16r00, 16r0E, 16r11, 16r11, 16r11, 16r0E}),
	('p', array[] of {16r00, 16r00, 16r1E, 16r11, 16r1E, 16r10, 16r10}),
	('q', array[] of {16r00, 16r00, 16r0D, 16r13, 16r0F, 16r01, 16r01}),
	('r', array[] of {16r00, 16r00, 16r16, 16r19, 16r10, 16r10, 16r10}),
	('s', array[] of {16r00, 16r00, 16r0E, 16r10, 16r0E, 16r01, 16r1E}),
	('t', array[] of {16r08, 16r08, 16r1C, 16r08, 16r08, 16r09, 16r06}),
	('u', array[] of {16r00, 16r00, 16r11, 16r11, 16r11, 16r13, 16r0D}),
	('v', array[] of {16r00, 16r00, 16r11, 16r11, 16r11, 16r0A, 16r04}),
	('w', array[] of {16r00, 16r00, 16r11, 16r11, 16r15, 16r15, 16r0A}),
	('x', array[] of {16r00, 16r00, 16r11, 16r0A, 16r04, 16r0A, 16r11}),
	('y', array[] of {16r00, 16r00, 16r11, 16r11, 16r0F, 16r01, 16r0E}),
	('z', array[] of {16r00, 16r00, 16r1F, 16r02, 16r04, 16r08, 16r1F}),
	('.', array[] of {16r00, 16r00, 16r00, 16r00, 16r00, 16r0C, 16r0C}),
	('_', array[] of {16r00, 16r00, 16r00, 16r00, 16r00, 16r00, 16r1F}),
	('-', array[] of {16r00, 16r00, 16r00, 16r1F, 16r00, 16r00, 16r00}),
	(':', array[] of {16r00, 16r0C, 16r0C, 16r00, 16r0C, 16r0C, 16r00}),
	('%', array[] of {16r18, 16r19, 16r02, 16r04, 16r08, 16r13, 16r03}),
	('?', array[] of {16r0E, 16r11, 16r01, 16r02, 16r04, 16r00, 16r04}),
};

glyph(c: int): array of int
{
	if(c >= 'A' && c <= 'Z')
		c += 'a' - 'A';
	if(c == ' ')
		return nil;
	for(i := 0; i < len glyphs; i++)
		if(glyphs[i].t0 == c)
			return glyphs[i].t1;
	return glyph('?');
}

text(pix: array of byte, w, h: int, x, y, s: int, t: string, ink: (int, int, int))
{
	for(i := 0; i < len t; i++){
		g := glyph(t[i]);
		for(row := 0; g != nil && row < 7; row++)
			for(col := 0; col < 5; col++)
				if(g[row] & (16r10 >> col))
					fill(pix, w, h, x + col*s, y + row*s, x + (col+1)*s, y + (row+1)*s, ink);
		x += 6*s;
	}
}

crop(pix: array of byte, w, h: int, x0, y0, x1, y1: int): (array of byte, int, int)
{
	if(x0 < 0)
		x0 = 0;
	if(y0 < 0)
		y0 = 0;
	if(x1 > w)
		x1 = w;
	if(y1 > h)
		y1 = h;
	cw := x1 - x0;
	ch := y1 - y0;
	if(cw < 1 || ch < 1 || len pix < 3*w*h)
		return (nil, 0, 0);
	out := array[3*cw*ch] of byte;
	for(y := 0; y < ch; y++)
		out[3*y*cw:] = pix[3*((y0+y)*w + x0):3*((y0+y)*w + x0 + cw)];
	return (out, cw, ch);
}

# ---- writing pictures ----

writeall(fd: ref Sys->FD, b: array of byte): string
{
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write: %r");
	return nil;
}

writeimage(fd: ref Sys->FD, pix: array of byte, w, h: int): string
{
	if(w < 1 || h < 1 || len pix < 3*w*h)
		return "no picture";
	hdr := sys->sprint("%11s %11d %11d %11d %11d ", "r8g8b8", 0, 0, w, h);
	if((e := writeall(fd, array of byte hdr)) != nil)
		return e;
	return writeall(fd, pix[0:3*w*h]);
}

crctab: array of int;

crc32(c: int, b: array of byte): int
{
	if(crctab == nil){
		crctab = array[256] of int;
		for(n := 0; n < 256; n++){
			v := n;
			for(k := 0; k < 8; k++)
				if(v & 1)
					v = -306674912 ^ ((v >> 1) & 16r7FFFFFFF);	# 16rEDB88320, the reflected CRC-32 polynomial
				else
					v = (v >> 1) & 16r7FFFFFFF;
			crctab[n] = v;
		}
	}
	c = ~c;
	for(i := 0; i < len b; i++)
		c = crctab[(c ^ int b[i]) & 16rFF] ^ ((c >> 8) & 16rFFFFFF);
	return ~c;
}

be32(b: array of byte, o, v: int)
{
	b[o] = byte (v >> 24);
	b[o+1] = byte (v >> 16);
	b[o+2] = byte (v >> 8);
	b[o+3] = byte v;
}

chunk(fd: ref Sys->FD, kind: string, data: array of byte): string
{
	b := array[12 + len data] of byte;
	be32(b, 0, len data);
	b[4:] = array of byte kind;
	b[8:] = data;
	be32(b, 8 + len data, crc32(0, b[4:8 + len data]));
	return writeall(fd, b);
}

# PNG: 8-bit RGB, each row unfiltered, the whole through deflate's zlib
writepng(fd: ref Sys->FD, pix: array of byte, w, h: int): string
{
	if(w < 1 || h < 1 || len pix < 3*w*h)
		return "no picture";
	if(deflate == nil){
		deflate = load Filter Filter->DEFLATEPATH;
		if(deflate == nil)
			return sys->sprint("cannot load deflate: %r");
		deflate->init();
	}
	raw := array[(3*w + 1)*h] of byte;
	for(y := 0; y < h; y++){
		o := y*(3*w + 1);
		raw[o] = byte 0;
		for(x := 0; x < w; x++){
			p := 3*(y*w + x);
			raw[o+1+3*x] = pix[p+2];
			raw[o+2+3*x] = pix[p+1];
			raw[o+3+3*x] = pix[p];
		}
	}
	z: list of array of byte;
	nz := 0;
	off := 0;
	rq := deflate->start("z6");
Run:
	for(;;){
		pick m := <-rq {
		Fill =>
			n := len raw - off;
			if(n > len m.buf)
				n = len m.buf;
			m.buf[0:] = raw[off:off+n];
			off += n;
			m.reply <-= n;
		Result =>
			b := array[len m.buf] of byte;
			b[0:] = m.buf;
			z = b :: z;
			nz += len m.buf;
			m.reply <-= 0;
		Finished =>
			break Run;
		Error =>
			return "deflate: " + m.e;
		}
	}
	idat := array[nz] of byte;
	for(o := nz; z != nil; z = tl z){
		o -= len hd z;
		idat[o:] = hd z;
	}
	sig := array[] of {byte 137, byte 'P', byte 'N', byte 'G', byte 13, byte 10, byte 26, byte 10};
	if((e := writeall(fd, sig)) != nil)
		return e;
	ihdr := array[13] of byte;
	be32(ihdr, 0, w);
	be32(ihdr, 4, h);
	ihdr[8] = byte 8;	# bits a channel
	ihdr[9] = byte 2;	# RGB
	ihdr[10] = ihdr[11] = ihdr[12] = byte 0;
	if((e = chunk(fd, "IHDR", ihdr)) != nil)
		return e;
	if((e = chunk(fd, "IDAT", idat)) != nil)
		return e;
	return chunk(fd, "IEND", array[0] of byte);
}
