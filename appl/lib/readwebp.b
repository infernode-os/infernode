implement RImagefile;

#
# WebP, as RFC 9649 defines it: the RIFF container; lossless images
# (VP8L); lossy images (VP8 key frames, RFC 6386) and their alpha
# (ALPH); and animations, each frame composed onto the canvas.
#
# A lossy frame is reconstructed exactly as RFC 6386 specifies.  Its
# chroma is half the size of its luma, and is brought up to full size
# and converted to RGB as libwebp does by default (its "fancy"
# upsampling), so a picture comes out as other browsers show it.
#
# An animation is composed as libwebp composes one, pixel for pixel: on
# a transparent canvas (the background colour is only a hint, and
# others ignore it too), each frame blended or not as it says, then
# disposed of or not.  readmulti returns every frame as the whole
# canvas (as many as MAXANIMPIXELS allows); read returns the first.
#
# A file that is not what it claims raises "webp:...", caught at the
# top and returned as the error; so is any fault decoding it, an array
# bound overrun by a corrupt file among them.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";

# A decoded frame: channels as Rawimage has them; a is nil if opaque
Pic: adt {
	w:	int;
	h:	int;
	r:	array of byte;
	g:	array of byte;
	b:	array of byte;
	a:	array of byte;
};

# The most pixels a frame or a canvas may have, as imgload's limit; and
# the most an animation's frames may have between them
MAXPIXELS: con 16*1024*1024;
MAXANIMPIXELS: con 64*1024*1024;

init(iomod: Bufio)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	bufio = iomod;
}

read(fd: ref Iobuf): (ref Rawimage, string)
{
	(a, err) := readfile(fd, 0);
	if(a == nil)
		return (nil, err);
	return (a[0], err);
}

readmulti(fd: ref Iobuf): (array of ref Rawimage, string)
{
	return readfile(fd, 1);
}

readfile(fd: ref Iobuf, multi: int): (array of ref Rawimage, string)
{
	data := readall(fd);
	{
		return (decodefile(data, multi), "");
	} exception e {
	"webp:*" =>
		return (nil, e[5:]);
	"*" =>
		return (nil, "corrupt image: " + e);
	}
}

# ==================== The container ====================

Chunk: adt {
	id:	string;
	data:	array of byte;
};

# The chunks in d[off:end], each padded to an even length
chunks(d: array of byte, off, end: int): list of ref Chunk
{
	l: list of ref Chunk;
	while(off + 8 <= end) {
		n := le32(d, off+4);
		s := off + 8;
		if(n < 0 || n > end - s)
			n = end - s;	# truncated: take what there is
		l = ref Chunk(string d[off:off+4], d[s:s+n]) :: l;
		off = s + n + (n & 1);
	}
	r: list of ref Chunk;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

decodefile(d: array of byte, multi: int): array of ref Rawimage
{
	if(len d < 12 || string d[0:4] != "RIFF" || string d[8:12] != "WEBP")
		raise "webp:not a WebP file";
	end := le32(d, 4) + 8;
	if(end > len d || end < 12)
		end = len d;
	cl := chunks(d, 12, end);
	if(cl == nil)
		raise "webp:no image data";
	if((hd cl).id != "VP8X")
		return array[] of {rawimage(frame(cl))};

	x := (hd cl).data;
	if(len x < 10)
		raise "webp:VP8X: chunk too short";
	animated := int x[0] & 16r02;
	cw := 1 + le24(x, 4);
	ch := 1 + le24(x, 7);
	if(!animated)
		return array[] of {rawimage(frame(tl cl))};
	toobig(cw, ch);

	nf := 0;
	for(l := cl; l != nil; l = tl l)
		if((hd l).id == "ANMF")
			nf++;
	if(nf == 0)
		raise "webp:animation has no frames";
	if(!multi)
		nf = 1;
	if(nf > MAXANIMPIXELS / (cw*ch))
		nf = MAXANIMPIXELS / (cw*ch);
	return animate(cl, cw, ch, nf);
}

# A frame's image, from its chunks: an optional ALPH, then VP8 or VP8L
frame(cl: list of ref Chunk): ref Pic
{
	alph: array of byte;
	for(; cl != nil; cl = tl cl) {
		c := hd cl;
		case c.id {
		"ALPH" =>
			alph = c.data;
		"VP8 " =>
			p := vp8(c.data);
			if(alph != nil)
				p.a = alpha(alph, p.w, p.h);
			return p;
		"VP8L" =>
			return vp8l(c.data);
		}
	}
	raise "webp:no image data";
}

toobig(w, h: int)
{
	if(w > MAXPIXELS / h)
		raise sys->sprint("webp:too large: %dx%d", w, h);
}

rawimage(p: ref Pic): ref Rawimage
{
	raw := ref Rawimage;
	raw.r = ((0, 0), (p.w, p.h));
	raw.transp = 0;
	if(p.a != nil) {
		raw.nchans = 4;
		raw.chandesc = RImagefile->CRGBA;
		raw.chans = array[] of {p.r, p.g, p.b, p.a};
	} else {
		raw.nchans = 3;
		raw.chandesc = RImagefile->CRGB;
		raw.chans = array[] of {p.r, p.g, p.b};
	}
	return raw;
}

# ==================== Animation ====================

animate(cl: list of ref Chunk, cw, ch, nf: int): array of ref Rawimage
{
	n := cw * ch;
	cr := array[n] of {* => byte 0};
	cg := array[n] of {* => byte 0};
	cb := array[n] of {* => byte 0};
	ca := array[n] of {* => byte 0};
	out := array[nf] of ref Rawimage;
	i := 0;
	# the previous frame: whether it was disposed of, its rectangle,
	# and whether it was a key frame
	pdispose := 0;
	px, py, pw, ph: int;
	pkey := 0;
	for(; cl != nil && i < nf; cl = tl cl) {
		c := hd cl;
		if(c.id != "ANMF")
			continue;
		d := c.data;
		if(len d < 16)
			raise "webp:ANMF: chunk too short";
		fx := 2 * le24(d, 0);
		fy := 2 * le24(d, 3);
		fw := 1 + le24(d, 6);
		fh := 1 + le24(d, 9);
		duration := le24(d, 12);
		flags := int d[15];
		blend := (flags & 2) == 0;
		p := frame(chunks(d, 16, len d));
		if(p.w != fw || p.h != fh)
			raise "webp:ANMF: frame size does not match its image";

		# A key frame, which libwebp draws on a clear canvas without
		# blending: the first; one that covers the canvas and needs
		# nothing under it; one after a frame disposed of that covered
		# the canvas or was itself drawn on a clear one.
		full := fw == cw && fh == ch;
		key := i == 0 || full && (p.a == nil || !blend) ||
			pdispose && (pw == cw && ph == ch || pkey);
		if(key)
			fillrect(cr, cg, cb, ca, cw, ch, 0, 0, cw, ch);
		else if(pdispose)
			fillrect(cr, cg, cb, ca, cw, ch, px, py, pw, ph);
		for(y := 0; y < fh && fy + y < ch; y++) {
			s := y * fw;
			t := (fy + y) * cw + fx;
			for(x := 0; x < fw && fx + x < cw; x++) {
				a := 255;
				if(p.a != nil)
					a = int p.a[s];
				# a pixel not opaque is blended with what is under
				# it, except where the previous frame was cleared
				if(blend && !key && a != 255 && !(pdispose &&
				   fx+x >= px && fx+x < px+pw && fy+y >= py && fy+y < py+ph)) {
					if(a != 0) {
						# libwebp's non-premultiplied blend
						da := (int ca[t] * (256 - a)) >> 8;
						ba := a + da;
						scale := big (1<<24) / big ba;
						cr[t] = byte ((big (int p.r[s] * a + int cr[t] * da) * scale) >> 24);
						cg[t] = byte ((big (int p.g[s] * a + int cg[t] * da) * scale) >> 24);
						cb[t] = byte ((big (int p.b[s] * a + int cb[t] * da) * scale) >> 24);
						ca[t] = byte ba;
					}
				} else {
					cr[t] = p.r[s];
					cg[t] = p.g[s];
					cb[t] = p.b[s];
					ca[t] = byte a;
				}
				s++;
				t++;
			}
		}
		raw := rawimage(ref Pic(cw, ch, copy(cr), copy(cg), copy(cb), copy(ca)));
		raw.fields = duration;
		out[i++] = raw;
		pdispose = flags & 1;
		(px, py, pw, ph) = (fx, fy, fw, fh);
		pkey = key;
	}
	return out[0:i];
}

fillrect(r, g, b, a: array of byte, cw, ch, x0, y0, w, h: int)
{
	for(y := y0; y < y0 + h && y < ch; y++)
		for(x := x0; x < x0 + w && x < cw; x++) {
			i := y * cw + x;
			r[i] = g[i] = b[i] = a[i] = byte 0;
		}
}

copy(a: array of byte): array of byte
{
	c := array[len a] of byte;
	c[0:] = a;
	return c;
}

# ==================== Alpha (ALPH) ====================

alpha(d: array of byte, w, h: int): array of byte
{
	if(len d < 1)
		raise "webp:ALPH: chunk too short";
	hdr := int d[0];
	method := hdr & 3;
	filter := (hdr >> 2) & 3;
	n := w * h;
	a := array[n] of {* => byte 255};
	case method {
	0 =>
		m := len d - 1;
		if(m > n)
			m = n;
		a[0:] = d[1:1+m];
	1 =>
		b := ref LB(d, 1, len d, 0, 0);
		argb := vp8lstream(b, w, h);
		for(i := 0; i < n; i++)
			a[i] = byte (argb[i] >> 8);
	* =>
		raise "webp:ALPH: unknown compression";
	}
	if(filter != 0)
		unfilter(a, w, h, filter);
	return a;
}

# Undo the alpha plane's filter: each value was stored less its prediction
unfilter(a: array of byte, w, h, filter: int)
{
	for(y := 0; y < h; y++) {
		r := y * w;
		for(x := 0; x < w; x++) {
			pred: int;
			if(x == 0 && y == 0)
				pred = 0;
			else if(y == 0)
				pred = int a[r+x-1];	# the top row: from the left
			else if(x == 0)
				pred = int a[r-w];	# the left column: from above
			else case filter {
			1 =>
				pred = int a[r+x-1];
			2 =>
				pred = int a[r+x-w];
			* =>
				pred = int a[r+x-1] + int a[r+x-w] - int a[r+x-w-1];
				if(pred < 0)
					pred = 0;
				else if(pred > 255)
					pred = 255;
			}
			a[r+x] = byte (int a[r+x] + pred);
		}
	}
}

# ==================== Lossless (VP8L) ====================

# The bit reader: least significant bit first
LB: adt {
	d:	array of byte;
	p:	int;	# the next byte
	e:	int;	# the end of the data
	v:	int;	# bits not yet read, the next lowest
	n:	int;	# how many
};

lbfill(b: ref LB)
{
	while(b.n <= 23) {
		c := 0;
		if(b.p < b.e)
			c = int b.d[b.p];
		else if(b.p > b.e + 8)
			raise "webp:VP8L: truncated";
		b.p++;
		b.v |= c << b.n;
		b.n += 8;
	}
}

rb(b: ref LB, k: int): int
{
	if(b.n < k)
		lbfill(b);
	x := b.v & ((1<<k) - 1);
	b.v >>= k;
	b.n -= k;
	return x;
}

# A prefix code.  Codes of FASTBITS bits or fewer are looked up in
# fast (each entry its length<<16 | its symbol); longer ones are
# decoded canonically from cnt and sym.  A code of one symbol is
# single, and reads no bits.
FASTBITS: con 8;

Huff: adt {
	single:	int;
	fast:	array of int;
	cnt:	array of int;
	sym:	array of int;
};

hbuild(lens: array of int): ref Huff
{
	cnt := array[16] of {* => 0};
	nz := 0;
	last := 0;
	for(i := 0; i < len lens; i++)
		if(lens[i] != 0) {
			cnt[lens[i]]++;
			nz++;
			last = i;
		}
	if(nz == 0)
		raise "webp:VP8L: empty prefix code";
	if(nz == 1)
		return ref Huff(last, nil, nil, nil);
	left := 1;
	for(l := 1; l < 16; l++) {
		left = (left << 1) - cnt[l];
		if(left < 0)
			raise "webp:VP8L: prefix code is over-subscribed";
	}
	if(left != 0)
		raise "webp:VP8L: prefix code is incomplete";

	offs := array[16] of int;
	offs[1] = 0;
	for(l = 1; l < 15; l++)
		offs[l+1] = offs[l] + cnt[l];
	sym := array[nz] of int;
	for(i = 0; i < len lens; i++)
		if(lens[i] != 0)
			sym[offs[lens[i]]++] = i;

	fast := array[1<<FASTBITS] of {* => -1};
	code := 0;
	k := 0;
	for(l = 1; l <= FASTBITS; l++) {
		for(j := 0; j < cnt[l]; j++) {
			rev := 0;
			for(m := 0; m < l; m++)
				rev |= ((code >> m) & 1) << (l - 1 - m);
			for(f := rev; f < len fast; f += 1<<l)
				fast[f] = (l<<16) | sym[k];
			code++;
			k++;
		}
		code <<= 1;
	}
	return ref Huff(-1, fast, cnt, sym);
}

hsym(b: ref LB, h: ref Huff): int
{
	if(h.single >= 0)
		return h.single;
	if(b.n < 15)
		lbfill(b);
	e := h.fast[b.v & ((1<<FASTBITS) - 1)];
	if(e >= 0) {
		l := e >> 16;
		b.v >>= l;
		b.n -= l;
		return e & 16rFFFF;
	}
	# a code longer than FASTBITS: decode it a bit at a time
	v := b.v;
	code := 0;
	first := 0;
	index := 0;
	for(l := 1; l < 16; l++) {
		code |= v & 1;
		v >>= 1;
		c := h.cnt[l];
		if(code - first < c) {
			b.v >>= l;
			b.n -= l;
			return h.sym[index + code - first];
		}
		index += c;
		first = (first + c) << 1;
		code <<= 1;
	}
	raise "webp:VP8L: bad prefix code";
}

clorder := array[] of {17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

readcode(b: ref LB, alphabet: int): ref Huff
{
	lens := array[alphabet] of {* => 0};
	if(rb(b, 1)) {
		# simple: one or two symbols
		ns := rb(b, 1) + 1;
		s := rb(b, 1 + 7*rb(b, 1));
		if(s >= alphabet)
			raise "webp:VP8L: bad prefix code";
		lens[s] = 1;
		if(ns == 2) {
			s = rb(b, 8);
			if(s >= alphabet)
				raise "webp:VP8L: bad prefix code";
			lens[s] = 1;
		}
		return hbuild(lens);
	}
	cl := array[19] of {* => 0};
	n := rb(b, 4) + 4;
	for(i := 0; i < n; i++)
		cl[clorder[i]] = rb(b, 3);
	clh := hbuild(cl);
	max := alphabet;
	if(rb(b, 1)) {
		max = 2 + rb(b, 2 + 2*rb(b, 3));
		if(max > alphabet)
			raise "webp:VP8L: bad prefix code";
	}
	prev := 8;
	for(s := 0; s < alphabet && max-- > 0; ) {
		c := hsym(b, clh);
		if(c < 16) {
			lens[s++] = c;
			if(c != 0)
				prev = c;
			continue;
		}
		rep, v: int;
		case c {
		16 =>
			(rep, v) = (3 + rb(b, 2), prev);
		17 =>
			(rep, v) = (3 + rb(b, 3), 0);
		* =>
			(rep, v) = (11 + rb(b, 7), 0);
		}
		if(s + rep > alphabet)
			raise "webp:VP8L: bad prefix code";
		while(rep-- > 0)
			lens[s++] = v;
	}
	return hbuild(lens);
}

vp8l(d: array of byte): ref Pic
{
	if(len d < 5 || int d[0] != 16r2F)
		raise "webp:VP8L: bad signature";
	hdr := int d[1] | (int d[2]<<8) | (int d[3]<<16) | (int d[4]<<24);
	w := (hdr & 16r3FFF) + 1;
	h := ((hdr >> 14) & 16r3FFF) + 1;
	hasalpha := (hdr >> 28) & 1;
	if((hdr >> 29) & 7)
		raise "webp:VP8L: unknown version";
	toobig(w, h);
	argb := vp8lstream(ref LB(d, 5, len d, 0, 0), w, h);
	n := w * h;
	p := ref Pic(w, h, array[n] of byte, array[n] of byte, array[n] of byte, nil);
	for(i := 0; i < n; i++) {
		c := argb[i];
		p.r[i] = byte (c >> 16);
		p.g[i] = byte (c >> 8);
		p.b[i] = byte c;
	}
	if(hasalpha) {
		p.a = array[n] of byte;
		for(i = 0; i < n; i++)
			p.a[i] = byte (argb[i] >> 24);
	}
	return p;
}

Xform: adt {
	t:	int;
	bits:	int;
	w:	int;	# the image's width when the transform was read
	data:	array of int;
};

PREDICT, CROSSCOLOUR, SUBGREEN, INDEX: con iota;

# An image stream: its transforms, then its pixels, which the
# transforms, undone last first, make the image
vp8lstream(b: ref LB, w, h: int): array of int
{
	xf: list of ref Xform;
	seen := 0;
	xw := w;
	while(rb(b, 1)) {
		t := rb(b, 2);
		if(seen & (1<<t))
			raise "webp:VP8L: transform repeated";
		seen |= 1<<t;
		x := ref Xform(t, 0, xw, nil);
		case t {
		PREDICT or CROSSCOLOUR =>
			x.bits = rb(b, 3) + 2;
			x.data = vp8limage(b, divup(xw, 1<<x.bits), divup(h, 1<<x.bits), 0);
		INDEX =>
			n := rb(b, 8) + 1;
			if(n > 16)
				x.bits = 0;
			else if(n > 4)
				x.bits = 1;
			else if(n > 2)
				x.bits = 2;
			else
				x.bits = 3;
			pal := vp8limage(b, n, 1, 0);
			x.data = array[256] of {* => 0};	# out of range: transparent black
			x.data[0] = pal[0];
			for(i := 1; i < n; i++)
				x.data[i] = addpix(pal[i], x.data[i-1]);
			xw = divup(xw, 1<<x.bits);
		}
		xf = x :: xf;
	}
	pix := vp8limage(b, xw, h, 1);
	for(; xf != nil; xf = tl xf) {
		x := hd xf;
		case x.t {
		PREDICT =>
			unpredict(pix, x.w, h, x.bits, x.data);
		CROSSCOLOUR =>
			uncross(pix, x.w, h, x.bits, x.data);
		SUBGREEN =>
			for(i := 0; i < len pix; i++) {
				c := pix[i];
				g := (c >> 8) & 255;
				pix[i] = (c & int 16rFF00FF00) | ((((c >> 16) + g) & 255) << 16) | ((c + g) & 255);
			}
		INDEX =>
			pix = unindex(pix, x.w, h, x.bits, x.data);
		}
	}
	return pix;
}

# Entropy-coded pixels: the image itself (main), with meta prefix
# codes; or a transform's, without
vp8limage(b: ref LB, w, h, main: int): array of int
{
	cbits := 0;
	if(rb(b, 1)) {
		cbits = rb(b, 4);
		if(cbits < 1 || cbits > 11)
			raise "webp:VP8L: bad colour cache size";
	}
	mbits := 0;
	ew := 0;
	ent: array of int;
	ngroups := 1;
	if(main && rb(b, 1)) {
		mbits = rb(b, 3) + 2;
		ew = divup(w, 1<<mbits);
		ent = vp8limage(b, ew, divup(h, 1<<mbits), 0);
		for(i := 0; i < len ent; i++) {
			g := (ent[i] >> 8) & 16rFFFF;
			ent[i] = g;
			if(g >= ngroups)
				ngroups = g + 1;
		}
	}
	csize := 0;
	if(cbits)
		csize = 1<<cbits;
	groups := array[ngroups] of array of ref Huff;
	for(i := 0; i < ngroups; i++) {
		groups[i] = array[5] of ref Huff;
		groups[i][0] = readcode(b, 256 + 24 + csize);
		groups[i][1] = readcode(b, 256);
		groups[i][2] = readcode(b, 256);
		groups[i][3] = readcode(b, 256);
		groups[i][4] = readcode(b, 40);
	}

	n := w * h;
	pix := array[n] of int;
	cache: array of int;
	cshift := 32 - cbits;
	cmask := csize - 1;
	if(csize)
		cache = array[csize] of {* => 0};
	cached := 0;	# pixels before this are in the cache
	tmask := (1<<mbits) - 1;
	gr := groups[0];
	hg := gr[0];
	x := 0;
	y := 0;
	for(i = 0; i < n; ) {
		if(mbits && (x & tmask) == 0) {
			gr = groups[ent[(y>>mbits)*ew + (x>>mbits)]];
			hg = gr[0];
		}
		s := hsym(b, hg);
		if(s < 256) {
			r := hsym(b, gr[1]);
			bl := hsym(b, gr[2]);
			a := hsym(b, gr[3]);
			pix[i++] = (a<<24) | (r<<16) | (s<<8) | bl;
			if(++x == w) {
				x = 0;
				y++;
			}
		} else if(s < 256 + 24) {
			l := prefixval(b, s - 256);
			dc := prefixval(b, hsym(b, gr[4]));
			dist: int;
			if(dc > 120)
				dist = dc - 120;
			else {
				dist = distmap[2*dc-2] + distmap[2*dc-1]*w;
				if(dist < 1)
					dist = 1;
			}
			if(dist > i || l > n - i)
				raise "webp:VP8L: bad backward reference";
			for(j := i - dist; l > 0; l--)
				pix[i++] = pix[j++];
			x = i % w;
			y = i / w;
			if(mbits && i < n && (x & tmask) != 0) {
				gr = groups[ent[(y>>mbits)*ew + (x>>mbits)]];
				hg = gr[0];
			}
		} else {
			k := s - (256 + 24);
			if(k >= csize)
				raise "webp:VP8L: bad colour cache index";
			while(cached < i) {
				c := pix[cached++];
				cache[((16r1E35A7BD * c) >> cshift) & cmask] = c;
			}
			pix[i++] = cache[k];
			if(++x == w) {
				x = 0;
				y++;
			}
		}
	}
	return pix;
}

prefixval(b: ref LB, c: int): int
{
	if(c < 4)
		return c + 1;
	eb := (c - 2) >> 1;
	return ((2 + (c & 1)) << eb) + rb(b, eb) + 1;
}

# ARGB arithmetic, a component at a time
addpix(a, b: int): int
{
	return (((a & int 16rFF00FF00) + (b & int 16rFF00FF00)) & int 16rFF00FF00) |
		(((a & 16r00FF00FF) + (b & 16r00FF00FF)) & 16r00FF00FF);
}

# (a component at a time, rounding down; the mask after the shift
# because >> carries the sign)
pavg(a, b: int): int
{
	return (a & b) + (((a ^ b) >> 1) & 16r7F7F7F7F);
}

select(l, t, tlx: int): int
{
	pl := 0;	# sum |T - TL|: the distance of the estimate from L
	pt := 0;	# sum |L - TL|
	for(sh := 0; sh < 32; sh += 8) {
		c := (tlx >> sh) & 255;
		d := ((t >> sh) & 255) - c;
		if(d < 0)
			d = -d;
		pl += d;
		d = ((l >> sh) & 255) - c;
		if(d < 0)
			d = -d;
		pt += d;
	}
	if(pl < pt)
		return l;
	return t;
}

clampfull(a, b, c: int): int
{
	r := 0;
	for(sh := 0; sh < 32; sh += 8) {
		v := ((a >> sh) & 255) + ((b >> sh) & 255) - ((c >> sh) & 255);
		if(v < 0)
			v = 0;
		else if(v > 255)
			v = 255;
		r |= v << sh;
	}
	return r;
}

clamphalf(a, b: int): int
{
	r := 0;
	for(sh := 0; sh < 32; sh += 8) {
		x := (a >> sh) & 255;
		v := x + (x - ((b >> sh) & 255)) / 2;
		if(v < 0)
			v = 0;
		else if(v > 255)
			v = 255;
		r |= v << sh;
	}
	return r;
}

unpredict(pix: array of int, w, h, bits: int, modes: array of int)
{
	tw := divup(w, 1<<bits);
	pix[0] = addpix(pix[0], int 16rFF000000);
	for(x := 1; x < w; x++)
		pix[x] = addpix(pix[x], pix[x-1]);
	for(y := 1; y < h; y++) {
		r := y * w;
		pix[r] = addpix(pix[r], pix[r-w]);
		mrow := (y >> bits) * tw;
		for(x = 1; x < w; x++) {
			i := r + x;
			l := pix[i-1];
			p: int;
			case (modes[mrow + (x>>bits)] >> 8) & 15 {
			1 =>	p = l;
			2 =>	p = pix[i-w];
			3 =>	p = pix[i-w+1];
			4 =>	p = pix[i-w-1];
			5 =>	p = pavg(pavg(l, pix[i-w+1]), pix[i-w]);
			6 =>	p = pavg(l, pix[i-w-1]);
			7 =>	p = pavg(l, pix[i-w]);
			8 =>	p = pavg(pix[i-w-1], pix[i-w]);
			9 =>	p = pavg(pix[i-w], pix[i-w+1]);
			10 =>	p = pavg(pavg(l, pix[i-w-1]), pavg(pix[i-w], pix[i-w+1]));
			11 =>	p = select(l, pix[i-w], pix[i-w-1]);
			12 =>	p = clampfull(l, pix[i-w], pix[i-w-1]);
			13 =>	p = clamphalf(pavg(l, pix[i-w]), pix[i-w-1]);
			* =>	p = int 16rFF000000;
			}
			pix[i] = addpix(pix[i], p);
		}
	}
}

sx8(v: int): int
{
	return ((v & 255) ^ 128) - 128;
}

uncross(pix: array of int, w, h, bits: int, data: array of int)
{
	tw := divup(w, 1<<bits);
	for(y := 0; y < h; y++) {
		drow := (y >> bits) * tw;
		for(x := 0; x < w; x++) {
			e := data[drow + (x>>bits)];
			i := y*w + x;
			c := pix[i];
			g := sx8(c >> 8);
			r := ((c >> 16) + ((sx8(e) * g) >> 5)) & 255;
			bl := (c + ((sx8(e >> 8) * g) >> 5) + ((sx8(e >> 16) * sx8(r)) >> 5)) & 255;
			pix[i] = (c & int 16rFF00FF00) | (r << 16) | bl;
		}
	}
}

unindex(pix: array of int, w, h, bits: int, pal: array of int): array of int
{
	out := array[w*h] of int;
	if(bits == 0) {
		for(i := 0; i < len out; i++)
			out[i] = pal[(pix[i] >> 8) & 255];
		return out;
	}
	pw := divup(w, 1<<bits);
	per := 8 >> bits;	# bits an index takes
	m := (1<<per) - 1;
	xm := (1<<bits) - 1;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++) {
			g := (pix[y*pw + (x>>bits)] >> 8) & 255;
			out[y*w + x] = pal[(g >> ((x & xm) * per)) & m];
		}
	return out;
}

# ==================== Lossy (VP8) ====================

# The boolean decoder (RFC 6386 section 7), as libwebp keeps it: the
# value's bits below its 8-bit window counted by bits, and the range
# kept less one.
BD: adt {
	d:	array of byte;
	p:	int;
	e:	int;
	v:	int;
	bits:	int;
	rng:	int;
};

bdnew(d: array of byte, p, e: int): ref BD
{
	return ref BD(d, p, e, 0, -8, 254);
}

# norm[r]: the left shift that brings a range r back to [128, 255]
norm: array of int;

getbit(b: ref BD, prob: int): int
{
	if(b.bits < 0) {
		c := 0;
		if(b.p < b.e)
			c = int b.d[b.p];
		b.p++;
		b.v = (b.v << 8) | c;
		b.bits += 8;
	}
	split := (b.rng * prob) >> 8;
	r, bit: int;
	if((b.v >> b.bits) > split) {
		r = b.rng - split;
		b.v -= (split + 1) << b.bits;
		bit = 1;
	} else {
		r = split + 1;
		bit = 0;
	}
	s := norm[r];
	b.rng = (r << s) - 1;
	b.bits -= s;
	return bit;
}

getlit(b: ref BD, n: int): int
{
	v := 0;
	while(n-- > 0)
		v = (v << 1) | getbit(b, 128);
	return v;
}

# A value of n bits and a sign, if a flag says it is there
getsigned(b: ref BD, n: int): int
{
	if(!getbit(b, 128))
		return 0;
	v := getlit(b, n);
	if(getbit(b, 128))
		return -v;
	return v;
}

gettree(b: ref BD, t, p: array of int, poff: int): int
{
	i := 0;
	while((i = t[i + getbit(b, p[poff + (i>>1)])]) > 0)
		;
	return -i;
}

# Prediction modes
DC_PRED, V_PRED, H_PRED, TM_PRED, B_PRED: con iota;
B_DC_PRED, B_TM_PRED, B_VE_PRED, B_HE_PRED, B_LD_PRED,
B_RD_PRED, B_VR_PRED, B_VL_PRED, B_HD_PRED, B_HU_PRED: con iota;

kfymodetree := array[] of {-B_PRED, 2, 4, 6, -DC_PRED, -V_PRED, -H_PRED, -TM_PRED};
kfymodeprob := array[] of {145, 156, 163, 128};
uvmodetree := array[] of {-DC_PRED, 2, -V_PRED, 4, -H_PRED, -TM_PRED};
kfuvmodeprob := array[] of {142, 114, 183};
bmodetree := array[] of {
	-B_DC_PRED, 2,
	-B_TM_PRED, 4,
	-B_VE_PRED, 6,
	8, 12,
	-B_HE_PRED, 10,
	-B_RD_PRED, -B_VR_PRED,
	-B_LD_PRED, 14,
	-B_VL_PRED, 16,
	-B_HD_PRED, -B_HU_PRED,
};
# the subblock mode a whole-macroblock luma mode implies, for context
impliedb := array[] of {B_DC_PRED, B_VE_PRED, B_HE_PRED, B_TM_PRED};

zigzag := array[] of {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
bands := array[] of {0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0};
# the probabilities of the extra bits of DCT_CAT3 to DCT_CAT6
catprob := array[] of {
	173, 148, 140,
	176, 155, 140, 135,
	180, 157, 141, 134, 130,
	254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129,
};
catoff := array[] of {0, 3, 7, 12, 23};

# The decoded frame: the planes, each with a border above and to the
# left that prediction reads (127 above, 129 to the left), and the
# luma four columns more to the right, for the pixels above and to the
# right of the last macroblock in a row
Frame: adt {
	w, h:	int;
	mbw, mbh:	int;
	y:	array of byte;
	u:	array of byte;
	v:	array of byte;
	ys:	int;	# strides
	uvs:	int;
	yo:	int;	# where pixel (0, 0) is
	uvo:	int;
};

# Dequantisation factors for a segment
Quant: adt {
	y1:	array of int;	# dc, ac
	y2:	array of int;
	uv:	array of int;
};

vp8(d: array of byte): ref Pic
{
	if(norm == nil)
		mktables();
	f := vp8frame(d);
	return torgb(f);
}

vp8frame(d: array of byte): ref Frame
{
	if(len d < 10)
		raise "webp:VP8: truncated";
	tag := int d[0] | (int d[1]<<8) | (int d[2]<<16);
	if(tag & 1)
		raise "webp:VP8: not a key frame";
	p0 := tag >> 5;
	if(int d[3] != 16r9D || int d[4] != 16r01 || int d[5] != 16r2A)
		raise "webp:VP8: bad start code";
	w := (int d[6] | (int d[7]<<8)) & 16r3FFF;
	h := (int d[8] | (int d[9]<<8)) & 16r3FFF;
	if(w == 0 || h == 0)
		raise "webp:VP8: no size";
	toobig(w, h);
	if(10 + p0 > len d)
		raise "webp:VP8: truncated";
	b := bdnew(d, 10, 10 + p0);

	getbit(b, 128);	# colour space
	getbit(b, 128);	# clamping: we always clamp

	# segments
	segon := getbit(b, 128);
	segmap := 0;
	segabs := 0;
	segq := array[4] of {* => 0};
	seglf := array[4] of {* => 0};
	segprob := array[3] of {* => 255};
	if(segon) {
		segmap = getbit(b, 128);
		if(getbit(b, 128)) {
			segabs = getbit(b, 128);
			for(i := 0; i < 4; i++)
				segq[i] = getsigned(b, 7);
			for(i = 0; i < 4; i++)
				seglf[i] = getsigned(b, 6);
		}
		if(segmap)
			for(i := 0; i < 3; i++)
				if(getbit(b, 128))
					segprob[i] = getlit(b, 8);
	}

	# the loop filter
	simple := getbit(b, 128);
	level := getlit(b, 6);
	sharp := getlit(b, 3);
	refdelta := array[4] of {* => 0};
	modedelta := array[4] of {* => 0};
	lfdelta := getbit(b, 128);
	if(lfdelta && getbit(b, 128)) {
		for(i := 0; i < 4; i++)
			refdelta[i] = getsigned(b, 6);
		for(i = 0; i < 4; i++)
			modedelta[i] = getsigned(b, 6);
	}

	# the token partitions
	np := 1 << getlit(b, 2);
	parts := array[np] of ref BD;
	o := 10 + p0;
	ps := o + 3*(np-1);
	if(ps > len d)
		raise "webp:VP8: truncated";
	for(i := 0; i < np; i++) {
		n := len d - ps;
		if(i < np - 1) {
			n = int d[o] | (int d[o+1]<<8) | (int d[o+2]<<16);
			o += 3;
		}
		if(ps + n > len d)
			n = len d - ps;	# truncated: the rest decodes as zeros
		parts[i] = bdnew(d, ps, ps + n);
		ps += n;
	}

	# quantisers
	qi := getlit(b, 7);
	dy1dc := getsigned(b, 4);
	dy2dc := getsigned(b, 4);
	dy2ac := getsigned(b, 4);
	duvdc := getsigned(b, 4);
	duvac := getsigned(b, 4);
	quants := array[4] of ref Quant;
	for(i = 0; i < 4; i++) {
		q := qi;
		if(segon) {
			q = segq[i];
			if(!segabs)
				q += qi;
		}
		y2ac := acq[clampq(q + dy2ac)] * 155 / 100;
		if(y2ac < 8)
			y2ac = 8;
		uvdc := dcq[clampq(q + duvdc)];
		if(uvdc > 132)
			uvdc = 132;
		quants[i] = ref Quant(
			array[] of {dcq[clampq(q + dy1dc)], acq[clampq(q)]},
			array[] of {dcq[clampq(q + dy2dc)] * 2, y2ac},
			array[] of {uvdc, acq[clampq(q + duvac)]});
	}

	getbit(b, 128);	# refresh entropy probabilities: there is one frame

	probs := array[len coeffdefault] of int;
	probs[0:] = coeffdefault;
	for(i = 0; i < len probs; i++)
		if(getbit(b, coeffupdate[i]))
			probs[i] = getlit(b, 8);

	skipon := getbit(b, 128);
	skipprob := 0;
	if(skipon)
		skipprob = getlit(b, 8);

	# Loop filter strengths, by segment and whether a macroblock is
	# B_PRED: (limit, interior limit, high edge variance threshold)
	flim := array[8] of int;
	filev := array[8] of int;
	fhev := array[8] of int;
	for(s := 0; s < 4; s++)
		for(i4 := 0; i4 < 2; i4++) {
			l := level;
			if(segon) {
				l = seglf[s];
				if(!segabs)
					l += level;
			}
			if(lfdelta) {
				l += refdelta[0];
				if(i4)
					l += modedelta[0];
			}
			if(l > 63)
				l = 63;
			else if(l < 0)
				l = 0;
			il := l;
			if(sharp > 0) {
				if(sharp > 4)
					il >>= 2;
				else
					il >>= 1;
				if(il > 9 - sharp)
					il = 9 - sharp;
			}
			if(il < 1)
				il = 1;
			k := 2*s + i4;
			flim[k] = 0;
			if(l > 0)
				flim[k] = 2*l + il;
			filev[k] = il;
			fhev[k] = 0;
			if(l >= 40)
				fhev[k] = 2;
			else if(l >= 15)
				fhev[k] = 1;
		}

	mbw := (w + 15) >> 4;
	mbh := (h + 15) >> 4;
	ys := mbw*16 + 5;
	uvs := mbw*8 + 1;
	f := ref Frame(w, h, mbw, mbh,
		array[ys * (mbh*16 + 1)] of byte,
		array[uvs * (mbh*8 + 1)] of byte,
		array[uvs * (mbh*8 + 1)] of byte,
		ys, uvs, ys + 1, uvs + 1);
	for(i = 0; i < ys; i++)
		f.y[i] = byte 127;
	for(i = 0; i < uvs; i++)
		f.u[i] = f.v[i] = byte 127;
	for(i = 1; i <= mbh*16; i++)
		f.y[i*ys] = byte 129;
	for(i = 1; i <= mbh*8; i++)
		f.u[i*uvs] = f.v[i*uvs] = byte 129;

	# contexts: the subblock modes above and to the left, and whether
	# the blocks above and to the left had coefficients
	abmode := array[mbw*4] of {* => B_DC_PRED};
	lbmode := array[4] of int;
	anz := array[mbw*9] of {* => 0};	# 4 luma, 2+2 chroma, Y2
	lnz := array[9] of int;
	bmodes := array[16] of int;
	coeffs := array[24*16] of {* => 0};
	y2 := array[16] of {* => 0};
	nzs := array[24] of {* => 0};

	# what the loop filter wants of each macroblock: its strength's
	# index, and whether to filter its inner edges
	finfo := array[mbw*mbh] of int;

	for(mby := 0; mby < mbh; mby++) {
		tb := parts[mby & (np-1)];
		for(i = 0; i < 4; i++)
			lbmode[i] = B_DC_PRED;
		for(i = 0; i < 9; i++)
			lnz[i] = 0;
		for(mbx := 0; mbx < mbw; mbx++) {
			# the macroblock's header, from the first partition
			seg := 0;
			if(segmap) {
				if(getbit(b, segprob[0]))
					seg = 2 + getbit(b, segprob[2]);
				else
					seg = getbit(b, segprob[1]);
			}
			skip := 0;
			if(skipon)
				skip = getbit(b, skipprob);
			ymode := gettree(b, kfymodetree, kfymodeprob, 0);
			if(ymode == B_PRED) {
				for(i = 0; i < 16; i++) {
					a := abmode[mbx*4 + (i&3)];
					l := lbmode[i>>2];
					m := gettree(b, bmodetree, kfbmode, (a*10 + l)*9);
					bmodes[i] = m;
					abmode[mbx*4 + (i&3)] = m;
					lbmode[i>>2] = m;
				}
			} else {
				m := impliedb[ymode];
				for(i = 0; i < 4; i++)
					abmode[mbx*4 + i] = lbmode[i] = m;
			}
			uvmode := gettree(b, uvmodetree, kfuvmodeprob, 0);

			# its coefficients, from its token partition
			q := quants[seg];
			nonzero := 0;
			if(!skip)
				nonzero = residuals(tb, probs, q, ymode != B_PRED, coeffs, y2, nzs, anz, mbx*9, lnz);
			else {
				for(i = 0; i < 8; i++)
					anz[mbx*9 + i] = lnz[i] = 0;
				if(ymode != B_PRED)
					anz[mbx*9 + 8] = lnz[8] = 0;
			}
			inner := ymode == B_PRED || nonzero;
			finfo[mby*mbw + mbx] = (2*seg + (ymode == B_PRED)) | (inner << 3);

			reconstruct(f, mbx, mby, ymode, uvmode, bmodes, coeffs, nzs);

			# leave the coefficients zero for the next
			for(i = 0; i < 24; i++)
				if(nzs[i]) {
					for(j := i*16; j < i*16 + 16; j++)
						coeffs[j] = 0;
					nzs[i] = 0;
				}
		}
		# the pixels right of the last macroblock, for the next row's
		# prediction: its own bottom right pixel, repeated
		r := f.yo + (mby*16 + 15)*ys + mbw*16;
		for(i = 0; i < 4; i++)
			f.y[r+i] = f.y[r-1];
	}

	if(level > 0)
		loopfilter(f, simple, finfo, flim, filev, fhev);
	return f;
}

clampq(q: int): int
{
	if(q < 0)
		return 0;
	if(q > 127)
		return 127;
	return q;
}

# A macroblock's coefficients, dequantised, in coeffs (all zero to
# begin with): sixteen luma blocks, four U, four V.  With a Y2 block
# (any luma mode but B_PRED), read into y2, its inverse Walsh-Hadamard
# transform gives the luma blocks' DCs.
# nzs says of each block: 0, no coefficients; 1, only a DC; 2, more.
# The result is whether any block has a coefficient.
residuals(b: ref BD, probs: array of int, q: ref Quant, hasy2: int,
	coeffs, y2, nzs, anz: array of int, ao: int, lnz: array of int): int
{
	first := 0;
	ytype := 3;
	if(hasy2) {
		for(i := 0; i < 16; i++)
			y2[i] = 0;
		ctx := anz[ao+8] + lnz[8];
		n := tokens(b, probs, 1, ctx, q.y2, 0, y2, 0);
		anz[ao+8] = lnz[8] = n > 0;
		if(n > 1)
			iwht(y2, coeffs);
		else {
			dc := (y2[0] + 3) >> 3;
			for(i = 0; i < 16; i++)
				coeffs[i*16] = dc;
		}
		first = 1;
		ytype = 0;
	}
	any := 0;
	for(y := 0; y < 4; y++) {
		l := lnz[y];
		for(x := 0; x < 4; x++) {
			k := y*4 + x;
			n := tokens(b, probs, ytype, l + anz[ao+x], q.y1, first, coeffs, k*16);
			l = n > first;
			anz[ao+x] = l;
			if(n > 1)
				nzs[k] = 2;
			else if(coeffs[k*16] != 0)
				nzs[k] = 1;
			any |= nzs[k];
		}
		lnz[y] = l;
	}
	for(p := 0; p < 2; p++)
		for(y = 0; y < 2; y++) {
			l := lnz[4 + 2*p + y];
			for(x := 0; x < 2; x++) {
				k := 16 + 4*p + y*2 + x;
				a := ao + 4 + 2*p + x;
				n := tokens(b, probs, 2, l + anz[a], q.uv, 0, coeffs, k*16);
				l = n > 0;
				anz[a] = l;
				if(n > 1)
					nzs[k] = 2;
				else if(coeffs[k*16] != 0)
					nzs[k] = 1;
				any |= nzs[k];
			}
			lnz[4 + 2*p + y] = l;
		}
	return any != 0;
}

# One block's tokens (RFC 6386 section 13), from coefficient n on,
# dequantised by dq into out[o:o+16]; the result is the index after
# the last one read, or 16
tokens(b: ref BD, probs: array of int, typ, ctx: int, dq: array of int, n: int, out: array of int, o: int): int
{
	base := typ * (8*3*11);
	p := base + bands[n]*33 + ctx*11;
	while(n < 16) {
		if(!getbit(b, probs[p]))
			return n;	# end of block
		while(!getbit(b, probs[p+1])) {	# a zero
			if(++n == 16)
				return 16;
			p = base + bands[n]*33;
		}
		v: int;
		nctx: int;
		if(!getbit(b, probs[p+2])) {
			v = 1;
			nctx = 1;
		} else {
			if(!getbit(b, probs[p+3])) {
				if(!getbit(b, probs[p+4]))
					v = 2;
				else
					v = 3 + getbit(b, probs[p+5]);
			} else if(!getbit(b, probs[p+6])) {
				if(!getbit(b, probs[p+7]))
					v = 5 + getbit(b, 159);
				else {
					v = 7 + 2*getbit(b, 165);
					v += getbit(b, 145);
				}
			} else {
				b1 := getbit(b, probs[p+8]);
				b0 := getbit(b, probs[p+9+b1]);
				cat := 2*b1 + b0;
				v = 0;
				for(i := catoff[cat]; i < catoff[cat+1]; i++)
					v += v + getbit(b, catprob[i]);
				v += 3 + (8 << cat);
			}
			nctx = 2;
		}
		if(getbit(b, 128))
			v = -v;
		if(n == 0)
			out[o + zigzag[n]] = v * dq[0];
		else
			out[o + zigzag[n]] = v * dq[1];
		n++;
		p = base + bands[n]*33 + nctx*11;
	}
	return 16;
}

# The inverse Walsh-Hadamard transform: in, the Y2 block; the results
# are the sixteen luma blocks' DCs
iwht(in, coeffs: array of int)
{
	t := array[16] of int;
	for(i := 0; i < 4; i++) {
		a1 := in[i] + in[12+i];
		b1 := in[4+i] + in[8+i];
		c1 := in[4+i] - in[8+i];
		d1 := in[i] - in[12+i];
		t[i] = a1 + b1;
		t[4+i] = c1 + d1;
		t[8+i] = a1 - b1;
		t[12+i] = d1 - c1;
	}
	for(i = 0; i < 4; i++) {
		a1 := t[4*i] + t[4*i+3];
		b1 := t[4*i+1] + t[4*i+2];
		c1 := t[4*i+1] - t[4*i+2];
		d1 := t[4*i] - t[4*i+3];
		coeffs[(4*i)*16] = (a1 + b1 + 3) >> 3;
		coeffs[(4*i+1)*16] = (c1 + d1 + 3) >> 3;
		coeffs[(4*i+2)*16] = (a1 - b1 + 3) >> 3;
		coeffs[(4*i+3)*16] = (d1 - c1 + 3) >> 3;
	}
}

clip255(v: int): byte
{
	if(v < 0)
		return byte 0;
	if(v > 255)
		return byte 255;
	return byte v;
}

# Add a block's residue, the inverse DCT of c[o:o+16], to the
# prediction at pl[pos], its rows s apart
idctadd(c: array of int, o: int, nz: int, pl: array of byte, pos, s: int)
{
	if(nz == 0)
		return;
	if(nz == 1) {
		dc := (c[o] + 4) >> 3;
		for(y := 0; y < 4; y++) {
			for(x := 0; x < 4; x++)
				pl[pos+x] = clip255(int pl[pos+x] + dc);
			pos += s;
		}
		return;
	}
	t := array[16] of int;
	for(i := 0; i < 4; i++) {
		i0 := c[o+i];
		i4 := c[o+4+i];
		i8 := c[o+8+i];
		i12 := c[o+12+i];
		a1 := i0 + i8;
		b1 := i0 - i8;
		c1 := ((i4 * 35468) >> 16) - (i12 + ((i12 * 20091) >> 16));
		d1 := (i4 + ((i4 * 20091) >> 16)) + ((i12 * 35468) >> 16);
		t[i] = a1 + d1;
		t[12+i] = a1 - d1;
		t[4+i] = b1 + c1;
		t[8+i] = b1 - c1;
	}
	for(i = 0; i < 4; i++) {
		t0 := t[4*i];
		t1 := t[4*i+1];
		t2 := t[4*i+2];
		t3 := t[4*i+3];
		a1 := t0 + t2;
		b1 := t0 - t2;
		c1 := ((t1 * 35468) >> 16) - (t3 + ((t3 * 20091) >> 16));
		d1 := (t1 + ((t1 * 20091) >> 16)) + ((t3 * 35468) >> 16);
		pl[pos] = clip255(int pl[pos] + ((a1 + d1 + 4) >> 3));
		pl[pos+3] = clip255(int pl[pos+3] + ((a1 - d1 + 4) >> 3));
		pl[pos+1] = clip255(int pl[pos+1] + ((b1 + c1 + 4) >> 3));
		pl[pos+2] = clip255(int pl[pos+2] + ((b1 - c1 + 4) >> 3));
		pos += s;
	}
}

reconstruct(f: ref Frame, mbx, mby, ymode, uvmode: int, bmodes, coeffs, nzs: array of int)
{
	ys := f.ys;
	yp := f.yo + mby*16*ys + mbx*16;
	if(ymode == B_PRED) {
		# above and right of the subblocks on the right: always
		# from the row above the macroblock
		tr := yp - ys + 16;
		for(i := 0; i < 16; i++) {
			bx := i & 3;
			by := i >> 2;
			pos := yp + by*4*ys + bx*4;
			trp := pos - ys + 4;
			if(bx == 3)
				trp = tr;
			predict4(f.y, pos, ys, trp, bmodes[i]);
			idctadd(coeffs, i*16, nzs[i], f.y, pos, ys);
		}
	} else {
		predict(f.y, yp, ys, 16, ymode, mbx, mby);
		for(i := 0; i < 16; i++)
			idctadd(coeffs, i*16, nzs[i], f.y, yp + (i>>2)*4*ys + (i&3)*4, ys);
	}
	uvs := f.uvs;
	up := f.uvo + mby*8*uvs + mbx*8;
	predict(f.u, up, uvs, 8, uvmode, mbx, mby);
	predict(f.v, up, uvs, 8, uvmode, mbx, mby);
	for(i := 0; i < 4; i++) {
		o := up + (i>>1)*4*uvs + (i&1)*4;
		idctadd(coeffs, (16+i)*16, nzs[16+i], f.u, o, uvs);
		idctadd(coeffs, (20+i)*16, nzs[20+i], f.v, o, uvs);
	}
}

# A whole block's prediction: luma 16x16, or chroma 8x8
predict(pl: array of byte, p, s, n, mode, mbx, mby: int)
{
	case mode {
	DC_PRED =>
		sum := 0;
		shift := 3;
		if(n == 16)
			shift = 4;
		if(mby > 0) {
			for(i := 0; i < n; i++)
				sum += int pl[p - s + i];
			shift++;
		}
		if(mbx > 0) {
			for(i := 0; i < n; i++)
				sum += int pl[p + i*s - 1];
			shift++;
		}
		dc := byte 128;
		if(mbx > 0 || mby > 0) {
			shift--;
			dc = byte ((sum + (1 << (shift-1))) >> shift);
		}
		for(y := 0; y < n; y++)
			for(x := 0; x < n; x++)
				pl[p + y*s + x] = dc;
	V_PRED =>
		for(y := 0; y < n; y++)
			pl[p + y*s:] = pl[p - s:p - s + n];
	H_PRED =>
		for(y := 0; y < n; y++) {
			l := pl[p + y*s - 1];
			for(x := 0; x < n; x++)
				pl[p + y*s + x] = l;
		}
	TM_PRED =>
		tlx := int pl[p - s - 1];
		for(y := 0; y < n; y++) {
			l := int pl[p + y*s - 1] - tlx;
			for(x := 0; x < n; x++)
				pl[p + y*s + x] = clip255(l + int pl[p - s + x]);
		}
	}
}

# A 4x4 subblock's prediction at pl[p]; the four pixels above and to
# its right are at pl[tr]
predict4(pl: array of byte, p, s, tr, mode: int)
{
	t := p - s;
	# above: A[-1] (the corner) to A[7]; left: L[0] to L[3]
	P := int pl[t-1];
	A0 := int pl[t];
	A1 := int pl[t+1];
	A2 := int pl[t+2];
	A3 := int pl[t+3];
	A4 := int pl[tr];
	A5 := int pl[tr+1];
	A6 := int pl[tr+2];
	A7 := int pl[tr+3];
	L0 := int pl[p-1];
	L1 := int pl[p+s-1];
	L2 := int pl[p+2*s-1];
	L3 := int pl[p+3*s-1];
	case mode {
	B_DC_PRED =>
		dc := byte ((A0 + A1 + A2 + A3 + L0 + L1 + L2 + L3 + 4) >> 3);
		for(y := 0; y < 4; y++)
			for(x := 0; x < 4; x++)
				pl[p + y*s + x] = dc;
	B_TM_PRED =>
		a := array[] of {A0, A1, A2, A3};
		l := array[] of {L0, L1, L2, L3};
		for(y := 0; y < 4; y++)
			for(x := 0; x < 4; x++)
				pl[p + y*s + x] = clip255(l[y] + a[x] - P);
	B_VE_PRED =>
		v := array[] of {
			byte avg3(P, A0, A1), byte avg3(A0, A1, A2),
			byte avg3(A1, A2, A3), byte avg3(A2, A3, A4)};
		for(y := 0; y < 4; y++)
			pl[p + y*s:] = v;
	B_HE_PRED =>
		h := array[] of {
			byte avg3(P, L0, L1), byte avg3(L0, L1, L2),
			byte avg3(L1, L2, L3), byte avg3(L2, L3, L3)};
		for(y := 0; y < 4; y++)
			for(x := 0; x < 4; x++)
				pl[p + y*s + x] = h[y];
	B_LD_PRED =>
		e := array[] of {
			avg3(A0, A1, A2), avg3(A1, A2, A3), avg3(A2, A3, A4),
			avg3(A3, A4, A5), avg3(A4, A5, A6), avg3(A5, A6, A7),
			avg3(A6, A7, A7)};
		for(y := 0; y < 4; y++)
			for(x := 0; x < 4; x++)
				pl[p + y*s + x] = byte e[x + y];
	B_RD_PRED =>
		# along the edge from the bottom of the left to the right of the top
		e := array[] of {
			avg3(L3, L2, L1), avg3(L2, L1, L0), avg3(L1, L0, P),
			avg3(L0, P, A0), avg3(P, A0, A1), avg3(A0, A1, A2),
			avg3(A1, A2, A3)};
		for(y := 0; y < 4; y++)
			for(x := 0; x < 4; x++)
				pl[p + y*s + x] = byte e[3 - y + x];
	B_VR_PRED =>
		put4(pl, p, s, array[] of {
			avg2(P, A0), avg2(A0, A1), avg2(A1, A2), avg2(A2, A3),
			avg3(L0, P, A0), avg3(P, A0, A1), avg3(A0, A1, A2), avg3(A1, A2, A3),
			avg3(L1, L0, P), avg2(P, A0), avg2(A0, A1), avg2(A1, A2),
			avg3(L2, L1, L0), avg3(L0, P, A0), avg3(P, A0, A1), avg3(A0, A1, A2)});
	B_VL_PRED =>
		put4(pl, p, s, array[] of {
			avg2(A0, A1), avg2(A1, A2), avg2(A2, A3), avg2(A3, A4),
			avg3(A0, A1, A2), avg3(A1, A2, A3), avg3(A2, A3, A4), avg3(A3, A4, A5),
			avg2(A1, A2), avg2(A2, A3), avg2(A3, A4), avg3(A4, A5, A6),
			avg3(A1, A2, A3), avg3(A2, A3, A4), avg3(A3, A4, A5), avg3(A5, A6, A7)});
	B_HD_PRED =>
		put4(pl, p, s, array[] of {
			avg2(L0, P), avg3(L0, P, A0), avg3(P, A0, A1), avg3(A0, A1, A2),
			avg2(L1, L0), avg3(L1, L0, P), avg2(L0, P), avg3(L0, P, A0),
			avg2(L2, L1), avg3(L2, L1, L0), avg2(L1, L0), avg3(L1, L0, P),
			avg2(L3, L2), avg3(L3, L2, L1), avg2(L2, L1), avg3(L2, L1, L0)});
	B_HU_PRED =>
		put4(pl, p, s, array[] of {
			avg2(L0, L1), avg3(L0, L1, L2), avg2(L1, L2), avg3(L1, L2, L3),
			avg2(L1, L2), avg3(L1, L2, L3), avg2(L2, L3), avg3(L2, L3, L3),
			avg2(L2, L3), avg3(L2, L3, L3), L3, L3,
			L3, L3, L3, L3});
	}
}

avg2(a, b: int): int
{
	return (a + b + 1) >> 1;
}

avg3(a, b, c: int): int
{
	return (a + 2*b + c + 2) >> 2;
}

put4(pl: array of byte, p, s: int, v: array of int)
{
	for(y := 0; y < 4; y++)
		for(x := 0; x < 4; x++)
			pl[p + y*s + x] = byte v[y*4 + x];
}

# The loop filter (RFC 6386 section 15), over the whole frame once it
# is reconstructed, a macroblock at a time in raster order: its left
# edge, its inner vertical edges, its top edge, its inner horizontal
# edges.
loopfilter(f: ref Frame, simple: int, finfo, flim, filev, fhev: array of int)
{
	ys := f.ys;
	uvs := f.uvs;
	for(mby := 0; mby < f.mbh; mby++)
		for(mbx := 0; mbx < f.mbw; mbx++) {
			fi := finfo[mby*f.mbw + mbx];
			k := fi & 7;
			inner := fi >> 3;
			lim := flim[k];
			if(lim == 0)
				continue;
			il := filev[k];
			hev := fhev[k];
			yp := f.yo + mby*16*ys + mbx*16;
			if(simple) {
				if(mbx > 0)
					simpleedge(f.y, yp, 1, ys, 16, lim + 4);
				if(inner)
					for(x := 4; x < 16; x += 4)
						simpleedge(f.y, yp + x, 1, ys, 16, lim);
				if(mby > 0)
					simpleedge(f.y, yp, ys, 1, 16, lim + 4);
				if(inner)
					for(y := 4; y < 16; y += 4)
						simpleedge(f.y, yp + y*ys, ys, 1, 16, lim);
				continue;
			}
			up := f.uvo + mby*8*uvs + mbx*8;
			if(mbx > 0) {
				edge(f.y, yp, 1, ys, 16, lim + 4, il, hev, 1);
				edge(f.u, up, 1, uvs, 8, lim + 4, il, hev, 1);
				edge(f.v, up, 1, uvs, 8, lim + 4, il, hev, 1);
			}
			if(inner) {
				for(x := 4; x < 16; x += 4)
					edge(f.y, yp + x, 1, ys, 16, lim, il, hev, 0);
				edge(f.u, up + 4, 1, uvs, 8, lim, il, hev, 0);
				edge(f.v, up + 4, 1, uvs, 8, lim, il, hev, 0);
			}
			if(mby > 0) {
				edge(f.y, yp, ys, 1, 16, lim + 4, il, hev, 1);
				edge(f.u, up, uvs, 1, 8, lim + 4, il, hev, 1);
				edge(f.v, up, uvs, 1, 8, lim + 4, il, hev, 1);
			}
			if(inner) {
				for(y := 4; y < 16; y += 4)
					edge(f.y, yp + y*ys, ys, 1, 16, lim, il, hev, 0);
				edge(f.u, up + 4*uvs, uvs, 1, 8, lim, il, hev, 0);
				edge(f.v, up + 4*uvs, uvs, 1, 8, lim, il, hev, 0);
			}
		}
}

# Clamping, by table, as libwebp does it: abs0[x+255] is |x|;
# sclip1[x+1020] is x clamped to [-128, 127]; sclip2[x+112] is x
# clamped to [-16, 15]; clip1[x+255] is x clamped to [0, 255].
abs0, sclip1, sclip2: array of int;
clip1: array of byte;

# YUV to RGB, as libwebp converts (14-bit fixed point, BT.601); the
# sums, shifted down 6, are clamped by clip1
ytab, vrtab, ugtab, vgtab, ubtab: array of int;

# Make the tables, each whole before it is seen, as the module may be
# shared; norm, the one vp8 looks for, last
mktables()
{
	ab := array[511] of int;
	for(i := -255; i <= 255; i++) {
		ab[i+255] = i;
		if(i < 0)
			ab[i+255] = -i;
	}
	s1 := array[2041] of int;
	for(i = -1020; i <= 1020; i++) {
		v := i;
		if(v < -128)
			v = -128;
		else if(v > 127)
			v = 127;
		s1[i+1020] = v;
	}
	s2 := array[225] of int;
	for(i = -112; i <= 112; i++) {
		v := i;
		if(v < -16)
			v = -16;
		else if(v > 15)
			v = 15;
		s2[i+112] = v;
	}
	c1 := array[766] of byte;
	for(i = -255; i <= 510; i++) {
		v := i;
		if(v < 0)
			v = 0;
		else if(v > 255)
			v = 255;
		c1[i+255] = byte v;
	}
	yt := array[256] of int;
	vr := array[256] of int;
	ug := array[256] of int;
	vg := array[256] of int;
	ub := array[256] of int;
	for(i = 0; i < 256; i++) {
		yt[i] = (i * 19077) >> 8;
		vr[i] = ((i * 26149) >> 8) - 14234;
		ug[i] = (i * 6419) >> 8;
		vg[i] = ((i * 13320) >> 8) - 8708;
		ub[i] = ((i * 33050) >> 8) - 17685;
	}
	nm := array[256] of int;
	for(r := 1; r < 256; r++) {
		sh := 0;
		while((r << sh) < 128)
			sh++;
		nm[r] = sh;
	}
	(abs0, sclip1, sclip2, clip1) = (ab, s1, s2, c1);
	(ytab, vrtab, ugtab, vgtab, ubtab) = (yt, vr, ug, vg, ub);
	norm = nm;
}

# Filter n pixels along an edge, from pl[pos] on, adv apart; the
# pixels either side of it are step apart: p3 p2 p1 p0 | q0 q1 q2 q3.
# The simple filter moves p0 and q0.
simpleedge(pl: array of byte, pos, step, adv, n, lim: int)
{
	for(; n > 0; n--) {
		p1 := int pl[pos - 2*step];
		p0 := int pl[pos - step];
		q0 := int pl[pos];
		q1 := int pl[pos + step];
		if(2*abs0[p0 - q0 + 255] + (abs0[p1 - q1 + 255] >> 1) <= lim) {
			a := 3*(q0 - p0) + sclip1[p1 - q1 + 1020];
			pl[pos - step] = clip1[p0 + sclip2[((a + 3) >> 3) + 112] + 255];
			pl[pos] = clip1[q0 - sclip2[((a + 4) >> 3) + 112] + 255];
		}
		pos += adv;
	}
}

# The normal filter: where the edge varies a lot, as the simple one;
# elsewhere, across a macroblock edge (mb) it moves three pixels each
# side, and across a subblock's edge two.
edge(pl: array of byte, pos, step, adv, n, lim, il, hev, mb: int)
{
	for(; n > 0; n--) {
		p1 := int pl[pos - 2*step];
		p0 := int pl[pos - step];
		q0 := int pl[pos];
		q1 := int pl[pos + step];
		if(2*abs0[p0 - q0 + 255] + (abs0[p1 - q1 + 255] >> 1) > lim) {
			pos += adv;
			continue;
		}
		p3 := int pl[pos - 4*step];
		p2 := int pl[pos - 3*step];
		q2 := int pl[pos + 2*step];
		q3 := int pl[pos + 3*step];
		if(abs0[p3 - p2 + 255] > il || abs0[p2 - p1 + 255] > il || abs0[p1 - p0 + 255] > il ||
		   abs0[q3 - q2 + 255] > il || abs0[q2 - q1 + 255] > il || abs0[q1 - q0 + 255] > il) {
			pos += adv;
			continue;
		}
		if(abs0[p1 - p0 + 255] > hev || abs0[q1 - q0 + 255] > hev) {
			a := 3*(q0 - p0) + sclip1[p1 - q1 + 1020];
			pl[pos - step] = clip1[p0 + sclip2[((a + 3) >> 3) + 112] + 255];
			pl[pos] = clip1[q0 - sclip2[((a + 4) >> 3) + 112] + 255];
		} else if(mb) {
			a := sclip1[3*(q0 - p0) + sclip1[p1 - q1 + 1020] + 1020];
			a1 := (27*a + 63) >> 7;
			a2 := (18*a + 63) >> 7;
			a3 := (9*a + 63) >> 7;
			pl[pos - 3*step] = clip1[p2 + a3 + 255];
			pl[pos - 2*step] = clip1[p1 + a2 + 255];
			pl[pos - step] = clip1[p0 + a1 + 255];
			pl[pos] = clip1[q0 - a1 + 255];
			pl[pos + step] = clip1[q1 - a2 + 255];
			pl[pos + 2*step] = clip1[q2 - a3 + 255];
		} else {
			a := 3*(q0 - p0);
			a1 := sclip2[((a + 4) >> 3) + 112];
			a2 := sclip2[((a + 3) >> 3) + 112];
			a3 := (a1 + 1) >> 1;
			pl[pos - 2*step] = clip1[p1 + a3 + 255];
			pl[pos - step] = clip1[p0 + a2 + 255];
			pl[pos] = clip1[q0 - a1 + 255];
			pl[pos + step] = clip1[q1 - a3 + 255];
		}
		pos += adv;
	}
}

torgb(f: ref Frame): ref Pic
{
	w := f.w;
	h := f.h;
	n := w * h;
	p := ref Pic(w, h, array[n] of byte, array[n] of byte, array[n] of byte, nil);
	ch := (h + 1) >> 1;
	ur := array[w] of int;
	vr := array[w] of int;
	o := 0;
	for(y := 0; y < h; y++) {
		# the chroma rows nearer and farther from this luma row
		near, far: int;
		if(y == 0)
			near = far = 0;
		else if(y & 1) {
			near = (y - 1) >> 1;
			far = (y + 1) >> 1;
			if(far >= ch)
				far = ch - 1;
		} else {
			near = y >> 1;
			far = near - 1;
		}
		upline(f.u, f.uvo + near*f.uvs, f.uvo + far*f.uvs, w, ur);
		upline(f.v, f.uvo + near*f.uvs, f.uvo + far*f.uvs, w, vr);
		yr := f.yo + y*f.ys;
		for(x := 0; x < w; x++) {
			yy := ytab[int f.y[yr + x]];
			u := ur[x];
			v := vr[x];
			p.r[o] = clip1[((yy + vrtab[v]) >> 6) + 255];
			p.g[o] = clip1[((yy - ugtab[u] - vgtab[v]) >> 6) + 255];
			p.b[o] = clip1[((yy + ubtab[u]) >> 6) + 255];
			o++;
		}
	}
	return p;
}

# A row of chroma brought up to full width and between two rows, the
# nearer weighted 3 to the farther's 1, both ways
upline(pl: array of byte, n, fa, w: int, out: array of int)
{
	tlx := int pl[n];
	l := int pl[fa];
	out[0] = (3*tlx + l + 2) >> 2;
	last := (w - 1) >> 1;
	for(j := 1; j <= last; j++) {
		t := int pl[n + j];
		u := int pl[fa + j];
		avg := tlx + t + l + u + 8;
		out[2*j - 1] = (((avg + 2*(t + l)) >> 3) + tlx) >> 1;
		out[2*j] = (((avg + 2*(tlx + u)) >> 3) + t) >> 1;
		tlx = t;
		l = u;
	}
	if((w & 1) == 0)
		out[w - 1] = (3*tlx + l + 2) >> 2;
}

# ==================== Utilities ====================

divup(n, d: int): int
{
	return (n + d - 1) / d;
}

le24(d: array of byte, o: int): int
{
	return int d[o] | (int d[o+1]<<8) | (int d[o+2]<<16);
}

le32(d: array of byte, o: int): int
{
	return int d[o] | (int d[o+1]<<8) | (int d[o+2]<<16) | (int d[o+3]<<24);
}

readall(fd: ref Iobuf): array of byte
{
	buf := array[65536] of byte;
	n := 0;
	for(;;) {
		if(n == len buf) {
			nb := array[2 * len buf] of byte;
			nb[0:] = buf;
			buf = nb;
		}
		m := fd.read(buf[n:], len buf - n);
		if(m <= 0)
			break;
		n += m;
	}
	return buf[0:n];
}

# ==================== Tables ====================

coeffupdate := array[] of {
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255,
	249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255,
	234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255,
	250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255,
	234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255,
	255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255,
	255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255,
	234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255,
	251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255,
	255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255,
	255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255,
	248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255,
	255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255,
	255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255,
	248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255,
	255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
};
coeffdefault := array[] of {
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128,
	189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128,
	106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128,
	1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128,
	181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128,
	78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128,
	1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128,
	184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128,
	77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128,
	1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128,
	170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128,
	37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128,
	1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128,
	207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128,
	102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128,
	1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128,
	177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128,
	80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128,
	1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62,
	131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1,
	68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128,
	1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128,
	184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128,
	81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128,
	1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128,
	99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128,
	23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128,
	1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128,
	109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128,
	44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128,
	1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128,
	94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128,
	22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128,
	1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128,
	124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128,
	35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128,
	1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128,
	121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128,
	45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128,
	1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128,
	203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128,
	137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
	253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128,
	175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128,
	73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128,
	1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128,
	239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128,
	155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128,
	1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128,
	201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128,
	69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128,
	1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128,
	223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128,
	141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128,
	1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128,
	190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128,
	149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128,
	213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128,
	55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255,
	126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128,
	61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128,
	1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128,
	166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128,
	39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128,
	1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128,
	124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128,
	24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128,
	1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128,
	149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128,
	28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128,
	1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128,
	123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128,
	20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128,
	1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128,
	168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128,
	47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128,
	1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128,
	141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128,
	42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128,
	1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
};
kfbmode := array[] of {
	231, 120, 48, 89, 115, 113, 120, 152, 112,
	152, 179, 64, 126, 170, 118, 46, 70, 95,
	175, 69, 143, 80, 85, 82, 72, 155, 103,
	56, 58, 10, 171, 218, 189, 17, 13, 152,
	144, 71, 10, 38, 171, 213, 144, 34, 26,
	114, 26, 17, 163, 44, 195, 21, 10, 173,
	121, 24, 80, 195, 26, 62, 44, 64, 85,
	170, 46, 55, 19, 136, 160, 33, 206, 71,
	63, 20, 8, 114, 114, 208, 12, 9, 226,
	81, 40, 11, 96, 182, 84, 29, 16, 36,
	134, 183, 89, 137, 98, 101, 106, 165, 148,
	72, 187, 100, 130, 157, 111, 32, 75, 80,
	66, 102, 167, 99, 74, 62, 40, 234, 128,
	41, 53, 9, 178, 241, 141, 26, 8, 107,
	104, 79, 12, 27, 217, 255, 87, 17, 7,
	74, 43, 26, 146, 73, 166, 49, 23, 157,
	65, 38, 105, 160, 51, 52, 31, 115, 128,
	87, 68, 71, 44, 114, 51, 15, 186, 23,
	47, 41, 14, 110, 182, 183, 21, 17, 194,
	66, 45, 25, 102, 197, 189, 23, 18, 22,
	88, 88, 147, 150, 42, 46, 45, 196, 205,
	43, 97, 183, 117, 85, 38, 35, 179, 61,
	39, 53, 200, 87, 26, 21, 43, 232, 171,
	56, 34, 51, 104, 114, 102, 29, 93, 77,
	107, 54, 32, 26, 51, 1, 81, 43, 31,
	39, 28, 85, 171, 58, 165, 90, 98, 64,
	34, 22, 116, 206, 23, 34, 43, 166, 73,
	68, 25, 106, 22, 64, 171, 36, 225, 114,
	34, 19, 21, 102, 132, 188, 16, 76, 124,
	62, 18, 78, 95, 85, 57, 50, 48, 51,
	193, 101, 35, 159, 215, 111, 89, 46, 111,
	60, 148, 31, 172, 219, 228, 21, 18, 111,
	112, 113, 77, 85, 179, 255, 38, 120, 114,
	40, 42, 1, 196, 245, 209, 10, 25, 109,
	100, 80, 8, 43, 154, 1, 51, 26, 71,
	88, 43, 29, 140, 166, 213, 37, 43, 154,
	61, 63, 30, 155, 67, 45, 68, 1, 209,
	142, 78, 78, 16, 255, 128, 34, 197, 171,
	41, 40, 5, 102, 211, 183, 4, 1, 221,
	51, 50, 17, 168, 209, 192, 23, 25, 82,
	125, 98, 42, 88, 104, 85, 117, 175, 82,
	95, 84, 53, 89, 128, 100, 113, 101, 45,
	75, 79, 123, 47, 51, 128, 81, 171, 1,
	57, 17, 5, 71, 102, 57, 53, 41, 49,
	115, 21, 2, 10, 102, 255, 166, 23, 6,
	38, 33, 13, 121, 57, 73, 26, 1, 85,
	41, 10, 67, 138, 77, 110, 90, 47, 114,
	101, 29, 16, 10, 85, 128, 101, 196, 26,
	57, 18, 10, 102, 102, 213, 34, 20, 43,
	117, 20, 15, 36, 163, 128, 68, 1, 26,
	138, 31, 36, 171, 27, 166, 38, 44, 229,
	67, 87, 58, 169, 82, 115, 26, 59, 179,
	63, 59, 90, 180, 59, 166, 93, 73, 154,
	40, 40, 21, 116, 143, 209, 34, 39, 175,
	57, 46, 22, 24, 128, 1, 54, 17, 37,
	47, 15, 16, 183, 34, 223, 49, 45, 183,
	46, 17, 33, 183, 6, 98, 15, 32, 183,
	65, 32, 73, 115, 28, 128, 23, 128, 205,
	40, 3, 9, 115, 51, 192, 18, 6, 223,
	87, 37, 9, 115, 59, 77, 64, 21, 47,
	104, 55, 44, 218, 9, 54, 53, 130, 226,
	64, 90, 70, 205, 40, 41, 23, 26, 57,
	54, 57, 112, 184, 5, 41, 38, 166, 213,
	30, 34, 26, 133, 152, 116, 10, 32, 134,
	75, 32, 12, 51, 192, 255, 160, 43, 51,
	39, 19, 53, 221, 26, 114, 32, 73, 255,
	31, 9, 65, 234, 2, 15, 1, 118, 73,
	88, 31, 35, 67, 102, 85, 55, 186, 85,
	56, 21, 23, 111, 59, 205, 45, 37, 192,
	55, 38, 70, 124, 73, 102, 1, 34, 98,
	102, 61, 71, 37, 34, 53, 31, 243, 192,
	69, 60, 71, 38, 73, 119, 28, 222, 37,
	68, 45, 128, 34, 1, 47, 11, 245, 171,
	62, 17, 19, 70, 146, 85, 55, 62, 70,
	75, 15, 9, 9, 64, 255, 184, 119, 16,
	37, 43, 37, 154, 100, 163, 85, 160, 1,
	63, 9, 92, 136, 28, 64, 32, 201, 85,
	86, 6, 28, 5, 64, 255, 25, 248, 1,
	56, 8, 17, 132, 137, 255, 55, 116, 128,
	58, 15, 20, 82, 135, 57, 26, 121, 40,
	164, 50, 31, 137, 154, 133, 25, 35, 218,
	51, 103, 44, 131, 131, 123, 31, 6, 158,
	86, 40, 64, 135, 148, 224, 45, 183, 128,
	22, 26, 17, 131, 240, 154, 14, 1, 209,
	83, 12, 13, 54, 192, 255, 68, 47, 28,
	45, 16, 21, 91, 64, 222, 7, 1, 197,
	56, 21, 39, 155, 60, 138, 23, 102, 213,
	85, 26, 85, 85, 128, 128, 32, 146, 171,
	18, 11, 7, 63, 144, 171, 4, 4, 246,
	35, 27, 10, 146, 174, 171, 12, 26, 128,
	190, 80, 35, 99, 180, 80, 126, 54, 45,
	85, 126, 47, 87, 176, 51, 41, 20, 32,
	101, 75, 128, 139, 118, 146, 116, 128, 85,
	56, 41, 15, 176, 236, 85, 37, 9, 62,
	146, 36, 19, 30, 171, 255, 97, 27, 20,
	71, 30, 17, 119, 118, 255, 17, 18, 138,
	101, 38, 60, 138, 55, 70, 43, 26, 142,
	138, 45, 61, 62, 219, 1, 81, 188, 64,
	32, 41, 20, 117, 151, 142, 20, 21, 163,
	112, 19, 12, 61, 195, 128, 48, 4, 24,
};
dcq := array[] of {
	4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17,
	18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28,
	29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43,
	44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
	59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
	75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
	91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
	122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
};
acq := array[] of {
	4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
	20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
	36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
	52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76,
	78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108,
	110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
	155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
	213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
};
distmap := array[] of {
	0, 1, 1, 0, 1, 1, -1, 1, 0, 2, 2, 0, 1, 2, -1, 2,
	2, 1, -2, 1, 2, 2, -2, 2, 0, 3, 3, 0, 1, 3, -1, 3,
	3, 1, -3, 1, 2, 3, -2, 3, 3, 2, -3, 2, 0, 4, 4, 0,
	1, 4, -1, 4, 4, 1, -4, 1, 3, 3, -3, 3, 2, 4, -2, 4,
	4, 2, -4, 2, 0, 5, 3, 4, -3, 4, 4, 3, -4, 3, 5, 0,
	1, 5, -1, 5, 5, 1, -5, 1, 2, 5, -2, 5, 5, 2, -5, 2,
	4, 4, -4, 4, 3, 5, -3, 5, 5, 3, -5, 3, 0, 6, 6, 0,
	1, 6, -1, 6, 6, 1, -6, 1, 2, 6, -2, 6, 6, 2, -6, 2,
	4, 5, -4, 5, 5, 4, -5, 4, 3, 6, -3, 6, 6, 3, -6, 3,
	0, 7, 7, 0, 1, 7, -1, 7, 5, 5, -5, 5, 7, 1, -7, 1,
	4, 6, -4, 6, 6, 4, -6, 4, 2, 7, -2, 7, 7, 2, -7, 2,
	3, 7, -3, 7, 7, 3, -7, 3, 5, 6, -5, 6, 6, 5, -6, 5,
	8, 0, 4, 7, -4, 7, 7, 4, -7, 4, 8, 1, 8, 2, 6, 6,
	-6, 6, 8, 3, 5, 7, -5, 7, 7, 5, -7, 5, 8, 4, 6, 7,
	-6, 7, 7, 6, -7, 6, 8, 5, 7, 7, -7, 7, 8, 6, 8, 7,
};
