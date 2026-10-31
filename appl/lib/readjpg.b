implement RImagefile;

#
# JPEG (ITU T.81) decoder: baseline and extended sequential (SOF0,
# SOF1) and progressive (SOF2) Huffman-coded, 8-bit, one, three or four
# components, any sampling factors that divide the largest, restart
# intervals.  It decodes as libjpeg(-turbo) does by default, so its
# pixels are libjpeg's: the integer "islow" IDCT and its range limit,
# "fancy" (triangle) upsampling where libjpeg uses it (h2v1, h1v2,
# h2v2; plain replication otherwise), and libjpeg's fixed-point YCbCr
# to RGB tables.  Four-component images (CMYK, YCCK) are taken as
# Adobe writes them, inverted, and made RGB as browsers make them.
# Arithmetic coding, lossless and hierarchical modes and 12-bit samples
# are refused.  EXIF orientation is not applied: that is the caller's
# (image-orientation).
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Point, Rect: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";

Huff: adt
{
	look:	array of int;	# 9-bit lookahead: length<<8 | value, 0 when the code is longer
	maxcode:	array of int;	# by length 1..16: the largest code, -1 when none
	mincode:	array of int;
	valptr:	array of int;
	vals:	array of int;
};

Comp: adt
{
	id, h, v, tq:	int;
	bw, bh:	int;	# blocks across and down, padded to whole MCUs
	dw, dh:	int;	# the component's own width and height in samples
	plane:	array of byte;	# bw*8 by bh*8 samples
	coef:	array of int;	# progressive: 64 coefficients a block, natural order
	pred:	int;	# DC predictor
	td, ta:	int;	# Huffman tables of this scan
};

Dec: adt
{
	d:	array of byte;
	pos:	int;
	buf, cnt:	int;	# entropy-coded bits, right aligned
	atmarker:	int;	# a marker (or the end) stopped the bits: zeros follow

	x, y:	int;
	comps:	array of ref Comp;
	hmax, vmax:	int;
	mcux, mcuy:	int;
	prog:	int;
	qt:	array of array of int;	# natural order
	dc, ac:	array of ref Huff;
	ri:	int;
	jfif, adobe, transform:	int;
	eobrun:	int;
};

zig := array[64] of {
	0, 1, 8, 16, 9, 2, 3, 10,
	17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63
};

idctlimit: array of byte;	# libjpeg's post-IDCT range limit, indexed by value & 1023
CLAMPOFF: con 512;
clamp: array of byte;	# v + CLAMPOFF -> 0..255
crr, cbb, crg, cbg: array of int;	# libjpeg's jdcolor.c tables

init(iomod: Bufio)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = iomod;
	idctlimit = array[1024] of byte;
	for(i := 0; i < 1024; i++) {
		v := 0;
		if(i < 128)
			v = i + 128;
		else if(i < 512)
			v = 255;
		else if(i < 896)
			v = 0;
		else
			v = i - 896;
		idctlimit[i] = byte v;
	}
	clamp = array[2*CLAMPOFF+256] of byte;
	for(i = 0; i < len clamp; i++) {
		v := i - CLAMPOFF;
		if(v < 0)
			v = 0;
		if(v > 255)
			v = 255;
		clamp[i] = byte v;
	}
	crr = array[256] of int;
	cbb = array[256] of int;
	crg = array[256] of int;
	cbg = array[256] of int;
	for(i = 0; i < 256; i++) {
		x := i - 128;
		crr[i] = (91881 * x + 32768) >> 16;	# FIX(1.40200)
		cbb[i] = (116130 * x + 32768) >> 16;	# FIX(1.77200)
		crg[i] = -46802 * x;	# -FIX(0.71414)
		cbg[i] = -22554 * x + 32768;	# -FIX(0.34414), with ONE_HALF
	}
}

read(fd: ref Iobuf): (ref Rawimage, string)
{
	d := readall(fd);
	if(d == nil)
		return (nil, "ReadJPG: read error");
	{
		return decode(d);
	} exception e {
	"*" =>
		return (nil, "ReadJPG: " + e);
	}
}

readmulti(fd: ref Iobuf): (array of ref Rawimage, string)
{
	(i, err) := read(fd);
	if(i != nil)
		return (array[1] of {i}, err);
	return (nil, err);
}

readall(fd: ref Iobuf): array of byte
{
	b := array[65536] of byte;
	n := 0;
	for(;;) {
		if(n == len b) {
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		m := fd.read(b[n:], len b - n);
		if(m <= 0)
			break;
		n += m;
	}
	if(n == 0)
		return nil;
	return b[0:n];
}

int2(b: array of byte, n: int): int
{
	return (int b[n] << 8) | int b[n+1];
}

decode(d: array of byte): (ref Rawimage, string)
{
	if(len d < 4 || d[0] != byte 16rFF || d[1] != byte 16rD8)
		return (nil, "ReadJPG: not a JPEG file");
	dc := ref Dec(d, 2, 0, 0, 0, 0, 0, nil, 0, 0, 0, 0, 0,
		array[4] of array of int, array[4] of ref Huff, array[4] of ref Huff,
		0, 0, 0, -1, 0);
	err: string;
	for(;;) {
		m := nextmarker(dc);
		if(m < 0 || m == 16rD9)	# the end, or EOI
			break;
		if(m == 16rD8 || m >= 16rD0 && m <= 16rD7 || m == 16r01)
			continue;	# markers without a length
		if(dc.pos + 2 > len d)
			break;
		n := int2(d, dc.pos);
		if(n < 2 || dc.pos + n > len d)
			return (nil, "ReadJPG: truncated segment");
		seg := d[dc.pos+2:dc.pos+n];
		dc.pos += n;
		case m {
		16rC0 or 16rC1 =>
			err = frame(dc, seg, 0);
		16rC2 =>
			err = frame(dc, seg, 1);
		16rC3 or 16rC7 or 16rCB or 16rCF =>
			err = "ReadJPG: lossless JPEG is not supported";
		16rC5 or 16rC6 =>
			err = "ReadJPG: hierarchical JPEG is not supported";
		16rC9 or 16rCA or 16rCD or 16rCE =>
			err = "ReadJPG: arithmetic coding is not supported";
		16rC4 =>
			err = huffman(dc, seg);
		16rCC =>
			;	# arithmetic conditioning: the frame says arithmetic, and is refused
		16rDB =>
			err = quant(dc, seg);
		16rDD =>
			if(len seg >= 2)
				dc.ri = int2(seg, 0);
		16rDA =>
			if(dc.comps == nil)
				return (nil, "ReadJPG: scan before frame");
			err = scan(dc, seg);
		16rE0 =>
			if(len seg >= 5 && string seg[0:4] == "JFIF" && seg[4] == byte 0)
				dc.jfif = 1;
		16rEE =>
			if(len seg >= 12 && string seg[0:5] == "Adobe") {
				dc.adobe = 1;
				dc.transform = int seg[11];
			}
		16rDC =>
			;	# DNL after the first scan: the frame's height stands
		}
		if(err != nil)
			return (nil, err);
	}
	if(dc.comps == nil)
		return (nil, "ReadJPG: no image");
	if(dc.prog)
		for(i := 0; i < len dc.comps; i++)
			finishcoef(dc, dc.comps[i]);
	return output(dc);
}

# the next marker's code at pos, skipping anything that is not one;
# -1 at the end of the data
nextmarker(dc: ref Dec): int
{
	d := dc.d;
	while(dc.pos < len d) {
		if(d[dc.pos] != byte 16rFF) {
			dc.pos++;
			continue;
		}
		while(dc.pos < len d && d[dc.pos] == byte 16rFF)
			dc.pos++;
		if(dc.pos >= len d)
			break;
		m := int d[dc.pos++];
		if(m != 0)
			return m;
	}
	return -1;
}

frame(dc: ref Dec, b: array of byte, prog: int): string
{
	if(dc.comps != nil)
		return "ReadJPG: more than one frame";
	if(len b < 6)
		return "ReadJPG: short frame header";
	if(int b[0] != 8)
		return sys->sprint("ReadJPG: %d-bit samples are not supported", int b[0]);
	dc.y = int2(b, 1);
	dc.x = int2(b, 3);
	nf := int b[5];
	if(dc.y == 0)
		return "ReadJPG: height given by DNL is not supported";
	if(dc.x == 0)
		return "ReadJPG: zero width";
	if(nf != 1 && nf != 3 && nf != 4)
		return sys->sprint("ReadJPG: %d components are not supported", nf);
	if(len b < 6 + 3*nf)
		return "ReadJPG: short frame header";
	dc.prog = prog;
	dc.comps = array[nf] of ref Comp;
	dc.hmax = 1;
	dc.vmax = 1;
	for(i := 0; i < nf; i++) {
		hv := int b[6+3*i+1];
		c := ref Comp(int b[6+3*i], hv >> 4, hv & 15, int b[6+3*i+2] & 3, 0, 0, 0, 0, nil, nil, 0, 0, 0);
		if(c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4)
			return "ReadJPG: bad sampling factors";
		if(c.h > dc.hmax)
			dc.hmax = c.h;
		if(c.v > dc.vmax)
			dc.vmax = c.v;
		dc.comps[i] = c;
	}
	if(nf == 1) {
		# one component is not subsampled, whatever it says (A.2.2)
		c := dc.comps[0];
		c.h = c.v = dc.hmax = dc.vmax = 1;
	}
	dc.mcux = (dc.x + 8*dc.hmax - 1) / (8*dc.hmax);
	dc.mcuy = (dc.y + 8*dc.vmax - 1) / (8*dc.vmax);
	for(i = 0; i < nf; i++) {
		c := dc.comps[i];
		if(dc.hmax % c.h != 0 || dc.vmax % c.v != 0)
			return "ReadJPG: sampling factors that do not divide are not supported";
		c.bw = dc.mcux * c.h;
		c.bh = dc.mcuy * c.v;
		c.dw = (dc.x * c.h + dc.hmax - 1) / dc.hmax;
		c.dh = (dc.y * c.v + dc.vmax - 1) / dc.vmax;
		c.plane = array[c.bw*8 * c.bh*8] of byte;
		if(prog)
			c.coef = array[c.bw * c.bh * 64] of {* => 0};
	}
	return nil;
}

quant(dc: ref Dec, b: array of byte): string
{
	for(l := 0; l < len b; ) {
		pq := int b[l] >> 4;
		tq := int b[l] & 15;
		if(pq > 1 || tq > 3)
			return "ReadJPG: bad quantization table";
		n := 64 * (1 + pq);
		if(l + 1 + n > len b)
			return "ReadJPG: short quantization table";
		q := array[64] of int;
		for(i := 0; i < 64; i++) {
			v: int;
			if(pq == 0)
				v = int b[l+1+i];
			else
				v = int2(b, l+1+2*i);
			q[zig[i]] = v;
		}
		dc.qt[tq] = q;
		l += 1 + n;
	}
	return nil;
}

huffman(dc: ref Dec, b: array of byte): string
{
	for(l := 0; l < len b; ) {
		if(l + 17 > len b)
			return "ReadJPG: short Huffman table";
		tc := int b[l] >> 4;
		th := int b[l] & 15;
		if(tc > 1 || th > 3)
			return "ReadJPG: bad Huffman table";
		counts := b[l+1:l+17];
		n := 0;
		for(i := 0; i < 16; i++)
			n += int counts[i];
		if(n > 256 || l + 17 + n > len b)
			return "ReadJPG: bad Huffman table";
		h := ref Huff(array[512] of {* => 0}, array[18] of {* => -1}, array[17] of {* => 0}, array[17] of {* => 0}, array[n] of int);
		for(i = 0; i < n; i++)
			h.vals[i] = int b[l+17+i];
		# canonical codes (C.2, F.15)
		code := 0;
		k := 0;
		for(len1 := 1; len1 <= 16; len1++) {
			c := int counts[len1-1];
			h.valptr[len1] = k;
			h.mincode[len1] = code;
			for(j := 0; j < c; j++) {
				if(len1 <= 9) {
					s := code << (9 - len1);
					e := s + (1 << (9 - len1));
					for(; s < e; s++)
						h.look[s] = (len1 << 8) | h.vals[k];
				}
				code++;
				k++;
			}
			if(c > 0)
				h.maxcode[len1] = code - 1;
			code <<= 1;
		}
		h.maxcode[17] = 16r7FFFFFFF;	# a sentinel: decode stops at 16 bits
		if(tc == 0)
			dc.dc[th] = h;
		else
			dc.ac[th] = h;
		l += 17 + n;
	}
	return nil;
}

# ---- entropy-coded bits ----

fill(dc: ref Dec)
{
	d := dc.d;
	while(dc.cnt <= 24) {
		b := 0;
		if(!dc.atmarker) {
			if(dc.pos >= len d)
				dc.atmarker = 1;
			else {
				b = int d[dc.pos];
				if(b == 16rFF) {
					if(dc.pos + 1 < len d && d[dc.pos+1] == byte 0)
						dc.pos += 2;
					else {
						dc.atmarker = 1;	# a marker: stop before it, feed zeros (as libjpeg does)
						b = 0;
					}
				} else
					dc.pos++;
			}
		}
		dc.buf = (dc.buf << 8) | b;
		dc.cnt += 8;
	}
}

getbits(dc: ref Dec, n: int): int
{
	if(n <= 0)
		return 0;
	if(n > 16)
		n = 16;	# corrupt data
	if(dc.cnt < n)
		fill(dc);
	dc.cnt -= n;
	return (dc.buf >> dc.cnt) & ((1 << n) - 1);
}

getbit(dc: ref Dec): int
{
	if(dc.cnt < 1)
		fill(dc);
	dc.cnt--;
	return (dc.buf >> dc.cnt) & 1;
}

extend(v, s: int): int
{
	if(s == 0)
		return 0;
	if(v < (1 << (s-1)))
		v += (-1 << s) + 1;
	return v;
}

huff(dc: ref Dec, h: ref Huff): int
{
	if(dc.cnt < 16)
		fill(dc);
	c := (dc.buf >> (dc.cnt - 9)) & 511;
	l := h.look[c];
	if(l != 0) {
		dc.cnt -= l >> 8;
		return l & 255;
	}
	n := 10;
	c = (dc.buf >> (dc.cnt - n)) & 1023;
	while(c > h.maxcode[n]) {
		n++;
		if(n > 16) {
			dc.cnt -= 16;	# not a code: corrupt data
			return 0;
		}
		c = (dc.buf >> (dc.cnt - n)) & ((1 << n) - 1);
	}
	dc.cnt -= n;
	i := h.valptr[n] + c - h.mincode[n];
	if(i < 0 || i >= len h.vals)
		return 0;
	return h.vals[i];
}

# at a restart interval: drop the bits left, pass the RSTn marker,
# reset the predictors
restart(dc: ref Dec, comps: array of ref Comp)
{
	dc.cnt = 0;
	dc.buf = 0;
	d := dc.d;
	for(p := dc.pos; p + 1 < len d; p++)
		if(d[p] == byte 16rFF) {
			m := int d[p+1];
			if(m >= 16rD0 && m <= 16rD7) {
				dc.pos = p + 2;
				break;
			}
			if(m != 0 && m != 16rFF) {
				dc.pos = p;	# another marker: leave it for the caller
				break;
			}
		}
	dc.atmarker = 0;
	for(i := 0; i < len comps; i++)
		comps[i].pred = 0;
	dc.eobrun = 0;
}

# ---- scans ----

scan(dc: ref Dec, b: array of byte): string
{
	ns := int b[0];
	if(ns < 1 || ns > 4 || len b < 1 + 2*ns + 3)
		return "ReadJPG: bad scan header";
	comps := array[ns] of ref Comp;
	for(i := 0; i < ns; i++) {
		id := int b[1+2*i];
		c: ref Comp;
		for(j := 0; j < len dc.comps; j++)
			if(dc.comps[j].id == id)
				c = dc.comps[j];
		if(c == nil)
			return "ReadJPG: scan names an unknown component";
		c.td = int b[2+2*i] >> 4;
		c.ta = int b[2+2*i] & 15;
		if(c.td > 3 || c.ta > 3)
			return "ReadJPG: bad Huffman table selector";
		c.pred = 0;
		comps[i] = c;
	}
	ss := int b[1+2*ns];
	se := int b[2+2*ns];
	ah := int b[3+2*ns] >> 4;
	al := int b[3+2*ns] & 15;
	dc.buf = dc.cnt = 0;
	dc.atmarker = 0;
	dc.eobrun = 0;
	kind := 0;	# 0 sequential, 1 DC first, 2 DC refine, 3 AC first, 4 AC refine
	if(dc.prog) {
		if(ss == 0) {
			if(se != 0)
				return "ReadJPG: bad progressive scan";
			kind = 1;
			if(ah != 0)
				kind = 2;
		} else {
			if(ns != 1 || se < ss || se > 63)
				return "ReadJPG: bad progressive scan";
			kind = 3;
			if(ah != 0)
				kind = 4;
		}
	}
	for(i = 0; i < ns; i++) {
		c := comps[i];
		needdc := kind == 0 || kind == 1;
		needac := kind == 0 || kind >= 3;
		if(needdc && dc.dc[c.td] == nil || needac && dc.ac[c.ta] == nil)
			return "ReadJPG: scan uses an undefined Huffman table";
		if(kind == 0 && dc.qt[c.tq] == nil)
			return "ReadJPG: scan uses an undefined quantization table";
	}
	zz := array[64] of int;
	n := 0;	# MCUs decoded, for restarts
	if(ns == 1) {
		# non-interleaved: the blocks the component's own size needs (A.2.2)
		c := comps[0];
		bx := (c.dw + 7) / 8;
		by := (c.dh + 7) / 8;
		for(y := 0; y < by; y++)
			for(x := 0; x < bx; x++) {
				if(dc.ri > 0 && n > 0 && n % dc.ri == 0)
					restart(dc, comps);
				block(dc, c, x, y, kind, ss, se, al, zz);
				n++;
			}
	} else {
		for(my := 0; my < dc.mcuy; my++)
			for(mx := 0; mx < dc.mcux; mx++) {
				if(dc.ri > 0 && n > 0 && n % dc.ri == 0)
					restart(dc, comps);
				for(i = 0; i < ns; i++) {
					c := comps[i];
					for(v := 0; v < c.v; v++)
						for(h := 0; h < c.h; h++)
							block(dc, c, mx*c.h + h, my*c.v + v, kind, ss, se, al, zz);
				}
				n++;
			}
	}
	# on to the next marker
	dc.cnt = 0;
	return nil;
}

block(dc: ref Dec, c: ref Comp, bx, by, kind, ss, se, al: int, zz: array of int)
{
	case kind {
	0 =>
		for(k := 0; k < 64; k++)
			zz[k] = 0;
		t := huff(dc, dc.dc[c.td]);
		c.pred += extend(getbits(dc, t), t);
		zz[0] = c.pred;
		ac := dc.ac[c.ta];
		for(k = 1; k < 64; ) {
			rs := huff(dc, ac);
			r := rs >> 4;
			s := rs & 15;
			if(s != 0) {
				k += r;
				if(k > 63)
					break;
				zz[zig[k]] = extend(getbits(dc, s), s);
				k++;
			} else {
				if(r != 15)
					break;
				k += 16;
			}
		}
		stride := c.bw * 8;
		idct(zz, dc.qt[c.tq], c.plane, by*8*stride + bx*8, stride);
	1 =>
		t := huff(dc, dc.dc[c.td]);
		c.pred += extend(getbits(dc, t), t);
		c.coef[(by*c.bw + bx)*64] = c.pred << al;
	2 =>
		if(getbit(dc))
			c.coef[(by*c.bw + bx)*64] |= 1 << al;
	3 =>
		if(dc.eobrun > 0) {
			dc.eobrun--;
			return;
		}
		co := c.coef;
		o := (by*c.bw + bx)*64;
		ac := dc.ac[c.ta];
		for(k := ss; k <= se; k++) {
			rs := huff(dc, ac);
			r := rs >> 4;
			s := rs & 15;
			if(s != 0) {
				k += r;
				if(k > 63)
					break;
				co[o + zig[k]] = extend(getbits(dc, s), s) << al;
			} else {
				if(r != 15) {
					dc.eobrun = 1 << r;
					if(r != 0)
						dc.eobrun += getbits(dc, r);
					dc.eobrun--;
					break;
				}
				k += 15;
			}
		}
	4 =>
		refine(dc, c, (by*c.bw + bx)*64, ss, se, al);
	}
}

# a successive-approximation AC refinement of one block (G.1.2.3, as
# libjpeg's decode_mcu_AC_refine)
refine(dc: ref Dec, c: ref Comp, o, ss, se, al: int)
{
	co := c.coef;
	p1 := 1 << al;
	m1 := -1 << al;
	ac := dc.ac[c.ta];
	k := ss;
	if(dc.eobrun == 0) {
		for(; k <= se; k++) {
			rs := huff(dc, ac);
			r := rs >> 4;
			s := rs & 15;
			if(s != 0) {
				if(getbit(dc))
					s = p1;
				else
					s = m1;
			} else if(r != 15) {
				dc.eobrun = 1 << r;
				if(r != 0)
					dc.eobrun += getbits(dc, r);
				break;
			}
			do {
				z := o + zig[k];
				if(co[z] != 0) {
					if(getbit(dc) && (co[z] & p1) == 0) {
						if(co[z] >= 0)
							co[z] += p1;
						else
							co[z] += m1;
					}
				} else {
					if(--r < 0)
						break;
				}
				k++;
			} while(k <= se);
			if(s != 0 && k <= 63)
				co[o + zig[k]] = s;
		}
	}
	if(dc.eobrun > 0) {
		for(; k <= se; k++) {
			z := o + zig[k];
			if(co[z] != 0 && getbit(dc) && (co[z] & p1) == 0) {
				if(co[z] >= 0)
					co[z] += p1;
				else
					co[z] += m1;
			}
		}
		dc.eobrun--;
	}
}

finishcoef(dc: ref Dec, c: ref Comp)
{
	q := dc.qt[c.tq];
	if(q == nil)
		return;
	stride := c.bw * 8;
	zz := array[64] of int;
	co := c.coef;
	for(by := 0; by < c.bh; by++)
		for(bx := 0; bx < c.bw; bx++) {
			o := (by*c.bw + bx)*64;
			zz[0:] = co[o:o+64];
			idct(zz, q, c.plane, by*8*stride + bx*8, stride);
		}
	c.coef = nil;
}

# ---- libjpeg's jpeg_idct_islow, dequantizing as it goes ----

CONST_BITS: con 13;
PASS1_BITS: con 2;
R: con CONST_BITS - PASS1_BITS;
H: con 1 << (R - 1);
S: con CONST_BITS + PASS1_BITS + 3;
HS: con 1 << (S - 1);

ws := array[64] of int;

idct(in: array of int, q: array of int, out: array of byte, o, stride: int)
{
	# pass 1: columns
	for(col := 0; col < 8; col++) {
		if(in[col+8] == 0 && in[col+16] == 0 && in[col+24] == 0 && in[col+32] == 0 &&
		   in[col+40] == 0 && in[col+48] == 0 && in[col+56] == 0) {
			dcval := (in[col] * q[col]) << PASS1_BITS;
			for(r := 0; r < 64; r += 8)
				ws[col+r] = dcval;
			continue;
		}
		z2 := in[col+16] * q[col+16];
		z3 := in[col+48] * q[col+48];
		z1 := (z2 + z3) * 4433;
		tmp2 := z1 + z3 * -15137;
		tmp3 := z1 + z2 * 6270;
		z2 = in[col] * q[col];
		z3 = in[col+32] * q[col+32];
		tmp0 := (z2 + z3) << CONST_BITS;
		tmp1 := (z2 - z3) << CONST_BITS;
		tmp10 := tmp0 + tmp3;
		tmp13 := tmp0 - tmp3;
		tmp11 := tmp1 + tmp2;
		tmp12 := tmp1 - tmp2;

		tmp0 = in[col+56] * q[col+56];
		tmp1 = in[col+40] * q[col+40];
		tmp2 = in[col+24] * q[col+24];
		tmp3 = in[col+8] * q[col+8];
		z1 = tmp0 + tmp3;
		z2 = tmp1 + tmp2;
		z3 = tmp0 + tmp2;
		z4 := tmp1 + tmp3;
		z5 := (z3 + z4) * 9633;
		tmp0 = tmp0 * 2446;
		tmp1 = tmp1 * 16819;
		tmp2 = tmp2 * 25172;
		tmp3 = tmp3 * 12299;
		z1 = z1 * -7373;
		z2 = z2 * -20995;
		z3 = z3 * -16069;
		z4 = z4 * -3196;
		z3 += z5;
		z4 += z5;
		tmp0 += z1 + z3;
		tmp1 += z2 + z4;
		tmp2 += z2 + z3;
		tmp3 += z1 + z4;

		ws[col] = (tmp10 + tmp3 + H) >> R;
		ws[col+56] = (tmp10 - tmp3 + H) >> R;
		ws[col+8] = (tmp11 + tmp2 + H) >> R;
		ws[col+48] = (tmp11 - tmp2 + H) >> R;
		ws[col+16] = (tmp12 + tmp1 + H) >> R;
		ws[col+40] = (tmp12 - tmp1 + H) >> R;
		ws[col+24] = (tmp13 + tmp0 + H) >> R;
		ws[col+32] = (tmp13 - tmp0 + H) >> R;
	}
	# pass 2: rows
	lim := idctlimit;
	for(r := 0; r < 64; r += 8) {
		p := o;
		o += stride;
		if(ws[r+1] == 0 && ws[r+2] == 0 && ws[r+3] == 0 && ws[r+4] == 0 &&
		   ws[r+5] == 0 && ws[r+6] == 0 && ws[r+7] == 0) {
			v := lim[((ws[r] + (1 << (PASS1_BITS+2))) >> (PASS1_BITS+3)) & 1023];
			for(i := 0; i < 8; i++)
				out[p+i] = v;
			continue;
		}
		z2 := ws[r+2];
		z3 := ws[r+6];
		z1 := (z2 + z3) * 4433;
		tmp2 := z1 + z3 * -15137;
		tmp3 := z1 + z2 * 6270;
		tmp0 := (ws[r] + ws[r+4]) << CONST_BITS;
		tmp1 := (ws[r] - ws[r+4]) << CONST_BITS;
		tmp10 := tmp0 + tmp3;
		tmp13 := tmp0 - tmp3;
		tmp11 := tmp1 + tmp2;
		tmp12 := tmp1 - tmp2;

		tmp0 = ws[r+7];
		tmp1 = ws[r+5];
		tmp2 = ws[r+3];
		tmp3 = ws[r+1];
		z1 = tmp0 + tmp3;
		z2 = tmp1 + tmp2;
		z3 = tmp0 + tmp2;
		z4 := tmp1 + tmp3;
		z5 := (z3 + z4) * 9633;
		tmp0 = tmp0 * 2446;
		tmp1 = tmp1 * 16819;
		tmp2 = tmp2 * 25172;
		tmp3 = tmp3 * 12299;
		z1 = z1 * -7373;
		z2 = z2 * -20995;
		z3 = z3 * -16069;
		z4 = z4 * -3196;
		z3 += z5;
		z4 += z5;
		tmp0 += z1 + z3;
		tmp1 += z2 + z4;
		tmp2 += z2 + z3;
		tmp3 += z1 + z4;

		out[p] = lim[((tmp10 + tmp3 + HS) >> S) & 1023];
		out[p+7] = lim[((tmp10 - tmp3 + HS) >> S) & 1023];
		out[p+1] = lim[((tmp11 + tmp2 + HS) >> S) & 1023];
		out[p+6] = lim[((tmp11 - tmp2 + HS) >> S) & 1023];
		out[p+2] = lim[((tmp12 + tmp1 + HS) >> S) & 1023];
		out[p+5] = lim[((tmp12 - tmp1 + HS) >> S) & 1023];
		out[p+3] = lim[((tmp13 + tmp0 + HS) >> S) & 1023];
		out[p+4] = lim[((tmp13 - tmp0 + HS) >> S) & 1023];
	}
}

# ---- upsampling and colour, as libjpeg-turbo's jdsample.c and jdcolor.c ----

# component c's samples for output row y, at full width, into row
uprow(c: ref Comp, hmax, vmax, y: int, row, colsum: array of int)
{
	hr := hmax / c.h;
	vr := vmax / c.v;
	stride := c.bw * 8;
	pl := c.plane;
	dw := c.dw;
	if(hr == 1 && vr == 1) {
		p := y * stride;
		for(x := 0; x < dw; x++)
			row[x] = int pl[p+x];
		return;
	}
	if(hr == 2 && vr == 1 && dw > 2) {
		p := y * stride;
		h2v1(pl, p, dw, row);
		return;
	}
	if(hr == 1 && vr == 2) {
		ir := y >> 1;
		nr := ir - 1;
		bias := 1;
		if(y & 1) {
			nr = ir + 1;
			bias = 2;
		}
		nr = cliprow(nr, c.dh);
		p0 := ir * stride;
		p1 := nr * stride;
		for(x := 0; x < dw; x++)
			row[x] = (3 * int pl[p0+x] + int pl[p1+x] + bias) >> 2;
		return;
	}
	if(hr == 2 && vr == 2 && dw > 2) {
		ir := y >> 1;
		nr := ir - 1;
		if(y & 1)
			nr = ir + 1;
		nr = cliprow(nr, c.dh);
		p0 := ir * stride;
		p1 := nr * stride;
		for(x := 0; x < dw; x++)
			colsum[x] = 3 * int pl[p0+x] + int pl[p1+x];
		row[0] = (colsum[0] * 4 + 8) >> 4;
		row[1] = (colsum[0] * 3 + colsum[1] + 7) >> 4;
		j := 2;
		for(x = 1; x < dw - 1; x++) {
			row[j++] = (colsum[x] * 3 + colsum[x-1] + 8) >> 4;
			row[j++] = (colsum[x] * 3 + colsum[x+1] + 7) >> 4;
		}
		row[j++] = (colsum[dw-1] * 3 + colsum[dw-2] + 8) >> 4;
		row[j] = (colsum[dw-1] * 4 + 7) >> 4;
		return;
	}
	# replication (int_upsample, and h2v1/h2v2 under three samples wide)
	p := cliprow(y / vr, c.dh) * stride;
	j := 0;
	for(x := 0; x < dw; x++) {
		v := int pl[p+x];
		for(k := 0; k < hr; k++)
			row[j++] = v;
	}
}

h2v1(pl: array of byte, p, dw: int, row: array of int)
{
	v := int pl[p];
	row[0] = v;
	row[1] = (v * 3 + int pl[p+1] + 2) >> 2;
	j := 2;
	for(x := 1; x < dw - 1; x++) {
		v = int pl[p+x] * 3;
		row[j++] = (v + int pl[p+x-1] + 1) >> 2;
		row[j++] = (v + int pl[p+x+1] + 2) >> 2;
	}
	v = int pl[p+dw-1];
	row[j++] = (v * 3 + int pl[p+dw-2] + 1) >> 2;
	row[j] = v;
}

cliprow(r, h: int): int
{
	if(r < 0)
		return 0;
	if(r >= h)
		return h - 1;
	return r;
}

output(dc: ref Dec): (ref Rawimage, string)
{
	X := dc.x;
	Y := dc.y;
	nf := len dc.comps;
	nout := 3;
	cd := RImagefile->CRGB;
	if(nf == 1) {
		nout = 1;
		cd = RImagefile->CY;
	}
	img := ref Rawimage(Rect((0, 0), (X, Y)), nil, 0, byte 0, nout, array[nout] of array of byte, cd, 0);
	for(i := 0; i < nout; i++)
		img.chans[i] = array[X*Y] of byte;
	if(nf == 1) {
		c := dc.comps[0];
		stride := c.bw * 8;
		out := img.chans[0];
		for(y := 0; y < Y; y++)
			out[y*X:] = c.plane[y*stride:y*stride+X];
		return (img, nil);
	}
	# which colour space (libjpeg's default_decompress_parms)
	rgb := 0;
	ycck := 0;
	if(nf == 3) {
		if(!dc.jfif && dc.adobe && dc.transform == 0)
			rgb = 1;
		else if(!dc.jfif && !dc.adobe && dc.comps[0].id == 'R' && dc.comps[1].id == 'G' && dc.comps[2].id == 'B')
			rgb = 1;
	} else if(dc.adobe && dc.transform != 0)
		ycck = 1;
	rows := array[nf] of array of int;
	for(i = 0; i < nf; i++)
		rows[i] = array[X + 8*dc.hmax + 8] of int;
	colsum := array[X + 8] of int;
	r := img.chans[0];
	g := img.chans[1];
	b := img.chans[2];
	cl := clamp;
	for(y := 0; y < Y; y++) {
		for(i = 0; i < nf; i++)
			uprow(dc.comps[i], dc.hmax, dc.vmax, y, rows[i], colsum);
		o := y * X;
		r0 := rows[0];
		r1 := rows[1];
		r2 := rows[2];
		if(rgb) {
			for(x := 0; x < X; x++) {
				r[o+x] = byte r0[x];
				g[o+x] = byte r1[x];
				b[o+x] = byte r2[x];
			}
		} else if(nf == 3) {
			for(x := 0; x < X; x++) {
				yy := r0[x] + CLAMPOFF;
				cb := r1[x];
				cr := r2[x];
				r[o+x] = cl[yy + crr[cr]];
				g[o+x] = cl[yy + ((cbg[cb] + crg[cr]) >> 16)];
				b[o+x] = cl[yy + cbb[cb]];
			}
		} else {
			r3 := rows[3];
			for(x := 0; x < X; x++) {
				c, m, yl: int;
				if(ycck) {
					yy := r0[x] + CLAMPOFF;
					cb := r1[x];
					cr := r2[x];
					c = 255 - int cl[yy + crr[cr]];
					m = 255 - int cl[yy + ((cbg[cb] + crg[cr]) >> 16)];
					yl = 255 - int cl[yy + cbb[cb]];
				} else {
					c = r0[x];
					m = r1[x];
					yl = r2[x];
				}
				k := r3[x];
				r[o+x] = byte muldiv255(c, k);
				g[o+x] = byte muldiv255(m, k);
				b[o+x] = byte muldiv255(yl, k);
			}
		}
	}
	return (img, nil);
}

# a*b/255 rounded, for inverted (Adobe) CMYK: no ink is 255
muldiv255(a, b: int): int
{
	t := a * b + 128;
	return ((t >> 8) + t) >> 8;
}
