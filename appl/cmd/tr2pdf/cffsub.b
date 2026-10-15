#
# cffsub.b: an OpenType font with CFF outlines, subset to the glyphs a
# document uses
#
# The glyphs keep their numbers (the PDF's text names them by number,
# Identity-H): those not used are emptied (a charstring of endchar
# alone), and so are the subroutines no glyph used calls (return alone),
# found by reading the used glyphs' charstrings as Type 2 programs.  The
# CFF is laid out again with its offsets; of the OpenType tables only
# those a PDF reader may look at are kept (the layout tables, GSUB, GPOS,
# GDEF and MATH, are not).  A font this does not understand (CID-keyed,
# Type 1 charstrings, an accent built with endchar's four arguments) is
# returned as it is.
#

# a CFF INDEX at o: its items, and where it ends
cffindex(d: array of byte, o: int): (array of array of byte, int)
{
	if(o + 2 > len d)
		raise "cff:index";
	n := (int d[o] << 8) | int d[o + 1];
	if(n == 0)
		return (array[0] of array of byte, o + 2);
	osz := int d[o + 2];
	if(osz < 1 || osz > 4)
		raise "cff:index";
	p := o + 3;
	offs := array[n + 1] of int;
	for(i := 0; i <= n; i++){
		v := 0;
		for(k := 0; k < osz; k++)
			v = (v << 8) | int d[p + i * osz + k];
		offs[i] = v;
	}
	base := p + (n + 1) * osz - 1;
	items := array[n] of array of byte;
	for(i = 0; i < n; i++){
		if(offs[i + 1] < offs[i] || base + offs[i + 1] > len d)
			raise "cff:index";
		items[i] = d[base + offs[i]:base + offs[i + 1]];
	}
	return (items, base + offs[n]);
}

# an INDEX written out
cffmkindex(items: array of array of byte): array of byte
{
	n := len items;
	if(n == 0)
		return array[] of {byte 0, byte 0};
	tot := 1;
	for(i := 0; i < n; i++)
		tot += len items[i];
	osz := 1;
	while(osz < 4 && tot >= (1 << (8 * osz)))
		osz++;
	r := array[3 + (n + 1) * osz + tot - 1] of byte;
	r[0] = byte (n >> 8);
	r[1] = byte n;
	r[2] = byte osz;
	off := 1;
	p := 3;
	for(i = 0; i <= n; i++){
		for(k := osz - 1; k >= 0; k--)
			r[p++] = byte (off >> (8 * k));
		if(i < n)
			off += len items[i];
	}
	for(i = 0; i < n; i++){
		r[p:] = items[i];
		p += len items[i];
	}
	return r;
}

# a DICT's entries: each operator (12 x as 1200 + x) with its operands'
# bytes, in order
Dent: adt {
	op:	int;
	args:	array of byte;	# the operands as they were encoded
	nums:	array of int;	# their values (reals as 0)
};

cffdict(b: array of byte): list of Dent
{
	r: list of Dent;
	i := 0;
	beg := 0;
	nums: list of int;
	while(i < len b){
		x := int b[i];
		if(x <= 21){
			op := x;
			oi := i;
			if(x == 12){
				op = 1200 + int b[i + 1];
				i += 2;
			}else
				i++;
			na := 0;
			for(t := nums; t != nil; t = tl t)
				na++;
			a := array[na] of int;
			for(t = nums; t != nil; t = tl t)
				a[--na] = hd t;
			r = Dent(op, b[beg:oi], a) :: r;
			nums = nil;
			beg = i;
		}else if(x == 28){
			nums = s16(b, i + 1) :: nums;
			i += 3;
		}else if(x == 29){
			nums = s32(b, i + 1) :: nums;
			i += 5;
		}else if(x == 30){
			i++;
			while(i < len b){
				y := int b[i++];
				if((y & 15) == 15 || (y >> 4) == 15)
					break;
			}
			nums = 0 :: nums;
		}else if(x >= 32 && x <= 246){
			nums = (x - 139) :: nums;
			i++;
		}else if(x >= 247 && x <= 250){
			nums = ((x - 247) * 256 + int b[i + 1] + 108) :: nums;
			i += 2;
		}else if(x >= 251 && x <= 254){
			nums = (-(x - 251) * 256 - int b[i + 1] - 108) :: nums;
			i += 2;
		}else
			raise "cff:dict";
	}
	rr: list of Dent;
	for(; r != nil; r = tl r)
		rr = hd r :: rr;
	return rr;
}

# s16 is pdf.b's
s32(b: array of byte, i: int): int
{
	return (int b[i] << 24) | (int b[i + 1] << 16) | (int b[i + 2] << 8) | int b[i + 3];
}

# an operand of five bytes, so that a DICT's size is known before its offsets are
int5(v: int): array of byte
{
	return array[] of {byte 29, byte (v >> 24), byte (v >> 16), byte (v >> 8), byte v};
}

dictop(op: int): array of byte
{
	if(op >= 1200)
		return array[] of {byte 12, byte (op - 1200)};
	return array[] of {byte op};
}

catb(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# a DICT written out, the operands of the operators in fix given as
# fixed-size integers
mkdict(ents: list of Dent, fix: list of (int, array of int)): array of byte
{
	r := array[0] of byte;
	for(; ents != nil; ents = tl ents){
		e := hd ents;
		args := e.args;
		for(f := fix; f != nil; f = tl f){
			(op, v) := hd f;
			if(op == e.op){
				args = array[0] of byte;
				for(k := 0; k < len v; k++)
					args = catb(args, int5(v[k]));
			}
		}
		r = catb(r, catb(args, dictop(e.op)));
	}
	return r;
}

dictget(ents: list of Dent, op: int): array of int
{
	for(; ents != nil; ents = tl ents)
		if((hd ents).op == op)
			return (hd ents).nums;
	return nil;
}

subrbias(n: int): int
{
	if(n < 1240)
		return 107;
	if(n < 33900)
		return 1131;
	return 32768;
}

# the subroutines a charstring calls, marked in gused and lused
Cs: adt {
	gsubrs, lsubrs:	array of array of byte;
	gused, lused:	array of byte;
	nhints:	int;
	depth:	int;
	stack:	array of int;	# one stack, a subroutine's operands left by its caller
	sp:	int;
};

# reads a Type 2 charstring; 1 at its end (endchar), 0 at return
cswalk(c: ref Cs, s: array of byte): int
{
	i := 0;
	while(i < len s){
		b := int s[i];
		if(b >= 32 || b == 28 || b == 255){
			v := 0;
			if(b == 28){
				if(i + 3 > len s)
					raise "cff:charstring";
				v = s16(s, i + 1);
				i += 3;
			}else if(b == 255){
				if(i + 5 > len s)
					raise "cff:charstring";
				v = s32(s, i + 1) >> 16;
				i += 5;
			}else if(b <= 246){
				v = b - 139;
				i++;
			}else if(b <= 250){
				v = (b - 247) * 256 + int s[i + 1] + 108;
				i += 2;
			}else{
				v = -(b - 251) * 256 - int s[i + 1] - 108;
				i += 2;
			}
			if(c.sp < len c.stack)
				c.stack[c.sp++] = v;
			continue;
		}
		i++;
		case b {
		1 or 3 or 18 or 23 =>		# hstem, vstem, hstemhm, vstemhm
			c.nhints += c.sp / 2;
			c.sp = 0;
		19 or 20 =>			# hintmask, cntrmask: stems before them too
			c.nhints += c.sp / 2;
			c.sp = 0;
			i += (c.nhints + 7) / 8;
		10 or 29 =>			# callsubr, callgsubr
			if(c.sp < 1 || c.depth > 10)
				raise "cff:charstring";
			c.sp--;
			subrs := c.lsubrs;
			used := c.lused;
			if(b == 29){
				subrs = c.gsubrs;
				used = c.gused;
			}
			k := c.stack[c.sp] + subrbias(len subrs);
			if(k < 0 || k >= len subrs)
				raise "cff:charstring";
			used[k] = byte 1;
			c.depth++;
			e := cswalk(c, subrs[k]);
			c.depth--;
			if(e)
				return 1;
		11 =>				# return
			return 0;
		14 =>				# endchar; with four more, an accent (seac)
			if(c.sp >= 4)
				raise "cff:seac";
			return 1;
		12 =>				# escaped: flex and arithmetic
			i++;
			c.sp = 0;
		* =>
			c.sp = 0;
		}
	}
	return 0;
}

# the CFF table cff subset to the glyphs used; nil if it cannot be
cffsubset(cff: array of byte, used: array of byte): array of byte
{
	{
		return cffsubset1(cff, used);
	} exception {
	"*" =>
		return nil;
	}
}

cffsubset1(d: array of byte, used: array of byte): array of byte
{
	if(len d < 4 || int d[0] != 1)
		return nil;
	hsz := int d[2];
	(names, o1) := cffindex(d, hsz);
	(tops, o2) := cffindex(d, o1);
	(strs, o3) := cffindex(d, o2);
	(gsubrs, nil) := cffindex(d, o3);
	if(len tops != 1)
		return nil;
	top := cffdict(tops[0]);
	if(dictget(top, 1230) != nil || dictget(top, 1236) != nil)	# ROS, FDArray: CID-keyed
		return nil;
	if((t := dictget(top, 1206)) != nil && len t > 0 && t[0] != 2)
		return nil;
	cso := dictget(top, 17);
	priv := dictget(top, 18);
	if(len cso != 1 || len priv != 2)
		return nil;
	(cs, nil) := cffindex(d, cso[0]);
	ng := len cs;
	pd := d[priv[1]:priv[1] + priv[0]];
	pdict := cffdict(pd);
	lsubrs := array[0] of array of byte;
	lso := dictget(pdict, 19);
	if(len lso == 1)
		(lsubrs, nil) = cffindex(d, priv[1] + lso[0]);
	# the glyphs kept: those used, and .notdef
	keep := array[ng] of {* => byte 0};
	keep[0] = byte 1;
	for(i := 0; i < len used && i < ng; i++)
		if(used[i] != byte 0)
			keep[i] = byte 1;
	c := ref Cs(gsubrs, lsubrs, array[len gsubrs] of {* => byte 0}, array[len lsubrs] of {* => byte 0}, 0, 0, array[48] of int, 0);
	ncs := array[ng] of array of byte;
	empty := array[] of {byte 14};
	for(i = 0; i < ng; i++){
		if(keep[i] == byte 0){
			ncs[i] = empty;
			continue;
		}
		c.nhints = 0;
		c.sp = 0;
		cswalk(c, cs[i]);
		ncs[i] = cs[i];
	}
	ret := array[] of {byte 11};
	ngs := array[len gsubrs] of array of byte;
	for(i = 0; i < len gsubrs; i++)
		if(c.gused[i] != byte 0)
			ngs[i] = gsubrs[i];
		else
			ngs[i] = ret;
	nls := array[len lsubrs] of array of byte;
	for(i = 0; i < len lsubrs; i++)
		if(c.lused[i] != byte 0)
			nls[i] = lsubrs[i];
		else
			nls[i] = ret;
	# the charset and encoding, as they were
	csetv := dictget(top, 15);
	charset := array[0] of byte;
	if(len csetv == 1 && csetv[0] > 2)
		charset = d[csetv[0]:csetv[0] + charsetlen(d, csetv[0], ng)];
	encv := dictget(top, 16);
	encoding := array[0] of byte;
	if(len encv == 1 && encv[0] > 1)
		encoding = d[encv[0]:encv[0] + encodinglen(d, encv[0])];
	# laid out again: header, Name, Top DICT, String and Global Subr
	# INDEXes; charset, encoding, CharStrings, Private DICT, its Subrs
	ngsi := cffmkindex(ngs);
	ncsi := cffmkindex(ncs);
	nlsi := cffmkindex(nls);
	nameb := cffmkindex(names);
	strb := cffmkindex(strs);
	# the Private DICT with its Subrs at a fixed-size offset (its own size)
	fixp: list of (int, array of int);
	if(len lso == 1)
		fixp = (19, array[] of {0}) :: nil;
	pdb := mkdict(pdict, fixp);
	if(len lso == 1){
		fixp = (19, array[] of {len pdb}) :: nil;
		pdb = mkdict(pdict, fixp);
	}
	# the Top DICT's size, with five-byte offsets
	fixt := (17, array[] of {0}) :: (18, array[] of {0, 0}) :: nil;
	if(len charset > 0)
		fixt = (15, array[] of {0}) :: fixt;
	if(len encoding > 0)
		fixt = (16, array[] of {0}) :: fixt;
	topb := mkdict(top, fixt);
	topi := cffmkindex(array[] of {topb});
	o := hsz + len nameb + len topi + len strb + len ngsi;
	ocs := o;
	o += len charset;
	oenc := o;
	o += len encoding;
	ochars := o;
	o += len ncsi;
	opriv := o;
	o += len pdb;
	fixt = (17, array[] of {ochars}) :: (18, array[] of {len pdb, opriv}) :: nil;
	if(len charset > 0)
		fixt = (15, array[] of {ocs}) :: fixt;
	if(len encoding > 0)
		fixt = (16, array[] of {oenc}) :: fixt;
	topb2 := mkdict(top, fixt);
	if(len topb2 != len topb)
		return nil;
	topi = cffmkindex(array[] of {topb2});
	r := array[o + len nlsi] of byte;
	p := 0;
	r[p:] = d[0:hsz];
	p += hsz;
	for(parts := array[] of {nameb, topi, strb, ngsi, charset, encoding, ncsi, pdb, nlsi}; len parts > 0; parts = parts[1:]){
		if(len lso != 1 && len parts == 1)
			break;
		r[p:] = parts[0];
		p += len parts[0];
	}
	return r[0:p];
}

charsetlen(d: array of byte, o: int, ng: int): int
{
	case int d[o] {
	0 =>
		return 1 + 2 * (ng - 1);
	1 or 2 =>
		w := 1;
		if(int d[o] == 2)
			w = 2;
		n := 0;
		p := o + 1;
		while(n < ng - 1){
			left := int d[p + 2];
			if(w == 2)
				left = (left << 8) | int d[p + 3];
			n += left + 1;
			p += 2 + w;
		}
		return p - o;
	}
	raise "cff:charset";
}

encodinglen(d: array of byte, o: int): int
{
	f := int d[o];
	n := 0;
	case f & 16r7f {
	0 =>
		n = 2 + int d[o + 1];
	1 =>
		n = 2 + 2 * int d[o + 1];
	* =>
		raise "cff:encoding";
	}
	if(f & 16r80)
		n += 1 + 3 * int d[o + n];
	return n;
}

# an OpenType font with its CFF table subset, and only the tables a PDF
# reader may look at; nil if it cannot be
otfsubset(otf: array of byte, used: array of byte): array of byte
{
	{
		return otfsubset1(otf, used);
	} exception {
	"*" =>
		return nil;
	}
}

otfsubset1(otf: array of byte, used: array of byte): array of byte
{
	if(len otf < 12)
		return nil;
	nt := (int otf[4] << 8) | int otf[5];
	tags := array[nt] of string;
	tabs := array[nt] of array of byte;
	n := 0;
	for(i := 0; i < nt; i++){
		e := 12 + 16 * i;
		tag := string otf[e:e + 4];
		off := s32(otf, e + 8);
		ln := s32(otf, e + 12);
		if(off < 0 || ln < 0 || off + ln > len otf)
			return nil;
		case tag {
		"CFF " =>
			sub := cffsubset(otf[off:off + ln], used);
			if(sub == nil)
				return nil;
			tags[n] = tag;
			tabs[n++] = sub;
		"head" or "hhea" or "hmtx" or "maxp" or "OS/2" or "name" or "post" or "cmap" =>
			tags[n] = tag;
			tabs[n++] = otf[off:off + ln];
		}
	}
	return sfnt(otf[0:4], tags[0:n], tabs[0:n]);
}

# an sfnt of these tables, each on four bytes after the directory
sfnt(ver: array of byte, tags: array of string, tabs: array of array of byte): array of byte
{
	n := len tags;
	sz := 12 + 16 * n;
	for(i := 0; i < n; i++)
		sz += (len tabs[i] + 3) & ~3;
	r := array[sz] of {* => byte 0};
	r[0:] = ver;
	r[4] = byte (n >> 8);
	r[5] = byte n;
	es := 1;
	lg := 0;
	while(es * 2 <= n){
		es *= 2;
		lg++;
	}
	put16(r, 6, es * 16);
	put16(r, 8, lg);
	put16(r, 10, n * 16 - es * 16);
	p := 12 + 16 * n;
	for(i = 0; i < n; i++){
		e := 12 + 16 * i;
		r[e:] = array of byte tags[i];
		put32(r, e + 4, tabsum(tabs[i]));
		put32(r, e + 8, p);
		put32(r, e + 12, len tabs[i]);
		r[p:] = tabs[i];
		p += (len tabs[i] + 3) & ~3;
	}
	return r;
}

tabsum(t: array of byte): int
{
	s := big 0;
	for(i := 0; i < len t; i += 4){
		v := 0;
		for(k := 0; k < 4; k++){
			v <<= 8;
			if(i + k < len t)
				v |= int t[i + k];
		}
		s += big v & big 16rffffffff;
	}
	return int (s & big 16rffffffff);
}

put16(b: array of byte, o: int, v: int)
{
	b[o] = byte (v >> 8);
	b[o + 1] = byte v;
}

put32(b: array of byte, o: int, v: int)
{
	b[o] = byte (v >> 24);
	b[o + 1] = byte (v >> 16);
	b[o + 2] = byte (v >> 8);
	b[o + 3] = byte v;
}

#
# a TrueType font subset to the glyphs used: the glyphs not used are
# empty (no outline), keeping their numbers, and a kept composite
# glyph's components are kept with it; glyf and loca are written again
# (loca long), and of the other tables those a reader may look at, the
# hinting programs among them
#
ttfsubset(otf: array of byte, used: array of byte): array of byte
{
	{
		return ttfsubset1(otf, used);
	} exception {
	"*" =>
		return nil;
	}
}

ttfsubset1(otf: array of byte, used: array of byte): array of byte
{
	if(len otf < 12)
		return nil;
	nt := (int otf[4] << 8) | int otf[5];
	tag := array[nt] of string;
	tab := array[nt] of array of byte;
	head, loca, glyf, maxp: array of byte;
	for(i := 0; i < nt; i++){
		e := 12 + 16 * i;
		tag[i] = string otf[e:e + 4];
		off := s32(otf, e + 8);
		ln := s32(otf, e + 12);
		if(off < 0 || ln < 0 || off + ln > len otf)
			return nil;
		tab[i] = otf[off:off + ln];
		case tag[i] {
		"head" =>	head = tab[i];
		"loca" =>	loca = tab[i];
		"glyf" =>	glyf = tab[i];
		"maxp" =>	maxp = tab[i];
		}
	}
	if(head == nil || loca == nil || glyf == nil || maxp == nil || len head < 54)
		return nil;
	ng := (int maxp[4] << 8) | int maxp[5];
	long := s16(head, 50) != 0;
	offs := array[ng + 1] of int;
	for(i = 0; i <= ng; i++){
		if(long)
			offs[i] = s32(loca, 4 * i);
		else
			offs[i] = 2 * ((int loca[2 * i] << 8) | int loca[2 * i + 1]);
		if(offs[i] < 0 || offs[i] > len glyf)
			return nil;
	}
	keep := array[ng] of {* => byte 0};
	keep[0] = byte 1;
	for(i = 0; i < len used && i < ng; i++)
		if(used[i] != byte 0)
			keep[i] = byte 1;
	# a composite glyph's components, and theirs
	for(changed := 1; changed; ){
		changed = 0;
		for(i = 0; i < ng; i++){
			if(keep[i] == byte 0 || offs[i + 1] - offs[i] < 10)
				continue;
			g := glyf[offs[i]:offs[i + 1]];
			if(s16(g, 0) >= 0)
				continue;
			p := 10;
			for(;;){
				fl := (int g[p] << 8) | int g[p + 1];
				ci := (int g[p + 2] << 8) | int g[p + 3];
				if(ci < ng && keep[ci] == byte 0){
					keep[ci] = byte 1;
					changed = 1;
				}
				p += 4;
				if(fl & 1)
					p += 4;
				else
					p += 2;
				if(fl & 8)
					p += 2;
				else if(fl & 16r40)
					p += 4;
				else if(fl & 16r80)
					p += 8;
				if(!(fl & 16r20))
					break;
			}
		}
	}
	tot := 0;
	for(i = 0; i < ng; i++)
		if(keep[i] != byte 0)
			tot += (offs[i + 1] - offs[i] + 3) & ~3;
	nglyf := array[tot] of {* => byte 0};
	nloca := array[4 * (ng + 1)] of byte;
	p := 0;
	for(i = 0; i < ng; i++){
		put32(nloca, 4 * i, p);
		if(keep[i] != byte 0){
			nglyf[p:] = glyf[offs[i]:offs[i + 1]];
			p += (offs[i + 1] - offs[i] + 3) & ~3;
		}
	}
	put32(nloca, 4 * ng, p);
	nhead := array[len head] of byte;
	nhead[0:] = head;
	put16(nhead, 50, 1);	# loca long
	put32(nhead, 8, 0);	# checkSumAdjustment: not kept up
	tags := array[nt] of string;
	tabs := array[nt] of array of byte;
	n := 0;
	for(i = 0; i < nt; i++){
		t := tab[i];
		case tag[i] {
		"head" =>	t = nhead;
		"loca" =>	t = nloca;
		"glyf" =>	t = nglyf;
		"hhea" or "hmtx" or "maxp" or "OS/2" or "name" or "post" or "cmap" or "cvt " or "fpgm" or "prep" =>
			;
		* =>
			continue;
		}
		tags[n] = tag[i];
		tabs[n++] = t;
	}
	return sfnt(otf[0:4], tags[0:n], tabs[0:n]);
}
