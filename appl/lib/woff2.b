implement Woff2;

#
# WOFF 2.0 (https://www.w3.org/TR/WOFF2/): a table directory, then all
# tables Brotli-compressed as one stream; glyf and loca may be in the
# transformed form of §5.1 and hmtx in that of §5.4.  The glyphs are
# rebuilt as plain TrueType: coordinates as 16-bit deltas, which is
# larger than the original encoding but means the same.
#

include "sys.m";
	sys: Sys;
include "brotli.m";
	brotli: Brotli;
include "woff2.m";

Bad: con "woff2: corrupt font";

known := array[] of {
	"cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ",
	"fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT", "EBLC", "gasp",
	"hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF",
	"GPOS", "GSUB", "EBSC", "JSTF", "MATH", "CBDT", "CBLC", "COLR", "CPAL",
	"SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc",
	"feat", "fmtx", "fvar", "gvar", "hsty", "just", "lcar", "mort", "morx",
	"opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
};

Tab: adt {
	tag:	string;
	xform:	int;		# transformation version
	olen:	int;		# original length
	tlen:	int;		# length in the stream
	off:	int;		# in the decompressed stream
	data:	array of byte;	# the table, rebuilt
};

# a byte reader
Rd: adt {
	d:	array of byte;
	p:	int;
	end:	int;

	u8:	fn(r: self ref Rd): int;
	u16:	fn(r: self ref Rd): int;
	s16:	fn(r: self ref Rd): int;
	u32:	fn(r: self ref Rd): int;
	u255:	fn(r: self ref Rd): int;
	base128:	fn(r: self ref Rd): int;
	take:	fn(r: self ref Rd, n: int): array of byte;
	sub:	fn(r: self ref Rd, n: int): ref Rd;
};

Rd.u8(r: self ref Rd): int
{
	if(r.p >= r.end)
		raise Bad;
	return int r.d[r.p++];
}

Rd.u16(r: self ref Rd): int
{
	v := r.u8() << 8;
	return v | r.u8();
}

Rd.s16(r: self ref Rd): int
{
	v := r.u16();
	if(v >= 16r8000)
		v -= 16r10000;
	return v;
}

Rd.u32(r: self ref Rd): int
{
	v := r.u16() << 16;
	return v | r.u16();
}

# 255UInt16 (§4.1)
Rd.u255(r: self ref Rd): int
{
	c := r.u8();
	case c {
	253 =>	return r.u16();
	255 =>	return r.u8() + 253;
	254 =>	return r.u8() + 506;
	}
	return c;
}

# UIntBase128 (§4.1)
Rd.base128(r: self ref Rd): int
{
	v := 0;
	for(i := 0; i < 5; i++) {
		b := r.u8();
		if(i == 0 && b == 16r80)
			raise Bad;
		if(v >= (1 << 24))	# would not fit once shifted
			raise Bad;
		v = (v << 7) | (b & 16r7F);
		if((b & 16r80) == 0)
			return v;
	}
	raise Bad;
}

Rd.take(r: self ref Rd, n: int): array of byte
{
	if(n < 0 || r.p + n > r.end)
		raise Bad;
	a := r.d[r.p:r.p+n];
	r.p += n;
	return a;
}

Rd.sub(r: self ref Rd, n: int): ref Rd
{
	if(n < 0 || r.p + n > r.end)
		raise Bad;
	s := ref Rd(r.d, r.p, r.p + n);
	r.p += n;
	return s;
}

decode(data: array of byte): (array of byte, string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(brotli == nil) {
		brotli = load Brotli Brotli->PATH;
		if(brotli == nil)
			return (nil, sys->sprint("woff2: cannot load %s: %r", Brotli->PATH));
	}
	{
		return (unpack(data), nil);
	} exception e {
	"woff2:*" or "brotli:*" =>
		return (nil, e);
	"array bounds*" or "out of memory*" =>
		return (nil, Bad);
	}
}

unpack(data: array of byte): array of byte
{
	r := ref Rd(data, 0, len data);
	if(string r.take(4) != "wOF2")
		raise "woff2: not a WOFF2 font";
	flavor := r.u32();
	if(flavor == 16r74746366)	# 'ttcf'
		raise "woff2: font collections are not supported";
	r.u32();	# length
	ntab := r.u16();
	r.u16();	# reserved
	r.u32();	# totalSfntSize
	clen := r.u32();
	r.p = 48;
	tabs := array[ntab] of ref Tab;
	total := 0;
	for(i := 0; i < ntab; i++) {
		f := r.u8();
		tag: string;
		if((f & 16r3F) == 63)
			tag = string r.take(4);
		else
			tag = known[f & 16r3F];
		v := f >> 6;
		olen := r.base128();
		t := ref Tab(tag, v, olen, olen, total, nil);
		# glyf and loca are transformed unless version 3; others only if not 0
		transformed := v != 0;
		if(tag == "glyf" || tag == "loca")
			transformed = v != 3;
		if(transformed)
			t.tlen = r.base128();
		else
			t.xform = -1;
		if(tag == "glyf" || tag == "loca")
			if(transformed)
				t.xform = 0;
		if(tag == "hmtx" && transformed)
			t.xform = 1;
		total += t.tlen;
		tabs[i] = t;
	}
	(raw, err) := brotli->decompress(r.take(clen), total);
	if(err != nil)
		raise err;
	for(i = 0; i < ntab; i++)
		tabs[i].data = raw[tabs[i].off:tabs[i].off + tabs[i].tlen];

	glyf := find(tabs, "glyf");
	loca := find(tabs, "loca");
	xmins: array of int;
	if(glyf != nil && glyf.xform == 0) {
		if(loca == nil)
			raise Bad;
		(gd, ld, xm) := rebuildglyf(glyf.data);
		glyf.data = gd;
		loca.data = ld;
		xmins = xm;
	}
	hmtx := find(tabs, "hmtx");
	if(hmtx != nil && hmtx.xform == 1) {
		hhea := find(tabs, "hhea");
		maxp := find(tabs, "maxp");
		if(hhea == nil || maxp == nil || xmins == nil || len hhea.data < 36 || len maxp.data < 6)
			raise Bad;
		nhm := be16(hhea.data, 34);
		ng := be16(maxp.data, 4);
		hmtx.data = rebuildhmtx(hmtx.data, ng, nhm, xmins);
	}
	return sfnt(flavor, tabs);
}

find(tabs: array of ref Tab, tag: string): ref Tab
{
	for(i := 0; i < len tabs; i++)
		if(tabs[i].tag == tag)
			return tabs[i];
	return nil;
}

# §5.1: glyf and loca from the transformed glyf; also each glyph's xMin
rebuildglyf(d: array of byte): (array of byte, array of byte, array of int)
{
	r := ref Rd(d, 0, len d);
	r.u16();	# reserved
	opts := r.u16();
	ng := r.u16();
	ifmt := r.u16();
	sizes := array[7] of int;
	for(i := 0; i < 7; i++)
		sizes[i] = r.u32();
	ncont := r.sub(sizes[0]);
	npts := r.sub(sizes[1]);
	flags := r.sub(sizes[2]);
	glyphs := r.sub(sizes[3]);
	comps := r.sub(sizes[4]);
	bboxr := r.sub(sizes[5]);
	instr := r.sub(sizes[6]);
	overlap: array of byte;
	if(opts & 1)
		overlap = r.take((ng + 7) / 8);
	bbits := bboxr.take(4 * ((ng + 31) / 32));

	out := ref Buf(array[len d * 2 + 1024] of byte, 0);
	loca := array[ng + 1] of int;
	xmins := array[ng] of {* => 0};
	for(g := 0; g < ng; g++) {
		loca[g] = out.n;
		nc := ncont.s16();
		hasbbox := int bbits[g >> 3] & (16r80 >> (g & 7));
		if(nc == 0) {
			if(hasbbox)
				raise Bad;
			continue;
		}
		start := out.n;
		if(nc < 0) {
			# composite: copied, with a bounding box that is given
			if(!hasbbox)
				raise Bad;
			out.put16(nc);
			bb := bboxr.take(8);
			out.put(bb);
			xmins[g] = s16of(bb, 0);
			cstart := comps.p;
			hasinstr := 0;
			for(;;) {
				f := comps.u16();
				comps.u16();	# glyph index
				n := 2;
				if(f & 16r0001)
					n = 4;
				if(f & 16r0008)
					n += 2;
				else if(f & 16r0040)
					n += 4;
				else if(f & 16r0080)
					n += 8;
				comps.take(n);
				if(f & 16r0100)
					hasinstr = 1;
				if((f & 16r0020) == 0)
					break;
			}
			out.put(comps.d[cstart:comps.p]);
			if(hasinstr) {
				il := glyphs.u255();
				out.put16(il);
				out.put(instr.take(il));
			}
		} else {
			# simple: points from flags and coordinate triplets
			ends := array[nc] of int;
			np := 0;
			for(c := 0; c < nc; c++) {
				np += npts.u255();
				ends[c] = np - 1;
			}
			fl := flags.take(np);
			xs := array[np] of int;
			ys := array[np] of int;
			on := array[np] of int;
			x := 0;
			y := 0;
			for(k := 0; k < np; k++) {
				f := int fl[k];
				on[k] = (f & 16r80) == 0;
				f &= 16r7F;
				(dx, dy) := triplet(glyphs, f);
				x += dx;
				y += dy;
				xs[k] = x;
				ys[k] = y;
			}
			il := glyphs.u255();
			out.put16(nc);
			if(hasbbox) {
				bb := bboxr.take(8);
				out.put(bb);
				xmins[g] = s16of(bb, 0);
			} else {
				(x0, y0, x1, y1) := (0, 0, 0, 0);
				if(np > 0) {
					(x0, y0, x1, y1) = (xs[0], ys[0], xs[0], ys[0]);
					for(k = 1; k < np; k++) {
						if(xs[k] < x0) x0 = xs[k];
						if(xs[k] > x1) x1 = xs[k];
						if(ys[k] < y0) y0 = ys[k];
						if(ys[k] > y1) y1 = ys[k];
					}
				}
				out.put16(x0);
				out.put16(y0);
				out.put16(x1);
				out.put16(y1);
				xmins[g] = x0;
			}
			for(c = 0; c < nc; c++)
				out.put16(ends[c]);
			out.put16(il);
			out.put(instr.take(il));
			# flags: on curve, both coordinates as 16-bit deltas
			ov := overlap != nil && int overlap[g >> 3] & (16r80 >> (g & 7));
			for(k = 0; k < np; k++) {
				f := on[k];
				if(k == 0 && ov)
					f |= 16r40;
				out.put8(f);
			}
			px := 0;
			for(k = 0; k < np; k++) {
				out.put16(xs[k] - px);
				px = xs[k];
			}
			py := 0;
			for(k = 0; k < np; k++) {
				out.put16(ys[k] - py);
				py = ys[k];
			}
		}
		# glyphs start on 4-byte boundaries
		while((out.n - start) & 3)
			out.put8(0);
	}
	loca[ng] = out.n;
	ld: array of byte;
	if(ifmt == 0) {
		ld = array[2 * (ng + 1)] of byte;
		for(g = 0; g <= ng; g++)
			put16(ld, 2*g, loca[g] / 2);
	} else {
		ld = array[4 * (ng + 1)] of byte;
		for(g = 0; g <= ng; g++)
			put32(ld, 4*g, loca[g]);
	}
	return (out.d[0:out.n], ld, xmins);
}

# §5.2: one point's delta from its flag and the glyph stream
triplet(r: ref Rd, f: int): (int, int)
{
	dx, dy: int;
	if(f < 10) {
		dx = 0;
		dy = sign(f, ((f & 14) << 7) + r.u8());
	} else if(f < 20) {
		dx = sign(f, (((f - 10) & 14) << 7) + r.u8());
		dy = 0;
	} else if(f < 84) {
		b0 := f - 20;
		b1 := r.u8();
		dx = sign(f, 1 + (b0 & 16r30) + (b1 >> 4));
		dy = sign(f >> 1, 1 + ((b0 & 16r0C) << 2) + (b1 & 16r0F));
	} else if(f < 120) {
		b0 := f - 84;
		b1 := r.u8();
		b2 := r.u8();
		dx = sign(f, 1 + ((b0 / 12) << 8) + b1);
		dy = sign(f >> 1, 1 + (((b0 % 12) >> 2) << 8) + b2);
	} else if(f < 124) {
		b1 := r.u8();
		b2 := r.u8();
		b3 := r.u8();
		dx = sign(f, (b1 << 4) + (b2 >> 4));
		dy = sign(f >> 1, ((b2 & 16r0F) << 8) + b3);
	} else {
		b1 := r.u8();
		b2 := r.u8();
		b3 := r.u8();
		b4 := r.u8();
		dx = sign(f, (b1 << 8) + b2);
		dy = sign(f >> 1, (b3 << 8) + b4);
	}
	return (dx, dy);
}

sign(f, v: int): int
{
	if(f & 1)
		return v;
	return -v;
}

# §5.4
rebuildhmtx(d: array of byte, ng, nhm: int, xmins: array of int): array of byte
{
	r := ref Rd(d, 0, len d);
	f := r.u8();
	if((f & 16rFC) != 0 || (f & 3) == 0 || nhm < 1 || nhm > ng || len xmins < ng)
		raise Bad;
	adv := array[nhm] of int;
	for(i := 0; i < nhm; i++)
		adv[i] = r.u16();
	o := array[4*nhm + 2*(ng - nhm)] of byte;
	for(i = 0; i < nhm; i++) {
		lsb := xmins[i];
		if((f & 1) == 0)
			lsb = r.s16();
		put16(o, 4*i, adv[i]);
		put16(o, 4*i + 2, lsb);
	}
	for(i = nhm; i < ng; i++) {
		lsb := xmins[i];
		if((f & 2) == 0)
			lsb = r.s16();
		put16(o, 4*nhm + 2*(i - nhm), lsb);
	}
	return o;
}

# the tables as an sfnt: directory sorted by tag, each table 4-aligned
sfnt(flavor: int, tabs: array of ref Tab): array of byte
{
	n := len tabs;
	t := array[n] of ref Tab;
	t[0:] = tabs;
	for(i := 1; i < n; i++)
		for(j := i; j > 0 && t[j].tag < t[j-1].tag; j--)
			(t[j], t[j-1]) = (t[j-1], t[j]);
	size := 12 + 16*n;
	for(i = 0; i < n; i++)
		size += (len t[i].data + 3) & ~3;
	o := array[size] of {* => byte 0};
	put32(o, 0, flavor);
	put16(o, 4, n);
	es := 1;
	lg := 0;
	while(es*2 <= n) {
		es *= 2;
		lg++;
	}
	put16(o, 6, es*16);
	put16(o, 8, lg);
	put16(o, 10, n*16 - es*16);
	off := 12 + 16*n;
	for(i = 0; i < n; i++) {
		e := 12 + 16*i;
		for(k := 0; k < 4; k++)
			o[e+k] = byte t[i].tag[k];
		put32(o, e+4, checksum(t[i].data));
		put32(o, e+8, off);
		put32(o, e+12, len t[i].data);
		o[off:] = t[i].data;
		off += (len t[i].data + 3) & ~3;
	}
	return o;
}

checksum(d: array of byte): int
{
	s := 0;
	for(i := 0; i < len d; i += 4) {
		w := 0;
		for(k := 0; k < 4; k++) {
			w <<= 8;
			if(i + k < len d)
				w |= int d[i+k];
		}
		s += w;
	}
	return s;
}

Buf: adt {
	d:	array of byte;
	n:	int;

	put:	fn(b: self ref Buf, a: array of byte);
	put8:	fn(b: self ref Buf, v: int);
	put16:	fn(b: self ref Buf, v: int);
};

Buf.put(b: self ref Buf, a: array of byte)
{
	if(b.n + len a > len b.d) {
		nd := array[2 * len b.d + len a] of byte;
		nd[0:] = b.d[0:b.n];
		b.d = nd;
	}
	b.d[b.n:] = a;
	b.n += len a;
}

Buf.put8(b: self ref Buf, v: int)
{
	b.put(array[] of {byte v});
}

Buf.put16(b: self ref Buf, v: int)
{
	b.put(array[] of {byte (v >> 8), byte v});
}

be16(d: array of byte, i: int): int
{
	return int d[i] << 8 | int d[i+1];
}

s16of(d: array of byte, i: int): int
{
	v := be16(d, i);
	if(v >= 16r8000)
		v -= 16r10000;
	return v;
}

put16(d: array of byte, i, v: int)
{
	d[i] = byte (v >> 8);
	d[i+1] = byte v;
}

put32(d: array of byte, i, v: int)
{
	d[i] = byte (v >> 24);
	d[i+1] = byte (v >> 16);
	d[i+2] = byte (v >> 8);
	d[i+3] = byte v;
}
