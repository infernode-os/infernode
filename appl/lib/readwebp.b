implement RImagefile;

#
# WebP: the RIFF container (simple, extended, animated), lossless
# VP8L (RFC 9649), lossy VP8 key frames (RFC 6386) and the ALPH alpha
# chunk, decoded as libwebp decodes them, to the pixel: its tables,
# its edge rules for intra prediction, its loop filter order and its
# fancy upsampling and fixed-point YUV to RGB.  Checked against
# libwebp by tests/readwebp_test.b.
#
# References:
#	https://www.rfc-editor.org/rfc/rfc9649 (WebP: container, lossless)
#	https://www.rfc-editor.org/rfc/rfc6386 (VP8)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";

# packed pixel masks (ARGB in an int)
RB:	con 16r00FF00FF;
AG:	con ~RB;
BLACK:	con ~16r00FFFFFF;	# opaque black, 16rFF000000

init(iomod: Bufio)
{
	sys = load Sys Sys->PATH;
	bufio = iomod;
}

read(fd: ref Iobuf): (ref Rawimage, string)
{
	(a, err) := readarray(fd, 0);
	if(a == nil || len a == 0)
		return (nil, err);
	return (a[0], err);
}

readmulti(fd: ref Iobuf): (array of ref Rawimage, string)
{
	return readarray(fd, 1);
}

readarray(fd: ref Iobuf, multi: int): (array of ref Rawimage, string)
{
	data := readall(fd);
	{
		return (decodefile(data, multi), nil);
	} exception e {
	"webp:*" =>
		return (nil, "WebP: " + e[5:]);
	"*" =>
		return (nil, "WebP: " + e);
	}
}

fail(s: string)
{
	raise "webp:" + s;
}

# ---------------- the container ----------------

Frame: adt {
	x, y, w, h:	int;
	dispose:	int;	# the frame's area is cleared after it is shown
	noblend:	int;	# drawn over the canvas without alpha blending
	data:	array of byte;
};

decodefile(data: array of byte, multi: int): array of ref Rawimage
{
	if(data == nil || len data < 12 || string data[0:4] != "RIFF" || string data[8:12] != "WEBP")
		fail("not a WebP file");
	end := le32(data, 4) + 8;
	if(end < 12 || end > len data)
		end = len data;
	vp8, vp8l, alph: array of byte;
	cw := 0;
	ch := 0;
	frames: list of ref Frame;
	for(off := 12; off + 8 <= end; ) {
		id := string data[off:off+4];
		n := le32(data, off + 4);
		off += 8;
		if(n < 0 || off + n > end)
			n = end - off;
		body := data[off:off+n];
		case id {
		"VP8 " =>
			vp8 = body;
		"VP8L" =>
			vp8l = body;
		"ALPH" =>
			alph = body;
		"VP8X" =>
			if(n >= 10) {
				cw = 1 + le24(body, 4);
				ch = 1 + le24(body, 7);
			}
		"ANMF" =>
			if(n >= 16) {
				fl := int body[15];
				frames = ref Frame(2*le24(body, 0), 2*le24(body, 3), 1 + le24(body, 6), 1 + le24(body, 9),
					fl & 1, (fl >> 1) & 1, body[16:]) :: frames;
			}
		}
		off += n + (n & 1);
	}
	if(frames != nil)
		return animation(revframes(frames), cw, ch, multi);
	img: ref Rawimage;
	if(vp8l != nil)
		img = decodevp8l(vp8l);
	else if(vp8 != nil)
		img = decodevp8(vp8, alph);
	else
		fail("no image data");
	return array[1] of {img};
}

revframes(l: list of ref Frame): array of ref Frame
{
	n := 0;
	for(t := l; t != nil; t = tl t)
		n++;
	a := array[n] of ref Frame;
	for(; l != nil; l = tl l)
		a[--n] = hd l;
	return a;
}

# A frame's own chunks: ALPH, then VP8 or VP8L.
decodeframe(d: array of byte): ref Rawimage
{
	vp8, vp8l, alph: array of byte;
	for(off := 0; off + 8 <= len d; ) {
		id := string d[off:off+4];
		n := le32(d, off + 4);
		off += 8;
		if(n < 0 || off + n > len d)
			n = len d - off;
		body := d[off:off+n];
		case id {
		"VP8 " => vp8 = body;
		"VP8L" => vp8l = body;
		"ALPH" => alph = body;
		}
		off += n + (n & 1);
	}
	if(vp8l != nil)
		return decodevp8l(vp8l);
	if(vp8 != nil)
		return decodevp8(vp8, alph);
	fail("animation frame without image data");
	return nil;
}

# Frames drawn in turn on a canvas that starts transparent, as
# libwebp's animation decoder draws them (anim_decode.c): a key frame
# is drawn on a cleared canvas without blending; another is blended,
# non-premultiplied, over what the last frame left, except where that
# frame was disposed to the background.  Each result is a copy of the
# canvas; read() takes the first.
animation(fr: array of ref Frame, cw, ch, multi: int): array of ref Rawimage
{
	if(cw <= 0 || ch <= 0)
		fail("animation without a canvas");
	n := len fr;
	if(!multi)
		n = 1;
	out := array[n] of ref Rawimage;
	canvas := rgba(cw, ch);
	prevkey := 0;
	for(i := 0; i < n; i++) {
		f := fr[i];
		img := decodeframe(f.data);
		hasalpha := img.nchans == 4;
		key := 0;
		if(i == 0)
			key = 1;
		else if((!hasalpha || f.noblend) && f.x == 0 && f.y == 0 && f.w == cw && f.h == ch)
			key = 1;
		else if(fr[i-1].dispose && (fullframe(fr[i-1], cw, ch) || prevkey))
			key = 1;
		if(key)
			clearrect(canvas, ref Frame(0, 0, cw, ch, 0, 0, nil));
		prev: ref Frame;
		if(i > 0 && fr[i-1].dispose)
			prev = fr[i-1];
		drawframe(canvas, img, f, !key && !f.noblend, prev);
		out[i] = copyraw(canvas);
		if(f.dispose)
			clearrect(canvas, f);
		prevkey = key;
	}
	return out;
}

fullframe(f: ref Frame, cw, ch: int): int
{
	return f.w == cw && f.h == ch;
}

rgba(w, h: int): ref Rawimage
{
	raw := ref Rawimage;
	raw.r = ((0, 0), (w, h));
	raw.cmap = nil;
	raw.transp = 0;
	raw.trindex = byte 0;
	raw.nchans = 4;
	raw.chandesc = RImagefile->CRGBA;
	raw.chans = array[4] of array of byte;
	for(i := 0; i < 4; i++)
		raw.chans[i] = array[w*h] of {* => byte 0};
	raw.fields = 0;
	return raw;
}

copyraw(r: ref Rawimage): ref Rawimage
{
	c := ref *r;
	c.chans = array[len r.chans] of array of byte;
	for(i := 0; i < len r.chans; i++) {
		c.chans[i] = array[len r.chans[i]] of byte;
		c.chans[i][0:] = r.chans[i];
	}
	return c;
}

clearrect(c: ref Rawimage, f: ref Frame)
{
	cw := c.r.max.x;
	ch := c.r.max.y;
	for(y := f.y; y < f.y + f.h && y < ch; y++)
		for(x := f.x; x < f.x + f.w && x < cw; x++)
			for(k := 0; k < 4; k++)
				c.chans[k][y*cw + x] = byte 0;
}

# The frame over the canvas; blend, unless the pixel is opaque or in
# the rectangle the previous frame disposed of (prev).
drawframe(c: ref Rawimage, img: ref Rawimage, f: ref Frame, blend: int, prev: ref Frame)
{
	cw := c.r.max.x;
	ch := c.r.max.y;
	iw := img.r.max.x;
	ih := img.r.max.y;
	k: int;
	for(y := 0; y < ih && f.y + y < ch; y++)
		for(x := 0; x < iw && f.x + x < cw; x++) {
			s := y*iw + x;
			cx := f.x + x;
			cy := f.y + y;
			d := cy*cw + cx;
			sa := 255;
			if(img.nchans == 4)
				sa = int img.chans[3][s];
			if(!blend || sa == 255 || prev != nil && cx >= prev.x && cx < prev.x + prev.w && cy >= prev.y && cy < prev.y + prev.h) {
				for(k = 0; k < 3; k++)
					c.chans[k][d] = img.chans[k][s];
				c.chans[3][d] = byte sa;
				continue;
			}
			if(sa == 0)
				continue;
			da := int c.chans[3][d];
			dfa := (da * (256 - sa)) >> 8;
			ba := sa + dfa;
			scale := big ((1 << 24) / ba);
			for(k = 0; k < 3; k++)
				c.chans[k][d] = byte int (((big (int img.chans[k][s] * sa + int c.chans[k][d] * dfa)) * scale) >> 24);
			c.chans[3][d] = byte ba;
		}
}

# An image from packed ARGB: RGB, or RGBA when any pixel is not opaque.
fromargb(w, h: int, px: array of int): ref Rawimage
{
	n := w * h;
	opaque := 1;
	for(i := 0; i < n; i++)
		if(((px[i] >> 24) & 255) != 255) {
			opaque = 0;
			break;
		}
	raw := ref Rawimage;
	raw.r = ((0, 0), (w, h));
	raw.cmap = nil;
	raw.transp = 0;
	raw.trindex = byte 0;
	raw.fields = 0;
	if(opaque) {
		raw.nchans = 3;
		raw.chandesc = RImagefile->CRGB;
	} else {
		raw.nchans = 4;
		raw.chandesc = RImagefile->CRGBA;
	}
	raw.chans = array[raw.nchans] of array of byte;
	r := array[n] of byte;
	g := array[n] of byte;
	b := array[n] of byte;
	raw.chans[0] = r;
	raw.chans[1] = g;
	raw.chans[2] = b;
	for(i = 0; i < n; i++) {
		p := px[i];
		r[i] = byte (p >> 16);
		g[i] = byte (p >> 8);
		b[i] = byte p;
	}
	if(!opaque) {
		a := array[n] of byte;
		raw.chans[3] = a;
		for(i = 0; i < n; i++)
			a[i] = byte (px[i] >> 24);
	}
	return raw;
}

# ---------------- VP8L: lossless (RFC 9649) ----------------

# bits are read least significant first
BR: adt {
	d:	array of byte;
	pos:	int;	# the next byte to take
	acc:	int;	# bits not yet read, lowest first (at most 31)
	n:	int;	# how many
};

fill(b: ref BR)
{
	while(b.n <= 23) {
		if(b.pos < len b.d)
			b.acc |= int b.d[b.pos] << b.n;
		else if(b.pos > len b.d + 64)
			fail("lossless data truncated");
		b.pos++;
		b.n += 8;
	}
}

readbits(b: ref BR, k: int): int
{
	if(k == 0)
		return 0;
	if(b.n < k)
		fill(b);
	v := b.acc & ((1 << k) - 1);
	b.acc >>= k;
	b.n -= k;
	return v;
}

# A prefix code: an 8-bit table for the short codes, the canonical
# counts for the long ones.
HT: adt {
	single:	int;		# the only symbol, which takes no bits; -1 otherwise
	root:	array of int;	# length<<16 | symbol; -1 where a longer code starts
	counts:	array of int;	# codes of each length
	syms:	array of int;	# the symbols in code order
};

ROOTBITS: con 8;

mkht(lens: array of int, n: int): ref HT
{
	nz := 0;
	last := 0;
	for(i := 0; i < n; i++)
		if(lens[i] > 0) {
			nz++;
			last = i;
		}
	if(nz == 0)
		fail("empty prefix code");
	if(nz == 1)
		return ref HT(last, nil, nil, nil);
	counts := array[16] of {* => 0};
	for(i = 0; i < n; i++)
		if(lens[i] > 15)
			fail("prefix code too long");
		else if(lens[i] > 0)
			counts[lens[i]]++;
	offs := array[16] of {* => 0};
	for(l := 1; l < 15; l++)
		offs[l+1] = offs[l] + counts[l];
	syms := array[nz] of int;
	for(i = 0; i < n; i++)
		if(lens[i] > 0)
			syms[offs[lens[i]]++] = i;
	root := array[1 << ROOTBITS] of {* => -1};
	code := 0;
	k := 0;
	for(l = 1; l <= 15; l++) {
		for(j := 0; j < counts[l]; j++) {
			s := syms[k++];
			if(l <= ROOTBITS)
				for(e := bitrev(code, l); e < (1 << ROOTBITS); e += 1 << l)
					root[e] = (l << 16) | s;
			code++;
		}
		code <<= 1;
	}
	return ref HT(-1, root, counts, syms);
}

bitrev(v, n: int): int
{
	r := 0;
	for(i := 0; i < n; i++) {
		r = (r << 1) | (v & 1);
		v >>= 1;
	}
	return r;
}

getsym(b: ref BR, h: ref HT): int
{
	if(h.single >= 0)
		return h.single;
	if(b.n < 15)
		fill(b);
	e := h.root[b.acc & ((1 << ROOTBITS) - 1)];
	if(e >= 0) {
		l := e >> 16;
		b.acc >>= l;
		b.n -= l;
		return e & 16rFFFF;
	}
	# longer than the table: a bit at a time (as puff does)
	code := 0;
	first := 0;
	idx := 0;
	for(l := 1; l <= 15; l++) {
		code |= readbits(b, 1);
		c := h.counts[l];
		if(code - c < first)
			return h.syms[idx + code - first];
		idx += c;
		first += c;
		first <<= 1;
		code <<= 1;
	}
	fail("bad prefix code");
	return 0;
}

clorder := array[] of {17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

readcode(b: ref BR, alphabet: int): ref HT
{
	lens := array[alphabet] of {* => 0};
	if(readbits(b, 1)) {
		# simple: one or two symbols
		ns := readbits(b, 1) + 1;
		first8 := readbits(b, 1);
		s0 := readbits(b, 1 + 7*first8);
		if(s0 >= alphabet)
			fail("symbol out of range");
		lens[s0] = 1;
		if(ns == 2) {
			s1 := readbits(b, 8);
			if(s1 >= alphabet)
				fail("symbol out of range");
			lens[s1] = 1;
		}
		return mkht(lens, alphabet);
	}
	cl := array[19] of {* => 0};
	nc := readbits(b, 4) + 4;
	for(i := 0; i < nc; i++)
		cl[clorder[i]] = readbits(b, 3);
	clh := mkht(cl, 19);
	maxsym := alphabet;
	if(readbits(b, 1)) {
		lb := 2 + 2*readbits(b, 3);
		maxsym = 2 + readbits(b, lb);
		if(maxsym > alphabet)
			fail("too many code lengths");
	}
	sym := 0;
	prev := 8;
	while(sym < alphabet) {
		if(maxsym-- == 0)
			break;
		c := getsym(b, clh);
		if(c < 16) {
			lens[sym++] = c;
			if(c != 0)
				prev = c;
			continue;
		}
		extra := 2;
		rep := 3;
		val := prev;
		case c {
		17 =>
			extra = 3;
			val = 0;
		18 =>
			extra = 7;
			rep = 11;
			val = 0;
		}
		rep += readbits(b, extra);
		if(sym + rep > alphabet)
			fail("code lengths overrun");
		for(; rep > 0; rep--)
			lens[sym++] = val;
	}
	return mkht(lens, alphabet);
}

Xf: adt {
	kind:	int;	# 0 predictor, 1 colour, 2 subtract green, 3 colour indexing
	bits:	int;
	xs:	int;	# the image's width where this transform applies
	data:	array of int;
};

subsample(n, bits: int): int
{
	return (n + (1 << bits) - 1) >> bits;
}

decodevp8l(d: array of byte): ref Rawimage
{
	if(len d < 5 || int d[0] != 16r2F)
		fail("bad lossless signature");
	b := ref BR(d, 1, 0, 0);
	w := readbits(b, 14) + 1;
	h := readbits(b, 14) + 1;
	readbits(b, 1);		# alpha_is_used: a hint; the pixels say
	if(readbits(b, 3) != 0)
		fail("unknown lossless version");
	return fromargb(w, h, decodeimage(b, w, h, 1));
}

# An image stream; level0 is the image itself (with transforms and an
# entropy image), the rest are the transforms' and entropy images.
decodeimage(b: ref BR, w, h, level0: int): array of int
{
	xfs: list of ref Xf;
	xs := w;
	if(level0) {
		seen := 0;
		while(readbits(b, 1)) {
			t := readbits(b, 2);
			if(seen & (1 << t))
				fail("transform repeated");
			seen |= 1 << t;
			x := ref Xf(t, 0, xs, nil);
			case t {
			0 or 1 =>
				x.bits = readbits(b, 3) + 2;
				x.data = decodeimage(b, subsample(xs, x.bits), subsample(h, x.bits), 0);
			3 =>
				nc := readbits(b, 8) + 1;
				if(nc > 16)
					x.bits = 0;
				else if(nc > 4)
					x.bits = 1;
				else if(nc > 2)
					x.bits = 2;
				else
					x.bits = 3;
				pal := decodeimage(b, nc, 1, 0);
				x.data = array[256] of {* => 0};
				x.data[0] = pal[0];
				for(i := 1; i < nc; i++)
					x.data[i] = addpx(pal[i], x.data[i-1]);
				xs = subsample(xs, x.bits);
			}
			xfs = x :: xfs;
		}
	}
	cc := 0;
	if(readbits(b, 1)) {
		cc = readbits(b, 4);
		if(cc < 1 || cc > 11)
			fail("bad colour cache size");
	}
	meta: array of int;
	mbits := 0;
	mw := 0;
	ngroups := 1;
	if(level0 && readbits(b, 1)) {
		mbits = readbits(b, 3) + 2;
		mw = subsample(xs, mbits);
		mimg := decodeimage(b, mw, subsample(h, mbits), 0);
		meta = array[len mimg] of int;
		for(i := 0; i < len mimg; i++) {
			meta[i] = (mimg[i] >> 8) & 16rFFFF;
			if(meta[i] >= ngroups)
				ngroups = meta[i] + 1;
		}
	}
	cachesize := 0;
	if(cc > 0)
		cachesize = 1 << cc;
	groups := array[ngroups * 5] of ref HT;
	for(g := 0; g < ngroups; g++)
		for(j := 0; j < 5; j++) {
			alphabet := 256;
			if(j == 0)
				alphabet = 256 + 24 + cachesize;
			else if(j == 4)
				alphabet = 40;
			groups[g*5 + j] = readcode(b, alphabet);
		}
	px := decodepixels(b, xs, h, groups, meta, mbits, mw, cc);
	for(; xfs != nil; xfs = tl xfs)
		px = inverse(hd xfs, px, h);
	return px;
}

decodepixels(b: ref BR, w, h: int, groups: array of ref HT, meta: array of int, mbits, mw, cc: int): array of int
{
	n := w * h;
	px := array[n] of int;
	cache: array of int;
	cmask := 0;
	cshift := 0;
	if(cc > 0) {
		cache = array[1 << cc] of {* => 0};
		cmask = (1 << cc) - 1;
		cshift = 32 - cc;
	}
	pos := 0;
	x := 0;
	y := 0;
	g := 0;
	while(pos < n) {
		if(meta != nil)
			g = meta[(y >> mbits)*mw + (x >> mbits)] * 5;
		c := getsym(b, groups[g]);
		if(c < 256) {
			r := getsym(b, groups[g+1]);
			bl := getsym(b, groups[g+2]);
			a := getsym(b, groups[g+3]);
			p := (a << 24) | (r << 16) | (c << 8) | bl;
			px[pos++] = p;
			if(cache != nil)
				cache[((p * 16r1E35A7BD) >> cshift) & cmask] = p;
			if(++x >= w) {
				x = 0;
				y++;
			}
		} else if(c < 280) {
			ln := copylen(b, c - 256);
			dc := copylen(b, getsym(b, groups[g+4]));
			dist := planedist(w, dc);
			if(dist > pos || pos + ln > n)
				fail("bad back-reference");
			for(i := 0; i < ln; i++) {
				p := px[pos - dist];
				px[pos++] = p;
				if(cache != nil)
					cache[((p * 16r1E35A7BD) >> cshift) & cmask] = p;
			}
			x += ln;
			while(x >= w) {
				x -= w;
				y++;
			}
		} else {
			k := c - 280;
			if(cache == nil || k > cmask)
				fail("bad colour cache index");
			p := cache[k];
			px[pos++] = p;
			cache[((p * 16r1E35A7BD) >> cshift) & cmask] = p;
			if(++x >= w) {
				x = 0;
				y++;
			}
		}
	}
	return px;
}

copylen(b: ref BR, sym: int): int
{
	if(sym < 4)
		return sym + 1;
	eb := (sym - 2) >> 1;
	return ((2 + (sym & 1)) << eb) + readbits(b, eb) + 1;
}

planedist(w, c: int): int
{
	if(c > 120)
		return c - 120;
	dc := codetoplane[c - 1];
	d := (dc >> 4)*w + 8 - (dc & 16rF);
	if(d < 1)
		d = 1;
	return d;
}

addpx(a, b: int): int
{
	return (((a & AG) + (b & AG)) & AG) | (((a & RB) + (b & RB)) & RB);
}

avg2(a, b: int): int
{
	return (((a ^ b) >> 1) & 16r7F7F7F7F) + (a & b);
}

clip255(v: int): int
{
	if(v < 0)
		return 0;
	if(v > 255)
		return 255;
	return v;
}

select(t, l, c0: int): int
{
	s := 0;
	for(sh := 0; sh < 32; sh += 8) {
		a := (t >> sh) & 255;
		b := (l >> sh) & 255;
		c := (c0 >> sh) & 255;
		s += iabs(b - c) - iabs(a - c);
	}
	if(s <= 0)
		return t;
	return l;
}

clampfull(a, b, c: int): int
{
	r := 0;
	for(sh := 0; sh < 32; sh += 8)
		r |= clip255(((a >> sh) & 255) + ((b >> sh) & 255) - ((c >> sh) & 255)) << sh;
	return r;
}

clamphalf(a, b, c: int): int
{
	ave := avg2(a, b);
	r := 0;
	for(sh := 0; sh < 32; sh += 8) {
		x := (ave >> sh) & 255;
		r |= clip255(x + (x - ((c >> sh) & 255)) / 2) << sh;
	}
	return r;
}

iabs(v: int): int
{
	if(v < 0)
		return -v;
	return v;
}

sbyte(v: int): int
{
	v &= 255;
	if(v >= 128)
		return v - 256;
	return v;
}

inverse(x: ref Xf, px: array of int, h: int): array of int
{
	w := x.xs;
	i, y, tw: int;
	case x.kind {
	0 =>
		tw = subsample(w, x.bits);
		px[0] = addpx(px[0], BLACK);
		for(i = 1; i < w; i++)
			px[i] = addpx(px[i], px[i-1]);
		for(y = 1; y < h; y++) {
			row := y * w;
			px[row] = addpx(px[row], px[row - w]);
			trow := (y >> x.bits) * tw;
			for(i = 1; i < w; i++) {
				p := row + i;
				l := px[p-1];
				t := px[p-w];
				pred := 0;
				case (x.data[trow + (i >> x.bits)] >> 8) & 15 {
				1 => pred = l;
				2 => pred = t;
				3 => pred = px[p-w+1];		# (the rightmost pixel's is this row's first)
				4 => pred = px[p-w-1];
				5 => pred = avg2(avg2(l, px[p-w+1]), t);
				6 => pred = avg2(l, px[p-w-1]);
				7 => pred = avg2(l, t);
				8 => pred = avg2(px[p-w-1], t);
				9 => pred = avg2(t, px[p-w+1]);
				10 => pred = avg2(avg2(l, px[p-w-1]), avg2(t, px[p-w+1]));
				11 => pred = select(t, l, px[p-w-1]);
				12 => pred = clampfull(l, t, px[p-w-1]);
				13 => pred = clamphalf(l, t, px[p-w-1]);
				* => pred = BLACK;	# 0, and 14 and 15 as libwebp has them
				}
				px[p] = addpx(px[p], pred);
			}
		}
		return px;
	1 =>
		tw = subsample(w, x.bits);
		for(y = 0; y < h; y++) {
			trow := (y >> x.bits) * tw;
			for(i = 0; i < w; i++) {
				m := x.data[trow + (i >> x.bits)];
				p := px[y*w + i];
				g := sbyte(p >> 8);
				r := ((p >> 16) + ((sbyte(m) * g) >> 5)) & 255;
				bl := p + ((sbyte(m >> 8) * g) >> 5);
				bl = (bl + ((sbyte(m >> 16) * sbyte(r)) >> 5)) & 255;
				px[y*w + i] = (p & AG) | (r << 16) | bl;
			}
		}
		return px;
	2 =>
		for(i = 0; i < len px; i++) {
			p := px[i];
			g := (p >> 8) & 255;
			px[i] = (p & AG) | ((((p >> 16) + g) & 255) << 16) | ((p + g) & 255);
		}
		return px;
	3 =>
		iw := subsample(w, x.bits);
		out := array[w*h] of int;
		bpp := 8 >> x.bits;
		cmask := (1 << x.bits) - 1;
		vmask := (1 << bpp) - 1;
		for(y = 0; y < h; y++)
			for(i = 0; i < w; i++) {
				v := (px[y*iw + (i >> x.bits)] >> 8) & 255;
				if(x.bits > 0)
					v = (v >> ((i & cmask) * bpp)) & vmask;
				out[y*w + i] = x.data[v];
			}
		return out;
	}
	return px;
}

# ---------------- ALPH ----------------

decodealpha(a: array of byte, w, h: int): array of byte
{
	if(len a < 1)
		fail("empty alpha chunk");
	method := int a[0] & 3;
	filter := (int a[0] >> 2) & 3;
	n := w * h;
	raw := array[n] of byte;
	i: int;
	case method {
	0 =>
		if(len a < 1 + n)
			fail("alpha data truncated");
		raw[0:] = a[1:1+n];
	1 =>
		px := decodeimage(ref BR(a[1:], 0, 0, 0), w, h, 1);
		for(i = 0; i < n; i++)
			raw[i] = byte (px[i] >> 8);
	* =>
		fail("unknown alpha compression");
	}
	out := array[n] of byte;
	for(y := 0; y < h; y++) {
		o := y * w;
		f := filter;
		if(y == 0 && f != 0)
			f = 1;	# the first row of every filter is horizontal from 0
		case f {
		0 =>
			out[o:] = raw[o:o+w];
		1 =>
			pred := 0;
			if(y > 0)
				pred = int out[o - w];
			for(i = 0; i < w; i++) {
				pred = (pred + int raw[o+i]) & 255;
				out[o+i] = byte pred;
			}
		2 =>
			for(i = 0; i < w; i++)
				out[o+i] = byte (int out[o-w+i] + int raw[o+i]);
		3 =>
			top := int out[o-w];
			tlv := top;
			left := top;
			for(i = 0; i < w; i++) {
				top = int out[o-w+i];
				left = (int raw[o+i] + clip255(left + top - tlv)) & 255;
				tlv = top;
				out[o+i] = byte left;
			}
		}
	}
	return out;
}

# ---------------- VP8: lossy key frames (RFC 6386) ----------------

# the boolean decoder (RFC 6386 §7)
BD: adt {
	d:	array of byte;
	pos, end:	int;
	value:	int;	# a 16-bit window
	range:	int;
	bc:	int;	# bits shifted out of the window's low byte
};

bdinit(d: array of byte, off, end: int): ref BD
{
	b := ref BD(d, off, end, 0, 255, 0);
	for(i := 0; i < 2; i++) {
		b.value <<= 8;
		if(b.pos < b.end)
			b.value |= int d[b.pos];
		b.pos++;
	}
	return b;
}

getbit(b: ref BD, prob: int): int
{
	split := 1 + (((b.range - 1) * prob) >> 8);
	bs := split << 8;
	bit := 0;
	if(b.value >= bs) {
		bit = 1;
		b.range -= split;
		b.value -= bs;
	} else
		b.range = split;
	while(b.range < 128) {
		b.value <<= 1;
		b.range <<= 1;
		if(++b.bc == 8) {
			b.bc = 0;
			if(b.pos < b.end)
				b.value |= int b.d[b.pos];
			b.pos++;
		}
	}
	return bit;
}

getvalue(b: ref BD, n: int): int
{
	v := 0;
	while(n-- > 0)
		v |= getbit(b, 128) << n;
	return v;
}

getsigned(b: ref BD, n: int): int
{
	v := getvalue(b, n);
	if(getbit(b, 128))
		return -v;
	return v;
}

# the per-macroblock work buffer, as libwebp lays it out: a 32-byte
# stride, the luma block with its top row and left column, then the
# two chroma blocks side by side with theirs
BPS: con 32;
YOFF: con BPS + 8;
UOFF: con YOFF + BPS*16 + BPS;
VOFF: con UOFF + 16;
YUVSIZE: con BPS*17 + BPS*9;

# intra modes: 4x4 ones, of which the first four are also the 16x16
# and chroma modes; then the DC variants for missing edges
BDC, BTM, BVE, BHE, BRD, BVR, BLD, BVL, BHD, BHU: con iota;
DCNOTOP: con 4;
DCNOLEFT: con 5;
DCNOTOPLEFT: con 6;

V8: adt {
	w, h, mbw, mbh:	int;
	br:	ref BD;		# the first partition: modes
	parts:	array of ref BD;	# the token partitions
	proba:	array of int;	# coefficient probabilities [type][band][ctx][11]
	useskip, skipp:	int;
	useseg, segupdate, absdelta:	int;
	segq, segf, segprob:	array of int;
	ftype, flevel, fsharp, uselfdelta:	int;
	reflf, modelf:	array of int;
	dq:	array of int;	# per segment: y1 dc, y1 ac, y2 dc, y2 ac, uv dc, uv ac
	intrat:	array of int;	# 4x4 mode context along the top, 4 per macroblock
	intral:	array of int;	# and down the left
	tnz, tnzdc:	array of int;	# non-zero context along the top
	lnz, lnzdc:	int;		# and at the left
	yp, up, vp:	array of byte;	# the planes, whole macroblocks
	ys, uvs:	int;		# their strides
	topy, topu, topv:	array of byte;	# each macroblock's bottom row, before filtering
	b:	array of byte;		# the work buffer
	finfo:	array of int;	# per macroblock: limit, interior level, hev threshold, inner edges
	fstr:	array of int;	# per segment and 4x4-ness: the same, precomputed
	coeffs:	array of int;	# 384: 16 luma, 4 u, 4 v blocks of 16
	imodes:	array of int;
};

decodevp8(d: array of byte, alph: array of byte): ref Rawimage
{
	if(len d < 10)
		fail("lossy data too short");
	bits := int d[0] | (int d[1] << 8) | (int d[2] << 16);
	if(bits & 1)
		fail("not a key frame");
	if(((bits >> 4) & 1) == 0)
		fail("frame not shown");
	fps := bits >> 5;
	if(int d[3] != 16r9D || int d[4] != 16r01 || int d[5] != 16r2A)
		fail("bad lossy signature");
	w := (int d[6] | (int d[7] << 8)) & 16r3FFF;
	h := (int d[8] | (int d[9] << 8)) & 16r3FFF;
	if(w == 0 || h == 0)
		fail("empty frame");
	if(10 + fps > len d)
		fail("first partition truncated");
	v := ref V8;
	v.w = w;
	v.h = h;
	v.mbw = (w + 15) >> 4;
	v.mbh = (h + 15) >> 4;
	v.br = bdinit(d, 10, 10 + fps);
	header(v, d, 10 + fps);
	frame(v);
	if(v.ftype > 0)
		loopfilter(v);
	raw := torgb(v);
	if(alph != nil) {
		a := decodealpha(alph, w, h);
		raw.nchans = 4;
		raw.chandesc = RImagefile->CRGBA;
		c := array[4] of array of byte;
		c[0:] = raw.chans[0:3];
		c[3] = a;
		raw.chans = c;
	}
	return raw;
}

header(v: ref V8, d: array of byte, poff: int)
{
	br := v.br;
	s, i: int;
	getbit(br, 128);	# colour space
	getbit(br, 128);	# clamping (always done)

	# segments (§9.3)
	v.segq = array[4] of {* => 0};
	v.segf = array[4] of {* => 0};
	v.segprob = array[3] of {* => 255};
	v.useseg = getbit(br, 128);
	v.segupdate = 0;
	v.absdelta = 0;
	if(v.useseg) {
		v.segupdate = getbit(br, 128);
		if(getbit(br, 128)) {
			v.absdelta = getbit(br, 128);
			for(s = 0; s < 4; s++)
				if(getbit(br, 128))
					v.segq[s] = getsigned(br, 7);
			for(s = 0; s < 4; s++)
				if(getbit(br, 128))
					v.segf[s] = getsigned(br, 6);
		}
		if(v.segupdate)
			for(s = 0; s < 3; s++)
				if(getbit(br, 128))
					v.segprob[s] = getvalue(br, 8);
	}

	# the loop filter (§9.4)
	simple := getbit(br, 128);
	v.flevel = getvalue(br, 6);
	v.fsharp = getvalue(br, 3);
	v.reflf = array[4] of {* => 0};
	v.modelf = array[4] of {* => 0};
	v.uselfdelta = getbit(br, 128);
	if(v.uselfdelta && getbit(br, 128)) {
		for(i = 0; i < 4; i++)
			if(getbit(br, 128))
				v.reflf[i] = getsigned(br, 6);
		for(i = 0; i < 4; i++)
			if(getbit(br, 128))
				v.modelf[i] = getsigned(br, 6);
	}
	if(v.flevel == 0)
		v.ftype = 0;
	else if(simple)
		v.ftype = 1;
	else
		v.ftype = 2;

	# token partitions (§9.5)
	np := 1 << getvalue(br, 2);
	v.parts = array[np] of ref BD;
	sz := poff;
	start := poff + 3*(np - 1);
	if(start > len d)
		fail("partition sizes truncated");
	for(p := 0; p < np - 1; p++) {
		psize := int d[sz] | (int d[sz+1] << 8) | (int d[sz+2] << 16);
		if(start + psize > len d)
			psize = len d - start;
		v.parts[p] = bdinit(d, start, start + psize);
		start += psize;
		sz += 3;
	}
	v.parts[np-1] = bdinit(d, start, len d);

	# quantizers (§9.6)
	q0 := getvalue(br, 7);
	dqy1dc := 0;
	dqy2dc := 0;
	dqy2ac := 0;
	dquvdc := 0;
	dquvac := 0;
	if(getbit(br, 128)) dqy1dc = getsigned(br, 4);
	if(getbit(br, 128)) dqy2dc = getsigned(br, 4);
	if(getbit(br, 128)) dqy2ac = getsigned(br, 4);
	if(getbit(br, 128)) dquvdc = getsigned(br, 4);
	if(getbit(br, 128)) dquvac = getsigned(br, 4);
	v.dq = array[4*6] of int;
	for(s = 0; s < 4; s++) {
		q := q0;
		if(v.useseg) {
			q = v.segq[s];
			if(!v.absdelta)
				q += q0;
		}
		m := s * 6;
		v.dq[m] = dctab[clip(q + dqy1dc, 127)];
		v.dq[m+1] = actab[clip(q, 127)];
		v.dq[m+2] = dctab[clip(q + dqy2dc, 127)] * 2;
		v.dq[m+3] = (actab[clip(q + dqy2ac, 127)] * 101581) >> 16;
		if(v.dq[m+3] < 8)
			v.dq[m+3] = 8;
		v.dq[m+4] = dctab[clip(q + dquvdc, 117)];
		v.dq[m+5] = actab[clip(q + dquvac, 127)];
	}

	getbit(br, 128);	# refresh_entropy_probs: one frame, no matter

	# coefficient probabilities (§13.4)
	v.proba = array[len coeffsproba0] of int;
	for(i = 0; i < len coeffsproba0; i++) {
		if(getbit(br, coeffsupdateproba[i]))
			v.proba[i] = getvalue(br, 8);
		else
			v.proba[i] = coeffsproba0[i];
	}
	v.useskip = getbit(br, 128);
	v.skipp = 0;
	if(v.useskip)
		v.skipp = getvalue(br, 8);

	# the loop filter's strengths per segment and kind of macroblock
	v.fstr = array[4*2*4] of {* => 0};
	if(v.ftype > 0)
		for(s = 0; s < 4; s++) {
			base := v.flevel;
			if(v.useseg) {
				base = v.segf[s];
				if(!v.absdelta)
					base += v.flevel;
			}
			for(i4 := 0; i4 <= 1; i4++) {
				o := (s*2 + i4) * 4;
				level := base;
				if(v.uselfdelta) {
					level += v.reflf[0];
					if(i4)
						level += v.modelf[0];
				}
				level = clip(level, 63);
				if(level > 0) {
					il := level;
					if(v.fsharp > 0) {
						if(v.fsharp > 4)
							il >>= 2;
						else
							il >>= 1;
						if(il > 9 - v.fsharp)
							il = 9 - v.fsharp;
					}
					if(il < 1)
						il = 1;
					v.fstr[o] = 2*level + il;
					v.fstr[o+1] = il;
					if(level >= 40)
						v.fstr[o+2] = 2;
					else if(level >= 15)
						v.fstr[o+2] = 1;
				}
				v.fstr[o+3] = i4;
			}
		}
}

clip(v, m: int): int
{
	if(v < 0)
		return 0;
	if(v > m)
		return m;
	return v;
}

frame(v: ref V8)
{
	v.ys = v.mbw * 16;
	v.uvs = v.mbw * 8;
	v.yp = array[v.ys * v.mbh * 16] of byte;
	v.up = array[v.uvs * v.mbh * 8] of byte;
	v.vp = array[v.uvs * v.mbh * 8] of byte;
	v.topy = array[v.mbw * 16] of {* => byte 0};
	v.topu = array[v.mbw * 8] of {* => byte 0};
	v.topv = array[v.mbw * 8] of {* => byte 0};
	v.b = array[YUVSIZE] of {* => byte 0};
	v.intrat = array[v.mbw * 4] of {* => BDC};
	v.intral = array[4] of {* => BDC};
	v.tnz = array[v.mbw] of {* => 0};
	v.tnzdc = array[v.mbw] of {* => 0};
	v.finfo = array[v.mbw * v.mbh * 4] of {* => 0};
	v.coeffs = array[384] of int;
	v.imodes = array[16] of int;
	for(mby := 0; mby < v.mbh; mby++) {
		tok := v.parts[mby & (len v.parts - 1)];
		v.lnz = 0;
		v.lnzdc = 0;
		for(i := 0; i < 4; i++)
			v.intral[i] = BDC;
		for(mbx := 0; mbx < v.mbw; mbx++) {
			(seg, skip, i4, uvmode) := modes(v, mbx);
			for(i = 0; i < 384; i++)
				v.coeffs[i] = 0;
			allzero := 1;
			if(!skip)
				allzero = residuals(v, tok, mbx, seg, i4);
			else {
				v.lnz = 0;
				v.tnz[mbx] = 0;
				if(!i4) {
					v.lnzdc = 0;
					v.tnzdc[mbx] = 0;
				}
			}
			if(v.ftype > 0) {
				o := (mby*v.mbw + mbx) * 4;
				s := (seg*2 + i4) * 4;
				v.finfo[o:] = v.fstr[s:s+4];
				if(!allzero)
					v.finfo[o+3] = 1;
			}
			reconstruct(v, mbx, mby, i4, uvmode);
		}
	}
}

# a macroblock's segment, skip flag, 4x4-ness and modes (§11)
modes(v: ref V8, mbx: int): (int, int, int, int)
{
	br := v.br;
	seg := 0;
	if(v.segupdate) {
		if(!getbit(br, v.segprob[0]))
			seg = getbit(br, v.segprob[1]);
		else
			seg = getbit(br, v.segprob[2]) + 2;
	}
	skip := 0;
	if(v.useskip)
		skip = getbit(br, v.skipp);
	i4 := !getbit(br, 145);
	t := mbx * 4;
	if(!i4) {
		ymode: int;
		if(getbit(br, 156)) {
			if(getbit(br, 128))
				ymode = BTM;
			else
				ymode = BHE;
		} else {
			if(getbit(br, 163))
				ymode = BVE;
			else
				ymode = BDC;
		}
		v.imodes[0] = ymode;
		for(i := 0; i < 4; i++) {
			v.intrat[t+i] = ymode;
			v.intral[i] = ymode;
		}
	} else {
		for(y := 0; y < 4; y++) {
			ym := v.intral[y];
			for(x := 0; x < 4; x++) {
				p := (v.intrat[t+x]*10 + ym) * 9;
				if(!getbit(br, bmodesproba[p]))
					ym = BDC;
				else if(!getbit(br, bmodesproba[p+1]))
					ym = BTM;
				else if(!getbit(br, bmodesproba[p+2]))
					ym = BVE;
				else if(!getbit(br, bmodesproba[p+3])) {
					if(!getbit(br, bmodesproba[p+4]))
						ym = BHE;
					else if(!getbit(br, bmodesproba[p+5]))
						ym = BRD;
					else
						ym = BVR;
				} else {
					if(!getbit(br, bmodesproba[p+6]))
						ym = BLD;
					else if(!getbit(br, bmodesproba[p+7]))
						ym = BVL;
					else if(!getbit(br, bmodesproba[p+8]))
						ym = BHD;
					else
						ym = BHU;
				}
				v.intrat[t+x] = ym;
				v.imodes[y*4 + x] = ym;
			}
			v.intral[y] = ym;
		}
	}
	uvmode: int;
	if(!getbit(br, 142))
		uvmode = BDC;
	else if(!getbit(br, 114))
		uvmode = BVE;
	else if(getbit(br, 183))
		uvmode = BTM;
	else
		uvmode = BHE;
	return (seg, skip, i4, uvmode);
}

bands := array[] of {0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0};
zigzag := array[] of {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
cat3 := array[] of {173, 148, 140};
cat4 := array[] of {176, 155, 140, 135};
cat5 := array[] of {180, 157, 141, 134, 130};
cat6 := array[] of {254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129};

# where the probabilities for coefficient n of a block of type t, in context ctx, start
pidx(t, n, ctx: int): int
{
	return ((t*8 + bands[n])*3 + ctx) * 11;
}

largevalue(b: ref BD, pr: array of int, p: int): int
{
	if(!getbit(b, pr[p+3])) {
		if(!getbit(b, pr[p+4]))
			return 2;
		return 3 + getbit(b, pr[p+5]);
	}
	if(!getbit(b, pr[p+6])) {
		if(!getbit(b, pr[p+7]))
			return 5 + getbit(b, 159);
		v := 7 + 2*getbit(b, 165);
		return v + getbit(b, 145);
	}
	bit1 := getbit(b, pr[p+8]);
	bit0 := getbit(b, pr[p+9+bit1]);
	cat := 2*bit1 + bit0;
	tab: array of int;
	case cat {
	0 => tab = cat3;
	1 => tab = cat4;
	2 => tab = cat5;
	* => tab = cat6;
	}
	v := 0;
	for(i := 0; i < len tab; i++)
		v += v + getbit(b, tab[i]);
	return v + 3 + (8 << cat);
}

# One block's coefficients (§13), dequantized, into out at o; returns
# the position after the last non-zero one.
coeffs(b: ref BD, pr: array of int, t, ctx, dq0, dq1, n: int, out: array of int, o: int): int
{
	p := pidx(t, n, ctx);
	for(; n < 16; n++) {
		if(!getbit(b, pr[p]))
			return n;
		while(!getbit(b, pr[p+1])) {
			n++;
			if(n == 16)
				return 16;
			p = pidx(t, n, 0);
		}
		v: int;
		if(!getbit(b, pr[p+2])) {
			v = 1;
			p = pidx(t, n+1, 1);
		} else {
			v = largevalue(b, pr, p);
			p = pidx(t, n+1, 2);
		}
		if(getbit(b, 128))
			v = -v;
		dq := dq1;
		if(n == 0)
			dq = dq0;
		out[o + zigzag[n]] = v * dq;
	}
	return 16;
}

# A macroblock's residuals (§13); returns whether all were zero.
residuals(v: ref V8, tok: ref BD, mbx, seg, i4: int): int
{
	pr := v.proba;
	c := v.coeffs;
	q := seg * 6;
	nonzero := 0;
	first := 0;
	actype := 3;
	if(!i4) {
		dc := array[16] of {* => 0};
		ctx := v.tnzdc[mbx] + v.lnzdc;
		nz := coeffs(tok, pr, 1, ctx, v.dq[q+2], v.dq[q+3], 0, dc, 0);
		v.tnzdc[mbx] = v.lnzdc = nz > 0;
		if(nz > 1)
			wht(dc, c);
		else {
			dc0 := (dc[0] + 3) >> 3;
			for(i := 0; i < 256; i += 16)
				c[i] = dc0;
		}
		if(nz > 0)
			nonzero = 1;
		first = 1;
		actype = 0;
	}
	tnz := v.tnz[mbx] & 16r0F;
	lnz := v.lnz & 16r0F;
	for(y := 0; y < 4; y++) {
		l := lnz & 1;
		for(x := 0; x < 4; x++) {
			ctx := l + (tnz & 1);
			nz := coeffs(tok, pr, actype, ctx, v.dq[q], v.dq[q+1], first, c, (y*4 + x)*16);
			l = nz > first;
			if(nz > first)
				nonzero = 1;
			tnz = (tnz >> 1) | (l << 7);
		}
		tnz >>= 4;
		lnz = (lnz >> 1) | (l << 7);
	}
	otnz := tnz;
	olnz := lnz >> 4;
	for(ch := 0; ch < 4; ch += 2) {
		tnz = v.tnz[mbx] >> (4 + ch);
		lnz = v.lnz >> (4 + ch);
		for(y = 0; y < 2; y++) {
			l := lnz & 1;
			for(x := 0; x < 2; x++) {
				ctx := l + (tnz & 1);
				nz := coeffs(tok, pr, 2, ctx, v.dq[q+4], v.dq[q+5], 0, c, (16 + ch*2 + y*2 + x)*16);
				l = nz > 0;
				if(nz > 0)
					nonzero = 1;
				tnz = (tnz >> 1) | (l << 3);
			}
			tnz >>= 2;
			lnz = (lnz >> 1) | (l << 5);
		}
		otnz |= (tnz << 4) << ch;
		olnz |= (lnz & 16rF0) << ch;
	}
	v.tnz[mbx] = otnz;
	v.lnz = olnz;
	return !nonzero;
}

# the inverse Walsh-Hadamard transform of the luma DCs, into each block's [0]
wht(in: array of int, out: array of int)
{
	tmp := array[16] of int;
	for(i := 0; i < 4; i++) {
		a0 := in[0+i] + in[12+i];
		a1 := in[4+i] + in[8+i];
		a2 := in[4+i] - in[8+i];
		a3 := in[0+i] - in[12+i];
		tmp[0+i] = a0 + a1;
		tmp[8+i] = a0 - a1;
		tmp[4+i] = a3 + a2;
		tmp[12+i] = a3 - a2;
	}
	o := 0;
	for(i = 0; i < 4; i++) {
		dc := tmp[0 + i*4] + 3;
		a0 := dc + tmp[3 + i*4];
		a1 := tmp[1 + i*4] + tmp[2 + i*4];
		a2 := tmp[1 + i*4] - tmp[2 + i*4];
		a3 := dc - tmp[3 + i*4];
		out[o] = (a0 + a1) >> 3;
		out[o+16] = (a3 + a2) >> 3;
		out[o+32] = (a0 - a1) >> 3;
		out[o+48] = (a3 - a2) >> 3;
		o += 64;
	}
}

mul1(a: int): int
{
	return ((a * 20091) >> 16) + a;
}

mul2(a: int): int
{
	return (a * 35468) >> 16;
}

clip8(v: int): byte
{
	if(v < 0)
		return byte 0;
	if(v > 255)
		return byte 255;
	return byte v;
}

# the inverse DCT of the block at c[o], added to the 4x4 pixels at b[d]
idct(c: array of int, o: int, b: array of byte, d: int)
{
	nz := 0;
	for(i := 0; i < 16; i++)
		if(c[o+i] != 0) {
			nz = 1;
			break;
		}
	if(!nz)
		return;
	tmp := array[16] of int;
	t := 0;
	for(i = 0; i < 4; i++) {
		in := o + i;
		a := c[in] + c[in+8];
		bb := c[in] - c[in+8];
		cc := mul2(c[in+4]) - mul1(c[in+12]);
		dd := mul1(c[in+4]) + mul2(c[in+12]);
		tmp[t] = a + dd;
		tmp[t+1] = bb + cc;
		tmp[t+2] = bb - cc;
		tmp[t+3] = a - dd;
		t += 4;
	}
	for(i = 0; i < 4; i++) {
		dc := tmp[i] + 4;
		a := dc + tmp[i+8];
		bb := dc - tmp[i+8];
		cc := mul2(tmp[i+4]) - mul1(tmp[i+12]);
		dd := mul1(tmp[i+4]) + mul2(tmp[i+12]);
		p := d + i*BPS;
		b[p] = clip8(int b[p] + ((a + dd) >> 3));
		b[p+1] = clip8(int b[p+1] + ((bb + cc) >> 3));
		b[p+2] = clip8(int b[p+2] + ((bb - cc) >> 3));
		b[p+3] = clip8(int b[p+3] + ((a - dd) >> 3));
	}
}

checkmode(mbx, mby, mode: int): int
{
	if(mode == BDC) {
		if(mbx == 0) {
			if(mby == 0)
				return DCNOTOPLEFT;
			return DCNOLEFT;
		}
		if(mby == 0)
			return DCNOTOP;
	}
	return mode;
}

reconstruct(v: ref V8, mbx, mby, i4, uvmode: int)
{
	b := v.b;
	j, k, n: int;
	if(mbx == 0) {
		for(j = 0; j < 16; j++)
			b[YOFF + j*BPS - 1] = byte 129;
		for(j = 0; j < 8; j++) {
			b[UOFF + j*BPS - 1] = byte 129;
			b[VOFF + j*BPS - 1] = byte 129;
		}
		if(mby > 0) {
			b[YOFF - 1 - BPS] = byte 129;
			b[UOFF - 1 - BPS] = byte 129;
			b[VOFF - 1 - BPS] = byte 129;
		} else {
			for(j = 0; j < 16 + 4 + 1; j++)
				b[YOFF - BPS - 1 + j] = byte 127;
			for(j = 0; j < 8 + 1; j++) {
				b[UOFF - BPS - 1 + j] = byte 127;
				b[VOFF - BPS - 1 + j] = byte 127;
			}
		}
	} else {
		# the left samples are the previous macroblock's right columns
		for(j = -1; j < 16; j++)
			b[YOFF + j*BPS - 4:] = b[YOFF + j*BPS + 12:YOFF + j*BPS + 16];
		for(j = -1; j < 8; j++) {
			b[UOFF + j*BPS - 4:] = b[UOFF + j*BPS + 4:UOFF + j*BPS + 8];
			b[VOFF + j*BPS - 4:] = b[VOFF + j*BPS + 4:VOFF + j*BPS + 8];
		}
	}
	if(mby > 0) {
		b[YOFF - BPS:] = v.topy[mbx*16:mbx*16 + 16];
		b[UOFF - BPS:] = v.topu[mbx*8:mbx*8 + 8];
		b[VOFF - BPS:] = v.topv[mbx*8:mbx*8 + 8];
	}
	c := v.coeffs;
	if(i4) {
		tr := YOFF - BPS + 16;
		if(mby > 0) {
			if(mbx >= v.mbw - 1)
				for(j = 0; j < 4; j++)
					b[tr + j] = v.topy[mbx*16 + 15];
			else
				b[tr:] = v.topy[(mbx+1)*16:(mbx+1)*16 + 4];
		}
		# the blocks down the right take the same pixels above-right
		for(k = 1; k <= 3; k++)
			b[tr + 4*k*BPS:] = b[tr:tr+4];
		for(n = 0; n < 16; n++) {
			dst := YOFF + (n & 3)*4 + (n >> 2)*4*BPS;
			pred4(b, dst, v.imodes[n]);
			idct(c, n*16, b, dst);
		}
	} else {
		pred16(b, YOFF, checkmode(mbx, mby, v.imodes[0]));
		for(n = 0; n < 16; n++)
			idct(c, n*16, b, YOFF + (n & 3)*4 + (n >> 2)*4*BPS);
	}
	m := checkmode(mbx, mby, uvmode);
	pred8(b, UOFF, m);
	pred8(b, VOFF, m);
	for(k = 0; k < 4; k++) {
		off := (k & 1)*4 + (k >> 1)*4*BPS;
		idct(c, (16 + k)*16, b, UOFF + off);
		idct(c, (20 + k)*16, b, VOFF + off);
	}
	if(mby < v.mbh - 1) {
		v.topy[mbx*16:] = b[YOFF + 15*BPS:YOFF + 15*BPS + 16];
		v.topu[mbx*8:] = b[UOFF + 7*BPS:UOFF + 7*BPS + 8];
		v.topv[mbx*8:] = b[VOFF + 7*BPS:VOFF + 7*BPS + 8];
	}
	yo := mby*16*v.ys + mbx*16;
	for(j = 0; j < 16; j++)
		v.yp[yo + j*v.ys:] = b[YOFF + j*BPS:YOFF + j*BPS + 16];
	uo := mby*8*v.uvs + mbx*8;
	for(j = 0; j < 8; j++) {
		v.up[uo + j*v.uvs:] = b[UOFF + j*BPS:UOFF + j*BPS + 8];
		v.vp[uo + j*v.uvs:] = b[VOFF + j*BPS:VOFF + j*BPS + 8];
	}
}

fillblk(b: array of byte, d, size, val: int)
{
	for(y := 0; y < size; y++)
		for(x := 0; x < size; x++)
			b[d + y*BPS + x] = byte val;
}

truemotion(b: array of byte, d, size: int)
{
	tlv := int b[d - BPS - 1];
	for(y := 0; y < size; y++) {
		l := int b[d + y*BPS - 1] - tlv;
		for(x := 0; x < size; x++)
			b[d + y*BPS + x] = clip8(int b[d - BPS + x] + l);
	}
}

pred16(b: array of byte, d, mode: int)
{
	x, y, i, j, dc: int;
	case mode {
	BTM =>
		truemotion(b, d, 16);
	BVE =>
		for(y = 0; y < 16; y++)
			b[d + y*BPS:] = b[d - BPS:d - BPS + 16];
	BHE =>
		for(y = 0; y < 16; y++)
			for(x = 0; x < 16; x++)
				b[d + y*BPS + x] = b[d + y*BPS - 1];
	DCNOTOP =>
		dc = 8;
		for(j = 0; j < 16; j++)
			dc += int b[d - 1 + j*BPS];
		fillblk(b, d, 16, dc >> 4);
	DCNOLEFT =>
		dc = 8;
		for(i = 0; i < 16; i++)
			dc += int b[d + i - BPS];
		fillblk(b, d, 16, dc >> 4);
	DCNOTOPLEFT =>
		fillblk(b, d, 16, 16r80);
	* =>
		dc = 16;
		for(j = 0; j < 16; j++)
			dc += int b[d - 1 + j*BPS] + int b[d + j - BPS];
		fillblk(b, d, 16, dc >> 5);
	}
}

pred8(b: array of byte, d, mode: int)
{
	x, y, i, dc: int;
	case mode {
	BTM =>
		truemotion(b, d, 8);
	BVE =>
		for(y = 0; y < 8; y++)
			b[d + y*BPS:] = b[d - BPS:d - BPS + 8];
	BHE =>
		for(y = 0; y < 8; y++)
			for(x = 0; x < 8; x++)
				b[d + y*BPS + x] = b[d + y*BPS - 1];
	DCNOTOP =>
		dc = 4;
		for(i = 0; i < 8; i++)
			dc += int b[d - 1 + i*BPS];
		fillblk(b, d, 8, dc >> 3);
	DCNOLEFT =>
		dc = 4;
		for(i = 0; i < 8; i++)
			dc += int b[d + i - BPS];
		fillblk(b, d, 8, dc >> 3);
	DCNOTOPLEFT =>
		fillblk(b, d, 8, 16r80);
	* =>
		dc = 8;
		for(i = 0; i < 8; i++)
			dc += int b[d + i - BPS] + int b[d - 1 + i*BPS];
		fillblk(b, d, 8, dc >> 4);
	}
}

avg3(a, b, c: int): byte
{
	return byte ((a + 2*b + c + 2) >> 2);
}

avg2b(a, b: int): byte
{
	return byte ((a + b + 1) >> 1);
}

pred4(b: array of byte, d, mode: int)
{
	top := d - BPS;
	A := int b[top];
	B := int b[top+1];
	C := int b[top+2];
	D := int b[top+3];
	E := int b[top+4];
	F := int b[top+5];
	G := int b[top+6];
	H := int b[top+7];
	X := int b[top-1];
	I := int b[d - 1];
	J := int b[d - 1 + BPS];
	K := int b[d - 1 + 2*BPS];
	L := int b[d - 1 + 3*BPS];
	case mode {
	BDC =>
		dc := 4;
		for(i := 0; i < 4; i++)
			dc += int b[top + i] + int b[d - 1 + i*BPS];
		fillblk(b, d, 4, dc >> 3);
	BTM =>
		truemotion(b, d, 4);
	BVE =>
		r := array[4] of byte;
		r[0] = avg3(X, A, B);
		r[1] = avg3(A, B, C);
		r[2] = avg3(B, C, D);
		r[3] = avg3(C, D, E);
		for(y := 0; y < 4; y++)
			b[d + y*BPS:] = r;
	BHE =>
		v0 := avg3(X, I, J);
		v1 := avg3(I, J, K);
		v2 := avg3(J, K, L);
		v3 := avg3(K, L, L);
		for(x := 0; x < 4; x++) {
			b[d + x] = v0;
			b[d + BPS + x] = v1;
			b[d + 2*BPS + x] = v2;
			b[d + 3*BPS + x] = v3;
		}
	BRD =>
		put(b, d, 0, 3, avg3(J, K, L));
		put(b, d, 1, 3, put(b, d, 0, 2, avg3(I, J, K)));
		put(b, d, 2, 3, put(b, d, 1, 2, put(b, d, 0, 1, avg3(X, I, J))));
		put(b, d, 3, 3, put(b, d, 2, 2, put(b, d, 1, 1, put(b, d, 0, 0, avg3(A, X, I)))));
		put(b, d, 3, 2, put(b, d, 2, 1, put(b, d, 1, 0, avg3(B, A, X))));
		put(b, d, 3, 1, put(b, d, 2, 0, avg3(C, B, A)));
		put(b, d, 3, 0, avg3(D, C, B));
	BLD =>
		put(b, d, 0, 0, avg3(A, B, C));
		put(b, d, 1, 0, put(b, d, 0, 1, avg3(B, C, D)));
		put(b, d, 2, 0, put(b, d, 1, 1, put(b, d, 0, 2, avg3(C, D, E))));
		put(b, d, 3, 0, put(b, d, 2, 1, put(b, d, 1, 2, put(b, d, 0, 3, avg3(D, E, F)))));
		put(b, d, 3, 1, put(b, d, 2, 2, put(b, d, 1, 3, avg3(E, F, G))));
		put(b, d, 3, 2, put(b, d, 2, 3, avg3(F, G, H)));
		put(b, d, 3, 3, avg3(G, H, H));
	BVR =>
		put(b, d, 0, 0, put(b, d, 1, 2, avg2b(X, A)));
		put(b, d, 1, 0, put(b, d, 2, 2, avg2b(A, B)));
		put(b, d, 2, 0, put(b, d, 3, 2, avg2b(B, C)));
		put(b, d, 3, 0, avg2b(C, D));
		put(b, d, 0, 3, avg3(K, J, I));
		put(b, d, 0, 2, avg3(J, I, X));
		put(b, d, 0, 1, put(b, d, 1, 3, avg3(I, X, A)));
		put(b, d, 1, 1, put(b, d, 2, 3, avg3(X, A, B)));
		put(b, d, 2, 1, put(b, d, 3, 3, avg3(A, B, C)));
		put(b, d, 3, 1, avg3(B, C, D));
	BVL =>
		put(b, d, 0, 0, avg2b(A, B));
		put(b, d, 1, 0, put(b, d, 0, 2, avg2b(B, C)));
		put(b, d, 2, 0, put(b, d, 1, 2, avg2b(C, D)));
		put(b, d, 3, 0, put(b, d, 2, 2, avg2b(D, E)));
		put(b, d, 0, 1, avg3(A, B, C));
		put(b, d, 1, 1, put(b, d, 0, 3, avg3(B, C, D)));
		put(b, d, 2, 1, put(b, d, 1, 3, avg3(C, D, E)));
		put(b, d, 3, 1, put(b, d, 2, 3, avg3(D, E, F)));
		put(b, d, 3, 2, avg3(E, F, G));
		put(b, d, 3, 3, avg3(F, G, H));
	BHU =>
		put(b, d, 0, 0, avg2b(I, J));
		put(b, d, 2, 0, put(b, d, 0, 1, avg2b(J, K)));
		put(b, d, 2, 1, put(b, d, 0, 2, avg2b(K, L)));
		put(b, d, 1, 0, avg3(I, J, K));
		put(b, d, 3, 0, put(b, d, 1, 1, avg3(J, K, L)));
		put(b, d, 3, 1, put(b, d, 1, 2, avg3(K, L, L)));
		put(b, d, 3, 2, put(b, d, 2, 2, put(b, d, 0, 3, put(b, d, 1, 3, put(b, d, 2, 3, put(b, d, 3, 3, byte L))))));
	BHD =>
		put(b, d, 0, 0, put(b, d, 2, 1, avg2b(I, X)));
		put(b, d, 0, 1, put(b, d, 2, 2, avg2b(J, I)));
		put(b, d, 0, 2, put(b, d, 2, 3, avg2b(K, J)));
		put(b, d, 0, 3, avg2b(L, K));
		put(b, d, 3, 0, avg3(A, B, C));
		put(b, d, 2, 0, avg3(X, A, B));
		put(b, d, 1, 0, put(b, d, 3, 1, avg3(I, X, A)));
		put(b, d, 1, 1, put(b, d, 3, 2, avg3(J, I, X)));
		put(b, d, 1, 2, put(b, d, 3, 3, avg3(K, J, I)));
		put(b, d, 1, 3, avg3(L, K, J));
	}
}

put(b: array of byte, d, x, y: int, v: byte): byte
{
	b[d + x + y*BPS] = v;
	return v;
}

# ---- the loop filter (§15), whole frame, macroblocks in order ----

sclip1(v: int): int
{
	if(v < -128)
		return -128;
	if(v > 127)
		return 127;
	return v;
}

sclip2(v: int): int
{
	if(v < -16)
		return -16;
	if(v > 15)
		return 15;
	return v;
}

clip1(v: int): byte
{
	if(v < 0)
		return byte 0;
	if(v > 255)
		return byte 255;
	return byte v;
}

needsfilter(a: array of byte, p, step, t: int): int
{
	p1 := int a[p - 2*step];
	p0 := int a[p - step];
	q0 := int a[p];
	q1 := int a[p + step];
	return 4*iabs(p0 - q0) + iabs(p1 - q1) <= t;
}

needsfilter2(a: array of byte, p, step, t, it: int): int
{
	p3 := int a[p - 4*step];
	p2 := int a[p - 3*step];
	p1 := int a[p - 2*step];
	p0 := int a[p - step];
	q0 := int a[p];
	q1 := int a[p + step];
	q2 := int a[p + 2*step];
	q3 := int a[p + 3*step];
	if(4*iabs(p0 - q0) + iabs(p1 - q1) > t)
		return 0;
	return iabs(p3 - p2) <= it && iabs(p2 - p1) <= it && iabs(p1 - p0) <= it &&
		iabs(q3 - q2) <= it && iabs(q2 - q1) <= it && iabs(q1 - q0) <= it;
}

hev(a: array of byte, p, step, t: int): int
{
	p1 := int a[p - 2*step];
	p0 := int a[p - step];
	q0 := int a[p];
	q1 := int a[p + step];
	return iabs(p1 - p0) > t || iabs(q1 - q0) > t;
}

dofilter2(a: array of byte, p, step: int)
{
	p1 := int a[p - 2*step];
	p0 := int a[p - step];
	q0 := int a[p];
	q1 := int a[p + step];
	x := 3*(q0 - p0) + sclip1(p1 - q1);
	a1 := sclip2((x + 4) >> 3);
	a2 := sclip2((x + 3) >> 3);
	a[p - step] = clip1(p0 + a2);
	a[p] = clip1(q0 - a1);
}

dofilter4(a: array of byte, p, step: int)
{
	p1 := int a[p - 2*step];
	p0 := int a[p - step];
	q0 := int a[p];
	q1 := int a[p + step];
	x := 3*(q0 - p0);
	a1 := sclip2((x + 4) >> 3);
	a2 := sclip2((x + 3) >> 3);
	a3 := (a1 + 1) >> 1;
	a[p - 2*step] = clip1(p1 + a3);
	a[p - step] = clip1(p0 + a2);
	a[p] = clip1(q0 - a1);
	a[p + step] = clip1(q1 - a3);
}

dofilter6(a: array of byte, p, step: int)
{
	p2 := int a[p - 3*step];
	p1 := int a[p - 2*step];
	p0 := int a[p - step];
	q0 := int a[p];
	q1 := int a[p + step];
	q2 := int a[p + 2*step];
	x := sclip1(3*(q0 - p0) + sclip1(p1 - q1));
	a1 := (27*x + 63) >> 7;
	a2 := (18*x + 63) >> 7;
	a3 := (9*x + 63) >> 7;
	a[p - 3*step] = clip1(p2 + a3);
	a[p - 2*step] = clip1(p1 + a2);
	a[p - step] = clip1(p0 + a1);
	a[p] = clip1(q0 - a1);
	a[p + step] = clip1(q1 - a2);
	a[p + 2*step] = clip1(q2 - a3);
}

simplefilter(a: array of byte, p, hstride, vstride, thresh: int)
{
	t2 := 2*thresh + 1;
	for(i := 0; i < 16; i++) {
		q := p + i*vstride;
		if(needsfilter(a, q, hstride, t2))
			dofilter2(a, q, hstride);
	}
}

# FilterLoop26 (edges: six taps) and FilterLoop24 (inner: four)
filterloop(a: array of byte, p, hstride, vstride, size, thresh, ithresh, hevt, six: int)
{
	t2 := 2*thresh + 1;
	for(; size > 0; size--) {
		if(needsfilter2(a, p, hstride, t2, ithresh)) {
			if(hev(a, p, hstride, hevt))
				dofilter2(a, p, hstride);
			else if(six)
				dofilter6(a, p, hstride);
			else
				dofilter4(a, p, hstride);
		}
		p += vstride;
	}
}

loopfilter(v: ref V8)
{
	ys := v.ys;
	uvs := v.uvs;
	k: int;
	for(mby := 0; mby < v.mbh; mby++)
		for(mbx := 0; mbx < v.mbw; mbx++) {
			o := (mby*v.mbw + mbx) * 4;
			limit := v.finfo[o];
			if(limit == 0)
				continue;
			il := v.finfo[o+1];
			hevt := v.finfo[o+2];
			inner := v.finfo[o+3];
			y := mby*16*ys + mbx*16;
			if(v.ftype == 1) {
				if(mbx > 0)
					simplefilter(v.yp, y, 1, ys, limit + 4);
				if(inner)
					for(k = 1; k <= 3; k++)
						simplefilter(v.yp, y + 4*k, 1, ys, limit);
				if(mby > 0)
					simplefilter(v.yp, y, ys, 1, limit + 4);
				if(inner)
					for(k = 1; k <= 3; k++)
						simplefilter(v.yp, y + 4*k*ys, ys, 1, limit);
				continue;
			}
			u := mby*8*uvs + mbx*8;
			if(mbx > 0) {
				filterloop(v.yp, y, 1, ys, 16, limit + 4, il, hevt, 1);
				filterloop(v.up, u, 1, uvs, 8, limit + 4, il, hevt, 1);
				filterloop(v.vp, u, 1, uvs, 8, limit + 4, il, hevt, 1);
			}
			if(inner) {
				for(k = 1; k <= 3; k++)
					filterloop(v.yp, y + 4*k, 1, ys, 16, limit, il, hevt, 0);
				filterloop(v.up, u + 4, 1, uvs, 8, limit, il, hevt, 0);
				filterloop(v.vp, u + 4, 1, uvs, 8, limit, il, hevt, 0);
			}
			if(mby > 0) {
				filterloop(v.yp, y, ys, 1, 16, limit + 4, il, hevt, 1);
				filterloop(v.up, u, uvs, 1, 8, limit + 4, il, hevt, 1);
				filterloop(v.vp, u, uvs, 1, 8, limit + 4, il, hevt, 1);
			}
			if(inner) {
				for(k = 1; k <= 3; k++)
					filterloop(v.yp, y + 4*k*ys, ys, 1, 16, limit, il, hevt, 0);
				filterloop(v.up, u + 4*uvs, uvs, 1, 8, limit, il, hevt, 0);
				filterloop(v.vp, u + 4*uvs, uvs, 1, 8, limit, il, hevt, 0);
			}
		}
}

# ---- YUV to RGB: libwebp's fancy upsampling and fixed-point BT.601 ----

mulhi(v, c: int): int
{
	return (v * c) >> 8;
}

yclip8(v: int): byte
{
	if((v & ~16383) == 0)
		return byte (v >> 6);
	if(v < 0)
		return byte 0;
	return byte 255;
}

Out: adt {
	r, g, b:	array of byte;
};

emit(o: ref Out, i, y, u, v: int)
{
	yy := mulhi(y, 19077);
	o.r[i] = yclip8(yy + mulhi(v, 26149) - 14234);
	o.g[i] = yclip8(yy - mulhi(u, 6419) - mulhi(v, 13320) + 8708);
	o.b[i] = yclip8(yy + mulhi(u, 33050) - 17685);
}

# a pair of output rows (bottom < 0: the top alone), between chroma
# rows tu (above) and cu
upsample(v: ref V8, o: ref Out, top, bottom, tu, cu: int)
{
	w := v.w;
	yp := v.yp;
	ys := v.ys;
	up := v.up;
	vp := v.vp;
	uvs := v.uvs;
	ty := top * ys;
	by := bottom * ys;
	tpo := top * w;
	bo := bottom * w;
	tuo := tu * uvs;
	cuo := cu * uvs;
	last := (w - 1) >> 1;
	tlu := int up[tuo];
	tlv := int vp[tuo];
	lu := int up[cuo];
	lv := int vp[cuo];
	emit(o, tpo, int yp[ty], (3*tlu + lu + 2) >> 2, (3*tlv + lv + 2) >> 2);
	if(bottom >= 0)
		emit(o, bo, int yp[by], (3*lu + tlu + 2) >> 2, (3*lv + tlv + 2) >> 2);
	for(x := 1; x <= last; x++) {
		tu1 := int up[tuo + x];
		tv1 := int vp[tuo + x];
		cu1 := int up[cuo + x];
		cv1 := int vp[cuo + x];
		au := tlu + tu1 + lu + cu1 + 8;
		av := tlv + tv1 + lv + cv1 + 8;
		d12u := (au + 2*(tu1 + lu)) >> 3;
		d12v := (av + 2*(tv1 + lv)) >> 3;
		d03u := (au + 2*(tlu + cu1)) >> 3;
		d03v := (av + 2*(tlv + cv1)) >> 3;
		emit(o, tpo + 2*x - 1, int yp[ty + 2*x - 1], (d12u + tlu) >> 1, (d12v + tlv) >> 1);
		emit(o, tpo + 2*x, int yp[ty + 2*x], (d03u + tu1) >> 1, (d03v + tv1) >> 1);
		if(bottom >= 0) {
			emit(o, bo + 2*x - 1, int yp[by + 2*x - 1], (d03u + lu) >> 1, (d03v + lv) >> 1);
			emit(o, bo + 2*x, int yp[by + 2*x], (d12u + cu1) >> 1, (d12v + cv1) >> 1);
		}
		tlu = tu1;
		tlv = tv1;
		lu = cu1;
		lv = cv1;
	}
	if((w & 1) == 0) {
		emit(o, tpo + w - 1, int yp[ty + w - 1], (3*tlu + lu + 2) >> 2, (3*tlv + lv + 2) >> 2);
		if(bottom >= 0)
			emit(o, bo + w - 1, int yp[by + w - 1], (3*lu + tlu + 2) >> 2, (3*lv + tlv + 2) >> 2);
	}
}

torgb(v: ref V8): ref Rawimage
{
	n := v.w * v.h;
	o := ref Out(array[n] of byte, array[n] of byte, array[n] of byte);
	upsample(v, o, 0, -1, 0, 0);
	y := 0;
	for(; y + 2 < v.h; y += 2)
		upsample(v, o, y + 1, y + 2, y/2, y/2 + 1);
	if((v.h & 1) == 0)
		upsample(v, o, v.h - 1, -1, y/2, y/2);
	raw := ref Rawimage;
	raw.r = ((0, 0), (v.w, v.h));
	raw.cmap = nil;
	raw.transp = 0;
	raw.trindex = byte 0;
	raw.nchans = 3;
	raw.chandesc = RImagefile->CRGB;
	raw.chans = array[] of {o.r, o.g, o.b};
	raw.fields = 0;
	return raw;
}

# ---------------- utilities ----------------

readall(fd: ref Iobuf): array of byte
{
	data := array[65536] of byte;
	n := 0;
	for(;;) {
		if(n == len data) {
			nd := array[2 * len data] of byte;
			nd[0:] = data;
			data = nd;
		}
		r := fd.read(data[n:], len data - n);
		if(r <= 0)
			break;
		n += r;
	}
	if(n == 0)
		return nil;
	return data[0:n];
}

le32(d: array of byte, o: int): int
{
	return int d[o] | (int d[o+1] << 8) | (int d[o+2] << 16) | (int d[o+3] << 24);
}

le24(d: array of byte, o: int): int
{
	return int d[o] | (int d[o+1] << 8) | (int d[o+2] << 16);
}

# ---------------- tables, from libwebp ----------------

dctab := array[] of {
	4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17,
	18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28,
	29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43,
	44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
	59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
	75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
	91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
	122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
};

actab := array[] of {
	4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
	20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
	36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
	52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76,
	78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108,
	110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
	155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
	213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
};

coeffsproba0 := array[] of {
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128, 189, 129, 242, 255,
	227, 213, 255, 219, 128, 128, 128, 106, 126, 227, 252, 214, 209, 255, 255, 128,
	128, 128, 1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128, 181, 133, 238,
	254, 221, 234, 255, 154, 128, 128, 128, 78, 134, 202, 247, 198, 180, 255, 219,
	128, 128, 128, 1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128, 184, 150,
	247, 255, 236, 224, 128, 128, 128, 128, 128, 77, 110, 216, 255, 236, 230, 128,
	128, 128, 128, 128, 1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128, 170,
	139, 241, 252, 236, 209, 255, 255, 128, 128, 128, 37, 116, 196, 243, 228, 255,
	255, 255, 128, 128, 128, 1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128,
	207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128, 102, 103, 231, 255, 211,
	171, 128, 128, 128, 128, 128, 1, 152, 252, 255, 240, 255, 128, 128, 128, 128,
	128, 177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128, 80, 129, 211, 255,
	194, 224, 128, 128, 128, 128, 128, 1, 1, 255, 128, 128, 128, 128, 128, 128,
	128, 128, 246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 255, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 198, 35, 237, 223, 193, 187, 162, 160,
	145, 155, 62, 131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1, 68, 47,
	146, 208, 149, 167, 221, 162, 255, 223, 128, 1, 149, 241, 255, 221, 224, 255,
	255, 128, 128, 128, 184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128, 81,
	99, 181, 242, 176, 190, 249, 202, 255, 255, 128, 1, 129, 232, 253, 214, 197,
	242, 196, 255, 255, 128, 99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128,
	23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128, 1, 200, 246, 255, 234,
	255, 128, 128, 128, 128, 128, 109, 178, 241, 255, 231, 245, 255, 255, 128, 128,
	128, 44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128, 1, 132, 239, 251,
	219, 209, 255, 165, 128, 128, 128, 94, 136, 225, 251, 218, 190, 255, 255, 128,
	128, 128, 22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128, 1, 182, 249,
	255, 232, 235, 128, 128, 128, 128, 128, 124, 143, 241, 255, 227, 234, 128, 128,
	128, 128, 128, 35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128, 1, 157,
	247, 255, 236, 231, 255, 255, 128, 128, 128, 121, 141, 235, 255, 225, 227, 255,
	255, 128, 128, 128, 45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128, 1,
	1, 251, 255, 213, 255, 128, 128, 128, 128, 128, 203, 1, 248, 255, 255, 128,
	128, 128, 128, 128, 128, 137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
	253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128, 175, 13, 224, 243, 193,
	185, 249, 198, 255, 255, 128, 73, 17, 171, 221, 161, 179, 236, 167, 255, 234,
	128, 1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128, 239, 90, 244, 250,
	211, 209, 255, 255, 128, 128, 128, 155, 77, 195, 248, 188, 195, 255, 255, 128,
	128, 128, 1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128, 201, 51, 219,
	255, 196, 186, 128, 128, 128, 128, 128, 69, 46, 190, 239, 201, 218, 255, 228,
	128, 128, 128, 1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128, 223, 165,
	249, 255, 213, 255, 128, 128, 128, 128, 128, 141, 124, 248, 255, 255, 128, 128,
	128, 128, 128, 128, 1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128, 190,
	36, 230, 255, 236, 255, 128, 128, 128, 128, 128, 149, 1, 255, 128, 128, 128,
	128, 128, 128, 128, 128, 1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128, 240, 128, 255, 128, 128,
	128, 128, 128, 128, 128, 128, 1, 134, 252, 255, 255, 128, 128, 128, 128, 128,
	128, 213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128, 55, 93, 255, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 202, 24, 213, 235, 186, 191, 220, 160,
	240, 175, 255, 126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128, 61, 46,
	138, 219, 151, 178, 240, 170, 255, 216, 128, 1, 112, 230, 250, 199, 191, 247,
	159, 255, 255, 128, 166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128, 39,
	77, 162, 232, 172, 180, 245, 178, 255, 255, 128, 1, 52, 220, 246, 198, 199,
	249, 220, 255, 255, 128, 124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128,
	24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128, 1, 182, 225, 249, 219,
	240, 255, 224, 128, 128, 128, 149, 150, 226, 252, 216, 205, 255, 171, 128, 128,
	128, 28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128, 1, 81, 230, 252,
	204, 203, 255, 192, 128, 128, 128, 123, 102, 209, 247, 188, 196, 255, 233, 128,
	128, 128, 20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128, 1, 222, 248,
	255, 216, 213, 128, 128, 128, 128, 128, 168, 175, 246, 252, 235, 205, 255, 255,
	128, 128, 128, 47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128, 1, 121,
	236, 253, 212, 214, 255, 255, 128, 128, 128, 141, 84, 213, 252, 201, 202, 255,
	219, 128, 128, 128, 42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128, 1,
	1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 244, 1, 255, 128, 128, 128,
	128, 128, 128, 128, 128, 238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
};

coeffsupdateproba := array[] of {
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255, 223, 241, 252, 255,
	255, 255, 255, 255, 255, 255, 255, 249, 253, 253, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255, 234, 254, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255, 239, 253,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 254, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251,
	255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 254, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 254, 253, 255, 254, 255, 255, 255, 255, 255,
	255, 250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 217, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255, 234, 250,
	241, 250, 253, 255, 253, 254, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 238,
	253, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 248, 254, 255, 255, 255,
	255, 255, 255, 255, 255, 249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 247, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 254, 255,
	255, 255, 255, 255, 255, 255, 255, 252, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254,
	253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255, 234, 251, 244, 254, 255,
	255, 255, 255, 255, 255, 255, 251, 251, 243, 253, 254, 255, 254, 255, 255, 255,
	255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 236, 253, 254, 255,
	255, 255, 255, 255, 255, 255, 255, 251, 253, 253, 254, 254, 255, 255, 255, 255,
	255, 255, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 248, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255, 248, 254,
	249, 253, 255, 255, 255, 255, 255, 255, 255, 255, 253, 253, 255, 255, 255, 255,
	255, 255, 255, 255, 246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255, 252,
	254, 251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 254, 252, 255, 255, 255,
	255, 255, 255, 255, 255, 248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251, 254, 255, 255,
	255, 255, 255, 255, 255, 255, 245, 251, 254, 255, 255, 255, 255, 255, 255, 255,
	255, 253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 251, 253, 255,
	255, 255, 255, 255, 255, 255, 255, 252, 253, 254, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 252, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 249, 255, 254, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
};

bmodesproba := array[] of {
	231, 120, 48, 89, 115, 113, 120, 152, 112, 152, 179, 64, 126, 170, 118, 46,
	70, 95, 175, 69, 143, 80, 85, 82, 72, 155, 103, 56, 58, 10, 171, 218,
	189, 17, 13, 152, 114, 26, 17, 163, 44, 195, 21, 10, 173, 121, 24, 80,
	195, 26, 62, 44, 64, 85, 144, 71, 10, 38, 171, 213, 144, 34, 26, 170,
	46, 55, 19, 136, 160, 33, 206, 71, 63, 20, 8, 114, 114, 208, 12, 9,
	226, 81, 40, 11, 96, 182, 84, 29, 16, 36, 134, 183, 89, 137, 98, 101,
	106, 165, 148, 72, 187, 100, 130, 157, 111, 32, 75, 80, 66, 102, 167, 99,
	74, 62, 40, 234, 128, 41, 53, 9, 178, 241, 141, 26, 8, 107, 74, 43,
	26, 146, 73, 166, 49, 23, 157, 65, 38, 105, 160, 51, 52, 31, 115, 128,
	104, 79, 12, 27, 217, 255, 87, 17, 7, 87, 68, 71, 44, 114, 51, 15,
	186, 23, 47, 41, 14, 110, 182, 183, 21, 17, 194, 66, 45, 25, 102, 197,
	189, 23, 18, 22, 88, 88, 147, 150, 42, 46, 45, 196, 205, 43, 97, 183,
	117, 85, 38, 35, 179, 61, 39, 53, 200, 87, 26, 21, 43, 232, 171, 56,
	34, 51, 104, 114, 102, 29, 93, 77, 39, 28, 85, 171, 58, 165, 90, 98,
	64, 34, 22, 116, 206, 23, 34, 43, 166, 73, 107, 54, 32, 26, 51, 1,
	81, 43, 31, 68, 25, 106, 22, 64, 171, 36, 225, 114, 34, 19, 21, 102,
	132, 188, 16, 76, 124, 62, 18, 78, 95, 85, 57, 50, 48, 51, 193, 101,
	35, 159, 215, 111, 89, 46, 111, 60, 148, 31, 172, 219, 228, 21, 18, 111,
	112, 113, 77, 85, 179, 255, 38, 120, 114, 40, 42, 1, 196, 245, 209, 10,
	25, 109, 88, 43, 29, 140, 166, 213, 37, 43, 154, 61, 63, 30, 155, 67,
	45, 68, 1, 209, 100, 80, 8, 43, 154, 1, 51, 26, 71, 142, 78, 78,
	16, 255, 128, 34, 197, 171, 41, 40, 5, 102, 211, 183, 4, 1, 221, 51,
	50, 17, 168, 209, 192, 23, 25, 82, 138, 31, 36, 171, 27, 166, 38, 44,
	229, 67, 87, 58, 169, 82, 115, 26, 59, 179, 63, 59, 90, 180, 59, 166,
	93, 73, 154, 40, 40, 21, 116, 143, 209, 34, 39, 175, 47, 15, 16, 183,
	34, 223, 49, 45, 183, 46, 17, 33, 183, 6, 98, 15, 32, 183, 57, 46,
	22, 24, 128, 1, 54, 17, 37, 65, 32, 73, 115, 28, 128, 23, 128, 205,
	40, 3, 9, 115, 51, 192, 18, 6, 223, 87, 37, 9, 115, 59, 77, 64,
	21, 47, 104, 55, 44, 218, 9, 54, 53, 130, 226, 64, 90, 70, 205, 40,
	41, 23, 26, 57, 54, 57, 112, 184, 5, 41, 38, 166, 213, 30, 34, 26,
	133, 152, 116, 10, 32, 134, 39, 19, 53, 221, 26, 114, 32, 73, 255, 31,
	9, 65, 234, 2, 15, 1, 118, 73, 75, 32, 12, 51, 192, 255, 160, 43,
	51, 88, 31, 35, 67, 102, 85, 55, 186, 85, 56, 21, 23, 111, 59, 205,
	45, 37, 192, 55, 38, 70, 124, 73, 102, 1, 34, 98, 125, 98, 42, 88,
	104, 85, 117, 175, 82, 95, 84, 53, 89, 128, 100, 113, 101, 45, 75, 79,
	123, 47, 51, 128, 81, 171, 1, 57, 17, 5, 71, 102, 57, 53, 41, 49,
	38, 33, 13, 121, 57, 73, 26, 1, 85, 41, 10, 67, 138, 77, 110, 90,
	47, 114, 115, 21, 2, 10, 102, 255, 166, 23, 6, 101, 29, 16, 10, 85,
	128, 101, 196, 26, 57, 18, 10, 102, 102, 213, 34, 20, 43, 117, 20, 15,
	36, 163, 128, 68, 1, 26, 102, 61, 71, 37, 34, 53, 31, 243, 192, 69,
	60, 71, 38, 73, 119, 28, 222, 37, 68, 45, 128, 34, 1, 47, 11, 245,
	171, 62, 17, 19, 70, 146, 85, 55, 62, 70, 37, 43, 37, 154, 100, 163,
	85, 160, 1, 63, 9, 92, 136, 28, 64, 32, 201, 85, 75, 15, 9, 9,
	64, 255, 184, 119, 16, 86, 6, 28, 5, 64, 255, 25, 248, 1, 56, 8,
	17, 132, 137, 255, 55, 116, 128, 58, 15, 20, 82, 135, 57, 26, 121, 40,
	164, 50, 31, 137, 154, 133, 25, 35, 218, 51, 103, 44, 131, 131, 123, 31,
	6, 158, 86, 40, 64, 135, 148, 224, 45, 183, 128, 22, 26, 17, 131, 240,
	154, 14, 1, 209, 45, 16, 21, 91, 64, 222, 7, 1, 197, 56, 21, 39,
	155, 60, 138, 23, 102, 213, 83, 12, 13, 54, 192, 255, 68, 47, 28, 85,
	26, 85, 85, 128, 128, 32, 146, 171, 18, 11, 7, 63, 144, 171, 4, 4,
	246, 35, 27, 10, 146, 174, 171, 12, 26, 128, 190, 80, 35, 99, 180, 80,
	126, 54, 45, 85, 126, 47, 87, 176, 51, 41, 20, 32, 101, 75, 128, 139,
	118, 146, 116, 128, 85, 56, 41, 15, 176, 236, 85, 37, 9, 62, 71, 30,
	17, 119, 118, 255, 17, 18, 138, 101, 38, 60, 138, 55, 70, 43, 26, 142,
	146, 36, 19, 30, 171, 255, 97, 27, 20, 138, 45, 61, 62, 219, 1, 81,
	188, 64, 32, 41, 20, 117, 151, 142, 20, 21, 163, 112, 19, 12, 61, 195,
	128, 48, 4, 24,
};

codetoplane := array[] of {
	24, 7, 23, 25, 40, 6, 39, 41, 22, 26, 38, 42, 56, 5, 55, 57,
	21, 27, 54, 58, 37, 43, 72, 4, 71, 73, 20, 28, 53, 59, 70, 74,
	36, 44, 88, 69, 75, 52, 60, 3, 87, 89, 19, 29, 86, 90, 35, 45,
	68, 76, 85, 91, 51, 61, 104, 2, 103, 105, 18, 30, 102, 106, 34, 46,
	84, 92, 67, 77, 101, 107, 50, 62, 120, 1, 119, 121, 83, 93, 17, 31,
	100, 108, 66, 78, 118, 122, 33, 47, 117, 123, 49, 63, 99, 109, 82, 94,
	0, 116, 124, 65, 79, 16, 32, 98, 110, 48, 115, 125, 81, 95, 64, 114,
	126, 97, 111, 80, 113, 127, 96, 112,
};
