implement Jpegenc;

#
# Baseline JPEG encoder for I420 frames (ITU T.81): JFIF, three
# components, Y sampled 2x2 and Cb, Cr 1x1 (4:2:0), one interleaved
# scan, the Huffman tables of Annex K.3, the quantisation tables of Annex
# K.1 scaled by quality as libjpeg scales them, and libjpeg's integer
# forward DCT (jfdctint, "islow").  Planes are taken as they are: a frame
# whose width or height is not a multiple of 16 is padded by repeating
# its last column and row, as libjpeg pads.
#

include "sys.m";
include "jpeg.m";

# Annex K.1: luminance and chrominance quantisation, natural order
lumq := array[64] of {
	16, 11, 10, 16, 24, 40, 51, 61,
	12, 12, 14, 19, 26, 58, 60, 55,
	14, 13, 16, 24, 40, 57, 69, 56,
	14, 17, 22, 29, 51, 87, 80, 62,
	18, 22, 37, 56, 68, 109, 103, 77,
	24, 35, 55, 64, 81, 104, 113, 92,
	49, 64, 78, 87, 103, 121, 120, 101,
	72, 92, 95, 98, 112, 100, 103, 99,
};
chrq := array[64] of {
	17, 18, 24, 47, 99, 99, 99, 99,
	18, 21, 26, 66, 99, 99, 99, 99,
	24, 26, 56, 99, 99, 99, 99, 99,
	47, 66, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
};

# zig-zag: the natural index of the k'th coefficient
zig := array[64] of {
	0, 1, 8, 16, 9, 2, 3, 10,
	17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63,
};

# Annex K.3: the code counts by length (1-16) and the values
dclbits := array[16] of {0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0};
dcvals := array[12] of {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
dccbits := array[16] of {0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0};
aclbits := array[16] of {0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 16r7d};
aclvals := array[162] of {
	16r01, 16r02, 16r03, 16r00, 16r04, 16r11, 16r05, 16r12, 16r21, 16r31, 16r41, 16r06, 16r13, 16r51, 16r61, 16r07,
	16r22, 16r71, 16r14, 16r32, 16r81, 16r91, 16ra1, 16r08, 16r23, 16r42, 16rb1, 16rc1, 16r15, 16r52, 16rd1, 16rf0,
	16r24, 16r33, 16r62, 16r72, 16r82, 16r09, 16r0a, 16r16, 16r17, 16r18, 16r19, 16r1a, 16r25, 16r26, 16r27, 16r28,
	16r29, 16r2a, 16r34, 16r35, 16r36, 16r37, 16r38, 16r39, 16r3a, 16r43, 16r44, 16r45, 16r46, 16r47, 16r48, 16r49,
	16r4a, 16r53, 16r54, 16r55, 16r56, 16r57, 16r58, 16r59, 16r5a, 16r63, 16r64, 16r65, 16r66, 16r67, 16r68, 16r69,
	16r6a, 16r73, 16r74, 16r75, 16r76, 16r77, 16r78, 16r79, 16r7a, 16r83, 16r84, 16r85, 16r86, 16r87, 16r88, 16r89,
	16r8a, 16r92, 16r93, 16r94, 16r95, 16r96, 16r97, 16r98, 16r99, 16r9a, 16ra2, 16ra3, 16ra4, 16ra5, 16ra6, 16ra7,
	16ra8, 16ra9, 16raa, 16rb2, 16rb3, 16rb4, 16rb5, 16rb6, 16rb7, 16rb8, 16rb9, 16rba, 16rc2, 16rc3, 16rc4, 16rc5,
	16rc6, 16rc7, 16rc8, 16rc9, 16rca, 16rd2, 16rd3, 16rd4, 16rd5, 16rd6, 16rd7, 16rd8, 16rd9, 16rda, 16re1, 16re2,
	16re3, 16re4, 16re5, 16re6, 16re7, 16re8, 16re9, 16rea, 16rf1, 16rf2, 16rf3, 16rf4, 16rf5, 16rf6, 16rf7, 16rf8,
	16rf9, 16rfa,
};
accbits := array[16] of {0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 16r77};
accvals := array[162] of {
	16r00, 16r01, 16r02, 16r03, 16r11, 16r04, 16r05, 16r21, 16r31, 16r06, 16r12, 16r41, 16r51, 16r07, 16r61, 16r71,
	16r13, 16r22, 16r32, 16r81, 16r08, 16r14, 16r42, 16r91, 16ra1, 16rb1, 16rc1, 16r09, 16r23, 16r33, 16r52, 16rf0,
	16r15, 16r62, 16r72, 16rd1, 16r0a, 16r16, 16r24, 16r34, 16re1, 16r25, 16rf1, 16r17, 16r18, 16r19, 16r1a, 16r26,
	16r27, 16r28, 16r29, 16r2a, 16r35, 16r36, 16r37, 16r38, 16r39, 16r3a, 16r43, 16r44, 16r45, 16r46, 16r47, 16r48,
	16r49, 16r4a, 16r53, 16r54, 16r55, 16r56, 16r57, 16r58, 16r59, 16r5a, 16r63, 16r64, 16r65, 16r66, 16r67, 16r68,
	16r69, 16r6a, 16r73, 16r74, 16r75, 16r76, 16r77, 16r78, 16r79, 16r7a, 16r82, 16r83, 16r84, 16r85, 16r86, 16r87,
	16r88, 16r89, 16r8a, 16r92, 16r93, 16r94, 16r95, 16r96, 16r97, 16r98, 16r99, 16r9a, 16ra2, 16ra3, 16ra4, 16ra5,
	16ra6, 16ra7, 16ra8, 16ra9, 16raa, 16rb2, 16rb3, 16rb4, 16rb5, 16rb6, 16rb7, 16rb8, 16rb9, 16rba, 16rc2, 16rc3,
	16rc4, 16rc5, 16rc6, 16rc7, 16rc8, 16rc9, 16rca, 16rd2, 16rd3, 16rd4, 16rd5, 16rd6, 16rd7, 16rd8, 16rd9, 16rda,
	16re2, 16re3, 16re4, 16re5, 16re6, 16re7, 16re8, 16re9, 16rea, 16rf2, 16rf3, 16rf4, 16rf5, 16rf6, 16rf7, 16rf8,
	16rf9, 16rfa,
};

# a Huffman table as codes and lengths by value (Annex C)
Code: adt {
	code:	array of int;
	size:	array of int;
};

# the entropy-coded bits
Out: adt {
	b:	array of byte;
	n:	int;
	acc:	int;	# bits waiting, right aligned
	nacc:	int;
};

dcl, acl, dcc, acc: ref Code;

encode(w, h: int, y, u, v: array of byte, quality: int): (array of byte, string)
{
	if(w <= 0 || h <= 0 || w > 65535 || h > 65535)
		return (nil, "jpegenc: bad size");
	cw := (w + 1) / 2;
	ch := (h + 1) / 2;
	if(len y < w*h || len u < cw*ch || len v < cw*ch)
		return (nil, "jpegenc: planes too short for the size");
	if(quality < 1 || quality > 100)
		return (nil, "jpegenc: quality not 1-100");
	if(dcl == nil){
		dcl = codes(dclbits, dcvals);
		acl = codes(aclbits, aclvals);
		dcc = codes(dccbits, dcvals);
		acc = codes(accbits, accvals);
	}
	ql := scaleq(lumq, quality);
	qc := scaleq(chrq, quality);
	o := ref Out(array[w*h/4 + 4096] of byte, 0, 0, 0);
	headers(o, w, h, ql, qc);

	# the divisors in natural order, times 8 for the DCT's scaling
	dl := array[64] of int;
	dch := array[64] of int;
	for(i := 0; i < 64; i++){
		dl[i] = ql[i] * 8;
		dch[i] = qc[i] * 8;
	}
	blk := array[64] of int;
	pdy := pdu := pdv := 0;
	for(my := 0; my < h; my += 16)
		for(mx := 0; mx < w; mx += 16){
			for(k := 0; k < 4; k++){
				fetch(y, w, h, mx + (k&1)*8, my + (k>>1)*8, blk);
				pdy = block(o, blk, dl, pdy, dcl, acl);
			}
			fetch(u, cw, ch, mx/2, my/2, blk);
			pdu = block(o, blk, dch, pdu, dcc, acc);
			fetch(v, cw, ch, mx/2, my/2, blk);
			pdv = block(o, blk, dch, pdv, dcc, acc);
		}
	# the last bits, padded with ones (F.1.2.3), and EOI
	if(o.nacc > 0)
		bits(o, (1 << (8 - o.nacc)) - 1, 8 - o.nacc);
	put(o, 16rFF);
	put(o, 16rD9);
	return (o.b[0:o.n], nil);
}

# libjpeg's jpeg_quality_scaling and jpeg_add_quant_table, baseline (<= 255)
scaleq(base: array of int, q: int): array of int
{
	s := 0;
	if(q < 50)
		s = 5000 / q;
	else
		s = 200 - q*2;
	t := array[64] of int;
	for(i := 0; i < 64; i++){
		x := (base[i] * s + 50) / 100;
		if(x < 1)
			x = 1;
		if(x > 255)
			x = 255;
		t[i] = x;
	}
	return t;
}

codes(bits, vals: array of int): ref Code
{
	c := ref Code(array[256] of {* => 0}, array[256] of {* => 0});
	code := 0;
	k := 0;
	for(l := 1; l <= 16; l++){
		for(i := 0; i < bits[l-1]; i++){
			c.code[vals[k]] = code;
			c.size[vals[k]] = l;
			code++;
			k++;
		}
		code <<= 1;
	}
	return c;
}

headers(o: ref Out, w, h: int, ql, qc: array of int)
{
	put(o, 16rFF); put(o, 16rD8);	# SOI
	# APP0 JFIF 1.01, no density, no thumbnail
	seg(o, 16rE0, array[] of {byte 'J', byte 'F', byte 'I', byte 'F', byte 0, byte 1, byte 1, byte 0, byte 0, byte 1, byte 0, byte 1, byte 0, byte 0});
	# DQT: table 0 luminance, 1 chrominance, in zig-zag order
	q := array[2*65] of byte;
	q[0] = byte 0;
	q[65] = byte 1;
	for(i := 0; i < 64; i++){
		q[1+i] = byte ql[zig[i]];
		q[66+i] = byte qc[zig[i]];
	}
	seg(o, 16rDB, q);
	# SOF0: 8-bit, h, w, three components: Y 2x2 table 0, Cb and Cr 1x1 table 1
	seg(o, 16rC0, array[] of {byte 8, byte (h>>8), byte h, byte (w>>8), byte w, byte 3,
		byte 1, byte 16r22, byte 0, byte 2, byte 16r11, byte 1, byte 3, byte 16r11, byte 1});
	# DHT: DC 0, AC 0 (luminance), DC 1, AC 1 (chrominance)
	dht(o, 16r00, dclbits, dcvals);
	dht(o, 16r10, aclbits, aclvals);
	dht(o, 16r01, dccbits, dcvals);
	dht(o, 16r11, accbits, accvals);
	# SOS: three components, Y tables 0/0, Cb and Cr 1/1, spectral 0-63
	seg(o, 16rDA, array[] of {byte 3, byte 1, byte 16r00, byte 2, byte 16r11, byte 3, byte 16r11, byte 0, byte 63, byte 0});
}

dht(o: ref Out, class: int, bits, vals: array of int)
{
	n := 0;
	for(i := 0; i < 16; i++)
		n += bits[i];
	b := array[1 + 16 + n] of byte;
	b[0] = byte class;
	for(i = 0; i < 16; i++)
		b[1+i] = byte bits[i];
	for(i = 0; i < n; i++)
		b[17+i] = byte vals[i];
	seg(o, 16rC4, b);
}

seg(o: ref Out, marker: int, body: array of byte)
{
	put(o, 16rFF);
	put(o, marker);
	n := len body + 2;
	put(o, n >> 8);
	put(o, n & 16rFF);
	for(i := 0; i < len body; i++)
		put(o, int body[i]);
}

put(o: ref Out, c: int)
{
	if(o.n >= len o.b){
		nb := array[2 * len o.b] of byte;
		nb[0:] = o.b[0:o.n];
		o.b = nb;
	}
	o.b[o.n++] = byte c;
}

# n bits of v, most significant first, a 0 stuffed after every FF
bits(o: ref Out, v, n: int)
{
	o.acc = (o.acc << n) | (v & ((1 << n) - 1));
	o.nacc += n;
	while(o.nacc >= 8){
		o.nacc -= 8;
		c := (o.acc >> o.nacc) & 16rFF;
		put(o, c);
		if(c == 16rFF)
			put(o, 0);
	}
	o.acc &= (1 << o.nacc) - 1;
}

# the 8x8 block at (x, y) of a plane w by h, its samples less 128;
# past the edge, the last column or row repeated
fetch(p: array of byte, w, h, x, y: int, blk: array of int)
{
	for(r := 0; r < 8; r++){
		sy := y + r;
		if(sy >= h)
			sy = h - 1;
		row := sy * w;
		for(c := 0; c < 8; c++){
			sx := x + c;
			if(sx >= w)
				sx = w - 1;
			blk[r*8+c] = int p[row+sx] - 128;
		}
	}
}

# one block: DCT, quantise, entropy code; the new DC predictor
block(o: ref Out, blk, div: array of int, pred: int, dc, ac: ref Code): int
{
	fdct(blk);
	q := array[64] of int;
	for(i := 0; i < 64; i++){
		x := blk[i];
		d := div[i];
		# round to nearest, as libjpeg's quantize does
		if(x < 0)
			q[i] = -((-x + (d >> 1)) / d);
		else
			q[i] = (x + (d >> 1)) / d;
	}
	diff := q[0] - pred;
	(s, m) := magnitude(diff);
	bits(o, dc.code[s], dc.size[s]);
	if(s)
		bits(o, m, s);
	run := 0;
	for(k := 1; k < 64; k++){
		x := q[zig[k]];
		if(x == 0){
			run++;
			continue;
		}
		while(run > 15){
			bits(o, ac.code[16rF0], ac.size[16rF0]);	# ZRL
			run -= 16;
		}
		(s, m) = magnitude(x);
		sym := (run << 4) | s;
		bits(o, ac.code[sym], ac.size[sym]);
		bits(o, m, s);
		run = 0;
	}
	if(run > 0)
		bits(o, ac.code[0], ac.size[0]);	# EOB
	return q[0];
}

# the size category of v and its bits (F.1.2.1): negative values one less
magnitude(v: int): (int, int)
{
	a := v;
	if(a < 0)
		a = -a;
	s := 0;
	while(a != 0){
		s++;
		a >>= 1;
	}
	if(v < 0)
		v += (1 << s) - 1;
	return (s, v);
}

# libjpeg's jpeg_fdct_islow: the outputs are the DCT's times 8
CONSTBITS:	con 13;
PASS1BITS:	con 2;
F0298631336:	con 2446;
F0390180644:	con 3196;
F0541196100:	con 4433;
F0765366865:	con 6270;
F0899976223:	con 7373;
F1175875602:	con 9633;
F1501321110:	con 12299;
F1847759065:	con 15137;
F1961570560:	con 16069;
F2053119869:	con 16819;
F2562915447:	con 20995;
F3072711026:	con 25172;

descale(x, n: int): int
{
	return (x + (1 << (n-1))) >> n;
}

fdct(d: array of int)
{
	for(p := 0; p < 64; p += 8){
		tmp0 := d[p+0] + d[p+7];
		tmp7 := d[p+0] - d[p+7];
		tmp1 := d[p+1] + d[p+6];
		tmp6 := d[p+1] - d[p+6];
		tmp2 := d[p+2] + d[p+5];
		tmp5 := d[p+2] - d[p+5];
		tmp3 := d[p+3] + d[p+4];
		tmp4 := d[p+3] - d[p+4];
		tmp10 := tmp0 + tmp3;
		tmp13 := tmp0 - tmp3;
		tmp11 := tmp1 + tmp2;
		tmp12 := tmp1 - tmp2;
		d[p+0] = (tmp10 + tmp11) << PASS1BITS;
		d[p+4] = (tmp10 - tmp11) << PASS1BITS;
		z1 := (tmp12 + tmp13) * F0541196100;
		d[p+2] = descale(z1 + tmp13*F0765366865, CONSTBITS-PASS1BITS);
		d[p+6] = descale(z1 - tmp12*F1847759065, CONSTBITS-PASS1BITS);
		z1 = tmp4 + tmp7;
		z2 := tmp5 + tmp6;
		z3 := tmp4 + tmp6;
		z4 := tmp5 + tmp7;
		z5 := (z3 + z4) * F1175875602;
		tmp4 *= F0298631336;
		tmp5 *= F2053119869;
		tmp6 *= F3072711026;
		tmp7 *= F1501321110;
		z1 *= -F0899976223;
		z2 *= -F2562915447;
		z3 *= -F1961570560;
		z4 *= -F0390180644;
		z3 += z5;
		z4 += z5;
		d[p+7] = descale(tmp4 + z1 + z3, CONSTBITS-PASS1BITS);
		d[p+5] = descale(tmp5 + z2 + z4, CONSTBITS-PASS1BITS);
		d[p+3] = descale(tmp6 + z2 + z3, CONSTBITS-PASS1BITS);
		d[p+1] = descale(tmp7 + z1 + z4, CONSTBITS-PASS1BITS);
	}
	for(c := 0; c < 8; c++){
		tmp0 := d[c+0] + d[c+56];
		tmp7 := d[c+0] - d[c+56];
		tmp1 := d[c+8] + d[c+48];
		tmp6 := d[c+8] - d[c+48];
		tmp2 := d[c+16] + d[c+40];
		tmp5 := d[c+16] - d[c+40];
		tmp3 := d[c+24] + d[c+32];
		tmp4 := d[c+24] - d[c+32];
		tmp10 := tmp0 + tmp3;
		tmp13 := tmp0 - tmp3;
		tmp11 := tmp1 + tmp2;
		tmp12 := tmp1 - tmp2;
		d[c+0] = descale(tmp10 + tmp11, PASS1BITS);
		d[c+32] = descale(tmp10 - tmp11, PASS1BITS);
		z1 := (tmp12 + tmp13) * F0541196100;
		d[c+16] = descale(z1 + tmp13*F0765366865, CONSTBITS+PASS1BITS);
		d[c+48] = descale(z1 - tmp12*F1847759065, CONSTBITS+PASS1BITS);
		z1 = tmp4 + tmp7;
		z2 := tmp5 + tmp6;
		z3 := tmp4 + tmp6;
		z4 := tmp5 + tmp7;
		z5 := (z3 + z4) * F1175875602;
		tmp4 *= F0298631336;
		tmp5 *= F2053119869;
		tmp6 *= F3072711026;
		tmp7 *= F1501321110;
		z1 *= -F0899976223;
		z2 *= -F2562915447;
		z3 *= -F1961570560;
		z4 *= -F0390180644;
		z3 += z5;
		z4 += z5;
		d[c+56] = descale(tmp4 + z1 + z3, CONSTBITS+PASS1BITS);
		d[c+40] = descale(tmp5 + z2 + z4, CONSTBITS+PASS1BITS);
		d[c+24] = descale(tmp6 + z2 + z3, CONSTBITS+PASS1BITS);
		d[c+8] = descale(tmp7 + z1 + z4, CONSTBITS+PASS1BITS);
	}
}
